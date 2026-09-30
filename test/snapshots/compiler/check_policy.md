# META
source_lines=898
stages=DESUGAR,MARK
# SOURCE
import types.effect_domain.{canonParam, drender, isSubTop, Param(..)}
import types.effect_authority.{
  Authority(..), authSub, authVars, authHasVars, authvarDefaultName,
  authJoinAll, authConsts
}
import types.effect_invocation.{invocationSummary, InvocationOps}
import types.effect_rows.{
  effLabelOrigin,
  atomLabelOf,
  atomKey,
  atomLabel,
  atomAuth,
  atomsUnion,
  renderAtom,
  Atom(..),
  effrowLabels,
}
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

import frontend.ast.{
  EffParamTy(..),
  effParamSurface,
  TyConOrigin(..),
  Decl(..),
  Expr(..),
  Pat(..),
  Lit(..),
  Arm(..),
  Guard(..),
  DoStmt(..),
  LetBind(..),
  FunClause(..),
  FieldAssign(..),
}
import frontend.parser.{parse}
import frontend.desugar.{desugar}
import types.repr.{Scheme(..), Mono(..), normalize}
import backend.private_mangle.{mangleCtorCollisionsPair}
import types.typecheck.{
  ElabResult,
  elaborateModulesWithSchemes,
  lastInvocationOps,
  decodeSetParam,
  decodeWrittenParam,
  atomOfLabel,
  ioAliasLabels,
  bindingGrantArity,
}
import eval.eval.{Value(..), evalModulesRootEnv, apply, outputRef, ppValue}
import support.util.{
  sortUniqS, joinWith, reverseL, escStr, lookupAssoc, contains, filterList,
  listLen
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

-- Every result's value, or the first error.
allOk : List (Result String a) -> Result String (List a)
allOk [] = Ok []
allOk ((Err m) :: _) = Err m
allOk ((Ok x) :: rest) = map (x :: _) (allOk rest)

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

-- ── 2. call graph from the desugared AST ────────────────────────────────────
-- collectEVars: every EVar name referenced in an expression (conservative —
-- includes non-call uses, safe for the chain heuristic).  Mirror collect_evars
-- in bin/main.ml; the desugared tree has no EGuards/ESection/EBlock
-- surface sugar, so those arms are omitted (already lowered).
collectEVars : Expr -> List String
collectEVars (EVar n) = [n]
collectEVars (ELoc _ e) = collectEVars e
collectEVars (EMethodRef n) = [n]
collectEVars (EDictApp n) = [n]
collectEVars (EApp f x) = collectEVars f ++ collectEVars x
collectEVars (ELam _ body) = collectEVars body
collectEVars (ELet _ _ _ v body) = collectEVars v ++ collectEVars body
collectEVars (ELetGroup binds body) =
  concatMapCP collectBind binds ++ collectEVars body
collectEVars (EMatch e arms) = collectEVars e ++ concatMapCP collectArm arms
collectEVars (EIf c t f) = collectEVars c ++ collectEVars t ++ collectEVars f
collectEVars (EBinOp _ a b _) = collectEVars a ++ collectEVars b
collectEVars (EUnOp _ e _) = collectEVars e
collectEVars (EInfix _ a b) = collectEVars a ++ collectEVars b
collectEVars (EAnnot e _) = collectEVars e
collectEVars (EHeadAnnot e _) = collectEVars e
collectEVars (EFieldAccess e _ _) = collectEVars e
collectEVars (ERecordCreate _ flds) = concatMapCP collectFieldAssign flds
collectEVars (ERecordUpdate e flds _) =
  collectEVars e ++ concatMapCP collectFieldAssign flds
collectEVars (EVariantUpdate _ e flds) =
  collectEVars e ++ concatMapCP collectFieldAssign flds
collectEVars (ETuple es) = concatMapCP collectEVars es
collectEVars (EListLit es) = concatMapCP collectEVars es
collectEVars (EArrayLit es) = concatMapCP collectEVars es
collectEVars (ERangeList a b _) = collectEVars a ++ collectEVars b
collectEVars (ERangeArray a b _) = collectEVars a ++ collectEVars b
collectEVars (ESlice a b c _ _) =
  collectEVars a ++ collectEVars b ++ collectEVars c
collectEVars (EIndex a b _) = collectEVars a ++ collectEVars b
collectEVars (EBlock stmts) = concatMapCP collectStmt stmts
collectEVars (EDo _ stmts) = concatMapCP collectStmt stmts
collectEVars _ = []

collectBind : LetBind -> List String
collectBind (LetBind _ clauses) = concatMapCP collectClause clauses

collectClause : FunClause -> List String
collectClause (FunClause _ body) = collectEVars body

collectArm : Arm -> List String
collectArm (Arm _ guards body) =
  concatMapCP collectGuard guards ++ collectEVars body

collectGuard : Guard -> List String
collectGuard (GBool e) = collectEVars e
collectGuard (GBind _ e) = collectEVars e

collectFieldAssign : FieldAssign -> List String
collectFieldAssign (FieldAssign _ e) = collectEVars e

collectStmt : DoStmt -> List String
collectStmt (DoExpr e) = collectEVars e
collectStmt (DoBind _ e) = collectEVars e
collectStmt (DoLet _ _ _ e) = collectEVars e
collectStmt (DoAssign _ e) = collectEVars e
collectStmt (DoFieldAssign _ _ e) = collectEVars e

concatMapCP : (a -> List b) -> List a -> List b
concatMapCP _ [] = []
concatMapCP f (x :: xs) = f x ++ concatMapCP f xs

-- A top-level name (DFunDef or DExtern), peeling DAttrib.  Mirror inner_decl +
-- the DFunDef/DExtern match in the OCaml call-graph builder.
topName : Decl -> Option String
topName (DFunDef _ n _ _) = Some n
topName (DExtern _ n _) = Some n
topName (DAttrib _ d) = topName d
topName _ = None

-- (name, body-EVars) for each top-level DFunDef (externs have no body).
fnBody : Decl -> Option (String, List String)
fnBody (DFunDef _ n _ body) = Some (n, collectEVars body)
fnBody (DAttrib _ d) = fnBody d
fnBody _ = None

-- The call graph: name → callees restricted to top-level names.  `assoc list`.
buildCallGraph : List Decl -> List (String, List String)
buildCallGraph decls =
  let tops = collectOpts (map topName decls)
  let bodies = collectOpts (map fnBody decls)
  map (restrictBody tops) bodies

restrictBody : List String -> (String, List String) -> (String, List String)
restrictBody tops (n, refs) = (n, intersectStr refs tops)

intersectStr : List String -> List String -> List String
intersectStr xs ys = filterMember xs ys

filterMember : List String -> List String -> List String
filterMember [] _ = []
filterMember (x :: xs) ys =
  if contains x ys then x :: filterMember xs ys else filterMember xs ys

collectOpts : List (Option a) -> List a
collectOpts [] = []
collectOpts (None :: rest) = collectOpts rest
collectOpts ((Some x) :: rest) = x :: collectOpts rest

-- ── 4. effect ATOMS from a scheme ────────────────────────────────────────
-- What the host can make an entry perform: the invocation summary
-- (`types/effect_invocation.mdk`), over the checked program's own
-- constructors and variance table (`lastInvocationOps`).

-- The label view of an atom list (for header rendering + chain keys).  Each atom
-- renders `label` (⊤ param) or `label "pat"` (concrete) via drender — byte-
-- identical to WS-1a for ⊤ params (drender ⊤ = "").
atomLabels : List Atom -> List String
atomLabels atoms = map renderAtom atoms

-- (name, effect-atoms) for every fn whose CALL performs a non-empty effect set:
-- the chain below follows what calling a callee performs, not what a host
-- could reach through it.
fnEffectsTable : List (String, Scheme) -> List (String, List Atom)
fnEffectsTable [] = []
fnEffectsTable ((name, sch) :: rest) = match callPerformed sch
  [] => fnEffectsTable rest
  effs => (name, effs) :: fnEffectsTable rest

-- What applying a binding performs: its forcing row and the rows along its
-- result spine, an effect index returned included.
callPerformed : Scheme -> List Atom
callPerformed (Forall _ _ _ _ force mono) =
  atomsUnion (effrowLabels force) (resultSpineRows mono)

resultSpineRows : Mono -> List Atom
resultSpineRows m = match normalize m
  TFun _ row res => atomsUnion (effrowLabels row) (resultSpineRows res)
  TEff row => effrowLabels row
  _ => []

-- Does fn `name` carry an atom whose LABEL is `label`?  (Chain reconstruction
-- stays label-keyed — the param does not participate in the call-graph trace.)
fnHasEffect : List (String, List Atom) -> String -> String -> Bool
fnHasEffect table name label = match lookupAssoc name table
  None => False
  Some effs => contains label (map atomLabel effs)

-- ── 6. call-chain reconstruction ────────────────────────────────────────────
-- find_chain: from `start`, repeatedly hop to the lexicographically-smallest
-- callee that carries `forbiddenLabel`, stopping at a leaf or a revisit (mirror
-- SS.find_first_opt over the sorted callee set + the `visited` cutoff).
findChain : List (String, List String) ->
  List (String, List Atom) ->
  String ->
  String ->
  List String
findChain callGraph effTable start forbiddenLabel =
  traceChain callGraph effTable forbiddenLabel start [start]

traceChain : List (String, List String) ->
  List (String, List Atom) ->
  String ->
  String ->
  List String ->
  List String
traceChain callGraph effTable forbiddenLabel fn visited =
  let callees = match lookupAssoc fn callGraph
    None => []
    Some s => s
  -- SS.find_first_opt picks the SMALLEST name; sortUniqS the callees, take first
  -- carrying the forbidden effect.
  match firstWithEffect effTable forbiddenLabel (sortUniqS callees)
    None => [fn]
    Some c =>
      if contains c visited then
        [fn, c]
      else
        fn :: traceChain callGraph effTable forbiddenLabel c (c :: visited)

firstWithEffect : List (String, List Atom) ->
  String ->
  List String ->
  Option String
firstWithEffect _ _ [] = None
firstWithEffect effTable label (c :: rest) =
  if fnHasEffect effTable c label then
    Some c
  else
    firstWithEffect effTable label rest

-- ── 5. policy filtering (WS-1b: parameter-level compare via dsub) ────────────
-- An atom is FORBIDDEN iff EITHER its label is absent from the policy, OR (label
-- present with policy param `pp`) `dsub inferredParam pp` is FALSE — i.e. the
-- inferred authority is NOT within the policy's authority.  Returns the offending
-- LABELS (the chain trace + reject report stay label-keyed).  Bare `--allow Net`
-- ⟹ policy param ⊤ (PPrefix None) ⟹ `dsub _ ⊤` = True ⟹ identical to WS-1a's
-- membership test.  Reuse `dsub` — do NOT reimplement the prefix logic.
forbiddenLabels : List Atom -> List (String, EffParamTy) -> List String
forbiddenLabels effs policy = filterForbidden effs policy

filterForbidden : List Atom -> List (String, EffParamTy) -> List String
filterForbidden [] _ = []
filterForbidden (a :: rest) policy = match permitOf a policy
  Permitted => filterForbidden rest policy
  _ => atomLabel a :: filterForbidden rest policy

-- Why each refused atom's policy entry could not be read, one report line per
-- malformed entry the verdict met.
policyProblems : List Atom -> List (String, EffParamTy) -> List String
policyProblems effs policy =
  flatMap
    (a => match permitOf a policy
      Malformed m => ["   policy entry for \{atomLabel a}: \{m}\n"]
      _ => [])
    effs

data Permit = Permitted | Forbidden | Malformed String

-- Permitted iff the label is in the policy AND the inferred authority is
-- provably within what the label's entries admit together, each entry decoded
-- in the domain of the atom's own label: an authority still symbolic at the
-- manifest boundary is not proven and is not permitted, and an entry the
-- domain does not admit permits nothing.
permitOf : Atom -> List (String, EffParamTy) -> Permit
permitOf a policy = match (atomLabel a == "IO", policyEntriesFor a policy)
  (True, []) => permitIoAsJoin policy
  (_, []) => Forbidden
  (_, written) => match allOk (map (decodeWrittenParam (atomLabelOf a)) written)
    -- The entries are read exactly, however many there are: a set is never
    -- folded, so a manifest of any size is accepted back as a policy.
    Ok pps =>
      if authSub (atomAuth a) (authJoinAll (map AConst pps)) then
        Permitted
      else
        Forbidden
    Err m => Malformed m

-- `IO` is the join of the ten host labels, so an `IO` atom under a policy with no
-- `IO` entry is permitted exactly when the policy admits every one of the ten at
-- its top.
permitIoAsJoin : List (String, EffParamTy) -> Permit
permitIoAsJoin policy =
  firstNotPermitted (map (l => permitOf (atomOfLabel l) policy) ioAliasLabels)

firstNotPermitted : List Permit -> Permit
firstNotPermitted [] = Permitted
firstNotPermitted (Permitted :: rest) = firstNotPermitted rest
firstNotPermitted (p :: _) = p

-- An atom whose authority is still a variable at the host boundary, refused
-- by a policy entry narrower than the whole label: the entry may well cover
-- what the caller will choose, but nothing proves it.
notProvenLines : List Atom -> List (String, EffParamTy) -> List String
notProvenLines effs policy =
  flatMap
    (a => match (authHasVars (atomAuth a), permitOf a policy)
      (True, Forbidden) => match policyEntriesFor a policy
        _ :: _ =>
          let unresolved =
            Atom
              (atomLabelOf a)
              (authJoinAll (map AVar (authVars (atomAuth a))))
          ["   not proven: \{renderAtom unresolved} (\{unresolvedWhy a})\n"]
        [] => []
      _ => [])
    effs

-- Why an atom's authority is unresolved: the variables it still names.
export
unresolvedWhy : Atom -> String
unresolvedWhy a =
  let names =
    map (v => "`" ++ authvarDefaultName v ++ "`") (authVars (atomAuth a))
  match names
    [one] => "authority variable \{one}"
    _ => "authority variables \{joinWith ", " names}"

-- The entries for an atom: those under its qualified key, else those under
-- its bare label.
policyEntriesFor : Atom -> List (String, EffParamTy) -> List EffParamTy
policyEntriesFor a policy =
  match entriesUnder (policySpelling (qualifiedKey a)) policy
    [] => entriesUnder (atomLabel a) policy
    es => es

entriesUnder : String -> List (String, EffParamTy) -> List EffParamTy
entriesUnder key policy = map snd (filterList (e => fst e == key) policy)

-- A policy token spells a qualified key without the TOML quotes.
policySpelling : String -> String
policySpelling k =
  let n = stringLength k
  if n >= 2 && stringSlice 0 1 k == "\"" && stringSlice (n - 1) n k == "\"" then
    stringSlice 1 (n - 1) k
  else
    k

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
  let rootEnv = evalModulesRootEnv (coreE ++ stubD) modulesE
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
-- `lastInvocationOps` describes whichever drive ran last.
public export data EntryAnalysis = EntryAnalysis {
  eaElab : ElabResult,
  eaSchemes : List (String, Scheme),
  eaOps : InvocationOps,
  eaEntryDecls : List Decl,
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
  EntryAnalysis {
    eaElab = elaborated,
    eaSchemes = ownSchemes ++ preludeSchemes,
    eaOps = ops,
    eaEntryDecls = entryModuleDecls modsD,
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
  let callGraph = buildCallGraph analysis.eaEntryDecls
  let schemes = analysis.eaSchemes
  let effTable = fnEffectsTable schemes
  -- Existence is checked against the complete scheme list, not effTable:
  -- fnEffectsTable deliberately omits verified-pure bindings, so using it as
  -- a name index would reject a real pure entry exactly like an absent one.
  match lookupAssoc fnName schemes
    None => PolicyReject "rejected. no '\{fnName}' entry found\n"
    Some fnScheme =>
      let fnEffects = invocationSummary analysis.eaOps fnScheme
      let forbidden = forbiddenLabels fnEffects policy
      match forbidden
        [] =>
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
        _ =>
          let chain = findChain callGraph effTable fnName (firstOf forbidden)
          let header =
            "rejected. \{fnName} requires <\{joinWith ", " (atomLabels fnEffects)}>. Not permitted by policy {\{joinWith ", " (policyLabels policy)}}\n"
          let via = "   reached via: " ++ joinWith " → " chain ++ "\n"
          let problems = stringConcat (policyProblems fnEffects policy)
          let unproven = stringConcat (notProvenLines fnEffects policy)
          PolicyReject (header ++ via ++ problems ++ unproven)

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
-- naming the variables that left it unresolved.
atomToToml : (Atom -> String) -> Atom -> String
atomToToml keyOf a =
  let label = keyOf a
  match authConsts (atomAuth a)
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
  PPrefix (Some s) => "\"\{s}\""
  PSet (Some xs) => "[\{joinWith ", " (map quoteTok xs)}]"
  PProduct ax if not (isSubTop (PProduct ax)) => "{ \{productTomlInline ax} }"  -- WS-4 inline table
  _ => "true"

-- WS-4: render a product's axes as a TOML inline-table body: a Prefix axis →
-- `host = "…"`, a Set axis → `method = ["GET", "POST"]` (TOML keys lowercased
-- by convention).  Comma-joined.
productTomlInline : List (String, Param) -> String
productTomlInline ax =
  joinWith ", " (map axisToToml (filterList (a => not (isSubTop (snd a))) ax))

axisToToml : (String, Param) -> String
axisToToml (name, PPrefix (Some s)) = "\{lowerFirst name} = \"\{s}\""
axisToToml (name, PSet (Some xs)) =
  "\{lowerFirst name} = [\{joinWith ", " (map quoteTok xs)}]"
axisToToml (name, _) = lowerFirst name ++ " = true"

quoteTok : String -> String
quoteTok s = "\"" ++ s ++ "\""

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

-- `"mod.Name"` for a module-declared label, the bare name for a builtin.
export
qualifiedKey : Atom -> String
qualifiedKey a = match effLabelOrigin (atomLabelOf a)
  OriginModule m => "\"\{m}.\{atomLabel a}\""
  _ => atomLabel a

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
    Some (ps@(_ :: _)) => map (paramAllowTok label) ps
    _ => [label]

paramAllowTok : String -> Param -> String
paramAllowTok label p = match canonParam p
  PPrefix (Some s) => "\{label}=\{s}"
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
(DUse false (UseGroup ("types" "effect_domain") ((mem "canonParam" false) (mem "drender" false) (mem "isSubTop" false) (mem "Param" true))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "authSub" false) (mem "authVars" false) (mem "authHasVars" false) (mem "authvarDefaultName" false) (mem "authJoinAll" false) (mem "authConsts" false))))
(DUse false (UseGroup ("types" "effect_invocation") ((mem "invocationSummary" false) (mem "InvocationOps" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "effLabelOrigin" false) (mem "atomLabelOf" false) (mem "atomKey" false) (mem "atomLabel" false) (mem "atomAuth" false) (mem "atomsUnion" false) (mem "renderAtom" false) (mem "Atom" true) (mem "effrowLabels" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "EffParamTy" true) (mem "effParamSurface" false) (mem "TyConOrigin" true) (mem "Decl" true) (mem "Expr" true) (mem "Pat" true) (mem "Lit" true) (mem "Arm" true) (mem "Guard" true) (mem "DoStmt" true) (mem "LetBind" true) (mem "FunClause" true) (mem "FieldAssign" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" true) (mem "Mono" true) (mem "normalize" false))))
(DUse false (UseGroup ("backend" "private_mangle") ((mem "mangleCtorCollisionsPair" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "ElabResult" false) (mem "elaborateModulesWithSchemes" false) (mem "lastInvocationOps" false) (mem "decodeSetParam" false) (mem "decodeWrittenParam" false) (mem "atomOfLabel" false) (mem "ioAliasLabels" false) (mem "bindingGrantArity" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" true) (mem "evalModulesRootEnv" false) (mem "apply" false) (mem "outputRef" false) (mem "ppValue" false))))
(DUse false (UseGroup ("support" "util") ((mem "sortUniqS" false) (mem "joinWith" false) (mem "reverseL" false) (mem "escStr" false) (mem "lookupAssoc" false) (mem "contains" false) (mem "filterList" false) (mem "listLen" false))))
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
(DTypeSig false "allOk" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "allOk" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "allOk" ((PCons (PCon "Err" (PVar "m")) PWild)) (EApp (EVar "Err") (EVar "m")))
(DFunDef false "allOk" ((PCons (PCon "Ok" (PVar "x")) (PVar "rest"))) (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "x") (EVar "_s")))) (EApp (EVar "allOk") (EVar "rest"))))
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
(DTypeSig false "collectEVars" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectEVars" ((PCon "EVar" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EMethodRef" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "EDictApp" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "f")) (EApp (EVar "collectEVars") (EVar "x"))))
(DFunDef false "collectEVars" ((PCon "ELam" PWild (PVar "body"))) (EApp (EVar "collectEVars") (EVar "body")))
(DFunDef false "collectEVars" ((PCon "ELet" PWild PWild PWild (PVar "v") (PVar "body"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "v")) (EApp (EVar "collectEVars") (EVar "body"))))
(DFunDef false "collectEVars" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "concatMapCP") (EVar "collectBind")) (EVar "binds")) (EApp (EVar "collectEVars") (EVar "body"))))
(DFunDef false "collectEVars" ((PCon "EMatch" (PVar "e") (PVar "arms"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectArm")) (EVar "arms"))))
(DFunDef false "collectEVars" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectEVars") (EVar "c")) (EApp (EVar "collectEVars") (EVar "t"))) (EApp (EVar "collectEVars") (EVar "f"))))
(DFunDef false "collectEVars" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EUnOp" PWild (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EFieldAccess" (PVar "e") PWild PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "ERecordCreate" PWild (PVar "flds"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds")))
(DFunDef false "collectEVars" ((PCon "ERecordUpdate" (PVar "e") (PVar "flds") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds"))))
(DFunDef false "collectEVars" ((PCon "EVariantUpdate" PWild (PVar "e") (PVar "flds"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds"))))
(DFunDef false "collectEVars" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "ERangeList" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "ERangeArray" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "ESlice" (PVar "a") (PVar "b") (PVar "c") PWild PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))) (EApp (EVar "collectEVars") (EVar "c"))))
(DFunDef false "collectEVars" ((PCon "EIndex" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectStmt")) (EVar "stmts")))
(DFunDef false "collectEVars" ((PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectStmt")) (EVar "stmts")))
(DFunDef false "collectEVars" (PWild) (EListLit))
(DTypeSig false "collectBind" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectBind" ((PCon "LetBind" PWild (PVar "clauses"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectClause")) (EVar "clauses")))
(DTypeSig false "collectClause" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectClause" ((PCon "FunClause" PWild (PVar "body"))) (EApp (EVar "collectEVars") (EVar "body")))
(DTypeSig false "collectArm" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectArm" ((PCon "Arm" PWild (PVar "guards") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "concatMapCP") (EVar "collectGuard")) (EVar "guards")) (EApp (EVar "collectEVars") (EVar "body"))))
(DTypeSig false "collectGuard" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectGuard" ((PCon "GBind" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "collectFieldAssign" (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectFieldAssign" ((PCon "FieldAssign" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "collectStmt" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoBind" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoLet" PWild PWild PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoAssign" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "concatMapCP" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")))))
(DFunDef false "concatMapCP" (PWild (PList)) (EListLit))
(DFunDef false "concatMapCP" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EApp (EVar "f") (EVar "x")) (EApp (EApp (EVar "concatMapCP") (EVar "f")) (EVar "xs"))))
(DTypeSig false "topName" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "topName" ((PCon "DFunDef" PWild (PVar "n") PWild PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "topName" ((PCon "DExtern" PWild (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "topName" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "topName") (EVar "d")))
(DFunDef false "topName" (PWild) (EVar "None"))
(DTypeSig false "fnBody" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "fnBody" ((PCon "DFunDef" PWild (PVar "n") PWild (PVar "body"))) (EApp (EVar "Some") (ETuple (EVar "n") (EApp (EVar "collectEVars") (EVar "body")))))
(DFunDef false "fnBody" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "fnBody") (EVar "d")))
(DFunDef false "fnBody" (PWild) (EVar "None"))
(DTypeSig false "buildCallGraph" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "buildCallGraph" ((PVar "decls")) (EBlock (DoLet false false (PVar "tops") (EApp (EVar "collectOpts") (EApp (EApp (EVar "map") (EVar "topName")) (EVar "decls")))) (DoLet false false (PVar "bodies") (EApp (EVar "collectOpts") (EApp (EApp (EVar "map") (EVar "fnBody")) (EVar "decls")))) (DoExpr (EApp (EApp (EVar "map") (EApp (EVar "restrictBody") (EVar "tops"))) (EVar "bodies")))))
(DTypeSig false "restrictBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "restrictBody" ((PVar "tops") (PTuple (PVar "n") (PVar "refs"))) (ETuple (EVar "n") (EApp (EApp (EVar "intersectStr") (EVar "refs")) (EVar "tops"))))
(DTypeSig false "intersectStr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "intersectStr" ((PVar "xs") (PVar "ys")) (EApp (EApp (EVar "filterMember") (EVar "xs")) (EVar "ys")))
(DTypeSig false "filterMember" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterMember" ((PList) PWild) (EListLit))
(DFunDef false "filterMember" ((PCons (PVar "x") (PVar "xs")) (PVar "ys")) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "ys")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "filterMember") (EVar "xs")) (EVar "ys"))) (EApp (EApp (EVar "filterMember") (EVar "xs")) (EVar "ys"))))
(DTypeSig false "collectOpts" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "collectOpts" ((PList)) (EListLit))
(DFunDef false "collectOpts" ((PCons (PCon "None") (PVar "rest"))) (EApp (EVar "collectOpts") (EVar "rest")))
(DFunDef false "collectOpts" ((PCons (PCon "Some" (PVar "x")) (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "collectOpts") (EVar "rest"))))
(DTypeSig false "atomLabels" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "atomLabels" ((PVar "atoms")) (EApp (EApp (EVar "map") (EVar "renderAtom")) (EVar "atoms")))
(DTypeSig false "fnEffectsTable" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "fnEffectsTable" ((PList)) (EListLit))
(DFunDef false "fnEffectsTable" ((PCons (PTuple (PVar "name") (PVar "sch")) (PVar "rest"))) (EMatch (EApp (EVar "callPerformed") (EVar "sch")) (arm (PList) () (EApp (EVar "fnEffectsTable") (EVar "rest"))) (arm (PVar "effs") () (EBinOp "::" (ETuple (EVar "name") (EVar "effs")) (EApp (EVar "fnEffectsTable") (EVar "rest"))))))
(DTypeSig false "callPerformed" (TyFun (TyCon "Scheme") (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "callPerformed" ((PCon "Forall" PWild PWild PWild PWild (PVar "force") (PVar "mono"))) (EApp (EApp (EVar "atomsUnion") (EApp (EVar "effrowLabels") (EVar "force"))) (EApp (EVar "resultSpineRows") (EVar "mono"))))
(DTypeSig false "resultSpineRows" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "resultSpineRows" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" PWild (PVar "row") (PVar "res")) () (EApp (EApp (EVar "atomsUnion") (EApp (EVar "effrowLabels") (EVar "row"))) (EApp (EVar "resultSpineRows") (EVar "res")))) (arm (PCon "TEff" (PVar "row")) () (EApp (EVar "effrowLabels") (EVar "row"))) (arm PWild () (EListLit))))
(DTypeSig false "fnHasEffect" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "fnHasEffect" ((PVar "table") (PVar "name") (PVar "label")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "table")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "effs")) () (EApp (EApp (EVar "contains") (EVar "label")) (EApp (EApp (EVar "map") (EVar "atomLabel")) (EVar "effs"))))))
(DTypeSig false "findChain" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "findChain" ((PVar "callGraph") (PVar "effTable") (PVar "start") (PVar "forbiddenLabel")) (EApp (EApp (EApp (EApp (EApp (EVar "traceChain") (EVar "callGraph")) (EVar "effTable")) (EVar "forbiddenLabel")) (EVar "start")) (EListLit (EVar "start"))))
(DTypeSig false "traceChain" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "traceChain" ((PVar "callGraph") (PVar "effTable") (PVar "forbiddenLabel") (PVar "fn") (PVar "visited")) (EBlock (DoLet false false (PVar "callees") (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "fn")) (EVar "callGraph")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "s")) () (EVar "s")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "firstWithEffect") (EVar "effTable")) (EVar "forbiddenLabel")) (EApp (EVar "sortUniqS") (EVar "callees"))) (arm (PCon "None") () (EListLit (EVar "fn"))) (arm (PCon "Some" (PVar "c")) () (EIf (EApp (EApp (EVar "contains") (EVar "c")) (EVar "visited")) (EListLit (EVar "fn") (EVar "c")) (EBinOp "::" (EVar "fn") (EApp (EApp (EApp (EApp (EApp (EVar "traceChain") (EVar "callGraph")) (EVar "effTable")) (EVar "forbiddenLabel")) (EVar "c")) (EBinOp "::" (EVar "c") (EVar "visited"))))))))))
(DTypeSig false "firstWithEffect" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "firstWithEffect" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstWithEffect" ((PVar "effTable") (PVar "label") (PCons (PVar "c") (PVar "rest"))) (EIf (EApp (EApp (EApp (EVar "fnHasEffect") (EVar "effTable")) (EVar "c")) (EVar "label")) (EApp (EVar "Some") (EVar "c")) (EApp (EApp (EApp (EVar "firstWithEffect") (EVar "effTable")) (EVar "label")) (EVar "rest"))))
(DTypeSig false "forbiddenLabels" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "forbiddenLabels" ((PVar "effs") (PVar "policy")) (EApp (EApp (EVar "filterForbidden") (EVar "effs")) (EVar "policy")))
(DTypeSig false "filterForbidden" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterForbidden" ((PList) PWild) (EListLit))
(DFunDef false "filterForbidden" ((PCons (PVar "a") (PVar "rest")) (PVar "policy")) (EMatch (EApp (EApp (EVar "permitOf") (EVar "a")) (EVar "policy")) (arm (PCon "Permitted") () (EApp (EApp (EVar "filterForbidden") (EVar "rest")) (EVar "policy"))) (arm PWild () (EBinOp "::" (EApp (EVar "atomLabel") (EVar "a")) (EApp (EApp (EVar "filterForbidden") (EVar "rest")) (EVar "policy"))))))
(DTypeSig false "policyProblems" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "policyProblems" ((PVar "effs") (PVar "policy")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "a")) (EMatch (EApp (EApp (EVar "permitOf") (EVar "a")) (EVar "policy")) (arm (PCon "Malformed" (PVar "m")) () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "   policy entry for ")) (EApp (EVar "display") (EApp (EVar "atomLabel") (EVar "a")))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "\n"))))) (arm PWild () (EListLit))))) (EVar "effs")))
(DData Private "Permit" () ((variant "Permitted" (ConPos)) (variant "Forbidden" (ConPos)) (variant "Malformed" (ConPos (TyCon "String")))) ())
(DTypeSig false "permitOf" (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyCon "Permit"))))
(DFunDef false "permitOf" ((PVar "a") (PVar "policy")) (EMatch (ETuple (EBinOp "==" (EApp (EVar "atomLabel") (EVar "a")) (ELit (LString "IO"))) (EApp (EApp (EVar "policyEntriesFor") (EVar "a")) (EVar "policy"))) (arm (PTuple (PCon "True") (PList)) () (EApp (EVar "permitIoAsJoin") (EVar "policy"))) (arm (PTuple PWild (PList)) () (EVar "Forbidden")) (arm (PTuple PWild (PVar "written")) () (EMatch (EApp (EVar "allOk") (EApp (EApp (EVar "map") (EApp (EVar "decodeWrittenParam") (EApp (EVar "atomLabelOf") (EVar "a")))) (EVar "written"))) (arm (PCon "Ok" (PVar "pps")) () (EIf (EApp (EApp (EVar "authSub") (EApp (EVar "atomAuth") (EVar "a"))) (EApp (EVar "authJoinAll") (EApp (EApp (EVar "map") (EVar "AConst")) (EVar "pps")))) (EVar "Permitted") (EVar "Forbidden"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Malformed") (EVar "m")))))))
(DTypeSig false "permitIoAsJoin" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyCon "Permit")))
(DFunDef false "permitIoAsJoin" ((PVar "policy")) (EApp (EVar "firstNotPermitted") (EApp (EApp (EVar "map") (ELam ((PVar "l")) (EApp (EApp (EVar "permitOf") (EApp (EVar "atomOfLabel") (EVar "l"))) (EVar "policy")))) (EVar "ioAliasLabels"))))
(DTypeSig false "firstNotPermitted" (TyFun (TyApp (TyCon "List") (TyCon "Permit")) (TyCon "Permit")))
(DFunDef false "firstNotPermitted" ((PList)) (EVar "Permitted"))
(DFunDef false "firstNotPermitted" ((PCons (PCon "Permitted") (PVar "rest"))) (EApp (EVar "firstNotPermitted") (EVar "rest")))
(DFunDef false "firstNotPermitted" ((PCons (PVar "p") PWild)) (EVar "p"))
(DTypeSig false "notProvenLines" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "notProvenLines" ((PVar "effs") (PVar "policy")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "a")) (EMatch (ETuple (EApp (EVar "authHasVars") (EApp (EVar "atomAuth") (EVar "a"))) (EApp (EApp (EVar "permitOf") (EVar "a")) (EVar "policy"))) (arm (PTuple (PCon "True") (PCon "Forbidden")) () (EMatch (EApp (EApp (EVar "policyEntriesFor") (EVar "a")) (EVar "policy")) (arm (PCons PWild PWild) () (EBlock (DoLet false false (PVar "unresolved") (EApp (EApp (EVar "Atom") (EApp (EVar "atomLabelOf") (EVar "a"))) (EApp (EVar "authJoinAll") (EApp (EApp (EVar "map") (EVar "AVar")) (EApp (EVar "authVars") (EApp (EVar "atomAuth") (EVar "a"))))))) (DoExpr (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "   not proven: ")) (EApp (EVar "display") (EApp (EVar "renderAtom") (EVar "unresolved")))) (ELit (LString " ("))) (EApp (EVar "display") (EApp (EVar "unresolvedWhy") (EVar "a")))) (ELit (LString ")\n"))))))) (arm (PList) () (EListLit)))) (arm PWild () (EListLit))))) (EVar "effs")))
(DTypeSig true "unresolvedWhy" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "unresolvedWhy" ((PVar "a")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "map") (ELam ((PVar "v")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "authvarDefaultName") (EVar "v"))) (ELit (LString "`"))))) (EApp (EVar "authVars") (EApp (EVar "atomAuth") (EVar "a"))))) (DoExpr (EMatch (EVar "names") (arm (PList (PVar "one")) () (EBinOp "++" (EBinOp "++" (ELit (LString "authority variable ")) (EApp (EVar "display") (EVar "one"))) (ELit (LString "")))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "authority variables ")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "names")))) (ELit (LString ""))))))))
(DTypeSig false "policyEntriesFor" (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "EffParamTy")))))
(DFunDef false "policyEntriesFor" ((PVar "a") (PVar "policy")) (EMatch (EApp (EApp (EVar "entriesUnder") (EApp (EVar "policySpelling") (EApp (EVar "qualifiedKey") (EVar "a")))) (EVar "policy")) (arm (PList) () (EApp (EApp (EVar "entriesUnder") (EApp (EVar "atomLabel") (EVar "a"))) (EVar "policy"))) (arm (PVar "es") () (EVar "es"))))
(DTypeSig false "entriesUnder" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "EffParamTy")))))
(DFunDef false "entriesUnder" ((PVar "key") (PVar "policy")) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "==" (EApp (EVar "fst") (EVar "e")) (EVar "key")))) (EVar "policy"))))
(DTypeSig false "policySpelling" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "policySpelling" ((PVar "k")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "k"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "k")) (ELit (LString "\"")))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "k")) (ELit (LString "\"")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "k")) (EVar "k")))))
(DTypeSig false "stubSource" (TyCon "String"))
(DFunDef false "stubSource" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "cacheGet req = \"\"\n")) (ELit (LString "cacheSet req result = ()\n")) (ELit (LString "logEvent s = putStr (stringConcat [\"   [LOG] \", s, \"\\n\"])\n")) (ELit (LString "getEnv k = None\n")) (ELit (LString "args u = []\n")) (ELit (LString "executablePath u = \"\"\n")) (ELit (LString "readFile p g = Err \"\"\n")) (ELit (LString "readFileBytes p g = Err \"\"\n")) (ELit (LString "fileExists p g = False\n")) (ELit (LString "canonicalizePath p g = p\n")) (ELit (LString "listDir p g = Err \"\"\n")) (ELit (LString "statFile p g = Err \"\"\n")) (ELit (LString "writeFile p c g = Err \"\"\n")) (ELit (LString "writeFileBytes p b g = Err \"\"\n")) (ELit (LString "appendFile p c g = Err \"\"\n")) (ELit (LString "makeDir p g = Err \"\"\n")) (ELit (LString "removeFile p g = Err \"\"\n")) (ELit (LString "rename o n gs gd = Err \"\"\n")) (ELit (LString "removeDir p g = Err \"\"\n")) (ELit (LString "runCommand cmd a = Err \"\"\n")) (ELit (LString "netResolve h = Err \"\"\n")) (ELit (LString "netTcpConnect h p = Err \"\"\n")) (ELit (LString "netTcpListen h p = Err \"\"\n")) (ELit (LString "netListenPort fd = Err \"\"\n")) (ELit (LString "netTcpAccept fd = Err \"\"\n")) (ELit (LString "netSend fd b = Err \"\"\n")) (ELit (LString "netRecv fd n = Err \"\"\n")) (ELit (LString "netShutdown fd how = Err \"\"\n")) (ELit (LString "netClose fd = Err \"\"\n")) (ELit (LString "netSetTimeout fd ms = Err \"\"\n")))))
(DTypeSig false "runPlugin" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "ElabResult") (TyCon "String")))))
(DFunDef false "runPlugin" ((PVar "fnName") (PVar "grants") (PTuple (PVar "coreD") (PVar "modules") PWild PWild PWild PWild)) (EBlock (DoLet false false (PVar "stubD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "stubSource")))) (DoLet false false (PTuple (PVar "coreE") (PVar "modulesE")) (EApp (EVar "mangleCtorCollisionsPair") (ETuple (EVar "coreD") (EVar "modules")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "outputRef")) (ELit (LString "")))) (DoLet false false (PVar "rootEnv") (EApp (EApp (EVar "evalModulesRootEnv") (EBinOp "++" (EVar "coreE") (EVar "stubD"))) (EVar "modulesE"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupValue") (EVar "fnName")) (EVar "rootEnv")) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "   (no '")) (EVar "fnName")) (ELit (LString "' binding in output)\n")))) (arm (PCon "Some" (PVar "fnVal")) () (EBlock (DoLet false false (PVar "sample") (ELit (LString "X-Forwarded-For: 192.168.1.1"))) (DoLet false false (PVar "granted") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "f") PWild) (EApp (EApp (EVar "apply") (EVar "f")) (EApp (EVar "VList") (EListLit))))) (EVar "fnVal")) (EApp (EApp (EVar "replicate") (EVar "grants")) (ELit LUnit)))) (DoLet false false (PVar "result") (EApp (EApp (EVar "apply") (EVar "granted")) (EApp (EVar "VString") (EVar "sample")))) (DoLet false false (PVar "logged") (EUnOp "!" (EVar "outputRef"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "logged"))) (ELit (LString "   "))) (EApp (EVar "display") (EVar "fnName"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStr") (EVar "sample")))) (ELit (LString " = "))) (EApp (EVar "display") (EApp (EVar "ppValue") (EVar "result")))) (ELit (LString "\n"))))))))))
(DTypeSig false "lookupValue" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "lookupValue" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupValue" ((PVar "k") (PCons (PTuple (PVar "n") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "lookupValue") (EVar "k")) (EVar "rest"))))
(DData Public "EntryAnalysis" () ((variant "EntryAnalysis" (ConNamed (field "eaElab" (TyCon "ElabResult")) (field "eaSchemes" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))) (field "eaOps" (TyCon "InvocationOps")) (field "eaEntryDecls" (TyApp (TyCon "List") (TyCon "Decl")))))) ())
(DTypeSig true "analyzeProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "EntryAnalysis")))))
(DFunDef false "analyzeProgram" ((PVar "rtD") (PVar "coreD") (PVar "modsD")) (EBlock (DoLet false false (PTuple (PVar "elaborated") (PVar "preludeSchemes") (PVar "ownSchemes")) (EApp (EApp (EApp (EVar "elaborateModulesWithSchemes") (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoLet false false (PVar "ops") (EApp (EVar "lastInvocationOps") (ELit LUnit))) (DoExpr (ERecordCreate "EntryAnalysis" ((fa "eaElab" (EVar "elaborated")) (fa "eaSchemes" (EBinOp "++" (EVar "ownSchemes") (EVar "preludeSchemes"))) (fa "eaOps" (EVar "ops")) (fa "eaEntryDecls" (EApp (EVar "entryModuleDecls") (EVar "modsD"))))))))
(DTypeSig false "entryModuleDecls" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "entryModuleDecls" ((PList)) (EListLit))
(DFunDef false "entryModuleDecls" ((PList (PTuple PWild (PVar "decls")))) (EVar "decls"))
(DFunDef false "entryModuleDecls" ((PCons PWild (PVar "rest"))) (EApp (EVar "entryModuleDecls") (EVar "rest")))
(DData Public "PolicyOutcome" () ((variant "PolicyAccept" (ConPos (TyCon "String") (TyFun (TyCon "Unit") (TyCon "String")))) (variant "PolicyReject" (ConPos (TyCon "String")))) ())
(DTypeSig true "runCheckPolicy" (TyFun (TyCon "EntryAnalysis") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "PolicyOutcome")))))
(DFunDef false "runCheckPolicy" ((PVar "analysis") (PVar "allowStr") (PVar "fnName")) (EMatch (EApp (EVar "parsePolicy") (EVar "allowStr")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "PolicyReject") (EBinOp "++" (EBinOp "++" (ELit (LString "rejected. ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "\n"))))) (arm (PCon "Ok" (PVar "policy")) () (EApp (EApp (EApp (EVar "policyVerdict") (EVar "policy")) (EVar "analysis")) (EVar "fnName")))))
(DTypeSig false "policyVerdict" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyFun (TyCon "EntryAnalysis") (TyFun (TyCon "String") (TyCon "PolicyOutcome")))))
(DFunDef false "policyVerdict" ((PVar "policy") (PVar "analysis") (PVar "fnName")) (EBlock (DoLet false false (PVar "callGraph") (EApp (EVar "buildCallGraph") (EFieldAccess (EVar "analysis") "eaEntryDecls"))) (DoLet false false (PVar "schemes") (EFieldAccess (EVar "analysis") "eaSchemes")) (DoLet false false (PVar "effTable") (EApp (EVar "fnEffectsTable") (EVar "schemes"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "fnName")) (EVar "schemes")) (arm (PCon "None") () (EApp (EVar "PolicyReject") (EBinOp "++" (EBinOp "++" (ELit (LString "rejected. no '")) (EApp (EVar "display") (EVar "fnName"))) (ELit (LString "' entry found\n"))))) (arm (PCon "Some" (PVar "fnScheme")) () (EBlock (DoLet false false (PVar "fnEffects") (EApp (EApp (EVar "invocationSummary") (EFieldAccess (EVar "analysis") "eaOps")) (EVar "fnScheme"))) (DoLet false false (PVar "forbidden") (EApp (EApp (EVar "forbiddenLabels") (EVar "fnEffects")) (EVar "policy"))) (DoExpr (EMatch (EVar "forbidden") (arm (PList) () (EBlock (DoLet false false (PVar "effStr") (EIf (EApp (EVar "listIsEmpty") (EVar "fnEffects")) (ELit (LString "pure")) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EVar "atomLabels") (EVar "fnEffects")))) (ELit (LString ">"))))) (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "accepted. ")) (EApp (EVar "display") (EVar "fnName"))) (ELit (LString " requires only "))) (EApp (EVar "display") (EVar "effStr"))) (ELit (LString "\n")))) (DoLet false false (PVar "pluginOutput") (ELam (PWild) (EIf (EApp (EVar "takesAndReturnsString") (EVar "fnScheme")) (EApp (EApp (EApp (EVar "runPlugin") (EVar "fnName")) (EApp (EApp (EVar "bindingGrantArity") (EVar "fnName")) (EVar "fnScheme"))) (EFieldAccess (EVar "analysis") "eaElab")) (EBinOp "++" (EBinOp "++" (ELit (LString "   no sample run: '")) (EApp (EVar "display") (EVar "fnName"))) (ELit (LString "' is not a String -> String entry\n")))))) (DoExpr (EApp (EApp (EVar "PolicyAccept") (EVar "header")) (EVar "pluginOutput"))))) (arm PWild () (EBlock (DoLet false false (PVar "chain") (EApp (EApp (EApp (EApp (EVar "findChain") (EVar "callGraph")) (EVar "effTable")) (EVar "fnName")) (EApp (EVar "firstOf") (EVar "forbidden")))) (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "rejected. ")) (EApp (EVar "display") (EVar "fnName"))) (ELit (LString " requires <"))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EVar "atomLabels") (EVar "fnEffects"))))) (ELit (LString ">. Not permitted by policy {"))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EVar "policyLabels") (EVar "policy"))))) (ELit (LString "}\n")))) (DoLet false false (PVar "via") (EBinOp "++" (EBinOp "++" (ELit (LString "   reached via: ")) (EApp (EApp (EVar "joinWith") (ELit (LString " → "))) (EVar "chain"))) (ELit (LString "\n")))) (DoLet false false (PVar "problems") (EApp (EVar "stringConcat") (EApp (EApp (EVar "policyProblems") (EVar "fnEffects")) (EVar "policy")))) (DoLet false false (PVar "unproven") (EApp (EVar "stringConcat") (EApp (EApp (EVar "notProvenLines") (EVar "fnEffects")) (EVar "policy")))) (DoExpr (EApp (EVar "PolicyReject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "header") (EVar "via")) (EVar "problems")) (EVar "unproven"))))))))))))))
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
(DFunDef false "atomToToml" ((PVar "keyOf") (PVar "a")) (EBlock (DoLet false false (PVar "label") (EApp (EVar "keyOf") (EVar "a"))) (DoExpr (EMatch (EApp (EVar "authConsts") (EApp (EVar "atomAuth") (EVar "a"))) (arm (PCon "Some" (PList (PVar "p"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "label"))) (ELit (LString " = "))) (EApp (EVar "display") (EApp (EVar "paramToml") (EVar "p")))) (ELit (LString "")))) (arm (PCon "Some" (PAs "ps" (PCons PWild (PCons PWild PWild)))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "label"))) (ELit (LString " = ["))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "paramToml")) (EVar "ps"))))) (ELit (LString "]")))) (arm PWild () (EIf (EApp (EVar "authHasVars") (EApp (EVar "atomAuth") (EVar "a"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "label"))) (ELit (LString " = true  # unresolved: "))) (EApp (EVar "display") (EApp (EVar "unresolvedWhy") (EVar "a")))) (ELit (LString ""))) (EBinOp "++" (EVar "label") (ELit (LString " = true")))))))))
(DTypeSig false "paramToml" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "paramToml" ((PVar "p")) (EMatch (EApp (EVar "canonParam") (EVar "p")) (arm (PCon "PPrefix" (PCon "Some" (PVar "s"))) () (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EVar "display") (EVar "s"))) (ELit (LString "\"")))) (arm (PCon "PSet" (PCon "Some" (PVar "xs"))) () (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "quoteTok")) (EVar "xs"))))) (ELit (LString "]")))) (arm (PCon "PProduct" (PVar "ax")) ((GBool (EApp (EVar "not") (EApp (EVar "isSubTop") (EApp (EVar "PProduct") (EVar "ax")))))) (EBinOp "++" (EBinOp "++" (ELit (LString "{ ")) (EApp (EVar "display") (EApp (EVar "productTomlInline") (EVar "ax")))) (ELit (LString " }")))) (arm PWild () (ELit (LString "true")))))
(DTypeSig false "productTomlInline" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "String")))
(DFunDef false "productTomlInline" ((PVar "ax")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "axisToToml")) (EApp (EApp (EVar "filterList") (ELam ((PVar "a")) (EApp (EVar "not") (EApp (EVar "isSubTop") (EApp (EVar "snd") (EVar "a")))))) (EVar "ax")))))
(DTypeSig false "axisToToml" (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyCon "String")))
(DFunDef false "axisToToml" ((PTuple (PVar "name") (PCon "PPrefix" (PCon "Some" (PVar "s"))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "lowerFirst") (EVar "name")))) (ELit (LString " = \""))) (EApp (EVar "display") (EVar "s"))) (ELit (LString "\""))))
(DFunDef false "axisToToml" ((PTuple (PVar "name") (PCon "PSet" (PCon "Some" (PVar "xs"))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "lowerFirst") (EVar "name")))) (ELit (LString " = ["))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "quoteTok")) (EVar "xs"))))) (ELit (LString "]"))))
(DFunDef false "axisToToml" ((PTuple (PVar "name") PWild)) (EBinOp "++" (EApp (EVar "lowerFirst") (EVar "name")) (ELit (LString " = true"))))
(DTypeSig false "quoteTok" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "quoteTok" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EVar "s")) (ELit (LString "\""))))
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
(DFunDef false "qualifiedKey" ((PVar "a")) (EMatch (EApp (EVar "effLabelOrigin") (EApp (EVar "atomLabelOf") (EVar "a"))) (arm (PCon "OriginModule" (PVar "m")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "atomLabel") (EVar "a")))) (ELit (LString "\"")))) (arm PWild () (EApp (EVar "atomLabel") (EVar "a")))))
(DTypeSig false "joinTomlLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinTomlLines" ((PList)) (ELit (LString "")))
(DFunDef false "joinTomlLines" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EVar "joinTomlLines") (EVar "xs")))) (ELit (LString ""))))
(DData Public "ManifestArgs" () ((variant "ManifestArgs" (ConPos (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String")))) ())
(DTypeSig true "runManifest" (TyFun (TyCon "EntryAnalysis") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "runManifest" ((PVar "analysis") (PVar "fnName")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "fnName")) (EFieldAccess (EVar "analysis") "eaSchemes")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "no '")) (EApp (EVar "display") (EVar "fnName"))) (ELit (LString "' entry found"))))) (arm (PCon "Some" (PVar "sch")) () (EApp (EVar "Ok") (EApp (EVar "manifestToml") (EApp (EApp (EVar "invocationSummary") (EFieldAccess (EVar "analysis") "eaOps")) (EVar "sch")))))))
(DTypeSig true "manifestToAllowStr" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "manifestToAllowStr" ((PVar "atoms")) (EBlock (DoLet false false (PVar "toks") (EApp (EApp (EVar "flatMap") (EVar "atomToAllowToks")) (EVar "atoms"))) (DoExpr (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "toks")))))
(DTypeSig false "atomToAllowToks" (TyFun (TyCon "Atom") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "atomToAllowToks" ((PVar "a")) (EBlock (DoLet false false (PVar "label") (EApp (EVar "atomLabel") (EVar "a"))) (DoExpr (EMatch (EApp (EVar "authConsts") (EApp (EVar "atomAuth") (EVar "a"))) (arm (PCon "Some" (PAs "ps" (PCons PWild PWild))) () (EApp (EApp (EVar "map") (EApp (EVar "paramAllowTok") (EVar "label"))) (EVar "ps"))) (arm PWild () (EListLit (EVar "label")))))))
(DTypeSig false "paramAllowTok" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyCon "String"))))
(DFunDef false "paramAllowTok" ((PVar "label") (PVar "p")) (EMatch (EApp (EVar "canonParam") (EVar "p")) (arm (PCon "PPrefix" (PCon "Some" (PVar "s"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "label"))) (ELit (LString "="))) (EApp (EVar "display") (EVar "s"))) (ELit (LString "")))) (arm (PCon "PSet" (PCon "Some" (PVar "xs"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "label"))) (ELit (LString "={"))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "xs")))) (ELit (LString "}")))) (arm (PCon "PProduct" (PVar "ax")) ((GBool (EApp (EVar "not") (EApp (EVar "isSubTop") (EApp (EVar "PProduct") (EVar "ax")))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "label"))) (ELit (LString "="))) (EApp (EVar "display") (EApp (EVar "productAllowRhs") (EVar "ax")))) (ELit (LString "")))) (arm PWild () (EVar "label"))))
(DTypeSig false "productAllowRhs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "String")))
(DFunDef false "productAllowRhs" ((PVar "ax")) (EApp (EVar "joinSemiTok") (EApp (EApp (EVar "flatMap") (EVar "axisToAllow")) (EVar "ax"))))
(DTypeSig false "axisToAllow" (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "axisToAllow" ((PTuple (PVar "name") (PCon "PPrefix" (PCon "Some" (PVar "s"))))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "=\""))) (EApp (EVar "display") (EVar "s"))) (ELit (LString "\"")))))
(DFunDef false "axisToAllow" ((PTuple (PVar "name") (PCon "PSet" (PCon "Some" (PVar "xs"))))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "={"))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "xs")))) (ELit (LString "}")))))
(DFunDef false "axisToAllow" (PWild) (EListLit))
(DTypeSig false "joinSemiTok" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinSemiTok" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString ";"))) (EVar "xs")))
# MARK
(DUse false (UseGroup ("types" "effect_domain") ((mem "canonParam" false) (mem "drender" false) (mem "isSubTop" false) (mem "Param" true))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "authSub" false) (mem "authVars" false) (mem "authHasVars" false) (mem "authvarDefaultName" false) (mem "authJoinAll" false) (mem "authConsts" false))))
(DUse false (UseGroup ("types" "effect_invocation") ((mem "invocationSummary" false) (mem "InvocationOps" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "effLabelOrigin" false) (mem "atomLabelOf" false) (mem "atomKey" false) (mem "atomLabel" false) (mem "atomAuth" false) (mem "atomsUnion" false) (mem "renderAtom" false) (mem "Atom" true) (mem "effrowLabels" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "EffParamTy" true) (mem "effParamSurface" false) (mem "TyConOrigin" true) (mem "Decl" true) (mem "Expr" true) (mem "Pat" true) (mem "Lit" true) (mem "Arm" true) (mem "Guard" true) (mem "DoStmt" true) (mem "LetBind" true) (mem "FunClause" true) (mem "FieldAssign" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "parse" false))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "desugar" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Scheme" true) (mem "Mono" true) (mem "normalize" false))))
(DUse false (UseGroup ("backend" "private_mangle") ((mem "mangleCtorCollisionsPair" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "ElabResult" false) (mem "elaborateModulesWithSchemes" false) (mem "lastInvocationOps" false) (mem "decodeSetParam" false) (mem "decodeWrittenParam" false) (mem "atomOfLabel" false) (mem "ioAliasLabels" false) (mem "bindingGrantArity" false))))
(DUse false (UseGroup ("eval" "eval") ((mem "Value" true) (mem "evalModulesRootEnv" false) (mem "apply" false) (mem "outputRef" false) (mem "ppValue" false))))
(DUse false (UseGroup ("support" "util") ((mem "sortUniqS" false) (mem "joinWith" false) (mem "reverseL" false) (mem "escStr" false) (mem "lookupAssoc" false) (mem "contains" false) (mem "filterList" false) (mem "listLen" false))))
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
(DTypeSig false "allOk" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyVar "a"))) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "allOk" ((PList)) (EApp (EVar "Ok") (EListLit)))
(DFunDef false "allOk" ((PCons (PCon "Err" (PVar "m")) PWild)) (EApp (EVar "Err") (EVar "m")))
(DFunDef false "allOk" ((PCons (PCon "Ok" (PVar "x")) (PVar "rest"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "x") (EVar "_s")))) (EApp (EVar "allOk") (EVar "rest"))))
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
(DTypeSig false "collectEVars" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectEVars" ((PCon "EVar" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EMethodRef" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "EDictApp" (PVar "n"))) (EListLit (EVar "n")))
(DFunDef false "collectEVars" ((PCon "EApp" (PVar "f") (PVar "x"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "f")) (EApp (EVar "collectEVars") (EVar "x"))))
(DFunDef false "collectEVars" ((PCon "ELam" PWild (PVar "body"))) (EApp (EVar "collectEVars") (EVar "body")))
(DFunDef false "collectEVars" ((PCon "ELet" PWild PWild PWild (PVar "v") (PVar "body"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "v")) (EApp (EVar "collectEVars") (EVar "body"))))
(DFunDef false "collectEVars" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "concatMapCP") (EVar "collectBind")) (EVar "binds")) (EApp (EVar "collectEVars") (EVar "body"))))
(DFunDef false "collectEVars" ((PCon "EMatch" (PVar "e") (PVar "arms"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectArm")) (EVar "arms"))))
(DFunDef false "collectEVars" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectEVars") (EVar "c")) (EApp (EVar "collectEVars") (EVar "t"))) (EApp (EVar "collectEVars") (EVar "f"))))
(DFunDef false "collectEVars" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EUnOp" PWild (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "EFieldAccess" (PVar "e") PWild PWild)) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectEVars" ((PCon "ERecordCreate" PWild (PVar "flds"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds")))
(DFunDef false "collectEVars" ((PCon "ERecordUpdate" (PVar "e") (PVar "flds") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds"))))
(DFunDef false "collectEVars" ((PCon "EVariantUpdate" PWild (PVar "e") (PVar "flds"))) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "e")) (EApp (EApp (EVar "concatMapCP") (EVar "collectFieldAssign")) (EVar "flds"))))
(DFunDef false "collectEVars" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectEVars")) (EVar "es")))
(DFunDef false "collectEVars" ((PCon "ERangeList" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "ERangeArray" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "ESlice" (PVar "a") (PVar "b") (PVar "c") PWild PWild)) (EBinOp "++" (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))) (EApp (EVar "collectEVars") (EVar "c"))))
(DFunDef false "collectEVars" ((PCon "EIndex" (PVar "a") (PVar "b") PWild)) (EBinOp "++" (EApp (EVar "collectEVars") (EVar "a")) (EApp (EVar "collectEVars") (EVar "b"))))
(DFunDef false "collectEVars" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectStmt")) (EVar "stmts")))
(DFunDef false "collectEVars" ((PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectStmt")) (EVar "stmts")))
(DFunDef false "collectEVars" (PWild) (EListLit))
(DTypeSig false "collectBind" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectBind" ((PCon "LetBind" PWild (PVar "clauses"))) (EApp (EApp (EVar "concatMapCP") (EVar "collectClause")) (EVar "clauses")))
(DTypeSig false "collectClause" (TyFun (TyCon "FunClause") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectClause" ((PCon "FunClause" PWild (PVar "body"))) (EApp (EVar "collectEVars") (EVar "body")))
(DTypeSig false "collectArm" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectArm" ((PCon "Arm" PWild (PVar "guards") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "concatMapCP") (EVar "collectGuard")) (EVar "guards")) (EApp (EVar "collectEVars") (EVar "body"))))
(DTypeSig false "collectGuard" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectGuard" ((PCon "GBind" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "collectFieldAssign" (TyFun (TyCon "FieldAssign") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectFieldAssign" ((PCon "FieldAssign" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "collectStmt" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "collectStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoBind" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoLet" PWild PWild PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoAssign" PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DFunDef false "collectStmt" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EApp (EVar "collectEVars") (EVar "e")))
(DTypeSig false "concatMapCP" (TyFun (TyFun (TyVar "a") (TyApp (TyCon "List") (TyVar "b"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "b")))))
(DFunDef false "concatMapCP" (PWild (PList)) (EListLit))
(DFunDef false "concatMapCP" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EApp (EVar "f") (EVar "x")) (EApp (EApp (EVar "concatMapCP") (EVar "f")) (EVar "xs"))))
(DTypeSig false "topName" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "topName" ((PCon "DFunDef" PWild (PVar "n") PWild PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "topName" ((PCon "DExtern" PWild (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "topName" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "topName") (EVar "d")))
(DFunDef false "topName" (PWild) (EVar "None"))
(DTypeSig false "fnBody" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "fnBody" ((PCon "DFunDef" PWild (PVar "n") PWild (PVar "body"))) (EApp (EVar "Some") (ETuple (EVar "n") (EApp (EVar "collectEVars") (EVar "body")))))
(DFunDef false "fnBody" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "fnBody") (EVar "d")))
(DFunDef false "fnBody" (PWild) (EVar "None"))
(DTypeSig false "buildCallGraph" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "buildCallGraph" ((PVar "decls")) (EBlock (DoLet false false (PVar "tops") (EApp (EVar "collectOpts") (EApp (EApp (EMethodRef "map") (EVar "topName")) (EVar "decls")))) (DoLet false false (PVar "bodies") (EApp (EVar "collectOpts") (EApp (EApp (EMethodRef "map") (EVar "fnBody")) (EVar "decls")))) (DoExpr (EApp (EApp (EMethodRef "map") (EApp (EVar "restrictBody") (EVar "tops"))) (EVar "bodies")))))
(DTypeSig false "restrictBody" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "restrictBody" ((PVar "tops") (PTuple (PVar "n") (PVar "refs"))) (ETuple (EVar "n") (EApp (EApp (EVar "intersectStr") (EVar "refs")) (EVar "tops"))))
(DTypeSig false "intersectStr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "intersectStr" ((PVar "xs") (PVar "ys")) (EApp (EApp (EVar "filterMember") (EVar "xs")) (EVar "ys")))
(DTypeSig false "filterMember" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterMember" ((PList) PWild) (EListLit))
(DFunDef false "filterMember" ((PCons (PVar "x") (PVar "xs")) (PVar "ys")) (EIf (EApp (EApp (EVar "contains") (EVar "x")) (EVar "ys")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "filterMember") (EVar "xs")) (EVar "ys"))) (EApp (EApp (EVar "filterMember") (EVar "xs")) (EVar "ys"))))
(DTypeSig false "collectOpts" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyVar "a"))) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "collectOpts" ((PList)) (EListLit))
(DFunDef false "collectOpts" ((PCons (PCon "None") (PVar "rest"))) (EApp (EVar "collectOpts") (EVar "rest")))
(DFunDef false "collectOpts" ((PCons (PCon "Some" (PVar "x")) (PVar "rest"))) (EBinOp "::" (EVar "x") (EApp (EVar "collectOpts") (EVar "rest"))))
(DTypeSig false "atomLabels" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "atomLabels" ((PVar "atoms")) (EApp (EApp (EMethodRef "map") (EVar "renderAtom")) (EVar "atoms")))
(DTypeSig false "fnEffectsTable" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom"))))))
(DFunDef false "fnEffectsTable" ((PList)) (EListLit))
(DFunDef false "fnEffectsTable" ((PCons (PTuple (PVar "name") (PVar "sch")) (PVar "rest"))) (EMatch (EApp (EVar "callPerformed") (EVar "sch")) (arm (PList) () (EApp (EVar "fnEffectsTable") (EVar "rest"))) (arm (PVar "effs") () (EBinOp "::" (ETuple (EVar "name") (EVar "effs")) (EApp (EVar "fnEffectsTable") (EVar "rest"))))))
(DTypeSig false "callPerformed" (TyFun (TyCon "Scheme") (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "callPerformed" ((PCon "Forall" PWild PWild PWild PWild (PVar "force") (PVar "mono"))) (EApp (EApp (EVar "atomsUnion") (EApp (EVar "effrowLabels") (EVar "force"))) (EApp (EVar "resultSpineRows") (EVar "mono"))))
(DTypeSig false "resultSpineRows" (TyFun (TyCon "Mono") (TyApp (TyCon "List") (TyCon "Atom"))))
(DFunDef false "resultSpineRows" ((PVar "m")) (EMatch (EApp (EVar "normalize") (EVar "m")) (arm (PCon "TFun" PWild (PVar "row") (PVar "res")) () (EApp (EApp (EVar "atomsUnion") (EApp (EVar "effrowLabels") (EVar "row"))) (EApp (EVar "resultSpineRows") (EVar "res")))) (arm (PCon "TEff" (PVar "row")) () (EApp (EVar "effrowLabels") (EVar "row"))) (arm PWild () (EListLit))))
(DTypeSig false "fnHasEffect" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "fnHasEffect" ((PVar "table") (PVar "name") (PVar "label")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "name")) (EVar "table")) (arm (PCon "None") () (EVar "False")) (arm (PCon "Some" (PVar "effs")) () (EApp (EApp (EVar "contains") (EVar "label")) (EApp (EApp (EMethodRef "map") (EVar "atomLabel")) (EVar "effs"))))))
(DTypeSig false "findChain" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "findChain" ((PVar "callGraph") (PVar "effTable") (PVar "start") (PVar "forbiddenLabel")) (EApp (EApp (EApp (EApp (EApp (EVar "traceChain") (EVar "callGraph")) (EVar "effTable")) (EVar "forbiddenLabel")) (EVar "start")) (EListLit (EVar "start"))))
(DTypeSig false "traceChain" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "traceChain" ((PVar "callGraph") (PVar "effTable") (PVar "forbiddenLabel") (PVar "fn") (PVar "visited")) (EBlock (DoLet false false (PVar "callees") (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "fn")) (EVar "callGraph")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "s")) () (EVar "s")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "firstWithEffect") (EVar "effTable")) (EVar "forbiddenLabel")) (EApp (EVar "sortUniqS") (EVar "callees"))) (arm (PCon "None") () (EListLit (EVar "fn"))) (arm (PCon "Some" (PVar "c")) () (EIf (EApp (EApp (EVar "contains") (EVar "c")) (EVar "visited")) (EListLit (EVar "fn") (EVar "c")) (EBinOp "::" (EVar "fn") (EApp (EApp (EApp (EApp (EApp (EVar "traceChain") (EVar "callGraph")) (EVar "effTable")) (EVar "forbiddenLabel")) (EVar "c")) (EBinOp "::" (EVar "c") (EVar "visited"))))))))))
(DTypeSig false "firstWithEffect" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "firstWithEffect" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "firstWithEffect" ((PVar "effTable") (PVar "label") (PCons (PVar "c") (PVar "rest"))) (EIf (EApp (EApp (EApp (EVar "fnHasEffect") (EVar "effTable")) (EVar "c")) (EVar "label")) (EApp (EVar "Some") (EVar "c")) (EApp (EApp (EApp (EVar "firstWithEffect") (EVar "effTable")) (EVar "label")) (EVar "rest"))))
(DTypeSig false "forbiddenLabels" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "forbiddenLabels" ((PVar "effs") (PVar "policy")) (EApp (EApp (EVar "filterForbidden") (EVar "effs")) (EVar "policy")))
(DTypeSig false "filterForbidden" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "filterForbidden" ((PList) PWild) (EListLit))
(DFunDef false "filterForbidden" ((PCons (PVar "a") (PVar "rest")) (PVar "policy")) (EMatch (EApp (EApp (EVar "permitOf") (EVar "a")) (EVar "policy")) (arm (PCon "Permitted") () (EApp (EApp (EVar "filterForbidden") (EVar "rest")) (EVar "policy"))) (arm PWild () (EBinOp "::" (EApp (EVar "atomLabel") (EVar "a")) (EApp (EApp (EVar "filterForbidden") (EVar "rest")) (EVar "policy"))))))
(DTypeSig false "policyProblems" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "policyProblems" ((PVar "effs") (PVar "policy")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "a")) (EMatch (EApp (EApp (EVar "permitOf") (EVar "a")) (EVar "policy")) (arm (PCon "Malformed" (PVar "m")) () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "   policy entry for ")) (EApp (EMethodRef "display") (EApp (EVar "atomLabel") (EVar "a")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "\n"))))) (arm PWild () (EListLit))))) (EVar "effs")))
(DData Private "Permit" () ((variant "Permitted" (ConPos)) (variant "Forbidden" (ConPos)) (variant "Malformed" (ConPos (TyCon "String")))) ())
(DTypeSig false "permitOf" (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyCon "Permit"))))
(DFunDef false "permitOf" ((PVar "a") (PVar "policy")) (EMatch (ETuple (EBinOp "==" (EApp (EVar "atomLabel") (EVar "a")) (ELit (LString "IO"))) (EApp (EApp (EVar "policyEntriesFor") (EVar "a")) (EVar "policy"))) (arm (PTuple (PCon "True") (PList)) () (EApp (EVar "permitIoAsJoin") (EVar "policy"))) (arm (PTuple PWild (PList)) () (EVar "Forbidden")) (arm (PTuple PWild (PVar "written")) () (EMatch (EApp (EVar "allOk") (EApp (EApp (EMethodRef "map") (EApp (EVar "decodeWrittenParam") (EApp (EVar "atomLabelOf") (EVar "a")))) (EVar "written"))) (arm (PCon "Ok" (PVar "pps")) () (EIf (EApp (EApp (EVar "authSub") (EApp (EVar "atomAuth") (EVar "a"))) (EApp (EVar "authJoinAll") (EApp (EApp (EMethodRef "map") (EVar "AConst")) (EVar "pps")))) (EVar "Permitted") (EVar "Forbidden"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Malformed") (EVar "m")))))))
(DTypeSig false "permitIoAsJoin" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyCon "Permit")))
(DFunDef false "permitIoAsJoin" ((PVar "policy")) (EApp (EVar "firstNotPermitted") (EApp (EApp (EMethodRef "map") (ELam ((PVar "l")) (EApp (EApp (EVar "permitOf") (EApp (EVar "atomOfLabel") (EVar "l"))) (EVar "policy")))) (EVar "ioAliasLabels"))))
(DTypeSig false "firstNotPermitted" (TyFun (TyApp (TyCon "List") (TyCon "Permit")) (TyCon "Permit")))
(DFunDef false "firstNotPermitted" ((PList)) (EVar "Permitted"))
(DFunDef false "firstNotPermitted" ((PCons (PCon "Permitted") (PVar "rest"))) (EApp (EVar "firstNotPermitted") (EVar "rest")))
(DFunDef false "firstNotPermitted" ((PCons (PVar "p") PWild)) (EVar "p"))
(DTypeSig false "notProvenLines" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "notProvenLines" ((PVar "effs") (PVar "policy")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "a")) (EMatch (ETuple (EApp (EVar "authHasVars") (EApp (EVar "atomAuth") (EVar "a"))) (EApp (EApp (EVar "permitOf") (EVar "a")) (EVar "policy"))) (arm (PTuple (PCon "True") (PCon "Forbidden")) () (EMatch (EApp (EApp (EVar "policyEntriesFor") (EVar "a")) (EVar "policy")) (arm (PCons PWild PWild) () (EBlock (DoLet false false (PVar "unresolved") (EApp (EApp (EVar "Atom") (EApp (EVar "atomLabelOf") (EVar "a"))) (EApp (EVar "authJoinAll") (EApp (EApp (EMethodRef "map") (EVar "AVar")) (EApp (EVar "authVars") (EApp (EVar "atomAuth") (EVar "a"))))))) (DoExpr (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "   not proven: ")) (EApp (EMethodRef "display") (EApp (EVar "renderAtom") (EVar "unresolved")))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EApp (EVar "unresolvedWhy") (EVar "a")))) (ELit (LString ")\n"))))))) (arm (PList) () (EListLit)))) (arm PWild () (EListLit))))) (EVar "effs")))
(DTypeSig true "unresolvedWhy" (TyFun (TyCon "Atom") (TyCon "String")))
(DFunDef false "unresolvedWhy" ((PVar "a")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "authvarDefaultName") (EVar "v"))) (ELit (LString "`"))))) (EApp (EVar "authVars") (EApp (EVar "atomAuth") (EVar "a"))))) (DoExpr (EMatch (EVar "names") (arm (PList (PVar "one")) () (EBinOp "++" (EBinOp "++" (ELit (LString "authority variable ")) (EApp (EMethodRef "display") (EVar "one"))) (ELit (LString "")))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "authority variables ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "names")))) (ELit (LString ""))))))))
(DTypeSig false "policyEntriesFor" (TyFun (TyCon "Atom") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "EffParamTy")))))
(DFunDef false "policyEntriesFor" ((PVar "a") (PVar "policy")) (EMatch (EApp (EApp (EVar "entriesUnder") (EApp (EVar "policySpelling") (EApp (EVar "qualifiedKey") (EVar "a")))) (EVar "policy")) (arm (PList) () (EApp (EApp (EVar "entriesUnder") (EApp (EVar "atomLabel") (EVar "a"))) (EVar "policy"))) (arm (PVar "es") () (EVar "es"))))
(DTypeSig false "entriesUnder" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyApp (TyCon "List") (TyCon "EffParamTy")))))
(DFunDef false "entriesUnder" ((PVar "key") (PVar "policy")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EApp (EVar "filterList") (ELam ((PVar "e")) (EBinOp "==" (EApp (EVar "fst") (EVar "e")) (EVar "key")))) (EVar "policy"))))
(DTypeSig false "policySpelling" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "policySpelling" ((PVar "k")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "k"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "k")) (ELit (LString "\"")))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "k")) (ELit (LString "\"")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "k")) (EVar "k")))))
(DTypeSig false "stubSource" (TyCon "String"))
(DFunDef false "stubSource" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "cacheGet req = \"\"\n")) (ELit (LString "cacheSet req result = ()\n")) (ELit (LString "logEvent s = putStr (stringConcat [\"   [LOG] \", s, \"\\n\"])\n")) (ELit (LString "getEnv k = None\n")) (ELit (LString "args u = []\n")) (ELit (LString "executablePath u = \"\"\n")) (ELit (LString "readFile p g = Err \"\"\n")) (ELit (LString "readFileBytes p g = Err \"\"\n")) (ELit (LString "fileExists p g = False\n")) (ELit (LString "canonicalizePath p g = p\n")) (ELit (LString "listDir p g = Err \"\"\n")) (ELit (LString "statFile p g = Err \"\"\n")) (ELit (LString "writeFile p c g = Err \"\"\n")) (ELit (LString "writeFileBytes p b g = Err \"\"\n")) (ELit (LString "appendFile p c g = Err \"\"\n")) (ELit (LString "makeDir p g = Err \"\"\n")) (ELit (LString "removeFile p g = Err \"\"\n")) (ELit (LString "rename o n gs gd = Err \"\"\n")) (ELit (LString "removeDir p g = Err \"\"\n")) (ELit (LString "runCommand cmd a = Err \"\"\n")) (ELit (LString "netResolve h = Err \"\"\n")) (ELit (LString "netTcpConnect h p = Err \"\"\n")) (ELit (LString "netTcpListen h p = Err \"\"\n")) (ELit (LString "netListenPort fd = Err \"\"\n")) (ELit (LString "netTcpAccept fd = Err \"\"\n")) (ELit (LString "netSend fd b = Err \"\"\n")) (ELit (LString "netRecv fd n = Err \"\"\n")) (ELit (LString "netShutdown fd how = Err \"\"\n")) (ELit (LString "netClose fd = Err \"\"\n")) (ELit (LString "netSetTimeout fd ms = Err \"\"\n")))))
(DTypeSig false "runPlugin" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "ElabResult") (TyCon "String")))))
(DFunDef false "runPlugin" ((PVar "fnName") (PVar "grants") (PTuple (PVar "coreD") (PVar "modules") PWild PWild PWild PWild)) (EBlock (DoLet false false (PVar "stubD") (EApp (EVar "desugar") (EApp (EVar "parse") (EVar "stubSource")))) (DoLet false false (PTuple (PVar "coreE") (PVar "modulesE")) (EApp (EVar "mangleCtorCollisionsPair") (ETuple (EVar "coreD") (EVar "modules")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "outputRef")) (ELit (LString "")))) (DoLet false false (PVar "rootEnv") (EApp (EApp (EVar "evalModulesRootEnv") (EBinOp "++" (EVar "coreE") (EVar "stubD"))) (EVar "modulesE"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupValue") (EVar "fnName")) (EVar "rootEnv")) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "   (no '")) (EVar "fnName")) (ELit (LString "' binding in output)\n")))) (arm (PCon "Some" (PVar "fnVal")) () (EBlock (DoLet false false (PVar "sample") (ELit (LString "X-Forwarded-For: 192.168.1.1"))) (DoLet false false (PVar "granted") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "f") PWild) (EApp (EApp (EVar "apply") (EVar "f")) (EApp (EVar "VList") (EListLit))))) (EVar "fnVal")) (EApp (EApp (EVar "replicate") (EVar "grants")) (ELit LUnit)))) (DoLet false false (PVar "result") (EApp (EApp (EVar "apply") (EVar "granted")) (EApp (EVar "VString") (EVar "sample")))) (DoLet false false (PVar "logged") (EUnOp "!" (EVar "outputRef"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "logged"))) (ELit (LString "   "))) (EApp (EMethodRef "display") (EVar "fnName"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStr") (EVar "sample")))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EApp (EVar "ppValue") (EVar "result")))) (ELit (LString "\n"))))))))))
(DTypeSig false "lookupValue" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Value") (TyVar "e")))) (TyApp (TyCon "Option") (TyApp (TyCon "Value") (TyVar "e"))))))
(DFunDef false "lookupValue" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupValue" ((PVar "k") (PCons (PTuple (PVar "n") (PVar "v")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EVar "Some") (EVar "v")) (EApp (EApp (EVar "lookupValue") (EVar "k")) (EVar "rest"))))
(DData Public "EntryAnalysis" () ((variant "EntryAnalysis" (ConNamed (field "eaElab" (TyCon "ElabResult")) (field "eaSchemes" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Scheme")))) (field "eaOps" (TyCon "InvocationOps")) (field "eaEntryDecls" (TyApp (TyCon "List") (TyCon "Decl")))))) ())
(DTypeSig true "analyzeProgram" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyCon "EntryAnalysis")))))
(DFunDef false "analyzeProgram" ((PVar "rtD") (PVar "coreD") (PVar "modsD")) (EBlock (DoLet false false (PTuple (PVar "elaborated") (PVar "preludeSchemes") (PVar "ownSchemes")) (EApp (EApp (EApp (EVar "elaborateModulesWithSchemes") (EVar "rtD")) (EVar "coreD")) (EVar "modsD"))) (DoLet false false (PVar "ops") (EApp (EVar "lastInvocationOps") (ELit LUnit))) (DoExpr (ERecordCreate "EntryAnalysis" ((fa "eaElab" (EVar "elaborated")) (fa "eaSchemes" (EBinOp "++" (EVar "ownSchemes") (EVar "preludeSchemes"))) (fa "eaOps" (EVar "ops")) (fa "eaEntryDecls" (EApp (EVar "entryModuleDecls") (EVar "modsD"))))))))
(DTypeSig false "entryModuleDecls" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "entryModuleDecls" ((PList)) (EListLit))
(DFunDef false "entryModuleDecls" ((PList (PTuple PWild (PVar "decls")))) (EVar "decls"))
(DFunDef false "entryModuleDecls" ((PCons PWild (PVar "rest"))) (EApp (EVar "entryModuleDecls") (EVar "rest")))
(DData Public "PolicyOutcome" () ((variant "PolicyAccept" (ConPos (TyCon "String") (TyFun (TyCon "Unit") (TyCon "String")))) (variant "PolicyReject" (ConPos (TyCon "String")))) ())
(DTypeSig true "runCheckPolicy" (TyFun (TyCon "EntryAnalysis") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "PolicyOutcome")))))
(DFunDef false "runCheckPolicy" ((PVar "analysis") (PVar "allowStr") (PVar "fnName")) (EMatch (EApp (EVar "parsePolicy") (EVar "allowStr")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "PolicyReject") (EBinOp "++" (EBinOp "++" (ELit (LString "rejected. ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "\n"))))) (arm (PCon "Ok" (PVar "policy")) () (EApp (EApp (EApp (EVar "policyVerdict") (EVar "policy")) (EVar "analysis")) (EVar "fnName")))))
(DTypeSig false "policyVerdict" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))) (TyFun (TyCon "EntryAnalysis") (TyFun (TyCon "String") (TyCon "PolicyOutcome")))))
(DFunDef false "policyVerdict" ((PVar "policy") (PVar "analysis") (PVar "fnName")) (EBlock (DoLet false false (PVar "callGraph") (EApp (EVar "buildCallGraph") (EFieldAccess (EVar "analysis") "eaEntryDecls"))) (DoLet false false (PVar "schemes") (EFieldAccess (EVar "analysis") "eaSchemes")) (DoLet false false (PVar "effTable") (EApp (EVar "fnEffectsTable") (EVar "schemes"))) (DoExpr (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "fnName")) (EVar "schemes")) (arm (PCon "None") () (EApp (EVar "PolicyReject") (EBinOp "++" (EBinOp "++" (ELit (LString "rejected. no '")) (EApp (EMethodRef "display") (EVar "fnName"))) (ELit (LString "' entry found\n"))))) (arm (PCon "Some" (PVar "fnScheme")) () (EBlock (DoLet false false (PVar "fnEffects") (EApp (EApp (EVar "invocationSummary") (EFieldAccess (EVar "analysis") "eaOps")) (EVar "fnScheme"))) (DoLet false false (PVar "forbidden") (EApp (EApp (EVar "forbiddenLabels") (EVar "fnEffects")) (EVar "policy"))) (DoExpr (EMatch (EVar "forbidden") (arm (PList) () (EBlock (DoLet false false (PVar "effStr") (EIf (EApp (EVar "listIsEmpty") (EVar "fnEffects")) (ELit (LString "pure")) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EVar "atomLabels") (EVar "fnEffects")))) (ELit (LString ">"))))) (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "accepted. ")) (EApp (EMethodRef "display") (EVar "fnName"))) (ELit (LString " requires only "))) (EApp (EMethodRef "display") (EVar "effStr"))) (ELit (LString "\n")))) (DoLet false false (PVar "pluginOutput") (ELam (PWild) (EIf (EApp (EVar "takesAndReturnsString") (EVar "fnScheme")) (EApp (EApp (EApp (EVar "runPlugin") (EVar "fnName")) (EApp (EApp (EVar "bindingGrantArity") (EVar "fnName")) (EVar "fnScheme"))) (EFieldAccess (EVar "analysis") "eaElab")) (EBinOp "++" (EBinOp "++" (ELit (LString "   no sample run: '")) (EApp (EMethodRef "display") (EVar "fnName"))) (ELit (LString "' is not a String -> String entry\n")))))) (DoExpr (EApp (EApp (EVar "PolicyAccept") (EVar "header")) (EVar "pluginOutput"))))) (arm PWild () (EBlock (DoLet false false (PVar "chain") (EApp (EApp (EApp (EApp (EVar "findChain") (EVar "callGraph")) (EVar "effTable")) (EVar "fnName")) (EApp (EVar "firstOf") (EVar "forbidden")))) (DoLet false false (PVar "header") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "rejected. ")) (EApp (EMethodRef "display") (EVar "fnName"))) (ELit (LString " requires <"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EVar "atomLabels") (EVar "fnEffects"))))) (ELit (LString ">. Not permitted by policy {"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EVar "policyLabels") (EVar "policy"))))) (ELit (LString "}\n")))) (DoLet false false (PVar "via") (EBinOp "++" (EBinOp "++" (ELit (LString "   reached via: ")) (EApp (EApp (EVar "joinWith") (ELit (LString " → "))) (EVar "chain"))) (ELit (LString "\n")))) (DoLet false false (PVar "problems") (EApp (EVar "stringConcat") (EApp (EApp (EVar "policyProblems") (EVar "fnEffects")) (EVar "policy")))) (DoLet false false (PVar "unproven") (EApp (EVar "stringConcat") (EApp (EApp (EVar "notProvenLines") (EVar "fnEffects")) (EVar "policy")))) (DoExpr (EApp (EVar "PolicyReject") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "header") (EVar "via")) (EVar "problems")) (EVar "unproven"))))))))))))))
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
(DFunDef false "atomToToml" ((PVar "keyOf") (PVar "a")) (EBlock (DoLet false false (PVar "label") (EApp (EVar "keyOf") (EVar "a"))) (DoExpr (EMatch (EApp (EVar "authConsts") (EApp (EVar "atomAuth") (EVar "a"))) (arm (PCon "Some" (PList (PVar "p"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EApp (EVar "paramToml") (EVar "p")))) (ELit (LString "")))) (arm (PCon "Some" (PAs "ps" (PCons PWild (PCons PWild PWild)))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString " = ["))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "paramToml")) (EVar "ps"))))) (ELit (LString "]")))) (arm PWild () (EIf (EApp (EVar "authHasVars") (EApp (EVar "atomAuth") (EVar "a"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString " = true  # unresolved: "))) (EApp (EMethodRef "display") (EApp (EVar "unresolvedWhy") (EVar "a")))) (ELit (LString ""))) (EBinOp "++" (EVar "label") (ELit (LString " = true")))))))))
(DTypeSig false "paramToml" (TyFun (TyCon "Param") (TyCon "String")))
(DFunDef false "paramToml" ((PVar "p")) (EMatch (EApp (EVar "canonParam") (EVar "p")) (arm (PCon "PPrefix" (PCon "Some" (PVar "s"))) () (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EMethodRef "display") (EVar "s"))) (ELit (LString "\"")))) (arm (PCon "PSet" (PCon "Some" (PVar "xs"))) () (EBinOp "++" (EBinOp "++" (ELit (LString "[")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "quoteTok")) (EVar "xs"))))) (ELit (LString "]")))) (arm (PCon "PProduct" (PVar "ax")) ((GBool (EApp (EVar "not") (EApp (EVar "isSubTop") (EApp (EVar "PProduct") (EVar "ax")))))) (EBinOp "++" (EBinOp "++" (ELit (LString "{ ")) (EApp (EMethodRef "display") (EApp (EVar "productTomlInline") (EVar "ax")))) (ELit (LString " }")))) (arm PWild () (ELit (LString "true")))))
(DTypeSig false "productTomlInline" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "String")))
(DFunDef false "productTomlInline" ((PVar "ax")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "axisToToml")) (EApp (EApp (EVar "filterList") (ELam ((PVar "a")) (EApp (EVar "not") (EApp (EVar "isSubTop") (EApp (EVar "snd") (EVar "a")))))) (EVar "ax")))))
(DTypeSig false "axisToToml" (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyCon "String")))
(DFunDef false "axisToToml" ((PTuple (PVar "name") (PCon "PPrefix" (PCon "Some" (PVar "s"))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "lowerFirst") (EVar "name")))) (ELit (LString " = \""))) (EApp (EMethodRef "display") (EVar "s"))) (ELit (LString "\""))))
(DFunDef false "axisToToml" ((PTuple (PVar "name") (PCon "PSet" (PCon "Some" (PVar "xs"))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "lowerFirst") (EVar "name")))) (ELit (LString " = ["))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "quoteTok")) (EVar "xs"))))) (ELit (LString "]"))))
(DFunDef false "axisToToml" ((PTuple (PVar "name") PWild)) (EBinOp "++" (EApp (EVar "lowerFirst") (EVar "name")) (ELit (LString " = true"))))
(DTypeSig false "quoteTok" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "quoteTok" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EVar "s")) (ELit (LString "\""))))
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
(DFunDef false "qualifiedKey" ((PVar "a")) (EMatch (EApp (EVar "effLabelOrigin") (EApp (EVar "atomLabelOf") (EVar "a"))) (arm (PCon "OriginModule" (PVar "m")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "atomLabel") (EVar "a")))) (ELit (LString "\"")))) (arm PWild () (EApp (EVar "atomLabel") (EVar "a")))))
(DTypeSig false "joinTomlLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinTomlLines" ((PList)) (ELit (LString "")))
(DFunDef false "joinTomlLines" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EVar "joinTomlLines") (EVar "xs")))) (ELit (LString ""))))
(DData Public "ManifestArgs" () ((variant "ManifestArgs" (ConPos (TyApp (TyCon "Option") (TyCon "String")) (TyCon "String")))) ())
(DTypeSig true "runManifest" (TyFun (TyCon "EntryAnalysis") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "runManifest" ((PVar "analysis") (PVar "fnName")) (EMatch (EApp (EApp (EVar "lookupAssoc") (EVar "fnName")) (EFieldAccess (EVar "analysis") "eaSchemes")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "no '")) (EApp (EMethodRef "display") (EVar "fnName"))) (ELit (LString "' entry found"))))) (arm (PCon "Some" (PVar "sch")) () (EApp (EVar "Ok") (EApp (EVar "manifestToml") (EApp (EApp (EVar "invocationSummary") (EFieldAccess (EVar "analysis") "eaOps")) (EVar "sch")))))))
(DTypeSig true "manifestToAllowStr" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "manifestToAllowStr" ((PVar "atoms")) (EBlock (DoLet false false (PVar "toks") (EApp (EApp (EDictApp "flatMap") (EVar "atomToAllowToks")) (EVar "atoms"))) (DoExpr (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "toks")))))
(DTypeSig false "atomToAllowToks" (TyFun (TyCon "Atom") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "atomToAllowToks" ((PVar "a")) (EBlock (DoLet false false (PVar "label") (EApp (EVar "atomLabel") (EVar "a"))) (DoExpr (EMatch (EApp (EVar "authConsts") (EApp (EVar "atomAuth") (EVar "a"))) (arm (PCon "Some" (PAs "ps" (PCons PWild PWild))) () (EApp (EApp (EMethodRef "map") (EApp (EVar "paramAllowTok") (EVar "label"))) (EVar "ps"))) (arm PWild () (EListLit (EVar "label")))))))
(DTypeSig false "paramAllowTok" (TyFun (TyCon "String") (TyFun (TyCon "Param") (TyCon "String"))))
(DFunDef false "paramAllowTok" ((PVar "label") (PVar "p")) (EMatch (EApp (EVar "canonParam") (EVar "p")) (arm (PCon "PPrefix" (PCon "Some" (PVar "s"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString "="))) (EApp (EMethodRef "display") (EVar "s"))) (ELit (LString "")))) (arm (PCon "PSet" (PCon "Some" (PVar "xs"))) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString "={"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "xs")))) (ELit (LString "}")))) (arm (PCon "PProduct" (PVar "ax")) ((GBool (EApp (EVar "not") (EApp (EVar "isSubTop") (EApp (EVar "PProduct") (EVar "ax")))))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString "="))) (EApp (EMethodRef "display") (EApp (EVar "productAllowRhs") (EVar "ax")))) (ELit (LString "")))) (arm PWild () (EVar "label"))))
(DTypeSig false "productAllowRhs" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Param"))) (TyCon "String")))
(DFunDef false "productAllowRhs" ((PVar "ax")) (EApp (EVar "joinSemiTok") (EApp (EApp (EDictApp "flatMap") (EVar "axisToAllow")) (EVar "ax"))))
(DTypeSig false "axisToAllow" (TyFun (TyTuple (TyCon "String") (TyCon "Param")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "axisToAllow" ((PTuple (PVar "name") (PCon "PPrefix" (PCon "Some" (PVar "s"))))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "=\""))) (EApp (EMethodRef "display") (EVar "s"))) (ELit (LString "\"")))))
(DFunDef false "axisToAllow" ((PTuple (PVar "name") (PCon "PSet" (PCon "Some" (PVar "xs"))))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "={"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EVar "xs")))) (ELit (LString "}")))))
(DFunDef false "axisToAllow" (PWild) (EListLit))
(DTypeSig false "joinSemiTok" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinSemiTok" ((PVar "xs")) (EApp (EApp (EVar "joinWith") (ELit (LString ";"))) (EVar "xs")))
