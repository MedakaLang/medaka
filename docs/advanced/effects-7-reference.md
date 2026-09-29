# Effects VII: Reference and Open Edges

This chapter is the lookup page for the topic: every spelling on one table, the
diagnostics you are likely to meet and where they are explained, and the places
where the system is known not to express something yet.

## Spellings

| Written | Meaning | Chapter |
|---|---|---|
| `f : A -> B` | pure function, the row is `<>` | [I](effects-1-rows.md) |
| `f : A -> <IO> B` | may perform any of the ten host labels | [I](effects-1-rows.md) |
| `f : A -> <Stdout, Clock> B` | may perform exactly those labels | [I](effects-1-rows.md) |
| `v : <Stdout> Int` | a value whose computation performs `Stdout` | [I](effects-1-rows.md) |
| `v : <> Int` | a value computed purely (checked) | [I](effects-1-rows.md) |
| `v : Int` | a value; its row is inferred, not promised | [I](effects-1-rows.md) |
| `f : (a -> <e> b) -> <e> b` | performs whatever the callback performs | [II](effects-2-polymorphism.md) |
| `f : … -> <Stdout \| e> b` | `Stdout`, plus the callback's row | [II](effects-2-polymorphism.md) |
| `f : … -> <e \| e2> b` | the join of two independent rows | [II](effects-2-polymorphism.md) |
| `effect Audit` | declare an atomic label | [III](effects-3-labels.md) |
| `export effect Audit` | declare and export one | [III](effects-3-labels.md) |
| `extern f : A -> <FFI> B` | a foreign call; `FFI` is mandatory | [III](effects-3-labels.md) |
| `extern f : A -> <FFI "libm"> B` | a foreign call, naming the library | [III](effects-3-labels.md) |
| `effect Store Prefix` | a label whose parameter is a path or host | [IV](effects-4-authority.md) |
| `effect Var Set` | a label whose parameter is a set of names | [IV](effects-4-authority.md) |
| `effect Http Product (Host : Prefix, Method : Set)` | a label with axes | [IV](effects-4-authority.md) |
| `<Store>` | the whole domain | [IV](effects-4-authority.md) |
| `<Store "cfg/*">` | a pattern: everything under `cfg/` | [IV](effects-4-authority.md) |
| `<Store "cfg/app.toml">` | an exact element: that path only | [IV](effects-4-authority.md) |
| `<Store "cfg/*", Store "data/*">` | either subtree, never their common prefix | [IV](effects-4-authority.md) |
| `<Var {"HOME", "PATH"}>` | a set element | [IV](effects-4-authority.md) |
| `<Http Host="a.com/*" Method={"GET"}>` | a product element; an unwritten axis is its whole axis | [IV](effects-4-authority.md) |
| `(path : String) -> <Store path> B` | a named argument; the caller's path is the authority | [IV](effects-4-authority.md) |
| `String @p` | a string known to lie within `p` | [IV](effects-4-authority.md) |
| `String @(a \| b)` | a string within either authority | [IV](effects-4-authority.md) |
| `(a <= d) => …` | a relation `check` prints on an unsigned binding | [IV](effects-4-authority.md) |
| `data H (p : Authority Store) = H (String @p)` | a type indexed by an authority | [V](effects-5-data.md) |
| `H path` / `H p` / `H "cfg/*"` / `H *` | index forms: named argument, variable, literal, whole domain | [V](effects-5-data.md) |
| `data Any = Any (p : Authority Store) (H p)` | an existential index | [V](effects-5-data.md) |
| `extern data Socket (h : Authority Net)` | an opaque indexed type produced only by the runtime | [V](effects-5-data.md) |
| `data Job (e : Effect) a = …` | a type indexed by a row | [VI](effects-6-indexed.md) |
| `Job <> a` / `Job <Stdout> a` | a written index | [VI](effects-6-indexed.md) |
| `Job (e \| e2) a` | a joined index | [VI](effects-6-indexed.md) |

## Commands

| Command | What it shows |
|---|---|
| `medaka check file.mdk` | the inferred scheme, row included, of every top-level binding |
| `medaka manifest file.mdk [--fn name]` | the entry's verified capability row as TOML |
| `medaka check-policy file.mdk --fn name --allow L1,L2=param,…` | accept or reject against an allow list |

## Diagnostics

The first words of each message, and where the rule behind it is explained.

