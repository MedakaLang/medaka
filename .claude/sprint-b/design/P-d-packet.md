# P-d packet — `B-2.1-d`: delete `universeKeyBucketsRef` and `shadowKeyTableRef`

**Pin: `1e7cbbbb`** (= `B-2.1-b2`, the S0 drain). Every line number, every set, and every
count below is derived at that commit and nowhere else. `1e7cbbbb` is **after** the drain
bite and **before `B-2.1-c`**, which is repointing the two importer-shadow readers *right
now* — so this packet's job is to say which readers exist at the pin and which of them `c`
is expected to take away.

Read the pin, not the tree: `git show 1e7cbbbb:compiler/types/typecheck.mdk > /var/tmp/x.mdk`.
The working-tree copy is being edited under you.

---

## 1. The complete reader/writer sets at `1e7cbbbb` (code lines only)

Derivation (comment lines stripped by hand — every hit below was read in context, and the
comment-only hits are enumerated separately in §4 rather than silently dropped):

```sh
grep -n 'universeKeyBucketsRef\|shadowKeyTableRef' compiler/types/typecheck.mdk \
  | grep -v ':[[:space:]]*--'
```

### `universeKeyBucketsRef` — 1 declaration, 1 initialiser, 1 writer, 2 reads

| Line | Kind | Site | Fate |
|---|---|---|---|
| `6177` | **field decl** | `data CrossRun = CrossRun {` — `universeKeyBucketsRef : Ref (OrdMap (List KeyEntry)),` (type written inline, *not* as `KeyBuckets`, because the alias is declared below the record) | **delete** |
| `6299` | **initialiser** | `freshCrossRun` — `universeKeyBucketsRef = Ref omEmpty,` | **delete** |
| `26376` | **write** (+ self-read of `.value` as the fold accumulator) | `appendUniverseAccums` — `setRef crossRun.value.universeKeyBucketsRef (bucketKeyEntries (flatMap keyEntryOf prog) crossRun.value.universeKeyBucketsRef.value)` | **delete this one statement**; the surrounding function has 8 other accumulator lines and stays |
| `20904` | **read — the ONLY external one** | `checkBodyImpl`'s Module arm — `Module _ _ _ => setRef perRun.value.shadowKeyTableRef crossRun.value.universeKeyBucketsRef.value` | **delete with the `shadowKeyTableRef` write it feeds** |

**Consequence: `universeKeyBucketsRef` is reachable by nothing except `shadowKeyTableRef`.**
Its only read is the pointer copy at `20904`. So its deletion is *entirely* gated on
`shadowKeyTableRef` losing all readers — there is no independent question to answer.
`resetCrossModuleState` / `freshCrossRun` are the only other places CrossRun fields are
touched wholesale; check `freshCrossRun` is the only initialiser (it is — `6296`).

### `shadowKeyTableRef` — 1 declaration, 1 initialiser, 2 writers, **2 code readers**

