# fs

Filesystem helpers built on the host file primitives.

The primitives are in scope without an import: `readFile`, `writeFile`,
`appendFile`, `readFileBytes`, `writeFileBytes`, `fileExists`, `listDir`,
`makeDir`, `removeFile`, `rename`, `removeDir`, `statFile`, and
`canonicalizePath`. This module adds a `FileStat` record over
`statFile`'s tuple and the composed operations `copyFile`,
`replaceDurably`, `mkdirAll`, `mkdirAllDurably`, `walkDir`, `walkFiles`, `walkFilesSkipping`,
`glob`, `isDir`,
`isFile`, and `fileSize`.

Every operation returns `Result String a`, with the host's error message
in `Err`.

`medaka run`, `medaka test` and a built program touch the real filesystem.
Only `medaka test --engines eval` and `medaka repl` do not bind the file
primitives, so a doctest that reaches one is rejected there; see
[ENGINES](ENGINES.md) for every engine.

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
stat : (path : String) -> <FileRead path> Result String FileStat
stat p
```

The metadata of a path as a `FileStat`, or `Err` when the path cannot
be examined, for instance because it does not exist.

### `isDir`

```
isDir : (path : String) -> <FileRead path> Result String Bool
isDir p
```

Whether a path exists and is a directory.

### `isFile`

```
isFile : (path : String) -> <FileRead path> Result String Bool
isFile p
```

Whether a path exists and is a regular file.

### `fileSize`

```
fileSize : (path : String) -> <FileRead path> Result String Int
fileSize p
```

The size of a file in bytes.

## Operations

### `copyFile`

```
copyFile : (src : String) -> (dst : String) -> <FileRead src, FileWrite dst> Result String Unit
copyFile src dst
```

Copies the bytes of `src` to `dst`, replacing any existing `dst`.

A read failure is reported before anything is written.

### `editFile`

```
editFile : (path : String) -> (String -> Result String String) -> <FileRead path, FileWrite path> Result String Unit
editFile path f
```

Rewrites the file at `path` with the result of `f` applied to its text.

`Err` from `f` writes nothing and is returned as `Err "<path>: <e>"`, as
is a failure to read or to write. The file is written only when the new text differs
from what was read, so an unchanged edit leaves the modification time
alone. The write is a plain `writeFile`, not a durable replace.

### `replaceDurably`

```
replaceDurably : String -> String -> String -> <FileWrite> Result String Unit
replaceDurably staged target content
```

Replaces `target` with `content` so that a crash leaves either the
old file or the new one, never a partial write.

The content is written to `staged` at `io.ownerOnlyMode` (`0600`),
`staged` is flushed, renamed onto `target`, and then the directory that
holds `target` is flushed, in that order. The first step that fails
returns its `Err` and the rest do not run. The mode is set before any
byte is written, so neither the umask nor a leftover `staged` at a wider
mode can widen it.

`staged` must be on the same filesystem as `target`. A crash before the
rename leaves `staged` behind, so a caller that stages into a directory
it later lists must remove that residue itself. The directory holding
`staged` is not flushed, and neither is the entry of `target`'s
directory in its own parent; `mkdirAllDurably` covers that.

```medaka
> replaceDurably "stdlib/no-such-doctest-dir/r.tmp" "stdlib/no-such-doctest-dir/r" "v1"
Err "No such file or directory"
```

### `mkdirAll`

```
mkdirAll : String -> <FileWrite> Result String Unit
mkdirAll path
```

Creates a directory and every missing parent, like `mkdir -p`.

A directory that already exists is not an error.

### `mkdirAllDurably`

```
mkdirAllDurably : String -> <FileRead, FileWrite> Result String Unit
mkdirAllDurably path
```

Creates a directory and every missing parent, like `mkdirAll`, and
makes each directory it creates durable by flushing that directory's
parent right after creating it.

A path that already exists is left alone and nothing is flushed, so a
call on an existing directory costs one existence check.

Known limit: a directory that already exists is taken to be durable.
That is false for a directory whose creator stopped between creating it
and flushing its parent. A later call finds it present and skips the
flush, so a crash after that can still lose it. Closing the gap would
mean flushing the parent on every call.

```medaka
> mkdirAllDurably "/dev/null"
Ok ()
> mkdirAllDurably "/dev/null/sub"
Err "Not a directory"
```

### `walkDir`

```
walkDir : String -> <FileRead> Result String (List String)
walkDir root
```

Every path under a directory, files and subdirectories both, depth
first.

Each result is the full path, joined onto `root`. `Err` on the first
directory that cannot be read or entry that cannot be examined.

### `walkFiles`

```
walkFiles : String -> <FileRead> Result String (List String)
walkFiles root
```

Every regular file under `root`, in plain string order.

Each result is the full path, joined onto `root`; directories are not
listed, and `Ok []` means there are no files. `Err` on the first
directory that cannot be read or entry that cannot be examined. The order
does not depend on the host's `listDir` order, so the result is stable.
Symbolic links are followed through `stat`, as `walkDir` does, so a link
to a directory is walked and a link loop reports an `Err`. An `Err` names
the path that failed, as `"<path>: <e>"`.

```medaka
> walkFiles "stdlib/no-such-walk-doctest-dir"
Err "stdlib/no-such-walk-doctest-dir: No such file or directory"
```

### `walkFilesSkipping`

```
walkFilesSkipping : (String -> Bool) -> String -> <FileRead> Result String (List String)
walkFilesSkipping skip root
```

`walkFiles`, but a directory whose path satisfies `skip` is not entered.

The path the predicate sees is the one `walkFiles` would report for that
directory, joined onto `root`. `root` itself is never tested, so a
predicate that holds for it still walks it.

```medaka
> walkFilesSkipping (_ => True) "stdlib/no-such-walk-doctest-dir"
Err "stdlib/no-such-walk-doctest-dir: No such file or directory"
```

### `glob`

```
glob : String -> <FileRead> Result String (List String)
glob pattern
```

The files whose paths match the glob `pattern`, in plain string order.

The pattern is read as by `path.matchGlob`. The walk starts at the
longest directory prefix of the pattern that has no `*` or `?`, and a
result reads as the pattern does: `*.mdk` finds `a.mdk`, not `./a.mdk`.
A pattern with no wildcard names one path, which is returned when it is a
file and is otherwise `Ok []`. A prefix directory that is missing or
cannot be read is an `Err` naming it, unlike Python's `glob`, which returns
`[]`. Unless the pattern has a `**` segment the walk goes no deeper than
the pattern's segments, so entries below that depth are never examined.

```medaka
> glob "stdlib/no-such-glob-doctest-dir/*.mdk"
Err "stdlib/no-such-glob-doctest-dir: No such file or directory"
> glob "no-such-glob-doctest-file"
Ok []
```

### `fixtureFiles`

```
fixtureFiles : String -> <FileRead> Result String (List String)
fixtureFiles root
```

Every regular file under `root`, depth first, or `Err` when there are
none.

`walkDir` with directories filtered out. A directory that reads cleanly
but holds no files is an `Err`, so a test that iterates over a fixture
directory cannot pass by iterating over nothing. Every result is a path
under `root`.

```medaka
> fixtureFiles "stdlib/no-such-fixture-doctest-dir"
Err "No such file or directory"
> map (all (contains "/effect_set_fixtures/")) (fixtureFiles "test/effect_set_fixtures")
Ok True
```

### `fixtureDirs`

```
fixtureDirs : String -> <FileRead> Result String (List String)
fixtureDirs root
```

Every top-level subdirectory of `root`, or `Err` when there are none.

Not recursive. For a corpus where each fixture is a whole directory
rather than a single file; `fixtureFiles` filters directories out. A
directory with no subdirectories is an `Err`, as for `fixtureFiles`.
Every result is a path under `root`.

```medaka
> fixtureDirs "stdlib/no-such-fixture-doctest-dir"
Err "No such file or directory"
> map (all (contains "/import_order_fixtures/")) (fixtureDirs "test/import_order_fixtures")
Ok True
```

### `expectUnitCount`

```
expectUnitCount : Int -> List a -> Result String Unit
expectUnitCount want units
```

`Ok` when `units` has exactly `want` elements, otherwise an `Err`
naming both counts.

A floor for a corpus with no roster to check against: it catches a
corpus that grew or shrank, but not which unit changed. When a roster
exists, `test_process.unrosteredUnits` and `test_process.missingUnits`
say which.

```medaka
> expectUnitCount 2 ["a", "b"]
Ok ()
> expectUnitCount 3 ["a", "b"]
Err "expected 3 units, found 2"
```

