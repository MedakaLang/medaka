# R4 — repair round: did any diagnostic go quiet?

Trunk `0b953165`, branch `arch/stage-a-sprint`. Binary as found (not rebuilt). Every probe
`MEDAKA_STRICT=1`; exit codes read from a redirect, never a pipe.

## Headline

**No diagnostic went quiet.** Every check the sprint relocated still fires, on both the Flat
(single-file) and Module (multi-file) paths, on `check` and `run`, at exit 1 (or exit 0 with the
warning present, for the demoted coherence class). The `None => []` silent-accept hazard the
sprint named for `ceRequiredAt`/IE did **not** materialise on any shape I could construct.

Three *quality* findings below (duplication + location), all S2/S3, none of them a lost check.

---

## 1. Confirmed INTACT (DERIVED — each run first-hand on this binary)

| diagnostic | Flat | Module | notes |
|---|---|---|---|
| `T-INCOMPLETE-IMPL` | ✅ `iface_incomplete_impl_flat.mdk` 40:11, check+run | ✅ `1111_a24_genuine_iface_rejects` 34:11 | user iface, **imported** iface and **prelude** iface (`Ord`/`compare`) all reject; matches committed `oracle.json` byte-for-byte incl. ranges and ordering |
| `T-IMPL-KIND-MISMATCH` | — | ✅ 38:12 | matches oracle range (line 37 char 12, 0-based) |
| `T-MISSING-SUPER-IMPL` | ✅ 11:8 | ✅ 7:8 (super declared in an **imported** module) | **positive controls accept** on both arms — no false-reject from an IE miss, which is the fail-direction A-3.5b's own comment flags |
| `W-INCOMPARABLE-IMPLS` | ✅ intra-module, `check` stderr + `--json` + `run` | ✅ cross-module, `check` stdout + stderr | the class that already broke once (`cohSoftInScope "" ""`) — **no sibling found** |
| `T-CONFLICTING-IMPL` | ✅ 58:9 | ✅ | |
| `T-AMBIGUOUS-INSTANCE` | ✅ 46:16 / 35:16 | — | |
| `T-CYCLIC-SUPERINTERFACE` | ✅ | ✅ | fires — but see §2 and §3 |
| `T-PHANTOM-METHOD` | ✅ | — | fires — but see §3 |
| `T-RECURSIVE-ALIAS` | ✅ | — | fires — but see §3 |
| `T-AMBIGUOUS-FIELD` | ✅ 6:8, unsignatured receiver | — | |
| `T-REQUIRES-DEPTH` | ✅ 33:9, at-limit control accepts | — | |
| `T-REQUIRES-UNROUTED` | — | ✅ `nest.mdk:3:16` | exactly the range #1564's `claim.txt` records |

---

## 2. FINDING — the "at worst a duplicate report" is REAL, not theoretical (S3)

A-3.5c's interface-cycle re-key was accepted on the argument that it yields *"at worst a
duplicate report, never a new error class."* It does produce one, on real code, and the
duplicate is **baked into the committed oracle**:

```
$ ./medaka check test/analyze_project_fixtures/1557_a35c_cycle_masked_by_samespelled/main_cyc.mdk
cyclemod.mdk:19:12: Cyclic superinterface: Alpha requires Beta requires Alpha
main_cyc.mdk:33:15: Cyclic superinterface: Alpha requires Beta requires Alpha
```

One cycle, two reports, attributed to two different modules. `oracle.json` (added by
`4dd1c304`, the A-3.5c commit itself) pins both. Nobody has looked at this as UX.

**Epistemics:** that the duplicate exists *today* is DERIVED. That A-3.5c *introduced* it is
**OWED** — proving it needs a pre-A-3.5c binary, and this round is read-only/no-rebuild.

## 3. FINDING — location loss / misattribution in the relocated decl-time checks (S2)

`ImplRow`/`CeRow` carry no `Loc`, and these checks use `pushTypeError` (no `…At`), so they
inherit whatever `currentLoc` happens to hold — the last expression typechecked. Measured:

- **`T-CYCLIC-SUPERINTERFACE`** points at *function bodies*, never the interface decls that form
  the cycle: `cfn n = ofn n` (19:12), `main = println (cfn 1)` (33:15). On a flat file with a
  leading comment it reported `1:0`, i.e. **the comment**.
- **`T-RECURSIVE-ALIAS`** — `<unknown location>: Recursive type alias \`Loop\``. No location at all.
- **`T-PHANTOM-METHOD`** — `<unknown location>: Method 'ghost' is not part of interface 'P'`.

`T-MISSING-SUPER-IMPL`'s 11:8/7:8 are the same incidental mechanism (they land on the impl's
method body); they merely happen to land somewhere plausible.

**OWED:** whether these were better before the relocation. The `.tc.golden` baselines for these
three record message text with *no* location field, so they cannot answer it.

---

## 4. RETRACTED — a false positive I generated and then killed

My first battery filtered output through a keyword grep that lacked `overlapping`. It reported
`W-INCOMPARABLE-IMPLS` as **missing** on the flat accepting fixtures. **That was my probe lying,
not the compiler.** Re-run raw, the warning is present on stderr, correctly located
(`s6-1c-per-goal-unique-min-accepted.mdk:49:8`). An independent trace of the flat
`checkRoute → analyzeLocatedG → checkProgramDiags` chain confirmed `matchWarnings` is harvested
*after* `runFinalChecks` pushes, so nothing is dropped. Recording it because a lossy grep is
exactly how an absence probe manufactures a false S0.

Related, and also **not** a regression: human `check` drops warnings when any error is present
(`checkToLinesWithRuntime`'s `match errs`). Verified general with a control — a `W-NONEXHAUSTIVE`
is suppressed the same way beside a type error. So the missing warning on
`s6-c1-hard-and-soft-in-one-file.mdk` is pre-existing behaviour, not coherence-specific.
`check --json` reports both codes there.

## 5. Could not construct a forcing program for

Transitive (2-hop) superinterface; super satisfied by a **non-exported** impl in an imported
module; genuine cross-module `T-CONFLICTING-IMPL` duplicate; `T-AMBIGUOUS-FIELD` on the Module
path (stage-K field-owner overlay). These are the untested corners of my axis.
