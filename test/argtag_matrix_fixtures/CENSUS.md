# The local-dictionary matrix

`test/diff_compiler_argtag_matrix.sh` drives these fixtures through `check`, `run`
(eval) and `build` + execute (native) and compares each transcript to its hand-written
`expected.txt`.

## What this corpus is

Each cell is one program in which a **local binding forwards a class dictionary and is
used at two types** — the region `T-LOCAL-CONSTRAINED-MONO` used to reject outright.
The cells are the product of two axes:

- **A, the head shapes of the two use types**: distinct user tycons (A1), one tycon at
  two argument types (A2), two primitives (A3), a user tycon and a primitive (A4), an
  open structured head (A5), and two shapes whose instance chain is reached through a
  second call (A6, A7).
- **B, how each instance supplies the method**: both define it (B1), one inherits the
  interface default (B2), both inherit one receiver-derived default (B3).

A local binding whose scheme keeps a class predicate is dictionary-abstracted
(`registerLocalAbs`, `compiler/types/typecheck.mdk`): each use applies it to the
dictionary solved at that use. So every cell is **`decidable`** — the instance is chosen
by the use's type, never recovered at run time from the argument's tag, which is the
question the earlier version of this census answered for the arg-tag route (#2032): two
instances at one head (A2) or at two primitives (A3, A4) cannot be told apart by a tag.
Under dictionary abstraction they never have to be.

Every `expected.txt` was written from the program's semantics, never captured. A cell
that goes red is a wrong answer from one engine, not a golden to re-bless.

## Classification vocabulary

- **`decidable`** — every engine must print `correct:`.

## The cells

| cell | correct |
|---|---|
| `A1…__B1_both_defined` | `woof\|meow` |
| `A1…__B2_one_default` | `woof\|meow` |
| `A1…__B2_one_default_xmod` | `woof\|meow` |
| `A1…__B3_both_inherit_default` | `<dog>\|<cat>` |
| `A2…__B1_both_defined` | `boxint\|boxstr` |
| `A2…__B2_one_default` | `boxint\|boxstr` |
| `A3…__B1_both_defined` | `int\|bool` |
| `A3…__B2_one_default` | `int\|bool` |
| `A4…__B1_both_defined` | `meow\|int` |
| `A4…__B2_one_default` | `meow\|int` |
| `A5…__B1_both_defined` | `[meow]\|meow` |
| `A5…__B2_one_default` | `box\|meow` |
| `A6…__no_local` | `1\|2` |
| `A6…__one_default` | `9\|2` |
| `A7…__one_default` | `9\|2` |
| `CONTROL…__not_pinned` | `woof\|meow//woof\|meow` |

### A1_distinct_user_heads__B1_both_defined

Two user tycons, both impls define the method. The local's two uses reach the two
instances: `woof|meow`.

### A1_distinct_user_heads__B2_one_default

`A1__B1` with one impl method-less, so the interface default supplies it (#1046's
shape): `woof|meow`.

### A1_distinct_user_heads__B2_one_default_xmod

`A1__B2` with the interface and its default in another module (#1046's repro): the
method-less impl's inherited default is found across the module boundary: `woof|meow`.

### A1_distinct_user_heads__B3_both_inherit_default

Both impls inherit one default that dispatches `name v` on its own receiver, so the
receiver's identity must survive through the shared default: `<dog>|<cat>`.

### A2_same_head_diff_args__B1_both_defined

`Box Int` and `Box String`: one tycon, two instances. A tag test sees `Box` for both;
the local's two uses carry the two instances' dictionaries: `boxint|boxstr`.

### A2_same_head_diff_args__B2_one_default

`A2__B1` with the `Box Int` impl inheriting the default: `boxint|boxstr`.

### A3_both_primitive__B1_both_defined

Two primitive types with no runtime cell tag between them: `int|bool`.

### A3_both_primitive__B2_one_default

`A3__B1` with one impl inheriting the default: `int|bool`.

### A4_mixed_primitive__B1_both_defined

A user tycon and a primitive: `meow|int`.

### A4_mixed_primitive__B2_one_default

`A4__B1` with one impl inheriting the default: `meow|int`.

### A5_open_head__B1_both_defined

An open structured head whose instance has a `requires` prerequisite, beside a ground
instance: `[meow]|meow`.  The arg-tag route read a missing dictionary word here and
crashed; the abstracted local passes the constructed dictionary.

### A5_open_head__B2_one_default

`A5__B1` with one impl inheriting the default: `box|meow`.

### A6_same_head_chain_reached__no_local

The same-head shape reached through a second constrained call with no local binding
at all, the control for the local cells: `1|2`.

### A6_same_head_chain_reached__one_default

The same shape through a local, one impl inheriting the default: `9|2`.

### A7_distinct_heads_chain_reached__one_default

Distinct heads reached through a second call, one impl inheriting the default: `9|2`.

### CONTROL_toplevel_helper__not_pinned

The same forwarding helper written at top level, where it was always dictionary-passed:
`woof|meow//woof|meow`.  Every local cell must agree with it.
