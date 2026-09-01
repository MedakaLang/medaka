# Modules & Projects

Every example so far has been one file. This chapter is about splitting a program
across several: how a file becomes a module, how one module uses another, and what
makes a directory a project.

## A file is a module

There is no `module` keyword. Every `.mdk` file is a module, named by its path
relative to the project root: `shapes.mdk` is the module `shapes`, and
`net/http.mdk` is `net.http`.

A declaration is private to its file unless you mark it. Two keywords cross the
boundary:

- `export` in front of a declaration makes it visible to other modules.
- `import` brings another module's exports into the current file.

## Importing

`import` has several shapes, which differ in which names they bind and whether the
names are qualified.

```medaka-project
-- file: greet.mdk
export hello = "hello"
export bye = "bye"

-- file: main_single.mdk
import greet.hello  -- one name
main = println hello

-- file: main_group.mdk
import greet.{hello, bye}  -- several names
main = println (hello ++ " / " ++ bye)

-- file: main_wildcard.mdk
import greet.*  -- every export
main = println hello
```

Day to day, use `import greet.hello` and `import greet.{hello, bye}`. A selective
import documents what the file uses. `import greet.*` is convenient for a small
module and worth dropping once the module grows: a later addition to `greet.mdk`
can collide with a name from another import, which is an error at the use site, or
be silently hidden by a local definition with the same name.

### Aliases

Two modules that export the same name collide if both are imported unqualified. An
alias resolves it:

```medaka-project
-- file: red.mdk
export paint = "red"

-- file: blue.mdk
export paint = "blue"

-- file: main.mdk
import red as R  -- module alias: refer to R.paint
import blue.{paint as bluePaint}  -- member alias: rename one import

main = println (R.paint ++ "/" ++ bluePaint)
```

```medaka-expect
red/blue
```

An alias replaces the unqualified import: `import red as R` does not also bind a bare
`paint`. A module alias has to be capitalized, since it is used as a qualifier. A
member alias renames one imported value.

There are two limits. An alias qualifies values only, so `C.Color` in a type does not parse;
import a type by its own name, `import colors.{Color(..)}`. And an alias cannot be
combined with a group or wildcard import, since those already bind their names
unqualified.

### A bare import binds nothing, but it is not a no-op

```medaka-nocheck: fragment referring to the greet module above
import greet
```

This form binds no names. `hello` is not in scope afterwards, and `greet.hello` does
not work either, because only aliases support the `Module.name` qualifier:

```
./main.mdk:3:15: Unbound variable: greet. 'greet' is an imported module, not a value — a
bare 'import greet' binds no names. Bind what you need: 'import greet.{name, ...}', or
'import greet as M' then 'M.name'
```

What any import does, including this one, is bring the module's `impl`s into scope
for the rest of the file. If `greet.mdk` defines `impl Display Message`, importing
`greet` in any form is what makes `display` work on a `Message` here. That matters
when a type and its implementations live in different files:

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

Delete the `import display_widget` line and `Widget 5` still compiles, since
`Widget` comes from `widget`. The `display` call no longer does, because the only
`impl Display Widget` in the program is in a file this one no longer imports:

```
error: ./main.mdk:3:16: No impl of Display for Widget; add 'deriving Display' to the 'Widget' type, or write an 'impl Display Widget'.
  |
3 | main = println (display (Widget 5))
  |                 ^
```

## Exporting

`export` in front of a binding, an `interface`, an `impl`, or a `type` alias makes it
visible under its own name.

`data` gets one extra distinction, because a type and its constructors are separate
things to expose. `public export data` exports both. Plain `export data` exports the
type only and keeps the constructors private, which is called an abstract export.

```medaka-project
-- file: account.mdk
public export data Point =
  | Point Int Int  -- type and constructors

export data Account =
  | Account Int  -- type only; the constructor stays private

export
mkAccount : Int -> Account
mkAccount n = Account n

export
balanceOf : Account -> Int
balanceOf (Account n) = n

-- file: main.mdk
import account.{Point(..), Account, mkAccount, balanceOf}

main = println (balanceOf (mkAccount 100))
```

```medaka-expect
100
```

`Point(..)` imports the type with its constructors, and works because `Point` was
exported with `public`. Trying the same on `Account` is refused at the import:

```
./main.mdk:1:16: 'Account' exports no constructors from module 'account' (exported abstractly). Remove `(..)` or export with `public export`
```

An abstract export is how a module keeps control of a type's representation.
`account.mdk` can change what an `Account` is made of later, and nothing that only
ever called `mkAccount` and `balanceOf` has to change.

To re-export something you imported, write `export import`:

```medaka
export import list.{reverse, take}
```

Importers of this module then see `reverse` and `take` as if it had defined them.

## `medaka.toml` and project layout

A directory becomes a project by containing a `medaka.toml`. Import paths resolve
relative to that directory, and `medaka` finds it by walking up from the file you
give it. `medaka new` creates one:

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

The generated `main.mdk` runs as is:

```medaka
main : <IO> Unit
main = println "Hello, Medaka"
```

```medaka-expect
Hello, Medaka
```

There is no required directory layout. A small project keeps its `.mdk` files next
to `medaka.toml`. A larger one can nest them, since a module's name comes from its
path. `medaka.toml` can also list `[dependencies]` on sibling projects and
`[foreign-libraries]` to link against, neither of which this guide covers.

---

The last chapter, [Tooling & Workflow](10-tooling-and-workflow.md), is about the
commands you run while writing Medaka: checking, formatting, linting, and testing.
