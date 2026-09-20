# META
source_lines=223
stages=DESUGAR,MARK
# SOURCE
{- | A mutable string of bytes, fixed at its allocated length.

   `MutBytes` is `bytes`'s mutable sibling and the way to build a byte string
   a byte at a time. `make` allocates `n` zero bytes, `setInPlace` writes one,
   `fill` writes them all, `blit` copies a run from one into another, and
   `freeze` hands back an immutable `Bytes`. `thaw` goes the other way. Both
   `freeze` and `thaw` copy, so neither result shares storage with its
   source.

   The alternative -- filling an `Array Int` and handing it to
   `bytes.fromArray` -- boxes a machine word per byte before packing them,
   which is the cost `Bytes` exists to avoid.

   `length` is the byte count, `get` reads one byte as an `Option`, and
   `mb[i]` panics on an out-of-range index instead. Every write checks both
   the index and the `0` to `255` domain.

   `length` is also the prelude's `Foldable` method, and `make`, `get`,
   `setInPlace`, `fill` and `blit` are also `array`'s, so import this module
   selectively rather than with `*`. `length` named in an import list shadows
   the prelude's method for the whole importing module, so reach it through
   an alias -- `import mut_bytes as MB`, then `MB.length` -- from a module
   that uses both. -}

-- `MutBytes` lives here rather than in a section of `bytes.mdk` so that both
-- types can carry the bare `make`/`length`/`get` names: one module cannot
-- export two `length`s.
--
-- The two types meet at `freeze` and `thaw`, which cross through `bytes`'s
-- kernel doors -- `adoptByteBlockUnsafe` and `lendByteBlockUnsafe` -- rather
-- than the `Bytes` constructor, which stays module-private there. Both hand
-- those doors a block nothing else holds, or read one they do not write, so
-- neither aliases.

import core.{Debug, Index, Option}
import bytes.{
  Bytes, adoptByteBlockUnsafe, encodeUtf8, lendByteBlockUnsafe, toArray
}

{- | The mutable byte-string type.

   The constructor is module-private, so `make` and `thaw` are the ways in
   and `freeze` the way out, and nothing observes the buffer except through
   the functions below.

   > length (make 3)
   3 -}
export newtype MutBytes = MutBytes ByteBlock

-- # Allocation

{- | A mutable byte string of `n` zero bytes.

   Panics when `n` is negative.

   > get 2 (make 3)
   Some 0 -}
export
make : Int -> MutBytes
make n =
  if n < 0 then
    panic "MutBytes.make: negative length"
  else
    MutBytes (byteBlockMake n)

-- # Reading

{- | The number of bytes in `mb`, fixed when it was allocated.

   > length (make 4)
   4 -}
export
length : MutBytes -> Int
length (MutBytes bb) = byteBlockLength bb

{- | The byte at index `i` of `mb`, or `None` when `i` is out of range.

   `mb[i]` is the panicking form: on the same out-of-range index, `get`
   answers `None` where `mb[i]` raises an index error.

   > get 1 (make 2)
   Some 0
   > get 2 (make 2)
   None
   > get (-1) (make 2)
   None -}
export
get : Int -> MutBytes -> Option Int
get i (MutBytes bb) =
  if i < 0 || i >= byteBlockLength bb then
    None
  else
    Some (byteBlockGetUnsafe i bb)

{- | `mb[i]` reads the byte at `i` in `O(1)`.

   Panics with an index error when `i` is out of range; `get` is the
   `Option`-returning form.

   > let mb = make 3 in let _ = setInPlace 1 8 mb in mb[1]
   8 -}
export impl Index MutBytes Int Int where
  index (MutBytes bb) i =
    if i < 0 || i >= byteBlockLength bb then
      indexErrorAt i
    else
      byteBlockGetUnsafe i bb

-- # Writing

{- | Replaces the byte at index `i` of `mb` with `v`.

   Panics when `i` is out of range, as `array.setInPlace` does, and panics
   when `v` falls outside `0` to `255` rather than keeping its low eight
   bits. A masked write would put a byte into a `Bytes` that no caller asked
   for, and this is the door every byte written here goes through.

   > let mb = make 2 in let _ = setInPlace 0 65 mb in get 0 mb
   Some 65 -}
