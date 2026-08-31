# Modules & Projects

Every example so far has lived in one file. Real programs don't: [chapter 8](08-do-and-monads.md)'s
`report`/`parseExpense` split naturally into "the parsing logic" and "the thing that runs it," and
a codebase that grows keeps splitting along those lines. This chapter is about the seam: how a
file becomes a module, how one module reaches into another, and how a directory becomes a project
`medaka` recognizes.

## A file is a module

There is no `module` keyword. Every `.mdk` file is a module, named after its path relative to the
project root: `shapes.mdk` is module `shapes`, `net/http.mdk` is module `net.http`. Nothing in the
file declares this — the filename and location *are* the identity.

By default a declaration is private to its file. Two keywords change that:

- **`export`** in front of a declaration makes it visible to importers.
- **`import`** pulls another module's exports into the current file.

## Importing

`import` has four shapes, and they answer different questions: *which names do I want*, and *do I
want them qualified*.

```medaka-project
-- file: greet.mdk
export hello = "hello"
export bye = "bye"

-- file: main_single.mdk
import greet.hello                  -- one name
main = println hello

-- file: main_group.mdk
import greet.{hello, bye}           -- several names
main = println (hello ++ " / " ++ bye)

-- file: main_wildcard.mdk
import greet.*                      -- every export
main = println hello
```

`import greet.hello` and `import greet.{hello, bye}` are the ones to reach for day to day —
selective imports read as documentation of what a file actually uses. `import greet.*` pulls in
everything, which is convenient for a small module and a habit to drop once a module grows past a
handful of exports (a later addition to `greet.mdk` can now silently shadow something).

There is a fifth shape, and it looks like it should be the simplest — importing a module with no
names at all:

```medaka-nocheck: fragment referring to the greet module above, not standalone
import greet
```

> ⚠️ **A bare `import` binds no names, but it is not a no-op.** `import greet` alone does not put
> `hello` or `bye` in scope, and reaching for `greet.hello` does not rescue it — only *aliased*
> imports support the `Module.name` qualifier (see below), so the module name itself is not a
> value and the reference fails to resolve:
>
> ```
> ./main.mdk:3:15: Unbound variable: greet. 'greet' is an imported module, not a value — a
> bare 'import greet' binds no names. Bind what you need: 'import greet.{name, ...}', or
> 'import greet as M' then 'M.name'
> ```
>
> What a bare import *does* do is bring that module's `impl`s into the dispatch table for the
> rest of the file. If
> `greet.mdk` defines `impl Display Message`, importing `greet` — even with no names — is what
> makes `display someMessage` resolve, for any `Message` value already in scope some other way.

That last point is worth seeing work, because "no names bound" reads like "nothing happened":

```medaka-project
-- file: widget.mdk
public export data Widget = Widget Int

-- file: display_widget.mdk
import widget.{Widget}

impl Display Widget where
  display (Widget n) = "widget#\{n}"

-- file: main.mdk
import widget.{Widget(..)}
import display_widget

main = println (display (Widget 5))
```

```medaka-expect
widget#5
```

Delete the `import display_widget` line and the program still compiles the value `Widget 5` just
fine — `Widget` came from `widget`, imported directly — but the `println (display ...)` call now
fails, because the only `impl Display Widget` in the program is one nothing has told this file
about:

```
error: ./main.mdk:3:16: No impl of Display for Widget; add 'deriving Display' to the 'Widget' type, or write an 'impl Display Widget'.
  |
3 | main = println (display (Widget 5))
  |                 ^
```

Any import form — bare, selective, wildcard, or aliased — has this effect; it isn't a special
behavior of the bare form, just the one place it's easy to miss because there's no bound name to
point at.

### Aliasing (`as`)

Two modules exporting the same name collide if you import both unqualified. Aliasing resolves it:

```medaka-project
-- file: red.mdk
export paint = "red"

-- file: blue.mdk
export paint = "blue"

-- file: main.mdk
import red as R                     -- module alias: refer to R.paint
import blue.{paint as bluePaint}    -- member alias: rename one import

main = println (R.paint ++ "/" ++ bluePaint)
```

