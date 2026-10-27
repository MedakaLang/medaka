# META
source_lines=555
stages=DESUGAR,MARK
# SOURCE
import array
import frontend.ast.{
  noBinderId,
  unminted,
  negateLiteral,
  DeriveRef(..),
  Lit(..),
  Ty(..),
  EffAtomTy(..),
  EffParamTy(..),
  effAtomAt,
  effectDeclUnstamped,
  KindAnn(..),
  Constraint(..),
  Pat(..),
  RecPatField(..),
  Guard(..),
  Arm(..),
  DoStmt(..),
  InterpPart(..),
  GuardArm(..),
  FieldAssign(..),
  Section(..),
  FunClause(..),
  LetBind(..),
  Expr(..),
  Loc(..),
  noDeclLoc,
  UseMember(..),
  UsePath(..),
  useMemberOrigin,
  useMemberAlias,
  qualifiedLocal,
  tyConUnresolved,
  tyConBuiltin,
  dDataUnresolved,
  externDataUnresolved,
  kindAnnSource,
  kindAuthorityUnstamped,
  dTypeAliasUnresolved,
  dNewtypeUnresolved,
  dInterfaceUnresolved,
  setDeclNameLoc,
  dImplUnresolved,
  constraintUnresolved,
  superUnresolved,
  requireUnresolved,
  PropParam(..),
  MethodDefault(..),
  IfaceMethod(..),
  Super(..),
  Require(..),
  ImplMethod(..),
  DataVis(..),
  Field(..),
  ConPayload(..),
  Variant(..),
  Decl(..),
  ExternDecl(..),
  ExternBind(..),
  Attr(..),
  Route(..),
}
import frontend.lex_token.{
  Token(..), isCommaTok, isNoiseTok, isColonTok, isConsTok, isDedentTok,
  isDeferTok, isEofTok, isEqualTok, isExportTok, isImplTok, isInTok,
  isIndentTok, isLBraceTok, isLetTok, isNewlineTok, isOfTok, isPipeTok,
  isPublicTok, isRBraceTok, isRequiresTok, isStarTok, isWhereTok, isLayoutTok,
  isOpenDelim, isCloseDelim, isTStringTok, isTUpperTok
}
import support.source_index.{lineStartIndex, offsetToLineColFast}
import support.util.{reverseL, joinWith}
import list.{last}
import support.char.{isUpper}

public export data DeclPos = DeclPos Int Int (Option Loc) (List (Option Loc))
public export data Positions =
  Positions (List DeclPos) (List Int) Int (List (List Int))

export
positionsDecls : Positions -> List DeclPos
positionsDecls (Positions ds _ _ _) = ds

export
positionsVariantLines : Positions -> List Int
positionsVariantLines (Positions _ vs _ _) = vs

export
positionsLastContentLine : Positions -> Int
positionsLastContentLine (Positions _ _ l _) = l

export
positionsChainLines : Positions -> List (List Int)
positionsChainLines (Positions _ _ _ cl) = cl

export
declPosLine : DeclPos -> Int
declPosLine (DeclPos l _ _ _) = l

export
declPosEndLine : DeclPos -> Int
declPosEndLine (DeclPos _ e _ _) = e
export
declPosNameLoc : DeclPos -> Option Loc
declPosNameLoc (DeclPos _ _ nl _) = nl
export
declPosChildLocs : DeclPos -> List (Option Loc)
declPosChildLocs (DeclPos _ _ _ cs) = cs

lastContentIdx : Array Token -> Int -> Int -> Int
lastContentIdx toks s i
  | i < s = s
  | isNoiseTok (arrayGetUnsafe i toks) = lastContentIdx toks s (i - 1)
  | otherwise = i
lineAt : Array Int -> Int -> Int
lineAt lines i
  | i < arrayLength lines = arrayGetUnsafe i lines
  | otherwise = 0
export
locOfSpanWith : Array (Int, Int) -> Array Int -> Int -> Int -> Loc
locOfSpanWith offs lineStarts startIdx endIdx =
  let lastIdx = if endIdx > startIdx then endIdx - 1 else startIdx
  let startOff = tokOffsetAtArr offs startIdx
  let endOff = tokEndOffsetAtArr offs lastIdx
  let si = lineStartIndex lineStarts startOff
  let ei = lineStartIndex lineStarts endOff
  Loc
    ""
    (si + 1)
    (startOff - arrayGetUnsafe si lineStarts)
    (ei + 1)
    (endOff - arrayGetUnsafe ei lineStarts)
tokOffsetAtArr : Array (Int, Int) -> Int -> Int
tokOffsetAtArr offs i =
  if i >= 0 && i < arrayLength offs then fst (arrayGetUnsafe i offs) else 0

tokEndOffsetAtArr : Array (Int, Int) -> Int -> Int
tokEndOffsetAtArr offs i =
  if i >= 0 && i < arrayLength offs then snd (arrayGetUnsafe i offs) else 0
isLeadingModifierTok : Token -> Bool
isLeadingModifierTok TPublic = True
isLeadingModifierTok TExport = True
isLeadingModifierTok TDefault = True
isLeadingModifierTok t = isNoiseTok t
skipLeadingModifiers : Array Token -> Int -> Int
skipLeadingModifiers toks i
  | i < arrayLength toks && isLeadingModifierTok (arrayGetUnsafe i toks) =
    skipLeadingModifiers toks (i + 1)
  | otherwise = i

tokIdxOrNone : Array Token -> Int -> Option Int
tokIdxOrNone toks i = if i >= 0 && i < arrayLength toks then Some i else None
implHeadTokIdx : Array Token -> Int -> Option Int
implHeadTokIdx toks i = implHeadTokGo toks i 0

implHeadTokGo : Array Token -> Int -> Int -> Option Int
implHeadTokGo toks i depth
  | i >= arrayLength toks = None
  | otherwise = implHeadTokStep toks i depth (arrayGetUnsafe i toks)

implHeadTokStep : Array Token -> Int -> Int -> Token -> Option Int
implHeadTokStep toks i depth t
  | isOpenDelim t = implHeadTokGo toks (i + 1) (depth + 1)
  | isCloseDelim t = implHeadTokGo toks (i + 1) (depth - 1)
  | isTUpperTok t = Some i
  | depth == 0 && (isWhereTok t || isRequiresTok t || isNoiseTok t) = None
  | otherwise = implHeadTokGo toks (i + 1) depth
declNameTokIdxAt : Array Token -> Decl -> Int -> Option Int
declNameTokIdxAt toks (DAttrib _ inner) i =
  let i1 = i + 1  -- '@'
  let i2 = i1 + 1  -- attribute name ident
  let i3 =
    if i2 < arrayLength toks && isTStringTok (arrayGetUnsafe i2 toks) then
      i2 + 1
    else
      i2
  declNameTokIdx toks inner i3
declNameTokIdxAt toks (DTypeSig _ _ _ _) i = tokIdxOrNone toks i
declNameTokIdxAt toks (DFunDef _ _ _ _ _ _) i = tokIdxOrNone toks i
declNameTokIdxAt toks (DExtern _) i =
  tokIdxOrNone toks (skipLeadingModifiers toks (i + 1))
declNameTokIdxAt toks (DData { dataOrigin = _ }) i =
  tokIdxOrNone toks (skipLeadingModifiers toks (i + 1))
declNameTokIdxAt toks (DEffect _ _ _ _ _ _) i =
  tokIdxOrNone toks (skipLeadingModifiers toks (i + 1))
declNameTokIdxAt toks (DProp _ _ _ _) i =
  tokIdxOrNone toks (skipLeadingModifiers toks (i + 1))
declNameTokIdxAt toks (DTest _ _ _) i =
  tokIdxOrNone toks (skipLeadingModifiers toks (i + 1))
declNameTokIdxAt toks (DInterface { ... }) i =
  tokIdxOrNone toks (skipLeadingModifiers toks (i + 1))
declNameTokIdxAt toks (DTypeAlias { tyAliasOrigin = _ }) i =
  tokIdxOrNone toks (skipLeadingModifiers toks (i + 1))
declNameTokIdxAt toks (DNewtype { newtypeOrigin = _ }) i =
  tokIdxOrNone toks (skipLeadingModifiers toks (i + 1))
declNameTokIdxAt toks (DLetGroup _ _) i =
  tokIdxOrNone toks (skipLeadingModifiers toks (i + 2))  -- `let` `rec`
declNameTokIdxAt toks (DImpl { ... }) i = match implHeadTokIdx toks (i + 2)
  Some headIdx => Some headIdx
  None => Some i  -- fully-parametric head: fall back to the `impl` keyword
declNameTokIdxAt toks (DUse _ _ _) i = None
declNameTokIdx : Array Token -> Decl -> Int -> Option Int
declNameTokIdx toks d i = declNameTokIdxAt toks d (skipLeadingModifiers toks i)
declNameSpanOf : Array Token ->
  Array (Int, Int) ->
  Array Int ->
  (Decl, Int, Int) ->
  Option Loc
declNameSpanOf toks offs lineStarts (d, s, _e) =
  map
    (nameIdx => locOfSpanWith offs lineStarts nameIdx (nameIdx + 1))
    (declNameTokIdx toks d s)
innerDeclOf : Decl -> Decl
innerDeclOf (DAttrib _ d) = innerDeclOf d
innerDeclOf d = d
declChildNameIdxs : Array Token -> (Decl, Int, Int) -> List (Option Int)
declChildNameIdxs toks (d, s, e) = match innerDeclOf d
  DData { dataCtors = variants } => dataChildIdxs toks s e variants
  DInterface { ... } => methodNameIdxs toks s e
  DImpl { ... } => methodNameIdxs toks s e
  DLetGroup _ _ => [declNameTokIdx toks d s]
  _ => []
variantBoundaryIdxs : Array Token -> Int -> Int -> List Int
variantBoundaryIdxs toks s e = variantBoundaryGo toks s e 0 False

variantBoundaryGo : Array Token -> Int -> Int -> Int -> Bool -> List Int
variantBoundaryGo toks i e depth seenEq
  | i >= e = []
  | otherwise = variantBoundaryAt toks i e depth seenEq (arrayGetUnsafe i toks)

variantBoundaryAt : Array Token ->
  Int ->
  Int ->
  Int ->
  Bool ->
  Token ->
  List Int
variantBoundaryAt toks i e depth seenEq t
  | isOpenDelim t = variantBoundaryGo toks (i + 1) e (depth + 1) seenEq
  | isCloseDelim t = variantBoundaryGo toks (i + 1) e (depth - 1) seenEq
  | depth == 0 && not seenEq && isEqualTok t && nextSigIsPipe toks e (i + 1) =
    variantBoundaryGo toks (i + 1) e depth True
  | depth == 0 && not seenEq && isEqualTok t =
    firstContentAt toks (i + 1) e :: variantBoundaryGo toks (i + 1) e depth True
  | depth == 0 && seenEq && isPipeTok t =
    firstContentAt toks (i + 1) e
      :: variantBoundaryGo toks (i + 1) e depth seenEq
  | otherwise = variantBoundaryGo toks (i + 1) e depth seenEq
dataChildIdxs : Array Token -> Int -> Int -> List Variant -> List (Option Int)
dataChildIdxs toks s e variants =
  zipVariantIdxs toks e variants (variantBoundaryIdxs toks s e)

zipVariantIdxs : Array Token ->
  Int ->
  List Variant ->
  List Int ->
  List (Option Int)
zipVariantIdxs _ _ [] _ = []
zipVariantIdxs toks e ((Variant _ (ConNamed fs True)) :: vs) (b :: bs) =
  zipFieldIdxs fs (fieldNameIdxsIn toks (b + 1) e)
    ++ zipVariantIdxs toks e vs bs
zipVariantIdxs toks e ((Variant _ _) :: vs) (b :: bs) =
  Some b :: zipVariantIdxs toks e vs bs
zipVariantIdxs toks e (v :: vs) [] =
  variantNoneIdxs v ++ zipVariantIdxs toks e vs []
