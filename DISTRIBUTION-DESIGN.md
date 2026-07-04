# DISTRIBUTION-DESIGN.md — shipping a native `medaka` binary to strangers

> **Goal.** A relocatable `medaka` (+ `medaka_emitter`) that a stranger on macOS
> or Linux can install and use `medaka build` with — the "now do something real"
> path of the 0.1.0 funnel ([`RELEASE-0.1.0-PLAN.md`](./RELEASE-0.1.0-PLAN.md) §W1).
> Windows is explicitly out of scope.

Status: **design + dependency audit done; not yet started.** The audit below was
taken directly against the tree — file:line evidence is load-bearing, re-verify
if the code has moved.

---

## 1. The good news — codegen and runtime are already portable

Two findings that mean this is a *packaging* problem, not a *compiler* problem:

- **Emitted LLVM IR carries no target triple / datalayout.** `llvm_preamble.mdk`
  emits only `declare` lines; grep for `triple|datalayout|arm64|x86_64|apple|darwin`
  across `llvm_emit.mdk` / `llvm_preamble.mdk` / `medaka_rt.c` returns nothing. IR
  is target-neutral; clang defaults to the host. No `-arch`, no `.dylib`/`.so`
  assumptions in the emitter.
- **`runtime/medaka_rt.c` is POSIX-clean** — standard POSIX headers + `gc.h`, no
  `__APPLE__`/`__linux__` ifdefs, no dylib logic. Portable between macOS and Linux
  as-is.

So the work is entirely in the **packaging + discovery seam**.

## 2. Portability blockers (audit)

Each is a thing that currently assumes "running inside this repo, on this dev
machine." File:line references are from the audited tree.

