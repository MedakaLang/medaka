# Effects issues against the architecture

Review dated 2026-09-29. Source inspected: `afab823b1fcdf10ad7f066dac6ccd992de51db94`
(PR #3584, file confinement). Issue inventory: all 865 open GitHub issues at
retrieval, filtered by titles and bodies, with discussions read for the effects
issues below. This is a dated assessment, not a replacement backlog. The companion
documentation changes reconcile delivered behavior and existing rulings; remaining
recommendations below are proposals, not implementation claims.

**Assessment: retain the core architecture, but complete and sharpen its boundaries.**
Separate type/row/authority variables, scoped constraints, forcing versus latent
effects, invariant indices, qualified schemes and the shared invocation summary
are the right foundations. The backlog does not establish a need for a different
effect calculus, handlers, dependent types, or effect-directed instance selection.
It does establish that the implementation is not yet sound end to end: #3523 still
allows an effectful function to acquire a pure type. Several safe refusals also
expose incomplete constraint ownership and checking judgments. Runtime resource
confinement needs a first-class architectural contract beyond the static algebra.

The distinction matters: a missing checker rule can violate a sound design;
an intentionally conservative rule can require a design extension to accept more
programs; neither conclusion is established by the issue's age or severity label.

**Evidence and limits.** `make medaka` restored matching build-cache artifacts;
all probes used `MEDAKA_STRICT=1`. The table distinguishes **probe** (executed on
this source), **source** (implementation inspected), **tracker** (reported evidence,
not independently re-executed), and **historical** (later comments or implementation
supersede the original claim). The probes are targeted checks, not a soundness
proof or a full regression run. Only #3523 was also executed through `medaka run`;
this review did not re-run its native/Wasm witnesses or the filesystem race.
The reconciliation at the end records the issues subsequently closed and updated.

**The architectural map.** The normative anchors are
[Effects semantics](../spec/EFFECTS-SEMANTICS.md),
[Effects within the typechecker](../../compiler/EFFECTS-ARCHITECTURE.md), and
[Typechecker destination contracts](../../compiler/TYPECHECK-CONTRACTS.md).

| Layer | Existing responsibility | What the backlog says |
|---|---|---|
| Declaration elaboration | Resolved label identities, declared kinds, domain-correct qualifiers and indices | Apply well-formedness checks to every type-writing site; several consumers remain incomplete. |
| Expression checking | Infer value type and immediate row; check directed flow; use domain-directed abstraction α | Qualified results and contextual callback inference do not consistently use the information available at their checking sites. |
| Constraint solving/publication | Distinguish universals from inference choices; solve at owning scopes; retain qualified residuals | Shared recursive residuals and joint equality/inclusion solving need explicit extensions; input position must not imply rigidity. |
| Dictionary integration | Select by interface/type identity; establish full typing obligations before publishing evidence | Dispatch-shape equality currently escapes into proof of instance applicability. This is a live soundness breach. |
| Manifest/policy | One verified forcing-plus-invocation summary with conservative unknowns | The summary is shared; loading, diagnostics and serialization are not yet uniformly shared. |
| Runtime enforcement | Turn static authority into a grant checked by resource operations | File grants now exist, but their ABI, trust boundary and target guarantees have outgrown the architecture document. |

**Static checking and inference issues.** “Fits” means the existing semantic
contract already gives the answer, not that the implementation change is small.

| Issue | Architectural fit and required work | Spec/design action | Evidence |
|---|---|---|---|
| [#3523](https://github.com/MedakaLang/medaka/issues/3523), repeated impl variable launders rows/indices | **Fits, but exposes an essential integration boundary.** `cohEqR` ignores arrow rows, treats all `TEff`/`TAuth` pairs as equal and strips qualifiers. That is unsuitable for proving that two bindings of one head variable are the same type. Keep effect-blind candidate ranking; require full row/index/qualifier consistency for the selected instance and retain blocked obligations. An effect failure must not select a different instance. | Make the distinction explicit in EFFECTS §6.9 and DICT's applicability/evidence rules. Candidate-shape match is not a typing proof. Correct TYPECHECK workstream guidance that broadly says subsumption/matching ignore effects. | **Probe + source:** `check` accepts `impl Same a a` converting `Int -> <IO> Int` to `Int -> Int`; `run` prints `side effect`, then `4`. |
| [#3473](https://github.com/MedakaLang/medaka/issues/3473), eta-expanded callback into a pure slot | **Ownership-rule completion.** A row of an unsigned parameter is flexible while its binding is inferred. Being an input or borrowed by a child does not make it a declaration universal. Transfer the upper bound to its owner and solve there; do not close unrelated external or rigid rows. | Refine the architecture's “borrowed input roles take precedence” rule and EFFECTS §6.8: distinguish “not owned here” from “unsolvable everywhere.” State the pure upper-bound example explicitly. | **Probe:** `viaL f = run (Handler (x => f x))` still rejects; the issue records the direct-value control. |
| [#3537](https://github.com/MedakaLang/medaka/issues/3537), joined index solved too early | **Solver completeness gap.** The index equality and the argument's lower bound must constrain one fresh instance together. Prematurely choosing the exact argument string loses a valid wider solution. Preserve equality as an obligation until all relevant constraints are available. | Specify the supported joint equality/inclusion fragment in §4.1, including when a principal solution exists, when a residual is retained, and when ambiguity is refused. “Check the index argument first” alone is not an order-independent contract; do not promise arbitrary join inversion. | **Probe:** the issue's `Socket (p \| "a.com/*")` example still rejects with the exact-string mismatch. |
| [#3482](https://github.com/MedakaLang/medaka/issues/3482), mutual recursion shares a residual | **Real, bounded extension.** `ScopeRoles.rlQuantified` and `componentMember` represent one owning member. Extend ownership to the ratified mention-closed member set, attaching the whole residual through each member's substitution. Each member must quantify every local variable it needs; distinct variables connected only by a relation cannot be exported piecemeal. | Update §4.1's current one-member-only rule and the residual checkpoint. The issue contains the 2026-09-26 ruling. Keep value restriction, external captures, row-only authority widening and scope escape intact. | **Probe + source:** committed mutual-recursion fixture rejects; its self-recursive control succeeds with `(a <= d) => ...`. |
| [#3566](https://github.com/MedakaLang/medaka/issues/3566), no written residual contexts | **Surface extension over existing schemes.** Parse/elaborate authority predicates alongside class predicates. At definition, these are scoped givens over rigid binders; at use, instantiate them as wanteds with the same substitution. They require no runtime dictionary. | Add the grammar and entailment rules to §4.1/§6: scope, domains, joins, mixed contexts, malformed predicates and generalization. The printed form is a proposal, not already accepted syntax. | **Tracker + source:** `Scheme` already stores authority residuals; spec explicitly excludes written syntax. |
| [#3532](https://github.com/MedakaLang/medaka/issues/3532), literal cannot satisfy qualified result | **Fits; incomplete expression-directed checking.** Share the qualified-slot judgment between call arguments and returned expressions, with their lexical environment and expected domain. Do not recover authority from an arbitrary unqualified type. | Extend §4.1's argument-focused presentation to a general judgment `check(expression, expected qualified type)`. A literal inside a constant bound is valid; a literal under an unrelated universally quantified authority remains invalid. | **Probe + source:** `pick : Bool -> String @"x/*"` returning `"x/a"` or `"x/b"` still rejects. |
| [#3543](https://github.com/MedakaLang/medaka/issues/3543), qualifier into Product primary axis | **Small semantic extension, not a new domain.** Add an explicit schema-directed lift at consumption. Exact strings can become singleton Set elements; Prefix patterns cannot become singleton Set elements and must widen appropriately. Use the declared primary axis, never sorted constant fields. | Specify cross-domain lifting separately from same-domain comparison. Binder-free Product qualifiers also need a rule supplying the schema, or explicit label syntax; do not infer arbitrary schemas from printed field names. | **Tracker + source:** `qualifierIn` currently requires domain identity; bare literal abstraction already has a Product lift. |
| [#3548](https://github.com/MedakaLang/medaka/issues/3548), unchecked alias qualifiers/ascriptions | **Fits.** One declaration/type well-formedness service should cover aliases, signatures, data fields and expression annotations. A later use-site rejection does not validate the declaration. | Clarify that domain and parameter-shape well-formedness holds at every type-writing site; no new authority algebra. | **Probe:** both incompatible-domain aliases in the issue are accepted when unused. Tracker says uses refuse safely. |
| [#2122](https://github.com/MedakaLang/medaka/issues/2122), position-blind atom guarantee table | **Proof-summary contract gap.** A syntactic occurrence is not evidence that an effect is available in the relevant position. Define the guarantee this table proves and include polarity/reachability, or retire its use once the shared checking judgment covers it. | Document the summary's premises and consumers; do not treat the invocation walk as an interchangeable proof—it answers a different question. | **Source + tracker:** `paramRowAtomOccs` still walks both sides identically. No laundering witness established by this review or the issue. |
| [#995](https://github.com/MedakaLang/medaka/issues/995), two post-unify soundness walks | **Migration debt within the architecture.** `launderEscapeFromLog` and `checkImplEffVarRigidity` remain. Consolidation is justified only when one checking contract covers arrow-spine, off-spine and tail-identity cases, including supplied/default methods. | Refresh the historical blocker account; preserve the pre-unification check and coverage until replacements are demonstrated. A file extraction alone establishes no soundness property. | **Source:** both walks remain; the issue's old graded-interface blockers are no longer a reliable execution plan. |
| [#3541](https://github.com/MedakaLang/medaka/issues/3541), exponential α | **Fits existing DAG/complexity requirements.** Memoize lexical binder abstraction per analysis call/domain using binding identity and its defining scope. Do not cache by spelling across shadowing or requests. | Make the α complexity contract explicit alongside the architecture's symbolic-DAG rule. No semantic weakening or depth cutoff. | **Source + tracker:** `varAuthority` re-evaluates definitions; issue supplies exponential measurements. |
| [#3514](https://github.com/MedakaLang/medaka/issues/3514), cubic variance fixpoint | **Fits.** Dependency/SCC scheduling and keyed tables should compute the same least fixpoint efficiently. Invocation soundness depends on convergence. | Preserve §6.4/§7's least-fixpoint requirement; never reinstate a finite iteration cap as a performance repair. | **Source + tracker:** fixpoint is shared with invocation analysis; measurements are from the issue. |

**Runtime confinement is the main architectural addition.** These issues do not
all mean static typing is unsound. They distinguish bounds on strings, bounds on
actual resources, and preservation of a hidden handle's more precise authority.

| Issue | Architectural fit and required work | Spec/design action | Evidence |
|---|---|---|---|
| [#3585](https://github.com/MedakaLang/medaka/issues/3585), filesystem TOCTOU | **Missing operation-level enforcement.** Checking a pathname and then resolving it again cannot enforce confinement against concurrent symlink changes. Bind authorization to the actual operation using anchored descriptors and beneath/no-follow resolution appropriate to each operation, including both rename endpoints and creation. Linux and macOS need stated equivalents. | §2.3/§7 must distinguish the current checked-path guarantee from the desired performed-operation guarantee. Define symlink, entry-versus-target and relative-root semantics before implementation. | **Source + tracker:** runtime checks before ordinary file operations; tracker reports 47 escapes in 200,000 reads. Race not re-run. |
| [#3592](https://github.com/MedakaLang/medaka/issues/3592), Net only bounds strings | **Missing resource interpretation and enforcement adapter.** Grants must reach endpoint creation and the operations on indexed sockets. Define what Net authorizes for DNS, connect, listen and accept, and how host/port identity is normalized. Existing authority terms can remain. | Extend §2.3/§7 with a network resource contract. Decide hostname versus resolved-address guarantees and redirects/re-resolution where applicable; lowercasing strings alone does not define endpoint confinement. The issue's URL-like examples need checking against each extern's actual input format. | **Source + tracker:** grant extern roster covers files; no new network escape was demonstrated here. |
| [#3590](https://github.com/MedakaLang/medaka/issues/3590), Wasm has no grant enforcement | **Missing target/host protocol.** Pass grants to a host that enforces them, or require a host-enforced module manifest with explicitly coarser granularity. Embedding a custom section alone is not enforcement, and a module-wide grant is not a per-call grant. | State the supported target/host guarantee in §7/§8. Current pattern refusal is an honest limit. Exact-path safety depends on the host's resource-resolution model; absence of a check is not by itself a demonstrated escape in every VFS. | **Source + tracker:** Wasm rejects narrow patterns and drops admitted grants at file imports. |
| [#3591](https://github.com/MedakaLang/medaka/issues/3591), sourceless authority becomes top | **Optional precision extension, currently a documented safe fallback.** To preserve the packed handle's narrower runtime authority, carry trustworthy grant evidence with existential/proof-source values or relevant method environments. Caller-passed authority alone cannot reconstruct it. | Choose explicitly between current declaration-row confinement and value-carried confinement. The latter changes representation/ABI and the erasure exception; it is not merely a solver fix. No change is required to retain the present weaker guarantee. | **Source + tracker:** `gsSourceless` identifies opened existentials and impl-head indices. |
| [#3586](https://github.com/MedakaLang/medaka/issues/3586), symlink false refusals (F14) | **Fits the enforcement layer, with a semantic distinction.** Exact-grant symlinks must follow the documented canonicalization rule. Dangling symlinks are explicitly refused by today's spec; accepting more requires a safe resolution rule, not a relaxed string check. | Split these runtime cases from this issue's elaboration/rendering cases. Review alongside #3585 so a precision improvement cannot reopen confinement. | **Tracker; spec inspected.** |
| [#104](https://github.com/MedakaLang/medaka/issues/104), capability tail/extern assurance | **Mixed historical umbrella.** Manifest emission and much label refinement exist. `exit` is still unlabelled; Wasm embedding and systematic extern-row assurance remain separate concerns. The trusted catalog must cover what each primitive actually does. | Reconcile Exit/process-control capability policy with IO's enumerated labels before relabelling. Document assurance responsibilities across declaration, lowering, runtime and host; distinguish artifact emission from enforcement. | **Source + tracker:** `extern exit : Int -> Unit`; historical comments include superseded underscore signatures. |

The current implementation already has a substantial grant mechanism in
`typecheck.mdk` (`GrantState`, `fileGrantExterns`, `grantPass`), plus native,
interpreter and Wasm consumers. At the reviewed baseline the architecture said authority annotations
“do not add hidden arguments,” which is false for this implementation. Its module
map also lacked an owner for grant elaboration. Both are corrected in the
companion architecture update.

Add an explicit boundary: the typechecker produces a checked, identity-bearing
grant requirement and its instantiation; shared elaboration lowers it to ordinary
runtime arguments; backends implement a specified ABI; the runtime/host enforces
the resource interpretation. Backends must not re-solve authority constraints.
Give catalog entries explicit determining positions and enforcement support, so
Net/rename/new primitives do not depend on independently maintained name rosters.
Separate the typechecking service from backend/runtime code when extracting it;
this does not require completing the unrelated typechecker split first.

**Manifest, diagnostics and tooling issues.** These mostly fit existing services.
They are important because users and hosts see the rendered artifact rather than
the internal proof.

| Issue | Mapping and required action | Evidence |
|---|---|---|
| [#3331](https://github.com/MedakaLang/medaka/issues/3331), policy cannot analyze imports | **Integration gap.** `manifest` and `check-policy` already call `invocationSummary`; policy still constructs a single-module program. Share the checked project/entry input, diagnostics and invocation context. No second summary algorithm. | **Probe + source:** two-module manifest emits `Stdout = true`; policy allowing Stdout rejects before policy evaluation. |
| [#3330](https://github.com/MedakaLang/medaka/issues/3330), imported type error attributed to entry file | **Diagnostic provenance.** Keep module source identity through failure rendering; use the common project diagnostic path. | **Source:** `runManifestResolveGate` renders type errors against `tsrc`/`target`. |
| [#3540](https://github.com/MedakaLang/medaka/issues/3540), unescaped parameter output | **Serialization gap.** Source rendering and TOML serialization need correct, format-specific escaping. Semantic keys must remain structural, never rendered strings. Round-trip the emitted manifest through a TOML parser. | **Tracker + source locations inspected.** |
| [#3551](https://github.com/MedakaLang/medaka/issues/3551), qualifier-join messages | **Explanation gap.** Report the real domain/schema and distinguish mentioning an index inside a join from carrying evidence for it. No new inference rule. | **Tracker.** |
| [#3553](https://github.com/MedakaLang/medaka/issues/3553), FFI diagnostics | **Identity/witness rendering.** Disambiguate aliases and show the uncovered component of a joined authority. Its third item is explicitly unconfirmed and should remain so. | **Tracker.** |
| [#3574](https://github.com/MedakaLang/medaka/issues/3574), Product/extension diagnostics | **Parser commitment, domain-aware rendering and source locations.** Preserve the most relevant parse failure and name the actual failed constraint. The `p ++ ""` case is separately an optional precision rule: today's spec widens variable extension even for an empty suffix. | **Tracker; current §4 inspected.** |
| [#3586](https://github.com/MedakaLang/medaka/issues/3586), nested binder/rendering cases F11–F13 | **Elaboration/printing consistency.** Preserve written binder domains recursively, print enough domain information to express the binding, and avoid cascading atomic-label diagnostics. Same declaration service as #3548. | **Tracker.** |
| [#2465](https://github.com/MedakaLang/medaka/issues/2465), re-exported method documentation | **Tooling provenance.** Preserve the origin's written method signature when available; ensure fallback scheme rendering retains rows. Re-check after the scheme-renderer changes before assuming the whole original symptom survives. | **Tracker; not re-run.** |
| [#1027](https://github.com/MedakaLang/medaka/issues/1027), missing effect references | **Namespace consumer gap.** Index effect definitions and uses by resolved declaration identity. No new effects semantics. | **Tracker; not re-run.** |
| [#2102](https://github.com/MedakaLang/medaka/issues/2102), unhelpful policy witness | **Diagnostic selection.** Prefer a witness for the actual failed authority predicate, with deterministic tie-breaking. “Most concerning” requires a product policy; it is not a new lattice order. | **Tracker.** |
| [#2123](https://github.com/MedakaLang/medaka/issues/2123), disappearing polarity diagnostic | **Unconfirmed accumulator defect.** Preserve as needs-repro; do not build an architecture change around a witness the original review could not reproduce. | **Tracker explicitly unconfirmed.** |
| [#3300](https://github.com/MedakaLang/medaka/issues/3300), async native doctest rejection | **Unresolved harness/integration report.** A generated wrapper must preserve immediate/forcing/deferred rows just like source code. Reproduce on current harness before assigning a missing language mechanism. | **Tracker only; old command/defaults and `runAsyncIO` examples predate current source.** |

**Open issues whose original architectural premise has changed.** These need
tracker reconciliation before implementation scheduling; a passing sample is not
an automatic issue closure.

| Issue | Present reading |
|---|---|
| [#3321](https://github.com/MedakaLang/medaka/issues/3321), fail-open manifest | **Probe:** ill-typed and nonexistent entries refuse; a value-bound `main` emits `Stdout = true`. Imports also produce a nonempty manifest. Comments already mark the earlier loading cases fixed. The forcing-row and invocation carriers now address the reported representation gap. |
| [#3327](https://github.com/MedakaLang/medaka/issues/3327), forward-declared Effect kinds | **Probe:** the adverse declaration order now accepts and preserves `W <Clock \| a>`. This agrees with the architecture's declared-kind prepass checkpoint. |
| [#2132](https://github.com/MedakaLang/medaka/issues/2132), FFI `curl` admits `curl_extra` | **Probe:** now rejected. §2.3's exact-element versus explicit-pattern rule addresses this witness without a new FFI domain. |
| [#2583](https://github.com/MedakaLang/medaka/issues/2583), dropped displayed rows | **Probe and 2026-09-28 issue comment:** effect variables and forcing rows print. The remaining proposal concerns variable naming/readability, not missing effect tracking. |
| [#2111](https://github.com/MedakaLang/medaka/issues/2111), silently narrowed declared tail | **Probe:** the reported Stdout/Stdin example now rejects at the definition with a caller-chosen-row diagnostic. Rigid signature checking implements the intended contract. |
| [#797](https://github.com/MedakaLang/medaka/issues/797), return-only free row | **Semantic premise superseded.** A declared `<e>` is universal, not permission to infer any effects. Rejecting a concrete effectful body can now be correct. Preserve honest pure/forwarding controls and diagnose rigidity rather than a fabricated empty row. Use #138 for genuine inference holes. |
| [#1118](https://github.com/MedakaLang/medaka/issues/1118), positional unifier; [#1119](https://github.com/MedakaLang/medaka/issues/1119), variance; [#820](https://github.com/MedakaLang/medaka/issues/820), graded interfaces | **Historical:** each has a later comment recording delivery in PR #2491; current source contains graded interfaces, deferred Async bodies, row joins and variance analysis. Re-audit residual scope rather than schedule those old migration plans. #1118's old “grade subsumption in indices” wording must defer to the current invariant-index spec. |
| [#3332](https://github.com/MedakaLang/medaka/issues/3332), dead manifest path | **Source:** `runManifestAtoms` and singular `atomToAllowTok` are absent; the current plural helper is live. Reconcile the stale-symbol issue instead of recreating its proposed normalization path. |

**Optional or adjacent work.**

| Issue | Relationship to effects architecture |
|---|---|
| [#138](https://github.com/MedakaLang/medaka/issues/138), wildcard rows | Additive annotation feature. Give holes fresh inference identities, solve before publication, and specify partial-row meaning. Never reinterpret named universal rows as holes. Its old quoted-underscore analogy is obsolete. |
| [#3387](https://github.com/MedakaLang/medaka/issues/3387), GC hold | The later owner ruling explicitly says this is pure runtime control, not a new effect. Follow the scoped intrinsic proposal if still needed; do not reopen the effects taxonomy from the original issue body. |
| [#3467](https://github.com/MedakaLang/medaka/issues/3467), attributes discard signatures | Cross-cutting declaration-preservation defect: it can bypass effect contracts as well as ordinary types. Repairing the front-end contract is necessary; adding another effects checker cannot compensate for a discarded signature. Tracker evidence only here. |
| [#1518](https://github.com/MedakaLang/medaka/issues/1518), record-update evaluation order | Backend agreement/evaluation semantics. A may-effect row describes permitted effects, not their execution order; changing row algebra would not fix this. Tracker evidence only here. |

**Specific architecture/spec amendments identified by the review.** The companion
changes already clarify dispatch proof versus selection, transcribe #3482's
ratified rule with its implementation limitation, document the shipped grant
boundary, and correct erasure/precision and delivery claims. The implementation
extensions below remain work to do.

1. **Separate dispatch shape from full typing proof.** Add the repeated-variable
   case to EFFECTS §6.9 and the dictionary applicability contract. Effects never
   rank instances, but successful evidence must preserve rows, qualifiers and
   indices. This is the immediate soundness priority (#3523).
2. **Specify constraint ownership and joint solving.** Refine §4.1/§6.8 and the
   solver contract for flexible input upper bounds, joined index equalities and
   mention-closed recursive residuals (#3473/#3537/#3482). Outcomes remain
   proved, deferred or refused; no arbitrary join decomposition, early defaulting
   or escape of a local binder. #3482 already has a ratified extension to transcribe.
3. **Complete the qualified expression judgment.** Give expected-domain checking
   one rule across arguments, results and constructor fields; make schema-directed
   lifting and declaration well-formedness explicit (#3532/#3543/#3548). Add written
   residual contexts as a separate surface extension (#3566).
4. **Document authority-grant elaboration and its trust boundary.** Update the
   architecture module map, ownership and ABI contract for the already-shipped
   grant pass. Specify native/interpreter/Wasm enforcement separately and define
   filesystem/network resources, not just string languages (#3585/#3590/#3592).
   Decide whether #3591's stronger value-carried guarantee is wanted.
5. **Repair the erasure and precision claims.** §8 first says effects contribute
   nothing to runtime representation, then introduces hidden grants. State that
   types/rows erase while a selected enforcement projection survives. Successful
   results and instance selection are annotation-independent; grant checks may
   refuse execution and have runtime cost. Do not claim full observational
   equivalence while allowing annotation-dependent refusal. Likewise §9's
   “tightest sound” manifest claim must be relative to the chosen abstraction,
   declared contracts and host protocol: §§4/7 explicitly permit conservative
   abstraction, unknown-to-top and invariant-slot overcharging. Keep soundness,
   principality within a supported fragment, and manifest precision distinct.
6. **Make artifact provenance part of the consumer boundary.** Manifest and policy
   should consume the same checked project/entry, invocation context and located
   diagnostics. Serialization is a separate, tested projection of structural
   authority values (#3331/#3330/#3540). Update the architecture's stale claim that
   #3463 is unbuilt: the handoff and code show it is delivered.

The static completion bar should cross direct calls, interface methods, stored
callbacks, recursion, imports and signed/unsigned bindings, with positive controls
and deliberately dishonest counterparts. For solver changes, permuting arguments,
clauses and declarations must preserve the result; newly accepted programs must
also execute under all supported engines. For runtime confinement, test the actual
resource reached, including adversarial filesystem mutation and the host boundary,
rather than treating a correct manifest or engine agreement as proof of enforcement.

Recommended order: close the instance-proof breach; settle ownership/joint-solving
contracts and their recursive residual extension; complete expression checking;
develop resource enforcement against its explicit target/host contract. Diagnostics,
serialization, performance and tracker reconciliation can proceed within those
boundaries. None requires reopening the whole typechecker rearchitecture.

**Tracker reconciliation completed on 2026-09-29.** Nine closures were written
with evidence comments, then their comments and final states were read back:

| Closed issue | Closure basis |
|---|---|
| [#3321](https://github.com/MedakaLang/medaka/issues/3321#issuecomment-5900178144) | Fresh manifest refusals for ill-typed, unresolved and absent entries; nonempty forcing rows for `main` and `x`; imported entry succeeds. |
| [#3327](https://github.com/MedakaLang/medaka/issues/3327#issuecomment-5900178822) | Both declaration orders accept with the effect index preserved. |
| [#2132](https://github.com/MedakaLang/medaka/issues/2132#issuecomment-5900179460) | Both unequal-name directions reject; equal-name control accepts. |
| [#2111](https://github.com/MedakaLang/medaka/issues/2111#issuecomment-5900180132) | Dishonest declared tail rejects; honest `<Stdin, Stdout \| e>` control accepts with its tail retained. |
| [#797](https://github.com/MedakaLang/medaka/issues/797#issuecomment-5900180770) | Current universal-row semantics supersede the wildcard reading; effectful body rejects with a rigidity diagnostic, pure body preserves `<e>`. |
| [#3332](https://github.com/MedakaLang/medaka/issues/3332#issuecomment-5900181418) | Obsolete dead exports are absent; current consumers use the checked path and plural live helper. |
| [#1118](https://github.com/MedakaLang/medaka/issues/1118#issuecomment-5900182074) | Recorded delivery plus closed prerequisite/fix issues; current invariant-index semantics supersede the old positional wording. |
| [#1119](https://github.com/MedakaLang/medaka/issues/1119#issuecomment-5900182703) | Recorded delivery and current variance fixpoint; later performance/guarantee concerns remain separate. |
| [#820](https://github.com/MedakaLang/medaka/issues/820#issuecomment-5900183321) | Recorded delivery, all four phases closed, and current deferred interfaces/Async implementation. |

#2583 was retitled and narrowed to its remaining variable-naming proposal;
#995 now identifies retained checks without the obsolete graded-interface blocker;
#104 now distinguishes shipped manifest/authority features from remaining
catalog/platform work. Their original reports were preserved beneath dated
corrections, and all three remain open. The broader #830 was left open; the
effect-row witness alone does not settle every ordinary type-signature case.
