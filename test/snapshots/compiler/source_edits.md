# META
source_lines=57
stages=DESUGAR,MARK
# SOURCE
import list.{sortBy}
import tools.source_snapshot.{SourceSnapshot(..), SnapshotId, matchesSnapshot}
import frontend.syntax_source.{SourceSpan(..)}

public export data SourceEdit = SourceEdit SnapshotId SourceSpan String String
public export data EditError =
  | StaleSnapshot
  | InvalidRange
  | OverlappingEdits
  | ExpectedTextMismatch

compareEdit : SourceEdit -> SourceEdit -> Ordering
compareEdit (SourceEdit _ (SourceSpan a b) _ _) (SourceEdit _ (SourceSpan c d) _ _) =
  if a == c then compare b d else compare a c

validateEach : SourceSnapshot ->
  String ->
  List SourceEdit ->
  Result EditError Unit
validateEach _ _ [] = Ok ()
validateEach snapshot text ((SourceEdit id (SourceSpan lo hi) expected _) :: rest) =
  if not (matchesSnapshot id snapshot) then
    Err StaleSnapshot
  else if lo < 0 || hi < lo || hi > stringLength text then
    Err InvalidRange
  else if stringSlice lo hi text /= expected then
    Err ExpectedTextMismatch
  else
    validateEach snapshot text rest

validateOverlap : List SourceEdit -> Result EditError Unit
validateOverlap [] = Ok ()
validateOverlap [_] = Ok ()
validateOverlap ((SourceEdit _ (SourceSpan a b) _ _) :: (next@(SourceEdit _ (SourceSpan c d) _ _)) :: rest) =
  if c < b || a == b && c == d && a == c then
    Err OverlappingEdits
  else
    validateOverlap (next :: rest)

export
validateSourceEdits : SourceSnapshot -> List SourceEdit -> Result EditError Unit
validateSourceEdits (snapshot@(SourceSnapshot _ _ _ text _)) edits =
  match validateEach snapshot text edits
    Err e => Err e
    Ok _ => validateOverlap (sortBy compareEdit edits)

editParts : String -> Int -> List SourceEdit -> List String
editParts text pos [] = [stringSlice pos (stringLength text) text]
editParts text pos ((SourceEdit _ (SourceSpan lo hi) _ replacement) :: rest) =
  stringSlice pos lo text :: replacement :: editParts text hi rest

export
applySourceEdits : SourceSnapshot -> List SourceEdit -> Result EditError String
applySourceEdits (snapshot@(SourceSnapshot _ _ _ text _)) edits =
  map
    (_ => stringConcat (editParts text 0 (sortBy compareEdit edits)))
    (validateSourceEdits snapshot edits)
