# META
source_lines=623
stages=DESUGAR,MARK
# SOURCE
import types.effect_domain.{
  canonParam, drender, isSubTop, Param(..), pathClimbs, pathSpelling
}
import types.effect_authority.{authHasVars, authConsts}
import types.effect_policy as EP
import types.effect_policy.{
  PolicyVerdict(..), policyRefusals, buildCallGraph, fnEffectsTable, viaChain,
  allOk
}
import types.effect_invocation.{invocationSummary, InvocationOps}
import types.effect_rows.{atomKey, atomLabel, atomAuth, renderAtom, Atom(..)}
-- compiler/tools/check_policy.mdk — the native `medaka check-policy` capability
-- policy checker (WS-1a of EFFECTS-CONFORMANCE-ROADMAP.md).
--
-- A faithful port of bin/main.ml's `check-policy` arm (the §7c "minimal wow demo"
-- from CAPABILITY-PLATFORM.md), byte-identical accept/reject output.  Given a
-- plugin file, a policy (`--allow L1,L2,…`) and an entry function (`--fn name`):
--   1. the CLI loads the file and its imports as `medaka check` does and refuses
--      what `check` refuses; `analyzeProgram` elaborates the loaded program once,
--      and `manifest` reads its row from the same analysis;
--   2. build a call graph (name → set of called top-level names) from the
--      entry module's DESUGARED AST (conservative EVar collection);
--   3. the inferred schemes include prelude names -- `--fn <name>` is arbitrary
--      user input looked up DIRECTLY in the effect table (see `analyzeProgram`);
--   4. read each fn's inferred effect row → its concrete labels
--      (effrowLabels/atomLabel — the native analog of OCaml's effrow_labels);
--   5. policy compare: a label is forbidden iff it is NOT in the policy set
--      (WS-1a = BARE-LABEL compare — see the `-- WS-1b:` seam below; parameter-
--      level compare `--allow 'Net=host/*'` is the later WS-1b task);
--   6. if any forbidden label → REJECT with the call chain that introduces the
--      first forbidden effect; else ACCEPT and run the plugin on a sample
--      request with stub platform capabilities (cacheGet/cacheSet/logEvent).
--
-- Divergence note vs the OCaml oracle: OCaml runs the accepted plugin via
-- Eval.extra_prims (host-injected VPrim stubs for cacheGet/cacheSet/logEvent).
-- compiler's externBindings is fixed and user-declared `extern`s get no eval
-- cell, so we instead SYNTHESIZE Medaka stub funDefs (parsed from a tiny source
-- string) that shadow those names, prepend them to the prelude, and drive
-- evalModulesRootEnv + apply.  The stubbed `logEvent` writes the `   [LOG] …`
-- line directly to the captured output buffer (eval's outputRef), reproducing
-- OCaml's log-then-result ordering byte-for-byte.

import frontend.ast.{EffParamTy(..), effParamSurface, Decl(..)}
import driver.main_autoprint.{shouldAutoPrintMain}
import frontend.parser.{parse}
import frontend.desugar.{desugar}
import types.repr.{Scheme(..), Mono(..), normalize}
import types.private_mangle.{mangleCtorCollisionsPair}
import types.typecheck.{
  ElabResult,
  elaborateModulesWithSchemes,
  lastInvocationOps,
  decodeSetParam,
  bindingGrantArity,
}
import eval.eval.{
  Value(..), evalModulesRootEnvWith, buildStampExterns, apply, outputRef,
  ppValue
}
import support.util.{
  sortUniqS, joinWith, escStr, lookupAssoc, filterList, listLen, escOneHex2,
  anyList
}
import string.{toLower}
import list.{replicate}

-- ── policy args ──────────────────────────────────────────────────────────
public export data PolicyArgs = PolicyArgs (Option String) String String

-- Split the --allow value on ',', dropping empties (mirror String.split_on_char
-- ',' then filter (<> "")).
splitComma : String -> List String
splitComma s =
  filterNonEmpty
    (splitCommaGo (stringToChars s) (arrayLength (stringToChars s)) 0 0 0)

-- WS-4: brace-depth-aware label split.  Commas INSIDE `{…}` (a product Method
-- set, e.g. `Method={GET,POST}`) do NOT separate policy labels.  `depth` tracks
-- nesting; a top-level comma (depth 0) splits.  Backward-compat: existing
-- brace-free policies have depth 0 throughout ⇒ identical to the old split.
splitCommaGo : Array Char -> Int -> Int -> Int -> Int -> List String
splitCommaGo cs n start i depth
  | i >= n = [sliceStr cs start n]
  | arrayGetUnsafe i cs == '{' = splitCommaGo cs n start (i + 1) (depth + 1)
  | arrayGetUnsafe i cs == '}' = splitCommaGo cs n start (i + 1) (depth - 1)
  | arrayGetUnsafe i cs == ',' && depth == 0 =
    sliceStr cs start i :: splitCommaGo cs n (i + 1) (i + 1) depth
  | otherwise = splitCommaGo cs n start (i + 1) depth

sliceStr : Array Char -> Int -> Int -> String
sliceStr cs a b = stringFromChars (arrayFromList (sliceGo cs a b))

sliceGo : Array Char -> Int -> Int -> List Char
sliceGo cs a b
  | a >= b = []
  | otherwise = arrayGetUnsafe a cs :: sliceGo cs (a + 1) b

filterNonEmpty : List String -> List String
filterNonEmpty [] = []
filterNonEmpty (x :: xs) =
  if x == "" then filterNonEmpty xs else x :: filterNonEmpty xs

-- ── WS-1b: policy as (label, written parameter) ────────────────────────────
-- Each comma-separated token is a bare label `L` (the label's whole domain) or
-- `L=rhs`, whose rhs is a parameter written as an atom writes one: a pattern
-- (`Net=a.com/*`), a set (`Env={HOME,PATH}`) or a product's axes
-- (`Net=Host="a.com/*";Method={GET,POST}`, `;` between axes).  The entry is
-- kept WRITTEN and decoded against the declared domain of the label it is
-- compared with (`decodeWrittenParam`), by the same rules as a source atom: a
-- bare pattern on a Product label lifts into its first axis, and an entry the
-- domain does not admit (`Method=GET` on a Set axis) is refused, never read
-- as the whole domain.  A label may have several entries; together they admit
-- what any one of them admits, as a row's atoms of one label do.
parsePolicy : String -> Result String (List (String, EffParamTy))
parsePolicy s = allOk (map parsePolicyTok (splitComma s))

parsePolicyTok : String -> Result String (String, EffParamTy)
parsePolicyTok tok =
  match splitOnFirstEq (stringToChars tok) (arrayLength (stringToChars tok)) 0
    None => Ok (tok, EPTop)
    Some i =>
      let cs = stringToChars tok
      let n = arrayLength cs
      let label = sliceStr cs 0 i
      let rhs = sliceStr cs (i + 1) n
      if rhsIsProduct rhs then
        productEntry tok label rhs
      else if rhsIsSet rhs then
        Ok (label, EPSet (map unquote (decodeSetParam rhs)))
      else
        Ok (label, EPLit (unquote rhs))

-- One product axis `Axis=value`: a set `{a,b}` or a pattern, quoted or bare.
policyAxis : String -> Result String (String, EffParamTy)
policyAxis spec =
  match splitOnFirstEq (stringToChars spec) (arrayLength (stringToChars spec)) 0
    None =>
      Err
        "axis '\{spec}' has no value; write `\{spec}=…`, or leave the axis out for its whole domain"
    Some i =>
      let cs = stringToChars spec
      let name = sliceStr cs 0 i
      let v = sliceStr cs (i + 1) (arrayLength cs)
      if rhsIsSet v then
        Ok (name, EPSet (map unquote (decodeSetParam v)))
      else
        Ok (name, EPLit (unquote v))

-- A product entry's axes, or the first malformed one, named with its entry.
productEntry : String -> String -> String -> Result String (String, EffParamTy)
productEntry tok label rhs = match allOk (map policyAxis (splitSemi rhs))
  Ok axes => Ok (label, EPProduct axes)
  Err m => Err "policy entry '\{tok}': \{m}"

-- A pattern written quoted (`Host="a.com/*"`) or bare (`a.com/*`).
unquote : String -> String
unquote v =
  let n = stringLength v
  if n >= 2 && stringSlice 0 1 v == "\"" && stringSlice (n - 1) n v == "\"" then
    stringSlice 1 (n - 1) v
  else
    v

-- Split a product rhs on `;`, the axis separator (a set's `,` is inside braces
-- and never meets a `;`).
splitSemi : String -> List String
splitSemi s = splitSemiGo (stringToChars s) (arrayLength (stringToChars s)) 0 0

splitSemiGo : Array Char -> Int -> Int -> Int -> List String
splitSemiGo cs n start i
  | i >= n = [sliceStr cs start n]
  | arrayGetUnsafe i cs == ';' =
    sliceStr cs start i :: splitSemiGo cs n (i + 1) (i + 1)
  | otherwise = splitSemiGo cs n start (i + 1)

-- a policy rhs is a product when it contains an axis assignment `=` (after the
-- label `=` already consumed) — e.g. `Host="…"` / `Method={…}`.  A bare prefix
-- pattern (`a.com/*`) has no `=`.
rhsIsProduct : String -> Bool
rhsIsProduct rhs =
  match splitOnFirstEq (stringToChars rhs) (arrayLength (stringToChars rhs)) 0
    None => False
    Some _ => True

-- a policy rhs is a set when it is brace-delimited (`Env={HOME,PATH}`) with no
-- axis `=` inside (that's the product case, already routed above).
rhsIsSet : String -> Bool
rhsIsSet rhs =
  let n = stringLength rhs
  n >= 2 && stringSlice 0 1 rhs == "{" && stringSlice (n - 1) n rhs == "}"

-- Index of the first '=' in the char array, or None.
splitOnFirstEq : Array Char -> Int -> Int -> Option Int
splitOnFirstEq cs n i
  | i >= n = None
  | arrayGetUnsafe i cs == '=' = Some i
  | otherwise = splitOnFirstEq cs n (i + 1)

-- The policy as the reject report renders it (`{…}`): a bare entry as the
-- label, a parameterized one as an atom writes it (`L "pat"`).
policyLabels : List (String, EffParamTy) -> List String
policyLabels [] = []
policyLabels ((l, p) :: rest) =
  l ++ effParamSurface quoteTok p :: policyLabels rest

-- ── 4. effect ATOMS from a scheme ────────────────────────────────────────
-- What the host can make an entry perform: the invocation summary
-- (`types/effect_invocation.mdk`), over the checked program's own
-- constructors and variance table (`lastInvocationOps`).

-- The label view of an atom list (for header rendering + chain keys).  Each atom
-- renders `label` (⊤ param) or `label "pat"` (concrete) via drender — byte-
-- identical to WS-1a for ⊤ params (drender ⊤ = "").
atomLabels : List Atom -> List String
atomLabels atoms = map renderAtom atoms

-- ── 7. accept: run the plugin on a sample request with stub capabilities ─────
-- Synthetic stub funDefs that shadow the user-declared platform externs.  Parsed
-- from source so we don't hand-build the `stringConcat`/literal AST.  `logEvent`
-- writes the OCaml-format `   [LOG] <s>\n` line straight to the captured output
-- buffer (eval forces putStr → outputRef), so the log lines land BEFORE the
-- transform-result line we print afterward — matching the oracle's ordering.
--
-- The stdlib platform externs (getEnv/runCommand/readFile/writeFile/… — the
-- file/net/env catalog declared in stdlib/runtime.mdk) are native-only: they
-- have NO binding under the tree-walk interpreter, so a plugin that reaches one
-- during this accept-path demo run would panic `unbound identifier: getEnv`,
-- leaking a stray runtime-error line before the (correct, statically-derived)
-- verdict.  We stub them here as effectful NO-OPS returning a benign placeholder
-- (`None` / `Err ""` / `[]`), so the demo run completes cleanly.  This ONLY
-- affects check-policy's accept demo; `medaka run` never touches these stubs and
-- keeps its native-only behaviour.  These bodies are eval'd but never
-- typechecked, so `Err ""` serves for EVERY `Result _ a`-returning extern
-- regardless of the Ok payload type.
stubSource : String
stubSource = stringConcat
  [
    "cacheGet req = \"\"\n",
    "cacheSet req result = ()\n",
    "logEvent s = putStr (stringConcat [\"   [LOG] \", s, \"\\n\"])\n",
    -- env
    "getEnv k = None\n",
    "args u = []\n",
    "executablePath u = \"\"\n",
    -- file read: each file extern takes its path's grant last
    "readFile p g = Err \"\"\n",
    "readFileBytes p g = Err \"\"\n",
    "fileExists p g = False\n",
    "canonicalizePath p g = p\n",
    "listDir p g = Err \"\"\n",
    "statFile p g = Err \"\"\n",
    -- file write
    "writeFile p c g = Err \"\"\n",
    "writeFileBytes p b g = Err \"\"\n",
    "appendFile p c g = Err \"\"\n",
    "makeDir p g = Err \"\"\n",
    "removeFile p g = Err \"\"\n",
    "rename o n gs gd = Err \"\"\n",
    "removeDir p g = Err \"\"\n",
    -- exec
    "runCommand cmd a = Err \"\"\n",
    "runCommandBatch cmd j a = []\n",
    -- net
    "netResolve h = Err \"\"\n",
    "netTcpConnect h p = Err \"\"\n",
    "netTcpListen h p = Err \"\"\n",
    "netListenPort fd = Err \"\"\n",
    "netTcpAccept fd = Err \"\"\n",
    "netSend fd b = Err \"\"\n",
    "netRecv fd n = Err \"\"\n",
    "netShutdown fd how = Err \"\"\n",
    "netClose fd = Err \"\"\n",
    "netSetTimeout fd ms = Err \"\"\n",
  ]

-- Run `fn` on the sample request "X-Forwarded-For: 192.168.1.1" with stub
-- platform impls, returning the captured stdout (LOG lines) ++ the transform
-- line.  An entry whose type
-- quantifies authorities first takes one grant per authority
-- (EFFECTS-SEMANTICS §8); the sample run grants each the whole domain.
runPlugin : String -> Int -> ElabResult -> String
runPlugin fnName grants (coreD, modules, _, _, _, _) =
  let stubD = desugar (parse stubSource)
  -- The plugin runs ELABORATED, as `run` does: an interface default reaches an
  -- instance only through the elaboration's disposition table.  The stubs are
  -- plain prelude-level values the evaluator binds after the prelude.
  let (coreE, modulesE) = mangleCtorCollisionsPair (coreD, modules)
  outputRef := ""
  let rootEnv =
    evalModulesRootEnvWith (buildStampExterns ()) (coreE ++ stubD) modulesE
  match lookupValue fnName rootEnv
    None => "   (no '" ++ fnName ++ "' binding in output)\n"
    Some fnVal =>
      let sample = "X-Forwarded-For: 192.168.1.1"
      let granted = fold (f _ => apply f (VList [])) fnVal (replicate grants ())
      let result = apply granted (VString sample)
      let logged = !outputRef
      "\{logged}   \{fnName} \{escStr sample} = \{ppValue result}\n"

lookupValue : String -> List (String, Value e) -> Option (Value e)
lookupValue _ [] = None
lookupValue k ((n, v) :: rest) = if k == n then Some v else lookupValue k rest

-- ── the analysis `check-policy` and `manifest` share ───────────────────────
-- One elaboration of a loaded, resolve-clean program: the loader's module
-- list, each module DESUGARED, dependency-first with the entry last.  Both
-- verbs read the entry's row from it, so a manifest's claim and a policy
-- verdict over the same target come from one analysis, and the accepted
-- sample run evaluates the same elaborated trees.  The caller refuses on the
-- diagnostics `eaElab` carries before consulting anything else.
--
-- `eaSchemes` holds the entry module's own schemes FIRST, then the prelude's:
-- `--fn <name>` is arbitrary CLI input looked up directly by bare name
-- (`lookupAssoc` is a first-match scan), so an entry redefinition of a prelude
-- name must win, and a prelude name (`--fn println`) must be present rather
-- than read as effect-free.  `eaOps` is read straight after the drive, since
-- `lastInvocationOps` describes whichever drive ran last, and so is
-- `eaAutoPrintCall`: when the drivers that run the program print a value `main`
-- (`shouldAutoPrintMain` reads the drive's `main` type), the scheme of the
-- prelude `println` the wrap applies to it.
public export data EntryAnalysis = EntryAnalysis {
  eaElab : ElabResult,
  eaSchemes : List (String, Scheme),
  eaOps : InvocationOps,
  eaEntryDecls : List Decl,
  eaAutoPrintCall : Option Scheme,
}

export
analyzeProgram : List Decl ->
  List Decl ->
  List (String, List Decl) ->
  EntryAnalysis
analyzeProgram rtD coreD modsD =
  let (elaborated, preludeSchemes, ownSchemes) =
    elaborateModulesWithSchemes rtD coreD modsD
  let ops = lastInvocationOps ()
  let autoPrintCall =
    if shouldAutoPrintMain coreD modsD then
      lookupAssoc "println" preludeSchemes
    else
      None
  EntryAnalysis {
    eaElab = elaborated,
    eaSchemes = ownSchemes ++ preludeSchemes,
    eaOps = ops,
    eaEntryDecls = entryModuleDecls modsD,
    eaAutoPrintCall = autoPrintCall,
  }

-- The entry module's decls: the last of the loader's dependency-first list.
entryModuleDecls : List (String, List Decl) -> List Decl
entryModuleDecls [] = []
entryModuleDecls [(_, decls)] = decls
entryModuleDecls (_ :: rest) = entryModuleDecls rest

-- ── driver ──────────────────────────────────────────────────────────────────
-- The outcome of a policy check.  Accept carries the verdict header and the
-- sample run as a thunk: the verdict is decided from the static analysis alone,
-- so the caller prints it BEFORE forcing the run, and a sample that panics
-- cannot hide it.  Reject carries the full report; the run never happens.
public export data PolicyOutcome =
  | PolicyAccept String (Unit -> String)
  | PolicyReject String

-- The verdict for `fnName` under the `--allow` policy, over an analysis the
-- caller already found free of diagnostics.  The caller prints the report and
-- sets the exit code (0 accept / 1 reject).
export
runCheckPolicy : EntryAnalysis -> String -> String -> PolicyOutcome
runCheckPolicy analysis allowStr fnName = match parsePolicy allowStr
  Err m => PolicyReject "rejected. \{m}\n"
  Ok policy => policyVerdict policy analysis fnName

policyVerdict : List (String, EffParamTy) ->
  EntryAnalysis ->
  String ->
  PolicyOutcome
policyVerdict policy analysis fnName =
  let schemes = analysis.eaSchemes
  -- Existence is checked against the complete scheme list, not effTable:
  -- fnEffectsTable deliberately omits verified-pure bindings, so using it as
  -- a name index would reject a real pure entry exactly like an absent one.
  match lookupAssoc fnName schemes
    None => PolicyReject "rejected. no '\{fnName}' entry found\n"
    Some fnScheme =>
      let fnEffects = invocationSummary analysis.eaOps fnScheme
      match policyRefusals fnEffects policy
        PolicyAdmitted =>
          let effStr =
            if listIsEmpty fnEffects then
              "pure"
            else
              "<" ++ joinWith ", " (atomLabels fnEffects) ++ ">"
          let header = "accepted. \{fnName} requires only \{effStr}\n"
          -- The sample is a String; only an entry taking and returning one is
          -- run.  It stays a thunk so the verdict prints first.
          let pluginOutput =
            _ =>
              if takesAndReturnsString fnScheme then
                runPlugin
                  fnName
                  (bindingGrantArity fnName fnScheme)
                  analysis.eaElab
              else
                "   no sample run: '\{fnName}' is not a String -> String entry\n"
          PolicyAccept header pluginOutput
        PolicyRefused forbidden lines =>
          let callGraph = buildCallGraph analysis.eaEntryDecls
          let effTable = fnEffectsTable schemes
          let chain = viaChain callGraph effTable fnName (firstOf forbidden)
          let header =
            "rejected. \{fnName} requires <\{joinWith ", " (atomLabels fnEffects)}>. Not permitted by policy {\{joinWith ", " (policyLabels policy)}}\n"
          let via = "   reached via: " ++ joinWith " → " chain ++ "\n"
          PolicyReject (header ++ via ++ stringConcat lines)

takesAndReturnsString : Scheme -> Bool
takesAndReturnsString (Forall _ _ _ _ _ mono) = match normalize mono
  TFun arg _ res => isStringCon (normalize arg) && isStringCon (normalize res)
  _ => False

isStringCon : Mono -> Bool
isStringCon (TCon "String" _) = True
-- A named argument's type is `String @κ`; the qualifier erases before runtime.
isStringCon (TQual t _) = isStringCon (normalize t)
isStringCon _ = False

firstOf : List String -> String
firstOf [] = ""
firstOf (x :: _) = x

listIsEmpty : List a -> Bool
listIsEmpty [] = True
listIsEmpty _ = False

-- ── WS-1c: capability manifest emission ─────────────────────────────────────
-- Emit a module's verified capability manifest as a TOML artifact.
-- M(module) = verified-row of the entry point — §7 of EFFECTS-SEMANTICS.md.
--
-- Every effect label is a host capability now (the old internal-only `Mut`/`Panic`
-- purity labels were removed 2026-07-14), so the whole verified row goes in the
-- manifest — there is no longer a class of labels to filter out.
--
-- TOML value rendering:
--   PPrefix (Some s) → key = "s"   (concrete prefix/param as a string value)
--   PUnit / PPrefix None → key = true  (bare ⊤ grant — host decides scope)
--
-- Output order: labels sorted ascending (stable/gateable).
-- Labels already arrive sorted from the canonical atom join.
--
-- WS-1c (deferred): Wasm custom section — would embed M(module) into the
-- compiled .wasm binary as a custom section.  Touches wasm_emit.mdk; left
-- as a seam.  Add a `-- WS-1c wasm: encode M as custom section bytes` marker
-- in backend/wasm_emit.mdk when that work is picked up.

-- Render one atom as a TOML key-value line.
-- PPrefix (Some s) → 'Label = "s"'
-- PUnit / PPrefix None → 'Label = true'
-- A set of elements (`Net "a.com/*", Net "b.com/*"`) is an array of the
-- elements' values, `Net = ["a.com/*", "b.com/*"]`; a Set label's single
-- element is itself an array of members.
-- An authority left symbolic at the host boundary is reported conservatively
-- as the bare grant (`Label = true`), never omitted, with a TOML comment
-- naming the variables that left it unresolved. So is a path whose canonical
-- form lies above the working directory, which no working-directory-relative
-- grant admits.
atomToToml : (Atom -> String) -> Atom -> String
atomToToml keyOf a =
  let label = keyOf a
  match authConsts (atomAuth a)
    Some ps if anyList pathClimbs ps => label ++ " = true"
    Some [p] => "\{label} = \{paramToml p}"
    Some (ps@(_ :: _ :: _)) =>
      "\{label} = [\{joinWith ", " (map paramToml ps)}]"
    _ =>
      if authHasVars (atomAuth a) then
        "\{label} = true  # unresolved: \{unresolvedWhy a}"
      else
        label ++ " = true"

paramToml : Param -> String
paramToml p = match canonParam p
  PPrefix (Some s) => tomlQuote s
  PPath (Some s) => tomlQuote (pathSpelling s)
  PSet (Some xs) => "[\{joinWith ", " (map tomlQuote xs)}]"
  PProduct ax if not (isSubTop (PProduct ax)) => "{ \{productTomlInline ax} }"  -- WS-4 inline table
  _ => "true"

-- WS-4: render a product's axes as a TOML inline-table body: a Prefix axis →
-- `host = "…"`, a Set axis → `method = ["GET", "POST"]` (TOML keys lowercased
-- by convention).  Comma-joined.
productTomlInline : List (String, Param) -> String
productTomlInline ax =
  joinWith ", " (map axisToToml (filterList (a => not (isSubTop (snd a))) ax))

axisToToml : (String, Param) -> String
axisToToml (name, PPrefix (Some s)) = "\{lowerFirst name} = \{tomlQuote s}"
axisToToml (name, PSet (Some xs)) =
  "\{lowerFirst name} = [\{joinWith ", " (map tomlQuote xs)}]"
axisToToml (name, _) = lowerFirst name ++ " = true"

quoteTok : String -> String
quoteTok s = escStr s

-- TOML basic strings use four hex digits for control characters; Medaka's
-- source-literal escStr uses braced \u{XX}, which TOML does not accept.
tomlQuote : String -> String
tomlQuote s = "\"" ++ stringConcat (tomlChars (stringToChars s) 0) ++ "\""

tomlChars : Array Char -> Int -> List String
tomlChars cs i
  | i >= arrayLength cs = []
  | otherwise = tomlChar (arrayGetUnsafe i cs) :: tomlChars cs (i + 1)

tomlChar : Char -> String
tomlChar c
  | c == '\\' = "\\\\"
  | c == '"' = "\\\""
  | charCode c < 32 || charCode c == 127 = "\\u00\{escOneHex2 (charCode c)}"
  | otherwise = charToStr c

-- lowercase the first char of an axis name (Host → host) for TOML-key convention.
lowerFirst : String -> String
lowerFirst s =
  let n = stringLength s
  if n == 0 then s else toLower (stringSlice 0 1 s) ++ stringSlice 1 n s

-- Render the whole capability row as TOML.
-- Returns the full TOML block (bare header if no effects).
export
manifestToml : List Atom -> String
manifestToml [] = "[package.capabilities]\n"
manifestToml atoms =
  let lines = map (atomToToml (manifestKey atoms)) atoms
  "[package.capabilities]\n" ++ joinTomlLines lines

-- The TOML key an atom is written under: its bare spelling, unless another
-- atom of the row spells the same label from a different declaring origin
-- (identity is `(origin, name)`), in which case every atom of that spelling
-- is keyed by its origin, `"mod.Name"` (a builtin keeps the bare name).  A row
-- with no such collision is byte-identical to the bare-keyed manifest; the
-- policy side accepts both spellings (`atomPermitted`).
export
manifestKey : List Atom -> Atom -> String
manifestKey atoms a =
  if labelCollides atoms (atomLabel a) then qualifiedKey a else atomLabel a

labelCollides : List Atom -> String -> Bool
labelCollides atoms name =
  listLen
      (sortUniqS (map atomKey (filterList (b => atomLabel b == name) atoms)))
    > 1

export
qualifiedKey : Atom -> String
qualifiedKey a = EP.qualifiedKey a

export
unresolvedWhy : Atom -> String
unresolvedWhy a = EP.unresolvedWhy a

joinTomlLines : List String -> String
joinTomlLines [] = ""
joinTomlLines (x :: xs) = "\{x}\n\{joinTomlLines xs}"

-- Parse args for `medaka manifest <file.mdk> [--fn name]`.
-- Default fn name: "main" (the conventional entry point for manifest extraction;
-- differs from check-policy's "transform" which is the plugin convention).
public export data ManifestArgs = ManifestArgs (Option String) String

-- The manifest for `fnName`, read from the same analysis `check-policy`
-- decides its verdict from (`analyzeProgram`), over an analysis the caller
-- already found free of diagnostics.  A name absent from the scheme list is
-- refused; a name whose scheme carries no effect row (a pure/value binding)
-- still emits the bare `[package.capabilities]` header.
export
runManifest : EntryAnalysis -> String -> Result String String
runManifest analysis fnName = match lookupAssoc fnName analysis.eaSchemes
  None => Err "no '\{fnName}' entry found"
  Some sch => Ok (manifestToml (invocationSummary analysis.eaOps sch))

-- Render the manifest as --allow tokens for round-trip through check-policy.
-- PPrefix (Some s) → "Label=s"
-- PUnit / PPrefix None → "Label"
-- A set of elements is one token per element.
-- Returns a comma-joined string suitable for --allow.
export
manifestToAllowStr : List Atom -> String
manifestToAllowStr atoms =
  let toks = flatMap atomToAllowToks atoms
  joinWith "," toks

atomToAllowToks : Atom -> List String
atomToAllowToks a =
  let label = atomLabel a
  match authConsts (atomAuth a)
    Some ps if anyList pathClimbs ps => [label]
    Some (ps@(_ :: _)) => map (paramAllowTok label) ps
    _ => [label]

paramAllowTok : String -> Param -> String
paramAllowTok label p = match canonParam p
  PPrefix (Some s) => "\{label}=\{s}"
  PPath (Some s) => "\{label}=\{pathSpelling s}"
  PSet (Some xs) => "\{label}={\{joinWith "," xs}}"
  PProduct ax if not (isSubTop (PProduct ax)) =>
    "\{label}=\{productAllowRhs ax}"  -- WS-4 round-trip form
  _ => label

-- WS-4: render product axes as a policy `--allow` rhs `Host="…";Method={…}` —
-- `;`-separated so it round-trips through `parsePolicyTok`/`splitComma` (the
-- brace-depth-aware comma split keeps `{…}` intact).
productAllowRhs : List (String, Param) -> String
productAllowRhs ax = joinSemiTok (flatMap axisToAllow ax)

-- A top axis is spelled by leaving it out, as a policy entry spells it.
axisToAllow : (String, Param) -> List String
axisToAllow (name, PPrefix (Some s)) = ["\{name}=\"\{s}\""]
axisToAllow (name, PSet (Some xs)) = ["\{name}={\{joinWith "," xs}}"]
axisToAllow _ = []

joinSemiTok : List String -> String
joinSemiTok xs = joinWith ";" xs
# DESUGAR
(DUse false (UseGroup ("types" "effect_domain") ((mem "canonParam" false) (mem "drender" false) (mem "isSubTop" false) (mem "Param" true) (mem "pathClimbs" false) (mem "pathSpelling" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "authHasVars" false) (mem "authConsts" false))))
(DUse false (UseAlias ("types" "effect_policy") "EP"))
(DUse false (UseGroup ("types" "effect_policy") ((mem "PolicyVerdict" true) (mem "policyRefusals" false) (mem "buildCallGraph" false) (mem "fnEffectsTable" false) (mem "viaChain" false) (mem "allOk" false))))
(DUse false (UseGroup ("types" "effect_invocation") ((mem "invocationSummary" false) (mem "InvocationOps" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "atomKey" false) (mem "atomLabel" false) (mem "atomAuth" false) (mem "renderAtom" false) (mem "Atom" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "EffParamTy" true) (mem "effParamSurface" false) (mem "Decl" true))))
(DUse false (UseGroup ("driver" "main_autoprint") ((mem "shouldAutoPrintMain" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" true) (mem "Mono" true) (mem "normalize" false))))
(DUse false (UseGroup ("types" "private_mangle") ((mem "mangleCtorCollisionsPair" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "ElabResult" false) (mem "elaborateModulesWithSchemes" false) (mem "lastInvocationOps" false) (mem "decodeSetParam" false) (mem "bindingGrantArity" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" true) (mem "evalModulesRootEnvWith" false) (mem "buildStampExterns" false) (mem "apply" false) (mem "outputRef" false) (mem "ppValue" false))))
(DUse false (UseGroup ("support" "util") ((mem "sortUniqS" false) (mem "joinWith" false) (mem "escStr" false) (mem "lookupAssoc" false) (mem "filterList" false) (mem "listLen" false) (mem "escOneHex2" false) (mem "anyList" false))))
(DUse false (UseGroup ("string") ((mem "toLower" false))))
(DUse false (UseGroup ("list") ((mem "replicate" false))))
(DData Public "PolicyArgs" () ((variant "PolicyArgs" (ConPos (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String") (TyCon "String")))) ())
(DTypeSig false "splitComma" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitComma" ((PVar "s")) (EApp (EVar "filterNonEmpty") (EApp (EApp (EApp (EApp (EApp (EVar "splitCommaGo") (EApp (EVar "stringToChars") (EVar "s"))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EVar "s")))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))))
(DTypeSig false "splitCommaGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "splitCommaGo" ((PVar "cs") (PVar "n") (PVar "start") (PVar "i") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (EVar "start")) (EVar "n"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "{"))) (EApp (EApp (EApp (EApp (EApp (EVar "splitCommaGo") (EVar "cs")) (EVar "n")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "}"))) (EApp (EApp (EApp (EApp (EApp (EVar "splitCommaGo") (EVar "cs")) (EVar "n")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar ","))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EBinOp "::" (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (EVar "start")) (EVar "i")) (EApp (EApp (EApp (EApp (EApp (EVar "splitCommaGo") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "splitCommaGo") (EVar "cs")) (EVar "n")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "sliceStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "sliceStr" ((PVar "cs") (PVar "a") (PVar "b")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "sliceGo") (EVar "cs")) (EVar "a")) (EVar "b")))))
(DTypeSig false "sliceGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "sliceGo" ((PVar "cs") (PVar "a") (PVar "b")) (EIf (EBinOp ">=" (EVar "a") (EVar "b")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "a")) (EVar "cs")) (EApp (EApp (EApp (EVar "sliceGo") (EVar "cs")) (EBinOp "+" (EVar "a") (ELit (LInt 1)))) (EVar "b"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "filterNonEmpty" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "filterNonEmpty" ((PList)) (EListLit))
(DFunDef false "filterNonEmpty" ((PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "==" (EVar "x") (ELit (LString ""))) (EApp (EVar "filterNonEmpty") (EVar "xs")) (EBinOp "::" (EVar "x") (EApp (EVar "filterNonEmpty") (EVar "xs")))))
(DTypeSig false "parsePolicy" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))))))
(DFunDef false "parsePolicy" ((PVar "s")) (EApp (EVar "allOk") (EApp (EApp (EVar "map") (EVar "parsePolicyTok")) (EApp (EVar "splitComma") (EVar "s")))))
(DTypeSig false "parsePolicyTok" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "EffParamTy")))))
(DFunDef false "parsePolicyTok" ((PVar "tok")) (EMatch (EApp (EApp (EApp (EVar "splitOnFirstEq") (EApp (EVar "stringToChars") (EVar "tok"))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EVar "tok")))) (ELit (LInt 0))) (arm (PCon "None") () (EApp (EVar "Ok") (ETuple (EVar "tok") (EVar "EPTop")))) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "tok"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoLet false false (PVar "label") (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (ELit (LInt 0))) (EVar "i"))) (DoLet false false (PVar "rhs") (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (DoExpr (EIf (EApp (EVar "rhsIsProduct") (EVar "rhs")) (EApp (EApp (EApp (EVar "productEntry") (EVar "tok")) (EVar "label")) (EVar "rhs")) (EIf (EApp (EVar "rhsIsSet") (EVar "rhs")) (EApp (EVar "Ok") (ETuple (EVar "label") (EApp (EVar "EPSet") (EApp (EApp (EVar "map") (EVar "unquote")) (EApp (EVar "decodeSetParam") (EVar "rhs")))))) (EApp (EVar "Ok") (ETuple (EVar "label") (EApp (EVar "EPLit") (EApp (EVar "unquote") (EVar "rhs"))))))))))))
(DTypeSig false "policyAxis" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "EffParamTy")))))
(DFunDef false "policyAxis" ((PVar "spec")) (EMatch (EApp (EApp (EApp (EVar "splitOnFirstEq") (EApp (EVar "stringToChars") (EVar "spec"))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EVar "spec")))) (ELit (LInt 0))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "axis '")) (EApp (EVar "display") (EVar "spec"))) (ELit (LString "' has no value; write `"))) (EApp (EVar "display") (EVar "spec"))) (ELit (LString "=…`, or leave the axis out for its whole domain"))))) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "spec"))) (DoLet false false (PVar "name") (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (ELit (LInt 0))) (EVar "i"))) (DoLet false false (PVar "v") (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "arrayLength") (EVar "cs")))) (DoExpr (EIf (EApp (EVar "rhsIsSet") (EVar "v")) (EApp (EVar "Ok") (ETuple (EVar "name") (EApp (EVar "EPSet") (EApp (EApp (EVar "map") (EVar "unquote")) (EApp (EVar "decodeSetParam") (EVar "v")))))) (EApp (EVar "Ok") (ETuple (EVar "name") (EApp (EVar "EPLit") (EApp (EVar "unquote") (EVar "v")))))))))))
(DTypeSig false "productEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "EffParamTy")))))))
(DFunDef false "productEntry" ((PVar "tok") (PVar "label") (PVar "rhs")) (EMatch (EApp (EVar "allOk") (EApp (EApp (EVar "map") (EVar "policyAxis")) (EApp (EVar "splitSemi") (EVar "rhs")))) (arm (PCon "Ok" (PVar "axes")) () (EApp (EVar "Ok") (ETuple (EVar "label") (EApp (EVar "EPProduct") (EVar "axes"))))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "policy entry '")) (EApp (EVar "display") (EVar "tok"))) (ELit (LString "': "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))))))
(DTypeSig false "unquote" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "unquote" ((PVar "v")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "v"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "v")) (ELit (LString "\"")))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "v")) (ELit (LString "\"")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "v")) (EVar "v")))))
(DTypeSig false "splitSemi" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitSemi" ((PVar "s")) (EApp (EApp (EApp (EApp (EVar "splitSemiGo") (EApp (EVar "stringToChars") (EVar "s"))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EVar "s")))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "splitSemiGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "splitSemiGo" ((PVar "cs") (PVar "n") (PVar "start") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (EVar "start")) (EVar "n"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar ";"))) (EBinOp "::" (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (EVar "start")) (EVar "i")) (EApp (EApp (EApp (EApp (EVar "splitSemiGo") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "splitSemiGo") (EVar "cs")) (EVar "n")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "rhsIsProduct" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "rhsIsProduct" ((PVar "rhs")) (EMatch (EApp (EApp (EApp (EVar "splitOnFirstEq") (EApp (EVar "stringToChars") (EVar "rhs"))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EVar "rhs")))) (ELit (LInt 0))) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" PWild) () (EVar "True"))))
(DTypeSig false "rhsIsSet" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "rhsIsSet" ((PVar "rhs")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "rhs"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "rhs")) (ELit (LString "{")))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "rhs")) (ELit (LString "}")))))))
(DTypeSig false "splitOnFirstEq" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "splitOnFirstEq" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "="))) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "splitOnFirstEq") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "policyLabels" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "policyLabels" ((PList)) (EListLit))
(DFunDef false "policyLabels" ((PCons (PTuple (PVar "l") (PVar "p")) (PVar "rest"))) (EBinOp "::" (EBinOp "++" (EVar "l") (EApp (EApp (EVar "effParamSurface") (EVar "quoteTok")) (EVar "p"))) (EApp (EVar "policyLabels") (EVar "rest"))))
(DTypeSig false "atomLabels" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "atomLabels" ((PVar "atoms")) (EApp (EApp (EVar "map") (EVar "renderAtom")) (EVar "atoms")))
(DTypeSig false "stubSource" (TyCon "String"))
(DFunDef false "stubSource" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "cacheGet req = \"\"\n")) (ELit (LString "cacheSet req result = ()\n")) (ELit (LString "logEvent s = putStr (stringConcat [\"   [LOG] \", s, \"\\n\"])\n")) (ELit (LString "getEnv k = None\n")) (ELit (LString "args u = []\n")) (ELit (LString "executablePath u = \"\"\n")) (ELit (LString "readFile p g = Err \"\"\n")) (ELit (LString "readFileBytes p g = Err \"\"\n")) (ELit (LString "fileExists p g = False\n")) (ELit (LString "canonicalizePath p g = p\n")) (ELit (LString "listDir p g = Err \"\"\n")) (ELit (LString "statFile p g = Err \"\"\n")) (ELit (LString "writeFile p c g = Err \"\"\n")) (ELit (LString "writeFileBytes p b g = Err \"\"\n")) (ELit (LString "appendFile p c g = Err \"\"\n")) (ELit (LString "makeDir p g = Err \"\"\n")) (ELit (LString "removeFile p g = Err \"\"\n")) (ELit (LString "rename o n gs gd = Err \"\"\n")) (ELit (LString "removeDir p g = Err \"\"\n")) (ELit (LString "runCommand cmd a = Err \"\"\n")) (ELit (LString "runCommandBatch cmd j a = []\n")) (ELit (LString "netResolve h = Err \"\"\n")) (ELit (LString "netTcpConnect h p = Err \"\"\n")) (ELit (LString "netTcpListen h p = Err \"\"\n")) (ELit (LString "netListenPort fd = Err \"\"\n")) (ELit (LString "netTcpAccept fd = Err \"\"\n")) (ELit (LString "netSend fd b = Err \"\"\n")) (ELit (LString "netRecv fd n = Err \"\"\n")) (ELit (LString "netShutdown fd how = Err \"\"\n")) (ELit (LString "netClose fd = Err \"\"\n")) (ELit (LString "netSetTimeout fd ms = Err \"\"\n")))))
(DTypeSig false "runPlugin" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "ElabResult") (TyCon "String")))))
(DFunDef false "runPlugin" ((PVar "fnName") (PVar "grants") (PTuple (PVar "coreD") (PVar "modules") PWild PWild PWild PWild)) (EBlock (DoLet false false (PVar "stubD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "stubSource")))) (DoLet false false (PTuple (PVar "coreE") (PVar "modulesE")) (EApp (EVar "mangleCtorCollisionsPair") (ETuple (EVar "coreD") (EVar "modules")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "outputRef")) (ELit (LString "")))) (DoLet false false (PVar "rootEnv") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "buildStampExterns") (ELit LUnit))) (EBinOp "++" (EVar "coreE") (EVar "stubD"))) (EVar "modulesE"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupValue") (EVar "fnName")) (EVar "rootEnv")) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "   (no '")) (EVar "fnName")) (ELit (LString "' binding in output)\n")))) (arm (PCon "Some" (PVar "fnVal")) () (EBlock (DoLet false false (PVar "sample") (ELit (LString "X-Forwarded-For: 192.168.1.1"))) (DoLet false false (PVar "granted") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "f") PWild) (EApp (EApp (EVar "apply") (EVar "f")) (EApp (EVar "VList") (EListLit))))) (EVar "fnVal")) (EApp (EApp (EVar "replicate") (EVar "grants")) (ELit LUnit)))) (DoLet false false (PVar "result") (EApp (EApp (EVar "apply") (EVar "granted")) (EApp (EVar "VString") (EVar "sample")))) (DoLet false false (PVar "logged") (EUnOp "!" (EVar "outputRef"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "logged"))) (ELit (LString "   "))) (EApp (EVar "display") (EVar "fnName"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "sample")))) (ELit (LString " = "))) (EApp (EVar "display") (EApp (EVar "ppValue") (EVar "result")))) (ELit (LString "\n"))))))))))
(DTypeSig false "lookupValue" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "lookupValue" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupValue" ((PVar "k") (PCons (PTuple (PVar "n") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "lookupValue") (EVar "k")) (EVar "rest"))))
(DData Public "EntryAnalysis" () ((variant "EntryAnalysis" (ConNamed (field "eaElab" (TyCon "ElabResult")) (field "eaSchemes" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))) (field "eaOps" (TyCon "InvocationOps")) (field "eaEntryDecls" (TyApp (TyCon "List") (TyCon "Decl"))) (field "eaAutoPrintCall" (TyApp (TyCon "Option") (TyCon "Scheme")))))) ())
(DTypeSig true "analyzeProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "EntryAnalysis")))))
(DFunDef false "analyzeProgram" ((PVar "rtD") (PVar "coreD") (PVar "modsD")) (EBlock (DoLet false false (PTuple (PVar "elaborated") (PVar "preludeSchemes") (PVar "ownSchemes")) (EApp (EApp (EApp (EVar "elaborateModulesWithSchemes") (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoLet false false (PVar "ops") (EApp (EVar "lastInvocationOps") (ELit LUnit))) (DoLet false false (PVar "autoPrintCall") (EIf (EApp (EApp (EVar "shouldAutoPrintMain") (EVar "coreD")) (EVar "modsD")) (EApp (EApp (EVar "lookupAssoc") (ELit (LString "println"))) (EVar "preludeSchemes")) (EVar "None"))) (DoExpr (ERecordCreate "EntryAnalysis" ((fa "eaElab" (EVar "elaborated")) (fa "eaSchemes" (EBinOp "++" (EVar "ownSchemes") (EVar "preludeSchemes"))) (fa "eaOps" (EVar "ops")) (fa "eaEntryDecls" (EApp (EVar "entryModuleDecls") (EVar "modsD"))) (fa "eaAutoPrintCall" (EVar "autoPrintCall")))))))
(DTypeSig false "entryModuleDecls" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "entryModuleDecls" ((PList)) (EListLit))
(DFunDef false "entryModuleDecls" ((PList (PTuple PWild (PVar "decls")))) (EVar "decls"))
(DFunDef false "entryModuleDecls" ((PCons PWild (PVar "rest"))) (EApp (EVar "entryModuleDecls") (EVar "rest")))
(DData Public "PolicyOutcome" () ((variant "PolicyAccept" (ConPos (TyCon "String") (TyFun (TyCon "Unit") (TyCon "String")))) (variant "PolicyReject" (ConPos (TyCon "String")))) ())
(DTypeSig true "runCheckPolicy" (TyFun (TyCon "EntryAnalysis") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "PolicyOutcome")))))
(DFunDef false "runCheckPolicy" ((PVar "analysis") (PVar "allowStr") (PVar "fnName")) (EMatch (EApp (EVar "parsePolicy") (EVar "allowStr")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "PolicyReject") (EBinOp "++" (EBinOp "++" (ELit (LString "rejected. ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "\n"))))) (arm (PCon "Ok" (PVar "policy")) () (EApp (EApp (EApp (EVar "policyVerdict") (EVar "policy")) (EVar "analysis")) (EVar "fnName")))))
(DTypeSig false "policyVerdict" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyFun (TyCon "EntryAnalysis") (TyFun (TyCon "String") (TyCon "PolicyOutcome")))))
(DFunDef false "policyVerdict" ((PVar "policy") (PVar "analysis") (PVar "fnName")) (EBlock (DoLet false false (PVar "schemes") (EFieldAccess (EVar "analysis") "eaSchemes")) (DoExpr (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "fnName")) (EVar "schemes")) (arm (PCon "None") () (EApp (EVar "PolicyReject") (EBinOp "++" (EBinOp "++" (ELit (LString "rejected. no '")) (EApp (EVar "display") (EVar "fnName"))) (ELit (LString "' entry found\n"))))) (arm (PCon "Some" (PVar "fnScheme")) () (EBlock (DoLet false false (PVar "fnEffects") (EApp (EApp (EVar "invocationSummary") (EFieldAccess (EVar "analysis") "eaOps")) (EVar "fnScheme"))) (DoExpr (EMatch (EApp (EApp (EVar "policyRefusals") (EVar "fnEffects")) (EVar "policy")) (arm (PCon "PolicyAdmitted") () (EBlock (DoLet false false (PVar "effStr") (EIf (EApp (EVar "listIsEmpty") (EVar "fnEffects")) (ELit (LString "pure")) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EVar "atomLabels") (EVar "fnEffects")))) (ELit (LString ">"))))) (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "accepted. ")) (EApp (EVar "display") (EVar "fnName"))) (ELit (LString " requires only "))) (EApp (EVar "display") (EVar "effStr"))) (ELit (LString "\n")))) (DoLet false false (PVar "pluginOutput") (ELam (PWild) (EIf (EApp (EVar "takesAndReturnsString") (EVar "fnScheme")) (EApp (EApp (EApp (EVar "runPlugin") (EVar "fnName")) (EApp (EApp (EVar "bindingGrantArity") (EVar "fnName")) (EVar "fnScheme"))) (EFieldAccess (EVar "analysis") "eaElab")) (EBinOp "++" (EBinOp "++" (ELit (LString "   no sample run: '")) (EApp (EVar "display") (EVar "fnName"))) (ELit (LString "' is not a String -> String entry\n")))))) (DoExpr (EApp (EApp (EVar "PolicyAccept") (EVar "header")) (EVar "pluginOutput"))))) (arm (PCon "PolicyRefused" (PVar "forbidden") (PVar "lines")) () (EBlock (DoLet false false (PVar "callGraph") (EApp (EVar "buildCallGraph") (EFieldAccess (EVar "analysis") "eaEntryDecls"))) (DoLet false false (PVar "effTable") (EApp (EVar "fnEffectsTable") (EVar "schemes"))) (DoLet false false (PVar "chain") (EApp (EApp (EApp (EApp (EVar "viaChain") (EVar "callGraph")) (EVar "effTable")) (EVar "fnName")) (EApp (EVar "firstOf") (EVar "forbidden")))) (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "rejected. ")) (EApp (EVar "display") (EVar "fnName"))) (ELit (LString " requires <"))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EVar "atomLabels") (EVar "fnEffects"))))) (ELit (LString ">. Not permitted by policy {"))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EVar "policyLabels") (EVar "policy"))))) (ELit (LString "}\n")))) (DoLet false false (PVar "via") (EBinOp "++" (EBinOp "++" (ELit (LString "   reached via: ")) (EApp (EApp (EVar "joinWith") (ELit (LString " → "))) (EVar "chain"))) (ELit (LString "\n")))) (DoExpr (EApp (EVar "PolicyReject") (EBinOp "++" (EBinOp "++" (EVar "header") (EVar "via")) (EApp (EVar "stringConcat") (EVar "lines")))))))))))))))
(DTypeSig false "takesAndReturnsString" (TyFun (TyCon "Scheme") (TyCon "Bool")))
(DFunDef false "takesAndReturnsString" ((PCon "Forall" PWild PWild PWild PWild PWild (PVar "mono"))) (EMatch (EApp (EVar "normalize") (EVar "mono")) (arm (PCon "TFun" (PVar "arg") PWild (PVar "res")) () (EBinOp "&&" (EApp (EVar "isStringCon") (EApp (EVar "normalize") (EVar "arg"))) (EApp (EVar "isStringCon") (EApp (EVar "normalize") (EVar "res"))))) (arm PWild () (EVar "False"))))
(DTypeSig false "isStringCon" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "isStringCon" ((PCon "TCon" (PLit (LString "String")) PWild)) (EVar "True"))
(DFunDef false "isStringCon" ((PCon "TQual" (PVar "t") PWild)) (EApp (EVar "isStringCon") (EApp (EVar "normalize") (EVar "t"))))
(DFunDef false "isStringCon" (PWild) (EVar "False"))
(DTypeSig false "firstOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "firstOf" ((PList)) (ELit (LString "")))
(DFunDef false "firstOf" ((PCons (PVar "x") PWild)) (EVar "x"))
(DTypeSig false "listIsEmpty" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "listIsEmpty" ((PList)) (EVar "True"))
(DFunDef false "listIsEmpty" (PWild) (EVar "False"))
(DTypeSig false "atomToToml" (TyFun (TyFun (TyCon "Atom") (TyCon "String")) (TyFun (TyCon "Atom") (TyCon "String"))))
(DFunDef false "atomToToml" ((PVar "keyOf") (PVar "a")) (EBlock (DoLet false false (PVar "label") (EApp (EVar "keyOf") (EVar "a"))) (DoExpr (EMatch (EApp (EVar "authConsts") (EApp (EVar "atomAuth") (EVar "a"))) (arm (PCon "Some" (PVar "ps")) ((GBool (EApp (EApp (EVar "anyList") (EVar "pathClimbs")) (EVar "ps")))) (EBinOp "++" (EVar "label") (ELit (LString " = true")))) (arm (PCon "Some" (PList (PVar "p"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "label"))) (ELit (LString " = "))) (EApp (EVar "display") (EApp (EVar "paramToml") (EVar "p")))) (ELit (LString "")))) (arm (PCon "Some" (PAs "ps" (PCons PWild (PCons PWild PWild)))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "label"))) (ELit (LString " = ["))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "paramToml")) (EVar "ps"))))) (ELit (LString "]")))) (arm PWild () (EIf (EApp (EVar "authHasVars") (EApp (EVar "atomAuth") (EVar "a"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "label"))) (ELit (LString " = true  # unresolved: "))) (EApp (EVar "display") (EApp (EVar "unresolvedWhy") (EVar "a")))) (ELit (LString ""))) (EBinOp "++" (EVar "label") (ELit (LString " = true")))))))))
(DTypeSig false "paramToml" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "paramToml" ((PVar "p")) (EMatch (EApp (EVar "canonParam") (EVar "p")) (arm (PCon "PPrefix" (PCon "Some" (PVar "s"))) () (EApp (EVar "tomlQuote") (EVar "s"))) (arm (PCon "PPath" (PCon "Some" (PVar "s"))) () (EApp (EVar "tomlQuote") (EApp (EVar "pathSpelling") (EVar "s")))) (arm (PCon "PSet" (PCon "Some" (PVar "xs"))) () (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "tomlQuote")) (EVar "xs"))))) (ELit (LString "]")))) (arm (PCon "PProduct" (PVar "ax")) ((GBool (EApp (EVar "not") (EApp (EVar "isSubTop") (EApp (EVar "PProduct") (EVar "ax")))))) (EBinOp "++" (EBinOp "++" (ELit (LString "{ ")) (EApp (EVar "display") (EApp (EVar "productTomlInline") (EVar "ax")))) (ELit (LString " }")))) (arm PWild () (ELit (LString "true")))))
(DTypeSig false "productTomlInline" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "String")))
(DFunDef false "productTomlInline" ((PVar "ax")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "axisToToml")) (EApp (EApp (EVar "filterList") (ELam ((PVar "a")) (EApp (EVar "not") (EApp (EVar "isSubTop") (EApp (EVar "snd") (EVar "a")))))) (EVar "ax")))))
(DTypeSig false "axisToToml" (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyCon "String")))
(DFunDef false "axisToToml" ((PTuple (PVar "name") (PCon "PPrefix" (PCon "Some" (PVar "s"))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "lowerFirst") (EVar "name")))) (ELit (LString " = "))) (EApp (EVar "display") (EApp (EVar "tomlQuote") (EVar "s")))) (ELit (LString ""))))
(DFunDef false "axisToToml" ((PTuple (PVar "name") (PCon "PSet" (PCon "Some" (PVar "xs"))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "lowerFirst") (EVar "name")))) (ELit (LString " = ["))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "tomlQuote")) (EVar "xs"))))) (ELit (LString "]"))))
(DFunDef false "axisToToml" ((PTuple (PVar "name") PWild)) (EBinOp "++" (EApp (EVar "lowerFirst") (EVar "name")) (ELit (LString " = true"))))
(DTypeSig false "quoteTok" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "quoteTok" ((PVar "s")) (EApp (EVar "escStr") (EVar "s")))
(DTypeSig false "tomlQuote" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "tomlQuote" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "tomlChars") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))))) (ELit (LString "\""))))
(DTypeSig false "tomlChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tomlChars" ((PVar "cs") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "tomlChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EVar "tomlChars") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tomlChar" (TyFun (TyCon "Char") (TyCon "String")))
(DFunDef false "tomlChar" ((PVar "c")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\\"))) (ELit (LString "\\\\")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\""))) (ELit (LString "\\\"")) (EIf (EBinOp "||" (EBinOp "<" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 32))) (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 127)))) (EBinOp "++" (EBinOp "++" (ELit (LString "\\u00")) (EApp (EVar "display") (EApp (EVar "escOneHex2") (EApp (EVar "charCode") (EVar "c"))))) (ELit (LString ""))) (EIf (EVar "otherwise") (EApp (EVar "charToStr") (EVar "c")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "lowerFirst" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "lowerFirst" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EVar "s") (EBinOp "++" (EApp (EVar "toLower") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EVar "n")) (EVar "s")))))))
(DTypeSig true "manifestToml" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "manifestToml" ((PList)) (ELit (LString "[package.capabilities]\n")))
(DFunDef false "manifestToml" ((PVar "atoms")) (EBlock (DoLet false false (PVar "lines") (EApp (EApp (EVar "map") (EApp (EVar "atomToToml") (EApp (EVar "manifestKey") (EVar "atoms")))) (EVar "atoms"))) (DoExpr (EBinOp "++" (ELit (LString "[package.capabilities]\n")) (EApp (EVar "joinTomlLines") (EVar "lines"))))))
(DTypeSig true "manifestKey" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyCon "Atom") (TyCon "String"))))
(DFunDef false "manifestKey" ((PVar "atoms") (PVar "a")) (EIf (EApp (EApp (EVar "labelCollides") (EVar "atoms")) (EApp (EVar "atomLabel") (EVar "a"))) (EApp (EVar "qualifiedKey") (EVar "a")) (EApp (EVar "atomLabel") (EVar "a"))))
(DTypeSig false "labelCollides" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "labelCollides" ((PVar "atoms") (PVar "name")) (EBinOp ">" (EApp (EVar "listLen") (EApp (EVar "sortUniqS") (EApp (EApp (EVar "map") (EVar "atomKey")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EBinOp "==" (EApp (EVar "atomLabel") (EVar "b")) (EVar "name")))) (EVar "atoms"))))) (ELit (LInt 1))))
(DTypeSig true "qualifiedKey" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "qualifiedKey" ((PVar "a")) (EApp (EVar "EP.qualifiedKey") (EVar "a")))
(DTypeSig true "unresolvedWhy" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "unresolvedWhy" ((PVar "a")) (EApp (EVar "EP.unresolvedWhy") (EVar "a")))
(DTypeSig false "joinTomlLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinTomlLines" ((PList)) (ELit (LString "")))
(DFunDef false "joinTomlLines" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EVar "joinTomlLines") (EVar "xs")))) (ELit (LString ""))))
(DData Public "ManifestArgs" () ((variant "ManifestArgs" (ConPos (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String")))) ())
(DTypeSig true "runManifest" (TyFun (TyCon "EntryAnalysis") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "runManifest" ((PVar "analysis") (PVar "fnName")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "fnName")) (EFieldAccess (EVar "analysis") "eaSchemes")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "no '")) (EApp (EVar "display") (EVar "fnName"))) (ELit (LString "' entry found"))))) (arm (PCon "Some" (PVar "sch")) () (EApp (EVar "Ok") (EApp (EVar "manifestToml") (EApp (EApp (EVar "invocationSummary") (EFieldAccess (EVar "analysis") "eaOps")) (EVar "sch")))))))
(DTypeSig true "manifestToAllowStr" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "manifestToAllowStr" ((PVar "atoms")) (EBlock (DoLet false false (PVar "toks") (EApp (EApp (EVar "flatMap") (EVar "atomToAllowToks")) (EVar "atoms"))) (DoExpr (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "toks")))))
(DTypeSig false "atomToAllowToks" (TyFun (TyCon "Atom") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "atomToAllowToks" ((PVar "a")) (EBlock (DoLet false false (PVar "label") (EApp (EVar "atomLabel") (EVar "a"))) (DoExpr (EMatch (EApp (EVar "authConsts") (EApp (EVar "atomAuth") (EVar "a"))) (arm (PCon "Some" (PVar "ps")) ((GBool (EApp (EApp (EVar "anyList") (EVar "pathClimbs")) (EVar "ps")))) (EListLit (EVar "label"))) (arm (PCon "Some" (PAs "ps" (PCons PWild PWild))) () (EApp (EApp (EVar "map") (EApp (EVar "paramAllowTok") (EVar "label"))) (EVar "ps"))) (arm PWild () (EListLit (EVar "label")))))))
(DTypeSig false "paramAllowTok" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyCon "String"))))
(DFunDef false "paramAllowTok" ((PVar "label") (PVar "p")) (EMatch (EApp (EVar "canonParam") (EVar "p")) (arm (PCon "PPrefix" (PCon "Some" (PVar "s"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "label"))) (ELit (LString "="))) (EApp (EVar "display") (EVar "s"))) (ELit (LString "")))) (arm (PCon "PPath" (PCon "Some" (PVar "s"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "label"))) (ELit (LString "="))) (EApp (EVar "display") (EApp (EVar "pathSpelling") (EVar "s")))) (ELit (LString "")))) (arm (PCon "PSet" (PCon "Some" (PVar "xs"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "label"))) (ELit (LString "={"))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "xs")))) (ELit (LString "}")))) (arm (PCon "PProduct" (PVar "ax")) ((GBool (EApp (EVar "not") (EApp (EVar "isSubTop") (EApp (EVar "PProduct") (EVar "ax")))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "label"))) (ELit (LString "="))) (EApp (EVar "display") (EApp (EVar "productAllowRhs") (EVar "ax")))) (ELit (LString "")))) (arm PWild () (EVar "label"))))
(DTypeSig false "productAllowRhs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "String")))
(DFunDef false "productAllowRhs" ((PVar "ax")) (EApp (EVar "joinSemiTok") (EApp (EApp (EVar "flatMap") (EVar "axisToAllow")) (EVar "ax"))))
(DTypeSig false "axisToAllow" (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "axisToAllow" ((PTuple (PVar "name") (PCon "PPrefix" (PCon "Some" (PVar "s"))))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "=\""))) (EApp (EVar "display") (EVar "s"))) (ELit (LString "\"")))))
(DFunDef false "axisToAllow" ((PTuple (PVar "name") (PCon "PSet" (PCon "Some" (PVar "xs"))))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "={"))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "xs")))) (ELit (LString "}")))))
(DFunDef false "axisToAllow" (PWild) (EListLit))
(DTypeSig false "joinSemiTok" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinSemiTok" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString ";"))) (EVar "xs")))
# MARK
(DUse false (UseGroup ("types" "effect_domain") ((mem "canonParam" false) (mem "drender" false) (mem "isSubTop" false) (mem "Param" true) (mem "pathClimbs" false) (mem "pathSpelling" false))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "authHasVars" false) (mem "authConsts" false))))
(DUse false (UseAlias ("types" "effect_policy") "EP"))
(DUse false (UseGroup ("types" "effect_policy") ((mem "PolicyVerdict" true) (mem "policyRefusals" false) (mem "buildCallGraph" false) (mem "fnEffectsTable" false) (mem "viaChain" false) (mem "allOk" false))))
(DUse false (UseGroup ("types" "effect_invocation") ((mem "invocationSummary" false) (mem "InvocationOps" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "atomKey" false) (mem "atomLabel" false) (mem "atomAuth" false) (mem "renderAtom" false) (mem "Atom" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "EffParamTy" true) (mem "effParamSurface" false) (mem "Decl" true))))
(DUse false (UseGroup ("driver" "main_autoprint") ((mem "shouldAutoPrintMain" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" true) (mem "Mono" true) (mem "normalize" false))))
(DUse false (UseGroup ("types" "private_mangle") ((mem "mangleCtorCollisionsPair" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "ElabResult" false) (mem "elaborateModulesWithSchemes" false) (mem "lastInvocationOps" false) (mem "decodeSetParam" false) (mem "bindingGrantArity" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" true) (mem "evalModulesRootEnvWith" false) (mem "buildStampExterns" false) (mem "apply" false) (mem "outputRef" false) (mem "ppValue" false))))
(DUse false (UseGroup ("support" "util") ((mem "sortUniqS" false) (mem "joinWith" false) (mem "escStr" false) (mem "lookupAssoc" false) (mem "filterList" false) (mem "listLen" false) (mem "escOneHex2" false) (mem "anyList" false))))
(DUse false (UseGroup ("string") ((mem "toLower" false))))
(DUse false (UseGroup ("list") ((mem "replicate" false))))
(DData Public "PolicyArgs" () ((variant "PolicyArgs" (ConPos (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String") (TyCon "String")))) ())
(DTypeSig false "splitComma" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitComma" ((PVar "s")) (EApp (EVar "filterNonEmpty") (EApp (EApp (EApp (EApp (EApp (EVar "splitCommaGo") (EApp (EVar "stringToChars") (EVar "s"))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EVar "s")))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))))
(DTypeSig false "splitCommaGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "splitCommaGo" ((PVar "cs") (PVar "n") (PVar "start") (PVar "i") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (EVar "start")) (EVar "n"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "{"))) (EApp (EApp (EApp (EApp (EApp (EVar "splitCommaGo") (EVar "cs")) (EVar "n")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "}"))) (EApp (EApp (EApp (EApp (EApp (EVar "splitCommaGo") (EVar "cs")) (EVar "n")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar ","))) (EBinOp "==" (EVar "depth") (ELit (LInt 0)))) (EBinOp "::" (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (EVar "start")) (EVar "i")) (EApp (EApp (EApp (EApp (EApp (EVar "splitCommaGo") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "splitCommaGo") (EVar "cs")) (EVar "n")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "sliceStr" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "sliceStr" ((PVar "cs") (PVar "a") (PVar "b")) (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EApp (EApp (EVar "sliceGo") (EVar "cs")) (EVar "a")) (EVar "b")))))
(DTypeSig false "sliceGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char"))))))
(DFunDef false "sliceGo" ((PVar "cs") (PVar "a") (PVar "b")) (EIf (EBinOp ">=" (EVar "a") (EVar "b")) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "a")) (EVar "cs")) (EApp (EApp (EApp (EVar "sliceGo") (EVar "cs")) (EBinOp "+" (EVar "a") (ELit (LInt 1)))) (EVar "b"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "filterNonEmpty" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "filterNonEmpty" ((PList)) (EListLit))
(DFunDef false "filterNonEmpty" ((PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "==" (EVar "x") (ELit (LString ""))) (EApp (EVar "filterNonEmpty") (EVar "xs")) (EBinOp "::" (EVar "x") (EApp (EVar "filterNonEmpty") (EVar "xs")))))
(DTypeSig false "parsePolicy" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))))))
(DFunDef false "parsePolicy" ((PVar "s")) (EApp (EVar "allOk") (EApp (EApp (EMethodRef "map") (EVar "parsePolicyTok")) (EApp (EVar "splitComma") (EVar "s")))))
(DTypeSig false "parsePolicyTok" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "EffParamTy")))))
(DFunDef false "parsePolicyTok" ((PVar "tok")) (EMatch (EApp (EApp (EApp (EVar "splitOnFirstEq") (EApp (EVar "stringToChars") (EVar "tok"))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EVar "tok")))) (ELit (LInt 0))) (arm (PCon "None") () (EApp (EVar "Ok") (ETuple (EVar "tok") (EVar "EPTop")))) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "tok"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoLet false false (PVar "label") (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (ELit (LInt 0))) (EVar "i"))) (DoLet false false (PVar "rhs") (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n"))) (DoExpr (EIf (EApp (EVar "rhsIsProduct") (EVar "rhs")) (EApp (EApp (EApp (EVar "productEntry") (EVar "tok")) (EVar "label")) (EVar "rhs")) (EIf (EApp (EVar "rhsIsSet") (EVar "rhs")) (EApp (EVar "Ok") (ETuple (EVar "label") (EApp (EVar "EPSet") (EApp (EApp (EMethodRef "map") (EVar "unquote")) (EApp (EVar "decodeSetParam") (EVar "rhs")))))) (EApp (EVar "Ok") (ETuple (EVar "label") (EApp (EVar "EPLit") (EApp (EVar "unquote") (EVar "rhs"))))))))))))
(DTypeSig false "policyAxis" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "EffParamTy")))))
(DFunDef false "policyAxis" ((PVar "spec")) (EMatch (EApp (EApp (EApp (EVar "splitOnFirstEq") (EApp (EVar "stringToChars") (EVar "spec"))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EVar "spec")))) (ELit (LInt 0))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "axis '")) (EApp (EMethodRef "display") (EVar "spec"))) (ELit (LString "' has no value; write `"))) (EApp (EMethodRef "display") (EVar "spec"))) (ELit (LString "=…`, or leave the axis out for its whole domain"))))) (arm (PCon "Some" (PVar "i")) () (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "spec"))) (DoLet false false (PVar "name") (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (ELit (LInt 0))) (EVar "i"))) (DoLet false false (PVar "v") (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "arrayLength") (EVar "cs")))) (DoExpr (EIf (EApp (EVar "rhsIsSet") (EVar "v")) (EApp (EVar "Ok") (ETuple (EVar "name") (EApp (EVar "EPSet") (EApp (EApp (EMethodRef "map") (EVar "unquote")) (EApp (EVar "decodeSetParam") (EVar "v")))))) (EApp (EVar "Ok") (ETuple (EVar "name") (EApp (EVar "EPLit") (EApp (EVar "unquote") (EVar "v")))))))))))
(DTypeSig false "productEntry" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "EffParamTy")))))))
(DFunDef false "productEntry" ((PVar "tok") (PVar "label") (PVar "rhs")) (EMatch (EApp (EVar "allOk") (EApp (EApp (EMethodRef "map") (EVar "policyAxis")) (EApp (EVar "splitSemi") (EVar "rhs")))) (arm (PCon "Ok" (PVar "axes")) () (EApp (EVar "Ok") (ETuple (EVar "label") (EApp (EVar "EPProduct") (EVar "axes"))))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "policy entry '")) (EApp (EMethodRef "display") (EVar "tok"))) (ELit (LString "': "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))))))
(DTypeSig false "unquote" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "unquote" ((PVar "v")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "v"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "v")) (ELit (LString "\"")))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "v")) (ELit (LString "\"")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "v")) (EVar "v")))))
(DTypeSig false "splitSemi" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "splitSemi" ((PVar "s")) (EApp (EApp (EApp (EApp (EVar "splitSemiGo") (EApp (EVar "stringToChars") (EVar "s"))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EVar "s")))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "splitSemiGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "splitSemiGo" ((PVar "cs") (PVar "n") (PVar "start") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EListLit (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (EVar "start")) (EVar "n"))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar ";"))) (EBinOp "::" (EApp (EApp (EApp (EVar "sliceStr") (EVar "cs")) (EVar "start")) (EVar "i")) (EApp (EApp (EApp (EApp (EVar "splitSemiGo") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "splitSemiGo") (EVar "cs")) (EVar "n")) (EVar "start")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "rhsIsProduct" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "rhsIsProduct" ((PVar "rhs")) (EMatch (EApp (EApp (EApp (EVar "splitOnFirstEq") (EApp (EVar "stringToChars") (EVar "rhs"))) (EApp (EVar "arrayLength") (EApp (EVar "stringToChars") (EVar "rhs")))) (ELit (LInt 0))) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" PWild) () (EVar "True"))))
(DTypeSig false "rhsIsSet" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "rhsIsSet" ((PVar "rhs")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "rhs"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "rhs")) (ELit (LString "{")))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "rhs")) (ELit (LString "}")))))))
(DTypeSig false "splitOnFirstEq" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "splitOnFirstEq" ((PVar "cs") (PVar "n") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "None") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "="))) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "splitOnFirstEq") (EVar "cs")) (EVar "n")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "policyLabels" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "policyLabels" ((PList)) (EListLit))
(DFunDef false "policyLabels" ((PCons (PTuple (PVar "l") (PVar "p")) (PVar "rest"))) (EBinOp "::" (EBinOp "++" (EVar "l") (EApp (EApp (EVar "effParamSurface") (EVar "quoteTok")) (EVar "p"))) (EApp (EVar "policyLabels") (EVar "rest"))))
(DTypeSig false "atomLabels" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "atomLabels" ((PVar "atoms")) (EApp (EApp (EMethodRef "map") (EVar "renderAtom")) (EVar "atoms")))
(DTypeSig false "stubSource" (TyCon "String"))
(DFunDef false "stubSource" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "cacheGet req = \"\"\n")) (ELit (LString "cacheSet req result = ()\n")) (ELit (LString "logEvent s = putStr (stringConcat [\"   [LOG] \", s, \"\\n\"])\n")) (ELit (LString "getEnv k = None\n")) (ELit (LString "args u = []\n")) (ELit (LString "executablePath u = \"\"\n")) (ELit (LString "readFile p g = Err \"\"\n")) (ELit (LString "readFileBytes p g = Err \"\"\n")) (ELit (LString "fileExists p g = False\n")) (ELit (LString "canonicalizePath p g = p\n")) (ELit (LString "listDir p g = Err \"\"\n")) (ELit (LString "statFile p g = Err \"\"\n")) (ELit (LString "writeFile p c g = Err \"\"\n")) (ELit (LString "writeFileBytes p b g = Err \"\"\n")) (ELit (LString "appendFile p c g = Err \"\"\n")) (ELit (LString "makeDir p g = Err \"\"\n")) (ELit (LString "removeFile p g = Err \"\"\n")) (ELit (LString "rename o n gs gd = Err \"\"\n")) (ELit (LString "removeDir p g = Err \"\"\n")) (ELit (LString "runCommand cmd a = Err \"\"\n")) (ELit (LString "runCommandBatch cmd j a = []\n")) (ELit (LString "netResolve h = Err \"\"\n")) (ELit (LString "netTcpConnect h p = Err \"\"\n")) (ELit (LString "netTcpListen h p = Err \"\"\n")) (ELit (LString "netListenPort fd = Err \"\"\n")) (ELit (LString "netTcpAccept fd = Err \"\"\n")) (ELit (LString "netSend fd b = Err \"\"\n")) (ELit (LString "netRecv fd n = Err \"\"\n")) (ELit (LString "netShutdown fd how = Err \"\"\n")) (ELit (LString "netClose fd = Err \"\"\n")) (ELit (LString "netSetTimeout fd ms = Err \"\"\n")))))
(DTypeSig false "runPlugin" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "ElabResult") (TyCon "String")))))
(DFunDef false "runPlugin" ((PVar "fnName") (PVar "grants") (PTuple (PVar "coreD") (PVar "modules") PWild PWild PWild PWild)) (EBlock (DoLet false false (PVar "stubD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "stubSource")))) (DoLet false false (PTuple (PVar "coreE") (PVar "modulesE")) (EApp (EVar "mangleCtorCollisionsPair") (ETuple (EVar "coreD") (EVar "modules")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "outputRef")) (ELit (LString "")))) (DoLet false false (PVar "rootEnv") (EApp (EApp (EApp (EVar "evalModulesRootEnvWith") (EApp (EVar "buildStampExterns") (ELit LUnit))) (EBinOp "++" (EVar "coreE") (EVar "stubD"))) (EVar "modulesE"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupValue") (EVar "fnName")) (EVar "rootEnv")) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "   (no '")) (EVar "fnName")) (ELit (LString "' binding in output)\n")))) (arm (PCon "Some" (PVar "fnVal")) () (EBlock (DoLet false false (PVar "sample") (ELit (LString "X-Forwarded-For: 192.168.1.1"))) (DoLet false false (PVar "granted") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "f") PWild) (EApp (EApp (EVar "apply") (EVar "f")) (EApp (EVar "VList") (EListLit))))) (EVar "fnVal")) (EApp (EApp (EVar "replicate") (EVar "grants")) (ELit LUnit)))) (DoLet false false (PVar "result") (EApp (EApp (EVar "apply") (EVar "granted")) (EApp (EVar "VString") (EVar "sample")))) (DoLet false false (PVar "logged") (EUnOp "!" (EVar "outputRef"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "logged"))) (ELit (LString "   "))) (EApp (EMethodRef "display") (EVar "fnName"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "sample")))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EApp (EVar "ppValue") (EVar "result")))) (ELit (LString "\n"))))))))))
(DTypeSig false "lookupValue" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "lookupValue" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupValue" ((PVar "k") (PCons (PTuple (PVar "n") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "lookupValue") (EVar "k")) (EVar "rest"))))
(DData Public "EntryAnalysis" () ((variant "EntryAnalysis" (ConNamed (field "eaElab" (TyCon "ElabResult")) (field "eaSchemes" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))) (field "eaOps" (TyCon "InvocationOps")) (field "eaEntryDecls" (TyApp (TyCon "List") (TyCon "Decl"))) (field "eaAutoPrintCall" (TyApp (TyCon "Option") (TyCon "Scheme")))))) ())
(DTypeSig true "analyzeProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "EntryAnalysis")))))
(DFunDef false "analyzeProgram" ((PVar "rtD") (PVar "coreD") (PVar "modsD")) (EBlock (DoLet false false (PTuple (PVar "elaborated") (PVar "preludeSchemes") (PVar "ownSchemes")) (EApp (EApp (EApp (EVar "elaborateModulesWithSchemes") (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoLet false false (PVar "ops") (EApp (EVar "lastInvocationOps") (ELit LUnit))) (DoLet false false (PVar "autoPrintCall") (EIf (EApp (EApp (EVar "shouldAutoPrintMain") (EVar "coreD")) (EVar "modsD")) (EApp (EApp (EVar "lookupAssoc") (ELit (LString "println"))) (EVar "preludeSchemes")) (EVar "None"))) (DoExpr (ERecordCreate "EntryAnalysis" ((fa "eaElab" (EVar "elaborated")) (fa "eaSchemes" (EBinOp "++" (EVar "ownSchemes") (EVar "preludeSchemes"))) (fa "eaOps" (EVar "ops")) (fa "eaEntryDecls" (EApp (EVar "entryModuleDecls") (EVar "modsD"))) (fa "eaAutoPrintCall" (EVar "autoPrintCall")))))))
(DTypeSig false "entryModuleDecls" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "entryModuleDecls" ((PList)) (EListLit))
(DFunDef false "entryModuleDecls" ((PList (PTuple PWild (PVar "decls")))) (EVar "decls"))
(DFunDef false "entryModuleDecls" ((PCons PWild (PVar "rest"))) (EApp (EVar "entryModuleDecls") (EVar "rest")))
(DData Public "PolicyOutcome" () ((variant "PolicyAccept" (ConPos (TyCon "String") (TyFun (TyCon "Unit") (TyCon "String")))) (variant "PolicyReject" (ConPos (TyCon "String")))) ())
(DTypeSig true "runCheckPolicy" (TyFun (TyCon "EntryAnalysis") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "PolicyOutcome")))))
(DFunDef false "runCheckPolicy" ((PVar "analysis") (PVar "allowStr") (PVar "fnName")) (EMatch (EApp (EVar "parsePolicy") (EVar "allowStr")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "PolicyReject") (EBinOp "++" (EBinOp "++" (ELit (LString "rejected. ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "\n"))))) (arm (PCon "Ok" (PVar "policy")) () (EApp (EApp (EApp (EVar "policyVerdict") (EVar "policy")) (EVar "analysis")) (EVar "fnName")))))
(DTypeSig false "policyVerdict" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyFun (TyCon "EntryAnalysis") (TyFun (TyCon "String") (TyCon "PolicyOutcome")))))
(DFunDef false "policyVerdict" ((PVar "policy") (PVar "analysis") (PVar "fnName")) (EBlock (DoLet false false (PVar "schemes") (EFieldAccess (EVar "analysis") "eaSchemes")) (DoExpr (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "fnName")) (EVar "schemes")) (arm (PCon "None") () (EApp (EVar "PolicyReject") (EBinOp "++" (EBinOp "++" (ELit (LString "rejected. no '")) (EApp (EMethodRef "display") (EVar "fnName"))) (ELit (LString "' entry found\n"))))) (arm (PCon "Some" (PVar "fnScheme")) () (EBlock (DoLet false false (PVar "fnEffects") (EApp (EApp (EVar "invocationSummary") (EFieldAccess (EVar "analysis") "eaOps")) (EVar "fnScheme"))) (DoExpr (EMatch (EApp (EApp (EVar "policyRefusals") (EVar "fnEffects")) (EVar "policy")) (arm (PCon "PolicyAdmitted") () (EBlock (DoLet false false (PVar "effStr") (EIf (EApp (EVar "listIsEmpty") (EVar "fnEffects")) (ELit (LString "pure")) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EVar "atomLabels") (EVar "fnEffects")))) (ELit (LString ">"))))) (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "accepted. ")) (EApp (EMethodRef "display") (EVar "fnName"))) (ELit (LString " requires only "))) (EApp (EMethodRef "display") (EVar "effStr"))) (ELit (LString "\n")))) (DoLet false false (PVar "pluginOutput") (ELam (PWild) (EIf (EApp (EVar "takesAndReturnsString") (EVar "fnScheme")) (EApp (EApp (EApp (EVar "runPlugin") (EVar "fnName")) (EApp (EApp (EVar "bindingGrantArity") (EVar "fnName")) (EVar "fnScheme"))) (EFieldAccess (EVar "analysis") "eaElab")) (EBinOp "++" (EBinOp "++" (ELit (LString "   no sample run: '")) (EApp (EMethodRef "display") (EVar "fnName"))) (ELit (LString "' is not a String -> String entry\n")))))) (DoExpr (EApp (EApp (EVar "PolicyAccept") (EVar "header")) (EVar "pluginOutput"))))) (arm (PCon "PolicyRefused" (PVar "forbidden") (PVar "lines")) () (EBlock (DoLet false false (PVar "callGraph") (EApp (EVar "buildCallGraph") (EFieldAccess (EVar "analysis") "eaEntryDecls"))) (DoLet false false (PVar "effTable") (EApp (EVar "fnEffectsTable") (EVar "schemes"))) (DoLet false false (PVar "chain") (EApp (EApp (EApp (EApp (EVar "viaChain") (EVar "callGraph")) (EVar "effTable")) (EVar "fnName")) (EApp (EVar "firstOf") (EVar "forbidden")))) (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "rejected. ")) (EApp (EMethodRef "display") (EVar "fnName"))) (ELit (LString " requires <"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EVar "atomLabels") (EVar "fnEffects"))))) (ELit (LString ">. Not permitted by policy {"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EVar "policyLabels") (EVar "policy"))))) (ELit (LString "}\n")))) (DoLet false false (PVar "via") (EBinOp "++" (EBinOp "++" (ELit (LString "   reached via: ")) (EApp (EApp (EVar "joinWith") (ELit (LString " → "))) (EVar "chain"))) (ELit (LString "\n")))) (DoExpr (EApp (EVar "PolicyReject") (EBinOp "++" (EBinOp "++" (EVar "header") (EVar "via")) (EApp (EVar "stringConcat") (EVar "lines")))))))))))))))
(DTypeSig false "takesAndReturnsString" (TyFun (TyCon "Scheme") (TyCon "Bool")))
(DFunDef false "takesAndReturnsString" ((PCon "Forall" PWild PWild PWild PWild PWild (PVar "mono"))) (EMatch (EApp (EVar "normalize") (EVar "mono")) (arm (PCon "TFun" (PVar "arg") PWild (PVar "res")) () (EBinOp "&&" (EApp (EVar "isStringCon") (EApp (EVar "normalize") (EVar "arg"))) (EApp (EVar "isStringCon") (EApp (EVar "normalize") (EVar "res"))))) (arm PWild () (EVar "False"))))
(DTypeSig false "isStringCon" (TyFun (TyCon "Mono") (TyCon "Bool")))
(DFunDef false "isStringCon" ((PCon "TCon" (PLit (LString "String")) PWild)) (EVar "True"))
(DFunDef false "isStringCon" ((PCon "TQual" (PVar "t") PWild)) (EApp (EVar "isStringCon") (EApp (EVar "normalize") (EVar "t"))))
(DFunDef false "isStringCon" (PWild) (EVar "False"))
(DTypeSig false "firstOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "firstOf" ((PList)) (ELit (LString "")))
(DFunDef false "firstOf" ((PCons (PVar "x") PWild)) (EVar "x"))
(DTypeSig false "listIsEmpty" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool")))
(DFunDef false "listIsEmpty" ((PList)) (EVar "True"))
(DFunDef false "listIsEmpty" (PWild) (EVar "False"))
(DTypeSig false "atomToToml" (TyFun (TyFun (TyCon "Atom") (TyCon "String")) (TyFun (TyCon "Atom") (TyCon "String"))))
(DFunDef false "atomToToml" ((PVar "keyOf") (PVar "a")) (EBlock (DoLet false false (PVar "label") (EApp (EVar "keyOf") (EVar "a"))) (DoExpr (EMatch (EApp (EVar "authConsts") (EApp (EVar "atomAuth") (EVar "a"))) (arm (PCon "Some" (PVar "ps")) ((GBool (EApp (EApp (EVar "anyList") (EVar "pathClimbs")) (EVar "ps")))) (EBinOp "++" (EVar "label") (ELit (LString " = true")))) (arm (PCon "Some" (PList (PVar "p"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EApp (EVar "paramToml") (EVar "p")))) (ELit (LString "")))) (arm (PCon "Some" (PAs "ps" (PCons PWild (PCons PWild PWild)))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString " = ["))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "paramToml")) (EVar "ps"))))) (ELit (LString "]")))) (arm PWild () (EIf (EApp (EVar "authHasVars") (EApp (EVar "atomAuth") (EVar "a"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString " = true  # unresolved: "))) (EApp (EMethodRef "display") (EApp (EVar "unresolvedWhy") (EVar "a")))) (ELit (LString ""))) (EBinOp "++" (EVar "label") (ELit (LString " = true")))))))))
(DTypeSig false "paramToml" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "paramToml" ((PVar "p")) (EMatch (EApp (EVar "canonParam") (EVar "p")) (arm (PCon "PPrefix" (PCon "Some" (PVar "s"))) () (EApp (EVar "tomlQuote") (EVar "s"))) (arm (PCon "PPath" (PCon "Some" (PVar "s"))) () (EApp (EVar "tomlQuote") (EApp (EVar "pathSpelling") (EVar "s")))) (arm (PCon "PSet" (PCon "Some" (PVar "xs"))) () (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "tomlQuote")) (EVar "xs"))))) (ELit (LString "]")))) (arm (PCon "PProduct" (PVar "ax")) ((GBool (EApp (EVar "not") (EApp (EVar "isSubTop") (EApp (EVar "PProduct") (EVar "ax")))))) (EBinOp "++" (EBinOp "++" (ELit (LString "{ ")) (EApp (EMethodRef "display") (EApp (EVar "productTomlInline") (EVar "ax")))) (ELit (LString " }")))) (arm PWild () (ELit (LString "true")))))
(DTypeSig false "productTomlInline" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "String")))
(DFunDef false "productTomlInline" ((PVar "ax")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "axisToToml")) (EApp (EApp (EVar "filterList") (ELam ((PVar "a")) (EApp (EVar "not") (EApp (EVar "isSubTop") (EApp (EVar "snd") (EVar "a")))))) (EVar "ax")))))
(DTypeSig false "axisToToml" (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyCon "String")))
(DFunDef false "axisToToml" ((PTuple (PVar "name") (PCon "PPrefix" (PCon "Some" (PVar "s"))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "lowerFirst") (EVar "name")))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EApp (EVar "tomlQuote") (EVar "s")))) (ELit (LString ""))))
(DFunDef false "axisToToml" ((PTuple (PVar "name") (PCon "PSet" (PCon "Some" (PVar "xs"))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "lowerFirst") (EVar "name")))) (ELit (LString " = ["))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "tomlQuote")) (EVar "xs"))))) (ELit (LString "]"))))
(DFunDef false "axisToToml" ((PTuple (PVar "name") PWild)) (EBinOp "++" (EApp (EVar "lowerFirst") (EVar "name")) (ELit (LString " = true"))))
(DTypeSig false "quoteTok" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "quoteTok" ((PVar "s")) (EApp (EVar "escStr") (EVar "s")))
(DTypeSig false "tomlQuote" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "tomlQuote" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "tomlChars") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))))) (ELit (LString "\""))))
(DTypeSig false "tomlChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tomlChars" ((PVar "cs") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "tomlChar") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EVar "tomlChars") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tomlChar" (TyFun (TyCon "Char") (TyCon "String")))
(DFunDef false "tomlChar" ((PVar "c")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\\"))) (ELit (LString "\\\\")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\""))) (ELit (LString "\\\"")) (EIf (EBinOp "||" (EBinOp "<" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 32))) (EBinOp "==" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 127)))) (EBinOp "++" (EBinOp "++" (ELit (LString "\\u00")) (EApp (EMethodRef "display") (EApp (EVar "escOneHex2") (EApp (EVar "charCode") (EVar "c"))))) (ELit (LString ""))) (EIf (EVar "otherwise") (EApp (EVar "charToStr") (EVar "c")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "lowerFirst" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "lowerFirst" ((PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EVar "s") (EBinOp "++" (EApp (EVar "toLower") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s"))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EVar "n")) (EVar "s")))))))
(DTypeSig true "manifestToml" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "manifestToml" ((PList)) (ELit (LString "[package.capabilities]\n")))
(DFunDef false "manifestToml" ((PVar "atoms")) (EBlock (DoLet false false (PVar "lines") (EApp (EApp (EMethodRef "map") (EApp (EVar "atomToToml") (EApp (EVar "manifestKey") (EVar "atoms")))) (EVar "atoms"))) (DoExpr (EBinOp "++" (ELit (LString "[package.capabilities]\n")) (EApp (EVar "joinTomlLines") (EVar "lines"))))))
(DTypeSig true "manifestKey" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyCon "Atom") (TyCon "String"))))
(DFunDef false "manifestKey" ((PVar "atoms") (PVar "a")) (EIf (EApp (EApp (EVar "labelCollides") (EVar "atoms")) (EApp (EVar "atomLabel") (EVar "a"))) (EApp (EVar "qualifiedKey") (EVar "a")) (EApp (EVar "atomLabel") (EVar "a"))))
(DTypeSig false "labelCollides" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "labelCollides" ((PVar "atoms") (PVar "name")) (EBinOp ">" (EApp (EVar "listLen") (EApp (EVar "sortUniqS") (EApp (EApp (EMethodRef "map") (EVar "atomKey")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EBinOp "==" (EApp (EVar "atomLabel") (EVar "b")) (EVar "name")))) (EVar "atoms"))))) (ELit (LInt 1))))
(DTypeSig true "qualifiedKey" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "qualifiedKey" ((PVar "a")) (EApp (EVar "EP.qualifiedKey") (EVar "a")))
(DTypeSig true "unresolvedWhy" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "unresolvedWhy" ((PVar "a")) (EApp (EVar "EP.unresolvedWhy") (EVar "a")))
(DTypeSig false "joinTomlLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinTomlLines" ((PList)) (ELit (LString "")))
(DFunDef false "joinTomlLines" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EVar "joinTomlLines") (EVar "xs")))) (ELit (LString ""))))
(DData Public "ManifestArgs" () ((variant "ManifestArgs" (ConPos (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String")))) ())
(DTypeSig true "runManifest" (TyFun (TyCon "EntryAnalysis") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "runManifest" ((PVar "analysis") (PVar "fnName")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "fnName")) (EFieldAccess (EVar "analysis") "eaSchemes")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "no '")) (EApp (EMethodRef "display") (EVar "fnName"))) (ELit (LString "' entry found"))))) (arm (PCon "Some" (PVar "sch")) () (EApp (EVar "Ok") (EApp (EVar "manifestToml") (EApp (EApp (EVar "invocationSummary") (EFieldAccess (EVar "analysis") "eaOps")) (EVar "sch")))))))
(DTypeSig true "manifestToAllowStr" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "manifestToAllowStr" ((PVar "atoms")) (EBlock (DoLet false false (PVar "toks") (EApp (EApp (EDictApp "flatMap") (EVar "atomToAllowToks")) (EVar "atoms"))) (DoExpr (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "toks")))))
(DTypeSig false "atomToAllowToks" (TyFun (TyCon "Atom") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "atomToAllowToks" ((PVar "a")) (EBlock (DoLet false false (PVar "label") (EApp (EVar "atomLabel") (EVar "a"))) (DoExpr (EMatch (EApp (EVar "authConsts") (EApp (EVar "atomAuth") (EVar "a"))) (arm (PCon "Some" (PVar "ps")) ((GBool (EApp (EApp (EVar "anyList") (EVar "pathClimbs")) (EVar "ps")))) (EListLit (EVar "label"))) (arm (PCon "Some" (PAs "ps" (PCons PWild PWild))) () (EApp (EApp (EMethodRef "map") (EApp (EVar "paramAllowTok") (EVar "label"))) (EVar "ps"))) (arm PWild () (EListLit (EVar "label")))))))
(DTypeSig false "paramAllowTok" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyCon "String"))))
(DFunDef false "paramAllowTok" ((PVar "label") (PVar "p")) (EMatch (EApp (EVar "canonParam") (EVar "p")) (arm (PCon "PPrefix" (PCon "Some" (PVar "s"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString "="))) (EApp (EMethodRef "display") (EVar "s"))) (ELit (LString "")))) (arm (PCon "PPath" (PCon "Some" (PVar "s"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString "="))) (EApp (EMethodRef "display") (EApp (EVar "pathSpelling") (EVar "s")))) (ELit (LString "")))) (arm (PCon "PSet" (PCon "Some" (PVar "xs"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString "={"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "xs")))) (ELit (LString "}")))) (arm (PCon "PProduct" (PVar "ax")) ((GBool (EApp (EVar "not") (EApp (EVar "isSubTop") (EApp (EVar "PProduct") (EVar "ax")))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString "="))) (EApp (EMethodRef "display") (EApp (EVar "productAllowRhs") (EVar "ax")))) (ELit (LString "")))) (arm PWild () (EVar "label"))))
(DTypeSig false "productAllowRhs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "String")))
(DFunDef false "productAllowRhs" ((PVar "ax")) (EApp (EVar "joinSemiTok") (EApp (EApp (EDictApp "flatMap") (EVar "axisToAllow")) (EVar "ax"))))
(DTypeSig false "axisToAllow" (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "axisToAllow" ((PTuple (PVar "name") (PCon "PPrefix" (PCon "Some" (PVar "s"))))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "=\""))) (EApp (EMethodRef "display") (EVar "s"))) (ELit (LString "\"")))))
(DFunDef false "axisToAllow" ((PTuple (PVar "name") (PCon "PSet" (PCon "Some" (PVar "xs"))))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "={"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "xs")))) (ELit (LString "}")))))
(DFunDef false "axisToAllow" (PWild) (EListLit))
(DTypeSig false "joinSemiTok" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinSemiTok" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString ";"))) (EVar "xs")))
