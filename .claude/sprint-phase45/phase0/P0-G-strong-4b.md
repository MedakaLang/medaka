# P0-G — DESIGN RUN for **STRONG Phase 4b: identity-keyed impl selection**

**Analyst:** packet P0-G, READ-ONLY. **Worktree:** `/root/medaka/.claude/worktrees/peppy-brewing-kitten`
**BASE (pinned):** `aaa437167b633d6070adccd055c8c2a19e9bb8c6`
**Method:** static derivation only. No build, no gate, no sub-agent, no edit to `compiler/`,
`stdlib/`, `runtime/`, `test/`. Every `file:line` below was printed at its exact number before
being written down; anything I could not print is DELETED or listed in `## REFUSALS`.

Owner ruling being designed to: **Phase 4b does the STRONG fix — identity-keyed impl selection,
not the name-keyed repoint.**

*(Appended live as derived — never buffered. **Sections are therefore in DERIVATION order, not
alphabetical order:** `0 · A · C · B · D · F · E · G · SUMMARY`. C precedes B because the
source contradiction had to be resolved before the options could be costed; F precedes E
because it was the blocking question. Each section is self-contained; §F.5 explicitly retracts
one claim made in §B/§D.)*

---

## 0. HEADLINE — read this before §A

Three findings, each grep-proven below, and together they change the shape of 4b:

1. **§C is resolved, and the source comment is FALSE. `resolve` does NOT reject two
   interfaces in one module sharing a method name — it has no value-name duplicate check at
   all.** `duplicateErrors` (`resolve.mdk:1922`) checks exactly three kinds — `type`,
   `constructor`, `interface` — and no fourth. What DOES exist is a **cross-module**
   ambiguity rejection (`AmbiguousOccurrence`, `resolve.mdk:726`) that fires on ≥2 *imported*
   spellings and **explicitly excludes own-module declarations** (`keepAmbiguous`'s
   `not (contains n sameMod)`). ⇒ the comment generalized the cross-module guard to the
   intra-module case. **That asymmetry is the whole bug.**

