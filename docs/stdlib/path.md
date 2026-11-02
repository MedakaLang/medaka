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
dirname path
```

The directory part of a path: everything before the last `/`.

`"."` when the path has no `/`. A trailing `/` is itself the last `/`, so
it is stripped without also dropping the segment before it: `dirname "a/"`
is `"a"`, not `"."`. Apply `normalize` first to collapse a trailing slash
when that segment should be dropped as well.

```medaka
> dirname "a/b/c.txt"
"a/b"
> dirname "c.txt"
"."
> dirname "/a"
"/"
```

### `basename`

```
basename : String -> String
basename path
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
extname path
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
stem path
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
hasExtension ext path
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
withExtension ext path
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
joinPath a b
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
segments path
```

The non-empty components of a path, split on `/`.

`.` and `..` are kept; apply `normalize` first to resolve them.

```medaka
> segments "a/b/c.txt"
["a", "b", "c.txt"]
> segments "/a//b/"
["a", "b"]
```

## Glob patterns

### `matchGlob`

```
matchGlob : String -> String -> Bool
matchGlob pattern path
```

Whether `path` matches the glob `pattern`.

Both are split into segments on `/`, so repeated slashes do not matter,
but a leading `/` must be on both or on neither. Within one segment `*`
matches any run of characters and `?` exactly one character; neither
crosses a `/`, and a leading `.` is matched like any other character, so
`*` and `?` match dot names. A segment that is exactly `**` matches any
number of whole segments, none included, so `a/**/b` matches `a/b`, but
it never consumes a segment that starts with `.` unless that segment is
the last of a path not ending in `/`: `**/*` matches `a/.x` and not
`.git/x`. A literal segment such as `.git` matches as written, so
`.git/**` matches `.git/objects/x` and not `.git/.hidden/x`. `**` inside
a longer segment acts as `*`. A pattern ending in `/` names directories
and matches only a path ending in `/`; a pattern without one ignores a
trailing `/` on the path. There are no braces, character classes or
escapes. The empty pattern matches only the empty path.

```medaka
> matchGlob "*.mdk" "a.mdk"
True
> matchGlob "*.mdk" "sub/a.mdk"
False
> matchGlob "a/**/b" "a/b"
True
> matchGlob "a/**/b" "a/x/y/b"
True
> matchGlob "a/**" "a/x/y"
True
> matchGlob "?.txt" "a.txt"
True
> matchGlob "?.txt" "ab.txt"
False
> matchGlob "a/b.txt" "a/b.txt"
True
> matchGlob "a**b" "axyb"
True
> matchGlob "a**b" "ax/yb"
False
> matchGlob "*" ".hidden"
True
> matchGlob "*/config" ".git/config"
True
> matchGlob "**/x" ".git/x"
False
> matchGlob "**/.x" "a/.x"
True
> matchGlob "**/*" "a/.x"
True
> matchGlob "**/*" ".git/x"
False
> matchGlob ".git/**" ".git/objects/x"
True
> matchGlob ".git/**" ".git/.hidden/x"
False
> matchGlob "sub/*/" "sub/d/"
True
> matchGlob "sub/*/" "sub/f"
False
> matchGlob "src/**/" "src/"
True
> matchGlob "/a/*" "/a/b"
True
> matchGlob "/a/*" "a/b"
False
> matchGlob "a/*" "a/b/"
True
> matchGlob "" ""
True
> matchGlob "" "a"
False
> matchGlob "*a*a*a*a*a*a*b" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
False
```

### `globReaches`

```
globReaches : String -> String -> Bool
globReaches pattern dir
```

Whether some path strictly below the directory `dir` can match `pattern`.

`**` is not allowed to pass through a dot directory, so a walk can leave
such a directory unentered when this is `False` for it.

```medaka
> globReaches "**/x" ".git"
False
> globReaches ".git/**" ".git"
True
> globReaches "*/config" ".git"
True
```

## Predicates

### `isAbsolute`

```
isAbsolute : String -> Bool
isAbsolute path
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
stripPrefix prefix path
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
normalize path
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

