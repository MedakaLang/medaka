## [T-EMITTER-BENCH] Emitter benchmarking two-rebuild rule

A binary's *behavior* comes from its source but its *speed* comes from the emitter that compiled
it, so measuring an emitter change needs **two** rebuilds to get a single-generation binary. One
rebuild crosses the arms and makes an optimization look like a regression — a real 2.2× win was
once measured as a 2.5× slowdown this way. Seed re-mints (`test/refresh_seed.sh`) are **not
idempotent after a codegen change; it must be run TWICE**, and a stale seed can **SEGFAULT the
fixpoint** on a perfectly correct change. Full method in the `benchmark-emitter` skill.

## [T-PERF-HUNT] Perf-hunt method notes

Profile **allocation** (deterministic) over wall-clock (noisy); use **DWARF** call graphs. Note
`whenL False (expensiveCall …)` is **NOT a stub** — Medaka is strict, so the argument still
evaluates; this produced a false "hypothesis disproved" verdict on a hypothesis that was actually
correct. Full method in the `perf-hunt` skill.

## [T-DISPATCH-LOADER] Loader-vs-single-file dispatch bugs

A dispatch bug that reproduces through the loader but is green single-file is *usually* the EVAL
DRIVER, not dict-passing — this pattern recurred at Phases 96, 103, 121, and 125. But verify:
Phase 134 was the documented inverse case, and the standard two-probe comparison did *not* flag
it. Full method, both probes, and the instrument-the-resolution-arms technique live in the
`debug-pipeline` skill. Regression tests for this class must exercise the multi-module path
(`test/diff_compiler_eval_modules.sh`), not a single-file doctest.

## [T-EVAL-LOCKSTEP] evalModules / cevalModules lockstep

`evalModules` (`eval/eval.mdk`) and `cevalModules` (`ir/core_ir_eval.mdk`) are parallel module
drivers — `cevalModules` deliberately mirrors `evalModules` (same frame layout, same
`importFrameOf`/`pubReexports`/`installConsts` helpers), so a fix to one is silently absent from
the other. This is exactly how the P0-9 cross-module ctor-collision fix shipped patching only
`eval.mdk`, leaving `core_ir_eval.mdk` broken for months. Underlying hazard: `installConsts` +
`findCell` is last-write-wins on duplicate names, so any flat frame keyed by bare name across
modules inherits it (e.g. `map`'s arity-5 `Bin` vs `set`'s arity-4 `Bin` collapse into one cell).
The fix shape is a per-module **local** ctor frame that shadows the global.

## [T-GLOBAL-TABLE] 2026-07-24 program-global-table incident

On 2026-07-24 alone, this shape was the root cause of an S0, an S1, and a def-site regression
across four different PRs — every one of them 12/12 green. Real example: a graded-interface kind
table keyed on a bare type-param name re-kinded *every* arity-matching application in the whole
module graph, so `f Int a -> f String a` was silently accepted (`meowmeow` for `meowwoof`, exit 0,
no diagnostic), and one 4-line file turned 1 clean diagnostic into 45.

## [T-FIXTURE-LINES] Fixture line-count incident

Two agents hit the line-count-shift trap on 2026-07-31; one caught it only because a STOP
guardrail made them suspicious of their own comment-only edit.

## [T-PERRUN-COMMENTS] #829 reopened — fmt --write comment corruption

Re-verified first-hand on a fresh cold `make medaka` of `origin/main` @ `f9db4fd2` (2026-08-05).
The issue had previously been marked "FIXED, retired 2026-08-01" — that retraction claim was
itself wrong, and it sent an agent's mandatory `fmt --write` into corrupting their own comment.
Both halves the retraction claimed were fixed were re-tested independently and **both still
reproduce**:

