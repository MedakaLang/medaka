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

## Instances

