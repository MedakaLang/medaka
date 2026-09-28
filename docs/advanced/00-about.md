# Advanced Topics

[The Medaka Guide](../guide/00-introduction.md) gets you writing programs. The
chapters here go deeper into one part of the language at a time, for readers who
have finished the guide and want to know how a feature actually works, what it can
express, and where its edges are.

Each topic is a short sequence of chapters that starts from what the guide already
taught and builds up from there. Read a topic in order the first time; the later
chapters assume the earlier ones.

Every example that can run does run. As in the guide, a ` ```medaka ` block is
compiled by the test suite before a change can merge, and a block with output shown
beneath it is executed and the output compared. Where a chapter shows what
`medaka check` prints for a program, or quotes an error message, that text was
pasted from the compiler, not paraphrased.

## Topics

**Effects.** How the effect row in a signature is inferred and checked, how effects
flow through higher-order functions, how to declare labels of your own, how a label
can carry a parameter that says *which* file, host, or variable a function may
touch, how that authority moves through data, and how the whole thing turns into a
capability manifest a host can read.

1. [What the Row Says](effects-1-rows.md). Latent and immediate effects, inference,
   the escape check, the built-in labels, and the rows of values.
2. [Effect Polymorphism](effects-2-polymorphism.md). Effect variables, open rows,
   callbacks, composition, interfaces, and callbacks stored in data.
3. [Labels, Manifests, and the Host](effects-3-labels.md). Declaring labels,
   `medaka manifest` and `check-policy`, `main` as the grant root, and FFI.
4. [Parameters and Authority](effects-4-authority.md). Prefix, Set, and Product
   domains, named arguments, how the compiler reads a path, and qualified values.
5. [Authority in Data](effects-5-data.md). Authority-indexed types, constructors as
   proof, invariance, existentials, and what may be exported.
6. [Effect-Indexed Types](effects-6-indexed.md). Types that store a computation and
   record its row in an index.
7. [Reference and Open Edges](effects-7-reference.md). Every spelling on one page,
   the diagnostics, and the known gaps.
