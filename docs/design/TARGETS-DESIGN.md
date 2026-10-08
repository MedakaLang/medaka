# Targets and host profiles

**Status:** OPEN — ratified 2026-10-01, nothing built. Epic #3661; milestones
T1–T5 (`Targets: T1 (the catalog is data)` … `Targets: T5 (the edge profile)`).
Every ruling in this document was taken by Val on 2026-10-01. Child issues cite
its sections rather than restating them.

Medaka has two compiled backends and an interpreter, and their capabilities
cannot stay identical: the browser has no sockets, the edge has no files, native
has no `fetch`. This document says how the language stays one language while its
targets differ — what may differ, where, and how the difference is checked.

## 1. Why now

`compiler/RUNTIME-DESIGN.md` §6a decided the shape of the answer on 2026-06-06:

> target = (available capability set) × (backend) … Effects make multi-target
> HONEST. A program using `<File>` simply won't typecheck/link against a target
> that doesn't provide `<File>` — a clear *static* error, never silent runtime
> divergence … No forks, no `#ifdef`.

That ruling stands. None of it is implemented. Measured on 2026-10-01:

- **No target reaches the typechecker.** `--target native|wasm` is a `medaka
  build` switch (`compiler/driver/build_cmd.mdk`, `BuildTarget`); the `EmitTarget`
  in `compiler/ir/core_ir_lower.mdk` narrows one dict-tag collision check and
  nothing else. `check`, `run` and `test` have no target.
