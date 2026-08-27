# META
source_lines=23
stages=TYPES
# SOURCE
-- extern declarations become top-level schemes; pure externs used freely,
-- effectful externs used through a signature that declares the effect
-- (inferred effect PROPAGATION from an unsigned call site needs open rows —
-- a later slice — so it's avoided here)
--
-- #2074: `toChars : String -> List Char` and `wrapL : a -> List a` used to sit
-- here.  Both are now rejected by the FFI-ABI.md §1 crossable-set guard: `List`
-- is not crossable, and NO crossable type is polymorphic, so a generic extern is
-- genuinely unrepresentable at a C ABI.  That is real semantics, not a test
-- artifact, so those two shapes moved to the guard's own gate as REJECT cells
-- (`test/effect_builtin_param_fixtures/ffi_cross_list_reject.mdk` and
-- `ffi_cross_poly_reject.mdk`).  ⚠️ THE PROPERTY THIS FILE LOSES is wrapper
-- generalization over a POLYMORPHIC extern scheme (the old `boxIt x = wrapL x`);
-- what remains is the monomorphic half plus the multi-argument spine.
extern strLen : String -> Int
extern charAt : String -> Int -> Char
extern emit : String -> <IO> Unit
extern rng : Unit -> <Rand> Int
useLen s = strLen s
firstOf s = charAt s 0
combine a b = strLen a + strLen b
shout : String -> <IO, FFI> Unit
shout s = emit s
# TYPES
strLen : String -> <FFI> Int
charAt : String -> Int -> <FFI> Char
emit : String -> <FFI, IO> Unit
rng : Unit -> <FFI, Rand> Int
useLen : String -> <FFI> Int
firstOf : String -> <FFI> Char
combine : String -> String -> <FFI> Int
shout : String -> <FFI, IO> Unit