| Line | Kind | Site | Fate |
|---|---|---|---|
| `7020` | **field decl** | `PerRun` — `shadowKeyTableRef : Ref (OrdMap (List KeyEntry)),` (**no trailing comment on this line** — see the #829 note in §6) | **delete** |
| `7116` | **initialiser** | `freshPerRun` — `shadowKeyTableRef = Ref omEmpty,` | **delete** |
| `20903` | **write**, Flat arm | `Flat _ => setRef perRun.value.shadowKeyTableRef (buildKeyTable fullUniverse)` | **delete** (this is one of `buildKeyTable`'s three call sites — see §3) |
| `20904` | **write**, Module arm | pointer copy of `universeKeyBucketsRef` | **delete** |
| `11548` | **READ** | `inferShadowApp` (def `11535-11536`) — `Some head => if implExistsForHead perRun.value.shadowKeyTableRef.value mname head then …` — the importer-shadow **APP** path | 🚦 **`c` removes it** |
| `11835` | **READ** | `definerReceiverDispatches` (def `11830-11836`) — `implExistsForHead perRun.value.shadowKeyTableRef.value name head` | 🚦 **`c` removes it** |

Both `20903` and `20904` are arms of one `let _ = match mode` at `20902`, so the writer
deletion is that whole 3-line statement (the comment above it at `20900-20901` goes with it).

### 🚦 The gating answer: survives vs. `c`-removes

**Zero readers survive `c`.** The two at `11548` / `11835` are exactly `c`'s scope, and they
are the *complete* set at the pin:

- The **third** reader that older ledgers name — `resolveRLocalSite` at `15352`,
  `(not (isDefinerShadow name) && implExistsForHead keyTable name tag)` — **is already off
  the ref at this pin.** It takes its table as a **threaded `keyTable` parameter**
  (`resolveRLocalSite : List Decl -> ImplBuckets -> KeyBuckets -> …`, `15329`), so a
  ref-grep does not see it and it does **not** block deletion. Per AM-1 / the `#415` block
  it **stays on its threaded table**; that table is `buildKeyTable`'s result (see §3), not
  this ref. **Do not "clean it up".**
- `implExistsForHead` itself (`15195`) **survives** — after `c` its only caller is `15352`,
  through the threaded table.

So the precondition to verify before deleting is exactly: **`grep` for
`perRun.value.shadowKeyTableRef` returns zero code lines.** §5 gives the commands.

### Outside `compiler/types/typecheck.mdk`

```sh
git grep -n 'universeKeyBucketsRef\|shadowKeyTableRef' -- compiler/
```

At the pin, for these **two ref names**, the only non-`typecheck.mdk` hits under `compiler/`
are **prose**, and the earlier survey's list has *moved* — `core_ir_lower.mdk` and
`llvm_emit.mdk` no longer mention either ref (their surviving hits are `keyForSite` /
`KeyBuckets`, both of which **stay live**, so those comments do not become lies):

| File:line | Status after deletion |
|---|---|
| `compiler/types/registry.mdk:682` | *"B-2.1-b2 repointed this leg off the topological-prefix `shadowKeyTableRef`"* — **past tense, stays TRUE.** Leave it. |
| `compiler/DIAGNOSTIC-CODES-DESIGN.md:189` (`T-REQUIRES-UNROUTED` row) | 🚨 **BECOMES A LIE.** It states the cause as *"the evidence reader `concreteReqMatchByIface` still consults `shadowKeyTableRef`, copied from the CUMULATIVE `universeKeyBucketsRef`"*. `concreteReqMatchByIface` was already deleted by `b2`; after `d` both refs are gone too. **Rewrite, do not leave** — this row is what a future agent reads to decide whether `T-REQUIRES-UNROUTED` can drain. |
| `compiler/TYPECHECK-TARGET-ARCHITECTURE.md:1819` | The deferral row this bite **cashes**: *"`universeKeyBucketsRef` / … | **DEFERRED → B-2, by DELETION.** Must not appear in the diff"*. Mark landed; note that only the **ref** half landed — `buildKeyTable`/`keyEntryOf`/`matchingEntries*`/`keyForSite*`/`headCollides*`/`implExistsForHead` in that same cell **stay live** (§3). |

🚨 **`compiler/*.md` is DELIBERATELY OUT of `check_agent_doc_symbols.sh`'s scope** (its own
header, ~line 161: 173 dead findings vs docs/spec's 7), so neither of those two doc rows is
gate-enforced. They are the "later agent rediscovers a fixed bug" hazard, not a red build.
**The gate delta is in §2b instead, and it is real.**

---

## 2. Ratchet delta

### 2a. `test/registry_keying_ratchet.sh` — one row out of `cross_allowed`, **23 → 22**

Derived, not quoted:

```sh
# expected side — the allowlist rows
sed -n '/^cross_allowed=/,/^driver_allowed=/p' test/registry_keying_ratchet.sh \
  | awk 'NF{print $1}'
# actual side — the record itself, exactly as check 1 extracts it
sed -n '/^data CrossRun = CrossRun {$/,/^  }$/p' compiler/types/typecheck.mdk \
  | sed -E 's/[[:space:]]*--.*$//' \
  | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*:.*/\1/' \
  | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' | LC_ALL=C sort | grep -c .
```

At `1e7cbbbb` both sides are **23**, and they are set-equal (that is why check 1 is green).

- **The row to delete: `test/registry_keying_ratchet.sh:175`**, beginning
  `universeKeyBucketsRef -- accumulated impl-existence key buckets (implExistsForHead); A-2.2b moved it onto the RegKey substrate …`. It is one physical line (the rows are
  newline-separated inside a single-quoted heredoc-ish string; the reason text runs to the
  end of that line). Delete the whole line.
- **New expected value: 22 rows in `cross_allowed`, 22 fields in `CrossRun`.**

⚠️ **Check 1 is a SET EQUALITY, not a count** (`if [ "$cross_actual" != "$cross_expected" ]`,
~`:302`). There is **no hardcoded number to edit** anywhere in the script. Nothing prints
"23". So "22" is a fact about *your* diff, not a constant you must update — deleting the
field without deleting the row fails with a set diff, and vice versa.

⚠️ **`shadowKeyTableRef` has ZERO ratchet delta.** The ratchet gates `CrossRun`,
`DriverState`, `DeclEnvs` and `DeclEnvModule` field sets; `PerRun` is **not** gated by any of
the four. Measured on the script at the pin: `universeKeyBucketsRef` occurs **exactly once**
(line 175) and `shadowKeyTableRef` occurs **zero times**. No check in the script references
`KeyEntry`, `bucketKeyEntries`, `buildKeyTable`, `keyForSite`, or `implExistsForHead` either
(the only `implExistsForHead` hit is inside line 175's own reason text).

### 2b. 🚨 The gate delta nobody has named: `docs/spec/SHADOW-SEMANTICS.md` reds `make agent-doc-symbols`

`test/check_agent_doc_symbols.sh` scans `docs/spec/*.md` in its **SCOPED** tier, and a
backticked token that resolves nowhere in `compiler/*.mdk` + `stdlib/*.mdk` + `runtime/*.c`
is a finding. **`shadowKeyTableRef` is backticked in four places there and is NOT in
`test/AGENT-DOC-SYMBOL-EXCEPTIONS.txt`** (checked: zero hits for either name):

```
docs/spec/SHADOW-SEMANTICS.md:1742   -- the S2 type+record (importer) row: "impl query table `shadowKeyTableRef` (`:11217`, …)"
docs/spec/SHADOW-SEMANTICS.md:1855   -- "… or its `shadowKeyTableRef` impl query doesn't span …"
docs/spec/SHADOW-SEMANTICS.md:1868   -- "… `shadowKeyTableRef` so live-impl receivers still dispatch"
docs/spec/SHADOW-SEMANTICS.md:1879   -- "`shadowKeyTableRef` seeded from the global …"
```

Re-derive before acting (it may have moved if `c` touched the spec):

```sh
git grep -n 'shadowKeyTableRef\|universeKeyBucketsRef' -- docs/ .claude/workstreams/ \
    .claude/skills/ .claude/ORCHESTRATING.md AGENTS.md
grep -n 'shadowKeyTableRef\|universeKeyBucketsRef' test/AGENT-DOC-SYMBOL-EXCEPTIONS.txt
```

**Coordination point, decide it explicitly rather than discovering it:** `c` is the bite
that repoints those two readers, so `c` may already rewrite these cells. If it does not,
**`d` owns them**, because `d`'s deletion is what makes the symbol dead. Do **not** add an
exceptions row — the symbol is being *deleted*, not renamed into a place the gate can't see;
the honest edit is to name the substrate `c` lands (the `implExistsForHead`-over-`IE`
successor) in those four cells. `.claude/STAGE-B-SPRINT.md` and `.claude/sprint-b/**` are
**not** in the gate's `git ls-files` globs, so the sprint docs cost nothing.

### 2c. `test/typecheck_compiler_source.sh` — **EMPTY. No change.**

Its `OriginUnresolved` allowlist (`tc_originun_allowed`, `:448-459`) is keyed on **line TEXT**,
not line numbers (`grep -w 'OriginUnresolved' … | sort` compared to the literal list, `:460`).
None of the eleven allowed lines mentions either ref, and none of the nine lines this bite
deletes contains `OriginUnresolved`. Deleting these refs changes nothing on that list.
One line, as promised.

---

## 3. Anti-scope: what MUST survive, each with its live caller at the pin

Per AM-1 (`DECISIONS.md:236-237`), B-2.1's deletion budget is **exactly the two refs**.
Verified at `1e7cbbbb` — every one of these has a live caller **after** the deletion:

| Symbol | Def | Live caller(s) after the deletion |
|---|---|---|
| `KeyBuckets` (type alias) | `17926` | ~30 signatures on the route path: `resolveSites:15121`, `resolveArgStamps:6525`, `resolveOpSites:15486`, `resolveDictApps:19435`, `routeOf:19624`, `undeterminedRoute:19649`, the four `EK*` constructors (`19471`,`19482`,`19491`,`19497`), … |
| `buildKeyTable` | `18075` | **`14461`** (`let keyTable = buildKeyTable prog2`) and **`29303`** (`let stampKeyTable = buildKeyTable implDecls`). `20903` is the third and is the one you delete → **2 callers remain** |
| `keyEntryOf` | `18149` | `18077`, inside `buildKeyTable`. (`26376` is the other and you delete it → **1 caller remains**) |
| `bucketKeyEntries` | `18084` | `18077`, inside `buildKeyTable`. (`26376` is the other → **`buildKeyTable` becomes its SOLE caller**. This is the whole of §4.) |
| `bucketKeyEntriesFrom` | `18095` | `18085`, `18102` (self) |
| `keyForSite` | `18224` | `15624` (`stampOpRouteVal`), `19557`, `19600` |
| `keyForSiteByIface` | `19087` | `19585` |
| `matchedEntry` | `18269` | `18225` |
| `matchingEntries` | `18288` | `18271` |
| `matchingEntriesGo` | `18423` | `18290`, self |
| `candidateBucket` | `18398` | `18290` (from `matchingEntries`) |
| `mergeByDeclIdx` | `18416` | `18401` (`candidateBucket`), **`18996`/`19002`** (`ieCandidatesForIface` / `ieCandidatesForMethod` — the `IE` selectors `b2` landed; deleting this breaks the *new* route path, not only the old one) |
| `headCollides` | `18795` | `18227` (inside `keyForSite`) |
| `countHead` / `countHeadGo` | `18869` / `18874` | `18796` / `18872`, self |
| `implExistsForHead` / `…Go` | `15195` / `15229` | after `c`: **`15352`** only, via the threaded `keyTable`. Two of its three callers (`11548`, `11835`) are `c`'s |
| `KeyEntry` / `keyEntryIdx` / `keyEntryOfRow` / `keyEntryIface` / `bucketOfHead` / `pickMostSpecificEntry` / `findMostSpecificEntry` / `entryCovers*` | `18068`, `18072`, `18939`, `18619`, `18136`, `18457`, `18676`, `18685`/`18694` | all reached from the surviving `keyForSite` chain **and** from `ieEntriesForIface`/`ieEntriesForMethod`/`ieRowOfEntry` (`18961`,`18970`,`19038`) |

**Nothing on this list becomes unreachable.** If your diff deletes anything above,
you have exceeded the bite. The `#415` block keeping `resolveRLocalSite` on its threaded
`keyTable` (`15329`, `15352`) is likewise untouched.

Nothing here *looks* deletable-but-isn't beyond the two already flagged: `bucketKeyEntries`
loses one of its two callers, and `implExistsForHead` loses two of its three. Both keep a
caller. `mergeByDeclIdx` is the trap most likely to be mis-audited, because two of its three
callers are the brand-new `IE` selectors rather than the old bucket path.

---

## 4. Stale-comment sweep — three comments whose *live defect* the deletion RETIRES

The mechanism is one sentence: **once `26376` is gone, `buildKeyTable` (`18075-18077`) is
`bucketKeyEntries`' sole caller**, and `buildKeyTable` passes `omEmpty` and applies
`omMapValues reverseL` per bucket. So every `KeyBuckets` value in the tree is
`omEmpty`-seeded, forward-ordered and index-unique — **`mergeByDeclIdx`'s ascending
precondition holds tree-wide, structurally.** All three comments below record the *violation*
as live. Leave them and a later agent rediscovers a fixed bug.

### (a) `bucketKeyEntriesFrom`'s duplicate-index warning — `18087-18094`

Currently false, verbatim:

> `-- ⚠️ A-2.2b: the per-module declaration-index numbering is UNCHANGED.  This`
> `-- function still starts at 0 on every call and \`appendUniverseAccums\` still`
> `-- re-enters it once per module with a non-empty accumulator, so indices still`
> `-- DUPLICATE across modules within one bucket of \`universeKeyBucketsRef\` and`
> `-- each module's slice is still prepended (descending).`

**Every clause of that dies with `26376`.** Replace with the positive property, and say what
would reintroduce the defect — that is the part a future agent needs:

> ⚠️ B-2.1-d: `buildKeyTable` is now this function's SOLE entry point, and it passes
> `omEmpty` and reverses each bucket. So the numbering starts at 0 **once per table**:
> indices are unique within a table and each bucket is in ascending declaration order —
> which is exactly `mergeByDeclIdx`'s precondition, now holding structurally rather than
> by convention. It was violated until `appendUniverseAccums`' per-module re-entry with a
> non-empty accumulator was deleted with `universeKeyBucketsRef`. **Any new caller that
> passes a NON-EMPTY accumulator reintroduces duplicate indices and breaks that
> precondition** — pass `omEmpty`, or don't call this.

### (b) `candidateBucket`'s "does NOT hold for `universeKeyBucketsRef`" note — `18319-18348`

Three paragraphs. `18333-18348` (the `✅ ARCH B-2.1-b2` paragraph) is already the honest
state and is *nearly* right; the sentence that goes stale is its last clause, `18343-18344`:

> `--      declaration order.  \`universeKeyBucketsRef\` still has the property; what`
> `--      changed is that no \`mergeByDeclIdx\` consumer reads it.`

and the paragraph at `18327-18331` that it refers back to:

> `--      It does NOT hold for \`universeKeyBucketsRef\`: \`appendUniverseAccums\` calls`
> `--      \`bucketKeyEntries\` once per module with a NON-EMPTY accumulator, so`
> `--      \`bucketKeyEntriesFrom\` restarts at 0 (indices DUPLICATE across modules within`
> `--      one bucket) and nothing ever reverses it (each module's slice is in`
> `--      DESCENDING index order).`

**Collapse both into the finished statement**: the violating table no longer exists, so the
precondition holds on every table this function can be handed —
`buildKeyTable`'s (`14461`/`29303`, the route word) and `ieHeadRows`' (ascending
`instRefSeq` by construction). Keep the *history* in one sentence (`b2` fixed it by moving
the selectors; `d` fixed it by deleting the table) because that history is what stops the
next agent re-adding a cumulative accumulator. **Do NOT delete `18350-18362`** — the
"why recorded rather than fixed" / F-3c residual paragraph is about
`pickMostSpecificEntry`'s non-closed-goal fallback and is **still live and unrelated**.

### (c) `mergeByDeclIdx`'s precondition comment — `18405-18415`

> `-- ⚠️ The PRECONDITION — both operands ascending by index — is a property of the`
> `-- CALLER'S TABLE, not of this function, and it does not hold everywhere. … Both halves`
> `-- are wrong for \`universeKeyBucketsRef\`: \`appendUniverseAccums\` re-enters`
> `-- \`bucketKeyEntries\` per module with a non-empty accumulator, so the numbering`
> `-- RESTARTS AT 0 within one table (indices duplicate) and each module's slice is`
> `-- prepended, never reversed (descending).`

**The "and it does not hold everywhere" framing is now false**, and it is the most dangerous
of the three: it tells a reader the function is called with unsorted operands today. New
text should keep the first clause (it *is* a caller property — that is still worth stating,
and it is what makes a future violation possible) and replace the counter-example with the
enumerated callers: `candidateBucket` over `buildKeyTable`'s reversed `omEmpty`-seeded table,
and `ieCandidatesForIface`/`ieCandidatesForMethod` over `ieHeadRows` keyed on `instRefSeq`, a
whole-graph counter appended in build order. **All three operands ascending; the one table
that violated it is gone.** Keep the final sentence (unsorted operands still terminate
deterministically) — it is a property of the code, not of the callers.

⚠️ Also update the two forward references that point *at* these paragraphs:
`18092-18093` ("*That is the property `candidateBucket`'s doc-comment records as violating
`mergeByDeclIdx`'s ascending precondition*") and `18413` ("*See `candidateBucket` for which
consumers that reaches*"). If (b) stops recording a violation, those cross-references dangle.

### Comment-only mentions of the two refs (14 more sites) — triage, not a sweep

For completeness, so nobody has to re-derive it. These are **prose hits only**, in
`typecheck.mdk`, at the pin: `2447`, `4341`, `4355`, `6834`, `11683`, `15305`, `18885`,
`20950`, `22244`, `22288`, `22773`, `25501-25502`, `25521`, `26359`, `28244`. Most are
historical/past-tense and stay honest. Four are worth reading before you commit, because
they are present-tense statements about a ref that will not exist:

- `11683` — *"is GLOBAL — `shadowKeyTableRef` spans local ∪ imported ∪ prelude"*: this is the
  rationale for the reader `c` is moving; it is `c`'s to update, but check it landed.
- `15305` — *"The separate `implExistsForHead perRun.value.shadowKeyTableRef.value` reads in
  inferShadowApp …"*: names the two readers `c` removes. Same — verify, don't assume.
- `20950` — *"exactly as PR1 copies `universeKeyBucketsRef` into `shadowKeyTableRef`"*: this
  is inside a comment about a **sibling** accumulator pair (`methodIfaceParams` /
  `registeredIfaces`) and uses the deleted copy as its ANALOGY. The analogy dies with the
  code. Rewrite the clause; do not delete the paragraph, which is about #1092.
- `26359` — `appendUniverseAccums`' header: *"(see their declarations near
  `shadowKeyTableRef`)"*. A dangling locator once the field is gone.
- `28244` — *"the persistent universe accumulators (`universeIfaceMethodsRef` /
  `universeKeyBucketsRef` / …)"*: an enumeration that must lose one member.

---

## 5. The `nearest miss:`, pre-answered

**Stated miss: "a fourth reader introduced between design and implementation."** Because a
writer is live in this tree, this is not paranoia. Run these **immediately before deleting**,
and diff against the baseline in this packet rather than re-deriving:

```sh
cd <trunk>

# (1) the gating check. Expected AT THE PIN: exactly 2 lines, 11548 and 11835.
#     Expected AFTER c: ZERO lines. A THIRD line is the nearest miss -- STOP.
grep -n 'perRun\.value\.shadowKeyTableRef' compiler/types/typecheck.mdk \
  | grep -v ':[[:space:]]*--'

# (2) the full code set for both refs. Expected AT THE PIN: exactly 9 lines --
#     6177 6299 7020 7116 11548 11835 20903 20904 26376.
#     Expected AFTER c: 7 (the two reads gone). Anything else is new.
grep -n 'universeKeyBucketsRef\|shadowKeyTableRef' compiler/types/typecheck.mdk \
  | grep -v ':[[:space:]]*--'

# (3) tree-wide, outside typecheck.mdk. Expected: prose only --
#     compiler/types/registry.mdk:682, compiler/DIAGNOSTIC-CODES-DESIGN.md:189,
#     compiler/TYPECHECK-TARGET-ARCHITECTURE.md:1819, docs/spec/SHADOW-SEMANTICS.md
#     (x4), .claude/** . ZERO .mdk code lines.
git grep -n 'universeKeyBucketsRef\|shadowKeyTableRef' -- '*.mdk' \
  | grep -v '^compiler/types/typecheck.mdk' | grep -v ':[[:space:]]*--'

# (4) the ratchet's two sides agree at 23 BEFORE, 22 AFTER (see 2a for both commands).

# (5) implExistsForHead must keep exactly ONE caller (15352, threaded). Expected
#     AFTER c+d: one call site, plus the def and the Go helper.
grep -n 'implExistsForHead' compiler/types/typecheck.mdk | grep -v ':[[:space:]]*--'
```

**A `grep -v ':[[:space:]]*--'` filter is load-bearing on every one of these** — comment hits
have produced false alarms twice this run, and the two refs have 14 prose mentions to 9 code
lines in `typecheck.mdk` alone. (The filter catches only *whole-line* comments; there are no
trailing-comment hits for either name except the field-type note at `6177`, which you are
deleting anyway.)

---

## 6. Do NOT re-derive — settled, and cheap to get wrong

- **The declaration-index defect is fixed by DELETION, not repair.** Do not repair
  `bucketKeyEntriesFrom`'s numbering, do not add a reverse, do not thread an index base.
- **`ieByHead` is origin-blind.** Not this bite's problem. Do not re-key anything.
- **Making the two arms file under the same keys is a MEASURED regression** — 32 false
  rejects on `medaka check stdlib/core.mdk`. Do not "unify" the Flat and Module arms.
- **`keyForSite*` / `KeyBuckets` retire LATER, not here** (AM-1, `DECISIONS.md:236-237`;
  `.claude/STAGE-B-SPRINT.md:20`). The sprint doc's §1 wording that B-2.1 retires them "by
  DELETION" was **amended**; the budget is the two refs.
- **`PerRun`'s field decl at `7020` carries NO trailing comment**, and `PerRun`'s header is
  the **safe one-line** `data PerRun = PerRun {` form — verify with
  `grep -n '^data PerRun =$' -A1 compiler/types/typecheck.mdk` (no hit = safe). So `fmt
  --write` will not cascade this record's ~60 trailing comments (#829, REOPENED). Deleting
  a comment-free field is the measured-safe operation on either header shape. **Still diff
  the record by eye after `fmt --write`** — `fmt --check` reports #829's damage as already
  formatted.
- **This diff moves goldens.** `compiler/types/typecheck.mdk` is in the snapshot corpus and
  in the selfproc **LEG A** corpus (`test/selfproc_goldens/legA/types.typecheck.golden`) —
  the latter reds only in CI's `backend` shard. Deleting six bindings' worth of lines moves
  both. LEG A must be **subtractive-only** here (bindings leave; no *surviving* binding's
  inferred type may change — if one did, the deletion changed types). Re-cut, never
  hand-merge (three agents blended that exact file in one session).
