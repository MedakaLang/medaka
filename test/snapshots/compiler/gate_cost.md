# META
source_lines=229
stages=DESUGAR,MARK
# SOURCE
{- gate_cost.mdk — the per-gate cost baseline reader (#2178, epic #2182).

   `test/gate_cost_baseline.json` (S-1, schema `gate-cost-baseline/1`) is a
   GENERATED file: `test/gate_cost_ingest.sh` folds `test/run_gates.sh`'s
   per-gate timing reports from unnarrowed CI runs into it, keeping a lower
   median of up to nine retained samples per gate.  This module is the
   read side — the balancer's only input besides the registry itself.

   ⚠️ **THE JOIN KEY IS NOT THE REGISTRY'S `name`.**  This is the one fact that
   makes an otherwise obvious join silently wrong, so it lives here with the
   reader rather than in the caller.

   The baseline is keyed by `run_gates.sh`'s OWN gate label (`gate_name`,
   `test/run_gates.sh:149-151`), which it derives from the gate SCRIPT PATH:
   drop `.sh`, turn every `/` into `_`, then drop a leading `test_`.  For the
   ~119 gates under `test/` that is the identity on their registry name
   (`test/diff_compiler_lexer.sh` -> `diff_compiler_lexer`), which is exactly
   why the mismatch hides: it is invisible on 149 of the 202 schedulable
   entries and only bites the 53 that live outside `test/`, where the registry
   name keeps its slashes (`sqlite/test/select_oracle`) and the baseline key
   does not (`sqlite_test_select_oracle`).

   Joining on `name` therefore does not FAIL — it silently reports "no cost"
   for all 53, including every gate on the `pds` row and 24 of `eval`'s 60,
   and a balancer would then pack a 949-second gate as if it were free.  So:
   join on `baselineKey g.run`, and treat a miss as a hard error, never a zero.

   Verified against the committed baseline: `baselineKey` over the 202
   non-`other-job` entries' `run` fields is a bijection onto the baseline's 202
   gate names — 0 missing, 0 duplicate keys, 0 unused baseline rows. -}

import json.{JNull, Json, asArray, asBool, asInt, asString, lookup, parse}
import support.util.{joinWith, splitOnChar, startsWith}

{- | One gate's measured cost.  `medianMs` is the baseline's `medianMs` —
   the LOWER median of the retained raw samples, in milliseconds. -}
public export data GateCost = GateCost { name : String, medianMs : Int }

{- | The baseline's key for a gate, from that gate's `run` script path.

   Mirrors `gate_name` in `test/run_gates.sh` exactly: strip the `.sh`
   extension, replace every `/` with `_`, then strip one leading `test_`.

   > baselineKey "test/diff_compiler_lexer.sh"
   "diff_compiler_lexer"

   > baselineKey "sqlite/test/select_oracle.sh"
   "sqlite_test_select_oracle"

   > baselineKey "test/native_fixtures/run.sh"
   "native_fixtures_run"

   > baselineKey "pds/test/repo_vectors.sh"
   "pds_test_repo_vectors" -}
export
baselineKey : String -> String
baselineKey run =
  let noExt = dropDotSh run
  let flat = joinWith "_" (splitOnChar '/' noExt)
  dropTestPrefix flat

-- `stripSuffix`/`stripPrefix` without pulling `stdlib/string` in for two uses
-- ([T-STDLIB-IMPORT]) — `stringSlice`/`stringLength` are prelude builtins.
dropDotSh : String -> String
dropDotSh s
  | stringLength s > 3 && stringSlice (stringLength s - 3) (stringLength s) s == ".sh" = stringSlice 0 (stringLength s - 3) s
  | otherwise = s

dropTestPrefix : String -> String
dropTestPrefix s
  | startsWith "test_" s = stringSlice 5 (stringLength s) s
  | otherwise = s

-- ── Reading the baseline ────────────────────────────────────────────────────

