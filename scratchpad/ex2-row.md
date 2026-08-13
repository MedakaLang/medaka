
---

### `EX-2` — Phase 2′ (sprint exit) — **the checkpoint seed re-mint (×2) and the IN-BAND fixpoint. C3a+C3b GREEN both BEFORE and AFTER the re-mint; the second pass was byte-identical — non-idempotence NOT reproduced on this diff, measured. One tracked file changed: the seed.**

🔗 **Ledger cross-reference: `DECISIONS.md` RUN-B-0xx** (the orchestrator composes it). Discharges
§8's exit criterion *"the self-compile fixpoint is green on a twice-refreshed seed"* and consumes
`B-2.1-d` (EX-1)'s `unchecked:` first bullet (*"nobody has run the fixpoint on this diff"* — now
somebody has, twice, and it is green).

sites:        **ONE tracked file: `compiler/seed/emitter.ll.gz`** (`git status --porcelain` →
`M compiler/seed/emitter.ll.gz`, plus untracked `scratchpad/`). **Zero `.mdk`, zero goldens, zero
gates, zero docs.** Two *untracked-by-git* build artifacts also moved as a side effect of
`refresh_seed.sh` step 1: `./medaka_emitter` (rebuilt from current source, `FORCE_EMITTER_REBUILD=1`)
and `.medaka_emitter.srcstamp` (unchanged value `4e6908b8…` — same source, so same stamp). `./medaka`
was NOT rebuilt and needed no rebuild: no compiler source changed, and `MEDAKA_STRICT=1 ./medaka run`
on a hello probe exits **0** with no staleness warning, before and after.

transform:    Four steps, in this order, each timed on a quiet box (`uptime` load **0.15** at start
— stated because a wall-clock number from a loaded box is not a measurement):
1. **Fixpoint BEFORE touching the seed** (`sh test/selfcompile_fixpoint.sh`, redirected to a file,
   `$?` read — never piped): **exit 0, `C3a YES` / `C3b YES`, 38 s** (`scratchpad/fixpoint-pre.log`).
2. **`sh test/refresh_seed.sh` — pass 1: exit 0, 85 s.** Seed gz `1359573 → 1679648` bytes, raw IR
   `11880260 → 14552244` bytes, `355600 → 437276` lines.
3. **`sh test/refresh_seed.sh` — pass 2: exit 0, 89 s.** **Raw IR byte-IDENTICAL to pass 1**
   (`md5 d08eb4bba108c4c894b457d28b83ba8b` both passes; `cmp -s` silent). See `could move:` item 2
   for the `.gz` byte difference, which is NOT an IR difference.
