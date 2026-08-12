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

---

> 🚨 **LINE NUMBERS IN THE FOUR ROWS BELOW ARE DELIBERATELY ABSENT — cite by SYMBOL.**
> These bites were written and measured while `compiler/types/typecheck.mdk` was quiescent
> at `f3d7f747`; A-3.6 then inserted ~109 lines above line 4144 **while this report was
> being written**, shifting every number by a non-uniform amount. Every anchor here is a
> symbol name, greppable at whatever HEAD you read this. See the operational note at the
> end of A5b-3's `unchecked:`.

### A5b-1 — A-3.5b — `IE` gains a row-set read at an ordinal (`ieRowsVisibleAt`)
sites:      `compiler/types/typecheck.mdk` — new `ieRowsVisibleAt` + header, immediately after
            `ieSnapAt`. Three comment re-cuts forced by its arrival, each of which asserted a
            fact this bite falsifies: the `ieUniverseAt` header (*"here is the only place
            `declEnvVisibleAt` is applied to `IE`"*), the `ieSnapAt` header (*"The ONE place
            …"*), and `checkBodyImpl`'s Module-arm note at the `moduleImplUniv` binding (*"the
            ONE read accessor, the ONE place …"*). Plus the `ceLookupAt` header, which cited
            `ieUniverseAt`/`ieSnapAt` as *"the one read path for `IE`"*.
transform:  `filterList (r => declEnvVisibleAt cur (ieRowOrd r)) env.ieRows` — the exact peer of
            `ceRowsVisibleAt`. As written it was routed through the ONE predicate on the stated
            grounds that A-3.6 would still have a single body to delete.
            🚩 **THAT GROUND WAS REMOVED BY A-3.6 WHILE THIS ROW WAS BEING WRITTEN**, and the
            row is corrected rather than left standing: A-3.6 SPLIT the predicate by owner
            ruling (RUN-010), moving `ieSnapAt` onto a new `ieCandidacyVisibleAt` (`True`) while
            `ieRowsVisibleAt` stayed on `declEnvVisibleAt`. That is the RIGHT outcome for this
            function — A-3.6's licence is I5's subject, `match(IE, C τ̄)`, and a decl-time
            EXISTENCE query is not that — but it means the two `IE` reads no longer share a
            predicate. `ieRowsVisibleAt`'s header was re-cut in place to say so and to retire the
            "one body" framing; A-3.6's own `ieCandidacyVisibleAt` header states the same thing
            from the other side and explicitly records that whether super-existence should see
            the whole graph is **NOT ruled**.
could move: **Nothing on its own — no caller until `A5b-3`.** What is NOT nothing is the arc's
            bookkeeping: `declEnvVisibleAt` gained one more production reader than RUN-013's
            enumeration of eight records. That enumeration is A-3.6's checklist for *"prove each
            of the seven I left alone was left alone"*, so **A-3.6 must re-derive it rather than
            reuse RUN-013's number** — this bite added a ninth path after that census was taken.
            🚩 **OWED, and it is a real open question, not bookkeeping:** under the split,
            super-existence is the ONE `IE` reader still ordinal-scoped. If instance candidacy is
            graph-global (C4/I2) but the super-EXISTENCE gate is prefix-scoped, then an
            `impl Sup T` in a topologically LATER module satisfies dispatch while still being
            reported missing by `checkSuperImpls`. Nobody has ruled whether that is intended.
            P0-B §4.3(4) asks for a fixture pinning exactly this shape and **it was not written**
            (see `unchecked:` in A5b-3).
unchecked:  Allocation was not measured. The function allocates a fresh list per call where the
            old code allocated nothing (`anyList` over a decl list is a pure traversal) — a
            constant-factor alloc increase in a GC-bound stage, which `perf_scaling`'s
            growth-ratio grading is structurally blind to (`compiler/AGENTS.md`, "the exception
            that IS one"). It is bound ONCE per whole-module check, so it is O(rows) per check
            and not per (impl × super) — the shape A-3.4 PR2 was caught for. §5 defers
            `perf_scaling`.

### A5b-2 — A-3.5b — the Flat `ImplEnv` (`flatImplEnvOf`)
sites:      `compiler/types/typecheck.mdk` — new `flatImplEnvOf` + header, immediately after
            `flatClassEnvOf`.
transform:  `buildImplEnv [declEnvModule 0 "" decls]` — the exact peer of `flatClassEnvOf`.
            **The Flat arm, answered explicitly:** `buildDeclEnvs` runs only at the two
            Module-mode driver entries, so `driverState.declEnvsRef.deImpls` is `emptyImplEnv` on
            every flat path; `A5b-4` therefore passes this, never `declEnvsRef`.
could move: **Nothing on its own — no caller until `A5b-4`.** Recorded anyway because it INVERTS
            the sibling hazard and a reader will assume otherwise: reading the empty envelope
            here would NOT be a silent accept. A miss in the super-EXISTENCE query makes
            `superImplExists` return `False`, which REPORTS a missing superinterface — so the
            Flat failure mode is a false REJECT of every `impl Sub T` on `medaka check <one
            file>`: loud, but wrong. (The silent-accept direction lives in `A5b-3`'s *other*
            lookup.) The header states this rather than copying `flatClassEnvOf`'s wording.
unchecked:  Not measured: `buildImplEnv` over the flat `prog` is a second whole-program fold
            beside `flatClassEnvOf`'s, on every flat `check`/`run`. Flat `prog` on the seeded
            entries is `coreProg ++ userProg`, i.e. the whole prelude, so this is a
            per-invocation constant, not per-module. No alloc A/B was run (§5).

### A5b-3 — A-3.5b — relocate both `T-MISSING-SUPER-IMPL` lookups onto stage K
sites:      `compiler/types/typecheck.mdk` — `checkSuperImpls` (+ header), `superImplMsgsOf`
            (+ header), `superMsgFor`, `superImplExists` (+ header), and `implMatchesSuper` →
            renamed **`implRowMatchesSuper`** (+ header).
            `ifaceSupersOf` is READ-unchanged and **NOT deleted**.
transform:  Lookup 1 (supers): `ifaceSupersOf allDecls iface` → `ceLookupAt (regKeyOfTab
            (ifaceTabKey implOrigin iface)) cur ce`, taking `(ceRowTyparams r, ceRowSupers r)`.
            Occurrence mint — `implOrigin` destructured beside `iface` in one record pattern, the
            `implCompletenessMsgsOfMap` discipline. Lookup 2 (existence): a scan of `allDecls`
            whose iface test was the bare `iface == superName` → a scan of the pre-bound visible
            `List ImplRow`, testing each row's OWN `IfaceRef` against the super's `superOrigin`
            key.
            **The three non-negotiables, each verified then honoured:**
            (1) `ifaceSupersOf` SURVIVES. Caller set RE-DERIVED (`grep -rn ifaceSupersOf
            --include=*.mdk .`): four code sites outside this check — `:8822` (constraint
            solving), `:11270` (`directSupers`, reading `superDeclsRef`), `:24365`
            (`censusSuperSlotsOf`), `:24395` (`censusSuperSlotsVecOf`) — plus its own recursion
            and one fixture comment. Matches P0-B's four exactly, at shifted lines. Only
            `superImplMsgsOf`'s use was re-pointed.
            (2) `tyMatchesAst` KEPT, `ImplUniverse` NOT used. `ImplRow`'s 4th position is
            `List Ty` (AST), so the predicate applies verbatim; `ieRowsVisibleAt` exists precisely
            so this check need not go through `ieUniverseAt`, whose `Mono`/`matchStep` matcher
            would be a second unbudgeted acceptance delta.
            (3) IDENTITY LEG ONLY. The query reads `ieRows` and tests each row's `IfaceRef`; it
            never looks the super's key up in `ieConcrete`/`ieHeadless`, whose `oblIfaceKeys` mint
            adds the bare-spelling compatibility leg #1438 rides on. Reading a bucket would have
            rebuilt that collapse in the new substrate.
            Perf: `ieRowsVisibleAt cur ie` is bound ONCE in `checkSuperImpls` and threaded; it is
            never called inside `superMsgFor`. `implRowMatchesSuper` tests the bare NAME first and
            the IDENTITY key second — bare-name equality is a NECESSARY condition for key equality
            (`tabKeyOf` puts the same name into both the `TkIdent` and the `TkBare` arm), so the
            gate is sound and it bounds `ifaceTabKey`'s per-row allocation to the set the OLD bare
            scan already let through. The DECIDING test is still the identity compare; the name
            test decides nothing on its own.
could move: 1. **🚨 The unit's primary hazard, unchanged and NOT eliminated: lookup 1's miss arm
               is an ABSTENTION.** A `ceLookupAt` miss yields `[]` — no diagnostic — where the
               bare scan found the interface by spelling regardless. `OriginUnresolved` is a legal
               inhabitant, so this is not hypothetical. **I deliberately did NOT make it fail
               loud** — see `unchecked:`. The tripwires are the two measured baselines below, and
               an identity miss turns both GREEN, which is the direction that matters.
            2. **Same-spelled interfaces, both directions** (P0-B §4.3(2), now live): (a) a super
               requirement satisfied today by an impl of a *different, same-spelled* interface now
               correctly REJECTS — a NEW rejection on programs that compile today, hand-derivable
               but with no fixture; (b) `ifaceSupersOf`'s first match could return the wrong
               interface's `supers` list entirely, so the SET of supers checked can change.
            3. **Population.** Lookup 2's candidate set moves from `allDecls` (Module:
               `accAll ++ accData ++ prog`) to IE's rows at `cur`. **OWED and not closed here** —
               see `unchecked:`.
            4. **Message and ORDER unchanged by construction.** Iteration still walks `cohDecls`
               (`userDecls`) in the same order, `missingSuperImplMsg` is untouched, and
               `runFinalChecks`' call order (coherence → cycles → phantom → super-impls) is
               unmoved, so no diagnostic re-ranks against another family.
            MEASURED, before and after, `MEDAKA_STRICT=1`, exit codes read from a file and never
            from a pipe — all five baselines byte-identical across the change, message AND
            location: flat local `T-INCOMPLETE-IMPL` (exit 1, `'impl Loc Bar' … 'lf'`); flat
            prelude-interface (exit 1, `'impl Eq Foo' … 'eq'`); flat `T-MISSING-SUPER-IMPL`
            (exit 1 at `10:9`); 2-module `T-MISSING-SUPER-IMPL` on `check` AND `run` (exit 1 at
            `main.mdk:6:9` both — ONE observation of a typecheck-stage change, not two); 2-module
            Module-arm completeness (exit 1, `missing method 'lg'` at `7:15`).
            POSITIVE CONTROLS, both exit 0 after the change: flat `impl Sup Bar` + `impl Sub Bar`
            accepted; and a 2-module graph where the satisfying `impl Sup Zed` lives in the
            IMPORTED module and is **not** `export`-marked — the property the `pickSchemes`
            header makes load-bearing (*"WS-1a fix: every impl in scope, EXPORT OR NOT"*) —
            accepted on `check` and `run`.
unchecked:  🚩 **DISAGREEMENT WITH THE BRIEF, reported rather than silently resolved.** The brief
            states *"Every miss path must fail closed and loud, never to an empty result."* I did
            not do that for lookup 1. Making it loud is a NEW rejection class — an acceptance
            NARROWING — and the standing argument in `declEnvVisibleAt`'s own header block (R2's
            two exceptions are both WIDENINGS carried by a could-not-pass-before fixture;
            `grep -n 'narrowing cannot meet that bar'`) says that needs a licence nobody has
            issued. Both sibling relocations kept
            the abstention: A-3.5c's `ifaceDfsCycleOneSuper` (`None => []`) and A-3.5a's
            `implCompletenessMsgsOfMap` (`None => []`), and `ifaceSupersOf`'s own pre-existing
            `None` arm did too. **If the owner wants fail-loud, it should be ruled for all three
            at once, not smuggled in here.** Lookup 2's miss direction is already loud (a miss ⇒
            report missing), so only lookup 1 is at issue.
            🚩 **The `DL` population equality is OWED and I did not measure it** (P0-B §4.3(3)):
            is IE's visible row set at `cur` the same impl SET as `accAll ++ accData ++ prog`?
            One necessary half was DERIVED rather than assumed, because the `pickSchemes` WS-1a
            header makes it load-bearing: `buildImplEnvGo` reads `m.demDecls` — the module's FULL
            decl list, not `demPubDecls` (`declEnvModule`) — so non-`export` impls reach IE, and the
            2-module positive control corroborates it end-to-end. The remaining half — that no
            impl in `accAll ++ accData ++ prog` is MISSING from IE at `cur` — is a measurement of
            A-3.4 PR2's shape and is not done. Note the asymmetry: the baselines are tripwires for
            a WIDENING (a wider set silences a rejection); a NARROWING would keep them red and is
            unpinned.
            🚩 **`runFinalChecks`' `cycDecls` parameter is now DEAD** — I left it as `_cycDecls`
            rather than removing it, to avoid deleting the subject of `checkInterfaceCycles`'
            root-set derivation and to keep the diff minimal. Consequence: the Module caller still
            computes `accAll ++ accData ++ prog` for a parameter nobody reads. A later unit can
            retire both; recorded so it is not mistaken for a live population.
            No gate beyond `registry_keying_ratchet.sh` and `check-self` was run (§5). Snapshot
            and selfproc LEG A are expected red for the run; `ieRowsVisibleAt`, `flatImplEnvOf`
            and `implRowMatchesSuper` are three ADDED bindings, `implMatchesSuper` one DELETED,
            and four schemes RE-TYPED — so the LEG A delta will be neither additive-only nor
            pure-deletion.
            🚩 **P0-B §4.3(4)'s A-3.6 TRIPWIRE FIXTURE WAS NOT WRITTEN** — a fixture asserting
            that a topologically LATER impl still does NOT satisfy a super requirement. #1557's
            own bar asks for it and it is now MORE load-bearing than when it was specified,
            because A-3.6 has since split the predicate and left this the only ordinal-scoped
            `IE` read (see A5b-1's `could move:`). Construction warning, RELAYED from #1112's
            2026-08-10 comment and reportedly worth two agents' false nulls: the goal must be
            elaborated in a module topologically EARLIER than the impl's — a fixture whose goal
            lives in `main` cannot discriminate, because `main` is always last.
            🚨 **OPERATIONAL — the measurements above are clean, but only just, and the
            provenance is worth recording.** The brief for this unit stated *"You are the ONLY
            agent live — the worktree is quiescent and yours alone."* That was already false, or
            became false during the unit: HEAD is `f3d7f747` *"switch to max-throughput posture;
            whole remaining stage in flight"*, and while these rows were being written `ps`
            showed a concurrent `make medaka`, a concurrent `diff_compiler_must_fail.sh`, an
            untracked `test/must_fail_fixtures/1438-…` (A-3.7's pin, RUN-025) and A-3.6's
            uncommitted predicate split in this same file. **Everything measured in this unit —
            the build, all five baselines, both positive controls and the ratchet — was taken
            BEFORE those edits reached disk**, established not by assumption but by a line-anchor
            grep taken after the ratchet run that still showed the pre-split layout. Nothing
            after that point was re-measured, deliberately: RUN-033 records that a mid-edit tree
            reported five phantom drains. **This is the fourth contaminated-scheduling event of
            the run** (RUN-028, RUN-032, RUN-033, this) and the first where an implementer's
            brief actively asserted quiescence that did not hold.

### A5b-4 — A-3.5b — thread the `ImplEnv` through `runFinalChecks` and its three call sites
sites:      `compiler/types/typecheck.mdk` — `runFinalChecks` (signature, body and header);
            callers `checkToLines`, `seedAndCheckSplit`, `checkModuleFullDiags`.
transform:  One more parameter, `ImplEnv`, placed after `cycCe` and before `cur`.
            **Which env each caller passes, and why it is the peer of what it replaced:**
            `checkToLines` and `seedAndCheckSplit` pass `flatImplEnvOf` of *exactly the list they
            already pass as `cycDecls`* (`prog` in both) — the same list the super-existence scan
            used to be handed, so the population question is *"does IE over that list equal that
            list"*, which is `A5b-3`'s owed measurement and not a new one.
            `checkModuleFullDiags` passes the whole-graph `declEnvsHere.deImpls` at `ordHere`;
            both were already bound at that site, so nothing new is derived and the ordinal is
            the SAME key `ceHere` and `moduleImplUniv` (`checkBodyImpl`) read at.
            `checkSuperImpls` is handed `cycCe`, **not** `ownCe`: `cycCe` is the CE peer of
            `cycDecls`, the list the check used to read. On Module both are `ceHere`; on the split
            Flat entry they genuinely differ (`flatClassEnvOf userDecls` vs `flatClassEnvOf prog`)
            and the whole-universe one is the correct choice.
could move: **Nothing from the plumbing itself** — a parameter added and passed. The behavioural
            content is entirely `A5b-3`'s. Two things that COULD have moved and were checked
            rather than assumed: the call ORDER inside `runFinalChecks` is untouched (RUN-021 and
            the site's own comment make it load-bearing), and no caller was given an env built
            from a different list than the one it already passed as `cycDecls`.
unchecked:  ⚠️ This bite touches the exact three call sites A-3.5c last edited. The region had NOT
            changed under me — all three were where A-3.5c left them, with A-3.5c's comments
            intact — so §4's STOP-and-report rule was not triggered. The caller set is DERIVED:
            `grep -rn runFinalChecks --include=*.mdk .` → exactly three call sites, all in
            `typecheck.mdk` (in `checkToLines`, `seedAndCheckSplit` and `checkModuleFullDiags`);
            every other hit is a comment. A caller
            reached through a re-export was not separately excluded beyond that grep and
            `check-self`.

### 3.7-0 — A-3.7 — author the missing #1438 pin, and observe it REPRO before the widening
sites:      `test/must_fail_fixtures/1438-same-spelled-interfaces-collapse-in-coherence/`
            (new: `amod.mdk`, `zmod.mdk`, `main.mdk`, `omod.mdk`, `control.mdk`, `claim.txt`)
transform:  new must-fail row. `amod` and `zmod` are two UNRELATED modules (no import edge)
            that each declare their OWN interface spelled `Same` — different methods — and each
            `impl Same Int`. `main.mdk` puts both in one graph and uses one method from each.
            Pinned: `check-json main.mdk` / `exit: 1` / `diag: T-CONFLICTING-IMPL
            None:None-None:None Conflicting ...`. Control: `check-json control.mdk` — the SAME
            program with the second module's interface spelled `Other`, measured exit 0 with an
            empty diagnostic list.
            RUN-025's ORDERING WAS HONOURED AND MEASURED, not asserted:
              * pin authored, then `sh test/diff_compiler_must_fail.sh` on the pre-3.7-4 binary
                (built from `f66198c2`) → **`REPRO 1438-same-spelled-interfaces-collapse-in-coherence`**;
              * 3.7-4 landed and the tree rebuilt → **`DRAINED 1438-... (issue #1438)`**.
            `diag:` rather than the default `diag-code:` is DELIBERATE and derived: this
            diagnostic is pushed by the cross-module arm, which drops its span on purpose
            (#414), so the JSON `range` is `null` and `diag-code:` would degenerate to the bare
            code — asserting nothing about WHICH conflict was found. The message is where the
            claim lives: it names the interface and BOTH owning modules.
could move: **The pin's own verdict, by design — and that is the deliverable, not a break.**
            Beyond that: nothing executable. It adds one directory to a corpus whose member set
            is `ls test/must_fail_fixtures/` (the gate encodes no table and no count), so it
            enrols in exactly one consumer — `test/diff_compiler_must_fail.sh`, which runs in
            the `soundness` job, not a gate shard.
            ⚠️ `diag:` pins the full message, so an unrelated error-quality PR that rewords
            `cohCrossModuleMsg` drains this row SPURIOUSLY. The trade is stated in `claim.txt`
            with the instruction to re-derive rather than delete.
            🚨 **DO NOT CLOSE #1438 on this drain.** It drains only #1438's *coherence reach*;
            the obligation channel's bare compatibility leg survives, is pinned separately by
            fixture 1514, and belongs to #1482/#1507. Written into `claim.txt`'s `why-note:` so
            the instruction travels with the fixture rather than only with this ledger.
unchecked:  The suite was run against a NON-QUIESCENT tree — Lane B and A-3.6 both held
            uncommitted edits throughout — so the run's OTHER rows are contaminated in exactly
            the RUN-032/RUN-033 shape: 5–6 unrelated rows reported DRAINED, and the count was
            UNSTABLE across two runs one minute apart (5, then 6, with my row REPRO in both).
            **Those are not mine and must not be acted on**; they need re-derivation on a
            quiescent tree. My row's verdict is unaffected by that instability — it read REPRO
            in both pre-fix runs and DRAINED in the post-fix run, which is the only signal
            claimed here.
            Not verified: that `run`'s exit/message stay in step with `check`'s after 3.7-4
            (they did before — measured, exit 1, identical text). The pin grades `check-json`.

### 3.7-3 — A-3.7 — `cohSameIface`, the acceptance-direction interface identity predicate
sites:      `compiler/types/typecheck.mdk` — new `cohSameIface : IfaceRef -> IfaceRef -> Bool`
            immediately above `cohScanInner`, with a ~24-line derivation comment.
transform:  `cohSameIface a b = sameTyConHead a.irName a.irOrigin b.irName b.irOrigin`.
            The comment states WHY `ifaceIdMatches` is wrong here, because that is the function
            a reader reaches for: the two are exact inverses — `sameTyConHead` lets an ABSENT
            origin match anything, `ifaceIdMatches` (`a != "" && a == b`) lets absence match
            nothing, not even itself. Coherence answers an ACCEPTANCE question, so absence must
            make no claim; `ifaceIdMatches` in this position would convert every
            unstamped-origin conflict into a SILENT ACCEPT — a severity increase.
could move: **Nothing on its own** — at the moment of this edit it had no reader; it becomes
            live in 3.7-4, and 3.7-4's row owns the acceptance delta. The one way this bite
            alone could move behaviour is by picking the wrong predicate, which is precisely
            what its comment exists to prevent a later editor from "fixing".
unchecked:  `sameTyConHead`'s own semantics were read (`compiler/frontend/ast.mdk`, the
            `n1 == n2 && not (tyConIdsConflict o1 o2)` body and `tyConIdsConflict`'s
            absence-makes-no-claim `_ => False` arm) but not re-tested in isolation; it is a
            pre-existing, already-exercised predicate (coherence's HEAD half has routed through
            it via `cohGoR`'s `TCon` arm since A-2.10).

### 3.7-4 — A-3.7 — 🚨 THE ACCEPTANCE WIDENING: `CohImpl` carries `IfaceRef`, compared by identity
sites:      `compiler/types/typecheck.mdk`, six sites, all in the `coh*` block:
            `CohImpl`'s declaration (1st field `String` → `IfaceRef`, + a `#1559` header note);
            `cohImplsOfMid` (builds the `IfaceRef` from `implOrigin`, destructured in the SAME
            record pattern as `iface` — the OCCURRENCE MINT discipline, identical to the
            expression `implDeclFact` uses); `cohScanInner` (`if1 == if2` → `cohSameIface if1
            if2`); `cohImplIface` (return type → `IfaceRef`) plus a new `cohImplIfaceName`
            projection; `cohHardMsg` ×2 and `cohClassify` ×1 now read `cohImplIfaceName`.
            The 33 `coh*` judgment functions are UNTOUCHED and no diagnostic wording moved —
            `cohOverlapMsg` / `cohIncomparableMsg` / `cohCrossModuleMsg` keep their `String`
            parameter, which is why `cohImplIfaceName` exists rather than `.irName` inline.
            **Landed ALONE, with its own build + `check-self` checkpoint**, per RUN-021.
transform:  the interface half of coherence's key stops being a bare spelling and becomes an
            identity compared with `sameTyConHead`.
could move: **YES — a DELIBERATE acceptance WIDENING, and it is this unit's headline.**
            * Two same-spelled but DISTINCT interfaces impl'd at a shared head are no longer a
              conflict. MEASURED, on the pin: `check main.mdk` **exit 1 → exit 0**.
            * The widening is confined to CROSS-MODULE pairs, and that is DERIVED, not argued:
              a single module cannot declare two interfaces of one name — `Duplicate interface:
              Same`, exit 1, measured first-hand on a single-file probe, and it is a
              resolve-side `DuplicateDefinition`. So no single-file program's acceptance moves.
            * Fail-capability CHECKED rather than assumed — a widening that turned the check off
              entirely would produce the same green on the pin. A GENUINE cross-module conflict
              (one interface declared once in `imod`, impl'd at `Int` by two importers) still
              rejects at exit 1 with byte-identical wording: `Conflicting ...impl One...
              Defined in amod and zmod`.
            * The five HARD-arm coverage fixtures P0-D listed as OWED were `ls`-verified AND
              run; all five behave as before: `typecheck_error_fixtures/dup_impl.mdk` exit 1,
              `overlapping_impls.mdk` exit 1, `dict_fixtures/s6-c1-duplicate-heads-rejected.mdk`
              exit 1, `check_json_fixtures/conflicting_impl_duplicate.mdk` exit 1, all with
              unchanged `Overlapping impls of …` wording; and
              `lint_fixtures/derivable_needs_datadecl.mdk` exit 0.
            * BASELINE HELD: a user `impl Eq Int` α-equal to the prelude's is **exit 0 on Flat
              AND on the Module path**, before and after (measured both times).
            * Direction check against ratified decisions: most-specific-wins is untouched
              (`cohClassify`'s first two guards), F-3d's (a)=warning ruling is untouched (the
              hard/soft split is untouched), and this MINTS no identity — it CONSUMES
              `implOrigin`, which resolve stamps.
            * P0-D's OWED "does any Flat path stamp `implOrigin`" is DISCHARGED, and the answer
              is YES-but-inert: `checkProgramSeededSplit` calls `stampFlatTyOrigins` on both the
              prelude and the user program. Its scope (`flatTyOriginScope coreDecls`) covers
              builtins and the PRELUDE's types/interfaces only — deliberately no `prog` term —
              so a flat program's OWN interface stays `OriginUnresolved` and a prelude interface
              is `mod:core`. Either way both sides of any flat pair carry the SAME origin, and
              `sameTyConHead` degenerates to today's name equality. Flat is behaviourally inert.
unchecked:  * **No goldens, snapshots or LEG A schemes were re-cut or inspected** (§5: bless
              zero). `CohImpl`'s constructor arity is unchanged but its 1st field's TYPE moved,
              and `cohImplIface`'s scheme moved (`-> String` → `-> IfaceRef`), so the selfproc
              LEG A `types.typecheck` golden WILL move, and `cohImplIfaceName`/`cohSameIface`
              are NEW bindings in it. Expected LEG A delta from bites 3.7-3+3.7-4: 2 additions
              (`cohSameIface`, `cohImplIfaceName`) and 1 re-type (`cohImplIface`). Any OTHER
              surviving binding whose scheme moved is a real finding this bite does not excuse.
            * The `run` and `build` engines were not re-measured after the fix. `run` shared the
              defect before (measured, exit 1, same message); they share the front end, so the
              widening should reach both, but that is an inference, not a measurement.
            * `cohClassify`'s 🚨 CARRY-FORWARD FOR A-3 comment is deliberately LEFT IN PLACE.
              It describes the input WIDENING to the global `IE` (bite 3.7-6), which did NOT
              land — see 3.7-STOPPED. Discharging it belongs to whoever lands 3.7-6.
            * No permutation differential was run. P0-D specifies one for 3.7-8 (scan order);
              this bite changes no order, but the two same-spelled interfaces' relative position
              in the scan was not varied.

### 3.7-STOPPED — A-3.7 — bites 3.7-1/2/5/6/7/8/9/10 NOT landed; region contention + a dead-code bar
sites:      none — no edit made.
transform:  none.
could move: **nothing, because nothing was written.** Recorded so the unit's residue is not
            mistaken for completeness: A-3.7 shipped its pin (3.7-0), its predicate (3.7-3) and
            its acceptance change (3.7-4). The IE INPUT RELOCATION did not ship. Coherence still
            reads `cohCollectImpls` / `cohCollectModuleImpls` over decl lists.
            Reasons, per bite:
            * **3.7-2 was already done by Lane B.** `flatImplEnvOf : List Decl -> ImplEnv =
              buildImplEnv [declEnvModule 0 "" decls]` exists beside `flatClassEnvOf`, with
              A-3.5b's own header. Duplicating it was declined; the sub-orchestrator should
              re-attribute the bite rather than expect it in A-3.7's diff.
            * **3.7-7 sits inside a region another lane had ALREADY re-signatured, uncommitted.**
              Lane B changed `runFinalChecks`' arity and all three of its call sites while I was
              live. §4's STOP-and-report rule applies: I did not adapt on top of a half-applied
              edit. 3.7-5/3.7-6 exist only to feed 3.7-7, and 3.7-9 deletes the fallback 3.7-7
              replaces, so the whole tail serialises behind it.
            * **3.7-1/3.7-5/3.7-6 were declined as READERLESS ADDITIONS.** Landing them without
              3.7-7 puts unreachable helpers in the tree — the shape RUN-031 refused F-3 for,
              and a `rule-dead-code` risk besides.
            * **3.7-10 (ledger updates) is premature.** Its edits assert relocations that did
              not happen. The ONE claim it could have landed honestly — the ratchet's `deImpls`
              row *"`ieInst` is read by no judgment"* — is STILL TRUE, because `instRefMid`
              acquires its first judgment reader in 3.7-5, which did not land.
            ⚠️ **3.7-5's `cohSoftInScope` hazard is therefore STILL ARMED and still owed.**
              `cohSoftInScope "" "" = True` is untouched, which is correct while every
              per-module mid is still `""`. The moment 3.7-5 lands and Module-arm rows carry
              real mids, every intra-module `W-INCOMPARABLE-IMPLS` is silently dropped. That is
              diagnostic-only and invisible to every value golden. Re-cut it sweep-scoped.
unchecked:  A-3.6 was concurrently editing the IE block (`ieSnapAt`, `declEnvVisibleAt`, the IE
            doctests) throughout. 3.7-1's accessors would have landed in that exact region.
            Their eventual implementer must re-derive `ieRowsAll`/`ieRowsOwnedBy` against
            whatever A-3.6 leaves, and must write `ieRowOrd r == cur` — NOT `declEnvVisibleAt
            cur (ieRowOrd r)`, which is the prefix, a different set, and would give A-3.6's
            predicate another reader.
            🚩 **CONFIRMED UNCHANGED, per RUN-021's warning not to chase it:** `sh
            test/registry_keying_ratchet.sh` → PASS. A-3.7 shrinks `driver_allowed` by ZERO
            rows and `coherenceUserDecls` does not retire. Nothing in this unit's diff was
            expected to move that signal and nothing did.

### C-1 — A-3.6 — the seed chain's own-row exclusion, asserted as fail-capable doctests
sites:      `compiler/types/typecheck.mdk` — 4 doctests + 2 fixtures (`deSeedRowN`,
            `deSeedChainProbe`) added after `deKindRow1`; a ~40-line header stating the
            fail-capability argument. No code path changed.
transform:  `declEnvSeedChain` stamps row k's id with the accumulators as they stand BEFORE
            k is folded in, so k's seed excludes k. That was asserted only in prose. Now a
            TWO-row chain (`deKindRow0` id "m" ord 0, `deSeedRowN` id "n" ord 1, same decls)
            pins: seed("m") = 0 kinds / no owners; seed("n") = 3 kinds / `["Pt"]` — one "Pt",
            not two. Two rows with distinct ids is required: a one-row chain cannot
            discriminate, since prefix and final accumulator coincide at the only row.
could move: **Nothing — additive doctests over existing fixtures, zero production code
            touched.** `deSeedRowN`/`deSeedChainProbe` are new top-level bindings, so the
            selfproc LEG A golden gains two ADDITIONS (expected debt, do not bless).
            The doctests themselves are new assertions and can only fail on a genuine break.
unchecked:  Nothing material. **Fail-capability was MEASURED, not argued**: `declEnvSeedChain`
            was temporarily edited to stamp the POST-fold accumulators (the own-row-inclusive
            shape the ratchet's *"hand every row the FINAL accumulator"* instruction produces),
            and `medaka test compiler/types/typecheck.mdk` went 52/52 → 48/52 with **exactly
            these four lines failing and no others**. That second half is the load-bearing
            part: it shows C-1 added coverage that did not already exist anywhere in the file,
            rather than duplicating an existing assertion. The edit was reverted and 52/52
            restored (verified by re-run, not by assumption).

### C-2 — A-3.6 — NOT PERFORMED. Dissolved by RUN-010; performing it was the ruled-out option
sites:      none.
transform:  none. P0-C §4 cut C-2 as "`declEnvSeedChain`: whole graph MINUS own row", gated on
            ruling (A). RUN-010 is ruling (B) — SPLIT — and P0-C's own text says "under ruling
            (B) this bite does not exist". The seeds feed `dataParamKindsRef` and
            `fieldOwnersRef`, both NAME-scoping, which RUN-010 leaves on the ordinal filter.
            Doing it anyway would have widened the field-owner population — the acceptance
            NARROWING (`typecheck.mdk`'s MEASURED `T-AMBIGUOUS-FIELD` paragraph) that the owner
            ruling was taken specifically to avoid.
could move: **Nothing — no edit made.** Recorded as a row rather than omitted because a
            silently-skipped bite and a deliberately-declined one are indistinguishable from
            the diff, and the testing round needs to know this was a decision.
unchecked:  n/a.

### C-3 — A-3.6 — the candidacy flip: `ieCandidacyVisibleAt`, instance axis only
sites:      `compiler/types/typecheck.mdk` — new `ieCandidacyVisibleAt : Int -> Int -> Bool`
            (`_ _ = True`) beside `declEnvVisibleAt`; `ieSnapAt`'s guard re-pointed to it;
            the IE §9.7 doctest items 3 and 4 re-cut (2 expected values moved 0 → 1, one
            now-vacuous duplicate line deleted); surrounding headers re-cut.
transform:  `declEnvVisibleAt` KEEPS its ordinal body. Only the instance-candidacy read moves,
            so `ieUniverseAt`/`ieSnapAt` now select the FINAL snapshot — the whole graph —
            which is C4/I2. Parameters kept on both predicates so no call site moves.
            Reachability discharged per RUN-031: `ieUniverseAt` has exactly ONE production
            caller, `moduleImplUniv` in `checkBodyImpl`'s Module arm, feeding both the
            end-of-body obligation universe and #1549's `residualUnivRef`. Not dead code.
could move: **Per reader — the 8-path checklist, re-derived by grep at edit time, plus a 9th
            that did not exist when RUN-013 enumerated them:**
            1. `ieSnapAt` → `checkBodyImpl` — **FLIPPED.** Everything below is downstream.
            2. `ceLookupAt` ← `checkGradedImplTys` — unchanged: still reads
               `declEnvVisibleAt`, whose body I did not touch. No edit in its call chain.
            3. `ceLookupAt` ← `ifaceDfsCycleOneSuper` — same, same reason.
            4. `ceRowsVisibleAt` ← `checkInterfaceCycles` — same. (The duplicated-cycle-report
               risk P0-C §2.5 raised does NOT arise: it was a consequence of widening CE,
               which did not happen.)
            5. `declEnvRowVisible` ← `overlayScanRows` — unchanged; reads
               `declEnvVisibleTo` → `declEnvVisibleAt`, both bodies intact.
            6. `declEnvRowVisible` ← `declEnvSeedChain` — unchanged; C-2 not performed.
            7. `declEnvRowKindEntries` ← `declEnvSeedChain` — unchanged; C-2 not performed.
            8. `aliasVisibleTo` ← `loadDataUniverse` — unchanged. Its own-row exclusion
               (`adOrd != cur`) and attributed-alias drop (`not adAttrib`) are separate `&&`
               terms and were not touched.
            For 2–8 the argument is uniform and mechanical: each reaches the ordinal test
            ONLY through `declEnvVisibleAt`, and `declEnvVisibleAt`'s body is byte-identical
            to its pre-bite form (`grep 'entryOrd <= cur'` still matches it). No reader was
            re-pointed except `ieSnapAt`.
            9. 🚩 **`ieRowsVisibleAt` — a NINTH path, added by Lane B (A-3.5b) DURING this
               unit and absent from RUN-013's enumeration.** It is an `IE` reader, so it is on
               the instance axis by table, but it answers a DECL-TIME EXISTENCE question for
               `checkSuperImpls`, not a candidacy question. **Left on `declEnvVisibleAt`** —
               RUN-010's licence is I5's subject, `match(IE, C τ̄)`, and that is not this.
               ⚠️ **Whether super-existence should also see the whole graph is UNRULED and
               nobody owns it.** It is now the only `IE` read that is ordinal-scoped, which is
               a genuine asymmetry a reader will trip over.
            **What actually moves, measured, not predicted:**
            * `must_fail_fixtures/1564-import-order-decides-conditional-impl-candidacy`
              **DRAINED** — attributed to this bite by single-variable revert (see unchecked).
            * `must_fail_fixtures/1438-same-spelled-interfaces-collapse-in-coherence`
              **DRAINED** — NOT attributed; see unchecked.
            * `1072-overlap-xmod-bare-head-arm-order` **still REPROs**, and RUN-006's premise
              that it must flip is **mechanistically wrong**: its claim names `KeyBuckets` /
              `implEntryRouteWords` (`llvm_emit.mdk`), and `buildKeyTable : List Decl ->
              KeyBuckets` is built from a decl list on the emitter path — a different
              substrate from `IE`. A-3.6's flip cannot reach it. It was REPRO at RUN-033's
              quiescent baseline and is REPRO now: unchanged, not worsened.
            * Diagnostic-only changes invisible to every value golden: new/removed
              exhaustiveness warnings via the overlay pool's downstream `seedCheckRun`, and
              I5 classes (2) and (4) — new C1 ambiguity rejections, and rejections via an
              unsatisfiable context from an interface the author never imported. **Both
              unpinned in both directions.**
            * `declEnvsOrdOf`'s `-1` fail-CLOSED sentinel is now **VACUOUS on this path** — an
              unknown module id gains the whole graph instead of losing everything. It remains
              live and fail-closed for the name axis. Commented at both sites, not tidied away.
            * 🚨 **THE BIG ONE — THE WIDENING IS HALF LANDED AND THE SECOND HALF IS UNOWNED.**
              On #1564's `main.mdk`, measured on the trunk binary:
              `check` → **exit 0** (the R2 widening, correct); `run` → **exit 1, E-PANIC
              "putStrLn: not a String"**; `build` → exit 0 and the binary **SEGFAULTS (139)**.
              `control.mdk` is clean on all three (`wrap(int)`, exit 0). So typecheck's
              CANDIDACY went graph-global while the EVIDENCE PLUMBING — dict construction and
              route stamping for a site whose own module cannot name the impl — did not.
              `nest` is generalized against an obligation discharged by an impl no dict
              reaches. **Neither engine is silently wrong (eval panics, native faults, both
              LOUD), so this is not S0** — but a compile-time diagnostic became a segfault,
              and that is this bite's. It does not violate the loud→quiet rule; it does mean
              **A-3.6 alone does not deliver a working program for the shape it now accepts.**
              The correct end state is `main.mdk` behaving like `control.mdk`. This is in no
              unit's bite list and is not A-3.7's (coherence). **Escalated, not absorbed.**
unchecked:  🚨 **THE MUST-FAIL RUN WAS CONTAMINATED and must be re-derived on a quiescent
            tree before anyone acts on the two drains — this is RUN-033's rule, exactly.**
            Lane B held uncommitted edits to `typecheck.mdk` (`checkSuperImpls`,
            `implMatchesSuper`, `ieRowsVisibleAt`) throughout; a third agent also modified the
            file mid-session (several Edits reported "modified on disk since you last read
            it"). Reading: `checked 99 fixtures: 97 reproduce, 2 DRAINED, 0 control-broke, 0
            malformed`. Note the corpus is **99, not RUN-033's 98** — a fixture was added by
            another lane during the run, so even the denominator is not the baseline's.
            * **#1564's drain IS attributed to me and is NOT contaminated**, because it was
              established by a single-variable revert rather than by the gate: `ieSnapAt`'s
              guard was pointed back at `declEnvVisibleAt`, the compiler rebuilt, and `check
              main.mdk` returned to **exit 1 with the identical original diagnostic**;
              restoring `ieCandidacyVisibleAt` returned it to exit 0. Nothing else changed
              between the two builds.
            * **#1438's drain is NOT attributed.** I did not revert-test it and its mechanism
              (coherence) is not obviously reachable from candidacy. RUN-021 verified that
              fixture did not exist; it now does, so another lane authored it during this run.
              ⚠️ **A newly-authored pin that reads DRAINED on its first run is either a real
              early drain or a probe that never reproduced** — RUN-025's hazard. Its author
              owes the discrimination; I am not it.
            * ⚠️ **DO NOT CLOSE #1564 ON ITS DRAIN.** That row's `cmd:` is `check-json
              main.mdk` / `exit: 1`, so it grades the CHECK arm ALONE. The run and build arms
              were never pinned there and the harness is structurally blind to them — which is
              why it reports a clean drain for what is measurably half a drain (see the 🚨
              above). This is the "partial identity reads as done from any single table" shape.
            NOT run, per §5: snapshot, selfproc LEG A, engines, perf_scaling, the differential
            gates. **Zero goldens blessed.** Snapshot and LEG A are expected red.
            **Perf:** no fold was introduced at any read site. `ieSnapAt` still SELECTS and
            still allocates nothing; its walk was deliberately NOT "simplified" to `last`
            despite the predicate now being constant, so the diff is one predicate name.
            Not measured — `perf_scaling` is deferred — but the shape that has twice gone
            quadratic here is structurally absent.

### C-4 — A-3.6 — NOT PERFORMED (out of brief)
sites:      none.
transform:  none. The permutation differential needs a new `test/*.sh`, which needs a shard
            pattern in `.github/workflows/ci.yml` or `diff_compiler_ci_shard_coverage.sh` reds
            the merge queue. Explicitly excluded from this implementer's brief.
could move: **Nothing — no edit made.** ⚠️ But its ABSENCE is load-bearing debt: it is the one
            instrument that can see I5 class (3) — a silent answer change — without knowing
            the right answer in advance, and class (3) is precisely what this run's deferred
            posture cannot see. C-3's re-cut IE doctest item 3 is a weak in-source substitute:
            it asserts the selected universe is INVARIANT in the reading ordinal, which is the
            same property the permutation differential would test, but over one hand-built
            two-module `ImplEnv` rather than over a real fixture corpus under permuted loader
            order.
unchecked:  n/a.

### C-5 — A-3.6 — the comment re-cut: A-3.6 stops being future tense, and one instruction is retracted
sites:      `compiler/types/typecheck.mdk` — 14 comment regions (anchored on strings, not line
            numbers; the set was re-derived with `grep -n 'A-3\.6'` at edit time, since A-3.5a
            had moved every line number in P0-C's list).
            `test/registry_keying_ratchet.sh` — 7 substitutions across the `declEnvsRef`,
            `deKindsBefore` and `demKindEntries` rows.
            `compiler/TYPECHECK-TARGET-ARCHITECTURE.md` — §9.2 consequence paragraph and §9.8
            exit criterion 1.
transform:  Every "A-3.6 deletes this body" / "A-3.6 keeps its one-body deletion" / "A-3.6
            still has a single body to delete" claim was re-cut to state what actually
            happened: the predicate SPLIT, the instance axis flipped, the name axis did not.
            Each retraction QUOTES the sentence it replaces rather than silently overwriting
            it, so a reader who remembers the old claim can see it was retired deliberately.
            🚨 **The highest-value edit is the retraction of a LIVE REGRESSION INSTRUCTION.**
            `typecheck.mdk`'s `declEnvSeedChain` header and the ratchet's `deKindsBefore` row
            both told A-3.6 to *"hand every row the FINAL accumulator"*. That destroys the
            own-row exclusion the SAME rows call structural two sentences earlier (RUN-009).
            Both now carry an explicit **DO NOT DO THIS**, both give the mechanism (doubled
            owner key → `mangledHeadCandidates` reads the multimap RAW → singleton gate
            becomes the give-up arm, live during inference), and both point at C-1's
            `deSeedChainProbe` doctests as the tripwire.
            PRESERVED as required: `declEnvVisibleTo`'s two separable conjuncts and the
            publicity conjunct's migration to R; `aliasVisibleTo`'s conditions 2 and 3; the
            zero-allocation contracts; the `-1` sentinel's NEW (vacuous-on-candidacy,
            live-on-names) meaning.
could move: **Nothing in behaviour — comments only, in `.mdk`, `.sh` and `.md`.** The `.mdk`
            comment diff moves the **snapshot** golden (`test/snapshots/compiler/typecheck.md`)
            and, because C-1 and C-3 add bindings, the **selfproc LEG A** golden. Both are
            expected red for the run; **zero blessed**.
            ⚠️ One real risk worth naming: a comment can only be verified by reading it, and I
            re-cut 14 regions of prose asserting things about code I did not run. Each claim is
            grounded in the same greps recorded under C-3's `could move:`, but this is the
            unit's largest surface of unverifiable-by-gate assertion — which is what #1574 is
            about, and this file is where #1574's fabrications happened.
unchecked:  `sh test/registry_keying_ratchet.sh` → PASS after the ratchet edits (its rows are
            prose fields inside a checked structure, so a malformed edit would have failed it).
            `make docs-links` → PASS. `make agent-doc-symbols` → **FAIL, 1 dead symbol:
            `universeIfaceRequiredRef` at `docs/spec/DICT-SEMANTICS.md:2517`. NOT MINE** — that
            symbol was retired by Lane A (A-3.5a) and the doc was not re-cut with it. I did not
            touch `DICT-SEMANTICS.md`. Owed to Lane A or the ledger-repair pass.
            `#829` respected: no interior record comment was added to any record; the two
            records in this region (`DeclEnvModule`, `DeclEnvs`) already carry their
            deliberate load-bearing interior comments and were not touched.
            `medaka fmt --write` → "already formatted"; `medaka lint` → rc 0 (both re-run after
            the final edit; note `lint | grep` reports grep's status, so rc was read direct).

### R2 fixture — A-3.6 — the could-not-pass-before fixture RUN-006 requires
sites:      `test/r2_widening_fixtures/1558-a36-candidacy-graph-global/` — 5 `.mdk` files
            (copied from #1564's verified-discriminating corpus) + `claim.txt`.
transform:  Authored, NOT wired and NOT run as a gate — which is what RUN-006 asks for
            ("even if it is only executed in the testing round"). `claim.txt` records the
            measured before/after (`check main.mdk`: exit 1 with `T-NO-IMPL` → exit 0), the
            control (`control.mdk`, two import lines swapped, clean both sides), the
            single-variable revert that attributes it to A-3.6, and the 🚨 block recording
            that `run` panics and `build` segfaults so the fixture cannot be read as proof the
            widening is complete.
could move: **Nothing.** Verified inert before leaving it: `grep -ln 'r2_widening_fixtures'
            test/*.sh` → no hits, and `diff_compiler_snapshot_frontend.sh` enumerates its
            corpus directories by NAME (`parse_fixtures`, `parse_only_fixtures`,
            `comment_fixtures`, `positions_fixtures`, `diff_fixtures`) rather than walking
            `test/`, so a new directory cannot silently enroll. That check was done because
            adding a fixture directory is the shared-corpus trap.
unchecked:  ⚠️ **It has ZERO consumers, which is the `deFieldOwnerIdents` anti-pattern** — a
            table that is built, documented and read by nothing. Accepted deliberately here
            because RUN-006 mandates authoring it and wiring it requires the new `test/*.sh` +
            CI shard pattern that C-4 was dropped for. `claim.txt` states this as OWED item 1
            rather than leaving it to be discovered. If the testing round decides an inert
            directory is worse than none, deleting it costs nothing — but the measured
            before/after and the attribution method should be preserved somewhere.
