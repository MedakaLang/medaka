# META
source_lines=121
stages=DESUGAR,MARK
# SOURCE
-- async.mdk — Medaka's basic, swappable cooperative-concurrency layer.
--
-- See ASYNC-DESIGN.md for the locked design. v1 is PURE MEDAKA (D6): the
-- scheduler is a pure interpreter of a trampolined `Async e a` description; no
-- eval.ml / runtime.c primitives. The cooperative-concurrency *contract* (D3)
-- is committed to (tasks interleave at yield boundaries, single-thread, no
-- parallelism), implemented as a degenerate sequential scheduler — swapping the
-- scheduler later changes performance + parallelism, never observable behavior.
--
-- Errors ride `Result` inside `Async` (D4); there is no rejected-promise
-- channel and `panic` still aborts the process uncatchably.
--
-- EFFECT POLYMORPHISM (D2 done precisely).  `Async` is parametric in an effect
-- ROW `e` as well as its value `a`: a `Suspend` thunk performs `<e>`, so the
-- type *carries* exactly the capabilities the suspended work needs — just as
-- `Result` carries errors instead of a `Throws` effect.  `runAsync` then
-- performs *exactly* that stored row (`Async e a -> <e> a`): an `Async <> a`
-- runs purely, an `Async <IO> a` performs `<IO>`.  This relies on effect-row
-- parameters on data declarations (`e` is kind-inferred KRow from its use in
-- the `Suspend` field's effect tail); see the `data Async e a` note.

-- | A deferred computation: either a finished value, or a thunk producing the
-- next step.  This is the trampoline / free-monad-ish encoding (ASYNC-DESIGN
-- §2.1) — `Suspend` boundaries are the yield points the scheduler interleaves
-- on.  The thunk performs `<e>`, so `e` is the row this computation rides.
export data Async (e : Effect) a = Done a | Suspend (Unit -> <e> Async e a)

-- The interface instances are the DEFERRED family (core.mdk `Deferred*`):
-- the instance head is the bare constructor `Async : Effect -> Type -> Type`,
-- and the effect of a callback rides the INDEX, not the method's arrow.  Every
-- arm STORES its callback under a `Suspend` — an eager `Done (f a)` would
-- perform the callback's row at construction, from a call typed pure, and is
-- rejected (`T-EFFECT-INDEX-EAGER`).  Cost accepted with that ruling: a
-- map/bind on an already-`Done` value allocates one `Suspend` and pays one
-- extra `runAsync` round.
export impl DeferredMappable Async where
  deferMap f (Done a) = Suspend (u => Done (f a))
  deferMap f (Suspend t) = Suspend (u => deferMap f (t u))

export impl DeferredApplicative Async where
  deferPure a = Done a
  deferAp mf ma = deferThen mf (f => deferMap f ma)

export impl DeferredThenable Async where
  deferThen (Done a) k = Suspend (u => k a)
  deferThen (Suspend t) k = Suspend (u => deferThen (t u) k)

-- | Lift an effectful (or pure) thunk into `Async`, deferring it behind one
-- `Suspend` boundary.  `liftIO (u => putStrLn "hi") : Async <Stdout> Unit`;
-- `runAsync`-ing it performs the `<Stdout>`.  A pure thunk yields `Async <> a`.
export
liftIO : (Unit -> <e> a) -> Async e a
liftIO act = Suspend (u => Done (act u))

-- | A cooperative yield point: hand control back to the scheduler, then resume.
-- Inert for a single chain; observable only once `concurrent` interleaves tasks.
-- Performs nothing, so it rides any row `e`.
export
yield : Async e Unit
yield = Suspend (_ => Done ())

-- | Drive one computation to its value (ASYNC-DESIGN §2.2), performing exactly
-- its row `e`.  Forces `Suspend` thunks until `Done`.  This is a tail-loop; for
-- a single chain it is just sequential execution.  (Compiled code TCOs this via
-- `-O2`, so a single chain is unbounded; the `medaka run` interpreter caps deep
-- chains at ~100–500k.  No stdlib rewrite needed when the runtime swap lands.)
export
runAsync : Async e a -> <e> a
runAsync (Done a) = a
runAsync (Suspend t) = runAsync (t ())

-- internal — advance one step (a `Suspend` round, or stay `Done`).
stepAsync : Async e a -> <e> Async e a
stepAsync (Done a) = Done a
stepAsync (Suspend t) = t ()

-- internal — is this computation finished?
isDone : Async e a -> Bool
isDone (Done _) = True
isDone (Suspend _) = False

-- internal — extract a finished value (only called once every task is `Done`).
forceVal : Async e a -> a
forceVal (Done a) = a
forceVal (Suspend _) = panic "async: forceVal on an unfinished computation"

-- | Run N computations concurrently, collecting results in input order once all
-- complete (ASYNC-DESIGN §2.3, D8 structured concurrency).  v1 advances each
-- task one `Suspend` round-robin so the interleave is *observable* even under
-- the sequential scheduler — surfaces order-dependent bugs before the real
-- scheduler lands.  Because v1 I/O externs block, this gains no wall-clock
-- overlap; the *semantics* are the production semantics (the point of D3).
export
concurrent : List (Async e a) -> <e> Async e (List a)
concurrent asyncs
  | all isDone asyncs = Done (map forceVal asyncs)
concurrent asyncs = Suspend (_ => concurrent (map stepAsync asyncs))

{- Doctests.

   > runAsync (Done 5)
   5

   > runAsync (deferMap (x => x + 1) (Done 4))
   5

   > runAsync (deferAp (Done (x => x * 2)) (Done 21))
   42

   > runAsync (deferThen (Done 10) (x => Done (x + 5)))
   15

   > runAsync (deferThen yield (_ => Done 99))
   99

   > runAsync (liftIO (u => 21 + 21))
   42

   > runAsync (concurrent [Done 1, Done 2, Done 3])
   [1, 2, 3]
-}
# DESUGAR
(DData Abstract "Async" ("e" "a") ((variant "Done" (ConPos (TyVar "a"))) (variant "Suspend" (ConPos (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))))) ())
(DImpl true "DeferredMappable" ((TyCon "Async")) () ((im "deferMap" ((PVar "f") (PCon "Done" (PVar "a"))) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EVar "f") (EVar "a")))))) (im "deferMap" ((PVar "f") (PCon "Suspend" (PVar "t"))) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EVar "deferMap") (EVar "f")) (EApp (EVar "t") (EVar "u"))))))))
(DImpl true "DeferredApplicative" ((TyCon "Async")) () ((im "deferPure" ((PVar "a")) (EApp (EVar "Done") (EVar "a"))) (im "deferAp" ((PVar "mf") (PVar "ma")) (EApp (EApp (EVar "deferThen") (EVar "mf")) (ELam ((PVar "f")) (EApp (EApp (EVar "deferMap") (EVar "f")) (EVar "ma")))))))
(DImpl true "DeferredThenable" ((TyCon "Async")) () ((im "deferThen" ((PCon "Done" (PVar "a")) (PVar "k")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "k") (EVar "a"))))) (im "deferThen" ((PCon "Suspend" (PVar "t")) (PVar "k")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EVar "deferThen") (EApp (EVar "t") (EVar "u"))) (EVar "k")))))))
(DTypeSig true "liftIO" (TyFun (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyVar "a"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))
(DFunDef false "liftIO" ((PVar "act")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EVar "act") (EVar "u"))))))
(DTypeSig true "yield" (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))
(DFunDef false "yield" () (EApp (EVar "Suspend") (ELam (PWild) (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig true "runAsync" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyEffect () (Some "e") (TyVar "a"))))
(DFunDef false "runAsync" ((PCon "Done" (PVar "a"))) (EVar "a"))
(DFunDef false "runAsync" ((PCon "Suspend" (PVar "t"))) (EApp (EVar "runAsync") (EApp (EVar "t") (ELit LUnit))))
(DTypeSig false "stepAsync" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")))))
(DFunDef false "stepAsync" ((PCon "Done" (PVar "a"))) (EApp (EVar "Done") (EVar "a")))
(DFunDef false "stepAsync" ((PCon "Suspend" (PVar "t"))) (EApp (EVar "t") (ELit LUnit)))
(DTypeSig false "isDone" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isDone" ((PCon "Done" PWild)) (EVar "True"))
(DFunDef false "isDone" ((PCon "Suspend" PWild)) (EVar "False"))
(DTypeSig false "forceVal" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyVar "a")))
(DFunDef false "forceVal" ((PCon "Done" (PVar "a"))) (EVar "a"))
(DFunDef false "forceVal" ((PCon "Suspend" PWild)) (EApp (EVar "panic") (ELit (LString "async: forceVal on an unfinished computation"))))
(DTypeSig true "concurrent" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))) (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "concurrent" ((PVar "asyncs")) (EIf (EApp (EApp (EVar "all") (EVar "isDone")) (EVar "asyncs")) (EApp (EVar "Done") (EApp (EApp (EVar "map") (EVar "forceVal")) (EVar "asyncs"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "concurrent" ((PVar "asyncs")) (EApp (EVar "Suspend") (ELam (PWild) (EApp (EVar "concurrent") (EApp (EApp (EVar "map") (EVar "stepAsync")) (EVar "asyncs"))))))
# MARK
(DData Abstract "Async" ("e" "a") ((variant "Done" (ConPos (TyVar "a"))) (variant "Suspend" (ConPos (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))))) ())
(DImpl true "DeferredMappable" ((TyCon "Async")) () ((im "deferMap" ((PVar "f") (PCon "Done" (PVar "a"))) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EVar "f") (EVar "a")))))) (im "deferMap" ((PVar "f") (PCon "Suspend" (PVar "t"))) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EMethodRef "deferMap") (EVar "f")) (EApp (EVar "t") (EVar "u"))))))))
(DImpl true "DeferredApplicative" ((TyCon "Async")) () ((im "deferPure" ((PVar "a")) (EApp (EVar "Done") (EVar "a"))) (im "deferAp" ((PVar "mf") (PVar "ma")) (EApp (EApp (EMethodRef "deferThen") (EVar "mf")) (ELam ((PVar "f")) (EApp (EApp (EMethodRef "deferMap") (EVar "f")) (EVar "ma")))))))
(DImpl true "DeferredThenable" ((TyCon "Async")) () ((im "deferThen" ((PCon "Done" (PVar "a")) (PVar "k")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "k") (EVar "a"))))) (im "deferThen" ((PCon "Suspend" (PVar "t")) (PVar "k")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "t") (EVar "u"))) (EVar "k")))))))
(DTypeSig true "liftIO" (TyFun (TyFun (TyCon "Unit") (TyEffect () (Some "e") (TyVar "a"))) (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))))
(DFunDef false "liftIO" ((PVar "act")) (EApp (EVar "Suspend") (ELam ((PVar "u")) (EApp (EVar "Done") (EApp (EVar "act") (EVar "u"))))))
(DTypeSig true "yield" (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyCon "Unit")))
(DFunDef false "yield" () (EApp (EVar "Suspend") (ELam (PWild) (EApp (EVar "Done") (ELit LUnit)))))
(DTypeSig true "runAsync" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyEffect () (Some "e") (TyVar "a"))))
(DFunDef false "runAsync" ((PCon "Done" (PVar "a"))) (EVar "a"))
(DFunDef false "runAsync" ((PCon "Suspend" (PVar "t"))) (EApp (EVar "runAsync") (EApp (EVar "t") (ELit LUnit))))
(DTypeSig false "stepAsync" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")))))
(DFunDef false "stepAsync" ((PCon "Done" (PVar "a"))) (EApp (EVar "Done") (EVar "a")))
(DFunDef false "stepAsync" ((PCon "Suspend" (PVar "t"))) (EApp (EVar "t") (ELit LUnit)))
(DTypeSig false "isDone" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyCon "Bool")))
(DFunDef false "isDone" ((PCon "Done" PWild)) (EVar "True"))
(DFunDef false "isDone" ((PCon "Suspend" PWild)) (EVar "False"))
(DTypeSig false "forceVal" (TyFun (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a")) (TyVar "a")))
(DFunDef false "forceVal" ((PCon "Done" (PVar "a"))) (EVar "a"))
(DFunDef false "forceVal" ((PCon "Suspend" PWild)) (EApp (EVar "panic") (ELit (LString "async: forceVal on an unfinished computation"))))
(DTypeSig true "concurrent" (TyFun (TyApp (TyCon "List") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyVar "a"))) (TyEffect () (Some "e") (TyApp (TyApp (TyCon "Async") (TyVar "e")) (TyApp (TyCon "List") (TyVar "a"))))))
(DFunDef false "concurrent" ((PVar "asyncs")) (EIf (EApp (EApp (EDictApp "all") (EVar "isDone")) (EVar "asyncs")) (EApp (EVar "Done") (EApp (EApp (EMethodRef "map") (EVar "forceVal")) (EVar "asyncs"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "concurrent" ((PVar "asyncs")) (EApp (EVar "Suspend") (ELam (PWild) (EApp (EVar "concurrent") (EApp (EApp (EMethodRef "map") (EVar "stepAsync")) (EVar "asyncs"))))))
