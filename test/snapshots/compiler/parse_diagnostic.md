# META
source_lines=331
stages=DESUGAR,MARK
# SOURCE
import support.diag_codes.{DiagCode(..)}
import frontend.ast.{Loc(..)}
import support.source_index.{SourceIndex, offsetToSourcePosition}

public export data EditApplicability =
  | MachineApplicable
  | HumanOnly
  deriving (Eq)

public export data ParseEdit = ParseEdit Loc String String EditApplicability

public export data ParseDiagnostic =
  ParseDiagnostic ParseDiagnosticKind Loc (List ParseEdit)

public export data UnicodeProblem =
  | UnicodeUnterminated
  | UnicodeSeparator
  | UnicodeEmpty
  | UnicodeExpectedDigit String
  | UnicodeExpectedClose String
  | UnicodeSurrogate String
  | UnicodeOutOfRange String
  deriving (Eq)

public export data ParseDiagnosticKind =
  | NestedInterpolation
  | UnterminatedString
  | UnterminatedComment
  | UnterminatedChar
  | EmptyChar
  | IntegerOverflow
  | PositiveIntOverflow
  | FloatOverflow
  | HsLambda
  | HsDollar
  | UnexpectedEnd
  | UnexpectedEndExpected String
  | BadNeq
  | RawStringAfterDot
  | HsCase
  | MatchWith
  | NoPow
  | HsSignature
  | BlockComment
  | BraceBlock
  | Semicolon
  | MatchGuardBar
  | MatchGuardBarWrapped
  | ExpectedMatchArm
  | ExpectedMatchArrow
  | MatchContinuationHint
  | EquationGuardIf
  | GenericParse String
  | InvalidEscape String Bool
  | BadUnicodeEscape UnicodeProblem
  | BareUnicodeEscape String String
  | LongChar String
  | NonAsciiByte String String
  | BadByteLiteral String
  | ByteLikeIdent String String
  | UnexpectedCharacter String
  | WidePattern String
  | MalformedRadix String String String
  | MalformedFloat String String Bool
  | ForeignKeyword String
  | MissingWhere String
  | WhereSameLine String
  | BlockEndsBinding String
  | ReservedKeyword String
  | PublicDataOnly Bool
  deriving (Eq)

export
diagnosticCode : ParseDiagnostic -> DiagCode
diagnosticCode (ParseDiagnostic kind _ _) = problemCode kind

problemCode : ParseDiagnosticKind -> DiagCode
problemCode NestedInterpolation = LNestedInterpolation
problemCode UnterminatedString = LUnterminatedString
problemCode UnterminatedComment = LUnterminatedComment
problemCode UnterminatedChar = LBadCharLiteral
problemCode EmptyChar = LBadCharLiteral
problemCode IntegerOverflow = LIntOverflow
problemCode PositiveIntOverflow = LIntOverflow
problemCode FloatOverflow = LFloatOverflow
problemCode HsLambda = LHsLambda
problemCode HsDollar = LHsDollar
problemCode UnexpectedEnd = PUnexpectedEof
problemCode (UnexpectedEndExpected _) = PUnexpectedEof
problemCode BadNeq = PBadNeq
problemCode RawStringAfterDot = PRawStringAfterDot
problemCode HsCase = PHsCase
problemCode MatchWith = POcamlMatchWith
problemCode NoPow = PNoPowOperator
problemCode HsSignature = PHsSig
problemCode BlockComment = LBlockcomment
problemCode BraceBlock = PBraceBlock
problemCode Semicolon = LSemicolon
problemCode MatchGuardBar = PGuardBarInMatch
problemCode MatchGuardBarWrapped = PGuardBarInMatch
problemCode ExpectedMatchArm = PParse
problemCode ExpectedMatchArrow = PParse
problemCode MatchContinuationHint = PParse
problemCode EquationGuardIf = PGuardIfInEquation
problemCode (GenericParse _) = PParse
problemCode (InvalidEscape _ _) = LBadEscape
problemCode (BadUnicodeEscape _) = LBadUnicodeEscape
problemCode (BareUnicodeEscape _ _) = LBareUnicodeEscape
problemCode (LongChar _) = LBadCharLiteral
problemCode (UnexpectedCharacter _) = LBadChar
problemCode (NonAsciiByte _ _) = LByteNonAscii
problemCode (BadByteLiteral _) = LBadByteLiteral
problemCode (ByteLikeIdent _ _) = LByteLiteralIdent
problemCode (WidePattern _) = LIntOverflow
problemCode (MalformedRadix _ _ _) = LMalformedRadix
problemCode (MalformedFloat _ _ _) = LMalformedFloat
problemCode (MissingWhere _) = PMissingWhere
problemCode (WhereSameLine _) = PWhereBodySameLine
problemCode (BlockEndsBinding _) = PDoEndsInBinding
problemCode (ReservedKeyword _) = PReservedKeyword
problemCode (PublicDataOnly _) = PParse
problemCode (ForeignKeyword word)
  | word == "def" = PDefKeyword
  | word == "for" || word == "while" = PForWhile
  | otherwise = PParse

export
diagnosticLoc : ParseDiagnostic -> Loc
diagnosticLoc (ParseDiagnostic _ loc _) = loc

export
diagnosticEdits : ParseDiagnostic -> List ParseEdit
diagnosticEdits (ParseDiagnostic _ _ edits) = edits

export
renderParseDiagnostic : ParseDiagnostic -> String
renderParseDiagnostic (ParseDiagnostic kind _ _) = renderParseProblem kind

export
renderParseProblem : ParseDiagnosticKind -> String
renderParseProblem NestedInterpolation =
  "nested string interpolation is not supported"
renderParseProblem UnterminatedString = "unterminated string literal"
renderParseProblem UnterminatedComment = "unterminated block comment"
renderParseProblem UnterminatedChar = "unterminated character literal"
renderParseProblem EmptyChar =
  "character literal is empty; a character is exactly one codepoint, such as `'a'`"
renderParseProblem IntegerOverflow =
  "integer literal too large for U64 (max 2^64 - 1)"
renderParseProblem PositiveIntOverflow =
  "integer literal too large for Int (max 4611686018427387903)"
renderParseProblem FloatOverflow =
  "float literal out of range (overflows to infinity)"
renderParseProblem HsLambda = "Medaka has no `\\x -> e` lambdas; write `x => e`"
renderParseProblem HsDollar = "Medaka has no `$`; write `f (g x)`"
renderParseProblem UnexpectedEnd = "unexpected end of input"
renderParseProblem BadNeq = "unexpected `!=`; did you mean `/=`?"
renderParseProblem RawStringAfterDot =
  "`.r\"` reads as a raw string literal, not the field `r`; put a space after the `r`, as in `p.r \"x\"`, or parenthesise the field access, as in `(p.r) \"x\"`"
renderParseProblem HsCase =
  "Medaka has no `case ... of`; write `match e` with indented `pattern => body` arms"
renderParseProblem MatchWith =
  "Medaka has no `match ... with`; write `match e` with indented `pattern => body` arms"
renderParseProblem NoPow = "Medaka has no `**`; write `pow x y`"
renderParseProblem HsSignature =
  "`::` is the list cons operator; write `f : T` for a type signature"
renderParseProblem BlockComment =
  "Medaka has no `/* ... */` comments; write `{- ... -}` or `--`"
renderParseProblem BraceBlock =
  "Medaka has no `{ ... }` blocks; indent the body after `then` and `else`"
renderParseProblem Semicolon =
  "Medaka has no statement terminator `;`; write each statement on its own line"
renderParseProblem MatchGuardBar =
  "a match-arm guard uses `if`, not `|`; write `pat if cond => body`"
renderParseProblem MatchGuardBarWrapped =
  "a `|` ending a line cannot continue an or-pattern; wrap the alternatives in parentheses, `(A | B | C) => body`, or write them on one line"
renderParseProblem ExpectedMatchArm = "expected a match arm (`pattern => body`)"
renderParseProblem ExpectedMatchArrow =
  "expected `=>` after the match pattern or guard"
renderParseProblem MatchContinuationHint =
  "expected a match arm (`pattern => body`); if this line continues the scrutinee, wrap the whole scrutinee in parentheses"
renderParseProblem EquationGuardIf =
  "an equation guard uses `|`, not `if`; write `| cond = body`"
renderParseProblem (UnexpectedEndExpected expected) =
  "unexpected end of input; expected \{expected}"
renderParseProblem (GenericParse msg) = msg
renderParseProblem (InvalidEscape spelling inChar) =
  let quote = if inChar then "\\'" else "\\\""
  "invalid escape sequence `\{spelling}`; valid escapes are \\n \\t \\r \\0 \\\\ \{quote} \\u{...}"
renderParseProblem (BadUnicodeEscape problem) = renderUnicodeProblem problem
renderParseProblem (BareUnicodeEscape old new) =
  "bare unicode escape `\{old}` is not valid; did you mean `\{new}`?"
renderParseProblem (LongChar text) =
  "character literal `'\{text}'` has more than one codepoint; write a `\"...\"` string for text"
renderParseProblem (NonAsciiByte ch fixIt) =
  "byte literal `b'\{ch}'` is not ASCII; a byte literal holds one byte, so write its UTF-8 bytes as \{fixIt}"
renderParseProblem (BadByteLiteral msg) = msg
renderParseProblem (ByteLikeIdent old new) =
  "`\{old}` is a byte literal, not an identifier; rename it, for example `\{new}`"
renderParseProblem (UnexpectedCharacter text) = "unexpected character `\{text}`"
renderParseProblem (WidePattern lx) =
  "integer literal too large for a pattern: `\{lx}` exceeds Int; match it in a guard instead, `x if x == \{lx}`"
renderParseProblem (MalformedRadix bad prefix digits)
  | stringLength digits == 0 =
    "malformed radix literal `\{bad}`: no digits follow the \{prefix} prefix; an underscore may only separate digits"
  | otherwise =
    "malformed radix literal `\{bad}`: an underscore cannot follow the \{prefix} prefix; write `\{prefix}\{digits}`"
renderParseProblem (MalformedFloat bad good leading) =
  let side = if leading then "precede" else "follow"
  "malformed float literal `\{bad}`: a digit must \{side} the decimal point; write `\{good}`"
renderParseProblem (ForeignKeyword word) = foreignKeywordMessage word
renderParseProblem (MissingWhere header) =
  let members = if header == "impl" then "methods" else "members"
  "missing `where` on this `\{header}` header; end the header with `where` and indent the \{members} below it"
renderParseProblem (WhereSameLine header) =
  let member = if header == "impl" then "method" else "member"
  "a `where` block must start on the next line; move this \{member} onto its own line, indented below the `\{header}` header"
renderParseProblem (BlockEndsBinding word) =
  "a `\{word}` block must end in an expression, not a binding; add the expression whose value the block should have"
renderParseProblem (ReservedKeyword name) =
  "`\{name}` is a reserved keyword and cannot name a variable or pattern; rename it to `\{name}_`"
renderParseProblem (PublicDataOnly True) =
  "`public` applies only to `data` declarations with constructors; write `export extern`"
renderParseProblem (PublicDataOnly False) =
  "`public` applies only to `data` declarations; write plain `export`"

foreignKeywordMessage : String -> String
foreignKeywordMessage "def" = "Medaka has no `def`; write `f x = ...`"
foreignKeywordMessage "while" =
  "Medaka has no `while`; write a recursive function"
foreignKeywordMessage "elif" = "Medaka has no `elif`; write `else if`"
foreignKeywordMessage "class" =
  "Medaka has no `class`; write a `data` type or an `interface`"
foreignKeywordMessage "try" =
  "Medaka has no `try`; return errors as `Result` values"
foreignKeywordMessage "except" =
  "Medaka has no `except`; return errors as `Result` values"
foreignKeywordMessage "finally" =
  "Medaka has no `finally`; return errors as `Result` values"
foreignKeywordMessage _ =
  "Medaka has no `for` loops; use `map` or `fold` over the list"

