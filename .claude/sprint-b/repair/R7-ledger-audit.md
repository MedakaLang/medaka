# R7 — audit of the orchestrator's own prose

**Scope:** `.claude/sprint-b/DECISIONS.md` · `.claude/sprint-b/DEBT.md` · `.claude/HANDOFF.md` ·
the 31 commit messages over `2b9dc798..61c4eebd`. **Pin `61c4eebd`.** Read-only; no build, no gate,
no `./medaka` was run. Every finding below ships the command that produced it.

⚠️ **Read this file the way it asks you to read the ledgers: the derivations are the content.**
Where I could not derive a number I say so rather than repeating it.

---

## S1 — the certification's load-bearing line has no derivation, and the row it supersedes records it as OWED

**`HANDOFF.md:92`** (the "Certified on the final binary at `7e3fe771`" table):

> | **Fixpoint** | **C3a YES · C3b YES** at `7e3fe771`, run *after* the golden re-cut — closing the
> gap that a re-cut could otherwise enshrine a stale binary's output. |

**`DEBT.md:2618-2620`** — EX-3's own row, the only ledger row covering that commit — says the
opposite:

> * **I did NOT rebuild the compiler, and did not re-run the fixpoint or the seed check.** …
>   ⚠️ **OWED if `EX-4` wants it airtight:** `sh test/selfcompile_fixpoint.sh` after this commit.

And **EX-4 produced no DEBT row at all**:

```sh
grep -n '^### ' /var/tmp/r7_DEBT.md | tail -1
#  2458:### `EX-3` — Phase 2′ (sprint exit) — THE ONE GOLDEN RE-CUT …      ← the file ends here
git show --stat --name-only 89a9536b | tail -1
#  .claude/HANDOFF.md                                                     ← EX-4's only artifact
```

So the entire certification that **removed the UNSAFE marking** lives in one commit message and one
HANDOFF table, both written by the orchestrator, neither reviewed, and its single most consequential
line is the one EX-3 explicitly booked as unpaid. Contrast EX-2's identical claim, which ships a
derivation (`DEBT.md:2272`): *"exit 0, `C3a YES` / `C3b YES`, 38 s (`scratchpad/fixpoint-pre.log`)"*
— no such artefact, timing, or exit code accompanies the `7e3fe771` claim.

**Second defect in the same line: it does not say WHICH C3a.** `DEBT.md:2286-2301` spends a page
establishing that there are two, that `selfcompile_fixpoint.sh`'s C3a is a one-crank convergence
test **a lagging seed passes by design**, and that conflating them is what makes *"the fixpoint is
green, so the seed is current"* a false inference. HANDOFF carries the conclusion and drops the
distinction — the same shape as the four-times-repeated "CI ran the fixpoint and it passed", which
was true only of C3b.

**Remedy:** re-run `sh test/selfcompile_fixpoint.sh` on a binary built at the pin, record exit
code + both verdict lines + the script name, and write an `EX-4` row. Until then the branch's only
in-band codegen signal is unrecorded at the certified commit.

---

## S2 — `HANDOFF.md`'s expected-red row for `diff_compiler_core_ir*` cites a field that does not exist

**`HANDOFF.md:258`:**

> The frozen-admissibility carrier is a **5th positional `CProgram` field**, and `CProgram` is
> rendered by `core_ir_sexp` … so the carrier alone moves these goldens **before any semantic
> change**.

```sh
git show 61c4eebd:compiler/ir/core_ir.mdk | grep -n 'CProgram'
#  241:public export data CProgram =
#  242:  | CProgram (List CBind) (List (String, Int)) (List (String, String)) (List CImplEntry)
git show 2b9dc798:compiler/ir/core_ir.mdk | grep -n 'CProgram'   # byte-identical — FOUR fields
```

**Four fields at base, four at the pin.** The carrier was *ruled* in Phase 0 (`DECISIONS.md`
RUN-B-013) and never implemented — Phase 4 was never started, as HANDOFF itself says at `:81`. And
EX-3 measured the family **green**: `DEBT.md:2588` — *"`core_ir_*` (7 gates): all GREEN."*

