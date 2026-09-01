# Tooling & Workflow

Every `medaka` command is a subcommand of one binary. The loop while writing Medaka
is `check`, `fmt`, `lint`, and `test`, with `repl` for quick experiments. This
chapter is a tour of each.

## `check`

`medaka check file.mdk` type-checks a file without running it. Every example in
this guide goes through it. A type error looks like this:

```
error: file.mdk:1:16: No impl of Num for String
  |
1 | main = println (1 + "x")
  |                 ^
```

`check` reports every error it finds in the file, not only the first, and exits 1 if
there were any. Warnings, such as a non-exhaustive match, are printed but do not
change the exit code.

## `fmt`

```
$ medaka fmt --check file.mdk
file.mdk: not formatted
```

```
$ medaka fmt --write file.mdk
formatted 1 file
```

`fmt` produces one canonical layout, preserves comments, and is idempotent. With no
flag or with `--check`, it reports which files are not formatted and changes
nothing. `--stdout` prints the formatted result. `--write` rewrites the file in
place. There are no configuration options. Every example in this guide is in `fmt`'s
layout.

## `lint`

```
$ medaka lint file.mdk
warning: file.mdk:1:1: [rule-missing-signature] top-level 'double' has no type signature. Add a `double : …` declaration
  |
1 | double x = x + x
  |  ^
```

`lint` runs about twenty rules over your source: missing signatures, dead code,
hand-written logic that a standard library function already does, a `match` that
could be a lookup, and so on. Each rule can be turned off with `--disable` or
promoted to an error with `--deny`. `--fix` rewrites what it safely can. Unlike
`check`, `lint` has no type information. Its rules look at the shape of the code and
the names in it.

## `test`

`medaka test` runs three kinds of test, all of which live in the source file next
to the code they test:

- **Doctests.** A comment of the form `-- > expr` followed by `-- expected`, above a
  definition. `medaka test` evaluates the expression, renders the result with
  `debug`, and compares.
- **Properties.** `prop "name" (x : T) … = expr` states something that should hold
  for all inputs. It is checked against 100 generated inputs by default. `--cases`
  changes the count and `--seed` replays a particular run.
- **Named tests.** `test "name" = expr` is one assertion, evaluated once. The
  expression has type `Expectation`, from the `test` module, rather than `Bool`.

One file with all three:

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

Running `medaka test` on it:

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

Both doctests matched, the property held for its 100 generated pairs, and the named
test passed. The `main` at the bottom is there only so the file also runs with
`medaka run`.

By default `test` runs everything through the interpreter. `--native` compiles the
file and runs the doctests through the compiled binary instead, which is slower but
catches a difference between the two engines. It has one precondition: the native
runner generates its own `main`, so it refuses a file that already defines one. On
the file above, `medaka test --native total.mdk` reports every doctest as an error:

```
  ERROR total.mdk:5: total [1, 2, 3]
        native doctest runner: SKIPPED total.mdk — it already defines a top-level `main`,
        which the synthesized doctest entry point would collide with. No example was
        executed natively.
```

Properties and named tests are unaffected and still run. Keep doctested functions
in modules without a `main` if you want to run them natively. `--filter <substring>` narrows a run to the tests whose name, or for a
doctest whose expression, contains the substring.

## `repl`

```
$ medaka repl
medaka repl (:quit to exit, :reset to clear session)
> 1 + 1
2 : Int
> "hi" ++ " there"
hi there : String
> :quit
```

Each line is evaluated and printed with its type. `:reset` forgets everything bound
so far and `:quit` exits. There is no module loading and nothing persists between
sessions. It is for finding out what an expression does, not for building anything.

## The playground

The [playground](https://medaka-lang.dev) is the same compiler, compiled to
WebAssembly and running in your browser with no server. It offers one action: edit,
run, read the output. That is `medaka run` in a sandbox. There is no `fmt`, `lint`,
`test`, or project layout there, because there is no filesystem. Use it to try
something in a few seconds, and switch to the command line once you are keeping the
code.

## `build`

`medaka build file.mdk -o prog` compiles a program to a native executable through
LLVM. A second backend produces WebAssembly, and is what the playground runs on.
How either backend works is outside this guide.

---

Chapters 1 through 8 covered the language, chapter 9 how to arrange
it in files, and this one the tools. From here, the [syntax reference](../spec/SYNTAX.md)
is the precise account of what the compiler accepts, and the
[stdlib reference](../stdlib/index.md) lists what ships beyond the prelude.