{- | The schema string this reader understands.  A baseline carrying any other
   value is REFUSED rather than read on a best-effort basis: the fields are
   the same shape a future `/2` would plausibly keep while changing what
   `medianMs` MEANS, and a packer silently fed the wrong statistic is exactly
   the failure this whole slice exists to make impossible. -}
export
costSchema : String
costSchema = "gate-cost-baseline/1"

costEntry : Int -> Json -> Result String GateCost
costEntry i e = match asString (orNull (lookup "name" e))
  None => Err "gate cost baseline: gates[\{intToString i}]: missing string field 'name'"
  Some n => match asInt (orNull (lookup "medianMs" e))
    None => Err "gate cost baseline: gates[\{intToString i}] '\{n}': missing integer field 'medianMs'"
    Some ms if ms < 0 => Err "gate cost baseline: gates[\{intToString i}] '\{n}': negative medianMs \{intToString ms}"
    Some ms => Ok GateCost { name = n, medianMs = ms }

orNull : Option Json -> Json
orNull None = JNull
orNull (Some j) = j

costEntries : Array Json -> Int -> Int -> List GateCost -> Result String (List GateCost)
costEntries arr i n acc
  | i >= n = Ok (reverseCosts acc [])
  | otherwise = match costEntry i (arrayGetUnsafe i arr)
    Err m => Err m
    Ok c => costEntries arr (i + 1) n (c::acc)

reverseCosts : List GateCost -> List GateCost -> List GateCost
reverseCosts [] acc = acc
reverseCosts (c::cs) acc = reverseCosts cs (c::acc)

{- | Parse a cost baseline's JSON source into its per-gate costs, in file
   order.  An empty `gates` array is an error for the same reason an empty
   registry is: "nothing has a measured cost" must not present as a
   well-formed answer a packer can proceed from. -}
export
parseCostBaseline : String -> Result String (List GateCost)
parseCostBaseline src = match parse src
  Err m => Err "gate cost baseline: \{m}"
  Ok doc => match asString (orNull (lookup "schema" doc))
    None => Err "gate cost baseline: missing top-level string field 'schema'"
    Some sc if sc /= costSchema => Err "gate cost baseline: unsupported schema '\{sc}' (this reader understands '\{costSchema}')"
    Some _ => match asArray (orNull (lookup "gates" doc))
      None => Err "gate cost baseline: missing top-level array field 'gates'"
      Some arr if arrayLength arr == 0 =>
        Err "gate cost baseline: 'gates' is empty"
      Some arr => costEntries arr 0 (arrayLength arr) []

