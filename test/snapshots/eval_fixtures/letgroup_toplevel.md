# META
source_lines=10
stages=CORE_IR
# SOURCE
-- Top-level DLetGroup (`let rec …`) coverage, each mutual-recursion pair
-- expressed as two separate top-level `let rec` bindings.
-- Uses both unconstrained mutual recursion and constrained (== and -) mutual recursion.
let rec ping n = if n then "ping" else pong n
let rec pong n = if n then pong n else "pong"

let rec isEven n = if n == 0 then True else isOdd (n - 1)
let rec isOdd n = if n == 0 then False else isEven (n - 1)

main = (ping False, isEven 4, isOdd 3)
# CORE_IR
(CProgram ((CBind "ping" (CClause ((PVar "n")) (CIf (CVar "n" (ALocal 0 0)) (CLit (LString "ping")) (CApp (CVar "pong" AGlobal) ((CVar "n" (ALocal 0 0))) CallExact true))))
(CBind "pong" (CClause ((PVar "n")) (CIf (CVar "n" (ALocal 0 0)) (CApp (CVar "pong" (ALocal 1 0)) ((CVar "n" (ALocal 0 0))) CallExact true) (CLit (LString "pong")))))
(CBind "isEven" (CClause ((PVar "n")) (CIf (CBinPrim "==" (CVar "n" (ALocal 0 0)) (CLit (LInt 0))) (CVar "True" AGlobal) (CApp (CVar "isOdd" AGlobal) ((CBinPrim "-" (CVar "n" (ALocal 0 0)) (CLit (LInt 1)))) CallExact true))))
(CBind "isOdd" (CClause ((PVar "n")) (CIf (CBinPrim "==" (CVar "n" (ALocal 0 0)) (CLit (LInt 0))) (CVar "False" AGlobal) (CApp (CVar "isEven" AGlobal) ((CBinPrim "-" (CVar "n" (ALocal 0 0)) (CLit (LInt 1)))) CallExact true))))
(CBind "main" (CClause () (CTuple (CApp (CVar "ping" AGlobal) ((CVar "False" AGlobal)) CallExact false) (CApp (CVar "isEven" AGlobal) ((CLit (LInt 4))) CallExact false) (CApp (CVar "isOdd" AGlobal) ((CLit (LInt 3))) CallExact false))))) () () () () (facts () () () none (externs) (manifests) (origins ((function "isEven" (single "isEven")) (function "isOdd" (single "isOdd")) (function "main" (single "main")) (function "ping" (single "ping")) (function "pong" (single "pong"))) ())) (binder-types
(b 0 "" "n" RTValue)
(b 1 "" "n" RTValue)
(b 2 "" "n" RTValue)
(b 3 "" "n" RTValue)
(b 4 "" "ping" RTValue RTValue)
(b 5 "" "pong" RTValue RTValue)
(b 6 "" "isEven" RTValue RTValue)
(b 7 "" "isOdd" RTValue RTValue)
(b 8 "" "main" RTValue RTValue)))
