# META
source_lines=57
stages=DESUGAR,MARK
# SOURCE
-- A binding owns the effects of evaluating its source body, not every arrow in
-- the value it returns. The syntactic arity separates thunk initialization from
-- invocation and prevents returned closures from donating their effect slots.
import types.repr.{Mono(..), normalize}
import types.effect_rows.{EffRow(..)}

pureRow : EffRow
pureRow = EffRow [] None

public export data BindingSummary = BindingSummary {
  bsArity : Int,
  bsValue : Mono,
  bsRecursiveValue : Mono,
  bsBody : EffRow,
  bsForce : EffRow,
}

export
bodyArrows : List Mono -> EffRow -> Mono -> Mono
bodyArrows [] _ result = result
bodyArrows [param] body result = TFun param body result
bodyArrows (param :: rest) body result =
  TFun param pureRow (bodyArrows rest body result)

export
newBindingSummary : Int -> (Unit -> Mono) -> (Unit -> EffRow) -> BindingSummary
newBindingSummary arity freshType freshSummary =
  let body = freshSummary ()
  let (published, recursive) = freshBodyValues arity freshType body
  BindingSummary {
    bsArity = arity,
    bsValue = published,
    bsRecursiveValue = recursive,
    bsBody = body,
    bsForce = if arity == 0 then body else pureRow,
  }

-- Inputs and source invocation are shared. Only the produced result differs:
-- recursive uses may constrain their assumption without claiming ownership of
-- the envelope that will be published after all producers have been inferred.
freshBodyValues : Int -> (Unit -> Mono) -> EffRow -> (Mono, Mono)
freshBodyValues arity freshType body =
  if arity <= 0 then
    (freshType (), freshType ())
  else
    let domain = freshType ()
    let row = if arity == 1 then body else pureRow
    let (published, recursive) = freshBodyValues (arity - 1) freshType body
    (TFun domain row published, TFun domain row recursive)

-- Only source applications belong to the binding; a function-valued result
-- starts a new invocation protocol. An arity mismatch is diagnosed by typing.
export
bodyRowAt : Int -> Mono -> EffRow
bodyRowAt arity value = match normalize value
  TFun _ row result => if arity == 1 then row else bodyRowAt (arity - 1) result
  _ => pureRow
