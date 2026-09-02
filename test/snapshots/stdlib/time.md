# META
source_lines=442
stages=DESUGAR,MARK
# SOURCE
{- | Durations, a UTC calendar, and the clock.

   `Duration` is a span of time in whole milliseconds, built with `millis`,
   `seconds`, `minutes`, `hours`, and `days`. `DateTime` is a civil date
   and time in UTC; `fromEpochSeconds` and `toEpochSeconds` convert to and
   from Unix time, and `formatIso` and `parseIso` convert to and from ISO
   8601 text. There is no time zone support: every `DateTime` is UTC.

   `now`, `monotonic`, `elapsedSince`, and `sleep` read and wait on the
   host clock. Under the interpreter the clock returns fixed values and
   `sleep` does nothing; in a built program they use the real clock. -}

-- The calendar core (`fromEpochSeconds` / `toEpochSeconds`) uses Howard
-- Hinnant's days-from-civil / civil-from-days algorithm: pure Int
-- arithmetic, correct across leap years and for negative (pre-1970) epochs.
-- Medaka's `/` truncates toward zero, so the seconds→days split uses
-- `math.floorDiv`; Hinnant's own `era` adjustments already assume truncating
-- division, so they are used verbatim.
--
-- The three externs all carry the `<Clock>` effect.  `sleepMs` reuses
-- `<Clock>` for cohesion with the time domain; there is no `<Sleep>` label.

import math.{floorDiv}
import string.{sliceClamped, toInt}

-- # Durations

-- | A span of time, in whole milliseconds.
public export data Duration = Duration Int deriving (Eq, Ord, Debug)

{- | A duration of `n` milliseconds.

   > toMillis (millis 250)
   250 -}
export
millis : Int -> Duration
millis n = Duration n

{- | A duration of `n` seconds.

   > toMillis (seconds 5)
   5000 -}
export
seconds : Int -> Duration
seconds n = Duration (n * 1000)

{- | A duration of `n` minutes.

   > toSeconds (minutes 2)
   120 -}
export
minutes : Int -> Duration
minutes n = Duration (n * 60000)

{- | A duration of `n` hours.

   > toSeconds (hours 1)
   3600 -}
export
hours : Int -> Duration
hours n = Duration (n * 3600000)

{- | A duration of `n` days.

   > toSeconds (days 1)
   86400 -}
export
days : Int -> Duration
days n = Duration (n * 86400000)

-- | The duration in whole milliseconds.
export
toMillis : Duration -> Int
toMillis (Duration ms) = ms

{- | The duration in whole seconds, rounded towards zero.

   > toSeconds (millis 2500)
   2 -}
export
toSeconds : Duration -> Int
toSeconds (Duration ms) = ms / 1000

{- | The duration in whole minutes, rounded towards zero.

   > toMinutes (seconds 150)
   2 -}
export
toMinutes : Duration -> Int
toMinutes (Duration ms) = ms / 60000

{- | The duration in whole hours, rounded towards zero.

   > toHours (minutes 150)
   2 -}
export
toHours : Duration -> Int
toHours (Duration ms) = ms / 3600000

{- | The duration in whole days, rounded towards zero.

   > toDays (hours 50)
   2 -}
export
toDays : Duration -> Int
toDays (Duration ms) = ms / 86400000

{- | The sum of two durations.

   `++` on durations is the same operation.

   > toMillis (addDuration (seconds 1) (millis 500))
   1500 -}
export
addDuration : Duration -> Duration -> Duration
addDuration (Duration a) (Duration b) = Duration (a + b)

{- | The first duration less the second.

   > toMillis (subDuration (seconds 2) (millis 500))
   1500 -}
export
subDuration : Duration -> Duration -> Duration
subDuration (Duration a) (Duration b) = Duration (a - b)

-- # Dates and times

{- | A civil date and time in UTC.

   `month` runs from 1 to 12 and `day` from 1 to 31. Values compare in
   field order, which is chronological order for valid dates. -}
public export data DateTime = DateTime {
  year : Int,
  month : Int,
  day : Int,
  hour : Int,
  minute : Int,
  second : Int,
}
  deriving (Eq, Ord, Debug)

-- Days since 1970-01-01 for a civil (y, m, d).  Hinnant's days_from_civil.
daysFromCivil : Int -> Int -> Int -> Int
daysFromCivil y0 m d =
  let y = if m <= 2 then y0 - 1 else y0
  let era = (if y >= 0 then y else y - 399) / 400
  let yoe = y - era * 400
  let mp = if m > 2 then m - 3 else m + 9
  let doy = (153 * mp + 2) / 5 + d - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146097 + doe - 719468

-- Civil (year, month, day) for a day count since 1970-01-01.
-- Hinnant's civil_from_days.
civilFromDays : Int -> (Int, Int, Int)
civilFromDays z0 =
  let z = z0 + 719468
  let era = (if z >= 0 then z else z - 146096) / 146097
  let doe = z - era * 146097
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp = (5 * doy + 2) / 153
  let d = doy - (153 * mp + 2) / 5 + 1
  let m = if mp < 10 then mp + 3 else mp - 9
  (if m <= 2 then y + 1 else y, m, d)

{- | The UTC date and time at a number of seconds since the Unix epoch.

   Negative values, before 1970, work too.

   > formatIso (fromEpochSeconds 0)
   "1970-01-01T00:00:00Z"
   > formatIso (fromEpochSeconds 1000000000)
   "2001-09-09T01:46:40Z" -}
export
fromEpochSeconds : Int -> DateTime
fromEpochSeconds secs =
  let ds = floorDiv secs 86400
  let sod = secs - ds * 86400
  match civilFromDays ds
    (y, m, d) => DateTime {
      year = y,
      month = m,
      day = d,
      hour = sod / 3600,
      minute = (sod / 60) % 60,
      second = sod % 60,
    }

-- > formatIso (fromEpochSeconds 951782400)
-- "2000-02-29T00:00:00Z"
-- > formatIso (fromEpochSeconds 1709164800)
-- "2024-02-29T00:00:00Z"
-- > formatIso (fromEpochSeconds (0 - 1))
-- "1969-12-31T23:59:59Z"

{- | The number of seconds since the Unix epoch at a UTC date and time. The
   inverse of `fromEpochSeconds`.

   > toEpochSeconds (fromEpochSeconds 1000000000)
   1000000000 -}
export
toEpochSeconds : DateTime -> Int
toEpochSeconds dt =
  daysFromCivil dt.year dt.month dt.day * 86400
    + dt.hour * 3600
    + dt.minute * 60
    + dt.second

-- Zero-pad a non-negative Int to two digits.
pad2 : Int -> String
pad2 n = if n < 10 then "0" ++ intToString n else intToString n

-- Zero-pad a non-negative Int to (at least) four digits, for ISO years.
pad4 : Int -> String
pad4 n =
  if n < 10 then
    "000" ++ intToString n
  else if n < 100 then
    "00" ++ intToString n
  else if n < 1000 then
    "0" ++ intToString n
  else
    intToString n

{- | The date and time in ISO 8601 form, `YYYY-MM-DDThh:mm:ssZ`.

   > formatIso (DateTime { year = 2024, month = 3, day = 5, hour = 7, minute = 8, second = 9 })
   "2024-03-05T07:08:09Z" -}
export
formatIso : DateTime -> String
formatIso dt =
  "\{pad4 dt.year}-\{pad2 dt.month}-\{pad2 dt.day}T\{pad2 dt.hour}:\{pad2 dt.minute}:\{pad2 dt.second}Z"

{- Assemble a `DateTime` from six already-parsed fields, rejecting any that is
   out of civil range.  Split out of `parseIso` so the six `Option`s are
   destructured by ONE pattern match rather than nested `match`es. -}
isoFields : Option Int ->
  Option Int ->
  Option Int ->
  Option Int ->
  Option Int ->
  Option Int ->
  Option DateTime
isoFields (Some y) (Some mo) (Some d) (Some h) (Some mi) (Some sec) =
  if y >= 0
    && mo >= 1
    && mo <= 12
    && d >= 1
    && d <= 31
    && h <= 23
    && mi <= 59
    && sec <= 59 then
    Some DateTime {
      year = y,
      month = mo,
      day = d,
      hour = h,
      minute = mi,
      second = sec,
    }
  else
    None
isoFields _ _ _ _ _ _ = None

{- | The date and time written in ISO 8601 form, `YYYY-MM-DDThh:mm:ssZ`, or
   `None`.

   Exactly the form `formatIso` produces is accepted, and nothing else: no
   other time zone, no missing zero padding, no lowercase `t`.

   > map toEpochSeconds (parseIso "1970-01-01T00:00:00Z")
   Some 0
   > parseIso "2024-13-05T07:08:09Z"
   None -}