-- ── Reading the `runs[]` provenance rows (#2208) ────────────────────────────
--
-- `runs[]` is a DIFFERENT axis from `gates[]`: one entry per CI row (shard
-- run), not per gate, keyed `"<runId>:<runAttempt>:<shard>"`.  Since S-1 it
-- also carries the row's own `jobs` (outer worker count), `parallel`
-- (whether the fan-out ran concurrently), and `rowElapsedMs` (the row's own
-- wall clock, spanning its whole `xargs -P $JOBS` fan-out) — all three
-- OPTIONAL, since a run ingested before this field existed has none of them
-- and must read as "unknown", never as a false 0/zero-cost.
--
-- This is a READ ONLY.  `balCompute`/`balCands` (the shard packer) do not
-- consume it — wiring these facts into the score is a later slice's job, not
-- this one's.  See `test/gate_cost_baseline.json`'s own header note and the
-- module's own doc-comment above for why the file exists at all.

{- | One `runs[]` provenance row. -}
public export data RunRecord =
  | RunRecord {
      key : String,
      runId : String,
      shard : String,
      jobs : Option Int,
      parallel : Option Bool,
      rowElapsedMs : Option Int,
    }

runEntry : Int -> Json -> Result String RunRecord
runEntry i e = match asString (orNull (lookup "key" e))
  None => Err "gate cost baseline: runs[\{intToString i}]: missing string field 'key'"
  Some k => match asString (orNull (lookup "runId" e))
    None => Err "gate cost baseline: runs[\{intToString i}] '\{k}': missing string field 'runId'"
    Some rid => match asString (orNull (lookup "shard" e))
      None => Err "gate cost baseline: runs[\{intToString i}] '\{k}': missing string field 'shard'"
      Some sh => Ok RunRecord {
        key = k,
        runId = rid,
        shard = sh,
        jobs = asInt (orNull (lookup "jobs" e)),
        parallel = asBool (orNull (lookup "parallel" e)),
        rowElapsedMs = asInt (orNull (lookup "rowElapsedMs" e)),
      }

runEntries : Array Json -> Int -> Int -> List RunRecord -> Result String (List RunRecord)
runEntries arr i n acc
  | i >= n = Ok (reverseRuns acc [])
  | otherwise = match runEntry i (arrayGetUnsafe i arr)
    Err m => Err m
    Ok r => runEntries arr (i + 1) n (r::acc)

reverseRuns : List RunRecord -> List RunRecord -> List RunRecord
reverseRuns [] acc = acc
reverseRuns (r::rs) acc = reverseRuns rs (r::acc)

{- | Parse a cost baseline's `runs[]` provenance rows, in file order (oldest
   first — the ingester appends new runs after old ones, dropping only past
   `--max-runs`).  A missing top-level `runs` array is an error, same as a
   missing `gates` one; an EMPTY `runs` array is not — a freshly-created
   baseline before its first ingest legitimately has none. -}
export
parseCostRuns : String -> Result String (List RunRecord)
parseCostRuns src = match parse src
  Err m => Err "gate cost baseline: \{m}"
  Ok doc => match asArray (orNull (lookup "runs" doc))
    None => Err "gate cost baseline: missing top-level array field 'runs'"
    Some arr => runEntries arr 0 (arrayLength arr) []

{- | The most recently ingested `runs[]` row for a given shard, or `None` if
   the shard has never been recorded.  "Most recent" is file order: the
   ingester only ever appends. -}
export
latestRunForShard : String -> List RunRecord -> Option RunRecord
latestRunForShard sh rs = latestRunGo sh rs None

latestRunGo : String -> List RunRecord -> Option RunRecord -> Option RunRecord
latestRunGo _ [] acc = acc
latestRunGo sh (r::rs) acc
  | r.shard == sh = latestRunGo sh rs (Some r)
  | otherwise = latestRunGo sh rs acc

{- | The measured cost of the gate whose script path is `run`, or `None` when
   the baseline has no row for it.  Linear — the caller does this once per
   gate over a ~200-row baseline, and a scan beats standing a map up for it. -}
export
costOf : String -> List GateCost -> Option Int
costOf run cs = costOfKey (baselineKey run) cs

-- The key is derived ONCE, not per element: `baselineKey` inside the loop
-- would re-split the path 202 times per gate, 40k times per run.
costOfKey : String -> List GateCost -> Option Int
costOfKey _ [] = None
costOfKey k (c::cs)
  | c.name == k = Some c.medianMs
  | otherwise = costOfKey k cs

-- ── Properties ──────────────────────────────────────────────────────────────

prop "baselineKey leaves a test/ gate's stem alone" (n : Int) =
  baselineKey "test/g\{intToString n}.sh" == "g\{intToString n}"

prop "baselineKey flattens every separator" (n : Int) =
  baselineKey "a/b/c\{intToString n}.sh" == "a_b_c\{intToString n}"

prop "baselineKey is idempotent on an already-flat key" (n : Int) =
  baselineKey (baselineKey "test/g\{intToString n}.sh") ==
    baselineKey "test/g\{intToString n}.sh"
