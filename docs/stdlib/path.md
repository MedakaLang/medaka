# path

## `dirname`

```
dirname : String -> String
```

Directory portion of a path — everything up to (not including) the final
`/`. `"."` if the path has no `/`. A trailing `/` is ignored (the last
segment before it is still stripped as the basename).

```medaka
> dirname "a/b/c.txt"
"a/b"
```

```medaka
> dirname "c.txt"
"."
```

## `basename`

```
basename : String -> String
```

Final path component — the text after the last `/` (the whole string if
there is none). A trailing `/` yields `""`, matching `path.Base`'s sibling
`path.Split` semantics (use `normalize` first if you want `basename` to
ignore a trailing slash).

```medaka
> basename "a/b/c.txt"
"c.txt"
```

```medaka
> basename "c.txt"
"c.txt"
```

```medaka
> basename "a/b/"
""
```

## `extname`

```
extname : String -> String
```

Extension of the final component, dot included (`""` if none). See the
module doc-comment for the exact dotfile convention.

```medaka
> extname "a/b/c.txt"
".txt"
```

```medaka
> extname "README"
""
```

```medaka
> extname ".bashrc"
""
```

## `stem`

```
stem : String -> String
```

Final component with its extension removed (the module-doc convention's
`""` extension leaves `stem` unchanged, e.g. dotfiles).

```medaka
> stem "a/b/c.txt"
"c"
```

```medaka
> stem ".bashrc"
".bashrc"
```

## `hasExtension`

```
hasExtension : String -> String -> Bool
```

`True` if the final component has extension `ext` (leading dot optional
on either side — `hasExtension "txt"` and `hasExtension ".txt"` both match).

```medaka
> hasExtension "txt" "a/b.txt"
True
```

```medaka
> hasExtension ".md" "a/b.txt"
False
```

## `withExtension`

```
withExtension : String -> String -> String
```

Replace the final component's extension with `ext` (leading dot on `ext`
is optional). If the path has no extension, `ext` is appended.

```medaka
> withExtension ".md" "a/b.txt"
"a/b.md"
```

```medaka
> withExtension "md" "a/b"
"a/b.md"
```

## `joinPath`

```
joinPath : String -> String -> String
```

Join two path segments with a single `/`, collapsing any slashes already
present at the boundary. An empty first (or second) segment is skipped.

```medaka
> joinPath "a/b" "c.txt"
"a/b/c.txt"
```

```medaka
> joinPath "a/b/" "/c.txt"
"a/b/c.txt"
```

```medaka
> joinPath "" "c.txt"
"c.txt"
```

## `joinAll`

```
joinAll : List String -> String
```

Join every segment in order with `joinPath`; `""` for the empty list.

```medaka
> joinAll ["a", "b", "c.txt"]
"a/b/c.txt"
```

```medaka
> joinAll []
""
```

## `segments`

```
segments : String -> List String
```

Split a path into its non-empty `/`-separated components (no `.`/`..`
resolution — use `normalize` first if you want those collapsed).

```medaka
> segments "a/b/c.txt"
["a", "b", "c.txt"]
```

```medaka
> segments "/a//b/"
["a", "b"]
```

## `isAbsolute`

```
isAbsolute : String -> Bool
```

`True` if the path starts with `/`.

```medaka
> isAbsolute "/a/b"
True
```

```medaka
> isAbsolute "a/b"
False
```

## `stripPrefix`

```
stripPrefix : String -> String -> Option String
```

Drop `prefix` from the front of `path` if `path` starts with it at a
whole component boundary (i.e. right after `prefix` comes either the end
of the string or a `/`); `None` when it does not.

Returns `Option` for the same reason `string.stripPrefix` does (#2310): the
old fail-soft form returned the input path on no-match, which is also what
a successful strip of `""` returns, so a caller could not tell the two
apart.  The empty prefix strips nothing and succeeds.

```medaka
> stripPrefix "a/b" "a/b/c.txt"
Some "c.txt"
```

```medaka
> stripPrefix "a/x" "a/b/c.txt"
None
```

```medaka
> stripPrefix "a/b" "a/b"
Some ""
```

```medaka
> stripPrefix "" "a/b"
Some "a/b"
```

## `normalize`

```
normalize : String -> String
```

Lexically simplify a path (Go `path.Clean` semantics — see the module
doc-comment): collapses repeated `/`, drops `.` segments, resolves `..`
against a preceding real segment, and drops a trailing `/`. The empty path
becomes `"."`.

```medaka
> normalize "a//b/./c/../d"
"a/b/d"
```

```medaka
> normalize "../a/../../b"
"../../b"
```

```medaka
> normalize "/../a"
"/a"
```

```medaka
> normalize ""
"."
```