variantNoneIdxs : Variant -> List (Option Int)
variantNoneIdxs (Variant _ (ConNamed fs True)) = map (_ => None) fs
variantNoneIdxs (Variant _ _) = [None]
fieldNameIdxsIn : Array Token -> Int -> Int -> List Int
fieldNameIdxsIn toks i e = fieldNameGo toks i e 1 True

fieldNameGo : Array Token -> Int -> Int -> Int -> Bool -> List Int
fieldNameGo toks i e depth atStart
  | i >= e = []
  | depth <= 0 = []
  | otherwise = fieldNameStep toks i e depth atStart (arrayGetUnsafe i toks)

fieldNameStep : Array Token -> Int -> Int -> Int -> Bool -> Token -> List Int
fieldNameStep toks i e depth atStart t
  | isOpenDelim t = fieldNameGo toks (i + 1) e (depth + 1) False
  | isCloseDelim t = fieldNameGo toks (i + 1) e (depth - 1) False
  | depth == 1 && isCommaTok t = fieldNameGo toks (i + 1) e depth True
  | isNoiseTok t = fieldNameGo toks (i + 1) e depth atStart
  | atStart && depth == 1 = i :: fieldNameGo toks (i + 1) e depth False
  | otherwise = fieldNameGo toks (i + 1) e depth False
zipFieldIdxs : List Field -> List Int -> List (Option Int)
zipFieldIdxs [] _ = []
zipFieldIdxs (_ :: fs) (i :: is) = Some i :: zipFieldIdxs fs is
zipFieldIdxs (_ :: fs) [] = None :: zipFieldIdxs fs []
methodNameIdxs : Array Token -> Int -> Int -> List (Option Int)
methodNameIdxs toks s e = match findWhereIdx toks s e
  None => []
  Some w =>
    let after = skipNewlineToks toks (w + 1) e
    if after < e && isIndentTok (arrayGetUnsafe after toks) then
      methodNameGo toks (after + 1) e 1 True
    else
      []

findWhereIdx : Array Token -> Int -> Int -> Option Int
findWhereIdx toks i e
  | i >= e = None
  | isWhereTok (arrayGetUnsafe i toks) = Some i
  | otherwise = findWhereIdx toks (i + 1) e
skipNewlineToks : Array Token -> Int -> Int -> Int
skipNewlineToks toks i e
  | i < e && isNewlineTok (arrayGetUnsafe i toks) =
    skipNewlineToks toks (i + 1) e
  | otherwise = i

methodNameGo : Array Token -> Int -> Int -> Int -> Bool -> List (Option Int)
methodNameGo toks i e depth atStart
  | i >= e = []
  | depth <= 0 = []
  | otherwise = methodNameStep toks i e depth atStart (arrayGetUnsafe i toks)

methodNameStep : Array Token ->
  Int ->
  Int ->
  Int ->
  Bool ->
  Token ->
  List (Option Int)
methodNameStep toks i e depth _ TIndent =
  methodNameGo toks (i + 1) e (depth + 1) False
methodNameStep toks i e depth _ TDedent =
  methodNameGo toks (i + 1) e (depth - 1) False
methodNameStep toks i e depth _ TNewline =
  methodNameGo toks (i + 1) e depth (depth == 1)
methodNameStep toks i e depth atStart _
  | atStart && depth == 1 = Some i :: methodNameGo toks (i + 1) e depth False
  | otherwise = methodNameGo toks (i + 1) e depth False
declChildSpansOf : Array Token ->
  Array (Int, Int) ->
  Array Int ->
  (Decl, Int, Int) ->
  List (Option Loc)
declChildSpansOf toks offs lineStarts span =
  map
    (idxOpt => map (idx => locOfSpanWith offs lineStarts idx (idx + 1)) idxOpt)
    (declChildNameIdxs toks span)
declPosOf : Array Token ->
  Array Int ->
  Array (Int, Int) ->
  Array Int ->
  (Decl, Int, Int) ->
  DeclPos
declPosOf toks lines offs lineStarts (d, s, e) =
  DeclPos
    (lineAt lines s)
    (lineAt lines (lastContentIdx toks s (e - 1)))
    (declNameSpanOf toks offs lineStarts (d, s, e))
    (declChildSpansOf toks offs lineStarts (d, s, e))
variantStartsIn : Array Token -> Array Int -> Int -> Int -> List Int
variantStartsIn toks lines i e = variantStartsGo toks lines i e 0 False
variantStartsGo : Array Token ->
  Array Int ->
  Int ->
  Int ->
  Int ->
  Bool ->
  List Int
variantStartsGo toks lines i e depth seenEq
  | i >= e = []
  | otherwise =
    variantStartsAt toks lines i e depth seenEq (arrayGetUnsafe i toks)

variantStartsAt : Array Token ->
  Array Int ->
  Int ->
  Int ->
  Int ->
  Bool ->
  Token ->
  List Int
variantStartsAt toks lines i e depth seenEq t
  | isOpenDelim t = variantStartsGo toks lines (i + 1) e (depth + 1) seenEq
  | isCloseDelim t = variantStartsGo toks lines (i + 1) e (depth - 1) seenEq
  | depth == 0 && not seenEq && isEqualTok t && nextSigIsPipe toks e (i + 1) =
    variantStartsGo toks lines (i + 1) e depth True
  | depth == 0 && not seenEq && isEqualTok t =
    lineAt lines (i + 1) :: variantStartsGo toks lines (i + 1) e depth True
  | depth == 0 && seenEq && isPipeTok t =
    lineAt lines (i + 1) :: variantStartsGo toks lines (i + 1) e depth seenEq
  | otherwise = variantStartsGo toks lines (i + 1) e depth seenEq
nextSigIsPipe : Array Token -> Int -> Int -> Bool
nextSigIsPipe toks e j
  | j >= e = False
  | isLayoutTok (arrayGetUnsafe j toks) = nextSigIsPipe toks e (j + 1)
  | otherwise = isPipeTok (arrayGetUnsafe j toks)
isDataDecl : Decl -> Bool
isDataDecl (DData { dataOrigin = _ }) = True
isDataDecl _ = False
allVariantLines : Array Token -> Array Int -> List (Decl, Int, Int) -> List Int
allVariantLines toks lines [] = []
allVariantLines toks lines ((d, s, e) :: rest)
  | isDataDecl d =
    variantStartsIn toks lines s e ++ allVariantLines toks lines rest
  | otherwise = allVariantLines toks lines rest
isContinuationOpStr : String -> Bool
isContinuationOpStr op =
  op == "|>"
    || op == ">>"
    || op == "<<"
    || op == "&&"
    || op == "||"
    || op == "++"
chainOpTokEq : String -> Token -> Bool
chainOpTokEq "&&" TAnd = True
chainOpTokEq "||" TOr = True
chainOpTokEq "|>" TPipeRight = True
chainOpTokEq ">>" TRCompose = True
chainOpTokEq "<<" TLCompose = True
chainOpTokEq "++" TPlusPlus = True
chainOpTokEq _ _ = False
declChainTopOp : Decl -> Option String
declChainTopOp (DAttrib _ inner) = declChainTopOp inner
declChainTopOp (DFunDef _ _ _ body _ _) = bodyChainTopOp body
declChainTopOp _ = None

bodyChainTopOp : Expr -> Option String
bodyChainTopOp (ELoc _ e) = bodyChainTopOp e
bodyChainTopOp (EBinOp op _ _ _) =
  if isContinuationOpStr op then Some op else None
bodyChainTopOp _ = None
firstContentAt : Array Token -> Int -> Int -> Int
firstContentAt toks i e
  | i >= e = e
  | isNoiseTok (arrayGetUnsafe i toks) = firstContentAt toks (i + 1) e
  | otherwise = i
rhsStartIdx : Array Token -> Int -> Int -> Int -> Int
rhsStartIdx toks i e depth
  | i >= e = e
  | isOpenDelim (arrayGetUnsafe i toks) = rhsStartIdx toks (i + 1) e (depth + 1)
  | isCloseDelim (arrayGetUnsafe i toks) =
    rhsStartIdx toks (i + 1) e (depth - 1)
  | depth == 0 && isEqualTok (arrayGetUnsafe i toks) = i + 1
  | otherwise = rhsStartIdx toks (i + 1) e depth
chainOperandLines : Array Token -> Array Int -> String -> Int -> Int -> List Int
chainOperandLines toks lines op rs e =
  let h = firstContentAt toks rs e
  if h >= e then [] else lineAt lines h :: chainOpLinesGo toks lines op rs e 0

chainOpLinesGo : Array Token ->
  Array Int ->
  String ->
  Int ->
  Int ->
  Int ->
  List Int
chainOpLinesGo toks lines op i e depth
  | i >= e = []
  | otherwise = chainOpLinesAt toks lines op i e depth (arrayGetUnsafe i toks)

chainOpLinesAt : Array Token ->
  Array Int ->
  String ->
  Int ->
  Int ->
  Int ->
  Token ->
  List Int
chainOpLinesAt toks lines op i e depth t
  | isOpenDelim t = chainOpLinesGo toks lines op (i + 1) e (depth + 1)
  | isCloseDelim t = chainOpLinesGo toks lines op (i + 1) e (depth - 1)
  | depth == 0 && chainOpTokEq op t =
    lineAt lines (firstContentAt toks (i + 1) e)
      :: chainOpLinesGo toks lines op (i + 1) e depth
  | otherwise = chainOpLinesGo toks lines op (i + 1) e depth

declBlockRhs : Decl -> Bool
declBlockRhs (DAttrib _ inner) = declBlockRhs inner
declBlockRhs (DFunDef _ _ _ body _ _) = bodyIsBlock body
declBlockRhs _ = False

bodyIsBlock : Expr -> Bool
bodyIsBlock (ELoc _ e) = bodyIsBlock e
bodyIsBlock (EBlock _) = True
bodyIsBlock (EDo _ _) = True
bodyIsBlock _ = False
firstIndentIdx : Array Token -> Int -> Int -> Int
firstIndentIdx toks i e
  | i >= e = e
  | isIndentTok (arrayGetUnsafe i toks) = i + 1
  | otherwise = firstIndentIdx toks (i + 1) e

blockStmtLines : Array Token -> Array Int -> Int -> Int -> List Int
blockStmtLines toks lines rs e =
  let bi = firstIndentIdx toks rs e
  if bi >= e then [] else blockStmtGo toks lines bi e 1 True
blockStmtGo : Array Token -> Array Int -> Int -> Int -> Int -> Bool -> List Int
blockStmtGo toks lines i e ind atStart
  | i >= e = []
  | ind <= 0 = []
  | otherwise = blockStmtAt toks lines i e ind atStart (arrayGetUnsafe i toks)

blockStmtAt : Array Token ->
  Array Int ->
  Int ->
  Int ->
  Int ->
  Bool ->
  Token ->
  List Int
blockStmtAt toks lines i e ind atStart t
  | isIndentTok t = blockStmtGo toks lines (i + 1) e (ind + 1) False
  | isDedentTok t = blockStmtGo toks lines (i + 1) e (ind - 1) False
  | isNewlineTok t = blockStmtGo toks lines (i + 1) e ind (ind == 1)
  | atStart && ind == 1 =
    lineAt lines i :: blockStmtGo toks lines (i + 1) e ind False
  | otherwise = blockStmtGo toks lines (i + 1) e ind False
declChainLines : Array Token -> Array Int -> Decl -> Int -> Int -> List Int
declChainLines toks lines d s e = match declChainTopOp d
  Some op => chainOperandLines toks lines op (rhsStartIdx toks s e 0) e
  None =>
    if declBlockRhs d then
      blockStmtLines toks lines (rhsStartIdx toks s e 0) e
    else
      []
allChainLines : Array Token ->
  Array Int ->
  List (Decl, Int, Int) ->
  List (List Int)
allChainLines toks lines [] = []
allChainLines toks lines ((d, s, e) :: rest) =
  declChainLines toks lines d s e :: allChainLines toks lines rest
lastContentLineOf : Array Token -> Array Int -> List (Decl, Int, Int) -> Int
lastContentLineOf toks lines spans = lastContentLineGo toks lines spans 0

lastContentLineGo : Array Token ->
  Array Int ->
  List (Decl, Int, Int) ->
  Int ->
  Int
