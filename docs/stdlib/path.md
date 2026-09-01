# path

path.mdk — POSIX ("/"-separated) path manipulation.

Pure string work: no filesystem access, no effects, no `IO`. Every function
here treats a path as opaque text and reasons about it lexically, exactly
like Go's `path` package or Python's `posixpath` — it never looks at the
filesystem, so `normalize`/`dirname`/etc. can't tell a real directory from
a dangling symlink.

**Extension convention (documented choice).** `extname` returns the
extension **including** the leading dot (`extname "a.txt" == ".txt"`),
matching Go's `path.Ext` and Python's `os.path.splitext` (whose second
element also keeps the dot). `extname "a" == ""` (no dot ⇒ no extension),
and a leading-dot-only basename is treated as a hidden file with no
extension (`extname ".bashrc" == ""`, `extname "..." == ""`) — the dot must
have at least one non-dot character before it within the basename.

**`normalize` convention** mirrors Go's `path.Clean`:
- Collapse repeated `/`.
- Eliminate `.` segments (except when the whole path is `.`).
- Eliminate `..` together with the preceding non-`..` segment; a leading
`..` on a relative path is kept (can't be resolved without a root);
`..` at the root of an absolute path is dropped (`/..` → `/`).
- The empty path normalizes to `"."`.
- A trailing `/` is dropped unless the result is `/` itself.

This module is the public-API sibling of the compiler-private
`compiler/support/path.mdk` (which stays a minimal internal helper used by
the self-hosted compiler's own module loader) — the two are not merged
because `compiler/` deliberately avoids depending on `stdlib/`'s heavier
surface for its own bootstrap path.

## `dirname`

```
dirname : String -> String
```

Directory portion of a path — everything up to (not including) the final
`/`. `"."` if the path has no `/`. A trailing `/` is ignored (the last
segment before it is still stripped as the basename).


*(doctest — run by `medaka test`)*

```medaka
> dirname "a/b/c.txt"
"a/b"
```

*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

```medaka
> basename "a/b/c.txt"
"c.txt"
```

*(doctest — run by `medaka test`)*

```medaka
> basename "c.txt"
"c.txt"
```

*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

```medaka
> extname "a/b/c.txt"
".txt"
```

*(doctest — run by `medaka test`)*

```medaka
> extname "README"
""
```

*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

```medaka
> stem "a/b/c.txt"
"c"
```

*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

```medaka
> hasExtension "txt" "a/b.txt"
True
```

*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

```medaka
> withExtension ".md" "a/b.txt"
"a/b.md"
```

*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

```medaka
> joinPath "a/b" "c.txt"
"a/b/c.txt"
```

*(doctest — run by `medaka test`)*

```medaka
> joinPath "a/b/" "/c.txt"
"a/b/c.txt"
```

*(doctest — run by `medaka test`)*

```medaka
> joinPath "" "c.txt"
"c.txt"
```

## `joinAll`

```
joinAll : List String -> String
```

Join every segment in order with `joinPath`; `""` for the empty list.


*(doctest — run by `medaka test`)*

```medaka
> joinAll ["a", "b", "c.txt"]
"a/b/c.txt"
```

*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

```medaka
> segments "a/b/c.txt"
["a", "b", "c.txt"]
```

*(doctest — run by `medaka test`)*

```medaka
> segments "/a//b/"
["a", "b"]
```

## `isAbsolute`

```
isAbsolute : String -> Bool
```

`True` if the path starts with `/`.


*(doctest — run by `medaka test`)*

```medaka
> isAbsolute "/a/b"
True
```

*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

```medaka
> stripPrefix "a/b" "a/b/c.txt"
Some "c.txt"
```

*(doctest — run by `medaka test`)*

```medaka
> stripPrefix "a/x" "a/b/c.txt"
None
```

*(doctest — run by `medaka test`)*

```medaka
> stripPrefix "a/b" "a/b"
Some ""
```

*(doctest — run by `medaka test`)*

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


*(doctest — run by `medaka test`)*

```medaka
> normalize "a//b/./c/../d"
"a/b/d"
```

*(doctest — run by `medaka test`)*

```medaka
> normalize "../a/../../b"
"../../b"
```

*(doctest — run by `medaka test`)*

```medaka
> normalize "/../a"
"/a"
```

*(doctest — run by `medaka test`)*

```medaka
> normalize ""
"."
```

