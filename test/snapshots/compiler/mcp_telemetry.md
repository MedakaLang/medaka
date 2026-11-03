# META
source_lines=63
stages=DESUGAR,MARK
# SOURCE
import json.{Json(..), jObject, stringify}

public export data TraceContext = TraceContext String String String (Ref Int)
public export data TraceToken =
  | TraceDisabled
  | TraceToken TraceContext String String Float

export
beginCall : TraceContext -> String -> String -> <IO, Clock> TraceToken
beginCall (TraceContext "" _ _ _) _ _ = TraceDisabled
beginCall context requestId tool =
  let started = monotonicSec ()
  emit context requestId tool "start" JNull JNull JNull
  TraceToken context requestId tool started

export
finishCall : TraceToken -> String -> Int -> <IO, Clock> Unit
finishCall TraceDisabled _ _ = ()
finishCall (TraceToken context requestId tool started) outcome responseBytes =
  let elapsed = floatToInt ((monotonicSec () - started) * 1000000000.0)
  emit
    context
    requestId
    tool
    "finish"
    (JString outcome)
    (JInt (max 0 elapsed))
    (JInt responseBytes)

export
recordProtocol : TraceContext -> String -> String -> <IO> Unit
recordProtocol context event requestId =
  emit context requestId "protocol" event JNull JNull JNull

emit : TraceContext ->
  String ->
  String ->
  String ->
  Json ->
  Json ->
  Json ->
  <IO> Unit
emit (TraceContext path session classification _) requestId tool event outcome duration size =
  if path == "" then
    ()
  else
    let line =
      stringify
          (jObject [
            ("schema_version", JInt 1),
            ("session_id", JString session),
            ("request_id", JString requestId),
            ("tool", JString tool),
            ("classification", JString classification),
            ("event", JString event),
            ("outcome", outcome),
            ("duration_ns", duration),
            ("response_bytes", size),
          ])
        ++ "\n"
    match appendFileExceptStdout path line
      Ok _ => ()
      Err _ => ()