export
setInPlace : Int -> Int -> MutBytes -> Unit
setInPlace i v (MutBytes bb) =
  if v < 0 || v > 255 then
    panic "MutBytes.setInPlace: value out of range 0..255"
  else if i < 0 || i >= byteBlockLength bb then
    panic "MutBytes.setInPlace: index out of bounds"
  else
    byteBlockSetUnsafe i v bb

{- | Replaces every byte of `mb` with `v`.

   `array.fill`'s counterpart. Panics when `v` falls outside `0` to `255`,
   for the reason `setInPlace` does.

   > let mb = make 3 in let _ = fill 7 mb in debug mb
   "MutBytes \"070707\"" -}
export
fill : Int -> MutBytes -> Unit
fill v (MutBytes bb) =
  if v < 0 || v > 255 then
    panic "MutBytes.fill: value out of range 0..255"
  else
    fillFrom v bb 0 (byteBlockLength bb)

-- The runtime has no block-fill primitive, so the bytes go one at a time
-- through the unchecked setter, with the domain and the bounds established
-- by `fill` above.
fillFrom : Int -> ByteBlock -> Int -> Int -> Unit
fillFrom v bb i n
  | i >= n = ()
  | otherwise =
    byteBlockSetUnsafe i v bb
    fillFrom v bb (i + 1) n

{- | Copies `len` bytes from `src`, starting at `srcOff`, into `dst`, starting
   at `dstOff`.

   Panics when any argument is negative or the copy would run past either
   byte string's end, as `array.blit` does.

   `src` and `dst` may be the same `MutBytes` and the two runs may overlap:
   every source byte is read as it was before any of them was written.

   > let src = make 2 in let _ = fill 9 src in let dst = make 4 in let _ = blit src 0 dst 1 2 in debug dst
   "MutBytes \"00090900\""
   > let mb = make 4 in let _ = setInPlace 0 1 mb in let _ = setInPlace 1 2 mb in let _ = blit mb 0 mb 1 2 in debug mb
   "MutBytes \"01010200\"" -}
export
blit : MutBytes -> Int -> MutBytes -> Int -> Int -> Unit
blit (MutBytes src) srcOff (MutBytes dst) dstOff len =
  if len < 0 then
    panic "MutBytes.blit: negative length"
  else if srcOff < 0 then
    panic "MutBytes.blit: negative srcOff"
  else if dstOff < 0 then
    panic "MutBytes.blit: negative dstOff"
  else if srcOff + len > byteBlockLength src then
    panic "MutBytes.blit: source out of bounds"
  else if dstOff + len > byteBlockLength dst then
    panic "MutBytes.blit: destination out of bounds"
  else
    byteBlockBlit src srcOff dst dstOff len

-- # Crossing to `Bytes`

{- | The bytes of `mb` as an immutable `Bytes`.

   The result is a copy, so a write to `mb` afterwards does not reach it.

   > let mb = make 2 in let _ = setInPlace 1 9 mb in toArray (freeze mb)
   [|0, 9|]
   > let m = make 1 in let b = freeze m in let _ = setInPlace 0 7 m in toArray b
   [|0|] -}
export
freeze : MutBytes -> Bytes
freeze (MutBytes bb) =
  adoptByteBlockUnsafe (byteBlockCopyUnsafe (byteBlockLength bb) bb)

{- | A mutable copy of `b`.

   `freeze`'s mirror, and a copy for the same reason: a write to the result
   does not reach `b`, which hands out no way to change it.

   > let b = encodeUtf8 "hi" in let mb = thaw b in let _ = setInPlace 0 65 mb in (toArray b, toArray (freeze mb))
   ([|104, 105|], [|65, 105|]) -}
export
thaw : Bytes -> MutBytes
thaw b =
  let bb = lendByteBlockUnsafe b
  MutBytes (byteBlockCopyUnsafe (byteBlockLength bb) bb)

{- | Renders as `MutBytes "<hex>"`, in the same lowercase hex shape
   `Debug Bytes` uses -- read from the live buffer, not a `freeze`d copy.

   > debug (make 0)
   "MutBytes \"\""
   > let mb = make 2 in let _ = setInPlace 0 255 mb in debug mb
   "MutBytes \"ff00\"" -}
