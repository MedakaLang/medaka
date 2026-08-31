# ARGS-DESIGN.md — one argument parser for sixteen verbs

**Status:** DECIDED (2026-08-31, reviewed and approved at the `argv-one-parser` phase-1
checkpoint). Implemented by `stdlib/args.mdk`. Serves #2355, #2276 leg 7, umbrella #2301.

Normative wording for the sentences this module renders lives in
`docs/ops/CLI-CONFORMANCE.md` (C1–C4); this file records the *shape* decision and the shapes
that were rejected, so the next agent finds a ruling instead of re-deriving one.

---

## 0. The decision, in one line

**A flag specification is a first-order value** — a `List FlagSpec` inside an `ArgSpec` —
and `rosterOf`, `helpBlockOf`, `unknownFlagMessage` and `parseArgs` are four *renderings* of
that one value. No applicative encoding, no combinators, **no closures per flag**.

**Why, in one line:** the `optparse-applicative` design is not merely heavy in Medaka, it is
**inexpressible** — the free applicative needs existential quantification and Medaka has none
(probed, §7.1). The only expressible combinator shape is the wrapped-function one that
`byteparser`/`parsec` use, which is opaque and therefore cannot derive help. Criterion 1 never
needed the applicative encoding; it needed the spec to be a *value*, and a list of records is a
value.

---

## 1. The problem

`medaka` is sixteen verbs behind one binary and the highest-frequency first-hour surface in the
project. Each verb currently hand-maintains, separately:

1. what it actually parses (a bespoke argv walk);
2. what its `--help` advertises (a string literal);
3. what its unknown-flag rejection names as `(known: …)` (a second string literal).

Three hand-maintained copies of one fact drift, and the drift is invisible: a flag that is
parsed but unadvertised, or advertised but unparsed, produces no error anywhere. That drift —
not the parsing — is the defect this module closes.

---

## 2. Verdict table — the six criteria the design was cut against

| # | Criterion | Verdict |
|---|---|---|
| 1 | help derives from the parser value | ✅ YES — *without* the applicative encoding |
| 2 | expresses all sixteen verbs + the D-2 hazards | ✅ YES — every hazard a declared spec field; one declared non-goal (`dispatchSub`) |
| 3 | short flags first-class | ✅ YES, from the first slice |
| 4 | allocation cost | ✅ CHEAP — predicted ≤ +0.3% Ir |
| 5 | reads like the rest of the tree | ⚠️ DELIBERATE DIVERGENCE, justified (§5) |
| 6 | defensible under #2306 | ✅ YES |

**Out of scope (declared non-goals):** subcommand dispatch (`dispatchSub`'s deliberate
first-position-only `--help`/`-h` interception, #1348, stays where it is); anything
`docs/ops/CLI-CONFORMANCE.md` does not require.

---

## 3. The API

```medaka
data Arity = Switch | Value String | ValueList String | OneOf (List String) String | IntValue String
  -- the String on each value-taking arm is the help metavar; OneOf also carries its closed set
data Visibility = Public | Internal
data Unknown = RejectUnknown | CollectUnknown
data Trailing = TrailingReject | TrailingRaw | TrailingAfterSeparator
data FlagSpec = FlagSpec { names : List String, arity : Arity, summary : String, visibility : Visibility }
data ArgSpec  = ArgSpec  { verb : String, flags : List FlagSpec, trailing : Trailing, unknown : Unknown }
data Args     = Args     { given : List (String, Option String), positionals : List String, rest : List String }

parseArgs : ArgSpec -> List String -> Result String Args
flag       : String -> Args -> Bool
flagValue  : String -> Args -> Option String    -- FIRST occurrence
lastValue  : String -> Args -> Option String    -- LAST occurrence
flagValues : String -> Args -> List String      -- all occurrences, argv order
rosterOf   : ArgSpec -> List String             -- `--`-prefixed names ONLY (see §4)
unknownFlagMessage  : ArgSpec -> String -> String
missingValueMessage : ArgSpec -> String -> String
invalidValueMessage : ArgSpec -> String -> String -> String
helpBlockOf : ArgSpec -> String
usageExitCode : Int                             -- the C3 constant, 1
```

Builders (`switch` / `value` / `valueList` / `oneOf` / `intValue` / `internal` / `spec` /
`withTrailing` / `withUnknown`) exist so a verb's spec reads as a table rather than as record
syntax; they construct nothing the record literals could not.

**Duplicate-flag semantics are deliberately NOT chosen here.** `given` keeps argv order and the
verb picks `flagValue` (first) or `lastValue` (last). The tree today contains both conventions
— `medaka_cli.mdk`'s `snapFlagValue`/`testFlagValue` take the first, `gate_cmd.mdk`'s
record-update fold takes the last — so a module that picked one would silently change behaviour
under a migration that is supposed to be inert. Converging them is a later, deliberate change.

---

## 4. 🚨 `rosterOf` filters to `--`-prefixed names

`FlagSpec.names` carries **every** spelling as a complete token including its dashes
(`["--write", "-w"]`) from the first day — short and long are members of *one* spec, not a
`short : Option Char` field (which forces two shapes on every renderer) and not separate
aliased specs (which split one flag's help into two rows that then drift, the very defect this
closes).

But the **rendering** stays `--`-only until the migration is complete. Putting shorts into
`rosterOf` changes the `(known: …)` text of every verb that has one, so
`make cli-conformance-census` would stop being byte-identical and the "migrations are
observably inert" property would fail. The tree has exactly four short flags — `-h`, `-v`,
`-w` (the only alias of a long flag) and `-o` — so the widening is small, deliberate, and gets
its own change with its own test. **Spec carries shorts from slice 1; the rendering widens
later.**

---

## 5. Criterion 5 — the deliberate divergence

The three existing combinator-shaped modules in the tree (`byteparser`, `parsec`,
`validation`) wrap functions. This module does not, and that is the point: a wrapped function
is opaque, and criterion 1 requires the spec to be *inspectable* so help can be derived from
it. The design instead converges with `checkCliFlags` (`compiler/driver/medaka_cli.mdk`), which
already takes flag *names* as data — it just takes them as two bare `List String`s that carry
no arity, no summary and no short-flag structure. `ArgSpec` is that idea, finished.

`cmdliner`'s *info* half (a flag's names + doc as a record) is adopted; its *term* half (the
applicative) is not.