# DESUGAR
(DUse false (UseGroup ("list") ((mem "sortBy" false))))
(DUse false (UseGroup ("tools" "source_snapshot") ((mem "SourceSnapshot" true) (mem "SnapshotId" false) (mem "matchesSnapshot" false))))
(DUse false (UseGroup ("frontend" "syntax_source") ((mem "SourceSpan" true))))
(DData Public "SourceEdit" () ((variant "SourceEdit" (ConPos (TyCon "SnapshotId") (TyCon "SourceSpan") (TyCon "String") (TyCon "String")))) ())
(DData Public "EditError" () ((variant "StaleSnapshot" (ConPos)) (variant "InvalidRange" (ConPos)) (variant "OverlappingEdits" (ConPos)) (variant "ExpectedTextMismatch" (ConPos))) ())
(DTypeSig false "compareEdit" (TyFun (TyCon "SourceEdit") (TyFun (TyCon "SourceEdit") (TyCon "Ordering"))))
(DFunDef false "compareEdit" ((PCon "SourceEdit" PWild (PCon "SourceSpan" (PVar "a") (PVar "b")) PWild PWild) (PCon "SourceEdit" PWild (PCon "SourceSpan" (PVar "c") (PVar "d")) PWild PWild)) (EIf (EBinOp "==" (EVar "a") (EVar "c")) (EApp (EApp (EVar "compare") (EVar "b")) (EVar "d")) (EApp (EApp (EVar "compare") (EVar "a")) (EVar "c"))))
(DTypeSig false "validateEach" (TyFun (TyCon "SourceSnapshot") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "SourceEdit")) (TyApp (TyApp (TyCon "Result") (TyCon "EditError")) (TyCon "Unit"))))))
(DFunDef false "validateEach" (PWild PWild (PList)) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateEach" ((PVar "snapshot") (PVar "text") (PCons (PCon "SourceEdit" (PVar "id") (PCon "SourceSpan" (PVar "lo") (PVar "hi")) (PVar "expected") PWild) (PVar "rest"))) (EIf (EApp (EVar "not") (EApp (EApp (EVar "matchesSnapshot") (EVar "id")) (EVar "snapshot"))) (EApp (EVar "Err") (EVar "StaleSnapshot")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (EBinOp "<" (EVar "hi") (EVar "lo"))) (EBinOp ">" (EVar "hi") (EApp (EVar "stringLength") (EVar "text")))) (EApp (EVar "Err") (EVar "InvalidRange")) (EIf (EBinOp "/=" (EApp (EApp (EApp (EVar "stringSlice") (EVar "lo")) (EVar "hi")) (EVar "text")) (EVar "expected")) (EApp (EVar "Err") (EVar "ExpectedTextMismatch")) (EApp (EApp (EApp (EVar "validateEach") (EVar "snapshot")) (EVar "text")) (EVar "rest"))))))
(DTypeSig false "validateOverlap" (TyFun (TyApp (TyCon "List") (TyCon "SourceEdit")) (TyApp (TyApp (TyCon "Result") (TyCon "EditError")) (TyCon "Unit"))))
(DFunDef false "validateOverlap" ((PList)) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateOverlap" ((PList PWild)) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateOverlap" ((PCons (PCon "SourceEdit" PWild (PCon "SourceSpan" (PVar "a") (PVar "b")) PWild PWild) (PCons (PAs "next" (PCon "SourceEdit" PWild (PCon "SourceSpan" (PVar "c") (PVar "d")) PWild PWild)) (PVar "rest")))) (EIf (EBinOp "||" (EBinOp "<" (EVar "c") (EVar "b")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "a") (EVar "b")) (EBinOp "==" (EVar "c") (EVar "d"))) (EBinOp "==" (EVar "a") (EVar "c")))) (EApp (EVar "Err") (EVar "OverlappingEdits")) (EApp (EVar "validateOverlap") (EBinOp "::" (EVar "next") (EVar "rest")))))
(DTypeSig true "validateSourceEdits" (TyFun (TyCon "SourceSnapshot") (TyFun (TyApp (TyCon "List") (TyCon "SourceEdit")) (TyApp (TyApp (TyCon "Result") (TyCon "EditError")) (TyCon "Unit")))))
(DFunDef false "validateSourceEdits" ((PAs "snapshot" (PCon "SourceSnapshot" PWild PWild PWild (PVar "text") PWild)) (PVar "edits")) (EMatch (EApp (EApp (EApp (EVar "validateEach") (EVar "snapshot")) (EVar "text")) (EVar "edits")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" PWild) () (EApp (EVar "validateOverlap") (EApp (EApp (EVar "sortBy") (EVar "compareEdit")) (EVar "edits"))))))
(DTypeSig false "editParts" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "SourceEdit")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "editParts" ((PVar "text") (PVar "pos") (PList)) (EListLit (EApp (EApp (EApp (EVar "stringSlice") (EVar "pos")) (EApp (EVar "stringLength") (EVar "text"))) (EVar "text"))))
(DFunDef false "editParts" ((PVar "text") (PVar "pos") (PCons (PCon "SourceEdit" PWild (PCon "SourceSpan" (PVar "lo") (PVar "hi")) PWild (PVar "replacement")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (EVar "pos")) (EVar "lo")) (EVar "text")) (EBinOp "::" (EVar "replacement") (EApp (EApp (EApp (EVar "editParts") (EVar "text")) (EVar "hi")) (EVar "rest")))))
(DTypeSig true "applySourceEdits" (TyFun (TyCon "SourceSnapshot") (TyFun (TyApp (TyCon "List") (TyCon "SourceEdit")) (TyApp (TyApp (TyCon "Result") (TyCon "EditError")) (TyCon "String")))))
(DFunDef false "applySourceEdits" ((PAs "snapshot" (PCon "SourceSnapshot" PWild PWild PWild (PVar "text") PWild)) (PVar "edits")) (EApp (EApp (EVar "map") (ELam (PWild) (EApp (EVar "stringConcat") (EApp (EApp (EApp (EVar "editParts") (EVar "text")) (ELit (LInt 0))) (EApp (EApp (EVar "sortBy") (EVar "compareEdit")) (EVar "edits")))))) (EApp (EApp (EVar "validateSourceEdits") (EVar "snapshot")) (EVar "edits"))))
# MARK
(DUse false (UseGroup ("list") ((mem "sortBy" false))))
(DUse false (UseGroup ("tools" "source_snapshot") ((mem "SourceSnapshot" true) (mem "SnapshotId" false) (mem "matchesSnapshot" false))))
(DUse false (UseGroup ("frontend" "syntax_source") ((mem "SourceSpan" true))))
(DData Public "SourceEdit" () ((variant "SourceEdit" (ConPos (TyCon "SnapshotId") (TyCon "SourceSpan") (TyCon "String") (TyCon "String")))) ())
(DData Public "EditError" () ((variant "StaleSnapshot" (ConPos)) (variant "InvalidRange" (ConPos)) (variant "OverlappingEdits" (ConPos)) (variant "ExpectedTextMismatch" (ConPos))) ())
(DTypeSig false "compareEdit" (TyFun (TyCon "SourceEdit") (TyFun (TyCon "SourceEdit") (TyCon "Ordering"))))
(DFunDef false "compareEdit" ((PCon "SourceEdit" PWild (PCon "SourceSpan" (PVar "a") (PVar "b")) PWild PWild) (PCon "SourceEdit" PWild (PCon "SourceSpan" (PVar "c") (PVar "d")) PWild PWild)) (EIf (EBinOp "==" (EVar "a") (EVar "c")) (EApp (EApp (EMethodRef "compare") (EVar "b")) (EVar "d")) (EApp (EApp (EMethodRef "compare") (EVar "a")) (EVar "c"))))
(DTypeSig false "validateEach" (TyFun (TyCon "SourceSnapshot") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "SourceEdit")) (TyApp (TyApp (TyCon "Result") (TyCon "EditError")) (TyCon "Unit"))))))
(DFunDef false "validateEach" (PWild PWild (PList)) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateEach" ((PVar "snapshot") (PVar "text") (PCons (PCon "SourceEdit" (PVar "id") (PCon "SourceSpan" (PVar "lo") (PVar "hi")) (PVar "expected") PWild) (PVar "rest"))) (EIf (EApp (EVar "not") (EApp (EApp (EVar "matchesSnapshot") (EVar "id")) (EVar "snapshot"))) (EApp (EVar "Err") (EVar "StaleSnapshot")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (EBinOp "<" (EVar "hi") (EVar "lo"))) (EBinOp ">" (EVar "hi") (EApp (EVar "stringLength") (EVar "text")))) (EApp (EVar "Err") (EVar "InvalidRange")) (EIf (EBinOp "/=" (EApp (EApp (EApp (EVar "stringSlice") (EVar "lo")) (EVar "hi")) (EVar "text")) (EVar "expected")) (EApp (EVar "Err") (EVar "ExpectedTextMismatch")) (EApp (EApp (EApp (EVar "validateEach") (EVar "snapshot")) (EVar "text")) (EVar "rest"))))))
(DTypeSig false "validateOverlap" (TyFun (TyApp (TyCon "List") (TyCon "SourceEdit")) (TyApp (TyApp (TyCon "Result") (TyCon "EditError")) (TyCon "Unit"))))
(DFunDef false "validateOverlap" ((PList)) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateOverlap" ((PList PWild)) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "validateOverlap" ((PCons (PCon "SourceEdit" PWild (PCon "SourceSpan" (PVar "a") (PVar "b")) PWild PWild) (PCons (PAs "next" (PCon "SourceEdit" PWild (PCon "SourceSpan" (PVar "c") (PVar "d")) PWild PWild)) (PVar "rest")))) (EIf (EBinOp "||" (EBinOp "<" (EVar "c") (EVar "b")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "a") (EVar "b")) (EBinOp "==" (EVar "c") (EVar "d"))) (EBinOp "==" (EVar "a") (EVar "c")))) (EApp (EVar "Err") (EVar "OverlappingEdits")) (EApp (EVar "validateOverlap") (EBinOp "::" (EVar "next") (EVar "rest")))))
(DTypeSig true "validateSourceEdits" (TyFun (TyCon "SourceSnapshot") (TyFun (TyApp (TyCon "List") (TyCon "SourceEdit")) (TyApp (TyApp (TyCon "Result") (TyCon "EditError")) (TyCon "Unit")))))
(DFunDef false "validateSourceEdits" ((PAs "snapshot" (PCon "SourceSnapshot" PWild PWild PWild (PVar "text") PWild)) (PVar "edits")) (EMatch (EApp (EApp (EApp (EVar "validateEach") (EVar "snapshot")) (EVar "text")) (EVar "edits")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "Ok" PWild) () (EApp (EVar "validateOverlap") (EApp (EApp (EVar "sortBy") (EVar "compareEdit")) (EVar "edits"))))))
(DTypeSig false "editParts" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "SourceEdit")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "editParts" ((PVar "text") (PVar "pos") (PList)) (EListLit (EApp (EApp (EApp (EVar "stringSlice") (EVar "pos")) (EApp (EVar "stringLength") (EVar "text"))) (EVar "text"))))
(DFunDef false "editParts" ((PVar "text") (PVar "pos") (PCons (PCon "SourceEdit" PWild (PCon "SourceSpan" (PVar "lo") (PVar "hi")) PWild (PVar "replacement")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "stringSlice") (EVar "pos")) (EVar "lo")) (EVar "text")) (EBinOp "::" (EVar "replacement") (EApp (EApp (EApp (EVar "editParts") (EVar "text")) (EVar "hi")) (EVar "rest")))))
(DTypeSig true "applySourceEdits" (TyFun (TyCon "SourceSnapshot") (TyFun (TyApp (TyCon "List") (TyCon "SourceEdit")) (TyApp (TyApp (TyCon "Result") (TyCon "EditError")) (TyCon "String")))))
(DFunDef false "applySourceEdits" ((PAs "snapshot" (PCon "SourceSnapshot" PWild PWild PWild (PVar "text") PWild)) (PVar "edits")) (EApp (EApp (EMethodRef "map") (ELam (PWild) (EApp (EVar "stringConcat") (EApp (EApp (EApp (EVar "editParts") (EVar "text")) (ELit (LInt 0))) (EApp (EApp (EVar "sortBy") (EVar "compareEdit")) (EVar "edits")))))) (EApp (EApp (EVar "validateSourceEdits") (EVar "snapshot")) (EVar "edits"))))
