# Type-Aware Lint Tier — Design

**Status: PARTLY SHIPPED, and RE-COSTED.** Re-derived 2026-08-19 against `main` at
`8b7b5517` (worktree level with `origin/main`); every file:line below was checked at that
commit. This supersedes the 2026-06-29 read-only pass, which was stale in **both**
directions — it understated what had shipped and overstated what Tier 2 costs.

| Tier | State |
|------|-------|
| **Tier 0** — constructor/datatype facts, no typecheck | **SHIPPED.** `lint.mdk` imports `frontend.exhaust.{Oracle, buildOracle, oGetCtors, oGetCtorType}`; `Rule`'s doc-comment describes the Oracle as *"used by the irrefutability logic to recognise single-constructor patterns"* — catalog rule (a), landed. |
| **Tier 1** — name-keyed inferred schemes | **NOT BUILT.** No `types.typecheck` import in `lint.mdk`. Design below stands, but see §10.1 — the recipe as written taxes the rearchitecture arc. |
| **Tier 2** — `typeOfLoc` over arbitrary sub-expressions | **NOT BUILT.** Re-costed from *large* to **medium**, plus one irreducible approximation. See §2.3 and §10. |

⚠️ **Read §10 before scheduling any of this.** The remaining work couples to the
typechecker rearchitecture arc (#1122) in three places, and one of the couplings
(§10.2) is a silent-wrongness hazard for anyone who builds the harvest without knowing it.

This doc scopes a *type-aware* rule tier for `medaka lint` (`compiler/tools/lint.mdk`),
analogous to `typescript-eslint`'s type-checked rules: rules keep matching the
**raw (pre-desugar) surface AST** for shape, but may **query a side-table of
resolve/type facts** (a "type oracle") harvested by running the pipeline once.

**Tracker home: #1754** (Tier 1 + Tier 2; filed 2026-08-19, DEPENDENCY-BLOCKED —
explicitly not slot-fillable). Its arc-side dependency is **#1752** (scope
`currentLoc`), which is arc work on its own merits, is *not* owned by this doc,
and **must not be prioritised on this tier's behalf** — the dependency is one-way.
Tier 1 additionally waits on the Stage E Flat-consumer migration (**#1115**; the
`CheckMode` deletion in #1116 is downstream of it) for the reason in §10.1.

---

## 1. Problem & non-goal

Today every lint rule is **purely syntactic**: `Rule.check : Positions ->
List Decl -> List Finding` (`compiler/tools/lint.mdk:50-56`) sees only the parsed
decls. That blocks a whole class of high-value rules:

- proving a single-arm constructor match (`match x { Just v => … }`,
  `let Just v = x`) is **irrefutable** (needs the constructor's sibling count);
- sharpening §6 `deriving` so it fires only when the type is *actually*
  locally-declared and derivable (needs the constructor/field table);
- sharpening §7a stdlib-reimpl so `reverse`/`map`/… fire only when the local
  definition's **signature matches** the stdlib one (needs the inferred scheme);
- redundant-conversion / redundant-wrapping / `map id` rules (need the inferred
  type of a sub-expression).

**Non-goal: do NOT relocate the linter to a post-typecheck stage.** The linter
deliberately runs on the **raw pre-desugar AST** (`lint.mdk:3-7`), exactly like
`checkGuardExhaustiveness`, because `desugar.mdk` runs first and destroys the
surface shapes rules detect — `EGuards`, `EFunction`, `ESection`, string interp,
`do`-blocks, and match-on-bare-param are all lowered to core before
resolve/typecheck ever see the tree (AGENTS.md "Pipeline" §; `desugar.mdk` runs
FIRST). A rule that pattern-matches on the desugared tree cannot see "this
function body is a `match` on its bare parameter," etc.

So the architecture is **not** "lint the typed tree." It is: **run the pipeline
once to harvest a fact table (the oracle), then run typed rules on the same raw
AST, passing them the oracle.** Surface shape comes from the raw AST; facts come
from the oracle. This mirrors typescript-eslint, where rules still walk the
ESTree (surface) AST and call `services.getTypeAtLocation(node)` into the TS
type-checker on the side.

---

## 2. The crux — is a `Loc`-keyed oracle feasible? (mostly clean, partly messy)

This is the load-bearing finding. Investigated empirically (LSP hover path,
typecheck channels, `Loc` representation).

### 2.1 There is no `Loc -> Type` map anywhere today

The LSP's "hover shows local var types" is **name-keyed, not position-keyed.**
The hover path (`compiler/tools/lsp.mdk:515-558`) uses the cursor position *only*
to scan out the **identifier string** under it (`identifierAt`,
`lsp.mdk:261-271` — pure `Array Char` scan, no AST), then looks that **name** up
in three flat `List (String, Scheme)` association lists (`hoverScheme`,
`lsp.mdk:553-558`; `lookupSchemeL` linear assoc, `:495-499`):

1. `env` — top-level schemes (the typecheck return value);
2. `currentLocalSchemes ()` — let-binders, lambda/clause params, match binders;
3. `currentSeedSchemes ()` — runtime externs.

Table (2) is built as a **side effect of inference**, not by walking a typed
tree: `recordLocalBind name v` appends `(name, mono)` to
`localBindRefs : Ref (List (String, Mono))` (`compiler/types/typecheck.mdk:1442-1466`),
generalized at the end of the run into `localSchemesOut`
(`typecheck.mdk:7507-7508`, module path `:9448`) and read via
`currentLocalSchemes : Unit -> <Mut> List (String, Scheme)` (`:1458`).

Consequences (documented limitations of reusing this machinery):
- keyed by **bare name** — shadowing is *not* disambiguated; `lookupSchemeL`
  returns the first match;
- only answers for **identifier occurrences**, never an arbitrary sub-expression
  (a literal, a `.field` projection, a call result);
- yields a generalized `Scheme`, not the monomorphic instantiated type at the
  occurrence.

### 2.2 `Loc` is span-only, sparse, and not a unique node id

`Loc = Loc String Int Int Int Int` (file, 1-based start line, 0-based start col,
1-based end line, 0-based end col) — `compiler/frontend/ast.mdk:26`. It is **not**
a field on every node; it is carried by a *transparent wrapper*
`ELoc Loc Expr` (`ast.mdk:1052`) that the parser puts on **atom/leaf and
statement-form productions only**. Specifically:

- **interior application / binop nodes are NOT individually wrapped.** This is
  deliberate and stated at the emission site: *"Binop/app/unary/postfix levels
  stay [unwrapped]"* (`parser.mdk:843`), mirroring `parser.mly`. Widening it is a
  parser change, not a typecheck one — and it moves `Positions`, the snapshot
  goldens, and (per [T-LEGA-GOLDEN]) the LEG A selfproc goldens.
- **`Pat`: CORRECTED 2026-08-19 — binders DO carry `Loc`.** The 2026-06-29 pass
  said "`Pat` nodes carry no `Loc` at all"; that is false at HEAD and was
  probably false when written. `PVar String Loc`, `PAs String Loc Pat`, and
  `RecPatField String Loc (Option Pat)` all carry one (`ast.mdk:859-873`).
  What genuinely carries none: `PCon`, `PTuple`, `PList`, `PLit`, `PCons`,
  `PWild`, `PRng`. So pattern *binders* are addressable; pattern *structure* is
  not.
- `file` is left `""` by the parser, filled by the caller (`ast.mdk:23`);
- every stage strips/recurses `ELoc` transparently, so it is *not* a stable
  unique node id — two nodes with the same span are indistinguishable.

### 2.3 The answer

- **Clean** for a *constructor/datatype* oracle: the constructor table is
  **purely syntactic** and needs neither types nor `Loc` keying (§3.1). The
  highest-value rule (irrefutable single-arm match) lands here.
- **Clean enough** for a *name-keyed* oracle: reusing
  `currentLocalSchemes`/top-level schemes gives `typeOfName`, modulo the
  shadowing caveat. Good for signature-based rules where the rule already has the
  declaration name in hand.
- **Mixed — and CHEAPER than the 2026-06-29 pass claimed** for a *true
  `typeOfLoc : Loc -> Option Mono`*. That pass scoped it as "a new pass that
  threads the solved `Mono` onto `ELoc`-wrapped nodes," i.e. net-new
  infrastructure. Two facts at HEAD remove most of that:

  1. **The `Loc` plumbing is already built.** `currentLoc : Ref (Option Loc)`
     (`typecheck.mdk:6858`) is set in `infer env (ELoc l e)` (`:8819`) and is
     already snapshotted into six side-tables (`PendingEntry`'s 6th field,
     `pushPendingObl`, `pushDictApp`, `recordObl`, the absorption event's `loc`,
     `pendingBinopSites`/`pendingUnopSites`). 82 references in the file. A
     harvest is *one more* consumer of an existing, exercised mechanism.
  2. **No zonk pass is needed.** `Mono = TVar (Ref Tyvar) | …`
     (`typecheck.mdk:210`) is ref-backed union-find, so a recorded `Mono`
     resolves itself as unification proceeds. Record during inference, read
     after the whole-graph post-passes, and the refs are already bound. There is
     no substitution to apply and no typed tree to walk.

  So the recorder itself is **small** — one `Ref (List (Loc, Mono))`, one push,
  one accessor, the same shape as `recordLocalBind`/`localSchemesOut`.

  ⚠️ **What is NOT small, and is the actual blocker: `currentLoc` is
  set-on-enter and NEVER RESTORED** — a *last-`ELoc`-entered* marker, not a
  scoped node identity. The tree documents the consequence itself at `:2269` and
  `:6863`: *"it names whichever ELoc happened to be entered last (observed …:
  the body of an unrelated impl three lines away)."* A naive harvest over
  today's ref therefore mis-attributes every expression that follows a nested
  subexpression, **silently** — a lint finding pointed at the wrong line, which
  is [W-QUIETER]. Measured at `8b7b5517`: **8 write sites, 33 readers**; several
  writes are deliberate re-targets compensating for the leak (notably the binop
  last-operand override at `:10486-10492`). Filed as **#1752**, as arc work on
  its own merits — see §10.3.

**Recommendation: do NOT build a general `typeOfLoc` first** — but the reason has
changed. It is no longer "the recorder is large"; it is (i) the span semantics
must be repaired first (#1752, and that repair belongs to the arc, not to lint),
and (ii) §2.4's join remains approximate no matter what, which caps the value of
every rule built on it.

### 2.4 The irreducible part: the raw↔core join

None of the above touches the property that actually decides whether Tier 2 earns
its keep. Types exist only on the **post-desugar** tree; lint reads the **raw**
tree by design (§1). `Loc` is the only available join key, it is span-only and
**not unique** (two nodes with the same span are indistinguishable), and desugar
mints nodes with no raw counterpart. So lookups are "smallest enclosing `ELoc`
span containing the query span" — approximate by construction, in a way no amount
of typechecker work removes.

This is not hypothetical. It is what made the #1739 `.value` → `!` rule
unshippable: the rule could not distinguish a `Ref` read from a record field
genuinely named `value`, the only sound formulation abstained into noise, and the
migration shipped as a reviewed textual transform verified by the self-compile
fixpoint instead. **Before building Tier 2, name a rule that survives an
approximate join** — that, not the recorder's cost, is the go/no-go.

---

## 3. Oracle interface

Define a `TypeOracle` record bundling the harvested facts. It is built once per
lint invocation (per file or per project — §8 fork) and passed to every typed
rule. Minimal viable set, split by the tier that backs each query:

```
public export record TypeOracle
  -- Tier 0 — constructor/datatype facts (SYNTACTIC; no typecheck) ------------
  ctorCountOfCtor : String -> Option Int        -- ctor name -> its type's sibling count
  ctorCountOfType : String -> Option Int        -- type name -> its constructor count
  typeOfCtor      : String -> Option String     -- ctor name -> its datatype name
  fieldsOfCtor    : String -> Option (List String)
  isLocalType     : String -> Bool              -- type was declared in THIS target set
  -- Tier 1 — name-keyed inferred schemes (typecheck; reuses LSP channel) -----
  schemeOfTop     : String -> Option Scheme     -- top-level name -> generalized scheme
  schemeOfLocal   : String -> Option Scheme     -- let/param/binder name (shadowing-lossy)
  typechecked     : Bool                        -- did typecheck run clean enough to trust Tier 1?
  -- Tier 2 — STRETCH (net-new; behind --type-aware-exprs fork; see §8) -------
  typeOfLoc       : Loc -> Option Mono           -- arbitrary sub-expr type (NOT built initially)
```

Derived helper (pure, on top of Tier 0 — the irrefutability primitive):

```
isIrrefutableArm : TypeOracle -> Pat -> Bool
-- PVar/PWild/PAs(irrefutable)            -> True
-- PTuple ps / PRecord …                  -> all sub-pats irrefutable
-- PCtor c subps                          -> ctorCountOfCtor c == Some 1
--                                            && all sub-pats irrefutable
-- PLit _                                  -> False
```

`Scheme`/`Mono` are the existing types (`typecheck.mdk:680`, `:78`). Rules that
only need the constructor table never touch `Scheme` and stay typecheck-free.

---

## 4. How the oracle is built

### 4.1 Tier 0 — constructor table (free; no typecheck, no `Loc` bridging)

**Reuse `exhaust.mdk`'s exported `Oracle` verbatim.** It is purpose-built, runs
on the **raw pre-desugar decls the linter already holds**, and needs no types:

- `record Oracle { typeCtors, ctorArity, ctorType, ctorFields }`
  — `compiler/frontend/exhaust.mdk:108`.
- `buildOracle : List Decl -> Oracle` — `exhaust.mdk:116` (seeds builtins
  `Bool`/`List`/`Unit`, user decls override).
- accessors `oGetCtors : Oracle -> String -> Option (List String)`
  (`exhaust.mdk:180`), `oGetCtorType` (`:185`), `oGetCtorFields` (`:177`),
  `oGetArity` (`:190`).

`ctorCountOfCtor c = oGetCtorType o c >>= oGetCtors o |> map listLen`;
`isLocalType` = membership in the locally-declared `typeCtors` keys (filter
`buildOracle (userDeclsOnly)` vs the builtin/imported seed). This is the same
oracle typecheck itself stores in `matchOracle` (`typecheck.mdk:9254`), so the
facts are exactly the compiler's own.

**Cost: one `buildOracle` call over the decls. No pipeline run.** This tier is
available even when the file does not typecheck, and even when `--type-aware` is
off, because it is just a syntactic scan of constructors.

### 4.2 Tier 1 — name-keyed schemes (one pipeline run; reuses LSP harvest)

Run the existing non-aborting analysis once and harvest schemes the same way the
LSP does:

- **Single file:** mirror `docSchemes` (`lsp.mdk:479-486`): `desugar` runtime +
  core + user, call
  `checkProgramSchemesWithRuntime : List Decl -> List Decl -> <Mut> List (String, Scheme)`
  (`typecheck.mdk:7460`) → that is `schemeOfTop`. Then read
  `currentLocalSchemes ()` (`typecheck.mdk:1458`) → `schemeOfLocal`. Runtime/core
  sources are read exactly as `runCheckCmd` does (`medaka_cli.mdk:115-128`:
  `MEDAKA_ROOT` + `stdlib/runtime.mdk`/`core.mdk`).
- **Project:** use the loader + diagnostics path —
  `checkModules : List Decl -> List Decl -> List (String,List Decl) -> <Mut> List (String,List (String,Scheme))`
  (`typecheck.mdk:9807`), fed by `loadProgramFilesE`/`loadProgramFilesLocatedE`
  (the string-error `loadProgramFiles`/`loadProgramFilesLocated` wrappers were
  removed with #100 — these return `Result LoadError`, so a dependency's parse
  error arrives attributed to ITS file; flatten with `loadErrorMessage` if the
  caller only wants text).
- **`typechecked` flag:** harvest errors via
  `checkProgramDiags : … -> <Mut> (List (String,Option Loc), List (String,Option Loc))`
  (`typecheck.mdk:9314`) or the boolean `checkErrorsWithRuntime`
  (`typecheck.mdk:9279`). Set `typechecked = (errors == [])`. Crucially,
  `checkProgramSchemesWithRuntime` returns **best-effort schemes even when the
  file has type errors** (it only fails to produce an env if the file doesn't
  *parse* — `docSchemes` returns `None` only on `parseResult == Err`,
  `lsp.mdk:480`), so Tier 1 degrades gracefully: see §5.

**`Loc` bridging in Tier 1: none needed.** Every Tier-1 query is keyed by the
*name* the rule already extracted from the raw decl (the function name, the
shadowed stdlib name), not by a source span. This is exactly why reusing the
LSP's name-keyed channel is sound here and *insufficient* for Tier 2.

The non-aborting accumulator that makes a single harvest safe is
`diagnostics.analyze`/`analyzeLocatedG` (single, `diagnostics.mdk:148-180`) and
`analyzeProject` (project, `:340-353`): they run parse→desugar→resolve→
exhaust→typecheck once, concatenate each stage's diagnostics, and never exit on
error (AGENTS.md "Errors accumulate"). A broken file does not sink the batch
(`wrappedRead` fallback, `diagnostics.mdk:292-305`).

### 4.3 Tier 2 — `typeOfLoc` (STRETCH; re-costed 2026-08-19; see fork §8.3)

Not built. The 2026-06-29 pass scoped this as a new pass walking the typed tree;
§2.3 re-derives it as **three separable pieces**, only one of which is large:

1. **The recorder — small.** `Ref (List (Loc, Mono))`, pushed in `infer`'s
   existing `ELoc` arm, read after the whole-graph post-passes. No typed-tree
   walk and **no zonk**: `Mono`'s `TVar (Ref Tyvar)` is union-find, so recorded
   monos resolve themselves. ⚠️ Read-point constraint: see §10.2 — reading
   per-SCC returns unsolved metavars for value-restricted bindings, and they
   present as a legitimate `Option`-miss rather than an error.
2. **Scoped spans — medium, and NOT this doc's work.** `currentLoc` must stop
   being a last-entered marker before any harvest can trust it (#1752, 8 write
   sites / 33 readers). This is arc work with three other consumers already
   standing on the defect; lint is the *fourth*, not the motivation.
3. **The approximate join — irreducible.** Interior app/binop nodes are
   unwrapped by deliberate parser design (`parser.mdk:843`); pattern *structure*
   carries no `Loc` (binders do — §2.2); `Loc` is not unique. Lookups stay
   "smallest enclosing `ELoc` span." §2.4 is the go/no-go this implies.

---

## 5. Registry shape & integration

Add a third registry parallel to `Rule`/`CrossFileRule`, additive — no existing
rule changes:

```
public export record TypedRule
  name     : String
  descr    : String
  severity : Severity
  enabled  : Bool
  needsTypecheck : Bool          -- False = Tier-0-only (runs even on type-error files)
  check    : TypeOracle -> Positions -> List Decl -> List Finding
```

`allTypedRules : List TypedRule` registry (one fn + one binding + one list entry
per rule, same convention as `allRules`, `lint.mdk:121-123`). Driver mirrors
`lintProgram` (`lint.mdk:149-156`):

```
lintTypedProgram : List TypedRule -> TypeOracle -> Positions -> List Decl -> List Finding
lintTypedProgram rules orc pos prog = flatMap (runTypedRuleOn orc pos prog) rules

runTypedRuleOn orc pos prog r
  | r.enabled && (r.needsTypecheck => orc.typechecked) =
      map (restampSeverity r.severity) (r.check orc pos prog)
  | otherwise = []
```

This is a **third pass** in the lint run, after the per-file `Rule` pass and the
`CrossFileRule` pass. It reuses `restampSeverity` (`lint.mdk:158`),
`findingToDiag`/`lintToLines` (`:251-262`) and the existing `--deny`/`--disable`/
`--only` filtering unchanged (typed rules are filtered by the same name lists).

### Graceful degradation
- **Tier 0 typed rules** (`needsTypecheck = False`) always run — the constructor
  table needs no pipeline and is valid on un-typecheckable files.
- **Tier 1 typed rules** (`needsTypecheck = True`) are **skipped when
  `orc.typechecked == False`** (the file/project has type errors), avoiding
  findings derived from unreliable best-effort schemes. (Alternative, softer
  policy in §8.)
- **Default flag behavior:** gate the whole typed pass behind **`--type-aware`**
  (opt-in) for v1 — it adds a pipeline run per target (cost) and the project
  path needs the loader + runtime/core sources. The Tier-0-only subset is cheap
  enough that turning it *on by default* is a viable fork (§8). When the flag is
  off, the linter behaves exactly as today.

---

## 6. Touchpoints (all additive)

| File | Change |
|------|--------|
| `compiler/tools/lint.mdk` | New `record TypedRule`, `record TypeOracle`, `isIrrefutableArm`, `lintTypedProgram`/`runTypedRuleOn`, the typed-rule fns + `allTypedRules` registry. (`Rule`/`CrossFileRule` untouched.) |
| `compiler/tools/lint.mdk` | New `import frontend.exhaust.{Oracle(..), buildOracle, oGetCtors, oGetCtorType, oGetCtorFields}` and `import types.typecheck.{Scheme(..), Mono(..)}` (Tier 1). |
| `compiler/driver/medaka_cli.mdk` | In `runLintCmd` (`:764-781`): `let typeAware = hasFlag "--type-aware" argv` (`:765-769`; `lintTargets` at `:942` already strips any `--`-prefixed token, so no change there). When set, build the `TypeOracle` (Tier 0 always; Tier 1 via the harvest below) and call `lintTypedProgram` after the existing per-file/cross-file passes. |
| `compiler/driver/medaka_cli.mdk` | New oracle-build helper near the lint helpers (`lintOneFileReport` `:899`, `parseLintFiles` `:813`): single-file mirrors `docSchemes` (`lsp.mdk:479-486`) + `currentLocalSchemes`; project mirrors `checkModules` fed by `loadProgramFilesE`. Reads runtime/core like `runCheckCmd` (`:115-128`). |
| (reuse, no edit) | `compiler/frontend/exhaust.mdk` `buildOracle`/accessors (`:108-190`); `compiler/types/typecheck.mdk` `checkProgramSchemesWithRuntime` (`:7460`), `currentLocalSchemes` (`:1458`), `checkProgramDiags` (`:9314`), `checkModules` (`:9807`); `compiler/driver/diagnostics.mdk` `analyzeProject` (`:340`). |

No seed re-mint expected: `lint` is outside the self-compile graph (per
MEMORY.md "medaka lint" note — adding rules surfaced emitter gaps but the tool
itself does not re-mint), though new `import`s into `lint.mdk` should be
fixpoint-checked (`selfcompile_fixpoint.sh`) since they widen what the emitter
compiles.

---

## 7. Candidate rule catalog (≥4 typed rules)

**(a) Upgrade `rule-bind-then-destructure` → irrefutable single-arm match.
✅ SHIPPED** (confirmed 2026-08-19: `lint.mdk` imports `frontend.exhaust.{Oracle,
buildOracle, oGetCtors, oGetCtorType}` and its `Rule` doc-comment names the
Oracle as the irrefutability logic's single-constructor recogniser). Retained
here as the worked example of a Tier-0 rule; (b)-(d) below remain unbuilt.
Surface shape (raw AST): a `let Pat = e` or a single-arm `EMatch scrut [Arm pat
[] body]` where `pat` is a `PCtor`. **Oracle query:** `isIrrefutableArm orc pat`
(Tier 0 — `ctorCountOfCtor c == Some 1`). Fires only when the constructor is the
sole constructor of its datatype (newtype/single-ctor record), so the match
cannot fail and the bind is safe to flatten. *No typecheck, no `Loc` bridging.*
Highest value, lowest cost — ship first.

**(b) Sharpen §6 `rule-hand-rolled-derivable`.** Current `derivableHit`
(`lint.mdk:442-453`) warns on *any* `impl Eq/Ord/Debug` over a TyCon-headed type,
including imported/abstract/aliased types where `deriving` is impossible.
**Oracle query:** `orc.isLocalType tyName && isSome (orc.ctorCountOfType tyName)`
(Tier 0). Only suggest `deriving` when the type is locally declared with known
constructors/fields — eliminating false positives on types the user cannot
re-declare. *No typecheck.*

**(c) Sharpen §7a `rule-stdlib-reimpl` by signature.** Current `ruleStdlibReimpl`
(`lint.mdk:475-510`) warns purely on name collision against a curated list
(`stdlibNames`, `:469-473`), so an unrelated local `reverse : Matrix -> Matrix`
false-positives. **Oracle query:** `orc.schemeOfTop name` (Tier 1, name-keyed —
no `Loc` needed) compared structurally against the known stdlib scheme for that
name (e.g. `reverse : List a -> List a`). Fire only when the signatures unify.
`needsTypecheck = True` → auto-skipped on type-error files.

**(d) Redundant conversion / wrapping.** Two flavors:
- *Syntactic sub-case (Tier 0/none):* `map id xs`, `xs |> map id` — detect the
  function arg is the bare `EVar "id"`; no types needed (offer as a plain `Rule`,
  not even typed).
- *Type-needing case (Tier 1 name-keyed where possible):* redundant
  `intToString`/`floatToString`/`fromList (toList x)` where the inner expression
  is **already** the target type. When the inner expression is a bare identifier,
  `orc.schemeOfTop`/`schemeOfLocal name` answers it (Tier 1). When the inner
  expression is an arbitrary sub-expression, this needs `typeOfLoc` (**Tier 2,
  deferred**) — which is the rule that motivates the stretch tier but is *not*
  required for v1.

---

## 8. Design forks (need a human decision)

1. **On-by-default vs `--type-aware` flag.** Tier 0 typed rules (a, b, the
   syntactic part of d) need no pipeline run and could be **on by default**
   (they are as cheap as today's rules). Tier 1 rules (c) add a typecheck per
   target. Options: (i) everything behind `--type-aware` (simplest, opt-in);
   (ii) Tier 0 on by default, Tier 1 behind the flag; (iii) auto-enable Tier 1
   only when the project already typechecks clean. **Recommendation: start with
   (i)** for a clean v1, migrate Tier 0 to default once stable.

2. **Whole-project vs per-file oracle.** Per-file harvest (mirror `docSchemes`)
   is simpler and matches the linter's current per-file `Rule` pass, but
   cross-module types are unresolved for imported names. Project harvest
   (`checkModules` + loader) is accurate but costs a full graph load and changes
   the lint effect surface. **Recommendation: per-file for v1**, project as a
   follow-up (the cross-file `CrossFileRule` pass already proves multi-file
   plumbing exists).

3. **`Loc`-keying strategy (the Tier-2 question).** Build a true
   `typeOfLoc : Loc -> Option Mono` (net-new harvest of `(Loc, Mono)` from
   `ELoc` nodes, span-containment index, approximate for unwrapped/pattern
   nodes), **or** stay name-keyed forever and accept that redundant-conversion
   over arbitrary sub-expressions is out of scope. **Recommendation: defer Tier
   2**; revisit only if a concrete rule clearly needs it.

4. **Behavior on type-error files.** Skip Tier 1 rules entirely when
   `typechecked == False` (conservative — proposed default), **or** run them on
   best-effort schemes and risk findings derived from partial inference. Tier 0
   rules are unaffected (no types). **Recommendation: skip Tier 1 on type
   errors.**

5. **Cost / perf.** A typecheck-per-target on large projects is the main cost.
   Mitigations: cache the harvest (the diagnostics path already has a parse cache
   — `loadProgramFilesLocatedCached`, `loader.mdk:601`); only run the typed pass
   when ≥1 typed rule is enabled after `--only`/`--disable` filtering.

---

## 9. Effort estimate

Re-costed 2026-08-19. Changes from the 2026-06-29 pass are marked.

| Piece | Cost | Note |
|---|---|---|
| Tier 0 framework + rule (a) | **small** | ✅ **shipped** — was the estimate, is now the record |
| Tier 1 (name-keyed schemes) + rules (b)(c) | **medium** | unchanged in size; **sequencing changed** — see §10.1 |
| Tier 2 · the `(Loc, Mono)` recorder | **small** | ⬇️ **revised from "large"** — `currentLoc` exists, `Mono` is union-find, no zonk (§2.3) |
| Tier 2 · scoped spans (#1752) | **medium** | ⬇️ **reattributed** — arc work, three other consumers, not lint's to schedule |
| Tier 2 · approximate raw↔core join | **irreducible** | ⬆️ **promoted to the go/no-go** (§2.4) |
| Perf + cache-closure work (any tier ≥1) | **medium** | typecheck per lint target; single-file `contentHash` cache must grow to the import closure or go silently stale |

**Bottom line, revised.** The 2026-06-29 verdict ("Tier 2 is the only large
piece, defer it") reached the right conclusion for a wrong reason. Tier 2's
*machinery* is cheaper than believed — most of it already exists for diagnostics.
What should defer it is not cost but **order and evidence**: the span semantics
belong to the arc and are filed there (#1752, §10.3), Tier 1's current recipe
taxes Stage E (§10.1), and no rule has yet been named that survives §2.4's
approximate join. **Fix the order, then re-ask the question** — do not treat
"Tier 2 is expensive" as the standing reason, because it is no longer true.

---

## 10. Interaction with the typechecker rearchitecture arc (#1122)

Derived 2026-08-19 against `compiler/TYPECHECK-TARGET-ARCHITECTURE.md`. Three
couplings. They are recorded here, on the consumer, rather than as arc units —
with one exception (§10.3) that is genuinely arc work and is filed as such.

⚠️ `TYPECHECK-TARGET-ARCHITECTURE.md` is itself open as **stale in the dangerous
direction** (#1660). Treat component dispositions cited below as claims to
re-derive at implementation time, not as settled facts.

### 10.1 Tier 1's current recipe taxes Stage E-1 (#1115) — sequencing, not design

§4.2 says to build the single-file harvest by mirroring `docSchemes`
(`lsp.mdk`). That is a **Flat-path** consumer. Component E's stated target is
"One driver … The target deletes `CheckMode` entirely," and its migration is
explicitly *consumer-by-consumer*, naming "the repl, LSP hover/single-file env,
playground, single-file doctests, `snapshot`/`check_policy`/`doc`" as consumers
"whose golden families pin Flat behavior."

Building Tier 1 as written therefore **adds a new consumer to the set E-1 has to
drain**, and pins another golden family to Flat behavior on the way.

**The owning unit is #1115 (E-1)** — *"migrate every Flat-path consumer to the
1-module Module path … one PR per consumer, each with its own golden
accounting."* #1116 (E-2) deletes `CheckMode` and is **downstream**: its own body
depends on *"E-1 (no Flat consumers left except the promotion fallback)."*

Census at `8b7b5517` — the live Flat consumers (callers of
`checkProgramSeededSplit` / `checkProgramSeeded` / `checkProgramSchemes` /
`checkProgramSchemesWithRuntime` outside `typecheck.mdk`) are `tools/repl.mdk`,
`tools/lsp.mdk`, `tools/check_policy.mdk`, `tools/doc.mdk`,
`entries/playground_main.mdk`, and `entries/origin_agreement_main.mdk`. **Tier 1
as designed would be the seventh.** ⚠️ The last of those is not in E-1's written
enumeration — it landed 2026-08-02, four days after the set was written (reported
on #1115). Re-derive the set before relying on it; do not read the list above as
durable either.

**Recommendation: hold Tier 1 until #1115 drains**, then write the harvest once
against the single driver. If it must land sooner, write it against whatever seam
E-1 is migrating consumers *to*, and say so in the PR, rather than cloning
`docSchemes`.

### 10.2 The harvest read-point is dictated by E — and getting it wrong is silent

Component E's red-team correction states that schemes are final per-SCC **for
generalized bindings only**: *"non-generalized (value-restricted) bindings keep
live metavariables, so route resolution and defaulting stay whole-graph
post-passes per S's commitment rule."*

**This constraint is arc-owned and already stated on #1117**, in those words —
nothing is owed to the arc here; it needs *obeying* by whoever builds the
harvest. Combined with `Mono` being ref-backed union-find (§2.3), it fixes the
read point: **a `(Loc, Mono)` harvest must be read after the whole-graph post-passes,
never per-SCC.** A per-SCC read returns *unsolved metavars* for value-restricted
bindings — and because the consumer sees an unresolved `TVar`, it presents as a
legitimate "no type here" `Option`-miss rather than as an error. The rule then
abstains on exactly the bindings a reader would least expect, with no signal.

This costs nothing if you know it and is a silent-wrongness bug if you do not,
which is why it is written down here rather than left to be rediscovered.

### 10.3 The expensive blocker is arc work, and is filed: #1752

§2.3's blocker — `currentLoc` is set-on-enter and never restored — is **not a
lint problem**. Three other workarounds already stand on the same defect:
`goalSiteLoc` and its five drain-base-case clears (#1155/F-3c), the record-time
`Option Loc` snapshot duplicated across six tables, and
`pushTypeErrorOnceAt`'s `Option Loc` parameter. Scoping the ref is the shared
repair for all of them, and it serves component D (Diagnostics) directly.

Filed as **#1752** and routed to the arc on that basis; this tier's own tracker
home (**#1754**) records it as a hard, one-way prerequisite. **Type-aware lint is
not a reason to prioritise #1752**, and #1752 does not depend on this doc. If #1752 lands, Tier 2's cost drops to §9's "small"
recorder plus §2.4's go/no-go. If it does not, Tier 2 should not be built at all
— a harvest over the leaky ref is a wrong-line finding machine.

### 10.4 A hazard the arc should see coming

A `(Loc, Mono)` harvest is a **new program-global table keyed by a bare span**,
and `Loc` is explicitly not unique (§2.2). That runs straight into the substrate
section's registry ratchet (*"A bare-`String` key fails the check"* — the #1070
owed gate, which covers "any cross-module-populated map in the pipeline,
regardless of bundle") and into [T-GLOBAL-TABLE]. Any implementation needs a
scoped key and — per [T-GLOBAL-TABLE]'s required fixture shape — a test where
the table is *populated* but the assertion is about code that never touches it.
