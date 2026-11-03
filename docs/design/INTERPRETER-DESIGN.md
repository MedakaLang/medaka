# The interpreter: a bytecode VM over the native runtime

**Status:** PROPOSED 2026-11-02; direction chosen by Val the same day (option C of the
2026-11-02 strategy discussion: a GHCi-model interpreter that shares the native runtime).
Epic #4811; milestones `Interp: V0` to `Interp: V6` are listed in §12 with their issues;
the decisions in §11 are open until Val rules them on the epic. Nothing below is built.
Child issues cite this document's sections rather than restating them.

Medaka's `medaka run` is a tree-walking interpreter over the elaborated AST. It is the
engine agents are meant to reach for instead of `python3` and `sh` (epic #4617), and it is
the engine behind the REPL. It is too slow for that job by two orders of magnitude, it
re-typechecks every stdlib module on every start, and the REPL on top of it is a toy. This
document says what replaces it, what the replacement shares with the native compiler, how
the work is cut into modules, and what each module is allowed to be.

## 1. The measurements

Taken 2026-11-02 at `053ea4f71` on the build box, on the survey's regex-census port
(`port_02`, 44 lines of Medaka, 24 lines of Python; `#4617`'s corpus). Minimum of three runs.

| engine | wall | what it says |
|---|---|---|
| Python original | 0.03 s | the target is "within 10x of this" |
| the `medaka build` binary | 0.04 s | native code already meets the target |
| `medaka run` | 27.8 s | eval 27.4 s, 30 GB allocated, 582M interpreter ops |
| `medaka build` itself | 2.2 to 2.7 s | typecheck+lower+emit 0.7 to 0.9 s for 32k lines of IR (the prelude is 88% of it), clang 1.2 to 1.4 s |
| `medaka run` startup for the port | 0.37 s | load 0.10 s, typecheck of the four stdlib imports 0.28 s |
| `medaka run` startup for hello | 0.06 s | |

PR #4758 (merged the same day) removed the interpreter's quadratic costs and wrote in its
own report that further local tuning is not a credible plan. The structural reasons, from
a census of `compiler/eval/eval.mdk`:

- Values are a boxed Medaka ADT (`Value`, `eval.mdk`): constructors are matched by string
  name, records are association lists, 64-bit integers are two halves. `fib 25` allocates
  2.4 KB per call.
- Application is unary: an n-argument call allocates n closures and n frames, and every
  top-level group is a runtime tag-dispatched candidate list (`VMulti`).
- Lookup is by name through a frame list. Lexical addressing exists in Core IR
  (`CVar _ Addr`, produced by `compiler/types/annotate.mdk`) and is dormant in both
  evaluators.
- Calls recurse on the host C stack with a 25,000-frame counter and no tail calls;
  `list.reverse` overflows at 16k elements (#4655), `fs.walkDir` at 25k entries.
- The stdlib runs interpreted too: regex, TOML, JSON and `Map` are pure Medaka, so the
  interpreter pays the interpretation tax twice where Python pays it once and runs C.
- Only `core.mdk` ships a checked interface (`stdlib/core.mdki`); every other stdlib
  module is re-typechecked per process (#4630).

Calibration from other systems: OCaml's ZINC bytecode runs about 5 to 7x slower than
`ocamlopt`, and on a text-parsing job sits about 2x behind CPython while native OCaml is
slightly ahead of it. Python's text speed is its C builtins. "Within 10x of Python"
therefore means OCaml-bytecode-class interpretation **plus native libraries**, which is
exactly the combination GHCi has: interpreted code for what you are editing, compiled
packages for everything else, one heap and one calling convention between them.

## 2. The decision

**`medaka run` becomes a bytecode VM that executes on the native value layout, in the
native heap, against the stdlib compiled to native code.** The existing tree-walker stays
as the pure, deterministic differential oracle it already is (`compiler/ARCHITECTURE.md`
§5, D1 of #4617) and leaves every production verb.

What is shared with the native compiler, and therefore not reimplemented:

| shared | where it is today |
|---|---|
| the tagged-word value layout, cell headers, strings, arrays, refs, closures, partial applications | `runtime/medaka_rt.c`, `compiler/backend/llvm_emit.mdk`; written down in `compiler/RUNTIME-DESIGN.md` §8 (drifted, see §4) |
| the C calling convention `i64 f(i64 …)` and the generic apply `__mdk_apply` | `runtime/medaka_rt.c` |
| Boehm GC, the 256 MB worker thread, the signal handlers, stdout | `runtime/medaka_rt.c` |
| the extern catalog and every `mdk_*` runtime function | `compiler/backend/extern_catalog.mdk`, `compiler/backend/llvm_preamble.mdk` |
| Core IR, the per-emission Plan, the validators | `compiler/ir/`, `compiler/backend/emit_plan.mdk`, `compiler/backend/core_validate.mdk` |
| the typechecker and its shipped interfaces | `compiler/types/`, `compiler/tools/interface_cmd.mdk` |

What is new: a third backend that emits bytecode from Core IR, a C dispatch loop and
linker under `runtime/`, the stdlib built as a package (interfaces plus native objects)
and linked into the `medaka` binary, and a REPL that is a session rather than a re-run.

## 3. The execution model

### 3.1 Bytecode objects

A **bytecode object** (BCO, GHC's term) is the unit the VM loads: one per user module. It
holds a constant pool, the code of every function in the module with variables resolved to
frame slots, and a reference table naming what the module needs from outside: native
symbols by their module-qualified name, runtime externs by catalog name, type ids and
constructor tags, and dictionaries. References are resolved once at load (§3.5); after
linking, a call to a native function is a direct C call and a constructor test is an
integer compare.

The BCO has a serialised form so that it can be cached on disk later (GHC added `.gbc`
bytecode objects in 2025 for exactly this). V2 to V5 keep BCOs in memory; the cache is a
V6 measurement, not a commitment (§11, D5).

### 3.2 The machine

A **stack machine** over tagged words, the shape of GHC's `interpretBCO` and OCaml's ZAM.
A register VM executes fewer instructions but needs register allocation in the emitter;
it is declined for the first version and can be revisited with numbers (§11, D4).

- **Frames** live on a VM-owned stack registered with the collector, not on the C stack.
  A VM-to-VM call pushes a frame without C recursion. Every call Core IR marks as a tail
  call (`CallSite`'s tail flag, `compiler/ir/core_ir.mdk`) replaces the frame, so
  `list.reverse` over a million elements and `walkDir` over any tree run in constant
  stack. The native backend only eliminates self tail calls; the VM is stricter, which is
  permitted because the language's semantics never promised a stack overflow.
- **Calls** follow Core IR's `CallMode`: `CallExact` to a known function is a direct call
  (native symbol or BCO function); `CallPartial` builds the runtime's partial-application
  cell; `CallOver` saturates then applies; `CallDynamic` goes through `__mdk_apply`. The
  PAP layout and `__mdk_apply` are the runtime's, unchanged, so a partial application
  built by native code can be completed by the VM and vice versa.
- **Pattern matching** executes Core IR's decision trees (`CDecision`, `CTree`): a switch
  on the cell header, tuple and cons tests, literal compares. Leaves bind by slot.
- **Primitives** (`CBinPrim`, `CUnOp`) and the 38 catalog rows the LLVM backend emits
  inline (`Inline` in `extern_catalog.mdk`: `Ref`, `setRef`, the integer width
  conversions, the u64 bit operations, `arrayGetUnsafe`, `stringLength` and the rest)
  are opcodes. Overflow, division and bounds checks call the same C helpers the native
  code calls, so a trap message and exit code are identical on both engines.
- **Everything else** (176 `CSymbol` rows) is a C call to the `mdk_*` function the
  preamble declares, through a generated extern table (§3.5). Float math takes raw
  doubles behind an i64 wrapper exactly as the LLVM backend does.
- **Panics** print and exit as today; there is no unwinding on either engine.
- **Async** imposes nothing: the scheduler is pure Medaka over a `poll` extern
  (`docs/design/ASYNC-RUNTIME-DESIGN.md` R1), so the VM only needs closures and externs.

### 3.3 Closures: the GHCi rule

A VM closure is an ordinary native closure cell: `[arity | code_ptr | bco, captures…]`.
Its `code_ptr` is one of a fixed set of C entry stubs, one per arity up to the runtime's
`MDK_MAX_ARITY`, which push the arguments and re-enter the dispatch loop on the function
the cell names. Native code therefore calls a VM closure exactly as it calls any closure
(load field 1, call) and never knows the difference. This is GHC's `stg_BCO` info
pointer: the interpreter is just another entry code.

Re-entry from native into the VM nests on the C stack (OCaml's `caml_callback`); the VM's
own frames do not. The 256 MB worker stack bounds the alternation depth, not the
recursion depth.

### 3.4 Dictionaries, globals and types across the boundary

Three ABI facts are per-program today and must become per-package for interpreted code
and precompiled code to share them. Each is a fact with one producer (law A4).

1. **Type ids** are assigned in program-wide declaration order (`installTypeIds` in
   `llvm_emit.mdk`; `compiler/ir/constructor_facts.mdk`). A cell header is
   `typeId << 32 | ordinal`. The package's types get ids fixed at package build and
   recorded in its interface; a program's own types are numbered above the package
   range. The site-file table (`core_ir.mdk`, `(file+1) << 44` in a trap word) gets the
   same treatment.
2. **Dictionaries** are instance witnesses, `[hash(instance key) | supers… | requires…]`,
   and a method call through a runtime dictionary is an if-chain over the whole
   program's impl table (`mdk.dispatch.*` in `llvm_emit.mdk`). Precompiled stdlib code
   cannot dispatch to a user impl that way. The dictionary becomes a **method table**:
   `[hdr | method entries… | supers… | requires…]`, a method call through a dictionary
   loads a slot and calls it. The VM builds such a table for a user impl with VM closures
   in its slots, and native `show`, `compare` or `fold` on a user type works unchanged.
   The static case (a known instance) stays a direct call to `mdk.impl.*`, so native
   code loses nothing; the if-chain dispatchers are deleted. Precedent: GHC dictionary
   records, Swift witness tables, rustc vtables; `project_backend_dispatch_strategy`
   already anticipated the witness table at module boundaries.
3. **Globals** are initialised in `@mdk_program_main`'s prologue (eager) or by a forcer
   with a state byte (lazy, black-holed, E-CYCLIC-VALUE on re-entry). A package module
   gets its own initialiser run at load in dependency order (OCaml module
   initialisation); the VM's user globals are cells with the same state machine, so
   cyclic-value detection and the eager/lazy split (`compiler/backend/global_plan.mdk`)
   are identical on both engines.

### 3.5 Linking

The `medaka` binary links the whole stdlib as native code (every module, no dead-code
elimination, exported symbols) together with two generated tables: the package symbol
table (module-qualified name to address, emitted by the package build) and the extern
table (catalog name to `mdk_*` address and arity, generated from the preamble rows that
already declare every runtime function). The loader resolves a BCO's reference table
against the two, resolves type ids against the package's interface, and refuses with a
located error on anything unresolved. Precedent: OCaml's primitive table
(`caml_builtin_cprim`), GHC's RTS linker symbol tables.

Static linking is proposed over a shared library (§11, D6): one artifact, no `dlopen`,
one answer on Linux and macOS, and the binary's existing source fingerprint already
guards staleness (`[B-STALENESS]`).

### 3.6 What `medaka run` does, after

1. Load the entry and its imports; stdlib modules load their interface files, not their
   source (§5).
2. Typecheck the user modules only; stdlib facts come from the interfaces.
3. Lower the user modules to Core IR; validate; build the Plan.
4. Emit one BCO per user module; link against the package; execute `main`.

Expected cost for the regex port: steps 1 to 4 well under 0.1 s, execution within 10x of
native on interpretation-bound code and at native speed inside the regex engine, which
is what the target needs.

## 4. The ABI is a contract (V0)

The census found the ABI described in three places that disagree with the code:
`compiler/RUNTIME-DESIGN.md` §8 says the closure header is never inspected (it holds the
arity and `__mdk_apply` reads it); the emitter's comments name symbol families that were
renamed; there is no ABI version and no test that cross-checks the preamble's prototypes
against the C definitions. A second implementation of the layout cannot be built on that.

V0 therefore produces, before any VM code:

- one C header holding the layout: tags, header formulas, closure and PAP shapes, the
  reserved type ids, `MDK_MAX_ARITY`, an ABI version constant, with the static asserts
  the runtime already has moved next to the definitions. The runtime and the VM include
  it; the emitter's preamble renders from the same facts.
- a conformance test that the preamble rows and the C definitions agree on name, arity
  and float-unboxing, generated from one source the way `types/runtime_abi.mdk` already
  generates the Medaka-level extern shapes.
- the three per-package facts of §3.4 as Plan facts with validators, landed in both
  physical backends (they are twin facts; the wasm backend transcribes the same ids and
  method tables).
- `RUNTIME-DESIGN.md` §8 re-derived from the header, and the drifted comments fixed.

The dictionary change (§3.4 item 2) is the largest piece of V0 and is sequenced first
because V1's package and V3's interop both depend on it.

## 5. The stdlib is a package (V1)

Playbook decision D6 (`compiler/ARCHITECTURE-PLAYBOOK.md` §9) already accepts "one
interface file per stdlib module beside the sources, `core.mdk` first", OCaml's `.cmi`
form, and D7 keys each on the target profile's IO join. Only `core` has landed. What
Phase 3 ruled out (C3b-2) was a persisted store for user modules and a `medaka test`
hand-off; it did not touch D6. V1 completes D6 and adds the native half:

- `medaka interface write` generalised from the prelude's two-text key to a per-module
  key (module source, its imports' interface digests, compiler fingerprint, IO join),
  content-addressed per D7. The evidence-lineage normalisation #4284 names is a
  prerequisite, since a stdlib module's elaborated trees carry evidence rows.
- the loader prefers an interface whose key matches and parses the source otherwise, for
  every verb, so `check` and `build` gain the same startup as `run`.
- a **package emission mode** in the LLVM backend: every stdlib module, no DCE, exported
  linkage for module-qualified functions, impl methods, globals and forcers, a per-module
  initialiser, the symbol table of §3.5, type ids from the package range. It generalises
  and then retires the prelude-only `--emit-prelude-obj` halves (`emitHalf` in
  `compiler/entries/llvm_emit_modules_main.mdk`).
- `make medaka` builds the package and links it into the binary. `medaka build` for user
  programs keeps whole-program emission by default: the prelude-object measurements
  (`build_cmd.mdk`, dispatch +70%, intsum +300% without LTO) say separate objects cost
  native code real speed, and nothing here changes that choice.

V1 is worth landing on its own: it removes the 0.3 s re-typecheck from every verb.

## 6. Module layout

Val's standing rule for this work: no god module, interfaces decided before code, every
module with its own tests. The table follows the Phase 4 form (`feedback_phase4_six_principles`):
one responsibility per row, a precedent per row, a stated size budget (law A8: 3,000 code
lines, header reason above), and a test sibling per module (`[P-TEST-SIBLING]`).
Planned files are named without extensions; they do not exist yet.

### 6.1 Compiler side (Medaka)

| module | layer | owns | may import | precedent | tests |
|---|---|---|---|---|---|
| `backend/bc_isa` | backend, leaf | the instruction set as data: opcode rows (name, ordinal, operand shape, stack effect); renders the generated C opcode header | `support/` | OCaml `bytecomp/instruct.ml` + generated `instruct.h`; GHC `GHC.ByteCode.Instr` | ordinals unique, encoding round-trips, header text equals the checked-in file |
| `backend/bc_frames` | backend | frame layout per function: consumes the dormant `Addr` (frame, slot), computes slot counts and capture lists (flat closure conversion) | `ir/core_ir`, `support/` | GHC `StgToByteCode`'s `BCEnv`; OCaml `bytegen` stack discipline | slot assignment on nested lets, lambdas, letrec groups, or-patterns |
| `backend/bc_emit` | backend | Core IR + Plan to instructions: expressions, calls by `CallMode`, decision trees, prims, extern references | `bc_isa`, `bc_frames`, `bc_object`, `ir/`, `emit_plan`, `extern_catalog` | GHC `GHC.StgToByteCode`; OCaml `bytegen.ml` | per-construct emission goldens; every `CExpr` arm covered (`[T-GLOBAL-TABLE]`) |
| `backend/bc_object` | backend, leaf | the BCO: constant pool, code, reference table; encode and decode | `support/` | GHC `GHC.ByteCode.Asm`/`Types`; OCaml `emitcode.ml` | round-trip, malformed input refused with a located fault |
| `backend/package_plan` | backend | the package facts: export set, symbol-table rows, type-id and site ranges, module initialisation order; a Plan extension, one producer | `ir/`, `emit_plan`, `global_plan` | rustc crate metadata; OCaml `.cmx` export info | ranges disjoint, exports closed over references |
| `backend/emit_plan`, `core_validate`, `extern_catalog`, `emit_target` | backend | existing; gain a `vm` backend constructor, a `vm` catalog column and the package facts | unchanged | — | existing siblings extended |
| `backend/llvm_emit`, `wasm_emit` | backend | existing; transcribe method-table dictionaries, stable ids, package linkage and initialisers | unchanged | — | existing gates; `twins.golden` may only fall |
| `tools/run_cmd` | tools | the `run` verb's pipeline: load, check, lower, emit BCOs, link, execute; today's 270 lines of `runRunCmd` leave `driver/medaka_cli.mdk` | `driver/`, `backend/bc_*`, the VM externs | `lint_cmd`, `gate_cmd` (the de-grab-bag shape) | engine selection, refusal paths, exit codes |
| `tools/engine_table` | tools | existing; gains the `vm` row | unchanged | — | existing sibling |
| `tools/repl_session` | tools | the session as a value: ordered input modules, bindings, `it`, redefinition rules (§8) | `driver/`, `backend/bc_*` | GHCi `GHC.Runtime.Eval`; Scala's per-line wrapper objects | shadowing, instance redefinition refused, `it` |
| `tools/repl` | tools | commands, prompt, multi-line reading, rendering; rewritten over `repl_session` | `repl_session` | GHCi `GHCi.UI` | command parsing, the six open REPL issues as pinned cases |
| `entries/vm_main`, `entries/vm_modules_main` | entries | thin probes: argv, one pipeline call, print | — | the `eval_*_main` probes | driven by the gates |

`bc_emit` is the module most likely to grow. Its named split points, to be taken before it
crosses the A8 line: decision-tree emission to `bc_emit_match`, dictionary and impl
emission to `bc_emit_dicts`. An unexplained append past the line is a review finding.

### 6.2 Runtime side (C)

`runtime/medaka_rt.c` is one 4,600-line file. The VM does not join it. A `runtime/vm/`
directory, each file under about 1,500 lines, with the shared layout header above both:

| file | owns | precedent |
|---|---|---|
| `runtime/medaka_abi` (header) | the value layout, tags, closure and PAP shapes, reserved ids, ABI version; included by the runtime, the VM and the conformance test | GHC `rts/include/rts/storage/Closures.h` |
| `runtime/vm/opcodes` (generated header) | the opcode numbering, rendered by `bc_isa`; checked in with a drift test | OCaml's generated `instruct.h` |
| `runtime/vm/interp` | the dispatch loop (computed goto), the primitive opcodes, trap calls | OCaml's `interp.c`; GHC `rts/Interpreter.c` |
| `runtime/vm/stack` | the VM stack: allocation, growth, collector registration, frame layout | GHC's STG stack chunks |
| `runtime/vm/link` | BCO loading, reference resolution against the symbol and extern tables, type-id binding, load-time refusal | OCaml `fix_code.c`; GHC `rts/Linker.c` |
| `runtime/vm/enter` | the per-arity entry stubs that make a VM closure a native closure; VM global cells and their forcers | GHC `stg_BCO` entry; OCaml `caml_callback` |
| `runtime/vm/externs_table` (generated) | catalog name to address, arity, float-unboxing, generated from the preamble rows | OCaml `caml_builtin_cprim` |

The VM talks to the compiler through two internal externs (load a linked program from a
BCO set, run `main`), declared like the other internal-only externs and refused outside
the compiler. Nothing in `runtime/vm/` includes the compiler, and nothing in the compiler
includes C.

### 6.3 Laws this layout satisfies

- **A1 layering:** `bc_*` and `package_plan` sit in `backend/`, importing `ir/` and
  `support/`; `run_cmd` and the REPL sit in `tools/`; the driver gains a route and
  loses an implementation. The `eval -> driver` and `ir -> eval` edges are untouched.
- **A2 output is a value:** a BCO is a value; the package plan is a value; the VM reads
  them and writes nothing back.
- **A4 one fact, one producer:** type ids, site ranges, method-table layouts and export
  sets are Plan facts with validators; three backends transcribe them.
- **A7 compute once:** interfaces per stdlib module close the "prelude ships pre-checked"
  exception for the rest of the library.
- **A8 modules are concerns:** every row above is one responsibility with a budget;
  `llvm_emit.mdk` grows only by transcription of new Plan facts, with the reason stated
  in each PR.
- **A9 goldens:** each new leaf gets a closure golden; the `vm` catalog column gets the
  same gate test as the others.
- **A10 documentation:** `runtime/` gets a directory map; this document moves to
  `archive/design/` when its status becomes IMPLEMENTED.

## 7. Engines, gates and the oracle

After V4 there are four engines:

| engine | runs | role |
|---|---|---|
| `eval` (tree-walker) | gates only, behind `--engine eval` | the pure deterministic oracle; frozen; `externBindings` canned by design |
| `vm` | `run`, `repl`, `test --engines vm` | the production interpreter; binds the native extern catalog |
| `native` | `build`, `test` default | unchanged |
| `wasm` | playground, `build --target wasm` | unchanged |

- The engines differential (`test/lib_engines_differential.sh`) gains the `vm` arm: eval,
  vm, native and wasm must agree on every fixture corpus. During V2 and V3 the arm runs
  on the corpora the VM can execute and the rest is a named gap, never a silent skip
  (`[L-PHANTOM-SKIP]`).
- `compiler/tools/engine_table.mdk` and the capability matrix gain the `vm` column. The
  30 externs `run` refuses today (`refusedOnRun`: `runCommand`, the `net*` family,
  `assertSnapshot`, `fetchText`) are a **policy** list, not an engine gap, once the VM
  binds the native catalog. The posture is unchanged by this design: the same set stays
  refused until #4414 rules the exec gate, and the refusal message says "refused by
  policy" rather than "the engine lacks it". Widening silently would be a severity
  increase (`[W-QUIETER]`).
- The interpreter-specific gates (`diff_compiler_eval_scaling.sh`, the `eval_*` fixture
  corpora, `profile_eval_main`) keep running on `eval`; `vm` gets its own scaling arm
  with a recursion-depth shape, which #1033 notes no arm has today.

## 8. The REPL (V5)

Today's REPL (`compiler/tools/repl.mdk`) re-runs resolve, typecheck and eval over the
prelude plus every accumulated declaration on every line, classifies input by a token
heuristic, cannot import, cannot load a file, and has six open issues (#4320, #4425,
#4198, #4400, #4424, #4737). It is replaced, not patched.

- **A session is a sequence of modules.** Each input becomes a module that imports every
  earlier one (Scala's wrapper-object model, which gives predictable redefinition: a new
  `x` shadows the old, closures built earlier keep the old, and a redefinition of a type
  or an instance that a live binding depends on is refused with the dependent named, as
  GHCi refuses by reloading). Values live in the VM heap across inputs.
- **Typechecking is incremental** through the driver's memoised entries (A7): only the new
  module is checked; the stdlib comes from interfaces.
- **`it`** binds the last expression's value; `:type`, `:info`, `:browse` read the
  session's published schemes; `:load` loads a module graph (user modules as BCOs, stdlib
  native) and `:reload` re-checks by fingerprint and relinks.
- **Agents are the first users.** A machine-readable session protocol (one input, one
  JSON reply) sits beside the human prompt, and `medaka mcp` exposes it as a session
  tool. Line editing and history for humans are a separate, later item (§11, D8).

## 9. Acceptance

V4 is met when, on the build box:

| check | target |
|---|---|
| survey ports `port_02` (regex census) and `port_04` (TOML grouping) on `run` | within 10x of Python (about 0.3 s and 0.4 s), output byte-identical |
| `run` startup, the four-import probe of #4630 | under 0.1 s |
| `list.reverse` over 1,000,000 strings; `fs.walkDir` over 100,000 entries on `run` | completes; #4655 and #1033 close |
| `fib 25` on `run` | within 10x of native |
| engines differential | eval, vm, native, wasm agree on every corpus |
| `compiler/PERF-RESULTS.md` | a dated section with the method, as #4758's |

V5 is met when every scenario in the six open REPL issues passes as a pinned test and an
agent can drive a session through `medaka mcp`.

## 10. Language changes this design asks for

Val ruled on 2026-11-02 that language-level changes are on the table for this work. Four
are worth taking because each removes a place where `run` and `build` would otherwise
behave differently, and one is a rule to keep rather than a change to make. Each is a
decision in §11 (D10 to D13); each changes `docs/spec/` and is filed as its own issue.

- **L1. Top-level values initialise strictly, in dependency order.** Today a top-level
  nullary binding is lazy (`lazy-toplevel-nullary-canonical`): a thunk in `eval`, a forcer
  with a state byte natively, black-holed, with E-CYCLIC-VALUE as a runtime trap. The
  reason was install order, not semantics: declarations are order-independent, and
  laziness let the engines avoid computing an order. `global_plan.mdk` already computes
  that order (the SCC of eager references) and sends only the cyclic, self-referencing or
  method-reaching values to the lazy path. Under L1 the order is the semantics:
  initialisers run in dependency order (OCaml's module initialisation), a value cycle is
  a static error at the declaration, and the forcer, the state byte, `VThunk` and the
  runtime cyclic-value trap all go. Four engines then share one rule with no state
  machine. Open question for the spec: whether a top-level value may perform an effect
  at initialisation (today it can only do so when forced); the recommendation is no,
  matching Haskell's and OCaml's "top-level values are pure or explicitly deferred".
- **L2. Proper tail calls are a language guarantee.** The VM gives every tail call constant
  stack (§3.2); the native backend today guarantees only self tail calls and TRMC and
  leaves the rest to clang. Without L2, a program that runs on `run` can overflow on
  `build`, which is a silent engine difference of exactly the kind the engines gate
  exists to forbid. Under L2 the native backend emits `musttail` for every Core-marked
  tail call, which the uniform `i64 f(i64 …)` convention makes possible, and the wasm
  backend uses `return_call`. OCaml and GHC both guarantee it on bytecode and native.
  The spike is whether `musttail` holds across differing arities under the SysV
  convention; if it needs `tailcc` on every Medaka function, that is an ABI change for
  V0, not a reason to drop the guarantee.
- **L3. A session module may shadow an import.** The REPL's "each input is a module that
  imports every earlier one" needs a definition in input N to shadow the same name
  imported from input N-1, which the selective-import shadow rule (#4624) refuses in an
  ordinary module. Either a REPL-only relaxation (GHCi's model) or a language rule that
  a local definition shadows an imported one with a warning. The recommendation is the
  REPL-only relaxation, so no ordinary module's meaning changes.
- **L4. Every method site is routed; the runtime never dispatches on an argument's tag.**
  `RNone` routes dispatch at run time on the cell header ("a pinned refining
  optimisation until its owning evidence work replaces it", `ARCHITECTURE.md` §5). Stable
  type ids keep it working across the package boundary, so this design does not need
  it gone; but with every site routed, a dictionary is the only dispatch mechanism in
  all four engines and the header carries no semantic weight at all. This is
  typechecker-owned work (`project_backend_dispatch_strategy`) and can land any time.
- **L5. The rule to keep: nothing in the language needs whole-program knowledge.** The
  census found no feature whose meaning depends on seeing the whole program (dictionary
  passing, not monomorphisation; coherence per instance; DCE is not semantic). V1 makes
  the stdlib separately compiled, so this becomes a law: a new feature whose semantics
  needs the whole program (specialisation-dependent meaning, global instance resolution
  at link time) is a design finding, not a sprint slice.

## 11. Decisions for Val

Each is recorded on the epic with the option taken. The recommendation is first.

- **D1. Engine identity.** The VM shares the native runtime; `eval` stays the oracle.
  *Chosen 2026-11-02 (option C).* A runtime bug now reaches `run` and `build` alike;
  `wasm` stays an independent third engine and `eval` an independent fourth.
- **D2. Dictionaries.** (a) method tables, replacing the witness hash and the if-chain
  dispatchers in both physical backends; or (b) keep witnesses and add a runtime registry
  the if-chain falls back to for impls it does not know. Recommend (a): it is what every
  mature implementation does, it makes dynamic dispatch O(1) on native code too, and (b)
  leaves two dispatch mechanisms alive.
- **D3. VM language.** (a) C under `runtime/vm/`, bytecode generated in Medaka; or (b) the
  loop in Medaka over raw-word externs. Recommend (a): GHC and OCaml both keep the loop
  in C beside self-hosted compilers; (b) needs unsafe word primitives the language does
  not have and would run the loop through the same code generator it is meant to replace.
- **D4. Machine shape.** Stack machine first; a register machine is a measured follow-up.
- **D5. Bytecode caching.** In memory through V5; an on-disk BCO cache (GHC's `.gbc`) is a
  V6 item taken only if V4's startup numbers ask for it.
- **D6. Package linkage.** The stdlib package is statically linked into `medaka`; a shared
  library loaded on demand is the alternative if binary size proves a problem.
- **D7. Exec posture.** Unchanged by this design; #4414 rules it. The VM makes the refusal
  a policy statement rather than an engine gap.
- **D8. The agent surface of the REPL.** (a) an MCP session tool over a JSON-lines
  protocol; (b) a `repl --json` mode only. Recommend (a), since agents already reach the
  compiler through `medaka mcp`.
- **D9. `medaka test`'s default engine** stays native. Moving it to the VM would trade
  clang's per-file cost for interpretation; decide after V4 with the engines gate's
  numbers, not before.
- **D10. L1, strict ordered top-level initialisation.** Recommend yes, with top-level
  values pure at initialisation; lands in V0 with the globals work.
- **D11. L2, proper tail calls guaranteed by the language.** Recommend yes; the native
  `musttail` spike is the first V2 slice and its result decides whether V0's ABI needs
  `tailcc`.
- **D12. L3, how a session module shadows an import.** Recommend the REPL-only
  relaxation; lands in V5.
- **D13. L4, retire runtime argument-tag dispatch.** Recommend yes but unsequenced: it is
  typechecker work and this design does not depend on it.

## 12. Milestones

| milestone | delivers | done when | issues |
|---|---|---|---|
| Interp: V0 (the ABI is a contract) | the layout header, the conformance test, the ABI version, method-table dictionaries, stable type and site ids, per-module initialisers, `RUNTIME-DESIGN.md` §8 re-derived | both physical backends emit the new layout; every engines gate green; the header is the only definition of the layout | #4783 #4784 #4785 #4786 #4787 #4788 #4789; #4790 found by the census |
| Interp: V1 (the stdlib is a package) | per-module interface files (D6 completed), the package emission mode, the symbol table, `make medaka` links the package | no stdlib module is typechecked in a `check`, `run` or `build` process (`stage_counts.golden`); the four-import probe starts under 0.1 s | #4791 #4792 #4793 #4794 |
| Interp: V2 (the VM runs pure programs) | `bc_isa`, `bc_frames`, `bc_emit`, `bc_object`, the generated opcode header, `interp`, `stack`, the probes | the pure fixture corpora agree with `eval` through `vm_main`; a million-element reverse and a million-deep non-tail recursion complete | #4795 #4796 #4797 #4798 #4799 |
| Interp: V3 (the VM and native code call each other) | `link`, `enter`, the extern table, method tables for user impls, VM globals | every `run`-capable corpus agrees across all four engines; `run --engine vm` runs the survey ports | #4800 #4801 #4802 #4803 |
| Interp: V4 (run is the VM) | the default flip, `run_cmd`, the engine table, the policy wording, the perf section, the architecture maps | §9's table | #4804 #4805 #4806 |
| Interp: V5 (the REPL is a session) | `repl_session`, the rewritten `repl`, `:load`/`:reload`, `it`, the MCP session tool | the six REPL issues pass as pinned tests; an agent drives a session | #4807 #4808 #4809 |
| Interp: V6 (measured follow-ups) | the BCO cache, superinstructions and inline caches, a register machine, `test` on the VM, a cached-native `run` (#4631's D2) | each taken only on a number from V4 | #4810 |

The epic body (#4811) carries the same table and the decision checkboxes of §11.

## 13. Not in scope

- The playground: it compiles in the browser through the wasm backend and never runs the
  interpreter. It receives the twin ABI changes (ids, method tables) and nothing else.
- Monomorphisation: dictionary passing stays (`project_backend_dispatch_strategy`); method
  tables are its open-world form, not a step away from it.
- A JIT: the native backend is the fast path and a cached-native `run` is V6's call.
- The exec policy (#4413, #4414): a sibling decision the VM makes easier to state.
- Catchable panics, cancellation, threads: unchanged language decisions.

## 14. An example

The interop case the whole design exists for: a user impl, a stdlib function compiled
natively, a lambda interpreted by the VM, one call chain.

```medaka-nocheck: illustrates which engine runs which line; Point and showAll are sketches, not a standalone program
data Point = Point Int Int

impl Display Point where            -- the VM builds a method table; `display` is a VM closure
  display (Point x y) = "(" ++ display x ++ ", " ++ display y ++ ")"

showAll : List Point -> String       -- user code: bytecode
showAll ps = join ", " (map display ps)
                                     -- `map` and `join` are native stdlib code; `map`
                                     -- calls the VM closure through its entry stub;
                                     -- `display` on Int is a direct native call
main = println (showAll [Point 1 2, Point 3 4])
```

Nothing in the chain marshals a value, and the only new runtime objects are the method
table and the two closures.