```medaka-expect
red/blue
```

An alias **replaces** the unqualified import — `import red as R` does not also bind bare `paint`.
A module alias (`as R`) must be Uppercase, since it's used as a qualifier (`R.paint`); a member
alias (`as bluePaint`) renames one imported value. Only values can be aliased or qualified this
way — `import colors as C` then referring to a type as `C.Color` does not parse; import a type by
its own name (`import colors.{Color(..)}`) instead. And you cannot combine a group or wildcard
import with an alias (`import m.{a} as A` is rejected) — the group already binds its names
unqualified, so pairing it with a qualifier is contradictory.

## Exporting

`export` in front of most declarations — a binding, an `interface`, an `impl`, a `type` alias, an
`extern` — is unconditional: the declaration becomes visible under its own name, in full.

`data` is the one exception, because a type and its constructors are two different things to make
visible. `public export data` exports both; plain `export data` exports the type only, keeping
its constructors private — an **abstract** export.

```medaka-project
-- file: account.mdk
public export data Point = Point Int Int   -- type + constructors, fully public

export data Account = Account Int          -- type only; constructors stay private

export mkAccount : Int -> Account
mkAccount n = Account n

export balanceOf : Account -> Int
balanceOf (Account n) = n

-- file: main.mdk
import account.{Point(..), Account, mkAccount, balanceOf}

main = println (balanceOf (mkAccount 100))
```

```medaka-expect
100
```

`Point(..)` works because `Point` is `public export`. Try the same `(..)` on the abstractly
exported `Account` — `import account.{Account(..)}` — and the compiler refuses it before your
code even runs, rather than letting you write an unbuildable pattern match:

```
./main.mdk:1:16: 'Account' exports no constructors from module 'account' (exported abstractly). Remove `(..)` or export with `public export`
```

This is the module-boundary version of the encapsulation [chapter 4](04-data-modeling.md) covered
inside one file: an abstract export lets `account.mdk` change how `Account` is represented later
without breaking anyone who only ever called `balanceOf`.

You can also re-export something you imported, with `export import`:

```medaka
export import list.{reverse, take}
```

now importers of *this* module see `reverse`/`take` as if this module had defined them. Re-export
subtleties — what happens when the name you're re-exporting itself came from somewhere else again
— are outside this guide's scope; [`docs/spec/SYNTAX.md`](../spec/SYNTAX.md) has the details.

## `medaka.toml` and project layout

A directory becomes a *project* by containing a `medaka.toml`. That file is what makes import
paths meaningful — they resolve relative to the directory it's in, not to the file doing the
importing — and it's the anchor `medaka` walks upward from an entry file to find.

`medaka new <name>` scaffolds one:

```
$ medaka new expenses
Created expenses/
```

```
expenses/
├── .gitignore
├── README.md
├── main.mdk
└── medaka.toml
```

```toml
[package]
name = "expenses"
version = "0.1.0"
entry = "main.mdk"
```

and `main.mdk` is a working, if minimal, starting point:

```medaka
main : <IO> Unit
main = println "Hello, Medaka"
```

```medaka-expect
Hello, Medaka
```

There's no mandated subdirectory layout — a small project keeps every `.mdk` file flat next to
`medaka.toml`, the way the running examples in this guide do; a larger one is free to nest modules
into directories, since a module's identity comes from its path (`net/http.mdk` is module
`net.http`) regardless of nesting depth. `medaka.toml` can also declare a `[dependencies]` section
pointing at sibling project directories, and a `[foreign-libraries]` section for `<FFI>` link
targets — both are project-scaling features this guide doesn't cover; treat their presence as a
sign a project has outgrown a single directory.

---

Everything up to here has been the language itself and how to arrange it in files. The last
chapter turns to the tools that check, format, and test what you've written — the loop you'll
actually run while writing Medaka.
