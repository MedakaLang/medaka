# META
source_lines=131
stages=DESUGAR,MARK
# SOURCE
import frontend.ast.{Addr(..), Pat(..), Lit(..), BinderId(..)}
import ir.core_ir.{
  CProgram(..), CBind(..), CClause(..), CExpr(..), CStmt(..), CallSite(..),
  CallMode(..)
}
import types.runtime_types.{RuntimeType(..), BinderRow}
import backend.core_validate.{validateBinderStamps, validateCalls}
import support.util.{anyList, joinNl}

sameBinder : BinderId -> BinderId -> Bool
sameBinder (BinderId a n) (BinderId b k) = a == b && n == k

integerLiteral : CExpr -> Option Int
integerLiteral (CLit (LInt n)) = Some n
integerLiteral _ = None

-- Catalog externs use CallDynamic; their known family still emits a direct C call.
arguments : String -> CExpr -> Option (List CExpr)
arguments name (CApp (CVar actual AGlobal) args (CallSite CallDynamic _)) =
  if actual == name then Some args else None
arguments _ _ = None

sourceVar : String -> CExpr -> Bool
sourceVar name (CVar actual (ALocal 0 0)) = actual == name
sourceVar _ _ = False

makeSize : CExpr -> Option Int
makeSize ex = match arguments "byteBlockMake" ex
  Some [n] => match integerLiteral n
    Some count if count >= 0 && count <= 4096 => Some count
    _ => None
  _ => None

leafStatement : String -> Int -> CExpr -> Bool
leafStatement name capacity ex = match arguments "byteBlockSetUnsafe" ex
  Some [i, value, bb] => match (integerLiteral i, integerLiteral value)
    (Some index, Some byte) =>
      sourceVar name bb
        && index >= 0
        && index < capacity
        && byte >= 0
        && byte <= 255
    _ => False
  _ => match arguments "byteBlockBlit" ex
    Some [src, so, dst, do_, n] => match (
      integerLiteral so,
      integerLiteral do_,
      integerLiteral n,
    )
      (Some start, Some dest, Some count) =>
        sourceVar name src
          && sourceVar name dst
          && start >= 0
          && start <= capacity
          && dest >= 0
          && dest <= capacity
          && count >= 0
          && count <= capacity
          && start + count <= capacity
          && dest + count <= capacity
      _ => False
    _ => False

copySize : String -> Int -> CExpr -> Option Int
copySize name capacity ex = match arguments "byteBlockCopyUnsafe" ex
  Some [n, bb] => match integerLiteral n
    Some count if sourceVar name bb && count >= 0 && count <= capacity =>
      Some count
    _ => None
  _ => None

terminal : String -> Int -> CExpr -> Bool
terminal name capacity ex = match arguments "byteBlockGetUnsafe" ex
  Some [i, copy] => match (integerLiteral i, copySize name capacity copy)
    (Some index, Some count) => index >= 0 && index < count
    _ => False
  _ => match arguments "byteBlockLength" ex
    Some [copy] => match copySize name capacity copy
      Some _ => True
      None => False
    _ => False

finish : String -> Int -> List CStmt -> Bool
finish name capacity [CSExpr result] = terminal name capacity result
finish name capacity ((CSExpr ex) :: rest) =
  leafStatement name capacity ex && finish name capacity rest
finish _ _ _ = False

bodyAccepted : CExpr -> Bool
bodyAccepted (CBlock ((CSLet False (PVar name _ _) allocation) :: rest)) =
  name /= "byteBlockMake"
    && name /= "byteBlockCopyUnsafe"
    && name /= "byteBlockGetUnsafe"
    && name /= "byteBlockLength"
    && name /= "byteBlockSetUnsafe"
    && name /= "byteBlockBlit"
    && (match makeSize allocation
      Some count => finish name count rest
      None => False)
bodyAccepted _ = False

sourceFact : CExpr -> List BinderRow -> Bool
sourceFact (CBlock ((CSLet False (PVar name _ bid) _) :: _)) rows =
  anyList
    (row =>
      sameBinder row.brId bid && row.brName == name && row.brType == RTValue)
    rows
sourceFact _ _ = False

