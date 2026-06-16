# Next-orchestrator handoff — Medaka, soak tail (2026-06-15)

You are the **orchestrator** for Medaka, a self-hosting functional language whose native
LLVM backend is now CANONICAL (compiles itself + all user code OCaml-free). You design and
delegate work to subagents, verify their output against gates, and keep `main` + docs
coherent. You usually do NOT implement directly. **Read `.claude/ORCHESTRATING.md` first**
(the orchestrator playbook — core loop, agent-prompt skeleton, verification discipline,
footguns) and `AGENTS.md` (the agent-facing router/map).

## RESUME — session 2026-06-15 PM (ended at usage max). local `main` = 5423214
Soak bug-hunt session. Worktrees/branches were pruned to 4 (housekeeping). THREE soak fixes found+fixed+MERGED+verified (fixpoint C3a/C3b YES each):
- **Native-emit scale failure** (`unbound 'not'`, ~5% build rate): post-mangle synthesized-prelude-ref reconciliation in `selfhost/ir/dce.mdk` + `selfhost/backend/llvm_emit.mdk`. Fuzzer now 900/900 clean (`test/fuzz_diff.sh` TIER=1 native).
- **Whole-float rendering → canonical `1.0`** (was `1.`): `runtime/medaka_rt.c` (×2) + `lib/eval.ml` (×2, deliberate oracle edit) + `dev/astdump.ml`/`lib/ast.ml` cosmetic; 14 goldens re-captured. nan/inf now bare. Decided change — memory `project_float_tostring_trailing_dot` (RESOLVED).
- **foldMap method-level-constraint gap CLOSED** (eval_dict 25/0, batch 25/0): `crossModuleMethodConstraintsRef` accumulator + register method dict slots after body inference in `selfhost/types/typecheck.mdk`. `diff_selfhost_eval_dict` now **25 ok / 0 failing** — the 3-failing / 18-batch baseline is gone.

**Capability-effects research pass DONE:** `CAPABILITY-EFFECTS-RESEARCH.md` committed to main. Recommendation: dual-layer manifest (TOML `[package.capabilities]` now + WIT world later); target Spin/Fermyon first; 5 forks identified (extern-namespace sealing on native is the sharp one).

**BOOKKEEPING CLEARED THIS CHECKPOINT:** EMITTER-GAPS.md entry for scale-bug added; PLAN.md / HANDOFF / eval_dict header updated. **Seed RE-MINTED** (commit 8718b05, `bootstrap_from_seed` PASS C3a byte-for-byte) — fresh as of this checkpoint.

**New minor finding (logged, deferred):** `-0.0` literal renders `0.0` interp vs `-0.0` native (sign-of-zero lost in interp) — pre-existing, esoteric, uncovered by gates.

