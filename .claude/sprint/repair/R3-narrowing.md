# R3 — Door 4 (`T-REQUIRES-UNROUTED`) adversarial review: narrowing hunt

Trunk `0b953165`, binary as found (never rebuilt). All probes `MEDAKA_STRICT=1`; `build` exit
codes read from a file, never a pipe; every program run on all four arms
(`check`/`run`/`build`/execute the built binary). Scratch: `/var/tmp/r3/`.

⚠️ Harness note for anyone re-running my script: `/var/tmp/r3/arms.sh` reuses one
`/var/tmp/r3/bin.out`, so when `build` fails the `exec` line reports the PREVIOUS binary.
Disregard `exec` whenever `build != 0`. (It never affected a finding below — every finding's
exec line is paired with `build=0`.)

---

## F1 — 🚨 S0, **the RUN-043 segfault SURVIVES Door 4** on the ground-goal shape (DERIVED)

RUN-047 records that "the severity increase RUN-043 recorded is undone". **It is undone only
for the DEFERRED goal.** Add one type signature to #1564's own fixture — nothing else changes,
the same four files, the same rejecting import order — and the goal becomes ground, Door 4
never fires, and the binary segfaults.

`/var/tmp/r3/sig/` (`iface.mdk` and `wrapimpl.mdk` copied verbatim from
`test/must_fail_fixtures/1564-import-order-decides-conditional-impl-candidacy/`):

```
nest.mdk:     import iface.{Tag, tagOf, Wrap}
              export nest : Int -> String          <-- THE ONLY DELTA vs #1564's nest.mdk
              nest x = tagOf (Wrap x)
main.mdk:     import iface.{Tag, tagOf, Wrap}
              import nest.{nest}
              import wrapimpl                       <-- rejecting order
              main = println (nest 5)
control.mdk:  ... import wrapimpl BEFORE import nest.{nest} ...   (one line swapped)
```

| arm | `main.mdk` | `control.mdk` (positive control, 2 import lines swapped) |
|---|---|---|
| `check` | **0** — `main : Unit` | 0 — `main : Unit` |
| `check --json` | **0, all four files `"diagnostics":[]`** | — |
| `run` | 1 — `runtime error [E-PANIC]: putStrLn: not a String` | 0 — `wrap(int)` |
| `build` | **0** | 0 |
| execute | **139 — `E-FATAL-SIGNAL: fatal memory fault (segmentation fault)`** | 0 — `wrap(int)` |

Byte-for-byte RUN-043's measurement, at `0b953165`, after Door 4.

**Unsignatured twin, same verdict** (`/var/tmp/r3/pA/`): `export nestg = tagOf (Wrap 5)` —
a nullary top-level whose goal is ground by literal defaulting, no signature involved.
`check` 0 · `run` 1 (`E-PANIC`) · `build` 0 · **exec 139**; control (import order swapped)
prints `wrap(int)` on every arm. So the trigger is **goal groundness, not the annotation** —
a signature is one of at least two ways in.

**Legality / regression direction (DERIVED, with one caveat).** Under A-3.6's ruling that
instance candidacy is graph-global, `nest : Int -> String` in a module that does not import
`wrapimpl` is exactly as legal as #1564's unsignatured `nest`, which this sprint treats as a
program that must not be rejected. A pre-sprint binary rejects it at `check`:
`/root/medaka/medaka check /var/tmp/r3/sig/main.mdk` → exit 1,
`nest.mdk:4:9: No impl of Tag for Wrap Int; write an 'impl Tag Wrap'.` — i.e. the same
compile-time-diagnostic → segfault severity increase RUN-043 escalated on.
⚠️ **CAVEAT (OWED):** that oracle is `/root/medaka`'s checked-in binary, which is stale
against its own source (its staleness warning fires, and `MEDAKA_STRICT=1` aborts on it, so I
read it non-strict). It is a pre-sprint compiler but not a pinned base build. The
branch-side measurement needs no such caveat.

**Why Door 4 misses it (DERIVED from source, `compiler/types/typecheck.mdk`).** `unroutedResidual`
is reachable only through `residualPredsOf`, which is the RESIDUAL reducer at a generalizing
group's close. A ground goal is never residualized — it is discharged by the end-of-body
obligation checker, which tests `implMatchesU` over the graph-global `IE` (accept) while the
route/evidence side still reads `shadowKeyTableRef` (the topological-prefix accumulator). Same
two-registry disagreement, other consumer. Door 4 patched the reducer's `None` arm only; it is
not a fix of the disagreement, and its own header says so ("it drains when the reader moves").

**Grading impact:** `test/must_fail_fixtures/1564-…` cannot see this — its arms are the
deferred shape. A pin for F1 would be #1564's four files with `export nest : Int -> String`
added, graded on the **built binary's exit code**, not on `check`.

---

## F2 — S2, the diagnostic's own remedy does not fix the declared-given shape (DERIVED)

`/var/tmp/r3/pgiven/` — `nest.mdk` writes the predicate as a **declared given**:
`export nest : Tag (Wrap a) => a -> String`, body `nest x = tagOf (Wrap x)`, rejecting order.

