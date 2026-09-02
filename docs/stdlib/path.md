# path

Manipulation of `/`-separated paths as text.

Nothing here touches the filesystem. A path is split, joined, and
simplified by its text alone, so `normalize` cannot tell a directory
from a symbolic link. `fs` is the module that reads the filesystem.

An extension includes its leading dot: `extname "a.txt"` is `".txt"`.
A name that starts with a dot and has no other dot, such as `.bashrc`,
has no extension.

## Components

### `dirname`

```
dirname : String -> String
```

The directory part of a path: everything before the last `/`.

`"."` when the path has no `/`. A trailing `/` is ignored, so the last
segment before it is still the part removed.

```medaka
> dirname "a/b/c.txt"
"a/b"
> dirname "c.txt"
"."
```

### `basename`

```
basename : String -> String
```

The last component of a path: everything after the last `/`.

The whole path when it has no `/`, and `""` when it ends in `/`. Apply
`normalize` first to ignore a trailing slash.

```medaka
> basename "a/b/c.txt"
"c.txt"
> basename "a/b/"
""
```

### `extname`

```
extname : String -> String
```

The extension of the last component, with its dot.

`""` when there is none, including for a name that starts with its only
dot.

```medaka
> extname "a/b/c.txt"
".txt"
> extname ".bashrc"
""
```

### `stem`

```
stem : String -> String
```

The last component without its extension.

```medaka
> stem "a/b/c.txt"
"c"
> stem ".bashrc"
".bashrc"
```

### `hasExtension`

```
hasExtension : String -> String -> Bool
```

Whether the last component has the extension `ext`.

The leading dot on `ext` is optional.

```medaka
> hasExtension "txt" "a/b.txt"
True
> hasExtension ".md" "a/b.txt"
False
```

### `withExtension`

```
withExtension : String -> String -> String
```

The path with the last component's extension replaced by `ext`.

The leading dot on `ext` is optional. When the path has no extension,
`ext` is appended.

```medaka
> withExtension ".md" "a/b.txt"
"a/b.md"
> withExtension "md" "a/b"
"a/b.md"
```

## Joining and splitting

### `joinPath`

```
joinPath : String -> String -> String
```

Two path segments joined with a single `/`.

Slashes already at the boundary are collapsed, and an empty segment is
skipped.

```medaka
> joinPath "a/b" "c.txt"
"a/b/c.txt"
> joinPath "a/b/" "/c.txt"
"a/b/c.txt"
```

### `joinAll`

```
joinAll : List String -> String
```

The segments joined in order with `joinPath`.

`""` for the empty list.

```medaka
> joinAll ["a", "b", "c.txt"]
"a/b/c.txt"
```

### `segments`

```
segments : String -> List String
```

The non-empty components of a path, split on `/`.

`.` and `..` are kept; apply `normalize` first to resolve them.

```medaka
> segments "a/b/c.txt"
["a", "b", "c.txt"]
> segments "/a//b/"
["a", "b"]
```

## Predicates

### `isAbsolute`

```
isAbsolute : String -> Bool
```

Whether the path starts with `/`.

```medaka
> isAbsolute "/a/b"
True
> isAbsolute "a/b"
False
```

### `stripPrefix`

```
stripPrefix : String -> String -> Option String
```

The path with `prefix` removed from its front, or `None` when the path
does not start with `prefix` at a component boundary.

The empty prefix always matches.

```medaka
> stripPrefix "a/b" "a/b/c.txt"
Some "c.txt"
> stripPrefix "a/x" "a/b/c.txt"
None
```

## Normalization

### `normalize`

```
normalize : String -> String
```

The path simplified by its text alone.

Repeated `/` are collapsed, `.` segments are dropped, a `..` cancels the
segment before it, and a trailing `/` is dropped. A leading `..` on a
relative path is kept, and a `..` above the root of an absolute path is
dropped. The empty path becomes `"."`.

```medaka
> normalize "a//b/./c/../d"
"a/b/d"
> normalize "../a/../../b"
"../../b"
```