---

## 6. Cost posture — criterion 4

**`FlagSpec` is four immutable fields of plain data.** A verb's spec is ~3–8 records plus cons
cells, built once at verb entry. An applicative encoding would allocate a closure per flag
**plus** an `ap` node per combinator **plus** an indirect dictionary-dispatched call per node —
roughly 3× the cells, on a path that runs on *every* `medaka` invocation. The allocator is
**46.8pp of compiler time** (#2036), so that multiplier is why the boring shape wins criterion
4 outright, independently of the expressibility finding.

Three properties the module must keep, or the measurement is void
(`[T-STDLIB-IMPORT]`):

1. **No `deriving`, no `impl`** on any type here. `[T-STDLIB-IMPORT]`'s +640M `import map` cost
   is its `Ord`-constrained impls and large API entering dispatch scope; `args` brings none.
2. **`args` imports only `string`**, which every consumer already imports — so no new module
   enters scope for the largest consumer.
3. **Per-flag lookup over `given` is a monomorphic fold**, not a polymorphic `lookup`, and not
   a `map`/`hash_map`.

**Prediction: ≤ +0.3% Ir** on `./medaka check compiler/driver/medaka_cli.mdk`. **Falsifier,
stated before it was measured:** any `deriving` or `impl` on these types, or a `map`/`hash_map`
import for the `given` lookup, invalidates it — a >+2% result should be checked against those
three first.

---

## 7. Rejected shapes, each with the criterion that killed it

| Shape | Killed by |
|---|---|
| `optparse-applicative` free applicative | criterion 1, **by inexpressibility** (§7.1) |
| function-wrapped applicative (the `byteparser`/`parsec` shape) | criterion 1 (opaque — help cannot be derived) + criterion 4 |
| `docopt` (parse the help text) | criterion 6, then criterion 1 — the spec becomes a `String` |
| `cmdliner` term/info | criterion 5, narrowly — its *info* half **is** adopted (§5) |
| Go `flag` / Python `argparse` registration | criterion 1 — registration is a *sequence of effects*, not a value |
| keep `checkCliFlags`'s two bare `List String`s | criteria 1 and 3 — no arity, no summary, no shorts |

### 7.1 The decisive probe — Medaka has no existential quantification

```medaka
data P a = PPure a | PFlag String | PAp (P (b -> a)) (P b)
names : P a -> List String
names (PAp f x) = names f ++ names x
run : P a -> a
run (PAp f x) = (run f) (run x)
spec : P Int
spec = PAp (PPure (n => n + 1)) (PPure 41)
```

```
$ MEDAKA_STRICT=1 ./medaka check free2.mdk
error: free2.mdk:13:24: Cannot construct infinite type involving a
error: free2.mdk:19:21: Cannot construct infinite type involving a
error: free2.mdk:19:29: 'run' takes 1 argument(s) but is applied to 2.
error: free2.mdk:22:32: Type mismatch: Int vs b
error: free2.mdk:24:22: Type mismatch: b vs Int
error: free2.mdk:22:39: Type mismatch: Int literal vs b
error: free2.mdk:22:24: No impl of Num for b
rc=1
```

The `b` in `PAp` is a **rigid, scope-escaping** type variable, not an existential. Free
applicative ⇒ inexpressible ⇒ criterion 1 is unreachable by any combinator encoding that is
also runnable.

---

## 8. What criterion 1 buys the conformance gate

Once roster and help are folds over one `ArgSpec`, the help-conformance properties
**A** (advertised ⊆ parsed) and **C** (parsed ⊆ advertised) are **true by construction** for
every migrated verb — regression detectors, not live disagreement finders. C's
`NO ROSTER (uncovered)` class (`codemod`, `doc`, `lsp`, `mcp`, `new`, `repl`) disappears, since
a verb with an `ArgSpec` has a roster whether or not it has flags. ⇒ **the enforcing gate
should key on the one call shape (`parseArgs`), not on agreement.**

---

## 9. Hazards the spec encodes rather than exempts

* **`medaka run`'s argv passthrough** (`CLI-CONFORMANCE.md` §2's second live behaviour):
  `trailing = TrailingRaw`. The first positional ends flag scanning; everything after it,
  `--` included and **not** consumed, is the program's argv.
* **`medaka gate <sub>`'s separator**: `trailing = TrailingAfterSeparator` consumes exactly one
  bare `--`; a second one is data.
* **`medaka codemod`'s per-codemod vocabulary** (`splitCodemodArgv`): `unknown =
  CollectUnknown`, so an unclaimed `--`-shaped token is recorded with the following token as
  its value. Handling it as a spec *field* rather than as an exemption is what keeps `codemod`
  out of being a permanent hole in the conformance gate.
* **`--allow-internal` and friends**: `visibility = Internal` hides a flag from `helpBlockOf`
  but **not** from `rosterOf`. A rejection sentence that refused to name a parseable flag would
  be a worse lie than a help block that omits it.
* **Everything else**: `trailing = TrailingReject`, which gives `--` no special meaning, so it
  rejects through the ordinary unknown-flag path with no special case.
