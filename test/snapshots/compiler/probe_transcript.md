# META
source_lines=211
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
--
-- ── the nonce ────────────────────────────────────────────────────────────────
-- `tagsInOrder` proves the observed tag sequence is a prefix of the tags the
-- probe was GENERATED to print — but a probe that prints the ENTIRE expected
-- sequence (forged `Pass`/fields, in order) and then dies satisfies that
-- check completely: a full sequence is trivially a prefix of itself, and the
-- exit code is never consulted once every chunk decodes. Tag TEXT alone can
-- never distinguish "the driver's generated code printed this" from "the
-- target's own source printed this", because the tag text is exactly the
-- fixed, publicly-readable constant a forger's SOURCE — written before any
-- given run — can also spell.
--
-- The fix is a per-run token neither engine's tag vocabulary needs, but the
-- PREFIX does: `mintNonce` draws it from `<Rand>` at driver time, strictly
-- after the target's source was already committed to disk, so no source
-- written before this invocation can contain it. Folded into the prefix via
-- `noncedPrefix` and embedded as a literal in the generated probe's own
-- sentinel-printing code (never exposed to the target's spliced-in source),
-- it turns "spell the sentinel text" from copying a public constant into
-- guessing a value that did not exist when the forger's source was written.
--
-- ── why a value is printed QUOTED ───────────────────────────────────────────
-- A value's own text is chosen by the program under test, so an unescaped
-- value can spell a sentinel line.  That is not a cosmetic collision: a value
-- containing `<prefix><a later tag>` closes its own chunk early and opens a
-- chunk under someone else's tag, and `lookupChunk` answers with the FIRST
-- match — so the forged chunk beats the genuine one the probe prints later,
-- and one test's operand text decides another test's verdict.  The driver
-- would still be the one judging, but on evidence the probe supplied.
--
-- So a value is never printed raw: `valuePrintExpr` prints it through
-- `debugStringLit`, whose output is ONE line, always starts with `"`, and
-- carries no raw newline.  `decodeValue` is the exact inverse.  A quoted value
-- therefore cannot spell a sentinel line whatever it contains.
--
-- Escaping covers the values.  It does not cover what the program under test
-- prints on its own account (a `println` inside a test body lands in the
-- transcript unescaped), so `tagsInOrder` is the second half: the driver knows
-- the exact tag sequence its probe emits, and a transcript that is not that
-- sequence is rejected whole rather than read.  Between them, no text a
-- program can produce turns into a verdict it did not earn — at worst it turns
-- into a loud error.

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

-- Fold a per-run nonce into an engine's fixed prefix base. Both engines call
-- this identically; only the base differs between them (already true of
-- `sentinelPrefix` before the nonce existed).
export
noncedPrefix : String -> String -> String
noncedPrefix base nonce = "\{base}\{nonce}@@ "

-- A fresh per-invocation token, drawn at driver time. Two draws rather than
-- one so a forger who somehow learned the RNG's exact state at the START of a
-- run still cannot predict the SECOND draw without also knowing how many
-- other `<Rand>` calls preceded it in that run — irrelevant against a static
-- source with no side channel at all, but cheap to add and it costs nothing
-- correctness-wise (the two draws are just concatenated digits).
export
mintNonce : Unit -> <IO> String
mintNonce _ =
  let a = randomInt 100000000 999999999
  let b = randomInt 100000000 999999999
  intToString a ++ intToString b

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

-- The observed tags must be the tags the probe was generated to print, in
-- order — truncated by an abort is allowed, reordered or inserted is not.  A
-- transcript that fails this carries a sentinel line the generator did not
-- write, so nothing in it can be trusted to belong to the test it names.
export
tagsInOrder : List String -> List Chunk -> Bool
tagsInOrder _ [] = True
tagsInOrder [] (_ :: _) = False
tagsInOrder (e :: es) ((Chunk t _ _) :: cs) = e == t && tagsInOrder es cs

-- ── values, quoted ──────────────────────────────────────────────────────────

-- The probe-source expression that prints `expr`'s value as one quoted line.
-- Its inverse is `decodeValue`; the two are here together because a change to
-- either alone silently corrupts every value the driver reads.
export
valuePrintExpr : String -> String
valuePrintExpr expr = "putStrLn (debugStringLit (\{expr}))"

-- A chunk's lines back to the value that was printed.  Zero lines is the empty
-- value (a doctest smoke example prints nothing but still evaluates); one line
-- is a quoted value; anything else is a transcript the generator cannot have
-- produced.
export
decodeValue : List String -> Option String
decodeValue [] = Some ""
decodeValue (l :: []) = unquoteLit l
decodeValue _ = None

-- The inverse of `debugStringLit` (runtime/medaka_rt.c): a double-quoted body
-- in which `\\ \n \t \r \0 \"` are the only escapes.  Codepoint-indexed while
-- the escaper is byte-oriented, which agrees: every escape it writes is ASCII
-- and every other byte passes through untouched.
export
unquoteLit : String -> Option String
unquoteLit s
  | stringLength s >= 2
    && charAt s 0 == "\""
    && charAt s (stringLength s - 1) == "\"" =
    unquoteScan s 1 (stringLength s - 1) []
  | otherwise = None

charAt : String -> Int -> String
charAt s i = stringSlice i (i + 1) s

unquoteScan : String -> Int -> Int -> List String -> Option String
unquoteScan s i end acc
  | i >= end = Some (stringConcat (reverseL acc))
  | charAt s i == "\\" =
    if i + 1 >= end then
      None
    else match unescapeChar (charAt s (i + 1))
      Some c => unquoteScan s (i + 2) end (c :: acc)
      None => None
  | otherwise = unquoteScan s (i + 1) end (charAt s i :: acc)

unescapeChar : String -> Option String
unescapeChar "n" = Some "\n"
unescapeChar "t" = Some "\t"
unescapeChar "r" = Some "\r"
unescapeChar "0" = Some "\0"
unescapeChar "\\" = Some "\\"
unescapeChar "\"" = Some "\""
unescapeChar _ = None

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
(DTypeSig true "noncedPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "noncedPrefix" ((PVar "base") (PVar "nonce")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "base"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "nonce"))) (ELit (LString "@@ "))))
(DTypeSig true "mintNonce" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "mintNonce" (PWild) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "randomInt") (ELit (LInt 100000000))) (ELit (LInt 999999999)))) (DoLet false false (PVar "b") (EApp (EApp (EVar "randomInt") (ELit (LInt 100000000))) (ELit (LInt 999999999)))) (DoExpr (EBinOp "++" (EApp (EVar "intToString") (EVar "a")) (EApp (EVar "intToString") (EVar "b"))))))
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
(DTypeSig true "tagsInOrder" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyCon "Bool"))))
(DFunDef false "tagsInOrder" (PWild (PList)) (EVar "True"))
(DFunDef false "tagsInOrder" ((PList) (PCons PWild PWild)) (EVar "False"))
(DFunDef false "tagsInOrder" ((PCons (PVar "e") (PVar "es")) (PCons (PCon "Chunk" (PVar "t") PWild PWild) (PVar "cs"))) (EBinOp "&&" (EBinOp "==" (EVar "e") (EVar "t")) (EApp (EApp (EVar "tagsInOrder") (EVar "es")) (EVar "cs"))))
(DTypeSig true "valuePrintExpr" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "valuePrintExpr" ((PVar "expr")) (EBinOp "++" (EBinOp "++" (ELit (LString "putStrLn (debugStringLit (")) (EApp (EVar "display") (EVar "expr"))) (ELit (LString "))"))))
(DTypeSig true "decodeValue" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "decodeValue" ((PList)) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "decodeValue" ((PCons (PVar "l") (PList))) (EApp (EVar "unquoteLit") (EVar "l")))
(DFunDef false "decodeValue" (PWild) (EVar "None"))
(DTypeSig true "unquoteLit" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "unquoteLit" ((PVar "s")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EVar "charAt") (EVar "s")) (ELit (LInt 0))) (ELit (LString "\"")))) (EBinOp "==" (EApp (EApp (EVar "charAt") (EVar "s")) (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 1)))) (ELit (LString "\"")))) (EApp (EApp (EApp (EApp (EVar "unquoteScan") (EVar "s")) (ELit (LInt 1))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 1)))) (EListLit)) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "charAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "charAt" ((PVar "s") (PVar "i")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s")))
(DTypeSig false "unquoteScan" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "unquoteScan" ((PVar "s") (PVar "i") (PVar "end") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "end")) (EApp (EVar "Some") (EApp (EVar "stringConcat") (EApp (EVar "reverseL") (EVar "acc")))) (EIf (EBinOp "==" (EApp (EApp (EVar "charAt") (EVar "s")) (EVar "i")) (ELit (LString "\\"))) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "end")) (EVar "None") (EMatch (EApp (EVar "unescapeChar") (EApp (EApp (EVar "charAt") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EVar "unquoteScan") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "end")) (EBinOp "::" (EVar "c") (EVar "acc")))) (arm (PCon "None") () (EVar "None")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "unquoteScan") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "end")) (EBinOp "::" (EApp (EApp (EVar "charAt") (EVar "s")) (EVar "i")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "unescapeChar" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "unescapeChar" ((PLit (LString "n"))) (EApp (EVar "Some") (ELit (LString "\n"))))
(DFunDef false "unescapeChar" ((PLit (LString "t"))) (EApp (EVar "Some") (ELit (LString "\t"))))
(DFunDef false "unescapeChar" ((PLit (LString "r"))) (EApp (EVar "Some") (ELit (LString "\r"))))
(DFunDef false "unescapeChar" ((PLit (LString "0"))) (EApp (EVar "Some") (ELit (LString "\0"))))
(DFunDef false "unescapeChar" ((PLit (LString "\\"))) (EApp (EVar "Some") (ELit (LString "\\"))))
(DFunDef false "unescapeChar" ((PLit (LString "\""))) (EApp (EVar "Some") (ELit (LString "\""))))
(DFunDef false "unescapeChar" (PWild) (EVar "None"))
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
(DTypeSig true "noncedPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "noncedPrefix" ((PVar "base") (PVar "nonce")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "base"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "nonce"))) (ELit (LString "@@ "))))
(DTypeSig true "mintNonce" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "mintNonce" (PWild) (EBlock (DoLet false false (PVar "a") (EApp (EApp (EVar "randomInt") (ELit (LInt 100000000))) (ELit (LInt 999999999)))) (DoLet false false (PVar "b") (EApp (EApp (EVar "randomInt") (ELit (LInt 100000000))) (ELit (LInt 999999999)))) (DoExpr (EBinOp "++" (EApp (EVar "intToString") (EVar "a")) (EApp (EVar "intToString") (EVar "b"))))))
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
(DTypeSig true "tagsInOrder" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyCon "Bool"))))
(DFunDef false "tagsInOrder" (PWild (PList)) (EVar "True"))
(DFunDef false "tagsInOrder" ((PList) (PCons PWild PWild)) (EVar "False"))
(DFunDef false "tagsInOrder" ((PCons (PVar "e") (PVar "es")) (PCons (PCon "Chunk" (PVar "t") PWild PWild) (PVar "cs"))) (EBinOp "&&" (EBinOp "==" (EVar "e") (EVar "t")) (EApp (EApp (EVar "tagsInOrder") (EVar "es")) (EVar "cs"))))
(DTypeSig true "valuePrintExpr" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "valuePrintExpr" ((PVar "expr")) (EBinOp "++" (EBinOp "++" (ELit (LString "putStrLn (debugStringLit (")) (EApp (EMethodRef "display") (EVar "expr"))) (ELit (LString "))"))))
(DTypeSig true "decodeValue" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "decodeValue" ((PList)) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "decodeValue" ((PCons (PVar "l") (PList))) (EApp (EVar "unquoteLit") (EVar "l")))
(DFunDef false "decodeValue" (PWild) (EVar "None"))
(DTypeSig true "unquoteLit" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "unquoteLit" ((PVar "s")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EVar "charAt") (EVar "s")) (ELit (LInt 0))) (ELit (LString "\"")))) (EBinOp "==" (EApp (EApp (EVar "charAt") (EVar "s")) (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 1)))) (ELit (LString "\"")))) (EApp (EApp (EApp (EApp (EVar "unquoteScan") (EVar "s")) (ELit (LInt 1))) (EBinOp "-" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 1)))) (EListLit)) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "charAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "charAt" ((PVar "s") (PVar "i")) (EApp (EApp (EApp (EVar "stringSlice") (EVar "i")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "s")))
(DTypeSig false "unquoteScan" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "unquoteScan" ((PVar "s") (PVar "i") (PVar "end") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "end")) (EApp (EVar "Some") (EApp (EVar "stringConcat") (EApp (EVar "reverseL") (EVar "acc")))) (EIf (EBinOp "==" (EApp (EApp (EVar "charAt") (EVar "s")) (EVar "i")) (ELit (LString "\\"))) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "end")) (EVar "None") (EMatch (EApp (EVar "unescapeChar") (EApp (EApp (EVar "charAt") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EVar "unquoteScan") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "end")) (EBinOp "::" (EVar "c") (EVar "acc")))) (arm (PCon "None") () (EVar "None")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "unquoteScan") (EVar "s")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "end")) (EBinOp "::" (EApp (EApp (EVar "charAt") (EVar "s")) (EVar "i")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "unescapeChar" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "unescapeChar" ((PLit (LString "n"))) (EApp (EVar "Some") (ELit (LString "\n"))))
(DFunDef false "unescapeChar" ((PLit (LString "t"))) (EApp (EVar "Some") (ELit (LString "\t"))))
(DFunDef false "unescapeChar" ((PLit (LString "r"))) (EApp (EVar "Some") (ELit (LString "\r"))))
(DFunDef false "unescapeChar" ((PLit (LString "0"))) (EApp (EVar "Some") (ELit (LString "\0"))))
(DFunDef false "unescapeChar" ((PLit (LString "\\"))) (EApp (EVar "Some") (ELit (LString "\\"))))
(DFunDef false "unescapeChar" ((PLit (LString "\""))) (EApp (EVar "Some") (ELit (LString "\""))))
(DFunDef false "unescapeChar" (PWild) (EVar "None"))
(DTypeSig true "lookupChunk" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyApp (TyCon "Option") (TyCon "Chunk")))))
(DFunDef false "lookupChunk" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupChunk" ((PVar "tag") (PCons (PCon "Chunk" (PVar "t") (PVar "ls") (PVar "done")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "t") (EVar "tag")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "Chunk") (EVar "t")) (EVar "ls")) (EVar "done"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupChunk") (EVar "tag")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "firstNonEmptyLine" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "firstNonEmptyLine" ((PList)) (ELit (LString "")))
(DFunDef false "firstNonEmptyLine" ((PCons (PVar "l") (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "stringTrim") (EVar "l")) (ELit (LString ""))) (EApp (EVar "firstNonEmptyLine") (EVar "rest")) (EIf (EVar "otherwise") (EApp (EVar "stringTrim") (EVar "l")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
