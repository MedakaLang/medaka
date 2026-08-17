#!/usr/bin/env python3
"""UserPromptSubmit hook: nudge skill triage on roadmap/Phase and stdlib tasks.

Injects a carve-out-aware reminder to load the matching task-playbook skill
*before* planning. It poses the triage question — it does not make the routing
call, because where a change actually lands is only knowable after exploration
(see AGENTS.md's harden-typechecker / extend-stdlib carve-outs)."""
import sys, json, re

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

prompt = data.get("prompt", "") or ""

# Roadmap/Phase task. Catches a bare "implement phase 65 in PLAN.md".
roadmap = re.search(r"PLAN\.md|phase\s+\d", prompt, re.IGNORECASE)

# Stdlib task: STDLIB.md by name, or "stdlib" with an authoring verb. Pure-Medaka
# stdlib edits and native externs route to different skills, so still a triage.
stdlib = re.search(r"STDLIB\.md", prompt, re.IGNORECASE) or (
    re.search(r"\bstd(?:lib| library)\b", prompt, re.IGNORECASE)
    and re.search(r"\b(implement|add|write|extend|complete|finish|port)\b",
                  prompt, re.IGNORECASE)
)

# MCP-tool-shaped task (#847): the medaka MCP server (compiler/tools/mcp.mdk)
# exposes check/type_at/symbols/definition/references/fmt/lint/test as
# mcp__medaka__* tools, but nothing maps a task's SHAPE to the matching tool
# at decision time -- the model defaults to grep/Bash even with a working
# tool present. Narrow, verb-anchored triggers (not "any .mdk mention") so
# this doesn't nudge on every prompt in the repo.
mcp_check = re.search(r"\btype-?check|\bdoes\s+(it|this(?:\s+file)?|the\s+file)\s+(parse|compile|typecheck)\b",
                       prompt, re.IGNORECASE)
mcp_type_at = re.search(r"\bwhat(?:'s| is) the type of\b|\btype of\b|\bwhat type is\b", prompt, re.IGNORECASE)
mcp_symbols = re.search(r"\b(list|show) (the )?(top-level )?(declarations|symbols|functions)\b|\bdocument outline\b",
                         prompt, re.IGNORECASE)
mcp_definition = re.search(r"\b(find|go to|where is)\b.*\bdefin", prompt, re.IGNORECASE)
mcp_references = re.search(r"\bfind (all )?(uses|usages|references)\b|\bwho calls\b",
                            prompt, re.IGNORECASE)
mcp_fmt = re.search(r"\bformat (this|the) (file|source|code)\b", prompt, re.IGNORECASE)
mcp_lint = re.search(r"\blint\b", prompt, re.IGNORECASE)
mcp_test = re.search(r"\brun (the )?doctests?\b", prompt, re.IGNORECASE)
mcp = mcp_check or mcp_type_at or mcp_symbols or mcp_definition or mcp_references or mcp_fmt or mcp_lint or mcp_test

# Sprint-orchestration task: running/starting a sprint, or orchestrating
# multi-agent implementation work. The sprint machinery lives in dedicated
# skills + .claude/agents/ definitions; nothing else routes to it.
sprint = re.search(r"\bsprint\b", prompt, re.IGNORECASE) or (
    re.search(r"\borchestrat", prompt, re.IGNORECASE)
    and re.search(r"\b(run|start|launch|kick|resume|implement|slice|packet)\b",
                  prompt, re.IGNORECASE)
)

# Gate-shaped task: a gate/shard went red, or a fixture/golden/gate is being
# authored. AGENTS.md keeps only the loop and the silent-failure traps; the
# per-gate table and the authoring procedure moved into the `gates` skill
# (2026-08-17), so nothing routes there unless this fires.
gate_red = re.search(r"\b(gate|shard|preflight|fixpoint|CI)\b.{0,40}\b(red|fail\w*|break\w*|broke)\b",
                     prompt, re.IGNORECASE) or re.search(
                     r"\b(red|fail\w*|broke)\b.{0,40}\b(gate|shard|preflight)\b", prompt, re.IGNORECASE)
gate_author = re.search(r"\b(add|write|author|capture|bless|re-?cut|update)\b.{0,30}\b(gate|fixture|golden|snapshot)s?\b",
                        prompt, re.IGNORECASE) or re.search(r"diff_compiler_\w*", prompt)
gates = gate_red or gate_author

# Debug-shaped task: a .mdk program misbehaves, or a two-arm differential is
# being set up. The probe/flag catalogue and the two-arm recipe moved out of
# AGENTS.md into `debug-pipeline` (2026-08-17).
debug = re.search(r"\b(why does\w*|why is|why won'?t|debug|diagnos\w+|repro\w*)\b.{0,60}"
                  r"\b(parse|compile|typecheck|type-check|eval|fail|error|crash|wrong)\b",
                  prompt, re.IGNORECASE) or re.search(
                  r"\btwo-?arm\b|\bwrong (value|answer|output)\b|--keep-ir\b|\bCore IR\b",
                  prompt, re.IGNORECASE)

if not roadmap and not stdlib and not mcp and not sprint and not gates and not debug:
    sys.exit(0)

