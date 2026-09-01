# Medaka Guide — Outline

A high-level overview / quickstart aimed at people who already know how to
program. Goal: get a reader productive and able to read Medaka code fast.
We teach *Medaka's way*, not programming from first principles.

Structure: **Foundations** (1–3) → **Medaka's worldview** (4–6) →
**Medaka's bets** (7–8) → **Scaling up** (9–10).

---

## 0. Introduction — "What is Medaka?"
*File slug and H1 both landed as `00-introduction.md` / "Introduction" — simpler
than "Landing" and this is the authority now, not the header above.*
Positioning, a "what you get" feature list, a 15-line taste example, who this is
for, and a map of the docs that follow.
- Introduce: the pitch; a personality example (ADT + match + pipe + interp +
  bare IO block), unexplained; "you know programming, we teach Medaka."
- Also carries: a short "Why Medaka?" origin/motivation essay, placed after the
  taste example — not in the original plan, but a reasonable editorial addition
  rather than drift worth fighting.
- Defer: everything else.

## 1. Quickstart — "Your first program"
Working program running in the playground in five minutes.
- Introduce: `main = ...` entry point; **`main` must be a zero-arg value, not
  `main () = ...`** (write `main = ...`). Measured 2026-08-31: the located
  `W-MAIN-SHAPE` diagnostic is a **warning** under `medaka check`, which still
  exits 0; `medaka run` and `medaka build` both exit 1. Say "warning under
  `check`, refused by `run`/`build`", not "rejected"; `println`; comments.
- Defer: modules, types, structure.

## 2. Values, Bindings & Types — "The shape of an expression"
*File slug stays `02-expressions.md`; the H1 is "Values, Bindings & Types" (the
scope below is the authority, not the slug).*
- Introduce: literals; `let ... in`; immutable bindings; mutable state through
  **`Ref` cells, with `:=` to write and `!` to read**; annotations/signatures;
  **inference means you rarely write types, but signatures document**;
  everything-is-an-expression.
- Defer: `Ref` internals, constrained signatures.

## 3. Functions — "Defining and composing behavior"
- Introduce: definitions; **multiple clauses with pattern-matching heads**;
  guards (`| cond = ...`, `otherwise`); lambdas (`x y => body`, **not curried**);
  `where`; prefix application (`f x y`); **pipe `|>`, compose `>> <<`, and
  sections `(+1)`/`(2 * _)`**; `x => match x ...` when a lambda immediately
  eliminates its argument.
- Defer: point-free zealotry.

## 4. Data Modeling — "Types that describe your domain" *(centerpiece)*
- Introduce: `data` sum types (payloads, type params); record-shaped declarations
  such as `data Person = { name : String }` (the word `record` is an ordinary
  identifier, not a declaration keyword); **pattern matching as the eliminator**;
  **exhaustiveness checking**; `Option`/`Result` as the null/exception replacement;
  `deriving`; functional update `{ p | f = v }`.
- Defer: `newtype` (a paragraph), nested-update depth, exhaustiveness internals.

## 5. Interfaces — "Ad-hoc polymorphism, Medaka-style"
- Introduce: `interface` + `impl`; the working vocabulary (`Eq`/`Ord`/`Debug`/
  `Display`/`Num`); **constraints via `=>`**; default methods; conditional impls
  (`impl Eq (List a) requires Eq a`); how `deriving` connects here; automatic
  selection of the most-specific ordinary `impl` when candidates overlap.
- Introduce lightly: `requires` at interface site.
- Defer: dict-passing internals, coherence, higher-kinded interfaces.

## 6. Working with Data — "Collections and the standard library"
- Introduce: `List` vs `Array` (when to reach for which); `Map`/`Set` + literals;
  strings + **interpolation `\{ }` tied to `Display`**; workhorse combinators
  (`map`/`filter`/`fold`) idiomatically with pipes; ranges. A "how do I..." cluster.
- Defer: `hash_map`/`mut_array`/`json`/`byteparser` etc. (link out); Foldable theory.

## 7. Effects & IO — "Doing things in the world" *(the signature chapter)*
Lead with the surprise.
- Introduce: **imperative IO is a bare indented block, not `do`** (IO is not a
  wrapper type here); immutable bindings with mutable `Ref` cells, written
  with `:=` and read with `!` (mutation is untracked — no effect label); **effect rows
  `<IO>`, `<Clock, IO>`** as the "what can this touch" contract — every effect
  label is a host capability; capabilities at a high level. Contrast with
  Haskell `IO a` and with unrestricted side effects.
- Defer: custom `effect` labels, capability platform, effect variables/open rows.

## 8. `do` and Thenables — "Chaining computations that might fail or accumulate"
Deliberately AFTER effects, so `do` is never mistaken for "how you do IO."
- Introduce: `do` over `Option`/`Result` (short-circuit chains); `<-`; `pure`;
  "`do` abstracts over any `Thenable`."