This is the identical shape to the `diff_compiler_llvm_typed_ir` wrong prediction that the
orchestrator **did** retract one row above (`:257`), left live here. Its cost is already documented
for the retracted twin: *"the wrong prediction primed an implementer to expect a large IR move that
does not exist."* A cold reader hitting a genuine `core_ir` red will now dismiss it as by-design.

*(The `diff_compiler_core_ir_modules.sh` row at `:259` is vacuous for the same reason — it is
scoped to B-2.4, in Phase 5, never started. Less harmful: it prescribes running two gates, which is
never wrong.)*

---

## S2 — the topmost Stage B section of `HANDOFF.md` is two commits stale, and it is the first screen a cold reader sees

`HANDOFF.md:5-36` is the `B-2.1-g` update (`26423f93`). The three Stage B sections below it are
**newer** — AD-1 (`:40`, `5ef29a60`), EX-4's certification (`:76`, `89a9536b`) — so the file's
newest-at-top convention is inverted exactly here, and the stalest section is first. Four concrete
ways it misleads:

1. **`:30`** *"The branch still owes the fixpoint, the seed question, and the goldens"* — all three
   discharged by EX-2 (`6ec0111a`) and EX-3 (`7e3fe771`).
2. **`:26`** *"`B-2.1-d` retires them in one sweep"* — future tense; EX-1 already did it at
   `ee49f7ec` (13 signatures deleted, 0 added — verified below).
3. **`:24-26`** *"**thirteen** now-dead bindings are retained with per-site
   `lint-disable-next-line rule-dead-code`"* — they are not:
   ```sh
   git grep -c 'rule-dead-code' 26423f93 -- compiler/types/typecheck.mdk   # 19
   git grep -c 'rule-dead-code' 61c4eebd -- compiler/types/typecheck.mdk   #  3
   ```
4. **Five dead symbols in one sentence.** `headCollides`, `countHead`, `bucketOfHead`,
   `shadowKeyTableRef`, `universeKeyBucketsRef` — cited in the present tense, **zero definitions at
   the pin** (only historical comments, correctly marked *"both deleted by ARCH B-2.1-d"*):
   ```sh
   git show 61c4eebd:compiler/types/typecheck.mdk > /var/tmp/r7_tc_pin.mdk
   for s in headCollides countHead bucketOfHead shadowKeyTableRef universeKeyBucketsRef; do
     printf '%s def=%s\n' "$s" "$(grep -cE "^$s( |:)" /var/tmp/r7_tc_pin.mdk)"; done
   # every one: def=0
   ```

