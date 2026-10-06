# META
source_lines=333
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
-- Each probe uses OS entropy in its prefix so fixed target output cannot
-- accidentally match another run's tags. Native probes embed that token in
-- generated source; it is not a security boundary against a target that reads
-- its process or build files. Test programs retain their ordinary OS effects.
-- Completeness, value decoding and exit checks still belong to each runner.
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
-- sequence is rejected whole rather than read. These checks prevent ordinary
-- target output and quoted operands from being mistaken for result fields.
--
-- ── the target's own `main` ─────────────────────────────────────────────────
-- Both probes append a synthesized `main` to the target's VERBATIM source, so
-- a target that defines its own would be a duplicate definition.
-- `renameUserMain` renames the target's top-level `main` definition heads
-- instead: the `main` identifier tokens the lexer places at column 0, which
-- are exactly the clause and signature heads of a top-level binding. The
-- rename is located by tokens, never by printing, so every other byte of the
-- target still reaches the backend unchanged, and a `main` inside a comment,
-- a string or a nested binding is left alone.

import frontend.lexer.{
  Token(..),
  tokenizeWithOffsetPairs,
  lineStartsOf,
  offsetToLineColFast,
}
import support.util.{joinNl, reverseL, splitNl, startsWith, stringTrim}
import support.ordmap.{OrdMap, omEmpty, omHasKey, omInsert}
import string.{toInt}

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

-- A fresh per-invocation token, drawn at driver time.
-- OS entropy keeps protocol tags independent of the program's deterministic
-- random stream. Fixed-width bytes make the textual encoding injective.
export
mintNonce : Unit -> <IO> String
mintNonce _ = nonceBytes (osEntropyBytes 16) 0

nonceBytes : Array Int -> Int -> String
nonceBytes bytes i =
  if i >= arrayLength bytes then
    ""
  else
    let byte = bytes[i]
    let padding = if byte < 10 then "00" else if byte < 100 then "0" else ""
    padding ++ intToString byte ++ nonceBytes bytes (i + 1)

-- Reserve the entire generated namespace, including aliases. Indexing all
-- occupied suffixes once avoids repeated source scans when many collide.
export
freshProbeNonce : String -> List String -> String -> String
freshProbeNonce nonce prefixes source =
  let (tokens, _) = tokenizeWithOffsetPairs source
  let occupied = occupiedNonceTokens nonce prefixes tokens omEmpty
  let index = freeNonceIndex occupied 0
  if index == 0 then nonce else "\{nonce}_\{intToString index}"

occupiedNonceTokens : String ->
  List String ->
  List Token ->
  OrdMap Unit ->
  OrdMap Unit
occupiedNonceTokens _ _ [] occupied = occupied
occupiedNonceTokens nonce prefixes ((TIdent name) :: rest) occupied =
  occupiedNonceTokens
    nonce
    prefixes
    rest
    (occupiedNonceName nonce prefixes name occupied)
occupiedNonceTokens nonce prefixes ((TUpper name) :: rest) occupied =
  occupiedNonceTokens
    nonce
    prefixes
    rest
    (occupiedNonceName nonce prefixes name occupied)
occupiedNonceTokens nonce prefixes (_ :: rest) occupied =
  occupiedNonceTokens nonce prefixes rest occupied

occupiedNonceName : String ->
  List String ->
  String ->
  OrdMap Unit ->
  OrdMap Unit
occupiedNonceName _ [] _ occupied = occupied
occupiedNonceName nonce (prefix :: rest) name occupied =
  let stem = prefix ++ nonce
  if startsWith stem name then
    let tail = stringSlice (stringLength stem) (stringLength name) name
    if tail == "" || startsWith "_" tail then
      let used = omInsert "0" () occupied
      let chars = stringToChars tail
      let end = nonceSuffixEnd chars 1
      let digits = if end > 20 then "" else stringSlice 1 end tail
      let next = match toInt digits
        Some index => omInsert (intToString index) () used
        None => used
      occupiedNonceName nonce rest name next
    else
      occupiedNonceName nonce rest name occupied
  else
    occupiedNonceName nonce rest name occupied

nonceSuffixEnd : Array Char -> Int -> Int
nonceSuffixEnd chars i =
  if i >= arrayLength chars || i > 20 then
    i
  else
    let char = chars[i]
    if char >= '0' && char <= '9' then nonceSuffixEnd chars (i + 1) else i

