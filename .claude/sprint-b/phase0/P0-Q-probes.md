# P0-Q — discharging the probes P0-A, P0-B and P0-FABLE owed but could not run

**Agent:** P0-Q (Phase 0, read-only on source). **Tree:**
`/root/medaka/.claude/worktrees/giggly-tinkering-rainbow`, branch `arch/stage-b-sprint`,
`git rev-parse HEAD` → `51b7a460e62c26b3ffdf98ed0bfe945143573634`.
⚠️ **HEAD is not the brief's `2b9dc798`** — three sprint-doc commits landed on top
(`398a3a2e`, `cfa4f12e`, `51b7a460`). **Compiler source is byte-identical to `2b9dc798`**,
verified: `git diff --stat 2b9dc798..HEAD -- compiler stdlib runtime` → empty. So every
source line number below is equally a `2b9dc798` line number, and the binary is a valid
measurement of that base.

**Binary:** `./medaka` (built 2026-08-13 02:46), used as-is; nothing was rebuilt.
Freshness re-confirmed at probe time rather than taken from the brief:

```
$ MEDAKA_STRICT=1 ./medaka run /var/tmp/p0q/fresh.mdk
strict exit=0
12345
stderr:            (empty — no staleness warning)
```

Every probe program is under `/var/tmp/p0q/`. Nothing in `test/`, `compiler/`, `stdlib/` or
`runtime/` was touched. This file is the only file written.

---

## Headline — verdicts, loudest first

