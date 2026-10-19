# Playground animation implementation plan

**Status:** READY FOR SPIKE — subsequent slices depend on its measured result.

Design: [Playground canvas and animation](PLAYGROUND-ANIMATION-DESIGN.md).
Planning base: `31f730fa4b186424d919e1d469e6cc64e95a40b5` (2026-10-19).
Tracking: [#4328](https://github.com/MedakaLang/medaka/issues/4328).
This is the durable implementation blueprint. At execution, the orchestrator
copies the relevant release boundary into its writable scratch `CONTRACT.md`,
records the then-current base, and creates one-page packets just in time using
[sprint-packet](../../.claude/skills/sprint-packet/SKILL.md) and
[the Codex adapter](../../.codex/SPRINT.md). Do not dispatch from this planning
SHA after another slice lands. Implementation has not started.

## 1. The question

Can a visitor write a pure scene or model/update/view program in Medaka, compile
it in the playground, and run an interruptible canvas animation without new
language syntax or a callback ABI?

Use two serial sprints, each small enough for one end review. Sprint A establishes
execution and library semantics; Sprint B delivers the user experience. Do not
run independent writers against the shared host, fixture corpus, or registry.

## 2. Scope and model selection

In: the design's scalar bindings, persistent guest session, bounded frame
protocol, library API, canvas controls, pointer input, three examples, tests,
packaging, and documentation. No compiler source change is presumed.

Out: general callbacks/foreign exports (spike-dependent redesign), JSVal and
DOM bindings (unneeded ownership surface), WebGL/WebGPU and OffscreenCanvas
(unmeasured need), image/audio/network assets (separate lifecycle), production
deployment (release action), and unrelated open compiler defects (separate
repro/fix work when encountered).

User model selection overrides the adapter's default implementation tier:
`sprint_implementer` with `gpt-6.1-sol`, high, for S1–S5; `gpt-6-luna`, medium,
for S6's mechanical packaging/documentation work. If unavailable in the execution
harness, record the actual available Sol/Luna mapping before dispatch. Do not
silently substitute Terra. Use the configured Sol sprint reviewer at each sprint
boundary. Luna receives settled paths and expected results, not protocol choices.

## 3. Slice contracts

The design's module table and signatures are the shape contract for every slice.
Paths below are approximate ownership, with proposed files named separately
from their directory. Each packet must include direct consumers, test enrollment,
and any licensed generated outputs found at dispatch time.

### Sprint A: prove and implement the execution model

| Field | S1 — prove-frame-reentry |
|---|---|
| Mission | SPIKE-FIRST. Prove repeated real playground-compiled entry, frame input freshness, model persistence, and reset. Produce the smallest evidence for any refusal. |
| Surface | Scratch sources and harness using existing `playground/compile.mjs`, assembler, and `medaka_host.mjs`; no production code or compiler edits. Probe the proposed pure callbacks and top-level Simulation shape. |
| Acceptance shape | Four checks: (1) three calls yield line endpoints 0, 10, 20 at times 0,1,2; (2) a captured model cell yields initial 0 then 1 then 2, fresh instance starts at 0; (3) console-only program prints once under a one-shot host; (4) same entry/input results with JSPI unavailable. Validate emitted WASM and assert no compile diagnostics. |
| Model | Sol/high: resolve whether entry semantics, closure capture, and top-level state actually support the proposed library contract. |
| Depends-on / parallel-ok | First. Serial. |
| Decision output | Report exact source, source/binary fingerprints, commands, outputs, and supported API spelling. On success freeze §4–§6 of the design. On failure replan; do not dispatch S2/S3 on a workaround that violates §8. |

| Field | S2 — persistent-session-and-frame-host |
|---|---|
| Mission | Add reusable entry sessions and a bounded scalar drawing host without changing one-shot behavior. |
| Surface | Extend `playground/medaka_host.mjs` at `runProgram`; add `animation_protocol.mjs` and `animation_host.mjs` in `playground/`, with sibling Node tests. Extend `test/wasm_host_probes_test.mdk` and its registry source list to execute the tests. No DOM/UI code. |
| Acceptance shape | Four groups: (1) existing host probes pass; (2) session persists state, refuses overlap/disposed/poisoned entry, retains JSPI and error/flush semantics; (3) protocol accepts a known complete frame and rejects bad ordering, nonfinite values, versions, and each budget overflow; (4) guest trap after end produces no batch and preserves stderr. |
| Model | Sol/high: persistent-session failure and disposal semantics cross existing async and synchronous paths. |
| Depends-on / parallel-ok | S1 success. Serial. |
| Shape | Implement the design's session API and two host/protocol modules. Keep the FFI wrapper and signature interpretation in the existing host; do not duplicate them in graphics code. |

| Field | S3 — graphics-and-animation-library |
|---|---|
| Mission | Implement the pure picture API and effectful frame adapters, including retained Simulation state. Prove them using actual WASM compilation. |
| Surface | New `graphics.mdk`, `canvas_host.mdk`, `animation.mdk` and pure `*_test.mdk` siblings in `stdlib/`; a proposed `animation_integration_test.mjs` under `playground/`; fixtures owned by this feature, outside shared engine corpora. Enrollment described in §6. |
| Acceptance shape | Four groups: (1) pure geometry/model tests and explicit typechecks; (2) static, time-based, viewport/pointer, and Simulation sources compile through browser compiler + assembler and produce specified commands; (3) independent instances and repeated runs have independent models, globals initialize once, and pure callbacks remain pure; (4) native/render-without-bindings routes refuse clearly while pure graphics remains usable. |
| Model | Sol/high: finalize the supported type/effect spelling from S1 without losing the agreed lifecycle or introducing an FFI closure. |
| Depends-on / parallel-ok | S2. Serial. |
| Shape | Exact module ownership and public signatures are in design §3–§4. `canvas_host` may not import `animation`. Simulation retains model inside its own guest instance, never a global JS table. |

Sprint A exit: first three contracts met; session API regression-tested; no
canvas UI needed yet. One end review and fix round, then normal PR/merge flow.

### Sprint B: integrate and publish the example surface

| Field | S4 — canvas-controller-and-playground |
|---|---|
| Mission | Wire the persistent runner to a canvas with bounded scheduling, input, lifecycle controls, and unchanged console behavior. |
| Surface | Add `animation_controller.mjs`, `canvas_renderer.mjs` and sibling Node tests under `playground/`; extend `worker.js`, `main.js`, `index.html` and its existing stylesheet. Add `animation.spec.mjs` under `playground/e2e/` and wire the existing e2e orchestrator. Update asset/header paths immediately when imports are introduced. |
| Acceptance shape | Five groups: (1) fake-clock controller proves one outstanding tick, pause time, zero resume delta, watchdog, stale compile/result rejection; (2) recording canvas proves drawing order, clearing, y-up transform and resize revision handling; (3) browser tests prove changing pixels and Run/Stop/Pause/Resume, runaway termination, error recovery and resize; (4) existing console/runaway/async regressions pass; (5) reduced motion, hidden-tab/manual-pause interaction and primary pointer cancellation work. |
| Model | Sol/high: lifecycle races and page/worker ownership are the main correctness decision. |
| Depends-on / parallel-ok | Sprint A integrated; S3. Serial. |
| Shape | Controller exports and dependency injection are fixed in design §3. The worker only routes and executes; the page never executes user WASM. `main.js` remains UI glue. |

| Field | S5 — examples-and-browser-proof |
|---|---|
| Mission | Ship the cube, Lissajous, and bouncing-balls programs and demonstrate the full contract in the three browser engines. |
| Surface | New `animation_examples.mjs` in `playground/`, consumed by `main.js`, integration tests, and browser tests. Extend animation tests and the cross-engine smoke path. A short explanatory guide belongs in the existing guide/advanced structure chosen from its current index. |
| Acceptance shape | Four groups: (1) every example compiles via the real browser compiler and produces differing frames at fixed inputs; (2) independent expected cube projections, curve samples, and ball collisions match with numeric tolerances; (3) shared source restores and runs each example, pointer input changes the intended output; (4) Chromium, Firefox, and WebKit show canvas changes, Stop, and a clean rerun; record a bounded performance sample with guest/transport/replay costs separated. |
| Model | Sol/high: establish independent geometric/model oracles and judge rendering/performance evidence. |
| Depends-on / parallel-ok | S4. Serial. |
| Shape | JavaScript owns only an id-to-source map. All geometry and model logic remain visible in the editable Medaka programs. Do not add a public 3D subsystem for one cube. |

| Field | S6 — package-and-document |
|---|---|
| Mission | Reconcile site packaging, headers, generated reference/index, and usage documentation with the already-tested implementation. |
| Surface | Existing `playground/build_site.sh`, `playground/build_playground_wasm.sh`, `playground/_headers`, `playground/README.md`; generated stdlib reference/index and docs index. The packet must list the exact source/asset roster frozen by S5. |
| Acceptance shape | Four groups: (1) header-rule test passes for transitive imports; (2) fresh compiler assets and built site contain every declared module/example/JS dependency; (3) built-site browser smoke runs the three examples, with no dev-tree fallback; (4) documentation links/index pass and all published Medaka snippets compile. |
| Model | Luna/medium: mechanical roster and documentation reconciliation; no architecture decisions remain. |
| Depends-on / parallel-ok | S5. Serial. |
| Shape | Extend existing build machinery, never add a new deployment script. If packaging exposes a runtime defect, report it for a corrected Sol packet rather than redesigning it here. |

## 4. Checked facts and unresolved premises

Checked-at paths/lines refer to the planning base; commands below reproduce the
inspection. They establish source facts only. S1 supplies runtime evidence.

| Fact | Checked-at | Proving command |
|---|---|---|
| Entry is split and documented as re-entrant on one instance. | `compiler/backend/wasm_emit.mdk:3546`, `:3595` | `sed -n '3546,3610p' compiler/backend/wasm_emit.mdk` |
| Browser compiler already preserves an instance across calls. | `playground/compile.mjs:110` | `sed -n '110,205p' playground/compile.mjs` |
| One-shot host wraps entry/flush/error handling. | `playground/medaka_host.mjs:1246` | `sed -n '1240,1280p' playground/medaka_host.mjs` |
| Host accepts a supplied JS binding map. | `playground/medaka_host.mjs:1052` | `sed -n '1048,1058p' playground/medaka_host.mjs` |
| Runner creates a host without canvas bindings, then runs once. | `playground/worker.js:65` | `sed -n '60,100p' playground/worker.js` |
| Current page deadline is total-run, 10 seconds. | `playground/main.js:26`, `:495` | `rg -n 'RUN_TIMEOUT_MS|killTimer|runBtn.disabled' playground/main.js` |
| Extra stdlib imports share the compile/editor VFS. | `playground/compile.mjs:88` | `sed -n '88,110p' playground/compile.mjs` |
| Callback ABI and arbitrary async JS bindings are outside FFI v1. | `docs/design/TARGETS-DESIGN.md:489` | `sed -n '489,503p' docs/design/TARGETS-DESIGN.md` |
| Host probes already have a merge-tier native gate wrapper. | `test/gates.toml:2946` | `sed -n '2946,2962p' test/gates.toml` |
| Browser e2e is locally skipped by ordinary preflight; explicit execution is required. | `test/preflight.sh:1953` | `sed -n '1953,1961p' test/preflight.sh` |

Unproved: the proposed Simulation representation compiles with pure callbacks;
every required high-arity scalar binding lowers through the browser path; frame
performance meets the demo target. S1/S3/S5 own these respectively. No statement
in this table licenses skipping their acceptance checks.

Backlog was read on 2026-10-19 with `gh issue list --label 'S0: silent wrongness'
--state open`, the `ws:wasm` equivalent, and an animation/canvas/callback search.
No existing canvas implementation issue was found in that search. Relevant open
risks included [#3195](https://github.com/MedakaLang/medaka/issues/3195) (nested
partial applications in records), [#3203](https://github.com/MedakaLang/medaka/issues/3203)
(Ref representation reach), [#4183](https://github.com/MedakaLang/medaka/issues/4183)
(effectful top-level value), and [#3529](https://github.com/MedakaLang/medaka/issues/3529)
(WASM guard scratch locals). These are probes to consider, not asserted blockers
or an instruction to fix unrelated issues. Refresh their state before execution;
never infer that any one explains a failure without reproducing it.

## 5. Packet, tracking, and closure policy

At dispatch, give each agent a prepared isolated worktree at the exact current
sprint head, owned paths, model, report location, and 3–5 concrete check commands.
The six packet sections are Identity, Setup, Mission, Already settled, Sites,
Acceptance. Future packets must fill actual paths/SHAs; this plan deliberately
does not invent them. Agents are not alone in the repository and must preserve
others' changes. Slices execute serially and do not merge main into their branch.

Keep this design as the specification; GitHub tracking owns work status. Mirror
the slice checklist into the tracking issue, linking the eventual design PR.
Close only when each acceptance group has evidence at the final reviewed head.
A spike success does not close implementation. A discovered compiler defect gets
its own minimal reproducer and issue; no existing pin is removed because an
example avoids the failing shape.

At completion, move implemented design records to `archive/design/` according to
the architecture policy, leave current user instructions beside the playground
and in the published guide, and regenerate the index.

## 6. Test execution and expected reds

No expected-red implementation gates are licensed. Missing WASM/compiler/browser
assets are setup failures, not passing skips. A known-red unrelated gate must
have its current issue checked and be recorded separately.

Use native Medaka sibling tests for pure graphics and models; use `expectEqual`
for exact values and `expectWithin` for floating-point tolerances. Explicitly
typecheck as well as running tests. Enroll new siblings in the existing Makefile
test roster where discovery does not include them. Never claim eval/native tests
prove WASM behavior.

Extend the existing `wasm_host_probes` gate to run protocol/session/controller
Node tests through its native wrapper; grade exit and a nonzero executed-case
floor with `expectSpawnOk`/`expectFloor` as applicable. Update the gate's sources
to cover all new modules and fixtures. Explicitly invoke the new browser-compiler
animation harness from `test/wasm/diff_playground_input.sh`, after its fresh build,
and propagate its exit status into the gate result. That gate currently has inline
Node harnesses; it does not invoke `playground/client_flow_test.mjs`. Verify the
actual invocation chain: adding a test file alone does not enroll it. Browser e2e
cases must be invoked by
`playground/e2e/lib/run-server-and-tests.mjs` and the cross-engine smoke route.

Before build/gates, fmt and lint touched Medaka with absolute paths. Build in
the assigned worktree; assert freshness. Use packet-targeted checks, then derived
preflight unless stdlib blast radius means CI must run the full set. Do not run
the full suite locally. Gate registry checks and the adapter's standing checks
still apply. If a new gate is actually required, obtain its cost sample, balance,
generate CI, and commit the derived outputs before merge; never hand-assign its
final shard or defer an uncosted required check.

Useful existing check entry points for packet authors:

```sh
node playground/medaka_host_test.mjs
node playground/headers_rules_test.mjs
sh test/wasm/diff_playground_input.sh
bash playground/e2e/run.sh
SITE=1 bash playground/e2e/run.sh
make docs-links
make docs-index
```

These are a menu, not a requirement to run all per slice. New tests get explicit
commands once they exist. Browser checks run against freshly built assets from
the reviewed source. Preserve built-site results separately from dev-tree ones.

## 7. Exit criteria and review assignment

Final review attacks these domain properties, with actual tests and independently
chosen expected results:

- Entry reuse: model persists, init runs once, new Run resets, trap poisons state.
- Temporal behavior: time units, no frame-count dependence, hidden-tab pause,
  bounded delta, one outstanding frame, no accumulated input/tick queue.
- Protocol integrity: transaction closes only on guest success, malformed values
  and budget overflows fail before presentation, direct extern calls obey rules.
- Lifecycle races: Stop during compile, late compile completion, late worker
  stdout/frame/error, pause in flight, resize in flight, and repeated Run.
- Containment: a guest loop can be terminated while controls remain usable;
  no unrestricted JS/DOM access is introduced through bindings.
- Visual semantics: known geometric output, actual pixels change, pointer mapping
  and DPR work, state and transforms do not leak across frames.
- Distribution: all three examples work from a share URL and the assembled site
  in Chromium/Firefox/WebKit; imported modules resolve in editor tooling too.
- Regression: console output, diagnostics, existing sleep behavior, one-shot
  hosts, and non-browser target refusals retain their contracts.

Require one end review/fix round per sprint and normal required CI/merge queue.
Report representative performance measurements without turning noisy wall-clock
numbers into a merge gate. No production deploy is part of completion.