freeNonceIndex : OrdMap Unit -> Int -> Int
freeNonceIndex occupied index =
  if omHasKey (intToString index) occupied then
    freeNonceIndex occupied (index + 1)
  else
    index

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
valuePrintExpr expr = valuePrintExprWith "putStrLn" "debugStringLit" expr

export
valuePrintExprWith : String -> String -> String -> String
valuePrintExprWith printer encoder expr = "\{printer} (\{encoder} (\{expr}))"

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
--
-- The scan walks an `Array Char` taken once up front rather than indexing the
-- `String` per character: a codepoint index into a UTF-8 string resolves by
-- rescanning from byte 0, so a per-character `stringSlice i (i + 1) s` costs
-- O(n) each and the decode as a whole costs O(n²) — in a value whose length is
-- chosen by the program under test.
export
unquoteLit : String -> Option String
unquoteLit s =
  let cs = stringToChars s
  let n = arrayLength cs
  if n >= 2
    && arrayGetUnsafe 0 cs == '"'
    && arrayGetUnsafe (n - 1) cs == '"' then
    unquoteScan cs 1 (n - 1) []
  else
    None

unquoteScan : Array Char -> Int -> Int -> List Char -> Option String
unquoteScan cs i end acc
  | i >= end = Some (stringFromChars (arrayFromList (reverseL acc)))
  | arrayGetUnsafe i cs == '\\' =
    if i + 1 >= end then
      None
    else match unescapeChar (arrayGetUnsafe (i + 1) cs)
      Some c => unquoteScan cs (i + 2) end (c :: acc)
      None => None
  | otherwise = unquoteScan cs (i + 1) end (arrayGetUnsafe i cs :: acc)

unescapeChar : Char -> Option Char
unescapeChar 'n' = Some '\n'
unescapeChar 't' = Some '\t'
unescapeChar 'r' = Some '\r'
unescapeChar '0' = Some '\0'
unescapeChar '\\' = Some '\\'
unescapeChar '"' = Some '"'
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

-- What a target's own top-level `main` is renamed to inside a probe.  Nothing
-- in a probe references it, so dead-code elimination drops it.
export
userMainName : String
userMainName = "__probe_user_main__"

-- `src` with every top-level `main` definition head renamed to
-- `userMainName`; `src` itself when it defines no top-level `main`.
export
renameUserMain : String -> String
renameUserMain src =
  let (toks, spans) = tokenizeWithOffsetPairs src
  match mainHeadLines (lineStartsOf src) toks spans
    [] => src
    heads => joinNl (renameHeads 1 heads (splitNl src))

-- The 1-based lines, ascending, on which a `main` identifier token starts at
-- column 0.
mainHeadLines : Array Int -> List Token -> List (Int, Int) -> List Int
mainHeadLines starts ((TIdent "main") :: toks) ((off, _) :: spans) =
  match offsetToLineColFast starts off
    (line, 0) => line :: mainHeadLines starts toks spans
    _ => mainHeadLines starts toks spans
mainHeadLines starts (_ :: toks) (_ :: spans) = mainHeadLines starts toks spans
mainHeadLines _ _ _ = []

renameHeads : Int -> List Int -> List String -> List String
renameHeads _ [] lines = lines
renameHeads _ _ [] = []
renameHeads n (h :: hs) (l :: ls)
  | n == h =
    userMainName ++ stringSlice 4 (stringLength l) l
      :: renameHeads (n + 1) hs ls
  | otherwise = l :: renameHeads (n + 1) (h :: hs) ls
