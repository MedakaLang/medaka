# META
source_lines=36
stages=DESUGAR,MARK
# SOURCE
import support.source_index.{
  SourceIndex, sourcePositionToOffset, offsetToUtf16Position,
  utf16PositionToOffset, clampSourcePositionToOffset
}
import frontend.ast.{Loc(..)}
import json.{Json(..), jObject, get, asInt}

position : (Int, Int) -> Json
position (line, col) = jObject [("line", JInt line), ("character", JInt col)]

export
locToLspRange : SourceIndex -> Loc -> Option Json
locToLspRange index (Loc _ sl sc el ec) = do
  start <- sourcePositionToOffset index sl sc
  end <- sourcePositionToOffset index el ec
  a <- offsetToUtf16Position index start
  b <- offsetToUtf16Position index end
  Some (jObject [("start", position a), ("end", position b)])

export
lspPositionToOffset : SourceIndex -> Json -> Option Int
lspPositionToOffset index pos = match (get "line" pos, get "character" pos)
  (Some l, Some c) => match (asInt l, asInt c)
    (Some line, Some col) => utf16PositionToOffset index line col
    _ => None
  _ => None

export
clampedLocToLspRange : SourceIndex -> Loc -> Option Json
clampedLocToLspRange index (Loc _ sl sc el ec) = match (
  offsetToUtf16Position index (clampSourcePositionToOffset index sl sc),
  offsetToUtf16Position index (clampSourcePositionToOffset index el ec),
)
  (Some a, Some b) =>
    Some (jObject [("start", position a), ("end", position b)])
  _ => None
# DESUGAR
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "sourcePositionToOffset" false) (mem "offsetToUtf16Position" false) (mem "utf16PositionToOffset" false) (mem "clampSourcePositionToOffset" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true))))
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false) (mem "get" false) (mem "asInt" false))))
(DTypeSig false "position" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "Json")))
(DFunDef false "position" ((PTuple (PVar "line") (PVar "col"))) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "col"))))))
(DTypeSig true "locToLspRange" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Loc") (TyApp (TyCon "Option") (TyCon "Json")))))
(DFunDef false "locToLspRange" ((PVar "index") (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EVar "index")) (EVar "sl")) (EVar "sc"))) (ELam ((PVar "start")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EVar "index")) (EVar "el")) (EVar "ec"))) (ELam ((PVar "end")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "offsetToUtf16Position") (EVar "index")) (EVar "start"))) (ELam ((PVar "a")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "offsetToUtf16Position") (EVar "index")) (EVar "end"))) (ELam ((PVar "b")) (EApp (EVar "Some") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "start")) (EApp (EVar "position") (EVar "a"))) (ETuple (ELit (LString "end")) (EApp (EVar "position") (EVar "b")))))))))))))))
(DTypeSig true "lspPositionToOffset" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "lspPositionToOffset" ((PVar "index") (PVar "pos")) (EMatch (ETuple (EApp (EApp (EVar "get") (ELit (LString "line"))) (EVar "pos")) (EApp (EApp (EVar "get") (ELit (LString "character"))) (EVar "pos"))) (arm (PTuple (PCon "Some" (PVar "l")) (PCon "Some" (PVar "c"))) () (EMatch (ETuple (EApp (EVar "asInt") (EVar "l")) (EApp (EVar "asInt") (EVar "c"))) (arm (PTuple (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EApp (EApp (EApp (EVar "utf16PositionToOffset") (EVar "index")) (EVar "line")) (EVar "col"))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig true "clampedLocToLspRange" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Loc") (TyApp (TyCon "Option") (TyCon "Json")))))
(DFunDef false "clampedLocToLspRange" ((PVar "index") (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EMatch (ETuple (EApp (EApp (EVar "offsetToUtf16Position") (EVar "index")) (EApp (EApp (EApp (EVar "clampSourcePositionToOffset") (EVar "index")) (EVar "sl")) (EVar "sc"))) (EApp (EApp (EVar "offsetToUtf16Position") (EVar "index")) (EApp (EApp (EApp (EVar "clampSourcePositionToOffset") (EVar "index")) (EVar "el")) (EVar "ec")))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) () (EApp (EVar "Some") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "start")) (EApp (EVar "position") (EVar "a"))) (ETuple (ELit (LString "end")) (EApp (EVar "position") (EVar "b"))))))) (arm PWild () (EVar "None"))))
# MARK
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "sourcePositionToOffset" false) (mem "offsetToUtf16Position" false) (mem "utf16PositionToOffset" false) (mem "clampSourcePositionToOffset" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true))))
(DUse false (UseGroup ("json") ((mem "Json" true) (mem "jObject" false) (mem "get" false) (mem "asInt" false))))
(DTypeSig false "position" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "Json")))
(DFunDef false "position" ((PTuple (PVar "line") (PVar "col"))) (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "line")) (EApp (EVar "JInt") (EVar "line"))) (ETuple (ELit (LString "character")) (EApp (EVar "JInt") (EVar "col"))))))
(DTypeSig true "locToLspRange" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Loc") (TyApp (TyCon "Option") (TyCon "Json")))))
(DFunDef false "locToLspRange" ((PVar "index") (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EMethodRef "index")) (EVar "sl")) (EVar "sc"))) (ELam ((PVar "start")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "sourcePositionToOffset") (EMethodRef "index")) (EVar "el")) (EVar "ec"))) (ELam ((PVar "end")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "offsetToUtf16Position") (EMethodRef "index")) (EVar "start"))) (ELam ((PVar "a")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "offsetToUtf16Position") (EMethodRef "index")) (EVar "end"))) (ELam ((PVar "b")) (EApp (EVar "Some") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "start")) (EApp (EVar "position") (EVar "a"))) (ETuple (ELit (LString "end")) (EApp (EVar "position") (EVar "b")))))))))))))))
(DTypeSig true "lspPositionToOffset" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Json") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "lspPositionToOffset" ((PVar "index") (PVar "pos")) (EMatch (ETuple (EApp (EApp (EVar "get") (ELit (LString "line"))) (EVar "pos")) (EApp (EApp (EVar "get") (ELit (LString "character"))) (EVar "pos"))) (arm (PTuple (PCon "Some" (PVar "l")) (PCon "Some" (PVar "c"))) () (EMatch (ETuple (EApp (EVar "asInt") (EVar "l")) (EApp (EVar "asInt") (EVar "c"))) (arm (PTuple (PCon "Some" (PVar "line")) (PCon "Some" (PVar "col"))) () (EApp (EApp (EApp (EVar "utf16PositionToOffset") (EMethodRef "index")) (EVar "line")) (EVar "col"))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig true "clampedLocToLspRange" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Loc") (TyApp (TyCon "Option") (TyCon "Json")))))
(DFunDef false "clampedLocToLspRange" ((PVar "index") (PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EMatch (ETuple (EApp (EApp (EVar "offsetToUtf16Position") (EMethodRef "index")) (EApp (EApp (EApp (EVar "clampSourcePositionToOffset") (EMethodRef "index")) (EVar "sl")) (EVar "sc"))) (EApp (EApp (EVar "offsetToUtf16Position") (EMethodRef "index")) (EApp (EApp (EApp (EVar "clampSourcePositionToOffset") (EMethodRef "index")) (EVar "el")) (EVar "ec")))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) () (EApp (EVar "Some") (EApp (EVar "jObject") (EListLit (ETuple (ELit (LString "start")) (EApp (EVar "position") (EVar "a"))) (ETuple (ELit (LString "end")) (EApp (EVar "position") (EVar "b"))))))) (arm PWild () (EVar "None"))))