**NEXT direction — CAPABILITY-EFFECTS v2 (language-level, in progress).** The user reprioritized: get the effect-system language features right BEFORE the manifest/platform layer (avoids downstream rewrites). Design LOCKED + committed: `CAPABILITY-EFFECTS-V2-DESIGN.md` (§0 = locked fork decisions, authoritative). Shape: parameterized effects over a general **RefinementDomain** repr (Prefix domain first — trailing-`*`, local known-literal-prefix analysis, widen to ⊤ on dynamic; **set-of-atoms-per-label**, NOT join); **IO decomposition** into narrow labels + `IO` as a widening alias (re-annotate ~21 externs only, cheap migration); **security-vs-internal taxonomy** axis (drives the manifest). Syntax: `effect Net Prefix` / `internal effect Mut`. NON-GOAL: `Throws`/typed-error effects (Result canonical; panic sole uncatchable escape — honors no-catchable-panics). Both typecheckers change in lockstep; every stage fixpoint-gated.
- **Stage 1 DONE + merged** (main 1c22ffd): effect-row `labels:string-list` → `atom-list` over RefinementDomain, in lib/typecheck.ml + selfhost/types/typecheck.mdk. Behavior byte-identical (all params ⊤). Prefix domain arms written but unreachable; Stage 2 adds the analysis + parser with ZERO row-repr changes. Fixpoint C3a/C3b YES, all diff gates green.
- **Stage 2a DONE + merged** (main bff2700 + CLI gate 0ecbc68): Prefix domain algebra (`dsub`/`djoin`/`dmeet`/`drender`), label→domain registry, `prefix_pattern_ok` delimiter validation, parser `effect Net Prefix` / `internal effect Mut` / `<Net "a.com/*">`, subsumption wired into the open/closed row check — both backends. NOTE: a reported "col-17 parse defect" was a PHANTOM (orchestrator's own worktree was stale, behind the grammar-rule commit); no defect existed. Real gap (closed): unit tests parse via raw `Parser.program Lexer.token`, bypassing the indentation lexer the CLI uses → no CLI coverage. Fixed with fixture `test/diff_fixtures/effect_param.mdk` + gate `test/diff_selfhost_effect_param.sh` (4/0).
- **Stage 2b DONE + merged** (main 56e1b13): known-literal-prefix analysis α (§2.4) over desugared core string forms + inferred-hole `<Net _>` surface form, both backends. Leaf extern carries the hole; each call site fills it via `α(first arg)`; concrete `<Net "a.com/*">` annotations are the granted bound checked via `dsub`. Hole encoded non-structurally as `PPrefix (Some "_")` (eff_hole_src sentinel), de-holed to ⊤ before dsub/render. α: literal⇒Known; `++`⇒left prefix; let/EVar/ELet⇒propagate; EIf/EMatch⇒LCP-if-all-Known; EApp/fn-param/field⇒Unknown⇒⊤ (the intraprocedural no-exfiltration guarantee). Gate `test/diff_selfhost_effect_hole.sh` (6/0): admits `a.com/foo`, REJECTS sibling-host + computed-URL through BOTH CLIs. Fixpoint C3a/C3b YES; parse/typecheck/resolve diff gates clean.
- **Stage 3 (NEXT):** IO decomposition — mint narrow labels (Stdout/Stderr/Stdin/FileRead/FileWrite/Env/Exec/Clock/Net/Rand) + classification axis, `IO` as widening union alias, re-annotate the ~21 leaf externs in `stdlib/runtime.mdk` (existing `<IO>` annotations widen, no forced changes), re-capture inferred-row goldens. Then extend `check-policy` + manifest emission to carry per-label params and port `check-policy` to the native CLI (currently OCaml-only, fork i).
Then the manifest/platform layer (the earlier `CAPABILITY-EFFECTS-RESEARCH.md` dual-layer TOML+WIT recommendation, Spin first) sits on top.

**Prior (superseded) NEXT note — manifest-format design — is deferred until the v2 language features land.**

## Where things stand (local `main` = 6dd74dc; nothing pushed — work lives on LOCAL main)
The big multi-session arc is essentially done. Verify current state, don't trust this verbatim:
- `cd /Users/val/medaka && git log --oneline -20 main` (the recent landings).
- In a worktree: `export PATH="$HOME/.opam/5.4.1/bin:$PATH" && export MEDAKA_EMITTER=$PWD/medaka_emitter && make medaka && FORCE=1 bash test/build_oracles.sh && bash test/selfcompile_fixpoint.sh` (should print C3a YES / C3b YES — the decisive emitter gate).

DONE (don't re-do; full record in `PLAN.md` "Current status" + `PLAN-ARCHIVE.md` Stage-3/4 logs):
gate re-rooting (every correctness gate OCaml-free, `selfhost/REROOT-PLAN.md`); the
single-file/multi-module **driver collapse** (`selfhost/DRIVER-COLLAPSE-PLAN.md`, closes audit
§6; `medaka check` resolves imports); native dispatch gaps #55/#54/#50/#21 (the latter genuinely
solved, not contained); the map Foldable false-positive+SIGBUS; native stdlib test expansion;
fuzz_gen ported native; the cross-module **ctor-name collision** emitter fix (universal ctor
mangling); the **`argStampEnabled` eval-vs-emit dispatch unification** COMPLETE (eval now threads
dicts like emit — `selfhost/ARGSTAMP-UNIFY-PLAN.md`); emit-path Set-literal/mutual-rec dict fixes (#44).

DONE this session (2026-06-15) — a style-audit + hygiene arc, all on local main, every merge
fixpoint-gated byte-identical:
- **Style audit** of selfhost: trailing-comma-on-break + width-triggered import wrapping (#18);
  trailing-operator line continuation (both lexers) + Option-B binop width-breaking (both formatters)
  (#19); derive smart-constructors in `desugar.mdk` (#21); cross-module protocol-name constants in
  `support/util` (#22); block-form `data`/`record` + `deriving` parser fix, both parsers (#23).
  New `STYLE.md` (5 hand-source conventions). AGENTS.md: the no-stdlib rule + *why* (instance
  surface / compile-time / isolation — DCE already shakes plain fns; not just binary size).
- **Helper centralization** (#25, `selfhost/HELPER-CENSUS.md` is the audit): the compiler's
  hand-rolled generic helpers consolidated into `support/{util,char,path}.mdk` (2 new themed
  modules); ~23 duplicate clusters collapsed, ~6 O(n²) impls dropped (drifted `joinWith`/`reverseL`/
  `joinNl`/`joinDot`), dedup promoted to OrdMap O(n·log n). typecheck.mdk included. Net ~−365 lines.
- **#24 correctness fix:** match-arm refutable pattern-guard binders (`x if Some v <- e => …`) now
  scope into later guard qualifiers AND the arm body in the native pipeline — was a NATIVE-only
  divergence (`frontend/resolve.mdk` `checkArm` + `types/typecheck.mdk` `inferArms` didn't thread
  the binders; OCaml always did; `medaka run` evaluated correctly, only `check` rejected). Fixed both
  passes; AGENTS.md guard note corrected (the prior "fails in both backends" was wrong).
- Fixed an inherited stale lsp/session golden (the semanticTokensProvider capability) + re-fmt'd the
  import lines the centralization batches left unwrapped.

## The standing goal: the SOAK, then gated `lib/` removal
Native is canonical; OCaml `lib/`+`bin/` is FROZEN in-tree as the differential oracle. **The
user's gate to delete `lib/` (memory `[[retirement-is-not-removal]]`): a clean day-or-two stretch
of native-only dev where we STOP hitting bugs/gaps.** This session (2026-06-15) surfaced+fixed a
real native-only correctness bug (#24 guard-binder scoping), latent helper drift, and an inherited
golden break — so the soak clock **restarts again from this checkpoint**. Do NOT `rm lib/` until the
user explicitly calls the soak. Until then: keep native canonical, fix what real use surfaces,
keep all gates + fixpoint green.

## Open items (all durably documented — verify before acting; docs drift)
- **`lib/` removal** — soak-gated (above). The endgame.
- `eval_dict` 25/0 + batch 25/0 is the current baseline (`diff_selfhost_eval_dict.sh` header updated): foldMap method-level-constraint gap CLOSED 2026-06-15. All 25 fixtures pass.
- Deferred native-test modules: string (2 Unicode case-fold doctests), hash_map/hash_set
  (need byte-identical Int64-wrapping `hashInt`) — `diff_selfhost_test.sh` DEFERRED header.
- Stage-4 minor remainders: diagnostics-surfacing layer, coverage.ml/bench_runner.ml port — `PLAN.md`.
- `argStampEnabled` itself still has ~3 emit-only readers — a possible further-simplification
  follow-up (`ARGSTAMP-UNIFY-PLAN.md` §vestigiality). Not urgent.
- #11 full Num-polymorphic integer literals — `PLAN.md` (deferred, post-flip; not a gate).
- Memory holds the rest (`/Users/val/.claude/projects/-Users-val-medaka/memory/MEMORY.md` index):
  dispatch-gap history, the "parity probe is BLIND to equal-ON/OFF regressions → use
  diff_selfhost_eval_dict golden-diff" methodology, decided invariants.

## Non-negotiable operating rules (these cost real time this session — see ORCHESTRATING.md)
- **FORCE the oracle binaries:** `FORCE=1 bash test/build_oracles.sh` before ANY gate reading
  `test/bin/*` (`diff_selfhost_test`, `_eval_*`, the parity probe). `build_oracles.sh` mtime-skips
  rebuilds → a `typecheck.mdk`/`eval.mdk` change silently runs STALE source otherwise. Same for
  `./medaka` (rebuild via `make medaka`) and the parity probe binary (it doesn't auto-rebuild).
  A green/red on a stale binary means nothing.
- **The fixpoint is the decisive emitter gate.** Any change to `selfhost/types/typecheck.mdk`,
  `selfhost/eval/eval.mdk`, `selfhost/backend/*`, `selfhost/ir/*` is in the self-compiled emitter
  graph → `selfcompile_fixpoint.sh` C3a+C3b YES is MANDATORY.
- **Golden-diff, not convergence probes.** A probe comparing two modes (e.g. the argstamp parity
  probe) is BLIND to a regression that moves both modes the same wrong way. Gate on the OCaml
  golden (`diff_selfhost_eval_dict`, `diff_selfhost_test`, `diff_selfhost_build`).
- **Merge into LOCAL `main` via the MAIN checkout** (`cd /Users/val/medaka && git merge --ff-only
  <branch>`), then ASSERT it advanced (`git rev-parse main` == new tip). Never fetch/push.
  **Never `git checkout <sha>` in a worktree** (detaches HEAD; merges then strand commits on a
  dangling line — happened this session). Use `git reset --hard <sha>` on the branch.
- **Agent prompts:** STEP 0 = `git merge main` + a `git merge-base --is-ancestor <expected-tip>
  HEAD && echo BASE_OK` assert (an agent silently built on a stale base this session). Hand the
  agent the verified root cause + file:line; a STOP-with-precise-diagnosis is a success, not a
  failure (the gap docs are systematically stale — tell agents to reproduce + disprove the
  hypothesis on current main). Agents commit on THEIR branch + report the SHA; YOU verify + merge.
- **Bounded orchestrator reading:** scope-read just enough to frame a precise prompt; delegate
  deep exploration to read-only agents; keep conclusions, not file dumps.
- **Seed:** emitter-graph changes leave the gz seed (`selfhost/seed/emitter.ll.gz`) stale; agents
  do NOT re-mint (they rely on the fixpoint). The ORCHESTRATOR re-mints
  (`CHECK_OCAML=0 bash test/refresh_seed.sh` → verify `bootstrap_from_seed.sh`) only at real
  checkpoints. Currently FRESH (re-minted at 6dd74dc).
- Build in the worktree with `dune build --root .`; never `dune test` (hangs); opam env is pre-set
  (no `eval $(opam env)`). The task list is SESSION-LOCAL — durable items go in PLAN.md/docs/memory.

## How to start
Ask the user what they want, or — if told to proceed autonomously — pick the highest-value open
item that advances the soak (likely: close one of the documented gaps above, or chase whatever a
real-use bug report surfaces). For anything non-trivial, scope read-only first, present the plan,
then delegate + verify + merge. Surface genuine design decisions as questions; act on sensible
defaults otherwise.