renderUnicodeProblem : UnicodeProblem -> String
renderUnicodeProblem UnicodeUnterminated =
  "unicode escape is not terminated; the file ends before its closing `}`"
renderUnicodeProblem UnicodeSeparator =
  "unicode escape cannot contain `_`; write the hex digits unbroken, as in `\\u{41}`"
renderUnicodeProblem UnicodeEmpty =
  "unicode escape `\\u{}` has no digits; write at least one hex digit, as in `\\u{41}`"
renderUnicodeProblem (UnicodeExpectedDigit found) =
  "unicode escape expects a hex digit after `\\u{` but found `\{found}`"
renderUnicodeProblem (UnicodeExpectedClose found) =
  "unicode escape expects `}` after its hex digits but found `\{found}`"
renderUnicodeProblem (UnicodeSurrogate text) =
  "unicode escape `\{text}` is a UTF-16 surrogate, not a character; codepoints D800-DFFF are not valid on their own"
renderUnicodeProblem (UnicodeOutOfRange text) =
  "unicode escape `\{text}` is out of range; a codepoint is at most 10FFFF"

export
diagnosticHelp : ParseDiagnostic -> Option String
diagnosticHelp (ParseDiagnostic kind _ _) = problemHelp kind

problemHelp : ParseDiagnosticKind -> Option String
problemHelp HsSignature = Some "replace `::` with `:`"
problemHelp BadNeq = Some "replace `!=` with `/=`"
problemHelp RawStringAfterDot =
  Some "insert a space between the `r` and the opening quote"
problemHelp PositiveIntOverflow =
  Some
    "`Int` is 63-bit, spanning [-4611686018427387904, 4611686018427387903]; 4611686018427387904 fits only as the negative -4611686018427387904, so write it with its `-`"
problemHelp (NonAsciiByte _ fixIt) =
  Some "write the character as its UTF-8 bytes, \{fixIt}"
problemHelp (ByteLikeIdent _ new) =
  Some "rename every occurrence of the identifier, for example to `\{new}`"
problemHelp (BareUnicodeEscape _ _) =
  Some "write the unicode escape braced, `\\u{XXXX}`"
problemHelp (MalformedRadix _ _ _) =
  Some "the digit separator `_` may only appear between digits"
problemHelp (MalformedFloat _ _ _) =
  Some "a float literal needs a digit on both sides of the decimal point"
problemHelp (ReservedKeyword w) =
  Some "rename it to `\{w}_`; any reserved word plus `_` is a valid identifier"
problemHelp (PublicDataOnly _) =
  Some "drop `public`; a function or value is exported with plain `export`"
problemHelp (MissingWhere _) =
  Some
    "end the header with `where`; without it the next line is read as another type argument"
problemHelp (BlockEndsBinding _) =
  Some
    "end the block with the expression whose value it should have, such as `pure x`"
problemHelp (WhereSameLine _) =
  Some
    "`where` opens a block only when it ends the line; move the member to the next line"
problemHelp MatchGuardBar = Some "replace `|` with `if`"
problemHelp EquationGuardIf = Some "replace `if` with `|`"
problemHelp _ = None

-- Offsets are codepoints, and both ends are resolved against the same index.
export
locateParseProblem : SourceIndex ->
  Int ->
  Int ->
  ParseDiagnosticKind ->
  ParseDiagnostic
locateParseProblem index start end kind =
  let (sl, sc) = optionOr (1, 0) (offsetToSourcePosition index start)
  let (el, ec) = optionOr (sl, sc) (offsetToSourcePosition index end)
  let loc = Loc "" sl sc el ec
  makeParseDiagnostic kind loc

replacementEdit : Loc -> String -> String -> List ParseEdit
replacementEdit loc old new = [ParseEdit loc old new MachineApplicable]

problemEdits : ParseDiagnosticKind -> Loc -> List ParseEdit
problemEdits BadNeq loc = replacementEdit loc "!=" "/="
problemEdits RawStringAfterDot (Loc file sl sc _ _) =
  replacementEdit (Loc file sl sc sl (sc + 2)) "r\"" "r \""
problemEdits HsSignature loc = replacementEdit loc "::" ":"
problemEdits (BareUnicodeEscape old new) loc = replacementEdit loc old new
problemEdits (MalformedRadix bad prefix digits) loc =
  if digits == "" then [] else replacementEdit loc bad (prefix ++ digits)
problemEdits (MalformedFloat bad good _) loc = replacementEdit loc bad good
problemEdits (ReservedKeyword name) loc = replacementEdit loc name (name ++ "_")
problemEdits (PublicDataOnly _) loc = replacementEdit loc "public" ""
problemEdits MatchGuardBar loc = replacementEdit loc "|" "if"
problemEdits EquationGuardIf loc = replacementEdit loc "if" "|"
problemEdits _ _ = []

