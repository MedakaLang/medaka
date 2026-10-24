# META
source_lines=14
stages=DESUGAR,MARK
# SOURCE
{- | SHA-256 of non-secret data, computed in the runtime.

   `sha256Fast` returns the same 32-byte digest as `crypto.sha256.sha256`.
   The runtime kernel makes no constant-time promise, so code that hashes
   secret material (HMAC, signing) uses `crypto.sha256.sha256`, the audited
   Medaka implementation, and never this module. -}

import bytes.{Bytes, adoptByteBlockUnsafe, lendByteBlockUnsafe}

{- | The 32-byte SHA-256 digest of `msg`, computed natively. -}
export
sha256Fast : Bytes -> Bytes
-- lint-disable-next-line rule-stdlib-reimpl
sha256Fast msg = adoptByteBlockUnsafe (sha256Native (lendByteBlockUnsafe msg))
# DESUGAR
(DUse false (UseGroup ("bytes") ((mem "Bytes" false) (mem "adoptByteBlockUnsafe" false) (mem "lendByteBlockUnsafe" false))))
(DTypeSig true "sha256Fast" (TyFun (TyCon "Bytes") (TyCon "Bytes")))
(DFunDef false "sha256Fast" ((PVar "msg")) (EApp (EVar "adoptByteBlockUnsafe") (EApp (EVar "sha256Native") (EApp (EVar "lendByteBlockUnsafe") (EVar "msg")))))
# MARK
(DUse false (UseGroup ("bytes") ((mem "Bytes" false) (mem "adoptByteBlockUnsafe" false) (mem "lendByteBlockUnsafe" false))))
(DTypeSig true "sha256Fast" (TyFun (TyCon "Bytes") (TyCon "Bytes")))
(DFunDef false "sha256Fast" ((PVar "msg")) (EApp (EVar "adoptByteBlockUnsafe") (EApp (EVar "sha256Native") (EApp (EVar "lendByteBlockUnsafe") (EVar "msg")))))
