# META
source_lines=49
stages=DESUGAR,MARK
# SOURCE
import u64
import test.{Expectation, expectAll, expectEach, expectEqual, expectNotEqual}

observeRandom : Unit -> <Rand> (Int, Bool, Float, Char)
observeRandom _ =
  (randomInt (-1000000) 1000000, randomBool (), randomFloat (), randomChar ())

stateRoundtrip : U64 -> <Rand> Expectation
stateRoundtrip state =
  let original = randomState ()
  let _ = restoreRandomState state
  let actual = randomState ()
  let _ = restoreRandomState original
  expectEqual state actual

test "random state capture preserves all 64 bits without drawing" =
  expectEach
    (map
      (state => (debug state, stateRoundtrip state))
      ([0, 1, 9223372036854775808, 18446744073709551615] : List U64))

test "restoring an advanced state replays every deterministic random family" =
  let original = randomState ()
  let _ = setSeed (-1)
  let _ = observeRandom ()
  let snapshot = randomState ()
  let expected = observeRandom ()
  let advanced = randomState ()
  let _ = restoreRandomState snapshot
  let actual = observeRandom ()
  let _ = restoreRandomState original
  expectAll [
    expectNotEqual snapshot advanced,
    expectEqual expected actual,
  ]

test "an isolated random stream leaves the caller continuation intact" =
  let original = randomState ()
  let _ = setSeed 42
  let expected = observeRandom ()
  let _ = setSeed 42
  let caller = randomState ()
  let _ = setSeed 20261005
  let _ = observeRandom ()
  let _ = observeRandom ()
  let _ = restoreRandomState caller
  let actual = observeRandom ()
  let _ = restoreRandomState original
  expectEqual expected actual
