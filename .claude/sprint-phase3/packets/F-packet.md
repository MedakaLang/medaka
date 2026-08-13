# Packet `B-2.2-f` — the declared-prefix sidecar

**Bite:** carry a per-entry **declared-prefix length** alongside the constraint **ids** table, so
`B-2.2-b1` can withhold identity from **appended super slots**.
**Branch:** `arch/stage-b-phase3-b22`. **Base for this bite:** `f203dcb2`.
**Worktree (absolute, always):** `/root/medaka/.claude/worktrees/expressive-prancing-minsky`

---

## 0. Concurrency, stated honestly

**You are the ONLY writer live.** The tree is quiescent, `git status` is clean, and the binary was
built from exactly this source. If the tree moves under you, **STOP and report** — do not adapt.

## 1. 🚨 There is NO `csDeclared` field, and adding one would be WRONG

The Phase 0 ruling (RUN-P3-015) said `csDeclared : Bool` on `CSlot`, decided at the fill sites as
`index < k`. **The prep pass refuted the field half of that and I accepted the refutation.** Do not
add a field to `CSlot`. Do not touch `data CSlot`. Do not touch any `CSlot` mint site.

**Why — the decisive fact.** Three sites mint the route word `b1` must withhold identity from. Two
hold `List CSlot`. **The third holds no `CSlot` at all:**

| site | what it holds | can a `CSlot` field serve it? |
|---|---|---|
| `inferDictAtFound:9170-9176` | `expanded : List CSlot` | yes |
| `shadowStandaloneDictSlots:12376-12379` | `expanded : List CSlot` | yes |
| `realizeRecDictApps:20140` → `recRoutes:20145` → `resolveRecMono:20161` | **`List Int`, straight out of `funConstraintsRef`** — no `CSlot` is constructed anywhere on this path | **NO** |

A `csDeclared` field serves 2 of 3 and leaves the recursive-call arm stamping identity on appended
slots — **the same "vacuous exactly where it must not be" failure that got options (1) and (2)
rejected, in a different guise.** A per-entry count keyed by callee name serves all three, including
the one with no slot record.

Second, independent reason: a field would have to be minted by all four `CSlot` mints — including
`pairSlots`, which is RUN-P3-010's defect verbatim. The field re-opens the exact hole the count was
ruled in to close.

**⇒ `f` = table plumbing + one read accessor. Zero mint edits, zero `data CSlot` edit.**

### Scope ruling: `f` touches NEITHER fill site

Land the plumbing, the accessor, and doctests — and **stop there.** The indexed read belongs to
`b1`, which is what actually stamps. This makes `f` **fully inert and provable by unmoved goldens**,
the same shape that made `a` reviewable. Binding `k` at the fill sites and doing nothing with it is
dead code that `fmt`/lint carry and review cannot judge.

## 2. Already settled — do NOT re-derive

1. `data CSlot` (`:5843`), `data CrossRun` (`:6186`) and `data PerRun` (`:7022`) are **all in the
   single-line, measured-safe class**, so #829's `fmt --write` record-comment corruption does not
   trigger. Under §1 you touch only the latter two.
2. `expandSupersIfaceEntry` is **non-idempotent** (it fabricates synthetic ids, so the ifaces entry
   grows one per module). **The sidecar rides the IDS table. Never key it to the ifaces table.**
