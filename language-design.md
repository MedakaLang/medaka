# Medaka Language Design Document
*A pragmatic, modern functional programming language*

---

## Vision & Philosophy

This language is best described as sitting at the intersection of three existing languages:

- **A modernized, cleaned-up OCaml** — keeping strict evaluation and pragmatism, replacing dated syntax and the object system
- **A practical Haskell** — keeping the type system and syntax elegance, removing laziness and the IO monad tax
- **A more functional, garbage-collected Rust** — keeping the trait/typeclass model and algebraic data types, removing the borrow checker complexity

The north star: **the language a pragmatic functional programmer would design if they could start fresh today.** Informed by research languages (OCaml, Haskell, Idris), not beholden to them. Every feature must earn its complexity in practical daily use.

**Key design filter:** *Does this feature earn its complexity in practical use, or is it just theoretically neat?*

### Influences
- **OCaml** — strict evaluation, pragmatic side effects, practical functional programming
- **Haskell** — type system, typeclasses, syntax, higher-kinded types, do-notation
- **Idris** — cleaned-up Haskell syntax, named interface instances, modern design sensibilities
- **Rust** — traits/typeclasses, ADTs, module system, Result-based error handling
- **Elm** — record syntax, friendly error messages, accessibility of concepts
- **F#** — practical ML-family language targeting a real ecosystem

---

## Type System

### Core
- **Hindley-Milner with System F** parametric polymorphism
- Full **type inference** — type annotations are optional in most cases
- **Higher-kinded types** — the one advanced feature, justified by enabling user-defined abstractions like `Functor`, `Monad`, `Traversable`
- "**If it compiles, it runs**" — a core property inherited from the HM family

### Interfaces (Typeclasses)
- Called **interfaces**, not typeclasses (more accessible terminology)
- Full Haskell-style power, including higher-kinded types
- Enables user-defined `Functor`, `Monad`, etc. — monads are available as a pattern, not mandatory

### Named Instances with Defaults
Solves Haskell's coherence problem without sacrificing inference:

- One instance → resolved automatically
- Multiple instances → one can be marked `default`, used unless annotated otherwise
- Multiple instances, no default → compiler requires explicit annotation

```
interface default Additive of Monoid Int where ...
interface Multiplicative of Monoid Int where ...

sum [1, 2, 3]              -- uses Additive automatically
fold @Multiplicative [1, 2, 3]  -- explicit opt-out
```

This eliminates the `newtype` hack entirely.

### Friendly Naming
Abstract concepts get accessible names:
- `interface` instead of typeclass
- `Option` / `Some` / `None` instead of `Maybe` / `Just` / `Nothing`
- `Mappable` instead of `Functor` (where surfaced to users)
- `flatMap` / `andThen` as primary operation names rather than `>>=`

### Explicitly Out of Scope
- GADTs
- Existential types
- Dependent types
- Anything that significantly damages inference or error message quality

### Error Message Quality
First-class design goal. Elm-style friendly, actionable error messages. The compiler should explain what went wrong and why, not just dump a type unification failure.

---

## Syntax

### General Principles
- **Indentation-sensitive** (Haskell/Idris/Python style) — no braces for blocks
- **Expression-oriented** — everything is an expression
- **Declarative** — functions defined by pattern matching, not imperative steps
- **Accessible** — no insider notation, names over symbols

### Type Annotations
Idris-style single colon:
```
x : Int
greet : String -> String
add : Int -> Int -> Int
```

### Function Definition
Declarative pattern matching style — no `match` keyword needed:
```
factorial : Int -> Int
factorial 0 = 1
factorial n = n * factorial (n - 1)

head : List a -> Option a
head []     = None
head (x::_) = Some x
```

### Currying
Functions are curried by default. Partial application falls out naturally:
```
add : Int -> Int -> Int
add x y = x + y

addFive : Int -> Int
addFive = add 5

result = map (add 5) [1, 2, 3]  -- [6, 7, 8]
```

Tuples are regular data, not special argument syntax. Passing multiple values as a unit means wrapping in a tuple explicitly.

### Lambda Syntax
Fat arrow `=>` for lambda bodies, thin arrow `->` reserved for type signatures:
```
x => x + 1
(x, y) => x + y

-- distinction is clear at a glance
add : Int -> Int -> Int    -- type signature
add = (x, y) => x + y     -- lambda
```

