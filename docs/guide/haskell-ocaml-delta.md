# Medaka for Haskell and OCaml Readers

This is a delta sheet, not a second tutorial. It names the places where
Haskell or OCaml instincts are most likely to mislead you; the rest of the
[main guide](00-introduction.md) remains the default route. A Python-first
(tier-1) route is deliberately deferred until real reader evidence shows what
it needs—it is not an unfinished guide hidden elsewhere.

## The delta

| Topic | Medaka today | Current authority |
|---|---|---|
| Interfaces and impls | A typeclass is an `interface`; instances are ordinary `impl`s. `requires` on an interface declares a superclass, while `requires` on an impl declares the impl's context. Overlap is allowed only when selection has a unique most-specific match; Medaka chooses that match automatically and rejects ambiguity. | [Syntax forms](../spec/SYNTAX.md#interfaces--implementations); [selection semantics](../spec/DICT-SEMANTICS.md#3-entailment-and-evidence-resolution) |
| Removed dispatch syntax | Named impls, `default impl`, and `@Name` use-site hints are gone. Write a plain `impl`; there is no name or hint to select manually. | [Interfaces and implementations](../spec/SYNTAX.md#interfaces--implementations) |
| Default methods | A default method body lives in the `interface`, but its signature must mention the interface parameter so dispatch has the required type connection. | [Interfaces and implementations](../spec/SYNTAX.md#interfaces--implementations) |
| Effect rows | Effects decorate the result arrow: `String -> <IO> String`. Higher-order functions can accept an effectful function such as `a -> <e> b`, and `<IO \| e>` is an open row with tail `e`. | [Type annotations and signatures](../spec/SYNTAX.md#type-annotations--signatures) |
| IO and `do` | Sequence ordinary IO in a bare indented block. `do` is monadic sugar for `andThen`/`pure`, not an IO wrapper; it is required when using `<-`, which is forbidden in a bare block. | [`do` notation](../spec/SYNTAX.md#do-notation-do-keyword-required) |
| Mutation | Bindings stay immutable. Mutable state lives in `Ref a`: construct with `Ref value`, write with `:=`, and read with prefix `!`. Here `!` is dereference, not Boolean negation (`not`). | [Refs](../spec/SYNTAX.md#refs) |
| Records | There is no record declaration keyword. A record is a single-constructor `data` declaration with named fields, for example `data Person = { name : String }`. | [Records](../spec/SYNTAX.md#records) |
| Local recursion | `let rec` binds exactly one recursive binding. There is no OCaml-style `with` group for mutually recursive local definitions. | [`let` and mutation](../spec/SYNTAX.md#let--mutation) |
| Layout | Blocks use indentation and lexer-produced `INDENT`/`DEDENT`/`NEWLINE`, not explicit braces. Deeper indentation can instead continue an expression according to Medaka's continuation rules, so do not infer layout solely from visual nesting. | [Layout notes](../spec/SYNTAX.md#layout-notes); [formal layout semantics](../spec/LAYOUT-SEMANTICS.md) |
| `deriving` placement | Keep `deriving (...)` inline after a one-line `data` declaration. It may occupy its own indented line only when the declaration itself is multi-line. | [Data types](../spec/SYNTAX.md#data-types) |
| Reserved words | Do not paste a keyword list or count into notes or tooling. Derive the lexer keywords and the parser's reserved-identifier subset with the commands in the syntax specification. | [Reserved words and derivation commands](../spec/SYNTAX.md#reserved-words--keywords) |

## One checked example

The generic impl is applicable to every type, but the `Int` impl is the unique
most-specific match. The same bare block then mutates and reads a `Ref` before
performing IO:

```medaka
interface GuideKind a where
  guideKind : a -> String

impl GuideKind a where
  guideKind _ = "general"

impl GuideKind Int where
  guideKind _ = "specific"

main =
  let count = Ref 1
  count := !count + 1
  println (guideKind (1 : Int))
  println !count
```

Its output is:

```medaka-expect
specific
2
```

## Fast migration checks

- If Haskell intuition says “put IO in `do`,” ask whether you are actually
  binding a monadic value with `<-`. Plain effectful statements belong in a
  bare block.
- If OCaml intuition says `let rec ... and ...`, split the design: Medaka's
  local recursive form owns one binding and has no grouping keyword.
- If instance selection seems to need a name, remove the name or hint. The
  accepted program must have one most-specific matching impl instead.
- If an identifier produces a surprising layout error, derive the current
  reserved spellings from the lexer/parser commands before diagnosing layout.
