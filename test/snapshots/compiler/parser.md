# META
source_lines=5076
stages=DESUGAR,MARK
# SOURCE
import frontend.parse_locate.{locateOffset, locateTokenDiagnostic}
import frontend.parse_hints.{
  prescanDiagnostic, matchContinuationHint, letMutRemovedMsg, isLineEndTok,
  isBracketOpenTok, isBracketCloseTok
}
import frontend.parse_engine.{
  PR(..), PFail(..), ParserE(..), Parser, ParseContext, ParseMark,
  ParseMode(..), newParseContext, newParseContextWith, runPWith, runP,
  contextTokens, contextOffsets, contextLineStarts, contextHasTab, contextP,
  getPos, peekTok, peekP, peek2P, peek3P, advance, emit, expectTok, failP,
  fatalP, fatalProblemAtP, fatalAtP, failProblem, orElse as parseOrElse, many,
  sepBy1, mark, rewind, locOfSpan, spanLoc, depthOf, withDepth,
  recordTrailingComma, recordUnitStart, forgetLatestUnitStart, contextCues,
  unexpectedTokenMsg
}
import frontend.parse_result.{
  ParsedSource, makeParsedSource, makeParseMetadata, parsedDecls,
  parsedPositions
}
-- Parse the lexer token array into declarations and expressions.
-- ParserE combinators handle grammar productions; binLevel uses the raw
-- representation to avoid per-level allocation in the operator ladder.
-- Syntax precedence and associativity are specified in docs/spec/SYNTAX.md.

export import frontend.parse_result.{
  ParseError(..), parseErrorDiagnostic, parseErrorLine, parseErrorCol,
  parseErrorMessage
}
import frontend.parse_diagnostic.{
  ParseDiagnostic,
  ParseDiagnosticKind(..),
  renderParseProblem,
}
import support.source_index.{SourceIndex, indexSource}
import support.stage_count.{stageBump}
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
import frontend.lexer.{
  Token(..),
  tokenize,
  tokenizeWithOffsets,
  tokenizeWithOffsetPairs,
  offsetToLineCol,
  lineStartsOf,
  offsetToLineColFast,
  isThenTok,
}
export import frontend.parse_positions.{
  DeclPos(..), Positions(..), positionsDecls, positionsVariantLines,
  positionsLastContentLine, positionsChainLines, declPosLine, declPosEndLine,
  declPosNameLoc, declPosChildLocs
}
import frontend.parse_positions.{positionsFromSpans}
import frontend.lex_token.{
  isColonTok, isConsTok, isDedentTok, isDeferTok, isEofTok, isEqualTok,
  isExportTok, isImplTok, isInTok, isIndentTok, isLBraceTok, isLetTok,
  isNewlineTok, isOfTok, isPipeTok, isPublicTok, isRBraceTok, isRequiresTok,
  isStarTok, isOpenDelim, isCloseDelim, isTStringTok, isTUpperTok
}
import support.util.{reverseL, joinWith}
import list.{last}
import support.char.{isUpper}

located : Parser Expr -> Parser Expr
located p = defer
  s <- getPos
  e <- p
  q <- getPos
  loc <- spanLoc s q
  deferPure (ELoc loc e)

identNameP : Parser String
identNameP = defer
  t <- peekP
  identNameFor t

identNameFor : Token -> Parser String
identNameFor (TIdent x) = emit x
identNameFor _ = failP "expected an identifier"

-- Consume an OPTIONAL trailing comma that `sepBy1` left positioned at (a
-- trailing comma backtracks the failed element parse, leaving the parser AT the
-- comma).  Additive: a non-comma token is left untouched, so existing
-- (comma-free) input parses identically.  Insert between `sepBy1` and the
-- closing-delimiter `expectTok` to accept the trailing-comma-on-break form the
-- formatter emits.
optTrailingComma : Parser Unit
optTrailingComma = defer
  t <- peekP
  optTrailingCommaFor t

optTrailingCommaFor : Token -> Parser Unit
optTrailingCommaFor TComma = defer
  p <- getPos
  advance
  recordTrailingComma p
optTrailingCommaFor _ = deferPure ()

-- Like `optTrailingComma`, but a no-op for a single-element paren group — a
-- trailing comma after one element (`(x,)`) is NOT accepted, so `(x)` keeps its
-- "parenthesized x" meaning (no 1-tuple ambiguity).
optTrailingCommaTuple : List a -> Parser Unit
optTrailingCommaTuple [_] = deferPure ()
optTrailingCommaTuple _ = optTrailingComma

-- NB: recurse through a do-continuation (lazy), not by passing `skipNewlines`
-- as a strict argument — the latter forces the value while it's being defined
-- (a recursive-value init cycle → CamlinternalLazy.Undefined under strict eval).
skipNewlines : Parser Unit
skipNewlines = defer
  t <- peekP
  skipNlFor t

skipNlFor : Token -> Parser Unit
skipNlFor TNewline = defer
  advance
  skipNewlines
skipNlFor _ = deferPure ()

-- ── Expressions ─────────────────────────────────────────────────────────
-- ladder: lam → or → and → cmp → cons → append → add → mul → app → postfix → atom
parseExpr : Parser Expr
parseExpr = defer
  e <- parseAssign
  annotOpt e

-- `:=` reference assignment (mutation). Looser than lambda so the RHS may be a
-- full lambda (`r := x => x`), right-associative (`a := b := c` ⇒ `a := (b := c)`)
-- like OCaml. Desugars to `setRef lhs rhs` in `desugar.mdk` (an `EBinOp ":="` node
-- survives resolve/typecheck only up to that lowering).
parseAssign : Parser Expr
parseAssign = defer
  e <- parseLam
  assignOpt e

assignTail : Expr -> Parser Expr
assignTail lhs = located (assignTailRaw lhs)

-- The RHS reads via `parseRhsExpr`, not a bare `parseAssign`: `:=` is a layout
-- herald (LAYOUT-SEMANTICS.md §7.1) exactly as `=>` is — it is absent from the
-- lexer's `canEndExpr`, so `r :=⏎  rhs` opens a bare-INDENT block that
-- `parseAssign` has no TIndent case to read.  The same production the decl body
-- (`parseBody`), a let/where RHS, and `lamTailRaw` already use.
--
-- Before this, an indented RHS died on the generic *"unexpected `:=`; expected a
-- dedent"* — §12 item 5's "the lexer heralds it correctly but the parser cannot
-- consume it" ⇒ a PARSER bug, not a lexer one.  It also made `medaka lint --fix`
-- DESTROY SOURCE: a fix reprints the whole decl through `tools/printer.mdk`, whose
-- `hangAtSep` legitimately drops a wide def-body below its separator, so any decl
-- whose body was a `:=` with a wide RHS came back unparseable while `--fix`
-- reported success and exited 0.
--
-- Right-associativity is preserved: `parseRhsExpr` falls back to `parseExpr`,
-- which routes to `parseAssign`, so `a := b := c` still nests right.  (It also
-- admits a trailing annotation on the RHS — `r := e : T` — which bare
-- `parseAssign` did not; that matches every other RHS position.)
assignTailRaw : Expr -> Parser Expr
assignTailRaw lhs = defer
  expectTok TColonEq
  rhs <- parseRhsExpr
  deferPure (EBinOp ":=" lhs rhs unminted)

-- Each optional tail is taken only when its introducing token is next.  Any
-- other next token makes the tail fail without consuming (at this same pos), so
-- the result is `POk e pos` and the tail's chain need not be built.
annotOpt : Expr -> Parser Expr
annotOpt e = ParserE (ctx pos => match peekTok (contextTokens ctx) pos
  TColon => runPWith ctx (parseOrElse (annotTail e) (deferPure e)) pos
  _ => POk e pos)

assignOpt : Expr -> Parser Expr
assignOpt e = ParserE (ctx pos => match peekTok (contextTokens ctx) pos
  TColonEq => runPWith ctx (parseOrElse (assignTail e) (deferPure e)) pos
  _ => POk e pos)

lamOpt : Expr -> Parser Expr
lamOpt e = ParserE (ctx pos => match peekTok (contextTokens ctx) pos
  TFatArrow => runPWith ctx (parseOrElse (lamTail e) (deferPure e)) pos
  _ => POk e pos)

-- expression type annotation `e : ty` (loosest level)
annotTail : Expr -> Parser Expr
annotTail e = defer
  expectTok TColon
  t <- parseTy
  deferPure (EAnnot e t)

parseLam : Parser Expr
parseLam = defer
  e <- parsePipe
  lamOpt e

lamTail : Expr -> Parser Expr
lamTail e = located (lamTailRaw e)

-- The body reads via `parseRhsExpr`, not a bare `parseExpr`: `=>` is a layout
-- herald (LAYOUT-SEMANTICS.md §7.1) — it is absent from the lexer's
-- `canEndExpr`, so `g x =>⏎  body` opens a bare-INDENT block, and a bare
-- `parseExpr` has no TIndent case to read it.  Same production the decl body
-- (`parseBody`) and a let/where RHS (`parseRhsExpr`) already use.
lamTailRaw : Expr -> Parser Expr
lamTailRaw e = defer
  expectTok TFatArrow
  body <- parseRhsExpr
  deferPure (ELam (exprToParams e) body)

-- convert a lambda LHS expression to a parameter-pattern list (mirrors the
-- reference `expr_to_pats`): an EApp spine with a lowercase head is a multi-arg
-- lambda (one pattern per spine element); an uppercase head is a single
-- constructor pattern; anything else is a single pattern.
exprToParams : Expr -> List Pat
exprToParams (ELoc _ e) = exprToParams e
exprToParams (EApp f x) = appToParams (EApp f x)
exprToParams e = [exprToPat e]

appToParams : Expr -> List Pat
appToParams app = paramsForHead (spineHead app) app

paramsForHead : Expr -> Expr -> List Pat
paramsForHead (EVar c) app = paramsForCtor c app
paramsForHead _ app = map exprToPat (spineList app)

paramsForCtor : String -> Expr -> List Pat
paramsForCtor c app
  | isCtorName c = [exprToPat app]
  | otherwise = map exprToPat (spineList app)

-- head of an EApp spine.  App nodes are un-wrapped (the app level builds bare
-- EApp), but the leaf head is ELoc-wrapped — strip it so callers can match the
-- raw `EVar`/etc. shape.
spineHead : Expr -> Expr
spineHead (EApp f _) = spineHead f
spineHead (ELoc _ e) = spineHead e
spineHead e = e

-- flatten an EApp spine into [head, arg1, arg2, …]
spineList : Expr -> List Expr
spineList e = spineOnto e []

spineOnto : Expr -> List Expr -> List Expr
spineOnto (ELoc _ e) acc = spineOnto e acc
spineOnto (EApp f x) acc = spineOnto f (x :: acc)
spineOnto e acc = e :: acc

exprToPat : Expr -> Pat
exprToPat (ELoc _ e) = exprToPat e
exprToPat (EVar "_") = PWild
exprToPat (EVar x) = ctorOrVar x
exprToPat (ELit l) = PLit l
-- PLAN.md #11 §0.4: an integer in pattern (binding-LHS) position stays a
-- monomorphic `Int` pattern; only EXPRESSION-position integers go polymorphic.
exprToPat (ENumLit n _ _) = PLit (LInt n)
exprToPat (EWideLit hi lo _ _) = PLit (LU64 hi lo)
exprToPat (ETuple es) = PTuple (map exprToPat es)
exprToPat (EListLit es) = PList (map exprToPat es)
exprToPat (EBinOp "::" a b _) = PCons (exprToPat a) (exprToPat b)
-- `(x :: _)` in a binding LHS: the `_` was eaten by the left-section rewrite
-- (parenResult/leftSectionOrExpr); recover it as a cons pattern (mirrors the
-- reference `expr_to_pat`'s `SecLeft (a, "::")` case).
exprToPat (ESection (SecLeft a "::")) = PCons (exprToPat a) PWild
exprToPat (EAsPat x sub) = PAs x (Loc "" 0 0 0 0) noBinderId (exprToPat sub)
exprToPat (EOrPat es) = orPatOf (map exprToPat es)
exprToPat (EApp f x) = appToPat (EApp f x)
exprToPat _ = PWild

-- Alternatives joined into one pattern; nested or-patterns are flattened so a
-- POr never sits directly inside a POr.
orPatOf : List Pat -> Pat
orPatOf [p] = p
orPatOf ps = POr (flatMap orAlts ps)

orAlts : Pat -> List Pat
orAlts (POr qs) = qs
orAlts p = [p]

ctorOrVar : String -> Pat
ctorOrVar x
  | isCtorName x = PCon x []
  | otherwise = PVar x (Loc "" 0 0 0 0) noBinderId

-- constructor-application pattern: the spine head must be uppercase
appToPat : Expr -> Pat
appToPat app = appToPatH (spineHead app) (spineList app)

appToPatH : Expr -> List Expr -> Pat
appToPatH (EVar c) spine = appToPatCtor c spine
appToPatH _ _ = PWild

appToPatCtor : String -> List Expr -> Pat
appToPatCtor c spine
  | isCtorName c = PCon c (map exprToPat (dropFirst spine))
  | otherwise = PWild

dropFirst : List a -> List a
dropFirst [] = []
dropFirst (_ :: xs) = xs

isCtorName : String -> Bool
isCtorName s = isCtorChars (stringToChars s)

isCtorChars : Array Char -> Bool
isCtorChars cs
  | arrayLength cs == 0 = False
  | otherwise = isUpper (arrayGetUnsafe 0 cs)

-- Peel transparent ELoc wrappers to expose the underlying expr shape.  Mirrors
-- parser.mly's local `strip` (used before `expr_to_pat`/section detection): the
-- binding-LHS→pattern conversions and section recovery match on the raw node
-- kind, so they must see through the ELoc the atom level now puts on leaves.
stripLoc : Expr -> Expr
stripLoc (ELoc _ e) = stripLoc e
stripLoc e = e

-- #164: a BOUNDED (single-layer) variant of `stripLoc`, for the one call site
-- (`leftSectionOrExpr`) that would otherwise pay for the full recursive unwind at every
-- paren-nesting level.  `parseAtom = located parseAtomRaw` wraps EVERY atom
-- production in exactly one fresh `ELoc`, including a parenthesised expr read
-- back as an atom by its enclosing parens — so at nesting level k the content
-- handed to `leftSectionOrExpr` already carries k accumulated `ELoc` layers,
-- and the full `stripLoc` walked all k of them, on EVERY one of the N levels:
-- O(N) work summed N times = O(N^2) (confirmed by `perf`: 44% self-time here).
--
-- A single-layer strip is sufficient here and nowhere else needs to change: an
-- `EBinOp` node is NEVER itself wrapped in `ELoc` (binop levels stay unwrapped
-- — see the comment on `parseAtom` below), so the only way `stripLoc1`'s single
-- peel could miss a genuine left-section is if a real `EBinOp op lhs (EVar
-- "_")` sat under 2+ ELoc layers here. It cannot: the FIRST paren level that
-- ever sees that raw `EBinOp` directly (unwrapped, e.g. literally `(e op _)`)
-- already runs `leftSectionOrExpr` on it right then and converts it to
-- `ESection` before any further `ELoc` wrapping is ever applied — so a plain
-- `EBinOp` can never survive to be re-discovered two-or-more parens further
-- out. (Multiple PLAIN paren layers around a non-section value, e.g.
-- `((((1))))`, is exactly the pathological case this fixes: one strip reveals
-- another `ELoc`, correctly falls through to "not a section" every time,
-- without walking the rest of the stack.)
stripLoc1 : Expr -> Expr
stripLoc1 (ELoc _ e) = e
stripLoc1 e = e

-- ── The binary-operator ladder ──────────────────────────────────────────
-- Levels, loosest first: 1 `|>`, 2 `>>` `<<`, 3 `||`, 4 `&&`, 5 the
-- comparisons, 6 `::`, 7 `++`, 8 `+` `-`, 9 `*` `/` `%`.  Every level is
-- left-associative except `::`, which is right-associative.  The operands of
-- level 9 are `parseUnary`.  0 means "not a binary operator".
binLevelOf : Token -> Int
binLevelOf TPipeRight = 1
binLevelOf TRCompose = 2
binLevelOf TLCompose = 2
binLevelOf TOr = 3
binLevelOf TAnd = 4
binLevelOf TEqEq = 5
binLevelOf TNeq = 5
binLevelOf TLt = 5
binLevelOf TGt = 5
binLevelOf TLeq = 5
binLevelOf TGeq = 5
binLevelOf TCons = 6
binLevelOf TPlusPlus = 7
binLevelOf TPlus = 8
binLevelOf TMinus = 8
binLevelOf TMinusTight = 8
binLevelOf TStar = 9
binLevelOf TSlash = 9
binLevelOf TMod = 9
binLevelOf _ = 0

binOpName : Token -> String
binOpName TPipeRight = "|>"
binOpName TRCompose = ">>"
binOpName TLCompose = "<<"
binOpName TOr = "||"
binOpName TAnd = "&&"
binOpName TEqEq = "=="
binOpName TNeq = "/="
binOpName TLt = "<"
binOpName TGt = ">"
binOpName TLeq = "<="
binOpName TGeq = ">="
binOpName TCons = "::"
binOpName TPlusPlus = "++"
binOpName TStar = "*"
binOpName TSlash = "/"
binOpName TMod = "%"
binOpName TPlus = "+"
binOpName TMinus = "-"
binOpName TMinusTight = "-"
binOpName _ = panic "binOpName: not a binary operator"

pipeLevel : Int
pipeLevel = 1

orLevel : Int
orLevel = 3

consLevel : Int
consLevel = 6

mulLevel : Int
mulLevel = 9

parsePipe : Parser Expr
parsePipe = ParserE (binLevel pipeLevel)

parseOr : Parser Expr
parseOr = ParserE (binLevel orLevel)

-- One level of the ladder, over the raw `ParserE` representation rather than
-- `defer`-notation: an operand that no operator of this level follows passes
-- up as the very `PR` its level returned, so a descent through all nine levels
-- allocates nothing of its own.
binLevel : Int -> ParseContext -> Int -> PR Expr
binLevel lvl ctx pos
  | lvl > mulLevel = runPWith ctx parseUnary pos
  | otherwise = binLevelRest lvl ctx (binLevel (lvl + 1) ctx pos)

binLevelRest : Int -> ParseContext -> PR Expr -> PR Expr
binLevelRest lvl ctx (r@(POk x pos)) =
  binTry lvl ctx r x pos (peekTok (contextTokens ctx) pos)
binLevelRest _ _ r = r

-- `r` is `POk x pos`, handed back unchanged when `t` is not this level's.
binTry : Int -> ParseContext -> PR Expr -> Expr -> Int -> Token -> PR Expr
binTry lvl ctx r x pos t
  | binLevelOf t == lvl =
    let saved = mark ctx
    binRhs saved lvl ctx x pos t (binLevel (binRhsLevel lvl) ctx (pos + 1))
  | otherwise = r

binRhsLevel : Int -> Int
binRhsLevel lvl
  | lvl == consLevel = lvl
  | otherwise = lvl + 1

-- A right operand that fails recoverably un-consumes the operator: the level
-- yields its left operand at the operator's position.  No looser level then
-- tries that token, since each operator belongs to exactly one level.  `::`
-- stops after one operator because its right operand already took the rest
-- of the chain.
binRhs : ParseMark ->
  Int ->
  ParseContext ->
  Expr ->
  Int ->
  Token ->
  PR Expr ->
  PR Expr
binRhs _ lvl ctx x _ t (POk y q) =
  binNext lvl ctx (POk (EBinOp (binOpName t) x y unminted) q)
binRhs saved _ ctx _ pos _ (PErr _ q)
  | q == pos + 1
    && (isLineEndTok (peekTok (contextTokens ctx) q)
      || isCloseDelim (peekTok (contextTokens ctx) q)
      || peekTok (contextTokens ctx) q == TComma) =
    rewind saved
    PFatal
      (FailMsg "expected an expression after the binary operator")
      (committedErrorPos ctx q)
binRhs saved _ _ x pos _ (PErr _ _) =
  rewind saved
  POk x pos
binRhs saved _ _ _ _ _ ry =
  rewind saved
  ry

binNext : Int -> ParseContext -> PR Expr -> PR Expr
binNext lvl ctx r
  | lvl == consLevel = r
  | otherwise = binLevelRest lvl ctx r

-- ── The 2^62 int literal: legal only under a unary `-` (#171) ───────────────
-- `Int` is 63-bit (`word = (n << 1) | 1`), spanning [-2^62, 2^62-1].  The lexer
-- sees only unsigned digits — the `-` is a separate token — so its magnitude
-- guard (`intLitOverflows`) must admit 2^62 to keep the minimum -2^62 writable,
-- and `parseIntFrom` spells that magnitude as `intMinBound` on the spot.  The
-- SIGN only exists here, in the parser, so this is the only place the remaining
-- asymmetry can be resolved: 2^62 is in range as a negative and out of range as
-- a positive.  C, Rust and Haskell all carry the same INT_MIN literal asymmetry.
--
-- A `TInt` carrying exactly `intMinBound` can ONLY have come from the digit
-- string 2^62 (every admissible smaller magnitude parses non-negative), so the
-- value is an exact discriminator and needs no extra token.  In a PATTERN the
-- positive 2^62 is rejected (`intLitTooBigMsg`); in an EXPRESSION it is the wide
-- literal it spells (`intMinAsWide`), which only a `U64` accepts, so at `Int` the
-- typechecker rejects it with the same text.  The negation sites consume the token
-- themselves and keep the value as-is (`negateLiteral` leaves `intMinBound`
-- fixed), which is the wanted number.  Rejection is FATAL: an enclosing
-- `many (appArg …)` would otherwise swallow a recoverable failure and the user
-- would get "unexpected INT" instead.
--
-- Written as arithmetic rather than as the literal `-4611686018427387904` so
-- that the constant does not depend on the very rule it defines.
intMinLit : Int
intMinLit = 0 - 4611686018427387903 - 1

isIntMinLit : Int -> Bool
isIntMinLit n = n == intMinLit

intLitTooBigMsg : ParseDiagnosticKind
intLitTooBigMsg = PositiveIntOverflow

-- A literal above 2^62 (`TWideInt`) is a `U64` or `I64` literal or nothing: no
-- sign makes it fit `Int`, and a literal PATTERN is typed `Int`/`U8`/`U16`/`U32`/
-- `I32` only (INTEGER-TYPES-DESIGN §3.2 item 5; `U64` and `I64` patterns are not
-- built). A negated one is an ordinary `-`
-- applied to it, which the typechecker accepts only at `I64`.
widePatMsg : String -> ParseDiagnosticKind
widePatMsg lx = WidePattern lx

-- 2^62 written without a sign is the one `TInt` that is really a wide literal:
-- the lexer admits it for `-4611686018427387904`'s sake and it has wrapped to
-- `intMinLit`, so the positive position rebuilds it as the halves of 2^62.
intMinAsWide : String -> Expr
intMinAsWide lx = EWideLit 1073741824 0 unminted lx

-- unary minus, tighter than `*` (a leading `-` in operand position)
parseUnary : Parser Expr
parseUnary = defer
  t <- peekP
  unaryFor t

unaryFor : Token -> Parser Expr
unaryFor TMinus = negUnary
unaryFor TMinusTight = negUnary
unaryFor TBang = defer
  advance
  e <- parseUnary
  deferPure (EUnOp "!" e unminted)
unaryFor _ = parseInfix

-- `-` in operand position.  A directly-following 2^62 literal is FUSED into a
-- single negative `ENumLit` (the token already carries `intMinBound`), which is
-- both the value `EUnOp "-"` would have computed and the only shape that keeps
-- `-4611686018427387904` writable now that the bare literal is rejected.  Same
-- fusion `negLitArgFor` already does for a tight negative argument.  Anything
-- else keeps the ordinary `EUnOp "-"` shape.
negUnary : Parser Expr
negUnary = defer
  t2 <- peek2P
  negUnaryFor t2

negUnaryFor : Token -> Parser Expr
negUnaryFor (TInt n lx)
  | isIntMinLit n = located (defer
    advance
    advance
    deferPure (ENumLit n unminted ("-" ++ lx)))
negUnaryFor _ = defer
  advance
  e <- parseUnary
  deferPure (EUnOp "-" e unminted)

-- backtick infix application (``a `div` b``) has been removed.  The lexer still
-- produces `TBacktickIdent` as a sentinel; a pre-grammar scan surfaces a located
-- hint pointing at the backtick operator.
parseInfix : Parser Expr
parseInfix = parseApp

parseApp : Parser Expr
parseApp = defer
  head <- parseAspat
  args <- many (appArg head)
  deferPure (applyAll head args)

-- One application argument.  Normally an aspat, but a TIGHT negative literal
-- (`f -1` / `f -1.5`, lexed as TMinusTight INT/FLOAT) is grabbed as a
-- negative-numeric argument when the application HEAD is non-numeric.  A numeric
-- head (`5 -1`) never grabs, so the TMinusTight falls through to the
-- binary-minus level (`binLevel`) and stays subtraction (Rule C, head-gated).
appArg : Expr -> Parser Expr
appArg head = ParserE (ctx pos => appArgR head ctx pos)

-- End-of-arguments fast path.  `many (appArg …)` ends every application with a
-- failing attempt whose error it discards, so for a token that cannot start an
-- argument the whole chain is a PErr at `pos`.  The one exception is the nesting
-- cap: `parseAtomNestGo` returns PFatal before it looks at the token, so the
-- chain runs whenever the depth counter is at the cap.
appArgR : Expr -> ParseContext -> Int -> PR Expr
appArgR head ctx pos =
  if appArgStops (peekTok (contextTokens ctx) pos)
    && depthOf ctx < maxNestDepth then
    PErr (FailMsg "expected an application argument") pos
  else
    runPWith
      ctx
      (parseOrElse (negLitArg head) (parseOrElse derefArg parseAspat))
      pos

-- Tokens that no argument alternative accepts without a fatal outcome.
appArgStops : Token -> Bool
appArgStops TEof = True
appArgStops TNewline = True
appArgStops TDedent = True
appArgStops TRParen = True
appArgStops TRBracket = True
appArgStops TRBrace = True
appArgStops TComma = True
appArgStops _ = False

-- #1739 half A: `!` (Ref-dereference) binds TIGHTER than application, so `f !r`
-- is `f (!r)` — the OCaml-standard Ref ergonomics this bite exists to deliver.
-- Without this arm `!` sits at `parseUnary`, BELOW application, and every
-- argument-position read needs parens (`f (!r)`) where `.value` needed none
-- (`f r.value`) — which would make the spelling this bite introduces clumsier
-- than the one it replaces, at ~a third of the Ref reads in the tree.
--
-- Unambiguous, and only because half B already ran: `!=` is now its own `TBangEq`
-- token, so a `TBang` in argument position can ONLY begin a unary deref. There is
-- no binary `!`, so no `a ! b` reading competes for it.
--
-- The operand is an ASPAT, not a `parseUnary` — `!` takes exactly one atom, the
-- same shape the tight-negative-literal arm above takes. `!!r` (deref of a deref)
-- therefore needs parens; that is deliberate, since `!` chains are vanishingly
-- rare and the alternative re-opens the greedy-operand ambiguity `-` had.
derefArg : Parser Expr
derefArg = defer
  t <- peekP
  derefArgFor t

derefArgFor : Token -> Parser Expr
derefArgFor TBang = defer
  advance
  e <- parseAspat
  deferPure (EUnOp "!" e unminted)
derefArgFor _ = failP "not a tight deref argument"

-- The numeric-head test (`headIsNumeric`) walks the head's ELoc chain, so it runs
-- only once the next token is TMinusTight, the one token it can change the answer for.
negLitArg : Expr -> Parser Expr
negLitArg head = defer
  t <- peekP
  negLitArgGate head t

negLitArgGate : Expr -> Token -> Parser Expr
negLitArgGate head TMinusTight =
  if headIsNumeric head then
    failP "numeric head: tight minus stays subtraction"
  else
    negLitArgTight
negLitArgGate _ _ = failP "not a tight negative literal argument"

negLitArgTight : Parser Expr
negLitArgTight = defer
  t2 <- peek2P
  negLitArgFor TMinusTight t2

negLitArgFor : Token -> Token -> Parser Expr
negLitArgFor TMinusTight (TInt n lx) = defer
  advance
  advance
  deferPure (ENumLit (negateLiteral n) unminted ("-" ++ lx))
negLitArgFor TMinusTight (TWideInt hi lo lx) = defer
  advance
  advance
  deferPure (EUnOp "-" (EWideLit hi lo unminted lx) unminted)
negLitArgFor TMinusTight (TFloat f) = defer
  advance
  advance
  deferPure (ELit (LFloat (negate f)))
negLitArgFor _ _ = failP "not a tight negative literal argument"

-- Is the application head a numeric literal (so a following `-N` is subtraction,
-- not a negative argument)?  Strip the transparent ELoc wrapper first.
headIsNumeric : Expr -> Bool
headIsNumeric (ELoc _ e) = headIsNumeric e
headIsNumeric (ENumLit _ _ _) = True
headIsNumeric (EWideLit _ _ _ _) = True
headIsNumeric (ELit (LInt _)) = True
headIsNumeric (ELit (LFloat _)) = True
headIsNumeric _ = False

-- the as-pattern operator level (`expr_aspat`): `IDENT AS_AT postfix` → EAsPat
-- (a binding-LHS as-pattern, e.g. a lambda param `xs@rest =>`); else a postfix.
-- AS_AT is only emitted by the lexer when `@` directly follows an identifier.
parseAspat : Parser Expr
parseAspat = parseOrElse parseAspatAt parsePostfix

parseAspatAt : Parser Expr
parseAspatAt = located parseAspatAtRaw

parseAspatAtRaw : Parser Expr
parseAspatAtRaw = defer
  x <- identNameP
  expectTok TAsAt
  sub <- parsePostfix
  deferPure (EAsPat x sub)

applyAll : Expr -> List Expr -> Expr
applyAll head [] = head
applyAll head (a :: rest) = applyAll (EApp head a) rest

parsePostfix : Parser Expr
parsePostfix = defer
  e <- parseAtom
  postfixTail e

postfixTail : Expr -> Parser Expr
postfixTail e = ParserE (ctx pos => postfixTailR e ctx pos)

-- Only `[`-tight and `.` can continue a postfix chain.  For any other next
-- token both tails fail without consuming (at this same pos), so the chain
-- would pick `deferPure e`: return that directly and skip building the chain.
postfixTailR : Expr -> ParseContext -> Int -> PR Expr
postfixTailR e ctx pos = match peekTok (contextTokens ctx) pos
  TLBracketTight => runPWith ctx (postfixChain e) pos
  TDot => runPWith ctx (postfixChain e) pos
  _ => POk e pos

postfixChain : Expr -> Parser Expr
postfixChain e =
  parseOrElse (bracketIndexTail e) (parseOrElse (dotTail e) (deferPure e))

-- bare `a[i]` postfix indexing (no dot) — fires only on the adjacency-lexed
-- TLBracketTight token, so a spaced `a [i]` (application to a list literal)
-- is untouched. Builds the SAME EIndex node dotTail's `.[i]` produces. Bare
-- slice `a[i..j]`/`a[i..=j]` is deferred (#17) — clean error, not ESlice.
bracketIndexTail : Expr -> Parser Expr
bracketIndexTail e = defer
  expectTok TLBracketTight
  lo <- parseExpr
  t <- peekP
  bracketIndexRest e lo t

bracketIndexRest : Expr -> Expr -> Token -> Parser Expr
bracketIndexRest _ _ TDotDot =
  failP "bare slice `a[i..j]` is not supported; write `a.[i..j]`"
bracketIndexRest _ _ TDotDotEq =
  failP "bare slice `a[i..=j]` is not supported; write `a.[i..=j]`"
bracketIndexRest e lo TRBracket = finishBracketIndex e lo
bracketIndexRest _ _ _ = failP "expected `]` to close the index"

-- shared by `bracketIndexRest`/`indexOrSliceRest`'s closing-`]` clause (#602):
-- both readers land here once the index expression is complete.
finishBracketIndex : Expr -> Expr -> Parser Expr
finishBracketIndex e lo = defer
  advance
  postfixTail (EIndex e lo)

-- after a `.`: a field access `.field`, an index `.[i]`, or a slice `.[lo..hi]`
dotTail : Expr -> Parser Expr
dotTail e = defer
  expectTok TDot
  t <- peekP
  dotFor e t

dotFor : Expr -> Token -> Parser Expr
dotFor e TLBracket = indexOrSlice e
dotFor e _ = defer
  f <- identNameP
  postfixTail (EFieldAccess e f unminted)

indexOrSlice : Expr -> Parser Expr
indexOrSlice e = defer
  expectTok TLBracket
  lo <- parseExpr
  t <- peekP
  indexOrSliceRest e lo t

indexOrSliceRest : Expr -> Expr -> Token -> Parser Expr
indexOrSliceRest e lo TDotDot = sliceHi e lo False
indexOrSliceRest e lo TDotDotEq = sliceHi e lo True
indexOrSliceRest e lo TRBracket = finishBracketIndex e lo
indexOrSliceRest _ _ _ = failP "expected `..`, `..=` or `]` in the index"

sliceHi : Expr -> Expr -> Bool -> Parser Expr
sliceHi e lo incl = defer
  advance
  hi <- parseExpr
  expectTok TRBracket
  postfixTail (ESlice e lo hi incl)

-- #77: bound recursion depth so a pathologically deep input fails with a
-- clean, located diagnostic instead of exhausting the native call stack (a
-- hang or a SEGFAULT/exit 134). `parseAtom` (below) is the single shared
-- re-entry point for EVERY recursive expression form — parenthesised/tuple
-- exprs, list literals, if/let/match/do, and (through the operand ladder)
-- nested application — so bounding depth here bounds all of them, whichever
-- bracket or keyword does the nesting. #77 F1: also shared by `parsePatAtom`
-- and `parseTyAtom`'s own wrappers below, closing the pattern- and
-- type-grammar gaps the end-of-sprint review found; an expr-only input still
-- only ever increments here, so `parseAtom`'s own boundary does not move.
-- Comfortably above any depth a hand-written or generated program plausibly
-- needs (this repo's own deepest perf-corpus shape nests a few thousand
-- levels) while staying well inside the 256MB GC-worker stack every `medaka`
-- invocation runs on (AGENTS.md [B-ENV]).
maxNestDepth : Int
maxNestDepth = 20000

nestTooDeepMsg : String
nestTooDeepMsg =
  "expression nesting too deep (limit \{intToString maxNestDepth}); split this expression into named intermediate bindings"

-- Atom level (`expr_atom` + the statement-form productions in parser.mly).
-- Wrapped in a transparent ELoc capturing the atom's token span, mirroring
-- parser.mly where every atom and every let/if/match/function/do production is
-- `ELoc (of_pos $startpos $endpos, …)`.  Binop/app/unary/postfix levels stay
-- un-wrapped (exactly like parser.mly's `mkbin`/`EApp` rules), so their span is
-- implicit from their wrapped leaf operands.
--
-- The engine restores the shared invocation depth on success and both failure
-- constructors; a decrement sequenced through a bind would miss failures.
parseAtom : Parser Expr
parseAtom =
  withDepth maxNestDepth (FailMsg nestTooDeepMsg) (ParserE atomRawLocated)

atomRawLocated : ParseContext -> Int -> PR Expr
atomRawLocated ctx pos = match runPWith ctx parseAtomRaw pos
  POk e q => POk (ELoc (locOfSpan ctx pos q) e) q
  PErr f q => PErr f q
  PFatal f q => PFatal f q

parseAtomRaw : Parser Expr
parseAtomRaw = defer
  t <- peekP
  match t
    TInt n lx if isIntMinLit n => emit (intMinAsWide lx)
    TInt n lx => emit (ENumLit n unminted lx)
    TWideInt hi lo lx => emit (EWideLit hi lo unminted lx)
    TFloat f => emit (ELit (LFloat f))
    TString s => emit (ELit (LString s))
    TChar s => emit (ELit (LChar s))
    TByte n => emit (ELit (LByte n))
    TIdent x => emit (EVar x)
    TUpper x => parseUpperAtom x
    TUnderscore => emit (EVar "_")
    TLParen => parseParen
    TLBracket => parseListE
    TLArray => parseArray
    TLBrace => parseRecordUpdate
    TIf => parseIf
    TLet => parseLet
    TMatch => parseMatch
    TDo => parseDo
    TDefer => parseDefer
    TInterpOpen _ => parseInterp
    _ => failP "expected an expression"

-- a constructor (`Upper`) atom, or a record literal `Upper { field = e, … }`
parseUpperAtom : String -> Parser Expr
parseUpperAtom x = defer
  advance
  n <- upperQualTail x
  t <- peekP
  upperTail n t

upperTail : String -> Token -> Parser Expr
upperTail x TLBrace = upperBrace x
upperTail x _ = deferPure (EVar x)

-- After `Con {`: a constructor-tagged variant update `Con { e | f = v, … }`
-- (a `|` follows the leading expr), or the unified `Con { kv_or_e, … }` form,
-- which classifies into a record create (`f = v`
-- fields + puns), a map literal (`k => v` entries), or a set literal (bare
-- elements).  `parseOrElse` backtracks, so try the update form first — its leading
-- `parseExpr` fails fast at the first `=`/`=>`/`,`/`}` (no `|`).
upperBrace : String -> Parser Expr
upperBrace x = defer
  expectTok TLBrace
  parseOrElse (variantUpdateTail x) (braceItems x)

variantUpdateTail : String -> Parser Expr
variantUpdateTail x = defer
  e <- parseExpr
  expectTok TPipe
  fields <- sepBy1 recordFieldExpr (expectTok TComma)
  optTrailingComma
  expectTok TRBrace
  deferPure (EVariantUpdate x e (map (desugarDottedField e) fields))

-- a kv_or_e item: a record field `f = v`, a map entry `k => v`, or a bare
-- element/pun.  The classification of the whole brace picks the node kind.
data KvItem = KvField String Expr | KvKV Expr Expr | KvElem Expr

braceItems : String -> Parser Expr
braceItems x = defer
  t <- peekP
  braceItemsFor x t

braceItemsFor : String -> Token -> Parser Expr
braceItemsFor x TRBrace = defer
  advance
  deferPure (classifyBrace x [])
braceItemsFor x _ = defer
  items <- sepBy1 parseKvOrE (expectTok TComma)
  optTrailingComma
  expectTok TRBrace
  deferPure (classifyBrace x items)

-- `IDENT = expr` → field; `key => expr` → map entry; else a bare element.  The
-- key is parsed at the pipe level (like the reference `expr_pipe`) so a `=>`
-- ends the key rather than starting a lambda.
parseKvOrE : Parser KvItem
parseKvOrE =
  parseOrElse parseKvField (parseOrElse parseKvBlockElem parseKvKVorElem)

-- Gate B: a bare-INDENT block as a record-field / set-element value.
parseKvBlockElem : Parser KvItem
parseKvBlockElem = defer
  e <- parseBracketBlock
  deferPure (KvElem e)

parseKvField : Parser KvItem
parseKvField = defer
  p <- getPos
  name <- identNameP
  expectTok TEqual
  e <- committedExpr "expected a record field value after `=`" parseBracketElem
  recordUnitStart 4 p
  deferPure (KvField name e)

parseKvKVorElem : Parser KvItem
parseKvKVorElem = defer
  e <- parsePipe
  t <- peekP
  kvKVorElemFor e t

kvKVorElemFor : Expr -> Token -> Parser KvItem
kvKVorElemFor e TFatArrow = defer
  advance
  v <- parseExpr
  deferPure (KvKV e v)
kvKVorElemFor e _ = deferPure (KvElem e)

-- classify: any field → record create (Elem puns to `n = n`); else any map
-- entry → map literal; else → set literal.  (Mixed-kind braces are user errors.)
classifyBrace : String -> List KvItem -> Expr
classifyBrace name items
  | anyField items = ERecordCreate name (map kvToField items)
  | anyKV items = EMapLit name (kvPairs items)
  | otherwise = ESetLit name (kvElems items)

anyField : List KvItem -> Bool
anyField [] = False
anyField ((KvField _ _) :: _) = True
anyField (_ :: rest) = anyField rest

anyKV : List KvItem -> Bool
anyKV [] = False
anyKV ((KvKV _ _) :: _) = True
anyKV (_ :: rest) = anyKV rest

kvToField : KvItem -> FieldAssign
kvToField (KvField n e) = FieldAssign n e
kvToField (KvElem e) = kvElemToField (stripLoc e)
kvToField _ = FieldAssign "_" (ELit LUnit)

-- a bare element in a record-literal brace is a pun `{ x }` → `{ x = x }`.
kvElemToField : Expr -> FieldAssign
kvElemToField (EVar n) = FieldAssign n (EVar n)
kvElemToField _ = FieldAssign "_" (ELit LUnit)

kvPairs : List KvItem -> List (Expr, Expr)
kvPairs [] = []
kvPairs ((KvKV k v) :: rest) = (k, v) :: kvPairs rest
kvPairs (_ :: rest) = kvPairs rest

kvElems : List KvItem -> List Expr
kvElems [] = []
kvElems ((KvElem e) :: rest) = e :: kvElems rest
kvElems (_ :: rest) = kvElems rest

-- record update `{ e | field = e, … }`, including nested dotted-path fields
-- `{ p | a.b.c = v }` desugared to nested ERecordUpdates.
parseRecordUpdate : Parser Expr
parseRecordUpdate = defer
  expectTok TLBrace
  e <- parseExpr
  expectTok TPipe
  fields <- sepBy1 recordFieldExpr (expectTok TComma)
  optTrailingComma
  expectTok TRBrace
  deferPure (ERecordUpdate e (map (desugarDottedField e) fields) unminted)

-- a record-update field `path = expr` (dotted path) or a pun `name`
-- (a dotted-path update field).
recordFieldExpr : Parser (List String, Expr)
recordFieldExpr = defer
  path <- sepBy1 identNameP (expectTok TDot)
  t <- peekP
  recordFieldExprRest path t

recordFieldExprRest : List String -> Token -> Parser (List String, Expr)
recordFieldExprRest path TEqual = defer
  advance
  e <- committedExpr "expected a record field value after `=`" parseBracketElem
  deferPure (path, e)
recordFieldExprRest [x] _ = deferPure ([x], EVar x)
recordFieldExprRest _ _ =
  failP "expected `=` after the field name in a record update"

-- desugar a dotted-path update field against the update base:
-- `{ base | a.b.c = v }` → ("a", { base.a | b = { base.a.b | c = v } })
desugarDottedField : Expr -> (List String, Expr) -> FieldAssign
desugarDottedField base (path, value) = match path
  [field] => FieldAssign field value
  field :: rest =>
    FieldAssign field (dottedGo (EFieldAccess base field unminted) rest value)
  [] => FieldAssign "_" value

dottedGo : Expr -> List String -> Expr -> Expr
dottedGo cur [f] value = ERecordUpdate cur [FieldAssign f value] unminted
dottedGo cur (f :: fs) value =
  ERecordUpdate
    cur
    [FieldAssign f (dottedGo (EFieldAccess cur f unminted) fs value)]
    unminted
dottedGo cur [] value = value

-- interpolated string: INTERP_OPEN <expr> (INTERP_MID <expr>)* INTERP_END,
-- assembled into alternating InterpStr / InterpExpr parts
parseInterp : Parser Expr
parseInterp = defer
  s0 <- interpOpenStr
  rest <- interpRest
  deferPure (EStringInterp (InterpStr s0 :: rest))

interpOpenStr : Parser String
interpOpenStr = defer
  t <- peekP
  interpOpenFor t

interpOpenFor : Token -> Parser String
interpOpenFor (TInterpOpen s) = emit s
interpOpenFor _ = failP "expected interpolation open"

interpRest : Parser (List InterpPart)
interpRest = defer
  e <- parseExpr
  t <- peekP
  interpRestFor e t

interpRestFor : Expr -> Token -> Parser (List InterpPart)
interpRestFor e (TInterpMid s) = defer
  advance
  rest <- interpRest
  deferPure (InterpExpr e :: InterpStr s :: rest)
interpRestFor e (TInterpEnd s) = defer
  advance
  deferPure [InterpExpr e, InterpStr s]
interpRestFor e _ = failP "expected interpolation mid/end"

-- Bracket block-expressions (LAYOUT-BRACKETS-DESIGN.md, Gate B).  The locked
-- herald set is match/do/record/bare-INDENT block.  All of those
-- EXCEPT the bare-INDENT block already reach bracket element positions because
-- parseAtomRaw dispatches TMatch/TDo/TDefer (and records via TUpper/TLBrace)
-- as atoms, so parseExpr reaches them.  The one herald NOT reachable from the
-- expression chain is the bare-INDENT block (it lives only in the decl-body
-- `indentedBody`).  parseBracketBlock is the dedicated, contained reader for it;
-- parseBracketElem admits it in bracket element positions WITHOUT folding the
-- bare-INDENT block into parseAtom/parseExpr generally (mirrors parser.mly's
-- `bracket_block`/`bracket_elem`).
-- NOTE (staging): the LEXER does not yet emit INDENT/NEWLINE/DEDENT inside
-- brackets (Stage 3, pending), so these readers are not reachable on real input
-- yet — they exist so the grammar has a target the future lexer tokens land on.
parseBracketBlock : Parser Expr
parseBracketBlock = defer
  expectTok TIndent
  stmts <- parseStmts
  expectTok TDedent
  unrecordSoleStmt stmts
  deferPure (blockOrExpr stmts)

-- A one-expression block is unwrapped to that expression (`blockOrExpr`), so
-- it is not a statement of its own: forget the unit start `parseStmt` recorded
-- for it, or the formatter would take a hung body's first line for the start
-- of the statement that owns it.
unrecordSoleStmt : List DoStmt -> Parser Unit
unrecordSoleStmt [DoExpr _] = forgetLatestUnitStart
unrecordSoleStmt _ = deferPure ()

-- a bracket element: a bare-INDENT block, or an ordinary expression.
parseBracketElem : Parser Expr
parseBracketElem = parseOrElse parseBracketBlock parseExpr

parseParen : Parser Expr
parseParen = defer
  expectTok TLParen
  t <- peekP
  committedExpr "expected a complete parenthesized expression" (parenFor t)

committedExpr : String -> Parser Expr -> Parser Expr
committedExpr msg p = ParserE (ctx pos => match runPWith ctx p pos
  PErr f q =>
    let loc = committedErrorPos ctx q
    let reason = match f
      FailExpect TNewline TRParen =>
        if loc > q then FailMsg "unexpected end of input; expected `)`" else f
      _ => if q > pos then f else FailMsg msg
    PFatal reason loc
  r => r)

committedErrorPos : ParseContext -> Int -> Int
committedErrorPos ctx q =
  let toks = contextTokens ctx
  let offs = contextOffsets ctx
  if q > 0
    && q < arrayLength offs
    && fst (arrayGetUnsafe q offs) == 0
    && peekTok toks q == TNewline
    && peekTok toks (q + 1) == TEof then
    q + 1
  else
    q

-- inside parens: `()` unit, an operator section `(op)`/`(op e)`/`(e op _)`,
-- a tuple, or a plain parenthesised expression
parenFor : Token -> Parser Expr
parenFor TRParen = emit (ELit LUnit)
parenFor TMinus = parseOrElse bareMinusSection parseParenExpr
parenFor TMinusTight = parseOrElse bareMinusSection parseParenExpr
parenFor t = parenSectionOr t

parenSectionOr : Token -> Parser Expr
parenSectionOr t = match sectionOpStr t
  Some op => parseSectionOp op
  None => parseParenExpr

-- `(-)` is a bare section; `(-e)` is a parenthesised unary minus (parseOrElse falls
-- through). MINUS is excluded from the SecRight form, matching the grammar.
bareMinusSection : Parser Expr
bareMinusSection = defer
  expectMinus
  expectTok TRParen
  deferPure (ESection (SecBare "-"))

-- Accept either spacing of bare minus (TMinus or the asymmetric-spaced
-- TMinusTight) wherever a `-` operator token is required.
expectMinus : Parser Unit
expectMinus = defer
  t <- peekP
  expectMinusGo t

expectMinusGo : Token -> Parser Unit
expectMinusGo TMinus = emit ()
expectMinusGo TMinusTight = emit ()
expectMinusGo _ = failP "expected `-`"

parseSectionOp : String -> Parser Expr
parseSectionOp op = defer
  advance
  t <- peekP
  sectionTail op t

sectionTail : String -> Token -> Parser Expr
sectionTail op TRParen = defer
  advance
  deferPure (ESection (SecBare op))
sectionTail op _ = defer
  e <- parseExpr
  expectTok TRParen
  deferPure (ESection (SecRight op e))

parseParenExpr : Parser Expr
parseParenExpr = defer
  es <- sepBy1 parseOrAltsExpr (expectTok TComma)
  optTrailingCommaTuple es
  expectTok TRParen
  deferPure (parenResult es)

-- `e1 | e2 | ...` inside parentheses: the expression twin of an or-pattern.
-- `|` has no other meaning in a parenthesized expression.
parseOrAltsExpr : Parser Expr
parseOrAltsExpr = defer
  e <- parseBracketElem
  rest <- many orAltExpr
  deferPure (orExprOf e rest)

orAltExpr : Parser Expr
orAltExpr = defer
  expectTok TPipe
  parseBracketElem

orExprOf : Expr -> List Expr -> Expr
orExprOf e [] = e
orExprOf e rest = EOrPat (e :: rest)

parenResult : List Expr -> Expr
parenResult [e] = leftSectionOrExpr e
parenResult es = ETuple es

-- a single `(e op _)` becomes a left section; otherwise just the inner expr.
-- The `_` placeholder is a wrapped atom (`ELoc (EVar "_")`), so strip the RHS
-- operand before matching (mirrors parser.mly's local `strip` in this rule).
-- On no match we return the ORIGINAL expr untouched (keeping its wrappers).
-- Both strips are the BOUNDED `stripLoc1` (see its comment) — `e` is where the
-- O(N^2) lived (its `ELoc` depth grows with paren-nesting level); `rhs` is
-- always the immediate right operand of a directly-unwrapped `EBinOp`, so its
-- depth is O(1) regardless of N either way.
leftSectionOrExpr : Expr -> Expr
leftSectionOrExpr e = leftSectionGo e (stripLoc1 e)

leftSectionGo : Expr -> Expr -> Expr
leftSectionGo orig (EBinOp op lhs rhs _) =
  leftSectionRhs orig op lhs (stripLoc1 rhs)
leftSectionGo orig _ = orig

leftSectionRhs : Expr -> String -> Expr -> Expr -> Expr
leftSectionRhs _ op lhs (EVar "_") = ESection (SecLeft lhs op)
leftSectionRhs orig _ _ _ = orig

-- section_op (no MINUS): tokens that can head an operator section
sectionOpStr : Token -> Option String
sectionOpStr TPlus = Some "+"
sectionOpStr TStar = Some "*"
sectionOpStr TSlash = Some "/"
sectionOpStr TEqEq = Some "=="
sectionOpStr TNeq = Some "/="
sectionOpStr TLt = Some "<"
sectionOpStr TGt = Some ">"
sectionOpStr TLeq = Some "<="
sectionOpStr TGeq = Some ">="
sectionOpStr TAnd = Some "&&"
sectionOpStr TOr = Some "||"
sectionOpStr TCons = Some "::"
sectionOpStr TPlusPlus = Some "++"
sectionOpStr TPipeRight = Some "|>"
sectionOpStr TRCompose = Some ">>"
sectionOpStr TLCompose = Some "<<"
sectionOpStr _ = None

parseListE : Parser Expr
parseListE = defer
  expectTok TLBracket
  t <- peekP
  listFor t

listFor : Token -> Parser Expr
listFor TRBracket = emit (EListLit [])
listFor _ = defer
  first <- parseBracketElem
  t <- peekP
  listRest first t

-- after the first element: `..`/`..=` range, `,` more elements, or `]` close
listRest : Expr -> Token -> Parser Expr
listRest first TDotDot = rangeAfter first False
listRest first TDotDotEq = rangeAfter first True
listRest first TComma = defer
  advance
  t <- peekP
  listAfterComma first t
listRest first TRBracket = finishSingletonList first
listRest _ _ = failP "expected `,`, `..`, `..=` or `]` in the list"

-- shared by `listRest`/`listAfterComma`'s closing-`]` clause (#602): both a
-- bare single-element list (`[x]`) and a single-element list with a trailing
-- comma (`[x,]`) land here once the closing bracket is seen.
finishSingletonList : Expr -> Parser Expr
finishSingletonList first = defer
  advance
  deferPure (EListLit [first])

-- after the first element and a comma: a `]` here is a trailing comma on a
-- single-element list (`[x,]`); otherwise parse the remaining elements (and
-- accept a trailing comma after them too).
listAfterComma : Expr -> Token -> Parser Expr
listAfterComma first TRBracket = finishSingletonList first
listAfterComma first _ = defer
  rest <- sepBy1 parseBracketElem (expectTok TComma)
  optTrailingComma
  expectTok TRBracket
  deferPure (EListLit (first :: rest))

rangeAfter : Expr -> Bool -> Parser Expr
rangeAfter lo incl = defer
  advance
  hi <- parseExpr
  expectTok TRBracket
  deferPure (ERangeList lo hi incl)

-- array literal `[| e, … |]`
parseArray : Parser Expr
parseArray = defer
  expectTok TLArray
  t <- peekP
  arrayFor t

arrayFor : Token -> Parser Expr
arrayFor TRArray = emit (EArrayLit [])
arrayFor _ = defer
  first <- parseBracketElem
  t <- peekP
  arrayRest first t

-- after the first element: `..`/`..=` array range, `,` more elements, or `|]`
arrayRest : Expr -> Token -> Parser Expr
arrayRest first TDotDot = arrayRangeAfter first False
arrayRest first TDotDotEq = arrayRangeAfter first True
arrayRest first TComma = defer
  advance
  t <- peekP
  arrayAfterComma first t
arrayRest first TRArray = finishSingletonArray first
arrayRest _ _ = failP "expected `,`, `..`, `..=` or `|]` in the array"

-- shared by `arrayRest`/`arrayAfterComma`'s closing-`|]` clause (#602): both a
-- bare single-element array (`[|x|]`) and one with a trailing comma
-- (`[|x,|]`) land here once the closing delimiter is seen.
finishSingletonArray : Expr -> Parser Expr
finishSingletonArray first = defer
  advance
  deferPure (EArrayLit [first])

-- single-element trailing comma `[|x,|]`: a `|]` after the comma closes it.
arrayAfterComma : Expr -> Token -> Parser Expr
arrayAfterComma first TRArray = finishSingletonArray first
arrayAfterComma first _ = defer
  rest <- sepBy1 parseBracketElem (expectTok TComma)
  optTrailingComma
  expectTok TRArray
  deferPure (EArrayLit (first :: rest))

arrayRangeAfter : Expr -> Bool -> Parser Expr
arrayRangeAfter lo incl = defer
  advance
  hi <- parseExpr
  expectTok TRArray
  deferPure (ERangeArray lo hi incl)

parseIf : Parser Expr
parseIf = defer
  expectTok TIf
  t <- peekP
  ifKind t

ifKind : Token -> Parser Expr
ifKind TLet = ifLet
ifKind _ = ifPlain

-- `if let pat = e then t else f` desugars (at parse) to a two-arm match, exactly
-- to `match e { pat => t; _ => f }`.  Always has an else.
ifLet : Parser Expr
ifLet = defer
  expectTok TLet
  pat <- parsePat
  expectTok TEqual
  scrut <- parseExpr
  expectTok TThen
  thenE <- parseExpr
  expectTok TElse
  elseE <- parseExpr
  deferPure (EMatch scrut [Arm pat [] thenE, Arm PWild [] elseE])

ifPlain : Parser Expr
ifPlain = defer
  cond <- parseExpr
  expectTok TThen
  thenE <- parseBranch
  elseE <- elseBranch
  deferPure (EIf cond thenE elseE)

-- `else` is optional; an else-less `if` defaults the else branch to unit, left
-- without an `ELoc` so the typechecker can tell it from a written `()`
-- (`isOmittedElse`, `compiler/types/typecheck.mdk`)
elseBranch : Parser Expr
elseBranch = parseOrElse elsePresent (deferPure (ELit LUnit))

elsePresent : Parser Expr
elsePresent = defer
  expectTok TElse
  parseBranch

-- a then/else branch is either an inline expr or an indented statement block
parseBranch : Parser Expr
parseBranch = parseOrElse branchBlock parseExpr

-- Same offside-block production as `parseBracketBlock`/`indentedBody` (#602).
branchBlock : Parser Expr
branchBlock = parseBracketBlock

-- expression-level `let`: `let [mut] pat = e in e2`, function-let
-- `let f a… = e in e2`, annotated `let [mut] x : ty = e in e2`, and
-- mutually-recursive `let rec f = … with g = … in e2` (→ ELetGroup).
parseLet : Parser Expr
parseLet = defer
  ctx <- contextP
  s <- getPos
  expectTok TLet
  t <- peekP
  e <- letExprKind t
  deferPure (atLetSite (locOfSpan ctx s (s + 1)) e)

letExprKind : Token -> Parser Expr
-- beta mutability model: `let mut` has been removed (bindings are immutable).
-- It is rejected here at the parser so the `mut` flag is never constructed
-- anywhere downstream. See `letMutRemovedMsg`.
letExprKind TMut = failP letMutRemovedMsg
letExprKind TRec = letRecExpr
letExprKind (TIdent name) = letIdentExpr name
letExprKind _ = letPatExpr

-- IDENT-led: function-let `let f a… = e` (params present), annotated
-- `let x : ty = e`, or plain `let x = e`, each followed by `in e2`
letIdentExpr : String -> Parser Expr
letIdentExpr name = defer
  ctx <- contextP
  s <- getPos
  advance
  params <- many parseParamPat
  t <- peekP
  letIdentExprRest name (locOfSpan ctx s (s + 1)) params t

letIdentExprRest : String -> Loc -> List Pat -> Token -> Parser Expr
letIdentExprRest name nameLoc [] TColon = defer
  advance
  ty <- parseTy
  expectTok TEqual
  e1 <- parseExpr
  expectTok TIn
  e2 <- parseExpr
  deferPure
    (ELet noDeclLoc False (PVar name nameLoc noBinderId) (EAnnot e1 ty) e2)
letIdentExprRest name nameLoc [] TEqual = defer
  advance
  e1 <- parseExpr
  expectTok TIn
  e2 <- parseExpr
  deferPure (ELet noDeclLoc False (PVar name nameLoc noBinderId) e1 e2)
letIdentExprRest name nameLoc params TEqual = defer
  advance
  e1 <- parseExpr
  expectTok TIn
  e2 <- parseExpr
  deferPure
    (ELet noDeclLoc True (PVar name nameLoc noBinderId) (curryLam params e1) e2)
letIdentExprRest _ _ _ _ = failP "expected `:` or `=` after the `let` name"

-- non-IDENT pattern: `let (a, b) = e in e2`, `let Some x = e in e2`, …
letPatExpr : Parser Expr
letPatExpr = defer
  pat <- parsePat
  expectTok TEqual
  e1 <- parseExpr
  expectTok TIn
  e2 <- parseExpr
  deferPure (ELet noDeclLoc False pat e1 e2)

-- `let rec f a… = e in e2` → ELetGroup with a single binding (Phase 57 inline
-- form). Mutual-recursion grouping via `with` has been removed — each
-- recursive binding is its own `let rec`.
letRecExpr : Parser Expr
letRecExpr = defer
  expectTok TRec
  clause <- letRecInlineClause
  expectTok TIn
  e2 <- parseExpr
  deferPure (ELetGroup (coalesceClauses [clause]) e2)

letRecInlineClause : Parser (String, List Pat, Expr, Loc)
letRecInlineClause = defer
  ctx <- contextP
  s <- getPos
  name <- identNameP
  pats <- many parseParamPat
  expectTok TEqual
  body <- parseExpr
  deferPure (name, pats, body, locOfSpan ctx s (s + 1))

parseMatch : Parser Expr
parseMatch = defer
  matchPos <- getPos
  expectTok TMatch
  scrut <- parseExpr
  expectTok TIndent
  arms <- parseArms matchPos
  expectTok TDedent
  deferPure (EMatch scrut arms)

parseArms : Int -> Parser (List Arm)
parseArms matchPos = defer
  skipNewlines
  armsLoop matchPos

armsLoop : Int -> Parser (List Arm)
armsLoop matchPos = defer
  t <- peekP
  if t == TDedent then deferPure [] else armsCons matchPos

armsCons : Int -> Parser (List Arm)
armsCons matchPos = defer
  a <- parseArm matchPos
  skipNewlines
  rest <- armsLoop matchPos
  deferPure (a :: rest)

parseArm : Int -> Parser Arm
parseArm matchPos = ParserE (ctx pos => match runPWith ctx parseArmPat pos
  POk pat q => runPWith ctx (parseArmRest pos pat) q
  PFatal f q => PFatal f q
  PErr _ _ =>
    let hint =
      if contextHasTab ctx then
        None
      else
        matchContinuationHint
          (contextTokens ctx)
          (contextOffsets ctx)
          (contextLineStarts ctx)
          matchPos
          pos
    let kind = optionOr ExpectedMatchArm hint
    PFatal (FailProblem kind) pos)

parseArmRest : Int -> Pat -> Parser Arm
parseArmRest p pat = defer
  guards <- armGuardOpt
  matchArrow
  body <- matchBody
  recordUnitStart 0 p
  deferPure (Arm pat guards body)

matchArrow : Parser Unit
matchArrow = ParserE (ctx pos => match runPWith ctx (expectTok TFatArrow) pos
  PErr _ q => PFatal (FailProblem ExpectedMatchArrow) q
  r => r)

matchBody : Parser Expr
matchBody = ParserE
  (ctx pos => match runPWith ctx (parseOrElse branchBlock parseBodyExpr) pos
    PErr f q => PFatal f q
    r => r)

-- optional match-arm guard: `if g, g…` (NB: uses `if`, not `|`)
armGuardOpt : Parser (List Guard)
armGuardOpt = defer
  t <- peekP
  armGuardFor t

-- A `|` after a match-arm pattern joins alternatives (`parseArmPat`), so by the
-- time a guard is read, no `|` can remain.  Match-arm guards use `if`; the
-- equation (function-clause) guards use `|`.
armGuardFor : Token -> Parser (List Guard)
armGuardFor TIf = defer
  advance
  sepBy1 parseGuard (expectTok TComma)
armGuardFor _ = deferPure []

-- A match-arm pattern: alternatives `p | q | ...` joined by a bare `|`.  A `|`
-- followed by something that is not a pattern ending the alternative (`=>`,
-- `if`, another `|`) is the Haskell guard habit (`pat | cond => ...`) and
-- keeps the targeted `if` message; it is committed (`barSteer`) so the steer
-- survives `armsLoop`'s backtracking (#591).
parseArmPat : Parser Pat
parseArmPat = defer
  p <- parsePat
  t <- peekP
  armPatAlts [p] t

armPatAlts : List Pat -> Token -> Parser Pat
armPatAlts acc TPipe = barSteer (defer
  advance
  q <- parsePat
  t <- peekP
  armAltEnd (q :: acc) t)
armPatAlts acc _ = deferPure (orPatOf (reverseL acc))

armAltEnd : List Pat -> Token -> Parser Pat
armAltEnd acc TPipe = armPatAlts acc TPipe
armAltEnd acc TFatArrow = armPatAlts acc TFatArrow
armAltEnd acc TIf = armPatAlts acc TIf
armAltEnd _ _ = failP "expected `=>` after the alternative"

-- A recoverable failure after a `|` becomes the committed steer, positioned at
-- the `|` so the diagnostic and its `if` fix land on it.  A `|` that ends its
-- line is an or-pattern wrapped onto the next line (the layout opens a block
-- there), not a guard, so that steer carries no `if` fix.
barSteer : Parser a -> Parser a
barSteer p = ParserE (ctx pos => match runPWith ctx p pos
  PErr _ _ => PFatal (FailProblem (barSteerKind (runPWith ctx peek2P pos))) pos
  r => r)

barSteerKind : PR Token -> ParseDiagnosticKind
barSteerKind (POk TIndent _) = MatchGuardBarWrapped
barSteerKind _ = MatchGuardBar

-- ── Patterns ────────────────────────────────────────────────────────────
-- A full pattern is a cons-pattern; the as-pattern `x@p` is a cons HEAD, so `@`
-- binds tighter than `::` (see parsePatCons/parseAsPat below).  AS_AT is the
-- lexer's `@`-adjacent-to-ident token; if it doesn't follow, parseOrElse backtracks.
parsePat : Parser Pat
parsePat = parsePatCons

-- `@` binds TIGHTER than `::`: `t@(A _)::rest` is `PCons (PAs t (A _)) rest`,
-- not `PAs t (PCons (A _) rest)` (#812).  So the as-pattern is parsed as a cons
-- HEAD (below), and its sub-pattern is a `parsePatApp` — an application/atom that
-- does NOT swallow a following `::` tail.
parseAsPat : Parser Pat
parseAsPat = defer
  ctx <- contextP
  s <- getPos
  x <- identNameP
  q <- getPos
  expectTok TAsAt
  sub <- parsePatApp
  deferPure (PAs x (locOfSpan ctx s q) noBinderId sub)

parsePatCons : Parser Pat
parsePatCons = defer
  p <- parseOrElse parseAsPat parsePatApp
  parseOrElse (patConsTail p) (deferPure p)

patConsTail : Pat -> Parser Pat
patConsTail p = defer
  expectTok TCons
  q <- parsePatCons
  deferPure (PCons p q)

parsePatApp : Parser Pat
parsePatApp = defer
  t <- peekP
  patAppFor t

patAppFor : Token -> Parser Pat
patAppFor (TUpper c) = defer
  advance
  n <- upperQualTail c
  t <- peekP
  upperPatRest n t
patAppFor _ = parsePatAtom

-- after an uppercase ctor in pattern position: a record pattern `C { … }`,
-- else a constructor application `C p…`
upperPatRest : String -> Token -> Parser Pat
upperPatRest c TLBrace = recordPat c
upperPatRest c _ = defer
  args <- many parsePatAtom
  deferPure (PCon c args)

-- record pattern: `C { field, field = pat, … }` with an optional `...` rest
recordPat : String -> Parser Pat
recordPat c = defer
  expectTok TLBrace
  fr <- recordPatFields
  expectTok TRBrace
  deferPure (mkRec c fr)

mkRec : String -> (List RecPatField, Bool) -> Pat
mkRec c (fields, rest) = PRec c fields rest

recordPatFields : Parser (List RecPatField, Bool)
recordPatFields = defer
  t <- peekP
  recordPatFieldsFor t

recordPatFieldsFor : Token -> Parser (List RecPatField, Bool)
recordPatFieldsFor TEllipsis = defer
  advance
  deferPure ([], True)
-- trailing comma: a `}` directly after a comma closes the field list (also
-- accepts an empty `C {}` record pattern, which is harmless and additive)
recordPatFieldsFor TRBrace = deferPure ([], False)
recordPatFieldsFor _ = defer
  f <- recordPatField
  t <- peekP
  recordPatFieldsRest f t

recordPatFieldsRest : RecPatField -> Token -> Parser (List RecPatField, Bool)
recordPatFieldsRest f TComma = defer
  advance
  fr <- recordPatFields
  deferPure (consField f fr)
recordPatFieldsRest f _ = deferPure ([f], False)

consField : RecPatField -> (List RecPatField, Bool) -> (List RecPatField, Bool)
consField f (fs, rest) = (f :: fs, rest)

recordPatField : Parser RecPatField
recordPatField = defer
  ctx <- contextP
  s <- getPos
  name <- identNameP
  t <- peekP
  recordPatFieldRest name (locOfSpan ctx s (s + 1)) t

recordPatFieldRest : String -> Loc -> Token -> Parser RecPatField
recordPatFieldRest name nameLoc TEqual = defer
  advance
  p <- parsePat
  deferPure (RecPatField name nameLoc noBinderId (Some p))
recordPatFieldRest name nameLoc _ =
  deferPure (RecPatField name nameLoc noBinderId None)

-- A reserved keyword sitting where a pattern-variable / identifier is expected is
-- ALWAYS an error — no keyword starts a legal pattern — and the generic "expected
-- pattern" (or a downstream layout/`: or =` complaint, once `many`/`parseOrElse` has
-- swallowed the recoverable failure) hides the real cause: the NAME is reserved.
-- `reservedIdentKeyword` returns the SOURCE SPELLING of any lowercase-lexeme
-- keyword token (the full `keywordOrIdent` table in lex_scan.mdk — the identifiers a
-- user would plausibly try as a name), or None for a structural token (`=`, `(`,
-- `,`, …) whose presence is the ordinary end-of-pattern signal that MUST stay a
-- recoverable `failP` so `many parseParamPat` / list-cons parsing terminates.
-- `mut`/`function`/`with` are listed for a complete enumeration of the table but
-- never reach this arm on the loader/user-facing path (`parseResult`/
-- `parseLocatedResult`): a pre-grammar token scan —`letMutRemovedMsg` etc.,
-- ~parser.mdk:4108— preempts them there. The narrower internal `parse`/
-- `parseLocated` entry (self-typecheck tool) runs no such scan, so the arm can
-- fire for them — harmless, since none is ever a legal identifier under any
-- channel. (`record` is NOT in this table any more: it is an ordinary
-- identifier, #62 — see `keywordOrIdent` in lex_scan.mdk for why it was freed and
-- `mut`/`function` were not.)
-- ⚠️ `let`/`if`/`then`/`else`/`rec` are DELIBERATELY absent (→ None → recoverable
-- "expected pattern"): `if` legitimately follows a pattern as a match-arm GUARD
-- (`pat if cond => body`) and `rec` legitimately follows `let` (`let rec go = …`),
-- so `many parsePatAtom` / the let-binder path MUST stay recoverable at them (a
-- fatal here miscompiles the compiler's own guarded arms and every `let rec`).
-- They are still RESERVED — you cannot bind one — so the diagnostic for the
-- unambiguous case is produced POSITIONALLY instead, by the `phCtxKw` rule of
-- `prescanLineStart` (#935), which reuses `ReservedKeyword` so the same
-- `P-RESERVED-KEYWORD` code and `append _` fix reach the user.
reservedIdentKeyword : Token -> Option String
reservedIdentKeyword TWith = Some "with"
reservedIdentKeyword TMut = Some "mut"
reservedIdentKeyword TIn = Some "in"
reservedIdentKeyword TMatch = Some "match"
reservedIdentKeyword TData = Some "data"
reservedIdentKeyword TInterface = Some "interface"
reservedIdentKeyword TDefault = Some "default"
reservedIdentKeyword TImpl = Some "impl"
reservedIdentKeyword TImport = Some "import"
reservedIdentKeyword TExport = Some "export"
reservedIdentKeyword TPublic = Some "public"
reservedIdentKeyword TWhere = Some "where"
reservedIdentKeyword TOf = Some "of"
reservedIdentKeyword TDo = Some "do"
reservedIdentKeyword TDefer = Some "defer"
reservedIdentKeyword TAs = Some "as"
reservedIdentKeyword TExtern = Some "extern"
reservedIdentKeyword TRequires = Some "requires"
reservedIdentKeyword TDeriving = Some "deriving"
reservedIdentKeyword TType = Some "type"
reservedIdentKeyword TNewtype = Some "newtype"
reservedIdentKeyword TProp = Some "prop"
reservedIdentKeyword TTest = Some "test"
reservedIdentKeyword TBench = Some "bench"
reservedIdentKeyword TEffect = Some "effect"
reservedIdentKeyword TFunction = Some "function"
reservedIdentKeyword _ = None

reservedKeywordMsg : String -> ParseDiagnosticKind
reservedKeywordMsg name = ReservedKeyword name

-- Committed (`fatalP`) so the message reaches the user through the enclosing
-- `many`/`parseOrElse` (which discard a recoverable `PErr`) — the same channel
-- `intLitTooBigMsg` uses.  A structural token stays a recoverable `failP`.
reservedOrPatFail : Token -> Parser Pat
reservedOrPatFail t = match reservedIdentKeyword t
  Some name => fatalP (reservedKeywordMsg name)
  None => failP "expected a pattern"

-- Shares the invocation depth/`maxNestDepth` with `parseAtom` above — a
-- pattern's own recursive re-entry (`parsePatParen`/`parsePatList` calling back
-- into `parsePat` -> ... -> `parsePatAtom`) was NOT reached by the expression
-- cap, so pathologically deep pattern nesting (e.g. `((((...(x)...))))` in a
-- `match` arm) still exhausted the native stack with an unlocated exit 134.
-- One counter shared across expr/pattern/type mirrors how a single adversarial
-- input can nest through more than one grammar at once, and does not move
-- `parseAtom`'s own already-verified boundary: an expr-only input still only
-- ever increments at `parseAtom`.
parsePatAtom : Parser Pat
parsePatAtom = withDepth maxNestDepth (FailMsg nestTooDeepMsg) parsePatAtomRaw

parsePatAtomRaw : Parser Pat
parsePatAtomRaw = defer
  ctx <- contextP
  t <- peekP
  match t
    TIdent x => defer
      s <- getPos
      advance
      deferPure (PVar x (locOfSpan ctx s (s + 1)) noBinderId)
    TUnderscore => emit PWild
    TInt n _ if isIntMinLit n => fatalP intLitTooBigMsg
    TInt n _ => intPatRest (LInt n)
    TWideInt _ _ lx => fatalP (widePatMsg lx)
    TMinus => negIntPat
    TMinusTight => negIntPat
    TFloat f => emit (PLit (LFloat f))
    TString s => emit (PLit (LString s))
    TChar s => charPatRest (LChar s)
    TByte n => bytePatRest (LByte n)
    TUpper c => defer
      advance
      n <- upperQualTail c
      t2 <- peekP
      upperAtomRest n t2
    TLParen => parsePatParen
    TLBracket => parsePatList
    _ => reservedOrPatFail t

-- atom-level uppercase: a record pattern `C { … }` or a bare nullary ctor `C`
-- (an *applied* ctor `C p…` needs parens at atom level, like the OCaml grammar).
upperAtomRest : String -> Token -> Parser Pat
upperAtomRest c TLBrace = recordPat c
upperAtomRest c _ = deferPure (PCon c [])

-- A function-definition parameter: a `pat_atom`, plus the `@` as-pattern
-- (`x@atom`).  `parseOrElse` backtracks, so a plain-ident / non-`@` param falls
-- through to parsePatAtom.
parseParamPat : Parser Pat
parseParamPat = parseOrElse parseParamAsPat parsePatAtom

parseParamAsPat : Parser Pat
parseParamAsPat = defer
  ctx <- contextP
  s <- getPos
  x <- identNameP
  q <- getPos
  expectTok TAsAt
  sub <- parsePatAtom
  deferPure (PAs x (locOfSpan ctx s q) noBinderId sub)

-- an int literal pattern, or a range pattern `lo..hi` / `lo..=hi`
intPatRest : Lit -> Parser Pat
intPatRest lo = defer
  advance
  t <- peekP
  rngPatRest lo intBound t

-- a negative int literal pattern `-N`, or a negative-bound range `-N..hi`
-- Mirrors OCaml grammar: only `MINUS INT` followed by `..` or `..=` is valid;
-- a bare `-1` literal pattern is not accepted (consistent with OCaml parser).
negIntPat : Parser Pat
negIntPat = defer
  advance
  t <- peekP
  match t
    TInt n _ => negIntRng (LInt (negateLiteral n))
    _ => failP "expected an integer after `-`"
-- consume MINUS

-- After parsing MINUS INT, require a `..` or `..=` (range is mandatory).
negIntRng : Lit -> Parser Pat
negIntRng lo = defer
  advance
  t <- peekP
  match t
    TDotDot => defer
      advance
      hi <- intBound
      deferPure (PRng lo hi False)
    TDotDotEq => defer
      advance
      hi <- intBound
      deferPure (PRng lo hi True)
    _ => failP "expected `..` or `..=` after the range bound"
-- consume INT

charPatRest : Lit -> Parser Pat
charPatRest lo = defer
  advance
  t <- peekP
  rngPatRest lo charBound t

bytePatRest : Lit -> Parser Pat
bytePatRest lo = defer
  advance
  t <- peekP
  rngPatRest lo byteBound t

rngPatRest : Lit -> Parser Lit -> Token -> Parser Pat
rngPatRest lo bound TDotDot = defer
  advance
  hi <- bound
  deferPure (PRng lo hi False)
rngPatRest lo bound TDotDotEq = defer
  advance
  hi <- bound
  deferPure (PRng lo hi True)
rngPatRest lo _ _ = deferPure (PLit lo)

intBound : Parser Lit
intBound = defer
  t <- peekP
  intBoundFor t

intBoundFor : Token -> Parser Lit
intBoundFor (TInt n _)
  | isIntMinLit n = fatalP intLitTooBigMsg
intBoundFor (TInt n _) = emit (LInt n)
intBoundFor (TWideInt _ _ lx) = fatalP (widePatMsg lx)
intBoundFor TMinus = defer
  advance
  t <- peekP
  match t
    TInt n _ => emit (LInt (negateLiteral n))
    _ => failP "expected an integer after `-` in the range bound"
intBoundFor TMinusTight = defer
  advance
  t <- peekP
  match t
    TInt n _ => emit (LInt (negateLiteral n))
    _ => failP "expected an integer after `-` in the range bound"
intBoundFor _ = failP "expected an integer range bound"

charBound : Parser Lit
charBound = defer
  t <- peekP
  charBoundFor t

byteBound : Parser Lit
byteBound = defer
  t <- peekP
  byteBoundFor t

byteBoundFor : Token -> Parser Lit
byteBoundFor (TByte n) = emit (LByte n)
byteBoundFor _ = failP "expected a byte range bound"

charBoundFor : Token -> Parser Lit
charBoundFor (TChar s) = emit (LChar s)
charBoundFor _ = failP "expected a character range bound"

tuplePatOrSingle : List Pat -> Pat
tuplePatOrSingle [p] = p
tuplePatOrSingle ps = PTuple ps

parsePatParen : Parser Pat
parsePatParen = defer
  expectTok TLParen
  t <- peekP
  patParenFor t

patParenFor : Token -> Parser Pat
patParenFor TRParen = emit (PLit LUnit)
patParenFor _ = defer
  ps <- sepBy1 parsePatAlts (expectTok TComma)
  optTrailingCommaTuple ps
  expectTok TRParen
  deferPure (tuplePatOrSingle ps)

-- `p | q | ...` inside parentheses.
parsePatAlts : Parser Pat
parsePatAlts = defer
  p <- parsePat
  rest <- many patAlt
  deferPure (orPatOf (p :: rest))

patAlt : Parser Pat
patAlt = defer
  expectTok TPipe
  parsePat

parsePatList : Parser Pat
parsePatList = defer
  expectTok TLBracket
  t <- peekP
  patListFor t

patListFor : Token -> Parser Pat
patListFor TRBracket = emit (PList [])
patListFor _ = defer
  ps <- sepBy1 parsePat (expectTok TComma)
  optTrailingComma
  expectTok TRBracket
  deferPure (PList ps)

-- ── Types ───────────────────────────────────────────────────────────────
-- a full type is a function/effect type, optionally prefixed by a constraint
-- list: `C a => ty`.  The constraint LHS is itself parsed as a ty_fun and
-- reinterpreted by `extractConstraints` below: a `TyApp` spine bottoming at a
-- `TyCon` head → `Constraint I args` at ANY arity; `TyTuple` → many.
-- ⚠️ It reads the WHOLE spine on purpose.  Matching only one level
-- (`TyApp (TyCon I) a`) silently dropped every >=2-arg constraint — `Ix a i` is
-- `TyApp (TyApp (TyCon Ix) a) i`, whose outer TyApp holds a TyApp, not a TyCon,
-- so it fell through to `_ = []` and the constraint vanished at exit 0 (#604).
parseTy : Parser Ty
parseTy = defer
  lhs <- parseTyFun
  parseOrElse (constraintTail lhs) (deferPure lhs)

constraintTail : Ty -> Parser Ty
constraintTail lhs = defer
  expectTok TFatArrow
  t <- peekP
  indented <- tyArrowSkipLayout t
  rhs <- parseTy
  deferWhen indented (defer
    skipNewlines
    expectTok TDedent)
  deferPure (TyConstrained (extractConstraints lhs) rhs)

extractConstraints : Ty -> List Constraint
extractConstraints (TyApp f a) = match tyAppSpine (TyApp f a)
  Some (iface, args) => [constraintUnresolved iface args]
  None => []
extractConstraints (TyCon { tyConName = iface }) =
  [constraintUnresolved iface []]
extractConstraints (TyTuple cs) = concatMapC cs
extractConstraints _ = []

-- `Ix a i` parses as a left-nested TyApp spine (TyApp (TyApp (TyCon Ix) a) i),
-- so a constraint head must be FLATTENED, not matched one-arg-deep: matching only
-- `TyApp (TyCon iface _) arg` silently DROPPED every constraint of arity >= 2 (it
-- fell through to the `_ = []` arm), leaving `TyConstrained [] ty` — a signature
-- whose constraints do not exist, which typecheck then never enforced and the
-- printer rendered as `() => ty`, source that does not parse (#604).  Recurse the
-- whole spine rather than adding a 2-arg arm: that is the same trap one width over.
tyAppSpine : Ty -> Option (String, List Ty)
tyAppSpine t = tyAppSpineAcc t []

-- descends the spine outermost-first, prepending each argument, so the accumulator
-- arrives in source order at the TyCon head (`Ix a i` -> ("Ix", [a, i])).
tyAppSpineAcc : Ty -> List Ty -> Option (String, List Ty)
tyAppSpineAcc (TyCon { tyConName = iface }) acc = Some (iface, acc)
tyAppSpineAcc (TyApp f a) acc = tyAppSpineAcc f (a :: acc)
tyAppSpineAcc _ _ = None

concatMapC : List Ty -> List Constraint
concatMapC [] = []
concatMapC (t :: rest) = extractConstraints t ++ concatMapC rest

parseTyFun : Parser Ty
parseTyFun = defer
  t <- peekP
  tyFor t

tyFor : Token -> Parser Ty
tyFor TLt = parseEffectTy
tyFor _ = defer
  left <- parseTyApp
  tyAfterApp left

-- A named argument `(name : T)` binds an authority for the rest of the
-- signature, so it can only be an arrow's domain: without the arrow there is
-- no "rest" for the name to scope over.
tyAfterApp : Ty -> Parser Ty
tyAfterApp (left@(TyNamed _ _ _)) =
  parseOrElse (tyArrowTail left) (failP namedArgNeedsArrowMsg)
tyAfterApp left = parseOrElse (tyArrowTail left) (deferPure left)

namedArgNeedsArrowMsg : String
namedArgNeedsArrowMsg =
  "a named argument `(name : T)` must be followed by `->`, as in `(path : String) -> <FileRead path> Result String String`"

-- `< labels? (| tail)? > ty` — an effect-annotated type.  A bare lowercase ident
-- inside the angles is the tail var (no labels), e.g. `<e> a`.
parseEffectTy : Parser Ty
parseEffectTy = defer
  expectTok TLt
  body <- effectBody
  expectTok TGt
  inner <- parseTy
  deferPure (mkEffect body inner)

mkEffect : (List EffAtomTy, List String) -> Ty -> Ty
mkEffect (labels, tail) inner = TyEffect labels tail inner

effectBody : Parser (List EffAtomTy, List String)
effectBody = defer
  t <- peekP
  effectBodyFor t

effectBodyFor : Token -> Parser (List EffAtomTy, List String)
effectBodyFor (TUpper _) = defer
  labels <- sepBy1 effAtomP (expectTok TComma)
  tail <- pipeTail
  deferPure (labels, tail)
-- A leading tail var may itself be joined with more (`<e | e2>`, #821), so the
-- rest of the row is the same `| name` loop the labelled form uses.
effectBodyFor (TIdent _) = defer
  v <- identNameP
  rest <- pipeTail
  deferPure ([], v :: rest)
effectBodyFor _ = deferPure ([], [])

-- a row atom is a label with an optional parameter: `Foo` (the domain's top),
-- `Net "a.com/*"` (a literal), `Env {"HOME"}` (a set), `Net Host="…" Method={…}`
-- (a product).  The identity is acquired by resolve.
effAtomP : Parser EffAtomTy
effAtomP = defer
  ctx <- contextP
  s <- getPos
  l <- upperNameP
  p <- effParamP
  q <- getPos
  deferPure (effAtomAt l p (locOfSpan ctx s q))

effParamP : Parser EffParamTy
effParamP = defer
  t <- peekP
  t2 <- peek2P
  effParamDispatch t t2

-- WS-4: a `TUpper` axis-name immediately followed by `TEqual` (`Host=`) starts a
-- PRODUCT param (keyword-axes, Option A).  Otherwise fall through to the existing
-- single-domain clauses (string / hole / brace-set / none).  This is the only
-- ambiguity point: a bare `TUpper` with NO following `=` is the next comma-less
-- atom — but atoms are comma-SEPARATED, so a label-juxtaposed upper can only be a
-- product axis; the `= ` lookahead distinguishes it cleanly with zero collision.
effParamDispatch : Token -> Token -> Parser EffParamTy
effParamDispatch (TUpper _) TEqual = productParamP True
effParamDispatch t _ = effParamFor t

-- parse `Host="…" Method={…} …` (space-separated axes; loop while peek is an
-- upper-name followed by `=`).  [named]: an axis may name an argument, which
-- only an effect atom's parameter may do.
productParamP : Bool -> Parser EffParamTy
productParamP named = defer
  axes <- productAxes named
  deferPure (EPProduct axes)

productAxes : Bool -> Parser (List (String, EffParamTy))
productAxes named = defer
  a <- productAxis named
  rest <- productAxesMore named
  deferPure (a :: rest)

productAxesMore : Bool -> Parser (List (String, EffParamTy))
productAxesMore named = defer
  t <- peekP
  t2 <- peek2P
  productAxesMoreFor named t t2

productAxesMoreFor : Bool ->
  Token ->
  Token ->
  Parser (List (String, EffParamTy))
productAxesMoreFor named (TUpper _) TEqual = productAxes named
productAxesMoreFor _ _ _ = deferPure []

-- one `Axis=val` axis: val is `"…"` (Prefix), `{a,b}` (Set), or in an atom an
-- argument's name.
productAxis : Bool -> Parser (String, EffParamTy)
productAxis named = defer
  name <- upperNameP
  expectTok TEqual
  v <- productAxisVal named
  deferPure (name, v)

productAxisVal : Bool -> Parser EffParamTy
productAxisVal named = defer
  t <- peekP
  productAxisValFor named t

productAxisValFor : Bool -> Token -> Parser EffParamTy
productAxisValFor _ (TString s) = defer
  advance
  deferPure (EPLit s)
productAxisValFor _ TLBrace = effSetLiteralP
productAxisValFor True (TIdent n) = defer
  advance
  deferPure (EPName n)
productAxisValFor True _ =
  failP "expected an axis value: a `\"prefix\"`, a `{set}` or an argument name"
productAxisValFor False (TIdent _) =
  failP
    "an axis of an authority term takes a `\"prefix\"` or a `{set}`; an argument name is allowed only in an effect row"
productAxisValFor False _ =
  failP "expected an axis value: a `\"prefix\"` or a `{set}`"

-- A parameter nothing in the signature determines would be an unchecked
-- claim, so `_` (quoted or bare) is rejected with the three admissible forms
-- named: an argument's authority is bound through the arrow that names it.
effParamFor : Token -> Parser EffParamTy
effParamFor (TString s) = defer
  pos <- getPos
  advance
  if s == "_" then fatalAtP effHoleRetiredMsg pos else deferPure (EPLit s)
effParamFor TUnderscore = defer
  pos <- getPos
  fatalAtP effHoleRetiredMsg pos
effParamFor (TIdent n) = defer
  advance
  deferPure (EPName n)
effParamFor TLBrace = effSetLiteralP
effParamFor _ = deferPure EPTop

-- The Set-domain literal `{"a", "b"}`, as an atom's parameter or a product axis.
effSetLiteralP : Parser EffParamTy
effSetLiteralP = defer
  expectTok TLBrace
  elems <- sepBy1 stringLitP (expectTok TComma)
  expectTok TRBrace
  deferPure (EPSet elems)

effHoleRetiredMsg : String
effHoleRetiredMsg =
  "the `_` effect parameter is not accepted; write the bare label `<FileRead>` for any authority, or name the argument that determines it, `<FileRead path>`"

-- Zero or more `| name` tail variables.  Several make the row a JOIN (#821):
-- `<Stdout | e | e2>` is the row of Stdout together with everything e or e2
-- can perform.
pipeTail : Parser (List String)
pipeTail = defer
  t <- peekP
  pipeTailFor t

pipeTailFor : Token -> Parser (List String)
pipeTailFor TPipe = defer
  advance
  v <- identNameP
  rest <- pipeTail
  deferPure (v :: rest)
pipeTailFor _ = deferPure []

upperNameP : Parser String
upperNameP = defer
  t <- peekP
  upperNameFor t

upperNameFor : Token -> Parser String
upperNameFor (TUpper c) = emit c
upperNameFor _ = failP "expected an effect label"

-- `D.Leaf` in constructor, `impl`-head and `requires` position: a module alias
-- qualifies a CONSTRUCTOR and an INTERFACE name too, not only a type (#1287).
-- The value-level peer of `tyConQualTail`, and deliberately the same two-token
-- rule: `TDot` followed by `TUpper` folds into ONE dotted name, the flat
-- spelling `qualifiedLocal` gives an alias-qualified value and the one the
-- import machinery enters an aliased module's ctors and interfaces under.
-- Resolve strips the prefix once it has a module identity to check it against
-- (`unqualAliasCtorName`, frontend/resolve.mdk), so nothing downstream of
-- resolve sees a dotted ctor or interface name.
--
-- Only `Upper . Upper` folds.  A record FIELD is always lowercase (`TIdent`),
-- and `Upper . Upper` has no other reading in expression, pattern, `impl`-head
-- or `requires` position, so no existing spelling is taken away.
--
-- The caller re-reads the next token AFTER calling this, because `D.Node { … }`
-- is a record literal / record pattern on the folded name — not a plain
-- `EVar`/`PCon` followed by a brace.
upperQualTail : String -> Parser String
upperQualTail head = defer
  t <- peekP
  t2 <- peek2P
  upperQualFor head t t2

upperQualFor : String -> Token -> Token -> Parser String
upperQualFor head TDot (TUpper n) = defer
  advance
  advance
  deferPure (qualifiedLocal head n)
upperQualFor head _ _ = deferPure head

tyArrowTail : Ty -> Parser Ty
tyArrowTail left = defer
  expectTok TArrow
  t <- peekP
  indented <- tyArrowSkipLayout t
  right <- parseTy
  deferWhen indented (defer
    skipNewlines
    expectTok TDedent)
  deferPure (TyFun left right)

-- Skip NEWLINE or INDENT that can follow a trailing `->` in a type signature.
-- Returns True if an INDENT was consumed (caller must then consume the matching DEDENT).
tyArrowSkipLayout : Token -> Parser Bool
tyArrowSkipLayout TNewline = defer
  advance
  deferPure False
tyArrowSkipLayout TIndent = defer
  advance
  deferPure True
tyArrowSkipLayout _ = deferPure False

parseTyApp : Parser Ty
parseTyApp = defer
  head <- parseTyAtom
  args <- many parseTyAtom
  tyQualTail (tyApplyAll head args)

-- An explicit authority qualifier `T @p` on a whole type application: `@`
-- after whitespace (the lexer's `TAt`, never the adjacent as-pattern `TAsAt`)
-- followed by the binder's name, or by a parenthesised join of binder names,
-- `T @(a | b)`, the spelling a joined qualifier renders as.  Each name must be
-- bound by a `(p : T)` binder to the left, which resolve checks.
tyQualTail : Ty -> Parser Ty
tyQualTail ty = defer
  t <- peekP
  t2 <- peek2P
  tyQualTailFor ty t t2

tyQualTailFor : Ty -> Token -> Token -> Parser Ty
tyQualTailFor ty TAt (TIdent n) = defer
  ctx <- contextP
  s <- getPos
  advance
  advance
  q <- getPos
  tyQualDone (TyQual ty [EPName n] (Some (locOfSpan ctx s q)))
tyQualTailFor ty TAt (TString _) = defer
  ctx <- contextP
  s <- getPos
  advance
  p <- authTermP
  q <- getPos
  tyQualDone (TyQual ty [p] (Some (locOfSpan ctx s q)))
tyQualTailFor ty TAt TLParen = defer
  ctx <- contextP
  s <- getPos
  advance
  advance
  first <- authTermP
  rest <- authJoinTail
  expectTok TRParen
  q <- getPos
  tyQualDone (TyQual ty (first :: rest) (Some (locOfSpan ctx s q)))
tyQualTailFor _ TAsAt (TIdent n) = defer
  pos <- getPos
  fatalAtP
    "an authority qualifier needs a space before `@`; write `String @\{n}`"
    pos
tyQualTailFor _ TAsAt (TString s) = defer
  pos <- getPos
  fatalAtP
    "an authority qualifier needs a space before `@`; write `String @\"\{s}\"`"
    pos
tyQualTailFor _ TAsAt TLParen = defer
  pos <- getPos
  fatalAtP
    "an authority qualifier needs a space before `@`; write `String @(...)`"
    pos
tyQualTailFor ty _ _ = deferPure ty

-- A second `@` directly after a qualifier is refused at that `@`.  Left in the
-- stream it would be read as a declaration attribute on the next declaration,
-- and `fmt` would then write it there.  Only a qualifier that was just read is
-- checked, because `(p : T @Label)` is a binder domain, not a qualifier.
tyQualDone : Ty -> Parser Ty
tyQualDone ty = defer
  t <- peekP
  tyQualDoneFor ty t

tyQualDoneFor : Ty -> Token -> Parser Ty
tyQualDoneFor _ TAt = defer
  pos <- getPos
  fatalAtP "a type takes one authority qualifier" pos
tyQualDoneFor ty _ = deferPure ty

-- One term of a written authority join, in a qualifier (`@(a | "b/*")`) or
-- an index (`Handle ("a/*" | p)`): a name, or a domain literal spelled as an
-- atom's parameter is (a pattern, a set, a product's axes).
authTermP : Parser EffParamTy
authTermP = defer
  t <- peekP
  t2 <- peek2P
  authTermFor t t2

authTermFor : Token -> Token -> Parser EffParamTy
authTermFor (TUpper _) TEqual = productParamP False
authTermFor (t@(TString _)) _ = effParamFor t
authTermFor (t@(TIdent _)) _ = effParamFor t
authTermFor TLBrace _ = effSetLiteralP
authTermFor _ _ =
  failP
    "expected an authority term: a name, a `\"pattern\"`, a `{set}` or `Axis=...` axes"

-- The `| term` operands after a join's first term.
authJoinTail : Parser (List EffParamTy)
authJoinTail = defer
  t <- peekP
  authJoinTailFor t

authJoinTailFor : Token -> Parser (List EffParamTy)
authJoinTailFor TPipe = defer
  advance
  p <- authTermP
  rest <- authJoinTail
  deferPure (p :: rest)
authJoinTailFor _ = deferPure []

tyApplyAll : Ty -> List Ty -> Ty
tyApplyAll head [] = head
tyApplyAll head (a :: rest) = tyApplyAll (TyApp head a) rest

-- Shares the invocation depth/`maxNestDepth` with `parseAtom` above — see
-- the comment on `parsePatAtom`'s own wrapper for why a shared counter, and
-- why it can't move `parseAtom`'s already-verified boundary. The type
-- parser's own recursive re-entry (`parseTyParen` calling back into
-- `parseTy` -> ... -> `parseTyAtom`) was NOT reached by the expression cap,
-- so pathologically deep type nesting (e.g. `f : ((((Int)))) -> Int`) still
-- exhausted the native stack with an unlocated exit 134.
parseTyAtom : Parser Ty
parseTyAtom = withDepth maxNestDepth (FailMsg nestTooDeepMsg) parseTyAtomRaw

parseTyAtomRaw : Parser Ty
parseTyAtomRaw = defer
  ctx <- contextP
  t <- peekP
  match t
    TUpper c => defer
      s <- getPos
      advance
      n <- tyConQualTail c
      q <- getPos
      deferPure (tyConUnresolved n (Some (locOfSpan ctx s q)))
    TIdent v => emit (TyVar v)
    TLParen => parseTyParen
    TLt => parseBareEffectAtom
    TStar => parseTyAuthTop
    TString _ => parseTyAuthLit
    TLBrace => parseTyAuthLit
    _ => failP "expected a type"

-- An authority term in an `Authority`-kinded type-ARGUMENT slot: `Handle *`
-- is the domain's top (a row spells top by omitting the parameter; an index
-- argument cannot be omitted), `Handle "config/*"` a literal, `Handle {"A"}`
-- a set — the atom-parameter grammar (`effParamFor`), so the quoted
-- underscore is refused here exactly as it is in a row.  Which slots are
-- Authority-kinded is the elaborator's knowledge, not the parser's: outside
-- one the node is diagnosed there, as a bare row in a `Type` slot is.
parseTyAuthTop : Parser Ty
parseTyAuthTop = defer
  ctx <- contextP
  s <- getPos
  expectTok TStar
  q <- getPos
  deferPure (TyAuth [EPTop] (Some (locOfSpan ctx s q)))

parseTyAuthLit : Parser Ty
parseTyAuthLit = defer
  ctx <- contextP
  s <- getPos
  p <- effParamP
  q <- getPos
  deferPure (TyAuth [p] (Some (locOfSpan ctx s q)))

-- A parenthesised authority join in an index slot whose first term is a
-- literal: `("a.com/*" | "b.com/*")`, `("cfg/*" | p)`.
parseTyAuthJoin : Int -> Parser Ty
parseTyAuthJoin s = defer
  ctx <- contextP
  first <- authTermP
  rest <- authJoinTail
  expectTok TRParen
  q <- getPos
  deferPure (TyAuth (first :: rest) (Some (locOfSpan ctx s q)))

-- `M.Map` in type position: a module alias qualifies a TYPE name, not only a
-- value (#2412).  The grammar has no notion of a qualified name, so the two
-- tokens are folded into ONE dotted `TyCon` name here — the same flat spelling
-- `qualifiedLocal` gives an alias-qualified value, and the same one the import
-- machinery enters an aliased module's types under.  Resolve strips the prefix
-- once it has the module identity to stamp (`stampTyHead`, frontend/resolve.mdk),
-- so nothing downstream of resolve ever sees a dotted type name.
--
-- Only `Upper . Upper` folds.  A `.` after a type atom is a parse error in every
-- other shape, so no existing reading is taken away, and a lowercase right-hand
-- side stays the error it was (a type name cannot be lowercase).
tyConQualTail : String -> Parser String
tyConQualTail head = defer
  t <- peekP
  t2 <- peek2P
  tyConQualFor head t t2

tyConQualFor : String -> Token -> Token -> Parser String
tyConQualFor head TDot (TUpper n) = defer
  advance
  advance
  deferPure (qualifiedLocal head n)
tyConQualFor head _ _ = deferPure head

-- A row/grade written directly in a type-ARGUMENT slot (#997), e.g.
-- `Async <Stdout> Unit` — unlike the prefix `tyFor TLt` form
-- (`<Stdout> Unit -> Int`), there is no following type for the row to wrap:
-- `Unit` here is `Async`'s *next* argument, parsed separately by the `many
-- parseTyAtom` loop in `parseTyApp`. Reuses `effectBody` — the same
-- row-parsing helper `parseEffectTy` uses — so both spellings agree on what
-- a row means. Produces `TyRow`, NOT a filler-wrapped `TyEffect`: a bare row
-- atom wraps no inner type, and a filler (e.g. `TyCon "Unit"`) would be
-- print-ambiguous with a genuine wrapped type of the same shape (see
-- `TyRow`'s doc comment, ast.mdk).
parseBareEffectAtom : Parser Ty
parseBareEffectAtom = defer
  ctx <- contextP
  s <- getPos
  expectTok TLt
  body <- effectBody
  expectTok TGt
  q <- getPos
  deferPure (mkRow body (locOfSpan ctx s q))

mkRow : (List EffAtomTy, List String) -> Loc -> Ty
mkRow (labels, tail) loc = TyRow labels tail (Some loc)

tyTupleOrSingle : List Ty -> Ty
tyTupleOrSingle [t] = t
tyTupleOrSingle ts = TyTuple ts

parseTyParen : Parser Ty
parseTyParen = defer
  s <- getPos
  expectTok TLParen
  t <- peekP
  t2 <- peek2P
  parseTyParenAt s t t2

-- `(` then a string, a set or `Axis=` starts an authority join; anything
-- else is the type grammar below.
parseTyParenAt : Int -> Token -> Token -> Parser Ty
parseTyParenAt s (TString _) _ = parseTyAuthJoin s
parseTyParenAt s TLBrace _ = parseTyAuthJoin s
parseTyParenAt s (TUpper _) TEqual = parseTyAuthJoin s
parseTyParenAt _ t _ = parseTyParenBody t

-- A leading comma right after `(` can only be the bare tuple type constructor
-- `(,)`/`(,,)`/… (arities 2–5) — a normal parenthesized/tuple type always starts
-- with a type atom.  Everything else is the existing `(a)` / `(a, b)` / `(a -> b)`
-- path.
parseTyParenBody : Token -> Parser Ty
parseTyParenBody TComma = parseTupleCtorTail 0
-- `(e | e2)` in an Effect-kinded type-ARGUMENT slot is a bare row whose tail
-- is a join (#821), the parenthesised spelling of `<e | e2>`: `f (e | e2) b`.
-- Only a `|` right after the ident selects it, so `(e)` and `(e, f)` keep
-- their ordinary parenthesised/tuple readings.
parseTyParenBody (TIdent _) = defer
  t2 <- peek2P
  parseTyParenIdent t2
parseTyParenBody _ = parseTyParenTuple

parseTyParenIdent : Token -> Parser Ty
-- `(name : T)`: an arrow-domain binder naming the argument's authority, and
-- `(name : T @Label)`, the same binder with its domain written.  A label
-- after the type is not a qualifier on `T` (a qualifier names a binder, and
-- is lowercase); it says which label's domain the binder's authority is in.
parseTyParenIdent TColon = defer
  n <- identNameP
  expectTok TColon
  t <- parseTy
  t1 <- peekP
  t2 <- peek2P
  d <- binderDomainP t1 t2
  expectTok TRParen
  deferPure (TyNamed n t d)
-- `(a | b)` of names only stays a row join, as an `Effect` slot reads it; a
-- literal among the terms makes it an authority join.
parseTyParenIdent TPipe = defer
  ctx <- contextP
  s <- getPos
  v <- identNameP
  rest <- authJoinTail
  expectTok TRParen
  q <- getPos
  deferPure (namesOrAuthJoin v rest (Some (locOfSpan ctx s q)))
parseTyParenIdent _ = parseTyParenTuple

-- A binder's written domain, `@Label` after its type, held as a label-only
-- atom so resolve acquires the label's identity as it does for a row's.
binderDomainP : Token -> Token -> Parser (Option EffAtomTy)
binderDomainP TAt (TUpper _) = defer
  ctx <- contextP
  s <- getPos
  advance
  l <- upperNameP
  pat <- patternMarkP
  q <- getPos
  let atom = effAtomAt l EPTop (locOfSpan ctx s q)
  deferPure (Some EffAtomTy { atom | eatPattern = pat })
binderDomainP TAsAt (TUpper l) = defer
  pos <- getPos
  fatalAtP
    "a binder's domain needs a space before `@`; write `String @\{l}`"
    pos
binderDomainP _ _ = deferPure None

namesOrAuthJoin : String -> List EffParamTy -> Option Loc -> Ty
namesOrAuthJoin v rest loc = match allNames rest []
  Some names => TyRow [] (v :: names) loc
  None => TyAuth (EPName v :: rest) loc

allNames : List EffParamTy -> List String -> Option (List String)
allNames [] acc = Some (reverseL acc)
allNames ((EPName n) :: rest) acc = allNames rest (n :: acc)
allNames _ _ = None

parseTyParenTuple : Parser Ty
parseTyParenTuple = defer
  ts <- sepBy1 parseTy (expectTok TComma)
  optTrailingCommaTuple ts
  expectTok TRParen
  deferPure (tyTupleOrSingle ts)

-- Count the commas of a bare tuple constructor `( , , … )`; arity = commas + 1.
-- Lowers to `TyCon "__tupleN__"`, the same dispatch tag typecheck uses
-- (`tupleHeadTagTc`), so the unsaturated head can bind a higher-kinded class
-- param (`impl Bimappable (,)`).
parseTupleCtorTail : Int -> Parser Ty
parseTupleCtorTail commas = defer
  t <- peekP
  tupleCtorTailFor commas t

tupleCtorTailFor : Int -> Token -> Parser Ty
tupleCtorTailFor commas TComma = defer
  advance
  parseTupleCtorTail (commas + 1)
tupleCtorTailFor commas TRParen = defer
  advance
  tupleCtorTyOfArity (commas + 1)
tupleCtorTailFor _ _ = failP "expected `,` or `)` in the tuple type constructor"

-- #1110 (was a residual, DRAINED by the stamping PR): this head is a BUILTIN, so
-- `DICT-SEMANTICS.md` §8 I6.2 (a) says its identity is the reserved
-- `OriginBuiltin`, NOT the module the tuple was written in.  Stamping it with the
-- module under elaboration would make every module's `(Int, Int)` a distinct type
-- and the prelude's `impl Bimappable (,)` stop applying — silently.  `tyConBuiltin`
-- is what keeps resolve's stamper off it: the stamper only ever fills in an
-- `OriginUnresolved` head, so this node is immune by construction rather than by
-- a special case the stamper has to remember.
tupleCtorTyOfArity : Int -> Parser Ty
tupleCtorTyOfArity n =
  if n >= 2 && n <= 5 then
    deferPure (tyConBuiltin (tupleCtorTyName n) None)
  else
    failP "a tuple type constructor has 2 to 5 components"

tupleCtorTyName : Int -> String
tupleCtorTyName 2 = "__tuple2__"
tupleCtorTyName 3 = "__tuple3__"
tupleCtorTyName 4 = "__tuple4__"
tupleCtorTyName 5 = "__tuple5__"
tupleCtorTyName _ = "__tuple0__"

-- ── Declarations + program ──────────────────────────────────────────────
-- top-level dispatch.  `export`/`public export` are prefixes: `export` sets
-- is_pub on a non-data decl (or DataAbstract on data/record); `public export`
-- yields DataPublic.  `import`/`export import` → DUse; `extern` → DExtern.
parseDecl : Parser Decl
parseDecl = defer
  t <- peekP
  match t
    TImport => parseImport False
    TExport => afterExport
    TPublic => afterPublic
    TData => parseData VisPrivate
    TExtern => parseExtern False
    TProp => parseProp False
    TTest => parseTest False
    TBench => parseBench False
    TEffect => parseEffect False
    TInterface => parseInterface False False
    TImpl => parseImpl False
    TDefault => afterDefault False
    TType => parseTypeAlias False
    TNewtype => parseNewtype False
    TLet => parseLetGroupDecl False
    TAt => parseAttrib
    _ => parseFunOrSig False

-- `default` prefixes an interface (marks its default methods).  `default impl`
-- has been removed — afterDefaultFor surfaces a located hint for it.
afterDefault : Bool -> Parser Decl
afterDefault pub = defer
  expectTok TDefault
  skipNewlines
  t <- peekP
  afterDefaultFor pub t

afterDefaultFor : Bool -> Token -> Parser Decl
afterDefaultFor pub TInterface = parseInterface pub True
afterDefaultFor _ TImpl = failP defaultImplRemovedMsg
afterDefaultFor _ _ = failP "expected an interface after `default`"

afterExport : Parser Decl
afterExport = defer
  expectTok TExport
  skipNewlines
  t <- peekP
  match t
    TImport => parseImport True
    TData => parseData VisAbstract
    TExtern => parseExtern True
    TProp => parseProp True
    TTest => parseTest True
    TBench => parseBench True
    TEffect => parseEffect True
    TInterface => parseInterface True False
    TImpl => parseImpl True
    TDefault => afterDefault True
    TType => parseTypeAlias True
    TNewtype => parseNewtype True
    TLet => parseLetGroupDecl True
    _ => parseFunOrSig True

afterPublic : Parser Decl
afterPublic = defer
  pubPos <- getPos
  expectTok TPublic
  skipNewlines
  expectTok TExport
  skipNewlines
  t <- peekP
  afterPublicFor pubPos t

-- `public` is meaningful only in front of `data` (it selects `VisPublic`
-- instead of the plain-`export` `VisAbstract`); anything else is a user
-- mistake, not a grammar gap.  The error is reported at `pubPos` — the
-- `public` token itself, captured before it was consumed — rather than at
-- whatever token follows `public export`, so the caret lands on the actual
-- problem and its edit deletes exactly the `public` token at that location.
afterPublicFor : Int -> Token -> Parser Decl
afterPublicFor _ TData = parseData VisPublic
afterPublicFor pubPos TExtern = fatalProblemAtP (PublicDataOnly True) pubPos
afterPublicFor pubPos _ = fatalProblemAtP (PublicDataOnly False) pubPos

parseFunOrSig : Bool -> Parser Decl
parseFunOrSig pub = defer
  ctx <- contextP
  s <- getPos
  name <- identNameP
  let site = locOfSpan ctx s (s + 1)
  params <- many parseParamPat
  t <- peekP
  match t
    TColon => defer
      advance
      ty <- parseTy
      skipNewlines
      deferPure (DTypeSig pub name ty site)
    TEqual => defer
      advance
      body <- parseBody
      skipNewlines
      deferPure (DFunDef pub name params body site noBinderId)
    TIndent => defer
      advance
      arms <- parseGuardArms
      body <- guardArmsWhereOpt arms
      expectTok TDedent
      skipNewlines
      deferPure (DFunDef pub name params body site noBinderId)
    TPipe => defer
      arm <- parseGuardArm
      skipNewlines
      deferPure (DFunDef pub name params (EGuards [arm]) site noBinderId)
    _ => failP "expected `:` or `=` after the definition head"

-- ── extern + import declarations ─────────────────────────────────────────
parseExtern : Bool -> Parser Decl
parseExtern pub = defer
  expectTok TExtern
  t <- peekP
  parseExternFor pub t

parseExternFor : Bool -> Token -> Parser Decl
parseExternFor pub TData = defer
  expectTok TData
  named <- locatedUpperNameP
  let name = fst named
  let nameLoc = snd named
  ps <- tyParamsP
  t <- peekP
  d <- externDataEnd pub name ps t
  deferPure (setDeclNameLoc nameLoc d)
parseExternFor pub _ = defer
  ctx <- contextP
  s <- getPos
  name <- externName
  expectTok TColon
  ty <- parseTy
  e <- getPos
  t <- peekP
  u <- peek2P
  binds <- externBindsFor t u
  skipNewlines
  deferPure
    (DExtern ExternDecl {
      edPub = pub,
      edName = name,
      edTy = ty,
      edLoc = locOfSpan ctx s e,
      edBinds = binds,
    })

-- The indented `bind` clause lines under an extern's signature, which the
-- layout opens as a block of their own (`frontend/lex_layout.mdk`).
externBindsFor : Token -> Token -> Parser (List ExternBind)
externBindsFor TIndent (TIdent "bind") = defer
  advance
  binds <- externBindLines
  expectTok TDedent
  deferPure binds
externBindsFor _ _ = deferPure []

externBindLines : Parser (List ExternBind)
externBindLines = defer
  b <- externBindP
  skipNewlines
  t <- peekP
  rest <- if t == TDedent then deferPure [] else externBindLines
  deferPure (b :: rest)

-- `bind <host> "<symbol>"`.  Which hosts and symbols are valid is the
-- typechecker's question (`types/ffi_bindings.mdk`), so any lowercase host
-- parses.
externBindP : Parser ExternBind
externBindP = defer
  ctx <- contextP
  s <- getPos
  t <- peekP
  _ <- if t == TIdent "bind" then advance else failP "expected `bind`"
  h <- peekP
  host <- bindHostFor h
  symbol <- stringLitP
  e <- getPos
  deferPure ExternBind {
    ebHost = host,
    ebSymbol = symbol,
    ebLoc = locOfSpan ctx s e,
  }

bindHostFor : Token -> Parser String
bindHostFor (TIdent x) = emit x
bindHostFor _ = failP "expected a host after `bind`, such as `c` or `js`"

-- An extern type has no body: its values come from externs, so a
-- constructor list or a derived instance has nothing to describe.
externDataEnd : Bool ->
  String ->
  List (String, Option KindAnn) ->
  Token ->
  Parser Decl
externDataEnd _ _ _ TEqual =
  failP "an `extern data` type has no constructors; drop the `= ...`"
externDataEnd _ _ _ TDeriving =
  failP
    "an `extern data` type has no constructors to derive from; drop the `deriving` clause"
externDataEnd pub name ps _ = defer
  skipNewlines
  deferPure (externDataUnresolved pub name (map fst ps) (map snd ps))

-- A declaration's upper-case name and its span, which diagnostics about the
-- declaration (a duplicate, a reserved name) are located at.
locatedUpperNameP : Parser (String, Loc)
locatedUpperNameP = defer
  ctx <- contextP
  s <- getPos
  name <- upperNameP
  q <- getPos
  deferPure (name, locOfSpan ctx s q)

-- ── type alias / newtype / top-level let-group / attributes ──────────────
-- `type Name a… = ty`
parseTypeAlias : Bool -> Parser Decl
parseTypeAlias pub = defer
  expectTok TType
  named <- locatedUpperNameP
  let name = fst named
  let nameLoc = snd named
  ps <- tyParamsP
  expectTok TEqual
  ty <- parseTy
  skipNewlines
  deferPure
    (setDeclNameLoc
      nameLoc
      (dTypeAliasUnresolved pub name (map fst ps) (map snd ps) ty))

-- `newtype Name a… = Con ty [deriving (…)]`
parseNewtype : Bool -> Parser Decl
parseNewtype pub = defer
  expectTok TNewtype
  named <- locatedUpperNameP
  let name = fst named
  let nameLoc = snd named
  ps <- tyParamsP
  expectTok TEqual
  con <- upperNameP
  binders <- ctorBindersP
  fty <- parseTy
  t <- peekP
  derives <- newtypeDerives t
  skipNewlines
  deferPure
    (setDeclNameLoc
      nameLoc
      (dNewtypeUnresolved
        pub
        name
        (map fst ps)
        (map snd ps)
        con
        binders
        fty
        derives))

-- top-level `let rec f a… = body` → DLetGroup with a single binding.
-- Mutual-recursion grouping via `with` has been removed — each recursive
-- top-level binding is its own `let rec`.
parseLetGroupDecl : Bool -> Parser Decl
parseLetGroupDecl pub = defer
  expectTok TLet
  expectTok TRec
  c <- letRecDeclClause
  skipNewlines
  deferPure (DLetGroup pub (coalesceClauses [c]))

letRecDeclClause : Parser (String, List Pat, Expr, Loc)
letRecDeclClause = defer
  ctx <- contextP
  s <- getPos
  name <- identNameP
  pats <- many parseParamPat
  expectTok TEqual
  body <- parseBody
  deferPure (name, pats, body, locOfSpan ctx s (s + 1))

-- declaration attribute `@deprecated "msg"` / `@inline` / `@must_use` / `@noinline` wrapping
-- the following decl.  `atPos` is the `@`, where an unknown or ill-formed
-- attribute is reported.
parseAttrib : Parser Decl
parseAttrib = defer
  atPos <- getPos
  expectTok TAt
  name <- identNameP
  t <- peekP
  attr <- attrArg atPos name t
  skipNewlines
  inner <- parseDecl
  deferPure (DAttrib [attr] inner)

attrArg : Int -> String -> Token -> Parser Attr
attrArg atPos name (TString msg) = defer
  advance
  mkAttr atPos name (Some msg)
attrArg atPos name _ = mkAttr atPos name None

-- Every attribute name is listed here, so a name outside the list is a located
-- error.  Mapping it to a default would make `fmt` write that default back over
-- the author's text.  `@deprecated` keeps an absent message as `None`, so it
-- prints back as written.
mkAttr : Int -> String -> Option String -> Parser Attr
mkAttr _ "deprecated" msg = deferPure (AttrDeprecated msg)
mkAttr atPos name msg = match bareAttr name
  None =>
    fatalAtP
      "unknown declaration attribute `@\{name}`; the attributes are `@deprecated \"msg\"`, `@inline`, `@must_use` and `@noinline`"
      atPos
  Some attr => match msg
    None => deferPure attr
    Some _ => fatalAtP "`@\{name}` takes no message" atPos

bareAttr : String -> Option Attr
bareAttr "inline" = Some AttrInline
bareAttr "must_use" = Some AttrMustUse
bareAttr "noinline" = Some AttrNoInline
bareAttr _ = None

externName : Parser String
externName = defer
  t <- peekP
  externNameFor t

externNameFor : Token -> Parser String
externNameFor (TIdent x) = emit x
externNameFor (TUpper x) = emit x
externNameFor _ = failP "expected a name after `extern`"

parseImport : Bool -> Parser Decl
parseImport pub = defer
  ctx <- contextP
  s <- getPos
  expectTok TImport
  quals <- importQuals
  path <- importPathFor quals
  e <- getPos
  noExportedAlias pub path
  skipNewlines
  deferPure (DUse pub path (locOfSpan ctx s e))

-- An `export import` may NOT be aliased, in either form.  Both would re-export a name
-- that does not exist in the module that actually defines it:
--
--   `export import m as A`        binds `A.name` — names meaningful only against OUR
--                                 private alias, which an importer could not write.
--   `export import m.{a as b}`    would re-export `b`, but a module's export table maps
--                                 (name → defining module) and the real symbol is
--                                 rebuilt from that pair — so `b` would rebuild as
--                                 `m__b`, while the symbol is `m__a`.
--
-- Rejecting is the honest option: an alias is FILE-LOCAL.  Re-export the module
-- (`export import m`) or the member under its own name (`export import m.{a}`), and let
-- the importer alias it.
noExportedAlias : Bool -> UsePath -> Parser Unit
noExportedAlias True (UseAlias _ a) =
  failP
    "`export import ... as \{a}` is not allowed; a module alias is file-local, so write `export import m` and let the importer choose its alias"
noExportedAlias True (UseGroup _ members) = failIfAliasedMember members
noExportedAlias _ _ = deferPure ()

failIfAliasedMember : List UseMember -> Parser Unit
failIfAliasedMember [] = deferPure ()
failIfAliasedMember (m :: rest) = match useMemberAlias m
  Some a =>
    failP
      "`export import` cannot rename `\{useMemberOrigin m}` as `\{a}`; re-export it under its own name, `export import m.{\{useMemberOrigin m}}`"
  None => failIfAliasedMember rest

importQuals : Parser (List String)
importQuals = defer
  first <- importIdent
  rest <- importQualRest
  deferPure (first :: rest)

importQualRest : Parser (List String)
importQualRest = defer
  t <- peekP
  importQualRestFor t

importQualRestFor : Token -> Parser (List String)
importQualRestFor TDot = defer
  advance
  x <- importIdent
  rest <- importQualRest
  deferPure (x :: rest)
importQualRestFor _ = deferPure []

importIdent : Parser String
importIdent = defer
  t <- peekP
  importIdentFor t

-- a path component: a lowercase module name, an Uppercase name (e.g.
-- `collections.HashMap`), or a keyword that is legal as a path component
-- (`test`, `data`, `type`).  `record` needs no arm of its own since #62 — it
-- lexes as a plain `TIdent` and the first arm takes it.
importIdentFor : Token -> Parser String
importIdentFor (TIdent x) = emit x
importIdentFor (TUpper x) = emit x
importIdentFor TTest = emit "test"
importIdentFor TData = emit "data"
importIdentFor TType = emit "type"
importIdentFor _ = failP "expected a module name in the import path"

importPathFor : List String -> Parser UsePath
importPathFor quals = defer
  t <- peekP
  importPathForT quals t

importPathForT : List String -> Token -> Parser UsePath
importPathForT quals TDotLBrace = defer
  advance
  ms <- sepBy1 importMember (expectTok TComma)
  optTrailingComma
  expectTok TRBrace
  noTrailingAlias "a selective import"
  deferPure (UseGroup quals ms)
importPathForT quals TDotStar = defer
  advance
  noTrailingAlias "a wildcard import"
  deferPure (UseWild quals)
importPathForT quals TAs = defer
  advance
  a <- aliasName
  deferPure (UseAlias quals a)
importPathForT quals _ = deferPure (UseName quals)

-- `import m.{a, b} as A` / `import m.* as A` are REJECTED, not silently ignored.
-- Both forms are self-contradictory: the group/wildcard says "bind these names
-- unqualified HERE", the alias says "bind them only under `A.`".  A module alias
-- (`import m as A`) already covers everything the module exports, and a member alias
-- (`import m.{a as b}`) covers renaming a single name — so neither form loses power.
noTrailingAlias : String -> Parser Unit
noTrailingAlias what = defer
  t <- peekP
  noTrailingAliasFor what t

noTrailingAliasFor : String -> Token -> Parser Unit
noTrailingAliasFor what TAs =
  failP
    "`as` cannot alias \{what}; write `import m as A` to alias the whole module"
noTrailingAliasFor _ _ = deferPure ()

importMember : Parser UseMember
importMember = defer
  s <- getPos
  t <- peekP
  importMemberFor s t

importMemberFor : Int -> Token -> Parser UseMember
importMemberFor s (TIdent x) = defer
  advance
  memberAliasOrNot s x False
importMemberFor s (TUpper x) = defer
  advance
  withAllOrNot s x
importMemberFor _ _ = failP "expected an imported name"

withAllOrNot : Int -> String -> Parser UseMember
withAllOrNot s x = defer
  t <- peekP
  withAllFor s x t

-- An Uppercase member is a TYPE, CONSTRUCTOR or INTERFACE, and none of those may be
-- aliased.  Impl coherence and constructor identity are resolved on the REAL name
-- globally, so binding one under a local alias would be a silent soundness hole, not a
-- rename.  Reject it here rather than accept-and-ignore.
withAllFor : Int -> String -> Token -> Parser UseMember
withAllFor s x TLParen = defer
  ctx <- contextP
  advance
  expectTok TDotDot
  expectTok TRParen
  q <- getPos
  noMemberAlias x
  deferPure (UseMember x True (locOfSpan ctx s q) None)
withAllFor s x _ = defer
  ctx <- contextP
  q <- getPos
  noMemberAlias x
  deferPure (UseMember x False (locOfSpan ctx s q) None)

noMemberAlias : String -> Parser Unit
noMemberAlias x = defer
  t <- peekP
  noMemberAliasFor x t

noMemberAliasFor : String -> Token -> Parser Unit
noMemberAliasFor x TAs =
  failP
    "`\{x}` is a type or constructor and cannot be aliased; import it under its own name"
noMemberAliasFor _ _ = deferPure ()

-- a value member's optional `as <alias>`: `import m.{a as b}` binds m's `a` under `b`.
memberAliasOrNot : Int -> String -> Bool -> Parser UseMember
memberAliasOrNot s x allCtors = defer
  t <- peekP
  memberAliasFor s x allCtors t

memberAliasFor : Int -> String -> Bool -> Token -> Parser UseMember
memberAliasFor s x allCtors TAs = defer
  ctx <- contextP
  advance
  a <- memberAliasName
  q <- getPos
  deferPure (UseMember x allCtors (locOfSpan ctx s q) (Some a))
memberAliasFor s x allCtors _ = defer
  ctx <- contextP
  q <- getPos
  deferPure (UseMember x allCtors (locOfSpan ctx s q) None)

-- A value member's alias is itself a value name ⇒ lowercase.
memberAliasName : Parser String
memberAliasName = defer
  t <- peekP
  memberAliasNameFor t

memberAliasNameFor : Token -> Parser String
memberAliasNameFor (TIdent x) = emit x
memberAliasNameFor (TUpper x) =
  failP
    "a value member's alias must be lowercase; `as \{x}` names a type or constructor"
memberAliasNameFor _ = failP "expected an alias after `as`"

-- A MODULE alias must be Uppercase.  It is referenced as `A.name`, which parses as a
-- field access on `A`; requiring uppercase keeps it unambiguous against `rec.field` on
-- a lowercase local (record fields are accessed with the same `.`).
aliasName : Parser String
aliasName = defer
  t <- peekP
  aliasNameFor t

aliasNameFor : Token -> Parser String
aliasNameFor (TUpper x) = emit x
aliasNameFor (TIdent x) =
  failP "a module alias must be capitalized; `as \{x}` is lowercase"
aliasNameFor _ = failP "expected an alias after `as`"

-- ── prop / test / bench declarations ─────────────────────────────────────
stringLitP : Parser String
stringLitP = defer
  t <- peekP
  stringLitFor t

stringLitFor : Token -> Parser String
stringLitFor (TString s) = emit s
stringLitFor _ = failP "expected a string literal"

-- A `prop`/`test` name is a static label, so a string with `\{…}` interpolation
-- is rejected at the keyword rather than falling through to a generic failure.
interpolatedNameMsg : String -> String
interpolatedNameMsg kw =
  "a `\{kw}` name must be a plain string literal, not an interpolated string"

propNameFor : Int -> Token -> Parser String
propNameFor propPos (TInterpOpen _) =
  fatalAtP (interpolatedNameMsg "prop") propPos
propNameFor _ t = stringLitFor t

parseProp : Bool -> Parser Decl
parseProp pub = defer
  propPos <- getPos
  expectTok TProp
  t <- peekP
  name <- propNameFor propPos t
  params <- many propParam
  expectTok TEqual
  body <- parseBody
  skipNewlines
  deferPure (DProp pub name params body)

propParam : Parser PropParam
propParam = defer
  ctx <- contextP
  expectTok TLParen
  s <- getPos
  name <- identNameP
  expectTok TColon
  ty <- parseTy
  expectTok TRParen
  deferPure (PropParam name (locOfSpan ctx s (s + 1)) ty)

-- `TTest` at a decl head is ambiguous between the two things `test` can mean:
-- the start of a `test "…" = …` block, or an ordinary (but reserved, so
-- illegal) declaration name (`test = 2`, #646).  Capture the keyword's own
-- position BEFORE consuming it, then peek: a string literal confirms the
-- block production and we proceed as before; anything else means the user
-- wrote `test` as a plain name, so report it the same way #532/#630 report
-- every other reserved-word collision — `fatalP` (not `failP`) so the
-- message survives the enclosing `many`'s swallow-and-retry recovery, at the
-- captured `testPos` so the caret lands on `test`, not on whatever token
-- (`=`) happened to be where the string label was expected.
parseTest : Bool -> Parser Decl
parseTest pub = defer
  testPos <- getPos
  expectTok TTest
  t <- peekP
  parseTestRest pub testPos t

parseTestRest : Bool -> Int -> Token -> Parser Decl
parseTestRest pub _ (TString _) = defer
  name <- stringLitP
  expectTok TEqual
  body <- parseBody
  skipNewlines
  deferPure (DTest pub name body)
parseTestRest _ testPos (TInterpOpen _) =
  fatalAtP (interpolatedNameMsg "test") testPos
parseTestRest _ testPos _ = fatalProblemAtP (ReservedKeyword "test") testPos

-- `bench "name" = expr` is removed: no verb and no runner ever consumed the
-- declaration, so it typechecked and then did nothing.  `bench` stays a lexer
-- keyword solely so this located message can name the replacement instead of a
-- generic parse failure — the same shape as `let mut` / `record` / `function`.
-- `fatalAtP` (not `failP`) so the message survives `parseProgram`'s enclosing
-- `many` recovery, at the `bench` token's own position.
benchRemovedMsg : String
benchRemovedMsg = "`bench` has been removed; delete the declaration"

parseBench : Bool -> Parser Decl
parseBench _ = defer
  benchPos <- getPos
  fatalAtP benchRemovedMsg benchPos

-- `effect Foo` declares a user/platform effect label (Phase 146 gap 2).
-- `effect Foo` (atomic), `effect Net Prefix` (domain-carrying).  The optional
-- domain is a bare UPPER after the label; only `Prefix` is accepted in v2.
parseEffect : Bool -> Parser Decl
parseEffect pub = defer
  ctx <- contextP
  expectTok TEffect
  s <- getPos
  name <- upperNameP
  q <- getPos
  dom <- effDomainP
  axes <- effAxesP
  skipNewlines
  deferPure (effectDeclUnstamped pub name dom axes (Some (locOfSpan ctx s q)))

-- A Product label's axis schema, `(Host : Prefix, Method : Set)`: each axis
-- named with the domain it is drawn from, in the order written, the first
-- being the primary axis a bare literal lifts into.  Only a Product carries
-- one; the typechecker refuses a schema on any other domain and a Product
-- without one.
effAxesP : Parser (List (String, String))
effAxesP = defer
  t <- peekP
  effAxesFor t

effAxesFor : Token -> Parser (List (String, String))
effAxesFor TLParen = defer
  advance
  axes <- sepBy1 effAxisP (expectTok TComma)
  expectTok TRParen
  deferPure axes
effAxesFor _ = deferPure []

effAxisP : Parser (String, String)
effAxisP = defer
  name <- upperNameP
  expectTok TColon
  dom <- upperNameP
  deferPure (name, dom)

effDomainP : Parser (Option String)
effDomainP = defer
  t <- peekP
  effDomainFor t

effDomainFor : Token -> Parser (Option String)
effDomainFor (TUpper d) = defer
  advance
  deferPure (Some d)
effDomainFor _ = deferPure None

-- ── interface declarations ───────────────────────────────────────────────
parseInterface : Bool -> Bool -> Parser Decl
parseInterface pub isDefault = defer
  kw <- getPos
  expectTok TInterface
  named <- locatedUpperNameP
  let name = fst named
  let nameLoc = snd named
  ps <- tyParamsP
  supers <- ifaceSuper
  methods <- ifaceBody kw
  -- #1110: the parser has a token stream, not a module id, so it builds every
  -- type declaration identity-less; resolve acquires it (`stampDeclOrigin`).
  deferPure
    (setDeclNameLoc
      nameLoc
      (dInterfaceUnresolved
        pub
        isDefault
        name
        (map fst ps)
        (map snd ps)
        supers
        methods))

-- optional `requires Iface a, …` superclass list
ifaceSuper : Parser (List Super)
ifaceSuper = defer
  t <- peekP
  ifaceSuperFor t

ifaceSuperFor : Token -> Parser (List Super)
ifaceSuperFor TRequires = defer
  advance
  sepBy1 ifaceSuperEntry (expectTok TComma)
ifaceSuperFor _ = deferPure []

ifaceSuperEntry : Parser Super
ifaceSuperEntry = defer
  head <- upperNameP
  name <- upperQualTail head
  params <- many lowerNameP
  deferPure (superUnresolved name params)

-- `where INDENT members DEDENT` body, or a marker interface (optional where).
-- `kw` is the `interface` keyword's token index, captured before it was
-- consumed, so the missing-`where` diagnostic can be re-attributed to the
-- header line (#1160) instead of to whatever token the parser tripped over.
ifaceBody : Int -> Parser (List IfaceMethod)
ifaceBody kw = defer
  t <- peekP
  ifaceBodyFor kw t

ifaceBodyFor : Int -> Token -> Parser (List IfaceMethod)
ifaceBodyFor _ TWhere = defer
  advance
  t <- peekP
  ifaceWhereBody t
ifaceBodyFor kw t
  | endsDecl t = defer
    skipNewlines
    deferPure []
  | otherwise = fatalProblemAtP missingWhereIfaceMsg kw

ifaceWhereBody : Token -> Parser (List IfaceMethod)
ifaceWhereBody TIndent = defer
  advance
  ms <- ifaceMembers
  expectTok TDedent
  skipNewlines
  deferPure ms
ifaceWhereBody t
  | endsDecl t = defer
    skipNewlines
    deferPure []
  | otherwise = fatalP sameLineWhereIfaceMsg

-- A token that legitimately ENDS a declaration where a `where` block could
-- otherwise have started: end of line (marker interface / method-less impl),
-- a dedent closing an enclosing block, or end of file.  Anything else after a
-- header — or after its `where` — is a layout mistake, not a body (#1140/#1160);
-- a `_` arm returning an EMPTY member list swallows it, silently discarding
-- the declaration the user actually wrote.
endsDecl : Token -> Bool
endsDecl TNewline = True
endsDecl TDedent = True
endsDecl TEof = True
endsDecl _ = False

-- #1160.  `interface Shape a⏎  area : a -> Float` lexes as ONE logical line:
-- the header ends in `a`, which `canEndExpr` (LAYOUT-SEMANTICS §7.1), so the
-- deeper next line is absorbed as an application continuation rather than
-- heralding a block — the token stream never contains an INDENT to notice.
-- The parser therefore over-consumes `area` as another type parameter and only
-- trips on the `:`, one line past the real defect.  These messages are reported
-- at the HEADER KEYWORD instead (`fatalAtP`), which is the token that is
-- actually missing something.
missingWhereIfaceMsg : ParseDiagnosticKind
missingWhereIfaceMsg = MissingWhere "interface"

missingWhereImplMsg : ParseDiagnosticKind
missingWhereImplMsg = MissingWhere "impl"

-- #1140.  `where` only heralds a block when it ENDS a line (LAYOUT-SEMANTICS
-- §7.1/§9), so `interface Foo a where m : a -> String` opens no block at all and
-- `m` is not a member of anything.  Rejecting it here is deliberate: the old `_`
-- arm returned `[]`, registering an interface with ZERO methods and no
-- diagnostic, and the loss surfaced later as an unlocated "Method 'm' is not
-- part of interface 'Foo'" blaming a correct `impl`.
sameLineWhereIfaceMsg : ParseDiagnosticKind
sameLineWhereIfaceMsg = WhereSameLine "interface"

sameLineWhereImplMsg : ParseDiagnosticKind
sameLineWhereImplMsg = WhereSameLine "impl"

ifaceMembers : Parser (List IfaceMethod)
ifaceMembers = defer
  skipNewlines
  ifaceMembersLoop

ifaceMembersLoop : Parser (List IfaceMethod)
ifaceMembersLoop = parseOrElse ifaceMembersCons (deferPure [])

ifaceMembersCons : Parser (List IfaceMethod)
ifaceMembersCons = defer
  m <- ifaceMember
  skipNewlines
  rest <- ifaceMembersLoop
  deferPure (m :: rest)

-- a method signature `name : ty`, or a default method `name pats = body`
-- #1499 / D2: the [s, q) token span brackets the method NAME alone, so a
-- declaration-site diagnostic about the method (`W-PRELUDE-METHOD-SHADOW`)
-- lands on the name token rather than on the enclosing `interface` header.
-- Like `located`, this follows the invocation location policy: `parse` uses
-- placeholder spans for method names and expression locations alike.
ifaceMember : Parser IfaceMethod
ifaceMember = defer
  ctx <- contextP
  s <- getPos
  name <- identNameP
  q <- getPos
  pats <- many parseParamPat
  t <- peekP
  ifaceMemberRest name (Some (locOfSpan ctx s q)) pats t

ifaceMemberRest : String ->
  Option Loc ->
  List Pat ->
  Token ->
  Parser IfaceMethod
ifaceMemberRest name nameLoc _ TColon = defer
  advance
  ty <- parseTy
  deferPure (IfaceMethod name ty None nameLoc)
ifaceMemberRest name nameLoc pats TEqual = defer
  advance
  body <- parseBody
  deferPure
    (IfaceMethod name (TyVar "_") (Some (MethodDefault pats body)) nameLoc)
ifaceMemberRest _ _ _ _ =
  failP "expected `:` or `=` after the interface member name"

-- ── impl declarations ────────────────────────────────────────────────────
parseImpl : Bool -> Parser Decl
parseImpl pub = defer
  kw <- getPos
  expectTok TImpl
  t <- peekP
  implHead pub kw t

-- `impl Iface tyargs…`.  (Named impls — `impl name of Iface …` — have been
-- removed; a lowercase head or a stray `of` now yields a clean parse error.)
implHead : Bool -> Int -> Token -> Parser Decl
implHead pub kw (TUpper u) = defer
  ctx <- contextP
  s <- getPos
  advance
  n <- upperQualTail u
  q <- getPos
  d <- implRest pub kw n
  deferPure (setDeclNameLoc (locOfSpan ctx s q) d)
implHead _ _ (TIdent _) = failP namedImplRemovedMsg
implHead _ _ _ = failP "expected an interface name after `impl`"

implRest : Bool -> Int -> String -> Parser Decl
implRest pub kw iface = defer
  tyargs <- many parseTyAtom
  reqs <- implRequires
  methods <- implBody kw
  deferPure (dImplUnresolved pub iface tyargs reqs methods)

namedImplRemovedMsg : String
namedImplRemovedMsg =
  "named impls (`impl name of Iface`) have been removed; write a plain `impl Iface`"

defaultImplRemovedMsg : String
defaultImplRemovedMsg = "`default impl` has been removed; write a plain `impl`"

-- optional `requires Iface tyargs…, …`
implRequires : Parser (List Require)
implRequires = defer
  t <- peekP
  implRequiresFor t

implRequiresFor : Token -> Parser (List Require)
implRequiresFor TRequires = defer
  advance
  sepBy1 implRequireEntry (expectTok TComma)
implRequiresFor _ = deferPure []

implRequireEntry : Parser Require
implRequireEntry = defer
  head <- upperNameP
  iface <- upperQualTail head
  tys <- many parseTyAtom
  deferPure (requireUnresolved iface tys)

-- `kw` is the `impl` keyword's token index — see `ifaceBody` for why the
-- missing-`where` diagnostic has to be re-attributed to it (#1160).
implBody : Int -> Parser (List ImplMethod)
implBody kw = defer
  t <- peekP
  implBodyFor kw t

implBodyFor : Int -> Token -> Parser (List ImplMethod)
implBodyFor _ TWhere = defer
  advance
  t <- peekP
  implWhereBody t
implBodyFor kw t
  | endsDecl t = defer
    skipNewlines
    deferPure []
  | otherwise = fatalProblemAtP missingWhereImplMsg kw

implWhereBody : Token -> Parser (List ImplMethod)
implWhereBody TIndent = defer
  advance
  ms <- implMethods
  expectTok TDedent
  skipNewlines
  deferPure ms
implWhereBody t
  | endsDecl t = defer
    skipNewlines
    deferPure []
  | otherwise = fatalP sameLineWhereImplMsg

implMethods : Parser (List ImplMethod)
implMethods = defer
  skipNewlines
  implMethodsLoop

implMethodsLoop : Parser (List ImplMethod)
implMethodsLoop = parseOrElse implMethodsCons (deferPure [])

implMethodsCons : Parser (List ImplMethod)
implMethodsCons = defer
  m <- implMethod
  skipNewlines
  rest <- implMethodsLoop
  deferPure (m :: rest)

-- impl methods are `name pats = body` (multi-clause = repeated entries), and,
-- exactly like a top-level `parseFunOrSig` clause, may instead be a guarded
-- clause: a single `| cond = body` on the same line, or an INDENT block of
-- `| cond = body` arms (#508 — this used to be parser-only-supported at top
-- level; an impl method's clause list is already multi-clause-aware
-- downstream (`implDictPassMethods`/typecheck's per-name clause grouping),
-- so mirroring `parseFunOrSig`'s TIndent/TPipe arms is enough.
implMethod : Parser ImplMethod
implMethod = defer
  p <- getPos
  name <- identNameP
  pats <- many parseParamPat
  t <- peekP
  m <- implMethodRest name pats t
  recordUnitStart 2 p
  deferPure m

implMethodRest : String -> List Pat -> Token -> Parser ImplMethod
implMethodRest name pats TEqual = defer
  advance
  body <- parseBody
  deferPure (ImplMethod name pats body)
implMethodRest name pats TIndent = defer
  advance
  arms <- parseGuardArms
  body <- guardArmsWhereOpt arms
  expectTok TDedent
  deferPure (ImplMethod name pats body)
implMethodRest name pats TPipe = defer
  arm <- parseGuardArm
  deferPure (ImplMethod name pats (EGuards [arm]))
implMethodRest _ _ _ = failP "expected `=` or `|` after the method head"

-- a Haskell-style `where` scoping over ALL guard arms (it sits at the guards'
-- indentation, inside their INDENT block): `guards WHERE INDENT bindings DEDENT
-- newlines` → ELetGroup wrapping the EGuards.
guardArmsWhereOpt : List GuardArm -> Parser Expr
guardArmsWhereOpt arms = defer
  t <- peekP
  guardArmsWhereFor arms t

guardArmsWhereFor : List GuardArm -> Token -> Parser Expr
guardArmsWhereFor arms TWhere = defer
  advance
  expectTok TIndent
  binds <- parseWhereBindings
  expectTok TDedent
  skipNewlines
  deferPure (ELetGroup (coalesceClauses binds) (EGuards arms))
guardArmsWhereFor arms _ = deferPure (EGuards arms)

-- function guards: an INDENT block of `| guard, … = body` arms
parseGuardArms : Parser (List GuardArm)
parseGuardArms = defer
  skipNewlines
  guardArmsLoop

guardArmsLoop : Parser (List GuardArm)
guardArmsLoop = parseOrElse guardArmsCons (deferPure [])

guardArmsCons : Parser (List GuardArm)
guardArmsCons = defer
  a <- parseGuardArm
  skipNewlines
  rest <- guardArmsLoop
  deferPure (a :: rest)

-- The inverse of the match-arm case (#591): an equation (function-clause) guard
-- uses `|`, but a user with the match-arm `if` habit writes `if cond = body`.
-- Only commit (`fatalP` at the `if`) when the line has the guard SHAPE — a
-- top-level `=` before any `then`/end-of-line — so a genuine, if malformed,
-- `if … then …` body isn't mis-blamed as a guard; otherwise fall through to the
-- ordinary `expectTok TPipe` failure.
parseGuardArm : Parser GuardArm
parseGuardArm = defer
  t <- peekP
  parseGuardArmFor t

parseGuardArmFor : Token -> Parser GuardArm
parseGuardArmFor TIf = defer
  looksGuard <- eqGuardShapeP
  parseGuardArmIf looksGuard
parseGuardArmFor _ = parseGuardArmBody

parseGuardArmIf : Bool -> Parser GuardArm
parseGuardArmIf True = fatalP eqGuardIfMsg
parseGuardArmIf False = parseGuardArmBody

parseGuardArmBody : Parser GuardArm
parseGuardArmBody = defer
  expectTok TPipe
  guards <- sepBy1 parseGuard (expectTok TComma)
  expectTok TEqual
  body <- parseBody
  deferPure (GuardArm guards body)
eqGuardIfMsg : ParseDiagnosticKind
eqGuardIfMsg = EquationGuardIf

-- true when, from token `i` at bracket depth 0, a top-level `=` appears before
-- any `then` / end-of-line: the `if …` heads an equation guard (`if cond = body`),
-- not an `if … then … else …` expression.  Bracket depth keeps a `then`/`=`
-- inside a parenthesised condition from being counted (mirrors the depth-tracked
-- line scanners below).
eqGuardShapeFrom : Array Token -> Int -> Int -> Bool
eqGuardShapeFrom toks i depth
  | i >= arrayLength toks = False
  | depth == 0 && isLineEndTok (peekTok toks i) = False
  | depth == 0 && isThenTok (peekTok toks i) = False
  | depth == 0 && isEqualTok (peekTok toks i) = True
  | isBracketOpenTok (peekTok toks i) =
    eqGuardShapeFrom toks (i + 1) (depth + 1)
  | isBracketCloseTok (peekTok toks i) =
    eqGuardShapeFrom toks (i + 1) (depth - 1)
  | otherwise = eqGuardShapeFrom toks (i + 1) depth

eqGuardShapeP : Parser Bool
eqGuardShapeP =
  ParserE (ctx pos => POk (eqGuardShapeFrom (contextTokens ctx) pos 0) pos)

-- A guard qualifier parses at the `expr_or` level (mirrors the reference
-- `guard_qual`): NOT full `parseExpr`, so a trailing `=>` in a match-arm guard
-- isn't swallowed as a lambda, and `<-`/`,` stay as the bind/separator tokens.
parseGuard : Parser Guard
parseGuard = defer
  e <- parseOr
  t <- peekP
  guardFor e t

guardFor : Expr -> Token -> Parser Guard
guardFor e TLArrow = defer
  advance
  rhs <- parseOr
  deferPure (GBind (exprToPat e) rhs)
guardFor e _ = deferPure (GBool e)

-- ── data / record declarations ──────────────────────────────────────────
lowerNameP : Parser String
lowerNameP = defer
  t <- peekP
  lowerNameFor t

lowerNameFor : Token -> Parser String
lowerNameFor (TIdent x) = emit x
lowerNameFor _ = failP "expected a type parameter"

-- ── declared type-parameter kinds (EFFECTS-SEMANTICS §6.1/§6.2) ─────────
-- `TyParam ::= name | ( name : Kind )`, `Kind ::= Type | Effect | Kind ->
-- Kind | ( Kind )`, arrow right-associative.  `Type`/`Effect` are ordinary
-- capitalised identifiers matched only here, in kind position — they are NOT
-- keywords, so a type or constructor may still be called either of them.
--
-- All four parameterised heads (`data`/`newtype`/`type`/`interface`) bind
-- their parameters through `tyParamsP`, which is exactly the §6.2 table: an
-- `impl` head names types rather than binding parameters and never reaches
-- here, so it takes no annotation without any code saying so.
--
-- A malformed annotation fails with `failP`, so `many` un-consumes the `(`
-- and the head's own `expectTok` reports the position.  That is safe because
-- nothing else in these four heads may follow the parameter list with a `(`.
tyParamsP : Parser (List (String, Option KindAnn))
tyParamsP = many tyParamP

tyParamP : Parser (String, Option KindAnn)
tyParamP = defer
  t <- peekP
  tyParamFor t

tyParamFor : Token -> Parser (String, Option KindAnn)
tyParamFor TLParen = defer
  advance
  n <- lowerNameP
  expectTok TColon
  k <- kindP
  expectTok TRParen
  deferPure (n, Some k)
tyParamFor t = defer
  n <- lowerNameFor t
  deferPure (n, None)

kindP : Parser KindAnn
kindP = defer
  a <- kindAtomP
  t <- peekP
  kindArrowRest a t

kindArrowRest : KindAnn -> Token -> Parser KindAnn
kindArrowRest a TArrow = defer
  advance
  b <- kindP
  deferPure (KindArrow a b)
kindArrowRest a _ = deferPure a

kindAtomP : Parser KindAnn
kindAtomP = defer
  t <- peekP
  kindAtomFor t

kindAtomFor : Token -> Parser KindAnn
kindAtomFor (TUpper c)
  | c == "Type" = kindAtomEmit KindType
  | c == "Effect" = kindAtomEmit KindEffect
  | c == "Authority" = kindAuthorityP
  | otherwise = failP kindExpectedMsg
kindAtomFor TLParen = defer
  advance
  k <- kindP
  expectTok TRParen
  deferPure k
kindAtomFor _ = failP kindExpectedMsg

kindExpectedMsg : String
kindExpectedMsg =
  "expected a kind: `Type`, `Effect`, `Authority <Label>` or an arrow between them"

-- `Authority FileRead`: the parameter ranges over the declared domain of the
-- named effect label (EFFECTS-SEMANTICS §6.1).
kindAuthorityP : Parser KindAnn
kindAuthorityP = defer
  ctx <- contextP
  advance
  s <- getPos
  l <- upperNameP
  pat <- patternMarkP
  q <- getPos
  deferPure (kindAuthorityUnstamped l pat (Some (locOfSpan ctx s q)))

-- The `*` after a label that makes a binder range over the domain's patterns
-- only: `Authority FileWrite*`, `(dir : String @FileWrite*)`.
patternMarkP : Parser Bool
patternMarkP = defer
  t <- peekP
  patternMarkFor t

patternMarkFor : Token -> Parser Bool
patternMarkFor TStar = defer
  advance
  deferPure True
patternMarkFor _ = deferPure False

kindAtomEmit : KindAnn -> Parser KindAnn
kindAtomEmit k = defer
  advance
  deferPure k

parseData : DataVis -> Parser Decl
parseData vis = defer
  expectTok TData
  named <- locatedUpperNameP
  let name = fst named
  let nameLoc = snd named
  ps <- tyParamsP
  bodyAndDerives <- dataBody name
  let variants = fst bodyAndDerives
  let blockDerives = snd bodyAndDerives
  outerDerives <- derivingClause
  skipNewlines
  deferPure
    (setDeclNameLoc
      nameLoc
      (dDataUnresolved
        vis
        name
        (map fst ps)
        (map snd ps)
        (map fst variants)
        (map snd variants)
        (combineDerives blockDerives outerDerives)))
-- block form may carry `deriving (…)` INSIDE the INDENT span (own line or
-- trailing the last constructor); that is captured by dataBody.  The inline
-- form leaves derives empty here and the trailing derivingClause picks it up.

-- block-form deriving (inside the INDENT) and inline-form deriving (after the
-- DEDENT) are mutually exclusive in practice; prefer whichever is non-empty.
combineDerives : List DeriveRef -> List DeriveRef -> List DeriveRef
combineDerives [] outer = outer
combineDerives block _ = block

-- inline (`= …`) or block (`INDENT = … DEDENT`) variant list.  Returns the
-- variants paired with any deriving names found INSIDE a block body (empty for
-- the inline form).
dataBody : String -> Parser (List (Variant, CtorBinders), List DeriveRef)
dataBody tyName = defer
  t <- peekP
  dataBodyFor tyName t

dataBodyFor : String ->
  Token ->
  Parser (List (Variant, CtorBinders), List DeriveRef)
dataBodyFor tyName TEqual = defer
  advance
  t <- peekP
  dataAfterEq tyName t
dataBodyFor tyName TIndent = defer
  advance
  expectTok TEqual
  vs <- dataVariantsN tyName
  derives <- derivingClause
  skipNewlines
  expectTok TDedent
  deferPure (vs, derives)
-- `deriving (…)` may sit INSIDE the block (the lexer keeps the indented
-- deriving line within the INDENT/DEDENT), so consume it before the DEDENT.
-- derivingClause stops at the RPAREN; skip its trailing NEWLINE so the DEDENT
-- is the next token.

dataBodyFor _ _ = deferPure ([], [])

-- After a header-line `=` (inline `data Foo = …`) the body is EITHER an inline
-- variant list on the same line, OR — the new multiline form — a line-final `=`
-- followed by an indented block whose variants each carry a leading `|`:
--   data Foo =
--     | Bar
--     | Baz
-- An INDENT here means the latter (the `=` was line-final).  The leading `|`
-- before the first variant is optional (lenient); the formatter always emits it.
-- `deriving (…)` inside the block is consumed before the DEDENT, mirroring the
-- old `TIndent` block form.
dataAfterEq : String ->
  Token ->
  Parser (List (Variant, CtorBinders), List DeriveRef)
dataAfterEq tyName TIndent = defer
  advance
  skipNewlines
  _ <- optPipe
  vs <- dataVariantsN tyName
  derives <- derivingClause
  skipNewlines
  expectTok TDedent
  deferPure (vs, derives)
dataAfterEq tyName _ = defer
  vs <- dataVariantsN tyName
  t <- peekP
  derives <- inlineTrailingDerives t
  deferPure (vs, derives)

-- A one-line `data X = A | B` may still carry `deriving (…)` on its own,
-- more-indented, next line — the lexer wraps that as an INDENT/DEDENT span
-- (mirroring the block form's own-line deriving) even though the header
-- itself never opened a block.
-- `newtype`: `deriving (…)` inline after the payload type, or on its own
-- more-indented next line, exactly as a one-line `data` accepts it.
newtypeDerives : Token -> Parser (List DeriveRef)
newtypeDerives TIndent = inlineTrailingDerives TIndent
newtypeDerives _ = derivingClause

inlineTrailingDerives : Token -> Parser (List DeriveRef)
inlineTrailingDerives TIndent = defer
  advance
  derives <- derivingClause
  skipNewlines
  expectTok TDedent
  deferPure derives
inlineTrailingDerives _ = deferPure []

-- Consume a leading `|` if present (the new multiline form's per-variant pipe
-- also prefixes the first variant); a no-op otherwise.
optPipe : Parser Unit
optPipe = defer
  t <- peekP
  optPipeFor t

optPipeFor : Token -> Parser Unit
optPipeFor TPipe = defer
  advance
  deferPure ()
optPipeFor _ = deferPure ()

-- Variant list with the tycon name in scope, so the anonymous short form
-- `data X = { … }` (a single brace-group, no ctor name, no `|`) can synthesize
-- a single named constructor whose name is the tycon name (`X`), flagged
-- `nameOmitted = True` so the printer round-trips the short form.  Any other
-- shape falls through to the normal `dataVariants` path.  A leading `{` is the
-- unambiguous trigger — no legal named/positional variant starts with `{`.
-- A constructor's existential binders (EFFECTS-SEMANTICS §4.1): kinded
-- parameters written between its name and its fields, `AnyHandle (p :
-- Authority FileRead) (Handle p)`.  They ride beside the variant until the
-- declaration is built, where they become `dataCtorBinders`.
type CtorBinders = List (String, KindAnn)

dataVariantsN : String -> Parser (List (Variant, CtorBinders))
dataVariantsN tyName = defer
  t <- peekP
  dataVariantsNFor tyName t

dataVariantsNFor : String -> Token -> Parser (List (Variant, CtorBinders))
dataVariantsNFor tyName TLBrace = defer
  fields <- parseNamedFields
  deferPure [(Variant tyName (ConNamed fields True), [])]
dataVariantsNFor _ _ = dataVariants

dataVariants : Parser (List (Variant, CtorBinders))
dataVariants = defer
  v <- parseVariant
  rest <- variantsRest
  deferPure (v :: rest)

variantsRest : Parser (List (Variant, CtorBinders))
variantsRest = defer
  skipNewlines
  t <- peekP
  variantsRestFor t

variantsRestFor : Token -> Parser (List (Variant, CtorBinders))
variantsRestFor TPipe = defer
  advance
  v <- parseVariant
  rest <- variantsRest
  deferPure (v :: rest)
variantsRestFor _ = deferPure []

parseVariant : Parser (Variant, CtorBinders)
parseVariant = defer
  name <- upperNameP
  binders <- ctorBindersP
  payload <- parsePayload
  deferPure (Variant name payload, binders)

-- `(p : Kind)` groups leading a constructor's fields.  Only an `Authority`
-- kind is an existential Medaka can open (a match arm gives it a fresh rigid
-- authority); any other kind here is refused with the reason, so a type or
-- row existential cannot parse as a silent no-op.  A group that is not a
-- kinded binder (`(String @p)`, `(p : String)`) fails softly and is read as
-- the payload it is.
ctorBindersP : Parser CtorBinders
ctorBindersP = many ctorBinderP

ctorBinderP : Parser (String, KindAnn)
ctorBinderP = defer
  t <- peekP
  t2 <- peek2P
  ctorBinderFor t t2

ctorBinderFor : Token -> Token -> Parser (String, KindAnn)
ctorBinderFor TLParen (TIdent _) = defer
  t3 <- peek3P
  ctorBinderColon t3
ctorBinderFor _ _ = failP "expected a constructor binder"

ctorBinderColon : Token -> Parser (String, KindAnn)
ctorBinderColon TColon = defer
  advance
  n <- lowerNameP
  expectTok TColon
  k <- kindP
  expectTok TRParen
  ctorBinderKind n k
ctorBinderColon _ = failP "expected a constructor binder"

ctorBinderKind : String -> KindAnn -> Parser (String, KindAnn)
ctorBinderKind n (k@(KindAuthority _ _ _ _)) = deferPure (n, k)
ctorBinderKind n k = defer
  pos <- getPos
  fatalAtP
    "a constructor may bind only an `Authority` existential, not `(\{n} : \{kindAnnSource k})`; declare `\{n}` on the type's head instead"
    pos

parsePayload : Parser ConPayload
parsePayload = defer
  t <- peekP
  payloadFor t

payloadFor : Token -> Parser ConPayload
payloadFor TLBrace = parseNamedPayload
payloadFor _ = defer
  tys <- many parseTyAtom
  deferPure (ConPos tys)

parseNamedPayload : Parser ConPayload
parseNamedPayload = defer
  fields <- parseNamedFields
  deferPure (ConNamed fields False)

-- The brace-group of a named-field payload: `{ f0 : T0, f1 : T1, … }`.  Shared
-- by the explicit-name form (`parseNamedPayload`) and the anonymous short form
-- (`data X = { … }`, `dataAnonVariant`).
parseNamedFields : Parser (List Field)
parseNamedFields = defer
  expectTok TLBrace
  fields <- sepBy1 parseField (expectTok TComma)
  optTrailingComma
  expectTok TRBrace
  deferPure fields

parseField : Parser Field
parseField = defer
  name <- identNameP
  expectTok TColon
  t <- parseTy
  deferPure (Field name t)

-- `deriving (Name, …)`, after the variant/field block; optional
derivingClause : Parser (List DeriveRef)
derivingClause = defer
  skipNewlines
  t <- peekP
  derivingFor t

derivingFor : Token -> Parser (List DeriveRef)
derivingFor TDeriving = defer
  advance
  expectTok TLParen
  names <- sepBy1 derivedNameP (expectTok TComma)
  expectTok TRParen
  deferPure names
derivingFor _ = deferPure []

-- One name in a `deriving (…)` list, wrapped with its own token span so a
-- "cannot derive" diagnostic underlines the NAME.  Real only on the
-- `parseLocated` path (`parse` uses placeholder locations), the
-- same convention `TyCon`'s `Option Loc` already follows.
derivedNameP : Parser DeriveRef
derivedNameP = defer
  ctx <- contextP
  s <- getPos
  n <- upperNameP
  q <- getPos
  deferPure (DeriveRef n (Some (locOfSpan ctx s q)))

-- a decl body is an inline expr, or an INDENT block of statements: a single
-- expression statement unwraps to that expr; anything else becomes an EBlock
parseBody : Parser Expr
parseBody = parseOrElse indentedBody parseBodyExpr

-- an inline body expr, optionally followed by a Haskell-style `where` block:
-- `<expr> INDENT where INDENT bindings DEDENT NEWLINE DEDENT` → ELetGroup
parseBodyExpr : Parser Expr
parseBodyExpr = defer
  e <- parseExpr
  parseOrElse (whereEol e) (parseOrElse (whereTail e) (deferPure e))

-- end-of-line `where` (the `where` sits on the body line):
-- `<expr> WHERE INDENT bindings DEDENT` → ELetGroup
whereEol : Expr -> Parser Expr
whereEol e = defer
  expectTok TWhere
  expectTok TIndent
  binds <- parseWhereBindings
  expectTok TDedent
  deferPure (ELetGroup (coalesceClauses binds) e)

whereTail : Expr -> Parser Expr
whereTail e = defer
  expectTok TIndent
  expectTok TWhere
  expectTok TIndent
  binds <- parseWhereBindings
  expectTok TDedent
  skipNewlines
  expectTok TDedent
  deferPure (ELetGroup (coalesceClauses binds) e)

parseWhereBindings : Parser (List (String, List Pat, Expr, Loc))
parseWhereBindings = defer
  skipNewlines
  whereBindingsLoop

whereBindingsLoop : Parser (List (String, List Pat, Expr, Loc))
whereBindingsLoop = parseOrElse whereBindingsCons (deferPure [])

whereBindingsCons : Parser (List (String, List Pat, Expr, Loc))
whereBindingsCons = defer
  b <- parseWhereBinding
  skipNewlines
  rest <- whereBindingsLoop
  deferPure (b :: rest)

parseWhereBinding : Parser (String, List Pat, Expr, Loc)
parseWhereBinding = defer
  ctx <- contextP
  p <- getPos
  name <- identNameP
  pats <- many parseParamPat
  t <- peekP
  b <- whereBindRest name pats t
  recordUnitStart 3 p
  deferPure (withBindSite (locOfSpan ctx p (p + 1)) b)

withBindSite : Loc -> (String, List Pat, Expr) -> (String, List Pat, Expr, Loc)
withBindSite site (name, pats, body) = (name, pats, body, site)

whereBindRest : String -> List Pat -> Token -> Parser (String, List Pat, Expr)
-- annotated binding `go : ty = body` (no params only, mirrors let-in / block-let)
whereBindRest name [] TColon = defer
  advance
  ty <- parseTy
  expectTok TEqual
  body <- parseRhsExpr
  deferPure (name, [], EAnnot body ty)
whereBindRest name pats TEqual = defer
  advance
  body <- parseRhsExpr
  deferPure (name, pats, body)
whereBindRest name pats TIndent = defer
  advance
  arms <- parseGuardArms
  expectTok TDedent
  deferPure (name, pats, EGuards arms)
whereBindRest name pats TPipe = defer
  arm <- parseGuardArm
  deferPure (name, pats, EGuards [arm])
whereBindRest _ _ _ = failP "expected a body for the `where` binding"

-- group CONSECUTIVE same-name bindings into one LetBind (mirrors the reference
-- `coalesce_clauses`), so `go … = …` over several lines becomes one entry,
-- sited at its first clause
coalesceClauses : List (String, List Pat, Expr, Loc) -> List LetBind
coalesceClauses [] = []
coalesceClauses ((name, ps, b, site) :: rest) =
  coalesceGo name site [FunClause ps b] rest

coalesceGo : String ->
  Loc ->
  List FunClause ->
  List (String, List Pat, Expr, Loc) ->
  List LetBind
coalesceGo name site acc [] = [LetBind name (reverseL acc) site noBinderId]
coalesceGo name site acc ((n, ps, b, nsite) :: rest) =
  coalesceStep name site acc n ps b nsite rest

coalesceStep : String ->
  Loc ->
  List FunClause ->
  String ->
  List Pat ->
  Expr ->
  Loc ->
  List (String, List Pat, Expr, Loc) ->
  List LetBind
coalesceStep name site acc n ps b nsite rest
  | n == name = coalesceGo name site (FunClause ps b :: acc) rest
  | otherwise =
    LetBind name (reverseL acc) site noBinderId
      :: coalesceGo n nsite [FunClause ps b] rest

-- Same offside-block production as `parseBracketBlock` (#602: the two must not
-- fork into independently-maintained byte-identical copies — one backing decl
-- bodies, the other let/where RHS and lambda bodies — exactly the class of
-- silent-divergence hazard `rule-duplicate-body` exists to catch). Consolidated
-- to a single definition; both call sites keep their own name since each is
-- reached from a different grammar context.
indentedBody : Parser Expr
indentedBody = parseBracketBlock

blockOrExpr : List DoStmt -> Expr
blockOrExpr [DoExpr e] = e
blockOrExpr stmts = EBlock stmts

-- `do <INDENT stmt block DEDENT>` → a monadic do-block
parseDo : Parser Expr
parseDo = parseDoBlock TDo False

-- `defer <INDENT stmt block DEDENT>` → a deferred do-block (#824).  Identical
-- grammar to `do`; only the EDo flag differs, which routes desugar to
-- `deferThen`/`deferPure` instead of `andThen`/`pure`.
parseDefer : Parser Expr
parseDefer = parseDoBlock TDefer True

parseDoBlock : Token -> Bool -> Parser Expr
parseDoBlock herald deferred = defer
  expectTok herald
  expectTok TIndent
  p0 <- getPos
  r <- doStmtsFrom p0
  expectTok TDedent
  doBlockResult herald (fst r) (snd r)

-- The statements of a `do`/`defer` block, paired with the token index where the
-- LAST source statement starts (`p0` for an empty block).
doStmtsFrom : Int -> Parser (Int, List DoStmt)
doStmtsFrom p0 = defer
  skipNewlines
  doStmtsLoop p0

doStmtsLoop : Int -> Parser (Int, List DoStmt)
doStmtsLoop lastStart = parseOrElse doStmtsCons (deferPure (lastStart, []))

doStmtsCons : Parser (Int, List DoStmt)
doStmtsCons = defer
  p <- getPos
  ss <- parseStmt
  skipNewlines
  r <- doStmtsLoop p
  deferPure (fst r, ss ++ snd r)

-- A do block's value is its last expression, so a trailing `let` or `x <- e`
-- has nothing to yield; reported at that statement.
doBlockResult : Token -> Int -> List DoStmt -> Parser Expr
doBlockResult herald lastStart stmts = match last stmts
  Some (DoLet _ _ _ _ _) =>
    fatalProblemAtP (doEndsInBindingMsg herald) lastStart
  Some (DoBind _ _) => fatalProblemAtP (doEndsInBindingMsg herald) lastStart
  _ => deferPure (EDo (isDeferTok herald) stmts)
doEndsInBindingMsg : Token -> ParseDiagnosticKind
doEndsInBindingMsg herald = BlockEndsBinding (blockWord herald)

blockWord : Token -> String
blockWord TDefer = "defer"
blockWord _ = "do"

-- statements, NEWLINE-separated, until the block's DEDENT
-- A statement-let / where RHS, or a lambda body (`lamTailRaw`): a bare-INDENT
-- block (the RHS sits on its own indented line, e.g. `let n =\n    length pairs`
-- or `g x =>\n  g + x`), or an ordinary expression.  Every herald that opens
-- such a block is one `canEndExpr` omits — see LAYOUT-SEMANTICS.md §7.1.
-- Mirrors parser.mly's `expr_no_block` including the
-- `INDENT nonempty_list(stmt) DEDENT` production, which lets a let binding's RHS
-- be an indented block.  Without this the lexer's (correct, oracle-identical)
-- `LET n EQUAL INDENT … DEDENT` stream had no parser rule and failed to parse.
parseRhsExpr : Parser Expr
parseRhsExpr = parseOrElse parseBracketBlock parseExpr

parseStmts : Parser (List DoStmt)
parseStmts = defer
  skipNewlines
  stmtsLoop

stmtsLoop : Parser (List DoStmt)
stmtsLoop = parseOrElse stmtsCons (deferPure [])

stmtsCons : Parser (List DoStmt)
stmtsCons = defer
  ss <- parseStmt
  skipNewlines
  rest <- stmtsLoop
  deferPure (ss ++ rest)

-- one surface statement → one OR MORE DoStmts (an annotated do-bind
-- `x : ty <- e` expands to two: the bind + a shadowing annotated let)
parseStmt : Parser (List DoStmt)
parseStmt = defer
  p <- getPos
  t <- peekP
  ss <- stmtFor t
  recordUnitStart 1 p
  deferPure ss

stmtFor : Token -> Parser (List DoStmt)
stmtFor TLet = defer
  s <- parseLetStmt
  deferPure [s]
stmtFor _ = parseExprStmt

-- a `let` statement: `let mut p = e`, function-let `let f a… = e`, plain
-- `let p = e`, let-in (→ DoExpr), or let-else `let p = e else alt`
parseLetStmt : Parser DoStmt
parseLetStmt = defer
  ctx <- contextP
  s <- getPos
  expectTok TLet
  t <- peekP
  stmt <- letKind t
  deferPure (letStmtAt (locOfSpan ctx s (s + 1)) stmt)

-- `letKind`'s productions build a statement `DoLet` or a `let … in` with
-- `noDeclLoc`; the site of either is the `let` keyword, which only
-- `parseLetStmt` has seen.
letStmtAt : Loc -> DoStmt -> DoStmt
letStmtAt site (DoLet m r p e _) = DoLet m r p e site
letStmtAt site (DoExpr e) = DoExpr (atLetSite site e)
letStmtAt _ stmt = stmt

-- [e] with [site] as its `let` keyword's span when it is a `let … in`.
atLetSite : Loc -> Expr -> Expr
atLetSite site (ELet _ r p e1 e2) = ELet site r p e1 e2
atLetSite _ e = e

letKind : Token -> Parser DoStmt
-- beta mutability model: `let mut` has been removed — rejected at the parser
-- (see `letMutRemovedMsg`), so no `mut` flag is ever built downstream.
letKind TMut = failP letMutRemovedMsg
letKind TRec = letRecStmt
letKind (TIdent name) = letIdent name
letKind _ = letPat

-- REC-led: block-level `let rec f a… = e [in/else]` (#645). A plain
-- function-let is already self-recursive (`letFunTailFor` always builds an
-- `isRec=True` node), so `rec` here only matters for the zero-param value
-- form (`let rec x = …`, otherwise non-recursive) — but both shapes are
-- accepted, mirroring top-level `let rec`/expr-level `letRecExpr`. Reuses
-- `letFunTailFor` rather than duplicating its `in`/no-`in` tail dispatch.
letRecStmt : Parser DoStmt
letRecStmt = defer
  ctx <- contextP
  expectTok TRec
  s <- getPos
  name <- identNameP
  q <- getPos
  pats <- many parseParamPat
  expectTok TEqual
  e1 <- parseRhsExpr
  t <- peekP
  letFunTailFor name (locOfSpan ctx s q) pats e1 t

-- IDENT-led: function-let `let f a… = e` (params present), annotated
-- `let x : ty = e`, or plain `let x = e [in/else]`
letIdent : String -> Parser DoStmt
letIdent name = defer
  ctx <- contextP
  s <- getPos
  advance
  pats <- many parseParamPat
  t <- peekP
  letIdentBody name (locOfSpan ctx s (s + 1)) pats t

-- annotation (`: ty`) only on the no-params case, mirroring the let-in path
letIdentBody : String -> Loc -> List Pat -> Token -> Parser DoStmt
letIdentBody name nameLoc [] TColon = defer
  advance
  ty <- parseTy
  expectTok TEqual
  e1 <- parseRhsExpr
  letIdentRest name nameLoc [] (EAnnot e1 ty)
letIdentBody name nameLoc pats _ = defer
  expectTok TEqual
  e1 <- parseRhsExpr
  letIdentRest name nameLoc pats e1

letIdentRest : String -> Loc -> List Pat -> Expr -> Parser DoStmt
letIdentRest name nameLoc [] e1 = defer
  t <- peekP
  letTailFor (PVar name nameLoc noBinderId) e1 t
letIdentRest name nameLoc pats e1 = defer
  t <- peekP
  letFunTailFor name nameLoc pats e1 t

-- `let f params = e1 in e2` → DoExpr (ELet); without `in` → DoLet (stmt)
letFunTailFor : String -> Loc -> List Pat -> Expr -> Token -> Parser DoStmt
letFunTailFor name nameLoc pats e1 TIn = defer
  advance
  e2 <- parseExpr
  deferPure
    (DoExpr
      (ELet
        noDeclLoc
        True
        (PVar name nameLoc noBinderId)
        (curryLam pats e1)
        e2))
letFunTailFor name nameLoc pats e1 _ =
  deferPure
    (DoLet
      False
      True
      (PVar name nameLoc noBinderId)
      (curryLam pats e1)
      noDeclLoc)

-- non-IDENT-led pattern: `let (a, b) = e`, `let Some v = e`, …
letPat : Parser DoStmt
letPat = defer
  pat <- parsePat
  expectTok TEqual
  e1 <- parseRhsExpr
  t <- peekP
  letTailFor pat e1 t

letTailFor : Pat -> Expr -> Token -> Parser DoStmt
letTailFor pat e1 TIn = defer
  advance
  e2 <- parseExpr
  deferPure (DoExpr (ELet noDeclLoc False pat e1 e2))
letTailFor pat e1 _ = deferPure (DoLet False False pat e1 noDeclLoc)

-- mirror the reference `curry_lam`: one single-arg ELam per param
curryLam : List Pat -> Expr -> Expr
curryLam [] body = body
curryLam (p :: ps) body = ELam [p] (curryLam ps body)

-- `pat <- e` is a DoBind (LHS parsed as an expr, reinterpreted); `lhs = e` is
-- a `DoAssign`; a field-path assignment is rejected (`fieldAssignRemovedMsg`);
-- else a bare DoExpr
parseExprStmt : Parser (List DoStmt)
parseExprStmt = defer
  startPos <- getPos
  e <- parseExpr
  t <- peekP
  exprStmtFor startPos e t

exprStmtFor : Int -> Expr -> Token -> Parser (List DoStmt)
exprStmtFor _ e TLArrow = defer
  advance
  rhs <- parseExpr
  deferPure (bindStmts e rhs)
exprStmtFor startPos e TEqual = defer
  advance
  rhs <- parseExpr
  s <- assignFromLhs startPos e rhs
  deferPure [s]
exprStmtFor _ e _ = deferPure [DoExpr e]

-- `pat <- e` → one DoBind; an annotated var LHS `x : ty <- e` → the bind PLUS a
-- shadowing `let x = (x : ty)` so x is bound AND its declared type is enforced
-- (there is no annotated-pattern node to carry the type on the binder directly)
bindStmts : Expr -> Expr -> List DoStmt
bindStmts lhs rhs = match stripLoc lhs
  EAnnot inner ty => bindAnnot inner ty rhs
  _ => [DoBind (exprToPat lhs) rhs]

bindAnnot : Expr -> Ty -> Expr -> List DoStmt
bindAnnot inner ty rhs = match stripLoc inner
  EVar x => [
    DoBind (PVar x (Loc "" 0 0 0 0) noBinderId) rhs,
    DoLet
      False
      False
      (PVar x (Loc "" 0 0 0 0) noBinderId)
      (EAnnot (EVar x) ty)
      noDeclLoc,
  ]
  other => [DoBind (exprToPat other) rhs]

-- a `lhs = rhs` statement: bare var → DoAssign; a field path is rejected at the
-- statement's start (`fatalAtP`, so the message survives `many` recovery)
assignFromLhs : Int -> Expr -> Expr -> Parser DoStmt
assignFromLhs startPos lhs rhs = match flattenFieldPath lhs
  Some (x, []) => deferPure (DoAssign x rhs)
  Some (x, fs) => fatalAtP (fieldAssignRemovedMsg x fs) startPos
  None => failP "invalid assignment target in this block"

-- Block field assignment (`v.x = e`, `a.b.c = e`) is removed: bindings are
-- immutable and it never typechecked.  A lowercase head is a record variable,
-- so the hint names its record-update form.  A capitalised head is a module
-- alias (lowercase aliases do not parse) or a constructor, so it gets the generic hint.
fieldAssignRemovedMsg : String -> List String -> String
fieldAssignRemovedMsg x fs =
  let path = joinWith "." (x :: fs)
  if isCtorName x then
    "field assignment `\{path} = e` has been removed; bindings are immutable, so bind the new value to a new name"
  else
    "field assignment `\{path} = e` has been removed; build an updated record instead, `\{recordUpdateText x fs}`"

-- `a`, [b, c] → `{ a | b = { a.b | c = e } }`
recordUpdateText : String -> List String -> String
recordUpdateText _ [] = "e"
recordUpdateText base [f] = "{ \{base} | \{f} = e }"
recordUpdateText base (f :: fs) =
  let inner = recordUpdateText "\{base}.\{f}" fs
  "{ \{base} | \{f} = \{inner} }"

-- `a` → Some (a, []); `a.b.c` → Some (a, [b, c]); anything else → None.
-- Strips ELoc wrappers (the base var and any sub-access are wrapped atoms).
flattenFieldPath : Expr -> Option (String, List String)
flattenFieldPath (ELoc _ e) = flattenFieldPath e
flattenFieldPath (EVar x) = Some (x, [])
flattenFieldPath (EFieldAccess inner f _) =
  fieldPathExtend (flattenFieldPath inner) f
flattenFieldPath _ = None

fieldPathExtend : Option (String, List String) ->
  String ->
  Option (String, List String)
fieldPathExtend (Some (x, fs)) f = Some (x, fs ++ [f])
fieldPathExtend None _ = None

-- skip layout noise (NEWLINE/INDENT/DEDENT) between top-level decls; recurse
-- through a do-continuation (see skipNewlines) to avoid a recursive-value cycle
skipNoise : Parser Unit
skipNoise = defer
  t <- peekP
  skipNoiseFor t

skipNoiseFor : Token -> Parser Unit
skipNoiseFor TNewline = afterNoise
skipNoiseFor TIndent = afterNoise
skipNoiseFor TDedent = afterNoise
skipNoiseFor _ = deferPure ()

afterNoise : Parser Unit
afterNoise = defer
  advance
  skipNoise

declThenNoise : Parser Decl
declThenNoise = defer
  d <- parseDecl
  skipNoise
  deferPure d

parseProgram : Parser (List Decl)
parseProgram = defer
  skipNoise
  many declThenNoise

-- ── Position side-channel ─────────────────────────────────────────────────
-- Three channels, surfaced for `medaka fmt`'s
-- comment-interleaving engine (`format_program`):
--   * decl_positions  — per top-level decl, a (line, end_line) pair, in source
--                        order;
--   * variant_lines   — start line of each `data` variant, flat across the file
--                        in decl order;
--   * last_content_line — the line of the last non-trivia token in the file.
-- These are computed *out of band* from the token/line arrays produced by
-- `tokenizeWithOffsetPairs`: parsing itself is untouched (the AST has no `loc`).  Each
-- decl is parsed with its start/end token index captured via `getPos`; lines
-- come from the parallel line array; variant start lines are re-derived from the
-- decl's token span (the data-body's depth-0 `=`/`|` separators).
-- Third field (#331, increment 1): the decl's NAME-token span, `None` only
-- when the name-finder can't locate one (`DUse` — see `declNameTokIdxAt`;
-- `DImpl`'s head now always resolves, to its head `TyCon` or the `impl`
-- keyword itself — F4/increment 5).  Additive — every existing consumer
-- reads only `declPosLine`/`declPosEndLine` (never a positional match on
-- `DeclPos`), so this is snapshot-invisible (`snapshot.mdk:renderDeclPos`
-- reads accessors only) and requires no change anywhere but this file and the
-- LSP consumers that want the real span.
-- Fourth field (#331, increment 2 — child-name spans, channel-first): the
-- ORDERED list of the decl's document-outline CHILD name-token `Loc`s (variant
-- ctors, record fields, interface/impl methods, the single let-bind), in the
-- EXACT order `syntax_queries.mdk:symbolPartsOfDecl` emits them.  `Some l` per child whose
-- name token was located, `None` where the finder missed (the LSP falls back to
-- the parent decl range for that child).  `[]` for decls with no outline
-- children.  Also additive/accessor-only, so still snapshot-invisible.
-- ⚠️ INVARIANT: this list's order/length must track `symbolPartsOfDecl`'s
-- child traversal exactly — guarded by `test/mcp_fixtures/child_spans.mdk`.
-- Parse one decl, capturing the (startTokIdx, endTokIdx) span around it.
declWithSpan : Parser (Decl, Int, Int)
declWithSpan = defer
  s <- getPos
  d <- parseDecl
  e <- getPos
  deferPure (d, s, e)

-- Program parse that records each decl's token span, mirroring parseProgram's
-- skipNoise + many declThenNoise but threading spans.
spanDeclThenNoise : Parser (Decl, Int, Int)
spanDeclThenNoise = defer
  ds <- declWithSpan
  skipNoise
  deferPure ds

programWithSpans : Parser (List (Decl, Int, Int))
programWithSpans = defer
  skipNoise
  many spanDeclThenNoise

-- Parse `src` and return the position side-channel alongside the decls.  The
-- non-panicking `parseWithPositionsOpt` does the work; this wrapper preserves the
-- panic-on-unparseable behaviour the compiler + `medaka fmt` rely on.
export
parseWithPositions : String -> (List Decl, Positions)
parseWithPositions src = match parseWithPositionsOpt src
  Some r => r
  None => panic "parse error"

-- Backward-compatibility alias kept for callers in `compiler/tools/lint.mdk`'s
-- `lintFileDiagTriple` and `compiler/driver/medaka_cli.mdk`'s `lintFileFresh`. See
-- docs/design/SOURCE-POSITION-DESIGN.md § "Increment 3 — unify the parse entry points
-- (I6)" for why the dual-tokenize design this replaced existed and was retired.
export
parseWithPositionsLocated : String -> (List Decl, Positions)
parseWithPositionsLocated src = parseWithPositions src

-- Non-panicking positions parse for strict callers. Returns `None` when the source
-- doesn't parse (instead of `panic "parse error"`), so definition
-- / inlayHint use this strict path without crashing the whole server —
-- files are unparseable constantly mid-edit.
export
parseWithPositionsOpt : String -> Option (List Decl, Positions)
parseWithPositionsOpt src =
  let _ = stageBump "parse.positions"
  match tokenizeWithOffsetPairs src
    (tokList, offPairList) => parseWithPositionsOptPairs src tokList offPairList

-- `parseWithPositionsOpt` over an ALREADY-tokenized stream: `tokList` and
-- `offPairList` must be `tokenizeWithOffsetPairs src`.  Lets a caller that has
-- lexed the source once (fmt) parse it without a second lexing pass.
export
parseWithPositionsOptPairs : String ->
  List Token ->
  List (Int, Int) ->
  Option (List Decl, Positions)
parseWithPositionsOptPairs src tokList offPairList =
  map
    (parsed => (parsedDecls parsed, parsedPositions parsed))
    (parseSourceSyntaxPairs src tokList offPairList)

export
parseSourceSyntaxPairs : String ->
  List Token ->
  List (Int, Int) ->
  Option ParsedSource
parseSourceSyntaxPairs src tokList offPairList =
  let ctx =
    newParseContextWith
      LocatedSyntax
      src
      (arrayFromList tokList)
      (arrayFromList offPairList)
  match runPWith ctx programWithSpans 0
    POk spans pos if isEofTok (peekTok (contextTokens ctx) pos) =>
      Some (publishSource ctx spans)
    _ => None

publishSource : ParseContext -> List (Decl, Int, Int) -> ParsedSource
publishSource ctx spans =
  let (commas, units) = contextCues ctx
  makeParsedSource
    (map ((d, _s, _e) => d) spans)
    (positionsFromSpans
      (contextLineStarts ctx)
      (contextTokens ctx)
      (contextOffsets ctx)
      spans)
    (makeParseMetadata commas units)

export
parseSource : String -> Result ParseDiagnostic ParsedSource
parseSource src = match tokenizeWithOffsetPairs src
  (toks, pairs) => parseSourcePairs src toks pairs

export
parseSourcePairs : String ->
  List Token ->
  List (Int, Int) ->
  Result ParseDiagnostic ParsedSource
parseSourcePairs src tokList offPairs =
  parseSourcePairsWithIndex src tokList offPairs (() => indexSource src)

export
parseSourcePairsWithIndex : String ->
  List Token ->
  List (Int, Int) ->
  (Unit -> SourceIndex) ->
  Result ParseDiagnostic ParsedSource
parseSourcePairsWithIndex src tokList offPairs index =
  let toks = arrayFromList tokList
  let offs = arrayFromList (map fst offPairs)
  let ends = arrayFromList (map snd offPairs)
  match prescanError src index toks offs ends
    Some e => Err (parseErrorDiagnostic e)
    None =>
      let ctx = newParseContext src toks (arrayFromList offPairs)
      match runPWith ctx programWithSpans 0
        POk spans pos if isEofTok (peekTok toks pos) =>
          Ok (publishSource ctx spans)
        POk _ pos =>
          Err
            (parseErrorDiagnostic
              (deepenLeftover
                ctx
                src
                index
                toks
                offs
                ends
                (stringLength src)
                pos))
        PErr f pos =>
          Err
            (parseErrorDiagnostic
              (mkLocated
                index
                toks
                offs
                ends
                (stringLength src)
                (failProblem f)
                pos))
        PFatal f pos =>
          Err
            (parseErrorDiagnostic
              (mkLocated
                index
                toks
                offs
                ends
                (stringLength src)
                (failProblem f)
                pos))

export
parseDeclAt : ParseContext -> Int -> PR Decl
parseDeclAt ctx pos =
  let saved = mark ctx
  match runPWith ctx parseDecl pos
    r@(POk _ _) => r
    r =>
      rewind saved
      r

-- Check that the parse consumed all tokens (no trailing garbage), panic on error.
resultDecls : Array Token -> PR (List Decl) -> List Decl
resultDecls _ (PErr _ _) = panic "parse error"
resultDecls _ (PFatal _ _) = panic "parse error"
resultDecls toks (POk ds pos)
  | isEofTok (peekTok toks pos) = ds
  | otherwise = panic "parse error"

-- A lexer error (unterminated string / block comment, invalid escape, stray
-- character) reaches the token stream as a terminal `TLexError msg` (see
-- `firstLexError` below).  The panicking entry must surface THAT specific
-- message rather than the generic "parse error" the grammar's own failure
-- produces once it runs off the end of a truncated/garbled token stream —
-- otherwise a parser-only caller (no `firstLexError` pre-scan of its own,
-- e.g. `compiler/entries/parse_main.mdk`) degrades every lexer error to the
-- same uninformative string, while `parseResult` (used by the CLI `check`
-- path) already special-cases it.  Shares `firstLexError` with `parseResult`
-- so both entries agree on wording.
export
parse : String -> List Decl
parse src =
  let toks = arrayFromList (tokenize src)
  match firstLexError toks 0
    Some (_, kind) => panic (renderParseProblem kind)
    None => resultDecls toks (runP parseProgram toks 0)

-- Parse with real expression locations and the syntax-only guard policy.
export
parseLocated : String -> List Decl
parseLocated src = match tokenizeWithOffsetPairs src
  (tokList, offPairs) =>
    let toks = arrayFromList tokList
    let ctx =
      newParseContextWith LocatedSyntax src toks (arrayFromList offPairs)
    resultDecls toks (runPWith ctx parseProgram 0)

-- ── Structured parse errors (non-panicking entry) ───────────────────────────
-- The LSP prerequisite (Stage 4 task #24): a parser should yield errors as
-- DATA, not abort.  The combinator already threads errors as values internally
-- (`PR a = POk | PErr PFail Int | PFatal PFail Int`); only the top boundary (`resultDecls`,
-- `parseWithPositions`) panics on `PErr` / leftover tokens.  `parseResult` is a
-- purely-additive non-panicking entry: it returns the same parse on success and
-- a located, structured `ParseError` on failure, leaving `parse` byte-identical.
--
-- Compatibility accessors expose one-based lines and zero-based codepoint columns.
-- The strict result retains diagnostic identity, full ranges and suggested edits.
-- Non-panicking analog of `resultDecls`: turn a finished parse into a structured
-- result.  `PErr msg pos` → located error at `pos`; a `POk` that did not consume
-- through `TEof` → "parse error" at the first leftover token (mirroring the
-- OCaml oracle, which reports the cursor where the grammar got stuck).
resultDeclsResult : ParseContext ->
  String ->
  (Unit -> SourceIndex) ->
  Array Token ->
  Array Int ->
  Array Int ->
  Int ->
  PR (List Decl) ->
  Result ParseError (List Decl)
resultDeclsResult _ _ index toks offs ends srcLen (PErr f pos) =
  Err (mkLocated index toks offs ends srcLen (failProblem f) pos)
resultDeclsResult _ _ index toks offs ends srcLen (PFatal f pos) =
  Err (mkLocated index toks offs ends srcLen (failProblem f) pos)
resultDeclsResult ctx src index toks offs ends srcLen (POk ds pos)
  | isEofTok (peekTok toks pos) = Ok ds
  | otherwise = Err (deepenLeftover ctx src index toks offs ends srcLen pos)

deepenLeftover : ParseContext ->
  String ->
  (Unit -> SourceIndex) ->
  Array Token ->
  Array Int ->
  Array Int ->
  Int ->
  Int ->
  ParseError
deepenLeftover ctx src index toks offs ends srcLen pos =
  let saved = mark ctx
  let result = runPWith ctx parseDecl pos
  rewind saved
  match result
    PFatal f pos2 => mkLocated index toks offs ends srcLen (failProblem f) pos2
    PErr f pos2 if pos2 > pos =>
      mkLocated index toks offs ends srcLen (failProblem f) pos2
    _ =>
      mkLocated
        index
        toks
        offs
        ends
        srcLen
        (GenericParse (unexpectedLeftoverMsg src toks offs srcLen pos))
        pos

mkLocated : (Unit -> SourceIndex) ->
  Array Token ->
  Array Int ->
  Array Int ->
  Int ->
  ParseDiagnosticKind ->
  Int ->
  ParseError
mkLocated index toks offs ends srcLen kind pos =
  ParseError (locateTokenDiagnostic index toks offs ends srcLen kind pos)

-- Is the char at `offset` the first non-whitespace character on its line?  If
-- so, return `Some col` where `col` is its (0-based, tab-not-expanded — same
-- convention as `offsetToLineCol`) column; otherwise `None`.  Used to detect a
-- leftover-token parse error caused by a misindented line (dedented to a
-- column that doesn't match any enclosing block) so the message can hint at
-- the fix instead of just naming the unexpected token.
leadingIndentAt : String -> Int -> Option Int
leadingIndentAt src offset =
  let chars = stringToChars src
  let lineStart = leadingIndentLineStart chars (offset - 1)
  if leadingIndentAllBlank chars lineStart offset then
    Some (offset - lineStart)
  else
    None

leadingIndentLineStart : Array Char -> Int -> Int
leadingIndentLineStart chars i
  | i < 0 = 0
  | arrayGetUnsafe i chars == '\n' || arrayGetUnsafe i chars == '\r' = i + 1
  | otherwise = leadingIndentLineStart chars (i - 1)

leadingIndentAllBlank : Array Char -> Int -> Int -> Bool
leadingIndentAllBlank chars i limit
  | i >= limit = True
  | otherwise = match arrayGetUnsafe i chars
    ' ' => leadingIndentAllBlank chars (i + 1) limit
    '\t' => leadingIndentAllBlank chars (i + 1) limit
    _ => False

-- Build the leftover-token "unexpected `X`" message, appending an
-- indentation-aware hint when the token is the sole content that dedented
-- this line to a column that doesn't line up with the surrounding block.
unexpectedLeftoverMsg : String ->
  Array Token ->
  Array Int ->
  Int ->
  Int ->
  String
unexpectedLeftoverMsg src toks offs srcLen pos =
  let base = unexpectedTokenMsg (peekTok toks pos)
  let offset = locateOffset toks offs srcLen pos
  match leadingIndentAt src offset
    Some col if col > 0 => leadingIndentMsg (peekTok toks pos) base col
    _ => trailingArrowLeftoverMsg (peekTok toks pos) base

-- #1718: a trailing-`->` type-signature continuation IS supported
-- (`tyArrowTail`/`tyArrowSkipLayout` above) as long as every wrapped line
-- indents at the same depth the first continuation established, or deeper.
-- A later line that dedents past that depth breaks the continuation, and the
-- resulting parse failure surfaces here — as a mid-line, non-leading `->`
-- reported leftover at the FIRST arrow of the signature — with no hint that
-- the true fault is a later line's indentation, not the arrow itself
-- (`expected type atom` / a bare `unexpected \`->\`` before this fix). This is
-- the trailing-side twin of #66's leading-`->` fix just above: name the real
-- cause instead of the token the parser happened to choke on. A leading `->`
-- is still never accepted at any indentation (#66), so — unlike the leading
-- case — there's no alternative form to point to; the fix is always to
-- re-indent the wrapped lines, which is what this message says.
trailingArrowLeftoverMsg : Token -> String -> String
trailingArrowLeftoverMsg TArrow base =
  "\{base}; a later line of this type signature dedents past its first continuation line, so indent every wrapped line at least that far"
trailingArrowLeftoverMsg _ base = base

-- `->` is deliberately absent from the leading-operator continuation set
-- (LAYOUT-SEMANTICS.md §5 excludes arrows on both the leading and trailing
-- sides). So a line that
-- starts with `->` is rejected at ANY indentation — the generic
-- "indentation doesn't match" message is false here (re-indenting can never
-- fix it) and names the wrong root cause (#66). Name the true one and the
-- real fix: put `->` at the end of the previous line instead, where it
-- heralds the indented continuation the writer wanted.
leadingIndentMsg : Token -> String -> Int -> String
leadingIndentMsg TArrow base col =
  "\{base}; a line cannot start with `->`, so put it at the end of the previous line, as in `f : Int ->` then an indented `Int`"
leadingIndentMsg _ base col =
  "\{base}; this line is indented to column \{intToString col}, which matches no enclosing block"

-- A lexer error (unterminated string / block comment, invalid escape, stray
-- character) is surfaced as a terminal `TLexError msg` token carrying the
-- offending offset (in the parallel offset array) rather than a raw panic.
-- Detecting it here — before the grammar runs — lets it flow through the SAME
-- located `ParseError` path as a real parse error, so the driver renders it
-- `file:L:C: msg` (identical treatment to `unexpected '/='`).  Returns the token
-- index + message of the first such token, or `None`.
firstLexError : Array Token -> Int -> Option (Int, ParseDiagnosticKind)
firstLexError toks i
  | i >= arrayLength toks = None
  | otherwise = match peekTok toks i
    TLexError msg => Some (i, msg)
    _ => firstLexError toks (i + 1)

-- Parse `src`, returning `Ok decls` or a structured, located `Err ParseError`.
-- Purely additive: does NOT touch the panicking `parse` path the happy-path
-- drivers (check / eval / fmt) rely on.
export
parseResult : String -> Result ParseError (List Decl)
parseResult src = match tokenizeWithOffsetPairs src
  (tokList, offList) => parseResultWith UnlocatedChecked src tokList offList

-- `parseResult` over an ALREADY-tokenized stream: `tokList` and `offPairs` must
-- be `tokenizeWithOffsetPairs src` (its pair starts are `tokenizeWithOffsets`'s
-- offsets).  Lets a caller that has lexed the source once reuse the tokens.
export
parseResultPairs : String ->
  List Token ->
  List (Int, Int) ->
  Result ParseError (List Decl)
parseResultPairs src tokList offPairs =
  parseResultWith UnlocatedChecked src tokList offPairs

-- Strict parsing with real expression locations and structured errors.
export
parseLocatedResult : String -> Result ParseError (List Decl)
parseLocatedResult src = match tokenizeWithOffsetPairs src
  (tokList, offPairs) => parseResultWith LocatedChecked src tokList offPairs

export
prescanError : String ->
  (Unit -> SourceIndex) ->
  Array Token ->
  Array Int ->
  Array Int ->
  Option ParseError
prescanError src index toks offs ends =
  let _ = stageBump "parse.prescan"
  map ParseError (prescanDiagnostic index toks offs ends (stringLength src))

-- `prescanError` over the `tokenizeWithOffsetPairs` shape that `fmt` holds.
export
prescanErrorPairs : String -> List Token -> List (Int, Int) -> Option ParseError
prescanErrorPairs src tokList offPairs =
  prescanErrorPairsWithIndex src tokList offPairs (() => indexSource src)

export
prescanErrorPairsWithIndex : String ->
  List Token ->
  List (Int, Int) ->
  (Unit -> SourceIndex) ->
  Option ParseError
prescanErrorPairsWithIndex src tokList offPairs index =
  prescanError
    src
    index
    (arrayFromList tokList)
    (arrayFromList (map fst offPairs))
    (arrayFromList (map snd offPairs))

-- Shared body of `parseResult` / `parseLocatedResult`: the pre-scans, then the
-- grammar, over an ALREADY-tokenized stream.  Split out so the located entry
-- does not have to tokenize a second time (the loader parses every module in
-- the graph through it).
parseResultWith : ParseMode ->
  String ->
  List Token ->
  List (Int, Int) ->
  Result ParseError (List Decl)
parseResultWith mode src tokList offList =
  let toks = arrayFromList tokList
  let offs = arrayFromList (map fst offList)
  let ends = arrayFromList (map snd offList)
  let index () = indexSource src
  match prescanError src index toks offs ends
    Some e => Err e
    None =>
      let ctx = newParseContextWith mode src toks (arrayFromList offList)
      resultDeclsResult
        ctx
        src
        index
        toks
        offs
        ends
        (stringLength src)
        (runPWith ctx parseProgram 0)
# DESUGAR
(DUse false (UseGroup ("frontend" "parse_locate") ((mem "locateOffset" false) (mem "locateTokenDiagnostic" false))))
(DUse false (UseGroup ("frontend" "parse_hints") ((mem "prescanDiagnostic" false) (mem "matchContinuationHint" false) (mem "letMutRemovedMsg" false) (mem "isLineEndTok" false) (mem "isBracketOpenTok" false) (mem "isBracketCloseTok" false))))
(DUse false (UseGroup ("frontend" "parse_engine") ((mem "PR" true) (mem "PFail" true) (mem "ParserE" true) (mem "Parser" false) (mem "ParseContext" false) (mem "ParseMark" false) (mem "ParseMode" true) (mem "newParseContext" false) (mem "newParseContextWith" false) (mem "runPWith" false) (mem "runP" false) (mem "contextTokens" false) (mem "contextOffsets" false) (mem "contextLineStarts" false) (mem "contextHasTab" false) (mem "contextP" false) (mem "getPos" false) (mem "peekTok" false) (mem "peekP" false) (mem "peek2P" false) (mem "peek3P" false) (mem "advance" false) (mem "emit" false) (mem "expectTok" false) (mem "failP" false) (mem "fatalP" false) (mem "fatalProblemAtP" false) (mem "fatalAtP" false) (mem "failProblem" false) (mem "orElse" false "parseOrElse") (mem "many" false) (mem "sepBy1" false) (mem "mark" false) (mem "rewind" false) (mem "locOfSpan" false) (mem "spanLoc" false) (mem "depthOf" false) (mem "withDepth" false) (mem "recordTrailingComma" false) (mem "recordUnitStart" false) (mem "forgetLatestUnitStart" false) (mem "contextCues" false) (mem "unexpectedTokenMsg" false))))
(DUse false (UseGroup ("frontend" "parse_result") ((mem "ParsedSource" false) (mem "makeParsedSource" false) (mem "makeParseMetadata" false) (mem "parsedDecls" false) (mem "parsedPositions" false))))
(DUse true (UseGroup ("frontend" "parse_result") ((mem "ParseError" true) (mem "parseErrorDiagnostic" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false))))
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnostic" false) (mem "ParseDiagnosticKind" true) (mem "renderParseProblem" false))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "indexSource" false))))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageBump" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "noBinderId" false) (mem "unminted" false) (mem "negateLiteral" false) (mem "DeriveRef" true) (mem "Lit" true) (mem "Ty" true) (mem "EffAtomTy" true) (mem "EffParamTy" true) (mem "effAtomAt" false) (mem "effectDeclUnstamped" false) (mem "KindAnn" true) (mem "Constraint" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "Loc" true) (mem "noDeclLoc" false) (mem "UseMember" true) (mem "UsePath" true) (mem "useMemberOrigin" false) (mem "useMemberAlias" false) (mem "qualifiedLocal" false) (mem "tyConUnresolved" false) (mem "tyConBuiltin" false) (mem "dDataUnresolved" false) (mem "externDataUnresolved" false) (mem "kindAnnSource" false) (mem "kindAuthorityUnstamped" false) (mem "dTypeAliasUnresolved" false) (mem "dNewtypeUnresolved" false) (mem "dInterfaceUnresolved" false) (mem "setDeclNameLoc" false) (mem "dImplUnresolved" false) (mem "constraintUnresolved" false) (mem "superUnresolved" false) (mem "requireUnresolved" false) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true) (mem "ExternDecl" true) (mem "ExternBind" true) (mem "Attr" true) (mem "Route" true))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Token" true) (mem "tokenize" false) (mem "tokenizeWithOffsets" false) (mem "tokenizeWithOffsetPairs" false) (mem "offsetToLineCol" false) (mem "lineStartsOf" false) (mem "offsetToLineColFast" false) (mem "isThenTok" false))))
(DUse true (UseGroup ("frontend" "parse_positions") ((mem "DeclPos" true) (mem "Positions" true) (mem "positionsDecls" false) (mem "positionsVariantLines" false) (mem "positionsLastContentLine" false) (mem "positionsChainLines" false) (mem "declPosLine" false) (mem "declPosEndLine" false) (mem "declPosNameLoc" false) (mem "declPosChildLocs" false))))
(DUse false (UseGroup ("frontend" "parse_positions") ((mem "positionsFromSpans" false))))
(DUse false (UseGroup ("frontend" "lex_token") ((mem "isColonTok" false) (mem "isConsTok" false) (mem "isDedentTok" false) (mem "isDeferTok" false) (mem "isEofTok" false) (mem "isEqualTok" false) (mem "isExportTok" false) (mem "isImplTok" false) (mem "isInTok" false) (mem "isIndentTok" false) (mem "isLBraceTok" false) (mem "isLetTok" false) (mem "isNewlineTok" false) (mem "isOfTok" false) (mem "isPipeTok" false) (mem "isPublicTok" false) (mem "isRBraceTok" false) (mem "isRequiresTok" false) (mem "isStarTok" false) (mem "isOpenDelim" false) (mem "isCloseDelim" false) (mem "isTStringTok" false) (mem "isTUpperTok" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "joinWith" false))))
(DUse false (UseGroup ("list") ((mem "last" false))))
(DUse false (UseGroup ("support" "char") ((mem "isUpper" false))))
(DTypeSig false "located" (TyFun (TyApp (TyCon "Parser") (TyCon "Expr")) (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "located" ((PVar "p")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "p")) (ELam ((PVar "e")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "spanLoc") (EVar "s")) (EVar "q"))) (ELam ((PVar "loc")) (EApp (EVar "deferPure") (EApp (EApp (EVar "ELoc") (EVar "loc")) (EVar "e"))))))))))))
(DTypeSig false "identNameP" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "identNameP" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "identNameFor") (EVar "t")))))
(DTypeSig false "identNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "identNameFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "identNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected an identifier"))))
(DTypeSig false "optTrailingComma" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "optTrailingComma" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "optTrailingCommaFor") (EVar "t")))))
(DTypeSig false "optTrailingCommaFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "optTrailingCommaFor" ((PCon "TComma")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "p")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "recordTrailingComma") (EVar "p")))))))
(DFunDef false "optTrailingCommaFor" (PWild) (EApp (EVar "deferPure") (ELit LUnit)))
(DTypeSig false "optTrailingCommaTuple" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "optTrailingCommaTuple" ((PList PWild)) (EApp (EVar "deferPure") (ELit LUnit)))
(DFunDef false "optTrailingCommaTuple" (PWild) (EVar "optTrailingComma"))
(DTypeSig false "skipNewlines" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "skipNewlines" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "skipNlFor") (EVar "t")))))
(DTypeSig false "skipNlFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "skipNlFor" ((PCon "TNewline")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EVar "skipNewlines"))))
(DFunDef false "skipNlFor" (PWild) (EApp (EVar "deferPure") (ELit LUnit)))
(DTypeSig false "parseExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseExpr" () (EApp (EApp (EVar "deferThen") (EVar "parseAssign")) (ELam ((PVar "e")) (EApp (EVar "annotOpt") (EVar "e")))))
(DTypeSig false "parseAssign" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAssign" () (EApp (EApp (EVar "deferThen") (EVar "parseLam")) (ELam ((PVar "e")) (EApp (EVar "assignOpt") (EVar "e")))))
(DTypeSig false "assignTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "assignTail" ((PVar "lhs")) (EApp (EVar "located") (EApp (EVar "assignTailRaw") (EVar "lhs"))))
(DTypeSig false "assignTailRaw" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "assignTailRaw" ((PVar "lhs")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TColonEq"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseRhsExpr")) (ELam ((PVar "rhs")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString ":="))) (EVar "lhs")) (EVar "rhs")) (EVar "unminted"))))))))
(DTypeSig false "annotOpt" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "annotOpt" ((PVar "e")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "pos")) (arm (PCon "TColon") () (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "annotTail") (EVar "e"))) (EApp (EVar "deferPure") (EVar "e")))) (EVar "pos"))) (arm PWild () (EApp (EApp (EVar "POk") (EVar "e")) (EVar "pos")))))))
(DTypeSig false "assignOpt" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "assignOpt" ((PVar "e")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "pos")) (arm (PCon "TColonEq") () (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "assignTail") (EVar "e"))) (EApp (EVar "deferPure") (EVar "e")))) (EVar "pos"))) (arm PWild () (EApp (EApp (EVar "POk") (EVar "e")) (EVar "pos")))))))
(DTypeSig false "lamOpt" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "lamOpt" ((PVar "e")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "pos")) (arm (PCon "TFatArrow") () (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "lamTail") (EVar "e"))) (EApp (EVar "deferPure") (EVar "e")))) (EVar "pos"))) (arm PWild () (EApp (EApp (EVar "POk") (EVar "e")) (EVar "pos")))))))
(DTypeSig false "annotTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "annotTail" ((PVar "e")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseTy")) (ELam ((PVar "t")) (EApp (EVar "deferPure") (EApp (EApp (EVar "EAnnot") (EVar "e")) (EVar "t"))))))))
(DTypeSig false "parseLam" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseLam" () (EApp (EApp (EVar "deferThen") (EVar "parsePipe")) (ELam ((PVar "e")) (EApp (EVar "lamOpt") (EVar "e")))))
(DTypeSig false "lamTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "lamTail" ((PVar "e")) (EApp (EVar "located") (EApp (EVar "lamTailRaw") (EVar "e"))))
(DTypeSig false "lamTailRaw" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "lamTailRaw" ((PVar "e")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TFatArrow"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseRhsExpr")) (ELam ((PVar "body")) (EApp (EVar "deferPure") (EApp (EApp (EVar "ELam") (EApp (EVar "exprToParams") (EVar "e"))) (EVar "body"))))))))
(DTypeSig false "exprToParams" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Pat"))))
(DFunDef false "exprToParams" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "exprToParams") (EVar "e")))
(DFunDef false "exprToParams" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EVar "appToParams") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))))
(DFunDef false "exprToParams" ((PVar "e")) (EListLit (EApp (EVar "exprToPat") (EVar "e"))))
(DTypeSig false "appToParams" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Pat"))))
(DFunDef false "appToParams" ((PVar "app")) (EApp (EApp (EVar "paramsForHead") (EApp (EVar "spineHead") (EVar "app"))) (EVar "app")))
(DTypeSig false "paramsForHead" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "paramsForHead" ((PCon "EVar" (PVar "c")) (PVar "app")) (EApp (EApp (EVar "paramsForCtor") (EVar "c")) (EVar "app")))
(DFunDef false "paramsForHead" (PWild (PVar "app")) (EApp (EApp (EVar "map") (EVar "exprToPat")) (EApp (EVar "spineList") (EVar "app"))))
(DTypeSig false "paramsForCtor" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "paramsForCtor" ((PVar "c") (PVar "app")) (EIf (EApp (EVar "isCtorName") (EVar "c")) (EListLit (EApp (EVar "exprToPat") (EVar "app"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "map") (EVar "exprToPat")) (EApp (EVar "spineList") (EVar "app"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "spineHead" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "spineHead" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "spineHead") (EVar "f")))
(DFunDef false "spineHead" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "spineHead") (EVar "e")))
(DFunDef false "spineHead" ((PVar "e")) (EVar "e"))
(DTypeSig false "spineList" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "spineList" ((PVar "e")) (EApp (EApp (EVar "spineOnto") (EVar "e")) (EListLit)))
(DTypeSig false "spineOnto" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "spineOnto" ((PCon "ELoc" PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EVar "spineOnto") (EVar "e")) (EVar "acc")))
(DFunDef false "spineOnto" ((PCon "EApp" (PVar "f") (PVar "x")) (PVar "acc")) (EApp (EApp (EVar "spineOnto") (EVar "f")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DFunDef false "spineOnto" ((PVar "e") (PVar "acc")) (EBinOp "::" (EVar "e") (EVar "acc")))
(DTypeSig false "exprToPat" (TyFun (TyCon "Expr") (TyCon "Pat")))
(DFunDef false "exprToPat" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "exprToPat") (EVar "e")))
(DFunDef false "exprToPat" ((PCon "EVar" (PLit (LString "_")))) (EVar "PWild"))
(DFunDef false "exprToPat" ((PCon "EVar" (PVar "x"))) (EApp (EVar "ctorOrVar") (EVar "x")))
(DFunDef false "exprToPat" ((PCon "ELit" (PVar "l"))) (EApp (EVar "PLit") (EVar "l")))
(DFunDef false "exprToPat" ((PCon "ENumLit" (PVar "n") PWild PWild)) (EApp (EVar "PLit") (EApp (EVar "LInt") (EVar "n"))))
(DFunDef false "exprToPat" ((PCon "EWideLit" (PVar "hi") (PVar "lo") PWild PWild)) (EApp (EVar "PLit") (EApp (EApp (EVar "LU64") (EVar "hi")) (EVar "lo"))))
(DFunDef false "exprToPat" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "PTuple") (EApp (EApp (EVar "map") (EVar "exprToPat")) (EVar "es"))))
(DFunDef false "exprToPat" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "PList") (EApp (EApp (EVar "map") (EVar "exprToPat")) (EVar "es"))))
(DFunDef false "exprToPat" ((PCon "EBinOp" (PLit (LString "::")) (PVar "a") (PVar "b") PWild)) (EApp (EApp (EVar "PCons") (EApp (EVar "exprToPat") (EVar "a"))) (EApp (EVar "exprToPat") (EVar "b"))))
(DFunDef false "exprToPat" ((PCon "ESection" (PCon "SecLeft" (PVar "a") (PLit (LString "::"))))) (EApp (EApp (EVar "PCons") (EApp (EVar "exprToPat") (EVar "a"))) (EVar "PWild")))
(DFunDef false "exprToPat" ((PCon "EAsPat" (PVar "x") (PVar "sub"))) (EApp (EApp (EApp (EApp (EVar "PAs") (EVar "x")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId")) (EApp (EVar "exprToPat") (EVar "sub"))))
(DFunDef false "exprToPat" ((PCon "EOrPat" (PVar "es"))) (EApp (EVar "orPatOf") (EApp (EApp (EVar "map") (EVar "exprToPat")) (EVar "es"))))
(DFunDef false "exprToPat" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EVar "appToPat") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))))
(DFunDef false "exprToPat" (PWild) (EVar "PWild"))
(DTypeSig false "orPatOf" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Pat")))
(DFunDef false "orPatOf" ((PList (PVar "p"))) (EVar "p"))
(DFunDef false "orPatOf" ((PVar "ps")) (EApp (EVar "POr") (EApp (EApp (EVar "flatMap") (EVar "orAlts")) (EVar "ps"))))
(DTypeSig false "orAlts" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "Pat"))))
(DFunDef false "orAlts" ((PCon "POr" (PVar "qs"))) (EVar "qs"))
(DFunDef false "orAlts" ((PVar "p")) (EListLit (EVar "p")))
(DTypeSig false "ctorOrVar" (TyFun (TyCon "String") (TyCon "Pat")))
(DFunDef false "ctorOrVar" ((PVar "x")) (EIf (EApp (EVar "isCtorName") (EVar "x")) (EApp (EApp (EVar "PCon") (EVar "x")) (EListLit)) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "appToPat" (TyFun (TyCon "Expr") (TyCon "Pat")))
(DFunDef false "appToPat" ((PVar "app")) (EApp (EApp (EVar "appToPatH") (EApp (EVar "spineHead") (EVar "app"))) (EApp (EVar "spineList") (EVar "app"))))
(DTypeSig false "appToPatH" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Pat"))))
(DFunDef false "appToPatH" ((PCon "EVar" (PVar "c")) (PVar "spine")) (EApp (EApp (EVar "appToPatCtor") (EVar "c")) (EVar "spine")))
(DFunDef false "appToPatH" (PWild PWild) (EVar "PWild"))
(DTypeSig false "appToPatCtor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Pat"))))
(DFunDef false "appToPatCtor" ((PVar "c") (PVar "spine")) (EIf (EApp (EVar "isCtorName") (EVar "c")) (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EVar "map") (EVar "exprToPat")) (EApp (EVar "dropFirst") (EVar "spine")))) (EIf (EVar "otherwise") (EVar "PWild") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dropFirst" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "dropFirst" ((PList)) (EListLit))
(DFunDef false "dropFirst" ((PCons PWild (PVar "xs"))) (EVar "xs"))
(DTypeSig false "isCtorName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isCtorName" ((PVar "s")) (EApp (EVar "isCtorChars") (EApp (EVar "stringToChars") (EVar "s"))))
(DTypeSig false "isCtorChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyCon "Bool")))
(DFunDef false "isCtorChars" ((PVar "cs")) (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EVar "False") (EIf (EVar "otherwise") (EApp (EVar "isUpper") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "stripLoc" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "stripLoc" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "stripLoc") (EVar "e")))
(DFunDef false "stripLoc" ((PVar "e")) (EVar "e"))
(DTypeSig false "stripLoc1" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "stripLoc1" ((PCon "ELoc" PWild (PVar "e"))) (EVar "e"))
(DFunDef false "stripLoc1" ((PVar "e")) (EVar "e"))
(DTypeSig false "binLevelOf" (TyFun (TyCon "Token") (TyCon "Int")))
(DFunDef false "binLevelOf" ((PCon "TPipeRight")) (ELit (LInt 1)))
(DFunDef false "binLevelOf" ((PCon "TRCompose")) (ELit (LInt 2)))
(DFunDef false "binLevelOf" ((PCon "TLCompose")) (ELit (LInt 2)))
(DFunDef false "binLevelOf" ((PCon "TOr")) (ELit (LInt 3)))
(DFunDef false "binLevelOf" ((PCon "TAnd")) (ELit (LInt 4)))
(DFunDef false "binLevelOf" ((PCon "TEqEq")) (ELit (LInt 5)))
(DFunDef false "binLevelOf" ((PCon "TNeq")) (ELit (LInt 5)))
(DFunDef false "binLevelOf" ((PCon "TLt")) (ELit (LInt 5)))
(DFunDef false "binLevelOf" ((PCon "TGt")) (ELit (LInt 5)))
(DFunDef false "binLevelOf" ((PCon "TLeq")) (ELit (LInt 5)))
(DFunDef false "binLevelOf" ((PCon "TGeq")) (ELit (LInt 5)))
(DFunDef false "binLevelOf" ((PCon "TCons")) (ELit (LInt 6)))
(DFunDef false "binLevelOf" ((PCon "TPlusPlus")) (ELit (LInt 7)))
(DFunDef false "binLevelOf" ((PCon "TPlus")) (ELit (LInt 8)))
(DFunDef false "binLevelOf" ((PCon "TMinus")) (ELit (LInt 8)))
(DFunDef false "binLevelOf" ((PCon "TMinusTight")) (ELit (LInt 8)))
(DFunDef false "binLevelOf" ((PCon "TStar")) (ELit (LInt 9)))
(DFunDef false "binLevelOf" ((PCon "TSlash")) (ELit (LInt 9)))
(DFunDef false "binLevelOf" ((PCon "TMod")) (ELit (LInt 9)))
(DFunDef false "binLevelOf" (PWild) (ELit (LInt 0)))
(DTypeSig false "binOpName" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "binOpName" ((PCon "TPipeRight")) (ELit (LString "|>")))
(DFunDef false "binOpName" ((PCon "TRCompose")) (ELit (LString ">>")))
(DFunDef false "binOpName" ((PCon "TLCompose")) (ELit (LString "<<")))
(DFunDef false "binOpName" ((PCon "TOr")) (ELit (LString "||")))
(DFunDef false "binOpName" ((PCon "TAnd")) (ELit (LString "&&")))
(DFunDef false "binOpName" ((PCon "TEqEq")) (ELit (LString "==")))
(DFunDef false "binOpName" ((PCon "TNeq")) (ELit (LString "/=")))
(DFunDef false "binOpName" ((PCon "TLt")) (ELit (LString "<")))
(DFunDef false "binOpName" ((PCon "TGt")) (ELit (LString ">")))
(DFunDef false "binOpName" ((PCon "TLeq")) (ELit (LString "<=")))
(DFunDef false "binOpName" ((PCon "TGeq")) (ELit (LString ">=")))
(DFunDef false "binOpName" ((PCon "TCons")) (ELit (LString "::")))
(DFunDef false "binOpName" ((PCon "TPlusPlus")) (ELit (LString "++")))
(DFunDef false "binOpName" ((PCon "TStar")) (ELit (LString "*")))
(DFunDef false "binOpName" ((PCon "TSlash")) (ELit (LString "/")))
(DFunDef false "binOpName" ((PCon "TMod")) (ELit (LString "%")))
(DFunDef false "binOpName" ((PCon "TPlus")) (ELit (LString "+")))
(DFunDef false "binOpName" ((PCon "TMinus")) (ELit (LString "-")))
(DFunDef false "binOpName" ((PCon "TMinusTight")) (ELit (LString "-")))
(DFunDef false "binOpName" (PWild) (EApp (EVar "panic") (ELit (LString "binOpName: not a binary operator"))))
(DTypeSig false "pipeLevel" (TyCon "Int"))
(DFunDef false "pipeLevel" () (ELit (LInt 1)))
(DTypeSig false "orLevel" (TyCon "Int"))
(DFunDef false "orLevel" () (ELit (LInt 3)))
(DTypeSig false "consLevel" (TyCon "Int"))
(DFunDef false "consLevel" () (ELit (LInt 6)))
(DTypeSig false "mulLevel" (TyCon "Int"))
(DFunDef false "mulLevel" () (ELit (LInt 9)))
(DTypeSig false "parsePipe" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parsePipe" () (EApp (EVar "ParserE") (EApp (EVar "binLevel") (EVar "pipeLevel"))))
(DTypeSig false "parseOr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseOr" () (EApp (EVar "ParserE") (EApp (EVar "binLevel") (EVar "orLevel"))))
(DTypeSig false "binLevel" (TyFun (TyCon "Int") (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyApp (TyCon "PR") (TyCon "Expr"))))))
(DFunDef false "binLevel" ((PVar "lvl") (PVar "ctx") (PVar "pos")) (EIf (EBinOp ">" (EVar "lvl") (EVar "mulLevel")) (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "parseUnary")) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "binLevelRest") (EVar "lvl")) (EVar "ctx")) (EApp (EApp (EApp (EVar "binLevel") (EBinOp "+" (EVar "lvl") (ELit (LInt 1)))) (EVar "ctx")) (EVar "pos"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "binLevelRest" (TyFun (TyCon "Int") (TyFun (TyCon "ParseContext") (TyFun (TyApp (TyCon "PR") (TyCon "Expr")) (TyApp (TyCon "PR") (TyCon "Expr"))))))
(DFunDef false "binLevelRest" ((PVar "lvl") (PVar "ctx") (PAs "r" (PCon "POk" (PVar "x") (PVar "pos")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "binTry") (EVar "lvl")) (EVar "ctx")) (EVar "r")) (EVar "x")) (EVar "pos")) (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "pos"))))
(DFunDef false "binLevelRest" (PWild PWild (PVar "r")) (EVar "r"))
(DTypeSig false "binTry" (TyFun (TyCon "Int") (TyFun (TyCon "ParseContext") (TyFun (TyApp (TyCon "PR") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "PR") (TyCon "Expr")))))))))
(DFunDef false "binTry" ((PVar "lvl") (PVar "ctx") (PVar "r") (PVar "x") (PVar "pos") (PVar "t")) (EIf (EBinOp "==" (EApp (EVar "binLevelOf") (EVar "t")) (EVar "lvl")) (EBlock (DoLet false false (PVar "saved") (EApp (EVar "mark") (EVar "ctx"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "binRhs") (EVar "saved")) (EVar "lvl")) (EVar "ctx")) (EVar "x")) (EVar "pos")) (EVar "t")) (EApp (EApp (EApp (EVar "binLevel") (EApp (EVar "binRhsLevel") (EVar "lvl"))) (EVar "ctx")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))))) (EIf (EVar "otherwise") (EVar "r") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "binRhsLevel" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "binRhsLevel" ((PVar "lvl")) (EIf (EBinOp "==" (EVar "lvl") (EVar "consLevel")) (EVar "lvl") (EIf (EVar "otherwise") (EBinOp "+" (EVar "lvl") (ELit (LInt 1))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "binRhs" (TyFun (TyCon "ParseMark") (TyFun (TyCon "Int") (TyFun (TyCon "ParseContext") (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyFun (TyApp (TyCon "PR") (TyCon "Expr")) (TyApp (TyCon "PR") (TyCon "Expr"))))))))))
(DFunDef false "binRhs" (PWild (PVar "lvl") (PVar "ctx") (PVar "x") PWild (PVar "t") (PCon "POk" (PVar "y") (PVar "q"))) (EApp (EApp (EApp (EVar "binNext") (EVar "lvl")) (EVar "ctx")) (EApp (EApp (EVar "POk") (EApp (EApp (EApp (EApp (EVar "EBinOp") (EApp (EVar "binOpName") (EVar "t"))) (EVar "x")) (EVar "y")) (EVar "unminted"))) (EVar "q"))))
(DFunDef false "binRhs" ((PVar "saved") PWild (PVar "ctx") PWild (PVar "pos") PWild (PCon "PErr" PWild (PVar "q"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "q") (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EBinOp "||" (EBinOp "||" (EApp (EVar "isLineEndTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "q"))) (EApp (EVar "isCloseDelim") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "q")))) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "q")) (EVar "TComma")))) (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EApp (EApp (EVar "PFatal") (EApp (EVar "FailMsg") (ELit (LString "expected an expression after the binary operator")))) (EApp (EApp (EVar "committedErrorPos") (EVar "ctx")) (EVar "q"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "binRhs" ((PVar "saved") PWild PWild (PVar "x") (PVar "pos") PWild (PCon "PErr" PWild PWild)) (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EApp (EApp (EVar "POk") (EVar "x")) (EVar "pos")))))
(DFunDef false "binRhs" ((PVar "saved") PWild PWild PWild PWild PWild (PVar "ry")) (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EVar "ry"))))
(DTypeSig false "binNext" (TyFun (TyCon "Int") (TyFun (TyCon "ParseContext") (TyFun (TyApp (TyCon "PR") (TyCon "Expr")) (TyApp (TyCon "PR") (TyCon "Expr"))))))
(DFunDef false "binNext" ((PVar "lvl") (PVar "ctx") (PVar "r")) (EIf (EBinOp "==" (EVar "lvl") (EVar "consLevel")) (EVar "r") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "binLevelRest") (EVar "lvl")) (EVar "ctx")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "intMinLit" (TyCon "Int"))
(DFunDef false "intMinLit" () (EBinOp "-" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 4611686018427387903))) (ELit (LInt 1))))
(DTypeSig false "isIntMinLit" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isIntMinLit" ((PVar "n")) (EBinOp "==" (EVar "n") (EVar "intMinLit")))
(DTypeSig false "intLitTooBigMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "intLitTooBigMsg" () (EVar "PositiveIntOverflow"))
(DTypeSig false "widePatMsg" (TyFun (TyCon "String") (TyCon "ParseDiagnosticKind")))
(DFunDef false "widePatMsg" ((PVar "lx")) (EApp (EVar "WidePattern") (EVar "lx")))
(DTypeSig false "intMinAsWide" (TyFun (TyCon "String") (TyCon "Expr")))
(DFunDef false "intMinAsWide" ((PVar "lx")) (EApp (EApp (EApp (EApp (EVar "EWideLit") (ELit (LInt 1073741824))) (ELit (LInt 0))) (EVar "unminted")) (EVar "lx")))
(DTypeSig false "parseUnary" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseUnary" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "unaryFor") (EVar "t")))))
(DTypeSig false "unaryFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "unaryFor" ((PCon "TMinus")) (EVar "negUnary"))
(DFunDef false "unaryFor" ((PCon "TMinusTight")) (EVar "negUnary"))
(DFunDef false "unaryFor" ((PCon "TBang")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseUnary")) (ELam ((PVar "e")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "EUnOp") (ELit (LString "!"))) (EVar "e")) (EVar "unminted"))))))))
(DFunDef false "unaryFor" (PWild) (EVar "parseInfix"))
(DTypeSig false "negUnary" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "negUnary" () (EApp (EApp (EVar "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EVar "negUnaryFor") (EVar "t2")))))
(DTypeSig false "negUnaryFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "negUnaryFor" ((PCon "TInt" (PVar "n") (PVar "lx"))) (EIf (EApp (EVar "isIntMinLit") (EVar "n")) (EApp (EVar "located") (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "ENumLit") (EVar "n")) (EVar "unminted")) (EBinOp "++" (ELit (LString "-")) (EVar "lx"))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "negUnaryFor" (PWild) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseUnary")) (ELam ((PVar "e")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "EUnOp") (ELit (LString "-"))) (EVar "e")) (EVar "unminted"))))))))
(DTypeSig false "parseInfix" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseInfix" () (EVar "parseApp"))
(DTypeSig false "parseApp" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseApp" () (EApp (EApp (EVar "deferThen") (EVar "parseAspat")) (ELam ((PVar "head")) (EApp (EApp (EVar "deferThen") (EApp (EVar "many") (EApp (EVar "appArg") (EVar "head")))) (ELam ((PVar "args")) (EApp (EVar "deferPure") (EApp (EApp (EVar "applyAll") (EVar "head")) (EVar "args"))))))))
(DTypeSig false "appArg" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "appArg" ((PVar "head")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EApp (EVar "appArgR") (EVar "head")) (EVar "ctx")) (EVar "pos")))))
(DTypeSig false "appArgR" (TyFun (TyCon "Expr") (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyApp (TyCon "PR") (TyCon "Expr"))))))
(DFunDef false "appArgR" ((PVar "head") (PVar "ctx") (PVar "pos")) (EIf (EBinOp "&&" (EApp (EVar "appArgStops") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "pos"))) (EBinOp "<" (EApp (EVar "depthOf") (EVar "ctx")) (EVar "maxNestDepth"))) (EApp (EApp (EVar "PErr") (EApp (EVar "FailMsg") (ELit (LString "expected an application argument")))) (EVar "pos")) (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "negLitArg") (EVar "head"))) (EApp (EApp (EVar "parseOrElse") (EVar "derefArg")) (EVar "parseAspat")))) (EVar "pos"))))
(DTypeSig false "appArgStops" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "appArgStops" ((PCon "TEof")) (EVar "True"))
(DFunDef false "appArgStops" ((PCon "TNewline")) (EVar "True"))
(DFunDef false "appArgStops" ((PCon "TDedent")) (EVar "True"))
(DFunDef false "appArgStops" ((PCon "TRParen")) (EVar "True"))
(DFunDef false "appArgStops" ((PCon "TRBracket")) (EVar "True"))
(DFunDef false "appArgStops" ((PCon "TRBrace")) (EVar "True"))
(DFunDef false "appArgStops" ((PCon "TComma")) (EVar "True"))
(DFunDef false "appArgStops" (PWild) (EVar "False"))
(DTypeSig false "derefArg" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "derefArg" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "derefArgFor") (EVar "t")))))
(DTypeSig false "derefArgFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "derefArgFor" ((PCon "TBang")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseAspat")) (ELam ((PVar "e")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "EUnOp") (ELit (LString "!"))) (EVar "e")) (EVar "unminted"))))))))
(DFunDef false "derefArgFor" (PWild) (EApp (EVar "failP") (ELit (LString "not a tight deref argument"))))
(DTypeSig false "negLitArg" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "negLitArg" ((PVar "head")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "negLitArgGate") (EVar "head")) (EVar "t")))))
(DTypeSig false "negLitArgGate" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "negLitArgGate" ((PVar "head") (PCon "TMinusTight")) (EIf (EApp (EVar "headIsNumeric") (EVar "head")) (EApp (EVar "failP") (ELit (LString "numeric head: tight minus stays subtraction"))) (EVar "negLitArgTight")))
(DFunDef false "negLitArgGate" (PWild PWild) (EApp (EVar "failP") (ELit (LString "not a tight negative literal argument"))))
(DTypeSig false "negLitArgTight" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "negLitArgTight" () (EApp (EApp (EVar "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EVar "negLitArgFor") (EVar "TMinusTight")) (EVar "t2")))))
(DTypeSig false "negLitArgFor" (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "negLitArgFor" ((PCon "TMinusTight") (PCon "TInt" (PVar "n") (PVar "lx"))) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "ENumLit") (EApp (EVar "negateLiteral") (EVar "n"))) (EVar "unminted")) (EBinOp "++" (ELit (LString "-")) (EVar "lx")))))))))
(DFunDef false "negLitArgFor" ((PCon "TMinusTight") (PCon "TWideInt" (PVar "hi") (PVar "lo") (PVar "lx"))) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "EUnOp") (ELit (LString "-"))) (EApp (EApp (EApp (EApp (EVar "EWideLit") (EVar "hi")) (EVar "lo")) (EVar "unminted")) (EVar "lx"))) (EVar "unminted"))))))))
(DFunDef false "negLitArgFor" ((PCon "TMinusTight") (PCon "TFloat" (PVar "f"))) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EVar "ELit") (EApp (EVar "LFloat") (EApp (EVar "negate") (EVar "f"))))))))))
(DFunDef false "negLitArgFor" (PWild PWild) (EApp (EVar "failP") (ELit (LString "not a tight negative literal argument"))))
(DTypeSig false "headIsNumeric" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "headIsNumeric" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "headIsNumeric") (EVar "e")))
(DFunDef false "headIsNumeric" ((PCon "ENumLit" PWild PWild PWild)) (EVar "True"))
(DFunDef false "headIsNumeric" ((PCon "EWideLit" PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "headIsNumeric" ((PCon "ELit" (PCon "LInt" PWild))) (EVar "True"))
(DFunDef false "headIsNumeric" ((PCon "ELit" (PCon "LFloat" PWild))) (EVar "True"))
(DFunDef false "headIsNumeric" (PWild) (EVar "False"))
(DTypeSig false "parseAspat" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAspat" () (EApp (EApp (EVar "parseOrElse") (EVar "parseAspatAt")) (EVar "parsePostfix")))
(DTypeSig false "parseAspatAt" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAspatAt" () (EApp (EVar "located") (EVar "parseAspatAtRaw")))
(DTypeSig false "parseAspatAtRaw" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAspatAtRaw" () (EApp (EApp (EVar "deferThen") (EVar "identNameP")) (ELam ((PVar "x")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TAsAt"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parsePostfix")) (ELam ((PVar "sub")) (EApp (EVar "deferPure") (EApp (EApp (EVar "EAsPat") (EVar "x")) (EVar "sub"))))))))))
(DTypeSig false "applyAll" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr"))))
(DFunDef false "applyAll" ((PVar "head") (PList)) (EVar "head"))
(DFunDef false "applyAll" ((PVar "head") (PCons (PVar "a") (PVar "rest"))) (EApp (EApp (EVar "applyAll") (EApp (EApp (EVar "EApp") (EVar "head")) (EVar "a"))) (EVar "rest")))
(DTypeSig false "parsePostfix" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parsePostfix" () (EApp (EApp (EVar "deferThen") (EVar "parseAtom")) (ELam ((PVar "e")) (EApp (EVar "postfixTail") (EVar "e")))))
(DTypeSig false "postfixTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "postfixTail" ((PVar "e")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EApp (EVar "postfixTailR") (EVar "e")) (EVar "ctx")) (EVar "pos")))))
(DTypeSig false "postfixTailR" (TyFun (TyCon "Expr") (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyApp (TyCon "PR") (TyCon "Expr"))))))
(DFunDef false "postfixTailR" ((PVar "e") (PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "pos")) (arm (PCon "TLBracketTight") () (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EApp (EVar "postfixChain") (EVar "e"))) (EVar "pos"))) (arm (PCon "TDot") () (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EApp (EVar "postfixChain") (EVar "e"))) (EVar "pos"))) (arm PWild () (EApp (EApp (EVar "POk") (EVar "e")) (EVar "pos")))))
(DTypeSig false "postfixChain" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "postfixChain" ((PVar "e")) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "bracketIndexTail") (EVar "e"))) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "dotTail") (EVar "e"))) (EApp (EVar "deferPure") (EVar "e")))))
(DTypeSig false "bracketIndexTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "bracketIndexTail" ((PVar "e")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TLBracketTight"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "lo")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "bracketIndexRest") (EVar "e")) (EVar "lo")) (EVar "t")))))))))
(DTypeSig false "bracketIndexRest" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))))
(DFunDef false "bracketIndexRest" (PWild PWild (PCon "TDotDot")) (EApp (EVar "failP") (ELit (LString "bare slice `a[i..j]` is not supported; write `a.[i..j]`"))))
(DFunDef false "bracketIndexRest" (PWild PWild (PCon "TDotDotEq")) (EApp (EVar "failP") (ELit (LString "bare slice `a[i..=j]` is not supported; write `a.[i..=j]`"))))
(DFunDef false "bracketIndexRest" ((PVar "e") (PVar "lo") (PCon "TRBracket")) (EApp (EApp (EVar "finishBracketIndex") (EVar "e")) (EVar "lo")))
(DFunDef false "bracketIndexRest" (PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected `]` to close the index"))))
(DTypeSig false "finishBracketIndex" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "finishBracketIndex" ((PVar "e") (PVar "lo")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "postfixTail") (EApp (EApp (EVar "EIndex") (EVar "e")) (EVar "lo"))))))
(DTypeSig false "dotTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "dotTail" ((PVar "e")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TDot"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "dotFor") (EVar "e")) (EVar "t")))))))
(DTypeSig false "dotFor" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "dotFor" ((PVar "e") (PCon "TLBracket")) (EApp (EVar "indexOrSlice") (EVar "e")))
(DFunDef false "dotFor" ((PVar "e") PWild) (EApp (EApp (EVar "deferThen") (EVar "identNameP")) (ELam ((PVar "f")) (EApp (EVar "postfixTail") (EApp (EApp (EApp (EVar "EFieldAccess") (EVar "e")) (EVar "f")) (EVar "unminted"))))))
(DTypeSig false "indexOrSlice" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "indexOrSlice" ((PVar "e")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TLBracket"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "lo")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "indexOrSliceRest") (EVar "e")) (EVar "lo")) (EVar "t")))))))))
(DTypeSig false "indexOrSliceRest" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))))
(DFunDef false "indexOrSliceRest" ((PVar "e") (PVar "lo") (PCon "TDotDot")) (EApp (EApp (EApp (EVar "sliceHi") (EVar "e")) (EVar "lo")) (EVar "False")))
(DFunDef false "indexOrSliceRest" ((PVar "e") (PVar "lo") (PCon "TDotDotEq")) (EApp (EApp (EApp (EVar "sliceHi") (EVar "e")) (EVar "lo")) (EVar "True")))
(DFunDef false "indexOrSliceRest" ((PVar "e") (PVar "lo") (PCon "TRBracket")) (EApp (EApp (EVar "finishBracketIndex") (EVar "e")) (EVar "lo")))
(DFunDef false "indexOrSliceRest" (PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected `..`, `..=` or `]` in the index"))))
(DTypeSig false "sliceHi" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Expr"))))))
(DFunDef false "sliceHi" ((PVar "e") (PVar "lo") (PVar "incl")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "hi")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRBracket"))) (ELam (PWild) (EApp (EVar "postfixTail") (EApp (EApp (EApp (EApp (EVar "ESlice") (EVar "e")) (EVar "lo")) (EVar "hi")) (EVar "incl"))))))))))
(DTypeSig false "maxNestDepth" (TyCon "Int"))
(DFunDef false "maxNestDepth" () (ELit (LInt 20000)))
(DTypeSig false "nestTooDeepMsg" (TyCon "String"))
(DFunDef false "nestTooDeepMsg" () (EBinOp "++" (EBinOp "++" (ELit (LString "expression nesting too deep (limit ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "maxNestDepth")))) (ELit (LString "); split this expression into named intermediate bindings"))))
(DTypeSig false "parseAtom" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAtom" () (EApp (EApp (EApp (EVar "withDepth") (EVar "maxNestDepth")) (EApp (EVar "FailMsg") (EVar "nestTooDeepMsg"))) (EApp (EVar "ParserE") (EVar "atomRawLocated"))))
(DTypeSig false "atomRawLocated" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyApp (TyCon "PR") (TyCon "Expr")))))
(DFunDef false "atomRawLocated" ((PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "parseAtomRaw")) (EVar "pos")) (arm (PCon "POk" (PVar "e") (PVar "q")) () (EApp (EApp (EVar "POk") (EApp (EApp (EVar "ELoc") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "pos")) (EVar "q"))) (EVar "e"))) (EVar "q"))) (arm (PCon "PErr" (PVar "f") (PVar "q")) () (EApp (EApp (EVar "PErr") (EVar "f")) (EVar "q"))) (arm (PCon "PFatal" (PVar "f") (PVar "q")) () (EApp (EApp (EVar "PFatal") (EVar "f")) (EVar "q")))))
(DTypeSig false "parseAtomRaw" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAtomRaw" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TInt" (PVar "n") (PVar "lx")) ((GBool (EApp (EVar "isIntMinLit") (EVar "n")))) (EApp (EVar "emit") (EApp (EVar "intMinAsWide") (EVar "lx")))) (arm (PCon "TInt" (PVar "n") (PVar "lx")) () (EApp (EVar "emit") (EApp (EApp (EApp (EVar "ENumLit") (EVar "n")) (EVar "unminted")) (EVar "lx")))) (arm (PCon "TWideInt" (PVar "hi") (PVar "lo") (PVar "lx")) () (EApp (EVar "emit") (EApp (EApp (EApp (EApp (EVar "EWideLit") (EVar "hi")) (EVar "lo")) (EVar "unminted")) (EVar "lx")))) (arm (PCon "TFloat" (PVar "f")) () (EApp (EVar "emit") (EApp (EVar "ELit") (EApp (EVar "LFloat") (EVar "f"))))) (arm (PCon "TString" (PVar "s")) () (EApp (EVar "emit") (EApp (EVar "ELit") (EApp (EVar "LString") (EVar "s"))))) (arm (PCon "TChar" (PVar "s")) () (EApp (EVar "emit") (EApp (EVar "ELit") (EApp (EVar "LChar") (EVar "s"))))) (arm (PCon "TByte" (PVar "n")) () (EApp (EVar "emit") (EApp (EVar "ELit") (EApp (EVar "LByte") (EVar "n"))))) (arm (PCon "TIdent" (PVar "x")) () (EApp (EVar "emit") (EApp (EVar "EVar") (EVar "x")))) (arm (PCon "TUpper" (PVar "x")) () (EApp (EVar "parseUpperAtom") (EVar "x"))) (arm (PCon "TUnderscore") () (EApp (EVar "emit") (EApp (EVar "EVar") (ELit (LString "_"))))) (arm (PCon "TLParen") () (EVar "parseParen")) (arm (PCon "TLBracket") () (EVar "parseListE")) (arm (PCon "TLArray") () (EVar "parseArray")) (arm (PCon "TLBrace") () (EVar "parseRecordUpdate")) (arm (PCon "TIf") () (EVar "parseIf")) (arm (PCon "TLet") () (EVar "parseLet")) (arm (PCon "TMatch") () (EVar "parseMatch")) (arm (PCon "TDo") () (EVar "parseDo")) (arm (PCon "TDefer") () (EVar "parseDefer")) (arm (PCon "TInterpOpen" PWild) () (EVar "parseInterp")) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected an expression"))))))))
(DTypeSig false "parseUpperAtom" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "parseUpperAtom" ((PVar "x")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "upperQualTail") (EVar "x"))) (ELam ((PVar "n")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "upperTail") (EVar "n")) (EVar "t")))))))))
(DTypeSig false "upperTail" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "upperTail" ((PVar "x") (PCon "TLBrace")) (EApp (EVar "upperBrace") (EVar "x")))
(DFunDef false "upperTail" ((PVar "x") PWild) (EApp (EVar "deferPure") (EApp (EVar "EVar") (EVar "x"))))
(DTypeSig false "upperBrace" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "upperBrace" ((PVar "x")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TLBrace"))) (ELam (PWild) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "variantUpdateTail") (EVar "x"))) (EApp (EVar "braceItems") (EVar "x"))))))
(DTypeSig false "variantUpdateTail" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "variantUpdateTail" ((PVar "x")) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TPipe"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "recordFieldExpr")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "fields")) (EApp (EApp (EVar "deferThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "x")) (EVar "e")) (EApp (EApp (EVar "map") (EApp (EVar "desugarDottedField") (EVar "e"))) (EVar "fields")))))))))))))))
(DData Private "KvItem" () ((variant "KvField" (ConPos (TyCon "String") (TyCon "Expr"))) (variant "KvKV" (ConPos (TyCon "Expr") (TyCon "Expr"))) (variant "KvElem" (ConPos (TyCon "Expr")))) ())
(DTypeSig false "braceItems" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "braceItems" ((PVar "x")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "braceItemsFor") (EVar "x")) (EVar "t")))))
(DTypeSig false "braceItemsFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "braceItemsFor" ((PVar "x") (PCon "TRBrace")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EVar "classifyBrace") (EVar "x")) (EListLit))))))
(DFunDef false "braceItemsFor" ((PVar "x") PWild) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "parseKvOrE")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "items")) (EApp (EApp (EVar "deferThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EVar "classifyBrace") (EVar "x")) (EVar "items"))))))))))
(DTypeSig false "parseKvOrE" (TyApp (TyCon "Parser") (TyCon "KvItem")))
(DFunDef false "parseKvOrE" () (EApp (EApp (EVar "parseOrElse") (EVar "parseKvField")) (EApp (EApp (EVar "parseOrElse") (EVar "parseKvBlockElem")) (EVar "parseKvKVorElem"))))
(DTypeSig false "parseKvBlockElem" (TyApp (TyCon "Parser") (TyCon "KvItem")))
(DFunDef false "parseKvBlockElem" () (EApp (EApp (EVar "deferThen") (EVar "parseBracketBlock")) (ELam ((PVar "e")) (EApp (EVar "deferPure") (EApp (EVar "KvElem") (EVar "e"))))))
(DTypeSig false "parseKvField" (TyApp (TyCon "Parser") (TyCon "KvItem")))
(DFunDef false "parseKvField" () (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "p")) (EApp (EApp (EVar "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "committedExpr") (ELit (LString "expected a record field value after `=`"))) (EVar "parseBracketElem"))) (ELam ((PVar "e")) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "recordUnitStart") (ELit (LInt 4))) (EVar "p"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EVar "KvField") (EVar "name")) (EVar "e"))))))))))))))
(DTypeSig false "parseKvKVorElem" (TyApp (TyCon "Parser") (TyCon "KvItem")))
(DFunDef false "parseKvKVorElem" () (EApp (EApp (EVar "deferThen") (EVar "parsePipe")) (ELam ((PVar "e")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "kvKVorElemFor") (EVar "e")) (EVar "t")))))))
(DTypeSig false "kvKVorElemFor" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "KvItem")))))
(DFunDef false "kvKVorElemFor" ((PVar "e") (PCon "TFatArrow")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "v")) (EApp (EVar "deferPure") (EApp (EApp (EVar "KvKV") (EVar "e")) (EVar "v"))))))))
(DFunDef false "kvKVorElemFor" ((PVar "e") PWild) (EApp (EVar "deferPure") (EApp (EVar "KvElem") (EVar "e"))))
(DTypeSig false "classifyBrace" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "KvItem")) (TyCon "Expr"))))
(DFunDef false "classifyBrace" ((PVar "name") (PVar "items")) (EIf (EApp (EVar "anyField") (EVar "items")) (EApp (EApp (EVar "ERecordCreate") (EVar "name")) (EApp (EApp (EVar "map") (EVar "kvToField")) (EVar "items"))) (EIf (EApp (EVar "anyKV") (EVar "items")) (EApp (EApp (EVar "EMapLit") (EVar "name")) (EApp (EVar "kvPairs") (EVar "items"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "ESetLit") (EVar "name")) (EApp (EVar "kvElems") (EVar "items"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "anyField" (TyFun (TyApp (TyCon "List") (TyCon "KvItem")) (TyCon "Bool")))
(DFunDef false "anyField" ((PList)) (EVar "False"))
(DFunDef false "anyField" ((PCons (PCon "KvField" PWild PWild) PWild)) (EVar "True"))
(DFunDef false "anyField" ((PCons PWild (PVar "rest"))) (EApp (EVar "anyField") (EVar "rest")))
(DTypeSig false "anyKV" (TyFun (TyApp (TyCon "List") (TyCon "KvItem")) (TyCon "Bool")))
(DFunDef false "anyKV" ((PList)) (EVar "False"))
(DFunDef false "anyKV" ((PCons (PCon "KvKV" PWild PWild) PWild)) (EVar "True"))
(DFunDef false "anyKV" ((PCons PWild (PVar "rest"))) (EApp (EVar "anyKV") (EVar "rest")))
(DTypeSig false "kvToField" (TyFun (TyCon "KvItem") (TyCon "FieldAssign")))
(DFunDef false "kvToField" ((PCon "KvField" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EVar "e")))
(DFunDef false "kvToField" ((PCon "KvElem" (PVar "e"))) (EApp (EVar "kvElemToField") (EApp (EVar "stripLoc") (EVar "e"))))
(DFunDef false "kvToField" (PWild) (EApp (EApp (EVar "FieldAssign") (ELit (LString "_"))) (EApp (EVar "ELit") (EVar "LUnit"))))
(DTypeSig false "kvElemToField" (TyFun (TyCon "Expr") (TyCon "FieldAssign")))
(DFunDef false "kvElemToField" ((PCon "EVar" (PVar "n"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EVar "EVar") (EVar "n"))))
(DFunDef false "kvElemToField" (PWild) (EApp (EApp (EVar "FieldAssign") (ELit (LString "_"))) (EApp (EVar "ELit") (EVar "LUnit"))))
(DTypeSig false "kvPairs" (TyFun (TyApp (TyCon "List") (TyCon "KvItem")) (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "kvPairs" ((PList)) (EListLit))
(DFunDef false "kvPairs" ((PCons (PCon "KvKV" (PVar "k") (PVar "v")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EVar "kvPairs") (EVar "rest"))))
(DFunDef false "kvPairs" ((PCons PWild (PVar "rest"))) (EApp (EVar "kvPairs") (EVar "rest")))
(DTypeSig false "kvElems" (TyFun (TyApp (TyCon "List") (TyCon "KvItem")) (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "kvElems" ((PList)) (EListLit))
(DFunDef false "kvElems" ((PCons (PCon "KvElem" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EVar "e") (EApp (EVar "kvElems") (EVar "rest"))))
(DFunDef false "kvElems" ((PCons PWild (PVar "rest"))) (EApp (EVar "kvElems") (EVar "rest")))
(DTypeSig false "parseRecordUpdate" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseRecordUpdate" () (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TLBrace"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TPipe"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "recordFieldExpr")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "fields")) (EApp (EApp (EVar "deferThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "ERecordUpdate") (EVar "e")) (EApp (EApp (EVar "map") (EApp (EVar "desugarDottedField") (EVar "e"))) (EVar "fields"))) (EVar "unminted"))))))))))))))))
(DTypeSig false "recordFieldExpr" (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr"))))
(DFunDef false "recordFieldExpr" () (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "identNameP")) (EApp (EVar "expectTok") (EVar "TDot")))) (ELam ((PVar "path")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "recordFieldExprRest") (EVar "path")) (EVar "t")))))))
(DTypeSig false "recordFieldExprRest" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr"))))))
(DFunDef false "recordFieldExprRest" ((PVar "path") (PCon "TEqual")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "committedExpr") (ELit (LString "expected a record field value after `=`"))) (EVar "parseBracketElem"))) (ELam ((PVar "e")) (EApp (EVar "deferPure") (ETuple (EVar "path") (EVar "e"))))))))
(DFunDef false "recordFieldExprRest" ((PList (PVar "x")) PWild) (EApp (EVar "deferPure") (ETuple (EListLit (EVar "x")) (EApp (EVar "EVar") (EVar "x")))))
(DFunDef false "recordFieldExprRest" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected `=` after the field name in a record update"))))
(DTypeSig false "desugarDottedField" (TyFun (TyCon "Expr") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr")) (TyCon "FieldAssign"))))
(DFunDef false "desugarDottedField" ((PVar "base") (PTuple (PVar "path") (PVar "value"))) (EMatch (EVar "path") (arm (PList (PVar "field")) () (EApp (EApp (EVar "FieldAssign") (EVar "field")) (EVar "value"))) (arm (PCons (PVar "field") (PVar "rest")) () (EApp (EApp (EVar "FieldAssign") (EVar "field")) (EApp (EApp (EApp (EVar "dottedGo") (EApp (EApp (EApp (EVar "EFieldAccess") (EVar "base")) (EVar "field")) (EVar "unminted"))) (EVar "rest")) (EVar "value")))) (arm (PList) () (EApp (EApp (EVar "FieldAssign") (ELit (LString "_"))) (EVar "value")))))
(DTypeSig false "dottedGo" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "dottedGo" ((PVar "cur") (PList (PVar "f")) (PVar "value")) (EApp (EApp (EApp (EVar "ERecordUpdate") (EVar "cur")) (EListLit (EApp (EApp (EVar "FieldAssign") (EVar "f")) (EVar "value")))) (EVar "unminted")))
(DFunDef false "dottedGo" ((PVar "cur") (PCons (PVar "f") (PVar "fs")) (PVar "value")) (EApp (EApp (EApp (EVar "ERecordUpdate") (EVar "cur")) (EListLit (EApp (EApp (EVar "FieldAssign") (EVar "f")) (EApp (EApp (EApp (EVar "dottedGo") (EApp (EApp (EApp (EVar "EFieldAccess") (EVar "cur")) (EVar "f")) (EVar "unminted"))) (EVar "fs")) (EVar "value"))))) (EVar "unminted")))
(DFunDef false "dottedGo" ((PVar "cur") (PList) (PVar "value")) (EVar "value"))
(DTypeSig false "parseInterp" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseInterp" () (EApp (EApp (EVar "deferThen") (EVar "interpOpenStr")) (ELam ((PVar "s0")) (EApp (EApp (EVar "deferThen") (EVar "interpRest")) (ELam ((PVar "rest")) (EApp (EVar "deferPure") (EApp (EVar "EStringInterp") (EBinOp "::" (EApp (EVar "InterpStr") (EVar "s0")) (EVar "rest")))))))))
(DTypeSig false "interpOpenStr" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "interpOpenStr" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "interpOpenFor") (EVar "t")))))
(DTypeSig false "interpOpenFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "interpOpenFor" ((PCon "TInterpOpen" (PVar "s"))) (EApp (EVar "emit") (EVar "s")))
(DFunDef false "interpOpenFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected interpolation open"))))
(DTypeSig false "interpRest" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "InterpPart"))))
(DFunDef false "interpRest" () (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "interpRestFor") (EVar "e")) (EVar "t")))))))
(DTypeSig false "interpRestFor" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "InterpPart"))))))
(DFunDef false "interpRestFor" ((PVar "e") (PCon "TInterpMid" (PVar "s"))) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "interpRest")) (ELam ((PVar "rest")) (EApp (EVar "deferPure") (EBinOp "::" (EApp (EVar "InterpExpr") (EVar "e")) (EBinOp "::" (EApp (EVar "InterpStr") (EVar "s")) (EVar "rest")))))))))
(DFunDef false "interpRestFor" ((PVar "e") (PCon "TInterpEnd" (PVar "s"))) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "deferPure") (EListLit (EApp (EVar "InterpExpr") (EVar "e")) (EApp (EVar "InterpStr") (EVar "s")))))))
(DFunDef false "interpRestFor" ((PVar "e") PWild) (EApp (EVar "failP") (ELit (LString "expected interpolation mid/end"))))
(DTypeSig false "parseBracketBlock" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseBracketBlock" () (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseStmts")) (ELam ((PVar "stmts")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "unrecordSoleStmt") (EVar "stmts"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EVar "blockOrExpr") (EVar "stmts"))))))))))))
(DTypeSig false "unrecordSoleStmt" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "unrecordSoleStmt" ((PList (PCon "DoExpr" PWild))) (EVar "forgetLatestUnitStart"))
(DFunDef false "unrecordSoleStmt" (PWild) (EApp (EVar "deferPure") (ELit LUnit)))
(DTypeSig false "parseBracketElem" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseBracketElem" () (EApp (EApp (EVar "parseOrElse") (EVar "parseBracketBlock")) (EVar "parseExpr")))
(DTypeSig false "parseParen" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseParen" () (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TLParen"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "committedExpr") (ELit (LString "expected a complete parenthesized expression"))) (EApp (EVar "parenFor") (EVar "t"))))))))
(DTypeSig false "committedExpr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Parser") (TyCon "Expr")) (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "committedExpr" ((PVar "msg") (PVar "p")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "p")) (EVar "pos")) (arm (PCon "PErr" (PVar "f") (PVar "q")) () (EBlock (DoLet false false (PVar "loc") (EApp (EApp (EVar "committedErrorPos") (EVar "ctx")) (EVar "q"))) (DoLet false false (PVar "reason") (EMatch (EVar "f") (arm (PCon "FailExpect" (PCon "TNewline") (PCon "TRParen")) () (EIf (EBinOp ">" (EVar "loc") (EVar "q")) (EApp (EVar "FailMsg") (ELit (LString "unexpected end of input; expected `)`"))) (EVar "f"))) (arm PWild () (EIf (EBinOp ">" (EVar "q") (EVar "pos")) (EVar "f") (EApp (EVar "FailMsg") (EVar "msg")))))) (DoExpr (EApp (EApp (EVar "PFatal") (EVar "reason")) (EVar "loc"))))) (arm (PVar "r") () (EVar "r"))))))
(DTypeSig false "committedErrorPos" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "committedErrorPos" ((PVar "ctx") (PVar "q")) (EBlock (DoLet false false (PVar "toks") (EApp (EVar "contextTokens") (EVar "ctx"))) (DoLet false false (PVar "offs") (EApp (EVar "contextOffsets") (EVar "ctx"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "q") (ELit (LInt 0))) (EBinOp "<" (EVar "q") (EApp (EVar "arrayLength") (EVar "offs")))) (EBinOp "==" (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "q")) (EVar "offs"))) (ELit (LInt 0)))) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "q")) (EVar "TNewline"))) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "q") (ELit (LInt 1)))) (EVar "TEof"))) (EBinOp "+" (EVar "q") (ELit (LInt 1))) (EVar "q")))))
(DTypeSig false "parenFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "parenFor" ((PCon "TRParen")) (EApp (EVar "emit") (EApp (EVar "ELit") (EVar "LUnit"))))
(DFunDef false "parenFor" ((PCon "TMinus")) (EApp (EApp (EVar "parseOrElse") (EVar "bareMinusSection")) (EVar "parseParenExpr")))
(DFunDef false "parenFor" ((PCon "TMinusTight")) (EApp (EApp (EVar "parseOrElse") (EVar "bareMinusSection")) (EVar "parseParenExpr")))
(DFunDef false "parenFor" ((PVar "t")) (EApp (EVar "parenSectionOr") (EVar "t")))
(DTypeSig false "parenSectionOr" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "parenSectionOr" ((PVar "t")) (EMatch (EApp (EVar "sectionOpStr") (EVar "t")) (arm (PCon "Some" (PVar "op")) () (EApp (EVar "parseSectionOp") (EVar "op"))) (arm (PCon "None") () (EVar "parseParenExpr"))))
(DTypeSig false "bareMinusSection" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "bareMinusSection" () (EApp (EApp (EVar "deferThen") (EVar "expectMinus")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EVar "ESection") (EApp (EVar "SecBare") (ELit (LString "-"))))))))))
(DTypeSig false "expectMinus" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "expectMinus" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "expectMinusGo") (EVar "t")))))
(DTypeSig false "expectMinusGo" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "expectMinusGo" ((PCon "TMinus")) (EApp (EVar "emit") (ELit LUnit)))
(DFunDef false "expectMinusGo" ((PCon "TMinusTight")) (EApp (EVar "emit") (ELit LUnit)))
(DFunDef false "expectMinusGo" (PWild) (EApp (EVar "failP") (ELit (LString "expected `-`"))))
(DTypeSig false "parseSectionOp" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "parseSectionOp" ((PVar "op")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "sectionTail") (EVar "op")) (EVar "t")))))))
(DTypeSig false "sectionTail" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "sectionTail" ((PVar "op") (PCon "TRParen")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EVar "ESection") (EApp (EVar "SecBare") (EVar "op")))))))
(DFunDef false "sectionTail" ((PVar "op") PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EVar "ESection") (EApp (EApp (EVar "SecRight") (EVar "op")) (EVar "e")))))))))
(DTypeSig false "parseParenExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseParenExpr" () (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "parseOrAltsExpr")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "es")) (EApp (EApp (EVar "deferThen") (EApp (EVar "optTrailingCommaTuple") (EVar "es"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EVar "parenResult") (EVar "es"))))))))))
(DTypeSig false "parseOrAltsExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseOrAltsExpr" () (EApp (EApp (EVar "deferThen") (EVar "parseBracketElem")) (ELam ((PVar "e")) (EApp (EApp (EVar "deferThen") (EApp (EVar "many") (EVar "orAltExpr"))) (ELam ((PVar "rest")) (EApp (EVar "deferPure") (EApp (EApp (EVar "orExprOf") (EVar "e")) (EVar "rest"))))))))
(DTypeSig false "orAltExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "orAltExpr" () (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TPipe"))) (ELam (PWild) (EVar "parseBracketElem"))))
(DTypeSig false "orExprOf" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr"))))
(DFunDef false "orExprOf" ((PVar "e") (PList)) (EVar "e"))
(DFunDef false "orExprOf" ((PVar "e") (PVar "rest")) (EApp (EVar "EOrPat") (EBinOp "::" (EVar "e") (EVar "rest"))))
(DTypeSig false "parenResult" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr")))
(DFunDef false "parenResult" ((PList (PVar "e"))) (EApp (EVar "leftSectionOrExpr") (EVar "e")))
(DFunDef false "parenResult" ((PVar "es")) (EApp (EVar "ETuple") (EVar "es")))
(DTypeSig false "leftSectionOrExpr" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "leftSectionOrExpr" ((PVar "e")) (EApp (EApp (EVar "leftSectionGo") (EVar "e")) (EApp (EVar "stripLoc1") (EVar "e"))))
(DTypeSig false "leftSectionGo" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "leftSectionGo" ((PVar "orig") (PCon "EBinOp" (PVar "op") (PVar "lhs") (PVar "rhs") PWild)) (EApp (EApp (EApp (EApp (EVar "leftSectionRhs") (EVar "orig")) (EVar "op")) (EVar "lhs")) (EApp (EVar "stripLoc1") (EVar "rhs"))))
(DFunDef false "leftSectionGo" ((PVar "orig") PWild) (EVar "orig"))
(DTypeSig false "leftSectionRhs" (TyFun (TyCon "Expr") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "leftSectionRhs" (PWild (PVar "op") (PVar "lhs") (PCon "EVar" (PLit (LString "_")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecLeft") (EVar "lhs")) (EVar "op"))))
(DFunDef false "leftSectionRhs" ((PVar "orig") PWild PWild PWild) (EVar "orig"))
(DTypeSig false "sectionOpStr" (TyFun (TyCon "Token") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "sectionOpStr" ((PCon "TPlus")) (EApp (EVar "Some") (ELit (LString "+"))))
(DFunDef false "sectionOpStr" ((PCon "TStar")) (EApp (EVar "Some") (ELit (LString "*"))))
(DFunDef false "sectionOpStr" ((PCon "TSlash")) (EApp (EVar "Some") (ELit (LString "/"))))
(DFunDef false "sectionOpStr" ((PCon "TEqEq")) (EApp (EVar "Some") (ELit (LString "=="))))
(DFunDef false "sectionOpStr" ((PCon "TNeq")) (EApp (EVar "Some") (ELit (LString "/="))))
(DFunDef false "sectionOpStr" ((PCon "TLt")) (EApp (EVar "Some") (ELit (LString "<"))))
(DFunDef false "sectionOpStr" ((PCon "TGt")) (EApp (EVar "Some") (ELit (LString ">"))))
(DFunDef false "sectionOpStr" ((PCon "TLeq")) (EApp (EVar "Some") (ELit (LString "<="))))
(DFunDef false "sectionOpStr" ((PCon "TGeq")) (EApp (EVar "Some") (ELit (LString ">="))))
(DFunDef false "sectionOpStr" ((PCon "TAnd")) (EApp (EVar "Some") (ELit (LString "&&"))))
(DFunDef false "sectionOpStr" ((PCon "TOr")) (EApp (EVar "Some") (ELit (LString "||"))))
(DFunDef false "sectionOpStr" ((PCon "TCons")) (EApp (EVar "Some") (ELit (LString "::"))))
(DFunDef false "sectionOpStr" ((PCon "TPlusPlus")) (EApp (EVar "Some") (ELit (LString "++"))))
(DFunDef false "sectionOpStr" ((PCon "TPipeRight")) (EApp (EVar "Some") (ELit (LString "|>"))))
(DFunDef false "sectionOpStr" ((PCon "TRCompose")) (EApp (EVar "Some") (ELit (LString ">>"))))
(DFunDef false "sectionOpStr" ((PCon "TLCompose")) (EApp (EVar "Some") (ELit (LString "<<"))))
(DFunDef false "sectionOpStr" (PWild) (EVar "None"))
(DTypeSig false "parseListE" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseListE" () (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TLBracket"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "listFor") (EVar "t")))))))
(DTypeSig false "listFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "listFor" ((PCon "TRBracket")) (EApp (EVar "emit") (EApp (EVar "EListLit") (EListLit))))
(DFunDef false "listFor" (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseBracketElem")) (ELam ((PVar "first")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "listRest") (EVar "first")) (EVar "t")))))))
(DTypeSig false "listRest" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "listRest" ((PVar "first") (PCon "TDotDot")) (EApp (EApp (EVar "rangeAfter") (EVar "first")) (EVar "False")))
(DFunDef false "listRest" ((PVar "first") (PCon "TDotDotEq")) (EApp (EApp (EVar "rangeAfter") (EVar "first")) (EVar "True")))
(DFunDef false "listRest" ((PVar "first") (PCon "TComma")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "listAfterComma") (EVar "first")) (EVar "t")))))))
(DFunDef false "listRest" ((PVar "first") (PCon "TRBracket")) (EApp (EVar "finishSingletonList") (EVar "first")))
(DFunDef false "listRest" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected `,`, `..`, `..=` or `]` in the list"))))
(DTypeSig false "finishSingletonList" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "finishSingletonList" ((PVar "first")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EVar "EListLit") (EListLit (EVar "first")))))))
(DTypeSig false "listAfterComma" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "listAfterComma" ((PVar "first") (PCon "TRBracket")) (EApp (EVar "finishSingletonList") (EVar "first")))
(DFunDef false "listAfterComma" ((PVar "first") PWild) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "parseBracketElem")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "rest")) (EApp (EApp (EVar "deferThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRBracket"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EVar "EListLit") (EBinOp "::" (EVar "first") (EVar "rest")))))))))))
(DTypeSig false "rangeAfter" (TyFun (TyCon "Expr") (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "rangeAfter" ((PVar "lo") (PVar "incl")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "hi")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRBracket"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "ERangeList") (EVar "lo")) (EVar "hi")) (EVar "incl"))))))))))
(DTypeSig false "parseArray" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseArray" () (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TLArray"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "arrayFor") (EVar "t")))))))
(DTypeSig false "arrayFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "arrayFor" ((PCon "TRArray")) (EApp (EVar "emit") (EApp (EVar "EArrayLit") (EListLit))))
(DFunDef false "arrayFor" (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseBracketElem")) (ELam ((PVar "first")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "arrayRest") (EVar "first")) (EVar "t")))))))
(DTypeSig false "arrayRest" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "arrayRest" ((PVar "first") (PCon "TDotDot")) (EApp (EApp (EVar "arrayRangeAfter") (EVar "first")) (EVar "False")))
(DFunDef false "arrayRest" ((PVar "first") (PCon "TDotDotEq")) (EApp (EApp (EVar "arrayRangeAfter") (EVar "first")) (EVar "True")))
(DFunDef false "arrayRest" ((PVar "first") (PCon "TComma")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "arrayAfterComma") (EVar "first")) (EVar "t")))))))
(DFunDef false "arrayRest" ((PVar "first") (PCon "TRArray")) (EApp (EVar "finishSingletonArray") (EVar "first")))
(DFunDef false "arrayRest" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected `,`, `..`, `..=` or `|]` in the array"))))
(DTypeSig false "finishSingletonArray" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "finishSingletonArray" ((PVar "first")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EVar "EArrayLit") (EListLit (EVar "first")))))))
(DTypeSig false "arrayAfterComma" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "arrayAfterComma" ((PVar "first") (PCon "TRArray")) (EApp (EVar "finishSingletonArray") (EVar "first")))
(DFunDef false "arrayAfterComma" ((PVar "first") PWild) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "parseBracketElem")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "rest")) (EApp (EApp (EVar "deferThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRArray"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EVar "EArrayLit") (EBinOp "::" (EVar "first") (EVar "rest")))))))))))
(DTypeSig false "arrayRangeAfter" (TyFun (TyCon "Expr") (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "arrayRangeAfter" ((PVar "lo") (PVar "incl")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "hi")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRArray"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "ERangeArray") (EVar "lo")) (EVar "hi")) (EVar "incl"))))))))))
(DTypeSig false "parseIf" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseIf" () (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TIf"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "ifKind") (EVar "t")))))))
(DTypeSig false "ifKind" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "ifKind" ((PCon "TLet")) (EVar "ifLet"))
(DFunDef false "ifKind" (PWild) (EVar "ifPlain"))
(DTypeSig false "ifLet" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "ifLet" () (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TLet"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parsePat")) (ELam ((PVar "pat")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "scrut")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TThen"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "thenE")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TElse"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "elseE")) (EApp (EVar "deferPure") (EApp (EApp (EVar "EMatch") (EVar "scrut")) (EListLit (EApp (EApp (EApp (EVar "Arm") (EVar "pat")) (EListLit)) (EVar "thenE")) (EApp (EApp (EApp (EVar "Arm") (EVar "PWild")) (EListLit)) (EVar "elseE"))))))))))))))))))))))
(DTypeSig false "ifPlain" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "ifPlain" () (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "cond")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TThen"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseBranch")) (ELam ((PVar "thenE")) (EApp (EApp (EVar "deferThen") (EVar "elseBranch")) (ELam ((PVar "elseE")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "EIf") (EVar "cond")) (EVar "thenE")) (EVar "elseE"))))))))))))
(DTypeSig false "elseBranch" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "elseBranch" () (EApp (EApp (EVar "parseOrElse") (EVar "elsePresent")) (EApp (EVar "deferPure") (EApp (EVar "ELit") (EVar "LUnit")))))
(DTypeSig false "elsePresent" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "elsePresent" () (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TElse"))) (ELam (PWild) (EVar "parseBranch"))))
(DTypeSig false "parseBranch" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseBranch" () (EApp (EApp (EVar "parseOrElse") (EVar "branchBlock")) (EVar "parseExpr")))
(DTypeSig false "branchBlock" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "branchBlock" () (EVar "parseBracketBlock"))
(DTypeSig false "parseLet" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseLet" () (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TLet"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EApp (EVar "letExprKind") (EVar "t"))) (ELam ((PVar "e")) (EApp (EVar "deferPure") (EApp (EApp (EVar "atLetSite") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EBinOp "+" (EVar "s") (ELit (LInt 1))))) (EVar "e"))))))))))))))
(DTypeSig false "letExprKind" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "letExprKind" ((PCon "TMut")) (EApp (EVar "failP") (EVar "letMutRemovedMsg")))
(DFunDef false "letExprKind" ((PCon "TRec")) (EVar "letRecExpr"))
(DFunDef false "letExprKind" ((PCon "TIdent" (PVar "name"))) (EApp (EVar "letIdentExpr") (EVar "name")))
(DFunDef false "letExprKind" (PWild) (EVar "letPatExpr"))
(DTypeSig false "letIdentExpr" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "letIdentExpr" ((PVar "name")) (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "params")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EApp (EVar "letIdentExprRest") (EVar "name")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EBinOp "+" (EVar "s") (ELit (LInt 1))))) (EVar "params")) (EVar "t")))))))))))))
(DTypeSig false "letIdentExprRest" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))))
(DFunDef false "letIdentExprRest" ((PVar "name") (PVar "nameLoc") (PList) (PCon "TColon")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "e1")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TIn"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "noDeclLoc")) (EVar "False")) (EApp (EApp (EApp (EVar "PVar") (EVar "name")) (EVar "nameLoc")) (EVar "noBinderId"))) (EApp (EApp (EVar "EAnnot") (EVar "e1")) (EVar "ty"))) (EVar "e2"))))))))))))))))
(DFunDef false "letIdentExprRest" ((PVar "name") (PVar "nameLoc") (PList) (PCon "TEqual")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "e1")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TIn"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "noDeclLoc")) (EVar "False")) (EApp (EApp (EApp (EVar "PVar") (EVar "name")) (EVar "nameLoc")) (EVar "noBinderId"))) (EVar "e1")) (EVar "e2"))))))))))))
(DFunDef false "letIdentExprRest" ((PVar "name") (PVar "nameLoc") (PVar "params") (PCon "TEqual")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "e1")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TIn"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "noDeclLoc")) (EVar "True")) (EApp (EApp (EApp (EVar "PVar") (EVar "name")) (EVar "nameLoc")) (EVar "noBinderId"))) (EApp (EApp (EVar "curryLam") (EVar "params")) (EVar "e1"))) (EVar "e2"))))))))))))
(DFunDef false "letIdentExprRest" (PWild PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected `:` or `=` after the `let` name"))))
(DTypeSig false "letPatExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "letPatExpr" () (EApp (EApp (EVar "deferThen") (EVar "parsePat")) (ELam ((PVar "pat")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "e1")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TIn"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "noDeclLoc")) (EVar "False")) (EVar "pat")) (EVar "e1")) (EVar "e2"))))))))))))))
(DTypeSig false "letRecExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "letRecExpr" () (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRec"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "letRecInlineClause")) (ELam ((PVar "clause")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TIn"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EVar "deferPure") (EApp (EApp (EVar "ELetGroup") (EApp (EVar "coalesceClauses") (EListLit (EVar "clause")))) (EVar "e2"))))))))))))
(DTypeSig false "letRecInlineClause" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyCon "Loc"))))
(DFunDef false "letRecInlineClause" () (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "deferThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "body")) (EApp (EVar "deferPure") (ETuple (EVar "name") (EVar "pats") (EVar "body") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EBinOp "+" (EVar "s") (ELit (LInt 1)))))))))))))))))))
(DTypeSig false "parseMatch" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseMatch" () (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "matchPos")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TMatch"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "scrut")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "parseArms") (EVar "matchPos"))) (ELam ((PVar "arms")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EVar "EMatch") (EVar "scrut")) (EVar "arms"))))))))))))))))
(DTypeSig false "parseArms" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Arm")))))
(DFunDef false "parseArms" ((PVar "matchPos")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "armsLoop") (EVar "matchPos")))))
(DTypeSig false "armsLoop" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Arm")))))
(DFunDef false "armsLoop" ((PVar "matchPos")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EIf (EBinOp "==" (EVar "t") (EVar "TDedent")) (EApp (EVar "deferPure") (EListLit)) (EApp (EVar "armsCons") (EVar "matchPos"))))))
(DTypeSig false "armsCons" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Arm")))))
(DFunDef false "armsCons" ((PVar "matchPos")) (EApp (EApp (EVar "deferThen") (EApp (EVar "parseArm") (EVar "matchPos"))) (ELam ((PVar "a")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "armsLoop") (EVar "matchPos"))) (ELam ((PVar "rest")) (EApp (EVar "deferPure") (EBinOp "::" (EVar "a") (EVar "rest"))))))))))
(DTypeSig false "parseArm" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyCon "Arm"))))
(DFunDef false "parseArm" ((PVar "matchPos")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "parseArmPat")) (EVar "pos")) (arm (PCon "POk" (PVar "pat") (PVar "q")) () (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EApp (EApp (EVar "parseArmRest") (EVar "pos")) (EVar "pat"))) (EVar "q"))) (arm (PCon "PFatal" (PVar "f") (PVar "q")) () (EApp (EApp (EVar "PFatal") (EVar "f")) (EVar "q"))) (arm (PCon "PErr" PWild PWild) () (EBlock (DoLet false false (PVar "hint") (EIf (EApp (EVar "contextHasTab") (EVar "ctx")) (EVar "None") (EApp (EApp (EApp (EApp (EApp (EVar "matchContinuationHint") (EApp (EVar "contextTokens") (EVar "ctx"))) (EApp (EVar "contextOffsets") (EVar "ctx"))) (EApp (EVar "contextLineStarts") (EVar "ctx"))) (EVar "matchPos")) (EVar "pos")))) (DoLet false false (PVar "kind") (EApp (EApp (EVar "optionOr") (EVar "ExpectedMatchArm")) (EVar "hint"))) (DoExpr (EApp (EApp (EVar "PFatal") (EApp (EVar "FailProblem") (EVar "kind"))) (EVar "pos")))))))))
(DTypeSig false "parseArmRest" (TyFun (TyCon "Int") (TyFun (TyCon "Pat") (TyApp (TyCon "Parser") (TyCon "Arm")))))
(DFunDef false "parseArmRest" ((PVar "p") (PVar "pat")) (EApp (EApp (EVar "deferThen") (EVar "armGuardOpt")) (ELam ((PVar "guards")) (EApp (EApp (EVar "deferThen") (EVar "matchArrow")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "matchBody")) (ELam ((PVar "body")) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "recordUnitStart") (ELit (LInt 0))) (EVar "p"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "Arm") (EVar "pat")) (EVar "guards")) (EVar "body"))))))))))))
(DTypeSig false "matchArrow" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "matchArrow" () (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EApp (EVar "expectTok") (EVar "TFatArrow"))) (EVar "pos")) (arm (PCon "PErr" PWild (PVar "q")) () (EApp (EApp (EVar "PFatal") (EApp (EVar "FailProblem") (EVar "ExpectedMatchArrow"))) (EVar "q"))) (arm (PVar "r") () (EVar "r"))))))
(DTypeSig false "matchBody" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "matchBody" () (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EApp (EApp (EVar "parseOrElse") (EVar "branchBlock")) (EVar "parseBodyExpr"))) (EVar "pos")) (arm (PCon "PErr" (PVar "f") (PVar "q")) () (EApp (EApp (EVar "PFatal") (EVar "f")) (EVar "q"))) (arm (PVar "r") () (EVar "r"))))))
(DTypeSig false "armGuardOpt" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Guard"))))
(DFunDef false "armGuardOpt" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "armGuardFor") (EVar "t")))))
(DTypeSig false "armGuardFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Guard")))))
(DFunDef false "armGuardFor" ((PCon "TIf")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "sepBy1") (EVar "parseGuard")) (EApp (EVar "expectTok") (EVar "TComma"))))))
(DFunDef false "armGuardFor" (PWild) (EApp (EVar "deferPure") (EListLit)))
(DTypeSig false "parseArmPat" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parseArmPat" () (EApp (EApp (EVar "deferThen") (EVar "parsePat")) (ELam ((PVar "p")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "armPatAlts") (EListLit (EVar "p"))) (EVar "t")))))))
(DTypeSig false "armPatAlts" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat")))))
(DFunDef false "armPatAlts" ((PVar "acc") (PCon "TPipe")) (EApp (EVar "barSteer") (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parsePat")) (ELam ((PVar "q")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "armAltEnd") (EBinOp "::" (EVar "q") (EVar "acc"))) (EVar "t"))))))))))
(DFunDef false "armPatAlts" ((PVar "acc") PWild) (EApp (EVar "deferPure") (EApp (EVar "orPatOf") (EApp (EVar "reverseL") (EVar "acc")))))
(DTypeSig false "armAltEnd" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat")))))
(DFunDef false "armAltEnd" ((PVar "acc") (PCon "TPipe")) (EApp (EApp (EVar "armPatAlts") (EVar "acc")) (EVar "TPipe")))
(DFunDef false "armAltEnd" ((PVar "acc") (PCon "TFatArrow")) (EApp (EApp (EVar "armPatAlts") (EVar "acc")) (EVar "TFatArrow")))
(DFunDef false "armAltEnd" ((PVar "acc") (PCon "TIf")) (EApp (EApp (EVar "armPatAlts") (EVar "acc")) (EVar "TIf")))
(DFunDef false "armAltEnd" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected `=>` after the alternative"))))
(DTypeSig false "barSteer" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyApp (TyCon "Parser") (TyVar "a"))))
(DFunDef false "barSteer" ((PVar "p")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "p")) (EVar "pos")) (arm (PCon "PErr" PWild PWild) () (EApp (EApp (EVar "PFatal") (EApp (EVar "FailProblem") (EApp (EVar "barSteerKind") (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "peek2P")) (EVar "pos"))))) (EVar "pos"))) (arm (PVar "r") () (EVar "r"))))))
(DTypeSig false "barSteerKind" (TyFun (TyApp (TyCon "PR") (TyCon "Token")) (TyCon "ParseDiagnosticKind")))
(DFunDef false "barSteerKind" ((PCon "POk" (PCon "TIndent") PWild)) (EVar "MatchGuardBarWrapped"))
(DFunDef false "barSteerKind" (PWild) (EVar "MatchGuardBar"))
(DTypeSig false "parsePat" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePat" () (EVar "parsePatCons"))
(DTypeSig false "parseAsPat" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parseAsPat" () (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "identNameP")) (ELam ((PVar "x")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TAsAt"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parsePatApp")) (ELam ((PVar "sub")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EVar "PAs") (EVar "x")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))) (EVar "noBinderId")) (EVar "sub"))))))))))))))))
(DTypeSig false "parsePatCons" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatCons" () (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "parseOrElse") (EVar "parseAsPat")) (EVar "parsePatApp"))) (ELam ((PVar "p")) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "patConsTail") (EVar "p"))) (EApp (EVar "deferPure") (EVar "p"))))))
(DTypeSig false "patConsTail" (TyFun (TyCon "Pat") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "patConsTail" ((PVar "p")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TCons"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parsePatCons")) (ELam ((PVar "q")) (EApp (EVar "deferPure") (EApp (EApp (EVar "PCons") (EVar "p")) (EVar "q"))))))))
(DTypeSig false "parsePatApp" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatApp" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "patAppFor") (EVar "t")))))
(DTypeSig false "patAppFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "patAppFor" ((PCon "TUpper" (PVar "c"))) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "upperQualTail") (EVar "c"))) (ELam ((PVar "n")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "upperPatRest") (EVar "n")) (EVar "t")))))))))
(DFunDef false "patAppFor" (PWild) (EVar "parsePatAtom"))
(DTypeSig false "upperPatRest" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat")))))
(DFunDef false "upperPatRest" ((PVar "c") (PCon "TLBrace")) (EApp (EVar "recordPat") (EVar "c")))
(DFunDef false "upperPatRest" ((PVar "c") PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "many") (EVar "parsePatAtom"))) (ELam ((PVar "args")) (EApp (EVar "deferPure") (EApp (EApp (EVar "PCon") (EVar "c")) (EVar "args"))))))
(DTypeSig false "recordPat" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "recordPat" ((PVar "c")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TLBrace"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "recordPatFields")) (ELam ((PVar "fr")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EVar "mkRec") (EVar "c")) (EVar "fr"))))))))))
(DTypeSig false "mkRec" (TyFun (TyCon "String") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool")) (TyCon "Pat"))))
(DFunDef false "mkRec" ((PVar "c") (PTuple (PVar "fields") (PVar "rest"))) (EApp (EApp (EApp (EVar "PRec") (EVar "c")) (EVar "fields")) (EVar "rest")))
(DTypeSig false "recordPatFields" (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool"))))
(DFunDef false "recordPatFields" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "recordPatFieldsFor") (EVar "t")))))
(DTypeSig false "recordPatFieldsFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool")))))
(DFunDef false "recordPatFieldsFor" ((PCon "TEllipsis")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "deferPure") (ETuple (EListLit) (EVar "True"))))))
(DFunDef false "recordPatFieldsFor" ((PCon "TRBrace")) (EApp (EVar "deferPure") (ETuple (EListLit) (EVar "False"))))
(DFunDef false "recordPatFieldsFor" (PWild) (EApp (EApp (EVar "deferThen") (EVar "recordPatField")) (ELam ((PVar "f")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "recordPatFieldsRest") (EVar "f")) (EVar "t")))))))
(DTypeSig false "recordPatFieldsRest" (TyFun (TyCon "RecPatField") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool"))))))
(DFunDef false "recordPatFieldsRest" ((PVar "f") (PCon "TComma")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "recordPatFields")) (ELam ((PVar "fr")) (EApp (EVar "deferPure") (EApp (EApp (EVar "consField") (EVar "f")) (EVar "fr"))))))))
(DFunDef false "recordPatFieldsRest" ((PVar "f") PWild) (EApp (EVar "deferPure") (ETuple (EListLit (EVar "f")) (EVar "False"))))
(DTypeSig false "consField" (TyFun (TyCon "RecPatField") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool")) (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool")))))
(DFunDef false "consField" ((PVar "f") (PTuple (PVar "fs") (PVar "rest"))) (ETuple (EBinOp "::" (EVar "f") (EVar "fs")) (EVar "rest")))
(DTypeSig false "recordPatField" (TyApp (TyCon "Parser") (TyCon "RecPatField")))
(DFunDef false "recordPatField" () (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "recordPatFieldRest") (EVar "name")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EBinOp "+" (EVar "s") (ELit (LInt 1))))) (EVar "t")))))))))))
(DTypeSig false "recordPatFieldRest" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "RecPatField"))))))
(DFunDef false "recordPatFieldRest" ((PVar "name") (PVar "nameLoc") (PCon "TEqual")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parsePat")) (ELam ((PVar "p")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EVar "RecPatField") (EVar "name")) (EVar "nameLoc")) (EVar "noBinderId")) (EApp (EVar "Some") (EVar "p")))))))))
(DFunDef false "recordPatFieldRest" ((PVar "name") (PVar "nameLoc") PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EVar "RecPatField") (EVar "name")) (EVar "nameLoc")) (EVar "noBinderId")) (EVar "None"))))
(DTypeSig false "reservedIdentKeyword" (TyFun (TyCon "Token") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TWith")) (EApp (EVar "Some") (ELit (LString "with"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TMut")) (EApp (EVar "Some") (ELit (LString "mut"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TIn")) (EApp (EVar "Some") (ELit (LString "in"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TMatch")) (EApp (EVar "Some") (ELit (LString "match"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TData")) (EApp (EVar "Some") (ELit (LString "data"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TInterface")) (EApp (EVar "Some") (ELit (LString "interface"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TDefault")) (EApp (EVar "Some") (ELit (LString "default"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TImpl")) (EApp (EVar "Some") (ELit (LString "impl"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TImport")) (EApp (EVar "Some") (ELit (LString "import"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TExport")) (EApp (EVar "Some") (ELit (LString "export"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TPublic")) (EApp (EVar "Some") (ELit (LString "public"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TWhere")) (EApp (EVar "Some") (ELit (LString "where"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TOf")) (EApp (EVar "Some") (ELit (LString "of"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TDo")) (EApp (EVar "Some") (ELit (LString "do"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TDefer")) (EApp (EVar "Some") (ELit (LString "defer"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TAs")) (EApp (EVar "Some") (ELit (LString "as"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TExtern")) (EApp (EVar "Some") (ELit (LString "extern"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TRequires")) (EApp (EVar "Some") (ELit (LString "requires"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TDeriving")) (EApp (EVar "Some") (ELit (LString "deriving"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TType")) (EApp (EVar "Some") (ELit (LString "type"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TNewtype")) (EApp (EVar "Some") (ELit (LString "newtype"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TProp")) (EApp (EVar "Some") (ELit (LString "prop"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TTest")) (EApp (EVar "Some") (ELit (LString "test"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TBench")) (EApp (EVar "Some") (ELit (LString "bench"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TEffect")) (EApp (EVar "Some") (ELit (LString "effect"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TFunction")) (EApp (EVar "Some") (ELit (LString "function"))))
(DFunDef false "reservedIdentKeyword" (PWild) (EVar "None"))
(DTypeSig false "reservedKeywordMsg" (TyFun (TyCon "String") (TyCon "ParseDiagnosticKind")))
(DFunDef false "reservedKeywordMsg" ((PVar "name")) (EApp (EVar "ReservedKeyword") (EVar "name")))
(DTypeSig false "reservedOrPatFail" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "reservedOrPatFail" ((PVar "t")) (EMatch (EApp (EVar "reservedIdentKeyword") (EVar "t")) (arm (PCon "Some" (PVar "name")) () (EApp (EVar "fatalP") (EApp (EVar "reservedKeywordMsg") (EVar "name")))) (arm (PCon "None") () (EApp (EVar "failP") (ELit (LString "expected a pattern"))))))
(DTypeSig false "parsePatAtom" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatAtom" () (EApp (EApp (EApp (EVar "withDepth") (EVar "maxNestDepth")) (EApp (EVar "FailMsg") (EVar "nestTooDeepMsg"))) (EVar "parsePatAtomRaw")))
(DTypeSig false "parsePatAtomRaw" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatAtomRaw" () (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TIdent" (PVar "x")) () (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EBinOp "+" (EVar "s") (ELit (LInt 1))))) (EVar "noBinderId")))))))) (arm (PCon "TUnderscore") () (EApp (EVar "emit") (EVar "PWild"))) (arm (PCon "TInt" (PVar "n") PWild) ((GBool (EApp (EVar "isIntMinLit") (EVar "n")))) (EApp (EVar "fatalP") (EVar "intLitTooBigMsg"))) (arm (PCon "TInt" (PVar "n") PWild) () (EApp (EVar "intPatRest") (EApp (EVar "LInt") (EVar "n")))) (arm (PCon "TWideInt" PWild PWild (PVar "lx")) () (EApp (EVar "fatalP") (EApp (EVar "widePatMsg") (EVar "lx")))) (arm (PCon "TMinus") () (EVar "negIntPat")) (arm (PCon "TMinusTight") () (EVar "negIntPat")) (arm (PCon "TFloat" (PVar "f")) () (EApp (EVar "emit") (EApp (EVar "PLit") (EApp (EVar "LFloat") (EVar "f"))))) (arm (PCon "TString" (PVar "s")) () (EApp (EVar "emit") (EApp (EVar "PLit") (EApp (EVar "LString") (EVar "s"))))) (arm (PCon "TChar" (PVar "s")) () (EApp (EVar "charPatRest") (EApp (EVar "LChar") (EVar "s")))) (arm (PCon "TByte" (PVar "n")) () (EApp (EVar "bytePatRest") (EApp (EVar "LByte") (EVar "n")))) (arm (PCon "TUpper" (PVar "c")) () (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "upperQualTail") (EVar "c"))) (ELam ((PVar "n")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t2")) (EApp (EApp (EVar "upperAtomRest") (EVar "n")) (EVar "t2"))))))))) (arm (PCon "TLParen") () (EVar "parsePatParen")) (arm (PCon "TLBracket") () (EVar "parsePatList")) (arm PWild () (EApp (EVar "reservedOrPatFail") (EVar "t")))))))))
(DTypeSig false "upperAtomRest" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat")))))
(DFunDef false "upperAtomRest" ((PVar "c") (PCon "TLBrace")) (EApp (EVar "recordPat") (EVar "c")))
(DFunDef false "upperAtomRest" ((PVar "c") PWild) (EApp (EVar "deferPure") (EApp (EApp (EVar "PCon") (EVar "c")) (EListLit))))
(DTypeSig false "parseParamPat" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parseParamPat" () (EApp (EApp (EVar "parseOrElse") (EVar "parseParamAsPat")) (EVar "parsePatAtom")))
(DTypeSig false "parseParamAsPat" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parseParamAsPat" () (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "identNameP")) (ELam ((PVar "x")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TAsAt"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parsePatAtom")) (ELam ((PVar "sub")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EVar "PAs") (EVar "x")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))) (EVar "noBinderId")) (EVar "sub"))))))))))))))))
(DTypeSig false "intPatRest" (TyFun (TyCon "Lit") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "intPatRest" ((PVar "lo")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "rngPatRest") (EVar "lo")) (EVar "intBound")) (EVar "t")))))))
(DTypeSig false "negIntPat" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "negIntPat" () (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TInt" (PVar "n") PWild) () (EApp (EVar "negIntRng") (EApp (EVar "LInt") (EApp (EVar "negateLiteral") (EVar "n"))))) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected an integer after `-`"))))))))))
(DTypeSig false "negIntRng" (TyFun (TyCon "Lit") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "negIntRng" ((PVar "lo")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TDotDot") () (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "intBound")) (ELam ((PVar "hi")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "PRng") (EVar "lo")) (EVar "hi")) (EVar "False")))))))) (arm (PCon "TDotDotEq") () (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "intBound")) (ELam ((PVar "hi")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "PRng") (EVar "lo")) (EVar "hi")) (EVar "True")))))))) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected `..` or `..=` after the range bound"))))))))))
(DTypeSig false "charPatRest" (TyFun (TyCon "Lit") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "charPatRest" ((PVar "lo")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "rngPatRest") (EVar "lo")) (EVar "charBound")) (EVar "t")))))))
(DTypeSig false "bytePatRest" (TyFun (TyCon "Lit") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "bytePatRest" ((PVar "lo")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "rngPatRest") (EVar "lo")) (EVar "byteBound")) (EVar "t")))))))
(DTypeSig false "rngPatRest" (TyFun (TyCon "Lit") (TyFun (TyApp (TyCon "Parser") (TyCon "Lit")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat"))))))
(DFunDef false "rngPatRest" ((PVar "lo") (PVar "bound") (PCon "TDotDot")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "bound")) (ELam ((PVar "hi")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "PRng") (EVar "lo")) (EVar "hi")) (EVar "False"))))))))
(DFunDef false "rngPatRest" ((PVar "lo") (PVar "bound") (PCon "TDotDotEq")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "bound")) (ELam ((PVar "hi")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "PRng") (EVar "lo")) (EVar "hi")) (EVar "True"))))))))
(DFunDef false "rngPatRest" ((PVar "lo") PWild PWild) (EApp (EVar "deferPure") (EApp (EVar "PLit") (EVar "lo"))))
(DTypeSig false "intBound" (TyApp (TyCon "Parser") (TyCon "Lit")))
(DFunDef false "intBound" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "intBoundFor") (EVar "t")))))
(DTypeSig false "intBoundFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Lit"))))
(DFunDef false "intBoundFor" ((PCon "TInt" (PVar "n") PWild)) (EIf (EApp (EVar "isIntMinLit") (EVar "n")) (EApp (EVar "fatalP") (EVar "intLitTooBigMsg")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "intBoundFor" ((PCon "TInt" (PVar "n") PWild)) (EApp (EVar "emit") (EApp (EVar "LInt") (EVar "n"))))
(DFunDef false "intBoundFor" ((PCon "TWideInt" PWild PWild (PVar "lx"))) (EApp (EVar "fatalP") (EApp (EVar "widePatMsg") (EVar "lx"))))
(DFunDef false "intBoundFor" ((PCon "TMinus")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TInt" (PVar "n") PWild) () (EApp (EVar "emit") (EApp (EVar "LInt") (EApp (EVar "negateLiteral") (EVar "n"))))) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected an integer after `-` in the range bound"))))))))))
(DFunDef false "intBoundFor" ((PCon "TMinusTight")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TInt" (PVar "n") PWild) () (EApp (EVar "emit") (EApp (EVar "LInt") (EApp (EVar "negateLiteral") (EVar "n"))))) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected an integer after `-` in the range bound"))))))))))
(DFunDef false "intBoundFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected an integer range bound"))))
(DTypeSig false "charBound" (TyApp (TyCon "Parser") (TyCon "Lit")))
(DFunDef false "charBound" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "charBoundFor") (EVar "t")))))
(DTypeSig false "byteBound" (TyApp (TyCon "Parser") (TyCon "Lit")))
(DFunDef false "byteBound" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "byteBoundFor") (EVar "t")))))
(DTypeSig false "byteBoundFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Lit"))))
(DFunDef false "byteBoundFor" ((PCon "TByte" (PVar "n"))) (EApp (EVar "emit") (EApp (EVar "LByte") (EVar "n"))))
(DFunDef false "byteBoundFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected a byte range bound"))))
(DTypeSig false "charBoundFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Lit"))))
(DFunDef false "charBoundFor" ((PCon "TChar" (PVar "s"))) (EApp (EVar "emit") (EApp (EVar "LChar") (EVar "s"))))
(DFunDef false "charBoundFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected a character range bound"))))
(DTypeSig false "tuplePatOrSingle" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Pat")))
(DFunDef false "tuplePatOrSingle" ((PList (PVar "p"))) (EVar "p"))
(DFunDef false "tuplePatOrSingle" ((PVar "ps")) (EApp (EVar "PTuple") (EVar "ps")))
(DTypeSig false "parsePatParen" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatParen" () (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TLParen"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "patParenFor") (EVar "t")))))))
(DTypeSig false "patParenFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "patParenFor" ((PCon "TRParen")) (EApp (EVar "emit") (EApp (EVar "PLit") (EVar "LUnit"))))
(DFunDef false "patParenFor" (PWild) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "parsePatAlts")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "ps")) (EApp (EApp (EVar "deferThen") (EApp (EVar "optTrailingCommaTuple") (EVar "ps"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EVar "tuplePatOrSingle") (EVar "ps"))))))))))
(DTypeSig false "parsePatAlts" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatAlts" () (EApp (EApp (EVar "deferThen") (EVar "parsePat")) (ELam ((PVar "p")) (EApp (EApp (EVar "deferThen") (EApp (EVar "many") (EVar "patAlt"))) (ELam ((PVar "rest")) (EApp (EVar "deferPure") (EApp (EVar "orPatOf") (EBinOp "::" (EVar "p") (EVar "rest")))))))))
(DTypeSig false "patAlt" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "patAlt" () (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TPipe"))) (ELam (PWild) (EVar "parsePat"))))
(DTypeSig false "parsePatList" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatList" () (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TLBracket"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "patListFor") (EVar "t")))))))
(DTypeSig false "patListFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "patListFor" ((PCon "TRBracket")) (EApp (EVar "emit") (EApp (EVar "PList") (EListLit))))
(DFunDef false "patListFor" (PWild) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "parsePat")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "ps")) (EApp (EApp (EVar "deferThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRBracket"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EVar "PList") (EVar "ps"))))))))))
(DTypeSig false "parseTy" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTy" () (EApp (EApp (EVar "deferThen") (EVar "parseTyFun")) (ELam ((PVar "lhs")) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "constraintTail") (EVar "lhs"))) (EApp (EVar "deferPure") (EVar "lhs"))))))
(DTypeSig false "constraintTail" (TyFun (TyCon "Ty") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "constraintTail" ((PVar "lhs")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TFatArrow"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EApp (EVar "tyArrowSkipLayout") (EVar "t"))) (ELam ((PVar "indented")) (EApp (EApp (EVar "deferThen") (EVar "parseTy")) (ELam ((PVar "rhs")) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "deferWhen") (EVar "indented")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "expectTok") (EVar "TDedent")))))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EVar "TyConstrained") (EApp (EVar "extractConstraints") (EVar "lhs"))) (EVar "rhs"))))))))))))))
(DTypeSig false "extractConstraints" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Constraint"))))
(DFunDef false "extractConstraints" ((PCon "TyApp" (PVar "f") (PVar "a"))) (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "f")) (EVar "a"))) (arm (PCon "Some" (PTuple (PVar "iface") (PVar "args"))) () (EListLit (EApp (EApp (EVar "constraintUnresolved") (EVar "iface")) (EVar "args")))) (arm (PCon "None") () (EListLit))))
(DFunDef false "extractConstraints" ((PRec "TyCon" ((rf "tyConName" (PVar "iface"))) false)) (EListLit (EApp (EApp (EVar "constraintUnresolved") (EVar "iface")) (EListLit))))
(DFunDef false "extractConstraints" ((PCon "TyTuple" (PVar "cs"))) (EApp (EVar "concatMapC") (EVar "cs")))
(DFunDef false "extractConstraints" (PWild) (EListLit))
(DTypeSig false "tyAppSpine" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty"))))))
(DFunDef false "tyAppSpine" ((PVar "t")) (EApp (EApp (EVar "tyAppSpineAcc") (EVar "t")) (EListLit)))
(DTypeSig false "tyAppSpineAcc" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty")))))))
(DFunDef false "tyAppSpineAcc" ((PRec "TyCon" ((rf "tyConName" (PVar "iface"))) false) (PVar "acc")) (EApp (EVar "Some") (ETuple (EVar "iface") (EVar "acc"))))
(DFunDef false "tyAppSpineAcc" ((PCon "TyApp" (PVar "f") (PVar "a")) (PVar "acc")) (EApp (EApp (EVar "tyAppSpineAcc") (EVar "f")) (EBinOp "::" (EVar "a") (EVar "acc"))))
(DFunDef false "tyAppSpineAcc" (PWild PWild) (EVar "None"))
(DTypeSig false "concatMapC" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Constraint"))))
(DFunDef false "concatMapC" ((PList)) (EListLit))
(DFunDef false "concatMapC" ((PCons (PVar "t") (PVar "rest"))) (EBinOp "++" (EApp (EVar "extractConstraints") (EVar "t")) (EApp (EVar "concatMapC") (EVar "rest"))))
(DTypeSig false "parseTyFun" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyFun" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "tyFor") (EVar "t")))))
(DTypeSig false "tyFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "tyFor" ((PCon "TLt")) (EVar "parseEffectTy"))
(DFunDef false "tyFor" (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseTyApp")) (ELam ((PVar "left")) (EApp (EVar "tyAfterApp") (EVar "left")))))
(DTypeSig false "tyAfterApp" (TyFun (TyCon "Ty") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "tyAfterApp" ((PAs "left" (PCon "TyNamed" PWild PWild PWild))) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "tyArrowTail") (EVar "left"))) (EApp (EVar "failP") (EVar "namedArgNeedsArrowMsg"))))
(DFunDef false "tyAfterApp" ((PVar "left")) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "tyArrowTail") (EVar "left"))) (EApp (EVar "deferPure") (EVar "left"))))
(DTypeSig false "namedArgNeedsArrowMsg" (TyCon "String"))
(DFunDef false "namedArgNeedsArrowMsg" () (ELit (LString "a named argument `(name : T)` must be followed by `->`, as in `(path : String) -> <FileRead path> Result String String`")))
(DTypeSig false "parseEffectTy" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseEffectTy" () (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TLt"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "effectBody")) (ELam ((PVar "body")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TGt"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseTy")) (ELam ((PVar "inner")) (EApp (EVar "deferPure") (EApp (EApp (EVar "mkEffect") (EVar "body")) (EVar "inner"))))))))))))
(DTypeSig false "mkEffect" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "mkEffect" ((PTuple (PVar "labels") (PVar "tail")) (PVar "inner")) (EApp (EApp (EApp (EVar "TyEffect") (EVar "labels")) (EVar "tail")) (EVar "inner")))
(DTypeSig false "effectBody" (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "effectBody" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "effectBodyFor") (EVar "t")))))
(DTypeSig false "effectBodyFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "effectBodyFor" ((PCon "TUpper" PWild)) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "effAtomP")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "labels")) (EApp (EApp (EVar "deferThen") (EVar "pipeTail")) (ELam ((PVar "tail")) (EApp (EVar "deferPure") (ETuple (EVar "labels") (EVar "tail"))))))))
(DFunDef false "effectBodyFor" ((PCon "TIdent" PWild)) (EApp (EApp (EVar "deferThen") (EVar "identNameP")) (ELam ((PVar "v")) (EApp (EApp (EVar "deferThen") (EVar "pipeTail")) (ELam ((PVar "rest")) (EApp (EVar "deferPure") (ETuple (EListLit) (EBinOp "::" (EVar "v") (EVar "rest")))))))))
(DFunDef false "effectBodyFor" (PWild) (EApp (EVar "deferPure") (ETuple (EListLit) (EListLit))))
(DTypeSig false "effAtomP" (TyApp (TyCon "Parser") (TyCon "EffAtomTy")))
(DFunDef false "effAtomP" () (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "upperNameP")) (ELam ((PVar "l")) (EApp (EApp (EVar "deferThen") (EVar "effParamP")) (ELam ((PVar "p")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "effAtomAt") (EVar "l")) (EVar "p")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q")))))))))))))))
(DTypeSig false "effParamP" (TyApp (TyCon "Parser") (TyCon "EffParamTy")))
(DFunDef false "effParamP" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EVar "effParamDispatch") (EVar "t")) (EVar "t2")))))))
(DTypeSig false "effParamDispatch" (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "EffParamTy")))))
(DFunDef false "effParamDispatch" ((PCon "TUpper" PWild) (PCon "TEqual")) (EApp (EVar "productParamP") (EVar "True")))
(DFunDef false "effParamDispatch" ((PVar "t") PWild) (EApp (EVar "effParamFor") (EVar "t")))
(DTypeSig false "productParamP" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "EffParamTy"))))
(DFunDef false "productParamP" ((PVar "named")) (EApp (EApp (EVar "deferThen") (EApp (EVar "productAxes") (EVar "named"))) (ELam ((PVar "axes")) (EApp (EVar "deferPure") (EApp (EVar "EPProduct") (EVar "axes"))))))
(DTypeSig false "productAxes" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))))))
(DFunDef false "productAxes" ((PVar "named")) (EApp (EApp (EVar "deferThen") (EApp (EVar "productAxis") (EVar "named"))) (ELam ((PVar "a")) (EApp (EApp (EVar "deferThen") (EApp (EVar "productAxesMore") (EVar "named"))) (ELam ((PVar "rest")) (EApp (EVar "deferPure") (EBinOp "::" (EVar "a") (EVar "rest"))))))))
(DTypeSig false "productAxesMore" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))))))
(DFunDef false "productAxesMore" ((PVar "named")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EApp (EVar "productAxesMoreFor") (EVar "named")) (EVar "t")) (EVar "t2")))))))
(DTypeSig false "productAxesMoreFor" (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))))))))
(DFunDef false "productAxesMoreFor" ((PVar "named") (PCon "TUpper" PWild) (PCon "TEqual")) (EApp (EVar "productAxes") (EVar "named")))
(DFunDef false "productAxesMoreFor" (PWild PWild PWild) (EApp (EVar "deferPure") (EListLit)))
(DTypeSig false "productAxis" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyCon "EffParamTy")))))
(DFunDef false "productAxis" ((PVar "named")) (EApp (EApp (EVar "deferThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "productAxisVal") (EVar "named"))) (ELam ((PVar "v")) (EApp (EVar "deferPure") (ETuple (EVar "name") (EVar "v"))))))))))
(DTypeSig false "productAxisVal" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "EffParamTy"))))
(DFunDef false "productAxisVal" ((PVar "named")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "productAxisValFor") (EVar "named")) (EVar "t")))))
(DTypeSig false "productAxisValFor" (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "EffParamTy")))))
(DFunDef false "productAxisValFor" (PWild (PCon "TString" (PVar "s"))) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EVar "EPLit") (EVar "s"))))))
(DFunDef false "productAxisValFor" (PWild (PCon "TLBrace")) (EVar "effSetLiteralP"))
(DFunDef false "productAxisValFor" ((PCon "True") (PCon "TIdent" (PVar "n"))) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EVar "EPName") (EVar "n"))))))
(DFunDef false "productAxisValFor" ((PCon "True") PWild) (EApp (EVar "failP") (ELit (LString "expected an axis value: a `\"prefix\"`, a `{set}` or an argument name"))))
(DFunDef false "productAxisValFor" ((PCon "False") (PCon "TIdent" PWild)) (EApp (EVar "failP") (ELit (LString "an axis of an authority term takes a `\"prefix\"` or a `{set}`; an argument name is allowed only in an effect row"))))
(DFunDef false "productAxisValFor" ((PCon "False") PWild) (EApp (EVar "failP") (ELit (LString "expected an axis value: a `\"prefix\"` or a `{set}`"))))
(DTypeSig false "effParamFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "EffParamTy"))))
(DFunDef false "effParamFor" ((PCon "TString" (PVar "s"))) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "pos")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EIf (EBinOp "==" (EVar "s") (ELit (LString "_"))) (EApp (EApp (EVar "fatalAtP") (EVar "effHoleRetiredMsg")) (EVar "pos")) (EApp (EVar "deferPure") (EApp (EVar "EPLit") (EVar "s")))))))))
(DFunDef false "effParamFor" ((PCon "TUnderscore")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "pos")) (EApp (EApp (EVar "fatalAtP") (EVar "effHoleRetiredMsg")) (EVar "pos")))))
(DFunDef false "effParamFor" ((PCon "TIdent" (PVar "n"))) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EVar "EPName") (EVar "n"))))))
(DFunDef false "effParamFor" ((PCon "TLBrace")) (EVar "effSetLiteralP"))
(DFunDef false "effParamFor" (PWild) (EApp (EVar "deferPure") (EVar "EPTop")))
(DTypeSig false "effSetLiteralP" (TyApp (TyCon "Parser") (TyCon "EffParamTy")))
(DFunDef false "effSetLiteralP" () (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TLBrace"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "stringLitP")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "elems")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EVar "EPSet") (EVar "elems"))))))))))
(DTypeSig false "effHoleRetiredMsg" (TyCon "String"))
(DFunDef false "effHoleRetiredMsg" () (ELit (LString "the `_` effect parameter is not accepted; write the bare label `<FileRead>` for any authority, or name the argument that determines it, `<FileRead path>`")))
(DTypeSig false "pipeTail" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "pipeTail" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "pipeTailFor") (EVar "t")))))
(DTypeSig false "pipeTailFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "pipeTailFor" ((PCon "TPipe")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "identNameP")) (ELam ((PVar "v")) (EApp (EApp (EVar "deferThen") (EVar "pipeTail")) (ELam ((PVar "rest")) (EApp (EVar "deferPure") (EBinOp "::" (EVar "v") (EVar "rest"))))))))))
(DFunDef false "pipeTailFor" (PWild) (EApp (EVar "deferPure") (EListLit)))
(DTypeSig false "upperNameP" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "upperNameP" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "upperNameFor") (EVar "t")))))
(DTypeSig false "upperNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "upperNameFor" ((PCon "TUpper" (PVar "c"))) (EApp (EVar "emit") (EVar "c")))
(DFunDef false "upperNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected an effect label"))))
(DTypeSig false "upperQualTail" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "upperQualTail" ((PVar "head")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EApp (EVar "upperQualFor") (EVar "head")) (EVar "t")) (EVar "t2")))))))
(DTypeSig false "upperQualFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))))
(DFunDef false "upperQualFor" ((PVar "head") (PCon "TDot") (PCon "TUpper" (PVar "n"))) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EVar "qualifiedLocal") (EVar "head")) (EVar "n"))))))))
(DFunDef false "upperQualFor" ((PVar "head") PWild PWild) (EApp (EVar "deferPure") (EVar "head")))
(DTypeSig false "tyArrowTail" (TyFun (TyCon "Ty") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "tyArrowTail" ((PVar "left")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TArrow"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EApp (EVar "tyArrowSkipLayout") (EVar "t"))) (ELam ((PVar "indented")) (EApp (EApp (EVar "deferThen") (EVar "parseTy")) (ELam ((PVar "right")) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "deferWhen") (EVar "indented")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "expectTok") (EVar "TDedent")))))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EVar "TyFun") (EVar "left")) (EVar "right"))))))))))))))
(DTypeSig false "tyArrowSkipLayout" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Bool"))))
(DFunDef false "tyArrowSkipLayout" ((PCon "TNewline")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "deferPure") (EVar "False")))))
(DFunDef false "tyArrowSkipLayout" ((PCon "TIndent")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "deferPure") (EVar "True")))))
(DFunDef false "tyArrowSkipLayout" (PWild) (EApp (EVar "deferPure") (EVar "False")))
(DTypeSig false "parseTyApp" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyApp" () (EApp (EApp (EVar "deferThen") (EVar "parseTyAtom")) (ELam ((PVar "head")) (EApp (EApp (EVar "deferThen") (EApp (EVar "many") (EVar "parseTyAtom"))) (ELam ((PVar "args")) (EApp (EVar "tyQualTail") (EApp (EApp (EVar "tyApplyAll") (EVar "head")) (EVar "args"))))))))
(DTypeSig false "tyQualTail" (TyFun (TyCon "Ty") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "tyQualTail" ((PVar "ty")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EApp (EVar "tyQualTailFor") (EVar "ty")) (EVar "t")) (EVar "t2")))))))
(DTypeSig false "tyQualTailFor" (TyFun (TyCon "Ty") (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Ty"))))))
(DFunDef false "tyQualTailFor" ((PVar "ty") (PCon "TAt") (PCon "TIdent" (PVar "n"))) (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EVar "tyQualDone") (EApp (EApp (EApp (EVar "TyQual") (EVar "ty")) (EListLit (EApp (EVar "EPName") (EVar "n")))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))))))))))))))))
(DFunDef false "tyQualTailFor" ((PVar "ty") (PCon "TAt") (PCon "TString" PWild)) (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "authTermP")) (ELam ((PVar "p")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EVar "tyQualDone") (EApp (EApp (EApp (EVar "TyQual") (EVar "ty")) (EListLit (EVar "p"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))))))))))))))))
(DFunDef false "tyQualTailFor" ((PVar "ty") (PCon "TAt") (PCon "TLParen")) (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "authTermP")) (ELam ((PVar "first")) (EApp (EApp (EVar "deferThen") (EVar "authJoinTail")) (ELam ((PVar "rest")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EVar "tyQualDone") (EApp (EApp (EApp (EVar "TyQual") (EVar "ty")) (EBinOp "::" (EVar "first") (EVar "rest"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))))))))))))))))))))))
(DFunDef false "tyQualTailFor" (PWild (PCon "TAsAt") (PCon "TIdent" (PVar "n"))) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "pos")) (EApp (EApp (EVar "fatalAtP") (EBinOp "++" (EBinOp "++" (ELit (LString "an authority qualifier needs a space before `@`; write `String @")) (EApp (EVar "display") (EVar "n"))) (ELit (LString "`")))) (EVar "pos")))))
(DFunDef false "tyQualTailFor" (PWild (PCon "TAsAt") (PCon "TString" (PVar "s"))) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "pos")) (EApp (EApp (EVar "fatalAtP") (EBinOp "++" (EBinOp "++" (ELit (LString "an authority qualifier needs a space before `@`; write `String @\"")) (EApp (EVar "display") (EVar "s"))) (ELit (LString "\"`")))) (EVar "pos")))))
(DFunDef false "tyQualTailFor" (PWild (PCon "TAsAt") (PCon "TLParen")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "pos")) (EApp (EApp (EVar "fatalAtP") (ELit (LString "an authority qualifier needs a space before `@`; write `String @(...)`"))) (EVar "pos")))))
(DFunDef false "tyQualTailFor" ((PVar "ty") PWild PWild) (EApp (EVar "deferPure") (EVar "ty")))
(DTypeSig false "tyQualDone" (TyFun (TyCon "Ty") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "tyQualDone" ((PVar "ty")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "tyQualDoneFor") (EVar "ty")) (EVar "t")))))
(DTypeSig false "tyQualDoneFor" (TyFun (TyCon "Ty") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Ty")))))
(DFunDef false "tyQualDoneFor" (PWild (PCon "TAt")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "pos")) (EApp (EApp (EVar "fatalAtP") (ELit (LString "a type takes one authority qualifier"))) (EVar "pos")))))
(DFunDef false "tyQualDoneFor" ((PVar "ty") PWild) (EApp (EVar "deferPure") (EVar "ty")))
(DTypeSig false "authTermP" (TyApp (TyCon "Parser") (TyCon "EffParamTy")))
(DFunDef false "authTermP" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EVar "authTermFor") (EVar "t")) (EVar "t2")))))))
(DTypeSig false "authTermFor" (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "EffParamTy")))))
(DFunDef false "authTermFor" ((PCon "TUpper" PWild) (PCon "TEqual")) (EApp (EVar "productParamP") (EVar "False")))
(DFunDef false "authTermFor" ((PAs "t" (PCon "TString" PWild)) PWild) (EApp (EVar "effParamFor") (EVar "t")))
(DFunDef false "authTermFor" ((PAs "t" (PCon "TIdent" PWild)) PWild) (EApp (EVar "effParamFor") (EVar "t")))
(DFunDef false "authTermFor" ((PCon "TLBrace") PWild) (EVar "effSetLiteralP"))
(DFunDef false "authTermFor" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected an authority term: a name, a `\"pattern\"`, a `{set}` or `Axis=...` axes"))))
(DTypeSig false "authJoinTail" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "EffParamTy"))))
(DFunDef false "authJoinTail" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "authJoinTailFor") (EVar "t")))))
(DTypeSig false "authJoinTailFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "EffParamTy")))))
(DFunDef false "authJoinTailFor" ((PCon "TPipe")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "authTermP")) (ELam ((PVar "p")) (EApp (EApp (EVar "deferThen") (EVar "authJoinTail")) (ELam ((PVar "rest")) (EApp (EVar "deferPure") (EBinOp "::" (EVar "p") (EVar "rest"))))))))))
(DFunDef false "authJoinTailFor" (PWild) (EApp (EVar "deferPure") (EListLit)))
(DTypeSig false "tyApplyAll" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Ty"))))
(DFunDef false "tyApplyAll" ((PVar "head") (PList)) (EVar "head"))
(DFunDef false "tyApplyAll" ((PVar "head") (PCons (PVar "a") (PVar "rest"))) (EApp (EApp (EVar "tyApplyAll") (EApp (EApp (EVar "TyApp") (EVar "head")) (EVar "a"))) (EVar "rest")))
(DTypeSig false "parseTyAtom" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyAtom" () (EApp (EApp (EApp (EVar "withDepth") (EVar "maxNestDepth")) (EApp (EVar "FailMsg") (EVar "nestTooDeepMsg"))) (EVar "parseTyAtomRaw")))
(DTypeSig false "parseTyAtomRaw" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyAtomRaw" () (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TUpper" (PVar "c")) () (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "tyConQualTail") (EVar "c"))) (ELam ((PVar "n")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EVar "deferPure") (EApp (EApp (EVar "tyConUnresolved") (EVar "n")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q")))))))))))))) (arm (PCon "TIdent" (PVar "v")) () (EApp (EVar "emit") (EApp (EVar "TyVar") (EVar "v")))) (arm (PCon "TLParen") () (EVar "parseTyParen")) (arm (PCon "TLt") () (EVar "parseBareEffectAtom")) (arm (PCon "TStar") () (EVar "parseTyAuthTop")) (arm (PCon "TString" PWild) () (EVar "parseTyAuthLit")) (arm (PCon "TLBrace") () (EVar "parseTyAuthLit")) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected a type"))))))))))
(DTypeSig false "parseTyAuthTop" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyAuthTop" () (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TStar"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EVar "deferPure") (EApp (EApp (EVar "TyAuth") (EListLit (EVar "EPTop"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))))))))))))))
(DTypeSig false "parseTyAuthLit" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyAuthLit" () (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "effParamP")) (ELam ((PVar "p")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EVar "deferPure") (EApp (EApp (EVar "TyAuth") (EListLit (EVar "p"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))))))))))))))
(DTypeSig false "parseTyAuthJoin" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "parseTyAuthJoin" ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "authTermP")) (ELam ((PVar "first")) (EApp (EApp (EVar "deferThen") (EVar "authJoinTail")) (ELam ((PVar "rest")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EVar "deferPure") (EApp (EApp (EVar "TyAuth") (EBinOp "::" (EVar "first") (EVar "rest"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))))))))))))))))
(DTypeSig false "tyConQualTail" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "tyConQualTail" ((PVar "head")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EApp (EVar "tyConQualFor") (EVar "head")) (EVar "t")) (EVar "t2")))))))
(DTypeSig false "tyConQualFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))))
(DFunDef false "tyConQualFor" ((PVar "head") (PCon "TDot") (PCon "TUpper" (PVar "n"))) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EVar "qualifiedLocal") (EVar "head")) (EVar "n"))))))))
(DFunDef false "tyConQualFor" ((PVar "head") PWild PWild) (EApp (EVar "deferPure") (EVar "head")))
(DTypeSig false "parseBareEffectAtom" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseBareEffectAtom" () (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TLt"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "effectBody")) (ELam ((PVar "body")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TGt"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EVar "deferPure") (EApp (EApp (EVar "mkRow") (EVar "body")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q")))))))))))))))))
(DTypeSig false "mkRow" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "Loc") (TyCon "Ty"))))
(DFunDef false "mkRow" ((PTuple (PVar "labels") (PVar "tail")) (PVar "loc")) (EApp (EApp (EApp (EVar "TyRow") (EVar "labels")) (EVar "tail")) (EApp (EVar "Some") (EVar "loc"))))
(DTypeSig false "tyTupleOrSingle" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Ty")))
(DFunDef false "tyTupleOrSingle" ((PList (PVar "t"))) (EVar "t"))
(DFunDef false "tyTupleOrSingle" ((PVar "ts")) (EApp (EVar "TyTuple") (EVar "ts")))
(DTypeSig false "parseTyParen" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyParen" () (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TLParen"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EApp (EVar "parseTyParenAt") (EVar "s")) (EVar "t")) (EVar "t2")))))))))))
(DTypeSig false "parseTyParenAt" (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Ty"))))))
(DFunDef false "parseTyParenAt" ((PVar "s") (PCon "TString" PWild) PWild) (EApp (EVar "parseTyAuthJoin") (EVar "s")))
(DFunDef false "parseTyParenAt" ((PVar "s") (PCon "TLBrace") PWild) (EApp (EVar "parseTyAuthJoin") (EVar "s")))
(DFunDef false "parseTyParenAt" ((PVar "s") (PCon "TUpper" PWild) (PCon "TEqual")) (EApp (EVar "parseTyAuthJoin") (EVar "s")))
(DFunDef false "parseTyParenAt" (PWild (PVar "t") PWild) (EApp (EVar "parseTyParenBody") (EVar "t")))
(DTypeSig false "parseTyParenBody" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "parseTyParenBody" ((PCon "TComma")) (EApp (EVar "parseTupleCtorTail") (ELit (LInt 0))))
(DFunDef false "parseTyParenBody" ((PCon "TIdent" PWild)) (EApp (EApp (EVar "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EVar "parseTyParenIdent") (EVar "t2")))))
(DFunDef false "parseTyParenBody" (PWild) (EVar "parseTyParenTuple"))
(DTypeSig false "parseTyParenIdent" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "parseTyParenIdent" ((PCon "TColon")) (EApp (EApp (EVar "deferThen") (EVar "identNameP")) (ELam ((PVar "n")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseTy")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t1")) (EApp (EApp (EVar "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "binderDomainP") (EVar "t1")) (EVar "t2"))) (ELam ((PVar "d")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "TyNamed") (EVar "n")) (EVar "t")) (EVar "d"))))))))))))))))))
(DFunDef false "parseTyParenIdent" ((PCon "TPipe")) (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "identNameP")) (ELam ((PVar "v")) (EApp (EApp (EVar "deferThen") (EVar "authJoinTail")) (ELam ((PVar "rest")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "namesOrAuthJoin") (EVar "v")) (EVar "rest")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))))))))))))))))))
(DFunDef false "parseTyParenIdent" (PWild) (EVar "parseTyParenTuple"))
(DTypeSig false "binderDomainP" (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "Option") (TyCon "EffAtomTy"))))))
(DFunDef false "binderDomainP" ((PCon "TAt") (PCon "TUpper" PWild)) (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "upperNameP")) (ELam ((PVar "l")) (EApp (EApp (EVar "deferThen") (EVar "patternMarkP")) (ELam ((PVar "pat")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (ELet false (PVar "atom") (EApp (EApp (EApp (EVar "effAtomAt") (EVar "l")) (EVar "EPTop")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))) (EApp (EVar "deferPure") (EApp (EVar "Some") (EVariantUpdate "EffAtomTy" (EVar "atom") ((fa "eatPattern" (EVar "pat"))))))))))))))))))))
(DFunDef false "binderDomainP" ((PCon "TAsAt") (PCon "TUpper" (PVar "l"))) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "pos")) (EApp (EApp (EVar "fatalAtP") (EBinOp "++" (EBinOp "++" (ELit (LString "a binder's domain needs a space before `@`; write `String @")) (EApp (EVar "display") (EVar "l"))) (ELit (LString "`")))) (EVar "pos")))))
(DFunDef false "binderDomainP" (PWild PWild) (EApp (EVar "deferPure") (EVar "None")))
(DTypeSig false "namesOrAuthJoin" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "EffParamTy")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Ty")))))
(DFunDef false "namesOrAuthJoin" ((PVar "v") (PVar "rest") (PVar "loc")) (EMatch (EApp (EApp (EVar "allNames") (EVar "rest")) (EListLit)) (arm (PCon "Some" (PVar "names")) () (EApp (EApp (EApp (EVar "TyRow") (EListLit)) (EBinOp "::" (EVar "v") (EVar "names"))) (EVar "loc"))) (arm (PCon "None") () (EApp (EApp (EVar "TyAuth") (EBinOp "::" (EApp (EVar "EPName") (EVar "v")) (EVar "rest"))) (EVar "loc")))))
(DTypeSig false "allNames" (TyFun (TyApp (TyCon "List") (TyCon "EffParamTy")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "allNames" ((PList) (PVar "acc")) (EApp (EVar "Some") (EApp (EVar "reverseL") (EVar "acc"))))
(DFunDef false "allNames" ((PCons (PCon "EPName" (PVar "n")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "allNames") (EVar "rest")) (EBinOp "::" (EVar "n") (EVar "acc"))))
(DFunDef false "allNames" (PWild PWild) (EVar "None"))
(DTypeSig false "parseTyParenTuple" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyParenTuple" () (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "parseTy")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "ts")) (EApp (EApp (EVar "deferThen") (EApp (EVar "optTrailingCommaTuple") (EVar "ts"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EVar "tyTupleOrSingle") (EVar "ts"))))))))))
(DTypeSig false "parseTupleCtorTail" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "parseTupleCtorTail" ((PVar "commas")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "tupleCtorTailFor") (EVar "commas")) (EVar "t")))))
(DTypeSig false "tupleCtorTailFor" (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Ty")))))
(DFunDef false "tupleCtorTailFor" ((PVar "commas") (PCon "TComma")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "parseTupleCtorTail") (EBinOp "+" (EVar "commas") (ELit (LInt 1)))))))
(DFunDef false "tupleCtorTailFor" ((PVar "commas") (PCon "TRParen")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "tupleCtorTyOfArity") (EBinOp "+" (EVar "commas") (ELit (LInt 1)))))))
(DFunDef false "tupleCtorTailFor" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected `,` or `)` in the tuple type constructor"))))
(DTypeSig false "tupleCtorTyOfArity" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "tupleCtorTyOfArity" ((PVar "n")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "<=" (EVar "n") (ELit (LInt 5)))) (EApp (EVar "deferPure") (EApp (EApp (EVar "tyConBuiltin") (EApp (EVar "tupleCtorTyName") (EVar "n"))) (EVar "None"))) (EApp (EVar "failP") (ELit (LString "a tuple type constructor has 2 to 5 components")))))
(DTypeSig false "tupleCtorTyName" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "tupleCtorTyName" ((PLit (LInt 2))) (ELit (LString "__tuple2__")))
(DFunDef false "tupleCtorTyName" ((PLit (LInt 3))) (ELit (LString "__tuple3__")))
(DFunDef false "tupleCtorTyName" ((PLit (LInt 4))) (ELit (LString "__tuple4__")))
(DFunDef false "tupleCtorTyName" ((PLit (LInt 5))) (ELit (LString "__tuple5__")))
(DFunDef false "tupleCtorTyName" (PWild) (ELit (LString "__tuple0__")))
(DTypeSig false "parseDecl" (TyApp (TyCon "Parser") (TyCon "Decl")))
(DFunDef false "parseDecl" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TImport") () (EApp (EVar "parseImport") (EVar "False"))) (arm (PCon "TExport") () (EVar "afterExport")) (arm (PCon "TPublic") () (EVar "afterPublic")) (arm (PCon "TData") () (EApp (EVar "parseData") (EVar "VisPrivate"))) (arm (PCon "TExtern") () (EApp (EVar "parseExtern") (EVar "False"))) (arm (PCon "TProp") () (EApp (EVar "parseProp") (EVar "False"))) (arm (PCon "TTest") () (EApp (EVar "parseTest") (EVar "False"))) (arm (PCon "TBench") () (EApp (EVar "parseBench") (EVar "False"))) (arm (PCon "TEffect") () (EApp (EVar "parseEffect") (EVar "False"))) (arm (PCon "TInterface") () (EApp (EApp (EVar "parseInterface") (EVar "False")) (EVar "False"))) (arm (PCon "TImpl") () (EApp (EVar "parseImpl") (EVar "False"))) (arm (PCon "TDefault") () (EApp (EVar "afterDefault") (EVar "False"))) (arm (PCon "TType") () (EApp (EVar "parseTypeAlias") (EVar "False"))) (arm (PCon "TNewtype") () (EApp (EVar "parseNewtype") (EVar "False"))) (arm (PCon "TLet") () (EApp (EVar "parseLetGroupDecl") (EVar "False"))) (arm (PCon "TAt") () (EVar "parseAttrib")) (arm PWild () (EApp (EVar "parseFunOrSig") (EVar "False")))))))
(DTypeSig false "afterDefault" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "afterDefault" ((PVar "pub")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TDefault"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "afterDefaultFor") (EVar "pub")) (EVar "t")))))))))
(DTypeSig false "afterDefaultFor" (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Decl")))))
(DFunDef false "afterDefaultFor" ((PVar "pub") (PCon "TInterface")) (EApp (EApp (EVar "parseInterface") (EVar "pub")) (EVar "True")))
(DFunDef false "afterDefaultFor" (PWild (PCon "TImpl")) (EApp (EVar "failP") (EVar "defaultImplRemovedMsg")))
(DFunDef false "afterDefaultFor" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected an interface after `default`"))))
(DTypeSig false "afterExport" (TyApp (TyCon "Parser") (TyCon "Decl")))
(DFunDef false "afterExport" () (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TExport"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TImport") () (EApp (EVar "parseImport") (EVar "True"))) (arm (PCon "TData") () (EApp (EVar "parseData") (EVar "VisAbstract"))) (arm (PCon "TExtern") () (EApp (EVar "parseExtern") (EVar "True"))) (arm (PCon "TProp") () (EApp (EVar "parseProp") (EVar "True"))) (arm (PCon "TTest") () (EApp (EVar "parseTest") (EVar "True"))) (arm (PCon "TBench") () (EApp (EVar "parseBench") (EVar "True"))) (arm (PCon "TEffect") () (EApp (EVar "parseEffect") (EVar "True"))) (arm (PCon "TInterface") () (EApp (EApp (EVar "parseInterface") (EVar "True")) (EVar "False"))) (arm (PCon "TImpl") () (EApp (EVar "parseImpl") (EVar "True"))) (arm (PCon "TDefault") () (EApp (EVar "afterDefault") (EVar "True"))) (arm (PCon "TType") () (EApp (EVar "parseTypeAlias") (EVar "True"))) (arm (PCon "TNewtype") () (EApp (EVar "parseNewtype") (EVar "True"))) (arm (PCon "TLet") () (EApp (EVar "parseLetGroupDecl") (EVar "True"))) (arm PWild () (EApp (EVar "parseFunOrSig") (EVar "True")))))))))))
(DTypeSig false "afterPublic" (TyApp (TyCon "Parser") (TyCon "Decl")))
(DFunDef false "afterPublic" () (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "pubPos")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TPublic"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TExport"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "afterPublicFor") (EVar "pubPos")) (EVar "t")))))))))))))))
(DTypeSig false "afterPublicFor" (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Decl")))))
(DFunDef false "afterPublicFor" (PWild (PCon "TData")) (EApp (EVar "parseData") (EVar "VisPublic")))
(DFunDef false "afterPublicFor" ((PVar "pubPos") (PCon "TExtern")) (EApp (EApp (EVar "fatalProblemAtP") (EApp (EVar "PublicDataOnly") (EVar "True"))) (EVar "pubPos")))
(DFunDef false "afterPublicFor" ((PVar "pubPos") PWild) (EApp (EApp (EVar "fatalProblemAtP") (EApp (EVar "PublicDataOnly") (EVar "False"))) (EVar "pubPos")))
(DTypeSig false "parseFunOrSig" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseFunOrSig" ((PVar "pub")) (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (ELet false (PVar "site") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EBinOp "+" (EVar "s") (ELit (LInt 1)))) (EApp (EApp (EVar "deferThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "params")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TColon") () (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EVar "DTypeSig") (EVar "pub")) (EVar "name")) (EVar "ty")) (EVar "site")))))))))) (arm (PCon "TEqual") () (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "name")) (EVar "params")) (EVar "body")) (EVar "site")) (EVar "noBinderId")))))))))) (arm (PCon "TIndent") () (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseGuardArms")) (ELam ((PVar "arms")) (EApp (EApp (EVar "deferThen") (EApp (EVar "guardArmsWhereOpt") (EVar "arms"))) (ELam ((PVar "body")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "name")) (EVar "params")) (EVar "body")) (EVar "site")) (EVar "noBinderId")))))))))))))) (arm (PCon "TPipe") () (EApp (EApp (EVar "deferThen") (EVar "parseGuardArm")) (ELam ((PVar "arm")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "name")) (EVar "params")) (EApp (EVar "EGuards") (EListLit (EVar "arm")))) (EVar "site")) (EVar "noBinderId")))))))) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected `:` or `=` after the definition head")))))))))))))))))
(DTypeSig false "parseExtern" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseExtern" ((PVar "pub")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TExtern"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "parseExternFor") (EVar "pub")) (EVar "t")))))))
(DTypeSig false "parseExternFor" (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Decl")))))
(DFunDef false "parseExternFor" ((PVar "pub") (PCon "TData")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TData"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "locatedUpperNameP")) (ELam ((PVar "named")) (ELet false (PVar "name") (EApp (EVar "fst") (EVar "named")) (ELet false (PVar "nameLoc") (EApp (EVar "snd") (EVar "named")) (EApp (EApp (EVar "deferThen") (EVar "tyParamsP")) (ELam ((PVar "ps")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EApp (EApp (EApp (EApp (EVar "externDataEnd") (EVar "pub")) (EVar "name")) (EVar "ps")) (EVar "t"))) (ELam ((PVar "d")) (EApp (EVar "deferPure") (EApp (EApp (EVar "setDeclNameLoc") (EVar "nameLoc")) (EVar "d"))))))))))))))))
(DFunDef false "parseExternFor" ((PVar "pub") PWild) (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "externName")) (ELam ((PVar "name")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "e")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EVar "peek2P")) (ELam ((PVar "u")) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "externBindsFor") (EVar "t")) (EVar "u"))) (ELam ((PVar "binds")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EVar "DExtern") (ERecordCreate "ExternDecl" ((fa "edPub" (EVar "pub")) (fa "edName" (EVar "name")) (fa "edTy" (EVar "ty")) (fa "edLoc" (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "e"))) (fa "edBinds" (EVar "binds")))))))))))))))))))))))))))
(DTypeSig false "externBindsFor" (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ExternBind"))))))
(DFunDef false "externBindsFor" ((PCon "TIndent") (PCon "TIdent" (PLit (LString "bind")))) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "externBindLines")) (ELam ((PVar "binds")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EVar "deferPure") (EVar "binds")))))))))
(DFunDef false "externBindsFor" (PWild PWild) (EApp (EVar "deferPure") (EListLit)))
(DTypeSig false "externBindLines" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ExternBind"))))
(DFunDef false "externBindLines" () (EApp (EApp (EVar "deferThen") (EVar "externBindP")) (ELam ((PVar "b")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EIf (EBinOp "==" (EVar "t") (EVar "TDedent")) (EApp (EVar "deferPure") (EListLit)) (EVar "externBindLines"))) (ELam ((PVar "rest")) (EApp (EVar "deferPure") (EBinOp "::" (EVar "b") (EVar "rest"))))))))))))
(DTypeSig false "externBindP" (TyApp (TyCon "Parser") (TyCon "ExternBind")))
(DFunDef false "externBindP" () (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EIf (EBinOp "==" (EVar "t") (EApp (EVar "TIdent") (ELit (LString "bind")))) (EVar "advance") (EApp (EVar "failP") (ELit (LString "expected `bind`"))))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "h")) (EApp (EApp (EVar "deferThen") (EApp (EVar "bindHostFor") (EVar "h"))) (ELam ((PVar "host")) (EApp (EApp (EVar "deferThen") (EVar "stringLitP")) (ELam ((PVar "symbol")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "e")) (EApp (EVar "deferPure") (ERecordCreate "ExternBind" ((fa "ebHost" (EVar "host")) (fa "ebSymbol" (EVar "symbol")) (fa "ebLoc" (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "e")))))))))))))))))))))))
(DTypeSig false "bindHostFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "bindHostFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "bindHostFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected a host after `bind`, such as `c` or `js`"))))
(DTypeSig false "externDataEnd" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "KindAnn")))) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Decl")))))))
(DFunDef false "externDataEnd" (PWild PWild PWild (PCon "TEqual")) (EApp (EVar "failP") (ELit (LString "an `extern data` type has no constructors; drop the `= ...`"))))
(DFunDef false "externDataEnd" (PWild PWild PWild (PCon "TDeriving")) (EApp (EVar "failP") (ELit (LString "an `extern data` type has no constructors to derive from; drop the `deriving` clause"))))
(DFunDef false "externDataEnd" ((PVar "pub") (PVar "name") (PVar "ps") PWild) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EVar "externDataUnresolved") (EVar "pub")) (EVar "name")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "ps"))) (EApp (EApp (EVar "map") (EVar "snd")) (EVar "ps")))))))
(DTypeSig false "locatedUpperNameP" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyCon "Loc"))))
(DFunDef false "locatedUpperNameP" () (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EVar "deferPure") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q")))))))))))))
(DTypeSig false "parseTypeAlias" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseTypeAlias" ((PVar "pub")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TType"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "locatedUpperNameP")) (ELam ((PVar "named")) (ELet false (PVar "name") (EApp (EVar "fst") (EVar "named")) (ELet false (PVar "nameLoc") (EApp (EVar "snd") (EVar "named")) (EApp (EApp (EVar "deferThen") (EVar "tyParamsP")) (ELam ((PVar "ps")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EVar "setDeclNameLoc") (EVar "nameLoc")) (EApp (EApp (EApp (EApp (EApp (EVar "dTypeAliasUnresolved") (EVar "pub")) (EVar "name")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "ps"))) (EApp (EApp (EVar "map") (EVar "snd")) (EVar "ps"))) (EVar "ty")))))))))))))))))))
(DTypeSig false "parseNewtype" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseNewtype" ((PVar "pub")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TNewtype"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "locatedUpperNameP")) (ELam ((PVar "named")) (ELet false (PVar "name") (EApp (EVar "fst") (EVar "named")) (ELet false (PVar "nameLoc") (EApp (EVar "snd") (EVar "named")) (EApp (EApp (EVar "deferThen") (EVar "tyParamsP")) (ELam ((PVar "ps")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "upperNameP")) (ELam ((PVar "con")) (EApp (EApp (EVar "deferThen") (EVar "ctorBindersP")) (ELam ((PVar "binders")) (EApp (EApp (EVar "deferThen") (EVar "parseTy")) (ELam ((PVar "fty")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EApp (EVar "newtypeDerives") (EVar "t"))) (ELam ((PVar "derives")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EVar "setDeclNameLoc") (EVar "nameLoc")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dNewtypeUnresolved") (EVar "pub")) (EVar "name")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "ps"))) (EApp (EApp (EVar "map") (EVar "snd")) (EVar "ps"))) (EVar "con")) (EVar "binders")) (EVar "fty")) (EVar "derives")))))))))))))))))))))))))))
(DTypeSig false "parseLetGroupDecl" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseLetGroupDecl" ((PVar "pub")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TLet"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRec"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "letRecDeclClause")) (ELam ((PVar "c")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EVar "coalesceClauses") (EListLit (EVar "c"))))))))))))))
(DTypeSig false "letRecDeclClause" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyCon "Loc"))))
(DFunDef false "letRecDeclClause" () (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "deferThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EVar "deferPure") (ETuple (EVar "name") (EVar "pats") (EVar "body") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EBinOp "+" (EVar "s") (ELit (LInt 1)))))))))))))))))))
(DTypeSig false "parseAttrib" (TyApp (TyCon "Parser") (TyCon "Decl")))
(DFunDef false "parseAttrib" () (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "atPos")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TAt"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EApp (EApp (EApp (EVar "attrArg") (EVar "atPos")) (EVar "name")) (EVar "t"))) (ELam ((PVar "attr")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseDecl")) (ELam ((PVar "inner")) (EApp (EVar "deferPure") (EApp (EApp (EVar "DAttrib") (EListLit (EVar "attr"))) (EVar "inner"))))))))))))))))))
(DTypeSig false "attrArg" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Attr"))))))
(DFunDef false "attrArg" ((PVar "atPos") (PVar "name") (PCon "TString" (PVar "msg"))) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EApp (EVar "mkAttr") (EVar "atPos")) (EVar "name")) (EApp (EVar "Some") (EVar "msg"))))))
(DFunDef false "attrArg" ((PVar "atPos") (PVar "name") PWild) (EApp (EApp (EApp (EVar "mkAttr") (EVar "atPos")) (EVar "name")) (EVar "None")))
(DTypeSig false "mkAttr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Parser") (TyCon "Attr"))))))
(DFunDef false "mkAttr" (PWild (PLit (LString "deprecated")) (PVar "msg")) (EApp (EVar "deferPure") (EApp (EVar "AttrDeprecated") (EVar "msg"))))
(DFunDef false "mkAttr" ((PVar "atPos") (PVar "name") (PVar "msg")) (EMatch (EApp (EVar "bareAttr") (EVar "name")) (arm (PCon "None") () (EApp (EApp (EVar "fatalAtP") (EBinOp "++" (EBinOp "++" (ELit (LString "unknown declaration attribute `@")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "`; the attributes are `@deprecated \"msg\"`, `@inline`, `@must_use` and `@noinline`")))) (EVar "atPos"))) (arm (PCon "Some" (PVar "attr")) () (EMatch (EVar "msg") (arm (PCon "None") () (EApp (EVar "deferPure") (EVar "attr"))) (arm (PCon "Some" PWild) () (EApp (EApp (EVar "fatalAtP") (EBinOp "++" (EBinOp "++" (ELit (LString "`@")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` takes no message")))) (EVar "atPos")))))))
(DTypeSig false "bareAttr" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Attr"))))
(DFunDef false "bareAttr" ((PLit (LString "inline"))) (EApp (EVar "Some") (EVar "AttrInline")))
(DFunDef false "bareAttr" ((PLit (LString "must_use"))) (EApp (EVar "Some") (EVar "AttrMustUse")))
(DFunDef false "bareAttr" ((PLit (LString "noinline"))) (EApp (EVar "Some") (EVar "AttrNoInline")))
(DFunDef false "bareAttr" (PWild) (EVar "None"))
(DTypeSig false "externName" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "externName" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "externNameFor") (EVar "t")))))
(DTypeSig false "externNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "externNameFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "externNameFor" ((PCon "TUpper" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "externNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected a name after `extern`"))))
(DTypeSig false "parseImport" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseImport" ((PVar "pub")) (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TImport"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "importQuals")) (ELam ((PVar "quals")) (EApp (EApp (EVar "deferThen") (EApp (EVar "importPathFor") (EVar "quals"))) (ELam ((PVar "path")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "e")) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "noExportedAlias") (EVar "pub")) (EVar "path"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "DUse") (EVar "pub")) (EVar "path")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "e")))))))))))))))))))))
(DTypeSig false "noExportedAlias" (TyFun (TyCon "Bool") (TyFun (TyCon "UsePath") (TyApp (TyCon "Parser") (TyCon "Unit")))))
(DFunDef false "noExportedAlias" ((PCon "True") (PCon "UseAlias" PWild (PVar "a"))) (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (ELit (LString "`export import ... as ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "` is not allowed; a module alias is file-local, so write `export import m` and let the importer choose its alias")))))
(DFunDef false "noExportedAlias" ((PCon "True") (PCon "UseGroup" PWild (PVar "members"))) (EApp (EVar "failIfAliasedMember") (EVar "members")))
(DFunDef false "noExportedAlias" (PWild PWild) (EApp (EVar "deferPure") (ELit LUnit)))
(DTypeSig false "failIfAliasedMember" (TyFun (TyApp (TyCon "List") (TyCon "UseMember")) (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "failIfAliasedMember" ((PList)) (EApp (EVar "deferPure") (ELit LUnit)))
(DFunDef false "failIfAliasedMember" ((PCons (PVar "m") (PVar "rest"))) (EMatch (EApp (EVar "useMemberAlias") (EVar "m")) (arm (PCon "Some" (PVar "a")) () (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`export import` cannot rename `")) (EApp (EVar "display") (EApp (EVar "useMemberOrigin") (EVar "m")))) (ELit (LString "` as `"))) (EApp (EVar "display") (EVar "a"))) (ELit (LString "`; re-export it under its own name, `export import m.{"))) (EApp (EVar "display") (EApp (EVar "useMemberOrigin") (EVar "m")))) (ELit (LString "}`"))))) (arm (PCon "None") () (EApp (EVar "failIfAliasedMember") (EVar "rest")))))
(DTypeSig false "importQuals" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "importQuals" () (EApp (EApp (EVar "deferThen") (EVar "importIdent")) (ELam ((PVar "first")) (EApp (EApp (EVar "deferThen") (EVar "importQualRest")) (ELam ((PVar "rest")) (EApp (EVar "deferPure") (EBinOp "::" (EVar "first") (EVar "rest"))))))))
(DTypeSig false "importQualRest" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "importQualRest" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "importQualRestFor") (EVar "t")))))
(DTypeSig false "importQualRestFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "importQualRestFor" ((PCon "TDot")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "importIdent")) (ELam ((PVar "x")) (EApp (EApp (EVar "deferThen") (EVar "importQualRest")) (ELam ((PVar "rest")) (EApp (EVar "deferPure") (EBinOp "::" (EVar "x") (EVar "rest"))))))))))
(DFunDef false "importQualRestFor" (PWild) (EApp (EVar "deferPure") (EListLit)))
(DTypeSig false "importIdent" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "importIdent" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "importIdentFor") (EVar "t")))))
(DTypeSig false "importIdentFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "importIdentFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "importIdentFor" ((PCon "TUpper" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "importIdentFor" ((PCon "TTest")) (EApp (EVar "emit") (ELit (LString "test"))))
(DFunDef false "importIdentFor" ((PCon "TData")) (EApp (EVar "emit") (ELit (LString "data"))))
(DFunDef false "importIdentFor" ((PCon "TType")) (EApp (EVar "emit") (ELit (LString "type"))))
(DFunDef false "importIdentFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected a module name in the import path"))))
(DTypeSig false "importPathFor" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Parser") (TyCon "UsePath"))))
(DFunDef false "importPathFor" ((PVar "quals")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "importPathForT") (EVar "quals")) (EVar "t")))))
(DTypeSig false "importPathForT" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "UsePath")))))
(DFunDef false "importPathForT" ((PVar "quals") (PCon "TDotLBrace")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "importMember")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "ms")) (EApp (EApp (EVar "deferThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "noTrailingAlias") (ELit (LString "a selective import")))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EVar "UseGroup") (EVar "quals")) (EVar "ms"))))))))))))))
(DFunDef false "importPathForT" ((PVar "quals") (PCon "TDotStar")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "noTrailingAlias") (ELit (LString "a wildcard import")))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EVar "UseWild") (EVar "quals"))))))))
(DFunDef false "importPathForT" ((PVar "quals") (PCon "TAs")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "aliasName")) (ELam ((PVar "a")) (EApp (EVar "deferPure") (EApp (EApp (EVar "UseAlias") (EVar "quals")) (EVar "a"))))))))
(DFunDef false "importPathForT" ((PVar "quals") PWild) (EApp (EVar "deferPure") (EApp (EVar "UseName") (EVar "quals"))))
(DTypeSig false "noTrailingAlias" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "noTrailingAlias" ((PVar "what")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "noTrailingAliasFor") (EVar "what")) (EVar "t")))))
(DTypeSig false "noTrailingAliasFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit")))))
(DFunDef false "noTrailingAliasFor" ((PVar "what") (PCon "TAs")) (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (ELit (LString "`as` cannot alias ")) (EApp (EVar "display") (EVar "what"))) (ELit (LString "; write `import m as A` to alias the whole module")))))
(DFunDef false "noTrailingAliasFor" (PWild PWild) (EApp (EVar "deferPure") (ELit LUnit)))
(DTypeSig false "importMember" (TyApp (TyCon "Parser") (TyCon "UseMember")))
(DFunDef false "importMember" () (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "importMemberFor") (EVar "s")) (EVar "t")))))))
(DTypeSig false "importMemberFor" (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "UseMember")))))
(DFunDef false "importMemberFor" ((PVar "s") (PCon "TIdent" (PVar "x"))) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EApp (EVar "memberAliasOrNot") (EVar "s")) (EVar "x")) (EVar "False")))))
(DFunDef false "importMemberFor" ((PVar "s") (PCon "TUpper" (PVar "x"))) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "withAllOrNot") (EVar "s")) (EVar "x")))))
(DFunDef false "importMemberFor" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected an imported name"))))
(DTypeSig false "withAllOrNot" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "UseMember")))))
(DFunDef false "withAllOrNot" ((PVar "s") (PVar "x")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "withAllFor") (EVar "s")) (EVar "x")) (EVar "t")))))
(DTypeSig false "withAllFor" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "UseMember"))))))
(DFunDef false "withAllFor" ((PVar "s") (PVar "x") (PCon "TLParen")) (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TDotDot"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EApp (EVar "deferThen") (EApp (EVar "noMemberAlias") (EVar "x"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "x")) (EVar "True")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))) (EVar "None"))))))))))))))))
(DFunDef false "withAllFor" ((PVar "s") (PVar "x") PWild) (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EApp (EVar "deferThen") (EApp (EVar "noMemberAlias") (EVar "x"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "x")) (EVar "False")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))) (EVar "None"))))))))))
(DTypeSig false "noMemberAlias" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "noMemberAlias" ((PVar "x")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "noMemberAliasFor") (EVar "x")) (EVar "t")))))
(DTypeSig false "noMemberAliasFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit")))))
(DFunDef false "noMemberAliasFor" ((PVar "x") (PCon "TAs")) (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "x"))) (ELit (LString "` is a type or constructor and cannot be aliased; import it under its own name")))))
(DFunDef false "noMemberAliasFor" (PWild PWild) (EApp (EVar "deferPure") (ELit LUnit)))
(DTypeSig false "memberAliasOrNot" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "UseMember"))))))
(DFunDef false "memberAliasOrNot" ((PVar "s") (PVar "x") (PVar "allCtors")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EApp (EVar "memberAliasFor") (EVar "s")) (EVar "x")) (EVar "allCtors")) (EVar "t")))))
(DTypeSig false "memberAliasFor" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "UseMember")))))))
(DFunDef false "memberAliasFor" ((PVar "s") (PVar "x") (PVar "allCtors") (PCon "TAs")) (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "memberAliasName")) (ELam ((PVar "a")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "x")) (EVar "allCtors")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))) (EApp (EVar "Some") (EVar "a")))))))))))))
(DFunDef false "memberAliasFor" ((PVar "s") (PVar "x") (PVar "allCtors") PWild) (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "x")) (EVar "allCtors")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))) (EVar "None"))))))))
(DTypeSig false "memberAliasName" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "memberAliasName" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "memberAliasNameFor") (EVar "t")))))
(DTypeSig false "memberAliasNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "memberAliasNameFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "memberAliasNameFor" ((PCon "TUpper" (PVar "x"))) (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (ELit (LString "a value member's alias must be lowercase; `as ")) (EApp (EVar "display") (EVar "x"))) (ELit (LString "` names a type or constructor")))))
(DFunDef false "memberAliasNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected an alias after `as`"))))
(DTypeSig false "aliasName" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "aliasName" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "aliasNameFor") (EVar "t")))))
(DTypeSig false "aliasNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "aliasNameFor" ((PCon "TUpper" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "aliasNameFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (ELit (LString "a module alias must be capitalized; `as ")) (EApp (EVar "display") (EVar "x"))) (ELit (LString "` is lowercase")))))
(DFunDef false "aliasNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected an alias after `as`"))))
(DTypeSig false "stringLitP" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "stringLitP" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "stringLitFor") (EVar "t")))))
(DTypeSig false "stringLitFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "stringLitFor" ((PCon "TString" (PVar "s"))) (EApp (EVar "emit") (EVar "s")))
(DFunDef false "stringLitFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected a string literal"))))
(DTypeSig false "interpolatedNameMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "interpolatedNameMsg" ((PVar "kw")) (EBinOp "++" (EBinOp "++" (ELit (LString "a `")) (EApp (EVar "display") (EVar "kw"))) (ELit (LString "` name must be a plain string literal, not an interpolated string"))))
(DTypeSig false "propNameFor" (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String")))))
(DFunDef false "propNameFor" ((PVar "propPos") (PCon "TInterpOpen" PWild)) (EApp (EApp (EVar "fatalAtP") (EApp (EVar "interpolatedNameMsg") (ELit (LString "prop")))) (EVar "propPos")))
(DFunDef false "propNameFor" (PWild (PVar "t")) (EApp (EVar "stringLitFor") (EVar "t")))
(DTypeSig false "parseProp" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseProp" ((PVar "pub")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "propPos")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TProp"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "propNameFor") (EVar "propPos")) (EVar "t"))) (ELam ((PVar "name")) (EApp (EApp (EVar "deferThen") (EApp (EVar "many") (EVar "propParam"))) (ELam ((PVar "params")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "params")) (EVar "body"))))))))))))))))))))
(DTypeSig false "propParam" (TyApp (TyCon "Parser") (TyCon "PropParam")))
(DFunDef false "propParam" () (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TLParen"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "PropParam") (EVar "name")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EBinOp "+" (EVar "s") (ELit (LInt 1))))) (EVar "ty"))))))))))))))))))
(DTypeSig false "parseTest" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseTest" ((PVar "pub")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "testPos")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TTest"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "parseTestRest") (EVar "pub")) (EVar "testPos")) (EVar "t")))))))))
(DTypeSig false "parseTestRest" (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Decl"))))))
(DFunDef false "parseTestRest" ((PVar "pub") PWild (PCon "TString" PWild)) (EApp (EApp (EVar "deferThen") (EVar "stringLitP")) (ELam ((PVar "name")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name")) (EVar "body"))))))))))))
(DFunDef false "parseTestRest" (PWild (PVar "testPos") (PCon "TInterpOpen" PWild)) (EApp (EApp (EVar "fatalAtP") (EApp (EVar "interpolatedNameMsg") (ELit (LString "test")))) (EVar "testPos")))
(DFunDef false "parseTestRest" (PWild (PVar "testPos") PWild) (EApp (EApp (EVar "fatalProblemAtP") (EApp (EVar "ReservedKeyword") (ELit (LString "test")))) (EVar "testPos")))
(DTypeSig false "benchRemovedMsg" (TyCon "String"))
(DFunDef false "benchRemovedMsg" () (ELit (LString "`bench` has been removed; delete the declaration")))
(DTypeSig false "parseBench" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseBench" (PWild) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "benchPos")) (EApp (EApp (EVar "fatalAtP") (EVar "benchRemovedMsg")) (EVar "benchPos")))))
(DTypeSig false "parseEffect" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseEffect" ((PVar "pub")) (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TEffect"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EApp (EVar "deferThen") (EVar "effDomainP")) (ELam ((PVar "dom")) (EApp (EApp (EVar "deferThen") (EVar "effAxesP")) (ELam ((PVar "axes")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EApp (EVar "effectDeclUnstamped") (EVar "pub")) (EVar "name")) (EVar "dom")) (EVar "axes")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))))))))))))))))))))))
(DTypeSig false "effAxesP" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "effAxesP" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "effAxesFor") (EVar "t")))))
(DTypeSig false "effAxesFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "effAxesFor" ((PCon "TLParen")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "effAxisP")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "axes")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EVar "deferPure") (EVar "axes")))))))))
(DFunDef false "effAxesFor" (PWild) (EApp (EVar "deferPure") (EListLit)))
(DTypeSig false "effAxisP" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "effAxisP" () (EApp (EApp (EVar "deferThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "upperNameP")) (ELam ((PVar "dom")) (EApp (EVar "deferPure") (ETuple (EVar "name") (EVar "dom"))))))))))
(DTypeSig false "effDomainP" (TyApp (TyCon "Parser") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "effDomainP" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "effDomainFor") (EVar "t")))))
(DTypeSig false "effDomainFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "effDomainFor" ((PCon "TUpper" (PVar "d"))) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EVar "Some") (EVar "d"))))))
(DFunDef false "effDomainFor" (PWild) (EApp (EVar "deferPure") (EVar "None")))
(DTypeSig false "parseInterface" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl")))))
(DFunDef false "parseInterface" ((PVar "pub") (PVar "isDefault")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "kw")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TInterface"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "locatedUpperNameP")) (ELam ((PVar "named")) (ELet false (PVar "name") (EApp (EVar "fst") (EVar "named")) (ELet false (PVar "nameLoc") (EApp (EVar "snd") (EVar "named")) (EApp (EApp (EVar "deferThen") (EVar "tyParamsP")) (ELam ((PVar "ps")) (EApp (EApp (EVar "deferThen") (EVar "ifaceSuper")) (ELam ((PVar "supers")) (EApp (EApp (EVar "deferThen") (EApp (EVar "ifaceBody") (EVar "kw"))) (ELam ((PVar "methods")) (EApp (EVar "deferPure") (EApp (EApp (EVar "setDeclNameLoc") (EVar "nameLoc")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dInterfaceUnresolved") (EVar "pub")) (EVar "isDefault")) (EVar "name")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "ps"))) (EApp (EApp (EVar "map") (EVar "snd")) (EVar "ps"))) (EVar "supers")) (EVar "methods")))))))))))))))))))
(DTypeSig false "ifaceSuper" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Super"))))
(DFunDef false "ifaceSuper" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "ifaceSuperFor") (EVar "t")))))
(DTypeSig false "ifaceSuperFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Super")))))
(DFunDef false "ifaceSuperFor" ((PCon "TRequires")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "sepBy1") (EVar "ifaceSuperEntry")) (EApp (EVar "expectTok") (EVar "TComma"))))))
(DFunDef false "ifaceSuperFor" (PWild) (EApp (EVar "deferPure") (EListLit)))
(DTypeSig false "ifaceSuperEntry" (TyApp (TyCon "Parser") (TyCon "Super")))
(DFunDef false "ifaceSuperEntry" () (EApp (EApp (EVar "deferThen") (EVar "upperNameP")) (ELam ((PVar "head")) (EApp (EApp (EVar "deferThen") (EApp (EVar "upperQualTail") (EVar "head"))) (ELam ((PVar "name")) (EApp (EApp (EVar "deferThen") (EApp (EVar "many") (EVar "lowerNameP"))) (ELam ((PVar "params")) (EApp (EVar "deferPure") (EApp (EApp (EVar "superUnresolved") (EVar "name")) (EVar "params"))))))))))
(DTypeSig false "ifaceBody" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod")))))
(DFunDef false "ifaceBody" ((PVar "kw")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "ifaceBodyFor") (EVar "kw")) (EVar "t")))))
(DTypeSig false "ifaceBodyFor" (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod"))))))
(DFunDef false "ifaceBodyFor" (PWild (PCon "TWhere")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "ifaceWhereBody") (EVar "t")))))))
(DFunDef false "ifaceBodyFor" ((PVar "kw") (PVar "t")) (EIf (EApp (EVar "endsDecl") (EVar "t")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "deferPure") (EListLit)))) (EIf (EVar "otherwise") (EApp (EApp (EVar "fatalProblemAtP") (EVar "missingWhereIfaceMsg")) (EVar "kw")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ifaceWhereBody" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod")))))
(DFunDef false "ifaceWhereBody" ((PCon "TIndent")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "ifaceMembers")) (ELam ((PVar "ms")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "deferPure") (EVar "ms")))))))))))
(DFunDef false "ifaceWhereBody" ((PVar "t")) (EIf (EApp (EVar "endsDecl") (EVar "t")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "deferPure") (EListLit)))) (EIf (EVar "otherwise") (EApp (EVar "fatalP") (EVar "sameLineWhereIfaceMsg")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "endsDecl" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "endsDecl" ((PCon "TNewline")) (EVar "True"))
(DFunDef false "endsDecl" ((PCon "TDedent")) (EVar "True"))
(DFunDef false "endsDecl" ((PCon "TEof")) (EVar "True"))
(DFunDef false "endsDecl" (PWild) (EVar "False"))
(DTypeSig false "missingWhereIfaceMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "missingWhereIfaceMsg" () (EApp (EVar "MissingWhere") (ELit (LString "interface"))))
(DTypeSig false "missingWhereImplMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "missingWhereImplMsg" () (EApp (EVar "MissingWhere") (ELit (LString "impl"))))
(DTypeSig false "sameLineWhereIfaceMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "sameLineWhereIfaceMsg" () (EApp (EVar "WhereSameLine") (ELit (LString "interface"))))
(DTypeSig false "sameLineWhereImplMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "sameLineWhereImplMsg" () (EApp (EVar "WhereSameLine") (ELit (LString "impl"))))
(DTypeSig false "ifaceMembers" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod"))))
(DFunDef false "ifaceMembers" () (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EVar "ifaceMembersLoop"))))
(DTypeSig false "ifaceMembersLoop" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod"))))
(DFunDef false "ifaceMembersLoop" () (EApp (EApp (EVar "parseOrElse") (EVar "ifaceMembersCons")) (EApp (EVar "deferPure") (EListLit))))
(DTypeSig false "ifaceMembersCons" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod"))))
(DFunDef false "ifaceMembersCons" () (EApp (EApp (EVar "deferThen") (EVar "ifaceMember")) (ELam ((PVar "m")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "ifaceMembersLoop")) (ELam ((PVar "rest")) (EApp (EVar "deferPure") (EBinOp "::" (EVar "m") (EVar "rest"))))))))))
(DTypeSig false "ifaceMember" (TyApp (TyCon "Parser") (TyCon "IfaceMethod")))
(DFunDef false "ifaceMember" () (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EApp (EVar "deferThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EApp (EVar "ifaceMemberRest") (EVar "name")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q")))) (EVar "pats")) (EVar "t")))))))))))))))
(DTypeSig false "ifaceMemberRest" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "IfaceMethod")))))))
(DFunDef false "ifaceMemberRest" ((PVar "name") (PVar "nameLoc") PWild (PCon "TColon")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "name")) (EVar "ty")) (EVar "None")) (EVar "nameLoc"))))))))
(DFunDef false "ifaceMemberRest" ((PVar "name") (PVar "nameLoc") (PVar "pats") (PCon "TEqual")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "name")) (EApp (EVar "TyVar") (ELit (LString "_")))) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EVar "pats")) (EVar "body")))) (EVar "nameLoc"))))))))
(DFunDef false "ifaceMemberRest" (PWild PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected `:` or `=` after the interface member name"))))
(DTypeSig false "parseImpl" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseImpl" ((PVar "pub")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "kw")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TImpl"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "implHead") (EVar "pub")) (EVar "kw")) (EVar "t")))))))))
(DTypeSig false "implHead" (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Decl"))))))
(DFunDef false "implHead" ((PVar "pub") (PVar "kw") (PCon "TUpper" (PVar "u"))) (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "upperQualTail") (EVar "u"))) (ELam ((PVar "n")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EApp (EVar "deferThen") (EApp (EApp (EApp (EVar "implRest") (EVar "pub")) (EVar "kw")) (EVar "n"))) (ELam ((PVar "d")) (EApp (EVar "deferPure") (EApp (EApp (EVar "setDeclNameLoc") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))) (EVar "d"))))))))))))))))
(DFunDef false "implHead" (PWild PWild (PCon "TIdent" PWild)) (EApp (EVar "failP") (EVar "namedImplRemovedMsg")))
(DFunDef false "implHead" (PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected an interface name after `impl`"))))
(DTypeSig false "implRest" (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Decl"))))))
(DFunDef false "implRest" ((PVar "pub") (PVar "kw") (PVar "iface")) (EApp (EApp (EVar "deferThen") (EApp (EVar "many") (EVar "parseTyAtom"))) (ELam ((PVar "tyargs")) (EApp (EApp (EVar "deferThen") (EVar "implRequires")) (ELam ((PVar "reqs")) (EApp (EApp (EVar "deferThen") (EApp (EVar "implBody") (EVar "kw"))) (ELam ((PVar "methods")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EApp (EVar "dImplUnresolved") (EVar "pub")) (EVar "iface")) (EVar "tyargs")) (EVar "reqs")) (EVar "methods"))))))))))
(DTypeSig false "namedImplRemovedMsg" (TyCon "String"))
(DFunDef false "namedImplRemovedMsg" () (ELit (LString "named impls (`impl name of Iface`) have been removed; write a plain `impl Iface`")))
(DTypeSig false "defaultImplRemovedMsg" (TyCon "String"))
(DFunDef false "defaultImplRemovedMsg" () (ELit (LString "`default impl` has been removed; write a plain `impl`")))
(DTypeSig false "implRequires" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Require"))))
(DFunDef false "implRequires" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "implRequiresFor") (EVar "t")))))
(DTypeSig false "implRequiresFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Require")))))
(DFunDef false "implRequiresFor" ((PCon "TRequires")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "sepBy1") (EVar "implRequireEntry")) (EApp (EVar "expectTok") (EVar "TComma"))))))
(DFunDef false "implRequiresFor" (PWild) (EApp (EVar "deferPure") (EListLit)))
(DTypeSig false "implRequireEntry" (TyApp (TyCon "Parser") (TyCon "Require")))
(DFunDef false "implRequireEntry" () (EApp (EApp (EVar "deferThen") (EVar "upperNameP")) (ELam ((PVar "head")) (EApp (EApp (EVar "deferThen") (EApp (EVar "upperQualTail") (EVar "head"))) (ELam ((PVar "iface")) (EApp (EApp (EVar "deferThen") (EApp (EVar "many") (EVar "parseTyAtom"))) (ELam ((PVar "tys")) (EApp (EVar "deferPure") (EApp (EApp (EVar "requireUnresolved") (EVar "iface")) (EVar "tys"))))))))))
(DTypeSig false "implBody" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod")))))
(DFunDef false "implBody" ((PVar "kw")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "implBodyFor") (EVar "kw")) (EVar "t")))))
(DTypeSig false "implBodyFor" (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod"))))))
(DFunDef false "implBodyFor" (PWild (PCon "TWhere")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "implWhereBody") (EVar "t")))))))
(DFunDef false "implBodyFor" ((PVar "kw") (PVar "t")) (EIf (EApp (EVar "endsDecl") (EVar "t")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "deferPure") (EListLit)))) (EIf (EVar "otherwise") (EApp (EApp (EVar "fatalProblemAtP") (EVar "missingWhereImplMsg")) (EVar "kw")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "implWhereBody" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod")))))
(DFunDef false "implWhereBody" ((PCon "TIndent")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "implMethods")) (ELam ((PVar "ms")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "deferPure") (EVar "ms")))))))))))
(DFunDef false "implWhereBody" ((PVar "t")) (EIf (EApp (EVar "endsDecl") (EVar "t")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "deferPure") (EListLit)))) (EIf (EVar "otherwise") (EApp (EVar "fatalP") (EVar "sameLineWhereImplMsg")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "implMethods" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod"))))
(DFunDef false "implMethods" () (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EVar "implMethodsLoop"))))
(DTypeSig false "implMethodsLoop" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod"))))
(DFunDef false "implMethodsLoop" () (EApp (EApp (EVar "parseOrElse") (EVar "implMethodsCons")) (EApp (EVar "deferPure") (EListLit))))
(DTypeSig false "implMethodsCons" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod"))))
(DFunDef false "implMethodsCons" () (EApp (EApp (EVar "deferThen") (EVar "implMethod")) (ELam ((PVar "m")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "implMethodsLoop")) (ELam ((PVar "rest")) (EApp (EVar "deferPure") (EBinOp "::" (EVar "m") (EVar "rest"))))))))))
(DTypeSig false "implMethod" (TyApp (TyCon "Parser") (TyCon "ImplMethod")))
(DFunDef false "implMethod" () (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "p")) (EApp (EApp (EVar "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "deferThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EApp (EApp (EApp (EVar "implMethodRest") (EVar "name")) (EVar "pats")) (EVar "t"))) (ELam ((PVar "m")) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "recordUnitStart") (ELit (LInt 2))) (EVar "p"))) (ELam (PWild) (EApp (EVar "deferPure") (EVar "m")))))))))))))))
(DTypeSig false "implMethodRest" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "ImplMethod"))))))
(DFunDef false "implMethodRest" ((PVar "name") (PVar "pats") (PCon "TEqual")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "ImplMethod") (EVar "name")) (EVar "pats")) (EVar "body"))))))))
(DFunDef false "implMethodRest" ((PVar "name") (PVar "pats") (PCon "TIndent")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseGuardArms")) (ELam ((PVar "arms")) (EApp (EApp (EVar "deferThen") (EApp (EVar "guardArmsWhereOpt") (EVar "arms"))) (ELam ((PVar "body")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "ImplMethod") (EVar "name")) (EVar "pats")) (EVar "body"))))))))))))
(DFunDef false "implMethodRest" ((PVar "name") (PVar "pats") (PCon "TPipe")) (EApp (EApp (EVar "deferThen") (EVar "parseGuardArm")) (ELam ((PVar "arm")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "ImplMethod") (EVar "name")) (EVar "pats")) (EApp (EVar "EGuards") (EListLit (EVar "arm"))))))))
(DFunDef false "implMethodRest" (PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected `=` or `|` after the method head"))))
(DTypeSig false "guardArmsWhereOpt" (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "guardArmsWhereOpt" ((PVar "arms")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "guardArmsWhereFor") (EVar "arms")) (EVar "t")))))
(DTypeSig false "guardArmsWhereFor" (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "guardArmsWhereFor" ((PVar "arms") (PCon "TWhere")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseWhereBindings")) (ELam ((PVar "binds")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EVar "ELetGroup") (EApp (EVar "coalesceClauses") (EVar "binds"))) (EApp (EVar "EGuards") (EVar "arms")))))))))))))))
(DFunDef false "guardArmsWhereFor" ((PVar "arms") PWild) (EApp (EVar "deferPure") (EApp (EVar "EGuards") (EVar "arms"))))
(DTypeSig false "parseGuardArms" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "GuardArm"))))
(DFunDef false "parseGuardArms" () (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EVar "guardArmsLoop"))))
(DTypeSig false "guardArmsLoop" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "GuardArm"))))
(DFunDef false "guardArmsLoop" () (EApp (EApp (EVar "parseOrElse") (EVar "guardArmsCons")) (EApp (EVar "deferPure") (EListLit))))
(DTypeSig false "guardArmsCons" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "GuardArm"))))
(DFunDef false "guardArmsCons" () (EApp (EApp (EVar "deferThen") (EVar "parseGuardArm")) (ELam ((PVar "a")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "guardArmsLoop")) (ELam ((PVar "rest")) (EApp (EVar "deferPure") (EBinOp "::" (EVar "a") (EVar "rest"))))))))))
(DTypeSig false "parseGuardArm" (TyApp (TyCon "Parser") (TyCon "GuardArm")))
(DFunDef false "parseGuardArm" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "parseGuardArmFor") (EVar "t")))))
(DTypeSig false "parseGuardArmFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "GuardArm"))))
(DFunDef false "parseGuardArmFor" ((PCon "TIf")) (EApp (EApp (EVar "deferThen") (EVar "eqGuardShapeP")) (ELam ((PVar "looksGuard")) (EApp (EVar "parseGuardArmIf") (EVar "looksGuard")))))
(DFunDef false "parseGuardArmFor" (PWild) (EVar "parseGuardArmBody"))
(DTypeSig false "parseGuardArmIf" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "GuardArm"))))
(DFunDef false "parseGuardArmIf" ((PCon "True")) (EApp (EVar "fatalP") (EVar "eqGuardIfMsg")))
(DFunDef false "parseGuardArmIf" ((PCon "False")) (EVar "parseGuardArmBody"))
(DTypeSig false "parseGuardArmBody" (TyApp (TyCon "Parser") (TyCon "GuardArm")))
(DFunDef false "parseGuardArmBody" () (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TPipe"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "parseGuard")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "guards")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EVar "deferPure") (EApp (EApp (EVar "GuardArm") (EVar "guards")) (EVar "body"))))))))))))
(DTypeSig false "eqGuardIfMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "eqGuardIfMsg" () (EVar "EquationGuardIf"))
(DTypeSig false "eqGuardShapeFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "eqGuardShapeFrom" ((PVar "toks") (PVar "i") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "False") (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "isLineEndTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EVar "False") (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "isThenTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EVar "False") (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "isEqualTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EVar "True") (EIf (EApp (EVar "isBracketOpenTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EVar "eqGuardShapeFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EApp (EVar "isBracketCloseTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EVar "eqGuardShapeFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "eqGuardShapeFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "eqGuardShapeP" (TyApp (TyCon "Parser") (TyCon "Bool")))
(DFunDef false "eqGuardShapeP" () (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EVar "POk") (EApp (EApp (EApp (EVar "eqGuardShapeFrom") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "pos")) (ELit (LInt 0)))) (EVar "pos")))))
(DTypeSig false "parseGuard" (TyApp (TyCon "Parser") (TyCon "Guard")))
(DFunDef false "parseGuard" () (EApp (EApp (EVar "deferThen") (EVar "parseOr")) (ELam ((PVar "e")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "guardFor") (EVar "e")) (EVar "t")))))))
(DTypeSig false "guardFor" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Guard")))))
(DFunDef false "guardFor" ((PVar "e") (PCon "TLArrow")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseOr")) (ELam ((PVar "rhs")) (EApp (EVar "deferPure") (EApp (EApp (EVar "GBind") (EApp (EVar "exprToPat") (EVar "e"))) (EVar "rhs"))))))))
(DFunDef false "guardFor" ((PVar "e") PWild) (EApp (EVar "deferPure") (EApp (EVar "GBool") (EVar "e"))))
(DTypeSig false "lowerNameP" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "lowerNameP" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "lowerNameFor") (EVar "t")))))
(DTypeSig false "lowerNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "lowerNameFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "lowerNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected a type parameter"))))
(DTypeSig false "tyParamsP" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "KindAnn"))))))
(DFunDef false "tyParamsP" () (EApp (EVar "many") (EVar "tyParamP")))
(DTypeSig false "tyParamP" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "KindAnn")))))
(DFunDef false "tyParamP" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "tyParamFor") (EVar "t")))))
(DTypeSig false "tyParamFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "KindAnn"))))))
(DFunDef false "tyParamFor" ((PCon "TLParen")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "lowerNameP")) (ELam ((PVar "n")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "kindP")) (ELam ((PVar "k")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EVar "deferPure") (ETuple (EVar "n") (EApp (EVar "Some") (EVar "k")))))))))))))))
(DFunDef false "tyParamFor" ((PVar "t")) (EApp (EApp (EVar "deferThen") (EApp (EVar "lowerNameFor") (EVar "t"))) (ELam ((PVar "n")) (EApp (EVar "deferPure") (ETuple (EVar "n") (EVar "None"))))))
(DTypeSig false "kindP" (TyApp (TyCon "Parser") (TyCon "KindAnn")))
(DFunDef false "kindP" () (EApp (EApp (EVar "deferThen") (EVar "kindAtomP")) (ELam ((PVar "a")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "kindArrowRest") (EVar "a")) (EVar "t")))))))
(DTypeSig false "kindArrowRest" (TyFun (TyCon "KindAnn") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "KindAnn")))))
(DFunDef false "kindArrowRest" ((PVar "a") (PCon "TArrow")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "kindP")) (ELam ((PVar "b")) (EApp (EVar "deferPure") (EApp (EApp (EVar "KindArrow") (EVar "a")) (EVar "b"))))))))
(DFunDef false "kindArrowRest" ((PVar "a") PWild) (EApp (EVar "deferPure") (EVar "a")))
(DTypeSig false "kindAtomP" (TyApp (TyCon "Parser") (TyCon "KindAnn")))
(DFunDef false "kindAtomP" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "kindAtomFor") (EVar "t")))))
(DTypeSig false "kindAtomFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "KindAnn"))))
(DFunDef false "kindAtomFor" ((PCon "TUpper" (PVar "c"))) (EIf (EBinOp "==" (EVar "c") (ELit (LString "Type"))) (EApp (EVar "kindAtomEmit") (EVar "KindType")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "Effect"))) (EApp (EVar "kindAtomEmit") (EVar "KindEffect")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "Authority"))) (EVar "kindAuthorityP") (EIf (EVar "otherwise") (EApp (EVar "failP") (EVar "kindExpectedMsg")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DFunDef false "kindAtomFor" ((PCon "TLParen")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "kindP")) (ELam ((PVar "k")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EVar "deferPure") (EVar "k")))))))))
(DFunDef false "kindAtomFor" (PWild) (EApp (EVar "failP") (EVar "kindExpectedMsg")))
(DTypeSig false "kindExpectedMsg" (TyCon "String"))
(DFunDef false "kindExpectedMsg" () (ELit (LString "expected a kind: `Type`, `Effect`, `Authority <Label>` or an arrow between them")))
(DTypeSig false "kindAuthorityP" (TyApp (TyCon "Parser") (TyCon "KindAnn")))
(DFunDef false "kindAuthorityP" () (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "upperNameP")) (ELam ((PVar "l")) (EApp (EApp (EVar "deferThen") (EVar "patternMarkP")) (ELam ((PVar "pat")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EVar "deferPure") (EApp (EApp (EApp (EVar "kindAuthorityUnstamped") (EVar "l")) (EVar "pat")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))))))))))))))))))
(DTypeSig false "patternMarkP" (TyApp (TyCon "Parser") (TyCon "Bool")))
(DFunDef false "patternMarkP" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "patternMarkFor") (EVar "t")))))
(DTypeSig false "patternMarkFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Bool"))))
(DFunDef false "patternMarkFor" ((PCon "TStar")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "deferPure") (EVar "True")))))
(DFunDef false "patternMarkFor" (PWild) (EApp (EVar "deferPure") (EVar "False")))
(DTypeSig false "kindAtomEmit" (TyFun (TyCon "KindAnn") (TyApp (TyCon "Parser") (TyCon "KindAnn"))))
(DFunDef false "kindAtomEmit" ((PVar "k")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "deferPure") (EVar "k")))))
(DTypeSig false "parseData" (TyFun (TyCon "DataVis") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseData" ((PVar "vis")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TData"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "locatedUpperNameP")) (ELam ((PVar "named")) (ELet false (PVar "name") (EApp (EVar "fst") (EVar "named")) (ELet false (PVar "nameLoc") (EApp (EVar "snd") (EVar "named")) (EApp (EApp (EVar "deferThen") (EVar "tyParamsP")) (ELam ((PVar "ps")) (EApp (EApp (EVar "deferThen") (EApp (EVar "dataBody") (EVar "name"))) (ELam ((PVar "bodyAndDerives")) (ELet false (PVar "variants") (EApp (EVar "fst") (EVar "bodyAndDerives")) (ELet false (PVar "blockDerives") (EApp (EVar "snd") (EVar "bodyAndDerives")) (EApp (EApp (EVar "deferThen") (EVar "derivingClause")) (ELam ((PVar "outerDerives")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EVar "setDeclNameLoc") (EVar "nameLoc")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dDataUnresolved") (EVar "vis")) (EVar "name")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "ps"))) (EApp (EApp (EVar "map") (EVar "snd")) (EVar "ps"))) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "variants"))) (EApp (EApp (EVar "map") (EVar "snd")) (EVar "variants"))) (EApp (EApp (EVar "combineDerives") (EVar "blockDerives")) (EVar "outerDerives"))))))))))))))))))))))
(DTypeSig false "combineDerives" (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyApp (TyCon "List") (TyCon "DeriveRef")))))
(DFunDef false "combineDerives" ((PList) (PVar "outer")) (EVar "outer"))
(DFunDef false "combineDerives" ((PVar "block") PWild) (EVar "block"))
(DTypeSig false "dataBody" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Variant") (TyCon "CtorBinders"))) (TyApp (TyCon "List") (TyCon "DeriveRef"))))))
(DFunDef false "dataBody" ((PVar "tyName")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "dataBodyFor") (EVar "tyName")) (EVar "t")))))
(DTypeSig false "dataBodyFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Variant") (TyCon "CtorBinders"))) (TyApp (TyCon "List") (TyCon "DeriveRef")))))))
(DFunDef false "dataBodyFor" ((PVar "tyName") (PCon "TEqual")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "dataAfterEq") (EVar "tyName")) (EVar "t")))))))
(DFunDef false "dataBodyFor" ((PVar "tyName") (PCon "TIndent")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "dataVariantsN") (EVar "tyName"))) (ELam ((PVar "vs")) (EApp (EApp (EVar "deferThen") (EVar "derivingClause")) (ELam ((PVar "derives")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EVar "deferPure") (ETuple (EVar "vs") (EVar "derives"))))))))))))))))
(DFunDef false "dataBodyFor" (PWild PWild) (EApp (EVar "deferPure") (ETuple (EListLit) (EListLit))))
(DTypeSig false "dataAfterEq" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Variant") (TyCon "CtorBinders"))) (TyApp (TyCon "List") (TyCon "DeriveRef")))))))
(DFunDef false "dataAfterEq" ((PVar "tyName") (PCon "TIndent")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "optPipe")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "dataVariantsN") (EVar "tyName"))) (ELam ((PVar "vs")) (EApp (EApp (EVar "deferThen") (EVar "derivingClause")) (ELam ((PVar "derives")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EVar "deferPure") (ETuple (EVar "vs") (EVar "derives"))))))))))))))))))
(DFunDef false "dataAfterEq" ((PVar "tyName") PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "dataVariantsN") (EVar "tyName"))) (ELam ((PVar "vs")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EApp (EVar "inlineTrailingDerives") (EVar "t"))) (ELam ((PVar "derives")) (EApp (EVar "deferPure") (ETuple (EVar "vs") (EVar "derives"))))))))))
(DTypeSig false "newtypeDerives" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DeriveRef")))))
(DFunDef false "newtypeDerives" ((PCon "TIndent")) (EApp (EVar "inlineTrailingDerives") (EVar "TIndent")))
(DFunDef false "newtypeDerives" (PWild) (EVar "derivingClause"))
(DTypeSig false "inlineTrailingDerives" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DeriveRef")))))
(DFunDef false "inlineTrailingDerives" ((PCon "TIndent")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "derivingClause")) (ELam ((PVar "derives")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EVar "deferPure") (EVar "derives")))))))))))
(DFunDef false "inlineTrailingDerives" (PWild) (EApp (EVar "deferPure") (EListLit)))
(DTypeSig false "optPipe" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "optPipe" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "optPipeFor") (EVar "t")))))
(DTypeSig false "optPipeFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "optPipeFor" ((PCon "TPipe")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "deferPure") (ELit LUnit)))))
(DFunDef false "optPipeFor" (PWild) (EApp (EVar "deferPure") (ELit LUnit)))
(DTypeAlias false "CtorBinders" () (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn"))))
(DTypeSig false "dataVariantsN" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "Variant") (TyCon "CtorBinders"))))))
(DFunDef false "dataVariantsN" ((PVar "tyName")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "dataVariantsNFor") (EVar "tyName")) (EVar "t")))))
(DTypeSig false "dataVariantsNFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "Variant") (TyCon "CtorBinders")))))))
(DFunDef false "dataVariantsNFor" ((PVar "tyName") (PCon "TLBrace")) (EApp (EApp (EVar "deferThen") (EVar "parseNamedFields")) (ELam ((PVar "fields")) (EApp (EVar "deferPure") (EListLit (ETuple (EApp (EApp (EVar "Variant") (EVar "tyName")) (EApp (EApp (EVar "ConNamed") (EVar "fields")) (EVar "True"))) (EListLit)))))))
(DFunDef false "dataVariantsNFor" (PWild PWild) (EVar "dataVariants"))
(DTypeSig false "dataVariants" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "Variant") (TyCon "CtorBinders")))))
(DFunDef false "dataVariants" () (EApp (EApp (EVar "deferThen") (EVar "parseVariant")) (ELam ((PVar "v")) (EApp (EApp (EVar "deferThen") (EVar "variantsRest")) (ELam ((PVar "rest")) (EApp (EVar "deferPure") (EBinOp "::" (EVar "v") (EVar "rest"))))))))
(DTypeSig false "variantsRest" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "Variant") (TyCon "CtorBinders")))))
(DFunDef false "variantsRest" () (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "variantsRestFor") (EVar "t")))))))
(DTypeSig false "variantsRestFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "Variant") (TyCon "CtorBinders"))))))
(DFunDef false "variantsRestFor" ((PCon "TPipe")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseVariant")) (ELam ((PVar "v")) (EApp (EApp (EVar "deferThen") (EVar "variantsRest")) (ELam ((PVar "rest")) (EApp (EVar "deferPure") (EBinOp "::" (EVar "v") (EVar "rest"))))))))))
(DFunDef false "variantsRestFor" (PWild) (EApp (EVar "deferPure") (EListLit)))
(DTypeSig false "parseVariant" (TyApp (TyCon "Parser") (TyTuple (TyCon "Variant") (TyCon "CtorBinders"))))
(DFunDef false "parseVariant" () (EApp (EApp (EVar "deferThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "deferThen") (EVar "ctorBindersP")) (ELam ((PVar "binders")) (EApp (EApp (EVar "deferThen") (EVar "parsePayload")) (ELam ((PVar "payload")) (EApp (EVar "deferPure") (ETuple (EApp (EApp (EVar "Variant") (EVar "name")) (EVar "payload")) (EVar "binders"))))))))))
(DTypeSig false "ctorBindersP" (TyApp (TyCon "Parser") (TyCon "CtorBinders")))
(DFunDef false "ctorBindersP" () (EApp (EVar "many") (EVar "ctorBinderP")))
(DTypeSig false "ctorBinderP" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyCon "KindAnn"))))
(DFunDef false "ctorBinderP" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EVar "ctorBinderFor") (EVar "t")) (EVar "t2")))))))
(DTypeSig false "ctorBinderFor" (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyCon "KindAnn"))))))
(DFunDef false "ctorBinderFor" ((PCon "TLParen") (PCon "TIdent" PWild)) (EApp (EApp (EVar "deferThen") (EVar "peek3P")) (ELam ((PVar "t3")) (EApp (EVar "ctorBinderColon") (EVar "t3")))))
(DFunDef false "ctorBinderFor" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected a constructor binder"))))
(DTypeSig false "ctorBinderColon" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyCon "KindAnn")))))
(DFunDef false "ctorBinderColon" ((PCon "TColon")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "lowerNameP")) (ELam ((PVar "n")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "kindP")) (ELam ((PVar "k")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EApp (EVar "ctorBinderKind") (EVar "n")) (EVar "k")))))))))))))
(DFunDef false "ctorBinderColon" (PWild) (EApp (EVar "failP") (ELit (LString "expected a constructor binder"))))
(DTypeSig false "ctorBinderKind" (TyFun (TyCon "String") (TyFun (TyCon "KindAnn") (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyCon "KindAnn"))))))
(DFunDef false "ctorBinderKind" ((PVar "n") (PAs "k" (PCon "KindAuthority" PWild PWild PWild PWild))) (EApp (EVar "deferPure") (ETuple (EVar "n") (EVar "k"))))
(DFunDef false "ctorBinderKind" ((PVar "n") (PVar "k")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "pos")) (EApp (EApp (EVar "fatalAtP") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "a constructor may bind only an `Authority` existential, not `(")) (EApp (EVar "display") (EVar "n"))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "kindAnnSource") (EVar "k")))) (ELit (LString ")`; declare `"))) (EApp (EVar "display") (EVar "n"))) (ELit (LString "` on the type's head instead")))) (EVar "pos")))))
(DTypeSig false "parsePayload" (TyApp (TyCon "Parser") (TyCon "ConPayload")))
(DFunDef false "parsePayload" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "payloadFor") (EVar "t")))))
(DTypeSig false "payloadFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "ConPayload"))))
(DFunDef false "payloadFor" ((PCon "TLBrace")) (EVar "parseNamedPayload"))
(DFunDef false "payloadFor" (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "many") (EVar "parseTyAtom"))) (ELam ((PVar "tys")) (EApp (EVar "deferPure") (EApp (EVar "ConPos") (EVar "tys"))))))
(DTypeSig false "parseNamedPayload" (TyApp (TyCon "Parser") (TyCon "ConPayload")))
(DFunDef false "parseNamedPayload" () (EApp (EApp (EVar "deferThen") (EVar "parseNamedFields")) (ELam ((PVar "fields")) (EApp (EVar "deferPure") (EApp (EApp (EVar "ConNamed") (EVar "fields")) (EVar "False"))))))
(DTypeSig false "parseNamedFields" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Field"))))
(DFunDef false "parseNamedFields" () (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TLBrace"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "parseField")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "fields")) (EApp (EApp (EVar "deferThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EVar "deferPure") (EVar "fields")))))))))))
(DTypeSig false "parseField" (TyApp (TyCon "Parser") (TyCon "Field")))
(DFunDef false "parseField" () (EApp (EApp (EVar "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseTy")) (ELam ((PVar "t")) (EApp (EVar "deferPure") (EApp (EApp (EVar "Field") (EVar "name")) (EVar "t"))))))))))
(DTypeSig false "derivingClause" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DeriveRef"))))
(DFunDef false "derivingClause" () (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "derivingFor") (EVar "t")))))))
(DTypeSig false "derivingFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DeriveRef")))))
(DFunDef false "derivingFor" ((PCon "TDeriving")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TLParen"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "derivedNameP")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "names")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EVar "deferPure") (EVar "names")))))))))))
(DFunDef false "derivingFor" (PWild) (EApp (EVar "deferPure") (EListLit)))
(DTypeSig false "derivedNameP" (TyApp (TyCon "Parser") (TyCon "DeriveRef")))
(DFunDef false "derivedNameP" () (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "upperNameP")) (ELam ((PVar "n")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EVar "deferPure") (EApp (EApp (EVar "DeriveRef") (EVar "n")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))))))))))))))
(DTypeSig false "parseBody" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseBody" () (EApp (EApp (EVar "parseOrElse") (EVar "indentedBody")) (EVar "parseBodyExpr")))
(DTypeSig false "parseBodyExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseBodyExpr" () (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "whereEol") (EVar "e"))) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "whereTail") (EVar "e"))) (EApp (EVar "deferPure") (EVar "e")))))))
(DTypeSig false "whereEol" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "whereEol" ((PVar "e")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TWhere"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseWhereBindings")) (ELam ((PVar "binds")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EVar "ELetGroup") (EApp (EVar "coalesceClauses") (EVar "binds"))) (EVar "e"))))))))))))
(DTypeSig false "whereTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "whereTail" ((PVar "e")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TWhere"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseWhereBindings")) (ELam ((PVar "binds")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EVar "ELetGroup") (EApp (EVar "coalesceClauses") (EVar "binds"))) (EVar "e"))))))))))))))))))
(DTypeSig false "parseWhereBindings" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyCon "Loc")))))
(DFunDef false "parseWhereBindings" () (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EVar "whereBindingsLoop"))))
(DTypeSig false "whereBindingsLoop" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyCon "Loc")))))
(DFunDef false "whereBindingsLoop" () (EApp (EApp (EVar "parseOrElse") (EVar "whereBindingsCons")) (EApp (EVar "deferPure") (EListLit))))
(DTypeSig false "whereBindingsCons" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyCon "Loc")))))
(DFunDef false "whereBindingsCons" () (EApp (EApp (EVar "deferThen") (EVar "parseWhereBinding")) (ELam ((PVar "b")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "whereBindingsLoop")) (ELam ((PVar "rest")) (EApp (EVar "deferPure") (EBinOp "::" (EVar "b") (EVar "rest"))))))))))
(DTypeSig false "parseWhereBinding" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyCon "Loc"))))
(DFunDef false "parseWhereBinding" () (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "p")) (EApp (EApp (EVar "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "deferThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EApp (EApp (EApp (EVar "whereBindRest") (EVar "name")) (EVar "pats")) (EVar "t"))) (ELam ((PVar "b")) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "recordUnitStart") (ELit (LInt 3))) (EVar "p"))) (ELam (PWild) (EApp (EVar "deferPure") (EApp (EApp (EVar "withBindSite") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (EVar "b"))))))))))))))))))
(DTypeSig false "withBindSite" (TyFun (TyCon "Loc") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyCon "Loc")))))
(DFunDef false "withBindSite" ((PVar "site") (PTuple (PVar "name") (PVar "pats") (PVar "body"))) (ETuple (EVar "name") (EVar "pats") (EVar "body") (EVar "site")))
(DTypeSig false "whereBindRest" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))
(DFunDef false "whereBindRest" ((PVar "name") (PList) (PCon "TColon")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseRhsExpr")) (ELam ((PVar "body")) (EApp (EVar "deferPure") (ETuple (EVar "name") (EListLit) (EApp (EApp (EVar "EAnnot") (EVar "body")) (EVar "ty")))))))))))))
(DFunDef false "whereBindRest" ((PVar "name") (PVar "pats") (PCon "TEqual")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseRhsExpr")) (ELam ((PVar "body")) (EApp (EVar "deferPure") (ETuple (EVar "name") (EVar "pats") (EVar "body"))))))))
(DFunDef false "whereBindRest" ((PVar "name") (PVar "pats") (PCon "TIndent")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseGuardArms")) (ELam ((PVar "arms")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EVar "deferPure") (ETuple (EVar "name") (EVar "pats") (EApp (EVar "EGuards") (EVar "arms")))))))))))
(DFunDef false "whereBindRest" ((PVar "name") (PVar "pats") (PCon "TPipe")) (EApp (EApp (EVar "deferThen") (EVar "parseGuardArm")) (ELam ((PVar "arm")) (EApp (EVar "deferPure") (ETuple (EVar "name") (EVar "pats") (EApp (EVar "EGuards") (EListLit (EVar "arm"))))))))
(DFunDef false "whereBindRest" (PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected a body for the `where` binding"))))
(DTypeSig false "coalesceClauses" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "LetBind"))))
(DFunDef false "coalesceClauses" ((PList)) (EListLit))
(DFunDef false "coalesceClauses" ((PCons (PTuple (PVar "name") (PVar "ps") (PVar "b") (PVar "site")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "coalesceGo") (EVar "name")) (EVar "site")) (EListLit (EApp (EApp (EVar "FunClause") (EVar "ps")) (EVar "b")))) (EVar "rest")))
(DTypeSig false "coalesceGo" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "LetBind")))))))
(DFunDef false "coalesceGo" ((PVar "name") (PVar "site") (PVar "acc") (PList)) (EListLit (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "name")) (EApp (EVar "reverseL") (EVar "acc"))) (EVar "site")) (EVar "noBinderId"))))
(DFunDef false "coalesceGo" ((PVar "name") (PVar "site") (PVar "acc") (PCons (PTuple (PVar "n") (PVar "ps") (PVar "b") (PVar "nsite")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "coalesceStep") (EVar "name")) (EVar "site")) (EVar "acc")) (EVar "n")) (EVar "ps")) (EVar "b")) (EVar "nsite")) (EVar "rest")))
(DTypeSig false "coalesceStep" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "LetBind")))))))))))
(DFunDef false "coalesceStep" ((PVar "name") (PVar "site") (PVar "acc") (PVar "n") (PVar "ps") (PVar "b") (PVar "nsite") (PVar "rest")) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EApp (EApp (EApp (EVar "coalesceGo") (EVar "name")) (EVar "site")) (EBinOp "::" (EApp (EApp (EVar "FunClause") (EVar "ps")) (EVar "b")) (EVar "acc"))) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "name")) (EApp (EVar "reverseL") (EVar "acc"))) (EVar "site")) (EVar "noBinderId")) (EApp (EApp (EApp (EApp (EVar "coalesceGo") (EVar "n")) (EVar "nsite")) (EListLit (EApp (EApp (EVar "FunClause") (EVar "ps")) (EVar "b")))) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "indentedBody" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "indentedBody" () (EVar "parseBracketBlock"))
(DTypeSig false "blockOrExpr" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "Expr")))
(DFunDef false "blockOrExpr" ((PList (PCon "DoExpr" (PVar "e")))) (EVar "e"))
(DFunDef false "blockOrExpr" ((PVar "stmts")) (EApp (EVar "EBlock") (EVar "stmts")))
(DTypeSig false "parseDo" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseDo" () (EApp (EApp (EVar "parseDoBlock") (EVar "TDo")) (EVar "False")))
(DTypeSig false "parseDefer" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseDefer" () (EApp (EApp (EVar "parseDoBlock") (EVar "TDefer")) (EVar "True")))
(DTypeSig false "parseDoBlock" (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "parseDoBlock" ((PVar "herald") (PVar "deferred")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "herald"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "p0")) (EApp (EApp (EVar "deferThen") (EApp (EVar "doStmtsFrom") (EVar "p0"))) (ELam ((PVar "r")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EApp (EVar "doBlockResult") (EVar "herald")) (EApp (EVar "fst") (EVar "r"))) (EApp (EVar "snd") (EVar "r"))))))))))))))
(DTypeSig false "doStmtsFrom" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "DoStmt"))))))
(DFunDef false "doStmtsFrom" ((PVar "p0")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "doStmtsLoop") (EVar "p0")))))
(DTypeSig false "doStmtsLoop" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "DoStmt"))))))
(DFunDef false "doStmtsLoop" ((PVar "lastStart")) (EApp (EApp (EVar "parseOrElse") (EVar "doStmtsCons")) (EApp (EVar "deferPure") (ETuple (EVar "lastStart") (EListLit)))))
(DTypeSig false "doStmtsCons" (TyApp (TyCon "Parser") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "DoStmt")))))
(DFunDef false "doStmtsCons" () (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "p")) (EApp (EApp (EVar "deferThen") (EVar "parseStmt")) (ELam ((PVar "ss")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "doStmtsLoop") (EVar "p"))) (ELam ((PVar "r")) (EApp (EVar "deferPure") (ETuple (EApp (EVar "fst") (EVar "r")) (EBinOp "++" (EVar "ss") (EApp (EVar "snd") (EVar "r"))))))))))))))
(DTypeSig false "doBlockResult" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Parser") (TyCon "Expr"))))))
(DFunDef false "doBlockResult" ((PVar "herald") (PVar "lastStart") (PVar "stmts")) (EMatch (EApp (EVar "last") (EVar "stmts")) (arm (PCon "Some" (PCon "DoLet" PWild PWild PWild PWild PWild)) () (EApp (EApp (EVar "fatalProblemAtP") (EApp (EVar "doEndsInBindingMsg") (EVar "herald"))) (EVar "lastStart"))) (arm (PCon "Some" (PCon "DoBind" PWild PWild)) () (EApp (EApp (EVar "fatalProblemAtP") (EApp (EVar "doEndsInBindingMsg") (EVar "herald"))) (EVar "lastStart"))) (arm PWild () (EApp (EVar "deferPure") (EApp (EApp (EVar "EDo") (EApp (EVar "isDeferTok") (EVar "herald"))) (EVar "stmts"))))))
(DTypeSig false "doEndsInBindingMsg" (TyFun (TyCon "Token") (TyCon "ParseDiagnosticKind")))
(DFunDef false "doEndsInBindingMsg" ((PVar "herald")) (EApp (EVar "BlockEndsBinding") (EApp (EVar "blockWord") (EVar "herald"))))
(DTypeSig false "blockWord" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "blockWord" ((PCon "TDefer")) (ELit (LString "defer")))
(DFunDef false "blockWord" (PWild) (ELit (LString "do")))
(DTypeSig false "parseRhsExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseRhsExpr" () (EApp (EApp (EVar "parseOrElse") (EVar "parseBracketBlock")) (EVar "parseExpr")))
(DTypeSig false "parseStmts" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt"))))
(DFunDef false "parseStmts" () (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EVar "stmtsLoop"))))
(DTypeSig false "stmtsLoop" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt"))))
(DFunDef false "stmtsLoop" () (EApp (EApp (EVar "parseOrElse") (EVar "stmtsCons")) (EApp (EVar "deferPure") (EListLit))))
(DTypeSig false "stmtsCons" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt"))))
(DFunDef false "stmtsCons" () (EApp (EApp (EVar "deferThen") (EVar "parseStmt")) (ELam ((PVar "ss")) (EApp (EApp (EVar "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "stmtsLoop")) (ELam ((PVar "rest")) (EApp (EVar "deferPure") (EBinOp "++" (EVar "ss") (EVar "rest"))))))))))
(DTypeSig false "parseStmt" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt"))))
(DFunDef false "parseStmt" () (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "p")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EApp (EVar "stmtFor") (EVar "t"))) (ELam ((PVar "ss")) (EApp (EApp (EVar "deferThen") (EApp (EApp (EVar "recordUnitStart") (ELit (LInt 1))) (EVar "p"))) (ELam (PWild) (EApp (EVar "deferPure") (EVar "ss")))))))))))
(DTypeSig false "stmtFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt")))))
(DFunDef false "stmtFor" ((PCon "TLet")) (EApp (EApp (EVar "deferThen") (EVar "parseLetStmt")) (ELam ((PVar "s")) (EApp (EVar "deferPure") (EListLit (EVar "s"))))))
(DFunDef false "stmtFor" (PWild) (EVar "parseExprStmt"))
(DTypeSig false "parseLetStmt" (TyApp (TyCon "Parser") (TyCon "DoStmt")))
(DFunDef false "parseLetStmt" () (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TLet"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "deferThen") (EApp (EVar "letKind") (EVar "t"))) (ELam ((PVar "stmt")) (EApp (EVar "deferPure") (EApp (EApp (EVar "letStmtAt") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EBinOp "+" (EVar "s") (ELit (LInt 1))))) (EVar "stmt"))))))))))))))
(DTypeSig false "letStmtAt" (TyFun (TyCon "Loc") (TyFun (TyCon "DoStmt") (TyCon "DoStmt"))))
(DFunDef false "letStmtAt" ((PVar "site") (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EVar "e")) (EVar "site")))
(DFunDef false "letStmtAt" ((PVar "site") (PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EApp (EVar "atLetSite") (EVar "site")) (EVar "e"))))
(DFunDef false "letStmtAt" (PWild (PVar "stmt")) (EVar "stmt"))
(DTypeSig false "atLetSite" (TyFun (TyCon "Loc") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "atLetSite" ((PVar "site") (PCon "ELet" PWild (PVar "r") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "site")) (EVar "r")) (EVar "p")) (EVar "e1")) (EVar "e2")))
(DFunDef false "atLetSite" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "letKind" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "DoStmt"))))
(DFunDef false "letKind" ((PCon "TMut")) (EApp (EVar "failP") (EVar "letMutRemovedMsg")))
(DFunDef false "letKind" ((PCon "TRec")) (EVar "letRecStmt"))
(DFunDef false "letKind" ((PCon "TIdent" (PVar "name"))) (EApp (EVar "letIdent") (EVar "name")))
(DFunDef false "letKind" (PWild) (EVar "letPat"))
(DTypeSig false "letRecStmt" (TyApp (TyCon "Parser") (TyCon "DoStmt")))
(DFunDef false "letRecStmt" () (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TRec"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EApp (EVar "deferThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseRhsExpr")) (ELam ((PVar "e1")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "letFunTailFor") (EVar "name")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))) (EVar "pats")) (EVar "e1")) (EVar "t")))))))))))))))))))))
(DTypeSig false "letIdent" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "DoStmt"))))
(DFunDef false "letIdent" ((PVar "name")) (EApp (EApp (EVar "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EApp (EVar "letIdentBody") (EVar "name")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EBinOp "+" (EVar "s") (ELit (LInt 1))))) (EVar "pats")) (EVar "t")))))))))))))
(DTypeSig false "letIdentBody" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "DoStmt")))))))
(DFunDef false "letIdentBody" ((PVar "name") (PVar "nameLoc") (PList) (PCon "TColon")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseRhsExpr")) (ELam ((PVar "e1")) (EApp (EApp (EApp (EApp (EVar "letIdentRest") (EVar "name")) (EVar "nameLoc")) (EListLit)) (EApp (EApp (EVar "EAnnot") (EVar "e1")) (EVar "ty"))))))))))))
(DFunDef false "letIdentBody" ((PVar "name") (PVar "nameLoc") (PVar "pats") PWild) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseRhsExpr")) (ELam ((PVar "e1")) (EApp (EApp (EApp (EApp (EVar "letIdentRest") (EVar "name")) (EVar "nameLoc")) (EVar "pats")) (EVar "e1")))))))
(DTypeSig false "letIdentRest" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "DoStmt")))))))
(DFunDef false "letIdentRest" ((PVar "name") (PVar "nameLoc") (PList) (PVar "e1")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "letTailFor") (EApp (EApp (EApp (EVar "PVar") (EVar "name")) (EVar "nameLoc")) (EVar "noBinderId"))) (EVar "e1")) (EVar "t")))))
(DFunDef false "letIdentRest" ((PVar "name") (PVar "nameLoc") (PVar "pats") (PVar "e1")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "letFunTailFor") (EVar "name")) (EVar "nameLoc")) (EVar "pats")) (EVar "e1")) (EVar "t")))))
(DTypeSig false "letFunTailFor" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "DoStmt"))))))))
(DFunDef false "letFunTailFor" ((PVar "name") (PVar "nameLoc") (PVar "pats") (PVar "e1") (PCon "TIn")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EVar "deferPure") (EApp (EVar "DoExpr") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "noDeclLoc")) (EVar "True")) (EApp (EApp (EApp (EVar "PVar") (EVar "name")) (EVar "nameLoc")) (EVar "noBinderId"))) (EApp (EApp (EVar "curryLam") (EVar "pats")) (EVar "e1"))) (EVar "e2")))))))))
(DFunDef false "letFunTailFor" ((PVar "name") (PVar "nameLoc") (PVar "pats") (PVar "e1") PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "False")) (EVar "True")) (EApp (EApp (EApp (EVar "PVar") (EVar "name")) (EVar "nameLoc")) (EVar "noBinderId"))) (EApp (EApp (EVar "curryLam") (EVar "pats")) (EVar "e1"))) (EVar "noDeclLoc"))))
(DTypeSig false "letPat" (TyApp (TyCon "Parser") (TyCon "DoStmt")))
(DFunDef false "letPat" () (EApp (EApp (EVar "deferThen") (EVar "parsePat")) (ELam ((PVar "pat")) (EApp (EApp (EVar "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseRhsExpr")) (ELam ((PVar "e1")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "letTailFor") (EVar "pat")) (EVar "e1")) (EVar "t")))))))))))
(DTypeSig false "letTailFor" (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "DoStmt"))))))
(DFunDef false "letTailFor" ((PVar "pat") (PVar "e1") (PCon "TIn")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EVar "deferPure") (EApp (EVar "DoExpr") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "noDeclLoc")) (EVar "False")) (EVar "pat")) (EVar "e1")) (EVar "e2")))))))))
(DFunDef false "letTailFor" ((PVar "pat") (PVar "e1") PWild) (EApp (EVar "deferPure") (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "False")) (EVar "False")) (EVar "pat")) (EVar "e1")) (EVar "noDeclLoc"))))
(DTypeSig false "curryLam" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "curryLam" ((PList) (PVar "body")) (EVar "body"))
(DFunDef false "curryLam" ((PCons (PVar "p") (PVar "ps")) (PVar "body")) (EApp (EApp (EVar "ELam") (EListLit (EVar "p"))) (EApp (EApp (EVar "curryLam") (EVar "ps")) (EVar "body"))))
(DTypeSig false "parseExprStmt" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt"))))
(DFunDef false "parseExprStmt" () (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "startPos")) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "exprStmtFor") (EVar "startPos")) (EVar "e")) (EVar "t")))))))))
(DTypeSig false "exprStmtFor" (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt")))))))
(DFunDef false "exprStmtFor" (PWild (PVar "e") (PCon "TLArrow")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "rhs")) (EApp (EVar "deferPure") (EApp (EApp (EVar "bindStmts") (EVar "e")) (EVar "rhs"))))))))
(DFunDef false "exprStmtFor" ((PVar "startPos") (PVar "e") (PCon "TEqual")) (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "deferThen") (EVar "parseExpr")) (ELam ((PVar "rhs")) (EApp (EApp (EVar "deferThen") (EApp (EApp (EApp (EVar "assignFromLhs") (EVar "startPos")) (EVar "e")) (EVar "rhs"))) (ELam ((PVar "s")) (EApp (EVar "deferPure") (EListLit (EVar "s"))))))))))
(DFunDef false "exprStmtFor" (PWild (PVar "e") PWild) (EApp (EVar "deferPure") (EListLit (EApp (EVar "DoExpr") (EVar "e")))))
(DTypeSig false "bindStmts" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "DoStmt")))))
(DFunDef false "bindStmts" ((PVar "lhs") (PVar "rhs")) (EMatch (EApp (EVar "stripLoc") (EVar "lhs")) (arm (PCon "EAnnot" (PVar "inner") (PVar "ty")) () (EApp (EApp (EApp (EVar "bindAnnot") (EVar "inner")) (EVar "ty")) (EVar "rhs"))) (arm PWild () (EListLit (EApp (EApp (EVar "DoBind") (EApp (EVar "exprToPat") (EVar "lhs"))) (EVar "rhs"))))))
(DTypeSig false "bindAnnot" (TyFun (TyCon "Expr") (TyFun (TyCon "Ty") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "DoStmt"))))))
(DFunDef false "bindAnnot" ((PVar "inner") (PVar "ty") (PVar "rhs")) (EMatch (EApp (EVar "stripLoc") (EVar "inner")) (arm (PCon "EVar" (PVar "x")) () (EListLit (EApp (EApp (EVar "DoBind") (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId"))) (EVar "rhs")) (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "False")) (EVar "False")) (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId"))) (EApp (EApp (EVar "EAnnot") (EApp (EVar "EVar") (EVar "x"))) (EVar "ty"))) (EVar "noDeclLoc")))) (arm (PVar "other") () (EListLit (EApp (EApp (EVar "DoBind") (EApp (EVar "exprToPat") (EVar "other"))) (EVar "rhs"))))))
(DTypeSig false "assignFromLhs" (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "DoStmt"))))))
(DFunDef false "assignFromLhs" ((PVar "startPos") (PVar "lhs") (PVar "rhs")) (EMatch (EApp (EVar "flattenFieldPath") (EVar "lhs")) (arm (PCon "Some" (PTuple (PVar "x") (PList))) () (EApp (EVar "deferPure") (EApp (EApp (EVar "DoAssign") (EVar "x")) (EVar "rhs")))) (arm (PCon "Some" (PTuple (PVar "x") (PVar "fs"))) () (EApp (EApp (EVar "fatalAtP") (EApp (EApp (EVar "fieldAssignRemovedMsg") (EVar "x")) (EVar "fs"))) (EVar "startPos"))) (arm (PCon "None") () (EApp (EVar "failP") (ELit (LString "invalid assignment target in this block"))))))
(DTypeSig false "fieldAssignRemovedMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "fieldAssignRemovedMsg" ((PVar "x") (PVar "fs")) (EBlock (DoLet false false (PVar "path") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EBinOp "::" (EVar "x") (EVar "fs")))) (DoExpr (EIf (EApp (EVar "isCtorName") (EVar "x")) (EBinOp "++" (EBinOp "++" (ELit (LString "field assignment `")) (EApp (EVar "display") (EVar "path"))) (ELit (LString " = e` has been removed; bindings are immutable, so bind the new value to a new name"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "field assignment `")) (EApp (EVar "display") (EVar "path"))) (ELit (LString " = e` has been removed; build an updated record instead, `"))) (EApp (EVar "display") (EApp (EApp (EVar "recordUpdateText") (EVar "x")) (EVar "fs")))) (ELit (LString "`")))))))
(DTypeSig false "recordUpdateText" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "recordUpdateText" (PWild (PList)) (ELit (LString "e")))
(DFunDef false "recordUpdateText" ((PVar "base") (PList (PVar "f"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "{ ")) (EApp (EVar "display") (EVar "base"))) (ELit (LString " | "))) (EApp (EVar "display") (EVar "f"))) (ELit (LString " = e }"))))
(DFunDef false "recordUpdateText" ((PVar "base") (PCons (PVar "f") (PVar "fs"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "recordUpdateText") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "base"))) (ELit (LString "."))) (EApp (EVar "display") (EVar "f"))) (ELit (LString "")))) (EVar "fs"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "{ ")) (EApp (EVar "display") (EVar "base"))) (ELit (LString " | "))) (EApp (EVar "display") (EVar "f"))) (ELit (LString " = "))) (EApp (EVar "display") (EVar "inner"))) (ELit (LString " }"))))))
(DTypeSig false "flattenFieldPath" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "flattenFieldPath" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "flattenFieldPath") (EVar "e")))
(DFunDef false "flattenFieldPath" ((PCon "EVar" (PVar "x"))) (EApp (EVar "Some") (ETuple (EVar "x") (EListLit))))
(DFunDef false "flattenFieldPath" ((PCon "EFieldAccess" (PVar "inner") (PVar "f") PWild)) (EApp (EApp (EVar "fieldPathExtend") (EApp (EVar "flattenFieldPath") (EVar "inner"))) (EVar "f")))
(DFunDef false "flattenFieldPath" (PWild) (EVar "None"))
(DTypeSig false "fieldPathExtend" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "fieldPathExtend" ((PCon "Some" (PTuple (PVar "x") (PVar "fs"))) (PVar "f")) (EApp (EVar "Some") (ETuple (EVar "x") (EBinOp "++" (EVar "fs") (EListLit (EVar "f"))))))
(DFunDef false "fieldPathExtend" ((PCon "None") PWild) (EVar "None"))
(DTypeSig false "skipNoise" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "skipNoise" () (EApp (EApp (EVar "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "skipNoiseFor") (EVar "t")))))
(DTypeSig false "skipNoiseFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "skipNoiseFor" ((PCon "TNewline")) (EVar "afterNoise"))
(DFunDef false "skipNoiseFor" ((PCon "TIndent")) (EVar "afterNoise"))
(DFunDef false "skipNoiseFor" ((PCon "TDedent")) (EVar "afterNoise"))
(DFunDef false "skipNoiseFor" (PWild) (EApp (EVar "deferPure") (ELit LUnit)))
(DTypeSig false "afterNoise" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "afterNoise" () (EApp (EApp (EVar "deferThen") (EVar "advance")) (ELam (PWild) (EVar "skipNoise"))))
(DTypeSig false "declThenNoise" (TyApp (TyCon "Parser") (TyCon "Decl")))
(DFunDef false "declThenNoise" () (EApp (EApp (EVar "deferThen") (EVar "parseDecl")) (ELam ((PVar "d")) (EApp (EApp (EVar "deferThen") (EVar "skipNoise")) (ELam (PWild) (EApp (EVar "deferPure") (EVar "d")))))))
(DTypeSig false "parseProgram" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "parseProgram" () (EApp (EApp (EVar "deferThen") (EVar "skipNoise")) (ELam (PWild) (EApp (EVar "many") (EVar "declThenNoise")))))
(DTypeSig false "declWithSpan" (TyApp (TyCon "Parser") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "declWithSpan" () (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EVar "deferThen") (EVar "parseDecl")) (ELam ((PVar "d")) (EApp (EApp (EVar "deferThen") (EVar "getPos")) (ELam ((PVar "e")) (EApp (EVar "deferPure") (ETuple (EVar "d") (EVar "s") (EVar "e"))))))))))
(DTypeSig false "spanDeclThenNoise" (TyApp (TyCon "Parser") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "spanDeclThenNoise" () (EApp (EApp (EVar "deferThen") (EVar "declWithSpan")) (ELam ((PVar "ds")) (EApp (EApp (EVar "deferThen") (EVar "skipNoise")) (ELam (PWild) (EApp (EVar "deferPure") (EVar "ds")))))))
(DTypeSig false "programWithSpans" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "programWithSpans" () (EApp (EApp (EVar "deferThen") (EVar "skipNoise")) (ELam (PWild) (EApp (EVar "many") (EVar "spanDeclThenNoise")))))
(DTypeSig true "parseWithPositions" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions"))))
(DFunDef false "parseWithPositions" ((PVar "src")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "Some" (PVar "r")) () (EVar "r")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "parse error"))))))
(DTypeSig true "parseWithPositionsLocated" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions"))))
(DFunDef false "parseWithPositionsLocated" ((PVar "src")) (EApp (EVar "parseWithPositions") (EVar "src")))
(DTypeSig true "parseWithPositionsOpt" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")))))
(DFunDef false "parseWithPositionsOpt" ((PVar "src")) (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "parse.positions")))) (DoExpr (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "tokList") (PVar "offPairList")) () (EApp (EApp (EApp (EVar "parseWithPositionsOptPairs") (EVar "src")) (EVar "tokList")) (EVar "offPairList")))))))
(DTypeSig true "parseWithPositionsOptPairs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")))))))
(DFunDef false "parseWithPositionsOptPairs" ((PVar "src") (PVar "tokList") (PVar "offPairList")) (EApp (EApp (EVar "map") (ELam ((PVar "parsed")) (ETuple (EApp (EVar "parsedDecls") (EVar "parsed")) (EApp (EVar "parsedPositions") (EVar "parsed"))))) (EApp (EApp (EApp (EVar "parseSourceSyntaxPairs") (EVar "src")) (EVar "tokList")) (EVar "offPairList"))))
(DTypeSig true "parseSourceSyntaxPairs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "Option") (TyCon "ParsedSource"))))))
(DFunDef false "parseSourceSyntaxPairs" ((PVar "src") (PVar "tokList") (PVar "offPairList")) (EBlock (DoLet false false (PVar "ctx") (EApp (EApp (EApp (EApp (EVar "newParseContextWith") (EVar "LocatedSyntax")) (EVar "src")) (EApp (EVar "arrayFromList") (EVar "tokList"))) (EApp (EVar "arrayFromList") (EVar "offPairList")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "programWithSpans")) (ELit (LInt 0))) (arm (PCon "POk" (PVar "spans") (PVar "pos")) ((GBool (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "pos"))))) (EApp (EVar "Some") (EApp (EApp (EVar "publishSource") (EVar "ctx")) (EVar "spans")))) (arm PWild () (EVar "None"))))))
(DTypeSig false "publishSource" (TyFun (TyCon "ParseContext") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyCon "ParsedSource"))))
(DFunDef false "publishSource" ((PVar "ctx") (PVar "spans")) (EBlock (DoLet false false (PTuple (PVar "commas") (PVar "units")) (EApp (EVar "contextCues") (EVar "ctx"))) (DoExpr (EApp (EApp (EApp (EVar "makeParsedSource") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "d") (PVar "_s") (PVar "_e"))) (EVar "d"))) (EVar "spans"))) (EApp (EApp (EApp (EApp (EVar "positionsFromSpans") (EApp (EVar "contextLineStarts") (EVar "ctx"))) (EApp (EVar "contextTokens") (EVar "ctx"))) (EApp (EVar "contextOffsets") (EVar "ctx"))) (EVar "spans"))) (EApp (EApp (EVar "makeParseMetadata") (EVar "commas")) (EVar "units"))))))
(DTypeSig true "parseSource" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseDiagnostic")) (TyCon "ParsedSource"))))
(DFunDef false "parseSource" ((PVar "src")) (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "toks") (PVar "pairs")) () (EApp (EApp (EApp (EVar "parseSourcePairs") (EVar "src")) (EVar "toks")) (EVar "pairs")))))
(DTypeSig true "parseSourcePairs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyApp (TyCon "Result") (TyCon "ParseDiagnostic")) (TyCon "ParsedSource"))))))
(DFunDef false "parseSourcePairs" ((PVar "src") (PVar "tokList") (PVar "offPairs")) (EApp (EApp (EApp (EApp (EVar "parseSourcePairsWithIndex") (EVar "src")) (EVar "tokList")) (EVar "offPairs")) (ELam ((PLit LUnit)) (EApp (EVar "indexSource") (EVar "src")))))
(DTypeSig true "parseSourcePairsWithIndex" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyFun (TyCon "Unit") (TyCon "SourceIndex")) (TyApp (TyApp (TyCon "Result") (TyCon "ParseDiagnostic")) (TyCon "ParsedSource")))))))
(DFunDef false "parseSourcePairsWithIndex" ((PVar "src") (PVar "tokList") (PVar "offPairs") (PVar "index")) (EBlock (DoLet false false (PVar "toks") (EApp (EVar "arrayFromList") (EVar "tokList"))) (DoLet false false (PVar "offs") (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "offPairs")))) (DoLet false false (PVar "ends") (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (EVar "snd")) (EVar "offPairs")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "prescanError") (EVar "src")) (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "parseErrorDiagnostic") (EVar "e")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "ctx") (EApp (EApp (EApp (EVar "newParseContext") (EVar "src")) (EVar "toks")) (EApp (EVar "arrayFromList") (EVar "offPairs")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "programWithSpans")) (ELit (LInt 0))) (arm (PCon "POk" (PVar "spans") (PVar "pos")) ((GBool (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos"))))) (EApp (EVar "Ok") (EApp (EApp (EVar "publishSource") (EVar "ctx")) (EVar "spans")))) (arm (PCon "POk" PWild (PVar "pos")) () (EApp (EVar "Err") (EApp (EVar "parseErrorDiagnostic") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "deepenLeftover") (EVar "ctx")) (EVar "src")) (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EApp (EVar "stringLength") (EVar "src"))) (EVar "pos"))))) (arm (PCon "PErr" (PVar "f") (PVar "pos")) () (EApp (EVar "Err") (EApp (EVar "parseErrorDiagnostic") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EApp (EVar "stringLength") (EVar "src"))) (EApp (EVar "failProblem") (EVar "f"))) (EVar "pos"))))) (arm (PCon "PFatal" (PVar "f") (PVar "pos")) () (EApp (EVar "Err") (EApp (EVar "parseErrorDiagnostic") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EApp (EVar "stringLength") (EVar "src"))) (EApp (EVar "failProblem") (EVar "f"))) (EVar "pos")))))))))))))
(DTypeSig true "parseDeclAt" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyApp (TyCon "PR") (TyCon "Decl")))))
(DFunDef false "parseDeclAt" ((PVar "ctx") (PVar "pos")) (EBlock (DoLet false false (PVar "saved") (EApp (EVar "mark") (EVar "ctx"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "parseDecl")) (EVar "pos")) (arm (PAs "r" (PCon "POk" PWild PWild)) () (EVar "r")) (arm (PVar "r") () (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EVar "r"))))))))
(DTypeSig false "resultDecls" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "PR") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "resultDecls" (PWild (PCon "PErr" PWild PWild)) (EApp (EVar "panic") (ELit (LString "parse error"))))
(DFunDef false "resultDecls" (PWild (PCon "PFatal" PWild PWild)) (EApp (EVar "panic") (ELit (LString "parse error"))))
(DFunDef false "resultDecls" ((PVar "toks") (PCon "POk" (PVar "ds") (PVar "pos"))) (EIf (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos"))) (EVar "ds") (EIf (EVar "otherwise") (EApp (EVar "panic") (ELit (LString "parse error"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "parse" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "parse" ((PVar "src")) (EBlock (DoLet false false (PVar "toks") (EApp (EVar "arrayFromList") (EApp (EVar "tokenize") (EVar "src")))) (DoExpr (EMatch (EApp (EApp (EVar "firstLexError") (EVar "toks")) (ELit (LInt 0))) (arm (PCon "Some" (PTuple PWild (PVar "kind"))) () (EApp (EVar "panic") (EApp (EVar "renderParseProblem") (EVar "kind")))) (arm (PCon "None") () (EApp (EApp (EVar "resultDecls") (EVar "toks")) (EApp (EApp (EApp (EVar "runP") (EVar "parseProgram")) (EVar "toks")) (ELit (LInt 0)))))))))
(DTypeSig true "parseLocated" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "parseLocated" ((PVar "src")) (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "tokList") (PVar "offPairs")) () (EBlock (DoLet false false (PVar "toks") (EApp (EVar "arrayFromList") (EVar "tokList"))) (DoLet false false (PVar "ctx") (EApp (EApp (EApp (EApp (EVar "newParseContextWith") (EVar "LocatedSyntax")) (EVar "src")) (EVar "toks")) (EApp (EVar "arrayFromList") (EVar "offPairs")))) (DoExpr (EApp (EApp (EVar "resultDecls") (EVar "toks")) (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "parseProgram")) (ELit (LInt 0)))))))))
(DTypeSig false "resultDeclsResult" (TyFun (TyCon "ParseContext") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyCon "SourceIndex")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "PR") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl"))))))))))))
(DFunDef false "resultDeclsResult" (PWild PWild (PVar "index") (PVar "toks") (PVar "offs") (PVar "ends") (PVar "srcLen") (PCon "PErr" (PVar "f") (PVar "pos"))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "failProblem") (EVar "f"))) (EVar "pos"))))
(DFunDef false "resultDeclsResult" (PWild PWild (PVar "index") (PVar "toks") (PVar "offs") (PVar "ends") (PVar "srcLen") (PCon "PFatal" (PVar "f") (PVar "pos"))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "failProblem") (EVar "f"))) (EVar "pos"))))
(DFunDef false "resultDeclsResult" ((PVar "ctx") (PVar "src") (PVar "index") (PVar "toks") (PVar "offs") (PVar "ends") (PVar "srcLen") (PCon "POk" (PVar "ds") (PVar "pos"))) (EIf (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos"))) (EApp (EVar "Ok") (EVar "ds")) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "deepenLeftover") (EVar "ctx")) (EVar "src")) (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EVar "pos"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "deepenLeftover" (TyFun (TyCon "ParseContext") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyCon "SourceIndex")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "ParseError"))))))))))
(DFunDef false "deepenLeftover" ((PVar "ctx") (PVar "src") (PVar "index") (PVar "toks") (PVar "offs") (PVar "ends") (PVar "srcLen") (PVar "pos")) (EBlock (DoLet false false (PVar "saved") (EApp (EVar "mark") (EVar "ctx"))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "parseDecl")) (EVar "pos"))) (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EMatch (EVar "result") (arm (PCon "PFatal" (PVar "f") (PVar "pos2")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "failProblem") (EVar "f"))) (EVar "pos2"))) (arm (PCon "PErr" (PVar "f") (PVar "pos2")) ((GBool (EBinOp ">" (EVar "pos2") (EVar "pos")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "failProblem") (EVar "f"))) (EVar "pos2"))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "GenericParse") (EApp (EApp (EApp (EApp (EApp (EVar "unexpectedLeftoverMsg") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "pos")))) (EVar "pos")))))))
(DTypeSig false "mkLocated" (TyFun (TyFun (TyCon "Unit") (TyCon "SourceIndex")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "ParseDiagnosticKind") (TyFun (TyCon "Int") (TyCon "ParseError")))))))))
(DFunDef false "mkLocated" ((PVar "index") (PVar "toks") (PVar "offs") (PVar "ends") (PVar "srcLen") (PVar "kind") (PVar "pos")) (EApp (EVar "ParseError") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EVar "kind")) (EVar "pos"))))
(DTypeSig false "leadingIndentAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "leadingIndentAt" ((PVar "src") (PVar "offset")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "lineStart") (EApp (EApp (EVar "leadingIndentLineStart") (EVar "chars")) (EBinOp "-" (EVar "offset") (ELit (LInt 1))))) (DoExpr (EIf (EApp (EApp (EApp (EVar "leadingIndentAllBlank") (EVar "chars")) (EVar "lineStart")) (EVar "offset")) (EApp (EVar "Some") (EBinOp "-" (EVar "offset") (EVar "lineStart"))) (EVar "None")))))
(DTypeSig false "leadingIndentLineStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "leadingIndentLineStart" ((PVar "chars") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (ELit (LInt 0)) (EIf (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")) (ELit (LChar "\n"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")) (ELit (LChar "\r")))) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EVar "otherwise") (EApp (EApp (EVar "leadingIndentLineStart") (EVar "chars")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "leadingIndentAllBlank" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "leadingIndentAllBlank" ((PVar "chars") (PVar "i") (PVar "limit")) (EIf (EBinOp ">=" (EVar "i") (EVar "limit")) (EVar "True") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")) (arm (PLit (LChar " ")) () (EApp (EApp (EApp (EVar "leadingIndentAllBlank") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "limit"))) (arm (PLit (LChar "\t")) () (EApp (EApp (EApp (EVar "leadingIndentAllBlank") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "limit"))) (arm PWild () (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "unexpectedLeftoverMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))))
(DFunDef false "unexpectedLeftoverMsg" ((PVar "src") (PVar "toks") (PVar "offs") (PVar "srcLen") (PVar "pos")) (EBlock (DoLet false false (PVar "base") (EApp (EVar "unexpectedTokenMsg") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos")))) (DoLet false false (PVar "offset") (EApp (EApp (EApp (EApp (EVar "locateOffset") (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "pos"))) (DoExpr (EMatch (EApp (EApp (EVar "leadingIndentAt") (EVar "src")) (EVar "offset")) (arm (PCon "Some" (PVar "col")) ((GBool (EBinOp ">" (EVar "col") (ELit (LInt 0))))) (EApp (EApp (EApp (EVar "leadingIndentMsg") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos"))) (EVar "base")) (EVar "col"))) (arm PWild () (EApp (EApp (EVar "trailingArrowLeftoverMsg") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos"))) (EVar "base")))))))
(DTypeSig false "trailingArrowLeftoverMsg" (TyFun (TyCon "Token") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "trailingArrowLeftoverMsg" ((PCon "TArrow") (PVar "base")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "base"))) (ELit (LString "; a later line of this type signature dedents past its first continuation line, so indent every wrapped line at least that far"))))
(DFunDef false "trailingArrowLeftoverMsg" (PWild (PVar "base")) (EVar "base"))
(DTypeSig false "leadingIndentMsg" (TyFun (TyCon "Token") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "leadingIndentMsg" ((PCon "TArrow") (PVar "base") (PVar "col")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "base"))) (ELit (LString "; a line cannot start with `->`, so put it at the end of the previous line, as in `f : Int ->` then an indented `Int`"))))
(DFunDef false "leadingIndentMsg" (PWild (PVar "base") (PVar "col")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "base"))) (ELit (LString "; this line is indented to column "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "col")))) (ELit (LString ", which matches no enclosing block"))))
(DTypeSig false "firstLexError" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "ParseDiagnosticKind"))))))
(DFunDef false "firstLexError" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "None") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (arm (PCon "TLexError" (PVar "msg")) () (EApp (EVar "Some") (ETuple (EVar "i") (EVar "msg")))) (arm PWild () (EApp (EApp (EVar "firstLexError") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "parseResult" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "parseResult" ((PVar "src")) (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "tokList") (PVar "offList")) () (EApp (EApp (EApp (EApp (EVar "parseResultWith") (EVar "UnlocatedChecked")) (EVar "src")) (EVar "tokList")) (EVar "offList")))))
(DTypeSig true "parseResultPairs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "parseResultPairs" ((PVar "src") (PVar "tokList") (PVar "offPairs")) (EApp (EApp (EApp (EApp (EVar "parseResultWith") (EVar "UnlocatedChecked")) (EVar "src")) (EVar "tokList")) (EVar "offPairs")))
(DTypeSig true "parseLocatedResult" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "parseLocatedResult" ((PVar "src")) (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "tokList") (PVar "offPairs")) () (EApp (EApp (EApp (EApp (EVar "parseResultWith") (EVar "LocatedChecked")) (EVar "src")) (EVar "tokList")) (EVar "offPairs")))))
(DTypeSig true "prescanError" (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyCon "SourceIndex")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "ParseError"))))))))
(DFunDef false "prescanError" ((PVar "src") (PVar "index") (PVar "toks") (PVar "offs") (PVar "ends")) (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "parse.prescan")))) (DoExpr (EApp (EApp (EVar "map") (EVar "ParseError")) (EApp (EApp (EApp (EApp (EApp (EVar "prescanDiagnostic") (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EApp (EVar "stringLength") (EVar "src")))))))
(DTypeSig true "prescanErrorPairs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "Option") (TyCon "ParseError"))))))
(DFunDef false "prescanErrorPairs" ((PVar "src") (PVar "tokList") (PVar "offPairs")) (EApp (EApp (EApp (EApp (EVar "prescanErrorPairsWithIndex") (EVar "src")) (EVar "tokList")) (EVar "offPairs")) (ELam ((PLit LUnit)) (EApp (EVar "indexSource") (EVar "src")))))
(DTypeSig true "prescanErrorPairsWithIndex" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyFun (TyCon "Unit") (TyCon "SourceIndex")) (TyApp (TyCon "Option") (TyCon "ParseError")))))))
(DFunDef false "prescanErrorPairsWithIndex" ((PVar "src") (PVar "tokList") (PVar "offPairs") (PVar "index")) (EApp (EApp (EApp (EApp (EApp (EVar "prescanError") (EVar "src")) (EVar "index")) (EApp (EVar "arrayFromList") (EVar "tokList"))) (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "offPairs")))) (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (EVar "snd")) (EVar "offPairs")))))
(DTypeSig false "parseResultWith" (TyFun (TyCon "ParseMode") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "parseResultWith" ((PVar "mode") (PVar "src") (PVar "tokList") (PVar "offList")) (EBlock (DoLet false false (PVar "toks") (EApp (EVar "arrayFromList") (EVar "tokList"))) (DoLet false false (PVar "offs") (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "offList")))) (DoLet false false (PVar "ends") (EApp (EVar "arrayFromList") (EApp (EApp (EVar "map") (EVar "snd")) (EVar "offList")))) (DoLet false true (PVar "index") (ELam ((PLit LUnit)) (EApp (EVar "indexSource") (EVar "src")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "prescanError") (EVar "src")) (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "ctx") (EApp (EApp (EApp (EApp (EVar "newParseContextWith") (EVar "mode")) (EVar "src")) (EVar "toks")) (EApp (EVar "arrayFromList") (EVar "offList")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resultDeclsResult") (EVar "ctx")) (EVar "src")) (EVar "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EApp (EVar "stringLength") (EVar "src"))) (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "parseProgram")) (ELit (LInt 0)))))))))))
# MARK
(DUse false (UseGroup ("frontend" "parse_locate") ((mem "locateOffset" false) (mem "locateTokenDiagnostic" false))))
(DUse false (UseGroup ("frontend" "parse_hints") ((mem "prescanDiagnostic" false) (mem "matchContinuationHint" false) (mem "letMutRemovedMsg" false) (mem "isLineEndTok" false) (mem "isBracketOpenTok" false) (mem "isBracketCloseTok" false))))
(DUse false (UseGroup ("frontend" "parse_engine") ((mem "PR" true) (mem "PFail" true) (mem "ParserE" true) (mem "Parser" false) (mem "ParseContext" false) (mem "ParseMark" false) (mem "ParseMode" true) (mem "newParseContext" false) (mem "newParseContextWith" false) (mem "runPWith" false) (mem "runP" false) (mem "contextTokens" false) (mem "contextOffsets" false) (mem "contextLineStarts" false) (mem "contextHasTab" false) (mem "contextP" false) (mem "getPos" false) (mem "peekTok" false) (mem "peekP" false) (mem "peek2P" false) (mem "peek3P" false) (mem "advance" false) (mem "emit" false) (mem "expectTok" false) (mem "failP" false) (mem "fatalP" false) (mem "fatalProblemAtP" false) (mem "fatalAtP" false) (mem "failProblem" false) (mem "orElse" false "parseOrElse") (mem "many" false) (mem "sepBy1" false) (mem "mark" false) (mem "rewind" false) (mem "locOfSpan" false) (mem "spanLoc" false) (mem "depthOf" false) (mem "withDepth" false) (mem "recordTrailingComma" false) (mem "recordUnitStart" false) (mem "forgetLatestUnitStart" false) (mem "contextCues" false) (mem "unexpectedTokenMsg" false))))
(DUse false (UseGroup ("frontend" "parse_result") ((mem "ParsedSource" false) (mem "makeParsedSource" false) (mem "makeParseMetadata" false) (mem "parsedDecls" false) (mem "parsedPositions" false))))
(DUse true (UseGroup ("frontend" "parse_result") ((mem "ParseError" true) (mem "parseErrorDiagnostic" false) (mem "parseErrorLine" false) (mem "parseErrorCol" false) (mem "parseErrorMessage" false))))
(DUse false (UseGroup ("frontend" "parse_diagnostic") ((mem "ParseDiagnostic" false) (mem "ParseDiagnosticKind" true) (mem "renderParseProblem" false))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "indexSource" false))))
(DUse false (UseGroup ("support" "stage_count") ((mem "stageBump" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "noBinderId" false) (mem "unminted" false) (mem "negateLiteral" false) (mem "DeriveRef" true) (mem "Lit" true) (mem "Ty" true) (mem "EffAtomTy" true) (mem "EffParamTy" true) (mem "effAtomAt" false) (mem "effectDeclUnstamped" false) (mem "KindAnn" true) (mem "Constraint" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "Loc" true) (mem "noDeclLoc" false) (mem "UseMember" true) (mem "UsePath" true) (mem "useMemberOrigin" false) (mem "useMemberAlias" false) (mem "qualifiedLocal" false) (mem "tyConUnresolved" false) (mem "tyConBuiltin" false) (mem "dDataUnresolved" false) (mem "externDataUnresolved" false) (mem "kindAnnSource" false) (mem "kindAuthorityUnstamped" false) (mem "dTypeAliasUnresolved" false) (mem "dNewtypeUnresolved" false) (mem "dInterfaceUnresolved" false) (mem "setDeclNameLoc" false) (mem "dImplUnresolved" false) (mem "constraintUnresolved" false) (mem "superUnresolved" false) (mem "requireUnresolved" false) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true) (mem "ExternDecl" true) (mem "ExternBind" true) (mem "Attr" true) (mem "Route" true))))
(DUse false (UseGroup ("frontend" "lexer") ((mem "Token" true) (mem "tokenize" false) (mem "tokenizeWithOffsets" false) (mem "tokenizeWithOffsetPairs" false) (mem "offsetToLineCol" false) (mem "lineStartsOf" false) (mem "offsetToLineColFast" false) (mem "isThenTok" false))))
(DUse true (UseGroup ("frontend" "parse_positions") ((mem "DeclPos" true) (mem "Positions" true) (mem "positionsDecls" false) (mem "positionsVariantLines" false) (mem "positionsLastContentLine" false) (mem "positionsChainLines" false) (mem "declPosLine" false) (mem "declPosEndLine" false) (mem "declPosNameLoc" false) (mem "declPosChildLocs" false))))
(DUse false (UseGroup ("frontend" "parse_positions") ((mem "positionsFromSpans" false))))
(DUse false (UseGroup ("frontend" "lex_token") ((mem "isColonTok" false) (mem "isConsTok" false) (mem "isDedentTok" false) (mem "isDeferTok" false) (mem "isEofTok" false) (mem "isEqualTok" false) (mem "isExportTok" false) (mem "isImplTok" false) (mem "isInTok" false) (mem "isIndentTok" false) (mem "isLBraceTok" false) (mem "isLetTok" false) (mem "isNewlineTok" false) (mem "isOfTok" false) (mem "isPipeTok" false) (mem "isPublicTok" false) (mem "isRBraceTok" false) (mem "isRequiresTok" false) (mem "isStarTok" false) (mem "isOpenDelim" false) (mem "isCloseDelim" false) (mem "isTStringTok" false) (mem "isTUpperTok" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "joinWith" false))))
(DUse false (UseGroup ("list") ((mem "last" false))))
(DUse false (UseGroup ("support" "char") ((mem "isUpper" false))))
(DTypeSig false "located" (TyFun (TyApp (TyCon "Parser") (TyCon "Expr")) (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "located" ((PVar "p")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "p")) (ELam ((PVar "e")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "spanLoc") (EVar "s")) (EVar "q"))) (ELam ((PVar "loc")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "ELoc") (EVar "loc")) (EVar "e"))))))))))))
(DTypeSig false "identNameP" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "identNameP" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "identNameFor") (EVar "t")))))
(DTypeSig false "identNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "identNameFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "identNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected an identifier"))))
(DTypeSig false "optTrailingComma" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "optTrailingComma" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "optTrailingCommaFor") (EVar "t")))))
(DTypeSig false "optTrailingCommaFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "optTrailingCommaFor" ((PCon "TComma")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "p")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "recordTrailingComma") (EVar "p")))))))
(DFunDef false "optTrailingCommaFor" (PWild) (EApp (EMethodRef "deferPure") (ELit LUnit)))
(DTypeSig false "optTrailingCommaTuple" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "optTrailingCommaTuple" ((PList PWild)) (EApp (EMethodRef "deferPure") (ELit LUnit)))
(DFunDef false "optTrailingCommaTuple" (PWild) (EVar "optTrailingComma"))
(DTypeSig false "skipNewlines" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "skipNewlines" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "skipNlFor") (EVar "t")))))
(DTypeSig false "skipNlFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "skipNlFor" ((PCon "TNewline")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EVar "skipNewlines"))))
(DFunDef false "skipNlFor" (PWild) (EApp (EMethodRef "deferPure") (ELit LUnit)))
(DTypeSig false "parseExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseExpr" () (EApp (EApp (EMethodRef "deferThen") (EVar "parseAssign")) (ELam ((PVar "e")) (EApp (EVar "annotOpt") (EVar "e")))))
(DTypeSig false "parseAssign" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAssign" () (EApp (EApp (EMethodRef "deferThen") (EVar "parseLam")) (ELam ((PVar "e")) (EApp (EVar "assignOpt") (EVar "e")))))
(DTypeSig false "assignTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "assignTail" ((PVar "lhs")) (EApp (EVar "located") (EApp (EVar "assignTailRaw") (EVar "lhs"))))
(DTypeSig false "assignTailRaw" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "assignTailRaw" ((PVar "lhs")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TColonEq"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseRhsExpr")) (ELam ((PVar "rhs")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString ":="))) (EVar "lhs")) (EVar "rhs")) (EVar "unminted"))))))))
(DTypeSig false "annotOpt" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "annotOpt" ((PVar "e")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "pos")) (arm (PCon "TColon") () (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "annotTail") (EVar "e"))) (EApp (EMethodRef "deferPure") (EVar "e")))) (EVar "pos"))) (arm PWild () (EApp (EApp (EVar "POk") (EVar "e")) (EVar "pos")))))))
(DTypeSig false "assignOpt" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "assignOpt" ((PVar "e")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "pos")) (arm (PCon "TColonEq") () (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "assignTail") (EVar "e"))) (EApp (EMethodRef "deferPure") (EVar "e")))) (EVar "pos"))) (arm PWild () (EApp (EApp (EVar "POk") (EVar "e")) (EVar "pos")))))))
(DTypeSig false "lamOpt" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "lamOpt" ((PVar "e")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "pos")) (arm (PCon "TFatArrow") () (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "lamTail") (EVar "e"))) (EApp (EMethodRef "deferPure") (EVar "e")))) (EVar "pos"))) (arm PWild () (EApp (EApp (EVar "POk") (EVar "e")) (EVar "pos")))))))
(DTypeSig false "annotTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "annotTail" ((PVar "e")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseTy")) (ELam ((PVar "t")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "EAnnot") (EVar "e")) (EVar "t"))))))))
(DTypeSig false "parseLam" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseLam" () (EApp (EApp (EMethodRef "deferThen") (EVar "parsePipe")) (ELam ((PVar "e")) (EApp (EVar "lamOpt") (EVar "e")))))
(DTypeSig false "lamTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "lamTail" ((PVar "e")) (EApp (EVar "located") (EApp (EVar "lamTailRaw") (EVar "e"))))
(DTypeSig false "lamTailRaw" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "lamTailRaw" ((PVar "e")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TFatArrow"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseRhsExpr")) (ELam ((PVar "body")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "ELam") (EApp (EVar "exprToParams") (EVar "e"))) (EVar "body"))))))))
(DTypeSig false "exprToParams" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Pat"))))
(DFunDef false "exprToParams" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "exprToParams") (EVar "e")))
(DFunDef false "exprToParams" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EVar "appToParams") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))))
(DFunDef false "exprToParams" ((PVar "e")) (EListLit (EApp (EVar "exprToPat") (EVar "e"))))
(DTypeSig false "appToParams" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Pat"))))
(DFunDef false "appToParams" ((PVar "app")) (EApp (EApp (EVar "paramsForHead") (EApp (EVar "spineHead") (EVar "app"))) (EVar "app")))
(DTypeSig false "paramsForHead" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "paramsForHead" ((PCon "EVar" (PVar "c")) (PVar "app")) (EApp (EApp (EVar "paramsForCtor") (EVar "c")) (EVar "app")))
(DFunDef false "paramsForHead" (PWild (PVar "app")) (EApp (EApp (EMethodRef "map") (EVar "exprToPat")) (EApp (EVar "spineList") (EVar "app"))))
(DTypeSig false "paramsForCtor" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Pat")))))
(DFunDef false "paramsForCtor" ((PVar "c") (PVar "app")) (EIf (EApp (EVar "isCtorName") (EVar "c")) (EListLit (EApp (EVar "exprToPat") (EVar "app"))) (EIf (EVar "otherwise") (EApp (EApp (EMethodRef "map") (EVar "exprToPat")) (EApp (EVar "spineList") (EVar "app"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "spineHead" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "spineHead" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "spineHead") (EVar "f")))
(DFunDef false "spineHead" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "spineHead") (EVar "e")))
(DFunDef false "spineHead" ((PVar "e")) (EVar "e"))
(DTypeSig false "spineList" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "spineList" ((PVar "e")) (EApp (EApp (EVar "spineOnto") (EVar "e")) (EListLit)))
(DTypeSig false "spineOnto" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "spineOnto" ((PCon "ELoc" PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EVar "spineOnto") (EVar "e")) (EVar "acc")))
(DFunDef false "spineOnto" ((PCon "EApp" (PVar "f") (PVar "x")) (PVar "acc")) (EApp (EApp (EVar "spineOnto") (EVar "f")) (EBinOp "::" (EVar "x") (EVar "acc"))))
(DFunDef false "spineOnto" ((PVar "e") (PVar "acc")) (EBinOp "::" (EVar "e") (EVar "acc")))
(DTypeSig false "exprToPat" (TyFun (TyCon "Expr") (TyCon "Pat")))
(DFunDef false "exprToPat" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "exprToPat") (EVar "e")))
(DFunDef false "exprToPat" ((PCon "EVar" (PLit (LString "_")))) (EVar "PWild"))
(DFunDef false "exprToPat" ((PCon "EVar" (PVar "x"))) (EApp (EVar "ctorOrVar") (EVar "x")))
(DFunDef false "exprToPat" ((PCon "ELit" (PVar "l"))) (EApp (EVar "PLit") (EVar "l")))
(DFunDef false "exprToPat" ((PCon "ENumLit" (PVar "n") PWild PWild)) (EApp (EVar "PLit") (EApp (EVar "LInt") (EVar "n"))))
(DFunDef false "exprToPat" ((PCon "EWideLit" (PVar "hi") (PVar "lo") PWild PWild)) (EApp (EVar "PLit") (EApp (EApp (EVar "LU64") (EVar "hi")) (EVar "lo"))))
(DFunDef false "exprToPat" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "PTuple") (EApp (EApp (EMethodRef "map") (EVar "exprToPat")) (EVar "es"))))
(DFunDef false "exprToPat" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "PList") (EApp (EApp (EMethodRef "map") (EVar "exprToPat")) (EVar "es"))))
(DFunDef false "exprToPat" ((PCon "EBinOp" (PLit (LString "::")) (PVar "a") (PVar "b") PWild)) (EApp (EApp (EVar "PCons") (EApp (EVar "exprToPat") (EVar "a"))) (EApp (EVar "exprToPat") (EVar "b"))))
(DFunDef false "exprToPat" ((PCon "ESection" (PCon "SecLeft" (PVar "a") (PLit (LString "::"))))) (EApp (EApp (EVar "PCons") (EApp (EVar "exprToPat") (EVar "a"))) (EVar "PWild")))
(DFunDef false "exprToPat" ((PCon "EAsPat" (PVar "x") (PVar "sub"))) (EApp (EApp (EApp (EApp (EVar "PAs") (EVar "x")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId")) (EApp (EVar "exprToPat") (EMethodRef "sub"))))
(DFunDef false "exprToPat" ((PCon "EOrPat" (PVar "es"))) (EApp (EVar "orPatOf") (EApp (EApp (EMethodRef "map") (EVar "exprToPat")) (EVar "es"))))
(DFunDef false "exprToPat" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EVar "appToPat") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))))
(DFunDef false "exprToPat" (PWild) (EVar "PWild"))
(DTypeSig false "orPatOf" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Pat")))
(DFunDef false "orPatOf" ((PList (PVar "p"))) (EVar "p"))
(DFunDef false "orPatOf" ((PVar "ps")) (EApp (EVar "POr") (EApp (EApp (EDictApp "flatMap") (EVar "orAlts")) (EVar "ps"))))
(DTypeSig false "orAlts" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "Pat"))))
(DFunDef false "orAlts" ((PCon "POr" (PVar "qs"))) (EVar "qs"))
(DFunDef false "orAlts" ((PVar "p")) (EListLit (EVar "p")))
(DTypeSig false "ctorOrVar" (TyFun (TyCon "String") (TyCon "Pat")))
(DFunDef false "ctorOrVar" ((PVar "x")) (EIf (EApp (EVar "isCtorName") (EVar "x")) (EApp (EApp (EVar "PCon") (EVar "x")) (EListLit)) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "appToPat" (TyFun (TyCon "Expr") (TyCon "Pat")))
(DFunDef false "appToPat" ((PVar "app")) (EApp (EApp (EVar "appToPatH") (EApp (EVar "spineHead") (EVar "app"))) (EApp (EVar "spineList") (EVar "app"))))
(DTypeSig false "appToPatH" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Pat"))))
(DFunDef false "appToPatH" ((PCon "EVar" (PVar "c")) (PVar "spine")) (EApp (EApp (EVar "appToPatCtor") (EVar "c")) (EVar "spine")))
(DFunDef false "appToPatH" (PWild PWild) (EVar "PWild"))
(DTypeSig false "appToPatCtor" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Pat"))))
(DFunDef false "appToPatCtor" ((PVar "c") (PVar "spine")) (EIf (EApp (EVar "isCtorName") (EVar "c")) (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EMethodRef "map") (EVar "exprToPat")) (EApp (EVar "dropFirst") (EVar "spine")))) (EIf (EVar "otherwise") (EVar "PWild") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "dropFirst" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "dropFirst" ((PList)) (EListLit))
(DFunDef false "dropFirst" ((PCons PWild (PVar "xs"))) (EVar "xs"))
(DTypeSig false "isCtorName" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isCtorName" ((PVar "s")) (EApp (EVar "isCtorChars") (EApp (EVar "stringToChars") (EVar "s"))))
(DTypeSig false "isCtorChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyCon "Bool")))
(DFunDef false "isCtorChars" ((PVar "cs")) (EIf (EBinOp "==" (EApp (EVar "arrayLength") (EVar "cs")) (ELit (LInt 0))) (EVar "False") (EIf (EVar "otherwise") (EApp (EVar "isUpper") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "cs"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "stripLoc" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "stripLoc" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "stripLoc") (EVar "e")))
(DFunDef false "stripLoc" ((PVar "e")) (EVar "e"))
(DTypeSig false "stripLoc1" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "stripLoc1" ((PCon "ELoc" PWild (PVar "e"))) (EVar "e"))
(DFunDef false "stripLoc1" ((PVar "e")) (EVar "e"))
(DTypeSig false "binLevelOf" (TyFun (TyCon "Token") (TyCon "Int")))
(DFunDef false "binLevelOf" ((PCon "TPipeRight")) (ELit (LInt 1)))
(DFunDef false "binLevelOf" ((PCon "TRCompose")) (ELit (LInt 2)))
(DFunDef false "binLevelOf" ((PCon "TLCompose")) (ELit (LInt 2)))
(DFunDef false "binLevelOf" ((PCon "TOr")) (ELit (LInt 3)))
(DFunDef false "binLevelOf" ((PCon "TAnd")) (ELit (LInt 4)))
(DFunDef false "binLevelOf" ((PCon "TEqEq")) (ELit (LInt 5)))
(DFunDef false "binLevelOf" ((PCon "TNeq")) (ELit (LInt 5)))
(DFunDef false "binLevelOf" ((PCon "TLt")) (ELit (LInt 5)))
(DFunDef false "binLevelOf" ((PCon "TGt")) (ELit (LInt 5)))
(DFunDef false "binLevelOf" ((PCon "TLeq")) (ELit (LInt 5)))
(DFunDef false "binLevelOf" ((PCon "TGeq")) (ELit (LInt 5)))
(DFunDef false "binLevelOf" ((PCon "TCons")) (ELit (LInt 6)))
(DFunDef false "binLevelOf" ((PCon "TPlusPlus")) (ELit (LInt 7)))
(DFunDef false "binLevelOf" ((PCon "TPlus")) (ELit (LInt 8)))
(DFunDef false "binLevelOf" ((PCon "TMinus")) (ELit (LInt 8)))
(DFunDef false "binLevelOf" ((PCon "TMinusTight")) (ELit (LInt 8)))
(DFunDef false "binLevelOf" ((PCon "TStar")) (ELit (LInt 9)))
(DFunDef false "binLevelOf" ((PCon "TSlash")) (ELit (LInt 9)))
(DFunDef false "binLevelOf" ((PCon "TMod")) (ELit (LInt 9)))
(DFunDef false "binLevelOf" (PWild) (ELit (LInt 0)))
(DTypeSig false "binOpName" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "binOpName" ((PCon "TPipeRight")) (ELit (LString "|>")))
(DFunDef false "binOpName" ((PCon "TRCompose")) (ELit (LString ">>")))
(DFunDef false "binOpName" ((PCon "TLCompose")) (ELit (LString "<<")))
(DFunDef false "binOpName" ((PCon "TOr")) (ELit (LString "||")))
(DFunDef false "binOpName" ((PCon "TAnd")) (ELit (LString "&&")))
(DFunDef false "binOpName" ((PCon "TEqEq")) (ELit (LString "==")))
(DFunDef false "binOpName" ((PCon "TNeq")) (ELit (LString "/=")))
(DFunDef false "binOpName" ((PCon "TLt")) (ELit (LString "<")))
(DFunDef false "binOpName" ((PCon "TGt")) (ELit (LString ">")))
(DFunDef false "binOpName" ((PCon "TLeq")) (ELit (LString "<=")))
(DFunDef false "binOpName" ((PCon "TGeq")) (ELit (LString ">=")))
(DFunDef false "binOpName" ((PCon "TCons")) (ELit (LString "::")))
(DFunDef false "binOpName" ((PCon "TPlusPlus")) (ELit (LString "++")))
(DFunDef false "binOpName" ((PCon "TStar")) (ELit (LString "*")))
(DFunDef false "binOpName" ((PCon "TSlash")) (ELit (LString "/")))
(DFunDef false "binOpName" ((PCon "TMod")) (ELit (LString "%")))
(DFunDef false "binOpName" ((PCon "TPlus")) (ELit (LString "+")))
(DFunDef false "binOpName" ((PCon "TMinus")) (ELit (LString "-")))
(DFunDef false "binOpName" ((PCon "TMinusTight")) (ELit (LString "-")))
(DFunDef false "binOpName" (PWild) (EApp (EVar "panic") (ELit (LString "binOpName: not a binary operator"))))
(DTypeSig false "pipeLevel" (TyCon "Int"))
(DFunDef false "pipeLevel" () (ELit (LInt 1)))
(DTypeSig false "orLevel" (TyCon "Int"))
(DFunDef false "orLevel" () (ELit (LInt 3)))
(DTypeSig false "consLevel" (TyCon "Int"))
(DFunDef false "consLevel" () (ELit (LInt 6)))
(DTypeSig false "mulLevel" (TyCon "Int"))
(DFunDef false "mulLevel" () (ELit (LInt 9)))
(DTypeSig false "parsePipe" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parsePipe" () (EApp (EVar "ParserE") (EApp (EVar "binLevel") (EVar "pipeLevel"))))
(DTypeSig false "parseOr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseOr" () (EApp (EVar "ParserE") (EApp (EVar "binLevel") (EVar "orLevel"))))
(DTypeSig false "binLevel" (TyFun (TyCon "Int") (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyApp (TyCon "PR") (TyCon "Expr"))))))
(DFunDef false "binLevel" ((PVar "lvl") (PVar "ctx") (PVar "pos")) (EIf (EBinOp ">" (EVar "lvl") (EVar "mulLevel")) (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "parseUnary")) (EVar "pos")) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "binLevelRest") (EVar "lvl")) (EVar "ctx")) (EApp (EApp (EApp (EVar "binLevel") (EBinOp "+" (EVar "lvl") (ELit (LInt 1)))) (EVar "ctx")) (EVar "pos"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "binLevelRest" (TyFun (TyCon "Int") (TyFun (TyCon "ParseContext") (TyFun (TyApp (TyCon "PR") (TyCon "Expr")) (TyApp (TyCon "PR") (TyCon "Expr"))))))
(DFunDef false "binLevelRest" ((PVar "lvl") (PVar "ctx") (PAs "r" (PCon "POk" (PVar "x") (PVar "pos")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "binTry") (EVar "lvl")) (EVar "ctx")) (EVar "r")) (EVar "x")) (EVar "pos")) (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "pos"))))
(DFunDef false "binLevelRest" (PWild PWild (PVar "r")) (EVar "r"))
(DTypeSig false "binTry" (TyFun (TyCon "Int") (TyFun (TyCon "ParseContext") (TyFun (TyApp (TyCon "PR") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "PR") (TyCon "Expr")))))))))
(DFunDef false "binTry" ((PVar "lvl") (PVar "ctx") (PVar "r") (PVar "x") (PVar "pos") (PVar "t")) (EIf (EBinOp "==" (EApp (EVar "binLevelOf") (EVar "t")) (EVar "lvl")) (EBlock (DoLet false false (PVar "saved") (EApp (EVar "mark") (EVar "ctx"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "binRhs") (EVar "saved")) (EVar "lvl")) (EVar "ctx")) (EVar "x")) (EVar "pos")) (EVar "t")) (EApp (EApp (EApp (EVar "binLevel") (EApp (EVar "binRhsLevel") (EVar "lvl"))) (EVar "ctx")) (EBinOp "+" (EVar "pos") (ELit (LInt 1))))))) (EIf (EVar "otherwise") (EVar "r") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "binRhsLevel" (TyFun (TyCon "Int") (TyCon "Int")))
(DFunDef false "binRhsLevel" ((PVar "lvl")) (EIf (EBinOp "==" (EVar "lvl") (EVar "consLevel")) (EVar "lvl") (EIf (EVar "otherwise") (EBinOp "+" (EVar "lvl") (ELit (LInt 1))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "binRhs" (TyFun (TyCon "ParseMark") (TyFun (TyCon "Int") (TyFun (TyCon "ParseContext") (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyFun (TyApp (TyCon "PR") (TyCon "Expr")) (TyApp (TyCon "PR") (TyCon "Expr"))))))))))
(DFunDef false "binRhs" (PWild (PVar "lvl") (PVar "ctx") (PVar "x") PWild (PVar "t") (PCon "POk" (PVar "y") (PVar "q"))) (EApp (EApp (EApp (EVar "binNext") (EVar "lvl")) (EVar "ctx")) (EApp (EApp (EVar "POk") (EApp (EApp (EApp (EApp (EVar "EBinOp") (EApp (EVar "binOpName") (EVar "t"))) (EVar "x")) (EVar "y")) (EVar "unminted"))) (EVar "q"))))
(DFunDef false "binRhs" ((PVar "saved") PWild (PVar "ctx") PWild (PVar "pos") PWild (PCon "PErr" PWild (PVar "q"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "q") (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EBinOp "||" (EBinOp "||" (EApp (EVar "isLineEndTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "q"))) (EApp (EVar "isCloseDelim") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "q")))) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "q")) (EVar "TComma")))) (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EApp (EApp (EVar "PFatal") (EApp (EVar "FailMsg") (ELit (LString "expected an expression after the binary operator")))) (EApp (EApp (EVar "committedErrorPos") (EVar "ctx")) (EVar "q"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "binRhs" ((PVar "saved") PWild PWild (PVar "x") (PVar "pos") PWild (PCon "PErr" PWild PWild)) (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EApp (EApp (EVar "POk") (EVar "x")) (EVar "pos")))))
(DFunDef false "binRhs" ((PVar "saved") PWild PWild PWild PWild PWild (PVar "ry")) (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EVar "ry"))))
(DTypeSig false "binNext" (TyFun (TyCon "Int") (TyFun (TyCon "ParseContext") (TyFun (TyApp (TyCon "PR") (TyCon "Expr")) (TyApp (TyCon "PR") (TyCon "Expr"))))))
(DFunDef false "binNext" ((PVar "lvl") (PVar "ctx") (PVar "r")) (EIf (EBinOp "==" (EVar "lvl") (EVar "consLevel")) (EVar "r") (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "binLevelRest") (EVar "lvl")) (EVar "ctx")) (EVar "r")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "intMinLit" (TyCon "Int"))
(DFunDef false "intMinLit" () (EBinOp "-" (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 4611686018427387903))) (ELit (LInt 1))))
(DTypeSig false "isIntMinLit" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isIntMinLit" ((PVar "n")) (EBinOp "==" (EVar "n") (EVar "intMinLit")))
(DTypeSig false "intLitTooBigMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "intLitTooBigMsg" () (EVar "PositiveIntOverflow"))
(DTypeSig false "widePatMsg" (TyFun (TyCon "String") (TyCon "ParseDiagnosticKind")))
(DFunDef false "widePatMsg" ((PVar "lx")) (EApp (EVar "WidePattern") (EVar "lx")))
(DTypeSig false "intMinAsWide" (TyFun (TyCon "String") (TyCon "Expr")))
(DFunDef false "intMinAsWide" ((PVar "lx")) (EApp (EApp (EApp (EApp (EVar "EWideLit") (ELit (LInt 1073741824))) (ELit (LInt 0))) (EVar "unminted")) (EVar "lx")))
(DTypeSig false "parseUnary" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseUnary" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "unaryFor") (EVar "t")))))
(DTypeSig false "unaryFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "unaryFor" ((PCon "TMinus")) (EVar "negUnary"))
(DFunDef false "unaryFor" ((PCon "TMinusTight")) (EVar "negUnary"))
(DFunDef false "unaryFor" ((PCon "TBang")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseUnary")) (ELam ((PVar "e")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "EUnOp") (ELit (LString "!"))) (EVar "e")) (EVar "unminted"))))))))
(DFunDef false "unaryFor" (PWild) (EVar "parseInfix"))
(DTypeSig false "negUnary" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "negUnary" () (EApp (EApp (EMethodRef "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EVar "negUnaryFor") (EVar "t2")))))
(DTypeSig false "negUnaryFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "negUnaryFor" ((PCon "TInt" (PVar "n") (PVar "lx"))) (EIf (EApp (EVar "isIntMinLit") (EVar "n")) (EApp (EVar "located") (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "ENumLit") (EVar "n")) (EVar "unminted")) (EBinOp "++" (ELit (LString "-")) (EVar "lx"))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "negUnaryFor" (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseUnary")) (ELam ((PVar "e")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "EUnOp") (ELit (LString "-"))) (EVar "e")) (EVar "unminted"))))))))
(DTypeSig false "parseInfix" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseInfix" () (EVar "parseApp"))
(DTypeSig false "parseApp" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseApp" () (EApp (EApp (EMethodRef "deferThen") (EVar "parseAspat")) (ELam ((PVar "head")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "many") (EApp (EVar "appArg") (EVar "head")))) (ELam ((PVar "args")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "applyAll") (EVar "head")) (EVar "args"))))))))
(DTypeSig false "appArg" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "appArg" ((PVar "head")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EApp (EVar "appArgR") (EVar "head")) (EVar "ctx")) (EVar "pos")))))
(DTypeSig false "appArgR" (TyFun (TyCon "Expr") (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyApp (TyCon "PR") (TyCon "Expr"))))))
(DFunDef false "appArgR" ((PVar "head") (PVar "ctx") (PVar "pos")) (EIf (EBinOp "&&" (EApp (EVar "appArgStops") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "pos"))) (EBinOp "<" (EApp (EVar "depthOf") (EVar "ctx")) (EVar "maxNestDepth"))) (EApp (EApp (EVar "PErr") (EApp (EVar "FailMsg") (ELit (LString "expected an application argument")))) (EVar "pos")) (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "negLitArg") (EVar "head"))) (EApp (EApp (EVar "parseOrElse") (EVar "derefArg")) (EVar "parseAspat")))) (EVar "pos"))))
(DTypeSig false "appArgStops" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "appArgStops" ((PCon "TEof")) (EVar "True"))
(DFunDef false "appArgStops" ((PCon "TNewline")) (EVar "True"))
(DFunDef false "appArgStops" ((PCon "TDedent")) (EVar "True"))
(DFunDef false "appArgStops" ((PCon "TRParen")) (EVar "True"))
(DFunDef false "appArgStops" ((PCon "TRBracket")) (EVar "True"))
(DFunDef false "appArgStops" ((PCon "TRBrace")) (EVar "True"))
(DFunDef false "appArgStops" ((PCon "TComma")) (EVar "True"))
(DFunDef false "appArgStops" (PWild) (EVar "False"))
(DTypeSig false "derefArg" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "derefArg" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "derefArgFor") (EVar "t")))))
(DTypeSig false "derefArgFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "derefArgFor" ((PCon "TBang")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseAspat")) (ELam ((PVar "e")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "EUnOp") (ELit (LString "!"))) (EVar "e")) (EVar "unminted"))))))))
(DFunDef false "derefArgFor" (PWild) (EApp (EVar "failP") (ELit (LString "not a tight deref argument"))))
(DTypeSig false "negLitArg" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "negLitArg" ((PVar "head")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "negLitArgGate") (EVar "head")) (EVar "t")))))
(DTypeSig false "negLitArgGate" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "negLitArgGate" ((PVar "head") (PCon "TMinusTight")) (EIf (EApp (EVar "headIsNumeric") (EVar "head")) (EApp (EVar "failP") (ELit (LString "numeric head: tight minus stays subtraction"))) (EVar "negLitArgTight")))
(DFunDef false "negLitArgGate" (PWild PWild) (EApp (EVar "failP") (ELit (LString "not a tight negative literal argument"))))
(DTypeSig false "negLitArgTight" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "negLitArgTight" () (EApp (EApp (EMethodRef "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EVar "negLitArgFor") (EVar "TMinusTight")) (EVar "t2")))))
(DTypeSig false "negLitArgFor" (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "negLitArgFor" ((PCon "TMinusTight") (PCon "TInt" (PVar "n") (PVar "lx"))) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "ENumLit") (EApp (EVar "negateLiteral") (EVar "n"))) (EVar "unminted")) (EBinOp "++" (ELit (LString "-")) (EVar "lx")))))))))
(DFunDef false "negLitArgFor" ((PCon "TMinusTight") (PCon "TWideInt" (PVar "hi") (PVar "lo") (PVar "lx"))) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "EUnOp") (ELit (LString "-"))) (EApp (EApp (EApp (EApp (EVar "EWideLit") (EVar "hi")) (EVar "lo")) (EVar "unminted")) (EVar "lx"))) (EVar "unminted"))))))))
(DFunDef false "negLitArgFor" ((PCon "TMinusTight") (PCon "TFloat" (PVar "f"))) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "ELit") (EApp (EVar "LFloat") (EApp (EMethodRef "negate") (EVar "f"))))))))))
(DFunDef false "negLitArgFor" (PWild PWild) (EApp (EVar "failP") (ELit (LString "not a tight negative literal argument"))))
(DTypeSig false "headIsNumeric" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "headIsNumeric" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "headIsNumeric") (EVar "e")))
(DFunDef false "headIsNumeric" ((PCon "ENumLit" PWild PWild PWild)) (EVar "True"))
(DFunDef false "headIsNumeric" ((PCon "EWideLit" PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "headIsNumeric" ((PCon "ELit" (PCon "LInt" PWild))) (EVar "True"))
(DFunDef false "headIsNumeric" ((PCon "ELit" (PCon "LFloat" PWild))) (EVar "True"))
(DFunDef false "headIsNumeric" (PWild) (EVar "False"))
(DTypeSig false "parseAspat" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAspat" () (EApp (EApp (EVar "parseOrElse") (EVar "parseAspatAt")) (EVar "parsePostfix")))
(DTypeSig false "parseAspatAt" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAspatAt" () (EApp (EVar "located") (EVar "parseAspatAtRaw")))
(DTypeSig false "parseAspatAtRaw" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAspatAtRaw" () (EApp (EApp (EMethodRef "deferThen") (EVar "identNameP")) (ELam ((PVar "x")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TAsAt"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parsePostfix")) (ELam ((PVar "sub")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "EAsPat") (EVar "x")) (EMethodRef "sub"))))))))))
(DTypeSig false "applyAll" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr"))))
(DFunDef false "applyAll" ((PVar "head") (PList)) (EVar "head"))
(DFunDef false "applyAll" ((PVar "head") (PCons (PVar "a") (PVar "rest"))) (EApp (EApp (EVar "applyAll") (EApp (EApp (EVar "EApp") (EVar "head")) (EVar "a"))) (EVar "rest")))
(DTypeSig false "parsePostfix" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parsePostfix" () (EApp (EApp (EMethodRef "deferThen") (EVar "parseAtom")) (ELam ((PVar "e")) (EApp (EVar "postfixTail") (EVar "e")))))
(DTypeSig false "postfixTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "postfixTail" ((PVar "e")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EApp (EVar "postfixTailR") (EVar "e")) (EVar "ctx")) (EVar "pos")))))
(DTypeSig false "postfixTailR" (TyFun (TyCon "Expr") (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyApp (TyCon "PR") (TyCon "Expr"))))))
(DFunDef false "postfixTailR" ((PVar "e") (PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "pos")) (arm (PCon "TLBracketTight") () (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EApp (EVar "postfixChain") (EVar "e"))) (EVar "pos"))) (arm (PCon "TDot") () (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EApp (EVar "postfixChain") (EVar "e"))) (EVar "pos"))) (arm PWild () (EApp (EApp (EVar "POk") (EVar "e")) (EVar "pos")))))
(DTypeSig false "postfixChain" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "postfixChain" ((PVar "e")) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "bracketIndexTail") (EVar "e"))) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "dotTail") (EVar "e"))) (EApp (EMethodRef "deferPure") (EVar "e")))))
(DTypeSig false "bracketIndexTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "bracketIndexTail" ((PVar "e")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TLBracketTight"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "lo")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "bracketIndexRest") (EVar "e")) (EVar "lo")) (EVar "t")))))))))
(DTypeSig false "bracketIndexRest" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))))
(DFunDef false "bracketIndexRest" (PWild PWild (PCon "TDotDot")) (EApp (EVar "failP") (ELit (LString "bare slice `a[i..j]` is not supported; write `a.[i..j]`"))))
(DFunDef false "bracketIndexRest" (PWild PWild (PCon "TDotDotEq")) (EApp (EVar "failP") (ELit (LString "bare slice `a[i..=j]` is not supported; write `a.[i..=j]`"))))
(DFunDef false "bracketIndexRest" ((PVar "e") (PVar "lo") (PCon "TRBracket")) (EApp (EApp (EVar "finishBracketIndex") (EVar "e")) (EVar "lo")))
(DFunDef false "bracketIndexRest" (PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected `]` to close the index"))))
(DTypeSig false "finishBracketIndex" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "finishBracketIndex" ((PVar "e") (PVar "lo")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "postfixTail") (EApp (EApp (EVar "EIndex") (EVar "e")) (EVar "lo"))))))
(DTypeSig false "dotTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "dotTail" ((PVar "e")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TDot"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "dotFor") (EVar "e")) (EVar "t")))))))
(DTypeSig false "dotFor" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "dotFor" ((PVar "e") (PCon "TLBracket")) (EApp (EVar "indexOrSlice") (EVar "e")))
(DFunDef false "dotFor" ((PVar "e") PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "identNameP")) (ELam ((PVar "f")) (EApp (EVar "postfixTail") (EApp (EApp (EApp (EVar "EFieldAccess") (EVar "e")) (EVar "f")) (EVar "unminted"))))))
(DTypeSig false "indexOrSlice" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "indexOrSlice" ((PVar "e")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TLBracket"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "lo")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "indexOrSliceRest") (EVar "e")) (EVar "lo")) (EVar "t")))))))))
(DTypeSig false "indexOrSliceRest" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))))
(DFunDef false "indexOrSliceRest" ((PVar "e") (PVar "lo") (PCon "TDotDot")) (EApp (EApp (EApp (EVar "sliceHi") (EVar "e")) (EVar "lo")) (EVar "False")))
(DFunDef false "indexOrSliceRest" ((PVar "e") (PVar "lo") (PCon "TDotDotEq")) (EApp (EApp (EApp (EVar "sliceHi") (EVar "e")) (EVar "lo")) (EVar "True")))
(DFunDef false "indexOrSliceRest" ((PVar "e") (PVar "lo") (PCon "TRBracket")) (EApp (EApp (EVar "finishBracketIndex") (EVar "e")) (EVar "lo")))
(DFunDef false "indexOrSliceRest" (PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected `..`, `..=` or `]` in the index"))))
(DTypeSig false "sliceHi" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Expr"))))))
(DFunDef false "sliceHi" ((PVar "e") (PVar "lo") (PVar "incl")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "hi")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRBracket"))) (ELam (PWild) (EApp (EVar "postfixTail") (EApp (EApp (EApp (EApp (EVar "ESlice") (EVar "e")) (EVar "lo")) (EVar "hi")) (EVar "incl"))))))))))
(DTypeSig false "maxNestDepth" (TyCon "Int"))
(DFunDef false "maxNestDepth" () (ELit (LInt 20000)))
(DTypeSig false "nestTooDeepMsg" (TyCon "String"))
(DFunDef false "nestTooDeepMsg" () (EBinOp "++" (EBinOp "++" (ELit (LString "expression nesting too deep (limit ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "maxNestDepth")))) (ELit (LString "); split this expression into named intermediate bindings"))))
(DTypeSig false "parseAtom" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAtom" () (EApp (EApp (EApp (EVar "withDepth") (EVar "maxNestDepth")) (EApp (EVar "FailMsg") (EVar "nestTooDeepMsg"))) (EApp (EVar "ParserE") (EVar "atomRawLocated"))))
(DTypeSig false "atomRawLocated" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyApp (TyCon "PR") (TyCon "Expr")))))
(DFunDef false "atomRawLocated" ((PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "parseAtomRaw")) (EVar "pos")) (arm (PCon "POk" (PVar "e") (PVar "q")) () (EApp (EApp (EVar "POk") (EApp (EApp (EVar "ELoc") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "pos")) (EVar "q"))) (EVar "e"))) (EVar "q"))) (arm (PCon "PErr" (PVar "f") (PVar "q")) () (EApp (EApp (EVar "PErr") (EVar "f")) (EVar "q"))) (arm (PCon "PFatal" (PVar "f") (PVar "q")) () (EApp (EApp (EVar "PFatal") (EVar "f")) (EVar "q")))))
(DTypeSig false "parseAtomRaw" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseAtomRaw" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TInt" (PVar "n") (PVar "lx")) ((GBool (EApp (EVar "isIntMinLit") (EVar "n")))) (EApp (EVar "emit") (EApp (EVar "intMinAsWide") (EVar "lx")))) (arm (PCon "TInt" (PVar "n") (PVar "lx")) () (EApp (EVar "emit") (EApp (EApp (EApp (EVar "ENumLit") (EVar "n")) (EVar "unminted")) (EVar "lx")))) (arm (PCon "TWideInt" (PVar "hi") (PVar "lo") (PVar "lx")) () (EApp (EVar "emit") (EApp (EApp (EApp (EApp (EVar "EWideLit") (EVar "hi")) (EVar "lo")) (EVar "unminted")) (EVar "lx")))) (arm (PCon "TFloat" (PVar "f")) () (EApp (EVar "emit") (EApp (EVar "ELit") (EApp (EVar "LFloat") (EVar "f"))))) (arm (PCon "TString" (PVar "s")) () (EApp (EVar "emit") (EApp (EVar "ELit") (EApp (EVar "LString") (EVar "s"))))) (arm (PCon "TChar" (PVar "s")) () (EApp (EVar "emit") (EApp (EVar "ELit") (EApp (EVar "LChar") (EVar "s"))))) (arm (PCon "TByte" (PVar "n")) () (EApp (EVar "emit") (EApp (EVar "ELit") (EApp (EVar "LByte") (EVar "n"))))) (arm (PCon "TIdent" (PVar "x")) () (EApp (EVar "emit") (EApp (EVar "EVar") (EVar "x")))) (arm (PCon "TUpper" (PVar "x")) () (EApp (EVar "parseUpperAtom") (EVar "x"))) (arm (PCon "TUnderscore") () (EApp (EVar "emit") (EApp (EVar "EVar") (ELit (LString "_"))))) (arm (PCon "TLParen") () (EVar "parseParen")) (arm (PCon "TLBracket") () (EVar "parseListE")) (arm (PCon "TLArray") () (EVar "parseArray")) (arm (PCon "TLBrace") () (EVar "parseRecordUpdate")) (arm (PCon "TIf") () (EVar "parseIf")) (arm (PCon "TLet") () (EVar "parseLet")) (arm (PCon "TMatch") () (EVar "parseMatch")) (arm (PCon "TDo") () (EVar "parseDo")) (arm (PCon "TDefer") () (EVar "parseDefer")) (arm (PCon "TInterpOpen" PWild) () (EVar "parseInterp")) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected an expression"))))))))
(DTypeSig false "parseUpperAtom" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "parseUpperAtom" ((PVar "x")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "upperQualTail") (EVar "x"))) (ELam ((PVar "n")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "upperTail") (EVar "n")) (EVar "t")))))))))
(DTypeSig false "upperTail" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "upperTail" ((PVar "x") (PCon "TLBrace")) (EApp (EVar "upperBrace") (EVar "x")))
(DFunDef false "upperTail" ((PVar "x") PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "EVar") (EVar "x"))))
(DTypeSig false "upperBrace" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "upperBrace" ((PVar "x")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TLBrace"))) (ELam (PWild) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "variantUpdateTail") (EVar "x"))) (EApp (EVar "braceItems") (EVar "x"))))))
(DTypeSig false "variantUpdateTail" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "variantUpdateTail" ((PVar "x")) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TPipe"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "recordFieldExpr")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "fields")) (EApp (EApp (EMethodRef "deferThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "x")) (EVar "e")) (EApp (EApp (EMethodRef "map") (EApp (EVar "desugarDottedField") (EVar "e"))) (EVar "fields")))))))))))))))
(DData Private "KvItem" () ((variant "KvField" (ConPos (TyCon "String") (TyCon "Expr"))) (variant "KvKV" (ConPos (TyCon "Expr") (TyCon "Expr"))) (variant "KvElem" (ConPos (TyCon "Expr")))) ())
(DTypeSig false "braceItems" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "braceItems" ((PVar "x")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "braceItemsFor") (EVar "x")) (EVar "t")))))
(DTypeSig false "braceItemsFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "braceItemsFor" ((PVar "x") (PCon "TRBrace")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "classifyBrace") (EVar "x")) (EListLit))))))
(DFunDef false "braceItemsFor" ((PVar "x") PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "parseKvOrE")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "items")) (EApp (EApp (EMethodRef "deferThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "classifyBrace") (EVar "x")) (EVar "items"))))))))))
(DTypeSig false "parseKvOrE" (TyApp (TyCon "Parser") (TyCon "KvItem")))
(DFunDef false "parseKvOrE" () (EApp (EApp (EVar "parseOrElse") (EVar "parseKvField")) (EApp (EApp (EVar "parseOrElse") (EVar "parseKvBlockElem")) (EVar "parseKvKVorElem"))))
(DTypeSig false "parseKvBlockElem" (TyApp (TyCon "Parser") (TyCon "KvItem")))
(DFunDef false "parseKvBlockElem" () (EApp (EApp (EMethodRef "deferThen") (EVar "parseBracketBlock")) (ELam ((PVar "e")) (EApp (EMethodRef "deferPure") (EApp (EVar "KvElem") (EVar "e"))))))
(DTypeSig false "parseKvField" (TyApp (TyCon "Parser") (TyCon "KvItem")))
(DFunDef false "parseKvField" () (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "p")) (EApp (EApp (EMethodRef "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "committedExpr") (ELit (LString "expected a record field value after `=`"))) (EVar "parseBracketElem"))) (ELam ((PVar "e")) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "recordUnitStart") (ELit (LInt 4))) (EVar "p"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "KvField") (EVar "name")) (EVar "e"))))))))))))))
(DTypeSig false "parseKvKVorElem" (TyApp (TyCon "Parser") (TyCon "KvItem")))
(DFunDef false "parseKvKVorElem" () (EApp (EApp (EMethodRef "deferThen") (EVar "parsePipe")) (ELam ((PVar "e")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "kvKVorElemFor") (EVar "e")) (EVar "t")))))))
(DTypeSig false "kvKVorElemFor" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "KvItem")))))
(DFunDef false "kvKVorElemFor" ((PVar "e") (PCon "TFatArrow")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "v")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "KvKV") (EVar "e")) (EVar "v"))))))))
(DFunDef false "kvKVorElemFor" ((PVar "e") PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "KvElem") (EVar "e"))))
(DTypeSig false "classifyBrace" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "KvItem")) (TyCon "Expr"))))
(DFunDef false "classifyBrace" ((PVar "name") (PVar "items")) (EIf (EApp (EVar "anyField") (EVar "items")) (EApp (EApp (EVar "ERecordCreate") (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "kvToField")) (EVar "items"))) (EIf (EApp (EVar "anyKV") (EVar "items")) (EApp (EApp (EVar "EMapLit") (EVar "name")) (EApp (EVar "kvPairs") (EVar "items"))) (EIf (EVar "otherwise") (EApp (EApp (EVar "ESetLit") (EVar "name")) (EApp (EVar "kvElems") (EVar "items"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "anyField" (TyFun (TyApp (TyCon "List") (TyCon "KvItem")) (TyCon "Bool")))
(DFunDef false "anyField" ((PList)) (EVar "False"))
(DFunDef false "anyField" ((PCons (PCon "KvField" PWild PWild) PWild)) (EVar "True"))
(DFunDef false "anyField" ((PCons PWild (PVar "rest"))) (EApp (EVar "anyField") (EVar "rest")))
(DTypeSig false "anyKV" (TyFun (TyApp (TyCon "List") (TyCon "KvItem")) (TyCon "Bool")))
(DFunDef false "anyKV" ((PList)) (EVar "False"))
(DFunDef false "anyKV" ((PCons (PCon "KvKV" PWild PWild) PWild)) (EVar "True"))
(DFunDef false "anyKV" ((PCons PWild (PVar "rest"))) (EApp (EVar "anyKV") (EVar "rest")))
(DTypeSig false "kvToField" (TyFun (TyCon "KvItem") (TyCon "FieldAssign")))
(DFunDef false "kvToField" ((PCon "KvField" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EVar "e")))
(DFunDef false "kvToField" ((PCon "KvElem" (PVar "e"))) (EApp (EVar "kvElemToField") (EApp (EVar "stripLoc") (EVar "e"))))
(DFunDef false "kvToField" (PWild) (EApp (EApp (EVar "FieldAssign") (ELit (LString "_"))) (EApp (EVar "ELit") (EVar "LUnit"))))
(DTypeSig false "kvElemToField" (TyFun (TyCon "Expr") (TyCon "FieldAssign")))
(DFunDef false "kvElemToField" ((PCon "EVar" (PVar "n"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EVar "EVar") (EVar "n"))))
(DFunDef false "kvElemToField" (PWild) (EApp (EApp (EVar "FieldAssign") (ELit (LString "_"))) (EApp (EVar "ELit") (EVar "LUnit"))))
(DTypeSig false "kvPairs" (TyFun (TyApp (TyCon "List") (TyCon "KvItem")) (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "kvPairs" ((PList)) (EListLit))
(DFunDef false "kvPairs" ((PCons (PCon "KvKV" (PVar "k") (PVar "v")) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "k") (EVar "v")) (EApp (EVar "kvPairs") (EVar "rest"))))
(DFunDef false "kvPairs" ((PCons PWild (PVar "rest"))) (EApp (EVar "kvPairs") (EVar "rest")))
(DTypeSig false "kvElems" (TyFun (TyApp (TyCon "List") (TyCon "KvItem")) (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "kvElems" ((PList)) (EListLit))
(DFunDef false "kvElems" ((PCons (PCon "KvElem" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EVar "e") (EApp (EVar "kvElems") (EVar "rest"))))
(DFunDef false "kvElems" ((PCons PWild (PVar "rest"))) (EApp (EVar "kvElems") (EVar "rest")))
(DTypeSig false "parseRecordUpdate" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseRecordUpdate" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TLBrace"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TPipe"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "recordFieldExpr")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "fields")) (EApp (EApp (EMethodRef "deferThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "ERecordUpdate") (EVar "e")) (EApp (EApp (EMethodRef "map") (EApp (EVar "desugarDottedField") (EVar "e"))) (EVar "fields"))) (EVar "unminted"))))))))))))))))
(DTypeSig false "recordFieldExpr" (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr"))))
(DFunDef false "recordFieldExpr" () (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "identNameP")) (EApp (EVar "expectTok") (EVar "TDot")))) (ELam ((PVar "path")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "recordFieldExprRest") (EVar "path")) (EVar "t")))))))
(DTypeSig false "recordFieldExprRest" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr"))))))
(DFunDef false "recordFieldExprRest" ((PVar "path") (PCon "TEqual")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "committedExpr") (ELit (LString "expected a record field value after `=`"))) (EVar "parseBracketElem"))) (ELam ((PVar "e")) (EApp (EMethodRef "deferPure") (ETuple (EVar "path") (EVar "e"))))))))
(DFunDef false "recordFieldExprRest" ((PList (PVar "x")) PWild) (EApp (EMethodRef "deferPure") (ETuple (EListLit (EVar "x")) (EApp (EVar "EVar") (EVar "x")))))
(DFunDef false "recordFieldExprRest" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected `=` after the field name in a record update"))))
(DTypeSig false "desugarDottedField" (TyFun (TyCon "Expr") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "Expr")) (TyCon "FieldAssign"))))
(DFunDef false "desugarDottedField" ((PVar "base") (PTuple (PVar "path") (PVar "value"))) (EMatch (EVar "path") (arm (PList (PVar "field")) () (EApp (EApp (EVar "FieldAssign") (EVar "field")) (EVar "value"))) (arm (PCons (PVar "field") (PVar "rest")) () (EApp (EApp (EVar "FieldAssign") (EVar "field")) (EApp (EApp (EApp (EVar "dottedGo") (EApp (EApp (EApp (EVar "EFieldAccess") (EVar "base")) (EVar "field")) (EVar "unminted"))) (EVar "rest")) (EVar "value")))) (arm (PList) () (EApp (EApp (EVar "FieldAssign") (ELit (LString "_"))) (EVar "value")))))
(DTypeSig false "dottedGo" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "dottedGo" ((PVar "cur") (PList (PVar "f")) (PVar "value")) (EApp (EApp (EApp (EVar "ERecordUpdate") (EVar "cur")) (EListLit (EApp (EApp (EVar "FieldAssign") (EVar "f")) (EVar "value")))) (EVar "unminted")))
(DFunDef false "dottedGo" ((PVar "cur") (PCons (PVar "f") (PVar "fs")) (PVar "value")) (EApp (EApp (EApp (EVar "ERecordUpdate") (EVar "cur")) (EListLit (EApp (EApp (EVar "FieldAssign") (EVar "f")) (EApp (EApp (EApp (EVar "dottedGo") (EApp (EApp (EApp (EVar "EFieldAccess") (EVar "cur")) (EVar "f")) (EVar "unminted"))) (EVar "fs")) (EVar "value"))))) (EVar "unminted")))
(DFunDef false "dottedGo" ((PVar "cur") (PList) (PVar "value")) (EVar "value"))
(DTypeSig false "parseInterp" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseInterp" () (EApp (EApp (EMethodRef "deferThen") (EVar "interpOpenStr")) (ELam ((PVar "s0")) (EApp (EApp (EMethodRef "deferThen") (EVar "interpRest")) (ELam ((PVar "rest")) (EApp (EMethodRef "deferPure") (EApp (EVar "EStringInterp") (EBinOp "::" (EApp (EVar "InterpStr") (EVar "s0")) (EVar "rest")))))))))
(DTypeSig false "interpOpenStr" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "interpOpenStr" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "interpOpenFor") (EVar "t")))))
(DTypeSig false "interpOpenFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "interpOpenFor" ((PCon "TInterpOpen" (PVar "s"))) (EApp (EVar "emit") (EVar "s")))
(DFunDef false "interpOpenFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected interpolation open"))))
(DTypeSig false "interpRest" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "InterpPart"))))
(DFunDef false "interpRest" () (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "interpRestFor") (EVar "e")) (EVar "t")))))))
(DTypeSig false "interpRestFor" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "InterpPart"))))))
(DFunDef false "interpRestFor" ((PVar "e") (PCon "TInterpMid" (PVar "s"))) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "interpRest")) (ELam ((PVar "rest")) (EApp (EMethodRef "deferPure") (EBinOp "::" (EApp (EVar "InterpExpr") (EVar "e")) (EBinOp "::" (EApp (EVar "InterpStr") (EVar "s")) (EVar "rest")))))))))
(DFunDef false "interpRestFor" ((PVar "e") (PCon "TInterpEnd" (PVar "s"))) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EListLit (EApp (EVar "InterpExpr") (EVar "e")) (EApp (EVar "InterpStr") (EVar "s")))))))
(DFunDef false "interpRestFor" ((PVar "e") PWild) (EApp (EVar "failP") (ELit (LString "expected interpolation mid/end"))))
(DTypeSig false "parseBracketBlock" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseBracketBlock" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseStmts")) (ELam ((PVar "stmts")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "unrecordSoleStmt") (EVar "stmts"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "blockOrExpr") (EVar "stmts"))))))))))))
(DTypeSig false "unrecordSoleStmt" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "unrecordSoleStmt" ((PList (PCon "DoExpr" PWild))) (EVar "forgetLatestUnitStart"))
(DFunDef false "unrecordSoleStmt" (PWild) (EApp (EMethodRef "deferPure") (ELit LUnit)))
(DTypeSig false "parseBracketElem" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseBracketElem" () (EApp (EApp (EVar "parseOrElse") (EVar "parseBracketBlock")) (EVar "parseExpr")))
(DTypeSig false "parseParen" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseParen" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TLParen"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "committedExpr") (ELit (LString "expected a complete parenthesized expression"))) (EApp (EVar "parenFor") (EVar "t"))))))))
(DTypeSig false "committedExpr" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Parser") (TyCon "Expr")) (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "committedExpr" ((PVar "msg") (PVar "p")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "p")) (EVar "pos")) (arm (PCon "PErr" (PVar "f") (PVar "q")) () (EBlock (DoLet false false (PVar "loc") (EApp (EApp (EVar "committedErrorPos") (EVar "ctx")) (EVar "q"))) (DoLet false false (PVar "reason") (EMatch (EVar "f") (arm (PCon "FailExpect" (PCon "TNewline") (PCon "TRParen")) () (EIf (EBinOp ">" (EVar "loc") (EVar "q")) (EApp (EVar "FailMsg") (ELit (LString "unexpected end of input; expected `)`"))) (EVar "f"))) (arm PWild () (EIf (EBinOp ">" (EVar "q") (EVar "pos")) (EVar "f") (EApp (EVar "FailMsg") (EVar "msg")))))) (DoExpr (EApp (EApp (EVar "PFatal") (EVar "reason")) (EVar "loc"))))) (arm (PVar "r") () (EVar "r"))))))
(DTypeSig false "committedErrorPos" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "committedErrorPos" ((PVar "ctx") (PVar "q")) (EBlock (DoLet false false (PVar "toks") (EApp (EVar "contextTokens") (EVar "ctx"))) (DoLet false false (PVar "offs") (EApp (EVar "contextOffsets") (EVar "ctx"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "q") (ELit (LInt 0))) (EBinOp "<" (EVar "q") (EApp (EVar "arrayLength") (EVar "offs")))) (EBinOp "==" (EApp (EVar "fst") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "q")) (EVar "offs"))) (ELit (LInt 0)))) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "q")) (EVar "TNewline"))) (EBinOp "==" (EApp (EApp (EVar "peekTok") (EVar "toks")) (EBinOp "+" (EVar "q") (ELit (LInt 1)))) (EVar "TEof"))) (EBinOp "+" (EVar "q") (ELit (LInt 1))) (EVar "q")))))
(DTypeSig false "parenFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "parenFor" ((PCon "TRParen")) (EApp (EVar "emit") (EApp (EVar "ELit") (EVar "LUnit"))))
(DFunDef false "parenFor" ((PCon "TMinus")) (EApp (EApp (EVar "parseOrElse") (EVar "bareMinusSection")) (EVar "parseParenExpr")))
(DFunDef false "parenFor" ((PCon "TMinusTight")) (EApp (EApp (EVar "parseOrElse") (EVar "bareMinusSection")) (EVar "parseParenExpr")))
(DFunDef false "parenFor" ((PVar "t")) (EApp (EVar "parenSectionOr") (EVar "t")))
(DTypeSig false "parenSectionOr" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "parenSectionOr" ((PVar "t")) (EMatch (EApp (EVar "sectionOpStr") (EVar "t")) (arm (PCon "Some" (PVar "op")) () (EApp (EVar "parseSectionOp") (EVar "op"))) (arm (PCon "None") () (EVar "parseParenExpr"))))
(DTypeSig false "bareMinusSection" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "bareMinusSection" () (EApp (EApp (EMethodRef "deferThen") (EVar "expectMinus")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "ESection") (EApp (EVar "SecBare") (ELit (LString "-"))))))))))
(DTypeSig false "expectMinus" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "expectMinus" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "expectMinusGo") (EVar "t")))))
(DTypeSig false "expectMinusGo" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "expectMinusGo" ((PCon "TMinus")) (EApp (EVar "emit") (ELit LUnit)))
(DFunDef false "expectMinusGo" ((PCon "TMinusTight")) (EApp (EVar "emit") (ELit LUnit)))
(DFunDef false "expectMinusGo" (PWild) (EApp (EVar "failP") (ELit (LString "expected `-`"))))
(DTypeSig false "parseSectionOp" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "parseSectionOp" ((PVar "op")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "sectionTail") (EVar "op")) (EVar "t")))))))
(DTypeSig false "sectionTail" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "sectionTail" ((PVar "op") (PCon "TRParen")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "ESection") (EApp (EVar "SecBare") (EVar "op")))))))
(DFunDef false "sectionTail" ((PVar "op") PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "ESection") (EApp (EApp (EVar "SecRight") (EVar "op")) (EVar "e")))))))))
(DTypeSig false "parseParenExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseParenExpr" () (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "parseOrAltsExpr")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "es")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "optTrailingCommaTuple") (EVar "es"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "parenResult") (EVar "es"))))))))))
(DTypeSig false "parseOrAltsExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseOrAltsExpr" () (EApp (EApp (EMethodRef "deferThen") (EVar "parseBracketElem")) (ELam ((PVar "e")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "many") (EVar "orAltExpr"))) (ELam ((PVar "rest")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "orExprOf") (EVar "e")) (EVar "rest"))))))))
(DTypeSig false "orAltExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "orAltExpr" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TPipe"))) (ELam (PWild) (EVar "parseBracketElem"))))
(DTypeSig false "orExprOf" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr"))))
(DFunDef false "orExprOf" ((PVar "e") (PList)) (EVar "e"))
(DFunDef false "orExprOf" ((PVar "e") (PVar "rest")) (EApp (EVar "EOrPat") (EBinOp "::" (EVar "e") (EVar "rest"))))
(DTypeSig false "parenResult" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr")))
(DFunDef false "parenResult" ((PList (PVar "e"))) (EApp (EVar "leftSectionOrExpr") (EVar "e")))
(DFunDef false "parenResult" ((PVar "es")) (EApp (EVar "ETuple") (EVar "es")))
(DTypeSig false "leftSectionOrExpr" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "leftSectionOrExpr" ((PVar "e")) (EApp (EApp (EVar "leftSectionGo") (EVar "e")) (EApp (EVar "stripLoc1") (EVar "e"))))
(DTypeSig false "leftSectionGo" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "leftSectionGo" ((PVar "orig") (PCon "EBinOp" (PVar "op") (PVar "lhs") (PVar "rhs") PWild)) (EApp (EApp (EApp (EApp (EVar "leftSectionRhs") (EVar "orig")) (EVar "op")) (EVar "lhs")) (EApp (EVar "stripLoc1") (EVar "rhs"))))
(DFunDef false "leftSectionGo" ((PVar "orig") PWild) (EVar "orig"))
(DTypeSig false "leftSectionRhs" (TyFun (TyCon "Expr") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "leftSectionRhs" (PWild (PVar "op") (PVar "lhs") (PCon "EVar" (PLit (LString "_")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecLeft") (EVar "lhs")) (EVar "op"))))
(DFunDef false "leftSectionRhs" ((PVar "orig") PWild PWild PWild) (EVar "orig"))
(DTypeSig false "sectionOpStr" (TyFun (TyCon "Token") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "sectionOpStr" ((PCon "TPlus")) (EApp (EVar "Some") (ELit (LString "+"))))
(DFunDef false "sectionOpStr" ((PCon "TStar")) (EApp (EVar "Some") (ELit (LString "*"))))
(DFunDef false "sectionOpStr" ((PCon "TSlash")) (EApp (EVar "Some") (ELit (LString "/"))))
(DFunDef false "sectionOpStr" ((PCon "TEqEq")) (EApp (EVar "Some") (ELit (LString "=="))))
(DFunDef false "sectionOpStr" ((PCon "TNeq")) (EApp (EVar "Some") (ELit (LString "/="))))
(DFunDef false "sectionOpStr" ((PCon "TLt")) (EApp (EVar "Some") (ELit (LString "<"))))
(DFunDef false "sectionOpStr" ((PCon "TGt")) (EApp (EVar "Some") (ELit (LString ">"))))
(DFunDef false "sectionOpStr" ((PCon "TLeq")) (EApp (EVar "Some") (ELit (LString "<="))))
(DFunDef false "sectionOpStr" ((PCon "TGeq")) (EApp (EVar "Some") (ELit (LString ">="))))
(DFunDef false "sectionOpStr" ((PCon "TAnd")) (EApp (EVar "Some") (ELit (LString "&&"))))
(DFunDef false "sectionOpStr" ((PCon "TOr")) (EApp (EVar "Some") (ELit (LString "||"))))
(DFunDef false "sectionOpStr" ((PCon "TCons")) (EApp (EVar "Some") (ELit (LString "::"))))
(DFunDef false "sectionOpStr" ((PCon "TPlusPlus")) (EApp (EVar "Some") (ELit (LString "++"))))
(DFunDef false "sectionOpStr" ((PCon "TPipeRight")) (EApp (EVar "Some") (ELit (LString "|>"))))
(DFunDef false "sectionOpStr" ((PCon "TRCompose")) (EApp (EVar "Some") (ELit (LString ">>"))))
(DFunDef false "sectionOpStr" ((PCon "TLCompose")) (EApp (EVar "Some") (ELit (LString "<<"))))
(DFunDef false "sectionOpStr" (PWild) (EVar "None"))
(DTypeSig false "parseListE" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseListE" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TLBracket"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "listFor") (EVar "t")))))))
(DTypeSig false "listFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "listFor" ((PCon "TRBracket")) (EApp (EVar "emit") (EApp (EVar "EListLit") (EListLit))))
(DFunDef false "listFor" (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseBracketElem")) (ELam ((PVar "first")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "listRest") (EVar "first")) (EVar "t")))))))
(DTypeSig false "listRest" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "listRest" ((PVar "first") (PCon "TDotDot")) (EApp (EApp (EVar "rangeAfter") (EVar "first")) (EVar "False")))
(DFunDef false "listRest" ((PVar "first") (PCon "TDotDotEq")) (EApp (EApp (EVar "rangeAfter") (EVar "first")) (EVar "True")))
(DFunDef false "listRest" ((PVar "first") (PCon "TComma")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "listAfterComma") (EVar "first")) (EVar "t")))))))
(DFunDef false "listRest" ((PVar "first") (PCon "TRBracket")) (EApp (EVar "finishSingletonList") (EVar "first")))
(DFunDef false "listRest" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected `,`, `..`, `..=` or `]` in the list"))))
(DTypeSig false "finishSingletonList" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "finishSingletonList" ((PVar "first")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "EListLit") (EListLit (EVar "first")))))))
(DTypeSig false "listAfterComma" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "listAfterComma" ((PVar "first") (PCon "TRBracket")) (EApp (EVar "finishSingletonList") (EVar "first")))
(DFunDef false "listAfterComma" ((PVar "first") PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "parseBracketElem")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "rest")) (EApp (EApp (EMethodRef "deferThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRBracket"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "EListLit") (EBinOp "::" (EVar "first") (EVar "rest")))))))))))
(DTypeSig false "rangeAfter" (TyFun (TyCon "Expr") (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "rangeAfter" ((PVar "lo") (PVar "incl")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "hi")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRBracket"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "ERangeList") (EVar "lo")) (EVar "hi")) (EVar "incl"))))))))))
(DTypeSig false "parseArray" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseArray" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TLArray"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "arrayFor") (EVar "t")))))))
(DTypeSig false "arrayFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "arrayFor" ((PCon "TRArray")) (EApp (EVar "emit") (EApp (EVar "EArrayLit") (EListLit))))
(DFunDef false "arrayFor" (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseBracketElem")) (ELam ((PVar "first")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "arrayRest") (EVar "first")) (EVar "t")))))))
(DTypeSig false "arrayRest" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "arrayRest" ((PVar "first") (PCon "TDotDot")) (EApp (EApp (EVar "arrayRangeAfter") (EVar "first")) (EVar "False")))
(DFunDef false "arrayRest" ((PVar "first") (PCon "TDotDotEq")) (EApp (EApp (EVar "arrayRangeAfter") (EVar "first")) (EVar "True")))
(DFunDef false "arrayRest" ((PVar "first") (PCon "TComma")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "arrayAfterComma") (EVar "first")) (EVar "t")))))))
(DFunDef false "arrayRest" ((PVar "first") (PCon "TRArray")) (EApp (EVar "finishSingletonArray") (EVar "first")))
(DFunDef false "arrayRest" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected `,`, `..`, `..=` or `|]` in the array"))))
(DTypeSig false "finishSingletonArray" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "finishSingletonArray" ((PVar "first")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "EArrayLit") (EListLit (EVar "first")))))))
(DTypeSig false "arrayAfterComma" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "arrayAfterComma" ((PVar "first") (PCon "TRArray")) (EApp (EVar "finishSingletonArray") (EVar "first")))
(DFunDef false "arrayAfterComma" ((PVar "first") PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "parseBracketElem")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "rest")) (EApp (EApp (EMethodRef "deferThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRArray"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "EArrayLit") (EBinOp "::" (EVar "first") (EVar "rest")))))))))))
(DTypeSig false "arrayRangeAfter" (TyFun (TyCon "Expr") (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "arrayRangeAfter" ((PVar "lo") (PVar "incl")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "hi")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRArray"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "ERangeArray") (EVar "lo")) (EVar "hi")) (EVar "incl"))))))))))
(DTypeSig false "parseIf" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseIf" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TIf"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "ifKind") (EVar "t")))))))
(DTypeSig false "ifKind" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "ifKind" ((PCon "TLet")) (EVar "ifLet"))
(DFunDef false "ifKind" (PWild) (EVar "ifPlain"))
(DTypeSig false "ifLet" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "ifLet" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TLet"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parsePat")) (ELam ((PVar "pat")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "scrut")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TThen"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "thenE")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TElse"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "elseE")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "EMatch") (EVar "scrut")) (EListLit (EApp (EApp (EApp (EVar "Arm") (EVar "pat")) (EListLit)) (EVar "thenE")) (EApp (EApp (EApp (EVar "Arm") (EVar "PWild")) (EListLit)) (EVar "elseE"))))))))))))))))))))))
(DTypeSig false "ifPlain" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "ifPlain" () (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "cond")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TThen"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseBranch")) (ELam ((PVar "thenE")) (EApp (EApp (EMethodRef "deferThen") (EVar "elseBranch")) (ELam ((PVar "elseE")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "EIf") (EVar "cond")) (EVar "thenE")) (EVar "elseE"))))))))))))
(DTypeSig false "elseBranch" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "elseBranch" () (EApp (EApp (EVar "parseOrElse") (EVar "elsePresent")) (EApp (EMethodRef "deferPure") (EApp (EVar "ELit") (EVar "LUnit")))))
(DTypeSig false "elsePresent" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "elsePresent" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TElse"))) (ELam (PWild) (EVar "parseBranch"))))
(DTypeSig false "parseBranch" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseBranch" () (EApp (EApp (EVar "parseOrElse") (EVar "branchBlock")) (EVar "parseExpr")))
(DTypeSig false "branchBlock" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "branchBlock" () (EVar "parseBracketBlock"))
(DTypeSig false "parseLet" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseLet" () (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TLet"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "letExprKind") (EVar "t"))) (ELam ((PVar "e")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "atLetSite") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EBinOp "+" (EVar "s") (ELit (LInt 1))))) (EVar "e"))))))))))))))
(DTypeSig false "letExprKind" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "letExprKind" ((PCon "TMut")) (EApp (EVar "failP") (EVar "letMutRemovedMsg")))
(DFunDef false "letExprKind" ((PCon "TRec")) (EVar "letRecExpr"))
(DFunDef false "letExprKind" ((PCon "TIdent" (PVar "name"))) (EApp (EVar "letIdentExpr") (EVar "name")))
(DFunDef false "letExprKind" (PWild) (EVar "letPatExpr"))
(DTypeSig false "letIdentExpr" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "letIdentExpr" ((PVar "name")) (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "params")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EApp (EVar "letIdentExprRest") (EVar "name")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EBinOp "+" (EVar "s") (ELit (LInt 1))))) (EVar "params")) (EVar "t")))))))))))))
(DTypeSig false "letIdentExprRest" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))))
(DFunDef false "letIdentExprRest" ((PVar "name") (PVar "nameLoc") (PList) (PCon "TColon")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "e1")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TIn"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "noDeclLoc")) (EVar "False")) (EApp (EApp (EApp (EVar "PVar") (EVar "name")) (EVar "nameLoc")) (EVar "noBinderId"))) (EApp (EApp (EVar "EAnnot") (EVar "e1")) (EVar "ty"))) (EVar "e2"))))))))))))))))
(DFunDef false "letIdentExprRest" ((PVar "name") (PVar "nameLoc") (PList) (PCon "TEqual")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "e1")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TIn"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "noDeclLoc")) (EVar "False")) (EApp (EApp (EApp (EVar "PVar") (EVar "name")) (EVar "nameLoc")) (EVar "noBinderId"))) (EVar "e1")) (EVar "e2"))))))))))))
(DFunDef false "letIdentExprRest" ((PVar "name") (PVar "nameLoc") (PVar "params") (PCon "TEqual")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "e1")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TIn"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "noDeclLoc")) (EVar "True")) (EApp (EApp (EApp (EVar "PVar") (EVar "name")) (EVar "nameLoc")) (EVar "noBinderId"))) (EApp (EApp (EVar "curryLam") (EVar "params")) (EVar "e1"))) (EVar "e2"))))))))))))
(DFunDef false "letIdentExprRest" (PWild PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected `:` or `=` after the `let` name"))))
(DTypeSig false "letPatExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "letPatExpr" () (EApp (EApp (EMethodRef "deferThen") (EVar "parsePat")) (ELam ((PVar "pat")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "e1")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TIn"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "noDeclLoc")) (EVar "False")) (EVar "pat")) (EVar "e1")) (EVar "e2"))))))))))))))
(DTypeSig false "letRecExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "letRecExpr" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRec"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "letRecInlineClause")) (ELam ((PVar "clause")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TIn"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "ELetGroup") (EApp (EVar "coalesceClauses") (EListLit (EVar "clause")))) (EVar "e2"))))))))))))
(DTypeSig false "letRecInlineClause" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyCon "Loc"))))
(DFunDef false "letRecInlineClause" () (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "body")) (EApp (EMethodRef "deferPure") (ETuple (EVar "name") (EVar "pats") (EVar "body") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EBinOp "+" (EVar "s") (ELit (LInt 1)))))))))))))))))))
(DTypeSig false "parseMatch" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseMatch" () (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "matchPos")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TMatch"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "scrut")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "parseArms") (EVar "matchPos"))) (ELam ((PVar "arms")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "EMatch") (EVar "scrut")) (EVar "arms"))))))))))))))))
(DTypeSig false "parseArms" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Arm")))))
(DFunDef false "parseArms" ((PVar "matchPos")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "armsLoop") (EVar "matchPos")))))
(DTypeSig false "armsLoop" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Arm")))))
(DFunDef false "armsLoop" ((PVar "matchPos")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EIf (EBinOp "==" (EVar "t") (EVar "TDedent")) (EApp (EMethodRef "deferPure") (EListLit)) (EApp (EVar "armsCons") (EVar "matchPos"))))))
(DTypeSig false "armsCons" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Arm")))))
(DFunDef false "armsCons" ((PVar "matchPos")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "parseArm") (EVar "matchPos"))) (ELam ((PVar "a")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "armsLoop") (EVar "matchPos"))) (ELam ((PVar "rest")) (EApp (EMethodRef "deferPure") (EBinOp "::" (EVar "a") (EVar "rest"))))))))))
(DTypeSig false "parseArm" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyCon "Arm"))))
(DFunDef false "parseArm" ((PVar "matchPos")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "parseArmPat")) (EVar "pos")) (arm (PCon "POk" (PVar "pat") (PVar "q")) () (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EApp (EApp (EVar "parseArmRest") (EVar "pos")) (EVar "pat"))) (EVar "q"))) (arm (PCon "PFatal" (PVar "f") (PVar "q")) () (EApp (EApp (EVar "PFatal") (EVar "f")) (EVar "q"))) (arm (PCon "PErr" PWild PWild) () (EBlock (DoLet false false (PVar "hint") (EIf (EApp (EVar "contextHasTab") (EVar "ctx")) (EVar "None") (EApp (EApp (EApp (EApp (EApp (EVar "matchContinuationHint") (EApp (EVar "contextTokens") (EVar "ctx"))) (EApp (EVar "contextOffsets") (EVar "ctx"))) (EApp (EVar "contextLineStarts") (EVar "ctx"))) (EVar "matchPos")) (EVar "pos")))) (DoLet false false (PVar "kind") (EApp (EApp (EVar "optionOr") (EVar "ExpectedMatchArm")) (EVar "hint"))) (DoExpr (EApp (EApp (EVar "PFatal") (EApp (EVar "FailProblem") (EVar "kind"))) (EVar "pos")))))))))
(DTypeSig false "parseArmRest" (TyFun (TyCon "Int") (TyFun (TyCon "Pat") (TyApp (TyCon "Parser") (TyCon "Arm")))))
(DFunDef false "parseArmRest" ((PVar "p") (PVar "pat")) (EApp (EApp (EMethodRef "deferThen") (EVar "armGuardOpt")) (ELam ((PVar "guards")) (EApp (EApp (EMethodRef "deferThen") (EVar "matchArrow")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "matchBody")) (ELam ((PVar "body")) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "recordUnitStart") (ELit (LInt 0))) (EVar "p"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "Arm") (EVar "pat")) (EVar "guards")) (EVar "body"))))))))))))
(DTypeSig false "matchArrow" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "matchArrow" () (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EApp (EVar "expectTok") (EVar "TFatArrow"))) (EVar "pos")) (arm (PCon "PErr" PWild (PVar "q")) () (EApp (EApp (EVar "PFatal") (EApp (EVar "FailProblem") (EVar "ExpectedMatchArrow"))) (EVar "q"))) (arm (PVar "r") () (EVar "r"))))))
(DTypeSig false "matchBody" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "matchBody" () (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EApp (EApp (EVar "parseOrElse") (EVar "branchBlock")) (EVar "parseBodyExpr"))) (EVar "pos")) (arm (PCon "PErr" (PVar "f") (PVar "q")) () (EApp (EApp (EVar "PFatal") (EVar "f")) (EVar "q"))) (arm (PVar "r") () (EVar "r"))))))
(DTypeSig false "armGuardOpt" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Guard"))))
(DFunDef false "armGuardOpt" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "armGuardFor") (EVar "t")))))
(DTypeSig false "armGuardFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Guard")))))
(DFunDef false "armGuardFor" ((PCon "TIf")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "sepBy1") (EVar "parseGuard")) (EApp (EVar "expectTok") (EVar "TComma"))))))
(DFunDef false "armGuardFor" (PWild) (EApp (EMethodRef "deferPure") (EListLit)))
(DTypeSig false "parseArmPat" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parseArmPat" () (EApp (EApp (EMethodRef "deferThen") (EVar "parsePat")) (ELam ((PVar "p")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "armPatAlts") (EListLit (EVar "p"))) (EVar "t")))))))
(DTypeSig false "armPatAlts" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat")))))
(DFunDef false "armPatAlts" ((PVar "acc") (PCon "TPipe")) (EApp (EVar "barSteer") (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parsePat")) (ELam ((PVar "q")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "armAltEnd") (EBinOp "::" (EVar "q") (EVar "acc"))) (EVar "t"))))))))))
(DFunDef false "armPatAlts" ((PVar "acc") PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "orPatOf") (EApp (EVar "reverseL") (EVar "acc")))))
(DTypeSig false "armAltEnd" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat")))))
(DFunDef false "armAltEnd" ((PVar "acc") (PCon "TPipe")) (EApp (EApp (EVar "armPatAlts") (EVar "acc")) (EVar "TPipe")))
(DFunDef false "armAltEnd" ((PVar "acc") (PCon "TFatArrow")) (EApp (EApp (EVar "armPatAlts") (EVar "acc")) (EVar "TFatArrow")))
(DFunDef false "armAltEnd" ((PVar "acc") (PCon "TIf")) (EApp (EApp (EVar "armPatAlts") (EVar "acc")) (EVar "TIf")))
(DFunDef false "armAltEnd" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected `=>` after the alternative"))))
(DTypeSig false "barSteer" (TyFun (TyApp (TyCon "Parser") (TyVar "a")) (TyApp (TyCon "Parser") (TyVar "a"))))
(DFunDef false "barSteer" ((PVar "p")) (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "p")) (EVar "pos")) (arm (PCon "PErr" PWild PWild) () (EApp (EApp (EVar "PFatal") (EApp (EVar "FailProblem") (EApp (EVar "barSteerKind") (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "peek2P")) (EVar "pos"))))) (EVar "pos"))) (arm (PVar "r") () (EVar "r"))))))
(DTypeSig false "barSteerKind" (TyFun (TyApp (TyCon "PR") (TyCon "Token")) (TyCon "ParseDiagnosticKind")))
(DFunDef false "barSteerKind" ((PCon "POk" (PCon "TIndent") PWild)) (EVar "MatchGuardBarWrapped"))
(DFunDef false "barSteerKind" (PWild) (EVar "MatchGuardBar"))
(DTypeSig false "parsePat" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePat" () (EVar "parsePatCons"))
(DTypeSig false "parseAsPat" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parseAsPat" () (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "identNameP")) (ELam ((PVar "x")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TAsAt"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parsePatApp")) (ELam ((PVar "sub")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EVar "PAs") (EVar "x")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))) (EVar "noBinderId")) (EMethodRef "sub"))))))))))))))))
(DTypeSig false "parsePatCons" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatCons" () (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "parseOrElse") (EVar "parseAsPat")) (EVar "parsePatApp"))) (ELam ((PVar "p")) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "patConsTail") (EVar "p"))) (EApp (EMethodRef "deferPure") (EVar "p"))))))
(DTypeSig false "patConsTail" (TyFun (TyCon "Pat") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "patConsTail" ((PVar "p")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TCons"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parsePatCons")) (ELam ((PVar "q")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "PCons") (EVar "p")) (EVar "q"))))))))
(DTypeSig false "parsePatApp" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatApp" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "patAppFor") (EVar "t")))))
(DTypeSig false "patAppFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "patAppFor" ((PCon "TUpper" (PVar "c"))) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "upperQualTail") (EVar "c"))) (ELam ((PVar "n")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "upperPatRest") (EVar "n")) (EVar "t")))))))))
(DFunDef false "patAppFor" (PWild) (EVar "parsePatAtom"))
(DTypeSig false "upperPatRest" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat")))))
(DFunDef false "upperPatRest" ((PVar "c") (PCon "TLBrace")) (EApp (EVar "recordPat") (EVar "c")))
(DFunDef false "upperPatRest" ((PVar "c") PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "many") (EVar "parsePatAtom"))) (ELam ((PVar "args")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "PCon") (EVar "c")) (EVar "args"))))))
(DTypeSig false "recordPat" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "recordPat" ((PVar "c")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TLBrace"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "recordPatFields")) (ELam ((PVar "fr")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "mkRec") (EVar "c")) (EVar "fr"))))))))))
(DTypeSig false "mkRec" (TyFun (TyCon "String") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool")) (TyCon "Pat"))))
(DFunDef false "mkRec" ((PVar "c") (PTuple (PVar "fields") (PVar "rest"))) (EApp (EApp (EApp (EVar "PRec") (EVar "c")) (EVar "fields")) (EVar "rest")))
(DTypeSig false "recordPatFields" (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool"))))
(DFunDef false "recordPatFields" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "recordPatFieldsFor") (EVar "t")))))
(DTypeSig false "recordPatFieldsFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool")))))
(DFunDef false "recordPatFieldsFor" ((PCon "TEllipsis")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "deferPure") (ETuple (EListLit) (EVar "True"))))))
(DFunDef false "recordPatFieldsFor" ((PCon "TRBrace")) (EApp (EMethodRef "deferPure") (ETuple (EListLit) (EVar "False"))))
(DFunDef false "recordPatFieldsFor" (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "recordPatField")) (ELam ((PVar "f")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "recordPatFieldsRest") (EVar "f")) (EVar "t")))))))
(DTypeSig false "recordPatFieldsRest" (TyFun (TyCon "RecPatField") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool"))))))
(DFunDef false "recordPatFieldsRest" ((PVar "f") (PCon "TComma")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "recordPatFields")) (ELam ((PVar "fr")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "consField") (EVar "f")) (EVar "fr"))))))))
(DFunDef false "recordPatFieldsRest" ((PVar "f") PWild) (EApp (EMethodRef "deferPure") (ETuple (EListLit (EVar "f")) (EVar "False"))))
(DTypeSig false "consField" (TyFun (TyCon "RecPatField") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool")) (TyTuple (TyApp (TyCon "List") (TyCon "RecPatField")) (TyCon "Bool")))))
(DFunDef false "consField" ((PVar "f") (PTuple (PVar "fs") (PVar "rest"))) (ETuple (EBinOp "::" (EVar "f") (EVar "fs")) (EVar "rest")))
(DTypeSig false "recordPatField" (TyApp (TyCon "Parser") (TyCon "RecPatField")))
(DFunDef false "recordPatField" () (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "recordPatFieldRest") (EVar "name")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EBinOp "+" (EVar "s") (ELit (LInt 1))))) (EVar "t")))))))))))
(DTypeSig false "recordPatFieldRest" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "RecPatField"))))))
(DFunDef false "recordPatFieldRest" ((PVar "name") (PVar "nameLoc") (PCon "TEqual")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parsePat")) (ELam ((PVar "p")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EVar "RecPatField") (EVar "name")) (EVar "nameLoc")) (EVar "noBinderId")) (EApp (EVar "Some") (EVar "p")))))))))
(DFunDef false "recordPatFieldRest" ((PVar "name") (PVar "nameLoc") PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EVar "RecPatField") (EVar "name")) (EVar "nameLoc")) (EVar "noBinderId")) (EVar "None"))))
(DTypeSig false "reservedIdentKeyword" (TyFun (TyCon "Token") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TWith")) (EApp (EVar "Some") (ELit (LString "with"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TMut")) (EApp (EVar "Some") (ELit (LString "mut"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TIn")) (EApp (EVar "Some") (ELit (LString "in"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TMatch")) (EApp (EVar "Some") (ELit (LString "match"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TData")) (EApp (EVar "Some") (ELit (LString "data"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TInterface")) (EApp (EVar "Some") (ELit (LString "interface"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TDefault")) (EApp (EVar "Some") (ELit (LString "default"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TImpl")) (EApp (EVar "Some") (ELit (LString "impl"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TImport")) (EApp (EVar "Some") (ELit (LString "import"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TExport")) (EApp (EVar "Some") (ELit (LString "export"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TPublic")) (EApp (EVar "Some") (ELit (LString "public"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TWhere")) (EApp (EVar "Some") (ELit (LString "where"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TOf")) (EApp (EVar "Some") (ELit (LString "of"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TDo")) (EApp (EVar "Some") (ELit (LString "do"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TDefer")) (EApp (EVar "Some") (ELit (LString "defer"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TAs")) (EApp (EVar "Some") (ELit (LString "as"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TExtern")) (EApp (EVar "Some") (ELit (LString "extern"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TRequires")) (EApp (EVar "Some") (ELit (LString "requires"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TDeriving")) (EApp (EVar "Some") (ELit (LString "deriving"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TType")) (EApp (EVar "Some") (ELit (LString "type"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TNewtype")) (EApp (EVar "Some") (ELit (LString "newtype"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TProp")) (EApp (EVar "Some") (ELit (LString "prop"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TTest")) (EApp (EVar "Some") (ELit (LString "test"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TBench")) (EApp (EVar "Some") (ELit (LString "bench"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TEffect")) (EApp (EVar "Some") (ELit (LString "effect"))))
(DFunDef false "reservedIdentKeyword" ((PCon "TFunction")) (EApp (EVar "Some") (ELit (LString "function"))))
(DFunDef false "reservedIdentKeyword" (PWild) (EVar "None"))
(DTypeSig false "reservedKeywordMsg" (TyFun (TyCon "String") (TyCon "ParseDiagnosticKind")))
(DFunDef false "reservedKeywordMsg" ((PVar "name")) (EApp (EVar "ReservedKeyword") (EVar "name")))
(DTypeSig false "reservedOrPatFail" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "reservedOrPatFail" ((PVar "t")) (EMatch (EApp (EVar "reservedIdentKeyword") (EVar "t")) (arm (PCon "Some" (PVar "name")) () (EApp (EVar "fatalP") (EApp (EVar "reservedKeywordMsg") (EVar "name")))) (arm (PCon "None") () (EApp (EVar "failP") (ELit (LString "expected a pattern"))))))
(DTypeSig false "parsePatAtom" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatAtom" () (EApp (EApp (EApp (EVar "withDepth") (EVar "maxNestDepth")) (EApp (EVar "FailMsg") (EVar "nestTooDeepMsg"))) (EVar "parsePatAtomRaw")))
(DTypeSig false "parsePatAtomRaw" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatAtomRaw" () (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TIdent" (PVar "x")) () (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EBinOp "+" (EVar "s") (ELit (LInt 1))))) (EVar "noBinderId")))))))) (arm (PCon "TUnderscore") () (EApp (EVar "emit") (EVar "PWild"))) (arm (PCon "TInt" (PVar "n") PWild) ((GBool (EApp (EVar "isIntMinLit") (EVar "n")))) (EApp (EVar "fatalP") (EVar "intLitTooBigMsg"))) (arm (PCon "TInt" (PVar "n") PWild) () (EApp (EVar "intPatRest") (EApp (EVar "LInt") (EVar "n")))) (arm (PCon "TWideInt" PWild PWild (PVar "lx")) () (EApp (EVar "fatalP") (EApp (EVar "widePatMsg") (EVar "lx")))) (arm (PCon "TMinus") () (EVar "negIntPat")) (arm (PCon "TMinusTight") () (EVar "negIntPat")) (arm (PCon "TFloat" (PVar "f")) () (EApp (EVar "emit") (EApp (EVar "PLit") (EApp (EVar "LFloat") (EVar "f"))))) (arm (PCon "TString" (PVar "s")) () (EApp (EVar "emit") (EApp (EVar "PLit") (EApp (EVar "LString") (EVar "s"))))) (arm (PCon "TChar" (PVar "s")) () (EApp (EVar "charPatRest") (EApp (EVar "LChar") (EVar "s")))) (arm (PCon "TByte" (PVar "n")) () (EApp (EVar "bytePatRest") (EApp (EVar "LByte") (EVar "n")))) (arm (PCon "TUpper" (PVar "c")) () (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "upperQualTail") (EVar "c"))) (ELam ((PVar "n")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t2")) (EApp (EApp (EVar "upperAtomRest") (EVar "n")) (EVar "t2"))))))))) (arm (PCon "TLParen") () (EVar "parsePatParen")) (arm (PCon "TLBracket") () (EVar "parsePatList")) (arm PWild () (EApp (EVar "reservedOrPatFail") (EVar "t")))))))))
(DTypeSig false "upperAtomRest" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat")))))
(DFunDef false "upperAtomRest" ((PVar "c") (PCon "TLBrace")) (EApp (EVar "recordPat") (EVar "c")))
(DFunDef false "upperAtomRest" ((PVar "c") PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "PCon") (EVar "c")) (EListLit))))
(DTypeSig false "parseParamPat" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parseParamPat" () (EApp (EApp (EVar "parseOrElse") (EVar "parseParamAsPat")) (EVar "parsePatAtom")))
(DTypeSig false "parseParamAsPat" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parseParamAsPat" () (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "identNameP")) (ELam ((PVar "x")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TAsAt"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parsePatAtom")) (ELam ((PVar "sub")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EVar "PAs") (EVar "x")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))) (EVar "noBinderId")) (EMethodRef "sub"))))))))))))))))
(DTypeSig false "intPatRest" (TyFun (TyCon "Lit") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "intPatRest" ((PVar "lo")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "rngPatRest") (EVar "lo")) (EVar "intBound")) (EVar "t")))))))
(DTypeSig false "negIntPat" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "negIntPat" () (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TInt" (PVar "n") PWild) () (EApp (EVar "negIntRng") (EApp (EVar "LInt") (EApp (EVar "negateLiteral") (EVar "n"))))) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected an integer after `-`"))))))))))
(DTypeSig false "negIntRng" (TyFun (TyCon "Lit") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "negIntRng" ((PVar "lo")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TDotDot") () (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "intBound")) (ELam ((PVar "hi")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "PRng") (EVar "lo")) (EVar "hi")) (EVar "False")))))))) (arm (PCon "TDotDotEq") () (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "intBound")) (ELam ((PVar "hi")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "PRng") (EVar "lo")) (EVar "hi")) (EVar "True")))))))) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected `..` or `..=` after the range bound"))))))))))
(DTypeSig false "charPatRest" (TyFun (TyCon "Lit") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "charPatRest" ((PVar "lo")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "rngPatRest") (EVar "lo")) (EVar "charBound")) (EVar "t")))))))
(DTypeSig false "bytePatRest" (TyFun (TyCon "Lit") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "bytePatRest" ((PVar "lo")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "rngPatRest") (EVar "lo")) (EVar "byteBound")) (EVar "t")))))))
(DTypeSig false "rngPatRest" (TyFun (TyCon "Lit") (TyFun (TyApp (TyCon "Parser") (TyCon "Lit")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat"))))))
(DFunDef false "rngPatRest" ((PVar "lo") (PVar "bound") (PCon "TDotDot")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "bound")) (ELam ((PVar "hi")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "PRng") (EVar "lo")) (EVar "hi")) (EVar "False"))))))))
(DFunDef false "rngPatRest" ((PVar "lo") (PVar "bound") (PCon "TDotDotEq")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "bound")) (ELam ((PVar "hi")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "PRng") (EVar "lo")) (EVar "hi")) (EVar "True"))))))))
(DFunDef false "rngPatRest" ((PVar "lo") PWild PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "PLit") (EVar "lo"))))
(DTypeSig false "intBound" (TyApp (TyCon "Parser") (TyCon "Lit")))
(DFunDef false "intBound" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "intBoundFor") (EVar "t")))))
(DTypeSig false "intBoundFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Lit"))))
(DFunDef false "intBoundFor" ((PCon "TInt" (PVar "n") PWild)) (EIf (EApp (EVar "isIntMinLit") (EVar "n")) (EApp (EVar "fatalP") (EVar "intLitTooBigMsg")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "intBoundFor" ((PCon "TInt" (PVar "n") PWild)) (EApp (EVar "emit") (EApp (EVar "LInt") (EVar "n"))))
(DFunDef false "intBoundFor" ((PCon "TWideInt" PWild PWild (PVar "lx"))) (EApp (EVar "fatalP") (EApp (EVar "widePatMsg") (EVar "lx"))))
(DFunDef false "intBoundFor" ((PCon "TMinus")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TInt" (PVar "n") PWild) () (EApp (EVar "emit") (EApp (EVar "LInt") (EApp (EVar "negateLiteral") (EVar "n"))))) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected an integer after `-` in the range bound"))))))))))
(DFunDef false "intBoundFor" ((PCon "TMinusTight")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TInt" (PVar "n") PWild) () (EApp (EVar "emit") (EApp (EVar "LInt") (EApp (EVar "negateLiteral") (EVar "n"))))) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected an integer after `-` in the range bound"))))))))))
(DFunDef false "intBoundFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected an integer range bound"))))
(DTypeSig false "charBound" (TyApp (TyCon "Parser") (TyCon "Lit")))
(DFunDef false "charBound" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "charBoundFor") (EVar "t")))))
(DTypeSig false "byteBound" (TyApp (TyCon "Parser") (TyCon "Lit")))
(DFunDef false "byteBound" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "byteBoundFor") (EVar "t")))))
(DTypeSig false "byteBoundFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Lit"))))
(DFunDef false "byteBoundFor" ((PCon "TByte" (PVar "n"))) (EApp (EVar "emit") (EApp (EVar "LByte") (EVar "n"))))
(DFunDef false "byteBoundFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected a byte range bound"))))
(DTypeSig false "charBoundFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Lit"))))
(DFunDef false "charBoundFor" ((PCon "TChar" (PVar "s"))) (EApp (EVar "emit") (EApp (EVar "LChar") (EVar "s"))))
(DFunDef false "charBoundFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected a character range bound"))))
(DTypeSig false "tuplePatOrSingle" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Pat")))
(DFunDef false "tuplePatOrSingle" ((PList (PVar "p"))) (EVar "p"))
(DFunDef false "tuplePatOrSingle" ((PVar "ps")) (EApp (EVar "PTuple") (EVar "ps")))
(DTypeSig false "parsePatParen" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatParen" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TLParen"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "patParenFor") (EVar "t")))))))
(DTypeSig false "patParenFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "patParenFor" ((PCon "TRParen")) (EApp (EVar "emit") (EApp (EVar "PLit") (EVar "LUnit"))))
(DFunDef false "patParenFor" (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "parsePatAlts")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "ps")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "optTrailingCommaTuple") (EVar "ps"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "tuplePatOrSingle") (EVar "ps"))))))))))
(DTypeSig false "parsePatAlts" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatAlts" () (EApp (EApp (EMethodRef "deferThen") (EVar "parsePat")) (ELam ((PVar "p")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "many") (EVar "patAlt"))) (ELam ((PVar "rest")) (EApp (EMethodRef "deferPure") (EApp (EVar "orPatOf") (EBinOp "::" (EVar "p") (EVar "rest")))))))))
(DTypeSig false "patAlt" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "patAlt" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TPipe"))) (ELam (PWild) (EVar "parsePat"))))
(DTypeSig false "parsePatList" (TyApp (TyCon "Parser") (TyCon "Pat")))
(DFunDef false "parsePatList" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TLBracket"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "patListFor") (EVar "t")))))))
(DTypeSig false "patListFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Pat"))))
(DFunDef false "patListFor" ((PCon "TRBracket")) (EApp (EVar "emit") (EApp (EVar "PList") (EListLit))))
(DFunDef false "patListFor" (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "parsePat")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "ps")) (EApp (EApp (EMethodRef "deferThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRBracket"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "PList") (EVar "ps"))))))))))
(DTypeSig false "parseTy" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTy" () (EApp (EApp (EMethodRef "deferThen") (EVar "parseTyFun")) (ELam ((PVar "lhs")) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "constraintTail") (EVar "lhs"))) (EApp (EMethodRef "deferPure") (EVar "lhs"))))))
(DTypeSig false "constraintTail" (TyFun (TyCon "Ty") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "constraintTail" ((PVar "lhs")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TFatArrow"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "tyArrowSkipLayout") (EVar "t"))) (ELam ((PVar "indented")) (EApp (EApp (EMethodRef "deferThen") (EVar "parseTy")) (ELam ((PVar "rhs")) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EDictApp "deferWhen") (EVar "indented")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "expectTok") (EVar "TDedent")))))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "TyConstrained") (EApp (EVar "extractConstraints") (EVar "lhs"))) (EVar "rhs"))))))))))))))
(DTypeSig false "extractConstraints" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "Constraint"))))
(DFunDef false "extractConstraints" ((PCon "TyApp" (PVar "f") (PVar "a"))) (EMatch (EApp (EVar "tyAppSpine") (EApp (EApp (EVar "TyApp") (EVar "f")) (EVar "a"))) (arm (PCon "Some" (PTuple (PVar "iface") (PVar "args"))) () (EListLit (EApp (EApp (EVar "constraintUnresolved") (EVar "iface")) (EVar "args")))) (arm (PCon "None") () (EListLit))))
(DFunDef false "extractConstraints" ((PRec "TyCon" ((rf "tyConName" (PVar "iface"))) false)) (EListLit (EApp (EApp (EVar "constraintUnresolved") (EVar "iface")) (EListLit))))
(DFunDef false "extractConstraints" ((PCon "TyTuple" (PVar "cs"))) (EApp (EVar "concatMapC") (EVar "cs")))
(DFunDef false "extractConstraints" (PWild) (EListLit))
(DTypeSig false "tyAppSpine" (TyFun (TyCon "Ty") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty"))))))
(DFunDef false "tyAppSpine" ((PVar "t")) (EApp (EApp (EVar "tyAppSpineAcc") (EVar "t")) (EListLit)))
(DTypeSig false "tyAppSpineAcc" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Ty")))))))
(DFunDef false "tyAppSpineAcc" ((PRec "TyCon" ((rf "tyConName" (PVar "iface"))) false) (PVar "acc")) (EApp (EVar "Some") (ETuple (EVar "iface") (EVar "acc"))))
(DFunDef false "tyAppSpineAcc" ((PCon "TyApp" (PVar "f") (PVar "a")) (PVar "acc")) (EApp (EApp (EVar "tyAppSpineAcc") (EVar "f")) (EBinOp "::" (EVar "a") (EVar "acc"))))
(DFunDef false "tyAppSpineAcc" (PWild PWild) (EVar "None"))
(DTypeSig false "concatMapC" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyApp (TyCon "List") (TyCon "Constraint"))))
(DFunDef false "concatMapC" ((PList)) (EListLit))
(DFunDef false "concatMapC" ((PCons (PVar "t") (PVar "rest"))) (EBinOp "++" (EApp (EVar "extractConstraints") (EVar "t")) (EApp (EVar "concatMapC") (EVar "rest"))))
(DTypeSig false "parseTyFun" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyFun" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "tyFor") (EVar "t")))))
(DTypeSig false "tyFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "tyFor" ((PCon "TLt")) (EVar "parseEffectTy"))
(DFunDef false "tyFor" (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseTyApp")) (ELam ((PVar "left")) (EApp (EVar "tyAfterApp") (EVar "left")))))
(DTypeSig false "tyAfterApp" (TyFun (TyCon "Ty") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "tyAfterApp" ((PAs "left" (PCon "TyNamed" PWild PWild PWild))) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "tyArrowTail") (EVar "left"))) (EApp (EVar "failP") (EVar "namedArgNeedsArrowMsg"))))
(DFunDef false "tyAfterApp" ((PVar "left")) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "tyArrowTail") (EVar "left"))) (EApp (EMethodRef "deferPure") (EVar "left"))))
(DTypeSig false "namedArgNeedsArrowMsg" (TyCon "String"))
(DFunDef false "namedArgNeedsArrowMsg" () (ELit (LString "a named argument `(name : T)` must be followed by `->`, as in `(path : String) -> <FileRead path> Result String String`")))
(DTypeSig false "parseEffectTy" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseEffectTy" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TLt"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "effectBody")) (ELam ((PVar "body")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TGt"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseTy")) (ELam ((PVar "inner")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "mkEffect") (EVar "body")) (EVar "inner"))))))))))))
(DTypeSig false "mkEffect" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "mkEffect" ((PTuple (PVar "labels") (PVar "tail")) (PVar "inner")) (EApp (EApp (EApp (EVar "TyEffect") (EVar "labels")) (EVar "tail")) (EVar "inner")))
(DTypeSig false "effectBody" (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "effectBody" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "effectBodyFor") (EVar "t")))))
(DTypeSig false "effectBodyFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "effectBodyFor" ((PCon "TUpper" PWild)) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "effAtomP")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "labels")) (EApp (EApp (EMethodRef "deferThen") (EVar "pipeTail")) (ELam ((PVar "tail")) (EApp (EMethodRef "deferPure") (ETuple (EVar "labels") (EVar "tail"))))))))
(DFunDef false "effectBodyFor" ((PCon "TIdent" PWild)) (EApp (EApp (EMethodRef "deferThen") (EVar "identNameP")) (ELam ((PVar "v")) (EApp (EApp (EMethodRef "deferThen") (EVar "pipeTail")) (ELam ((PVar "rest")) (EApp (EMethodRef "deferPure") (ETuple (EListLit) (EBinOp "::" (EVar "v") (EVar "rest")))))))))
(DFunDef false "effectBodyFor" (PWild) (EApp (EMethodRef "deferPure") (ETuple (EListLit) (EListLit))))
(DTypeSig false "effAtomP" (TyApp (TyCon "Parser") (TyCon "EffAtomTy")))
(DFunDef false "effAtomP" () (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "upperNameP")) (ELam ((PVar "l")) (EApp (EApp (EMethodRef "deferThen") (EVar "effParamP")) (ELam ((PVar "p")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "effAtomAt") (EVar "l")) (EVar "p")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q")))))))))))))))
(DTypeSig false "effParamP" (TyApp (TyCon "Parser") (TyCon "EffParamTy")))
(DFunDef false "effParamP" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EVar "effParamDispatch") (EVar "t")) (EVar "t2")))))))
(DTypeSig false "effParamDispatch" (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "EffParamTy")))))
(DFunDef false "effParamDispatch" ((PCon "TUpper" PWild) (PCon "TEqual")) (EApp (EVar "productParamP") (EVar "True")))
(DFunDef false "effParamDispatch" ((PVar "t") PWild) (EApp (EVar "effParamFor") (EVar "t")))
(DTypeSig false "productParamP" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "EffParamTy"))))
(DFunDef false "productParamP" ((PVar "named")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "productAxes") (EVar "named"))) (ELam ((PVar "axes")) (EApp (EMethodRef "deferPure") (EApp (EVar "EPProduct") (EVar "axes"))))))
(DTypeSig false "productAxes" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))))))
(DFunDef false "productAxes" ((PVar "named")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "productAxis") (EVar "named"))) (ELam ((PVar "a")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "productAxesMore") (EVar "named"))) (ELam ((PVar "rest")) (EApp (EMethodRef "deferPure") (EBinOp "::" (EVar "a") (EVar "rest"))))))))
(DTypeSig false "productAxesMore" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))))))
(DFunDef false "productAxesMore" ((PVar "named")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EApp (EVar "productAxesMoreFor") (EVar "named")) (EVar "t")) (EVar "t2")))))))
(DTypeSig false "productAxesMoreFor" (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "EffParamTy"))))))))
(DFunDef false "productAxesMoreFor" ((PVar "named") (PCon "TUpper" PWild) (PCon "TEqual")) (EApp (EVar "productAxes") (EVar "named")))
(DFunDef false "productAxesMoreFor" (PWild PWild PWild) (EApp (EMethodRef "deferPure") (EListLit)))
(DTypeSig false "productAxis" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyCon "EffParamTy")))))
(DFunDef false "productAxis" ((PVar "named")) (EApp (EApp (EMethodRef "deferThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "productAxisVal") (EVar "named"))) (ELam ((PVar "v")) (EApp (EMethodRef "deferPure") (ETuple (EVar "name") (EVar "v"))))))))))
(DTypeSig false "productAxisVal" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "EffParamTy"))))
(DFunDef false "productAxisVal" ((PVar "named")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "productAxisValFor") (EVar "named")) (EVar "t")))))
(DTypeSig false "productAxisValFor" (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "EffParamTy")))))
(DFunDef false "productAxisValFor" (PWild (PCon "TString" (PVar "s"))) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "EPLit") (EVar "s"))))))
(DFunDef false "productAxisValFor" (PWild (PCon "TLBrace")) (EVar "effSetLiteralP"))
(DFunDef false "productAxisValFor" ((PCon "True") (PCon "TIdent" (PVar "n"))) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "EPName") (EVar "n"))))))
(DFunDef false "productAxisValFor" ((PCon "True") PWild) (EApp (EVar "failP") (ELit (LString "expected an axis value: a `\"prefix\"`, a `{set}` or an argument name"))))
(DFunDef false "productAxisValFor" ((PCon "False") (PCon "TIdent" PWild)) (EApp (EVar "failP") (ELit (LString "an axis of an authority term takes a `\"prefix\"` or a `{set}`; an argument name is allowed only in an effect row"))))
(DFunDef false "productAxisValFor" ((PCon "False") PWild) (EApp (EVar "failP") (ELit (LString "expected an axis value: a `\"prefix\"` or a `{set}`"))))
(DTypeSig false "effParamFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "EffParamTy"))))
(DFunDef false "effParamFor" ((PCon "TString" (PVar "s"))) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "pos")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EIf (EBinOp "==" (EVar "s") (ELit (LString "_"))) (EApp (EApp (EVar "fatalAtP") (EVar "effHoleRetiredMsg")) (EVar "pos")) (EApp (EMethodRef "deferPure") (EApp (EVar "EPLit") (EVar "s")))))))))
(DFunDef false "effParamFor" ((PCon "TUnderscore")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "pos")) (EApp (EApp (EVar "fatalAtP") (EVar "effHoleRetiredMsg")) (EVar "pos")))))
(DFunDef false "effParamFor" ((PCon "TIdent" (PVar "n"))) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "EPName") (EVar "n"))))))
(DFunDef false "effParamFor" ((PCon "TLBrace")) (EVar "effSetLiteralP"))
(DFunDef false "effParamFor" (PWild) (EApp (EMethodRef "deferPure") (EVar "EPTop")))
(DTypeSig false "effSetLiteralP" (TyApp (TyCon "Parser") (TyCon "EffParamTy")))
(DFunDef false "effSetLiteralP" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TLBrace"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "stringLitP")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "elems")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "EPSet") (EVar "elems"))))))))))
(DTypeSig false "effHoleRetiredMsg" (TyCon "String"))
(DFunDef false "effHoleRetiredMsg" () (ELit (LString "the `_` effect parameter is not accepted; write the bare label `<FileRead>` for any authority, or name the argument that determines it, `<FileRead path>`")))
(DTypeSig false "pipeTail" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "pipeTail" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "pipeTailFor") (EVar "t")))))
(DTypeSig false "pipeTailFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "pipeTailFor" ((PCon "TPipe")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "identNameP")) (ELam ((PVar "v")) (EApp (EApp (EMethodRef "deferThen") (EVar "pipeTail")) (ELam ((PVar "rest")) (EApp (EMethodRef "deferPure") (EBinOp "::" (EVar "v") (EVar "rest"))))))))))
(DFunDef false "pipeTailFor" (PWild) (EApp (EMethodRef "deferPure") (EListLit)))
(DTypeSig false "upperNameP" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "upperNameP" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "upperNameFor") (EVar "t")))))
(DTypeSig false "upperNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "upperNameFor" ((PCon "TUpper" (PVar "c"))) (EApp (EVar "emit") (EVar "c")))
(DFunDef false "upperNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected an effect label"))))
(DTypeSig false "upperQualTail" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "upperQualTail" ((PVar "head")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EApp (EVar "upperQualFor") (EVar "head")) (EVar "t")) (EVar "t2")))))))
(DTypeSig false "upperQualFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))))
(DFunDef false "upperQualFor" ((PVar "head") (PCon "TDot") (PCon "TUpper" (PVar "n"))) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "qualifiedLocal") (EVar "head")) (EVar "n"))))))))
(DFunDef false "upperQualFor" ((PVar "head") PWild PWild) (EApp (EMethodRef "deferPure") (EVar "head")))
(DTypeSig false "tyArrowTail" (TyFun (TyCon "Ty") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "tyArrowTail" ((PVar "left")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TArrow"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "tyArrowSkipLayout") (EVar "t"))) (ELam ((PVar "indented")) (EApp (EApp (EMethodRef "deferThen") (EVar "parseTy")) (ELam ((PVar "right")) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EDictApp "deferWhen") (EVar "indented")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "expectTok") (EVar "TDedent")))))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "TyFun") (EVar "left")) (EVar "right"))))))))))))))
(DTypeSig false "tyArrowSkipLayout" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Bool"))))
(DFunDef false "tyArrowSkipLayout" ((PCon "TNewline")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EVar "False")))))
(DFunDef false "tyArrowSkipLayout" ((PCon "TIndent")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EVar "True")))))
(DFunDef false "tyArrowSkipLayout" (PWild) (EApp (EMethodRef "deferPure") (EVar "False")))
(DTypeSig false "parseTyApp" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyApp" () (EApp (EApp (EMethodRef "deferThen") (EVar "parseTyAtom")) (ELam ((PVar "head")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "many") (EVar "parseTyAtom"))) (ELam ((PVar "args")) (EApp (EVar "tyQualTail") (EApp (EApp (EVar "tyApplyAll") (EVar "head")) (EVar "args"))))))))
(DTypeSig false "tyQualTail" (TyFun (TyCon "Ty") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "tyQualTail" ((PVar "ty")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EApp (EVar "tyQualTailFor") (EVar "ty")) (EVar "t")) (EVar "t2")))))))
(DTypeSig false "tyQualTailFor" (TyFun (TyCon "Ty") (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Ty"))))))
(DFunDef false "tyQualTailFor" ((PVar "ty") (PCon "TAt") (PCon "TIdent" (PVar "n"))) (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EVar "tyQualDone") (EApp (EApp (EApp (EVar "TyQual") (EVar "ty")) (EListLit (EApp (EVar "EPName") (EVar "n")))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))))))))))))))))
(DFunDef false "tyQualTailFor" ((PVar "ty") (PCon "TAt") (PCon "TString" PWild)) (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "authTermP")) (ELam ((PVar "p")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EVar "tyQualDone") (EApp (EApp (EApp (EVar "TyQual") (EVar "ty")) (EListLit (EVar "p"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))))))))))))))))
(DFunDef false "tyQualTailFor" ((PVar "ty") (PCon "TAt") (PCon "TLParen")) (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "authTermP")) (ELam ((PVar "first")) (EApp (EApp (EMethodRef "deferThen") (EVar "authJoinTail")) (ELam ((PVar "rest")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EVar "tyQualDone") (EApp (EApp (EApp (EVar "TyQual") (EVar "ty")) (EBinOp "::" (EVar "first") (EVar "rest"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))))))))))))))))))))))
(DFunDef false "tyQualTailFor" (PWild (PCon "TAsAt") (PCon "TIdent" (PVar "n"))) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "pos")) (EApp (EApp (EVar "fatalAtP") (EBinOp "++" (EBinOp "++" (ELit (LString "an authority qualifier needs a space before `@`; write `String @")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "`")))) (EVar "pos")))))
(DFunDef false "tyQualTailFor" (PWild (PCon "TAsAt") (PCon "TString" (PVar "s"))) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "pos")) (EApp (EApp (EVar "fatalAtP") (EBinOp "++" (EBinOp "++" (ELit (LString "an authority qualifier needs a space before `@`; write `String @\"")) (EApp (EMethodRef "display") (EVar "s"))) (ELit (LString "\"`")))) (EVar "pos")))))
(DFunDef false "tyQualTailFor" (PWild (PCon "TAsAt") (PCon "TLParen")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "pos")) (EApp (EApp (EVar "fatalAtP") (ELit (LString "an authority qualifier needs a space before `@`; write `String @(...)`"))) (EVar "pos")))))
(DFunDef false "tyQualTailFor" ((PVar "ty") PWild PWild) (EApp (EMethodRef "deferPure") (EVar "ty")))
(DTypeSig false "tyQualDone" (TyFun (TyCon "Ty") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "tyQualDone" ((PVar "ty")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "tyQualDoneFor") (EVar "ty")) (EVar "t")))))
(DTypeSig false "tyQualDoneFor" (TyFun (TyCon "Ty") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Ty")))))
(DFunDef false "tyQualDoneFor" (PWild (PCon "TAt")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "pos")) (EApp (EApp (EVar "fatalAtP") (ELit (LString "a type takes one authority qualifier"))) (EVar "pos")))))
(DFunDef false "tyQualDoneFor" ((PVar "ty") PWild) (EApp (EMethodRef "deferPure") (EVar "ty")))
(DTypeSig false "authTermP" (TyApp (TyCon "Parser") (TyCon "EffParamTy")))
(DFunDef false "authTermP" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EVar "authTermFor") (EVar "t")) (EVar "t2")))))))
(DTypeSig false "authTermFor" (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "EffParamTy")))))
(DFunDef false "authTermFor" ((PCon "TUpper" PWild) (PCon "TEqual")) (EApp (EVar "productParamP") (EVar "False")))
(DFunDef false "authTermFor" ((PAs "t" (PCon "TString" PWild)) PWild) (EApp (EVar "effParamFor") (EVar "t")))
(DFunDef false "authTermFor" ((PAs "t" (PCon "TIdent" PWild)) PWild) (EApp (EVar "effParamFor") (EVar "t")))
(DFunDef false "authTermFor" ((PCon "TLBrace") PWild) (EVar "effSetLiteralP"))
(DFunDef false "authTermFor" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected an authority term: a name, a `\"pattern\"`, a `{set}` or `Axis=...` axes"))))
(DTypeSig false "authJoinTail" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "EffParamTy"))))
(DFunDef false "authJoinTail" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "authJoinTailFor") (EVar "t")))))
(DTypeSig false "authJoinTailFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "EffParamTy")))))
(DFunDef false "authJoinTailFor" ((PCon "TPipe")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "authTermP")) (ELam ((PVar "p")) (EApp (EApp (EMethodRef "deferThen") (EVar "authJoinTail")) (ELam ((PVar "rest")) (EApp (EMethodRef "deferPure") (EBinOp "::" (EVar "p") (EVar "rest"))))))))))
(DFunDef false "authJoinTailFor" (PWild) (EApp (EMethodRef "deferPure") (EListLit)))
(DTypeSig false "tyApplyAll" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Ty"))))
(DFunDef false "tyApplyAll" ((PVar "head") (PList)) (EVar "head"))
(DFunDef false "tyApplyAll" ((PVar "head") (PCons (PVar "a") (PVar "rest"))) (EApp (EApp (EVar "tyApplyAll") (EApp (EApp (EVar "TyApp") (EVar "head")) (EVar "a"))) (EVar "rest")))
(DTypeSig false "parseTyAtom" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyAtom" () (EApp (EApp (EApp (EVar "withDepth") (EVar "maxNestDepth")) (EApp (EVar "FailMsg") (EVar "nestTooDeepMsg"))) (EVar "parseTyAtomRaw")))
(DTypeSig false "parseTyAtomRaw" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyAtomRaw" () (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TUpper" (PVar "c")) () (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "tyConQualTail") (EVar "c"))) (ELam ((PVar "n")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "tyConUnresolved") (EVar "n")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q")))))))))))))) (arm (PCon "TIdent" (PVar "v")) () (EApp (EVar "emit") (EApp (EVar "TyVar") (EVar "v")))) (arm (PCon "TLParen") () (EVar "parseTyParen")) (arm (PCon "TLt") () (EVar "parseBareEffectAtom")) (arm (PCon "TStar") () (EVar "parseTyAuthTop")) (arm (PCon "TString" PWild) () (EVar "parseTyAuthLit")) (arm (PCon "TLBrace") () (EVar "parseTyAuthLit")) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected a type"))))))))))
(DTypeSig false "parseTyAuthTop" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyAuthTop" () (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TStar"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "TyAuth") (EListLit (EVar "EPTop"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))))))))))))))
(DTypeSig false "parseTyAuthLit" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyAuthLit" () (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "effParamP")) (ELam ((PVar "p")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "TyAuth") (EListLit (EVar "p"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))))))))))))))
(DTypeSig false "parseTyAuthJoin" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "parseTyAuthJoin" ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "authTermP")) (ELam ((PVar "first")) (EApp (EApp (EMethodRef "deferThen") (EVar "authJoinTail")) (ELam ((PVar "rest")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "TyAuth") (EBinOp "::" (EVar "first") (EVar "rest"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))))))))))))))))
(DTypeSig false "tyConQualTail" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "tyConQualTail" ((PVar "head")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EApp (EVar "tyConQualFor") (EVar "head")) (EVar "t")) (EVar "t2")))))))
(DTypeSig false "tyConQualFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))))
(DFunDef false "tyConQualFor" ((PVar "head") (PCon "TDot") (PCon "TUpper" (PVar "n"))) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "qualifiedLocal") (EVar "head")) (EVar "n"))))))))
(DFunDef false "tyConQualFor" ((PVar "head") PWild PWild) (EApp (EMethodRef "deferPure") (EVar "head")))
(DTypeSig false "parseBareEffectAtom" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseBareEffectAtom" () (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TLt"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "effectBody")) (ELam ((PVar "body")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TGt"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "mkRow") (EVar "body")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q")))))))))))))))))
(DTypeSig false "mkRow" (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "EffAtomTy")) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "Loc") (TyCon "Ty"))))
(DFunDef false "mkRow" ((PTuple (PVar "labels") (PVar "tail")) (PVar "loc")) (EApp (EApp (EApp (EVar "TyRow") (EVar "labels")) (EVar "tail")) (EApp (EVar "Some") (EVar "loc"))))
(DTypeSig false "tyTupleOrSingle" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Ty")))
(DFunDef false "tyTupleOrSingle" ((PList (PVar "t"))) (EVar "t"))
(DFunDef false "tyTupleOrSingle" ((PVar "ts")) (EApp (EVar "TyTuple") (EVar "ts")))
(DTypeSig false "parseTyParen" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyParen" () (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TLParen"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EApp (EVar "parseTyParenAt") (EVar "s")) (EVar "t")) (EVar "t2")))))))))))
(DTypeSig false "parseTyParenAt" (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Ty"))))))
(DFunDef false "parseTyParenAt" ((PVar "s") (PCon "TString" PWild) PWild) (EApp (EVar "parseTyAuthJoin") (EVar "s")))
(DFunDef false "parseTyParenAt" ((PVar "s") (PCon "TLBrace") PWild) (EApp (EVar "parseTyAuthJoin") (EVar "s")))
(DFunDef false "parseTyParenAt" ((PVar "s") (PCon "TUpper" PWild) (PCon "TEqual")) (EApp (EVar "parseTyAuthJoin") (EVar "s")))
(DFunDef false "parseTyParenAt" (PWild (PVar "t") PWild) (EApp (EVar "parseTyParenBody") (EVar "t")))
(DTypeSig false "parseTyParenBody" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "parseTyParenBody" ((PCon "TComma")) (EApp (EVar "parseTupleCtorTail") (ELit (LInt 0))))
(DFunDef false "parseTyParenBody" ((PCon "TIdent" PWild)) (EApp (EApp (EMethodRef "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EVar "parseTyParenIdent") (EVar "t2")))))
(DFunDef false "parseTyParenBody" (PWild) (EVar "parseTyParenTuple"))
(DTypeSig false "parseTyParenIdent" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "parseTyParenIdent" ((PCon "TColon")) (EApp (EApp (EMethodRef "deferThen") (EVar "identNameP")) (ELam ((PVar "n")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseTy")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t1")) (EApp (EApp (EMethodRef "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "binderDomainP") (EVar "t1")) (EVar "t2"))) (ELam ((PVar "d")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "TyNamed") (EVar "n")) (EVar "t")) (EVar "d"))))))))))))))))))
(DFunDef false "parseTyParenIdent" ((PCon "TPipe")) (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "identNameP")) (ELam ((PVar "v")) (EApp (EApp (EMethodRef "deferThen") (EVar "authJoinTail")) (ELam ((PVar "rest")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "namesOrAuthJoin") (EVar "v")) (EVar "rest")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))))))))))))))))))
(DFunDef false "parseTyParenIdent" (PWild) (EVar "parseTyParenTuple"))
(DTypeSig false "binderDomainP" (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "Option") (TyCon "EffAtomTy"))))))
(DFunDef false "binderDomainP" ((PCon "TAt") (PCon "TUpper" PWild)) (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "upperNameP")) (ELam ((PVar "l")) (EApp (EApp (EMethodRef "deferThen") (EVar "patternMarkP")) (ELam ((PVar "pat")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (ELet false (PVar "atom") (EApp (EApp (EApp (EVar "effAtomAt") (EVar "l")) (EVar "EPTop")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))) (EApp (EMethodRef "deferPure") (EApp (EVar "Some") (EVariantUpdate "EffAtomTy" (EVar "atom") ((fa "eatPattern" (EVar "pat"))))))))))))))))))))
(DFunDef false "binderDomainP" ((PCon "TAsAt") (PCon "TUpper" (PVar "l"))) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "pos")) (EApp (EApp (EVar "fatalAtP") (EBinOp "++" (EBinOp "++" (ELit (LString "a binder's domain needs a space before `@`; write `String @")) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString "`")))) (EVar "pos")))))
(DFunDef false "binderDomainP" (PWild PWild) (EApp (EMethodRef "deferPure") (EVar "None")))
(DTypeSig false "namesOrAuthJoin" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "EffParamTy")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Ty")))))
(DFunDef false "namesOrAuthJoin" ((PVar "v") (PVar "rest") (PVar "loc")) (EMatch (EApp (EApp (EVar "allNames") (EVar "rest")) (EListLit)) (arm (PCon "Some" (PVar "names")) () (EApp (EApp (EApp (EVar "TyRow") (EListLit)) (EBinOp "::" (EVar "v") (EVar "names"))) (EVar "loc"))) (arm (PCon "None") () (EApp (EApp (EVar "TyAuth") (EBinOp "::" (EApp (EVar "EPName") (EVar "v")) (EVar "rest"))) (EVar "loc")))))
(DTypeSig false "allNames" (TyFun (TyApp (TyCon "List") (TyCon "EffParamTy")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "allNames" ((PList) (PVar "acc")) (EApp (EVar "Some") (EApp (EVar "reverseL") (EVar "acc"))))
(DFunDef false "allNames" ((PCons (PCon "EPName" (PVar "n")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "allNames") (EVar "rest")) (EBinOp "::" (EVar "n") (EVar "acc"))))
(DFunDef false "allNames" (PWild PWild) (EVar "None"))
(DTypeSig false "parseTyParenTuple" (TyApp (TyCon "Parser") (TyCon "Ty")))
(DFunDef false "parseTyParenTuple" () (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "parseTy")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "ts")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "optTrailingCommaTuple") (EVar "ts"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "tyTupleOrSingle") (EVar "ts"))))))))))
(DTypeSig false "parseTupleCtorTail" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "parseTupleCtorTail" ((PVar "commas")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "tupleCtorTailFor") (EVar "commas")) (EVar "t")))))
(DTypeSig false "tupleCtorTailFor" (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Ty")))))
(DFunDef false "tupleCtorTailFor" ((PVar "commas") (PCon "TComma")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "parseTupleCtorTail") (EBinOp "+" (EVar "commas") (ELit (LInt 1)))))))
(DFunDef false "tupleCtorTailFor" ((PVar "commas") (PCon "TRParen")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EVar "tupleCtorTyOfArity") (EBinOp "+" (EVar "commas") (ELit (LInt 1)))))))
(DFunDef false "tupleCtorTailFor" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected `,` or `)` in the tuple type constructor"))))
(DTypeSig false "tupleCtorTyOfArity" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyCon "Ty"))))
(DFunDef false "tupleCtorTyOfArity" ((PVar "n")) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 2))) (EBinOp "<=" (EVar "n") (ELit (LInt 5)))) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "tyConBuiltin") (EApp (EVar "tupleCtorTyName") (EVar "n"))) (EVar "None"))) (EApp (EVar "failP") (ELit (LString "a tuple type constructor has 2 to 5 components")))))
(DTypeSig false "tupleCtorTyName" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "tupleCtorTyName" ((PLit (LInt 2))) (ELit (LString "__tuple2__")))
(DFunDef false "tupleCtorTyName" ((PLit (LInt 3))) (ELit (LString "__tuple3__")))
(DFunDef false "tupleCtorTyName" ((PLit (LInt 4))) (ELit (LString "__tuple4__")))
(DFunDef false "tupleCtorTyName" ((PLit (LInt 5))) (ELit (LString "__tuple5__")))
(DFunDef false "tupleCtorTyName" (PWild) (ELit (LString "__tuple0__")))
(DTypeSig false "parseDecl" (TyApp (TyCon "Parser") (TyCon "Decl")))
(DFunDef false "parseDecl" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TImport") () (EApp (EVar "parseImport") (EVar "False"))) (arm (PCon "TExport") () (EVar "afterExport")) (arm (PCon "TPublic") () (EVar "afterPublic")) (arm (PCon "TData") () (EApp (EVar "parseData") (EVar "VisPrivate"))) (arm (PCon "TExtern") () (EApp (EVar "parseExtern") (EVar "False"))) (arm (PCon "TProp") () (EApp (EVar "parseProp") (EVar "False"))) (arm (PCon "TTest") () (EApp (EVar "parseTest") (EVar "False"))) (arm (PCon "TBench") () (EApp (EVar "parseBench") (EVar "False"))) (arm (PCon "TEffect") () (EApp (EVar "parseEffect") (EVar "False"))) (arm (PCon "TInterface") () (EApp (EApp (EVar "parseInterface") (EVar "False")) (EVar "False"))) (arm (PCon "TImpl") () (EApp (EVar "parseImpl") (EVar "False"))) (arm (PCon "TDefault") () (EApp (EVar "afterDefault") (EVar "False"))) (arm (PCon "TType") () (EApp (EVar "parseTypeAlias") (EVar "False"))) (arm (PCon "TNewtype") () (EApp (EVar "parseNewtype") (EVar "False"))) (arm (PCon "TLet") () (EApp (EVar "parseLetGroupDecl") (EVar "False"))) (arm (PCon "TAt") () (EVar "parseAttrib")) (arm PWild () (EApp (EVar "parseFunOrSig") (EVar "False")))))))
(DTypeSig false "afterDefault" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "afterDefault" ((PVar "pub")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TDefault"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "afterDefaultFor") (EVar "pub")) (EVar "t")))))))))
(DTypeSig false "afterDefaultFor" (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Decl")))))
(DFunDef false "afterDefaultFor" ((PVar "pub") (PCon "TInterface")) (EApp (EApp (EVar "parseInterface") (EVar "pub")) (EVar "True")))
(DFunDef false "afterDefaultFor" (PWild (PCon "TImpl")) (EApp (EVar "failP") (EVar "defaultImplRemovedMsg")))
(DFunDef false "afterDefaultFor" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected an interface after `default`"))))
(DTypeSig false "afterExport" (TyApp (TyCon "Parser") (TyCon "Decl")))
(DFunDef false "afterExport" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TExport"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TImport") () (EApp (EVar "parseImport") (EVar "True"))) (arm (PCon "TData") () (EApp (EVar "parseData") (EVar "VisAbstract"))) (arm (PCon "TExtern") () (EApp (EVar "parseExtern") (EVar "True"))) (arm (PCon "TProp") () (EApp (EVar "parseProp") (EVar "True"))) (arm (PCon "TTest") () (EApp (EVar "parseTest") (EVar "True"))) (arm (PCon "TBench") () (EApp (EVar "parseBench") (EVar "True"))) (arm (PCon "TEffect") () (EApp (EVar "parseEffect") (EVar "True"))) (arm (PCon "TInterface") () (EApp (EApp (EVar "parseInterface") (EVar "True")) (EVar "False"))) (arm (PCon "TImpl") () (EApp (EVar "parseImpl") (EVar "True"))) (arm (PCon "TDefault") () (EApp (EVar "afterDefault") (EVar "True"))) (arm (PCon "TType") () (EApp (EVar "parseTypeAlias") (EVar "True"))) (arm (PCon "TNewtype") () (EApp (EVar "parseNewtype") (EVar "True"))) (arm (PCon "TLet") () (EApp (EVar "parseLetGroupDecl") (EVar "True"))) (arm PWild () (EApp (EVar "parseFunOrSig") (EVar "True")))))))))))
(DTypeSig false "afterPublic" (TyApp (TyCon "Parser") (TyCon "Decl")))
(DFunDef false "afterPublic" () (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "pubPos")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TPublic"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TExport"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "afterPublicFor") (EVar "pubPos")) (EVar "t")))))))))))))))
(DTypeSig false "afterPublicFor" (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Decl")))))
(DFunDef false "afterPublicFor" (PWild (PCon "TData")) (EApp (EVar "parseData") (EVar "VisPublic")))
(DFunDef false "afterPublicFor" ((PVar "pubPos") (PCon "TExtern")) (EApp (EApp (EVar "fatalProblemAtP") (EApp (EVar "PublicDataOnly") (EVar "True"))) (EVar "pubPos")))
(DFunDef false "afterPublicFor" ((PVar "pubPos") PWild) (EApp (EApp (EVar "fatalProblemAtP") (EApp (EVar "PublicDataOnly") (EVar "False"))) (EVar "pubPos")))
(DTypeSig false "parseFunOrSig" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseFunOrSig" ((PVar "pub")) (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (ELet false (PVar "site") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EBinOp "+" (EVar "s") (ELit (LInt 1)))) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "params")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EMatch (EVar "t") (arm (PCon "TColon") () (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EVar "DTypeSig") (EVar "pub")) (EVar "name")) (EVar "ty")) (EVar "site")))))))))) (arm (PCon "TEqual") () (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "name")) (EVar "params")) (EVar "body")) (EVar "site")) (EVar "noBinderId")))))))))) (arm (PCon "TIndent") () (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseGuardArms")) (ELam ((PVar "arms")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "guardArmsWhereOpt") (EVar "arms"))) (ELam ((PVar "body")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "name")) (EVar "params")) (EVar "body")) (EVar "site")) (EVar "noBinderId")))))))))))))) (arm (PCon "TPipe") () (EApp (EApp (EMethodRef "deferThen") (EVar "parseGuardArm")) (ELam ((PVar "arm")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "name")) (EVar "params")) (EApp (EVar "EGuards") (EListLit (EVar "arm")))) (EVar "site")) (EVar "noBinderId")))))))) (arm PWild () (EApp (EVar "failP") (ELit (LString "expected `:` or `=` after the definition head")))))))))))))))))
(DTypeSig false "parseExtern" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseExtern" ((PVar "pub")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TExtern"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "parseExternFor") (EVar "pub")) (EVar "t")))))))
(DTypeSig false "parseExternFor" (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Decl")))))
(DFunDef false "parseExternFor" ((PVar "pub") (PCon "TData")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TData"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "locatedUpperNameP")) (ELam ((PVar "named")) (ELet false (PVar "name") (EApp (EVar "fst") (EVar "named")) (ELet false (PVar "nameLoc") (EApp (EVar "snd") (EVar "named")) (EApp (EApp (EMethodRef "deferThen") (EVar "tyParamsP")) (ELam ((PVar "ps")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EApp (EApp (EVar "externDataEnd") (EVar "pub")) (EVar "name")) (EVar "ps")) (EVar "t"))) (ELam ((PVar "d")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "setDeclNameLoc") (EVar "nameLoc")) (EVar "d"))))))))))))))))
(DFunDef false "parseExternFor" ((PVar "pub") PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "externName")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "e")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EVar "peek2P")) (ELam ((PVar "u")) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "externBindsFor") (EVar "t")) (EVar "u"))) (ELam ((PVar "binds")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "DExtern") (ERecordCreate "ExternDecl" ((fa "edPub" (EVar "pub")) (fa "edName" (EVar "name")) (fa "edTy" (EVar "ty")) (fa "edLoc" (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "e"))) (fa "edBinds" (EVar "binds")))))))))))))))))))))))))))
(DTypeSig false "externBindsFor" (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ExternBind"))))))
(DFunDef false "externBindsFor" ((PCon "TIndent") (PCon "TIdent" (PLit (LString "bind")))) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "externBindLines")) (ELam ((PVar "binds")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EVar "binds")))))))))
(DFunDef false "externBindsFor" (PWild PWild) (EApp (EMethodRef "deferPure") (EListLit)))
(DTypeSig false "externBindLines" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ExternBind"))))
(DFunDef false "externBindLines" () (EApp (EApp (EMethodRef "deferThen") (EVar "externBindP")) (ELam ((PVar "b")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EIf (EBinOp "==" (EVar "t") (EVar "TDedent")) (EApp (EMethodRef "deferPure") (EListLit)) (EVar "externBindLines"))) (ELam ((PVar "rest")) (EApp (EMethodRef "deferPure") (EBinOp "::" (EVar "b") (EVar "rest"))))))))))))
(DTypeSig false "externBindP" (TyApp (TyCon "Parser") (TyCon "ExternBind")))
(DFunDef false "externBindP" () (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EIf (EBinOp "==" (EVar "t") (EApp (EVar "TIdent") (ELit (LString "bind")))) (EVar "advance") (EApp (EVar "failP") (ELit (LString "expected `bind`"))))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "h")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "bindHostFor") (EVar "h"))) (ELam ((PVar "host")) (EApp (EApp (EMethodRef "deferThen") (EVar "stringLitP")) (ELam ((PVar "symbol")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "e")) (EApp (EMethodRef "deferPure") (ERecordCreate "ExternBind" ((fa "ebHost" (EVar "host")) (fa "ebSymbol" (EVar "symbol")) (fa "ebLoc" (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "e")))))))))))))))))))))))
(DTypeSig false "bindHostFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "bindHostFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "bindHostFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected a host after `bind`, such as `c` or `js`"))))
(DTypeSig false "externDataEnd" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "KindAnn")))) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Decl")))))))
(DFunDef false "externDataEnd" (PWild PWild PWild (PCon "TEqual")) (EApp (EVar "failP") (ELit (LString "an `extern data` type has no constructors; drop the `= ...`"))))
(DFunDef false "externDataEnd" (PWild PWild PWild (PCon "TDeriving")) (EApp (EVar "failP") (ELit (LString "an `extern data` type has no constructors to derive from; drop the `deriving` clause"))))
(DFunDef false "externDataEnd" ((PVar "pub") (PVar "name") (PVar "ps") PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EVar "externDataUnresolved") (EVar "pub")) (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "ps"))) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "ps")))))))
(DTypeSig false "locatedUpperNameP" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyCon "Loc"))))
(DFunDef false "locatedUpperNameP" () (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EMethodRef "deferPure") (ETuple (EVar "name") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q")))))))))))))
(DTypeSig false "parseTypeAlias" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseTypeAlias" ((PVar "pub")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TType"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "locatedUpperNameP")) (ELam ((PVar "named")) (ELet false (PVar "name") (EApp (EVar "fst") (EVar "named")) (ELet false (PVar "nameLoc") (EApp (EVar "snd") (EVar "named")) (EApp (EApp (EMethodRef "deferThen") (EVar "tyParamsP")) (ELam ((PVar "ps")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "setDeclNameLoc") (EVar "nameLoc")) (EApp (EApp (EApp (EApp (EApp (EVar "dTypeAliasUnresolved") (EVar "pub")) (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "ps"))) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "ps"))) (EVar "ty")))))))))))))))))))
(DTypeSig false "parseNewtype" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseNewtype" ((PVar "pub")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TNewtype"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "locatedUpperNameP")) (ELam ((PVar "named")) (ELet false (PVar "name") (EApp (EVar "fst") (EVar "named")) (ELet false (PVar "nameLoc") (EApp (EVar "snd") (EVar "named")) (EApp (EApp (EMethodRef "deferThen") (EVar "tyParamsP")) (ELam ((PVar "ps")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "upperNameP")) (ELam ((PVar "con")) (EApp (EApp (EMethodRef "deferThen") (EVar "ctorBindersP")) (ELam ((PVar "binders")) (EApp (EApp (EMethodRef "deferThen") (EVar "parseTy")) (ELam ((PVar "fty")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "newtypeDerives") (EVar "t"))) (ELam ((PVar "derives")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "setDeclNameLoc") (EVar "nameLoc")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dNewtypeUnresolved") (EVar "pub")) (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "ps"))) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "ps"))) (EVar "con")) (EVar "binders")) (EVar "fty")) (EVar "derives")))))))))))))))))))))))))))
(DTypeSig false "parseLetGroupDecl" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseLetGroupDecl" ((PVar "pub")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TLet"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRec"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "letRecDeclClause")) (ELam ((PVar "c")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EVar "coalesceClauses") (EListLit (EVar "c"))))))))))))))
(DTypeSig false "letRecDeclClause" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyCon "Loc"))))
(DFunDef false "letRecDeclClause" () (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EMethodRef "deferPure") (ETuple (EVar "name") (EVar "pats") (EVar "body") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EBinOp "+" (EVar "s") (ELit (LInt 1)))))))))))))))))))
(DTypeSig false "parseAttrib" (TyApp (TyCon "Parser") (TyCon "Decl")))
(DFunDef false "parseAttrib" () (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "atPos")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TAt"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EApp (EVar "attrArg") (EVar "atPos")) (EVar "name")) (EVar "t"))) (ELam ((PVar "attr")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseDecl")) (ELam ((PVar "inner")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "DAttrib") (EListLit (EVar "attr"))) (EVar "inner"))))))))))))))))))
(DTypeSig false "attrArg" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Attr"))))))
(DFunDef false "attrArg" ((PVar "atPos") (PVar "name") (PCon "TString" (PVar "msg"))) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EApp (EVar "mkAttr") (EVar "atPos")) (EVar "name")) (EApp (EVar "Some") (EVar "msg"))))))
(DFunDef false "attrArg" ((PVar "atPos") (PVar "name") PWild) (EApp (EApp (EApp (EVar "mkAttr") (EVar "atPos")) (EVar "name")) (EVar "None")))
(DTypeSig false "mkAttr" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyApp (TyCon "Parser") (TyCon "Attr"))))))
(DFunDef false "mkAttr" (PWild (PLit (LString "deprecated")) (PVar "msg")) (EApp (EMethodRef "deferPure") (EApp (EVar "AttrDeprecated") (EVar "msg"))))
(DFunDef false "mkAttr" ((PVar "atPos") (PVar "name") (PVar "msg")) (EMatch (EApp (EVar "bareAttr") (EVar "name")) (arm (PCon "None") () (EApp (EApp (EVar "fatalAtP") (EBinOp "++" (EBinOp "++" (ELit (LString "unknown declaration attribute `@")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "`; the attributes are `@deprecated \"msg\"`, `@inline`, `@must_use` and `@noinline`")))) (EVar "atPos"))) (arm (PCon "Some" (PVar "attr")) () (EMatch (EVar "msg") (arm (PCon "None") () (EApp (EMethodRef "deferPure") (EVar "attr"))) (arm (PCon "Some" PWild) () (EApp (EApp (EVar "fatalAtP") (EBinOp "++" (EBinOp "++" (ELit (LString "`@")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` takes no message")))) (EVar "atPos")))))))
(DTypeSig false "bareAttr" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Attr"))))
(DFunDef false "bareAttr" ((PLit (LString "inline"))) (EApp (EVar "Some") (EVar "AttrInline")))
(DFunDef false "bareAttr" ((PLit (LString "must_use"))) (EApp (EVar "Some") (EVar "AttrMustUse")))
(DFunDef false "bareAttr" ((PLit (LString "noinline"))) (EApp (EVar "Some") (EVar "AttrNoInline")))
(DFunDef false "bareAttr" (PWild) (EVar "None"))
(DTypeSig false "externName" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "externName" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "externNameFor") (EVar "t")))))
(DTypeSig false "externNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "externNameFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "externNameFor" ((PCon "TUpper" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "externNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected a name after `extern`"))))
(DTypeSig false "parseImport" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseImport" ((PVar "pub")) (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TImport"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "importQuals")) (ELam ((PVar "quals")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "importPathFor") (EVar "quals"))) (ELam ((PVar "path")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "e")) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "noExportedAlias") (EVar "pub")) (EVar "path"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "DUse") (EVar "pub")) (EVar "path")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "e")))))))))))))))))))))
(DTypeSig false "noExportedAlias" (TyFun (TyCon "Bool") (TyFun (TyCon "UsePath") (TyApp (TyCon "Parser") (TyCon "Unit")))))
(DFunDef false "noExportedAlias" ((PCon "True") (PCon "UseAlias" PWild (PVar "a"))) (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (ELit (LString "`export import ... as ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "` is not allowed; a module alias is file-local, so write `export import m` and let the importer choose its alias")))))
(DFunDef false "noExportedAlias" ((PCon "True") (PCon "UseGroup" PWild (PVar "members"))) (EApp (EVar "failIfAliasedMember") (EVar "members")))
(DFunDef false "noExportedAlias" (PWild PWild) (EApp (EMethodRef "deferPure") (ELit LUnit)))
(DTypeSig false "failIfAliasedMember" (TyFun (TyApp (TyCon "List") (TyCon "UseMember")) (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "failIfAliasedMember" ((PList)) (EApp (EMethodRef "deferPure") (ELit LUnit)))
(DFunDef false "failIfAliasedMember" ((PCons (PVar "m") (PVar "rest"))) (EMatch (EApp (EVar "useMemberAlias") (EVar "m")) (arm (PCon "Some" (PVar "a")) () (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`export import` cannot rename `")) (EApp (EMethodRef "display") (EApp (EVar "useMemberOrigin") (EVar "m")))) (ELit (LString "` as `"))) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "`; re-export it under its own name, `export import m.{"))) (EApp (EMethodRef "display") (EApp (EVar "useMemberOrigin") (EVar "m")))) (ELit (LString "}`"))))) (arm (PCon "None") () (EApp (EVar "failIfAliasedMember") (EVar "rest")))))
(DTypeSig false "importQuals" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "importQuals" () (EApp (EApp (EMethodRef "deferThen") (EVar "importIdent")) (ELam ((PVar "first")) (EApp (EApp (EMethodRef "deferThen") (EVar "importQualRest")) (ELam ((PVar "rest")) (EApp (EMethodRef "deferPure") (EBinOp "::" (EVar "first") (EVar "rest"))))))))
(DTypeSig false "importQualRest" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "importQualRest" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "importQualRestFor") (EVar "t")))))
(DTypeSig false "importQualRestFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "importQualRestFor" ((PCon "TDot")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "importIdent")) (ELam ((PVar "x")) (EApp (EApp (EMethodRef "deferThen") (EVar "importQualRest")) (ELam ((PVar "rest")) (EApp (EMethodRef "deferPure") (EBinOp "::" (EVar "x") (EVar "rest"))))))))))
(DFunDef false "importQualRestFor" (PWild) (EApp (EMethodRef "deferPure") (EListLit)))
(DTypeSig false "importIdent" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "importIdent" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "importIdentFor") (EVar "t")))))
(DTypeSig false "importIdentFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "importIdentFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "importIdentFor" ((PCon "TUpper" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "importIdentFor" ((PCon "TTest")) (EApp (EVar "emit") (ELit (LString "test"))))
(DFunDef false "importIdentFor" ((PCon "TData")) (EApp (EVar "emit") (ELit (LString "data"))))
(DFunDef false "importIdentFor" ((PCon "TType")) (EApp (EVar "emit") (ELit (LString "type"))))
(DFunDef false "importIdentFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected a module name in the import path"))))
(DTypeSig false "importPathFor" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Parser") (TyCon "UsePath"))))
(DFunDef false "importPathFor" ((PVar "quals")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "importPathForT") (EVar "quals")) (EVar "t")))))
(DTypeSig false "importPathForT" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "UsePath")))))
(DFunDef false "importPathForT" ((PVar "quals") (PCon "TDotLBrace")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "importMember")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "ms")) (EApp (EApp (EMethodRef "deferThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "noTrailingAlias") (ELit (LString "a selective import")))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "UseGroup") (EVar "quals")) (EVar "ms"))))))))))))))
(DFunDef false "importPathForT" ((PVar "quals") (PCon "TDotStar")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "noTrailingAlias") (ELit (LString "a wildcard import")))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "UseWild") (EVar "quals"))))))))
(DFunDef false "importPathForT" ((PVar "quals") (PCon "TAs")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "aliasName")) (ELam ((PVar "a")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "UseAlias") (EVar "quals")) (EVar "a"))))))))
(DFunDef false "importPathForT" ((PVar "quals") PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "UseName") (EVar "quals"))))
(DTypeSig false "noTrailingAlias" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "noTrailingAlias" ((PVar "what")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "noTrailingAliasFor") (EVar "what")) (EVar "t")))))
(DTypeSig false "noTrailingAliasFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit")))))
(DFunDef false "noTrailingAliasFor" ((PVar "what") (PCon "TAs")) (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (ELit (LString "`as` cannot alias ")) (EApp (EMethodRef "display") (EVar "what"))) (ELit (LString "; write `import m as A` to alias the whole module")))))
(DFunDef false "noTrailingAliasFor" (PWild PWild) (EApp (EMethodRef "deferPure") (ELit LUnit)))
(DTypeSig false "importMember" (TyApp (TyCon "Parser") (TyCon "UseMember")))
(DFunDef false "importMember" () (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "importMemberFor") (EVar "s")) (EVar "t")))))))
(DTypeSig false "importMemberFor" (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "UseMember")))))
(DFunDef false "importMemberFor" ((PVar "s") (PCon "TIdent" (PVar "x"))) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EApp (EVar "memberAliasOrNot") (EVar "s")) (EVar "x")) (EVar "False")))))
(DFunDef false "importMemberFor" ((PVar "s") (PCon "TUpper" (PVar "x"))) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "withAllOrNot") (EVar "s")) (EVar "x")))))
(DFunDef false "importMemberFor" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected an imported name"))))
(DTypeSig false "withAllOrNot" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "UseMember")))))
(DFunDef false "withAllOrNot" ((PVar "s") (PVar "x")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "withAllFor") (EVar "s")) (EVar "x")) (EVar "t")))))
(DTypeSig false "withAllFor" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "UseMember"))))))
(DFunDef false "withAllFor" ((PVar "s") (PVar "x") (PCon "TLParen")) (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TDotDot"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "noMemberAlias") (EVar "x"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "x")) (EVar "True")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))) (EVar "None"))))))))))))))))
(DFunDef false "withAllFor" ((PVar "s") (PVar "x") PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "noMemberAlias") (EVar "x"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "x")) (EVar "False")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))) (EVar "None"))))))))))
(DTypeSig false "noMemberAlias" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "noMemberAlias" ((PVar "x")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "noMemberAliasFor") (EVar "x")) (EVar "t")))))
(DTypeSig false "noMemberAliasFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit")))))
(DFunDef false "noMemberAliasFor" ((PVar "x") (PCon "TAs")) (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString "` is a type or constructor and cannot be aliased; import it under its own name")))))
(DFunDef false "noMemberAliasFor" (PWild PWild) (EApp (EMethodRef "deferPure") (ELit LUnit)))
(DTypeSig false "memberAliasOrNot" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "UseMember"))))))
(DFunDef false "memberAliasOrNot" ((PVar "s") (PVar "x") (PVar "allCtors")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EApp (EVar "memberAliasFor") (EVar "s")) (EVar "x")) (EVar "allCtors")) (EVar "t")))))
(DTypeSig false "memberAliasFor" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "UseMember")))))))
(DFunDef false "memberAliasFor" ((PVar "s") (PVar "x") (PVar "allCtors") (PCon "TAs")) (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "memberAliasName")) (ELam ((PVar "a")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "x")) (EVar "allCtors")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))) (EApp (EVar "Some") (EVar "a")))))))))))))
(DFunDef false "memberAliasFor" ((PVar "s") (PVar "x") (PVar "allCtors") PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EVar "UseMember") (EVar "x")) (EVar "allCtors")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))) (EVar "None"))))))))
(DTypeSig false "memberAliasName" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "memberAliasName" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "memberAliasNameFor") (EVar "t")))))
(DTypeSig false "memberAliasNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "memberAliasNameFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "memberAliasNameFor" ((PCon "TUpper" (PVar "x"))) (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (ELit (LString "a value member's alias must be lowercase; `as ")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString "` names a type or constructor")))))
(DFunDef false "memberAliasNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected an alias after `as`"))))
(DTypeSig false "aliasName" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "aliasName" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "aliasNameFor") (EVar "t")))))
(DTypeSig false "aliasNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "aliasNameFor" ((PCon "TUpper" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "aliasNameFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "failP") (EBinOp "++" (EBinOp "++" (ELit (LString "a module alias must be capitalized; `as ")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString "` is lowercase")))))
(DFunDef false "aliasNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected an alias after `as`"))))
(DTypeSig false "stringLitP" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "stringLitP" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "stringLitFor") (EVar "t")))))
(DTypeSig false "stringLitFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "stringLitFor" ((PCon "TString" (PVar "s"))) (EApp (EVar "emit") (EVar "s")))
(DFunDef false "stringLitFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected a string literal"))))
(DTypeSig false "interpolatedNameMsg" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "interpolatedNameMsg" ((PVar "kw")) (EBinOp "++" (EBinOp "++" (ELit (LString "a `")) (EApp (EMethodRef "display") (EVar "kw"))) (ELit (LString "` name must be a plain string literal, not an interpolated string"))))
(DTypeSig false "propNameFor" (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String")))))
(DFunDef false "propNameFor" ((PVar "propPos") (PCon "TInterpOpen" PWild)) (EApp (EApp (EVar "fatalAtP") (EApp (EVar "interpolatedNameMsg") (ELit (LString "prop")))) (EVar "propPos")))
(DFunDef false "propNameFor" (PWild (PVar "t")) (EApp (EVar "stringLitFor") (EVar "t")))
(DTypeSig false "parseProp" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseProp" ((PVar "pub")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "propPos")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TProp"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "propNameFor") (EVar "propPos")) (EVar "t"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "many") (EVar "propParam"))) (ELam ((PVar "params")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "params")) (EVar "body"))))))))))))))))))))
(DTypeSig false "propParam" (TyApp (TyCon "Parser") (TyCon "PropParam")))
(DFunDef false "propParam" () (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TLParen"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "PropParam") (EVar "name")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EBinOp "+" (EVar "s") (ELit (LInt 1))))) (EVar "ty"))))))))))))))))))
(DTypeSig false "parseTest" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseTest" ((PVar "pub")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "testPos")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TTest"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "parseTestRest") (EVar "pub")) (EVar "testPos")) (EVar "t")))))))))
(DTypeSig false "parseTestRest" (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Decl"))))))
(DFunDef false "parseTestRest" ((PVar "pub") PWild (PCon "TString" PWild)) (EApp (EApp (EMethodRef "deferThen") (EVar "stringLitP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name")) (EVar "body"))))))))))))
(DFunDef false "parseTestRest" (PWild (PVar "testPos") (PCon "TInterpOpen" PWild)) (EApp (EApp (EVar "fatalAtP") (EApp (EVar "interpolatedNameMsg") (ELit (LString "test")))) (EVar "testPos")))
(DFunDef false "parseTestRest" (PWild (PVar "testPos") PWild) (EApp (EApp (EVar "fatalProblemAtP") (EApp (EVar "ReservedKeyword") (ELit (LString "test")))) (EVar "testPos")))
(DTypeSig false "benchRemovedMsg" (TyCon "String"))
(DFunDef false "benchRemovedMsg" () (ELit (LString "`bench` has been removed; delete the declaration")))
(DTypeSig false "parseBench" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseBench" (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "benchPos")) (EApp (EApp (EVar "fatalAtP") (EVar "benchRemovedMsg")) (EVar "benchPos")))))
(DTypeSig false "parseEffect" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseEffect" ((PVar "pub")) (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TEffect"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EApp (EMethodRef "deferThen") (EVar "effDomainP")) (ELam ((PVar "dom")) (EApp (EApp (EMethodRef "deferThen") (EVar "effAxesP")) (ELam ((PVar "axes")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EApp (EVar "effectDeclUnstamped") (EVar "pub")) (EVar "name")) (EVar "dom")) (EVar "axes")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))))))))))))))))))))))
(DTypeSig false "effAxesP" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "effAxesP" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "effAxesFor") (EVar "t")))))
(DTypeSig false "effAxesFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "effAxesFor" ((PCon "TLParen")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "effAxisP")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "axes")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EVar "axes")))))))))
(DFunDef false "effAxesFor" (PWild) (EApp (EMethodRef "deferPure") (EListLit)))
(DTypeSig false "effAxisP" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "effAxisP" () (EApp (EApp (EMethodRef "deferThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "upperNameP")) (ELam ((PVar "dom")) (EApp (EMethodRef "deferPure") (ETuple (EVar "name") (EVar "dom"))))))))))
(DTypeSig false "effDomainP" (TyApp (TyCon "Parser") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "effDomainP" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "effDomainFor") (EVar "t")))))
(DTypeSig false "effDomainFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "effDomainFor" ((PCon "TUpper" (PVar "d"))) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "Some") (EVar "d"))))))
(DFunDef false "effDomainFor" (PWild) (EApp (EMethodRef "deferPure") (EVar "None")))
(DTypeSig false "parseInterface" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl")))))
(DFunDef false "parseInterface" ((PVar "pub") (PVar "isDefault")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "kw")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TInterface"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "locatedUpperNameP")) (ELam ((PVar "named")) (ELet false (PVar "name") (EApp (EVar "fst") (EVar "named")) (ELet false (PVar "nameLoc") (EApp (EVar "snd") (EVar "named")) (EApp (EApp (EMethodRef "deferThen") (EVar "tyParamsP")) (ELam ((PVar "ps")) (EApp (EApp (EMethodRef "deferThen") (EVar "ifaceSuper")) (ELam ((PVar "supers")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "ifaceBody") (EVar "kw"))) (ELam ((PVar "methods")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "setDeclNameLoc") (EVar "nameLoc")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dInterfaceUnresolved") (EVar "pub")) (EVar "isDefault")) (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "ps"))) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "ps"))) (EVar "supers")) (EVar "methods")))))))))))))))))))
(DTypeSig false "ifaceSuper" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Super"))))
(DFunDef false "ifaceSuper" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "ifaceSuperFor") (EVar "t")))))
(DTypeSig false "ifaceSuperFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Super")))))
(DFunDef false "ifaceSuperFor" ((PCon "TRequires")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "sepBy1") (EVar "ifaceSuperEntry")) (EApp (EVar "expectTok") (EVar "TComma"))))))
(DFunDef false "ifaceSuperFor" (PWild) (EApp (EMethodRef "deferPure") (EListLit)))
(DTypeSig false "ifaceSuperEntry" (TyApp (TyCon "Parser") (TyCon "Super")))
(DFunDef false "ifaceSuperEntry" () (EApp (EApp (EMethodRef "deferThen") (EVar "upperNameP")) (ELam ((PVar "head")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "upperQualTail") (EVar "head"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "many") (EVar "lowerNameP"))) (ELam ((PVar "params")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "superUnresolved") (EVar "name")) (EVar "params"))))))))))
(DTypeSig false "ifaceBody" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod")))))
(DFunDef false "ifaceBody" ((PVar "kw")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "ifaceBodyFor") (EVar "kw")) (EVar "t")))))
(DTypeSig false "ifaceBodyFor" (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod"))))))
(DFunDef false "ifaceBodyFor" (PWild (PCon "TWhere")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "ifaceWhereBody") (EVar "t")))))))
(DFunDef false "ifaceBodyFor" ((PVar "kw") (PVar "t")) (EIf (EApp (EVar "endsDecl") (EVar "t")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EListLit)))) (EIf (EVar "otherwise") (EApp (EApp (EVar "fatalProblemAtP") (EVar "missingWhereIfaceMsg")) (EVar "kw")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ifaceWhereBody" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod")))))
(DFunDef false "ifaceWhereBody" ((PCon "TIndent")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "ifaceMembers")) (ELam ((PVar "ms")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EVar "ms")))))))))))
(DFunDef false "ifaceWhereBody" ((PVar "t")) (EIf (EApp (EVar "endsDecl") (EVar "t")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EListLit)))) (EIf (EVar "otherwise") (EApp (EVar "fatalP") (EVar "sameLineWhereIfaceMsg")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "endsDecl" (TyFun (TyCon "Token") (TyCon "Bool")))
(DFunDef false "endsDecl" ((PCon "TNewline")) (EVar "True"))
(DFunDef false "endsDecl" ((PCon "TDedent")) (EVar "True"))
(DFunDef false "endsDecl" ((PCon "TEof")) (EVar "True"))
(DFunDef false "endsDecl" (PWild) (EVar "False"))
(DTypeSig false "missingWhereIfaceMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "missingWhereIfaceMsg" () (EApp (EVar "MissingWhere") (ELit (LString "interface"))))
(DTypeSig false "missingWhereImplMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "missingWhereImplMsg" () (EApp (EVar "MissingWhere") (ELit (LString "impl"))))
(DTypeSig false "sameLineWhereIfaceMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "sameLineWhereIfaceMsg" () (EApp (EVar "WhereSameLine") (ELit (LString "interface"))))
(DTypeSig false "sameLineWhereImplMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "sameLineWhereImplMsg" () (EApp (EVar "WhereSameLine") (ELit (LString "impl"))))
(DTypeSig false "ifaceMembers" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod"))))
(DFunDef false "ifaceMembers" () (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EVar "ifaceMembersLoop"))))
(DTypeSig false "ifaceMembersLoop" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod"))))
(DFunDef false "ifaceMembersLoop" () (EApp (EApp (EVar "parseOrElse") (EVar "ifaceMembersCons")) (EApp (EMethodRef "deferPure") (EListLit))))
(DTypeSig false "ifaceMembersCons" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "IfaceMethod"))))
(DFunDef false "ifaceMembersCons" () (EApp (EApp (EMethodRef "deferThen") (EVar "ifaceMember")) (ELam ((PVar "m")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "ifaceMembersLoop")) (ELam ((PVar "rest")) (EApp (EMethodRef "deferPure") (EBinOp "::" (EVar "m") (EVar "rest"))))))))))
(DTypeSig false "ifaceMember" (TyApp (TyCon "Parser") (TyCon "IfaceMethod")))
(DFunDef false "ifaceMember" () (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EApp (EVar "ifaceMemberRest") (EVar "name")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q")))) (EVar "pats")) (EVar "t")))))))))))))))
(DTypeSig false "ifaceMemberRest" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "IfaceMethod")))))))
(DFunDef false "ifaceMemberRest" ((PVar "name") (PVar "nameLoc") PWild (PCon "TColon")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "name")) (EVar "ty")) (EVar "None")) (EVar "nameLoc"))))))))
(DFunDef false "ifaceMemberRest" ((PVar "name") (PVar "nameLoc") (PVar "pats") (PCon "TEqual")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "name")) (EApp (EVar "TyVar") (ELit (LString "_")))) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EVar "pats")) (EVar "body")))) (EVar "nameLoc"))))))))
(DFunDef false "ifaceMemberRest" (PWild PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected `:` or `=` after the interface member name"))))
(DTypeSig false "parseImpl" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseImpl" ((PVar "pub")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "kw")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TImpl"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "implHead") (EVar "pub")) (EVar "kw")) (EVar "t")))))))))
(DTypeSig false "implHead" (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Decl"))))))
(DFunDef false "implHead" ((PVar "pub") (PVar "kw") (PCon "TUpper" (PVar "u"))) (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "upperQualTail") (EVar "u"))) (ELam ((PVar "n")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EApp (EVar "implRest") (EVar "pub")) (EVar "kw")) (EVar "n"))) (ELam ((PVar "d")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "setDeclNameLoc") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))) (EVar "d"))))))))))))))))
(DFunDef false "implHead" (PWild PWild (PCon "TIdent" PWild)) (EApp (EVar "failP") (EVar "namedImplRemovedMsg")))
(DFunDef false "implHead" (PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected an interface name after `impl`"))))
(DTypeSig false "implRest" (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "Decl"))))))
(DFunDef false "implRest" ((PVar "pub") (PVar "kw") (PVar "iface")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "many") (EVar "parseTyAtom"))) (ELam ((PVar "tyargs")) (EApp (EApp (EMethodRef "deferThen") (EVar "implRequires")) (ELam ((PVar "reqs")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "implBody") (EVar "kw"))) (ELam ((PVar "methods")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EApp (EVar "dImplUnresolved") (EVar "pub")) (EVar "iface")) (EVar "tyargs")) (EVar "reqs")) (EVar "methods"))))))))))
(DTypeSig false "namedImplRemovedMsg" (TyCon "String"))
(DFunDef false "namedImplRemovedMsg" () (ELit (LString "named impls (`impl name of Iface`) have been removed; write a plain `impl Iface`")))
(DTypeSig false "defaultImplRemovedMsg" (TyCon "String"))
(DFunDef false "defaultImplRemovedMsg" () (ELit (LString "`default impl` has been removed; write a plain `impl`")))
(DTypeSig false "implRequires" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Require"))))
(DFunDef false "implRequires" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "implRequiresFor") (EVar "t")))))
(DTypeSig false "implRequiresFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Require")))))
(DFunDef false "implRequiresFor" ((PCon "TRequires")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EVar "sepBy1") (EVar "implRequireEntry")) (EApp (EVar "expectTok") (EVar "TComma"))))))
(DFunDef false "implRequiresFor" (PWild) (EApp (EMethodRef "deferPure") (EListLit)))
(DTypeSig false "implRequireEntry" (TyApp (TyCon "Parser") (TyCon "Require")))
(DFunDef false "implRequireEntry" () (EApp (EApp (EMethodRef "deferThen") (EVar "upperNameP")) (ELam ((PVar "head")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "upperQualTail") (EVar "head"))) (ELam ((PVar "iface")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "many") (EVar "parseTyAtom"))) (ELam ((PVar "tys")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "requireUnresolved") (EVar "iface")) (EVar "tys"))))))))))
(DTypeSig false "implBody" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod")))))
(DFunDef false "implBody" ((PVar "kw")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "implBodyFor") (EVar "kw")) (EVar "t")))))
(DTypeSig false "implBodyFor" (TyFun (TyCon "Int") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod"))))))
(DFunDef false "implBodyFor" (PWild (PCon "TWhere")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "implWhereBody") (EVar "t")))))))
(DFunDef false "implBodyFor" ((PVar "kw") (PVar "t")) (EIf (EApp (EVar "endsDecl") (EVar "t")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EListLit)))) (EIf (EVar "otherwise") (EApp (EApp (EVar "fatalProblemAtP") (EVar "missingWhereImplMsg")) (EVar "kw")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "implWhereBody" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod")))))
(DFunDef false "implWhereBody" ((PCon "TIndent")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "implMethods")) (ELam ((PVar "ms")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EVar "ms")))))))))))
(DFunDef false "implWhereBody" ((PVar "t")) (EIf (EApp (EVar "endsDecl") (EVar "t")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EListLit)))) (EIf (EVar "otherwise") (EApp (EVar "fatalP") (EVar "sameLineWhereImplMsg")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "implMethods" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod"))))
(DFunDef false "implMethods" () (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EVar "implMethodsLoop"))))
(DTypeSig false "implMethodsLoop" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod"))))
(DFunDef false "implMethodsLoop" () (EApp (EApp (EVar "parseOrElse") (EVar "implMethodsCons")) (EApp (EMethodRef "deferPure") (EListLit))))
(DTypeSig false "implMethodsCons" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "ImplMethod"))))
(DFunDef false "implMethodsCons" () (EApp (EApp (EMethodRef "deferThen") (EVar "implMethod")) (ELam ((PVar "m")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "implMethodsLoop")) (ELam ((PVar "rest")) (EApp (EMethodRef "deferPure") (EBinOp "::" (EVar "m") (EVar "rest"))))))))))
(DTypeSig false "implMethod" (TyApp (TyCon "Parser") (TyCon "ImplMethod")))
(DFunDef false "implMethod" () (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "p")) (EApp (EApp (EMethodRef "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EApp (EVar "implMethodRest") (EVar "name")) (EVar "pats")) (EVar "t"))) (ELam ((PVar "m")) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "recordUnitStart") (ELit (LInt 2))) (EVar "p"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EVar "m")))))))))))))))
(DTypeSig false "implMethodRest" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "ImplMethod"))))))
(DFunDef false "implMethodRest" ((PVar "name") (PVar "pats") (PCon "TEqual")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "ImplMethod") (EVar "name")) (EVar "pats")) (EVar "body"))))))))
(DFunDef false "implMethodRest" ((PVar "name") (PVar "pats") (PCon "TIndent")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseGuardArms")) (ELam ((PVar "arms")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "guardArmsWhereOpt") (EVar "arms"))) (ELam ((PVar "body")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "ImplMethod") (EVar "name")) (EVar "pats")) (EVar "body"))))))))))))
(DFunDef false "implMethodRest" ((PVar "name") (PVar "pats") (PCon "TPipe")) (EApp (EApp (EMethodRef "deferThen") (EVar "parseGuardArm")) (ELam ((PVar "arm")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "ImplMethod") (EVar "name")) (EVar "pats")) (EApp (EVar "EGuards") (EListLit (EVar "arm"))))))))
(DFunDef false "implMethodRest" (PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected `=` or `|` after the method head"))))
(DTypeSig false "guardArmsWhereOpt" (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "guardArmsWhereOpt" ((PVar "arms")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "guardArmsWhereFor") (EVar "arms")) (EVar "t")))))
(DTypeSig false "guardArmsWhereFor" (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "guardArmsWhereFor" ((PVar "arms") (PCon "TWhere")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseWhereBindings")) (ELam ((PVar "binds")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "ELetGroup") (EApp (EVar "coalesceClauses") (EVar "binds"))) (EApp (EVar "EGuards") (EVar "arms")))))))))))))))
(DFunDef false "guardArmsWhereFor" ((PVar "arms") PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "EGuards") (EVar "arms"))))
(DTypeSig false "parseGuardArms" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "GuardArm"))))
(DFunDef false "parseGuardArms" () (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EVar "guardArmsLoop"))))
(DTypeSig false "guardArmsLoop" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "GuardArm"))))
(DFunDef false "guardArmsLoop" () (EApp (EApp (EVar "parseOrElse") (EVar "guardArmsCons")) (EApp (EMethodRef "deferPure") (EListLit))))
(DTypeSig false "guardArmsCons" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "GuardArm"))))
(DFunDef false "guardArmsCons" () (EApp (EApp (EMethodRef "deferThen") (EVar "parseGuardArm")) (ELam ((PVar "a")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "guardArmsLoop")) (ELam ((PVar "rest")) (EApp (EMethodRef "deferPure") (EBinOp "::" (EVar "a") (EVar "rest"))))))))))
(DTypeSig false "parseGuardArm" (TyApp (TyCon "Parser") (TyCon "GuardArm")))
(DFunDef false "parseGuardArm" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "parseGuardArmFor") (EVar "t")))))
(DTypeSig false "parseGuardArmFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "GuardArm"))))
(DFunDef false "parseGuardArmFor" ((PCon "TIf")) (EApp (EApp (EMethodRef "deferThen") (EVar "eqGuardShapeP")) (ELam ((PVar "looksGuard")) (EApp (EVar "parseGuardArmIf") (EVar "looksGuard")))))
(DFunDef false "parseGuardArmFor" (PWild) (EVar "parseGuardArmBody"))
(DTypeSig false "parseGuardArmIf" (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "GuardArm"))))
(DFunDef false "parseGuardArmIf" ((PCon "True")) (EApp (EVar "fatalP") (EVar "eqGuardIfMsg")))
(DFunDef false "parseGuardArmIf" ((PCon "False")) (EVar "parseGuardArmBody"))
(DTypeSig false "parseGuardArmBody" (TyApp (TyCon "Parser") (TyCon "GuardArm")))
(DFunDef false "parseGuardArmBody" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TPipe"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "parseGuard")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "guards")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseBody")) (ELam ((PVar "body")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "GuardArm") (EVar "guards")) (EVar "body"))))))))))))
(DTypeSig false "eqGuardIfMsg" (TyCon "ParseDiagnosticKind"))
(DFunDef false "eqGuardIfMsg" () (EVar "EquationGuardIf"))
(DTypeSig false "eqGuardShapeFrom" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "eqGuardShapeFrom" ((PVar "toks") (PVar "i") (PVar "depth")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "False") (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "isLineEndTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EVar "False") (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "isThenTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EVar "False") (EIf (EBinOp "&&" (EBinOp "==" (EVar "depth") (ELit (LInt 0))) (EApp (EVar "isEqualTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")))) (EVar "True") (EIf (EApp (EVar "isBracketOpenTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EVar "eqGuardShapeFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "+" (EVar "depth") (ELit (LInt 1)))) (EIf (EApp (EVar "isBracketCloseTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i"))) (EApp (EApp (EApp (EVar "eqGuardShapeFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBinOp "-" (EVar "depth") (ELit (LInt 1)))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "eqGuardShapeFrom") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "depth")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "eqGuardShapeP" (TyApp (TyCon "Parser") (TyCon "Bool")))
(DFunDef false "eqGuardShapeP" () (EApp (EVar "ParserE") (ELam ((PVar "ctx") (PVar "pos")) (EApp (EApp (EVar "POk") (EApp (EApp (EApp (EVar "eqGuardShapeFrom") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "pos")) (ELit (LInt 0)))) (EVar "pos")))))
(DTypeSig false "parseGuard" (TyApp (TyCon "Parser") (TyCon "Guard")))
(DFunDef false "parseGuard" () (EApp (EApp (EMethodRef "deferThen") (EVar "parseOr")) (ELam ((PVar "e")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "guardFor") (EVar "e")) (EVar "t")))))))
(DTypeSig false "guardFor" (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Guard")))))
(DFunDef false "guardFor" ((PVar "e") (PCon "TLArrow")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseOr")) (ELam ((PVar "rhs")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "GBind") (EApp (EVar "exprToPat") (EVar "e"))) (EVar "rhs"))))))))
(DFunDef false "guardFor" ((PVar "e") PWild) (EApp (EMethodRef "deferPure") (EApp (EVar "GBool") (EVar "e"))))
(DTypeSig false "lowerNameP" (TyApp (TyCon "Parser") (TyCon "String")))
(DFunDef false "lowerNameP" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "lowerNameFor") (EVar "t")))))
(DTypeSig false "lowerNameFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "String"))))
(DFunDef false "lowerNameFor" ((PCon "TIdent" (PVar "x"))) (EApp (EVar "emit") (EVar "x")))
(DFunDef false "lowerNameFor" (PWild) (EApp (EVar "failP") (ELit (LString "expected a type parameter"))))
(DTypeSig false "tyParamsP" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "KindAnn"))))))
(DFunDef false "tyParamsP" () (EApp (EVar "many") (EVar "tyParamP")))
(DTypeSig false "tyParamP" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "KindAnn")))))
(DFunDef false "tyParamP" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "tyParamFor") (EVar "t")))))
(DTypeSig false "tyParamFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "KindAnn"))))))
(DFunDef false "tyParamFor" ((PCon "TLParen")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "lowerNameP")) (ELam ((PVar "n")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "kindP")) (ELam ((PVar "k")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (ETuple (EVar "n") (EApp (EVar "Some") (EVar "k")))))))))))))))
(DFunDef false "tyParamFor" ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "lowerNameFor") (EVar "t"))) (ELam ((PVar "n")) (EApp (EMethodRef "deferPure") (ETuple (EVar "n") (EVar "None"))))))
(DTypeSig false "kindP" (TyApp (TyCon "Parser") (TyCon "KindAnn")))
(DFunDef false "kindP" () (EApp (EApp (EMethodRef "deferThen") (EVar "kindAtomP")) (ELam ((PVar "a")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "kindArrowRest") (EVar "a")) (EVar "t")))))))
(DTypeSig false "kindArrowRest" (TyFun (TyCon "KindAnn") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "KindAnn")))))
(DFunDef false "kindArrowRest" ((PVar "a") (PCon "TArrow")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "kindP")) (ELam ((PVar "b")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "KindArrow") (EVar "a")) (EVar "b"))))))))
(DFunDef false "kindArrowRest" ((PVar "a") PWild) (EApp (EMethodRef "deferPure") (EVar "a")))
(DTypeSig false "kindAtomP" (TyApp (TyCon "Parser") (TyCon "KindAnn")))
(DFunDef false "kindAtomP" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "kindAtomFor") (EVar "t")))))
(DTypeSig false "kindAtomFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "KindAnn"))))
(DFunDef false "kindAtomFor" ((PCon "TUpper" (PVar "c"))) (EIf (EBinOp "==" (EVar "c") (ELit (LString "Type"))) (EApp (EVar "kindAtomEmit") (EVar "KindType")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "Effect"))) (EApp (EVar "kindAtomEmit") (EVar "KindEffect")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "Authority"))) (EVar "kindAuthorityP") (EIf (EVar "otherwise") (EApp (EVar "failP") (EVar "kindExpectedMsg")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DFunDef false "kindAtomFor" ((PCon "TLParen")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "kindP")) (ELam ((PVar "k")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EVar "k")))))))))
(DFunDef false "kindAtomFor" (PWild) (EApp (EVar "failP") (EVar "kindExpectedMsg")))
(DTypeSig false "kindExpectedMsg" (TyCon "String"))
(DFunDef false "kindExpectedMsg" () (ELit (LString "expected a kind: `Type`, `Effect`, `Authority <Label>` or an arrow between them")))
(DTypeSig false "kindAuthorityP" (TyApp (TyCon "Parser") (TyCon "KindAnn")))
(DFunDef false "kindAuthorityP" () (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "upperNameP")) (ELam ((PVar "l")) (EApp (EApp (EMethodRef "deferThen") (EVar "patternMarkP")) (ELam ((PVar "pat")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EVar "kindAuthorityUnstamped") (EVar "l")) (EVar "pat")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))))))))))))))))))
(DTypeSig false "patternMarkP" (TyApp (TyCon "Parser") (TyCon "Bool")))
(DFunDef false "patternMarkP" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "patternMarkFor") (EVar "t")))))
(DTypeSig false "patternMarkFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Bool"))))
(DFunDef false "patternMarkFor" ((PCon "TStar")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EVar "True")))))
(DFunDef false "patternMarkFor" (PWild) (EApp (EMethodRef "deferPure") (EVar "False")))
(DTypeSig false "kindAtomEmit" (TyFun (TyCon "KindAnn") (TyApp (TyCon "Parser") (TyCon "KindAnn"))))
(DFunDef false "kindAtomEmit" ((PVar "k")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EVar "k")))))
(DTypeSig false "parseData" (TyFun (TyCon "DataVis") (TyApp (TyCon "Parser") (TyCon "Decl"))))
(DFunDef false "parseData" ((PVar "vis")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TData"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "locatedUpperNameP")) (ELam ((PVar "named")) (ELet false (PVar "name") (EApp (EVar "fst") (EVar "named")) (ELet false (PVar "nameLoc") (EApp (EVar "snd") (EVar "named")) (EApp (EApp (EMethodRef "deferThen") (EVar "tyParamsP")) (ELam ((PVar "ps")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "dataBody") (EVar "name"))) (ELam ((PVar "bodyAndDerives")) (ELet false (PVar "variants") (EApp (EVar "fst") (EVar "bodyAndDerives")) (ELet false (PVar "blockDerives") (EApp (EVar "snd") (EVar "bodyAndDerives")) (EApp (EApp (EMethodRef "deferThen") (EVar "derivingClause")) (ELam ((PVar "outerDerives")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "setDeclNameLoc") (EVar "nameLoc")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dDataUnresolved") (EVar "vis")) (EVar "name")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "ps"))) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "ps"))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "variants"))) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "variants"))) (EApp (EApp (EVar "combineDerives") (EVar "blockDerives")) (EVar "outerDerives"))))))))))))))))))))))
(DTypeSig false "combineDerives" (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyApp (TyCon "List") (TyCon "DeriveRef")))))
(DFunDef false "combineDerives" ((PList) (PVar "outer")) (EVar "outer"))
(DFunDef false "combineDerives" ((PVar "block") PWild) (EVar "block"))
(DTypeSig false "dataBody" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Variant") (TyCon "CtorBinders"))) (TyApp (TyCon "List") (TyCon "DeriveRef"))))))
(DFunDef false "dataBody" ((PVar "tyName")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "dataBodyFor") (EVar "tyName")) (EVar "t")))))
(DTypeSig false "dataBodyFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Variant") (TyCon "CtorBinders"))) (TyApp (TyCon "List") (TyCon "DeriveRef")))))))
(DFunDef false "dataBodyFor" ((PVar "tyName") (PCon "TEqual")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "dataAfterEq") (EVar "tyName")) (EVar "t")))))))
(DFunDef false "dataBodyFor" ((PVar "tyName") (PCon "TIndent")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "dataVariantsN") (EVar "tyName"))) (ELam ((PVar "vs")) (EApp (EApp (EMethodRef "deferThen") (EVar "derivingClause")) (ELam ((PVar "derives")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (ETuple (EVar "vs") (EVar "derives"))))))))))))))))
(DFunDef false "dataBodyFor" (PWild PWild) (EApp (EMethodRef "deferPure") (ETuple (EListLit) (EListLit))))
(DTypeSig false "dataAfterEq" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "Variant") (TyCon "CtorBinders"))) (TyApp (TyCon "List") (TyCon "DeriveRef")))))))
(DFunDef false "dataAfterEq" ((PVar "tyName") (PCon "TIndent")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "optPipe")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "dataVariantsN") (EVar "tyName"))) (ELam ((PVar "vs")) (EApp (EApp (EMethodRef "deferThen") (EVar "derivingClause")) (ELam ((PVar "derives")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (ETuple (EVar "vs") (EVar "derives"))))))))))))))))))
(DFunDef false "dataAfterEq" ((PVar "tyName") PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "dataVariantsN") (EVar "tyName"))) (ELam ((PVar "vs")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "inlineTrailingDerives") (EVar "t"))) (ELam ((PVar "derives")) (EApp (EMethodRef "deferPure") (ETuple (EVar "vs") (EVar "derives"))))))))))
(DTypeSig false "newtypeDerives" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DeriveRef")))))
(DFunDef false "newtypeDerives" ((PCon "TIndent")) (EApp (EVar "inlineTrailingDerives") (EVar "TIndent")))
(DFunDef false "newtypeDerives" (PWild) (EVar "derivingClause"))
(DTypeSig false "inlineTrailingDerives" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DeriveRef")))))
(DFunDef false "inlineTrailingDerives" ((PCon "TIndent")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "derivingClause")) (ELam ((PVar "derives")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EVar "derives")))))))))))
(DFunDef false "inlineTrailingDerives" (PWild) (EApp (EMethodRef "deferPure") (EListLit)))
(DTypeSig false "optPipe" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "optPipe" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "optPipeFor") (EVar "t")))))
(DTypeSig false "optPipeFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "optPipeFor" ((PCon "TPipe")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EMethodRef "deferPure") (ELit LUnit)))))
(DFunDef false "optPipeFor" (PWild) (EApp (EMethodRef "deferPure") (ELit LUnit)))
(DTypeAlias false "CtorBinders" () (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "KindAnn"))))
(DTypeSig false "dataVariantsN" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "Variant") (TyCon "CtorBinders"))))))
(DFunDef false "dataVariantsN" ((PVar "tyName")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EVar "dataVariantsNFor") (EVar "tyName")) (EVar "t")))))
(DTypeSig false "dataVariantsNFor" (TyFun (TyCon "String") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "Variant") (TyCon "CtorBinders")))))))
(DFunDef false "dataVariantsNFor" ((PVar "tyName") (PCon "TLBrace")) (EApp (EApp (EMethodRef "deferThen") (EVar "parseNamedFields")) (ELam ((PVar "fields")) (EApp (EMethodRef "deferPure") (EListLit (ETuple (EApp (EApp (EVar "Variant") (EVar "tyName")) (EApp (EApp (EVar "ConNamed") (EVar "fields")) (EVar "True"))) (EListLit)))))))
(DFunDef false "dataVariantsNFor" (PWild PWild) (EVar "dataVariants"))
(DTypeSig false "dataVariants" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "Variant") (TyCon "CtorBinders")))))
(DFunDef false "dataVariants" () (EApp (EApp (EMethodRef "deferThen") (EVar "parseVariant")) (ELam ((PVar "v")) (EApp (EApp (EMethodRef "deferThen") (EVar "variantsRest")) (ELam ((PVar "rest")) (EApp (EMethodRef "deferPure") (EBinOp "::" (EVar "v") (EVar "rest"))))))))
(DTypeSig false "variantsRest" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "Variant") (TyCon "CtorBinders")))))
(DFunDef false "variantsRest" () (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "variantsRestFor") (EVar "t")))))))
(DTypeSig false "variantsRestFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "Variant") (TyCon "CtorBinders"))))))
(DFunDef false "variantsRestFor" ((PCon "TPipe")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseVariant")) (ELam ((PVar "v")) (EApp (EApp (EMethodRef "deferThen") (EVar "variantsRest")) (ELam ((PVar "rest")) (EApp (EMethodRef "deferPure") (EBinOp "::" (EVar "v") (EVar "rest"))))))))))
(DFunDef false "variantsRestFor" (PWild) (EApp (EMethodRef "deferPure") (EListLit)))
(DTypeSig false "parseVariant" (TyApp (TyCon "Parser") (TyTuple (TyCon "Variant") (TyCon "CtorBinders"))))
(DFunDef false "parseVariant" () (EApp (EApp (EMethodRef "deferThen") (EVar "upperNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "deferThen") (EVar "ctorBindersP")) (ELam ((PVar "binders")) (EApp (EApp (EMethodRef "deferThen") (EVar "parsePayload")) (ELam ((PVar "payload")) (EApp (EMethodRef "deferPure") (ETuple (EApp (EApp (EVar "Variant") (EVar "name")) (EVar "payload")) (EVar "binders"))))))))))
(DTypeSig false "ctorBindersP" (TyApp (TyCon "Parser") (TyCon "CtorBinders")))
(DFunDef false "ctorBindersP" () (EApp (EVar "many") (EVar "ctorBinderP")))
(DTypeSig false "ctorBinderP" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyCon "KindAnn"))))
(DFunDef false "ctorBinderP" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EVar "peek2P")) (ELam ((PVar "t2")) (EApp (EApp (EVar "ctorBinderFor") (EVar "t")) (EVar "t2")))))))
(DTypeSig false "ctorBinderFor" (TyFun (TyCon "Token") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyCon "KindAnn"))))))
(DFunDef false "ctorBinderFor" ((PCon "TLParen") (PCon "TIdent" PWild)) (EApp (EApp (EMethodRef "deferThen") (EVar "peek3P")) (ELam ((PVar "t3")) (EApp (EVar "ctorBinderColon") (EVar "t3")))))
(DFunDef false "ctorBinderFor" (PWild PWild) (EApp (EVar "failP") (ELit (LString "expected a constructor binder"))))
(DTypeSig false "ctorBinderColon" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyCon "KindAnn")))))
(DFunDef false "ctorBinderColon" ((PCon "TColon")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "lowerNameP")) (ELam ((PVar "n")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "kindP")) (ELam ((PVar "k")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EApp (EVar "ctorBinderKind") (EVar "n")) (EVar "k")))))))))))))
(DFunDef false "ctorBinderColon" (PWild) (EApp (EVar "failP") (ELit (LString "expected a constructor binder"))))
(DTypeSig false "ctorBinderKind" (TyFun (TyCon "String") (TyFun (TyCon "KindAnn") (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyCon "KindAnn"))))))
(DFunDef false "ctorBinderKind" ((PVar "n") (PAs "k" (PCon "KindAuthority" PWild PWild PWild PWild))) (EApp (EMethodRef "deferPure") (ETuple (EVar "n") (EVar "k"))))
(DFunDef false "ctorBinderKind" ((PVar "n") (PVar "k")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "pos")) (EApp (EApp (EVar "fatalAtP") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "a constructor may bind only an `Authority` existential, not `(")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "kindAnnSource") (EVar "k")))) (ELit (LString ")`; declare `"))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString "` on the type's head instead")))) (EVar "pos")))))
(DTypeSig false "parsePayload" (TyApp (TyCon "Parser") (TyCon "ConPayload")))
(DFunDef false "parsePayload" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "payloadFor") (EVar "t")))))
(DTypeSig false "payloadFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "ConPayload"))))
(DFunDef false "payloadFor" ((PCon "TLBrace")) (EVar "parseNamedPayload"))
(DFunDef false "payloadFor" (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "many") (EVar "parseTyAtom"))) (ELam ((PVar "tys")) (EApp (EMethodRef "deferPure") (EApp (EVar "ConPos") (EVar "tys"))))))
(DTypeSig false "parseNamedPayload" (TyApp (TyCon "Parser") (TyCon "ConPayload")))
(DFunDef false "parseNamedPayload" () (EApp (EApp (EMethodRef "deferThen") (EVar "parseNamedFields")) (ELam ((PVar "fields")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "ConNamed") (EVar "fields")) (EVar "False"))))))
(DTypeSig false "parseNamedFields" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Field"))))
(DFunDef false "parseNamedFields" () (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TLBrace"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "parseField")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "fields")) (EApp (EApp (EMethodRef "deferThen") (EVar "optTrailingComma")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRBrace"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EVar "fields")))))))))))
(DTypeSig false "parseField" (TyApp (TyCon "Parser") (TyCon "Field")))
(DFunDef false "parseField" () (EApp (EApp (EMethodRef "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TColon"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseTy")) (ELam ((PVar "t")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "Field") (EVar "name")) (EVar "t"))))))))))
(DTypeSig false "derivingClause" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DeriveRef"))))
(DFunDef false "derivingClause" () (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "derivingFor") (EVar "t")))))))
(DTypeSig false "derivingFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DeriveRef")))))
(DFunDef false "derivingFor" ((PCon "TDeriving")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TLParen"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "sepBy1") (EVar "derivedNameP")) (EApp (EVar "expectTok") (EVar "TComma")))) (ELam ((PVar "names")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRParen"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EVar "names")))))))))))
(DFunDef false "derivingFor" (PWild) (EApp (EMethodRef "deferPure") (EListLit)))
(DTypeSig false "derivedNameP" (TyApp (TyCon "Parser") (TyCon "DeriveRef")))
(DFunDef false "derivedNameP" () (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "upperNameP")) (ELam ((PVar "n")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "DeriveRef") (EVar "n")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))))))))))))))
(DTypeSig false "parseBody" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseBody" () (EApp (EApp (EVar "parseOrElse") (EVar "indentedBody")) (EVar "parseBodyExpr")))
(DTypeSig false "parseBodyExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseBodyExpr" () (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "whereEol") (EVar "e"))) (EApp (EApp (EVar "parseOrElse") (EApp (EVar "whereTail") (EVar "e"))) (EApp (EMethodRef "deferPure") (EVar "e")))))))
(DTypeSig false "whereEol" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "whereEol" ((PVar "e")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TWhere"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseWhereBindings")) (ELam ((PVar "binds")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "ELetGroup") (EApp (EVar "coalesceClauses") (EVar "binds"))) (EVar "e"))))))))))))
(DTypeSig false "whereTail" (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "Expr"))))
(DFunDef false "whereTail" ((PVar "e")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TWhere"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseWhereBindings")) (ELam ((PVar "binds")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "ELetGroup") (EApp (EVar "coalesceClauses") (EVar "binds"))) (EVar "e"))))))))))))))))))
(DTypeSig false "parseWhereBindings" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyCon "Loc")))))
(DFunDef false "parseWhereBindings" () (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EVar "whereBindingsLoop"))))
(DTypeSig false "whereBindingsLoop" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyCon "Loc")))))
(DFunDef false "whereBindingsLoop" () (EApp (EApp (EVar "parseOrElse") (EVar "whereBindingsCons")) (EApp (EMethodRef "deferPure") (EListLit))))
(DTypeSig false "whereBindingsCons" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyCon "Loc")))))
(DFunDef false "whereBindingsCons" () (EApp (EApp (EMethodRef "deferThen") (EVar "parseWhereBinding")) (ELam ((PVar "b")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "whereBindingsLoop")) (ELam ((PVar "rest")) (EApp (EMethodRef "deferPure") (EBinOp "::" (EVar "b") (EVar "rest"))))))))))
(DTypeSig false "parseWhereBinding" (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyCon "Loc"))))
(DFunDef false "parseWhereBinding" () (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "p")) (EApp (EApp (EMethodRef "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EApp (EVar "whereBindRest") (EVar "name")) (EVar "pats")) (EVar "t"))) (ELam ((PVar "b")) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "recordUnitStart") (ELit (LInt 3))) (EVar "p"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "withBindSite") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "p")) (EBinOp "+" (EVar "p") (ELit (LInt 1))))) (EVar "b"))))))))))))))))))
(DTypeSig false "withBindSite" (TyFun (TyCon "Loc") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyCon "Loc")))))
(DFunDef false "withBindSite" ((PVar "site") (PTuple (PVar "name") (PVar "pats") (PVar "body"))) (ETuple (EVar "name") (EVar "pats") (EVar "body") (EVar "site")))
(DTypeSig false "whereBindRest" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))))
(DFunDef false "whereBindRest" ((PVar "name") (PList) (PCon "TColon")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseRhsExpr")) (ELam ((PVar "body")) (EApp (EMethodRef "deferPure") (ETuple (EVar "name") (EListLit) (EApp (EApp (EVar "EAnnot") (EVar "body")) (EVar "ty")))))))))))))
(DFunDef false "whereBindRest" ((PVar "name") (PVar "pats") (PCon "TEqual")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseRhsExpr")) (ELam ((PVar "body")) (EApp (EMethodRef "deferPure") (ETuple (EVar "name") (EVar "pats") (EVar "body"))))))))
(DFunDef false "whereBindRest" ((PVar "name") (PVar "pats") (PCon "TIndent")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseGuardArms")) (ELam ((PVar "arms")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (ETuple (EVar "name") (EVar "pats") (EApp (EVar "EGuards") (EVar "arms")))))))))))
(DFunDef false "whereBindRest" ((PVar "name") (PVar "pats") (PCon "TPipe")) (EApp (EApp (EMethodRef "deferThen") (EVar "parseGuardArm")) (ELam ((PVar "arm")) (EApp (EMethodRef "deferPure") (ETuple (EVar "name") (EVar "pats") (EApp (EVar "EGuards") (EListLit (EVar "arm"))))))))
(DFunDef false "whereBindRest" (PWild PWild PWild) (EApp (EVar "failP") (ELit (LString "expected a body for the `where` binding"))))
(DTypeSig false "coalesceClauses" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "LetBind"))))
(DFunDef false "coalesceClauses" ((PList)) (EListLit))
(DFunDef false "coalesceClauses" ((PCons (PTuple (PVar "name") (PVar "ps") (PVar "b") (PVar "site")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "coalesceGo") (EVar "name")) (EVar "site")) (EListLit (EApp (EApp (EVar "FunClause") (EVar "ps")) (EVar "b")))) (EVar "rest")))
(DTypeSig false "coalesceGo" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "LetBind")))))))
(DFunDef false "coalesceGo" ((PVar "name") (PVar "site") (PVar "acc") (PList)) (EListLit (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "name")) (EApp (EVar "reverseL") (EVar "acc"))) (EVar "site")) (EVar "noBinderId"))))
(DFunDef false "coalesceGo" ((PVar "name") (PVar "site") (PVar "acc") (PCons (PTuple (PVar "n") (PVar "ps") (PVar "b") (PVar "nsite")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "coalesceStep") (EVar "name")) (EVar "site")) (EVar "acc")) (EVar "n")) (EVar "ps")) (EVar "b")) (EVar "nsite")) (EVar "rest")))
(DTypeSig false "coalesceStep" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "LetBind")))))))))))
(DFunDef false "coalesceStep" ((PVar "name") (PVar "site") (PVar "acc") (PVar "n") (PVar "ps") (PVar "b") (PVar "nsite") (PVar "rest")) (EIf (EBinOp "==" (EVar "n") (EVar "name")) (EApp (EApp (EApp (EApp (EVar "coalesceGo") (EVar "name")) (EVar "site")) (EBinOp "::" (EApp (EApp (EVar "FunClause") (EVar "ps")) (EVar "b")) (EVar "acc"))) (EVar "rest")) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "name")) (EApp (EVar "reverseL") (EVar "acc"))) (EVar "site")) (EVar "noBinderId")) (EApp (EApp (EApp (EApp (EVar "coalesceGo") (EVar "n")) (EVar "nsite")) (EListLit (EApp (EApp (EVar "FunClause") (EVar "ps")) (EVar "b")))) (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "indentedBody" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "indentedBody" () (EVar "parseBracketBlock"))
(DTypeSig false "blockOrExpr" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "Expr")))
(DFunDef false "blockOrExpr" ((PList (PCon "DoExpr" (PVar "e")))) (EVar "e"))
(DFunDef false "blockOrExpr" ((PVar "stmts")) (EApp (EVar "EBlock") (EVar "stmts")))
(DTypeSig false "parseDo" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseDo" () (EApp (EApp (EVar "parseDoBlock") (EVar "TDo")) (EVar "False")))
(DTypeSig false "parseDefer" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseDefer" () (EApp (EApp (EVar "parseDoBlock") (EVar "TDefer")) (EVar "True")))
(DTypeSig false "parseDoBlock" (TyFun (TyCon "Token") (TyFun (TyCon "Bool") (TyApp (TyCon "Parser") (TyCon "Expr")))))
(DFunDef false "parseDoBlock" ((PVar "herald") (PVar "deferred")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "herald"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TIndent"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "p0")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "doStmtsFrom") (EVar "p0"))) (ELam ((PVar "r")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TDedent"))) (ELam (PWild) (EApp (EApp (EApp (EVar "doBlockResult") (EVar "herald")) (EApp (EVar "fst") (EVar "r"))) (EApp (EVar "snd") (EVar "r"))))))))))))))
(DTypeSig false "doStmtsFrom" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "DoStmt"))))))
(DFunDef false "doStmtsFrom" ((PVar "p0")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EVar "doStmtsLoop") (EVar "p0")))))
(DTypeSig false "doStmtsLoop" (TyFun (TyCon "Int") (TyApp (TyCon "Parser") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "DoStmt"))))))
(DFunDef false "doStmtsLoop" ((PVar "lastStart")) (EApp (EApp (EVar "parseOrElse") (EVar "doStmtsCons")) (EApp (EMethodRef "deferPure") (ETuple (EVar "lastStart") (EListLit)))))
(DTypeSig false "doStmtsCons" (TyApp (TyCon "Parser") (TyTuple (TyCon "Int") (TyApp (TyCon "List") (TyCon "DoStmt")))))
(DFunDef false "doStmtsCons" () (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "p")) (EApp (EApp (EMethodRef "deferThen") (EVar "parseStmt")) (ELam ((PVar "ss")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "doStmtsLoop") (EVar "p"))) (ELam ((PVar "r")) (EApp (EMethodRef "deferPure") (ETuple (EApp (EVar "fst") (EVar "r")) (EBinOp "++" (EVar "ss") (EApp (EVar "snd") (EVar "r"))))))))))))))
(DTypeSig false "doBlockResult" (TyFun (TyCon "Token") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Parser") (TyCon "Expr"))))))
(DFunDef false "doBlockResult" ((PVar "herald") (PVar "lastStart") (PVar "stmts")) (EMatch (EApp (EVar "last") (EVar "stmts")) (arm (PCon "Some" (PCon "DoLet" PWild PWild PWild PWild PWild)) () (EApp (EApp (EVar "fatalProblemAtP") (EApp (EVar "doEndsInBindingMsg") (EVar "herald"))) (EVar "lastStart"))) (arm (PCon "Some" (PCon "DoBind" PWild PWild)) () (EApp (EApp (EVar "fatalProblemAtP") (EApp (EVar "doEndsInBindingMsg") (EVar "herald"))) (EVar "lastStart"))) (arm PWild () (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "EDo") (EApp (EVar "isDeferTok") (EVar "herald"))) (EVar "stmts"))))))
(DTypeSig false "doEndsInBindingMsg" (TyFun (TyCon "Token") (TyCon "ParseDiagnosticKind")))
(DFunDef false "doEndsInBindingMsg" ((PVar "herald")) (EApp (EVar "BlockEndsBinding") (EApp (EVar "blockWord") (EVar "herald"))))
(DTypeSig false "blockWord" (TyFun (TyCon "Token") (TyCon "String")))
(DFunDef false "blockWord" ((PCon "TDefer")) (ELit (LString "defer")))
(DFunDef false "blockWord" (PWild) (ELit (LString "do")))
(DTypeSig false "parseRhsExpr" (TyApp (TyCon "Parser") (TyCon "Expr")))
(DFunDef false "parseRhsExpr" () (EApp (EApp (EVar "parseOrElse") (EVar "parseBracketBlock")) (EVar "parseExpr")))
(DTypeSig false "parseStmts" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt"))))
(DFunDef false "parseStmts" () (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EVar "stmtsLoop"))))
(DTypeSig false "stmtsLoop" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt"))))
(DFunDef false "stmtsLoop" () (EApp (EApp (EVar "parseOrElse") (EVar "stmtsCons")) (EApp (EMethodRef "deferPure") (EListLit))))
(DTypeSig false "stmtsCons" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt"))))
(DFunDef false "stmtsCons" () (EApp (EApp (EMethodRef "deferThen") (EVar "parseStmt")) (ELam ((PVar "ss")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNewlines")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "stmtsLoop")) (ELam ((PVar "rest")) (EApp (EMethodRef "deferPure") (EBinOp "++" (EVar "ss") (EVar "rest"))))))))))
(DTypeSig false "parseStmt" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt"))))
(DFunDef false "parseStmt" () (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "p")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "stmtFor") (EVar "t"))) (ELam ((PVar "ss")) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EVar "recordUnitStart") (ELit (LInt 1))) (EVar "p"))) (ELam (PWild) (EApp (EMethodRef "deferPure") (EVar "ss")))))))))))
(DTypeSig false "stmtFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt")))))
(DFunDef false "stmtFor" ((PCon "TLet")) (EApp (EApp (EMethodRef "deferThen") (EVar "parseLetStmt")) (ELam ((PVar "s")) (EApp (EMethodRef "deferPure") (EListLit (EVar "s"))))))
(DFunDef false "stmtFor" (PWild) (EVar "parseExprStmt"))
(DTypeSig false "parseLetStmt" (TyApp (TyCon "Parser") (TyCon "DoStmt")))
(DFunDef false "parseLetStmt" () (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TLet"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "letKind") (EVar "t"))) (ELam ((PVar "stmt")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "letStmtAt") (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EBinOp "+" (EVar "s") (ELit (LInt 1))))) (EVar "stmt"))))))))))))))
(DTypeSig false "letStmtAt" (TyFun (TyCon "Loc") (TyFun (TyCon "DoStmt") (TyCon "DoStmt"))))
(DFunDef false "letStmtAt" ((PVar "site") (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e") PWild)) (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EVar "e")) (EVar "site")))
(DFunDef false "letStmtAt" ((PVar "site") (PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EApp (EVar "atLetSite") (EVar "site")) (EVar "e"))))
(DFunDef false "letStmtAt" (PWild (PVar "stmt")) (EVar "stmt"))
(DTypeSig false "atLetSite" (TyFun (TyCon "Loc") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "atLetSite" ((PVar "site") (PCon "ELet" PWild (PVar "r") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "site")) (EVar "r")) (EVar "p")) (EVar "e1")) (EVar "e2")))
(DFunDef false "atLetSite" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "letKind" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "DoStmt"))))
(DFunDef false "letKind" ((PCon "TMut")) (EApp (EVar "failP") (EVar "letMutRemovedMsg")))
(DFunDef false "letKind" ((PCon "TRec")) (EVar "letRecStmt"))
(DFunDef false "letKind" ((PCon "TIdent" (PVar "name"))) (EApp (EVar "letIdent") (EVar "name")))
(DFunDef false "letKind" (PWild) (EVar "letPat"))
(DTypeSig false "letRecStmt" (TyApp (TyCon "Parser") (TyCon "DoStmt")))
(DFunDef false "letRecStmt" () (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TRec"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "identNameP")) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "q")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseRhsExpr")) (ELam ((PVar "e1")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "letFunTailFor") (EVar "name")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EVar "q"))) (EVar "pats")) (EVar "e1")) (EVar "t")))))))))))))))))))))
(DTypeSig false "letIdent" (TyFun (TyCon "String") (TyApp (TyCon "Parser") (TyCon "DoStmt"))))
(DFunDef false "letIdent" ((PVar "name")) (EApp (EApp (EMethodRef "deferThen") (EVar "contextP")) (ELam ((PVar "ctx")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "many") (EVar "parseParamPat"))) (ELam ((PVar "pats")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EApp (EVar "letIdentBody") (EVar "name")) (EApp (EApp (EApp (EVar "locOfSpan") (EVar "ctx")) (EVar "s")) (EBinOp "+" (EVar "s") (ELit (LInt 1))))) (EVar "pats")) (EVar "t")))))))))))))
(DTypeSig false "letIdentBody" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "DoStmt")))))))
(DFunDef false "letIdentBody" ((PVar "name") (PVar "nameLoc") (PList) (PCon "TColon")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseTy")) (ELam ((PVar "ty")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseRhsExpr")) (ELam ((PVar "e1")) (EApp (EApp (EApp (EApp (EVar "letIdentRest") (EVar "name")) (EVar "nameLoc")) (EListLit)) (EApp (EApp (EVar "EAnnot") (EVar "e1")) (EVar "ty"))))))))))))
(DFunDef false "letIdentBody" ((PVar "name") (PVar "nameLoc") (PVar "pats") PWild) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseRhsExpr")) (ELam ((PVar "e1")) (EApp (EApp (EApp (EApp (EVar "letIdentRest") (EVar "name")) (EVar "nameLoc")) (EVar "pats")) (EVar "e1")))))))
(DTypeSig false "letIdentRest" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "DoStmt")))))))
(DFunDef false "letIdentRest" ((PVar "name") (PVar "nameLoc") (PList) (PVar "e1")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "letTailFor") (EApp (EApp (EApp (EVar "PVar") (EVar "name")) (EVar "nameLoc")) (EVar "noBinderId"))) (EVar "e1")) (EVar "t")))))
(DFunDef false "letIdentRest" ((PVar "name") (PVar "nameLoc") (PVar "pats") (PVar "e1")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EApp (EApp (EVar "letFunTailFor") (EVar "name")) (EVar "nameLoc")) (EVar "pats")) (EVar "e1")) (EVar "t")))))
(DTypeSig false "letFunTailFor" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "DoStmt"))))))))
(DFunDef false "letFunTailFor" ((PVar "name") (PVar "nameLoc") (PVar "pats") (PVar "e1") (PCon "TIn")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EMethodRef "deferPure") (EApp (EVar "DoExpr") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "noDeclLoc")) (EVar "True")) (EApp (EApp (EApp (EVar "PVar") (EVar "name")) (EVar "nameLoc")) (EVar "noBinderId"))) (EApp (EApp (EVar "curryLam") (EVar "pats")) (EVar "e1"))) (EVar "e2")))))))))
(DFunDef false "letFunTailFor" ((PVar "name") (PVar "nameLoc") (PVar "pats") (PVar "e1") PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "False")) (EVar "True")) (EApp (EApp (EApp (EVar "PVar") (EVar "name")) (EVar "nameLoc")) (EVar "noBinderId"))) (EApp (EApp (EVar "curryLam") (EVar "pats")) (EVar "e1"))) (EVar "noDeclLoc"))))
(DTypeSig false "letPat" (TyApp (TyCon "Parser") (TyCon "DoStmt")))
(DFunDef false "letPat" () (EApp (EApp (EMethodRef "deferThen") (EVar "parsePat")) (ELam ((PVar "pat")) (EApp (EApp (EMethodRef "deferThen") (EApp (EVar "expectTok") (EVar "TEqual"))) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseRhsExpr")) (ELam ((PVar "e1")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "letTailFor") (EVar "pat")) (EVar "e1")) (EVar "t")))))))))))
(DTypeSig false "letTailFor" (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "DoStmt"))))))
(DFunDef false "letTailFor" ((PVar "pat") (PVar "e1") (PCon "TIn")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "e2")) (EApp (EMethodRef "deferPure") (EApp (EVar "DoExpr") (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "noDeclLoc")) (EVar "False")) (EVar "pat")) (EVar "e1")) (EVar "e2")))))))))
(DFunDef false "letTailFor" ((PVar "pat") (PVar "e1") PWild) (EApp (EMethodRef "deferPure") (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "False")) (EVar "False")) (EVar "pat")) (EVar "e1")) (EVar "noDeclLoc"))))
(DTypeSig false "curryLam" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "curryLam" ((PList) (PVar "body")) (EVar "body"))
(DFunDef false "curryLam" ((PCons (PVar "p") (PVar "ps")) (PVar "body")) (EApp (EApp (EVar "ELam") (EListLit (EVar "p"))) (EApp (EApp (EVar "curryLam") (EVar "ps")) (EVar "body"))))
(DTypeSig false "parseExprStmt" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt"))))
(DFunDef false "parseExprStmt" () (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "startPos")) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "e")) (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EApp (EApp (EVar "exprStmtFor") (EVar "startPos")) (EVar "e")) (EVar "t")))))))))
(DTypeSig false "exprStmtFor" (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "DoStmt")))))))
(DFunDef false "exprStmtFor" (PWild (PVar "e") (PCon "TLArrow")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "rhs")) (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "bindStmts") (EVar "e")) (EVar "rhs"))))))))
(DFunDef false "exprStmtFor" ((PVar "startPos") (PVar "e") (PCon "TEqual")) (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EApp (EApp (EMethodRef "deferThen") (EVar "parseExpr")) (ELam ((PVar "rhs")) (EApp (EApp (EMethodRef "deferThen") (EApp (EApp (EApp (EVar "assignFromLhs") (EVar "startPos")) (EVar "e")) (EVar "rhs"))) (ELam ((PVar "s")) (EApp (EMethodRef "deferPure") (EListLit (EVar "s"))))))))))
(DFunDef false "exprStmtFor" (PWild (PVar "e") PWild) (EApp (EMethodRef "deferPure") (EListLit (EApp (EVar "DoExpr") (EVar "e")))))
(DTypeSig false "bindStmts" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "DoStmt")))))
(DFunDef false "bindStmts" ((PVar "lhs") (PVar "rhs")) (EMatch (EApp (EVar "stripLoc") (EVar "lhs")) (arm (PCon "EAnnot" (PVar "inner") (PVar "ty")) () (EApp (EApp (EApp (EVar "bindAnnot") (EVar "inner")) (EVar "ty")) (EVar "rhs"))) (arm PWild () (EListLit (EApp (EApp (EVar "DoBind") (EApp (EVar "exprToPat") (EVar "lhs"))) (EVar "rhs"))))))
(DTypeSig false "bindAnnot" (TyFun (TyCon "Expr") (TyFun (TyCon "Ty") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "DoStmt"))))))
(DFunDef false "bindAnnot" ((PVar "inner") (PVar "ty") (PVar "rhs")) (EMatch (EApp (EVar "stripLoc") (EVar "inner")) (arm (PCon "EVar" (PVar "x")) () (EListLit (EApp (EApp (EVar "DoBind") (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId"))) (EVar "rhs")) (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "False")) (EVar "False")) (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId"))) (EApp (EApp (EVar "EAnnot") (EApp (EVar "EVar") (EVar "x"))) (EVar "ty"))) (EVar "noDeclLoc")))) (arm (PVar "other") () (EListLit (EApp (EApp (EVar "DoBind") (EApp (EVar "exprToPat") (EVar "other"))) (EVar "rhs"))))))
(DTypeSig false "assignFromLhs" (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Parser") (TyCon "DoStmt"))))))
(DFunDef false "assignFromLhs" ((PVar "startPos") (PVar "lhs") (PVar "rhs")) (EMatch (EApp (EVar "flattenFieldPath") (EVar "lhs")) (arm (PCon "Some" (PTuple (PVar "x") (PList))) () (EApp (EMethodRef "deferPure") (EApp (EApp (EVar "DoAssign") (EVar "x")) (EVar "rhs")))) (arm (PCon "Some" (PTuple (PVar "x") (PVar "fs"))) () (EApp (EApp (EVar "fatalAtP") (EApp (EApp (EVar "fieldAssignRemovedMsg") (EVar "x")) (EVar "fs"))) (EVar "startPos"))) (arm (PCon "None") () (EApp (EVar "failP") (ELit (LString "invalid assignment target in this block"))))))
(DTypeSig false "fieldAssignRemovedMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "fieldAssignRemovedMsg" ((PVar "x") (PVar "fs")) (EBlock (DoLet false false (PVar "path") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EBinOp "::" (EVar "x") (EVar "fs")))) (DoExpr (EIf (EApp (EVar "isCtorName") (EVar "x")) (EBinOp "++" (EBinOp "++" (ELit (LString "field assignment `")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString " = e` has been removed; bindings are immutable, so bind the new value to a new name"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "field assignment `")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString " = e` has been removed; build an updated record instead, `"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "recordUpdateText") (EVar "x")) (EVar "fs")))) (ELit (LString "`")))))))
(DTypeSig false "recordUpdateText" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "recordUpdateText" (PWild (PList)) (ELit (LString "e")))
(DFunDef false "recordUpdateText" ((PVar "base") (PList (PVar "f"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "{ ")) (EApp (EMethodRef "display") (EVar "base"))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString " = e }"))))
(DFunDef false "recordUpdateText" ((PVar "base") (PCons (PVar "f") (PVar "fs"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "recordUpdateText") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "base"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString "")))) (EVar "fs"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "{ ")) (EApp (EMethodRef "display") (EVar "base"))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString " = "))) (EApp (EMethodRef "display") (EVar "inner"))) (ELit (LString " }"))))))
(DTypeSig false "flattenFieldPath" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "flattenFieldPath" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "flattenFieldPath") (EVar "e")))
(DFunDef false "flattenFieldPath" ((PCon "EVar" (PVar "x"))) (EApp (EVar "Some") (ETuple (EVar "x") (EListLit))))
(DFunDef false "flattenFieldPath" ((PCon "EFieldAccess" (PVar "inner") (PVar "f") PWild)) (EApp (EApp (EVar "fieldPathExtend") (EApp (EVar "flattenFieldPath") (EVar "inner"))) (EVar "f")))
(DFunDef false "flattenFieldPath" (PWild) (EVar "None"))
(DTypeSig false "fieldPathExtend" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "fieldPathExtend" ((PCon "Some" (PTuple (PVar "x") (PVar "fs"))) (PVar "f")) (EApp (EVar "Some") (ETuple (EVar "x") (EBinOp "++" (EVar "fs") (EListLit (EVar "f"))))))
(DFunDef false "fieldPathExtend" ((PCon "None") PWild) (EVar "None"))
(DTypeSig false "skipNoise" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "skipNoise" () (EApp (EApp (EMethodRef "deferThen") (EVar "peekP")) (ELam ((PVar "t")) (EApp (EVar "skipNoiseFor") (EVar "t")))))
(DTypeSig false "skipNoiseFor" (TyFun (TyCon "Token") (TyApp (TyCon "Parser") (TyCon "Unit"))))
(DFunDef false "skipNoiseFor" ((PCon "TNewline")) (EVar "afterNoise"))
(DFunDef false "skipNoiseFor" ((PCon "TIndent")) (EVar "afterNoise"))
(DFunDef false "skipNoiseFor" ((PCon "TDedent")) (EVar "afterNoise"))
(DFunDef false "skipNoiseFor" (PWild) (EApp (EMethodRef "deferPure") (ELit LUnit)))
(DTypeSig false "afterNoise" (TyApp (TyCon "Parser") (TyCon "Unit")))
(DFunDef false "afterNoise" () (EApp (EApp (EMethodRef "deferThen") (EVar "advance")) (ELam (PWild) (EVar "skipNoise"))))
(DTypeSig false "declThenNoise" (TyApp (TyCon "Parser") (TyCon "Decl")))
(DFunDef false "declThenNoise" () (EApp (EApp (EMethodRef "deferThen") (EVar "parseDecl")) (ELam ((PVar "d")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNoise")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EVar "d")))))))
(DTypeSig false "parseProgram" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "parseProgram" () (EApp (EApp (EMethodRef "deferThen") (EVar "skipNoise")) (ELam (PWild) (EApp (EVar "many") (EVar "declThenNoise")))))
(DTypeSig false "declWithSpan" (TyApp (TyCon "Parser") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "declWithSpan" () (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "s")) (EApp (EApp (EMethodRef "deferThen") (EVar "parseDecl")) (ELam ((PVar "d")) (EApp (EApp (EMethodRef "deferThen") (EVar "getPos")) (ELam ((PVar "e")) (EApp (EMethodRef "deferPure") (ETuple (EVar "d") (EVar "s") (EVar "e"))))))))))
(DTypeSig false "spanDeclThenNoise" (TyApp (TyCon "Parser") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "spanDeclThenNoise" () (EApp (EApp (EMethodRef "deferThen") (EVar "declWithSpan")) (ELam ((PVar "ds")) (EApp (EApp (EMethodRef "deferThen") (EVar "skipNoise")) (ELam (PWild) (EApp (EMethodRef "deferPure") (EVar "ds")))))))
(DTypeSig false "programWithSpans" (TyApp (TyCon "Parser") (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "programWithSpans" () (EApp (EApp (EMethodRef "deferThen") (EVar "skipNoise")) (ELam (PWild) (EApp (EVar "many") (EVar "spanDeclThenNoise")))))
(DTypeSig true "parseWithPositions" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions"))))
(DFunDef false "parseWithPositions" ((PVar "src")) (EMatch (EApp (EVar "parseWithPositionsOpt") (EVar "src")) (arm (PCon "Some" (PVar "r")) () (EVar "r")) (arm (PCon "None") () (EApp (EVar "panic") (ELit (LString "parse error"))))))
(DTypeSig true "parseWithPositionsLocated" (TyFun (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions"))))
(DFunDef false "parseWithPositionsLocated" ((PVar "src")) (EApp (EVar "parseWithPositions") (EVar "src")))
(DTypeSig true "parseWithPositionsOpt" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")))))
(DFunDef false "parseWithPositionsOpt" ((PVar "src")) (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "parse.positions")))) (DoExpr (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "tokList") (PVar "offPairList")) () (EApp (EApp (EApp (EVar "parseWithPositionsOptPairs") (EVar "src")) (EVar "tokList")) (EVar "offPairList")))))))
(DTypeSig true "parseWithPositionsOptPairs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")))))))
(DFunDef false "parseWithPositionsOptPairs" ((PVar "src") (PVar "tokList") (PVar "offPairList")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "parsed")) (ETuple (EApp (EVar "parsedDecls") (EVar "parsed")) (EApp (EVar "parsedPositions") (EVar "parsed"))))) (EApp (EApp (EApp (EVar "parseSourceSyntaxPairs") (EVar "src")) (EVar "tokList")) (EVar "offPairList"))))
(DTypeSig true "parseSourceSyntaxPairs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "Option") (TyCon "ParsedSource"))))))
(DFunDef false "parseSourceSyntaxPairs" ((PVar "src") (PVar "tokList") (PVar "offPairList")) (EBlock (DoLet false false (PVar "ctx") (EApp (EApp (EApp (EApp (EVar "newParseContextWith") (EVar "LocatedSyntax")) (EVar "src")) (EApp (EVar "arrayFromList") (EVar "tokList"))) (EApp (EVar "arrayFromList") (EVar "offPairList")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "programWithSpans")) (ELit (LInt 0))) (arm (PCon "POk" (PVar "spans") (PVar "pos")) ((GBool (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EApp (EVar "contextTokens") (EVar "ctx"))) (EVar "pos"))))) (EApp (EVar "Some") (EApp (EApp (EVar "publishSource") (EVar "ctx")) (EVar "spans")))) (arm PWild () (EVar "None"))))))
(DTypeSig false "publishSource" (TyFun (TyCon "ParseContext") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Decl") (TyCon "Int") (TyCon "Int"))) (TyCon "ParsedSource"))))
(DFunDef false "publishSource" ((PVar "ctx") (PVar "spans")) (EBlock (DoLet false false (PTuple (PVar "commas") (PVar "units")) (EApp (EVar "contextCues") (EVar "ctx"))) (DoExpr (EApp (EApp (EApp (EVar "makeParsedSource") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "d") (PVar "_s") (PVar "_e"))) (EVar "d"))) (EVar "spans"))) (EApp (EApp (EApp (EApp (EVar "positionsFromSpans") (EApp (EVar "contextLineStarts") (EVar "ctx"))) (EApp (EVar "contextTokens") (EVar "ctx"))) (EApp (EVar "contextOffsets") (EVar "ctx"))) (EVar "spans"))) (EApp (EApp (EVar "makeParseMetadata") (EVar "commas")) (EVar "units"))))))
(DTypeSig true "parseSource" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseDiagnostic")) (TyCon "ParsedSource"))))
(DFunDef false "parseSource" ((PVar "src")) (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "toks") (PVar "pairs")) () (EApp (EApp (EApp (EVar "parseSourcePairs") (EVar "src")) (EVar "toks")) (EVar "pairs")))))
(DTypeSig true "parseSourcePairs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyApp (TyCon "Result") (TyCon "ParseDiagnostic")) (TyCon "ParsedSource"))))))
(DFunDef false "parseSourcePairs" ((PVar "src") (PVar "tokList") (PVar "offPairs")) (EApp (EApp (EApp (EApp (EVar "parseSourcePairsWithIndex") (EVar "src")) (EVar "tokList")) (EVar "offPairs")) (ELam ((PLit LUnit)) (EApp (EVar "indexSource") (EVar "src")))))
(DTypeSig true "parseSourcePairsWithIndex" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyFun (TyCon "Unit") (TyCon "SourceIndex")) (TyApp (TyApp (TyCon "Result") (TyCon "ParseDiagnostic")) (TyCon "ParsedSource")))))))
(DFunDef false "parseSourcePairsWithIndex" ((PVar "src") (PVar "tokList") (PVar "offPairs") (PVar "index")) (EBlock (DoLet false false (PVar "toks") (EApp (EVar "arrayFromList") (EVar "tokList"))) (DoLet false false (PVar "offs") (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "offPairs")))) (DoLet false false (PVar "ends") (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "offPairs")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "prescanError") (EVar "src")) (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "parseErrorDiagnostic") (EVar "e")))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "ctx") (EApp (EApp (EApp (EVar "newParseContext") (EVar "src")) (EVar "toks")) (EApp (EVar "arrayFromList") (EVar "offPairs")))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "programWithSpans")) (ELit (LInt 0))) (arm (PCon "POk" (PVar "spans") (PVar "pos")) ((GBool (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos"))))) (EApp (EVar "Ok") (EApp (EApp (EVar "publishSource") (EVar "ctx")) (EVar "spans")))) (arm (PCon "POk" PWild (PVar "pos")) () (EApp (EVar "Err") (EApp (EVar "parseErrorDiagnostic") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "deepenLeftover") (EVar "ctx")) (EVar "src")) (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EApp (EVar "stringLength") (EVar "src"))) (EVar "pos"))))) (arm (PCon "PErr" (PVar "f") (PVar "pos")) () (EApp (EVar "Err") (EApp (EVar "parseErrorDiagnostic") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EApp (EVar "stringLength") (EVar "src"))) (EApp (EVar "failProblem") (EVar "f"))) (EVar "pos"))))) (arm (PCon "PFatal" (PVar "f") (PVar "pos")) () (EApp (EVar "Err") (EApp (EVar "parseErrorDiagnostic") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EApp (EVar "stringLength") (EVar "src"))) (EApp (EVar "failProblem") (EVar "f"))) (EVar "pos")))))))))))))
(DTypeSig true "parseDeclAt" (TyFun (TyCon "ParseContext") (TyFun (TyCon "Int") (TyApp (TyCon "PR") (TyCon "Decl")))))
(DFunDef false "parseDeclAt" ((PVar "ctx") (PVar "pos")) (EBlock (DoLet false false (PVar "saved") (EApp (EVar "mark") (EVar "ctx"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "parseDecl")) (EVar "pos")) (arm (PAs "r" (PCon "POk" PWild PWild)) () (EVar "r")) (arm (PVar "r") () (EBlock (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EVar "r"))))))))
(DTypeSig false "resultDecls" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "PR") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "resultDecls" (PWild (PCon "PErr" PWild PWild)) (EApp (EVar "panic") (ELit (LString "parse error"))))
(DFunDef false "resultDecls" (PWild (PCon "PFatal" PWild PWild)) (EApp (EVar "panic") (ELit (LString "parse error"))))
(DFunDef false "resultDecls" ((PVar "toks") (PCon "POk" (PVar "ds") (PVar "pos"))) (EIf (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos"))) (EVar "ds") (EIf (EVar "otherwise") (EApp (EVar "panic") (ELit (LString "parse error"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "parse" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "parse" ((PVar "src")) (EBlock (DoLet false false (PVar "toks") (EApp (EVar "arrayFromList") (EApp (EVar "tokenize") (EVar "src")))) (DoExpr (EMatch (EApp (EApp (EVar "firstLexError") (EVar "toks")) (ELit (LInt 0))) (arm (PCon "Some" (PTuple PWild (PVar "kind"))) () (EApp (EVar "panic") (EApp (EVar "renderParseProblem") (EVar "kind")))) (arm (PCon "None") () (EApp (EApp (EVar "resultDecls") (EVar "toks")) (EApp (EApp (EApp (EVar "runP") (EVar "parseProgram")) (EVar "toks")) (ELit (LInt 0)))))))))
(DTypeSig true "parseLocated" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))))
(DFunDef false "parseLocated" ((PVar "src")) (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "tokList") (PVar "offPairs")) () (EBlock (DoLet false false (PVar "toks") (EApp (EVar "arrayFromList") (EVar "tokList"))) (DoLet false false (PVar "ctx") (EApp (EApp (EApp (EApp (EVar "newParseContextWith") (EVar "LocatedSyntax")) (EVar "src")) (EVar "toks")) (EApp (EVar "arrayFromList") (EVar "offPairs")))) (DoExpr (EApp (EApp (EVar "resultDecls") (EVar "toks")) (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "parseProgram")) (ELit (LInt 0)))))))))
(DTypeSig false "resultDeclsResult" (TyFun (TyCon "ParseContext") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyCon "SourceIndex")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "PR") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl"))))))))))))
(DFunDef false "resultDeclsResult" (PWild PWild (PVar "index") (PVar "toks") (PVar "offs") (PVar "ends") (PVar "srcLen") (PCon "PErr" (PVar "f") (PVar "pos"))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "failProblem") (EVar "f"))) (EVar "pos"))))
(DFunDef false "resultDeclsResult" (PWild PWild (PVar "index") (PVar "toks") (PVar "offs") (PVar "ends") (PVar "srcLen") (PCon "PFatal" (PVar "f") (PVar "pos"))) (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "failProblem") (EVar "f"))) (EVar "pos"))))
(DFunDef false "resultDeclsResult" ((PVar "ctx") (PVar "src") (PVar "index") (PVar "toks") (PVar "offs") (PVar "ends") (PVar "srcLen") (PCon "POk" (PVar "ds") (PVar "pos"))) (EIf (EApp (EVar "isEofTok") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos"))) (EApp (EVar "Ok") (EVar "ds")) (EIf (EVar "otherwise") (EApp (EVar "Err") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "deepenLeftover") (EVar "ctx")) (EVar "src")) (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EVar "pos"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "deepenLeftover" (TyFun (TyCon "ParseContext") (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyCon "SourceIndex")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "ParseError"))))))))))
(DFunDef false "deepenLeftover" ((PVar "ctx") (PVar "src") (PVar "index") (PVar "toks") (PVar "offs") (PVar "ends") (PVar "srcLen") (PVar "pos")) (EBlock (DoLet false false (PVar "saved") (EApp (EVar "mark") (EVar "ctx"))) (DoLet false false (PVar "result") (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "parseDecl")) (EVar "pos"))) (DoExpr (EApp (EVar "rewind") (EVar "saved"))) (DoExpr (EMatch (EVar "result") (arm (PCon "PFatal" (PVar "f") (PVar "pos2")) () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "failProblem") (EVar "f"))) (EVar "pos2"))) (arm (PCon "PErr" (PVar "f") (PVar "pos2")) ((GBool (EBinOp ">" (EVar "pos2") (EVar "pos")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "failProblem") (EVar "f"))) (EVar "pos2"))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkLocated") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EApp (EVar "GenericParse") (EApp (EApp (EApp (EApp (EApp (EVar "unexpectedLeftoverMsg") (EVar "src")) (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "pos")))) (EVar "pos")))))))
(DTypeSig false "mkLocated" (TyFun (TyFun (TyCon "Unit") (TyCon "SourceIndex")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "ParseDiagnosticKind") (TyFun (TyCon "Int") (TyCon "ParseError")))))))))
(DFunDef false "mkLocated" ((PVar "index") (PVar "toks") (PVar "offs") (PVar "ends") (PVar "srcLen") (PVar "kind") (PVar "pos")) (EApp (EVar "ParseError") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "locateTokenDiagnostic") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EVar "srcLen")) (EVar "kind")) (EVar "pos"))))
(DTypeSig false "leadingIndentAt" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "leadingIndentAt" ((PVar "src") (PVar "offset")) (EBlock (DoLet false false (PVar "chars") (EApp (EVar "stringToChars") (EVar "src"))) (DoLet false false (PVar "lineStart") (EApp (EApp (EVar "leadingIndentLineStart") (EVar "chars")) (EBinOp "-" (EVar "offset") (ELit (LInt 1))))) (DoExpr (EIf (EApp (EApp (EApp (EVar "leadingIndentAllBlank") (EVar "chars")) (EVar "lineStart")) (EVar "offset")) (EApp (EVar "Some") (EBinOp "-" (EVar "offset") (EVar "lineStart"))) (EVar "None")))))
(DTypeSig false "leadingIndentLineStart" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "leadingIndentLineStart" ((PVar "chars") (PVar "i")) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (ELit (LInt 0)) (EIf (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")) (ELit (LChar "\n"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")) (ELit (LChar "\r")))) (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EIf (EVar "otherwise") (EApp (EApp (EVar "leadingIndentLineStart") (EVar "chars")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "leadingIndentAllBlank" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "leadingIndentAllBlank" ((PVar "chars") (PVar "i") (PVar "limit")) (EIf (EBinOp ">=" (EVar "i") (EVar "limit")) (EVar "True") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "chars")) (arm (PLit (LChar " ")) () (EApp (EApp (EApp (EVar "leadingIndentAllBlank") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "limit"))) (arm (PLit (LChar "\t")) () (EApp (EApp (EApp (EVar "leadingIndentAllBlank") (EVar "chars")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "limit"))) (arm PWild () (EVar "False"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "unexpectedLeftoverMsg" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String")))))))
(DFunDef false "unexpectedLeftoverMsg" ((PVar "src") (PVar "toks") (PVar "offs") (PVar "srcLen") (PVar "pos")) (EBlock (DoLet false false (PVar "base") (EApp (EVar "unexpectedTokenMsg") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos")))) (DoLet false false (PVar "offset") (EApp (EApp (EApp (EApp (EVar "locateOffset") (EVar "toks")) (EVar "offs")) (EVar "srcLen")) (EVar "pos"))) (DoExpr (EMatch (EApp (EApp (EVar "leadingIndentAt") (EVar "src")) (EVar "offset")) (arm (PCon "Some" (PVar "col")) ((GBool (EBinOp ">" (EVar "col") (ELit (LInt 0))))) (EApp (EApp (EApp (EVar "leadingIndentMsg") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos"))) (EVar "base")) (EVar "col"))) (arm PWild () (EApp (EApp (EVar "trailingArrowLeftoverMsg") (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "pos"))) (EVar "base")))))))
(DTypeSig false "trailingArrowLeftoverMsg" (TyFun (TyCon "Token") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "trailingArrowLeftoverMsg" ((PCon "TArrow") (PVar "base")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "base"))) (ELit (LString "; a later line of this type signature dedents past its first continuation line, so indent every wrapped line at least that far"))))
(DFunDef false "trailingArrowLeftoverMsg" (PWild (PVar "base")) (EVar "base"))
(DTypeSig false "leadingIndentMsg" (TyFun (TyCon "Token") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "leadingIndentMsg" ((PCon "TArrow") (PVar "base") (PVar "col")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "base"))) (ELit (LString "; a line cannot start with `->`, so put it at the end of the previous line, as in `f : Int ->` then an indented `Int`"))))
(DFunDef false "leadingIndentMsg" (PWild (PVar "base") (PVar "col")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "base"))) (ELit (LString "; this line is indented to column "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "col")))) (ELit (LString ", which matches no enclosing block"))))
(DTypeSig false "firstLexError" (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "ParseDiagnosticKind"))))))
(DFunDef false "firstLexError" ((PVar "toks") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "toks"))) (EVar "None") (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "peekTok") (EVar "toks")) (EVar "i")) (arm (PCon "TLexError" (PVar "msg")) () (EApp (EVar "Some") (ETuple (EVar "i") (EVar "msg")))) (arm PWild () (EApp (EApp (EVar "firstLexError") (EVar "toks")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "parseResult" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "parseResult" ((PVar "src")) (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "tokList") (PVar "offList")) () (EApp (EApp (EApp (EApp (EVar "parseResultWith") (EVar "UnlocatedChecked")) (EVar "src")) (EVar "tokList")) (EVar "offList")))))
(DTypeSig true "parseResultPairs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "parseResultPairs" ((PVar "src") (PVar "tokList") (PVar "offPairs")) (EApp (EApp (EApp (EApp (EVar "parseResultWith") (EVar "UnlocatedChecked")) (EVar "src")) (EVar "tokList")) (EVar "offPairs")))
(DTypeSig true "parseLocatedResult" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "parseLocatedResult" ((PVar "src")) (EMatch (EApp (EVar "tokenizeWithOffsetPairs") (EVar "src")) (arm (PTuple (PVar "tokList") (PVar "offPairs")) () (EApp (EApp (EApp (EApp (EVar "parseResultWith") (EVar "LocatedChecked")) (EVar "src")) (EVar "tokList")) (EVar "offPairs")))))
(DTypeSig true "prescanError" (TyFun (TyCon "String") (TyFun (TyFun (TyCon "Unit") (TyCon "SourceIndex")) (TyFun (TyApp (TyCon "Array") (TyCon "Token")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "ParseError"))))))))
(DFunDef false "prescanError" ((PVar "src") (PVar "index") (PVar "toks") (PVar "offs") (PVar "ends")) (EBlock (DoLet false false PWild (EApp (EVar "stageBump") (ELit (LString "parse.prescan")))) (DoExpr (EApp (EApp (EMethodRef "map") (EVar "ParseError")) (EApp (EApp (EApp (EApp (EApp (EVar "prescanDiagnostic") (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EApp (EVar "stringLength") (EVar "src")))))))
(DTypeSig true "prescanErrorPairs" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "Option") (TyCon "ParseError"))))))
(DFunDef false "prescanErrorPairs" ((PVar "src") (PVar "tokList") (PVar "offPairs")) (EApp (EApp (EApp (EApp (EVar "prescanErrorPairsWithIndex") (EVar "src")) (EVar "tokList")) (EVar "offPairs")) (ELam ((PLit LUnit)) (EApp (EVar "indexSource") (EVar "src")))))
(DTypeSig true "prescanErrorPairsWithIndex" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyFun (TyCon "Unit") (TyCon "SourceIndex")) (TyApp (TyCon "Option") (TyCon "ParseError")))))))
(DFunDef false "prescanErrorPairsWithIndex" ((PVar "src") (PVar "tokList") (PVar "offPairs") (PVar "index")) (EApp (EApp (EApp (EApp (EApp (EVar "prescanError") (EVar "src")) (EMethodRef "index")) (EApp (EVar "arrayFromList") (EVar "tokList"))) (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "offPairs")))) (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "offPairs")))))
(DTypeSig false "parseResultWith" (TyFun (TyCon "ParseMode") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Token")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyApp (TyCon "List") (TyCon "Decl"))))))))
(DFunDef false "parseResultWith" ((PVar "mode") (PVar "src") (PVar "tokList") (PVar "offList")) (EBlock (DoLet false false (PVar "toks") (EApp (EVar "arrayFromList") (EVar "tokList"))) (DoLet false false (PVar "offs") (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "offList")))) (DoLet false false (PVar "ends") (EApp (EVar "arrayFromList") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "offList")))) (DoLet false true (PVar "index") (ELam ((PLit LUnit)) (EApp (EVar "indexSource") (EVar "src")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "prescanError") (EVar "src")) (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "ctx") (EApp (EApp (EApp (EApp (EVar "newParseContextWith") (EVar "mode")) (EVar "src")) (EVar "toks")) (EApp (EVar "arrayFromList") (EVar "offList")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "resultDeclsResult") (EVar "ctx")) (EVar "src")) (EMethodRef "index")) (EVar "toks")) (EVar "offs")) (EVar "ends")) (EApp (EVar "stringLength") (EVar "src"))) (EApp (EApp (EApp (EVar "runPWith") (EVar "ctx")) (EVar "parseProgram")) (ELit (LInt 0)))))))))))