export impl Debug MutBytes where
  -- `adoptByteBlockUnsafe` aliases rather than copies, so the digits are the
  -- buffer's current bytes; the `Bytes` it builds is read here and dropped,
  -- and the byte-to-hex walk is not written a second time.
  debug (MutBytes bb) = "Mut\{debug (adoptByteBlockUnsafe bb)}"
# DESUGAR
(DUse false (UseGroup ("core") ((mem "Debug" false) (mem "Index" false) (mem "Option" false))))
(DUse false (UseGroup ("bytes") ((mem "Bytes" false) (mem "adoptByteBlockUnsafe" false) (mem "encodeUtf8" false) (mem "lendByteBlockUnsafe" false) (mem "toArray" false))))
(DNewtype true "MutBytes" () "MutBytes" (TyCon "ByteBlock") ())
(DTypeSig true "make" (TyFun (TyCon "Int") (TyCon "MutBytes")))
(DFunDef false "make" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "MutBytes.make: negative length"))) (EApp (EVar "MutBytes") (EApp (EVar "byteBlockMake") (EVar "n")))))
(DTypeSig true "length" (TyFun (TyCon "MutBytes") (TyCon "Int")))
(DFunDef false "length" ((PCon "MutBytes" (PVar "bb"))) (EApp (EVar "byteBlockLength") (EVar "bb")))
(DTypeSig true "get" (TyFun (TyCon "Int") (TyFun (TyCon "MutBytes") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "get" ((PVar "i") (PCon "MutBytes" (PVar "bb"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb")))))
(DImpl true "Index" ((TyCon "MutBytes") (TyCon "Int") (TyCon "Int")) () ((im "index" ((PCon "MutBytes" (PVar "bb")) (PVar "i")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EApp (EVar "indexErrorAt") (EVar "i")) (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb"))))))
(DTypeSig true "setInPlace" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "MutBytes") (TyCon "Unit")))))
(DFunDef false "setInPlace" ((PVar "i") (PVar "v") (PCon "MutBytes" (PVar "bb"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "v") (ELit (LInt 0))) (EBinOp ">" (EVar "v") (ELit (LInt 255)))) (EApp (EVar "panic") (ELit (LString "MutBytes.setInPlace: value out of range 0..255"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EApp (EVar "panic") (ELit (LString "MutBytes.setInPlace: index out of bounds"))) (EApp (EApp (EApp (EVar "byteBlockSetUnsafe") (EVar "i")) (EVar "v")) (EVar "bb")))))
(DTypeSig true "fill" (TyFun (TyCon "Int") (TyFun (TyCon "MutBytes") (TyCon "Unit"))))
(DFunDef false "fill" ((PVar "v") (PCon "MutBytes" (PVar "bb"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "v") (ELit (LInt 0))) (EBinOp ">" (EVar "v") (ELit (LInt 255)))) (EApp (EVar "panic") (ELit (LString "MutBytes.fill: value out of range 0..255"))) (EApp (EApp (EApp (EApp (EVar "fillFrom") (EVar "v")) (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb")))))
(DTypeSig false "fillFrom" (TyFun (TyCon "Int") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit"))))))
(DFunDef false "fillFrom" ((PVar "v") (PVar "bb") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "byteBlockSetUnsafe") (EVar "i")) (EVar "v")) (EVar "bb"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "fillFrom") (EVar "v")) (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "blit" (TyFun (TyCon "MutBytes") (TyFun (TyCon "Int") (TyFun (TyCon "MutBytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit")))))))
(DFunDef false "blit" ((PCon "MutBytes" (PVar "src")) (PVar "srcOff") (PCon "MutBytes" (PVar "dst")) (PVar "dstOff") (PVar "len")) (EIf (EBinOp "<" (EVar "len") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "MutBytes.blit: negative length"))) (EIf (EBinOp "<" (EVar "srcOff") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "MutBytes.blit: negative srcOff"))) (EIf (EBinOp "<" (EVar "dstOff") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "MutBytes.blit: negative dstOff"))) (EIf (EBinOp ">" (EBinOp "+" (EVar "srcOff") (EVar "len")) (EApp (EVar "byteBlockLength") (EVar "src"))) (EApp (EVar "panic") (ELit (LString "MutBytes.blit: source out of bounds"))) (EIf (EBinOp ">" (EBinOp "+" (EVar "dstOff") (EVar "len")) (EApp (EVar "byteBlockLength") (EVar "dst"))) (EApp (EVar "panic") (ELit (LString "MutBytes.blit: destination out of bounds"))) (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "src")) (EVar "srcOff")) (EVar "dst")) (EVar "dstOff")) (EVar "len"))))))))
(DTypeSig true "freeze" (TyFun (TyCon "MutBytes") (TyCon "Bytes")))
(DFunDef false "freeze" ((PCon "MutBytes" (PVar "bb"))) (EApp (EVar "adoptByteBlockUnsafe") (EApp (EApp (EVar "byteBlockCopyUnsafe") (EApp (EVar "byteBlockLength") (EVar "bb"))) (EVar "bb"))))
(DTypeSig true "thaw" (TyFun (TyCon "Bytes") (TyCon "MutBytes")))
(DFunDef false "thaw" ((PVar "b")) (EBlock (DoLet false false (PVar "bb") (EApp (EVar "lendByteBlockUnsafe") (EVar "b"))) (DoExpr (EApp (EVar "MutBytes") (EApp (EApp (EVar "byteBlockCopyUnsafe") (EApp (EVar "byteBlockLength") (EVar "bb"))) (EVar "bb"))))))
(DImpl true "Debug" ((TyCon "MutBytes")) () ((im "debug" ((PCon "MutBytes" (PVar "bb"))) (EBinOp "++" (EBinOp "++" (ELit (LString "Mut")) (EApp (EVar "display") (EApp (EVar "debug") (EApp (EVar "adoptByteBlockUnsafe") (EVar "bb"))))) (ELit (LString ""))))))
# MARK
(DUse false (UseGroup ("core") ((mem "Debug" false) (mem "Index" false) (mem "Option" false))))
(DUse false (UseGroup ("bytes") ((mem "Bytes" false) (mem "adoptByteBlockUnsafe" false) (mem "encodeUtf8" false) (mem "lendByteBlockUnsafe" false) (mem "toArray" false))))
(DNewtype true "MutBytes" () "MutBytes" (TyCon "ByteBlock") ())
(DTypeSig true "make" (TyFun (TyCon "Int") (TyCon "MutBytes")))
(DFunDef false "make" ((PVar "n")) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "MutBytes.make: negative length"))) (EApp (EVar "MutBytes") (EApp (EVar "byteBlockMake") (EVar "n")))))
(DTypeSig true "length#shadow" (TyFun (TyCon "MutBytes") (TyCon "Int")))
(DFunDef false "length#shadow" ((PCon "MutBytes" (PVar "bb"))) (EApp (EVar "byteBlockLength") (EVar "bb")))
(DTypeSig true "get" (TyFun (TyCon "Int") (TyFun (TyCon "MutBytes") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "get" ((PVar "i") (PCon "MutBytes" (PVar "bb"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EVar "None") (EApp (EVar "Some") (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb")))))
(DImpl true "Index" ((TyCon "MutBytes") (TyCon "Int") (TyCon "Int")) () ((im "index" ((PCon "MutBytes" (PVar "bb")) (PVar "i")) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EApp (EVar "indexErrorAt") (EVar "i")) (EApp (EApp (EVar "byteBlockGetUnsafe") (EVar "i")) (EVar "bb"))))))
(DTypeSig true "setInPlace" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "MutBytes") (TyCon "Unit")))))
(DFunDef false "setInPlace" ((PVar "i") (PVar "v") (PCon "MutBytes" (PVar "bb"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "v") (ELit (LInt 0))) (EBinOp ">" (EVar "v") (ELit (LInt 255)))) (EApp (EVar "panic") (ELit (LString "MutBytes.setInPlace: value out of range 0..255"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EBinOp ">=" (EVar "i") (EApp (EVar "byteBlockLength") (EVar "bb")))) (EApp (EVar "panic") (ELit (LString "MutBytes.setInPlace: index out of bounds"))) (EApp (EApp (EApp (EVar "byteBlockSetUnsafe") (EVar "i")) (EVar "v")) (EVar "bb")))))
(DTypeSig true "fill" (TyFun (TyCon "Int") (TyFun (TyCon "MutBytes") (TyCon "Unit"))))
(DFunDef false "fill" ((PVar "v") (PCon "MutBytes" (PVar "bb"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "v") (ELit (LInt 0))) (EBinOp ">" (EVar "v") (ELit (LInt 255)))) (EApp (EVar "panic") (ELit (LString "MutBytes.fill: value out of range 0..255"))) (EApp (EApp (EApp (EApp (EVar "fillFrom") (EVar "v")) (EVar "bb")) (ELit (LInt 0))) (EApp (EVar "byteBlockLength") (EVar "bb")))))
(DTypeSig false "fillFrom" (TyFun (TyCon "Int") (TyFun (TyCon "ByteBlock") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit"))))))
(DFunDef false "fillFrom" ((PVar "v") (PVar "bb") (PVar "i") (PVar "n")) (EIf (EBinOp ">=" (EVar "i") (EVar "n")) (ELit LUnit) (EIf (EVar "otherwise") (EBlock (DoExpr (EApp (EApp (EApp (EVar "byteBlockSetUnsafe") (EVar "i")) (EVar "v")) (EVar "bb"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "fillFrom") (EVar "v")) (EVar "bb")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "n")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "blit" (TyFun (TyCon "MutBytes") (TyFun (TyCon "Int") (TyFun (TyCon "MutBytes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit")))))))
(DFunDef false "blit" ((PCon "MutBytes" (PVar "src")) (PVar "srcOff") (PCon "MutBytes" (PVar "dst")) (PVar "dstOff") (PVar "len")) (EIf (EBinOp "<" (EVar "len") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "MutBytes.blit: negative length"))) (EIf (EBinOp "<" (EVar "srcOff") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "MutBytes.blit: negative srcOff"))) (EIf (EBinOp "<" (EVar "dstOff") (ELit (LInt 0))) (EApp (EVar "panic") (ELit (LString "MutBytes.blit: negative dstOff"))) (EIf (EBinOp ">" (EBinOp "+" (EVar "srcOff") (EVar "len")) (EApp (EVar "byteBlockLength") (EVar "src"))) (EApp (EVar "panic") (ELit (LString "MutBytes.blit: source out of bounds"))) (EIf (EBinOp ">" (EBinOp "+" (EVar "dstOff") (EVar "len")) (EApp (EVar "byteBlockLength") (EVar "dst"))) (EApp (EVar "panic") (ELit (LString "MutBytes.blit: destination out of bounds"))) (EApp (EApp (EApp (EApp (EApp (EVar "byteBlockBlit") (EVar "src")) (EVar "srcOff")) (EVar "dst")) (EVar "dstOff")) (EVar "len"))))))))
(DTypeSig true "freeze" (TyFun (TyCon "MutBytes") (TyCon "Bytes")))
(DFunDef false "freeze" ((PCon "MutBytes" (PVar "bb"))) (EApp (EVar "adoptByteBlockUnsafe") (EApp (EApp (EVar "byteBlockCopyUnsafe") (EApp (EVar "byteBlockLength") (EVar "bb"))) (EVar "bb"))))
(DTypeSig true "thaw" (TyFun (TyCon "Bytes") (TyCon "MutBytes")))
(DFunDef false "thaw" ((PVar "b")) (EBlock (DoLet false false (PVar "bb") (EApp (EVar "lendByteBlockUnsafe") (EVar "b"))) (DoExpr (EApp (EVar "MutBytes") (EApp (EApp (EVar "byteBlockCopyUnsafe") (EApp (EVar "byteBlockLength") (EVar "bb"))) (EVar "bb"))))))
(DImpl true "Debug" ((TyCon "MutBytes")) () ((im "debug" ((PCon "MutBytes" (PVar "bb"))) (EBinOp "++" (EBinOp "++" (ELit (LString "Mut")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EApp (EVar "adoptByteBlockUnsafe") (EVar "bb"))))) (ELit (LString ""))))))
