# META
source_lines=2238
stages=DESUGAR,MARK
# SOURCE
{- gate_pack.mdk — the gate SCHEDULER: `medaka gate balance`'s bin packing and
   `medaka gate budget`'s governor (#2178, #2180).

   Everything here is a pure function of the registry text plus the cost
   baseline `test/gate_cost_baseline.json`: the candidate/row model
   (`Cand`/`Row`/`Place`), the makespan objective and its floor, the packing
   itself, the stability and out-of-sample-error statistics, the rendered
   report, and the budget governor's three clauses.  Nothing here reads or
   writes a byte — `gate_cmd.mdk` keeps the argv parsers, the file IO, and the
   `--check` comparison, and calls in at `balNewText` and `budgetOutput`.

   `timeoutFor` lives here because the budget governor's tolerance is derived
   from it (`budgetToleratedMs`); `gate run` imports it back for its own fuse,
   which is the one direction of traffic that does not point at the packer. -}

import tools.gate_registry.{
  Gate,
  Shard,
  parseRegistry,
  parseShards,
  joinSpace,
}
import tools.gate_cost.{
  GateCost,
  RunRecord,
  baselineKey,
  costOf,
  costRowOf,
  gateSetDigest,
  latestRunForShard,
  packStat,
  parseCostBaseline,
  parseCostRuns,
}
import support.util.{
  contains,
  isNonEmptyL,
  joinNl,
  listLen,
  maxI,
  minI,
  reverseL,
  splitNl,
  splitOnChar,
  startsWith,
  stringTrim,
}

-- ── timeout policy ──────────────────────────────────────────────────────────
--
-- A FUSE, NOT A BUDGET.  The bound exists so a hung gate cannot hold this
-- command (or a CI runner) forever; it is deliberately far above any gate's
-- real runtime, because a bound tight enough to be a perf budget would make
-- `medaka gate run` behavior-CHANGING for the slowest gates — and per-gate cost
-- budgets are #2180's job, fed by the timing report this command emits, not
-- something to smuggle in as a kill signal.  `diff_compiler_perf_scaling` and
-- `diff_compiler_engines` can already exceed the 10-minute foreground ceiling
-- ([L-FOREGROUND-CEILING]), which is why `heavy` is an hour and not ten minutes.
--
-- The registry's `cost` today takes exactly three values (cheap/medium/heavy);
-- an unrecognized one gets the middle bound rather than an error, so a future
-- tier added to the schema degrades to "still fused" instead of "won't run".
export
timeoutFor : Int -> String -> Int
timeoutFor override cost
  | override > 0 = override
  | cost == "cheap" = 300
  | cost == "medium" = 900
  | cost == "heavy" = 3600
  | otherwise = 900

