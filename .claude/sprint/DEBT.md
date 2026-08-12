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

### F-0 — Unit F — pin #1597's field-owner false reject, in `must_fail_fixtures`, NOT `check_module_fixtures`
sites:      NEW `test/must_fail_fixtures/1597-unimported-record-votes-in-field-owners/`
            (`claim.txt`, `main.mdk`, `amod.mdk`, `bmod.mdk`);
            `.claude/HANDOFF.md` (one row in the Stage A table).
            🚩 **DIVERGES FROM P0-G F-0**, which specified
            `test/check_module_fixtures/unimported_record_no_field_vote/`. I built that first,
            MEASURED that the harness is structurally blind to this bug, and moved it.
transform:  Encode P0-G §1d / #1597's shape as a self-draining must-fail row: three modules
            (`amod` public `Zed { tag : String }`, `bmod` importing NOTHING with an UNSIGNATURED
            `readTag w = w.tag` over its own `Wye { tag : Int }`, `main` bare-importing both),
            pinned `cmd: check-json main.mdk` / `exit: 1` /
            `diag-code: T-AMBIGUOUS-FIELD 15:12-15:13`, control `check-json bmod.mdk`
            (the SAME FILE, byte-for-byte, as its own entry — the only variable is graph
            membership). Observed: **REPRO**, control green, 0 malformed
            (`sh test/diff_compiler_must_fail.sh` → `93 still reproduce, 5 DRAINED, 0
            control-broke, 0 malformed`; the 5 drains are pre-existing, none is 1597).
            WHY THE HARNESS MOVED, DERIVED not argued: `diff_compiler_check_modules.sh` diffs the
            ENTRY module's sorted scheme dump only, and
            `./test/bin/check_modules_main … entry.mdk <root>` over this exact graph prints
            `main : Unit` at **exit 0** — the rejection lives in `bmod.mdk`, whose schemes that
            dump never contains, and stderr is `2>/dev/null`'d. A cell there is GREEN before AND
            after the fix. The shape is also *structurally* inexpressible there: the reader must
            import nothing while the rival is in the graph, and the entry must import everything.
            (Positive control on my invocation: the same command on the existing
            `attributed_record_no_field_vote/` reproduces its committed `oracle.tcmod` exactly.)
could move: **Nothing in the compiler — no source was touched.** Two real gate-facing moves:
            (a) `test/must_fail_fixtures/` is a SHARED CORPUS; this adds one directory to
            `diff_compiler_must_fail.sh` (the `soundness` job) and to the nightly
            `must_fail_census.sh`. No gate edit is needed (the member set is `ls`-derived) and the
            one-fixture-per-issue and NOT-PINNABLE checks both pass.
            (b) The pinned RANGE is line-sensitive: `15:12-15:13` is `w.tag` in `bmod.mdk`,
            0-based. A COMMENT-ONLY edit to that file's header moves the pin and manufactures a
            false drain. Flagged in `claim.txt` itself.
