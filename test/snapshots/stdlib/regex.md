# META
source_lines=1678
stages=DESUGAR,MARK
# SOURCE
{- | Regular expressions, matched in linear time.

   Patterns use Perl syntax restricted to the regular subset, the dialect Go
   `regexp` and RE2 accept. There are no backreferences and no lookaround, and
   in exchange a match costs `O(n * m)` in subject length and pattern size
   with no subject that makes it blow up. When more than one match is
   possible the leftmost one wins, and among the matches starting there the
   one the pattern prefers: alternation order first, greedy before lazy. So
   `a|ab` matches `"a"` in `"ab"`, which is what Perl and Go give and not
   POSIX leftmost-longest.

   Positions are codepoint offsets, as in `string.indexOf`. `.` matches any
   codepoint but `\n`, and `\d`, `\w`, `\s`, `\b` and `(?i)` folding are
   ASCII only, matching `string.isDigit` and `string.toUpper`.

   A subject may also be a UTF-8 byte buffer rather than a `String`:
   `isFullMatchBytes` and `findBytes` match over a window of an `Array Int`
   with each byte a code 0..255, which is what a protocol grammar whose limits
   are stated in bytes wants.

   `compile` reports a bad pattern as an `Err`, and `mustCompile` panics,
   which suits a pattern written as a literal. A top-level binding is
   evaluated once, so `wordRe = mustCompile "\\w+"` compiles one time
   however often it is used.

   Every escape in a pattern needs its backslash doubled in Medaka source,
   because a plain string literal accepts only `\n`, `\t`, `\r`, `\0`, `\\`,
   `\"` and `\u{...}`. Write `\d` as `"\\d"` and a literal brace as `"\\{"`.

   The syntax accepted is:

   - `x`, `\.`, `\\`, `\n`, `\t`, `\r`, `\xHH`, `\u{HEX}`: one literal
     codepoint.
   - `.`: any codepoint but `\n`, or any at all under `(?s)`.
   - `[abc]`, `[a-z0-9]`, `[^...]`, with `\d`, `\w`, `\s` and their
     complements usable inside.
   - `\d`, `\D`, `\w`, `\W`, `\s`, `\S`: ASCII digit, word
     (`[A-Za-z0-9_]`), space (`[ \t\n\r]`), and complements.
   - `^`, `$`: start and end of the subject, or of a line under `(?m)`.
   - `\b`, `\B`: ASCII word boundary and its complement.
   - `ab`, `a|b`, `(...)`, `(?:...)`: concatenation, alternation, capturing
     and non-capturing group.
   - `*`, `+`, `?`, `{n}`, `{n,}`, `{n,m}`: greedy repetition, and `*?`,
     `+?`, `??`, `{n,m}?` for the lazy forms.
   - `(?i)`, `(?m)`, `(?s)` and combinations, at the start of the pattern
     only.

   A `{` that does not open a valid bound is a literal `{`. Named groups,
   POSIX classes, Unicode classes and inline flag scoping are rejected with
   a message naming what is missing. -}

-- The engine is a Thompson NFA run as a Pike VM: the pattern parses to a
-- tree, the tree compiles to a flat instruction array, and the VM walks the
-- subject once carrying a list of threads keyed by program counter, so each
-- counter is reached at most once per position and a step costs O(m).
-- Threads are added in priority order and everything below a thread that
-- reaches IMatch is cut, which is where leftmost-first comes from.
--
-- The VM runs over an Array Int with a (start, end) window rather than over
-- the String, which is what lets `isFullMatchBytes`/`findBytes` be a second
-- front door onto the same engine with each byte a code 0..255.

import array.{sliceClamped as sliceBytes}
import list.{get, reverse}
import string.{fromChars, fromUtf8, isDigit, repeat, sliceClamped, toChars}

-- # Types

{- | A compiled pattern.

   Values are immutable and safe to share. `Debug` renders the source
   pattern. There is no `Eq` or `Ord` instance. -}
export data Regex = Regex {
  src : String,
  prog : Array Inst,
  ngroups : Int,
  multiline : Bool,
}

{- | Why a pattern would not compile, and where.

   `position` is the codepoint offset in the pattern at which the parser
   gave up. -}
public export data RegexError = RegexError {
  message : String,
  position : Int,
}
  deriving (Eq, Debug)

{- | One capture group's span and text.

   `start` and `end` are codepoint offsets into the subject, `end`
   exclusive. -}
public export data Group = Group {
  start : Int,
  end : Int,
  text : String,
}
  deriving (Eq, Debug)

{- | One match: its span, its text, and its capture groups.

   `groups` holds group 1 onwards in pattern order, with `None` for a group
   that did not take part in the match. -}
public export data Match = Match {
  start : Int,
  end : Int,
  text : String,
  groups : List (Option Group),
}
  deriving (Eq, Debug)

export impl Debug Regex where
  debug re = "regex " ++ debugStringLit re.src

-- # Character sets
--
-- A set is a flat Array Int of lo,hi pairs plus a negation flag.  Matching
-- scans the pairs, which is short enough that an ordered structure would
-- cost more than it saves.

maxCode : Int
maxCode = 1114111

digitRanges : List (Int, Int)
digitRanges = [(48, 57)]

wordRanges : List (Int, Int)
wordRanges = [(48, 57), (65, 90), (95, 95), (97, 122)]

-- Space is ` \t\n\r`, matching string.isSpace's ASCII set minus form feed
-- and vertical tab, which no subject in the census uses.
spaceRanges : List (Int, Int)
spaceRanges = [(9, 10), (13, 13), (32, 32)]

wordSet : Array Int
wordSet = flattenRanges wordRanges

flattenRanges : List (Int, Int) -> Array Int
flattenRanges rs = arrayFromList (flattenGo rs)

flattenGo : List (Int, Int) -> List Int
flattenGo [] = []
flattenGo ((lo, hi) :: rest) = lo :: hi :: flattenGo rest

-- The complement over 0..maxCode of a sorted, non-overlapping range list.
-- Only ever applied to the three lists above.
complementRanges : List (Int, Int) -> List (Int, Int)
complementRanges rs = complementGo rs 0

complementGo : List (Int, Int) -> Int -> List (Int, Int)
complementGo [] next = if next > maxCode then [] else [(next, maxCode)]
complementGo ((lo, hi) :: rest) next =
  let after = max (hi + 1) next
  if lo > next then
    (next, lo - 1) :: complementGo rest after
  else
    complementGo rest after

inRanges : Array Int -> Int -> Int -> Bool
inRanges rs i c =
  if i >= arrayLength rs then
    False
  else if c >= arrayGetUnsafe i rs && c <= arrayGetUnsafe (i + 1) rs then
    True
  else
    inRanges rs (i + 2) c

setMatches : Array Int -> Bool -> Int -> Bool
setMatches rs negated c =
  if negated then not (inRanges rs 0 c) else inRanges rs 0 c

isWordCode : Int -> Bool
isWordCode c = inRanges wordSet 0 c

isAsciiLetterCode : Int -> Bool
isAsciiLetterCode c = c >= 65 && c <= 90 || c >= 97 && c <= 122

-- Adds the other-case counterpart of every ASCII letter a range covers.
-- Folding happens before negation, so `(?i)[^a]` rejects both cases.
foldRanges : List (Int, Int) -> List (Int, Int)
foldRanges [] = []
foldRanges ((lo, hi) :: rest) =
  let upper = clipShift lo hi 97 122 (-32)
  let lower = clipShift lo hi 65 90 32
  (lo, hi) :: upper ++ (lower ++ foldRanges rest)

clipShift : Int -> Int -> Int -> Int -> Int -> List (Int, Int)
clipShift lo hi blo bhi shift =
  let l = max lo blo
  let h = min hi bhi
  if l <= h then [(l + shift, h + shift)] else []

-- # Pattern tree

-- Assertion kinds, the payload of NAssert and IAssert.
asStart : Int
asStart = 0

asEnd : Int
asEnd = 1

asWordB : Int
asWordB = 2

asNotWordB : Int
asNotWordB = 3

data Node =
  | NEmpty
  | NChar Int
  | NSet (Array Int) Bool
  | NAny Bool
  | NCat Node Node
  | NAlt Node Node
  | NStar Bool Node
  | NPlus Bool Node
  | NOpt Bool Node
  | NGroup Int Node
  | NAssert Int

-- An upper bound on the instructions a node compiles to, used to refuse a
-- bounded repetition before expanding it rather than after.
nodeSize : Node -> Int
nodeSize NEmpty = 1
nodeSize (NChar _) = 1
nodeSize (NSet _ _) = 1
nodeSize (NAny _) = 1
nodeSize (NAssert _) = 1
nodeSize (NCat a b) = nodeSize a + nodeSize b
nodeSize (NAlt a b) = 2 + nodeSize a + nodeSize b
nodeSize (NStar _ b) = 2 + nodeSize b
nodeSize (NPlus _ b) = 1 + nodeSize b
nodeSize (NOpt _ b) = 1 + nodeSize b
nodeSize (NGroup _ b) = 2 + nodeSize b

-- # Parser

repeatCap : Int
repeatCap = 1000

progCap : Int
progCap = 20000

data PState = PState {
  pat : Array Char,
  pos : Ref Int,
  ngroups : Ref Int,
  perr : Ref (Option RegexError),
  fold : Bool,
  dotAll : Bool,
}

patLen : PState -> Int
patLen st = arrayLength st.pat

atEnd : PState -> Bool
atEnd st = !st.pos >= patLen st

cur : PState -> Char
cur st = arrayGetUnsafe !st.pos st.pat

isAt : PState -> Char -> Bool
isAt st c = not (atEnd st) && cur st == c

peekIs : PState -> Int -> Char -> Bool
peekIs st k c =
  let i = !st.pos + k
  i < patLen st && arrayGetUnsafe i st.pat == c

peekAt : PState -> Int -> Option Char
peekAt st k =
  let i = !st.pos + k
  if i < patLen st then Some (arrayGetUnsafe i st.pat) else None

advance : PState -> Unit
advance st = st.pos := !st.pos + 1

hasErr : PState -> Bool
hasErr st = match !st.perr
  Some _ => True
  None => False

-- The first failure is the reported one: a parser that keeps walking after
-- an error would otherwise overwrite the useful position with a later one.
failAt : PState -> String -> Unit
failAt st message = match !st.perr
  Some _ => ()
  None => st.perr := Some RegexError { message = message, position = !st.pos }

-- Consumes a two-character token and hands back a value.  The value is
-- evaluated before the cursor moves, so it must not itself read the cursor:
-- a caller that parses the rest of the token has to advance explicitly.
skip2 : PState -> a -> a
skip2 st v =
  advance st
  advance st
  v

-- Leading (?ims) groups, read before parsing because the flags they set are
-- fixed for the whole pattern.  Returns the offset the pattern proper starts
-- at plus the three flags.
scanFlags : Array Char -> Int -> Bool -> Bool -> Bool -> (Int, Bool, Bool, Bool)
scanFlags cs i fold multi dotAll =
  if i + 2 < arrayLength cs
    && arrayGetUnsafe i cs == '('
    && arrayGetUnsafe (i + 1) cs == '?'
    && isFlagChar
      (arrayGetUnsafe
        (i + 2)
        cs) then match scanFlagChars cs (i + 2) fold multi dotAll
    None => (i, fold, multi, dotAll)
    Some (j, f2, m2, s2) => scanFlags cs j f2 m2 s2
  else
    (i, fold, multi, dotAll)

isFlagChar : Char -> Bool
isFlagChar c = c == 'i' || c == 'm' || c == 's'

scanFlagChars : Array Char ->
  Int ->
  Bool ->
  Bool ->
  Bool ->
  Option (Int, Bool, Bool, Bool)
scanFlagChars cs k fold multi dotAll =
  if k >= arrayLength cs then
    None
  else
    let c = arrayGetUnsafe k cs
    if c == 'i' then
      scanFlagChars cs (k + 1) True multi dotAll
    else if c == 'm' then
      scanFlagChars cs (k + 1) fold True dotAll
    else if c == 's' then
      scanFlagChars cs (k + 1) fold multi True
    else if c == ')' then
      Some (k + 1, fold, multi, dotAll)
    else
      None

parseAlt : PState -> Node
parseAlt st = parseAltMore st (parseCat st)

parseAltMore : PState -> Node -> Node
parseAltMore st left =
  if isAt st '|' then
    advance st
    let right = parseCat st
    parseAltMore st (NAlt left right)
  else
    left

parseCat : PState -> Node
parseCat st = catOf (parseSeq st [])

catOf : List Node -> Node
catOf [] = NEmpty
catOf (x :: []) = x
catOf (x :: rest) = NCat x (catOf rest)

parseSeq : PState -> List Node -> List Node
parseSeq st acc =
  if hasErr st || atEnd st || isAt st '|' || isAt st ')' then
    reverse acc
  else
    let item = parsePiece st
    parseSeq st (item :: acc)

parsePiece : PState -> Node
parsePiece st =
  let atom = parseAtom st
  parseQuant st atom

parseQuant : PState -> Node -> Node
parseQuant st node =
  if hasErr st then
    node
  else if isAt st '*' then
    advance st
    parseQuant st (NStar (greedFlag st) node)
  else if isAt st '+' then
    advance st
    parseQuant st (NPlus (greedFlag st) node)
  else if isAt st '?' then
    advance st
    parseQuant st (NOpt (greedFlag st) node)
  else if isAt st '{' then
    parseBrace st node
  else
    node

greedFlag : PState -> Bool
greedFlag st =
  if isAt st '?' then
    advance st
    False
  else
    True

-- A `{` that does not open a valid bound rewinds and is re-read as a
-- literal, which is what RE2 does and what makes `a{` legal.
parseBrace : PState -> Node -> Node
parseBrace st node =
  let save = !st.pos
  advance st
  match parseDigits st
    None => rewind st save node
    Some lo =>
      if isAt st '}' then
        advance st
        finishRepeat st node lo lo
      else if isAt st ',' then
        advance st
        parseBraceUpper st node save lo
      else
        rewind st save node

parseBraceUpper : PState -> Node -> Int -> Int -> Node
parseBraceUpper st node save lo =
  if isAt st '}' then
    advance st
    finishRepeat st node lo (-1)
  else match parseDigits st
    None => rewind st save node
    Some hi =>
      if isAt st '}' then
        advance st
        finishRepeat st node lo hi
      else
        rewind st save node

rewind : PState -> Int -> Node -> Node
rewind st save node =
  st.pos := save
  node

parseDigits : PState -> Option Int
parseDigits st =
  if atEnd st || not (isDigit (cur st)) then None else digitsGo st 0

digitsGo : PState -> Int -> Option Int
digitsGo st acc =
  if atEnd st || not (isDigit (cur st)) then
    Some acc
  else if acc > repeatCap then
    Some acc
  else
    let d = charCode (cur st) - 48
    advance st
    digitsGo st (acc * 10 + d)

finishRepeat : PState -> Node -> Int -> Int -> Node
finishRepeat st node lo hi =
  if lo > repeatCap || hi > repeatCap then
    failAt st "repetition bound is larger than the maximum of 1000"
    node
  else if hi >= 0 && hi < lo then
    failAt st "repetition bounds are out of order"
    node
  else if repeatWidth lo hi * nodeSize node > progCap then
    failAt st "pattern compiles to more than 20000 instructions"
    node
  else
    let greedy = greedFlag st
    parseQuant st (expandRepeat greedy node lo hi)

repeatWidth : Int -> Int -> Int
repeatWidth lo hi = if hi < 0 then lo + 2 else hi + 1

expandRepeat : Bool -> Node -> Int -> Int -> Node
expandRepeat greedy node lo hi =
  if hi < 0 then
    catRepeat node lo (NStar greedy node)
  else
    catRepeat node lo (optChain greedy node (hi - lo))

catRepeat : Node -> Int -> Node -> Node
catRepeat node n rest =
  if n <= 0 then rest else NCat node (catRepeat node (n - 1) rest)

-- `a{2,4}` is `a a (a (a)?)?`, nested rather than a flat run of options, so
-- a greedy bound takes as many copies as it can and a lazy one as few.
optChain : Bool -> Node -> Int -> Node
optChain greedy node k =
  if k <= 0 then
    NEmpty
  else
    NOpt greedy (NCat node (optChain greedy node (k - 1)))

parseAtom : PState -> Node
parseAtom st =
  if atEnd st then
    failAt st "pattern ends where an expression was expected"
    NEmpty
  else
    let c = cur st
    if c == '(' then
      parseGroup st
    else if c == '[' then
      parseSet st
    else if c == '.' then
      advance st
      NAny st.dotAll
    else if c == '^' then
      advance st
      NAssert asStart
    else if c == '$' then
      advance st
      NAssert asEnd
    else if c == '\\' then
      parseEscape st
    else if c == '*' || c == '+' || c == '?' then
      failAt st "repetition operator with nothing to repeat"
      advance st
      NEmpty
    else
      advance st
      litNode st (charCode c)

litNode : PState -> Int -> Node
litNode st code =
  if st.fold && isAsciiLetterCode code then
    NSet (flattenRanges (foldRanges [(code, code)])) False
  else
    NChar code

parseGroup : PState -> Node
parseGroup st =
  advance st
  if isAt st '?' then
    if peekIs st 1 ':' then
      advance st
      advance st
      groupBody st 0
    else
      failAt st (groupRefusal st)
      NEmpty
  else
    let idx = !st.ngroups + 1
    st.ngroups := idx
    groupBody st idx

-- Group numbers follow the order the opening parens appear in, so the
-- counter moves before the body is parsed.
groupBody : PState -> Int -> Node
groupBody st idx =
  let body = parseAlt st
  if isAt st ')' then
    advance st
    if idx == 0 then body else NGroup idx body
  else
    failAt st "pattern is missing a closing )"
    NEmpty

groupRefusal : PState -> String
groupRefusal st = match peekAt st 1
  Some '=' => "lookahead is not supported"
  Some '!' => "lookahead is not supported"
  Some '<' => "named groups and lookbehind are not supported"
  Some 'P' => "named groups are not supported"
  Some 'i' => "flags are only allowed at the start of the pattern"
  Some 'm' => "flags are only allowed at the start of the pattern"
  Some 's' => "flags are only allowed at the start of the pattern"
  _ => "unsupported group syntax after (?"

parseEscape : PState -> Node
parseEscape st = match peekAt st 1
  None =>
    advance st
    failAt st "pattern ends in a backslash"
    NEmpty
  Some c =>
    if c == 'd' then
      skip2 st (NSet (flattenRanges digitRanges) False)
    else if c == 'D' then
      skip2 st (NSet (flattenRanges digitRanges) True)
    else if c == 'w' then
      skip2 st (NSet wordSet False)
    else if c == 'W' then
      skip2 st (NSet wordSet True)
    else if c == 's' then
      skip2 st (NSet (flattenRanges spaceRanges) False)
    else if c == 'S' then
      skip2 st (NSet (flattenRanges spaceRanges) True)
    else if c == 'b' then
      skip2 st (NAssert asWordB)
    else if c == 'B' then
      skip2 st (NAssert asNotWordB)
    else match escapeCode st
      None => NEmpty
      Some code => litNode st code

-- One escaped literal codepoint, the backslash still under the cursor.  The
-- class shorthands are handled by the two callers, which need them as sets.
escapeCode : PState -> Option Int
escapeCode st =
  advance st
  match peekAt st 0
    None =>
      failAt st "pattern ends in a backslash"
      None
    Some c =>
      advance st
      if c == 'n' then
        Some 10
      else if c == 't' then
        Some 9
      else if c == 'r' then
        Some 13
      else if c == 'x' then
        hexCode st 2
      else if c == 'u' then
        braceHexCode st
      else if c == 'p' || c == 'P' then
        failAt st "Unicode character classes are not supported"
        None
      else if isDigit c then
        failAt st "backreferences are not supported"
        None
      else if charIsAlpha c then
        failAt st "unknown escape sequence"
        None
      else
        Some (charCode c)

hexCode : PState -> Int -> Option Int
hexCode st n = hexGo st n 0

hexGo : PState -> Int -> Int -> Option Int
hexGo st n acc =
  if n <= 0 then
    Some acc
  else match peekAt st 0
    None =>
      failAt st "incomplete hexadecimal escape"
      None
    Some c => match hexValue c
      None =>
        failAt st "incomplete hexadecimal escape"
        None
      Some v =>
        advance st
        hexGo st (n - 1) (acc * 16 + v)

hexValue : Char -> Option Int
hexValue c =
  let n = charCode c
  if n >= 48 && n <= 57 then
    Some (n - 48)
  else if n >= 97 && n <= 102 then
    Some (n - 87)
  else if n >= 65 && n <= 70 then
    Some (n - 55)
  else
    None

braceHexCode : PState -> Option Int
braceHexCode st =
  if not (isAt st '{') then
    failAt st "\\u must be followed by a braced hexadecimal codepoint"
    None
  else
    advance st
    match braceHexGo st 0 0
      None => None
      Some code =>
        if code > maxCode then
          failAt st "codepoint is above the Unicode maximum"
          None
        else
          Some code

braceHexGo : PState -> Int -> Int -> Option Int
braceHexGo st seen acc =
  if isAt st '}' then
    advance st
    if seen == 0 then
      failAt st "\\u{} needs at least one hexadecimal digit"
      None
    else
      Some acc
  else match peekAt st 0
    None =>
      failAt st "\\u{ is missing its closing brace"
      None
    Some c => match hexValue c
      None =>
        failAt st "\\u{ is missing its closing brace"
        None
      Some v =>
        advance st
        braceHexGo st (seen + 1) (acc * 16 + v)

parseSet : PState -> Node
parseSet st =
  advance st
  let negated = setNegated st
  let rs = setItems st []
  if hasErr st then
    NEmpty
  else if isEmptyRanges rs then
    failAt st "empty character class"
    NEmpty
  else
    let folded = if st.fold then foldRanges rs else rs
    NSet (flattenRanges folded) negated

setNegated : PState -> Bool
setNegated st =
  if isAt st '^' then
    advance st
    True
  else
    False

isEmptyRanges : List (Int, Int) -> Bool
isEmptyRanges [] = True
isEmptyRanges _ = False

-- The accumulated ranges are a set, so nothing here keeps them in order or
-- merges overlaps; setMatches scans every pair.
setItems : PState -> List (Int, Int) -> List (Int, Int)
setItems st acc =
  if hasErr st then
    acc
  else if atEnd st then
    failAt st "character class is missing a closing ]"
    acc
  else if isAt st ']' then
    advance st
    acc
  else if isAt st '[' && peekIs st 1 ':' then
    failAt st "POSIX character classes are not supported"
    acc
  else match setItem st
    None => acc
    Some rs => setItems st (rs ++ acc)

setItem : PState -> Option (List (Int, Int))
setItem st =
  if isAt st '\\' then
    setEscapeItem st
  else
    let c = cur st
    advance st
    setRangeFrom st (charCode c)

setEscapeItem : PState -> Option (List (Int, Int))
setEscapeItem st = match peekAt st 1
  None =>
    advance st
    failAt st "pattern ends in a backslash"
    None
  Some c =>
    if c == 'd' then
      skip2 st (Some digitRanges)
    else if c == 'D' then
      skip2 st (Some (complementRanges digitRanges))
    else if c == 'w' then
      skip2 st (Some wordRanges)
    else if c == 'W' then
      skip2 st (Some (complementRanges wordRanges))
    else if c == 's' then
      skip2 st (Some spaceRanges)
    else if c == 'S' then
      skip2 st (Some (complementRanges spaceRanges))
    else match escapeCode st
      None => None
      Some code => setRangeFrom st code

-- A `-` directly before the closing bracket, or at the end of the pattern,
-- is a literal `-` rather than the start of a range.
setRangeFrom : PState -> Int -> Option (List (Int, Int))
setRangeFrom st lo =
  if isAt st '-' && not (peekIs st 1 ']') && !st.pos + 1 < patLen st then
    advance st
    match setSingle st
      None => None
      Some hi =>
        if lo <= hi then
          Some [(lo, hi)]
        else
          failAt st "character class range is reversed"
          None
  else
    Some [(lo, lo)]

setSingle : PState -> Option Int
setSingle st =
  if isAt st '\\' then
    escapeCode st
  else if atEnd st then
    failAt st "character class is missing a closing ]"
    None
  else
    let c = cur st
    advance st
    Some (charCode c)

-- # Program

data Inst =
  | IChar Int
  | ISet (Array Int) Bool
  | IAny Bool
  | ISplit Int Int
  | IJmp Int
  | ISave Int
  | IAssert Int
  | IMatch

-- Thompson construction with absolute targets: every node is told the
-- program counter its first instruction will sit at, and measures its own
-- children to place the jumps.  Concatenation nests to the right, so the
-- measuring stays linear in program size.
compileNode : Node -> Int -> List Inst
compileNode NEmpty _ = []
compileNode (NChar c) _ = [IChar c]
compileNode (NSet rs negated) _ = [ISet rs negated]
compileNode (NAny dotAll) _ = [IAny dotAll]
compileNode (NAssert kind) _ = [IAssert kind]
compileNode (NCat a b) pc =
  let ca = compileNode a pc
  ca ++ compileNode b (pc + length ca)
compileNode (NAlt a b) pc =
  let ca = compileNode a (pc + 1)
  let jmpAt = pc + 1 + length ca
  let cb = compileNode b (jmpAt + 1)
  let out = jmpAt + 1 + length cb
  ISplit (pc + 1) (jmpAt + 1) :: ca ++ (IJmp out :: cb)
compileNode (NStar greedy body) pc =
  let cb = compileNode body (pc + 1)
  let out = pc + 1 + length cb + 1
  let sp = if greedy then ISplit (pc + 1) out else ISplit out (pc + 1)
  sp :: cb ++ [IJmp pc]
compileNode (NPlus greedy body) pc =
  let cb = compileNode body pc
  let out = pc + length cb + 1
  let sp = if greedy then ISplit pc out else ISplit out pc
  cb ++ [sp]
compileNode (NOpt greedy body) pc =
  let cb = compileNode body (pc + 1)
  let out = pc + 1 + length cb
  let sp = if greedy then ISplit (pc + 1) out else ISplit out (pc + 1)
  sp :: cb
compileNode (NGroup idx body) pc =
  ISave (2 * idx) :: compileNode body (pc + 1) ++ [ISave (2 * idx + 1)]

-- # Pike VM

-- Slot 0 and 1 hold the whole match and are written by the VM itself; group
-- k owns slots 2k and 2k+1, written by ISave.
data Vm = Vm {
  prog : Array Inst,
  codes : Array Int,
  subjStart : Int,
  subjEnd : Int,
  multi : Bool,
  anchorEnd : Bool,
  nslots : Int,
  steps : Ref Int,
  found : Ref (Option (Array Int)),
}

-- A thread list is a sparse set: `mark[pc] == gen` says pc is already in
-- this list, so each pc is added at most once per position and a step costs
-- O(m).  The first thread to claim a pc is the highest-priority one, which
-- is what makes the dedup safe.
data ThreadList = ThreadList {
  dense : Array Int,
  slots : Array (Array Int),
  live : Ref Int,
  mark : Array Int,
  gen : Ref Int,
}

noSlots : Array Int
noSlots = [||]

newThreads : Int -> ThreadList
newThreads n = ThreadList {
  dense = arrayMake n 0,
  slots = arrayMake n noSlots,
  live = Ref 0,
  mark = arrayMake n 0,
  gen = Ref 1,
}

resetThreads : ThreadList -> Unit
resetThreads list =
  list.live := 0
  list.gen := !list.gen + 1

foundYet : Vm -> Bool
foundYet vm = match !vm.found
  Some _ => True
  None => False

addThread : Vm -> ThreadList -> Int -> Int -> Array Int -> Unit
addThread vm list pc pos slots =
  vm.steps := !vm.steps + 1
  if arrayGetUnsafe pc list.mark == !list.gen then
    ()
  else
    arraySetUnsafe pc !list.gen list.mark
    match arrayGetUnsafe pc vm.prog
      IJmp x => addThread vm list x pos slots
      ISplit x y =>
        addThread vm list x pos slots
        addThread vm list y pos slots
      ISave n =>
        let written = arrayCopy slots
        arraySetUnsafe n pos written
        addThread vm list (pc + 1) pos written
      IAssert kind =>
        if assertHolds vm kind pos then addThread vm list (pc + 1) pos slots
      _ =>
        let i = !list.live
        arraySetUnsafe i pc list.dense
        arraySetUnsafe i slots list.slots
        list.live := i + 1

assertHolds : Vm -> Int -> Int -> Bool
assertHolds vm kind pos =
  if kind == asStart then
    pos == vm.subjStart || vm.multi && arrayGetUnsafe (pos - 1) vm.codes == 10
  else if kind == asEnd then
    pos == vm.subjEnd || vm.multi && arrayGetUnsafe pos vm.codes == 10
  else if kind == asWordB then
    wordAt vm (pos - 1) /= wordAt vm pos
  else
    wordAt vm (pos - 1) == wordAt vm pos

wordAt : Vm -> Int -> Bool
wordAt vm i =
  i >= vm.subjStart && i < vm.subjEnd && isWordCode (arrayGetUnsafe i vm.codes)