- **Standalone `--` block** (the issue's own two-line repro, `data Cfg =\n  | Cfg { … }`):
  `fmt --write` collapses the header to `data Cfg = Cfg {` and drags the block onto the field
  **two past** the one it described, with the block's second line dangling onto the closing `}`.
- **Long trailing comment**: on the same header shape, a trailing comment on `alpha` lands on
  `beta` after `fmt --write` — moved one field down.
- **On the real `PerRun` record**, with its header artificially put into the two-line
  `data PerRun =\n | PerRun { … }` shape (the shape `DriverState`, in this same file, is actually
  in today) and given ONE new field with a trailing comment plus one standalone two-line block
  elsewhere in the body: `fmt --write` shifted **every one of the record's ~60 trailing
  comments** down by one field, piling the last two onto the closing `}` line — the whole-record
  cascade the reading-hazard paragraph (side comments as a column-wise prose river, where
  `effvarCounter`'s comment finishes a clause begun on `inRigidityBodyRef`) is a residue of.
- In every case, `fmt --check` on the corrupted output exits 0 — it reports the damage as already
  formatted, so the pre-commit hook (which gates on `fmt --check`, not a diff against intent) lets
  it through. The corruption is a stable fixed point, not a slow leak: a second `--write`
  reproduces the damaged file byte-for-byte, so it doesn't get worse, but it also never
  self-heals.

Three things measured safe: adding a field with no comment at all (either header shape, byte-
identical diff except the added line); adding a comment to a record whose header is already the
single-line `data X = X { … }` form (verified directly on `PerRun` as it stands today — a new
trailing-commented field and a new standalone two-line block each produced a diff containing only
the intended edit, second `fmt --write` a no-op). The real-world workaround for the unsafe case is
PR #1296 (still open, adding a new `Ref`-typed field to `DriverState`): add the field bare, put
the explanatory prose on the nearby function that derives/populates it instead of as an interior
record comment.

## [T-SHARED-CORPUS] The four/eight/five recount

This bullet has been wrong in both directions, twice. It used to say `test/wasm/fixtures/` had
"four" consumers — wrong, it missed `diff_compiler_prelude_obj.sh`. A "correction" to eight was
*also* wrong — a naive `grep -rl 'wasm/fixtures' test/` matches the real sibling corpora
`test/wasm/fixtures_typed/` (9 files) and `test/wasm/fixtures_modules/` (36), which
`diff_wasm_typed.sh`/`diff_wasm_modules.sh`/`build_wasm_cmd.sh` read *instead of* this directory.
The true count is five. `test/preflight.sh` already solves the word-boundary problem — "Word-
boundaries on both sides so `llvm_fixtures` cannot match `llvm_fixtures_modules`/`llvm_fixtures_
typed` (real sibling corpora in this tree)."

That two successive "verified" recounts each produced a *different wrong* number is the point,
not an embarrassing footnote: a count is an encoded fact with no derivation and no expiry, while
the enumeration is one command away. An agent obeying a count literally runs a subset and believes
it was exhaustive — the count manufactures the very confidence this warning exists to prevent.
It's "check the SET, not one member" failing inside the sentence that teaches it.

Assuming the flat `test/` path for the wasm gates (rather than `test/wasm/`) cost an agent two
failed invocations on 2026-07-16.

## [T-SNAPSHOT-SELF] Snapshot bless-command confusion

Two agents lost time on 2026-07-16 because the bullet said *what* to do (bless via the gate) and
never *which command* — they reached for `medaka snapshot --bless <compiler source>`, which is a
dead end (fails: "no snapshot … `--bless` never creates one — run `medaka snapshot --new` first",
exit 1).

## [T-LEGA-GOLDEN] LegA golden drift

Three perf PRs reddened only the `backend` shard on 2026-07-24 by blessing the snapshot corpus
but forgetting the selfproc LEG A scheme golden — because the LEG A diff runs in CI's `backend`
shard specifically, not the snapshot/check gates, so it stays green locally.

## [T-LEGA-REBASE] Three-way blend incident, 2026-08-11

This happened three times in one 2026-08-11 session, to three different agents, on the exact same
file (`test/selfproc_goldens/legA/types.typecheck.golden`, an ordinary ~1700-line text file with
no merge driver — `git check-attr merge` reports "merge: unspecified"). Two agents' re-cuts
landing in different regions three-way-merged with no conflict marker at all. The result is a
blend of two derivations, and no gate can flag it: the golden IS the oracle, so a plausible-
looking blend simply becomes the new expected output — the same rubber-stamp hazard as blessing a
red gate, but arriving with no red gate and no prompt to bless.

## [T-STDLIB-IMPORT] Per-module stdlib import cost measurements

- Importing a module whose types' instances live in `core` (the always-present prelude) is
  near-free — `import list`/`import string` drag no new instance surface, DCE trims to the
  referenced standalone fns (−256 B, +2% ≈ noise).
- Importing a module that defines a NEW type is not: DCE keeps every `DImpl`/`DInterface` whole
  (runtime dict-passing → pruning an impl would be a silent miscompile), so `import map` drags
  `Map`'s entire Eq/Ord/Debug/Display/Mappable/Monoid surface in (+34 KB binary, +4.8%
  self-compile).
- Anti-pattern, measured: delegating the compiler's hot monomorphic helpers (`elem`/`any`/`all`/
  `length`) to prelude Foldable methods loses `||`/`&&` short-circuiting and becomes dict-passed
  fold+closure — doing this to `util.mdk`'s hottest helpers cost +56% self-compile.
- The imported module is re-typechecked on every compile and every fixpoint iteration; once the
  compiler imports a stdlib module, any change there that perturbs emitted IR forces a seed
  re-mint + fixpoint re-validation (a feature — converts silent `support/`-vs-`stdlib/` divergence
  into a build-time gate — but it is churn).

## [T-GUARDS] Refutable-guard miscompile, fixed 2026-07-13

The multi-clause refutable-guard case was a run≠build miscompile until 2026-07-13: the
`__fallthrough__` sentinel read its jump target from a mutable Ref that `emitDecision` nulls
across a body-level match, and a refutable guard desugars to exactly such a match, so "try the
next clause" became `@mdk_oob`. It now carries its target in the node (`labelFallthrough`,
`backend/emit_support.mdk`) — the design the WasmGC backend already had, which is why wasm was
never wrong. Full write-up: `compiler/EMITTER-GAPS.md`.

## [WT-GOLDEN-ENSHRINES] Eval-oracle near-misses

Two separate PRs in one day nearly pinned a shape whose eval golden would have baked in a wrong
value; both were caught only because a reviewer computed the correct answer by hand first. 178
`*.eval.golden` files are generated from the interpreter across `test/eval_fixtures/`,
`eval_dict_fixtures/`, `eval_list_fixtures/`, `eval_modules_fixtures/*`, and eval is a known-wrong
oracle in at least five open S0s (#1034, #1037, #1040, #1047, #1062).

## [WT-DASH-PRINTF] Gzip CRC corruption incident

A `gzip/` oracle test case meant to corrupt a 4-byte CRC field used `printf '\xNN'` under dash,
which appended 16 junk *literal-character* bytes instead of 4 real bytes and shifted the whole
trailer. It still produced a CRC error, so the gate read green, and the bug only surfaced when a
sibling ISIZE test case failed with a CRC message that made no sense. Measured: appending the
literal-character form to a 219-byte file produced 235 bytes, not 223.