**Remedy:** move this section below the EX-4 certification, or strike it and keep only its two
still-live sentences (the `T-ROUTE-WORD-AMBIGUOUS`/#1578 correction, and the wasm-evidence warning).
⚠️ **Keep `:31`'s "this bite CHANGES EMITTED IR" — I first listed it here as a fifth stale claim,
contradicted by EX-3's green IR gates, and that was my error. See the next finding.**

---

## S1/S2 — "the IR did not move" is a green golden gate over a corpus that by construction excludes the changed class

`DEBT.md`'s `EX-3` item 4 concludes from `llvm_typed_ir` **54/54** and `llvm_modules` **56/56**
byte-identical that the sprint does not change emitted IR, and on that basis declares the run's own
expected-red entry **WRONG**. It also checks the green is not vacuous — but that check
(`N==0` is a hard failure) proves only that **54 goldens were compared**, not that the corpus
**covers the changed class**.

It does not. The drained programs (#1564/#1599/#1072 and `SA-4c`) were **rejected at `check` on
base** — a program that never emits produces no `.ll.golden`, so it cannot be in that corpus, and an
unmoved corpus is fully compatible with the `--keep-ir` readings in `B-2.1-b2`'s and `g`'s own rows
showing a **different call site** (`@mdk_impl_Tag__Wrap_a___tagOf` arity-2 → the arity-1 specific
impl). Both of those rows say verbatim **"THIS BITE CHANGES EMITTED IR"**. EX-3 does not reconcile
that claim; it overrules it with a gate that could not have seen it.

```sh
git ls-tree -r --name-only 61c4eebd -- test | grep -c 'll.golden$'                      # 54
git ls-tree -r --name-only 61c4eebd -- test/llvm_fixtures_typed | grep -c '\.mdk$'      # 54
# and no bite's diff adds a fixture to test/llvm_fixtures*:
git show --numstat 1e7cbbbb | grep llvm_fixtures || echo '(none)'
```

**This matters twice over.** First, it is the strongest "conclusion reaching past its evidence" in
the corpus, and it *reverses* a correct prediction rather than merely overstating a result. Second,
**I repeated the error while auditing it** — I read the green IR gates as refuting HANDOFF `:31`.
They do not. This is the `byte-identical bar on unread code is vacuous` shape, and it caught two of
us in the same file.

**Remedy for the repair round:** either add a fixture to `test/llvm_fixtures_typed/` that *does*
emit and *does* exercise the changed selection (the `SA-4c` control order builds — that leg is the
natural donor), or restate item 4 as *"no golden in the emitting corpus moved"* and leave the
expected-red prediction standing as unrefuted.

---

## S2 — `HANDOFF.md` names a permanently-red gate leg that does not exist and has been green since before the sprint opened

Stated **twice**, in present tense, at `:271-273` (Stage B known-red) and `:299-301` (Stage A
resolved):

> ⚠️ **One pre-existing red is NOT ours**: `check_cli_modules`' `1112-A34/later-invisible` leg,
> which fails by **ACCEPTING** … Inherited from before Stage B. / … **and is NOT resolved** … Do
> not attribute it to this work.

```sh
git show 61c4eebd:test/diff_compiler_check_cli_modules.sh | grep -n "printf '.*1112-A34/later"
#  1800: ok   1112-A34/later-visible (A-3.6: candidacy is graph-global, the ordinal no longer decides)
#  1813: ok   1112-A34/later-visible-run (5, and BOTH import orders agree)
git show 2b9dc798:test/diff_compiler_check_cli_modules.sh | grep -n "printf '.*1112-A34/later"
#  identical — already `later-visible` and green at the sprint's BASE
```

The gate's own header says so (`:1720`): *"`later-invisible` is now `later-visible`: both arms
accept, both run `5`."* The leg name `later-invisible` survives **only** in that historical comment.

Provenance — it was true when written and was copied forward without re-derivation:

```sh
git log -S'later-invisible' --oneline -- .claude/HANDOFF.md
#  398a3a2e sprint-b: open the Stage B run …          ← re-asserted at Stage B open, already false
#  51bd7fa3 test(dict-semantics): …                   ← where it was true
```

It is also flatly contradicted by EX-4's own `check_cli_modules` → **86 ok, 0 failing** at `:87` of
the same file. **This is the worst kind of stale warning:** it pre-authorises a cold reader to
ignore a future red in a named leg of the gate that is this sprint's primary behavioural oracle.

---

## S2 — a scope-**addition** ruling rests on a citation attributed to the wrong file (and to a spec rather than an arch doc)

`DECISIONS.md` RUN-B-011 rules `B-2.4-k` **ACCEPTED IN** on the authority of
`docs/spec/DICT-SEMANTICS.md` §9.9 `:2011-2012`, quoted as *"Revert; **that is B-2's**."*

```sh
git grep -n "that is B-2" 61c4eebd -- docs/spec/DICT-SEMANTICS.md compiler/TYPECHECK-TARGET-ARCHITECTURE.md
#  61c4eebd:compiler/TYPECHECK-TARGET-ARCHITECTURE.md:2012:  Revert; that is B-2's.
```

**Right line numbers, wrong file** — and the string is absent from `DICT-SEMANTICS.md` at the
introducing commit, at base, and at the pin. The distinction is load-bearing: a **spec** is
normative, an **architecture doc** is not, and this citation is the sole authority for widening the
sprint's scope. `TYPECHECK-ARCH-BUG-FIT.md`/`TYPECHECK-TARGET-ARCHITECTURE.md` are precisely the
"arc LEDGER is ungated prose" family.

---

## S2 — ~20 dangling `scratchpad/` citations, not one; and three of them were the sole carrier of work the ledger calls "the deliverable"

`61c4eebd`'s message names exactly one (`scratchpad/ex2-gzprobe.sh`) and says *"the dangling path
should be corrected by whoever next edits that row."* The real set:

```sh
grep -ohE '`?scratchpad/[A-Za-z0-9_./-]+' /var/tmp/r7_DEBT.md /var/tmp/r7_DECISIONS.md \
  /var/tmp/r7_HANDOFF.md | tr -d '`' | sort -u | wc -l     # 20
ls /root/medaka/.claude/worktrees/giggly-tinkering-rainbow/scratchpad
#  No such file or directory                                ← the directory is gone from disk
```

Plus **~18 bare script names** cited without a directory (`corpus.sh`, `mf.sh`, `resign.sh`,
`exhaustive.sh`, `attrib.sh`, `percommit.sh`, `srcmoved.sh`, `names.sh`, `sections.sh`,
`perdecl.sh`, `perdecl_mark.sh`, `p1564.sh`, `p1599.sh`, `probe4.sh`, `final.sh`, `c-probe.sh`,
`c-ir-probe.sh`, `c-build-probe.sh`) — EX-3's entire **`Reproduction:`** bullet (`DEBT.md:2643-2648`)
is eight of these, none of which exist.

🚨 **Three are not merely dangling citations — they are lost artefacts.**
`scratchpad/B-2.1-b1-2leg-AS-BRIEFED.patch`, `scratchpad/B-2.1-b1-3leg-EXPERIMENT.patch`, and
`scratchpad/c-REFUSED.patch`. `DEBT.md:585-588` says of the first two: *"Nothing landed … it is
**not shippable as briefed** and is parked as two patches in the scratchpad … **What follows is the
measurement, because the measurement is the deliverable.**"* and `:597` *"**On disk now: nothing.**"*
The patches were the only carrier of two refused bites' code, and they are gone. Only EX-2's 15
files were preserved (`/var/tmp/ex2-probes-kept`, tmpfs-adjacent and not durable either).

`make docs-links` cannot see any of this — `scratchpad/` is not in its pattern, which is why the
gate stayed green.

---

## S2 — `DEBT`'s `agent-doc-symbols` inference proves a narrower property than the sentence claims

`DEBT.md:2632`:

> `make agent-doc-symbols` (**0 dead across 1047 symbol claims** — so EX-1's 13 deletions left **no
> dangling backticked symbol in any agent-facing doc**)

```sh
git show 61c4eebd:Makefile | sed -n '147,157p'
#  … checks every backticked, symbol-shaped token in AGENTS.md, .claude/skills/*/SKILL.md,
#    .claude/workstreams/*.md, .claude/ORCHESTRATING.md (BROAD tier) and docs/spec/*.md (SCOPED) …
```

The corpus **excludes `.claude/HANDOFF.md`, `.claude/sprint-b/*.md`, and `compiler/*.md`**. The
finding three sections above is the direct counterexample: five EX-1-deleted symbols are cited live
in HANDOFF while the gate reads 0 dead. The property actually proved is *"no dangling symbol in the
gated corpus"* — and **the entire ledger corpus audited here is outside it**, which is why this
review exists.

---

## S2 — two `DECISIONS.md` citations do not resolve at any commit (delegated audit, spot-verified by me)

1. **RUN-B-009** claims P0-B's `expandSupersTable` premise was *"verified verbatim"* at
   `typecheck.mdk:9037-9042`. The quoted string *"APPENDS, per entry, one extra slot"* is at
   `:9023` at the introducing commit (`7e74149e`) and at `:9362` at the pin:
   ```sh
   git show 61c4eebd:compiler/types/typecheck.mdk | grep -n 'APPENDS'
   #  4364: … 9362:-- funConstraintsRef/funConstraintIfacesRef; this pass APPENDS, per entry, one extra
   ```
   The cited range holds a signature and a four-line body — no prose. **RUN-B-007 AMENDMENT 5 cites
   the same passage correctly at `:9027-9030`** — two entries, one passage, two ranges, one wrong.
   This is the third instance of the class the ledger flags about itself twice (`ast.mdk:706-712`,
   `core_ir_eval.mdk:598`) and the only one still uncorrected.
2. **RUN-B-013** prints a fenced *command + output* block —
   `grep -rn 'cevalModules\|cevalProgram' compiler/ --include=*.mdk` → 4 hits — that does not
   reproduce: the same grep returns **13** `.mdk` hits (also `eval.mdk`, `resolve.mdk`,
   `core_ir_lower.mdk`, two entry mains). All extras are comments, so the **conclusion stands**, but
   the block is the derivation the untyped-eval carve-out assent is said to rest on, and as printed
   it is filtered without saying so.

Lesser, verified: RUN-B-022 places both router populations *"in `checkModuleFullImpl`'s tail
(`:28677`/`:28682`)"* — at base `:28675` is `let schemes = checkModuleFullImpl mid …`, i.e. its
**caller**; RUN-B-008 swaps `argReqRoute`/`selectReqImpl` against `:19311`/`:19380`.

---

## S3 — a count the entry declaring counts unreliable did not derive

`DECISIONS.md:1875-1877` (RUN-B-028, headed *"Nothing measured"*):

> **P0-B's "7 `RKey` hits, 5 construct" does not reproduce — 8 and 6, at BASE too.** ⚠️ **That is
> the FOURTH count corrected this run** … Counts in this arc should be treated as unreliable by
> default.

No command ships with the correction. **Three independent attempts produced three answers** — the
delegated auditor got 7/7, my own crude pattern got 10:

```sh
git show 2b9dc798:compiler/types/typecheck.mdk | grep -nE '^\s+.*RKey [a-z]' | grep -v ':--' | wc -l   # 10
```

I am **not** claiming 8 is wrong — I am claiming the number has no derivation and is not
reproducible from the entry, which is exactly what the entry's own next sentence forbids. **Write
the command, not the value.**

---

## S3 — two off-by-one counts in EX-2's drift argument (the argument survives; the numbers are wrong)

`DEBT.md:2311-2313` — checked at EX-2's own commit, not the pin:

```sh
git diff --shortstat 0917e97f 6ec0111a -- compiler stdlib runtime
#  110 files changed, 48715 insertions(+), 7337 deletions(-)     ← ledger says "109 files"
git rev-list --count 0917e97f..6ec0111a
#  1342                                                          ← ledger says "1341 commits back"
```

Insertions/deletions are exact. The conclusion (the drift is overwhelmingly pre-sprint) is
unaffected.

---

## S3 — three more `DEBT.md` items (delegated audit, each re-verified by me)

1. **`B-2.1-g` states a wrong derived count in the sentence that says "derive, never count."** The
   row claims *"one … disable predates this bite (`wReset`), so `grep -c` answers **14**, not 13."*
   ```sh
   git grep -c 'lint-disable-next-line rule-dead-code' 26423f93 -- compiler/types/typecheck.mdk
   #  15
   ```
   **15.** The 13 new + `wReset` are right; the stated `grep -c` value is not — because the row's own
   recorded derive-command is itself written into the source (`:19431`) and matches its own pattern.
   A derivation that counts itself.
2. **`B-2.1-g`'s *"Outside this file the only mention is a comment in
   `compiler/types/registry.mdk:682`"* is incomplete**, and that sentence is what concludes
   *"`d`'s precondition is met."*
   ```sh
   git grep -n -e shadowKeyTableRef -e universeKeyBucketsRef 26423f93 -- compiler stdlib \
     | grep -v types/typecheck.mdk
   #  compiler/DIAGNOSTIC-CODES-DESIGN.md:189        ← backticked symbol claim
   #  compiler/TYPECHECK-TARGET-ARCHITECTURE.md:1819 ← backticked symbol claim
   #  compiler/types/registry.mdk:682
   ```
   Three sites, not one, and two are symbol *claims* rather than prose — `EX-1` had to edit both
   (`2/2` and `1/1` in `git show --numstat ee49f7ec`). Note these are `compiler/*.md`, which
   `agent-doc-symbols` does not scan (#1192) — the same blind spot as the finding two sections up.
3. **`B-2.1-a3`'s site line numbers are systematically 2–25 lines early** (pre-`fmt` numbering):
   `:4304 ieInsertRow` → actual `4307`; `:4360-4361 ieFileRowByHead` → `4364`; `:4363-4375
   ieHeadRows` → `4378`; `:4306-4358 ieFileRow` → `4331`. Nothing dangles — each lands in a
   neighbour's comment block — but the contract's `sites:` field is meant to be jumpable.
   *(Also: `B-2.1-a1`'s `sites:` omits `AGENTS.md 13/5`, which `git show --numstat 523f960e` shows
   its commit touched — described only in the commit message.)*

---

## S3 — smaller items

* **`HANDOFF.md:44`** sends the reader to `/var/tmp/ad1p/` for the unfiled S0 repro, flagged
  *"`/tmp`-family, **not durable** — re-create from below"* — while **durable copies were committed**
  at `.claude/sprint-b/next/dedup.mdk` and `control_twoheads.mdk` (`5ef29a60`), and I diffed them
  against the inline listing: they match. Point at the repo copies.
* **`HANDOFF.md:94`** *"wasm clean on **all four** gates"* names a count, not a set — the rule the
  same file teaches at `:192` (*"Check drained NAMES, never the count"*).
  `git ls-tree -r --name-only 61c4eebd -- test/wasm | grep -E 'diff_.*\.sh$'` returns **six**;
  EX-3's row says the sqlite and playground gates were **not** run, so four is derivable but
  unnamed. Name them.
* **`ee49f7ec`'s commit message** cites `implExistsForHedGo` — dead symbol; the real one is
  `implExistsForHeadGo` (`git grep -c implExistsForHeadGo 2b9dc798 -- compiler` → 10 hits at base).
  Confined to the commit message; absent from the ledgers.
* **`DECISIONS.md:1018`** lists B-3 bites *"`a`, `b`, `c`, `e` (`d` **declined**)"* and then
  *"all **five** site-verified"* — four are listed. Reads as an inflated verification claim even if
  the intent was a..e.
* **`DECISIONS.md:990`**'s header *"`diff_flat_vs_onemodule.sh` **does not exist**"* is now
  historically true but reads as live; it was **discharged** — the successor
  `test/diff_compiler_flat_vs_onemodule.sh` exists, `typecheck.mdk:14436-14440` was repointed, and
  `test/DOC-LINK-EXCEPTIONS.txt:174` records the whole disposition correctly. Nothing to fix in the
  tree; add a one-line "DISCHARGED" marker to the entry.

---

## Retracted

**Two.** The first is above, in place: I listed HANDOFF `:31`'s *"this bite CHANGES EMITTED IR"* as
a stale claim refuted by EX-3's green IR gates. **It is not refuted** — the golden corpus excludes
the changed class by construction, and I made the same over-read I was auditing EX-3 for. The
finding now runs the other way.

**The second I withdraw outright.** I flagged that HANDOFF reports **`check_cli_modules` → 86 ok, 0
failing** for both `f` (`:164`) and `g` (`:14`, `:87`) while the two `SA-4c` legs were re-cut
between them from asserting **rejection** to asserting **acceptance** —

```sh
git diff 086aeb35 26423f93 -- test/diff_compiler_check_cli_modules.sh | grep -E '^[+-].*SA-4'
#  - ok SA-4/overlap-still-rejects (build refuses, no binary; …)
#  + ok SA-4c/overlap-DRAINED-both-orders (build 0 both orders; binary prints wrap-int-specific)
```

— i.e. the same headline number for opposite oracles, the exact trap `:192` teaches. **It is
disclosed**, at `HANDOFF.md:15-17`, which states both legs were deliberately re-cut and why.
Withdrawn.

---

## Verified correct — so the base rate is not zero

Stated because a review that only lists defects gives a false picture of the corpus, and because
several of these are unusually good citations:

* **`registerMember` `:24268-24276`** and **`keptConstraintArgs` `:24278-24280`** — exact at the
  introducing commit `6dd3a975`, to the line.
* **D8 `routeUndeterminedTop:19288`** and **D9 `resolveRecMono:19538`** — exact at `4b0f5b68`,
  including the characterisation *"decides by dedup'd impl COUNT, and reads `prog`, not `IE`"*.
* **`snapshot.mdk:568` / `:605`** — exact at both `85bbbb7e` and the pin (`cprogramToSexp`,
  `lowerProgramEmit`).
* **`.github/workflows/ci.yml:1282-1316`** — exact, including *"C3b errors, C3a warns"* verbatim.
* **The three gzip seed-fixture citations** (`inflate_oracle.sh:357-361`, `deflate_oracle.sh:228-233`,
  `wasm/diff_gzip.sh:238`) — all exact.
* **`.claude/STAGE-B-SPRINT.md` §1 / §5 / §8** — all exist; §8's exit criterion quoted verbatim.
* **EX-1's headline** — *"13 signatures removed, ZERO added, ZERO re-signed"*:
  ```sh
  git show ee49f7ec -- compiler/types/typecheck.mdk | grep -cE '^-[a-zA-Z_][a-zA-Z0-9_]* :'   # 13
  git show ee49f7ec -- compiler/types/typecheck.mdk | grep -cE '^\+[a-zA-Z_][a-zA-Z0-9_]* :'  #  0
  ```
  And **all 8 knowledge-block relocation TARGETS resolve as live definitions at the pin**
  (`headTabIs`, `ieCountHeadByIface`, `mergeByDeclIdx`, `headBucketKey`, `pickMostSpecificEntry`,
  `keyForSite`, `checkBodyImpl`, `appendUniverseAccums`) — the knowledge landed where claimed.
* **EX-2's measured numbers** — seed gz `1359573 → 1679648` (matches `git diff --stat`),
  `+1296/−523` in `typecheck.mdk`, `core_ir_lower` 9/3, `registry` 5/2, and
  `git diff --name-only 2b9dc798..HEAD -- compiler/backend` **empty**: all exact.
* **`must_fail` arithmetic** — 99 = 98+1 at base, **100** = 97+3 at the pin
  (`git ls-tree -d --name-only 61c4eebd:test/must_fail_fixtures | wc -l`). Because the count and the
  three names together cover the universe, *"Nothing silently drained"* is genuinely supported.
* **`selfproc` 16** = 13 `legA` goldens + 3 probes (`lex_probe`, `parse_probe`, `tc_probe`) — exact.
* **`llvm_typed_ir` 54/54** — 54 `.ll.golden` files and 54 `.mdk` fixtures in
  `test/llvm_fixtures_typed`. Exact.
* **31 commit messages** over the range; **31** `## RUN-B-*` entries in `DECISIONS.md`. Both match
  the orchestrator's stated "~30".
* **"The revert set is exactly TWO commits"** — `95359281` and `3ba7817b` are ledger-only, verified.
  ⚠️ But see the note below.
* The delegated DECISIONS auditor checked **all 33 `<file>.mdk:N` citations** and **all 283 unique
  backticked identifiers** against full identifier dumps at both `2b9dc798` and `61c4eebd`:
  **zero dead symbols in `DECISIONS.md`.** ~95 further citations verified correct.
* The delegated DEBT auditor checked **all ~60 repo-relative paths** (**all present** at the pin —
  no dangling path beyond the known `scratchpad/*`, and the rows' *negative* claims, e.g. that
  `test/must_fail_fixtures/1075-*` does not exist, are also correct), **all 431 backticked
  identifiers** (392 resolve; all 39 non-resolvers are explicitly labelled reverted/removed in the
  prose — **no dead symbol in `DEBT.md`**), and **re-derived 21 numbers of which 20 are exact**:
  every `git diff --numstat`, every signature delta (EX-1 `13−/0+`, `g` `+2/1 re-sign`, `b2`
  `+14/−6/2 re-sign`, `f` `+6/0/0`), `legA` 1770→1790, the flat gate 9→13 rows, 100 must-fail
  fixtures with all 10 cited names present, `engine_divergence.txt` 44, `bodyImplEnvRef` 6 hits/4
  code sites, and the seven `shadowKeyTableRef`/`universeKeyBucketsRef` lines at the exact numbers
  EX-1 lists. **`DEBT.md` is the strongest of the three files.**

---

## Two constructive notes for the repair round

**1. `HANDOFF.md:135-155` ("📋 IF YOU ARE PICKING THIS UP COLD, START HERE") is stale in a way that
matters, and it is the file's designated entry point.** It presents the exit/revert choice as
conditional on `g`'s verdict, which is settled 60 lines above. Worse, its identity check is now
false: it says *"The revert set is exactly TWO commits"* and gives
`git diff --stat 85ceec1f -- compiler/` → empty as the check — but **two later commits also touched
`compiler/types/typecheck.mdk`**:

```sh
git show --stat --name-only 26423f93 | tail -2   # compiler/types/typecheck.mdk  (B-2.1-g)
git show --stat --name-only ee49f7ec | tail -3   # compiler/types/typecheck.mdk  (EX-1)
```

A cold reader following `QUEUED-h-revert.md` reverts two commits, gets a non-empty identity check,
and is told nothing about why. **Retitle this section as historical, or delete the revert row.**

**2. Two of the repair round's inherited items are the same code, and saying so saves a round.**
HANDOFF presents the unfiled S0 (`:40-73`, same-tycon-head ambiguity silently resolved) and the
Phase 3′ blocker (`:113-117`, D8/D9 stamp with no selector) as separate items. They meet at one
site. Derived statically at the pin, no build:

```sh
sed -n '19858,19860p' /var/tmp/r7_tc_pin.mdk
#  implExistsForHeadGo …  →  implHeadTagsForIface prog iface = dedup (flatMap (implHeadTagForIface iface) prog)
```

`implHeadTagForIface` projects an impl head through `headTyconNameTy` to a **bare tag string**, so
`impl Mk (T Int)` and `impl Mk (T Bool)` both yield `"T"`; `dedup` collapses them to `["T"]`; the
`[tag] =>` arm of `routeUndeterminedTop` fires and its `_ => reportAmbiguousImpl iface` arm is
**unreachable by construction**. That is AD-1's finding and D8's "no selector ran" bullet, one
mechanism. The repair round should file it as one issue and rule it once.

⚠️ Per HANDOFF's own caution, this does **not** establish it is #1180 — #1180 is OPEN, S0,
`verified`, and pinned at `test/must_fail_fixtures/1180-undetermined-top-headless-impl-commits/`,
but *"a 'same class' claim needs the same proof as a filing"* and I did not run one.

---

## What I did not check

* Any claim requiring a run: `86 ok / 0 failing`, `97 REPRO / 3 DRAINED`, `201/201 snapshots`,
  `583 fixtures`, `perf_scaling 20 ok`, `wasm clean`. I verified their **arithmetic and corpus
  sizes** where those are static (above); I did not verify the runs.
* `DECISIONS.md`'s bare `` `:NNNN` `` citations: ~45 of 109 sampled, weighted to decision-bearing
  entries. `DEBT.md`'s `file:LINE` citations: ~24 of 35 sampled, all resolving. The unsampled
  remainder is the largest gap in this audit.
* `HANDOFF.md` below `:344` — inherited pre-Stage-B content, out of scope. Noted in passing:
  `diff_compiler_eval_dict.sh` (`:1618`, `:2456`) and `byteparser/lib/bytebuilder.mdk` (`:1700`) do
  not resolve at the pin (`test/diff_compiler_eval_dict_batch.sh` and `stdlib/bytebuilder.mdk` do).
  Pre-existing, not this run's.
