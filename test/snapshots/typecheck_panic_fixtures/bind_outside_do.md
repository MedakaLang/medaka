# META
source_lines=3
stages=TYPES
diagnostics=TYPES
# SOURCE
f a =
  x <- a
  x
# TYPES
TYPE ERROR: `<-` is only valid inside a `do` block; outside one, bind the value with `let x = ...`