### Operators
- **Fixed set of built-in symbolic operators:** `+`, `-`, `*`, `/`, `==`, `<`, `>`, `&&`, `||`, `::` (cons), `++` (append), etc.
- **No custom symbolic operators** — eliminates unreadable operator soup
- **Named functions can be used infix** via backticks:

```
x `div` y
x `andThen` f
3 `elem` [1, 2, 3]
```

Functions always have real names. Infix is a calling convenience, not a way to invent hieroglyphics.

### Do Notation
General monad abstraction, not tied to effects:
```
result =
  x <- computation1
  y <- computation2 x
  pure (x + y)
```

`do` is for abstracting over monadic patterns (Option, Result, custom monads) — not a required wrapper for side effects.

---

## Data Types

### Sum Types (`data`)
```
data Shape
  = Circle Float
  | Rectangle Float Float
  | Triangle Float Float Float

area : Shape -> Float
area (Circle r)      = pi * r * r
area (Rectangle w h) = w * h
```

### Product Types (`record`)
```
record Person
  name : String
  age  : Int
```

- **Dot access** for fields: `person.name`
- **Immutable update syntax** (Elm-style):
  ```
  let p2 = { p | age = 31 }
  ```
- **Construction requires all fields** — no partial construction, no runtime surprises
- **Fields are namespaced** to the type — no global namespace pollution

### Combining Them
```
record Point2D
  x : Float
  y : Float

data Shape
  = Circle Float
  | Rectangle Float Float
  | Positioned Point2D Float
```

`data` and `record` are kept clearly separate. Pattern matching on `data` is always positional. Named field access is always through `record` via dot notation.

---

## Error Handling

No exceptions. Two distinct categories:

### Recoverable Errors → `Result`
```
divide : Int -> Int -> Result Int String
parseJson : String -> Result Json ParseError

match divide 10 0
  Ok n    => print n
  Err msg => print msg
```

Errors are data. Pattern match to handle them. Library authors cannot be lazy and throw — they must model failure explicitly.

### Unrecoverable Errors → `Panic`
For genuine invariant violations, index out of bounds, stack overflow — situations where the program cannot reasonably continue. Tracked as an effect in the type system (see Effects).

---

## Effect System

### Philosophy
Pure by default. Effects are explicit in type signatures. No IO monad infection — you don't have to rewrite your entire call stack to use a side effect deep in your program.

A small, fixed set of built-in effects tracked by the compiler. Not a full algebraic effect system — practical benefit without the complexity tax.

### Built-in Effects
```
IO      -- file system, network, console
Mut     -- mutable state
Async   -- asynchronous computation
Panic   -- unrecoverable errors
Rand    -- randomness / nondeterminism
Time    -- current time / clock access
```

### How It Works
Effects appear in type signatures:
```
readFile  : String -> <IO> String
divide    : Int -> Int -> Result Int String   -- pure, uses Result not Exn
counter   : <Mut> Int
fetchUser : String -> <Async, IO> User
roll      : <Rand> Int
now       : <Time> Timestamp

-- pure function — no annotation, compiler enforces purity
add : Int -> Int -> Int
```

### Rules
- **Pure by default** — no annotation means guaranteed pure, compiler enforced
- **Effects compose automatically** via inference — call an `<IO>` and `<Rand>` function, your function is inferred as `<IO, Rand>`
- **No manual annotation needed in most cases** — inference propagates effects up the call stack
- **Purity is a guarantee** — a function with no effect annotation genuinely cannot do IO, mutate state, etc.

### What This Gives You
- Know what any function can do just from its signature
- Pure functions are trivially testable
- Nondeterminism (`Rand`, `Time`) is visible and can be controlled in tests
- No exceptions — `Exn` replaced entirely by `Result` and `Panic`

---

## Module System

Rust-inspired. Private by default, file structure mirrors module hierarchy.

```
-- src/utils.lang
pub greet : String -> String
greet name = "Hello, " ++ name

internal : String -> String  -- private, not exported
internal s = ...

-- src/main.lang
use utils.greet

main =
  print (greet "Alice")
```

### Rules
- **Private by default** — explicitly `pub` to export
- **File/directory structure = module hierarchy** — intuitive, no separate declaration
- **`use` for imports** — clean and explicit
- **No circular dependencies** — enforced by compiler
- **No first-class modules or functors** — OCaml-style complexity explicitly rejected