export
validateByteBlockKernel : CProgram -> Result String String
validateByteBlockKernel (cp@(CProgram groups ctors ctorTypes impls contexts facts)) =
  let faults = validateBinderStamps cp ++ validateCalls cp
  if faults /= [] then
    Err (joinNl faults)
  else match (groups, ctors, ctorTypes, impls, contexts)
    ([CBind "main" [CClause [] body] _ bid], [], [], [], []) =>
      if anyList
          (row =>
            sameBinder row.brId bid
              && row.brType == RTInt
              && row.brReturns == Some RTInt)
          facts.factBinders
        && sourceFact body facts.factBinders
        && bodyAccepted body then
        Ok
          "(byteblock-kernel v1 runtime-layout=mdk_gc_byteblock_atomic_v1 output=tagged-int source-consumed-by-copy no-escape no-later-argument-allocation)\n"
      else
        Err "byteblock kernel: unsupported producer/use or main return contract"
    _ =>
      Err "byteblock kernel: extra definitions or unsupported module structure"
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Addr" true) (mem "Pat" true) (mem "Lit" true) (mem "BinderId" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CStmt" true) (mem "CallSite" true) (mem "CallMode" true))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "RuntimeType" true) (mem "BinderRow" false))))
(DUse false (UseGroup ("backend" "core_validate") ((mem "validateBinderStamps" false) (mem "validateCalls" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "joinNl" false))))
(DTypeSig false "sameBinder" (TyFun (TyCon "BinderId") (TyFun (TyCon "BinderId") (TyCon "Bool"))))
(DFunDef false "sameBinder" ((PCon "BinderId" (PVar "a") (PVar "n")) (PCon "BinderId" (PVar "b") (PVar "k"))) (EBinOp "&&" (EBinOp "==" (EVar "a") (EVar "b")) (EBinOp "==" (EVar "n") (EVar "k"))))
(DTypeSig false "integerLiteral" (TyFun (TyCon "CExpr") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "integerLiteral" ((PCon "CLit" (PCon "LInt" (PVar "n")))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "integerLiteral" (PWild) (EVar "None"))
(DTypeSig false "arguments" (TyFun (TyCon "String") (TyFun (TyCon "CExpr") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "CExpr"))))))
(DFunDef false "arguments" ((PVar "name") (PCon "CApp" (PCon "CVar" (PVar "actual") (PCon "AGlobal")) (PVar "args") (PCon "CallSite" (PCon "CallDynamic") PWild))) (EIf (EBinOp "==" (EVar "actual") (EVar "name")) (EApp (EVar "Some") (EVar "args")) (EVar "None")))
(DFunDef false "arguments" (PWild PWild) (EVar "None"))
(DTypeSig false "sourceVar" (TyFun (TyCon "String") (TyFun (TyCon "CExpr") (TyCon "Bool"))))
(DFunDef false "sourceVar" ((PVar "name") (PCon "CVar" (PVar "actual") (PCon "ALocal" (PLit (LInt 0)) (PLit (LInt 0))))) (EBinOp "==" (EVar "actual") (EVar "name")))
(DFunDef false "sourceVar" (PWild PWild) (EVar "False"))
(DTypeSig false "makeSize" (TyFun (TyCon "CExpr") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "makeSize" ((PVar "ex")) (EMatch (EApp (EApp (EVar "arguments") (ELit (LString "byteBlockMake"))) (EVar "ex")) (arm (PCon "Some" (PList (PVar "n"))) () (EMatch (EApp (EVar "integerLiteral") (EVar "n")) (arm (PCon "Some" (PVar "count")) ((GBool (EBinOp "&&" (EBinOp ">=" (EVar "count") (ELit (LInt 0))) (EBinOp "<=" (EVar "count") (ELit (LInt 4096)))))) (EApp (EVar "Some") (EVar "count"))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "leafStatement" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "CExpr") (TyCon "Bool")))))
(DFunDef false "leafStatement" ((PVar "name") (PVar "capacity") (PVar "ex")) (EMatch (EApp (EApp (EVar "arguments") (ELit (LString "byteBlockSetUnsafe"))) (EVar "ex")) (arm (PCon "Some" (PList (PVar "i") (PVar "value") (PVar "bb"))) () (EMatch (ETuple (EApp (EVar "integerLiteral") (EVar "i")) (EApp (EVar "integerLiteral") (EVar "value"))) (arm (PTuple (PCon "Some" (PVar "index")) (PCon "Some" (PVar "byte"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "sourceVar") (EVar "name")) (EVar "bb")) (EBinOp ">=" (EVar "index") (ELit (LInt 0)))) (EBinOp "<" (EVar "index") (EVar "capacity"))) (EBinOp ">=" (EVar "byte") (ELit (LInt 0)))) (EBinOp "<=" (EVar "byte") (ELit (LInt 255))))) (arm PWild () (EVar "False")))) (arm PWild () (EMatch (EApp (EApp (EVar "arguments") (ELit (LString "byteBlockBlit"))) (EVar "ex")) (arm (PCon "Some" (PList (PVar "src") (PVar "so") (PVar "dst") (PVar "do_") (PVar "n"))) () (EMatch (ETuple (EApp (EVar "integerLiteral") (EVar "so")) (EApp (EVar "integerLiteral") (EVar "do_")) (EApp (EVar "integerLiteral") (EVar "n"))) (arm (PTuple (PCon "Some" (PVar "start")) (PCon "Some" (PVar "dest")) (PCon "Some" (PVar "count"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "sourceVar") (EVar "name")) (EVar "src")) (EApp (EApp (EVar "sourceVar") (EVar "name")) (EVar "dst"))) (EBinOp ">=" (EVar "start") (ELit (LInt 0)))) (EBinOp "<=" (EVar "start") (EVar "capacity"))) (EBinOp ">=" (EVar "dest") (ELit (LInt 0)))) (EBinOp "<=" (EVar "dest") (EVar "capacity"))) (EBinOp ">=" (EVar "count") (ELit (LInt 0)))) (EBinOp "<=" (EVar "count") (EVar "capacity"))) (EBinOp "<=" (EBinOp "+" (EVar "start") (EVar "count")) (EVar "capacity"))) (EBinOp "<=" (EBinOp "+" (EVar "dest") (EVar "count")) (EVar "capacity")))) (arm PWild () (EVar "False")))) (arm PWild () (EVar "False"))))))
(DTypeSig false "copySize" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "CExpr") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "copySize" ((PVar "name") (PVar "capacity") (PVar "ex")) (EMatch (EApp (EApp (EVar "arguments") (ELit (LString "byteBlockCopyUnsafe"))) (EVar "ex")) (arm (PCon "Some" (PList (PVar "n") (PVar "bb"))) () (EMatch (EApp (EVar "integerLiteral") (EVar "n")) (arm (PCon "Some" (PVar "count")) ((GBool (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "sourceVar") (EVar "name")) (EVar "bb")) (EBinOp ">=" (EVar "count") (ELit (LInt 0)))) (EBinOp "<=" (EVar "count") (EVar "capacity"))))) (EApp (EVar "Some") (EVar "count"))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "terminal" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "CExpr") (TyCon "Bool")))))
(DFunDef false "terminal" ((PVar "name") (PVar "capacity") (PVar "ex")) (EMatch (EApp (EApp (EVar "arguments") (ELit (LString "byteBlockGetUnsafe"))) (EVar "ex")) (arm (PCon "Some" (PList (PVar "i") (PVar "copy"))) () (EMatch (ETuple (EApp (EVar "integerLiteral") (EVar "i")) (EApp (EApp (EApp (EVar "copySize") (EVar "name")) (EVar "capacity")) (EVar "copy"))) (arm (PTuple (PCon "Some" (PVar "index")) (PCon "Some" (PVar "count"))) () (EBinOp "&&" (EBinOp ">=" (EVar "index") (ELit (LInt 0))) (EBinOp "<" (EVar "index") (EVar "count")))) (arm PWild () (EVar "False")))) (arm PWild () (EMatch (EApp (EApp (EVar "arguments") (ELit (LString "byteBlockLength"))) (EVar "ex")) (arm (PCon "Some" (PList (PVar "copy"))) () (EMatch (EApp (EApp (EApp (EVar "copySize") (EVar "name")) (EVar "capacity")) (EVar "copy")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False")))) (arm PWild () (EVar "False"))))))
(DTypeSig false "finish" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyCon "Bool")))))
(DFunDef false "finish" ((PVar "name") (PVar "capacity") (PList (PCon "CSExpr" (PVar "result")))) (EApp (EApp (EApp (EVar "terminal") (EVar "name")) (EVar "capacity")) (EVar "result")))
(DFunDef false "finish" ((PVar "name") (PVar "capacity") (PCons (PCon "CSExpr" (PVar "ex")) (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EApp (EVar "leafStatement") (EVar "name")) (EVar "capacity")) (EVar "ex")) (EApp (EApp (EApp (EVar "finish") (EVar "name")) (EVar "capacity")) (EVar "rest"))))
(DFunDef false "finish" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "bodyAccepted" (TyFun (TyCon "CExpr") (TyCon "Bool")))
(DFunDef false "bodyAccepted" ((PCon "CBlock" (PCons (PCon "CSLet" (PCon "False") (PCon "PVar" (PVar "name") PWild PWild) (PVar "allocation")) (PVar "rest")))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "name") (ELit (LString "byteBlockMake"))) (EBinOp "/=" (EVar "name") (ELit (LString "byteBlockCopyUnsafe")))) (EBinOp "/=" (EVar "name") (ELit (LString "byteBlockGetUnsafe")))) (EBinOp "/=" (EVar "name") (ELit (LString "byteBlockLength")))) (EBinOp "/=" (EVar "name") (ELit (LString "byteBlockSetUnsafe")))) (EBinOp "/=" (EVar "name") (ELit (LString "byteBlockBlit")))) (EMatch (EApp (EVar "makeSize") (EVar "allocation")) (arm (PCon "Some" (PVar "count")) () (EApp (EApp (EApp (EVar "finish") (EVar "name")) (EVar "count")) (EVar "rest"))) (arm (PCon "None") () (EVar "False")))))
(DFunDef false "bodyAccepted" (PWild) (EVar "False"))
(DTypeSig false "sourceFact" (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "List") (TyCon "BinderRow")) (TyCon "Bool"))))
(DFunDef false "sourceFact" ((PCon "CBlock" (PCons (PCon "CSLet" (PCon "False") (PCon "PVar" (PVar "name") PWild (PVar "bid")) PWild) PWild)) (PVar "rows")) (EApp (EApp (EVar "anyList") (ELam ((PVar "row")) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "sameBinder") (EFieldAccess (EVar "row") "brId")) (EVar "bid")) (EBinOp "==" (EFieldAccess (EVar "row") "brName") (EVar "name"))) (EBinOp "==" (EFieldAccess (EVar "row") "brType") (EVar "RTValue"))))) (EVar "rows")))
(DFunDef false "sourceFact" (PWild PWild) (EVar "False"))
(DTypeSig true "validateByteBlockKernel" (TyFun (TyCon "CProgram") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))
(DFunDef false "validateByteBlockKernel" ((PAs "cp" (PCon "CProgram" (PVar "groups") (PVar "ctors") (PVar "ctorTypes") (PVar "impls") (PVar "contexts") (PVar "facts")))) (EBlock (DoLet false false (PVar "faults") (EBinOp "++" (EApp (EVar "validateBinderStamps") (EVar "cp")) (EApp (EVar "validateCalls") (EVar "cp")))) (DoExpr (EIf (EBinOp "/=" (EVar "faults") (EListLit)) (EApp (EVar "Err") (EApp (EVar "joinNl") (EVar "faults"))) (EMatch (ETuple (EVar "groups") (EVar "ctors") (EVar "ctorTypes") (EVar "impls") (EVar "contexts")) (arm (PTuple (PList (PCon "CBind" (PLit (LString "main")) (PList (PCon "CClause" (PList) (PVar "body"))) PWild (PVar "bid"))) (PList) (PList) (PList) (PList)) () (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "anyList") (ELam ((PVar "row")) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "sameBinder") (EFieldAccess (EVar "row") "brId")) (EVar "bid")) (EBinOp "==" (EFieldAccess (EVar "row") "brType") (EVar "RTInt"))) (EBinOp "==" (EFieldAccess (EVar "row") "brReturns") (EApp (EVar "Some") (EVar "RTInt")))))) (EFieldAccess (EVar "facts") "factBinders")) (EApp (EApp (EVar "sourceFact") (EVar "body")) (EFieldAccess (EVar "facts") "factBinders"))) (EApp (EVar "bodyAccepted") (EVar "body"))) (EApp (EVar "Ok") (ELit (LString "(byteblock-kernel v1 runtime-layout=mdk_gc_byteblock_atomic_v1 output=tagged-int source-consumed-by-copy no-escape no-later-argument-allocation)\n"))) (EApp (EVar "Err") (ELit (LString "byteblock kernel: unsupported producer/use or main return contract"))))) (arm PWild () (EApp (EVar "Err") (ELit (LString "byteblock kernel: extra definitions or unsupported module structure")))))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Addr" true) (mem "Pat" true) (mem "Lit" true) (mem "BinderId" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CStmt" true) (mem "CallSite" true) (mem "CallMode" true))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "RuntimeType" true) (mem "BinderRow" false))))
(DUse false (UseGroup ("backend" "core_validate") ((mem "validateBinderStamps" false) (mem "validateCalls" false))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "joinNl" false))))
(DTypeSig false "sameBinder" (TyFun (TyCon "BinderId") (TyFun (TyCon "BinderId") (TyCon "Bool"))))
(DFunDef false "sameBinder" ((PCon "BinderId" (PVar "a") (PVar "n")) (PCon "BinderId" (PVar "b") (PVar "k"))) (EBinOp "&&" (EBinOp "==" (EVar "a") (EVar "b")) (EBinOp "==" (EVar "n") (EVar "k"))))
(DTypeSig false "integerLiteral" (TyFun (TyCon "CExpr") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "integerLiteral" ((PCon "CLit" (PCon "LInt" (PVar "n")))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "integerLiteral" (PWild) (EVar "None"))
(DTypeSig false "arguments" (TyFun (TyCon "String") (TyFun (TyCon "CExpr") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "CExpr"))))))
(DFunDef false "arguments" ((PVar "name") (PCon "CApp" (PCon "CVar" (PVar "actual") (PCon "AGlobal")) (PVar "args") (PCon "CallSite" (PCon "CallDynamic") PWild))) (EIf (EBinOp "==" (EVar "actual") (EVar "name")) (EApp (EVar "Some") (EVar "args")) (EVar "None")))
(DFunDef false "arguments" (PWild PWild) (EVar "None"))
(DTypeSig false "sourceVar" (TyFun (TyCon "String") (TyFun (TyCon "CExpr") (TyCon "Bool"))))
(DFunDef false "sourceVar" ((PVar "name") (PCon "CVar" (PVar "actual") (PCon "ALocal" (PLit (LInt 0)) (PLit (LInt 0))))) (EBinOp "==" (EVar "actual") (EVar "name")))
(DFunDef false "sourceVar" (PWild PWild) (EVar "False"))
(DTypeSig false "makeSize" (TyFun (TyCon "CExpr") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "makeSize" ((PVar "ex")) (EMatch (EApp (EApp (EVar "arguments") (ELit (LString "byteBlockMake"))) (EVar "ex")) (arm (PCon "Some" (PList (PVar "n"))) () (EMatch (EApp (EVar "integerLiteral") (EVar "n")) (arm (PCon "Some" (PVar "count")) ((GBool (EBinOp "&&" (EBinOp ">=" (EDictApp "count") (ELit (LInt 0))) (EBinOp "<=" (EDictApp "count") (ELit (LInt 4096)))))) (EApp (EVar "Some") (EDictApp "count"))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "leafStatement" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "CExpr") (TyCon "Bool")))))
(DFunDef false "leafStatement" ((PVar "name") (PVar "capacity") (PVar "ex")) (EMatch (EApp (EApp (EVar "arguments") (ELit (LString "byteBlockSetUnsafe"))) (EVar "ex")) (arm (PCon "Some" (PList (PVar "i") (PVar "value") (PVar "bb"))) () (EMatch (ETuple (EApp (EVar "integerLiteral") (EVar "i")) (EApp (EVar "integerLiteral") (EVar "value"))) (arm (PTuple (PCon "Some" (PVar "index")) (PCon "Some" (PVar "byte"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "sourceVar") (EVar "name")) (EVar "bb")) (EBinOp ">=" (EMethodRef "index") (ELit (LInt 0)))) (EBinOp "<" (EMethodRef "index") (EVar "capacity"))) (EBinOp ">=" (EVar "byte") (ELit (LInt 0)))) (EBinOp "<=" (EVar "byte") (ELit (LInt 255))))) (arm PWild () (EVar "False")))) (arm PWild () (EMatch (EApp (EApp (EVar "arguments") (ELit (LString "byteBlockBlit"))) (EVar "ex")) (arm (PCon "Some" (PList (PVar "src") (PVar "so") (PVar "dst") (PVar "do_") (PVar "n"))) () (EMatch (ETuple (EApp (EVar "integerLiteral") (EVar "so")) (EApp (EVar "integerLiteral") (EVar "do_")) (EApp (EVar "integerLiteral") (EVar "n"))) (arm (PTuple (PCon "Some" (PVar "start")) (PCon "Some" (PVar "dest")) (PCon "Some" (PVar "count"))) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "sourceVar") (EVar "name")) (EVar "src")) (EApp (EApp (EVar "sourceVar") (EVar "name")) (EVar "dst"))) (EBinOp ">=" (EVar "start") (ELit (LInt 0)))) (EBinOp "<=" (EVar "start") (EVar "capacity"))) (EBinOp ">=" (EVar "dest") (ELit (LInt 0)))) (EBinOp "<=" (EVar "dest") (EVar "capacity"))) (EBinOp ">=" (EDictApp "count") (ELit (LInt 0)))) (EBinOp "<=" (EDictApp "count") (EVar "capacity"))) (EBinOp "<=" (EBinOp "+" (EVar "start") (EDictApp "count")) (EVar "capacity"))) (EBinOp "<=" (EBinOp "+" (EVar "dest") (EDictApp "count")) (EVar "capacity")))) (arm PWild () (EVar "False")))) (arm PWild () (EVar "False"))))))
(DTypeSig false "copySize" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "CExpr") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "copySize" ((PVar "name") (PVar "capacity") (PVar "ex")) (EMatch (EApp (EApp (EVar "arguments") (ELit (LString "byteBlockCopyUnsafe"))) (EVar "ex")) (arm (PCon "Some" (PList (PVar "n") (PVar "bb"))) () (EMatch (EApp (EVar "integerLiteral") (EVar "n")) (arm (PCon "Some" (PVar "count")) ((GBool (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "sourceVar") (EVar "name")) (EVar "bb")) (EBinOp ">=" (EDictApp "count") (ELit (LInt 0)))) (EBinOp "<=" (EDictApp "count") (EVar "capacity"))))) (EApp (EVar "Some") (EDictApp "count"))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "terminal" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "CExpr") (TyCon "Bool")))))
(DFunDef false "terminal" ((PVar "name") (PVar "capacity") (PVar "ex")) (EMatch (EApp (EApp (EVar "arguments") (ELit (LString "byteBlockGetUnsafe"))) (EVar "ex")) (arm (PCon "Some" (PList (PVar "i") (PVar "copy"))) () (EMatch (ETuple (EApp (EVar "integerLiteral") (EVar "i")) (EApp (EApp (EApp (EVar "copySize") (EVar "name")) (EVar "capacity")) (EVar "copy"))) (arm (PTuple (PCon "Some" (PVar "index")) (PCon "Some" (PVar "count"))) () (EBinOp "&&" (EBinOp ">=" (EMethodRef "index") (ELit (LInt 0))) (EBinOp "<" (EMethodRef "index") (EDictApp "count")))) (arm PWild () (EVar "False")))) (arm PWild () (EMatch (EApp (EApp (EVar "arguments") (ELit (LString "byteBlockLength"))) (EVar "ex")) (arm (PCon "Some" (PList (PVar "copy"))) () (EMatch (EApp (EApp (EApp (EVar "copySize") (EVar "name")) (EVar "capacity")) (EVar "copy")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False")))) (arm PWild () (EVar "False"))))))
(DTypeSig false "finish" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyCon "Bool")))))
(DFunDef false "finish" ((PVar "name") (PVar "capacity") (PList (PCon "CSExpr" (PVar "result")))) (EApp (EApp (EApp (EVar "terminal") (EVar "name")) (EVar "capacity")) (EVar "result")))
(DFunDef false "finish" ((PVar "name") (PVar "capacity") (PCons (PCon "CSExpr" (PVar "ex")) (PVar "rest"))) (EBinOp "&&" (EApp (EApp (EApp (EVar "leafStatement") (EVar "name")) (EVar "capacity")) (EVar "ex")) (EApp (EApp (EApp (EVar "finish") (EVar "name")) (EVar "capacity")) (EVar "rest"))))
(DFunDef false "finish" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "bodyAccepted" (TyFun (TyCon "CExpr") (TyCon "Bool")))
(DFunDef false "bodyAccepted" ((PCon "CBlock" (PCons (PCon "CSLet" (PCon "False") (PCon "PVar" (PVar "name") PWild PWild) (PVar "allocation")) (PVar "rest")))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "name") (ELit (LString "byteBlockMake"))) (EBinOp "/=" (EVar "name") (ELit (LString "byteBlockCopyUnsafe")))) (EBinOp "/=" (EVar "name") (ELit (LString "byteBlockGetUnsafe")))) (EBinOp "/=" (EVar "name") (ELit (LString "byteBlockLength")))) (EBinOp "/=" (EVar "name") (ELit (LString "byteBlockSetUnsafe")))) (EBinOp "/=" (EVar "name") (ELit (LString "byteBlockBlit")))) (EMatch (EApp (EVar "makeSize") (EVar "allocation")) (arm (PCon "Some" (PVar "count")) () (EApp (EApp (EApp (EVar "finish") (EVar "name")) (EDictApp "count")) (EVar "rest"))) (arm (PCon "None") () (EVar "False")))))
(DFunDef false "bodyAccepted" (PWild) (EVar "False"))
(DTypeSig false "sourceFact" (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "List") (TyCon "BinderRow")) (TyCon "Bool"))))
(DFunDef false "sourceFact" ((PCon "CBlock" (PCons (PCon "CSLet" (PCon "False") (PCon "PVar" (PVar "name") PWild (PVar "bid")) PWild) PWild)) (PVar "rows")) (EApp (EApp (EVar "anyList") (ELam ((PVar "row")) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "sameBinder") (EFieldAccess (EVar "row") "brId")) (EVar "bid")) (EBinOp "==" (EFieldAccess (EVar "row") "brName") (EVar "name"))) (EBinOp "==" (EFieldAccess (EVar "row") "brType") (EVar "RTValue"))))) (EVar "rows")))
(DFunDef false "sourceFact" (PWild PWild) (EVar "False"))
(DTypeSig true "validateByteBlockKernel" (TyFun (TyCon "CProgram") (TyApp (TyApp (TyCon "Result") (TyCon "String")) (TyCon "String"))))
(DFunDef false "validateByteBlockKernel" ((PAs "cp" (PCon "CProgram" (PVar "groups") (PVar "ctors") (PVar "ctorTypes") (PVar "impls") (PVar "contexts") (PVar "facts")))) (EBlock (DoLet false false (PVar "faults") (EBinOp "++" (EApp (EVar "validateBinderStamps") (EVar "cp")) (EApp (EVar "validateCalls") (EVar "cp")))) (DoExpr (EIf (EBinOp "/=" (EVar "faults") (EListLit)) (EApp (EVar "Err") (EApp (EVar "joinNl") (EVar "faults"))) (EMatch (ETuple (EVar "groups") (EVar "ctors") (EVar "ctorTypes") (EVar "impls") (EVar "contexts")) (arm (PTuple (PList (PCon "CBind" (PLit (LString "main")) (PList (PCon "CClause" (PList) (PVar "body"))) PWild (PVar "bid"))) (PList) (PList) (PList) (PList)) () (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "anyList") (ELam ((PVar "row")) (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "sameBinder") (EFieldAccess (EVar "row") "brId")) (EVar "bid")) (EBinOp "==" (EFieldAccess (EVar "row") "brType") (EVar "RTInt"))) (EBinOp "==" (EFieldAccess (EVar "row") "brReturns") (EApp (EVar "Some") (EVar "RTInt")))))) (EFieldAccess (EVar "facts") "factBinders")) (EApp (EApp (EVar "sourceFact") (EVar "body")) (EFieldAccess (EVar "facts") "factBinders"))) (EApp (EVar "bodyAccepted") (EVar "body"))) (EApp (EVar "Ok") (ELit (LString "(byteblock-kernel v1 runtime-layout=mdk_gc_byteblock_atomic_v1 output=tagged-int source-consumed-by-copy no-escape no-later-argument-allocation)\n"))) (EApp (EVar "Err") (ELit (LString "byteblock kernel: unsupported producer/use or main return contract"))))) (arm PWild () (EApp (EVar "Err") (ELit (LString "byteblock kernel: extra definitions or unsupported module structure")))))))))