| Message begins | Rule | Chapter |
|---|---|---|
| `Effectful value used where <…> is allowed, but it performs <…>` | a body, alias, stored value, or index exceeds its bound | [I](effects-1-rows.md), [II](effects-2-polymorphism.md), [VI](effects-6-indexed.md) |
| `Binding '…' performs <…>, but the row it must fit, <a>, is chosen by its caller` | a declared effect variable is rigid | [II](effects-2-polymorphism.md) |
| `Binding '…' runs the effect row <a>, which its caller chooses` | a callback is applied under a pure arrow | [II](effects-2-polymorphism.md) |
| `this statement's value (…) is silently discarded` | a non-`Unit` statement | [I](effects-1-rows.md) |
| `Unknown effect: …` | a label nobody declared | [III](effects-3-labels.md) |
| `Ambiguous effect label: …` | two modules' labels with one spelling in scope | [III](effects-3-labels.md) |
| `Foreign declaration '…' does not name the 'FFI' effect` | an `extern` without `FFI` | [III](effects-3-labels.md) |
| `Foreign declaration '…' redeclares a built-in runtime name with a NARROWER effect row` | a catalog name redeclared too narrowly | [III](effects-3-labels.md) |
| `Invalid effect parameter on <…>` | a written element the domain refuses: an empty element, or more than 16 members | [IV](effects-4-authority.md) |
| `Binding '…' reaches "…" where only … is admitted` | a body under a named authority reaches a value it did not derive from it | [IV](effects-4-authority.md) |
| `Binding '…' reaches … where its declared bound admits only …` | a constructor or existential exceeds a literal bound | [V](effects-5-data.md) |
| `The qualifier names '…', but no effect atom or index in this signature names '…'` | a qualifier with no domain | [IV](effects-4-authority.md) |
| `'…' needs "…" to lie within "…" here` | a use violates a relation the binding's inferred type carries | [IV](effects-4-authority.md) |
| `Authority index mismatch` | an authority index is invariant | [V](effects-5-data.md) |
| `Effect index mismatch` | an effect index is invariant | [VI](effects-6-indexed.md) |
| `This pattern opens the existential authority '…'` | only a clause or arm can open one | [V](effects-5-data.md) |
| `Constructor '…' of public type '…' carries its authority parameter '…' in no field` | a `public export data` constructor that proves nothing | [V](effects-5-data.md) |
| `Type parameter … is used as an effect row … but its head does not declare it one` | `(e : Effect)` is missing | [VI](effects-6-indexed.md) |

## Open edges

These are the places where the current compiler does not yet express something
the design intends, or where it is stricter than it needs to be. Each has an
issue; the number is the thing to search for.

- **A path bound is a string prefix, and `..` escapes it.** `"cfg/" ++ name`
  lies within `"cfg/*"` for `name = "../secret.txt"`, and the runtime resolves
  the `..`, so the manifest's `cfg/*` is not a sandbox.
  [#3564](https://github.com/MedakaLang/medaka/issues/3564)
- **A pure helper cannot return a value at a named argument's authority.** The
  qualifier needs a label atom. [#3559](https://github.com/MedakaLang/medaka/issues/3559),
  [#3532](https://github.com/MedakaLang/medaka/issues/3532)
- **There is no written syntax for a relation.** A binding whose inferred type
  carries a context such as `(a <= d) =>` (the relation the compiler kept, see
  chapter IV) must stay unsigned.
  [#3566](https://github.com/MedakaLang/medaka/issues/3566)
- **`IO` is a label above the ten, not their abbreviation.** A performed `<IO>`
  does not fit a bound or a policy that spells the ten labels out.
  [#3565](https://github.com/MedakaLang/medaka/issues/3565)
- **A relation cannot be shared by a recursive group.** Two mutually recursive
  functions over a captured handle are refused where one function would be
  accepted. [#3482](https://github.com/MedakaLang/medaka/issues/3482)
- **`check` prints effect and type variables from one alphabet.** The issue's
  title describes an older symptom, since fixed; the naming is what remains.
  [#2583](https://github.com/MedakaLang/medaka/issues/2583)

## Further reading

- [`docs/spec/EFFECTS-SEMANTICS.md`](../spec/EFFECTS-SEMANTICS.md): the
  specification this topic is an introduction to. It describes the intended
  system rather than the current binary, so where it says more than this topic
  does, check the claim against `medaka check` before relying on it.
- [`docs/spec/SYNTAX.md`](../spec/SYNTAX.md): the accepted spellings, including
  the ones this topic did not need.
- [`docs/design/CAPABILITY-EFFECTS.md`](../design/CAPABILITY-EFFECTS.md) and
  [`docs/design/CAPABILITY-PLATFORM.md`](../design/CAPABILITY-PLATFORM.md): why
  the system exists, and what a host that consumes a manifest looks like.
- [Chapter 7 of the guide](../guide/07-effects-and-io.md): where this topic
  started.