if roadmap:
    print(
        "Skill triage (roadmap/Phase task detected): before planning, decide "
        "where the change lands and load the matching skill from AGENTS.md's "
        "task-playbook table — skills are PLANNING inputs, so load during "
        "exploration, not after the plan is approved.\n"
        "- Typechecker-internal work in compiler/types/typecheck.mdk (most of "
        "the Phase 62-72 arc: a new type_error, constraint/coherence/unification "
        "tightening) -> load harden-typechecker.\n"
        "- Cross-cutting items threading compiler/frontend/resolve.mdk / "
        "compiler/frontend/desugar.mdk / compiler/eval/eval.mdk (e.g. Phase 63, "
        "69.x dictionary passing) are NOT harden-typechecker -> treat like "
        "add-language-feature.\n"
        "Triage reminder, not a directive: confirm where the fix actually "
        "lands first."
    )

if stdlib:
    print(
        "Skill triage (stdlib task detected): route:\n"
        "- Pure-Medaka function/impl/doctest/prop in stdlib/*.mdk -> load "
        "extend-stdlib (read its doctest-harness + language sharp-edge notes "
        "BEFORE writing — they cost real iterations otherwise).\n"
        "- A new native primitive (extern in compiler/eval/eval.mdk) -> load "
        "add-primitive.\n"
        "STDLIB.md is the checklist but is prone to drift; verify each item "
        "against the actual .mdk before trusting its status."
    )

if mcp:
    print(
        "Skill triage (MCP-tool-shaped task detected): before reaching for "
        "grep/Bash, check whether a medaka_* MCP tool answers this directly "
        "(mcp__medaka__*, deferred -- ToolSearch its schema before the first "
        "call):\n"
        "- Type-check / does it parse or compile -> medaka_check.\n"
        "- What type is X -> medaka_type_at.\n"
        "- List declarations / outline a file -> medaka_symbols.\n"
        "- Where is X defined (same file) -> medaka_definition.\n"
        "- Find every use of X (whole project) -> medaka_references.\n"
        "- Format a file -> medaka_fmt.\n"
        "- Lint a file -> medaka_lint.\n"
        "- Run a file's doctests -> medaka_test.\n"
        "Caveat: an inherited server answers with the ORCHESTRATOR's binary "
        "-- a daughter editing compiler/*.mdk or stdlib/core.mdk must still "
        "verify with its OWN freshly-built ./medaka (docs/ops/MCP.md §4); "
        "watch for a staleBinary field on the tool result."
    )

if sprint:
    print(
        "Skill triage (sprint/orchestration task detected): the sprint "
        "machinery is defined in skills + agent definitions — do not re-derive "
        "the workflow from ORCHESTRATING.md prose:\n"
        "- Planning/cutting a NEW sprint (choosing the slice set) -> load "
        "sprint-plan (coherent set, ~5+ slices, boundary-depth specs only; "
        "Opus 5 minimum).\n"
        "- Running a sprint as the FRONT seat -> load sprint-orchestrator "
        "(Sonnet 5 main session + persistent sprint-brain and sprint-rear "
        "daughters; escalation is a rule table; one sprint branch/PR).\n"
        "- An implementer just returned -> load slice-landed (the fixed "
        "completion sequence; order is load-bearing).\n"
        "- Writing or executing a slice handoff -> load sprint-packet (the "
        "contract: slice forms, refusal license, the six-section report).\n"
        "- Dispatch roles via .claude/agents/: sprint-brain, sprint-rear, "
        "sprint-implementer, "
        "slice-breaker, spec-conformance-reviewer, sprint-planner, "
        "sprint-verifier, sprint-scout, bug-reproducer, and at wrap-up "
        "friction-triage + sprint-retro.\n"
        "- A bug/gap was found mid-sprint -> load sprint-findings (row -> "
        "bug-reproducer bundle -> brain's two-question ruling: in-sprint w/ "
        "adjustment sweep, or orthogonal placed PLANNED-vs-GAP; every row "
        "terminal before exit).\n"
        "- Parallel-writer disjointness evidence -> scripts/sprint-disjoint.sh."
    )

if gates:
    print(
        "Skill triage (gate-shaped task detected): AGENTS.md keeps only the "
        "preflight loop and the traps whose failure is SILENT -- the per-gate "
        "table and the authoring procedure live in the `gates` skill.\n"
        "- A gate/shard went red -> run `gh issue list --label known-red` "
        "FIRST (it is usually not your break), then load gates for what that "
        "gate proves.\n"
        "- Adding a fixture, capturing/blessing a golden, or writing a new "
        "gate -> load gates (shared-corpus consumers, CI shard registration, "
        "and the dash-not-bash shell half).\n"
        "Triage reminder, not a directive."
    )

if debug:
    print(
        "Skill triage (debug-shaped task detected): load debug-pipeline "
        "before reasoning from source -- it carries the stage-isolation "
        "method, the entry probes, the [D-*] flag catalogue (--json codes, "
        "--types, the TYPED Core IR dump, --keep-ir), and the two-arm "
        "differential recipe. AGENTS.md keeps only the three traps that turn "
        "a wrong answer into a right-looking one ([D-JSON-HOLE], "
        "[D-BUILD-PIPE], [D-TWO-ARM-STDLIB]).\n"
        "Triage reminder, not a directive."
    )

sys.exit(0)
