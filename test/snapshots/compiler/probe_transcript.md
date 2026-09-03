# META
source_lines=84
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/probe_transcript.mdk — the sentinel-delimited stdout format
-- the native execution engines read back.
--
-- Both native engines — `native_doctest.mdk` (doctests) and
-- `native_test_decls.mdk` (`test "…"` decls) — compile ONE probe binary per
-- file and recover the values it printed.  What they compile is genuinely
-- different (a doctest owns a source expression, a `test "…"` decl owns an
-- `Expr`), which is why neither generates the other's probe.  What they READ is
-- the same thing twice, and that half lives here.
--
-- ── the format ──────────────────────────────────────────────────────────────
-- A printed value can span MANY lines, so the split point cannot be "one line
-- per value".  The probe prints a sentinel line BEFORE each value; a value is
-- every line up to the next sentinel.  A trailing sentinel closes the last
-- value — which is also what makes "complete" decidable: a value is complete
-- iff ANOTHER sentinel followed it.  Without the terminator, a probe killed
-- immediately after printing the final value would be indistinguishable from a
-- clean run, and "this didn't run" would look exactly like "this passed".
--
-- The sentinel PREFIX is per-engine (so one engine's transcript can never be
-- mistaken for the other's) and therefore a parameter here, not a constant.

import support.util.{reverseL, startsWith, stringTrim}

-- The tag of a sentinel line under `prefix`, or None for an ordinary output
-- line.
export
sentTagOf : String -> String -> Option String
sentTagOf prefix line
  | startsWith prefix line =
    Some (stringSlice (stringLength prefix) (stringLength line) line)
  | otherwise = None

export
sentinelLine : String -> String -> String
sentinelLine prefix tag = prefix ++ tag

-- The tag of the terminator both engines print last.
export
endTag : String
endTag = "END"

-- tag, the value's lines, and whether ANOTHER sentinel followed (i.e. the value
-- is complete rather than truncated by an abort).
public export data Chunk = Chunk String (List String) Bool

export
chunksOf : String -> List String -> List Chunk
chunksOf prefix lines = reverseL (chunkScan prefix [] None [] lines)

-- Lines before the FIRST sentinel are dropped: they are whatever the module's
-- own top-level effects printed, not part of any value.
chunkScan : String ->
  List Chunk ->
  Option String ->
  List String ->
  List String ->
  List Chunk
chunkScan _ acc cur curLines [] = closeChunk acc cur curLines False
chunkScan prefix acc cur curLines (l :: rest) = match sentTagOf prefix l
  Some t => chunkScan prefix (closeChunk acc cur curLines True) (Some t) [] rest
  None => match cur
    None => chunkScan prefix acc cur curLines rest
    Some _ => chunkScan prefix acc cur (l :: curLines) rest

closeChunk : List Chunk -> Option String -> List String -> Bool -> List Chunk
closeChunk acc None _ _ = acc
closeChunk acc (Some t) curLines terminated =
  Chunk t (reverseL curLines) terminated :: acc

export
lookupChunk : String -> List Chunk -> Option Chunk
lookupChunk _ [] = None
lookupChunk tag ((Chunk t ls done) :: rest)
  | t == tag = Some (Chunk t ls done)
  | otherwise = lookupChunk tag rest

-- The probe's stderr, reduced to the one line worth quoting in an abort note.
export
firstNonEmptyLine : List String -> String
firstNonEmptyLine [] = ""
firstNonEmptyLine (l :: rest)
  | stringTrim l == "" = firstNonEmptyLine rest
  | otherwise = stringTrim l