export
parseIso : String -> Option DateTime
parseIso s =
  if stringLength s == 20
    && sliceClamped 4 5 s == "-"
    && sliceClamped 7 8 s == "-"
    && sliceClamped 10 11 s == "T"
    && sliceClamped 13 14 s == ":"
    && sliceClamped 16 17 s == ":"
    && sliceClamped 19 20 s
      == "Z" then match (isoFields
    (toInt (sliceClamped 0 4 s))
    (toInt (sliceClamped 5 7 s))
    (toInt (sliceClamped 8 10 s))
    (toInt (sliceClamped 11 13 s))
    (toInt (sliceClamped 14 16 s))
    (toInt (sliceClamped 17 19 s)))
    Some dt => if formatIso dt == s then Some dt else None
    None => None
  else
    None

-- > parseIso "2024-03-05T07:08:09Z" == Some (DateTime { year = 2024, month = 3, day = 5, hour = 7, minute = 8, second = 9 })
-- True
-- > parseIso "2024-03-05 07:08:09Z"
-- None
-- > parseIso "not a date"
-- None

-- ── Instances ───────────────────────────────────────────────────────────
-- `Eq`/`Ord`/`Debug` are derived on both types (see the `data` decls).
-- Derived `Ord Duration` compares the stored millisecond count, so it agrees
-- with `toMillis`; derived `Ord DateTime` is lexicographic in field order
-- (year, month, day, hour, minute, second), so for civil-range values it
-- agrees with `toEpochSeconds`.  Both laws are property-tested below.

-- | `display` renders a duration as its millisecond count with an `ms`
-- suffix.
export impl Display Duration where
  display (Duration ms) = "\{intToString ms}ms"

-- | `display` renders a date and time in ISO 8601 form, like `formatIso`.
export impl Display DateTime where
  display dt = formatIso dt

-- | `++` on durations is `addDuration`.
export impl Semigroup Duration where
  append a b = addDuration a b

-- | `empty` is the zero duration.
export impl Monoid Duration where
  empty = Duration 0

-- # The clock

-- | The current wall-clock time in seconds since the Unix epoch.
export
now : Unit -> <Clock> Float
now u = wallTimeSec u

-- | The current UTC date and time, to the second.
export
nowDateTime : Unit -> <Clock> DateTime
nowDateTime u = fromEpochSeconds (floatToInt (wallTimeSec u))

{- | A reading of the monotonic clock, in seconds.

   The monotonic clock is unaffected by adjustments to the wall clock, so
   two readings measure an interval. See `elapsedSince`. -}
export
monotonic : Unit -> <Clock> Float
monotonic u = monotonicSec u

{- | The seconds elapsed since an earlier `monotonic` reading.

   Time a computation with `let t0 = monotonic ()`, the computation, then
   `elapsedSince t0`. -}
export
elapsedSince : Float -> <Clock> Float
elapsedSince start = monotonicSec () - start

{- | Pauses the program for a duration.

   `sleep (seconds 5)` and `sleep (millis 5)` say their unit. -}
export
sleep : Duration -> <Clock> Unit
sleep d = sleepMs (toMillis d)

-- | Pauses the program for `s` seconds. The same as `sleep (seconds s)`.
export
sleepSeconds : Int -> <Clock> Unit
sleepSeconds s = sleepMs (s * 1000)

-- Round-trip: epoch → civil → epoch is the identity (n constrained ≥ 0 to a
-- sane band; negatives are supported too, see the `fromEpochSeconds (0 - 1)`
-- doctest).
prop "epoch round-trips through the civil calendar" (n : Int) =
  let s = 1000000 + (if n < 0 then 0 - n else n) % 3000000000
  toEpochSeconds (fromEpochSeconds s) == s

-- A civil-range epoch second, for the DateTime laws below.
sane : Int -> Int
sane n = 1000000 + (if n < 0 then 0 - n else n) % 3000000000

-- LAW: `parseIso` is the exact inverse of `formatIso`: every value
-- `formatIso` can emit parses back to the SAME `DateTime`, and nothing else
-- parses at all.
prop "parseIso inverts formatIso" (n : Int) =
  let dt = fromEpochSeconds (sane n)
  parseIso (formatIso dt) == Some dt

prop "parseIso rejects a corrupted separator" (n : Int) =
  let iso = formatIso (fromEpochSeconds (sane n))
  parseIso (sliceClamped 0 10 iso ++ " " ++ sliceClamped 11 20 iso) == None

-- LAW: the five `Duration` constructors and the five projections are inverse
-- at their own unit, and each projection truncates toward zero.
prop "Duration projections invert their constructors" (n : Int) =
  let k = (if n < 0 then 0 - n else n) % 100000
  toMillis (millis k) == k
    && toSeconds (seconds k) == k
    && toMinutes (minutes k) == k
    && toHours (hours k) == k
    && toDays (days k) == k

prop "Duration projections are the coarser unit's floor" (n : Int) =
  let k = (if n < 0 then 0 - n else n) % 100000000
  let d = millis k
  toSeconds d == toMillis d / 1000
    && toMinutes d == toSeconds d / 60
    && toHours d == toMinutes d / 60
    && toDays d == toHours d / 24

-- LAW: derived `Ord Duration` must agree with `toMillis` ordering, and must
-- be consistent with `Eq`.
prop "Ord Duration agrees with toMillis" (a : Int) (b : Int) =
  compare (millis a) (millis b) == compare a b
    && millis a == millis b == (a == b)

-- LAW: derived `Ord DateTime` must agree with `toEpochSeconds` ordering on
-- civil-range values, and must be consistent with `Eq`.
prop "Ord DateTime agrees with toEpochSeconds" (a : Int) (b : Int) =
  let x = fromEpochSeconds (sane a)
  let y = fromEpochSeconds (sane b)
  compare x y == compare (toEpochSeconds x) (toEpochSeconds y)
    && x == y == (toEpochSeconds x == toEpochSeconds y)

-- LAW: `Display DateTime` IS `formatIso`; `Display Duration` renders the
-- millisecond count, so it round-trips through `toMillis`.
prop "Display DateTime is formatIso" (n : Int) =
  let dt = fromEpochSeconds (sane n)
  display dt == formatIso dt

prop "Display Duration renders the millisecond count" (n : Int) =
  display (millis n) == intToString n ++ "ms"

-- LAW: `Semigroup`/`Monoid Duration`: associativity plus a two-sided
-- identity.  These are the laws that license the instances at all.
prop "Semigroup Duration is associative" (a : Int) (b : Int) (c : Int) =
  let l = append (append (millis a) (millis b)) (millis c)
  let r = append (millis a) (append (millis b) (millis c))
  l == r

prop "Monoid Duration: empty is a two-sided identity" (n : Int) =
  let d = millis n
  append d empty == d && append empty d == d