2. **There is exactly ONE identity supply for a method occurrence in the entire compiler**,
   and it is `perRun.methodIfaceParamsRef` — an `OrdMap` keyed by the **bare method name**
   whose VALUE is a full `IfaceRef { irName, irOrigin }`. `recordImplObligation` (`:11306`),
   `ifaceParamMonos` (`:15314`) and `ifaceOfMethodName` (`:24508`) are its only readers, and
   every one of them takes the interface out of that entry. **The identity is not missing —
   it is in the payload. The KEY is what collides.** This is a textbook member of the class
   the tree already names at `frontend/ast.mdk:492-494`:
   > *"**a table keyed by a BARE NAME that STORES a type head is an identity-supply defect**"*

   That paragraph instructs the reader to **derive** the member set rather than read its list
   of two (#1256 `recordByNameRef`, #1259 `universeDataEnv`). `methodIfaceParamsRef` is a
   third member and is not on that list.

3. ⇒ **STRONG 4b is NOT one unit. It is TWO, and they are independent** — different files,
   different failure modes, different gates, and neither subsumes the other:
   - **S (selection)** — the `*ByIface` family compares `ir.irName` (a spelling). Re-key it
     to compare `IfaceRef` identity via the comparator that already exists
     (`sameTyConHead`, `frontend/ast.mdk:496`). One file, ~6 signatures, *narrowing only*.
   - **Q (supply)** — decide which interface an occurrence denotes. **For #1182's shape there
     is no answer to derive: both declarations are "own", and the source says so itself**
     (`typecheck.mdk:16802-16818`). The principled fix is to make the ambiguity
     **unrepresentable** — reject it in `resolve.mdk` — which is what makes
     `methodIfaceParamsRef`'s bare-name key SOUND rather than working around its unsoundness.

   Doing S without Q ships identity-keyed selection over an order-decided supply. Doing Q
   without S leaves #1619's same-spelled-interfaces class untouched. **Both are needed and
   they land in that order.**

---

## A. THE QUERY SIDE, TRACED END TO END

Every hop, in pipeline order. "Identity?" is graded against the question *"which `interface`
DECLARATION does this occurrence denote"*.

| # | hop | file:line | what is carried | identity? |
|---|---|---|---|---|
| A1 | resolve: the value environment | `resolve.mdk:1613` `let valuesM = omFromNames (externNames runtimeDecls ++ pValues ++ userValueNames prog ++ imported) omEmpty` | an `OrdMap Unit` **membership SET of bare names** | 🔴 **NEVER PRESENT.** A set cannot carry a payload. Method names enter it flattened by `userValueNames` (`:1531`, `map ifaceMethodNm methods`) and `preludeValueNames` (`:1518`) |
| A2 | resolve: the iface→methods relation | `resolve.mdk:1625` `ifaceMethods = pIfaces ++ uIfaces`, typed `List (String, List String)` (`:260`) | `(ifaceName, methodNames)` pairs | 🟡 **PRESENT BUT ONE-DIRECTIONAL.** Its only reader is `ifaceMethodsOf` (`:1435`), used at `:1433` to validate that an `impl I`'s methods belong to `I`. **The relation is never inverted**, so no occurrence ever asks "which interface declares `m`". Keyed by interface *NAME*, not identity |
| A3 | resolve: occurrence check | `resolve.mdk:715` `checkVar cur env scope n` | a bare `String` | 🔴 LOST. `lookupValue` is a set-membership test |
| A4 | marker: the method pool | `marker.mdk:55` `interfaceMethodNames ((DInterface { methods, ... })::rest) = map ifaceMethodName methods` | `List String` | 🔴 **DISCARD SITE #1.** The arm destructures `DInterface` and takes `methods` only — `name` and `ifaceOrigin` are reachable in that very pattern and are dropped |
| A5 | marker: the union | `marker.mdk:492-493` `let methods = preludeMethods ++ interfaceMethodNames prog2` / `let methodSet = omFromNames methods omEmpty` | `OrdMap Unit` | 🔴 LOST. Prelude and user interfaces flatten into one set |
| A6 | marker: the rewrite | `marker.mdk:90` `\| omHasKey x methods = EMethodRef x` | `EMethodRef String` | 🔴 LOST |
| A7 | AST node | `ast.mdk:875` `\| EMethodRef String` | bare name | 🔴 LOST |
| A8 | typecheck: rp/arg name pools | `typecheck.mdk:14865-14867` `returnPosOfDecl (DInterface { typarams, methods, ... }) = flatMap (returnPosMethod typarams) methods`; `:14870-14873` `returnPosMethod typarams (IfaceMethod mname mty _) \| … = [mname]` | `List String` | 🔴 **DISCARD SITE #2 — and it is INSIDE `typecheck.mdk`.** Same shape as A4 |
| A9 | typecheck: the route-site rewrite | `typecheck.mdk:14906` and `:14948-14949` `\| contains n rpNames = EMethodAt n (Ref RNone) (Ref []) (Ref [])` | `EMethodAt String …` | 🔴 LOST. ⚠️ Note this rewrites from **`EVar n`**, not from `EMethodRef` — a *second*, typecheck-internal marking pass keyed on bare-name list membership |
| A10 | AST node | `ast.mdk:919` `\| EMethodAt String (Ref Route) (Ref (List Route)) (Ref (List Route))` | bare name + 3 route cells | 🔴 LOST |
| A11 | typecheck: inference | `typecheck.mdk:8792` `infer env (EMethodAt name tagRef implRef methodRef) = inferMethodAt env name …`; `:8843` `inferMethodAt env name … = match lookupVar env name` | bare name → a `Scheme` | 🔴 **DISCARD SITE #3.** The scheme pool is `ifaceMethodSchemes : List Decl -> List (String, Scheme)` (`:24594`), built by `declIfaceMethods` (`:24599-24601`), whose `DInterface { name, typarams, methods, ... }` pattern **binds `name` and never uses it** |
| A12 | typecheck: the obligation | `typecheck.mdk:11306` `\| otherwise = match omLookup x perRun.value.methodIfaceParamsRef.value` → `Some (iface, typarams, mty, _)` | 🟢 **`iface : IfaceRef` — FULL IDENTITY, name AND origin** | 🟢 **PRESENT — the ONLY place in the pipeline where it is.** But obtained by a **bare-name lookup into a last-write-wins table** |
| A13 | typecheck: the supply readers | `:24507-24510` `ifaceOfMethodName name = map ((iface, _, _, _) => iface.irName) (omLookup name perRun.value.methodIfaceParamsRef.value)`; `:15314` `ifaceParamMonos` | `Option String` (a spelling) | 🔴 **DISCARD SITE #4 — one line, trivially recoverable.** `.irName` is projected off an `IfaceRef` that carries `irOrigin` beside it |
| A14 | typecheck: the entail rung | `:19783` `EKReturn KeyBuckets Mono Bool` · `:19803` `EKArg KeyBuckets Mono` · `:19809` `EKOp Bool KeyBuckets Bool` — no iface field. `:19794` `EKNestedTop KeyBuckets String …` — a **`String`** iface field | 3 of 4 carry nothing; 1 carries a spelling | 🔴 LOST |
| A15 | typecheck: the route word | `:18556` `keyForSite : String -> List Mono -> Option String` | bare method name | 🔴 LOST |
| A16 | typecheck: the selector | `:19187` `ieSelectRowByMethod : ImplEnv -> String -> List Mono -> Option ImplRow` → `:19132` guard `contains name ms` | bare method name vs the row's method-name list | 🔴 LOST |
| A17 | 🟢 the IMPL-ROW side | `:4074` `\| ImplRow Int InstRef IfaceRef (List Ty) (List Require) (List String)`; `:5795-5796` `irName : String` / `irOrigin : TyConOrigin,  -- the I4 identity of the declaration this occurrence denotes` | full identity | 🟢 **PRESENT AND UNUSED BY THE FILTER** |
| A18 | the peer filter | `:19122` `\| ir.irName == iface && ieRowHeadMatches tys goals`; `:19348` the same compare in `ieCountHeadByIfaceGo` | compares the **SPELLING** | 🔴 **DISCARD SITE #5 — the selection-side one** |

### A.1 The named fix sites

Read as a SET rather than a list, identity is discarded at **five** distinct sites, and they
are not five instances of one bug:

| site | where | class | cost to repair |
|---|---|---|---|
| **#5** `:19122` / `:19348` | `typecheck.mdk` | **SELECTION** compares spelling, not identity | ~6 signatures, one file. **This is problem S.** |
| **#4** `:24508` | `typecheck.mdk` | a reader that projects identity away | one line — but only as good as the table it reads |
| **#1** `marker.mdk:55` · **#2** `typecheck.mdk:14866` · **#3** `typecheck.mdk:24599` | 3 files | the three name-POOL collectors | **NOT INDIVIDUALLY REPAIRABLE — see §A.2** |

### A.2 🚨 THE MARKER DID NOT DROP AN IDENTITY THE RESOLVER KNEW. Nobody ever computed one.

The brief's hypothesis — *"if the resolver knew the interface and the marker dropped it to a
name, that is the whole bug and the fix is upstream of typecheck"* — is **REFUTED**, by A1/A2:

- resolve's value environment is a **set** (`omFromNames`, `resolve.mdk:1613`). It has no slot
  for an interface, so it cannot have known one.
- resolve's `ifaceMethods` (`:1625`) holds only the *forward* relation `iface → methods`.
  Inverting it for #1182's file yields **TWO** answers for `"m"`, and resolve has no rule to
  pick one.

⇒ **Repairing sites #1/#2/#3 is not "carry the thing you already have". It is "compute an
answer that does not currently exist", and for #1182's shape THERE IS NO ANSWER TO COMPUTE.**
The source states this itself at `typecheck.mdk:16802-16818`:

```
-- one user module, so a name it declares cannot collide ACROSS modules, and its
-- own-declaration-wins answer is already the scoped one."  The second clause is FALSE and
-- was measured to be: in ONE file declaring two interfaces that share a method name there
-- is no single OWN declaration — both are own — so there is nothing for a ladder whose top
-- rung is "own declarations win" to select.  The flat answer is last-declared-wins.
-- MEASURED (identical on this build and on main, so nothing here regressed): one file with
-- `interface FA`/`interface FB` both declaring `mth`, `data Blob`, and `impl FA Blob` only —
-- with FA declared FIRST the program is REJECTED `No impl of FB for Blob`, and with the two
-- interface declarations SWAPPED (nothing else changed) it is ACCEPTED at exit 0 and prints
-- FA's body.  The obligation goes to the LAST-declared interface either way; an
-- interface-declaration reordering that changes no program meaning changes the verdict.
```
and, six lines on:
```
-- WITHIN-module discriminator (or an ambiguity diagnostic at the occurrence) that neither
-- A-2.5 nor E-1 provides — it is owed a derivation, not covered.  Nearest tracked relative:
-- #1182 (same one-file two-interface collision, decided by impl-block order at dispatch).
```

🚨 **Note what that says: the tree has ALREADY MEASURED an interface-declaration permutation
flipping a verdict, and recorded it as owed.** That is P0-B §C.2's prediction, independently
measured by an earlier unit and sitting in a comment. The interface-permutation control §E
asks for is therefore not speculative — **its expected pre-fix finding is already written in
the source.**

The parenthetical `(or an ambiguity diagnostic at the occurrence)` is the design this packet
recommends. §C shows why it is also the cheap one.

---

## C. 🚨 THE SOURCE CONTRADICTION — RESOLVED. **The comment is FALSE.**

The claim under test, `typecheck.mdk:2331-2333`:
```
-- is per-module state and a module's scope binds a bare method name to at most one
-- declaration — resolve rejects the ambiguous case outright).
```

### C.1 Resolve has NO value-name duplicate check. Three independent derivations.

**(a) `duplicateErrors` checks THREE kinds and no fourth** — `resolve.mdk:1922-1930`:
```
duplicateErrors : List Decl -> List Decl -> List ResError
duplicateErrors preludeDecls prog =
  let seed = not (programIsCore prog)
  let typeSeed = primitiveTypes ++ whenL seed (dataRecordNames preludeDecls)
  let ctorSeed = primitiveConstructors ++ whenL seed (ctorNames preludeDecls)
  let ifaceSeed = whenL seed (map fst (interfaceList preludeDecls))
  map (dupErr "type") (findDups typeSeed (dataRecordNames prog))
    ++ map (dupErr "constructor") (findDups ctorSeed (ctorNames prog))
    ++ map (dupErr "interface") (findDups ifaceSeed (map fst (interfaceList prog)))
```
`type` · `constructor` · `interface`. **No `method`, no value.** Note `interfaceList`
(`resolve.mdk:1507-1509`) already computes `(ifaceName, methodNames)` over exactly this decl
list — the duplicate check simply never looks at the second component. **The data the fix
needs is already being built, one line above, and discarded.**

**(b) The two value-level duplicate checks cannot SEE an interface method.** Both are decl
walks whose extractors return `None` for a `DInterface`:
```
resolve.mdk:1745: dupSigOf : Decl -> Option (String, Option Loc)
resolve.mdk:1746: dupSigOf (DAttrib _ d) = dupSigOf d
resolve.mdk:1747: dupSigOf (DTypeSig _ n ty) = Some (n, firstTyLoc ty)
resolve.mdk:1748: dupSigOf _ = None
```
```
resolve.mdk:1783: dupValClause : Decl -> Option (String, Bool, Option Loc)
resolve.mdk:1784: dupValClause (DAttrib _ d) = dupValClause d
resolve.mdk:1785: dupValClause (DFunDef _ n ps body) = Some (n, isEmptyL ps, firstExprLoc body)
resolve.mdk:1786: dupValClause _ = None
```
An `IfaceMethod` is a *field of a `DInterface`*, never a top-level `DTypeSig`/`DFunDef`. Both
walks take the `_ => None` arm. (This is the wildcard-arm hazard `AGENTS.md` names, already
realized: neither walk is *wrong*, and neither can see the case.)

**(c) The value environment is a SET, so the ambiguity is not representable.**
`resolve.mdk:1613`: `let valuesM = omFromNames (… ++ userValueNames prog ++ imported) omEmpty`.
`userValueNames` (`:1531`) contributes `map ifaceMethodNm methods` per `DInterface`. Two
declarations of `"m"` insert the same key twice; the second is a no-op.

### C.2 🎯 WHY THE COMMENT BELIEVES IT — there IS such a rejection, for the CROSS-MODULE case

`resolve.mdk:722-726`:
```
  -- use-time ambiguity: resolves, not shadowed by a local, exported by >=2
  -- non-core modules (same-module top-levels already excluded from the set).
  | not (scopeMem n scope) && isAmbiguous env n =
    [AmbiguousOccurrence n (ambigMods env n) cur]
```
and the exclusion is explicit in the set builder — `resolve.mdk:2458-2462`:
```
ambiguousSet : OrdMap ModuleExports -> List Decl -> List (String, List String)
ambiguousSet known prog =
  let prov = valueProvenance known (usePathsOf prog)
  let sameMod = userValueNames prog
  keepAmbiguous sameMod (provToPairs prov)
```
```
keepAmbiguous sameMod ((n, mids)::rest)
  | listLen mids >= 2 && not (contains n sameMod) =
```
**Interface method names ARE participants in that set**: a `public interface`'s methods are
exported as values — `resolve.mdk:2857` `expValues = expValuesDirect prog ++ publicIfaceMethodVals prog env ++ reExpValues coreExp known prog,`
with `pubIfaceMethodSets` (`:2885-2887`) contributing `map ifaceMethodNm methods` per
`DInterface { pub = True, methods, ... }`.

⇒ **Importing two modules that each export a method named `m` from different interfaces
already fails with `R-AMBIGUOUS-OCCURRENCE` (`resolve.mdk:2159`). Declaring both interfaces in
ONE file does not.** The comment states a true fact about one half of the space as though it
covered both.

The tree even documents *why* the intra-module case is excluded, at `resolve.mdk:3592-3594`:
```
--     (`ambiguousSet`) only ever fires on >=2 IMPORTED spellings for this reason:
--     a local declaration is not a participant in the ambiguity, it settles it.
```
That rule ("own declarations beat imports") is correct for **one** own declaration and has no
content when there are **two** — precisely the gap `typecheck.mdk:16805` names.

⚠️ Second scope limit: on the FLAT/single-file env the ambiguity machinery is **hard-wired
off** — `resolve.mdk:1629` reads `ambiguous = [],`. So a single file has neither guard, which
is exactly #1182's repro shape.

### C.3 ⇒ VERDICT, and it is the cheap direction

**Resolve *should* reject and doesn't.** The comment is not merely stale: it is the
**specification of an invariant the rest of `typecheck.mdk` is entitled to rely on and that
nothing establishes**. `methodIfaceParamsRef`'s bare-name key is *correct under that
invariant*. That reframes 4b — the defect is not "the table is keyed wrong", it is "the
table's documented precondition is unenforced."

**Feasibility indicator (heuristic scan, NOT a census — derive before relying on it):** a scan
of every `.mdk` under `compiler/`, `stdlib/` and `sqlite/` for two interfaces in one file
declaring a same-named method found **ZERO collisions**, so the rejection would break nothing
in this tree. Reproduce (read-only, from the worktree root):
```sh
find compiler stdlib sqlite -name '*.mdk' | while read -r f; do
  awk -v F="$f" '/^(public )?(export )?interface /{i=$0;sub(/^.*interface /,"",i);sub(/ .*/,"",i)}
                 /^  [a-z_][A-Za-z0-9_]* *:/{m=$1;sub(/:.*/,"",m); if(i!="")print F,m,i}' "$f"
done | awk '{k=$1" "$2;c[k]=c[k]" "$3;n[k]++} END{for(k in n) if(n[k]>1) print k":"c[k]}'
```
⚠️ It only sees 2-space-indented `name :` lines and does not reset the current interface at an
`impl`, so it establishes HEADROOM, not absence. The authoritative check is running the new
resolve rule over the tree — which is what bite Q1's own gate does.

---

## B. THE OPTIONS, WITH HONEST COSTS

### B.1 Option 1 — carry the identity on the AST node (`EMethodRef` / `EMethodAt`)

**Shape:** widen `EMethodRef String` (`ast.mdk:875`) and
`EMethodAt String (Ref Route) (Ref (List Route)) (Ref (List Route))` (`ast.mdk:919`) with an
identity field.

**🟢 The `AGENTS.md` wildcard trap does NOT apply in its stated form here — and the reason is
worth stating, because it flips the risk assessment.** That trap is about *adding a
CONSTRUCTOR*, which every `_ =>` arm silently swallows. **Widening an EXISTING constructor is
LOUD**: every `EMethodRef n` / `EMethodAt n r i m` destructuring pattern becomes an arity
mismatch and fails to compile. The audit set is therefore mechanically enumerable, not a
judgement call.

**The audit set, grep-proven** (`grep -rn 'EMethodAt \|EMethodRef' --include=*.mdk compiler/`,
comment lines excluded):

| file | `EMethodAt` | `EMethodRef` | notes |
|---|---|---|---|
| `compiler/types/typecheck.mdk` | 15 | 0 | **9 of the 15 CONSTRUCT** — `:14906` `:14948` `:14949` `:15031` `:15034` `:15036` `:20463` `:20487` `:20497` |
| `compiler/frontend/marker.mdk` | 1 (`:308`) | 4 (`:90` `:96` `:165` `:257`) | the minting site |
| `compiler/frontend/resolve.mdk` | 3 (`:635` `:637` `:3293`) | 2 (`:628` `:3291`) | |
| `compiler/tools/printer.mdk` | 2 (`:722` `:940`) | 2 (`:688` `:819`) | the formatter |
| `compiler/ir/sexp.mdk` | 2 (`:136` `:138`) | 1 (`:180`) | 🚨 **moves the S-expr goldens and the selfproc LEG A `ir.sexp` golden** |
| `compiler/frontend/ast.mdk` | 2 (`:919` `:1699`) | 2 (`:875` `:1689`) | |
| `compiler/types/annotate.mdk` | 1 (`:124`) | 1 (`:122`) | |
| `compiler/ir/core_ir_lower.mdk` | 1 (`:150`) | 1 (`:1745`) | |
| `compiler/eval/eval.mdk` | 1 (`:1256`) | 0 | |
| `compiler/tools/check_policy.mdk` | 0 | 1 (`:190`) | |

⇒ **~37 code sites across 9 files**, of which **9 must SUPPLY a value**.

**🚨 AND THAT IS WHY IT FAILS.** Three of the nine construction sites are the bare-name-pool
rewrites themselves:
```
typecheck.mdk:14906:  | contains n rpNames = EMethodAt n (Ref RNone) (Ref []) (Ref [])
typecheck.mdk:14948:  | contains n rpNames = EMethodAt n (Ref RNone) (Ref []) (Ref [])
typecheck.mdk:14949:  | contains n argNames = EMethodAt n (Ref RNone) (Ref []) (Ref [])
```
`rpNames`/`argNames` are `List String` (`returnPosMethodNames`, `:14861`; discard site #2).
**At exactly the sites that matter, the only available value is `None`.** Option 1 threads a
field that is absent precisely where #1182 lives, and an absent field falls back to today's
behaviour — silently. It converts an S0 into an S0 with more plumbing.

- **files touched:** 9 · **signatures changed:** 2 constructors + ~37 destructuring sites
- **moves emitted IR:** ⚠️ only if a supplied identity ever changes a selection. On its own,
  no — but it **does move the S-expr snapshot corpus and the LEG A `ir.sexp` golden**
  (`sexp.mdk:180`) and the formatter goldens (`printer.mdk:819`), for zero behaviour change.
- **FLAT vs MODULE:** identical — the field would be `None` on both for the collision shape,
  since the supply is the same absent one.
- **VERDICT: REJECT.** Correct plumbing for a value that does not exist.

### B.2 Option 2 — recover the identity at the selection site

**REFUTED, and the refutation is short.** The candidates in scope at `keyForSite` /
`ieSelectRow*` are the method name, the goal monos, and `ImplEnv`. The only thing that could
carry an interface is the occurrence's TYPE — and it cannot:

- A method's scheme is built from its declared type alone —
  `methodSchemes … ((IfaceMethod mname mty _)::rest) = let st = sigToSchemeTvsIn scope mty`
  (`typecheck.mdk:24644-24645`). For #1182's `m : a -> Int` in both `A1` and `A2` the two
  schemes are **identical**. Nothing in the inferred type names the interface.
- The `Predicate` that *does* carry identity — `data Predicate = Predicate { iface : IfaceRef, args : List Mono }`
  (`typecheck.mdk:5904`) — is manufactured downstream **from the colliding table**:
  `recordImplObligation` (`:11306`) does `omLookup x perRun.value.methodIfaceParamsRef.value`
  and takes `iface` out of the entry.

⇒ every candidate supply at the selection site is a **derivative of `methodIfaceParamsRef`**.
Recovery is circular. **VERDICT: REJECT.** (This is P0-B's finding, independently re-derived.)

### B.3 Option 3 — fix `methodIfaceParamsRef`'s keying

**P0-B's unverified claim is now VERIFIED, in two ways.**

**(a) Mechanically.** `public export data Ident = Ident Ns IdentOrigin String` (`ast.mdk:310`).
The mint is `mkIdent NsMethod origin mname` (`typecheck.mdk:16834`) where `origin` is the
interface's `ifaceOrigin` — a **module** (`insertMethodIdents`, `:16828`:
`insertIfaceMethodIdents name typarams (declGradedScope typarams methods) ifaceOrigin methods acc`).
For two interfaces in ONE module, `A1.m` and `A2.m` mint the **identical** `Ident`. The
collapse is then explicit:
```
typecheck.mdk:16853: dropMethodIdentCand : Ident -> …
typecheck.mdk:16855: dropMethodIdentCand ident ((c@(i, _))::rest)
typecheck.mdk:16856:   | i == ident = dropMethodIdentCand ident rest
```
so in `addMethodIdentCand` (`:16844-16851`) `prior` drops A1's row, `next` has length **1**,
`listLen next >= 2` is False, `"m"` never enters `collided`, and `overrideScopedMethods`
(`:16872`) — which *"Iterates the collided list — not the table"* (`:16861-16862`) — never
looks at it. **The machinery reports "no collision" on the exact shape that IS the collision.**

**(b) The source says so itself**, at `typecheck.mdk:16813-16818` (quoted in full in §A.2):
*"the flat path therefore has a live defect of this class whose fix needs a WITHIN-module
discriminator (or an ambiguity diagnostic at the occurrence) that neither A-2.5 nor E-1
provides"*, plus *"⚠️ Nor would #1115 (E-1)'s real module ids supply one: both declarations
would carry the SAME module id."*

**(c) A THIRD reason nobody has stated: this machinery is MODULE-PATH-ONLY and #1182's repro
is FLAT.** `mkIdent` returns `None` for `OriginUnresolved` (`ast.mdk:325-326`
`identOriginOf OriginUnresolved = None`), and `insertIfaceMethodIdents`'s
`None => acc` arm (`:16836-16837`) *"contributes NO identity"*. A single-file program's
interfaces carry `OriginUnresolved`. ⇒ **even a fixed `Ident` would not reach #1182's own pin.**

**Sub-option 3′ — widen the identity to include the interface** (`Ns` already has `NsIface`,
`ast.mdk:195`, so `module::Iface::method` is representable). This makes the collision
*visible* — `collided` fills, `applyMethodScopeOverrides` runs. **But it still cannot RESOLVE
it:** `overrideScopedMethods` picks the candidate *this module's scope* selects, and for #1182
the module's scope contains both. Visibility without a discriminator = a table that now knows
it is ambiguous and still has to pick one.

- **files touched:** 1 (`typecheck.mdk`) for 3′ · **signatures:** ~4
- **moves emitted IR:** no, by itself
- **FLAT vs MODULE:** 🚨 **3′ is MODULE-ONLY by construction** and #1182 is FLAT. The header at
  `:2336-2338` already says *"The FLAT path is unchanged and still last-write-wins."*
- **VERDICT: REJECT as a fix.** ⭐ **But KEEP the visibility half** — "this name is declared by
  two interfaces" is exactly the predicate a diagnostic needs, and §B.4 puts it where it works
  on both paths.

### B.4 ⭐ Option 4 (RECOMMENDED) — make the ambiguity UNREPRESENTABLE, then key selection by identity

Two independent halves. Neither is the other's prerequisite in code, but Q must land first in
*time* (§F).

**Q — the supply, fixed by REJECTION rather than by resolution.** Establish the invariant
`methodIfaceParamsRef`'s own header already claims (`:2331-2333`): a module's scope binds a
bare method name to at most one declaration. `resolve.mdk` already computes the exact input —
`interfaceList : List Decl -> List (String, List String)` (`:1507`) — and `duplicateErrors`
(`:1922`) already consumes its `map fst`. Add the fourth kind.

- **files touched:** `compiler/frontend/resolve.mdk` only (+ a diagnostic code in
  `compiler/DIAGNOSTIC-CODES-DESIGN.md`)
- **signatures changed:** ZERO. `duplicateErrors` grows one `++` clause; a new `ResError`
  constructor needs its arms in `resErrorLoc` / `resErrorSexp` / `ppResError` / `resErrorCode`
  (the four dispatchers at `:237`, `:2004`, `:2112`, `:2159` — enumerable, all total)
- **moves emitted IR:** **NO.** It only rejects programs; every accepted program is unchanged
- **FLAT vs MODULE:** 🟢 **BOTH.** `duplicateErrors` runs on the decl list, not on the import
  graph — unlike `ambiguousSet` (`:2458`), which is module-path-only, and unlike A-2.5's
  `Ident` machinery, which is module-path-only *and* origin-gated. **This is the only candidate
  in this whole packet that reaches #1182's own single-file repro.**
- ⚠️ **Scope it to the USER decl list, and check the prelude interaction.** `preludeValueNames`
  (`:1518`) puts core's method names into the same pool, and `programIsCore prog` (`:1924`)
  already guards the seed for the other three kinds — follow that pattern exactly. A user
  interface redeclaring a *prelude* method name is a different, supported shape
  (`marker.mdk:490` `shadowRename preludeMethods prog`) and **must not** be caught.

**S — the selection, keyed by identity.** Change the `*ByIface` family's interface parameter
from `String` to `IfaceRef`, and its guard from `ir.irName == iface` to the comparator that
already exists for exactly this question:
```
frontend/ast.mdk:496: export sameTyConHead : String -> TyConOrigin -> String -> TyConOrigin -> Bool
frontend/ast.mdk:497: sameTyConHead n1 o1 n2 o2 = n1 == n2 && not (tyConIdsConflict o1 o2)
```
```
frontend/ast.mdk:503: tyConIdsConflict o1 o2 = match (identOriginOf o1, identOriginOf o2)
frontend/ast.mdk:505:   (Some i1, Some i2) => i1 != i2
frontend/ast.mdk:506:   _ => False
```
It is already used for precisely this at `typecheck.mdk:16343`:
`cohSameIface a b = sameTyConHead a.irName a.irOrigin b.irName b.irOrigin`.

🟢 **The FLAT degradation is provably safe and needs no special case.** On a single file both
origins are `OriginUnresolved`, `identOriginOf` returns `None` for both, `tyConIdsConflict` is
`False` by the `_ => False` arm, and `sameTyConHead` reduces to `n1 == n2` — **byte-identical
to today's `ir.irName == iface`**. This closes P0-A's REFUSAL 3 (the unverified
`OriginUnresolved` arm).

- **files touched:** `compiler/types/typecheck.mdk` only
- **signatures changed:** 6 in the family (`ieEntriesForIface` `:19119`, `ieCandidatesForIface`
  `:19154`, `ieSelectRowByIface` `:19179`, `ieCountHeadByIface` `:19340` +
  `ieCountHeadByIfaceGo` `:19345`, `ieHeadCollidesByIface` `:19265`, `keyForSiteByIface`
  `:19249`), plus the 4 call sites `:19252` `:19939` `:20227` `:22674`
- **moves emitted IR:** **NO on FLAT (proved above). On MODULE, only where two SAME-SPELLED
  interfaces are live in one graph** — i.e. exactly #1619's class and nothing else
- **FLAT vs MODULE:** 🚨 **they genuinely differ, and the difference is the point.** FLAT is a
  no-op; MODULE narrows. Any gate that grades only single-file fixtures **cannot see this
  bite at all** — see §E.

### B.5 The option the brief invites and the tree does NOT support

**Type-directed disambiguation** ("pick whichever interface has an impl matching the
receiver"). Not proposed. It is a *language feature*, it makes acceptance depend on the impl
set, and it would put the resolution of a **name-resolution question** back into the
typechecker — which is the thing #1182's own body objects to. Recording it as considered and
declined, not derived-against.

---

## D. THE RECOMMENDED DESIGN, SIZED AS BITES

### D.0 The keystone, stated before the bites, because it changes the sizing

🎯 **Q (the resolve rejection) is not merely one of two halves — it is the PRECONDITION that
makes the tree's EXISTING identity machinery correct, on BOTH paths.** Derivation:

- After Q, two declarations of a method name `m` necessarily live in **different modules**.
- Different modules ⇒ different `ifaceOrigin` ⇒ `mkIdent NsMethod origin "m"`
  (`typecheck.mdk:16834`) yields **DISTINCT** `Ident`s ⇒ `dropMethodIdentCand` (`:16855`) no
  longer collapses them ⇒ `listLen next >= 2` (`:16849`) is True ⇒ `"m"` enters `collided` ⇒
  `applyMethodScopeOverrides` (`:16869`) **actually fires** and overlays the floor with this
  module's scoped answer. **The A-2.5 machinery that is dead today becomes live.**
- On FLAT there is exactly one module, so after Q there can be at most one declaration of `m`
  at all — the collision is *unreachable*, which is why the module-only carve-out
  (`:2336-2338`, *"The FLAT path is unchanged and still last-write-wins"*) stops mattering.

⇒ **`methodIfaceParamsRef`'s supply becomes SOUND on both paths without re-keying the table.**
That is what makes the STRONG selector re-key (S3) worth doing instead of circular.

⚠️ **One residual survives Q and must be named, because it is the reason S3 is still needed.**
`keepAmbiguous`'s `not (contains n sameMod)` (`resolve.mdk:2461`) means a module that DECLARES
`interface A1 where m` and also IMPORTS a module exporting `A2.m` is **not** flagged — own
declaration wins, correctly. But `bodyImplEnvRef` is **graph-global**, so `A2`'s impl rows are
still in the env, and `ieEntriesForMethod`'s `contains name ms` (`:19132`) still unions them
into one candidate set. **That is #1182's mechanism surviving Q**, and only scoping the
candidate set by interface removes it.

### D.1 The bites, in landing order

---

#### **BITE G-0 — the interface-permutation instrument. LANDS FIRST, MUST BE RED.**

- **what:** a second permutation strategy in `test/diff_compiler_dict_semantics.sh` §4 that
  permutes **`interface` declaration blocks** instead of `impl` blocks, plus the fixture it
  grades. Full spec in §E.
- **why first:** it is the only thing that can tell "identity-scoped" from "name-scoped", and
  a probe that first runs after the fix cannot demonstrate it was able to fail.
- **NOTHING → SOMETHING?** n/a (test-only).
- `could move:` `test/diff_compiler_dict_semantics.sh` and its ledger rows. ⚠️ **Do NOT add a
  new `test/*.sh`** — `diff_compiler_ci_shard_coverage.sh` reds on any `.sh` in the tree with
  no shard pattern (`AGENTS.md`). Extend the existing gate.
- `nearest miss:` a permuter that reorders interfaces but whose fixture's two interfaces have
  no impl-selection consequence — it would pass pre-fix and prove nothing. The fixture must be
  the *measured* shape from `typecheck.mdk:16806-16810`.
- `engines:` `check` **and** `run` **and** `build`+exec. `check` is load-bearing here because
  the measured pre-fix divergence is a **verdict flip** (exit 1 vs exit 0), which only `check`
  and `run` see; `keyForSite` itself is elaborate-only (`:18531`) so a `check`-only grading
  would be blind to S3.
- `unchecked:` whether §4's chunk permuter tolerates an `interface` block whose body spans a
  `where` + indented methods. Its own rule is *"a chunk starts at any line with a
  non-whitespace character in column 0"* (`:866-867`), which covers it — but derive it on the
  fixture before trusting the parse (its header calls a parse failure under permutation *"a
  permuter bug, not a compiler finding"*).

---

#### **BITE Q1 — resolve rejects two interfaces in one module sharing a method name**

- **what:** one clause in `duplicateErrors` (`resolve.mdk:1922-1930`), fed by the second
  component of `interfaceList` (`:1507-1509`) which is already computed and discarded there.
- **sites, grep-proven:**
  - `resolve.mdk:1929` — the existing `map (dupErr "interface") (findDups ifaceSeed …)` line
    is the template; add a peer for method names.
  - the diagnostic. **Two options, and the cheap one has zero trap surface:**
    - 🟢 **reuse `DuplicateDefinition String String (Option Loc)` with kind `"method"`** —
      `dupErr` (`:1931-1932`) already takes the kind, and `ppResError (DuplicateDefinition k n _) = "Duplicate \{k}: \{n}"`
      (`:2093`) already renders it. **ZERO new constructors, ZERO dispatcher arms, the AST/ADT
      wildcard trap does not apply at all.** Message quality is weak (it names neither
      interface).
    - a dedicated `ResError` constructor modelled on `AmbiguousOccurrence String (List String) (Option Loc)`
      (`:166`), whose `ppResError` (`:2112`) names the participants. Costs **four** arms —
      `resErrorLoc` (`:237`), `resErrorSexp` (`:2004`), `ppResError` (`:2112`),
      `resErrorCode` (`:2159`). 🟢 **VERIFIED SAFE:** none of those four has a wildcard arm
      (`grep -n 'resErrorLoc _ \|resErrorSexp _ \|ppResError _ \|resErrorCode _ ' resolve.mdk`
      → no output; 28/28/29/28 arms against ~28 constructors), so a missing arm is a
      **non-exhaustive match**, i.e. LOUD. **Recommended**, per `compiler/ERROR-QUALITY.md`.
  - `compiler/DIAGNOSTIC-CODES-DESIGN.md` — a new `R-*` code (or reuse `R-DUPLICATE-DEF`,
    `:2145`).
- **🚨 NOTHING → SOMETHING? YES — this is the bite that needs a spec-derived test.** It turns
  `exit 0, no diagnostic` into `exit 1, one diagnostic`. **Every pre-existing fixture covers
  the accepted case**, so no existing fixture can fail on the new behaviour; a green suite is
  vacuous evidence. The tests that catch it, derived from the rule rather than the diff:
  1. **POSITIVE, FLAT** — one file, `interface A1 where m`, `interface A2 where m`. Must reject
     with the new code. (This is #1182's own pin, `test/must_fail_fixtures/1182-…/main.mdk:12-22`
     — so Q1 **drains** it and the drain is the assertion.)
  2. **POSITIVE, MODULE** — the same two interfaces in one *imported* module. Proves the rule
     is on the decl walk, not the entry file.
  3. 🚨 **NEGATIVE, and this is the one the diff cannot suggest** — two interfaces declaring
     `m` in **different** modules, both imported by a third. Must still be `R-AMBIGUOUS-OCCURRENCE`
     at the *use* site (the existing rule, `:726`), **not** the new decl-site rejection. If the
     new clause fires here, Q1 has widened a rejection across module boundaries.
  4. 🚨 **NEGATIVE, prelude** — a user interface declaring a method named `compare`/`eq`. Must
     still be ACCEPTED: `shadowRename preludeMethods prog` (`marker.mdk:490`) is a supported
     shape. `programIsCore` (`resolve.mdk:1924`) and the `seed` gating are the existing
     pattern to follow.
  5. **NEGATIVE, self** — one interface declaring `m` twice. Out of scope for this rule (that
     is a malformed interface, if it is anything); assert whatever today does, unchanged.
- `could move:` `test/must_fail_fixtures/1182-…` (drains), any resolve-diagnostic golden
  corpus. ⚠️ **The shared-corpus trap applies** — enumerate every consumer of the fixture
  directory before touching it; do not trust a count.
- `nearest miss:` a legal program this rejects. The heuristic scan in §C.3 found zero in
  `compiler/`+`stdlib/`+`sqlite/`, which is headroom, **not a proof** — the authoritative check
  is `make check-self` plus `typecheck_compiler_source.sh` after the change.
- `engines:` `check` alone is sufficient and correct — this is a resolve-stage rejection, and
  `medaka run --json`/`lint --json` share the same `Diag` envelope. **Do not** grade it on
  `build`; a rejected program never reaches the backend.
- `unchecked:` whether any `test/` fixture (which are deliberately style-violating and
  sometimes malformed) contains the rejected shape and would flip a golden. Derive with the §C.3
  scan extended over `test/`.

---

#### **BITE S1 — widen the `*ByIface` family from `String` to `IfaceRef`. BEHAVIOUR-NEUTRAL.**

- **what:** parameter type change + guard swap to `sameTyConHead`. Callers construct
  `ifaceRefBare` (`typecheck.mdk:5814`) at the seam, so no supply changes yet.
- **sites, grep-proven (all `compiler/types/typecheck.mdk`):**

  | # | symbol | line | change |
  |---|---|---|---|
  | 1 | `ieEntriesForIface` | `:19119` sig, `:19122` guard | `String`→`IfaceRef`; `ir.irName == iface` → `sameTyConHead ir.irName ir.irOrigin iface.irName iface.irOrigin` |
  | 2 | `ieCandidatesForIface` | `:19154` | sig only |
  | 3 | `ieSelectRowByIface` | `:19179` | sig only |
  | 4 | `ieCountHeadByIface` | `:19340` | sig only |
  | 5 | `ieCountHeadByIfaceGo` | `:19345` sig, `:19348` guard | same guard swap |
  | 6 | `ieHeadCollidesByIface` | `:19265` | sig only |
  | 7 | `keyForSiteByIface` | `:19249` | sig only |
  | 8 | caller — `entailInst` EKNestedTop | `:19939` | `keyForSiteByIface iface …` — see the `EKNestedTop` note below |
  | 9 | caller — `selectReqImpl` | `:20227` | `ieSelectRowByIface … iface goals` |
  | 10 | caller — `concreteReqMatchByIface` | `:22669` sig, `:22674` | |

  ⚠️ **The `""` sentinel is load-bearing and must be preserved explicitly.**
  `selectReqImpl` (`:20225-20227`) branches on `| iface == ""` and `argImplRequiresRoutes`
  (`:20195`) on `let goals = if iface == "" then [m] else m::rest`. Widening to `IfaceRef`
  needs an absence representation — `ifaceRefBare ""` keeps those tests literal; `Option
  IfaceRef` is cleaner and costs two more arms. **Rule either way, don't infer it.**
- **🟢 PROOF OF BEHAVIOUR-NEUTRALITY (this is what makes S1 cheap to review):** with every
  caller supplying `ifaceRefBare n = IfaceRef { irName = n, irOrigin = OriginUnresolved }`
  (`:5814`), `identOriginOf OriginUnresolved = None` (`ast.mdk:326`) ⇒ `tyConIdsConflict`'s
  `_ => False` arm (`ast.mdk:506`) ⇒ `sameTyConHead` reduces to `n1 == n2`, **which is exactly
  the line it replaced.** No program's answer can move.
- **NOTHING → SOMETHING? NO.** Byte-neutral by the proof above.
- `could move:` nothing behavioural. ⚠️ **`test/selfproc_goldens/legA/types.typecheck.golden`
  MOVES** — the signatures of seven top-level bindings change, and that golden is the LEG A
  scheme dump, diffed only in the CI `backend` shard. Re-cut with
  `sh test/capture_goldens.sh --frozen selfproc_legA` and confirm the diff is **additive/typed
  only**, no existing binding's *inferred* type changing for another reason.
- `nearest miss:` a caller that reaches the family through a path not in the ten rows above.
  Re-derive rather than trust the table:
  `grep -n 'ByIface' compiler/types/typecheck.mdk`.
- `engines:` none — nothing observable changes. Grade on the **fixpoint** and
  `typecheck_compiler_source.sh`, not on program behaviour.
- `unchecked:` whether `ifaceRefBare` is the right seam value at `:19939`; `EKNestedTop`'s
  iface field is itself a `String` (`:19794`) and its own supply chain is S2's subject.

---

#### **BITE S2 — supply the REAL identity at the `*ByIface` seams. This is where behaviour moves.**

- **what:** stop constructing `ifaceRefBare` at the seams and pass the identity that already
  exists upstream.
- **sites, grep-proven:**
  - 🟢 **FREE — the identity is already in hand and is being projected away:**
    `typecheck.mdk:22653` `findMatchingImplReqsU univ iface (a0::rest) = match concreteReqMatchByIface iface.irName (a0::rest)`
    — `iface` is an `IfaceRef`. Delete `.irName`.
  - 🟡 `EKNestedTop KeyBuckets String Undetermined Int (List Mono)` (`:19794`) → `IfaceRef`.
    Constructed at `:20007` inside `routeOfD` (`:19995-20007`), whose `iface : String` comes
    from `routeOf` (`:19984`), `argImplRequiresRoutes` (`:20192`), `topRouteV` (`:20057-20058`)
    and ultimately the `ifaces : List String` lists threaded by `routesOfMonosTop` (`:20072`)
    / `routesOfMonosTopV` (`:20035`) / `resolveDictApps` (`:19749`). **~10 further signatures.**
  - 🟢 **the ORIGIN exists at the root of that chain**: those interface names come from
    `=>`-constrained signatures, and `data Constraint = Constraint { constraintHead : String, constraintArgs : List Ty, constraintOrigin : TyConOrigin }`
    (`ast.mdk:612-617`) carries the origin, stamped by resolve's `fillIfaceOccOrigin` /
    `mapIfaceOccDeclLocal` (`resolve.mdk:4064-4067`). **This is a genuine, non-circular
    identity supply — unlike the method-occurrence leg.**
- **🚨 NOTHING → SOMETHING? Partly, in the SUBTRACTIVE direction, and it is NOT automatically
  safe.** A candidate set that had 2 rows can become 1 or **0**. A 0-row set makes
  `ieSelectRowByIface` return `None`, and its callers **fail open**:
  `let routeKey = fromOption tag (keyForSiteByIface iface (m::rest))` (`:19939`) silently
  substitutes the bare tag. So a correct narrowing can present as a *quiet* wrong route rather
  than a diagnostic. **The `None` policy must be ruled before this lands** — the same
  undecided question P0-B raised for `ifaceOfMethodName`.
- `could move:` **emitted IR**, wherever two same-spelled interfaces are live in one module
  graph (#1619's class). ⇒ the self-compile fixpoint, the seed, `test/snapshots/`, LEG A.
- `nearest miss:` a module graph with two same-spelled interfaces where the *impl heads* also
  collide — `test/must_fail_fixtures/1277-xmod-head-spelling-collision-across-ifaces` is named
  in the tree at `typecheck.mdk:19281` and is the nearest existing shape; check it before
  writing a new one.
- `engines:` `run` and `build`+exec. `check` is partially blind (route words are
  elaborate-only, `:18531`).
- `unchecked:` whether the `ifaces : List String` chain's entries are ever synthesised rather
  than resolved (a synthesised entry would carry no origin and degrade to today's answer —
  correct, but it makes the bite's coverage narrower than it looks). **Derive per producer;
  do not assume the chain is uniform.**

---

#### **BITE S3 — repoint `keyForSite` to the identity-keyed selector. LAST, and separable.**

- **what:** P0-B's D-2 — `keyForSite` (`:18556`) swaps `ieSelectRowByMethod` (`:18559`) for
  `ieSelectRowByIface` and `ieHeadCollidesByMethod` (`:18561`) for `ieHeadCollidesByIface`.
  **Its supply is `ifaceOfMethodName` (`:24507`) — which after Q1 is SOUND** (§D.0), so the
  circularity P0-B and RUN-P45-005 correctly refused is gone. Upgrade `ifaceOfMethodName` to
  return the whole `IfaceRef` rather than `.irName` (discard site #4, one line).
- **sites:** `:18556-18593` (definition), `:24507-24510` (the supply), and the three callers
  `:15821` `:19911` `:19954` (unchanged if the interface is derived inside `keyForSite`).
- **🚨 NOTHING → SOMETHING? YES, in the ADDITIVE direction, and the tree states the mechanism:**
  `ieEntriesForIface`'s header (`:19115-19116`) —
  *"`ifn == iface` filter (NOT method-name membership, so a specific impl inheriting a method
  via a DEFAULT is still seen)"*. An `impl Ord (Box a) requires Ord a` defining `compare` and
  inheriting `lt` is **invisible** to `keyForSite "lt"` today and **visible** after. Sites that
  returned `None` now return a row. **Untested by construction**; the test must come from the
  spec (an operator site over a default-inheriting impl), not from the diff.
- `could move:` **emitted IR, broadly.** The fixpoint is the authority (`keyForSite`'s own
  header, `:18528-18529`).
- `nearest miss:` the default-inheriting-impl operator site above. The tree already carries a
  measured repro of exactly this shape at `typecheck.mdk:15856-15860` — *"an `impl Cmp (Box a)
  requires Cmp a` defining `lt` and INHERITING `compare`, in a module the use site does not
  import"* — ⚠️ note it is `lt`-defining / `compare`-inheriting, the mirror image of the
  `Ord` example above; use the tree's wording, not mine.
- `engines:` `run` + `build`+exec. **Never `check`** — `keyForSite` is elaborate-only
  (`:18531`, `:18536-18546`).
- `unchecked:` **whether S3 should ship in this sprint at all.** After Q1 the only surviving
  #1182-class shape is the own-declaration-plus-import residual named in §D.0. That is real,
  but it is a *narrower* bug than the one 4b was chartered for, and S3 carries the largest IR
  move of any bite here. **Recommend: land G-0/Q1/S1/S2, re-measure the residual on the built
  binary, and rule S3 on evidence.**

---

#### **BITE X — strike `ieImplExistsForHeadGo` from the target list (free, documentation only)**

P0-B §C.6, re-verified: `ieImplExistsForHeadGo` (`:15441`) is an **existence** test —
*"does any impl define METHOD `name` at head `hk`"* — reached from three shadow/definer guards
(`:11660`, `:11957`, `:15549`) that are asking a method-name question by construction. There is
no interface in the question. `could move:` nothing. `unchecked:` none.

### D.2 Bite count and landing order

```
G-0  (instrument, must be RED)  →  Q1 (resolve)  →  S1 (substrate, neutral)
     →  S2 (real supply, IR moves)  →  [X, free]  →  ⟨rule S3 on evidence⟩
```

**Five landable bites (G-0, Q1, S1, S2, X), plus one owner decision (S3).**

---

## F. ORDERING AGAINST PHASE 4

*(Written after §D, incorporating P0-F's consumer identification. **It contradicts what §D.0
and §B implied about Phase 4, and I say where, below in F.5.** Appended before §E because it
is the blocking question.)*

### F.0 THE VERDICT, in one table

The question does **not** have one answer, and that is the most useful form it takes: **Phase 4
is ordered differently against S than against Q, and differently again by route.**

| | **vs Q** (the resolve rejection) | **vs S** (identity-keyed selection) |
|---|---|---|
| **route α** — Phase 4 freezes the `List Decl`-built `(iface, method) → positions` table | **NOT ORDERED.** Phase 4 may land first | **NOT ORDERED.** Phase 4 may land first — *and* it can go identity-keyed on its own, for free (F.3) |
| **route β** — Phase 4 freezes a table read off `IE`'s `ieRows` post-K | **NOT ORDERED** (F.4) | 🚨 **HARD-ORDERED: S1 MUST LAND FIRST** |

⇒ **The only hard ordering constraint in the whole matrix is `S1 → Phase 4`, and only on route
β.** Everything else is free.

### F.1 The discriminator, NAMED — and it is decidable today, without an owner ruling

P0-F refused to pick between α and β *"because picking requires knowing which property Phase 4
is chartered to freeze."* **The tree settles it without reference to the charter:** the table
Phase 4 would freeze **already exists**, and it is route α. Grep-proven:

```
compiler/eval/eval.mdk:1882: buildIfaceDispatch : List Decl -> List ((String, String), List Int)
compiler/eval/eval.mdk:1883: buildIfaceDispatch prog = flatMap ifaceDispatchEntries prog
```
```
compiler/eval/eval.mdk:1888: ifaceDispatchEntries (DInterface { name = ifaceName, typarams = typeParams, methods, ... }) = map (ifaceMethodEntry ifaceName typeParams) methods
```
```
compiler/eval/eval.mdk:1892: ifaceMethodEntry : String -> List String -> IfaceMethod -> ((String, String), List Int)
compiler/eval/eval.mdk:1893:   ((ifaceName, mname), dispatchPositionsOf mty (receiverParam typeParams))
```
Its type is **literally `List Decl -> …`**, its walk is over `DInterface` decls, and its
consumer is P0-F's `lookupPositions` (`eval.mdk:1903`). The Core IR sibling is the same shape
(`core_ir_lower.mdk:1405-1409`). **Nothing in this table's production or consumption touches
`IE`, `ieRows`, or any `*ByIface` symbol.**

**So the discriminator is: does Phase 4 freeze THIS table, or build a NEW one off `IE`?**
- If it freezes/extends the existing one ⇒ **route α, no ordering constraint.**
- If the charter's *"post-K, from `IE`"* wording is meant literally and a second, `IE`-derived
  table is built ⇒ **route β, and S1 is a hard precondition.**

That is an owner question about scope, but it is no longer a question about the *code* — and
**route α is strictly cheaper and strictly better-keyed** (F.3), which is itself an argument
for ruling α.

### F.2 P0-F's two consumer-side findings — VERIFIED first-hand, both exactly as reported

```
compiler/eval/eval.mdk:1972: implMethodEntry : EvalEnv (Value e) -> List ((String, String), List Int) -> TyConOrigin -> String -> List Ty -> ImplMethod -> (String, (Int, Value e))
compiler/eval/eval.mdk:1973: implMethodEntry env disp o ifaceName typeArgs (ImplMethod mname pats body) =
compiler/eval/eval.mdk:1974:   let tag = fromOption noneHeadTag (headTyconHead typeArgs)
compiler/eval/eval.mdk:1975:   let key = implRouteKeyWord o ifaceName typeArgs None
compiler/eval/eval.mdk:1976:   let positions = lookupPositions ifaceName mname disp
```
```
compiler/ir/core_ir_lower.mdk:1405: lowerImplMethod : List ((String, String), List Int) -> TyConOrigin -> String -> List Ty -> ImplMethod -> CImplEntry
compiler/ir/core_ir_lower.mdk:1406: lowerImplMethod disp o ifaceName typeArgs (ImplMethod mname pats body) =
compiler/ir/core_ir_lower.mdk:1407:   let tag = fromOption noneHeadTag (headTyconHead typeArgs)
compiler/ir/core_ir_lower.mdk:1408:   let key = implRouteKeyWord o ifaceName typeArgs None
compiler/ir/core_ir_lower.mdk:1409:   let positions = lookupPositions ifaceName mname disp
```
Confirmed: `o : TyConOrigin` is bound, consumed one line earlier for the route key, and **not
passed to `lookupPositions`**. Identical in both engines, two lines apart in each.

**⭐ And the PRODUCER discards it too — this is the half P0-F did not report.**
`ifaceDispatchEntries` (`eval.mdk:1888`) destructures
`DInterface { name = ifaceName, typarams = typeParams, methods, ... }` — the `ifaceOrigin`
field is *in that very record pattern's reach* and is not bound, exactly the shape of discard
sites #1 (`marker.mdk:55`), #2 (`typecheck.mdk:14866`) and #3 (`typecheck.mdk:24599`) in §A.
**This is discard site #6, and it is the one Phase 4 owns.**

### F.3 🟢 ROUTE α CAN GO IDENTITY-KEYED FOR FREE — the renderer already exists and is already used two lines away

```
compiler/frontend/ast.mdk:121: export ifaceIdentity : TyConOrigin -> String -> String
compiler/frontend/ast.mdk:122: ifaceIdentity (OriginModule m) name = "\{m}::\{name}"
compiler/frontend/ast.mdk:123: ifaceIdentity OriginUnresolved _ = ""
compiler/frontend/ast.mdk:124: ifaceIdentity OriginBuiltin _ = ""
```
Its doc-comment (`ast.mdk:104-106`) names it as *"§8 I4's `(originModule, name)` for an
INTERFACE, rendered as ONE comparable string"* — i.e. **it mints exactly the `module::Iface`
spelling the sprint's C4/I2 constraint demands**, and it is already called at both ends of this
very table's neighbourhood:
```
compiler/eval/eval.mdk:1969:      declImplEntries env _ (DInterface { … ifaceOrigin = o, … }) = flatMap (defaultEntry env (ifaceIdentity o ifaceName) typeParams) methods
compiler/ir/core_ir_lower.mdk:1402: lowerDeclImpl _ (DInterface { … ifaceOrigin = o, … }) = flatMap (lowerDefault (ifaceIdentity o ifaceName) typeParams) methods
```
⇒ **on route α, both the producer (`ifaceDispatchEntries`) and the consumers
(`implMethodEntry`, `lowerImplMethod`) already hold `o`.** Re-keying the table to
`(ifaceIdentity o name, method)` is a bind-and-pass at ~4 sites in 2 files, needs **nothing
from S**, and needs **nothing from Q**.

### F.4 🚨 TWO HAZARDS PHASE 4 MUST HANDLE, both derivable and neither yet stated anywhere

**(a) `""` IS ABSENCE, AND THE ONLY LEGAL COMPARISON MAKES EVERY FLAT LOOKUP MISS.**
```
compiler/frontend/ast.mdk:138: export ifaceIdMatches : String -> String -> Bool
compiler/frontend/ast.mdk:139: ifaceIdMatches a b = a != "" && a == b
```
with the rule stated at `ast.mdk:126-129`: *"The ONLY legal comparison on two `ifaceIdentity`
strings: absence never matches, not even itself."* On a flat/loader-less driver every interface
carries `OriginUnresolved`, so `ifaceIdentity` renders `""` for **all** of them, and
`ifaceIdMatches "" ""` is **False**. ⇒ an identity-keyed `lookupPositions` **misses on every
flat lookup** and falls through to its fail-open default:
```
compiler/eval/eval.mdk:1904: lookupPositions _ _ [] = [0]
```
🚨 **That is a silent, whole-path degradation of dispatch positions to `[0]` on `check <single
file>`, lsp, repl and doc.** A naive `==` instead would be the *opposite* bug (every flat
interface collides on the key `""` — the program-global bare-name table hazard). **Phase 4's
table therefore needs a two-tier key — identity when present, name when absent — and that
requirement is invisible from the charter.** It is exactly the fail-open pairing P0-A §A.1.3
flagged (`lookupPositions _ _ [] = [0]`, `keepOrAll original [] = original`).

**(b) The bare key separates DIFFERENTLY-named interfaces already.** `lookupPositions`'
guard is `| iface == i && mname == m` (`eval.mdk:1906`), so `(("A1","m"),p1)` and
`(("A2","m"),p2)` are already distinct rows. ⇒ **#1182's shape is NOT a defect of this table**
— its residual collision is only between two **same-spelled** interfaces, i.e. #1619's class.
That is what makes F.5's retraction necessary.

### F.5 🚨 WHERE THIS CONTRADICTS MY OWN §B/§D — RETRACTED

§D.0 and §B.4 imply Q1 is a precondition for Phase 4 ("Phase 4's lookup would supply a spelling
derived from an order-decided table"). **That was an inference about an unidentified consumer,
not a derivation, and now that P0-F has named the consumer it is WRONG.** The correction:

- `lookupPositions`' key comes from the **declaration side** — `DImpl.iface` / `DInterface.name`
  (`eval.mdk:1965`, `:1969`), both user-written and resolve-stamped. **It never reads
  `methodIfaceParamsRef`**, which is the order-decided table Q1 fixes. Verify the negative:
  `grep -n 'methodIfaceParamsRef' compiler/eval/eval.mdk compiler/ir/core_ir_lower.mdk` →
  no hits (that ref is `perRun` state in `types/typecheck.mdk`).
- ⇒ **Phase 4 is not ordered against Q on either route.** I claimed otherwise; the claim
  reached past its evidence and I withdraw it.

⚠️ **This does NOT weaken Q1.** Q1 is still the only bite in this design that reaches #1182's
own single-file repro (§B.4), and it is still the precondition that makes the A-2.5 identity
machinery live (§D.0). It is simply **not** a Phase-4 blocker. Those are separate claims and I
conflated them.

### F.6 What I still cannot settle

Whether the charter's *"post-K, from `IE`"* wording is a literal data-source requirement
(route β) or a description of the timing. **I did not read the charter** — it is
`.claude/STAGE-B-PHASE45-SPRINT.md` §3 per `DECISIONS.md`, and this packet's brief did not
include it. **The verdict table in F.0 is complete for both readings**, so the owner can rule
without a further design run; but if route β is ruled, `S1 → Phase 4` becomes mandatory and
S1's behaviour-neutrality proof (§D, bite S1) is what makes that cheap rather than a blocker.

---

## E. 🎯 THE VERIFICATION INSTRUMENT

### E.1 What the tree permutes today — DERIVED, and the answer is a hole

| instrument | axis actually permuted | proof |
|---|---|---|
| `test/diff_compiler_import_order.sh` | **the ENTRY MODULE'S IMPORT CLAUSES**, and nothing else | its own header, `:14-16`: *"The axis here is the ENTRY MODULE'S IMPORT-CLAUSE ORDER"*; scope limits at `:99-101`: *"Only the ENTRY module's clauses are permuted"* and *"Import clauses are permuted among THEIR OWN original slots, so a clause never moves across a declaration."* |
| `test/diff_compiler_dict_semantics.sh` §4 | **`impl` BLOCKS, within one file** | the permuter's own regex, `:889`: `$ifacename = $1 if $line =~ /^(?:export\s+)?impl\s+(\w+)/;` and `:901`: `die "need >=2 impl blocks of $iface, found " . scalar(@idx) . "\n" if scalar(@idx) < 2;`. Header `:212`: *"🚨 Section 4 permutes `impl` BLOCKS."* Header `:252`: *"scoped to files directly in `test/dict_fixtures/*.mdk`"* |

⇒ **NOTHING in this tree permutes `interface` DECLARATIONS.** That is precisely the axis onto
which a name-scoped selector displaces #1182's S0 (RUN-P45-005; P0-B §C.2), so **as the tree
stands, a name-scoped 4b would drain #1182's pin and no gate anywhere could see the survivor.**

⚠️ `dict_semantics.sh`'s own header already asks for this, at `:219-224`:
*"should either add a second permutation strategy here … or record why not. ⚠️ A permutation
differential is only order-free along the axis it actually permutes — do not read section 4's
green as 'order does not decide'."*

### E.2 The instrument, specified

**Where it lands:** a **second permutation strategy inside `test/diff_compiler_dict_semantics.sh`
§4**, not a new gate file. 🚨 A new `test/*.sh` reds `diff_compiler_ci_shard_coverage.sh` unless
a shard pattern is added, and an *ungated* one reds it too (`AGENTS.md`). Extending §4 inherits
its shard, its ledger discipline and its already-reviewed comparison harness.

**Mechanics:** the chunk permuter is reusable as-is — it splits on *"any line with a
non-whitespace character in column 0"* (`:866-867`), which is exactly where an `interface`
keyword sits. The change is the tagging regex and the selection rule:
- tag `^(?:public\s+)?(?:export\s+)?interface\s+(\w+)`;
- select **all** interface chunks in the fixture (not "≥2 of the same name", which is the impl
  rule and is wrong here — the whole point is two *differently*-named interfaces);
- reverse them across their original slots, exactly as the impl strategy does, so no
  declaration moves past another.

**The fixture — and it must be the MEASURED shape, not a fresh guess.** The tree already
records the pre-fix observation, at `typecheck.mdk:16806-16810`:
```
-- MEASURED (identical on this build and on main, so nothing here regressed): one file with
-- `interface FA`/`interface FB` both declaring `mth`, `data Blob`, and `impl FA Blob` only —
-- with FA declared FIRST the program is REJECTED `No impl of FB for Blob`, and with the two
-- interface declarations SWAPPED (nothing else changed) it is ACCEPTED at exit 0 and prints
-- FA's body.
```

### E.3 🚨 WHAT IT MUST READ **BEFORE** THE FIX — the fail-capability requirement

**Pre-fix, the fixture must produce TWO distinct signatures and the row must therefore be
LEDGERED, not green.** The expected pre-fix pair, from the quoted measurement:

| ordering | expected pre-fix |
|---|---|
| `interface FA` first | `check` **exit 1**, `No impl of FB for Blob` |
| `interface FB` first | `check` **exit 0**, prints FA's body |

That is a **verdict flip** — the strongest possible divergence, and it means the probe is
unambiguously ABLE to fail. ⚠️ **Do NOT bless a green here.** If the fixture reads invariant
before the fix, the fixture is wrong (most likely: only one interface has an impl-selection
consequence), and a green pre-fix probe proves nothing about the post-fix state.

The row goes in `test/DICT-SEMANTICS`-side ledger the same way §4's known-bad rows do, naming
**#1182**, pinning **both** signatures and asserting there is more than one — so it
**self-drains**: when the two orderings converge, the gate fails and names the issue to close.

### E.4 🎯 THE DISCRIMINATOR — what tells NAME-scoping from IDENTITY-scoping

This is the property the brief asks for, and this instrument is what supplies it:

| fix shipped | interface-permutation row reads | verdict |
|---|---|---|
| nothing (today) | **2 signatures** (verdict flip) | baseline |
| **name-scoped 4b** (`ieCandidatesForMethod` → `…ByIface` with `ifaceOfMethodName`'s spelling) | **still 2 signatures** — the interface is chosen by `methodIfaceParamsRef`'s last-write-wins, i.e. by interface declaration order | 🚨 **the impl-permutation pin DRAINS while this row stays red.** Exactly the blind spot RUN-P45-005 names — and now it is visible |
| **Q1 (this design)** | **1 signature** — both orderings reject, identically, with the new duplicate-method diagnostic | ✅ genuine order-independence: the ambiguity is unrepresentable, so there is nothing left to order |
| S1 alone | 2 signatures (S1 is behaviour-neutral by construction) | correctly unmoved |

⇒ **The instrument distinguishes all four states.** A design that drains #1182's existing pin
but leaves this row red is *self-evidently* the quieter-defect move; a design that turns this
row green has removed the order-dependence rather than relocating it.

### E.5 The second instrument this design needs, which the brief does not ask for

Q1's rejection is invisible to a *value* golden — every existing `.eval.golden` /
`*_fixtures` row pins a program's OUTPUT, and a program that now fails to resolve produces no
output to compare. **The diagnostic-only channel needs its own assertion**: the four
POSITIVE/NEGATIVE fixtures in bite Q1. Without them Q1 could reject *nothing at all* (a typo in
the `findDups` seed) and every gate in the tree would stay green.


---

## G. REFUSALS

**R1 — I did not build, run, or measure anything.** Every claim in this packet is static
derivation over the pinned base `aaa43716`. Where the *tree* records a MEASUREMENT
(`typecheck.mdk:16806-16810`, `:16813-16818`) I have quoted it as the tree's measurement and
labelled it so; **I did not re-derive it on a binary.** It must be re-measured on the base
binary before §E's ledger rows are transcribed — a transcribed measurement is an encoded fact.

**R2 — I decline to size bite S2's signature chain beyond "~10".** The `ifaces : List String`
threading is enumerable at the consumer end (`routesOfMonosTop` `:20072`, `routesOfMonosTopV`
`:20035`, `topRouteV` `:20057`, `routeOf` `:19984`, `routeOfD` `:19995`,
`argImplRequiresRoutes` `:20192`, `selectReqImpl` `:20224`, `resolveDictApps` `:19749`,
`undeterminedRoute` `:20009`, plus `CountImpls`) but its **producers** are not — I did not
trace `funConstraintsRef` / `funConstraintArgsRef` to every writer. A number without that trace
would be an encoded fact with no derivation.

**R3 — Whether bite Q1 breaks any program in `test/`.** The §C.3 scan covered `compiler/`,
`stdlib/` and `sqlite/` only, and it is heuristic (2-space-indented `name :` lines; it does not
reset the current interface at an `impl`). `test/` fixtures are deliberately malformed in
places and are the likeliest source of unexpected red. **Derive on the real rule, not on my
awk.**

**R4 — The `None` policy for `ifaceOfMethodName` (`:24507`) and `ieSelectRowByIface`
(`:19179`), needed by bites S2 and S3.** Failing open is what the code does today
(`fromOption tag (keyForSiteByIface …)`, `:19939`) and it is *quiet*; failing closed narrows
acceptance. **This is a semantics decision, not an implementation detail. It belongs to the
owner and I have not resolved it.**

**R5 — Whether 4b drains #1619 or #1620.** Unchanged from P0-B, and I add no evidence.
#1619's two interfaces are both spelled `Tag`, so only bite **S2** (real identity, not S1's
`ifaceRefBare`) could separate them — and only if the interface-**DEFAULT** registry the issue
actually names is re-keyed too, **a third site nobody in this sprint has enumerated, including
me.** #1620 states in its own body that its mis-selecting site is unknown. I decline to carry
either as drained.

**R6 — I did not verify that `test/must_fail_fixtures/1182-…` drains under Q1 rather than
merely changing its failure mode.** Q1 rejects at *resolve*; that fixture's `claim.txt` grades
a `run` (per P0-B §D-1, citing `claim.txt:32-37`, which I did not open). A resolve rejection
may present as a different observable than the one the claim pins. **Read the claim before
asserting the drain.**

**R7 — Which route Phase 4 is chartered to take (α or β).** I did not read
`.claude/STAGE-B-PHASE45-SPRINT.md`; it was not in this packet's brief. §F.0's verdict table is
**complete for both readings**, so the owner can rule without another design run — but the
ruling is theirs, and I have not made it. What I *have* done is show that the discriminator is
about SCOPE, not about the code: the table Phase 4 would freeze already exists and is route α
(`buildIfaceDispatch : List Decl -> …`, `eval.mdk:1882`).

**R8 — Whether re-keying the route-α dispatch table (§F.3) moves emitted IR.** `positions`
feeds `VTypedImpl tag key positions 0 inner` (`eval.mdk:1977`) and
`CImplTagged tag key ifaceName positions pats …` (`core_ir_lower.mdk:1414`). Whether a
*correctly* re-keyed table ever computes a DIFFERENT `positions` list for a real program — and
hence whether the seed and the fixpoint move — is a question about the two-tier fallback in
§F.4(a), which does not exist yet. **I decline to predict it; the fixpoint is the authority.**

**R9 — The `""`-absence two-tier key design in §F.4(a).** I derived that the hazard exists
(`ifaceIdMatches a b = a != "" && a == b`, `ast.mdk:139`, against `lookupPositions _ _ [] = [0]`,
`eval.mdk:1904`). **I did not design the fallback**, and the choice between "identity tier then
name tier" and "name-keyed with an identity disambiguator" has consequences for #1619 that I
have not worked through.

### G.1 Is STRONG 4b one unit? — **NO. It is two problems and five bites.**

The two problems are **SUPPLY** (which interface does a method occurrence denote) and
**SELECTION** (does the filter compare identity or spelling). They live in different files,
they fail differently, and **neither is a special case of the other**:

- **Selection alone** (S1+S2+S3) ships identity-keyed selection over an order-decided supply —
  the quieter-defect move, and §E.4's interface-permutation row would still read red.
- **Supply alone** (Q1) leaves `ir.irName == iface` (`:19122`) comparing spellings, so two
  same-spelled interfaces across modules stay in one bucket — #1619's class, untouched.

**The ruling's framing — "the STRONG fix: identity-keyed impl selection" — names only the
SELECTION half.** The half that reaches #1182 is SUPPLY, and it is not in `typecheck.mdk`.

---

## SUMMARY

**Recommended design.** Fix the SUPPLY by making the ambiguity unrepresentable — `resolve.mdk`
rejects two interfaces in one module declaring the same method name, which is the invariant
`methodIfaceParamsRef`'s own header already *claims* holds (`typecheck.mdk:2331-2333`) and
which nothing in the tree establishes — and fix SELECTION by widening the `*ByIface` family's
interface parameter from `String` to `IfaceRef` and comparing with the existing `sameTyConHead`
(`ast.mdk:496`), whose absence-makes-no-claim arm makes that change provably byte-neutral on
the flat path. Together they make the tree's already-present A-2.5 identity machinery *live and
correct on both paths* without re-keying a single table.

**Bite count: five landable bites** — G-0 (the interface-permutation instrument, lands FIRST
and must read RED), Q1 (the resolve rejection), S1 (the `IfaceRef` substrate, behaviour-neutral),
S2 (the real identity supply, moves IR), X (strike `ieImplExistsForHeadGo`, free) — **plus one
owner decision (S3, the `keyForSite` repoint), which should be ruled on a post-Q1 measurement
rather than up front.**

**Phase 4 ordering verdict — the question has TWO answers, by unit and by route (§F.0):**
**Phase 4 is NOT ordered against Q on either route** (its key comes from the declaration side,
`DImpl.iface`/`DInterface.name`, and never reads `methodIfaceParamsRef` — verified negative).
**Against S it depends on the route, and the discriminator is decidable today:** the table
Phase 4 would freeze already exists and is route α (`buildIfaceDispatch : List Decl -> …`,
`eval.mdk:1882`), where Phase 4 is unblocked *and* can go identity-keyed for free because
`ifaceIdentity` (`ast.mdk:121`) already mints `module::Iface` and both the producer and the
consumers already hold the origin. **Only if the charter's "post-K, from `IE`" is read
literally (route β) does `S1 → Phase 4` become a hard ordering constraint.** ⚠️ §F.5 **retracts**
this packet's own earlier §B/§D implication that Q1 blocks Phase 4 — that was an inference
about an unidentified consumer, and P0-F naming the consumer refutes it.
