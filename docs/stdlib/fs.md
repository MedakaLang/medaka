# fs

## `FileStat`

```
data FileStat
  = FileStat { size : Int, isDir : Bool, isFile : Bool, mtime : Float }
```

The metadata `statFile` (stat(2)) returns for a path:
`size` in bytes, `isDir`/`isFile` type flags, and `mtime` (modification
time, seconds since the Unix epoch).

Instances: `Eq`, `Debug`

## `stat`

```
stat : String -> <FileRead _> Result String FileStat
```

`stat path` — like `statFile`, but wraps the raw tuple in a `FileStat`.
`Err` (strerror) if the path cannot be stat'd (e.g. does not exist).

## `copyFile`

```
copyFile : String -> String -> <FileRead _, FileWrite _> Result String Unit
```

`copyFile src dst` — byte-clean copy: read `src`'s raw bytes, write them to
`dst` (truncating). Threads the `Result`, so a read failure short-circuits
before any write.

## `mkdirAll`

```
mkdirAll : String -> <FileWrite _> Result String Unit
```

`mkdirAll path` — create `path` and every missing parent directory (like
`mkdir -p`). Recurses on `path.dirname`, so parents are created first. An
already-existing directory (an `EEXIST`/"File exists" error from `makeDir`)
is ignored; any other failure (e.g. permission denied) is reported. Stays
`<FileWrite _>` — it never reads the filesystem, only writes.

## `walkDir`

```
walkDir : String -> <FileRead _> Result String (List String)
```

`walkDir root` — recursively list everything under `root`. Returns FULL
paths (each prefixed with `root` via `path.joinPath`), depth-first, and
includes BOTH files and subdirectories. `Err` (strerror) on the first
directory that cannot be read or entry that cannot be stat'd.

## `isDir`

```
isDir : String -> <FileRead _> Result String Bool
```

`isDir path` — `Ok True` if `path` exists and is a directory.

## `isFile`

```
isFile : String -> <FileRead _> Result String Bool
```

`isFile path` — `Ok True` if `path` exists and is a regular file.

## `fileSize`

```
fileSize : String -> <FileRead _> Result String Int
```

`fileSize path` — the size of `path` in bytes.

## Instances