4. **Strict byte-currency + fixpoint AFTER**: `SEED_STRICT=1 sh test/bootstrap_from_seed.sh
   scratchpad/emitter_from_seed strict` → **exit 0, 30 s, `C3a PASS: seed == native re-emission from
   current sources, byte-for-byte`** (an explicit `$OUT` was passed so the strict bootstrap did not
   overwrite the tree's `./medaka_emitter` with a seed-built one); then
   `sh test/selfcompile_fixpoint.sh` → **exit 0, `C3a YES` / `C3b YES`, 39 s**
   (`scratchpad/fixpoint-post.log`).

**THE RE-MINT DECISION, ARGUED — and the brief's discriminator is only half right.**
🚨 **There are TWO different C3a checks in this tree and they answer different questions.** Conflating
them is what makes "the fixpoint is green, so the seed is current" a false inference:
* **`selfcompile_fixpoint.sh`'s C3a** = `IR1 == REF`, where `REF` is the seed-bootstrapped
  emitter's *re-emission* of the gap-tolerant driver. Its own SEMANTIC NOTE (`:26-35`) says the seed
  is *expected* to lag by exactly one generation and that one turn of the crank converges. So this
  C3a is a **one-crank convergence** test that a lagging seed **passes by design** — which is exactly
  what happened: it was **GREEN before the re-mint on a seed minted 2026-07-19, 1341 commits back.**
* **`bootstrap_from_seed.sh`'s C3a** = `cmp seed.ll emitter2.ll` — the **byte-currency** test. That
  is the one a stale seed fails, and at `26423f93` **CI reported it failing**: `C3a WARN: committed
  seed differs from native re-emission (lagging seed)` (`seed-health`, job `94370157028`, log line
  209; also the `soundness` shard's cold-bootstrap step, job `94370157051`, log line 296).
  Reproduced locally: strict mode over the OLD seed is what the re-mint fixed.
⚠️ **Corollary that corrects the brief's ⭐ note:** *"CI has been running this on every push and it
PASSED"* is true only of **C3b**. `ci.yml`'s soundness step asserts `C3b PASS` and **explicitly
demotes C3a to a `::warning::`** (`.github/workflows/ci.yml:1282-1316`, *"C3b errors, C3a warns"*),
so a green `soundness` never claimed the seed was current — and in fact it was not.
**So was a re-mint NEEDED?** Under the SEED POLICY (`test/bootstrap_from_seed.sh:46-72`) — **no**,
not for correctness: only property (a) *"the seed WORKS"* is required, (b) byte-currency is a drift
detector, and `seed-health` was **green** at `26423f93` (`BOOTSTRAP-FROM-SEED PASS`). Under §8 — **yes**,
because §8 makes a twice-refreshed seed the exit criterion, and the policy's own carve-out is that
byte-currency *"is checked EXPLICITLY at checkpoints (`make bootstrap`) and re-minted then"*. **A sprint
exit is that checkpoint.** I did it for that reason and not because anything was broken.
**What the green pre-re-mint C3a does and does not prove:** it proves current source converges in one
crank from the committed seed and that the emitter reproduces itself. It does **not** prove the seed
was current (it was not), and it does **not** attribute the drift to this sprint — **the drift is
overwhelmingly pre-sprint**: the seed dates to 0917e97f (2026-07-19) and
`git diff --shortstat 0917e97f..HEAD -- compiler stdlib runtime` reads **109 files, +48715/−7337**,
against this branch's **+1296/−523 in one file**. The +23% seed growth is 1341 commits of accumulated
drift, **not** a measurement of `a3`/`b2`/`f`/`g`'s IR effect. Do not read it as one.

**Non-idempotence: NOT reproduced, and that is consistent rather than surprising.** The
`benchmark-emitter` rule (pass 1 mints with the old-generation emitter, pass 2 with an emitter built
from the new seed, so pass 1 can leave `C3a: NO`) is conditioned on a **codegen change**. This branch
has **none**: `git diff --name-only 2b9dc798..HEAD -- compiler/backend` is **EMPTY** (the only
non-`typecheck.mdk` compiler source touched is `compiler/ir/core_ir_lower.mdk`, 9/3, and
`compiler/types/registry.mdk`, 5/2). With codegen fixed, the mint is a pure function of source, so
pass 2 reproducing pass 1 byte-for-byte is the expected outcome — **and running it twice is still the
right move, because the prediction is only sound if the "no backend diff" premise holds, and the
second pass is what tests the premise rather than trusting it.** Measured, not asserted: identical
raw md5 across passes.

could move:   **Nothing in the language, in any engine, or in any golden — the diff contains no
executable byte the compiler reads.** The seed is *input to the cold bootstrap only*; every
`./medaka`/`medaka_emitter` in the tree was built from source and does not read it (`AGENTS.md`'s
borrow paragraph and `test/build_native_medaka.sh` cold/warm split). Concretely:

**1. What a re-mint changes, and what it cannot.** It changes the bytes a *cold* clone starts from
— i.e. which generation of the compiler compiles the first-generation compiler. It cannot change what
a warm build produces, because stage A/B rebuild the emitter from source either way. ⭐ **The emitted
IR carries no target triple** (`AGENTS.md`), so the new seed cold-bootstraps on x86 **or** arm from
these same bytes; the re-mint does not narrow the platform set. What it *does* buy on the cold path
is the removal of one generation of lag — the strict `C3a PASS` above is that statement.

**2. ⚠️ A NEW FINDING worth the ledger: `refresh_seed.sh` produces a DIFFERENT `.gz` blob on every
run even when the IR is byte-identical — so "the seed file changed" is NOT evidence that emission
changed.** Measured here: pass 1 gz `md5 7dab13ef…`, pass 2 gz `md5 8556110e…`, **same 1679648-byte
length, identical decompressed IR.** Mechanism derived, not assumed (`scratchpad/ex2-gzprobe.sh`):
`gzip -9 -c <file>` stores the input file's **MTIME** in the header — the probe compresses one
unchanged file at two mtimes and gets different bytes differing at **byte 6**, inside the 4-byte
MTIME field, with `FLG=0x08`. Two consequences: (i) every re-mint costs a fresh ~1.7 MB blob in git
history *regardless of whether anything moved*, which sharpens the SEED POLICY's own 86 MB / 41-re-mint
complaint; (ii) no gate is fooled, because both C3a checks compare the **decompressed** IR, never the
`.gz`. A future reviewer diffing the `.gz` will see a change that may mean nothing.

**3. The seed is also a FIXTURE for three other gates — enumerated, not assumed.**
`grep -rn 'seed/emitter.ll.gz'` names `gzip/test/inflate_oracle.sh:357-361`,
`gzip/test/deflate_oracle.sh:228-233` and `test/wasm/diff_gzip.sh:238`, which use it as *"the
self-referential, real-world corpus"*. **Their assertion is content-independent**: the expected
plaintext is obtained from the **system `gunzip`** of the very same bytes (`inflate_oracle.sh:176-181`
says so explicitly — *"never against a golden captured from our own code"*), so a re-minted corpus
changes the input and not the property. ⚠️ **NOT RUN** (see `unchecked:`) — the argument is from the
gates' construction, and a bigger corpus is a longer run, not a different verdict. `test/preflight.sh`
mentions the path only in comments; `test/selfcompile_build_fixpoint.sh` and
`test/diff_compiler_source_bytes.sh` consume it the same way the fixpoint does.

**4. The one behavioural surface that DOES move: `make bootstrap`/`seed-health` flip from WARN to
PASS**, and CI's cache key hashes `compiler/**`, so **this re-mint busts the medaka-binary and oracle
caches once** (`ci.yml:54-56` predicts exactly this: *"a seed re-mint busts the cache once"*). Expect
a slower first CI run on the pushed commit; that is designed, not a regression.

nearest miss: **A green fixpoint on a twice-refreshed seed proves SELF-CONSISTENCY and CONVERGENCE.
It cannot see a UNIFORM change — and this sprint's whole subject matter is uniform.** C3b is
`IR1 == IR2`: it asks whether the compiler reproduces *its own* output, so any change that moves the
emitted IR of **every** program in the same way (a dispatch route the whole graph now agrees on, a
dict arity uniformly re-shaped, a selection rule that picks a different-but-consistent impl
everywhere) is reproduced identically at every generation and **passes**. C3a after a re-mint is
weaker still: the reference is derived *from the seed I just minted with this same binary*, so it
compares the compiler against itself. **A wrong-but-self-consistent compiler passes both.** That is
precisely why `B-2.1-b2`/`f`/`g` needed a hand-built dict-arity/IR probe (`scratchpad/sa4c/probe.sh`,
`medaka build --keep-ir`) rather than the fixpoint: the fixpoint would have been green on the S0.
The nearest concrete programs it misses:
* **`SA-4c`'s two import orders** — the fixpoint compiles ONE module graph in ONE order, so an
  order-dependent route is invisible to it; `diff_compiler_check_cli_modules.sh`'s
  `route-word-order-invariant` leg is the check that sees it, and it is EX-4's to re-run.
* **Any program the emitter graph does not contain.** The corpus here is exactly
  `compiler/entries/llvm_bootstrap_lex_main.mdk`'s closure — no `deriving`-heavy user code, no
  graded-interface shapes, no `#1514`/`#1397`/`#1599` fixtures. A miscompile confined to a construct
  the compiler does not use itself is *structurally* outside this gate.
* **Diagnostics.** The gate compares emitted IR of a program that compiles clean; a
  diagnostic-only regression (an over-fire, an under-fire, a message change) leaves IR untouched.
  Value goldens cannot see it either — that is this run's standing blindness, restated because a
  green fixpoint is the most tempting thing in the sprint to over-read.

engines:      **ONE LINE, with the reason rather than the word: no engine's input changed, because
no `.mdk` and no `runtime/` byte changed** — the diff is one gzipped IR blob that only the *cold
bootstrap* reads, and the fixpoint's own C3b confirms the LLVM arm re-emits byte-identically at three
successive generations. LLVM: **positively observed** (C3a+C3b byte-identical, twice — pre- and
post-re-mint). eval · `core_ir_eval` · wasm: untouched by construction; none of them reads
`compiler/seed/emitter.ll.gz` (`grep -n 'seed' compiler/backend/wasm_emit.mdk
compiler/ir/core_ir_eval.mdk compiler/eval/eval.mdk` is empty).
⚠️ **wasm: STILL OWED AND STILL NEVER OBSERVED — six bites running** (`b2`/`c`/`f`/`g`/`d`/`EX-2`).
Stating it loudly as instructed: **this bite reaches nothing wasm consumes** (the wasm seed/bootstrap
path is `test/wasm/build_wasm_oracle.sh`, which builds from source, not from this seed), so its
exposure to EX-2 is nil — **but its exposure to `g`'s route-word change is unchanged and remains
unmeasured, and a green LLVM fixpoint is not evidence about the WasmGC backend.** The one gate that
would compare them (`diff_compiler_tmc_parity.sh`, `diff_compiler_engines.sh`) has not run this run.

gates run:    `sh test/selfcompile_fixpoint.sh` **exit 0 — `C3a YES` / `C3b YES`, BEFORE the
re-mint (38 s)** · `sh test/refresh_seed.sh` **×2, exit 0 each (85 s, 89 s)**, raw IR byte-identical
between passes · `SEED_STRICT=1 sh test/bootstrap_from_seed.sh <out> strict` **exit 0 — `C3a PASS`
byte-current, `BOOTSTRAP-FROM-SEED PASS` (30 s)** · `sh test/selfcompile_fixpoint.sh` **exit 0 —
`C3a YES` / `C3b YES`, AFTER the re-mint (39 s)** · `MEDAKA_STRICT=1 ./medaka run <probe>` **exit 0,
no staleness warning** (before and after). Every invocation redirected to a file with `$?` read
separately — **nothing piped**, per the `build`/`fixpoint`-exit-code-does-not-survive-a-pipe trap.
**⚠️ OWED-TIMINGS, now MEASURED (the brief's two `⚠️ OWED:` items):** `refresh_seed.sh` **85 s / 89 s**;
`selfcompile_fixpoint.sh` **38 s / 39 s**; strict `bootstrap_from_seed.sh` **30 s**. Total EX-2
wall-clock on the box ≈ **4.7 min**. 🚨 **The brief's foreground-ceiling warning did not bind:** the
fixpoint is a **~40-second** gate here, not a 600 s one. `AGENTS.md`'s foreground-ceiling paragraph
names `perf_scaling` (654-748 s) and `engines` (~5-7 min) — **the fixpoint is not in that class on
this box** and the caution appears to have been inherited by association. Backgrounding it cost
nothing, so this is a note for the next brief's budget, not a complaint.

unchecked:
* **Zero goldens blessed — intact.** `git status --porcelain` is exactly `M compiler/seed/emitter.ll.gz`
  plus untracked `scratchpad/`. **No snapshot, no `selfproc_legA`, nothing under `test/`.** EX-1's
  required LEG A shape (**13 deletions, zero additions, zero re-signatures**) is undisturbed: I
  changed no `.mdk`, so I cannot have moved a scheme. EX-3 inherits exactly what EX-1 left.
* **The three gzip corpus gates were NOT run** (`gzip/test/inflate_oracle.sh`,
  `gzip/test/deflate_oracle.sh`, `test/wasm/diff_gzip.sh`) — the seed is their fixture and its bytes
  changed. Argued content-independent above from their own construction; **that is an argument, not a
  run.** ⚠️ **OWED:** `sh gzip/test/inflate_oracle.sh` · `sh gzip/test/deflate_oracle.sh` ·
  `sh test/wasm/diff_gzip.sh` (the last needs node ≥24 + the wasm oracle). Cheapest first-line
  substitute, also not run: `gunzip -t compiler/seed/emitter.ll.gz`.
* **`typecheck_compiler_source.sh`, `diff_compiler_engines.sh`, `perf_scaling`, `tmc_parity`,
  `must_fail`, corpus sweeps, full suite: NOT RUN** — per the reduced floor, and none of them is
  moved by a seed blob. EX-4 owns the must-fail and `check_cli_modules` re-runs on this binary.
* **A COLD clone from the new seed was not exercised end-to-end** — `bootstrap_from_seed.sh` builds
  the emitter from the seed (that ran, strict, PASS) but I did not then run a full cold
  `make medaka` in a fresh checkout with no `./medaka_emitter`. CI's every shard does exactly that
  (`ci.yml:941`, *"Build medaka (cold bootstrap from seed)"*), and the cache-bust in `could move:`
  item 4 guarantees it happens on the next push. ⚠️ **OWED:** a fresh-clone `make medaka` if the
  release cares.
* **Whether the seed lagged at BASE could NOT be retrieved.** `gh run view --job 94308407847 --log`
  (the `soundness` job on `2b9dc798`) returns **empty output at exit 0** — the log is gone or
  unavailable, so the BASE-side C3a WARN is inferred from the seed's 2026-07-19 date and the
  1341-commit gap, **not observed**. ⚠️ **OWED:** nothing re-derivable now; the inference is
  labelled as such.
* **PERF: not measured.** A re-mint cannot change any built binary's speed (nothing reads the seed
  after bootstrap), but the *cold bootstrap itself* now expands a 23%-larger IR and compiles it —
  `bootstrap_from_seed.sh` took **30 s** here post-re-mint and I have no pre-re-mint reading of the
  same script to compare against. **Genuinely unanswered.**
* **Reproduction:** `scratchpad/ex2-state.sh` (state + seed identity), `ex2-fp.sh <label>` (timed
  fixpoint), `ex2-remint.sh` (the two-pass re-mint with the identity comparison), `ex2-post.sh`
  (strict bootstrap + post fixpoint), `ex2-gzprobe.sh` (the gzip-mtime derivation). Logs:
  `fixpoint-pre.log`, `fixpoint-post.log`, `remint-1.log`, `remint-2.log`,
  `bootstrap-strict.log`, `ci-soundness.log`, `ci-seedhealth-head.log`. ⚠️ The multi-MB seed copies
  those scripts made were **deleted** after their md5s were recorded (47 MB → 164 KB of untracked
  scratch); the pre-re-mint seed is recoverable from git (`git show HEAD:compiler/seed/emitter.ll.gz`,
  `md5 aabf000154a06fa5964815706e63267d`, raw `md5 60e85f34ea808452af49c955828cfc9d`).
