# DIAGNOSTIC-CODES-DESIGN.md

**Status:** IMPLEMENTED — Stage 1 `ab61283c`, Stage 2 `761516e6`. Both stages landed:
codes are authored at push sites (`pushIncompleteImpl` → `"T-INCOMPLETE-IMPL"` in
`compiler/types/typecheck.mdk`, `"W-GUARD-INEXHAUSTIVE"` in
`compiler/driver/diagnostics.mdk`), and `cjDiagnostic` (`compiler/driver/diagnostics.mdk:769`)
emits the full `code`/`kind`/`help`/`fix`/`range`/`severity` JSON contract. This doc's own
body never added a closing status line — it still reads as an open plan; treat the "Decided
upstream" box and the contract shape as the current source of truth, not "not yet decided."

Design + census for **stable error codes on every Medaka diagnostic**. Companion
to `ERROR-QUALITY.md` (the grading key / copy standard). This doc is the
implementation design for its §5 machine-readable contract and its "Open
decisions" §1 (code scheme) and §5 (warning-range regression).

**Decided upstream (do not re-litigate):**
- **Push-site threading** — codes are *authored* at each diagnostic-producing
  site (or at a per-stage chokepoint), never inferred by a post-hoc classifier.
- **Scheme: per-stage-prefixed readable kebab codes** — `L-*` lex, `P-*` parse,
  `R-*` resolve, `T-*` type, `W-*` warnings. Exact prefixes + per-kind codes
  proposed in §2.
- **Staging** — Stage 1 = codes + `kind` + the warning `{0,0}`-range fix; Stage 2
  = `help`/`fix` JSON fields. Both designed here; Stage 1 detailed.
