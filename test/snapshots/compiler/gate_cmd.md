# META
source_lines=430
stages=DESUGAR,MARK
# SOURCE
{- gate_cmd.mdk — `medaka gate`, the gate-registry driver (#2176, epic #2182).

   This slice lands the FORMAT and the read path only: the registry schema
   (`test/gates.toml`), a reader for it, the selector language, and
   `medaka gate list [<selector>...] [--json]`.  `run`, `verify`, and
   `explain` (docs/ops/GATE-REGISTRY-DESIGN.md §3) are later slices; they are
   rejected here with a message that says so rather than silently doing
   nothing.

   Nothing about how any existing gate runs changes: `test/run_gates.sh` is
   still the only thing that executes a gate.  This command only *reads*.

   **Selector language** (design doc §3, "keep it boring"): a selector is a
   `field:pattern` token, where `field` is one of `name`/`area`/`project`/
   `tier` and `pattern` is a glob (`*`, `?`).  A bare token with no `field:`
   prefix is sugar for `name:<token>`.  Several selectors on one command line
   are a CONJUNCTION — a gate must match all of them.

   ⚠️ A selector that matches ZERO gates is a HARD ERROR, never a green empty
   list.  That mirrors `test/run_gates.sh:181` ("no gates match: …", exit 1)
   deliberately: a mistyped pattern that silently selects nothing is how a
   shard certifies coverage of a gate that never ran. -}

import toml.{Toml, parse, getString, getArray, tableCount, tableEntry}
import json.{Json, JString, jArray, jObject, stringify}
import driver.build_cmd.{envOr, defaultMedakaRoot}
import support.path.{joinPath}

-- ── The entry schema ────────────────────────────────────────────────────────
-- One `[[gate]]` table in `test/gates.toml` per gate.  Every field below is
-- REQUIRED to be present in the file, list fields included: an absent list is
-- an error, not an empty list.  `sources`/`corpus` are populated in a later
-- slice, so today they are present-and-empty on every entry — which is a
-- different fact from "this gate has no sources", and the reader must not
-- blur the two by defaulting.

public export data Gate =
  | Gate {
      name : String,
      area : String,
      project : String,
      tier : String,
      cost : String,
      kind : String,
      run : String,
      oracles : List String,
      sources : List String,
      corpus : List String,
      toolchain : List String,
    }

-- ── Registry reading ────────────────────────────────────────────────────────

-- Pull one required string field out of a `[[gate]]` sub-document.
reqStr : Int -> String -> Toml -> Result String String
reqStr i field entry = match getString field entry
  Some s => Ok s
  None => Err "gates.toml: [[gate]] #\{intToString i}: missing required string field '\{field}'"

-- Pull one required string-array field.  Present-but-empty is fine; absent is
-- not (see the schema note above).
reqArr : Int -> String -> Toml -> Result String (List String)
reqArr i field entry = match getArray field entry
  Some xs => Ok xs
  None => Err "gates.toml: [[gate]] #\{intToString i}: missing required array field '\{field}'"

readGate : Toml -> Int -> Result String Gate
readGate doc i =
  let e = tableEntry "gate" i doc
  do
    name <- reqStr i "name" e
    area <- reqStr i "area" e
    project <- reqStr i "project" e
    tier <- reqStr i "tier" e
    cost <- reqStr i "cost" e
    kind <- reqStr i "kind" e
    run <- reqStr i "run" e
    oracles <- reqArr i "oracles" e
    sources <- reqArr i "sources" e
    corpus <- reqArr i "corpus" e
    toolchain <- reqArr i "toolchain" e
    Ok
      Gate {
        name = name,
        area = area,
        project = project,
        tier = tier,
        cost = cost,
        kind = kind,
        run = run,
        oracles = oracles,
        sources = sources,
        corpus = corpus,
        toolchain = toolchain,
      }

readGatesFrom : Toml -> Int -> Int -> List Gate -> Result String (List Gate)
readGatesFrom doc i n acc
  | i >= n = Ok (reverseGates acc [])
  | otherwise = match readGate doc i
    Err m => Err m
    Ok g => readGatesFrom doc (i + 1) n (g::acc)

reverseGates : List Gate -> List Gate -> List Gate
reverseGates [] acc = acc
reverseGates (g::gs) acc = reverseGates gs (g::acc)

{- | Parse a registry's TOML source into its gate entries, in file order.
   An empty registry is an error: an unreadable or empty `gates.toml` must not
   present as "the repo has no gates". -}
export
parseRegistry : String -> Result String (List Gate)
parseRegistry src = match parse src
  Err m => Err "gates.toml: \{m}"
  Ok doc =>
    let n = tableCount "gate" doc
    if n == 0 then
      Err "gates.toml: no [[gate]] entries found"
    else
      readGatesFrom doc 0 n []

-- ── Glob matching ───────────────────────────────────────────────────────────
-- `*` matches any run of characters (path separators included — the registry's
-- names are opaque strings, not paths), `?` matches exactly one.  Everything
-- else is literal.  This is the same shape `run_gates.sh` gets from the shell.

globMatchAt : Array Char -> Int -> Int -> Array Char -> Int -> Int -> Bool
globMatchAt pat pi pn s si sn
  | pi >= pn = si >= sn
  | arrayGetUnsafe pi pat == '*' = globStar pat pi pn s si sn
  | si >= sn = False
  | arrayGetUnsafe pi pat == '?' = globMatchAt pat (pi + 1) pn s (si + 1) sn
  | arrayGetUnsafe pi pat == arrayGetUnsafe si s =
    globMatchAt pat (pi + 1) pn s (si + 1) sn
  | otherwise = False

-- `*` at `pi`: try consuming 0, 1, 2, … characters of the subject.
globStar : Array Char -> Int -> Int -> Array Char -> Int -> Int -> Bool
globStar pat pi pn s si sn
  | globMatchAt pat (pi + 1) pn s si sn = True
  | si >= sn = False
  | otherwise = globStar pat pi pn s (si + 1) sn

{- | Glob match, `*`/`?` only.

   > globMatch "diff_compiler_*" "diff_compiler_parse_result"
   True

   > globMatch "diff_compiler_*" "build_cmd"
   False

   A pattern with no metacharacter is an exact match:

   > globMatch "backend" "backend"
   True

   > globMatch "backend" "backends"
   False

   `*` crosses `/` — registry names are opaque strings, not paths:

   > globMatch "sqlite/*" "sqlite/test/select_oracle"
   True -}
export
globMatch : String -> String -> Bool
globMatch pat s =
  let p = stringToChars pat
  let subj = stringToChars s
  globMatchAt p 0 (arrayLength p) subj 0 (arrayLength subj)

-- ── Selectors ───────────────────────────────────────────────────────────────

public export data Selector =
  | SelName String
  | SelArea String
  | SelProject String
  | SelTier String
deriving (Eq, Debug)

-- The `field:` prefixes, checked longest-first is unnecessary here (no prefix
-- is a prefix of another).
selPrefix : String -> String -> Option String
selPrefix pre tok =
  let pn = stringLength pre
  if stringLength tok >= pn && stringSlice 0 pn tok == pre then
    Some (stringSlice pn (stringLength tok) tok)
  else
    None

hasColon : String -> Bool
hasColon tok = colonAt (stringToChars tok) 0

colonAt : Array Char -> Int -> Bool
colonAt arr i
  | i >= arrayLength arr = False
  | arrayGetUnsafe i arr == ':' = True
  | otherwise = colonAt arr (i + 1)

{- | Parse one selector token.  An unrecognized `field:` prefix is an ERROR,
   not a fall-through to `name:` — `aria:backend` selecting every gate whose
   *name* is `aria:backend` (i.e. none) would report "matched no gates" and
   send the reader hunting for a missing gate instead of a typo'd field.

   > parseSelector "name:diff_compiler_*" == Ok (SelName "diff_compiler_*")
   True

   > parseSelector "area:backend" == Ok (SelArea "backend")
   True

   A bare token is `name:` sugar:

   > parseSelector "build_cmd" == Ok (SelName "build_cmd")
   True

   An unknown field is rejected:

   > parseSelector "aria:backend"
   Err "unknown selector field in 'aria:backend' (expected name:, area:, project: or tier:)" -}
export
parseSelector : String -> Result String Selector
parseSelector tok = match selPrefix "name:" tok
  Some v => Ok (SelName v)
  None => match selPrefix "area:" tok
    Some v => Ok (SelArea v)
    None => match selPrefix "project:" tok
      Some v => Ok (SelProject v)
      None => match selPrefix "tier:" tok
        Some v => Ok (SelTier v)
        None =>
          if hasColon tok then
            Err "unknown selector field in '\{tok}' (expected name:, area:, project: or tier:)"
          else
            Ok (SelName tok)

{- | Does a gate satisfy one selector?  Every field is glob-matched, so a
   literal value is an exact match and `area:back*` also works. -}
export
matchesSelector : Selector -> Gate -> Bool
matchesSelector (SelName p) g = globMatch p g.name
matchesSelector (SelArea p) g = globMatch p g.area
matchesSelector (SelProject p) g = globMatch p g.project
matchesSelector (SelTier p) g = globMatch p g.tier

-- Conjunction: a gate must satisfy EVERY selector given.
matchesAll : List Selector -> Gate -> Bool
matchesAll [] _ = True
matchesAll (s::ss) g = matchesSelector s g && matchesAll ss g

{- | Select the gates matching every selector, preserving registry order. -}
export
selectGates : List Selector -> List Gate -> List Gate
selectGates _ [] = []
selectGates sels (g::gs)
  | matchesAll sels g = g :: selectGates sels gs
  | otherwise = selectGates sels gs

-- ── Rendering ───────────────────────────────────────────────────────────────

renderNames : List Gate -> String
renderNames [] = ""
renderNames (g::gs) = "\{g.name}\n" ++ renderNames gs

gateJson : Gate -> Json
gateJson g = jObject
  [
    ("name", JString g.name),
    ("area", JString g.area),
    ("project", JString g.project),
    ("tier", JString g.tier),
    ("cost", JString g.cost),
    ("kind", JString g.kind),
    ("run", JString g.run),
    ("oracles", jArray (map JString g.oracles)),
    ("sources", jArray (map JString g.sources)),
    ("corpus", jArray (map JString g.corpus)),
    ("toolchain", jArray (map JString g.toolchain)),
  ]

{- | The `--json` rendering: a JSON array of entry objects, in registry order,
   every schema field present. -}
export
renderJson : List Gate -> String
renderJson gs = stringify (jArray (map gateJson gs))

-- ── CLI ─────────────────────────────────────────────────────────────────────

export
gateHelpText : String
gateHelpText = stringConcat
  [
    "medaka gate — Query the gate registry (test/gates.toml)\n",
    "\n",
    "Usage:\n",
    "  medaka gate list [<selector>...] [--json] [--registry <path>]\n",
    "\n",
    "Selectors (conjunction — a gate must match all of them):\n",
    "  name:<glob>      gate name, e.g. name:diff_compiler_*\n",
    "  area:<glob>      semantic area, e.g. area:backend\n",
    "  project:<glob>   owning project, e.g. project:sqlite\n",
    "  tier:<glob>      merge | nightly | ondemand\n",
    "  <glob>           sugar for name:<glob>\n",
    "\n",
    "A selector matching zero gates is an error, not an empty list.\n",
    "\n",
    "  --json             emit the registry entries as JSON\n",
    "  --registry <path>  read this registry instead of <MEDAKA_ROOT>/test/gates.toml\n",
    "\n",
    "`gate run`, `gate verify` and `gate explain` are not implemented yet\n",
    "(see docs/ops/GATE-REGISTRY-DESIGN.md §3).\n",
  ]

-- Parsed `gate list` argv.
data ListArgs =
  | ListArgs { json : Bool, registry : Option String, selectors : List String }

parseListArgs : List String -> ListArgs -> Result String ListArgs
parseListArgs [] acc =
  Ok ListArgs { acc | selectors = reverseStrs acc.selectors [] }
parseListArgs ("--json"::rest) acc =
  parseListArgs rest ListArgs { acc | json = True }
parseListArgs ("--registry"::p::rest) acc =
  parseListArgs rest ListArgs { acc | registry = Some p }
parseListArgs ("--registry"::[]) _ =
  Err "medaka gate list: --registry needs a path"
parseListArgs (a::rest) acc
  | stringLength a > 0 && stringSlice 0 1 a == "-" =
    Err "medaka gate list: unknown flag: \{a}"
  | otherwise =
    parseListArgs rest ListArgs { acc | selectors = a::acc.selectors }

reverseStrs : List String -> List String -> List String
reverseStrs [] acc = acc
reverseStrs (x::xs) acc = reverseStrs xs (x::acc)

parseSelectors : List String -> List Selector -> Result String (List Selector)
parseSelectors [] acc = Ok (reverseSels acc [])
parseSelectors (t::ts) acc = match parseSelector t
  Err m => Err m
  Ok s => parseSelectors ts (s::acc)

reverseSels : List Selector -> List Selector -> List Selector
reverseSels [] acc = acc
reverseSels (s::ss) acc = reverseSels ss (s::acc)

-- `<MEDAKA_ROOT>/test/gates.toml` unless --registry overrides it.  MEDAKA_ROOT
-- resolves exe-relative like every other asset (build_cmd.defaultMedakaRoot),
-- so a relocated binary finds its own tree, not the cwd.
registryPath : Option String -> <IO> String
registryPath (Some p) = p
registryPath None =
  let root = envOr "MEDAKA_ROOT" defaultMedakaRoot
  joinPath (joinPath root "test") "gates.toml"

-- Every way `list` can end, as one value: the text to print, or the message to
-- die with.  Keeping this a `Result` rather than sprinkling `exit 1` gives the
-- command a SINGLE exit site (`emit`), so no error path can grow a
-- print-without-exit or an exit-without-print.
listOutput : List String -> <IO> Result String String
listOutput argv = match parseListArgs argv ListArgs { json = False, registry = None, selectors = [] }
  Err m => Err m
  Ok a => match parseSelectors a.selectors []
    Err m => Err "medaka gate list: \{m}"
    Ok sels =>
      let path = registryPath a.registry
      match readFile path
        Err m => Err "medaka gate list: cannot read registry: \{m}"
        Ok src => match parseRegistry src
          Err m => Err "medaka gate list: \{m}"
          Ok gates =>
            selectionOutput a.json a.selectors (selectGates sels gates) path

-- A selector that selects nothing is a HARD ERROR (see the module header).
selectionOutput : Bool -> List String -> List Gate -> String -> Result String String
selectionOutput _ tokens [] path
  | isEmptyStrs tokens = Err "medaka gate list: \{path} contains no gates"
  | otherwise = Err "medaka gate list: no gates match: \{joinSpace tokens}"
selectionOutput isJson _ (g::gs) _ =
  if isJson then
    Ok (renderJson (g::gs) ++ "\n")
  else
    Ok (renderNames (g::gs))

-- The command's only exit site.
emit : Result String String -> <IO> Unit
emit (Err msg) =
  let _ = ePutStrLn msg
  exit 1
emit (Ok out) = putStr out

isEmptyStrs : List String -> Bool
isEmptyStrs [] = True
isEmptyStrs _ = False

joinSpace : List String -> String
joinSpace [] = ""
joinSpace (x::[]) = x
joinSpace (x::xs) = "\{x} \{joinSpace xs}"

{- | `medaka gate <sub> …`.  Only `list` exists in this slice; `run`/`verify`/
   `explain` are named explicitly so an agent reaching for one gets told they
   are not here yet rather than a generic "unknown subcommand". -}
export
runGateCmd : List String -> <IO> Unit
runGateCmd [] = emit (Err "usage: medaka gate list [<selector>...] [--json]")
runGateCmd ("list"::rest) = emit (listOutput rest)
runGateCmd ("run"::_) =
  emit (Err
    "medaka gate run: not implemented yet (see docs/ops/GATE-REGISTRY-DESIGN.md §3)")
runGateCmd ("verify"::_) =
  emit (Err
    "medaka gate verify: not implemented yet (see docs/ops/GATE-REGISTRY-DESIGN.md §3)")
runGateCmd ("explain"::_) =
  emit (Err
    "medaka gate explain: not implemented yet (see docs/ops/GATE-REGISTRY-DESIGN.md §3)")
runGateCmd (sub::_) =
  emit (Err "medaka gate: unknown subcommand '\{sub}' (expected: list)")

-- ── Properties ──────────────────────────────────────────────────────────────

prop "a bare selector token is name: sugar" (n : Int) =
  parseSelector (intToString n) == Ok (SelName (intToString n))

prop "an explicit name: selector agrees with the bare form" (n : Int) =
  parseSelector ("name:" ++ intToString n) == parseSelector (intToString n)

prop "a literal glob matches itself and nothing longer" (n : Int) = globMatch (intToString n) (intToString n)
  && not (globMatch (intToString n) (intToString n ++ "x"))

prop "a trailing * matches any suffix" (n : Int) =
  globMatch "g*" ("g" ++ intToString n)
# DESUGAR
(DUse false (UseGroup ("toml") ((mem "Toml" false) (mem "parse" false) (mem "getString" false) (mem "getArray" false) (mem "tableCount" false) (mem "tableEntry" false))))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JString" false) (mem "jArray" false) (mem "jObject" false) (mem "stringify" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("support" "path") ((mem "joinPath" false))))
(DData Public "Gate" () ((variant "Gate" (ConNamed (field "name" (TyCon "String")) (field "area" (TyCon "String")) (field "project" (TyCon "String")) (field "tier" (TyCon "String")) (field "cost" (TyCon "String")) (field "kind" (TyCon "String")) (field "run" (TyCon "String")) (field "oracles" (TyApp (TyCon "List") (TyCon "String"))) (field "sources" (TyApp (TyCon "List") (TyCon "String"))) (field "corpus" (TyApp (TyCon "List") (TyCon "String"))) (field "toolchain" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "reqStr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "reqStr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getString") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Ok") (EVar "s"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required string field '"))) (EApp (EVar "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "reqArr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "reqArr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getArray") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "xs")) () (EApp (EVar "Ok") (EVar "xs"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required array field '"))) (EApp (EVar "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "readGate" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Gate")))))
(DFunDef false "readGate" ((PVar "doc") (PVar "i")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (EVar "i")) (EVar "doc"))) (DoExpr (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "name"))) (EVar "e"))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "area"))) (EVar "e"))) (ELam ((PVar "area")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "project"))) (EVar "e"))) (ELam ((PVar "project")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "tier"))) (EVar "e"))) (ELam ((PVar "tier")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "cost"))) (EVar "e"))) (ELam ((PVar "cost")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "kind"))) (EVar "e"))) (ELam ((PVar "kind")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "run"))) (EVar "e"))) (ELam ((PVar "run")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "oracles"))) (EVar "e"))) (ELam ((PVar "oracles")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "sources"))) (EVar "e"))) (ELam ((PVar "sources")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "corpus"))) (EVar "e"))) (ELam ((PVar "corpus")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "toolchain"))) (EVar "e"))) (ELam ((PVar "toolchain")) (EApp (EVar "Ok") (ERecordCreate "Gate" ((fa "name" (EVar "name")) (fa "area" (EVar "area")) (fa "project" (EVar "project")) (fa "tier" (EVar "tier")) (fa "cost" (EVar "cost")) (fa "kind" (EVar "kind")) (fa "run" (EVar "run")) (fa "oracles" (EVar "oracles")) (fa "sources" (EVar "sources")) (fa "corpus" (EVar "corpus")) (fa "toolchain" (EVar "toolchain"))))))))))))))))))))))))))))))
(DTypeSig false "readGatesFrom" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Gate"))))))))
(DFunDef false "readGatesFrom" ((PVar "doc") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Ok") (EApp (EApp (EVar "reverseGates") (EVar "acc")) (EListLit))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "readGate") (EVar "doc")) (EVar "i")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "g")) () (EApp (EApp (EApp (EApp (EVar "readGatesFrom") (EVar "doc")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "::" (EVar "g") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reverseGates" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "reverseGates" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseGates" ((PCons (PVar "g") (PVar "gs")) (PVar "acc")) (EApp (EApp (EVar "reverseGates") (EVar "gs")) (EBinOp "::" (EVar "g") (EVar "acc"))))
(DTypeSig true "parseRegistry" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "parseRegistry" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "doc")) () (EBlock (DoLet false false (PVar "n") (EApp (EApp (EVar "tableCount") (ELit (LString "gate"))) (EVar "doc"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Err") (ELit (LString "gates.toml: no [[gate]] entries found"))) (EApp (EApp (EApp (EApp (EVar "readGatesFrom") (EVar "doc")) (ELit (LInt 0))) (EVar "n")) (EListLit))))))))
(DTypeSig false "globMatchAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))))
(DFunDef false "globMatchAt" ((PVar "pat") (PVar "pi") (PVar "pn") (PVar "s") (PVar "si") (PVar "sn")) (EIf (EBinOp ">=" (EVar "pi") (EVar "pn")) (EBinOp ">=" (EVar "si") (EVar "sn")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pi")) (EVar "pat")) (ELit (LChar "*"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globStar") (EVar "pat")) (EVar "pi")) (EVar "pn")) (EVar "s")) (EVar "si")) (EVar "sn")) (EIf (EBinOp ">=" (EVar "si") (EVar "sn")) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pi")) (EVar "pat")) (ELit (LChar "?"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globMatchAt") (EVar "pat")) (EBinOp "+" (EVar "pi") (ELit (LInt 1)))) (EVar "pn")) (EVar "s")) (EBinOp "+" (EVar "si") (ELit (LInt 1)))) (EVar "sn")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pi")) (EVar "pat")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "si")) (EVar "s"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globMatchAt") (EVar "pat")) (EBinOp "+" (EVar "pi") (ELit (LInt 1)))) (EVar "pn")) (EVar "s")) (EBinOp "+" (EVar "si") (ELit (LInt 1)))) (EVar "sn")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "globStar" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))))
(DFunDef false "globStar" ((PVar "pat") (PVar "pi") (PVar "pn") (PVar "s") (PVar "si") (PVar "sn")) (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globMatchAt") (EVar "pat")) (EBinOp "+" (EVar "pi") (ELit (LInt 1)))) (EVar "pn")) (EVar "s")) (EVar "si")) (EVar "sn")) (EVar "True") (EIf (EBinOp ">=" (EVar "si") (EVar "sn")) (EVar "False") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globStar") (EVar "pat")) (EVar "pi")) (EVar "pn")) (EVar "s")) (EBinOp "+" (EVar "si") (ELit (LInt 1)))) (EVar "sn")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "globMatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "globMatch" ((PVar "pat") (PVar "s")) (EBlock (DoLet false false (PVar "p") (EApp (EVar "stringToChars") (EVar "pat"))) (DoLet false false (PVar "subj") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globMatchAt") (EVar "p")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "p"))) (EVar "subj")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "subj"))))))
(DData Public "Selector" () ((variant "SelName" (ConPos (TyCon "String"))) (variant "SelArea" (ConPos (TyCon "String"))) (variant "SelProject" (ConPos (TyCon "String"))) (variant "SelTier" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "Selector")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "SelName" (PVar "__a0")) (PCon "SelName" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "SelArea" (PVar "__a0")) (PCon "SelArea" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "SelProject" (PVar "__a0")) (PCon "SelProject" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "SelTier" (PVar "__a0")) (PCon "SelTier" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Selector")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "SelName" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SelName ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "SelArea" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SelArea ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "SelProject" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SelProject ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0"))))) (arm (PCon "SelTier" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SelTier ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))))))))
(DTypeSig false "selPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "selPrefix" ((PVar "pre") (PVar "tok")) (EBlock (DoLet false false (PVar "pn") (EApp (EVar "stringLength") (EVar "pre"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "tok")) (EVar "pn")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "pn")) (EVar "tok")) (EVar "pre"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EVar "pn")) (EApp (EVar "stringLength") (EVar "tok"))) (EVar "tok"))) (EVar "None")))))
(DTypeSig false "hasColon" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasColon" ((PVar "tok")) (EApp (EApp (EVar "colonAt") (EApp (EVar "stringToChars") (EVar "tok"))) (ELit (LInt 0))))
(DTypeSig false "colonAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "colonAt" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar ":"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "colonAt") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "parseSelector" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Selector"))))
(DFunDef false "parseSelector" ((PVar "tok")) (EMatch (EApp (EApp (EVar "selPrefix") (ELit (LString "name:"))) (EVar "tok")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "Ok") (EApp (EVar "SelName") (EVar "v")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "selPrefix") (ELit (LString "area:"))) (EVar "tok")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "Ok") (EApp (EVar "SelArea") (EVar "v")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "selPrefix") (ELit (LString "project:"))) (EVar "tok")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "Ok") (EApp (EVar "SelProject") (EVar "v")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "selPrefix") (ELit (LString "tier:"))) (EVar "tok")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "Ok") (EApp (EVar "SelTier") (EVar "v")))) (arm (PCon "None") () (EIf (EApp (EVar "hasColon") (EVar "tok")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "unknown selector field in '")) (EApp (EVar "display") (EVar "tok"))) (ELit (LString "' (expected name:, area:, project: or tier:)")))) (EApp (EVar "Ok") (EApp (EVar "SelName") (EVar "tok")))))))))))))
(DTypeSig true "matchesSelector" (TyFun (TyCon "Selector") (TyFun (TyCon "Gate") (TyCon "Bool"))))
(DFunDef false "matchesSelector" ((PCon "SelName" (PVar "p")) (PVar "g")) (EApp (EApp (EVar "globMatch") (EVar "p")) (EFieldAccess (EVar "g") "name")))
(DFunDef false "matchesSelector" ((PCon "SelArea" (PVar "p")) (PVar "g")) (EApp (EApp (EVar "globMatch") (EVar "p")) (EFieldAccess (EVar "g") "area")))
(DFunDef false "matchesSelector" ((PCon "SelProject" (PVar "p")) (PVar "g")) (EApp (EApp (EVar "globMatch") (EVar "p")) (EFieldAccess (EVar "g") "project")))
(DFunDef false "matchesSelector" ((PCon "SelTier" (PVar "p")) (PVar "g")) (EApp (EApp (EVar "globMatch") (EVar "p")) (EFieldAccess (EVar "g") "tier")))
(DTypeSig false "matchesAll" (TyFun (TyApp (TyCon "List") (TyCon "Selector")) (TyFun (TyCon "Gate") (TyCon "Bool"))))
(DFunDef false "matchesAll" ((PList) PWild) (EVar "True"))
(DFunDef false "matchesAll" ((PCons (PVar "s") (PVar "ss")) (PVar "g")) (EBinOp "&&" (EApp (EApp (EVar "matchesSelector") (EVar "s")) (EVar "g")) (EApp (EApp (EVar "matchesAll") (EVar "ss")) (EVar "g"))))
(DTypeSig true "selectGates" (TyFun (TyApp (TyCon "List") (TyCon "Selector")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "selectGates" (PWild (PList)) (EListLit))
(DFunDef false "selectGates" ((PVar "sels") (PCons (PVar "g") (PVar "gs"))) (EIf (EApp (EApp (EVar "matchesAll") (EVar "sels")) (EVar "g")) (EBinOp "::" (EVar "g") (EApp (EApp (EVar "selectGates") (EVar "sels")) (EVar "gs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "selectGates") (EVar "sels")) (EVar "gs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "renderNames" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "String")))
(DFunDef false "renderNames" ((PList)) (ELit (LString "")))
(DFunDef false "renderNames" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "\n"))) (EApp (EVar "renderNames") (EVar "gs"))))
(DTypeSig false "gateJson" (TyFun (TyCon "Gate") (TyCon "Json")))
(DFunDef false "gateJson" ((PVar "g")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "name"))) (ETuple (ELit (LString "area")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "area"))) (ETuple (ELit (LString "project")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "project"))) (ETuple (ELit (LString "tier")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "tier"))) (ETuple (ELit (LString "cost")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "cost"))) (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "kind"))) (ETuple (ELit (LString "run")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "run"))) (ETuple (ELit (LString "oracles")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EFieldAccess (EVar "g") "oracles")))) (ETuple (ELit (LString "sources")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EFieldAccess (EVar "g") "sources")))) (ETuple (ELit (LString "corpus")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EFieldAccess (EVar "g") "corpus")))) (ETuple (ELit (LString "toolchain")) (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "JString")) (EFieldAccess (EVar "g") "toolchain")))))))
(DTypeSig true "renderJson" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "String")))
(DFunDef false "renderJson" ((PVar "gs")) (EApp (EVar "stringify") (EApp (EVar "jArray") (EApp (EApp (EVar "map") (EVar "gateJson")) (EVar "gs")))))
(DTypeSig true "gateHelpText" (TyCon "String"))
(DFunDef false "gateHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka gate — Query the gate registry (test/gates.toml)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka gate list [<selector>...] [--json] [--registry <path>]\n")) (ELit (LString "\n")) (ELit (LString "Selectors (conjunction — a gate must match all of them):\n")) (ELit (LString "  name:<glob>      gate name, e.g. name:diff_compiler_*\n")) (ELit (LString "  area:<glob>      semantic area, e.g. area:backend\n")) (ELit (LString "  project:<glob>   owning project, e.g. project:sqlite\n")) (ELit (LString "  tier:<glob>      merge | nightly | ondemand\n")) (ELit (LString "  <glob>           sugar for name:<glob>\n")) (ELit (LString "\n")) (ELit (LString "A selector matching zero gates is an error, not an empty list.\n")) (ELit (LString "\n")) (ELit (LString "  --json             emit the registry entries as JSON\n")) (ELit (LString "  --registry <path>  read this registry instead of <MEDAKA_ROOT>/test/gates.toml\n")) (ELit (LString "\n")) (ELit (LString "`gate run`, `gate verify` and `gate explain` are not implemented yet\n")) (ELit (LString "(see docs/ops/GATE-REGISTRY-DESIGN.md §3).\n")))))
(DData Private "ListArgs" () ((variant "ListArgs" (ConNamed (field "json" (TyCon "Bool")) (field "registry" (TyApp (TyCon "Option") (TyCon "String"))) (field "selectors" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "parseListArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ListArgs") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "ListArgs")))))
(DFunDef false "parseListArgs" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVariantUpdate "ListArgs" (EVar "acc") ((fa "selectors" (EApp (EApp (EVar "reverseStrs") (EFieldAccess (EVar "acc") "selectors")) (EListLit)))))))
(DFunDef false "parseListArgs" ((PCons (PLit (LString "--json")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "parseListArgs") (EVar "rest")) (EVariantUpdate "ListArgs" (EVar "acc") ((fa "json" (EVar "True"))))))
(DFunDef false "parseListArgs" ((PCons (PLit (LString "--registry")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseListArgs") (EVar "rest")) (EVariantUpdate "ListArgs" (EVar "acc") ((fa "registry" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseListArgs" ((PCons (PLit (LString "--registry")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate list: --registry needs a path"))))
(DFunDef false "parseListArgs" ((PCons (PVar "a") (PVar "rest")) (PVar "acc")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "a")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "a")) (ELit (LString "-")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: unknown flag: ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "parseListArgs") (EVar "rest")) (EVariantUpdate "ListArgs" (EVar "acc") ((fa "selectors" (EBinOp "::" (EVar "a") (EFieldAccess (EVar "acc") "selectors")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reverseStrs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reverseStrs" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseStrs" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "reverseStrs") (EVar "xs")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DTypeSig false "parseSelectors" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Selector")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Selector"))))))
(DFunDef false "parseSelectors" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EApp (EApp (EVar "reverseSels") (EVar "acc")) (EListLit))))
(DFunDef false "parseSelectors" ((PCons (PVar "t") (PVar "ts")) (PVar "acc")) (EMatch (EApp (EVar "parseSelector") (EVar "t")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "s")) () (EApp (EApp (EVar "parseSelectors") (EVar "ts")) (EBinOp "::" (EVar "s") (EVar "acc"))))))
(DTypeSig false "reverseSels" (TyFun (TyApp (TyCon "List") (TyCon "Selector")) (TyFun (TyApp (TyCon "List") (TyCon "Selector")) (TyApp (TyCon "List") (TyCon "Selector")))))
(DFunDef false "reverseSels" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseSels" ((PCons (PVar "s") (PVar "ss")) (PVar "acc")) (EApp (EApp (EVar "reverseSels") (EVar "ss")) (EBinOp "::" (EVar "s") (EVar "acc"))))
(DTypeSig false "registryPath" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "registryPath" ((PCon "Some" (PVar "p"))) (EVar "p"))
(DFunDef false "registryPath" ((PCon "None")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoExpr (EApp (EApp (EVar "joinPath") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "test")))) (ELit (LString "gates.toml"))))))
(DTypeSig false "listOutput" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "listOutput" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseListArgs") (EVar "argv")) (ERecordCreate "ListArgs" ((fa "json" (EVar "False")) (fa "registry" (EVar "None")) (fa "selectors" (EListLit))))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EApp (EApp (EVar "parseSelectors") (EFieldAccess (EVar "a") "selectors")) (EListLit)) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "sels")) () (EBlock (DoLet false false (PVar "path") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: cannot read registry: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseRegistry") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "gates")) () (EApp (EApp (EApp (EApp (EVar "selectionOutput") (EFieldAccess (EVar "a") "json")) (EFieldAccess (EVar "a") "selectors")) (EApp (EApp (EVar "selectGates") (EVar "sels")) (EVar "gates"))) (EVar "path")))))))))))))
(DTypeSig false "selectionOutput" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "selectionOutput" (PWild (PVar "tokens") (PList) (PVar "path")) (EIf (EApp (EVar "isEmptyStrs") (EVar "tokens")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: ")) (EApp (EVar "display") (EVar "path"))) (ELit (LString " contains no gates")))) (EIf (EVar "otherwise") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: no gates match: ")) (EApp (EVar "display") (EApp (EVar "joinSpace") (EVar "tokens")))) (ELit (LString "")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "selectionOutput" ((PVar "isJson") PWild (PCons (PVar "g") (PVar "gs")) PWild) (EIf (EVar "isJson") (EApp (EVar "Ok") (EBinOp "++" (EApp (EVar "renderJson") (EBinOp "::" (EVar "g") (EVar "gs"))) (ELit (LString "\n")))) (EApp (EVar "Ok") (EApp (EVar "renderNames") (EBinOp "::" (EVar "g") (EVar "gs"))))))
(DTypeSig false "emit" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "emit" ((PCon "Err" (PVar "msg"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))
(DFunDef false "emit" ((PCon "Ok" (PVar "out"))) (EApp (EVar "putStr") (EVar "out")))
(DTypeSig false "isEmptyStrs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "isEmptyStrs" ((PList)) (EVar "True"))
(DFunDef false "isEmptyStrs" (PWild) (EVar "False"))
(DTypeSig false "joinSpace" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinSpace" ((PList)) (ELit (LString "")))
(DFunDef false "joinSpace" ((PCons (PVar "x") (PList))) (EVar "x"))
(DFunDef false "joinSpace" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "joinSpace") (EVar "xs")))) (ELit (LString ""))))
(DTypeSig true "runGateCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runGateCmd" ((PList)) (EApp (EVar "emit") (EApp (EVar "Err") (ELit (LString "usage: medaka gate list [<selector>...] [--json]")))))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "list")) (PVar "rest"))) (EApp (EVar "emit") (EApp (EVar "listOutput") (EVar "rest"))))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "run")) PWild)) (EApp (EVar "emit") (EApp (EVar "Err") (ELit (LString "medaka gate run: not implemented yet (see docs/ops/GATE-REGISTRY-DESIGN.md §3)")))))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "verify")) PWild)) (EApp (EVar "emit") (EApp (EVar "Err") (ELit (LString "medaka gate verify: not implemented yet (see docs/ops/GATE-REGISTRY-DESIGN.md §3)")))))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "explain")) PWild)) (EApp (EVar "emit") (EApp (EVar "Err") (ELit (LString "medaka gate explain: not implemented yet (see docs/ops/GATE-REGISTRY-DESIGN.md §3)")))))
(DFunDef false "runGateCmd" ((PCons (PVar "sub") PWild)) (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate: unknown subcommand '")) (EApp (EVar "display") (EVar "sub"))) (ELit (LString "' (expected: list)"))))))
(DProp false "a bare selector token is name: sugar" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parseSelector") (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "Ok") (EApp (EVar "SelName") (EApp (EVar "intToString") (EVar "n"))))))
(DProp false "an explicit name: selector agrees with the bare form" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parseSelector") (EBinOp "++" (ELit (LString "name:")) (EApp (EVar "intToString") (EVar "n")))) (EApp (EVar "parseSelector") (EApp (EVar "intToString") (EVar "n")))))
(DProp false "a literal glob matches itself and nothing longer" ((pp "n" (TyCon "Int"))) (EBinOp "&&" (EApp (EApp (EVar "globMatch") (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "not") (EApp (EApp (EVar "globMatch") (EApp (EVar "intToString") (EVar "n"))) (EBinOp "++" (EApp (EVar "intToString") (EVar "n")) (ELit (LString "x")))))))
(DProp false "a trailing * matches any suffix" ((pp "n" (TyCon "Int"))) (EApp (EApp (EVar "globMatch") (ELit (LString "g*"))) (EBinOp "++" (ELit (LString "g")) (EApp (EVar "intToString") (EVar "n")))))
# MARK
(DUse false (UseGroup ("toml") ((mem "Toml" false) (mem "parse" false) (mem "getString" false) (mem "getArray" false) (mem "tableCount" false) (mem "tableEntry" false))))
(DUse false (UseGroup ("json") ((mem "Json" false) (mem "JString" false) (mem "jArray" false) (mem "jObject" false) (mem "stringify" false))))
(DUse false (UseGroup ("driver" "build_cmd") ((mem "envOr" false) (mem "defaultMedakaRoot" false))))
(DUse false (UseGroup ("support" "path") ((mem "joinPath" false))))
(DData Public "Gate" () ((variant "Gate" (ConNamed (field "name" (TyCon "String")) (field "area" (TyCon "String")) (field "project" (TyCon "String")) (field "tier" (TyCon "String")) (field "cost" (TyCon "String")) (field "kind" (TyCon "String")) (field "run" (TyCon "String")) (field "oracles" (TyApp (TyCon "List") (TyCon "String"))) (field "sources" (TyApp (TyCon "List") (TyCon "String"))) (field "corpus" (TyApp (TyCon "List") (TyCon "String"))) (field "toolchain" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "reqStr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))
(DFunDef false "reqStr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getString") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "s")) () (EApp (EVar "Ok") (EVar "s"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required string field '"))) (EApp (EMethodRef "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "reqArr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Toml") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "reqArr" ((PVar "i") (PVar "field") (PVar "entry")) (EMatch (EApp (EApp (EVar "getArray") (EVar "field")) (EVar "entry")) (arm (PCon "Some" (PVar "xs")) () (EApp (EVar "Ok") (EVar "xs"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: [[gate]] #")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString ": missing required array field '"))) (EApp (EMethodRef "display") (EVar "field"))) (ELit (LString "'")))))))
(DTypeSig false "readGate" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Gate")))))
(DFunDef false "readGate" ((PVar "doc") (PVar "i")) (EBlock (DoLet false false (PVar "e") (EApp (EApp (EApp (EVar "tableEntry") (ELit (LString "gate"))) (EVar "i")) (EVar "doc"))) (DoExpr (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "name"))) (EVar "e"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "area"))) (EVar "e"))) (ELam ((PVar "area")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "project"))) (EVar "e"))) (ELam ((PVar "project")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "tier"))) (EVar "e"))) (ELam ((PVar "tier")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "cost"))) (EVar "e"))) (ELam ((PVar "cost")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "kind"))) (EVar "e"))) (ELam ((PVar "kind")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqStr") (EVar "i")) (ELit (LString "run"))) (EVar "e"))) (ELam ((PVar "run")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "oracles"))) (EVar "e"))) (ELam ((PVar "oracles")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "sources"))) (EVar "e"))) (ELam ((PVar "sources")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "corpus"))) (EVar "e"))) (ELam ((PVar "corpus")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "reqArr") (EVar "i")) (ELit (LString "toolchain"))) (EVar "e"))) (ELam ((PVar "toolchain")) (EApp (EVar "Ok") (ERecordCreate "Gate" ((fa "name" (EVar "name")) (fa "area" (EVar "area")) (fa "project" (EVar "project")) (fa "tier" (EVar "tier")) (fa "cost" (EVar "cost")) (fa "kind" (EVar "kind")) (fa "run" (EVar "run")) (fa "oracles" (EVar "oracles")) (fa "sources" (EVar "sources")) (fa "corpus" (EVar "corpus")) (fa "toolchain" (EVar "toolchain"))))))))))))))))))))))))))))))
(DTypeSig false "readGatesFrom" (TyFun (TyCon "Toml") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Gate"))))))))
(DFunDef false "readGatesFrom" ((PVar "doc") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Ok") (EApp (EApp (EVar "reverseGates") (EVar "acc")) (EListLit))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "readGate") (EVar "doc")) (EVar "i")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "g")) () (EApp (EApp (EApp (EApp (EVar "readGatesFrom") (EVar "doc")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "::" (EVar "g") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reverseGates" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "reverseGates" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseGates" ((PCons (PVar "g") (PVar "gs")) (PVar "acc")) (EApp (EApp (EVar "reverseGates") (EVar "gs")) (EBinOp "::" (EVar "g") (EVar "acc"))))
(DTypeSig true "parseRegistry" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "parseRegistry" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gates.toml: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "doc")) () (EBlock (DoLet false false (PVar "n") (EApp (EApp (EVar "tableCount") (ELit (LString "gate"))) (EVar "doc"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Err") (ELit (LString "gates.toml: no [[gate]] entries found"))) (EApp (EApp (EApp (EApp (EVar "readGatesFrom") (EVar "doc")) (ELit (LInt 0))) (EVar "n")) (EListLit))))))))
(DTypeSig false "globMatchAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))))
(DFunDef false "globMatchAt" ((PVar "pat") (PVar "pi") (PVar "pn") (PVar "s") (PVar "si") (PVar "sn")) (EIf (EBinOp ">=" (EVar "pi") (EVar "pn")) (EBinOp ">=" (EVar "si") (EVar "sn")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pi")) (EVar "pat")) (ELit (LChar "*"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globStar") (EVar "pat")) (EVar "pi")) (EVar "pn")) (EVar "s")) (EVar "si")) (EVar "sn")) (EIf (EBinOp ">=" (EVar "si") (EVar "sn")) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pi")) (EVar "pat")) (ELit (LChar "?"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globMatchAt") (EVar "pat")) (EBinOp "+" (EVar "pi") (ELit (LInt 1)))) (EVar "pn")) (EVar "s")) (EBinOp "+" (EVar "si") (ELit (LInt 1)))) (EVar "sn")) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pi")) (EVar "pat")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "si")) (EVar "s"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globMatchAt") (EVar "pat")) (EBinOp "+" (EVar "pi") (ELit (LInt 1)))) (EVar "pn")) (EVar "s")) (EBinOp "+" (EVar "si") (ELit (LInt 1)))) (EVar "sn")) (EIf (EVar "otherwise") (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "globStar" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))))
(DFunDef false "globStar" ((PVar "pat") (PVar "pi") (PVar "pn") (PVar "s") (PVar "si") (PVar "sn")) (EIf (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globMatchAt") (EVar "pat")) (EBinOp "+" (EVar "pi") (ELit (LInt 1)))) (EVar "pn")) (EVar "s")) (EVar "si")) (EVar "sn")) (EVar "True") (EIf (EBinOp ">=" (EVar "si") (EVar "sn")) (EVar "False") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globStar") (EVar "pat")) (EVar "pi")) (EVar "pn")) (EVar "s")) (EBinOp "+" (EVar "si") (ELit (LInt 1)))) (EVar "sn")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "globMatch" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "globMatch" ((PVar "pat") (PVar "s")) (EBlock (DoLet false false (PVar "p") (EApp (EVar "stringToChars") (EVar "pat"))) (DoLet false false (PVar "subj") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "globMatchAt") (EVar "p")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "p"))) (EVar "subj")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "subj"))))))
(DData Public "Selector" () ((variant "SelName" (ConPos (TyCon "String"))) (variant "SelArea" (ConPos (TyCon "String"))) (variant "SelProject" (ConPos (TyCon "String"))) (variant "SelTier" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "Selector")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "SelName" (PVar "__a0")) (PCon "SelName" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "SelArea" (PVar "__a0")) (PCon "SelArea" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "SelProject" (PVar "__a0")) (PCon "SelProject" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "SelTier" (PVar "__a0")) (PCon "SelTier" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "Selector")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "SelName" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SelName ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "SelArea" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SelArea ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "SelProject" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SelProject ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0"))))) (arm (PCon "SelTier" (PVar "__a0")) () (EBinOp "++" (ELit (LString "SelTier ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))))))))
(DTypeSig false "selPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "selPrefix" ((PVar "pre") (PVar "tok")) (EBlock (DoLet false false (PVar "pn") (EApp (EVar "stringLength") (EVar "pre"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "tok")) (EVar "pn")) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "pn")) (EVar "tok")) (EVar "pre"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EVar "pn")) (EApp (EVar "stringLength") (EVar "tok"))) (EVar "tok"))) (EVar "None")))))
(DTypeSig false "hasColon" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "hasColon" ((PVar "tok")) (EApp (EApp (EVar "colonAt") (EApp (EVar "stringToChars") (EVar "tok"))) (ELit (LInt 0))))
(DTypeSig false "colonAt" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "colonAt" ((PVar "arr") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "False") (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr")) (ELit (LChar ":"))) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "colonAt") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "parseSelector" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "Selector"))))
(DFunDef false "parseSelector" ((PVar "tok")) (EMatch (EApp (EApp (EVar "selPrefix") (ELit (LString "name:"))) (EVar "tok")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "Ok") (EApp (EVar "SelName") (EVar "v")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "selPrefix") (ELit (LString "area:"))) (EVar "tok")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "Ok") (EApp (EVar "SelArea") (EVar "v")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "selPrefix") (ELit (LString "project:"))) (EVar "tok")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "Ok") (EApp (EVar "SelProject") (EVar "v")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "selPrefix") (ELit (LString "tier:"))) (EVar "tok")) (arm (PCon "Some" (PVar "v")) () (EApp (EVar "Ok") (EApp (EVar "SelTier") (EVar "v")))) (arm (PCon "None") () (EIf (EApp (EVar "hasColon") (EVar "tok")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "unknown selector field in '")) (EApp (EMethodRef "display") (EVar "tok"))) (ELit (LString "' (expected name:, area:, project: or tier:)")))) (EApp (EVar "Ok") (EApp (EVar "SelName") (EVar "tok")))))))))))))
(DTypeSig true "matchesSelector" (TyFun (TyCon "Selector") (TyFun (TyCon "Gate") (TyCon "Bool"))))
(DFunDef false "matchesSelector" ((PCon "SelName" (PVar "p")) (PVar "g")) (EApp (EApp (EVar "globMatch") (EVar "p")) (EFieldAccess (EVar "g") "name")))
(DFunDef false "matchesSelector" ((PCon "SelArea" (PVar "p")) (PVar "g")) (EApp (EApp (EVar "globMatch") (EVar "p")) (EFieldAccess (EVar "g") "area")))
(DFunDef false "matchesSelector" ((PCon "SelProject" (PVar "p")) (PVar "g")) (EApp (EApp (EVar "globMatch") (EVar "p")) (EFieldAccess (EVar "g") "project")))
(DFunDef false "matchesSelector" ((PCon "SelTier" (PVar "p")) (PVar "g")) (EApp (EApp (EVar "globMatch") (EVar "p")) (EFieldAccess (EVar "g") "tier")))
(DTypeSig false "matchesAll" (TyFun (TyApp (TyCon "List") (TyCon "Selector")) (TyFun (TyCon "Gate") (TyCon "Bool"))))
(DFunDef false "matchesAll" ((PList) PWild) (EVar "True"))
(DFunDef false "matchesAll" ((PCons (PVar "s") (PVar "ss")) (PVar "g")) (EBinOp "&&" (EApp (EApp (EVar "matchesSelector") (EVar "s")) (EVar "g")) (EApp (EApp (EVar "matchesAll") (EVar "ss")) (EVar "g"))))
(DTypeSig true "selectGates" (TyFun (TyApp (TyCon "List") (TyCon "Selector")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "selectGates" (PWild (PList)) (EListLit))
(DFunDef false "selectGates" ((PVar "sels") (PCons (PVar "g") (PVar "gs"))) (EIf (EApp (EApp (EVar "matchesAll") (EVar "sels")) (EVar "g")) (EBinOp "::" (EVar "g") (EApp (EApp (EVar "selectGates") (EVar "sels")) (EVar "gs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "selectGates") (EVar "sels")) (EVar "gs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "renderNames" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "String")))
(DFunDef false "renderNames" ((PList)) (ELit (LString "")))
(DFunDef false "renderNames" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "\n"))) (EApp (EVar "renderNames") (EVar "gs"))))
(DTypeSig false "gateJson" (TyFun (TyCon "Gate") (TyCon "Json")))
(DFunDef false "gateJson" ((PVar "g")) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "name")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "name"))) (ETuple (ELit (LString "area")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "area"))) (ETuple (ELit (LString "project")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "project"))) (ETuple (ELit (LString "tier")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "tier"))) (ETuple (ELit (LString "cost")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "cost"))) (ETuple (ELit (LString "kind")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "kind"))) (ETuple (ELit (LString "run")) (EApp (EVar "JString") (EFieldAccess (EVar "g") "run"))) (ETuple (ELit (LString "oracles")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EFieldAccess (EVar "g") "oracles")))) (ETuple (ELit (LString "sources")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EFieldAccess (EVar "g") "sources")))) (ETuple (ELit (LString "corpus")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EFieldAccess (EVar "g") "corpus")))) (ETuple (ELit (LString "toolchain")) (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "JString")) (EFieldAccess (EVar "g") "toolchain")))))))
(DTypeSig true "renderJson" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyCon "String")))
(DFunDef false "renderJson" ((PVar "gs")) (EApp (EVar "stringify") (EApp (EVar "jArray") (EApp (EApp (EMethodRef "map") (EVar "gateJson")) (EVar "gs")))))
(DTypeSig true "gateHelpText" (TyCon "String"))
(DFunDef false "gateHelpText" () (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka gate — Query the gate registry (test/gates.toml)\n")) (ELit (LString "\n")) (ELit (LString "Usage:\n")) (ELit (LString "  medaka gate list [<selector>...] [--json] [--registry <path>]\n")) (ELit (LString "\n")) (ELit (LString "Selectors (conjunction — a gate must match all of them):\n")) (ELit (LString "  name:<glob>      gate name, e.g. name:diff_compiler_*\n")) (ELit (LString "  area:<glob>      semantic area, e.g. area:backend\n")) (ELit (LString "  project:<glob>   owning project, e.g. project:sqlite\n")) (ELit (LString "  tier:<glob>      merge | nightly | ondemand\n")) (ELit (LString "  <glob>           sugar for name:<glob>\n")) (ELit (LString "\n")) (ELit (LString "A selector matching zero gates is an error, not an empty list.\n")) (ELit (LString "\n")) (ELit (LString "  --json             emit the registry entries as JSON\n")) (ELit (LString "  --registry <path>  read this registry instead of <MEDAKA_ROOT>/test/gates.toml\n")) (ELit (LString "\n")) (ELit (LString "`gate run`, `gate verify` and `gate explain` are not implemented yet\n")) (ELit (LString "(see docs/ops/GATE-REGISTRY-DESIGN.md §3).\n")))))
(DData Private "ListArgs" () ((variant "ListArgs" (ConNamed (field "json" (TyCon "Bool")) (field "registry" (TyApp (TyCon "Option") (TyCon "String"))) (field "selectors" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig false "parseListArgs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "ListArgs") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "ListArgs")))))
(DFunDef false "parseListArgs" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EVariantUpdate "ListArgs" (EVar "acc") ((fa "selectors" (EApp (EApp (EVar "reverseStrs") (EFieldAccess (EVar "acc") "selectors")) (EListLit)))))))
(DFunDef false "parseListArgs" ((PCons (PLit (LString "--json")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "parseListArgs") (EVar "rest")) (EVariantUpdate "ListArgs" (EVar "acc") ((fa "json" (EVar "True"))))))
(DFunDef false "parseListArgs" ((PCons (PLit (LString "--registry")) (PCons (PVar "p") (PVar "rest"))) (PVar "acc")) (EApp (EApp (EVar "parseListArgs") (EVar "rest")) (EVariantUpdate "ListArgs" (EVar "acc") ((fa "registry" (EApp (EVar "Some") (EVar "p")))))))
(DFunDef false "parseListArgs" ((PCons (PLit (LString "--registry")) (PList)) PWild) (EApp (EVar "Err") (ELit (LString "medaka gate list: --registry needs a path"))))
(DFunDef false "parseListArgs" ((PCons (PVar "a") (PVar "rest")) (PVar "acc")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "a")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "a")) (ELit (LString "-")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: unknown flag: ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "parseListArgs") (EVar "rest")) (EVariantUpdate "ListArgs" (EVar "acc") ((fa "selectors" (EBinOp "::" (EVar "a") (EFieldAccess (EVar "acc") "selectors")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reverseStrs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reverseStrs" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseStrs" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "reverseStrs") (EVar "xs")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DTypeSig false "parseSelectors" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Selector")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Selector"))))))
(DFunDef false "parseSelectors" ((PList) (PVar "acc")) (EApp (EVar "Ok") (EApp (EApp (EVar "reverseSels") (EVar "acc")) (EListLit))))
(DFunDef false "parseSelectors" ((PCons (PVar "t") (PVar "ts")) (PVar "acc")) (EMatch (EApp (EVar "parseSelector") (EVar "t")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "s")) () (EApp (EApp (EVar "parseSelectors") (EVar "ts")) (EBinOp "::" (EVar "s") (EVar "acc"))))))
(DTypeSig false "reverseSels" (TyFun (TyApp (TyCon "List") (TyCon "Selector")) (TyFun (TyApp (TyCon "List") (TyCon "Selector")) (TyApp (TyCon "List") (TyCon "Selector")))))
(DFunDef false "reverseSels" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseSels" ((PCons (PVar "s") (PVar "ss")) (PVar "acc")) (EApp (EApp (EVar "reverseSels") (EVar "ss")) (EBinOp "::" (EVar "s") (EVar "acc"))))
(DTypeSig false "registryPath" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "registryPath" ((PCon "Some" (PVar "p"))) (EVar "p"))
(DFunDef false "registryPath" ((PCon "None")) (EBlock (DoLet false false (PVar "root") (EApp (EApp (EVar "envOr") (ELit (LString "MEDAKA_ROOT"))) (EVar "defaultMedakaRoot"))) (DoExpr (EApp (EApp (EVar "joinPath") (EApp (EApp (EVar "joinPath") (EVar "root")) (ELit (LString "test")))) (ELit (LString "gates.toml"))))))
(DTypeSig false "listOutput" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))
(DFunDef false "listOutput" ((PVar "argv")) (EMatch (EApp (EApp (EVar "parseListArgs") (EVar "argv")) (ERecordCreate "ListArgs" ((fa "json" (EVar "False")) (fa "registry" (EVar "None")) (fa "selectors" (EListLit))))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "a")) () (EMatch (EApp (EApp (EVar "parseSelectors") (EFieldAccess (EVar "a") "selectors")) (EListLit)) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "sels")) () (EBlock (DoLet false false (PVar "path") (EApp (EVar "registryPath") (EFieldAccess (EVar "a") "registry"))) (DoExpr (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: cannot read registry: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "src")) () (EMatch (EApp (EVar "parseRegistry") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "gates")) () (EApp (EApp (EApp (EApp (EVar "selectionOutput") (EFieldAccess (EVar "a") "json")) (EFieldAccess (EVar "a") "selectors")) (EApp (EApp (EVar "selectGates") (EVar "sels")) (EVar "gates"))) (EVar "path")))))))))))))
(DTypeSig false "selectionOutput" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "selectionOutput" (PWild (PVar "tokens") (PList) (PVar "path")) (EIf (EApp (EVar "isEmptyStrs") (EVar "tokens")) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: ")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString " contains no gates")))) (EIf (EVar "otherwise") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate list: no gates match: ")) (EApp (EMethodRef "display") (EApp (EVar "joinSpace") (EVar "tokens")))) (ELit (LString "")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "selectionOutput" ((PVar "isJson") PWild (PCons (PVar "g") (PVar "gs")) PWild) (EIf (EVar "isJson") (EApp (EVar "Ok") (EBinOp "++" (EApp (EVar "renderJson") (EBinOp "::" (EVar "g") (EVar "gs"))) (ELit (LString "\n")))) (EApp (EVar "Ok") (EApp (EVar "renderNames") (EBinOp "::" (EVar "g") (EVar "gs"))))))
(DTypeSig false "emit" (TyFun (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "emit" ((PCon "Err" (PVar "msg"))) (EBlock (DoLet false false PWild (EApp (EVar "ePutStrLn") (EVar "msg"))) (DoExpr (EApp (EVar "exit") (ELit (LInt 1))))))
(DFunDef false "emit" ((PCon "Ok" (PVar "out"))) (EApp (EVar "putStr") (EVar "out")))
(DTypeSig false "isEmptyStrs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "isEmptyStrs" ((PList)) (EVar "True"))
(DFunDef false "isEmptyStrs" (PWild) (EVar "False"))
(DTypeSig false "joinSpace" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "joinSpace" ((PList)) (ELit (LString "")))
(DFunDef false "joinSpace" ((PCons (PVar "x") (PList))) (EVar "x"))
(DFunDef false "joinSpace" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "joinSpace") (EVar "xs")))) (ELit (LString ""))))
(DTypeSig true "runGateCmd" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "runGateCmd" ((PList)) (EApp (EVar "emit") (EApp (EVar "Err") (ELit (LString "usage: medaka gate list [<selector>...] [--json]")))))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "list")) (PVar "rest"))) (EApp (EVar "emit") (EApp (EVar "listOutput") (EVar "rest"))))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "run")) PWild)) (EApp (EVar "emit") (EApp (EVar "Err") (ELit (LString "medaka gate run: not implemented yet (see docs/ops/GATE-REGISTRY-DESIGN.md §3)")))))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "verify")) PWild)) (EApp (EVar "emit") (EApp (EVar "Err") (ELit (LString "medaka gate verify: not implemented yet (see docs/ops/GATE-REGISTRY-DESIGN.md §3)")))))
(DFunDef false "runGateCmd" ((PCons (PLit (LString "explain")) PWild)) (EApp (EVar "emit") (EApp (EVar "Err") (ELit (LString "medaka gate explain: not implemented yet (see docs/ops/GATE-REGISTRY-DESIGN.md §3)")))))
(DFunDef false "runGateCmd" ((PCons (PVar "sub") PWild)) (EApp (EVar "emit") (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate: unknown subcommand '")) (EApp (EMethodRef "display") (EMethodRef "sub"))) (ELit (LString "' (expected: list)"))))))
(DProp false "a bare selector token is name: sugar" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parseSelector") (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "Ok") (EApp (EVar "SelName") (EApp (EVar "intToString") (EVar "n"))))))
(DProp false "an explicit name: selector agrees with the bare form" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "parseSelector") (EBinOp "++" (ELit (LString "name:")) (EApp (EVar "intToString") (EVar "n")))) (EApp (EVar "parseSelector") (EApp (EVar "intToString") (EVar "n")))))
(DProp false "a literal glob matches itself and nothing longer" ((pp "n" (TyCon "Int"))) (EBinOp "&&" (EApp (EApp (EVar "globMatch") (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "not") (EApp (EApp (EVar "globMatch") (EApp (EVar "intToString") (EVar "n"))) (EBinOp "++" (EApp (EVar "intToString") (EVar "n")) (ELit (LString "x")))))))
(DProp false "a trailing * matches any suffix" ((pp "n" (TyCon "Int"))) (EApp (EApp (EVar "globMatch") (ELit (LString "g*"))) (EBinOp "++" (ELit (LString "g")) (EApp (EVar "intToString") (EVar "n")))))
