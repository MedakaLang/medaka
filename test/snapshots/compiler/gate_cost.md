# META
source_lines=603
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
import support.util.{joinWith, listLen, splitOnChar, startsWith}

{- | One gate's measured cost.  `medianMs` is the baseline's `medianMs` —
   the LOWER median of the retained raw samples, in milliseconds.  `samples`
   is the baseline's own `"samples": N` count (S-4, #2178/#2207) — how many
   raw measurements that median was taken over, so a reader (and, via
   `balReport`, `medaka gate balance`'s own output) can see when a gate's
   placement rests on thin evidence rather than having to go find the
   baseline file and count.

   `ms` is those retained raw samples themselves, in the ingester's append
   order (S-2, #2222).  The balancer does not SCORE from them — `costOf`
   still returns `medianMs`, and the packing statistic is unchanged — but it
   cannot state the statistic's out-of-sample error without them, because
   every honest estimate of that error has to recompute the statistic from a
   SUBSET of a gate's samples and score it against the sample left out.  A
   `medianMs` alone can only be validated against the samples that defined
   it, which is the in-sample residual that means nothing.

   `sampleRuns` is WHICH RUN each of those samples came from — the same
   length as `ms`, same order, one `runId` per element, and the empty string
   where that is not recorded (FR-1, #2222 review S0-1).

   ⚠️ IT EXISTS BECAUSE THE POSITION OF A SAMPLE DOES NOT IDENTIFY ITS RUN.
   S-2 inferred the attribution instead of recording it: `ms[i]` was read as
   "the sample from the i-th retained run" whenever a gate's `samples` equalled
   the number of distinct runIds in `runs[]`.  That equality is a COINCIDENCE,
   not an invariant.  `test/gate_cost_ingest.sh` trims `runs[]` by total ROW
   count (`MAX_RUNS`, one row per `runId:runAttempt:shard`) and trims each
   gate's `ms` by SAMPLE count (`MAX_SAMPLES`), independently, per gate;
   nothing ties the two counters together.  A gate that failed one run and was
   sampled in an older one lands back at the same COUNT with the wrong
   ALIGNMENT, and a leave-one-run-out fold computed off it grades one run's
   estimate against another run's measurement — silently, at exit 0.  So the
   attribution is now carried, not derived, and a sample without it is
   UNATTRIBUTED rather than positionally guessed.

   ⚠️ THE FIELD IS OPTIONAL ON READ, AND LEGACY SAMPLES STAY UNATTRIBUTED.
   Every baseline written before FR-1 lacks it, and the provenance of those
   samples is not recoverable from the file — it was never written down.
   Backfilling them by position would be exactly the inference this field
   removes, so a missing `sampleRuns` parses as all-empty (every sample
   unattributed) and the reader that needs attribution reports that it has
   none rather than inventing it. -}
public export data GateCost = GateCost {
  name : String,
  medianMs : Int,
  samples : Int,
  ms : List Int,
  sampleRuns : List String,
}

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
  | stringLength s > 3
    && stringSlice (stringLength s - 3) (stringLength s) s == ".sh" =
    stringSlice 0 (stringLength s - 3) s
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
  None =>
    Err
      "gate cost baseline: gates[\{intToString i}]: missing string field 'name'"
  Some n => match asInt (orNull (lookup "medianMs" e))
    None =>
      Err
        "gate cost baseline: gates[\{intToString i}] '\{n}': missing integer field 'medianMs'"
    Some ms if ms < 0 =>
      Err
        "gate cost baseline: gates[\{intToString i}] '\{n}': negative medianMs \{intToString ms}"
    Some ms => match asInt (orNull (lookup "samples" e))
      None =>
        Err
          "gate cost baseline: gates[\{intToString i}] '\{n}': missing integer field 'samples'"
      Some sc if sc < 1 =>
        Err
          "gate cost baseline: gates[\{intToString i}] '\{n}': samples must be >= 1, got \{intToString sc}"
      Some sc => match costSamples i n e
        Err m => Err m
        -- `samples` and `ms` are two spellings of the same fact, so a row
        -- where they disagree is REFUSED rather than reconciled: the whole
        -- point of retaining the raw samples is that a reader can re-derive
        -- the statistic from them, and a count that does not describe the
        -- array makes every such derivation quietly wrong.
        Ok raw if listLen raw /= sc =>
          Err
            "gate cost baseline: gates[\{intToString i}] '\{n}': samples is \{intToString sc} but 'ms' holds \{intToString (listLen raw)} value(s)"
        Ok raw =>
          map
            (rids => GateCost {
              name = n,
              medianMs = ms,
              samples = sc,
              ms = raw,
              sampleRuns = rids,
            })
            (costSampleRuns i n e (listLen raw))

-- The retained raw samples of one `gates[]` entry.  Required, not optional:
-- every baseline this reader has ever accepted carries them (the ingester has
-- written `ms` since its first commit), and treating a missing array as an
-- empty one would silently turn "this file predates the field" into "this
-- gate has no evidence", which reads as a thin-evidence finding rather than
-- as the schema error it is.
costSamples : Int -> String -> Json -> Result String (List Int)
costSamples i n e = match asArray (orNull (lookup "ms" e))
  None =>
    Err
      "gate cost baseline: gates[\{intToString i}] '\{n}': missing array field 'ms'"
  Some arr => costSampleInts i n arr 0 (arrayLength arr) []

costSampleInts : Int ->
  String ->
  Array Json ->
  Int ->
  Int ->
  List Int ->
  Result String (List Int)
costSampleInts i n arr k len acc
  | k >= len = Ok (reverseInts acc [])
  | otherwise = match asInt (arrayGetUnsafe k arr)
    None =>
      Err
        "gate cost baseline: gates[\{intToString i}] '\{n}': ms[\{intToString k}] is not an integer"
    Some v if v < 0 =>
      Err
        "gate cost baseline: gates[\{intToString i}] '\{n}': ms[\{intToString k}] is negative (\{intToString v})"
    Some v => costSampleInts i n arr (k + 1) len (v :: acc)

-- The per-sample run attribution of one `gates[]` entry — OPTIONAL, unlike
-- `ms`, and the asymmetry is deliberate.  `ms` has been written by every
-- ingester that ever produced a baseline, so its absence is a schema error;
-- `sampleRuns` was added by FR-1 and every baseline committed before it
-- legitimately lacks the field.  Absent (or explicitly null) therefore reads
-- as "this file predates the field" -> every sample UNATTRIBUTED, which is
-- the true statement about it; see the `GateCost` doc-comment for why
-- reconstructing it by position is the defect rather than the fix.
--
-- PRESENT-BUT-WRONG is still an error: a `sampleRuns` whose length does not
-- match `ms` cannot be a per-sample attribution of those samples under any
-- reading, and silently truncating or padding it would put the alignment bug
-- back in a new place.
costSampleRuns : Int -> String -> Json -> Int -> Result String (List String)
costSampleRuns i n e want = match lookup "sampleRuns" e
  None => Ok (blankRuns want)
  Some JNull => Ok (blankRuns want)
  Some j => match asArray j
    None =>
      Err
        "gate cost baseline: gates[\{intToString i}] '\{n}': 'sampleRuns' is present but is not an array"
    Some arr if arrayLength arr /= want =>
      Err
        "gate cost baseline: gates[\{intToString i}] '\{n}': 'sampleRuns' holds \{intToString (arrayLength arr)} entr(ies) but 'ms' holds \{intToString want}"
    Some arr => costSampleRunStrs i n arr 0 want []

costSampleRunStrs : Int ->
  String ->
  Array Json ->
  Int ->
  Int ->
  List String ->
  Result String (List String)
costSampleRunStrs i n arr k len acc
  | k >= len = Ok (reverseStrs acc [])
  | otherwise = match asString (arrayGetUnsafe k arr)
    None =>
      Err
        "gate cost baseline: gates[\{intToString i}] '\{n}': sampleRuns[\{intToString k}] is not a string"
    Some v => costSampleRunStrs i n arr (k + 1) len (v :: acc)

-- `n` unattributed slots — the empty string is the sentinel, and it can never
-- collide with a real runId (Actions' `github.run_id` is a nonempty decimal).
blankRuns : Int -> List String
blankRuns n
  | n <= 0 = []
  | otherwise = "" :: blankRuns (n - 1)

reverseStrs : List String -> List String -> List String
reverseStrs [] acc = acc
reverseStrs (x :: xs) acc = reverseStrs xs (x :: acc)

reverseInts : List Int -> List Int -> List Int
reverseInts [] acc = acc
reverseInts (x :: xs) acc = reverseInts xs (x :: acc)

orNull : Option Json -> Json
orNull None = JNull
orNull (Some j) = j

costEntries : Array Json ->
  Int ->
  Int ->
  List GateCost ->
  Result String (List GateCost)
costEntries arr i n acc
  | i >= n = Ok (reverseCosts acc [])
  | otherwise = match costEntry i (arrayGetUnsafe i arr)
    Err m => Err m
    Ok c => costEntries arr (i + 1) n (c :: acc)

reverseCosts : List GateCost -> List GateCost -> List GateCost
reverseCosts [] acc = acc
reverseCosts (c :: cs) acc = reverseCosts cs (c :: acc)

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
    Some sc if sc /= costSchema =>
      Err
        "gate cost baseline: unsupported schema '\{sc}' (this reader understands '\{costSchema}')"
    Some _ => match asArray (orNull (lookup "gates" doc))
      None => Err "gate cost baseline: missing top-level array field 'gates'"
      Some arr if arrayLength arr == 0 =>
        Err "gate cost baseline: 'gates' is empty"
      Some arr => costEntries arr 0 (arrayLength arr) []

-- ── The packing statistic (S-2, #2222) ──────────────────────────────────────

{- | The single number a balancer schedules a gate by, computed from that
   gate's retained raw samples: the LOWER MEDIAN.

   ⚠️ THIS IS THE INCUMBENT STATISTIC, RETAINED ON A MEASUREMENT — not kept by
   default.  Four candidate families were compared out-of-sample and the
   median won; the full table, protocol and derivation live in
   `docs/ops/GATE-REGISTRY-DESIGN.md` §8, and `medaka gate balance` prints the
   retained statistic's own error on every run (`balOosLines`).  The short
   version, because the shape of the answer is easy to get backwards:

     * On CENTRAL tendency every alternative beats the median.  It is
       systematically LOW — measured leave-one-run-out bias -12.6% on a row's
       predicted total — because the lower median of an even sample count is
       the lower of the two central samples.
     * On the TAIL the median wins, and that is the axis a packer is
       scheduling on.  One gate in the committed baseline
       (`pds_test_repo_vectors`, `ms` = [948919, 14082, 18725]) carries a
       50.7x hiccup sample.  At the baseline's own sample count the median
       prices it at 18725ms — the only candidate that gets it right.  The
       mean says 327242 (17x), the max says 948919 (50x), and
       `median + 0.25*spread` says 252434 (13x).  A 949-second misprice on
       one gate is enough to dominate an entire row.

   ⚠️ The -12.6% is S-2's DATED measurement, not a figure re-derived here: it was
   taken under the positional run attribution FR-1 replaced with a recorded one
   (`GateCost.sampleRuns`), so `balOosBlock` reports "not derivable" until enough
   attributed ingests have landed to re-take it.  The CHOICE of statistic does not
   rest on that alignment — the `pds_test_repo_vectors` outlier pricing above is a
   fact about one gate's samples, whichever run each came from — but the percentage
   does.

   So the -12.6% is the PRICE OF ROBUSTNESS, not a defect to correct: it is
   reported (in the balancer's ordinary output, and here) rather than
   cancelled by an uplift factor, because any such factor is a function of the
   sample count it was fitted at and would over-correct at every other one.

   `packStat` exists as a named function, rather than being implicit in the
   ingester's awk, so the balancer can recompute the statistic over a SUBSET
   of a gate's samples — which is exactly what stating an out-of-sample error
   requires.  It agrees with `medianMs` by construction on any baseline the
   current ingester wrote; `balOosLines` counts and reports the rows where it
   does not, so a future divergence between the two definitions is visible
   rather than silent.

   > packStat [7]
   7

   > packStat [10, 20, 30]
   20

   > packStat [20, 10]
   10 -}
export
packStat : List Int -> Int
packStat [] = 0
packStat xs =
  let s = costSortInts xs
  -- Lower median: n=4 -> 2nd, n=5 -> 3rd.  Mirrors `median()` in
  -- test/gate_cost_ingest.sh exactly; the two must never drift.
  costNth ((listLen s + 1) / 2 - 1) s

-- Insertion sort.  A gate holds at most `maxSamples` (9) samples, so the
-- quadratic is nine comparisons and a merge sort would be more code than
-- the thing it sorts.
costSortInts : List Int -> List Int
costSortInts [] = []
costSortInts (x :: xs) = costInsert x (costSortInts xs)

costInsert : Int -> List Int -> List Int
costInsert x [] = x :: []
costInsert x (y :: ys)
  | x <= y = x :: y :: ys
  | otherwise = y :: costInsert x ys

costNth : Int -> List Int -> Int
costNth _ [] = 0
costNth i (x :: xs)
  | i <= 0 = x
  | otherwise = costNth (i - 1) xs

-- ── The gate-set digest (S-2, #2223) ────────────────────────────────────────

{- | An order-independent digest of a set of baseline gate keys.

   WHY A DIGEST AND NOT THE NAMES.  `balCalibStaleness` has to answer "is the
   run this residual came from still describing the gate set that is committed
   now?".  Comparing COUNTS answers a strictly weaker question — a rebalance
   that swaps one gate for another leaves the count alone and the residual
   silently uncomparable (#2223).  Recording each row's gate NAMES would
   answer it exactly, but a 63-gate row is ~1.5kB of JSON on a line, in a
   committed file whose readability is the entire argument for it existing.
   A digest is 10 characters and answers the same question.

   The sum makes it order-independent, which is required: `run_gates.sh`
   reports gates in pattern-resolution order and the registry lists them in
   enrolment order, and those are not the same order.

   ⚠️ Its ONLY consumer is a staleness annotation, so a collision costs a
   missing annotation, never a wrong assignment — 31 bits is ample and no
   cryptographic property is wanted.  The mirror implementation is
   `_digest`/`_h` in `test/gate_cost_ingest.sh`; the two must agree
   byte-for-byte on ASCII, which is all a gate key can contain (it is derived
   from a repository path).  A non-ASCII key would hash differently in awk,
   which shows up as a permanent [STALE] annotation — loud and wrong in the
   safe direction, never a silently absent one. -}
export
gateSetDigest : List String -> Int
gateSetDigest ns = gateSetDigestGo ns 0

gateSetDigestGo : List String -> Int -> Int
gateSetDigestGo [] acc = acc
gateSetDigestGo (n :: ns) acc =
  gateSetDigestGo ns ((acc + gateNameHash n) % costHashMod)

{- | One gate key's hash: the classic `h = h * 131 + c` polynomial, reduced
   mod 2^31-1 at every step so the running value never leaves the range awk's
   double-precision arithmetic represents exactly (2147483646 * 131 is ~2.8e11,
   well inside 2^53).  The seed is 7 rather than 0 so a leading NUL-ish or
   empty key is not a fixed point.

   > gateNameHash ""
   7 -}
export
gateNameHash : String -> Int
gateNameHash s =
  let a = stringToChars s
  gateNameHashGo a 0 (arrayLength a) 7

gateNameHashGo : Array Char -> Int -> Int -> Int -> Int
gateNameHashGo a i n h
  | i >= n = h
  | otherwise =
    gateNameHashGo
      a
      (i + 1)
      n
      ((h * 131 + charCode (arrayGetUnsafe i a)) % costHashMod)

costHashMod : Int
costHashMod = 2147483647

-- ── Reading the `runs[]` provenance rows (#2208) ────────────────────────────
--
-- `runs[]` is a DIFFERENT axis from `gates[]`: one entry per CI row (shard
-- run), not per gate, keyed `"<runId>:<runAttempt>:<shard>"`.  Since S-1 it
-- also carries the row's own `jobs` (outer worker count), `parallel`
-- (whether the fan-out ran concurrently), and `rowElapsedMs` (the row's own
-- wall clock, spanning its whole `xargs -P $JOBS` fan-out) — all four
-- OPTIONAL, since a run ingested before this field existed has none of them
-- and must read as "unknown", never as a false 0/zero-cost.  `gates` (F-2,
-- #2178 review S2-1) is the fourth: the number of gates that shard's
-- registry had AT INGEST TIME, which lets a reader tell whether a later
-- rebalance moved gates on or off the row since — see `balCalibLine`.
-- `gatesDigest` (S-2, #2223) is the fifth, and exists because the fourth
-- answers a strictly weaker question than it looks like it does: a rebalance
-- that moves one gate OFF a row and another ON leaves `gates` unchanged, so a
-- count comparison reports "not stale" for a residual that is calibrating
-- against a gate set which no longer exists.  The digest is `gateSetDigest`
-- over that row's baseline keys at ingest time, and it catches the swap.
--
-- `jobs` (via `balJobsFor`/`balJobsIsFallback`) and `rowElapsedMs` (via
-- `balCalibLine`) ARE consumed by the balancer today; `parallel`, `gates` and
-- `gatesDigest` are read but only for the calibration/staleness report, never
-- the score itself.  See `test/gate_cost_baseline.json`'s own header note and the
-- module's own doc-comment above for why the file exists at all.

{- | One `runs[]` provenance row. -}
public export data RunRecord = RunRecord {
  key : String,
  runId : String,
  shard : String,
  jobs : Option Int,
  parallel : Option Bool,
  rowElapsedMs : Option Int,
  gates : Option Int,
  gatesDigest : Option Int,
}

runEntry : Int -> Json -> Result String RunRecord
runEntry i e = match asString (orNull (lookup "key" e))
  None =>
    Err "gate cost baseline: runs[\{intToString i}]: missing string field 'key'"
  Some k => match asString (orNull (lookup "runId" e))
    None =>
      Err
        "gate cost baseline: runs[\{intToString i}] '\{k}': missing string field 'runId'"
    Some rid => match asString (orNull (lookup "shard" e))
      None =>
        Err
          "gate cost baseline: runs[\{intToString i}] '\{k}': missing string field 'shard'"
      Some sh => Ok RunRecord {
        key = k,
        runId = rid,
        shard = sh,
        jobs = asInt (orNull (lookup "jobs" e)),
        parallel = asBool (orNull (lookup "parallel" e)),
        rowElapsedMs = asInt (orNull (lookup "rowElapsedMs" e)),
        gates = asInt (orNull (lookup "gates" e)),
        gatesDigest = asInt (orNull (lookup "gatesDigest" e)),
      }

runEntries : Array Json ->
  Int ->
  Int ->
  List RunRecord ->
  Result String (List RunRecord)
runEntries arr i n acc
  | i >= n = Ok (reverseRuns acc [])
  | otherwise = match runEntry i (arrayGetUnsafe i arr)
    Err m => Err m
    Ok r => runEntries arr (i + 1) n (r :: acc)

reverseRuns : List RunRecord -> List RunRecord -> List RunRecord
reverseRuns [] acc = acc
reverseRuns (r :: rs) acc = reverseRuns rs (r :: acc)

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
latestRunGo sh (r :: rs) acc
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
costOfKey k (c :: cs)
  | c.name == k = Some c.medianMs
  | otherwise = costOfKey k cs

{- | The whole baseline row for the gate whose script path is `run`, not just
   its median.  `costOf` answers what the packer SCHEDULES by; this answers
   what the packer's estimate was DERIVED from, which is what stating an
   out-of-sample error needs.  Same linear scan, same join key, same
   "a miss is a miss, never a zero" contract. -}
export
costRowOf : String -> List GateCost -> Option GateCost
costRowOf run cs = costRowOfKey (baselineKey run) cs

costRowOfKey : String -> List GateCost -> Option GateCost
costRowOfKey _ [] = None
costRowOfKey k (c :: cs)
  | c.name == k = Some c
  | otherwise = costRowOfKey k cs

-- ── Properties ──────────────────────────────────────────────────────────────

prop "baselineKey leaves a test/ gate's stem alone" (n : Int) =
  baselineKey "test/g\{intToString n}.sh" == "g\{intToString n}"

prop "baselineKey flattens every separator" (n : Int) =
  baselineKey "a/b/c\{intToString n}.sh" == "a_b_c\{intToString n}"

prop "baselineKey is idempotent on an already-flat key" (n : Int) =
  baselineKey (baselineKey "test/g\{intToString n}.sh")
    == baselineKey "test/g\{intToString n}.sh"

prop "packStat of one sample is that sample" (n : Int) = packStat (n :: []) == n

-- The robustness property the whole choice of statistic rests on: a single
-- wild sample among three cannot move the answer.  `pds_test_repo_vectors`
-- is this property with real numbers.
prop "one wild sample among three does not move packStat" (n : Int) =
  packStat (n :: n + 1 :: n + 1000000 :: []) == n + 1
    && packStat (n + 1000000 :: n :: n + 1 :: []) == n + 1

-- Order-independence is REQUIRED, not incidental: the ingester digests a
-- report's gates in pattern-resolution order and the balancer digests the
-- registry's in enrolment order.
prop "gateSetDigest ignores order" (n : Int) =
  gateSetDigest ("a\{intToString n}" :: "b\{intToString n}" :: [])
    == gateSetDigest ("b\{intToString n}" :: "a\{intToString n}" :: [])

-- ...and a swap at equal size must NOT be, which is the whole of #2223.
prop "gateSetDigest separates a same-size swap" (n : Int) =
  gateSetDigest ("a\{intToString n}" :: "b\{intToString n}" :: [])
    /= gateSetDigest ("a\{intToString n}" :: "c\{intToString n}" :: [])
# DESUGAR
(DUse false (UseGroup ("json") ((mem "JNull" false) (mem "Json" false) (mem "asArray" false) (mem "asBool" false) (mem "asInt" false) (mem "asString" false) (mem "lookup" false) (mem "parse" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "listLen" false) (mem "splitOnChar" false) (mem "startsWith" false))))
(DData Public "GateCost" () ((variant "GateCost" (ConNamed (field "name" (TyCon "String")) (field "medianMs" (TyCon "Int")) (field "samples" (TyCon "Int")) (field "ms" (TyApp (TyCon "List") (TyCon "Int"))) (field "sampleRuns" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig true "baselineKey" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "baselineKey" ((PVar "run")) (EBlock (DoLet false false (PVar "noExt") (EApp (EVar "dropDotSh") (EVar "run"))) (DoLet false false (PVar "flat") (EApp (EApp (EVar "joinWith") (ELit (LString "_"))) (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "noExt")))) (DoExpr (EApp (EVar "dropTestPrefix") (EVar "flat")))))
(DTypeSig false "dropDotSh" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dropDotSh" ((PVar "s")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 3))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 3)))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (ELit (LString ".sh")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 3)))) (EVar "s")) (EIf (EVar "otherwise") (EVar "s") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dropTestPrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dropTestPrefix" ((PVar "s")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "test_"))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 5))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EIf (EVar "otherwise") (EVar "s") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "costSchema" (TyCon "String"))
(DFunDef false "costSchema" () (ELit (LString "gate-cost-baseline/1")))
(DTypeSig false "costEntry" (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "GateCost")))))
(DFunDef false "costEntry" ((PVar "i") (PVar "e")) (EMatch (EApp (EVar "asString") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "name"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "]: missing string field 'name'"))))) (arm (PCon "Some" (PVar "n")) () (EMatch (EApp (EVar "asInt") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "medianMs"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "': missing integer field 'medianMs'"))))) (arm (PCon "Some" (PVar "ms")) ((GBool (EBinOp "<" (EVar "ms") (ELit (LInt 0))))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "': negative medianMs "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "ms")))) (ELit (LString ""))))) (arm (PCon "Some" (PVar "ms")) () (EMatch (EApp (EVar "asInt") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "samples"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "': missing integer field 'samples'"))))) (arm (PCon "Some" (PVar "sc")) ((GBool (EBinOp "<" (EVar "sc") (ELit (LInt 1))))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "': samples must be >= 1, got "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString ""))))) (arm (PCon "Some" (PVar "sc")) () (EMatch (EApp (EApp (EApp (EVar "costSamples") (EVar "i")) (EVar "n")) (EVar "e")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "raw")) ((GBool (EBinOp "/=" (EApp (EVar "listLen") (EVar "raw")) (EVar "sc")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "': samples is "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString " but 'ms' holds "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "raw"))))) (ELit (LString " value(s)"))))) (arm (PCon "Ok" (PVar "raw")) () (EApp (EApp (EVar "map") (ELam ((PVar "rids")) (ERecordCreate "GateCost" ((fa "name" (EVar "n")) (fa "medianMs" (EVar "ms")) (fa "samples" (EVar "sc")) (fa "ms" (EVar "raw")) (fa "sampleRuns" (EVar "rids")))))) (EApp (EApp (EApp (EApp (EVar "costSampleRuns") (EVar "i")) (EVar "n")) (EVar "e")) (EApp (EVar "listLen") (EVar "raw")))))))))))))
(DTypeSig false "costSamples" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "costSamples" ((PVar "i") (PVar "n") (PVar "e")) (EMatch (EApp (EVar "asArray") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "ms"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "': missing array field 'ms'"))))) (arm (PCon "Some" (PVar "arr")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "costSampleInts") (EVar "i")) (EVar "n")) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))) (EListLit)))))
(DTypeSig false "costSampleInts" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))))))
(DFunDef false "costSampleInts" ((PVar "i") (PVar "n") (PVar "arr") (PVar "k") (PVar "len") (PVar "acc")) (EIf (EBinOp ">=" (EVar "k") (EVar "len")) (EApp (EVar "Ok") (EApp (EApp (EVar "reverseInts") (EVar "acc")) (EListLit))) (EIf (EVar "otherwise") (EMatch (EApp (EVar "asInt") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arr"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "': ms["))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString "] is not an integer"))))) (arm (PCon "Some" (PVar "v")) ((GBool (EBinOp "<" (EVar "v") (ELit (LInt 0))))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "': ms["))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString "] is negative ("))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "v")))) (ELit (LString ")"))))) (arm (PCon "Some" (PVar "v")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "costSampleInts") (EVar "i")) (EVar "n")) (EVar "arr")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "len")) (EBinOp "::" (EVar "v") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "costSampleRuns" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "costSampleRuns" ((PVar "i") (PVar "n") (PVar "e") (PVar "want")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "sampleRuns"))) (EVar "e")) (arm (PCon "None") () (EApp (EVar "Ok") (EApp (EVar "blankRuns") (EVar "want")))) (arm (PCon "Some" (PCon "JNull")) () (EApp (EVar "Ok") (EApp (EVar "blankRuns") (EVar "want")))) (arm (PCon "Some" (PVar "j")) () (EMatch (EApp (EVar "asArray") (EVar "j")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "': 'sampleRuns' is present but is not an array"))))) (arm (PCon "Some" (PVar "arr")) ((GBool (EBinOp "/=" (EApp (EVar "arrayLength") (EVar "arr")) (EVar "want")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "': 'sampleRuns' holds "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "arrayLength") (EVar "arr"))))) (ELit (LString " entr(ies) but 'ms' holds "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "want")))) (ELit (LString ""))))) (arm (PCon "Some" (PVar "arr")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "costSampleRunStrs") (EVar "i")) (EVar "n")) (EVar "arr")) (ELit (LInt 0))) (EVar "want")) (EListLit)))))))
(DTypeSig false "costSampleRunStrs" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "costSampleRunStrs" ((PVar "i") (PVar "n") (PVar "arr") (PVar "k") (PVar "len") (PVar "acc")) (EIf (EBinOp ">=" (EVar "k") (EVar "len")) (EApp (EVar "Ok") (EApp (EApp (EVar "reverseStrs") (EVar "acc")) (EListLit))) (EIf (EVar "otherwise") (EMatch (EApp (EVar "asString") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arr"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "': sampleRuns["))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString "] is not a string"))))) (arm (PCon "Some" (PVar "v")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "costSampleRunStrs") (EVar "i")) (EVar "n")) (EVar "arr")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "len")) (EBinOp "::" (EVar "v") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "blankRuns" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "blankRuns" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (ELit (LString "")) (EApp (EVar "blankRuns") (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reverseStrs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reverseStrs" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseStrs" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "reverseStrs") (EVar "xs")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DTypeSig false "reverseInts" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "reverseInts" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseInts" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "reverseInts") (EVar "xs")) (EBinOp "::" (EVar "x") (EVar "acc"))))
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
(DTypeSig true "packStat" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "packStat" ((PList)) (ELit (LInt 0)))
(DFunDef false "packStat" ((PVar "xs")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "costSortInts") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "costNth") (EBinOp "-" (EBinOp "/" (EBinOp "+" (EApp (EVar "listLen") (EVar "s")) (ELit (LInt 1))) (ELit (LInt 2))) (ELit (LInt 1)))) (EVar "s")))))
(DTypeSig false "costSortInts" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "costSortInts" ((PList)) (EListLit))
(DFunDef false "costSortInts" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "costInsert") (EVar "x")) (EApp (EVar "costSortInts") (EVar "xs"))))
(DTypeSig false "costInsert" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "costInsert" ((PVar "x") (PList)) (EBinOp "::" (EVar "x") (EListLit)))
(DFunDef false "costInsert" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "<=" (EVar "x") (EVar "y")) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "costInsert") (EVar "x")) (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "costNth" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int"))))
(DFunDef false "costNth" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "costNth" ((PVar "i") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "x") (EIf (EVar "otherwise") (EApp (EApp (EVar "costNth") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "gateSetDigest" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))
(DFunDef false "gateSetDigest" ((PVar "ns")) (EApp (EApp (EVar "gateSetDigestGo") (EVar "ns")) (ELit (LInt 0))))
(DTypeSig false "gateSetDigestGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "gateSetDigestGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "gateSetDigestGo" ((PCons (PVar "n") (PVar "ns")) (PVar "acc")) (EApp (EApp (EVar "gateSetDigestGo") (EVar "ns")) (EBinOp "%" (EBinOp "+" (EVar "acc") (EApp (EVar "gateNameHash") (EVar "n"))) (EVar "costHashMod"))))
(DTypeSig true "gateNameHash" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "gateNameHash" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "gateNameHashGo") (EVar "a")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "a"))) (ELit (LInt 7))))))
(DTypeSig false "gateNameHashGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "gateNameHashGo" ((PVar "a") (PVar "i") (PVar "n") (PVar "h")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "h") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "gateNameHashGo") (EVar "a")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "%" (EBinOp "+" (EBinOp "*" (EVar "h") (ELit (LInt 131))) (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a")))) (EVar "costHashMod"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "costHashMod" (TyCon "Int"))
(DFunDef false "costHashMod" () (ELit (LInt 2147483647)))
(DData Public "RunRecord" () ((variant "RunRecord" (ConNamed (field "key" (TyCon "String")) (field "runId" (TyCon "String")) (field "shard" (TyCon "String")) (field "jobs" (TyApp (TyCon "Option") (TyCon "Int"))) (field "parallel" (TyApp (TyCon "Option") (TyCon "Bool"))) (field "rowElapsedMs" (TyApp (TyCon "Option") (TyCon "Int"))) (field "gates" (TyApp (TyCon "Option") (TyCon "Int"))) (field "gatesDigest" (TyApp (TyCon "Option") (TyCon "Int")))))) ())
(DTypeSig false "runEntry" (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "RunRecord")))))
(DFunDef false "runEntry" ((PVar "i") (PVar "e")) (EMatch (EApp (EVar "asString") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "key"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: runs[")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "]: missing string field 'key'"))))) (arm (PCon "Some" (PVar "k")) () (EMatch (EApp (EVar "asString") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "runId"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: runs[")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EVar "display") (EVar "k"))) (ELit (LString "': missing string field 'runId'"))))) (arm (PCon "Some" (PVar "rid")) () (EMatch (EApp (EVar "asString") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "shard"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: runs[")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EVar "display") (EVar "k"))) (ELit (LString "': missing string field 'shard'"))))) (arm (PCon "Some" (PVar "sh")) () (EApp (EVar "Ok") (ERecordCreate "RunRecord" ((fa "key" (EVar "k")) (fa "runId" (EVar "rid")) (fa "shard" (EVar "sh")) (fa "jobs" (EApp (EVar "asInt") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "jobs"))) (EVar "e"))))) (fa "parallel" (EApp (EVar "asBool") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "parallel"))) (EVar "e"))))) (fa "rowElapsedMs" (EApp (EVar "asInt") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "rowElapsedMs"))) (EVar "e"))))) (fa "gates" (EApp (EVar "asInt") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "gates"))) (EVar "e"))))) (fa "gatesDigest" (EApp (EVar "asInt") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "gatesDigest"))) (EVar "e")))))))))))))))
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
(DTypeSig true "costRowOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyApp (TyCon "Option") (TyCon "GateCost")))))
(DFunDef false "costRowOf" ((PVar "run") (PVar "cs")) (EApp (EApp (EVar "costRowOfKey") (EApp (EVar "baselineKey") (EVar "run"))) (EVar "cs")))
(DTypeSig false "costRowOfKey" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyApp (TyCon "Option") (TyCon "GateCost")))))
(DFunDef false "costRowOfKey" (PWild (PList)) (EVar "None"))
(DFunDef false "costRowOfKey" ((PVar "k") (PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "c") "name") (EVar "k")) (EApp (EVar "Some") (EVar "c")) (EIf (EVar "otherwise") (EApp (EApp (EVar "costRowOfKey") (EVar "k")) (EVar "cs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DProp false "baselineKey leaves a test/ gate's stem alone" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "baselineKey") (EBinOp "++" (EBinOp "++" (ELit (LString "test/g")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ".sh")))) (EBinOp "++" (EBinOp "++" (ELit (LString "g")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "")))))
(DProp false "baselineKey flattens every separator" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "baselineKey") (EBinOp "++" (EBinOp "++" (ELit (LString "a/b/c")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ".sh")))) (EBinOp "++" (EBinOp "++" (ELit (LString "a_b_c")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "")))))
(DProp false "baselineKey is idempotent on an already-flat key" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "baselineKey") (EApp (EVar "baselineKey") (EBinOp "++" (EBinOp "++" (ELit (LString "test/g")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ".sh"))))) (EApp (EVar "baselineKey") (EBinOp "++" (EBinOp "++" (ELit (LString "test/g")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ".sh"))))))
(DProp false "packStat of one sample is that sample" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "packStat") (EBinOp "::" (EVar "n") (EListLit))) (EVar "n")))
(DProp false "one wild sample among three does not move packStat" ((pp "n" (TyCon "Int"))) (EBinOp "&&" (EBinOp "==" (EApp (EVar "packStat") (EBinOp "::" (EVar "n") (EBinOp "::" (EBinOp "+" (EVar "n") (ELit (LInt 1))) (EBinOp "::" (EBinOp "+" (EVar "n") (ELit (LInt 1000000))) (EListLit))))) (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EBinOp "==" (EApp (EVar "packStat") (EBinOp "::" (EBinOp "+" (EVar "n") (ELit (LInt 1000000))) (EBinOp "::" (EVar "n") (EBinOp "::" (EBinOp "+" (EVar "n") (ELit (LInt 1))) (EListLit))))) (EBinOp "+" (EVar "n") (ELit (LInt 1))))))
(DProp false "gateSetDigest ignores order" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "gateSetDigest") (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "a")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "b")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EListLit)))) (EApp (EVar "gateSetDigest") (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "b")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "a")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EListLit))))))
(DProp false "gateSetDigest separates a same-size swap" ((pp "n" (TyCon "Int"))) (EBinOp "/=" (EApp (EVar "gateSetDigest") (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "a")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "b")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EListLit)))) (EApp (EVar "gateSetDigest") (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "a")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "c")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EListLit))))))
# MARK
(DUse false (UseGroup ("json") ((mem "JNull" false) (mem "Json" false) (mem "asArray" false) (mem "asBool" false) (mem "asInt" false) (mem "asString" false) (mem "lookup" false) (mem "parse" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "listLen" false) (mem "splitOnChar" false) (mem "startsWith" false))))
(DData Public "GateCost" () ((variant "GateCost" (ConNamed (field "name" (TyCon "String")) (field "medianMs" (TyCon "Int")) (field "samples" (TyCon "Int")) (field "ms" (TyApp (TyCon "List") (TyCon "Int"))) (field "sampleRuns" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig true "baselineKey" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "baselineKey" ((PVar "run")) (EBlock (DoLet false false (PVar "noExt") (EApp (EVar "dropDotSh") (EVar "run"))) (DoLet false false (PVar "flat") (EApp (EApp (EVar "joinWith") (ELit (LString "_"))) (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "noExt")))) (DoExpr (EApp (EVar "dropTestPrefix") (EDictApp "flat")))))
(DTypeSig false "dropDotSh" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dropDotSh" ((PVar "s")) (EIf (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 3))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 3)))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (ELit (LString ".sh")))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 3)))) (EVar "s")) (EIf (EVar "otherwise") (EVar "s") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dropTestPrefix" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "dropTestPrefix" ((PVar "s")) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "test_"))) (EVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 5))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EIf (EVar "otherwise") (EVar "s") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "costSchema" (TyCon "String"))
(DFunDef false "costSchema" () (ELit (LString "gate-cost-baseline/1")))
(DTypeSig false "costEntry" (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "GateCost")))))
(DFunDef false "costEntry" ((PVar "i") (PVar "e")) (EMatch (EApp (EVar "asString") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "name"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "]: missing string field 'name'"))))) (arm (PCon "Some" (PVar "n")) () (EMatch (EApp (EVar "asInt") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "medianMs"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "': missing integer field 'medianMs'"))))) (arm (PCon "Some" (PVar "ms")) ((GBool (EBinOp "<" (EVar "ms") (ELit (LInt 0))))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "': negative medianMs "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "ms")))) (ELit (LString ""))))) (arm (PCon "Some" (PVar "ms")) () (EMatch (EApp (EVar "asInt") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "samples"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "': missing integer field 'samples'"))))) (arm (PCon "Some" (PVar "sc")) ((GBool (EBinOp "<" (EVar "sc") (ELit (LInt 1))))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "': samples must be >= 1, got "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString ""))))) (arm (PCon "Some" (PVar "sc")) () (EMatch (EApp (EApp (EApp (EVar "costSamples") (EVar "i")) (EVar "n")) (EVar "e")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PVar "raw")) ((GBool (EBinOp "/=" (EApp (EVar "listLen") (EVar "raw")) (EVar "sc")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "': samples is "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "sc")))) (ELit (LString " but 'ms' holds "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "raw"))))) (ELit (LString " value(s)"))))) (arm (PCon "Ok" (PVar "raw")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "rids")) (ERecordCreate "GateCost" ((fa "name" (EVar "n")) (fa "medianMs" (EVar "ms")) (fa "samples" (EVar "sc")) (fa "ms" (EVar "raw")) (fa "sampleRuns" (EVar "rids")))))) (EApp (EApp (EApp (EApp (EVar "costSampleRuns") (EVar "i")) (EVar "n")) (EVar "e")) (EApp (EVar "listLen") (EVar "raw")))))))))))))
(DTypeSig false "costSamples" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "costSamples" ((PVar "i") (PVar "n") (PVar "e")) (EMatch (EApp (EVar "asArray") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "ms"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "': missing array field 'ms'"))))) (arm (PCon "Some" (PVar "arr")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "costSampleInts") (EVar "i")) (EVar "n")) (EVar "arr")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr"))) (EListLit)))))
(DTypeSig false "costSampleInts" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Int"))))))))))
(DFunDef false "costSampleInts" ((PVar "i") (PVar "n") (PVar "arr") (PVar "k") (PVar "len") (PVar "acc")) (EIf (EBinOp ">=" (EVar "k") (EVar "len")) (EApp (EVar "Ok") (EApp (EApp (EVar "reverseInts") (EVar "acc")) (EListLit))) (EIf (EVar "otherwise") (EMatch (EApp (EVar "asInt") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arr"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "': ms["))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString "] is not an integer"))))) (arm (PCon "Some" (PVar "v")) ((GBool (EBinOp "<" (EVar "v") (ELit (LInt 0))))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "': ms["))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString "] is negative ("))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "v")))) (ELit (LString ")"))))) (arm (PCon "Some" (PVar "v")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "costSampleInts") (EVar "i")) (EVar "n")) (EVar "arr")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "len")) (EBinOp "::" (EVar "v") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "costSampleRuns" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Int") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "costSampleRuns" ((PVar "i") (PVar "n") (PVar "e") (PVar "want")) (EMatch (EApp (EApp (EVar "lookup") (ELit (LString "sampleRuns"))) (EVar "e")) (arm (PCon "None") () (EApp (EVar "Ok") (EApp (EVar "blankRuns") (EVar "want")))) (arm (PCon "Some" (PCon "JNull")) () (EApp (EVar "Ok") (EApp (EVar "blankRuns") (EVar "want")))) (arm (PCon "Some" (PVar "j")) () (EMatch (EApp (EVar "asArray") (EVar "j")) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "': 'sampleRuns' is present but is not an array"))))) (arm (PCon "Some" (PVar "arr")) ((GBool (EBinOp "/=" (EApp (EVar "arrayLength") (EVar "arr")) (EVar "want")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "': 'sampleRuns' holds "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "arrayLength") (EVar "arr"))))) (ELit (LString " entr(ies) but 'ms' holds "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "want")))) (ELit (LString ""))))) (arm (PCon "Some" (PVar "arr")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "costSampleRunStrs") (EVar "i")) (EVar "n")) (EVar "arr")) (ELit (LInt 0))) (EVar "want")) (EListLit)))))))
(DTypeSig false "costSampleRunStrs" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Json")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))))
(DFunDef false "costSampleRunStrs" ((PVar "i") (PVar "n") (PVar "arr") (PVar "k") (PVar "len") (PVar "acc")) (EIf (EBinOp ">=" (EVar "k") (EVar "len")) (EApp (EVar "Ok") (EApp (EApp (EVar "reverseStrs") (EVar "acc")) (EListLit))) (EIf (EVar "otherwise") (EMatch (EApp (EVar "asString") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "arr"))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: gates[")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "': sampleRuns["))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString "] is not a string"))))) (arm (PCon "Some" (PVar "v")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "costSampleRunStrs") (EVar "i")) (EVar "n")) (EVar "arr")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "len")) (EBinOp "::" (EVar "v") (EVar "acc"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "blankRuns" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "blankRuns" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (ELit (LString "")) (EApp (EVar "blankRuns") (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "reverseStrs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "reverseStrs" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseStrs" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "reverseStrs") (EVar "xs")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DTypeSig false "reverseInts" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "reverseInts" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseInts" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "reverseInts") (EVar "xs")) (EBinOp "::" (EVar "x") (EVar "acc"))))
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
(DTypeSig true "packStat" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "packStat" ((PList)) (ELit (LInt 0)))
(DFunDef false "packStat" ((PVar "xs")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "costSortInts") (EVar "xs"))) (DoExpr (EApp (EApp (EVar "costNth") (EBinOp "-" (EBinOp "/" (EBinOp "+" (EApp (EVar "listLen") (EVar "s")) (ELit (LInt 1))) (ELit (LInt 2))) (ELit (LInt 1)))) (EVar "s")))))
(DTypeSig false "costSortInts" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "costSortInts" ((PList)) (EListLit))
(DFunDef false "costSortInts" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "costInsert") (EVar "x")) (EApp (EVar "costSortInts") (EVar "xs"))))
(DTypeSig false "costInsert" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "costInsert" ((PVar "x") (PList)) (EBinOp "::" (EVar "x") (EListLit)))
(DFunDef false "costInsert" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "<=" (EVar "x") (EVar "y")) (EBinOp "::" (EVar "x") (EBinOp "::" (EVar "y") (EVar "ys"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "costInsert") (EVar "x")) (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "costNth" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int"))))
(DFunDef false "costNth" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "costNth" ((PVar "i") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "x") (EIf (EVar "otherwise") (EApp (EApp (EVar "costNth") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "gateSetDigest" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))
(DFunDef false "gateSetDigest" ((PVar "ns")) (EApp (EApp (EVar "gateSetDigestGo") (EVar "ns")) (ELit (LInt 0))))
(DTypeSig false "gateSetDigestGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "gateSetDigestGo" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "gateSetDigestGo" ((PCons (PVar "n") (PVar "ns")) (PVar "acc")) (EApp (EApp (EVar "gateSetDigestGo") (EVar "ns")) (EBinOp "%" (EBinOp "+" (EVar "acc") (EApp (EVar "gateNameHash") (EVar "n"))) (EVar "costHashMod"))))
(DTypeSig true "gateNameHash" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "gateNameHash" ((PVar "s")) (EBlock (DoLet false false (PVar "a") (EApp (EVar "stringToChars") (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "gateNameHashGo") (EVar "a")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "a"))) (ELit (LInt 7))))))
(DTypeSig false "gateNameHashGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "gateNameHashGo" ((PVar "a") (PVar "i") (PVar "n") (PVar "h")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (EVar "h") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "gateNameHashGo") (EVar "a")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")) (EBinOp "%" (EBinOp "+" (EBinOp "*" (EVar "h") (ELit (LInt 131))) (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "a")))) (EVar "costHashMod"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "costHashMod" (TyCon "Int"))
(DFunDef false "costHashMod" () (ELit (LInt 2147483647)))
(DData Public "RunRecord" () ((variant "RunRecord" (ConNamed (field "key" (TyCon "String")) (field "runId" (TyCon "String")) (field "shard" (TyCon "String")) (field "jobs" (TyApp (TyCon "Option") (TyCon "Int"))) (field "parallel" (TyApp (TyCon "Option") (TyCon "Bool"))) (field "rowElapsedMs" (TyApp (TyCon "Option") (TyCon "Int"))) (field "gates" (TyApp (TyCon "Option") (TyCon "Int"))) (field "gatesDigest" (TyApp (TyCon "Option") (TyCon "Int")))))) ())
(DTypeSig false "runEntry" (TyFun (TyCon "Int") (TyFun (TyCon "Json") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "RunRecord")))))
(DFunDef false "runEntry" ((PVar "i") (PVar "e")) (EMatch (EApp (EVar "asString") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "key"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: runs[")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "]: missing string field 'key'"))))) (arm (PCon "Some" (PVar "k")) () (EMatch (EApp (EVar "asString") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "runId"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: runs[")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EMethodRef "display") (EVar "k"))) (ELit (LString "': missing string field 'runId'"))))) (arm (PCon "Some" (PVar "rid")) () (EMatch (EApp (EVar "asString") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "shard"))) (EVar "e")))) (arm (PCon "None") () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "gate cost baseline: runs[")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "i")))) (ELit (LString "] '"))) (EApp (EMethodRef "display") (EVar "k"))) (ELit (LString "': missing string field 'shard'"))))) (arm (PCon "Some" (PVar "sh")) () (EApp (EVar "Ok") (ERecordCreate "RunRecord" ((fa "key" (EVar "k")) (fa "runId" (EVar "rid")) (fa "shard" (EVar "sh")) (fa "jobs" (EApp (EVar "asInt") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "jobs"))) (EVar "e"))))) (fa "parallel" (EApp (EVar "asBool") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "parallel"))) (EVar "e"))))) (fa "rowElapsedMs" (EApp (EVar "asInt") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "rowElapsedMs"))) (EVar "e"))))) (fa "gates" (EApp (EVar "asInt") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "gates"))) (EVar "e"))))) (fa "gatesDigest" (EApp (EVar "asInt") (EApp (EVar "orNull") (EApp (EApp (EVar "lookup") (ELit (LString "gatesDigest"))) (EVar "e")))))))))))))))
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
(DTypeSig true "costRowOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyApp (TyCon "Option") (TyCon "GateCost")))))
(DFunDef false "costRowOf" ((PVar "run") (PVar "cs")) (EApp (EApp (EVar "costRowOfKey") (EApp (EVar "baselineKey") (EVar "run"))) (EVar "cs")))
(DTypeSig false "costRowOfKey" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyApp (TyCon "Option") (TyCon "GateCost")))))
(DFunDef false "costRowOfKey" (PWild (PList)) (EVar "None"))
(DFunDef false "costRowOfKey" ((PVar "k") (PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "c") "name") (EVar "k")) (EApp (EVar "Some") (EVar "c")) (EIf (EVar "otherwise") (EApp (EApp (EVar "costRowOfKey") (EVar "k")) (EVar "cs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DProp false "baselineKey leaves a test/ gate's stem alone" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "baselineKey") (EBinOp "++" (EBinOp "++" (ELit (LString "test/g")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ".sh")))) (EBinOp "++" (EBinOp "++" (ELit (LString "g")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "")))))
(DProp false "baselineKey flattens every separator" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "baselineKey") (EBinOp "++" (EBinOp "++" (ELit (LString "a/b/c")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ".sh")))) (EBinOp "++" (EBinOp "++" (ELit (LString "a_b_c")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString "")))))
(DProp false "baselineKey is idempotent on an already-flat key" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "baselineKey") (EApp (EVar "baselineKey") (EBinOp "++" (EBinOp "++" (ELit (LString "test/g")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ".sh"))))) (EApp (EVar "baselineKey") (EBinOp "++" (EBinOp "++" (ELit (LString "test/g")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ".sh"))))))
(DProp false "packStat of one sample is that sample" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "packStat") (EBinOp "::" (EVar "n") (EListLit))) (EVar "n")))
(DProp false "one wild sample among three does not move packStat" ((pp "n" (TyCon "Int"))) (EBinOp "&&" (EBinOp "==" (EApp (EVar "packStat") (EBinOp "::" (EVar "n") (EBinOp "::" (EBinOp "+" (EVar "n") (ELit (LInt 1))) (EBinOp "::" (EBinOp "+" (EVar "n") (ELit (LInt 1000000))) (EListLit))))) (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EBinOp "==" (EApp (EVar "packStat") (EBinOp "::" (EBinOp "+" (EVar "n") (ELit (LInt 1000000))) (EBinOp "::" (EVar "n") (EBinOp "::" (EBinOp "+" (EVar "n") (ELit (LInt 1))) (EListLit))))) (EBinOp "+" (EVar "n") (ELit (LInt 1))))))
(DProp false "gateSetDigest ignores order" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "gateSetDigest") (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "a")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "b")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EListLit)))) (EApp (EVar "gateSetDigest") (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "b")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "a")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EListLit))))))
(DProp false "gateSetDigest separates a same-size swap" ((pp "n" (TyCon "Int"))) (EBinOp "/=" (EApp (EVar "gateSetDigest") (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "a")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "b")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EListLit)))) (EApp (EVar "gateSetDigest") (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "a")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "c")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EListLit))))))