# DESUGAR
(DUse false (UseGroup ("frontend" "lexer") ((mem "Token" true) (mem "tokenizeWithOffsetPairs" false) (mem "lineStartsOf" false) (mem "offsetToLineColFast" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "reverseL" false) (mem "splitNl" false) (mem "startsWith" false) (mem "stringTrim" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omInsert" false))))
(DUse false (UseGroup ("string") ((mem "toInt" false))))
(DTypeSig true "sentTagOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "sentTagOf" ((PVar "prefix") (PVar "line")) (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "line")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "prefix"))) (EApp (EVar "stringLength") (EVar "line"))) (EVar "line"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "sentinelLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "sentinelLine" ((PVar "prefix") (PVar "tag")) (EBinOp "++" (EVar "prefix") (EVar "tag")))
(DTypeSig true "noncedPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "noncedPrefix" ((PVar "base") (PVar "nonce")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "base"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "nonce"))) (ELit (LString "@@ "))))
(DTypeSig true "mintNonce" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "mintNonce" (PWild) (EApp (EApp (EVar "nonceBytes") (EApp (EVar "osEntropyBytes") (ELit (LInt 16)))) (ELit (LInt 0))))
(DTypeSig false "nonceBytes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "nonceBytes" ((PVar "bytes") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (ELit (LString "")) (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EVar "index") (EVar "bytes")) (EVar "i"))) (DoLet false false (PVar "padding") (EIf (EBinOp "<" (EVar "byte") (ELit (LInt 10))) (ELit (LString "00")) (EIf (EBinOp "<" (EVar "byte") (ELit (LInt 100))) (ELit (LString "0")) (ELit (LString ""))))) (DoExpr (EBinOp "++" (EBinOp "++" (EVar "padding") (EApp (EVar "intToString") (EVar "byte"))) (EApp (EApp (EVar "nonceBytes") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))))
(DTypeSig true "freshProbeNonce" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "freshProbeNonce" ((PVar "nonce") (PVar "prefixes") (PVar "source")) (EBlock (DoLet false false (PTuple (PVar "tokens") PWild) (EApp (EVar "tokenizeWithOffsetPairs") (EVar "source"))) (DoLet false false (PVar "occupied") (EApp (EApp (EApp (EApp (EVar "occupiedNonceTokens") (EVar "nonce")) (EVar "prefixes")) (EVar "tokens")) (EVar "omEmpty"))) (DoLet false false (PVar "index") (EApp (EApp (EVar "freeNonceIndex") (EVar "occupied")) (ELit (LInt 0)))) (DoExpr (EIf (EBinOp "==" (EVar "index") (ELit (LInt 0))) (EVar "nonce") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "nonce"))) (ELit (LString "_"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "index")))) (ELit (LString "")))))))
(DTypeSig false "occupiedNonceTokens" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "occupiedNonceTokens" (PWild PWild (PList) (PVar "occupied")) (EVar "occupied"))
(DFunDef false "occupiedNonceTokens" ((PVar "nonce") (PVar "prefixes") (PCons (PCon "TIdent" (PVar "name")) (PVar "rest")) (PVar "occupied")) (EApp (EApp (EApp (EApp (EVar "occupiedNonceTokens") (EVar "nonce")) (EVar "prefixes")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "occupiedNonceName") (EVar "nonce")) (EVar "prefixes")) (EVar "name")) (EVar "occupied"))))
(DFunDef false "occupiedNonceTokens" ((PVar "nonce") (PVar "prefixes") (PCons (PCon "TUpper" (PVar "name")) (PVar "rest")) (PVar "occupied")) (EApp (EApp (EApp (EApp (EVar "occupiedNonceTokens") (EVar "nonce")) (EVar "prefixes")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "occupiedNonceName") (EVar "nonce")) (EVar "prefixes")) (EVar "name")) (EVar "occupied"))))
(DFunDef false "occupiedNonceTokens" ((PVar "nonce") (PVar "prefixes") (PCons PWild (PVar "rest")) (PVar "occupied")) (EApp (EApp (EApp (EApp (EVar "occupiedNonceTokens") (EVar "nonce")) (EVar "prefixes")) (EVar "rest")) (EVar "occupied")))
(DTypeSig false "occupiedNonceName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "occupiedNonceName" (PWild (PList) PWild (PVar "occupied")) (EVar "occupied"))
(DFunDef false "occupiedNonceName" ((PVar "nonce") (PCons (PVar "prefix") (PVar "rest")) (PVar "name") (PVar "occupied")) (EBlock (DoLet false false (PVar "stem") (EBinOp "++" (EVar "prefix") (EVar "nonce"))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (EVar "stem")) (EVar "name")) (EBlock (DoLet false false (PVar "tail") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "stem"))) (EApp (EVar "stringLength") (EVar "name"))) (EVar "name"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "tail") (ELit (LString ""))) (EApp (EApp (EVar "startsWith") (ELit (LString "_"))) (EVar "tail"))) (EBlock (DoLet false false (PVar "used") (EApp (EApp (EApp (EVar "omInsert") (ELit (LString "0"))) (ELit LUnit)) (EVar "occupied"))) (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "tail"))) (DoLet false false (PVar "end") (EApp (EApp (EVar "nonceSuffixEnd") (EVar "chars")) (ELit (LInt 1)))) (DoLet false false (PVar "digits") (EIf (EBinOp ">" (EVar "end") (ELit (LInt 20))) (ELit (LString "")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EVar "end")) (EVar "tail")))) (DoLet false false (PVar "next") (EMatch (EApp (EVar "toInt") (EVar "digits")) (arm (PCon "Some" (PVar "index")) () (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "intToString") (EVar "index"))) (ELit LUnit)) (EVar "used"))) (arm (PCon "None") () (EVar "used")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "occupiedNonceName") (EVar "nonce")) (EVar "rest")) (EVar "name")) (EVar "next")))) (EApp (EApp (EApp (EApp (EVar "occupiedNonceName") (EVar "nonce")) (EVar "rest")) (EVar "name")) (EVar "occupied"))))) (EApp (EApp (EApp (EApp (EVar "occupiedNonceName") (EVar "nonce")) (EVar "rest")) (EVar "name")) (EVar "occupied"))))))
(DTypeSig false "nonceSuffixEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "nonceSuffixEnd" ((PVar "chars") (PVar "i")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "chars"))) (EBinOp ">" (EVar "i") (ELit (LInt 20)))) (EVar "i") (EBlock (DoLet false false (PVar "char") (EApp (EApp (EVar "index") (EVar "chars")) (EVar "i"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "char") (ELit (LChar "0"))) (EBinOp "<=" (EVar "char") (ELit (LChar "9")))) (EApp (EApp (EVar "nonceSuffixEnd") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "i"))))))
(DTypeSig false "freeNonceIndex" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "freeNonceIndex" ((PVar "occupied") (PVar "index")) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EVar "intToString") (EVar "index"))) (EVar "occupied")) (EApp (EApp (EVar "freeNonceIndex") (EVar "occupied")) (EBinOp "+" (EVar "index") (ELit (LInt 1)))) (EVar "index")))
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
(DFunDef false "valuePrintExpr" ((PVar "expr")) (EApp (EApp (EApp (EVar "valuePrintExprWith") (ELit (LString "putStrLn"))) (ELit (LString "debugStringLit"))) (EVar "expr")))
(DTypeSig true "valuePrintExprWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "valuePrintExprWith" ((PVar "printer") (PVar "encoder") (PVar "expr")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "printer"))) (ELit (LString " ("))) (EApp (EVar "display") (EVar "encoder"))) (ELit (LString " ("))) (EApp (EVar "display") (EVar "expr"))) (ELit (LString "))"))))
(DTypeSig true "decodeValue" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "decodeValue" ((PList)) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "decodeValue" ((PCons (PVar "l") (PList))) (EApp (EVar "unquoteLit") (EVar "l")))
(DFunDef false "decodeValue" (PWild) (EVar "None"))
(DTypeSig true "unquoteLit" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "unquoteLit" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs")) (ELit (LChar "\"")))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "cs")) (ELit (LChar "\"")))) (EApp (EApp (EApp (EApp (EVar "unquoteScan") (EVar "cs")) (ELit (LInt 1))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EListLit)) (EVar "None")))))
(DTypeSig false "unquoteScan" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "unquoteScan" ((PVar "cs") (PVar "i") (PVar "end") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "end")) (EApp (EVar "Some") (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EVar "reverseL") (EVar "acc"))))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "\\"))) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "end")) (EVar "None") (EMatch (EApp (EVar "unescapeChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "cs"))) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EVar "unquoteScan") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "end")) (EBinOp "::" (EVar "c") (EVar "acc")))) (arm (PCon "None") () (EVar "None")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "unquoteScan") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "end")) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "unescapeChar" (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "Char"))))
(DFunDef false "unescapeChar" ((PLit (LChar "n"))) (EApp (EVar "Some") (ELit (LChar "\n"))))
(DFunDef false "unescapeChar" ((PLit (LChar "t"))) (EApp (EVar "Some") (ELit (LChar "\t"))))
(DFunDef false "unescapeChar" ((PLit (LChar "r"))) (EApp (EVar "Some") (ELit (LChar "\r"))))
(DFunDef false "unescapeChar" ((PLit (LChar "0"))) (EApp (EVar "Some") (ELit (LChar "\0"))))
(DFunDef false "unescapeChar" ((PLit (LChar "\\"))) (EApp (EVar "Some") (ELit (LChar "\\"))))
(DFunDef false "unescapeChar" ((PLit (LChar "\""))) (EApp (EVar "Some") (ELit (LChar "\""))))
(DFunDef false "unescapeChar" (PWild) (EVar "None"))
(DTypeSig true "lookupChunk" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyApp (TyCon "Option") (TyCon "Chunk")))))
(DFunDef false "lookupChunk" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupChunk" ((PVar "tag") (PCons (PCon "Chunk" (PVar "t") (PVar "ls") (PVar "done")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "t") (EVar "tag")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "Chunk") (EVar "t")) (EVar "ls")) (EVar "done"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupChunk") (EVar "tag")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "firstNonEmptyLine" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "firstNonEmptyLine" ((PList)) (ELit (LString "")))
(DFunDef false "firstNonEmptyLine" ((PCons (PVar "l") (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "stringTrim") (EVar "l")) (ELit (LString ""))) (EApp (EVar "firstNonEmptyLine") (EVar "rest")) (EIf (EVar "otherwise") (EApp (EVar "stringTrim") (EVar "l")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "userMainName" (TyCon "String"))
(DFunDef false "userMainName" () (ELit (LString "__probe_user_main__")))
(DTypeSig true "renameUserMain" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "renameUserMain" ((PVar "src")) (EBlock (DoLet false false (PTuple (PVar "toks") (PVar "spans")) (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "mainHeadLines") (EApp (EVar "lineStartsOf") (EVar "src"))) (EVar "toks")) (EVar "spans")) (arm (PList) () (EVar "src")) (arm (PVar "heads") () (EApp (EVar "joinNl") (EApp (EApp (EApp (EVar "renameHeads") (ELit (LInt 1))) (EVar "heads")) (EApp (EVar "splitNl") (EVar "src")))))))))
(DTypeSig false "mainHeadLines" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "mainHeadLines" ((PVar "starts") (PCons (PCon "TIdent" (PLit (LString "main"))) (PVar "toks")) (PCons (PTuple (PVar "off") PWild) (PVar "spans"))) (EMatch (EApp (EApp (EVar "offsetToLineColFast") (EVar "starts")) (EVar "off")) (arm (PTuple (PVar "line") (PLit (LInt 0))) () (EBinOp "::" (EVar "line") (EApp (EApp (EApp (EVar "mainHeadLines") (EVar "starts")) (EVar "toks")) (EVar "spans")))) (arm PWild () (EApp (EApp (EApp (EVar "mainHeadLines") (EVar "starts")) (EVar "toks")) (EVar "spans")))))
(DFunDef false "mainHeadLines" ((PVar "starts") (PCons PWild (PVar "toks")) (PCons PWild (PVar "spans"))) (EApp (EApp (EApp (EVar "mainHeadLines") (EVar "starts")) (EVar "toks")) (EVar "spans")))
(DFunDef false "mainHeadLines" (PWild PWild PWild) (EListLit))
(DTypeSig false "renameHeads" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "renameHeads" (PWild (PList) (PVar "lines")) (EVar "lines"))
(DFunDef false "renameHeads" (PWild PWild (PList)) (EListLit))
(DFunDef false "renameHeads" ((PVar "n") (PCons (PVar "h") (PVar "hs")) (PCons (PVar "l") (PVar "ls"))) (EIf (EBinOp "==" (EVar "n") (EVar "h")) (EBinOp "::" (EBinOp "++" (EVar "userMainName") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 4))) (EApp (EVar "stringLength") (EVar "l"))) (EVar "l"))) (EApp (EApp (EApp (EVar "renameHeads") (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EVar "hs")) (EVar "ls"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "l") (EApp (EApp (EApp (EVar "renameHeads") (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EBinOp "::" (EVar "h") (EVar "hs"))) (EVar "ls"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
# MARK
(DUse false (UseGroup ("frontend" "lexer") ((mem "Token" true) (mem "tokenizeWithOffsetPairs" false) (mem "lineStartsOf" false) (mem "offsetToLineColFast" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinNl" false) (mem "reverseL" false) (mem "splitNl" false) (mem "startsWith" false) (mem "stringTrim" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omHasKey" false) (mem "omInsert" false))))
(DUse false (UseGroup ("string") ((mem "toInt" false))))
(DTypeSig true "sentTagOf" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "sentTagOf" ((PVar "prefix") (PVar "line")) (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "line")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "prefix"))) (EApp (EVar "stringLength") (EVar "line"))) (EVar "line"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "sentinelLine" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "sentinelLine" ((PVar "prefix") (PVar "tag")) (EBinOp "++" (EVar "prefix") (EVar "tag")))
(DTypeSig true "noncedPrefix" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "noncedPrefix" ((PVar "base") (PVar "nonce")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "base"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "nonce"))) (ELit (LString "@@ "))))
(DTypeSig true "mintNonce" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "mintNonce" (PWild) (EApp (EApp (EVar "nonceBytes") (EApp (EVar "osEntropyBytes") (ELit (LInt 16)))) (ELit (LInt 0))))
(DTypeSig false "nonceBytes" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "nonceBytes" ((PVar "bytes") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "bytes"))) (ELit (LString "")) (EBlock (DoLet false false (PVar "byte") (EApp (EApp (EMethodRef "index") (EVar "bytes")) (EVar "i"))) (DoLet false false (PVar "padding") (EIf (EBinOp "<" (EVar "byte") (ELit (LInt 10))) (ELit (LString "00")) (EIf (EBinOp "<" (EVar "byte") (ELit (LInt 100))) (ELit (LString "0")) (ELit (LString ""))))) (DoExpr (EBinOp "++" (EBinOp "++" (EVar "padding") (EApp (EVar "intToString") (EVar "byte"))) (EApp (EApp (EVar "nonceBytes") (EVar "bytes")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))))))
(DTypeSig true "freshProbeNonce" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "freshProbeNonce" ((PVar "nonce") (PVar "prefixes") (PVar "source")) (EBlock (DoLet false false (PTuple (PVar "tokens") PWild) (EApp (EVar "tokenizeWithOffsetPairs") (EVar "source"))) (DoLet false false (PVar "occupied") (EApp (EApp (EApp (EApp (EVar "occupiedNonceTokens") (EVar "nonce")) (EVar "prefixes")) (EVar "tokens")) (EVar "omEmpty"))) (DoLet false false (PVar "index") (EApp (EApp (EVar "freeNonceIndex") (EVar "occupied")) (ELit (LInt 0)))) (DoExpr (EIf (EBinOp "==" (EMethodRef "index") (ELit (LInt 0))) (EVar "nonce") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "nonce"))) (ELit (LString "_"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EMethodRef "index")))) (ELit (LString "")))))))
(DTypeSig false "occupiedNonceTokens" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "occupiedNonceTokens" (PWild PWild (PList) (PVar "occupied")) (EVar "occupied"))
(DFunDef false "occupiedNonceTokens" ((PVar "nonce") (PVar "prefixes") (PCons (PCon "TIdent" (PVar "name")) (PVar "rest")) (PVar "occupied")) (EApp (EApp (EApp (EApp (EVar "occupiedNonceTokens") (EVar "nonce")) (EVar "prefixes")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "occupiedNonceName") (EVar "nonce")) (EVar "prefixes")) (EVar "name")) (EVar "occupied"))))
(DFunDef false "occupiedNonceTokens" ((PVar "nonce") (PVar "prefixes") (PCons (PCon "TUpper" (PVar "name")) (PVar "rest")) (PVar "occupied")) (EApp (EApp (EApp (EApp (EVar "occupiedNonceTokens") (EVar "nonce")) (EVar "prefixes")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "occupiedNonceName") (EVar "nonce")) (EVar "prefixes")) (EVar "name")) (EVar "occupied"))))
(DFunDef false "occupiedNonceTokens" ((PVar "nonce") (PVar "prefixes") (PCons PWild (PVar "rest")) (PVar "occupied")) (EApp (EApp (EApp (EApp (EVar "occupiedNonceTokens") (EVar "nonce")) (EVar "prefixes")) (EVar "rest")) (EVar "occupied")))
(DTypeSig false "occupiedNonceName" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "occupiedNonceName" (PWild (PList) PWild (PVar "occupied")) (EVar "occupied"))
(DFunDef false "occupiedNonceName" ((PVar "nonce") (PCons (PVar "prefix") (PVar "rest")) (PVar "name") (PVar "occupied")) (EBlock (DoLet false false (PVar "stem") (EBinOp "++" (EVar "prefix") (EVar "nonce"))) (DoExpr (EIf (EApp (EApp (EVar "startsWith") (EVar "stem")) (EVar "name")) (EBlock (DoLet false false (PVar "tail") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "stem"))) (EApp (EVar "stringLength") (EVar "name"))) (EVar "name"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "tail") (ELit (LString ""))) (EApp (EApp (EVar "startsWith") (ELit (LString "_"))) (EVar "tail"))) (EBlock (DoLet false false (PVar "used") (EApp (EApp (EApp (EVar "omInsert") (ELit (LString "0"))) (ELit LUnit)) (EVar "occupied"))) (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "tail"))) (DoLet false false (PVar "end") (EApp (EApp (EVar "nonceSuffixEnd") (EVar "chars")) (ELit (LInt 1)))) (DoLet false false (PVar "digits") (EIf (EBinOp ">" (EVar "end") (ELit (LInt 20))) (ELit (LString "")) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EVar "end")) (EVar "tail")))) (DoLet false false (PVar "next") (EMatch (EApp (EVar "toInt") (EVar "digits")) (arm (PCon "Some" (PVar "index")) () (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "intToString") (EMethodRef "index"))) (ELit LUnit)) (EVar "used"))) (arm (PCon "None") () (EVar "used")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "occupiedNonceName") (EVar "nonce")) (EVar "rest")) (EVar "name")) (EVar "next")))) (EApp (EApp (EApp (EApp (EVar "occupiedNonceName") (EVar "nonce")) (EVar "rest")) (EVar "name")) (EVar "occupied"))))) (EApp (EApp (EApp (EApp (EVar "occupiedNonceName") (EVar "nonce")) (EVar "rest")) (EVar "name")) (EVar "occupied"))))))
(DTypeSig false "nonceSuffixEnd" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "nonceSuffixEnd" ((PVar "chars") (PVar "i")) (EIf (EBinOp "||" (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "chars"))) (EBinOp ">" (EVar "i") (ELit (LInt 20)))) (EVar "i") (EBlock (DoLet false false (PVar "char") (EApp (EApp (EMethodRef "index") (EVar "chars")) (EVar "i"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "char") (ELit (LChar "0"))) (EBinOp "<=" (EVar "char") (ELit (LChar "9")))) (EApp (EApp (EVar "nonceSuffixEnd") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "i"))))))
(DTypeSig false "freeNonceIndex" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "freeNonceIndex" ((PVar "occupied") (PVar "index")) (EIf (EApp (EApp (EVar "omHasKey") (EApp (EVar "intToString") (EMethodRef "index"))) (EVar "occupied")) (EApp (EApp (EVar "freeNonceIndex") (EVar "occupied")) (EBinOp "+" (EMethodRef "index") (ELit (LInt 1)))) (EMethodRef "index")))
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
(DFunDef false "valuePrintExpr" ((PVar "expr")) (EApp (EApp (EApp (EVar "valuePrintExprWith") (ELit (LString "putStrLn"))) (ELit (LString "debugStringLit"))) (EVar "expr")))
(DTypeSig true "valuePrintExprWith" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "valuePrintExprWith" ((PVar "printer") (PVar "encoder") (PVar "expr")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "printer"))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EVar "encoder"))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EVar "expr"))) (ELit (LString "))"))))
(DTypeSig true "decodeValue" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "decodeValue" ((PList)) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "decodeValue" ((PCons (PVar "l") (PList))) (EApp (EVar "unquoteLit") (EVar "l")))
(DFunDef false "decodeValue" (PWild) (EVar "None"))
(DTypeSig true "unquoteLit" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "unquoteLit" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "stringToChars") (EVar "s"))) (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "cs"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs")) (ELit (LChar "\"")))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "cs")) (ELit (LChar "\"")))) (EApp (EApp (EApp (EApp (EVar "unquoteScan") (EVar "cs")) (ELit (LInt 1))) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EListLit)) (EVar "None")))))
(DTypeSig false "unquoteScan" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Char")) (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "unquoteScan" ((PVar "cs") (PVar "i") (PVar "end") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EVar "end")) (EApp (EVar "Some") (EApp (EVar "stringFromChars") (EApp (EVar "arrayFromList") (EApp (EVar "reverseL") (EVar "acc"))))) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "\\"))) (EIf (EBinOp ">=" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EVar "end")) (EVar "None") (EMatch (EApp (EVar "unescapeChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "cs"))) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EVar "unquoteScan") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "end")) (EBinOp "::" (EVar "c") (EVar "acc")))) (arm (PCon "None") () (EVar "None")))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "unquoteScan") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "end")) (EBinOp "::" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (EVar "acc"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "unescapeChar" (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "Char"))))
(DFunDef false "unescapeChar" ((PLit (LChar "n"))) (EApp (EVar "Some") (ELit (LChar "\n"))))
(DFunDef false "unescapeChar" ((PLit (LChar "t"))) (EApp (EVar "Some") (ELit (LChar "\t"))))
(DFunDef false "unescapeChar" ((PLit (LChar "r"))) (EApp (EVar "Some") (ELit (LChar "\r"))))
(DFunDef false "unescapeChar" ((PLit (LChar "0"))) (EApp (EVar "Some") (ELit (LChar "\0"))))
(DFunDef false "unescapeChar" ((PLit (LChar "\\"))) (EApp (EVar "Some") (ELit (LChar "\\"))))
(DFunDef false "unescapeChar" ((PLit (LChar "\""))) (EApp (EVar "Some") (ELit (LChar "\""))))
(DFunDef false "unescapeChar" (PWild) (EVar "None"))
(DTypeSig true "lookupChunk" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Chunk")) (TyApp (TyCon "Option") (TyCon "Chunk")))))
(DFunDef false "lookupChunk" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupChunk" ((PVar "tag") (PCons (PCon "Chunk" (PVar "t") (PVar "ls") (PVar "done")) (PVar "rest"))) (EIf (EBinOp "==" (EVar "t") (EVar "tag")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "Chunk") (EVar "t")) (EVar "ls")) (EVar "done"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "lookupChunk") (EVar "tag")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "firstNonEmptyLine" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "firstNonEmptyLine" ((PList)) (ELit (LString "")))
(DFunDef false "firstNonEmptyLine" ((PCons (PVar "l") (PVar "rest"))) (EIf (EBinOp "==" (EApp (EVar "stringTrim") (EVar "l")) (ELit (LString ""))) (EApp (EVar "firstNonEmptyLine") (EVar "rest")) (EIf (EVar "otherwise") (EApp (EVar "stringTrim") (EVar "l")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "userMainName" (TyCon "String"))
(DFunDef false "userMainName" () (ELit (LString "__probe_user_main__")))
(DTypeSig true "renameUserMain" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "renameUserMain" ((PVar "src")) (EBlock (DoLet false false (PTuple (PVar "toks") (PVar "spans")) (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "mainHeadLines") (EApp (EVar "lineStartsOf") (EVar "src"))) (EVar "toks")) (EVar "spans")) (arm (PList) () (EVar "src")) (arm (PVar "heads") () (EApp (EVar "joinNl") (EApp (EApp (EApp (EVar "renameHeads") (ELit (LInt 1))) (EVar "heads")) (EApp (EVar "splitNl") (EVar "src")))))))))
(DTypeSig false "mainHeadLines" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "mainHeadLines" ((PVar "starts") (PCons (PCon "TIdent" (PLit (LString "main"))) (PVar "toks")) (PCons (PTuple (PVar "off") PWild) (PVar "spans"))) (EMatch (EApp (EApp (EVar "offsetToLineColFast") (EVar "starts")) (EVar "off")) (arm (PTuple (PVar "line") (PLit (LInt 0))) () (EBinOp "::" (EVar "line") (EApp (EApp (EApp (EVar "mainHeadLines") (EVar "starts")) (EVar "toks")) (EVar "spans")))) (arm PWild () (EApp (EApp (EApp (EVar "mainHeadLines") (EVar "starts")) (EVar "toks")) (EVar "spans")))))
(DFunDef false "mainHeadLines" ((PVar "starts") (PCons PWild (PVar "toks")) (PCons PWild (PVar "spans"))) (EApp (EApp (EApp (EVar "mainHeadLines") (EVar "starts")) (EVar "toks")) (EVar "spans")))
(DFunDef false "mainHeadLines" (PWild PWild PWild) (EListLit))
(DTypeSig false "renameHeads" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "renameHeads" (PWild (PList) (PVar "lines")) (EVar "lines"))
(DFunDef false "renameHeads" (PWild PWild (PList)) (EListLit))
(DFunDef false "renameHeads" ((PVar "n") (PCons (PVar "h") (PVar "hs")) (PCons (PVar "l") (PVar "ls"))) (EIf (EBinOp "==" (EVar "n") (EVar "h")) (EBinOp "::" (EBinOp "++" (EVar "userMainName") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 4))) (EApp (EVar "stringLength") (EVar "l"))) (EVar "l"))) (EApp (EApp (EApp (EVar "renameHeads") (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EVar "hs")) (EVar "ls"))) (EIf (EVar "otherwise") (EBinOp "::" (EVar "l") (EApp (EApp (EApp (EVar "renameHeads") (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (EBinOp "::" (EVar "h") (EVar "hs"))) (EVar "ls"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
