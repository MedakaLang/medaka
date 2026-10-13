# META
source_lines=23
stages=CORE_IR
# SOURCE
-- range patterns through the decision tree (PRng arms with fall-through)
classify n = match n
  0..=4 => "tiny"
  5..=9 => "small"
  _ => "big"

hexDigit c = match c
  '0'..'9' => "num"
  'a'..'f' => "lo"
  'A'..'F' => "hi"
  _ => "no"

main =
  ( classify 0
  , classify 4
  , classify 5
  , classify 9
  , classify 10
  , hexDigit '3'
  , hexDigit 'b'
  , hexDigit 'E'
  , hexDigit 'z'
  )
# CORE_IR
(CProgram ((CBind "classify" (CClause ((PVar "n")) (CDecision (CVar "n" (ALocal 0 0)) ((arm (PRng (LInt 0) (LInt 4) true) () (CLit (LString "tiny"))) (arm (PRng (LInt 5) (LInt 9) true) () (CLit (LString "small"))) (arm PWild () (CLit (LString "big")))) (CTGuard 0 (CTGuard 1 (CTLeaf 2))))))
(CBind "hexDigit" (CClause ((PVar "c")) (CDecision (CVar "c" (ALocal 0 0)) ((arm (PRng (LChar "0") (LChar "9") false) () (CLit (LString "num"))) (arm (PRng (LChar "a") (LChar "f") false) () (CLit (LString "lo"))) (arm (PRng (LChar "A") (LChar "F") false) () (CLit (LString "hi"))) (arm PWild () (CLit (LString "no")))) (CTGuard 0 (CTGuard 1 (CTGuard 2 (CTLeaf 3)))))))
(CBind "main" (CClause () (CTuple (CApp (CVar "classify" AGlobal) ((CLit (LInt 0))) CallExact false) (CApp (CVar "classify" AGlobal) ((CLit (LInt 4))) CallExact false) (CApp (CVar "classify" AGlobal) ((CLit (LInt 5))) CallExact false) (CApp (CVar "classify" AGlobal) ((CLit (LInt 9))) CallExact false) (CApp (CVar "classify" AGlobal) ((CLit (LInt 10))) CallExact false) (CApp (CVar "hexDigit" AGlobal) ((CLit (LChar "3"))) CallExact false) (CApp (CVar "hexDigit" AGlobal) ((CLit (LChar "b"))) CallExact false) (CApp (CVar "hexDigit" AGlobal) ((CLit (LChar "E"))) CallExact false) (CApp (CVar "hexDigit" AGlobal) ((CLit (LChar "z"))) CallExact false))))) () () () () (facts () ()) (binder-types
(b 0 "" "n" RTValue)
(b 1 "" "c" RTValue)
(b 2 "" "classify" RTValue RTValue)
(b 3 "" "hexDigit" RTValue RTValue)
(b 4 "" "main" RTValue RTValue)))
