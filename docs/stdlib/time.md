# time

time.mdk — durations + a UTC civil calendar, plus thin wrappers over the
`<Clock>` externs (`wallTimeSec` / `monotonicSec` / `sleepMs`).

Import with `import time.*` (or select names, e.g.
`import time.{fromEpochSeconds, formatIso}`).

── Scope ──────────────────────────────────────────────────────────────
• UTC ONLY.  There is no timezone / DST database (that is a P2 follow-up).
Every `DateTime` here is civil UTC; `formatIso` always emits a `Z` suffix.
• The calendar core (`fromEpochSeconds` / `toEpochSeconds`) uses Howard
Hinnant's days-from-civil / civil-from-days algorithm — pure Int
arithmetic, correct across leap years and for negative (pre-1970) epochs.
Medaka's `/` truncates toward zero, so the seconds→days split uses a
`floorDiv` helper; Hinnant's own `era` adjustments already assume
truncating division, so they are used verbatim.  `floorDiv` itself now
lives in `math.mdk` (promoted in #433 — this file used to hand-roll a
private copy; same algorithm, unchanged).

── Effect labels ──────────────────────────────────────────────────────
The three externs all carry the `<Clock>` effect.  `sleepMs` reuses
`<Clock>` for cohesion with the time domain — there is no `<Sleep>` label
and adding one is out of scope.  Unlike the file externs, `<Clock>`
externs DO run under the interpreter (`medaka run`): there the interpreter
oracle has no FFI to the clock, so `wallTimeSec` / `monotonicSec` return
fixed plausible values and `sleepMs` is a no-op.  On native `build` they
call the real C clock / `nanosleep`.

## `Duration`

```
data Duration
  = Duration Int
```

── Duration ────────────────────────────────────────────────────────────
A time span, stored as a whole number of MILLISECONDS.

## `millis`

```
millis : Int -> Duration
```

A duration of `n` milliseconds.


*(doctest — run by `medaka test`)*

```medaka
> toMillis (millis 250)
250
```

## `seconds`

```
seconds : Int -> Duration
```

A duration of `n` seconds.


*(doctest — run by `medaka test`)*

```medaka
> toMillis (seconds 5)
5000
```

## `minutes`

```
minutes : Int -> Duration
```

A duration of `n` minutes.


*(doctest — run by `medaka test`)*

```medaka
> toSeconds (minutes 2)
120
```

## `hours`

```
hours : Int -> Duration
```

A duration of `n` hours.


*(doctest — run by `medaka test`)*

```medaka
> toSeconds (hours 1)
3600
```

## `days`

```
days : Int -> Duration
```

A duration of `n` days.


*(doctest — run by `medaka test`)*

```medaka
> toSeconds (days 1)
86400
```

## `toMillis`

```
toMillis : Duration -> Int
```

The duration as whole milliseconds.

## `toSeconds`

```
toSeconds : Duration -> Int
```

The duration as whole seconds (truncated toward zero).


*(doctest — run by `medaka test`)*

```medaka
> toSeconds (millis 2500)
2
```

## `toMinutes`

```
toMinutes : Duration -> Int
```

The duration as whole minutes (truncated toward zero).


*(doctest — run by `medaka test`)*

```medaka
> toMinutes (seconds 150)
2
```

## `toHours`

```
toHours : Duration -> Int
```

The duration as whole hours (truncated toward zero).


*(doctest — run by `medaka test`)*

```medaka
> toHours (minutes 150)
2
```

## `toDays`

```
toDays : Duration -> Int
```

The duration as whole days (truncated toward zero).


*(doctest — run by `medaka test`)*

```medaka
> toDays (hours 50)
2
```

## `addDuration`

```
addDuration : Duration -> Duration -> Duration
```

Add two durations.


*(doctest — run by `medaka test`)*

```medaka
> toMillis (addDuration (seconds 1) (millis 500))
1500
```

## `subDuration`

```
subDuration : Duration -> Duration -> Duration
```

Subtract the second duration from the first.


*(doctest — run by `medaka test`)*

```medaka
> toMillis (subDuration (seconds 2) (millis 500))
1500
```

## `DateTime`

```
data DateTime
  = DateTime { year : Int, month : Int, day : Int, hour : Int, minute : Int, second : Int }
```

── UTC civil calendar ──────────────────────────────────────────────────
A civil UTC date-and-time.  `month` is 1-12, `day` is 1-31.

## `fromEpochSeconds`