# DESUGAR
(DUse false (UseName ("u64")))
(DUse false (UseGroup ("test") ((mem "Expectation" false) (mem "expectAll" false) (mem "expectEach" false) (mem "expectEqual" false) (mem "expectNotEqual" false))))
(DTypeSig false "observeRandom" (TyFun (TyCon "Unit") (TyEffect ("Rand") None (TyTuple (TyCon "Int") (TyCon "Bool") (TyCon "Float") (TyCon "Char")))))
(DFunDef false "observeRandom" (PWild) (ETuple (EApp (EApp (EVar "randomInt") (EUnOp "-" (ELit (LInt 1000000)))) (ELit (LInt 1000000))) (EApp (EVar "randomBool") (ELit LUnit)) (EApp (EVar "randomFloat") (ELit LUnit)) (EApp (EVar "randomChar") (ELit LUnit))))
(DTypeSig false "stateRoundtrip" (TyFun (TyCon "U64") (TyEffect ("Rand") None (TyCon "Expectation"))))
(DFunDef false "stateRoundtrip" ((PVar "state")) (EBlock (DoLet false false (PVar "original") (EApp (EVar "randomState") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "restoreRandomState") (EVar "state"))) (DoLet false false (PVar "actual") (EApp (EVar "randomState") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "restoreRandomState") (EVar "original"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EVar "state")) (EVar "actual")))))
(DTest false "random state capture preserves all 64 bits without drawing" (EApp (EVar "expectEach") (EApp (EApp (EVar "map") (ELam ((PVar "state")) (ETuple (EApp (EVar "debug") (EVar "state")) (EApp (EVar "stateRoundtrip") (EVar "state"))))) (EAnnot (EListLit (ELit (LInt 0)) (ELit (LInt 1)) (ELit (LU64 2147483648 0)) (ELit (LU64 4294967295 4294967295))) (TyApp (TyCon "List") (TyCon "U64"))))))
(DTest false "restoring an advanced state replays every deterministic random family" (EBlock (DoLet false false (PVar "original") (EApp (EVar "randomState") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "setSeed") (EUnOp "-" (ELit (LInt 1))))) (DoLet false false PWild (EApp (EVar "observeRandom") (ELit LUnit))) (DoLet false false (PVar "snapshot") (EApp (EVar "randomState") (ELit LUnit))) (DoLet false false (PVar "expected") (EApp (EVar "observeRandom") (ELit LUnit))) (DoLet false false (PVar "advanced") (EApp (EVar "randomState") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "restoreRandomState") (EVar "snapshot"))) (DoLet false false (PVar "actual") (EApp (EVar "observeRandom") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "restoreRandomState") (EVar "original"))) (DoExpr (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectNotEqual") (EVar "snapshot")) (EVar "advanced")) (EApp (EApp (EVar "expectEqual") (EVar "expected")) (EVar "actual")))))))
(DTest false "an isolated random stream leaves the caller continuation intact" (EBlock (DoLet false false (PVar "original") (EApp (EVar "randomState") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "setSeed") (ELit (LInt 42)))) (DoLet false false (PVar "expected") (EApp (EVar "observeRandom") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "setSeed") (ELit (LInt 42)))) (DoLet false false (PVar "caller") (EApp (EVar "randomState") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "setSeed") (ELit (LInt 20261005)))) (DoLet false false PWild (EApp (EVar "observeRandom") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "observeRandom") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "restoreRandomState") (EVar "caller"))) (DoLet false false (PVar "actual") (EApp (EVar "observeRandom") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "restoreRandomState") (EVar "original"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EVar "expected")) (EVar "actual")))))
# MARK
(DUse false (UseName ("u64")))
(DUse false (UseGroup ("test") ((mem "Expectation" false) (mem "expectAll" false) (mem "expectEach" false) (mem "expectEqual" false) (mem "expectNotEqual" false))))
(DTypeSig false "observeRandom" (TyFun (TyCon "Unit") (TyEffect ("Rand") None (TyTuple (TyCon "Int") (TyCon "Bool") (TyCon "Float") (TyCon "Char")))))
(DFunDef false "observeRandom" (PWild) (ETuple (EApp (EApp (EVar "randomInt") (EUnOp "-" (ELit (LInt 1000000)))) (ELit (LInt 1000000))) (EApp (EVar "randomBool") (ELit LUnit)) (EApp (EVar "randomFloat") (ELit LUnit)) (EApp (EVar "randomChar") (ELit LUnit))))
(DTypeSig false "stateRoundtrip" (TyFun (TyCon "U64") (TyEffect ("Rand") None (TyCon "Expectation"))))
(DFunDef false "stateRoundtrip" ((PVar "state")) (EBlock (DoLet false false (PVar "original") (EApp (EVar "randomState") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "restoreRandomState") (EVar "state"))) (DoLet false false (PVar "actual") (EApp (EVar "randomState") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "restoreRandomState") (EVar "original"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EVar "state")) (EVar "actual")))))
(DTest false "random state capture preserves all 64 bits without drawing" (EApp (EVar "expectEach") (EApp (EApp (EMethodRef "map") (ELam ((PVar "state")) (ETuple (EApp (EMethodRef "debug") (EVar "state")) (EApp (EVar "stateRoundtrip") (EVar "state"))))) (EAnnot (EListLit (ELit (LInt 0)) (ELit (LInt 1)) (ELit (LU64 2147483648 0)) (ELit (LU64 4294967295 4294967295))) (TyApp (TyCon "List") (TyCon "U64"))))))
(DTest false "restoring an advanced state replays every deterministic random family" (EBlock (DoLet false false (PVar "original") (EApp (EVar "randomState") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "setSeed") (EUnOp "-" (ELit (LInt 1))))) (DoLet false false PWild (EApp (EVar "observeRandom") (ELit LUnit))) (DoLet false false (PVar "snapshot") (EApp (EVar "randomState") (ELit LUnit))) (DoLet false false (PVar "expected") (EApp (EVar "observeRandom") (ELit LUnit))) (DoLet false false (PVar "advanced") (EApp (EVar "randomState") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "restoreRandomState") (EVar "snapshot"))) (DoLet false false (PVar "actual") (EApp (EVar "observeRandom") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "restoreRandomState") (EVar "original"))) (DoExpr (EApp (EVar "expectAll") (EListLit (EApp (EApp (EVar "expectNotEqual") (EVar "snapshot")) (EVar "advanced")) (EApp (EApp (EVar "expectEqual") (EVar "expected")) (EVar "actual")))))))
(DTest false "an isolated random stream leaves the caller continuation intact" (EBlock (DoLet false false (PVar "original") (EApp (EVar "randomState") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "setSeed") (ELit (LInt 42)))) (DoLet false false (PVar "expected") (EApp (EVar "observeRandom") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "setSeed") (ELit (LInt 42)))) (DoLet false false (PVar "caller") (EApp (EVar "randomState") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "setSeed") (ELit (LInt 20261005)))) (DoLet false false PWild (EApp (EVar "observeRandom") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "observeRandom") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "restoreRandomState") (EVar "caller"))) (DoLet false false (PVar "actual") (EApp (EVar "observeRandom") (ELit LUnit))) (DoLet false false PWild (EApp (EVar "restoreRandomState") (EVar "original"))) (DoExpr (EApp (EApp (EVar "expectEqual") (EVar "expected")) (EVar "actual")))))