-- One position's worth of work: advance every thread past the code at `pos`
-- into `nlist`.  A thread reaching IMatch records its slots and cuts every
-- lower-priority thread, which is leftmost-first; a higher-priority thread
-- already in nlist may still overwrite that record later, which is what
-- makes greedy repetition win.
stepThreads : Vm -> ThreadList -> ThreadList -> Int -> Int -> Unit
stepThreads vm clist nlist pos i =
  if i >= !clist.live then
    ()
  else
    let pc = arrayGetUnsafe i clist.dense
    let slots = arrayGetUnsafe i clist.slots
    match arrayGetUnsafe pc vm.prog
      IChar ch =>
        if pos < vm.subjEnd && arrayGetUnsafe pos vm.codes == ch then
          addThread vm nlist (pc + 1) (pos + 1) slots
        stepThreads vm clist nlist pos (i + 1)
      ISet rs negated =>
        if pos < vm.subjEnd
          && setMatches rs negated (arrayGetUnsafe pos vm.codes) then
          addThread vm nlist (pc + 1) (pos + 1) slots
        stepThreads vm clist nlist pos (i + 1)
      IAny dotAll =>
        if pos < vm.subjEnd
          && (dotAll || arrayGetUnsafe pos vm.codes /= 10) then
          addThread vm nlist (pc + 1) (pos + 1) slots
        stepThreads vm clist nlist pos (i + 1)
      IMatch =>
        if vm.anchorEnd && pos /= vm.subjEnd then
          stepThreads vm clist nlist pos (i + 1)
        else
          let done = arrayCopy slots
          arraySetUnsafe 1 pos done
          vm.found := Some done
      _ => stepThreads vm clist nlist pos (i + 1)

-- A fresh thread is seeded at every position until a match is found, at the
-- end of the list so it loses to everything already running: that is the
-- leftmost half of leftmost-first.  Under anchorStart only the first
-- position is seeded.
seedThread : Vm -> ThreadList -> Int -> Int -> Bool -> Unit
seedThread vm clist pos startAt anchorStart =
  if foundYet vm || anchorStart && pos /= startAt then
    ()
  else
    let slots = arrayMake vm.nslots (-1)
    arraySetUnsafe 0 pos slots
    addThread vm clist 0 pos slots

vmSearch : Vm -> Int -> Bool -> Option (Array Int)
vmSearch vm startAt anchorStart =
  let n = arrayLength vm.prog
  vmLoop vm startAt anchorStart startAt (newThreads n) (newThreads n)

vmLoop : Vm ->
  Int ->
  Bool ->
  Int ->
  ThreadList ->
  ThreadList ->
  Option (Array Int)
vmLoop vm startAt anchorStart pos clist nlist =
  seedThread vm clist pos startAt anchorStart
  if !clist.live == 0 && (foundYet vm || anchorStart) then
    !vm.found
  else
    resetThreads nlist
    stepThreads vm clist nlist pos 0
    if pos >= vm.subjEnd then
      !vm.found
    else
      vmLoop vm startAt anchorStart (pos + 1) nlist clist

codesOf : String -> Array Int
codesOf s =
  let cs = toChars s
  arrayMakeWith (arrayLength cs) (i => charCode (arrayGetUnsafe i cs))

searchFrom : Regex ->
  Array Int ->
  Int ->
  Bool ->
  Bool ->
  Ref Int ->
  Option (Array Int)
searchFrom re codes startAt anchorStart anchorEnd steps =
  searchWindow
    re
    codes
    (0, arrayLength codes)
    startAt
    anchorStart
    anchorEnd
    steps

-- The window is what the byte front door needs: a validator holding one
-- buffer grades a slice of it without copying, and `^`, `$` and `\b` mean the
-- ends of the WINDOW, not of the buffer, so a slice grades the same as that
-- slice standing alone.
searchWindow : Regex ->
  Array Int ->
  (Int, Int) ->
  Int ->
  Bool ->
  Bool ->
  Ref Int ->
  Option (Array Int)
searchWindow re codes (lo, hi) startAt anchorStart anchorEnd steps =
  let vm = Vm {
    prog = re.prog,
    codes = codes,
    subjStart = lo,
    subjEnd = hi,
    multi = re.multiline,
    anchorEnd = anchorEnd,
    nslots = 2 * (re.ngroups + 1),
    steps = steps,
    found = Ref None,
  }
  vmSearch vm startAt anchorStart

-- `[lo, hi)` narrowed to the array, with `lo` never past `hi`, so no caller
-- can hand the VM a window that indexes outside the buffer.
clampWindow : Array Int -> Int -> Int -> (Int, Int)
clampWindow codes start end =
  let n = arrayLength codes
  let hi = max 0 (min end n)
  (max 0 (min start hi), hi)

-- Threads added to a list over one `find`.  The linear-time doctest at the
-- bottom of this module is the only caller; it exists so the bound can be
-- pinned by a count rather than by a clock.
findSteps : Regex -> String -> Int
findSteps re s =
  let steps = Ref 0
  let _ = searchFrom re (codesOf s) 0 False False steps
  !steps

-- `textOf lo hi` renders one span: a String subject slices itself, a byte
-- subject decodes the span, and the span walk is written once either way.
mkMatchWith : (Int -> Int -> String) -> Regex -> Array Int -> Match
mkMatchWith textOf re slots =
  let lo = arrayGetUnsafe 0 slots
  let hi = arrayGetUnsafe 1 slots
  Match {
    start = lo,
    end = hi,
    text = textOf lo hi,
    groups = groupsOfWith textOf re slots 1,
  }

groupsOfWith : (Int -> Int -> String) ->
  Regex ->
  Array Int ->
  Int ->
  List (Option Group)
groupsOfWith textOf re slots k =
  if k > re.ngroups then
    []
  else
    let lo = arrayGetUnsafe (2 * k) slots
    let hi = arrayGetUnsafe (2 * k + 1) slots
    let g =
      if lo < 0 || hi < 0 then
        None
      else
        Some Group { start = lo, end = hi, text = textOf lo hi }
    g :: groupsOfWith textOf re slots (k + 1)

mkMatch : Regex -> String -> Array Int -> Match
mkMatch re s slots = mkMatchWith (lo hi => sliceClamped lo hi s) re slots

matchOnce : Regex -> String -> Int -> Bool -> Bool -> Option Match
matchOnce re s startAt anchorStart anchorEnd =
  map
    (mkMatch re s)
    (searchFrom re (codesOf s) startAt anchorStart anchorEnd (Ref 0))

-- # Compiling a pattern

{- | The pattern compiled, or an `Err` naming what is wrong and where.

   > map source (compile "a+b")
   Ok "a+b"
   > compile "a("
   Err RegexError { message = "pattern is missing a closing )", position = 2 } -}
export
compile : String -> Result RegexError Regex
compile pattern =
  let cs = toChars pattern
  let (start, fold, multi, dotAll) = scanFlags cs 0 False False False
  let st = PState {
    pat = cs,
    pos = Ref start,
    ngroups = Ref 0,
    perr = Ref None,
    fold = fold,
    dotAll = dotAll,
  }
  let node = parseAlt st
  finishCompile st node pattern multi

finishCompile : PState -> Node -> String -> Bool -> Result RegexError Regex
finishCompile st node pattern multi = match !st.perr
  Some e => Err e
  None =>
    if not (atEnd st) then
      Err RegexError { message = "unbalanced closing )", position = !st.pos }
    else
      let insts = compileNode node 0 ++ [IMatch]
      if length insts > progCap then
        Err RegexError {
          message = "pattern compiles to more than 20000 instructions",
          position = 0,
        }
      else
        Ok Regex {
          src = pattern,
          prog = arrayFromList insts,
          ngroups = !st.ngroups,
          multiline = multi,
        }

-- > compile "["
-- Err RegexError { message = "character class is missing a closing ]", position = 1 }
-- > compile "a{3,2}"
-- Err RegexError { message = "repetition bounds are out of order", position = 6 }
-- > compile "a{1001}"
-- Err RegexError { message = "repetition bound is larger than the maximum of 1000", position = 7 }
-- > compile "*a"
-- Err RegexError { message = "repetition operator with nothing to repeat", position = 0 }
-- > compile "a)b"
-- Err RegexError { message = "unbalanced closing )", position = 1 }
-- > compile "(a)\\1"
-- Err RegexError { message = "backreferences are not supported", position = 5 }
-- > compile "(?=a)"
-- Err RegexError { message = "lookahead is not supported", position = 1 }
-- > compile "(?<n>a)"
-- Err RegexError { message = "named groups and lookbehind are not supported", position = 1 }
-- > compile "[[:alpha:]]"
-- Err RegexError { message = "POSIX character classes are not supported", position = 1 }
-- > compile "\\p{L}"
-- Err RegexError { message = "Unicode character classes are not supported", position = 2 }
-- > compile "a(?i)b"
-- Err RegexError { message = "flags are only allowed at the start of the pattern", position = 2 }
-- > compile "[z-a]"
-- Err RegexError { message = "character class range is reversed", position = 4 }
-- > compile "a\\"
-- Err RegexError { message = "pattern ends in a backslash", position = 2 }
-- > compile "\\q"
-- Err RegexError { message = "unknown escape sequence", position = 2 }

-- An unmatched `{` is a literal, so these compile.
-- > map source (compile "a{")
-- Ok "a{"
-- > map source (compile "a{2,")
-- Ok "a{2,"
-- > isMatch (mustCompile "a{2") "a{2"
-- True

{- | The pattern compiled, panicking when it does not compile.

   For a pattern written as a literal, where a failure is a mistake in the
   program rather than in the data. A top-level binding is evaluated once, so
   the compilation happens one time. Use `compile` for a pattern that comes
   from input.

   > source (mustCompile "[0-9]+")
   "[0-9]+" -}
export
mustCompile : String -> Regex
mustCompile pattern = match compile pattern
  Ok re => re
  Err e =>
    panic
      "regex: \{e.message} at position \{intToString e.position} in \{debugStringLit pattern}"

{- | The pattern the regex was compiled from.

   > source (mustCompile "^\\d+$")
   "^\\d+$" -}
export
source : Regex -> String
source re = re.src

{- | The text as a pattern matching exactly itself, every metacharacter
   quoted.

   This is how a literal, a glob, or a SQL `LIKE` pattern becomes a regex:
   translate the wildcards and send everything else through `escape`.

   > escape "a.b*c"
   "a\\.b\\*c"
   > isFullMatch (mustCompile (escape "1+1=2")) "1+1=2"
   True -}
export
escape : String -> String
escape s = fromChars (escapeGo (toChars s) 0)

escapeGo : Array Char -> Int -> List Char
escapeGo cs i =
  if i >= arrayLength cs then
    []
  else
    let c = arrayGetUnsafe i cs
    if isMeta c then
      '\\' :: c :: escapeGo cs (i + 1)
    else
      c :: escapeGo cs (i + 1)

isMeta : Char -> Bool
isMeta c =
  c == '\\'
    || c == '.'
    || c == '+'
    || c == '*'
    || c == '?'
    || c == '('
    || c == ')'
    || c == '|'
    || c == '['
    || c == ']'
    || c == '{'
    || c == '}'
    || c == '^'
    || c == '$'

-- # Matching

{- | Whether the pattern matches anywhere in the subject.

   > isMatch (mustCompile "\\d") "abc7"
   True
   > isMatch (mustCompile "\\d") "abc"
   False -}
export
isMatch : Regex -> String -> Bool
isMatch re s = match searchFrom re (codesOf s) 0 False False (Ref 0)
  Some _ => True
  None => False

{- | Whether the pattern matches the whole subject.

   The validator shape: anchored at both ends, so a pattern that would match
   a prefix does not pass. Among the whole-subject matches the pattern still
   picks its preferred one, so `isFullMatch` is not `isMatch` of an anchored
   pattern with a shorter alternative first.

   > isFullMatch (mustCompile "[a-z]+") "abc"
   True
   > isFullMatch (mustCompile "[a-z]+") "abc1"
   False -}
export
isFullMatch : Regex -> String -> Bool
isFullMatch re s = match searchFrom re (codesOf s) 0 True True (Ref 0)
  Some _ => True
  None => False

{- | The leftmost match, or `None` when the pattern does not match.

   > find (mustCompile "\\d+") "ab123cd"
   Some Match { start = 2, end = 5, text = "123", groups = [] }
   > find (mustCompile "z") "ab"
   None -}
export
find : Regex -> String -> Option Match
find re s = matchOnce re s 0 False False

-- Leftmost-first, not leftmost-longest: the alternation's order decides.
-- > map (m => m.text) (find (mustCompile "a|ab") "ab")
-- Some "a"
-- > map (m => m.text) (find (mustCompile "ab|a") "ab")
-- Some "ab"
-- > map (m => m.text) (find (mustCompile "a+") "aaa")
-- Some "aaa"
-- > map (m => m.text) (find (mustCompile "a+?") "aaa")
-- Some "a"
-- > map (m => m.text) (find (mustCompile "<.+>") "<a><b>")
-- Some "<a><b>"
-- > map (m => m.text) (find (mustCompile "<.+?>") "<a><b>")
-- Some "<a>"

{- | The leftmost match that starts at or after `from`.

   `from` is clamped to the subject. `^` and `$` still mean the ends of the
   whole subject, not of the searched tail.

   > map (m => m.start) (findFrom 3 (mustCompile "a") "aaaaa")
   Some 3
   > findFrom 3 (mustCompile "^a") "aaaaa"
   None -}
export
findFrom : Int -> Regex -> String -> Option Match
findFrom from re s =
  let n = stringLength s
  let at = max 0 (min from n)
  matchOnce re s at False False

{- | The match covering the whole subject, or `None`.

   > map (m => m.text) (fullMatch (mustCompile "a|ab") "ab")
   Some "ab"
   > fullMatch (mustCompile "a") "ab"
   None -}
export
fullMatch : Regex -> String -> Option Match
fullMatch re s = matchOnce re s 0 True True

-- # Byte subjects
--
-- One engine, two front doors.  A site holding a UTF-8 byte buffer grades a
-- window of it directly, with each byte taken as a code 0..255, rather than
-- decoding back to a String to be re-encoded as codepoints.

{- | Whether the pattern matches the whole of `bytes[start..end)`, each byte
   taken as a code 0..255.

   The validator shape for a byte buffer, and the reason a protocol grammar
   wants this door: a bound written into the pattern counts BYTES, which is
   what a DNS label, a DID or an RFC 7230 token means by its limits, and the
   window grades a slice of a larger buffer without copying it. `start` and
   `end` are clamped to the buffer, and `^`, `$` and `\b` mean the ends of the
   window.

   A pattern reaching this door should name only ASCII: `[a-z]` matches the
   byte 97, and a non-ASCII codepoint arrives as its two or more UTF-8 bytes,
   each of them outside every ASCII class. `toUtf8 "abc"` is `[|97, 98, 99|]`.

   > isFullMatchBytes (mustCompile "[a-z]+") [|97, 98, 99|] 0 3
   True
   > isFullMatchBytes (mustCompile "[a-z]+") [|97, 98, 99, 46|] 0 3
   True
   > isFullMatchBytes (mustCompile "[a-z]+") [|97, 98, 99, 46|] 0 4
   False -}
export
isFullMatchBytes : Regex -> Array Int -> Int -> Int -> Bool
isFullMatchBytes re bytes start end =
  let (lo, hi) = clampWindow bytes start end
  match searchWindow re bytes (lo, hi) lo True True (Ref 0)
    Some _ => True
    None => False

-- An out-of-range window is shorter, never a panic, and an empty one matches
-- only a pattern that can match nothing.
-- > isFullMatchBytes (mustCompile "[a-z]*") [|97|] 0 99
-- True
-- > isFullMatchBytes (mustCompile "[a-z]*") [|97|] 5 1
-- True
-- > isFullMatchBytes (mustCompile "[a-z]+") [|97|] 5 1
-- False

-- `^` and `$` are the ends of the WINDOW, so a slice grades as that slice
-- standing alone.
-- > isFullMatchBytes (mustCompile "^b$") [|97, 98, 99|] 1 2
-- True

{- | The leftmost match in `bytes[start..end)`, or `None`.

   The peer of `find` over a byte buffer. `start`, `end` and the reported
   offsets are byte offsets into the whole buffer, and the match's text and
   each group's text are the matched bytes decoded as UTF-8, so a span that
   cuts a codepoint decodes the way `fromUtf8` decodes any malformed input.
   Keeping byte patterns ASCII is what keeps that from arising.

   > map (m => m.text) (findBytes (mustCompile "[0-9]+") [|97, 49, 50, 98|] 0 4)
   Some "12"
   > map (m => m.start) (findBytes (mustCompile "[0-9]+") [|97, 49, 50, 98|] 0 4)
   Some 1
   > findBytes (mustCompile "[0-9]+") [|97, 49, 50, 98|] 0 1
   None -}
export
findBytes : Regex -> Array Int -> Int -> Int -> Option Match
findBytes re bytes start end =
  let (lo, hi) = clampWindow bytes start end
  map
    (mkMatchWith (from to => fromUtf8 (sliceBytes from to bytes)) re)
    (searchWindow re bytes (lo, hi) lo False False (Ref 0))

{- | Every match, left to right, none of them overlapping.

   An empty match is kept, except directly at the end of the previous match:
   `\d*` over `"a1b"` reports the empty match before `a`, `"1"`, and the
   empty match at the end.

   > map (m => m.text) (findAll (mustCompile "\\d+") "a1b22c")
   ["1", "22"]
   > map (m => m.text) (findAll (mustCompile "\\d*") "a1b")
   ["", "1", ""] -}
export
findAll : Regex -> String -> List Match
findAll re s = reverse (findAllGo re s (codesOf s) 0 (-1) [])

-- An empty match advances the cursor one codepoint, and one sitting exactly
-- where the previous match ended is dropped, so `a*` over "abc" reports "a"
-- and then the empties at 2 and 3 but not the one at 1.
findAllGo : Regex ->
  String ->
  Array Int ->
  Int ->
  Int ->
  List Match ->
  List Match
findAllGo re s codes pos prevEnd acc =
  if pos > arrayLength codes then
    acc
  else match searchFrom re codes pos False False (Ref 0)
    None => acc
    Some slots =>
      let lo = arrayGetUnsafe 0 slots
      let hi = arrayGetUnsafe 1 slots
      let keep = not (hi == lo && lo == prevEnd)
      let next = if hi == lo then lo + 1 else hi
      let acc2 = if keep then mkMatch re s slots :: acc else acc
      findAllGo re s codes next hi acc2

-- > map (m => m.text) (findAll (mustCompile "a*") "baaab")
-- ["", "aaa", ""]
-- > map (m => (m.start, m.end)) (findAll (mustCompile "a*") "baaab")
-- [(0, 0), (1, 4), (5, 5)]
-- > map (m => m.text) (findAll (mustCompile "") "abc")
-- ["", "", "", ""]

-- # Groups

-- > map (m => m.groups) (find (mustCompile "(a)(b)") "ab")
-- Some [Some Group { start = 0, end = 1, text = "a" }, Some Group { start = 1, end = 2, text = "b" }]

-- A group that did not take part in the match is None.
-- > map (m => m.groups) (find (mustCompile "(a)|b") "b")
-- Some [None]

-- The classic leftmost-first submatch: `a` then `bcd`, not `ab` then `cd`.
-- > map (m => map (g => map (g2 => g2.text) g) m.groups) (find (mustCompile "(a|ab)(c|bcd)") "abcd")
-- Some [Some "a", Some "bcd"]

-- The last iteration of a repeated group is the one that is reported.
-- > map (m => map (g => map (g2 => g2.text) g) m.groups) (find (mustCompile "(a|b)*") "ab")
-- Some [Some "b"]
-- > map (m => map (g => map (g2 => (g2.start, g2.end)) g) m.groups) (find (mustCompile "(a*)(a*)") "aa")
-- Some [Some (0, 2), Some (2, 2)]

-- # Replacing and splitting

{- | The subject with the first match replaced by `repl`.

   In `repl`, `$0` is the whole match, `$1` to `$9` are the capture groups,
   and `$$` is a literal `$`. A group that did not take part expands to the
   empty string, and a `$` before anything else is itself.

   > replace (mustCompile "\\d+") "N" "a1b2"
   "aNb2"
   > replace (mustCompile "(\\w+)@(\\w+)") "$2/$1" "user@host"
   "host/user" -}
export
replace : Regex -> String -> String -> String
replace re repl s = match find re s
  None => s
  Some m =>
    sliceClamped 0 m.start s
      ++ expandRepl repl m
      ++ sliceClamped m.end (stringLength s) s

{- | The subject with every match replaced by `repl`.

   `repl` expands as in `replace`.

   > replaceAll (mustCompile "\\s+") " " "a  b\tc"
   "a b c"
   > replaceAll (mustCompile "a*") "-" "abc"
   "-b-c-" -}
export
replaceAll : Regex -> String -> String -> String
replaceAll re repl s = replaceAllWith re (m => expandRepl repl m) s

{- | The subject with every match replaced by `f` applied to it.

   Nothing in the result is rescanned, so a replacement that looks like the
   pattern is left alone.

   > replaceAllWith (mustCompile "\\d") (m => "[" ++ m.text ++ "]") "a1b2"
   "a[1]b[2]" -}
export
replaceAllWith : Regex -> (Match -> <e> String) -> String -> <e> String
replaceAllWith re f s = stringConcat (reverse (stitch f s (findAll re s) 0 []))

stitch : (Match -> <e> String) ->
  String ->
  List Match ->
  Int ->
  List String ->
  <e> List String
stitch _ s [] beg acc = sliceClamped beg (stringLength s) s :: acc
stitch f s (m :: rest) beg acc =
  let piece = sliceClamped beg m.start s
  let replaced = f m
  stitch f s rest m.end (replaced :: piece :: acc)

expandRepl : String -> Match -> String
expandRepl repl m = stringConcat (reverse (expandGo (toChars repl) 0 m []))

expandGo : Array Char -> Int -> Match -> List String -> List String
expandGo cs i m acc =
  if i >= arrayLength cs then
    acc
  else
    let c = arrayGetUnsafe i cs
    if c == '$' && i + 1 < arrayLength cs then
      let d = arrayGetUnsafe (i + 1) cs
      if d == '$' then
        expandGo cs (i + 2) m ("$" :: acc)
      else if isDigit d then
        expandGo cs (i + 2) m (groupText m (charCode d - 48) :: acc)
      else
        expandGo cs (i + 1) m ("$" :: acc)
    else
      expandGo cs (i + 1) m (charToStr c :: acc)

groupText : Match -> Int -> String
groupText m 0 = m.text
groupText m k = match get (k - 1) m.groups
  Some (Some g) => g.text
  _ => ""

{- | The subject cut at every match, with the matches dropped.

   A leading or trailing separator leaves an empty piece, as `string.split`
   does, so joining the pieces back with a literal separator recovers the
   subject. A subject with no match is returned whole.

   > split (mustCompile ",\\s*") "a, b,c"
   ["a", "b", "c"]
   > split (mustCompile ",") ",a,"
   ["", "a", ""] -}
export
split : Regex -> String -> List String
split re s = reverse (splitGo s (findAll re s) 0 0 [])

splitGo : String -> List Match -> Int -> Int -> List String -> List String
splitGo s [] beg lastStart acc =
  if lastStart /= stringLength s then
    sliceClamped beg (stringLength s) s :: acc
  else
    acc
splitGo s (m :: rest) beg _ acc =
  let acc2 = if m.end /= 0 then sliceClamped beg m.start s :: acc else acc
  splitGo s rest m.end m.start acc2

-- > split (mustCompile ",") "abc"
-- ["abc"]
-- > split (mustCompile "") "abc"
-- ["a", "b", "c"]

-- # Anchors, classes, and flags

-- > map (m => (m.start, m.end)) (find (mustCompile "^a*") "aab")
-- Some (0, 2)
-- > map (m => m.start) (find (mustCompile "$") "abc")
-- Some 3
-- > isFullMatch (mustCompile "^abc$") "abc"
-- True
-- > map (m => m.text) (find (mustCompile "\\bfoo\\b") "a foo bar")
-- Some "foo"
-- > isMatch (mustCompile "\\bfoo\\b") "foobar"
-- False
-- > map (m => m.text) (find (mustCompile "\\Bar\\b") "foobar")
-- Some "ar"
-- > map (m => m.text) (find (mustCompile "[^a-z]+") "abc123")
-- Some "123"
-- > map (m => m.text) (find (mustCompile "[\\d.]+") "x3.14y")
-- Some "3.14"
-- > isMatch (mustCompile ".") "\n"
-- False
-- > isMatch (mustCompile "(?s).") "\n"
-- True
-- > map (m => m.start) (find (mustCompile "(?m)^b") "a\nb")
-- Some 2
-- > map (m => m.text) (find (mustCompile "(?i)AbC") "xxabcyy")
-- Some "abc"
-- > isFullMatch (mustCompile "(?i)[a-z]+") "AbC"
-- True
-- > isFullMatch (mustCompile "(?i)[^a-z]+") "AbC"
-- False
-- > map (m => m.text) (find (mustCompile "a{2,3}") "aaaa")
-- Some "aaa"
-- > map (m => m.text) (find (mustCompile "a{2,3}?") "aaaa")
-- Some "aa"
-- > map (m => m.text) (find (mustCompile "a{2}") "aaaa")
-- Some "aa"
-- > map (m => m.text) (find (mustCompile "a{2,}") "aaaa")
-- Some "aaaa"
-- > map (m => m.text) (find (mustCompile "\\x41\\u{42}") "xABy")
-- Some "AB"

-- # Linear time

-- `(a*)*b` and `(a|a)*b` are the two patterns a backtracking engine dies
-- on: either takes exponential time against a run of `a` with no `b` after
-- it.  Every program counter enters a thread list at most once per subject
-- position, so the thread-add count is bounded by a small constant times
-- subject length times program size -- here 50008 and 55006 against
-- 5000 * 9 = 45000 and 5000 * 10 = 50000, about 1.1x each.  The pairs below
-- are (program size, thread-adds): they are a measurement, so a deliberate
-- change to the emitted program moves them, but a change that loses the
-- sparse-set dedup or the priority cut moves the second number by orders of
-- magnitude rather than by ones.
-- > find (mustCompile "(a*)*b") (repeat 5000 "a")
-- None

-- > find (mustCompile "(a|a)*b") (repeat 5000 "a")
-- None

-- > (arrayLength (mustCompile "(a*)*b").prog, findSteps (mustCompile "(a*)*b") (repeat 5000 "a"))
-- (9, 50008)

-- > (arrayLength (mustCompile "(a|a)*b").prog, findSteps (mustCompile "(a|a)*b") (repeat 5000 "a"))
-- (10, 55006)

-- # Properties

prop "escape s full-matches exactly s" (s : String) =
  isFullMatch (mustCompile (escape s)) s

prop "split on a literal separator rejoins to the subject" (s : String) =
  stringConcat (intersperseComma (split commaRe s)) == s

commaRe : Regex
commaRe = mustCompile ","

intersperseComma : List String -> List String
intersperseComma [] = []
intersperseComma (x :: []) = [x]
intersperseComma (x :: rest) = x :: "," :: intersperseComma rest

prop "findAll spans are ascending and disjoint" (s : String) =
  spansOrdered (findAll (mustCompile "[a-z]+|.") s) 0

spansOrdered : List Match -> Int -> Bool
spansOrdered [] _ = True
spansOrdered (m :: rest) floor =
  m.start >= floor && m.end >= m.start && spansOrdered rest m.end
