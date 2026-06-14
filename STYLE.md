# Medaka style guide

Conventions for hand-written Medaka source — primarily the self-hosted compiler
(`selfhost/*.mdk`) and stdlib (`stdlib/*.mdk`). These are the rules the formatter
**cannot** enforce (it preserves your choices); they live here so reviewers and
agents apply them consistently. For what the formatter *does* enforce
(indentation, width-breaking, trailing commas, import wrapping) see `fmt`.

> Each entry is a convention, not a hard gate. Prefer it where it improves
> readability; don't force-fit. When you touch nearby code, nudge it toward
> these — don't churn a file wholesale just to conform.

## 1. Block comments for prose; line comments for asides

Use a block comment `{- … -}` for any explanation spanning more than one line —
a function's doc, a paragraph of rationale, a worked example. Reserve `--` line
comments for short single-line asides next to the code they annotate.

A run of three-plus consecutive `--` lines is a smell: it's prose wearing a
line-comment costume. Convert it to one `{- … -}` block. (Watch the
[[mdk_comment_first_line_of_block]] gotcha: a comment can't be the first line of
an indented block — put the block *above* the opening line, not inside it.)

```
-- BAD: prose as a wall of line comments
-- This function lowers guard arms into a nested
-- if/match chain, terminated by a fallthrough
-- sentinel so the fold has a base case.
lowerGuards = …

{- GOOD: prose as one block, attached above the signature
   Lowers guard arms into a nested if/match chain, terminated by a
   fallthrough sentinel so the fold has a base case. -}
lowerGuards = …
```

## 2. Comment placement: whole-function docs above the signature; per-clause notes above the clause

A comment describing *what the function is/does* goes **above its type
signature** (or above the first clause if unsigned) — never wedged between the
signature and the first clause, and never trailing the last clause.

A comment about *one specific clause* (why this case is special, what edge it
handles) goes **immediately above that clause**, indented to match it.

```
{- Desugar a section like `(+ 1)` into a lambda. -}   -- whole-fn: above sig
sectionToCore : Section -> Expr
sectionToCore (SecRight op e) = …
-- left section needs an explicit `_` placeholder           -- clause note: above clause
sectionToCore (SecLeft op e)  = …
```

## 3. Prefer pattern guards over a nested `match`

When a clause's body is a `match` whose only purpose is to test/destructure a
computed value, a **guard** usually reads better — especially a pattern-bind
guard (`Pat <- e`). Function-clause guards (`f n | Some v <- e = v`) fully work
(interp + native, bind reaches the body).

```
-- BAD: match purely to gate one case
classify n =
  match lookup n table
    Some v => use v
    None   => fallback

-- GOOD: pattern-bind guard, function-clause form
classify n
  | Some v <- lookup n table = use v
  | otherwise                = fallback
```

Caveat (see the AGENTS.md guard note): in a **match-arm** guard
(`x if Some v <- e => body`) the bound `v` reaches later guard qualifiers but
**not the arm body** (a resolve bug, both backends). So the match-arm form is
only safe when the bind is consumed inside the guard chain — for bind-in-body,
use the function-clause form above.

## 4. Magic strings: three categories, three treatments

Synthetic string literals in compiler code fall into three kinds — keep them
distinct:

1. **Local synthetic binder names** (`"__fn_arg"`, `"__do_x"`, `"__a"`/`"__b"`,
   `"__r"`). Gensym-style names produced *and consumed* within one desugaring.
   Fine inline; keep the `__`-prefix and make the stem name the site
   (`__lc_x` = list-comprehension scrutinee). They never cross a module boundary,
   so a local literal is correct.
2. **Cross-module protocol names** (`"__fallthrough__"` — referenced in
   `desugar.mdk`, `eval.mdk`, *and* `llvm_emit.mdk`). These MUST be a single
   shared constant in the support layer; three independent literals silently
   drift. (Tracked as the protocol-name-centralization refactor.)
3. **Language-surface names** (`"eq"`, `"compare"`, `"show"`, interface method
   names). These are the actual contract with the prelude/interfaces — keep them
   as literals at the call site; "centralizing" them only adds indirection over
   a name that is *defined* to be that string.

The rule of thumb: centralize a magic string exactly when **two+ files must
agree on it and nothing else defines it** (category 2). Leave categories 1 and 3
inline.

## 5. Reach for a support helper over manual index-threading

When you find yourself threading an explicit index/accumulator through a fold
just to join or separate elements (commas between fields, newlines between
clauses), prefer a named helper — `intersperseStr`, `intercalate`-shaped — from
`selfhost/support/util.mdk`. It states intent and removes the off-by-one surface.

Compiler code may **not** `import` stdlib (`list`/`string`/…) for this — see the
no-stdlib-in-compiler rule in AGENTS.md. Add the helper to `support/` (or inline
it) instead.

```
-- BAD: manual index threading to place separators
go i [] acc = acc
go i (f :: fs) acc =
  go (i + 1) fs (acc ++ (if i == 0 then "" else ", ") ++ f)

-- GOOD: intent named, no index
intercalateStr ", " fields
```