```
fromEpochSeconds : Int -> DateTime
```

Convert Unix epoch seconds (UTC) to a civil `DateTime`.  Supports
negative (pre-1970) inputs.


*(doctest — run by `medaka test`)*

```medaka
> formatIso (fromEpochSeconds 0)
"1970-01-01T00:00:00Z"
> formatIso (fromEpochSeconds 1000000000)
"2001-09-09T01:46:40Z"
> formatIso (fromEpochSeconds 951782400)
"2000-02-29T00:00:00Z"
> formatIso (fromEpochSeconds 1709164800)
"2024-02-29T00:00:00Z"
> formatIso (fromEpochSeconds (0 - 1))
"1969-12-31T23:59:59Z"
```

## `toEpochSeconds`

```
toEpochSeconds : DateTime -> Int
```

Convert a civil `DateTime` (UTC) to Unix epoch seconds.  Inverse of
`fromEpochSeconds`.


*(doctest — run by `medaka test`)*

```medaka
> toEpochSeconds (fromEpochSeconds 1000000000)
1000000000
```

## `formatIso`

```
formatIso : DateTime -> String
```

Render a `DateTime` as ISO 8601 `YYYY-MM-DDThh:mm:ssZ` (zero-padded, UTC).


*(doctest — run by `medaka test`)*

```medaka
> formatIso (DateTime { year = 2024, month = 3, day = 5, hour = 7, minute = 8, second = 9 })
"2024-03-05T07:08:09Z"
```

## `parseIso`

```
parseIso : String -> Option DateTime
```

Parse ISO 8601 `YYYY-MM-DDThh:mm:ssZ` (UTC only, exactly the shape
`formatIso` emits), or `None`.  This is the exact inverse of `formatIso`:
the candidate is accepted only if re-rendering it reproduces the input
byte-for-byte, so no alternate spelling of the same instant (`+7` for `07`,
a lowercase `t`, a missing pad) is silently accepted.


*(doctest — run by `medaka test`)*

```medaka
> parseIso "2024-03-05T07:08:09Z" == Some (DateTime { year = 2024, month = 3, day = 5, hour = 7, minute = 8, second = 9 })
True
> map toEpochSeconds (parseIso "1970-01-01T00:00:00Z")
Some 0
> parseIso "2024-03-05 07:08:09Z"
None
> parseIso "2024-13-05T07:08:09Z"
None
> parseIso "not a date"
None
```

## `Display Duration`

```
impl Display Duration
```

A `Duration` displays as its whole millisecond count with an `ms` suffix.

## `Display DateTime`

```
impl Display DateTime
```

A `DateTime` displays as its ISO 8601 rendering — `display == formatIso`.

## `Semigroup Duration`

```
impl Semigroup Duration
```

`addDuration` is the associative append.

## `Monoid Duration`

```
impl Monoid Duration
```

`millis 0` is the identity for `addDuration`.

## `now`

```
now : Unit -> <Clock> Float
```

── Effectful helpers (over the `<Clock>` externs) ──────────────────────
Current wall-clock time in Unix epoch seconds (Float).

## `nowDateTime`

```
nowDateTime : Unit -> <Clock> DateTime
```

Current UTC civil time, from the wall clock (floored to whole seconds).

## `monotonic`

```
monotonic : Unit -> <Clock> Float
```

A monotonic-clock reading in seconds (immune to wall-clock adjustment).
Use two readings to time an interval, or `elapsedSince`.

## `elapsedSince`

```
elapsedSince : Float -> <Clock> Float
```

Seconds elapsed on the monotonic clock since an earlier `monotonic ()`
reading.  Time a block with `let t0 = monotonic ()  … elapsedSince t0`.

## `sleep`

```
sleep : Duration -> <Clock> Unit
```

Sleep for a `Duration`.

Takes a `Duration`, not a bare `Int`: `sleep 5` used to mean five
MILLISECONDS while reading as five seconds, and the type could not warn
anyone (#2306 J-1).  Now the unit is in the value — `sleep (seconds 5)`,
`sleep (millis 5)` — and the old `sleepSeconds` is gone with it, since
`seconds` already says that.

`sleepSeconds` below is UNCHANGED: it was never the ambiguous one — the
row cites it as the proof that this module already knew units belong
somewhere the reader can see them.

## `sleepSeconds`

```
sleepSeconds : Int -> <Clock> Unit
```

Sleep for `s` seconds.  Equivalent to `sleep (seconds s)`.