- Defer: writing your own `Thenable`, laws, `Async`.

## 9. Modules & Projects — "Organizing a real codebase"
- Introduce: `import` forms; `export` / `public export` / abstract export;
  `medaka.toml` + layout; `medaka new`.
- Defer: re-export subtleties, cross-package module identity.

## 10. Tooling & Workflow — "The batteries"
- Introduce: `fmt`, `lint`, `check`, `test` (**doctests + `prop` tests**), `repl`;
  how these map to the playground. Doctests get a real example.
- Defer: `build`/backend/LLVM/WasmGC (appendix at most).

---

## Cross-cutting notes
- Chapters **4 and 7** carry the guide — over-invest there, keep the rest lean.
- Hold the **7-before-8** ordering: un-fuse IO from `do` in that order.
- **Out of scope** (link, don't teach): backends, dict-passing internals,
  exhaustiveness algorithm, layout formal rules, capability platform, custom
  effects, `Async`, higher-kinded interfaces, full stdlib list, `Ref` internals.
- **Gotcha callouts** where they arise: `main` must be a value (1); multi-arg
  lambdas aren't curried (3); `<-` forbidden in bare blocks (7/8); indentation
  is significant (1).

### Conventions — settled in chapters 0–2, follow them in 3–10

These are decisions, not suggestions. Read them rather than re-inventing them.

1. **Every example that can run, runs.** A ` ```medaka ` block that has a `main`
   and produces stdout is immediately followed by a ` ```medaka-expect ` block
   holding that stdout verbatim, so `test/check_syntax_examples.sh` executes it
   and diffs the result. Prose between the two ("It prints:") is fine and reads
   well; another fenced block between them is not — the expectation must be the
   next fence. A fragment that genuinely cannot run standalone uses
   ` ```medaka-nocheck: <reason> `, and the reason is a real one.
2. **Never assert output that no expectation backs.** Do not write "this prints
   7" above a bare ` ```medaka ` block. Either attach the expectation, or don't
   claim the output. Same for a claim about the *shape* of a program — if the
   text says "as you can see in the previous example", the previous example had
   better still show it. That sentence rotted once already in chapter 1.
3. **Diagnostics are quoted, never paraphrased.** When a gotcha is worth showing
   the compiler's own words for, run it and paste the real message into an
   indented plain ` ``` ` block (untagged, so it is not treated as an example).
   A paraphrased diagnostic is a claim the gate cannot check.
4. **Gotcha callout style:** a blockquote opening `> ⚠️ **<short imperative>.**`,
   then two or three sentences, then the quoted diagnostic if there is one.
   Reserve it for things that will actually bite — chapter 2 spends one on `!`,
   chapter 1 one on `main`'s shape and one on indentation. More than two per
   chapter and they stop being read.
5. **"Coming from X" sidebar style:** a blockquote opening
   `> **Already comfortable with X?**` or `> **Coming from X?**`, one to three
   sentences, no code fence inside. Use them to *skip* first-principles prose,
   not to add a second explanation of the same thing. The
   [delta sheet](haskell-ocaml-delta.md) carries the systematic Haskell/OCaml
   comparison; sidebars in the chapters are for one-liners only.
6. **Running example: the expense tracker.** Chapter 0's `Expense` / `cost` taste
   example is the seed, and chapter 0 promises the reader it comes back. Pick it
   up in **4** (as the `data` centerpiece — add a record-shaped `Expense` with a
   date and a payee), carry it through **5** (a `Display` impl), **6** (grouping
   and totalling with `map`/`filter`/`fold`), **7** (reading the log from a file,
   with the effect row that implies), and **8** (parsing a line into
   `Result Expense String`). Chapter 3 may borrow `cost` for its multi-clause
   section. Chapters 9–10 are free of it — they are about the toolchain.
7. **Forward links only to files that exist.** `make docs-links` is a hard gate
   and every cited path must resolve. Refer to a not-yet-written chapter by
   number and name in plain prose ("chapter 6 covers…"), and convert it to a real
   link in the slice that creates the file.
8. **`async`/`Async` is not mentioned anywhere in reader-facing chapter prose**, not
   even to say it is out of scope. It is excluded from the documented 0.1.0 surface.
   This outline's own scope notes are the one licensed exception: they name `Async`
   in the per-chapter "Defer" lines and in the out-of-scope list above, because that
   is how the exclusion gets recorded. Nothing in `docs/guide/*.md` other than this
   file may mention it.
9. **`docs/spec/SYNTAX.md` is ground truth**, over this outline and over any
   existing guide prose. Where they disagree, the binary decides and the guide
   gets corrected. `docs/spec/language-design.md` describes unimplemented
   features and is never the authority for a guide claim.