# DESUGAR
(DUse false (UseGroup ("array") ((mem "sliceClamped" false "sliceBytes"))))
(DUse false (UseGroup ("list") ((mem "get" false) (mem "reverse" false))))
(DUse false (UseGroup ("string") ((mem "fromChars" false) (mem "fromUtf8" false) (mem "isDigit" false) (mem "repeat" false) (mem "sliceClamped" false) (mem "toChars" false))))
(DData Abstract "Regex" () ((variant "Regex" (ConNamed (field "src" (TyCon "String")) (field "prog" (TyApp (TyCon "Array") (TyCon "Inst"))) (field "ngroups" (TyCon "Int")) (field "multiline" (TyCon "Bool"))))) ())
(DData Public "RegexError" () ((variant "RegexError" (ConNamed (field "message" (TyCon "String")) (field "position" (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "RegexError")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "RegexError" ((rf "message" (PVar "__a0")) (rf "position" (PVar "__a1"))) false) (PRec "RegexError" ((rf "message" (PVar "__b0")) (rf "position" (PVar "__b1"))) false)) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Debug" ((TyCon "RegexError")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "RegexError" ((rf "message" (PVar "__a0")) (rf "position" (PVar "__a1"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "RegexError {")) (ELit (LString " message = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", position = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString " }"))))))))
(DData Public "Group" () ((variant "Group" (ConNamed (field "start" (TyCon "Int")) (field "end" (TyCon "Int")) (field "text" (TyCon "String"))))) ())
(DImpl true "Eq" ((TyCon "Group")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Group" ((rf "start" (PVar "__a0")) (rf "end" (PVar "__a1")) (rf "text" (PVar "__a2"))) false) (PRec "Group" ((rf "start" (PVar "__b0")) (rf "end" (PVar "__b1")) (rf "text" (PVar "__b2"))) false)) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))))))))
(DImpl true "Debug" ((TyCon "Group")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "Group" ((rf "start" (PVar "__a0")) (rf "end" (PVar "__a1")) (rf "text" (PVar "__a2"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Group {")) (ELit (LString " start = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", end = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", text = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString " }"))))))))
(DData Public "Match" () ((variant "Match" (ConNamed (field "start" (TyCon "Int")) (field "end" (TyCon "Int")) (field "text" (TyCon "String")) (field "groups" (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Group"))))))) ())
(DImpl true "Eq" ((TyCon "Match")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Match" ((rf "start" (PVar "__a0")) (rf "end" (PVar "__a1")) (rf "text" (PVar "__a2")) (rf "groups" (PVar "__a3"))) false) (PRec "Match" ((rf "start" (PVar "__b0")) (rf "end" (PVar "__b1")) (rf "text" (PVar "__b2")) (rf "groups" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "Match")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "Match" ((rf "start" (PVar "__a0")) (rf "end" (PVar "__a1")) (rf "text" (PVar "__a2")) (rf "groups" (PVar "__a3"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Match {")) (ELit (LString " start = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", end = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", text = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString ", groups = "))) (EApp (EVar "debug") (EVar "__a3"))) (ELit (LString " }"))))))))
(DImpl true "Debug" ((TyCon "Regex")) () ((im "debug" ((PVar "re")) (EBinOp "++" (ELit (LString "regex ")) (EApp (EVar "debugStringLit") (EFieldAccess (EVar "re") "src"))))))
(DTypeSig false "maxCode" (TyCon "Int"))
(DFunDef false "maxCode" () (ELit (LInt 1114111)))
(DTypeSig false "digitRanges" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "digitRanges" () (EListLit (ETuple (ELit (LInt 48)) (ELit (LInt 57)))))
(DTypeSig false "wordRanges" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "wordRanges" () (EListLit (ETuple (ELit (LInt 48)) (ELit (LInt 57))) (ETuple (ELit (LInt 65)) (ELit (LInt 90))) (ETuple (ELit (LInt 95)) (ELit (LInt 95))) (ETuple (ELit (LInt 97)) (ELit (LInt 122)))))
(DTypeSig false "spaceRanges" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "spaceRanges" () (EListLit (ETuple (ELit (LInt 9)) (ELit (LInt 10))) (ETuple (ELit (LInt 13)) (ELit (LInt 13))) (ETuple (ELit (LInt 32)) (ELit (LInt 32)))))
(DTypeSig false "wordSet" (TyApp (TyCon "Array") (TyCon "Int")))
(DFunDef false "wordSet" () (EApp (EVar "flattenRanges") (EVar "wordRanges")))
(DTypeSig false "flattenRanges" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "flattenRanges" ((PVar "rs")) (EApp (EVar "arrayFromList") (EApp (EVar "flattenGo") (EVar "rs"))))
(DTypeSig false "flattenGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "flattenGo" ((PList)) (EListLit))
(DFunDef false "flattenGo" ((PCons (PTuple (PVar "lo") (PVar "hi")) (PVar "rest"))) (EBinOp "::" (EVar "lo") (EBinOp "::" (EVar "hi") (EApp (EVar "flattenGo") (EVar "rest")))))
(DTypeSig false "complementRanges" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "complementRanges" ((PVar "rs")) (EApp (EApp (EVar "complementGo") (EVar "rs")) (ELit (LInt 0))))
(DTypeSig false "complementGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "complementGo" ((PList) (PVar "next")) (EIf (EBinOp ">" (EVar "next") (EVar "maxCode")) (EListLit) (EListLit (ETuple (EVar "next") (EVar "maxCode")))))
(DFunDef false "complementGo" ((PCons (PTuple (PVar "lo") (PVar "hi")) (PVar "rest")) (PVar "next")) (EBlock (DoLet false false (PVar "after") (EApp (EApp (EVar "max") (EBinOp "+" (EVar "hi") (ELit (LInt 1)))) (EVar "next"))) (DoExpr (EIf (EBinOp ">" (EVar "lo") (EVar "next")) (EBinOp "::" (ETuple (EVar "next") (EBinOp "-" (EVar "lo") (ELit (LInt 1)))) (EApp (EApp (EVar "complementGo") (EVar "rest")) (EVar "after"))) (EApp (EApp (EVar "complementGo") (EVar "rest")) (EVar "after"))))))
(DTypeSig false "inRanges" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "inRanges" ((PVar "rs") (PVar "i") (PVar "c")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "rs"))) (EVar "False") (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "rs"))) (EBinOp "<=" (EVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rs")))) (EVar "True") (EApp (EApp (EApp (EVar "inRanges") (EVar "rs")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "c")))))
(DTypeSig false "setMatches" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "setMatches" ((PVar "rs") (PVar "negated") (PVar "c")) (EIf (EVar "negated") (EApp (EVar "not") (EApp (EApp (EApp (EVar "inRanges") (EVar "rs")) (ELit (LInt 0))) (EVar "c"))) (EApp (EApp (EApp (EVar "inRanges") (EVar "rs")) (ELit (LInt 0))) (EVar "c"))))
(DTypeSig false "isWordCode" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isWordCode" ((PVar "c")) (EApp (EApp (EApp (EVar "inRanges") (EVar "wordSet")) (ELit (LInt 0))) (EVar "c")))
(DTypeSig false "isAsciiLetterCode" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isAsciiLetterCode" ((PVar "c")) (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LInt 65))) (EBinOp "<=" (EVar "c") (ELit (LInt 90)))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LInt 97))) (EBinOp "<=" (EVar "c") (ELit (LInt 122))))))
(DTypeSig false "foldRanges" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "foldRanges" ((PList)) (EListLit))
(DFunDef false "foldRanges" ((PCons (PTuple (PVar "lo") (PVar "hi")) (PVar "rest"))) (EBlock (DoLet false false (PVar "upper") (EApp (EApp (EApp (EApp (EApp (EVar "clipShift") (EVar "lo")) (EVar "hi")) (ELit (LInt 97))) (ELit (LInt 122))) (EUnOp "-" (ELit (LInt 32))))) (DoLet false false (PVar "lower") (EApp (EApp (EApp (EApp (EApp (EVar "clipShift") (EVar "lo")) (EVar "hi")) (ELit (LInt 65))) (ELit (LInt 90))) (ELit (LInt 32)))) (DoExpr (EBinOp "::" (ETuple (EVar "lo") (EVar "hi")) (EBinOp "++" (EVar "upper") (EBinOp "++" (EVar "lower") (EApp (EVar "foldRanges") (EVar "rest"))))))))
(DTypeSig false "clipShift" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))))))
(DFunDef false "clipShift" ((PVar "lo") (PVar "hi") (PVar "blo") (PVar "bhi") (PVar "shift")) (EBlock (DoLet false false (PVar "l") (EApp (EApp (EVar "max") (EVar "lo")) (EVar "blo"))) (DoLet false false (PVar "h") (EApp (EApp (EVar "min") (EVar "hi")) (EVar "bhi"))) (DoExpr (EIf (EBinOp "<=" (EVar "l") (EVar "h")) (EListLit (ETuple (EBinOp "+" (EVar "l") (EVar "shift")) (EBinOp "+" (EVar "h") (EVar "shift")))) (EListLit)))))
(DTypeSig false "asStart" (TyCon "Int"))
(DFunDef false "asStart" () (ELit (LInt 0)))
(DTypeSig false "asEnd" (TyCon "Int"))
(DFunDef false "asEnd" () (ELit (LInt 1)))
(DTypeSig false "asWordB" (TyCon "Int"))
(DFunDef false "asWordB" () (ELit (LInt 2)))
(DTypeSig false "asNotWordB" (TyCon "Int"))
(DFunDef false "asNotWordB" () (ELit (LInt 3)))
(DData Private "Node" () ((variant "NEmpty" (ConPos)) (variant "NChar" (ConPos (TyCon "Int"))) (variant "NSet" (ConPos (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Bool"))) (variant "NAny" (ConPos (TyCon "Bool"))) (variant "NCat" (ConPos (TyCon "Node") (TyCon "Node"))) (variant "NAlt" (ConPos (TyCon "Node") (TyCon "Node"))) (variant "NStar" (ConPos (TyCon "Bool") (TyCon "Node"))) (variant "NPlus" (ConPos (TyCon "Bool") (TyCon "Node"))) (variant "NOpt" (ConPos (TyCon "Bool") (TyCon "Node"))) (variant "NGroup" (ConPos (TyCon "Int") (TyCon "Node"))) (variant "NAssert" (ConPos (TyCon "Int")))) ())
(DTypeSig false "nodeSize" (TyFun (TyCon "Node") (TyCon "Int")))
(DFunDef false "nodeSize" ((PCon "NEmpty")) (ELit (LInt 1)))
(DFunDef false "nodeSize" ((PCon "NChar" PWild)) (ELit (LInt 1)))
(DFunDef false "nodeSize" ((PCon "NSet" PWild PWild)) (ELit (LInt 1)))
(DFunDef false "nodeSize" ((PCon "NAny" PWild)) (ELit (LInt 1)))
(DFunDef false "nodeSize" ((PCon "NAssert" PWild)) (ELit (LInt 1)))
(DFunDef false "nodeSize" ((PCon "NCat" (PVar "a") (PVar "b"))) (EBinOp "+" (EApp (EVar "nodeSize") (EVar "a")) (EApp (EVar "nodeSize") (EVar "b"))))
(DFunDef false "nodeSize" ((PCon "NAlt" (PVar "a") (PVar "b"))) (EBinOp "+" (EBinOp "+" (ELit (LInt 2)) (EApp (EVar "nodeSize") (EVar "a"))) (EApp (EVar "nodeSize") (EVar "b"))))
(DFunDef false "nodeSize" ((PCon "NStar" PWild (PVar "b"))) (EBinOp "+" (ELit (LInt 2)) (EApp (EVar "nodeSize") (EVar "b"))))
(DFunDef false "nodeSize" ((PCon "NPlus" PWild (PVar "b"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "nodeSize") (EVar "b"))))
(DFunDef false "nodeSize" ((PCon "NOpt" PWild (PVar "b"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "nodeSize") (EVar "b"))))
(DFunDef false "nodeSize" ((PCon "NGroup" PWild (PVar "b"))) (EBinOp "+" (ELit (LInt 2)) (EApp (EVar "nodeSize") (EVar "b"))))
(DTypeSig false "repeatCap" (TyCon "Int"))
(DFunDef false "repeatCap" () (ELit (LInt 1000)))
(DTypeSig false "progCap" (TyCon "Int"))
(DFunDef false "progCap" () (ELit (LInt 20000)))
(DData Private "PState" () ((variant "PState" (ConNamed (field "pat" (TyApp (TyCon "Array") (TyCon "Char"))) (field "pos" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "ngroups" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "perr" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "RegexError")))) (field "fold" (TyCon "Bool")) (field "dotAll" (TyCon "Bool"))))) ())
(DTypeSig false "patLen" (TyFun (TyCon "PState") (TyCon "Int")))
(DFunDef false "patLen" ((PVar "st")) (EApp (EVar "arrayLength") (EFieldAccess (EVar "st") "pat")))
(DTypeSig false "atEnd" (TyFun (TyCon "PState") (TyCon "Bool")))
(DFunDef false "atEnd" ((PVar "st")) (EBinOp ">=" (EUnOp "!" (EFieldAccess (EVar "st") "pos")) (EApp (EVar "patLen") (EVar "st"))))
(DTypeSig false "cur" (TyFun (TyCon "PState") (TyCon "Char")))
(DFunDef false "cur" ((PVar "st")) (EApp (EApp (EVar "arrayGetUnsafe") (EUnOp "!" (EFieldAccess (EVar "st") "pos"))) (EFieldAccess (EVar "st") "pat")))
(DTypeSig false "isAt" (TyFun (TyCon "PState") (TyFun (TyCon "Char") (TyCon "Bool"))))
(DFunDef false "isAt" ((PVar "st") (PVar "c")) (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "atEnd") (EVar "st"))) (EBinOp "==" (EApp (EVar "cur") (EVar "st")) (EVar "c"))))
(DTypeSig false "peekIs" (TyFun (TyCon "PState") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyCon "Bool")))))
(DFunDef false "peekIs" ((PVar "st") (PVar "k") (PVar "c")) (EBlock (DoLet false false (PVar "i") (EBinOp "+" (EUnOp "!" (EFieldAccess (EVar "st") "pos")) (EVar "k"))) (DoExpr (EBinOp "&&" (EBinOp "<" (EVar "i") (EApp (EVar "patLen") (EVar "st"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EFieldAccess (EVar "st") "pat")) (EVar "c"))))))
(DTypeSig false "peekAt" (TyFun (TyCon "PState") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Char")))))
(DFunDef false "peekAt" ((PVar "st") (PVar "k")) (EBlock (DoLet false false (PVar "i") (EBinOp "+" (EUnOp "!" (EFieldAccess (EVar "st") "pos")) (EVar "k"))) (DoExpr (EIf (EBinOp "<" (EVar "i") (EApp (EVar "patLen") (EVar "st"))) (EApp (EVar "Some") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EFieldAccess (EVar "st") "pat"))) (EVar "None")))))
(DTypeSig false "advance" (TyFun (TyCon "PState") (TyCon "Unit")))
(DFunDef false "advance" ((PVar "st")) (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "pos")) (EBinOp "+" (EUnOp "!" (EFieldAccess (EVar "st") "pos")) (ELit (LInt 1)))))
(DTypeSig false "hasErr" (TyFun (TyCon "PState") (TyCon "Bool")))
(DFunDef false "hasErr" ((PVar "st")) (EMatch (EUnOp "!" (EFieldAccess (EVar "st") "perr")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "failAt" (TyFun (TyCon "PState") (TyFun (TyCon "String") (TyCon "Unit"))))
(DFunDef false "failAt" ((PVar "st") (PVar "message")) (EMatch (EUnOp "!" (EFieldAccess (EVar "st") "perr")) (arm (PCon "Some" PWild) () (ELit LUnit)) (arm (PCon "None") () (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "perr")) (EApp (EVar "Some") (ERecordCreate "RegexError" ((fa "message" (EVar "message")) (fa "position" (EUnOp "!" (EFieldAccess (EVar "st") "pos"))))))))))
(DTypeSig false "skip2" (TyFun (TyCon "PState") (TyFun (TyVar "a") (TyVar "a"))))
(DFunDef false "skip2" ((PVar "st") (PVar "v")) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EVar "v"))))
(DTypeSig false "scanFlags" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyTuple (TyCon "Int") (TyCon "Bool") (TyCon "Bool") (TyCon "Bool"))))))))
(DFunDef false "scanFlags" ((PVar "cs") (PVar "i") (PVar "fold") (PVar "multi") (PVar "dotAll")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 2))) (EApp (EVar "arrayLength") (EVar "cs"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "(")))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "cs")) (ELit (LChar "?")))) (EApp (EVar "isFlagChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "cs")))) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "scanFlagChars") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "fold")) (EVar "multi")) (EVar "dotAll")) (arm (PCon "None") () (ETuple (EVar "i") (EVar "fold") (EVar "multi") (EVar "dotAll"))) (arm (PCon "Some" (PTuple (PVar "j") (PVar "f2") (PVar "m2") (PVar "s2"))) () (EApp (EApp (EApp (EApp (EApp (EVar "scanFlags") (EVar "cs")) (EVar "j")) (EVar "f2")) (EVar "m2")) (EVar "s2")))) (ETuple (EVar "i") (EVar "fold") (EVar "multi") (EVar "dotAll"))))
(DTypeSig false "isFlagChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isFlagChar" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "i"))) (EBinOp "==" (EVar "c") (ELit (LChar "m")))) (EBinOp "==" (EVar "c") (ELit (LChar "s")))))
(DTypeSig false "scanFlagChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Bool") (TyCon "Bool") (TyCon "Bool")))))))))
(DFunDef false "scanFlagChars" ((PVar "cs") (PVar "k") (PVar "fold") (PVar "multi") (PVar "dotAll")) (EIf (EBinOp ">=" (EVar "k") (EApp (EVar "arrayLength") (EVar "cs"))) (EVar "None") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "cs"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LChar "i"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanFlagChars") (EVar "cs")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "True")) (EVar "multi")) (EVar "dotAll")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "m"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanFlagChars") (EVar "cs")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "fold")) (EVar "True")) (EVar "dotAll")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "s"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanFlagChars") (EVar "cs")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "fold")) (EVar "multi")) (EVar "True")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar ")"))) (EApp (EVar "Some") (ETuple (EBinOp "+" (EVar "k") (ELit (LInt 1))) (EVar "fold") (EVar "multi") (EVar "dotAll"))) (EVar "None")))))))))
(DTypeSig false "parseAlt" (TyFun (TyCon "PState") (TyCon "Node")))
(DFunDef false "parseAlt" ((PVar "st")) (EApp (EApp (EVar "parseAltMore") (EVar "st")) (EApp (EVar "parseCat") (EVar "st"))))
(DTypeSig false "parseAltMore" (TyFun (TyCon "PState") (TyFun (TyCon "Node") (TyCon "Node"))))
(DFunDef false "parseAltMore" ((PVar "st") (PVar "left")) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "|"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoLet false false (PVar "right") (EApp (EVar "parseCat") (EVar "st"))) (DoExpr (EApp (EApp (EVar "parseAltMore") (EVar "st")) (EApp (EApp (EVar "NAlt") (EVar "left")) (EVar "right"))))) (EVar "left")))
(DTypeSig false "parseCat" (TyFun (TyCon "PState") (TyCon "Node")))
(DFunDef false "parseCat" ((PVar "st")) (EApp (EVar "catOf") (EApp (EApp (EVar "parseSeq") (EVar "st")) (EListLit))))
(DTypeSig false "catOf" (TyFun (TyApp (TyCon "List") (TyCon "Node")) (TyCon "Node")))
(DFunDef false "catOf" ((PList)) (EVar "NEmpty"))
(DFunDef false "catOf" ((PCons (PVar "x") (PList))) (EVar "x"))
(DFunDef false "catOf" ((PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EVar "NCat") (EVar "x")) (EApp (EVar "catOf") (EVar "rest"))))
(DTypeSig false "parseSeq" (TyFun (TyCon "PState") (TyFun (TyApp (TyCon "List") (TyCon "Node")) (TyApp (TyCon "List") (TyCon "Node")))))
(DFunDef false "parseSeq" ((PVar "st") (PVar "acc")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "hasErr") (EVar "st")) (EApp (EVar "atEnd") (EVar "st"))) (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "|")))) (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar ")")))) (EApp (EVar "reverse") (EVar "acc")) (EBlock (DoLet false false (PVar "item") (EApp (EVar "parsePiece") (EVar "st"))) (DoExpr (EApp (EApp (EVar "parseSeq") (EVar "st")) (EBinOp "::" (EVar "item") (EVar "acc")))))))
(DTypeSig false "parsePiece" (TyFun (TyCon "PState") (TyCon "Node")))
(DFunDef false "parsePiece" ((PVar "st")) (EBlock (DoLet false false (PVar "atom") (EApp (EVar "parseAtom") (EVar "st"))) (DoExpr (EApp (EApp (EVar "parseQuant") (EVar "st")) (EVar "atom")))))
(DTypeSig false "parseQuant" (TyFun (TyCon "PState") (TyFun (TyCon "Node") (TyCon "Node"))))
(DFunDef false "parseQuant" ((PVar "st") (PVar "node")) (EIf (EApp (EVar "hasErr") (EVar "st")) (EVar "node") (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "*"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EVar "parseQuant") (EVar "st")) (EApp (EApp (EVar "NStar") (EApp (EVar "greedFlag") (EVar "st"))) (EVar "node"))))) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "+"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EVar "parseQuant") (EVar "st")) (EApp (EApp (EVar "NPlus") (EApp (EVar "greedFlag") (EVar "st"))) (EVar "node"))))) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "?"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EVar "parseQuant") (EVar "st")) (EApp (EApp (EVar "NOpt") (EApp (EVar "greedFlag") (EVar "st"))) (EVar "node"))))) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "{"))) (EApp (EApp (EVar "parseBrace") (EVar "st")) (EVar "node")) (EVar "node")))))))
(DTypeSig false "greedFlag" (TyFun (TyCon "PState") (TyCon "Bool")))
(DFunDef false "greedFlag" ((PVar "st")) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "?"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EVar "False"))) (EVar "True")))
(DTypeSig false "parseBrace" (TyFun (TyCon "PState") (TyFun (TyCon "Node") (TyCon "Node"))))
(DFunDef false "parseBrace" ((PVar "st") (PVar "node")) (EBlock (DoLet false false (PVar "save") (EUnOp "!" (EFieldAccess (EVar "st") "pos"))) (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EMatch (EApp (EVar "parseDigits") (EVar "st")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "rewind") (EVar "st")) (EVar "save")) (EVar "node"))) (arm (PCon "Some" (PVar "lo")) () (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "}"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "finishRepeat") (EVar "st")) (EVar "node")) (EVar "lo")) (EVar "lo")))) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar ","))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "parseBraceUpper") (EVar "st")) (EVar "node")) (EVar "save")) (EVar "lo")))) (EApp (EApp (EApp (EVar "rewind") (EVar "st")) (EVar "save")) (EVar "node")))))))))
(DTypeSig false "parseBraceUpper" (TyFun (TyCon "PState") (TyFun (TyCon "Node") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Node"))))))
(DFunDef false "parseBraceUpper" ((PVar "st") (PVar "node") (PVar "save") (PVar "lo")) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "}"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "finishRepeat") (EVar "st")) (EVar "node")) (EVar "lo")) (EUnOp "-" (ELit (LInt 1)))))) (EMatch (EApp (EVar "parseDigits") (EVar "st")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "rewind") (EVar "st")) (EVar "save")) (EVar "node"))) (arm (PCon "Some" (PVar "hi")) () (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "}"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "finishRepeat") (EVar "st")) (EVar "node")) (EVar "lo")) (EVar "hi")))) (EApp (EApp (EApp (EVar "rewind") (EVar "st")) (EVar "save")) (EVar "node")))))))
(DTypeSig false "rewind" (TyFun (TyCon "PState") (TyFun (TyCon "Int") (TyFun (TyCon "Node") (TyCon "Node")))))
(DFunDef false "rewind" ((PVar "st") (PVar "save") (PVar "node")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "pos")) (EVar "save"))) (DoExpr (EVar "node"))))
(DTypeSig false "parseDigits" (TyFun (TyCon "PState") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "parseDigits" ((PVar "st")) (EIf (EBinOp "||" (EApp (EVar "atEnd") (EVar "st")) (EApp (EVar "not") (EApp (EVar "isDigit") (EApp (EVar "cur") (EVar "st"))))) (EVar "None") (EApp (EApp (EVar "digitsGo") (EVar "st")) (ELit (LInt 0)))))
(DTypeSig false "digitsGo" (TyFun (TyCon "PState") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "digitsGo" ((PVar "st") (PVar "acc")) (EIf (EBinOp "||" (EApp (EVar "atEnd") (EVar "st")) (EApp (EVar "not") (EApp (EVar "isDigit") (EApp (EVar "cur") (EVar "st"))))) (EApp (EVar "Some") (EVar "acc")) (EIf (EBinOp ">" (EVar "acc") (EVar "repeatCap")) (EApp (EVar "Some") (EVar "acc")) (EBlock (DoLet false false (PVar "d") (EBinOp "-" (EApp (EVar "charCode") (EApp (EVar "cur") (EVar "st"))) (ELit (LInt 48)))) (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EVar "digitsGo") (EVar "st")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EVar "d"))))))))
(DTypeSig false "finishRepeat" (TyFun (TyCon "PState") (TyFun (TyCon "Node") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Node"))))))
(DFunDef false "finishRepeat" ((PVar "st") (PVar "node") (PVar "lo") (PVar "hi")) (EIf (EBinOp "||" (EBinOp ">" (EVar "lo") (EVar "repeatCap")) (EBinOp ">" (EVar "hi") (EVar "repeatCap"))) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "repetition bound is larger than the maximum of 1000")))) (DoExpr (EVar "node"))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "hi") (ELit (LInt 0))) (EBinOp "<" (EVar "hi") (EVar "lo"))) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "repetition bounds are out of order")))) (DoExpr (EVar "node"))) (EIf (EBinOp ">" (EBinOp "*" (EApp (EApp (EVar "repeatWidth") (EVar "lo")) (EVar "hi")) (EApp (EVar "nodeSize") (EVar "node"))) (EVar "progCap")) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "pattern compiles to more than 20000 instructions")))) (DoExpr (EVar "node"))) (EBlock (DoLet false false (PVar "greedy") (EApp (EVar "greedFlag") (EVar "st"))) (DoExpr (EApp (EApp (EVar "parseQuant") (EVar "st")) (EApp (EApp (EApp (EApp (EVar "expandRepeat") (EVar "greedy")) (EVar "node")) (EVar "lo")) (EVar "hi")))))))))
(DTypeSig false "repeatWidth" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "repeatWidth" ((PVar "lo") (PVar "hi")) (EIf (EBinOp "<" (EVar "hi") (ELit (LInt 0))) (EBinOp "+" (EVar "lo") (ELit (LInt 2))) (EBinOp "+" (EVar "hi") (ELit (LInt 1)))))
(DTypeSig false "expandRepeat" (TyFun (TyCon "Bool") (TyFun (TyCon "Node") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Node"))))))
(DFunDef false "expandRepeat" ((PVar "greedy") (PVar "node") (PVar "lo") (PVar "hi")) (EIf (EBinOp "<" (EVar "hi") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "catRepeat") (EVar "node")) (EVar "lo")) (EApp (EApp (EVar "NStar") (EVar "greedy")) (EVar "node"))) (EApp (EApp (EApp (EVar "catRepeat") (EVar "node")) (EVar "lo")) (EApp (EApp (EApp (EVar "optChain") (EVar "greedy")) (EVar "node")) (EBinOp "-" (EVar "hi") (EVar "lo"))))))
(DTypeSig false "catRepeat" (TyFun (TyCon "Node") (TyFun (TyCon "Int") (TyFun (TyCon "Node") (TyCon "Node")))))
(DFunDef false "catRepeat" ((PVar "node") (PVar "n") (PVar "rest")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EVar "rest") (EApp (EApp (EVar "NCat") (EVar "node")) (EApp (EApp (EApp (EVar "catRepeat") (EVar "node")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "rest")))))
(DTypeSig false "optChain" (TyFun (TyCon "Bool") (TyFun (TyCon "Node") (TyFun (TyCon "Int") (TyCon "Node")))))
(DFunDef false "optChain" ((PVar "greedy") (PVar "node") (PVar "k")) (EIf (EBinOp "<=" (EVar "k") (ELit (LInt 0))) (EVar "NEmpty") (EApp (EApp (EVar "NOpt") (EVar "greedy")) (EApp (EApp (EVar "NCat") (EVar "node")) (EApp (EApp (EApp (EVar "optChain") (EVar "greedy")) (EVar "node")) (EBinOp "-" (EVar "k") (ELit (LInt 1))))))))
(DTypeSig false "parseAtom" (TyFun (TyCon "PState") (TyCon "Node")))
(DFunDef false "parseAtom" ((PVar "st")) (EIf (EApp (EVar "atEnd") (EVar "st")) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "pattern ends where an expression was expected")))) (DoExpr (EVar "NEmpty"))) (EBlock (DoLet false false (PVar "c") (EApp (EVar "cur") (EVar "st"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LChar "("))) (EApp (EVar "parseGroup") (EVar "st")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "["))) (EApp (EVar "parseSet") (EVar "st")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "."))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EVar "NAny") (EFieldAccess (EVar "st") "dotAll")))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "^"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EVar "NAssert") (EVar "asStart")))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "$"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EVar "NAssert") (EVar "asEnd")))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\\"))) (EApp (EVar "parseEscape") (EVar "st")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "*"))) (EBinOp "==" (EVar "c") (ELit (LChar "+")))) (EBinOp "==" (EVar "c") (ELit (LChar "?")))) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "repetition operator with nothing to repeat")))) (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EVar "NEmpty"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EVar "litNode") (EVar "st")) (EApp (EVar "charCode") (EVar "c"))))))))))))))))
(DTypeSig false "litNode" (TyFun (TyCon "PState") (TyFun (TyCon "Int") (TyCon "Node"))))
(DFunDef false "litNode" ((PVar "st") (PVar "code")) (EIf (EBinOp "&&" (EFieldAccess (EVar "st") "fold") (EApp (EVar "isAsciiLetterCode") (EVar "code"))) (EApp (EApp (EVar "NSet") (EApp (EVar "flattenRanges") (EApp (EVar "foldRanges") (EListLit (ETuple (EVar "code") (EVar "code")))))) (EVar "False")) (EApp (EVar "NChar") (EVar "code"))))
(DTypeSig false "parseGroup" (TyFun (TyCon "PState") (TyCon "Node")))
(DFunDef false "parseGroup" ((PVar "st")) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "?"))) (EIf (EApp (EApp (EApp (EVar "peekIs") (EVar "st")) (ELit (LInt 1))) (ELit (LChar ":"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EVar "groupBody") (EVar "st")) (ELit (LInt 0))))) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (EApp (EVar "groupRefusal") (EVar "st")))) (DoExpr (EVar "NEmpty")))) (EBlock (DoLet false false (PVar "idx") (EBinOp "+" (EUnOp "!" (EFieldAccess (EVar "st") "ngroups")) (ELit (LInt 1)))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "ngroups")) (EVar "idx"))) (DoExpr (EApp (EApp (EVar "groupBody") (EVar "st")) (EVar "idx"))))))))
(DTypeSig false "groupBody" (TyFun (TyCon "PState") (TyFun (TyCon "Int") (TyCon "Node"))))
(DFunDef false "groupBody" ((PVar "st") (PVar "idx")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "parseAlt") (EVar "st"))) (DoExpr (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar ")"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EIf (EBinOp "==" (EVar "idx") (ELit (LInt 0))) (EVar "body") (EApp (EApp (EVar "NGroup") (EVar "idx")) (EVar "body"))))) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "pattern is missing a closing )")))) (DoExpr (EVar "NEmpty")))))))
(DTypeSig false "groupRefusal" (TyFun (TyCon "PState") (TyCon "String")))
(DFunDef false "groupRefusal" ((PVar "st")) (EMatch (EApp (EApp (EVar "peekAt") (EVar "st")) (ELit (LInt 1))) (arm (PCon "Some" (PLit (LChar "="))) () (ELit (LString "lookahead is not supported"))) (arm (PCon "Some" (PLit (LChar "!"))) () (ELit (LString "lookahead is not supported"))) (arm (PCon "Some" (PLit (LChar "<"))) () (ELit (LString "named groups and lookbehind are not supported"))) (arm (PCon "Some" (PLit (LChar "P"))) () (ELit (LString "named groups are not supported"))) (arm (PCon "Some" (PLit (LChar "i"))) () (ELit (LString "flags are only allowed at the start of the pattern"))) (arm (PCon "Some" (PLit (LChar "m"))) () (ELit (LString "flags are only allowed at the start of the pattern"))) (arm (PCon "Some" (PLit (LChar "s"))) () (ELit (LString "flags are only allowed at the start of the pattern"))) (arm PWild () (ELit (LString "unsupported group syntax after (?")))))
(DTypeSig false "parseEscape" (TyFun (TyCon "PState") (TyCon "Node")))
(DFunDef false "parseEscape" ((PVar "st")) (EMatch (EApp (EApp (EVar "peekAt") (EVar "st")) (ELit (LInt 1))) (arm (PCon "None") () (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "pattern ends in a backslash")))) (DoExpr (EVar "NEmpty")))) (arm (PCon "Some" (PVar "c")) () (EIf (EBinOp "==" (EVar "c") (ELit (LChar "d"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EApp (EVar "NSet") (EApp (EVar "flattenRanges") (EVar "digitRanges"))) (EVar "False"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "D"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EApp (EVar "NSet") (EApp (EVar "flattenRanges") (EVar "digitRanges"))) (EVar "True"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "w"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EApp (EVar "NSet") (EVar "wordSet")) (EVar "False"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "W"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EApp (EVar "NSet") (EVar "wordSet")) (EVar "True"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "s"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EApp (EVar "NSet") (EApp (EVar "flattenRanges") (EVar "spaceRanges"))) (EVar "False"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "S"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EApp (EVar "NSet") (EApp (EVar "flattenRanges") (EVar "spaceRanges"))) (EVar "True"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "b"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EVar "NAssert") (EVar "asWordB"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "B"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EVar "NAssert") (EVar "asNotWordB"))) (EMatch (EApp (EVar "escapeCode") (EVar "st")) (arm (PCon "None") () (EVar "NEmpty")) (arm (PCon "Some" (PVar "code")) () (EApp (EApp (EVar "litNode") (EVar "st")) (EVar "code")))))))))))))))
(DTypeSig false "escapeCode" (TyFun (TyCon "PState") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "escapeCode" ((PVar "st")) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EMatch (EApp (EApp (EVar "peekAt") (EVar "st")) (ELit (LInt 0))) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "pattern ends in a backslash")))) (DoExpr (EVar "None")))) (arm (PCon "Some" (PVar "c")) () (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LChar "n"))) (EApp (EVar "Some") (ELit (LInt 10))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "t"))) (EApp (EVar "Some") (ELit (LInt 9))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "r"))) (EApp (EVar "Some") (ELit (LInt 13))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "x"))) (EApp (EApp (EVar "hexCode") (EVar "st")) (ELit (LInt 2))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "u"))) (EApp (EVar "braceHexCode") (EVar "st")) (EIf (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "p"))) (EBinOp "==" (EVar "c") (ELit (LChar "P")))) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "Unicode character classes are not supported")))) (DoExpr (EVar "None"))) (EIf (EApp (EVar "isDigit") (EVar "c")) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "backreferences are not supported")))) (DoExpr (EVar "None"))) (EIf (EApp (EVar "charIsAlpha") (EVar "c")) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "unknown escape sequence")))) (DoExpr (EVar "None"))) (EApp (EVar "Some") (EApp (EVar "charCode") (EVar "c"))))))))))))))))))
(DTypeSig false "hexCode" (TyFun (TyCon "PState") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "hexCode" ((PVar "st") (PVar "n")) (EApp (EApp (EApp (EVar "hexGo") (EVar "st")) (EVar "n")) (ELit (LInt 0))))
(DTypeSig false "hexGo" (TyFun (TyCon "PState") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "hexGo" ((PVar "st") (PVar "n") (PVar "acc")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Some") (EVar "acc")) (EMatch (EApp (EApp (EVar "peekAt") (EVar "st")) (ELit (LInt 0))) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "incomplete hexadecimal escape")))) (DoExpr (EVar "None")))) (arm (PCon "Some" (PVar "c")) () (EMatch (EApp (EVar "hexValue") (EVar "c")) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "incomplete hexadecimal escape")))) (DoExpr (EVar "None")))) (arm (PCon "Some" (PVar "v")) () (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EApp (EVar "hexGo") (EVar "st")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 16))) (EVar "v")))))))))))
(DTypeSig false "hexValue" (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "hexValue" ((PVar "c")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "charCode") (EVar "c"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 48))) (EBinOp "<=" (EVar "n") (ELit (LInt 57)))) (EApp (EVar "Some") (EBinOp "-" (EVar "n") (ELit (LInt 48)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 97))) (EBinOp "<=" (EVar "n") (ELit (LInt 102)))) (EApp (EVar "Some") (EBinOp "-" (EVar "n") (ELit (LInt 87)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 65))) (EBinOp "<=" (EVar "n") (ELit (LInt 70)))) (EApp (EVar "Some") (EBinOp "-" (EVar "n") (ELit (LInt 55)))) (EVar "None")))))))
(DTypeSig false "braceHexCode" (TyFun (TyCon "PState") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "braceHexCode" ((PVar "st")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "{")))) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "\\u must be followed by a braced hexadecimal codepoint")))) (DoExpr (EVar "None"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "braceHexGo") (EVar "st")) (ELit (LInt 0))) (ELit (LInt 0))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "code")) () (EIf (EBinOp ">" (EVar "code") (EVar "maxCode")) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "codepoint is above the Unicode maximum")))) (DoExpr (EVar "None"))) (EApp (EVar "Some") (EVar "code")))))))))
(DTypeSig false "braceHexGo" (TyFun (TyCon "PState") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "braceHexGo" ((PVar "st") (PVar "seen") (PVar "acc")) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "}"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EIf (EBinOp "==" (EVar "seen") (ELit (LInt 0))) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "\\u{} needs at least one hexadecimal digit")))) (DoExpr (EVar "None"))) (EApp (EVar "Some") (EVar "acc"))))) (EMatch (EApp (EApp (EVar "peekAt") (EVar "st")) (ELit (LInt 0))) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "\\u{ is missing its closing brace")))) (DoExpr (EVar "None")))) (arm (PCon "Some" (PVar "c")) () (EMatch (EApp (EVar "hexValue") (EVar "c")) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "\\u{ is missing its closing brace")))) (DoExpr (EVar "None")))) (arm (PCon "Some" (PVar "v")) () (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EApp (EVar "braceHexGo") (EVar "st")) (EBinOp "+" (EVar "seen") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 16))) (EVar "v")))))))))))
(DTypeSig false "parseSet" (TyFun (TyCon "PState") (TyCon "Node")))
(DFunDef false "parseSet" ((PVar "st")) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoLet false false (PVar "negated") (EApp (EVar "setNegated") (EVar "st"))) (DoLet false false (PVar "rs") (EApp (EApp (EVar "setItems") (EVar "st")) (EListLit))) (DoExpr (EIf (EApp (EVar "hasErr") (EVar "st")) (EVar "NEmpty") (EIf (EApp (EVar "isEmptyRanges") (EVar "rs")) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "empty character class")))) (DoExpr (EVar "NEmpty"))) (EBlock (DoLet false false (PVar "folded") (EIf (EFieldAccess (EVar "st") "fold") (EApp (EVar "foldRanges") (EVar "rs")) (EVar "rs"))) (DoExpr (EApp (EApp (EVar "NSet") (EApp (EVar "flattenRanges") (EVar "folded"))) (EVar "negated")))))))))
(DTypeSig false "setNegated" (TyFun (TyCon "PState") (TyCon "Bool")))
(DFunDef false "setNegated" ((PVar "st")) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "^"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EVar "True"))) (EVar "False")))
(DTypeSig false "isEmptyRanges" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyCon "Bool")))
(DFunDef false "isEmptyRanges" ((PList)) (EVar "True"))
(DFunDef false "isEmptyRanges" (PWild) (EVar "False"))
(DTypeSig false "setItems" (TyFun (TyCon "PState") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "setItems" ((PVar "st") (PVar "acc")) (EIf (EApp (EVar "hasErr") (EVar "st")) (EVar "acc") (EIf (EApp (EVar "atEnd") (EVar "st")) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "character class is missing a closing ]")))) (DoExpr (EVar "acc"))) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "]"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EVar "acc"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "["))) (EApp (EApp (EApp (EVar "peekIs") (EVar "st")) (ELit (LInt 1))) (ELit (LChar ":")))) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "POSIX character classes are not supported")))) (DoExpr (EVar "acc"))) (EMatch (EApp (EVar "setItem") (EVar "st")) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PVar "rs")) () (EApp (EApp (EVar "setItems") (EVar "st")) (EBinOp "++" (EVar "rs") (EVar "acc"))))))))))
(DTypeSig false "setItem" (TyFun (TyCon "PState") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "setItem" ((PVar "st")) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "\\"))) (EApp (EVar "setEscapeItem") (EVar "st")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "cur") (EVar "st"))) (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EVar "setRangeFrom") (EVar "st")) (EApp (EVar "charCode") (EVar "c")))))))
(DTypeSig false "setEscapeItem" (TyFun (TyCon "PState") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "setEscapeItem" ((PVar "st")) (EMatch (EApp (EApp (EVar "peekAt") (EVar "st")) (ELit (LInt 1))) (arm (PCon "None") () (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "pattern ends in a backslash")))) (DoExpr (EVar "None")))) (arm (PCon "Some" (PVar "c")) () (EIf (EBinOp "==" (EVar "c") (ELit (LChar "d"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EVar "Some") (EVar "digitRanges"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "D"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EVar "Some") (EApp (EVar "complementRanges") (EVar "digitRanges")))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "w"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EVar "Some") (EVar "wordRanges"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "W"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EVar "Some") (EApp (EVar "complementRanges") (EVar "wordRanges")))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "s"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EVar "Some") (EVar "spaceRanges"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "S"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EVar "Some") (EApp (EVar "complementRanges") (EVar "spaceRanges")))) (EMatch (EApp (EVar "escapeCode") (EVar "st")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "code")) () (EApp (EApp (EVar "setRangeFrom") (EVar "st")) (EVar "code")))))))))))))
(DTypeSig false "setRangeFrom" (TyFun (TyCon "PState") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "setRangeFrom" ((PVar "st") (PVar "lo")) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "-"))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "peekIs") (EVar "st")) (ELit (LInt 1))) (ELit (LChar "]"))))) (EBinOp "<" (EBinOp "+" (EUnOp "!" (EFieldAccess (EVar "st") "pos")) (ELit (LInt 1))) (EApp (EVar "patLen") (EVar "st")))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EMatch (EApp (EVar "setSingle") (EVar "st")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "hi")) () (EIf (EBinOp "<=" (EVar "lo") (EVar "hi")) (EApp (EVar "Some") (EListLit (ETuple (EVar "lo") (EVar "hi")))) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "character class range is reversed")))) (DoExpr (EVar "None")))))))) (EApp (EVar "Some") (EListLit (ETuple (EVar "lo") (EVar "lo"))))))
(DTypeSig false "setSingle" (TyFun (TyCon "PState") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "setSingle" ((PVar "st")) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "\\"))) (EApp (EVar "escapeCode") (EVar "st")) (EIf (EApp (EVar "atEnd") (EVar "st")) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "character class is missing a closing ]")))) (DoExpr (EVar "None"))) (EBlock (DoLet false false (PVar "c") (EApp (EVar "cur") (EVar "st"))) (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EVar "Some") (EApp (EVar "charCode") (EVar "c"))))))))
(DData Private "Inst" () ((variant "IChar" (ConPos (TyCon "Int"))) (variant "ISet" (ConPos (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Bool"))) (variant "IAny" (ConPos (TyCon "Bool"))) (variant "ISplit" (ConPos (TyCon "Int") (TyCon "Int"))) (variant "IJmp" (ConPos (TyCon "Int"))) (variant "ISave" (ConPos (TyCon "Int"))) (variant "IAssert" (ConPos (TyCon "Int"))) (variant "IMatch" (ConPos))) ())
(DTypeSig false "compileNode" (TyFun (TyCon "Node") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Inst")))))
(DFunDef false "compileNode" ((PCon "NEmpty") PWild) (EListLit))
(DFunDef false "compileNode" ((PCon "NChar" (PVar "c")) PWild) (EListLit (EApp (EVar "IChar") (EVar "c"))))
(DFunDef false "compileNode" ((PCon "NSet" (PVar "rs") (PVar "negated")) PWild) (EListLit (EApp (EApp (EVar "ISet") (EVar "rs")) (EVar "negated"))))
(DFunDef false "compileNode" ((PCon "NAny" (PVar "dotAll")) PWild) (EListLit (EApp (EVar "IAny") (EVar "dotAll"))))
(DFunDef false "compileNode" ((PCon "NAssert" (PVar "kind")) PWild) (EListLit (EApp (EVar "IAssert") (EVar "kind"))))
(DFunDef false "compileNode" ((PCon "NCat" (PVar "a") (PVar "b")) (PVar "pc")) (EBlock (DoLet false false (PVar "ca") (EApp (EApp (EVar "compileNode") (EVar "a")) (EVar "pc"))) (DoExpr (EBinOp "++" (EVar "ca") (EApp (EApp (EVar "compileNode") (EVar "b")) (EBinOp "+" (EVar "pc") (EApp (EVar "length") (EVar "ca"))))))))
(DFunDef false "compileNode" ((PCon "NAlt" (PVar "a") (PVar "b")) (PVar "pc")) (EBlock (DoLet false false (PVar "ca") (EApp (EApp (EVar "compileNode") (EVar "a")) (EBinOp "+" (EVar "pc") (ELit (LInt 1))))) (DoLet false false (PVar "jmpAt") (EBinOp "+" (EBinOp "+" (EVar "pc") (ELit (LInt 1))) (EApp (EVar "length") (EVar "ca")))) (DoLet false false (PVar "cb") (EApp (EApp (EVar "compileNode") (EVar "b")) (EBinOp "+" (EVar "jmpAt") (ELit (LInt 1))))) (DoLet false false (PVar "out") (EBinOp "+" (EBinOp "+" (EVar "jmpAt") (ELit (LInt 1))) (EApp (EVar "length") (EVar "cb")))) (DoExpr (EBinOp "::" (EApp (EApp (EVar "ISplit") (EBinOp "+" (EVar "pc") (ELit (LInt 1)))) (EBinOp "+" (EVar "jmpAt") (ELit (LInt 1)))) (EBinOp "++" (EVar "ca") (EBinOp "::" (EApp (EVar "IJmp") (EVar "out")) (EVar "cb")))))))
(DFunDef false "compileNode" ((PCon "NStar" (PVar "greedy") (PVar "body")) (PVar "pc")) (EBlock (DoLet false false (PVar "cb") (EApp (EApp (EVar "compileNode") (EVar "body")) (EBinOp "+" (EVar "pc") (ELit (LInt 1))))) (DoLet false false (PVar "out") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EVar "pc") (ELit (LInt 1))) (EApp (EVar "length") (EVar "cb"))) (ELit (LInt 1)))) (DoLet false false (PVar "sp") (EIf (EVar "greedy") (EApp (EApp (EVar "ISplit") (EBinOp "+" (EVar "pc") (ELit (LInt 1)))) (EVar "out")) (EApp (EApp (EVar "ISplit") (EVar "out")) (EBinOp "+" (EVar "pc") (ELit (LInt 1)))))) (DoExpr (EBinOp "::" (EVar "sp") (EBinOp "++" (EVar "cb") (EListLit (EApp (EVar "IJmp") (EVar "pc"))))))))
(DFunDef false "compileNode" ((PCon "NPlus" (PVar "greedy") (PVar "body")) (PVar "pc")) (EBlock (DoLet false false (PVar "cb") (EApp (EApp (EVar "compileNode") (EVar "body")) (EVar "pc"))) (DoLet false false (PVar "out") (EBinOp "+" (EBinOp "+" (EVar "pc") (EApp (EVar "length") (EVar "cb"))) (ELit (LInt 1)))) (DoLet false false (PVar "sp") (EIf (EVar "greedy") (EApp (EApp (EVar "ISplit") (EVar "pc")) (EVar "out")) (EApp (EApp (EVar "ISplit") (EVar "out")) (EVar "pc")))) (DoExpr (EBinOp "++" (EVar "cb") (EListLit (EVar "sp"))))))
(DFunDef false "compileNode" ((PCon "NOpt" (PVar "greedy") (PVar "body")) (PVar "pc")) (EBlock (DoLet false false (PVar "cb") (EApp (EApp (EVar "compileNode") (EVar "body")) (EBinOp "+" (EVar "pc") (ELit (LInt 1))))) (DoLet false false (PVar "out") (EBinOp "+" (EBinOp "+" (EVar "pc") (ELit (LInt 1))) (EApp (EVar "length") (EVar "cb")))) (DoLet false false (PVar "sp") (EIf (EVar "greedy") (EApp (EApp (EVar "ISplit") (EBinOp "+" (EVar "pc") (ELit (LInt 1)))) (EVar "out")) (EApp (EApp (EVar "ISplit") (EVar "out")) (EBinOp "+" (EVar "pc") (ELit (LInt 1)))))) (DoExpr (EBinOp "::" (EVar "sp") (EVar "cb")))))
(DFunDef false "compileNode" ((PCon "NGroup" (PVar "idx") (PVar "body")) (PVar "pc")) (EBinOp "::" (EApp (EVar "ISave") (EBinOp "*" (ELit (LInt 2)) (EVar "idx"))) (EBinOp "++" (EApp (EApp (EVar "compileNode") (EVar "body")) (EBinOp "+" (EVar "pc") (ELit (LInt 1)))) (EListLit (EApp (EVar "ISave") (EBinOp "+" (EBinOp "*" (ELit (LInt 2)) (EVar "idx")) (ELit (LInt 1))))))))
(DData Private "Vm" () ((variant "Vm" (ConNamed (field "prog" (TyApp (TyCon "Array") (TyCon "Inst"))) (field "codes" (TyApp (TyCon "Array") (TyCon "Int"))) (field "subjStart" (TyCon "Int")) (field "subjEnd" (TyCon "Int")) (field "multi" (TyCon "Bool")) (field "anchorEnd" (TyCon "Bool")) (field "nslots" (TyCon "Int")) (field "steps" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "found" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int")))))))) ())
(DData Private "ThreadList" () ((variant "ThreadList" (ConNamed (field "dense" (TyApp (TyCon "Array") (TyCon "Int"))) (field "slots" (TyApp (TyCon "Array") (TyApp (TyCon "Array") (TyCon "Int")))) (field "live" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "mark" (TyApp (TyCon "Array") (TyCon "Int"))) (field "gen" (TyApp (TyCon "Ref") (TyCon "Int")))))) ())
(DTypeSig false "noSlots" (TyApp (TyCon "Array") (TyCon "Int")))
(DFunDef false "noSlots" () (EArrayLit))
(DTypeSig false "newThreads" (TyFun (TyCon "Int") (TyCon "ThreadList")))
(DFunDef false "newThreads" ((PVar "n")) (ERecordCreate "ThreadList" ((fa "dense" (EApp (EApp (EVar "arrayMake") (EVar "n")) (ELit (LInt 0)))) (fa "slots" (EApp (EApp (EVar "arrayMake") (EVar "n")) (EVar "noSlots"))) (fa "live" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "mark" (EApp (EApp (EVar "arrayMake") (EVar "n")) (ELit (LInt 0)))) (fa "gen" (EApp (EVar "Ref") (ELit (LInt 1)))))))
(DTypeSig false "resetThreads" (TyFun (TyCon "ThreadList") (TyCon "Unit")))
(DFunDef false "resetThreads" ((PVar "list")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "list") "live")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "list") "gen")) (EBinOp "+" (EUnOp "!" (EFieldAccess (EVar "list") "gen")) (ELit (LInt 1)))))))
(DTypeSig false "foundYet" (TyFun (TyCon "Vm") (TyCon "Bool")))
(DFunDef false "foundYet" ((PVar "vm")) (EMatch (EUnOp "!" (EFieldAccess (EVar "vm") "found")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "addThread" (TyFun (TyCon "Vm") (TyFun (TyCon "ThreadList") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "addThread" ((PVar "vm") (PVar "list") (PVar "pc") (PVar "pos") (PVar "slots")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "vm") "steps")) (EBinOp "+" (EUnOp "!" (EFieldAccess (EVar "vm") "steps")) (ELit (LInt 1))))) (DoExpr (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pc")) (EFieldAccess (EVar "list") "mark")) (EUnOp "!" (EFieldAccess (EVar "list") "gen"))) (ELit LUnit) (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "pc")) (EUnOp "!" (EFieldAccess (EVar "list") "gen"))) (EFieldAccess (EVar "list") "mark"))) (DoExpr (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pc")) (EFieldAccess (EVar "vm") "prog")) (arm (PCon "IJmp" (PVar "x")) () (EApp (EApp (EApp (EApp (EApp (EVar "addThread") (EVar "vm")) (EVar "list")) (EVar "x")) (EVar "pos")) (EVar "slots"))) (arm (PCon "ISplit" (PVar "x") (PVar "y")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "addThread") (EVar "vm")) (EVar "list")) (EVar "x")) (EVar "pos")) (EVar "slots"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "addThread") (EVar "vm")) (EVar "list")) (EVar "y")) (EVar "pos")) (EVar "slots"))))) (arm (PCon "ISave" (PVar "n")) () (EBlock (DoLet false false (PVar "written") (EApp (EVar "arrayCopy") (EVar "slots"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "n")) (EVar "pos")) (EVar "written"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "addThread") (EVar "vm")) (EVar "list")) (EBinOp "+" (EVar "pc") (ELit (LInt 1)))) (EVar "pos")) (EVar "written"))))) (arm (PCon "IAssert" (PVar "kind")) () (EIf (EApp (EApp (EApp (EVar "assertHolds") (EVar "vm")) (EVar "kind")) (EVar "pos")) (EApp (EApp (EApp (EApp (EApp (EVar "addThread") (EVar "vm")) (EVar "list")) (EBinOp "+" (EVar "pc") (ELit (LInt 1)))) (EVar "pos")) (EVar "slots")) (ELit LUnit))) (arm PWild () (EBlock (DoLet false false (PVar "i") (EUnOp "!" (EFieldAccess (EVar "list") "live"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "pc")) (EFieldAccess (EVar "list") "dense"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "slots")) (EFieldAccess (EVar "list") "slots"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "list") "live")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))))))))
(DTypeSig false "assertHolds" (TyFun (TyCon "Vm") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "assertHolds" ((PVar "vm") (PVar "kind") (PVar "pos")) (EIf (EBinOp "==" (EVar "kind") (EVar "asStart")) (EBinOp "||" (EBinOp "==" (EVar "pos") (EFieldAccess (EVar "vm") "subjStart")) (EBinOp "&&" (EFieldAccess (EVar "vm") "multi") (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "pos") (ELit (LInt 1)))) (EFieldAccess (EVar "vm") "codes")) (ELit (LInt 10))))) (EIf (EBinOp "==" (EVar "kind") (EVar "asEnd")) (EBinOp "||" (EBinOp "==" (EVar "pos") (EFieldAccess (EVar "vm") "subjEnd")) (EBinOp "&&" (EFieldAccess (EVar "vm") "multi") (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pos")) (EFieldAccess (EVar "vm") "codes")) (ELit (LInt 10))))) (EIf (EBinOp "==" (EVar "kind") (EVar "asWordB")) (EBinOp "/=" (EApp (EApp (EVar "wordAt") (EVar "vm")) (EBinOp "-" (EVar "pos") (ELit (LInt 1)))) (EApp (EApp (EVar "wordAt") (EVar "vm")) (EVar "pos"))) (EBinOp "==" (EApp (EApp (EVar "wordAt") (EVar "vm")) (EBinOp "-" (EVar "pos") (ELit (LInt 1)))) (EApp (EApp (EVar "wordAt") (EVar "vm")) (EVar "pos")))))))
(DTypeSig false "wordAt" (TyFun (TyCon "Vm") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "wordAt" ((PVar "vm") (PVar "i")) (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "i") (EFieldAccess (EVar "vm") "subjStart")) (EBinOp "<" (EVar "i") (EFieldAccess (EVar "vm") "subjEnd"))) (EApp (EVar "isWordCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EFieldAccess (EVar "vm") "codes")))))
(DTypeSig false "stepThreads" (TyFun (TyCon "Vm") (TyFun (TyCon "ThreadList") (TyFun (TyCon "ThreadList") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit")))))))
(DFunDef false "stepThreads" ((PVar "vm") (PVar "clist") (PVar "nlist") (PVar "pos") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EUnOp "!" (EFieldAccess (EVar "clist") "live"))) (ELit LUnit) (EBlock (DoLet false false (PVar "pc") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EFieldAccess (EVar "clist") "dense"))) (DoLet false false (PVar "slots") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EFieldAccess (EVar "clist") "slots"))) (DoExpr (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pc")) (EFieldAccess (EVar "vm") "prog")) (arm (PCon "IChar" (PVar "ch")) () (EBlock (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EVar "pos") (EFieldAccess (EVar "vm") "subjEnd")) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pos")) (EFieldAccess (EVar "vm") "codes")) (EVar "ch"))) (EApp (EApp (EApp (EApp (EApp (EVar "addThread") (EVar "vm")) (EVar "nlist")) (EBinOp "+" (EVar "pc") (ELit (LInt 1)))) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "slots")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "stepThreads") (EVar "vm")) (EVar "clist")) (EVar "nlist")) (EVar "pos")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))) (arm (PCon "ISet" (PVar "rs") (PVar "negated")) () (EBlock (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EVar "pos") (EFieldAccess (EVar "vm") "subjEnd")) (EApp (EApp (EApp (EVar "setMatches") (EVar "rs")) (EVar "negated")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pos")) (EFieldAccess (EVar "vm") "codes")))) (EApp (EApp (EApp (EApp (EApp (EVar "addThread") (EVar "vm")) (EVar "nlist")) (EBinOp "+" (EVar "pc") (ELit (LInt 1)))) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "slots")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "stepThreads") (EVar "vm")) (EVar "clist")) (EVar "nlist")) (EVar "pos")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))) (arm (PCon "IAny" (PVar "dotAll")) () (EBlock (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EVar "pos") (EFieldAccess (EVar "vm") "subjEnd")) (EBinOp "||" (EVar "dotAll") (EBinOp "/=" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pos")) (EFieldAccess (EVar "vm") "codes")) (ELit (LInt 10))))) (EApp (EApp (EApp (EApp (EApp (EVar "addThread") (EVar "vm")) (EVar "nlist")) (EBinOp "+" (EVar "pc") (ELit (LInt 1)))) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "slots")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "stepThreads") (EVar "vm")) (EVar "clist")) (EVar "nlist")) (EVar "pos")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))) (arm (PCon "IMatch") () (EIf (EBinOp "&&" (EFieldAccess (EVar "vm") "anchorEnd") (EBinOp "/=" (EVar "pos") (EFieldAccess (EVar "vm") "subjEnd"))) (EApp (EApp (EApp (EApp (EApp (EVar "stepThreads") (EVar "vm")) (EVar "clist")) (EVar "nlist")) (EVar "pos")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBlock (DoLet false false (PVar "done") (EApp (EVar "arrayCopy") (EVar "slots"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (ELit (LInt 1))) (EVar "pos")) (EVar "done"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "vm") "found")) (EApp (EVar "Some") (EVar "done"))))))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EVar "stepThreads") (EVar "vm")) (EVar "clist")) (EVar "nlist")) (EVar "pos")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))))
(DTypeSig false "seedThread" (TyFun (TyCon "Vm") (TyFun (TyCon "ThreadList") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Unit")))))))
(DFunDef false "seedThread" ((PVar "vm") (PVar "clist") (PVar "pos") (PVar "startAt") (PVar "anchorStart")) (EIf (EBinOp "||" (EApp (EVar "foundYet") (EVar "vm")) (EBinOp "&&" (EVar "anchorStart") (EBinOp "/=" (EVar "pos") (EVar "startAt")))) (ELit LUnit) (EBlock (DoLet false false (PVar "slots") (EApp (EApp (EVar "arrayMake") (EFieldAccess (EVar "vm") "nslots")) (EUnOp "-" (ELit (LInt 1))))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (ELit (LInt 0))) (EVar "pos")) (EVar "slots"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "addThread") (EVar "vm")) (EVar "clist")) (ELit (LInt 0))) (EVar "pos")) (EVar "slots"))))))
(DTypeSig false "vmSearch" (TyFun (TyCon "Vm") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int")))))))
(DFunDef false "vmSearch" ((PVar "vm") (PVar "startAt") (PVar "anchorStart")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EFieldAccess (EVar "vm") "prog"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "vmLoop") (EVar "vm")) (EVar "startAt")) (EVar "anchorStart")) (EVar "startAt")) (EApp (EVar "newThreads") (EVar "n"))) (EApp (EVar "newThreads") (EVar "n"))))))
(DTypeSig false "vmLoop" (TyFun (TyCon "Vm") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyCon "ThreadList") (TyFun (TyCon "ThreadList") (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int"))))))))))
(DFunDef false "vmLoop" ((PVar "vm") (PVar "startAt") (PVar "anchorStart") (PVar "pos") (PVar "clist") (PVar "nlist")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "seedThread") (EVar "vm")) (EVar "clist")) (EVar "pos")) (EVar "startAt")) (EVar "anchorStart"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "==" (EUnOp "!" (EFieldAccess (EVar "clist") "live")) (ELit (LInt 0))) (EBinOp "||" (EApp (EVar "foundYet") (EVar "vm")) (EVar "anchorStart"))) (EUnOp "!" (EFieldAccess (EVar "vm") "found")) (EBlock (DoExpr (EApp (EVar "resetThreads") (EVar "nlist"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "stepThreads") (EVar "vm")) (EVar "clist")) (EVar "nlist")) (EVar "pos")) (ELit (LInt 0)))) (DoExpr (EIf (EBinOp ">=" (EVar "pos") (EFieldAccess (EVar "vm") "subjEnd")) (EUnOp "!" (EFieldAccess (EVar "vm") "found")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "vmLoop") (EVar "vm")) (EVar "startAt")) (EVar "anchorStart")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "nlist")) (EVar "clist")))))))))
(DTypeSig false "codesOf" (TyFun (TyCon "String") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "codesOf" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "toChars") (EVar "s"))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EApp (EVar "arrayLength") (EVar "cs"))) (ELam ((PVar "i")) (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))))))))
(DTypeSig false "searchFrom" (TyFun (TyCon "Regex") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int"))))))))))
(DFunDef false "searchFrom" ((PVar "re") (PVar "codes") (PVar "startAt") (PVar "anchorStart") (PVar "anchorEnd") (PVar "steps")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "searchWindow") (EVar "re")) (EVar "codes")) (ETuple (ELit (LInt 0)) (EApp (EVar "arrayLength") (EVar "codes")))) (EVar "startAt")) (EVar "anchorStart")) (EVar "anchorEnd")) (EVar "steps")))
(DTypeSig false "searchWindow" (TyFun (TyCon "Regex") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int")))))))))))
(DFunDef false "searchWindow" ((PVar "re") (PVar "codes") (PTuple (PVar "lo") (PVar "hi")) (PVar "startAt") (PVar "anchorStart") (PVar "anchorEnd") (PVar "steps")) (EBlock (DoLet false false (PVar "vm") (ERecordCreate "Vm" ((fa "prog" (EFieldAccess (EVar "re") "prog")) (fa "codes" (EVar "codes")) (fa "subjStart" (EVar "lo")) (fa "subjEnd" (EVar "hi")) (fa "multi" (EFieldAccess (EVar "re") "multiline")) (fa "anchorEnd" (EVar "anchorEnd")) (fa "nslots" (EBinOp "*" (ELit (LInt 2)) (EBinOp "+" (EFieldAccess (EVar "re") "ngroups") (ELit (LInt 1))))) (fa "steps" (EVar "steps")) (fa "found" (EApp (EVar "Ref") (EVar "None")))))) (DoExpr (EApp (EApp (EApp (EVar "vmSearch") (EVar "vm")) (EVar "startAt")) (EVar "anchorStart")))))
(DTypeSig false "clampWindow" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "clampWindow" ((PVar "codes") (PVar "start") (PVar "end")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "codes"))) (DoLet false false (PVar "hi") (EApp (EApp (EVar "max") (ELit (LInt 0))) (EApp (EApp (EVar "min") (EVar "end")) (EVar "n")))) (DoExpr (ETuple (EApp (EApp (EVar "max") (ELit (LInt 0))) (EApp (EApp (EVar "min") (EVar "start")) (EVar "hi"))) (EVar "hi")))))
(DTypeSig false "findSteps" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "findSteps" ((PVar "re") (PVar "s")) (EBlock (DoLet false false (PVar "steps") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "searchFrom") (EVar "re")) (EApp (EVar "codesOf") (EVar "s"))) (ELit (LInt 0))) (EVar "False")) (EVar "False")) (EVar "steps"))) (DoExpr (EUnOp "!" (EVar "steps")))))
(DTypeSig false "mkMatchWith" (TyFun (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Regex") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Match")))))
(DFunDef false "mkMatchWith" ((PVar "textOf") (PVar "re") (PVar "slots")) (EBlock (DoLet false false (PVar "lo") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "slots"))) (DoLet false false (PVar "hi") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 1))) (EVar "slots"))) (DoExpr (ERecordCreate "Match" ((fa "start" (EVar "lo")) (fa "end" (EVar "hi")) (fa "text" (EApp (EApp (EVar "textOf") (EVar "lo")) (EVar "hi"))) (fa "groups" (EApp (EApp (EApp (EApp (EVar "groupsOfWith") (EVar "textOf")) (EVar "re")) (EVar "slots")) (ELit (LInt 1)))))))))
(DTypeSig false "groupsOfWith" (TyFun (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Regex") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Group"))))))))
(DFunDef false "groupsOfWith" ((PVar "textOf") (PVar "re") (PVar "slots") (PVar "k")) (EIf (EBinOp ">" (EVar "k") (EFieldAccess (EVar "re") "ngroups")) (EListLit) (EBlock (DoLet false false (PVar "lo") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "*" (ELit (LInt 2)) (EVar "k"))) (EVar "slots"))) (DoLet false false (PVar "hi") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EBinOp "*" (ELit (LInt 2)) (EVar "k")) (ELit (LInt 1)))) (EVar "slots"))) (DoLet false false (PVar "g") (EIf (EBinOp "||" (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (EBinOp "<" (EVar "hi") (ELit (LInt 0)))) (EVar "None") (EApp (EVar "Some") (ERecordCreate "Group" ((fa "start" (EVar "lo")) (fa "end" (EVar "hi")) (fa "text" (EApp (EApp (EVar "textOf") (EVar "lo")) (EVar "hi")))))))) (DoExpr (EBinOp "::" (EVar "g") (EApp (EApp (EApp (EApp (EVar "groupsOfWith") (EVar "textOf")) (EVar "re")) (EVar "slots")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))))))))
(DTypeSig false "mkMatch" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Match")))))
(DFunDef false "mkMatch" ((PVar "re") (PVar "s") (PVar "slots")) (EApp (EApp (EApp (EVar "mkMatchWith") (ELam ((PVar "lo") (PVar "hi")) (EApp (EApp (EApp (EVar "sliceClamped") (EVar "lo")) (EVar "hi")) (EVar "s")))) (EVar "re")) (EVar "slots")))
(DTypeSig false "matchOnce" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Match"))))))))
(DFunDef false "matchOnce" ((PVar "re") (PVar "s") (PVar "startAt") (PVar "anchorStart") (PVar "anchorEnd")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "mkMatch") (EVar "re")) (EVar "s"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "searchFrom") (EVar "re")) (EApp (EVar "codesOf") (EVar "s"))) (EVar "startAt")) (EVar "anchorStart")) (EVar "anchorEnd")) (EApp (EVar "Ref") (ELit (LInt 0))))))
(DTypeSig true "compile" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "RegexError")) (TyCon "Regex"))))
(DFunDef false "compile" ((PVar "pattern")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "toChars") (EVar "pattern"))) (DoLet false false (PTuple (PVar "start") (PVar "fold") (PVar "multi") (PVar "dotAll")) (EApp (EApp (EApp (EApp (EApp (EVar "scanFlags") (EVar "cs")) (ELit (LInt 0))) (EVar "False")) (EVar "False")) (EVar "False"))) (DoLet false false (PVar "st") (ERecordCreate "PState" ((fa "pat" (EVar "cs")) (fa "pos" (EApp (EVar "Ref") (EVar "start"))) (fa "ngroups" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "perr" (EApp (EVar "Ref") (EVar "None"))) (fa "fold" (EVar "fold")) (fa "dotAll" (EVar "dotAll"))))) (DoLet false false (PVar "node") (EApp (EVar "parseAlt") (EVar "st"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "finishCompile") (EVar "st")) (EVar "node")) (EVar "pattern")) (EVar "multi")))))
(DTypeSig false "finishCompile" (TyFun (TyCon "PState") (TyFun (TyCon "Node") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyApp (TyApp (TyCon "Result") (TyCon "RegexError")) (TyCon "Regex")))))))
(DFunDef false "finishCompile" ((PVar "st") (PVar "node") (PVar "pattern") (PVar "multi")) (EMatch (EUnOp "!" (EFieldAccess (EVar "st") "perr")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "None") () (EIf (EApp (EVar "not") (EApp (EVar "atEnd") (EVar "st"))) (EApp (EVar "Err") (ERecordCreate "RegexError" ((fa "message" (ELit (LString "unbalanced closing )"))) (fa "position" (EUnOp "!" (EFieldAccess (EVar "st") "pos")))))) (EBlock (DoLet false false (PVar "insts") (EBinOp "++" (EApp (EApp (EVar "compileNode") (EVar "node")) (ELit (LInt 0))) (EListLit (EVar "IMatch")))) (DoExpr (EIf (EBinOp ">" (EApp (EVar "length") (EVar "insts")) (EVar "progCap")) (EApp (EVar "Err") (ERecordCreate "RegexError" ((fa "message" (ELit (LString "pattern compiles to more than 20000 instructions"))) (fa "position" (ELit (LInt 0)))))) (EApp (EVar "Ok") (ERecordCreate "Regex" ((fa "src" (EVar "pattern")) (fa "prog" (EApp (EVar "arrayFromList") (EVar "insts"))) (fa "ngroups" (EUnOp "!" (EFieldAccess (EVar "st") "ngroups"))) (fa "multiline" (EVar "multi"))))))))))))
(DTypeSig true "mustCompile" (TyFun (TyCon "String") (TyCon "Regex")))
(DFunDef false "mustCompile" ((PVar "pattern")) (EMatch (EApp (EVar "compile") (EVar "pattern")) (arm (PCon "Ok" (PVar "re")) () (EVar "re")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "regex: ")) (EApp (EVar "display") (EFieldAccess (EVar "e") "message"))) (ELit (LString " at position "))) (EApp (EVar "display") (EApp (EVar "intToString") (EFieldAccess (EVar "e") "position")))) (ELit (LString " in "))) (EApp (EVar "display") (EApp (EVar "debugStringLit") (EVar "pattern")))) (ELit (LString "")))))))
(DTypeSig true "source" (TyFun (TyCon "Regex") (TyCon "String")))
(DFunDef false "source" ((PVar "re")) (EFieldAccess (EVar "re") "src"))
(DTypeSig true "escape" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "escape" ((PVar "s")) (EApp (EVar "fromChars") (EApp (EApp (EVar "escapeGo") (EApp (EVar "toChars") (EVar "s"))) (ELit (LInt 0)))))
(DTypeSig false "escapeGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char")))))
(DFunDef false "escapeGo" ((PVar "cs") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (DoExpr (EIf (EApp (EVar "isMeta") (EVar "c")) (EBinOp "::" (ELit (LChar "\\")) (EBinOp "::" (EVar "c") (EApp (EApp (EVar "escapeGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EBinOp "::" (EVar "c") (EApp (EApp (EVar "escapeGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))))
(DTypeSig false "isMeta" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isMeta" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "\\"))) (EBinOp "==" (EVar "c") (ELit (LChar ".")))) (EBinOp "==" (EVar "c") (ELit (LChar "+")))) (EBinOp "==" (EVar "c") (ELit (LChar "*")))) (EBinOp "==" (EVar "c") (ELit (LChar "?")))) (EBinOp "==" (EVar "c") (ELit (LChar "(")))) (EBinOp "==" (EVar "c") (ELit (LChar ")")))) (EBinOp "==" (EVar "c") (ELit (LChar "|")))) (EBinOp "==" (EVar "c") (ELit (LChar "[")))) (EBinOp "==" (EVar "c") (ELit (LChar "]")))) (EBinOp "==" (EVar "c") (ELit (LChar "{")))) (EBinOp "==" (EVar "c") (ELit (LChar "}")))) (EBinOp "==" (EVar "c") (ELit (LChar "^")))) (EBinOp "==" (EVar "c") (ELit (LChar "$")))))
(DTypeSig true "isMatch" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isMatch" ((PVar "re") (PVar "s")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "searchFrom") (EVar "re")) (EApp (EVar "codesOf") (EVar "s"))) (ELit (LInt 0))) (EVar "False")) (EVar "False")) (EApp (EVar "Ref") (ELit (LInt 0)))) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "isFullMatch" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isFullMatch" ((PVar "re") (PVar "s")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "searchFrom") (EVar "re")) (EApp (EVar "codesOf") (EVar "s"))) (ELit (LInt 0))) (EVar "True")) (EVar "True")) (EApp (EVar "Ref") (ELit (LInt 0)))) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "find" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Match")))))
(DFunDef false "find" ((PVar "re") (PVar "s")) (EApp (EApp (EApp (EApp (EApp (EVar "matchOnce") (EVar "re")) (EVar "s")) (ELit (LInt 0))) (EVar "False")) (EVar "False")))
(DTypeSig true "findFrom" (TyFun (TyCon "Int") (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Match"))))))
(DFunDef false "findFrom" ((PVar "from") (PVar "re") (PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoLet false false (PVar "at") (EApp (EApp (EVar "max") (ELit (LInt 0))) (EApp (EApp (EVar "min") (EVar "from")) (EVar "n")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "matchOnce") (EVar "re")) (EVar "s")) (EVar "at")) (EVar "False")) (EVar "False")))))
(DTypeSig true "fullMatch" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Match")))))
(DFunDef false "fullMatch" ((PVar "re") (PVar "s")) (EApp (EApp (EApp (EApp (EApp (EVar "matchOnce") (EVar "re")) (EVar "s")) (ELit (LInt 0))) (EVar "True")) (EVar "True")))
(DTypeSig true "isFullMatchBytes" (TyFun (TyCon "Regex") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "isFullMatchBytes" ((PVar "re") (PVar "bytes") (PVar "start") (PVar "end")) (EBlock (DoLet false false (PTuple (PVar "lo") (PVar "hi")) (EApp (EApp (EApp (EVar "clampWindow") (EVar "bytes")) (EVar "start")) (EVar "end"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "searchWindow") (EVar "re")) (EVar "bytes")) (ETuple (EVar "lo") (EVar "hi"))) (EVar "lo")) (EVar "True")) (EVar "True")) (EApp (EVar "Ref") (ELit (LInt 0)))) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))))
(DTypeSig true "findBytes" (TyFun (TyCon "Regex") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Match")))))))
(DFunDef false "findBytes" ((PVar "re") (PVar "bytes") (PVar "start") (PVar "end")) (EBlock (DoLet false false (PTuple (PVar "lo") (PVar "hi")) (EApp (EApp (EApp (EVar "clampWindow") (EVar "bytes")) (EVar "start")) (EVar "end"))) (DoExpr (EApp (EApp (EVar "map") (EApp (EApp (EVar "mkMatchWith") (ELam ((PVar "from") (PVar "to")) (EApp (EVar "fromUtf8") (EApp (EApp (EApp (EVar "sliceBytes") (EVar "from")) (EVar "to")) (EVar "bytes"))))) (EVar "re"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "searchWindow") (EVar "re")) (EVar "bytes")) (ETuple (EVar "lo") (EVar "hi"))) (EVar "lo")) (EVar "False")) (EVar "False")) (EApp (EVar "Ref") (ELit (LInt 0))))))))
(DTypeSig true "findAll" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Match")))))
(DFunDef false "findAll" ((PVar "re") (PVar "s")) (EApp (EVar "reverse") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findAllGo") (EVar "re")) (EVar "s")) (EApp (EVar "codesOf") (EVar "s"))) (ELit (LInt 0))) (EUnOp "-" (ELit (LInt 1)))) (EListLit))))
(DTypeSig false "findAllGo" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Match")) (TyApp (TyCon "List") (TyCon "Match")))))))))
(DFunDef false "findAllGo" ((PVar "re") (PVar "s") (PVar "codes") (PVar "pos") (PVar "prevEnd") (PVar "acc")) (EIf (EBinOp ">" (EVar "pos") (EApp (EVar "arrayLength") (EVar "codes"))) (EVar "acc") (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "searchFrom") (EVar "re")) (EVar "codes")) (EVar "pos")) (EVar "False")) (EVar "False")) (EApp (EVar "Ref") (ELit (LInt 0)))) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PVar "slots")) () (EBlock (DoLet false false (PVar "lo") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "slots"))) (DoLet false false (PVar "hi") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 1))) (EVar "slots"))) (DoLet false false (PVar "keep") (EApp (EVar "not") (EBinOp "&&" (EBinOp "==" (EVar "hi") (EVar "lo")) (EBinOp "==" (EVar "lo") (EVar "prevEnd"))))) (DoLet false false (PVar "next") (EIf (EBinOp "==" (EVar "hi") (EVar "lo")) (EBinOp "+" (EVar "lo") (ELit (LInt 1))) (EVar "hi"))) (DoLet false false (PVar "acc2") (EIf (EVar "keep") (EBinOp "::" (EApp (EApp (EApp (EVar "mkMatch") (EVar "re")) (EVar "s")) (EVar "slots")) (EVar "acc")) (EVar "acc"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findAllGo") (EVar "re")) (EVar "s")) (EVar "codes")) (EVar "next")) (EVar "hi")) (EVar "acc2"))))))))
(DTypeSig true "replace" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "replace" ((PVar "re") (PVar "repl") (PVar "s")) (EMatch (EApp (EApp (EVar "find") (EVar "re")) (EVar "s")) (arm (PCon "None") () (EVar "s")) (arm (PCon "Some" (PVar "m")) () (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 0))) (EFieldAccess (EVar "m") "start")) (EVar "s")) (EApp (EApp (EVar "expandRepl") (EVar "repl")) (EVar "m"))) (EApp (EApp (EApp (EVar "sliceClamped") (EFieldAccess (EVar "m") "end")) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s"))))))
(DTypeSig true "replaceAll" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "replaceAll" ((PVar "re") (PVar "repl") (PVar "s")) (EApp (EApp (EApp (EVar "replaceAllWith") (EVar "re")) (ELam ((PVar "m")) (EApp (EApp (EVar "expandRepl") (EVar "repl")) (EVar "m")))) (EVar "s")))
(DTypeSig true "replaceAllWith" (TyFun (TyCon "Regex") (TyFun (TyFun (TyCon "Match") (TyEffect () (Some "e") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect () (Some "e") (TyCon "String"))))))
(DFunDef false "replaceAllWith" ((PVar "re") (PVar "f") (PVar "s")) (EApp (EVar "stringConcat") (EApp (EVar "reverse") (EApp (EApp (EApp (EApp (EApp (EVar "stitch") (EVar "f")) (EVar "s")) (EApp (EApp (EVar "findAll") (EVar "re")) (EVar "s"))) (ELit (LInt 0))) (EListLit)))))
(DTypeSig false "stitch" (TyFun (TyFun (TyCon "Match") (TyEffect () (Some "e") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Match")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "stitch" (PWild (PVar "s") (PList) (PVar "beg") (PVar "acc")) (EBinOp "::" (EApp (EApp (EApp (EVar "sliceClamped") (EVar "beg")) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EVar "acc")))
(DFunDef false "stitch" ((PVar "f") (PVar "s") (PCons (PVar "m") (PVar "rest")) (PVar "beg") (PVar "acc")) (EBlock (DoLet false false (PVar "piece") (EApp (EApp (EApp (EVar "sliceClamped") (EVar "beg")) (EFieldAccess (EVar "m") "start")) (EVar "s"))) (DoLet false false (PVar "replaced") (EApp (EVar "f") (EVar "m"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "stitch") (EVar "f")) (EVar "s")) (EVar "rest")) (EFieldAccess (EVar "m") "end")) (EBinOp "::" (EVar "replaced") (EBinOp "::" (EVar "piece") (EVar "acc")))))))
(DTypeSig false "expandRepl" (TyFun (TyCon "String") (TyFun (TyCon "Match") (TyCon "String"))))
(DFunDef false "expandRepl" ((PVar "repl") (PVar "m")) (EApp (EVar "stringConcat") (EApp (EVar "reverse") (EApp (EApp (EApp (EApp (EVar "expandGo") (EApp (EVar "toChars") (EVar "repl"))) (ELit (LInt 0))) (EVar "m")) (EListLit)))))
(DTypeSig false "expandGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Match") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "expandGo" ((PVar "cs") (PVar "i") (PVar "m") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EVar "acc") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "$"))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "cs")))) (EBlock (DoLet false false (PVar "d") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "cs"))) (DoExpr (EIf (EBinOp "==" (EVar "d") (ELit (LChar "$"))) (EApp (EApp (EApp (EApp (EVar "expandGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "m")) (EBinOp "::" (ELit (LString "$")) (EVar "acc"))) (EIf (EApp (EVar "isDigit") (EVar "d")) (EApp (EApp (EApp (EApp (EVar "expandGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "m")) (EBinOp "::" (EApp (EApp (EVar "groupText") (EVar "m")) (EBinOp "-" (EApp (EVar "charCode") (EVar "d")) (ELit (LInt 48)))) (EVar "acc"))) (EApp (EApp (EApp (EApp (EVar "expandGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "m")) (EBinOp "::" (ELit (LString "$")) (EVar "acc"))))))) (EApp (EApp (EApp (EApp (EVar "expandGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "m")) (EBinOp "::" (EApp (EVar "charToStr") (EVar "c")) (EVar "acc"))))))))
(DTypeSig false "groupText" (TyFun (TyCon "Match") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "groupText" ((PVar "m") (PLit (LInt 0))) (EFieldAccess (EVar "m") "text"))
(DFunDef false "groupText" ((PVar "m") (PVar "k")) (EMatch (EApp (EApp (EVar "get") (EBinOp "-" (EVar "k") (ELit (LInt 1)))) (EFieldAccess (EVar "m") "groups")) (arm (PCon "Some" (PCon "Some" (PVar "g"))) () (EFieldAccess (EVar "g") "text")) (arm PWild () (ELit (LString "")))))
(DTypeSig true "split" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "split" ((PVar "re") (PVar "s")) (EApp (EVar "reverse") (EApp (EApp (EApp (EApp (EApp (EVar "splitGo") (EVar "s")) (EApp (EApp (EVar "findAll") (EVar "re")) (EVar "s"))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit))))
(DTypeSig false "splitGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Match")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "splitGo" ((PVar "s") (PList) (PVar "beg") (PVar "lastStart") (PVar "acc")) (EIf (EBinOp "/=" (EVar "lastStart") (EApp (EVar "stringLength") (EVar "s"))) (EBinOp "::" (EApp (EApp (EApp (EVar "sliceClamped") (EVar "beg")) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EVar "acc")) (EVar "acc")))
(DFunDef false "splitGo" ((PVar "s") (PCons (PVar "m") (PVar "rest")) (PVar "beg") PWild (PVar "acc")) (EBlock (DoLet false false (PVar "acc2") (EIf (EBinOp "/=" (EFieldAccess (EVar "m") "end") (ELit (LInt 0))) (EBinOp "::" (EApp (EApp (EApp (EVar "sliceClamped") (EVar "beg")) (EFieldAccess (EVar "m") "start")) (EVar "s")) (EVar "acc")) (EVar "acc"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "splitGo") (EVar "s")) (EVar "rest")) (EFieldAccess (EVar "m") "end")) (EFieldAccess (EVar "m") "start")) (EVar "acc2")))))
(DProp false "escape s full-matches exactly s" ((pp "s" (TyCon "String"))) (EApp (EApp (EVar "isFullMatch") (EApp (EVar "mustCompile") (EApp (EVar "escape") (EVar "s")))) (EVar "s")))
(DProp false "split on a literal separator rejoins to the subject" ((pp "s" (TyCon "String"))) (EBinOp "==" (EApp (EVar "stringConcat") (EApp (EVar "intersperseComma") (EApp (EApp (EVar "split") (EVar "commaRe")) (EVar "s")))) (EVar "s")))
(DTypeSig false "commaRe" (TyCon "Regex"))
(DFunDef false "commaRe" () (EApp (EVar "mustCompile") (ELit (LString ","))))
(DTypeSig false "intersperseComma" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "intersperseComma" ((PList)) (EListLit))
(DFunDef false "intersperseComma" ((PCons (PVar "x") (PList))) (EListLit (EVar "x")))
(DFunDef false "intersperseComma" ((PCons (PVar "x") (PVar "rest"))) (EBinOp "::" (EVar "x") (EBinOp "::" (ELit (LString ",")) (EApp (EVar "intersperseComma") (EVar "rest")))))
(DProp false "findAll spans are ascending and disjoint" ((pp "s" (TyCon "String"))) (EApp (EApp (EVar "spansOrdered") (EApp (EApp (EVar "findAll") (EApp (EVar "mustCompile") (ELit (LString "[a-z]+|.")))) (EVar "s"))) (ELit (LInt 0))))
(DTypeSig false "spansOrdered" (TyFun (TyApp (TyCon "List") (TyCon "Match")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "spansOrdered" ((PList) PWild) (EVar "True"))
(DFunDef false "spansOrdered" ((PCons (PVar "m") (PVar "rest")) (PVar "floor")) (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EFieldAccess (EVar "m") "start") (EVar "floor")) (EBinOp ">=" (EFieldAccess (EVar "m") "end") (EFieldAccess (EVar "m") "start"))) (EApp (EApp (EVar "spansOrdered") (EVar "rest")) (EFieldAccess (EVar "m") "end"))))
# MARK
(DUse false (UseGroup ("array") ((mem "sliceClamped" false "sliceBytes"))))
(DUse false (UseGroup ("list") ((mem "get" false) (mem "reverse" false))))
(DUse false (UseGroup ("string") ((mem "fromChars" false) (mem "fromUtf8" false) (mem "isDigit" false) (mem "repeat" false) (mem "sliceClamped" false) (mem "toChars" false))))
(DData Abstract "Regex" () ((variant "Regex" (ConNamed (field "src" (TyCon "String")) (field "prog" (TyApp (TyCon "Array") (TyCon "Inst"))) (field "ngroups" (TyCon "Int")) (field "multiline" (TyCon "Bool"))))) ())
(DData Public "RegexError" () ((variant "RegexError" (ConNamed (field "message" (TyCon "String")) (field "position" (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "RegexError")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "RegexError" ((rf "message" (PVar "__a0")) (rf "position" (PVar "__a1"))) false) (PRec "RegexError" ((rf "message" (PVar "__b0")) (rf "position" (PVar "__b1"))) false)) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Debug" ((TyCon "RegexError")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "RegexError" ((rf "message" (PVar "__a0")) (rf "position" (PVar "__a1"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "RegexError {")) (ELit (LString " message = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", position = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString " }"))))))))
(DData Public "Group" () ((variant "Group" (ConNamed (field "start" (TyCon "Int")) (field "end" (TyCon "Int")) (field "text" (TyCon "String"))))) ())
(DImpl true "Eq" ((TyCon "Group")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Group" ((rf "start" (PVar "__a0")) (rf "end" (PVar "__a1")) (rf "text" (PVar "__a2"))) false) (PRec "Group" ((rf "start" (PVar "__b0")) (rf "end" (PVar "__b1")) (rf "text" (PVar "__b2"))) false)) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))))))))
(DImpl true "Debug" ((TyCon "Group")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "Group" ((rf "start" (PVar "__a0")) (rf "end" (PVar "__a1")) (rf "text" (PVar "__a2"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Group {")) (ELit (LString " start = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", end = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", text = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString " }"))))))))
(DData Public "Match" () ((variant "Match" (ConNamed (field "start" (TyCon "Int")) (field "end" (TyCon "Int")) (field "text" (TyCon "String")) (field "groups" (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Group"))))))) ())
(DImpl true "Eq" ((TyCon "Match")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "Match" ((rf "start" (PVar "__a0")) (rf "end" (PVar "__a1")) (rf "text" (PVar "__a2")) (rf "groups" (PVar "__a3"))) false) (PRec "Match" ((rf "start" (PVar "__b0")) (rf "end" (PVar "__b1")) (rf "text" (PVar "__b2")) (rf "groups" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "Match")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "Match" ((rf "start" (PVar "__a0")) (rf "end" (PVar "__a1")) (rf "text" (PVar "__a2")) (rf "groups" (PVar "__a3"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Match {")) (ELit (LString " start = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", end = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", text = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString ", groups = "))) (EApp (EMethodRef "debug") (EVar "__a3"))) (ELit (LString " }"))))))))
(DImpl true "Debug" ((TyCon "Regex")) () ((im "debug" ((PVar "re")) (EBinOp "++" (ELit (LString "regex ")) (EApp (EVar "debugStringLit") (EFieldAccess (EVar "re") "src"))))))
(DTypeSig false "maxCode" (TyCon "Int"))
(DFunDef false "maxCode" () (ELit (LInt 1114111)))
(DTypeSig false "digitRanges" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "digitRanges" () (EListLit (ETuple (ELit (LInt 48)) (ELit (LInt 57)))))
(DTypeSig false "wordRanges" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "wordRanges" () (EListLit (ETuple (ELit (LInt 48)) (ELit (LInt 57))) (ETuple (ELit (LInt 65)) (ELit (LInt 90))) (ETuple (ELit (LInt 95)) (ELit (LInt 95))) (ETuple (ELit (LInt 97)) (ELit (LInt 122)))))
(DTypeSig false "spaceRanges" (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))
(DFunDef false "spaceRanges" () (EListLit (ETuple (ELit (LInt 9)) (ELit (LInt 10))) (ETuple (ELit (LInt 13)) (ELit (LInt 13))) (ETuple (ELit (LInt 32)) (ELit (LInt 32)))))
(DTypeSig false "wordSet" (TyApp (TyCon "Array") (TyCon "Int")))
(DFunDef false "wordSet" () (EApp (EVar "flattenRanges") (EVar "wordRanges")))
(DTypeSig false "flattenRanges" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "flattenRanges" ((PVar "rs")) (EApp (EVar "arrayFromList") (EApp (EVar "flattenGo") (EVar "rs"))))
(DTypeSig false "flattenGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyCon "Int"))))
(DFunDef false "flattenGo" ((PList)) (EListLit))
(DFunDef false "flattenGo" ((PCons (PTuple (PVar "lo") (PVar "hi")) (PVar "rest"))) (EBinOp "::" (EVar "lo") (EBinOp "::" (EVar "hi") (EApp (EVar "flattenGo") (EVar "rest")))))
(DTypeSig false "complementRanges" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "complementRanges" ((PVar "rs")) (EApp (EApp (EVar "complementGo") (EVar "rs")) (ELit (LInt 0))))
(DTypeSig false "complementGo" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "complementGo" ((PList) (PVar "next")) (EIf (EBinOp ">" (EVar "next") (EVar "maxCode")) (EListLit) (EListLit (ETuple (EVar "next") (EVar "maxCode")))))
(DFunDef false "complementGo" ((PCons (PTuple (PVar "lo") (PVar "hi")) (PVar "rest")) (PVar "next")) (EBlock (DoLet false false (PVar "after") (EApp (EApp (EMethodRef "max") (EBinOp "+" (EVar "hi") (ELit (LInt 1)))) (EVar "next"))) (DoExpr (EIf (EBinOp ">" (EVar "lo") (EVar "next")) (EBinOp "::" (ETuple (EVar "next") (EBinOp "-" (EVar "lo") (ELit (LInt 1)))) (EApp (EApp (EVar "complementGo") (EVar "rest")) (EVar "after"))) (EApp (EApp (EVar "complementGo") (EVar "rest")) (EVar "after"))))))
(DTypeSig false "inRanges" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "inRanges" ((PVar "rs") (PVar "i") (PVar "c")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "rs"))) (EVar "False") (EIf (EBinOp "&&" (EBinOp ">=" (EVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "rs"))) (EBinOp "<=" (EVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rs")))) (EVar "True") (EApp (EApp (EApp (EVar "inRanges") (EVar "rs")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "c")))))
(DTypeSig false "setMatches" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "setMatches" ((PVar "rs") (PVar "negated") (PVar "c")) (EIf (EVar "negated") (EApp (EVar "not") (EApp (EApp (EApp (EVar "inRanges") (EVar "rs")) (ELit (LInt 0))) (EVar "c"))) (EApp (EApp (EApp (EVar "inRanges") (EVar "rs")) (ELit (LInt 0))) (EVar "c"))))
(DTypeSig false "isWordCode" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isWordCode" ((PVar "c")) (EApp (EApp (EApp (EVar "inRanges") (EVar "wordSet")) (ELit (LInt 0))) (EVar "c")))
(DTypeSig false "isAsciiLetterCode" (TyFun (TyCon "Int") (TyCon "Bool")))
(DFunDef false "isAsciiLetterCode" ((PVar "c")) (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LInt 65))) (EBinOp "<=" (EVar "c") (ELit (LInt 90)))) (EBinOp "&&" (EBinOp ">=" (EVar "c") (ELit (LInt 97))) (EBinOp "<=" (EVar "c") (ELit (LInt 122))))))
(DTypeSig false "foldRanges" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "foldRanges" ((PList)) (EListLit))
(DFunDef false "foldRanges" ((PCons (PTuple (PVar "lo") (PVar "hi")) (PVar "rest"))) (EBlock (DoLet false false (PVar "upper") (EApp (EApp (EApp (EApp (EApp (EVar "clipShift") (EVar "lo")) (EVar "hi")) (ELit (LInt 97))) (ELit (LInt 122))) (EUnOp "-" (ELit (LInt 32))))) (DoLet false false (PVar "lower") (EApp (EApp (EApp (EApp (EApp (EVar "clipShift") (EVar "lo")) (EVar "hi")) (ELit (LInt 65))) (ELit (LInt 90))) (ELit (LInt 32)))) (DoExpr (EBinOp "::" (ETuple (EVar "lo") (EVar "hi")) (EBinOp "++" (EVar "upper") (EBinOp "++" (EVar "lower") (EApp (EVar "foldRanges") (EVar "rest"))))))))
(DTypeSig false "clipShift" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))))))
(DFunDef false "clipShift" ((PVar "lo") (PVar "hi") (PVar "blo") (PVar "bhi") (PVar "shift")) (EBlock (DoLet false false (PVar "l") (EApp (EApp (EMethodRef "max") (EVar "lo")) (EVar "blo"))) (DoLet false false (PVar "h") (EApp (EApp (EMethodRef "min") (EVar "hi")) (EVar "bhi"))) (DoExpr (EIf (EBinOp "<=" (EVar "l") (EVar "h")) (EListLit (ETuple (EBinOp "+" (EVar "l") (EVar "shift")) (EBinOp "+" (EVar "h") (EVar "shift")))) (EListLit)))))
(DTypeSig false "asStart" (TyCon "Int"))
(DFunDef false "asStart" () (ELit (LInt 0)))
(DTypeSig false "asEnd" (TyCon "Int"))
(DFunDef false "asEnd" () (ELit (LInt 1)))
(DTypeSig false "asWordB" (TyCon "Int"))
(DFunDef false "asWordB" () (ELit (LInt 2)))
(DTypeSig false "asNotWordB" (TyCon "Int"))
(DFunDef false "asNotWordB" () (ELit (LInt 3)))
(DData Private "Node" () ((variant "NEmpty" (ConPos)) (variant "NChar" (ConPos (TyCon "Int"))) (variant "NSet" (ConPos (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Bool"))) (variant "NAny" (ConPos (TyCon "Bool"))) (variant "NCat" (ConPos (TyCon "Node") (TyCon "Node"))) (variant "NAlt" (ConPos (TyCon "Node") (TyCon "Node"))) (variant "NStar" (ConPos (TyCon "Bool") (TyCon "Node"))) (variant "NPlus" (ConPos (TyCon "Bool") (TyCon "Node"))) (variant "NOpt" (ConPos (TyCon "Bool") (TyCon "Node"))) (variant "NGroup" (ConPos (TyCon "Int") (TyCon "Node"))) (variant "NAssert" (ConPos (TyCon "Int")))) ())
(DTypeSig false "nodeSize" (TyFun (TyCon "Node") (TyCon "Int")))
(DFunDef false "nodeSize" ((PCon "NEmpty")) (ELit (LInt 1)))
(DFunDef false "nodeSize" ((PCon "NChar" PWild)) (ELit (LInt 1)))
(DFunDef false "nodeSize" ((PCon "NSet" PWild PWild)) (ELit (LInt 1)))
(DFunDef false "nodeSize" ((PCon "NAny" PWild)) (ELit (LInt 1)))
(DFunDef false "nodeSize" ((PCon "NAssert" PWild)) (ELit (LInt 1)))
(DFunDef false "nodeSize" ((PCon "NCat" (PVar "a") (PVar "b"))) (EBinOp "+" (EApp (EVar "nodeSize") (EVar "a")) (EApp (EVar "nodeSize") (EVar "b"))))
(DFunDef false "nodeSize" ((PCon "NAlt" (PVar "a") (PVar "b"))) (EBinOp "+" (EBinOp "+" (ELit (LInt 2)) (EApp (EVar "nodeSize") (EVar "a"))) (EApp (EVar "nodeSize") (EVar "b"))))
(DFunDef false "nodeSize" ((PCon "NStar" PWild (PVar "b"))) (EBinOp "+" (ELit (LInt 2)) (EApp (EVar "nodeSize") (EVar "b"))))
(DFunDef false "nodeSize" ((PCon "NPlus" PWild (PVar "b"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "nodeSize") (EVar "b"))))
(DFunDef false "nodeSize" ((PCon "NOpt" PWild (PVar "b"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EVar "nodeSize") (EVar "b"))))
(DFunDef false "nodeSize" ((PCon "NGroup" PWild (PVar "b"))) (EBinOp "+" (ELit (LInt 2)) (EApp (EVar "nodeSize") (EVar "b"))))
(DTypeSig false "repeatCap" (TyCon "Int"))
(DFunDef false "repeatCap" () (ELit (LInt 1000)))
(DTypeSig false "progCap" (TyCon "Int"))
(DFunDef false "progCap" () (ELit (LInt 20000)))
(DData Private "PState" () ((variant "PState" (ConNamed (field "pat" (TyApp (TyCon "Array") (TyCon "Char"))) (field "pos" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "ngroups" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "perr" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "RegexError")))) (field "fold" (TyCon "Bool")) (field "dotAll" (TyCon "Bool"))))) ())
(DTypeSig false "patLen" (TyFun (TyCon "PState") (TyCon "Int")))
(DFunDef false "patLen" ((PVar "st")) (EApp (EVar "arrayLength") (EFieldAccess (EVar "st") "pat")))
(DTypeSig false "atEnd" (TyFun (TyCon "PState") (TyCon "Bool")))
(DFunDef false "atEnd" ((PVar "st")) (EBinOp ">=" (EUnOp "!" (EFieldAccess (EVar "st") "pos")) (EApp (EVar "patLen") (EVar "st"))))
(DTypeSig false "cur" (TyFun (TyCon "PState") (TyCon "Char")))
(DFunDef false "cur" ((PVar "st")) (EApp (EApp (EVar "arrayGetUnsafe") (EUnOp "!" (EFieldAccess (EVar "st") "pos"))) (EFieldAccess (EVar "st") "pat")))
(DTypeSig false "isAt" (TyFun (TyCon "PState") (TyFun (TyCon "Char") (TyCon "Bool"))))
(DFunDef false "isAt" ((PVar "st") (PVar "c")) (EBinOp "&&" (EApp (EVar "not") (EApp (EVar "atEnd") (EVar "st"))) (EBinOp "==" (EApp (EVar "cur") (EVar "st")) (EVar "c"))))
(DTypeSig false "peekIs" (TyFun (TyCon "PState") (TyFun (TyCon "Int") (TyFun (TyCon "Char") (TyCon "Bool")))))
(DFunDef false "peekIs" ((PVar "st") (PVar "k") (PVar "c")) (EBlock (DoLet false false (PVar "i") (EBinOp "+" (EUnOp "!" (EFieldAccess (EVar "st") "pos")) (EVar "k"))) (DoExpr (EBinOp "&&" (EBinOp "<" (EVar "i") (EApp (EVar "patLen") (EVar "st"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EFieldAccess (EVar "st") "pat")) (EVar "c"))))))
(DTypeSig false "peekAt" (TyFun (TyCon "PState") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Char")))))
(DFunDef false "peekAt" ((PVar "st") (PVar "k")) (EBlock (DoLet false false (PVar "i") (EBinOp "+" (EUnOp "!" (EFieldAccess (EVar "st") "pos")) (EVar "k"))) (DoExpr (EIf (EBinOp "<" (EVar "i") (EApp (EVar "patLen") (EVar "st"))) (EApp (EVar "Some") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EFieldAccess (EVar "st") "pat"))) (EVar "None")))))
(DTypeSig false "advance" (TyFun (TyCon "PState") (TyCon "Unit")))
(DFunDef false "advance" ((PVar "st")) (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "pos")) (EBinOp "+" (EUnOp "!" (EFieldAccess (EVar "st") "pos")) (ELit (LInt 1)))))
(DTypeSig false "hasErr" (TyFun (TyCon "PState") (TyCon "Bool")))
(DFunDef false "hasErr" ((PVar "st")) (EMatch (EUnOp "!" (EFieldAccess (EVar "st") "perr")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "failAt" (TyFun (TyCon "PState") (TyFun (TyCon "String") (TyCon "Unit"))))
(DFunDef false "failAt" ((PVar "st") (PVar "message")) (EMatch (EUnOp "!" (EFieldAccess (EVar "st") "perr")) (arm (PCon "Some" PWild) () (ELit LUnit)) (arm (PCon "None") () (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "perr")) (EApp (EVar "Some") (ERecordCreate "RegexError" ((fa "message" (EVar "message")) (fa "position" (EUnOp "!" (EFieldAccess (EVar "st") "pos"))))))))))
(DTypeSig false "skip2" (TyFun (TyCon "PState") (TyFun (TyVar "a") (TyVar "a"))))
(DFunDef false "skip2" ((PVar "st") (PVar "v")) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EVar "v"))))
(DTypeSig false "scanFlags" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyTuple (TyCon "Int") (TyCon "Bool") (TyCon "Bool") (TyCon "Bool"))))))))
(DFunDef false "scanFlags" ((PVar "cs") (PVar "i") (PVar "fold") (PVar "multi") (PVar "dotAll")) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 2))) (EApp (EVar "arrayLength") (EVar "cs"))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "(")))) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "cs")) (ELit (LChar "?")))) (EApp (EVar "isFlagChar") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "cs")))) (EMatch (EApp (EApp (EApp (EApp (EApp (EVar "scanFlagChars") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EMethodRef "fold")) (EVar "multi")) (EVar "dotAll")) (arm (PCon "None") () (ETuple (EVar "i") (EMethodRef "fold") (EVar "multi") (EVar "dotAll"))) (arm (PCon "Some" (PTuple (PVar "j") (PVar "f2") (PVar "m2") (PVar "s2"))) () (EApp (EApp (EApp (EApp (EApp (EVar "scanFlags") (EVar "cs")) (EVar "j")) (EVar "f2")) (EVar "m2")) (EVar "s2")))) (ETuple (EVar "i") (EMethodRef "fold") (EVar "multi") (EVar "dotAll"))))
(DTypeSig false "isFlagChar" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isFlagChar" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "i"))) (EBinOp "==" (EVar "c") (ELit (LChar "m")))) (EBinOp "==" (EVar "c") (ELit (LChar "s")))))
(DTypeSig false "scanFlagChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Bool") (TyCon "Bool") (TyCon "Bool")))))))))
(DFunDef false "scanFlagChars" ((PVar "cs") (PVar "k") (PVar "fold") (PVar "multi") (PVar "dotAll")) (EIf (EBinOp ">=" (EVar "k") (EApp (EVar "arrayLength") (EVar "cs"))) (EVar "None") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "k")) (EVar "cs"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LChar "i"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanFlagChars") (EVar "cs")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "True")) (EVar "multi")) (EVar "dotAll")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "m"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanFlagChars") (EVar "cs")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EMethodRef "fold")) (EVar "True")) (EVar "dotAll")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "s"))) (EApp (EApp (EApp (EApp (EApp (EVar "scanFlagChars") (EVar "cs")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EMethodRef "fold")) (EVar "multi")) (EVar "True")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar ")"))) (EApp (EVar "Some") (ETuple (EBinOp "+" (EVar "k") (ELit (LInt 1))) (EMethodRef "fold") (EVar "multi") (EVar "dotAll"))) (EVar "None")))))))))
(DTypeSig false "parseAlt" (TyFun (TyCon "PState") (TyCon "Node")))
(DFunDef false "parseAlt" ((PVar "st")) (EApp (EApp (EVar "parseAltMore") (EVar "st")) (EApp (EVar "parseCat") (EVar "st"))))
(DTypeSig false "parseAltMore" (TyFun (TyCon "PState") (TyFun (TyCon "Node") (TyCon "Node"))))
(DFunDef false "parseAltMore" ((PVar "st") (PVar "left")) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "|"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoLet false false (PVar "right") (EApp (EVar "parseCat") (EVar "st"))) (DoExpr (EApp (EApp (EVar "parseAltMore") (EVar "st")) (EApp (EApp (EVar "NAlt") (EVar "left")) (EVar "right"))))) (EVar "left")))
(DTypeSig false "parseCat" (TyFun (TyCon "PState") (TyCon "Node")))
(DFunDef false "parseCat" ((PVar "st")) (EApp (EVar "catOf") (EApp (EApp (EVar "parseSeq") (EVar "st")) (EListLit))))
(DTypeSig false "catOf" (TyFun (TyApp (TyCon "List") (TyCon "Node")) (TyCon "Node")))
(DFunDef false "catOf" ((PList)) (EVar "NEmpty"))
(DFunDef false "catOf" ((PCons (PVar "x") (PList))) (EVar "x"))
(DFunDef false "catOf" ((PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EVar "NCat") (EVar "x")) (EApp (EVar "catOf") (EVar "rest"))))
(DTypeSig false "parseSeq" (TyFun (TyCon "PState") (TyFun (TyApp (TyCon "List") (TyCon "Node")) (TyApp (TyCon "List") (TyCon "Node")))))
(DFunDef false "parseSeq" ((PVar "st") (PVar "acc")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "hasErr") (EVar "st")) (EApp (EVar "atEnd") (EVar "st"))) (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "|")))) (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar ")")))) (EApp (EVar "reverse") (EVar "acc")) (EBlock (DoLet false false (PVar "item") (EApp (EVar "parsePiece") (EVar "st"))) (DoExpr (EApp (EApp (EVar "parseSeq") (EVar "st")) (EBinOp "::" (EVar "item") (EVar "acc")))))))
(DTypeSig false "parsePiece" (TyFun (TyCon "PState") (TyCon "Node")))
(DFunDef false "parsePiece" ((PVar "st")) (EBlock (DoLet false false (PVar "atom") (EApp (EVar "parseAtom") (EVar "st"))) (DoExpr (EApp (EApp (EVar "parseQuant") (EVar "st")) (EVar "atom")))))
(DTypeSig false "parseQuant" (TyFun (TyCon "PState") (TyFun (TyCon "Node") (TyCon "Node"))))
(DFunDef false "parseQuant" ((PVar "st") (PVar "node")) (EIf (EApp (EVar "hasErr") (EVar "st")) (EVar "node") (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "*"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EVar "parseQuant") (EVar "st")) (EApp (EApp (EVar "NStar") (EApp (EVar "greedFlag") (EVar "st"))) (EVar "node"))))) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "+"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EVar "parseQuant") (EVar "st")) (EApp (EApp (EVar "NPlus") (EApp (EVar "greedFlag") (EVar "st"))) (EVar "node"))))) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "?"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EVar "parseQuant") (EVar "st")) (EApp (EApp (EVar "NOpt") (EApp (EVar "greedFlag") (EVar "st"))) (EVar "node"))))) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "{"))) (EApp (EApp (EVar "parseBrace") (EVar "st")) (EVar "node")) (EVar "node")))))))
(DTypeSig false "greedFlag" (TyFun (TyCon "PState") (TyCon "Bool")))
(DFunDef false "greedFlag" ((PVar "st")) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "?"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EVar "False"))) (EVar "True")))
(DTypeSig false "parseBrace" (TyFun (TyCon "PState") (TyFun (TyCon "Node") (TyCon "Node"))))
(DFunDef false "parseBrace" ((PVar "st") (PVar "node")) (EBlock (DoLet false false (PVar "save") (EUnOp "!" (EFieldAccess (EVar "st") "pos"))) (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EMatch (EApp (EVar "parseDigits") (EVar "st")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "rewind") (EVar "st")) (EVar "save")) (EVar "node"))) (arm (PCon "Some" (PVar "lo")) () (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "}"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "finishRepeat") (EVar "st")) (EVar "node")) (EVar "lo")) (EVar "lo")))) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar ","))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "parseBraceUpper") (EVar "st")) (EVar "node")) (EVar "save")) (EVar "lo")))) (EApp (EApp (EApp (EVar "rewind") (EVar "st")) (EVar "save")) (EVar "node")))))))))
(DTypeSig false "parseBraceUpper" (TyFun (TyCon "PState") (TyFun (TyCon "Node") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Node"))))))
(DFunDef false "parseBraceUpper" ((PVar "st") (PVar "node") (PVar "save") (PVar "lo")) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "}"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "finishRepeat") (EVar "st")) (EVar "node")) (EVar "lo")) (EUnOp "-" (ELit (LInt 1)))))) (EMatch (EApp (EVar "parseDigits") (EVar "st")) (arm (PCon "None") () (EApp (EApp (EApp (EVar "rewind") (EVar "st")) (EVar "save")) (EVar "node"))) (arm (PCon "Some" (PVar "hi")) () (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "}"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "finishRepeat") (EVar "st")) (EVar "node")) (EVar "lo")) (EVar "hi")))) (EApp (EApp (EApp (EVar "rewind") (EVar "st")) (EVar "save")) (EVar "node")))))))
(DTypeSig false "rewind" (TyFun (TyCon "PState") (TyFun (TyCon "Int") (TyFun (TyCon "Node") (TyCon "Node")))))
(DFunDef false "rewind" ((PVar "st") (PVar "save") (PVar "node")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "pos")) (EVar "save"))) (DoExpr (EVar "node"))))
(DTypeSig false "parseDigits" (TyFun (TyCon "PState") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "parseDigits" ((PVar "st")) (EIf (EBinOp "||" (EApp (EVar "atEnd") (EVar "st")) (EApp (EVar "not") (EApp (EVar "isDigit") (EApp (EVar "cur") (EVar "st"))))) (EVar "None") (EApp (EApp (EVar "digitsGo") (EVar "st")) (ELit (LInt 0)))))
(DTypeSig false "digitsGo" (TyFun (TyCon "PState") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "digitsGo" ((PVar "st") (PVar "acc")) (EIf (EBinOp "||" (EApp (EVar "atEnd") (EVar "st")) (EApp (EVar "not") (EApp (EVar "isDigit") (EApp (EVar "cur") (EVar "st"))))) (EApp (EVar "Some") (EVar "acc")) (EIf (EBinOp ">" (EVar "acc") (EVar "repeatCap")) (EApp (EVar "Some") (EVar "acc")) (EBlock (DoLet false false (PVar "d") (EBinOp "-" (EApp (EVar "charCode") (EApp (EVar "cur") (EVar "st"))) (ELit (LInt 48)))) (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EVar "digitsGo") (EVar "st")) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 10))) (EVar "d"))))))))
(DTypeSig false "finishRepeat" (TyFun (TyCon "PState") (TyFun (TyCon "Node") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Node"))))))
(DFunDef false "finishRepeat" ((PVar "st") (PVar "node") (PVar "lo") (PVar "hi")) (EIf (EBinOp "||" (EBinOp ">" (EVar "lo") (EVar "repeatCap")) (EBinOp ">" (EVar "hi") (EVar "repeatCap"))) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "repetition bound is larger than the maximum of 1000")))) (DoExpr (EVar "node"))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "hi") (ELit (LInt 0))) (EBinOp "<" (EVar "hi") (EVar "lo"))) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "repetition bounds are out of order")))) (DoExpr (EVar "node"))) (EIf (EBinOp ">" (EBinOp "*" (EApp (EApp (EVar "repeatWidth") (EVar "lo")) (EVar "hi")) (EApp (EVar "nodeSize") (EVar "node"))) (EVar "progCap")) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "pattern compiles to more than 20000 instructions")))) (DoExpr (EVar "node"))) (EBlock (DoLet false false (PVar "greedy") (EApp (EVar "greedFlag") (EVar "st"))) (DoExpr (EApp (EApp (EVar "parseQuant") (EVar "st")) (EApp (EApp (EApp (EApp (EVar "expandRepeat") (EVar "greedy")) (EVar "node")) (EVar "lo")) (EVar "hi")))))))))
(DTypeSig false "repeatWidth" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "repeatWidth" ((PVar "lo") (PVar "hi")) (EIf (EBinOp "<" (EVar "hi") (ELit (LInt 0))) (EBinOp "+" (EVar "lo") (ELit (LInt 2))) (EBinOp "+" (EVar "hi") (ELit (LInt 1)))))
(DTypeSig false "expandRepeat" (TyFun (TyCon "Bool") (TyFun (TyCon "Node") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Node"))))))
(DFunDef false "expandRepeat" ((PVar "greedy") (PVar "node") (PVar "lo") (PVar "hi")) (EIf (EBinOp "<" (EVar "hi") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "catRepeat") (EVar "node")) (EVar "lo")) (EApp (EApp (EVar "NStar") (EVar "greedy")) (EVar "node"))) (EApp (EApp (EApp (EVar "catRepeat") (EVar "node")) (EVar "lo")) (EApp (EApp (EApp (EVar "optChain") (EVar "greedy")) (EVar "node")) (EBinOp "-" (EVar "hi") (EVar "lo"))))))
(DTypeSig false "catRepeat" (TyFun (TyCon "Node") (TyFun (TyCon "Int") (TyFun (TyCon "Node") (TyCon "Node")))))
(DFunDef false "catRepeat" ((PVar "node") (PVar "n") (PVar "rest")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EVar "rest") (EApp (EApp (EVar "NCat") (EVar "node")) (EApp (EApp (EApp (EVar "catRepeat") (EVar "node")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "rest")))))
(DTypeSig false "optChain" (TyFun (TyCon "Bool") (TyFun (TyCon "Node") (TyFun (TyCon "Int") (TyCon "Node")))))
(DFunDef false "optChain" ((PVar "greedy") (PVar "node") (PVar "k")) (EIf (EBinOp "<=" (EVar "k") (ELit (LInt 0))) (EVar "NEmpty") (EApp (EApp (EVar "NOpt") (EVar "greedy")) (EApp (EApp (EVar "NCat") (EVar "node")) (EApp (EApp (EApp (EVar "optChain") (EVar "greedy")) (EVar "node")) (EBinOp "-" (EVar "k") (ELit (LInt 1))))))))
(DTypeSig false "parseAtom" (TyFun (TyCon "PState") (TyCon "Node")))
(DFunDef false "parseAtom" ((PVar "st")) (EIf (EApp (EVar "atEnd") (EVar "st")) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "pattern ends where an expression was expected")))) (DoExpr (EVar "NEmpty"))) (EBlock (DoLet false false (PVar "c") (EApp (EVar "cur") (EVar "st"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LChar "("))) (EApp (EVar "parseGroup") (EVar "st")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "["))) (EApp (EVar "parseSet") (EVar "st")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "."))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EVar "NAny") (EFieldAccess (EVar "st") "dotAll")))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "^"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EVar "NAssert") (EVar "asStart")))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "$"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EVar "NAssert") (EVar "asEnd")))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\\"))) (EApp (EVar "parseEscape") (EVar "st")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "*"))) (EBinOp "==" (EVar "c") (ELit (LChar "+")))) (EBinOp "==" (EVar "c") (ELit (LChar "?")))) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "repetition operator with nothing to repeat")))) (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EVar "NEmpty"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EVar "litNode") (EVar "st")) (EApp (EVar "charCode") (EVar "c"))))))))))))))))
(DTypeSig false "litNode" (TyFun (TyCon "PState") (TyFun (TyCon "Int") (TyCon "Node"))))
(DFunDef false "litNode" ((PVar "st") (PVar "code")) (EIf (EBinOp "&&" (EFieldAccess (EVar "st") "fold") (EApp (EVar "isAsciiLetterCode") (EVar "code"))) (EApp (EApp (EVar "NSet") (EApp (EVar "flattenRanges") (EApp (EVar "foldRanges") (EListLit (ETuple (EVar "code") (EVar "code")))))) (EVar "False")) (EApp (EVar "NChar") (EVar "code"))))
(DTypeSig false "parseGroup" (TyFun (TyCon "PState") (TyCon "Node")))
(DFunDef false "parseGroup" ((PVar "st")) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "?"))) (EIf (EApp (EApp (EApp (EVar "peekIs") (EVar "st")) (ELit (LInt 1))) (ELit (LChar ":"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EVar "groupBody") (EVar "st")) (ELit (LInt 0))))) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (EApp (EVar "groupRefusal") (EVar "st")))) (DoExpr (EVar "NEmpty")))) (EBlock (DoLet false false (PVar "idx") (EBinOp "+" (EUnOp "!" (EFieldAccess (EVar "st") "ngroups")) (ELit (LInt 1)))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "st") "ngroups")) (EVar "idx"))) (DoExpr (EApp (EApp (EVar "groupBody") (EVar "st")) (EVar "idx"))))))))
(DTypeSig false "groupBody" (TyFun (TyCon "PState") (TyFun (TyCon "Int") (TyCon "Node"))))
(DFunDef false "groupBody" ((PVar "st") (PVar "idx")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "parseAlt") (EVar "st"))) (DoExpr (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar ")"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EIf (EBinOp "==" (EVar "idx") (ELit (LInt 0))) (EVar "body") (EApp (EApp (EVar "NGroup") (EVar "idx")) (EVar "body"))))) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "pattern is missing a closing )")))) (DoExpr (EVar "NEmpty")))))))
(DTypeSig false "groupRefusal" (TyFun (TyCon "PState") (TyCon "String")))
(DFunDef false "groupRefusal" ((PVar "st")) (EMatch (EApp (EApp (EVar "peekAt") (EVar "st")) (ELit (LInt 1))) (arm (PCon "Some" (PLit (LChar "="))) () (ELit (LString "lookahead is not supported"))) (arm (PCon "Some" (PLit (LChar "!"))) () (ELit (LString "lookahead is not supported"))) (arm (PCon "Some" (PLit (LChar "<"))) () (ELit (LString "named groups and lookbehind are not supported"))) (arm (PCon "Some" (PLit (LChar "P"))) () (ELit (LString "named groups are not supported"))) (arm (PCon "Some" (PLit (LChar "i"))) () (ELit (LString "flags are only allowed at the start of the pattern"))) (arm (PCon "Some" (PLit (LChar "m"))) () (ELit (LString "flags are only allowed at the start of the pattern"))) (arm (PCon "Some" (PLit (LChar "s"))) () (ELit (LString "flags are only allowed at the start of the pattern"))) (arm PWild () (ELit (LString "unsupported group syntax after (?")))))
(DTypeSig false "parseEscape" (TyFun (TyCon "PState") (TyCon "Node")))
(DFunDef false "parseEscape" ((PVar "st")) (EMatch (EApp (EApp (EVar "peekAt") (EVar "st")) (ELit (LInt 1))) (arm (PCon "None") () (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "pattern ends in a backslash")))) (DoExpr (EVar "NEmpty")))) (arm (PCon "Some" (PVar "c")) () (EIf (EBinOp "==" (EVar "c") (ELit (LChar "d"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EApp (EVar "NSet") (EApp (EVar "flattenRanges") (EVar "digitRanges"))) (EVar "False"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "D"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EApp (EVar "NSet") (EApp (EVar "flattenRanges") (EVar "digitRanges"))) (EVar "True"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "w"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EApp (EVar "NSet") (EVar "wordSet")) (EVar "False"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "W"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EApp (EVar "NSet") (EVar "wordSet")) (EVar "True"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "s"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EApp (EVar "NSet") (EApp (EVar "flattenRanges") (EVar "spaceRanges"))) (EVar "False"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "S"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EApp (EVar "NSet") (EApp (EVar "flattenRanges") (EVar "spaceRanges"))) (EVar "True"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "b"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EVar "NAssert") (EVar "asWordB"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "B"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EVar "NAssert") (EVar "asNotWordB"))) (EMatch (EApp (EVar "escapeCode") (EVar "st")) (arm (PCon "None") () (EVar "NEmpty")) (arm (PCon "Some" (PVar "code")) () (EApp (EApp (EVar "litNode") (EVar "st")) (EVar "code")))))))))))))))
(DTypeSig false "escapeCode" (TyFun (TyCon "PState") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "escapeCode" ((PVar "st")) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EMatch (EApp (EApp (EVar "peekAt") (EVar "st")) (ELit (LInt 0))) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "pattern ends in a backslash")))) (DoExpr (EVar "None")))) (arm (PCon "Some" (PVar "c")) () (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LChar "n"))) (EApp (EVar "Some") (ELit (LInt 10))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "t"))) (EApp (EVar "Some") (ELit (LInt 9))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "r"))) (EApp (EVar "Some") (ELit (LInt 13))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "x"))) (EApp (EApp (EVar "hexCode") (EVar "st")) (ELit (LInt 2))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "u"))) (EApp (EVar "braceHexCode") (EVar "st")) (EIf (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "p"))) (EBinOp "==" (EVar "c") (ELit (LChar "P")))) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "Unicode character classes are not supported")))) (DoExpr (EVar "None"))) (EIf (EApp (EVar "isDigit") (EVar "c")) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "backreferences are not supported")))) (DoExpr (EVar "None"))) (EIf (EApp (EVar "charIsAlpha") (EVar "c")) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "unknown escape sequence")))) (DoExpr (EVar "None"))) (EApp (EVar "Some") (EApp (EVar "charCode") (EVar "c"))))))))))))))))))
(DTypeSig false "hexCode" (TyFun (TyCon "PState") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int")))))
(DFunDef false "hexCode" ((PVar "st") (PVar "n")) (EApp (EApp (EApp (EVar "hexGo") (EVar "st")) (EVar "n")) (ELit (LInt 0))))
(DTypeSig false "hexGo" (TyFun (TyCon "PState") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "hexGo" ((PVar "st") (PVar "n") (PVar "acc")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Some") (EVar "acc")) (EMatch (EApp (EApp (EVar "peekAt") (EVar "st")) (ELit (LInt 0))) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "incomplete hexadecimal escape")))) (DoExpr (EVar "None")))) (arm (PCon "Some" (PVar "c")) () (EMatch (EApp (EVar "hexValue") (EVar "c")) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "incomplete hexadecimal escape")))) (DoExpr (EVar "None")))) (arm (PCon "Some" (PVar "v")) () (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EApp (EVar "hexGo") (EVar "st")) (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 16))) (EVar "v")))))))))))
(DTypeSig false "hexValue" (TyFun (TyCon "Char") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "hexValue" ((PVar "c")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "charCode") (EVar "c"))) (DoExpr (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 48))) (EBinOp "<=" (EVar "n") (ELit (LInt 57)))) (EApp (EVar "Some") (EBinOp "-" (EVar "n") (ELit (LInt 48)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 97))) (EBinOp "<=" (EVar "n") (ELit (LInt 102)))) (EApp (EVar "Some") (EBinOp "-" (EVar "n") (ELit (LInt 87)))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "n") (ELit (LInt 65))) (EBinOp "<=" (EVar "n") (ELit (LInt 70)))) (EApp (EVar "Some") (EBinOp "-" (EVar "n") (ELit (LInt 55)))) (EVar "None")))))))
(DTypeSig false "braceHexCode" (TyFun (TyCon "PState") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "braceHexCode" ((PVar "st")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "{")))) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "\\u must be followed by a braced hexadecimal codepoint")))) (DoExpr (EVar "None"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "braceHexGo") (EVar "st")) (ELit (LInt 0))) (ELit (LInt 0))) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "code")) () (EIf (EBinOp ">" (EVar "code") (EVar "maxCode")) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "codepoint is above the Unicode maximum")))) (DoExpr (EVar "None"))) (EApp (EVar "Some") (EVar "code")))))))))
(DTypeSig false "braceHexGo" (TyFun (TyCon "PState") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Int"))))))
(DFunDef false "braceHexGo" ((PVar "st") (PVar "seen") (PVar "acc")) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "}"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EIf (EBinOp "==" (EVar "seen") (ELit (LInt 0))) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "\\u{} needs at least one hexadecimal digit")))) (DoExpr (EVar "None"))) (EApp (EVar "Some") (EVar "acc"))))) (EMatch (EApp (EApp (EVar "peekAt") (EVar "st")) (ELit (LInt 0))) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "\\u{ is missing its closing brace")))) (DoExpr (EVar "None")))) (arm (PCon "Some" (PVar "c")) () (EMatch (EApp (EVar "hexValue") (EVar "c")) (arm (PCon "None") () (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "\\u{ is missing its closing brace")))) (DoExpr (EVar "None")))) (arm (PCon "Some" (PVar "v")) () (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EApp (EVar "braceHexGo") (EVar "st")) (EBinOp "+" (EVar "seen") (ELit (LInt 1)))) (EBinOp "+" (EBinOp "*" (EVar "acc") (ELit (LInt 16))) (EVar "v")))))))))))
(DTypeSig false "parseSet" (TyFun (TyCon "PState") (TyCon "Node")))
(DFunDef false "parseSet" ((PVar "st")) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoLet false false (PVar "negated") (EApp (EVar "setNegated") (EVar "st"))) (DoLet false false (PVar "rs") (EApp (EApp (EVar "setItems") (EVar "st")) (EListLit))) (DoExpr (EIf (EApp (EVar "hasErr") (EVar "st")) (EVar "NEmpty") (EIf (EApp (EVar "isEmptyRanges") (EVar "rs")) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "empty character class")))) (DoExpr (EVar "NEmpty"))) (EBlock (DoLet false false (PVar "folded") (EIf (EFieldAccess (EVar "st") "fold") (EApp (EVar "foldRanges") (EVar "rs")) (EVar "rs"))) (DoExpr (EApp (EApp (EVar "NSet") (EApp (EVar "flattenRanges") (EVar "folded"))) (EVar "negated")))))))))
(DTypeSig false "setNegated" (TyFun (TyCon "PState") (TyCon "Bool")))
(DFunDef false "setNegated" ((PVar "st")) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "^"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EVar "True"))) (EVar "False")))
(DTypeSig false "isEmptyRanges" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyCon "Bool")))
(DFunDef false "isEmptyRanges" ((PList)) (EVar "True"))
(DFunDef false "isEmptyRanges" (PWild) (EVar "False"))
(DTypeSig false "setItems" (TyFun (TyCon "PState") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "setItems" ((PVar "st") (PVar "acc")) (EIf (EApp (EVar "hasErr") (EVar "st")) (EVar "acc") (EIf (EApp (EVar "atEnd") (EVar "st")) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "character class is missing a closing ]")))) (DoExpr (EVar "acc"))) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "]"))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EVar "acc"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "["))) (EApp (EApp (EApp (EVar "peekIs") (EVar "st")) (ELit (LInt 1))) (ELit (LChar ":")))) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "POSIX character classes are not supported")))) (DoExpr (EVar "acc"))) (EMatch (EApp (EVar "setItem") (EVar "st")) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PVar "rs")) () (EApp (EApp (EVar "setItems") (EVar "st")) (EBinOp "++" (EVar "rs") (EVar "acc"))))))))))
(DTypeSig false "setItem" (TyFun (TyCon "PState") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "setItem" ((PVar "st")) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "\\"))) (EApp (EVar "setEscapeItem") (EVar "st")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "cur") (EVar "st"))) (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EVar "setRangeFrom") (EVar "st")) (EApp (EVar "charCode") (EVar "c")))))))
(DTypeSig false "setEscapeItem" (TyFun (TyCon "PState") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "setEscapeItem" ((PVar "st")) (EMatch (EApp (EApp (EVar "peekAt") (EVar "st")) (ELit (LInt 1))) (arm (PCon "None") () (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "pattern ends in a backslash")))) (DoExpr (EVar "None")))) (arm (PCon "Some" (PVar "c")) () (EIf (EBinOp "==" (EVar "c") (ELit (LChar "d"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EVar "Some") (EVar "digitRanges"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "D"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EVar "Some") (EApp (EVar "complementRanges") (EVar "digitRanges")))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "w"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EVar "Some") (EVar "wordRanges"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "W"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EVar "Some") (EApp (EVar "complementRanges") (EVar "wordRanges")))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "s"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EVar "Some") (EVar "spaceRanges"))) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "S"))) (EApp (EApp (EVar "skip2") (EVar "st")) (EApp (EVar "Some") (EApp (EVar "complementRanges") (EVar "spaceRanges")))) (EMatch (EApp (EVar "escapeCode") (EVar "st")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "code")) () (EApp (EApp (EVar "setRangeFrom") (EVar "st")) (EVar "code")))))))))))))
(DTypeSig false "setRangeFrom" (TyFun (TyCon "PState") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "setRangeFrom" ((PVar "st") (PVar "lo")) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "-"))) (EApp (EVar "not") (EApp (EApp (EApp (EVar "peekIs") (EVar "st")) (ELit (LInt 1))) (ELit (LChar "]"))))) (EBinOp "<" (EBinOp "+" (EUnOp "!" (EFieldAccess (EVar "st") "pos")) (ELit (LInt 1))) (EApp (EVar "patLen") (EVar "st")))) (EBlock (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EMatch (EApp (EVar "setSingle") (EVar "st")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "hi")) () (EIf (EBinOp "<=" (EVar "lo") (EVar "hi")) (EApp (EVar "Some") (EListLit (ETuple (EVar "lo") (EVar "hi")))) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "character class range is reversed")))) (DoExpr (EVar "None")))))))) (EApp (EVar "Some") (EListLit (ETuple (EVar "lo") (EVar "lo"))))))
(DTypeSig false "setSingle" (TyFun (TyCon "PState") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "setSingle" ((PVar "st")) (EIf (EApp (EApp (EVar "isAt") (EVar "st")) (ELit (LChar "\\"))) (EApp (EVar "escapeCode") (EVar "st")) (EIf (EApp (EVar "atEnd") (EVar "st")) (EBlock (DoExpr (EApp (EApp (EVar "failAt") (EVar "st")) (ELit (LString "character class is missing a closing ]")))) (DoExpr (EVar "None"))) (EBlock (DoLet false false (PVar "c") (EApp (EVar "cur") (EVar "st"))) (DoExpr (EApp (EVar "advance") (EVar "st"))) (DoExpr (EApp (EVar "Some") (EApp (EVar "charCode") (EVar "c"))))))))
(DData Private "Inst" () ((variant "IChar" (ConPos (TyCon "Int"))) (variant "ISet" (ConPos (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Bool"))) (variant "IAny" (ConPos (TyCon "Bool"))) (variant "ISplit" (ConPos (TyCon "Int") (TyCon "Int"))) (variant "IJmp" (ConPos (TyCon "Int"))) (variant "ISave" (ConPos (TyCon "Int"))) (variant "IAssert" (ConPos (TyCon "Int"))) (variant "IMatch" (ConPos))) ())
(DTypeSig false "compileNode" (TyFun (TyCon "Node") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Inst")))))
(DFunDef false "compileNode" ((PCon "NEmpty") PWild) (EListLit))
(DFunDef false "compileNode" ((PCon "NChar" (PVar "c")) PWild) (EListLit (EApp (EVar "IChar") (EVar "c"))))
(DFunDef false "compileNode" ((PCon "NSet" (PVar "rs") (PVar "negated")) PWild) (EListLit (EApp (EApp (EVar "ISet") (EVar "rs")) (EVar "negated"))))
(DFunDef false "compileNode" ((PCon "NAny" (PVar "dotAll")) PWild) (EListLit (EApp (EVar "IAny") (EVar "dotAll"))))
(DFunDef false "compileNode" ((PCon "NAssert" (PVar "kind")) PWild) (EListLit (EApp (EVar "IAssert") (EVar "kind"))))
(DFunDef false "compileNode" ((PCon "NCat" (PVar "a") (PVar "b")) (PVar "pc")) (EBlock (DoLet false false (PVar "ca") (EApp (EApp (EVar "compileNode") (EVar "a")) (EVar "pc"))) (DoExpr (EBinOp "++" (EVar "ca") (EApp (EApp (EVar "compileNode") (EVar "b")) (EBinOp "+" (EVar "pc") (EApp (EMethodRef "length") (EVar "ca"))))))))
(DFunDef false "compileNode" ((PCon "NAlt" (PVar "a") (PVar "b")) (PVar "pc")) (EBlock (DoLet false false (PVar "ca") (EApp (EApp (EVar "compileNode") (EVar "a")) (EBinOp "+" (EVar "pc") (ELit (LInt 1))))) (DoLet false false (PVar "jmpAt") (EBinOp "+" (EBinOp "+" (EVar "pc") (ELit (LInt 1))) (EApp (EMethodRef "length") (EVar "ca")))) (DoLet false false (PVar "cb") (EApp (EApp (EVar "compileNode") (EVar "b")) (EBinOp "+" (EVar "jmpAt") (ELit (LInt 1))))) (DoLet false false (PVar "out") (EBinOp "+" (EBinOp "+" (EVar "jmpAt") (ELit (LInt 1))) (EApp (EMethodRef "length") (EVar "cb")))) (DoExpr (EBinOp "::" (EApp (EApp (EVar "ISplit") (EBinOp "+" (EVar "pc") (ELit (LInt 1)))) (EBinOp "+" (EVar "jmpAt") (ELit (LInt 1)))) (EBinOp "++" (EVar "ca") (EBinOp "::" (EApp (EVar "IJmp") (EVar "out")) (EVar "cb")))))))
(DFunDef false "compileNode" ((PCon "NStar" (PVar "greedy") (PVar "body")) (PVar "pc")) (EBlock (DoLet false false (PVar "cb") (EApp (EApp (EVar "compileNode") (EVar "body")) (EBinOp "+" (EVar "pc") (ELit (LInt 1))))) (DoLet false false (PVar "out") (EBinOp "+" (EBinOp "+" (EBinOp "+" (EVar "pc") (ELit (LInt 1))) (EApp (EMethodRef "length") (EVar "cb"))) (ELit (LInt 1)))) (DoLet false false (PVar "sp") (EIf (EVar "greedy") (EApp (EApp (EVar "ISplit") (EBinOp "+" (EVar "pc") (ELit (LInt 1)))) (EVar "out")) (EApp (EApp (EVar "ISplit") (EVar "out")) (EBinOp "+" (EVar "pc") (ELit (LInt 1)))))) (DoExpr (EBinOp "::" (EVar "sp") (EBinOp "++" (EVar "cb") (EListLit (EApp (EVar "IJmp") (EVar "pc"))))))))
(DFunDef false "compileNode" ((PCon "NPlus" (PVar "greedy") (PVar "body")) (PVar "pc")) (EBlock (DoLet false false (PVar "cb") (EApp (EApp (EVar "compileNode") (EVar "body")) (EVar "pc"))) (DoLet false false (PVar "out") (EBinOp "+" (EBinOp "+" (EVar "pc") (EApp (EMethodRef "length") (EVar "cb"))) (ELit (LInt 1)))) (DoLet false false (PVar "sp") (EIf (EVar "greedy") (EApp (EApp (EVar "ISplit") (EVar "pc")) (EVar "out")) (EApp (EApp (EVar "ISplit") (EVar "out")) (EVar "pc")))) (DoExpr (EBinOp "++" (EVar "cb") (EListLit (EVar "sp"))))))
(DFunDef false "compileNode" ((PCon "NOpt" (PVar "greedy") (PVar "body")) (PVar "pc")) (EBlock (DoLet false false (PVar "cb") (EApp (EApp (EVar "compileNode") (EVar "body")) (EBinOp "+" (EVar "pc") (ELit (LInt 1))))) (DoLet false false (PVar "out") (EBinOp "+" (EBinOp "+" (EVar "pc") (ELit (LInt 1))) (EApp (EMethodRef "length") (EVar "cb")))) (DoLet false false (PVar "sp") (EIf (EVar "greedy") (EApp (EApp (EVar "ISplit") (EBinOp "+" (EVar "pc") (ELit (LInt 1)))) (EVar "out")) (EApp (EApp (EVar "ISplit") (EVar "out")) (EBinOp "+" (EVar "pc") (ELit (LInt 1)))))) (DoExpr (EBinOp "::" (EVar "sp") (EVar "cb")))))
(DFunDef false "compileNode" ((PCon "NGroup" (PVar "idx") (PVar "body")) (PVar "pc")) (EBinOp "::" (EApp (EVar "ISave") (EBinOp "*" (ELit (LInt 2)) (EVar "idx"))) (EBinOp "++" (EApp (EApp (EVar "compileNode") (EVar "body")) (EBinOp "+" (EVar "pc") (ELit (LInt 1)))) (EListLit (EApp (EVar "ISave") (EBinOp "+" (EBinOp "*" (ELit (LInt 2)) (EVar "idx")) (ELit (LInt 1))))))))
(DData Private "Vm" () ((variant "Vm" (ConNamed (field "prog" (TyApp (TyCon "Array") (TyCon "Inst"))) (field "codes" (TyApp (TyCon "Array") (TyCon "Int"))) (field "subjStart" (TyCon "Int")) (field "subjEnd" (TyCon "Int")) (field "multi" (TyCon "Bool")) (field "anchorEnd" (TyCon "Bool")) (field "nslots" (TyCon "Int")) (field "steps" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "found" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int")))))))) ())
(DData Private "ThreadList" () ((variant "ThreadList" (ConNamed (field "dense" (TyApp (TyCon "Array") (TyCon "Int"))) (field "slots" (TyApp (TyCon "Array") (TyApp (TyCon "Array") (TyCon "Int")))) (field "live" (TyApp (TyCon "Ref") (TyCon "Int"))) (field "mark" (TyApp (TyCon "Array") (TyCon "Int"))) (field "gen" (TyApp (TyCon "Ref") (TyCon "Int")))))) ())
(DTypeSig false "noSlots" (TyApp (TyCon "Array") (TyCon "Int")))
(DFunDef false "noSlots" () (EArrayLit))
(DTypeSig false "newThreads" (TyFun (TyCon "Int") (TyCon "ThreadList")))
(DFunDef false "newThreads" ((PVar "n")) (ERecordCreate "ThreadList" ((fa "dense" (EApp (EApp (EVar "arrayMake") (EVar "n")) (ELit (LInt 0)))) (fa "slots" (EApp (EApp (EVar "arrayMake") (EVar "n")) (EVar "noSlots"))) (fa "live" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "mark" (EApp (EApp (EVar "arrayMake") (EVar "n")) (ELit (LInt 0)))) (fa "gen" (EApp (EVar "Ref") (ELit (LInt 1)))))))
(DTypeSig false "resetThreads" (TyFun (TyCon "ThreadList") (TyCon "Unit")))
(DFunDef false "resetThreads" ((PVar "list")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "list") "live")) (ELit (LInt 0)))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "list") "gen")) (EBinOp "+" (EUnOp "!" (EFieldAccess (EVar "list") "gen")) (ELit (LInt 1)))))))
(DTypeSig false "foundYet" (TyFun (TyCon "Vm") (TyCon "Bool")))
(DFunDef false "foundYet" ((PVar "vm")) (EMatch (EUnOp "!" (EFieldAccess (EVar "vm") "found")) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "addThread" (TyFun (TyCon "Vm") (TyFun (TyCon "ThreadList") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Unit")))))))
(DFunDef false "addThread" ((PVar "vm") (PVar "list") (PVar "pc") (PVar "pos") (PVar "slots")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "vm") "steps")) (EBinOp "+" (EUnOp "!" (EFieldAccess (EVar "vm") "steps")) (ELit (LInt 1))))) (DoExpr (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pc")) (EFieldAccess (EVar "list") "mark")) (EUnOp "!" (EFieldAccess (EVar "list") "gen"))) (ELit LUnit) (EBlock (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "pc")) (EUnOp "!" (EFieldAccess (EVar "list") "gen"))) (EFieldAccess (EVar "list") "mark"))) (DoExpr (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pc")) (EFieldAccess (EVar "vm") "prog")) (arm (PCon "IJmp" (PVar "x")) () (EApp (EApp (EApp (EApp (EApp (EVar "addThread") (EVar "vm")) (EVar "list")) (EVar "x")) (EVar "pos")) (EVar "slots"))) (arm (PCon "ISplit" (PVar "x") (PVar "y")) () (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "addThread") (EVar "vm")) (EVar "list")) (EVar "x")) (EVar "pos")) (EVar "slots"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "addThread") (EVar "vm")) (EVar "list")) (EVar "y")) (EVar "pos")) (EVar "slots"))))) (arm (PCon "ISave" (PVar "n")) () (EBlock (DoLet false false (PVar "written") (EApp (EVar "arrayCopy") (EVar "slots"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "n")) (EVar "pos")) (EVar "written"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "addThread") (EVar "vm")) (EVar "list")) (EBinOp "+" (EVar "pc") (ELit (LInt 1)))) (EVar "pos")) (EVar "written"))))) (arm (PCon "IAssert" (PVar "kind")) () (EIf (EApp (EApp (EApp (EVar "assertHolds") (EVar "vm")) (EVar "kind")) (EVar "pos")) (EApp (EApp (EApp (EApp (EApp (EVar "addThread") (EVar "vm")) (EVar "list")) (EBinOp "+" (EVar "pc") (ELit (LInt 1)))) (EVar "pos")) (EVar "slots")) (ELit LUnit))) (arm PWild () (EBlock (DoLet false false (PVar "i") (EUnOp "!" (EFieldAccess (EVar "list") "live"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "pc")) (EFieldAccess (EVar "list") "dense"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "slots")) (EFieldAccess (EVar "list") "slots"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "list") "live")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))))))))
(DTypeSig false "assertHolds" (TyFun (TyCon "Vm") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool")))))
(DFunDef false "assertHolds" ((PVar "vm") (PVar "kind") (PVar "pos")) (EIf (EBinOp "==" (EVar "kind") (EVar "asStart")) (EBinOp "||" (EBinOp "==" (EVar "pos") (EFieldAccess (EVar "vm") "subjStart")) (EBinOp "&&" (EFieldAccess (EVar "vm") "multi") (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "-" (EVar "pos") (ELit (LInt 1)))) (EFieldAccess (EVar "vm") "codes")) (ELit (LInt 10))))) (EIf (EBinOp "==" (EVar "kind") (EVar "asEnd")) (EBinOp "||" (EBinOp "==" (EVar "pos") (EFieldAccess (EVar "vm") "subjEnd")) (EBinOp "&&" (EFieldAccess (EVar "vm") "multi") (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pos")) (EFieldAccess (EVar "vm") "codes")) (ELit (LInt 10))))) (EIf (EBinOp "==" (EVar "kind") (EVar "asWordB")) (EBinOp "/=" (EApp (EApp (EVar "wordAt") (EVar "vm")) (EBinOp "-" (EVar "pos") (ELit (LInt 1)))) (EApp (EApp (EVar "wordAt") (EVar "vm")) (EVar "pos"))) (EBinOp "==" (EApp (EApp (EVar "wordAt") (EVar "vm")) (EBinOp "-" (EVar "pos") (ELit (LInt 1)))) (EApp (EApp (EVar "wordAt") (EVar "vm")) (EVar "pos")))))))
(DTypeSig false "wordAt" (TyFun (TyCon "Vm") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "wordAt" ((PVar "vm") (PVar "i")) (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "i") (EFieldAccess (EVar "vm") "subjStart")) (EBinOp "<" (EVar "i") (EFieldAccess (EVar "vm") "subjEnd"))) (EApp (EVar "isWordCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EFieldAccess (EVar "vm") "codes")))))
(DTypeSig false "stepThreads" (TyFun (TyCon "Vm") (TyFun (TyCon "ThreadList") (TyFun (TyCon "ThreadList") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Unit")))))))
(DFunDef false "stepThreads" ((PVar "vm") (PVar "clist") (PVar "nlist") (PVar "pos") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EUnOp "!" (EFieldAccess (EVar "clist") "live"))) (ELit LUnit) (EBlock (DoLet false false (PVar "pc") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EFieldAccess (EVar "clist") "dense"))) (DoLet false false (PVar "slots") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EFieldAccess (EVar "clist") "slots"))) (DoExpr (EMatch (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pc")) (EFieldAccess (EVar "vm") "prog")) (arm (PCon "IChar" (PVar "ch")) () (EBlock (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EVar "pos") (EFieldAccess (EVar "vm") "subjEnd")) (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pos")) (EFieldAccess (EVar "vm") "codes")) (EVar "ch"))) (EApp (EApp (EApp (EApp (EApp (EVar "addThread") (EVar "vm")) (EVar "nlist")) (EBinOp "+" (EVar "pc") (ELit (LInt 1)))) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "slots")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "stepThreads") (EVar "vm")) (EVar "clist")) (EVar "nlist")) (EVar "pos")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))) (arm (PCon "ISet" (PVar "rs") (PVar "negated")) () (EBlock (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EVar "pos") (EFieldAccess (EVar "vm") "subjEnd")) (EApp (EApp (EApp (EVar "setMatches") (EVar "rs")) (EVar "negated")) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pos")) (EFieldAccess (EVar "vm") "codes")))) (EApp (EApp (EApp (EApp (EApp (EVar "addThread") (EVar "vm")) (EVar "nlist")) (EBinOp "+" (EVar "pc") (ELit (LInt 1)))) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "slots")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "stepThreads") (EVar "vm")) (EVar "clist")) (EVar "nlist")) (EVar "pos")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))) (arm (PCon "IAny" (PVar "dotAll")) () (EBlock (DoExpr (EIf (EBinOp "&&" (EBinOp "<" (EVar "pos") (EFieldAccess (EVar "vm") "subjEnd")) (EBinOp "||" (EVar "dotAll") (EBinOp "/=" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "pos")) (EFieldAccess (EVar "vm") "codes")) (ELit (LInt 10))))) (EApp (EApp (EApp (EApp (EApp (EVar "addThread") (EVar "vm")) (EVar "nlist")) (EBinOp "+" (EVar "pc") (ELit (LInt 1)))) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "slots")) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "stepThreads") (EVar "vm")) (EVar "clist")) (EVar "nlist")) (EVar "pos")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))) (arm (PCon "IMatch") () (EIf (EBinOp "&&" (EFieldAccess (EVar "vm") "anchorEnd") (EBinOp "/=" (EVar "pos") (EFieldAccess (EVar "vm") "subjEnd"))) (EApp (EApp (EApp (EApp (EApp (EVar "stepThreads") (EVar "vm")) (EVar "clist")) (EVar "nlist")) (EVar "pos")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EBlock (DoLet false false (PVar "done") (EApp (EVar "arrayCopy") (EVar "slots"))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (ELit (LInt 1))) (EVar "pos")) (EVar "done"))) (DoExpr (EApp (EApp (EVar "setRef") (EFieldAccess (EVar "vm") "found")) (EApp (EVar "Some") (EVar "done"))))))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EVar "stepThreads") (EVar "vm")) (EVar "clist")) (EVar "nlist")) (EVar "pos")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))))
(DTypeSig false "seedThread" (TyFun (TyCon "Vm") (TyFun (TyCon "ThreadList") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyCon "Unit")))))))
(DFunDef false "seedThread" ((PVar "vm") (PVar "clist") (PVar "pos") (PVar "startAt") (PVar "anchorStart")) (EIf (EBinOp "||" (EApp (EVar "foundYet") (EVar "vm")) (EBinOp "&&" (EVar "anchorStart") (EBinOp "/=" (EVar "pos") (EVar "startAt")))) (ELit LUnit) (EBlock (DoLet false false (PVar "slots") (EApp (EApp (EVar "arrayMake") (EFieldAccess (EVar "vm") "nslots")) (EUnOp "-" (ELit (LInt 1))))) (DoExpr (EApp (EApp (EApp (EVar "arraySetUnsafe") (ELit (LInt 0))) (EVar "pos")) (EVar "slots"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "addThread") (EVar "vm")) (EVar "clist")) (ELit (LInt 0))) (EVar "pos")) (EVar "slots"))))))
(DTypeSig false "vmSearch" (TyFun (TyCon "Vm") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int")))))))
(DFunDef false "vmSearch" ((PVar "vm") (PVar "startAt") (PVar "anchorStart")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EFieldAccess (EVar "vm") "prog"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "vmLoop") (EVar "vm")) (EVar "startAt")) (EVar "anchorStart")) (EVar "startAt")) (EApp (EVar "newThreads") (EVar "n"))) (EApp (EVar "newThreads") (EVar "n"))))))
(DTypeSig false "vmLoop" (TyFun (TyCon "Vm") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyCon "ThreadList") (TyFun (TyCon "ThreadList") (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int"))))))))))
(DFunDef false "vmLoop" ((PVar "vm") (PVar "startAt") (PVar "anchorStart") (PVar "pos") (PVar "clist") (PVar "nlist")) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "seedThread") (EVar "vm")) (EVar "clist")) (EVar "pos")) (EVar "startAt")) (EVar "anchorStart"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "==" (EUnOp "!" (EFieldAccess (EVar "clist") "live")) (ELit (LInt 0))) (EBinOp "||" (EApp (EVar "foundYet") (EVar "vm")) (EVar "anchorStart"))) (EUnOp "!" (EFieldAccess (EVar "vm") "found")) (EBlock (DoExpr (EApp (EVar "resetThreads") (EVar "nlist"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "stepThreads") (EVar "vm")) (EVar "clist")) (EVar "nlist")) (EVar "pos")) (ELit (LInt 0)))) (DoExpr (EIf (EBinOp ">=" (EVar "pos") (EFieldAccess (EVar "vm") "subjEnd")) (EUnOp "!" (EFieldAccess (EVar "vm") "found")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "vmLoop") (EVar "vm")) (EVar "startAt")) (EVar "anchorStart")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "nlist")) (EVar "clist")))))))))
(DTypeSig false "codesOf" (TyFun (TyCon "String") (TyApp (TyCon "Array") (TyCon "Int"))))
(DFunDef false "codesOf" ((PVar "s")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "toChars") (EVar "s"))) (DoExpr (EApp (EApp (EVar "arrayMakeWith") (EApp (EVar "arrayLength") (EVar "cs"))) (ELam ((PVar "i")) (EApp (EVar "charCode") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))))))))
(DTypeSig false "searchFrom" (TyFun (TyCon "Regex") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int"))))))))))
(DFunDef false "searchFrom" ((PVar "re") (PVar "codes") (PVar "startAt") (PVar "anchorStart") (PVar "anchorEnd") (PVar "steps")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "searchWindow") (EVar "re")) (EVar "codes")) (ETuple (ELit (LInt 0)) (EApp (EVar "arrayLength") (EVar "codes")))) (EVar "startAt")) (EVar "anchorStart")) (EVar "anchorEnd")) (EVar "steps")))
(DTypeSig false "searchWindow" (TyFun (TyCon "Regex") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Ref") (TyCon "Int")) (TyApp (TyCon "Option") (TyApp (TyCon "Array") (TyCon "Int")))))))))))
(DFunDef false "searchWindow" ((PVar "re") (PVar "codes") (PTuple (PVar "lo") (PVar "hi")) (PVar "startAt") (PVar "anchorStart") (PVar "anchorEnd") (PVar "steps")) (EBlock (DoLet false false (PVar "vm") (ERecordCreate "Vm" ((fa "prog" (EFieldAccess (EVar "re") "prog")) (fa "codes" (EVar "codes")) (fa "subjStart" (EVar "lo")) (fa "subjEnd" (EVar "hi")) (fa "multi" (EFieldAccess (EVar "re") "multiline")) (fa "anchorEnd" (EVar "anchorEnd")) (fa "nslots" (EBinOp "*" (ELit (LInt 2)) (EBinOp "+" (EFieldAccess (EVar "re") "ngroups") (ELit (LInt 1))))) (fa "steps" (EVar "steps")) (fa "found" (EApp (EVar "Ref") (EVar "None")))))) (DoExpr (EApp (EApp (EApp (EVar "vmSearch") (EVar "vm")) (EVar "startAt")) (EVar "anchorStart")))))
(DTypeSig false "clampWindow" (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "clampWindow" ((PVar "codes") (PVar "start") (PVar "end")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "arrayLength") (EVar "codes"))) (DoLet false false (PVar "hi") (EApp (EApp (EMethodRef "max") (ELit (LInt 0))) (EApp (EApp (EMethodRef "min") (EVar "end")) (EVar "n")))) (DoExpr (ETuple (EApp (EApp (EMethodRef "max") (ELit (LInt 0))) (EApp (EApp (EMethodRef "min") (EVar "start")) (EVar "hi"))) (EVar "hi")))))
(DTypeSig false "findSteps" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "findSteps" ((PVar "re") (PVar "s")) (EBlock (DoLet false false (PVar "steps") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EApp (EApp (EVar "searchFrom") (EVar "re")) (EApp (EVar "codesOf") (EVar "s"))) (ELit (LInt 0))) (EVar "False")) (EVar "False")) (EVar "steps"))) (DoExpr (EUnOp "!" (EVar "steps")))))
(DTypeSig false "mkMatchWith" (TyFun (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Regex") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Match")))))
(DFunDef false "mkMatchWith" ((PVar "textOf") (PVar "re") (PVar "slots")) (EBlock (DoLet false false (PVar "lo") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "slots"))) (DoLet false false (PVar "hi") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 1))) (EVar "slots"))) (DoExpr (ERecordCreate "Match" ((fa "start" (EVar "lo")) (fa "end" (EVar "hi")) (fa "text" (EApp (EApp (EVar "textOf") (EVar "lo")) (EVar "hi"))) (fa "groups" (EApp (EApp (EApp (EApp (EVar "groupsOfWith") (EVar "textOf")) (EVar "re")) (EVar "slots")) (ELit (LInt 1)))))))))
(DTypeSig false "groupsOfWith" (TyFun (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "String"))) (TyFun (TyCon "Regex") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "Group"))))))))
(DFunDef false "groupsOfWith" ((PVar "textOf") (PVar "re") (PVar "slots") (PVar "k")) (EIf (EBinOp ">" (EVar "k") (EFieldAccess (EVar "re") "ngroups")) (EListLit) (EBlock (DoLet false false (PVar "lo") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "*" (ELit (LInt 2)) (EVar "k"))) (EVar "slots"))) (DoLet false false (PVar "hi") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EBinOp "*" (ELit (LInt 2)) (EVar "k")) (ELit (LInt 1)))) (EVar "slots"))) (DoLet false false (PVar "g") (EIf (EBinOp "||" (EBinOp "<" (EVar "lo") (ELit (LInt 0))) (EBinOp "<" (EVar "hi") (ELit (LInt 0)))) (EVar "None") (EApp (EVar "Some") (ERecordCreate "Group" ((fa "start" (EVar "lo")) (fa "end" (EVar "hi")) (fa "text" (EApp (EApp (EVar "textOf") (EVar "lo")) (EVar "hi")))))))) (DoExpr (EBinOp "::" (EVar "g") (EApp (EApp (EApp (EApp (EVar "groupsOfWith") (EVar "textOf")) (EVar "re")) (EVar "slots")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))))))))
(DTypeSig false "mkMatch" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyCon "Match")))))
(DFunDef false "mkMatch" ((PVar "re") (PVar "s") (PVar "slots")) (EApp (EApp (EApp (EVar "mkMatchWith") (ELam ((PVar "lo") (PVar "hi")) (EApp (EApp (EApp (EVar "sliceClamped") (EVar "lo")) (EVar "hi")) (EVar "s")))) (EVar "re")) (EVar "slots")))
(DTypeSig false "matchOnce" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyApp (TyCon "Option") (TyCon "Match"))))))))
(DFunDef false "matchOnce" ((PVar "re") (PVar "s") (PVar "startAt") (PVar "anchorStart") (PVar "anchorEnd")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "mkMatch") (EVar "re")) (EVar "s"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "searchFrom") (EVar "re")) (EApp (EVar "codesOf") (EVar "s"))) (EVar "startAt")) (EVar "anchorStart")) (EVar "anchorEnd")) (EApp (EVar "Ref") (ELit (LInt 0))))))
(DTypeSig true "compile" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "RegexError")) (TyCon "Regex"))))
(DFunDef false "compile" ((PVar "pattern")) (EBlock (DoLet false false (PVar "cs") (EApp (EVar "toChars") (EVar "pattern"))) (DoLet false false (PTuple (PVar "start") (PVar "fold") (PVar "multi") (PVar "dotAll")) (EApp (EApp (EApp (EApp (EApp (EVar "scanFlags") (EVar "cs")) (ELit (LInt 0))) (EVar "False")) (EVar "False")) (EVar "False"))) (DoLet false false (PVar "st") (ERecordCreate "PState" ((fa "pat" (EVar "cs")) (fa "pos" (EApp (EVar "Ref") (EVar "start"))) (fa "ngroups" (EApp (EVar "Ref") (ELit (LInt 0)))) (fa "perr" (EApp (EVar "Ref") (EVar "None"))) (fa "fold" (EMethodRef "fold")) (fa "dotAll" (EVar "dotAll"))))) (DoLet false false (PVar "node") (EApp (EVar "parseAlt") (EVar "st"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "finishCompile") (EVar "st")) (EVar "node")) (EVar "pattern")) (EVar "multi")))))
(DTypeSig false "finishCompile" (TyFun (TyCon "PState") (TyFun (TyCon "Node") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyApp (TyApp (TyCon "Result") (TyCon "RegexError")) (TyCon "Regex")))))))
(DFunDef false "finishCompile" ((PVar "st") (PVar "node") (PVar "pattern") (PVar "multi")) (EMatch (EUnOp "!" (EFieldAccess (EVar "st") "perr")) (arm (PCon "Some" (PVar "e")) () (EApp (EVar "Err") (EVar "e"))) (arm (PCon "None") () (EIf (EApp (EVar "not") (EApp (EVar "atEnd") (EVar "st"))) (EApp (EVar "Err") (ERecordCreate "RegexError" ((fa "message" (ELit (LString "unbalanced closing )"))) (fa "position" (EUnOp "!" (EFieldAccess (EVar "st") "pos")))))) (EBlock (DoLet false false (PVar "insts") (EBinOp "++" (EApp (EApp (EVar "compileNode") (EVar "node")) (ELit (LInt 0))) (EListLit (EVar "IMatch")))) (DoExpr (EIf (EBinOp ">" (EApp (EMethodRef "length") (EVar "insts")) (EVar "progCap")) (EApp (EVar "Err") (ERecordCreate "RegexError" ((fa "message" (ELit (LString "pattern compiles to more than 20000 instructions"))) (fa "position" (ELit (LInt 0)))))) (EApp (EVar "Ok") (ERecordCreate "Regex" ((fa "src" (EVar "pattern")) (fa "prog" (EApp (EVar "arrayFromList") (EVar "insts"))) (fa "ngroups" (EUnOp "!" (EFieldAccess (EVar "st") "ngroups"))) (fa "multiline" (EVar "multi"))))))))))))
(DTypeSig true "mustCompile" (TyFun (TyCon "String") (TyCon "Regex")))
(DFunDef false "mustCompile" ((PVar "pattern")) (EMatch (EApp (EVar "compile") (EVar "pattern")) (arm (PCon "Ok" (PVar "re")) () (EVar "re")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "regex: ")) (EApp (EMethodRef "display") (EFieldAccess (EVar "e") "message"))) (ELit (LString " at position "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EFieldAccess (EVar "e") "position")))) (ELit (LString " in "))) (EApp (EMethodRef "display") (EApp (EVar "debugStringLit") (EVar "pattern")))) (ELit (LString "")))))))
(DTypeSig true "source" (TyFun (TyCon "Regex") (TyCon "String")))
(DFunDef false "source" ((PVar "re")) (EFieldAccess (EVar "re") "src"))
(DTypeSig true "escape" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "escape" ((PVar "s")) (EApp (EVar "fromChars") (EApp (EApp (EVar "escapeGo") (EApp (EVar "toChars") (EVar "s"))) (ELit (LInt 0)))))
(DTypeSig false "escapeGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Char")))))
(DFunDef false "escapeGo" ((PVar "cs") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit) (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (DoExpr (EIf (EApp (EVar "isMeta") (EVar "c")) (EBinOp "::" (ELit (LChar "\\")) (EBinOp "::" (EVar "c") (EApp (EApp (EVar "escapeGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (EBinOp "::" (EVar "c") (EApp (EApp (EVar "escapeGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))))))
(DTypeSig false "isMeta" (TyFun (TyCon "Char") (TyCon "Bool")))
(DFunDef false "isMeta" ((PVar "c")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "c") (ELit (LChar "\\"))) (EBinOp "==" (EVar "c") (ELit (LChar ".")))) (EBinOp "==" (EVar "c") (ELit (LChar "+")))) (EBinOp "==" (EVar "c") (ELit (LChar "*")))) (EBinOp "==" (EVar "c") (ELit (LChar "?")))) (EBinOp "==" (EVar "c") (ELit (LChar "(")))) (EBinOp "==" (EVar "c") (ELit (LChar ")")))) (EBinOp "==" (EVar "c") (ELit (LChar "|")))) (EBinOp "==" (EVar "c") (ELit (LChar "[")))) (EBinOp "==" (EVar "c") (ELit (LChar "]")))) (EBinOp "==" (EVar "c") (ELit (LChar "{")))) (EBinOp "==" (EVar "c") (ELit (LChar "}")))) (EBinOp "==" (EVar "c") (ELit (LChar "^")))) (EBinOp "==" (EVar "c") (ELit (LChar "$")))))
(DTypeSig true "isMatch" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isMatch" ((PVar "re") (PVar "s")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "searchFrom") (EVar "re")) (EApp (EVar "codesOf") (EVar "s"))) (ELit (LInt 0))) (EVar "False")) (EVar "False")) (EApp (EVar "Ref") (ELit (LInt 0)))) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "isFullMatch" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isFullMatch" ((PVar "re") (PVar "s")) (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "searchFrom") (EVar "re")) (EApp (EVar "codesOf") (EVar "s"))) (ELit (LInt 0))) (EVar "True")) (EVar "True")) (EApp (EVar "Ref") (ELit (LInt 0)))) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "find" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Match")))))
(DFunDef false "find" ((PVar "re") (PVar "s")) (EApp (EApp (EApp (EApp (EApp (EVar "matchOnce") (EVar "re")) (EVar "s")) (ELit (LInt 0))) (EVar "False")) (EVar "False")))
(DTypeSig true "findFrom" (TyFun (TyCon "Int") (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Match"))))))
(DFunDef false "findFrom" ((PVar "from") (PVar "re") (PVar "s")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoLet false false (PVar "at") (EApp (EApp (EMethodRef "max") (ELit (LInt 0))) (EApp (EApp (EMethodRef "min") (EVar "from")) (EVar "n")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "matchOnce") (EVar "re")) (EVar "s")) (EVar "at")) (EVar "False")) (EVar "False")))))
(DTypeSig true "fullMatch" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "Match")))))
(DFunDef false "fullMatch" ((PVar "re") (PVar "s")) (EApp (EApp (EApp (EApp (EApp (EVar "matchOnce") (EVar "re")) (EVar "s")) (ELit (LInt 0))) (EVar "True")) (EVar "True")))
(DTypeSig true "isFullMatchBytes" (TyFun (TyCon "Regex") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "isFullMatchBytes" ((PVar "re") (PVar "bytes") (PVar "start") (PVar "end")) (EBlock (DoLet false false (PTuple (PVar "lo") (PVar "hi")) (EApp (EApp (EApp (EVar "clampWindow") (EVar "bytes")) (EVar "start")) (EVar "end"))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "searchWindow") (EVar "re")) (EVar "bytes")) (ETuple (EVar "lo") (EVar "hi"))) (EVar "lo")) (EVar "True")) (EVar "True")) (EApp (EVar "Ref") (ELit (LInt 0)))) (arm (PCon "Some" PWild) () (EVar "True")) (arm (PCon "None") () (EVar "False"))))))
(DTypeSig true "findBytes" (TyFun (TyCon "Regex") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "Match")))))))
(DFunDef false "findBytes" ((PVar "re") (PVar "bytes") (PVar "start") (PVar "end")) (EBlock (DoLet false false (PTuple (PVar "lo") (PVar "hi")) (EApp (EApp (EApp (EVar "clampWindow") (EVar "bytes")) (EVar "start")) (EVar "end"))) (DoExpr (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "mkMatchWith") (ELam ((PVar "from") (PVar "to")) (EApp (EVar "fromUtf8") (EApp (EApp (EApp (EVar "sliceBytes") (EVar "from")) (EVar "to")) (EVar "bytes"))))) (EVar "re"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "searchWindow") (EVar "re")) (EVar "bytes")) (ETuple (EVar "lo") (EVar "hi"))) (EVar "lo")) (EVar "False")) (EVar "False")) (EApp (EVar "Ref") (ELit (LInt 0))))))))
(DTypeSig true "findAll" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Match")))))
(DFunDef false "findAll" ((PVar "re") (PVar "s")) (EApp (EVar "reverse") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findAllGo") (EVar "re")) (EVar "s")) (EApp (EVar "codesOf") (EVar "s"))) (ELit (LInt 0))) (EUnOp "-" (ELit (LInt 1)))) (EListLit))))
(DTypeSig false "findAllGo" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Array") (TyCon "Int")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Match")) (TyApp (TyCon "List") (TyCon "Match")))))))))
(DFunDef false "findAllGo" ((PVar "re") (PVar "s") (PVar "codes") (PVar "pos") (PVar "prevEnd") (PVar "acc")) (EIf (EBinOp ">" (EVar "pos") (EApp (EVar "arrayLength") (EVar "codes"))) (EVar "acc") (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "searchFrom") (EVar "re")) (EVar "codes")) (EVar "pos")) (EVar "False")) (EVar "False")) (EApp (EVar "Ref") (ELit (LInt 0)))) (arm (PCon "None") () (EVar "acc")) (arm (PCon "Some" (PVar "slots")) () (EBlock (DoLet false false (PVar "lo") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 0))) (EVar "slots"))) (DoLet false false (PVar "hi") (EApp (EApp (EVar "arrayGetUnsafe") (ELit (LInt 1))) (EVar "slots"))) (DoLet false false (PVar "keep") (EApp (EVar "not") (EBinOp "&&" (EBinOp "==" (EVar "hi") (EVar "lo")) (EBinOp "==" (EVar "lo") (EVar "prevEnd"))))) (DoLet false false (PVar "next") (EIf (EBinOp "==" (EVar "hi") (EVar "lo")) (EBinOp "+" (EVar "lo") (ELit (LInt 1))) (EVar "hi"))) (DoLet false false (PVar "acc2") (EIf (EVar "keep") (EBinOp "::" (EApp (EApp (EApp (EVar "mkMatch") (EVar "re")) (EVar "s")) (EVar "slots")) (EVar "acc")) (EVar "acc"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "findAllGo") (EVar "re")) (EVar "s")) (EVar "codes")) (EVar "next")) (EVar "hi")) (EVar "acc2"))))))))
(DTypeSig true "replace" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "replace" ((PVar "re") (PVar "repl") (PVar "s")) (EMatch (EApp (EApp (EVar "find") (EVar "re")) (EVar "s")) (arm (PCon "None") () (EVar "s")) (arm (PCon "Some" (PVar "m")) () (EBinOp "++" (EBinOp "++" (EApp (EApp (EApp (EVar "sliceClamped") (ELit (LInt 0))) (EFieldAccess (EVar "m") "start")) (EVar "s")) (EApp (EApp (EVar "expandRepl") (EVar "repl")) (EVar "m"))) (EApp (EApp (EApp (EVar "sliceClamped") (EFieldAccess (EVar "m") "end")) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s"))))))
(DTypeSig true "replaceAll" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String")))))
(DFunDef false "replaceAll" ((PVar "re") (PVar "repl") (PVar "s")) (EApp (EApp (EApp (EVar "replaceAllWith") (EVar "re")) (ELam ((PVar "m")) (EApp (EApp (EVar "expandRepl") (EVar "repl")) (EVar "m")))) (EVar "s")))
(DTypeSig true "replaceAllWith" (TyFun (TyCon "Regex") (TyFun (TyFun (TyCon "Match") (TyEffect () (Some "e") (TyCon "String"))) (TyFun (TyCon "String") (TyEffect () (Some "e") (TyCon "String"))))))
(DFunDef false "replaceAllWith" ((PVar "re") (PVar "f") (PVar "s")) (EApp (EVar "stringConcat") (EApp (EVar "reverse") (EApp (EApp (EApp (EApp (EApp (EVar "stitch") (EVar "f")) (EVar "s")) (EApp (EApp (EVar "findAll") (EVar "re")) (EVar "s"))) (ELit (LInt 0))) (EListLit)))))
(DTypeSig false "stitch" (TyFun (TyFun (TyCon "Match") (TyEffect () (Some "e") (TyCon "String"))) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Match")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect () (Some "e") (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "stitch" (PWild (PVar "s") (PList) (PVar "beg") (PVar "acc")) (EBinOp "::" (EApp (EApp (EApp (EVar "sliceClamped") (EVar "beg")) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EVar "acc")))
(DFunDef false "stitch" ((PVar "f") (PVar "s") (PCons (PVar "m") (PVar "rest")) (PVar "beg") (PVar "acc")) (EBlock (DoLet false false (PVar "piece") (EApp (EApp (EApp (EVar "sliceClamped") (EVar "beg")) (EFieldAccess (EVar "m") "start")) (EVar "s"))) (DoLet false false (PVar "replaced") (EApp (EVar "f") (EVar "m"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "stitch") (EVar "f")) (EVar "s")) (EVar "rest")) (EFieldAccess (EVar "m") "end")) (EBinOp "::" (EVar "replaced") (EBinOp "::" (EVar "piece") (EVar "acc")))))))
(DTypeSig false "expandRepl" (TyFun (TyCon "String") (TyFun (TyCon "Match") (TyCon "String"))))
(DFunDef false "expandRepl" ((PVar "repl") (PVar "m")) (EApp (EVar "stringConcat") (EApp (EVar "reverse") (EApp (EApp (EApp (EApp (EVar "expandGo") (EApp (EVar "toChars") (EVar "repl"))) (ELit (LInt 0))) (EVar "m")) (EListLit)))))
(DTypeSig false "expandGo" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyFun (TyCon "Match") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "expandGo" ((PVar "cs") (PVar "i") (PVar "m") (PVar "acc")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EVar "acc") (EBlock (DoLet false false (PVar "c") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "==" (EVar "c") (ELit (LChar "$"))) (EBinOp "<" (EBinOp "+" (EVar "i") (ELit (LInt 1))) (EApp (EVar "arrayLength") (EVar "cs")))) (EBlock (DoLet false false (PVar "d") (EApp (EApp (EVar "arrayGetUnsafe") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "cs"))) (DoExpr (EIf (EBinOp "==" (EVar "d") (ELit (LChar "$"))) (EApp (EApp (EApp (EApp (EVar "expandGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "m")) (EBinOp "::" (ELit (LString "$")) (EVar "acc"))) (EIf (EApp (EVar "isDigit") (EVar "d")) (EApp (EApp (EApp (EApp (EVar "expandGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "m")) (EBinOp "::" (EApp (EApp (EVar "groupText") (EVar "m")) (EBinOp "-" (EApp (EVar "charCode") (EVar "d")) (ELit (LInt 48)))) (EVar "acc"))) (EApp (EApp (EApp (EApp (EVar "expandGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "m")) (EBinOp "::" (ELit (LString "$")) (EVar "acc"))))))) (EApp (EApp (EApp (EApp (EVar "expandGo") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "m")) (EBinOp "::" (EApp (EVar "charToStr") (EVar "c")) (EVar "acc"))))))))
(DTypeSig false "groupText" (TyFun (TyCon "Match") (TyFun (TyCon "Int") (TyCon "String"))))
(DFunDef false "groupText" ((PVar "m") (PLit (LInt 0))) (EFieldAccess (EVar "m") "text"))
(DFunDef false "groupText" ((PVar "m") (PVar "k")) (EMatch (EApp (EApp (EVar "get") (EBinOp "-" (EVar "k") (ELit (LInt 1)))) (EFieldAccess (EVar "m") "groups")) (arm (PCon "Some" (PCon "Some" (PVar "g"))) () (EFieldAccess (EVar "g") "text")) (arm PWild () (ELit (LString "")))))
(DTypeSig true "split" (TyFun (TyCon "Regex") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "split" ((PVar "re") (PVar "s")) (EApp (EVar "reverse") (EApp (EApp (EApp (EApp (EApp (EVar "splitGo") (EVar "s")) (EApp (EApp (EVar "findAll") (EVar "re")) (EVar "s"))) (ELit (LInt 0))) (ELit (LInt 0))) (EListLit))))
(DTypeSig false "splitGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Match")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "splitGo" ((PVar "s") (PList) (PVar "beg") (PVar "lastStart") (PVar "acc")) (EIf (EBinOp "/=" (EVar "lastStart") (EApp (EVar "stringLength") (EVar "s"))) (EBinOp "::" (EApp (EApp (EApp (EVar "sliceClamped") (EVar "beg")) (EApp (EVar "stringLength") (EVar "s"))) (EVar "s")) (EVar "acc")) (EVar "acc")))
(DFunDef false "splitGo" ((PVar "s") (PCons (PVar "m") (PVar "rest")) (PVar "beg") PWild (PVar "acc")) (EBlock (DoLet false false (PVar "acc2") (EIf (EBinOp "/=" (EFieldAccess (EVar "m") "end") (ELit (LInt 0))) (EBinOp "::" (EApp (EApp (EApp (EVar "sliceClamped") (EVar "beg")) (EFieldAccess (EVar "m") "start")) (EVar "s")) (EVar "acc")) (EVar "acc"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "splitGo") (EVar "s")) (EVar "rest")) (EFieldAccess (EVar "m") "end")) (EFieldAccess (EVar "m") "start")) (EVar "acc2")))))
(DProp false "escape s full-matches exactly s" ((pp "s" (TyCon "String"))) (EApp (EApp (EVar "isFullMatch") (EApp (EVar "mustCompile") (EApp (EVar "escape") (EVar "s")))) (EVar "s")))
(DProp false "split on a literal separator rejoins to the subject" ((pp "s" (TyCon "String"))) (EBinOp "==" (EApp (EVar "stringConcat") (EApp (EVar "intersperseComma") (EApp (EApp (EVar "split") (EVar "commaRe")) (EVar "s")))) (EVar "s")))
(DTypeSig false "commaRe" (TyCon "Regex"))
(DFunDef false "commaRe" () (EApp (EVar "mustCompile") (ELit (LString ","))))
(DTypeSig false "intersperseComma" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "intersperseComma" ((PList)) (EListLit))
(DFunDef false "intersperseComma" ((PCons (PVar "x") (PList))) (EListLit (EVar "x")))
(DFunDef false "intersperseComma" ((PCons (PVar "x") (PVar "rest"))) (EBinOp "::" (EVar "x") (EBinOp "::" (ELit (LString ",")) (EApp (EVar "intersperseComma") (EVar "rest")))))
(DProp false "findAll spans are ascending and disjoint" ((pp "s" (TyCon "String"))) (EApp (EApp (EVar "spansOrdered") (EApp (EApp (EVar "findAll") (EApp (EVar "mustCompile") (ELit (LString "[a-z]+|.")))) (EVar "s"))) (ELit (LInt 0))))
(DTypeSig false "spansOrdered" (TyFun (TyApp (TyCon "List") (TyCon "Match")) (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "spansOrdered" ((PList) PWild) (EVar "True"))
(DFunDef false "spansOrdered" ((PCons (PVar "m") (PVar "rest")) (PVar "floor")) (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EFieldAccess (EVar "m") "start") (EVar "floor")) (EBinOp ">=" (EFieldAccess (EVar "m") "end") (EFieldAccess (EVar "m") "start"))) (EApp (EApp (EVar "spansOrdered") (EVar "rest")) (EFieldAccess (EVar "m") "end"))))
