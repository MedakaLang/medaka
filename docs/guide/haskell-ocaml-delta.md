# For Haskell and OCaml Readers

This is a delta sheet, not a second tutorial. It lists the places where Haskell or
OCaml habits will mislead you in Medaka. For everything else, the
[main guide](00-introduction.md) applies.

## The delta

| Topic | In Medaka | Reference |
|---|---|---|
| Typeclasses | A typeclass is an `interface`; an instance is an `impl`. `requires` on an interface declares a superclass. `requires` on an impl declares the impl's context. | [Interfaces](../spec/SYNTAX.md#interfaces--implementations) |
| Overlapping instances | Allowed. When several impls apply, the unique most-specific one is chosen automatically. Genuine ambiguity is an error. There are no named instances, no `OVERLAPPING` pragmas, and no use-site hints. | [Selection semantics](../spec/DICT-SEMANTICS.md#3-entailment-constructing-evidence) |
| Functor / Monad | The interfaces are `Mappable`, `Applicative`, `Thenable`, `Filterable`, and `Traversable`. The methods are `map`, `pure`, and `andThen` (`>>=` with the arguments swapped). There is no `Functor` or `Monad`, and no `IO` instance of anything. | [Interfaces](../spec/SYNTAX.md#interfaces--implementations) |
| Default methods | A default body lives in the interface, and its signature must mention the interface parameter so dispatch has something to key on. | [Interfaces](../spec/SYNTAX.md#interfaces--implementations) |
| Effects | Effects go on the result arrow: `String -> <IO> String`. A higher-order function can take an effectful argument, `a -> <e> b`, and `<IO \| e>` is an open row. | [Signatures](../spec/SYNTAX.md#type-annotations--signatures) |
| IO and `do` | IO is a plain indented block of statements. `do` is sugar for `Thenable`'s `andThen` and `pure`, and `<-` is legal only inside it. | [`do` notation](../spec/SYNTAX.md#do-notation-do-keyword-required) |
| Mutation | Bindings are immutable. Mutable state is a `Ref a`: build with `Ref value`, write with `:=`, read with prefix `!`. `!` is dereference, not negation; negation is `not`. | [Refs](../spec/SYNTAX.md#refs) |
| Records | No record keyword. A record is a single-constructor `data` with named fields: `data Person = { name : String }`. Field names are scoped to their type. | [Records](../spec/SYNTAX.md#records) |
| Local recursion | `let rec` binds one recursive definition. There is no `and` for mutually recursive local definitions; top-level definitions are mutually recursive without a keyword. | [`let`](../spec/SYNTAX.md#let--mutation) |
| Strings | `String` is not a list of characters. `string.toChars` converts when you need one. | [Working with Data](06-working-with-data.md#strings) |
| Layout | Indentation-based, as in Haskell, but a deeper-indented line can continue an expression rather than open a block, depending on the tokens at the boundary. | [Layout notes](../spec/SYNTAX.md#layout-notes) |
| `deriving` placement | Inline after a one-line `data` declaration. On its own line only when the declaration spans several lines. | [Data types](../spec/SYNTAX.md#data-types) |
| Lambdas | `x y => body`, with no backslash. Multi-parameter lambdas are not curried one arrow at a time. `(x, y) => …` takes a tuple. | [Lambdas](../spec/SYNTAX.md#lambdas) |
| Backtick infix | Removed. Write `f x y`. | [Removed](../spec/SYNTAX.md#removed--do-not-use) |

## One checked example

The general impl applies to every type, but the `Int` impl is the unique most-specific
match, so it wins. The same block then writes and reads a `Ref` before printing:

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

```medaka-expect
specific
2
```

## Quick checks when something feels wrong

- If your instinct says "put the IO in `do`", ask whether you are binding a
  `Thenable` value with `<-`. If not, it belongs in a plain block.
- If your instinct says `let rec … and …`, split it into separate definitions, or
  move them to the top level.
- If instance selection seems to need a name or a pragma, remove it. Write the more
  specific `impl` and let selection pick it.
- If a name you can see is reported as unbound, check indentation before anything
  else.
