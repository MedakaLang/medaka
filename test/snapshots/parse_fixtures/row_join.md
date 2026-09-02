# META
source_lines=34
stages=PARSE,PRINTER,DESUGAR,MARK
# SOURCE
-- Effect-row JOINS written in a signature (#821,
-- docs/spec/EFFECTS-SEMANTICS.md §6): a row may name SEVERAL tail variables,
-- meaning "everything any of them performs".  Enrolled in diff_compiler_fmt.sh
-- via test/parse_fixtures/*.mdk, so row_join.fmt.golden pins the byte-for-byte
-- round trip of both spellings: a LABELLED join keeps the angle brackets
-- (`<Stdout | e | e2>`), a label-free one in an Effect-kinded type-ARGUMENT
-- slot is written with parentheses (`f (e | e2) b`).

data Later (e : Effect) a = Now a | Wait (Unit -> <e> Later e a)

-- the parenthesised spelling, in the result index of a method
interface JMap (f : Effect -> Type -> Type) where
  jmap : (a -> <e2> b) -> f e a -> f (e | e2) b

impl JMap Later where
  jmap g (Now a) = Wait (u => Now (g a))
  jmap g (Wait t) = Wait (u => jmap g (t u))

-- a labelled join, in both an argument row and the return row
relay : (Unit -> <Stdout | e | e2> Unit) -> <Stdout | e | e2> Unit
relay k = k ()

-- three tail variables, in a type-argument slot
wide : Later (e | e2 | e3) Int -> Later (e | e2 | e3) Int
wide l = l

-- the pre-#821 single-tail and closed spellings are unchanged
single : Later e Int -> <Stdout | e> Int
single (Now n) = n
single (Wait t) = single (t ())

closed : Later <> Int -> <Stdout> Int
closed (Now n) = n
closed (Wait t) = closed (t ())
# PARSE
(DData Private "Later" ("e" "a") ((variant "Now" (ConPos (TyVar "a"))) (variant "Wait" (ConPos (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Later") (TyVar "e")) (TyVar "a"))))))) ())
(DInterface false false "JMap" ("f") () ((imethod "jmap" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e2") (TyVar "b"))) (TyFun (TyApp (TyApp (TyVar "f") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyVar "f") (TyRow () (Join "e" "e2"))) (TyVar "b")))) None)))
(DImpl false "JMap" ((TyCon "Later")) () ((im "jmap" ((PVar "g") (PCon "Now" (PVar "a"))) (EApp (EVar "Wait") (ELam ((PVar "u")) (EApp (EVar "Now") (EApp (EVar "g") (EVar "a")))))) (im "jmap" ((PVar "g") (PCon "Wait" (PVar "t"))) (EApp (EVar "Wait") (ELam ((PVar "u")) (EApp (EApp (EVar "jmap") (EVar "g")) (EApp (EVar "t") (EVar "u"))))))))
(DTypeSig false "relay" (TyFun (TyFun (TyCon "Unit") (TyEffect ("Stdout") (Join "e" "e2") (TyCon "Unit"))) (TyEffect ("Stdout") (Join "e" "e2") (TyCon "Unit"))))
(DFunDef false "relay" ((PVar "k")) (EApp (EVar "k") (ELit LUnit)))
(DTypeSig false "wide" (TyFun (TyApp (TyApp (TyCon "Later") (TyRow () (Join "e" "e2" "e3"))) (TyCon "Int")) (TyApp (TyApp (TyCon "Later") (TyRow () (Join "e" "e2" "e3"))) (TyCon "Int"))))
(DFunDef false "wide" ((PVar "l")) (EVar "l"))
(DTypeSig false "single" (TyFun (TyApp (TyApp (TyCon "Later") (TyVar "e")) (TyCon "Int")) (TyEffect ("Stdout") (Some "e") (TyCon "Int"))))
(DFunDef false "single" ((PCon "Now" (PVar "n"))) (EVar "n"))
(DFunDef false "single" ((PCon "Wait" (PVar "t"))) (EApp (EVar "single") (EApp (EVar "t") (ELit LUnit))))
(DTypeSig false "closed" (TyFun (TyApp (TyApp (TyCon "Later") (TyRow () None)) (TyCon "Int")) (TyEffect ("Stdout") None (TyCon "Int"))))
(DFunDef false "closed" ((PCon "Now" (PVar "n"))) (EVar "n"))
(DFunDef false "closed" ((PCon "Wait" (PVar "t"))) (EApp (EVar "closed") (EApp (EVar "t") (ELit LUnit))))
# PRINTER
data Later (e : Effect) a = Now a | Wait (Unit -> <e> Later e a)
interface JMap (f : Effect -> Type -> Type) where
  jmap : (a -> <e2> b) -> f e a -> f (e | e2) b
impl JMap Later where
  jmap g (Now a) = Wait (u => Now (g a))
  jmap g (Wait t) = Wait (u => jmap g (t u))
relay : (Unit -> <Stdout | e | e2> Unit) -> <Stdout | e | e2> Unit
relay k = k ()
wide : Later (e | e2 | e3) Int -> Later (e | e2 | e3) Int
wide l = l
single : Later e Int -> <Stdout | e> Int
single (Now n) = n
single (Wait t) = single (t ())
closed : Later <> Int -> <Stdout> Int
closed (Now n) = n
closed (Wait t) = closed (t ())
# DESUGAR
(DData Private "Later" ("e" "a") ((variant "Now" (ConPos (TyVar "a"))) (variant "Wait" (ConPos (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Later") (TyVar "e")) (TyVar "a"))))))) ())
(DInterface false false "JMap" ("f") () ((imethod "jmap" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e2") (TyVar "b"))) (TyFun (TyApp (TyApp (TyVar "f") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyVar "f") (TyRow () (Join "e" "e2"))) (TyVar "b")))) None)))
(DImpl false "JMap" ((TyCon "Later")) () ((im "jmap" ((PVar "g") (PCon "Now" (PVar "a"))) (EApp (EVar "Wait") (ELam ((PVar "u")) (EApp (EVar "Now") (EApp (EVar "g") (EVar "a")))))) (im "jmap" ((PVar "g") (PCon "Wait" (PVar "t"))) (EApp (EVar "Wait") (ELam ((PVar "u")) (EApp (EApp (EVar "jmap") (EVar "g")) (EApp (EVar "t") (EVar "u"))))))))
(DTypeSig false "relay" (TyFun (TyFun (TyCon "Unit") (TyEffect ("Stdout") (Join "e" "e2") (TyCon "Unit"))) (TyEffect ("Stdout") (Join "e" "e2") (TyCon "Unit"))))
(DFunDef false "relay" ((PVar "k")) (EApp (EVar "k") (ELit LUnit)))
(DTypeSig false "wide" (TyFun (TyApp (TyApp (TyCon "Later") (TyRow () (Join "e" "e2" "e3"))) (TyCon "Int")) (TyApp (TyApp (TyCon "Later") (TyRow () (Join "e" "e2" "e3"))) (TyCon "Int"))))
(DFunDef false "wide" ((PVar "l")) (EVar "l"))
(DTypeSig false "single" (TyFun (TyApp (TyApp (TyCon "Later") (TyVar "e")) (TyCon "Int")) (TyEffect ("Stdout") (Some "e") (TyCon "Int"))))
(DFunDef false "single" ((PCon "Now" (PVar "n"))) (EVar "n"))
(DFunDef false "single" ((PCon "Wait" (PVar "t"))) (EApp (EVar "single") (EApp (EVar "t") (ELit LUnit))))
(DTypeSig false "closed" (TyFun (TyApp (TyApp (TyCon "Later") (TyRow () None)) (TyCon "Int")) (TyEffect ("Stdout") None (TyCon "Int"))))
(DFunDef false "closed" ((PCon "Now" (PVar "n"))) (EVar "n"))
(DFunDef false "closed" ((PCon "Wait" (PVar "t"))) (EApp (EVar "closed") (EApp (EVar "t") (ELit LUnit))))
# MARK
(DData Private "Later" ("e" "a") ((variant "Now" (ConPos (TyVar "a"))) (variant "Wait" (ConPos (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Later") (TyVar "e")) (TyVar "a"))))))) ())
(DInterface false false "JMap" ("f") () ((imethod "jmap" (TyFun (TyFun (TyVar "a") (TyEffect () (Some "e2") (TyVar "b"))) (TyFun (TyApp (TyApp (TyVar "f") (TyVar "e")) (TyVar "a")) (TyApp (TyApp (TyVar "f") (TyRow () (Join "e" "e2"))) (TyVar "b")))) None)))
(DImpl false "JMap" ((TyCon "Later")) () ((im "jmap" ((PVar "g") (PCon "Now" (PVar "a"))) (EApp (EVar "Wait") (ELam ((PVar "u")) (EApp (EVar "Now") (EApp (EVar "g") (EVar "a")))))) (im "jmap" ((PVar "g") (PCon "Wait" (PVar "t"))) (EApp (EVar "Wait") (ELam ((PVar "u")) (EApp (EApp (EMethodRef "jmap") (EVar "g")) (EApp (EVar "t") (EVar "u"))))))))
(DTypeSig false "relay" (TyFun (TyFun (TyCon "Unit") (TyEffect ("Stdout") (Join "e" "e2") (TyCon "Unit"))) (TyEffect ("Stdout") (Join "e" "e2") (TyCon "Unit"))))
(DFunDef false "relay" ((PVar "k")) (EApp (EVar "k") (ELit LUnit)))
(DTypeSig false "wide" (TyFun (TyApp (TyApp (TyCon "Later") (TyRow () (Join "e" "e2" "e3"))) (TyCon "Int")) (TyApp (TyApp (TyCon "Later") (TyRow () (Join "e" "e2" "e3"))) (TyCon "Int"))))
(DFunDef false "wide" ((PVar "l")) (EVar "l"))
(DTypeSig false "single" (TyFun (TyApp (TyApp (TyCon "Later") (TyVar "e")) (TyCon "Int")) (TyEffect ("Stdout") (Some "e") (TyCon "Int"))))
(DFunDef false "single" ((PCon "Now" (PVar "n"))) (EVar "n"))
(DFunDef false "single" ((PCon "Wait" (PVar "t"))) (EApp (EVar "single") (EApp (EVar "t") (ELit LUnit))))
(DTypeSig false "closed" (TyFun (TyApp (TyApp (TyCon "Later") (TyRow () None)) (TyCon "Int")) (TyEffect ("Stdout") None (TyCon "Int"))))
(DFunDef false "closed" ((PCon "Now" (PVar "n"))) (EVar "n"))
(DFunDef false "closed" ((PCon "Wait" (PVar "t"))) (EApp (EVar "closed") (EApp (EVar "t") (ELit LUnit))))
