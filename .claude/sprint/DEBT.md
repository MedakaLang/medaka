# Stage A sprint — DEBT ledger

**Append-only, one row per landed bite.** Written by the sub-orchestrator when it commits a
bite; the implementer supplies the row's content with its edit.

> ⚠️ **This ledger is the deliverable that makes the testing round possible.** The diff alone
> is not. An agent that skips a row has not saved time — it has converted a deferred check into
> a check nobody will ever know to make.

**`could move:` may not be left blank.** "Nothing, and here is why" is a valid entry; silence is
not. The testing round works this column first, because the gate suite is structurally blind to
this run's characteristic failure — a silently widened acceptance. Value goldens cannot see a
diagnostic-only change, and absence probes cannot see an undercount.

Row format (§4):

```
### <bite id> — <unit> — <one-line description>
sites:      <the files:lines actually touched>
transform:  <what was applied>
could move: <what acceptance behavior could plausibly have changed, incl. "nothing — pure rename">
unchecked:  <what I did not verify, and why>
```

---

<!-- rows appended below, in landing order -->

### P0A-D1 — ledger-repair — retire the stale `loadDataUniverse`/`storeDataUniverse` table counts
sites:      `compiler/types/typecheck.mdk` — the `#1557 A-3.5c` CE-reader-flip block (the "WAS:"
            paragraph, was `:1818`) and the `universeIfaceParamKinds` COORDINATION block (was
            `:4277-4278`). **Anchor on the strings, not the lines** — both shifted when D2 landed
            above them.