- **`range` for an UNLOCATED diagnostic is `null`, never `{0,0}`** (#789). A `Diag`
  with `loc = None` (a genuinely span-less diagnostic — `R-MODULE-LOAD` and every
  other resolve/build-phase error with no node span) renders its `range` as JSON
  `null`. The key is **present with a null value, not omitted**, so a consumer can
  distinguish "diagnostic is unlocated" from "field is missing / older schema".
  `{0,0}` is a real position on source line 1 that a reader or editor would trust,
  so it must never stand in for "no location" — this mirrors the human path's
  `<unknown location>`. A diagnostic that genuinely sits at 0,0 carries a
  `Some (Loc … 0 0 …)` and still renders a real `{0,0}` range; only `None` becomes
  `null`. Renderer: `cjRangeOfLoc`'s `None` arm (`compiler/driver/diagnostics.mdk`).
  The `{0,0}` was OCaml-oracle byte-compat; the oracle was removed 2026-06-26, so
  the rationale is retired.

---

## 0. TL;DR for the orchestrator

- **Distinct error kinds per stage:** DERIVE, never read from here. The codes
  emitted as literals (lex `L-*`, parse `P-*`, warnings `W-*`) enumerate with:

  ```sh
  grep -ohE '"[LPRTW]-[A-Z0-9-]+"' compiler/driver/diagnostics.mdk | sort -u
  ```

  Resolve and typecheck are **ADTs**, so their kinds are counted at the data
  declaration, not by this grep. This bullet used to carry per-stage counts and a
  total; every one of them had rotted (the "lex 4" was 11 by #594), because a
  written-down count has no derivation and no expiry — the same disease #556 fixed
  in `diagnostics.mdk` itself. Run the command.
- **Threading:** three push funcs in typecheck (`pushTypeError`,
  `pushTypeErrorOnce`, `pushTypeErrorOnceAt`) are the only type-error entry
  points → **~55 call sites** must supply a code. Resolve needs **0 call-site
  changes** (one new `resErrorCode : ResError -> Code`, 13 arms). Lex/parse
  attach at their ADT boundary (few sites). **`kind` is DERIVED from the code
  prefix** — only `code` is authored.
- **Golden churn (measured on prototype):**
  - **JSON-only** (code/kind in `cjDiagnostic`): **9** `check_json` goldens (+ a
    handful of LSP JSON goldens). `error_quality` / `native_cli` **unchanged**.
  - **CLI-shows-code** (code in the `ppDiagCliSrc` header): **35** `error_quality`
    goldens + **~57** `native_cli/check` goldens + the 9 JSON = **~100** goldens.
    (`diff_compiler_diagnostics` stays clean iff we keep the code out of `ppDiag`,
    the loc-free diff form — a deliberate lever.)
  - **Recommendation: Stage 1 = JSON-only** (≈9 goldens; satisfies ERROR-QUALITY
    §5 "add `code`+`kind` to every diagnostic"). CLI `[CODE]` is a separate
    opt-in with a one-time ~90-golden recapture.
- **Warning-range locus:** `cjDiagnostic`'s `SevWarning (Some loc)` arm
  (`diagnostics.mdk:528-537`) bakes `path:L:C: Warning:` into `message` and emits
  `{0,0}`. The loc is already snapshotted (`matchWarningLocs`, M2 confirmed); the
  fix is renderer-side + threading loc through the multi-module warn path.
- **Stage-1 size: M.** No re-mint (diagnostics/typecheck self-compile but are not
  the emitter); cost is the ~55 authored codes + fixpoint + golden recapture.

---

## 1. Site inventory (by stage)

Counts are of **distinct error KINDS** (codes map to kinds, not raw sites);
raw-site counts noted where they diverge.

### Lex — `compiler/frontend/lexer.mdk` (`TLexError String`, **5 kinds**)

(Site line-numbers are not tracked here — they rot; grep `lexErrorTok` for the
live set. The kinds are the stable handle.)

| Message | Kind |
|---|---|
| `unterminated string literal` | unterminated-string |
| `unterminated block comment` | unterminated-comment |
| `invalid escape sequence '\x'` (string AND char paths — shared) | bad-escape |
| `character literal must be a single codepoint …` / `… is empty` / `… is not terminated` | bad-char-literal |
| `unexpected character 'c'` | bad-char |

Lexer errors do not reach `Diag` directly — a `TLexError` token is surfaced by
`parseResult` as a `ParseError` (the driver renders it exactly like a parse
error). So an `L-*` code must be recovered from the message or threaded from the
`RawTok`; see §3.

### Parse — `compiler/frontend/parser.mdk` (`ParseError Int Int String`, **~3 kinds**)

~36 distinct `failP "expected …"` / `PErr` messages, **all one ADT** funneled
through `failP`/`PErr`. For coding purposes they collapse to:

| Kind | Trigger | Kind name |
|---|---|---|
| general parse error | every `failP "expected …"` (~34 messages) | parse |
| unexpected EOF | `advanceR TEof` → `"unexpected end of input"` (`:178`) | unexpected-eof |
| `!=` typo | `"unexpected '!=' (did you mean '/=' …)"` (`:3508`) | bad-neq-operator |
| foreign-syntax pre-scans | `parseResult` chain: `/* */` block comment, `if … { }` brace block, `for`/`while` loop, `def`/`function` header, trailing `;` (each a pure token scan that fires only on never-valid Medaka shapes, located at the offending token) | brace-block / for-while / def-keyword / block-comment / semicolon |

(The ~34 `expected …` messages stay distinct *prose* under one code — they are
context, not separate categories. If finer codes are later wanted they can split
without breaking existing consumers, since the umbrella `P-PARSE` is stable.)

### Resolve — `compiler/frontend/resolve.mdk` (`data ResError`, **13 variants = 13 kinds**)

Already a discriminated ADT (`:68`), one `ppResError` arm each (`:1072+`):

`UnboundVariable`, `UnknownConstructor`, `UnknownType`, `UnknownEffect`,
`UnknownField`, `FieldNotInRecord`, `DuplicateDefinition`, `UnknownInterface`,
`MethodNotInInterface`, `ExternWithBody`, `PrivateNameAccess`,
`NoExportedConstructors`, `AbstractFieldAccess`, `UnknownModule`,
`AsPatternMisplaced`, `NonRecursiveValueLet`, `DuplicateBinding`,
`AmbiguousOccurrence`, `InternalExternAccess`.

(That is 19 constructors — I listed "13" loosely above; the true count is **19
resolve kinds**. Each is one code, authored in one place: a `resErrorCode`
function, §3.)

### Exhaust — `compiler/frontend/exhaust.mdk` (**1 warning kind**)

- `guardWarning = "Warning: guards may not be exhaustive"` (`:482`) — the only
  diagnostic produced standalone here (guard coverage on the raw AST).

### Typecheck — `compiler/types/typecheck.mdk` (push sites / kinds + 1 warning)

⚠️ **The counts that stood here (`55 push sites / ~25 kinds`) were stale and are not
replaced with new ones** — a hand-maintained census in prose rots at the next PR, exactly
as the "Distinct-kind totals" note at the end of the code table already says. Derive them:

```sh
grep -cE 'pushTypeError(Once)?(At|HelpFixAt)? "' compiler/types/typecheck.mdk   # push sites
grep -oE 'pushTypeError(Once)?(At|HelpFixAt)? "[A-Z-]+"' compiler/types/typecheck.mdk \
  | grep -oE '"[A-Z-]+"' | sort -u | wc -l                                      # distinct codes
```

The sites all go through `pushTypeError` / `pushTypeErrorOnce` / `pushTypeErrorOnceAt` /
`pushTypeErrorHelpFixAt`; the one warning is a direct `setRef matchWarnings`. Distinct
kinds (enumerated from the message families):

| Kind | Representative message | Code (§2) |
|---|---|---|
| type mismatch | `Type mismatch: <a> vs <b>` (`:2273`,`:2282`,`:2952`) | `T-TYPE-MISMATCH` |
| `!` on a `Bool` | `` `!` is dereference (Ref), not boolean negation — use `not x` `` — #1739 half A repurposed `!` from boolean-not to Ref-DEREFERENCE, so the old use no longer unifies. Intercepted in `derefOp` BEFORE the `Ref a` unify, because the bare `Ref a vs Bool` mismatch it would otherwise produce says nothing about what changed. The advice is in the MESSAGE (not only `help`) because the CLI renderer prints no `help:` line — same shape as the did-you-mean precedent | `T-BANG-ON-BOOL` |
| not a function | `This expression has type <T>, which is not a function …` / `'<f>' takes N argument(s) but is applied to M.` (`inferApp` guard) | `T-NOT-A-FUNCTION` |
| method type mismatch | `Method 'm': expected type <a> but got <b>` (`:2270`) | `T-METHOD-MISMATCH` |
| no impl (class) | `No impl of Num for String` (`:8338`) | `T-NO-IMPL` |
| no impl, PARTIALLY-GROUND goal | `No impl of Conv for Wrap a b` — the same code and the same `pushNoImplError` reporter, reached from a THIRD site: the §3 residual reducer's no-match arm (`residualPredsOf` → `unroutedResidual`), for a goal whose argument vector mixes a concrete head with a still-free variable. **This arm used to be `| otherwise = []` and was SILENT** — the predicate reached neither the binding's scheme, nor any channel's check, nor a diagnostic, so `h x y = conv (Wrap x) y` gave `check` exit 0 on `h : a -> b -> String` and `run` exit 0 printing `int-bool` out of `impl Conv Int Bool`, an impl whose head is not the goal's (issue 1578). ⚠️ **The test is CANDIDACY, not the match that just failed** (`residualRefutableNow`): the goal is reported only when its RECEIVER's head is a concrete tycon — hence stable, since grounding is monotone — and no impl of that interface heads at it or is headless, so `match(IE, π)` is empty now and stays empty at every instantiation. That is DICT-SEMANTICS §4.2 OD1's *structurally refutable* population, not its *ground* one. Keying the reject on the match itself would false-reject every partially-free vector `matchStep` cannot yet decide (`Ix Int t`), which is why the two questions are separate functions. ⚠️ **The candidacy read is the graph-global `bodyImplEnvRef`, deliberately not `residualUnivRef`** — the latter is a topological PREFIX, and a reject keyed on a prefix would reject a program whose only matching impl sorts later, i.e. decide by module order (the `T-REQUIRES-UNROUTED` failure shape). Reading the global registry fails toward DEFERRAL. ⚠️ **A goal that is NOT refutable here is now deferred rather than dropped** (issue 1905, OD2) and gets its verdict at the use site through this same code — `useIx x = ix x 'z'` now infers `useIx : Ix a Char => a -> Int`, and `main = println (useIx 'q')` is rejected as `No impl of Ix for Char Char` on check/run/build, exactly as the hand-written context already was (OD6(a)). Distinct from `T-REQUIRES-UNROUTED` (an impl matches, its evidence is unreachable) and `T-REQUIRES-DEPTH` (impls matched all the way down) | `T-NO-IMPL` |
| no named impl | `No impl named 'x' found for …` (`:7157`) | `T-NO-IMPL-NAMED` |
| infinite type | `Cannot construct infinite type involving …` (`:2229`) | `T-INFINITE-TYPE` |
| ambiguous instance | **TWO messages share this code, at two different judgements.** (1) *undetermined variable* — ``Ambiguous instance for `C`. Cannot determine which impl; add a type annotation`` (`ambiguousImplMsg`): the constraint variable is pinned by neither an argument nor the result, and the interface has ≥2 impls, so no type guides the choice. (2) *ambiguous overlap*, #1155/F-3c — ``Ambiguous instance for `C`. The goal `C (Pair Int Int)` matches `impl C (Pair Int b)` and `impl C (Pair a Int)`, and neither is more specific than the other. …`` (`ambiguousOverlapMsg`): the type IS determined, and the problem is that DICT-SEMANTICS §6 C1's ⊑-minimum does not exist among the matching instances. One code because both are "this predicate has no unique evidence"; two messages because the fixes are opposite — (1) wants an annotation, (2) wants the instance set changed, and telling a user with two overlapping impls to "add a type annotation" is advice they cannot act on. (2) names the competing impls, which is the whole of what makes it actionable. Distinct from `T-CONFLICTING-IMPL`, which is the DECLARATION-time (§6.1 condition (a)) rejection of the same overlap; a program can carry both, at two different sites | `T-AMBIGUOUS-INSTANCE` |
| ambiguous field | `Ambiguous field access: '.f' …` (`:3851`) | `T-AMBIGUOUS-FIELD` |
| ambiguous shadow declaration | ``'mth' is ambiguous here: 'IA' (from 'amodI') and 'IZ' (from 'zmodI') each declare a method 'mth' and are both in scope, and they do not agree on what 'mth' denotes at this call.`` (`pushAmbiguousShadowDecl`) — `docs/spec/SHADOW-SEMANTICS.md` **S2-DECL (d) bullet 3**, implemented 2026-08-30 ([#2188](https://github.com/MedakaLang/medaka/issues/2188)) at the code that clause's own S2-DECL-SCOPE note had **RESERVED** for it. Fires when an occurrence of a name that is a shadow under S1 has **two or more admitted declarations** (S1-NS (a): the interface name OR the method name is nameable in `M`) whose OWN (receiver argument, impl query) pairs — both halves from the same declaration, per (b) — yield **different denotations**. Located at the APPLICATION NODE, not at the argument and not at the `import`: unlike `T-AMBIGUOUS-ALIAS-METHOD` and `T-AMBIGUOUS-REEXPORT`, whose collisions are decidable from the import list alone, this one depends on the RECEIVER's head tycon and so cannot exist until there is a call to point at. ⚠️ **Distinct from `T-AMBIGUOUS-INSTANCE`**, which is *"this predicate has no unique evidence"* for a determined type; this is *"two admitted declarations disagree about what this NAME denotes"* — the interfaces here are unrelated and the impl sets are not in competition. ⚠️ **Distinct from `R-DUPLICATE-IFACE-METHOD`**, its intra-module declaration-time peer, which explicitly does not cover the cross-module case. ⚠️ Two or more admitted declarations that AGREE are **not** reported — (d) bullet 2 — and since two distinct interfaces can never yield the same impl, agreement at cardinality ≥2 means they all fall to the standalone. Help names the two fixes (bring only one interface into scope; or rename a method); no machine-applicable `fix`, because the repair is an `import`-list edit whose right shape depends on what else that clause is bringing in. Pinned by `test/shadow_fixtures/i27_importer_two_admitted_disagree/` (verdict, both import orders) against its accepting twin `i28_importer_two_admitted_agree/` | `T-AMBIGUOUS-SHADOW-DECL` |
| ambiguous alias-qualified method | ``'A.mth' is ambiguous: this alias names more than one module declaring a method 'mth' — 'ifa' and 'ifb'. …`` (`aliasAmbiguityMsg`) — one alias name bound by two or more `import … as A` lines whose modules export the same method spelling from DIFFERENT declarations, so the `A.<method>` key #1386's alias-qualified obligation supply mints is claimed by more than one declaration identity. Reported **at the last colliding `import`**, not at the occurrence, for the reason `R-DUPLICATE-IFACE-METHOD` is: the ambiguity becomes unrepresentable rather than merely unreported, and the verdict stops depending on which `import` came first. ⚠️ IDENTITY, not module id, is the discriminator — a re-export hop reaches ONE declaration through two module ids and is not ambiguous; the same module aliased twice under one name is not either | `T-AMBIGUOUS-ALIAS-METHOD` |
| ambiguous re-exported value | ``Ambiguous `g` imported from `lib.hub`. Defined in lib.pa and lib.pb`` (`ambigReexportMsg`) — a module IMPORTS a bare VALUE name that the named dependency exports under **two different definitions**, which is what a re-export hub (`export import lib.pa.{g}` + `export import lib.pb.{g}`) makes of one spelling. Before this code the importer silently took the first, so which function ran was decided by the ORDER OF THE HUB'S TWO `export import` LINES — a semantically null edit moving the program's printed value from `2` to `10` at exit 0 on every verb, `check --json` included (issue 1675, S0). ⚠️ IDENTITY, not module id, is the discriminator, exactly as in `T-AMBIGUOUS-ALIAS-METHOD`'s row: the rows are deduped on the whole `(definer module, name at the definer)` pair, so a DIAMOND — one definition reached through two re-export hops — is ONE denotation and stays legal. ⚠️ The dependency's OWN declaration SETTLES the name rather than participating (`ambiguousExportRows`' `mid` test), matching `graphPubDefiners`' "declared names come first" and resolve's `keepAmbiguous`, which drops any name with a same-module top-level value shadow. Reported **at the import decl** (that is where the location points and where the fix belongs) but keyed on an **OCCURRENCE**: the name is rejected only where the importing module actually WRITES it, in the spelling its import form binds it under — bare for `import m.*` and for a selective `{g}`, alias-qualified (`A.g`) for `import m as A` (`ambiguousAdmitted`, `moduleRefNameSet`). A hub that re-exports a colliding name an importer never mentions does NOT reject that importer; the hub ITSELF stays legal either way (the decided USE-SITE ambiguity model; issue 1070's reject-at-declaration remedy is superseded). ⚠️ The occurrence narrowing does not launder the collision through a silent hop: `reexportDefiners` takes a wildcard `export import`'s rows WHOLESALE, so a module re-exporting the hub without mentioning the name carries the ambiguity into its own export table and the first module downstream that writes it is rejected there. ⚠️ `T-AMBIGUOUS-ALIAS-METHOD` — cited as this rule's precedent for the identity discriminator above — is deliberately NOT followed on this point: it is a different namespace, where methods dispatch by argument type and having the method callable is often the whole point of the import, so "admitted" and "used" are much harder to pull apart there. ⚠️ Distinct from `R-AMBIGUOUS-OCCURRENCE`, which fires on ≥2 IMPORTED SPELLINGS in one scope and cannot see this — a hub is ONE provenance, and the collision lives inside its export table | `T-AMBIGUOUS-REEXPORT` |
| unknown field | `Unknown field: f` / `Field f does not belong to record R` (`:2985`,`:3720`) | `T-UNKNOWN-FIELD` |
| field not in all ctors | `Field 'f' is not declared by every constructor of 'T': constructor 's' has no 'f'. A 'T' value carries no constructor tag, so '.f' cannot be resolved; match on the constructor instead` (`fieldNotInAllCtorsMsg`, `:10579`) — #1468/F1: a field access `.f` where `f` is declared by SOME but not ALL constructors of `T`, so no fixed slot exists across every value of the type. Distinct from `T-UNKNOWN-FIELD` (no constructor declares `f` at all) and `T-ABSTRACT-FIELD` (the field exists but is not exported) | `T-FIELD-NOT-IN-ALL-CTORS` |
| missing field | `Missing field f in construction of record R` (`:3732`) | `T-MISSING-FIELD` |
| abstract field | `'T' is exported abstractly; its field 'f' …` (`:3812`) | `T-ABSTRACT-FIELD` |
| unknown record | `Unknown record type: R` (`:2958`,`:3906`) | `T-UNKNOWN-RECORD` |
| unknown ctor | `Unknown constructor: C` (`:3010`) | `T-UNKNOWN-CTOR` |
| unbound var (tc) | `Unbound variable: x` (`:3911`) | `T-UNBOUND` |
| missing constraint | `Could not deduce 'Eq a' … add 'Eq a =>'` (`:9628`) | `T-MISSING-CONSTRAINT` |
| recursive alias | `Recursive type alias \`x\`` (`:2661`) | `T-RECURSIVE-ALIAS` |
| alias arity | `Type alias \`x\` expects N argument(s), got M` (`:2793`) | `T-ALIAS-ARITY` |
| row in non-row-kinded slot | `A row <…> was written here, but this type-argument position isn't row-kinded — it expects an ordinary type, not an effect row. …` — a bare row atom (`<Stdout>`, #997) or the pre-#997 degenerate `(<Stdout> T)` spelling used as a type argument whose declared parameter kind is `Type`, not `Row` (`List <Stdout>`, `data Holder = Holder <Stdout>`). Before #997 this was a parse error; `fromAstTypeE`/`reqTyToMono` still fall back to an inert `Unit` Mono after pushing the error so inference can continue. **The MIRROR direction shares this code** (#1094): ``The type `Int` was written here, but this type-argument position is row-kinded — it expects an effect row, not an ordinary type. …`` — an ordinary type written into a *row*-kinded slot (`Box Int Int` where `Box`'s first parameter has kind `Effect`), which `rowArgOf` used to coerce silently to `<>`. Same rule, opposite seam, so it takes the same code rather than half-applying the decided `T-ROW-KIND-MISMATCH` → `T-EFFECT-KIND-MISMATCH` rename (EFFECTS-SEMANTICS §6.4, §6.9 Q2) at one site out of three; `rowArgOf` likewise falls back to an inert `pureRow` | `T-EFFECT-KIND-MISMATCH` (renamed from `T-ROW-KIND-MISMATCH` per EFFECTS-SEMANTICS §6.4, with `kindName KRow` now rendering `Effect`). ONE code for every seam of the declared-kinds rule (§6.9 Q2 resolved): the use-site row-in-Type-slot / type-in-Effect-slot checks above, and — from `checkDeclaredKinds`, §6.4/§6.5 — an UNANNOTATED parameter used as an effect row (`unannotatedRowParamMsg`, the compulsory-migration case), a declared `(p : Type)` used as a row, a declared `(p : Effect)` used as an ordinary type, an Effect-bearing arrow kind on a data/alias head, an unannotated interface parameter the methods use as an effect-indexed constructor (`unannotatedGradedParamMsg`), a declared interface slot the methods use as a row, `(p : Effect)` on an interface parameter, and a `requires` clause whose parameter kinds disagree with the superinterface's (`requiresKindMsg`, same module) |
| effect leak | effect-leak message (`:906`) Since #821 the same code also carries `joinMismatchMsg` ("Effect rows … cannot be made equal: each carries an effect variable the other side has no room for") from `unifyJoinRows` in ARROW mode: a rigid member (a method effect variable of the impl body being checked) left over on one side with nothing flexible to absorb it — the #825 shape, a callback's row stored under a pure arrow | `T-EFFECT-LEAK` |
| effect index mismatch | `Effect index mismatch: <Stdout> vs <>. An effect row written as a type argument is invariant — the two rows must be EQUAL, not merely compatible …` — two index rows with **nothing left to solve** meeting in an `Effect`-kinded type-ARGUMENT (index) slot: either both CLOSED (`quiet : Box <> Int = (loud : Box <Stdout> Int)`) or both already ending in the **same effvar cell** with differing prefixes (`launderBox : Box <Stdout \| e> a -> Box e a`). EFFECTS-SEMANTICS §9 "Index fidelity": an index is INVARIANT, so no direction of the row order `≤` is licensed there (a contravariant index is writable — `data Sink e = MkSink ((Unit -> <e> Unit) -> Int)` — so widening in *either* direction launders). Distinct from `T-EFFECT-LEAK`, which is an ARROW's latent row meeting a bound and *is* sub-effected via re-open; the arrow message would read as a lie here because nothing is performed at the point of mismatch. An index row that still has a **metavariable to solve** is NOT diagnosed and unifies through the ordinary row arms — open~closed binds the tail to the exact difference (instantiation, not interchange: `mkPure : a -> Async <> a`), and two DISTINCT open tails unify to their join, which is the most general row equal to both. #1094 Since #821 `unifyJoinRows` in INDEX mode reports the same code with `joinMismatchMsg` when a join's rigid member has no counterpart | `T-EFFECT-INDEX-MISMATCH` |
| effect param | `Invalid effect parameter on <L>: …` / host-pattern (`:972`,`:993`) | `T-EFFECT-PARAM` |
| extern row missing FFI | `Foreign declaration 'f' does not name the 'FFI' effect in its result row. Every user-declared 'extern' is a foreign call, so its declared row must say so: write '<FFI>' … joined with whatever else the row already names …` (`ffiUnlabelledMsg`) — F1 (epic #2070): a user-declared `extern` whose terminal result row omits the `FFI` label, in EVERY shape — a written `<Net "a.com/*">`, a bare `<>`, or no row at all. It replaces a SILENT REWRITE: `userExternSchemes` used to add the atom whenever it was missing, so the row in the source and the row the effect system enforced were two different rows and a signature could not be written honestly and believed. Located at the signature's first located head (`firstTyLoc`), because `DExtern` carries no `Loc` and the offending row may not exist to point at. Gated on the same `ffiStampMode` ownership Bool and the same `ffiIsBuiltinExternName` exemption as `T-FFI-NONCROSSABLE`, deliberately: a stdlib-owned program's catalog IS the effect vocabulary, and a redeclaration of a catalog name is lowered as the builtin whatever its local row claims (that exemption's own admission test is `T-FFI-BUILTIN-SHADOW`). A nullary `extern k : Int` is the SIBLING arm `T-FFI-NULLARY`, not this one: it has no row to be missing a label from | `T-FFI-UNLABELLED` |
| extern type not crossable | `Type 'List Int' cannot cross the foreign-function boundary in extern 'f'. A foreign declaration may only mention Int, Float, Bool, Char, String, Unit, or Array Int …` (`ffiNonCrossableMsg`) — #2074: a user-declared `extern` naming a type outside `compiler/FFI-ABI.md` §1's CLOSED crossable set at any param or result position. A different axis from `T-FFI-UNLABELLED` (which row is declared, not which types cross); one signature can honestly earn both | `T-FFI-NONCROSSABLE` |
| extern nullary (no arrow) | `Foreign declaration 'k' has no arrow in its signature, so it declares a foreign VALUE rather than a foreign call. Medaka cannot express that: an effect row lives on an arrow's result, so there is nowhere to write the required '<FFI>' label, and the emitter has no lowering for a foreign value — it would hand you a function pointer where a value is expected. Declare it as a call instead: 'extern k : Unit -> <FFI> T', invoked as 'k ()'` (`ffiNullaryMsg`) — S0-2 of the `ffi-lower-and-link` review round. The `None` arm of `ffiRowHasFFITy`, which USED to fall through to a pass; while it did, the #2074 emitter still lowered the name as a foreign call (`emitVar`'s `isFfiExtern` arm → `emitFfiEtaClosure`) and an `Int`-typed name evaluated to an eta CLOSURE POINTER at exit 0, where before that lowering the program died loudly with `unbound variable` ([W-QUIETER]). Same gating and same builtin-name exemption as `T-FFI-UNLABELLED` — it is that rule's other arm, not a separate loop. ⚠️ CLOSES #2106 (how a nullary extern *would* spell a label). The `ffi-boundary-honesty` sprint measured the alias-wrapped spellings this rule was thought to miss — `type A = Int; extern k : A` and `type A a = Sh a => Int; extern k : A Int` — and both produce the byte-identical `T-FFI-NULLARY` diagnostic the plain `extern k : Int` spelling gets, via the same path (`expandAliasHeadTy` unwraps both alias shapes to a bare `TyCon` before `ffiRowHasFFITy` matches). The design question resolves as *there is no spelling and none is needed*: an effect row lives on an arrow's result, so a nullary foreign declaration is refused rather than labelled, and `extern k : Unit -> <FFI> T` is the whole answer. Pinned by `ffi_nullary_alias_direct_reject.mdk` / `ffi_nullary_alias_constrained_reject.mdk` in `test/effect_builtin_param_domain_test.mdk` | `T-FFI-NULLARY` |
| extern shadows a builtin, incompatibly | `Foreign declaration 'log' redeclares a built-in runtime name with an incompatible signature: the built-in is 'Float -> Float', this declaration claims 'String -> Unit' (type heads only; effect rows are not compared) …` (`ffiShadowMsg`) — S0-3 of the `ffi-lower-and-link` review round. The ADMISSION TEST for `ffiIsBuiltinExternName`'s exemption, which was keyed on the bare name and had been measured only on *compatible* redeclarations (`bitAnd`, `getEnv`): an incompatible one got the same free pass, and `extern log : String -> <FFI "mylog"> Unit` compiled to `call double @mdk_log(double <String cell pointer>)` at exit 0 with the author's own C `log` never called. A rejection rather than a re-route through `T-FFI-NONCROSSABLE`/`T-FFI-UNLABELLED`, because that re-route was MEASURED not to close it — the `log` signature passes both of those guards on its own terms, and the emitter's half of the exemption (`ffiExternRows`' catalog subtraction, `emitApp`'s `isAnyExtern` test before the FFI arm) is name-only and reads no typecheck verdict. Compared at TYPE-HEAD granularity (argument heads + return head, rows and constraints walked through, type variables normalised), the same projection the emitter's FFI index stores | `T-FFI-BUILTIN-SHADOW` |
| extern narrows a builtin's effect row | `Foreign declaration 'writeFile' redeclares a built-in runtime name with a NARROWER effect row: the built-in performs <FileWrite>, this declaration claims <>, which does not cover <FileWrite> …` (`ffiCatalogNarrowMsg`) — #2163, the `ffi-boundary-honesty` sprint. The FIFTH declaration rule, and the one that closes epic #2070's own R2 escape-hatch sentence for the 138 catalog names. `T-FFI-BUILTIN-SHADOW` compares TYPE HEADS and walks *through* effect rows by design, so `<>` and `<FileWrite "_">` are one shape to it: `extern writeFile : String -> String -> <> Result Unit String` passed every rule, typed its caller `String -> Unit`, and the emitter (name-keyed via `isAnyExtern`/`ffiExternRows`, never reached by a typecheck verdict) still lowered the call to the real `writeFile` — a function `medaka check` printed as pure, writing to disk at exit 0. SUBSUMPTION, NOT EQUALITY, AND NOT A BAN: the declared row must COVER the catalog's own row and may be wider, because over-declaring is the safe direction — so `extern putStrLn : String -> <IO> Unit` stays legal against the catalog's narrower `<Stdout>`. Reuses `atomsEscape` (the existing escape-direction `atomsDiff` with the BOUND's `IO` widened to its security-label alias), with the DECLARED row as the bound and the catalog row as what is really performed; it is not a second subset predicate. Both rows are lifted to atoms at the CHECK seam, never at the catalog-seed seam, because `atomsOfWritten` resolves labels against `driverState.effectDomains` and the seed can run before that registry is populated. Silent by construction for the ~100 catalog rows that write no effect row at all (`bitAnd`, `arrayBlit`, the math family): the empty row is covered by everything. Distinct from `T-FFI-BUILTIN-SHADOW` on the axis it compares (row vs. shape) — one declaration can honestly earn both | `T-FFI-CATALOG-NARROW` |
| extern claims a reserved name | `Foreign declaration 'mdk_nil' claims a reserved name: the 'mdk_' prefix is the Medaka runtime's own C symbol namespace (runtime/medaka_rt.c), and a foreign declaration's name is used verbatim as the C symbol it links to …` (`ffiReservedMsg`) — S0-4 of the `ffi-lower-and-link` review round. UNCONDITIONAL: no signature test (a *mismatched* signature was already loud — clang rejects the conflicting `declare` — while the silent half is the MATCHING one, which for an allocator- or cell-shaped internal is heap-corruption-shaped, not merely a wrong value) and no builtin-name exemption (the catalog holds no `mdk_`-prefixed row, so the two rules cannot collide). Distinct from `T-FFI-BUILTIN-SHADOW`, which is about *incompatibility* with a legitimate builtin; this one is a namespace ban | `T-FFI-RESERVED-NAME` |
| under-determined effect var | `Under-determined effect variable <e> in method 'm' of interface 'I': …` — an interface method with a free effect tail var in RETURN position but no argument position (#784 Option A; dispatch could launder the effect) | `T-EFFECT-UNDETERMINED` |
| effect launder (impl body) | `Effect laundering in impl of 'm' for interface 'I': the body performs <X>, …` — an impl method body performing an INTRINSIC effect (not sourced from any argument) that is absorbed into a declared effect var and laundered to pure at the call site (#803; distinct from `T-EFFECT-UNDETERMINED`, which is signature-shape, and `T-EFFECT-LEAK`, which is a concrete/pure declared row) | `T-EFFECT-LAUNDER` |
| effect arg-occurrence uncovered | `Argument-only effect variable <e> in method 'm' of interface 'I': …` / `Effect variable <e> … carries <X> at an argument position, but a method row carrying <e> does not include it …` / `Effect variable <e> in function 'f' carries <X> at an argument position, but a row carrying <e> does not include it …` — the dual of `T-EFFECT-UNDETERMINED`: an effect var's ARGUMENT occurrences are rows an impl (or caller) can perform by using that argument, so a var appearing in no non-argument row (argument-only), or carrying argument-side atoms some non-argument occurrence lacks (uncovered), is rejected at the declaration (adversarial break 4 of #816; must be declaration-time — the same-tail row-unification arm loses the atom). ⚠️ **TWO SCOPES, NOT ONE.** The ARGUMENT-ONLY arm stays interface-method-only (`Some iface`, `argOnlyEffVarMsg`) — a direct top-level call is rejected at the CALL SITE instead (an ordinary effect-escape diagnostic), so widening this arm to plain functions would only false-reject honest inspectors of a row-kinded value. The UNCOVERED-ATOMS arm (#1103, slice 1/D-1) is NOT method-only: `checkArgEffVarCoverage` also runs over plain `DTypeSig` top-level signatures with an empty graded scope (`checkUndeterminedRetEffVarsDecl`, `iface = None`), because the same-tail row-unification hazard survives an ordinary top-level arrow just as readily as a method (`launderArrow : (Unit -> <Stdout \| e> Unit) -> (Unit -> <e> Unit)`); that arm's message names `in function 'f'` (`argAtomsUncoveredFnMsg`) rather than `in method 'm' of interface 'I'` | `T-EFFECT-ARG-UNCOVERED` |
| effect param variance mismatch | `Effect row mismatch inside a non-covariant type argument: <X> vs <Y>. This type parameter is used contravariantly, or behind a mutable cell, so the two rows must be EQUAL — weakening one to the other would let an effectful value be reached through a type that no longer mentions its effects. Write the same effect row on both sides. If the value here performs FEWER effects than the slot permits, that narrowing is safe but is still rejected, because unification is symmetric here and cannot tell which side is the declaration; eta-expand the mismatched function to recover — write `(s => f s)` in place of `f`, and when that function is nested inside a wrapper value here, rebuild the wrapper around the eta-expanded function (e.g. `Ref (s => f s)`). A value that performs MORE effects than the slot permits is rejected either way, so this recovery cannot widen a row.` (`paramVarianceMismatchMsg`) — D-2 (#1119, slice 4): a parallel structural walk (`paramVarianceCheck`/`paramVarianceCheckN`) of two argument types being unified at a type-CONSTRUCTOR application (`TApp`) reports every CLOSED~CLOSED arrow-row pair whose atoms differ, when that type parameter's computed POLARITY (`dataParamPolarityRef`, per-parameter — contravariant, invariant, or a mutable-cell seed for `Ref`/`Array`) is not plain covariant. Closes the #1098/#1121 launder family (write-channel and contravariant-domain widening): before this code, `substMonoP`'s `TApp` arm propagated the SAME `pos` unchanged into every nested type argument regardless of the constructor's own variance, so a value whose type carried an effect row could be silently widened through a non-covariant parameter (a `Ref`'s stored function, a function-typed field's domain) and the row would be laundered away at the point the caller reads it back. Distinct from `T-EFFECT-INDEX-MISMATCH` (an `Effect`-kinded index argument, INVARIANT by kind, not by a computed data-parameter polarity) and from `T-EFFECT-LEAK` (an arrow's own latent row meeting a bound, not a nested type argument). Does not cover higher-kinded type-constructor heads or type aliases (#2107, #2108) — `dataParamPolarityRef` is seeded from ordinary first-order `data` declarations' constructor fields only. **The safe direction at a FRESH value is accepted (#2109):** a signed clause's body is inferred RESULT-FIRST against the signature (`inferExpected`), so `handler = Ref noop` at `Ref (String -> <Stdout> Unit)` meets the declaration while `Ref`'s slot is still a metavariable, the guard abstains, and `noop` is then checked against the DECLARED field type by the ordinary arrow-row rule. The order changes nothing for an already-typed value: `alias = idr box` (the #1098 laundering) pins `idr`'s result first and then meets `box`'s closed row as closed~closed, rejected as before. What remains rejected is therefore exactly the alias of an existing cell, in either direction; the eta-expansion recovery the message names is still valid for the cases the result-first order does not reach (an unsigned binding, a lambda-argument head). The result-first order is made sound by `checkArgSubEffect`: every argument is checked DIRECTIONALLY against its pinned domain before the lenient arrow unify, so `Ref loud` at `Ref (Int -> <> Int)` is `T-EFFECT-LEAK`, not accepted | `T-EFFECT-PARAM-VARIANCE` |
| effect index eager | `Impl of 'gmap' for interface 'GMap' performs the effect variable <e> at call time, but the method's signature charges <e> only in a result INDEX (`f e …`), which promises the effect when the value is later forced, not now. …` (`indexEagerMsg`) — D-3 (#1095): under a GRADED signature whose only non-argument occurrences of an argument-carried effect variable are result INDICES (`gmap : (a -> <e> b) -> f e a -> f e b`), an impl that APPLIES its `<e>`-callback (or FORCES an `<e>`-indexed argument) performs `<e>` on an arrow the signature declares pure, which closes the rigid `e := <>` — the caller's effectful callback then runs from a call typed pure, with `check` green on both engines. Detected post-unify in `checkImplEffVarRigidity` (`checkIndexOnlyEffVarsOpen`): an INDEX-ONLY variable (`indexOnlyEffVars`) whose cell normalizes CLOSED. Scoped to index-only variables on purpose — a variable the method's own arrow charges (`map : … -> <e> f b`) may still close (the compiler's own `impl Mappable Parser` does; #825's channel, pinned, out of scope). Distinct from `T-EFFECT-ARG-UNCOVERED` (declaration shape — which a result index legitimately DISCHARGES; Val's #1095 comment shows removing that discharge reverts #822) and from `T-EFFECT-LAUNDER` (a concrete atom poured into the variable; here no atom is involved, the variable is CLOSED) | `T-EFFECT-INDEX-EAGER` |
| impl pins method-scheme var | `Impl of 'm' for interface 'I' pins the method's quantified type variable(s) 'b' …` / `… identifies quantified type variables …` / `… identifies effect variables …` — an impl (or specialized default) method body constrains a caller-owned quantified variable of the method scheme: pins a type var to a constructed type, identifies two of them (or one with an impl-head var), or identifies two effect vars (W3 method-scheme fidelity, DICT-SEMANTICS §3; #814).  The effect-atom half of the same check (an atom poured into a method effect var at an occurrence whose declared row lacks it) reuses `T-EFFECT-LAUNDER`. Since #823 the former #817 carve-out is gone: a method effect variable identified with an INSTANCE-HEAD row parameter (`impl Mappable (Async e)` storing the callback under the head's `<e>`) is also this code (`aliasesHeadRowMsg`) — implement the `Deferred*` family for an effect-indexed constructor instead | `T-IMPL-TOO-SPECIFIC` |
| graded instance head kind | ``Instance head has the wrong kind for interface 'GThenable': the interface's type parameter is graded — kind `Row -> Type -> Type` — but `Box` has kind `Type -> Type -> Type` …`` / ``… but this head already applies 1 argument(s) to `Async`, leaving kind `Type -> Type` …`` — an `impl` of a GRADED interface (one whose type parameter is row-indexed, `f : Row -> Type -> Type`; EFFECTS-SEMANTICS §6, #822) whose head does not carry a `Row` parameter at the interface's `Row` slot, or which fixes the row by applying the family (`impl I (Async e)`). Soundness, not polish: the method type's `Row` slot elaborates to a `TEff` row while the constructor's own scheme has a plain tyvar there, and `unify` binds the two silently — the impl would be accepted with a grade that means nothing. Deliberately ABSTAINS when the head's kind is not knowable (a type alias — already policed by `T-ALIAS-ARITY` — or a head absent from the kind table, which includes an abstractly-exported row-indexed type, #804) | `T-IMPL-KIND-MISMATCH` |
| non-recursive value let | `'x' is not in scope on the RHS of its own binding …` (`:4923`) | `T-NONREC-VALUE-LET` |
| local binding not constraint-polymorphic | `local binding 'h' is used at two different types (Bool and String), but it cannot be polymorphic: its body calls something that needs a 'Debug' instance, and only top-level definitions can carry that constraint` — a `let`/`where` member whose body forwards a constrained callee's dictionary is NOT dict-abstracted (it lowers to one lifted lambda with one shared route ref), so typecheck declines to generalize it over that variable (`pinLocalIfDictForwarded`); a second use at a different type then collides. Located at the **binding**, not the second use — the binding is what the user changes. Carries a `help` naming both fixes (lift to top level; or use at one type). Replaces the bare `T-TYPE-MISMATCH` this used to surface as, and only when exactly one pinned binding matches (`pinnedLocalExplain` — see its conservatism rules). #866 / #1021; the narrowing is deliberate and signed off, and is retired by dict-abstracting local bindings. ⚠️ THREE detection channels emit this ONE code, sharing one renderer (`pinnedLocalReport`): the ordinary unification failure above (`pinnedLocalMismatch`, two ground types); the SIGNATURE-TYVAR COLLAPSE (`reportSigTooGeneral` → `pinnedLocalCollapsedInto`), where the enclosing function has an explicit signature and the pin merged two of ITS declared variables, so the message names those variables (`the signature's 'a' and 'b'`) instead of two ground types — that case used to surface as the cause-blind `T-TYPE-TOO-GENERAL` (#1052), and an UNCORRELATED signature-too-general still does; and — since #1986 rung 2's voice pass — the NUMERIC-LITERAL REFRAME (`reportNumOrNoImpl` → `reportNumlitMismatch` → `pinnedLocalExplainOne`), which is where a pin used at a bare literal lands. That third channel is NOT a unification failure at all: the literal's variable unifies with the grounded pin and it is the residual `Num T` OBLIGATION that fails, so `pinnedLocalExplain`'s two-type query is never consulted and the shape used to print a bare `Type mismatch: Int literal vs Bool` caretted on the literal, while the SAME program with a non-literal `Int` got this diagnostic. `pinnedLocalExplainOne` is the one-type form of the same query, guarded identically (grounded head, same file, exactly one responsible binding), so a program with no pinned binding keeps every literal-mismatch message byte for byte. ⚠️ The pin match is REACHABILITY, not rendering equality: a collision one level BELOW the pinned head (`Box Bool` pinned, `Bool` vs `String` reported) is still this pin, and the two types the message names are the ones the binding was USED AT (`Box Bool and Box String`), reconstructed by substituting the collision's other side back into the grounded type — never the raw inner pair, which would be a true statement about the wrong pair | `T-LOCAL-CONSTRAINED-MONO` |
| do not a monad | `do requires a monad` | `T-DO-NOT-MONAD` |
| `<-` bind outside do | `bindOutsideDoMsg` — `<-` in a bare (non-`do`) block | `T-BIND-OUTSIDE-DO` |
| discarded statement value | `this statement's value (<Type>) is silently discarded — only a Unit-typed expression may stand alone as a statement` (`discardedValueMsg`) — a non-final, non-`let` bare-block statement (`DoStmt.DoExpr`) whose inferred type does not unify with `Unit` (`checkStmtNotDiscarded`). A free/unconstrained result var is pinned to `Unit` via plain `unify` and never reaches this code — only a CONCRETE non-`Unit` type does. Carries a `help` naming the fix (`let _ = …`) and, when the statement's own span is recoverable (`exprLoc`), a machine `fix` inserting it; `exprLoc` returns `None` for a bare unparenthesized application (the common case — the outer `EApp` carries no `ELoc`), so `fix` is frequently absent and the location falls back to `currentLoc` (the innermost sub-expression `infer` last entered) rather than the statement's own start. Distinct from routing through bare `unify`, which would render the generic `Type mismatch: Int vs Unit` (ERROR-QUALITY.md dims 3/5: doesn't name the rule or offer the fix) | `T-DISCARDED-VALUE` |
| cyclic superinterface | `cyclic superinterface: …` | `T-CYCLIC-SUPERINTERFACE` |
| conflicting impl | `conflicting \`impl X\`: defined in … and …` | `T-CONFLICTING-IMPL` |
| incomplete impl | `'impl Iface Ty' is missing method 'm'. …` — an impl omits an interface method that has no default body (P0-17) | `T-INCOMPLETE-IMPL` |
| `requires` chain too deep | ``Cannot resolve this constraint: following the `requires` clauses of the matching impls exceeded the maximum depth of 32, and still needed `Tag (Wrap a)` after 32 steps. …`` (`requiresDepthMsg`) — §3 `inst` reduction of a `requires` residual at a generalizing binder (`residualPredsOf`) hit `residualReduceFuel`. **A resource limit reported as a reject, and it is deliberately not silent**: continuing would drop the predicate from the binding's inferred context *and* from its `λd̄.` dict prefix, which is issue 1549's S0 (`check` exit 0 on a scheme with no context, and a binary that reads an unpassed dict word) — issue 1562. **Exactly ONE shape is known to reach it: genuine nesting deeper than 32 `requires` steps.** ⚠️ A self-naming `requires` (`impl C (Box a) requires C (Box a)`) is the obvious second candidate and **does NOT reach it** — measured, that program aborts `check`/`run`/`build` at exit 134 with `E-STACK-OVERFLOW` (identically before and after #1562's fix), because something upstream of this fuel-bounded walk diverges first; that crash is pre-existing and is filed as issue 1575, and the message deliberately does not offer advice its reader can never see. ⚠️ Nor is this code a general "deep chain" reject: a GROUND `requires` chain is never deferred over a bound tyvar, so it never reaches this reducer at all. That used to mean it was silently accepted past depth 33 and then segfaulted (issue 1576, issue 1836); since #1576's fix the ROUTE-side fuse it does reach (`argImplRequiresRoutes`) spends fuel only on NON-SHRINKING steps, so a ground chain of any depth now resolves correctly and there is nothing left there for this message to say. Distinct from `T-NO-IMPL`, which is "no instance matches"; here instances matched all the way down and the chain did not bottom out. The goal rendered is the one still OUTSTANDING at exhaustion, not the one originally posed — the message says so, because after 32 steps it is one level deep and would otherwise read as trivially shallow. Located at the recording site through `goalSiteLoc`, not at whatever `currentLoc` holds at the group's close | `T-REQUIRES-DEPTH` |
| `requires` evidence cannot be routed | ``Cannot pass a dictionary for `Tag (Wrap a)`: a matching `impl Tag …` does exist in this program and is a candidate here, but this compiler cannot yet route its evidence to this code …`` (`requiresUnroutedMsg`) — TWO guards, one message: the §3 residual reducer (`residualPredsOf` → `unroutedResidual`) and the end-of-body obligation checker (`reqObligationsFor` → `unroutedGroundReqs`, SA-1 — a fully GROUND goal never becomes a residual and so never reaches the first) found NO `requires` for a goal that the impl universe nevertheless says an impl matches. ⚠️ Both guards test `implMatchesWithReqsU`, not bare `implMatchesU`: the matched impl must carry a non-empty `requires`, i.e. a dictionary would actually have to be passed. Firing on bare existence over-reported — a no-`requires` impl needs no dict at all (MEASURED: `define i64 @mdk_nest__nest(i64 %arg0)`, arity 1) and the message's dictionary claim is false for it (SA-4, owner ruling RUN-055). ⚠️ The two sites share this string VERBATIM because `pushTypeErrorOnceAt` dedups on message text and a deferred goal reaches both; differing wording double-reports at one span. **A compiler limitation reported as a reject, and the message says so rather than claiming the impl is missing** — issue 1564. 🚨 **THE CAUSE SENTENCE THAT STOOD HERE IS NOW FALSE, AND IT IS CORRECTED RATHER THAN DELETED (ARCH B-2.1-b2, Stage B sprint).** It read: *"the evidence reader `concreteReqMatchByIface` still consults `shadowKeyTableRef`, copied from the CUMULATIVE `universeKeyBucketsRef`"*. **Neither ref is on this code's path any more** — `B-2.1-b2` repointed `concreteReqMatchByIface`, `selectReqImpl`/`keyForSiteByIface` and the method-keyed element-dict routes onto the graph-global `perRun.bodyImplEnvRef`, and deleted the four `…ByIface` prefix scans outright. Original cause, kept for the record: ARCH A-3.6 (issue 1112) made instance CANDIDACY graph-global while the evidence reader stayed on a topological PREFIX, so an impl declared in a module sorting later than the goal's own was a candidate whose `requires` could not be recovered — no residual, no `λd̄.` slot, no route dict. Silent before this code: `check` exit 0 and a built binary at exit **139** (an arity-2 impl called arity-1, the value cell in the dict slot). ⚠️ **DRAINED FOR THAT CAUSE**: the three pins this code was carrying — #1564, #1599, #1072 — report DRAINED on the BUILT BINARY (not merely on `check`) since `B-2.1-b2`; the code and both its guards stay live for #1578-adjacent shapes and for any future prefix reader. ⚠️ **What it did NOT drain is the METHOD-keyed ROUTE WORD** (`keyForSite`, left prefix-read by AM-1). That residual proved to be the same 139 miscompile one organ over — an arity-2 conditional impl called with one argument, at `check` exit 0 — and it is reported by `T-ROUTE-WORD-AMBIGUOUS` (next row), NOT by this code: its cause is a bare route word that names two impls, not an unrecoverable `requires`. ⚠️ Distinct from `T-NO-IMPL` ("no instance matches") and from `T-REQUIRES-DEPTH` ("instances matched all the way down and the chain did not bottom out"); here exactly one instance matches and its evidence is unreachable. ⚠️ It does **not** make DICT-SEMANTICS C4/I2 true — C4's evidence conjunct is still unmet. ⚠️ **The deferral named here has been PARTLY cashed and the code did NOT drain:** `B-2.1-b2` moved the CONCRETE evidence reader onto `IE` and `B-2.1-d` deleted `universeKeyBucketsRef` rather than re-keying it, but `findMatchingImplReqsU`'s HEADLESS leg (`firstReqMatch (univHeadless univ iface)`) is still read off `residualUnivRef`, a per-module ordinal projection — so a prefix evidence read survives one leg over, and this code drains when THAT moves. ⚠️ It also does not cover the no-impl-anywhere partially-ground shape — that shape is `T-NO-IMPL`'s (see the *no impl, PARTIALLY-GROUND goal* row in the §1 table). 🚨 **It is no longer SILENT, and the sentence that said so is corrected rather than deleted**: `unroutedResidual`'s `| otherwise = []` fallthrough is gone, so a goal this guard declines now reaches OD1 (a located `T-NO-IMPL` at the goal site) or OD2 (deferred into the binding's scheme, rejected at the use site) — issues 1578 and 1905. Located through `goalSiteLoc`, exactly as `T-REQUIRES-DEPTH` is | `T-REQUIRES-UNROUTED` |
| method route word is not unique — 🚨 **RETIRED (unreachable) SINCE ARCH B-2.1-g; NEVER EMITTED BY THE CURRENT BINARY** | ``Cannot route the call to `tagOf` at `Wrap Int`: two or more impls that define `tagOf` share this receiver's head type constructor, and they are declared in modules that this one does not import …`` (`routeWordAmbiguousMsg`) — ONE guard, `reportRouteWordSkew`, on both bare-word arms of `keyForSite` (the non-colliding `Some` arm and the `None` arm, whose callers answer it with the same bare goal-head tag). 🚨 **RETIRED AS THIS ROW'S OWN LAST SENTENCE PRESCRIBED**: ARCH B-2.1-g repointed `keyForSite` onto the graph-global `perRun.bodyImplEnvRef` (selection through `ieSelectRowByMethod`, collision retest through `ieHeadCollidesByMethod`), so the prefix count and the graph count this guard compared **are one count** and the disagreement it reports cannot arise. `keyForSite` no longer calls it. 🚨 **AND THE CODE IS NOW GONE: `ARCH B-2.1-d` DELETED `routeWordHeadSkew`/`reportRouteWordSkew`/`routeWordAmbiguousMsg`**, together with the whole prefix-table read side they were inseparable from (`headCollides` → `countHead` → `bucketOfHead` — thirteen bindings in one argued sweep, with the two write-only refs `shadowKeyTableRef`/`universeKeyBucketsRef`). The deletion was argued, not incidental: `B-2.1-g` had already made the guard unreachable, and the class it covered — a bare route word naming two impls — is now handled correctly rather than rejected, because the word is taken graph-globally. **Row kept rather than removed so a reader who meets the code in an old log can find it; it is NOT a code the current binary can emit, and the guard no longer exists.** ⚠️ It never covered issue 1578 — that shape is named in `T-REQUIRES-UNROUTED`'s row and stayed REPRO with this guard live. What replaced it is not another diagnostic but the absence of the defect: the route word now names the impl the checker selected, on every import order. The rest of this row is the historical record of WHY the word had to move, and is worth keeping accurate: **A DELIBERATE FALSE-REJECT WIDENING, and it is louder-not-quieter on purpose** (ARCH B-2.1-f, Stage B sprint). `B-2.1-b2` moved the three SELECTION legs onto the graph-global `IE` and left the method-keyed ROUTE WORD on the topological prefix table by design (AM-1: repointing it renames route words and re-mints the seed). Its own `nearest miss:` Item 4 recorded the residual as a *naming* skew; **MEASURED, it is a MISCOMPILE** — with `impl Tag (Wrap a) requires Tag a` plus the more specific `impl Tag (Wrap Int)` in a module the goal's own does not import, `check` exited **0** (human *and* `--json`), `build` exited 0, and the built binary exited **139**, because the site emitted `call @mdk_impl_Tag__Wrap_a___tagOf(i64 %t2)` — an **arity-2 define called with ONE argument**, the value cell landing in the dict slot. The guard fires exactly on the disagreement that produces it: the prefix table says the head is UNIQUE (so a bare word is stamped) while the whole graph says two or more impls defining that method share it (so the emitter resolves that word by declaration order, to a different impl). ⚠️ **ONE DIRECTION ONLY** — 0-vs-1, 1-vs-1, 2-vs-2, 2-vs-3 are all untouched, which is what keeps #1564/#1599/#1072 drained; a prefix that already collides stamps a canonical key, which names one impl on any substrate. ⚠️ Distinct from `T-REQUIRES-UNROUTED` (an impl matched and its `requires` could not be recovered) and from `W-INCOMPARABLE-IMPLS` (the impls genuinely have no min⊑ — here they do, and the checker even selects it correctly; only the emitted WORD is ambiguous). ⚠️ Deliberately **not** `requiresUnroutedMsg`'s string: the impl min⊑ actually selects here carries no `requires` and needs no dictionary, so *"Cannot pass a dictionary for …"* would misname its own cause. **It retires WITH the route-word repoint** (#1113 / ARCH B-2.1-g), which is when the two counts become one. Located through `goalSiteLoc`, exactly as `T-REQUIRES-UNROUTED` is | `T-ROUTE-WORD-AMBIGUOUS` |
| empty record update | `empty record update` | `T-EMPTY-RECORD-UPDATE` |
| unsupported (internal) | `typecheck: unsupported expression/pattern/operator …` | `T-UNSUPPORTED` |
| unknown module ordinal (internal) | `internal error: the whole-program final checks … were reached with an unknown module ordinal …` (`ordinalSentinelMsg`) — `runFinalChecks` was handed `declEnvsOrdOf`'s miss sentinel (`0 - 1`). **Unreachable from the three current drivers** (both Flat entries pass a literal `0`; the Module entry passes `declEnvsOrdOf mid` over the very list `buildDeclEnvs` indexed) and the guard exists so a FOURTH Module-mode driver cannot arrive silently: at `-1` all four members — `checkCoherence` (`cohRowsOwnedBy`), `checkInterfaceCycles`/`checkPhantomMethods` (`ceRowsVisibleAt`/`ceRowsOwnedBy`) and `checkSuperImpls` (`ceLookupAt` for the supers) — abstain and the whole tail degrades to a silent accept. `declEnvsOrdOf`'s own header prescribes exactly this remedy: abstain loudly at the READER, never a sentinel that means "everything". ⚠️ It cannot see a valid-but-WRONG ordinal, and `globalCoherenceConflict` takes no ordinal at all (SA-6, sprint repair round) | `T-INTERNAL-ORDINAL` |
| **non-exhaustive match** (warning) | `non-exhaustive match — some values may not be covered` (`:4644`) | `W-NONEXHAUSTIVE` |
| **unreachable match arm** (warning) | `unreachable match arm — this pattern is already covered by an earlier arm` | `W-UNREACHABLE-ARM` |
| **`⊑`-incomparable impls** (warning) | `Overlapping impls of C: <h1> and <h2> are not ordered by specificity — neither head is more specific than the other, so a goal matching both has no most-specific impl to pick` (F-3d) | `W-INCOMPARABLE-IMPLS` |

**Distinct-kind totals:** deliberately NOT written down — see the TL;DR bullet for the
one-line `grep` that derives them. The counts that stood here (and the divergent ones in
the TL;DR, which this note tried to reconcile) were both stale: the reconciliation was
itself evidence that a hand-maintained count in a doc is a liability, not a fact. The
table above is the inventory; the grep is the census.

---

## 2. Code taxonomy

Per-stage prefixes: **`L-`** lex, **`P-`** parse, **`R-`** resolve, **`T-`** type,
**`W-`** warning. `kind` (the JSON `kind` field) is **derived** from the prefix:
`L→lex`, `P→parse`, `R→resolve`, `T→type`, `W→warning`. Names are stable/greppable
kebab-case; never renumber (append only).

### Lex
| Code | Kind |
|---|---|
| `L-UNTERMINATED-STRING` | unterminated string literal |
| `L-UNTERMINATED-COMMENT` | unterminated block comment |
| `L-BAD-ESCAPE` | invalid escape sequence |
| `L-BAD-UNICODE-ESCAPE` | Any `\u{…}` escape the lexer must reject. Two families: **ill-formed** — the digit run is empty, is not closed by `}`, or contains a `_` (a digit separator in *integer* literals, deliberately not here — #592); and **well-formed but naming no character** — out of range (`> 10FFFF`), or a UTF-16 surrogate (`D800`–`DFFF`), which is never a scalar value. **The enumeration of causes lives in the guard clauses of `uniEscWellFormed`/`uniEscTermErr`/`uniEscErr` (`compiler/frontend/lexer.mdk`), not in this cell** — read them there. This row used to say "Covers **both**… the two messages", which #592 silently made wrong by adding four more; a list written down here has no derivation and no expiry, so it is stated as a rule instead: *every* `\u{…}` defect shares this one code (as `L-INT-OVERFLOW` does across its two stages) because they are one user-facing defect — "this escape is not a character" — and *every* message therefore opens with the `"unicode escape"` prefix that `parseErrCode` (`compiler/driver/diagnostics.mdk`) keys on, while still naming its specific cause in prose. Three checks are independently load-bearing and none is redundant: shape (an ill-formed run has no codepoint to check at all, and its terminator is not where the scanner assumed — the #592 S0), digit count (`parseRadix` accumulates in a wrapping 63-bit `Int`, so `\u{8000000000000041}` = 2^63+65 once wrapped to `65` and lexed as `A`, which no range check can see), and range (which no digit count can see — `\u{110000}` is 6 digits). Raised from all five `\u{…}` scan sites (char literal, plain/triple string, both interpolation continuations) |
| `L-BARE-UNICODE-ESCAPE` | (#515) A `\u` immediately followed by a hex digit rather than `{` — the fixed-width `\uXXXX` spelling other languages use, which Medaka does not accept (Medaka's is `\u{…}`, braced — see `L-BAD-UNICODE-ESCAPE` just above). **Distinct from that code on purpose**: `L-BAD-UNICODE-ESCAPE` is for a `\u{…}` the lexer already opened but had to reject; here no brace was ever written, so there is nothing to diagnose about the escape's content, only its spelling. Before this code existed, a bare `\uXXXX` fell through to the generic `L-BAD-ESCAPE` ("invalid escape sequence '\u'"), which never mentioned that a unicode escape exists under a different spelling — the discoverability gap an agent hit when it hand-built a 621-case test battery from raw char codes instead of `\u{...}` literals rather than discover the accepted spelling. The message embeds both spellings as its first two backtick-quoted words (`` `\uXXXX` `` then `` `\u{XXXX}` ``), reusing the malformed-radix/malformed-float `twoBacktickWords`/`oldNewFixOf` machinery (`compiler/driver/diagnostics.mdk`) for a machine `fix` — a literal brace-wrap of exactly the hex digits written, whatever the run length. Raised from both sites that dispatch on an escape letter that isn't `\u{` (`scanStrEsc`, `escChar`; `compiler/frontend/lexer.mdk`) |
| `L-BAD-CHAR-LITERAL` | A character literal that is not exactly one codepoint (#668). Three causes, one code because they are one user-facing defect — "a `Char` is exactly one codepoint": **empty** (`''`), **multi-codepoint** (`'ab'`), and **unterminated** (`'a`<EOF>, or a valid escape not immediately followed by a closing quote — `'\na'`, and equally a valid `\u{…}` escape not immediately closed, `'\u{41}z` / `'\u{41}ab'`). All three messages open with the `"character literal"` prefix that `parseErrCode` (`compiler/driver/diagnostics.mdk`) keys on; the enumeration lives in the guard clauses of `readChar`/`rawChar`/`escChar` (`compiler/frontend/lexer.mdk`), not this cell. A **bad escape** inside a char (`'\v'`) is NOT this code — it shares `L-BAD-ESCAPE` with the string path via the same `"invalid escape sequence '\x'"` message and the shared `commonEscDecode` table, because "this is not a valid escape" is the same defect in both literal kinds. A valid multi-BYTE single codepoint (`'é'`, `'😀'`) is one codepoint and is accepted — the check counts codepoints (source array elements), never bytes |
| `L-BAD-CHAR` | unexpected character |
| `L-HS-LAMBDA` | stray `\` (Haskell lambda `\x -> e`; suggest `x => e`) |
| `L-HS-DOLLAR` | stray `$` (Haskell low-precedence apply; suggest direct apply/parens/`\|>`) |
| `L-BLOCKCOMMENT` | `/* … */` C-style block comment (suggest `{- … -}` block / `--` line) |
| `L-SEMICOLON` | trailing `;` statement terminator (suggest newline/indentation separation) |
| `L-INT-OVERFLOW` | integer literal out of the 63-bit tagged-`Int` range `[-2^62, 2^62-1]`. Raised from **two** stages, deliberately under one code (#171): the **lexer** rejects magnitude `2^62+1` and above; the **parser** rejects exactly `2^62` in POSITIVE position, which the lexer must admit (it sees only unsigned digits — the `-` is a separate token) so that the writable minimum `-2^62` survives. Splitting these by catching stage would make a consumer key on two codes for one user-facing defect, so both messages share the `"integer literal too large"` prefix that `parseErrCode` (`compiler/driver/diagnostics.mdk`) keys on, and the parser-raised one keeps `kind: "lex"` for the same reason |
| `L-FLOAT-OVERFLOW` | float literal whose magnitude overflows the IEEE-754 double range (e.g. `2e308`) and would parse to `inf` — rejected at the source so it never reaches codegen as an invalid `store double inf` |
| `L-MALFORMED-FLOAT` | (#677) A `.` next to digits with no valid float on the other side. Three shapes, one code — each is "a float literal is malformed", not a separate defect: **leading** (`.5` — a `.` immediately followed by a digit is never valid Medaka; a member-access field name is an identifier, never a digit, so this can only be a float missing its integer part; caught in `singleOp`'s `.` case, skipped when the dot is glued to the end of another expression — `x.5`, `arr[0].5` — where `.5` is ambiguous enough that the pre-existing downstream diagnostic is left in place), **trailing** (`5.` — digits then `.` with nothing after it that could continue a legal-if-ill-typed postfix; caught in `numFinish`, so it only ever fires for a dot immediately following the digit run THAT CALL just scanned — never a dot after an older, already-tokenized literal, e.g. `5.0.toString` is untouched), and **exponent** (`5.e3` — digits, `.`, then something that reads as a decimal exponent; folded into the trailing shape because an `Int`/`Float` literal can never have a REAL field named `e3`, so reading it as the missing fractional digit is always correct). All three messages open with the `"malformed float literal"` prefix `parseErrCode` keys on and embed both the offending spelling and the suggested one in backticks (`` `5.e3` … `5.0e3` ``) so `parseErrHelpFix` can build a machine `fix` without re-deriving either from the diagnostic's single-point `Loc` |
| `L-MALFORMED-RADIX` | (#677) `0x`/`0b`/`0o` immediately followed by the digit separator `_` (`0x_FF`) — `_` is only legal BETWEEN digits (`0xD_EAD`), not right after the prefix. Caught in `scanNumber`, complementing `isRadixPrefix`'s existing "≥1 valid digit after the prefix" requirement. When the literal has digits after the bad `_` run, the message embeds both spellings in backticks (`` `0x_FF` … `0xFF` ``) for a machine `fix`; when it has none at all (`0x_`, `0x___`) there is no safe spelling to suggest, so the message carries only the one backtick pair and `fix` is `None` (`help` still is) |

### Parse
| Code | Kind |
|---|---|
| `P-PARSE` | general "expected …" parse failure (umbrella) |
| `P-UNEXPECTED-EOF` | unexpected end of input |
| `P-BAD-NEQ` | `!=` used for not-equal (suggest `/=`) |
| `P-HS-CASE` | Haskell `case … of` (suggest `match e` with `pattern => body` arms) |
| `P-HS-SIG` | Haskell `f :: T` type-signature syntax (`::` is cons; suggest `f : T`) |
| `P-BRACE-BLOCK` | C-style `{ … }` brace block on `if` (suggest `then`/`else` + indentation) |
| `P-FOR-WHILE` | foreign `for`/`while` loop (suggest recursion or list functions) |
| `P-DEF-KEYWORD` | foreign `def`/`function` header (suggest `f x = …`) |
| `P-GUARD-BAR-IN-MATCH` | `\|` used for a MATCH-ARM guard, which uses `if` (#591; caret on the `\|`, machine-applicable `fix`: replace `\|` with `if`) |
| `P-GUARD-IF-IN-EQUATION` | `if` used for an EQUATION (function-clause) guard, which uses `\|` (#591; caret on the `if`, machine-applicable `fix`: replace `if` with `\|`) |
| `P-RESERVED-KEYWORD` | a reserved keyword (`as`, `test`, `type`, …) used where a variable/pattern name is expected (machine-applicable `fix`: append `_`). Two producers, one code — deliberately, because it is one defect: `reservedIdentKeyword` fires wherever the grammar wanted a pattern, and (#935) the `firstCtxKwDeclIdx` pre-scan fires for the five CONTEXTUAL keywords `let`/`rec`/`if`/`then`/`else` at a top-level binding LHS (`let = 5`, `if : Int`). Those five cannot go through `reservedIdentKeyword` — a fatal there would break match-arm guards and every `let rec` (see its comment) — so the position does the disambiguation instead. Both arms build the message with `reservedKeywordMsg`, which is what `isReservedKwMsg` keys on, so the code and the `append _` fix are shared rather than duplicated |
| `P-MISSING-WHERE` | (#1160) an `interface`/`impl` header with members indented below it but no `where`. One code for both headers because it is one defect. **Anchored at the header KEYWORD, not at the token the parser tripped over** — the header ends in a name, which `canEndExpr`, so the indented member line is absorbed as an application continuation (LAYOUT-SEMANTICS §7.1) and the parser over-consumes it as another type argument before failing one line late, on a `:`/`_` that is entirely correct. `help` only, no `fix`: the repair is an insertion at the end of the header LINE, a position not derivable from this diagnostic's single-point `Loc` |
| `P-WHERE-BODY-SAME-LINE` | (#1140) an `interface`/`impl` member written on the same line as `where` (`interface Foo a where m : a -> String`). `where` heralds a block only as the LAST token of a line (LAYOUT-SEMANTICS §7.1, §9), so no block is opened and the member belongs to nothing; the parser used to return an EMPTY member list here and register a method-less interface with no diagnostic at all. Caret on the misplaced member. `help` only, no `fix`: the repair is a line break plus an indent, not a single-span edit |

### Resolve (one per `ResError` constructor)
| Code | Constructor |
|---|---|
| `R-UNBOUND` | `UnboundVariable` — also covers the sibling constructors `UnboundVariableExported` (the name is exported by an already-imported module; suggests the selective import) and `UnboundVariableIsModule` (#514: the name is itself an imported module's id, e.g. bare `import string` then a reference to `string`; a bare import binds no names, so this points at `import string.{…}`/`import string as M` instead of falling through to an unrelated edit-distance guess) |
| `R-UNKNOWN-CTOR` | `UnknownConstructor` |
| `R-UNKNOWN-TYPE` | `UnknownType` |
| `R-UNKNOWN-EFFECT` | `UnknownEffect` — special-cases the removed `Mut`/`Panic` labels with a migration hint (same code) |
| `R-UNKNOWN-FIELD` | `UnknownField` |
| `R-FIELD-NOT-IN-RECORD` | `FieldNotInRecord` |
| `R-DUPLICATE-DEF` | `DuplicateDefinition` |
| `R-UNKNOWN-INTERFACE` | `UnknownInterface` |
| `R-CANNOT-DERIVE` | a `deriving (…)` name no deriver claims (#421). Emitted by `checkDerives` (`compiler/frontend/desugar.mdk`), pushed by the driver, so it accumulates like every other diagnostic. Distinct from `R-UNKNOWN-INTERFACE` on purpose: `deriving (Num)` names a REAL interface that simply has no deriver, so the message reports what was observed ("cannot derive 'Num' for 'Dist'; supported: …") rather than concluding the name is unknown. The supported list is `map fst` of the same deriver table the lookup uses, and `data` and `newtype` have separate tables — a newtype cannot derive `Generic` here, so it is not advertised on one |
| `R-METHOD-NOT-IN-INTERFACE` | `MethodNotInInterface` |
| `R-EXTERN-WITH-BODY` | `ExternWithBody` |
| `R-PRIVATE-NAME` | `PrivateNameAccess` |
| `R-NO-EXPORTED-CTORS` | `NoExportedConstructors` |
| `R-NEWTYPE-CTOR-PRIVATE` | `NewtypeCtorNotExported` — an import member (`T(..)` or the ctor named directly) tries to bring in a `newtype`'s constructor (#1311). Deliberately a separate code from `R-NO-EXPORTED-CTORS`: that code's type is exported *abstractly* and its message ends "export with `public export`", which is a real remedy there — but a `newtype`'s constructor is unconditionally module-private (`public newtype` is a parse error; there is no spelling that exports it), so the same advice would be actively wrong. Before this code existed, resolve accepted the member silently and the failure surfaced two stages later as a bare `T-UNBOUND: Unbound variable: <ctor>` at the *use* site, with no mention of the import. A `.*` wildcard import stays silent (as it already is for an abstractly-exported `data`'s ctors) since there is no import member to locate a refusal on. |
| `R-ABSTRACT-FIELD` | `AbstractFieldAccess` |
| `R-UNKNOWN-MODULE` | `UnknownModule` |
| `R-AS-PATTERN-MISPLACED` | `AsPatternMisplaced` |
| `R-NONREC-VALUE-LET` | `NonRecursiveValueLet` |
| `R-DUPLICATE-BINDING` | `DuplicateBinding` |
| `R-DUP-BINDING` | `DuplicateValueBinding` |
| `R-DUPLICATE-SIGNATURE` | `DuplicateSignature` — a top-level name carries >=2 of its own type signatures (unambiguous: a legitimate multi-clause function has exactly one). S-2 fix (2026-07-13); for a name this check covers, it replaces `R-DUPLICATE-BINDING`'s "must be contiguous, merge them" advice — that advice is wrong when the two runs are genuinely unrelated definitions, not one function split by accident. |
| `R-DUP-BINDER` | `DuplicateBinder` (non-linear pattern / repeated parameter) |
| `R-AMBIGUOUS-OCCURRENCE` | `AmbiguousOccurrence` |
| `R-AMBIGUOUS-CTOR` | `AmbiguousConstructor` — a bare constructor USED (pattern or expression) that ≥2 explicitly-importing non-`core` modules bring into scope under the same name (#674). The constructor peer of `R-AMBIGUOUS-OCCURRENCE`. Fired at the USE site (importing both but never using the ctor stays legal). No qualified-ctor syntax exists, so the help points at a selective `import <mod>.{T(..)}` of ONE owning type, never "qualify". |
| `R-AMBIGUOUS-TYPE` | `AmbiguousType` — a TYPE name WRITTEN (in a signature/annotation, a record-pattern head, or a record-literal head) that ≥2 non-`core` imports bring into scope under one spelling (#1110 Stage A-1). The type peer of `R-AMBIGUOUS-OCCURRENCE`, with the identical trigger: a SCOPE collision, i.e. ≥2 import provenances visible in one module. It says nothing about two modules that each declare the name and are never imported together — those never meet in one scope (that is A-2's registry re-keying, not a use-site diagnostic). Fired at the USE site: importing both and never naming the type stays legal, and the using module's OWN declaration settles the name rather than participating. Neither remedy `R-AMBIGUOUS-OCCURRENCE` offers applies — an alias-qualified name in TYPE position is a parse error and only a VALUE member may be renamed — so the help names the one that works: drop the name from one import list. |
| `R-AMBIGUOUS-INTERFACE` | `AmbiguousInterface` — the interface peer, at all four interface-occurrence positions (a `=>` predicate, a superinterface, an impl `requires`, and the interface an `impl` is OF). Separate from `R-AMBIGUOUS-TYPE` because types and interfaces are separate namespaces (one file may declare both `data Foo` and `interface Foo a` and check clean), so the two ambiguity sets are computed from disjoint export lists and are never keyed together. ⚠️ Its span is best-effort: none of the four occurrence carriers holds a `Loc`, so it is located from the `Ty`s beside the head, then the enclosing expression, then (for a `=>` predicate) the constrained type's own first span. Two shapes have no span anywhere in the AST and report unlocated — a superinterface (`Super` has no `Ty` position at all) and a predicate whose types are all variables in a signature whose body is too. Both are pre-existing and shared with the `R-UNKNOWN-INTERFACE` at the same sites. |
| `R-INTERNAL-EXTERN` | `InternalExternAccess` |
| `R-IMMUTABLE-ASSIGN` | `ReassignImmutable` — bare reassignment `x = e` of an existing binding (beta immutability model; use `Ref` + `:=`). Note: `let mut` is rejected earlier, at the parser (a `P-*` parse error), not here. |
| `R-DUPLICATE-IFACE-METHOD` | `DuplicateInterfaceMethod` — two `interface`s among **one module's own declarations** declare the same **method** name (Stage B / Phase 4b "Q1"). Rejected **on the declaration**, not at an ambiguous occurrence, so the ambiguity is unrepresentable rather than merely unreported. ⚠️ **This NARROWS acceptance:** two interfaces sharing a method name whose impls sit at *disjoint* receivers compiled and ran correctly before, and is rejected now — the help text says so rather than implying the program was always illegal. **Scope, by construction of the site** (`duplicateErrors` ← `buildErrors`, which has no import table): the prelude is **not** consulted, so a collision with a prelude standalone stays the `W-PRELUDE-METHOD-SHADOW` case ruled by `docs/spec/SHADOW-SEMANTICS.md` S1-PRELUDE / [#1499](https://github.com/MedakaLang/medaka/issues/1499), and a collision with a prelude *interface method* is left exactly as it behaves today — pinned as [#1672](https://github.com/MedakaLang/medaka/issues/1672) (`test/must_fail_fixtures/1672-prelude-iface-debug-collision/`), a member of [#1182](https://github.com/MedakaLang/medaka/issues/1182)'s family (bare-name-keyed candidate merge ranked by receiver type — same mechanism, prelude as one participant): on the pinned cell `check`/`run`/the built binary all silently agree on the *prelude's* impl, but selection is receiver-TYPE-directed, not a rule that always resolves to the prelude — see #1672's body for the measured reachability set (wildcard/qualified/re-export/no-import cells, other colliding prelude methods, and a signature-variant cell where `run` and the built binary disagree instead); imports never enter, so two interfaces in **different** modules — the residual [#1182](https://github.com/MedakaLang/medaka/issues/1182)/[#1620](https://github.com/MedakaLang/medaka/issues/1620) class — are **not** covered and stay live. **Span-less by construction, not by omission:** `DInterface` carries no `Loc` (`declLoc` sends it to `None`). `IfaceMethod` itself gained a fourth field (`Option Loc`) in the `prelude-shadow-agreement` sprint (see the `W-PRELUDE-METHOD-SHADOW` row below) so a method name's own span now DOES survive to resolve where that field is populated — this diagnostic simply does not consume it: `duplicateErrors` reports at the interface DECLARATION (via `DInterface`'s absent `Loc`), not at the individual method, so `IfaceMethod`'s span is available but unused here, not itself absent. A repeated method name *within one* interface is deliberately **not** reported here (a different, still-unchecked shape). |
| `R-MODULE-LOAD` | Not a `ResError` constructor — a driver/loader-level failure (missing/cyclic import, unreadable module) surfaced by `medaka check`/`run`/`build`'s multi-module load step, bucketed under `R-*` like the rest of this table since it has no lex/parse/type home. Span-less (`loc = None`) unless the failing import's own `import` line could be recovered. |
| `R-FILE-NOT-FOUND` | Not a `ResError` constructor — the CLI target path itself could not be read (`check --json`/`build --json`'s `readFile` on the entry fails before any loading starts). Span-less. Exists so a caller keying off `code` can tell "the file doesn't exist" apart from `R-MODULE-LOAD` ("an *import* doesn't resolve") — see `cjFileNotFoundJson`, `compiler/driver/medaka_cli.mdk`. |
| `R-BUILD-FAILED` | Not a `ResError` constructor — `medaka build --json`'s (#1078) envelope for a failure at the EMIT/CLANG stage, i.e. AFTER the front-end gate (the same `checkJsonFile` pass `check --json` runs) has already reported clean. Carries the emitter/linker's own message verbatim as `message`; span-less. Distinguishes "the emitted program is fine, the backend choked" from every front-end `R-*`/`T-*`/`P-*`/`L-*` code the same envelope can also carry on that command. See `cjBuildFailedJson`, `compiler/driver/medaka_cli.mdk`. |

### Type — see the §1 typecheck table (`T-TYPE-MISMATCH`, `T-NO-IMPL`,
`T-MISSING-CONSTRAINT`, `T-AMBIGUOUS-INSTANCE`, `T-AMBIGUOUS-SHADOW-DECL`,
`T-INFINITE-TYPE`,
`T-UNKNOWN-FIELD`, `T-MISSING-FIELD`, …).

### Warnings
| Code | Source |
|---|---|
| `W-NONEXHAUSTIVE` | non-exhaustive `match` (typecheck `matchWarnings`) |
| `W-UNREACHABLE-ARM` | unreachable/redundant `match` arm — pattern already covered by an earlier unguarded arm (typecheck `matchWarnings`; `checkMatchRedundant`) |
| `W-GUARD-INEXHAUSTIVE` | guards may not be exhaustive (exhaust) |
| `W-NONEXHAUSTIVE-CLAUSES` | non-exhaustive clauses of a multi-clause function — a constructor is not covered by any clause (exhaust; the function-clause analog of `W-NONEXHAUSTIVE`) |
| `W-INCOMPARABLE-IMPLS` | two overlapping `impl`s of one interface whose heads are `⊑`-**incomparable** — neither is more specific than the other (typecheck `matchWarnings`; `checkCoherence` → `cohClassify`). DICT-SEMANTICS §6.1 choice-point 2 condition **(a)**, which that clause licenses as *"at most a warning at declaration time … but acceptance is per-goal"*; the acceptance decision belongs to the goal-site `min⊑` reject (`T-AMBIGUOUS-INSTANCE`). ⚠️ **Not the whole of the old `T-CONFLICTING-IMPL`.** Two *mutually*-`⊑` (α-equal) heads still take that ERROR code: they satisfy (a) but violate §6 C1 outright (two `⊑`-minimal elements), and `entryCovers` makes equal heads cover each other, so the goal-site reject never sees them |
| `W-OPEN-GOAL-COMMITTED` | At a goal that is still **non-closed at quiescence** — after `#2548`'s whole-graph stamper drain, so nothing further will ground it — the candidate set has no `⊑`-minimum and the checker commits to the **first-declared** match, making declaration order decide which impl runs (exit 0, silently, before this code existed). DICT-SEMANTICS §6.2 **T4**: a non-closed goal is DEFERRED rather than decided, so `T-AMBIGUOUS-INSTANCE`'s reject deliberately does not reach it; this warning is the same arm on the other side of the closedness gate (`reportAmbiguousOverlap`, typecheck `matchWarnings`). ⚠️ **It is a MEASUREMENT, not a verdict.** Ruling 1 of the `graph-quiescence-solve` sprint makes T4's reject audible first so the set it fires on can be counted; whether it becomes an error (SC-3, reject on non-unique minimum) is an owner decision taken on that census, and promoting it without one over-rejects programs the spec accepts — the open half of `test/dict_fixtures/s6-2-t{3,4}-*.mdk` is exactly such a program. ⚠️ Deliberately **not** in `runBuildWarnCodes` (`compiler/driver/medaka_cli.mdk`), whose doc comment records the three measurements every addition owes; it reaches `check`, `check --json`, and the single-file `run`/`build` arms that filter the whole channel |
| `W-MAIN-SHAPE` | `main` is not a zero-arg `Unit`-typed value (a beginner footgun: `medaka run` checks `main` EXISTS but never APPLIES it, so an ill-shaped `main` silently no-ops) — two shapes, one code: a FUNCTION `main` (`main () = …` / `main x = …`, arity check, no type info needed) or a zero-arg VALUE `main` whose inferred type is neither `Unit` nor `Async _` (`main = 1 + 2`) (`driver.diagnostics` `mainArityWarning`/`mainNonUnitWarning`/`mainShapeWarnings`, called from `check`/`run`/`build`, both human and `--json`). [#1236](https://github.com/MedakaLang/medaka/issues/1236): previously bespoke — `<unknown location>` (no `Loc`, `mainBodyLoc` only walked the `EApp` spine so a binop/unary/postfix-headed body like `1 + 2` fell through), absent from `check --json` (computed nowhere near `checkJsonFile`), and raw non-JSON text on `run --json` (bypassed `pendingRunDiags`). Now an ordinary located `Diag`, routed through the same envelope/rendering every other diagnostic uses on every verb × form cell |
| `W-KEEP-IR-FAILED` | Not a typecheck warning — `medaka build`'s best-effort `--keep-ir` copy could not be written (the build itself succeeded; the copy is diagnostic evidence, never a build input, so failing it must not fail the build). Span-less: it reports on an output path, not on source. Authored at `keepIrOutcome` (`compiler/driver/build_cmd.mdk`) as a `Diag` on the build report rather than as text appended to the status line, which is what lets `build --json` carry it at all — before [#2243](https://github.com/MedakaLang/medaka/issues/2243) that channel printed the front-end gate's envelope verbatim and dropped every build-stage note. The plain CLI renders it as `warning: <msg>` via `ppBuildReport`, deliberately NOT through `ppDiagCliLines`, whose unlocated arm would prepend `<unknown location>` (#2400 F3) to wording that has never carried it. |
| `W-PRELUDE-METHOD-SHADOW` | An interface method declared in module `M` whose name collides with an **implicit-prelude standalone**, which the declaration therefore makes unreachable by its bare name anywhere in `M`. Required by `docs/spec/SHADOW-SEMANTICS.md` **S1-PRELUDE (b)** (ruled 2026-08-10, [#1375](https://github.com/MedakaLang/medaka/issues/1375) item 2) and implemented by [#1499](https://github.com/MedakaLang/medaka/issues/1499): under (a) the interface method wins the name and the program is well-defined and **accepted**, so the collision is **observable** but is **not** an error — an error would narrow acceptance on working programs. Emitted from `preludeStandaloneShadows` (`compiler/frontend/marker.mdk`, the inverse direction of Phase 78b's `shadowRename`, sited beside it so both directions are auditable as a set) and wired at the **two** sites `checkGuardExhaustivenessWith` occupies in `compiler/driver/diagnostics.mdk` — `analyzeFrom` (flat) and `foldModuleTc` (per module) — via `preludeShadowWarnToDiag`. No table and therefore no key: a pure function of two decl lists, evaluated per (module, prelude) pair and consumed immediately. Located on the method NAME's own span, carried by `IfaceMethod`'s fourth field (`Option Loc`, added by this work; see the `R-DUPLICATE-IFACE-METHOD` row above, whose span-less-by-construction note predates it). Visible on all four verbs: `check` (human), `check --json`/MCP/LSP, `run` and `build` — the last two because the code joins `runBuildWarnCodes`, the `isCoherenceWarn` allowlist (`compiler/driver/medaka_cli.mdk`), whose doc comment records the three measurements every addition owes. **No machine-applicable `fix`:** a `Fix` is a single-span replacement and the repair (renaming the method) is multi-site — an agent applying a one-span fix verbatim would rewrite the declaration and leave every call site broken. The help names the shim recovery only; ⚠️ **do not name `import core as C` / `import core.{n as pn}` / `export import core.{n}` + module alias** — all three are measured broken and the last one **SIGSEGVs**; that negative list lives in `SHADOW-SEMANTICS.md` |

#### Adding a typecheck-stage warning

A warning is a full diagnostic, so it gets a code the same way an error does:
**authored at the push site, never inferred downstream.** Concretely:

1. Push a `TcDiag <code> 2 <loc> <msg> <help> None` onto **`matchWarnings`**
   (`compiler/types/typecheck.mdk`). Despite the name that channel is the general
   typecheck-warning channel, not a match-specific one. `<msg>` keeps the leading
   `"Warning: "` — the text renderers print it verbatim and only
   `diagOfTypeWarning` strips it.
2. Add the code to the table above.

**The `W-` prefix is load-bearing, not a naming convention.** The JSON `kind` is
derived from the code's prefix (`codeKind`), so the code you author decides how
every consumer classifies the diagnostic. A demoted error that keeps its `T-*` code
reads as a type *error* to anything filtering the per-stage taxonomy. `diagKind`
(`compiler/driver/diagnostics.mdk`) stops that from rendering incoherently — a
`SevWarning` diagnostic can never emit a per-stage kind — but it deliberately does
**not** rewrite your code: inventing `W-FOO` from `T-FOO` would be the same
derive-identity-from-spelling mistake in the other direction. Author a new `W-*`
code; do not reuse the error's.

⚠️ `diagKind`'s rule is *"a warning may not render a per-STAGE kind"*, **not**
*"severity 2 implies kind `warning`"*. `lint` is a genuine severity-2 kind —
`medaka lint --json` ships `{"code":"rule-…","kind":"lint","severity":2}` through
the same envelope — so the narrower rule is what keeps lint's kind intact.

Two rules, both paid for:

- **Do not leave the code `""` and let the conversion guess.** Until 2026-07-31
  `diagOfTypeWarning` (then `diagOfMatchWarning`) discarded the `TcDiag`'s code and
  recomputed one by prefix-matching the *rendered message*, with `otherwise =
  "W-NONEXHAUSTIVE"`. That is identity keyed on spelling — design law **L2**
  (`TYPECHECK-TARGET-ARCHITECTURE.md` §1) — and it happened to work only because the
  channel carried exactly two warnings with distinguishable prefixes; a third would
  have been silently relabelled a non-exhaustive-match warning. §5 below already
  prescribed authoring the code at the push; the conversion now simply carries it.
  (§5 is right about *where* the code is authored and wrong about *what* it is — it
  prescribes `W-NONEXHAUSTIVE` for **both** sites, which is incorrect for the
  unreachable-arm one. That site takes `W-UNREACHABLE-ARM`, per the table above.)
- **Do not demote an error to a warning by pushing severity 2 through
  `recordTypeError`.** The `typeErrors` channel is not a pure report: it arms
  `typeErrorsSticky` (which `hadTypeErrors` uses to abort `build`/`run`) and bumps
  `errorsDetected` (which `erredDuring` polls to gate inference — issue 1146).
  `recordTypeError` does both **unconditionally, without reading severity at all**,
  so such a "warning" keeps both of an error's side effects. The *side effects* are
  the reason; be careful with the rendering claim, because the sloppy version invites
  the wrong fix. It does **not** print as severity 2 today: `diagOfTypeError` binds
  the severity field to `_` and hardcodes `SevError`, so it prints severity 1 — it
  does not even look like the warning its author intended. Removing that hardcode
  would not rescue the idea either; it would print severity 2 and *still* abort the
  build and steer inference. `matchWarnings` has neither side effect; demote by
  moving the push to that channel.

⚠️ `matchWarnings` is control-coupling-free, which is **not** the same as
consumer-free. `hadMatchWarnings` (`compiler/types/typecheck.mdk`) answers "did the
last pass push any warning at all", and `compiler/tools/snapshot.mdk` reads it to
decide whether a rendered `# TYPES` section is `--bless`-able. A new warning that
fires on existing corpus code can therefore make snapshots that bless today stop
blessing — budget for that when you add one.

### Eval / runtime — `E-*` (`compiler/eval/eval.mdk`, `medaka run`)

Runtime errors surfaced by the tree-walking interpreter. Unlike the compile-time
stages these are reachable on a **well-typed** program (value-dependent). They are
formatted at the `runtimePanic` chokepoint (`eval.mdk`) into the located text
`file:L:C: runtime error [E-*]: <message>` and handed to the `noreturn` `panic`
extern (`kind` = `"error"`, `severity` = 1). See
`RUNTIME-DIAGNOSTIC-CHANNEL-DESIGN.md`. Internal-invariant panics (compiler-bug
asserts) stay **bare** and carry no code.

| Code | Meaning |
|---|---|
| `E-DIV-ZERO` | integer division by zero |
| `E-MOD-ZERO` | integer modulo by zero |
| `E-INDEX-OOB` | list/array/string index out of bounds |
| `E-SLICE-OOB` | slice bounds out of range |
| `E-PANIC` | explicit user `panic` |
| `E-NONEXHAUSTIVE-MATCH` | `match` had no arm for the runtime value |
| `E-LET-REFUTE` | refutable `let` pattern failed |
| `E-NOT-A-FUNCTION` | applied a non-function value (borderline) |
| `E-MISSING-FIELD` | reserved — record-field miss (borderline; no live emit site on current tree, see design §5) |

---

## 3. Diag ADT + threading mechanism

### ADT change

Today (`diagnostics.mdk:61`):
```
data Diag = Diag Severity String (Option Loc)
```
Proposed:
```
data Diag = Diag Severity Code String (Option Loc)      -- Code = alias for String
```
`Code` is a kebab string (no separate `Kind` field stored). `kind` in the JSON is
**derived** at render time from the code's prefix (`codeKind : Code -> String`),
so authors supply exactly one token. This keeps the ADT one field wider and every
construction site's change mechanical.

**20 `Diag Sev…` construction sites** exist across the compiler
(`diagnostics.mdk`, `medaka_cli.mdk`, `playground_main.mdk`,
`entries/playground_main.mdk`). Each already knows which stage produced the diag
(they map `ResError`/`(msg,loc)`/`ParseError` into `Diag`), so each supplies the
code from the per-stage helper below — not 20 ad-hoc literals.

### Where the code actually attaches (per stage)

- **Resolve — ZERO call-site changes.** `ResError` is already an ADT. Add one
  pure function `resErrorCode : ResError -> Code` (19 arms, beside `ppResError`),
  and at the two `Diag SevError (ppResError e) …` sites
  (`diagnostics.mdk:168`, `:408`) pass `(resErrorCode e)`. Two edited lines,
  one new function.

- **Typecheck — ~55 authored sites.** The three push functions are the only
  entry points. Change their signatures to take the code **first**:
  ```
  pushTypeError       : Code -> String -> <Mut> Unit
  pushTypeErrorOnce   : Code -> String -> <Mut> Unit
  pushTypeErrorOnceAt : Code -> Option Loc -> String -> <Mut> Unit
  ```
  The `typeErrors` ref becomes `Ref (List (Code, String, Option Loc))` and
  `checkProgramDiags`/`checkModulesDiags` propagate the code out. **All ~55
  `pushTypeError*` call sites gain a code argument** — this is the bulk of the
  authoring work, but it is mechanical (each site's kind is obvious from its
  message; see §1 table). The two `setRef matchWarnings` sites similarly gain
  `W-NONEXHAUSTIVE`/`W-UNREACHABLE-ARM` (SHIPPED 2026-07-31 — they were the last two
  push sites still passing `""`; see "Adding a typecheck-stage warning" above).
  *No chokepoint can infer these* — the message strings are
  built inline/by helpers, so the code must be authored at the push. (Signature
  variant considered and rejected: a single `pushTypeError code msg` wrapper that
  defaults the code — the language has no default args, so it saves nothing.)

- **Parse — ADT boundary.** Add a `Code` to `ParseError` (or derive at the single
  `ParseError → Diag` conversion by matching `"unexpected end of input"` /
  `!=`-message → `P-UNEXPECTED-EOF` / `P-BAD-NEQ`, else `P-PARSE`). Deriving at
  the boundary is 0 parser edits; adding the field is ~3 edits. Recommend
  **derive at the boundary** (parser messages stay untouched).

- **Lex — recover at the parse boundary.** `TLexError` surfaces as a
  `ParseError`; match the lexer messages there to emit `L-*` (else `P-PARSE`).
  Alternatively thread a code on `RawTok (TLexError …)`. Recommend the
  message-match at the boundary (contained). This is now **implemented** as
  `parseErrCode` (`compiler/driver/diagnostics.mdk`), so its `L-*` arms — not this
  bullet — are the pattern set; the TL;DR's grep enumerates them. The bullet said
  "the 4 lexer messages … (4 patterns)" long after there were more.

- **Guard warning (exhaust).** `checkGuardExhaustiveness : … -> List String`.
  Map its output to `W-GUARD-INEXHAUSTIVE` at the two conversion sites in
  `diagnostics.mdk` (`:176`, `:441`).

**Authored-code call sites that must change: ~55 (typecheck) + 2 (match-warning
setRefs) ≈ 57.** Everything else (resolve 19 kinds, parse, lex, guard) attaches
via one helper function / boundary match with **0–3** edits each. `kind` is never
authored (derived from prefix).

---

## 4. Warning-range fix (ERROR-QUALITY Open decision §5)

**Confirmed (M2):** the loc IS snapshotted. `matchWarningLocs`
(`typecheck.mdk:2125`) is pushed in lockstep with `matchWarnings`, and
`checkProgramDiags` (`:9832`) returns `zipL matchWarnings matchWarningLocs` —
each warning already carries `(msg, Option Loc)` on the single-file path.

**Where the `{0,0}` is actually produced:** not in the accumulator but in the
**renderer** — `cjDiagnostic`'s warning arm (`diagnostics.mdk:528-537`):
```
cjDiagnostic path src (Diag SevWarning msg (Some (Loc _ sl sc _ _))) = jObject
  [ ("message", JString "\{path}:\{sl}:\{sc}: Warning: \{msg}")   -- loc baked into text
  , ("range",   cjRange 0 0 0 0)                                  -- dummy {0,0}
  , … ]
```
This is a deliberate oracle-compat artifact. The fix:
1. **Renderer:** collapse the special warning arm into the general arm so a
   `SevWarning` with a `Some loc` emits `("range", cjRangeOfLoc src loc)` and a
   bare `message` (no `path:L:C: Warning:` prefix).
2. **Multi-module path:** `checkModulesDiags` currently returns `List String` for
   warns (drops the loc) and `foldModuleTc` (`:439`) wraps them with `None`.
   Widen the warn payload to `(String, Option Loc)` so multi-module warnings keep
   their span too.
3. **Guard warnings** (`checkGuardExhaustiveness : … -> List String`) have no loc
   today (`None` at `:176`/`:441`). To give them a real span, thread the guard
   node's `Loc` out of exhaust — a larger change; acceptable to leave guard
   warnings positionless in Stage 1 (they still get `W-GUARD-INEXHAUSTIVE` + the
   whole-doc fallback), and fix the span in a follow-up.

This changes `check_json` warning output (a golden recapture — see §5) and is the
one place a warning JSON currently diverges from an error JSON.

---

## 5. GOLDEN-CHURN CENSUS (measured on prototype, then reverted)

Method: injected `[PROTOCODE]` into the `ppDiagCliSrc` header **and** added
`("code",…)/("kind",…)` to `cjDiagnostic`, rebuilt `make medaka`, ran the gates in
CHECK mode, counted differing goldens, then `git reset --hard`.

| Option | Renderer touched | Goldens changed | Which corpora |
|---|---|---|---|
| **JSON-only** | `cjDiagnostic` | **9** | `check_json` (9/9; 8 diagnostic-bearing + clean). LSP JSON goldens add a few more. `error_quality`, `native_cli`, `diagnostics` **unchanged**. |
| **CLI-shows-code** | `ppDiagCliSrc` header | **~100** | `error_quality` **35** (measured) + `native_cli/check` **~57** + the 9 JSON. `diff_compiler_diagnostics` stays clean **iff** the code is kept out of `ppDiag` (the loc-free diff form). |

Notes from the measurement:
- **Only type errors with a loc flow through `ppDiagCliSrc`.** Resolve errors
  render via `ppResErrorLocated`/`ppDiag` and did **not** pick up the header
  prefix — so a full CLI-code rollout also touches those renderers, i.e. the ~100
  is a floor if we want codes on *every* CLI line.
- `native_cli` is documented stale-prone (`AGENTS.md`); its 72/106-fail run under
  the prototype conflated real churn with staleness. Treat "~57 check goldens" as
  the recapture estimate, not a correctness signal.

**Recommendation:** **Stage 1 = JSON-only.** It reaches ERROR-QUALITY §5's bar
("add `code` and `kind` to every diagnostic" for the agent audience) at ~9-golden
cost, with zero perturbation to the human-facing CLI corpora. CLI `[CODE]` in the
header (per the §4 exemplars in ERROR-QUALITY) is a **separate opt-in** costing a
one-time ~100-golden recapture; sequence it after Stage 1 if the human-CLI code is
wanted. Keeping the code out of `ppDiag` is a deliberate lever that spares
`diff_compiler_diagnostics` in both options.

---

## 6. Stage 2 — `help` / `fix` scope

Already-computed suggestions that just need structured surfacing:

| Category | Already computed? | Stage-2 surfacing |
|---|---|---|
| **did-you-mean** (misspelled name) | **Yes** — `UnboundVariable String (Option Loc) (Option String)` carries the suggestion (3rd field) and `ppResError` already appends it | `help` = "did you mean `x`?"; **machine `fix`** = the identifier's own range + replacement (the range is the unbound-var loc). *First `fix` to ship.* |
| `!=` → `/=` | **Yes** — hardcoded parser hint | `help` + `fix` = replace `!=` span with `/=`. |
| **missing constraint** | Partially — message already says "add `Eq a =>`" | `help` prose; a machine `fix` needs the signature's insertion point (deferred). |
| **missing case** (non-exhaustive) | **Yes** — exhaustiveness computes the witness ctor(s) internally | `help` = "missing case: `None`"; machine `fix` deferred (insertion point non-trivial). |

Proposed `fix` shape (mirrors the LSP edit + `medaka lint --fix`):
```
data Fix = Fix Loc String            -- replace `Loc`'s span with the String
-- JSON: "fix": { "range": {…}, "replacement": "…" }
```
Add optional `help : Option String` and `fix : Option Fix` to `Diag` (or a
side-table keyed by push). **v1 machine `fix`: did-you-mean + `!=`→`/=` only**
(both are exact, single-span, agent-applicable). Everything else ships `help`
prose in Stage 2 and earns a `fix` later. This also gates whether `medaka check
--fix` becomes a thing (parallel to `medaka lint --fix`) — recommend deferring
that CLI surface until ≥2 `fix` categories exist.

---

## 7. Staged plan

### Stage 1 (codes + kind + warning-range; **size M**)
1. `Diag` gains `Code` (`data Diag = Diag Severity Code String (Option Loc)`);
   add `codeKind : Code -> String` (prefix → `lex/parse/resolve/type/warning`).
2. Resolve: add `resErrorCode : ResError -> Code` (19 arms); pass at the 2
   `ResError→Diag` sites. (0 resolver call-site changes.)
3. Typecheck: add `Code` param to the 3 push funcs + widen `typeErrors` ref;
   author the code at **~55** push sites + 2 match-warning sites
   (`W-NONEXHAUSTIVE`).
4. Parse/lex: derive `P-*`/`L-*` at the `ParseError→Diag` boundary (message
   match); guard warning → `W-GUARD-INEXHAUSTIVE` at its 2 conversion sites.
5. Warning-range fix (§4): renderer arm + multi-module warn-loc threading.
6. Render: add `code`+`kind` to `cjDiagnostic` (**JSON-only**; leave `ppDiag`
   and `ppDiagCliSrc` unchanged for minimal churn).
7. Recapture goldens: `check_json` (+ LSP JSON). Run `selfcompile_fixpoint`
   (C3a/C3b) + `run_gates.sh`.

### Stage 2 (help/fix)
8. `help : Option String` + `fix : Option Fix` on `Diag`; render into JSON.
9. Surface did-you-mean `fix` (from `UnboundVariable`'s 3rd field) + `!=`→`/=`.
10. `help` prose for missing-constraint / missing-case (witness already computed).
11. (Optional) `medaka check --fix`.

### Risk flags
- **No re-mint:** diagnostics/typecheck are self-compiled but **not the emitter**,
  so the checked-in seed is untouched — but the change perturbs compiler IR, so
  **`selfcompile_fixpoint` (C3a/C3b) must be re-validated** and any recaptured
  goldens re-committed. (Per AGENTS.md: fixpoint is the decisive semantics-
  preserving gate here.)
- **~55 authored codes** is the labor centre of Stage 1 — each is mechanical but
  must be reviewed against the §1 table so codes stay accurate (a wrong code is
  worse than none for the agent audience).
- **Multi-module warn-loc threading** widens `checkModulesDiags`'s return type —
  audit every caller (`typecheckPass`, LSP `analyzeProject`) for the shape change.
- **Code stability contract:** once shipped, codes are append-only. Document that
  in this file's header when Stage 1 lands.