# DESUGAR
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false) (mem "stringify" false))))
(DData Public "TraceContext" () ((variant "TraceContext" (ConPos (TyCon "String") (TyCon "String") (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Int"))))) ())
(DData Public "TraceToken" () ((variant "TraceDisabled" (ConPos)) (variant "TraceToken" (ConPos (TyCon "TraceContext") (TyCon "String") (TyCon "String") (TyCon "Float")))) ())
(DTypeSig true "beginCall" (TyFun (TyCon "TraceContext") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO" "Clock") None (TyCon "TraceToken"))))))
(DFunDef false "beginCall" ((PCon "TraceContext" (PLit (LString "")) PWild PWild PWild) PWild PWild) (EVar "TraceDisabled"))
(DFunDef false "beginCall" ((PVar "context") (PVar "requestId") (PVar "tool")) (EBlock (DoLet false false (PVar "started") (EApp (EVar "monotonicSec") (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "context")) (EVar "requestId")) (EVar "tool")) (ELit (LString "start"))) (EVar "JNull")) (EVar "JNull")) (EVar "JNull"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "TraceToken") (EVar "context")) (EVar "requestId")) (EVar "tool")) (EVar "started")))))
(DTypeSig true "finishCall" (TyFun (TyCon "TraceToken") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyEffect ("IO" "Clock") None (TyCon "Unit"))))))
(DFunDef false "finishCall" ((PCon "TraceDisabled") PWild PWild) (ELit LUnit))
(DFunDef false "finishCall" ((PCon "TraceToken" (PVar "context") (PVar "requestId") (PVar "tool") (PVar "started")) (PVar "outcome") (PVar "responseBytes")) (EBlock (DoLet false false (PVar "elapsed") (EApp (EVar "floatToInt") (EBinOp "*" (EBinOp "-" (EApp (EVar "monotonicSec") (ELit LUnit)) (EVar "started")) (ELit (LFloat 1000000000.0))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "context")) (EVar "requestId")) (EVar "tool")) (ELit (LString "finish"))) (EApp (EVar "JString") (EVar "outcome"))) (EApp (EVar "JInt") (EApp (EApp (EVar "max") (ELit (LInt 0))) (EVar "elapsed")))) (EApp (EVar "JInt") (EVar "responseBytes"))))))
(DTypeSig true "recordProtocol" (TyFun (TyCon "TraceContext") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "recordProtocol" ((PVar "context") (PVar "event") (PVar "requestId")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "context")) (EVar "requestId")) (ELit (LString "protocol"))) (EVar "event")) (EVar "JNull")) (EVar "JNull")) (EVar "JNull")))
(DTypeSig false "emit" (TyFun (TyCon "TraceContext") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit"))))))))))
(DFunDef false "emit" ((PCon "TraceContext" (PVar "path") (PVar "session") (PVar "classification") PWild) (PVar "requestId") (PVar "tool") (PVar "event") (PVar "outcome") (PVar "duration") (PVar "size")) (EIf (EBinOp "==" (EVar "path") (ELit (LString ""))) (ELit LUnit) (EBlock (DoLet false false (PVar "line") (EBinOp "++" (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "schema_version")) (EApp (EVar "JInt") (ELit (LInt 1)))) (ETuple (ELit (LString "session_id")) (EApp (EVar "JString") (EVar "session"))) (ETuple (ELit (LString "request_id")) (EApp (EVar "JString") (EVar "requestId"))) (ETuple (ELit (LString "tool")) (EApp (EVar "JString") (EVar "tool"))) (ETuple (ELit (LString "classification")) (EApp (EVar "JString") (EVar "classification"))) (ETuple (ELit (LString "event")) (EApp (EVar "JString") (EVar "event"))) (ETuple (ELit (LString "outcome")) (EVar "outcome")) (ETuple (ELit (LString "duration_ns")) (EVar "duration")) (ETuple (ELit (LString "response_bytes")) (EVar "size"))))) (ELit (LString "\n")))) (DoExpr (EMatch (EApp (EApp (EVar "appendFileExceptStdout") (EVar "path")) (EVar "line")) (arm (PCon "Ok" PWild) () (ELit LUnit)) (arm (PCon "Err" PWild) () (ELit LUnit)))))))
# MARK
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false) (mem "stringify" false))))
(DData Public "TraceContext" () ((variant "TraceContext" (ConPos (TyCon "String") (TyCon "String") (TyCon "String") (TyApp (TyCon "Ref") (TyCon "Int"))))) ())
(DData Public "TraceToken" () ((variant "TraceDisabled" (ConPos)) (variant "TraceToken" (ConPos (TyCon "TraceContext") (TyCon "String") (TyCon "String") (TyCon "Float")))) ())
(DTypeSig true "beginCall" (TyFun (TyCon "TraceContext") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO" "Clock") None (TyCon "TraceToken"))))))
(DFunDef false "beginCall" ((PCon "TraceContext" (PLit (LString "")) PWild PWild PWild) PWild PWild) (EVar "TraceDisabled"))
(DFunDef false "beginCall" ((PVar "context") (PVar "requestId") (PVar "tool")) (EBlock (DoLet false false (PVar "started") (EApp (EVar "monotonicSec") (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "context")) (EVar "requestId")) (EVar "tool")) (ELit (LString "start"))) (EVar "JNull")) (EVar "JNull")) (EVar "JNull"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "TraceToken") (EVar "context")) (EVar "requestId")) (EVar "tool")) (EVar "started")))))
(DTypeSig true "finishCall" (TyFun (TyCon "TraceToken") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyEffect ("IO" "Clock") None (TyCon "Unit"))))))
(DFunDef false "finishCall" ((PCon "TraceDisabled") PWild PWild) (ELit LUnit))
(DFunDef false "finishCall" ((PCon "TraceToken" (PVar "context") (PVar "requestId") (PVar "tool") (PVar "started")) (PVar "outcome") (PVar "responseBytes")) (EBlock (DoLet false false (PVar "elapsed") (EApp (EVar "floatToInt") (EBinOp "*" (EBinOp "-" (EApp (EVar "monotonicSec") (ELit LUnit)) (EVar "started")) (ELit (LFloat 1000000000.0))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "context")) (EVar "requestId")) (EVar "tool")) (ELit (LString "finish"))) (EApp (EVar "JString") (EVar "outcome"))) (EApp (EVar "JInt") (EApp (EApp (EMethodRef "max") (ELit (LInt 0))) (EVar "elapsed")))) (EApp (EVar "JInt") (EVar "responseBytes"))))))
(DTypeSig true "recordProtocol" (TyFun (TyCon "TraceContext") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "recordProtocol" ((PVar "context") (PVar "event") (PVar "requestId")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "emit") (EVar "context")) (EVar "requestId")) (ELit (LString "protocol"))) (EVar "event")) (EVar "JNull")) (EVar "JNull")) (EVar "JNull")))
(DTypeSig false "emit" (TyFun (TyCon "TraceContext") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyFun (TyCon "Json") (TyEffect ("IO") None (TyCon "Unit"))))))))))
(DFunDef false "emit" ((PCon "TraceContext" (PVar "path") (PVar "session") (PVar "classification") PWild) (PVar "requestId") (PVar "tool") (PVar "event") (PVar "outcome") (PVar "duration") (PVar "size")) (EIf (EBinOp "==" (EVar "path") (ELit (LString ""))) (ELit LUnit) (EBlock (DoLet false false (PVar "line") (EBinOp "++" (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "schema_version")) (EApp (EVar "JInt") (ELit (LInt 1)))) (ETuple (ELit (LString "session_id")) (EApp (EVar "JString") (EVar "session"))) (ETuple (ELit (LString "request_id")) (EApp (EVar "JString") (EVar "requestId"))) (ETuple (ELit (LString "tool")) (EApp (EVar "JString") (EVar "tool"))) (ETuple (ELit (LString "classification")) (EApp (EVar "JString") (EVar "classification"))) (ETuple (ELit (LString "event")) (EApp (EVar "JString") (EVar "event"))) (ETuple (ELit (LString "outcome")) (EVar "outcome")) (ETuple (ELit (LString "duration_ns")) (EVar "duration")) (ETuple (ELit (LString "response_bytes")) (EVar "size"))))) (ELit (LString "\n")))) (DoExpr (EMatch (EApp (EApp (EVar "appendFileExceptStdout") (EVar "path")) (EVar "line")) (arm (PCon "Ok" PWild) () (ELit LUnit)) (arm (PCon "Err" PWild) () (ELit LUnit)))))))
