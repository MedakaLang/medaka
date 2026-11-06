# META
source_lines=15
stages=TYPES
diagnostics=TYPES
# SOURCE
-- effect annotations on arrows (rendered only when non-empty; pure inference
-- stays bare; a value's own row must be empty, so a row sits on an arrow)
emit : Int -> <IO> Unit
emit x = ()
gen : a -> <IO, Rand> a
gen x = x
pureVal : Unit -> <IO> Int
pureVal () = 5
higher : (a -> <IO> b) -> a -> <IO> b
higher fn x = fn x
runTwice : (Unit -> <IO> a) -> <IO> Unit
runTwice fn = ()
mixed : Int -> Int -> <Rand> Bool
mixed a b = a == b
purePoly x = x
# TYPES
emit : Int -> <IO> Unit
gen : a -> <IO, Rand> a
pureVal : Unit -> <IO> Int
higher : (a -> <IO> b) -> a -> <IO> b
runTwice : (Unit -> <IO> a) -> <IO> Unit
mixed : Int -> Int -> <Rand> Bool
purePoly : a -> a