# DESUGAR
(DUse false (UseGroup ("math") ((mem "floorDiv" false))))
(DUse false (UseGroup ("string") ((mem "sliceClamped" false) (mem "toInt" false))))
(DData Public "Duration" () ((variant "Duration" (ConPos (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "Duration")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Duration" (PVar "__a0")) (PCon "Duration" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")))))))
(DImpl true "Ord" ((TyCon "Duration")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Duration" (PVar "__a0")) (PCon "Duration" (PVar "__b0"))) () (EApp (EApp (EVar "compare") (EVar "__a0")) (EVar "__b0")))))))
(DImpl true "Debug" ((TyCon "Duration")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Duration" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Duration ")) (EApp (EVar "derivedShowWrap") (EApp (EVar "debug") (EVar "__a0")))))))))
(DTypeSig true "millis" (TyFun (TyCon "Int") (TyCon "Duration")))
(DFunDef false "millis" ((PVar "n")) (EApp (EVar "Duration") (EVar "n")))
(DTypeSig true "seconds" (TyFun (TyCon "Int") (TyCon "Duration")))
(DFunDef false "seconds" ((PVar "n")) (EApp (EVar "Duration") (EBinOp "*" (EVar "n") (ELit (LInt 1000)))))
(DTypeSig true "minutes" (TyFun (TyCon "Int") (TyCon "Duration")))
(DFunDef false "minutes" ((PVar "n")) (EApp (EVar "Duration") (EBinOp "*" (EVar "n") (ELit (LInt 60000)))))
(DTypeSig true "hours" (TyFun (TyCon "Int") (TyCon "Duration")))
(DFunDef false "hours" ((PVar "n")) (EApp (EVar "Duration") (EBinOp "*" (EVar "n") (ELit (LInt 3600000)))))
(DTypeSig true "days" (TyFun (TyCon "Int") (TyCon "Duration")))
(DFunDef false "days" ((PVar "n")) (EApp (EVar "Duration") (EBinOp "*" (EVar "n") (ELit (LInt 86400000)))))
(DTypeSig true "toMillis" (TyFun (TyCon "Duration") (TyCon "Int")))
(DFunDef false "toMillis" ((PCon "Duration" (PVar "ms"))) (EVar "ms"))
(DTypeSig true "toSeconds" (TyFun (TyCon "Duration") (TyCon "Int")))
(DFunDef false "toSeconds" ((PCon "Duration" (PVar "ms"))) (EBinOp "/" (EVar "ms") (ELit (LInt 1000))))
(DTypeSig true "toMinutes" (TyFun (TyCon "Duration") (TyCon "Int")))
(DFunDef false "toMinutes" ((PCon "Duration" (PVar "ms"))) (EBinOp "/" (EVar "ms") (ELit (LInt 60000))))
(DTypeSig true "toHours" (TyFun (TyCon "Duration") (TyCon "Int")))
(DFunDef false "toHours" ((PCon "Duration" (PVar "ms"))) (EBinOp "/" (EVar "ms") (ELit (LInt 3600000))))
(DTypeSig true "toDays" (TyFun (TyCon "Duration") (TyCon "Int")))
(DFunDef false "toDays" ((PCon "Duration" (PVar "ms"))) (EBinOp "/" (EVar "ms") (ELit (LInt 86400000))))
(DTypeSig true "addDuration" (TyFun (TyCon "Duration") (TyFun (TyCon "Duration") (TyCon "Duration"))))
(DFunDef false "addDuration" ((PCon "Duration" (PVar "a")) (PCon "Duration" (PVar "b"))) (EApp (EVar "Duration") (EBinOp "+" (EVar "a") (EVar "b"))))
(DTypeSig true "subDuration" (TyFun (TyCon "Duration") (TyFun (TyCon "Duration") (TyCon "Duration"))))
(DFunDef false "subDuration" ((PCon "Duration" (PVar "a")) (PCon "Duration" (PVar "b"))) (EApp (EVar "Duration") (EBinOp "-" (EVar "a") (EVar "b"))))
(DData Public "DateTime" () ((variant "DateTime" (ConNamed (field "year" (TyCon "Int")) (field "month" (TyCon "Int")) (field "day" (TyCon "Int")) (field "hour" (TyCon "Int")) (field "minute" (TyCon "Int")) (field "second" (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "DateTime")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "DateTime" ((rf "year" (PVar "__a0")) (rf "month" (PVar "__a1")) (rf "day" (PVar "__a2")) (rf "hour" (PVar "__a3")) (rf "minute" (PVar "__a4")) (rf "second" (PVar "__a5"))) false) (PRec "DateTime" ((rf "year" (PVar "__b0")) (rf "month" (PVar "__b1")) (rf "day" (PVar "__b2")) (rf "hour" (PVar "__b3")) (rf "minute" (PVar "__b4")) (rf "second" (PVar "__b5"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EVar "eq") (EVar "__a4")) (EVar "__b4"))) (EApp (EApp (EVar "eq") (EVar "__a5")) (EVar "__b5"))))))))
(DImpl true "Ord" ((TyCon "DateTime")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "DateTime" ((rf "year" (PVar "__a0")) (rf "month" (PVar "__a1")) (rf "day" (PVar "__a2")) (rf "hour" (PVar "__a3")) (rf "minute" (PVar "__a4")) (rf "second" (PVar "__a5"))) false) (PRec "DateTime" ((rf "year" (PVar "__b0")) (rf "month" (PVar "__b1")) (rf "day" (PVar "__b2")) (rf "hour" (PVar "__b3")) (rf "minute" (PVar "__b4")) (rf "second" (PVar "__b5"))) false)) () (EMatch (EApp (EApp (EVar "compare") (EVar "__a0")) (EVar "__b0")) (arm (PCon "Eq") () (EMatch (EApp (EApp (EVar "compare") (EVar "__a1")) (EVar "__b1")) (arm (PCon "Eq") () (EMatch (EApp (EApp (EVar "compare") (EVar "__a2")) (EVar "__b2")) (arm (PCon "Eq") () (EMatch (EApp (EApp (EVar "compare") (EVar "__a3")) (EVar "__b3")) (arm (PCon "Eq") () (EMatch (EApp (EApp (EVar "compare") (EVar "__a4")) (EVar "__b4")) (arm (PCon "Eq") () (EApp (EApp (EVar "compare") (EVar "__a5")) (EVar "__b5"))) (arm (PVar "__c") () (EVar "__c")))) (arm (PVar "__c") () (EVar "__c")))) (arm (PVar "__c") () (EVar "__c")))) (arm (PVar "__c") () (EVar "__c")))) (arm (PVar "__c") () (EVar "__c"))))))))
(DImpl true "Debug" ((TyCon "DateTime")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "DateTime" ((rf "year" (PVar "__a0")) (rf "month" (PVar "__a1")) (rf "day" (PVar "__a2")) (rf "hour" (PVar "__a3")) (rf "minute" (PVar "__a4")) (rf "second" (PVar "__a5"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "DateTime {")) (ELit (LString " year = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", month = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", day = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString ", hour = "))) (EApp (EVar "debug") (EVar "__a3"))) (ELit (LString ", minute = "))) (EApp (EVar "debug") (EVar "__a4"))) (ELit (LString ", second = "))) (EApp (EVar "debug") (EVar "__a5"))) (ELit (LString " }"))))))))
(DTypeSig false "daysFromCivil" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "daysFromCivil" ((PVar "y0") (PVar "m") (PVar "d")) (EBlock (DoLet false false (PVar "y") (EIf (EBinOp "<=" (EVar "m") (ELit (LInt 2))) (EBinOp "-" (EVar "y0") (ELit (LInt 1))) (EVar "y0"))) (DoLet false false (PVar "era") (EBinOp "/" (EIf (EBinOp ">=" (EVar "y") (ELit (LInt 0))) (EVar "y") (EBinOp "-" (EVar "y") (ELit (LInt 399)))) (ELit (LInt 400)))) (DoLet false false (PVar "yoe") (EBinOp "-" (EVar "y") (EBinOp "*" (EVar "era") (ELit (LInt 400))))) (DoLet false false (PVar "mp") (EIf (EBinOp ">" (EVar "m") (ELit (LInt 2))) (EBinOp "-" (EVar "m") (ELit (LInt 3))) (EBinOp "+" (EVar "m") (ELit (LInt 9))))) (DoLet false false (PVar "doy") (EBinOp "-" (EBinOp "+" (EBinOp "/" (EBinOp "+" (EBinOp "*" (ELit (LInt 153)) (EVar "mp")) (ELit (LInt 2))) (ELit (LInt 5))) (EVar "d")) (ELit (LInt 1)))) (DoLet false false (PVar "doe") (EBinOp "+" (EBinOp "-" (EBinOp "+" (EBinOp "*" (EVar "yoe") (ELit (LInt 365))) (EBinOp "/" (EVar "yoe") (ELit (LInt 4)))) (EBinOp "/" (EVar "yoe") (ELit (LInt 100)))) (EVar "doy"))) (DoExpr (EBinOp "-" (EBinOp "+" (EBinOp "*" (EVar "era") (ELit (LInt 146097))) (EVar "doe")) (ELit (LInt 719468))))))
(DTypeSig false "civilFromDays" (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "civilFromDays" ((PVar "z0")) (EBlock (DoLet false false (PVar "z") (EBinOp "+" (EVar "z0") (ELit (LInt 719468)))) (DoLet false false (PVar "era") (EBinOp "/" (EIf (EBinOp ">=" (EVar "z") (ELit (LInt 0))) (EVar "z") (EBinOp "-" (EVar "z") (ELit (LInt 146096)))) (ELit (LInt 146097)))) (DoLet false false (PVar "doe") (EBinOp "-" (EVar "z") (EBinOp "*" (EVar "era") (ELit (LInt 146097))))) (DoLet false false (PVar "yoe") (EBinOp "/" (EBinOp "-" (EBinOp "+" (EBinOp "-" (EVar "doe") (EBinOp "/" (EVar "doe") (ELit (LInt 1460)))) (EBinOp "/" (EVar "doe") (ELit (LInt 36524)))) (EBinOp "/" (EVar "doe") (ELit (LInt 146096)))) (ELit (LInt 365)))) (DoLet false false (PVar "y") (EBinOp "+" (EVar "yoe") (EBinOp "*" (EVar "era") (ELit (LInt 400))))) (DoLet false false (PVar "doy") (EBinOp "-" (EVar "doe") (EBinOp "-" (EBinOp "+" (EBinOp "*" (ELit (LInt 365)) (EVar "yoe")) (EBinOp "/" (EVar "yoe") (ELit (LInt 4)))) (EBinOp "/" (EVar "yoe") (ELit (LInt 100)))))) (DoLet false false (PVar "mp") (EBinOp "/" (EBinOp "+" (EBinOp "*" (ELit (LInt 5)) (EVar "doy")) (ELit (LInt 2))) (ELit (LInt 153)))) (DoLet false false (PVar "d") (EBinOp "+" (EBinOp "-" (EVar "doy") (EBinOp "/" (EBinOp "+" (EBinOp "*" (ELit (LInt 153)) (EVar "mp")) (ELit (LInt 2))) (ELit (LInt 5)))) (ELit (LInt 1)))) (DoLet false false (PVar "m") (EIf (EBinOp "<" (EVar "mp") (ELit (LInt 10))) (EBinOp "+" (EVar "mp") (ELit (LInt 3))) (EBinOp "-" (EVar "mp") (ELit (LInt 9))))) (DoExpr (ETuple (EIf (EBinOp "<=" (EVar "m") (ELit (LInt 2))) (EBinOp "+" (EVar "y") (ELit (LInt 1))) (EVar "y")) (EVar "m") (EVar "d")))))
(DTypeSig true "fromEpochSeconds" (TyFun (TyCon "Int") (TyCon "DateTime")))
(DFunDef false "fromEpochSeconds" ((PVar "secs")) (EBlock (DoLet false false (PVar "ds") (EApp (EApp (EVar "floorDiv") (EVar "secs")) (ELit (LInt 86400)))) (DoLet false false (PVar "sod") (EBinOp "-" (EVar "secs") (EBinOp "*" (EVar "ds") (ELit (LInt 86400))))) (DoExpr (EMatch (EApp (EVar "civilFromDays") (EVar "ds")) (arm (PTuple (PVar "y") (PVar "m") (PVar "d")) () (ERecordCreate "DateTime" ((fa "year" (EVar "y")) (fa "month" (EVar "m")) (fa "day" (EVar "d")) (fa "hour" (EBinOp "/" (EVar "sod") (ELit (LInt 3600)))) (fa "minute" (EBinOp "%" (EBinOp "/" (EVar "sod") (ELit (LInt 60))) (ELit (LInt 60)))) (fa "second" (EBinOp "%" (EVar "sod") (ELit (LInt 60)))))))))))
(DTypeSig true "toEpochSeconds" (TyFun (TyCon "DateTime") (TyCon "Int")))
(DFunDef false "toEpochSeconds" ((PVar "dt")) (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EApp (EApp (EApp (EVar "daysFromCivil") (EFieldAccess (EVar "dt") "year")) (EFieldAccess (EVar "dt") "month")) (EFieldAccess (EVar "dt") "day")) (ELit (LInt 86400))) (EBinOp "*" (EFieldAccess (EVar "dt") "hour") (ELit (LInt 3600)))) (EBinOp "*" (EFieldAccess (EVar "dt") "minute") (ELit (LInt 60)))) (EFieldAccess (EVar "dt") "second")))
(DTypeSig false "pad2" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "pad2" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 10))) (EBinOp "++" (ELit (LString "0")) (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "intToString") (EVar "n"))))
(DTypeSig false "pad4" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "pad4" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 10))) (EBinOp "++" (ELit (LString "000")) (EApp (EVar "intToString") (EVar "n"))) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 100))) (EBinOp "++" (ELit (LString "00")) (EApp (EVar "intToString") (EVar "n"))) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 1000))) (EBinOp "++" (ELit (LString "0")) (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "intToString") (EVar "n"))))))
(DTypeSig true "formatIso" (TyFun (TyCon "DateTime") (TyCon "String")))
(DFunDef false "formatIso" ((PVar "dt")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "pad4") (EFieldAccess (EVar "dt") "year")))) (ELit (LString "-"))) (EApp (EVar "display") (EApp (EVar "pad2") (EFieldAccess (EVar "dt") "month")))) (ELit (LString "-"))) (EApp (EVar "display") (EApp (EVar "pad2") (EFieldAccess (EVar "dt") "day")))) (ELit (LString "T"))) (EApp (EVar "display") (EApp (EVar "pad2") (EFieldAccess (EVar "dt") "hour")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "pad2") (EFieldAccess (EVar "dt") "minute")))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EVar "pad2") (EFieldAccess (EVar "dt") "second")))) (ELit (LString "Z"))))
(DTypeSig false "isoFields" (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "DateTime")))))))))
(DFunDef false "isoFields" ((PCon "Some" (PVar "y")) (PCon "Some" (PVar "mo")) (PCon "Some" (PVar "d")) (PCon "Some" (PVar "h")) (PCon "Some" (PVar "mi")) (PCon "Some" (PVar "sec"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "y") (ELit (LInt 0))) (EBinOp ">=" (EVar "mo") (ELit (LInt 1)))) (EBinOp "<=" (EVar "mo") (ELit (LInt 12)))) (EBinOp ">=" (EVar "d") (ELit (LInt 1)))) (EBinOp "<=" (EVar "d") (ELit (LInt 31)))) (EBinOp "<=" (EVar "h") (ELit (LInt 23)))) (EBinOp "<=" (EVar "mi") (ELit (LInt 59)))) (EBinOp "<=" (EVar "sec") (ELit (LInt 59)))) (EApp (EVar "Some") (ERecordCreate "DateTime" ((fa "year" (EVar "y")) (fa "month" (EVar "mo")) (fa "day" (EVar "d")) (fa "hour" (EVar "h")) (fa "minute" (EVar "mi")) (fa "second" (EVar "sec"))))) (EVar "None")))
(DFunDef false "isoFields" (PWild PWild PWild PWild PWild PWild) (EVar "None"))
(DTypeSig true "parseIso" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "DateTime"))))
(DFunDef false "parseIso" ((PVar "s")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 20))) (EBinOp "==" (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 4))) (ELit (LInt 5))) (EVar "s")) (ELit (LString "-")))) (EBinOp "==" (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 7))) (ELit (LInt 8))) (EVar "s")) (ELit (LString "-")))) (EBinOp "==" (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 10))) (ELit (LInt 11))) (EVar "s")) (ELit (LString "T")))) (EBinOp "==" (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 13))) (ELit (LInt 14))) (EVar "s")) (ELit (LString ":")))) (EBinOp "==" (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 16))) (ELit (LInt 17))) (EVar "s")) (ELit (LString ":")))) (EBinOp "==" (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 19))) (ELit (LInt 20))) (EVar "s")) (ELit (LString "Z")))) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "isoFields") (EApp (EVar "toInt") (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 0))) (ELit (LInt 4))) (EVar "s")))) (EApp (EVar "toInt") (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 5))) (ELit (LInt 7))) (EVar "s")))) (EApp (EVar "toInt") (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 8))) (ELit (LInt 10))) (EVar "s")))) (EApp (EVar "toInt") (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 11))) (ELit (LInt 13))) (EVar "s")))) (EApp (EVar "toInt") (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 14))) (ELit (LInt 16))) (EVar "s")))) (EApp (EVar "toInt") (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 17))) (ELit (LInt 19))) (EVar "s")))) (arm (PCon "Some" (PVar "dt")) () (EIf (EBinOp "==" (EApp (EVar "formatIso") (EVar "dt")) (EVar "s")) (EApp (EVar "Some") (EVar "dt")) (EVar "None"))) (arm (PCon "None") () (EVar "None"))) (EVar "None")))
(DImpl true "Display" ((TyCon "Duration")) () ((im "display" ((PCon "Duration" (PVar "ms"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "ms")))) (ELit (LString "ms"))))))
(DImpl true "Display" ((TyCon "DateTime")) () ((im "display" ((PVar "dt")) (EApp (EVar "formatIso") (EVar "dt")))))
(DImpl true "Semigroup" ((TyCon "Duration")) () ((im "append" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "addDuration") (EVar "a")) (EVar "b")))))
(DImpl true "Monoid" ((TyCon "Duration")) () ((im "empty" () (EApp (EVar "Duration") (ELit (LInt 0))))))
(DTypeSig true "now" (TyFun (TyCon "Unit") (TyEffect ("Clock") None (TyCon "Float"))))
(DFunDef false "now" ((PVar "u")) (EApp (EVar "wallTimeSec") (EVar "u")))
(DTypeSig true "nowDateTime" (TyFun (TyCon "Unit") (TyEffect ("Clock") None (TyCon "DateTime"))))
(DFunDef false "nowDateTime" ((PVar "u")) (EApp (EVar "fromEpochSeconds") (EApp (EVar "floatToInt") (EApp (EVar "wallTimeSec") (EVar "u")))))
(DTypeSig true "monotonic" (TyFun (TyCon "Unit") (TyEffect ("Clock") None (TyCon "Float"))))
(DFunDef false "monotonic" ((PVar "u")) (EApp (EVar "monotonicSec") (EVar "u")))
(DTypeSig true "elapsedSince" (TyFun (TyCon "Float") (TyEffect ("Clock") None (TyCon "Float"))))
(DFunDef false "elapsedSince" ((PVar "start")) (EBinOp "-" (EApp (EVar "monotonicSec") (ELit LUnit)) (EVar "start")))
(DTypeSig true "sleep" (TyFun (TyCon "Duration") (TyEffect ("Clock") None (TyCon "Unit"))))
(DFunDef false "sleep" ((PVar "d")) (EApp (EVar "sleepMs") (EApp (EVar "toMillis") (EVar "d"))))
(DTypeSig true "sleepSeconds" (TyFun (TyCon "Int") (TyEffect ("Clock") None (TyCon "Unit"))))
(DFunDef false "sleepSeconds" ((PVar "s")) (EApp (EVar "sleepMs") (EBinOp "*" (EVar "s") (ELit (LInt 1000)))))
(DProp false "epoch round-trips through the civil calendar" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "s") (EBinOp "+" (ELit (LInt 1000000)) (EBinOp "%" (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n")) (ELit (LInt 3000000000))))) (DoExpr (EBinOp "==" (EApp (EVar "toEpochSeconds") (EApp (EVar "fromEpochSeconds") (EVar "s"))) (EVar "s")))))
(DTypeSig false "sane" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "sane" ((PVar "n")) (EBinOp "+" (ELit (LInt 1000000)) (EBinOp "%" (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n")) (ELit (LInt 3000000000)))))
(DProp false "parseIso inverts formatIso" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "dt") (EApp (EVar "fromEpochSeconds") (EApp (EVar "sane") (EVar "n")))) (DoExpr (EBinOp "==" (EApp (EVar "parseIso") (EApp (EVar "formatIso") (EVar "dt"))) (EApp (EVar "Some") (EVar "dt"))))))
(DProp false "parseIso rejects a corrupted separator" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "iso") (EApp (EVar "formatIso") (EApp (EVar "fromEpochSeconds") (EApp (EVar "sane") (EVar "n"))))) (DoExpr (EBinOp "==" (EApp (EVar "parseIso") (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 0))) (ELit (LInt 10))) (EVar "iso")) (ELit (LString " "))) (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 11))) (ELit (LInt 20))) (EVar "iso")))) (EVar "None")))))
(DProp false "Duration projections invert their constructors" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "k") (EBinOp "%" (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n")) (ELit (LInt 100000)))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "toMillis") (EApp (EVar "millis") (EVar "k"))) (EVar "k")) (EBinOp "==" (EApp (EVar "toSeconds") (EApp (EVar "seconds") (EVar "k"))) (EVar "k"))) (EBinOp "==" (EApp (EVar "toMinutes") (EApp (EVar "minutes") (EVar "k"))) (EVar "k"))) (EBinOp "==" (EApp (EVar "toHours") (EApp (EVar "hours") (EVar "k"))) (EVar "k"))) (EBinOp "==" (EApp (EVar "toDays") (EApp (EVar "days") (EVar "k"))) (EVar "k"))))))
(DProp false "Duration projections are the coarser unit's floor" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "k") (EBinOp "%" (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n")) (ELit (LInt 100000000)))) (DoLet false false (PVar "d") (EApp (EVar "millis") (EVar "k"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "toSeconds") (EVar "d")) (EBinOp "/" (EApp (EVar "toMillis") (EVar "d")) (ELit (LInt 1000)))) (EBinOp "==" (EApp (EVar "toMinutes") (EVar "d")) (EBinOp "/" (EApp (EVar "toSeconds") (EVar "d")) (ELit (LInt 60))))) (EBinOp "==" (EApp (EVar "toHours") (EVar "d")) (EBinOp "/" (EApp (EVar "toMinutes") (EVar "d")) (ELit (LInt 60))))) (EBinOp "==" (EApp (EVar "toDays") (EVar "d")) (EBinOp "/" (EApp (EVar "toHours") (EVar "d")) (ELit (LInt 24))))))))
(DProp false "Ord Duration agrees with toMillis" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "compare") (EApp (EVar "millis") (EVar "a"))) (EApp (EVar "millis") (EVar "b"))) (EApp (EApp (EVar "compare") (EVar "a")) (EVar "b"))) (EBinOp "==" (EBinOp "==" (EApp (EVar "millis") (EVar "a")) (EApp (EVar "millis") (EVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))))
(DProp false "Ord DateTime agrees with toEpochSeconds" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EBlock (DoLet false false (PVar "x") (EApp (EVar "fromEpochSeconds") (EApp (EVar "sane") (EVar "a")))) (DoLet false false (PVar "y") (EApp (EVar "fromEpochSeconds") (EApp (EVar "sane") (EVar "b")))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "compare") (EVar "x")) (EVar "y")) (EApp (EApp (EVar "compare") (EApp (EVar "toEpochSeconds") (EVar "x"))) (EApp (EVar "toEpochSeconds") (EVar "y")))) (EBinOp "==" (EBinOp "==" (EVar "x") (EVar "y")) (EBinOp "==" (EApp (EVar "toEpochSeconds") (EVar "x")) (EApp (EVar "toEpochSeconds") (EVar "y"))))))))
(DProp false "Display DateTime is formatIso" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "dt") (EApp (EVar "fromEpochSeconds") (EApp (EVar "sane") (EVar "n")))) (DoExpr (EBinOp "==" (EApp (EVar "display") (EVar "dt")) (EApp (EVar "formatIso") (EVar "dt"))))))
(DProp false "Display Duration renders the millisecond count" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EVar "display") (EApp (EVar "millis") (EVar "n"))) (EBinOp "++" (EApp (EVar "intToString") (EVar "n")) (ELit (LString "ms")))))
(DProp false "Semigroup Duration is associative" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int")) (pp "c" (TyCon "Int"))) (EBlock (DoLet false false (PVar "l") (EApp (EApp (EVar "append") (EApp (EApp (EVar "append") (EApp (EVar "millis") (EVar "a"))) (EApp (EVar "millis") (EVar "b")))) (EApp (EVar "millis") (EVar "c")))) (DoLet false false (PVar "r") (EApp (EApp (EVar "append") (EApp (EVar "millis") (EVar "a"))) (EApp (EApp (EVar "append") (EApp (EVar "millis") (EVar "b"))) (EApp (EVar "millis") (EVar "c"))))) (DoExpr (EBinOp "==" (EVar "l") (EVar "r")))))
(DProp false "Monoid Duration: empty is a two-sided identity" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "d") (EApp (EVar "millis") (EVar "n"))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EApp (EVar "append") (EVar "d")) (EVar "empty")) (EVar "d")) (EBinOp "==" (EApp (EApp (EVar "append") (EVar "empty")) (EVar "d")) (EVar "d"))))))
# MARK
(DUse false (UseGroup ("math") ((mem "floorDiv" false))))
(DUse false (UseGroup ("string") ((mem "sliceClamped" false) (mem "toInt" false))))
(DData Public "Duration" () ((variant "Duration" (ConPos (TyCon "Int")))) ())
(DImpl true "Eq" ((TyCon "Duration")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Duration" (PVar "__a0")) (PCon "Duration" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")))))))
(DImpl true "Ord" ((TyCon "Duration")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Duration" (PVar "__a0")) (PCon "Duration" (PVar "__b0"))) () (EApp (EApp (EMethodRef "compare") (EVar "__a0")) (EVar "__b0")))))))
(DImpl true "Debug" ((TyCon "Duration")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Duration" (PVar "__a0")) () (EBinOp "++" (ELit (LString "Duration ")) (EApp (EVar "derivedShowWrap") (EApp (EMethodRef "debug") (EVar "__a0")))))))))
(DTypeSig true "millis" (TyFun (TyCon "Int") (TyCon "Duration")))
(DFunDef false "millis" ((PVar "n")) (EApp (EVar "Duration") (EVar "n")))
(DTypeSig true "seconds" (TyFun (TyCon "Int") (TyCon "Duration")))
(DFunDef false "seconds" ((PVar "n")) (EApp (EVar "Duration") (EBinOp "*" (EVar "n") (ELit (LInt 1000)))))
(DTypeSig true "minutes" (TyFun (TyCon "Int") (TyCon "Duration")))
(DFunDef false "minutes" ((PVar "n")) (EApp (EVar "Duration") (EBinOp "*" (EVar "n") (ELit (LInt 60000)))))
(DTypeSig true "hours" (TyFun (TyCon "Int") (TyCon "Duration")))
(DFunDef false "hours" ((PVar "n")) (EApp (EVar "Duration") (EBinOp "*" (EVar "n") (ELit (LInt 3600000)))))
(DTypeSig true "days" (TyFun (TyCon "Int") (TyCon "Duration")))
(DFunDef false "days" ((PVar "n")) (EApp (EVar "Duration") (EBinOp "*" (EVar "n") (ELit (LInt 86400000)))))
(DTypeSig true "toMillis" (TyFun (TyCon "Duration") (TyCon "Int")))
(DFunDef false "toMillis" ((PCon "Duration" (PVar "ms"))) (EVar "ms"))
(DTypeSig true "toSeconds" (TyFun (TyCon "Duration") (TyCon "Int")))
(DFunDef false "toSeconds" ((PCon "Duration" (PVar "ms"))) (EBinOp "/" (EVar "ms") (ELit (LInt 1000))))
(DTypeSig true "toMinutes" (TyFun (TyCon "Duration") (TyCon "Int")))
(DFunDef false "toMinutes" ((PCon "Duration" (PVar "ms"))) (EBinOp "/" (EVar "ms") (ELit (LInt 60000))))
(DTypeSig true "toHours" (TyFun (TyCon "Duration") (TyCon "Int")))
(DFunDef false "toHours" ((PCon "Duration" (PVar "ms"))) (EBinOp "/" (EVar "ms") (ELit (LInt 3600000))))
(DTypeSig true "toDays" (TyFun (TyCon "Duration") (TyCon "Int")))
(DFunDef false "toDays" ((PCon "Duration" (PVar "ms"))) (EBinOp "/" (EVar "ms") (ELit (LInt 86400000))))
(DTypeSig true "addDuration" (TyFun (TyCon "Duration") (TyFun (TyCon "Duration") (TyCon "Duration"))))
(DFunDef false "addDuration" ((PCon "Duration" (PVar "a")) (PCon "Duration" (PVar "b"))) (EApp (EVar "Duration") (EBinOp "+" (EVar "a") (EVar "b"))))
(DTypeSig true "subDuration" (TyFun (TyCon "Duration") (TyFun (TyCon "Duration") (TyCon "Duration"))))
(DFunDef false "subDuration" ((PCon "Duration" (PVar "a")) (PCon "Duration" (PVar "b"))) (EApp (EVar "Duration") (EBinOp "-" (EVar "a") (EVar "b"))))
(DData Public "DateTime" () ((variant "DateTime" (ConNamed (field "year" (TyCon "Int")) (field "month" (TyCon "Int")) (field "day" (TyCon "Int")) (field "hour" (TyCon "Int")) (field "minute" (TyCon "Int")) (field "second" (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "DateTime")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "DateTime" ((rf "year" (PVar "__a0")) (rf "month" (PVar "__a1")) (rf "day" (PVar "__a2")) (rf "hour" (PVar "__a3")) (rf "minute" (PVar "__a4")) (rf "second" (PVar "__a5"))) false) (PRec "DateTime" ((rf "year" (PVar "__b0")) (rf "month" (PVar "__b1")) (rf "day" (PVar "__b2")) (rf "hour" (PVar "__b3")) (rf "minute" (PVar "__b4")) (rf "second" (PVar "__b5"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))) (EApp (EApp (EMethodRef "eq") (EVar "__a4")) (EVar "__b4"))) (EApp (EApp (EMethodRef "eq") (EVar "__a5")) (EVar "__b5"))))))))
(DImpl true "Ord" ((TyCon "DateTime")) () ((im "compare" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "DateTime" ((rf "year" (PVar "__a0")) (rf "month" (PVar "__a1")) (rf "day" (PVar "__a2")) (rf "hour" (PVar "__a3")) (rf "minute" (PVar "__a4")) (rf "second" (PVar "__a5"))) false) (PRec "DateTime" ((rf "year" (PVar "__b0")) (rf "month" (PVar "__b1")) (rf "day" (PVar "__b2")) (rf "hour" (PVar "__b3")) (rf "minute" (PVar "__b4")) (rf "second" (PVar "__b5"))) false)) () (EMatch (EApp (EApp (EMethodRef "compare") (EVar "__a0")) (EVar "__b0")) (arm (PCon "Eq") () (EMatch (EApp (EApp (EMethodRef "compare") (EVar "__a1")) (EVar "__b1")) (arm (PCon "Eq") () (EMatch (EApp (EApp (EMethodRef "compare") (EVar "__a2")) (EVar "__b2")) (arm (PCon "Eq") () (EMatch (EApp (EApp (EMethodRef "compare") (EVar "__a3")) (EVar "__b3")) (arm (PCon "Eq") () (EMatch (EApp (EApp (EMethodRef "compare") (EVar "__a4")) (EVar "__b4")) (arm (PCon "Eq") () (EApp (EApp (EMethodRef "compare") (EVar "__a5")) (EVar "__b5"))) (arm (PVar "__c") () (EVar "__c")))) (arm (PVar "__c") () (EVar "__c")))) (arm (PVar "__c") () (EVar "__c")))) (arm (PVar "__c") () (EVar "__c")))) (arm (PVar "__c") () (EVar "__c"))))))))
(DImpl true "Debug" ((TyCon "DateTime")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "DateTime" ((rf "year" (PVar "__a0")) (rf "month" (PVar "__a1")) (rf "day" (PVar "__a2")) (rf "hour" (PVar "__a3")) (rf "minute" (PVar "__a4")) (rf "second" (PVar "__a5"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "DateTime {")) (ELit (LString " year = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", month = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", day = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString ", hour = "))) (EApp (EMethodRef "debug") (EVar "__a3"))) (ELit (LString ", minute = "))) (EApp (EMethodRef "debug") (EVar "__a4"))) (ELit (LString ", second = "))) (EApp (EMethodRef "debug") (EVar "__a5"))) (ELit (LString " }"))))))))
(DTypeSig false "daysFromCivil" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "daysFromCivil" ((PVar "y0") (PVar "m") (PVar "d")) (EBlock (DoLet false false (PVar "y") (EIf (EBinOp "<=" (EVar "m") (ELit (LInt 2))) (EBinOp "-" (EVar "y0") (ELit (LInt 1))) (EVar "y0"))) (DoLet false false (PVar "era") (EBinOp "/" (EIf (EBinOp ">=" (EVar "y") (ELit (LInt 0))) (EVar "y") (EBinOp "-" (EVar "y") (ELit (LInt 399)))) (ELit (LInt 400)))) (DoLet false false (PVar "yoe") (EBinOp "-" (EVar "y") (EBinOp "*" (EVar "era") (ELit (LInt 400))))) (DoLet false false (PVar "mp") (EIf (EBinOp ">" (EVar "m") (ELit (LInt 2))) (EBinOp "-" (EVar "m") (ELit (LInt 3))) (EBinOp "+" (EVar "m") (ELit (LInt 9))))) (DoLet false false (PVar "doy") (EBinOp "-" (EBinOp "+" (EBinOp "/" (EBinOp "+" (EBinOp "*" (ELit (LInt 153)) (EVar "mp")) (ELit (LInt 2))) (ELit (LInt 5))) (EVar "d")) (ELit (LInt 1)))) (DoLet false false (PVar "doe") (EBinOp "+" (EBinOp "-" (EBinOp "+" (EBinOp "*" (EVar "yoe") (ELit (LInt 365))) (EBinOp "/" (EVar "yoe") (ELit (LInt 4)))) (EBinOp "/" (EVar "yoe") (ELit (LInt 100)))) (EVar "doy"))) (DoExpr (EBinOp "-" (EBinOp "+" (EBinOp "*" (EVar "era") (ELit (LInt 146097))) (EVar "doe")) (ELit (LInt 719468))))))
(DTypeSig false "civilFromDays" (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "civilFromDays" ((PVar "z0")) (EBlock (DoLet false false (PVar "z") (EBinOp "+" (EVar "z0") (ELit (LInt 719468)))) (DoLet false false (PVar "era") (EBinOp "/" (EIf (EBinOp ">=" (EVar "z") (ELit (LInt 0))) (EVar "z") (EBinOp "-" (EVar "z") (ELit (LInt 146096)))) (ELit (LInt 146097)))) (DoLet false false (PVar "doe") (EBinOp "-" (EVar "z") (EBinOp "*" (EVar "era") (ELit (LInt 146097))))) (DoLet false false (PVar "yoe") (EBinOp "/" (EBinOp "-" (EBinOp "+" (EBinOp "-" (EVar "doe") (EBinOp "/" (EVar "doe") (ELit (LInt 1460)))) (EBinOp "/" (EVar "doe") (ELit (LInt 36524)))) (EBinOp "/" (EVar "doe") (ELit (LInt 146096)))) (ELit (LInt 365)))) (DoLet false false (PVar "y") (EBinOp "+" (EVar "yoe") (EBinOp "*" (EVar "era") (ELit (LInt 400))))) (DoLet false false (PVar "doy") (EBinOp "-" (EVar "doe") (EBinOp "-" (EBinOp "+" (EBinOp "*" (ELit (LInt 365)) (EVar "yoe")) (EBinOp "/" (EVar "yoe") (ELit (LInt 4)))) (EBinOp "/" (EVar "yoe") (ELit (LInt 100)))))) (DoLet false false (PVar "mp") (EBinOp "/" (EBinOp "+" (EBinOp "*" (ELit (LInt 5)) (EVar "doy")) (ELit (LInt 2))) (ELit (LInt 153)))) (DoLet false false (PVar "d") (EBinOp "+" (EBinOp "-" (EVar "doy") (EBinOp "/" (EBinOp "+" (EBinOp "*" (ELit (LInt 153)) (EVar "mp")) (ELit (LInt 2))) (ELit (LInt 5)))) (ELit (LInt 1)))) (DoLet false false (PVar "m") (EIf (EBinOp "<" (EVar "mp") (ELit (LInt 10))) (EBinOp "+" (EVar "mp") (ELit (LInt 3))) (EBinOp "-" (EVar "mp") (ELit (LInt 9))))) (DoExpr (ETuple (EIf (EBinOp "<=" (EVar "m") (ELit (LInt 2))) (EBinOp "+" (EVar "y") (ELit (LInt 1))) (EVar "y")) (EVar "m") (EVar "d")))))
(DTypeSig true "fromEpochSeconds" (TyFun (TyCon "Int") (TyCon "DateTime")))
(DFunDef false "fromEpochSeconds" ((PVar "secs")) (EBlock (DoLet false false (PVar "ds") (EApp (EApp (EVar "floorDiv") (EVar "secs")) (ELit (LInt 86400)))) (DoLet false false (PVar "sod") (EBinOp "-" (EVar "secs") (EBinOp "*" (EVar "ds") (ELit (LInt 86400))))) (DoExpr (EMatch (EApp (EVar "civilFromDays") (EVar "ds")) (arm (PTuple (PVar "y") (PVar "m") (PVar "d")) () (ERecordCreate "DateTime" ((fa "year" (EVar "y")) (fa "month" (EVar "m")) (fa "day" (EVar "d")) (fa "hour" (EBinOp "/" (EVar "sod") (ELit (LInt 3600)))) (fa "minute" (EBinOp "%" (EBinOp "/" (EVar "sod") (ELit (LInt 60))) (ELit (LInt 60)))) (fa "second" (EBinOp "%" (EVar "sod") (ELit (LInt 60)))))))))))
(DTypeSig true "toEpochSeconds" (TyFun (TyCon "DateTime") (TyCon "Int")))
(DFunDef false "toEpochSeconds" ((PVar "dt")) (EBinOp "+" (EBinOp "+" (EBinOp "+" (EBinOp "*" (EApp (EApp (EApp (EVar "daysFromCivil") (EFieldAccess (EVar "dt") "year")) (EFieldAccess (EVar "dt") "month")) (EFieldAccess (EVar "dt") "day")) (ELit (LInt 86400))) (EBinOp "*" (EFieldAccess (EVar "dt") "hour") (ELit (LInt 3600)))) (EBinOp "*" (EFieldAccess (EVar "dt") "minute") (ELit (LInt 60)))) (EFieldAccess (EVar "dt") "second")))
(DTypeSig false "pad2" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "pad2" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 10))) (EBinOp "++" (ELit (LString "0")) (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "intToString") (EVar "n"))))
(DTypeSig false "pad4" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "pad4" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 10))) (EBinOp "++" (ELit (LString "000")) (EApp (EVar "intToString") (EVar "n"))) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 100))) (EBinOp "++" (ELit (LString "00")) (EApp (EVar "intToString") (EVar "n"))) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 1000))) (EBinOp "++" (ELit (LString "0")) (EApp (EVar "intToString") (EVar "n"))) (EApp (EVar "intToString") (EVar "n"))))))
(DTypeSig true "formatIso" (TyFun (TyCon "DateTime") (TyCon "String")))
(DFunDef false "formatIso" ((PVar "dt")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "pad4") (EFieldAccess (EVar "dt") "year")))) (ELit (LString "-"))) (EApp (EMethodRef "display") (EApp (EVar "pad2") (EFieldAccess (EVar "dt") "month")))) (ELit (LString "-"))) (EApp (EMethodRef "display") (EApp (EVar "pad2") (EFieldAccess (EVar "dt") "day")))) (ELit (LString "T"))) (EApp (EMethodRef "display") (EApp (EVar "pad2") (EFieldAccess (EVar "dt") "hour")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "pad2") (EFieldAccess (EVar "dt") "minute")))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EVar "pad2") (EFieldAccess (EVar "dt") "second")))) (ELit (LString "Z"))))
(DTypeSig false "isoFields" (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "DateTime")))))))))
(DFunDef false "isoFields" ((PCon "Some" (PVar "y")) (PCon "Some" (PVar "mo")) (PCon "Some" (PVar "d")) (PCon "Some" (PVar "h")) (PCon "Some" (PVar "mi")) (PCon "Some" (PVar "sec"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "y") (ELit (LInt 0))) (EBinOp ">=" (EVar "mo") (ELit (LInt 1)))) (EBinOp "<=" (EVar "mo") (ELit (LInt 12)))) (EBinOp ">=" (EVar "d") (ELit (LInt 1)))) (EBinOp "<=" (EVar "d") (ELit (LInt 31)))) (EBinOp "<=" (EVar "h") (ELit (LInt 23)))) (EBinOp "<=" (EVar "mi") (ELit (LInt 59)))) (EBinOp "<=" (EVar "sec") (ELit (LInt 59)))) (EApp (EVar "Some") (ERecordCreate "DateTime" ((fa "year" (EVar "y")) (fa "month" (EVar "mo")) (fa "day" (EVar "d")) (fa "hour" (EVar "h")) (fa "minute" (EVar "mi")) (fa "second" (EVar "sec"))))) (EVar "None")))
(DFunDef false "isoFields" (PWild PWild PWild PWild PWild PWild) (EVar "None"))
(DTypeSig true "parseIso" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "DateTime"))))
(DFunDef false "parseIso" ((PVar "s")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 20))) (EBinOp "==" (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 4))) (ELit (LInt 5))) (EVar "s")) (ELit (LString "-")))) (EBinOp "==" (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 7))) (ELit (LInt 8))) (EVar "s")) (ELit (LString "-")))) (EBinOp "==" (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 10))) (ELit (LInt 11))) (EVar "s")) (ELit (LString "T")))) (EBinOp "==" (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 13))) (ELit (LInt 14))) (EVar "s")) (ELit (LString ":")))) (EBinOp "==" (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 16))) (ELit (LInt 17))) (EVar "s")) (ELit (LString ":")))) (EBinOp "==" (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 19))) (ELit (LInt 20))) (EVar "s")) (ELit (LString "Z")))) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "isoFields") (EApp (EVar "toInt") (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 0))) (ELit (LInt 4))) (EVar "s")))) (EApp (EVar "toInt") (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 5))) (ELit (LInt 7))) (EVar "s")))) (EApp (EVar "toInt") (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 8))) (ELit (LInt 10))) (EVar "s")))) (EApp (EVar "toInt") (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 11))) (ELit (LInt 13))) (EVar "s")))) (EApp (EVar "toInt") (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 14))) (ELit (LInt 16))) (EVar "s")))) (EApp (EVar "toInt") (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 17))) (ELit (LInt 19))) (EVar "s")))) (arm (PCon "Some" (PVar "dt")) () (EIf (EBinOp "==" (EApp (EVar "formatIso") (EVar "dt")) (EVar "s")) (EApp (EVar "Some") (EVar "dt")) (EVar "None"))) (arm (PCon "None") () (EVar "None"))) (EVar "None")))
(DImpl true "Display" ((TyCon "Duration")) () ((im "display" ((PCon "Duration" (PVar "ms"))) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "ms")))) (ELit (LString "ms"))))))
(DImpl true "Display" ((TyCon "DateTime")) () ((im "display" ((PVar "dt")) (EApp (EVar "formatIso") (EVar "dt")))))
(DImpl true "Semigroup" ((TyCon "Duration")) () ((im "append" ((PVar "a") (PVar "b")) (EApp (EApp (EVar "addDuration") (EVar "a")) (EVar "b")))))
(DImpl true "Monoid" ((TyCon "Duration")) () ((im "empty" () (EApp (EVar "Duration") (ELit (LInt 0))))))
(DTypeSig true "now" (TyFun (TyCon "Unit") (TyEffect ("Clock") None (TyCon "Float"))))
(DFunDef false "now" ((PVar "u")) (EApp (EVar "wallTimeSec") (EVar "u")))
(DTypeSig true "nowDateTime" (TyFun (TyCon "Unit") (TyEffect ("Clock") None (TyCon "DateTime"))))
(DFunDef false "nowDateTime" ((PVar "u")) (EApp (EVar "fromEpochSeconds") (EApp (EVar "floatToInt") (EApp (EVar "wallTimeSec") (EVar "u")))))
(DTypeSig true "monotonic" (TyFun (TyCon "Unit") (TyEffect ("Clock") None (TyCon "Float"))))
(DFunDef false "monotonic" ((PVar "u")) (EApp (EVar "monotonicSec") (EVar "u")))
(DTypeSig true "elapsedSince" (TyFun (TyCon "Float") (TyEffect ("Clock") None (TyCon "Float"))))
(DFunDef false "elapsedSince" ((PVar "start")) (EBinOp "-" (EApp (EVar "monotonicSec") (ELit LUnit)) (EVar "start")))
(DTypeSig true "sleep" (TyFun (TyCon "Duration") (TyEffect ("Clock") None (TyCon "Unit"))))
(DFunDef false "sleep" ((PVar "d")) (EApp (EVar "sleepMs") (EApp (EVar "toMillis") (EVar "d"))))
(DTypeSig true "sleepSeconds" (TyFun (TyCon "Int") (TyEffect ("Clock") None (TyCon "Unit"))))
(DFunDef false "sleepSeconds" ((PVar "s")) (EApp (EVar "sleepMs") (EBinOp "*" (EVar "s") (ELit (LInt 1000)))))
(DProp false "epoch round-trips through the civil calendar" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "s") (EBinOp "+" (ELit (LInt 1000000)) (EBinOp "%" (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n")) (ELit (LInt 3000000000))))) (DoExpr (EBinOp "==" (EApp (EVar "toEpochSeconds") (EApp (EVar "fromEpochSeconds") (EVar "s"))) (EVar "s")))))
(DTypeSig false "sane" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "sane" ((PVar "n")) (EBinOp "+" (ELit (LInt 1000000)) (EBinOp "%" (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n")) (ELit (LInt 3000000000)))))
(DProp false "parseIso inverts formatIso" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "dt") (EApp (EVar "fromEpochSeconds") (EApp (EVar "sane") (EVar "n")))) (DoExpr (EBinOp "==" (EApp (EVar "parseIso") (EApp (EVar "formatIso") (EVar "dt"))) (EApp (EVar "Some") (EVar "dt"))))))
(DProp false "parseIso rejects a corrupted separator" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "iso") (EApp (EVar "formatIso") (EApp (EVar "fromEpochSeconds") (EApp (EVar "sane") (EVar "n"))))) (DoExpr (EBinOp "==" (EApp (EVar "parseIso") (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 0))) (ELit (LInt 10))) (EVar "iso")) (ELit (LString " "))) (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 11))) (ELit (LInt 20))) (EVar "iso")))) (EVar "None")))))
(DProp false "Duration projections invert their constructors" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "k") (EBinOp "%" (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n")) (ELit (LInt 100000)))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "toMillis") (EApp (EVar "millis") (EVar "k"))) (EVar "k")) (EBinOp "==" (EApp (EVar "toSeconds") (EApp (EVar "seconds") (EVar "k"))) (EVar "k"))) (EBinOp "==" (EApp (EVar "toMinutes") (EApp (EVar "minutes") (EVar "k"))) (EVar "k"))) (EBinOp "==" (EApp (EVar "toHours") (EApp (EVar "hours") (EVar "k"))) (EVar "k"))) (EBinOp "==" (EApp (EVar "toDays") (EApp (EVar "days") (EVar "k"))) (EVar "k"))))))
(DProp false "Duration projections are the coarser unit's floor" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "k") (EBinOp "%" (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EBinOp "-" (ELit (LInt 0)) (EVar "n")) (EVar "n")) (ELit (LInt 100000000)))) (DoLet false false (PVar "d") (EApp (EVar "millis") (EVar "k"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "toSeconds") (EVar "d")) (EBinOp "/" (EApp (EVar "toMillis") (EVar "d")) (ELit (LInt 1000)))) (EBinOp "==" (EApp (EVar "toMinutes") (EVar "d")) (EBinOp "/" (EApp (EVar "toSeconds") (EVar "d")) (ELit (LInt 60))))) (EBinOp "==" (EApp (EVar "toHours") (EVar "d")) (EBinOp "/" (EApp (EVar "toMinutes") (EVar "d")) (ELit (LInt 60))))) (EBinOp "==" (EApp (EVar "toDays") (EVar "d")) (EBinOp "/" (EApp (EVar "toHours") (EVar "d")) (ELit (LInt 24))))))))
(DProp false "Ord Duration agrees with toMillis" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EBinOp "&&" (EBinOp "==" (EApp (EApp (EMethodRef "compare") (EApp (EVar "millis") (EVar "a"))) (EApp (EVar "millis") (EVar "b"))) (EApp (EApp (EMethodRef "compare") (EVar "a")) (EVar "b"))) (EBinOp "==" (EBinOp "==" (EApp (EVar "millis") (EVar "a")) (EApp (EVar "millis") (EVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))))
(DProp false "Ord DateTime agrees with toEpochSeconds" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int"))) (EBlock (DoLet false false (PVar "x") (EApp (EVar "fromEpochSeconds") (EApp (EVar "sane") (EVar "a")))) (DoLet false false (PVar "y") (EApp (EVar "fromEpochSeconds") (EApp (EVar "sane") (EVar "b")))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EApp (EMethodRef "compare") (EVar "x")) (EVar "y")) (EApp (EApp (EMethodRef "compare") (EApp (EVar "toEpochSeconds") (EVar "x"))) (EApp (EVar "toEpochSeconds") (EVar "y")))) (EBinOp "==" (EBinOp "==" (EVar "x") (EVar "y")) (EBinOp "==" (EApp (EVar "toEpochSeconds") (EVar "x")) (EApp (EVar "toEpochSeconds") (EVar "y"))))))))
(DProp false "Display DateTime is formatIso" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "dt") (EApp (EVar "fromEpochSeconds") (EApp (EVar "sane") (EVar "n")))) (DoExpr (EBinOp "==" (EApp (EMethodRef "display") (EVar "dt")) (EApp (EVar "formatIso") (EVar "dt"))))))
(DProp false "Display Duration renders the millisecond count" ((pp "n" (TyCon "Int"))) (EBinOp "==" (EApp (EMethodRef "display") (EApp (EVar "millis") (EVar "n"))) (EBinOp "++" (EApp (EVar "intToString") (EVar "n")) (ELit (LString "ms")))))
(DProp false "Semigroup Duration is associative" ((pp "a" (TyCon "Int")) (pp "b" (TyCon "Int")) (pp "c" (TyCon "Int"))) (EBlock (DoLet false false (PVar "l") (EApp (EApp (EMethodRef "append") (EApp (EApp (EMethodRef "append") (EApp (EVar "millis") (EVar "a"))) (EApp (EVar "millis") (EVar "b")))) (EApp (EVar "millis") (EVar "c")))) (DoLet false false (PVar "r") (EApp (EApp (EMethodRef "append") (EApp (EVar "millis") (EVar "a"))) (EApp (EApp (EMethodRef "append") (EApp (EVar "millis") (EVar "b"))) (EApp (EVar "millis") (EVar "c"))))) (DoExpr (EBinOp "==" (EVar "l") (EVar "r")))))
(DProp false "Monoid Duration: empty is a two-sided identity" ((pp "n" (TyCon "Int"))) (EBlock (DoLet false false (PVar "d") (EApp (EVar "millis") (EVar "n"))) (DoExpr (EBinOp "&&" (EBinOp "==" (EApp (EApp (EMethodRef "append") (EVar "d")) (EMethodRef "empty")) (EVar "d")) (EBinOp "==" (EApp (EApp (EMethodRef "append") (EMethodRef "empty")) (EVar "d")) (EVar "d"))))))