lastContentLineGo toks lines [] acc = acc
lastContentLineGo toks lines ((_, s, e) :: rest) acc =
  lastContentLineGo
    toks
    lines
    rest
    (lineAt lines (lastContentIdx toks s (e - 1)))

export
positionsFromSpans : Array Int ->
  Array Token ->
  Array (Int, Int) ->
  List (Decl, Int, Int) ->
  Positions
positionsFromSpans lineStarts toks offs spans =
  let lines = map (off => fst (offsetToLineColFast lineStarts (fst off))) offs
  Positions
    (map (declPosOf toks lines offs lineStarts) spans)
    (allVariantLines toks lines spans)
    (lastContentLineOf toks lines spans)
    (allChainLines toks lines spans)
# DESUGAR
(DUse false (UseName ("array")))
(DUse false (UseGroup ("frontend" "ast") ((mem "noBinderId" false) (mem "unminted" false) (mem "negateLiteral" false) (mem "DeriveRef" true) (mem "Lit" true) (mem "Ty" true) (mem "EffAtomTy" true) (mem "EffParamTy" true) (mem "effAtomAt" false) (mem "effectDeclUnstamped" false) (mem "KindAnn" true) (mem "Constraint" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "Loc" true) (mem "noDeclLoc" false) (mem "UseMember" true) (mem "UsePath" true) (mem "useMemberOrigin" false) (mem "useMemberAlias" false) (mem "qualifiedLocal" false) (mem "tyConUnresolved" false) (mem "tyConBuiltin" false) (mem "dDataUnresolved" false) (mem "externDataUnresolved" false) (mem "kindAnnSource" false) (mem "kindAuthorityUnstamped" false) (mem "dTypeAliasUnresolved" false) (mem "dNewtypeUnresolved" false) (mem "dInterfaceUnresolved" false) (mem "setDeclNameLoc" false) (mem "dImplUnresolved" false) (mem "constraintUnresolved" false) (mem "superUnresolved" false) (mem "requireUnresolved" false) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true) (mem "ExternDecl" true) (mem "ExternBind" true) (mem "Attr" true) (mem "Route" true))))
(DUse false (UseGroup ("frontend" "lex_token") ((mem "Token" true) (mem "isCommaTok" false) (mem "isNoiseTok" false) (mem "isColonTok" false) (mem "isConsTok" false) (mem "isDedentTok" false) (mem "isDeferTok" false) (mem "isEofTok" false) (mem "isEqualTok" false) (mem "isExportTok" false) (mem "isImplTok" false) (mem "isInTok" false) (mem "isIndentTok" false) (mem "isLBraceTok" false) (mem "isLetTok" false) (mem "isNewlineTok" false) (mem "isOfTok" false) (mem "isPipeTok" false) (mem "isPublicTok" false) (mem "isRBraceTok" false) (mem "isRequiresTok" false) (mem "isStarTok" false) (mem "isWhereTok" false) (mem "isLayoutTok" false) (mem "isOpenDelim" false) (mem "isCloseDelim" false) (mem "isTStringTok" false) (mem "isTUpperTok" false))))
(DUse false (UseGroup ("support" "source_index") ((mem "lineStartIndex" false) (mem "offsetToLineColFast" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "joinWith" false))))
(DUse false (UseGroup ("list") ((mem "last" false))))
(DUse false (UseGroup ("support" "char") ((mem "isUpper" false))))
(DData Public "DeclPos" () ((variant "DeclPos" (ConPos (TyCon "Int") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc")))))) ())
(DData Public "Positions" () ((variant "Positions" (ConPos (TyApp (TyCon "List") (TyCon "DeclPos")) (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DTypeSig true "positionsDecls" (TyFun (TyCon "Positions") (TyApp (TyCon "List") (TyCon "DeclPos"))))
(DFunDef false "positionsDecls" ((PCon "Positions" (PVar "ds") PWild PWild PWild)) (EVar "ds"))
(DTypeSig true "positionsVariantLines" (TyFun (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "positionsVariantLines" ((PCon "Positions" PWild (PVar "vs") PWild PWild)) (EVar "vs"))
(DTypeSig true "positionsLastContentLine" (TyFun (TyCon "Positions") (TyCon "Int")))
(DFunDef false "positionsLastContentLine" ((PCon "Positions" PWild PWild (PVar "l") PWild)) (EVar "l"))
(DTypeSig true "positionsChainLines" (TyFun (TyCon "Positions") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "positionsChainLines" ((PCon "Positions" PWild PWild PWild (PVar "cl"))) (EVar "cl"))
(DTypeSig true "declPosLine" (TyFun (TyCon "DeclPos") (TyCon "Int")))
(DFunDef false "declPosLine" ((PCon "DeclPos" (PVar "l") PWild PWild PWild)) (EVar "l"))
(DTypeSig true "declPosEndLine" (TyFun (TyCon "DeclPos") (TyCon "Int")))
(DFunDef false "declPosEndLine" ((PCon "DeclPos" PWild (PVar "e") PWild PWild)) (EVar "e"))
(DTypeSig true "declPosNameLoc" (TyFun (TyCon "DeclPos") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "declPosNameLoc" ((PCon "DeclPos" PWild PWild (PVar "nl") PWild)) (EVar "nl"))
(DTypeSig true "declPosChildLocs" (TyFun (TyCon "DeclPos") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "declPosChildLocs" ((PCon "DeclPos" PWild PWild PWild (PVar "cs"))) (EVar "cs"))
(DTypeSig false "lastContentIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "lastContentIdx" ((PVar "toks") (PVar "s") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (EVar "s")) (EVar "s") (EIf (EApp (EVar "isNoiseTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EApp (EApp (EVar "lastContentIdx") (EVar "toks")) (EVar "s")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "lineAt" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lineAt" ((PVar "lines") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "lines"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "lines")) (EIf (EVar "otherwise") (ELit (LInt 0)) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "locOfSpanWith" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Loc"))))))
(DFunDef false "locOfSpanWith" ((PVar "offs") (PVar "lineStarts") (PVar "startIdx") (PVar "endIdx")) (EBlock (DoLet false false (PVar "lastIdx") (EIf (EBinOp ">" (EVar "endIdx") (EVar "startIdx")) (EBinOp "-" (EVar "endIdx") (ELit (LInt 1))) (EVar "startIdx"))) (DoLet false false (PVar "startOff") (EApp (EApp (EVar "tokOffsetAtArr") (EVar "offs")) (EVar "startIdx"))) (DoLet false false (PVar "endOff") (EApp (EApp (EVar "tokEndOffsetAtArr") (EVar "offs")) (EVar "lastIdx"))) (DoLet false false (PVar "si") (EApp (EApp (EVar "lineStartIndex") (EVar "lineStarts")) (EVar "startOff"))) (DoLet false false (PVar "ei") (EApp (EApp (EVar "lineStartIndex") (EVar "lineStarts")) (EVar "endOff"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EBinOp "+" (EVar "si") (ELit (LInt 1)))) (EBinOp "-" (EVar "startOff") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "si")) (EVar "lineStarts")))) (EBinOp "+" (EVar "ei") (ELit (LInt 1)))) (EBinOp "-" (EVar "endOff") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "ei")) (EVar "lineStarts")))))))
(DTypeSig false "tokOffsetAtArr" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "tokOffsetAtArr" ((PVar "offs") (PVar "i")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "offs")))) (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "offs"))) (ELit (LInt 0))))
(DTypeSig false "tokEndOffsetAtArr" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "tokEndOffsetAtArr" ((PVar "offs") (PVar "i")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "offs")))) (EApp (EVar "snd") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "offs"))) (ELit (LInt 0))))
(DTypeSig false "isLeadingModifierTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isLeadingModifierTok" ((PCon "TPublic")) (EVar "True"))
(DFunDef false "isLeadingModifierTok" ((PCon "TExport")) (EVar "True"))
(DFunDef false "isLeadingModifierTok" ((PCon "TDefault")) (EVar "True"))
(DFunDef false "isLeadingModifierTok" ((PVar "t")) (EApp (EVar "isNoiseTok") (EVar "t")))
(DTypeSig false "skipLeadingModifiers" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "skipLeadingModifiers" ((PVar "toks") (PVar "i")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EApp (EVar "isLeadingModifierTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks")))) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tokIdxOrNone" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "tokIdxOrNone" ((PVar "toks") (PVar "i")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks")))) (EApp (EVar "Some") (EVar "i")) (EVar "None")))
(DTypeSig false "implHeadTokIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "implHeadTokIdx" ((PVar "toks") (PVar "i")) (EApp (EApp (EApp (EVar "implHeadTokGo") (EVar "toks")) (EVar "i")) (ELit (LInt 0))))
(DTypeSig false "implHeadTokGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "implHeadTokGo" ((PVar "toks") (PVar "i") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "implHeadTokStep") (EVar "toks")) (EVar "i")) (EVar "depth")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "implHeadTokStep" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "implHeadTokStep" ((PVar "toks") (PVar "i") (PVar "depth") (PVar "t")) (EIf (EApp (EVar "isOpenDelim") (EVar "t")) (EApp (EApp (EApp (EVar "implHeadTokGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EApp (EVar "isCloseDelim") (EVar "t")) (EApp (EApp (EApp (EVar "implHeadTokGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EApp (EVar "isTUpperTok") (EVar "t")) (EApp (EVar "Some") (EVar "i")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EBinOp "||" (EBinOp "||" (EApp (EVar "isWhereTok") (EVar "t")) (EApp (EVar "isRequiresTok") (EVar "t"))) (EApp (EVar "isNoiseTok") (EVar "t")))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "implHeadTokGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "declNameTokIdxAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DAttrib" PWild (PVar "inner")) (PVar "i")) (EBlock (DoLet false false (PVar "i1") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (DoLet false false (PVar "i2") (EBinOp "+" (EVar "i1") (ELit (LInt 1)))) (DoLet false false (PVar "i3") (EIf (EBinOp "&&" (EBinOp "<" (EVar "i2") (EApp (EVar "arrayLength") (EVar "toks"))) (EApp (EVar "isTStringTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i2")) (EVar "toks")))) (EBinOp "+" (EVar "i2") (ELit (LInt 1))) (EVar "i2"))) (DoExpr (EApp (EApp (EApp (EVar "declNameTokIdx") (EVar "toks")) (EVar "inner")) (EVar "i3")))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DTypeSig" PWild PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EVar "i")))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DFunDef" PWild PWild PWild PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EVar "i")))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DExtern" PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PRec "DData" ((rf "dataOrigin" PWild)) false) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DEffect" PWild PWild PWild PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DProp" PWild PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DTest" PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PRec "DInterface" () true) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PRec "DTypeAlias" ((rf "tyAliasOrigin" PWild)) false) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PRec "DNewtype" ((rf "newtypeOrigin" PWild)) false) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DLetGroup" PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 2))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PRec "DImpl" () true) (PVar "i")) (EMatch (EApp (EApp (EVar "implHeadTokIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (arm (PCon "Some" (PVar "headIdx")) () (EApp (EVar "Some") (EVar "headIdx"))) (arm (PCon "None") () (EApp (EVar "Some") (EVar "i")))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DUse" PWild PWild PWild) (PVar "i")) (EVar "None"))
(DTypeSig false "declNameTokIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "declNameTokIdx" ((PVar "toks") (PVar "d") (PVar "i")) (EApp (EApp (EApp (EVar "declNameTokIdxAt") (EVar "toks")) (EVar "d")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EVar "i"))))
(DTypeSig false "declNameSpanOf" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "declNameSpanOf" ((PVar "toks") (PVar "offs") (PVar "lineStarts") (PTuple (PVar "d") (PVar "s") (PVar "_e"))) (EApp (EApp (EVar "map") (ELam ((PVar "nameIdx")) (EApp (EApp (EApp (EApp (EVar "locOfSpanWith") (EVar "offs")) (EVar "lineStarts")) (EVar "nameIdx")) (EBinOp "+" (EVar "nameIdx") (ELit (LInt 1)))))) (EApp (EApp (EApp (EVar "declNameTokIdx") (EVar "toks")) (EVar "d")) (EVar "s"))))
(DTypeSig false "innerDeclOf" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "innerDeclOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "innerDeclOf") (EVar "d")))
(DFunDef false "innerDeclOf" ((PVar "d")) (EVar "d"))
(DTypeSig false "declChildNameIdxs" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "declChildNameIdxs" ((PVar "toks") (PTuple (PVar "d") (PVar "s") (PVar "e"))) (EMatch (EApp (EVar "innerDeclOf") (EVar "d")) (arm (PRec "DData" ((rf "dataCtors" (PVar "variants"))) false) () (EApp (EApp (EApp (EApp (EVar "dataChildIdxs") (EVar "toks")) (EVar "s")) (EVar "e")) (EVar "variants"))) (arm (PRec "DInterface" () true) () (EApp (EApp (EApp (EVar "methodNameIdxs") (EVar "toks")) (EVar "s")) (EVar "e"))) (arm (PRec "DImpl" () true) () (EApp (EApp (EApp (EVar "methodNameIdxs") (EVar "toks")) (EVar "s")) (EVar "e"))) (arm (PCon "DLetGroup" PWild PWild) () (EListLit (EApp (EApp (EApp (EVar "declNameTokIdx") (EVar "toks")) (EVar "d")) (EVar "s")))) (arm PWild () (EListLit))))
(DTypeSig false "variantBoundaryIdxs" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "variantBoundaryIdxs" ((PVar "toks") (PVar "s") (PVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EVar "s")) (EVar "e")) (ELit (LInt 0))) (EVar "False")))
(DTypeSig false "variantBoundaryGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "variantBoundaryGo" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "seenEq")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryAt") (EVar "toks")) (EVar "i")) (EVar "e")) (EVar "depth")) (EVar "seenEq")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "variantBoundaryAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "variantBoundaryAt" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "seenEq") (PVar "t")) (EIf (EApp (EVar "isOpenDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "seenEq")) (EIf (EApp (EVar "isCloseDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "seenEq")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "not") (EVar "seenEq"))) (EApp (EVar "isEqualTok") (EVar "t"))) (EApp (EApp (EApp (EVar "nextSigIsPipe") (EVar "toks")) (EVar "e")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "True")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "not") (EVar "seenEq"))) (EApp (EVar "isEqualTok") (EVar "t"))) (EBinOp "::" (EApp (EApp (EApp (EVar "firstContentAt") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "True"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EVar "seenEq")) (EApp (EVar "isPipeTok") (EVar "t"))) (EBinOp "::" (EApp (EApp (EApp (EVar "firstContentAt") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "seenEq"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "seenEq")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "dataChildIdxs" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "dataChildIdxs" ((PVar "toks") (PVar "s") (PVar "e") (PVar "variants")) (EApp (EApp (EApp (EApp (EVar "zipVariantIdxs") (EVar "toks")) (EVar "e")) (EVar "variants")) (EApp (EApp (EApp (EVar "variantBoundaryIdxs") (EVar "toks")) (EVar "s")) (EVar "e"))))
(DTypeSig false "zipVariantIdxs" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "zipVariantIdxs" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "zipVariantIdxs" ((PVar "toks") (PVar "e") (PCons (PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") (PCon "True"))) (PVar "vs")) (PCons (PVar "b") (PVar "bs"))) (EBinOp "++" (EApp (EApp (EVar "zipFieldIdxs") (EVar "fs")) (EApp (EApp (EApp (EVar "fieldNameIdxsIn") (EVar "toks")) (EBinOp "+" (EVar "b") (ELit (LInt 1)))) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "zipVariantIdxs") (EVar "toks")) (EVar "e")) (EVar "vs")) (EVar "bs"))))
(DFunDef false "zipVariantIdxs" ((PVar "toks") (PVar "e") (PCons (PCon "Variant" PWild PWild) (PVar "vs")) (PCons (PVar "b") (PVar "bs"))) (EBinOp "::" (EApp (EVar "Some") (EVar "b")) (EApp (EApp (EApp (EApp (EVar "zipVariantIdxs") (EVar "toks")) (EVar "e")) (EVar "vs")) (EVar "bs"))))
(DFunDef false "zipVariantIdxs" ((PVar "toks") (PVar "e") (PCons (PVar "v") (PVar "vs")) (PList)) (EBinOp "++" (EApp (EVar "variantNoneIdxs") (EVar "v")) (EApp (EApp (EApp (EApp (EVar "zipVariantIdxs") (EVar "toks")) (EVar "e")) (EVar "vs")) (EListLit))))
(DTypeSig false "variantNoneIdxs" (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "variantNoneIdxs" ((PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") (PCon "True")))) (EApp (EApp (EVar "map") (ELam (PWild) (EVar "None"))) (EVar "fs")))
(DFunDef false "variantNoneIdxs" ((PCon "Variant" PWild PWild)) (EListLit (EVar "None")))
(DTypeSig false "fieldNameIdxsIn" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "fieldNameIdxsIn" ((PVar "toks") (PVar "i") (PVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EVar "i")) (EVar "e")) (ELit (LInt 1))) (EVar "True")))
(DTypeSig false "fieldNameGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "fieldNameGo" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "atStart")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EBinOp "<=" (EVar "depth") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameStep") (EVar "toks")) (EVar "i")) (EVar "e")) (EVar "depth")) (EVar "atStart")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "fieldNameStep" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "fieldNameStep" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "atStart") (PVar "t")) (EIf (EApp (EVar "isOpenDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "False")) (EIf (EApp (EVar "isCloseDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "False")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 1))) (EApp (EVar "isCommaTok") (EVar "t"))) (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "True")) (EIf (EApp (EVar "isNoiseTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "atStart")) (EIf (EBinOp "&&" (EVar "atStart") (EBinOp "==" (EVar "depth") (ELit (LInt 1)))) (EBinOp "::" (EVar "i") (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "zipFieldIdxs" (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "zipFieldIdxs" ((PList) PWild) (EListLit))
(DFunDef false "zipFieldIdxs" ((PCons PWild (PVar "fs")) (PCons (PVar "i") (PVar "is"))) (EBinOp "::" (EApp (EVar "Some") (EVar "i")) (EApp (EApp (EVar "zipFieldIdxs") (EVar "fs")) (EVar "is"))))
(DFunDef false "zipFieldIdxs" ((PCons PWild (PVar "fs")) (PList)) (EBinOp "::" (EVar "None") (EApp (EApp (EVar "zipFieldIdxs") (EVar "fs")) (EListLit))))
(DTypeSig false "methodNameIdxs" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "methodNameIdxs" ((PVar "toks") (PVar "s") (PVar "e")) (EMatch (EApp (EApp (EApp (EVar "findWhereIdx") (EVar "toks")) (EVar "s")) (EVar "e")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "w")) () (EBlock (DoLet false false (PVar "after") (EApp (EApp (EApp (EVar "skipNewlineToks") (EVar "toks")) (EBinOp "+" (EVar "w") (ELit (LInt 1)))) (EVar "e"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EVar "after") (EVar "e")) (EApp (EVar "isIndentTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "after")) (EVar "toks")))) (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "after") (ELit (LInt 1)))) (EVar "e")) (ELit (LInt 1))) (EVar "True")) (EListLit)))))))
(DTypeSig false "findWhereIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "findWhereIdx" ((PVar "toks") (PVar "i") (PVar "e")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EVar "None") (EIf (EApp (EVar "isWhereTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "findWhereIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "skipNewlineToks" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "skipNewlineToks" ((PVar "toks") (PVar "i") (PVar "e")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "i") (EVar "e")) (EApp (EVar "isNewlineTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks")))) (EApp (EApp (EApp (EVar "skipNewlineToks") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "methodNameGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int")))))))))
(DFunDef false "methodNameGo" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "atStart")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EBinOp "<=" (EVar "depth") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "methodNameStep") (EVar "toks")) (EVar "i")) (EVar "e")) (EVar "depth")) (EVar "atStart")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "methodNameStep" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int"))))))))))
(DFunDef false "methodNameStep" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") PWild (PCon "TIndent")) (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "False")))
(DFunDef false "methodNameStep" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") PWild (PCon "TDedent")) (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "False")))
(DFunDef false "methodNameStep" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") PWild (PCon "TNewline")) (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EBinOp "==" (EVar "depth") (ELit (LInt 1)))))
(DFunDef false "methodNameStep" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "atStart") PWild) (EIf (EBinOp "&&" (EVar "atStart") (EBinOp "==" (EVar "depth") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "Some") (EVar "i")) (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declChildSpansOf" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))))))))
(DFunDef false "declChildSpansOf" ((PVar "toks") (PVar "offs") (PVar "lineStarts") (PVar "span")) (EApp (EApp (EVar "map") (ELam ((PVar "idxOpt")) (EApp (EApp (EVar "map") (ELam ((PVar "idx")) (EApp (EApp (EApp (EApp (EVar "locOfSpanWith") (EVar "offs")) (EVar "lineStarts")) (EVar "idx")) (EBinOp "+" (EVar "idx") (ELit (LInt 1)))))) (EVar "idxOpt")))) (EApp (EApp (EVar "declChildNameIdxs") (EVar "toks")) (EVar "span"))))
(DTypeSig false "declPosOf" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int")) (TyCon "DeclPos")))))))
(DFunDef false "declPosOf" ((PVar "toks") (PVar "lines") (PVar "offs") (PVar "lineStarts") (PTuple (PVar "d") (PVar "s") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "DeclPos") (EApp (EApp (EVar "lineAt") (EVar "lines")) (EVar "s"))) (EApp (EApp (EVar "lineAt") (EVar "lines")) (EApp (EApp (EApp (EVar "lastContentIdx") (EVar "toks")) (EVar "s")) (EBinOp "-" (EVar "e") (ELit (LInt 1)))))) (EApp (EApp (EApp (EApp (EVar "declNameSpanOf") (EVar "toks")) (EVar "offs")) (EVar "lineStarts")) (ETuple (EVar "d") (EVar "s") (EVar "e")))) (EApp (EApp (EApp (EApp (EVar "declChildSpansOf") (EVar "toks")) (EVar "offs")) (EVar "lineStarts")) (ETuple (EVar "d") (EVar "s") (EVar "e")))))
(DTypeSig false "variantStartsIn" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "variantStartsIn" ((PVar "toks") (PVar "lines") (PVar "i") (PVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EVar "i")) (EVar "e")) (ELit (LInt 0))) (EVar "False")))
(DTypeSig false "variantStartsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "variantStartsGo" ((PVar "toks") (PVar "lines") (PVar "i") (PVar "e") (PVar "depth") (PVar "seenEq")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsAt") (EVar "toks")) (EVar "lines")) (EVar "i")) (EVar "e")) (EVar "depth")) (EVar "seenEq")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "variantStartsAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyCon "Int"))))))))))
(DFunDef false "variantStartsAt" ((PVar "toks") (PVar "lines") (PVar "i") (PVar "e") (PVar "depth") (PVar "seenEq") (PVar "t")) (EIf (EApp (EVar "isOpenDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "seenEq")) (EIf (EApp (EVar "isCloseDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "seenEq")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "not") (EVar "seenEq"))) (EApp (EVar "isEqualTok") (EVar "t"))) (EApp (EApp (EApp (EVar "nextSigIsPipe") (EVar "toks")) (EVar "e")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "True")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "not") (EVar "seenEq"))) (EApp (EVar "isEqualTok") (EVar "t"))) (EBinOp "::" (EApp (EApp (EVar "lineAt") (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "True"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EVar "seenEq")) (EApp (EVar "isPipeTok") (EVar "t"))) (EBinOp "::" (EApp (EApp (EVar "lineAt") (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "seenEq"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "seenEq")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "nextSigIsPipe" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "nextSigIsPipe" ((PVar "toks") (PVar "e") (PVar "j")) (EIf (EBinOp ">=" (EVar "j") (EVar "e")) (EVar "False") (EIf (EApp (EVar "isLayoutTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "toks"))) (EApp (EApp (EApp (EVar "nextSigIsPipe") (EVar "toks")) (EVar "e")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EVar "isPipeTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isDataDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isDataDecl" ((PRec "DData" ((rf "dataOrigin" PWild)) false)) (EVar "True"))
(DFunDef false "isDataDecl" (PWild) (EVar "False"))
(DTypeSig false "allVariantLines" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "allVariantLines" ((PVar "toks") (PVar "lines") (PList)) (EListLit))
(DFunDef false "allVariantLines" ((PVar "toks") (PVar "lines") (PCons (PTuple (PVar "d") (PVar "s") (PVar "e")) (PVar "rest"))) (EIf (EApp (EVar "isDataDecl") (EVar "d")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "variantStartsIn") (EVar "toks")) (EVar "lines")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EVar "allVariantLines") (EVar "toks")) (EVar "lines")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "allVariantLines") (EVar "toks")) (EVar "lines")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isContinuationOpStr" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isContinuationOpStr" ((PVar "op")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "|>"))) (EBinOp "==" (EVar "op") (ELit (LString ">>")))) (EBinOp "==" (EVar "op") (ELit (LString "<<")))) (EBinOp "==" (EVar "op") (ELit (LString "&&")))) (EBinOp "==" (EVar "op") (ELit (LString "||")))) (EBinOp "==" (EVar "op") (ELit (LString "++")))))
(DTypeSig false "chainOpTokEq" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyCon "Bool"))))
(DFunDef false "chainOpTokEq" ((PLit (LString "&&")) (PCon "TAnd")) (EVar "True"))
(DFunDef false "chainOpTokEq" ((PLit (LString "||")) (PCon "TOr")) (EVar "True"))
(DFunDef false "chainOpTokEq" ((PLit (LString "|>")) (PCon "TPipeRight")) (EVar "True"))
(DFunDef false "chainOpTokEq" ((PLit (LString ">>")) (PCon "TRCompose")) (EVar "True"))
(DFunDef false "chainOpTokEq" ((PLit (LString "<<")) (PCon "TLCompose")) (EVar "True"))
(DFunDef false "chainOpTokEq" ((PLit (LString "++")) (PCon "TPlusPlus")) (EVar "True"))
(DFunDef false "chainOpTokEq" (PWild PWild) (EVar "False"))
(DTypeSig false "declChainTopOp" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "declChainTopOp" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "declChainTopOp") (EVar "inner")))
(DFunDef false "declChainTopOp" ((PCon "DFunDef" PWild PWild PWild (PVar "body") PWild PWild)) (EApp (EVar "bodyChainTopOp") (EVar "body")))
(DFunDef false "declChainTopOp" (PWild) (EVar "None"))
(DTypeSig false "bodyChainTopOp" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "bodyChainTopOp" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "bodyChainTopOp") (EVar "e")))
(DFunDef false "bodyChainTopOp" ((PCon "EBinOp" (PVar "op") PWild PWild PWild)) (EIf (EApp (EVar "isContinuationOpStr") (EVar "op")) (EApp (EVar "Some") (EVar "op")) (EVar "None")))
(DFunDef false "bodyChainTopOp" (PWild) (EVar "None"))
(DTypeSig false "firstContentAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "firstContentAt" ((PVar "toks") (PVar "i") (PVar "e")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EVar "e") (EIf (EApp (EVar "isNoiseTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EApp (EApp (EVar "firstContentAt") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "rhsStartIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "rhsStartIdx" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EVar "e") (EIf (EApp (EVar "isOpenDelim") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EApp (EApp (EApp (EVar "rhsStartIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EApp (EVar "isCloseDelim") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EApp (EApp (EApp (EVar "rhsStartIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "isEqualTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks")))) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "rhsStartIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "chainOperandLines" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "chainOperandLines" ((PVar "toks") (PVar "lines") (PVar "op") (PVar "rs") (PVar "e")) (EBlock (DoLet false false (PVar "h") (EApp (EApp (EApp (EVar "firstContentAt") (EVar "toks")) (EVar "rs")) (EVar "e"))) (DoExpr (EIf (EBinOp ">=" (EVar "h") (EVar "e")) (EListLit) (EBinOp "::" (EApp (EApp (EVar "lineAt") (EVar "lines")) (EVar "h")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesGo") (EVar "toks")) (EVar "lines")) (EVar "op")) (EVar "rs")) (EVar "e")) (ELit (LInt 0))))))))
(DTypeSig false "chainOpLinesGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "chainOpLinesGo" ((PVar "toks") (PVar "lines") (PVar "op") (PVar "i") (PVar "e") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesAt") (EVar "toks")) (EVar "lines")) (EVar "op")) (EVar "i")) (EVar "e")) (EVar "depth")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "chainOpLinesAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyCon "Int"))))))))))
(DFunDef false "chainOpLinesAt" ((PVar "toks") (PVar "lines") (PVar "op") (PVar "i") (PVar "e") (PVar "depth") (PVar "t")) (EIf (EApp (EVar "isOpenDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesGo") (EVar "toks")) (EVar "lines")) (EVar "op")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EApp (EVar "isCloseDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesGo") (EVar "toks")) (EVar "lines")) (EVar "op")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EApp (EVar "chainOpTokEq") (EVar "op")) (EVar "t"))) (EBinOp "::" (EApp (EApp (EVar "lineAt") (EVar "lines")) (EApp (EApp (EApp (EVar "firstContentAt") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesGo") (EVar "toks")) (EVar "lines")) (EVar "op")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesGo") (EVar "toks")) (EVar "lines")) (EVar "op")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "declBlockRhs" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "declBlockRhs" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "declBlockRhs") (EVar "inner")))
(DFunDef false "declBlockRhs" ((PCon "DFunDef" PWild PWild PWild (PVar "body") PWild PWild)) (EApp (EVar "bodyIsBlock") (EVar "body")))
(DFunDef false "declBlockRhs" (PWild) (EVar "False"))
(DTypeSig false "bodyIsBlock" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "bodyIsBlock" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "bodyIsBlock") (EVar "e")))
(DFunDef false "bodyIsBlock" ((PCon "EBlock" PWild)) (EVar "True"))
(DFunDef false "bodyIsBlock" ((PCon "EDo" PWild PWild)) (EVar "True"))
(DFunDef false "bodyIsBlock" (PWild) (EVar "False"))
(DTypeSig false "firstIndentIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "firstIndentIdx" ((PVar "toks") (PVar "i") (PVar "e")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EVar "e") (EIf (EApp (EVar "isIndentTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "firstIndentIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "blockStmtLines" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "blockStmtLines" ((PVar "toks") (PVar "lines") (PVar "rs") (PVar "e")) (EBlock (DoLet false false (PVar "bi") (EApp (EApp (EApp (EVar "firstIndentIdx") (EVar "toks")) (EVar "rs")) (EVar "e"))) (DoExpr (EIf (EBinOp ">=" (EVar "bi") (EVar "e")) (EListLit) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EVar "bi")) (EVar "e")) (ELit (LInt 1))) (EVar "True"))))))
(DTypeSig false "blockStmtGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "blockStmtGo" ((PVar "toks") (PVar "lines") (PVar "i") (PVar "e") (PVar "ind") (PVar "atStart")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EBinOp "<=" (EVar "ind") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtAt") (EVar "toks")) (EVar "lines")) (EVar "i")) (EVar "e")) (EVar "ind")) (EVar "atStart")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "blockStmtAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyCon "Int"))))))))))
(DFunDef false "blockStmtAt" ((PVar "toks") (PVar "lines") (PVar "i") (PVar "e") (PVar "ind") (PVar "atStart") (PVar "t")) (EIf (EApp (EVar "isIndentTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "ind") (ELit (LInt 1)))) (EVar "False")) (EIf (EApp (EVar "isDedentTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "ind") (ELit (LInt 1)))) (EVar "False")) (EIf (EApp (EVar "isNewlineTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "ind")) (EBinOp "==" (EVar "ind") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EVar "atStart") (EBinOp "==" (EVar "ind") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "lineAt") (EVar "lines")) (EVar "i")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "ind")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "ind")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "declChainLines" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "declChainLines" ((PVar "toks") (PVar "lines") (PVar "d") (PVar "s") (PVar "e")) (EMatch (EApp (EVar "declChainTopOp") (EVar "d")) (arm (PCon "Some" (PVar "op")) () (EApp (EApp (EApp (EApp (EApp (EVar "chainOperandLines") (EVar "toks")) (EVar "lines")) (EVar "op")) (EApp (EApp (EApp (EApp (EVar "rhsStartIdx") (EVar "toks")) (EVar "s")) (EVar "e")) (ELit (LInt 0)))) (EVar "e"))) (arm (PCon "None") () (EIf (EApp (EVar "declBlockRhs") (EVar "d")) (EApp (EApp (EApp (EApp (EVar "blockStmtLines") (EVar "toks")) (EVar "lines")) (EApp (EApp (EApp (EApp (EVar "rhsStartIdx") (EVar "toks")) (EVar "s")) (EVar "e")) (ELit (LInt 0)))) (EVar "e")) (EListLit)))))
(DTypeSig false "allChainLines" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "allChainLines" ((PVar "toks") (PVar "lines") (PList)) (EListLit))
(DFunDef false "allChainLines" ((PVar "toks") (PVar "lines") (PCons (PTuple (PVar "d") (PVar "s") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "declChainLines") (EVar "toks")) (EVar "lines")) (EVar "d")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EVar "allChainLines") (EVar "toks")) (EVar "lines")) (EVar "rest"))))
(DTypeSig false "lastContentLineOf" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyCon "Int")))))
(DFunDef false "lastContentLineOf" ((PVar "toks") (PVar "lines") (PVar "spans")) (EApp (EApp (EApp (EApp (EVar "lastContentLineGo") (EVar "toks")) (EVar "lines")) (EVar "spans")) (ELit (LInt 0))))
(DTypeSig false "lastContentLineGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "lastContentLineGo" ((PVar "toks") (PVar "lines") (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "lastContentLineGo" ((PVar "toks") (PVar "lines") (PCons (PTuple PWild (PVar "s") (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "lastContentLineGo") (EVar "toks")) (EVar "lines")) (EVar "rest")) (EApp (EApp (EVar "lineAt") (EVar "lines")) (EApp (EApp (EApp (EVar "lastContentIdx") (EVar "toks")) (EVar "s")) (EBinOp "-" (EVar "e") (ELit (LInt 1)))))))
(DTypeSig true "positionsFromSpans" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyCon "Positions"))))))
(DFunDef false "positionsFromSpans" ((PVar "lineStarts") (PVar "toks") (PVar "offs") (PVar "spans")) (EBlock (DoLet false false (PVar "lines") (EApp (EApp (EVar "map") (ELam ((PVar "off")) (EApp (EVar "fst") (EApp (EApp (EVar "offsetToLineColFast") (EVar "lineStarts")) (EApp (EVar "fst") (EVar "off")))))) (EVar "offs"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "Positions") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "declPosOf") (EVar "toks")) (EVar "lines")) (EVar "offs")) (EVar "lineStarts"))) (EVar "spans"))) (EApp (EApp (EApp (EVar "allVariantLines") (EVar "toks")) (EVar "lines")) (EVar "spans"))) (EApp (EApp (EApp (EVar "lastContentLineOf") (EVar "toks")) (EVar "lines")) (EVar "spans"))) (EApp (EApp (EApp (EVar "allChainLines") (EVar "toks")) (EVar "lines")) (EVar "spans"))))))
# MARK
(DUse false (UseName ("array")))
(DUse false (UseGroup ("frontend" "ast") ((mem "noBinderId" false) (mem "unminted" false) (mem "negateLiteral" false) (mem "DeriveRef" true) (mem "Lit" true) (mem "Ty" true) (mem "EffAtomTy" true) (mem "EffParamTy" true) (mem "effAtomAt" false) (mem "effectDeclUnstamped" false) (mem "KindAnn" true) (mem "Constraint" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "Loc" true) (mem "noDeclLoc" false) (mem "UseMember" true) (mem "UsePath" true) (mem "useMemberOrigin" false) (mem "useMemberAlias" false) (mem "qualifiedLocal" false) (mem "tyConUnresolved" false) (mem "tyConBuiltin" false) (mem "dDataUnresolved" false) (mem "externDataUnresolved" false) (mem "kindAnnSource" false) (mem "kindAuthorityUnstamped" false) (mem "dTypeAliasUnresolved" false) (mem "dNewtypeUnresolved" false) (mem "dInterfaceUnresolved" false) (mem "setDeclNameLoc" false) (mem "dImplUnresolved" false) (mem "constraintUnresolved" false) (mem "superUnresolved" false) (mem "requireUnresolved" false) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true) (mem "ExternDecl" true) (mem "ExternBind" true) (mem "Attr" true) (mem "Route" true))))
(DUse false (UseGroup ("frontend" "lex_token") ((mem "Token" true) (mem "isCommaTok" false) (mem "isNoiseTok" false) (mem "isColonTok" false) (mem "isConsTok" false) (mem "isDedentTok" false) (mem "isDeferTok" false) (mem "isEofTok" false) (mem "isEqualTok" false) (mem "isExportTok" false) (mem "isImplTok" false) (mem "isInTok" false) (mem "isIndentTok" false) (mem "isLBraceTok" false) (mem "isLetTok" false) (mem "isNewlineTok" false) (mem "isOfTok" false) (mem "isPipeTok" false) (mem "isPublicTok" false) (mem "isRBraceTok" false) (mem "isRequiresTok" false) (mem "isStarTok" false) (mem "isWhereTok" false) (mem "isLayoutTok" false) (mem "isOpenDelim" false) (mem "isCloseDelim" false) (mem "isTStringTok" false) (mem "isTUpperTok" false))))
(DUse false (UseGroup ("support" "source_index") ((mem "lineStartIndex" false) (mem "offsetToLineColFast" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "joinWith" false))))
(DUse false (UseGroup ("list") ((mem "last" false))))
(DUse false (UseGroup ("support" "char") ((mem "isUpper" false))))
(DData Public "DeclPos" () ((variant "DeclPos" (ConPos (TyCon "Int") (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc")))))) ())
(DData Public "Positions" () ((variant "Positions" (ConPos (TyApp (TyCon "List") (TyCon "DeclPos")) (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DTypeSig true "positionsDecls" (TyFun (TyCon "Positions") (TyApp (TyCon "List") (TyCon "DeclPos"))))
(DFunDef false "positionsDecls" ((PCon "Positions" (PVar "ds") PWild PWild PWild)) (EVar "ds"))
(DTypeSig true "positionsVariantLines" (TyFun (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "positionsVariantLines" ((PCon "Positions" PWild (PVar "vs") PWild PWild)) (EVar "vs"))
(DTypeSig true "positionsLastContentLine" (TyFun (TyCon "Positions") (TyCon "Int")))
(DFunDef false "positionsLastContentLine" ((PCon "Positions" PWild PWild (PVar "l") PWild)) (EVar "l"))
(DTypeSig true "positionsChainLines" (TyFun (TyCon "Positions") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "positionsChainLines" ((PCon "Positions" PWild PWild PWild (PVar "cl"))) (EVar "cl"))
(DTypeSig true "declPosLine" (TyFun (TyCon "DeclPos") (TyCon "Int")))
(DFunDef false "declPosLine" ((PCon "DeclPos" (PVar "l") PWild PWild PWild)) (EVar "l"))
(DTypeSig true "declPosEndLine" (TyFun (TyCon "DeclPos") (TyCon "Int")))
(DFunDef false "declPosEndLine" ((PCon "DeclPos" PWild (PVar "e") PWild PWild)) (EVar "e"))
(DTypeSig true "declPosNameLoc" (TyFun (TyCon "DeclPos") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "declPosNameLoc" ((PCon "DeclPos" PWild PWild (PVar "nl") PWild)) (EVar "nl"))
(DTypeSig true "declPosChildLocs" (TyFun (TyCon "DeclPos") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "declPosChildLocs" ((PCon "DeclPos" PWild PWild PWild (PVar "cs"))) (EVar "cs"))
(DTypeSig false "lastContentIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "lastContentIdx" ((PVar "toks") (PVar "s") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (EVar "s")) (EVar "s") (EIf (EApp (EVar "isNoiseTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EApp (EApp (EVar "lastContentIdx") (EVar "toks")) (EVar "s")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "lineAt" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "lineAt" ((PVar "lines") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "lines"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "lines")) (EIf (EVar "otherwise") (ELit (LInt 0)) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "locOfSpanWith" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Loc"))))))
(DFunDef false "locOfSpanWith" ((PVar "offs") (PVar "lineStarts") (PVar "startIdx") (PVar "endIdx")) (EBlock (DoLet false false (PVar "lastIdx") (EIf (EBinOp ">" (EVar "endIdx") (EVar "startIdx")) (EBinOp "-" (EVar "endIdx") (ELit (LInt 1))) (EVar "startIdx"))) (DoLet false false (PVar "startOff") (EApp (EApp (EVar "tokOffsetAtArr") (EVar "offs")) (EVar "startIdx"))) (DoLet false false (PVar "endOff") (EApp (EApp (EVar "tokEndOffsetAtArr") (EVar "offs")) (EVar "lastIdx"))) (DoLet false false (PVar "si") (EApp (EApp (EVar "lineStartIndex") (EVar "lineStarts")) (EVar "startOff"))) (DoLet false false (PVar "ei") (EApp (EApp (EVar "lineStartIndex") (EVar "lineStarts")) (EVar "endOff"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EBinOp "+" (EVar "si") (ELit (LInt 1)))) (EBinOp "-" (EVar "startOff") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "si")) (EVar "lineStarts")))) (EBinOp "+" (EVar "ei") (ELit (LInt 1)))) (EBinOp "-" (EVar "endOff") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "ei")) (EVar "lineStarts")))))))
(DTypeSig false "tokOffsetAtArr" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "tokOffsetAtArr" ((PVar "offs") (PVar "i")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "offs")))) (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "offs"))) (ELit (LInt 0))))
(DTypeSig false "tokEndOffsetAtArr" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "tokEndOffsetAtArr" ((PVar "offs") (PVar "i")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "offs")))) (EApp (EVar "snd") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "offs"))) (ELit (LInt 0))))
(DTypeSig false "isLeadingModifierTok" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "isLeadingModifierTok" ((PCon "TPublic")) (EVar "True"))
(DFunDef false "isLeadingModifierTok" ((PCon "TExport")) (EVar "True"))
(DFunDef false "isLeadingModifierTok" ((PCon "TDefault")) (EVar "True"))
(DFunDef false "isLeadingModifierTok" ((PVar "t")) (EApp (EVar "isNoiseTok") (EVar "t")))
(DTypeSig false "skipLeadingModifiers" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "skipLeadingModifiers" ((PVar "toks") (PVar "i")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EApp (EVar "isLeadingModifierTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks")))) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "tokIdxOrNone" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "tokIdxOrNone" ((PVar "toks") (PVar "i")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks")))) (EApp (EVar "Some") (EVar "i")) (EVar "None")))
(DTypeSig false "implHeadTokIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "implHeadTokIdx" ((PVar "toks") (PVar "i")) (EApp (EApp (EApp (EVar "implHeadTokGo") (EVar "toks")) (EVar "i")) (ELit (LInt 0))))
(DTypeSig false "implHeadTokGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "implHeadTokGo" ((PVar "toks") (PVar "i") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "implHeadTokStep") (EVar "toks")) (EVar "i")) (EVar "depth")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "implHeadTokStep" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "implHeadTokStep" ((PVar "toks") (PVar "i") (PVar "depth") (PVar "t")) (EIf (EApp (EVar "isOpenDelim") (EVar "t")) (EApp (EApp (EApp (EVar "implHeadTokGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EApp (EVar "isCloseDelim") (EVar "t")) (EApp (EApp (EApp (EVar "implHeadTokGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EApp (EVar "isTUpperTok") (EVar "t")) (EApp (EVar "Some") (EVar "i")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EBinOp "||" (EBinOp "||" (EApp (EVar "isWhereTok") (EVar "t")) (EApp (EVar "isRequiresTok") (EVar "t"))) (EApp (EVar "isNoiseTok") (EVar "t")))) (EVar "None") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "implHeadTokGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "declNameTokIdxAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DAttrib" PWild (PVar "inner")) (PVar "i")) (EBlock (DoLet false false (PVar "i1") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (DoLet false false (PVar "i2") (EBinOp "+" (EVar "i1") (ELit (LInt 1)))) (DoLet false false (PVar "i3") (EIf (EBinOp "&&" (EBinOp "<" (EVar "i2") (EApp (EVar "arrayLength") (EVar "toks"))) (EApp (EVar "isTStringTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i2")) (EVar "toks")))) (EBinOp "+" (EVar "i2") (ELit (LInt 1))) (EVar "i2"))) (DoExpr (EApp (EApp (EApp (EVar "declNameTokIdx") (EVar "toks")) (EVar "inner")) (EVar "i3")))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DTypeSig" PWild PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EVar "i")))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DFunDef" PWild PWild PWild PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EVar "i")))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DExtern" PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PRec "DData" ((rf "dataOrigin" PWild)) false) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DEffect" PWild PWild PWild PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DProp" PWild PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DTest" PWild PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PRec "DInterface" () true) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PRec "DTypeAlias" ((rf "tyAliasOrigin" PWild)) false) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PRec "DNewtype" ((rf "newtypeOrigin" PWild)) false) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DLetGroup" PWild PWild) (PVar "i")) (EApp (EApp (EVar "tokIdxOrNone") (EVar "toks")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 2))))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PRec "DImpl" () true) (PVar "i")) (EMatch (EApp (EApp (EVar "implHeadTokIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (arm (PCon "Some" (PVar "headIdx")) () (EApp (EVar "Some") (EVar "headIdx"))) (arm (PCon "None") () (EApp (EVar "Some") (EVar "i")))))
(DFunDef false "declNameTokIdxAt" ((PVar "toks") (PCon "DUse" PWild PWild PWild) (PVar "i")) (EVar "None"))
(DTypeSig false "declNameTokIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "declNameTokIdx" ((PVar "toks") (PVar "d") (PVar "i")) (EApp (EApp (EApp (EVar "declNameTokIdxAt") (EVar "toks")) (EVar "d")) (EApp (EApp (EVar "skipLeadingModifiers") (EVar "toks")) (EVar "i"))))
(DTypeSig false "declNameSpanOf" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "declNameSpanOf" ((PVar "toks") (PVar "offs") (PVar "lineStarts") (PTuple (PVar "d") (PVar "s") (PVar "_e"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "nameIdx")) (EApp (EApp (EApp (EApp (EVar "locOfSpanWith") (EVar "offs")) (EVar "lineStarts")) (EVar "nameIdx")) (EBinOp "+" (EVar "nameIdx") (ELit (LInt 1)))))) (EApp (EApp (EApp (EVar "declNameTokIdx") (EVar "toks")) (EVar "d")) (EVar "s"))))
(DTypeSig false "innerDeclOf" (TyFun (TyCon "Decl") (TyCon "Decl")))
(DFunDef false "innerDeclOf" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "innerDeclOf") (EVar "d")))
(DFunDef false "innerDeclOf" ((PVar "d")) (EVar "d"))
(DTypeSig false "declChildNameIdxs" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "declChildNameIdxs" ((PVar "toks") (PTuple (PVar "d") (PVar "s") (PVar "e"))) (EMatch (EApp (EVar "innerDeclOf") (EVar "d")) (arm (PRec "DData" ((rf "dataCtors" (PVar "variants"))) false) () (EApp (EApp (EApp (EApp (EVar "dataChildIdxs") (EVar "toks")) (EVar "s")) (EVar "e")) (EVar "variants"))) (arm (PRec "DInterface" () true) () (EApp (EApp (EApp (EVar "methodNameIdxs") (EVar "toks")) (EVar "s")) (EVar "e"))) (arm (PRec "DImpl" () true) () (EApp (EApp (EApp (EVar "methodNameIdxs") (EVar "toks")) (EVar "s")) (EVar "e"))) (arm (PCon "DLetGroup" PWild PWild) () (EListLit (EApp (EApp (EApp (EVar "declNameTokIdx") (EVar "toks")) (EVar "d")) (EVar "s")))) (arm PWild () (EListLit))))
(DTypeSig false "variantBoundaryIdxs" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "variantBoundaryIdxs" ((PVar "toks") (PVar "s") (PVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EVar "s")) (EVar "e")) (ELit (LInt 0))) (EVar "False")))
(DTypeSig false "variantBoundaryGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "variantBoundaryGo" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "seenEq")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryAt") (EVar "toks")) (EVar "i")) (EVar "e")) (EVar "depth")) (EVar "seenEq")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "variantBoundaryAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "variantBoundaryAt" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "seenEq") (PVar "t")) (EIf (EApp (EVar "isOpenDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "seenEq")) (EIf (EApp (EVar "isCloseDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "seenEq")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "not") (EVar "seenEq"))) (EApp (EVar "isEqualTok") (EVar "t"))) (EApp (EApp (EApp (EVar "nextSigIsPipe") (EVar "toks")) (EVar "e")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "True")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "not") (EVar "seenEq"))) (EApp (EVar "isEqualTok") (EVar "t"))) (EBinOp "::" (EApp (EApp (EApp (EVar "firstContentAt") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "True"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EVar "seenEq")) (EApp (EVar "isPipeTok") (EVar "t"))) (EBinOp "::" (EApp (EApp (EApp (EVar "firstContentAt") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "seenEq"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "variantBoundaryGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "seenEq")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "dataChildIdxs" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "dataChildIdxs" ((PVar "toks") (PVar "s") (PVar "e") (PVar "variants")) (EApp (EApp (EApp (EApp (EVar "zipVariantIdxs") (EVar "toks")) (EVar "e")) (EVar "variants")) (EApp (EApp (EApp (EVar "variantBoundaryIdxs") (EVar "toks")) (EVar "s")) (EVar "e"))))
(DTypeSig false "zipVariantIdxs" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int"))))))))
(DFunDef false "zipVariantIdxs" (PWild PWild (PList) PWild) (EListLit))
(DFunDef false "zipVariantIdxs" ((PVar "toks") (PVar "e") (PCons (PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") (PCon "True"))) (PVar "vs")) (PCons (PVar "b") (PVar "bs"))) (EBinOp "++" (EApp (EApp (EVar "zipFieldIdxs") (EVar "fs")) (EApp (EApp (EApp (EVar "fieldNameIdxsIn") (EVar "toks")) (EBinOp "+" (EVar "b") (ELit (LInt 1)))) (EVar "e"))) (EApp (EApp (EApp (EApp (EVar "zipVariantIdxs") (EVar "toks")) (EVar "e")) (EVar "vs")) (EVar "bs"))))
(DFunDef false "zipVariantIdxs" ((PVar "toks") (PVar "e") (PCons (PCon "Variant" PWild PWild) (PVar "vs")) (PCons (PVar "b") (PVar "bs"))) (EBinOp "::" (EApp (EVar "Some") (EVar "b")) (EApp (EApp (EApp (EApp (EVar "zipVariantIdxs") (EVar "toks")) (EVar "e")) (EVar "vs")) (EVar "bs"))))
(DFunDef false "zipVariantIdxs" ((PVar "toks") (PVar "e") (PCons (PVar "v") (PVar "vs")) (PList)) (EBinOp "++" (EApp (EVar "variantNoneIdxs") (EVar "v")) (EApp (EApp (EApp (EApp (EVar "zipVariantIdxs") (EVar "toks")) (EVar "e")) (EVar "vs")) (EListLit))))
(DTypeSig false "variantNoneIdxs" (TyFun (TyCon "Variant") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "variantNoneIdxs" ((PCon "Variant" PWild (PCon "ConNamed" (PVar "fs") (PCon "True")))) (EApp (EApp (EMethodRef "map") (ELam (PWild) (EVar "None"))) (EVar "fs")))
(DFunDef false "variantNoneIdxs" ((PCon "Variant" PWild PWild)) (EListLit (EVar "None")))
(DTypeSig false "fieldNameIdxsIn" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "fieldNameIdxsIn" ((PVar "toks") (PVar "i") (PVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EVar "i")) (EVar "e")) (ELit (LInt 1))) (EVar "True")))
(DTypeSig false "fieldNameGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "fieldNameGo" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "atStart")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EBinOp "<=" (EVar "depth") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameStep") (EVar "toks")) (EVar "i")) (EVar "e")) (EVar "depth")) (EVar "atStart")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "fieldNameStep" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "fieldNameStep" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "atStart") (PVar "t")) (EIf (EApp (EVar "isOpenDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "False")) (EIf (EApp (EVar "isCloseDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "False")) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 1))) (EApp (EVar "isCommaTok") (EVar "t"))) (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "True")) (EIf (EApp (EVar "isNoiseTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "atStart")) (EIf (EBinOp "&&" (EVar "atStart") (EBinOp "==" (EVar "depth") (ELit (LInt 1)))) (EBinOp "::" (EVar "i") (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "fieldNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "zipFieldIdxs" (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "zipFieldIdxs" ((PList) PWild) (EListLit))
(DFunDef false "zipFieldIdxs" ((PCons PWild (PVar "fs")) (PCons (PVar "i") (PVar "is"))) (EBinOp "::" (EApp (EVar "Some") (EVar "i")) (EApp (EApp (EVar "zipFieldIdxs") (EVar "fs")) (EVar "is"))))
(DFunDef false "zipFieldIdxs" ((PCons PWild (PVar "fs")) (PList)) (EBinOp "::" (EVar "None") (EApp (EApp (EVar "zipFieldIdxs") (EVar "fs")) (EListLit))))
(DTypeSig false "methodNameIdxs" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int")))))))
(DFunDef false "methodNameIdxs" ((PVar "toks") (PVar "s") (PVar "e")) (EMatch (EApp (EApp (EApp (EVar "findWhereIdx") (EVar "toks")) (EVar "s")) (EVar "e")) (arm (PCon "None") () (EListLit)) (arm (PCon "Some" (PVar "w")) () (EBlock (DoLet false false (PVar "after") (EApp (EApp (EApp (EVar "skipNewlineToks") (EVar "toks")) (EBinOp "+" (EVar "w") (ELit (LInt 1)))) (EVar "e"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EVar "after") (EVar "e")) (EApp (EVar "isIndentTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "after")) (EVar "toks")))) (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "after") (ELit (LInt 1)))) (EVar "e")) (ELit (LInt 1))) (EVar "True")) (EListLit)))))))
(DTypeSig false "findWhereIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "findWhereIdx" ((PVar "toks") (PVar "i") (PVar "e")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EVar "None") (EIf (EApp (EVar "isWhereTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "Some") (EVar "i")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "findWhereIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "skipNewlineToks" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "skipNewlineToks" ((PVar "toks") (PVar "i") (PVar "e")) (EIf (EBinOp "&&" (EBinOp "<" (EVar "i") (EVar "e")) (EApp (EVar "isNewlineTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks")))) (EApp (EApp (EApp (EVar "skipNewlineToks") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "methodNameGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int")))))))))
(DFunDef false "methodNameGo" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "atStart")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EBinOp "<=" (EVar "depth") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "methodNameStep") (EVar "toks")) (EVar "i")) (EVar "e")) (EVar "depth")) (EVar "atStart")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "methodNameStep" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Int"))))))))))
(DFunDef false "methodNameStep" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") PWild (PCon "TIndent")) (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "False")))
(DFunDef false "methodNameStep" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") PWild (PCon "TDedent")) (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "False")))
(DFunDef false "methodNameStep" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") PWild (PCon "TNewline")) (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EBinOp "==" (EVar "depth") (ELit (LInt 1)))))
(DFunDef false "methodNameStep" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth") (PVar "atStart") PWild) (EIf (EBinOp "&&" (EVar "atStart") (EBinOp "==" (EVar "depth") (ELit (LInt 1)))) (EBinOp "::" (EApp (EVar "Some") (EVar "i")) (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EVar "methodNameGo") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declChildSpansOf" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int")) (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Loc"))))))))
(DFunDef false "declChildSpansOf" ((PVar "toks") (PVar "offs") (PVar "lineStarts") (PVar "span")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "idxOpt")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "idx")) (EApp (EApp (EApp (EApp (EVar "locOfSpanWith") (EVar "offs")) (EVar "lineStarts")) (EVar "idx")) (EBinOp "+" (EVar "idx") (ELit (LInt 1)))))) (EVar "idxOpt")))) (EApp (EApp (EVar "declChildNameIdxs") (EVar "toks")) (EVar "span"))))
(DTypeSig false "declPosOf" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int")) (TyCon "DeclPos")))))))
(DFunDef false "declPosOf" ((PVar "toks") (PVar "lines") (PVar "offs") (PVar "lineStarts") (PTuple (PVar "d") (PVar "s") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "DeclPos") (EApp (EApp (EVar "lineAt") (EVar "lines")) (EVar "s"))) (EApp (EApp (EVar "lineAt") (EVar "lines")) (EApp (EApp (EApp (EVar "lastContentIdx") (EVar "toks")) (EVar "s")) (EBinOp "-" (EVar "e") (ELit (LInt 1)))))) (EApp (EApp (EApp (EApp (EVar "declNameSpanOf") (EVar "toks")) (EVar "offs")) (EVar "lineStarts")) (ETuple (EVar "d") (EVar "s") (EVar "e")))) (EApp (EApp (EApp (EApp (EVar "declChildSpansOf") (EVar "toks")) (EVar "offs")) (EVar "lineStarts")) (ETuple (EVar "d") (EVar "s") (EVar "e")))))
(DTypeSig false "variantStartsIn" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "variantStartsIn" ((PVar "toks") (PVar "lines") (PVar "i") (PVar "e")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EVar "i")) (EVar "e")) (ELit (LInt 0))) (EVar "False")))
(DTypeSig false "variantStartsGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "variantStartsGo" ((PVar "toks") (PVar "lines") (PVar "i") (PVar "e") (PVar "depth") (PVar "seenEq")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsAt") (EVar "toks")) (EVar "lines")) (EVar "i")) (EVar "e")) (EVar "depth")) (EVar "seenEq")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "variantStartsAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyCon "Int"))))))))))
(DFunDef false "variantStartsAt" ((PVar "toks") (PVar "lines") (PVar "i") (PVar "e") (PVar "depth") (PVar "seenEq") (PVar "t")) (EIf (EApp (EVar "isOpenDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EVar "seenEq")) (EIf (EApp (EVar "isCloseDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EVar "seenEq")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "not") (EVar "seenEq"))) (EApp (EVar "isEqualTok") (EVar "t"))) (EApp (EApp (EApp (EVar "nextSigIsPipe") (EVar "toks")) (EVar "e")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "True")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "not") (EVar "seenEq"))) (EApp (EVar "isEqualTok") (EVar "t"))) (EBinOp "::" (EApp (EApp (EVar "lineAt") (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "True"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EVar "seenEq")) (EApp (EVar "isPipeTok") (EVar "t"))) (EBinOp "::" (EApp (EApp (EVar "lineAt") (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "seenEq"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "variantStartsGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EVar "seenEq")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "nextSigIsPipe" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "nextSigIsPipe" ((PVar "toks") (PVar "e") (PVar "j")) (EIf (EBinOp ">=" (EVar "j") (EVar "e")) (EVar "False") (EIf (EApp (EVar "isLayoutTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "toks"))) (EApp (EApp (EApp (EVar "nextSigIsPipe") (EVar "toks")) (EVar "e")) (EBinOp "+" (EVar "j") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EVar "isPipeTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "isDataDecl" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "isDataDecl" ((PRec "DData" ((rf "dataOrigin" PWild)) false)) (EVar "True"))
(DFunDef false "isDataDecl" (PWild) (EVar "False"))
(DTypeSig false "allVariantLines" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Int"))))))
(DFunDef false "allVariantLines" ((PVar "toks") (PVar "lines") (PList)) (EListLit))
(DFunDef false "allVariantLines" ((PVar "toks") (PVar "lines") (PCons (PTuple (PVar "d") (PVar "s") (PVar "e")) (PVar "rest"))) (EIf (EApp (EVar "isDataDecl") (EVar "d")) (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "variantStartsIn") (EVar "toks")) (EVar "lines")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EVar "allVariantLines") (EVar "toks")) (EVar "lines")) (EVar "rest"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "allVariantLines") (EVar "toks")) (EVar "lines")) (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isContinuationOpStr" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isContinuationOpStr" ((PVar "op")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "|>"))) (EBinOp "==" (EVar "op") (ELit (LString ">>")))) (EBinOp "==" (EVar "op") (ELit (LString "<<")))) (EBinOp "==" (EVar "op") (ELit (LString "&&")))) (EBinOp "==" (EVar "op") (ELit (LString "||")))) (EBinOp "==" (EVar "op") (ELit (LString "++")))))
(DTypeSig false "chainOpTokEq" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyCon "Bool"))))
(DFunDef false "chainOpTokEq" ((PLit (LString "&&")) (PCon "TAnd")) (EVar "True"))
(DFunDef false "chainOpTokEq" ((PLit (LString "||")) (PCon "TOr")) (EVar "True"))
(DFunDef false "chainOpTokEq" ((PLit (LString "|>")) (PCon "TPipeRight")) (EVar "True"))
(DFunDef false "chainOpTokEq" ((PLit (LString ">>")) (PCon "TRCompose")) (EVar "True"))
(DFunDef false "chainOpTokEq" ((PLit (LString "<<")) (PCon "TLCompose")) (EVar "True"))
(DFunDef false "chainOpTokEq" ((PLit (LString "++")) (PCon "TPlusPlus")) (EVar "True"))
(DFunDef false "chainOpTokEq" (PWild PWild) (EVar "False"))
(DTypeSig false "declChainTopOp" (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "declChainTopOp" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "declChainTopOp") (EVar "inner")))
(DFunDef false "declChainTopOp" ((PCon "DFunDef" PWild PWild PWild (PVar "body") PWild PWild)) (EApp (EVar "bodyChainTopOp") (EVar "body")))
(DFunDef false "declChainTopOp" (PWild) (EVar "None"))
(DTypeSig false "bodyChainTopOp" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "bodyChainTopOp" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "bodyChainTopOp") (EVar "e")))
(DFunDef false "bodyChainTopOp" ((PCon "EBinOp" (PVar "op") PWild PWild PWild)) (EIf (EApp (EVar "isContinuationOpStr") (EVar "op")) (EApp (EVar "Some") (EVar "op")) (EVar "None")))
(DFunDef false "bodyChainTopOp" (PWild) (EVar "None"))
(DTypeSig false "firstContentAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "firstContentAt" ((PVar "toks") (PVar "i") (PVar "e")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EVar "e") (EIf (EApp (EVar "isNoiseTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EApp (EApp (EVar "firstContentAt") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EIf (EVar "otherwise") (EVar "i") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "rhsStartIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "rhsStartIdx" ((PVar "toks") (PVar "i") (PVar "e") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EVar "e") (EIf (EApp (EVar "isOpenDelim") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EApp (EApp (EApp (EVar "rhsStartIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EApp (EVar "isCloseDelim") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EApp (EApp (EApp (EVar "rhsStartIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "isEqualTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks")))) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EVar "rhsStartIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "chainOperandLines" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "chainOperandLines" ((PVar "toks") (PVar "lines") (PVar "op") (PVar "rs") (PVar "e")) (EBlock (DoLet false false (PVar "h") (EApp (EApp (EApp (EVar "firstContentAt") (EVar "toks")) (EVar "rs")) (EVar "e"))) (DoExpr (EIf (EBinOp ">=" (EVar "h") (EVar "e")) (EListLit) (EBinOp "::" (EApp (EApp (EVar "lineAt") (EVar "lines")) (EVar "h")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesGo") (EVar "toks")) (EVar "lines")) (EVar "op")) (EVar "rs")) (EVar "e")) (ELit (LInt 0))))))))
(DTypeSig false "chainOpLinesGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "chainOpLinesGo" ((PVar "toks") (PVar "lines") (PVar "op") (PVar "i") (PVar "e") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesAt") (EVar "toks")) (EVar "lines")) (EVar "op")) (EVar "i")) (EVar "e")) (EVar "depth")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "chainOpLinesAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyCon "Int"))))))))))
(DFunDef false "chainOpLinesAt" ((PVar "toks") (PVar "lines") (PVar "op") (PVar "i") (PVar "e") (PVar "depth") (PVar "t")) (EIf (EApp (EVar "isOpenDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesGo") (EVar "toks")) (EVar "lines")) (EVar "op")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EApp (EVar "isCloseDelim") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesGo") (EVar "toks")) (EVar "lines")) (EVar "op")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EApp (EVar "chainOpTokEq") (EVar "op")) (EVar "t"))) (EBinOp "::" (EApp (EApp (EVar "lineAt") (EVar "lines")) (EApp (EApp (EApp (EVar "firstContentAt") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesGo") (EVar "toks")) (EVar "lines")) (EVar "op")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "chainOpLinesGo") (EVar "toks")) (EVar "lines")) (EVar "op")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "declBlockRhs" (TyFun (TyCon "Decl") (TyCon "Bool")))
(DFunDef false "declBlockRhs" ((PCon "DAttrib" PWild (PVar "inner"))) (EApp (EVar "declBlockRhs") (EVar "inner")))
(DFunDef false "declBlockRhs" ((PCon "DFunDef" PWild PWild PWild (PVar "body") PWild PWild)) (EApp (EVar "bodyIsBlock") (EVar "body")))
(DFunDef false "declBlockRhs" (PWild) (EVar "False"))
(DTypeSig false "bodyIsBlock" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "bodyIsBlock" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "bodyIsBlock") (EVar "e")))
(DFunDef false "bodyIsBlock" ((PCon "EBlock" PWild)) (EVar "True"))
(DFunDef false "bodyIsBlock" ((PCon "EDo" PWild PWild)) (EVar "True"))
(DFunDef false "bodyIsBlock" (PWild) (EVar "False"))
(DTypeSig false "firstIndentIdx" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))
(DFunDef false "firstIndentIdx" ((PVar "toks") (PVar "i") (PVar "e")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EVar "e") (EIf (EApp (EVar "isIndentTok") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "firstIndentIdx") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "blockStmtLines" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "blockStmtLines" ((PVar "toks") (PVar "lines") (PVar "rs") (PVar "e")) (EBlock (DoLet false false (PVar "bi") (EApp (EApp (EApp (EVar "firstIndentIdx") (EVar "toks")) (EVar "rs")) (EVar "e"))) (DoExpr (EIf (EBinOp ">=" (EVar "bi") (EVar "e")) (EListLit) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EVar "bi")) (EVar "e")) (ELit (LInt 1))) (EVar "True"))))))
(DTypeSig false "blockStmtGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Int")))))))))
(DFunDef false "blockStmtGo" ((PVar "toks") (PVar "lines") (PVar "i") (PVar "e") (PVar "ind") (PVar "atStart")) (EIf (EBinOp ">=" (EVar "i") (EVar "e")) (EListLit) (EIf (EBinOp "<=" (EVar "ind") (ELit (LInt 0))) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtAt") (EVar "toks")) (EVar "lines")) (EVar "i")) (EVar "e")) (EVar "ind")) (EVar "atStart")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "toks"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "blockStmtAt" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "List") (TyCon "Int"))))))))))
(DFunDef false "blockStmtAt" ((PVar "toks") (PVar "lines") (PVar "i") (PVar "e") (PVar "ind") (PVar "atStart") (PVar "t")) (EIf (EApp (EVar "isIndentTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "+" (EVar "ind") (ELit (LInt 1)))) (EVar "False")) (EIf (EApp (EVar "isDedentTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EBinOp "-" (EVar "ind") (ELit (LInt 1)))) (EVar "False")) (EIf (EApp (EVar "isNewlineTok") (EVar "t")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "ind")) (EBinOp "==" (EVar "ind") (ELit (LInt 1)))) (EIf (EBinOp "&&" (EVar "atStart") (EBinOp "==" (EVar "ind") (ELit (LInt 1)))) (EBinOp "::" (EApp (EApp (EVar "lineAt") (EVar "lines")) (EVar "i")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "ind")) (EVar "False"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "blockStmtGo") (EVar "toks")) (EVar "lines")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "e")) (EVar "ind")) (EVar "False")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))
(DTypeSig false "declChainLines" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Decl") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int"))))))))
(DFunDef false "declChainLines" ((PVar "toks") (PVar "lines") (PVar "d") (PVar "s") (PVar "e")) (EMatch (EApp (EVar "declChainTopOp") (EVar "d")) (arm (PCon "Some" (PVar "op")) () (EApp (EApp (EApp (EApp (EApp (EVar "chainOperandLines") (EVar "toks")) (EVar "lines")) (EVar "op")) (EApp (EApp (EApp (EApp (EVar "rhsStartIdx") (EVar "toks")) (EVar "s")) (EVar "e")) (ELit (LInt 0)))) (EVar "e"))) (arm (PCon "None") () (EIf (EApp (EVar "declBlockRhs") (EVar "d")) (EApp (EApp (EApp (EApp (EVar "blockStmtLines") (EVar "toks")) (EVar "lines")) (EApp (EApp (EApp (EApp (EVar "rhsStartIdx") (EVar "toks")) (EVar "s")) (EVar "e")) (ELit (LInt 0)))) (EVar "e")) (EListLit)))))
(DTypeSig false "allChainLines" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Int")))))))
(DFunDef false "allChainLines" ((PVar "toks") (PVar "lines") (PList)) (EListLit))
(DFunDef false "allChainLines" ((PVar "toks") (PVar "lines") (PCons (PTuple (PVar "d") (PVar "s") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "declChainLines") (EVar "toks")) (EVar "lines")) (EVar "d")) (EVar "s")) (EVar "e")) (EApp (EApp (EApp (EVar "allChainLines") (EVar "toks")) (EVar "lines")) (EVar "rest"))))
(DTypeSig false "lastContentLineOf" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyCon "Int")))))
(DFunDef false "lastContentLineOf" ((PVar "toks") (PVar "lines") (PVar "spans")) (EApp (EApp (EApp (EApp (EVar "lastContentLineGo") (EVar "toks")) (EVar "lines")) (EVar "spans")) (ELit (LInt 0))))
(DTypeSig false "lastContentLineGo" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "lastContentLineGo" ((PVar "toks") (PVar "lines") (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "lastContentLineGo" ((PVar "toks") (PVar "lines") (PCons (PTuple PWild (PVar "s") (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "lastContentLineGo") (EVar "toks")) (EVar "lines")) (EVar "rest")) (EApp (EApp (EVar "lineAt") (EVar "lines")) (EApp (EApp (EApp (EVar "lastContentIdx") (EVar "toks")) (EVar "s")) (EBinOp "-" (EVar "e") (ELit (LInt 1)))))))
(DTypeSig true "positionsFromSpans" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyCon "Positions"))))))
(DFunDef false "positionsFromSpans" ((PVar "lineStarts") (PVar "toks") (PVar "offs") (PVar "spans")) (EBlock (DoLet false false (PVar "lines") (EApp (EApp (EMethodRef "map") (ELam ((PVar "off")) (EApp (EVar "fst") (EApp (EApp (EVar "offsetToLineColFast") (EVar "lineStarts")) (EApp (EVar "fst") (EVar "off")))))) (EVar "offs"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "Positions") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "declPosOf") (EVar "toks")) (EVar "lines")) (EVar "offs")) (EVar "lineStarts"))) (EVar "spans"))) (EApp (EApp (EApp (EVar "allVariantLines") (EVar "toks")) (EVar "lines")) (EVar "spans"))) (EApp (EApp (EApp (EVar "lastContentLineOf") (EVar "toks")) (EVar "lines")) (EVar "spans"))) (EApp (EApp (EApp (EVar "allChainLines") (EVar "toks")) (EVar "lines")) (EVar "spans"))))))
