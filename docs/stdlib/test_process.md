# test_process

Assertions for a test that runs a program.

A test whose subject is a whole toolchain — a compiler verb, a script,
any binary — cannot compute its answer; it has to spawn the thing and
grade what came back. `expectSpawnOk` and `expectSpawnFails` grade a
spawn, and `medakaRoot`, `underRoot` and `medakaBin` say which files and
which binary a test addresses.

The two jobs are deliberately separate: a grader that also resolved the
binary would have to name a verb, and callers need `check`, `run` and
`test`.

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
`MEDAKA` cannot resolve to some other build on `PATH` — or to nothing at
all, which still spawns and exits 127 with no output, an outcome any
assertion phrased over the output would accept.

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