# DESUGAR
(DUse false (UseGroup ("json") ((mem "JNull" false) (mem "Json" false) (mem "asArray" false) (mem "asBool" false) (mem "asInt" false) (mem "asString" false) (mem "lookup" false) (mem "parse" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "splitOnChar" false) (mem "startsWith" false))))
(DData Public "GateCost" () ((variant "GateCost" (ConNamed (field "name" (TyCon "String")) (field "medianMs" (TyCon "Int"))))) ())
(DTypeSig true "baselineKey" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "baselineKey" ((PVar "run")) (EBlock (DoLet false false (PVar "noExt") (EApp (EVar "dropDotSh") (EVar "run"))) (DoLet false false (PVar "flat") (EApp (EApp (EVar "joinWith") (ELit (LString "_"))) (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "noExt")))) (DoExpr (EApp (EVar "dropTestPrefix") (EVar "flat")))))
(DTypeSig false "dropDotSh" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dropDotSh" ((PVar "s")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 3))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 3)))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (ELit (LString ".sh")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 3)))) (EVar "s")) (EIf (EVar "otherwise") (EVar "s") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dropTestPrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dropTestPrefix" ((PVar "s")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "test_"))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 5))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EIf (EVar "otherwise") (EVar "s") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "costSchema" (TyCon "String"))
(DFunDef false "costSchema" () (ELit (LString "gate-cost-baseline/1")))
(DTypeSig false "costEntry" (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "GateCost")))))
(DFunDef false "costEntry" ((PVar "i") (PVar "e")) (EMatch (EApp (EVar "asString") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "name"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "]: missing string field 'name'"))))) (arm (PCon "Some" (PVar "n")) () (EMatch (EApp (EVar "asInt") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "medianMs"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "': missing integer field 'medianMs'"))))) (arm (PCon "Some" (PVar "ms")) ((GBool (EBinOp "<" (EVar "ms") (ELit (LInt 0))))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "': negative medianMs "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "ms")))) (ELit (LString ""))))) (arm (PCon "Some" (PVar "ms")) () (EApp (EVar "Ok") (ERecordCreate "GateCost" ((fa "name" (EVar "n")) (fa "medianMs" (EVar "ms"))))))))))
(DTypeSig false "orNull" (TyFun (TyApp (TyCon "Option") (TyCon "Json")) (TyCon "Json")))
(DFunDef false "orNull" ((PCon "None")) (EVar "JNull"))
(DFunDef false "orNull" ((PCon "Some" (PVar "j"))) (EVar "j"))
(DTypeSig false "costEntries" (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "GateCost"))))))))
(DFunDef false "costEntries" ((PVar "arr") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Ok") (EApp (EApp (EVar "reverseCosts") (EVar "acc")) (EListLit))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "costEntry") (EVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "c")) () (EApp (EApp (EApp (EApp (EVar "costEntries") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "::" (EVar "c") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reverseCosts" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyApp (TyCon "List") (TyCon "GateCost")))))
(DFunDef false "reverseCosts" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseCosts" ((PCons (PVar "c") (PVar "cs")) (PVar "acc")) (EApp (EApp (EVar "reverseCosts") (EVar "cs")) (EBinOp "::" (EVar "c") (EVar "acc"))))
(DTypeSig true "parseCostBaseline" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "GateCost")))))
(DFunDef false "parseCostBaseline" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "doc")) () (EMatch (EApp (EVar "asString") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "schema"))) (EVar "doc")))) (arm (PCon "None") () (EApp (EVar "Err") (ELit (LString "gate cost baseline: missing top-level string field 'schema'")))) (arm (PCon "Some" (PVar "sc")) ((GBool (EBinOp "/=" (EVar "sc") (EVar "costSchema")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: unsupported schema '")) (EApp (EVar "display") (EVar "sc"))) (ELit (LString "' (this reader understands '"))) (EApp (EVar "display") (EVar "costSchema"))) (ELit (LString "')"))))) (arm (PCon "Some" PWild) () (EMatch (EApp (EVar "asArray") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "gates"))) (EVar "doc")))) (arm (PCon "None") () (EApp (EVar "Err") (ELit (LString "gate cost baseline: missing top-level array field 'gates'")))) (arm (PCon "Some" (PVar "arr")) ((GBool (EBinOp "==" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 0))))) (EApp (EVar "Err") (ELit (LString "gate cost baseline: 'gates' is empty")))) (arm (PCon "Some" (PVar "arr")) () (EApp (EApp (EApp (EApp (EVar "costEntries") (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))) (EListLit)))))))))
(DData Public "RunRecord" () ((variant "RunRecord" (ConNamed (field "key" (TyCon "String")) (field "runId" (TyCon "String")) (field "shard" (TyCon "String")) (field "jobs" (TyApp (TyCon "Option") (TyCon "Int"))) (field "parallel" (TyApp (TyCon "Option") (TyCon "Bool"))) (field "rowElapsedMs" (TyApp (TyCon "Option") (TyCon "Int")))))) ())
(DTypeSig false "runEntry" (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "RunRecord")))))
(DFunDef false "runEntry" ((PVar "i") (PVar "e")) (EMatch (EApp (EVar "asString") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "key"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: runs[")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "]: missing string field 'key'"))))) (arm (PCon "Some" (PVar "k")) () (EMatch (EApp (EVar "asString") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "runId"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: runs[")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EVar "display") (EVar "k"))) (ELit (LString "': missing string field 'runId'"))))) (arm (PCon "Some" (PVar "rid")) () (EMatch (EApp (EVar "asString") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "shard"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: runs[")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EVar "display") (EVar "k"))) (ELit (LString "': missing string field 'shard'"))))) (arm (PCon "Some" (PVar "sh")) () (EApp (EVar "Ok") (ERecordCreate "RunRecord" ((fa "key" (EVar "k")) (fa "runId" (EVar "rid")) (fa "shard" (EVar "sh")) (fa "jobs" (EApp (EVar "asInt") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "jobs"))) (EVar "e"))))) (fa "parallel" (EApp (EVar "asBool") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "parallel"))) (EVar "e"))))) (fa "rowElapsedMs" (EApp (EVar "asInt") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "rowElapsedMs"))) (EVar "e")))))))))))))))
(DTypeSig false "runEntries" (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "RunRecord"))))))))
(DFunDef false "runEntries" ((PVar "arr") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Ok") (EApp (EApp (EVar "reverseRuns") (EVar "acc")) (EListLit))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "runEntry") (EVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "r")) () (EApp (EApp (EApp (EApp (EVar "runEntries") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "::" (EVar "r") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reverseRuns" (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyApp (TyCon "List") (TyCon "RunRecord")))))
(DFunDef false "reverseRuns" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseRuns" ((PCons (PVar "r") (PVar "rs")) (PVar "acc")) (EApp (EApp (EVar "reverseRuns") (EVar "rs")) (EBinOp "::" (EVar "r") (EVar "acc"))))
(DTypeSig true "parseCostRuns" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "RunRecord")))))
(DFunDef false "parseCostRuns" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "doc")) () (EMatch (EApp (EVar "asArray") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "runs"))) (EVar "doc")))) (arm (PCon "None") () (EApp (EVar "Err") (ELit (LString "gate cost baseline: missing top-level array field 'runs'")))) (arm (PCon "Some" (PVar "arr")) () (EApp (EApp (EApp (EApp (EVar "runEntries") (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))) (EListLit)))))))
(DTypeSig true "latestRunForShard" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyApp (TyCon "Option") (TyCon "RunRecord")))))
(DFunDef false "latestRunForShard" ((PVar "sh") (PVar "rs")) (EApp (EApp (EApp (EVar "latestRunGo") (EVar "sh")) (EVar "rs")) (EVar "None")))
(DTypeSig false "latestRunGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyFun (TyApp (TyCon "Option") (TyCon "RunRecord")) (TyApp (TyCon "Option") (TyCon "RunRecord"))))))
(DFunDef false "latestRunGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "latestRunGo" ((PVar "sh") (PCons (PVar "r") (PVar "rs")) (PVar "acc")) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "shard") (EVar "sh")) (EApp (EApp (EApp (EVar "latestRunGo") (EVar "sh")) (EVar "rs")) (EApp (EVar "Some") (EVar "r"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "latestRunGo") (EVar "sh")) (EVar "rs")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "costOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "costOf" ((PVar "run") (PVar "cs")) (EApp (EApp (EVar "costOfKey") (EApp (EVar "baselineKey") (EVar "run"))) (EVar "cs")))
(DTypeSig false "costOfKey" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "costOfKey" (PWild (PList)) (EVar "None"))
(DFunDef false "costOfKey" ((PVar "k") (PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "c") "name") (EVar "k")) (EApp (EVar "Some") (EFieldAccess (EVar "c") "medianMs")) (EIf (EVar "otherwise") (EApp (EApp (EVar "costOfKey") (EVar "k")) (EVar "cs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DProp false "baselineKey leaves a test/ gate's stem alone" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "baselineKey") (EBinOp "++" (EBinOp "++" (ELit (LString "test/g")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ".sh")))) (EBinOp "++" (EBinOp "++" (ELit (LString "g")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "")))))
(DProp false "baselineKey flattens every separator" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "baselineKey") (EBinOp "++" (EBinOp "++" (ELit (LString "a/b/c")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ".sh")))) (EBinOp "++" (EBinOp "++" (ELit (LString "a_b_c")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "")))))
(DProp false "baselineKey is idempotent on an already-flat key" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "baselineKey") (EApp (EVar "baselineKey") (EBinOp "++" (EBinOp "++" (ELit (LString "test/g")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ".sh"))))) (EApp (EVar "baselineKey") (EBinOp "++" (EBinOp "++" (ELit (LString "test/g")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ".sh"))))))
# MARK
(DUse false (UseGroup ("json") ((mem "JNull" false) (mem "Json" false) (mem "asArray" false) (mem "asBool" false) (mem "asInt" false) (mem "asString" false) (mem "lookup" false) (mem "parse" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "splitOnChar" false) (mem "startsWith" false))))
(DData Public "GateCost" () ((variant "GateCost" (ConNamed (field "name" (TyCon "String")) (field "medianMs" (TyCon "Int"))))) ())
(DTypeSig true "baselineKey" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "baselineKey" ((PVar "run")) (EBlock (DoLet false false (PVar "noExt") (EApp (EVar "dropDotSh") (EVar "run"))) (DoLet false false (PVar "flat") (EApp (EApp (EVar "joinWith") (ELit (LString "_"))) (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "noExt")))) (DoExpr (EApp (EVar "dropTestPrefix") (EDictApp "flat")))))
(DTypeSig false "dropDotSh" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dropDotSh" ((PVar "s")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 3))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 3)))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (ELit (LString ".sh")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 3)))) (EVar "s")) (EIf (EVar "otherwise") (EVar "s") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dropTestPrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dropTestPrefix" ((PVar "s")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "test_"))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 5))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EIf (EVar "otherwise") (EVar "s") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "costSchema" (TyCon "String"))
(DFunDef false "costSchema" () (ELit (LString "gate-cost-baseline/1")))
(DTypeSig false "costEntry" (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "GateCost")))))
(DFunDef false "costEntry" ((PVar "i") (PVar "e")) (EMatch (EApp (EVar "asString") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "name"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "]: missing string field 'name'"))))) (arm (PCon "Some" (PVar "n")) () (EMatch (EApp (EVar "asInt") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "medianMs"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "': missing integer field 'medianMs'"))))) (arm (PCon "Some" (PVar "ms")) ((GBool (EBinOp "<" (EVar "ms") (ELit (LInt 0))))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "': negative medianMs "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "ms")))) (ELit (LString ""))))) (arm (PCon "Some" (PVar "ms")) () (EApp (EVar "Ok") (ERecordCreate "GateCost" ((fa "name" (EVar "n")) (fa "medianMs" (EVar "ms"))))))))))
(DTypeSig false "orNull" (TyFun (TyApp (TyCon "Option") (TyCon "Json")) (TyCon "Json")))
(DFunDef false "orNull" ((PCon "None")) (EVar "JNull"))
(DFunDef false "orNull" ((PCon "Some" (PVar "j"))) (EVar "j"))
(DTypeSig false "costEntries" (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "GateCost"))))))))
(DFunDef false "costEntries" ((PVar "arr") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Ok") (EApp (EApp (EVar "reverseCosts") (EVar "acc")) (EListLit))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "costEntry") (EVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "c")) () (EApp (EApp (EApp (EApp (EVar "costEntries") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "::" (EVar "c") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reverseCosts" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyApp (TyCon "List") (TyCon "GateCost")))))
(DFunDef false "reverseCosts" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseCosts" ((PCons (PVar "c") (PVar "cs")) (PVar "acc")) (EApp (EApp (EVar "reverseCosts") (EVar "cs")) (EBinOp "::" (EVar "c") (EVar "acc"))))
(DTypeSig true "parseCostBaseline" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "GateCost")))))
(DFunDef false "parseCostBaseline" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "doc")) () (EMatch (EApp (EVar "asString") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "schema"))) (EVar "doc")))) (arm (PCon "None") () (EApp (EVar "Err") (ELit (LString "gate cost baseline: missing top-level string field 'schema'")))) (arm (PCon "Some" (PVar "sc")) ((GBool (EBinOp "/=" (EVar "sc") (EVar "costSchema")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: unsupported schema '")) (EApp (EMethodRef "display") (EVar "sc"))) (ELit (LString "' (this reader understands '"))) (EApp (EMethodRef "display") (EVar "costSchema"))) (ELit (LString "')"))))) (arm (PCon "Some" PWild) () (EMatch (EApp (EVar "asArray") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "gates"))) (EVar "doc")))) (arm (PCon "None") () (EApp (EVar "Err") (ELit (LString "gate cost baseline: missing top-level array field 'gates'")))) (arm (PCon "Some" (PVar "arr")) ((GBool (EBinOp "==" (EApp (EVar "arrayLength") (EVar "arr")) (ELit (LInt 0))))) (EApp (EVar "Err") (ELit (LString "gate cost baseline: 'gates' is empty")))) (arm (PCon "Some" (PVar "arr")) () (EApp (EApp (EApp (EApp (EVar "costEntries") (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))) (EListLit)))))))))
(DData Public "RunRecord" () ((variant "RunRecord" (ConNamed (field "key" (TyCon "String")) (field "runId" (TyCon "String")) (field "shard" (TyCon "String")) (field "jobs" (TyApp (TyCon "Option") (TyCon "Int"))) (field "parallel" (TyApp (TyCon "Option") (TyCon "Bool"))) (field "rowElapsedMs" (TyApp (TyCon "Option") (TyCon "Int")))))) ())
(DTypeSig false "runEntry" (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "RunRecord")))))
(DFunDef false "runEntry" ((PVar "i") (PVar "e")) (EMatch (EApp (EVar "asString") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "key"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: runs[")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "]: missing string field 'key'"))))) (arm (PCon "Some" (PVar "k")) () (EMatch (EApp (EVar "asString") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "runId"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: runs[")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EMethodRef "display") (EVar "k"))) (ELit (LString "': missing string field 'runId'"))))) (arm (PCon "Some" (PVar "rid")) () (EMatch (EApp (EVar "asString") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "shard"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: runs[")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EMethodRef "display") (EVar "k"))) (ELit (LString "': missing string field 'shard'"))))) (arm (PCon "Some" (PVar "sh")) () (EApp (EVar "Ok") (ERecordCreate "RunRecord" ((fa "key" (EVar "k")) (fa "runId" (EVar "rid")) (fa "shard" (EVar "sh")) (fa "jobs" (EApp (EVar "asInt") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "jobs"))) (EVar "e"))))) (fa "parallel" (EApp (EVar "asBool") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "parallel"))) (EVar "e"))))) (fa "rowElapsedMs" (EApp (EVar "asInt") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "rowElapsedMs"))) (EVar "e")))))))))))))))
(DTypeSig false "runEntries" (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "RunRecord"))))))))
(DFunDef false "runEntries" ((PVar "arr") (PVar "i") (PVar "n") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EApp (EVar "Ok") (EApp (EApp (EVar "reverseRuns") (EVar "acc")) (EListLit))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "runEntry") (EVar "i")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "arr"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "r")) () (EApp (EApp (EApp (EApp (EVar "runEntries") (EVar "arr")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "::" (EVar "r") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reverseRuns" (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyApp (TyCon "List") (TyCon "RunRecord")))))
(DFunDef false "reverseRuns" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseRuns" ((PCons (PVar "r") (PVar "rs")) (PVar "acc")) (EApp (EApp (EVar "reverseRuns") (EVar "rs")) (EBinOp "::" (EVar "r") (EVar "acc"))))
(DTypeSig true "parseCostRuns" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "RunRecord")))))
(DFunDef false "parseCostRuns" ((PVar "src")) (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "doc")) () (EMatch (EApp (EVar "asArray") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "runs"))) (EVar "doc")))) (arm (PCon "None") () (EApp (EVar "Err") (ELit (LString "gate cost baseline: missing top-level array field 'runs'")))) (arm (PCon "Some" (PVar "arr")) () (EApp (EApp (EApp (EApp (EVar "runEntries") (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))) (EListLit)))))))
(DTypeSig true "latestRunForShard" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyApp (TyCon "Option") (TyCon "RunRecord")))))
(DFunDef false "latestRunForShard" ((PVar "sh") (PVar "rs")) (EApp (EApp (EApp (EVar "latestRunGo") (EVar "sh")) (EVar "rs")) (EVar "None")))
(DTypeSig false "latestRunGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyFun (TyApp (TyCon "Option") (TyCon "RunRecord")) (TyApp (TyCon "Option") (TyCon "RunRecord"))))))
(DFunDef false "latestRunGo" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "latestRunGo" ((PVar "sh") (PCons (PVar "r") (PVar "rs")) (PVar "acc")) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "shard") (EVar "sh")) (EApp (EApp (EApp (EVar "latestRunGo") (EVar "sh")) (EVar "rs")) (EApp (EVar "Some") (EVar "r"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "latestRunGo") (EVar "sh")) (EVar "rs")) (EVar "acc")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "costOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "costOf" ((PVar "run") (PVar "cs")) (EApp (EApp (EVar "costOfKey") (EApp (EVar "baselineKey") (EVar "run"))) (EVar "cs")))
(DTypeSig false "costOfKey" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "costOfKey" (PWild (PList)) (EVar "None"))
(DFunDef false "costOfKey" ((PVar "k") (PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "c") "name") (EVar "k")) (EApp (EVar "Some") (EFieldAccess (EVar "c") "medianMs")) (EIf (EVar "otherwise") (EApp (EApp (EVar "costOfKey") (EVar "k")) (EVar "cs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DProp false "baselineKey leaves a test/ gate's stem alone" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "baselineKey") (EBinOp "++" (EBinOp "++" (ELit (LString "test/g")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ".sh")))) (EBinOp "++" (EBinOp "++" (ELit (LString "g")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "")))))
(DProp false "baselineKey flattens every separator" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "baselineKey") (EBinOp "++" (EBinOp "++" (ELit (LString "a/b/c")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ".sh")))) (EBinOp "++" (EBinOp "++" (ELit (LString "a_b_c")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "")))))
(DProp false "baselineKey is idempotent on an already-flat key" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "baselineKey") (EApp (EVar "baselineKey") (EBinOp "++" (EBinOp "++" (ELit (LString "test/g")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ".sh"))))) (EApp (EVar "baselineKey") (EBinOp "++" (EBinOp "++" (ELit (LString "test/g")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ".sh"))))))
