# META
source_lines=89
stages=DESUGAR,MARK
# SOURCE
import json.{Json(..), jObject, stringify}

public export data TraceSettings = TraceSettings {
  tracePath : String,
  traceSession : String,
  traceClassification : String,
}
public export data TraceContext = TraceContext {
  traceSettings : Option TraceSettings,
  traceCounter : Ref Int,
}
public export data TraceToken =
  | TraceDisabled
  | TraceToken TraceContext String String Float

data TraceEvent = TraceEvent {
  requestId : String,
  tool : String,
  event : String,
  outcome : Json,
  duration : Json,
  size : Json,
}

export
beginCall : TraceContext -> String -> String -> <IO, Clock> TraceToken
beginCall context requestId tool = match context.traceSettings
  None => TraceDisabled
  Some _ => beginEnabledCall context requestId tool

beginEnabledCall : TraceContext -> String -> String -> <IO, Clock> TraceToken
beginEnabledCall context requestId tool =
  let started = monotonicSec ()
  emit context TraceEvent {
    requestId = requestId,
    tool = tool,
    event = "start",
    outcome = JNull,
    duration = JNull,
    size = JNull,
  }
  TraceToken context requestId tool started

export
finishCall : TraceToken -> String -> Int -> <IO, Clock> Unit
finishCall TraceDisabled _ _ = ()
finishCall (TraceToken context requestId tool started) outcome responseBytes =
  let elapsed = floatToInt ((monotonicSec () - started) * 1000000000.0)
  emit context TraceEvent {
    requestId = requestId,
    tool = tool,
    event = "finish",
    outcome = JString outcome,
    duration = JInt (max 0 elapsed),
    size = JInt responseBytes,
  }

export
recordProtocol : TraceContext -> String -> String -> <IO> Unit
recordProtocol context event requestId = emit context TraceEvent {
  requestId = requestId,
  tool = "protocol",
  event = event,
  outcome = JNull,
  duration = JNull,
  size = JNull,
}

emit : TraceContext -> TraceEvent -> <IO> Unit
emit context entry = match context.traceSettings
  None => ()
  Some settings =>
    let line =
      stringify
          (jObject [
            ("schema_version", JInt 1),
            ("session_id", JString settings.traceSession),
            ("request_id", JString entry.requestId),
            ("tool", JString entry.tool),
            ("classification", JString settings.traceClassification),
            ("event", JString entry.event),
            ("outcome", entry.outcome),
            ("duration_ns", entry.duration),
            ("response_bytes", entry.size),
          ])
        ++ "\n"
    bestEffort
      "telemetry is advisory and must not interrupt the protocol"
      (appendFileExceptStdout settings.tracePath line)