unchecked:  I did NOT author the negative control (a `bmod` that genuinely `import amod`s and must
            STAY rejected — P0-G §1d's `/var/tmp/pf/v1`). This harness is one-entry-per-directory
            and one-fixture-per-issue, so it cannot hold both arms; it is recorded as OWED to
            #1597's fix in the claim's `why-note:` and must land there as a permanent regression
            test, since a drained must-fail leaves nothing behind. I also did not run
            `diff_compiler_check_modules.sh` end to end (§5 defers it) — I ran its probe binary
            directly, which is the part that decided the harness question.

### F-3 — Unit F — NOT LANDED. The briefed site cannot reach a `DAttrib`; #1586 does NOT drain.
sites:      **NONE. No compiler source was edited.** The briefed region,
            `declEnvDeclFieldOwners` (`compiler/types/typecheck.mdk:3065-3069`), is UNCHANGED.
transform:  None applied. Reported instead, per the brief's "STOP and report; do not build a
            half-predicate".
            WHY, a closed chain of DIRECT source readings (no inference), each grepped:
            1. `declEnvDeclFieldOwners` has exactly ONE production caller —
               `declEnvSeedChain:3061` — which passes `declEnvRowVisible (m.demOrd + 1) m`.
               (`grep -n declEnvDeclFieldOwners` → `:3061` + the definition + 2 doctest lines.)
            2. `declEnvRowVisible:2927-2931` at `cur = m.demOrd + 1`: guard 1 is
               `declEnvVisibleTo cur m.demOrd False`, and `declEnvVisibleTo:2911-2913` is
               `declEnvVisibleAt cur o && (o == cur || pub)` — with `o = cur - 1` and
               `pub = False` that is False. Guard 2 (`pub = True`) is True ⇒ the function returns
               `m.demPubDecls`, ALWAYS, on this call.
            3. `declEnvModule:2819`: `demPubDecls = publicDataDecls decls`.
            4. `publicDataDecls:25245` = `filterList publicDataDecl`; `publicDataDecl:25234-25239`
               has arms for `DData VisPublic` / `DInterface` / `DImpl` / `DTypeAlias` and then
               `_ = False` — **no `DAttrib` arm**.
            ⇒ A `DAttrib`-wrapped decl is filtered out at step 4 and can NEVER appear in
            `declEnvDeclFieldOwners`'s input on any production path. A `DAttrib` arm there is
            unreachable dead code: it drains nothing, and it moves no golden (contra P0-G F-3's
            `flips:` and `could move:` rows). The tree already says this in prose I found only
            after deriving it — `check_module_fixtures/attributed_record_no_field_vote/entry.mdk`
            calls the non-own arm *"the `publicDataDecls` memo, `DAttrib`-blind by construction"*.
            #1586 IS LIVE, measured on the binary I built (`make -C <trunk> medaka`, green):
            single-file repro (`data A = A { s : Int }` + `@deprecated "old" data B = B { s : Int }`
            + unsignatured `g r = r.s`) → **exit 0**, silent `g : A -> Int`;
            positive control (the attribute line removed, otherwise byte-identical) → **exit 1**,
            `T-AMBIGUOUS-FIELD`. Discriminating: the attribute is the only variable.
            Its real sites are `registerData` (`:12504-12523`, the Flat/own-row half — where
            #1586's headline S0 repro actually lives; `declEnvDeclFieldOwners` is not on the Flat
            path at all, `buildDeclEnvs` runs only on the Module entries), `resolve.mdk`'s
            `fieldOwnersOf` (#1586's second site, RELAYED from the issue — I did not open it), and
            — for the cross-module arm — `publicDataDecl` itself. That last one is NOT small and
            NOT pre-licensed: `typecheck.mdk:3398-3405` records that letting an attributed decl
            through `publicDataDecl` would expand an attributed alias in importers while it stays
            opaque at its declaration, *"an acceptance WIDENING, incoherent besides"*.
could move: **Nothing — no code changed.** Stated affirmatively because silence is not an entry:
            `declEnvDeclFieldOwners` is byte-identical to base, so no field-owner judgment, no
            `T-AMBIGUOUS-FIELD`/`T-UNKNOWN-FIELD` verdict, and no `oracle.tcmod` can move from
            this bite. The acceptance NARROWING P0-G pre-declared for F-3 (attributed records
            start voting; `attributed_record_no_field_vote` moves) **does not happen**, and Unit F
            therefore drains **neither** #1586 nor #1383 — F-4 was dropped by brief.
            The shape that WOULD have moved had the arm been reachable, named so the testing round
            can hunt it if a later unit lands the real fix: any program with a field name shared
            between an attributed record and an unattributed sibling, where today's silent accept
            becomes `T-AMBIGUOUS-FIELD`.
unchecked:  I did NOT build the arm and measure its inertness end to end — the claim is a closed
            source chain plus the tree's own corroborating prose, not a two-arm differential. That
            second build was declined deliberately: a concurrent implementer was editing
            `typecheck.mdk` throughout (`git status` → ` M`), so an A/B whose two arms straddle
            someone else's in-flight edits would not have isolated my one line (RUN-028). If the
            testing round wants the differential, it is one line and two builds on a quiet tree.
            I did not open `compiler/frontend/resolve.mdk`, and I did not verify P0-G's claim that
            `registerData`'s arm alone fixes the Flat half.

### A5a-1 — A-3.5a — `CeRow` gains the required-method projection (8th positional field)
sites:      `compiler/types/typecheck.mdk` — the `CeRow` field-order paragraph of the header
            block (`:4366-4383`), `data CeRow` (`:4409-4410`), the seven existing accessors
            (`:4411-4431`, each gaining one `_`), new accessor `ceRowRequired` (`:4433-4434`),
            and the single construction site in `classEnvRowsOf` (`:4481`).
transform:  8th positional field `List String`, populated `requiredMethodNames methods`.
            Positional, not a `ceMethods` 4-tuple widening: `ceRowMethods` has three live readers
            and the triple type appears in four signatures, so an 8th field is the strictly
            smaller diff — and positional is a MEASURED emitter constraint (`:4358-4368`), not a
            style choice. DERIVED that this is the only construction site: `grep -rn 'CeRow '
            compiler/` filtered to `CeRow ->`-free lines returns exactly the decl, the accessor
            patterns, and `:4481` — the CE doctest corpus builds rows through `buildClassEnv`,
            never by applying the constructor, so no doctest needed an arity fix.
could move: **Nothing.** A new field with no reader until `A5a-2`, and no existing field's
            position or value changed. Stated affirmatively rather than left silent: the only
            way this bite alone could move acceptance is if adding a field perturbed `CeRow`
            construction for an existing reader, and every existing accessor was re-derived
            positionally against the new arity in the same edit (`check-self` PASS is the
            mechanical witness — an arity slip would be a type error, not a silent shift).
            **#829 did NOT bite**, and the check was real, not assumed: `data CeRow =` IS the
            unsafe two-line header form (`grep -n '^data CeRow =$' -A1` → `| CeRow …`), so no
            interior comment was added — the new field's prose went into the standalone header
            paragraph that PRECEDES the decl. `fmt --write` reported `already formatted` on
            every run of this unit, i.e. zero reflow, so no comment could have been dragged.
unchecked:  I did not re-derive `ifaceParamKindsOf`/`declGradedScope`; they are untouched.
            I did not run the CE doctests (`medaka test`) — §5 defers them.

### A5a-2 — A-3.5a — `ceRequiredAt`, the read accessor, routed through the ONE predicate
sites:      `compiler/types/typecheck.mdk:4544-4564` — new `ceRequiredAt : RegKey -> Int ->
            ClassEnv -> Option (List String)` immediately after `ceRowsOwnedBy`/before
            `ceSlotKindsAt`'s block, with a header stating the routing rule and the miss policy.
transform:  `ceRequiredAt key cur env = map ceRowRequired (ceLookupAt key cur env)`.
            🚨 It goes through `ceLookupAt`, **never** `regLookupK env.ceByKey` — RUN-018's
            binding constraint, and `ceLookupAt`'s own header states why: a second open-coded
            path to `ceByKey` bypasses `declEnvVisibleAt` and performs A-3.6's widening early.
            A-3.6 depends on there being exactly ONE ordinal predicate to split.
            ⚠️ Two drafts, and the second is the shipped one. The first wrote `mapOption`
            (P0-B's suggested body) and **broke the build**: `E-PANIC: unbound variable
            'mapOption'` from the seed emitter — `mapOption` is exported from
            `compiler/support/util.mdk` but is NOT in `typecheck.mdk`'s import surface. The
            second used an explicit two-arm `match`, which built and passed `check-self`, but
            `medaka lint` then flagged it `[rule-match-to-map]` (the tree is at 0 findings and
            the pre-commit hook is a MAX ratchet, so leaving it would have failed the commit).
            The shipped form is the linter's own suggested rewrite, `map` over `Option`
            (`stdlib/core.mdk:761` `export impl Mappable Option`), rebuilt and re-verified.
could move: **Nothing.** No caller until `A5a-3`. The named hazard belongs to its callers, and
            is recorded here because this is where the policy lives: a `None` from this function
            means "no interface of that IDENTITY is visible at `cur`", and both call sites'
            miss arm is `[]` — **an identity miss produces no diagnostic at all**, a silent
            accept. That is this unit's characteristic failure and the reason the four
            baselines below are the bar rather than a code review.
unchecked:  The `map`-over-`Option` form is dict-passed where the `match` was monomorphic. I did
            NOT measure that (`compiler/AGENTS.md` warns against delegating HOT helpers to
            prelude methods). Judged out of scope rather than dismissed: this is called once per
            `DImpl` decl per module, not in an inner loop, and `perf_scaling` is deferred by §5.
            If the testing round sees a typecheck-time regression, this is a candidate.

### A5a-3 — A-3.5a — flip the Module arm onto CE
sites:      `compiler/types/typecheck.mdk` — `checkImplCompletenessMap` signature+body
            (`:15659-15663`), `implCompletenessMsgsOfMap`'s three clauses (`:15667-15681`,
            including the fall-through arm's arity), its header (`:15636-15658`), the mode
            switch (`:20010`), and the `classEnvHere` binding (`:19887-19892`).
transform:  `Registry (List String)` → `ClassEnv -> Int`; `regLookupK (regKeyOfTab (ifaceTabKey
            o iface)) reqMap` → `ceRequiredAt (regKeyOfTab (ifaceTabKey o iface)) cur ce`. The
            occurrence-mint discipline is preserved verbatim — `implOrigin = o` still
            destructured beside `iface` in the same record pattern.
            ⚠️ **I did NOT bind a new `(ce, ord)` pair as P0-B's site list suggests.** The pair
            already existed: A-3.5c's `gradedClassEnv` (`:19887`) computes exactly
            `Flat _ => (flatClassEnvOf prog, 0)` / `Module mid _ _ => (envs.deIfaces,
            declEnvsOrdOf mid envs)`, and it is bound BEFORE the completeness site. A second
            binding would have folded the whole decl list into a second `ClassEnv` per flat
            compile and created two copies that can drift. It is instead **renamed**
            `gradedClassEnv` → `classEnvHere` (it now has two consumers), and its one in-file
            citation at `:1846` was updated in the same edit so no stale symbol is left.
could move: **A Module-arm `T-INCOMPLETE-IMPL` could VANISH (silent accept) or APPEAR.** The KEY
            does not move — `regKeyOfTab (ifaceTabKey implOrigin iface)` on the read side both
            before and after, and `classEnvRowsOf:4477` mints `CeRow`'s key from the same
            `ifaceTabKey ifaceOrigin name` the retired `insertIfaceRequired` used — so the only
            variable is POPULATION. Before: an accumulator grown by `appendUniverseAccums prog0`
            earlier in this same body, holding ordinals `0..cur` inclusive. After: the whole-graph
            `CE` filtered by `declEnvVisibleAt cur o` = `entryOrd <= cur`, the same prefix.
            **That equality is the unit's owed evidence and I did not measure it** — see below.
            Secondary, argued not measured: required-ness is prePass-INVARIANT, so building `CE`
            from raw `demDecls` while this body may hold prePass-rewritten decls cannot change
            the answer (`requiredMethodNames` reads only the `Some`/`None` presence of
            `IfaceMethod`'s third position; the prePass rewrite touches only a `Some (…, e)`
            arm's body). I read `requiredMethodNames` first-hand; `prePassIfaceMethodScoped` is
            RELAYED from the CE header, not re-derived.
            **MEASURED, and it is a discriminating probe rather than a control**: a 2-module
            project (`iface.mdk` exports `interface Loc` with two required methods, `main.mdk`
            imports it and impls only one) rejects at exit 1, `main.mdk:6:9: 'impl Loc Bar' is
            missing method 'lg'`, byte-identical on `check` and `run`, before and after. It is
            fail-capable in the exact direction that matters: had `ceRequiredAt` missed, the
            `None => []` arm would have produced exit 0 with no diagnostic.
unchecked:  🚩 **The `DL` decl-list identity is OWED and I did not measure it.** Is
            `checkBodyImpl`'s `prog0` the same list as the corresponding
            `DeclEnvModule.demDecls`? A-3.4 PR2 measured the analogous proposition for IE with a
            temporary hard-panic instrument it deleted before merge; P0-B §3.2 says CE must
            measure its own and may not cite IE's (#1112's own A-3.4 comment: *"A-3.2's DataEnv
            and A-3.3's CE must measure their own and may not cite this one"*). I did not build
            that instrument — it is a second full build plus an instrumented third, outside this
            bite's brief, and §5 defers gate-level evidence. **This is the single most
            load-bearing unchecked item in A-3.5a**, and the two-module probe above is a spot
            check of it, not a proof: it witnesses ONE (importer, imported-interface) shape at
            one ordinal, not set equality across a graph.
            I also did not vary the surrounding program to hunt an UNDERCOUNT — an absence probe
            cannot see one. A graph where module `k` declares an interface and a topologically
            LATER module impls it incompletely alongside other interfaces is the shape that
            would discriminate; not written.

### A5a-4 — A-3.5a — flip the Flat arm and unify (**the unit's only genuine re-key**)
sites:      `compiler/types/typecheck.mdk` — `checkImplCompleteness` and
            `implCompletenessMsgsOf` **deleted**, their P0-17 header retained and re-cut
            (`:15544-15586`); `ifaceRequiredMethods` **deleted**, replaced by a re-cut header on
            the surviving `requiredMethodNames` (`:15601-15610`); the mode switch collapsed from
            a two-arm `match mode` to one call (`:20001-20010`); the `fullUniverse` binding's
            consumer list (`:19566-19573`) corrected to drop `checkImplCompleteness`; a
            `Map`-suffix note added to `checkImplCompletenessMap`'s header (`:15615-15621`).
transform:  Both arms now call `checkImplCompletenessMap (fst classEnvHere) (snd classEnvHere)
            prog`. The Flat arm's bare-name first-match scan is gone. DERIVED that
            `flatClassEnvOf prog` IS `flatClassEnvOf fullUniverse`: `fullUniverse = prog` on the
            `Flat _` arm (`:19574-19576`), and `checkImplCompleteness` was called
            `fullUniverse prog`, so lookup-list and iterate-list were already the same object.
            ⚠️ **`checkImplCompletenessMap` is NOT renamed** even though its `Map` suffix named
            the `Registry` it no longer takes. Deliberate, and recorded rather than left as a
            silent lie: it is cited from `compiler/frontend/resolve.mdk:3948`, from
            `compiler/TYPECHECK-TARGET-ARCHITECTURE.md:1804` and from three comment blocks in
            `typecheck.mdk` (`:1640`, `:1688`, `:15622`); a rename strands all of them, which is
            the stale-symbol failure this arc has paid for repeatedly (#1574, RUN-009, RUN-015).
            A header note at `:15615` says the suffix is historical.
could move: **This is the bite that carries the unit's acceptance delta, and it is confined to
            the FLAT arm.** Under the owner ruling on #1557 OWED 1 (re-key; CE grows no
            bare-spelling compatibility leg), the delta is:
            1. 🚩 **A flat program where a USER interface shadows a PRELUDE one by spelling.**
               On the split entry `prog = coreProg ++ userProg`, the deleted scan walked that
               list HEAD-FIRST, so a user `interface Eq a` lost to the prelude's `Eq` and the
               PRELUDE's required set was returned for a user impl. Under identity the impl's
               own `implOrigin` decides — the correct answer. **A real Flat acceptance delta
               with no existing fixture, in BOTH directions** (an impl that was rejected for
               missing the prelude's method may now pass; one that silently passed may now be
               rejected). **I did not hand-derive the expected value from DICT §8 and I did not
               write the fixture.** This is the testing round's first target for A-3.5a.
            2. Two same-spelled interfaces in ONE flat file cannot occur — resolve rejects
               `Duplicate interface` within a module. RELAYED from P0-B, not re-derived. So the
               #1258 class has no intra-file flat instance; item 1 is the flat instance that does.
            3. **Loud → silent, asked explicitly.** The relocated miss policy is `None => []`.
               A key that MISSES where the old bare scan HIT produces no diagnostic at all.
            **MEASURED — both flat baselines still reject, same message, same location**
            (byte-compared against the pre-edit capture, `diff` exit 0): flat LOCAL interface
            (`impl Loc Bar` missing `lf`, exit 1, `:1:0`) and flat PRELUDE interface (`impl Eq
            Foo` missing `eq`, exit 1, `:1:0`). The second is the discriminating one — P0-B §3.3
            records that `:1669-1697` argued *structurally only* that a flat `impl <prelude
            iface> T` keys `TkIdent … core` and meets the prelude declaration's `TkIdent … core`
            row, *"because the completeness table is Module-only"* and no fixture could witness
            it. A-3.5a is the change that makes it witnessable, and it is now witnessed.
            🚨 The Flat arm does NOT read `declEnvsRef`: `buildDeclEnvs` runs only at the two
            Module-mode driver entries, so that envelope is `emptyDeclEnvs` on every flat path
            and a Flat read would make `ceRequiredAt` miss on EVERY interface — turning both
            baselines above into silent accepts. `classEnvHere`'s `Flat _` arm is what prevents
            it, and the two probes are the tripwire. (`buildDeclEnvs`' two-entry restriction is
            RELAYED from the in-source comment, not re-derived.)
            `firstImplMethodLoc` is preserved by construction: iteration stays over DECLS, so
            the location still comes from the first impl-method body's `exprLoc`. Per RUN-018
            this is exactly why A-3.5a is not implemented against IE.
unchecked:  The user-shadows-prelude fixture (item 1) — not written, and the correct answer not
            hand-derived. I did not run any snapshot, golden, engines or must-fail gate (§5).
            The flat probes cover a LOCAL and a PRELUDE interface; they do not cover an
            attributed (`DAttrib`-wrapped) interface decl on the Flat arm, whose unwrapping now
            comes from `classEnvDeclFact` instead of `ifaceRequiredMethods` — argued equivalent
            (both unwrap `DAttrib` recursively), not measured.

### A5a-5 — A-3.5a — retire `universeIfaceRequiredRef` (`cross_allowed` 24 → 23)
sites:      `compiler/types/typecheck.mdk` — the `CrossRun` field (deleted, tombstoned in place
            at `:5616-5629`), the `freshCrossRun` initializer (deleted), the writer
            `insertIfaceRequired` (deleted, tombstoned at `:15681-15687`), its `setRef` inside
            `appendUniverseAccums` (deleted; that function's header re-cut at `:24887-24900`),
            and three stale prose references corrected: `:1616-1621`, `:4272-4278` (marked a
            DATED SNAPSHOT rather than rewritten, since its own claim survives), `:26779`.
            `test/registry_keying_ratchet.sh` — the allowlist row deleted, the `join_setref`
            helper comment de-referenced (it cited this field as its worked example), and the
            `declEnvsRef` hand-off row corrected. `compiler/TYPECHECK-TARGET-ARCHITECTURE.md:1804`
            — the row flipped DEFERRED → ✅ LANDED with the 24 → 23 transition.
transform:  Delete the cell, its initializer, its writer and its call; remove the allowlist row;
            flip the doc row. **DERIVED, not relayed: `sh test/registry_keying_ratchet.sh` →
            PASS, `ok: 23 CrossRun field(s), 22 DriverState field(s)` and `ok: 23
            crossRun.value.* write target(s)` — 24 → 23, measured on this unit's own base.**
            ⚠️ The ratchet's `declEnvsRef` row said *"A-3.5a (`universeIfaceRequiredRef`) and
            A-3.5b remain owed; **both read IE** and stay in the A-3b lane."* Both halves were
            wrong and both are corrected in place rather than deleted (RUN-018 ruled A-3.5a is
            CE-only; iterating `IE.ieRows` would lose every `T-INCOMPLETE-IMPL` location because
            `ImplRow` deliberately carries no `Loc`). That row is the arc's hand-off channel and
            is outside `check_agent_doc_symbols.sh`'s corpus — the #1574 thesis.
could move: **Nothing behavioral — a table with no remaining reader after `A5a-3`/`A5a-4`.**
            Not asserted from the diff: `grep -n universeIfaceRequiredRef typecheck.mdk` after
            this bite returns **only comment lines** (the tombstone and four back-references),
            zero declaration and zero read sites. DERIVED that it is **not** in the
            `loadDataUniverse`/`storeDataUniverse` ladder — it was written only from
            `appendUniverseAccums` — so unlike A-3.5c this retirement cannot desynchronize that
            marshalling pair's two lists.
            One second-order shape, named because it is the kind of thing a diff hides: removing
            the line from `appendUniverseAccums` removes an ORDERING dependency, not just a
            write. That comment recorded *"called BEFORE the shadow/key/completeness reads, so
            this module's own decls are visible there"*. Completeness no longer depends on it —
            `declEnvVisibleAt cur o` is `o <= cur`, which admits the reader's OWN row — and the
            re-cut header says so, so a later unit cannot restore the accumulator to fix an
            ordering property that has moved onto the ordinal predicate.
unchecked:  I did not run the ratchet's sibling gates, nor `make agent-doc-symbols` /
            `make docs-links` (§5 defers the doc gates). The three prose corrections were made
            by reading, not by a symbol gate — and `test/*.sh` is outside that gate's corpus
            anyway, which is precisely #1574.
            🚩 **`A5a-6` (dispose of `ieMethods`) was NOT cut** — skipped by brief, as CONDITIONAL
            on an unruled question. `ieMethods` therefore still has ZERO readers, and the
            in-source note at `implDeclFacts` still names A-3.5 as its consumer while A-3.5a has
            now declined it. That note is now stale in the same way the ratchet row was, and
            nobody owns it: it needs either the field dropped or the note re-pointed at
            A-3.7/B-2. ⚠️ RUN-021 independently reports that **A-3.7 gives `ieMethods` no reader
            either** (coherence compares `(iface, head)` only), so "re-point it at A-3.7" is not
            a free answer.