transform:  Replaced two counts that read as live ("one of the **five** tables … marshalled in
            lockstep"; "now marshal **THREE** tables (recordByName, fieldOwners, dataParamKinds)")
            with the derive-instruction the neighbouring `loadDataUniverse` header already uses.
            "five" is kept but explicitly re-framed as history-at-the-time.
            DERIVED current truth, read from the bodies: `loadDataUniverse` marshals ONE cross-run
            cell (`universeRecordByName`) + ONE stage-K projection (`aliasTableRef`);
            `storeDataUniverse` is one line.
could move: **Nothing executable — comment text only, entirely inside `--` lines.** No binding,
            signature, arity or expression was touched. Evidence, not assertion: `medaka fmt --write`
            reported `already formatted` (zero reflow, so #829 could not fire), `medaka lint` exit 0,
            `make medaka` green, `make check-self` PASS.
            It DOES move `test/snapshots/compiler/typecheck.md` (compiler source is in the snapshot
            corpus) — expected debt, blessed by nobody per sprint §5. It does NOT move the selfproc
            LEG A golden: no top-level binding changed.
unchecked:  The snapshot gate was not run (§5 defers it and forbids blessing). I repaired the two
            sites P0-A named plus the one RUN-014 named; I did not sweep the tree for a fourth
            marshalling-count claim.

### P0A-D2 — ledger-repair — 🚨 correct the FALSIFIED "global monotonic counter" claim
sites:      `compiler/types/typecheck.mdk` — the `🚨 WHY NOT JUST CALL registerAllData/…` block above
            `data DataTypeDecl` (was `:3249-3260`), and its restatement in the `CE` block (was
            `:4249-4252`). Anchor on `WHY NOT JUST CALL`.
transform:  Deleted the claim that elaboration mints tyvar ids "from a global monotonic counter"
            owned by the per-module walk — and said so explicitly rather than silently, because
            `:4254` routes every future CE/DataEnv implementer to this block as "the full
            derivation", so a silent swap would leave no trace that the recorded reason had ever
            been wrong. Replaced it with two walls: (a) the `perRun` ref WRITES, (b) diagnostics.
            The block's CONCLUSION ("so this index is deliberately SYNTACTIC") is unchanged — only
            its stated reason was wrong.
            **DERIVED first-hand by me on this tree:** `grep -n tyvarCounter compiler/types/typecheck.mdk`
            → `6346:    tyvarCounter : Ref Int,` inside `data PerRun = PerRun {` (`:6345`);
            `6441:  tyvarCounter = Ref 0,` in `freshPerRun`; `resetState` (`:6527-6529`) is
            `let _ = setRef perRun (freshPerRun ())` — a whole fresh `PerRun` per module. `:8447`
            independently says "per-module tyvarCounter reset". **The counter is PER-MODULE.**
            Also DERIVED: `pushTypeErrorOnce` (`:6090`) and `pushTypeErrorOnceAt` (`:6104`) both
            dedupe against `perRun.value.typeErrors.items.value`; `fromAstTypeE` pushes
            `T-ALIAS-ARITY` (`:7532`) and `T-ROW-KIND-MISMATCH` (`:7563`).
            ⚠️ **The diagnostics CONSEQUENCE is RELAYED, and the comment I wrote says so in-line.**
            The four sites and the `Once` scope are DERIVED; the inference (preamble elaboration
            would merge the dedupe scope graph-wide and relocate the push outside a module's harvest
            window ⇒ strictly fewer diagnostics, loud → silent) is P0-A's, not re-derived by running
            anything.
could move: **Nothing executable — comment text only.** Same evidence as D1 (no reflow, lint 0,
            build green, check-self PASS). Moves the snapshot golden only; LEG A untouched.
            ⚠️ **The real risk of this bite is epistemic, not behavioral, and the testing round
            should treat it as such:** it writes a RELAYED claim into the source ledger, where the
            next reader meets it as the block's reason. It is labelled — but a label is precisely
            the thing this repo has repeatedly watched die in a handoff. Verifying the diagnostics
            claim is cheap (four named sites, no build) and is owed before anyone acts on it.
unchecked:  I did not verify the harvest-window half at all — that `checkModulesPreamble` snapshots
            per-module diagnostics downstream of `buildDeclEnvs`. I did not probe whether the dedupe
            merge would change any observable diagnostic on a real program; no fixture was written
            and none is owed by this bite. `:4254`'s forwarding pointer was left in place (it now
            forwards to a corrected block, which is the intent).

### P0A-D3 — ledger-repair — repair the marshalling-cell counts in `TYPECHECK-ARCHITECTURE.md`
sites:      `compiler/TYPECHECK-ARCHITECTURE.md:336` — the "Cross-module universe marshalling" row.
transform:  Replaced `loadDataUniverse` (14 cells) / `storeDataUniverse` (14) / `appendUniverseAccums`
            (11) with a derive-instruction naming the three bodies.
            DERIVED: load = 1 cross-run cell + 1 stage-K projection; store = 1 line;
            `appendUniverseAccums` = **9** `setRef`s
            (`sed -n '/^appendUniverseAccums/,/^$/p' compiler/types/typecheck.mdk | grep -c setRef` → 9).
could move: **Nothing — a Markdown table cell in a doc no build reads.** No symbol was removed from
            the row, so the symbol gate keeps resolving it. VERIFIED rather than assumed:
            `make docs-links` → PASS, `make agent-doc-symbols` → PASS (neither needs the compiler).
unchecked:  I did not audit the rest of that table for sibling stale counts — only the row P0-A
            named. `make docs-index` was not run; the row's `**Status:**` banner is untouched, so
            `docs/README.md` cannot move.

### P0A-D4 — ledger-repair — re-derive the `universe*`/`obUniv*` census in `TYPECHECK-TARGET-ARCHITECTURE.md`
sites:      `compiler/TYPECHECK-TARGET-ARCHITECTURE.md:270-271` — the "(23 as of this writing)"
            parenthetical. ⚠️ **The string is line-WRAPPED** (`(23 as of this` / `writing)`), which
            is why P0-A's suggested grep anchor `23 as of this writing` returns nothing. Anchor on
            `derive the count rather than trust a number here`.
transform:  Replaced `23` with the re-derived **15 `universe*` + 0 `obUniv*`**, kept the sentence's
            own derive-instruction, and named what retired the difference.
            DERIVED with the doc's OWN two commands, run by me:
            `grep -rn '^\s*universe[A-Za-z0-9_]* *:' compiler/ stdlib/ | grep -v '\.md:' | wc -l` → 15
            `grep -rn '^\s*obUniv[A-Za-z0-9_]* *:' compiler/ --include=*.mdk | wc -l` → 0
could move: **Nothing — doc prose.** `make docs-links` and `make agent-doc-symbols` both PASS.
unchecked:  Whether 15 is the architecturally "right" number — I re-derived only what the doc's own
            commands return. No other number in this ~1900-line doc was audited beyond the two rows
            this commit is scoped to (D4 and RUN-015).

### RUN-015 — ledger-repair — the gated doc attributed a `cross_allowed` transition to the wrong unit
sites:      `compiler/TYPECHECK-TARGET-ARCHITECTURE.md:1803` — the A-3.5c row.
transform:  `cross_allowed 28 → 27` → **`27 → 26`**, with the per-commit derivation written into the
            row so the next reader re-checks it instead of trusting it.
            ⚠️ **I did NOT take the briefed value on trust.** Re-derived independently by counting
            the `cross_allowed` allowlist rows in `test/registry_keying_ratchet.sh` at each merge
            commit AND at its first parent (`git show <sha>:test/registry_keying_ratchet.sh`, counting
            lines in that heredoc block that begin with a symbol name; parents confirmed with
            `git log -1 --format=%p`):
              `0240af59` (#1588's first parent) **28** → `257d7e79` (#1588, A-3.2b residual 1) **27**
              `257d7e79` (= #1592's first parent) **27** → `6775679a` (#1592, A-3.5c) **26**
              `1cb5c8e6` (#1592 branch tip) **26** → `dc3e8bd5` (#1590, A-3.2b slices 2+3) **24**
              HEAD `176feb50` **24**, agreeing with the live
              `sh test/registry_keying_ratchet.sh` → `ok: 24 crossRun.value.* write target(s)`.
            **My derivation AGREES with P0-F's (27 → 26). No disagreement to report.** The doc's
            `28 → 27` is the PRIOR unit's transition attributed to this one.
could move: **Nothing — a Markdown table cell.** Both doc gates PASS.
unchecked:  My count is of ALLOWLIST rows, not of `crossRun.value.*` write targets in the source —
            two measurements the ratchet forces into agreement but which I cross-checked only at
            HEAD (24/24); checking them at the historical commits would need a checkout and build
            per commit. I did **not** touch `test/registry_keying_ratchet.sh` — out of scope by
            brief (A-3.6/A-3.7 territory). Its eight recorded defects remain owed.

### RUN-014 — ledger-repair — "three tables on this side" names one call site for two seeds
sites:      `compiler/types/typecheck.mdk` — the STAGE-K bullet of the `🚨 THE CROSS-RUN HALF IS NOW
            ONE CELL` block above `loadDataUniverse` (was `:24874-24878`).
transform:  Re-framed the bullet to say which of the three stage-K seeds happens in
            `loadDataUniverse`'s own body (`aliasTableRef`) and which two happen at a different
            function's call.
            DERIVED: `declEnvSeedDataUniverse` is defined at `:3113` and has exactly ONE call site,
            `:19780` (`let _ = declEnvSeedDataUniverse mid envs`) in `checkBodyImpl`'s Module arm.
            ⚠️ **A first draft of this comment asserted the seed runs BEFORE `loadDataUniverse` in
            that arm; I checked instead of shipping it and it is FALSE** — `loadDataUniverse cur` is
            called at `:19733`, i.e. EARLIER in the same arm. The ordering claim was removed rather
            than corrected, since it is not load-bearing for the fix. Recorded because a plausible
            unverified ordering claim is exactly this arc's defect class.
could move: **Nothing executable — comment text only.** No reflow, lint 0, check-self PASS.
            Snapshot moves; LEG A does not.
unchecked:  I did not trace `checkBodyImpl`'s Module arm end to end, so I make no claim about the
            relative order of the seeds beyond the two grep-verified call-site line numbers above.
            The load-bearing half — that two of the three seeds happen in a DIFFERENT function — is
            DERIVED and stands.

### 991-O-a — ledger-repair — record the numlit descope at `numlitRefs` (#991's last residual)
sites:      `compiler/types/typecheck.mdk:6366` — a trailing comment added to the `numlitRefs` field
            inside `data PerRun`.
transform:  Recorded that the numeric-literal channel STAYS BESPOKE, with the reason (Float-
            defaulting machinery, `setNumlitFloats` — not obligation checking) and the issue number.
            Wording taken from #991's own body via `gh issue view 991`, not invented.
            **All three of #991's asks re-verified by me before writing, as the brief required:**
              ask 1 **DRAINED** — `implObls : Windowed UObligation` at `:6365`; `grep -n implOblToU`
                returns only three past-tense comments (`:4902`, `:19927`, `:21030`), no definition.
              ask 2 **DRAINED** — `:5203` reads "#991: every arm below is now LIVE".
              ask 3 was **LIVE** — `numlitRefs` carried no comment; `grep -n numlit … | grep -i
                'descope\|bespoke\|deliberate'` was empty. Now recorded. ⇒ **#991 drains.**
            **#829 check, DONE not assumed:** `grep -n '^data PerRun' …` → `6345:data PerRun = PerRun {`
            — the SAFE collapsed one-line header (and the record already carries interior comments at
            `:6365`/`:6368`). `medaka fmt --write` afterwards reported `already formatted`, i.e. it
            produced no reflow at all, so the #829 comment-shift could not have fired. I diffed the
            record by eye as well; the comment sits on its intended field.
could move: **Nothing executable — a trailing `--` comment on an existing field.** The field's type,
            name and position are byte-unchanged.  Snapshot moves; LEG A does not (no binding
            changed, and a record FIELD is not a top-level binding).
unchecked:  I did not verify the CLAIM the comment makes (that keeping numlit bespoke is *correct*)
            — I recorded the decision as #991 states it. Whether the numlit channel should migrate
            remains open; the comment does not claim to settle it.

### C-0 — ledger-repair (from P0-C) — retire the dead `declEnvsVisible`/`declEnvsUpTo` accessor path
sites:      `compiler/types/typecheck.mdk` — **DELETED** `declEnvsUpTo` (was `:2868-2869`),
            `declEnvsUpToGo` (was `:2871-2875`) and `export declEnvsVisible` (was `:2877-2880`),
            replaced by a tombstone comment. Also re-cut the two comment blocks that NAMED the
            deleted symbols: the A-3.1 block's "NOT LIVE: the filter" paragraph (was `:2687-2695`)
            and the A-3.2a block's "for the identical reason" sentence (was `:3218`) — leaving a
            comment that names a deleted symbol is the defect class this whole commit repairs.
transform:  Deletion of three functions with zero callers, plus a tombstone recording why they must
            not be re-added (the live shape is a predicate applied at the READ, not a pre-filtered
            row list).
            **RE-DERIVED BY ME at edit time — I did not take P0-C/P0-F's finding on trust:**
            `grep -rn 'declEnvsVisible\|declEnvsUpTo' --include=*.mdk .` over the whole worktree
            returned ONLY the three definitions plus three comment mentions, all in `typecheck.mdk`.
            No call site in `compiler/`, `stdlib/`, `test/` or `compiler/entries/`.
            **Doctest check, run because P0-F reported doctest-only readers for SIBLING functions:**
            that grep is over ALL `.mdk` text, doctest lines included, and returned no `>>>` hit.
            Non-`.mdk` hits are `test/registry_keying_ratchet.sh` (prose),
            `test/snapshots/compiler/typecheck.md` (a generated golden OF this file) and
            `.claude/sprint/*` — none of them a caller. **No live or doctest caller exists, so the
            brief's STOP-and-report condition did not trigger.**
            The `export` existed solely to silence `rule-dead-code` (its own comment said so);
            `medaka lint compiler/types/typecheck.mdk` after deletion → exit 0, so removing the
            definitions removed the need rather than exposing a new finding.
could move: **This is the ONE bite in the commit that deletes executable code, so it gets a real
            argument rather than "comments only": nothing can move, because nothing called it.**
            Three functions, zero call sites tree-wide, and the only `export`
            (`declEnvsVisible`) is imported by no `.mdk`. The deletion cannot change a judgment, a
            diagnostic, or emitted code, because no execution path reached the code.
            Corroborated, not merely argued: `make medaka` green and `make check-self` PASS — a
            surviving caller would have been a resolve error, the loudest available failure.
            ⚠️ **It DOES move BOTH golden families, and one of the diffs is NOT additive-only.**
            Snapshot: `test/snapshots/compiler/typecheck.md` contains all three definitions verbatim
            (`:2872-2884`) plus their AST renderings (`:28314-28320`, `:33264-33270`). Selfproc LEG A:
            `test/selfproc_goldens/legA/types.typecheck.golden` loses three top-level bindings —
            unlike every other bite here. That LEG A diff is a **DELETION**, the one case the
            standing "additive-only" rule flags for review. It is correct (the bindings are gone),
            but the testing round must not rubber-stamp it as routine. **Per sprint §5 I blessed
            neither.**
            Secondary, and a change to what a LATER unit reasons about rather than to behavior: this
            removes one of the five direct `declEnvVisibleAt` call sites, so A-3.6 now faces 4, all
            live. That is the bite's purpose.
unchecked:  I did not run the snapshot or selfproc gates (§5 defers both and forbids blessing), so
            the two golden moves above are DERIVED by reading the goldens, not observed as red gates.
            `make agent-doc-symbols` PASSes, which covers `AGENTS.md`, `.claude/**` and
            `docs/spec/*.md` — but that gate does **not** scan `test/*.sh`, and
            `test/registry_keying_ratchet.sh` still names `declEnvsVisible` in prose. It is OUT OF
            SCOPE by brief and was deliberately left; it is now a ninth stale reference in that file.
