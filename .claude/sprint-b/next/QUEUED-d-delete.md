# QUEUED — `B-2.1-d`: delete `universeKeyBucketsRef` + `shadowKeyTableRef`. Dispatch when `c` lands.

⚠️ **GATED ON `c`.** This bite is only reachable once `c` has repointed the last shadow readers. **If
`c` refused, partially landed, or left a reader behind — STOP and tell me.** A ref with a surviving
reader cannot be deleted, and that is the entire precondition.

## 🚨 Your packet: `.claude/sprint-b/design/P-d-packet.md` — AUTHORITATIVE. Read it first.

A prep pass pre-derived the reader/writer sets, the ratchet delta, the must-survive list, the stale
comments, and the exact greps for your `nearest miss:`. **Do not re-derive what it hands you.**
⚠️ It was written at pin `1e7cbbbb`, **before `c`** — so **re-grep every line number**, and expect
`shadowKeyTableRef`'s readers to have changed under you.

## The transformation

**Pure deletion.** Remove `universeKeyBucketsRef` and `shadowKeyTableRef`: field declarations,
initialisers, writers, and the arm gate that populated them. Nothing should read either by now.

## 🚨 THE ANTI-SCOPE LIST — deleting any of these breaks the route path

**These all STAY LIVE** (AM-1, and the `#415` block keeps `resolveRLocalSite` on its threaded
`keyTable`): `KeyBuckets` · `buildKeyTable` · `keyEntryOf` · `matchingEntries*` · `candidateBucket` ·
`mergeByDeclIdx` · `keyForSite*` · `headCollides*` · `countHead*` · `matchedEntry`.

**They will look unused if you only grep for the two refs — they are threaded as `keyTable`
PARAMETERS.** *"It looked unused"* is exactly how the route path gets broken. The packet lists a live
caller for each; verify, don't assume.

## Two ratchets move — both derive, neither quote

1. **`test/registry_keying_ratchet.sh`** — `universeKeyBucketsRef` **is** a `cross_allowed` row, so
   deleting it **shrinks the count.** ⚠️ **Derive the value by reading the script and running the
   gate; do NOT quote a number from any ledger.** A count in this arc has been wrong **four times**,
   and the arch doc's own figure was measured wrong in *both directions*.
2. **`test/typecheck_compiler_source.sh`** — holds an `OriginUnresolved` allowlist keyed on lines
   **inside `typecheck.mdk`**, and it is a **required CI check** (it caught a red this run that no
   local gate sees). If your deletion changes any listed line, update the list **with a justification
   comment**, following the convention its existing entries use.

## Stale comments — REWRITE, do not delete

Deleting these refs **retires a live defect**, which makes several comments false. The packet has
them with exact lines and quotes. The key fact: **`buildKeyTable` becomes `bucketKeyEntries`' sole
caller, so `mergeByDeclIdx`'s ascending precondition holds tree-wide** — and
`bucketKeyEntriesFrom`/`candidateBucket`/`mergeByDeclIdx` all currently document that it does *not*.
**Leaving them is how a later agent rediscovers a fixed bug.** *(The declaration-index defect is
fixed BY this deletion, not by repair — settled, do not re-litigate.)*

## Verification floor — REDUCED

**Run:** `medaka fmt --write` (**BEFORE building** — a prior writer lost ~4 min to a post-build
reflow) → `make medaka` → `check-self` → `diff_compiler_flat_vs_onemodule.sh` (13 rows) →
`sh test/registry_keying_ratchet.sh` (it moves — you own it) → `lint`.

**DO NOT RUN:** `selfcompile_fixpoint.sh`, corpus sweeps, full gate suites — CI's `soundness` shard
(draft PR #1605) and I own those. ⚠️ **Exception: at any sign of a codegen or dict-arity anomaly,
STOP and tell me.**

⭐ **A base binary may already exist in scratch** (`baseB/`, `postB/`, `mine/`) from an earlier bite —
**check before building one.** `compiler/**` files are whole-compiler compiles (~3/min under load);
scope any sweep and state its cost first.

## Deliverables

`DEBT.md` row + `🔗 DECISIONS.md RUN-B-0xx` cross-reference. **No `DECISIONS.md` entry — that ledger
is mine.** `engines:` one line if no compiled byte reaches an engine (name the four arms briefly:
LLVM · wasm · eval · `core_ir_eval`).

**`could move:`** — for a pure deletion this should be *"nothing at the language level"*, **but say
WHY**, and name the one real change: the `mergeByDeclIdx` precondition now holding tree-wide.

**`nearest miss:`** — *a FOURTH reader introduced between the packet's derivation and your deletion.*
**Re-run the packet's greps immediately before deleting and diff against its baseline.** If the sets
differ, **STOP and report** — the region changed under the unit.

**REFUSE AND REPORT.** Nine briefs corrected that way this run — including a prep pass that found
four errors in a brief before the implementer saw it.

## 📊 MANDATORY: TIME ACCOUNTING (~8 lines; cannot affect your verdict)
Split · biggest sink · **what you had to derive that the packet should have handed you** (scored
against ME, not you) · what of this brief was wasted · build cycles + which avoidable. **Reading and
thinking are NOT overhead and will never be counted against you**; only build churn and
report-writing are.
