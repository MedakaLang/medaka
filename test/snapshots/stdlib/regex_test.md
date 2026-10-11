# META
source_lines=46
stages=DESUGAR,MARK
# SOURCE
-- Tests for the `^` anchor and alternation in `stdlib/regex.mdk`.
--
-- A `^` that is not on every path through the pattern must not restrict the
-- search to the start of the subject, and alternation branches keep their
-- source order.

import regex.{Match, find, mustCompile}
import test.{expectEqual}

foundText : String -> String -> Option String
foundText pattern subject =
  map (m => (m : Match).text) (find (mustCompile pattern) subject)

-- # Anchors

test "a leading ^ matches at the start" =
  expectEqual (Some "abc") (foundText "^abc" "abcabc")

test "a leading ^ does not match later in the subject" =
  expectEqual None (foundText "^abc" "xabc")

test "^ in one alternative leaves the other alternative unanchored" =
  expectEqual (Some "b") (foundText "^a|b" "xb")

test "^ inside a group in one alternative leaves the other unanchored" =
  expectEqual (Some "b") (foundText "(^a|b)" "xb")

test "a grouped ^ before an alternation leaves the other branch unanchored" =
  expectEqual (Some "b") (foundText "(^a)|b" "xb")

test "(?m)^ matches at a later line start" =
  expectEqual (Some "b") (foundText "(?m)^b" "a\nb")

-- # Alternation

test "alternation prefers the earlier branch" =
  expectEqual (Some "a") (foundText "a|ab|abc|abcd" "abcd")

test "a wide alternation finds its branch in source order" =
  expectEqual (Some "w4") (foundText "w0|w1|w2|w3|w4|w5" "xxw4w5")

test "a nested alternation keeps source priority" =
  expectEqual (Some "a") (foundText "(a|ab)|abc" "abc")

test "an empty last branch matches the empty string" =
  expectEqual (Some "") (foundText "a|b|" "x")
# DESUGAR
(DUse false (UseGroup ("regex") ((mem "Match" false) (mem "find" false) (mem "mustCompile" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false))))
(DTypeSig false "foundText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "foundText" ((PVar "pattern") (PVar "subject")) (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EFieldAccess (EAnnot (EVar "m") (TyCon "Match")) "text"))) (EApp (EApp (EVar "find") (EApp (EVar "mustCompile") (EVar "pattern"))) (EVar "subject"))))
(DTest false "a leading ^ matches at the start" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "abc")))) (EApp (EApp (EVar "foundText") (ELit (LString "^abc"))) (ELit (LString "abcabc")))))
(DTest false "a leading ^ does not match later in the subject" (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EApp (EVar "foundText") (ELit (LString "^abc"))) (ELit (LString "xabc")))))
(DTest false "^ in one alternative leaves the other alternative unanchored" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "b")))) (EApp (EApp (EVar "foundText") (ELit (LString "^a|b"))) (ELit (LString "xb")))))
(DTest false "^ inside a group in one alternative leaves the other unanchored" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "b")))) (EApp (EApp (EVar "foundText") (ELit (LString "(^a|b)"))) (ELit (LString "xb")))))
(DTest false "a grouped ^ before an alternation leaves the other branch unanchored" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "b")))) (EApp (EApp (EVar "foundText") (ELit (LString "(^a)|b"))) (ELit (LString "xb")))))
(DTest false "(?m)^ matches at a later line start" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "b")))) (EApp (EApp (EVar "foundText") (ELit (LString "(?m)^b"))) (ELit (LString "a\nb")))))
(DTest false "alternation prefers the earlier branch" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "a")))) (EApp (EApp (EVar "foundText") (ELit (LString "a|ab|abc|abcd"))) (ELit (LString "abcd")))))
(DTest false "a wide alternation finds its branch in source order" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "w4")))) (EApp (EApp (EVar "foundText") (ELit (LString "w0|w1|w2|w3|w4|w5"))) (ELit (LString "xxw4w5")))))
(DTest false "a nested alternation keeps source priority" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "a")))) (EApp (EApp (EVar "foundText") (ELit (LString "(a|ab)|abc"))) (ELit (LString "abc")))))
(DTest false "an empty last branch matches the empty string" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "")))) (EApp (EApp (EVar "foundText") (ELit (LString "a|b|"))) (ELit (LString "x")))))
# MARK
(DUse false (UseGroup ("regex") ((mem "Match" false) (mem "find" false) (mem "mustCompile" false))))
(DUse false (UseGroup ("test") ((mem "expectEqual" false))))
(DTypeSig false "foundText" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "foundText" ((PVar "pattern") (PVar "subject")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EFieldAccess (EAnnot (EVar "m") (TyCon "Match")) "text"))) (EApp (EApp (EDictApp "find") (EApp (EVar "mustCompile") (EVar "pattern"))) (EVar "subject"))))
(DTest false "a leading ^ matches at the start" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "abc")))) (EApp (EApp (EVar "foundText") (ELit (LString "^abc"))) (ELit (LString "abcabc")))))
(DTest false "a leading ^ does not match later in the subject" (EApp (EApp (EVar "expectEqual") (EVar "None")) (EApp (EApp (EVar "foundText") (ELit (LString "^abc"))) (ELit (LString "xabc")))))
(DTest false "^ in one alternative leaves the other alternative unanchored" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "b")))) (EApp (EApp (EVar "foundText") (ELit (LString "^a|b"))) (ELit (LString "xb")))))
(DTest false "^ inside a group in one alternative leaves the other unanchored" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "b")))) (EApp (EApp (EVar "foundText") (ELit (LString "(^a|b)"))) (ELit (LString "xb")))))
(DTest false "a grouped ^ before an alternation leaves the other branch unanchored" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "b")))) (EApp (EApp (EVar "foundText") (ELit (LString "(^a)|b"))) (ELit (LString "xb")))))
(DTest false "(?m)^ matches at a later line start" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "b")))) (EApp (EApp (EVar "foundText") (ELit (LString "(?m)^b"))) (ELit (LString "a\nb")))))
(DTest false "alternation prefers the earlier branch" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "a")))) (EApp (EApp (EVar "foundText") (ELit (LString "a|ab|abc|abcd"))) (ELit (LString "abcd")))))
(DTest false "a wide alternation finds its branch in source order" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "w4")))) (EApp (EApp (EVar "foundText") (ELit (LString "w0|w1|w2|w3|w4|w5"))) (ELit (LString "xxw4w5")))))
(DTest false "a nested alternation keeps source priority" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "a")))) (EApp (EApp (EVar "foundText") (ELit (LString "(a|ab)|abc"))) (ELit (LString "abc")))))
(DTest false "an empty last branch matches the empty string" (EApp (EApp (EVar "expectEqual") (EApp (EVar "Some") (ELit (LString "")))) (EApp (EApp (EVar "foundText") (ELit (LString "a|b|"))) (ELit (LString "x")))))
