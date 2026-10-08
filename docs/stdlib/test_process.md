# test_process

Assertions for a test that runs a program.

A test whose subject is a whole program (a compiler verb, a script, any
binary) spawns it and grades what came back. `expectSpawnOk`,
`expectSpawnFails` and `expectSpawnOkLine` grade a spawn. `medakaRoot`,
`underRoot` and `medakaBin` locate the tree and the binary under test.
`boundedVerb` puts a time limit on one spawn, and `withScratchDir` runs a
test body in a directory of its own and removes it afterwards.

A test that grades a directory of `medaka test` suites reads their
assertion counts with `testAssertionCount`, or with `testAssertionCounts`
to run the suites side by side, and checks its roster against
the directory with `testFileStem`, `unrosteredTestFiles` and
`missingTestFiles`. `expectFloor` grades one count against its committed
floor, and `mdkModuleStem` names the modules of a directory that is not
limited to test files.

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
underRoot rel
```

The path `rel`, relative to the tree root, resolved under `medakaRoot`.

### `medakaBin`

```
medakaBin : <IO> String
```

The Medaka binary to spawn: `MEDAKA`, or the binary named medaka in
`medakaRoot` when it is unset.

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
boundedVerb : String -> List String -> <Exec> Result String (Int, String, String)
boundedVerb cmd args
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
boundedVerbSeconds : Int -> String -> List String -> <Exec> Result String (Int, String, String)
boundedVerbSeconds secs cmd args
```

`boundedVerb` with the time limit given as `secs`, for a spawn that
needs longer than `spawnTimeoutSeconds`.