- **An extern wasm cannot lower fails after typechecking**, inside the emitter,
  as `unbound variable 'writeFile'` — an unlocated panic (#380, #2130, #2426).
  Only the 28 net names and user FFI externs get a worded refusal. The one
  located, pre-lowering refusal is the file-grant check in
  `compiler/backend/wasm_file_grants.mdk`.
- **Which backend lowers which extern is recorded in name lists.** A ladder of
  predicates in `compiler/backend/wasm_emit.mdk` (`isStrExternW`, `isLeafExternW`,
  `isArrayExternW`, `isByteBlockExternW`, `isNetExternW`, `isFfiExternW`), the
  21-family `externCatalog` in `compiler/backend/llvm_emit.mdk`, `isNetExtern`
  duplicated across the two on purpose, and the hand-kept
  `test/CAPABILITY-EXCEPTIONS.txt`, which `test/diff_compiler_capability_matrix.sh`
  checks by scraping those lists out of the source. Live figures: interpreter
  166/196, LLVM 195/196, wasm 140/196 (33 `PERMANENT`, 22 `WASM-GAP`, 1 `TODO`).
- **The JavaScript host is three drifting copies.** `test/wasm/run.js`,
  `playground/worker.js` and `playground/compile.mjs` each carry their own `env`
  import object, plus two ad-hoc stubs in the playground tests. `worker.js` lacks
  the `mdk_write_file_*` trio (#375, a `LinkError`); the parity gate diffs only
  marked blocks (#449); the third copy took the playground down once (#543).
- **The playground decides which stdlib modules ship by a hand list** in
  `playground/main.js`, and the "stubbed capability" regex is copied into
  `playground/render_docs.mjs` and `playground/guide_wasm_differential.mjs`.
- **User code cannot call JavaScript.** `extern f : … -> <FFI "lib"> …` binds a
  C symbol; `wasm_emit` refuses it (pinned by `test/wasm/diff_wasm_ffi_wall.sh`).
  No issue tracked a JavaScript binding, a WASI target, or an edge profile.
- **Some divergences are not capability gaps.** `canonicalizePath` lowers to
  identity on wasm; Unicode classification is ASCII-only on wasm; JavaScript
  `Math.*` and libm differ sub-ULP; float formatting executes in the host. Under
  §3's law these are defects or ledgered deviations with a drain date, not
  properties of the target.

So the design problem is not to invent a divergence model. It is to make §6a a
checked property, and to add the one thing §6a did not cover: a binding the user
supplies for a host.

## 2. Prior art

| Language | Mechanism | What it tells us |
|---|---|---|
| Rust | `#[cfg(target_os, target_arch)]`; the `core` / `alloc` / `std` split; `wasm32-unknown-unknown` vs `wasm32-wasip2`; wasm-bindgen glue | The `core`/`std` split is §6a's stratification. A target triple separates *architecture* from *operating system*; we need the same separation (backend from host). `cfg` is the fork §6a rejected. |
| Go | build tags; `GOOS=js GOARCH=wasm`; `syscall/js`; `wasip1` | The JavaScript boundary is a *library*, not a language feature. |
| Gleam | `@target(erlang)` on a definition; `@external(erlang, "m", "f")` and `@external(javascript, "./m.mjs", "f")` on one declaration, with an optional Gleam fallback body; a definition without an implementation for the current target is an error only when referenced | The closest fit: one signature, per-target bindings, in-language fallback, reached-means-error. |
| MoonBit | `extern "js"` / `extern "wasm"` inline bodies; file-level `targets` in the package manifest; a function-level `cfg`; reaching a backend-A FFI while compiling backend B is an error | Confirms reached-means-error. File-level targets are what people reach for when the language gives them nothing better. |
| Koka | one `extern` with `c inline "…"` / `js inline "…"` bodies per backend | The per-backend *body* on one declaration — the stdlib-internal form of Gleam's `@external`. |
| GHC (wasm and JS backends) | `foreign import javascript "((x,y) => x + y)"`; an opaque `JSVal`; a declared set of directly marshalled types | The boundary is a type plus a declared crossable set — the shape FFI v1 already has (#2073). |
| Kotlin multiplatform | `expect fun` in common code, `actual fun` per platform; a missing `actual` is a compile error | Per-platform implementation of one typed declaration, statically complete. |
| Roc | the platform owns all IO; the application is pure plus hosted effects; one ecosystem per platform | §6a rejected full Roc-style platforms. Roc's *host declares what it provides* is right, and it is what a profile is. |
| WASI preview 2 / the component model | a WIT `world` is the set of imports a host provides | The profile concept already has a standard spelling. A profile lowers to a world later; nothing here reinvents one. |
| WinterTC | a minimum common API across Node, Deno, Workers and Bun; `navigator.userAgent` runtime keys | The edge is not one host. Define a minimum common host and let richer hosts be supersets. Runtime detection is the host's business, never the language's. |
| Elm | no FFI; ports only | The browser-sandbox posture the playground's capability stubs already take. |

Nobody in this set does `#ifdef` in a typed functional language any more. They do
one declaration with per-target bindings, reached-means-error, and they keep
backend and host apart.

## 3. The model

### 3.1 Three axes

`--target wasm` today names all three of these at once.

1. **Backend** — `llvm` or `wasmgc` (and `eval`, the interpreter). The backend
   decides the value representation and what the emitter can lower. It is
   semantically invisible: `docs/spec/EMITTER-SEMANTICS.md` R2 already requires
   one meaning on every engine.
2. **Host profile** — what the environment provides: a set of granted effect
   labels, each with a domain, plus a host ABI (C symbols, `env` imports, WIT
   imports). `llvm/native-posix`, `wasmgc/node`, `wasmgc/browser-worker`,
   `wasmgc/edge`; later `wasmgc/wasi-p2`.
3. **Capability requirement** — what a program needs. Already in the types as
   the effect row; the manifest `M(module)` of `docs/spec/EFFECTS-SEMANTICS.md`
   §7 is its rendering.

A **target** is a backend paired with a profile. `--target wasm` today means
`wasmgc` with the `env` shim that `run.js` happens to install; §5.3 keeps that
spelling as an alias.

### 3.2 The law

> A target may **lack** a capability. A target may **never change a meaning**.
> The only place two targets are permitted to differ is the **binding of an
> extern** — never a Medaka body.

Four consequences:

- No `#ifdef`, no `@target` on a Medaka definition, no per-target stdlib file.
  Divergence lives in catalog rows and host bindings, both of which are data the
  compiler can check.
- A difference in a *value* between two targets is a defect. `canonicalizePath`
  as identity, ASCII-only Unicode on wasm, and the libm/`Math.*` ULP class are
  tracked as such, or sit in `test/engine_divergence.txt` with a reason and an
  issue, never as a property of the target.
- A difference in *availability* is static. A program that needs a label the
  profile does not grant is refused by `check`, located, before any emitter runs
  (§5).
- A profile is the same object twice: the compiler's grant table (§5) and the
  host's installed slice set (§6). Gates check that the two agree (§6.3).

### 3.3 What a profile is not

A profile is not a security boundary and this document makes no capability
claim. The 2026-08-26 ruling in `docs/design/CAPABILITY-PLATFORM.md` §10 — the
capability platform waits for the typechecker and emitter rearchitectures and is
not pitched externally until the effect-soundness pins drain — is unchanged. The
test applied to the FFI epic (#2070) applies here: this work ships a mechanism
that makes the three engines honest with each other; it asserts no guarantee to
anyone outside the project.

## 4. The extern catalog as data (T1)

`compiler/EMITTER-TARGET-ARCHITECTURE.md` §9 already specifies the row:

```text
ExternSpec
  id, signature, effects/capabilities, domain, target dispositions
```

and says "each physical backend then supplies a lowering or an explicit
rejection". T1 builds it.

### 4.1 The row

One row per `stdlib/runtime.mdk` extern, read from the declaration:

- the name;
- the declared signature, whose effect row is the *only* statement of what the
  extern requires — it is never retyped in the table;
- one **disposition** per backend, a closed sum:

```medaka-nocheck: a sketch of the disposition sum; the names are the design's, not a compiled declaration
data Disposition
  = CSymbol String        -- llvm: a symbol in runtime/medaka_rt.c
  | EnvImport String      -- wasmgc: an `env.mdk_*` host import
  | Inline                -- lowered in place: an IR intrinsic or pure WAT
  | Interpreted           -- eval: bound in the interpreter's extern table
  | NotProvided String    -- this backend does not lower it; the reason
```

### 4.2 Consumers

- Both emitters dispatch on the row. The family predicates become projections of
  the table; the two intentionally duplicated net lists are deleted.
- A reachable extern whose disposition for the selected backend is `NotProvided`
  is a validator refusal before any emitter runs (the architecture's R6), never a
  fallthrough. After T2 that refusal is unreachable from user code (§5.5).
- `NotProvided` carries the reason the exceptions ledger carries today, which is
  what lets the ledger be derived.

Issue: #3662 (catalog as data). The residuals of #1405 and #2616 are absorbed.

### 4.3 The matrix gate reads the table

`test/diff_compiler_capability_matrix.sh` stops scraping `contains name [...]`
lists out of emitter source. It reads the catalog, and the TAB-separated ledger
is either generated from the table or retired in favour of it. The informal
categories (`PERMANENT`, `WASM-GAP`, `BUG`, `DEAD`, `TODO`) become the
disposition sum, so a row cannot be `WASM-GAP` "only because it isn't documented
`PERMANENT` anywhere". The three stale extern counts in the tree (71, ~132, 138
against a catalog of 196) are derived or deleted, as are the two false statements
that the math externs trap on wasm (`stdlib/runtime.mdk`, `stdlib/math.mdk`).

Issue: #3663 (matrix gate reads the catalog).

## 5. Availability is static (T2)

### 5.1 A profile is a policy

The subsumption check already exists: `medaka check-policy --allow L1,L2 --fn f`
compares an entry's inferred row with an allowed set
(`compiler/tools/check_policy.mdk`, over `compiler/types/effect_invocation.mdk`).
A host profile is that allowed set, built in. No typechecker rule changes; a
profile never touches inference, only the entry-point check.

The profiles and their grants are one compiler-owned table — §8 gives the
contents.

### 5.2 Label grain

**Ruling.** Availability is at **label** grain, not extern grain. A backend that
claims a label for a profile implements every catalog extern under it.

The alternative — profiles granting per extern — is honest about today but makes
the manifest no longer the single truth, and turns each profile into a 196-row
table. Label grain is what "effects make multi-target honest" literally means.

The cost is a ratchet. The 22 `WASM-GAP` rows each get a host import or force a
label split:

| Label | Missing on wasm | Disposition |
|---|---|---|
| `Clock` | `wallTimeSec`, `monotonicSec`, `sleepMs` | host imports |
| `Rand` | `osEntropyBytes` | `crypto.getRandomValues` |
| `Stdin` | `readLine`, `readLineOpt`, `readAll`, `readExactly` | host imports; `browser-worker` does not grant `Stdin` |
| `FileRead` / `FileWrite` | `writeFile`, `appendFile`, `listDir`, `makeDir`, `removeDir`, `removeFile`, `rename`, `statFile`, `fileMode`, `writeFileMode`, `fsync` | extend the host-fs seam |
| `Env` | `executablePath` | host import; empty where there is no executable |
| `Exec` | `runCommand` | `NotProvided` on every wasm profile |
| `IO` (narrow, unlabelled) | `allocBytes` | decide its label, then a host import |

The `PERMANENT` rows are re-read under the law: the three build stamps are
constants known at build time and can be baked in; the two `medaka run` stdout
hooks belong to an interpreter-only disposition; the 28 `Net` externs stay
`NotProvided` on every `env` profile, because they are raw sockets, and `Net` on
the edge is a fetch binding (§8.2).

Issue: #3666 (label-grain ratchet).

### 5.3 Selecting a target

- `medaka.toml` gains a `[target]` section: `profile = "wasmgc/browser-worker"`.
  A library declares the profile it promises to work on; `check` proves it.
- `--target <backend>/<profile>` on `check`, `build` and `run` overrides the
  manifest. `--target wasm` remains an alias for `wasmgc/node` so every existing
  gate invocation is unchanged; `--target native` for `llvm/native-posix`.
- `run` is a profile too. The interpreter's grants are what its `ioExternBindings`
  install, so a program that needs `<Net>` is refused at check time rather than
  panicking inside `compiler/eval/eval.mdk`.
- An unknown profile name is a located error that lists the known names. The
  flag vocabulary is a value per `docs/design/ARGS-DESIGN.md`, and the
  `docs/ops/CLI-CONFORMANCE.md` census is re-derived.

Issue: #3664 (profiles as policies).

### 5.4 The refusal

With a profile selected, `check` performs `M(entry) ⊆ profile` and refuses with a
located, coded diagnostic that names the label, the profile and the via-chain the
manifest machinery already prints:

```text
error[T-TARGET-CAPABILITY]: main requires <Exec "_", Stdin>
  target wasmgc/browser-worker grants {Stdout, Stderr, FileRead, FileWrite, Clock, Rand}
  reached via: main -> loadConfig -> runCommand
```

- Parameterized labels compare by domain subsumption: `<Net "api.example.com/*">`
  is admitted by a profile that grants `Net` whole and refused by one that does
  not grant `Net`.
- An authority unresolved at the entry is top in its domain
  (`docs/spec/EFFECTS-SEMANTICS.md` §7) and is refused by any profile that grants
  less than the whole label. It is never admitted silently.
- A missing entry point is a refusal. #2047's fail-open shape is pinned against
  here as it is in `check-policy`.
- `build` runs the same check before lowering, so it cannot reach a program that
  `check` would refuse.

Issue: #3665 (check refuses on profile).

### 5.5 What this retires

After §4 and §5.4, an extern with no lowering can reach an emitter only through a
compiler bug. The worded net and FFI rejections and the `unbound variable`
fallthrough for catalog names in `compiler/backend/wasm_emit.mdk`, and the
`unsupported extern` arm in `compiler/backend/llvm_emit.mdk`, are replaced by one
validator refusal that names the extern and the profile and says that `check`
should have refused the program. `docs/spec/EMITTER-SEMANTICS.md` R3 is met by
construction. The `wasm:emitter-gap` rows in `test/engine_divergence.txt` that
quote `unbound variable` drain.

Issue: #3667 (extern panics retired). Closes #380 (its extern half), #2130, #2426.

## 6. The host side (T3)

### 6.1 One module, composed from slices

The wasm TCB below the emitted module is JavaScript, and `docs/spec/WASM-SEMANTICS.md`
§2 (WH1–WH6) already treats the import surface as part of the semantics. T3
gives that surface one implementation: a host module under `playground/`
(placement per the `architecture` skill) built from **capability slices** —
`stdout`, `stderr`, `floatfmt`, `math`, `strtod`, `fs`, `env`, `args`, `exit`,
`clock`, `entropy`, `stdin`, and later `jsffi` (§7.4).

```text
makeImports(profile, { vfs, args, env, bindings }) -> the `env` import object
```

- A profile on the host side is the set of installed slices.
- A withheld slice installs a callable that throws the named `CapabilityError`
  (WH3). Instantiation never fails with a `LinkError` on a module the compiler
  legally emitted.
- Flush discipline (WH4) has one implementation: stdout bytes, then stderr bytes,
  on completion, `exit` and trap alike.
- `run.js`, `worker.js`, `compile.mjs` and the two test stubs import it. The
  `--- BEGIN SHARED SHIM ---` blocks and the byte-diff that guards them are
  deleted.

Issue: #3668 (one host module). Closes #375, #376, #449.

### 6.2 Where it runs

| Profile | Host | Slices installed |
|---|---|---|
| `wasmgc/node` | `test/wasm/run.js`; every wasm gate | all but `jsffi` unless a bindings module is given |
| `wasmgc/browser-worker` | `playground/worker.js` | `stdout stderr floatfmt math strtod clock entropy`, `fs` over the in-memory vfs; `exit` is a capability error by design |
| the compiler itself in the browser | `playground/compile.mjs` | `fs` over the source vfs, `args` as the call's argv; `env` returns `None` |
| `wasmgc/edge` | the T5 loader | §8.2 |

### 6.3 Derived parity

The compile-time profile (§5) and the host-side slice set are the same object
rendered twice. The gate checks it from the module's side: for every fixture the
wasm gates build, the emitted module's import key set is a subset of the keys the
selected profile's slices install. A new import without a slice reds the gate
naming the key; a slice without an import is reported as unused. This is #1407's
"import availability is validated before WAT" criterion, measured from the other
side, and it replaces the marked-block byte diff.

### 6.4 The playground ships what the catalog says

A stdlib module ships on a profile iff the labels its exports require — from the
catalog, via `medaka manifest` per module — are granted by the profile. One
generated list replaces the hand list in `playground/main.js` and the regex
copied into `playground/render_docs.mjs` and `playground/guide_wasm_differential.mjs`.
`playground/build_site.sh`'s fail-closed asset check reads the generated list.

Issue: #3669 (derived parity).

Amendment (2026-10-05, `docs/design/WASM-ASYNC-DESIGN.md` section 10 ruling 4):
the playground vfs carries every stdlib module, and the refusal is T2's
label diagnostic (`T-TARGET-CAPABILITY`, naming the label and the via-chain),
the same one a native `--target` check gives. This amends the mechanism, not
the ruling: the generated list feeds `build_site.sh`'s asset check only.

### 6.5 The host receives the grant

Native and `medaka run` confine a file operation to the authority granted at the
call (`docs/spec/EFFECTS-SEMANTICS.md` §2.3, §8). A wasm host import receives the
path alone, so `compiler/backend/wasm_file_grants.mdk` refuses pattern grants at
build and lets exact and whole-domain grants run unchecked (#3590). With one host
module the fix is a channel: the emitter passes the hidden grant argument the file
externs already carry ahead of the path, through the existing byte channel; the
`fs` slice canonicalizes and checks the way `runtime/medaka_rt.c` does, against
the vfs or the real filesystem; the pattern refusal is then deleted.

Issue: #3670 (fs slice receives the grant). Closes #3590.

## 7. Host bindings (T4)

### 7.1 Why

A user can call C (`extern f : … -> <FFI "lib"> …`, #2070) and cannot call
JavaScript. A library that wants `fetch` on wasm and libcurl on native has no way
to say so from one source. This is the one divergence §3.2 permits — the binding
of an extern — made available to users.

### 7.2 The shape

**Ruling.** One `FFI` label, with a **host-qualified prefix**: `<FFI "c/libcurl">`
and `<FFI "js/fetch">` are the same ceiling with a backend-qualified parameter.
There is one rule, one `T-FFI-UNLABELLED` check, and symmetric walls (§7.5). A
second label would double each of those.

A declaration carries one binding per host ABI. The spelling is a parser
decision inside #3671 (per-host bindings surface); the shape, with a placeholder
syntax, is:

```medaka-nocheck: the binding form is not yet accepted syntax; this illustrates one declaration with two host bindings and a fallback body
extern fetchText : (url : String) -> <Net url, FFI "js/fetch"> Result String String
  bind c  "mdk_fetch_text"      -- llvm/native-posix: a C symbol, linked per [foreign-libraries]
  bind js "env.fetchText"       -- wasmgc/*: an import the host's `jsffi` slice supplies
```

- A Medaka body may stand in for a host with no binding (the Gleam fallback).
- The terminal row must name `FFI` with a prefix matching a host the declaration
  binds; `<>` is refused as today. The parameter stays in the `Prefix` domain;
  the first path element is the host ABI, which is what the walls key on.
- The written row may narrow the description and never remove `FFI` — the FFI
  epic's R2, unchanged.

### 7.3 Reached-means-error

A declaration with no binding for the selected target and no fallback body is a
located error only when it survives dead-code elimination for that target. That
is the Gleam and MoonBit rule, and it is what lets one library serve native and
wasm from one source: the `js/` binding is simply not reached under
`llvm/native-posix`.

Issue: #3671 (per-host bindings surface).

### 7.4 Lowering a `js/` binding

- The emitter turns a bound declaration into an `env` import named by its
  binding, marshalled over the existing byte channel (WH5: GC references never
  cross). The crossable surface is FFI v1's (#2073): `Int`, `Float`, `Bool`,
  `Char`, `String`, `Bytes`, `Array Int`. A signature outside it is a located
  refusal at the declaration with the same text the C side gives.
- The host module gains a `jsffi` slice: `makeImports(profile, { bindings })`
  installs each user binding under its import name. A binding the host did not
  supply is a named `CapabilityError` at call time.
- `test/wasm/run.js` accepts a bindings module so a gate can exercise a binding
  end to end. The one-fixture-two-hosts probe — the same declaration bound to a
  stub C library on native and a bindings module on wasm, returning the same
  values — is the law's "never change a meaning" check for this feature.

Issue: #3672 (js binding lowering).

### 7.5 Symmetric walls

Today the wall is one-sided: `wasm_emit` refuses `FFI`, and LLVM has nothing to
refuse. With prefixes both walls are `check`-time profile refusals (§5.4):
`c/` reached under a `wasmgc/*` profile, `js/` reached under `llvm/native-posix`,
and either under `medaka run`, which grants no `FFI` prefix. The emitter-side FFI
refusals are deleted as unreachable; `test/wasm/diff_wasm_ffi_wall.sh` is
generalized or migrated to a native test.

Issue: #3673 (symmetric walls).

### 7.6 Not in v1

- **Callbacks from the host into Medaka.** The FFI epic's non-goal; a function
  value cannot cross the byte channel.
- **Async bindings.** `fetch` is a promise and a host import is synchronous. On
  a worker the host can block with `Atomics.wait`; on a main thread it cannot.
  JavaScript promise integration (JSPI) is the eventual path, and the Async v2
  effect index is where a native async binding would surface. Neither is
  designed here (the clock's wait is designed in `docs/design/WASM-ASYNC-DESIGN.md`).
- **An opaque host-value type** (GHC's `JSVal`). The crossable set is bytes and
  scalars. If arrays of bytes prove too thin, an opaque handle type is the next
  step and does not change anything above.

## 8. Profiles (T5)

### 8.1 The table

| Profile | Backend | Host ABI | Grants |
|---|---|---|---|
| `llvm/native-posix` | `llvm` | C symbols | every label; `FFI "c/*"` |
| `eval/run` | interpreter | `ioExternBindings` | what `medaka run` installs today: `Stdout Stderr Stdin Clock Env Exec Rand FileRead FileWrite Net Signal`; no `FFI` |
| `wasmgc/node` | `wasmgc` | `env` | `Stdout Stderr Stdin Clock Env Rand FileRead FileWrite`; `FFI "js/*"` with a bindings module |
| `wasmgc/browser-worker` | `wasmgc` | `env` | `Stdout Stderr Clock Rand FileRead FileWrite` (vfs); `FFI "js/*"` through the playground's bindings |
| `wasmgc/edge` | `wasmgc` | `env` | `Stdout Stderr Clock Rand`; `Net` through a fetch binding; `FFI "js/*"` |
| `wasmgc/wasi-p2` | `wasmgc` | WIT | per world — a seam only, §8.4 |

`Exec` is granted on native and `run` only. `Net` as raw sockets is granted on
native and `run` only. `Signal` is native and `run` only.

### 8.2 The edge

The first profile that is neither the playground nor Node, at the WinterTC
minimum common API that Cloudflare Workers, Deno, Bun and Node all satisfy, so
one loader runs on every one of them.

- `Net` is granted **through a fetch binding only**: a stdlib capability module
  binds `js/fetch` under `<Net url>` so a program writes `<Net url>` and never
  names `FFI` itself. That module is the one place the prefix is written, and it
  goes through the stdlib proposal path.
- `medaka build --target wasmgc/edge` emits the module and an ES-module loader
  that imports the host module with the `edge` slice set. The loader never
  branches on `navigator.userAgent`; runtime detection is the host's business.
- A Node-simulated runner installs exactly the edge slice set and runs the
  engines corpus restricted to the programs whose manifest the profile admits —
  a set derived by §5.4, not listed. One real deploy is verified by hand before
  T5 closes and the procedure is written under `docs/ops/`.

Issue: #3674 (edge profile).

### 8.3 Async on the edge

A request handler on the edge is itself a promise. v1 runs a binding
synchronously on a worker where the host allows `Atomics.wait` and documents the
hosts where it does not; the async binding is §7.6's open item, not T5's.
The waiting model is in `docs/design/WASM-ASYNC-DESIGN.md`.

### 8.4 The WASI seam

WASI preview 2 is a different host ABI — WIT imports — not a profile of `env`.
In this design it is one more constructor of the disposition sum (§4.1) and one
more row of the profile table, with nothing built. `compiler/WASMGC-DESIGN.md`
already names it as the production-CLI path; that remains the plan of record,
and a WIT `world` is what a profile would lower to there.

## 9. Non-goals

- Conditional compilation of Medaka bodies, in any spelling.
- Per-target stdlib source files. A stdlib module is one module; its capability
  modules are present on a profile iff their labels are granted (§6.4).
- A capability or security claim. §3.3.
- Replacing the `env` ABI with WASI now. §8.4.
- Designing the async host binding. §7.6.
- Memory isolation between modules. `docs/design/CAPABILITY-PLATFORM.md` §7b
  owns that question.

## 10. Gates and ledgers — what each becomes

| Today | After |
|---|---|
| `test/CAPABILITY-EXCEPTIONS.txt`, hand-kept | derived from the catalog's `NotProvided` rows, or retired (T1) |
| `test/diff_compiler_capability_matrix.sh` scrapes emitter source | reads the catalog table (T1) |
| `wasm:emitter-gap` rows in `test/engine_divergence.txt` quoting `unbound variable` | drained; the program is refused at `check` (T2) |
| `test/diff_compiler_wasm_shim_parity_test.mdk` byte-diffs marked blocks | retired; import key set ⊆ profile slices, derived (T3) |
| `playground/main.js` hand list of shipped stdlib modules | generated from the catalog (T3) |
| `compiler/backend/wasm_file_grants.mdk` refuses pattern grants | deleted; the host enforces the grant (T3) |
| `test/wasm/diff_wasm_ffi_wall.sh`, one direction | both directions, check-time (T4) |
| no edge runner | a Node-simulated edge gate over the admitted corpus (T5) |

A new host import still lands under WH1: an inventory row in
`docs/spec/WASM-SEMANTICS.md` §3, a slice, and a catalog disposition.

## 11. Sequencing

T1 (the catalog is data) → T2 (availability is static) → T3 (one host shim) →
T4 (host bindings) → T5 (the edge profile).

T1 before T2 because the refusal needs a disposition to read. T2 before T3
because derived parity (§6.3) compares against the compiler's profile. T3 before
T4 because a user binding is a slice. T5 last because the edge's `Net` is a
binding. Within T2, #3666 (label-grain ratchet) can run alongside #3664 and
#3665; within T3, #3670 (fs slice receives the grant) follows #3668.

This work lands in the seam #2616 names — the plan record carrying extern
requirements and the target — and does not wait on the emitter rearchitecture's
other stages. It is unrelated to the typechecker rearchitecture's package 2.

## 12. Rulings (Val, 2026-10-01)

1. Availability is at **label** grain; the `WASM-GAP` rows are a ratchet to zero
   (§5.2).
2. JavaScript bindings use the **one `FFI` label with a host-qualified prefix**,
   not a second label (§7.2).
3. A target is selected by a **`[target]` key in `medaka.toml` with a `--target`
   CLI override** on `check`, `build` and `run` (§5.3).
4. **WASI p2 is a seam only** in this design; nothing is built for it (§8.4).