| # | Probe | Verdict |
|---|---|---|
| 1 | Does the SHADOW widening reach the DEFINER arm? | ✅ **NO — P0-A §2.2 CONFIRMED, behaviourally and twice over in source.** Not an S0. |
| 3 | Which drivers still take the **Flat** path? | 🚨 **`B-2.1-a` IS LOAD-BEARING, and the risk is the OPPOSITE DIRECTION from the one P0-A frames.** Flat is reached by `medaka check <no-import file>`, `lsp`, `repl`, `doc`, `lint`-policy, `snapshot`, and the two typed **emit** entries. **Measured: the Flat arm gets #1564 RIGHT (exit 0, prints `wrap(int)`) where the Module arm gets it WRONG.** A reader repointed onto an empty Flat `IE` would regress a currently-correct arm. |
| 5 | Is the `RDict` skew coupling real, and silent? | ⚠️ **Coupling REAL; "silent" UNDERSTATED (it is `unreachable`, i.e. LLVM UB, not an abort). But "live on the RDict path" is OVER-READ** — two masking tiers P0-B does not mention (`implEntryRouteWords` #1036 leg 2, and the general-entry catch-all) absorb exactly the tag↔key skew, including the example typecheck's own comment gives. Also **P0-B's `ast.mdk:706-712` citation is about `RLocal`, not `RDict`.** |
| 2 | Do `univReceiverTag` and `headTyconTy` agree on the head's spelling? | ✅ **They cannot disagree — `univReceiverTag` IS a wrapper that calls `headTyconTy`.** P0-A §4.3's framing is wrong; the real divergence it should have flagged is **membership on empty `tys`**, not spelling. Corroborated behaviourally on 6 head kinds; **1 divergence found (type ALIAS heads), and it is impl-vs-GOAL, symmetric across both tables.** |
| 4 | The ratchet's current allowance | ✅ **23 rows.** Derived; `universeKeyBucketsRef` IS one of them ⇒ `B-2.1-d` shrinks it to 22. |
| — | Bonus, unasked | ⚠️ **P0-A's `B-2.1-c` "sites:" list is INCOMPLETE — it omits `typecheck.mdk:15014`**, a fourth `implExistsForHead` call site. Since B-2.1-c changes that function's *signature*, `:15014` must move with it or the tree will not compile. |
| — | Bonus, unasked | ⚠️ **`typecheck.mdk:14076` cites `diff_flat_vs_onemodule.sh` as a gate that "exists". It does not exist anywhere in the tree.** It is the exact instrument a `B-2.1-a` implementer would reach for. |

---

## Probe 1 — 🚨 does the SHADOW widening reach the DEFINER arm? **NO.**

### 1.1 The claim under test

P0-A §2.2, its one self-flagged unprobeable claim: *"It is consulted here only on the
`otherwise` (non-definer-shadow) leg, so the definer-shadow inversion is untouched. … if the
widening reached the definer arm it would be a silent re-erasure of the user's function — the
exact S0 S2 was written to fix."*

### 1.2 The monotonicity argument that makes this probeable on ONE binary

The widening B-2.1-c proposes can only ever flip `implExistsForHead` from `False` to `True`
(a wider impl universe finds strictly more impls; it removes none). Therefore:

> **If a definer-shadow occurrence still calls the standalone when the impl is ALREADY in the
> universe (in the topological prefix, and directly imported by the definer's own module),
> then no widening can change that occurrence's answer** — because widening cannot make the
> universe *more* than "contains it".

That converts the two-arm differential P0-A could not run (`#1431`: the shadow gate hardcodes
`$ROOT/medaka`) into a **single-binary probe on a maximal universe**, which is sound and needs
no second worktree.

### 1.3 The discriminating pair

Same interface (`Display`, prelude), same method (`display`), same impl
(`impl Display Box where display (Box _) = "IMPL"` in `implmod.mdk`), same standalone
(`display _ = "STANDALONE"`), same in-prefix universe. **The ONLY variable is definer vs
importer shadow** — i.e. whether the module containing the *use site* is the module that
*defines* the standalone.

Files (`/var/tmp/p0q/disp/`):

```
boxty.mdk    public export data Box = Box Int

implmod.mdk  import boxty.{Box(..)}
             export impl Display Box where
               display (Box _) = "IMPL"

stand.mdk    import boxty.{Box(..)}
             export display : Box -> String
             display _ = "STANDALONE"

defr.mdk     import boxty.{Box(..)}
             import implmod                      -- impl is in defr's OWN prefix, imported
             export display : Box -> String
             display _ = "STANDALONE"
             export probe : String
             probe = display (Box 1)             -- DEFINER shadow occurrence

main_importer.mdk   import boxty.{Box(..)}
                    import stand.{display}
                    import implmod
                    main = putStrLn (display (Box 1))   -- IMPORTER shadow occurrence

main_definer.mdk    import defr.{probe}
                    main = putStrLn probe
```

```
$ ./medaka run /var/tmp/p0q/disp/main_importer.mdk
exit=0
IMPL                       ← POSITIVE CONTROL: implExistsForHead answered True

$ ./medaka run /var/tmp/p0q/disp/main_definer.mdk
exit=0
STANDALONE                 ← definer arm, IDENTICAL universe: not consulted
```

Both arms also built and run natively (redirect-then-read, not piped — `build`'s exit code
does not survive a pipe):

```
$ ./medaka build /var/tmp/p0q/disp/main_definer.mdk -o /var/tmp/p0q/bin_definer   ; echo $?
0
$ /var/tmp/p0q/bin_definer
STANDALONE                 (exit 0)
$ ./medaka build /var/tmp/p0q/disp/main_importer.mdk -o /var/tmp/p0q/bin_importer ; echo $?
0
$ /var/tmp/p0q/bin_importer
IMPL                       (exit 0)
```

**And the "nearest miss" program P0-A names** — definer shadow whose impl is NOT reachable
from the definer's module (`/var/tmp/p0q/nonprefix/`, `defr.mdk` drops `import implmod`;
`main_np.mdk` imports both):

```
$ ./medaka run   /var/tmp/p0q/nonprefix/main_np.mdk       →  exit 0, STANDALONE
$ ./medaka build /var/tmp/p0q/nonprefix/main_np.mdk -o …  →  exit 0
$ /var/tmp/p0q/bin_np                                     →  STANDALONE (exit 0)
```

A second, independent instance on a **user-defined** interface rather than a prelude one
(`/var/tmp/p0q/ctrl/`: `interface Sz a` with `size : a -> Int`, `impl Sz Box → 100`,
definer standalone `size _ = 7`, impl directly imported by the definer's module):

```
$ ./medaka run /var/tmp/p0q/ctrl/main_ctrl.mdk
exit=0
7                          ← the standalone, not the 100 the in-prefix impl would give
```

### 1.4 What else could have produced `STANDALONE` / `7`, and how it is ruled out

| Alternative explanation | Ruled out by |
|---|---|
| `implExistsForHead` never finds `Display@Box` at all (impl not registered, probe broken) | The **importer arm prints `IMPL`** on the identical module set and identical universe. The predicate demonstrably answers `True` there. |
| The impl is not actually in the universe when `defr` is checked | `defr.mdk` **directly `import`s `implmod`**, so the impl is in `defr`'s topological prefix *and* nameable in it — the strongest possible position. The `nonprefix` arm is the weaker case and agrees. |
| A prelude-specific quirk of `Display` | Reproduced independently on a user-declared `interface Sz a` (`ctrl` arm) with a different return type and different values. |
| Only the interpreter behaves this way | `build` + the native binary agree on all arms. |
| The probe cannot fail | It **does** fail in the intended direction: the importer arm is the same code shape and yields the other answer. The pair differs in exactly one property. |

### 1.5 Source corroboration — the short-circuit, and a SECOND one P0-A did not cite

`definerReceiverDispatches` (`compiler/types/typecheck.mdk:11498-11504`), verbatim:

```
definerReceiverDispatches : String -> Mono -> Bool
definerReceiverDispatches name xt
  | isDefinerShadow name = definerReceiverIsDictVar name xt
  | otherwise = match headTyconMono xt
    Some head =>
      implExistsForHead perRun.value.shadowKeyTableRef.value name head
    None => definerReceiverIsDictVar name xt
```

Guards are first-match, so `isDefinerShadow name = True` returns before the reader at `:11503`
is ever evaluated. **`isDefinerShadow` is tested unconditionally at the top**, independent of
which disjunct of `definerShadowArgHead` routed the occurrence here — so even the
`importerShadowOnEmitPath` entry (`:11336-11338`, the mangled-emit arm that also reaches
`inferDefinerShadowApp`) cannot smuggle a *genuine* definer shadow onto the `otherwise` leg.

**And the ROUTE side is gated identically** — `resolveRLocalSite:15014`:

```
  Some tag => stampRLocalOrFallback
    (not (isDefinerShadow name) && implExistsForHead keyTable name tag)
```

This matters more than the type-side gate for the S0 question, because a route/type
disagreement is the P0-20 bug class the surrounding comment (`:15008-15013`) names by hand:
*"Routing here on a gate the typing entry points do not share would route a site whose TYPE came
from the dispatch path… Keep the two gates identical."* They are identical, and both
short-circuit. P0-A's §2 discusses only the type side.

### 1.6 Verdict

✅ **P0-A §2.2 is CONFIRMED. The definer-shadow inversion is not reachable by the widening, on
either the type side or the route side, on either engine.** `B-2.1-c` does not carry the S0 that
paragraph feared. The `nearest miss:` program P0-A specifies is written and its baseline is
recorded above — an implementer can diff against it directly. What `B-2.1-c` *does* still move
is the **importer** arm (Fork 1's per-receiver rule), which is the acceptance change P0-A
budgeted; the `main_importer.mdk` arm above is its baseline.

---

## Probe 2 — `univReceiverTag` vs `headTyconTy`: they cannot disagree on spelling

### 2.1 🚨 P0-A §4.3's framing is wrong: one function CALLS the other

`typecheck.mdk:21622-21624`:

```
univReceiverTag : List Ty -> Option HeadKey
univReceiverTag (headTy::_) = headTyconTy headTy
univReceiverTag [] = None
```

`keyEntryOf` (`:17797-17806`):

```
keyEntryOf (DImpl { iface, tys, reqs, methods, ... }) = match tys
  headTy::_ => [
    KeyEntry (map implMethodNameTc methods) (headTyconTy headTy) headTy (implKeyTc iface tys) iface tys reqs 0
  ]
  [] => []
```

**Both take the FIRST element of the same `tys` list and apply the SAME `headTyconTy`.** For any
non-empty `tys` the two projections are the *identical* `Option HeadKey` value — origin
component included. A spelling divergence is not merely absent, it is unconstructible.

Both tables then key on **spelling only**, through the same projection —
`dispHeadTab hk = TkBare NsType (headKeyName hk)` (`:21616-21617`) for `IE`, and per
`:2480-2484` `KeyBuckets` since A-2.2b pairs the same `headTyconTy`/`headTyconMono`. So the
bucketing agrees too.

And the input decls are the same nodes: `implDeclFact` (`:4172-4180`) passes `DImpl`'s `tys`
through **unmodified** — no elaboration, no alias expansion, no normalization — so `IE`'s
`ImplRow` field 4 is the very list `keyEntryOf` reads.

### 2.2 The divergence P0-A should have flagged instead: **membership on empty `tys`**

| `tys` shape | `keyEntryOf` | `ieInsertRowAt` (`:4244-4248`) |
|---|---|---|
| `headTy::_`, head is `TyCon`/`TyTuple` | `KeyEntry … (Some hk) …` → concrete bucket | `Some hk` → `ieConcrete` at `[ifk, dispHeadTab hk]` |
| `headTy::_`, head is neither (tyvar / general instance, #1128) | `KeyEntry … None …` → the `noneHeadTag` bucket | `None` → `ieHeadless` |
| **`[]` (no head types at all)** | **`[]` — NO entry is produced at all** | **`None` → the row IS inserted, into `ieHeadless`** |

So the one real asymmetry is that **`IE` admits a row `KeyBuckets` drops entirely.** A reader
repointed onto `IE` inherits that admission. That is a *widening*, not a "stops finding impls",
so it is the opposite hazard from the one P0-A warns about — and it belongs in `B-2.1-b`'s
`could move:`. (Whether an `impl I where` with empty `tys` is reachable from the surface
grammar I did not establish; the divergence is in the tables regardless.)

Note also `headKeyName (HkRigid n) = n` — a rigid head *does* hand out a bucket key
(`dispHeadTab`'s own ⚠️). It is not reachable from `headTyconTy`, whose only `Some` arms mint
`headKeyOfCon`, so **neither** table's impl side can produce `HkRigid`. Symmetric; no delta.

### 2.3 Behavioural corroboration — heads actually covered, and one divergence found

The point of running this rather than only reading it: a disagreement between the two tables
would surface as a **false `T-NO-IMPL`** or a **wrong impl chosen**, both observable. The
probe is a multi-module program (so the Module arm runs, i.e. `IE` candidacy *and* `KeyBuckets`
selection both fire) declaring one impl per head kind in `impls.mdk` and calling each across
the module boundary from `main_heads.mdk`.

```
$ ./medaka run /var/tmp/p0q/heads/main_heads.mdk
run exit=0
int          ← Int            (primitive head)
str          ← String         (primitive head)
tup2         ← (Int, Int)     (2-tuple — __tuple2__-headed TApp spine, not a TTuple node)
tup3         ← (Int, Int, Int)(3-tuple)
pair         ← Pair Int Bool  (multi-arg application head)
SKIP-alias
listint      ← List Int       (imported-tycon head, one type argument)
```

**Heads covered: `Int`, `String`, 2-tuple, 3-tuple, multi-arg application (`Pair Int Bool`),
`List Int`. Head kinds NOT covered: a bare type-VARIABLE head (`impl Tag a`) — omitted because
it overlaps every concrete head above and coherence would decide the program rather than the
bucketing; and a rigid head, unreachable per §2.2.** I state that rather than writing "they
agree", per the brief.

**The one divergence found — type ALIAS heads** (`export type Alias = Bool`;
`export impl Tag Alias where tagOf _ = "alias"`):

```
$ ./medaka check /var/tmp/p0q/heads/impls.mdk
exit=0
-- /var/tmp/p0q/heads/impls.mdk: ok (0 declaration(s) checked, 0 errors)     ← ACCEPTED at decl

$ ./medaka run /var/tmp/p0q/heads/main_heads.mdk        (with `tagOf True` present)
exit=1
main_heads.mdk:9:12: No impl of Tag for Bool

$ ./medaka run /var/tmp/p0q/heads/main_alias.mdk        (receiver annotated `v : Alias`)
exit=1
main_alias.mdk:6:17: No impl of Tag for Bool
```

**An alias-headed impl is accepted at its declaration and is unreachable from every goal**, in
both spellings of the receiver. `headTyconTy` does not expand aliases, so the impl is bucketed
under `"Alias"` while every goal's `headTyconMono` spells `"Bool"`.

**Attribution, which is the part that matters for B-2.1:** this is an **impl-vs-GOAL**
divergence and it is **symmetric across the two tables** — both key the impl side through
`headTyconTy`, so `IE` spells it `"Alias"` exactly as `KeyBuckets` does. **A repointed reader
inherits it unchanged; it is not a B-2.1 delta.** It is a loud reject (exit 1 with a located
diagnostic), so S2/S3 at worst — I did not check the tracker for it and am **not** filing it;
recorded here because it is the one head kind where a naive reading of "the two projections
agree, therefore heads resolve" would mislead.

### 2.4 Verdict

✅ **No spelling disagreement is possible; §4.3's "derive the agreement on a fixture before
landing" is discharged.** The owed derivation should be **re-pointed** at the empty-`tys`
membership asymmetry (§2.2), which is real and which P0-A does not mention.

---

## Probe 3 — 🚨 which drivers take the **Flat** path? (`B-2.1-a` is load-bearing)

### 3.1 The two entries to `checkBodyImpl`, derived

`CheckMode` (`typecheck.mdk:20149`) has exactly two constructors, and exactly two functions
construct them:

- `checkProgramSeededSplit:20132` → `checkBodyImpl seed (Flat coreProg) userProg`
- `checkModuleFullImpl:25586` → `checkBodyImpl seedVars (Module mid accData implDecls) prog`

Derivation command (code lines only):

```sh
grep -rn 'checkProgramSeededSplit\|checkModuleFullImpl' compiler/ --include=*.mdk \
  | grep -v ':[[:space:]]*--'
```

### 3.2 The Flat-arm reachability set

Public typecheck APIs that reach the **Flat** arm:
`checkProgramSchemes` · `checkProgramSchemesWithRuntime` · `checkProgramSeeded` ·
`checkToLines` · `checkToLinesWithRuntime` · `checkErrorsWithRuntime` · `checkMatchToLines` ·
`checkProgramDiags` (via `seedAndCheckSplit:25472`) · **`elaborateDict`** (`:14120`, and
`discoverPromoted:14150`).

Public typecheck APIs that reach the **Module** arm:
`checkModuleFull` · `checkModuleFullDiags` · `checkModules` · `checkModulesDiags` ·
`checkModulesEntry{Report,HasErrors,Lines}` · `checkModulesAllLines` · `elaborateModules` ·
**`elaborateOne`** (`:14078-14081` — it is `elaborateModules … [(rootId, prog)]`, a 1-module
wrapper; **AGENTS.md's `runSingle` note is correct and I initially mis-attributed this**).

Mapped to drivers (`grep -rn … compiler/ --include=*.mdk | grep -v types/typecheck.mdk`):

| Driver / verb | Site | Arm |
|---|---|---|
| **`medaka check <no-import file>`** | `tools/check.mdk:81` `checkToLinesWithRuntime`, `:114` `checkErrorsWithRuntime` | **Flat** |
| `medaka check <import-bearing / project>` | `tools/check.mdk:134`, `:144` `checkModulesEntry*` | Module |
| **`medaka lsp`** | `tools/lsp.mdk:694` | **Flat** |
| **`medaka repl`** | `tools/repl.mdk:74`, `:217`, `:221` | **Flat** |
| **`medaka doc`** | `tools/doc.mdk:394` | **Flat** |
| **`medaka lint` / policy** | `tools/check_policy.mdk:523`, `:652`, `:698` | **Flat** |
| **`medaka snapshot`** | `tools/snapshot.mdk:497`, `:530`, `:604` (`elaborateDict`) | **Flat** (`:575` `elaborateOne` → Module) |
| single-file diagnostics | `driver/diagnostics.mdk:566` `checkProgramDiags` | **Flat** (`:838`, `:902` → Module) |
| `main_autoprint` | `driver/main_autoprint.mdk:126` | **Flat** |
| **`llvm_emit_typed_main`** | `entries/llvm_emit_typed_main.mdk:99` `elaborateDict` | **Flat** |
| **`wasm_emit_typed_main`** | `entries/wasm_emit_typed_main.mdk:100` `elaborateDict` | **Flat** |
| `core_ir_dict_pp_main` | `entries/core_ir_dict_pp_main.mdk:35` | **Flat** |
| `profile_main` | `entries/profile_main.mdk:172`, `:228` | **Flat** |
| `check_batch`, `typecheck_main`, `selfproc_tc_probe`, `check_match_main`, `origin_agreement_main:270` | — | **Flat** |
| `medaka run` / `build` / `test` (multi), eval entries, `core_ir_typed_main`, `entry_support:179/191`, `test_cmd:393` | `elaborateModules` / `elaborateOne` | Module |

`tools/check.mdk:127-131` states the CLI split in its own words: *"Kept separate from
`runCheck` so the no-import path stays byte-identical (**the CLI routes 1-module loads through
`runCheck`**)."* So **import-presence is the switch** for `medaka check`.

### 3.3 🚨 The behavioural discriminator — and it inverts P0-A's risk direction

Flattening issue **#1564**'s four modules into one no-import file changes nothing about the
program's meaning, and changes the arm from Module to Flat. Same conditional impl, same
`requires`, same goal.

```
$ ./medaka check /var/tmp/p0q/flat1564/flat.mdk
check exit=0
nest : Tag a => a -> String
main : Unit
-- /var/tmp/p0q/flat1564/flat.mdk: ok (2 declaration(s) checked, 0 errors)

$ ./medaka run /var/tmp/p0q/flat1564/flat.mdk
run exit=0
wrap(int)                                    ← the CORRECT answer

$ ./medaka check test/must_fail_fixtures/1564-import-order-decides-conditional-impl-candidacy/main.mdk
check exit=1
nest.mdk:3:16: Cannot pass a dictionary for `Tag (Wrap a)`: a matching `impl Tag …` does
exist in this program and is a candidate here, but this compiler cannot yet route its
evidence to this code — the impl is declared in a module that this one does not import. …
```

`/var/tmp/p0q/flat1564/flat.mdk` is `iface.mdk ++ nest.mdk ++ wrapimpl.mdk ++ main.mdk` with the
import lines removed and nothing else changed.

**What this establishes:**

1. **The Flat arm is live, and it is a real user-facing invocation** — not a probe-only path.
2. **The two arms give DIFFERENT answers on the same program.** `IE`-is-empty-on-Flat is not a
   quiescent fact; the Flat arm's own `buildKeyTable fullUniverse` / `buildImplUniverse prog`
   (`:20319`, `:20347`) is *whole-program*, which is why Flat is **already graph-global and
   already correct** for the #1564 class.
3. 🚨 **Therefore the risk `B-2.1-a` guards is a CORRECT→BROKEN regression on the arm that
   works today**, not (as P0-A's §5 `could move:` frames it) a substrate swap where *"the
   reader's substrate changes table but not content"*. If the reader is repointed onto `IE`
   and Flat's `IE` is empty or is seated with a narrower population, `medaka check <one file>`
   loses an answer it currently gets right. That is a loud→loud narrowing at best and a silent
   accept at worst, on the highest-traffic verb in the CLI.
4. `B-2.1-a` is **not** vestigial and its "⚑ FLAGGED AS A DECISION POINT" status is
   well-taken. The scope question the brief poses is answered: **load-bearing.**

Corroboration already in the tree for the same conclusion, from the *other* direction — the
ratchet's own `deImpls` row: *"reading the empty envelope there would have turned three live
rejections into silent accepts on `medaka check <one file>`, which is a severity INCREASE, not
a simplification"* (`test/registry_keying_ratchet.sh`, `cross_allowed`'s `declEnvsRef` row).
That is the identical hazard, already paid for once in A-3.5c, on the identical arm.

### 3.4 ⚠️ The instrument for this bite does not exist

`typecheck.mdk:14076-14077`, in `elaborateOne`'s own header, verbatim:

> `diff_flat_vs_onemodule.sh` **exists** to CHARACTERIZE where that difference (and the eval
> install order) actually changes OUTPUT.

```sh
$ find . -name 'diff_flat*' -o -name '*flat_vs*'      # (no output)
$ grep -rn 'diff_flat_vs_onemodule' --include=*.mdk --include=*.sh --include=*.md .
compiler/DRIVER-COLLAPSE-PLAN.md:77:  `test/diff_flat_vs_onemodule.sh` that runs every existing flat fixture through BOTH
compiler/DRIVER-COLLAPSE-PLAN.md:109:  `evalOutput`, plus `flat_vs_one_probe.mdk` + `diff_flat_vs_onemodule.sh`. KEPT
compiler/types/typecheck.mdk:14076:-- module path own the dict-set.  diff_flat_vs_onemodule.sh exists to CHARACTERIZE
test/snapshots/compiler/typecheck.md:14080:-- ... (the snapshot of the same line)
```

**It is planned in `DRIVER-COLLAPSE-PLAN.md` and asserted as existing in compiler source; there
is no such file.** `make agent-doc-symbols` cannot see it (it scans `AGENTS.md`, `.claude/**`,
`docs/spec/*.md` — not `.mdk` comments), and `make docs-links` does not read `.mdk` either. An
implementer told "characterize the Flat/Module output delta" will go looking for it and not find
it. §3.3's flattened-#1564 pair is the closest thing that exists and is offered as a starting
fixture.

---

## Probe 4 — the ratchet's current allowance, derived

The gate is grep-only; **it built nothing** (no `make`, no oracle, no `medaka` invocation).

```
$ sh test/registry_keying_ratchet.sh
exit=0
checking #1111 CrossRun / DriverState field allowlist ...
  ok: 23 CrossRun field(s), 22 DriverState field(s), 8 DeclEnvs field(s), 5 DeclEnvModule field(s), no new bundle field
checking #1111 crossRun / driverState setRef writer ratchet ...
  ok: 23 crossRun.value.* write target(s), 22 driverState.value.* write target(s), no rogue writer
checking #1111 three-way engine module-driver frame parity ...
  ok: cevalModules (core_ir_eval.mdk) seeds all 4 frame operations
  ok: evalModulesWith (eval.mdk) seeds all 4 frame operations
  ok: evalModulesRootEnvWith (eval.mdk) seeds all 4 frame operations
  ok: all 4 frame operations appear in exactly 3 places total (no phantom driver)
  ok: ctorFieldOrdersRef asymmetry unchanged (cevalModules-only, justified above)
checking #1112 A-3.4 IE namespace ratchet ...
  ok: IE block is 129 line(s), no non-IE namespace mint, no default-arm reach
checking #1519 A-3.3 CE construction ratchet ...
  ok: CE block is 197 line(s), no elaboration-machinery call, no excluded-table reach
PASS: #1111 registry keying ratchet (…)
```

**`cross_allowed` currently holds 23 rows** — the "23 CrossRun field(s)" the gate prints is
that count. Enumerated independently (do not trust the number; the command is the fact):

```sh
awk "/^cross_allowed='/,/'\$/" test/registry_keying_ratchet.sh \
  | awk 'NF{print $1}' | sed "s/^cross_allowed='//" | LC_ALL=C sort
```

→ `builtinClassesRef` · `coreSchemeObligationsRef` ·
`crossModuleFunConstraintIfaces{,Qual}Ref` · `crossModuleFunConstraints{,Qual}Ref` ·
`crossModuleMethodConstraints{,Qual}Ref` · `crossModuleSchemeOblsQualRef` ·
`universeCtorCollidedRef` · `universeCtorIdentsRef` · `universeDataEnv` ·
`universeFunNamesRef` · `universeIfaceMethodsRef` · **`universeKeyBucketsRef`** ·
`universeMethodCollidedRef` · `universeMethodDispatchIdxRef` · `universeMethodIdentsRef` ·
`universeMethodIfaceParamsRef` · `universeRecordByName` · `universeRecordCollidedRef` ·
`universeRecordIdentsRef` · `universeRegisteredIfacesRef` · `userIfaceNamesRef` — **23.**

**`universeKeyBucketsRef` IS an allowlist row**, so `B-2.1-d`'s deletion shrinks
`cross_allowed` **23 → 22** (the arc's next shrink) and correspondingly changes both the field
count and the writer count the gate prints. **`shadowKeyTableRef` is NOT in it** — it lives on
`PerRun`, which check 1 does not ratchet; deleting it moves no ratchet number.

### 4.1 Bonus — P0-A's §1 reader sets re-verified on this tree

`B-2.1-d`'s `nearest miss:` says STOP if the sets are not `{11216, 11503, 21715}` and
`{20348}`. Re-derived just now:

```sh
grep -n 'shadowKeyTableRef'     compiler/types/typecheck.mdk | grep -v ':[[:space:]]*--'
#  6726 (field) · 6821 (init) · 11216 READ · 11503 READ · 20347 WRITE(Flat) ·
#  20348 WRITE(Module) · 21715 READ
grep -n 'universeKeyBucketsRef' compiler/types/typecheck.mdk | grep -v ':[[:space:]]*--'
#  5883 (field) · 6005 (init) · 20348 READ · 25755 WRITE
```

✅ **Both sets are exactly as P0-A recorded.** The region has not changed.

### 4.2 🚨 Bonus — `B-2.1-c`'s site list is incomplete

```sh
grep -n 'implExistsForHead' compiler/types/typecheck.mdk | grep -v ':[[:space:]]*--'
# 11216  call   (inferShadowApp)
# 11503  call   (definerReceiverDispatches)
# 14857/14858/14862  def
# 14891-14895        implExistsForHeadGo
# 15014  call   (resolveRLocalSite)   ← NOT in P0-A's B-2.1-c "sites:" list
```

`:15014` reaches `implExistsForHead` with a **threaded `keyTable` parameter**, so P0-A's §1
table (scoped to `shadowKeyTableRef` readers) correctly excludes it — but `B-2.1-c` changes
`implExistsForHead`'s **signature** (`KeyBuckets` → `IE`/an accessor), and `:15014` is a call
of that function. **It must move in the same bite or the tree will not compile.** It is also
where the route-side definer short-circuit lives, so it is not a mechanical edit: whatever
population `:11503` ends up reading, `:15014` must read the same one, or the route/type
agreement the surrounding comment calls load-bearing (`:15008-15013`) breaks. Add it to
`B-2.1-c`'s sites.

---

## Probe 5 — the `RDict` skew coupling (**SOURCE READING, labelled as such**)

I did **not** construct a probe for this. Producing a genuine route-word skew requires editing
the compiler (changing one side of the tag/key split and not the other), which the brief
forbids. Everything below is read off the tree.

### 5.1 The coupling is REAL

`keyForSite` (`typecheck.mdk:17872-17887`) and `declRouteKey`
(`compiler/ir/core_ir_lower.mdk:1348`) implement the *same* tag-vs-key split **independently**,
and each cites the other by name:

- `typecheck.mdk:17860-17866`: *"The key/tag split deliberately mirrors
  `core_ir_lower.declRouteKey` … **the typechecker stamps this word into the caller's dict cell
  and the emitter derives the impl's own from `declRouteKey`, so the two must agree word for
  word.** Returning the canonical key for a UNIQUE headless head would have stamped `Tag|a|`
  where the emitter computes `__none__` — a dict-word skew invisible on the direct-call path
  this fixture exercises and live on the RDict path."*
- `core_ir_lower.mdk:1331-1336`: *"Mirrors typecheck's `keyForSiteByIface`: the bare head tag
  when that head is unique among the interface's declared impls … else the canonical full-type
  key — **the same word `keyForSiteByIface` stamps into the caller's dict cell.**"*
- `keyForSite`'s body carries the constraint inline: *"what the checker stamps into the dict
  cell has to keep matching `core_ir_lower.declRouteKey` byte for byte."*

✅ **P0-B's sequencing constraint (bite `e` must land with bite `b`, or back-to-back with no
build published between) is correctly derived.** Two separate implementations of one word, with
no mechanical tie between them, is exactly the drift shape.

### 5.2 "Silent" is **UNDERSTATED**, not overstated

P0-B argues silence from `ast.mdk:706-712` (under-application: *"check green, run
type-confused, build prints a raw PAP pointer"*). The stronger fact is in the emitter:
`emitDispatchChain` (`llvm_emit.mdk:5433-5440`) terminates a non-matching chain with

```
    None => emit e "  unreachable"
```

Not `@mdk_oob`. Every *other* non-exhaustive path in that file aborts through
`call void @mdk_oob()` (`:326-336`, `:2225`, `:3830`). A route-word miss reaching the chain's
end with no general entry emits LLVM **`unreachable`** — undefined behaviour, no diagnostic, no
guaranteed trap. **That is worse than silent-wrong-answer; it is silent-anything.**

⚠️ **But P0-B's citation is to the wrong route constructor.** `ast.mdk:706-712` documents
**`RLocal`**'s `List Route` — *"⚠️ S-1 / SHADOW-SEMANTICS clause S9: **RLocal** DOES carry
dicts"* — i.e. a shadowing standalone's own constraint dicts. The under-application mechanism
it describes is real and the analogy holds, but it is not a statement about `RDict`. Cite
`:17865-17866` (which names `RDict` explicitly) or `:5433-5440` instead.

### 5.3 🚨 But "live on the RDict path" is **OVER-READ** — two masking tiers

Neither is mentioned in P0-B, and both absorb precisely the tag↔key skew:

**Tier 1 — `implEntryRouteWords` (#1036 leg 2), `llvm_emit.mdk:1512-1518.** The dispatcher
already emits **an arm per possible word**, the union of `declRouteKey`'s answer and the bare
tag:

```
implEntryRouteWords e (CImplEntry m s (CImplTagged t k iface ps pats body)) = dedupS
  [ implEntryRouteKeyE e (CImplEntry m s (CImplTagged t k iface ps pats body)), t, ]
```

with the reason stated at `:1500-1506`: *"`keyForSiteByIface` picks the bare head tag when the
SITE'S MODULE sees no collision at that head and the canonical key when it does, so the impl
legitimately answers to both; which one arrives depends on the caller's imports, which the
shared dispatcher cannot know. **Emitting an arm per word makes the dispatcher accept the union
instead of betting on one.**" So a tag↔key skew in **either** direction still lands on an arm.

**Tier 2 — the general-entry catch-all.** `emitDispatchChain`'s `firstGeneralEntry` arm is
unconditional; only its *absence* falls through to `unreachable`. So a method that has a
general/headless impl absorbs any unmatched word — **which is exactly the population
`:17865`'s own example lives in** (`Tag|a|` vs `__none__` is a *headless* impl, i.e. a general
entry).

**Tier 3 — eval's peer.** `pickTagFallback` (`eval/eval.mdk:1053`) is the interpreter's arg-tag
punt; `keyForSite`'s own header, `:17849-17853`, warns about relying on it: *"Those three
fixtures pass because that tier catches them, not because the word did not move. If that tier
is ever narrowed, re-derive this — **a green suite here is evidence about the fallback, not
about the route word.**"*

**Net:** the live window for a tag↔key skew is narrower than P0-B states — a word in *neither*
the emitted union *nor* covered by a general arm. It is not empty (a method with ≥2 concrete
impls and no general one, where the stamped word is a third spelling), but the flat claim
"live on the RDict path" does not hold as written, and the tree says so in its own comment.

### 5.4 Consequence for P0-B's recommendation

The **sequencing constraint stands on its own merits** (§5.1) — two independent derivations of
one word must move together regardless of how well the failure is masked, because the masking
tiers are themselves scheduled for retirement (P0-B's `B2.2-*` retires `fromOption tag (…)`
outright). What should be **rewritten** is the *severity argument*: the honest form is *"a skew
is masked today by two hedges the same arc deletes, and the failure mode when it stops being
masked is LLVM `unreachable` — silent UB, no diagnostic"*, which is a stronger case for
co-landing than the one P0-B makes, and it does not rest on a citation about `RLocal`.

⚠️ **Label:** everything in Probe 5 is source reading. I did not observe a skew, and a
verification probe for it is **STILL OWED** — see below.

---

## STILL OWED

1. **A probe that observes an actual route-word skew (Probe 5).** Not constructible read-only:
   it needs one side of the tag/key split changed and the other not. The honest form is a
   **temporary two-arm build** — branch binary with `declRouteKey` inverted vs base binary —
   over a method with ≥2 concrete impls and **no** general/headless impl (to defeat Tier 2) and
   a genuine head collision (to make Tier 1's union carry two distinct words). Owed to whoever
   lands `B2.2-b`/`B2.2-e`; it is the positive control that shows the co-landing constraint was
   necessary rather than merely prudent.
2. **A bare type-VARIABLE-headed impl in Probe 2's head sweep.** Omitted deliberately: `impl
   Tag a` overlaps every concrete head in the same corpus, so coherence — not bucketing —
   decides the program, and the probe would stop discriminating. Covering it needs a corpus
   where the general impl is the *only* impl of its interface. The empty-`tys` case (§2.2) is
   likewise unprobed from the surface: I did not establish whether `impl I where` parses.
3. **Whether the empty-`tys` `IE`/`KeyBuckets` membership asymmetry (§2.2) is reachable from a
   surface program.** If it is not, it is a latent trap rather than a `could move:`; if it is,
   it is a `B-2.1-b` acceptance widening. Cheap for the implementer to settle and it changes a
   ledger field either way.
4. **The `medaka check --json` corroboration on Probe 3's Module arm.** I read the human
   `check` arm throughout, deliberately (#1362's silent-accept hole makes `--json` unreliable
   on multi-module projects and it is the arm under test here). A `--json` reading of the
   flattened-vs-modular #1564 pair would be a second channel, but per #1362 it may report exit
   0 on the rejecting arm — so it is owed *as a #1362 scope observation*, not as
   corroboration.
5. **`ieMethods`' adequacy for `implExistsForHead`'s method-name axis** (P0-A §7's second open
   item). Untouched here; Probe 1's verdict makes `B-2.1-c` safer but does not make the field
   adequate.
