# time

## `Duration`

```
data Duration
  = Duration Int
```

Instances: `Eq`, `Ord`, `Debug`, [`Display`](#display-duration), [`Semigroup`](#semigroup-duration), [`Monoid`](#monoid-duration)

A time span, stored as a whole number of MILLISECONDS.

## `millis`

```
millis : Int -> Duration
```

A duration of `n` milliseconds.

```medaka
> toMillis (millis 250)
250
```

## `seconds`

```
seconds : Int -> Duration
```

A duration of `n` seconds.

```medaka
> toMillis (seconds 5)
5000
```

## `minutes`

```
minutes : Int -> Duration
```

A duration of `n` minutes.

```medaka
> toSeconds (minutes 2)
120
```

## `hours`

```
hours : Int -> Duration
```

A duration of `n` hours.

```medaka
> toSeconds (hours 1)
3600
```

## `days`

```
days : Int -> Duration
```

A duration of `n` days.

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

```medaka
> toSeconds (millis 2500)
2
```

## `toMinutes`

```
toMinutes : Duration -> Int
```

The duration as whole minutes (truncated toward zero).

```medaka
> toMinutes (seconds 150)
2
```

## `toHours`

```
toHours : Duration -> Int
```

The duration as whole hours (truncated toward zero).

```medaka
> toHours (minutes 150)
2
```

## `toDays`

```
toDays : Duration -> Int
```

The duration as whole days (truncated toward zero).

```medaka
> toDays (hours 50)
2
```

## `addDuration`

```
addDuration : Duration -> Duration -> Duration
```

Add two durations.

```medaka
> toMillis (addDuration (seconds 1) (millis 500))
1500
```

## `subDuration`

```
subDuration : Duration -> Duration -> Duration
```

Subtract the second duration from the first.

```medaka
> toMillis (subDuration (seconds 2) (millis 500))
1500
```

## `DateTime`

```
data DateTime
  = DateTime { year : Int, month : Int, day : Int, hour : Int, minute : Int, second : Int }
```

Instances: `Eq`, `Ord`, `Debug`, [`Display`](#display-datetime)

A civil UTC date-and-time.  `month` is 1-12, `day` is 1-31.

## `fromEpochSeconds`

```
fromEpochSeconds : Int -> DateTime
```

Convert Unix epoch seconds (UTC) to a civil `DateTime`.  Supports
negative (pre-1970) inputs.

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

```medaka
> toEpochSeconds (fromEpochSeconds 1000000000)
1000000000
```

## `formatIso`

```
formatIso : DateTime -> String
```

Render a `DateTime` as ISO 8601 `YYYY-MM-DDThh:mm:ssZ` (zero-padded, UTC).

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

## `now`

```
now : Unit -> <Clock> Float
```

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

## Instances

### `Display Duration`

```
impl Display Duration
```

A `Duration` displays as its whole millisecond count with an `ms` suffix.

### `Display DateTime`

```
impl Display DateTime
```

A `DateTime` displays as its ISO 8601 rendering — `display == formatIso`.

### `Semigroup Duration`

```
impl Semigroup Duration
```

`addDuration` is the associative append.

### `Monoid Duration`

```
impl Monoid Duration
```

`millis 0` is the identity for `addDuration`.

