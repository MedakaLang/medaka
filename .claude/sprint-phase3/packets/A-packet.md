# Packet `B-2.2-a` — the shared route-word mint

**Bite:** create `compiler/types/route_key.mdk` — one new module, one mint, **zero call sites**.
**Branch:** `arch/stage-b-phase3-b22`. **Base commit for this bite:** `5d3c49f1`.
**Worktree (absolute, always):** `/root/medaka/.claude/worktrees/expressive-prancing-minsky`

---

## 0. Concurrency, stated honestly

**You are the ONLY writer live.** No other agent is editing this tree. The tree is quiescent, the
binary at `<worktree>/medaka` was built from unmodified source at this commit, and `git diff` is
empty. If you find the tree has moved under you, **STOP and report** — do not adapt.

## 1. What you are building, and why it is not what the design doc says

The design of record (`.claude/sprint-b/design/D1-phase3-routes.md`, section `B-2.2-a`) says to
change `RKey`'s field type to a two-component carrier. **That was refused in Phase 0 after a
consumer-side derivation; do not implement it.** The full ruling is `DECISIONS.md` RUN-P3-019. The
one-line version:

> `Route` crosses out of `types/` into `ir/`, `backend/` and `eval/`, where the only namespaces that
> exist are `String` symbol names and `hashName`'d i64 dict words. **All 15 reading sites need the
> word; none can consume an identity.** So the identity belongs *in the word* (content-derived),
> and `a` is the shared mint that makes the caller side and the definition side produce that word
> **by construction** instead of by two mirrored implementations agreeing.

**`data Route` in `compiler/frontend/ast.mdk` is UNCHANGED. Do not touch it.**

## 2. Already settled — do NOT re-derive (each was derived or measured this session)

1. `ast.mdk` imports nothing (`grep -Hn '^import' compiler/frontend/ast.mdk` → zero hits).
2. `eval.mdk` and `core_ir_lower.mdk` **cannot** import `types.typecheck`. That is why the mint gets
   its own module rather than living in `typecheck.mdk` — siting it there would make it a **third**
   mirrored copy beside `implKeyTc` and `implKeyOf`, which is the P0-9 shape `B-2.2-e` exists to
   delete.
3. `compiler/support/util.mdk` is a **rejected** home: `test/preflight.sh` maps `compiler/support/*`
   to `mark_full`, i.e. the whole ~103-gate suite on every touch.
4. `compiler/frontend/ast.mdk` is a **rejected** home: the mint needs `joinWith` from
   `support/util.mdk`, which would give the zero-import base module its first import.
5. **No cycle:** `frontend/ast.mdk` imports nothing; `support/util.mdk` imports only
   `support.ordmap`, `support.opcount`, `list`, `string` — not `frontend.ast`. `types.route_key`
   sits strictly below `eval`, `typecheck` and `core_ir_lower`.
6. Precedent for a new module with exactly this import shape: `compiler/types/registry.mdk`.
7. `data CSlot` is single-line, and `data CProgram` is the two-line form — neither is yours, but see
   §6 on `fmt`.

## 3. The shape to write

Names are **given** — use them verbatim; each greps uniquely today.

```medaka
export ifaceWordOf      : TyConOrigin -> String -> String
export implRouteKeyWord : TyConOrigin -> String -> List Ty -> Option String -> String
export routeWordFor     : Bool -> String -> TyConOrigin -> String -> List Ty -> String
rkTy : Ty -> String        -- private
rkTyAtom : Ty -> String    -- private
rkTyFunArg : Ty -> String  -- private
```

- `implRouteKeyWord o iface tys nm` = `"\{ifaceWordOf o iface}|\{joinWith " " (map rkTyAtom tys)}|\{fromOption "" nm}"`
  — **byte-identical to today's `implKeyTc`/`implKeyOf` whenever the origin is absent**, and
  carrying `module::Iface` in place of the bare name when it is not. It is *available* here but
  **not yet applied anywhere**, because you wire up no callers.
  🚨 **CORRECTED AFTER ISSUE (referee R-2, adjudicated twice).** This line originally read *"that
  substitution is **#1182's** fix"*, and the `a` implementer copied that sentence verbatim into
  `route_key.mdk` — **this packet is the origin of a nine-instance propagation.** It is **wrong**.
  #1182 is two interfaces sharing a **METHOD** name; selection runs through
  `ieEntriesForMethod`'s `contains name ms` filter — method-name membership plus a head match, **no
  interface component** — and the word is minted *downstream of the already-selected row*, so no
  word substitution can reach it. In #1182's own single-file repro the word does not even **move**
  (`ifaceIdentity` answers `""`, the fallback returns the bare name). What the substitution fixes is
  the **same-SPELLED-interface** family: #1047 (**CLOSED**) and its open successor **#1265**, whose
  title records that *"#1264 fixed only the interface-name half of #1047"* — the tables were
  qualified, the route word was not. **The citable ticket is `#1113`**, the arc issue this sprint
  runs under.
- `routeWordFor headIsUnique tag o iface tys` = `if headIsUnique then tag else implRouteKeyWord o iface tys None`
  — this is `core_ir_lower.declRouteKey`'s body and `keyForSite`'s
  `if ieHeadCollidesBy* … then implKeyTc … else headKeyNameOr …`, unified.
