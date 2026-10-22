# META
source_lines=22
stages=DESUGAR,MARK
# SOURCE
-- Runtime facts for primitive operators.  This module reads only the solved
-- type representation: it has no graph, evidence, or backend state.

import types.repr.{Mono}
import types.runtime_types.{RuntimeType(..), runtimeTypeOf}

-- The scalar tag carried by a monomorphic arithmetic site, or `None` when the
-- operand's solved type does not name one of the primitive arithmetic kinds.
-- In particular, an unbound `Num a` variable stays `RTValue`, so its operation
-- keeps the dictionary/runtime-dispatch path.
export
arithmeticTag : Mono -> Option String
arithmeticTag mono = match runtimeTypeOf (_ _ => False) mono
  RTInt => Some "Int"
  RTFloat => Some "Float"
  RTU64 => Some "U64"
  RTI64 => Some "I64"
  RTU32 => Some "U32"
  RTI32 => Some "I32"
  RTU16 => Some "U16"
  RTU8 => Some "U8"
  _ => None
# DESUGAR
(DUse false (UseGroup ("types" "repr") ((mem "Mono" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "RuntimeType" true) (mem "runtimeTypeOf" false))))
(DTypeSig true "arithmeticTag" (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "arithmeticTag" ((PVar "mono")) (EMatch (EApp (EApp (EVar "runtimeTypeOf") (ELam (PWild PWild) (EVar "False"))) (EVar "mono")) (arm (PCon "RTInt") () (EApp (EVar "Some") (ELit (LString "Int")))) (arm (PCon "RTFloat") () (EApp (EVar "Some") (ELit (LString "Float")))) (arm (PCon "RTU64") () (EApp (EVar "Some") (ELit (LString "U64")))) (arm (PCon "RTI64") () (EApp (EVar "Some") (ELit (LString "I64")))) (arm (PCon "RTU32") () (EApp (EVar "Some") (ELit (LString "U32")))) (arm (PCon "RTI32") () (EApp (EVar "Some") (ELit (LString "I32")))) (arm (PCon "RTU16") () (EApp (EVar "Some") (ELit (LString "U16")))) (arm (PCon "RTU8") () (EApp (EVar "Some") (ELit (LString "U8")))) (arm PWild () (EVar "None"))))
# MARK
(DUse false (UseGroup ("types" "repr") ((mem "Mono" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "RuntimeType" true) (mem "runtimeTypeOf" false))))
(DTypeSig true "arithmeticTag" (TyFun (TyCon "Mono") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "arithmeticTag" ((PVar "mono")) (EMatch (EApp (EApp (EVar "runtimeTypeOf") (ELam (PWild PWild) (EVar "False"))) (EVar "mono")) (arm (PCon "RTInt") () (EApp (EVar "Some") (ELit (LString "Int")))) (arm (PCon "RTFloat") () (EApp (EVar "Some") (ELit (LString "Float")))) (arm (PCon "RTU64") () (EApp (EVar "Some") (ELit (LString "U64")))) (arm (PCon "RTI64") () (EApp (EVar "Some") (ELit (LString "I64")))) (arm (PCon "RTU32") () (EApp (EVar "Some") (ELit (LString "U32")))) (arm (PCon "RTI32") () (EApp (EVar "Some") (ELit (LString "I32")))) (arm (PCon "RTU16") () (EApp (EVar "Some") (ELit (LString "U16")))) (arm (PCon "RTU8") () (EApp (EVar "Some") (ELit (LString "U8")))) (arm PWild () (EVar "None"))))