- `main.mdk`: `check`/`run`/`build` all **1** with `T-REQUIRES-UNROUTED` at `nest.mdk:4:9`,
  advising *"Add an `import` of the module that declares that impl to the module containing
  this binding"*.
- Following that advice (`/var/tmp/r3/pgiven2/`, `import wrapimpl` added to `nest.mdk`):
  still exit 1, now `Could not deduce 'Tag a' from the signature of 'nest'. Its body requires
  it; add 'Tag a =>' to the declared type`.
- Positive control (`control.mdk`, import order swapped, impl visible for reduction): also
  exit 1 with that same "add 'Tag a =>'" message.

So this shape is rejected in **both** import orders and the remedy Door 4 prints is wrong for
it — the user needs `Tag a =>`, not an import. **Not a false reject** (the program is refused
either way, by design: with the impl visible the compiler insists the context be reduced), but
the advice sends the reader somewhere that still fails. Cheapest honest fix is wording, not
behaviour.

---

## F3 — low, an in-class narrowing that removes a program that ran correctly (DERIVED / part OWED)

`/var/tmp/r3/pD/`: `export dead x = if False then tagOf (Wrap x) else "no"`, rejecting order →
`T-REQUIRES-UNROUTED` on all three arms. Control (order swapped) prints `no`.
This is squarely inside Door 4's declared class (deferred goal, impl in a non-imported,
later-sorting module) and the reject is fail-closed and defensible. Recorded only because the
pre-Door-4 build of this one **would have run correctly** — the dropped residual is never
executed, so no dict is ever read. That the residual is harmless *here* is a property of the
branch, not of the type, so I do not think it should change the ruling. ⚠️ The
"would have run correctly" half is **OWED** — mechanism-derived (dead branch ⇒ the arity-1
call is emitted but never reached), not measured, since I did not rebuild the Door-4 base.

---

## Shapes I attacked and found CLEAN (no false reject)

All on `iface`/`wrapimpl` from #1564's fixture unless stated; all four arms exercised.

| shape | dir | verdict |
|---|---|---|
| `import wrapimpl` (bare) in `nest.mdk` — the diagnostic's own remedy | `pbare` | silent; `wrap(int)` on run + exec 0 |
| `import wrapimpl as W` in `nest.mdk` (values-only alias, impls still in scope) | `pali` | silent; `wrap(int)`, exec 0 |
| **transitive**: `nest` imports `mid`, `mid` imports `wrapimpl`, `nest` does not | `ptrans` | silent; `wrap(int)`, exec 0. Consistent with the mechanism — the prefix accumulator contains any module that sorts earlier, imported or not, so the reject can only fire for a module sorting BEFORE the impl's module |
| **Flat / single file**: overlap (`impl Tag Int` + `impl Tag a` + `impl Tag (Wrap a) requires Tag a`) plus a 2-deep chain `impl Tag (Box (Wrap a)) requires Tag (Wrap a)`, goal `Tag (Box (Wrap a))` | `flat` | `nest : Tag a => a -> String`, exec 0 `box(wrap(int))`. Never fires on the Flat path — expected: both registries are built from the same decl set there, and `implHeadMatchesArgs` / `implHeadSubst` are the same success condition (`typecheck.mdk:18638`, `:22396`) |
| **2-deep `requires` chain across module order** (`Box`+`Wrap` impls both in the later module) | `pdeep` | fires correctly, message names the full goal `Tag (Box (Wrap a))`, located in `nest.mdk`. In-class, not a false reject |
| **Real corpora sweep** — `medaka check` over `compiler/driver/medaka_cli.mdk` (whole compiler closure), `sqlite/lib/sqlite.mdk`, `stdlib/json.mdk` | — | exit 0, exit 0, exit 0; **zero** `Cannot pass a dictionary` occurrences. Prelude/`core` impls never trip it |

## What I could NOT construct, and why

- **A false reject where the evidence IS routable.** Every reject I produced was in Door 4's
  declared class (impl in a module sorting later than the goal's module). The mechanism makes
  a spurious fire hard on the Flat path: the two legs share `matchTyMono`, the same length
  test, and the same headless fallback, so `implMatchesU`-True-with-`findMatchingImplReqsU`-None
  needs the two registries to be populated differently, which happens only on the Module path.
- **A `pickMostSpecificEntry`-ambiguity fire.** `typecheck.mdk:8970` records that
  `pickMostSpecificEntry []` returns `None` and everything else falls back to head-of-list, so
  an incomparable overlap yields a winner rather than `None`; I could not turn it into a `None`
  from the concrete leg. **OWED** — argued from source, not from a probe that fired.
- **Same-spelled-interface-in-two-modules (#1438 shape) crossed with a conditional impl.**
  Designed but not executed; a name/identity mismatch between the bare-name-keyed KeyBuckets
  read (`concreteReqMatchByIface iface.irName`) and `IE`'s `oblIfaceKey` is the one remaining
  structural route to a spurious fire I can see. Left for whoever picks this up.
- **Any base-vs-branch two-arm differential**, because the brief forbids rebuilding and the
  Door-4 base binary does not exist in this tree. Every "would have worked before" claim above
  is labelled accordingly.