# DESUGAR
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false) (mem "stringify" false))))
(DData Public "TraceSettings" () ((variant "TraceSettings" (ConNamed (field "tracePath" (TyCon "String")) (field "traceSession" (TyCon "String")) (field "traceClassification" (TyCon "String"))))) ())
(DData Public "TraceContext" () ((variant "TraceContext" (ConNamed (field "traceSettings" (TyApp (TyCon "Option") (TyCon "TraceSettings"))) (field "traceCounter" (TyApp (TyCon "Ref") (TyCon "Int")))))) ())
(DData Public "TraceToken" () ((variant "TraceDisabled" (ConPos)) (variant "TraceToken" (ConPos (TyCon "TraceContext") (TyCon "String") (TyCon "String") (TyCon "Float")))) ())
(DData Private "TraceEvent" () ((variant "TraceEvent" (ConNamed (field "requestId" (TyCon "String")) (field "tool" (TyCon "String")) (field "event" (TyCon "String")) (field "outcome" (TyCon "Json")) (field "duration" (TyCon "Json")) (field "size" (TyCon "Json"))))) ())
(DTypeSig true "beginCall" (TyFun (TyCon "TraceContext") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO" "Clock") None (TyCon "TraceToken"))))))
(DFunDef false "beginCall" ((PVar "context") (PVar "requestId") (PVar "tool")) (EMatch (EFieldAccess (EVar "context") "traceSettings") (arm (PCon "None") () (EVar "TraceDisabled")) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EVar "beginEnabledCall") (EVar "context")) (EVar "requestId")) (EVar "tool")))))
(DTypeSig false "beginEnabledCall" (TyFun (TyCon "TraceContext") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO" "Clock") None (TyCon "TraceToken"))))))
(DFunDef false "beginEnabledCall" ((PVar "context") (PVar "requestId") (PVar "tool")) (EBlock (DoLet false false (PVar "started") (EApp (EVar "monotonicSec") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "emit") (EVar "context")) (ERecordCreate "TraceEvent" ((fa "requestId" (EVar "requestId")) (fa "tool" (EVar "tool")) (fa "event" (ELit (LString "start"))) (fa "outcome" (EVar "JNull")) (fa "duration" (EVar "JNull")) (fa "size" (EVar "JNull")))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "TraceToken") (EVar "context")) (EVar "requestId")) (EVar "tool")) (EVar "started")))))
(DTypeSig true "finishCall" (TyFun (TyCon "TraceToken") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyEffect ("IO" "Clock") None (TyCon "Unit"))))))
(DFunDef false "finishCall" ((PCon "TraceDisabled") PWild PWild) (ELit LUnit))
(DFunDef false "finishCall" ((PCon "TraceToken" (PVar "context") (PVar "requestId") (PVar "tool") (PVar "started")) (PVar "outcome") (PVar "responseBytes")) (EBlock (DoLet false false (PVar "elapsed") (EApp (EVar "floatToInt") (EBinOp "*" (EBinOp "-" (EApp (EVar "monotonicSec") (ELit LUnit)) (EVar "started")) (ELit (LFloat 1000000000.0))))) (DoExpr (EApp (EApp (EVar "emit") (EVar "context")) (ERecordCreate "TraceEvent" ((fa "requestId" (EVar "requestId")) (fa "tool" (EVar "tool")) (fa "event" (ELit (LString "finish"))) (fa "outcome" (EApp (EVar "JString") (EVar "outcome"))) (fa "duration" (EApp (EVar "JInt") (EApp (EApp (EVar "max") (ELit (LInt 0))) (EVar "elapsed")))) (fa "size" (EApp (EVar "JInt") (EVar "responseBytes")))))))))
(DTypeSig true "recordProtocol" (TyFun (TyCon "TraceContext") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "recordProtocol" ((PVar "context") (PVar "event") (PVar "requestId")) (EApp (EApp (EVar "emit") (EVar "context")) (ERecordCreate "TraceEvent" ((fa "requestId" (EVar "requestId")) (fa "tool" (ELit (LString "protocol"))) (fa "event" (EVar "event")) (fa "outcome" (EVar "JNull")) (fa "duration" (EVar "JNull")) (fa "size" (EVar "JNull"))))))
(DTypeSig false "emit" (TyFun (TyCon "TraceContext") (TyFun (TyCon "TraceEvent") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "emit" ((PVar "context") (PVar "entry")) (EMatch (EFieldAccess (EVar "context") "traceSettings") (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "settings")) () (EBlock (DoLet false false (PVar "line") (EBinOp "++" (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "schema_version")) (EApp (EVar "JInt") (ELit (LInt 1)))) (ETuple (ELit (LString "session_id")) (EApp (EVar "JString") (EFieldAccess (EVar "settings") "traceSession"))) (ETuple (ELit (LString "request_id")) (EApp (EVar "JString") (EFieldAccess (EVar "entry") "requestId"))) (ETuple (ELit (LString "tool")) (EApp (EVar "JString") (EFieldAccess (EVar "entry") "tool"))) (ETuple (ELit (LString "classification")) (EApp (EVar "JString") (EFieldAccess (EVar "settings") "traceClassification"))) (ETuple (ELit (LString "event")) (EApp (EVar "JString") (EFieldAccess (EVar "entry") "event"))) (ETuple (ELit (LString "outcome")) (EFieldAccess (EVar "entry") "outcome")) (ETuple (ELit (LString "duration_ns")) (EFieldAccess (EVar "entry") "duration")) (ETuple (ELit (LString "response_bytes")) (EFieldAccess (EVar "entry") "size"))))) (ELit (LString "\n")))) (DoExpr (EApp (EApp (EVar "bestEffort") (ELit (LString "telemetry is advisory and must not interrupt the protocol"))) (EApp (EApp (EVar "appendFileExceptStdout") (EFieldAccess (EVar "settings") "tracePath")) (EVar "line"))))))))
# MARK
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false) (mem "stringify" false))))
(DData Public "TraceSettings" () ((variant "TraceSettings" (ConNamed (field "tracePath" (TyCon "String")) (field "traceSession" (TyCon "String")) (field "traceClassification" (TyCon "String"))))) ())
(DData Public "TraceContext" () ((variant "TraceContext" (ConNamed (field "traceSettings" (TyApp (TyCon "Option") (TyCon "TraceSettings"))) (field "traceCounter" (TyApp (TyCon "Ref") (TyCon "Int")))))) ())
(DData Public "TraceToken" () ((variant "TraceDisabled" (ConPos)) (variant "TraceToken" (ConPos (TyCon "TraceContext") (TyCon "String") (TyCon "String") (TyCon "Float")))) ())
(DData Private "TraceEvent" () ((variant "TraceEvent" (ConNamed (field "requestId" (TyCon "String")) (field "tool" (TyCon "String")) (field "event" (TyCon "String")) (field "outcome" (TyCon "Json")) (field "duration" (TyCon "Json")) (field "size" (TyCon "Json"))))) ())
(DTypeSig true "beginCall" (TyFun (TyCon "TraceContext") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO" "Clock") None (TyCon "TraceToken"))))))
(DFunDef false "beginCall" ((PVar "context") (PVar "requestId") (PVar "tool")) (EMatch (EFieldAccess (EVar "context") "traceSettings") (arm (PCon "None") () (EVar "TraceDisabled")) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EVar "beginEnabledCall") (EVar "context")) (EVar "requestId")) (EVar "tool")))))
(DTypeSig false "beginEnabledCall" (TyFun (TyCon "TraceContext") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO" "Clock") None (TyCon "TraceToken"))))))
(DFunDef false "beginEnabledCall" ((PVar "context") (PVar "requestId") (PVar "tool")) (EBlock (DoLet false false (PVar "started") (EApp (EVar "monotonicSec") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "emit") (EVar "context")) (ERecordCreate "TraceEvent" ((fa "requestId" (EVar "requestId")) (fa "tool" (EVar "tool")) (fa "event" (ELit (LString "start"))) (fa "outcome" (EVar "JNull")) (fa "duration" (EVar "JNull")) (fa "size" (EVar "JNull")))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "TraceToken") (EVar "context")) (EVar "requestId")) (EVar "tool")) (EVar "started")))))
(DTypeSig true "finishCall" (TyFun (TyCon "TraceToken") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyEffect ("IO" "Clock") None (TyCon "Unit"))))))
(DFunDef false "finishCall" ((PCon "TraceDisabled") PWild PWild) (ELit LUnit))
(DFunDef false "finishCall" ((PCon "TraceToken" (PVar "context") (PVar "requestId") (PVar "tool") (PVar "started")) (PVar "outcome") (PVar "responseBytes")) (EBlock (DoLet false false (PVar "elapsed") (EApp (EVar "floatToInt") (EBinOp "*" (EBinOp "-" (EApp (EVar "monotonicSec") (ELit LUnit)) (EVar "started")) (ELit (LFloat 1000000000.0))))) (DoExpr (EApp (EApp (EVar "emit") (EVar "context")) (ERecordCreate "TraceEvent" ((fa "requestId" (EVar "requestId")) (fa "tool" (EVar "tool")) (fa "event" (ELit (LString "finish"))) (fa "outcome" (EApp (EVar "JString") (EVar "outcome"))) (fa "duration" (EApp (EVar "JInt") (EApp (EApp (EMethodRef "max") (ELit (LInt 0))) (EVar "elapsed")))) (fa "size" (EApp (EVar "JInt") (EVar "responseBytes")))))))))
(DTypeSig true "recordProtocol" (TyFun (TyCon "TraceContext") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "recordProtocol" ((PVar "context") (PVar "event") (PVar "requestId")) (EApp (EApp (EVar "emit") (EVar "context")) (ERecordCreate "TraceEvent" ((fa "requestId" (EVar "requestId")) (fa "tool" (ELit (LString "protocol"))) (fa "event" (EVar "event")) (fa "outcome" (EVar "JNull")) (fa "duration" (EVar "JNull")) (fa "size" (EVar "JNull"))))))
(DTypeSig false "emit" (TyFun (TyCon "TraceContext") (TyFun (TyCon "TraceEvent") (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "emit" ((PVar "context") (PVar "entry")) (EMatch (EFieldAccess (EVar "context") "traceSettings") (arm (PCon "None") () (ELit LUnit)) (arm (PCon "Some" (PVar "settings")) () (EBlock (DoLet false false (PVar "line") (EBinOp "++" (EApp (EVar "stringify") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "schema_version")) (EApp (EVar "JInt") (ELit (LInt 1)))) (ETuple (ELit (LString "session_id")) (EApp (EVar "JString") (EFieldAccess (EVar "settings") "traceSession"))) (ETuple (ELit (LString "request_id")) (EApp (EVar "JString") (EFieldAccess (EVar "entry") "requestId"))) (ETuple (ELit (LString "tool")) (EApp (EVar "JString") (EFieldAccess (EVar "entry") "tool"))) (ETuple (ELit (LString "classification")) (EApp (EVar "JString") (EFieldAccess (EVar "settings") "traceClassification"))) (ETuple (ELit (LString "event")) (EApp (EVar "JString") (EFieldAccess (EVar "entry") "event"))) (ETuple (ELit (LString "outcome")) (EFieldAccess (EVar "entry") "outcome")) (ETuple (ELit (LString "duration_ns")) (EFieldAccess (EVar "entry") "duration")) (ETuple (ELit (LString "response_bytes")) (EFieldAccess (EVar "entry") "size"))))) (ELit (LString "\n")))) (DoExpr (EApp (EApp (EVar "bestEffort") (ELit (LString "telemetry is advisory and must not interrupt the protocol"))) (EApp (EApp (EVar "appendFileExceptStdout") (EFieldAccess (EVar "settings") "tracePath")) (EVar "line"))))))))