### To Be Decided (follow Rust's lead)
- Selective imports: `use utils.{greet, helper}`
- Wildcard imports: `use utils.*`
- Qualified imports: `use utils` then `utils.greet`
- Re-exports for clean public APIs

---

## Implementation Plan

### Phase 1: OCaml-hosted compiler
- Write the compiler in OCaml (fitting given the influence, and Rust did the same initially)
- Transpile to OCaml or interpret directly
- Focus entirely on nailing language design — type system, syntax, semantics
- Do not optimize for performance, codegen, or multiple architecture targets

### Phase 2: Revisit backend if warranted
Once the language design is stable and the project feels worth continuing:
- **LLVM** is the likely long-term target for native compilation
- Could also explore self-hosting — writing the compiler in the language itself
- JVM remains an option if ecosystem access becomes a priority

### Non-goals (for now)
- Performance optimization
- Multiple architecture targets
- Production-ready GC
- Package ecosystem

---

## Standard Library Philosophy

### Core Principle
Batteries included — a rich standard library so most things are available out of the box without reaching for third party packages. Consistent interfaces across all collection types — `map`, `filter`, `fold` work the same way on everything via shared interfaces (`Mappable`, `Foldable`, etc.).

### Collections Hierarchy

#### List — the default sequential collection
Linked list. Immutable. The conceptual entry point for learning Medaka and the natural collection for functional programming. Pattern matches beautifully, structurally recursive. Reach for it when performance isn't a concern.

```
-- natural pattern matching
sum : List Int -> Int
sum []      = 0
sum (x::xs) = x + sum xs

-- standard operations
map (x => x + 1) [1, 2, 3]
filter (x => x > 2) [1, 2, 3]
```

#### Array — immutable, cache-friendly sequential collection
For performance-sensitive code, random access, numeric work. Immutable by default. Array literal syntax: `[|1, 2, 3|]` (borrowed from OCaml, visually distinct from list literals).

```
let arr = [|1, 2, 3|]
arr[0]                        -- 1
map (x => x + 1) arr         -- [|2, 3, 4|], same interface as List
```

#### MutArray — mutable array
Opt-in mutability for performance. Requires `let mut`. Carries `<Mut>` effect.

```
let mut arr = [|1, 2, 3|]
arr[0] = 5                    -- fine, Mut effect tracked
```

Conversion between Array and MutArray:
```
freeze : MutArray a -> Array a         -- zero cost, type change only
thaw   : Array a -> <Mut> MutArray a   -- copies
```

#### Map — immutable tree map
Persistent, structurally shared updates. Efficient for immutable update patterns. Keys require `Hashable` interface.

```
let m = Map { "alice" => 30, "bob" => 25 }
m["alice"]                        -- Some 30
m["charlie"]                      -- None, never a runtime error
m `insert` ("charlie", 35)        -- returns new Map, cheap via structural sharing
```

#### HashMap — mutable hash map
Hash-based, mutable. Requires `let mut`. Carries `<Mut>` effect. Faster for update-heavy code.

```
let mut m = HashMap { "alice" => 30 }
m `insert` ("charlie", 35)        -- mutates in place
```

#### Set and HashSet
Same immutable/mutable distinction as Map/HashMap:
- `Set` — immutable tree set
- `HashSet` — mutable hash set, requires `let mut`

### Mutability Rules
Universal and consistent across all collection types and bindings:

**If mutation happens, `mut` is there. Always. No exceptions.**

```
let x = 5                              -- immutable binding
let mut x = 5                          -- mutable binding

let arr = [|1, 2, 3|]                 -- immutable array
let mut arr = [|1, 2, 3|]             -- mutable array

let m = Map { "alice" => 30 }         -- immutable map
let mut m = HashMap { "alice" => 30 } -- mutable map

let p = Person { name = "Alice", age = 30 }     -- immutable record
let mut p = Person { name = "Alice", age = 30 } -- mutable record
p.age = 31                             -- fine
```

The `mut` keyword and the `<Mut>` effect are two faces of the same concept. Any function that touches a `mut` binding automatically carries `<Mut>` in its inferred type signature.

