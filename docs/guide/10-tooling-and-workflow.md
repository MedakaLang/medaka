# Tooling & Workflow

Every `medaka` verb you've been reading examples through this whole guide — `check`, `run` — is
one binary with several subcommands, and the loop of writing Medaka day to day is mostly `fmt`,
`lint`, `check`, and `test` on repeat, with `repl` for quick experiments. This chapter is a tour
of the box.

## `check` — does it type-check?

You've seen this one everywhere already: `medaka check file.mdk` type-checks a file without
running it, and every ` ```medaka ` block in this guide is checked exactly this way. A type error
looks like this:

```
error: file.mdk:1:16: No impl of Num for String
  |
1 | main = println (1 + "x")
  |                 ^
```

located, with the source line and a caret. `check` exits 0 on success and 1 on the first
accumulated batch of errors — it does not stop at the first one; it collects everything wrong in
the file and reports all of it at once.

## `fmt` — one canonical layout

```
$ medaka fmt --check file.mdk
file.mdk: not formatted
```

```
$ medaka fmt --write file.mdk
formatted 1 file
```

`fmt` is comment-preserving and idempotent — running it twice does nothing the second time. Three
modes: bare (or `--check`) reports which files aren't formatted and changes nothing; `--stdout`
prints the formatted result without writing; `--write` rewrites in place. There is no
configuration — one layout, the same one this guide's own examples are written in.

## `lint` — style rules beyond what types can catch

```
$ medaka lint file.mdk
warning: file.mdk:1:1: [rule-missing-signature] top-level 'double' has no type signature. Add a `double : …` declaration
  |
1 | double x = x + x
  |  ^
```

`lint` runs around twenty rules over your source — dead code, hand-rolled logic that a stdlib
function already does (`rule-stdlib-reimpl`), a `match` that could be a lookup, and more — each
independently `--disable`-able, or promotable to a hard error with `--deny`. Unlike `check`, `lint`
has no type information; its rules work on shape and name, not on what things resolve to.
`--fix` rewrites what it safely can, in place.

## `test` — doctests, `prop`s, and named tests, in one file

`medaka test` runs three different kinds of check that live directly in your source, none of them
needing a separate test file:

- **Doctests** — a comment of the form `-- > expr` followed by `-- expected`, attached to a
  function. `medaka test` synthesizes `debug (expr)`, runs it, and compares.
- **`prop`** — a property, checked against 100 generated inputs by default (`--cases` to change
  that; `--seed` to replay a specific failure).
- **`test "name" = expr`** — a single named assertion, evaluated once. `expr` must have type
  `Expectation`, from [`test.mdk`](../../stdlib/test.mdk) (`import test.{expectEqual, ...}`) —
  not a bare `Bool`.

One file with all three, doctest included:

```medaka
import test.{expectEqual}

-- Sum every element of a list.
--
-- > total [1, 2, 3]
-- 6
-- > total []
-- 0
total : List Int -> Int
total xs = fold (+) 0 xs

test "total of an empty list is 0" = expectEqual 0 (total [])

prop "total splits over ++" (xs : List Int) (ys : List Int) =
  total (xs ++ ys) == total xs + total ys

main = println (total [1, 2, 3])
```

```medaka-expect
6
```

Running `medaka test` on that file:

```
$ medaka test total.mdk
running doctests in total.mdk
  ok   total.mdk:5: total [1, 2, 3]
  ok   total.mdk:7: total []

total.mdk: 2/2 passed
Testing "total splits over ++" ... OK (100 tests)

1 passed, 0 failed
running tests in total.mdk
  running total.mdk:12: total of an empty list is 0
  ok   total.mdk:12: total of an empty list is 0

total.mdk: 1/1 passed
```

Every doctest example ran and matched, the property held over its 100 generated `(xs, ys)` pairs,
and the named test passed. The `main` at the bottom is unrelated to any of this — it's just what
makes the file runnable with `medaka run` too, which is how this guide's own example ran to
produce the `6` above.

By default `test` runs everything through the interpreter (`eval`); `--native` (or
`--engines native`) compiles to a native binary first and runs doctests through that instead
— useful for catching an eval/native divergence, but slower. It has a precondition worth
knowing before you reach for it: the native doctest runner synthesizes its own `main`, so it
refuses any file that already defines one. Run `medaka test --native total.mdk` on the file
above and every doctest errors out:

```
  ERROR total.mdk:5: total [1, 2, 3]
        native doctest runner: SKIPPED total.mdk — it already defines a top-level `main`,
        which the synthesized doctest entry point would collide with. No example was
        executed natively.
  ERROR total.mdk:7: total []
        native doctest runner: SKIPPED total.mdk — it already defines a top-level `main`,
        which the synthesized doctest entry point would collide with. No example was
        executed natively.

total.mdk: 0/2 passed (0 failed, 2 errors)
```

Move the doctested functions into a `main`-free module and `--native` works on that. (`prop`s
and `test "…"`s are unaffected — they run either way.) `--filter <substring>` narrows to
doctests, `test "…"`s, and `prop "…"`s whose name (or, for a doctest, its input expression)
contains the substring.

## `repl` — quick experiments

```
$ medaka repl
medaka repl (:quit to exit, :reset to clear session)
> 1 + 1
2 : Int
> "hi" ++ " there"
hi there : String
> :quit
```

Each line is evaluated and its value and type printed. `:reset` clears everything you've bound so
far in the session; `:quit` or closing stdin (Ctrl-D) ends it. There's no persistence between
sessions, and no module-loading — it's for a quick "what does this expression do," not for
building anything.

## The playground

Everything above is the local CLI. The [playground](https://medaka-lang.dev) is the same compiler
— compiled to WasmGC and running entirely in your browser, no server involved — but it exposes
only one action: edit, hit Run, see output. That's roughly `medaka run`, sandboxed in a Web
Worker; there's no `fmt`, `lint`, `test`, or project layout in the browser, because there's no
filesystem for a project to live in. Use the playground to try something in five seconds with
nothing installed — the [quick start](01-quick-start.md) is written around exactly that — and
reach for the CLI once you're keeping the code.

## `build`

One tool this chapter has deliberately said almost nothing about: `medaka build` compiles to a
native binary through an LLVM backend (there's a second, WasmGC, backend behind the scenes too —
it's what the playground runs). Backend internals, and everything about how either one turns
checked source into machine code, are out of scope for this guide.

---

That's the whole tour: a language ([chapters 1](01-quick-start.md)–[8](08-do-and-monads.md)), how
to arrange it in files (chapter 9), and the tools that check, format, and test what you wrote
(this chapter). From here, [`docs/spec/SYNTAX.md`](../spec/SYNTAX.md) is the precise reference for
what the compiler accepts, and the [stdlib docs](../stdlib/STDLIB.md) cover what ships beyond the
prelude.
