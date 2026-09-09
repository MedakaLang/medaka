# fs

Filesystem helpers built on the host file primitives.

The primitives are in scope without an import: `readFile`, `writeFile`,
`appendFile`, `readFileBytes`, `writeFileBytes`, `fileExists`, `listDir`,
`makeDir`, `removeFile`, `rename`, `removeDir`, `statFile`, and
`canonicalizePath`. This module adds a `FileStat` record over
`statFile`'s tuple and the composed operations `copyFile`, `mkdirAll`,
`walkDir`, `isDir`, `isFile`, and `fileSize`.

Every operation returns `Result String a`, with the host's error message
in `Err`. File operations run only in a built program, not under the
interpreter.

## Metadata

### `FileStat`

```
data FileStat
  = FileStat { size : Int, isDir : Bool, isFile : Bool, mtime : Float }
```

What `stat` reports about a path: its size in bytes, whether it is a
directory, whether it is a regular file, and its modification time in
seconds since the Unix epoch.

Instances: `Eq`, `Debug`

### `stat`

```
stat : String -> <FileRead _> Result String FileStat
```

The metadata of a path as a `FileStat`, or `Err` when the path cannot
be examined, for instance because it does not exist.

### `isDir`

```
isDir : String -> <FileRead _> Result String Bool
```

Whether a path exists and is a directory.

### `isFile`

```
isFile : String -> <FileRead _> Result String Bool
```

Whether a path exists and is a regular file.

### `fileSize`

```
fileSize : String -> <FileRead _> Result String Int
```

The size of a file in bytes.

## Operations

### `copyFile`

```
copyFile : String -> String -> <FileRead _, FileWrite _> Result String Unit
```

Copies the bytes of `src` to `dst`, replacing any existing `dst`.

A read failure is reported before anything is written.

### `mkdirAll`

```
mkdirAll : String -> <FileWrite _> Result String Unit
```

Creates a directory and every missing parent, like `mkdir -p`.

A directory that already exists is not an error.

### `walkDir`

```
walkDir : String -> <FileRead _> Result String (List String)
```

Every path under a directory, files and subdirectories both, depth
first.

Each result is the full path, joined onto `root`. `Err` on the first
directory that cannot be read or entry that cannot be examined.

### `fixtureFiles`

```
fixtureFiles : String -> <FileRead _> Result String (List String)
```

Every regular file under `root`, depth first: `walkDir` with
directories filtered out and an anti-vacuity floor. A directory that
reads cleanly but holds zero files is still `Err`, since a fixture-file
gate iterating zero fixtures would otherwise report success having
tested nothing.

```medaka
> fixtureFiles "stdlib/no-such-fixture-doctest-dir"
Err "No such file or directory"
```

Every result is a path under `root`. The shape is asserted rather than
the count, for the same reason as `fixtureDirs`' doctest below.

```medaka
> map (all (contains "/effect_set_fixtures/")) (fixtureFiles "test/effect_set_fixtures")
Ok True
```

### `fixtureDirs`

```
fixtureDirs : String -> <FileRead _> Result String (List String)
```

Every top-level subdirectory of `root`, non-recursive, with the same
anti-vacuity floor as `fixtureFiles`. For a corpus where each fixture unit
is a whole directory (several files under one name) rather than a single
file — `fixtureFiles` filters directories out, so a directory-shaped
corpus needs this instead.

```medaka
> fixtureDirs "stdlib/no-such-fixture-doctest-dir"
Err "No such file or directory"
```

Every result is a path under `root`. The shape is asserted rather than
the count: a count of somebody else's corpus written down here breaks
this module every time that corpus grows.

```medaka
> map (all (contains "/import_order_fixtures/")) (fixtureDirs "test/import_order_fixtures")
Ok True
```

### `expectUnitCount`

```
expectUnitCount : Int -> List a -> Result String Unit
```

`Err` unless `units` has exactly `want` elements — the weaker floor for
a corpus with no wired roster to check against: it catches a corpus that
grew or shrank, but not which unit changed. Prefer `unrosteredUnits` /
`missingUnits` (`test_process.mdk`) whenever a roster exists to check
against instead.

```medaka
> expectUnitCount 2 ["a", "b"]
Ok ()
```

```medaka
> expectUnitCount 3 ["a", "b"]
Err "expected 3 units, found 2"
```

## Instances