1. **stdlib is located only via `MEDAKA_ROOT` (default `.` = cwd).** No
   argv[0]-relative and no compiled-in path. `medaka_cli.mdk` header comment
   states there is **no `getcwd`/`executable_name` extern**. Every subcommand
   derives `root ++ "/stdlib/..."` (`medaka_cli.mdk` `check`~:203, `build`~:481,
   `run`~:633, `test`~:717, `doc`~:732). A binary moved out of the repo, run
   anywhere but the repo root, fails to load `stdlib/{runtime,core}.mdk`.
   → **Needs a new exe-path primitive + exe-relative default.** *(This is also
   shared with any interpreter-only distribution — it's not native-build-specific.)*

2. **Mach-O-only stack-size linker flag, hardcoded + unconditional.**
   `-Wl,-stack_size,0x20000000` at `build_cmd.mdk:262` (and every bootstrap
   script). GNU ld on Linux **rejects** this outright (it uses `-z stacksize=`).
   Documented as "the arm64 macOS ceiling" (`selfcompile_lex.sh:36`). → **Must be
   platform-conditional**, and see the Linux stack risk in §3.

3. **`medaka build` needs a second compiled binary, `medaka_emitter`**, pointed
   to by `MEDAKA_EMITTER`. The `medaka run <emitter>` fallback is **non-functional**
   (`build_cmd.mdk:176-182` — the LLVM entry's `main` uses the `args` runtime
   extern, unbound in `medaka run` → resolve error). So shipping `medaka` alone
   does not give a working `build`; ship **both** binaries + default the env var.

4. **libgc (bdw-gc) is a required system dep, dynamically linked (`-lgc`), not
   vendored.** Three-tier probe in `detectGC` (`build_cmd.mdk:85-118`):
   pkg-config `bdw-gc` → `brew --prefix bdw-gc` → bare `-lgc`; hard-errors with an
   install hint if all fail (`:254`). Both *building* and *every produced binary*
   depend on libgc at runtime. → **Either lean on the package manager to install
   it, or vendor + static-link.**

5. **`clang` assumed on `PATH`** (`CC` default `"clang"`, `medaka_cli.mdk:483`),
   and **`runtime/medaka_rt.c` is compiled from source on every build** (no
   prebuilt object/archive anywhere). → The user needs a full C toolchain +
   headers, and `medaka_rt.c` + `gc.h` must be present. Inherent to the design
   (build shells to clang); acceptable for a developer audience; optionally
   smoothed with a prebuilt `libmedaka_rt`.

6. **Hardcoded `/tmp` scratch paths** — the IR file `/tmp/medaka_build_<out>.ll`
   (`build_cmd.mdk:148`) and GC probe (`:114-116`). Works on mac/linux but assumes
   a writable `/tmp`; namespaced only by output basename (race note already in
   AGENTS.md). Low priority; note for hardening.

7. **`brew --prefix bdw-gc` is macOS-only** (`build_cmd.mdk:99`) — harmless middle
   tier; on Linux success rides on pkg-config or a system `-lgc`.

## 3. The one genuine unknown — Linux deep-recursion stack (SPIKE FIRST)

The compiler is deeply recursive. macOS gives it a **512MB stack** via
`-Wl,-stack_size,0x20000000` — the exact flag **GNU ld rejects**. Linux's
main-thread stack defaults to ~8MB. So the real question is not "swap the flag"
but **"does the self-hosted emitter even run on Linux without blowing the
stack?"** If it doesn't, the fix may be structural: run the compiler on a spawned
`pthread` with a large stack, or `setrlimit(RLIMIT_STACK)`, or a big-stack worker.

This is the **only high-uncertainty item** in the whole workstream. Everything
else is bounded/mechanical. So it is the **first task**:

> **Task D0 — Linux build spike.** Stand up a GitHub Actions Ubuntu job (or a
> local Docker container) that: clones, runs the cold bootstrap from
> `compiler/seed/emitter.ll.gz`, builds `medaka` + `medaka_emitter`, and runs a
> trivial `medaka build hello.mdk` end-to-end. Outcome is binary: **green** ⇒ the
> rest is downhill, sequence the mechanical packaging; **fails** ⇒ we've found the
> exact Linux stack/link failure, which is the most valuable thing to learn now.

(This box is macOS, so the realistic probe is CI or Docker, not local.)

## 4. Design decisions

- **Lean on the package manager; do NOT chase a zero-dep static binary for
  0.1.0.** Homebrew formula with `depends_on "bdw-gc"` (+ Xcode CLT provides
  clang) makes blockers #4/#5 mostly evaporate on mac. Linux ships a tarball whose
  README lists `clang` + `libgc-dev`. Static-linking libgc is *optional polish*,
  deferred — don't let it block launch.
- **exe-relative stdlib discovery** (blocker #1): add an `executable_path`
  primitive (`_NSGetExecutablePath` on mac, `readlink /proc/self/exe` on Linux),
  and default `MEDAKA_ROOT` to a layout-relative path (e.g. `<exedir>/../lib/medaka`
  or `<exedir>/stdlib`). `MEDAKA_ROOT` stays as an override. This is an
  `add-primitive` job (declare in `stdlib/runtime.mdk`, implement in
  `compiler/eval/eval.mdk` **and** wire the native path). Keystone fix — collapses
  #3 too (default `MEDAKA_EMITTER` to `<exedir>/medaka_emitter`).
- **Platform-conditional linker flag** (blocker #2): detect OS (a `uname`-style
  extern or a build-time constant) and emit the Mach-O flag only on Darwin; on
  Linux use the appropriate mechanism (informed by D0's result — may be a
  big-stack thread rather than a link flag at all).
- **Ship a conventional install layout**: `bin/medaka`, `bin/medaka_emitter`,
  `lib/medaka/stdlib/...`, `lib/medaka/runtime/medaka_rt.c` (+ optionally a
  prebuilt `libmedaka_rt`), discoverable exe-relative.

## 5. Phased plan

- **D0 — Linux build spike** (§3). *Gates whether native build is in 0.1.0.*
- **D1 — exe-relative stdlib discovery.** exe-path primitive + `MEDAKA_ROOT`
  default; collapses the two-binary env ritual. Verify a `medaka` moved outside
  the repo still `run`/`check`/`build`s.
- **D2 — platform-conditional link/stack handling.** Make `medaka build` (and the
  compiler's own build) work on Linux; keep macOS byte-identical.
- **D3 — install layout + package manager.** Homebrew formula (`depends_on
  bdw-gc`); Linux tarball + README deps; clang-missing UX (actionable error).
- **D4 — release CI matrix.** Tagged CI builds mac (arm64; x86_64 if cheap) +
  Linux (x86_64; arm64 if cheap) artifacts + Homebrew bottle. This is
  `RELEASE-0.1.0-PLAN.md` §W8's delivery vehicle.
- **D5 (optional polish, post-0.1.0-OK)** — vendor + static-link libgc for a
  self-contained binary; prebuilt `libmedaka_rt` so clang doesn't recompile the
  runtime each build; `/tmp` scratch hardening.

## 6. Cross-checks

- Any change to `build_cmd.mdk` / the runtime / the emitter graph that perturbs
  emitted IR forces a **seed re-mint + fixpoint re-validation** (AGENTS.md). The
  exe-path primitive touches `eval.mdk` + `stdlib/runtime.mdk` + the native path →
  expect a re-mint; batch it (`feedback_defer_seed_remint`).
- The exe-path extern is **also** what an interpreter-only / self-contained-`run`
  distribution needs — do it once, both funnels benefit.
- Keep every golden byte-identical on macOS through D1–D3 (the platform
  conditional must be a no-op on Darwin).