Practical benefit: grep a codebase for `mut` and find every place mutation is introduced.

### Strings

**Encoding:** UTF-8 internally.

**Abstraction:** Strings are sequences of grapheme clusters, not bytes or code points. `Char` represents a grapheme cluster. No integer indexing — `str[0]` is a compiler error, not a runtime footgun.

```
length "hello"       -- 5
length "👋🏽"         -- 1 (one grapheme cluster, not 4 bytes)
chars "hello"        -- ['h', 'e', 'l', 'l', 'o']
bytes "hello"        -- [|104, 101, 108, 108, 111|]
slice "hello" 1 3    -- "ell"
```

String literals use double quotes. Multiline strings strip leading indentation:
```
let s = "hello"
let multiline = "
  this is
  a multiline string
  "
```

**Why no indexing:** String indexing by integer is almost always a bug waiting to happen in non-ASCII text. Elm takes this approach and it's been validated in practice. Interact with strings through functions — honest about what strings actually are.

### Naming Conventions
- Collection operations are consistent: `map`, `filter`, `fold`, `insert`, `remove`, `contains`
- Backed by shared interfaces (`Mappable`, `Foldable`, etc.) so switching between collection types is low friction — change the data structure, operations stay the same
- Simple, unsurprising names throughout — no Haskell-style operator soup

## Async

`Async` is a monad, not special runtime syntax. Do-notation handles sequencing naturally:

```
fetch : String -> <Async> Response
parse : Response -> <Async> Json

result : <Async> Json
result =
  response <- fetch "https://api.example.com"
  json <- parse response
  pure json
```

The friendly name for the monad interface is **`Thenable`** — familiar to JS developers, descriptive, not academic.

`<Async>` is still tracked as an effect even though it's monad-based. The effect tag and the monad are two views of the same thing — the effect tells you a function can kick off async work, the monad is how you compose it. Consistent with the rest of the effect system.

---

## Module System — Import Details

```
-- selective imports
use utils.{greet, helper}

-- wildcard (available but discouraged in style guides)
use utils.*

-- qualified (no names brought into scope)
use utils
utils.greet "Alice"

-- re-exports (for clean public APIs)
pub use list.{map, filter, fold}

-- aliased imports
use collections.HashMap as HM
```

All follow Rust conventions closely. Wildcard imports are available but style guides should discourage them — makes it hard to know where names come from.

---

## Standard Library

**Philosophy: batteries included, but not to an extreme.**

Rule of thumb: *"Would the absence of this cause every non-trivial project to immediately reach for a third party package?"* If yes → stdlib. If no → ecosystem.

Rough target: Go's stdlib scope, maybe slightly smaller.

### In stdlib:
- Core collections — List, Array, MutArray, Map, HashMap, Set, HashSet
- String utilities — split, trim, join, regex
- Math — standard numeric operations
- IO — file system, stdin/stdout
- Date/Time — too universally needed and historically painful to leave out
- JSON — too ubiquitous to omit
- Basic concurrency primitives
- Testing utilities — built-in test runner

### Left to ecosystem:
- HTTP client/server — too opinionated, let ecosystem compete
- Database drivers
- Serialization formats beyond JSON (YAML, TOML, XML etc.)
- Cryptography — too security-sensitive to get half right
- GUI
- Domain-specific libraries (ML, graphics, etc.)

---

## Open Questions

1. **GC design** — what kind of garbage collector? Depends partly on backend choice. Modern incremental/concurrent GC (OCaml 5, Go) is the reference point.

2. **Algebraic effects** — kept as a future possibility. The current effect system reserves space in the type system, making a future upgrade to full algebraic effects less painful than bolting it on from scratch.

---

## Quick Reference

| Concept | This Language | Haskell | OCaml | Rust |
|---|---|---|---|---|
| Evaluation | Strict | Lazy | Strict | Strict |
| Polymorphism | Interfaces (HKT) | Typeclasses (HKT) | Objects + Modules | Traits |
| Error handling | Result + Panic | Either + exceptions | exceptions | Result + panic |
| Effects | Built-in tracked set | IO Monad | Unrestricted | Unrestricted |
| Memory | GC | GC | GC | Ownership |
| Syntax style | Haskell/Idris | Haskell | ML | C-like |
| Module system | Rust-style | Weak namespacing | Powerful functors | Rust-style |