-- ── `gate balance` (#2178) ──────────────────────────────────────────────────
--
-- `medaka gate balance` CHOOSES each gate's `shard` row, from the registry's
-- own constraints plus S-1's measured cost baseline
-- (`test/gate_cost_baseline.json`), instead of the hand-assignment the header
-- of `test/gates.toml` describes as "HAND-ASSIGNED DATA, NOT A DERIVED
-- OUTPUT".  After this command the eight row NAMES are still fixed (they are
-- required status-check contexts, `gates (<name>)`, so they are not free to
-- change) — only which gates land in each is computed.
--
-- THE ASSIGNMENT LIVES IN `test/gates.toml`, by TARGETED LINE REPLACEMENT.
-- The alternative — a second, generated file that overrides the registry's
-- `shard` — was rejected: `gate ci`, `gate list`, `gate verify`,
-- `diff_compiler_ci_shard_coverage.sh` and `test/preflight.sh` all read
-- `shard` from this file today, and a second source of truth is only safe if
-- EVERY one of them learns the override rule.  Any that does not schedules
-- from stale data silently, which is [W-THIRD-CONSUMER] with extra steps; and
-- a `shard` field left present-but-vestigial is a lie that greps true.  So
-- there stays exactly one place a row assignment is written, and this command
-- rewrites it.
--
-- Only the `shard = "…"` lines move.  `stdlib/toml.mdk` is a PARSER with no
-- serializer, so round-tripping 230 hand-written entries through it is not
-- available and would be a formatting-drift trap if it were (`balSplice`).
--
-- ── The objective ───────────────────────────────────────────────────────────
--
-- The `gates` job's wall-clock is its SLOWEST row (the pole); its billed
-- runner-time is `rows × pole`.  So the waste a balancer can actually remove
-- is the gap between the pole and the best pole any assignment could reach —
-- the FLOOR — and the enforced statement is `pole / floor` (`balFactorMilli`).
--
-- IT USED TO BE `pole / median`, AND THAT METRIC WAS PERVERSE IN BOTH
-- DIRECTIONS (S-4, #2216).  Its denominator is a property of the SUITE, not of
-- the packing, so it moved for reasons the balancer neither caused nor could
-- repair:
--
--   * The pole is one indivisible gate.  A 16-20% slowdown in that ONE gate
--     raises the pole while the median stands still, so `ci-gen-drift` — a
--     REQUIRED check — goes red with no repair available to anyone who did not
--     write that gate.  `dominating_gate.toml` was that case as a fixture, and
--     it was committed as a REFUSAL.
--   * Worse, the same metric reds when the suite gets FASTER.  Speed up every
--     non-pole gate by 4× and the median falls while the pole does not, so
--     `pole / median` RISES.  `nonpole_speedup.toml` is that measured: an
--     optimally packed 7-gate suite scoring 3.333 against a target of 1.250.
--
-- The floor is the ACHIEVABLE pole: the largest of three quantities, each of
-- which the pole provably cannot go below (`balFloor`) —
--
--   1. the most expensive single gate (gates are indivisible, so whichever row
--      holds it has a makespan at least that big);
--   2. the heaviest CLOSED row's makespan (the packer moves nothing onto a
--      `full_cores` row or off it, so that row's load is fixed input);
--   3. the open gates' total work divided by the open rows' worker SLOTS — a
--      row's capacity is its recorded `rjobs` parallel workers, not one
--      (`balJobsFor`), so `sum(rjobs) × pole >= total work`.
--
-- So `pole / floor >= 1.000` always, it is 1.000 exactly when the packing is
-- optimal, and it moves ONLY when the packing changes: both perverse cases
-- above score 1.000 under it, and the classic LPT worst case
-- (`lpt_packing_gap.toml`) still scores 1.222 and is still refused.  It is a
-- budget and not a wish — `balance` and `balance --check` both FAIL when the
-- assignment they would emit misses it.
--
-- The floor is a LOWER BOUND, not always an achievable makespan: 500 + three
-- 300s over three rows floors at 500 and cannot finish before 600.  So a miss
-- can still be indivisibility rather than packing, and `balEnforce` keeps two
-- messages so a reader is never sent to "rebalance harder" when the answer is
-- "this gate has to get FASTER".
--
-- ONE VALID FLOOR TERM IS DELIBERATELY OMITTED: the wasm-constrained gates'
-- own work over the wasm rows' slots.  Leaving a valid term out makes the floor
-- SMALLER and the ratio LARGER, i.e. strictly stricter, so it cannot manufacture
-- a false green; add it if a wasm-only red ever turns out to be unrepairable.
--
-- ── A row's score is its MAKESPAN, and it predicts real wall clock ──────────
--
-- THIS SECTION USED TO SAY THE OPPOSITE, AND THE OLD CLAIM WAS FALSE.  It
-- read "costs are RELATIVE, not predicted wall-clock", and justified scoring a
-- row by the SUM of its gates' medians on the grounds that the sum "is NOT
-- what CI will print for the row" but is still the right relative signal.  It
-- is not.  CI does not run a row's gates one after another: `test/run_gates.sh`
-- fans them out through an `xargs -P $JOBS` pool, so what CI prints for a row
-- is the MAKESPAN over `$JOBS` workers, and a sum over-states every row by
-- roughly `$JOBS`× — unevenly, because a row of one huge gate and a row of
-- many small ones do not shrink by the same factor under the same pool.  A
-- score that is wrong by a per-row-varying factor is not a relative signal
-- either; it is the pole being minimised on the wrong axis.
--
-- So a row's load here is the makespan of scheduling its gates onto `$JOBS`
-- worker buckets, longest-first, mirroring the pool: `balBucketAdd` puts each
-- gate on the least-loaded bucket and `rload` is the fullest bucket.  This is
-- an LPT simulation NESTED inside the LPT across rows (`balSortCands`), which
-- is why both take their candidates cost-descending.
--
-- `$JOBS` IS READ, NEVER ASSUMED.  `run_gates.sh` derives it from the
-- runner's core count (`(NCPU*3+2)/5`), so it is not one fixed number and no
-- literal here can stand in for it.  Since S-1 each row's own run records the
-- `jobs` it actually used, and `balJobsFor` reads that — see its own note for
-- what happens to a row that has never been recorded.
--
-- THE MODEL IS VALIDATED AGAINST SOMETHING OTHER THAN ITSELF.  S-1 also
-- records each row's `rowElapsedMs` — the row's real CI wall clock, spanning
-- the whole fan-out.  `balCalibLines` prints, per row, that recorded number
-- against this model's prediction for the COMMITTED assignment, and the
-- residual between them.  A model whose only evidence is its own arithmetic
-- would be unfalsifiable; this block is what makes it checkable by a reader.
-- Read the caveat in `balCalibLines` before reading the residuals: they are
-- only comparable while the committed assignment is still the one that ran.

-- One schedulable gate, joined with its measured cost.
data Cand = Cand {
  cname : String,
  crun : String,
  curRow : String,
  cms : Int,
  needsWasm : Bool,
}

-- One matrix row, with the load accumulated onto it so far.
--
-- `rload` is the row's MAKESPAN, not the sum of its gates: the fullest of its
-- `rjobs` worker buckets.  It is kept as a field rather than recomputed at
-- every read because `balPick` consults it once per candidate per row.
-- `rbuckets` always has exactly `rjobs` entries (`balJobsFor` guarantees
-- `rjobs >= 1`), and the two are only ever updated together, by `balAdd`.
data Row = Row {
  rname : String,
  rwasm : Bool,
  rclosed : Bool,
  rload : Int,
  rcount : Int,
  rjobs : Int,
  rbuckets : List Int,
}

-- One gate's outcome: where it goes, and where it came from.
data Place = Place { pname : String, pfrom : String, pto : String }

{- | The sentinel `shard` value for a gate some other workflow job schedules.
   These never enter the packing (derive the current count, don't trust one
   pinned here: `grep -c '^shard = "other-job"$' test/gates.toml` — it rots on
   every enrolment/removal): they never go through `test/run_gates.sh`, and so
   they structurally cannot appear in the cost baseline either.
   `diff_compiler_must_fail` is one of them — its INVERTED
   polarity ([G-MUST-FAIL]) is `compiler-soundness`'s business, and a matrix
   balancer must never so much as see it. -}
export
balOtherJob : String
balOtherJob = "other-job"

{- | The enforced `pole / floor` budget, in thousandths.  See "The objective"
   for what the floor is and why the denominator stopped being the median.

   1.125 IS DERIVED FROM A MEASUREMENT, NOT CHOSEN.  The arithmetic, in full,
   so a future reader can redo it rather than trust it:

     * The metric's own optimum is 1.000, by construction — `balFloor` is a
       lower bound on the pole, so the ratio cannot go below one and the whole
       budget is PACKING SLACK.  There is no achieved-value term to leave room
       for, which is exactly what the old `pole / median` ceiling had to do.

     * What the budget must absorb is therefore only re-ingest NOISE: the
       baseline's `medianMs` values move on every scheduled ingest, and both
       the pole and the floor are recomputed from them.  S-2 measured that
       noise out-of-sample rather than guessing at it — leave-one-run-out over
       the 3 runs in `runs[]`, across 202 of 202 schedulable gates: per-run
       errors -21.1% / -6.1% / -9.0%, mean |error| 12.0%, systematic bias
       -12.5% (the median is deliberately low-side robust —
       `gate_cost.packStat`).

       THOSE FIVE NUMBERS ARE ONE HISTORICAL MEASUREMENT, NOT A FIGURE THE
       TOOL RE-DERIVES.  They were taken on the baseline as it stood at S-2,
       by a `balOosBlock` that inferred each sample's run from its POSITION;
       FR-1 (#2222 review S0-1) showed that inference is unsound in general
       and replaced it with a recorded per-sample runId, so the block now
       reports "not derivable" on any baseline whose samples predate
       `sampleRuns` — which includes the one these numbers came from.  The
       budget below therefore stands on the S-2 measurement as a dated
       observation.  Re-derive it, and this constant with it, once enough
       attributed ingests have landed for `balOosBlock` to print a figure
       again.

     * Budget = 1 + max(mean |error|, |bias|) = 1 + max(0.120, 0.125) = 1.125.
       The LARGER of the two terms, because they are two ways of being wrong
       about the same prediction and a budget has to cover the worse one.

   THAT IS THE CONSERVATIVE DIRECTION, KNOWINGLY.  Much of the measured error
   is COMMON MODE — a run that is 12% slow is slow in the numerator and the
   denominator alike — and a common-mode factor cancels in a ratio, so 12.5% is
   an upper bound on the noise this metric can actually inherit, not an
   estimate of it.  Erring high is deliberate: the failure mode of a too-tight
   budget is a red `ci-gen-drift` with no repair available, which is the exact
   defect (#2216) this metric exists to remove.  Erring high costs only
   sensitivity to a packing that is bad by less than an eighth.

   IT IS STILL A REAL CONSTRAINT, WHICH IS WHY IT WAS NOT ROUNDED UP FURTHER.
   LPT's worst case is `4/3 - 1/(3m)` — 1.222 at three rows, 1.292 at the
   registry's eight — so a genuinely worst-case packing misses 1.125 and is
   refused.  `lpt_packing_gap.toml` pins that at 1.222.

   Achieved on the committed registry at the time this landed: 1.000 (pole
   482.2s = `diff_compiler_dict_semantics` alone, which is also the floor), so
   the full 12.5% is headroom and no re-ingest noise in that one gate can red
   it — under the retired metric the same gate's cost WAS the red. -}
balTargetMilli : Int
balTargetMilli = 1125

-- Hysteresis threshold, as a percentage of the pole. It no longer decides
-- WHETHER a gate moves (S-4, #2178, see `balBandNote` below) — the emitted
-- assignment is always the derived target. It survives only as the REPORT's
-- account of whether a move was worth its churn: a projected pole gain of
-- this percentage or less is annotated "not reached" rather than "TAKEN",
-- so a one-millisecond drift in one gate's median is visibly noise, not a
-- claimed improvement, even though the target still moves it.
balMarginPct : Int
balMarginPct = 5

{- | The incumbent row's slack, as a percentage of the LPT pick's current row
   load.  See `balPickStable` for the mechanism, `balStays` for why the
   comparison is made before the gate is added rather than after, and
   `balTarget` for why reading the incumbent at all is sound.

   NOT `balMarginPct`, DELIBERATELY, AND THE TWO MUST NOT BE MERGED.  They
   are numbers in different units answering different questions:

     * `balMarginPct` is 5% OF THE POLE, and it grades the WHOLE assignment
       after the fact — "was this rebalance worth its churn?" — for the report.
     * this is a percentage OF ONE ROW'S LOAD at ONE placement step, and it
       decides a single gate's row.

   Folding them into one constant would mean one edit silently retunes both a
   scheduling decision and a report's wording, and it would make the report's
   "a move needs a pole gain of more than 5%" line read as if it described the
   packer, which is exactly the confusion S-4 of #2178 removed.

   HELD AT 5 ON A MEASUREMENT, NOT A GUESS.  Measured against the committed
   202-gate registry under three independent ±2% perturbation shapes (index
   parity, its opposite, and a name-hashed sign), counting gates whose derived
   `shard` moved: 89 / 128 / 127 without the preference, 0 / 4 / 0 with it, at
   an achieved pole identical to three significant figures in all three (the
   printed factor moved by at most 0.005, measured as pole/median, the metric
   S-4 of #2216 retired).  Table and method:
   `docs/ops/GATE-REGISTRY-DESIGN.md` §12.

   The pole is not free in general: a slack of p% lets a placement land on a row
   up to p% heavier than the lightest legal one.  It is exactly free on an
   UNPERTURBED input — the committed assignment IS the packer's output, so every
   incumbent already equals the pick and the preference never fires — which is
   why the cost only ever shows up on a re-ingest, and why `balStabLine` states
   the realised figure on every run rather than leaving it to this comment. -}
balStabPct : Int
balStabPct = 5

-- ── Quantizing noisy costs — TRIED AND MEASURED AWAY (S-4, #2178/#2207) ─────
--
-- EVERY GATE IN THE COMMITTED BASELINE IS SCORED OFF AS FEW AS ONE OR TWO
-- SAMPLES.  `balSortCands`'s order and `balAdd`'s per-row makespan are both a
-- direct function of `Cand.cms`, so an ordinary re-ingest's measurement noise
-- (a slow runner, a GC pause, cache warmth) changes `cms` by a percent or
-- two and can flip which of two near-tied gates sorts first, or which row a
-- gate newly clears the least-loaded threshold for — moving the ASSIGNMENT
-- even though nothing about the SUITE changed. Measured on this baseline
-- perturbed by +/-2% per gate (alternating sign, deterministic — ordinary
-- jitter's rough magnitude): 113 of 202 gates' derived `shard` differed from
-- the unperturbed run.
--
-- The obvious fix is to quantize `medianMs` into a bucket before it becomes
-- `cms`, so two nearly-tied costs collapse to the same scheduling value.
-- THIS WAS TRIED, IN TWO SHAPES, AND MEASURED TO NOT WORK — recorded here so
-- the next reader does not re-attempt it blind:
--
--   (a) bucket width = a percentage of the value ITSELF (snap `ms` to the
--       nearest multiple of `5% of ms`). Measured WORSE than no bucketing:
--       188 of 202 bucketed values changed under the same perturbation,
--       because jittering `ms` also jitters the bucket width, so the grid
--       moves under the noise instead of absorbing it.
--
--   (b) a FIXED geometric grid (1ms, growing by a constant ratio) — immune
--       to (a)'s flaw, since the grid's boundaries do not depend on the
--       noisy reading. Swept the ratio at 3/5/8/10/15/20/30/50 percent
--       against the SAME 202-gate registry and TWO INDEPENDENT perturbation
--       seeds (opposite-parity sign assignment, plus a name-hashed wobble on
--       the second). Real shard-assignment churn (not bucketed-value churn)
--       was NON-MONOTONIC in the ratio and, at every ratio tried, was
--       sometimes BETTER and sometimes WORSE than doing nothing: seed 1 went
--       113 (unbucketed) -> {107, 89, 122, 117, 76, 74, 157, 151} across the
--       eight ratios; seed 2's own unbucketed number (71, different from
--       seed 1's because the two seeds are different perturbations) went to
--       78 at the ratio (20%) that looked best on seed 1. Two seeds, same
--       ratio, opposite direction of effect: a fix that helps or hurts
--       depending on which noise draw you happen to get is not damping
--       noise, it is fitting one.
--
-- The reason is structural, not a bad ratio choice: `balPick` places each
-- candidate on the row with STRICTLY the least CUMULATIVE load, across only
-- eight rows. Bucketing an individual gate's cost narrows that gate's OWN
-- tie window, but the quantity `balPick` actually compares — the running sum
-- of many gates' costs on each row — still drifts by the sum of many
-- individual snap-to-bucket roundings, and a handful of milliseconds is
-- routinely enough to flip which of eight rows is "least loaded" at a given
-- step. Once one placement flips, every later placement on that row's
-- history can cascade. Bucketing the INPUT does not control the quantity the
-- packer is actually sensitive to, so it cannot be the fix; a real
-- discussion of the LPT packer's sensitivity to cumulative-load ties is a
-- separate, larger question than this slice's cost-quantization mandate.
--
-- So the emitted assignment stays a pure function of the raw `medianMs` —
-- `cms` below is unchanged from before this note — and the honest response
-- to "ordinary noise moves gates" is Step 4's thin-evidence visibility
-- (`balThinLine`), not a damped score. The alternative (i) the contract also
-- named — widen the estimate for `samples < N` gates — was considered too,
-- and is moot the same way bucketing's target was: the committed baseline is
-- at a uniform sample count per gate right now (see `GateCost.samples`; as of
-- S-1-baseline-autoadvance that count is 3, capped at `maxSamples` = 9 as
-- fresh ingests land), so there is no under-sampled subset to widen.

-- A gate needs the Wasm arm when its toolchain names `wasm-tools` or a `node`
-- version.  Per the sprint contract §4.4, `sqlite3` and `valgrind` are
-- installed on EVERY row by ci.yml's "Setup medaka" step, so they constrain
-- nothing; `wasm-tools`/`node` is the only row-conditional toolchain, and
-- which rows offer it is read from `[[shard]]`'s `wasm_arm`, never assumed.
balNeedsWasm : List String -> Bool
balNeedsWasm [] = False
balNeedsWasm (t :: ts)
  | t == "wasm-tools" = True
  | startsWith "node" t = True
  | otherwise = balNeedsWasm ts

-- ── Building the candidate set ──────────────────────────────────────────────

-- Gates with no row for their `shard` value, as names.  A gate naming a row
-- that does not exist cannot be scheduled at all, and must not be silently
-- dropped from the packing (which would quietly REMOVE it from CI).
balUnknownRows : List Shard -> List Gate -> List String
balUnknownRows _ [] = []
balUnknownRows shs (g :: gs)
  | g.shard == balOtherJob = balUnknownRows shs gs
  | balHasRow g.shard shs = balUnknownRows shs gs
  | otherwise = g.name :: balUnknownRows shs gs

balHasRow : String -> List Shard -> Bool
balHasRow _ [] = False
balHasRow n (s :: ss)
  | s.name == n = True
  | otherwise = balHasRow n ss

-- Schedulable gates whose `run` script has no row in the cost baseline.
--
-- HARD ERROR, NEVER A ZERO.  A missing cost read as 0 does not make the
-- packing a little worse — it makes the gate free, so the packer piles it onto
-- whatever row is already lightest and the projection it prints is confidently
-- wrong.  `gate_cost.baselineKey` is the join key precisely because the
-- obvious join (on `name`) misses 53 of the 202 schedulable entries in
-- silence; this check is what makes any future drift in that key loud.
balUncosted : List GateCost -> List Gate -> List String
balUncosted _ [] = []
balUncosted base (g :: gs)
  | g.shard == balOtherJob = balUncosted base gs
  | otherwise = match costOf g.run base
    Some _ => balUncosted base gs
    None =>
      "\{g.name} (baseline key '\{baselineKey g.run}')" :: balUncosted base gs

balCands : List GateCost -> List Gate -> List Cand
balCands _ [] = []
balCands base (g :: gs)
  | g.shard == balOtherJob = balCands base gs
  | otherwise = match costOf g.run base
    None => balCands base gs
    Some ms =>
      Cand {
          cname = g.name,
          crun = g.run,
          curRow = g.shard,
          cms = ms,
          needsWasm = balNeedsWasm g.toolchain,
        }
        :: balCands base gs

-- A `full_cores` row is CLOSED, not merely preferred.
--
-- `engines` exists because `diff_compiler_engines` needs a whole runner to
-- itself; its row-mates are there because they share that need, and none of
-- that is a cost fact the packer can see.  So the packer neither moves a gate
-- OFF a full-cores row nor moves one ON — the row's membership is an input,
-- and the remaining rows are what it packs.
--
-- This is also what makes the target assignment a pure function of (registry
-- constraints, costs) and therefore a FIXED POINT: closing the row on the
-- `full_cores` flag rather than on "whatever is there now" means re-running
-- the balancer on its own output derives the same pin set, hence the same
-- target.  See `balTarget`.
balRows : List RunRecord -> List Shard -> List Row
balRows _ [] = []
balRows runs (s :: ss) =
  let j = balJobsFor s.name runs
  Row {
      rname = s.name,
      rwasm = s.wasmArm,
      rclosed = s.fullCores,
      rload = 0,
      rcount = 0,
      rjobs = j,
      rbuckets = balZeros j,
    }
    :: balRows runs ss

{- | The worker count to model this row's fan-out with: the `jobs` its own most
   recent recorded run actually used (S-1, #2208).

   NEVER A LITERAL, AND NEVER A GUESS DRESSED AS A MEASUREMENT.  `$JOBS` is
   `(NCPU*3+2)/5` on whatever runner CI gave the row, so it is a property of
   the run, not a constant this file may hold.

   Two fallbacks, in order, for a row the baseline has no `jobs` for:

     1. The most recent `jobs` recorded on ANY row.  Every row runs on the same
        `ubuntu-latest` runner class, so the worker count is a property of the
        runner and not of the row — borrowing a sibling's is a measurement, not
        an assumption, and it is what makes a NEWLY ADDED row modellable at all.

     2. Failing that (a baseline with no recorded `jobs` anywhere — every
        synthetic fixture, and any baseline ingested before S-1), 1: the row is
        modelled SERIALLY, which is exactly the sum this slice replaced.

   Fallback 2 is deliberately the conservative direction and not merely the
   convenient one.  Modelling a row with FEWER workers than it has OVER-states
   its makespan, so the packer moves work OFF it; over-stating `jobs` would
   under-state the makespan and pile work ON, which is the fail-open direction
   (`balUncosted`'s "a missing cost is not a cheap gate" argument, one axis
   over).  A fallback is still a fallback, so `balReport` names every row that
   used one rather than letting a serial row sit silently among honest ones.

   A hard refusal was considered and rejected: a brand-new `[[shard]]` row has
   no recorded run BY CONSTRUCTION, and refusing to balance until it has one
   would deadlock — its first run cannot happen until `ci.yml` schedules gates
   onto it, and nothing is scheduled onto it until the balancer runs.

   `parallel == Some False` OVERRIDES `jobs` entirely (F-2, #2178 review
   S3-3).  `run_gates.sh` hardcodes `parallel: true` today, so this is
   currently vacuous, but a future producer that ran a row's gates serially
   would have `jobs` describe a worker count the row never actually used —
   modelling it at that `jobs` would UNDER-state its makespan by roughly
   `jobs`×, the same fail-open direction fallback 2 above exists to avoid. A
   row recorded as non-parallel is modelled at 1 worker regardless of what
   `jobs` says. -}
balJobsFor : String -> List RunRecord -> Int
balJobsFor n runs = match latestRunForShard n runs
  Some r => match r.parallel
    Some False => 1
    _ => match r.jobs
      Some j if j >= 1 => j
      _ => balAnyJobs runs 1
  None => balAnyJobs runs 1

-- The latest `jobs` recorded on any row, in file order (the ingester appends,
-- so the last one wins), or the given default when no run records one.
balAnyJobs : List RunRecord -> Int -> Int
balAnyJobs [] acc = acc
balAnyJobs (r :: rs) acc = match r.jobs
  Some j if j >= 1 => balAnyJobs rs j
  _ => balAnyJobs rs acc

-- True when this row's worker count is borrowed or defaulted rather than its
-- own recorded measurement — what `balReport` annotates.
balJobsIsFallback : String -> List RunRecord -> Bool
balJobsIsFallback n runs = match latestRunForShard n runs
  Some r => match r.jobs
    Some j if j >= 1 => False
    _ => True
  None => True

balZeros : Int -> List Int
balZeros n
  | n <= 0 = []
  | otherwise = 0 :: balZeros (n - 1)

-- ── The packing ─────────────────────────────────────────────────────────────

-- Longest-processing-time first: the classic list-scheduling heuristic, and
-- the reason the pole lands on its floor here rather than merely near it —
-- the biggest gate is placed first, onto an empty row, so nothing can be
-- stacked on top of it afterwards except by a row that is still lighter.
--
-- Ties break on the gate NAME, so the output is a function of the inputs and
-- not of `gates.toml`'s line order.
candBefore : Cand -> Cand -> Bool
candBefore a b
  | a.cms /= b.cms = a.cms > b.cms
  | otherwise = a.cname < b.cname

balSortCands : List Cand -> List Cand
balSortCands [] = []
balSortCands (x :: []) = x :: []
balSortCands xs =
  let (l, r) = balHalve xs [] []
  balMergeCands (balSortCands l) (balSortCands r)

balHalve : List Cand -> List Cand -> List Cand -> (List Cand, List Cand)
balHalve [] a b = (a, b)
balHalve (x :: xs) a b = balHalve xs b (x :: a)

balMergeCands : List Cand -> List Cand -> List Cand
balMergeCands [] ys = ys
balMergeCands xs [] = xs
balMergeCands (x :: xs) (y :: ys)
  | candBefore x y = x :: balMergeCands xs (y :: ys)
  | otherwise = y :: balMergeCands (x :: xs) ys

-- The open row a gate should go on: the lightest row that can legally run it.
-- Scanning with a STRICT `<` keeps the first minimum, so an all-equal set of
-- rows resolves in `[[shard]]` order — deterministic, and stable as loads grow.
balPick : Cand -> List Row -> Option String
balPick c rs = balPickGo c rs None

balPickGo : Cand -> List Row -> Option Row -> Option String
balPickGo _ [] None = None
balPickGo _ [] (Some b) = Some b.rname
balPickGo c (r :: rs) best
  | r.rclosed = balPickGo c rs best
  | c.needsWasm && not r.rwasm = balPickGo c rs best
  | otherwise = match best
    None => balPickGo c rs (Some r)
    Some b =>
      if r.rload < b.rload then balPickGo c rs (Some r) else balPickGo c rs best

{- | The row a gate should go on, with the INCUMBENT row given a bounded
   preference over the LPT pick (S-3, #2218).

   READ `balBandNote` FIRST.  A near-identical-LOOKING mechanism shipped in
   #2178 and was REVERTED, and the difference between that one and this one is
   the whole reason this one is allowed to exist.  The reverted mechanism let
   the COMMITTED ASSIGNMENT stand whenever it was within `balMarginPct` of the
   target's pole.  That made "the derived assignment" a SET rather than a
   value, so `--check` could not tell a hysteresis-preserved incumbent from a
   stale hand edit: moving `diff_compiler_source_bytes` from `tools` to `types`
   by hand shifted the pole by 0s, and `--check` reported "already balanced".

   This is not that.  The incumbent is an EXPLICIT INPUT to a placement
   decision, consulted at a defined point in a defined order, and the result is
   still a single value that `--check` re-derives from committed data alone.
   `balTarget` is a pure function of a WIDER argument list — (rows, costs,
   toolchains, incumbent shards) — not a function with an escape hatch.  The
   discriminator is mechanical: under the reverted mechanism a hand edit was
   ACCEPTED because it was never re-derived; here a hand edit is re-derived like
   everything else, and survives only if the derivation independently produces
   it, which is what "derived" means.

   The rule.  Take the LPT pick (`balPick`) as the baseline, then keep the
   incumbent instead when all three hold:

     1. the incumbent row is OPEN (a closed row's members never reach here —
        `balOpenCands` filtered them — but the predicate is total anyway), and
     2. the incumbent row is LEGAL for this gate (`wasm_arm`), and
     3. the incumbent row is currently no more than `balStabPct` percent
        heavier than the LPT pick (`balStays`, which argues for BEFORE-adding
        rather than after).

   (2) is `balCurrentLegal`'s argument one layer down and is NOT negotiable:
   cost is what a preference may weigh, and legality is not a cost.  An illegal
   incumbent fails the predicate and is moved, which is what keeps the
   `wasm_only_row` fixture red-on-regression.

   WHY THIS IS STILL A FIXED POINT, which is the property #2178 paid for.
   Run the balancer on its own output and every candidate's incumbent IS the row
   the previous run placed it on.  By induction over the (identical) candidate
   order: if the previous run took the LPT pick, the incumbent equals the pick
   and clause (3) holds trivially with slack 0, so the pick is taken again; if
   the previous run kept the incumbent, the row states at that step are
   identical and the same three clauses hold, so it is kept again.  Either way
   the second run emits the first run's assignment, byte for byte —
   `diff_compiler_gate_balance.sh`'s `_bal_real`-twice assertion. -}
balPickStable : Cand -> List Row -> Option String
balPickStable c rs = match balPick c rs
  None => None
  Some best => if balStays c best rs then Some c.curRow else Some best

{- | Clause (1)+(2)+(3) of `balPickStable`, in that order.  Kept separate so the
   legality clause is a readable line rather than a term inside an arithmetic
   comparison.

   CLAUSE (3) COMPARES THE ROWS' LOADS BEFORE THIS GATE IS ADDED, NOT AFTER,
   AND THE TWO ARE NOT THE SAME RULE.  Both were implemented and measured; the
   before-form is kept, on both counts:

     * The bound it gives is the one worth having.  A hold puts this gate on a
       row already carrying `Lcur` instead of the lightest legal `Lbest`, and
       the excess it can add to the pole is exactly `Lcur - Lbest`, which this
       form caps at `balStabPct`% of `Lbest`.  The after-form caps the same
       excess at `balStabPct`% of `Lbest + cms`, so the slack GROWS with the
       gate's own cost — an expensive gate would earn more licence to sit on a
       heavy row, which is backwards for an objective that is the pole.
     * It measured no worse.  Same three ±2% perturbation shapes, churn out of
       202 gates: before-form 0 / 4 / 0, after-form 0 / 7 / 5.

   A consequence worth naming rather than discovering: early in the pack every
   row is near-empty, so `Lbest` is near 0 and the ABSOLUTE slack the
   preference tolerates is near 0 too — but the comparison is `Lcur * 100 <=
   Lbest * (100 + balStabPct)`, and when BOTH sides are exactly 0 (curRow and
   best both still-empty rows) that reduces to `0 <= 0`, which holds
   UNCONDITIONALLY regardless of `balStabPct`.  So the preference does not
   sit out the empty-row region — a gate committed to a still-empty row that
   is not bare LPT's pick is HELD there too, at zero cost either way (a
   fixed point, since every empty legal row is equally good).  What the
   biggest gates actually get placed by bare LPT with no preference in
   practice is the case where `curRow == best` already (ties broken in
   `[[shard]]` order tend to agree with the incumbent early on), not a
   genuine "preference disabled below some load" rule. -}
balStays : Cand -> String -> List Row -> Bool
balStays c best rs
  | c.curRow == best = True
  | not (balRowTakes c rs) = False
  | otherwise =
    balRowLoad c.curRow rs * 100 <= balRowLoad best rs * (100 + balStabPct)

-- Whether this gate's incumbent row exists, is open, and can run it.  An
-- unknown row name answers False — `balUnknownRows` has already refused that
-- registry, but a placement rule that read a missing row as "fine" would be one
-- refusal away from silently pinning a gate to nothing.
balRowTakes : Cand -> List Row -> Bool
balRowTakes _ [] = False
balRowTakes c (r :: rs)
  | r.rname == c.curRow = not r.rclosed && (not c.needsWasm || r.rwasm)
  | otherwise = balRowTakes c rs

-- One row's accumulated makespan, by name.  A row that does not exist reads as
-- 0, which `balStays` only ever reaches through `balRowTakes` having already
-- answered False for the same name.
balRowLoad : String -> List Row -> Int
balRowLoad _ [] = 0
balRowLoad n (r :: rs)
  | r.rname == n = r.rload
  | otherwise = balRowLoad n rs

-- Put one gate on a row, and re-derive that row's makespan.
--
-- THE CALLER OWES THIS FUNCTION COST-DESCENDING ORDER.  The within-row
-- schedule is LPT like the across-row one, and LPT's guarantee is a property of
-- the ORDER, not of the placement rule: fed a row's gates smallest-first, the
-- same buckets can end up markedly less even.  Every caller therefore feeds
-- `balSortCands` output — `balPlace`, `balSeedClosed` and `balCurrent` alike —
-- so the committed assignment and the derived one are scored by the same
-- model rather than by two schedules that happen to share a function.
balAdd : String -> Int -> List Row -> List Row
balAdd _ _ [] = []
balAdd n ms (r :: rs)
  | r.rname == n =
    let bs = balBucketAdd ms r.rbuckets
    Row { r | rbuckets = bs, rload = balMaxL bs, rcount = r.rcount + 1 } :: rs
  | otherwise = r :: balAdd n ms rs

-- One worker bucket takes the gate: the least-loaded one, first minimum kept,
-- which is what `xargs -P` does when a worker frees up.  An empty bucket list
-- cannot arise (`balJobsFor` floors at 1), but if it ever did, growing a bucket
-- is the one response that does not silently LOSE the gate's cost.
balBucketAdd : Int -> List Int -> List Int
balBucketAdd ms [] = ms :: []
balBucketAdd ms bs = balBucketPut ms (balMinL bs) bs

balBucketPut : Int -> Int -> List Int -> List Int
balBucketPut _ _ [] = []
balBucketPut ms m (b :: bs)
  | b == m = b + ms :: bs
  | otherwise = b :: balBucketPut ms m bs

balMinL : List Int -> Int
balMinL [] = 0
balMinL (x :: []) = x
balMinL (x :: xs) = minI x (balMinL xs)

balMaxL : List Int -> Int
balMaxL [] = 0
balMaxL (x :: xs) = maxI x (balMaxL xs)

-- Place the sorted candidates one at a time.  A gate with no legal row is the
-- constraint refusal: it names the gate, what it needs, and which rows offer
-- it, rather than quietly landing somewhere the toolchain is absent (where it
-- would fail in CI as a mysterious missing-binary error, on a row whose
-- coverage check reports the gate as scheduled).
--
-- `stab` selects the placement rule: `balPickStable` (the shipped one) or the
-- bare LPT `balPick`.  Both are needed on every run, because the report states
-- what the stability preference COSTS by packing the same candidates twice and
-- comparing the two poles (`balCompute`) — a claim about a trade-off that
-- printed only one side of it would be unfalsifiable by a reader.
balPlace : Bool ->
  List Cand ->
  List Row ->
  List Place ->
  Result String (List Place, List Row)
balPlace _ [] rs acc = Ok (reverseL acc, rs)
balPlace stab (c :: cs) rs acc =
  match if stab then balPickStable c rs else balPick c rs
    None =>
      Err
        (stringConcat [
          "medaka gate balance: no row can run '\{c.cname}'.\n",
          "  It needs the Wasm toolchain (wasm-tools / node), and every row with\n",
          "  wasm_arm = true is closed to the packer (full_cores).  Wasm rows: ",
          joinSpace (balWasmRowNames rs),
          "\n",
        ])
    Some rn =>
      balPlace
        stab
        cs
        (balAdd rn c.cms rs)
        (Place {
            pname = c.cname,
            pfrom = c.curRow,
            pto = rn,
          }
          :: acc)

balWasmRowNames : List Row -> List String
balWasmRowNames [] = []
balWasmRowNames (r :: rs)
  | r.rwasm = r.rname :: balWasmRowNames rs
  | otherwise = balWasmRowNames rs

-- The closed rows keep exactly the gates that already name them.  A pinned
-- gate whose row cannot run it is a registry defect, not something to repack
-- around: the row is closed, so there is nowhere for it to go.
--
-- Reading `c.curRow` here is only sound because `balPinErrors` has already
-- refused any registry whose closed rows do not match their declared
-- `pinned_gates`.  Without that check this seed is the one place a `shard`
-- value is still hand-assignable, and the hand edit is adopted as the new pin.
balSeedClosed : List Cand ->
  List Row ->
  List Place ->
  Result String (List Place, List Row)
balSeedClosed [] rs acc = Ok (reverseL acc, rs)
balSeedClosed (c :: cs) rs acc
  | not (balIsClosed c.curRow rs) = balSeedClosed cs rs acc
  | c.needsWasm && not (balRowIsWasm c.curRow rs) =
    Err
      "medaka gate balance: '\{c.cname}' needs the Wasm toolchain but is pinned to row '\{c.curRow}', which has wasm_arm = false"
  | otherwise =
    balSeedClosed
      cs
      (balAdd c.curRow c.cms rs)
      (Place {
          pname = c.cname,
          pfrom = c.curRow,
          pto = c.curRow,
        }
        :: acc)

balIsClosed : String -> List Row -> Bool
balIsClosed _ [] = False
balIsClosed n (r :: rs)
  | r.rname == n = r.rclosed
  | otherwise = balIsClosed n rs

balRowIsWasm : String -> List Row -> Bool
balRowIsWasm _ [] = False
balRowIsWasm n (r :: rs)
  | r.rname == n = r.rwasm
  | otherwise = balRowIsWasm n rs

-- ── The closed rows' declared membership ────────────────────────

{- | A CLOSED ROW'S MEMBERSHIP IS A DECLARED INVARIANT, NOT AN OBSERVATION.

   `balSeedClosed` seeds a `full_cores` row from whatever gates CURRENTLY name
   it.  As a packing rule that is right — the packer must move nothing onto a
   whole-runner row and nothing off it.  On its own, though, it leaves that row
   as the one place a `shard` value is still hand-assignable, which is exactly
   what #2178 exists to remove.  Two hand edits were accepted in review (F3),
   both adopted permanently by one `medaka gate balance` run, after which
   `--check` reported "already balanced":

     (a) move an unrelated gate ONTO `engines`.  The seed takes it, the packer
         repacks the other seven rows around the extra load, and the result is
         a fixed point of itself.
     (b) move `diff_compiler_engines` OFF `engines`.  Same adoption — and the
         projection printed is BETTER (pole/median 1.005 against 1.073, under
         the metric #2216 retired),
         because idling a whole runner and stacking the suite's heaviest gate
         onto a shared one is what a cost objective blind to the pin prefers.

   Neither is a cost fact, so neither can be derived.  It is DECLARED per row,
   in `[[shard]]`'s `pinned_gates`, and checked here against what the registry
   actually says — in BOTH directions.  Checking both is what makes this an
   invariant a wrong committed state can FAIL, rather than a fiat under which
   whatever is committed defines itself as correct.

   An OPEN row must declare `pinned_gates = []`: its membership IS the packer's
   output, and a non-empty list there would be prose the tool silently ignores.
   Every violation is reported, not just the first — a membership repair is one
   edit, and finding out about the second half of it on the next run is not. -}
balPinErrors : List Gate -> List Shard -> List String
balPinErrors _ [] = []
balPinErrors gs (s :: ss)
  | not s.fullCores && isNonEmptyL s.pinned =
    "row '\{s.name}': pinned_gates is non-empty (\{joinSpace s.pinned}) on an OPEN row (full_cores = false); only a closed row's membership is declared, an open row's is the packer's output"
      :: balPinErrors gs ss
  | not s.fullCores = balPinErrors gs ss
  | otherwise =
    let members = balRowMembers s.name gs
    balPinMissing s.name gs s.pinned members
      ++ balPinExtra s.name s.pinned members
      ++ balPinErrors gs ss

-- The gates whose committed `shard` names this row, in registry order.
balRowMembers : String -> List Gate -> List String
balRowMembers _ [] = []
balRowMembers n (g :: gs)
  | g.shard == n = g.name :: balRowMembers n gs
  | otherwise = balRowMembers n gs

-- Declared, but not there: the pinned gate has been moved off the closed row
-- (F3(b)).  Naming where it went instead is the whole diagnosis.
balPinMissing : String -> List Gate -> List String -> List String -> List String
balPinMissing _ _ [] _ = []
balPinMissing n gs (p :: ps) members
  | balElemStr p members = balPinMissing n gs ps members
  | otherwise = balPinPlace n gs p :: balPinMissing n gs ps members

balPinPlace : String -> List Gate -> String -> String
balPinPlace n gs p = match balShardOfGate p gs
  None => "row '\{n}': pinned gate '\{p}' is not in the registry at all"
  Some other =>
    "row '\{n}': pinned gate '\{p}' is committed on row '\{other}' instead"

balShardOfGate : String -> List Gate -> Option String
balShardOfGate _ [] = None
balShardOfGate n (g :: gs)
  | g.name == n = Some g.shard
  | otherwise = balShardOfGate n gs

-- There, but not declared: a gate has been moved onto the closed row (F3(a)).
balPinExtra : String -> List String -> List String -> List String
balPinExtra _ _ [] = []
balPinExtra n pinned (m :: ms)
  | balElemStr m pinned = balPinExtra n pinned ms
  | otherwise =
    "row '\{n}': '\{m}' is committed on this closed row but is not in its pinned_gates"
      :: balPinExtra n pinned ms

balElemStr : String -> List String -> Bool
balElemStr _ [] = False
balElemStr x (y :: ys)
  | x == y = True
  | otherwise = balElemStr x ys

balOpenCands : List Cand -> List Row -> List Cand
balOpenCands [] _ = []
balOpenCands (c :: cs) rs
  | balIsClosed c.curRow rs = balOpenCands cs rs
  | otherwise = c :: balOpenCands cs rs

{- | The target assignment: seed the closed rows from their current members,
   then pack the rest onto the open rows.

   A PURE FUNCTION OF (rows, costs, toolchains, INCUMBENT SHARDS).  That
   fourth input arrived with S-3/#2218's stability preference, and the wording
   of this paragraph used to be its own load-bearing claim, so read the change
   carefully rather than as a widening of scope:

   IT USED TO SAY "it does not read the `shard` of any gate on an OPEN row",
   and that was the right rule for the mechanism it described.  #2178's reverted
   hysteresis band did not take the incumbent as an argument — it took the
   derived target and then DECLINED TO EMIT IT if what happened to be committed
   scored close enough.  A function that can decline to emit its own output has
   no single value for `--check` to police, and a hand edit inside the band
   passed as "already balanced" (`balBandNote`).

   Reading `Cand.curRow` here is the opposite move, not a softening of it.
   `curRow` is populated from the COMMITTED registry (`balCands`), so it is
   ordinary committed input, exactly like `cms` and `needsWasm`; the function
   consumes it and returns ONE assignment, which `--check` re-derives from the
   same committed bytes and compares. Purity is a property of the argument
   list, not a property of arguments being few.

   Idempotence — the reason any of this care is spent — is unchanged and argued
   in `balPickStable`: on the balancer's own output every incumbent is the row
   the previous run chose, so every placement repeats and the second run is
   byte-identical.

   `stab` is False for the pure-LPT comparison run that `balCompute` scores the
   preference's pole cost against; the emitted assignment is always the True
   one. -}
balTarget : Bool ->
  List Cand ->
  List Row ->
  Result String (List Place, List Row)
balTarget stab cs rows0 =
  -- Cost-descending for BOTH halves, not just the packed one: `balAdd` now runs
  -- an LPT schedule inside each row, and a closed row seeded in registry order
  -- would be scored under a schedule CI never runs (`balAdd`'s note).  The
  -- pinned `Place`s are looked up by name downstream (`balPlaceOf`), so their
  -- order carries no meaning of its own.
  let sorted = balSortCands cs
  match balSeedClosed sorted rows0 []
    Err m => Err m
    Ok (pinned, rows1) =>
      map
        ((placed, rows2) => (pinned ++ placed, rows2))
        (balPlace stab (balSortCands (balOpenCands sorted rows0)) rows1 [])

-- The assignment already on disk, as the same shape, so the two can be scored
-- by identical code rather than by two functions that could drift apart.
--
-- Its caller passes `balSortCands` output, for `balAdd`'s reason: scoring the
-- committed assignment under registry order and the derived one under
-- cost-descending order would compare two DIFFERENT models and call the
-- difference a packing gain.
balCurrent : List Cand -> List Row -> (List Place, List Row)
balCurrent [] rs = ([], rs)
balCurrent (c :: cs) rs =
  let (ps, rs2) = balCurrent cs (balAdd c.curRow c.cms rs)
  (Place { pname = c.cname, pfrom = c.curRow, pto = c.curRow } :: ps, rs2)

-- ── Scoring ─────────────────────────────────────────────────────────────────

balPole : List Row -> Int
balPole [] = 0
balPole (r :: rs) = maxI r.rload (balPole rs)

balPoleRow : List Row -> String
balPoleRow rs = balPoleRowGo rs "" (-1)

balPoleRowGo : List Row -> String -> Int -> String
balPoleRowGo [] n _ = n
balPoleRowGo (r :: rs) n best
  | r.rload > best = balPoleRowGo rs r.rname r.rload
  | otherwise = balPoleRowGo rs n best

balLoads : List Row -> List Int
balLoads [] = []
balLoads (r :: rs) = r.rload :: balLoads rs

balSortInts : List Int -> List Int
balSortInts [] = []
balSortInts (x :: []) = x :: []
balSortInts xs =
  let (l, r) = balHalveI xs [] []
  balMergeInts (balSortInts l) (balSortInts r)

balHalveI : List Int -> List Int -> List Int -> (List Int, List Int)
balHalveI [] a b = (a, b)
balHalveI (x :: xs) a b = balHalveI xs b (x :: a)

balMergeInts : List Int -> List Int -> List Int
balMergeInts [] ys = ys
balMergeInts xs [] = xs
balMergeInts (x :: xs) (y :: ys)
  | x <= y = x :: balMergeInts xs (y :: ys)
  | otherwise = y :: balMergeInts (x :: xs) ys

-- The median row load: the mean of the two middle values for an even row
-- count, the middle value for an odd one.
--
-- DESCRIPTIVE ONLY SINCE S-4 (#2216) — it enforces nothing.  It was the
-- denominator of the old `pole / median` target and is kept because it is the
-- one number that tells a reader at a glance how far the typical row sits from
-- the pole, which the per-row table shows but does not summarise.  It is NOT a
-- component of `balFloor`: a median is a property of the suite, and mixing one
-- into the floor would put the perversity this slice removed straight back.
balMedian : List Row -> Int
balMedian rs =
  let v = balSortInts (balLoads rs)
  let n = listLen v
  if n == 0 then
    0
  else if n % 2 == 1 then
    balNth (n / 2) v
  else
    (balNth (n / 2 - 1) v + balNth (n / 2) v) / 2

balNth : Int -> List Int -> Int
balNth _ [] = 0
balNth i (x :: xs)
  | i <= 0 = x
  | otherwise = balNth (i - 1) xs

-- ── The floor: the achievable pole ──────────────────────────────────────────
--
-- The largest of three lower bounds on the pole, each proved in "The
-- objective" above.  A floor of 0 (no rows, no gates) is reported as a factor
-- of 0 by `balFactorMilli`, matching what the old ratio did with a zero
-- median: there is nothing to grade, and `balEnforce` must not divide by it.

-- Term 1: the most expensive single gate.  Over ALL gates, closed-row members
-- included — whichever row holds it, that row's makespan is at least its cost.
balFloorGateMs : List Cand -> Int
balFloorGateMs cs = (balMaxCand cs).cms

-- Term 2: the heaviest closed row's makespan.  A `full_cores` row's membership
-- is declared, not packed (`balSeedClosed`), so its load is fixed input and the
-- pole is at least that.  Blaming the packer for it would be the same category
-- error as blaming it for one indivisible gate.
balFloorClosedMs : List Row -> Int
balFloorClosedMs [] = 0
balFloorClosedMs (r :: rs)
  | r.rclosed = maxI r.rload (balFloorClosedMs rs)
  | otherwise = balFloorClosedMs rs

balFloorClosedRow : List Row -> String
balFloorClosedRow rs = balFloorClosedRowGo rs "" (-1)

balFloorClosedRowGo : List Row -> String -> Int -> String
balFloorClosedRowGo [] n _ = n
balFloorClosedRowGo (r :: rs) n best
  | r.rclosed && r.rload > best = balFloorClosedRowGo rs r.rname r.rload
  | otherwise = balFloorClosedRowGo rs n best

-- The open gates' total work.  Closed-row members are excluded on BOTH sides of
-- the capacity term (here and in `balOpenSlots`): they cannot move, so they are
-- neither work the packer has to place nor capacity it has to place it on.
balOpenWork : List Cand -> List Row -> Int
balOpenWork [] _ = 0
balOpenWork (c :: cs) rs
  | balIsClosed c.curRow rs = balOpenWork cs rs
  | otherwise = c.cms + balOpenWork cs rs

-- The open rows' worker slots.  `rjobs`, not 1: a row runs its gates through
-- `run_gates.sh`'s pool, so its capacity per unit of wall clock is its recorded
-- worker count (`balJobsFor`), and counting rows instead of slots would inflate
-- this term by roughly `jobs`×.
balOpenSlots : List Row -> Int
balOpenSlots [] = 0
balOpenSlots (r :: rs)
  | r.rclosed = balOpenSlots rs
  | otherwise = r.rjobs + balOpenSlots rs

-- Term 3: total open work spread perfectly over every open worker slot.
balFloorCapMs : List Cand -> List Row -> Int
balFloorCapMs cs rs =
  let s = balOpenSlots rs
  if s <= 0 then 0 else balOpenWork cs rs / s

balFloor : List Cand -> List Row -> Int
balFloor cs rs =
  maxI (balFloorGateMs cs) (maxI (balFloorClosedMs rs) (balFloorCapMs cs rs))

-- True when the floor is set by one indivisible gate rather than by capacity or
-- by a closed row — the discriminator `balEnforce` needs to choose between "this
-- is the packing" and "this gate has to get FASTER".  Ties go to the gate: when
-- the terms are equal, the gate is the one a reader can act on.
balFloorIsGate : List Cand -> List Row -> Bool
balFloorIsGate cs rs = balFloorGateMs cs >= balFloor cs rs

-- Where the floor comes from, in one line, on every run.  A bound with no
-- stated provenance is a number a reader has to reverse-engineer before they
-- can act on the ratio built from it.
balFloorLine : List Cand -> List Row -> String
balFloorLine cs rs
  | balFloor cs rs <= 0 = ""
  | balFloorIsGate cs rs = stringConcat [
    "  floor: the achievable pole — set by '\{(balMaxCand cs).cname}' alone (\{balSecs (balFloorGateMs cs)}), which is indivisible.\n",
    "         Moving the FLOOR means that gate has to get FASTER (or be split).\n",
  ]
  | balFloorClosedMs rs >= balFloor cs rs =
    "  floor: the achievable pole — set by the closed row '\{balFloorClosedRow rs}' (\{balSecs (balFloorClosedMs rs)}), whose membership the packer cannot change.\n"
  | otherwise =
    "  floor: the achievable pole — set by \{balSecs (balOpenWork cs rs)} of open work over \{intToString (balOpenSlots rs)} open worker slots.\n"

-- `pole / floor` in thousandths.  Integer arithmetic throughout: the factor
-- is compared against a threshold and printed, and a float would make both
-- the comparison and the printed digits platform-sensitive for no gain.
balFactorMilli : List Cand -> List Row -> Int
balFactorMilli cs rs =
  let f = balFloor cs rs
  if f <= 0 then 0 else balPole rs * 1000 / f

balMaxCand : List Cand -> Cand
balMaxCand [] =
  Cand { cname = "(none)", crun = "", curRow = "", cms = 0, needsWasm = False }
balMaxCand (c :: []) = c
balMaxCand (c :: cs) =
  let r = balMaxCand cs
  if c.cms >= r.cms then c else r

-- ── Rendering ───────────────────────────────────────────────────────────────

-- Milliseconds as `948.9s` — one decimal, which is all the precision a median
-- of nine noisy CI samples supports.
balSecs : Int -> String
balSecs ms = "\{intToString (ms / 1000)}.\{intToString (ms % 1000 / 100)}s"

-- Per-mille as a one-decimal percentage magnitude, `126` -> `12.6%`.
balTenth : Int -> String
balTenth pm = "\{intToString (pm / 10)}.\{intToString (pm % 10)}%"

-- A signed one-decimal percentage of `base`, as `-12.6%`.  Integer
-- arithmetic, for `balFactorMilli`'s reason, and the sign is applied to the
-- MAGNITUDE rather than carried through the division — `balDelta`'s trap,
-- where both halves of an integer split carry the sign and a negative renders
-- as `-1.-4`.
balPct1 : Int -> Int -> String
balPct1 d base
  | base <= 0 = "n/a"
  | d < 0 = "-\{balTenth ((0 - d) * 1000 / base)}"
  | otherwise = "+\{balTenth (d * 1000 / base)}"

-- Thousandths as `1.074`.
balMilli : Int -> String
balMilli m = "\{intToString (m / 1000)}.\{balPad3 (m % 1000)}"

balPad3 : Int -> String
balPad3 n
  | n < 10 = "00\{intToString n}"
  | n < 100 = "0\{intToString n}"
  | otherwise = intToString n

balPadR : Int -> String -> String
balPadR w s
  | stringLength s >= w = s
  | otherwise = balPadR w (s ++ " ")

balPadL : Int -> String -> String
balPadL w s
  | stringLength s >= w = s
  | otherwise = balPadL w (" " ++ s)

-- A signed millisecond delta as `+14.3s` / `-2.0s`.  `balSecs` alone renders a
-- negative as `-1.-4s`, because both halves of its integer split carry the
-- sign; the residual column is the first place negatives occur.
balDelta : Int -> String
balDelta d
  | d < 0 = "-\{balSecs (0 - d)}"
  | otherwise = "+\{balSecs d}"

-- Every row's per-gate load is its makespan; the worker count it was modelled
-- with is printed beside it, and a borrowed or defaulted one says so — a row
-- silently modelled serially among 2-worker siblings would misprice by 2× with
-- nothing in the output to show for it (`balJobsFor`).
balRowLines : List Row -> List RunRecord -> List String
balRowLines [] _ = []
balRowLines (r :: rs) runs =
  let tag = if r.rclosed then "  [closed: full_cores]" else ""
  let jt = if balJobsIsFallback r.rname runs then " jobs*" else " jobs "
  "    \{balPadR 10 r.rname} \{balPadL 4 (intToString r.rcount)} gates \{balPadL 9 (balSecs r.rload)}  \{jt}\{intToString r.rjobs}\{tag}"
    :: balRowLines rs runs

{- | The model against something that is not the model: each row's recorded CI
   wall clock (`rowElapsedMs`, S-1/#2208) beside this model's makespan for the
   COMMITTED assignment, and the residual between them.

   READ THE CAVEAT BEFORE READING THE NUMBERS.  A residual is only meaningful
   while the recorded run and the committed assignment describe the SAME gate
   set — that is true right after an ingest and false the moment a rebalance
   lands, because the next run has not happened yet.  So this block is
   calibration evidence at ingest time, not a live invariant, and it is
   reported rather than enforced for exactly that reason.  The line CANNOT
   detect that on its own — a residual reads identically whether the gate set
   moved or not — so `balCalibStaleness` annotates the line when the recorded
   run and the committed row have drifted apart, comparing the recorded
   `gates` COUNT (F-2, #2178 review S2-1) and, when the run recorded one, the
   recorded gate-SET digest (S-2, #2223) — because a rebalance that swaps one
   gate for another leaves the count alone and would otherwise report clean.

   The residual is expected to be POSITIVE and not zero.  A row's recorded
   elapsed spans things no per-gate median contains:

     * the pool's own spawn overhead (still real);
     * the packing statistic is the LOWER MEDIAN of a gate's retained raw
       samples, which is systematically LOW — and, since S-2 (#2222), by a
       MEASURED amount rather than an asserted one: leave-one-run-out over
       the runs recorded in `runs[]` puts the bias at -12.6% of a row's
       predicted total.  That is the deliberate price of a statistic one wild
       sample cannot move (`gate_cost.packStat`'s doc-comment carries the
       comparison that settled it), and `balOosLines` prints the current
       figure on every run rather than leaving this prose to rot; and
     * gates that FAILED, which contribute wall clock to the row but, by the
       ingester's rule, no sample to the baseline.  Whether this is currently
       vacuous is DERIVED, not asserted here: `balOosBlock` reports how many
       schedulable gates carry a run-attributed sample from EVERY recorded
       run, and it is vacuous exactly when that count is all of them, since a
       gate that failed a run is a gate short that run's sample.  On a
       baseline predating `sampleRuns` that count is 0 for want of
       attribution, not for want of samples, and `balOosBlock` says which —
       do not read its "not derivable" line as evidence that gates failed.
       (An earlier version of this comment pinned the state as a fact —
       "every gate ... at `samples: 2` across both ingested runIds" — and it
       was stale within two ingests.  Hence the derivation.)

   The gate's own shebang syntax pre-check is NOT a cause: `test/run_gates.sh`
   starts the clock BEFORE that check runs (search "clock starts BEFORE the
   syntax pre-check"), so its cost is already inside each gate's own `ms` and
   cannot also be part of the residual.

   A residual near zero or negative is the surprising one. -}
balCalibLines : List Cand -> List Row -> List RunRecord -> List String
balCalibLines _ [] _ = []
balCalibLines cs (r :: rs) runs =
  balCalibLine cs r runs :: balCalibLines cs rs runs

{- | The recorded run and the committed assignment describe the same gate set
   only as long as the row has not been rebalanced since that run.  Two
   independent comparisons answer that, and BOTH are needed:

     1. `rcount` (now) against the run's own recorded `gates` (at ingest).
     2. The row's current gate-SET digest against the run's recorded
        `gatesDigest`.

   (1) ALONE IS A COUNT, AND A COUNT IS NOT A SET (#2223).  The commonest
   rebalance is a SWAP — one gate leaves the row, another arrives — and a swap
   is invisible to (1) by construction.  The observed instance was a -96%
   residual printing entirely clean, which reads as "the model is calibrated"
   when it means "the model is being graded against a gate set that has not
   existed since the rebalance". (2) is what closes it.

   `None` on either side (a run ingested before that field existed) is
   silently unannotated — "unknown" is not "stale" — so a baseline predating
   `gatesDigest` keeps exactly the count-only behaviour it had, and gains the
   set check at its next ingest. -}
balCalibStaleness : Int -> Option Int -> Int -> Option Int -> String
balCalibStaleness _ None _ _ = ""
balCalibStaleness cur (Some recorded) curDig recDig
  | cur /= recorded =
    " [STALE: \{intToString cur} gates now, \{intToString recorded} when recorded]"
  | otherwise = balCalibSetStaleness cur curDig recDig

balCalibSetStaleness : Int -> Int -> Option Int -> String
balCalibSetStaleness _ _ None = ""
balCalibSetStaleness n cur (Some recorded)
  | cur == recorded = ""
  | otherwise =
    " [STALE: the same \{intToString n} gates by COUNT but a DIFFERENT SET (set digest \{intToString cur} now, \{intToString recorded} when recorded)]"

-- The digest of what is committed to this row NOW, over the same population
-- `rcount` counts: the candidates whose COMMITTED shard is this row.  Keyed
-- by `baselineKey c.crun`, never by `c.cname` — the ingester digests
-- `run_gates.sh`'s labels, and those are the flattened script paths, not the
-- registry names (`gate_cost`'s module header carries why that distinction
-- silently bites 53 of the 202 entries).
balRowDigest : String -> List Cand -> Int
balRowDigest rn cs = gateSetDigest (balRowKeys rn cs)

balRowKeys : String -> List Cand -> List String
balRowKeys _ [] = []
balRowKeys rn (c :: cs)
  | c.curRow == rn = baselineKey c.crun :: balRowKeys rn cs
  | otherwise = balRowKeys rn cs

balCalibLine : List Cand -> Row -> List RunRecord -> String
balCalibLine cands r runs = match latestRunForShard r.rname runs
  None => "    \{balPadR 10 r.rname} (no recorded run)"
  Some rr => match rr.rowElapsedMs
    None =>
      "    \{balPadR 10 r.rname} (run \{rr.runId} recorded no rowElapsedMs)"
    Some e =>
      let d = e - r.rload
      let pct =
        if r.rload > 0 then " (\{intToString (d * 100 / r.rload)}%)" else ""
      let stale =
        balCalibStaleness
          r.rcount
          rr.gates
          (balRowDigest r.rname cands)
          rr.gatesDigest
      "    \{balPadR 10 r.rname} recorded \{balPadL 9 (balSecs e)}   predicted \{balPadL 9 (balSecs r.rload)}   residual \{balPadL 9 (balDelta d)}\{pct}\{stale}"

{- | What the incumbent preference bought, and what it cost — on EVERY run, in
   ordinary output, derived rather than asserted.

   The trade `balStabPct` makes is churn against pole, and a tool that made it
   silently would be asking a reader to take both halves on faith.  So the same
   candidates are packed a SECOND time with the preference off (`balTarget
   False`) and the two results are compared directly: how many gates the
   preference held where bare LPT would have moved them, and what the achieved
   pole is under each.

   ON AN UNPERTURBED, ALREADY-BALANCED REGISTRY BOTH NUMBERS ARE ZERO, AND
   THAT IS THE HEALTHY READING, NOT A BROKEN COMPARISON.  The committed
   assignment IS the LPT output, so every incumbent already equals the LPT pick
   and the preference never fires.  It fires when the baseline moves under it —
   which is the only situation it exists for.  A reader seeing "0 held, +0.0s"
   after a re-ingest that moved nothing is being told the truth.

   The comparison arm cannot fail where the emitted arm succeeded
   (`balPickStable` returns `None` exactly when `balPick` does, and the closed-row
   seed is identical), but a `Result` is still a `Result`: rather than paper over
   an impossible case with a zero, say the comparison is unavailable. -}
balStabLine : List Cand -> List Row -> List Place -> List Row -> String
balStabLine cs rows0 ps rows = match balTarget False cs rows0
  Err _ =>
    "  stability: the unstabilized comparison packing could not be derived\n"
  Ok (lps, lrows) => stringConcat [
    "  stability: \{intToString (balHeldCount ps lps)} of \{intToString (listLen ps)} gates held on their committed row",
    " (incumbent slack \{intToString balStabPct}% of a row's load)",
    "; pole \{balSecs (balPole rows)} against \{balSecs (balPole lrows)} unstabilized",
    " (\{balDelta (balPole rows - balPole lrows)}),",
    " pole/floor \{balMilli (balFactorMilli cs rows)} against \{balMilli (balFactorMilli cs lrows)}\n",
  ]

-- Gates the preference actually HELD: still on the row they were committed to,
-- where the bare-LPT packing would have moved them.
--
-- NOT "gates the two packings disagree about", which is the larger and
-- misleading number.  Holding one gate shifts the row loads every LATER
-- placement is measured against, so bare LPT and the stabilized packing can
-- also disagree about gates that were themselves MOVED — `stability_preference`
-- has exactly one of each, and reporting 2 there under the word "held" would be
-- a count that does not mean what the sentence around it says.
balHeldCount : List Place -> List Place -> Int
balHeldCount [] _ = 0
balHeldCount (p :: ps) qs
  | p.pto == p.pfrom && balPlaceOf p.pname qs /= p.pto = 1 + balHeldCount ps qs
  | otherwise = balHeldCount ps qs

balMoved : List Place -> Int
balMoved [] = 0
balMoved (p :: ps)
  | p.pfrom /= p.pto = 1 + balMoved ps
  | otherwise = balMoved ps

-- ── Thin-evidence visibility (S-4, #2178/#2207) ─────────────────────────────
--
-- "A gate balanced off a single sample is a fact the tool states, not one a
-- reader has to go find." Bucketing (above) makes the SCORE tolerant of
-- ordinary noise; it does not make a one-sample median any less thin. Both
-- facts are true at once, so both get reported.
balThinSamples : Int
balThinSamples = 2

balThinCount : List GateCost -> Int
balThinCount [] = 0
balThinCount (c :: cs)
  | c.samples < balThinSamples = 1 + balThinCount cs
  | otherwise = balThinCount cs

-- Printed unconditionally in ordinary output (never behind a flag): even
-- "0 of N" is worth stating, because it is the reader's evidence that the
-- baseline is not currently resting on single-sample data, not merely an
-- absence of a warning they might otherwise wonder about.
balThinLine : List GateCost -> String
balThinLine base =
  "  \{intToString (balThinCount base)} of \{intToString (listLen base)} gates are scheduled off a single sample (samples < \{intToString balThinSamples})\n"

-- ── Out-of-sample error of the packing statistic (S-2, #2222) ───────────────

{- | What the packing statistic's estimates are actually WORTH, printed in
   ordinary output beside the projection they underwrite.

   Before S-2 the balancer scheduled on `medianMs` with NO STATED ERROR: every
   number in this report was a point estimate presented as if exact, and the
   only account of its accuracy was a prose claim in `balCalibLines` that the
   median "systematically underestimates".  True, as it turns out — but nobody
   had measured by how much, and the two doc-comments asserting the baseline's
   sample state had both gone stale within two ingests.  A figure the tool
   derives on every run cannot rot that way.

   THE PROTOCOL, and why it is out-of-sample.  An estimate validated against
   the samples that defined it is an in-sample residual and is worth nothing:
   the median of three numbers is trivially close to those three numbers.  So
   each recorded run is held out in turn, the statistic for every gate is
   recomputed from the OTHER runs' samples ONLY, and the sum of those
   estimates is scored against the held-out run's actual total.  No estimate
   is ever graded against a sample that helped produce it.

   LEAVING OUT A RUN REQUIRES KNOWING WHICH SAMPLE CAME FROM IT, AND THAT
   IS READ, NEVER INFERRED (FR-1, #2222 review S0-1).  Until FR-1 this block
   inferred it: `ms[i]` was taken to be the i-th retained run's sample whenever
   a gate's `samples` equalled the number of distinct runIds in `runs[]`, on
   the argument that a gate receives at most one sample per run.  The premise
   is true and the conclusion does not follow.  `test/gate_cost_ingest.sh`
   trims `runs[]` by total ROW count (`MAX_RUNS`, one row per
   `runId:runAttempt:shard`) and each gate's `ms` by SAMPLE count
   (`MAX_SAMPLES`), independently, per gate — the two counters are unrelated,
   and they agreed only because the committed file happened to hold exactly
   3 runs x 8 shards with no gate having ever missed one.  One gate failing
   one run puts that gate's count back to equal with the ALIGNMENT wrong, and
   every fold then grades one run's estimate against a different run's
   measurement, at exit 0, with no warning.

   So the join is now by runId, exactly: a gate contributes its sample for
   fold `i` only if exactly one of its `sampleRuns` entries equals the i-th
   recorded runId.  Zero matches (a failed gate, a sample older than the
   retained run window, or a legacy sample with no attribution at all) and
   ambiguous matches (two samples claiming one runId) both EXCLUDE the gate
   rather than positioning it.

   THE ADMITTED SET IS THE SAME ACROSS EVERY FOLD, DELIBERATELY.  A gate
   missing run 2's sample could still be folded into runs 1 and 3, but then
   each row of the table below would be a sum over a different set of gates
   and the `predicted`/`actual` columns would not be comparable row to row —
   a reader would be looking at three totals of three different things.  So
   the admission is all-or-nothing per gate: a gate is folded in only if it
   carries an exactly attributed sample for EVERY recorded run, and the
   header states how many gates that is out of how many are schedulable.

   AND IF NOTHING QUALIFIES, THERE IS NO NUMBER.  A baseline whose samples
   predate `sampleRuns` (every baseline committed before FR-1) has no
   attribution to join on, so this block prints what it does not know and how
   many samples that verdict rests on.  It never falls back to the count-based
   inference: the whole defect was a plausible number where an absence
   belonged.

   A gate short a sample is also exactly the case the `balCalibLines` residual
   blames on failed gates, so the two accounts stay consistent.

   THE FIGURE IS AN UPPER BOUND ON THE PRODUCTION ERROR, NOT AN ESTIMATE OF
   IT.  Holding out one of N samples trains the statistic at N-1, one below
   what the committed file actually schedules from, and fewer samples is
   strictly worse.  Read it as "no worse than this". -}
balOosBlock : List GateCost -> List Cand -> List RunRecord -> String
balOosBlock base cs runs =
  let ids = balRunIds runs []
  let nr = listLen ids
  if nr < 2 then
    "  out-of-sample error of the packing statistic: not derivable (\{intToString nr} recorded run(s); predicting one run from the others needs at least two)\n"
  else
    let vs = balOosVecs base cs ids
    let ne = listLen vs
    if ne == 0 then
      "  out-of-sample error of the packing statistic: not derivable — \{intToString (balAttrKnown base cs)} of \{intToString (balAttrTotal base cs)} retained samples carry run attribution, and no schedulable gate carries an exactly attributed sample from each of the \{intToString nr} recorded runs\n"
    else
      stringConcat [
        "  out-of-sample error of the packing statistic (leave-one-run-out over the \{intToString nr} runs in runs[], across the \{intToString ne} of \{intToString (listLen cs)} schedulable gates carrying a run-attributed sample from every run):\n",
        joinNl (balOosFolds vs ids 0 nr),
        "\n",
        balOosSummary vs nr,
        balOosDriftLine base,
      ]

balOosFolds : List (List Int) -> List String -> Int -> Int -> List String
balOosFolds vs ids i nr
  | i >= nr = []
  | otherwise =
    let p = balOosPred vs i
    let a = balOosAct vs i
    "    run \{balPadR 13 (balNthStr i ids)} predicted \{balPadL 9 (balSecs p)}   actual \{balPadL 9 (balSecs a)}   \{balPadL 7 (balPct1 (p - a) a)}"
      :: balOosFolds vs ids (i + 1) nr

-- The bias is the number a reader should carry away, so it says which way it
-- points: the median is the LOW-side robust choice, and the underestimate is
-- the price of a statistic one wild sample cannot move.  `gate_cost.packStat`
-- carries the measurement that settled that trade.
balOosSummary : List (List Int) -> Int -> String
balOosSummary vs nr =
  let p = balOosPredAll vs 0 nr
  let a = balOosActAll vs 0 nr
  "    mean |error| \{balTenth (balOosAbsPm vs 0 nr 0 / nr)}   systematic bias \{balPct1 (p - a) a} (the median is the low-side robust choice — see gate_cost.packStat)\n"

-- `packStat` and the committed `medianMs` are two spellings of ONE rule, kept
-- equal only by `test/gate_cost_ingest.sh`'s awk `median()` and
-- `gate_cost.packStat` agreeing.  Counting the rows where they disagree turns
-- a drift between those two into a printed number rather than a silently
-- different score.  Expected to be 0, and printed only when it is not.
balOosDriftLine : List GateCost -> String
balOosDriftLine base =
  let n = balStatDrift base
  if n == 0 then
    ""
  else
    "    WARNING: \{intToString n} baseline row(s) carry a medianMs that the packing statistic does not reproduce — the ingester and gate_cost.packStat have drifted; re-ingest before trusting a placement\n"

balStatDrift : List GateCost -> Int
balStatDrift [] = 0
balStatDrift (c :: cs)
  | packStat c.ms == c.medianMs = balStatDrift cs
  | otherwise = 1 + balStatDrift cs

-- The sample vectors of the schedulable gates that carry an exactly
-- run-attributed sample for every recorded run, each REORDERED into `ids`
-- order so that index i genuinely is run i — which is the property the whole
-- block turns on and the property the old count check did not establish.  A
-- gate the baseline has no row for is already a hard error upstream
-- (`balUncosted`), so the `None` arm here is unreachable in a real run and
-- drops rather than guesses.
balOosVecs : List GateCost -> List Cand -> List String -> List (List Int)
balOosVecs _ [] _ = []
balOosVecs base (c :: cs) ids = match costRowOf c.crun base
  None => balOosVecs base cs ids
  Some g => match balOosVecFor g ids
    None => balOosVecs base cs ids
    Some v => v :: balOosVecs base cs ids

-- `Some v` only when EVERY id resolves; one miss drops the whole gate, per
-- the "same admitted set across every fold" rule in `balOosBlock`.
balOosVecFor : GateCost -> List String -> Option (List Int)
balOosVecFor _ [] = Some []
balOosVecFor g (r :: rs) = match balSampleForRun r g.ms g.sampleRuns None
  None => None
  Some v => map (v :: _) (balOosVecFor g rs)

-- The one sample of `g` attributed to run `r`, or `None` if there are zero or
-- more than one.  TWO is as disqualifying as zero: a runId that appears twice
-- in one gate's `sampleRuns` (a re-run recorded under a second runAttempt,
-- say) leaves no fact about which of the two samples "is" that run, and
-- picking either would be the same guess in a smaller costume.  An
-- unattributed sample carries the empty string and matches no real runId, so
-- legacy rows fall out here without a special case.
balSampleForRun : String -> List Int -> List String -> Option Int -> Option Int
balSampleForRun _ [] _ acc = acc
balSampleForRun _ _ [] acc = acc
balSampleForRun r (m :: ms) (s :: ss) acc
  | s /= r = balSampleForRun r ms ss acc
  | otherwise = match acc
    None => balSampleForRun r ms ss (Some m)
    Some _ => None

-- How many retained samples across the schedulable gates carry ANY run
-- attribution, and how many there are in total.  Printed together in the
-- not-derivable line so the reader can tell "this baseline predates the
-- field" (0 of N) from "attribution exists but no gate spans every run".
balAttrKnown : List GateCost -> List Cand -> Int
balAttrKnown _ [] = 0
balAttrKnown base (c :: cs) = match costRowOf c.crun base
  None => balAttrKnown base cs
  Some g => balCountAttr g.sampleRuns + balAttrKnown base cs

balCountAttr : List String -> Int
balCountAttr [] = 0
balCountAttr (s :: ss)
  | s == "" = balCountAttr ss
  | otherwise = 1 + balCountAttr ss

balAttrTotal : List GateCost -> List Cand -> Int
balAttrTotal _ [] = 0
balAttrTotal base (c :: cs) = match costRowOf c.crun base
  None => balAttrTotal base cs
  Some g => listLen g.ms + balAttrTotal base cs

balOosPred : List (List Int) -> Int -> Int
balOosPred [] _ = 0
balOosPred (v :: vs) i = packStat (balDropNth i v) + balOosPred vs i

balOosAct : List (List Int) -> Int -> Int
balOosAct [] _ = 0
balOosAct (v :: vs) i = balNth i v + balOosAct vs i

balOosPredAll : List (List Int) -> Int -> Int -> Int
balOosPredAll vs i nr
  | i >= nr = 0
  | otherwise = balOosPred vs i + balOosPredAll vs (i + 1) nr

balOosActAll : List (List Int) -> Int -> Int -> Int
balOosActAll vs i nr
  | i >= nr = 0
  | otherwise = balOosAct vs i + balOosActAll vs (i + 1) nr

-- Per-fold RELATIVE errors, summed in per-mille and averaged by the caller.
-- Per-fold rather than pooled: a fold's own total is the denominator its own
-- error means anything against.
balOosAbsPm : List (List Int) -> Int -> Int -> Int -> Int
balOosAbsPm vs i nr acc
  | i >= nr = acc
  | otherwise =
    let p = balOosPred vs i
    let a = balOosAct vs i
    let d = if p >= a then p - a else a - p
    balOosAbsPm vs (i + 1) nr (acc + (if a > 0 then d * 1000 / a else 0))

balDropNth : Int -> List Int -> List Int
balDropNth _ [] = []
balDropNth i (x :: xs)
  | i <= 0 = xs
  | otherwise = x :: balDropNth (i - 1) xs

-- The distinct runIds of `runs[]`, in file order (oldest first) — the same
-- order `ms` is appended in, which is what makes index i mean run i.
balRunIds : List RunRecord -> List String -> List String
balRunIds [] acc = balRevStrs acc []
balRunIds (r :: rs) acc
  | balHasStr r.runId acc = balRunIds rs acc
  | otherwise = balRunIds rs (r.runId :: acc)

balHasStr : String -> List String -> Bool
balHasStr _ [] = False
balHasStr s (x :: xs)
  | x == s = True
  | otherwise = balHasStr s xs

balRevStrs : List String -> List String -> List String
balRevStrs [] acc = acc
balRevStrs (x :: xs) acc = balRevStrs xs (x :: acc)

balNthStr : Int -> List String -> String
balNthStr _ [] = ""
balNthStr i (x :: xs)
  | i <= 0 = x
  | otherwise = balNthStr (i - 1) xs

-- The projection block both `--check` and the mutating form print, verbatim.
-- One renderer, so the two can never describe different packings.
balReport : String ->
  List Cand ->
  List Row ->
  List Place ->
  List RunRecord ->
  String
balReport label cs rs ps runs = stringConcat [
  "  \{label}: \{intToString (listLen cs)} schedulable gates over \{intToString (listLen rs)} rows\n",
  "  predicted row wall clock (makespan of the per-gate baseline medians over the row's recorded workers; * = borrowed/defaulted worker count):\n",
  joinNl (balRowLines rs runs),
  "\n  pole \{balSecs (balPole rs)} (\{balPoleRow rs})   median \{balSecs (balMedian rs)}   floor \{balSecs (balFloor cs rs)}   pole/floor \{balMilli (balFactorMilli cs rs)}\n",
  balFloorLine cs rs,
  "  gates whose row changes: \{intToString (balMoved ps)}\n",
]

-- ── The decision ────────────────────────────────────────────────────────────

-- HYSTERESIS MUST NEVER PRESERVE AN ILLEGAL ASSIGNMENT.
--
-- This is the first test for a reason, and it was not in the first draft: the
-- `wasm_only_row` fixture caught it.  There, a gate needing wasm-tools sat on
-- a row with `wasm_arm = false`, and moving it to the one legal row changed
-- the pole by 10ms out of 310 — far inside the 5% band.  So the balancer
-- reported "unchanged (within the hysteresis band)", exited 0, and left the
-- gate scheduled on a row where its toolchain is absent.
--
-- A band that damps churn is correct; a band that damps a CORRECTNESS repair
-- is a silent wrong answer.  Cost is what the margin is allowed to weigh, and
-- legality is not a cost.
balCurrentLegal : List Cand -> List Row -> Bool
balCurrentLegal [] _ = True
balCurrentLegal (c :: cs) rs
  | c.needsWasm && not (balRowIsWasm c.curRow rs) = False
  | otherwise = balCurrentLegal cs rs

{- | THE BAND ANNOTATES; IT NO LONGER DECIDES (S-4, #2178).

   S-3 gave the band a THIRD job beyond damping churn: when the committed
   assignment differed from the target by less than `balMarginPct` of the pole,
   the balancer kept the committed one and exited 0.  That made "the derived
   assignment" a SET rather than a value, and a check can only ever police a
   value.  Measured on the balanced registry, moving `diff_compiler_source_bytes`
   from `tools` to `types` by hand shifted the pole by 0s, so
   `medaka gate balance --check` reported *"already balanced"* and exited 0 —
   the hand edit this slice exists to make red.

   The argument is S-3's own, one step further.  Its comment above says a band
   that damps a CORRECTNESS repair is a silent wrong answer, because "legality
   is not a cost".  DERIVEDNESS is not a cost either: the whole point of
   #2178 is that `shard` stops being data a human may choose, and a band that
   silently ratifies a human's choice is that property's only hole.

   So the emitted assignment is now always `balTarget` — a pure function of
   (rows, costs, toolchains).  The band survives as the REPORT's account of how
   much a move was worth, and `balMarginPct` is still what that account is
   measured against.

   Idempotence is unaffected and is now trivial rather than argued: the target
   is a fixed point of itself, so a second run on an unchanged baseline emits
   byte-identical text and `balWrite` writes nothing.

   What the band cost, and what is paid for it: a baseline re-ingest whose
   noise moves a gate now moves that gate in `test/gates.toml` too, so a
   re-ingest commit carries a matrix reshuffle it used to be able to skip.
   That is the price of the assignment being checkable at all, and the repair
   is two mechanical commands (`medaka gate balance`, `make gen-ci`), not a
   judgement call.

   THAT PRICE IS NOW PARTLY PAID BACK, AND NOT BY REINSTATING THIS BAND
   (S-3, #2218).  Re-ingests became scheduled (S-1), so "a reshuffle per
   re-ingest" stopped being occasional: measured on this registry, an ordinary
   ±2% perturbation moved 89–128 of 202 gates.  The response is
   `balPickStable` — an incumbent preference INSIDE the packing, taking the
   committed `shard` as an explicit argument — and the distinction from what
   this comment describes is the entire point.  The band declined to emit a
   derived value; the preference derives a different value, from a wider input
   list, and `--check` re-derives it from committed bytes exactly as before.
   The four annotations below are unchanged and still describe the WHOLE
   assignment's pole gain; `balStabLine` is where the preference's own
   arithmetic is reported. -}
balBandNote : Bool -> Bool -> Bool -> String
balBandNote True _ _ = " — OVERRIDDEN (illegal assignment)"
balBandNote _ True _ = " — TAKEN"
balBandNote _ _ True =
  " — OVERRIDDEN (the committed assignment is not the derived one)"
balBandNote _ _ _ =
  " — not reached (the committed assignment already IS the derived one)"

-- The first gate whose committed row is not its derived row, for the check's
-- message.  A `git diff` of 164 lines does not tell a reader WHICH gate the
-- tool disagrees about, and that is the only fact they need.
balFirstMove : List Place -> Option Place
balFirstMove [] = None
balFirstMove (p :: ps)
  | p.pfrom /= p.pto = Some p
  | otherwise = balFirstMove ps

balMoveLine : List Place -> String
balMoveLine ps = match balFirstMove ps
  None => ""
  Some p =>
    "  first divergence: '\{p.pname}' is committed on row '\{p.pfrom}' but derives to '\{p.pto}'.\n"

{- | The enforcement.  Distinguishes the two ways the budget can be missed,
   because they need different repairs: a packing this command could fix, or
   one gate that has to get faster before any packing can.

   THE SPLIT IS NOW ON WHAT SETS THE FLOOR, NOT ON WHETHER ONE GATE BLOWS THE
   TARGET (S-4, #2216) — and that is a narrowing, deliberately.  Under
   `pole / median` the indivisible-gate branch fired whenever one gate was
   expensive relative to the typical row, which is a fact about the SUITE and
   was the perverse red (`nonpole_speedup.toml`): that case now scores 1.000 and
   is not a refusal at all, because the floor moved up with the gate.

   What survives is the case where it is still true: the floor is a lower bound
   and not always an achievable makespan (500 + three 300s over three rows floors
   at 500 and cannot beat 600), so a miss whose floor is gate-set is a miss
   indivisibility caused.  The message keeps the sentence that made the old one
   worth reading — a reader must leave it knowing the gate has to get FASTER
   (or be split), not just that a number is renamed — while stating honestly
   that a repack may still close part of the gap.  Pointing a reader at
   "rebalance harder" when the answer is "this gate must get faster" costs them
   the whole investigation; pointing them the other way costs the same. -}
balEnforce : List Cand -> List Row -> Option String
balEnforce cs rs
  | balFactorMilli cs rs <= balTargetMilli = None
  | balFloorIsGate cs rs =
    Some
      (stringConcat [
        "medaka gate balance: the emitted assignment misses the pole/floor budget of ",
        balMilli balTargetMilli,
        " (it is ",
        balMilli (balFactorMilli cs rs),
        ").\n",
        "  The floor is '\{(balMaxCand cs).cname}' alone, at \{balSecs (balMaxCand cs).cms}, against a pole of \{balSecs (balPole rs)}.\n",
        "  Gates are indivisible, so the pole can never go below the most expensive\n",
        "  gate, and the rest of this gap is what would not fit around it.  This is\n",
        "  a gate that has to get FASTER (or be split); repacking cannot move the\n",
        "  floor while it stands.\n",
      ])
  | otherwise =
    Some
      (stringConcat [
        "medaka gate balance: the emitted assignment misses the pole/floor budget of ",
        balMilli balTargetMilli,
        " (it is ",
        balMilli (balFactorMilli cs rs),
        ").\n",
        "  No single gate explains it — the floor is \{balSecs (balFloor cs rs)} and no gate costs that\n",
        "  much — so this is the packing: rows within budget exist and the heuristic\n",
        "  did not find them.\n",
      ])

-- ── Writing the assignment back ─────────────────────────────────────────────

-- The new `shard` value for every entry, in FILE ORDER — `other-job` entries
-- included, carrying their sentinel through unchanged, so the list lines up
-- one-for-one with the file's `[[gate]]` blocks and `balSplice` never has to
-- decide which entries it is allowed to skip.
balShardValues : List Gate -> List Place -> List String
balShardValues [] _ = []
balShardValues (g :: gs) ps
  | g.shard == balOtherJob = balOtherJob :: balShardValues gs ps
  | otherwise = balPlaceOf g.name ps :: balShardValues gs ps

balPlaceOf : String -> List Place -> String
balPlaceOf n [] = n
balPlaceOf n (p :: ps)
  | p.pname == n = p.pto
  | otherwise = balPlaceOf n ps

-- Targeted line replacement: every `shard = "…"` line inside a `[[gate]]`
-- block becomes that gate's new value, and every other byte of the file is
-- copied verbatim.  Not a TOML round-trip — `stdlib/toml.mdk` has no
-- serializer, and re-emitting 230 hand-written entries (with their comment
-- blocks) from a parse tree would rewrite far more than the field that
-- changed.
--
-- The `[[shard]]` tables at the foot of the file carry no `shard =` key, and
-- `inGate` goes false at the first of them, so the row definitions are out of
-- reach by construction as well as by key name.
balSplice : List String -> List String -> Result String (List String)
balSplice vals src = balSpliceGo vals src False []

balSpliceGo : List String ->
  List String ->
  Bool ->
  List String ->
  Result String (List String)
balSpliceGo [] [] _ acc = Ok (reverseL acc)
balSpliceGo vs [] _ _ =
  Err
    "medaka gate balance: test/gates.toml has fewer [[gate]] shard lines than entries (\{intToString (listLen vs)} unplaced)"
balSpliceGo vs (l :: ls) inGate acc
  | l == "[[gate]]" = balSpliceGo vs ls True (l :: acc)
  | l == "[[shard]]" = balSpliceGo vs ls False (l :: acc)
  | inGate && startsWith "shard = \"" l = match vs
    [] =>
      Err
        "medaka gate balance: test/gates.toml has more [[gate]] shard lines than entries"
    v :: rest => balSpliceGo rest ls inGate ("shard = \"\{v}\"" :: acc)
  | otherwise = balSpliceGo vs ls inGate (l :: acc)

-- Everything that can go wrong before a byte is written, as one `Result`: the
-- projection to print, and the registry text to write.  `ciNewText`'s shape,
-- for `ciCmdBody`'s reason — the mutating form and `--check` must compute the
-- SAME answer and differ only in what they do with it.
export
balNewText : String -> String -> String -> Result String (String, String)
balNewText regPath regSrc baseSrc = match parseRegistry regSrc
  Err m => Err "medaka gate balance: \{m}"
  Ok gates => match parseShards regSrc
    Err m => Err "medaka gate balance: \{m}"
    Ok shs => match parseCostBaseline baseSrc
      Err m => Err "medaka gate balance: \{m}"
      -- `runs[]` (#2208: jobs/parallel/rowElapsedMs) is LOAD-BEARING as of
      -- this slice: `jobs` is the width of the worker pool each row's makespan
      -- is computed over, and `rowElapsedMs` is what that prediction is
      -- calibrated against.  S-1 landed the read; this is what consumes it.
      Ok base => match parseCostRuns baseSrc
        Err m => Err "medaka gate balance: \{m}"
        Ok runsRead => match balUnknownRows shs gates
          b :: bs =>
            Err
              "medaka gate balance: \{regPath}: gate(s) name a shard with no [[shard]] row: \{joinSpace (b :: bs)}"
          [] => match balUncosted base gates
            u :: us =>
              Err
                (stringConcat [
                  "medaka gate balance: \{intToString (listLen (u :: us))} schedulable gate(s) have no row in the cost baseline:\n",
                  joinNl (balIndent (u :: us)),
                  "\n  Refusing to pack: a missing cost is not a cheap gate, it is an\n",
                  "  unknown one, and treating it as 0 would pile it onto the lightest row.\n",
                  "  Re-ingest the baseline (test/gate_cost_ingest.sh) or fix the gate's `run`.\n",
                ])
            [] => match balPinErrors gates shs
              e :: es =>
                Err
                  (stringConcat [
                    "medaka gate balance: \{regPath}: a closed row's membership does not match its declared `pinned_gates`:\n",
                    joinNl (balIndent (e :: es)),
                    "\n  A `full_cores` row is CLOSED: the packer moves nothing onto it and\n",
                    "  nothing off it, so its members are the one `shard` value no cost\n",
                    "  measurement derives.  They are DECLARED in that [[shard]] row's\n",
                    "  `pinned_gates` and checked against the registry in both directions,\n",
                    "  so a hand-moved `shard` cannot be adopted as the new pin.\n",
                    "  Repair the gate's `shard`; change `pinned_gates` only when the row's\n",
                    "  membership is genuinely meant to differ, and say why in its rationale\n",
                    "  file (docs/ops/GATE-REGISTRY-DESIGN.md §2).\n",
                  ])
              [] => balCompute regPath gates shs base runsRead regSrc

balIndent : List String -> List String
balIndent [] = []
balIndent (x :: xs) = "    \{x}" :: balIndent xs

balCompute : String ->
  List Gate ->
  List Shard ->
  List GateCost ->
  List RunRecord ->
  String ->
  Result String (String, String)
balCompute regPath gates shs base runs regSrc =
  let cs = balCands base gates
  -- Cost-descending into BOTH scorings — `balAdd`'s and `balCurrent`'s notes.
  let (_, curRows) = balCurrent (balSortCands cs) (balRows runs shs)
  match balTarget True cs (balRows runs shs)
    Err m => Err m
    Ok (ps, rows) =>
      let illegal = not (balCurrentLegal cs curRows)
      let gains = balPole rows * 100 < balPole curRows * (100 - balMarginPct)
      let moved = balMoved ps > 0
      let label =
        if illegal then
          "rebalanced (the committed assignment ran a gate on a row lacking its toolchain)"
        else if moved then
          "rebalanced"
        else
          "unchanged (the committed assignment is already the derived one)"
      let head = stringConcat
        [
          "medaka gate balance: \{regPath}\n",
          balReport label cs rows ps runs,
          balThinLine base,
          balOosBlock base cs runs,
          balStabLine cs (balRows runs shs) ps rows,
          "  hysteresis: a move needs a pole gain of more than \{intToString balMarginPct}%",
          balBandNote illegal gains moved,
          "\n  budget pole/floor \{balMilli balTargetMilli}",
          if balFactorMilli cs rows <= balTargetMilli then
            " — MET\n"
          else
            " — MISSED\n",
          balMoveLine ps,
          -- Scored against `curRows`, never `rows`: the recorded wall clock came
          -- from the COMMITTED assignment, so comparing it to the DERIVED one
          -- would grade the model against a gate set that has never run.
          "  calibration — last recorded CI wall clock vs this model's prediction for the COMMITTED assignment:\n",
          joinNl (balCalibLines cs curRows runs),
          "\n",
        ]
      match balEnforce cs rows
        Some m => Err "\{head}\{m}"
        None => match balSplice (balShardValues gates ps) (splitNl regSrc)
          Err m => Err "\{head}\{m}"
          Ok outLines => Ok (head, joinNl outLines)

-- ── `gate budget` — #2180's governor (S-5) ──────────────────────────────────
--
-- A required, cheap, TEXT-ONLY gate — no build, `gate verify`'s shape — that
-- reds on any of three clauses:
--
--   (a) a schedulable gate has no cost baseline entry (`balUncosted`'s
--       condition). The sprint contract's literal clause (a) — "a registry
--       entry lacks a cost declaration" — cannot occur: `cost` is a REQUIRED
--       TOML field (`reqStr i "cost" e`) and a registry missing it fails to
--       PARSE, long before this gate runs. `balUncosted`'s "a schedulable
--       gate the packer cannot price" is the state that both can occur and
--       matters.
--   (b) a gate's measured cost has eaten into the tolerance-adjusted timeout
--       its declared `cost` class implies (`timeoutFor`). The class is not
--       free-floating metadata — it is what kills the gate — so "declared
--       class no longer matches reality" is measurable exactly here.
--   (c) the projected `pole/floor` (S-4's metric, `balTargetMilli`) exceeds
--       budget on the SAME assignment `gate balance --check` derives —
--       computed from `balCands`/`balRows`/`balTarget`, which already skip
--       `other-job` gates, so an `other-job` gate's (nonexistent) cost never
--       contributes here either.
--
-- Any clause may be accepted on purpose with a structured, greppable
-- acknowledgment: a trailer line on an AUTHORED commit message in the change
-- under test. There is no PR body in a `merge_group` run, so an authored
-- commit message is the one thing the queue can always see. The `.sh` gate
-- script obtains that text and passes it via `--commit-message`; this module
-- touches no git state itself, so every clause stays testable on plain
-- strings.
--
-- This comment used to say the CHECKED-OUT commit's own message was that
-- text, read with `git log -1 --pretty=%B`, and that being "ordinary git
-- behaviour, not a GitHub-specific API" meant it "needs no separate
-- verification against GitHub policy". That was wrong and is the bug FR-2
-- fixed (review S1-2): it was never a policy question, it was a question
-- about the git state `actions/checkout@v4` produces, and with no `ref:` that
-- is a SYNTHETIC merge commit on both `pull_request` and `merge_group` —
-- GitHub boilerplate, never the author's text. Nothing in THIS module changed
-- (`--commit-message` parsing was always correct); the fix is entirely in how
-- `.github/workflows/ci.yml` and test/diff_compiler_gate_budget.sh obtain the
-- text. See docs/ops/GATE-REGISTRY-DESIGN.md §14 for the measured evidence.

-- The exact trailer a reader pastes: `Gate-Budget-Override: <token>`, one per
-- violation accepted, free text after the token (a human reason) never
-- machine-checked. Multiple lines are read one violation per line.
budgetOverridePrefix : String
budgetOverridePrefix = "Gate-Budget-Override: "

budgetOverrideTokens : String -> List String
budgetOverrideTokens msg = budgetTokensFromLines (splitNl msg)

budgetTokensFromLines : List String -> List String
budgetTokensFromLines [] = []
budgetTokensFromLines (l :: ls)
  | startsWith budgetOverridePrefix (stringTrim l) =
    budgetFirstWord
        (stringTrim (budgetDropPrefix budgetOverridePrefix (stringTrim l)))
      :: budgetTokensFromLines ls
  | otherwise = budgetTokensFromLines ls

budgetDropPrefix : String -> String -> String
budgetDropPrefix pre s = stringSlice (stringLength pre) (stringLength s) s

budgetFirstWord : String -> String
budgetFirstWord s = match splitOnChar ' ' s
  [] => s
  w :: _ => w

budgetAcked : String -> String -> Bool
budgetAcked commitMessage token =
  contains token (budgetOverrideTokens commitMessage)

budgetCountUnacked : String -> List String -> Int
budgetCountUnacked _ [] = 0
budgetCountUnacked commitMessage (t :: ts)
  | budgetAcked commitMessage t = budgetCountUnacked commitMessage ts
  | otherwise = 1 + budgetCountUnacked commitMessage ts

-- ── Clause (a) ───────────────────────────────────────────────────────────────

budgetUncostedNames : List GateCost -> List Gate -> List String
budgetUncostedNames _ [] = []
budgetUncostedNames base (g :: gs)
  | g.shard == balOtherJob = budgetUncostedNames base gs
  | otherwise = match costOf g.run base
    Some _ => budgetUncostedNames base gs
    None => g.name :: budgetUncostedNames base gs

budgetUncostedTokens : List String -> List String
budgetUncostedTokens [] = []
budgetUncostedTokens (n :: ns) = "uncosted:\{n}" :: budgetUncostedTokens ns

budgetUncostedLines : String -> List String -> List String
budgetUncostedLines _ [] = []
budgetUncostedLines commitMessage (n :: ns) =
  let tok = "uncosted:\{n}"
  let ack = if budgetAcked commitMessage tok then " [ACKNOWLEDGED]" else ""
  stringConcat [
      n, ack,
      " — remedy: re-ingest the baseline (test/gate_cost_ingest.sh) so this",
      " gate gets a sample; the `cost` field is present, the packer just has",
      " no price yet, so there is nothing to declare or split here.",
      " To accept unpriced on purpose, paste:\n    Gate-Budget-Override: ", tok,
      "\n"
    ]
    :: budgetUncostedLines commitMessage ns

-- ── Clause (b) ───────────────────────────────────────────────────────────────
--
-- The tolerance is deliberately the SAME constant as clause (c)'s
-- (`balTargetMilli`, 1.125 = 1 + max(S-2's mean |error| 12.0%, bias 12.5%)):
-- one measured slack, used everywhere a noisy estimate is compared to a hard
-- line. `medianMs` can UNDERSTATE a gate's true cost by that much (S-2), so
-- comparing the raw measurement against the raw timeout would let a gate that
-- is actually over its own kill timeout read as compliant on a lucky sample.
budgetTimeoutMs : String -> Int
budgetTimeoutMs cost = timeoutFor 0 cost * 1000

budgetToleratedMs : String -> Int
budgetToleratedMs cost = budgetTimeoutMs cost * 1000 / balTargetMilli

-- Schedulable, COSTED gates whose measured cost exceeds the tolerance-
-- adjusted ceiling for their declared class. Uncosted gates are clause (a)'s
-- alone — never double-reported here.
budgetOverClassGates : List GateCost -> List Gate -> List Gate
budgetOverClassGates _ [] = []
budgetOverClassGates base (g :: gs)
  | g.shard == balOtherJob = budgetOverClassGates base gs
  | otherwise = match costOf g.run base
    None => budgetOverClassGates base gs
    Some ms if ms > budgetToleratedMs g.cost =>
      g :: budgetOverClassGates base gs
    _ => budgetOverClassGates base gs

budgetOverClassTokens : List Gate -> List String
budgetOverClassTokens [] = []
budgetOverClassTokens (g :: gs) =
  "over-class:\{g.name}" :: budgetOverClassTokens gs

-- `timeoutFor`'s coupling is stated inline: re-classing a gate is not a free
-- label change, it changes when CI kills it.
budgetTimeoutRemedy : String
budgetTimeoutRemedy =
  "Re-classing a gate changes its CI kill timeout (cheap=300s / medium=900s / heavy=3600s, `timeoutFor`) — pick deliberately, not just to silence this gate."

budgetOverClassLines : List GateCost -> String -> List Gate -> List String
budgetOverClassLines _ _ [] = []
budgetOverClassLines base commitMessage (g :: gs) =
  -- `ms` is always `Some` here — `budgetOverClassGates` only keeps gates
  -- `costOf` already resolved; the 0 fallback is unreachable, not a real cost.
  let ms = match costOf g.run base
    Some m => m
    None => 0
  let tok = "over-class:\{g.name}"
  let ack = if budgetAcked commitMessage tok then " [ACKNOWLEDGED]" else ""
  stringConcat [
      "\{g.name} (\{g.cost}, measured \{balSecs ms}, tolerance-adjusted ceiling ",
      balSecs (budgetToleratedMs g.cost),
      " of a \{intToString (timeoutFor 0 g.cost)}s timeout)",
      ack,
      " — remedy: declare a higher `cost` class, split the gate into cheaper",
      " pieces, or demote it with `tiers = [\"nightly\"]` so it leaves the",
      " merge-required path. ",
      budgetTimeoutRemedy,
      " To accept the current cost on purpose, paste:\n    Gate-Budget-Override: ",
      tok,
      "\n",
    ]
    :: budgetOverClassLines base commitMessage gs

-- ── Clause (c) ───────────────────────────────────────────────────────────────
--
-- The SAME projection `gate balance --check` computes — `balCands` already
-- excludes `other-job` gates from packing entirely, so their (nonexistent)
-- cost cannot move this number by construction.
budgetPoleFactor : List Gate ->
  List Shard ->
  List GateCost ->
  List RunRecord ->
  Result String (Option Int)
budgetPoleFactor gates shs base runs =
  let cs = balCands base gates
  match balTarget True cs (balRows runs shs)
    Err m => Err m
    Ok (_, rows) =>
      let factor = balFactorMilli cs rows
      if factor <= balTargetMilli then Ok None else Ok (Some factor)

budgetPoleFloorLines : String -> Option Int -> List String
budgetPoleFloorLines _ None = []
budgetPoleFloorLines commitMessage (Some factor) =
  let tok = "pole-floor"
  let ack = if budgetAcked commitMessage tok then " [ACKNOWLEDGED]" else ""
  stringConcat [
      "projected pole/floor \{balMilli factor} exceeds the budget \{balMilli balTargetMilli} (S-4)",
      ack,
      " — remedy: run `medaka gate balance` to see which row or gate needs to",
      " shrink, split the pole gate, or demote a heavy gate to",
      " `tiers = [\"nightly\"]`. To accept the current pole/floor on purpose, paste:\n    Gate-Budget-Override: ",
      tok,
      "\n",
    ]
    :: []

-- ── Assembling the report ────────────────────────────────────────────────────

budgetIndent : List String -> List String
budgetIndent [] = []
budgetIndent (x :: xs) = "  \{x}" :: budgetIndent xs

budgetSection : String -> List String -> String
budgetSection _ [] = ""
budgetSection title lines =
  "\{title}: \{intToString (listLen lines)}\n\{joinNl (budgetIndent lines)}\n\n"

budgetReport : List GateCost ->
  String ->
  List String ->
  List Gate ->
  Option Int ->
  Result String String
budgetReport base commitMessage uncosted overClass poleFactorOpt =
  let aLines = budgetUncostedLines commitMessage uncosted
  let bLines = budgetOverClassLines base commitMessage overClass
  let cLines = budgetPoleFloorLines commitMessage poleFactorOpt
  let aUnacked =
    budgetCountUnacked commitMessage (budgetUncostedTokens uncosted)
  let bUnacked =
    budgetCountUnacked commitMessage (budgetOverClassTokens overClass)
  let cCount = match poleFactorOpt
    None => 0
    Some _ => 1
  let cUnacked =
    if cCount == 0 then
      0
    else if budgetAcked commitMessage "pole-floor" then
      0
    else
      1
  let total = listLen uncosted + listLen overClass + cCount
  let unacked = aUnacked + bUnacked + cUnacked
  let body = stringConcat [
    budgetSection "no cost baseline entry (clause a)" aLines,
    budgetSection "over declared class, tolerance-adjusted (clause b)" bLines,
    budgetSection "projected pole/floor over budget (clause c)" cLines,
  ]
  if total == 0 then
    Ok "medaka gate budget: OK — 0 violations.\n"
  else if unacked == 0 then
    Ok
      "\{body}medaka gate budget: \{intToString total} violation(s), all acknowledged by commit-message trailer — OK.\n"
  else
    Err
      "\{body}medaka gate budget: FAIL — \{intToString unacked} of \{intToString total} violation(s) not acknowledged. Paste the `Gate-Budget-Override:` trailer(s) shown above onto your commit message to accept them on purpose.\n"

export
budgetOutput : String -> String -> String -> String -> Result String String
budgetOutput regPath regSrc baseSrc commitMessage = match parseRegistry regSrc
  Err m => Err "medaka gate budget: \{m}"
  Ok gates => match parseShards regSrc
    Err m => Err "medaka gate budget: \{m}"
    Ok shs => match parseCostBaseline baseSrc
      Err m => Err "medaka gate budget: \{m}"
      Ok base => match parseCostRuns baseSrc
        Err m => Err "medaka gate budget: \{m}"
        Ok runs => match balUnknownRows shs gates
          u :: us =>
            Err
              "medaka gate budget: \{regPath}: gate(s) name a shard with no [[shard]] row: \{joinSpace (u :: us)}\n"
          [] =>
            let uncosted = budgetUncostedNames base gates
            let overClass = budgetOverClassGates base gates
            match budgetPoleFactor gates shs base runs
              Err m => Err "medaka gate budget: \{m}\n"
              Ok poleFactorOpt =>
                budgetReport base commitMessage uncosted overClass poleFactorOpt
# DESUGAR
(DUse false (UseGroup ("tools" "gate_registry") ((mem "Gate" false) (mem "Shard" false) (mem "parseRegistry" false) (mem "parseShards" false) (mem "joinSpace" false))))
(DUse false (UseGroup ("tools" "gate_cost") ((mem "GateCost" false) (mem "RunRecord" false) (mem "baselineKey" false) (mem "costOf" false) (mem "costRowOf" false) (mem "gateSetDigest" false) (mem "latestRunForShard" false) (mem "packStat" false) (mem "parseCostBaseline" false) (mem "parseCostRuns" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "isNonEmptyL" false) (mem "joinNl" false) (mem "listLen" false) (mem "maxI" false) (mem "minI" false) (mem "reverseL" false) (mem "splitNl" false) (mem "splitOnChar" false) (mem "startsWith" false) (mem "stringTrim" false))))
(DTypeSig true "timeoutFor" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "timeoutFor" ((PVar "override") (PVar "cost")) (EIf (EBinOp ">" (EVar "override") (ELit (LInt 0))) (EVar "override") (EIf (EBinOp "==" (EVar "cost") (ELit (LString "cheap"))) (ELit (LInt 300)) (EIf (EBinOp "==" (EVar "cost") (ELit (LString "medium"))) (ELit (LInt 900)) (EIf (EBinOp "==" (EVar "cost") (ELit (LString "heavy"))) (ELit (LInt 3600)) (EIf (EVar "otherwise") (ELit (LInt 900)) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DData Private "Cand" () ((variant "Cand" (ConNamed (field "cname" (TyCon "String")) (field "crun" (TyCon "String")) (field "curRow" (TyCon "String")) (field "cms" (TyCon "Int")) (field "needsWasm" (TyCon "Bool"))))) ())
(DData Private "Row" () ((variant "Row" (ConNamed (field "rname" (TyCon "String")) (field "rwasm" (TyCon "Bool")) (field "rclosed" (TyCon "Bool")) (field "rload" (TyCon "Int")) (field "rcount" (TyCon "Int")) (field "rjobs" (TyCon "Int")) (field "rbuckets" (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DData Private "Place" () ((variant "Place" (ConNamed (field "pname" (TyCon "String")) (field "pfrom" (TyCon "String")) (field "pto" (TyCon "String"))))) ())
(DTypeSig true "balOtherJob" (TyCon "String"))
(DFunDef false "balOtherJob" () (ELit (LString "other-job")))
(DTypeSig false "balTargetMilli" (TyCon "Int"))
(DFunDef false "balTargetMilli" () (ELit (LInt 1125)))
(DTypeSig false "balMarginPct" (TyCon "Int"))
(DFunDef false "balMarginPct" () (ELit (LInt 5)))
(DTypeSig false "balStabPct" (TyCon "Int"))
(DFunDef false "balStabPct" () (ELit (LInt 5)))
(DTypeSig false "balNeedsWasm" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "balNeedsWasm" ((PList)) (EVar "False"))
(DFunDef false "balNeedsWasm" ((PCons (PVar "t") (PVar "ts"))) (EIf (EBinOp "==" (EVar "t") (ELit (LString "wasm-tools"))) (EVar "True") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "node"))) (EVar "t")) (EVar "True") (EIf (EVar "otherwise") (EApp (EVar "balNeedsWasm") (EVar "ts")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balUnknownRows" (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balUnknownRows" (PWild (PList)) (EListLit))
(DFunDef false "balUnknownRows" ((PVar "shs") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EApp (EApp (EVar "balUnknownRows") (EVar "shs")) (EVar "gs")) (EIf (EApp (EApp (EVar "balHasRow") (EFieldAccess (EVar "g") "shard")) (EVar "shs")) (EApp (EApp (EVar "balUnknownRows") (EVar "shs")) (EVar "gs")) (EIf (EVar "otherwise") (EBinOp "::" (EFieldAccess (EVar "g") "name") (EApp (EApp (EVar "balUnknownRows") (EVar "shs")) (EVar "gs"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balHasRow" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyCon "Bool"))))
(DFunDef false "balHasRow" (PWild (PList)) (EVar "False"))
(DFunDef false "balHasRow" ((PVar "n") (PCons (PVar "s") (PVar "ss"))) (EIf (EBinOp "==" (EFieldAccess (EVar "s") "name") (EVar "n")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "balHasRow") (EVar "n")) (EVar "ss")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balUncosted" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balUncosted" (PWild (PList)) (EListLit))
(DFunDef false "balUncosted" ((PVar "base") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EApp (EApp (EVar "balUncosted") (EVar "base")) (EVar "gs")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "costOf") (EFieldAccess (EVar "g") "run")) (EVar "base")) (arm (PCon "Some" PWild) () (EApp (EApp (EVar "balUncosted") (EVar "base")) (EVar "gs"))) (arm (PCon "None") () (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString " (baseline key '"))) (EApp (EVar "display") (EApp (EVar "baselineKey") (EFieldAccess (EVar "g") "run")))) (ELit (LString "')"))) (EApp (EApp (EVar "balUncosted") (EVar "base")) (EVar "gs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balCands" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Cand")))))
(DFunDef false "balCands" (PWild (PList)) (EListLit))
(DFunDef false "balCands" ((PVar "base") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EApp (EApp (EVar "balCands") (EVar "base")) (EVar "gs")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "costOf") (EFieldAccess (EVar "g") "run")) (EVar "base")) (arm (PCon "None") () (EApp (EApp (EVar "balCands") (EVar "base")) (EVar "gs"))) (arm (PCon "Some" (PVar "ms")) () (EBinOp "::" (ERecordCreate "Cand" ((fa "cname" (EFieldAccess (EVar "g") "name")) (fa "crun" (EFieldAccess (EVar "g") "run")) (fa "curRow" (EFieldAccess (EVar "g") "shard")) (fa "cms" (EVar "ms")) (fa "needsWasm" (EApp (EVar "balNeedsWasm") (EFieldAccess (EVar "g") "toolchain"))))) (EApp (EApp (EVar "balCands") (EVar "base")) (EVar "gs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRows" (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyApp (TyCon "List") (TyCon "Row")))))
(DFunDef false "balRows" (PWild (PList)) (EListLit))
(DFunDef false "balRows" ((PVar "runs") (PCons (PVar "s") (PVar "ss"))) (EBlock (DoLet false false (PVar "j") (EApp (EApp (EVar "balJobsFor") (EFieldAccess (EVar "s") "name")) (EVar "runs"))) (DoExpr (EBinOp "::" (ERecordCreate "Row" ((fa "rname" (EFieldAccess (EVar "s") "name")) (fa "rwasm" (EFieldAccess (EVar "s") "wasmArm")) (fa "rclosed" (EFieldAccess (EVar "s") "fullCores")) (fa "rload" (ELit (LInt 0))) (fa "rcount" (ELit (LInt 0))) (fa "rjobs" (EVar "j")) (fa "rbuckets" (EApp (EVar "balZeros") (EVar "j"))))) (EApp (EApp (EVar "balRows") (EVar "runs")) (EVar "ss"))))))
(DTypeSig false "balJobsFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyCon "Int"))))
(DFunDef false "balJobsFor" ((PVar "n") (PVar "runs")) (EMatch (EApp (EApp (EVar "latestRunForShard") (EVar "n")) (EVar "runs")) (arm (PCon "Some" (PVar "r")) () (EMatch (EFieldAccess (EVar "r") "parallel") (arm (PCon "Some" (PCon "False")) () (ELit (LInt 1))) (arm PWild () (EMatch (EFieldAccess (EVar "r") "jobs") (arm (PCon "Some" (PVar "j")) ((GBool (EBinOp ">=" (EVar "j") (ELit (LInt 1))))) (EVar "j")) (arm PWild () (EApp (EApp (EVar "balAnyJobs") (EVar "runs")) (ELit (LInt 1)))))))) (arm (PCon "None") () (EApp (EApp (EVar "balAnyJobs") (EVar "runs")) (ELit (LInt 1))))))
(DTypeSig false "balAnyJobs" (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "balAnyJobs" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "balAnyJobs" ((PCons (PVar "r") (PVar "rs")) (PVar "acc")) (EMatch (EFieldAccess (EVar "r") "jobs") (arm (PCon "Some" (PVar "j")) ((GBool (EBinOp ">=" (EVar "j") (ELit (LInt 1))))) (EApp (EApp (EVar "balAnyJobs") (EVar "rs")) (EVar "j"))) (arm PWild () (EApp (EApp (EVar "balAnyJobs") (EVar "rs")) (EVar "acc")))))
(DTypeSig false "balJobsIsFallback" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyCon "Bool"))))
(DFunDef false "balJobsIsFallback" ((PVar "n") (PVar "runs")) (EMatch (EApp (EApp (EVar "latestRunForShard") (EVar "n")) (EVar "runs")) (arm (PCon "Some" (PVar "r")) () (EMatch (EFieldAccess (EVar "r") "jobs") (arm (PCon "Some" (PVar "j")) ((GBool (EBinOp ">=" (EVar "j") (ELit (LInt 1))))) (EVar "False")) (arm PWild () (EVar "True")))) (arm (PCon "None") () (EVar "True"))))
(DTypeSig false "balZeros" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "balZeros" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (ELit (LInt 0)) (EApp (EVar "balZeros") (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "candBefore" (TyFun (TyCon "Cand") (TyFun (TyCon "Cand") (TyCon "Bool"))))
(DFunDef false "candBefore" ((PVar "a") (PVar "b")) (EIf (EBinOp "/=" (EFieldAccess (EVar "a") "cms") (EFieldAccess (EVar "b") "cms")) (EBinOp ">" (EFieldAccess (EVar "a") "cms") (EFieldAccess (EVar "b") "cms")) (EIf (EVar "otherwise") (EBinOp "<" (EFieldAccess (EVar "a") "cname") (EFieldAccess (EVar "b") "cname")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balSortCands" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyApp (TyCon "List") (TyCon "Cand"))))
(DFunDef false "balSortCands" ((PList)) (EListLit))
(DFunDef false "balSortCands" ((PCons (PVar "x") (PList))) (EBinOp "::" (EVar "x") (EListLit)))
(DFunDef false "balSortCands" ((PVar "xs")) (EBlock (DoLet false false (PTuple (PVar "l") (PVar "r")) (EApp (EApp (EApp (EVar "balHalve") (EVar "xs")) (EListLit)) (EListLit))) (DoExpr (EApp (EApp (EVar "balMergeCands") (EApp (EVar "balSortCands") (EVar "l"))) (EApp (EVar "balSortCands") (EVar "r"))))))
(DTypeSig false "balHalve" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyTuple (TyApp (TyCon "List") (TyCon "Cand")) (TyApp (TyCon "List") (TyCon "Cand")))))))
(DFunDef false "balHalve" ((PList) (PVar "a") (PVar "b")) (ETuple (EVar "a") (EVar "b")))
(DFunDef false "balHalve" ((PCons (PVar "x") (PVar "xs")) (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "balHalve") (EVar "xs")) (EVar "b")) (EBinOp "::" (EVar "x") (EVar "a"))))
(DTypeSig false "balMergeCands" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyApp (TyCon "List") (TyCon "Cand")))))
(DFunDef false "balMergeCands" ((PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "balMergeCands" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "balMergeCands" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EIf (EApp (EApp (EVar "candBefore") (EVar "x")) (EVar "y")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "balMergeCands") (EVar "xs")) (EBinOp "::" (EVar "y") (EVar "ys")))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "balMergeCands") (EBinOp "::" (EVar "x") (EVar "xs"))) (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPick" (TyFun (TyCon "Cand") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "balPick" ((PVar "c") (PVar "rs")) (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EVar "None")))
(DTypeSig false "balPickGo" (TyFun (TyCon "Cand") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "Option") (TyCon "Row")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "balPickGo" (PWild (PList) (PCon "None")) (EVar "None"))
(DFunDef false "balPickGo" (PWild (PList) (PCon "Some" (PVar "b"))) (EApp (EVar "Some") (EFieldAccess (EVar "b") "rname")))
(DFunDef false "balPickGo" ((PVar "c") (PCons (PVar "r") (PVar "rs")) (PVar "best")) (EIf (EFieldAccess (EVar "r") "rclosed") (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EVar "best")) (EIf (EBinOp "&&" (EFieldAccess (EVar "c") "needsWasm") (EApp (EVar "not") (EFieldAccess (EVar "r") "rwasm"))) (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EVar "best")) (EIf (EVar "otherwise") (EMatch (EVar "best") (arm (PCon "None") () (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EApp (EVar "Some") (EVar "r")))) (arm (PCon "Some" (PVar "b")) () (EIf (EBinOp "<" (EFieldAccess (EVar "r") "rload") (EFieldAccess (EVar "b") "rload")) (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EApp (EVar "Some") (EVar "r"))) (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EVar "best"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balPickStable" (TyFun (TyCon "Cand") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "balPickStable" ((PVar "c") (PVar "rs")) (EMatch (EApp (EApp (EVar "balPick") (EVar "c")) (EVar "rs")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "best")) () (EIf (EApp (EApp (EApp (EVar "balStays") (EVar "c")) (EVar "best")) (EVar "rs")) (EApp (EVar "Some") (EFieldAccess (EVar "c") "curRow")) (EApp (EVar "Some") (EVar "best"))))))
(DTypeSig false "balStays" (TyFun (TyCon "Cand") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool")))))
(DFunDef false "balStays" ((PVar "c") (PVar "best") (PVar "rs")) (EIf (EBinOp "==" (EFieldAccess (EVar "c") "curRow") (EVar "best")) (EVar "True") (EIf (EApp (EVar "not") (EApp (EApp (EVar "balRowTakes") (EVar "c")) (EVar "rs"))) (EVar "False") (EIf (EVar "otherwise") (EBinOp "<=" (EBinOp "*" (EApp (EApp (EVar "balRowLoad") (EFieldAccess (EVar "c") "curRow")) (EVar "rs")) (ELit (LInt 100))) (EBinOp "*" (EApp (EApp (EVar "balRowLoad") (EVar "best")) (EVar "rs")) (EBinOp "+" (ELit (LInt 100)) (EVar "balStabPct")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balRowTakes" (TyFun (TyCon "Cand") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool"))))
(DFunDef false "balRowTakes" (PWild (PList)) (EVar "False"))
(DFunDef false "balRowTakes" ((PVar "c") (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "rname") (EFieldAccess (EVar "c") "curRow")) (EBinOp "&&" (EApp (EVar "not") (EFieldAccess (EVar "r") "rclosed")) (EBinOp "||" (EApp (EVar "not") (EFieldAccess (EVar "c") "needsWasm")) (EFieldAccess (EVar "r") "rwasm"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "balRowTakes") (EVar "c")) (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRowLoad" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int"))))
(DFunDef false "balRowLoad" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "balRowLoad" ((PVar "n") (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "rname") (EVar "n")) (EFieldAccess (EVar "r") "rload") (EIf (EVar "otherwise") (EApp (EApp (EVar "balRowLoad") (EVar "n")) (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balAdd" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "List") (TyCon "Row"))))))
(DFunDef false "balAdd" (PWild PWild (PList)) (EListLit))
(DFunDef false "balAdd" ((PVar "n") (PVar "ms") (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "rname") (EVar "n")) (EBlock (DoLet false false (PVar "bs") (EApp (EApp (EVar "balBucketAdd") (EVar "ms")) (EFieldAccess (EVar "r") "rbuckets"))) (DoExpr (EBinOp "::" (EVariantUpdate "Row" (EVar "r") ((fa "rbuckets" (EVar "bs")) (fa "rload" (EApp (EVar "balMaxL") (EVar "bs"))) (fa "rcount" (EBinOp "+" (EFieldAccess (EVar "r") "rcount") (ELit (LInt 1)))))) (EVar "rs")))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "r") (EApp (EApp (EApp (EVar "balAdd") (EVar "n")) (EVar "ms")) (EVar "rs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balBucketAdd" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "balBucketAdd" ((PVar "ms") (PList)) (EBinOp "::" (EVar "ms") (EListLit)))
(DFunDef false "balBucketAdd" ((PVar "ms") (PVar "bs")) (EApp (EApp (EApp (EVar "balBucketPut") (EVar "ms")) (EApp (EVar "balMinL") (EVar "bs"))) (EVar "bs")))
(DTypeSig false "balBucketPut" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "balBucketPut" (PWild PWild (PList)) (EListLit))
(DFunDef false "balBucketPut" ((PVar "ms") (PVar "m") (PCons (PVar "b") (PVar "bs"))) (EIf (EBinOp "==" (EVar "b") (EVar "m")) (EBinOp "::" (EBinOp "+" (EVar "b") (EVar "ms")) (EVar "bs")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "b") (EApp (EApp (EApp (EVar "balBucketPut") (EVar "ms")) (EVar "m")) (EVar "bs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balMinL" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "balMinL" ((PList)) (ELit (LInt 0)))
(DFunDef false "balMinL" ((PCons (PVar "x") (PList))) (EVar "x"))
(DFunDef false "balMinL" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "minI") (EVar "x")) (EApp (EVar "balMinL") (EVar "xs"))))
(DTypeSig false "balMaxL" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "balMaxL" ((PList)) (ELit (LInt 0)))
(DFunDef false "balMaxL" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "maxI") (EVar "x")) (EApp (EVar "balMaxL") (EVar "xs"))))
(DTypeSig false "balPlace" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "List") (TyCon "Row")))))))))
(DFunDef false "balPlace" (PWild (PList) (PVar "rs") (PVar "acc")) (EApp (EVar "Ok") (ETuple (EApp (EVar "reverseL") (EVar "acc")) (EVar "rs"))))
(DFunDef false "balPlace" ((PVar "stab") (PCons (PVar "c") (PVar "cs")) (PVar "rs") (PVar "acc")) (EMatch (EIf (EVar "stab") (EApp (EApp (EVar "balPickStable") (EVar "c")) (EVar "rs")) (EApp (EApp (EVar "balPick") (EVar "c")) (EVar "rs"))) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: no row can run '")) (EApp (EVar "display") (EFieldAccess (EVar "c") "cname"))) (ELit (LString "'.\n"))) (ELit (LString "  It needs the Wasm toolchain (wasm-tools / node), and every row with\n")) (ELit (LString "  wasm_arm = true is closed to the packer (full_cores).  Wasm rows: ")) (EApp (EVar "joinSpace") (EApp (EVar "balWasmRowNames") (EVar "rs"))) (ELit (LString "\n")))))) (arm (PCon "Some" (PVar "rn")) () (EApp (EApp (EApp (EApp (EVar "balPlace") (EVar "stab")) (EVar "cs")) (EApp (EApp (EApp (EVar "balAdd") (EVar "rn")) (EFieldAccess (EVar "c") "cms")) (EVar "rs"))) (EBinOp "::" (ERecordCreate "Place" ((fa "pname" (EFieldAccess (EVar "c") "cname")) (fa "pfrom" (EFieldAccess (EVar "c") "curRow")) (fa "pto" (EVar "rn")))) (EVar "acc"))))))
(DTypeSig false "balWasmRowNames" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "balWasmRowNames" ((PList)) (EListLit))
(DFunDef false "balWasmRowNames" ((PCons (PVar "r") (PVar "rs"))) (EIf (EFieldAccess (EVar "r") "rwasm") (EBinOp "::" (EFieldAccess (EVar "r") "rname") (EApp (EVar "balWasmRowNames") (EVar "rs"))) (EIf (EVar "otherwise") (EApp (EVar "balWasmRowNames") (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balSeedClosed" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "List") (TyCon "Row"))))))))
(DFunDef false "balSeedClosed" ((PList) (PVar "rs") (PVar "acc")) (EApp (EVar "Ok") (ETuple (EApp (EVar "reverseL") (EVar "acc")) (EVar "rs"))))
(DFunDef false "balSeedClosed" ((PCons (PVar "c") (PVar "cs")) (PVar "rs") (PVar "acc")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "balIsClosed") (EFieldAccess (EVar "c") "curRow")) (EVar "rs"))) (EApp (EApp (EApp (EVar "balSeedClosed") (EVar "cs")) (EVar "rs")) (EVar "acc")) (EIf (EBinOp "&&" (EFieldAccess (EVar "c") "needsWasm") (EApp (EVar "not") (EApp (EApp (EVar "balRowIsWasm") (EFieldAccess (EVar "c") "curRow")) (EVar "rs")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: '")) (EApp (EVar "display") (EFieldAccess (EVar "c") "cname"))) (ELit (LString "' needs the Wasm toolchain but is pinned to row '"))) (EApp (EVar "display") (EFieldAccess (EVar "c") "curRow"))) (ELit (LString "', which has wasm_arm = false")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "balSeedClosed") (EVar "cs")) (EApp (EApp (EApp (EVar "balAdd") (EFieldAccess (EVar "c") "curRow")) (EFieldAccess (EVar "c") "cms")) (EVar "rs"))) (EBinOp "::" (ERecordCreate "Place" ((fa "pname" (EFieldAccess (EVar "c") "cname")) (fa "pfrom" (EFieldAccess (EVar "c") "curRow")) (fa "pto" (EFieldAccess (EVar "c") "curRow")))) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balIsClosed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool"))))
(DFunDef false "balIsClosed" (PWild (PList)) (EVar "False"))
(DFunDef false "balIsClosed" ((PVar "n") (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "rname") (EVar "n")) (EFieldAccess (EVar "r") "rclosed") (EIf (EVar "otherwise") (EApp (EApp (EVar "balIsClosed") (EVar "n")) (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRowIsWasm" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool"))))
(DFunDef false "balRowIsWasm" (PWild (PList)) (EVar "False"))
(DFunDef false "balRowIsWasm" ((PVar "n") (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "rname") (EVar "n")) (EFieldAccess (EVar "r") "rwasm") (EIf (EVar "otherwise") (EApp (EApp (EVar "balRowIsWasm") (EVar "n")) (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPinErrors" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balPinErrors" (PWild (PList)) (EListLit))
(DFunDef false "balPinErrors" ((PVar "gs") (PCons (PVar "s") (PVar "ss"))) (EIf (EBinOp "&&" (EApp (EVar "not") (EFieldAccess (EVar "s") "fullCores")) (EApp (EVar "isNonEmptyL") (EFieldAccess (EVar "s") "pinned"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "row '")) (EApp (EVar "display") (EFieldAccess (EVar "s") "name"))) (ELit (LString "': pinned_gates is non-empty ("))) (EApp (EVar "display") (EApp (EVar "joinSpace") (EFieldAccess (EVar "s") "pinned")))) (ELit (LString ") on an OPEN row (full_cores = false); only a closed row's membership is declared, an open row's is the packer's output"))) (EApp (EApp (EVar "balPinErrors") (EVar "gs")) (EVar "ss"))) (EIf (EApp (EVar "not") (EFieldAccess (EVar "s") "fullCores")) (EApp (EApp (EVar "balPinErrors") (EVar "gs")) (EVar "ss")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "members") (EApp (EApp (EVar "balRowMembers") (EFieldAccess (EVar "s") "name")) (EVar "gs"))) (DoExpr (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "balPinMissing") (EFieldAccess (EVar "s") "name")) (EVar "gs")) (EFieldAccess (EVar "s") "pinned")) (EVar "members")) (EApp (EApp (EApp (EVar "balPinExtra") (EFieldAccess (EVar "s") "name")) (EFieldAccess (EVar "s") "pinned")) (EVar "members"))) (EApp (EApp (EVar "balPinErrors") (EVar "gs")) (EVar "ss"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balRowMembers" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balRowMembers" (PWild (PList)) (EListLit))
(DFunDef false "balRowMembers" ((PVar "n") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "n")) (EBinOp "::" (EFieldAccess (EVar "g") "name") (EApp (EApp (EVar "balRowMembers") (EVar "n")) (EVar "gs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "balRowMembers") (EVar "n")) (EVar "gs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPinMissing" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "balPinMissing" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "balPinMissing" ((PVar "n") (PVar "gs") (PCons (PVar "p") (PVar "ps")) (PVar "members")) (EIf (EApp (EApp (EVar "balElemStr") (EVar "p")) (EVar "members")) (EApp (EApp (EApp (EApp (EVar "balPinMissing") (EVar "n")) (EVar "gs")) (EVar "ps")) (EVar "members")) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "balPinPlace") (EVar "n")) (EVar "gs")) (EVar "p")) (EApp (EApp (EApp (EApp (EVar "balPinMissing") (EVar "n")) (EVar "gs")) (EVar "ps")) (EVar "members"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPinPlace" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "balPinPlace" ((PVar "n") (PVar "gs") (PVar "p")) (EMatch (EApp (EApp (EVar "balShardOfGate") (EVar "p")) (EVar "gs")) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "row '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "': pinned gate '"))) (EApp (EVar "display") (EVar "p"))) (ELit (LString "' is not in the registry at all")))) (arm (PCon "Some" (PVar "other")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "row '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "': pinned gate '"))) (EApp (EVar "display") (EVar "p"))) (ELit (LString "' is committed on row '"))) (EApp (EVar "display") (EVar "other"))) (ELit (LString "' instead"))))))
(DTypeSig false "balShardOfGate" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "balShardOfGate" (PWild (PList)) (EVar "None"))
(DFunDef false "balShardOfGate" ((PVar "n") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "name") (EVar "n")) (EApp (EVar "Some") (EFieldAccess (EVar "g") "shard")) (EIf (EVar "otherwise") (EApp (EApp (EVar "balShardOfGate") (EVar "n")) (EVar "gs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPinExtra" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "balPinExtra" (PWild PWild (PList)) (EListLit))
(DFunDef false "balPinExtra" ((PVar "n") (PVar "pinned") (PCons (PVar "m") (PVar "ms"))) (EIf (EApp (EApp (EVar "balElemStr") (EVar "m")) (EVar "pinned")) (EApp (EApp (EApp (EVar "balPinExtra") (EVar "n")) (EVar "pinned")) (EVar "ms")) (EIf (EVar "otherwise") (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "row '")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "': '"))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "' is committed on this closed row but is not in its pinned_gates"))) (EApp (EApp (EApp (EVar "balPinExtra") (EVar "n")) (EVar "pinned")) (EVar "ms"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balElemStr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "balElemStr" (PWild (PList)) (EVar "False"))
(DFunDef false "balElemStr" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "balElemStr") (EVar "x")) (EVar "ys")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOpenCands" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "List") (TyCon "Cand")))))
(DFunDef false "balOpenCands" ((PList) PWild) (EListLit))
(DFunDef false "balOpenCands" ((PCons (PVar "c") (PVar "cs")) (PVar "rs")) (EIf (EApp (EApp (EVar "balIsClosed") (EFieldAccess (EVar "c") "curRow")) (EVar "rs")) (EApp (EApp (EVar "balOpenCands") (EVar "cs")) (EVar "rs")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "c") (EApp (EApp (EVar "balOpenCands") (EVar "cs")) (EVar "rs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balTarget" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "List") (TyCon "Row"))))))))
(DFunDef false "balTarget" ((PVar "stab") (PVar "cs") (PVar "rows0")) (EBlock (DoLet false false (PVar "sorted") (EApp (EVar "balSortCands") (EVar "cs"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "balSeedClosed") (EVar "sorted")) (EVar "rows0")) (EListLit)) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PTuple (PVar "pinned") (PVar "rows1"))) () (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "placed") (PVar "rows2"))) (ETuple (EBinOp "++" (EVar "pinned") (EVar "placed")) (EVar "rows2")))) (EApp (EApp (EApp (EApp (EVar "balPlace") (EVar "stab")) (EApp (EVar "balSortCands") (EApp (EApp (EVar "balOpenCands") (EVar "sorted")) (EVar "rows0")))) (EVar "rows1")) (EListLit))))))))
(DTypeSig false "balCurrent" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyTuple (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "List") (TyCon "Row"))))))
(DFunDef false "balCurrent" ((PList) (PVar "rs")) (ETuple (EListLit) (EVar "rs")))
(DFunDef false "balCurrent" ((PCons (PVar "c") (PVar "cs")) (PVar "rs")) (EBlock (DoLet false false (PTuple (PVar "ps") (PVar "rs2")) (EApp (EApp (EVar "balCurrent") (EVar "cs")) (EApp (EApp (EApp (EVar "balAdd") (EFieldAccess (EVar "c") "curRow")) (EFieldAccess (EVar "c") "cms")) (EVar "rs")))) (DoExpr (ETuple (EBinOp "::" (ERecordCreate "Place" ((fa "pname" (EFieldAccess (EVar "c") "cname")) (fa "pfrom" (EFieldAccess (EVar "c") "curRow")) (fa "pto" (EFieldAccess (EVar "c") "curRow")))) (EVar "ps")) (EVar "rs2")))))
(DTypeSig false "balPole" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int")))
(DFunDef false "balPole" ((PList)) (ELit (LInt 0)))
(DFunDef false "balPole" ((PCons (PVar "r") (PVar "rs"))) (EApp (EApp (EVar "maxI") (EFieldAccess (EVar "r") "rload")) (EApp (EVar "balPole") (EVar "rs"))))
(DTypeSig false "balPoleRow" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "String")))
(DFunDef false "balPoleRow" ((PVar "rs")) (EApp (EApp (EApp (EVar "balPoleRowGo") (EVar "rs")) (ELit (LString ""))) (EUnOp "-" (ELit (LInt 1)))))
(DTypeSig false "balPoleRowGo" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "balPoleRowGo" ((PList) (PVar "n") PWild) (EVar "n"))
(DFunDef false "balPoleRowGo" ((PCons (PVar "r") (PVar "rs")) (PVar "n") (PVar "best")) (EIf (EBinOp ">" (EFieldAccess (EVar "r") "rload") (EVar "best")) (EApp (EApp (EApp (EVar "balPoleRowGo") (EVar "rs")) (EFieldAccess (EVar "r") "rname")) (EFieldAccess (EVar "r") "rload")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "balPoleRowGo") (EVar "rs")) (EVar "n")) (EVar "best")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balLoads" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "balLoads" ((PList)) (EListLit))
(DFunDef false "balLoads" ((PCons (PVar "r") (PVar "rs"))) (EBinOp "::" (EFieldAccess (EVar "r") "rload") (EApp (EVar "balLoads") (EVar "rs"))))
(DTypeSig false "balSortInts" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "balSortInts" ((PList)) (EListLit))
(DFunDef false "balSortInts" ((PCons (PVar "x") (PList))) (EBinOp "::" (EVar "x") (EListLit)))
(DFunDef false "balSortInts" ((PVar "xs")) (EBlock (DoLet false false (PTuple (PVar "l") (PVar "r")) (EApp (EApp (EApp (EVar "balHalveI") (EVar "xs")) (EListLit)) (EListLit))) (DoExpr (EApp (EApp (EVar "balMergeInts") (EApp (EVar "balSortInts") (EVar "l"))) (EApp (EVar "balSortInts") (EVar "r"))))))
(DTypeSig false "balHalveI" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "balHalveI" ((PList) (PVar "a") (PVar "b")) (ETuple (EVar "a") (EVar "b")))
(DFunDef false "balHalveI" ((PCons (PVar "x") (PVar "xs")) (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "balHalveI") (EVar "xs")) (EVar "b")) (EBinOp "::" (EVar "x") (EVar "a"))))
(DTypeSig false "balMergeInts" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "balMergeInts" ((PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "balMergeInts" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "balMergeInts" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "<=" (EVar "x") (EVar "y")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "balMergeInts") (EVar "xs")) (EBinOp "::" (EVar "y") (EVar "ys")))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "balMergeInts") (EBinOp "::" (EVar "x") (EVar "xs"))) (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balMedian" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int")))
(DFunDef false "balMedian" ((PVar "rs")) (EBlock (DoLet false false (PVar "v") (EApp (EVar "balSortInts") (EApp (EVar "balLoads") (EVar "rs")))) (DoLet false false (PVar "n") (EApp (EVar "listLen") (EVar "v"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (ELit (LInt 0)) (EIf (EBinOp "==" (EBinOp "%" (EVar "n") (ELit (LInt 2))) (ELit (LInt 1))) (EApp (EApp (EVar "balNth") (EBinOp "/" (EVar "n") (ELit (LInt 2)))) (EVar "v")) (EBinOp "/" (EBinOp "+" (EApp (EApp (EVar "balNth") (EBinOp "-" (EBinOp "/" (EVar "n") (ELit (LInt 2))) (ELit (LInt 1)))) (EVar "v")) (EApp (EApp (EVar "balNth") (EBinOp "/" (EVar "n") (ELit (LInt 2)))) (EVar "v"))) (ELit (LInt 2))))))))
(DTypeSig false "balNth" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int"))))
(DFunDef false "balNth" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "balNth" ((PVar "i") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "x") (EIf (EVar "otherwise") (EApp (EApp (EVar "balNth") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balFloorGateMs" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyCon "Int")))
(DFunDef false "balFloorGateMs" ((PVar "cs")) (EFieldAccess (EApp (EVar "balMaxCand") (EVar "cs")) "cms"))
(DTypeSig false "balFloorClosedMs" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int")))
(DFunDef false "balFloorClosedMs" ((PList)) (ELit (LInt 0)))
(DFunDef false "balFloorClosedMs" ((PCons (PVar "r") (PVar "rs"))) (EIf (EFieldAccess (EVar "r") "rclosed") (EApp (EApp (EVar "maxI") (EFieldAccess (EVar "r") "rload")) (EApp (EVar "balFloorClosedMs") (EVar "rs"))) (EIf (EVar "otherwise") (EApp (EVar "balFloorClosedMs") (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balFloorClosedRow" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "String")))
(DFunDef false "balFloorClosedRow" ((PVar "rs")) (EApp (EApp (EApp (EVar "balFloorClosedRowGo") (EVar "rs")) (ELit (LString ""))) (EUnOp "-" (ELit (LInt 1)))))
(DTypeSig false "balFloorClosedRowGo" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "balFloorClosedRowGo" ((PList) (PVar "n") PWild) (EVar "n"))
(DFunDef false "balFloorClosedRowGo" ((PCons (PVar "r") (PVar "rs")) (PVar "n") (PVar "best")) (EIf (EBinOp "&&" (EFieldAccess (EVar "r") "rclosed") (EBinOp ">" (EFieldAccess (EVar "r") "rload") (EVar "best"))) (EApp (EApp (EApp (EVar "balFloorClosedRowGo") (EVar "rs")) (EFieldAccess (EVar "r") "rname")) (EFieldAccess (EVar "r") "rload")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "balFloorClosedRowGo") (EVar "rs")) (EVar "n")) (EVar "best")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOpenWork" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int"))))
(DFunDef false "balOpenWork" ((PList) PWild) (ELit (LInt 0)))
(DFunDef false "balOpenWork" ((PCons (PVar "c") (PVar "cs")) (PVar "rs")) (EIf (EApp (EApp (EVar "balIsClosed") (EFieldAccess (EVar "c") "curRow")) (EVar "rs")) (EApp (EApp (EVar "balOpenWork") (EVar "cs")) (EVar "rs")) (EIf (EVar "otherwise") (EBinOp "+" (EFieldAccess (EVar "c") "cms") (EApp (EApp (EVar "balOpenWork") (EVar "cs")) (EVar "rs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOpenSlots" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int")))
(DFunDef false "balOpenSlots" ((PList)) (ELit (LInt 0)))
(DFunDef false "balOpenSlots" ((PCons (PVar "r") (PVar "rs"))) (EIf (EFieldAccess (EVar "r") "rclosed") (EApp (EVar "balOpenSlots") (EVar "rs")) (EIf (EVar "otherwise") (EBinOp "+" (EFieldAccess (EVar "r") "rjobs") (EApp (EVar "balOpenSlots") (EVar "rs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balFloorCapMs" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int"))))
(DFunDef false "balFloorCapMs" ((PVar "cs") (PVar "rs")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "balOpenSlots") (EVar "rs"))) (DoExpr (EIf (EBinOp "<=" (EVar "s") (ELit (LInt 0))) (ELit (LInt 0)) (EBinOp "/" (EApp (EApp (EVar "balOpenWork") (EVar "cs")) (EVar "rs")) (EVar "s"))))))
(DTypeSig false "balFloor" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int"))))
(DFunDef false "balFloor" ((PVar "cs") (PVar "rs")) (EApp (EApp (EVar "maxI") (EApp (EVar "balFloorGateMs") (EVar "cs"))) (EApp (EApp (EVar "maxI") (EApp (EVar "balFloorClosedMs") (EVar "rs"))) (EApp (EApp (EVar "balFloorCapMs") (EVar "cs")) (EVar "rs")))))
(DTypeSig false "balFloorIsGate" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool"))))
(DFunDef false "balFloorIsGate" ((PVar "cs") (PVar "rs")) (EBinOp ">=" (EApp (EVar "balFloorGateMs") (EVar "cs")) (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs"))))
(DTypeSig false "balFloorLine" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "String"))))
(DFunDef false "balFloorLine" ((PVar "cs") (PVar "rs")) (EIf (EBinOp "<=" (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs")) (ELit (LInt 0))) (ELit (LString "")) (EIf (EApp (EApp (EVar "balFloorIsGate") (EVar "cs")) (EVar "rs")) (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  floor: the achievable pole — set by '")) (EApp (EVar "display") (EFieldAccess (EApp (EVar "balMaxCand") (EVar "cs")) "cname"))) (ELit (LString "' alone ("))) (EApp (EVar "display") (EApp (EVar "balSecs") (EApp (EVar "balFloorGateMs") (EVar "cs"))))) (ELit (LString "), which is indivisible.\n"))) (ELit (LString "         Moving the FLOOR means that gate has to get FASTER (or be split).\n")))) (EIf (EBinOp ">=" (EApp (EVar "balFloorClosedMs") (EVar "rs")) (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  floor: the achievable pole — set by the closed row '")) (EApp (EVar "display") (EApp (EVar "balFloorClosedRow") (EVar "rs")))) (ELit (LString "' ("))) (EApp (EVar "display") (EApp (EVar "balSecs") (EApp (EVar "balFloorClosedMs") (EVar "rs"))))) (ELit (LString "), whose membership the packer cannot change.\n"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  floor: the achievable pole — set by ")) (EApp (EVar "display") (EApp (EVar "balSecs") (EApp (EApp (EVar "balOpenWork") (EVar "cs")) (EVar "rs"))))) (ELit (LString " of open work over "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "balOpenSlots") (EVar "rs"))))) (ELit (LString " open worker slots.\n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "balFactorMilli" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int"))))
(DFunDef false "balFactorMilli" ((PVar "cs") (PVar "rs")) (EBlock (DoLet false false (PVar "f") (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs"))) (DoExpr (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (ELit (LInt 0)) (EBinOp "/" (EBinOp "*" (EApp (EVar "balPole") (EVar "rs")) (ELit (LInt 1000))) (EVar "f"))))))
(DTypeSig false "balMaxCand" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyCon "Cand")))
(DFunDef false "balMaxCand" ((PList)) (ERecordCreate "Cand" ((fa "cname" (ELit (LString "(none)"))) (fa "crun" (ELit (LString ""))) (fa "curRow" (ELit (LString ""))) (fa "cms" (ELit (LInt 0))) (fa "needsWasm" (EVar "False")))))
(DFunDef false "balMaxCand" ((PCons (PVar "c") (PList))) (EVar "c"))
(DFunDef false "balMaxCand" ((PCons (PVar "c") (PVar "cs"))) (EBlock (DoLet false false (PVar "r") (EApp (EVar "balMaxCand") (EVar "cs"))) (DoExpr (EIf (EBinOp ">=" (EFieldAccess (EVar "c") "cms") (EFieldAccess (EVar "r") "cms")) (EVar "c") (EVar "r")))))
(DTypeSig false "balSecs" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "balSecs" ((PVar "ms")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "/" (EVar "ms") (ELit (LInt 1000)))))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "/" (EBinOp "%" (EVar "ms") (ELit (LInt 1000))) (ELit (LInt 100)))))) (ELit (LString "s"))))
(DTypeSig false "balTenth" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "balTenth" ((PVar "pm")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "/" (EVar "pm") (ELit (LInt 10)))))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "%" (EVar "pm") (ELit (LInt 10)))))) (ELit (LString "%"))))
(DTypeSig false "balPct1" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "balPct1" ((PVar "d") (PVar "base")) (EIf (EBinOp "<=" (EVar "base") (ELit (LInt 0))) (ELit (LString "n/a")) (EIf (EBinOp "<" (EVar "d") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (ELit (LString "-")) (EApp (EVar "display") (EApp (EVar "balTenth") (EBinOp "/" (EBinOp "*" (EBinOp "-" (ELit (LInt 0)) (EVar "d")) (ELit (LInt 1000))) (EVar "base"))))) (ELit (LString ""))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (ELit (LString "+")) (EApp (EVar "display") (EApp (EVar "balTenth") (EBinOp "/" (EBinOp "*" (EVar "d") (ELit (LInt 1000))) (EVar "base"))))) (ELit (LString ""))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balMilli" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "balMilli" ((PVar "m")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "/" (EVar "m") (ELit (LInt 1000)))))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "balPad3") (EBinOp "%" (EVar "m") (ELit (LInt 1000)))))) (ELit (LString ""))))
(DTypeSig false "balPad3" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "balPad3" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 10))) (EBinOp "++" (EBinOp "++" (ELit (LString "00")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 100))) (EBinOp "++" (EBinOp "++" (ELit (LString "0")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EIf (EVar "otherwise") (EApp (EVar "intToString") (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balPadR" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "balPadR" ((PVar "w") (PVar "s")) (EIf (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (EVar "w")) (EVar "s") (EIf (EVar "otherwise") (EApp (EApp (EVar "balPadR") (EVar "w")) (EBinOp "++" (EVar "s") (ELit (LString " ")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPadL" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "balPadL" ((PVar "w") (PVar "s")) (EIf (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (EVar "w")) (EVar "s") (EIf (EVar "otherwise") (EApp (EApp (EVar "balPadL") (EVar "w")) (EBinOp "++" (ELit (LString " ")) (EVar "s"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balDelta" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "balDelta" ((PVar "d")) (EIf (EBinOp "<" (EVar "d") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (ELit (LString "-")) (EApp (EVar "display") (EApp (EVar "balSecs") (EBinOp "-" (ELit (LInt 0)) (EVar "d"))))) (ELit (LString ""))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (ELit (LString "+")) (EApp (EVar "display") (EApp (EVar "balSecs") (EVar "d")))) (ELit (LString ""))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRowLines" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balRowLines" ((PList) PWild) (EListLit))
(DFunDef false "balRowLines" ((PCons (PVar "r") (PVar "rs")) (PVar "runs")) (EBlock (DoLet false false (PVar "tag") (EIf (EFieldAccess (EVar "r") "rclosed") (ELit (LString "  [closed: full_cores]")) (ELit (LString "")))) (DoLet false false (PVar "jt") (EIf (EApp (EApp (EVar "balJobsIsFallback") (EFieldAccess (EVar "r") "rname")) (EVar "runs")) (ELit (LString " jobs*")) (ELit (LString " jobs ")))) (DoExpr (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EVar "display") (EApp (EApp (EVar "balPadR") (ELit (LInt 10))) (EFieldAccess (EVar "r") "rname")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 4))) (EApp (EVar "intToString") (EFieldAccess (EVar "r") "rcount"))))) (ELit (LString " gates "))) (EApp (EVar "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balSecs") (EFieldAccess (EVar "r") "rload"))))) (ELit (LString "  "))) (EApp (EVar "display") (EVar "jt"))) (ELit (LString ""))) (EApp (EVar "display") (EApp (EVar "intToString") (EFieldAccess (EVar "r") "rjobs")))) (ELit (LString ""))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString ""))) (EApp (EApp (EVar "balRowLines") (EVar "rs")) (EVar "runs"))))))
(DTypeSig false "balCalibLines" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "balCalibLines" (PWild (PList) PWild) (EListLit))
(DFunDef false "balCalibLines" ((PVar "cs") (PCons (PVar "r") (PVar "rs")) (PVar "runs")) (EBinOp "::" (EApp (EApp (EApp (EVar "balCalibLine") (EVar "cs")) (EVar "r")) (EVar "runs")) (EApp (EApp (EApp (EVar "balCalibLines") (EVar "cs")) (EVar "rs")) (EVar "runs"))))
(DTypeSig false "balCalibStaleness" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "String"))))))
(DFunDef false "balCalibStaleness" (PWild (PCon "None") PWild PWild) (ELit (LString "")))
(DFunDef false "balCalibStaleness" ((PVar "cur") (PCon "Some" (PVar "recorded")) (PVar "curDig") (PVar "recDig")) (EIf (EBinOp "/=" (EVar "cur") (EVar "recorded")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " [STALE: ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "cur")))) (ELit (LString " gates now, "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "recorded")))) (ELit (LString " when recorded]"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "balCalibSetStaleness") (EVar "cur")) (EVar "curDig")) (EVar "recDig")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balCalibSetStaleness" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "balCalibSetStaleness" (PWild PWild (PCon "None")) (ELit (LString "")))
(DFunDef false "balCalibSetStaleness" ((PVar "n") (PVar "cur") (PCon "Some" (PVar "recorded"))) (EIf (EBinOp "==" (EVar "cur") (EVar "recorded")) (ELit (LString "")) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " [STALE: the same ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " gates by COUNT but a DIFFERENT SET (set digest "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "cur")))) (ELit (LString " now, "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "recorded")))) (ELit (LString " when recorded)]"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRowDigest" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyCon "Int"))))
(DFunDef false "balRowDigest" ((PVar "rn") (PVar "cs")) (EApp (EVar "gateSetDigest") (EApp (EApp (EVar "balRowKeys") (EVar "rn")) (EVar "cs"))))
(DTypeSig false "balRowKeys" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balRowKeys" (PWild (PList)) (EListLit))
(DFunDef false "balRowKeys" ((PVar "rn") (PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "c") "curRow") (EVar "rn")) (EBinOp "::" (EApp (EVar "baselineKey") (EFieldAccess (EVar "c") "crun")) (EApp (EApp (EVar "balRowKeys") (EVar "rn")) (EVar "cs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "balRowKeys") (EVar "rn")) (EVar "cs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balCalibLine" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyCon "Row") (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyCon "String")))))
(DFunDef false "balCalibLine" ((PVar "cands") (PVar "r") (PVar "runs")) (EMatch (EApp (EApp (EVar "latestRunForShard") (EFieldAccess (EVar "r") "rname")) (EVar "runs")) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EVar "display") (EApp (EApp (EVar "balPadR") (ELit (LInt 10))) (EFieldAccess (EVar "r") "rname")))) (ELit (LString " (no recorded run)")))) (arm (PCon "Some" (PVar "rr")) () (EMatch (EFieldAccess (EVar "rr") "rowElapsedMs") (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EVar "display") (EApp (EApp (EVar "balPadR") (ELit (LInt 10))) (EFieldAccess (EVar "r") "rname")))) (ELit (LString " (run "))) (EApp (EVar "display") (EFieldAccess (EVar "rr") "runId"))) (ELit (LString " recorded no rowElapsedMs)")))) (arm (PCon "Some" (PVar "e")) () (EBlock (DoLet false false (PVar "d") (EBinOp "-" (EVar "e") (EFieldAccess (EVar "r") "rload"))) (DoLet false false (PVar "pct") (EIf (EBinOp ">" (EFieldAccess (EVar "r") "rload") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EVar "display") (EApp (EVar "intToString") (EBinOp "/" (EBinOp "*" (EVar "d") (ELit (LInt 100))) (EFieldAccess (EVar "r") "rload"))))) (ELit (LString "%)"))) (ELit (LString "")))) (DoLet false false (PVar "stale") (EApp (EApp (EApp (EApp (EVar "balCalibStaleness") (EFieldAccess (EVar "r") "rcount")) (EFieldAccess (EVar "rr") "gates")) (EApp (EApp (EVar "balRowDigest") (EFieldAccess (EVar "r") "rname")) (EVar "cands"))) (EFieldAccess (EVar "rr") "gatesDigest"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EVar "display") (EApp (EApp (EVar "balPadR") (ELit (LInt 10))) (EFieldAccess (EVar "r") "rname")))) (ELit (LString " recorded "))) (EApp (EVar "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balSecs") (EVar "e"))))) (ELit (LString "   predicted "))) (EApp (EVar "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balSecs") (EFieldAccess (EVar "r") "rload"))))) (ELit (LString "   residual "))) (EApp (EVar "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balDelta") (EVar "d"))))) (ELit (LString ""))) (EApp (EVar "display") (EVar "pct"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "stale"))) (ELit (LString ""))))))))))
(DTypeSig false "balStabLine" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "String"))))))
(DFunDef false "balStabLine" ((PVar "cs") (PVar "rows0") (PVar "ps") (PVar "rows")) (EMatch (EApp (EApp (EApp (EVar "balTarget") (EVar "False")) (EVar "cs")) (EVar "rows0")) (arm (PCon "Err" PWild) () (ELit (LString "  stability: the unstabilized comparison packing could not be derived\n"))) (arm (PCon "Ok" (PTuple (PVar "lps") (PVar "lrows"))) () (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  stability: ")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EApp (EVar "balHeldCount") (EVar "ps")) (EVar "lps"))))) (ELit (LString " of "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "ps"))))) (ELit (LString " gates held on their committed row"))) (EBinOp "++" (EBinOp "++" (ELit (LString " (incumbent slack ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "balStabPct")))) (ELit (LString "% of a row's load)"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "; pole ")) (EApp (EVar "display") (EApp (EVar "balSecs") (EApp (EVar "balPole") (EVar "rows"))))) (ELit (LString " against "))) (EApp (EVar "display") (EApp (EVar "balSecs") (EApp (EVar "balPole") (EVar "lrows"))))) (ELit (LString " unstabilized"))) (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EVar "display") (EApp (EVar "balDelta") (EBinOp "-" (EApp (EVar "balPole") (EVar "rows")) (EApp (EVar "balPole") (EVar "lrows")))))) (ELit (LString "),"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " pole/floor ")) (EApp (EVar "display") (EApp (EVar "balMilli") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rows"))))) (ELit (LString " against "))) (EApp (EVar "display") (EApp (EVar "balMilli") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "lrows"))))) (ELit (LString "\n"))))))))
(DTypeSig false "balHeldCount" (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyCon "Int"))))
(DFunDef false "balHeldCount" ((PList) PWild) (ELit (LInt 0)))
(DFunDef false "balHeldCount" ((PCons (PVar "p") (PVar "ps")) (PVar "qs")) (EIf (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "p") "pto") (EFieldAccess (EVar "p") "pfrom")) (EBinOp "/=" (EApp (EApp (EVar "balPlaceOf") (EFieldAccess (EVar "p") "pname")) (EVar "qs")) (EFieldAccess (EVar "p") "pto"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EApp (EVar "balHeldCount") (EVar "ps")) (EVar "qs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "balHeldCount") (EVar "ps")) (EVar "qs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balMoved" (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyCon "Int")))
(DFunDef false "balMoved" ((PList)) (ELit (LInt 0)))
(DFunDef false "balMoved" ((PCons (PVar "p") (PVar "ps"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "p") "pfrom") (EFieldAccess (EVar "p") "pto")) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "balMoved") (EVar "ps"))) (EIf (EVar "otherwise") (EApp (EVar "balMoved") (EVar "ps")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balThinSamples" (TyCon "Int"))
(DFunDef false "balThinSamples" () (ELit (LInt 2)))
(DTypeSig false "balThinCount" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyCon "Int")))
(DFunDef false "balThinCount" ((PList)) (ELit (LInt 0)))
(DFunDef false "balThinCount" ((PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "<" (EFieldAccess (EVar "c") "samples") (EVar "balThinSamples")) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "balThinCount") (EVar "cs"))) (EIf (EVar "otherwise") (EApp (EVar "balThinCount") (EVar "cs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balThinLine" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyCon "String")))
(DFunDef false "balThinLine" ((PVar "base")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "balThinCount") (EVar "base"))))) (ELit (LString " of "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "base"))))) (ELit (LString " gates are scheduled off a single sample (samples < "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "balThinSamples")))) (ELit (LString ")\n"))))
(DTypeSig false "balOosBlock" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyCon "String")))))
(DFunDef false "balOosBlock" ((PVar "base") (PVar "cs") (PVar "runs")) (EBlock (DoLet false false (PVar "ids") (EApp (EApp (EVar "balRunIds") (EVar "runs")) (EListLit))) (DoLet false false (PVar "nr") (EApp (EVar "listLen") (EVar "ids"))) (DoExpr (EIf (EBinOp "<" (EVar "nr") (ELit (LInt 2))) (EBinOp "++" (EBinOp "++" (ELit (LString "  out-of-sample error of the packing statistic: not derivable (")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "nr")))) (ELit (LString " recorded run(s); predicting one run from the others needs at least two)\n"))) (EBlock (DoLet false false (PVar "vs") (EApp (EApp (EApp (EVar "balOosVecs") (EVar "base")) (EVar "cs")) (EVar "ids"))) (DoLet false false (PVar "ne") (EApp (EVar "listLen") (EVar "vs"))) (DoExpr (EIf (EBinOp "==" (EVar "ne") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  out-of-sample error of the packing statistic: not derivable — ")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EApp (EVar "balAttrKnown") (EVar "base")) (EVar "cs"))))) (ELit (LString " of "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EApp (EVar "balAttrTotal") (EVar "base")) (EVar "cs"))))) (ELit (LString " retained samples carry run attribution, and no schedulable gate carries an exactly attributed sample from each of the "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "nr")))) (ELit (LString " recorded runs\n"))) (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  out-of-sample error of the packing statistic (leave-one-run-out over the ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "nr")))) (ELit (LString " runs in runs[], across the "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "ne")))) (ELit (LString " of "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "cs"))))) (ELit (LString " schedulable gates carrying a run-attributed sample from every run):\n"))) (EApp (EVar "joinNl") (EApp (EApp (EApp (EApp (EVar "balOosFolds") (EVar "vs")) (EVar "ids")) (ELit (LInt 0))) (EVar "nr"))) (ELit (LString "\n")) (EApp (EApp (EVar "balOosSummary") (EVar "vs")) (EVar "nr")) (EApp (EVar "balOosDriftLine") (EVar "base")))))))))))
(DTypeSig false "balOosFolds" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "balOosFolds" ((PVar "vs") (PVar "ids") (PVar "i") (PVar "nr")) (EIf (EBinOp ">=" (EVar "i") (EVar "nr")) (EListLit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "p") (EApp (EApp (EVar "balOosPred") (EVar "vs")) (EVar "i"))) (DoLet false false (PVar "a") (EApp (EApp (EVar "balOosAct") (EVar "vs")) (EVar "i"))) (DoExpr (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    run ")) (EApp (EVar "display") (EApp (EApp (EVar "balPadR") (ELit (LInt 13))) (EApp (EApp (EVar "balNthStr") (EVar "i")) (EVar "ids"))))) (ELit (LString " predicted "))) (EApp (EVar "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balSecs") (EVar "p"))))) (ELit (LString "   actual "))) (EApp (EVar "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balSecs") (EVar "a"))))) (ELit (LString "   "))) (EApp (EVar "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 7))) (EApp (EApp (EVar "balPct1") (EBinOp "-" (EVar "p") (EVar "a"))) (EVar "a"))))) (ELit (LString ""))) (EApp (EApp (EApp (EApp (EVar "balOosFolds") (EVar "vs")) (EVar "ids")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "nr"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOosSummary" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "balOosSummary" ((PVar "vs") (PVar "nr")) (EBlock (DoLet false false (PVar "p") (EApp (EApp (EApp (EVar "balOosPredAll") (EVar "vs")) (ELit (LInt 0))) (EVar "nr"))) (DoLet false false (PVar "a") (EApp (EApp (EApp (EVar "balOosActAll") (EVar "vs")) (ELit (LInt 0))) (EVar "nr"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    mean |error| ")) (EApp (EVar "display") (EApp (EVar "balTenth") (EBinOp "/" (EApp (EApp (EApp (EApp (EVar "balOosAbsPm") (EVar "vs")) (ELit (LInt 0))) (EVar "nr")) (ELit (LInt 0))) (EVar "nr"))))) (ELit (LString "   systematic bias "))) (EApp (EVar "display") (EApp (EApp (EVar "balPct1") (EBinOp "-" (EVar "p") (EVar "a"))) (EVar "a")))) (ELit (LString " (the median is the low-side robust choice — see gate_cost.packStat)\n"))))))
(DTypeSig false "balOosDriftLine" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyCon "String")))
(DFunDef false "balOosDriftLine" ((PVar "base")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "balStatDrift") (EVar "base"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString "    WARNING: ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " baseline row(s) carry a medianMs that the packing statistic does not reproduce — the ingester and gate_cost.packStat have drifted; re-ingest before trusting a placement\n")))))))
(DTypeSig false "balStatDrift" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyCon "Int")))
(DFunDef false "balStatDrift" ((PList)) (ELit (LInt 0)))
(DFunDef false "balStatDrift" ((PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "==" (EApp (EVar "packStat") (EFieldAccess (EVar "c") "ms")) (EFieldAccess (EVar "c") "medianMs")) (EApp (EVar "balStatDrift") (EVar "cs")) (EIf (EVar "otherwise") (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "balStatDrift") (EVar "cs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOosVecs" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "balOosVecs" (PWild (PList) PWild) (EListLit))
(DFunDef false "balOosVecs" ((PVar "base") (PCons (PVar "c") (PVar "cs")) (PVar "ids")) (EMatch (EApp (EApp (EVar "costRowOf") (EFieldAccess (EVar "c") "crun")) (EVar "base")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "balOosVecs") (EVar "base")) (EVar "cs")) (EVar "ids"))) (arm (PCon "Some" (PVar "g")) () (EMatch (EApp (EApp (EVar "balOosVecFor") (EVar "g")) (EVar "ids")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "balOosVecs") (EVar "base")) (EVar "cs")) (EVar "ids"))) (arm (PCon "Some" (PVar "v")) () (EBinOp "::" (EVar "v") (EApp (EApp (EApp (EVar "balOosVecs") (EVar "base")) (EVar "cs")) (EVar "ids"))))))))
(DTypeSig false "balOosVecFor" (TyFun (TyCon "GateCost") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "balOosVecFor" (PWild (PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "balOosVecFor" ((PVar "g") (PCons (PVar "r") (PVar "rs"))) (EMatch (EApp (EApp (EApp (EApp (EVar "balSampleForRun") (EVar "r")) (EFieldAccess (EVar "g") "ms")) (EFieldAccess (EVar "g") "sampleRuns")) (EVar "None")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "v")) () (EApp (EApp (EVar "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "v") (EVar "_s")))) (EApp (EApp (EVar "balOosVecFor") (EVar "g")) (EVar "rs"))))))
(DTypeSig false "balSampleForRun" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "balSampleForRun" (PWild (PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "balSampleForRun" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "balSampleForRun" ((PVar "r") (PCons (PVar "m") (PVar "ms")) (PCons (PVar "s") (PVar "ss")) (PVar "acc")) (EIf (EBinOp "/=" (EVar "s") (EVar "r")) (EApp (EApp (EApp (EApp (EVar "balSampleForRun") (EVar "r")) (EVar "ms")) (EVar "ss")) (EVar "acc")) (EIf (EVar "otherwise") (EMatch (EVar "acc") (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "balSampleForRun") (EVar "r")) (EVar "ms")) (EVar "ss")) (EApp (EVar "Some") (EVar "m")))) (arm (PCon "Some" PWild) () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balAttrKnown" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyCon "Int"))))
(DFunDef false "balAttrKnown" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "balAttrKnown" ((PVar "base") (PCons (PVar "c") (PVar "cs"))) (EMatch (EApp (EApp (EVar "costRowOf") (EFieldAccess (EVar "c") "crun")) (EVar "base")) (arm (PCon "None") () (EApp (EApp (EVar "balAttrKnown") (EVar "base")) (EVar "cs"))) (arm (PCon "Some" (PVar "g")) () (EBinOp "+" (EApp (EVar "balCountAttr") (EFieldAccess (EVar "g") "sampleRuns")) (EApp (EApp (EVar "balAttrKnown") (EVar "base")) (EVar "cs"))))))
(DTypeSig false "balCountAttr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))
(DFunDef false "balCountAttr" ((PList)) (ELit (LInt 0)))
(DFunDef false "balCountAttr" ((PCons (PVar "s") (PVar "ss"))) (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EApp (EVar "balCountAttr") (EVar "ss")) (EIf (EVar "otherwise") (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "balCountAttr") (EVar "ss"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balAttrTotal" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyCon "Int"))))
(DFunDef false "balAttrTotal" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "balAttrTotal" ((PVar "base") (PCons (PVar "c") (PVar "cs"))) (EMatch (EApp (EApp (EVar "costRowOf") (EFieldAccess (EVar "c") "crun")) (EVar "base")) (arm (PCon "None") () (EApp (EApp (EVar "balAttrTotal") (EVar "base")) (EVar "cs"))) (arm (PCon "Some" (PVar "g")) () (EBinOp "+" (EApp (EVar "listLen") (EFieldAccess (EVar "g") "ms")) (EApp (EApp (EVar "balAttrTotal") (EVar "base")) (EVar "cs"))))))
(DTypeSig false "balOosPred" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "balOosPred" ((PList) PWild) (ELit (LInt 0)))
(DFunDef false "balOosPred" ((PCons (PVar "v") (PVar "vs")) (PVar "i")) (EBinOp "+" (EApp (EVar "packStat") (EApp (EApp (EVar "balDropNth") (EVar "i")) (EVar "v"))) (EApp (EApp (EVar "balOosPred") (EVar "vs")) (EVar "i"))))
(DTypeSig false "balOosAct" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "balOosAct" ((PList) PWild) (ELit (LInt 0)))
(DFunDef false "balOosAct" ((PCons (PVar "v") (PVar "vs")) (PVar "i")) (EBinOp "+" (EApp (EApp (EVar "balNth") (EVar "i")) (EVar "v")) (EApp (EApp (EVar "balOosAct") (EVar "vs")) (EVar "i"))))
(DTypeSig false "balOosPredAll" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "balOosPredAll" ((PVar "vs") (PVar "i") (PVar "nr")) (EIf (EBinOp ">=" (EVar "i") (EVar "nr")) (ELit (LInt 0)) (EIf (EVar "otherwise") (EBinOp "+" (EApp (EApp (EVar "balOosPred") (EVar "vs")) (EVar "i")) (EApp (EApp (EApp (EVar "balOosPredAll") (EVar "vs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "nr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOosActAll" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "balOosActAll" ((PVar "vs") (PVar "i") (PVar "nr")) (EIf (EBinOp ">=" (EVar "i") (EVar "nr")) (ELit (LInt 0)) (EIf (EVar "otherwise") (EBinOp "+" (EApp (EApp (EVar "balOosAct") (EVar "vs")) (EVar "i")) (EApp (EApp (EApp (EVar "balOosActAll") (EVar "vs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "nr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOosAbsPm" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "balOosAbsPm" ((PVar "vs") (PVar "i") (PVar "nr") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "nr")) (EVar "acc") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "p") (EApp (EApp (EVar "balOosPred") (EVar "vs")) (EVar "i"))) (DoLet false false (PVar "a") (EApp (EApp (EVar "balOosAct") (EVar "vs")) (EVar "i"))) (DoLet false false (PVar "d") (EIf (EBinOp ">=" (EVar "p") (EVar "a")) (EBinOp "-" (EVar "p") (EVar "a")) (EBinOp "-" (EVar "a") (EVar "p")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "balOosAbsPm") (EVar "vs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "nr")) (EBinOp "+" (EVar "acc") (EIf (EBinOp ">" (EVar "a") (ELit (LInt 0))) (EBinOp "/" (EBinOp "*" (EVar "d") (ELit (LInt 1000))) (EVar "a")) (ELit (LInt 0))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balDropNth" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "balDropNth" (PWild (PList)) (EListLit))
(DFunDef false "balDropNth" ((PVar "i") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "xs") (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EApp (EVar "balDropNth") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "xs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRunIds" (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balRunIds" ((PList) (PVar "acc")) (EApp (EApp (EVar "balRevStrs") (EVar "acc")) (EListLit)))
(DFunDef false "balRunIds" ((PCons (PVar "r") (PVar "rs")) (PVar "acc")) (EIf (EApp (EApp (EVar "balHasStr") (EFieldAccess (EVar "r") "runId")) (EVar "acc")) (EApp (EApp (EVar "balRunIds") (EVar "rs")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EVar "balRunIds") (EVar "rs")) (EBinOp "::" (EFieldAccess (EVar "r") "runId") (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balHasStr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "balHasStr" (PWild (PList)) (EVar "False"))
(DFunDef false "balHasStr" ((PVar "s") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "==" (EVar "x") (EVar "s")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "balHasStr") (EVar "s")) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRevStrs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balRevStrs" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "balRevStrs" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "balRevStrs") (EVar "xs")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DTypeSig false "balNthStr" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "balNthStr" (PWild (PList)) (ELit (LString "")))
(DFunDef false "balNthStr" ((PVar "i") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "x") (EIf (EVar "otherwise") (EApp (EApp (EVar "balNthStr") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balReport" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyCon "String")))))))
(DFunDef false "balReport" ((PVar "label") (PVar "cs") (PVar "rs") (PVar "ps") (PVar "runs")) (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EVar "label"))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "cs"))))) (ELit (LString " schedulable gates over "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "rs"))))) (ELit (LString " rows\n"))) (ELit (LString "  predicted row wall clock (makespan of the per-gate baseline medians over the row's recorded workers; * = borrowed/defaulted worker count):\n")) (EApp (EVar "joinNl") (EApp (EApp (EVar "balRowLines") (EVar "rs")) (EVar "runs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n  pole ")) (EApp (EVar "display") (EApp (EVar "balSecs") (EApp (EVar "balPole") (EVar "rs"))))) (ELit (LString " ("))) (EApp (EVar "display") (EApp (EVar "balPoleRow") (EVar "rs")))) (ELit (LString ")   median "))) (EApp (EVar "display") (EApp (EVar "balSecs") (EApp (EVar "balMedian") (EVar "rs"))))) (ELit (LString "   floor "))) (EApp (EVar "display") (EApp (EVar "balSecs") (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs"))))) (ELit (LString "   pole/floor "))) (EApp (EVar "display") (EApp (EVar "balMilli") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rs"))))) (ELit (LString "\n"))) (EApp (EApp (EVar "balFloorLine") (EVar "cs")) (EVar "rs")) (EBinOp "++" (EBinOp "++" (ELit (LString "  gates whose row changes: ")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "balMoved") (EVar "ps"))))) (ELit (LString "\n"))))))
(DTypeSig false "balCurrentLegal" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool"))))
(DFunDef false "balCurrentLegal" ((PList) PWild) (EVar "True"))
(DFunDef false "balCurrentLegal" ((PCons (PVar "c") (PVar "cs")) (PVar "rs")) (EIf (EBinOp "&&" (EFieldAccess (EVar "c") "needsWasm") (EApp (EVar "not") (EApp (EApp (EVar "balRowIsWasm") (EFieldAccess (EVar "c") "curRow")) (EVar "rs")))) (EVar "False") (EIf (EVar "otherwise") (EApp (EApp (EVar "balCurrentLegal") (EVar "cs")) (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balBandNote" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "String")))))
(DFunDef false "balBandNote" ((PCon "True") PWild PWild) (ELit (LString " — OVERRIDDEN (illegal assignment)")))
(DFunDef false "balBandNote" (PWild (PCon "True") PWild) (ELit (LString " — TAKEN")))
(DFunDef false "balBandNote" (PWild PWild (PCon "True")) (ELit (LString " — OVERRIDDEN (the committed assignment is not the derived one)")))
(DFunDef false "balBandNote" (PWild PWild PWild) (ELit (LString " — not reached (the committed assignment already IS the derived one)")))
(DTypeSig false "balFirstMove" (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "Option") (TyCon "Place"))))
(DFunDef false "balFirstMove" ((PList)) (EVar "None"))
(DFunDef false "balFirstMove" ((PCons (PVar "p") (PVar "ps"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "p") "pfrom") (EFieldAccess (EVar "p") "pto")) (EApp (EVar "Some") (EVar "p")) (EIf (EVar "otherwise") (EApp (EVar "balFirstMove") (EVar "ps")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balMoveLine" (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyCon "String")))
(DFunDef false "balMoveLine" ((PVar "ps")) (EMatch (EApp (EVar "balFirstMove") (EVar "ps")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PVar "p")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  first divergence: '")) (EApp (EVar "display") (EFieldAccess (EVar "p") "pname"))) (ELit (LString "' is committed on row '"))) (EApp (EVar "display") (EFieldAccess (EVar "p") "pfrom"))) (ELit (LString "' but derives to '"))) (EApp (EVar "display") (EFieldAccess (EVar "p") "pto"))) (ELit (LString "'.\n"))))))
(DTypeSig false "balEnforce" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "balEnforce" ((PVar "cs") (PVar "rs")) (EIf (EBinOp "<=" (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rs")) (EVar "balTargetMilli")) (EVar "None") (EIf (EApp (EApp (EVar "balFloorIsGate") (EVar "cs")) (EVar "rs")) (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka gate balance: the emitted assignment misses the pole/floor budget of ")) (EApp (EVar "balMilli") (EVar "balTargetMilli")) (ELit (LString " (it is ")) (EApp (EVar "balMilli") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rs"))) (ELit (LString ").\n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  The floor is '")) (EApp (EVar "display") (EFieldAccess (EApp (EVar "balMaxCand") (EVar "cs")) "cname"))) (ELit (LString "' alone, at "))) (EApp (EVar "display") (EApp (EVar "balSecs") (EFieldAccess (EApp (EVar "balMaxCand") (EVar "cs")) "cms")))) (ELit (LString ", against a pole of "))) (EApp (EVar "display") (EApp (EVar "balSecs") (EApp (EVar "balPole") (EVar "rs"))))) (ELit (LString ".\n"))) (ELit (LString "  Gates are indivisible, so the pole can never go below the most expensive\n")) (ELit (LString "  gate, and the rest of this gap is what would not fit around it.  This is\n")) (ELit (LString "  a gate that has to get FASTER (or be split); repacking cannot move the\n")) (ELit (LString "  floor while it stands.\n"))))) (EIf (EVar "otherwise") (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka gate balance: the emitted assignment misses the pole/floor budget of ")) (EApp (EVar "balMilli") (EVar "balTargetMilli")) (ELit (LString " (it is ")) (EApp (EVar "balMilli") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rs"))) (ELit (LString ").\n")) (EBinOp "++" (EBinOp "++" (ELit (LString "  No single gate explains it — the floor is ")) (EApp (EVar "display") (EApp (EVar "balSecs") (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs"))))) (ELit (LString " and no gate costs that\n"))) (ELit (LString "  much — so this is the packing: rows within budget exist and the heuristic\n")) (ELit (LString "  did not find them.\n"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balShardValues" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balShardValues" ((PList) PWild) (EListLit))
(DFunDef false "balShardValues" ((PCons (PVar "g") (PVar "gs")) (PVar "ps")) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EBinOp "::" (EVar "balOtherJob") (EApp (EApp (EVar "balShardValues") (EVar "gs")) (EVar "ps"))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "balPlaceOf") (EFieldAccess (EVar "g") "name")) (EVar "ps")) (EApp (EApp (EVar "balShardValues") (EVar "gs")) (EVar "ps"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPlaceOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyCon "String"))))
(DFunDef false "balPlaceOf" ((PVar "n") (PList)) (EVar "n"))
(DFunDef false "balPlaceOf" ((PVar "n") (PCons (PVar "p") (PVar "ps"))) (EIf (EBinOp "==" (EFieldAccess (EVar "p") "pname") (EVar "n")) (EFieldAccess (EVar "p") "pto") (EIf (EVar "otherwise") (EApp (EApp (EVar "balPlaceOf") (EVar "n")) (EVar "ps")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balSplice" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "balSplice" ((PVar "vals") (PVar "src")) (EApp (EApp (EApp (EApp (EVar "balSpliceGo") (EVar "vals")) (EVar "src")) (EVar "False")) (EListLit)))
(DTypeSig false "balSpliceGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "balSpliceGo" ((PList) (PList) PWild (PVar "acc")) (EApp (EVar "Ok") (EApp (EVar "reverseL") (EVar "acc"))))
(DFunDef false "balSpliceGo" ((PVar "vs") (PList) PWild PWild) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: test/gates.toml has fewer [[gate]] shard lines than entries (")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "vs"))))) (ELit (LString " unplaced)")))))
(DFunDef false "balSpliceGo" ((PVar "vs") (PCons (PVar "l") (PVar "ls")) (PVar "inGate") (PVar "acc")) (EIf (EBinOp "==" (EVar "l") (ELit (LString "[[gate]]"))) (EApp (EApp (EApp (EApp (EVar "balSpliceGo") (EVar "vs")) (EVar "ls")) (EVar "True")) (EBinOp "::" (EVar "l") (EVar "acc"))) (EIf (EBinOp "==" (EVar "l") (ELit (LString "[[shard]]"))) (EApp (EApp (EApp (EApp (EVar "balSpliceGo") (EVar "vs")) (EVar "ls")) (EVar "False")) (EBinOp "::" (EVar "l") (EVar "acc"))) (EIf (EBinOp "&&" (EVar "inGate") (EApp (EApp (EVar "startsWith") (ELit (LString "shard = \""))) (EVar "l"))) (EMatch (EVar "vs") (arm (PList) () (EApp (EVar "Err") (ELit (LString "medaka gate balance: test/gates.toml has more [[gate]] shard lines than entries")))) (arm (PCons (PVar "v") (PVar "rest")) () (EApp (EApp (EApp (EApp (EVar "balSpliceGo") (EVar "rest")) (EVar "ls")) (EVar "inGate")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "shard = \"")) (EApp (EVar "display") (EVar "v"))) (ELit (LString "\""))) (EVar "acc"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "balSpliceGo") (EVar "vs")) (EVar "ls")) (EVar "inGate")) (EBinOp "::" (EVar "l") (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig true "balNewText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "balNewText" ((PVar "regPath") (PVar "regSrc") (PVar "baseSrc")) (EMatch (EApp (EVar "parseRegistry") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "gates")) () (EMatch (EApp (EVar "parseShards") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "shs")) () (EMatch (EApp (EVar "parseCostBaseline") (EVar "baseSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "base")) () (EMatch (EApp (EVar "parseCostRuns") (EVar "baseSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "runsRead")) () (EMatch (EApp (EApp (EVar "balUnknownRows") (EVar "shs")) (EVar "gates")) (arm (PCons (PVar "b") (PVar "bs")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EVar "display") (EVar "regPath"))) (ELit (LString ": gate(s) name a shard with no [[shard]] row: "))) (EApp (EVar "display") (EApp (EVar "joinSpace") (EBinOp "::" (EVar "b") (EVar "bs"))))) (ELit (LString ""))))) (arm (PList) () (EMatch (EApp (EApp (EVar "balUncosted") (EVar "base")) (EVar "gates")) (arm (PCons (PVar "u") (PVar "us")) () (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EBinOp "::" (EVar "u") (EVar "us")))))) (ELit (LString " schedulable gate(s) have no row in the cost baseline:\n"))) (EApp (EVar "joinNl") (EApp (EVar "balIndent") (EBinOp "::" (EVar "u") (EVar "us")))) (ELit (LString "\n  Refusing to pack: a missing cost is not a cheap gate, it is an\n")) (ELit (LString "  unknown one, and treating it as 0 would pile it onto the lightest row.\n")) (ELit (LString "  Re-ingest the baseline (test/gate_cost_ingest.sh) or fix the gate's `run`.\n")))))) (arm (PList) () (EMatch (EApp (EApp (EVar "balPinErrors") (EVar "gates")) (EVar "shs")) (arm (PCons (PVar "e") (PVar "es")) () (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EVar "display") (EVar "regPath"))) (ELit (LString ": a closed row's membership does not match its declared `pinned_gates`:\n"))) (EApp (EVar "joinNl") (EApp (EVar "balIndent") (EBinOp "::" (EVar "e") (EVar "es")))) (ELit (LString "\n  A `full_cores` row is CLOSED: the packer moves nothing onto it and\n")) (ELit (LString "  nothing off it, so its members are the one `shard` value no cost\n")) (ELit (LString "  measurement derives.  They are DECLARED in that [[shard]] row's\n")) (ELit (LString "  `pinned_gates` and checked against the registry in both directions,\n")) (ELit (LString "  so a hand-moved `shard` cannot be adopted as the new pin.\n")) (ELit (LString "  Repair the gate's `shard`; change `pinned_gates` only when the row's\n")) (ELit (LString "  membership is genuinely meant to differ, and say why in its rationale\n")) (ELit (LString "  file (docs/ops/GATE-REGISTRY-DESIGN.md §2).\n")))))) (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "balCompute") (EVar "regPath")) (EVar "gates")) (EVar "shs")) (EVar "base")) (EVar "runsRead")) (EVar "regSrc")))))))))))))))))
(DTypeSig false "balIndent" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "balIndent" ((PList)) (EListLit))
(DFunDef false "balIndent" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EVar "display") (EVar "x"))) (ELit (LString ""))) (EApp (EVar "balIndent") (EVar "xs"))))
(DTypeSig false "balCompute" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "String"))))))))))
(DFunDef false "balCompute" ((PVar "regPath") (PVar "gates") (PVar "shs") (PVar "base") (PVar "runs") (PVar "regSrc")) (EBlock (DoLet false false (PVar "cs") (EApp (EApp (EVar "balCands") (EVar "base")) (EVar "gates"))) (DoLet false false (PTuple PWild (PVar "curRows")) (EApp (EApp (EVar "balCurrent") (EApp (EVar "balSortCands") (EVar "cs"))) (EApp (EApp (EVar "balRows") (EVar "runs")) (EVar "shs")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "balTarget") (EVar "True")) (EVar "cs")) (EApp (EApp (EVar "balRows") (EVar "runs")) (EVar "shs"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PTuple (PVar "ps") (PVar "rows"))) () (EBlock (DoLet false false (PVar "illegal") (EApp (EVar "not") (EApp (EApp (EVar "balCurrentLegal") (EVar "cs")) (EVar "curRows")))) (DoLet false false (PVar "gains") (EBinOp "<" (EBinOp "*" (EApp (EVar "balPole") (EVar "rows")) (ELit (LInt 100))) (EBinOp "*" (EApp (EVar "balPole") (EVar "curRows")) (EBinOp "-" (ELit (LInt 100)) (EVar "balMarginPct"))))) (DoLet false false (PVar "moved") (EBinOp ">" (EApp (EVar "balMoved") (EVar "ps")) (ELit (LInt 0)))) (DoLet false false (PVar "label") (EIf (EVar "illegal") (ELit (LString "rebalanced (the committed assignment ran a gate on a row lacking its toolchain)")) (EIf (EVar "moved") (ELit (LString "rebalanced")) (ELit (LString "unchanged (the committed assignment is already the derived one)"))))) (DoLet false false (PVar "head") (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EVar "display") (EVar "regPath"))) (ELit (LString "\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "balReport") (EVar "label")) (EVar "cs")) (EVar "rows")) (EVar "ps")) (EVar "runs")) (EApp (EVar "balThinLine") (EVar "base")) (EApp (EApp (EApp (EVar "balOosBlock") (EVar "base")) (EVar "cs")) (EVar "runs")) (EApp (EApp (EApp (EApp (EVar "balStabLine") (EVar "cs")) (EApp (EApp (EVar "balRows") (EVar "runs")) (EVar "shs"))) (EVar "ps")) (EVar "rows")) (EBinOp "++" (EBinOp "++" (ELit (LString "  hysteresis: a move needs a pole gain of more than ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "balMarginPct")))) (ELit (LString "%"))) (EApp (EApp (EApp (EVar "balBandNote") (EVar "illegal")) (EVar "gains")) (EVar "moved")) (EBinOp "++" (EBinOp "++" (ELit (LString "\n  budget pole/floor ")) (EApp (EVar "display") (EApp (EVar "balMilli") (EVar "balTargetMilli")))) (ELit (LString ""))) (EIf (EBinOp "<=" (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rows")) (EVar "balTargetMilli")) (ELit (LString " — MET\n")) (ELit (LString " — MISSED\n"))) (EApp (EVar "balMoveLine") (EVar "ps")) (ELit (LString "  calibration — last recorded CI wall clock vs this model's prediction for the COMMITTED assignment:\n")) (EApp (EVar "joinNl") (EApp (EApp (EApp (EVar "balCalibLines") (EVar "cs")) (EVar "curRows")) (EVar "runs"))) (ELit (LString "\n"))))) (DoExpr (EMatch (EApp (EApp (EVar "balEnforce") (EVar "cs")) (EVar "rows")) (arm (PCon "Some" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "head"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "balSplice") (EApp (EApp (EVar "balShardValues") (EVar "gates")) (EVar "ps"))) (EApp (EVar "splitNl") (EVar "regSrc"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "head"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "outLines")) () (EApp (EVar "Ok") (ETuple (EVar "head") (EApp (EVar "joinNl") (EVar "outLines")))))))))))))))
(DTypeSig false "budgetOverridePrefix" (TyCon "String"))
(DFunDef false "budgetOverridePrefix" () (ELit (LString "Gate-Budget-Override: ")))
(DTypeSig false "budgetOverrideTokens" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "budgetOverrideTokens" ((PVar "msg")) (EApp (EVar "budgetTokensFromLines") (EApp (EVar "splitNl") (EVar "msg"))))
(DTypeSig false "budgetTokensFromLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "budgetTokensFromLines" ((PList)) (EListLit))
(DFunDef false "budgetTokensFromLines" ((PCons (PVar "l") (PVar "ls"))) (EIf (EApp (EApp (EVar "startsWith") (EVar "budgetOverridePrefix")) (EApp (EVar "stringTrim") (EVar "l"))) (EBinOp "::" (EApp (EVar "budgetFirstWord") (EApp (EVar "stringTrim") (EApp (EApp (EVar "budgetDropPrefix") (EVar "budgetOverridePrefix")) (EApp (EVar "stringTrim") (EVar "l"))))) (EApp (EVar "budgetTokensFromLines") (EVar "ls"))) (EIf (EVar "otherwise") (EApp (EVar "budgetTokensFromLines") (EVar "ls")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "budgetDropPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "budgetDropPrefix" ((PVar "pre") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "pre"))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))
(DTypeSig false "budgetFirstWord" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "budgetFirstWord" ((PVar "s")) (EMatch (EApp (EApp (EVar "splitOnChar") (ELit (LChar " "))) (EVar "s")) (arm (PList) () (EVar "s")) (arm (PCons (PVar "w") PWild) () (EVar "w"))))
(DTypeSig false "budgetAcked" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "budgetAcked" ((PVar "commitMessage") (PVar "token")) (EApp (EApp (EVar "contains") (EVar "token")) (EApp (EVar "budgetOverrideTokens") (EVar "commitMessage"))))
(DTypeSig false "budgetCountUnacked" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int"))))
(DFunDef false "budgetCountUnacked" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "budgetCountUnacked" ((PVar "commitMessage") (PCons (PVar "t") (PVar "ts"))) (EIf (EApp (EApp (EVar "budgetAcked") (EVar "commitMessage")) (EVar "t")) (EApp (EApp (EVar "budgetCountUnacked") (EVar "commitMessage")) (EVar "ts")) (EIf (EVar "otherwise") (EBinOp "+" (ELit (LInt 1)) (EApp (EApp (EVar "budgetCountUnacked") (EVar "commitMessage")) (EVar "ts"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "budgetUncostedNames" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "budgetUncostedNames" (PWild (PList)) (EListLit))
(DFunDef false "budgetUncostedNames" ((PVar "base") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EApp (EApp (EVar "budgetUncostedNames") (EVar "base")) (EVar "gs")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "costOf") (EFieldAccess (EVar "g") "run")) (EVar "base")) (arm (PCon "Some" PWild) () (EApp (EApp (EVar "budgetUncostedNames") (EVar "base")) (EVar "gs"))) (arm (PCon "None") () (EBinOp "::" (EFieldAccess (EVar "g") "name") (EApp (EApp (EVar "budgetUncostedNames") (EVar "base")) (EVar "gs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "budgetUncostedTokens" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "budgetUncostedTokens" ((PList)) (EListLit))
(DFunDef false "budgetUncostedTokens" ((PCons (PVar "n") (PVar "ns"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "uncosted:")) (EApp (EVar "display") (EVar "n"))) (ELit (LString ""))) (EApp (EVar "budgetUncostedTokens") (EVar "ns"))))
(DTypeSig false "budgetUncostedLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "budgetUncostedLines" (PWild (PList)) (EListLit))
(DFunDef false "budgetUncostedLines" ((PVar "commitMessage") (PCons (PVar "n") (PVar "ns"))) (EBlock (DoLet false false (PVar "tok") (EBinOp "++" (EBinOp "++" (ELit (LString "uncosted:")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "")))) (DoLet false false (PVar "ack") (EIf (EApp (EApp (EVar "budgetAcked") (EVar "commitMessage")) (EVar "tok")) (ELit (LString " [ACKNOWLEDGED]")) (ELit (LString "")))) (DoExpr (EBinOp "::" (EApp (EVar "stringConcat") (EListLit (EVar "n") (EVar "ack") (ELit (LString " — remedy: re-ingest the baseline (test/gate_cost_ingest.sh) so this")) (ELit (LString " gate gets a sample; the `cost` field is present, the packer just has")) (ELit (LString " no price yet, so there is nothing to declare or split here.")) (ELit (LString " To accept unpriced on purpose, paste:\n    Gate-Budget-Override: ")) (EVar "tok") (ELit (LString "\n")))) (EApp (EApp (EVar "budgetUncostedLines") (EVar "commitMessage")) (EVar "ns"))))))
(DTypeSig false "budgetTimeoutMs" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "budgetTimeoutMs" ((PVar "cost")) (EBinOp "*" (EApp (EApp (EVar "timeoutFor") (ELit (LInt 0))) (EVar "cost")) (ELit (LInt 1000))))
(DTypeSig false "budgetToleratedMs" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "budgetToleratedMs" ((PVar "cost")) (EBinOp "/" (EBinOp "*" (EApp (EVar "budgetTimeoutMs") (EVar "cost")) (ELit (LInt 1000))) (EVar "balTargetMilli")))
(DTypeSig false "budgetOverClassGates" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "budgetOverClassGates" (PWild (PList)) (EListLit))
(DFunDef false "budgetOverClassGates" ((PVar "base") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EApp (EApp (EVar "budgetOverClassGates") (EVar "base")) (EVar "gs")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "costOf") (EFieldAccess (EVar "g") "run")) (EVar "base")) (arm (PCon "None") () (EApp (EApp (EVar "budgetOverClassGates") (EVar "base")) (EVar "gs"))) (arm (PCon "Some" (PVar "ms")) ((GBool (EBinOp ">" (EVar "ms") (EApp (EVar "budgetToleratedMs") (EFieldAccess (EVar "g") "cost"))))) (EBinOp "::" (EVar "g") (EApp (EApp (EVar "budgetOverClassGates") (EVar "base")) (EVar "gs")))) (arm PWild () (EApp (EApp (EVar "budgetOverClassGates") (EVar "base")) (EVar "gs")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "budgetOverClassTokens" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "budgetOverClassTokens" ((PList)) (EListLit))
(DFunDef false "budgetOverClassTokens" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "over-class:")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ""))) (EApp (EVar "budgetOverClassTokens") (EVar "gs"))))
(DTypeSig false "budgetTimeoutRemedy" (TyCon "String"))
(DFunDef false "budgetTimeoutRemedy" () (ELit (LString "Re-classing a gate changes its CI kill timeout (cheap=300s / medium=900s / heavy=3600s, `timeoutFor`) — pick deliberately, not just to silence this gate.")))
(DTypeSig false "budgetOverClassLines" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "budgetOverClassLines" (PWild PWild (PList)) (EListLit))
(DFunDef false "budgetOverClassLines" ((PVar "base") (PVar "commitMessage") (PCons (PVar "g") (PVar "gs"))) (EBlock (DoLet false false (PVar "ms") (EMatch (EApp (EApp (EVar "costOf") (EFieldAccess (EVar "g") "run")) (EVar "base")) (arm (PCon "Some" (PVar "m")) () (EVar "m")) (arm (PCon "None") () (ELit (LInt 0))))) (DoLet false false (PVar "tok") (EBinOp "++" (EBinOp "++" (ELit (LString "over-class:")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "")))) (DoLet false false (PVar "ack") (EIf (EApp (EApp (EVar "budgetAcked") (EVar "commitMessage")) (EVar "tok")) (ELit (LString " [ACKNOWLEDGED]")) (ELit (LString "")))) (DoExpr (EBinOp "::" (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString " ("))) (EApp (EVar "display") (EFieldAccess (EVar "g") "cost"))) (ELit (LString ", measured "))) (EApp (EVar "display") (EApp (EVar "balSecs") (EVar "ms")))) (ELit (LString ", tolerance-adjusted ceiling "))) (EApp (EVar "balSecs") (EApp (EVar "budgetToleratedMs") (EFieldAccess (EVar "g") "cost"))) (EBinOp "++" (EBinOp "++" (ELit (LString " of a ")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EApp (EVar "timeoutFor") (ELit (LInt 0))) (EFieldAccess (EVar "g") "cost"))))) (ELit (LString "s timeout)"))) (EVar "ack") (ELit (LString " — remedy: declare a higher `cost` class, split the gate into cheaper")) (ELit (LString " pieces, or demote it with `tiers = [\"nightly\"]` so it leaves the")) (ELit (LString " merge-required path. ")) (EVar "budgetTimeoutRemedy") (ELit (LString " To accept the current cost on purpose, paste:\n    Gate-Budget-Override: ")) (EVar "tok") (ELit (LString "\n")))) (EApp (EApp (EApp (EVar "budgetOverClassLines") (EVar "base")) (EVar "commitMessage")) (EVar "gs"))))))
(DTypeSig false "budgetPoleFactor" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "budgetPoleFactor" ((PVar "gates") (PVar "shs") (PVar "base") (PVar "runs")) (EBlock (DoLet false false (PVar "cs") (EApp (EApp (EVar "balCands") (EVar "base")) (EVar "gates"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "balTarget") (EVar "True")) (EVar "cs")) (EApp (EApp (EVar "balRows") (EVar "runs")) (EVar "shs"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PTuple PWild (PVar "rows"))) () (EBlock (DoLet false false (PVar "factor") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rows"))) (DoExpr (EIf (EBinOp "<=" (EVar "factor") (EVar "balTargetMilli")) (EApp (EVar "Ok") (EVar "None")) (EApp (EVar "Ok") (EApp (EVar "Some") (EVar "factor")))))))))))
(DTypeSig false "budgetPoleFloorLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "budgetPoleFloorLines" (PWild (PCon "None")) (EListLit))
(DFunDef false "budgetPoleFloorLines" ((PVar "commitMessage") (PCon "Some" (PVar "factor"))) (EBlock (DoLet false false (PVar "tok") (ELit (LString "pole-floor"))) (DoLet false false (PVar "ack") (EIf (EApp (EApp (EVar "budgetAcked") (EVar "commitMessage")) (EVar "tok")) (ELit (LString " [ACKNOWLEDGED]")) (ELit (LString "")))) (DoExpr (EBinOp "::" (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "projected pole/floor ")) (EApp (EVar "display") (EApp (EVar "balMilli") (EVar "factor")))) (ELit (LString " exceeds the budget "))) (EApp (EVar "display") (EApp (EVar "balMilli") (EVar "balTargetMilli")))) (ELit (LString " (S-4)"))) (EVar "ack") (ELit (LString " — remedy: run `medaka gate balance` to see which row or gate needs to")) (ELit (LString " shrink, split the pole gate, or demote a heavy gate to")) (ELit (LString " `tiers = [\"nightly\"]`. To accept the current pole/floor on purpose, paste:\n    Gate-Budget-Override: ")) (EVar "tok") (ELit (LString "\n")))) (EListLit)))))
(DTypeSig false "budgetIndent" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "budgetIndent" ((PList)) (EListLit))
(DFunDef false "budgetIndent" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EVar "display") (EVar "x"))) (ELit (LString ""))) (EApp (EVar "budgetIndent") (EVar "xs"))))
(DTypeSig false "budgetSection" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "budgetSection" (PWild (PList)) (ELit (LString "")))
(DFunDef false "budgetSection" ((PVar "title") (PVar "lines")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "title"))) (ELit (LString ": "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "lines"))))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EVar "joinNl") (EApp (EVar "budgetIndent") (EVar "lines"))))) (ELit (LString "\n\n"))))
(DTypeSig false "budgetReport" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))))
(DFunDef false "budgetReport" ((PVar "base") (PVar "commitMessage") (PVar "uncosted") (PVar "overClass") (PVar "poleFactorOpt")) (EBlock (DoLet false false (PVar "aLines") (EApp (EApp (EVar "budgetUncostedLines") (EVar "commitMessage")) (EVar "uncosted"))) (DoLet false false (PVar "bLines") (EApp (EApp (EApp (EVar "budgetOverClassLines") (EVar "base")) (EVar "commitMessage")) (EVar "overClass"))) (DoLet false false (PVar "cLines") (EApp (EApp (EVar "budgetPoleFloorLines") (EVar "commitMessage")) (EVar "poleFactorOpt"))) (DoLet false false (PVar "aUnacked") (EApp (EApp (EVar "budgetCountUnacked") (EVar "commitMessage")) (EApp (EVar "budgetUncostedTokens") (EVar "uncosted")))) (DoLet false false (PVar "bUnacked") (EApp (EApp (EVar "budgetCountUnacked") (EVar "commitMessage")) (EApp (EVar "budgetOverClassTokens") (EVar "overClass")))) (DoLet false false (PVar "cCount") (EMatch (EVar "poleFactorOpt") (arm (PCon "None") () (ELit (LInt 0))) (arm (PCon "Some" PWild) () (ELit (LInt 1))))) (DoLet false false (PVar "cUnacked") (EIf (EBinOp "==" (EVar "cCount") (ELit (LInt 0))) (ELit (LInt 0)) (EIf (EApp (EApp (EVar "budgetAcked") (EVar "commitMessage")) (ELit (LString "pole-floor"))) (ELit (LInt 0)) (ELit (LInt 1))))) (DoLet false false (PVar "total") (EBinOp "+" (EBinOp "+" (EApp (EVar "listLen") (EVar "uncosted")) (EApp (EVar "listLen") (EVar "overClass"))) (EVar "cCount"))) (DoLet false false (PVar "unacked") (EBinOp "+" (EBinOp "+" (EVar "aUnacked") (EVar "bUnacked")) (EVar "cUnacked"))) (DoLet false false (PVar "body") (EApp (EVar "stringConcat") (EListLit (EApp (EApp (EVar "budgetSection") (ELit (LString "no cost baseline entry (clause a)"))) (EVar "aLines")) (EApp (EApp (EVar "budgetSection") (ELit (LString "over declared class, tolerance-adjusted (clause b)"))) (EVar "bLines")) (EApp (EApp (EVar "budgetSection") (ELit (LString "projected pole/floor over budget (clause c)"))) (EVar "cLines"))))) (DoExpr (EIf (EBinOp "==" (EVar "total") (ELit (LInt 0))) (EApp (EVar "Ok") (ELit (LString "medaka gate budget: OK — 0 violations.\n"))) (EIf (EBinOp "==" (EVar "unacked") (ELit (LInt 0))) (EApp (EVar "Ok") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "body"))) (ELit (LString "medaka gate budget: "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "total")))) (ELit (LString " violation(s), all acknowledged by commit-message trailer — OK.\n")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "body"))) (ELit (LString "medaka gate budget: FAIL — "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "unacked")))) (ELit (LString " of "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "total")))) (ELit (LString " violation(s) not acknowledged. Paste the `Gate-Budget-Override:` trailer(s) shown above onto your commit message to accept them on purpose.\n")))))))))
(DTypeSig true "budgetOutput" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "budgetOutput" ((PVar "regPath") (PVar "regSrc") (PVar "baseSrc") (PVar "commitMessage")) (EMatch (EApp (EVar "parseRegistry") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "gates")) () (EMatch (EApp (EVar "parseShards") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "shs")) () (EMatch (EApp (EVar "parseCostBaseline") (EVar "baseSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "base")) () (EMatch (EApp (EVar "parseCostRuns") (EVar "baseSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "runs")) () (EMatch (EApp (EApp (EVar "balUnknownRows") (EVar "shs")) (EVar "gates")) (arm (PCons (PVar "u") (PVar "us")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EVar "display") (EVar "regPath"))) (ELit (LString ": gate(s) name a shard with no [[shard]] row: "))) (EApp (EVar "display") (EApp (EVar "joinSpace") (EBinOp "::" (EVar "u") (EVar "us"))))) (ELit (LString "\n"))))) (arm (PList) () (EBlock (DoLet false false (PVar "uncosted") (EApp (EApp (EVar "budgetUncostedNames") (EVar "base")) (EVar "gates"))) (DoLet false false (PVar "overClass") (EApp (EApp (EVar "budgetOverClassGates") (EVar "base")) (EVar "gates"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "budgetPoleFactor") (EVar "gates")) (EVar "shs")) (EVar "base")) (EVar "runs")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "\n"))))) (arm (PCon "Ok" (PVar "poleFactorOpt")) () (EApp (EApp (EApp (EApp (EApp (EVar "budgetReport") (EVar "base")) (EVar "commitMessage")) (EVar "uncosted")) (EVar "overClass")) (EVar "poleFactorOpt")))))))))))))))))
# MARK
(DUse false (UseGroup ("tools" "gate_registry") ((mem "Gate" false) (mem "Shard" false) (mem "parseRegistry" false) (mem "parseShards" false) (mem "joinSpace" false))))
(DUse false (UseGroup ("tools" "gate_cost") ((mem "GateCost" false) (mem "RunRecord" false) (mem "baselineKey" false) (mem "costOf" false) (mem "costRowOf" false) (mem "gateSetDigest" false) (mem "latestRunForShard" false) (mem "packStat" false) (mem "parseCostBaseline" false) (mem "parseCostRuns" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "isNonEmptyL" false) (mem "joinNl" false) (mem "listLen" false) (mem "maxI" false) (mem "minI" false) (mem "reverseL" false) (mem "splitNl" false) (mem "splitOnChar" false) (mem "startsWith" false) (mem "stringTrim" false))))
(DTypeSig true "timeoutFor" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "timeoutFor" ((PVar "override") (PVar "cost")) (EIf (EBinOp ">" (EVar "override") (ELit (LInt 0))) (EVar "override") (EIf (EBinOp "==" (EVar "cost") (ELit (LString "cheap"))) (ELit (LInt 300)) (EIf (EBinOp "==" (EVar "cost") (ELit (LString "medium"))) (ELit (LInt 900)) (EIf (EBinOp "==" (EVar "cost") (ELit (LString "heavy"))) (ELit (LInt 3600)) (EIf (EVar "otherwise") (ELit (LInt 900)) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DData Private "Cand" () ((variant "Cand" (ConNamed (field "cname" (TyCon "String")) (field "crun" (TyCon "String")) (field "curRow" (TyCon "String")) (field "cms" (TyCon "Int")) (field "needsWasm" (TyCon "Bool"))))) ())
(DData Private "Row" () ((variant "Row" (ConNamed (field "rname" (TyCon "String")) (field "rwasm" (TyCon "Bool")) (field "rclosed" (TyCon "Bool")) (field "rload" (TyCon "Int")) (field "rcount" (TyCon "Int")) (field "rjobs" (TyCon "Int")) (field "rbuckets" (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DData Private "Place" () ((variant "Place" (ConNamed (field "pname" (TyCon "String")) (field "pfrom" (TyCon "String")) (field "pto" (TyCon "String"))))) ())
(DTypeSig true "balOtherJob" (TyCon "String"))
(DFunDef false "balOtherJob" () (ELit (LString "other-job")))
(DTypeSig false "balTargetMilli" (TyCon "Int"))
(DFunDef false "balTargetMilli" () (ELit (LInt 1125)))
(DTypeSig false "balMarginPct" (TyCon "Int"))
(DFunDef false "balMarginPct" () (ELit (LInt 5)))
(DTypeSig false "balStabPct" (TyCon "Int"))
(DFunDef false "balStabPct" () (ELit (LInt 5)))
(DTypeSig false "balNeedsWasm" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))
(DFunDef false "balNeedsWasm" ((PList)) (EVar "False"))
(DFunDef false "balNeedsWasm" ((PCons (PVar "t") (PVar "ts"))) (EIf (EBinOp "==" (EVar "t") (ELit (LString "wasm-tools"))) (EVar "True") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "node"))) (EVar "t")) (EVar "True") (EIf (EVar "otherwise") (EApp (EVar "balNeedsWasm") (EVar "ts")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balUnknownRows" (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balUnknownRows" (PWild (PList)) (EListLit))
(DFunDef false "balUnknownRows" ((PVar "shs") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EApp (EApp (EVar "balUnknownRows") (EVar "shs")) (EVar "gs")) (EIf (EApp (EApp (EVar "balHasRow") (EFieldAccess (EVar "g") "shard")) (EVar "shs")) (EApp (EApp (EVar "balUnknownRows") (EVar "shs")) (EVar "gs")) (EIf (EVar "otherwise") (EBinOp "::" (EFieldAccess (EVar "g") "name") (EApp (EApp (EVar "balUnknownRows") (EVar "shs")) (EVar "gs"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balHasRow" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyCon "Bool"))))
(DFunDef false "balHasRow" (PWild (PList)) (EVar "False"))
(DFunDef false "balHasRow" ((PVar "n") (PCons (PVar "s") (PVar "ss"))) (EIf (EBinOp "==" (EFieldAccess (EVar "s") "name") (EVar "n")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "balHasRow") (EVar "n")) (EVar "ss")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balUncosted" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balUncosted" (PWild (PList)) (EListLit))
(DFunDef false "balUncosted" ((PVar "base") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EApp (EApp (EVar "balUncosted") (EVar "base")) (EVar "gs")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "costOf") (EFieldAccess (EVar "g") "run")) (EVar "base")) (arm (PCon "Some" PWild) () (EApp (EApp (EVar "balUncosted") (EVar "base")) (EVar "gs"))) (arm (PCon "None") () (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString " (baseline key '"))) (EApp (EMethodRef "display") (EApp (EVar "baselineKey") (EFieldAccess (EVar "g") "run")))) (ELit (LString "')"))) (EApp (EApp (EVar "balUncosted") (EVar "base")) (EVar "gs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balCands" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Cand")))))
(DFunDef false "balCands" (PWild (PList)) (EListLit))
(DFunDef false "balCands" ((PVar "base") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EApp (EApp (EVar "balCands") (EVar "base")) (EVar "gs")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "costOf") (EFieldAccess (EVar "g") "run")) (EVar "base")) (arm (PCon "None") () (EApp (EApp (EVar "balCands") (EVar "base")) (EVar "gs"))) (arm (PCon "Some" (PVar "ms")) () (EBinOp "::" (ERecordCreate "Cand" ((fa "cname" (EFieldAccess (EVar "g") "name")) (fa "crun" (EFieldAccess (EVar "g") "run")) (fa "curRow" (EFieldAccess (EVar "g") "shard")) (fa "cms" (EVar "ms")) (fa "needsWasm" (EApp (EVar "balNeedsWasm") (EFieldAccess (EVar "g") "toolchain"))))) (EApp (EApp (EVar "balCands") (EVar "base")) (EVar "gs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRows" (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyApp (TyCon "List") (TyCon "Row")))))
(DFunDef false "balRows" (PWild (PList)) (EListLit))
(DFunDef false "balRows" ((PVar "runs") (PCons (PVar "s") (PVar "ss"))) (EBlock (DoLet false false (PVar "j") (EApp (EApp (EVar "balJobsFor") (EFieldAccess (EVar "s") "name")) (EVar "runs"))) (DoExpr (EBinOp "::" (ERecordCreate "Row" ((fa "rname" (EFieldAccess (EVar "s") "name")) (fa "rwasm" (EFieldAccess (EVar "s") "wasmArm")) (fa "rclosed" (EFieldAccess (EVar "s") "fullCores")) (fa "rload" (ELit (LInt 0))) (fa "rcount" (ELit (LInt 0))) (fa "rjobs" (EVar "j")) (fa "rbuckets" (EApp (EVar "balZeros") (EVar "j"))))) (EApp (EApp (EVar "balRows") (EVar "runs")) (EVar "ss"))))))
(DTypeSig false "balJobsFor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyCon "Int"))))
(DFunDef false "balJobsFor" ((PVar "n") (PVar "runs")) (EMatch (EApp (EApp (EVar "latestRunForShard") (EVar "n")) (EVar "runs")) (arm (PCon "Some" (PVar "r")) () (EMatch (EFieldAccess (EVar "r") "parallel") (arm (PCon "Some" (PCon "False")) () (ELit (LInt 1))) (arm PWild () (EMatch (EFieldAccess (EVar "r") "jobs") (arm (PCon "Some" (PVar "j")) ((GBool (EBinOp ">=" (EVar "j") (ELit (LInt 1))))) (EVar "j")) (arm PWild () (EApp (EApp (EVar "balAnyJobs") (EVar "runs")) (ELit (LInt 1)))))))) (arm (PCon "None") () (EApp (EApp (EVar "balAnyJobs") (EVar "runs")) (ELit (LInt 1))))))
(DTypeSig false "balAnyJobs" (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "balAnyJobs" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "balAnyJobs" ((PCons (PVar "r") (PVar "rs")) (PVar "acc")) (EMatch (EFieldAccess (EVar "r") "jobs") (arm (PCon "Some" (PVar "j")) ((GBool (EBinOp ">=" (EVar "j") (ELit (LInt 1))))) (EApp (EApp (EVar "balAnyJobs") (EVar "rs")) (EVar "j"))) (arm PWild () (EApp (EApp (EVar "balAnyJobs") (EVar "rs")) (EVar "acc")))))
(DTypeSig false "balJobsIsFallback" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyCon "Bool"))))
(DFunDef false "balJobsIsFallback" ((PVar "n") (PVar "runs")) (EMatch (EApp (EApp (EVar "latestRunForShard") (EVar "n")) (EVar "runs")) (arm (PCon "Some" (PVar "r")) () (EMatch (EFieldAccess (EVar "r") "jobs") (arm (PCon "Some" (PVar "j")) ((GBool (EBinOp ">=" (EVar "j") (ELit (LInt 1))))) (EVar "False")) (arm PWild () (EVar "True")))) (arm (PCon "None") () (EVar "True"))))
(DTypeSig false "balZeros" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "balZeros" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (ELit (LInt 0)) (EApp (EVar "balZeros") (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "candBefore" (TyFun (TyCon "Cand") (TyFun (TyCon "Cand") (TyCon "Bool"))))
(DFunDef false "candBefore" ((PVar "a") (PVar "b")) (EIf (EBinOp "/=" (EFieldAccess (EVar "a") "cms") (EFieldAccess (EVar "b") "cms")) (EBinOp ">" (EFieldAccess (EVar "a") "cms") (EFieldAccess (EVar "b") "cms")) (EIf (EVar "otherwise") (EBinOp "<" (EFieldAccess (EVar "a") "cname") (EFieldAccess (EVar "b") "cname")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balSortCands" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyApp (TyCon "List") (TyCon "Cand"))))
(DFunDef false "balSortCands" ((PList)) (EListLit))
(DFunDef false "balSortCands" ((PCons (PVar "x") (PList))) (EBinOp "::" (EVar "x") (EListLit)))
(DFunDef false "balSortCands" ((PVar "xs")) (EBlock (DoLet false false (PTuple (PVar "l") (PVar "r")) (EApp (EApp (EApp (EVar "balHalve") (EVar "xs")) (EListLit)) (EListLit))) (DoExpr (EApp (EApp (EVar "balMergeCands") (EApp (EVar "balSortCands") (EVar "l"))) (EApp (EVar "balSortCands") (EVar "r"))))))
(DTypeSig false "balHalve" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyTuple (TyApp (TyCon "List") (TyCon "Cand")) (TyApp (TyCon "List") (TyCon "Cand")))))))
(DFunDef false "balHalve" ((PList) (PVar "a") (PVar "b")) (ETuple (EVar "a") (EVar "b")))
(DFunDef false "balHalve" ((PCons (PVar "x") (PVar "xs")) (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "balHalve") (EVar "xs")) (EVar "b")) (EBinOp "::" (EVar "x") (EVar "a"))))
(DTypeSig false "balMergeCands" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyApp (TyCon "List") (TyCon "Cand")))))
(DFunDef false "balMergeCands" ((PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "balMergeCands" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "balMergeCands" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EIf (EApp (EApp (EVar "candBefore") (EVar "x")) (EVar "y")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "balMergeCands") (EVar "xs")) (EBinOp "::" (EVar "y") (EVar "ys")))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "balMergeCands") (EBinOp "::" (EVar "x") (EVar "xs"))) (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPick" (TyFun (TyCon "Cand") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "balPick" ((PVar "c") (PVar "rs")) (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EVar "None")))
(DTypeSig false "balPickGo" (TyFun (TyCon "Cand") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "Option") (TyCon "Row")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "balPickGo" (PWild (PList) (PCon "None")) (EVar "None"))
(DFunDef false "balPickGo" (PWild (PList) (PCon "Some" (PVar "b"))) (EApp (EVar "Some") (EFieldAccess (EVar "b") "rname")))
(DFunDef false "balPickGo" ((PVar "c") (PCons (PVar "r") (PVar "rs")) (PVar "best")) (EIf (EFieldAccess (EVar "r") "rclosed") (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EVar "best")) (EIf (EBinOp "&&" (EFieldAccess (EVar "c") "needsWasm") (EApp (EVar "not") (EFieldAccess (EVar "r") "rwasm"))) (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EVar "best")) (EIf (EVar "otherwise") (EMatch (EVar "best") (arm (PCon "None") () (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EApp (EVar "Some") (EVar "r")))) (arm (PCon "Some" (PVar "b")) () (EIf (EBinOp "<" (EFieldAccess (EVar "r") "rload") (EFieldAccess (EVar "b") "rload")) (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EApp (EVar "Some") (EVar "r"))) (EApp (EApp (EApp (EVar "balPickGo") (EVar "c")) (EVar "rs")) (EVar "best"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balPickStable" (TyFun (TyCon "Cand") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "balPickStable" ((PVar "c") (PVar "rs")) (EMatch (EApp (EApp (EVar "balPick") (EVar "c")) (EVar "rs")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "best")) () (EIf (EApp (EApp (EApp (EVar "balStays") (EVar "c")) (EVar "best")) (EVar "rs")) (EApp (EVar "Some") (EFieldAccess (EVar "c") "curRow")) (EApp (EVar "Some") (EVar "best"))))))
(DTypeSig false "balStays" (TyFun (TyCon "Cand") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool")))))
(DFunDef false "balStays" ((PVar "c") (PVar "best") (PVar "rs")) (EIf (EBinOp "==" (EFieldAccess (EVar "c") "curRow") (EVar "best")) (EVar "True") (EIf (EApp (EVar "not") (EApp (EApp (EVar "balRowTakes") (EVar "c")) (EVar "rs"))) (EVar "False") (EIf (EVar "otherwise") (EBinOp "<=" (EBinOp "*" (EApp (EApp (EVar "balRowLoad") (EFieldAccess (EVar "c") "curRow")) (EVar "rs")) (ELit (LInt 100))) (EBinOp "*" (EApp (EApp (EVar "balRowLoad") (EVar "best")) (EVar "rs")) (EBinOp "+" (ELit (LInt 100)) (EVar "balStabPct")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balRowTakes" (TyFun (TyCon "Cand") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool"))))
(DFunDef false "balRowTakes" (PWild (PList)) (EVar "False"))
(DFunDef false "balRowTakes" ((PVar "c") (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "rname") (EFieldAccess (EVar "c") "curRow")) (EBinOp "&&" (EApp (EVar "not") (EFieldAccess (EVar "r") "rclosed")) (EBinOp "||" (EApp (EVar "not") (EFieldAccess (EVar "c") "needsWasm")) (EFieldAccess (EVar "r") "rwasm"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "balRowTakes") (EVar "c")) (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRowLoad" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int"))))
(DFunDef false "balRowLoad" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "balRowLoad" ((PVar "n") (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "rname") (EVar "n")) (EFieldAccess (EVar "r") "rload") (EIf (EVar "otherwise") (EApp (EApp (EVar "balRowLoad") (EVar "n")) (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balAdd" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "List") (TyCon "Row"))))))
(DFunDef false "balAdd" (PWild PWild (PList)) (EListLit))
(DFunDef false "balAdd" ((PVar "n") (PVar "ms") (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "rname") (EVar "n")) (EBlock (DoLet false false (PVar "bs") (EApp (EApp (EVar "balBucketAdd") (EVar "ms")) (EFieldAccess (EVar "r") "rbuckets"))) (DoExpr (EBinOp "::" (EVariantUpdate "Row" (EVar "r") ((fa "rbuckets" (EVar "bs")) (fa "rload" (EApp (EVar "balMaxL") (EVar "bs"))) (fa "rcount" (EBinOp "+" (EFieldAccess (EVar "r") "rcount") (ELit (LInt 1)))))) (EVar "rs")))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "r") (EApp (EApp (EApp (EVar "balAdd") (EVar "n")) (EVar "ms")) (EVar "rs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balBucketAdd" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "balBucketAdd" ((PVar "ms") (PList)) (EBinOp "::" (EVar "ms") (EListLit)))
(DFunDef false "balBucketAdd" ((PVar "ms") (PVar "bs")) (EApp (EApp (EApp (EVar "balBucketPut") (EVar "ms")) (EApp (EVar "balMinL") (EVar "bs"))) (EVar "bs")))
(DTypeSig false "balBucketPut" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "balBucketPut" (PWild PWild (PList)) (EListLit))
(DFunDef false "balBucketPut" ((PVar "ms") (PVar "m") (PCons (PVar "b") (PVar "bs"))) (EIf (EBinOp "==" (EVar "b") (EVar "m")) (EBinOp "::" (EBinOp "+" (EVar "b") (EVar "ms")) (EVar "bs")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "b") (EApp (EApp (EApp (EVar "balBucketPut") (EVar "ms")) (EVar "m")) (EVar "bs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balMinL" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "balMinL" ((PList)) (ELit (LInt 0)))
(DFunDef false "balMinL" ((PCons (PVar "x") (PList))) (EVar "x"))
(DFunDef false "balMinL" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "minI") (EVar "x")) (EApp (EVar "balMinL") (EVar "xs"))))
(DTypeSig false "balMaxL" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "balMaxL" ((PList)) (ELit (LInt 0)))
(DFunDef false "balMaxL" ((PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "maxI") (EVar "x")) (EApp (EVar "balMaxL") (EVar "xs"))))
(DTypeSig false "balPlace" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "List") (TyCon "Row")))))))))
(DFunDef false "balPlace" (PWild (PList) (PVar "rs") (PVar "acc")) (EApp (EVar "Ok") (ETuple (EApp (EVar "reverseL") (EVar "acc")) (EVar "rs"))))
(DFunDef false "balPlace" ((PVar "stab") (PCons (PVar "c") (PVar "cs")) (PVar "rs") (PVar "acc")) (EMatch (EIf (EVar "stab") (EApp (EApp (EVar "balPickStable") (EVar "c")) (EVar "rs")) (EApp (EApp (EVar "balPick") (EVar "c")) (EVar "rs"))) (arm (PCon "None") () (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: no row can run '")) (EApp (EMethodRef "display") (EFieldAccess (EVar "c") "cname"))) (ELit (LString "'.\n"))) (ELit (LString "  It needs the Wasm toolchain (wasm-tools / node), and every row with\n")) (ELit (LString "  wasm_arm = true is closed to the packer (full_cores).  Wasm rows: ")) (EApp (EVar "joinSpace") (EApp (EVar "balWasmRowNames") (EVar "rs"))) (ELit (LString "\n")))))) (arm (PCon "Some" (PVar "rn")) () (EApp (EApp (EApp (EApp (EVar "balPlace") (EVar "stab")) (EVar "cs")) (EApp (EApp (EApp (EVar "balAdd") (EVar "rn")) (EFieldAccess (EVar "c") "cms")) (EVar "rs"))) (EBinOp "::" (ERecordCreate "Place" ((fa "pname" (EFieldAccess (EVar "c") "cname")) (fa "pfrom" (EFieldAccess (EVar "c") "curRow")) (fa "pto" (EVar "rn")))) (EVar "acc"))))))
(DTypeSig false "balWasmRowNames" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "balWasmRowNames" ((PList)) (EListLit))
(DFunDef false "balWasmRowNames" ((PCons (PVar "r") (PVar "rs"))) (EIf (EFieldAccess (EVar "r") "rwasm") (EBinOp "::" (EFieldAccess (EVar "r") "rname") (EApp (EVar "balWasmRowNames") (EVar "rs"))) (EIf (EVar "otherwise") (EApp (EVar "balWasmRowNames") (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balSeedClosed" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "List") (TyCon "Row"))))))))
(DFunDef false "balSeedClosed" ((PList) (PVar "rs") (PVar "acc")) (EApp (EVar "Ok") (ETuple (EApp (EVar "reverseL") (EVar "acc")) (EVar "rs"))))
(DFunDef false "balSeedClosed" ((PCons (PVar "c") (PVar "cs")) (PVar "rs") (PVar "acc")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "balIsClosed") (EFieldAccess (EVar "c") "curRow")) (EVar "rs"))) (EApp (EApp (EApp (EVar "balSeedClosed") (EVar "cs")) (EVar "rs")) (EVar "acc")) (EIf (EBinOp "&&" (EFieldAccess (EVar "c") "needsWasm") (EApp (EVar "not") (EApp (EApp (EVar "balRowIsWasm") (EFieldAccess (EVar "c") "curRow")) (EVar "rs")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: '")) (EApp (EMethodRef "display") (EFieldAccess (EVar "c") "cname"))) (ELit (LString "' needs the Wasm toolchain but is pinned to row '"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "c") "curRow"))) (ELit (LString "', which has wasm_arm = false")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "balSeedClosed") (EVar "cs")) (EApp (EApp (EApp (EVar "balAdd") (EFieldAccess (EVar "c") "curRow")) (EFieldAccess (EVar "c") "cms")) (EVar "rs"))) (EBinOp "::" (ERecordCreate "Place" ((fa "pname" (EFieldAccess (EVar "c") "cname")) (fa "pfrom" (EFieldAccess (EVar "c") "curRow")) (fa "pto" (EFieldAccess (EVar "c") "curRow")))) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balIsClosed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool"))))
(DFunDef false "balIsClosed" (PWild (PList)) (EVar "False"))
(DFunDef false "balIsClosed" ((PVar "n") (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "rname") (EVar "n")) (EFieldAccess (EVar "r") "rclosed") (EIf (EVar "otherwise") (EApp (EApp (EVar "balIsClosed") (EVar "n")) (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRowIsWasm" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool"))))
(DFunDef false "balRowIsWasm" (PWild (PList)) (EVar "False"))
(DFunDef false "balRowIsWasm" ((PVar "n") (PCons (PVar "r") (PVar "rs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "r") "rname") (EVar "n")) (EFieldAccess (EVar "r") "rwasm") (EIf (EVar "otherwise") (EApp (EApp (EVar "balRowIsWasm") (EVar "n")) (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPinErrors" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balPinErrors" (PWild (PList)) (EListLit))
(DFunDef false "balPinErrors" ((PVar "gs") (PCons (PVar "s") (PVar "ss"))) (EIf (EBinOp "&&" (EApp (EVar "not") (EFieldAccess (EVar "s") "fullCores")) (EApp (EVar "isNonEmptyL") (EFieldAccess (EVar "s") "pinned"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "row '")) (EApp (EMethodRef "display") (EFieldAccess (EVar "s") "name"))) (ELit (LString "': pinned_gates is non-empty ("))) (EApp (EMethodRef "display") (EApp (EVar "joinSpace") (EFieldAccess (EVar "s") "pinned")))) (ELit (LString ") on an OPEN row (full_cores = false); only a closed row's membership is declared, an open row's is the packer's output"))) (EApp (EApp (EVar "balPinErrors") (EVar "gs")) (EVar "ss"))) (EIf (EApp (EVar "not") (EFieldAccess (EVar "s") "fullCores")) (EApp (EApp (EVar "balPinErrors") (EVar "gs")) (EVar "ss")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "members") (EApp (EApp (EVar "balRowMembers") (EFieldAccess (EVar "s") "name")) (EVar "gs"))) (DoExpr (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "balPinMissing") (EFieldAccess (EVar "s") "name")) (EVar "gs")) (EFieldAccess (EVar "s") "pinned")) (EVar "members")) (EApp (EApp (EApp (EVar "balPinExtra") (EFieldAccess (EVar "s") "name")) (EFieldAccess (EVar "s") "pinned")) (EVar "members"))) (EApp (EApp (EVar "balPinErrors") (EVar "gs")) (EVar "ss"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balRowMembers" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balRowMembers" (PWild (PList)) (EListLit))
(DFunDef false "balRowMembers" ((PVar "n") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "n")) (EBinOp "::" (EFieldAccess (EVar "g") "name") (EApp (EApp (EVar "balRowMembers") (EVar "n")) (EVar "gs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "balRowMembers") (EVar "n")) (EVar "gs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPinMissing" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "balPinMissing" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "balPinMissing" ((PVar "n") (PVar "gs") (PCons (PVar "p") (PVar "ps")) (PVar "members")) (EIf (EApp (EApp (EVar "balElemStr") (EVar "p")) (EVar "members")) (EApp (EApp (EApp (EApp (EVar "balPinMissing") (EVar "n")) (EVar "gs")) (EVar "ps")) (EVar "members")) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EVar "balPinPlace") (EVar "n")) (EVar "gs")) (EVar "p")) (EApp (EApp (EApp (EApp (EVar "balPinMissing") (EVar "n")) (EVar "gs")) (EVar "ps")) (EVar "members"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPinPlace" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "balPinPlace" ((PVar "n") (PVar "gs") (PVar "p")) (EMatch (EApp (EApp (EVar "balShardOfGate") (EVar "p")) (EVar "gs")) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "row '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "': pinned gate '"))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "' is not in the registry at all")))) (arm (PCon "Some" (PVar "other")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "row '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "': pinned gate '"))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "' is committed on row '"))) (EApp (EMethodRef "display") (EVar "other"))) (ELit (LString "' instead"))))))
(DTypeSig false "balShardOfGate" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "balShardOfGate" (PWild (PList)) (EVar "None"))
(DFunDef false "balShardOfGate" ((PVar "n") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "name") (EVar "n")) (EApp (EVar "Some") (EFieldAccess (EVar "g") "shard")) (EIf (EVar "otherwise") (EApp (EApp (EVar "balShardOfGate") (EVar "n")) (EVar "gs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPinExtra" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "balPinExtra" (PWild PWild (PList)) (EListLit))
(DFunDef false "balPinExtra" ((PVar "n") (PVar "pinned") (PCons (PVar "m") (PVar "ms"))) (EIf (EApp (EApp (EVar "balElemStr") (EVar "m")) (EVar "pinned")) (EApp (EApp (EApp (EVar "balPinExtra") (EVar "n")) (EVar "pinned")) (EVar "ms")) (EIf (EVar "otherwise") (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "row '")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "': '"))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "' is committed on this closed row but is not in its pinned_gates"))) (EApp (EApp (EApp (EVar "balPinExtra") (EVar "n")) (EVar "pinned")) (EVar "ms"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balElemStr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "balElemStr" (PWild (PList)) (EVar "False"))
(DFunDef false "balElemStr" ((PVar "x") (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "==" (EVar "x") (EVar "y")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "balElemStr") (EVar "x")) (EVar "ys")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOpenCands" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "List") (TyCon "Cand")))))
(DFunDef false "balOpenCands" ((PList) PWild) (EListLit))
(DFunDef false "balOpenCands" ((PCons (PVar "c") (PVar "cs")) (PVar "rs")) (EIf (EApp (EApp (EVar "balIsClosed") (EFieldAccess (EVar "c") "curRow")) (EVar "rs")) (EApp (EApp (EVar "balOpenCands") (EVar "cs")) (EVar "rs")) (EIf (EVar "otherwise") (EBinOp "::" (EVar "c") (EApp (EApp (EVar "balOpenCands") (EVar "cs")) (EVar "rs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balTarget" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "List") (TyCon "Row"))))))))
(DFunDef false "balTarget" ((PVar "stab") (PVar "cs") (PVar "rows0")) (EBlock (DoLet false false (PVar "sorted") (EApp (EVar "balSortCands") (EVar "cs"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "balSeedClosed") (EVar "sorted")) (EVar "rows0")) (EListLit)) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PTuple (PVar "pinned") (PVar "rows1"))) () (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "placed") (PVar "rows2"))) (ETuple (EBinOp "++" (EVar "pinned") (EVar "placed")) (EVar "rows2")))) (EApp (EApp (EApp (EApp (EVar "balPlace") (EVar "stab")) (EApp (EVar "balSortCands") (EApp (EApp (EVar "balOpenCands") (EVar "sorted")) (EVar "rows0")))) (EVar "rows1")) (EListLit))))))))
(DTypeSig false "balCurrent" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyTuple (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "List") (TyCon "Row"))))))
(DFunDef false "balCurrent" ((PList) (PVar "rs")) (ETuple (EListLit) (EVar "rs")))
(DFunDef false "balCurrent" ((PCons (PVar "c") (PVar "cs")) (PVar "rs")) (EBlock (DoLet false false (PTuple (PVar "ps") (PVar "rs2")) (EApp (EApp (EVar "balCurrent") (EVar "cs")) (EApp (EApp (EApp (EVar "balAdd") (EFieldAccess (EVar "c") "curRow")) (EFieldAccess (EVar "c") "cms")) (EVar "rs")))) (DoExpr (ETuple (EBinOp "::" (ERecordCreate "Place" ((fa "pname" (EFieldAccess (EVar "c") "cname")) (fa "pfrom" (EFieldAccess (EVar "c") "curRow")) (fa "pto" (EFieldAccess (EVar "c") "curRow")))) (EVar "ps")) (EVar "rs2")))))
(DTypeSig false "balPole" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int")))
(DFunDef false "balPole" ((PList)) (ELit (LInt 0)))
(DFunDef false "balPole" ((PCons (PVar "r") (PVar "rs"))) (EApp (EApp (EVar "maxI") (EFieldAccess (EVar "r") "rload")) (EApp (EVar "balPole") (EVar "rs"))))
(DTypeSig false "balPoleRow" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "String")))
(DFunDef false "balPoleRow" ((PVar "rs")) (EApp (EApp (EApp (EVar "balPoleRowGo") (EVar "rs")) (ELit (LString ""))) (EUnOp "-" (ELit (LInt 1)))))
(DTypeSig false "balPoleRowGo" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "balPoleRowGo" ((PList) (PVar "n") PWild) (EVar "n"))
(DFunDef false "balPoleRowGo" ((PCons (PVar "r") (PVar "rs")) (PVar "n") (PVar "best")) (EIf (EBinOp ">" (EFieldAccess (EVar "r") "rload") (EVar "best")) (EApp (EApp (EApp (EVar "balPoleRowGo") (EVar "rs")) (EFieldAccess (EVar "r") "rname")) (EFieldAccess (EVar "r") "rload")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "balPoleRowGo") (EVar "rs")) (EVar "n")) (EVar "best")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balLoads" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "balLoads" ((PList)) (EListLit))
(DFunDef false "balLoads" ((PCons (PVar "r") (PVar "rs"))) (EBinOp "::" (EFieldAccess (EVar "r") "rload") (EApp (EVar "balLoads") (EVar "rs"))))
(DTypeSig false "balSortInts" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "balSortInts" ((PList)) (EListLit))
(DFunDef false "balSortInts" ((PCons (PVar "x") (PList))) (EBinOp "::" (EVar "x") (EListLit)))
(DFunDef false "balSortInts" ((PVar "xs")) (EBlock (DoLet false false (PTuple (PVar "l") (PVar "r")) (EApp (EApp (EApp (EVar "balHalveI") (EVar "xs")) (EListLit)) (EListLit))) (DoExpr (EApp (EApp (EVar "balMergeInts") (EApp (EVar "balSortInts") (EVar "l"))) (EApp (EVar "balSortInts") (EVar "r"))))))
(DTypeSig false "balHalveI" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyTuple (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "balHalveI" ((PList) (PVar "a") (PVar "b")) (ETuple (EVar "a") (EVar "b")))
(DFunDef false "balHalveI" ((PCons (PVar "x") (PVar "xs")) (PVar "a") (PVar "b")) (EApp (EApp (EApp (EVar "balHalveI") (EVar "xs")) (EVar "b")) (EBinOp "::" (EVar "x") (EVar "a"))))
(DTypeSig false "balMergeInts" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "balMergeInts" ((PList) (PVar "ys")) (EVar "ys"))
(DFunDef false "balMergeInts" ((PVar "xs") (PList)) (EVar "xs"))
(DFunDef false "balMergeInts" ((PCons (PVar "x") (PVar "xs")) (PCons (PVar "y") (PVar "ys"))) (EIf (EBinOp "<=" (EVar "x") (EVar "y")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "balMergeInts") (EVar "xs")) (EBinOp "::" (EVar "y") (EVar "ys")))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "y") (EApp (EApp (EVar "balMergeInts") (EBinOp "::" (EVar "x") (EVar "xs"))) (EVar "ys"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balMedian" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int")))
(DFunDef false "balMedian" ((PVar "rs")) (EBlock (DoLet false false (PVar "v") (EApp (EVar "balSortInts") (EApp (EVar "balLoads") (EVar "rs")))) (DoLet false false (PVar "n") (EApp (EVar "listLen") (EVar "v"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (ELit (LInt 0)) (EIf (EBinOp "==" (EBinOp "%" (EVar "n") (ELit (LInt 2))) (ELit (LInt 1))) (EApp (EApp (EVar "balNth") (EBinOp "/" (EVar "n") (ELit (LInt 2)))) (EVar "v")) (EBinOp "/" (EBinOp "+" (EApp (EApp (EVar "balNth") (EBinOp "-" (EBinOp "/" (EVar "n") (ELit (LInt 2))) (ELit (LInt 1)))) (EVar "v")) (EApp (EApp (EVar "balNth") (EBinOp "/" (EVar "n") (ELit (LInt 2)))) (EVar "v"))) (ELit (LInt 2))))))))
(DTypeSig false "balNth" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int"))))
(DFunDef false "balNth" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "balNth" ((PVar "i") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "x") (EIf (EVar "otherwise") (EApp (EApp (EVar "balNth") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balFloorGateMs" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyCon "Int")))
(DFunDef false "balFloorGateMs" ((PVar "cs")) (EFieldAccess (EApp (EVar "balMaxCand") (EVar "cs")) "cms"))
(DTypeSig false "balFloorClosedMs" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int")))
(DFunDef false "balFloorClosedMs" ((PList)) (ELit (LInt 0)))
(DFunDef false "balFloorClosedMs" ((PCons (PVar "r") (PVar "rs"))) (EIf (EFieldAccess (EVar "r") "rclosed") (EApp (EApp (EVar "maxI") (EFieldAccess (EVar "r") "rload")) (EApp (EVar "balFloorClosedMs") (EVar "rs"))) (EIf (EVar "otherwise") (EApp (EVar "balFloorClosedMs") (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balFloorClosedRow" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "String")))
(DFunDef false "balFloorClosedRow" ((PVar "rs")) (EApp (EApp (EApp (EVar "balFloorClosedRowGo") (EVar "rs")) (ELit (LString ""))) (EUnOp "-" (ELit (LInt 1)))))
(DTypeSig false "balFloorClosedRowGo" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "balFloorClosedRowGo" ((PList) (PVar "n") PWild) (EVar "n"))
(DFunDef false "balFloorClosedRowGo" ((PCons (PVar "r") (PVar "rs")) (PVar "n") (PVar "best")) (EIf (EBinOp "&&" (EFieldAccess (EVar "r") "rclosed") (EBinOp ">" (EFieldAccess (EVar "r") "rload") (EVar "best"))) (EApp (EApp (EApp (EVar "balFloorClosedRowGo") (EVar "rs")) (EFieldAccess (EVar "r") "rname")) (EFieldAccess (EVar "r") "rload")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "balFloorClosedRowGo") (EVar "rs")) (EVar "n")) (EVar "best")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOpenWork" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int"))))
(DFunDef false "balOpenWork" ((PList) PWild) (ELit (LInt 0)))
(DFunDef false "balOpenWork" ((PCons (PVar "c") (PVar "cs")) (PVar "rs")) (EIf (EApp (EApp (EVar "balIsClosed") (EFieldAccess (EVar "c") "curRow")) (EVar "rs")) (EApp (EApp (EVar "balOpenWork") (EVar "cs")) (EVar "rs")) (EIf (EVar "otherwise") (EBinOp "+" (EFieldAccess (EVar "c") "cms") (EApp (EApp (EVar "balOpenWork") (EVar "cs")) (EVar "rs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOpenSlots" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int")))
(DFunDef false "balOpenSlots" ((PList)) (ELit (LInt 0)))
(DFunDef false "balOpenSlots" ((PCons (PVar "r") (PVar "rs"))) (EIf (EFieldAccess (EVar "r") "rclosed") (EApp (EVar "balOpenSlots") (EVar "rs")) (EIf (EVar "otherwise") (EBinOp "+" (EFieldAccess (EVar "r") "rjobs") (EApp (EVar "balOpenSlots") (EVar "rs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balFloorCapMs" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int"))))
(DFunDef false "balFloorCapMs" ((PVar "cs") (PVar "rs")) (EBlock (DoLet false false (PVar "s") (EApp (EVar "balOpenSlots") (EVar "rs"))) (DoExpr (EIf (EBinOp "<=" (EVar "s") (ELit (LInt 0))) (ELit (LInt 0)) (EBinOp "/" (EApp (EApp (EVar "balOpenWork") (EVar "cs")) (EVar "rs")) (EVar "s"))))))
(DTypeSig false "balFloor" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int"))))
(DFunDef false "balFloor" ((PVar "cs") (PVar "rs")) (EApp (EApp (EVar "maxI") (EApp (EVar "balFloorGateMs") (EVar "cs"))) (EApp (EApp (EVar "maxI") (EApp (EVar "balFloorClosedMs") (EVar "rs"))) (EApp (EApp (EVar "balFloorCapMs") (EVar "cs")) (EVar "rs")))))
(DTypeSig false "balFloorIsGate" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool"))))
(DFunDef false "balFloorIsGate" ((PVar "cs") (PVar "rs")) (EBinOp ">=" (EApp (EVar "balFloorGateMs") (EVar "cs")) (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs"))))
(DTypeSig false "balFloorLine" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "String"))))
(DFunDef false "balFloorLine" ((PVar "cs") (PVar "rs")) (EIf (EBinOp "<=" (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs")) (ELit (LInt 0))) (ELit (LString "")) (EIf (EApp (EApp (EVar "balFloorIsGate") (EVar "cs")) (EVar "rs")) (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  floor: the achievable pole — set by '")) (EApp (EMethodRef "display") (EFieldAccess (EApp (EVar "balMaxCand") (EVar "cs")) "cname"))) (ELit (LString "' alone ("))) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EApp (EVar "balFloorGateMs") (EVar "cs"))))) (ELit (LString "), which is indivisible.\n"))) (ELit (LString "         Moving the FLOOR means that gate has to get FASTER (or be split).\n")))) (EIf (EBinOp ">=" (EApp (EVar "balFloorClosedMs") (EVar "rs")) (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  floor: the achievable pole — set by the closed row '")) (EApp (EMethodRef "display") (EApp (EVar "balFloorClosedRow") (EVar "rs")))) (ELit (LString "' ("))) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EApp (EVar "balFloorClosedMs") (EVar "rs"))))) (ELit (LString "), whose membership the packer cannot change.\n"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  floor: the achievable pole — set by ")) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EApp (EApp (EVar "balOpenWork") (EVar "cs")) (EVar "rs"))))) (ELit (LString " of open work over "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "balOpenSlots") (EVar "rs"))))) (ELit (LString " open worker slots.\n"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "balFactorMilli" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Int"))))
(DFunDef false "balFactorMilli" ((PVar "cs") (PVar "rs")) (EBlock (DoLet false false (PVar "f") (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs"))) (DoExpr (EIf (EBinOp "<=" (EVar "f") (ELit (LInt 0))) (ELit (LInt 0)) (EBinOp "/" (EBinOp "*" (EApp (EVar "balPole") (EVar "rs")) (ELit (LInt 1000))) (EVar "f"))))))
(DTypeSig false "balMaxCand" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyCon "Cand")))
(DFunDef false "balMaxCand" ((PList)) (ERecordCreate "Cand" ((fa "cname" (ELit (LString "(none)"))) (fa "crun" (ELit (LString ""))) (fa "curRow" (ELit (LString ""))) (fa "cms" (ELit (LInt 0))) (fa "needsWasm" (EVar "False")))))
(DFunDef false "balMaxCand" ((PCons (PVar "c") (PList))) (EVar "c"))
(DFunDef false "balMaxCand" ((PCons (PVar "c") (PVar "cs"))) (EBlock (DoLet false false (PVar "r") (EApp (EVar "balMaxCand") (EVar "cs"))) (DoExpr (EIf (EBinOp ">=" (EFieldAccess (EVar "c") "cms") (EFieldAccess (EVar "r") "cms")) (EVar "c") (EVar "r")))))
(DTypeSig false "balSecs" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "balSecs" ((PVar "ms")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "/" (EVar "ms") (ELit (LInt 1000)))))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "/" (EBinOp "%" (EVar "ms") (ELit (LInt 1000))) (ELit (LInt 100)))))) (ELit (LString "s"))))
(DTypeSig false "balTenth" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "balTenth" ((PVar "pm")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "/" (EVar "pm") (ELit (LInt 10)))))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "%" (EVar "pm") (ELit (LInt 10)))))) (ELit (LString "%"))))
(DTypeSig false "balPct1" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "balPct1" ((PVar "d") (PVar "base")) (EIf (EBinOp "<=" (EVar "base") (ELit (LInt 0))) (ELit (LString "n/a")) (EIf (EBinOp "<" (EVar "d") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (ELit (LString "-")) (EApp (EMethodRef "display") (EApp (EVar "balTenth") (EBinOp "/" (EBinOp "*" (EBinOp "-" (ELit (LInt 0)) (EVar "d")) (ELit (LInt 1000))) (EVar "base"))))) (ELit (LString ""))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (ELit (LString "+")) (EApp (EMethodRef "display") (EApp (EVar "balTenth") (EBinOp "/" (EBinOp "*" (EVar "d") (ELit (LInt 1000))) (EVar "base"))))) (ELit (LString ""))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balMilli" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "balMilli" ((PVar "m")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "/" (EVar "m") (ELit (LInt 1000)))))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "balPad3") (EBinOp "%" (EVar "m") (ELit (LInt 1000)))))) (ELit (LString ""))))
(DTypeSig false "balPad3" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "balPad3" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 10))) (EBinOp "++" (EBinOp "++" (ELit (LString "00")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 100))) (EBinOp "++" (EBinOp "++" (ELit (LString "0")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))) (EIf (EVar "otherwise") (EApp (EVar "intToString") (EVar "n")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balPadR" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "balPadR" ((PVar "w") (PVar "s")) (EIf (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (EVar "w")) (EVar "s") (EIf (EVar "otherwise") (EApp (EApp (EVar "balPadR") (EVar "w")) (EBinOp "++" (EVar "s") (ELit (LString " ")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPadL" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "balPadL" ((PVar "w") (PVar "s")) (EIf (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (EVar "w")) (EVar "s") (EIf (EVar "otherwise") (EApp (EApp (EVar "balPadL") (EVar "w")) (EBinOp "++" (ELit (LString " ")) (EVar "s"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balDelta" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "balDelta" ((PVar "d")) (EIf (EBinOp "<" (EVar "d") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (ELit (LString "-")) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EBinOp "-" (ELit (LInt 0)) (EVar "d"))))) (ELit (LString ""))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (ELit (LString "+")) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EVar "d")))) (ELit (LString ""))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRowLines" (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balRowLines" ((PList) PWild) (EListLit))
(DFunDef false "balRowLines" ((PCons (PVar "r") (PVar "rs")) (PVar "runs")) (EBlock (DoLet false false (PVar "tag") (EIf (EFieldAccess (EVar "r") "rclosed") (ELit (LString "  [closed: full_cores]")) (ELit (LString "")))) (DoLet false false (PVar "jt") (EIf (EApp (EApp (EVar "balJobsIsFallback") (EFieldAccess (EVar "r") "rname")) (EVar "runs")) (ELit (LString " jobs*")) (ELit (LString " jobs ")))) (DoExpr (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadR") (ELit (LInt 10))) (EFieldAccess (EVar "r") "rname")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 4))) (EApp (EVar "intToString") (EFieldAccess (EVar "r") "rcount"))))) (ELit (LString " gates "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balSecs") (EFieldAccess (EVar "r") "rload"))))) (ELit (LString "  "))) (EApp (EMethodRef "display") (EVar "jt"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EFieldAccess (EVar "r") "rjobs")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString ""))) (EApp (EApp (EVar "balRowLines") (EVar "rs")) (EVar "runs"))))))
(DTypeSig false "balCalibLines" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "balCalibLines" (PWild (PList) PWild) (EListLit))
(DFunDef false "balCalibLines" ((PVar "cs") (PCons (PVar "r") (PVar "rs")) (PVar "runs")) (EBinOp "::" (EApp (EApp (EApp (EVar "balCalibLine") (EVar "cs")) (EVar "r")) (EVar "runs")) (EApp (EApp (EApp (EVar "balCalibLines") (EVar "cs")) (EVar "rs")) (EVar "runs"))))
(DTypeSig false "balCalibStaleness" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "String"))))))
(DFunDef false "balCalibStaleness" (PWild (PCon "None") PWild PWild) (ELit (LString "")))
(DFunDef false "balCalibStaleness" ((PVar "cur") (PCon "Some" (PVar "recorded")) (PVar "curDig") (PVar "recDig")) (EIf (EBinOp "/=" (EVar "cur") (EVar "recorded")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " [STALE: ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "cur")))) (ELit (LString " gates now, "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "recorded")))) (ELit (LString " when recorded]"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "balCalibSetStaleness") (EVar "cur")) (EVar "curDig")) (EVar "recDig")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balCalibSetStaleness" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyCon "String")))))
(DFunDef false "balCalibSetStaleness" (PWild PWild (PCon "None")) (ELit (LString "")))
(DFunDef false "balCalibSetStaleness" ((PVar "n") (PVar "cur") (PCon "Some" (PVar "recorded"))) (EIf (EBinOp "==" (EVar "cur") (EVar "recorded")) (ELit (LString "")) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " [STALE: the same ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " gates by COUNT but a DIFFERENT SET (set digest "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "cur")))) (ELit (LString " now, "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "recorded")))) (ELit (LString " when recorded)]"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRowDigest" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyCon "Int"))))
(DFunDef false "balRowDigest" ((PVar "rn") (PVar "cs")) (EApp (EVar "gateSetDigest") (EApp (EApp (EVar "balRowKeys") (EVar "rn")) (EVar "cs"))))
(DTypeSig false "balRowKeys" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balRowKeys" (PWild (PList)) (EListLit))
(DFunDef false "balRowKeys" ((PVar "rn") (PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "c") "curRow") (EVar "rn")) (EBinOp "::" (EApp (EVar "baselineKey") (EFieldAccess (EVar "c") "crun")) (EApp (EApp (EVar "balRowKeys") (EVar "rn")) (EVar "cs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "balRowKeys") (EVar "rn")) (EVar "cs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balCalibLine" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyCon "Row") (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyCon "String")))))
(DFunDef false "balCalibLine" ((PVar "cands") (PVar "r") (PVar "runs")) (EMatch (EApp (EApp (EVar "latestRunForShard") (EFieldAccess (EVar "r") "rname")) (EVar "runs")) (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadR") (ELit (LInt 10))) (EFieldAccess (EVar "r") "rname")))) (ELit (LString " (no recorded run)")))) (arm (PCon "Some" (PVar "rr")) () (EMatch (EFieldAccess (EVar "rr") "rowElapsedMs") (arm (PCon "None") () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadR") (ELit (LInt 10))) (EFieldAccess (EVar "r") "rname")))) (ELit (LString " (run "))) (EApp (EMethodRef "display") (EFieldAccess (EVar "rr") "runId"))) (ELit (LString " recorded no rowElapsedMs)")))) (arm (PCon "Some" (PVar "e")) () (EBlock (DoLet false false (PVar "d") (EBinOp "-" (EVar "e") (EFieldAccess (EVar "r") "rload"))) (DoLet false false (PVar "pct") (EIf (EBinOp ">" (EFieldAccess (EVar "r") "rload") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EBinOp "/" (EBinOp "*" (EVar "d") (ELit (LInt 100))) (EFieldAccess (EVar "r") "rload"))))) (ELit (LString "%)"))) (ELit (LString "")))) (DoLet false false (PVar "stale") (EApp (EApp (EApp (EApp (EVar "balCalibStaleness") (EFieldAccess (EVar "r") "rcount")) (EFieldAccess (EVar "rr") "gates")) (EApp (EApp (EVar "balRowDigest") (EFieldAccess (EVar "r") "rname")) (EVar "cands"))) (EFieldAccess (EVar "rr") "gatesDigest"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadR") (ELit (LInt 10))) (EFieldAccess (EVar "r") "rname")))) (ELit (LString " recorded "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balSecs") (EVar "e"))))) (ELit (LString "   predicted "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balSecs") (EFieldAccess (EVar "r") "rload"))))) (ELit (LString "   residual "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balDelta") (EVar "d"))))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "pct"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "stale"))) (ELit (LString ""))))))))))
(DTypeSig false "balStabLine" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "String"))))))
(DFunDef false "balStabLine" ((PVar "cs") (PVar "rows0") (PVar "ps") (PVar "rows")) (EMatch (EApp (EApp (EApp (EVar "balTarget") (EVar "False")) (EVar "cs")) (EVar "rows0")) (arm (PCon "Err" PWild) () (ELit (LString "  stability: the unstabilized comparison packing could not be derived\n"))) (arm (PCon "Ok" (PTuple (PVar "lps") (PVar "lrows"))) () (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  stability: ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EApp (EVar "balHeldCount") (EVar "ps")) (EVar "lps"))))) (ELit (LString " of "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "ps"))))) (ELit (LString " gates held on their committed row"))) (EBinOp "++" (EBinOp "++" (ELit (LString " (incumbent slack ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "balStabPct")))) (ELit (LString "% of a row's load)"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "; pole ")) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EApp (EVar "balPole") (EVar "rows"))))) (ELit (LString " against "))) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EApp (EVar "balPole") (EVar "lrows"))))) (ELit (LString " unstabilized"))) (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EMethodRef "display") (EApp (EVar "balDelta") (EBinOp "-" (EApp (EVar "balPole") (EVar "rows")) (EApp (EVar "balPole") (EVar "lrows")))))) (ELit (LString "),"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " pole/floor ")) (EApp (EMethodRef "display") (EApp (EVar "balMilli") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rows"))))) (ELit (LString " against "))) (EApp (EMethodRef "display") (EApp (EVar "balMilli") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "lrows"))))) (ELit (LString "\n"))))))))
(DTypeSig false "balHeldCount" (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyCon "Int"))))
(DFunDef false "balHeldCount" ((PList) PWild) (ELit (LInt 0)))
(DFunDef false "balHeldCount" ((PCons (PVar "p") (PVar "ps")) (PVar "qs")) (EIf (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "p") "pto") (EFieldAccess (EVar "p") "pfrom")) (EBinOp "/=" (EApp (EApp (EVar "balPlaceOf") (EFieldAccess (EVar "p") "pname")) (EVar "qs")) (EFieldAccess (EVar "p") "pto"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EApp (EVar "balHeldCount") (EVar "ps")) (EVar "qs"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "balHeldCount") (EVar "ps")) (EVar "qs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balMoved" (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyCon "Int")))
(DFunDef false "balMoved" ((PList)) (ELit (LInt 0)))
(DFunDef false "balMoved" ((PCons (PVar "p") (PVar "ps"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "p") "pfrom") (EFieldAccess (EVar "p") "pto")) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "balMoved") (EVar "ps"))) (EIf (EVar "otherwise") (EApp (EVar "balMoved") (EVar "ps")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balThinSamples" (TyCon "Int"))
(DFunDef false "balThinSamples" () (ELit (LInt 2)))
(DTypeSig false "balThinCount" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyCon "Int")))
(DFunDef false "balThinCount" ((PList)) (ELit (LInt 0)))
(DFunDef false "balThinCount" ((PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "<" (EFieldAccess (EVar "c") "samples") (EVar "balThinSamples")) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "balThinCount") (EVar "cs"))) (EIf (EVar "otherwise") (EApp (EVar "balThinCount") (EVar "cs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balThinLine" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyCon "String")))
(DFunDef false "balThinLine" ((PVar "base")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "balThinCount") (EVar "base"))))) (ELit (LString " of "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "base"))))) (ELit (LString " gates are scheduled off a single sample (samples < "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "balThinSamples")))) (ELit (LString ")\n"))))
(DTypeSig false "balOosBlock" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyCon "String")))))
(DFunDef false "balOosBlock" ((PVar "base") (PVar "cs") (PVar "runs")) (EBlock (DoLet false false (PVar "ids") (EApp (EApp (EVar "balRunIds") (EVar "runs")) (EListLit))) (DoLet false false (PVar "nr") (EApp (EVar "listLen") (EVar "ids"))) (DoExpr (EIf (EBinOp "<" (EVar "nr") (ELit (LInt 2))) (EBinOp "++" (EBinOp "++" (ELit (LString "  out-of-sample error of the packing statistic: not derivable (")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "nr")))) (ELit (LString " recorded run(s); predicting one run from the others needs at least two)\n"))) (EBlock (DoLet false false (PVar "vs") (EApp (EApp (EApp (EVar "balOosVecs") (EVar "base")) (EVar "cs")) (EVar "ids"))) (DoLet false false (PVar "ne") (EApp (EVar "listLen") (EVar "vs"))) (DoExpr (EIf (EBinOp "==" (EVar "ne") (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  out-of-sample error of the packing statistic: not derivable — ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EApp (EVar "balAttrKnown") (EVar "base")) (EVar "cs"))))) (ELit (LString " of "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EApp (EVar "balAttrTotal") (EVar "base")) (EVar "cs"))))) (ELit (LString " retained samples carry run attribution, and no schedulable gate carries an exactly attributed sample from each of the "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "nr")))) (ELit (LString " recorded runs\n"))) (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  out-of-sample error of the packing statistic (leave-one-run-out over the ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "nr")))) (ELit (LString " runs in runs[], across the "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "ne")))) (ELit (LString " of "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "cs"))))) (ELit (LString " schedulable gates carrying a run-attributed sample from every run):\n"))) (EApp (EVar "joinNl") (EApp (EApp (EApp (EApp (EVar "balOosFolds") (EVar "vs")) (EVar "ids")) (ELit (LInt 0))) (EVar "nr"))) (ELit (LString "\n")) (EApp (EApp (EVar "balOosSummary") (EVar "vs")) (EVar "nr")) (EApp (EVar "balOosDriftLine") (EVar "base")))))))))))
(DTypeSig false "balOosFolds" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "balOosFolds" ((PVar "vs") (PVar "ids") (PVar "i") (PVar "nr")) (EIf (EBinOp ">=" (EVar "i") (EVar "nr")) (EListLit) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "p") (EApp (EApp (EVar "balOosPred") (EVar "vs")) (EVar "i"))) (DoLet false false (PVar "a") (EApp (EApp (EVar "balOosAct") (EVar "vs")) (EVar "i"))) (DoExpr (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    run ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadR") (ELit (LInt 13))) (EApp (EApp (EVar "balNthStr") (EVar "i")) (EVar "ids"))))) (ELit (LString " predicted "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balSecs") (EVar "p"))))) (ELit (LString "   actual "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 9))) (EApp (EVar "balSecs") (EVar "a"))))) (ELit (LString "   "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPadL") (ELit (LInt 7))) (EApp (EApp (EVar "balPct1") (EBinOp "-" (EVar "p") (EVar "a"))) (EVar "a"))))) (ELit (LString ""))) (EApp (EApp (EApp (EApp (EVar "balOosFolds") (EVar "vs")) (EVar "ids")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "nr"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOosSummary" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "balOosSummary" ((PVar "vs") (PVar "nr")) (EBlock (DoLet false false (PVar "p") (EApp (EApp (EApp (EVar "balOosPredAll") (EVar "vs")) (ELit (LInt 0))) (EVar "nr"))) (DoLet false false (PVar "a") (EApp (EApp (EApp (EVar "balOosActAll") (EVar "vs")) (ELit (LInt 0))) (EVar "nr"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "    mean |error| ")) (EApp (EMethodRef "display") (EApp (EVar "balTenth") (EBinOp "/" (EApp (EApp (EApp (EApp (EVar "balOosAbsPm") (EVar "vs")) (ELit (LInt 0))) (EVar "nr")) (ELit (LInt 0))) (EVar "nr"))))) (ELit (LString "   systematic bias "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "balPct1") (EBinOp "-" (EVar "p") (EVar "a"))) (EVar "a")))) (ELit (LString " (the median is the low-side robust choice — see gate_cost.packStat)\n"))))))
(DTypeSig false "balOosDriftLine" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyCon "String")))
(DFunDef false "balOosDriftLine" ((PVar "base")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "balStatDrift") (EVar "base"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (ELit (LString "")) (EBinOp "++" (EBinOp "++" (ELit (LString "    WARNING: ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " baseline row(s) carry a medianMs that the packing statistic does not reproduce — the ingester and gate_cost.packStat have drifted; re-ingest before trusting a placement\n")))))))
(DTypeSig false "balStatDrift" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyCon "Int")))
(DFunDef false "balStatDrift" ((PList)) (ELit (LInt 0)))
(DFunDef false "balStatDrift" ((PCons (PVar "c") (PVar "cs"))) (EIf (EBinOp "==" (EApp (EVar "packStat") (EFieldAccess (EVar "c") "ms")) (EFieldAccess (EVar "c") "medianMs")) (EApp (EVar "balStatDrift") (EVar "cs")) (EIf (EVar "otherwise") (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "balStatDrift") (EVar "cs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOosVecs" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "balOosVecs" (PWild (PList) PWild) (EListLit))
(DFunDef false "balOosVecs" ((PVar "base") (PCons (PVar "c") (PVar "cs")) (PVar "ids")) (EMatch (EApp (EApp (EVar "costRowOf") (EFieldAccess (EVar "c") "crun")) (EVar "base")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "balOosVecs") (EVar "base")) (EVar "cs")) (EVar "ids"))) (arm (PCon "Some" (PVar "g")) () (EMatch (EApp (EApp (EVar "balOosVecFor") (EVar "g")) (EVar "ids")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "balOosVecs") (EVar "base")) (EVar "cs")) (EVar "ids"))) (arm (PCon "Some" (PVar "v")) () (EBinOp "::" (EVar "v") (EApp (EApp (EApp (EVar "balOosVecs") (EVar "base")) (EVar "cs")) (EVar "ids"))))))))
(DTypeSig false "balOosVecFor" (TyFun (TyCon "GateCost") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "balOosVecFor" (PWild (PList)) (EApp (EVar "Some") (EListLit)))
(DFunDef false "balOosVecFor" ((PVar "g") (PCons (PVar "r") (PVar "rs"))) (EMatch (EApp (EApp (EApp (EApp (EVar "balSampleForRun") (EVar "r")) (EFieldAccess (EVar "g") "ms")) (EFieldAccess (EVar "g") "sampleRuns")) (EVar "None")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "v")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "_s")) (EBinOp "::" (EVar "v") (EVar "_s")))) (EApp (EApp (EVar "balOosVecFor") (EVar "g")) (EVar "rs"))))))
(DTypeSig false "balSampleForRun" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "balSampleForRun" (PWild (PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "balSampleForRun" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "balSampleForRun" ((PVar "r") (PCons (PVar "m") (PVar "ms")) (PCons (PVar "s") (PVar "ss")) (PVar "acc")) (EIf (EBinOp "/=" (EVar "s") (EVar "r")) (EApp (EApp (EApp (EApp (EVar "balSampleForRun") (EVar "r")) (EVar "ms")) (EVar "ss")) (EVar "acc")) (EIf (EVar "otherwise") (EMatch (EVar "acc") (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "balSampleForRun") (EVar "r")) (EVar "ms")) (EVar "ss")) (EApp (EVar "Some") (EVar "m")))) (arm (PCon "Some" PWild) () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balAttrKnown" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyCon "Int"))))
(DFunDef false "balAttrKnown" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "balAttrKnown" ((PVar "base") (PCons (PVar "c") (PVar "cs"))) (EMatch (EApp (EApp (EVar "costRowOf") (EFieldAccess (EVar "c") "crun")) (EVar "base")) (arm (PCon "None") () (EApp (EApp (EVar "balAttrKnown") (EVar "base")) (EVar "cs"))) (arm (PCon "Some" (PVar "g")) () (EBinOp "+" (EApp (EVar "balCountAttr") (EFieldAccess (EVar "g") "sampleRuns")) (EApp (EApp (EVar "balAttrKnown") (EVar "base")) (EVar "cs"))))))
(DTypeSig false "balCountAttr" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int")))
(DFunDef false "balCountAttr" ((PList)) (ELit (LInt 0)))
(DFunDef false "balCountAttr" ((PCons (PVar "s") (PVar "ss"))) (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EApp (EVar "balCountAttr") (EVar "ss")) (EIf (EVar "otherwise") (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "balCountAttr") (EVar "ss"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balAttrTotal" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyCon "Int"))))
(DFunDef false "balAttrTotal" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "balAttrTotal" ((PVar "base") (PCons (PVar "c") (PVar "cs"))) (EMatch (EApp (EApp (EVar "costRowOf") (EFieldAccess (EVar "c") "crun")) (EVar "base")) (arm (PCon "None") () (EApp (EApp (EVar "balAttrTotal") (EVar "base")) (EVar "cs"))) (arm (PCon "Some" (PVar "g")) () (EBinOp "+" (EApp (EVar "listLen") (EFieldAccess (EVar "g") "ms")) (EApp (EApp (EVar "balAttrTotal") (EVar "base")) (EVar "cs"))))))
(DTypeSig false "balOosPred" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "balOosPred" ((PList) PWild) (ELit (LInt 0)))
(DFunDef false "balOosPred" ((PCons (PVar "v") (PVar "vs")) (PVar "i")) (EBinOp "+" (EApp (EVar "packStat") (EApp (EApp (EVar "balDropNth") (EVar "i")) (EVar "v"))) (EApp (EApp (EVar "balOosPred") (EVar "vs")) (EVar "i"))))
(DTypeSig false "balOosAct" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "balOosAct" ((PList) PWild) (ELit (LInt 0)))
(DFunDef false "balOosAct" ((PCons (PVar "v") (PVar "vs")) (PVar "i")) (EBinOp "+" (EApp (EApp (EVar "balNth") (EVar "i")) (EVar "v")) (EApp (EApp (EVar "balOosAct") (EVar "vs")) (EVar "i"))))
(DTypeSig false "balOosPredAll" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "balOosPredAll" ((PVar "vs") (PVar "i") (PVar "nr")) (EIf (EBinOp ">=" (EVar "i") (EVar "nr")) (ELit (LInt 0)) (EIf (EVar "otherwise") (EBinOp "+" (EApp (EApp (EVar "balOosPred") (EVar "vs")) (EVar "i")) (EApp (EApp (EApp (EVar "balOosPredAll") (EVar "vs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "nr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOosActAll" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "balOosActAll" ((PVar "vs") (PVar "i") (PVar "nr")) (EIf (EBinOp ">=" (EVar "i") (EVar "nr")) (ELit (LInt 0)) (EIf (EVar "otherwise") (EBinOp "+" (EApp (EApp (EVar "balOosAct") (EVar "vs")) (EVar "i")) (EApp (EApp (EApp (EVar "balOosActAll") (EVar "vs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "nr"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balOosAbsPm" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "balOosAbsPm" ((PVar "vs") (PVar "i") (PVar "nr") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "nr")) (EVar "acc") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "p") (EApp (EApp (EVar "balOosPred") (EVar "vs")) (EVar "i"))) (DoLet false false (PVar "a") (EApp (EApp (EVar "balOosAct") (EVar "vs")) (EVar "i"))) (DoLet false false (PVar "d") (EIf (EBinOp ">=" (EVar "p") (EVar "a")) (EBinOp "-" (EVar "p") (EVar "a")) (EBinOp "-" (EVar "a") (EVar "p")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "balOosAbsPm") (EVar "vs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "nr")) (EBinOp "+" (EVar "acc") (EIf (EBinOp ">" (EVar "a") (ELit (LInt 0))) (EBinOp "/" (EBinOp "*" (EVar "d") (ELit (LInt 1000))) (EVar "a")) (ELit (LInt 0))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balDropNth" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "balDropNth" (PWild (PList)) (EListLit))
(DFunDef false "balDropNth" ((PVar "i") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "xs") (EIf (EVar "otherwise") (EBinOp "::" (EVar "x") (EApp (EApp (EVar "balDropNth") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "xs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRunIds" (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balRunIds" ((PList) (PVar "acc")) (EApp (EApp (EVar "balRevStrs") (EVar "acc")) (EListLit)))
(DFunDef false "balRunIds" ((PCons (PVar "r") (PVar "rs")) (PVar "acc")) (EIf (EApp (EApp (EVar "balHasStr") (EFieldAccess (EVar "r") "runId")) (EVar "acc")) (EApp (EApp (EVar "balRunIds") (EVar "rs")) (EVar "acc")) (EIf (EVar "otherwise") (EApp (EApp (EVar "balRunIds") (EVar "rs")) (EBinOp "::" (EFieldAccess (EVar "r") "runId") (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balHasStr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool"))))
(DFunDef false "balHasStr" (PWild (PList)) (EVar "False"))
(DFunDef false "balHasStr" ((PVar "s") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "==" (EVar "x") (EVar "s")) (EVar "True") (EIf (EVar "otherwise") (EApp (EApp (EVar "balHasStr") (EVar "s")) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balRevStrs" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balRevStrs" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "balRevStrs" ((PCons (PVar "x") (PVar "xs")) (PVar "acc")) (EApp (EApp (EVar "balRevStrs") (EVar "xs")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DTypeSig false "balNthStr" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "balNthStr" (PWild (PList)) (ELit (LString "")))
(DFunDef false "balNthStr" ((PVar "i") (PCons (PVar "x") (PVar "xs"))) (EIf (EBinOp "<=" (EVar "i") (ELit (LInt 0))) (EVar "x") (EIf (EVar "otherwise") (EApp (EApp (EVar "balNthStr") (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EVar "xs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balReport" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyCon "String")))))))
(DFunDef false "balReport" ((PVar "label") (PVar "cs") (PVar "rs") (PVar "ps") (PVar "runs")) (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "cs"))))) (ELit (LString " schedulable gates over "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "rs"))))) (ELit (LString " rows\n"))) (ELit (LString "  predicted row wall clock (makespan of the per-gate baseline medians over the row's recorded workers; * = borrowed/defaulted worker count):\n")) (EApp (EVar "joinNl") (EApp (EApp (EVar "balRowLines") (EVar "rs")) (EVar "runs"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "\n  pole ")) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EApp (EVar "balPole") (EVar "rs"))))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EApp (EVar "balPoleRow") (EVar "rs")))) (ELit (LString ")   median "))) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EApp (EVar "balMedian") (EVar "rs"))))) (ELit (LString "   floor "))) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs"))))) (ELit (LString "   pole/floor "))) (EApp (EMethodRef "display") (EApp (EVar "balMilli") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rs"))))) (ELit (LString "\n"))) (EApp (EApp (EVar "balFloorLine") (EVar "cs")) (EVar "rs")) (EBinOp "++" (EBinOp "++" (ELit (LString "  gates whose row changes: ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "balMoved") (EVar "ps"))))) (ELit (LString "\n"))))))
(DTypeSig false "balCurrentLegal" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyCon "Bool"))))
(DFunDef false "balCurrentLegal" ((PList) PWild) (EVar "True"))
(DFunDef false "balCurrentLegal" ((PCons (PVar "c") (PVar "cs")) (PVar "rs")) (EIf (EBinOp "&&" (EFieldAccess (EVar "c") "needsWasm") (EApp (EVar "not") (EApp (EApp (EVar "balRowIsWasm") (EFieldAccess (EVar "c") "curRow")) (EVar "rs")))) (EVar "False") (EIf (EVar "otherwise") (EApp (EApp (EVar "balCurrentLegal") (EVar "cs")) (EVar "rs")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balBandNote" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyCon "String")))))
(DFunDef false "balBandNote" ((PCon "True") PWild PWild) (ELit (LString " — OVERRIDDEN (illegal assignment)")))
(DFunDef false "balBandNote" (PWild (PCon "True") PWild) (ELit (LString " — TAKEN")))
(DFunDef false "balBandNote" (PWild PWild (PCon "True")) (ELit (LString " — OVERRIDDEN (the committed assignment is not the derived one)")))
(DFunDef false "balBandNote" (PWild PWild PWild) (ELit (LString " — not reached (the committed assignment already IS the derived one)")))
(DTypeSig false "balFirstMove" (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "Option") (TyCon "Place"))))
(DFunDef false "balFirstMove" ((PList)) (EVar "None"))
(DFunDef false "balFirstMove" ((PCons (PVar "p") (PVar "ps"))) (EIf (EBinOp "/=" (EFieldAccess (EVar "p") "pfrom") (EFieldAccess (EVar "p") "pto")) (EApp (EVar "Some") (EVar "p")) (EIf (EVar "otherwise") (EApp (EVar "balFirstMove") (EVar "ps")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balMoveLine" (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyCon "String")))
(DFunDef false "balMoveLine" ((PVar "ps")) (EMatch (EApp (EVar "balFirstMove") (EVar "ps")) (arm (PCon "None") () (ELit (LString ""))) (arm (PCon "Some" (PVar "p")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  first divergence: '")) (EApp (EMethodRef "display") (EFieldAccess (EVar "p") "pname"))) (ELit (LString "' is committed on row '"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "p") "pfrom"))) (ELit (LString "' but derives to '"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "p") "pto"))) (ELit (LString "'.\n"))))))
(DTypeSig false "balEnforce" (TyFun (TyApp (TyCon "List") (TyCon "Cand")) (TyFun (TyApp (TyCon "List") (TyCon "Row")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "balEnforce" ((PVar "cs") (PVar "rs")) (EIf (EBinOp "<=" (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rs")) (EVar "balTargetMilli")) (EVar "None") (EIf (EApp (EApp (EVar "balFloorIsGate") (EVar "cs")) (EVar "rs")) (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka gate balance: the emitted assignment misses the pole/floor budget of ")) (EApp (EVar "balMilli") (EVar "balTargetMilli")) (ELit (LString " (it is ")) (EApp (EVar "balMilli") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rs"))) (ELit (LString ").\n")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "  The floor is '")) (EApp (EMethodRef "display") (EFieldAccess (EApp (EVar "balMaxCand") (EVar "cs")) "cname"))) (ELit (LString "' alone, at "))) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EFieldAccess (EApp (EVar "balMaxCand") (EVar "cs")) "cms")))) (ELit (LString ", against a pole of "))) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EApp (EVar "balPole") (EVar "rs"))))) (ELit (LString ".\n"))) (ELit (LString "  Gates are indivisible, so the pole can never go below the most expensive\n")) (ELit (LString "  gate, and the rest of this gap is what would not fit around it.  This is\n")) (ELit (LString "  a gate that has to get FASTER (or be split); repacking cannot move the\n")) (ELit (LString "  floor while it stands.\n"))))) (EIf (EVar "otherwise") (EApp (EVar "Some") (EApp (EVar "stringConcat") (EListLit (ELit (LString "medaka gate balance: the emitted assignment misses the pole/floor budget of ")) (EApp (EVar "balMilli") (EVar "balTargetMilli")) (ELit (LString " (it is ")) (EApp (EVar "balMilli") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rs"))) (ELit (LString ").\n")) (EBinOp "++" (EBinOp "++" (ELit (LString "  No single gate explains it — the floor is ")) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EApp (EApp (EVar "balFloor") (EVar "cs")) (EVar "rs"))))) (ELit (LString " and no gate costs that\n"))) (ELit (LString "  much — so this is the packing: rows within budget exist and the heuristic\n")) (ELit (LString "  did not find them.\n"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "balShardValues" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "balShardValues" ((PList) PWild) (EListLit))
(DFunDef false "balShardValues" ((PCons (PVar "g") (PVar "gs")) (PVar "ps")) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EBinOp "::" (EVar "balOtherJob") (EApp (EApp (EVar "balShardValues") (EVar "gs")) (EVar "ps"))) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EVar "balPlaceOf") (EFieldAccess (EVar "g") "name")) (EVar "ps")) (EApp (EApp (EVar "balShardValues") (EVar "gs")) (EVar "ps"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balPlaceOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Place")) (TyCon "String"))))
(DFunDef false "balPlaceOf" ((PVar "n") (PList)) (EVar "n"))
(DFunDef false "balPlaceOf" ((PVar "n") (PCons (PVar "p") (PVar "ps"))) (EIf (EBinOp "==" (EFieldAccess (EVar "p") "pname") (EVar "n")) (EFieldAccess (EVar "p") "pto") (EIf (EVar "otherwise") (EApp (EApp (EVar "balPlaceOf") (EVar "n")) (EVar "ps")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "balSplice" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "balSplice" ((PVar "vals") (PVar "src")) (EApp (EApp (EApp (EApp (EVar "balSpliceGo") (EVar "vals")) (EVar "src")) (EVar "False")) (EListLit)))
(DTypeSig false "balSpliceGo" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "balSpliceGo" ((PList) (PList) PWild (PVar "acc")) (EApp (EVar "Ok") (EApp (EVar "reverseL") (EVar "acc"))))
(DFunDef false "balSpliceGo" ((PVar "vs") (PList) PWild PWild) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: test/gates.toml has fewer [[gate]] shard lines than entries (")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "vs"))))) (ELit (LString " unplaced)")))))
(DFunDef false "balSpliceGo" ((PVar "vs") (PCons (PVar "l") (PVar "ls")) (PVar "inGate") (PVar "acc")) (EIf (EBinOp "==" (EVar "l") (ELit (LString "[[gate]]"))) (EApp (EApp (EApp (EApp (EVar "balSpliceGo") (EVar "vs")) (EVar "ls")) (EVar "True")) (EBinOp "::" (EVar "l") (EVar "acc"))) (EIf (EBinOp "==" (EVar "l") (ELit (LString "[[shard]]"))) (EApp (EApp (EApp (EApp (EVar "balSpliceGo") (EVar "vs")) (EVar "ls")) (EVar "False")) (EBinOp "::" (EVar "l") (EVar "acc"))) (EIf (EBinOp "&&" (EVar "inGate") (EApp (EApp (EVar "startsWith") (ELit (LString "shard = \""))) (EVar "l"))) (EMatch (EVar "vs") (arm (PList) () (EApp (EVar "Err") (ELit (LString "medaka gate balance: test/gates.toml has more [[gate]] shard lines than entries")))) (arm (PCons (PVar "v") (PVar "rest")) () (EApp (EApp (EApp (EApp (EVar "balSpliceGo") (EVar "rest")) (EVar "ls")) (EVar "inGate")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "shard = \"")) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString "\""))) (EVar "acc"))))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "balSpliceGo") (EVar "vs")) (EVar "ls")) (EVar "inGate")) (EBinOp "::" (EVar "l") (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig true "balNewText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "String")))))))
(DFunDef false "balNewText" ((PVar "regPath") (PVar "regSrc") (PVar "baseSrc")) (EMatch (EApp (EVar "parseRegistry") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "gates")) () (EMatch (EApp (EVar "parseShards") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "shs")) () (EMatch (EApp (EVar "parseCostBaseline") (EVar "baseSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "base")) () (EMatch (EApp (EVar "parseCostRuns") (EVar "baseSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "runsRead")) () (EMatch (EApp (EApp (EVar "balUnknownRows") (EVar "shs")) (EVar "gates")) (arm (PCons (PVar "b") (PVar "bs")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EMethodRef "display") (EVar "regPath"))) (ELit (LString ": gate(s) name a shard with no [[shard]] row: "))) (EApp (EMethodRef "display") (EApp (EVar "joinSpace") (EBinOp "::" (EVar "b") (EVar "bs"))))) (ELit (LString ""))))) (arm (PList) () (EMatch (EApp (EApp (EVar "balUncosted") (EVar "base")) (EVar "gates")) (arm (PCons (PVar "u") (PVar "us")) () (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EBinOp "::" (EVar "u") (EVar "us")))))) (ELit (LString " schedulable gate(s) have no row in the cost baseline:\n"))) (EApp (EVar "joinNl") (EApp (EVar "balIndent") (EBinOp "::" (EVar "u") (EVar "us")))) (ELit (LString "\n  Refusing to pack: a missing cost is not a cheap gate, it is an\n")) (ELit (LString "  unknown one, and treating it as 0 would pile it onto the lightest row.\n")) (ELit (LString "  Re-ingest the baseline (test/gate_cost_ingest.sh) or fix the gate's `run`.\n")))))) (arm (PList) () (EMatch (EApp (EApp (EVar "balPinErrors") (EVar "gates")) (EVar "shs")) (arm (PCons (PVar "e") (PVar "es")) () (EApp (EVar "Err") (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EMethodRef "display") (EVar "regPath"))) (ELit (LString ": a closed row's membership does not match its declared `pinned_gates`:\n"))) (EApp (EVar "joinNl") (EApp (EVar "balIndent") (EBinOp "::" (EVar "e") (EVar "es")))) (ELit (LString "\n  A `full_cores` row is CLOSED: the packer moves nothing onto it and\n")) (ELit (LString "  nothing off it, so its members are the one `shard` value no cost\n")) (ELit (LString "  measurement derives.  They are DECLARED in that [[shard]] row's\n")) (ELit (LString "  `pinned_gates` and checked against the registry in both directions,\n")) (ELit (LString "  so a hand-moved `shard` cannot be adopted as the new pin.\n")) (ELit (LString "  Repair the gate's `shard`; change `pinned_gates` only when the row's\n")) (ELit (LString "  membership is genuinely meant to differ, and say why in its rationale\n")) (ELit (LString "  file (docs/ops/GATE-REGISTRY-DESIGN.md §2).\n")))))) (arm (PList) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "balCompute") (EVar "regPath")) (EVar "gates")) (EVar "shs")) (EVar "base")) (EVar "runsRead")) (EVar "regSrc")))))))))))))))))
(DTypeSig false "balIndent" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "balIndent" ((PList)) (EListLit))
(DFunDef false "balIndent" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "    ")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString ""))) (EApp (EVar "balIndent") (EVar "xs"))))
(DTypeSig false "balCompute" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "String"))))))))))
(DFunDef false "balCompute" ((PVar "regPath") (PVar "gates") (PVar "shs") (PVar "base") (PVar "runs") (PVar "regSrc")) (EBlock (DoLet false false (PVar "cs") (EApp (EApp (EVar "balCands") (EVar "base")) (EVar "gates"))) (DoLet false false (PTuple PWild (PVar "curRows")) (EApp (EApp (EVar "balCurrent") (EApp (EVar "balSortCands") (EVar "cs"))) (EApp (EApp (EVar "balRows") (EVar "runs")) (EVar "shs")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "balTarget") (EVar "True")) (EVar "cs")) (EApp (EApp (EVar "balRows") (EVar "runs")) (EVar "shs"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PTuple (PVar "ps") (PVar "rows"))) () (EBlock (DoLet false false (PVar "illegal") (EApp (EVar "not") (EApp (EApp (EVar "balCurrentLegal") (EVar "cs")) (EVar "curRows")))) (DoLet false false (PVar "gains") (EBinOp "<" (EBinOp "*" (EApp (EVar "balPole") (EVar "rows")) (ELit (LInt 100))) (EBinOp "*" (EApp (EVar "balPole") (EVar "curRows")) (EBinOp "-" (ELit (LInt 100)) (EVar "balMarginPct"))))) (DoLet false false (PVar "moved") (EBinOp ">" (EApp (EVar "balMoved") (EVar "ps")) (ELit (LInt 0)))) (DoLet false false (PVar "label") (EIf (EVar "illegal") (ELit (LString "rebalanced (the committed assignment ran a gate on a row lacking its toolchain)")) (EIf (EVar "moved") (ELit (LString "rebalanced")) (ELit (LString "unchanged (the committed assignment is already the derived one)"))))) (DoLet false false (PVar "head") (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate balance: ")) (EApp (EMethodRef "display") (EVar "regPath"))) (ELit (LString "\n"))) (EApp (EApp (EApp (EApp (EApp (EVar "balReport") (EVar "label")) (EVar "cs")) (EVar "rows")) (EVar "ps")) (EVar "runs")) (EApp (EVar "balThinLine") (EVar "base")) (EApp (EApp (EApp (EVar "balOosBlock") (EVar "base")) (EVar "cs")) (EVar "runs")) (EApp (EApp (EApp (EApp (EVar "balStabLine") (EVar "cs")) (EApp (EApp (EVar "balRows") (EVar "runs")) (EVar "shs"))) (EVar "ps")) (EVar "rows")) (EBinOp "++" (EBinOp "++" (ELit (LString "  hysteresis: a move needs a pole gain of more than ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "balMarginPct")))) (ELit (LString "%"))) (EApp (EApp (EApp (EVar "balBandNote") (EVar "illegal")) (EVar "gains")) (EVar "moved")) (EBinOp "++" (EBinOp "++" (ELit (LString "\n  budget pole/floor ")) (EApp (EMethodRef "display") (EApp (EVar "balMilli") (EVar "balTargetMilli")))) (ELit (LString ""))) (EIf (EBinOp "<=" (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rows")) (EVar "balTargetMilli")) (ELit (LString " — MET\n")) (ELit (LString " — MISSED\n"))) (EApp (EVar "balMoveLine") (EVar "ps")) (ELit (LString "  calibration — last recorded CI wall clock vs this model's prediction for the COMMITTED assignment:\n")) (EApp (EVar "joinNl") (EApp (EApp (EApp (EVar "balCalibLines") (EVar "cs")) (EVar "curRows")) (EVar "runs"))) (ELit (LString "\n"))))) (DoExpr (EMatch (EApp (EApp (EVar "balEnforce") (EVar "cs")) (EVar "rows")) (arm (PCon "Some" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "balSplice") (EApp (EApp (EVar "balShardValues") (EVar "gates")) (EVar "ps"))) (EApp (EVar "splitNl") (EVar "regSrc"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "outLines")) () (EApp (EVar "Ok") (ETuple (EVar "head") (EApp (EVar "joinNl") (EVar "outLines")))))))))))))))
(DTypeSig false "budgetOverridePrefix" (TyCon "String"))
(DFunDef false "budgetOverridePrefix" () (ELit (LString "Gate-Budget-Override: ")))
(DTypeSig false "budgetOverrideTokens" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "budgetOverrideTokens" ((PVar "msg")) (EApp (EVar "budgetTokensFromLines") (EApp (EVar "splitNl") (EVar "msg"))))
(DTypeSig false "budgetTokensFromLines" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "budgetTokensFromLines" ((PList)) (EListLit))
(DFunDef false "budgetTokensFromLines" ((PCons (PVar "l") (PVar "ls"))) (EIf (EApp (EApp (EVar "startsWith") (EVar "budgetOverridePrefix")) (EApp (EVar "stringTrim") (EVar "l"))) (EBinOp "::" (EApp (EVar "budgetFirstWord") (EApp (EVar "stringTrim") (EApp (EApp (EVar "budgetDropPrefix") (EVar "budgetOverridePrefix")) (EApp (EVar "stringTrim") (EVar "l"))))) (EApp (EVar "budgetTokensFromLines") (EVar "ls"))) (EIf (EVar "otherwise") (EApp (EVar "budgetTokensFromLines") (EVar "ls")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "budgetDropPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "budgetDropPrefix" ((PVar "pre") (PVar "s")) (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "pre"))) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")))
(DTypeSig false "budgetFirstWord" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "budgetFirstWord" ((PVar "s")) (EMatch (EApp (EApp (EVar "splitOnChar") (ELit (LChar " "))) (EVar "s")) (arm (PList) () (EVar "s")) (arm (PCons (PVar "w") PWild) () (EVar "w"))))
(DTypeSig false "budgetAcked" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "budgetAcked" ((PVar "commitMessage") (PVar "token")) (EApp (EApp (EVar "contains") (EVar "token")) (EApp (EVar "budgetOverrideTokens") (EVar "commitMessage"))))
(DTypeSig false "budgetCountUnacked" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Int"))))
(DFunDef false "budgetCountUnacked" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "budgetCountUnacked" ((PVar "commitMessage") (PCons (PVar "t") (PVar "ts"))) (EIf (EApp (EApp (EVar "budgetAcked") (EVar "commitMessage")) (EVar "t")) (EApp (EApp (EVar "budgetCountUnacked") (EVar "commitMessage")) (EVar "ts")) (EIf (EVar "otherwise") (EBinOp "+" (ELit (LInt 1)) (EApp (EApp (EVar "budgetCountUnacked") (EVar "commitMessage")) (EVar "ts"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "budgetUncostedNames" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "budgetUncostedNames" (PWild (PList)) (EListLit))
(DFunDef false "budgetUncostedNames" ((PVar "base") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EApp (EApp (EVar "budgetUncostedNames") (EVar "base")) (EVar "gs")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "costOf") (EFieldAccess (EVar "g") "run")) (EVar "base")) (arm (PCon "Some" PWild) () (EApp (EApp (EVar "budgetUncostedNames") (EVar "base")) (EVar "gs"))) (arm (PCon "None") () (EBinOp "::" (EFieldAccess (EVar "g") "name") (EApp (EApp (EVar "budgetUncostedNames") (EVar "base")) (EVar "gs"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "budgetUncostedTokens" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "budgetUncostedTokens" ((PList)) (EListLit))
(DFunDef false "budgetUncostedTokens" ((PCons (PVar "n") (PVar "ns"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "uncosted:")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ""))) (EApp (EVar "budgetUncostedTokens") (EVar "ns"))))
(DTypeSig false "budgetUncostedLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "budgetUncostedLines" (PWild (PList)) (EListLit))
(DFunDef false "budgetUncostedLines" ((PVar "commitMessage") (PCons (PVar "n") (PVar "ns"))) (EBlock (DoLet false false (PVar "tok") (EBinOp "++" (EBinOp "++" (ELit (LString "uncosted:")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "")))) (DoLet false false (PVar "ack") (EIf (EApp (EApp (EVar "budgetAcked") (EVar "commitMessage")) (EVar "tok")) (ELit (LString " [ACKNOWLEDGED]")) (ELit (LString "")))) (DoExpr (EBinOp "::" (EApp (EVar "stringConcat") (EListLit (EVar "n") (EVar "ack") (ELit (LString " — remedy: re-ingest the baseline (test/gate_cost_ingest.sh) so this")) (ELit (LString " gate gets a sample; the `cost` field is present, the packer just has")) (ELit (LString " no price yet, so there is nothing to declare or split here.")) (ELit (LString " To accept unpriced on purpose, paste:\n    Gate-Budget-Override: ")) (EVar "tok") (ELit (LString "\n")))) (EApp (EApp (EVar "budgetUncostedLines") (EVar "commitMessage")) (EVar "ns"))))))
(DTypeSig false "budgetTimeoutMs" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "budgetTimeoutMs" ((PVar "cost")) (EBinOp "*" (EApp (EApp (EVar "timeoutFor") (ELit (LInt 0))) (EVar "cost")) (ELit (LInt 1000))))
(DTypeSig false "budgetToleratedMs" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "budgetToleratedMs" ((PVar "cost")) (EBinOp "/" (EBinOp "*" (EApp (EVar "budgetTimeoutMs") (EVar "cost")) (ELit (LInt 1000))) (EVar "balTargetMilli")))
(DTypeSig false "budgetOverClassGates" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "Gate")))))
(DFunDef false "budgetOverClassGates" (PWild (PList)) (EListLit))
(DFunDef false "budgetOverClassGates" ((PVar "base") (PCons (PVar "g") (PVar "gs"))) (EIf (EBinOp "==" (EFieldAccess (EVar "g") "shard") (EVar "balOtherJob")) (EApp (EApp (EVar "budgetOverClassGates") (EVar "base")) (EVar "gs")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "costOf") (EFieldAccess (EVar "g") "run")) (EVar "base")) (arm (PCon "None") () (EApp (EApp (EVar "budgetOverClassGates") (EVar "base")) (EVar "gs"))) (arm (PCon "Some" (PVar "ms")) ((GBool (EBinOp ">" (EVar "ms") (EApp (EVar "budgetToleratedMs") (EFieldAccess (EVar "g") "cost"))))) (EBinOp "::" (EVar "g") (EApp (EApp (EVar "budgetOverClassGates") (EVar "base")) (EVar "gs")))) (arm PWild () (EApp (EApp (EVar "budgetOverClassGates") (EVar "base")) (EVar "gs")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "budgetOverClassTokens" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "budgetOverClassTokens" ((PList)) (EListLit))
(DFunDef false "budgetOverClassTokens" ((PCons (PVar "g") (PVar "gs"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "over-class:")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString ""))) (EApp (EVar "budgetOverClassTokens") (EVar "gs"))))
(DTypeSig false "budgetTimeoutRemedy" (TyCon "String"))
(DFunDef false "budgetTimeoutRemedy" () (ELit (LString "Re-classing a gate changes its CI kill timeout (cheap=300s / medium=900s / heavy=3600s, `timeoutFor`) — pick deliberately, not just to silence this gate.")))
(DTypeSig false "budgetOverClassLines" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "budgetOverClassLines" (PWild PWild (PList)) (EListLit))
(DFunDef false "budgetOverClassLines" ((PVar "base") (PVar "commitMessage") (PCons (PVar "g") (PVar "gs"))) (EBlock (DoLet false false (PVar "ms") (EMatch (EApp (EApp (EVar "costOf") (EFieldAccess (EVar "g") "run")) (EVar "base")) (arm (PCon "Some" (PVar "m")) () (EVar "m")) (arm (PCon "None") () (ELit (LInt 0))))) (DoLet false false (PVar "tok") (EBinOp "++" (EBinOp "++" (ELit (LString "over-class:")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString "")))) (DoLet false false (PVar "ack") (EIf (EApp (EApp (EVar "budgetAcked") (EVar "commitMessage")) (EVar "tok")) (ELit (LString " [ACKNOWLEDGED]")) (ELit (LString "")))) (DoExpr (EBinOp "::" (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "name"))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EFieldAccess (EVar "g") "cost"))) (ELit (LString ", measured "))) (EApp (EMethodRef "display") (EApp (EVar "balSecs") (EVar "ms")))) (ELit (LString ", tolerance-adjusted ceiling "))) (EApp (EVar "balSecs") (EApp (EVar "budgetToleratedMs") (EFieldAccess (EVar "g") "cost"))) (EBinOp "++" (EBinOp "++" (ELit (LString " of a ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EApp (EVar "timeoutFor") (ELit (LInt 0))) (EFieldAccess (EVar "g") "cost"))))) (ELit (LString "s timeout)"))) (EVar "ack") (ELit (LString " — remedy: declare a higher `cost` class, split the gate into cheaper")) (ELit (LString " pieces, or demote it with `tiers = [\"nightly\"]` so it leaves the")) (ELit (LString " merge-required path. ")) (EVar "budgetTimeoutRemedy") (ELit (LString " To accept the current cost on purpose, paste:\n    Gate-Budget-Override: ")) (EVar "tok") (ELit (LString "\n")))) (EApp (EApp (EApp (EVar "budgetOverClassLines") (EVar "base")) (EVar "commitMessage")) (EVar "gs"))))))
(DTypeSig false "budgetPoleFactor" (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "List") (TyCon "Shard")) (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyApp (TyCon "List") (TyCon "RunRecord")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "budgetPoleFactor" ((PVar "gates") (PVar "shs") (PVar "base") (PVar "runs")) (EBlock (DoLet false false (PVar "cs") (EApp (EApp (EVar "balCands") (EVar "base")) (EVar "gates"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "balTarget") (EVar "True")) (EVar "cs")) (EApp (EApp (EVar "balRows") (EVar "runs")) (EVar "shs"))) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EVar "m"))) (arm (PCon "Ok" (PTuple PWild (PVar "rows"))) () (EBlock (DoLet false false (PVar "factor") (EApp (EApp (EVar "balFactorMilli") (EVar "cs")) (EVar "rows"))) (DoExpr (EIf (EBinOp "<=" (EVar "factor") (EVar "balTargetMilli")) (EApp (EVar "Ok") (EVar "None")) (EApp (EVar "Ok") (EApp (EVar "Some") (EVar "factor")))))))))))
(DTypeSig false "budgetPoleFloorLines" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "budgetPoleFloorLines" (PWild (PCon "None")) (EListLit))
(DFunDef false "budgetPoleFloorLines" ((PVar "commitMessage") (PCon "Some" (PVar "factor"))) (EBlock (DoLet false false (PVar "tok") (ELit (LString "pole-floor"))) (DoLet false false (PVar "ack") (EIf (EApp (EApp (EVar "budgetAcked") (EVar "commitMessage")) (EVar "tok")) (ELit (LString " [ACKNOWLEDGED]")) (ELit (LString "")))) (DoExpr (EBinOp "::" (EApp (EVar "stringConcat") (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "projected pole/floor ")) (EApp (EMethodRef "display") (EApp (EVar "balMilli") (EVar "factor")))) (ELit (LString " exceeds the budget "))) (EApp (EMethodRef "display") (EApp (EVar "balMilli") (EVar "balTargetMilli")))) (ELit (LString " (S-4)"))) (EVar "ack") (ELit (LString " — remedy: run `medaka gate balance` to see which row or gate needs to")) (ELit (LString " shrink, split the pole gate, or demote a heavy gate to")) (ELit (LString " `tiers = [\"nightly\"]`. To accept the current pole/floor on purpose, paste:\n    Gate-Budget-Override: ")) (EVar "tok") (ELit (LString "\n")))) (EListLit)))))
(DTypeSig false "budgetIndent" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "budgetIndent" ((PList)) (EListLit))
(DFunDef false "budgetIndent" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (ELit (LString "  ")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString ""))) (EApp (EVar "budgetIndent") (EVar "xs"))))
(DTypeSig false "budgetSection" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "budgetSection" (PWild (PList)) (ELit (LString "")))
(DFunDef false "budgetSection" ((PVar "title") (PVar "lines")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "title"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "lines"))))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EVar "joinNl") (EApp (EVar "budgetIndent") (EVar "lines"))))) (ELit (LString "\n\n"))))
(DTypeSig false "budgetReport" (TyFun (TyApp (TyCon "List") (TyCon "GateCost")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Gate")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))))))
(DFunDef false "budgetReport" ((PVar "base") (PVar "commitMessage") (PVar "uncosted") (PVar "overClass") (PVar "poleFactorOpt")) (EBlock (DoLet false false (PVar "aLines") (EApp (EApp (EVar "budgetUncostedLines") (EVar "commitMessage")) (EVar "uncosted"))) (DoLet false false (PVar "bLines") (EApp (EApp (EApp (EVar "budgetOverClassLines") (EVar "base")) (EVar "commitMessage")) (EVar "overClass"))) (DoLet false false (PVar "cLines") (EApp (EApp (EVar "budgetPoleFloorLines") (EVar "commitMessage")) (EVar "poleFactorOpt"))) (DoLet false false (PVar "aUnacked") (EApp (EApp (EVar "budgetCountUnacked") (EVar "commitMessage")) (EApp (EVar "budgetUncostedTokens") (EVar "uncosted")))) (DoLet false false (PVar "bUnacked") (EApp (EApp (EVar "budgetCountUnacked") (EVar "commitMessage")) (EApp (EVar "budgetOverClassTokens") (EVar "overClass")))) (DoLet false false (PVar "cCount") (EMatch (EVar "poleFactorOpt") (arm (PCon "None") () (ELit (LInt 0))) (arm (PCon "Some" PWild) () (ELit (LInt 1))))) (DoLet false false (PVar "cUnacked") (EIf (EBinOp "==" (EVar "cCount") (ELit (LInt 0))) (ELit (LInt 0)) (EIf (EApp (EApp (EVar "budgetAcked") (EVar "commitMessage")) (ELit (LString "pole-floor"))) (ELit (LInt 0)) (ELit (LInt 1))))) (DoLet false false (PVar "total") (EBinOp "+" (EBinOp "+" (EApp (EVar "listLen") (EVar "uncosted")) (EApp (EVar "listLen") (EVar "overClass"))) (EVar "cCount"))) (DoLet false false (PVar "unacked") (EBinOp "+" (EBinOp "+" (EVar "aUnacked") (EVar "bUnacked")) (EVar "cUnacked"))) (DoLet false false (PVar "body") (EApp (EVar "stringConcat") (EListLit (EApp (EApp (EVar "budgetSection") (ELit (LString "no cost baseline entry (clause a)"))) (EVar "aLines")) (EApp (EApp (EVar "budgetSection") (ELit (LString "over declared class, tolerance-adjusted (clause b)"))) (EVar "bLines")) (EApp (EApp (EVar "budgetSection") (ELit (LString "projected pole/floor over budget (clause c)"))) (EVar "cLines"))))) (DoExpr (EIf (EBinOp "==" (EVar "total") (ELit (LInt 0))) (EApp (EVar "Ok") (ELit (LString "medaka gate budget: OK — 0 violations.\n"))) (EIf (EBinOp "==" (EVar "unacked") (ELit (LInt 0))) (EApp (EVar "Ok") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "body"))) (ELit (LString "medaka gate budget: "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "total")))) (ELit (LString " violation(s), all acknowledged by commit-message trailer — OK.\n")))) (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "body"))) (ELit (LString "medaka gate budget: FAIL — "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "unacked")))) (ELit (LString " of "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "total")))) (ELit (LString " violation(s) not acknowledged. Paste the `Gate-Budget-Override:` trailer(s) shown above onto your commit message to accept them on purpose.\n")))))))))
(DTypeSig true "budgetOutput" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String")))))))
(DFunDef false "budgetOutput" ((PVar "regPath") (PVar "regSrc") (PVar "baseSrc") (PVar "commitMessage")) (EMatch (EApp (EVar "parseRegistry") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "gates")) () (EMatch (EApp (EVar "parseShards") (EVar "regSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "shs")) () (EMatch (EApp (EVar "parseCostBaseline") (EVar "baseSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "base")) () (EMatch (EApp (EVar "parseCostRuns") (EVar "baseSrc")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString ""))))) (arm (PCon "Ok" (PVar "runs")) () (EMatch (EApp (EApp (EVar "balUnknownRows") (EVar "shs")) (EVar "gates")) (arm (PCons (PVar "u") (PVar "us")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EMethodRef "display") (EVar "regPath"))) (ELit (LString ": gate(s) name a shard with no [[shard]] row: "))) (EApp (EMethodRef "display") (EApp (EVar "joinSpace") (EBinOp "::" (EVar "u") (EVar "us"))))) (ELit (LString "\n"))))) (arm (PList) () (EBlock (DoLet false false (PVar "uncosted") (EApp (EApp (EVar "budgetUncostedNames") (EVar "base")) (EVar "gates"))) (DoLet false false (PVar "overClass") (EApp (EApp (EVar "budgetOverClassGates") (EVar "base")) (EVar "gates"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "budgetPoleFactor") (EVar "gates")) (EVar "shs")) (EVar "base")) (EVar "runs")) (arm (PCon "Err" (PVar "m")) () (EApp (EVar "Err") (EBinOp "++" (EBinOp "++" (ELit (LString "medaka gate budget: ")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "\n"))))) (arm (PCon "Ok" (PVar "poleFactorOpt")) () (EApp (EApp (EApp (EApp (EApp (EVar "budgetReport") (EVar "base")) (EVar "commitMessage")) (EVar "uncosted")) (EVar "overClass")) (EVar "poleFactorOpt")))))))))))))))))
