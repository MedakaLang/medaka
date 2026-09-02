# time

Durations, a UTC calendar, and the clock.

`Duration` is a span of time in whole milliseconds, built with `millis`,
`seconds`, `minutes`, `hours`, and `days`. `DateTime` is a civil date
and time in UTC; `fromEpochSeconds` and `toEpochSeconds` convert to and
from Unix time, and `formatIso` and `parseIso` convert to and from ISO
8601 text. There is no time zone support: every `DateTime` is UTC.

`now`, `monotonic`, `elapsedSince`, and `sleep` read and wait on the
host clock. Under the interpreter the clock returns fixed values and
`sleep` does nothing; in a built program they use the real clock.

## Durations

### `Duration`

```
data Duration
  = Duration Int
```

A span of time, in whole milliseconds.

Instances: `Eq`, `Ord`, `Debug`, [`Display`](#display-duration), [`Semigroup`](#semigroup-duration), [`Monoid`](#monoid-duration)

### `millis`

```
millis : Int -> Duration
```

A duration of `n` milliseconds.

```medaka
> toMillis (millis 250)
250
```

### `seconds`

```
seconds : Int -> Duration
```

A duration of `n` seconds.

```medaka
> toMillis (seconds 5)
5000
```

### `minutes`

```
minutes : Int -> Duration
```

A duration of `n` minutes.

```medaka
> toSeconds (minutes 2)
120
```

### `hours`

```
hours : Int -> Duration
```

A duration of `n` hours.

```medaka
> toSeconds (hours 1)
3600
```

### `days`

```
days : Int -> Duration
```

A duration of `n` days.

```medaka
> toSeconds (days 1)
86400
```

### `toMillis`

```
toMillis : Duration -> Int
```

The duration in whole milliseconds.

### `toSeconds`

```
toSeconds : Duration -> Int
```

The duration in whole seconds, rounded towards zero.

```medaka
> toSeconds (millis 2500)
2
```

### `toMinutes`

```
toMinutes : Duration -> Int
```

The duration in whole minutes, rounded towards zero.

```medaka
> toMinutes (seconds 150)
2
```

### `toHours`

```
toHours : Duration -> Int
```

The duration in whole hours, rounded towards zero.

```medaka
> toHours (minutes 150)
2
```

### `toDays`

```
toDays : Duration -> Int
```

The duration in whole days, rounded towards zero.

```medaka
> toDays (hours 50)
2
```

### `addDuration`

```
addDuration : Duration -> Duration -> Duration
```

The sum of two durations.

`++` on durations is the same operation.

```medaka
> toMillis (addDuration (seconds 1) (millis 500))
1500
```

### `subDuration`

```
subDuration : Duration -> Duration -> Duration
```

The first duration less the second.

```medaka
> toMillis (subDuration (seconds 2) (millis 500))
1500
```

## Dates and times

### `DateTime`

```
data DateTime
  = DateTime { year : Int, month : Int, day : Int, hour : Int, minute : Int, second : Int }
```

A civil date and time in UTC.

`month` runs from 1 to 12 and `day` from 1 to 31. Values compare in
field order, which is chronological order for valid dates.

Instances: `Eq`, `Ord`, `Debug`, [`Display`](#display-datetime)

### `fromEpochSeconds`

```
fromEpochSeconds : Int -> DateTime
```

The UTC date and time at a number of seconds since the Unix epoch.

Negative values, before 1970, work too.

```medaka
> formatIso (fromEpochSeconds 0)
"1970-01-01T00:00:00Z"
> formatIso (fromEpochSeconds 1000000000)
"2001-09-09T01:46:40Z"
```

### `toEpochSeconds`

```
toEpochSeconds : DateTime -> Int
```

The number of seconds since the Unix epoch at a UTC date and time. The
inverse of `fromEpochSeconds`.

```medaka
> toEpochSeconds (fromEpochSeconds 1000000000)
1000000000
```

### `formatIso`

```
formatIso : DateTime -> String
```

The date and time in ISO 8601 form, `YYYY-MM-DDThh:mm:ssZ`.

```medaka
> formatIso (DateTime { year = 2024, month = 3, day = 5, hour = 7, minute = 8, second = 9 })
"2024-03-05T07:08:09Z"
```

### `parseIso`

```
parseIso : String -> Option DateTime
```

The date and time written in ISO 8601 form, `YYYY-MM-DDThh:mm:ssZ`, or
`None`.

Exactly the form `formatIso` produces is accepted, and nothing else: no
other time zone, no missing zero padding, no lowercase `t`.

```medaka
> map toEpochSeconds (parseIso "1970-01-01T00:00:00Z")
Some 0
> parseIso "2024-13-05T07:08:09Z"
None
```

## The clock

### `now`

```
now : Unit -> <Clock> Float
```

The current wall-clock time in seconds since the Unix epoch.

### `nowDateTime`

```
nowDateTime : Unit -> <Clock> DateTime
```

The current UTC date and time, to the second.

### `monotonic`

```
monotonic : Unit -> <Clock> Float
```

A reading of the monotonic clock, in seconds.

The monotonic clock is unaffected by adjustments to the wall clock, so
two readings measure an interval. See `elapsedSince`.

### `elapsedSince`

```
elapsedSince : Float -> <Clock> Float
```

The seconds elapsed since an earlier `monotonic` reading.

Time a computation with `let t0 = monotonic ()`, the computation, then
`elapsedSince t0`.

### `sleep`

```
sleep : Duration -> <Clock> Unit
```

Pauses the program for a duration.

`sleep (seconds 5)` and `sleep (millis 5)` say their unit.

## Instances

### `Display Duration`

```
impl Display Duration
```

`display` renders a duration as its millisecond count with an `ms`
suffix.

### `Display DateTime`

```
impl Display DateTime
```

`display` renders a date and time in ISO 8601 form, like `formatIso`.

### `Semigroup Duration`

```
impl Semigroup Duration
```

`++` on durations is `addDuration`.

### `Monoid Duration`

```
impl Monoid Duration
```

`empty` is the zero duration.

