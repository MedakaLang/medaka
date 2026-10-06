# META
source_lines=8
stages=TYPES_USER
diagnostics=TYPES_USER
# SOURCE
data Color = Red | Green | Blue

colorName : Color -> String
colorName c = match c
  Red => "red"
  Green => "green"

main = println (colorName Red)
# TYPES_USER
colorName : Color -> String
main : <Stdout> Unit
Warning: non-exhaustive match on `Color`: missing `Blue`; add a `Blue => ...` arm or a `_` wildcard
