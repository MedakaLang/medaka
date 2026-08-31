# CLI-CONFORMANCE.md — the ratified `medaka` command-line contract

**Status:** RATIFIED (conventions) / IN PROGRESS (conformance) — the four conventions below
are decided; the table records which cells already obey them and which are open defects the
`cli-one-program` sprint (#2354, umbrella #2301) drains.

---

## 0. What this document is, and how to re-derive it

`medaka` is sixteen verbs behind one binary. It is also the highest-frequency first-hour
surface in the project: a stranger types four or five `medaka` invocations before reading one
line of `docs/spec/SYNTAX.md`, and cross-verb drift reads as slop immediately.

This file is the **single normative source** for how those sixteen verbs handle arguments. It
ratifies four conventions (§1–§4), tabulates every verb against them (§5), re-derives every
claim #2301's body made (§6), and records two dispositions so the next agent finds a ruling
instead of re-deriving one (§7).

**Every column in §5 is machine-derivable, and none of it is hand-maintained.** Re-derive the
whole thing in one command:

```sh
make cli-conformance-census          # or: sh test/cli_conformance_census.sh
```

The census EXECUTES every verb of the built `./medaka` and reports the (exit code, stream,
message class) triple for each dimension. It derives the verb list from the binary's own usage
block, each verb's flag vocabulary from that verb's own `--help`, and whether a flag is really
parsed by *running the verb with it* — never by grepping the source for a literal, which
cannot attribute a flag to a verb. It asserts nothing and always exits 0: the non-conforming
cells below are known open defects, so a gate here would be red the day it landed. The
enforcing gate is the help/parse-arm agreement gate (sprint slice S-4).

> ⚠️ **Everything in §5 and §6 was derived by running a binary built from
> `cfa6aee8a7f7136dfe1abd7bbacac7ca72a60c3d`**, with `MEDAKA_STRICT=1` set on every probe so a
> stale binary would have failed loudly rather than answered (`[B-STALENESS]`/`[B-STDERR]`).
> A cell re-read off a stale binary is a census of last week's CLI.

---

## 1. Convention C1 — value syntax

> **Both `--flag <value>` and `--flag=<value>` are accepted, by every value-taking flag of
> every verb. Neither spelling is ever silently dropped, silently ignored, or reinterpreted as
> a positional argument. In prose — help texts, docs, this file — write `--flag <value>` for a
> single value and `--flag=<v1,v2>` for a comma-separated list.**

**Rationale.** The obvious ratification is to pick one spelling. Measurement says both single
choices break live callers, in opposite directions:

* the pre-commit hook depends on the `=` form — `.githooks/pre-commit:164` runs
  `"$MEDAKA" lint --only="$GATED_LINT_RULES" --deny="$GATED_LINT_RULES" "$f"`;
* the snapshot gates depend on the space form — `test/diff_compiler_snapshot_types_user.sh:93`
  runs `"$MEDAKA" snapshot "$MODE" --root "$ROOT" --out "$SNAPDIR/$sub" --stages "$stages"`.

More importantly, **the spelling is not the harm.** The harm is that the *unsupported*
spelling is, on four verbs, absorbed silently or misread as a filename:

```
$ medaka check-policy --allow=IO ok.mdk
No such file or directory                          # `--allow=IO` became the FILENAME
$ medaka manifest --fn=main ok.mdk
No such file or directory                          # ditto
$ medaka snapshot --check --stages=parse ok.mdk    # `--stages=parse` silently DROPPED:
                                                   # every stage renders, no message
$ medaka test --filter=zzz ok.mdk
medaka test: unrecognized flag '--filter=zzz' (known: …)   # loud — the conforming shape
```

> ⚠️ **Pre-C1 transcript.** The four lines above were captured before S-2 landed C1. Re-run
> today, all four now parse cleanly on both spellings — including the `test` line, which is no
> longer a rejection: `medaka test --filter=zzz ok.mdk` now behaves identically to `--filter
> zzz`. Left in place because it is still the correct illustration of *why* C1 was ratified
> (the three silent misreads it foreclosed); do not read it as current `test` behavior.

Accepting both spellings everywhere removes all three silent misreads at once and breaks
nothing. `lint` already models the loud half of this convention in the direction it does not
support, and its message is the wording to mirror:

```
$ medaka lint --deny rule-unused-import ok.mdk
medaka lint: --deny require a value in the form --flag=<rule1,rule2,...> (a bare
'--flag <rule>' space-separated form is not supported and would be silently ignored,
so it is rejected instead)
```

Under C1 that message stops being needed for `lint`, because the space form starts working —
but the *principle* it states ("would be silently ignored, so it is rejected instead") is the
one C1 generalises.

**Non-conforming cells:** `check-policy --allow=`, `manifest --fn=`, `snapshot --stages=` /
`--out=` / `--root=`, `codemod --strip=` / `--rename=`, `build -o=`, `lint --deny ` /
`--only ` / `--disable ` (space form). → **slice S-2** ✅ **DRAINED** — re-verified directly:
`check-policy --allow IO`/`--allow=IO`, `manifest --fn main`/`--fn=main`, `lint --deny
rule-not-eq`/`--deny=rule-not-eq`, `build -o=<path>`, and `snapshot --check --stages=parse` all
now parse the flag on either spelling instead of misreading it as a filename or dropping it.

---

## 2. Convention C2 — unknown-flag disposition

> **Every verb rejects an unrecognized `--`-shaped token appearing in a flag position. The
> rejection goes to stderr, names the offending token AND the verb's known flag set, and exits
> 1. No verb may treat an unrecognized `--` token as a filename, and no verb may ignore one.**
>
> **The wording is `medaka test`'s (#2316), verbatim in shape:**
>
> ```
> medaka <verb>: unrecognized flag '<token>' (known: <a>, <b>, <c>)
> ```

**Rationale.** Naming the valid set is what turns a rejection into a fix. **At the time this
convention was ratified** the tree carried **five** wordings for the same event — `unknown
flag: X` (`fmt`, `run`, `gate list`), `unknown option 'X'` (`new`, `repl`, `lsp`), `unknown
argument 'X'` (`mcp`, `codemod effect-labels`), `unknown codemod 'X'` / `unknown subcommand
'X'` (`codemod`, `gate`), and `unrecognized flag 'X' (known: …)` (`test`) — only the last of
which told the user what to type next. It was also the newest wording, landed by the
`test-vehicle-floor` sprint as the #2316 fix, and became the reference implementation this
convention generalises. **`S-unknown-flag-floor` and `S-help-truthfulness` have since unified
every verb onto this wording** (§5a); the five-wordings state above is history, not the
present tree — re-derive with `make cli-conformance-census` to see the current, unified set.

> ⚠️ **Two live behaviours C2 must not destroy**, both verified:
>
> * `dispatchSub` (`compiler/driver/medaka_cli.mdk:359-366`) intercepts `--help`/`-h` **at the
>   first position only**, deliberately (#1348). `medaka run prog.mdk --help` must keep
>   handing `--help` to the *program*:
>   ```
>   $ medaka run argv.mdk --help
>   ["--help"]
>   ```
> * Everything after the first positional under `medaka run <file>` is the program's argv,
>   `--`-shaped or not:
>   ```
>   $ medaka run argv.mdk -- --foo
>   ["--", "--foo"]
>   ```
>   Note that `--` is passed through as an ordinary argument, not consumed as a separator.
>   That is the current contract and C2 does not change it.

**The disposition classes**, as the census reports them:

| Class | Meaning | Conforms? |
|---|---|---|
| `REJECT-NAMED` | rejected, message names the token | ✅ (⚠️ only `test` also names the known set) |
| `REJECT-VAGUE` | rejected, but the message prints the command's *shape*, not the mistake | ❌ |
| `AS-FILENAME` | not rejected — the token became a positional and the verb tried to `open()` it | ❌ **S0-shaped** |
| `SILENT-ACCEPT` | exit 0, nothing printed — indistinguishable from a clean run | ❌ **the worst cell** |

**Non-conforming cells (AS OF THE PRE-SPRINT BASELINE):** `lint` (SILENT-ACCEPT), `check` /
`doc` / `check-policy` / `manifest` (AS-FILENAME), `build` / `new` / `snapshot` (REJECT-VAGUE),
plus `snapshot`'s *second* hole — with a mode supplied, any unknown flag was dropped without a
word:

```
$ medaka snapshot --check --zzz-not-a-flag ok.mdk
ok.mdk: FAIL no snapshot at ok.md …          # ran normally; --zzz never mentioned
```

→ **slice S-2** ✅ **DRAINED**, through ONE shared rejection helper (each verb supplies its name
and its known-flag set; the helper owns the check, the wording and the exit code). Re-verified
against the current binary: every one of the sixteen verbs now falls in the `REJECT-NAMED`
class, **`new` included** — ✅ **DRAINED by S-5**: `runNewCmd`'s arity-mismatch arm (0 or 2+
args) now scans for a leading-dash token and C2-names it before falling back to the generic
usage line, so `medaka new --zzz ok.mdk` (the census's own 2-positional probe shape) no longer
reads as `REJECT-VAGUE` just because it also has too many args; the genuine single-arg case
(`medaka new --zzz`) already rejected this way since S-2. `snapshot`'s second hole is closed
too: `medaka snapshot --check --zzz-not-a-flag ok.mdk` now answers `medaka snapshot:
unrecognized flag '--zzz-not-a-flag' (known: --check, --new, --bless, --isolate, --worker,
--out, --root, --stages)`, rc 1.

---

## 3. Convention C3 — exit-code semantics

> **Three codes, two of them used:**
>
> | Code | Means | Examples |
> |---|---|---|
> | **0** | the verb did what it was asked and the answer is *clean* | `check` with no errors; `fmt --check` on formatted input; any `--help` |
> | **1** | **everything else the verb can report** — usage error, unknown flag, missing or unreadable target, an empty target set, findings that constitute failure, compile error, runtime error | all of the below |
> | **2** | **RESERVED. No `medaka` verb may exit 2.** | — |
>
> **And "no `.mdk` files found" is a usage error**: one (stream, code) pair, `(stderr, 1)`,
> for every verb. A target set that matched nothing is never success.

**Rationale, part one — why 2 goes away.** Today `2` is emitted by `fmt`, `codemod` and `new`
only, and it does not mean one thing even there: in `fmt` it covers both "unknown flag" and
"no `.mdk` files found", while `check`/`run`/`test` report the very same usage errors as `1`.
A third code that distinguishes nothing is worse than two codes that distinguish one thing,
and *no in-tree consumer branches on it* — derived, not assumed: every `-eq 2` / `= "2"`
comparison under `test/`, `scripts/` and `.githooks/` is a gate script testing its **own**
skip code or another *script's* exit status, never a `medaka` verb's. Note in particular that
`fmt` already exits **1**, not 2, for its main finding ("unformatted files present",
`test/diff_compiler_fmt_write_safety.sh:53`), so converging 2→1 leaves that gate untouched.

**Rationale, part two — why "found nothing" is a failure.** The three verbs that accept a
directory disagree on the empty case in all three dimensions at once:

```
$ medaka fmt  empty/    → stderr "medaka fmt: no .mdk files found"    exit 2
$ medaka test empty/    → STDOUT "medaka test: no .mdk files found"   exit 0
$ medaka lint empty/    → (nothing at all)                            exit 0
```

`test` is the load-bearing one: **a test command that ran zero tests and exited 0 is the
"didn't run looks like passed" failure the whole test arc exists to close.** `lint`'s silence
is the same defect one degree worse. Both must become `(stderr, 1)`.

> This convention is the **one decision that spans slices S-2 and S-3** and is made here, once:
> S-2's new rejections and S-3's convergence both use **exit 1**. If S-2 chose per-verb and S-3
> converged afterwards, S-2's fixtures would pin the wrong number and S-3 would re-bless
> goldens it should never have touched.

**Non-conforming cells (AS OF THE PRE-SPRINT BASELINE):** `fmt` (2 on usage error and on empty
target set), `codemod` (2), `new` (2), `test` (0 on empty target set), `lint` (0 on empty
target set, 0 on unknown flag). → **slice S-3** ✅ **DRAINED** — re-verified against the
current binary: `fmt`, `codemod` and `new` now exit **1** on both a usage error and an unknown
flag; `test`'s and `lint`'s empty-target-set case are now `(stderr, 1)`, matching every other
verb (`sh test/cli_conformance_census.sh`, "usage-error exit code + stream" and
"empty-directory target" sections, current run).

---

## 4. Convention C4 — stream discipline

> **stdout carries the ANSWER the verb was asked for** — inferred schemes, generated Markdown,
> the TOML manifest, formatted source, the JSON envelope, help text, and the user program's own
> output under `medaka run`.
>
> **stderr carries everything else** — diagnostics, usage errors, unknown-flag rejections,
> warnings, progress, timing.
>
> **Under `--json`, the answer channel carries exactly one JSON document and nothing else.**
> For fifteen verbs the answer channel is stdout. `medaka run` is the single deliberate
> exception: its stdout belongs to the user program, so `run --json`'s envelope goes to
> **stderr**, and *stderr is therefore `run`'s machine channel* and must be equally pure.
>
> 🚨 **A human-readable writer that would corrupt the machine channel is ROUTED, never
> SUPPRESSED** (`[W-QUIETER]`). Silencing the staleness warning under `--json` would make a
> stale binary invisible to every MCP/LSP consumer — a severity increase dressed as a fix. It
> belongs in the envelope (the mechanism already exists: `attachStaleness`,
> `compiler/tools/mcp.mdk`) or on a documented third channel.

**Rationale.** A machine consumer reads one stream. A verb that answers on the other one is
unavailable to it however well-formed its JSON is — and a verb that mixes prose into the
answer stream is worse, because the consumer parses *most* of the time.

**Measured violations (AS OF THE PRE-SPRINT BASELINE — all four ✅ DRAINED by slice S-3;
re-verified against the current binary below each).**

*(a) `run --json`'s channel is corrupted by two different writers.* Both reproduce:

```
$ MEDAKA_PERF=1 medaka run --json panic2.mdk 2>&1 >/dev/null
[perf] load	0.04289889335632324s	panic2.mdk
[perf] check	0.07178306579589844s	panic2.mdk
{"files":[{"file":"panic2.mdk","diagnostics":[{"code":"E-DIV-ZERO", … }]}]}

$ MEDAKA_ROOT=/var/tmp/fakeroot medaka run --json panic2.mdk 2>&1 >/dev/null
warning: this ./medaka was built from compiler source that differs from
/var/tmp/fakeroot/compiler — it may be stale; rebuild with 'make medaka'.
{"files":[{"file":"panic2.mdk","diagnostics":[{"code":"E-DIV-ZERO", … }]}]}
```

⚠️ This is **not** the defect the 2026-08-30 adversarial pass reported, which was about
`check`. On `check` the envelope is on stdout and both writers are on stderr, so `check --json`
is clean — see §6, exemplar **X9**. The `--json` corruption is real and it lives on `run`,
where the envelope shares stderr with the prose. Fixing the wrong verb would have left it.

✅ **DRAINED by S-3 — routed, not suppressed.** Both writers now land INSIDE the JSON envelope
as extra fields, re-verified:

```
$ MEDAKA_PERF=1 medaka run --json panic2.mdk 2>&1 >/dev/null
{"files":[{"file":"panic2.mdk","diagnostics":[{"code":"E-DIV-ZERO", …}]}],"perf":["[perf] load\t0.036s\tpanic2.mdk","[perf] check\t0.065s\tpanic2.mdk"]}

$ MEDAKA_ROOT=/tmp/fakeroot medaka run --json panic2.mdk 2>&1 >/dev/null
{"files":[{"file":"panic2.mdk","diagnostics":[{"code":"E-DIV-ZERO", …}]}],"staleBinary":"warning: this ./medaka was built from compiler source that differs from /tmp/fakeroot/compiler — it may be stale; rebuild with 'make medaka'."}
```

stderr now carries exactly one JSON document on both paths. (`MEDAKA_STRICT=1` combined with
`MEDAKA_ROOT` still hard-exits before any envelope is produced, per `[B-STALENESS]` — that is
strict mode doing its job, not a residual of this defect.)

*(b) `check-policy` puts its verdict — the thing it was asked for and the reason for its
nonzero exit — on stdout, while every sibling verb reports failure on stderr:*

```
$ medaka check-policy ok.mdk ; echo "rc=$?"
rejected. no 'transform' entry found          # ← stdout
rc=1
```

✅ **DRAINED by S-3** — re-verified: `medaka check-policy ok.mdk` now prints `rejected. no
'transform' entry found` to **stderr**, stdout empty, rc 1.

*(c) `codemod` prints its usage error to stdout* (`medaka codemod` with no arguments: exit 2,
usage on stdout, stderr empty).

✅ **DRAINED by S-3** — re-verified: `medaka codemod` with no arguments now prints its usage
block to **stderr**, stdout empty, rc **1**.

*(d) `test`'s "no .mdk files found" is on stdout* — see §3.

✅ **DRAINED by S-3** — see §3's re-verification above: now `(stderr, 1)`.

→ **slice S-3**, closed. The `run --json` routing choice landed as envelope-embed (extra
`perf`/`staleBinary` fields), not a documented third channel.

---

## 5. The conformance table

Derived by `make cli-conformance-census` at base `cfa6aee8a`. ✅ conforms · ❌ does not ·
`—` not applicable.

### 5a. Unknown-flag disposition (C2) and usage-error exit code (C3)

Probe: `medaka <verb> --zzz-not-a-flag ok.mdk` (disposition), `medaka <verb>` (usage error).

**Re-derived against the current binary (post S-2/S-3/S-4/S-5) — this table no longer matches
the pre-sprint baseline captured when it was first written; every cell below is current.**

| Verb | Unknown flag → | rc | stream | C2 | Usage error rc | C3 |
|---|---|---|---|---|---|---|
| `check` | `medaka check: unrecognized flag '--zzz…' (known: --json, --types, --allow-internal)` | 1 | stderr | ✅ | 1 | ✅ |
| `fmt` | `medaka fmt: unrecognized flag '--zzz…' (known: --check, --stdout, --write, -w)` | 1 | stderr | ✅ | 1 | ✅ |
| `new` | `medaka new: unrecognized flag '--zzz…' (known: none)` | 1 | stderr | ✅ **DRAINED by S-5** (was REJECT-VAGUE — `runNewCmd`'s 2+-arg arm now C2-names a leading-dash token before its generic usage line) | 1 | ✅ |
| `build` | `medaka build: unrecognized flag '--zzz…' (known: --keep-ir, --allow-internal, --json, …)` | 1 | stderr | ✅ | 1 | ✅ |
| `run` | `medaka run: unrecognized flag '--zzz…' (known: --json, --allow-internal, --release)` | 1 | stderr | ✅ | 1 | ✅ |
| `test` | `medaka test: unrecognized flag '--zzz…' (known: --native, --json, --engines, --filter, --seed, --cases)` | 1 | stderr | ✅ **reference** | 1 | ✅ |
| `snapshot` | `medaka snapshot: unrecognized flag '--zzz…' (known: --check, --new, --bless, --isolate, --worker, --out, --root, --stages)` | 1 | stderr | ✅ | 1 | ✅ |
| `doc` | `medaka doc: unrecognized flag '--zzz…' (known: none)` | 1 | stderr | ✅ | 1 | ✅ |
| `lint` | `medaka lint: unrecognized flag '--zzz…' (known: --fix, --json, --cache, --disable, --only, …)` | 1 | stderr | ✅ | 1 | ✅ |
| `codemod` | `medaka codemod: unknown codemod '--zzz…'` | 1 | stderr | ✅ (names the token; the sub-name arm doesn't have a flag set to name, same shape as `gate`) | 1 | ✅ |
| `check-policy` | `medaka check-policy: unrecognized flag '--zzz…' (known: --allow, --fn)` | 1 | stderr | ✅ | 1 | ✅ |
| `manifest` | `medaka manifest: unrecognized flag '--zzz…' (known: --fn)` | 1 | stderr | ✅ | 1 | ✅ |
| `gate` | `medaka gate: unknown subcommand '--zzz…' (expected: list, run, verify, explain, reach, ci, balance, budget)` | 1 | stderr | ✅ | 1 | ✅ |
| `repl` | `medaka repl: unrecognized flag '--zzz…' (known: none)` | 1 | stderr | ✅ | 0 (starts a session) | — |
| `lsp` | `medaka lsp: unrecognized flag '--zzz…' (known: none)` | 1 | stderr | ✅ | 0 (starts the server) | — |
| `mcp` | `medaka mcp: unknown argument '--zzz…' (mcp takes no arguments; try 'medaka mcp --help')` | 1 | stderr | ✅ | 0 (starts the server) | — |
| bare / `help` / `--help` / `-h` | prints usage | 0 | stdout | — | — | ✅ |
| `--version` / `-v` / `version` | `medaka 0.1.0-preview` | 0 | stdout | — | — | ✅ |

There is no residual C2 cell left in this table — `new` was the last one and S-5 drained it.

### 5b. Empty target set (C3) — probe `medaka <verb> empty/`

**Re-derived against the current binary — every row below is current, not the pre-sprint
baseline.**

| Verb | Message | stream | rc | C3 |
|---|---|---|---|---|
| `fmt` | `medaka fmt: no .mdk files found` | stderr | 1 | ✅ |
| `test` | `medaka test: no .mdk files found` | stderr | 1 | ✅ |
| `lint` | `medaka lint: no .mdk files found` | stderr | 1 | ✅ |
| `codemod` | `medaka codemod: missing codemod name — 'empty' is a path, and a codemod name must come first` | stderr | 1 | ✅ (no longer reads the directory as a codemod NAME) |
| `check` / `doc` / `check-policy` / `manifest` | `Is a directory` | stderr | 1 | ⚠️ raw `errno` text, no verb prefix, no path (residual — see below) |
| `run` | `unknown module: empty — available modules: array, async, …` | stderr | 1 | ⚠️ a missing/wrong path is reported as a missing MODULE (residual — see below) |
| `snapshot` | usage line | stderr | 1 | ✅ |

### 5c. `--json` availability and channel (C4) — probe `medaka <verb> --json bad.mdk`

**Re-derived against the current binary.** The probe target (`bad.mdk`) doesn't exist, so for
`run` this exercises the module-resolution error path, not a compile-error path — `run --json`
on an actual compile error is covered separately in §4(a), now DRAINED.

| Verb | Channel | rc | Verdict |
|---|---|---|---|
| `check` | stdout | 1 | ✅ |
| `build` | stdout | 1 | ✅ |
| `lint` | stdout | 0 | ✅ |
| `test` | stdout | 1 | ✅ |
| `run` | none (prose only on this probe path) | 1 | ⚠️ deliberate that stdout is the program's; on this specific probe `--json` is accepted and ignored because the failure is a module-resolution error, not a diagnosable file — see §4(a) for the compile-error path, now routed cleanly to stderr |
| `doc` | none | 1 | ✅ honestly rejected (`medaka doc: unrecognized flag '--json' (known: none)`) — was accepted-and-ignored |
| `check-policy` | none | 1 | ✅ honestly rejected (`medaka check-policy: unrecognized flag '--json' (known: --allow, --fn)`) — was read as the FILENAME |
| `manifest` | none | 1 | ✅ honestly rejected (`medaka manifest: unrecognized flag '--json' (known: --fn)`) — was read as the FILENAME |
| `snapshot` | none | 1 | ✅ honestly rejected (`medaka snapshot: unrecognized flag '--json' (known: …)`) — was accepted and silently ignored |
| `fmt` | none | 1 | ✅ honestly rejected (`medaka fmt: unrecognized flag '--json' (known: …)`) |
| `codemod` | none | 1 | ✅ honestly rejected |
| `gate` | none | 1 | ✅ honestly rejected at top level — `--json` is a per-subcommand flag. `medaka gate list --json` emits the registry array on stdout, rc 0. (`gate run --json` writes the run report; `--dry-run` short-circuits before it, so it is not exercised by this probe.) |

✅ **DRAINED by S-5.** `check --types` under `--json` used to be a silent drop: `medaka check
--types ok.mdk` printed `main : Unit`; `medaka check --json --types ok.mdk` printed the same
envelope as without `--types`, no message, no note in `checkHelpText`. The envelope has no
field for a human-text scheme dump, so composing the two was a bigger design decision than
this residual warranted — instead the no-op is now EXPLICIT: `medaka check --json --types
ok.mdk` writes `medaka check: --types has no effect under --json (envelope has no scheme-dump
field)` to stderr before the (byte-identical) JSON envelope on stdout, and `checkHelpText`
documents it under `--types`.

### 5d. `--help` (C4) — probe `medaka <verb> --help`

**Every one of the sixteen verbs answers `--help` on stdout with exit 0.** This column is
fully conforming and is the CLI's best-behaved dimension. `dispatchSub` covers ten verbs
centrally; `build`, `new`, `repl`, `lsp`, `mcp` special-case it internally (#1348).

### 5e. Help/parse-arm agreement — derived

The census probes **every `--`-shaped token each verb's own `--help` advertises** against that
verb (walking each subcommand for the multi-subcommand verbs) and reports any the verb
rejects. **At this base that list is empty**: no verb advertises a flag its own parse arms
lack.

The census's *second* agreement probe covers what the first is blind to — a help text naming
**another** verb's flag in passing. That one finds exactly one row, and it is #2301's:

```
── help-prose cross-references (every 'medaka <verb> --flag' phrase) ──
CITED IN             CITED AS               VERDICT        evidence
build                --release              NOT-PARSED     error: medaka build takes exactly one input file
```

> ⚠️ **The bound on this column, stated rather than hidden** (E5's pre-licensed second
> discharge form applies to S-4's gate, which inherits it): the probe answers *"is this flag
> rejected as unknown"*, not *"is this flag honoured"*. A flag that is accepted-but-ignored
> reads as PARSED here, because from outside the process it is. That residue is closed by a
> source-side derivation in S-4, not here. Today exactly one such flag exists and it is
> **honest** — `gate run --jobs` is documented as `ACCEPTED BUT IGNORED — this runner is
> sequential` in its own help (`compiler/tools/gate_cmd.mdk:591`) and echoes the requested
> value back in its summary line. That is documented dead surface, which E6 permits.

### 5f. Dead / silent surface

| Site | Behaviour | Disposition |
|---|---|---|
| `notYet` (`medaka_cli.mdk`) | `medaka: subcommand 'X' not yet in native CLI` | ✅ **DRAINED by S-help-truthfulness** — renamed `unknownSubcommand`; now `medaka: unknown subcommand 'X'` + `run \`medaka help\` for the list of subcommands`, rc 1. Derivation of reach: `dispatch` matches every verb by literal, so this arm receives exactly the NON-verbs — for every input it can get, "not yet" was false. |
| `snapshot --root`, `snapshot --worker` | parsed, absent from `snapshotHelpText` entirely | ✅ **DRAINED by S-help-truthfulness** — both now documented; `--worker` is marked INTERNAL (the supervisor re-spawns this binary with it) rather than presented as user-facing. Now GATED, property C of `test/diff_compiler_cli_help_conformance.sh`. |
| top-level `usage` vs `checkHelpText` | usage advertised `medaka check [--json]`; the verb also parses `--types` and `--allow-internal` | ✅ **DRAINED by S-help-truthfulness** — usage now reads `medaka check [--json] [--types] [--allow-internal] <file.mdk>`. The `run` line had the same shape (it advertised ONLY the no-op `--release`) and was fixed with it. **NOT gated**: under-documentation in the top-level block is invisible to properties A/B/C — see §5g. |
| top-level `usage` vs `docHelpText` | usage said `medaka doc [file.mdk]` (optional); help says `medaka doc <file.mdk>`; the binary **requires** it | ✅ **DRAINED by S-help-truthfulness** — usage now reads `medaka doc <file.mdk>`, and `runDocTargets`'s own empty-argv usage line (which said `[file.mdk]` too, contradicting its sibling arm) with it. **NOT gated**: positional arity is not a flag, so no property sees it — §5g. |
| `doc <a> <b>` | second and later positionals silently ignored, exit 0 | ✅ **DRAINED by S-unknown-flag-floor** — `medaka doc a.mdk b.mdk` now answers `usage: medaka doc <file.mdk> (doc takes exactly one file)`, rc 1. |
| `lint --only=nosuchrule` / `--disable=nosuchrule` | unknown rule name silently accepted, exit 0 | ✅ **DRAINED by S-unknown-flag-floor** — both now answer `medaka lint: unknown rule <name> (known: …)`, rc 1. |
| `fmt --write --stdout` | mutually exclusive modes both accepted; `--stdout` wins, no write, exit 0 | ✅ **DRAINED by S-unknown-flag-floor** — now `medaka fmt: --stdout --write are mutually exclusive — pick one.`, rc 1 (`snapshot`'s own mode-conflict rejection was already the right model, now mirrored here). |
| `gate run --jobs <n>` | accepted, ignored, **documented as such** | ✅ conforming dead surface (E6) |

### 5g. What is now GATED, and what still is not

`test/diff_compiler_cli_help_conformance.sh` (S-help-truthfulness, #2354) is the enforcing
gate for the help/parse-arm columns above. It shares ONE derivation with this doc's census —
`test/cli_conformance_lib.sh`, sourced by both — so the map and the gate cannot give two
answers to the same question. It asserts three properties, all derived from the binary:

| | Property | Catches | Derived from |
|---|---|---|---|
| **A** | advertised ⊆ parsed | a help text promising a flag the arms lack | running the verb with each flag its own `--help` names |
| **B** | cross-references resolve | a help text citing ANOTHER verb's missing flag (X7) | running each `medaka <verb> --flag` phrase found in ANY help text against the verb it names |
| **C** | parsed ⊆ advertised | an arm no help text mentions (`snapshot --root`/`--worker`) | each verb's own `(known: …)` roster, printed by `assertCliFlags` |

**Coverage is REPORTED on every run, per verb, including what is uncovered** — a gate that
silently checks nine verbs of sixteen while reading as complete is worse than the drift.

**What NO property sees**, stated so nobody reads the green as broader than it is:

* **C covers only the verbs whose rejection carries a real `(known: …)` roster.**
  ✅ **Narrowed by S-5**: `doc`, `lsp`, `new` and `repl` all route their unknown-flag rejection
  through `unknownFlagMessage`, which renders `(known: none)` for a genuinely flagless spec —
  that IS a roster (an empty one), so `cli_known_flags_of` now distinguishes it (via
  `cli_had_roster`) from a verb with no roster at all, and these four are listed `(roster
  present, zero flags)` and counted as covered, not `NO ROSTER (uncovered)`. Only `codemod`
  (its own "unknown codemod 'X'" wording, no `(known: …)` substring) and `mcp` (its own
  "unknown argument 'X'" wording) remain genuinely `NO ROSTER (uncovered)` — neither goes
  through `unknownFlagMessage` at all, so there is nothing in the message to derive a roster
  from without inventing one (residual filing candidate).
* **Positional arity is not a flag.** `medaka doc [file.mdk]` vs `<file.mdk>` — the §5f row
  above — is a claim about a POSITIONAL, and no property can reach it.
* **Under-documentation in the top-level `usage` block is not a lie**, only an omission, and
  the block is deliberately abbreviated. Property B checks that what usage DOES cite resolves;
  nothing checks that it cites everything.
* **Prose semantics.** `run --help`'s `--json` paragraph describes WHEN an envelope appears.
  That the compile-error half of it was false (now written down as a KNOWN GAP in the help
  text itself) is not a flag-existence question, and A/B/C are blind to it.
* **A and B ask "is this flag rejected as unknown", not "is it honoured."** An
  accepted-but-ignored flag reads as parsed — which is why `gate run --jobs`, conforming dead
  surface under E6, is correctly not flagged.
* A help text can also evade B by citing a flag WITHOUT the `medaka ` prefix. `runHelpText`'s
  replacement sentence does exactly that ("There is no `build --release`") — correctly, since
  the claim is a negative, but the loophole is real for a positive one.
* **Single-dash flags are graded in neither direction.** `cli_help_flags_of` and
  `cli_known_flags_of` both pattern-match `--`-prefixed tokens only, so a single-dash flag
  like `fmt`'s `-w` or `build`'s `-o` — both real, both documented — is invisible to
  properties A and C alike. No false pass is known to exist from this today, but it is a
  genuine gap, found by the end-of-sprint review and not by any slice; still OPEN after S-5
  (this slice widened the REJECTION floor for undeclared single-dash tokens, not the census's
  grading of *declared* ones) — a residual filing candidate.

  ✅ **The AS-FILENAME half is DRAINED by S-5**, though: an undeclared single-dash token
  (`-foo`, not a declared short flag) used to fall through as a positional on `check`, `doc`,
  `build`, `manifest`, `check-policy`, `test`, `lint` and `snapshot` — §2's C2 scope was
  `--`-shaped only, so this reproduced the same AS-FILENAME defect via `-foo` instead of
  `--foo`. `stdlib/args.mdk` now carries a per-verb opt-in (`ArgSpec.strictDash` /
  `withStrictDash`, ArgSpec value, opt-in not tree-wide): those eight specs now C2-reject an
  undeclared `-foo` exactly like `--foo`, e.g. `medaka check -foo` → `medaka check:
  unrecognized flag '-foo' (known: --json, --types, --allow-internal)`, rc 1. `fmt` and `run`
  already rejected single-dash unknowns their own way (unaffected); `new`'s leading-dash check
  already covered it too (§5a). `codemod`'s per-codemod vocabulary and `gate`'s subcommand
  arms are unchanged (out of this slice's scope, §4).

---

## 6. #2301's exemplars, re-derived

Every claim in #2301's body and in the sprint contract's §1 table, re-run on a binary built
from `cfa6aee8a` with `MEDAKA_STRICT=1`. Verdicts: **CONFIRMED** (reproduces as stated) ·
**STALE** (was true, no longer is) · **CORRECTED** (true in substance, wrong in a detail that
would have misdirected a fix).

| # | Claim | Verdict | Deciding command and its actual output |
|---|---|---|---|
| **X1** | `medaka fmt --foo ok.mdk` → `medaka fmt: unknown flag: --foo`, exit 2 | **CONFIRMED** | `medaka fmt --zzz-not-a-flag ok.mdk` → stderr `medaka fmt: unknown flag: --zzz-not-a-flag`, rc 2 |
| **X2** | `medaka test --foo ok.mdk` → `unrecognized flag … (known: …)`, exit 1 | **CONFIRMED** | `medaka test --zzz-not-a-flag ok.mdk` → stderr `medaka test: unrecognized flag '--zzz-not-a-flag' (known: --native, --json, --engines, --filter, --seed, --cases)`, rc 1 |
| **X3** | `medaka check --foo` → tries to open a file named `--foo`, exit 1 | **CONFIRMED — and the exemplar is load-bearingly exact** | `medaka check --foo` → stderr `No such file or directory`, rc 1. ⚠️ **`medaka check --foo ok.mdk` does NOT show it**: two positionals hit the arity arm and print `usage: medaka check […] <file.mdk>`, rc 1. The AS-FILENAME cell needs the *single*-positional form. A fixture written with the two-token form would pass on the broken binary. |
| **X4** | `medaka doc --foo ok.mdk` → `No such file or directory`, exit 1 | **CONFIRMED** | `medaka doc --zzz-not-a-flag ok.mdk` → stderr `No such file or directory`, rc 1 (`doc` reads only the first positional, so the flag *is* the target here) |
| **X5** | `medaka lint --foo ok.mdk` → nothing at all, exit 0 | **CONFIRMED — the worst cell** | `medaka lint --zzz-not-a-flag ok.mdk` → no stdout, no stderr, rc 0 |
| **X6** | `check`/`doc` share `dropFlags` (`:833-839`), last arm passes unknown tokens through as positionals | **CONFIRMED** | `grep -n dropFlags compiler/driver/medaka_cli.mdk` → definition `:833-839`, consumers `check :459`, `run :2041`, `doc :2668`. ⚠️ **`run` is a consumer but is NOT vulnerable**: `runRunCmd` re-checks the first positional for a leading `-` (`:2054`, the #219 fix) and rejects it — which is why `run` is REJECT-NAMED and `check`/`doc` are AS-FILENAME. |
| **X7** | `runHelpText` documents `--release` as "kept for symmetry with `medaka build --release`"; `build` has no such arm, so `medaka build --release ok.mdk -o out` dies with `takes exactly one input file`, exit 1 | **CONFIRMED — now FIXED and GATED (S-help-truthfulness)** | `medaka build --release ok.mdk -o /tmp/outbin` → stderr `error: medaka build takes exactly one input file`, rc 1. Found *mechanically* by the census's cross-reference column, not by reading. **Drained by fixing the SENTENCE, not by adding a `build --release` arm** (a native build is always optimized — there is no mode to select); `--release` on `run` is unchanged and still accepted. That column is now an assertion, property B of `test/diff_compiler_cli_help_conformance.sh`. |
| **X8** | The top-level `usage` (`:377`) advertises `medaka run [--release]` too | **CORRECTED — not a defect** | `medaka run --release ok.mdk` → stdout `1`, rc 0. `run` really does accept `--release` (`dropFlags` strips it). The false claim is the *cross-reference* to `build --release` in `runHelpText`, not the top-level usage line. A fix that deleted `[--release]` from `:377` would remove a true statement and leave the false one. |
| **X9** | The `--json` stdout-purity defect (adversarial pass, 2026-08-30) | **STALE on `check` — LIVE on `run`** | `MEDAKA_PERF=1 medaka check --json ok.mdk` → stdout exactly `{"files":[{"file":"ok.mdk","diagnostics":[]}]}`, **stderr empty**, rc 0 — no defect, confirming the contract's negative result. But `run --json` answers on **stderr**, and there the `[perf]` writer and the staleness warning both land in front of the envelope — see §4(a) for the two pasted transcripts. |
| **X10** | "no `.mdk` files found" is three different contracts (`test` 0/stdout, `lint` silent/0, `fmt` msg/2) | **CONFIRMED** | see §5b — reproduced exactly, all three |
| **X11** | `notYet` (`:399-401`) tells the user a subcommand is "not yet in native CLI" | **CONFIRMED — now FIXED (S-help-truthfulness)** | `medaka bogusverb` → stderr `medaka: subcommand 'bogusverb' not yet in native CLI`, rc 1. Reachable for **any** unmatched token, including a `--`-shaped one: `medaka --zz` → the same message, which is also why `--zz` never reaches a flag check. |
| **X12** | #2301's headline: "`medaka test` exposes **two flags total**" | **STALE** | `medaka test --zzz-not-a-flag ok.mdk` names six: `--native, --json, --engines, --filter, --seed, --cases`. `test-vehicle-floor` landed the other four and closed #2316. `medaka test` is now the **most** conformant verb in the tree. |
| **X13** | `lint` guards only value-taking flags and uses `--flag=v`; `test` uses `--flag v`; the two syntaxes coexist | **CONFIRMED at the time, now STALE — DRAINED by C1 (S-unknown-flag-floor)** | Original repro: `medaka lint --deny=rule-unused-import ok.mdk` → rc 0; `medaka lint --deny rule-unused-import ok.mdk` → rc 1 with the "not supported … rejected instead" message; `medaka test --filter zzz ok.mdk` → rc 0; `medaka test --filter=zzz ok.mdk` → rc 1 `unrecognized flag`. **Current binary**: both spellings now succeed on both verbs — `medaka lint --deny rule-not-eq ok.mdk` → rc 0, and `medaka test --filter=zzz ok.mdk` → rc 0 (`running doctests …`). C1 applied to `test` itself closed the second half; §5a's `test` row and §3's `test` row describe only the (still-accurate) unknown-flag/empty-target-set dimensions, not this one. |
| **X14** | Six verbs reject unknown flags, at three wordings | **CORRECTED — five wordings, and one more verb** | `mcp` also rejects (`unknown argument 'X' (mcp takes no arguments; …)`), and `codemod`/`gate` reject via a *sub-name* arm (`unknown codemod 'X'`, `unknown subcommand 'X'`). A `grep` for `unknown flag\|unknown option` — the derivation behind the "three wordings" claim — cannot see any of those three. S-2's unification target set is therefore larger than the contract's §4 row implies; the census's disposition column (§5a) is the complete list. |

---

## 7. Recorded dispositions — do not relitigate

**#1822 (`medaka lint` exits 0 on findings unless `--deny` is given) — NOT a drift, and NOT
touched by this sprint.** It is deliberate policy. Making `lint` exit nonzero on findings by
default would redden the pre-commit hook and `make preflight` tree-wide on a tree that is not
lint-clean (`[H-FMT]`; run `make fmt-clean-census` for the current set). The cell and its
rationale are recorded here; changing it is a ratchet decision for the 0.1.0 epic's open
lint-baseline question, not a CLI-conformance slice.

⚠️ Note the distinction C2 preserves: #1822 is about **findings**. `medaka lint --zzz-not-a-flag`
exiting 0 is about an **unrecognized flag**, which is a usage error and is squarely in scope
(§2, §3). Fixing the second does not touch the first.

**#2291 (`bench` is dead syntax) — NOT a CLI issue.** `grep -n bench
compiler/driver/medaka_cli.mdk` is empty: `bench` is a dead *declaration keyword*
(parser/typecheck/fmt/LSP surface), not a verb. Wrong subsystem, wrong gates. It stays open on
its own leg.

**Splitting `medaka_cli.mdk` (3,646 lines) — out of scope.** That is #2282. This document
makes it more tempting, not less; note findings there rather than acting on them.

---

## 8. Where each cell goes

| Slice | Owns |
|---|---|
| **S-2** `S-unknown-flag-floor` | §2 in full (one shared rejection helper, `test`'s wording, exit 1), plus C1's silent misreads (§1) and the silent-drop rows in §5f (`doc` extra positionals, `lint` unknown rule names, `fmt` mode conflict) |
| **S-3** `S-exit-and-stream-floor` | §3 in full (2→1, one `(stderr, 1)` for the empty target set) and §4 in full (`run --json` channel purity by ROUTING not suppressing; `check-policy` and `codemod` stdout/stderr) |
| **S-4** `S-help-truthfulness` | §5e and §5f's documentation rows (`notYet`, `snapshot --root`/`--worker`, the `check` and `doc` usage/help disagreements, the `build --release` cross-reference), plus the mechanical agreement gate. Import this document's census rather than re-deriving the flag rosters — that is the single-implementation obligation the contract names. |
| **S-5** `S-cli-residual-filings` | anything above still marked ❌ after S-2..S-4, filed **per class** (one issue per conformance row, naming every offending verb), ranked by first-hour reachability |

---

## 9. See also

* `test/cli_conformance_census.sh` — the derivation, and the bounds of what it can decide
* `compiler/driver/medaka_cli.mdk` — all verb dispatch (`runCli`, `dispatchSub`, `usage`)
* `compiler/tools/gate_cmd.mdk` — `gate`'s subcommands and help
* `compiler/driver/build_cmd.mdk` — `build`'s argument parsing
* `compiler/ERROR-QUALITY.md` — the rubric for the *content* of a diagnostic (this file governs
  only the CLI's **argument-handling** messages; a type error's wording is #2302's)