# DESUGAR
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "normalize" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true))))
(DTypeSig false "pureRow" (TyCon "EffRow"))
(DFunDef false "pureRow" () (EApp (EApp (EVar "EffRow") (EListLit)) (EVar "None")))
(DData Public "BindingSummary" () ((variant "BindingSummary" (ConNamed (field "bsArity" (TyCon "Int")) (field "bsValue" (TyCon "Mono")) (field "bsRecursiveValue" (TyCon "Mono")) (field "bsBody" (TyCon "EffRow")) (field "bsForce" (TyCon "EffRow"))))) ())
(DTypeSig true "bodyArrows" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "EffRow") (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "bodyArrows" ((PList) PWild (PVar "result")) (EVar "result"))
(DFunDef false "bodyArrows" ((PList (PVar "param")) (PVar "body") (PVar "result")) (EApp (EApp (EApp (EVar "TFun") (EVar "param")) (EVar "body")) (EVar "result")))
(DFunDef false "bodyArrows" ((PCons (PVar "param") (PVar "rest")) (PVar "body") (PVar "result")) (EApp (EApp (EApp (EVar "TFun") (EVar "param")) (EVar "pureRow")) (EApp (EApp (EApp (EVar "bodyArrows") (EVar "rest")) (EVar "body")) (EVar "result"))))
(DTypeSig true "newBindingSummary" (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "Unit") (TyCon "Mono")) (TyFun (TyFun (TyCon "Unit") (TyCon "EffRow")) (TyCon "BindingSummary")))))
(DFunDef false "newBindingSummary" ((PVar "arity") (PVar "freshType") (PVar "freshSummary")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "freshSummary") (ELit LUnit))) (DoLet false false (PTuple (PVar "published") (PVar "recursive")) (EApp (EApp (EApp (EVar "freshBodyValues") (EVar "arity")) (EVar "freshType")) (EVar "body"))) (DoExpr (ERecordCreate "BindingSummary" ((fa "bsArity" (EVar "arity")) (fa "bsValue" (EVar "published")) (fa "bsRecursiveValue" (EVar "recursive")) (fa "bsBody" (EVar "body")) (fa "bsForce" (EIf (EBinOp "==" (EVar "arity") (ELit (LInt 0))) (EVar "body") (EVar "pureRow"))))))))
(DTypeSig false "freshBodyValues" (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "Unit") (TyCon "Mono")) (TyFun (TyCon "EffRow") (TyTuple (TyCon "Mono") (TyCon "Mono"))))))
(DFunDef false "freshBodyValues" ((PVar "arity") (PVar "freshType") (PVar "body")) (EIf (EBinOp "<=" (EVar "arity") (ELit (LInt 0))) (ETuple (EApp (EVar "freshType") (ELit LUnit)) (EApp (EVar "freshType") (ELit LUnit))) (EBlock (DoLet false false (PVar "domain") (EApp (EVar "freshType") (ELit LUnit))) (DoLet false false (PVar "row") (EIf (EBinOp "==" (EVar "arity") (ELit (LInt 1))) (EVar "body") (EVar "pureRow"))) (DoLet false false (PTuple (PVar "published") (PVar "recursive")) (EApp (EApp (EApp (EVar "freshBodyValues") (EBinOp "-" (EVar "arity") (ELit (LInt 1)))) (EVar "freshType")) (EVar "body"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "TFun") (EVar "domain")) (EVar "row")) (EVar "published")) (EApp (EApp (EApp (EVar "TFun") (EVar "domain")) (EVar "row")) (EVar "recursive")))))))
(DTypeSig true "bodyRowAt" (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "EffRow"))))
(DFunDef false "bodyRowAt" ((PVar "arity") (PVar "value")) (EMatch (EApp (EVar "normalize") (EVar "value")) (arm (PCon "TFun" PWild (PVar "row") (PVar "result")) () (EIf (EBinOp "==" (EVar "arity") (ELit (LInt 1))) (EVar "row") (EApp (EApp (EVar "bodyRowAt") (EBinOp "-" (EVar "arity") (ELit (LInt 1)))) (EVar "result")))) (arm PWild () (EVar "pureRow"))))
# MARK
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "normalize" false))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true))))
(DTypeSig false "pureRow" (TyCon "EffRow"))
(DFunDef false "pureRow" () (EApp (EApp (EVar "EffRow") (EListLit)) (EVar "None")))
(DData Public "BindingSummary" () ((variant "BindingSummary" (ConNamed (field "bsArity" (TyCon "Int")) (field "bsValue" (TyCon "Mono")) (field "bsRecursiveValue" (TyCon "Mono")) (field "bsBody" (TyCon "EffRow")) (field "bsForce" (TyCon "EffRow"))))) ())
(DTypeSig true "bodyArrows" (TyFun (TyApp (TyCon "List") (TyCon "Mono")) (TyFun (TyCon "EffRow") (TyFun (TyCon "Mono") (TyCon "Mono")))))
(DFunDef false "bodyArrows" ((PList) PWild (PVar "result")) (EVar "result"))
(DFunDef false "bodyArrows" ((PList (PVar "param")) (PVar "body") (PVar "result")) (EApp (EApp (EApp (EVar "TFun") (EVar "param")) (EVar "body")) (EVar "result")))
(DFunDef false "bodyArrows" ((PCons (PVar "param") (PVar "rest")) (PVar "body") (PVar "result")) (EApp (EApp (EApp (EVar "TFun") (EVar "param")) (EVar "pureRow")) (EApp (EApp (EApp (EVar "bodyArrows") (EVar "rest")) (EVar "body")) (EVar "result"))))
(DTypeSig true "newBindingSummary" (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "Unit") (TyCon "Mono")) (TyFun (TyFun (TyCon "Unit") (TyCon "EffRow")) (TyCon "BindingSummary")))))
(DFunDef false "newBindingSummary" ((PVar "arity") (PVar "freshType") (PVar "freshSummary")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "freshSummary") (ELit LUnit))) (DoLet false false (PTuple (PVar "published") (PVar "recursive")) (EApp (EApp (EApp (EVar "freshBodyValues") (EVar "arity")) (EVar "freshType")) (EVar "body"))) (DoExpr (ERecordCreate "BindingSummary" ((fa "bsArity" (EVar "arity")) (fa "bsValue" (EVar "published")) (fa "bsRecursiveValue" (EVar "recursive")) (fa "bsBody" (EVar "body")) (fa "bsForce" (EIf (EBinOp "==" (EVar "arity") (ELit (LInt 0))) (EVar "body") (EVar "pureRow"))))))))
(DTypeSig false "freshBodyValues" (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "Unit") (TyCon "Mono")) (TyFun (TyCon "EffRow") (TyTuple (TyCon "Mono") (TyCon "Mono"))))))
(DFunDef false "freshBodyValues" ((PVar "arity") (PVar "freshType") (PVar "body")) (EIf (EBinOp "<=" (EVar "arity") (ELit (LInt 0))) (ETuple (EApp (EVar "freshType") (ELit LUnit)) (EApp (EVar "freshType") (ELit LUnit))) (EBlock (DoLet false false (PVar "domain") (EApp (EVar "freshType") (ELit LUnit))) (DoLet false false (PVar "row") (EIf (EBinOp "==" (EVar "arity") (ELit (LInt 1))) (EVar "body") (EVar "pureRow"))) (DoLet false false (PTuple (PVar "published") (PVar "recursive")) (EApp (EApp (EApp (EVar "freshBodyValues") (EBinOp "-" (EVar "arity") (ELit (LInt 1)))) (EVar "freshType")) (EVar "body"))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "TFun") (EVar "domain")) (EVar "row")) (EVar "published")) (EApp (EApp (EApp (EVar "TFun") (EVar "domain")) (EVar "row")) (EVar "recursive")))))))
(DTypeSig true "bodyRowAt" (TyFun (TyCon "Int") (TyFun (TyCon "Mono") (TyCon "EffRow"))))
(DFunDef false "bodyRowAt" ((PVar "arity") (PVar "value")) (EMatch (EApp (EVar "normalize") (EVar "value")) (arm (PCon "TFun" PWild (PVar "row") (PVar "result")) () (EIf (EBinOp "==" (EVar "arity") (ELit (LInt 1))) (EVar "row") (EApp (EApp (EVar "bodyRowAt") (EBinOp "-" (EVar "arity") (ELit (LInt 1)))) (EVar "result")))) (arm PWild () (EVar "pureRow"))))