3. `setFunConstraintTables`' documented fusion prohibition does **not** transfer: it exists because
   `expandSupersEntry` reads the pre-expansion *ifaces* table while producing the new ids table, and
   `k` is read and written by neither expansion function. **What does transfer is the pairing
   discipline** — every whole-table replacement of the ids table owes one of `k` (§3's list).
4. `CSlot`'s header permits a per-entry scalar: the hazard it names is a **length mismatch silently
   truncated by a zip**, and a scalar has no length and no zip. ⚠️ But `qualConstraintFor:9029` names
   the residual one level up — *"the two independent lookups still default to `[]` independently"* —
   so a k **table** re-creates that shape unless §4's two mitigations are applied.

## 3. The site list

All `compiler/types/typecheck.mdk`. Re-derive by symbol before editing:
```sh
grep -n 'funConstraintsRef\|crossModuleFunConstraint\|aliasConstraintEntries\|promotedConstraints\|setFunConstraintEntry\|expandSupers' compiler/types/typecheck.mdk
```

### Field declarations
| symbol | ~line | edit |
|---|---|---|
| `data PerRun` | `:7057` | add `funConstraintDeclaredRef : Ref (List (String, CDeclaredPrefix))` |
| `freshPerRun` | `:7152` | `Ref []`. Reset is free — `resetState:7203` is `setRef perRun (freshPerRun ())` |
| `data CrossRun` | `:6260` | add **two**: `crossModuleFunConstraintDeclaredRef` (bare) + `…QualRef` |
| `freshCrossRun` | `:6322` | both `Ref []`. Reset free via `resetCrossModuleState:6351` |

### Where `k` is COMPUTED and WRITTEN — **FIVE sites, and RUN-P3-015 listed only three**
| symbol | ~line | edit |
|---|---|---|
| `setFunConstraintEntry` | `:25043` | the entry append. **Record `k = listLen (dedupSlots slots)`** — see §4 trap 1. Write it in the *same* op as the ids write so the two can never be written apart |
| Module seed, bare | `:21105` | mirror from the crossRun bare k table |
| Module seed, alias prepend | `:21107` | mirror with the qual k table. ⚠️ `aliasConstraintEntries:27250`/`aliasEntriesFor:27258` are typed `List ((String,String), List a)` — a bare scalar payload **does not fit**. Generalize `List a` → `a` in both signatures; bodies pass `snd e` through unchanged and every existing caller still typechecks |
| Module snapshot, bare | `:21364` | mirror |
| Module snapshot, qual | `:21366` | needs a scalar-payload attribution. `attributeModuleArities:29154`/`attributeModuleArrIfaces:29168` are already two structural duplicates each carrying `-- lint-disable-next-line rule-duplicate-body` (#1201). **A third copy needs a third disable or the lint ratchet blocks the commit. Preferred: generalize to one function and DELETE both disables** |
| 🚨 **the joint-discovery snapshot** | **`:14600-14612`** | `promotedConstraints … funConstraintsRef` → `expandSupersCross` → `setCrossFunConstraintTables`. **A whole-table write of the crossRun bare pair, and it is what module 1 is seeded from at `:21105`.** Without a companion, **every promoted cross-module callee reaches every fill site with no `k` and `f` ships VACUOUS.** ⚠️ The expansion happens *after* the filter — `k` must be the **pre-expansion** count from the perRun k table, filtered by the same `promoted` list |

### Where `k` is deliberately NOT owed — and this is the proof it must be optional
`:29056` (`dictPassModulesIfEnabled`) and `:29088` (`dictPassModulesScoped`) are whole-table
replacements built from `scopeArities`, which has no `k` to give. They are **writers**, not the
"count-only readers" RUN-P3-015 called them; their written table is only ever read for its **length**
(`dictArityOf`'s own comment: *"Only the COUNT is read here"*), and **no fill site runs after
dict-pass**. So absence here is *correct* — which is exactly why `k` cannot be a mandatory column.

### Where `k` is READ
`declaredConstraintSlots:9113` is the **only** accessor both fill sites use, and it makes a three-way
decision (qual hit / known-import miss ⇒ `[]` / bare fallback).
🚨 **Do NOT add a parallel `declaredConstraintK`.** Two readers re-deriving the same entry choice is
the drift the tree already paid to remove — `qualConstraintKey:9050` was factored out *"so
`qualConstraintFor` (slots) and `qualConstraintIds` (ids only) cannot drift on WHICH entry they
resolve to."* **Return `k` from `declaredConstraintSlots` itself** (e.g. a small record with the
slots and the prefix), one decision, one site.

## 4. 🚨 Two arithmetic traps — one of them is now MEASURED

**Trap 1 — `dedupSlots` shrinks the declared prefix. WITNESSED, not theoretical.** I instrumented
`setFunConstraintEntry` and ran it:

```
twice : (Shw a, Shw a) => a -> Int      -- one tyvar, duplicated constraint
runtime error [E-PANIC]: PROBE-F-M1 twice 2->1
```

Two declared slots collapse to one. **If `k` were recorded as `listLen slots` = 2, `index < k` would
mark the first APPENDED slot as declared** — the unsafe direction, silently.
⇒ **`k = listLen (dedupSlots slots)` is MANDATORY, with a witness.** Put that program in the bite's
doctests or as a fixture; it is a ready-made discriminator.
⚠️ It did **not** fire anywhere in a full `make medaka` (the whole compiler + stdlib through the
typechecker), so it is absent from the compiler's own corpus and only reachable from user source.
A test that only compiles the compiler will not catch a regression here.

**Trap 2 — `pairSlots` truncates to the shorter of (ids, ifaces).** If `slots` comes back shorter
than the recorded `k`, `index < k` again marks appended slots declared. **Read
`kEff = min k (listLen slots)`.** ⚠️ RUN-P3-015 claimed a mismatch *"clamps loudly"* — **it does
not; nothing clamps it today, you write the `min`.** I instrumented this one too and it did **not**
fire on a full compiler build or on a two-module probe, so it is **unwitnessed**: keep the `min`
(one token, free) and record it in `unchecked:` as defensive rather than measured.

## 5. 🚨 Fail-closed: what an ABSENT `k` means

**Rule: `absent ⇒ WITHHOLD identity`** (behaves as prefix 0). The opposite stamps identity onto
appended super slots — the exact defect `f` exists to prevent.

**Do NOT spell absence as `0`, and do NOT spell it `Option Int`.** `k = 0` is a genuinely reachable
*recorded* state (`registerMember:25068` guards on `ifaceMonos` being non-empty, **not** on `slots`,
so an entry with zero declared slots is real). And `fromOption 0 kOpt` is one idiomatic, invisible
token — the collapse RUN-B-013 condition 1 forbids by name, with `fromOption` at 99 uses in
`compiler/`. Use a two-valued type, exactly as AD-2 ruled for the Phase 4 carrier:

```medaka
data CDeclaredPrefix = CDPUnknown | CDPLen Int
```

`CDPUnknown` has **no prelude eliminator** and is a token that exists nowhere else in the tree, so
*"is any site collapsing absence into a length?"* is one grep. It also makes the vacuity measurement
(§7 M-3) possible at all — you cannot count unknown arrivals if absence is spelled `0`.

**Populations that can reach a fill site with no `k`** — enumerate these in your `DEBT.md` row:
every promoted cross-module callee if `:14600-14612` is not mirrored (**the big one**); aliased
imports if the qual table is not mirrored at `:21107`; a qual ids hit whose qual **k** entry misses;
the E6 dict-pass reseed (**correct** to be absent). The `hasImportDefiner` arm returns `[]` and is
vacuously fine.

## 6. `test/registry_keying_ratchet.sh` — **TWO rows, not four**

RUN-P3-015 said four. **It is two**, and the derivation is one line: check 2's allowlist is
*computed from* check 1's at `:362` (`sed 's/^/crossRun.value./'` over `cross_expected`), so **adding
a field row automatically admits its `setRef crossRun.value.<field>` writer.**

Row format — one per line inside the single-quoted `cross_allowed='…'` string (siblings at
`:187-190`):

```
crossModuleFunConstraintDeclaredRef -- cross-module DECLARED-PREFIX sidecar to crossModuleFunConstraintsRef; per-entry scalar, not a slot-parallel list -- B-2.2-f (#1113)
crossModuleFunConstraintDeclaredQualRef -- module-qualified mirror of the line above, keyed (definer module, fn name), resolved through the same qualConstraintKey decision as the ids and ifaces qual tables
```

Hard constraints, all derived:
- 🚨 **No apostrophes anywhere in the reason** — the allowlist is a single-quoted shell string.
  Existing rows write `` module`s `` with a backtick for exactly this reason.
- First whitespace token must be the field name; sort order is irrelevant.
- Field extraction keys on the header line — keep `data CrossRun = CrossRun {` **byte-exact** and put
  each field on its own `name : Type,` line.
- **`PerRun` is not pinned by this ratchet** — the perRun ref needs no row.
- The script is **grep-only, no binary, no oracle**: run `sh test/registry_keying_ratchet.sh`
  directly. It rides in `typecheck_compiler_source.sh` (the `soundness` job), not `ci.yml`.

## 7. Verify — gate your own work

```sh
make -C <worktree> medaka && make -C <worktree> check-self
sh test/registry_keying_ratchet.sh          # grep-only, no build needed
./medaka lint compiler/types/typecheck.mdk  # see §3's third-duplicate warning
./medaka fmt --check compiler/types/typecheck.mdk
```

**Expected of this bite: it is INERT.** Nothing reads `k` yet, so no route word, dict arity or
emitted symbol may change. **If a golden moves, STOP and report** — that contradicts this packet.

🚨 **BLESS ZERO GOLDENS.** Snapshot / `selfproc_legA` / `llvm_typed_ir` / must-fail are expected-red
for the sprint by design (`.claude/HANDOFF.md`); they are re-cut **once** at the close-out.

**One measurement is owed AFTER your plumbing exists, and it is the one that decides whether `f` is
a real feature or an empty one** — the orchestrator will run it, but flag anything you learn:
instrument the fill site to report the first `CDPUnknown` arrival and run it over a two-module
constrained-callee program. If it fires, a write site is missing — almost certainly `:14600-14612`.

## 8. Traps that apply to you

- **`!=`, not `/=`** — Medaka's inequality. (I lost a build to this an hour ago.)
- `medaka fmt --write` and `medaka lint` on the touched file **before** `make` — cheap checks first.
- **Exit codes do not survive a pipe.** Redirect to a file and read `$?`.
- **`main` must be a zero-arg value** in any probe (`main = println …`).
- **Do not name a probe method after a prelude method** (`add`/`sub`/`mul`/…): measured this
  session, a method named `sub` makes the built binary print a leaked pointer at exit 0.
- **Absolute paths everywhere**; the shell cwd resets between calls.
- ⚠️ `MEDAKA_STRICT=1` will hard-fail after you edit compiler source until you rebuild. That is the
  staleness guard working, not a break.

## 9. Refuse, explicitly

**Report disagreements rather than silently resolving them.** This packet has already been wrong
twice in one bite's lifetime: the ruling said add a `CSlot` field (refuted), and it said four ratchet
rows (it is two). **If §1's scope, §3's site list, or §5's absent-state rule does not survive contact
with the source, STOP and report with your derivation.** Every refusal in the two prior sprints
caught a defect in the orchestrator's scoping, two of which would have shipped as S0s behind a green
`check`. **A refused bite is landed work.**

## 10. Closing section, mandatory

End with **TIME ACCOUNTING**: split (orientation · derivation · edits · build/gate · report) ·
biggest sink · **what did you have to DERIVE that this packet could have handed you?** · what of this
packet was wasted · build cycles and which were avoidable.

**Reading and thinking are PRODUCTIVE** — only build churn and report-writing are overhead. Your
derivation time is a readout of this packet's quality, not your speed.
