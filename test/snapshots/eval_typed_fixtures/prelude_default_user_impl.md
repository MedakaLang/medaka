# META
source_lines=21
stages=EVAL
# SOURCE
-- A user impl of a prelude interface that supplies only `compare`: `<`, `lt`, `max`
-- and `min` are the prelude's defaults, specialized for `P` through the disposition
-- table.  `compare` is reversed, so a default that did not run `P`'s own `compare`
-- prints the opposite answer (TrueTrueP25P5).
data P = P Int

impl Eq P where
  eq (P a) (P b) = a == b

impl Ord P where
  compare (P a) (P b) = compare b a

impl Debug P where
  debug (P a) = "P" ++ debug a

main =
  println
    (debug (P 5 < P 25)
      ++ debug (lt (P 5) (P 25))
      ++ debug (max (P 5) (P 25))
      ++ debug (min (P 5) (P 25)))
# EVAL
FalseFalseP5P25