- `rkTy`/`rkTyAtom`/`rkTyFunArg`: **one** prec-2 `Ty` printer, replacing the mirrored `ppTyAtom`
  (`typecheck.mdk`) and `ppTyAtomK` (`eval.mdk`). ⚠️ **Write it; do not delete the two originals** —
  collapsing the callers is `B-2.2-e`'s bite, not yours, and those two **already differ** off the
  reachable subset (typecheck renders `TyEffect`/`TyRow` as `<…>` and `TyConstrained` as `cs => t`;
  eval strips all three). **Base `rkTy` on typecheck's `ppTyAtom`, the more complete of the two, and
  record the divergence in your `unchecked:` row** — `e` owes a discriminating probe before it
  collapses the callers.

### 🚨 The one thing most likely to be got wrong

```medaka
ifaceWordOf o name = match ifaceIdentity o name
  "" => name
  ident => ident
```

**`ifaceIdentity` returns `""` on the loader-less path, and the tree states `""` IS ABSENCE, NOT AN
IDENTITY** (`ast.mdk:113-124`; `ifaceIdMatches` is the only legal comparison and absence never
matches even itself — I verified this first-hand). The flat drivers deliberately stamp no origin, so
a word built from a **raw** `ifaceIdentity` would spell `"|T|"` for **every** interface on
`medaka check <single file>`, lsp, repl, doc, lint and snapshot — **collapsing instances the present
bare-name word keeps apart.** Hence the fallback.

**Assert, do not assume, the property the fallback rests on:** it is safe only because two
same-spelled interfaces cannot both have absent origins *and* be in scope together — the flat path
is one module and therefore one namespace; cross-module, origins are stamped. **Write that sentence
at the fallback.** It is precisely where a silent collapse would live, and a later reader deleting
the fallback as redundant is the failure mode.

## 4. Your deliverable

The new file, **plus** a `DEBT.md` row (append to `.claude/sprint-phase3/DEBT.md`) in this exact
shape. **`could move:` and `nearest miss:` may not be blank** — *"nothing, and here is why"* is
valid, silence is not:

```
### B-2.2-a — the shared route-word mint
sites:        <files:lines actually touched>
transform:    <what was applied>
could move:   <what acceptance behaviour could plausibly have changed>
nearest miss: <the nearest program this does NOT cover, and what it does today>
engines:      <LLVM / wasm / eval / core_ir_eval — which arms moved, which peers are owed>
unchecked:    <what you did not verify, and why>
```

`engines:` may be **one line** if no compiled byte reaches an engine — say so and say why.
Do **not** write `DECISIONS.md`; the orchestrator owns it.

## 5. Verify — and gate your own work

```sh
make -C /root/medaka/.claude/worktrees/expressive-prancing-minsky medaka
make -C /root/medaka/.claude/worktrees/expressive-prancing-minsky check-self
```

`check-self` is ~20 s and is the right first-line check. **Run them yourself** — the orchestrator
verifies your *evidence*, not by re-running your build.

🚨 **BLESS ZERO GOLDENS. Run no gate that captures.** Snapshot / `selfproc_legA` /
`llvm_typed_ir` / must-fail are **expected-red for the whole sprint by design** (see
`.claude/HANDOFF.md`); they are re-cut **once**, from the final binary, at the close-out. If you
think a golden needs blessing, you have found something — report it, do not bless it.

**Expected of this bite specifically: it is INERT.** No call sites, so `check-self` and the build
must be unaffected and no golden should move. **If a golden moves, stop and report** — that
would mean the module is not as inert as this packet claims.

## 6. Traps that apply to you

- **`medaka fmt --write` and `medaka lint` on the file you add, before `make`** — cheap checks
  first. The pre-commit hook gates on both. A bare `medaka fmt <file>` is READ-ONLY; `--write` is
  the only mutating mode.
- ⚠️ **The lint ratchet is at 0 findings and gates ~20 rules**, including a cross-file
  `rule-duplicate-body` run over the whole project (`medaka lint compiler stdlib sqlite`). Your
  module is **imported by nobody** — if that trips a dead-code or duplicate-body finding, **report
  it rather than adding a `lint-disable`**; the right resolution may be to land `a` together with
  `e`, which is the orchestrator's call, not yours.
- **`main` must be a zero-arg value** in any probe you write (`main = println …`); `main () = …` is
  a silent no-op at exit 0.
- **Exit codes do not survive a pipe.** Redirect to a file and read `$?`.
- **Do not name any probe method after a prelude method** (`add`/`sub`/`mul`/`div`/`negate`/`abs`/
  `signum`/`fromInt`) — measured this session, a user interface method named `sub` makes the built
  binary print a leaked pointer at exit 0, and you would be measuring that instead of your change.
- **Absolute paths everywhere.** The shell cwd resets between calls; a relative path edits the main
  checkout, which this build never sees.

## 7. Refuse, explicitly

**Report disagreements rather than silently resolving them.** If the shape in §3 does not typecheck,
if a name collides, if the module cannot sit where §2 says, or if you conclude this bite is wrong —
**STOP and report with your derivation.** In the two prior sprints the highest-value agent behaviour
was refusal: three bites were refused and **every refusal caught a defect in the orchestrator's
scoping**, two of which would have shipped as S0s behind a green `check`. **Stopping with a written
finding is worth more than a green gate.** A refused bite is landed work.

## 8. Closing section, mandatory

End your report with **TIME ACCOUNTING**: split (orientation · derivation · edits · build/gate ·
report) · biggest sink · **what did you have to DERIVE that this packet could have handed you?** ·
what of this packet was wasted on you · build cycles and which were avoidable.

**Reading and thinking are PRODUCTIVE, not overhead** — only build churn and report-writing count as
overhead. Your derivation time is a readout of **this packet's quality**, not of your speed.