`cmd` is looked up on `PATH` through the env command, so a command that
does not exist reports exit 127 with env's message on stderr rather than a
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
scratchDir : <Exec "mktemp*"> Result String String
```

A fresh, empty directory for a test that has to write files.

`scratchDir` is a value, so it is evaluated once per process: every use in
one test file, and so every `test` block of that file, is handed the SAME
directory. A block that removes it takes the next block's workspace with
it, and a block that leaves files behind leaks them into the next. Two
concurrent runs of the same test do not collide, because each process makes
its own. The caller owns the directory and removes it. Prefer
`withScratchDir`, which gives each call its own directory and removes it.

```medaka
> map (startsWith "/") scratchDir
Ok True
```

### `withScratchDir`

```
withScratchDir : (String -> <Exec, IO, FileRead, FileWrite> Expectation) -> <Exec, IO, FileRead, FileWrite> Expectation
withScratchDir body
```

Runs `body` with a fresh, empty directory of its own, then removes it.

Unlike `scratchDir`, each call makes a new directory, so the `test` blocks
of one file cannot see each other's files and none can delete another's
workspace. Removal is graded: a directory that cannot be removed fails the
test rather than being left behind, and a failing `body` still has its
directory removed.

```medaka
> withScratchDir (dir => if startsWith "/" dir then Pass "abs" "abs" else Fail "relative" "abs" dir)
Pass "" ""
> withScratchDir (dir => expectSpawnOk "ls" [dir])
Pass "" ""
```

## Grading a spawn

### `expectSpawnOk`

```
expectSpawnOk : (cmd : String) -> List String -> <Exec cmd> Expectation
expectSpawnOk cmd args
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
expectSpawnFails : (cmd : String) -> List String -> String -> <Exec cmd> Expectation
expectSpawnFails cmd args needle
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
expectSpawnFailsAll : (cmd : String) -> List String -> List String -> <Exec cmd> Expectation
expectSpawnFailsAll cmd args needles
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
expectSpawnOkLine : (cmd : String) -> List String -> String -> <Exec cmd> Expectation
expectSpawnOkLine cmd args wantLine
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
testFileStem name
```

The stem of a `*_test.mdk` file name, or `None` when `name` is not one.

```medaka
> testFileStem "expr_test.mdk"
Some "expr_test"
> testFileStem "expr.mdk"
None
```

### `mdkModuleStem`

```
mdkModuleStem : String -> Option String
mdkModuleStem name
```

The module name of a `.mdk` file name, or `None` when `name` is not one.

Unlike `testFileStem` it accepts every Medaka module, so a `*_test.mdk`
sibling is named by its full stem.

```medaka
> mdkModuleStem "set.mdk"
Some "set"
> mdkModuleStem "set_test.mdk"
Some "set_test"
> mdkModuleStem "set.lextok.golden"
None
```

### `expectFloor`

```
expectFloor : String -> Int -> Result String Int -> Expectation
expectFloor label floor counted
```

Passes when `counted`, the result of `testAssertionCount` for the suite
`label`, is `Ok` of at least `floor`.

A count below `floor` fails naming `label` and both numbers, so a suite
that silently stopped discovering its tests is not read as green. An `Err`
fails with its own text, so a suite that failed to spawn, exited nonzero or
reported unparseable output is never mistaken for a count that merely fell
short.

```medaka
> expectFloor "s/a.mdk" 3 (Ok 5)
Pass ">= 3 assertions" "5 assertions"
> expectFloor "s/a.mdk" 3 (Err "boom")
Fail "boom" ">= 3 assertions" "spawn/run/parse error"
> expectFloor "s/a.mdk" 3 (Ok 2)
Fail "s/a.mdk — only 2 assertions ran, expected >= 3 (vacuous-green guard: discovery may have silently stopped finding tests)" ">= 3 assertions" "2 assertions"
```

### `testAssertionCount`

```
testAssertionCount : String -> List String -> <Exec, IO> Result String Int
testAssertionCount path extraArgs
```

The number of assertions `medaka test --json` reports as passed for the
suite at `path`, or `Err` naming what went wrong.

`extraArgs` are passed to `medaka test` before the path, so a suite that
needs the compiled engine is spawned with `["--native"]`. A suite that
exits nonzero is an `Err`, never a smaller count. The `Err` for a
failing run carries the tail of its output.

### `testAssertionCounts`

```
testAssertionCounts : List (String, List String) -> <Exec, IO> List (Result String Int)
testAssertionCounts rows
```

`testAssertionCount` for every `(path, extraArgs)` row, with the suites
run side by side.

Each element is what `testAssertionCount` returns for that row, in the
same order, with the same error text. At most `testJobs` suites run at
once.

```medaka
> testAssertionCounts [("no-such-suite.mdk", [])] == [testAssertionCount "no-such-suite.mdk" []]
True
```

### `unrosteredUnits`

```
unrosteredUnits : (String -> Option String) -> List String -> List String -> List String
unrosteredUnits namer known entries
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
missingUnits namer wanted entries
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
unrosteredTestFiles : String -> List String -> <FileRead> Result String (List String)
unrosteredTestFiles dir known
```

The `*_test.mdk` stems in `dir` that are absent from `known`.

`known` is the roster plus any exemptions, so an empty result means every
test file in `dir` is accounted for.

### `missingTestFiles`

```
missingTestFiles : String -> List String -> <FileRead> Result String (List String)
missingTestFiles dir wanted
```

The stems in `wanted` that name no `*_test.mdk` file in `dir`.

Reports a roster row whose file is no longer present.

## Grading a floor roster against its own `test` blocks

### `ungradedRosterRows`

```
ungradedRosterRows : String -> String -> List String -> List String -> List String
ungradedRosterRows titlePrefix callOpen roster sourceLines
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
disagreeingFloorBlocks titlePrefix callOpen sourceLines
```

The blocks in `sourceLines` whose title and grading call name different
units, each rendered as `<titled> -> <graded>`.

A block that grades nothing renders as `<titled> -> grades nothing`.
`ungradedRosterRows` reports the rows such a block leaves ungraded.

```medaka
> disagreeingFloorBlocks "s/" "grade \"" ["test \"s/a.mdk executed >= 1 assertions\" = grade \"b\""]
["a -> b"]
```