# DESUGAR
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "startsWith" false) (mem "stringTrim" false))))
(DTypeSig true "sentTagOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "sentTagOf" ((PVar "prefix") (PVar "line")) (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "line")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "prefix"))) (EApp (EVar "stringLength") (EVar "line"))) (EVar "line"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "sentinelLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "sentinelLine" ((PVar "prefix") (PVar "tag")) (EBinOp "++" (EVar "prefix") (EVar "tag")))
(DTypeSig true "endTag" (TyCon "String"))
(DFunDef false "endTag" () (ELit (LString "END")))
(DData Public "Chunk" () ((variant "Chunk" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))) ())
(DTypeSig true "chunksOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Chunk")))))
(DFunDef false "chunksOf" ((PVar "prefix") (PVar "lines")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EApp (EApp (EVar "chunkScan") (EVar "prefix")) (EListLit)) (EVar "None")) (EListLit)) (EVar "lines"))))
(DTypeSig false "chunkScan" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Chunk"))))))))
(DFunDef false "chunkScan" (PWild (PVar "acc") (PVar "cur") (PVar "curLines") (PList)) (EApp (EApp (EApp (EApp (EVar "closeChunk") (EVar "acc")) (EVar "cur")) (EVar "curLines")) (EVar "False")))
(DFunDef false "chunkScan" ((PVar "prefix") (PVar "acc") (PVar "cur") (PVar "curLines") (PCons (PVar "l") (PVar "rest"))) (EMatch (EApp (EApp (EVar "sentTagOf") (EVar "prefix")) (EVar "l")) (arm (PCon "Some" (PVar "t")) () (EApp (EApp (EApp (EApp (EApp (EVar "chunkScan") (EVar "prefix")) (EApp (EApp (EApp (EApp (EVar "closeChunk") (EVar "acc")) (EVar "cur")) (EVar "curLines")) (EVar "True"))) (EApp (EVar "Some") (EVar "t"))) (EListLit)) (EVar "rest"))) (arm (PCon "None") () (EMatch (EVar "cur") (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "chunkScan") (EVar "prefix")) (EVar "acc")) (EVar "cur")) (EVar "curLines")) (EVar "rest"))) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EApp (EVar "chunkScan") (EVar "prefix")) (EVar "acc")) (EVar "cur")) (EBinOp "::" (EVar "l") (EVar "curLines"))) (EVar "rest")))))))
(DTypeSig false "closeChunk" (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Chunk")))))))
(DFunDef false "closeChunk" ((PVar "acc") (PCon "None") PWild PWild) (EVar "acc"))
(DFunDef false "closeChunk" ((PVar "acc") (PCon "Some" (PVar "t")) (PVar "curLines") (PVar "terminated")) (EBinOp "::" (EApp (EApp (EApp (EVar "Chunk") (EVar "t")) (EApp (EVar "reverseL") (EVar "curLines"))) (EVar "terminated")) (EVar "acc")))
(DTypeSig true "lookupChunk" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyApp (TyCon "Option") (TyCon "Chunk")))))
(DFunDef false "lookupChunk" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupChunk" ((PVar "tag") (PCons (PCon "Chunk" (PVar "t") (PVar "ls") (PVar "done")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "t") (EVar "tag")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "Chunk") (EVar "t")) (EVar "ls")) (EVar "done"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupChunk") (EVar "tag")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "firstNonEmptyLine" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "firstNonEmptyLine" ((PList)) (ELit (LString "")))
(DFunDef false "firstNonEmptyLine" ((PCons (PVar "l") (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "stringTrim") (EVar "l")) (ELit (LString ""))) (EApp (EVar "firstNonEmptyLine") (EVar "rest")) (EIf (EVar "otherwise") (EApp (EVar "stringTrim") (EVar "l")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
# MARK
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "startsWith" false) (mem "stringTrim" false))))
(DTypeSig true "sentTagOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "sentTagOf" ((PVar "prefix") (PVar "line")) (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "line")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "prefix"))) (EApp (EVar "stringLength") (EVar "line"))) (EVar "line"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "sentinelLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "sentinelLine" ((PVar "prefix") (PVar "tag")) (EBinOp "++" (EVar "prefix") (EVar "tag")))
(DTypeSig true "endTag" (TyCon "String"))
(DFunDef false "endTag" () (ELit (LString "END")))
(DData Public "Chunk" () ((variant "Chunk" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "String")) (TyCon "Bool")))) ())
(DTypeSig true "chunksOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Chunk")))))
(DFunDef false "chunksOf" ((PVar "prefix") (PVar "lines")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EApp (EApp (EVar "chunkScan") (EVar "prefix")) (EListLit)) (EVar "None")) (EListLit)) (EVar "lines"))))
(DTypeSig false "chunkScan" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "Chunk"))))))))
(DFunDef false "chunkScan" (PWild (PVar "acc") (PVar "cur") (PVar "curLines") (PList)) (EApp (EApp (EApp (EApp (EVar "closeChunk") (EVar "acc")) (EVar "cur")) (EVar "curLines")) (EVar "False")))
(DFunDef false "chunkScan" ((PVar "prefix") (PVar "acc") (PVar "cur") (PVar "curLines") (PCons (PVar "l") (PVar "rest"))) (EMatch (EApp (EApp (EVar "sentTagOf") (EVar "prefix")) (EVar "l")) (arm (PCon "Some" (PVar "t")) () (EApp (EApp (EApp (EApp (EApp (EVar "chunkScan") (EVar "prefix")) (EApp (EApp (EApp (EApp (EVar "closeChunk") (EVar "acc")) (EVar "cur")) (EVar "curLines")) (EVar "True"))) (EApp (EVar "Some") (EVar "t"))) (EListLit)) (EVar "rest"))) (arm (PCon "None") () (EMatch (EVar "cur") (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "chunkScan") (EVar "prefix")) (EVar "acc")) (EVar "cur")) (EVar "curLines")) (EVar "rest"))) (arm (PCon "Some" PWild) () (EApp (EApp (EApp (EApp (EApp (EVar "chunkScan") (EVar "prefix")) (EVar "acc")) (EVar "cur")) (EBinOp "::" (EVar "l") (EVar "curLines"))) (EVar "rest")))))))
(DTypeSig false "closeChunk" (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Chunk")))))))
(DFunDef false "closeChunk" ((PVar "acc") (PCon "None") PWild PWild) (EVar "acc"))
(DFunDef false "closeChunk" ((PVar "acc") (PCon "Some" (PVar "t")) (PVar "curLines") (PVar "terminated")) (EBinOp "::" (EApp (EApp (EApp (EVar "Chunk") (EVar "t")) (EApp (EVar "reverseL") (EVar "curLines"))) (EVar "terminated")) (EVar "acc")))
(DTypeSig true "lookupChunk" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyApp (TyCon "Option") (TyCon "Chunk")))))
(DFunDef false "lookupChunk" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupChunk" ((PVar "tag") (PCons (PCon "Chunk" (PVar "t") (PVar "ls") (PVar "done")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "t") (EVar "tag")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "Chunk") (EVar "t")) (EVar "ls")) (EVar "done"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupChunk") (EVar "tag")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "firstNonEmptyLine" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "firstNonEmptyLine" ((PList)) (ELit (LString "")))
(DFunDef false "firstNonEmptyLine" ((PCons (PVar "l") (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "stringTrim") (EVar "l")) (ELit (LString ""))) (EApp (EVar "firstNonEmptyLine") (EVar "rest")) (EIf (EVar "otherwise") (EApp (EVar "stringTrim") (EVar "l")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