export
makeParseDiagnostic : ParseDiagnosticKind -> Loc -> ParseDiagnostic
makeParseDiagnostic kind loc = ParseDiagnostic kind loc (problemEdits kind loc)
# DESUGAR
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "offsetToSourcePosition" false))))
(DData Public "EditApplicability" () ((variant "MachineApplicable" (ConPos)) (variant "HumanOnly" (ConPos))) ())
(DImpl true "Eq" ((TyCon "EditApplicability")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "MachineApplicable") (PCon "MachineApplicable")) () (EVar "True")) (arm (PTuple (PCon "HumanOnly") (PCon "HumanOnly")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "ParseEdit" () ((variant "ParseEdit" (ConPos (TyCon "Loc") (TyCon "String") (TyCon "String") (TyCon "EditApplicability")))) ())
(DData Public "ParseDiagnostic" () ((variant "ParseDiagnostic" (ConPos (TyCon "ParseDiagnosticKind") (TyCon "Loc") (TyApp (TyCon "List") (TyCon "ParseEdit"))))) ())
(DData Public "UnicodeProblem" () ((variant "UnicodeUnterminated" (ConPos)) (variant "UnicodeSeparator" (ConPos)) (variant "UnicodeEmpty" (ConPos)) (variant "UnicodeExpectedDigit" (ConPos (TyCon "String"))) (variant "UnicodeExpectedClose" (ConPos (TyCon "String"))) (variant "UnicodeSurrogate" (ConPos (TyCon "String"))) (variant "UnicodeOutOfRange" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "UnicodeProblem")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "UnicodeUnterminated") (PCon "UnicodeUnterminated")) () (EVar "True")) (arm (PTuple (PCon "UnicodeSeparator") (PCon "UnicodeSeparator")) () (EVar "True")) (arm (PTuple (PCon "UnicodeEmpty") (PCon "UnicodeEmpty")) () (EVar "True")) (arm (PTuple (PCon "UnicodeExpectedDigit" (PVar "__a0")) (PCon "UnicodeExpectedDigit" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "UnicodeExpectedClose" (PVar "__a0")) (PCon "UnicodeExpectedClose" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "UnicodeSurrogate" (PVar "__a0")) (PCon "UnicodeSurrogate" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "UnicodeOutOfRange" (PVar "__a0")) (PCon "UnicodeOutOfRange" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "ParseDiagnosticKind" () ((variant "NestedInterpolation" (ConPos)) (variant "UnterminatedString" (ConPos)) (variant "UnterminatedComment" (ConPos)) (variant "UnterminatedChar" (ConPos)) (variant "EmptyChar" (ConPos)) (variant "IntegerOverflow" (ConPos)) (variant "PositiveIntOverflow" (ConPos)) (variant "FloatOverflow" (ConPos)) (variant "HsLambda" (ConPos)) (variant "HsDollar" (ConPos)) (variant "UnexpectedEnd" (ConPos)) (variant "UnexpectedEndExpected" (ConPos (TyCon "String"))) (variant "BadNeq" (ConPos)) (variant "RawStringAfterDot" (ConPos)) (variant "HsCase" (ConPos)) (variant "MatchWith" (ConPos)) (variant "NoPow" (ConPos)) (variant "HsSignature" (ConPos)) (variant "BlockComment" (ConPos)) (variant "BraceBlock" (ConPos)) (variant "Semicolon" (ConPos)) (variant "MatchGuardBar" (ConPos)) (variant "MatchGuardBarWrapped" (ConPos)) (variant "ExpectedMatchArm" (ConPos)) (variant "ExpectedMatchArrow" (ConPos)) (variant "MatchContinuationHint" (ConPos)) (variant "EquationGuardIf" (ConPos)) (variant "GenericParse" (ConPos (TyCon "String"))) (variant "InvalidEscape" (ConPos (TyCon "String") (TyCon "Bool"))) (variant "BadUnicodeEscape" (ConPos (TyCon "UnicodeProblem"))) (variant "BareUnicodeEscape" (ConPos (TyCon "String") (TyCon "String"))) (variant "LongChar" (ConPos (TyCon "String"))) (variant "NonAsciiByte" (ConPos (TyCon "String") (TyCon "String"))) (variant "BadByteLiteral" (ConPos (TyCon "String"))) (variant "ByteLikeIdent" (ConPos (TyCon "String") (TyCon "String"))) (variant "UnexpectedCharacter" (ConPos (TyCon "String"))) (variant "WidePattern" (ConPos (TyCon "String"))) (variant "MalformedRadix" (ConPos (TyCon "String") (TyCon "String") (TyCon "String"))) (variant "MalformedFloat" (ConPos (TyCon "String") (TyCon "String") (TyCon "Bool"))) (variant "ForeignKeyword" (ConPos (TyCon "String"))) (variant "MissingWhere" (ConPos (TyCon "String"))) (variant "WhereSameLine" (ConPos (TyCon "String"))) (variant "BlockEndsBinding" (ConPos (TyCon "String"))) (variant "ReservedKeyword" (ConPos (TyCon "String"))) (variant "PublicDataOnly" (ConPos (TyCon "Bool")))) ())
(DImpl true "Eq" ((TyCon "ParseDiagnosticKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "NestedInterpolation") (PCon "NestedInterpolation")) () (EVar "True")) (arm (PTuple (PCon "UnterminatedString") (PCon "UnterminatedString")) () (EVar "True")) (arm (PTuple (PCon "UnterminatedComment") (PCon "UnterminatedComment")) () (EVar "True")) (arm (PTuple (PCon "UnterminatedChar") (PCon "UnterminatedChar")) () (EVar "True")) (arm (PTuple (PCon "EmptyChar") (PCon "EmptyChar")) () (EVar "True")) (arm (PTuple (PCon "IntegerOverflow") (PCon "IntegerOverflow")) () (EVar "True")) (arm (PTuple (PCon "PositiveIntOverflow") (PCon "PositiveIntOverflow")) () (EVar "True")) (arm (PTuple (PCon "FloatOverflow") (PCon "FloatOverflow")) () (EVar "True")) (arm (PTuple (PCon "HsLambda") (PCon "HsLambda")) () (EVar "True")) (arm (PTuple (PCon "HsDollar") (PCon "HsDollar")) () (EVar "True")) (arm (PTuple (PCon "UnexpectedEnd") (PCon "UnexpectedEnd")) () (EVar "True")) (arm (PTuple (PCon "UnexpectedEndExpected" (PVar "__a0")) (PCon "UnexpectedEndExpected" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "BadNeq") (PCon "BadNeq")) () (EVar "True")) (arm (PTuple (PCon "RawStringAfterDot") (PCon "RawStringAfterDot")) () (EVar "True")) (arm (PTuple (PCon "HsCase") (PCon "HsCase")) () (EVar "True")) (arm (PTuple (PCon "MatchWith") (PCon "MatchWith")) () (EVar "True")) (arm (PTuple (PCon "NoPow") (PCon "NoPow")) () (EVar "True")) (arm (PTuple (PCon "HsSignature") (PCon "HsSignature")) () (EVar "True")) (arm (PTuple (PCon "BlockComment") (PCon "BlockComment")) () (EVar "True")) (arm (PTuple (PCon "BraceBlock") (PCon "BraceBlock")) () (EVar "True")) (arm (PTuple (PCon "Semicolon") (PCon "Semicolon")) () (EVar "True")) (arm (PTuple (PCon "MatchGuardBar") (PCon "MatchGuardBar")) () (EVar "True")) (arm (PTuple (PCon "MatchGuardBarWrapped") (PCon "MatchGuardBarWrapped")) () (EVar "True")) (arm (PTuple (PCon "ExpectedMatchArm") (PCon "ExpectedMatchArm")) () (EVar "True")) (arm (PTuple (PCon "ExpectedMatchArrow") (PCon "ExpectedMatchArrow")) () (EVar "True")) (arm (PTuple (PCon "MatchContinuationHint") (PCon "MatchContinuationHint")) () (EVar "True")) (arm (PTuple (PCon "EquationGuardIf") (PCon "EquationGuardIf")) () (EVar "True")) (arm (PTuple (PCon "GenericParse" (PVar "__a0")) (PCon "GenericParse" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "InvalidEscape" (PVar "__a0") (PVar "__a1")) (PCon "InvalidEscape" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "BadUnicodeEscape" (PVar "__a0")) (PCon "BadUnicodeEscape" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "BareUnicodeEscape" (PVar "__a0") (PVar "__a1")) (PCon "BareUnicodeEscape" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "LongChar" (PVar "__a0")) (PCon "LongChar" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "NonAsciiByte" (PVar "__a0") (PVar "__a1")) (PCon "NonAsciiByte" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "BadByteLiteral" (PVar "__a0")) (PCon "BadByteLiteral" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "ByteLikeIdent" (PVar "__a0") (PVar "__a1")) (PCon "ByteLikeIdent" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "UnexpectedCharacter" (PVar "__a0")) (PCon "UnexpectedCharacter" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "WidePattern" (PVar "__a0")) (PCon "WidePattern" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "MalformedRadix" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "MalformedRadix" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "MalformedFloat" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "MalformedFloat" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "ForeignKeyword" (PVar "__a0")) (PCon "ForeignKeyword" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "MissingWhere" (PVar "__a0")) (PCon "MissingWhere" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "WhereSameLine" (PVar "__a0")) (PCon "WhereSameLine" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "BlockEndsBinding" (PVar "__a0")) (PCon "BlockEndsBinding" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "ReservedKeyword" (PVar "__a0")) (PCon "ReservedKeyword" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "PublicDataOnly" (PVar "__a0")) (PCon "PublicDataOnly" (PVar "__b0"))) () (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DTypeSig true "diagnosticCode" (TyFun (TyCon "ParseDiagnostic") (TyCon "DiagCode")))
(DFunDef false "diagnosticCode" ((PCon "ParseDiagnostic" (PVar "kind") PWild PWild)) (EApp (EVar "problemCode") (EVar "kind")))
(DTypeSig false "problemCode" (TyFun (TyCon "ParseDiagnosticKind") (TyCon "DiagCode")))
(DFunDef false "problemCode" ((PCon "NestedInterpolation")) (EVar "LNestedInterpolation"))
(DFunDef false "problemCode" ((PCon "UnterminatedString")) (EVar "LUnterminatedString"))
(DFunDef false "problemCode" ((PCon "UnterminatedComment")) (EVar "LUnterminatedComment"))
(DFunDef false "problemCode" ((PCon "UnterminatedChar")) (EVar "LBadCharLiteral"))
(DFunDef false "problemCode" ((PCon "EmptyChar")) (EVar "LBadCharLiteral"))
(DFunDef false "problemCode" ((PCon "IntegerOverflow")) (EVar "LIntOverflow"))
(DFunDef false "problemCode" ((PCon "PositiveIntOverflow")) (EVar "LIntOverflow"))
(DFunDef false "problemCode" ((PCon "FloatOverflow")) (EVar "LFloatOverflow"))
(DFunDef false "problemCode" ((PCon "HsLambda")) (EVar "LHsLambda"))
(DFunDef false "problemCode" ((PCon "HsDollar")) (EVar "LHsDollar"))
(DFunDef false "problemCode" ((PCon "UnexpectedEnd")) (EVar "PUnexpectedEof"))
(DFunDef false "problemCode" ((PCon "UnexpectedEndExpected" PWild)) (EVar "PUnexpectedEof"))
(DFunDef false "problemCode" ((PCon "BadNeq")) (EVar "PBadNeq"))
(DFunDef false "problemCode" ((PCon "RawStringAfterDot")) (EVar "PRawStringAfterDot"))
(DFunDef false "problemCode" ((PCon "HsCase")) (EVar "PHsCase"))
(DFunDef false "problemCode" ((PCon "MatchWith")) (EVar "POcamlMatchWith"))
(DFunDef false "problemCode" ((PCon "NoPow")) (EVar "PNoPowOperator"))
(DFunDef false "problemCode" ((PCon "HsSignature")) (EVar "PHsSig"))
(DFunDef false "problemCode" ((PCon "BlockComment")) (EVar "LBlockcomment"))
(DFunDef false "problemCode" ((PCon "BraceBlock")) (EVar "PBraceBlock"))
(DFunDef false "problemCode" ((PCon "Semicolon")) (EVar "LSemicolon"))
(DFunDef false "problemCode" ((PCon "MatchGuardBar")) (EVar "PGuardBarInMatch"))
(DFunDef false "problemCode" ((PCon "MatchGuardBarWrapped")) (EVar "PGuardBarInMatch"))
(DFunDef false "problemCode" ((PCon "ExpectedMatchArm")) (EVar "PParse"))
(DFunDef false "problemCode" ((PCon "ExpectedMatchArrow")) (EVar "PParse"))
(DFunDef false "problemCode" ((PCon "MatchContinuationHint")) (EVar "PParse"))
(DFunDef false "problemCode" ((PCon "EquationGuardIf")) (EVar "PGuardIfInEquation"))
(DFunDef false "problemCode" ((PCon "GenericParse" PWild)) (EVar "PParse"))
(DFunDef false "problemCode" ((PCon "InvalidEscape" PWild PWild)) (EVar "LBadEscape"))
(DFunDef false "problemCode" ((PCon "BadUnicodeEscape" PWild)) (EVar "LBadUnicodeEscape"))
(DFunDef false "problemCode" ((PCon "BareUnicodeEscape" PWild PWild)) (EVar "LBareUnicodeEscape"))
(DFunDef false "problemCode" ((PCon "LongChar" PWild)) (EVar "LBadCharLiteral"))
(DFunDef false "problemCode" ((PCon "UnexpectedCharacter" PWild)) (EVar "LBadChar"))
(DFunDef false "problemCode" ((PCon "NonAsciiByte" PWild PWild)) (EVar "LByteNonAscii"))
(DFunDef false "problemCode" ((PCon "BadByteLiteral" PWild)) (EVar "LBadByteLiteral"))
(DFunDef false "problemCode" ((PCon "ByteLikeIdent" PWild PWild)) (EVar "LByteLiteralIdent"))
(DFunDef false "problemCode" ((PCon "WidePattern" PWild)) (EVar "LIntOverflow"))
(DFunDef false "problemCode" ((PCon "MalformedRadix" PWild PWild PWild)) (EVar "LMalformedRadix"))
(DFunDef false "problemCode" ((PCon "MalformedFloat" PWild PWild PWild)) (EVar "LMalformedFloat"))
(DFunDef false "problemCode" ((PCon "MissingWhere" PWild)) (EVar "PMissingWhere"))
(DFunDef false "problemCode" ((PCon "WhereSameLine" PWild)) (EVar "PWhereBodySameLine"))
(DFunDef false "problemCode" ((PCon "BlockEndsBinding" PWild)) (EVar "PDoEndsInBinding"))
(DFunDef false "problemCode" ((PCon "ReservedKeyword" PWild)) (EVar "PReservedKeyword"))
(DFunDef false "problemCode" ((PCon "PublicDataOnly" PWild)) (EVar "PParse"))
(DFunDef false "problemCode" ((PCon "ForeignKeyword" (PVar "word"))) (EIf (EBinOp "==" (EVar "word") (ELit (LString "def"))) (EVar "PDefKeyword") (EIf (EBinOp "||" (EBinOp "==" (EVar "word") (ELit (LString "for"))) (EBinOp "==" (EVar "word") (ELit (LString "while")))) (EVar "PForWhile") (EIf (EVar "otherwise") (EVar "PParse") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "diagnosticLoc" (TyFun (TyCon "ParseDiagnostic") (TyCon "Loc")))
(DFunDef false "diagnosticLoc" ((PCon "ParseDiagnostic" PWild (PVar "loc") PWild)) (EVar "loc"))
(DTypeSig true "diagnosticEdits" (TyFun (TyCon "ParseDiagnostic") (TyApp (TyCon "List") (TyCon "ParseEdit"))))
(DFunDef false "diagnosticEdits" ((PCon "ParseDiagnostic" PWild PWild (PVar "edits"))) (EVar "edits"))
(DTypeSig true "renderParseDiagnostic" (TyFun (TyCon "ParseDiagnostic") (TyCon "String")))
(DFunDef false "renderParseDiagnostic" ((PCon "ParseDiagnostic" (PVar "kind") PWild PWild)) (EApp (EVar "renderParseProblem") (EVar "kind")))
(DTypeSig true "renderParseProblem" (TyFun (TyCon "ParseDiagnosticKind") (TyCon "String")))
(DFunDef false "renderParseProblem" ((PCon "NestedInterpolation")) (ELit (LString "nested string interpolation is not supported")))
(DFunDef false "renderParseProblem" ((PCon "UnterminatedString")) (ELit (LString "unterminated string literal")))
(DFunDef false "renderParseProblem" ((PCon "UnterminatedComment")) (ELit (LString "unterminated block comment")))
(DFunDef false "renderParseProblem" ((PCon "UnterminatedChar")) (ELit (LString "unterminated character literal")))
(DFunDef false "renderParseProblem" ((PCon "EmptyChar")) (ELit (LString "character literal is empty; a character is exactly one codepoint, such as `'a'`")))
(DFunDef false "renderParseProblem" ((PCon "IntegerOverflow")) (ELit (LString "integer literal too large for U64 (max 2^64 - 1)")))
(DFunDef false "renderParseProblem" ((PCon "PositiveIntOverflow")) (ELit (LString "integer literal too large for Int (max 4611686018427387903)")))
(DFunDef false "renderParseProblem" ((PCon "FloatOverflow")) (ELit (LString "float literal out of range (overflows to infinity)")))
(DFunDef false "renderParseProblem" ((PCon "HsLambda")) (ELit (LString "Medaka has no `\\x -> e` lambdas; write `x => e`")))
(DFunDef false "renderParseProblem" ((PCon "HsDollar")) (ELit (LString "Medaka has no `$`; write `f (g x)`")))
(DFunDef false "renderParseProblem" ((PCon "UnexpectedEnd")) (ELit (LString "unexpected end of input")))
(DFunDef false "renderParseProblem" ((PCon "BadNeq")) (ELit (LString "unexpected `!=`; did you mean `/=`?")))
(DFunDef false "renderParseProblem" ((PCon "RawStringAfterDot")) (ELit (LString "`.r\"` reads as a raw string literal, not the field `r`; put a space after the `r`, as in `p.r \"x\"`, or parenthesise the field access, as in `(p.r) \"x\"`")))
(DFunDef false "renderParseProblem" ((PCon "HsCase")) (ELit (LString "Medaka has no `case ... of`; write `match e` with indented `pattern => body` arms")))
(DFunDef false "renderParseProblem" ((PCon "MatchWith")) (ELit (LString "Medaka has no `match ... with`; write `match e` with indented `pattern => body` arms")))
(DFunDef false "renderParseProblem" ((PCon "NoPow")) (ELit (LString "Medaka has no `**`; write `pow x y`")))
(DFunDef false "renderParseProblem" ((PCon "HsSignature")) (ELit (LString "`::` is the list cons operator; write `f : T` for a type signature")))
(DFunDef false "renderParseProblem" ((PCon "BlockComment")) (ELit (LString "Medaka has no `/* ... */` comments; write `{- ... -}` or `--`")))
(DFunDef false "renderParseProblem" ((PCon "BraceBlock")) (ELit (LString "Medaka has no `{ ... }` blocks; indent the body after `then` and `else`")))
(DFunDef false "renderParseProblem" ((PCon "Semicolon")) (ELit (LString "Medaka has no statement terminator `;`; write each statement on its own line")))
(DFunDef false "renderParseProblem" ((PCon "MatchGuardBar")) (ELit (LString "a match-arm guard uses `if`, not `|`; write `pat if cond => body`")))
(DFunDef false "renderParseProblem" ((PCon "MatchGuardBarWrapped")) (ELit (LString "a `|` ending a line cannot continue an or-pattern; wrap the alternatives in parentheses, `(A | B | C) => body`, or write them on one line")))
(DFunDef false "renderParseProblem" ((PCon "ExpectedMatchArm")) (ELit (LString "expected a match arm (`pattern => body`)")))
(DFunDef false "renderParseProblem" ((PCon "ExpectedMatchArrow")) (ELit (LString "expected `=>` after the match pattern or guard")))
(DFunDef false "renderParseProblem" ((PCon "MatchContinuationHint")) (ELit (LString "expected a match arm (`pattern => body`); if this line continues the scrutinee, wrap the whole scrutinee in parentheses")))
(DFunDef false "renderParseProblem" ((PCon "EquationGuardIf")) (ELit (LString "an equation guard uses `|`, not `if`; write `| cond = body`")))
(DFunDef false "renderParseProblem" ((PCon "UnexpectedEndExpected" (PVar "expected"))) (EBinOp "++" (EBinOp "++" (ELit (LString "unexpected end of input; expected ")) (EApp (EVar "display") (EVar "expected"))) (ELit (LString ""))))
(DFunDef false "renderParseProblem" ((PCon "GenericParse" (PVar "msg"))) (EVar "msg"))
(DFunDef false "renderParseProblem" ((PCon "InvalidEscape" (PVar "spelling") (PVar "inChar"))) (EBlock (DoLet false false (PVar "quote") (EIf (EVar "inChar") (ELit (LString "\\'")) (ELit (LString "\\\"")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "invalid escape sequence `")) (EApp (EVar "display") (EVar "spelling"))) (ELit (LString "`; valid escapes are \\n \\t \\r \\0 \\\\ "))) (EApp (EVar "display") (EVar "quote"))) (ELit (LString " \\u{...}"))))))
(DFunDef false "renderParseProblem" ((PCon "BadUnicodeEscape" (PVar "problem"))) (EApp (EVar "renderUnicodeProblem") (EVar "problem")))
(DFunDef false "renderParseProblem" ((PCon "BareUnicodeEscape" (PVar "old") (PVar "new"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "bare unicode escape `")) (EApp (EVar "display") (EVar "old"))) (ELit (LString "` is not valid; did you mean `"))) (EApp (EVar "display") (EVar "new"))) (ELit (LString "`?"))))
(DFunDef false "renderParseProblem" ((PCon "LongChar" (PVar "text"))) (EBinOp "++" (EBinOp "++" (ELit (LString "character literal `'")) (EApp (EVar "display") (EVar "text"))) (ELit (LString "'` has more than one codepoint; write a `\"...\"` string for text"))))
(DFunDef false "renderParseProblem" ((PCon "NonAsciiByte" (PVar "ch") (PVar "fixIt"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "byte literal `b'")) (EApp (EVar "display") (EVar "ch"))) (ELit (LString "'` is not ASCII; a byte literal holds one byte, so write its UTF-8 bytes as "))) (EApp (EVar "display") (EVar "fixIt"))) (ELit (LString ""))))
(DFunDef false "renderParseProblem" ((PCon "BadByteLiteral" (PVar "msg"))) (EVar "msg"))
(DFunDef false "renderParseProblem" ((PCon "ByteLikeIdent" (PVar "old") (PVar "new"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "old"))) (ELit (LString "` is a byte literal, not an identifier; rename it, for example `"))) (EApp (EVar "display") (EVar "new"))) (ELit (LString "`"))))
(DFunDef false "renderParseProblem" ((PCon "UnexpectedCharacter" (PVar "text"))) (EBinOp "++" (EBinOp "++" (ELit (LString "unexpected character `")) (EApp (EVar "display") (EVar "text"))) (ELit (LString "`"))))
(DFunDef false "renderParseProblem" ((PCon "WidePattern" (PVar "lx"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "integer literal too large for a pattern: `")) (EApp (EVar "display") (EVar "lx"))) (ELit (LString "` exceeds Int; match it in a guard instead, `x if x == "))) (EApp (EVar "display") (EVar "lx"))) (ELit (LString "`"))))
(DFunDef false "renderParseProblem" ((PCon "MalformedRadix" (PVar "bad") (PVar "prefix") (PVar "digits"))) (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "digits")) (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "malformed radix literal `")) (EApp (EVar "display") (EVar "bad"))) (ELit (LString "`: no digits follow the "))) (EApp (EVar "display") (EVar "prefix"))) (ELit (LString " prefix; an underscore may only separate digits"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "malformed radix literal `")) (EApp (EVar "display") (EVar "bad"))) (ELit (LString "`: an underscore cannot follow the "))) (EApp (EVar "display") (EVar "prefix"))) (ELit (LString " prefix; write `"))) (EApp (EVar "display") (EVar "prefix"))) (ELit (LString ""))) (EApp (EVar "display") (EVar "digits"))) (ELit (LString "`"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "renderParseProblem" ((PCon "MalformedFloat" (PVar "bad") (PVar "good") (PVar "leading"))) (EBlock (DoLet false false (PVar "side") (EIf (EVar "leading") (ELit (LString "precede")) (ELit (LString "follow")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "malformed float literal `")) (EApp (EVar "display") (EVar "bad"))) (ELit (LString "`: a digit must "))) (EApp (EVar "display") (EVar "side"))) (ELit (LString " the decimal point; write `"))) (EApp (EVar "display") (EVar "good"))) (ELit (LString "`"))))))
(DFunDef false "renderParseProblem" ((PCon "ForeignKeyword" (PVar "word"))) (EApp (EVar "foreignKeywordMessage") (EVar "word")))
(DFunDef false "renderParseProblem" ((PCon "MissingWhere" (PVar "header"))) (EBlock (DoLet false false (PVar "members") (EIf (EBinOp "==" (EVar "header") (ELit (LString "impl"))) (ELit (LString "methods")) (ELit (LString "members")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "missing `where` on this `")) (EApp (EVar "display") (EVar "header"))) (ELit (LString "` header; end the header with `where` and indent the "))) (EApp (EVar "display") (EVar "members"))) (ELit (LString " below it"))))))
(DFunDef false "renderParseProblem" ((PCon "WhereSameLine" (PVar "header"))) (EBlock (DoLet false false (PVar "member") (EIf (EBinOp "==" (EVar "header") (ELit (LString "impl"))) (ELit (LString "method")) (ELit (LString "member")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "a `where` block must start on the next line; move this ")) (EApp (EVar "display") (EVar "member"))) (ELit (LString " onto its own line, indented below the `"))) (EApp (EVar "display") (EVar "header"))) (ELit (LString "` header"))))))
(DFunDef false "renderParseProblem" ((PCon "BlockEndsBinding" (PVar "word"))) (EBinOp "++" (EBinOp "++" (ELit (LString "a `")) (EApp (EVar "display") (EVar "word"))) (ELit (LString "` block must end in an expression, not a binding; add the expression whose value the block should have"))))
(DFunDef false "renderParseProblem" ((PCon "ReservedKeyword" (PVar "name"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` is a reserved keyword and cannot name a variable or pattern; rename it to `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "_`"))))
(DFunDef false "renderParseProblem" ((PCon "PublicDataOnly" (PCon "True"))) (ELit (LString "`public` applies only to `data` declarations with constructors; write `export extern`")))
(DFunDef false "renderParseProblem" ((PCon "PublicDataOnly" (PCon "False"))) (ELit (LString "`public` applies only to `data` declarations; write plain `export`")))
(DTypeSig false "foreignKeywordMessage" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "foreignKeywordMessage" ((PLit (LString "def"))) (ELit (LString "Medaka has no `def`; write `f x = ...`")))
(DFunDef false "foreignKeywordMessage" ((PLit (LString "while"))) (ELit (LString "Medaka has no `while`; write a recursive function")))
(DFunDef false "foreignKeywordMessage" ((PLit (LString "elif"))) (ELit (LString "Medaka has no `elif`; write `else if`")))
(DFunDef false "foreignKeywordMessage" ((PLit (LString "class"))) (ELit (LString "Medaka has no `class`; write a `data` type or an `interface`")))
(DFunDef false "foreignKeywordMessage" ((PLit (LString "try"))) (ELit (LString "Medaka has no `try`; return errors as `Result` values")))
(DFunDef false "foreignKeywordMessage" ((PLit (LString "except"))) (ELit (LString "Medaka has no `except`; return errors as `Result` values")))
(DFunDef false "foreignKeywordMessage" ((PLit (LString "finally"))) (ELit (LString "Medaka has no `finally`; return errors as `Result` values")))
(DFunDef false "foreignKeywordMessage" (PWild) (ELit (LString "Medaka has no `for` loops; use `map` or `fold` over the list")))
(DTypeSig false "renderUnicodeProblem" (TyFun (TyCon "UnicodeProblem") (TyCon "String")))
(DFunDef false "renderUnicodeProblem" ((PCon "UnicodeUnterminated")) (ELit (LString "unicode escape is not terminated; the file ends before its closing `}`")))
(DFunDef false "renderUnicodeProblem" ((PCon "UnicodeSeparator")) (ELit (LString "unicode escape cannot contain `_`; write the hex digits unbroken, as in `\\u{41}`")))
(DFunDef false "renderUnicodeProblem" ((PCon "UnicodeEmpty")) (ELit (LString "unicode escape `\\u{}` has no digits; write at least one hex digit, as in `\\u{41}`")))
(DFunDef false "renderUnicodeProblem" ((PCon "UnicodeExpectedDigit" (PVar "found"))) (EBinOp "++" (EBinOp "++" (ELit (LString "unicode escape expects a hex digit after `\\u{` but found `")) (EApp (EVar "display") (EVar "found"))) (ELit (LString "`"))))
(DFunDef false "renderUnicodeProblem" ((PCon "UnicodeExpectedClose" (PVar "found"))) (EBinOp "++" (EBinOp "++" (ELit (LString "unicode escape expects `}` after its hex digits but found `")) (EApp (EVar "display") (EVar "found"))) (ELit (LString "`"))))
(DFunDef false "renderUnicodeProblem" ((PCon "UnicodeSurrogate" (PVar "text"))) (EBinOp "++" (EBinOp "++" (ELit (LString "unicode escape `")) (EApp (EVar "display") (EVar "text"))) (ELit (LString "` is a UTF-16 surrogate, not a character; codepoints D800-DFFF are not valid on their own"))))
(DFunDef false "renderUnicodeProblem" ((PCon "UnicodeOutOfRange" (PVar "text"))) (EBinOp "++" (EBinOp "++" (ELit (LString "unicode escape `")) (EApp (EVar "display") (EVar "text"))) (ELit (LString "` is out of range; a codepoint is at most 10FFFF"))))
(DTypeSig true "diagnosticHelp" (TyFun (TyCon "ParseDiagnostic") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "diagnosticHelp" ((PCon "ParseDiagnostic" (PVar "kind") PWild PWild)) (EApp (EVar "problemHelp") (EVar "kind")))
(DTypeSig false "problemHelp" (TyFun (TyCon "ParseDiagnosticKind") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "problemHelp" ((PCon "HsSignature")) (EApp (EVar "Some") (ELit (LString "replace `::` with `:`"))))
(DFunDef false "problemHelp" ((PCon "BadNeq")) (EApp (EVar "Some") (ELit (LString "replace `!=` with `/=`"))))
(DFunDef false "problemHelp" ((PCon "RawStringAfterDot")) (EApp (EVar "Some") (ELit (LString "insert a space between the `r` and the opening quote"))))
(DFunDef false "problemHelp" ((PCon "PositiveIntOverflow")) (EApp (EVar "Some") (ELit (LString "`Int` is 63-bit, spanning [-4611686018427387904, 4611686018427387903]; 4611686018427387904 fits only as the negative -4611686018427387904, so write it with its `-`"))))
(DFunDef false "problemHelp" ((PCon "NonAsciiByte" PWild (PVar "fixIt"))) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "write the character as its UTF-8 bytes, ")) (EApp (EVar "display") (EVar "fixIt"))) (ELit (LString "")))))
(DFunDef false "problemHelp" ((PCon "ByteLikeIdent" PWild (PVar "new"))) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "rename every occurrence of the identifier, for example to `")) (EApp (EVar "display") (EVar "new"))) (ELit (LString "`")))))
(DFunDef false "problemHelp" ((PCon "BareUnicodeEscape" PWild PWild)) (EApp (EVar "Some") (ELit (LString "write the unicode escape braced, `\\u{XXXX}`"))))
(DFunDef false "problemHelp" ((PCon "MalformedRadix" PWild PWild PWild)) (EApp (EVar "Some") (ELit (LString "the digit separator `_` may only appear between digits"))))
(DFunDef false "problemHelp" ((PCon "MalformedFloat" PWild PWild PWild)) (EApp (EVar "Some") (ELit (LString "a float literal needs a digit on both sides of the decimal point"))))
(DFunDef false "problemHelp" ((PCon "ReservedKeyword" (PVar "w"))) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "rename it to `")) (EApp (EVar "display") (EVar "w"))) (ELit (LString "_`; any reserved word plus `_` is a valid identifier")))))
(DFunDef false "problemHelp" ((PCon "PublicDataOnly" PWild)) (EApp (EVar "Some") (ELit (LString "drop `public`; a function or value is exported with plain `export`"))))
(DFunDef false "problemHelp" ((PCon "MissingWhere" PWild)) (EApp (EVar "Some") (ELit (LString "end the header with `where`; without it the next line is read as another type argument"))))
(DFunDef false "problemHelp" ((PCon "BlockEndsBinding" PWild)) (EApp (EVar "Some") (ELit (LString "end the block with the expression whose value it should have, such as `pure x`"))))
(DFunDef false "problemHelp" ((PCon "WhereSameLine" PWild)) (EApp (EVar "Some") (ELit (LString "`where` opens a block only when it ends the line; move the member to the next line"))))
(DFunDef false "problemHelp" ((PCon "MatchGuardBar")) (EApp (EVar "Some") (ELit (LString "replace `|` with `if`"))))
(DFunDef false "problemHelp" ((PCon "EquationGuardIf")) (EApp (EVar "Some") (ELit (LString "replace `if` with `|`"))))
(DFunDef false "problemHelp" (PWild) (EVar "None"))
(DTypeSig true "locateParseProblem" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "ParseDiagnosticKind") (TyCon "ParseDiagnostic"))))))
(DFunDef false "locateParseProblem" ((PVar "index") (PVar "start") (PVar "end") (PVar "kind")) (EBlock (DoLet false false (PTuple (PVar "sl") (PVar "sc")) (EApp (EApp (EVar "optionOr") (ETuple (ELit (LInt 1)) (ELit (LInt 0)))) (EApp (EApp (EVar "offsetToSourcePosition") (EVar "index")) (EVar "start")))) (DoLet false false (PTuple (PVar "el") (PVar "ec")) (EApp (EApp (EVar "optionOr") (ETuple (EVar "sl") (EVar "sc"))) (EApp (EApp (EVar "offsetToSourcePosition") (EVar "index")) (EVar "end")))) (DoLet false false (PVar "loc") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec"))) (DoExpr (EApp (EApp (EVar "makeParseDiagnostic") (EVar "kind")) (EVar "loc")))))
(DTypeSig false "replacementEdit" (TyFun (TyCon "Loc") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ParseEdit"))))))
(DFunDef false "replacementEdit" ((PVar "loc") (PVar "old") (PVar "new")) (EListLit (EApp (EApp (EApp (EApp (EVar "ParseEdit") (EVar "loc")) (EVar "old")) (EVar "new")) (EVar "MachineApplicable"))))
(DTypeSig false "problemEdits" (TyFun (TyCon "ParseDiagnosticKind") (TyFun (TyCon "Loc") (TyApp (TyCon "List") (TyCon "ParseEdit")))))
(DFunDef false "problemEdits" ((PCon "BadNeq") (PVar "loc")) (EApp (EApp (EApp (EVar "replacementEdit") (EVar "loc")) (ELit (LString "!="))) (ELit (LString "/="))))
(DFunDef false "problemEdits" ((PCon "RawStringAfterDot") (PCon "Loc" (PVar "file") (PVar "sl") (PVar "sc") PWild PWild)) (EApp (EApp (EApp (EVar "replacementEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (EVar "sl")) (EVar "sc")) (EVar "sl")) (EBinOp "+" (EVar "sc") (ELit (LInt 2))))) (ELit (LString "r\""))) (ELit (LString "r \""))))
(DFunDef false "problemEdits" ((PCon "HsSignature") (PVar "loc")) (EApp (EApp (EApp (EVar "replacementEdit") (EVar "loc")) (ELit (LString "::"))) (ELit (LString ":"))))
(DFunDef false "problemEdits" ((PCon "BareUnicodeEscape" (PVar "old") (PVar "new")) (PVar "loc")) (EApp (EApp (EApp (EVar "replacementEdit") (EVar "loc")) (EVar "old")) (EVar "new")))
(DFunDef false "problemEdits" ((PCon "MalformedRadix" (PVar "bad") (PVar "prefix") (PVar "digits")) (PVar "loc")) (EIf (EBinOp "==" (EVar "digits") (ELit (LString ""))) (EListLit) (EApp (EApp (EApp (EVar "replacementEdit") (EVar "loc")) (EVar "bad")) (EBinOp "++" (EVar "prefix") (EVar "digits")))))
(DFunDef false "problemEdits" ((PCon "MalformedFloat" (PVar "bad") (PVar "good") PWild) (PVar "loc")) (EApp (EApp (EApp (EVar "replacementEdit") (EVar "loc")) (EVar "bad")) (EVar "good")))
(DFunDef false "problemEdits" ((PCon "ReservedKeyword" (PVar "name")) (PVar "loc")) (EApp (EApp (EApp (EVar "replacementEdit") (EVar "loc")) (EVar "name")) (EBinOp "++" (EVar "name") (ELit (LString "_")))))
(DFunDef false "problemEdits" ((PCon "PublicDataOnly" PWild) (PVar "loc")) (EApp (EApp (EApp (EVar "replacementEdit") (EVar "loc")) (ELit (LString "public"))) (ELit (LString ""))))
(DFunDef false "problemEdits" ((PCon "MatchGuardBar") (PVar "loc")) (EApp (EApp (EApp (EVar "replacementEdit") (EVar "loc")) (ELit (LString "|"))) (ELit (LString "if"))))
(DFunDef false "problemEdits" ((PCon "EquationGuardIf") (PVar "loc")) (EApp (EApp (EApp (EVar "replacementEdit") (EVar "loc")) (ELit (LString "if"))) (ELit (LString "|"))))
(DFunDef false "problemEdits" (PWild PWild) (EListLit))
(DTypeSig true "makeParseDiagnostic" (TyFun (TyCon "ParseDiagnosticKind") (TyFun (TyCon "Loc") (TyCon "ParseDiagnostic"))))
(DFunDef false "makeParseDiagnostic" ((PVar "kind") (PVar "loc")) (EApp (EApp (EApp (EVar "ParseDiagnostic") (EVar "kind")) (EVar "loc")) (EApp (EApp (EVar "problemEdits") (EVar "kind")) (EVar "loc"))))
# MARK
(DUse false (UseGroup ("support" "diag_codes") ((mem "DiagCode" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true))))
(DUse false (UseGroup ("support" "source_index") ((mem "SourceIndex" false) (mem "offsetToSourcePosition" false))))
(DData Public "EditApplicability" () ((variant "MachineApplicable" (ConPos)) (variant "HumanOnly" (ConPos))) ())
(DImpl true "Eq" ((TyCon "EditApplicability")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "MachineApplicable") (PCon "MachineApplicable")) () (EVar "True")) (arm (PTuple (PCon "HumanOnly") (PCon "HumanOnly")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "ParseEdit" () ((variant "ParseEdit" (ConPos (TyCon "Loc") (TyCon "String") (TyCon "String") (TyCon "EditApplicability")))) ())
(DData Public "ParseDiagnostic" () ((variant "ParseDiagnostic" (ConPos (TyCon "ParseDiagnosticKind") (TyCon "Loc") (TyApp (TyCon "List") (TyCon "ParseEdit"))))) ())
(DData Public "UnicodeProblem" () ((variant "UnicodeUnterminated" (ConPos)) (variant "UnicodeSeparator" (ConPos)) (variant "UnicodeEmpty" (ConPos)) (variant "UnicodeExpectedDigit" (ConPos (TyCon "String"))) (variant "UnicodeExpectedClose" (ConPos (TyCon "String"))) (variant "UnicodeSurrogate" (ConPos (TyCon "String"))) (variant "UnicodeOutOfRange" (ConPos (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "UnicodeProblem")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "UnicodeUnterminated") (PCon "UnicodeUnterminated")) () (EVar "True")) (arm (PTuple (PCon "UnicodeSeparator") (PCon "UnicodeSeparator")) () (EVar "True")) (arm (PTuple (PCon "UnicodeEmpty") (PCon "UnicodeEmpty")) () (EVar "True")) (arm (PTuple (PCon "UnicodeExpectedDigit" (PVar "__a0")) (PCon "UnicodeExpectedDigit" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "UnicodeExpectedClose" (PVar "__a0")) (PCon "UnicodeExpectedClose" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "UnicodeSurrogate" (PVar "__a0")) (PCon "UnicodeSurrogate" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "UnicodeOutOfRange" (PVar "__a0")) (PCon "UnicodeOutOfRange" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "ParseDiagnosticKind" () ((variant "NestedInterpolation" (ConPos)) (variant "UnterminatedString" (ConPos)) (variant "UnterminatedComment" (ConPos)) (variant "UnterminatedChar" (ConPos)) (variant "EmptyChar" (ConPos)) (variant "IntegerOverflow" (ConPos)) (variant "PositiveIntOverflow" (ConPos)) (variant "FloatOverflow" (ConPos)) (variant "HsLambda" (ConPos)) (variant "HsDollar" (ConPos)) (variant "UnexpectedEnd" (ConPos)) (variant "UnexpectedEndExpected" (ConPos (TyCon "String"))) (variant "BadNeq" (ConPos)) (variant "RawStringAfterDot" (ConPos)) (variant "HsCase" (ConPos)) (variant "MatchWith" (ConPos)) (variant "NoPow" (ConPos)) (variant "HsSignature" (ConPos)) (variant "BlockComment" (ConPos)) (variant "BraceBlock" (ConPos)) (variant "Semicolon" (ConPos)) (variant "MatchGuardBar" (ConPos)) (variant "MatchGuardBarWrapped" (ConPos)) (variant "ExpectedMatchArm" (ConPos)) (variant "ExpectedMatchArrow" (ConPos)) (variant "MatchContinuationHint" (ConPos)) (variant "EquationGuardIf" (ConPos)) (variant "GenericParse" (ConPos (TyCon "String"))) (variant "InvalidEscape" (ConPos (TyCon "String") (TyCon "Bool"))) (variant "BadUnicodeEscape" (ConPos (TyCon "UnicodeProblem"))) (variant "BareUnicodeEscape" (ConPos (TyCon "String") (TyCon "String"))) (variant "LongChar" (ConPos (TyCon "String"))) (variant "NonAsciiByte" (ConPos (TyCon "String") (TyCon "String"))) (variant "BadByteLiteral" (ConPos (TyCon "String"))) (variant "ByteLikeIdent" (ConPos (TyCon "String") (TyCon "String"))) (variant "UnexpectedCharacter" (ConPos (TyCon "String"))) (variant "WidePattern" (ConPos (TyCon "String"))) (variant "MalformedRadix" (ConPos (TyCon "String") (TyCon "String") (TyCon "String"))) (variant "MalformedFloat" (ConPos (TyCon "String") (TyCon "String") (TyCon "Bool"))) (variant "ForeignKeyword" (ConPos (TyCon "String"))) (variant "MissingWhere" (ConPos (TyCon "String"))) (variant "WhereSameLine" (ConPos (TyCon "String"))) (variant "BlockEndsBinding" (ConPos (TyCon "String"))) (variant "ReservedKeyword" (ConPos (TyCon "String"))) (variant "PublicDataOnly" (ConPos (TyCon "Bool")))) ())
(DImpl true "Eq" ((TyCon "ParseDiagnosticKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "NestedInterpolation") (PCon "NestedInterpolation")) () (EVar "True")) (arm (PTuple (PCon "UnterminatedString") (PCon "UnterminatedString")) () (EVar "True")) (arm (PTuple (PCon "UnterminatedComment") (PCon "UnterminatedComment")) () (EVar "True")) (arm (PTuple (PCon "UnterminatedChar") (PCon "UnterminatedChar")) () (EVar "True")) (arm (PTuple (PCon "EmptyChar") (PCon "EmptyChar")) () (EVar "True")) (arm (PTuple (PCon "IntegerOverflow") (PCon "IntegerOverflow")) () (EVar "True")) (arm (PTuple (PCon "PositiveIntOverflow") (PCon "PositiveIntOverflow")) () (EVar "True")) (arm (PTuple (PCon "FloatOverflow") (PCon "FloatOverflow")) () (EVar "True")) (arm (PTuple (PCon "HsLambda") (PCon "HsLambda")) () (EVar "True")) (arm (PTuple (PCon "HsDollar") (PCon "HsDollar")) () (EVar "True")) (arm (PTuple (PCon "UnexpectedEnd") (PCon "UnexpectedEnd")) () (EVar "True")) (arm (PTuple (PCon "UnexpectedEndExpected" (PVar "__a0")) (PCon "UnexpectedEndExpected" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "BadNeq") (PCon "BadNeq")) () (EVar "True")) (arm (PTuple (PCon "RawStringAfterDot") (PCon "RawStringAfterDot")) () (EVar "True")) (arm (PTuple (PCon "HsCase") (PCon "HsCase")) () (EVar "True")) (arm (PTuple (PCon "MatchWith") (PCon "MatchWith")) () (EVar "True")) (arm (PTuple (PCon "NoPow") (PCon "NoPow")) () (EVar "True")) (arm (PTuple (PCon "HsSignature") (PCon "HsSignature")) () (EVar "True")) (arm (PTuple (PCon "BlockComment") (PCon "BlockComment")) () (EVar "True")) (arm (PTuple (PCon "BraceBlock") (PCon "BraceBlock")) () (EVar "True")) (arm (PTuple (PCon "Semicolon") (PCon "Semicolon")) () (EVar "True")) (arm (PTuple (PCon "MatchGuardBar") (PCon "MatchGuardBar")) () (EVar "True")) (arm (PTuple (PCon "MatchGuardBarWrapped") (PCon "MatchGuardBarWrapped")) () (EVar "True")) (arm (PTuple (PCon "ExpectedMatchArm") (PCon "ExpectedMatchArm")) () (EVar "True")) (arm (PTuple (PCon "ExpectedMatchArrow") (PCon "ExpectedMatchArrow")) () (EVar "True")) (arm (PTuple (PCon "MatchContinuationHint") (PCon "MatchContinuationHint")) () (EVar "True")) (arm (PTuple (PCon "EquationGuardIf") (PCon "EquationGuardIf")) () (EVar "True")) (arm (PTuple (PCon "GenericParse" (PVar "__a0")) (PCon "GenericParse" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "InvalidEscape" (PVar "__a0") (PVar "__a1")) (PCon "InvalidEscape" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "BadUnicodeEscape" (PVar "__a0")) (PCon "BadUnicodeEscape" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "BareUnicodeEscape" (PVar "__a0") (PVar "__a1")) (PCon "BareUnicodeEscape" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "LongChar" (PVar "__a0")) (PCon "LongChar" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "NonAsciiByte" (PVar "__a0") (PVar "__a1")) (PCon "NonAsciiByte" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "BadByteLiteral" (PVar "__a0")) (PCon "BadByteLiteral" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "ByteLikeIdent" (PVar "__a0") (PVar "__a1")) (PCon "ByteLikeIdent" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "UnexpectedCharacter" (PVar "__a0")) (PCon "UnexpectedCharacter" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "WidePattern" (PVar "__a0")) (PCon "WidePattern" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "MalformedRadix" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "MalformedRadix" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "MalformedFloat" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "MalformedFloat" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple (PCon "ForeignKeyword" (PVar "__a0")) (PCon "ForeignKeyword" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "MissingWhere" (PVar "__a0")) (PCon "MissingWhere" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "WhereSameLine" (PVar "__a0")) (PCon "WhereSameLine" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "BlockEndsBinding" (PVar "__a0")) (PCon "BlockEndsBinding" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "ReservedKeyword" (PVar "__a0")) (PCon "ReservedKeyword" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple (PCon "PublicDataOnly" (PVar "__a0")) (PCon "PublicDataOnly" (PVar "__b0"))) () (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0"))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DTypeSig true "diagnosticCode" (TyFun (TyCon "ParseDiagnostic") (TyCon "DiagCode")))
(DFunDef false "diagnosticCode" ((PCon "ParseDiagnostic" (PVar "kind") PWild PWild)) (EApp (EVar "problemCode") (EVar "kind")))
(DTypeSig false "problemCode" (TyFun (TyCon "ParseDiagnosticKind") (TyCon "DiagCode")))
(DFunDef false "problemCode" ((PCon "NestedInterpolation")) (EVar "LNestedInterpolation"))
(DFunDef false "problemCode" ((PCon "UnterminatedString")) (EVar "LUnterminatedString"))
(DFunDef false "problemCode" ((PCon "UnterminatedComment")) (EVar "LUnterminatedComment"))
(DFunDef false "problemCode" ((PCon "UnterminatedChar")) (EVar "LBadCharLiteral"))
(DFunDef false "problemCode" ((PCon "EmptyChar")) (EVar "LBadCharLiteral"))
(DFunDef false "problemCode" ((PCon "IntegerOverflow")) (EVar "LIntOverflow"))
(DFunDef false "problemCode" ((PCon "PositiveIntOverflow")) (EVar "LIntOverflow"))
(DFunDef false "problemCode" ((PCon "FloatOverflow")) (EVar "LFloatOverflow"))
(DFunDef false "problemCode" ((PCon "HsLambda")) (EVar "LHsLambda"))
(DFunDef false "problemCode" ((PCon "HsDollar")) (EVar "LHsDollar"))
(DFunDef false "problemCode" ((PCon "UnexpectedEnd")) (EVar "PUnexpectedEof"))
(DFunDef false "problemCode" ((PCon "UnexpectedEndExpected" PWild)) (EVar "PUnexpectedEof"))
(DFunDef false "problemCode" ((PCon "BadNeq")) (EVar "PBadNeq"))
(DFunDef false "problemCode" ((PCon "RawStringAfterDot")) (EVar "PRawStringAfterDot"))
(DFunDef false "problemCode" ((PCon "HsCase")) (EVar "PHsCase"))
(DFunDef false "problemCode" ((PCon "MatchWith")) (EVar "POcamlMatchWith"))
(DFunDef false "problemCode" ((PCon "NoPow")) (EVar "PNoPowOperator"))
(DFunDef false "problemCode" ((PCon "HsSignature")) (EVar "PHsSig"))
(DFunDef false "problemCode" ((PCon "BlockComment")) (EVar "LBlockcomment"))
(DFunDef false "problemCode" ((PCon "BraceBlock")) (EVar "PBraceBlock"))
(DFunDef false "problemCode" ((PCon "Semicolon")) (EVar "LSemicolon"))
(DFunDef false "problemCode" ((PCon "MatchGuardBar")) (EVar "PGuardBarInMatch"))
(DFunDef false "problemCode" ((PCon "MatchGuardBarWrapped")) (EVar "PGuardBarInMatch"))
(DFunDef false "problemCode" ((PCon "ExpectedMatchArm")) (EVar "PParse"))
(DFunDef false "problemCode" ((PCon "ExpectedMatchArrow")) (EVar "PParse"))
(DFunDef false "problemCode" ((PCon "MatchContinuationHint")) (EVar "PParse"))
(DFunDef false "problemCode" ((PCon "EquationGuardIf")) (EVar "PGuardIfInEquation"))
(DFunDef false "problemCode" ((PCon "GenericParse" PWild)) (EVar "PParse"))
(DFunDef false "problemCode" ((PCon "InvalidEscape" PWild PWild)) (EVar "LBadEscape"))
(DFunDef false "problemCode" ((PCon "BadUnicodeEscape" PWild)) (EVar "LBadUnicodeEscape"))
(DFunDef false "problemCode" ((PCon "BareUnicodeEscape" PWild PWild)) (EVar "LBareUnicodeEscape"))
(DFunDef false "problemCode" ((PCon "LongChar" PWild)) (EVar "LBadCharLiteral"))
(DFunDef false "problemCode" ((PCon "UnexpectedCharacter" PWild)) (EVar "LBadChar"))
(DFunDef false "problemCode" ((PCon "NonAsciiByte" PWild PWild)) (EVar "LByteNonAscii"))
(DFunDef false "problemCode" ((PCon "BadByteLiteral" PWild)) (EVar "LBadByteLiteral"))
(DFunDef false "problemCode" ((PCon "ByteLikeIdent" PWild PWild)) (EVar "LByteLiteralIdent"))
(DFunDef false "problemCode" ((PCon "WidePattern" PWild)) (EVar "LIntOverflow"))
(DFunDef false "problemCode" ((PCon "MalformedRadix" PWild PWild PWild)) (EVar "LMalformedRadix"))
(DFunDef false "problemCode" ((PCon "MalformedFloat" PWild PWild PWild)) (EVar "LMalformedFloat"))
(DFunDef false "problemCode" ((PCon "MissingWhere" PWild)) (EVar "PMissingWhere"))
(DFunDef false "problemCode" ((PCon "WhereSameLine" PWild)) (EVar "PWhereBodySameLine"))
(DFunDef false "problemCode" ((PCon "BlockEndsBinding" PWild)) (EVar "PDoEndsInBinding"))
(DFunDef false "problemCode" ((PCon "ReservedKeyword" PWild)) (EVar "PReservedKeyword"))
(DFunDef false "problemCode" ((PCon "PublicDataOnly" PWild)) (EVar "PParse"))
(DFunDef false "problemCode" ((PCon "ForeignKeyword" (PVar "word"))) (EIf (EBinOp "==" (EVar "word") (ELit (LString "def"))) (EVar "PDefKeyword") (EIf (EBinOp "||" (EBinOp "==" (EVar "word") (ELit (LString "for"))) (EBinOp "==" (EVar "word") (ELit (LString "while")))) (EVar "PForWhile") (EIf (EVar "otherwise") (EVar "PParse") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig true "diagnosticLoc" (TyFun (TyCon "ParseDiagnostic") (TyCon "Loc")))
(DFunDef false "diagnosticLoc" ((PCon "ParseDiagnostic" PWild (PVar "loc") PWild)) (EVar "loc"))
(DTypeSig true "diagnosticEdits" (TyFun (TyCon "ParseDiagnostic") (TyApp (TyCon "List") (TyCon "ParseEdit"))))
(DFunDef false "diagnosticEdits" ((PCon "ParseDiagnostic" PWild PWild (PVar "edits"))) (EVar "edits"))
(DTypeSig true "renderParseDiagnostic" (TyFun (TyCon "ParseDiagnostic") (TyCon "String")))
(DFunDef false "renderParseDiagnostic" ((PCon "ParseDiagnostic" (PVar "kind") PWild PWild)) (EApp (EVar "renderParseProblem") (EVar "kind")))
(DTypeSig true "renderParseProblem" (TyFun (TyCon "ParseDiagnosticKind") (TyCon "String")))
(DFunDef false "renderParseProblem" ((PCon "NestedInterpolation")) (ELit (LString "nested string interpolation is not supported")))
(DFunDef false "renderParseProblem" ((PCon "UnterminatedString")) (ELit (LString "unterminated string literal")))
(DFunDef false "renderParseProblem" ((PCon "UnterminatedComment")) (ELit (LString "unterminated block comment")))
(DFunDef false "renderParseProblem" ((PCon "UnterminatedChar")) (ELit (LString "unterminated character literal")))
(DFunDef false "renderParseProblem" ((PCon "EmptyChar")) (ELit (LString "character literal is empty; a character is exactly one codepoint, such as `'a'`")))
(DFunDef false "renderParseProblem" ((PCon "IntegerOverflow")) (ELit (LString "integer literal too large for U64 (max 2^64 - 1)")))
(DFunDef false "renderParseProblem" ((PCon "PositiveIntOverflow")) (ELit (LString "integer literal too large for Int (max 4611686018427387903)")))
(DFunDef false "renderParseProblem" ((PCon "FloatOverflow")) (ELit (LString "float literal out of range (overflows to infinity)")))
(DFunDef false "renderParseProblem" ((PCon "HsLambda")) (ELit (LString "Medaka has no `\\x -> e` lambdas; write `x => e`")))
(DFunDef false "renderParseProblem" ((PCon "HsDollar")) (ELit (LString "Medaka has no `$`; write `f (g x)`")))
(DFunDef false "renderParseProblem" ((PCon "UnexpectedEnd")) (ELit (LString "unexpected end of input")))
(DFunDef false "renderParseProblem" ((PCon "BadNeq")) (ELit (LString "unexpected `!=`; did you mean `/=`?")))
(DFunDef false "renderParseProblem" ((PCon "RawStringAfterDot")) (ELit (LString "`.r\"` reads as a raw string literal, not the field `r`; put a space after the `r`, as in `p.r \"x\"`, or parenthesise the field access, as in `(p.r) \"x\"`")))
(DFunDef false "renderParseProblem" ((PCon "HsCase")) (ELit (LString "Medaka has no `case ... of`; write `match e` with indented `pattern => body` arms")))
(DFunDef false "renderParseProblem" ((PCon "MatchWith")) (ELit (LString "Medaka has no `match ... with`; write `match e` with indented `pattern => body` arms")))
(DFunDef false "renderParseProblem" ((PCon "NoPow")) (ELit (LString "Medaka has no `**`; write `pow x y`")))
(DFunDef false "renderParseProblem" ((PCon "HsSignature")) (ELit (LString "`::` is the list cons operator; write `f : T` for a type signature")))
(DFunDef false "renderParseProblem" ((PCon "BlockComment")) (ELit (LString "Medaka has no `/* ... */` comments; write `{- ... -}` or `--`")))
(DFunDef false "renderParseProblem" ((PCon "BraceBlock")) (ELit (LString "Medaka has no `{ ... }` blocks; indent the body after `then` and `else`")))
(DFunDef false "renderParseProblem" ((PCon "Semicolon")) (ELit (LString "Medaka has no statement terminator `;`; write each statement on its own line")))
(DFunDef false "renderParseProblem" ((PCon "MatchGuardBar")) (ELit (LString "a match-arm guard uses `if`, not `|`; write `pat if cond => body`")))
(DFunDef false "renderParseProblem" ((PCon "MatchGuardBarWrapped")) (ELit (LString "a `|` ending a line cannot continue an or-pattern; wrap the alternatives in parentheses, `(A | B | C) => body`, or write them on one line")))
(DFunDef false "renderParseProblem" ((PCon "ExpectedMatchArm")) (ELit (LString "expected a match arm (`pattern => body`)")))
(DFunDef false "renderParseProblem" ((PCon "ExpectedMatchArrow")) (ELit (LString "expected `=>` after the match pattern or guard")))
(DFunDef false "renderParseProblem" ((PCon "MatchContinuationHint")) (ELit (LString "expected a match arm (`pattern => body`); if this line continues the scrutinee, wrap the whole scrutinee in parentheses")))
(DFunDef false "renderParseProblem" ((PCon "EquationGuardIf")) (ELit (LString "an equation guard uses `|`, not `if`; write `| cond = body`")))
(DFunDef false "renderParseProblem" ((PCon "UnexpectedEndExpected" (PVar "expected"))) (EBinOp "++" (EBinOp "++" (ELit (LString "unexpected end of input; expected ")) (EApp (EMethodRef "display") (EVar "expected"))) (ELit (LString ""))))
(DFunDef false "renderParseProblem" ((PCon "GenericParse" (PVar "msg"))) (EVar "msg"))
(DFunDef false "renderParseProblem" ((PCon "InvalidEscape" (PVar "spelling") (PVar "inChar"))) (EBlock (DoLet false false (PVar "quote") (EIf (EVar "inChar") (ELit (LString "\\'")) (ELit (LString "\\\"")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "invalid escape sequence `")) (EApp (EMethodRef "display") (EVar "spelling"))) (ELit (LString "`; valid escapes are \\n \\t \\r \\0 \\\\ "))) (EApp (EMethodRef "display") (EVar "quote"))) (ELit (LString " \\u{...}"))))))
(DFunDef false "renderParseProblem" ((PCon "BadUnicodeEscape" (PVar "problem"))) (EApp (EVar "renderUnicodeProblem") (EVar "problem")))
(DFunDef false "renderParseProblem" ((PCon "BareUnicodeEscape" (PVar "old") (PVar "new"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "bare unicode escape `")) (EApp (EMethodRef "display") (EVar "old"))) (ELit (LString "` is not valid; did you mean `"))) (EApp (EMethodRef "display") (EVar "new"))) (ELit (LString "`?"))))
(DFunDef false "renderParseProblem" ((PCon "LongChar" (PVar "text"))) (EBinOp "++" (EBinOp "++" (ELit (LString "character literal `'")) (EApp (EMethodRef "display") (EVar "text"))) (ELit (LString "'` has more than one codepoint; write a `\"...\"` string for text"))))
(DFunDef false "renderParseProblem" ((PCon "NonAsciiByte" (PVar "ch") (PVar "fixIt"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "byte literal `b'")) (EApp (EMethodRef "display") (EVar "ch"))) (ELit (LString "'` is not ASCII; a byte literal holds one byte, so write its UTF-8 bytes as "))) (EApp (EMethodRef "display") (EVar "fixIt"))) (ELit (LString ""))))
(DFunDef false "renderParseProblem" ((PCon "BadByteLiteral" (PVar "msg"))) (EVar "msg"))
(DFunDef false "renderParseProblem" ((PCon "ByteLikeIdent" (PVar "old") (PVar "new"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "old"))) (ELit (LString "` is a byte literal, not an identifier; rename it, for example `"))) (EApp (EMethodRef "display") (EVar "new"))) (ELit (LString "`"))))
(DFunDef false "renderParseProblem" ((PCon "UnexpectedCharacter" (PVar "text"))) (EBinOp "++" (EBinOp "++" (ELit (LString "unexpected character `")) (EApp (EMethodRef "display") (EVar "text"))) (ELit (LString "`"))))
(DFunDef false "renderParseProblem" ((PCon "WidePattern" (PVar "lx"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "integer literal too large for a pattern: `")) (EApp (EMethodRef "display") (EVar "lx"))) (ELit (LString "` exceeds Int; match it in a guard instead, `x if x == "))) (EApp (EMethodRef "display") (EVar "lx"))) (ELit (LString "`"))))
(DFunDef false "renderParseProblem" ((PCon "MalformedRadix" (PVar "bad") (PVar "prefix") (PVar "digits"))) (EIf (EBinOp "==" (EApp (EVar "stringLength") (EVar "digits")) (ELit (LInt 0))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "malformed radix literal `")) (EApp (EMethodRef "display") (EVar "bad"))) (ELit (LString "`: no digits follow the "))) (EApp (EMethodRef "display") (EVar "prefix"))) (ELit (LString " prefix; an underscore may only separate digits"))) (EIf (EVar "otherwise") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "malformed radix literal `")) (EApp (EMethodRef "display") (EVar "bad"))) (ELit (LString "`: an underscore cannot follow the "))) (EApp (EMethodRef "display") (EVar "prefix"))) (ELit (LString " prefix; write `"))) (EApp (EMethodRef "display") (EVar "prefix"))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "digits"))) (ELit (LString "`"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "renderParseProblem" ((PCon "MalformedFloat" (PVar "bad") (PVar "good") (PVar "leading"))) (EBlock (DoLet false false (PVar "side") (EIf (EVar "leading") (ELit (LString "precede")) (ELit (LString "follow")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "malformed float literal `")) (EApp (EMethodRef "display") (EVar "bad"))) (ELit (LString "`: a digit must "))) (EApp (EMethodRef "display") (EVar "side"))) (ELit (LString " the decimal point; write `"))) (EApp (EMethodRef "display") (EVar "good"))) (ELit (LString "`"))))))
(DFunDef false "renderParseProblem" ((PCon "ForeignKeyword" (PVar "word"))) (EApp (EVar "foreignKeywordMessage") (EVar "word")))
(DFunDef false "renderParseProblem" ((PCon "MissingWhere" (PVar "header"))) (EBlock (DoLet false false (PVar "members") (EIf (EBinOp "==" (EVar "header") (ELit (LString "impl"))) (ELit (LString "methods")) (ELit (LString "members")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "missing `where` on this `")) (EApp (EMethodRef "display") (EVar "header"))) (ELit (LString "` header; end the header with `where` and indent the "))) (EApp (EMethodRef "display") (EVar "members"))) (ELit (LString " below it"))))))
(DFunDef false "renderParseProblem" ((PCon "WhereSameLine" (PVar "header"))) (EBlock (DoLet false false (PVar "member") (EIf (EBinOp "==" (EVar "header") (ELit (LString "impl"))) (ELit (LString "method")) (ELit (LString "member")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "a `where` block must start on the next line; move this ")) (EApp (EMethodRef "display") (EVar "member"))) (ELit (LString " onto its own line, indented below the `"))) (EApp (EMethodRef "display") (EVar "header"))) (ELit (LString "` header"))))))
(DFunDef false "renderParseProblem" ((PCon "BlockEndsBinding" (PVar "word"))) (EBinOp "++" (EBinOp "++" (ELit (LString "a `")) (EApp (EMethodRef "display") (EVar "word"))) (ELit (LString "` block must end in an expression, not a binding; add the expression whose value the block should have"))))
(DFunDef false "renderParseProblem" ((PCon "ReservedKeyword" (PVar "name"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "`")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` is a reserved keyword and cannot name a variable or pattern; rename it to `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "_`"))))
(DFunDef false "renderParseProblem" ((PCon "PublicDataOnly" (PCon "True"))) (ELit (LString "`public` applies only to `data` declarations with constructors; write `export extern`")))
(DFunDef false "renderParseProblem" ((PCon "PublicDataOnly" (PCon "False"))) (ELit (LString "`public` applies only to `data` declarations; write plain `export`")))
(DTypeSig false "foreignKeywordMessage" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "foreignKeywordMessage" ((PLit (LString "def"))) (ELit (LString "Medaka has no `def`; write `f x = ...`")))
(DFunDef false "foreignKeywordMessage" ((PLit (LString "while"))) (ELit (LString "Medaka has no `while`; write a recursive function")))
(DFunDef false "foreignKeywordMessage" ((PLit (LString "elif"))) (ELit (LString "Medaka has no `elif`; write `else if`")))
(DFunDef false "foreignKeywordMessage" ((PLit (LString "class"))) (ELit (LString "Medaka has no `class`; write a `data` type or an `interface`")))
(DFunDef false "foreignKeywordMessage" ((PLit (LString "try"))) (ELit (LString "Medaka has no `try`; return errors as `Result` values")))
(DFunDef false "foreignKeywordMessage" ((PLit (LString "except"))) (ELit (LString "Medaka has no `except`; return errors as `Result` values")))
(DFunDef false "foreignKeywordMessage" ((PLit (LString "finally"))) (ELit (LString "Medaka has no `finally`; return errors as `Result` values")))
(DFunDef false "foreignKeywordMessage" (PWild) (ELit (LString "Medaka has no `for` loops; use `map` or `fold` over the list")))
(DTypeSig false "renderUnicodeProblem" (TyFun (TyCon "UnicodeProblem") (TyCon "String")))
(DFunDef false "renderUnicodeProblem" ((PCon "UnicodeUnterminated")) (ELit (LString "unicode escape is not terminated; the file ends before its closing `}`")))
(DFunDef false "renderUnicodeProblem" ((PCon "UnicodeSeparator")) (ELit (LString "unicode escape cannot contain `_`; write the hex digits unbroken, as in `\\u{41}`")))
(DFunDef false "renderUnicodeProblem" ((PCon "UnicodeEmpty")) (ELit (LString "unicode escape `\\u{}` has no digits; write at least one hex digit, as in `\\u{41}`")))
(DFunDef false "renderUnicodeProblem" ((PCon "UnicodeExpectedDigit" (PVar "found"))) (EBinOp "++" (EBinOp "++" (ELit (LString "unicode escape expects a hex digit after `\\u{` but found `")) (EApp (EMethodRef "display") (EVar "found"))) (ELit (LString "`"))))
(DFunDef false "renderUnicodeProblem" ((PCon "UnicodeExpectedClose" (PVar "found"))) (EBinOp "++" (EBinOp "++" (ELit (LString "unicode escape expects `}` after its hex digits but found `")) (EApp (EMethodRef "display") (EVar "found"))) (ELit (LString "`"))))
(DFunDef false "renderUnicodeProblem" ((PCon "UnicodeSurrogate" (PVar "text"))) (EBinOp "++" (EBinOp "++" (ELit (LString "unicode escape `")) (EApp (EMethodRef "display") (EVar "text"))) (ELit (LString "` is a UTF-16 surrogate, not a character; codepoints D800-DFFF are not valid on their own"))))
(DFunDef false "renderUnicodeProblem" ((PCon "UnicodeOutOfRange" (PVar "text"))) (EBinOp "++" (EBinOp "++" (ELit (LString "unicode escape `")) (EApp (EMethodRef "display") (EVar "text"))) (ELit (LString "` is out of range; a codepoint is at most 10FFFF"))))
(DTypeSig true "diagnosticHelp" (TyFun (TyCon "ParseDiagnostic") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "diagnosticHelp" ((PCon "ParseDiagnostic" (PVar "kind") PWild PWild)) (EApp (EVar "problemHelp") (EVar "kind")))
(DTypeSig false "problemHelp" (TyFun (TyCon "ParseDiagnosticKind") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "problemHelp" ((PCon "HsSignature")) (EApp (EVar "Some") (ELit (LString "replace `::` with `:`"))))
(DFunDef false "problemHelp" ((PCon "BadNeq")) (EApp (EVar "Some") (ELit (LString "replace `!=` with `/=`"))))
(DFunDef false "problemHelp" ((PCon "RawStringAfterDot")) (EApp (EVar "Some") (ELit (LString "insert a space between the `r` and the opening quote"))))
(DFunDef false "problemHelp" ((PCon "PositiveIntOverflow")) (EApp (EVar "Some") (ELit (LString "`Int` is 63-bit, spanning [-4611686018427387904, 4611686018427387903]; 4611686018427387904 fits only as the negative -4611686018427387904, so write it with its `-`"))))
(DFunDef false "problemHelp" ((PCon "NonAsciiByte" PWild (PVar "fixIt"))) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "write the character as its UTF-8 bytes, ")) (EApp (EMethodRef "display") (EVar "fixIt"))) (ELit (LString "")))))
(DFunDef false "problemHelp" ((PCon "ByteLikeIdent" PWild (PVar "new"))) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "rename every occurrence of the identifier, for example to `")) (EApp (EMethodRef "display") (EVar "new"))) (ELit (LString "`")))))
(DFunDef false "problemHelp" ((PCon "BareUnicodeEscape" PWild PWild)) (EApp (EVar "Some") (ELit (LString "write the unicode escape braced, `\\u{XXXX}`"))))
(DFunDef false "problemHelp" ((PCon "MalformedRadix" PWild PWild PWild)) (EApp (EVar "Some") (ELit (LString "the digit separator `_` may only appear between digits"))))
(DFunDef false "problemHelp" ((PCon "MalformedFloat" PWild PWild PWild)) (EApp (EVar "Some") (ELit (LString "a float literal needs a digit on both sides of the decimal point"))))
(DFunDef false "problemHelp" ((PCon "ReservedKeyword" (PVar "w"))) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "rename it to `")) (EApp (EMethodRef "display") (EVar "w"))) (ELit (LString "_`; any reserved word plus `_` is a valid identifier")))))
(DFunDef false "problemHelp" ((PCon "PublicDataOnly" PWild)) (EApp (EVar "Some") (ELit (LString "drop `public`; a function or value is exported with plain `export`"))))
(DFunDef false "problemHelp" ((PCon "MissingWhere" PWild)) (EApp (EVar "Some") (ELit (LString "end the header with `where`; without it the next line is read as another type argument"))))
(DFunDef false "problemHelp" ((PCon "BlockEndsBinding" PWild)) (EApp (EVar "Some") (ELit (LString "end the block with the expression whose value it should have, such as `pure x`"))))
(DFunDef false "problemHelp" ((PCon "WhereSameLine" PWild)) (EApp (EVar "Some") (ELit (LString "`where` opens a block only when it ends the line; move the member to the next line"))))
(DFunDef false "problemHelp" ((PCon "MatchGuardBar")) (EApp (EVar "Some") (ELit (LString "replace `|` with `if`"))))
(DFunDef false "problemHelp" ((PCon "EquationGuardIf")) (EApp (EVar "Some") (ELit (LString "replace `if` with `|`"))))
(DFunDef false "problemHelp" (PWild) (EVar "None"))
(DTypeSig true "locateParseProblem" (TyFun (TyCon "SourceIndex") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "ParseDiagnosticKind") (TyCon "ParseDiagnostic"))))))
(DFunDef false "locateParseProblem" ((PVar "index") (PVar "start") (PVar "end") (PVar "kind")) (EBlock (DoLet false false (PTuple (PVar "sl") (PVar "sc")) (EApp (EApp (EVar "optionOr") (ETuple (ELit (LInt 1)) (ELit (LInt 0)))) (EApp (EApp (EVar "offsetToSourcePosition") (EMethodRef "index")) (EVar "start")))) (DoLet false false (PTuple (PVar "el") (PVar "ec")) (EApp (EApp (EVar "optionOr") (ETuple (EVar "sl") (EVar "sc"))) (EApp (EApp (EVar "offsetToSourcePosition") (EMethodRef "index")) (EVar "end")))) (DoLet false false (PVar "loc") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec"))) (DoExpr (EApp (EApp (EVar "makeParseDiagnostic") (EVar "kind")) (EVar "loc")))))
(DTypeSig false "replacementEdit" (TyFun (TyCon "Loc") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "ParseEdit"))))))
(DFunDef false "replacementEdit" ((PVar "loc") (PVar "old") (PVar "new")) (EListLit (EApp (EApp (EApp (EApp (EVar "ParseEdit") (EVar "loc")) (EVar "old")) (EVar "new")) (EVar "MachineApplicable"))))
(DTypeSig false "problemEdits" (TyFun (TyCon "ParseDiagnosticKind") (TyFun (TyCon "Loc") (TyApp (TyCon "List") (TyCon "ParseEdit")))))
(DFunDef false "problemEdits" ((PCon "BadNeq") (PVar "loc")) (EApp (EApp (EApp (EVar "replacementEdit") (EVar "loc")) (ELit (LString "!="))) (ELit (LString "/="))))
(DFunDef false "problemEdits" ((PCon "RawStringAfterDot") (PCon "Loc" (PVar "file") (PVar "sl") (PVar "sc") PWild PWild)) (EApp (EApp (EApp (EVar "replacementEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "file")) (EVar "sl")) (EVar "sc")) (EVar "sl")) (EBinOp "+" (EVar "sc") (ELit (LInt 2))))) (ELit (LString "r\""))) (ELit (LString "r \""))))
(DFunDef false "problemEdits" ((PCon "HsSignature") (PVar "loc")) (EApp (EApp (EApp (EVar "replacementEdit") (EVar "loc")) (ELit (LString "::"))) (ELit (LString ":"))))
(DFunDef false "problemEdits" ((PCon "BareUnicodeEscape" (PVar "old") (PVar "new")) (PVar "loc")) (EApp (EApp (EApp (EVar "replacementEdit") (EVar "loc")) (EVar "old")) (EVar "new")))
(DFunDef false "problemEdits" ((PCon "MalformedRadix" (PVar "bad") (PVar "prefix") (PVar "digits")) (PVar "loc")) (EIf (EBinOp "==" (EVar "digits") (ELit (LString ""))) (EListLit) (EApp (EApp (EApp (EVar "replacementEdit") (EVar "loc")) (EVar "bad")) (EBinOp "++" (EVar "prefix") (EVar "digits")))))
(DFunDef false "problemEdits" ((PCon "MalformedFloat" (PVar "bad") (PVar "good") PWild) (PVar "loc")) (EApp (EApp (EApp (EVar "replacementEdit") (EVar "loc")) (EVar "bad")) (EVar "good")))
(DFunDef false "problemEdits" ((PCon "ReservedKeyword" (PVar "name")) (PVar "loc")) (EApp (EApp (EApp (EVar "replacementEdit") (EVar "loc")) (EVar "name")) (EBinOp "++" (EVar "name") (ELit (LString "_")))))
(DFunDef false "problemEdits" ((PCon "PublicDataOnly" PWild) (PVar "loc")) (EApp (EApp (EApp (EVar "replacementEdit") (EVar "loc")) (ELit (LString "public"))) (ELit (LString ""))))
(DFunDef false "problemEdits" ((PCon "MatchGuardBar") (PVar "loc")) (EApp (EApp (EApp (EVar "replacementEdit") (EVar "loc")) (ELit (LString "|"))) (ELit (LString "if"))))
(DFunDef false "problemEdits" ((PCon "EquationGuardIf") (PVar "loc")) (EApp (EApp (EApp (EVar "replacementEdit") (EVar "loc")) (ELit (LString "if"))) (ELit (LString "|"))))
(DFunDef false "problemEdits" (PWild PWild) (EListLit))
(DTypeSig true "makeParseDiagnostic" (TyFun (TyCon "ParseDiagnosticKind") (TyFun (TyCon "Loc") (TyCon "ParseDiagnostic"))))
(DFunDef false "makeParseDiagnostic" ((PVar "kind") (PVar "loc")) (EApp (EApp (EApp (EVar "ParseDiagnostic") (EVar "kind")) (EVar "loc")) (EApp (EApp (EVar "problemEdits") (EVar "kind")) (EVar "loc"))))
