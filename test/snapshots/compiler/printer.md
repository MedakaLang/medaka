# META
source_lines=2429
stages=DESUGAR,MARK
# SOURCE
-- Pretty printer for Medaka, producing parseable source from the AST
-- (compiler/frontend/ast.mdk): consistent precedence/parenthesization,
-- operator and keyword spelling, and a Wadler/Leijen document layout engine.
--
-- This is the foundation under the formatter (`medaka fmt`), REPL echo,
-- `medaka new` scaffolding, `lint --fix`, and LSP hover.  The comment-free
-- entry points (`programToString` / `exprToString` / `declToString`) never see
-- a comment; `medaka fmt` (tools/fmt.mdk) hands this module each declaration's
-- interior comments through `setComments` and the printer attaches every one to
-- the layout unit it documents (see "Comments" below).
--
-- ONE layout policy, applied wherever an expression can appear:
--   1. a construct stays on one line when it fits the width;
--   2. a `binder = body` / `pat => body` / `let x = body` / `r := body` that
--      does not fit breaks AFTER the separator and hangs the body one indent
--      step below it — except a bracketed body (list/tuple/record) or an
--      application whose last argument is self-indenting (a lambda, a block,
--      a literal), which keeps its opener on the separator line and breaks
--      INSIDE (the shape every mainstream formatter uses for these);
--   3. a body that still does not fit breaks its OUTERMOST group: an operator
--      chain puts one operand per line with the operator LEADING; an
--      application puts one argument per line; a collection explodes; an
--      `if` ladders `then`/`else`; a signature puts one arrow per line;
--   4. inner groups stay flat while they fit, so the reader sees the largest
--      structure first.
-- Indentation is 2 spaces per step, always a multiple of 2; no alignment.
--
-- AST notes:
--   * `ELoc` wrappers are transparent; the printer peels them for layout
--     decisions and reads them for source lines (comment placement, blank
--     lines).
--   * EMethodRef/EDictApp carry only a name; both print transparently as that
--     name.  EVarAt/EMethodAt/EDictAt/EAnnot-internal nodes are typed-pipeline
--     only and never reach the printer from the parser; transparent fallbacks
--     keep the match total.

import frontend.ast.{
  DeriveRef(..),
  deriveRefName,
  dDataUnresolved,
  KindAnn(..),
  tyParamSources,
  Loc(..),
  Lit(..),
  Ty(..),
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
  UseMember(..),
  UsePath(..),
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
  Attr(..),
}
import support.util.{
  joinWith, listLen, allList, isEmptyL, isNonEmptyL, escOneHex2
}
import list.{last, sortBy}

-- ── Document algebra ──────────────────────────────

public export data Doc =
  | Nil
  | Text String
  | Cat Doc Doc
  -- flat: " "   broken: newline + indent
  | Line
  -- flat: ""    broken: newline + indent
  | Softline
  -- always newline + indent
  | Hardline
  -- an EMPTY output line (no indent) — a preserved blank line between two
  -- statements/arms.  Forces the enclosing group broken.
  | BlankLine
  | Nest Int Doc
  | Group Doc
  -- FlatAlt a b: render `a` when the enclosing group is BROKEN, `b` when FLAT.
  -- A break-only trailing comma is `FlatAlt (text ",") Nil`.
  | FlatAlt Doc Doc
  -- Alt a b: render `a` when its FIRST LINE fits from the current column,
  -- otherwise `b`.  Both share their sub-documents; only one is rendered.
  -- This is how an application chooses between hugging its last argument
  -- (`f x (y =>⏎  …)`) and putting every argument on its own line.
  | Alt Doc Doc
  -- Hang sep body: `sep body` on one line when that fits; else `sep` then the
  -- body one indent step below when the body then fits on ONE line; else
  -- `sep body` inline with the body breaking its own interior (so a list or
  -- record keeps its opener on the separator line).
  | Hang String Doc
  -- LineComment text: a trailing `--` comment anchored to the unit it
  -- documents.  Renders inline as `"  " ++ text`.  It ends the output line, so
  -- every enclosing group is forced broken, and a group that PRECEDES it on
  -- the line is measured only up to it.
  | LineComment String
  -- Fill sepFirst items: FILL (wrap-at-width) layout for a sequence.  When the
  -- enclosing group is FLAT it is exactly `sepBy Line items`.  When BROKEN it
  -- packs greedily: each item goes on the current line if it still fits
  -- `defaultWidth`, otherwise it starts a new line at the current indent.
  -- `sepFirst` says whether a separator precedes the FIRST item of this
  -- (sub)sequence — the render loop re-pushes the unconsumed tail as
  -- `Fill True rest`.  Items must be BREAK-FREE: they render Flat.
  | Fill Bool (List Doc)

text : String -> Doc
text s = Text s

group : Doc -> Doc
group d = Group d

-- the break-only trailing comma for a delimited list: `,` when broken, nothing
-- when flat.
trailingCommaDoc : Doc
trailingCommaDoc = FlatAlt (text ",") Nil

-- one 2-space indent step
nest : Doc -> Doc
nest d = Nest 2 d

sepBy : Doc -> List Doc -> Doc
sepBy _ [] = Nil
sepBy _ [x] = x
sepBy sep (x :: xs) = Cat x (Cat sep (sepBy sep xs))

concatD : List Doc -> Doc
concatD [] = Nil
concatD (d :: ds) = Cat d (concatD ds)

-- A forced newline then the content indented one step (match/do/where/record/
-- interface/impl bodies).
indentBlock : Doc -> Doc
indentBlock d = Nest 2 (Cat Hardline d)

-- ── Layout engine ─────────────────────────────────
-- mode = Flat | Break ; a render item = (indent, mode, doc).

public export data Mode = Flat | Break

public export data Item = Item Int Mode Doc

defaultWidth : Int
defaultWidth = 80

-- The FLAT expansion of a `Fill` — items separated by a single `Line` (a space
-- in Flat mode), with a leading separator iff `sepFirst`.
fillFlatDoc : Bool -> List Doc -> Doc
fillFlatDoc _ [] = Nil
fillFlatDoc False ds = sepBy Line ds
fillFlatDoc True ds = Cat Line (sepBy Line ds)

hangInline : String -> Doc -> Doc
hangInline sep d = Cat (text sep) (Cat (text " ") d)

-- Does the flat layout of `items` fit in `w` columns before a newline?
fits : Int -> List Item -> Bool
fits w _
  | w < 0 = False
fits _ [] = True
fits w ((Item _ _ Nil) :: z) = fits w z
fits w ((Item i m (Cat a b)) :: z) = fits w (Item i m a :: Item i m b :: z)
fits w ((Item i m (Nest j d)) :: z) = fits w (Item (i + j) m d :: z)
fits w ((Item _ _ (Text s)) :: z) = fits (w - stringLength s) z
fits w ((Item _ Flat Line) :: z) = fits (w - 1) z
fits w ((Item _ Flat Softline) :: z) = fits w z
fits _ ((Item _ Break Line) :: _) = True
fits _ ((Item _ Break Softline) :: _) = True
fits _ ((Item _ Break Hardline) :: _) = True
fits _ ((Item _ Flat Hardline) :: _) = False
fits _ ((Item _ Break BlankLine) :: _) = True
fits _ ((Item _ Flat BlankLine) :: _) = False
-- A group keeps the mode it is met in: the candidate under measurement is
-- Flat all the way down, while a group among the items that FOLLOW it on the
-- line (still in the enclosing Break mode) may break at its own first Line —
-- so a long sibling that will break for itself never forces an earlier
-- group open.
fits w ((Item i m (Group d)) :: z) = fits w (Item i m d :: z)
-- fits always measures a FLAT layout → take the flat alternative.
fits w ((Item i m (FlatAlt _ b)) :: z) = fits w (Item i m b :: z)
fits w ((Item i m (Alt a _)) :: z) = fits w (Item i m a :: z)
fits w ((Item i m (Hang sep d)) :: z) =
  fits w (Item i m (hangInline sep d) :: z)
-- A line comment ENDS the line.  A flat candidate that would put anything
-- after it on the same line cannot be flat; one that ends its line at the
-- comment fits (everything before it fit, and `go` renders what follows
-- broken — see the `LineComment` arm there).
fits _ ((Item _ Flat (LineComment _)) :: z) = restEndsLine z
fits _ ((Item _ Break (LineComment _)) :: _) = True
fits w ((Item i m (Fill sf ds)) :: z) =
  fits w (Item i m (fillFlatDoc sf ds) :: z)

-- Would the items after a flat line comment start a new line before printing
-- anything else?  (A Break-mode line does; flat text or a flat space does not.)
restEndsLine : List Item -> Bool
restEndsLine [] = True
restEndsLine ((Item _ _ Nil) :: z) = restEndsLine z
restEndsLine ((Item i m (Cat a b)) :: z) =
  restEndsLine (Item i m a :: Item i m b :: z)
restEndsLine ((Item i m (Nest j d)) :: z) = restEndsLine (Item (i + j) m d :: z)
restEndsLine ((Item _ _ (Text s)) :: z) =
  if s == "" then restEndsLine z else False
restEndsLine ((Item _ Flat Line) :: _) = False
restEndsLine ((Item _ Flat Softline) :: z) = restEndsLine z
restEndsLine ((Item _ Break Line) :: _) = True
restEndsLine ((Item _ Break Softline) :: _) = True
restEndsLine ((Item _ _ Hardline) :: _) = True
restEndsLine ((Item _ _ BlankLine) :: _) = True
restEndsLine ((Item i m (Group d)) :: z) = restEndsLine (Item i m d :: z)
restEndsLine ((Item i m (FlatAlt _ b)) :: z) = restEndsLine (Item i m b :: z)
restEndsLine ((Item i m (Alt a _)) :: z) = restEndsLine (Item i m a :: z)
restEndsLine ((Item i m (Hang sep d)) :: z) =
  restEndsLine (Item i m (hangInline sep d) :: z)
restEndsLine ((Item _ _ (LineComment _)) :: _) = False
restEndsLine ((Item i m (Fill sf ds)) :: z) =
  restEndsLine (Item i m (fillFlatDoc sf ds) :: z)

-- `n` spaces.
spaces : Int -> String
spaces n
  | n <= 0 = ""
  | otherwise = " " ++ spaces (n - 1)

newlineStr : Int -> String
newlineStr i = "\n" ++ spaces i

itemBroken : Item -> Item
itemBroken (Item i _ d) = Item i Break d

-- The render loop: returns the accumulated output pieces (stringConcat'd once).
go : Int -> List Item -> List String
go _ [] = []
go col ((Item _ _ Nil) :: z) = go col z
go col ((Item i m (Cat a b)) :: z) = go col (Item i m a :: Item i m b :: z)
go col ((Item i m (Nest j d)) :: z) = go col (Item (i + j) m d :: z)
go col ((Item _ _ (Text s)) :: z) = s :: go (col + stringLength s) z
go col ((Item _ Flat Line) :: z) = " " :: go (col + 1) z
go col ((Item _ Flat Softline) :: z) = go col z
go _ ((Item i Break Line) :: z) = newlineStr i :: go i z
go _ ((Item i Break Softline) :: z) = newlineStr i :: go i z
go _ ((Item i _ Hardline) :: z) = newlineStr i :: go i z
go _ ((Item _ _ BlankLine) :: z) = "\n" :: go 0 z
go col ((Item i _ (Group d)) :: z) =
  let flat = Item i Flat d :: z
  if fits (defaultWidth - col) flat then
    go col flat
  else
    go col (Item i Break d :: z)
-- FlatAlt: in Flat mode render the flat alternative `b`; in Break mode render `a`.
go col ((Item i Flat (FlatAlt _ b)) :: z) = go col (Item i Flat b :: z)
go col ((Item i Break (FlatAlt a _)) :: z) = go col (Item i Break a :: z)
go col ((Item i Flat (Alt a _)) :: z) = go col (Item i Flat a :: z)
go col ((Item i Break (Alt a b)) :: z) =
  if fits (defaultWidth - col) (Item i Break a :: z) then
    go col (Item i Break a :: z)
  else
    go col (Item i Break b :: z)
go col ((Item i Flat (Hang sep d)) :: z) =
  go col (Item i Flat (hangInline sep d) :: z)
go col ((Item i Break (Hang sep d)) :: z) =
  let inline = hangInline sep d
  if fits (defaultWidth - col) (Item i Flat inline :: z) then
    go col (Item i Flat inline :: z)
  else if fits (defaultWidth - i - 2) (Item (i + 2) Flat d :: z) then
    go col (Item i Break (Cat (text sep) (Nest 2 (Cat Line d))) :: z)
  else
    go col (Item i Break inline :: z)
-- A `--` comment runs to the end of the line, so nothing may follow it there:
-- every pending item switches to Break mode, and the next Line/Softline (a
-- separator, a closing bracket's) starts a fresh line.
go col ((Item _ _ (LineComment s)) :: z) =
  "  " ++ s :: go (col + 2 + stringLength s) (map itemBroken z)
-- Fill, Flat mode: identical to a plain space-separated sequence.
go col ((Item i Flat (Fill sf ds)) :: z) =
  go col (Item i Flat (fillFlatDoc sf ds) :: z)
-- Fill, Break mode: greedy packing.  The FIRST item of the whole fill takes no
-- separator and no fits-check — it is already at the fresh indent.  Every
-- later item is preceded by a space if it still fits, else by a newline at the
-- indent.
go col ((Item _ Break (Fill _ [])) :: z) = go col z
go col ((Item i Break (Fill False (d :: ds))) :: z) =
  go col (Item i Flat d :: Item i Break (Fill True ds) :: z)
go col ((Item i Break (Fill True (d :: ds))) :: z) =
  let rest = Item i Flat d :: Item i Break (Fill True ds) :: z
  if fits (defaultWidth - col - 1) [Item i Flat d] then
    " " :: go (col + 1) rest
  else
    newlineStr i :: go i rest

export
render : Doc -> String
render doc = stringConcat (go 0 [Item 0 Break doc])

-- Render a Doc UNCONDITIONALLY flat — every Group/Line/Softline takes its flat
-- form regardless of width.  Used to measure a `match` scrutinee (see
-- `matchScrutineeDoc`).
goFlat : List Doc -> List String
goFlat [] = []
goFlat (Nil :: z) = goFlat z
goFlat ((Text s) :: z) = s :: goFlat z
goFlat (Line :: z) = " " :: goFlat z
goFlat (Softline :: z) = goFlat z
goFlat (Hardline :: z) = " " :: goFlat z
goFlat (BlankLine :: z) = " " :: goFlat z
goFlat ((Cat a b) :: z) = goFlat (a :: b :: z)
goFlat ((Nest _ d) :: z) = goFlat (d :: z)
goFlat ((Group d) :: z) = goFlat (d :: z)
goFlat ((FlatAlt _ b) :: z) = goFlat (b :: z)
goFlat ((Alt a _) :: z) = goFlat (a :: z)
goFlat ((Hang sep d) :: z) = goFlat (hangInline sep d :: z)
goFlat ((LineComment s) :: z) = "  " ++ s :: goFlat z
goFlat ((Fill sf ds) :: z) = goFlat (fillFlatDoc sf ds :: z)

renderFlat : Doc -> String
renderFlat d = stringConcat (goFlat [d])

-- ── Comments ──────────────────────────────────────
-- `medaka fmt` sets the interior comments of the declaration being printed
-- (ascending by line) plus the line bound past which none of them belongs to
-- this declaration.  Every SEQUENCE the printer lays out — block statements,
-- match arms, guard arms, collection elements, record fields, application
-- arguments, chain operands, interface/impl methods — is printed as a list of
-- `Piece`s (source line span + doc builder), and `pieceDocs` attaches:
--   * every pending comment ABOVE a piece as its own line(s) before it;
--   * every pending non-standalone comment between a piece and the next as a
--     `LineComment` trailing that piece;
--   * standalone comments after the LAST piece as dangling lines;
--   * one blank line where the source had one or more.
-- A comment the walk never reaches stays pending; `medaka fmt` then falls back
-- to the declaration's source text so no comment is ever dropped.

-- line, column, lexeme, standalone (nothing but whitespace precedes it on its line)
public export data PComment = PComment Int Int String Bool

pcLine : PComment -> Int
pcLine (PComment l _ _ _) = l

pcText : PComment -> String
pcText (PComment _ _ t _) = t

pcCol : PComment -> Int
pcCol (PComment _ c _ _) = c

pcStandalone : PComment -> Bool
pcStandalone (PComment _ _ _ s) = s

-- last source line of a (possibly multi-line block) comment
pcEndLine : PComment -> Int
pcEndLine (PComment l _ t _) = l + countNewlines (stringToChars t) 0

countNewlines : Array Char -> Int -> Int
countNewlines cs i
  | i >= arrayLength cs = 0
  | arrayGetUnsafe i cs == '\n' = 1 + countNewlines cs (i + 1)
  | otherwise = countNewlines cs (i + 1)

commentsRef : Ref (List PComment)
commentsRef = Ref []

commentBoundRef : Ref Int
commentBoundRef = Ref 0

commentsUsedRef : Ref Int
commentsUsedRef = Ref 0

-- Install the pending comments for the next `printDecl` call.  `bound` is one
-- past the declaration's last source line.
export
setComments : List PComment -> Int -> Unit
setComments cs bound =
  commentsRef := cs
  commentBoundRef := bound
  declBoundRef := bound
  commentsUsedRef := 0

-- the declaration-level bound: a sequence whose own bound is this one has
-- nothing after it in the declaration
declBoundRef : Ref Int
declBoundRef = Ref 0

-- The comments the last print did not place (and clear them).
export
takeLeftoverComments : Unit -> List PComment
takeLeftoverComments _ =
  let cs = !commentsRef
  commentsRef := []
  cs

-- How many comments the last print placed.
export
commentsPlaced : Unit -> Int
commentsPlaced _ = !commentsUsedRef

-- Pop every pending comment strictly above `line`.
popBefore : Int -> List PComment
popBefore line =
  let cs = !commentsRef
  match spanBefore line cs
    (mine, rest) =>
      commentsRef := rest
      commentsUsedRef := !commentsUsedRef + listLen mine
      mine

spanBefore : Int -> List PComment -> (List PComment, List PComment)
spanBefore _ [] = ([], [])
spanBefore line (c :: rest)
  | pcLine c < line = match spanBefore line rest
    (mine, left) => (c :: mine, left)
  | otherwise = ([], c :: rest)

-- Pop the pending NON-standalone comments on `line` at column `col` or later
-- (the trailing comments of a unit ending there).
popTrailingAt : Int -> Int -> List PComment
popTrailingAt line col =
  let cs = !commentsRef
  match partTrailing line col cs
    (mine, rest) =>
      commentsRef := rest
      commentsUsedRef := !commentsUsedRef + listLen mine
      mine

partTrailing : Int -> Int -> List PComment -> (List PComment, List PComment)
partTrailing _ _ [] = ([], [])
partTrailing line col (c :: rest)
  | pcLine c > line = ([], c :: rest)
  | pcLine c == line
    && not (pcStandalone c)
    && pcCol c >= col = match partTrailing line col rest
    (mine, left) => (c :: mine, left)
  | otherwise = match partTrailing line col rest
    (mine, left) => (mine, c :: left)

-- Pop the pending comments strictly above `line` that sit at column `col` or
-- deeper (the dangling comments of the sequence just printed).
popDanglingBefore : Int -> Int -> List PComment
popDanglingBefore line col =
  let cs = !commentsRef
  match partDangling line col cs
    (mine, rest) =>
      commentsRef := rest
      commentsUsedRef := !commentsUsedRef + listLen mine
      mine

partDangling : Int -> Int -> List PComment -> (List PComment, List PComment)
partDangling _ _ [] = ([], [])
partDangling line col ((PComment cl cc t st) :: rest)
  | cl >= line = ([], PComment cl cc t st :: rest)
  | cc >= col = match partDangling line col rest
    (mine, left) => (PComment cl cc t st :: mine, left)
  | otherwise = match partDangling line col rest
    (mine, left) => (mine, PComment cl cc t st :: left)

-- Build a sub-document whose comments may not reach past line `b` (the start
-- line of whatever follows it): a condition before its `then` branch, a
-- let-in right-hand side before its body, a scrutinee before its arms.
withBound : Int -> (Unit -> Doc) -> Doc
withBound b mk =
  let saved = !commentBoundRef
  let narrowed = b > 0 && b < saved
  if narrowed then commentBoundRef := b
  let d = mk ()
  commentBoundRef := saved
  d

-- Build a sub-document inside which NO unit claims a comment: an `if`
-- condition, a guard, a scrutinee, a let-in right-hand side, a map key.  A
-- comment inside one of those cannot be given its own line without splitting
-- the construct's keyword from its operand, so it stays pending and the
-- declaration falls back to its source text.
noClaimRef : Ref Bool
noClaimRef = Ref False

noClaimDoc : (Unit -> Doc) -> Doc
noClaimDoc mk =
  let saved = !noClaimRef
  noClaimRef := True
  let d = mk ()
  noClaimRef := saved
  d

-- Any pending comment whose line lies in [lo, hi]?
pendingWithin : Int -> Int -> Bool
pendingWithin lo hi = anyWithin lo hi !commentsRef

anyWithin : Int -> Int -> List PComment -> Bool
anyWithin _ _ [] = False
anyWithin lo hi (c :: rest) =
  pcLine c >= lo && pcLine c <= hi || anyWithin lo hi rest

-- Any pending comment strictly inside the span (startLine, startCol) ..
-- (endLine, endCol)?  A comment trailing the span on its last line is not
-- inside it.
pendingInside : Int -> Int -> Int -> Int -> Bool
pendingInside sl sc el ec = anyInside sl sc el ec !commentsRef

anyInside : Int -> Int -> Int -> Int -> List PComment -> Bool
anyInside _ _ _ _ [] = False
anyInside sl sc el ec ((PComment cl cc _ _) :: rest) =
  let afterStart = cl > sl || cl == sl && cc >= sc
  let beforeEnd = cl < el || cl == el && cc < ec
  afterStart && beforeEnd || anyInside sl sc el ec rest

-- ── Source spans ──────────────────────────────────
-- (firstLine, firstCol, lastLine, lastCol) of a node, from the `ELoc`/pattern
-- locations inside it; all zero when it carries none.

noSpan : (Int, Int, Int, Int)
noSpan = (0, 0, 0, 0)

mergeSpan : (Int, Int, Int, Int) -> (Int, Int, Int, Int) -> (Int, Int, Int, Int)
mergeSpan (a1, c1, b1, d1) (a2, c2, b2, d2)
  | a1 == 0 = (a2, c2, b2, d2)
  | a2 == 0 = (a1, c1, b1, d1)
  | otherwise = match earliest (a1, c1) (a2, c2)
    (sl, sc) => match latest (b1, d1) (b2, d2)
      (el, ec) => (sl, sc, el, ec)

earliest : (Int, Int) -> (Int, Int) -> (Int, Int)
earliest (l1, c1) (l2, c2) =
  if l1 < l2 || l1 == l2 && c1 <= c2 then (l1, c1) else (l2, c2)

latest : (Int, Int) -> (Int, Int) -> (Int, Int)
latest (l1, c1) (l2, c2) =
  if l1 > l2 || l1 == l2 && c1 >= c2 then (l1, c1) else (l2, c2)

spanStart : (Int, Int, Int, Int) -> Int
spanStart (s, _, _, _) = s

spansOf : (a -> (Int, Int, Int, Int)) -> List a -> (Int, Int, Int, Int)
spansOf _ [] = noSpan
spansOf f (x :: xs) = mergeSpan (f x) (spansOf f xs)

locSpan : Loc -> (Int, Int, Int, Int)
locSpan (Loc _ sl sc el ec) = (sl, sc, el, ec)

exprSpan : Expr -> (Int, Int, Int, Int)
exprSpan (ELoc l _) = locSpan l
exprSpan (EApp f x) = mergeSpan (exprSpan f) (exprSpan x)
exprSpan (ELam pats body) = mergeSpan (spansOf patSpan pats) (exprSpan body)
exprSpan (ELet _ _ p rhs body) =
  mergeSpan (patSpan p) (mergeSpan (exprSpan rhs) (exprSpan body))
exprSpan (EMatch sc arms) = mergeSpan (exprSpan sc) (spansOf armSpan arms)
exprSpan (EIf c t e) =
  mergeSpan (exprSpan c) (mergeSpan (exprSpan t) (exprSpan e))
exprSpan (EBinOp _ l r _) = mergeSpan (exprSpan l) (exprSpan r)
exprSpan (EUnOp _ e _) = exprSpan e
exprSpan (EInfix _ l r) = mergeSpan (exprSpan l) (exprSpan r)
exprSpan (EFieldAccess e _ _) = exprSpan e
exprSpan (ETuple es) = spansOf exprSpan es
exprSpan (EListLit es) = spansOf exprSpan es
exprSpan (EArrayLit es) = spansOf exprSpan es
exprSpan (ERangeList lo hi _) = mergeSpan (exprSpan lo) (exprSpan hi)
exprSpan (ERangeArray lo hi _) = mergeSpan (exprSpan lo) (exprSpan hi)
exprSpan (ESlice e lo hi _ _) =
  mergeSpan (exprSpan e) (mergeSpan (exprSpan lo) (exprSpan hi))
exprSpan (ELetGroup binds body) =
  mergeSpan (spansOf letBindSpan binds) (exprSpan body)
exprSpan (ESection (SecRight _ e)) = exprSpan e
exprSpan (ESection (SecLeft e _)) = exprSpan e
exprSpan (ESection _) = noSpan
exprSpan (EIndex e i _) = mergeSpan (exprSpan e) (exprSpan i)
exprSpan (EAnnot e _) = exprSpan e
exprSpan (EHeadAnnot e _) = exprSpan e
exprSpan (EBlock stmts) = spansOf stmtSpan stmts
exprSpan (EDo _ stmts) = spansOf stmtSpan stmts
exprSpan (EStringInterp parts) = spansOf interpSpan parts
exprSpan (EGuards arms) = spansOf guardArmSpan arms
exprSpan (ERecordCreate _ fs) = spansOf fieldAssignSpan fs
exprSpan (ERecordUpdate e fs _) =
  mergeSpan (exprSpan e) (spansOf fieldAssignSpan fs)
exprSpan (EVariantUpdate _ e fs) =
  mergeSpan (exprSpan e) (spansOf fieldAssignSpan fs)
exprSpan (EMapLit _ kvs) = spansOf kvSpan kvs
exprSpan (ESetLit _ es) = spansOf exprSpan es
exprSpan (EAsPat _ e) = exprSpan e
exprSpan _ = noSpan

interpSpan : InterpPart -> (Int, Int, Int, Int)
interpSpan (InterpExpr e) = exprSpan e
interpSpan _ = noSpan

kvSpan : (Expr, Expr) -> (Int, Int, Int, Int)
kvSpan (k, v) = mergeSpan (exprSpan k) (exprSpan v)

fieldAssignSpan : FieldAssign -> (Int, Int, Int, Int)
fieldAssignSpan (FieldAssign _ v) = exprSpan v

letBindSpan : LetBind -> (Int, Int, Int, Int)
letBindSpan (LetBind _ clauses) = spansOf clauseSpan clauses

clauseSpan : FunClause -> (Int, Int, Int, Int)
clauseSpan (FunClause pats body) =
  mergeSpan (spansOf patSpan pats) (exprSpan body)

patSpan : Pat -> (Int, Int, Int, Int)
patSpan (PVar _ l) = locSpan l
patSpan (PAs _ l p) = mergeSpan (locSpan l) (patSpan p)
patSpan (PCon _ ps) = spansOf patSpan ps
patSpan (PCons a b) = mergeSpan (patSpan a) (patSpan b)
patSpan (PTuple ps) = spansOf patSpan ps
patSpan (PList ps) = spansOf patSpan ps
patSpan (PRec _ fs _) = spansOf recPatFieldSpan fs
patSpan _ = noSpan

recPatFieldSpan : RecPatField -> (Int, Int, Int, Int)
recPatFieldSpan (RecPatField _ l q) = match q
  Some p => mergeSpan (locSpan l) (patSpan p)
  None => locSpan l

guardSpan : Guard -> (Int, Int, Int, Int)
guardSpan (GBool e) = exprSpan e
guardSpan (GBind p e) = mergeSpan (patSpan p) (exprSpan e)

armSpan : Arm -> (Int, Int, Int, Int)
armSpan (Arm p gs body) =
  mergeSpan (patSpan p) (mergeSpan (spansOf guardSpan gs) (exprSpan body))

guardArmSpan : GuardArm -> (Int, Int, Int, Int)
guardArmSpan (GuardArm gs body) =
  mergeSpan (spansOf guardSpan gs) (exprSpan body)

stmtSpan : DoStmt -> (Int, Int, Int, Int)
stmtSpan (DoExpr e) = exprSpan e
stmtSpan (DoBind p e) = mergeSpan (patSpan p) (exprSpan e)
stmtSpan (DoLet _ _ p e) = mergeSpan (patSpan p) (exprSpan e)
stmtSpan (DoAssign _ e) = exprSpan e
stmtSpan (DoFieldAssign _ _ e) = exprSpan e

-- ── Pieces: sequences with comments and blank lines ──────────────────────

-- A layout unit: its source span (start line, start column, end line, end
-- column) and its doc builder.
data Piece = Piece Int Int Int Int (Unit -> Doc)

-- A rendered piece: whether a blank line precedes it, and its doc with any
-- leading/trailing comments folded in.
data PieceOut = PieceOut Bool Doc

pieceOutDoc : PieceOut -> Doc
pieceOutDoc (PieceOut _ d) = d

exprPiece : Expr -> Piece
exprPiece e = match exprSpan e
  (s, sc, en, ec) => Piece s sc en ec (_ => printExpr precTop e)

-- Render the pieces in order.  `sepAfter isLast` is glued right after each
-- piece's doc, BEFORE its trailing comment (a comma must precede `-- note`).
-- An expression-level sequence (elements, arguments, operands): a standalone
-- comment after its LAST piece belongs to it only when indented STRICTLY
-- deeper than its first piece — one at the same column documents the
-- enclosing sequence's next unit (the next list element, say), whose first
-- token shares that column.
pieceDocs : (Bool -> Doc) -> List Piece -> List PieceOut
pieceDocs sepAfter ps = pieceDocsGo sepAfter (firstPieceCol ps + 1) 0 ps

-- A statement-level sequence (statements, arms, guards, methods, clauses):
-- one line per piece, so a trailing standalone comment AT the pieces' column
-- is still inside the sequence.
pieceDocsHard : List Piece -> List PieceOut
pieceDocsHard ps = pieceDocsGo noSep (firstPieceCol ps) 0 ps

firstPieceCol : List Piece -> Int
firstPieceCol ((Piece _ sc _ _ _) :: _) = sc
firstPieceCol [] = 0

-- `dangCol` is the column a standalone comment after the LAST piece must reach
-- to belong to this sequence; a shallower one is left for the enclosing
-- sequence's next unit.  Such a comment is claimed at all only when nothing
-- follows this sequence in the declaration — otherwise the enclosing
-- sequence's next unit takes it as its leading comment.
pieceDocsGo : (Bool -> Doc) -> Int -> Int -> List Piece -> List PieceOut
pieceDocsGo _ _ _ [] = []
pieceDocsGo sepAfter dangCol prevEnd ((Piece s sc en ec mk) :: rest) =
  let isLast = isEmptyL rest
  let bound = !commentBoundRef
  let nextStart = match rest
    (Piece s2 _ _ _ _) :: _ => if s2 > 0 then s2 else bound
    [] => bound
  let claim = not !noClaimRef
  let leading = if claim && s > 0 then popBefore s else []
  let firstLine = match leading
    c :: _ => pcLine c
    [] => s
  let blankBefore = prevEnd > 0 && s > 0 && firstLine - prevEnd >= 2
  let leadDoc = leadingCommentsDoc leading s
  -- The trailing comment is claimed BEFORE the piece's own sub-documents are
  -- built, so the OUTERMOST unit ending on that line owns it (an inner
  -- operand would otherwise put it inside a closing bracket) — and only when
  -- nothing else starts on that line after the piece, so the LAST unit on the
  -- line owns it (a condition never takes its `then` branch's comment).
  let trailing =
    if claim && en > 0 && nextStart > en then popTrailingAt en ec else []
  commentBoundRef := nextStart
  let d = mk ()
  commentBoundRef := bound
  let trailDoc = concatD (map (c => LineComment (pcText c)) trailing)
  let dangling =
    if claim && isLast && s > 0 && nextStart == !declBoundRef then
      popDanglingBefore nextStart dangCol
    else
      []
  let dangDoc = concatD (map (c => Cat Hardline (text (pcText c))) dangling)
  let out = Cat leadDoc (Cat d (Cat (sepAfter isLast) (Cat trailDoc dangDoc)))
  PieceOut blankBefore out
    :: pieceDocsGo sepAfter dangCol (if en > 0 then en else prevEnd) rest

-- Leading comments, one per line, each followed by a preserved blank line when
-- the source had one between it and what follows.
leadingCommentsDoc : List PComment -> Int -> Doc
leadingCommentsDoc [] _ = Nil
leadingCommentsDoc (c :: rest) s =
  let nextLine = match rest
    c2 :: _ => pcLine c2
    [] => s
  let gap = if nextLine - pcEndLine c >= 2 then BlankLine else Nil
  Cat (text (pcText c)) (Cat gap (Cat Hardline (leadingCommentsDoc rest s)))

noSep : Bool -> Doc
noSep _ = Nil

-- A lone unit that starts its own line (a branch, a body): the same comment
-- handling as a one-piece sequence.
soloDoc : Expr -> (Unit -> Doc) -> Doc
soloDoc e mk = match exprSpan e
  (s, sc, en, ec) => joinLine (pieceDocs noSep [Piece s sc en ec mk])

commaSep : Bool -> Doc
commaSep isLast = if isLast then trailingCommaDoc else text ","

-- Statements / arms: Hardline-separated, blank lines preserved.
joinHard : List PieceOut -> Doc
joinHard [] = Nil
joinHard ((PieceOut _ d) :: rest) = Cat d (joinHardRest rest)

joinHardRest : List PieceOut -> Doc
joinHardRest [] = Nil
joinHardRest ((PieceOut blank d) :: rest) =
  Cat
    (if blank then BlankLine else Nil)
    (Cat Hardline (Cat d (joinHardRest rest)))

-- Elements: Line-separated (a space when flat, a newline when broken).
joinLine : List PieceOut -> Doc
joinLine [] = Nil
joinLine ((PieceOut _ d) :: rest) =
  Cat d (concatD (map (p => Cat Line (pieceOutDoc p)) rest))

-- Did any piece pick up a comment?  (Decides fill vs. explode.)
anyCommented : List Piece -> Bool
anyCommented [] = False
anyCommented ps =
  let lo = spanStart (spansOf pieceSpan ps)
  lo > 0 && pendingWithin lo (!commentBoundRef - 1)

pieceSpan : Piece -> (Int, Int, Int, Int)
pieceSpan (Piece s sc en ec _) = (s, sc, en, ec)

-- ── Delimited sequences ───────────────────────────

-- `open item, item, … close`: one line when it fits; else one item per line
-- with a trailing comma (`forced` = the source carried a trailing comma, which
-- pins the exploded form).
delimitedPieces : String -> String -> Bool -> List Piece -> Doc
delimitedPieces open_ close_ _ [] = Cat (text open_) (text close_)
delimitedPieces open_ close_ forced ps =
  let outs = pieceDocs commaSep ps
  group
    (Cat
      (text open_)
      (Cat
        (nest (Cat (if forced then Hardline else Softline) (joinLine outs)))
        (Cat Softline (text close_))))

-- Like `delimitedPieces`, but the items PACK to the width when the literal does
-- not fit (`[1, 2, 3, …` wrapped at 80).  No trailing comma in the packed form,
-- so the author's choice between packed and one-per-line is exactly whether
-- the source ends the list with a comma.
filledDocs : String -> String -> List Doc -> Doc
filledDocs open_ close_ [] = Cat (text open_) (text close_)
filledDocs open_ close_ items =
  group
    (Cat
      (text open_)
      (Cat
        (nest (Cat Softline (Fill False (commaJoinFill items))))
        (Cat Softline (text close_))))

-- Glue a `,` onto every item but the last: the fill's SEPARATOR is whitespace
-- only, so the comma has to travel with the item it follows.
commaJoinFill : List Doc -> List Doc
commaJoinFill [] = []
commaJoinFill [d] = [d]
commaJoinFill (d :: ds) = Cat d (text ",") :: commaJoinFill ds

-- brace-delimited sequence with inner padding (`{ a = 1, b = 2 }`).
bracedPieces : String -> Bool -> List Piece -> Doc
bracedPieces open_ _ [] = Cat (text open_) (text "}")
bracedPieces open_ forced ps =
  let outs = pieceDocs commaSep ps
  group
    (Cat
      (text open_)
      (Cat
        (nest (Cat (if forced then Hardline else Line) (joinLine outs)))
        (Cat Line (text "}"))))

-- ── Magic trailing comma ──────────────────────────
-- The parser records the source position of every trailing comma it consumed
-- (`trailingCommaLocs`, a (line, col) list); `medaka fmt` installs them here.
-- A collection literal whose last element is followed by one of them explodes
-- one element per line.

-- Sorted by (line, col) so each literal's lookup is a binary search; a scan
-- per literal made a file with N literals cost N x commas.
trailingCommasRef : Ref (Array (Int, Int))
trailingCommasRef = Ref (arrayFromList [])

export
setTrailingCommas : List (Int, Int) -> Unit
setTrailingCommas cs = trailingCommasRef := arrayFromList (sortBy cmpPos cs)

cmpPos : (Int, Int) -> (Int, Int) -> Ordering
cmpPos (l1, c1) (l2, c2) = if l1 == l2 then compare c1 c2 else compare l1 l2

-- number of entries strictly before (line, col)
posLowerBound : Array (Int, Int) -> Int -> Int -> Int -> Int -> Int
posLowerBound arr line col lo hi =
  if lo >= hi then
    lo
  else
    let mid = (lo + hi) / 2
    match arr[mid]
      (l, c) =>
        if l < line || l == line && c < col then
          posLowerBound arr line col (mid + 1) hi
        else
          posLowerBound arr line col lo mid

-- A recorded trailing comma strictly after (`lastLine`, `lastCol`) — the last
-- element's end — and before the literal's closing line/col.
hasTrailingComma : Int -> Int -> Int -> Int -> Bool
hasTrailingComma lastLine lastCol endLine endCol =
  let arr = !trailingCommasRef
  let i = posLowerBound arr lastLine lastCol 0 (arrayLength arr)
  if i >= arrayLength arr then
    False
  else match arr[i]
    (l, c) => l < endLine || l == endLine && c < endCol

-- Last element's (endLine, endCol) from its ELoc, if any.
exprEndPos : Expr -> Option (Int, Int)
exprEndPos (ELoc (Loc _ _ _ el ec) _) = Some (el, ec)
exprEndPos (EApp _ x) = exprEndPos x
exprEndPos (EBinOp _ _ r _) = exprEndPos r
exprEndPos (EFieldAccess e _ _) = exprEndPos e
exprEndPos _ = None

-- Does the literal at `loc` (its own ELoc) with elements `es` end with a
-- source trailing comma?
literalForced : Option Loc -> List Expr -> Bool
literalForced (Some (Loc _ _ _ el ec)) es = match last es
  Some e => match exprEndPos e
    Some (ll, lc) => hasTrailingComma ll lc el ec
    None => False
  None => False
literalForced None _ = False

fieldForced : Option Loc -> List FieldAssign -> Bool
fieldForced loc fs = literalForced loc (map (f => fieldAssignValue f) fs)

fieldAssignValue : FieldAssign -> Expr
fieldAssignValue (FieldAssign _ v) = v

kvForced : Option Loc -> List (Expr, Expr) -> Bool
kvForced loc kvs = literalForced loc (map (kv => snd kv) kvs)

-- ── Literals ──────────────────────────────────────

escapeCharLit : String -> String
escapeCharLit c
  | c == "'" = "\\'"
  | c == "\\" = "\\\\"
  | c == "\n" = "\\n"
  | c == "\t" = "\\t"
  | c == "\r" = "\\r"
  | c == "\0" = "\\0"
  | otherwise = c

-- String-literal escaping: quote, backslash, \n \t \r, NUL, and any other C0
-- control char as `\u{XX}` — never a raw control byte (a raw NUL once landed in
-- this file's own source and made it invisible to grep).
escStringLit : String -> String
escStringLit s = "\"" ++ stringConcat (escSChars (stringToChars s) 0) ++ "\""

escSChars : Array Char -> Int -> List String
escSChars cs i
  | i >= arrayLength cs = []
  | otherwise = escSOne (arrayGetUnsafe i cs) :: escSChars cs (i + 1)

escSOne : Char -> String
-- Intentional cross-file duplicate of the same helper in util.mdk; not consolidating (tiny helper / divergent-by-design backend pair).
-- lint-disable-next-line rule-duplicate-body
escSOne c
  | c == '\\' = "\\\\"
  | c == '"' = "\\\""
  | c == '\n' = "\\n"
  | c == '\t' = "\\t"
  | c == '\r' = "\\r"
  | c == '\0' = "\\0"
  | charCode c < 32 = "\\u{\{escOneHex2 (charCode c)}}"
  | otherwise = charToStr c

printLit : Lit -> Doc
printLit (LInt n) = text (intToString n)
-- `floatToString` renders a whole-valued float as `N.` (no fractional digit),
-- which is not a parseable literal; append `0` so `1.0` round-trips.
printLit (LFloat f) =
  let s = floatToString f
  let n = stringLength s
  text (if n > 0 && stringSlice (n - 1) n s == "." then s ++ "0" else s)
printLit (LString s) = text (escStringLit s)
printLit (LChar c) = text ("'" ++ escapeCharLit c ++ "'")
printLit (LBool b) = text (if b then "True" else "False")
printLit LUnit = text "()"

isNegLit : Lit -> Bool
isNegLit (LInt n) = n < 0
isNegLit (LFloat f) =
  let s = floatToString f
  stringLength s > 0 && stringSlice 0 1 s == "-"
isNegLit _ = False

-- ── Types ─────────────────────────────────────────

-- The bare tuple type constructors round-trip as `(,)`/`(,,)`/… — the parser
-- lowers those to `TyCon "__tupleN__"`, so the printer must render that
-- internal name back to the surface spelling.
tyConSurface : String -> String
tyConSurface "__tuple2__" = "(,)"
tyConSurface "__tuple3__" = "(,,)"
tyConSurface "__tuple4__" = "(,,,)"
tyConSurface "__tuple5__" = "(,,,,)"
tyConSurface "__tuple6__" = "(,,,,,)"
tyConSurface "__tuple7__" = "(,,,,,,)"
tyConSurface "__tuple8__" = "(,,,,,,,)"
tyConSurface n = n

printType : Ty -> Doc
printType (TyCon { tyConName = n }) = text (tyConSurface n)
printType (TyVar n) = text n
printType (TyApp a b) =
  Cat (printTypeAppLhs a) (Cat (text " ") (printTypeAtom b))
printType (TyFun a b) =
  Cat (printTypeFunLhs a) (Cat (text " -> ") (printType b))
printType (TyTuple ts) =
  Cat (text "(") (Cat (sepBy (text ", ") (map printType ts)) (text ")"))
printType (TyEffect es tail t) =
  let inside = effectInside es tail
  Cat (text "<") (Cat inside (Cat (text "> ") (printTypeAppLhs t)))
printType (TyRow [] (a :: b :: rest) _) =
  Cat (text "(") (Cat (text (joinWith " | " (a :: b :: rest))) (text ")"))
printType (TyRow es tail _) =
  Cat (text "<") (Cat (effectInside es tail) (text ">"))
printType (TyConstrained cs t) =
  Cat (constraintsDoc cs) (Cat (text " => ") (printType t))

constraintsDoc : List Constraint -> Doc
constraintsDoc [c] = printConstraint c
constraintsDoc cs =
  Cat (text "(") (Cat (sepBy (text ", ") (map printConstraint cs)) (text ")"))

-- A type in SIGNATURE position: one line when it fits, else one arrow per
-- line with the arrow TRAILING (`A ->` / `B ->` / `C`), the constraint list
-- ending the first line (`name : (C a) =>`).  A function type nested in an
-- argument stays flat.
sigTypeDoc : Ty -> Doc
sigTypeDoc (TyConstrained cs t) =
  group
    (Cat
      (constraintsDoc cs)
      (Cat (text " =>") (nest (Cat Line (arrowChain t)))))
sigTypeDoc t = group (nest (arrowChain t))

arrowChain : Ty -> Doc
arrowChain (TyFun a b) =
  Cat (printTypeFunLhs a) (Cat (text " ->") (Cat Line (arrowChain b)))
arrowChain t = printType t

effectInside : List (String, Option String) -> List String -> Doc
effectInside es [] = sepBy (text ", ") (map effAtomDoc es)
effectInside [] tails = text (joinWith " | " tails)
effectInside es tails =
  Cat
    (sepBy (text ", ") (map effAtomDoc es))
    (Cat (text " | ") (text (joinWith " | " tails)))

-- one row atom as a Doc: the label, or label + space + quoted param.
effAtomDoc : (String, Option String) -> Doc
effAtomDoc (l, None) = text l
effAtomDoc (l, Some s) = text "\{l} \{escStringLit s}"

printConstraint : Constraint -> Doc
printConstraint (Constraint { constraintHead = iface, constraintArgs = args }) =
  Cat (text iface) (concatD (map (a => Cat (text " ") (printTypeAtom a)) args))

printTypeAtom : Ty -> Doc
printTypeAtom (TyCon { tyConName = n }) = text (tyConSurface n)
printTypeAtom (TyVar n) = text n
printTypeAtom (TyTuple ts) = printType (TyTuple ts)
-- A bare row atom is already a complete atom (`<Stdout>`) — print it bare.
printTypeAtom (TyRow es tail loc) = printType (TyRow es tail loc)
-- A `TyEffect` in argument position keeps its parentheses: its wrapped type can
-- be a genuine payload (`Foo (<Stdout> Int)`), and nothing in the AST
-- distinguishes that from the pre-#997 filler spelling — dropping the parens
-- would silently drop a real type.
printTypeAtom t = Cat (text "(") (Cat (printType t) (text ")"))

printTypeFunLhs : Ty -> Doc
printTypeFunLhs (TyFun a b) =
  Cat (text "(") (Cat (printType (TyFun a b)) (text ")"))
printTypeFunLhs (TyConstrained cs t) =
  Cat (text "(") (Cat (printType (TyConstrained cs t)) (text ")"))
printTypeFunLhs t = printType t

-- Left operand of a TyApp: a nested TyApp prints bare; anything else as an atom.
printTypeAppLhs : Ty -> Doc
printTypeAppLhs (TyApp a b) = printType (TyApp a b)
printTypeAppLhs t = printTypeAtom t

-- ── Patterns ──────────────────────────────────────

printPat : Pat -> Doc
printPat (PVar x _) = text x
printPat PWild = text "_"
printPat (PLit l) = printLit l
printPat (PCon c []) = text c
printPat (PCon c pats) =
  Cat
    (text "(")
    (Cat
      (text c)
      (Cat
        (concatD (map (p => Cat (text " ") (printPatAtom p)) pats))
        (text ")")))
printPat (PCons a b) = Cat (printPatAtom a) (Cat (text " :: ") (printPat b))
printPat (PTuple ps) =
  Cat (text "(") (Cat (sepBy (text ", ") (map printPatArm ps)) (text ")"))
printPat (PList ps) =
  Cat (text "[") (Cat (sepBy (text ", ") (map printPatArm ps)) (text "]"))
printPat (PAs x _ inner) = Cat (text x) (Cat (text "@") (printPatAtom inner))
printPat (PRec name fields rest) =
  let fieldDocs = map recPatFieldDoc fields
  let all = if rest then fieldDocs ++ [text "..."] else fieldDocs
  Cat (text name) (Cat (text " { ") (Cat (sepBy (text ", ") all) (text " }")))
printPat (PRng lo hi incl) =
  Cat (printLit lo) (Cat (text (if incl then "..=" else "..")) (printLit hi))

recPatFieldDoc : RecPatField -> Doc
recPatFieldDoc (RecPatField k _ None) = text k
recPatFieldDoc (RecPatField k _ (Some q)) =
  Cat (text k) (Cat (text " = ") (printPat q))

-- PCon with args already self-parenthesizes in printPat, so it is atom-safe.
-- A PRec with fields is NOT self-delimiting, so in atom position it must be
-- parenthesized.
printPatAtom : Pat -> Doc
printPatAtom (PVar x l) = printPat (PVar x l)
printPatAtom PWild = printPat PWild
printPatAtom (PLit l) = printPat (PLit l)
printPatAtom (PCon c ps) = printPat (PCon c ps)
printPatAtom (PTuple ps) = printPat (PTuple ps)
printPatAtom (PList ps) = printPat (PList ps)
printPatAtom (PRec n fs r) =
  Cat (text "(") (Cat (printPat (PRec n fs r)) (text ")"))
printPatAtom (PRng lo hi incl) = printPat (PRng lo hi incl)
printPatAtom p = Cat (text "(") (Cat (printPat p) (text ")"))

-- Top-of-a-match-arm pattern: an outer constructor application stands alone, so
-- `Some i =>` needs no parens; nested args still route through printPatAtom.
printPatArm : Pat -> Doc
printPatArm (PCon c (p :: ps)) =
  Cat (text c) (concatD (map (q => Cat (text " ") (printPatAtom q)) (p :: ps)))
printPatArm p = printPat p

-- ── Expression precedence ─────────────────────────

precTop : Int
precTop = 0
precAssign : Int
precAssign = 1
precPipe : Int
precPipe = 2
precCompose : Int
precCompose = 3
precOr : Int
precOr = 4
precAnd : Int
precAnd = 5
precCmp : Int
precCmp = 6
precCons : Int
precCons = 7
precAppend : Int
precAppend = 8
precAdd : Int
precAdd = 9
precMul : Int
precMul = 10
precInfix : Int
precInfix = 11
precApp : Int
precApp = 12
precUnary : Int
precUnary = 13
precPostfix : Int
precPostfix = 14
precAtom : Int
precAtom = 15

binopPrec : String -> Int
binopPrec op
  | op == ":=" = precAssign
  | op == "|>" = precPipe
  | op == ">>" = precCompose
  | op == "<<" = precCompose
  | op == "||" = precOr
  | op == "&&" = precAnd
  | op == "==" = precCmp
  | op == "/=" = precCmp
  | op == "<" = precCmp
  | op == ">" = precCmp
  | op == "<=" = precCmp
  | op == ">=" = precCmp
  | op == "::" = precCons
  | op == "++" = precAppend
  | op == "+" = precAdd
  | op == "-" = precAdd
  | op == "*" = precMul
  | op == "/" = precMul
  | otherwise = precInfix

isRightAssoc : String -> Bool
isRightAssoc "::" = True
isRightAssoc ":=" = True
isRightAssoc _ = False

exprPrec : Expr -> Int
exprPrec (ELit l) = if isNegLit l then precUnary else precAtom
exprPrec (ENumLit n _ _ _) = if n < 0 then precUnary else precAtom
exprPrec (EVar _) = precAtom
exprPrec (EVarId _ _) = precAtom
exprPrec (EMethodRef _) = precAtom
exprPrec (EDictApp _) = precAtom
exprPrec (ETuple _) = precAtom
exprPrec (EArrayLit _) = precAtom
exprPrec (EListLit _) = precAtom
exprPrec (EMapLit _ _) = precAtom
exprPrec (ESetLit _ _) = precAtom
exprPrec (EStringInterp _) = precAtom
exprPrec (ERecordCreate _ _) = precAtom
exprPrec (ERecordUpdate _ _ _) = precAtom
exprPrec (EVariantUpdate _ _ _) = precAtom
exprPrec (ERangeList _ _ _) = precAtom
exprPrec (ERangeArray _ _ _) = precAtom
exprPrec (ESlice _ _ _ _ _) = precAtom
exprPrec (EFieldAccess _ _ _) = precPostfix
exprPrec (EIndex _ _ _) = precPostfix
exprPrec (EUnOp _ _ _) = precUnary
exprPrec (EApp _ _) = precApp
exprPrec (EInfix _ _ _) = precInfix
exprPrec (EBinOp op _ _ _) = binopPrec op
exprPrec (ESection _) = precAtom
exprPrec (EAsPat _ _) = precApp
exprPrec (ELam _ _) = precTop
exprPrec (ELet _ _ _ _ _) = precTop
exprPrec (ELetGroup _ _) = precTop
exprPrec (EIf _ _ _) = precTop
exprPrec (EMatch _ _) = precTop
exprPrec (EBlock _) = precTop
exprPrec (EDo _ _) = precTop
exprPrec (EAnnot _ _) = precTop
exprPrec (EHeadAnnot _ _) = precTop
exprPrec (EGuards _) = precTop
-- typed-pipeline-only nodes (never from the parser); give them atom precedence.
exprPrec (EVarAt _ _) = precAtom
exprPrec (EMethodAt _ _ _ _) = precAtom
exprPrec (EDictAt _ _) = precAtom
-- ELoc is transparent: the wrapper takes its child's precedence.
exprPrec (ELoc _ e) = exprPrec e

stripLocE : Expr -> Expr
stripLocE (ELoc _ e) = stripLocE e
stripLocE e = e

-- the outermost ELoc of an expression, if any (a literal's own span)
-- ── Body shapes ───────────────────────────────────

-- A `match`/`do`: keeps its keyword on the separator line (`= match sc`, `= do`).
isKeywordBlock : Expr -> Bool
isKeywordBlock e = match stripLocE e
  EMatch _ _ => True
  EDo _ _ => True
  _ => False

isBareBlock : Expr -> Bool
isBareBlock e = match stripLocE e
  EBlock _ => True
  _ => False

isGuardsBody : Expr -> Bool
isGuardsBody e = match stripLocE e
  EGuards _ => True
  _ => False

-- A body whose printed form always spans multiple lines.
isUnitLit : Expr -> Bool
isUnitLit e = match stripLocE e
  ELit LUnit => True
  _ => False

-- A bracketed body that keeps its opener on the separator line when it must
-- break (`= [` / `= (` / `= Name {`).
isDelimitedBody : Expr -> Bool
isDelimitedBody e = match stripLocE e
  EListLit (_ :: _) => True
  EArrayLit (_ :: _) => True
  ETuple (_ :: _) => True
  ERecordCreate _ (_ :: _) => True
  ERecordUpdate _ _ _ => True
  EVariantUpdate _ _ _ => True
  EMapLit _ (_ :: _) => True
  ESetLit _ (_ :: _) => True
  _ => False

-- An argument that self-indents its own multi-line body when broken: a
-- lambda, a block, a literal, a bracketed `match`/`do`/`if`.
isHuggableArg : Expr -> Bool
isHuggableArg e = match stripLocE e
  ELam _ _ => True
  EBlock _ => True
  EDo _ _ => True
  EMatch _ _ => True
  EIf _ _ _ => True
  EListLit (_ :: _) => True
  EArrayLit (_ :: _) => True
  ETuple (_ :: _) => True
  ERecordCreate _ (_ :: _) => True
  ERecordUpdate _ _ _ => True
  EVariantUpdate _ _ _ => True
  EMapLit _ (_ :: _) => True
  ESetLit _ (_ :: _) => True
  _ => False

-- Does an application hug its last argument?  Only when every earlier
-- argument is simple (an atom or a flat application), so the hug's first line
-- stays readable.
appHugsLast : Expr -> Bool
appHugsLast e = match collectApp [] e
  (_, args) => match last args
    Some lastArg => isHuggableArg lastArg && allList isSimpleArg (initOf args)
    None => False

initOf : List a -> List a
initOf [] = []
initOf [_] = []
initOf (x :: xs) = x :: initOf xs

isSimpleArg : Expr -> Bool
isSimpleArg e = not (isHuggableArg e)

-- ── Expressions ───────────────────────────────────

-- A fill "atom": a literal or a name — an element that never breaks, so a
-- list of them packs to the width instead of going one-per-line.
isFillAtom : Expr -> Bool
isFillAtom e = match stripLocE e
  ENumLit _ _ _ _ => True
  ELit _ => True
  EVar _ => True
  EVarId _ _ => True
  EMethodRef _ => True
  EDictApp _ => True
  EUnOp op inner _ => op == "-" && isFillAtom inner
  _ => False

isFillable : List Expr -> Bool
isFillable es = listLen es >= 2 && allList isFillAtom es

-- `[…]` / `[|…|]`: exploded when the source pins it with a trailing comma;
-- packed when every element is an atom; else one element per line when broken.
collectionDoc : String -> String -> Option Loc -> List Expr -> Doc
collectionDoc open_ close_ loc es =
  let forced = literalForced loc es
  let ps = map exprPiece es
  if not forced && isFillable es && not (anyCommented ps) then
    filledDocs open_ close_ (map (e => printExpr precTop e) es)
  else
    delimitedPieces open_ close_ forced ps

printExpr : Int -> Expr -> Doc
printExpr minPrec e =
  let ep = exprPrec e
  let d = printExprRaw None e
  if ep < minPrec then Cat (text "(") (Cat d (text ")")) else d

-- The raw form; `loc` is the outermost ELoc seen on the way down (a literal's
-- own span, for the magic trailing comma).
doKeyword : Bool -> String
doKeyword True = "defer"
doKeyword False = "do"

printExprRaw : Option Loc -> Expr -> Doc
printExprRaw _ (ELit l) = printLit l
-- ENumLit renders the ORIGINAL SOURCE LEXEME so the author's radix and
-- separators survive (`0xD800`, `1_000`); a synthesized literal carries "".
printExprRaw _ (ENumLit n _ _ lx) =
  text (if lx == "" then intToString n else lx)
printExprRaw _ (EVar n) = text n
printExprRaw _ (EVarId n _) = text n
printExprRaw _ (EMethodRef n) = text n
printExprRaw _ (EDictApp n) = text n
printExprRaw _ (EApp f x) = printAppSpine (EApp f x)
printExprRaw _ (ELam pats body) =
  Cat (sepBy (text " ") (map printPatAtom pats)) (sepBody " =>" body)
printExprRaw _ (ELet _ isf pat rhs e2) = printELet isf pat rhs e2
printExprRaw _ (ELetGroup bindings body) = letRecInDoc bindings body
printExprRaw _ (EIf c t e) = printIf c t e
printExprRaw _ (EBinOp op l r rf) = printBinOp (EBinOp op l r rf)
printExprRaw _ (EUnOp op e _) = Cat (text op) (printExpr precUnary e)
printExprRaw _ (EFieldAccess e f _) =
  Cat (printExpr precPostfix e) (Cat (text ".") (text f))
printExprRaw loc (ERecordCreate n fs) =
  Cat
    (text n)
    (Cat
      (text " ")
      (bracedPieces "{" (fieldForced loc fs) (map fieldAssignPiece fs)))
printExprRaw loc (ERecordUpdate e fs _) =
  let baseD = noClaimDoc (_ => printExpr precTop e)
  let headD = Cat (text "{ ") (Cat baseD (text " |"))
  bracedPieces (renderFlat headD) (fieldForced loc fs) (map fieldAssignPiece fs)
printExprRaw loc (EVariantUpdate c e fs) =
  let baseD = noClaimDoc (_ => printExpr precTop e)
  let headD = Cat (text c) (Cat (text " { ") (Cat baseD (text " |")))
  bracedPieces (renderFlat headD) (fieldForced loc fs) (map fieldAssignPiece fs)
printExprRaw loc (EArrayLit es) = collectionDoc "[|" "|]" loc es
printExprRaw loc (EListLit es) = collectionDoc "[" "]" loc es
printExprRaw loc (EMapLit n kvs) =
  Cat
    (text n)
    (Cat (text " ") (bracedPieces "{" (kvForced loc kvs) (map mapKvPiece kvs)))
printExprRaw loc (ESetLit n es) =
  Cat
    (text n)
    (Cat
      (text " ")
      (bracedPieces "{" (literalForced loc es) (map exprPiece es)))
printExprRaw loc (ETuple es) =
  delimitedPieces "(" ")" (literalForced loc es) (map exprPiece es)
printExprRaw _ (EIndex e i _) =
  Cat
    (printExpr precPostfix e)
    (Cat (text "[") (Cat (printExpr precTop i) (text "]")))
printExprRaw _ (EMatch sc arms) = printMatch sc arms
printExprRaw _ (EGuards arms) = printGuardArms arms
printExprRaw _ (ESection (SecBare op)) =
  Cat (text "(") (Cat (text op) (text ")"))
printExprRaw _ (ESection (SecRight op e)) =
  Cat
    (text "(")
    (Cat (text op) (Cat (text " ") (Cat (printExpr precTop e) (text ")"))))
printExprRaw _ (ESection (SecLeft e op)) =
  Cat
    (text "(")
    (Cat (printExpr precTop e) (Cat (text " ") (Cat (text op) (text " _)"))))
printExprRaw _ (EAsPat x e) =
  Cat (text x) (Cat (text "@") (printExpr precAtom e))
printExprRaw _ (EBlock stmts) = printBlock stmts
printExprRaw _ (EDo d stmts) = Cat (text (doKeyword d)) (printBlock stmts)
printExprRaw _ (EAnnot e t) =
  Cat (printExpr precTop e) (Cat (text " : ") (printType t))
printExprRaw _ (EHeadAnnot e _) = printExpr precTop e
printExprRaw _ (EInfix op l r) =
  Cat
    (printExpr (precInfix + 1) l)
    (Cat
      (text " `")
      (Cat (text op) (Cat (text "` ") (printExpr (precInfix + 1) r))))
printExprRaw _ (EStringInterp parts) =
  Cat (text "\"") (Cat (concatD (map interpPartDoc parts)) (text "\""))
printExprRaw _ (ERangeList lo hi incl) =
  Cat
    (text "[")
    (Cat
      (printExpr precTop lo)
      (Cat
        (text (if incl then "..=" else ".."))
        (Cat (printExpr precTop hi) (text "]"))))
printExprRaw _ (ERangeArray lo hi incl) =
  Cat
    (text "[|")
    (Cat
      (printExpr precTop lo)
      (Cat
        (text (if incl then "..=" else ".."))
        (Cat (printExpr precTop hi) (text "|]"))))
printExprRaw _ (ESlice e lo hi incl _) =
  Cat
    (printExpr precPostfix e)
    (Cat
      (text ".[")
      (Cat
        (printExpr precTop lo)
        (Cat
          (text (if incl then "..=" else ".."))
          (Cat (printExpr precTop hi) (text "]")))))
-- typed-pipeline-only nodes: print the name / inner transparently.
printExprRaw _ (EVarAt n _) = text n
printExprRaw _ (EMethodAt n _ _ _) = text n
printExprRaw _ (EDictAt n _) = text n
-- ELoc is transparent: print the wrapped expr, remembering the span.
printExprRaw _ (ELoc l e) = printExprRaw (Some l) e

fieldAssignPiece : FieldAssign -> Piece
fieldAssignPiece (FieldAssign k v) = match exprSpan v
  (s, sc, en, ec) => match unitStartAt 4 s sc
    (s2, sc2) => Piece s2 sc2 en ec (_ => Cat (text k) (sepBody " =" v))

mapKvPiece : (Expr, Expr) -> Piece
mapKvPiece (k, v) = match kvSpan (k, v)
  (s, sc, en, ec) => Piece s sc en ec (_ => mapKvDoc k v)

mapKvDoc : Expr -> Expr -> Doc
mapKvDoc k v =
  let kD = noClaimDoc (_ => printExpr precTop k)
  Cat kD (Cat (text " => ") (printExpr precTop v))

-- An interpolated expression never breaks: a string literal is one line.
interpPartDoc : InterpPart -> Doc
interpPartDoc (InterpStr s) = text (stringEscaped s)
interpPartDoc (InterpExpr e) =
  Cat (text "\\{") (Cat (text (renderFlat (printExpr precTop e))) (text "}"))

-- OCaml `String.escaped`: backslash, quote, \n \t \r (printable passthrough).
stringEscaped : String -> String
stringEscaped s = stringConcat (escEChars (stringToChars s) 0)

escEChars : Array Char -> Int -> List String
escEChars cs i
  | i >= arrayLength cs = []
  | otherwise = escSOne (arrayGetUnsafe i cs) :: escEChars cs (i + 1)

-- ── Separator + body ──────────────────────────────

-- The RHS after a separator (` =`, ` =>`, ` :=`): the one cascade described
-- at the top of this file.
sepBody : String -> Expr -> Doc
sepBody sep body
  | isGuardsBody body = printExprBody body
  | isBareBlock body = Cat (text sep) (printExprBody body)
  | isKeywordBlock body = Cat (text (sep ++ " ")) (printExprBody body)
  | otherwise =
    let s = spanStart (exprSpan body)
    let leading = if s > 0 then popBefore s else []
    if isNonEmptyL leading then
      Cat
        (text sep)
        (Nest
          2
          (Cat
            Hardline
            (Cat
              (leadingCommentsDoc leading s)
              (soloDoc body (_ => printExprBody body)))))
    else if isDelimitedBody body || appHugsLast body then
      Hang sep (soloDoc body (_ => printExprBody body))
    else
      Cat
        (text sep)
        (group (nest (Cat Line (soloDoc body (_ => printExprBody body)))))

-- An expression in body/statement position (the same doc `printExpr` builds;
-- kept as its own name for the call sites that read as "the body").
printExprBody : Expr -> Doc
printExprBody e = printExpr precTop e

-- ── Blocks ────────────────────────────────────────

stmtPiece : DoStmt -> Piece
stmtPiece st = match stmtSpan st
  (s, sc, en, ec) => match unitStartAt 1 s sc
    (s2, sc2) => Piece s2 sc2 en ec (_ => printDoStmt st)

printBlock : List DoStmt -> Doc
printBlock stmts = indentBlock (joinHard (pieceDocsHard (map stmtPiece stmts)))

printDoStmt : DoStmt -> Doc
printDoStmt (DoBind pat e) =
  Cat (printPat pat) (Cat (text " <- ") (printExprBody e))
printDoStmt (DoExpr e) = printExprBody e
printDoStmt (DoLet isMut _ pat e) =
  Cat
    (text "let ")
    (Cat
      (if isMut then text "mut " else Nil)
      (Cat (printPat pat) (sepBody " =" e)))
printDoStmt (DoAssign x e) = Cat (text x) (sepBody " =" e)
printDoStmt (DoFieldAssign x fields e) =
  Cat
    (text x)
    (Cat (text ".") (Cat (text (joinWith "." fields)) (sepBody " =" e)))

-- ── let … in ──────────────────────────────────────

-- `let [f args] = rhs in body`: one line when it fits, else the body drops one
-- step below the line-final `in`.
printELet : Bool -> Pat -> Expr -> Expr -> Doc
printELet True (PVar f _) rhs e2 = match unwrapLams [] rhs
  (args, body) =>
    let headD =
      Cat
        (text "let ")
        (Cat
          (text f)
          (concatD (map (p => Cat (text " ") (printPatAtom p)) args)))
    letInDoc headD body e2
printELet _ pat e1 e2 = letInDoc (Cat (text "let ") (printPat pat)) e1 e2

letInDoc : Doc -> Expr -> Expr -> Doc
letInDoc headD rhs e2 =
  let rhsD = noClaimDoc (_ => printExprBody rhs)
  let bodyD = soloDoc e2 (_ => printExprBody e2)
  group
    (Cat
      headD
      (Cat (text " = ") (Cat rhsD (Cat (text " in") (nest (Cat Line bodyD))))))

unwrapLams : List Pat -> Expr -> (List Pat, Expr)
unwrapLams acc (ELoc _ e) = unwrapLams acc e
unwrapLams acc (ELam pats body) = unwrapLams (acc ++ pats) body
unwrapLams acc body = (acc, body)

-- Expression-position `let rec f args = rhs in body` (one binding).  A group
-- with several bindings cannot be spelled in expression position; it prints as
-- nested `let rec … in` forms.
letRecInDoc : List LetBind -> Expr -> Doc
letRecInDoc [] body = printExprBody body
letRecInDoc ((LetBind name clauses) :: rest) body =
  let inner = letRecInDoc rest body
  match clauses
    [FunClause pats rhs] =>
      let headD =
        Cat
          (text "let rec ")
          (Cat
            (text name)
            (concatD (map (p => Cat (text " ") (printPatAtom p)) pats)))
      let rhsD = withBound (spanStart (exprSpan body)) (_ => printExprBody rhs)
      group
        (Cat
          headD
          (Cat
            (text " = ")
            (Cat rhsD (Cat (text " in") (nest (Cat Line inner))))))
    _ => inner

-- ── if / then / else ──────────────────────────────

-- `if c then t else e`: one line when it fits; else `then`/`else` on their
-- own lines with the branches one step below; an `if` in else position
-- ladders as `else if`.  Block branches (`then do`, `else match`) always break.
printIf : Expr -> Expr -> Expr -> Doc
printIf c t els = group (ifLadder c t els)

ifLadder : Expr -> Expr -> Expr -> Doc
ifLadder c t els =
  let condD = noClaimDoc (_ => printExpr precTop c)
  let thenD = withBound (spanStart (exprSpan els)) (_ => ifBranch "then" t)
  let elseD = ifElsePart els
  Cat (text "if ") (Cat condD (Cat (text " ") (Cat thenD elseD)))

ifElsePart : Expr -> Doc
ifElsePart els
  | isUnitLit els = Nil
  | otherwise = match stripLocE els
    EIf c2 t2 e2 => Cat Line (Cat (text "else ") (ifLadder c2 t2 e2))
    _ => Cat Line (ifBranch "else" els)

-- `kw` + its branch: a `do`/`match` keeps its keyword adjacent; a bare block
-- indents under the keyword; anything else hangs one step below when broken.
ifBranch : String -> Expr -> Doc
ifBranch kw b
  | isBareBlock b = Cat (text kw) (printExprBody b)
  | isKeywordBlock b = Cat (text kw) (Cat (text " ") (printExprBody b))
  | otherwise =
    Cat (text kw) (nest (Cat Line (soloDoc b (_ => printExprBody b))))

-- ── match ─────────────────────────────────────────

printMatch : Expr -> List Arm -> Doc
printMatch sc arms =
  let scD = noClaimDoc (_ => matchScrutineeDoc sc)
  Cat (text "match ") (Cat scD (printMatchArms arms))

-- A scrutinee wraps only INSIDE brackets: the lexer reads a deeper line after a
-- bare `match …` header as the arms block.  An atom (already bracketed) prints
-- normally; anything else prints flat when that fits the line, else
-- parenthesized so it may break inside.
matchScrutineeDoc : Expr -> Doc
matchScrutineeDoc sc =
  let d = printExpr precTop sc
  if exprPrec sc >= precAtom then
    d
  else match exprSpan sc
    (s, sc, en, ec) =>
      if s > 0 && pendingInside s sc en ec then
        Cat (text "(") (Cat d (text ")"))
      else
        Alt (text (renderFlat d)) (Cat (text "(") (Cat d (text ")")))

-- An arm's start is its pattern's position, which a bare constructor pattern
-- (`None =>`) does not carry — the parser records every arm's start position
-- (`setArmStarts`), and the latest recorded start at or before the arm's first
-- located token is the arm's own.
armPiece : Arm -> Piece
armPiece arm = match armSpan arm
  (s, sc, en, ec) => match unitStartAt 0 s sc
    (s2, sc2) => Piece s2 sc2 en ec (_ => matchArmDoc arm)

-- A unit's start is its first token, which the AST does not always carry (a
-- bare constructor pattern `None =>`, a `let` keyword, a method name) — the
-- parser records the start position of every arm, statement, method and
-- where-clause (`setUnitStarts`, tagged by kind: 0 arm, 1 statement, 2 impl
-- method, 3 where-clause), and the latest recorded start OF THAT KIND at or
-- before a unit's first located token is the unit's own.
-- Sorted by (kind, line, col) so each unit's lookup is a binary search; a
-- scan per unit made a file with N units cost N^2, in `fmt` and in every
-- `declToString` call lint makes after a parse.
unitStartsRef : Ref (Array (Int, Int, Int))
unitStartsRef = Ref (arrayFromList [])

export
setUnitStarts : List (Int, Int, Int) -> Unit
setUnitStarts ps = unitStartsRef := arrayFromList (sortBy cmpUnit ps)

cmpUnit : (Int, Int, Int) -> (Int, Int, Int) -> Ordering
cmpUnit (k1, l1, c1) (k2, l2, c2) =
  if k1 /= k2 then compare k1 k2 else cmpPos (l1, c1) (l2, c2)

-- number of entries at or before (kind, line, col)
unitUpperBound : Array (Int, Int, Int) -> Int -> Int -> Int -> Int -> Int -> Int
unitUpperBound arr kind line col lo hi =
  if lo >= hi then
    lo
  else
    let mid = (lo + hi) / 2
    match arr[mid]
      (k, l, c) =>
        let le = k < kind || k == kind && (l < line || l == line && c <= col)
        if le then
          unitUpperBound arr kind line col (mid + 1) hi
        else
          unitUpperBound arr kind line col lo mid

-- the latest recorded unit start of `kind` at or before (line, col); (line,
-- col) itself when none is recorded (or the unit carries no location at all)
unitStartAt : Int -> Int -> Int -> (Int, Int)
unitStartAt kind line col =
  if line == 0 then
    (0, 0)
  else
    let arr = !unitStartsRef
    let i = unitUpperBound arr kind line col 0 (arrayLength arr)
    if i == 0 then
      (line, col)
    else match arr[i - 1]
      (k, l, c) => if k == kind then (l, c) else (line, col)

printMatchArms : List Arm -> Doc
printMatchArms arms = indentBlock (joinHard (pieceDocsHard (map armPiece arms)))

matchArmDoc : Arm -> Doc
matchArmDoc (Arm pat guards body) =
  let guardsD = noClaimDoc (_ => matchGuardsDoc guards)
  Cat (printPatArm pat) (Cat guardsD (sepBody " =>" body))

matchGuardsDoc : List Guard -> Doc
matchGuardsDoc [] = Nil
matchGuardsDoc guards =
  Cat (text " if ") (sepBy (text ", ") (map guardDoc guards))

guardDoc : Guard -> Doc
guardDoc (GBool g) = printExpr precTop g
guardDoc (GBind gp g) =
  Cat (printPat gp) (Cat (text " <- ") (printExpr precTop g))

-- Function/where guard arms: indented block of `| guards = body`.
guardArmPiece : GuardArm -> Piece
guardArmPiece arm = match guardArmSpan arm
  (s, sc, en, ec) => Piece s sc en ec (_ => guardArmDoc arm)

printGuardArms : List GuardArm -> Doc
printGuardArms arms =
  indentBlock (joinHard (pieceDocsHard (map guardArmPiece arms)))

guardArmDoc : GuardArm -> Doc
guardArmDoc (GuardArm guards body) =
  let hd =
    noClaimDoc (_ => Cat (text "| ") (sepBy (text ", ") (map guardDoc guards)))
  Cat hd (sepBody " =" body)

-- ── Binary operators ──────────────────────────────

-- Every binary operator is spaced.  A chain of operators at one precedence
-- level is one group: `a op b op c` flat, else one operand per line with the
-- operator LEADING.  Tighter-binding sub-chains are their own groups.
printBinOp : Expr -> Doc
printBinOp e =
  let op = topOp e
  let prec = binopPrec op
  if op == ":=" then match stripLocE e
    EBinOp _ l r _ => Cat (printExpr (precAssign + 1) l) (sepBody " :=" r)
    _ => Nil
  else
    -- A same-level operand is parenthesized on the side the operator does not
    -- associate to; the collected spine never holds one on the other side.

    let ra = isRightAssoc op
    let headPrec = if ra then prec + 1 else prec
    let rightPrec = prec + 1
    match collectChain prec [] e
      (head, rights) =>
        let headPiece = match exprSpan head
          (s, sc, en, ec) => Piece s sc en ec (_ => printOperand headPrec head)
        let ps = headPiece :: map (r => rightPiece rightPrec r) rights
        let outs = pieceDocs noSep ps
        group (nest (joinLine outs))

topOp : Expr -> String
topOp e = match stripLocE e
  EBinOp op _ _ _ => op
  _ => ""

rightPiece : Int -> (String, Expr) -> Piece
rightPiece rightPrec (o, r) = match exprSpan r
  (s, sc, en, ec) => Piece s sc en ec (_ =>
    Cat (text o) (Cat (text " ") (printOperand rightPrec r)))

-- An operand of a chain: its own precedence-correct doc; an application or a
-- lambda breaks inside itself.
printOperand : Int -> Expr -> Doc
printOperand prec e = printExpr prec e

-- Flatten the same-precedence spine into (head, [(op, right)]).  A
-- left-associative operator collects down its LEFT spine; the right-associative
-- `::` collects down its RIGHT spine.  A parenthesized sub-chain (an `ELoc`
-- atom) at the same level flattens in — the parse is the same either way.
collectChain : Int -> List (String, Expr) -> Expr -> (Expr, List (String, Expr))
collectChain prec acc (ELoc l e) = match stripLocE e
  EBinOp op _ _ _ =>
    if binopPrec op == prec then collectChain prec acc e else (ELoc l e, acc)
  _ => (ELoc l e, acc)
collectChain prec acc (EBinOp op l r rf)
  | binopPrec op /= prec = (EBinOp op l r rf, acc)
  | isRightAssoc op = (l, rightSpine prec op r)
  | otherwise = collectChain prec ((op, r) :: acc) l
collectChain _ acc head = (head, acc)

-- The operands of a right-associative spine after its head, each paired with
-- the operator that precedes it: `a :: (b :: c)` → [(::, b), (::, c)].
rightSpine : Int -> String -> Expr -> List (String, Expr)
rightSpine prec opBefore e = match stripLocE e
  EBinOp op l2 r2 _ =>
    if binopPrec op == prec && isRightAssoc op then
      (opBefore, l2) :: rightSpine prec op r2
    else
      [(opBefore, e)]
  _ => [(opBefore, e)]

-- ── Application ───────────────────────────────────

-- `head arg … arg`: one line when it fits; else, when the last argument is
-- self-indenting (a lambda, a block, a literal), hug it — `head a (x =>` and
-- break inside; else one argument per line, one step in.
printAppSpine : Expr -> Doc
printAppSpine e = match collectApp [] e
  (head, []) => printExpr precApp head
  (head, args) =>
    let headD = printExpr precApp head
    let ps = map (a => argPiece head a) args
    if appHugsLast e && not (anyCommented ps) then
      let initOuts = pieceDocs noSep (map (a => argPiece head a) (initOf args))
      let initDocs = map pieceOutDoc initOuts
      match last args
        Some lastArg => match lastArgDocs head lastArg
          (openD, closedD) =>
            let explode =
              group
                (Nest
                  2
                  (Cat
                    headD
                    (concatD (map (d => Cat Line d) (initDocs ++ [closedD])))))
            let hug =
              Cat
                headD
                (Cat
                  (concatD (map (d => Cat (text " ") d) initDocs))
                  (Cat (text " ") openD))
            group (Alt hug explode)
        None => headD
    else
      let outs = pieceDocs noSep ps
      group
        (Nest
          2
          (Cat headD (concatD (map (o => Cat Line (pieceOutDoc o)) outs))))

-- The last argument of a hugging application, as (open, closed): the open
-- form renders broken (`(x =>` with the body below, `[` with the elements
-- below); the closed form is the ordinary one-line-when-it-fits doc.  Both
-- share one body doc, so comments inside it are placed exactly once.
lastArgDocs : Expr -> Expr -> (Doc, Doc)
lastArgDocs head arg = match stripLocE arg
  ELam pats body =>
    let patsD = sepBy (text " ") (map printPatAtom pats)
    let bodyPart = sepBody " =>" body
    let openD = Cat (text "(") (Cat patsD (Cat (openBody bodyPart) (text ")")))
    let closedD = Cat (text "(") (Cat patsD (Cat bodyPart (text ")")))
    (openD, closedD)

  _ =>
    let d = appArgDoc head arg
    (openDoc d, d)

-- A separator+body doc with its width group removed, so the body always
-- drops below the separator.
openBody : Doc -> Doc
openBody (Cat s (Group g)) = Cat s g
openBody (Hang sep d) = hangInline sep d
openBody d = d

-- A doc with its outermost width group removed (through one layer of parens).
openDoc : Doc -> Doc
openDoc (Group d) = d
openDoc (Cat (Text "(") (Cat (Group d) (Text ")"))) =
  Cat (text "(") (Cat d (text ")"))
openDoc (Cat (Text "(") (Cat d (Text ")"))) = Cat (text "(") (Cat d (text ")"))
openDoc d = d

argPiece : Expr -> Expr -> Piece
argPiece head arg = match exprSpan arg
  (s, sc, en, ec) => Piece s sc en ec (_ => appArgDoc head arg)

-- An application argument: atom-parenthesized by precedence, EXCEPT a tight
-- negative literal (`f -1`) under a non-numeric head and a Ref deref (`f !r`),
-- which the parser reads as arguments in their own right and which must print
-- bare to round-trip to the same node.
appArgDoc : Expr -> Expr -> Doc
appArgDoc head x =
  if isTightNegLitArg x && not (headIsNumericHead (stripLocE head)) then
    printExprRaw None (stripLocE x)
  else if isTightDerefArg x then
    printExprRaw None (stripLocE x)
  else
    printExpr precPostfix x

isTightDerefArg : Expr -> Bool
isTightDerefArg e = match stripLocE e
  EUnOp "!" _ _ => True
  _ => False

isTightNegLitArg : Expr -> Bool
isTightNegLitArg e = match stripLocE e
  ELit l => isNegLit l
  ENumLit n _ _ _ => n < 0
  _ => False

headIsNumericHead : Expr -> Bool
headIsNumericHead (ENumLit _ _ _ _) = True
headIsNumericHead (ELit (LInt _)) = True
headIsNumericHead (ELit (LFloat _)) = True
headIsNumericHead _ = False

collectApp : List Expr -> Expr -> (Expr, List Expr)
collectApp acc (EApp f x) = collectApp (x :: acc) f
collectApp acc (ELoc l e) = match stripLocE e
  EApp f x => collectApp acc (EApp f x)
  _ => (ELoc l e, acc)
collectApp acc head = (head, acc)

-- ── Declarations ──────────────────────────────────

-- The RHS of `<header> = <body>`.
printDefRhs : Expr -> Doc
printDefRhs body = match stripLocE body
  EGuards arms => printGuardArms arms
  ELetGroup binds inner => printWhere binds inner
  _ => sepBody " =" body

-- `body` + an indented `where` block (decl-body position only).
printWhere : List LetBind -> Expr -> Doc
printWhere binds inner =
  let bodyD =
    if isGuardsBody inner then
      printGuardArms (guardArmsOf inner)
    else
      sepBody " =" inner
  Cat
    bodyD
    (Nest
      2
      (Cat Hardline (Cat (text "where") (Nest 2 (letGroupClauses binds)))))

guardArmsOf : Expr -> List GuardArm
guardArmsOf e = match stripLocE e
  EGuards arms => arms
  _ => []

-- The clauses of a `where` block, one per line (comments and blank lines
-- between them preserved).
letGroupClauses : List LetBind -> Doc
letGroupClauses bindings =
  Cat Hardline (joinHard (pieceDocsHard (clausePieces bindings)))

clausePieces : List LetBind -> List Piece
clausePieces [] = []
clausePieces ((LetBind name clauses) :: rest) =
  map (c => clausePiece name c) clauses ++ clausePieces rest

clausePiece : String -> FunClause -> Piece
clausePiece name (FunClause pats rhs) = match clauseSpan (FunClause pats rhs)
  (s, sc, en, ec) => match unitStartAt 3 s sc
    (s2, sc2) =>
      Piece s2 sc2 en ec (_ => Cat (defHeader name pats) (printDefRhs rhs))

printUsePath : UsePath -> Bool -> Doc
printUsePath (UseName names) _ = text (joinWith "." names)
printUsePath (UseGroup names members) forced =
  let items = map useMemberDoc members
  let body =
    if forced then
      delimitedPieces "{" "}" True (map (d => Piece 0 0 0 0 (_ => d)) items)
    else
      filledDocs "{" "}" items
  Cat (text (joinWith "." names)) (Cat (text ".") body)
printUsePath (UseWild names) _ = Cat (text (joinWith "." names)) (text ".*")
printUsePath (UseAlias names alias) _ =
  Cat (text (joinWith "." names)) (Cat (text " as ") (text alias))

useMemberDoc : UseMember -> Doc
useMemberDoc (UseMember n allCtors _ alias) =
  let base = if allCtors then Cat (text n) (text "(..)") else text n
  match alias
    Some a => Cat base (text " as \{a}")
    None => base

-- ── data ──────────────────────────────────────────

-- A single `data` variant (without the leading `| `).  A named-field payload
-- is `Name { f : T, g : U }` on one line, else brace-on-name-line with one
-- field per line and a trailing comma:
--   Name {
--     f : T,
--     g : U,
--   }
printVariant : Variant -> Doc
printVariant (Variant name (ConPos tys)) =
  Cat (text name) (concatD (map (t => Cat (text " ") (printTypeAtom t)) tys))
printVariant (Variant name (ConNamed fields nameOmitted)) =
  recordVariantDoc name fields nameOmitted []

-- `Name { … }` with an optional deriving clause that stays inline when the
-- record fits one line and drops to its own indented line when it breaks.
recordVariantDoc : String -> List Field -> Bool -> List DeriveRef -> Doc
recordVariantDoc name fields nameOmitted derives =
  let namePart = if nameOmitted then text "{" else Cat (text name) (text " {")
  let sep = Cat (text ",") Line
  let derivesTail =
    if isEmptyL derives then
      Nil
    else
      FlatAlt
        (nest (Cat Line (printDerives derives)))
        (Cat (text " ") (printDerives derives))
  group
    (Cat
      namePart
      (Cat
        (nest
          (Cat Line (Cat (sepBy sep (map fieldTyDoc fields)) trailingCommaDoc)))
        (Cat Line (Cat (text "}") derivesTail))))

fieldTyDoc : Field -> Doc
fieldTyDoc (Field fn ft) = Cat (text fn) (Cat (text " : ") (printType ft))

-- A single-variant record-style data decl rendered ONE FIELD PER LINE:
--   data X = X {
--     f0 : T0,
--     f1 : T1,
--   }
-- Header on line 0, field i on line i+1, `}` last — output lines align 1:1
-- with the source field lines, so `medaka fmt` can re-attach each field's
-- trailing comment by line index.  Falls back to `printDecl` for any other shape.
export
printNamedFieldData : DataVis ->
  String ->
  List String ->
  List (Option KindAnn) ->
  List Variant ->
  List DeriveRef ->
  Doc
printNamedFieldData vis n params kinds [Variant cname (ConNamed fields nameOmitted)] derives =
  let eqPart =
    if nameOmitted then
      text " = {"
    else
      Cat (text " = ") (Cat (text cname) (text " {"))
  let head =
    Cat (text "data ") (Cat (text n) (Cat (tyParamsDoc params kinds) eqPart))
  let body =
    Cat
      (Nest
        2
        (concatD
          (map (f => Cat Hardline (Cat (fieldTyDoc f) (text ","))) fields)))
      (Cat Hardline (text "}"))
  let deriveDoc =
    if isEmptyL derives then Nil else indentBlock (printDerives derives)
  Cat (visPrefix vis) (Cat head (Cat body deriveDoc))
printNamedFieldData vis n params kinds variants derives =
  printDecl (dDataUnresolved vis n params kinds variants derives)

tyParamsDoc : List String -> List (Option KindAnn) -> Doc
tyParamsDoc params kinds =
  concatD (map (w => Cat (text " ") (text w)) (tyParamSources params kinds))

printDerives : List DeriveRef -> Doc
printDerives [] = Nil
printDerives derives =
  Cat
    (text "deriving (")
    (Cat (text (joinWith ", " (map deriveRefName derives))) (text ")"))

visPrefix : DataVis -> Doc
visPrefix VisPublic = text "public export "
visPrefix VisAbstract = text "export "
visPrefix VisPrivate = Nil

-- A `data` body.  Flat: `= V1 | V2 | …`.  Broken: a line-final `=`, then one
-- `| Vn` per variant (the first too), and `deriving` on its own line:
--   data Foo =
--     | Bar
--     | Baz
--     deriving (Eq)
-- A single record variant never gets a bar; it breaks inside its braces:
--   data Cfg = Cfg {
--     name : String,
--   }
--     deriving (Eq)
dataBodyDoc : List Variant -> List DeriveRef -> Doc
dataBodyDoc [] derives = derivesInline derives
dataBodyDoc [Variant name (ConNamed fields nameOmitted)] derives =
  Cat (text " = ") (recordVariantDoc name fields nameOmitted derives)
dataBodyDoc (v :: vs) derives =
  group
    (Cat
      (text " =")
      (nest
        (Cat
          (Cat (FlatAlt (Cat Line (text "| ")) (text " ")) (printVariant v))
          (Cat
            (concatD
              (map
                (v2 =>
                  Cat
                    (FlatAlt (Cat Line (text "| ")) (text " | "))
                    (printVariant v2))
                vs))
            (derivesLineOrInline derives)))))

derivesInline : List DeriveRef -> Doc
derivesInline [] = Nil
derivesInline derives = Cat (text " ") (printDerives derives)

-- inside a group: inline when flat, own line when broken
derivesLineOrInline : List DeriveRef -> Doc
derivesLineOrInline [] = Nil
derivesLineOrInline derives = Cat Line (printDerives derives)

-- Render a `data` declaration with interior comments interleaved.
-- `vcomments` is parallel to `variants`: entry i = (leading, trailing) lexemes
-- for variant i.  Any non-empty entry forces one-variant-per-line.
export
printDataDeclCommented : DataVis ->
  String ->
  List String ->
  List (Option KindAnn) ->
  List Variant ->
  List DeriveRef ->
  List (List String, List String) ->
  Doc
printDataDeclCommented vis n params kinds variants derives vcomments =
  let head = Cat (text "data ") (Cat (text n) (tyParamsDoc params kinds))
  let variantDocs = dataVariantDocsCommented variants vcomments
  let deriveDoc =
    if isEmptyL derives then Nil else indentBlock (printDerives derives)
  Cat (visPrefix vis) (Cat head (Cat variantDocs deriveDoc))

commentLinesDoc : List String -> Doc
commentLinesDoc cs = concatD (map (c => Cat Hardline (text c)) cs)

trailingCommentsDoc : List String -> Doc
trailingCommentsDoc cs = concatD (map (c => Cat (text "  ") (text c)) cs)

variantCommentedDoc : Variant -> (List String, List String) -> Doc
variantCommentedDoc v (leading, trailing) =
  Cat
    (commentLinesDoc leading)
    (Cat
      Hardline
      (Cat (text "| ") (Cat (printVariant v) (trailingCommentsDoc trailing))))

dataVariantDocsCommented : List Variant ->
  List (List String, List String) ->
  Doc
dataVariantDocsCommented [] _ = Nil
dataVariantDocsCommented _ [] = Nil
dataVariantDocsCommented (v :: vs) (vc :: vcs) =
  Cat
    (text " =")
    (nest
      (Cat (variantCommentedDoc v vc) (concatD (map2VariantComment vs vcs))))

map2VariantComment : List Variant -> List (List String, List String) -> List Doc
map2VariantComment [] _ = []
map2VariantComment _ [] = []
map2VariantComment (v :: vs) (vc :: vcs) =
  variantCommentedDoc v vc :: map2VariantComment vs vcs

-- `export` above a VALUE-level declaration (a type signature or an extern
-- declaration) sits on its own line, never collapsed onto the signature
-- (STYLE.md §10) — unlike `export data`/`export impl`, which stay collapsed.
valueExportPrefix : Bool -> Doc
valueExportPrefix pub = if pub then Cat (text "export") Hardline else Nil

-- `name args` of a function definition / method clause
defHeader : String -> List Pat -> Doc
defHeader n pats =
  Cat (text n) (concatD (map (p => Cat (text " ") (printPatAtom p)) pats))

-- Trailing-comma pin for an import member list: a recorded trailing comma on
-- one of the declaration's own lines (set by `medaka fmt` per declaration).
importForcedRef : Ref Bool
importForcedRef = Ref False

export
setImportForced : Bool -> Unit
setImportForced b = importForcedRef := b

export
printDecl : Decl -> Doc
printDecl (DTypeSig pub n t) =
  Cat (valueExportPrefix pub) (Cat (text n) (Cat (text " : ") (sigTypeDoc t)))
printDecl (DExtern pub n t) =
  Cat
    (valueExportPrefix pub)
    (Cat (text "extern ") (Cat (text n) (Cat (text " : ") (sigTypeDoc t))))
printDecl (DFunDef pub n pats body) =
  Cat
    (if pub then text "export " else Nil)
    (Cat (defHeader n pats) (printDefRhs body))
printDecl (DLetGroup pub bindings) =
  Cat (if pub then text "export " else Nil) (letGroupDecl bindings)
printDecl (DData { dataVis = vis, dataName = n, dataParams = params, dataParamKinds = kinds, dataCtors = variants, dataDerives = derives }) =
  let head = Cat (text "data ") (Cat (text n) (tyParamsDoc params kinds))
  Cat (visPrefix vis) (Cat head (dataBodyDoc variants derives))
printDecl (DTypeAlias { tyAliasPub = pub, tyAliasName = n, tyAliasParams = params, tyAliasParamKinds = kinds, tyAliasRhs = rhs }) =
  Cat
    (if pub then text "export " else Nil)
    (Cat
      (text "type ")
      (Cat
        (text n)
        (Cat (tyParamsDoc params kinds) (Cat (text " = ") (printType rhs)))))
printDecl (DNewtype { newtypePub = pub, newtypeName = n, newtypeParams = params, newtypeParamKinds = kinds, newtypeCtor = con, newtypeFieldTy = fty, newtypeDerives = derives }) =
  let head = Cat (text "newtype ") (Cat (text n) (tyParamsDoc params kinds))
  let body =
    Cat (text " = ") (Cat (text con) (Cat (text " ") (printTypeAtom fty)))
  Cat
    (if pub then text "export " else Nil)
    (Cat head (Cat body (group (nest (derivesLineOrInline derives)))))
printDecl (DInterface { pub, def, name, typarams, typaramKinds, supers, methods }) =
  Cat
    (if pub then text "export " else Nil)
    (Cat
      (if def then text "default " else Nil)
      (Cat
        (text "interface ")
        (Cat
          (text name)
          (Cat
            (tyParamsDoc typarams typaramKinds)
            (Cat (superDoc supers) (if isEmptyL methods then
              Nil
            else
              Cat
                (text " where")
                (methodsBlock (map ifaceMethodPiece methods))))))))
printDecl (DImpl { pub, iface, tys, reqs, methods }) =
  Cat
    (if pub then text "export " else Nil)
    (Cat
      (text "impl ")
      (Cat
        (implHead iface tys)
        (Cat (reqsDoc reqs) (if isEmptyL methods then
          Nil
        else
          Cat (text " where") (methodsBlock (map implMethodPiece methods))))))
printDecl (DUse pub path _) =
  Cat
    (if pub then text "export " else Nil)
    (Cat (text "import ") (printUsePath path !importForcedRef))
printDecl (DEffect pub name domain) =
  Cat (effDeclHead pub) (Cat (text name) (effDomainDoc domain))
printDecl (DProp pub propName propParams propBody) =
  Cat
    (if pub then text "export " else Nil)
    (Cat
      (text "prop ")
      (Cat
        (text (escStringLit propName))
        (Cat (concatD (map propParamDoc propParams)) (printDefRhs propBody))))
printDecl (DTest pub testName testBody) =
  Cat
    (if pub then text "export " else Nil)
    (Cat
      (text "test ")
      (Cat (text (escStringLit testName)) (printDefRhs testBody)))
printDecl (DBench pub benchName benchBody) =
  Cat
    (if pub then text "export " else Nil)
    (Cat
      (text "bench ")
      (Cat (text (escStringLit benchName)) (printDefRhs benchBody)))
printDecl (DAttrib attrs inner) =
  Cat (concatD (map attrDoc attrs)) (printDecl inner)

methodsBlock : List Piece -> Doc
methodsBlock ps = indentBlock (joinHard (pieceDocsHard ps))

-- prop param: ` (name : ppTy ty)`.
propParamDoc : PropParam -> Doc
propParamDoc (PropParam x _ ty) = text " (\{x} : \{ppTy ty})"

attrDoc : Attr -> Doc
attrDoc (AttrDeprecated msg) =
  Cat (text ("@deprecated " ++ escStringLit msg)) Hardline
attrDoc AttrInline = Cat (text "@inline") Hardline
attrDoc AttrMustUse = Cat (text "@must_use") Hardline

-- `let rec` for the first clause, `with` for the rest (across all bindings).
letGroupDecl : List LetBind -> Doc
letGroupDecl bindings =
  let docs = letGroupDeclGo True bindings
  concatD docs

letGroupDeclGo : Bool -> List LetBind -> List Doc
letGroupDeclGo _ [] = []
letGroupDeclGo first ((LetBind name clauses) :: rest) =
  let r = letGroupBindClauses first name clauses
  match r
    (docs, nextFirst) => docs ++ letGroupDeclGo nextFirst rest

letGroupBindClauses : Bool -> String -> List FunClause -> (List Doc, Bool)
letGroupBindClauses first _ [] = ([], first)
letGroupBindClauses first name (c :: cs) =
  let d = letGroupDeclClause first name c
  let r = letGroupBindClauses False name cs
  match r
    (rest, lastFirst) => (d :: rest, lastFirst)

letGroupDeclClause : Bool -> String -> FunClause -> Doc
letGroupDeclClause first name (FunClause pats body) =
  Cat
    (if first then text "let rec " else Cat Hardline (text "with "))
    (Cat (defHeader name pats) (printDefRhs body))

superDoc : List Super -> Doc
superDoc [] = Nil
superDoc supers =
  Cat (text " requires ") (sepBy (text ", ") (map oneSuper supers))

oneSuper : Super -> Doc
oneSuper (Super { superHead = n, superParams = ps }) =
  Cat (text n) (concatD (map (p => Cat (text " ") (text p)) ps))

ifaceMethodPiece : IfaceMethod -> Piece
ifaceMethodPiece (IfaceMethod n ty None l) = match l
  Some loc => match locSpan loc
    (s, sc, en, ec) =>
      Piece s sc en ec (_ => ifaceMethodDoc (IfaceMethod n ty None l))
  None => Piece 0 0 0 0 (_ => ifaceMethodDoc (IfaceMethod n ty None l))
ifaceMethodPiece (IfaceMethod n ty (Some (MethodDefault pats body)) l) =
  let sp = mergeSpan (spansOf patSpan pats) (exprSpan body)
  match sp
    (s, sc, en, ec) => Piece s sc en ec (_ =>
      ifaceMethodDoc (IfaceMethod n ty (Some (MethodDefault pats body)) l))

ifaceMethodDoc : IfaceMethod -> Doc
ifaceMethodDoc (IfaceMethod n ty None _) =
  Cat (text n) (Cat (text " : ") (sigTypeDoc ty))
ifaceMethodDoc (IfaceMethod n _ (Some (MethodDefault pats body)) _) =
  Cat (defHeader n pats) (printDefRhs body)

implHead : String -> List Ty -> Doc
implHead iface tys =
  Cat (text iface) (concatD (map (t => Cat (text " ") (printTypeAtom t)) tys))

reqsDoc : List Require -> Doc
reqsDoc [] = Nil
reqsDoc reqs = Cat (text " requires ") (sepBy (text ", ") (map oneReq reqs))

oneReq : Require -> Doc
oneReq (Require { requireHead = iface, requireArgs = args }) =
  Cat (text iface) (concatD (map (t => Cat (text " ") (printTypeAtom t)) args))

implMethodPiece : ImplMethod -> Piece
implMethodPiece (ImplMethod n pats body) = match (mergeSpan
  (spansOf patSpan pats)
  (exprSpan body))
  (s, sc, en, ec) => match unitStartAt 2 s sc
    (s2, sc2) =>
      Piece s2 sc2 en ec (_ => implMethodDoc (ImplMethod n pats body))

implMethodDoc : ImplMethod -> Doc
implMethodDoc (ImplMethod n pats body) =
  Cat (defHeader n pats) (printDefRhs body)

-- ── pp_ty (the precedence type printer used by prop params) ─────────
-- Distinct from printType: it parenthesizes by precedence level (0 top,
-- 1 fun-lhs, 2 app-arg).  Exported for `tools/lint.mdk`'s stdlib reference
-- index (this one keeps effect rows).
export
ppTy : Ty -> String
ppTy t = ppTyPrec 0 t

ppTyPrec : Int -> Ty -> String
ppTyPrec _ (TyCon { tyConName = s }) = tyConSurface s
ppTyPrec _ (TyVar s) = s
ppTyPrec _ (TyTuple ts) = "(" ++ joinWith ", " (map (ppTyPrec 0) ts) ++ ")"
ppTyPrec p (TyApp f x) =
  let s = "\{ppTyPrec 1 f} \{ppTyPrec 2 x}"
  if p >= 2 then "(" ++ s ++ ")" else s
ppTyPrec p (TyFun a b) =
  let s = "\{ppTyPrec 1 a} -> \{ppTyPrec 0 b}"
  if p >= 1 then "(" ++ s ++ ")" else s
ppTyPrec p (TyEffect effs tail t) =
  let inside = ppEffInside effs tail
  let s = "<\{inside}> \{ppTyPrec 0 t}"
  if p >= 1 then "(" ++ s ++ ")" else s
ppTyPrec _ (TyRow [] (a :: b :: rest) _) =
  "(\{joinWith " | " (a :: b :: rest)})"
ppTyPrec _ (TyRow effs tail _) = "<\{ppEffInside effs tail}>"
ppTyPrec _ (TyConstrained cs t) =
  let csStr = match cs
    [c] => ppConstr c
    _ => "(" ++ joinWith ", " (map ppConstr cs) ++ ")"
  "\{csStr} => \{ppTyPrec 0 t}"

ppEffInside : List (String, Option String) -> List String -> String
ppEffInside effs [] = joinWith ", " (map ppEffAtom effs)
ppEffInside [] tails = joinWith " | " tails
ppEffInside effs tails =
  "\{joinWith ", " (map ppEffAtom effs)} | \{joinWith " | " tails}"

ppEffAtom : (String, Option String) -> String
ppEffAtom (l, None) = l
ppEffAtom (l, Some s) = "\{l} \{escStringLit s}"

effDomainDoc : Option String -> Doc
effDomainDoc None = Nil
effDomainDoc (Some d) = Cat (text " ") (text d)

effDeclHead : Bool -> Doc
effDeclHead True = text "export effect "
effDeclHead False = text "effect "

ppConstr : Constraint -> String
ppConstr (Constraint { constraintHead = iface, constraintArgs = args }) =
  if isEmptyL args then
    iface
  else
    "\{iface} \{joinWith " " (map (ppTyPrec 2) args)}"

-- ── Public entry points ───────────────────────────

export
exprToString : Expr -> String
exprToString e = render (printExpr precTop e)

export
declToString : Decl -> String
declToString d = render (printDecl d)

-- each decl rendered + a trailing newline, concatenated.
export
programToString : List Decl -> String
programToString decls = stringConcat (map declLine decls)

declLine : Decl -> String
declLine d = render (printDecl d) ++ "\n"
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "DeriveRef" true) (mem "deriveRefName" false) (mem "dDataUnresolved" false) (mem "KindAnn" true) (mem "tyParamSources" false) (mem "Loc" true) (mem "Lit" true) (mem "Ty" true) (mem "Constraint" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "UseMember" true) (mem "UsePath" true) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true) (mem "Attr" true))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "listLen" false) (mem "allList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "escOneHex2" false))))
(DUse false (UseGroup ("list") ((mem "last" false) (mem "sortBy" false))))
(DData Public "Doc" () ((variant "Nil" (ConPos)) (variant "Text" (ConPos (TyCon "String"))) (variant "Cat" (ConPos (TyCon "Doc") (TyCon "Doc"))) (variant "Line" (ConPos)) (variant "Softline" (ConPos)) (variant "Hardline" (ConPos)) (variant "BlankLine" (ConPos)) (variant "Nest" (ConPos (TyCon "Int") (TyCon "Doc"))) (variant "Group" (ConPos (TyCon "Doc"))) (variant "FlatAlt" (ConPos (TyCon "Doc") (TyCon "Doc"))) (variant "Alt" (ConPos (TyCon "Doc") (TyCon "Doc"))) (variant "Hang" (ConPos (TyCon "String") (TyCon "Doc"))) (variant "LineComment" (ConPos (TyCon "String"))) (variant "Fill" (ConPos (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Doc"))))) ())
(DTypeSig false "text" (TyFun (TyCon "String") (TyCon "Doc")))
(DFunDef false "text" ((PVar "s")) (EApp (EVar "Text") (EVar "s")))
(DTypeSig false "group" (TyFun (TyCon "Doc") (TyCon "Doc")))
(DFunDef false "group" ((PVar "d")) (EApp (EVar "Group") (EVar "d")))
(DTypeSig false "trailingCommaDoc" (TyCon "Doc"))
(DFunDef false "trailingCommaDoc" () (EApp (EApp (EVar "FlatAlt") (EApp (EVar "text") (ELit (LString ",")))) (EVar "Nil")))
(DTypeSig false "nest" (TyFun (TyCon "Doc") (TyCon "Doc")))
(DFunDef false "nest" ((PVar "d")) (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EVar "d")))
(DTypeSig false "sepBy" (TyFun (TyCon "Doc") (TyFun (TyApp (TyCon "List") (TyCon "Doc")) (TyCon "Doc"))))
(DFunDef false "sepBy" (PWild (PList)) (EVar "Nil"))
(DFunDef false "sepBy" (PWild (PList (PVar "x"))) (EVar "x"))
(DFunDef false "sepBy" ((PVar "sep") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "Cat") (EVar "x")) (EApp (EApp (EVar "Cat") (EVar "sep")) (EApp (EApp (EVar "sepBy") (EVar "sep")) (EVar "xs")))))
(DTypeSig false "concatD" (TyFun (TyApp (TyCon "List") (TyCon "Doc")) (TyCon "Doc")))
(DFunDef false "concatD" ((PList)) (EVar "Nil"))
(DFunDef false "concatD" ((PCons (PVar "d") (PVar "ds"))) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "concatD") (EVar "ds"))))
(DTypeSig false "indentBlock" (TyFun (TyCon "Doc") (TyCon "Doc")))
(DFunDef false "indentBlock" ((PVar "d")) (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EVar "d"))))
(DData Public "Mode" () ((variant "Flat" (ConPos)) (variant "Break" (ConPos))) ())
(DData Public "Item" () ((variant "Item" (ConPos (TyCon "Int") (TyCon "Mode") (TyCon "Doc")))) ())
(DTypeSig false "defaultWidth" (TyCon "Int"))
(DFunDef false "defaultWidth" () (ELit (LInt 80)))
(DTypeSig false "fillFlatDoc" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Doc")) (TyCon "Doc"))))
(DFunDef false "fillFlatDoc" (PWild (PList)) (EVar "Nil"))
(DFunDef false "fillFlatDoc" ((PCon "False") (PVar "ds")) (EApp (EApp (EVar "sepBy") (EVar "Line")) (EVar "ds")))
(DFunDef false "fillFlatDoc" ((PCon "True") (PVar "ds")) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "sepBy") (EVar "Line")) (EVar "ds"))))
(DTypeSig false "hangInline" (TyFun (TyCon "String") (TyFun (TyCon "Doc") (TyCon "Doc"))))
(DFunDef false "hangInline" ((PVar "sep") (PVar "d")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "sep"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EVar "d"))))
(DTypeSig false "fits" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Item")) (TyCon "Bool"))))
(DFunDef false "fits" ((PVar "w") PWild) (EIf (EBinOp "<" (EVar "w") (ELit (LInt 0))) (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "fits" (PWild (PList)) (EVar "True"))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" PWild PWild (PCon "Nil")) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EVar "z")))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Cat" (PVar "a") (PVar "b"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "a")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "b")) (EVar "z")))))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Nest" (PVar "j") (PVar "d"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EBinOp "+" (EVar "i") (EVar "j"))) (EVar "m")) (EVar "d")) (EVar "z"))))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" PWild PWild (PCon "Text" (PVar "s"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EBinOp "-" (EVar "w") (EApp (EVar "stringLength") (EVar "s")))) (EVar "z")))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" PWild (PCon "Flat") (PCon "Line")) (PVar "z"))) (EApp (EApp (EVar "fits") (EBinOp "-" (EVar "w") (ELit (LInt 1)))) (EVar "z")))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" PWild (PCon "Flat") (PCon "Softline")) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EVar "z")))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Break") (PCon "Line")) PWild)) (EVar "True"))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Break") (PCon "Softline")) PWild)) (EVar "True"))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Break") (PCon "Hardline")) PWild)) (EVar "True"))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Flat") (PCon "Hardline")) PWild)) (EVar "False"))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Break") (PCon "BlankLine")) PWild)) (EVar "True"))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Flat") (PCon "BlankLine")) PWild)) (EVar "False"))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Group" (PVar "d"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "d")) (EVar "z"))))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "FlatAlt" PWild (PVar "b"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "b")) (EVar "z"))))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Alt" (PVar "a") PWild)) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "a")) (EVar "z"))))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Hang" (PVar "sep") (PVar "d"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EApp (EApp (EVar "hangInline") (EVar "sep")) (EVar "d"))) (EVar "z"))))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Flat") (PCon "LineComment" PWild)) (PVar "z"))) (EApp (EVar "restEndsLine") (EVar "z")))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Break") (PCon "LineComment" PWild)) PWild)) (EVar "True"))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Fill" (PVar "sf") (PVar "ds"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EApp (EApp (EVar "fillFlatDoc") (EVar "sf")) (EVar "ds"))) (EVar "z"))))
(DTypeSig false "restEndsLine" (TyFun (TyApp (TyCon "List") (TyCon "Item")) (TyCon "Bool")))
(DFunDef false "restEndsLine" ((PList)) (EVar "True"))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" PWild PWild (PCon "Nil")) (PVar "z"))) (EApp (EVar "restEndsLine") (EVar "z")))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Cat" (PVar "a") (PVar "b"))) (PVar "z"))) (EApp (EVar "restEndsLine") (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "a")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "b")) (EVar "z")))))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Nest" (PVar "j") (PVar "d"))) (PVar "z"))) (EApp (EVar "restEndsLine") (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EBinOp "+" (EVar "i") (EVar "j"))) (EVar "m")) (EVar "d")) (EVar "z"))))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" PWild PWild (PCon "Text" (PVar "s"))) (PVar "z"))) (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EApp (EVar "restEndsLine") (EVar "z")) (EVar "False")))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" PWild (PCon "Flat") (PCon "Line")) PWild)) (EVar "False"))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" PWild (PCon "Flat") (PCon "Softline")) (PVar "z"))) (EApp (EVar "restEndsLine") (EVar "z")))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" PWild (PCon "Break") (PCon "Line")) PWild)) (EVar "True"))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" PWild (PCon "Break") (PCon "Softline")) PWild)) (EVar "True"))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" PWild PWild (PCon "Hardline")) PWild)) (EVar "True"))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" PWild PWild (PCon "BlankLine")) PWild)) (EVar "True"))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Group" (PVar "d"))) (PVar "z"))) (EApp (EVar "restEndsLine") (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "d")) (EVar "z"))))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "FlatAlt" PWild (PVar "b"))) (PVar "z"))) (EApp (EVar "restEndsLine") (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "b")) (EVar "z"))))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Alt" (PVar "a") PWild)) (PVar "z"))) (EApp (EVar "restEndsLine") (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "a")) (EVar "z"))))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Hang" (PVar "sep") (PVar "d"))) (PVar "z"))) (EApp (EVar "restEndsLine") (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EApp (EApp (EVar "hangInline") (EVar "sep")) (EVar "d"))) (EVar "z"))))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" PWild PWild (PCon "LineComment" PWild)) PWild)) (EVar "False"))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Fill" (PVar "sf") (PVar "ds"))) (PVar "z"))) (EApp (EVar "restEndsLine") (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EApp (EApp (EVar "fillFlatDoc") (EVar "sf")) (EVar "ds"))) (EVar "z"))))
(DTypeSig false "spaces" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "spaces" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ELit (LString "")) (EIf (EVar "otherwise") (EBinOp "++" (ELit (LString " ")) (EApp (EVar "spaces") (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "newlineStr" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "newlineStr" ((PVar "i")) (EBinOp "++" (ELit (LString "\n")) (EApp (EVar "spaces") (EVar "i"))))
(DTypeSig false "itemBroken" (TyFun (TyCon "Item") (TyCon "Item")))
(DFunDef false "itemBroken" ((PCon "Item" (PVar "i") PWild (PVar "d"))) (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EVar "d")))
(DTypeSig false "go" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Item")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "go" (PWild (PList)) (EListLit))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" PWild PWild (PCon "Nil")) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EVar "z")))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Cat" (PVar "a") (PVar "b"))) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "a")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "b")) (EVar "z")))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Nest" (PVar "j") (PVar "d"))) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EBinOp "+" (EVar "i") (EVar "j"))) (EVar "m")) (EVar "d")) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" PWild PWild (PCon "Text" (PVar "s"))) (PVar "z"))) (EBinOp "::" (EVar "s") (EApp (EApp (EVar "go") (EBinOp "+" (EVar "col") (EApp (EVar "stringLength") (EVar "s")))) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" PWild (PCon "Flat") (PCon "Line")) (PVar "z"))) (EBinOp "::" (ELit (LString " ")) (EApp (EApp (EVar "go") (EBinOp "+" (EVar "col") (ELit (LInt 1)))) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" PWild (PCon "Flat") (PCon "Softline")) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EVar "z")))
(DFunDef false "go" (PWild (PCons (PCon "Item" (PVar "i") (PCon "Break") (PCon "Line")) (PVar "z"))) (EBinOp "::" (EApp (EVar "newlineStr") (EVar "i")) (EApp (EApp (EVar "go") (EVar "i")) (EVar "z"))))
(DFunDef false "go" (PWild (PCons (PCon "Item" (PVar "i") (PCon "Break") (PCon "Softline")) (PVar "z"))) (EBinOp "::" (EApp (EVar "newlineStr") (EVar "i")) (EApp (EApp (EVar "go") (EVar "i")) (EVar "z"))))
(DFunDef false "go" (PWild (PCons (PCon "Item" (PVar "i") PWild (PCon "Hardline")) (PVar "z"))) (EBinOp "::" (EApp (EVar "newlineStr") (EVar "i")) (EApp (EApp (EVar "go") (EVar "i")) (EVar "z"))))
(DFunDef false "go" (PWild (PCons (PCon "Item" PWild PWild (PCon "BlankLine")) (PVar "z"))) (EBinOp "::" (ELit (LString "\n")) (EApp (EApp (EVar "go") (ELit (LInt 0))) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") PWild (PCon "Group" (PVar "d"))) (PVar "z"))) (EBlock (DoLet false false (PVar "flat") (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "d")) (EVar "z"))) (DoExpr (EIf (EApp (EApp (EVar "fits") (EBinOp "-" (EVar "defaultWidth") (EVar "col"))) (EVar "flat")) (EApp (EApp (EVar "go") (EVar "col")) (EVar "flat")) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EVar "d")) (EVar "z")))))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PCon "Flat") (PCon "FlatAlt" PWild (PVar "b"))) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "b")) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PCon "Break") (PCon "FlatAlt" (PVar "a") PWild)) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EVar "a")) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PCon "Flat") (PCon "Alt" (PVar "a") PWild)) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "a")) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PCon "Break") (PCon "Alt" (PVar "a") (PVar "b"))) (PVar "z"))) (EIf (EApp (EApp (EVar "fits") (EBinOp "-" (EVar "defaultWidth") (EVar "col"))) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EVar "a")) (EVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EVar "a")) (EVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EVar "b")) (EVar "z")))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PCon "Flat") (PCon "Hang" (PVar "sep") (PVar "d"))) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EApp (EApp (EVar "hangInline") (EVar "sep")) (EVar "d"))) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PCon "Break") (PCon "Hang" (PVar "sep") (PVar "d"))) (PVar "z"))) (EBlock (DoLet false false (PVar "inline") (EApp (EApp (EVar "hangInline") (EVar "sep")) (EVar "d"))) (DoExpr (EIf (EApp (EApp (EVar "fits") (EBinOp "-" (EVar "defaultWidth") (EVar "col"))) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "inline")) (EVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "inline")) (EVar "z"))) (EIf (EApp (EApp (EVar "fits") (EBinOp "-" (EBinOp "-" (EVar "defaultWidth") (EVar "i")) (ELit (LInt 2)))) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "Flat")) (EVar "d")) (EVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "sep"))) (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EVar "Line")) (EVar "d"))))) (EVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EVar "inline")) (EVar "z"))))))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" PWild PWild (PCon "LineComment" (PVar "s"))) (PVar "z"))) (EBinOp "::" (EBinOp "++" (ELit (LString "  ")) (EVar "s")) (EApp (EApp (EVar "go") (EBinOp "+" (EBinOp "+" (EVar "col") (ELit (LInt 2))) (EApp (EVar "stringLength") (EVar "s")))) (EApp (EApp (EVar "map") (EVar "itemBroken")) (EVar "z")))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PCon "Flat") (PCon "Fill" (PVar "sf") (PVar "ds"))) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EApp (EApp (EVar "fillFlatDoc") (EVar "sf")) (EVar "ds"))) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" PWild (PCon "Break") (PCon "Fill" PWild (PList))) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EVar "z")))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PCon "Break") (PCon "Fill" (PCon "False") (PCons (PVar "d") (PVar "ds")))) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "d")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EApp (EApp (EVar "Fill") (EVar "True")) (EVar "ds"))) (EVar "z")))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PCon "Break") (PCon "Fill" (PCon "True") (PCons (PVar "d") (PVar "ds")))) (PVar "z"))) (EBlock (DoLet false false (PVar "rest") (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "d")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EApp (EApp (EVar "Fill") (EVar "True")) (EVar "ds"))) (EVar "z")))) (DoExpr (EIf (EApp (EApp (EVar "fits") (EBinOp "-" (EBinOp "-" (EVar "defaultWidth") (EVar "col")) (ELit (LInt 1)))) (EListLit (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "d")))) (EBinOp "::" (ELit (LString " ")) (EApp (EApp (EVar "go") (EBinOp "+" (EVar "col") (ELit (LInt 1)))) (EVar "rest"))) (EBinOp "::" (EApp (EVar "newlineStr") (EVar "i")) (EApp (EApp (EVar "go") (EVar "i")) (EVar "rest")))))))
(DTypeSig true "render" (TyFun (TyCon "Doc") (TyCon "String")))
(DFunDef false "render" ((PVar "doc")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "go") (ELit (LInt 0))) (EListLit (EApp (EApp (EApp (EVar "Item") (ELit (LInt 0))) (EVar "Break")) (EVar "doc"))))))
(DTypeSig false "goFlat" (TyFun (TyApp (TyCon "List") (TyCon "Doc")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "goFlat" ((PList)) (EListLit))
(DFunDef false "goFlat" ((PCons (PCon "Nil") (PVar "z"))) (EApp (EVar "goFlat") (EVar "z")))
(DFunDef false "goFlat" ((PCons (PCon "Text" (PVar "s")) (PVar "z"))) (EBinOp "::" (EVar "s") (EApp (EVar "goFlat") (EVar "z"))))
(DFunDef false "goFlat" ((PCons (PCon "Line") (PVar "z"))) (EBinOp "::" (ELit (LString " ")) (EApp (EVar "goFlat") (EVar "z"))))
(DFunDef false "goFlat" ((PCons (PCon "Softline") (PVar "z"))) (EApp (EVar "goFlat") (EVar "z")))
(DFunDef false "goFlat" ((PCons (PCon "Hardline") (PVar "z"))) (EBinOp "::" (ELit (LString " ")) (EApp (EVar "goFlat") (EVar "z"))))
(DFunDef false "goFlat" ((PCons (PCon "BlankLine") (PVar "z"))) (EBinOp "::" (ELit (LString " ")) (EApp (EVar "goFlat") (EVar "z"))))
(DFunDef false "goFlat" ((PCons (PCon "Cat" (PVar "a") (PVar "b")) (PVar "z"))) (EApp (EVar "goFlat") (EBinOp "::" (EVar "a") (EBinOp "::" (EVar "b") (EVar "z")))))
(DFunDef false "goFlat" ((PCons (PCon "Nest" PWild (PVar "d")) (PVar "z"))) (EApp (EVar "goFlat") (EBinOp "::" (EVar "d") (EVar "z"))))
(DFunDef false "goFlat" ((PCons (PCon "Group" (PVar "d")) (PVar "z"))) (EApp (EVar "goFlat") (EBinOp "::" (EVar "d") (EVar "z"))))
(DFunDef false "goFlat" ((PCons (PCon "FlatAlt" PWild (PVar "b")) (PVar "z"))) (EApp (EVar "goFlat") (EBinOp "::" (EVar "b") (EVar "z"))))
(DFunDef false "goFlat" ((PCons (PCon "Alt" (PVar "a") PWild) (PVar "z"))) (EApp (EVar "goFlat") (EBinOp "::" (EVar "a") (EVar "z"))))
(DFunDef false "goFlat" ((PCons (PCon "Hang" (PVar "sep") (PVar "d")) (PVar "z"))) (EApp (EVar "goFlat") (EBinOp "::" (EApp (EApp (EVar "hangInline") (EVar "sep")) (EVar "d")) (EVar "z"))))
(DFunDef false "goFlat" ((PCons (PCon "LineComment" (PVar "s")) (PVar "z"))) (EBinOp "::" (EBinOp "++" (ELit (LString "  ")) (EVar "s")) (EApp (EVar "goFlat") (EVar "z"))))
(DFunDef false "goFlat" ((PCons (PCon "Fill" (PVar "sf") (PVar "ds")) (PVar "z"))) (EApp (EVar "goFlat") (EBinOp "::" (EApp (EApp (EVar "fillFlatDoc") (EVar "sf")) (EVar "ds")) (EVar "z"))))
(DTypeSig false "renderFlat" (TyFun (TyCon "Doc") (TyCon "String")))
(DFunDef false "renderFlat" ((PVar "d")) (EApp (EVar "stringConcat") (EApp (EVar "goFlat") (EListLit (EVar "d")))))
(DData Public "PComment" () ((variant "PComment" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "String") (TyCon "Bool")))) ())
(DTypeSig false "pcLine" (TyFun (TyCon "PComment") (TyCon "Int")))
(DFunDef false "pcLine" ((PCon "PComment" (PVar "l") PWild PWild PWild)) (EVar "l"))
(DTypeSig false "pcText" (TyFun (TyCon "PComment") (TyCon "String")))
(DFunDef false "pcText" ((PCon "PComment" PWild PWild (PVar "t") PWild)) (EVar "t"))
(DTypeSig false "pcCol" (TyFun (TyCon "PComment") (TyCon "Int")))
(DFunDef false "pcCol" ((PCon "PComment" PWild (PVar "c") PWild PWild)) (EVar "c"))
(DTypeSig false "pcStandalone" (TyFun (TyCon "PComment") (TyCon "Bool")))
(DFunDef false "pcStandalone" ((PCon "PComment" PWild PWild PWild (PVar "s"))) (EVar "s"))
(DTypeSig false "pcEndLine" (TyFun (TyCon "PComment") (TyCon "Int")))
(DFunDef false "pcEndLine" ((PCon "PComment" (PVar "l") PWild (PVar "t") PWild)) (EBinOp "+" (EVar "l") (EApp (EApp (EVar "countNewlines") (EApp (EVar "stringToChars") (EVar "t"))) (ELit (LInt 0)))))
(DTypeSig false "countNewlines" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "countNewlines" ((PVar "cs") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0)) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "\n"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EApp (EVar "countNewlines") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EVar "countNewlines") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "commentsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "PComment"))))
(DFunDef false "commentsRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "commentBoundRef" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "commentBoundRef" () (EApp (EVar "Ref") (ELit (LInt 0))))
(DTypeSig false "commentsUsedRef" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "commentsUsedRef" () (EApp (EVar "Ref") (ELit (LInt 0))))
(DTypeSig true "setComments" (TyFun (TyApp (TyCon "List") (TyCon "PComment")) (TyFun (TyCon "Int") (TyCon "Unit"))))
(DFunDef false "setComments" ((PVar "cs") (PVar "bound")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentsRef")) (EVar "cs"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentBoundRef")) (EVar "bound"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "declBoundRef")) (EVar "bound"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentsUsedRef")) (ELit (LInt 0))))))
(DTypeSig false "declBoundRef" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "declBoundRef" () (EApp (EVar "Ref") (ELit (LInt 0))))
(DTypeSig true "takeLeftoverComments" (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyCon "PComment"))))
(DFunDef false "takeLeftoverComments" (PWild) (EBlock (DoLet false false (PVar "cs") (EUnOp "!" (EVar "commentsRef"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentsRef")) (EListLit))) (DoExpr (EVar "cs"))))
(DTypeSig true "commentsPlaced" (TyFun (TyCon "Unit") (TyCon "Int")))
(DFunDef false "commentsPlaced" (PWild) (EUnOp "!" (EVar "commentsUsedRef")))
(DTypeSig false "popBefore" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "PComment"))))
(DFunDef false "popBefore" ((PVar "line")) (EBlock (DoLet false false (PVar "cs") (EUnOp "!" (EVar "commentsRef"))) (DoExpr (EMatch (EApp (EApp (EVar "spanBefore") (EVar "line")) (EVar "cs")) (arm (PTuple (PVar "mine") (PVar "rest")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentsRef")) (EVar "rest"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentsUsedRef")) (EBinOp "+" (EUnOp "!" (EVar "commentsUsedRef")) (EApp (EVar "listLen") (EVar "mine"))))) (DoExpr (EVar "mine"))))))))
(DTypeSig false "spanBefore" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PComment")) (TyTuple (TyApp (TyCon "List") (TyCon "PComment")) (TyApp (TyCon "List") (TyCon "PComment"))))))
(DFunDef false "spanBefore" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "spanBefore" ((PVar "line") (PCons (PVar "c") (PVar "rest"))) (EIf (EBinOp "<" (EApp (EVar "pcLine") (EVar "c")) (EVar "line")) (EMatch (EApp (EApp (EVar "spanBefore") (EVar "line")) (EVar "rest")) (arm (PTuple (PVar "mine") (PVar "left")) () (ETuple (EBinOp "::" (EVar "c") (EVar "mine")) (EVar "left")))) (EIf (EVar "otherwise") (ETuple (EListLit) (EBinOp "::" (EVar "c") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "popTrailingAt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "PComment")))))
(DFunDef false "popTrailingAt" ((PVar "line") (PVar "col")) (EBlock (DoLet false false (PVar "cs") (EUnOp "!" (EVar "commentsRef"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "partTrailing") (EVar "line")) (EVar "col")) (EVar "cs")) (arm (PTuple (PVar "mine") (PVar "rest")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentsRef")) (EVar "rest"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentsUsedRef")) (EBinOp "+" (EUnOp "!" (EVar "commentsUsedRef")) (EApp (EVar "listLen") (EVar "mine"))))) (DoExpr (EVar "mine"))))))))
(DTypeSig false "partTrailing" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PComment")) (TyTuple (TyApp (TyCon "List") (TyCon "PComment")) (TyApp (TyCon "List") (TyCon "PComment")))))))
(DFunDef false "partTrailing" (PWild PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "partTrailing" ((PVar "line") (PVar "col") (PCons (PVar "c") (PVar "rest"))) (EIf (EBinOp ">" (EApp (EVar "pcLine") (EVar "c")) (EVar "line")) (ETuple (EListLit) (EBinOp "::" (EVar "c") (EVar "rest"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "pcLine") (EVar "c")) (EVar "line")) (EApp (EVar "not") (EApp (EVar "pcStandalone") (EVar "c")))) (EBinOp ">=" (EApp (EVar "pcCol") (EVar "c")) (EVar "col"))) (EMatch (EApp (EApp (EApp (EVar "partTrailing") (EVar "line")) (EVar "col")) (EVar "rest")) (arm (PTuple (PVar "mine") (PVar "left")) () (ETuple (EBinOp "::" (EVar "c") (EVar "mine")) (EVar "left")))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "partTrailing") (EVar "line")) (EVar "col")) (EVar "rest")) (arm (PTuple (PVar "mine") (PVar "left")) () (ETuple (EVar "mine") (EBinOp "::" (EVar "c") (EVar "left"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "popDanglingBefore" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "PComment")))))
(DFunDef false "popDanglingBefore" ((PVar "line") (PVar "col")) (EBlock (DoLet false false (PVar "cs") (EUnOp "!" (EVar "commentsRef"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "partDangling") (EVar "line")) (EVar "col")) (EVar "cs")) (arm (PTuple (PVar "mine") (PVar "rest")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentsRef")) (EVar "rest"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentsUsedRef")) (EBinOp "+" (EUnOp "!" (EVar "commentsUsedRef")) (EApp (EVar "listLen") (EVar "mine"))))) (DoExpr (EVar "mine"))))))))
(DTypeSig false "partDangling" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PComment")) (TyTuple (TyApp (TyCon "List") (TyCon "PComment")) (TyApp (TyCon "List") (TyCon "PComment")))))))
(DFunDef false "partDangling" (PWild PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "partDangling" ((PVar "line") (PVar "col") (PCons (PCon "PComment" (PVar "cl") (PVar "cc") (PVar "t") (PVar "st")) (PVar "rest"))) (EIf (EBinOp ">=" (EVar "cl") (EVar "line")) (ETuple (EListLit) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "PComment") (EVar "cl")) (EVar "cc")) (EVar "t")) (EVar "st")) (EVar "rest"))) (EIf (EBinOp ">=" (EVar "cc") (EVar "col")) (EMatch (EApp (EApp (EApp (EVar "partDangling") (EVar "line")) (EVar "col")) (EVar "rest")) (arm (PTuple (PVar "mine") (PVar "left")) () (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "PComment") (EVar "cl")) (EVar "cc")) (EVar "t")) (EVar "st")) (EVar "mine")) (EVar "left")))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "partDangling") (EVar "line")) (EVar "col")) (EVar "rest")) (arm (PTuple (PVar "mine") (PVar "left")) () (ETuple (EVar "mine") (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "PComment") (EVar "cl")) (EVar "cc")) (EVar "t")) (EVar "st")) (EVar "left"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "withBound" (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "Unit") (TyCon "Doc")) (TyCon "Doc"))))
(DFunDef false "withBound" ((PVar "b") (PVar "mk")) (EBlock (DoLet false false (PVar "saved") (EUnOp "!" (EVar "commentBoundRef"))) (DoLet false false (PVar "narrowed") (EBinOp "&&" (EBinOp ">" (EVar "b") (ELit (LInt 0))) (EBinOp "<" (EVar "b") (EVar "saved")))) (DoExpr (EIf (EVar "narrowed") (EApp (EApp (EVar "setRef") (EVar "commentBoundRef")) (EVar "b")) (ELit LUnit))) (DoLet false false (PVar "d") (EApp (EVar "mk") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentBoundRef")) (EVar "saved"))) (DoExpr (EVar "d"))))
(DTypeSig false "noClaimRef" (TyApp (TyCon "Ref") (TyCon "Bool")))
(DFunDef false "noClaimRef" () (EApp (EVar "Ref") (EVar "False")))
(DTypeSig false "noClaimDoc" (TyFun (TyFun (TyCon "Unit") (TyCon "Doc")) (TyCon "Doc")))
(DFunDef false "noClaimDoc" ((PVar "mk")) (EBlock (DoLet false false (PVar "saved") (EUnOp "!" (EVar "noClaimRef"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "noClaimRef")) (EVar "True"))) (DoLet false false (PVar "d") (EApp (EVar "mk") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "noClaimRef")) (EVar "saved"))) (DoExpr (EVar "d"))))
(DTypeSig false "pendingWithin" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "pendingWithin" ((PVar "lo") (PVar "hi")) (EApp (EApp (EApp (EVar "anyWithin") (EVar "lo")) (EVar "hi")) (EUnOp "!" (EVar "commentsRef"))))
(DTypeSig false "anyWithin" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PComment")) (TyCon "Bool")))))
(DFunDef false "anyWithin" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "anyWithin" ((PVar "lo") (PVar "hi") (PCons (PVar "c") (PVar "rest"))) (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EApp (EVar "pcLine") (EVar "c")) (EVar "lo")) (EBinOp "<=" (EApp (EVar "pcLine") (EVar "c")) (EVar "hi"))) (EApp (EApp (EApp (EVar "anyWithin") (EVar "lo")) (EVar "hi")) (EVar "rest"))))
(DTypeSig false "pendingInside" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "pendingInside" ((PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) (EApp (EApp (EApp (EApp (EApp (EVar "anyInside") (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec")) (EUnOp "!" (EVar "commentsRef"))))
(DTypeSig false "anyInside" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PComment")) (TyCon "Bool")))))))
(DFunDef false "anyInside" (PWild PWild PWild PWild (PList)) (EVar "False"))
(DFunDef false "anyInside" ((PVar "sl") (PVar "sc") (PVar "el") (PVar "ec") (PCons (PCon "PComment" (PVar "cl") (PVar "cc") PWild PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "afterStart") (EBinOp "||" (EBinOp ">" (EVar "cl") (EVar "sl")) (EBinOp "&&" (EBinOp "==" (EVar "cl") (EVar "sl")) (EBinOp ">=" (EVar "cc") (EVar "sc"))))) (DoLet false false (PVar "beforeEnd") (EBinOp "||" (EBinOp "<" (EVar "cl") (EVar "el")) (EBinOp "&&" (EBinOp "==" (EVar "cl") (EVar "el")) (EBinOp "<" (EVar "cc") (EVar "ec"))))) (DoExpr (EBinOp "||" (EBinOp "&&" (EVar "afterStart") (EVar "beforeEnd")) (EApp (EApp (EApp (EApp (EApp (EVar "anyInside") (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec")) (EVar "rest"))))))
(DTypeSig false "noSpan" (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))
(DFunDef false "noSpan" () (ETuple (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0))))
(DTypeSig false "mergeSpan" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "mergeSpan" ((PTuple (PVar "a1") (PVar "c1") (PVar "b1") (PVar "d1")) (PTuple (PVar "a2") (PVar "c2") (PVar "b2") (PVar "d2"))) (EIf (EBinOp "==" (EVar "a1") (ELit (LInt 0))) (ETuple (EVar "a2") (EVar "c2") (EVar "b2") (EVar "d2")) (EIf (EBinOp "==" (EVar "a2") (ELit (LInt 0))) (ETuple (EVar "a1") (EVar "c1") (EVar "b1") (EVar "d1")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "earliest") (ETuple (EVar "a1") (EVar "c1"))) (ETuple (EVar "a2") (EVar "c2"))) (arm (PTuple (PVar "sl") (PVar "sc")) () (EMatch (EApp (EApp (EVar "latest") (ETuple (EVar "b1") (EVar "d1"))) (ETuple (EVar "b2") (EVar "d2"))) (arm (PTuple (PVar "el") (PVar "ec")) () (ETuple (EVar "sl") (EVar "sc") (EVar "el") (EVar "ec")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "earliest" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "earliest" ((PTuple (PVar "l1") (PVar "c1")) (PTuple (PVar "l2") (PVar "c2"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "l1") (EVar "l2")) (EBinOp "&&" (EBinOp "==" (EVar "l1") (EVar "l2")) (EBinOp "<=" (EVar "c1") (EVar "c2")))) (ETuple (EVar "l1") (EVar "c1")) (ETuple (EVar "l2") (EVar "c2"))))
(DTypeSig false "latest" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "latest" ((PTuple (PVar "l1") (PVar "c1")) (PTuple (PVar "l2") (PVar "c2"))) (EIf (EBinOp "||" (EBinOp ">" (EVar "l1") (EVar "l2")) (EBinOp "&&" (EBinOp "==" (EVar "l1") (EVar "l2")) (EBinOp ">=" (EVar "c1") (EVar "c2")))) (ETuple (EVar "l1") (EVar "c1")) (ETuple (EVar "l2") (EVar "c2"))))
(DTypeSig false "spanStart" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "spanStart" ((PTuple (PVar "s") PWild PWild PWild)) (EVar "s"))
(DTypeSig false "spansOf" (TyFun (TyFun (TyVar "a") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "spansOf" (PWild (PList)) (EVar "noSpan"))
(DFunDef false "spansOf" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "f") (EVar "x"))) (EApp (EApp (EVar "spansOf") (EVar "f")) (EVar "xs"))))
(DTypeSig false "locSpan" (TyFun (TyCon "Loc") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "locSpan" ((PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (ETuple (EVar "sl") (EVar "sc") (EVar "el") (EVar "ec")))
(DTypeSig false "exprSpan" (TyFun (TyCon "Expr") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "exprSpan" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "locSpan") (EVar "l")))
(DFunDef false "exprSpan" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "f"))) (EApp (EVar "exprSpan") (EVar "x"))))
(DFunDef false "exprSpan" ((PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "mergeSpan") (EApp (EApp (EVar "spansOf") (EVar "patSpan")) (EVar "pats"))) (EApp (EVar "exprSpan") (EVar "body"))))
(DFunDef false "exprSpan" ((PCon "ELet" PWild PWild (PVar "p") (PVar "rhs") (PVar "body"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "patSpan") (EVar "p"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "rhs"))) (EApp (EVar "exprSpan") (EVar "body")))))
(DFunDef false "exprSpan" ((PCon "EMatch" (PVar "sc") (PVar "arms"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "sc"))) (EApp (EApp (EVar "spansOf") (EVar "armSpan")) (EVar "arms"))))
(DFunDef false "exprSpan" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "c"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "t"))) (EApp (EVar "exprSpan") (EVar "e")))))
(DFunDef false "exprSpan" ((PCon "EBinOp" PWild (PVar "l") (PVar "r") PWild)) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "l"))) (EApp (EVar "exprSpan") (EVar "r"))))
(DFunDef false "exprSpan" ((PCon "EUnOp" PWild (PVar "e") PWild)) (EApp (EVar "exprSpan") (EVar "e")))
(DFunDef false "exprSpan" ((PCon "EInfix" PWild (PVar "l") (PVar "r"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "l"))) (EApp (EVar "exprSpan") (EVar "r"))))
(DFunDef false "exprSpan" ((PCon "EFieldAccess" (PVar "e") PWild PWild)) (EApp (EVar "exprSpan") (EVar "e")))
(DFunDef false "exprSpan" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "spansOf") (EVar "exprSpan")) (EVar "es")))
(DFunDef false "exprSpan" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "spansOf") (EVar "exprSpan")) (EVar "es")))
(DFunDef false "exprSpan" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EVar "spansOf") (EVar "exprSpan")) (EVar "es")))
(DFunDef false "exprSpan" ((PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "lo"))) (EApp (EVar "exprSpan") (EVar "hi"))))
(DFunDef false "exprSpan" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "lo"))) (EApp (EVar "exprSpan") (EVar "hi"))))
(DFunDef false "exprSpan" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") PWild PWild)) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "e"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "lo"))) (EApp (EVar "exprSpan") (EVar "hi")))))
(DFunDef false "exprSpan" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "mergeSpan") (EApp (EApp (EVar "spansOf") (EVar "letBindSpan")) (EVar "binds"))) (EApp (EVar "exprSpan") (EVar "body"))))
(DFunDef false "exprSpan" ((PCon "ESection" (PCon "SecRight" PWild (PVar "e")))) (EApp (EVar "exprSpan") (EVar "e")))
(DFunDef false "exprSpan" ((PCon "ESection" (PCon "SecLeft" (PVar "e") PWild))) (EApp (EVar "exprSpan") (EVar "e")))
(DFunDef false "exprSpan" ((PCon "ESection" PWild)) (EVar "noSpan"))
(DFunDef false "exprSpan" ((PCon "EIndex" (PVar "e") (PVar "i") PWild)) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "e"))) (EApp (EVar "exprSpan") (EVar "i"))))
(DFunDef false "exprSpan" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "exprSpan") (EVar "e")))
(DFunDef false "exprSpan" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "exprSpan") (EVar "e")))
(DFunDef false "exprSpan" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "spansOf") (EVar "stmtSpan")) (EVar "stmts")))
(DFunDef false "exprSpan" ((PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EVar "spansOf") (EVar "stmtSpan")) (EVar "stmts")))
(DFunDef false "exprSpan" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EVar "spansOf") (EVar "interpSpan")) (EVar "parts")))
(DFunDef false "exprSpan" ((PCon "EGuards" (PVar "arms"))) (EApp (EApp (EVar "spansOf") (EVar "guardArmSpan")) (EVar "arms")))
(DFunDef false "exprSpan" ((PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EVar "spansOf") (EVar "fieldAssignSpan")) (EVar "fs")))
(DFunDef false "exprSpan" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") PWild)) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "e"))) (EApp (EApp (EVar "spansOf") (EVar "fieldAssignSpan")) (EVar "fs"))))
(DFunDef false "exprSpan" ((PCon "EVariantUpdate" PWild (PVar "e") (PVar "fs"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "e"))) (EApp (EApp (EVar "spansOf") (EVar "fieldAssignSpan")) (EVar "fs"))))
(DFunDef false "exprSpan" ((PCon "EMapLit" PWild (PVar "kvs"))) (EApp (EApp (EVar "spansOf") (EVar "kvSpan")) (EVar "kvs")))
(DFunDef false "exprSpan" ((PCon "ESetLit" PWild (PVar "es"))) (EApp (EApp (EVar "spansOf") (EVar "exprSpan")) (EVar "es")))
(DFunDef false "exprSpan" ((PCon "EAsPat" PWild (PVar "e"))) (EApp (EVar "exprSpan") (EVar "e")))
(DFunDef false "exprSpan" (PWild) (EVar "noSpan"))
(DTypeSig false "interpSpan" (TyFun (TyCon "InterpPart") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "interpSpan" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "exprSpan") (EVar "e")))
(DFunDef false "interpSpan" (PWild) (EVar "noSpan"))
(DTypeSig false "kvSpan" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "kvSpan" ((PTuple (PVar "k") (PVar "v"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "k"))) (EApp (EVar "exprSpan") (EVar "v"))))
(DTypeSig false "fieldAssignSpan" (TyFun (TyCon "FieldAssign") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "fieldAssignSpan" ((PCon "FieldAssign" PWild (PVar "v"))) (EApp (EVar "exprSpan") (EVar "v")))
(DTypeSig false "letBindSpan" (TyFun (TyCon "LetBind") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "letBindSpan" ((PCon "LetBind" PWild (PVar "clauses"))) (EApp (EApp (EVar "spansOf") (EVar "clauseSpan")) (EVar "clauses")))
(DTypeSig false "clauseSpan" (TyFun (TyCon "FunClause") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "clauseSpan" ((PCon "FunClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "mergeSpan") (EApp (EApp (EVar "spansOf") (EVar "patSpan")) (EVar "pats"))) (EApp (EVar "exprSpan") (EVar "body"))))
(DTypeSig false "patSpan" (TyFun (TyCon "Pat") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "patSpan" ((PCon "PVar" PWild (PVar "l"))) (EApp (EVar "locSpan") (EVar "l")))
(DFunDef false "patSpan" ((PCon "PAs" PWild (PVar "l") (PVar "p"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "locSpan") (EVar "l"))) (EApp (EVar "patSpan") (EVar "p"))))
(DFunDef false "patSpan" ((PCon "PCon" PWild (PVar "ps"))) (EApp (EApp (EVar "spansOf") (EVar "patSpan")) (EVar "ps")))
(DFunDef false "patSpan" ((PCon "PCons" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "patSpan") (EVar "a"))) (EApp (EVar "patSpan") (EVar "b"))))
(DFunDef false "patSpan" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "spansOf") (EVar "patSpan")) (EVar "ps")))
(DFunDef false "patSpan" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "spansOf") (EVar "patSpan")) (EVar "ps")))
(DFunDef false "patSpan" ((PCon "PRec" PWild (PVar "fs") PWild)) (EApp (EApp (EVar "spansOf") (EVar "recPatFieldSpan")) (EVar "fs")))
(DFunDef false "patSpan" (PWild) (EVar "noSpan"))
(DTypeSig false "recPatFieldSpan" (TyFun (TyCon "RecPatField") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "recPatFieldSpan" ((PCon "RecPatField" PWild (PVar "l") (PVar "q"))) (EMatch (EVar "q") (arm (PCon "Some" (PVar "p")) () (EApp (EApp (EVar "mergeSpan") (EApp (EVar "locSpan") (EVar "l"))) (EApp (EVar "patSpan") (EVar "p")))) (arm (PCon "None") () (EApp (EVar "locSpan") (EVar "l")))))
(DTypeSig false "guardSpan" (TyFun (TyCon "Guard") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "guardSpan" ((PCon "GBool" (PVar "e"))) (EApp (EVar "exprSpan") (EVar "e")))
(DFunDef false "guardSpan" ((PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "patSpan") (EVar "p"))) (EApp (EVar "exprSpan") (EVar "e"))))
(DTypeSig false "armSpan" (TyFun (TyCon "Arm") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "armSpan" ((PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "patSpan") (EVar "p"))) (EApp (EApp (EVar "mergeSpan") (EApp (EApp (EVar "spansOf") (EVar "guardSpan")) (EVar "gs"))) (EApp (EVar "exprSpan") (EVar "body")))))
(DTypeSig false "guardArmSpan" (TyFun (TyCon "GuardArm") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "guardArmSpan" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "mergeSpan") (EApp (EApp (EVar "spansOf") (EVar "guardSpan")) (EVar "gs"))) (EApp (EVar "exprSpan") (EVar "body"))))
(DTypeSig false "stmtSpan" (TyFun (TyCon "DoStmt") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "stmtSpan" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "exprSpan") (EVar "e")))
(DFunDef false "stmtSpan" ((PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "patSpan") (EVar "p"))) (EApp (EVar "exprSpan") (EVar "e"))))
(DFunDef false "stmtSpan" ((PCon "DoLet" PWild PWild (PVar "p") (PVar "e"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "patSpan") (EVar "p"))) (EApp (EVar "exprSpan") (EVar "e"))))
(DFunDef false "stmtSpan" ((PCon "DoAssign" PWild (PVar "e"))) (EApp (EVar "exprSpan") (EVar "e")))
(DFunDef false "stmtSpan" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EApp (EVar "exprSpan") (EVar "e")))
(DData Private "Piece" () ((variant "Piece" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyFun (TyCon "Unit") (TyCon "Doc"))))) ())
(DData Private "PieceOut" () ((variant "PieceOut" (ConPos (TyCon "Bool") (TyCon "Doc")))) ())
(DTypeSig false "pieceOutDoc" (TyFun (TyCon "PieceOut") (TyCon "Doc")))
(DFunDef false "pieceOutDoc" ((PCon "PieceOut" PWild (PVar "d"))) (EVar "d"))
(DTypeSig false "exprPiece" (TyFun (TyCon "Expr") (TyCon "Piece")))
(DFunDef false "exprPiece" ((PVar "e")) (EMatch (EApp (EVar "exprSpan") (EVar "e")) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s")) (EVar "sc")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e")))))))
(DTypeSig false "pieceDocs" (TyFun (TyFun (TyCon "Bool") (TyCon "Doc")) (TyFun (TyApp (TyCon "List") (TyCon "Piece")) (TyApp (TyCon "List") (TyCon "PieceOut")))))
(DFunDef false "pieceDocs" ((PVar "sepAfter") (PVar "ps")) (EApp (EApp (EApp (EApp (EVar "pieceDocsGo") (EVar "sepAfter")) (EBinOp "+" (EApp (EVar "firstPieceCol") (EVar "ps")) (ELit (LInt 1)))) (ELit (LInt 0))) (EVar "ps")))
(DTypeSig false "pieceDocsHard" (TyFun (TyApp (TyCon "List") (TyCon "Piece")) (TyApp (TyCon "List") (TyCon "PieceOut"))))
(DFunDef false "pieceDocsHard" ((PVar "ps")) (EApp (EApp (EApp (EApp (EVar "pieceDocsGo") (EVar "noSep")) (EApp (EVar "firstPieceCol") (EVar "ps"))) (ELit (LInt 0))) (EVar "ps")))
(DTypeSig false "firstPieceCol" (TyFun (TyApp (TyCon "List") (TyCon "Piece")) (TyCon "Int")))
(DFunDef false "firstPieceCol" ((PCons (PCon "Piece" PWild (PVar "sc") PWild PWild PWild) PWild)) (EVar "sc"))
(DFunDef false "firstPieceCol" ((PList)) (ELit (LInt 0)))
(DTypeSig false "pieceDocsGo" (TyFun (TyFun (TyCon "Bool") (TyCon "Doc")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Piece")) (TyApp (TyCon "List") (TyCon "PieceOut")))))))
(DFunDef false "pieceDocsGo" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "pieceDocsGo" ((PVar "sepAfter") (PVar "dangCol") (PVar "prevEnd") (PCons (PCon "Piece" (PVar "s") (PVar "sc") (PVar "en") (PVar "ec") (PVar "mk")) (PVar "rest"))) (EBlock (DoLet false false (PVar "isLast") (EApp (EVar "isEmptyL") (EVar "rest"))) (DoLet false false (PVar "bound") (EUnOp "!" (EVar "commentBoundRef"))) (DoLet false false (PVar "nextStart") (EMatch (EVar "rest") (arm (PCons (PCon "Piece" (PVar "s2") PWild PWild PWild PWild) PWild) () (EIf (EBinOp ">" (EVar "s2") (ELit (LInt 0))) (EVar "s2") (EVar "bound"))) (arm (PList) () (EVar "bound")))) (DoLet false false (PVar "claim") (EApp (EVar "not") (EUnOp "!" (EVar "noClaimRef")))) (DoLet false false (PVar "leading") (EIf (EBinOp "&&" (EVar "claim") (EBinOp ">" (EVar "s") (ELit (LInt 0)))) (EApp (EVar "popBefore") (EVar "s")) (EListLit))) (DoLet false false (PVar "firstLine") (EMatch (EVar "leading") (arm (PCons (PVar "c") PWild) () (EApp (EVar "pcLine") (EVar "c"))) (arm (PList) () (EVar "s")))) (DoLet false false (PVar "blankBefore") (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "prevEnd") (ELit (LInt 0))) (EBinOp ">" (EVar "s") (ELit (LInt 0)))) (EBinOp ">=" (EBinOp "-" (EVar "firstLine") (EVar "prevEnd")) (ELit (LInt 2))))) (DoLet false false (PVar "leadDoc") (EApp (EApp (EVar "leadingCommentsDoc") (EVar "leading")) (EVar "s"))) (DoLet false false (PVar "trailing") (EIf (EBinOp "&&" (EBinOp "&&" (EVar "claim") (EBinOp ">" (EVar "en") (ELit (LInt 0)))) (EBinOp ">" (EVar "nextStart") (EVar "en"))) (EApp (EApp (EVar "popTrailingAt") (EVar "en")) (EVar "ec")) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentBoundRef")) (EVar "nextStart"))) (DoLet false false (PVar "d") (EApp (EVar "mk") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentBoundRef")) (EVar "bound"))) (DoLet false false (PVar "trailDoc") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "c")) (EApp (EVar "LineComment") (EApp (EVar "pcText") (EVar "c"))))) (EVar "trailing")))) (DoLet false false (PVar "dangling") (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EVar "claim") (EVar "isLast")) (EBinOp ">" (EVar "s") (ELit (LInt 0)))) (EBinOp "==" (EVar "nextStart") (EUnOp "!" (EVar "declBoundRef")))) (EApp (EApp (EVar "popDanglingBefore") (EVar "nextStart")) (EVar "dangCol")) (EListLit))) (DoLet false false (PVar "dangDoc") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "c")) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EVar "text") (EApp (EVar "pcText") (EVar "c")))))) (EVar "dangling")))) (DoLet false false (PVar "out") (EApp (EApp (EVar "Cat") (EVar "leadDoc")) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EApp (EVar "Cat") (EApp (EVar "sepAfter") (EVar "isLast"))) (EApp (EApp (EVar "Cat") (EVar "trailDoc")) (EVar "dangDoc")))))) (DoExpr (EBinOp "::" (EApp (EApp (EVar "PieceOut") (EVar "blankBefore")) (EVar "out")) (EApp (EApp (EApp (EApp (EVar "pieceDocsGo") (EVar "sepAfter")) (EVar "dangCol")) (EIf (EBinOp ">" (EVar "en") (ELit (LInt 0))) (EVar "en") (EVar "prevEnd"))) (EVar "rest"))))))
(DTypeSig false "leadingCommentsDoc" (TyFun (TyApp (TyCon "List") (TyCon "PComment")) (TyFun (TyCon "Int") (TyCon "Doc"))))
(DFunDef false "leadingCommentsDoc" ((PList) PWild) (EVar "Nil"))
(DFunDef false "leadingCommentsDoc" ((PCons (PVar "c") (PVar "rest")) (PVar "s")) (EBlock (DoLet false false (PVar "nextLine") (EMatch (EVar "rest") (arm (PCons (PVar "c2") PWild) () (EApp (EVar "pcLine") (EVar "c2"))) (arm (PList) () (EVar "s")))) (DoLet false false (PVar "gap") (EIf (EBinOp ">=" (EBinOp "-" (EVar "nextLine") (EApp (EVar "pcEndLine") (EVar "c"))) (ELit (LInt 2))) (EVar "BlankLine") (EVar "Nil"))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EVar "pcText") (EVar "c")))) (EApp (EApp (EVar "Cat") (EVar "gap")) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "leadingCommentsDoc") (EVar "rest")) (EVar "s"))))))))
(DTypeSig false "noSep" (TyFun (TyCon "Bool") (TyCon "Doc")))
(DFunDef false "noSep" (PWild) (EVar "Nil"))
(DTypeSig false "soloDoc" (TyFun (TyCon "Expr") (TyFun (TyFun (TyCon "Unit") (TyCon "Doc")) (TyCon "Doc"))))
(DFunDef false "soloDoc" ((PVar "e") (PVar "mk")) (EMatch (EApp (EVar "exprSpan") (EVar "e")) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EApp (EVar "joinLine") (EApp (EApp (EVar "pieceDocs") (EVar "noSep")) (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s")) (EVar "sc")) (EVar "en")) (EVar "ec")) (EVar "mk"))))))))
(DTypeSig false "commaSep" (TyFun (TyCon "Bool") (TyCon "Doc")))
(DFunDef false "commaSep" ((PVar "isLast")) (EIf (EVar "isLast") (EVar "trailingCommaDoc") (EApp (EVar "text") (ELit (LString ",")))))
(DTypeSig false "joinHard" (TyFun (TyApp (TyCon "List") (TyCon "PieceOut")) (TyCon "Doc")))
(DFunDef false "joinHard" ((PList)) (EVar "Nil"))
(DFunDef false "joinHard" ((PCons (PCon "PieceOut" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "joinHardRest") (EVar "rest"))))
(DTypeSig false "joinHardRest" (TyFun (TyApp (TyCon "List") (TyCon "PieceOut")) (TyCon "Doc")))
(DFunDef false "joinHardRest" ((PList)) (EVar "Nil"))
(DFunDef false "joinHardRest" ((PCons (PCon "PieceOut" (PVar "blank") (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "Cat") (EIf (EVar "blank") (EVar "BlankLine") (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "joinHardRest") (EVar "rest"))))))
(DTypeSig false "joinLine" (TyFun (TyApp (TyCon "List") (TyCon "PieceOut")) (TyCon "Doc")))
(DFunDef false "joinLine" ((PList)) (EVar "Nil"))
(DFunDef false "joinLine" ((PCons (PCon "PieceOut" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "pieceOutDoc") (EVar "p"))))) (EVar "rest")))))
(DTypeSig false "anyCommented" (TyFun (TyApp (TyCon "List") (TyCon "Piece")) (TyCon "Bool")))
(DFunDef false "anyCommented" ((PList)) (EVar "False"))
(DFunDef false "anyCommented" ((PVar "ps")) (EBlock (DoLet false false (PVar "lo") (EApp (EVar "spanStart") (EApp (EApp (EVar "spansOf") (EVar "pieceSpan")) (EVar "ps")))) (DoExpr (EBinOp "&&" (EBinOp ">" (EVar "lo") (ELit (LInt 0))) (EApp (EApp (EVar "pendingWithin") (EVar "lo")) (EBinOp "-" (EUnOp "!" (EVar "commentBoundRef")) (ELit (LInt 1))))))))
(DTypeSig false "pieceSpan" (TyFun (TyCon "Piece") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "pieceSpan" ((PCon "Piece" (PVar "s") (PVar "sc") (PVar "en") (PVar "ec") PWild)) (ETuple (EVar "s") (EVar "sc") (EVar "en") (EVar "ec")))
(DTypeSig false "delimitedPieces" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Piece")) (TyCon "Doc"))))))
(DFunDef false "delimitedPieces" ((PVar "open_") (PVar "close_") PWild (PList)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "open_"))) (EApp (EVar "text") (EVar "close_"))))
(DFunDef false "delimitedPieces" ((PVar "open_") (PVar "close_") (PVar "forced") (PVar "ps")) (EBlock (DoLet false false (PVar "outs") (EApp (EApp (EVar "pieceDocs") (EVar "commaSep")) (EVar "ps"))) (DoExpr (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "open_"))) (EApp (EApp (EVar "Cat") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EIf (EVar "forced") (EVar "Hardline") (EVar "Softline"))) (EApp (EVar "joinLine") (EVar "outs"))))) (EApp (EApp (EVar "Cat") (EVar "Softline")) (EApp (EVar "text") (EVar "close_")))))))))
(DTypeSig false "filledDocs" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Doc")) (TyCon "Doc")))))
(DFunDef false "filledDocs" ((PVar "open_") (PVar "close_") (PList)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "open_"))) (EApp (EVar "text") (EVar "close_"))))
(DFunDef false "filledDocs" ((PVar "open_") (PVar "close_") (PVar "items")) (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "open_"))) (EApp (EApp (EVar "Cat") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Softline")) (EApp (EApp (EVar "Fill") (EVar "False")) (EApp (EVar "commaJoinFill") (EVar "items")))))) (EApp (EApp (EVar "Cat") (EVar "Softline")) (EApp (EVar "text") (EVar "close_")))))))
(DTypeSig false "commaJoinFill" (TyFun (TyApp (TyCon "List") (TyCon "Doc")) (TyApp (TyCon "List") (TyCon "Doc"))))
(DFunDef false "commaJoinFill" ((PList)) (EListLit))
(DFunDef false "commaJoinFill" ((PList (PVar "d"))) (EListLit (EVar "d")))
(DFunDef false "commaJoinFill" ((PCons (PVar "d") (PVar "ds"))) (EBinOp "::" (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "text") (ELit (LString ",")))) (EApp (EVar "commaJoinFill") (EVar "ds"))))
(DTypeSig false "bracedPieces" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Piece")) (TyCon "Doc")))))
(DFunDef false "bracedPieces" ((PVar "open_") PWild (PList)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "open_"))) (EApp (EVar "text") (ELit (LString "}")))))
(DFunDef false "bracedPieces" ((PVar "open_") (PVar "forced") (PVar "ps")) (EBlock (DoLet false false (PVar "outs") (EApp (EApp (EVar "pieceDocs") (EVar "commaSep")) (EVar "ps"))) (DoExpr (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "open_"))) (EApp (EApp (EVar "Cat") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EIf (EVar "forced") (EVar "Hardline") (EVar "Line"))) (EApp (EVar "joinLine") (EVar "outs"))))) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "text") (ELit (LString "}"))))))))))
(DTypeSig false "trailingCommasRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "trailingCommasRef" () (EApp (EVar "Ref") (EApp (EVar "arrayFromList") (EListLit))))
(DTypeSig true "setTrailingCommas" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyCon "Unit")))
(DFunDef false "setTrailingCommas" ((PVar "cs")) (EApp (EApp (EVar "setRef") (EVar "trailingCommasRef")) (EApp (EVar "arrayFromList") (EApp (EApp (EVar "sortBy") (EVar "cmpPos")) (EVar "cs")))))
(DTypeSig false "cmpPos" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "Ordering"))))
(DFunDef false "cmpPos" ((PTuple (PVar "l1") (PVar "c1")) (PTuple (PVar "l2") (PVar "c2"))) (EIf (EBinOp "==" (EVar "l1") (EVar "l2")) (EApp (EApp (EVar "compare") (EVar "c1")) (EVar "c2")) (EApp (EApp (EVar "compare") (EVar "l1")) (EVar "l2"))))
(DTypeSig false "posLowerBound" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "posLowerBound" ((PVar "arr") (PVar "line") (PVar "col") (PVar "lo") (PVar "hi")) (EIf (EBinOp ">=" (EVar "lo") (EVar "hi")) (EVar "lo") (EBlock (DoLet false false (PVar "mid") (EBinOp "/" (EBinOp "+" (EVar "lo") (EVar "hi")) (ELit (LInt 2)))) (DoExpr (EMatch (EApp (EApp (EVar "index") (EVar "arr")) (EVar "mid")) (arm (PTuple (PVar "l") (PVar "c")) () (EIf (EBinOp "||" (EBinOp "<" (EVar "l") (EVar "line")) (EBinOp "&&" (EBinOp "==" (EVar "l") (EVar "line")) (EBinOp "<" (EVar "c") (EVar "col")))) (EApp (EApp (EApp (EApp (EApp (EVar "posLowerBound") (EVar "arr")) (EVar "line")) (EVar "col")) (EBinOp "+" (EVar "mid") (ELit (LInt 1)))) (EVar "hi")) (EApp (EApp (EApp (EApp (EApp (EVar "posLowerBound") (EVar "arr")) (EVar "line")) (EVar "col")) (EVar "lo")) (EVar "mid")))))))))
(DTypeSig false "hasTrailingComma" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "hasTrailingComma" ((PVar "lastLine") (PVar "lastCol") (PVar "endLine") (PVar "endCol")) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "trailingCommasRef"))) (DoLet false false (PVar "i") (EApp (EApp (EApp (EApp (EApp (EVar "posLowerBound") (EVar "arr")) (EVar "lastLine")) (EVar "lastCol")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "False") (EMatch (EApp (EApp (EVar "index") (EVar "arr")) (EVar "i")) (arm (PTuple (PVar "l") (PVar "c")) () (EBinOp "||" (EBinOp "<" (EVar "l") (EVar "endLine")) (EBinOp "&&" (EBinOp "==" (EVar "l") (EVar "endLine")) (EBinOp "<" (EVar "c") (EVar "endCol"))))))))))
(DTypeSig false "exprEndPos" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "exprEndPos" ((PCon "ELoc" (PCon "Loc" PWild PWild PWild (PVar "el") (PVar "ec")) PWild)) (EApp (EVar "Some") (ETuple (EVar "el") (EVar "ec"))))
(DFunDef false "exprEndPos" ((PCon "EApp" PWild (PVar "x"))) (EApp (EVar "exprEndPos") (EVar "x")))
(DFunDef false "exprEndPos" ((PCon "EBinOp" PWild PWild (PVar "r") PWild)) (EApp (EVar "exprEndPos") (EVar "r")))
(DFunDef false "exprEndPos" ((PCon "EFieldAccess" (PVar "e") PWild PWild)) (EApp (EVar "exprEndPos") (EVar "e")))
(DFunDef false "exprEndPos" (PWild) (EVar "None"))
(DTypeSig false "literalForced" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Bool"))))
(DFunDef false "literalForced" ((PCon "Some" (PCon "Loc" PWild PWild PWild (PVar "el") (PVar "ec"))) (PVar "es")) (EMatch (EApp (EVar "last") (EVar "es")) (arm (PCon "Some" (PVar "e")) () (EMatch (EApp (EVar "exprEndPos") (EVar "e")) (arm (PCon "Some" (PTuple (PVar "ll") (PVar "lc"))) () (EApp (EApp (EApp (EApp (EVar "hasTrailingComma") (EVar "ll")) (EVar "lc")) (EVar "el")) (EVar "ec"))) (arm (PCon "None") () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DFunDef false "literalForced" ((PCon "None") PWild) (EVar "False"))
(DTypeSig false "fieldForced" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyCon "Bool"))))
(DFunDef false "fieldForced" ((PVar "loc") (PVar "fs")) (EApp (EApp (EVar "literalForced") (EVar "loc")) (EApp (EApp (EVar "map") (ELam ((PVar "f")) (EApp (EVar "fieldAssignValue") (EVar "f")))) (EVar "fs"))))
(DTypeSig false "fieldAssignValue" (TyFun (TyCon "FieldAssign") (TyCon "Expr")))
(DFunDef false "fieldAssignValue" ((PCon "FieldAssign" PWild (PVar "v"))) (EVar "v"))
(DTypeSig false "kvForced" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Expr"))) (TyCon "Bool"))))
(DFunDef false "kvForced" ((PVar "loc") (PVar "kvs")) (EApp (EApp (EVar "literalForced") (EVar "loc")) (EApp (EApp (EVar "map") (ELam ((PVar "kv")) (EApp (EVar "snd") (EVar "kv")))) (EVar "kvs"))))
(DTypeSig false "escapeCharLit" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "escapeCharLit" ((PVar "c")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "'"))) (ELit (LString "\\'")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "\\"))) (ELit (LString "\\\\")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "\n"))) (ELit (LString "\\n")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "\t"))) (ELit (LString "\\t")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "\r"))) (ELit (LString "\\r")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "\0"))) (ELit (LString "\\0")) (EIf (EVar "otherwise") (EVar "c") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "escStringLit" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "escStringLit" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "escSChars") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))))) (ELit (LString "\""))))
(DTypeSig false "escSChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "escSChars" ((PVar "cs") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "escSOne") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EVar "escSChars") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "escSOne" (TyFun (TyCon "Char") (TyCon "String")))
(DFunDef false "escSOne" ((PVar "c")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\\"))) (ELit (LString "\\\\")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\""))) (ELit (LString "\\\"")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\n"))) (ELit (LString "\\n")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\t"))) (ELit (LString "\\t")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\r"))) (ELit (LString "\\r")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\0"))) (ELit (LString "\\0")) (EIf (EBinOp "<" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 32))) (EBinOp "++" (EBinOp "++" (ELit (LString "\\u{")) (EApp (EVar "display") (EApp (EVar "escOneHex2") (EApp (EVar "charCode") (EVar "c"))))) (ELit (LString "}"))) (EIf (EVar "otherwise") (EApp (EVar "charToStr") (EVar "c")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "printLit" (TyFun (TyCon "Lit") (TyCon "Doc")))
(DFunDef false "printLit" ((PCon "LInt" (PVar "n"))) (EApp (EVar "text") (EApp (EVar "intToString") (EVar "n"))))
(DFunDef false "printLit" ((PCon "LFloat" (PVar "f"))) (EBlock (DoLet false false (PVar "s") (EApp (EVar "floatToString") (EVar "f"))) (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EApp (EVar "text") (EIf (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString ".")))) (EBinOp "++" (EVar "s") (ELit (LString "0"))) (EVar "s"))))))
(DFunDef false "printLit" ((PCon "LString" (PVar "s"))) (EApp (EVar "text") (EApp (EVar "escStringLit") (EVar "s"))))
(DFunDef false "printLit" ((PCon "LChar" (PVar "c"))) (EApp (EVar "text") (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EVar "escapeCharLit") (EVar "c"))) (ELit (LString "'")))))
(DFunDef false "printLit" ((PCon "LBool" (PVar "b"))) (EApp (EVar "text") (EIf (EVar "b") (ELit (LString "True")) (ELit (LString "False")))))
(DFunDef false "printLit" ((PCon "LUnit")) (EApp (EVar "text") (ELit (LString "()"))))
(DTypeSig false "isNegLit" (TyFun (TyCon "Lit") (TyCon "Bool")))
(DFunDef false "isNegLit" ((PCon "LInt" (PVar "n"))) (EBinOp "<" (EVar "n") (ELit (LInt 0))))
(DFunDef false "isNegLit" ((PCon "LFloat" (PVar "f"))) (EBlock (DoLet false false (PVar "s") (EApp (EVar "floatToString") (EVar "f"))) (DoExpr (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString "-")))))))
(DFunDef false "isNegLit" (PWild) (EVar "False"))
(DTypeSig false "tyConSurface" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "tyConSurface" ((PLit (LString "__tuple2__"))) (ELit (LString "(,)")))
(DFunDef false "tyConSurface" ((PLit (LString "__tuple3__"))) (ELit (LString "(,,)")))
(DFunDef false "tyConSurface" ((PLit (LString "__tuple4__"))) (ELit (LString "(,,,)")))
(DFunDef false "tyConSurface" ((PLit (LString "__tuple5__"))) (ELit (LString "(,,,,)")))
(DFunDef false "tyConSurface" ((PLit (LString "__tuple6__"))) (ELit (LString "(,,,,,)")))
(DFunDef false "tyConSurface" ((PLit (LString "__tuple7__"))) (ELit (LString "(,,,,,,)")))
(DFunDef false "tyConSurface" ((PLit (LString "__tuple8__"))) (ELit (LString "(,,,,,,,)")))
(DFunDef false "tyConSurface" ((PVar "n")) (EVar "n"))
(DTypeSig false "printType" (TyFun (TyCon "Ty") (TyCon "Doc")))
(DFunDef false "printType" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EApp (EVar "text") (EApp (EVar "tyConSurface") (EVar "n"))))
(DFunDef false "printType" ((PCon "TyVar" (PVar "n"))) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printType" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printTypeAppLhs") (EVar "a"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printTypeAtom") (EVar "b")))))
(DFunDef false "printType" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printTypeFunLhs") (EVar "a"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " -> ")))) (EApp (EVar "printType") (EVar "b")))))
(DFunDef false "printType" ((PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EVar "printType")) (EVar "ts")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printType" ((PCon "TyEffect" (PVar "es") (PVar "tail") (PVar "t"))) (EBlock (DoLet false false (PVar "inside") (EApp (EApp (EVar "effectInside") (EVar "es")) (EVar "tail"))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "<")))) (EApp (EApp (EVar "Cat") (EVar "inside")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "> ")))) (EApp (EVar "printTypeAppLhs") (EVar "t"))))))))
(DFunDef false "printType" ((PCon "TyRow" (PList) (PCons (PVar "a") (PCons (PVar "b") (PVar "rest"))) PWild)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EBinOp "::" (EVar "a") (EBinOp "::" (EVar "b") (EVar "rest")))))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printType" ((PCon "TyRow" (PVar "es") (PVar "tail") PWild)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "<")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "effectInside") (EVar "es")) (EVar "tail"))) (EApp (EVar "text") (ELit (LString ">"))))))
(DFunDef false "printType" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EApp (EApp (EVar "Cat") (EApp (EVar "constraintsDoc") (EVar "cs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " => ")))) (EApp (EVar "printType") (EVar "t")))))
(DTypeSig false "constraintsDoc" (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyCon "Doc")))
(DFunDef false "constraintsDoc" ((PList (PVar "c"))) (EApp (EVar "printConstraint") (EVar "c")))
(DFunDef false "constraintsDoc" ((PVar "cs")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EVar "printConstraint")) (EVar "cs")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DTypeSig false "sigTypeDoc" (TyFun (TyCon "Ty") (TyCon "Doc")))
(DFunDef false "sigTypeDoc" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EApp (EVar "constraintsDoc") (EVar "cs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =>")))) (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "arrowChain") (EVar "t"))))))))
(DFunDef false "sigTypeDoc" ((PVar "t")) (EApp (EVar "group") (EApp (EVar "nest") (EApp (EVar "arrowChain") (EVar "t")))))
(DTypeSig false "arrowChain" (TyFun (TyCon "Ty") (TyCon "Doc")))
(DFunDef false "arrowChain" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printTypeFunLhs") (EVar "a"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ->")))) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "arrowChain") (EVar "b"))))))
(DFunDef false "arrowChain" ((PVar "t")) (EApp (EVar "printType") (EVar "t")))
(DTypeSig false "effectInside" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Doc"))))
(DFunDef false "effectInside" ((PVar "es") (PList)) (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EVar "effAtomDoc")) (EVar "es"))))
(DFunDef false "effectInside" ((PList) (PVar "tails")) (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails"))))
(DFunDef false "effectInside" ((PVar "es") (PVar "tails")) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EVar "effAtomDoc")) (EVar "es")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " | ")))) (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails"))))))
(DTypeSig false "effAtomDoc" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "Doc")))
(DFunDef false "effAtomDoc" ((PTuple (PVar "l") (PCon "None"))) (EApp (EVar "text") (EVar "l")))
(DFunDef false "effAtomDoc" ((PTuple (PVar "l") (PCon "Some" (PVar "s")))) (EApp (EVar "text") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "l"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStringLit") (EVar "s")))) (ELit (LString "")))))
(DTypeSig false "printConstraint" (TyFun (TyCon "Constraint") (TyCon "Doc")))
(DFunDef false "printConstraint" ((PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PVar "args"))) false)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "iface"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "a")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printTypeAtom") (EVar "a"))))) (EVar "args")))))
(DTypeSig false "printTypeAtom" (TyFun (TyCon "Ty") (TyCon "Doc")))
(DFunDef false "printTypeAtom" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EApp (EVar "text") (EApp (EVar "tyConSurface") (EVar "n"))))
(DFunDef false "printTypeAtom" ((PCon "TyVar" (PVar "n"))) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printTypeAtom" ((PCon "TyTuple" (PVar "ts"))) (EApp (EVar "printType") (EApp (EVar "TyTuple") (EVar "ts"))))
(DFunDef false "printTypeAtom" ((PCon "TyRow" (PVar "es") (PVar "tail") (PVar "loc"))) (EApp (EVar "printType") (EApp (EApp (EApp (EVar "TyRow") (EVar "es")) (EVar "tail")) (EVar "loc"))))
(DFunDef false "printTypeAtom" ((PVar "t")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printType") (EVar "t"))) (EApp (EVar "text") (ELit (LString ")"))))))
(DTypeSig false "printTypeFunLhs" (TyFun (TyCon "Ty") (TyCon "Doc")))
(DFunDef false "printTypeFunLhs" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printType") (EApp (EApp (EVar "TyFun") (EVar "a")) (EVar "b")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printTypeFunLhs" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printType") (EApp (EApp (EVar "TyConstrained") (EVar "cs")) (EVar "t")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printTypeFunLhs" ((PVar "t")) (EApp (EVar "printType") (EVar "t")))
(DTypeSig false "printTypeAppLhs" (TyFun (TyCon "Ty") (TyCon "Doc")))
(DFunDef false "printTypeAppLhs" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EVar "printType") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))))
(DFunDef false "printTypeAppLhs" ((PVar "t")) (EApp (EVar "printTypeAtom") (EVar "t")))
(DTypeSig false "printPat" (TyFun (TyCon "Pat") (TyCon "Doc")))
(DFunDef false "printPat" ((PCon "PVar" (PVar "x") PWild)) (EApp (EVar "text") (EVar "x")))
(DFunDef false "printPat" ((PCon "PWild")) (EApp (EVar "text") (ELit (LString "_"))))
(DFunDef false "printPat" ((PCon "PLit" (PVar "l"))) (EApp (EVar "printLit") (EVar "l")))
(DFunDef false "printPat" ((PCon "PCon" (PVar "c") (PList))) (EApp (EVar "text") (EVar "c")))
(DFunDef false "printPat" ((PCon "PCon" (PVar "c") (PVar "pats"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "c"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "pats")))) (EApp (EVar "text") (ELit (LString ")")))))))
(DFunDef false "printPat" ((PCon "PCons" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPatAtom") (EVar "a"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " :: ")))) (EApp (EVar "printPat") (EVar "b")))))
(DFunDef false "printPat" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EVar "printPatArm")) (EVar "ps")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printPat" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "[")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EVar "printPatArm")) (EVar "ps")))) (EApp (EVar "text") (ELit (LString "]"))))))
(DFunDef false "printPat" ((PCon "PAs" (PVar "x") PWild (PVar "inner"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "x"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "@")))) (EApp (EVar "printPatAtom") (EVar "inner")))))
(DFunDef false "printPat" ((PCon "PRec" (PVar "name") (PVar "fields") (PVar "rest"))) (EBlock (DoLet false false (PVar "fieldDocs") (EApp (EApp (EVar "map") (EVar "recPatFieldDoc")) (EVar "fields"))) (DoLet false false (PVar "all") (EIf (EVar "rest") (EBinOp "++" (EVar "fieldDocs") (EListLit (EApp (EVar "text") (ELit (LString "..."))))) (EVar "fieldDocs"))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " { ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EVar "all"))) (EApp (EVar "text") (ELit (LString " }")))))))))
(DFunDef false "printPat" ((PCon "PRng" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printLit") (EVar "lo"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EIf (EVar "incl") (ELit (LString "..=")) (ELit (LString ".."))))) (EApp (EVar "printLit") (EVar "hi")))))
(DTypeSig false "recPatFieldDoc" (TyFun (TyCon "RecPatField") (TyCon "Doc")))
(DFunDef false "recPatFieldDoc" ((PCon "RecPatField" (PVar "k") PWild (PCon "None"))) (EApp (EVar "text") (EVar "k")))
(DFunDef false "recPatFieldDoc" ((PCon "RecPatField" (PVar "k") PWild (PCon "Some" (PVar "q")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "k"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EVar "printPat") (EVar "q")))))
(DTypeSig false "printPatAtom" (TyFun (TyCon "Pat") (TyCon "Doc")))
(DFunDef false "printPatAtom" ((PCon "PVar" (PVar "x") (PVar "l"))) (EApp (EVar "printPat") (EApp (EApp (EVar "PVar") (EVar "x")) (EVar "l"))))
(DFunDef false "printPatAtom" ((PCon "PWild")) (EApp (EVar "printPat") (EVar "PWild")))
(DFunDef false "printPatAtom" ((PCon "PLit" (PVar "l"))) (EApp (EVar "printPat") (EApp (EVar "PLit") (EVar "l"))))
(DFunDef false "printPatAtom" ((PCon "PCon" (PVar "c") (PVar "ps"))) (EApp (EVar "printPat") (EApp (EApp (EVar "PCon") (EVar "c")) (EVar "ps"))))
(DFunDef false "printPatAtom" ((PCon "PTuple" (PVar "ps"))) (EApp (EVar "printPat") (EApp (EVar "PTuple") (EVar "ps"))))
(DFunDef false "printPatAtom" ((PCon "PList" (PVar "ps"))) (EApp (EVar "printPat") (EApp (EVar "PList") (EVar "ps"))))
(DFunDef false "printPatAtom" ((PCon "PRec" (PVar "n") (PVar "fs") (PVar "r"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPat") (EApp (EApp (EApp (EVar "PRec") (EVar "n")) (EVar "fs")) (EVar "r")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printPatAtom" ((PCon "PRng" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EVar "printPat") (EApp (EApp (EApp (EVar "PRng") (EVar "lo")) (EVar "hi")) (EVar "incl"))))
(DFunDef false "printPatAtom" ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPat") (EVar "p"))) (EApp (EVar "text") (ELit (LString ")"))))))
(DTypeSig false "printPatArm" (TyFun (TyCon "Pat") (TyCon "Doc")))
(DFunDef false "printPatArm" ((PCon "PCon" (PVar "c") (PCons (PVar "p") (PVar "ps")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "c"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "q")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "q"))))) (EBinOp "::" (EVar "p") (EVar "ps"))))))
(DFunDef false "printPatArm" ((PVar "p")) (EApp (EVar "printPat") (EVar "p")))
(DTypeSig false "precTop" (TyCon "Int"))
(DFunDef false "precTop" () (ELit (LInt 0)))
(DTypeSig false "precAssign" (TyCon "Int"))
(DFunDef false "precAssign" () (ELit (LInt 1)))
(DTypeSig false "precPipe" (TyCon "Int"))
(DFunDef false "precPipe" () (ELit (LInt 2)))
(DTypeSig false "precCompose" (TyCon "Int"))
(DFunDef false "precCompose" () (ELit (LInt 3)))
(DTypeSig false "precOr" (TyCon "Int"))
(DFunDef false "precOr" () (ELit (LInt 4)))
(DTypeSig false "precAnd" (TyCon "Int"))
(DFunDef false "precAnd" () (ELit (LInt 5)))
(DTypeSig false "precCmp" (TyCon "Int"))
(DFunDef false "precCmp" () (ELit (LInt 6)))
(DTypeSig false "precCons" (TyCon "Int"))
(DFunDef false "precCons" () (ELit (LInt 7)))
(DTypeSig false "precAppend" (TyCon "Int"))
(DFunDef false "precAppend" () (ELit (LInt 8)))
(DTypeSig false "precAdd" (TyCon "Int"))
(DFunDef false "precAdd" () (ELit (LInt 9)))
(DTypeSig false "precMul" (TyCon "Int"))
(DFunDef false "precMul" () (ELit (LInt 10)))
(DTypeSig false "precInfix" (TyCon "Int"))
(DFunDef false "precInfix" () (ELit (LInt 11)))
(DTypeSig false "precApp" (TyCon "Int"))
(DFunDef false "precApp" () (ELit (LInt 12)))
(DTypeSig false "precUnary" (TyCon "Int"))
(DFunDef false "precUnary" () (ELit (LInt 13)))
(DTypeSig false "precPostfix" (TyCon "Int"))
(DFunDef false "precPostfix" () (ELit (LInt 14)))
(DTypeSig false "precAtom" (TyCon "Int"))
(DFunDef false "precAtom" () (ELit (LInt 15)))
(DTypeSig false "binopPrec" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "binopPrec" ((PVar "op")) (EIf (EBinOp "==" (EVar "op") (ELit (LString ":="))) (EVar "precAssign") (EIf (EBinOp "==" (EVar "op") (ELit (LString "|>"))) (EVar "precPipe") (EIf (EBinOp "==" (EVar "op") (ELit (LString ">>"))) (EVar "precCompose") (EIf (EBinOp "==" (EVar "op") (ELit (LString "<<"))) (EVar "precCompose") (EIf (EBinOp "==" (EVar "op") (ELit (LString "||"))) (EVar "precOr") (EIf (EBinOp "==" (EVar "op") (ELit (LString "&&"))) (EVar "precAnd") (EIf (EBinOp "==" (EVar "op") (ELit (LString "=="))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString "/="))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString "<"))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString ">"))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString "<="))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString ">="))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString "::"))) (EVar "precCons") (EIf (EBinOp "==" (EVar "op") (ELit (LString "++"))) (EVar "precAppend") (EIf (EBinOp "==" (EVar "op") (ELit (LString "+"))) (EVar "precAdd") (EIf (EBinOp "==" (EVar "op") (ELit (LString "-"))) (EVar "precAdd") (EIf (EBinOp "==" (EVar "op") (ELit (LString "*"))) (EVar "precMul") (EIf (EBinOp "==" (EVar "op") (ELit (LString "/"))) (EVar "precMul") (EIf (EVar "otherwise") (EVar "precInfix") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))))))))))))))
(DTypeSig false "isRightAssoc" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isRightAssoc" ((PLit (LString "::"))) (EVar "True"))
(DFunDef false "isRightAssoc" ((PLit (LString ":="))) (EVar "True"))
(DFunDef false "isRightAssoc" (PWild) (EVar "False"))
(DTypeSig false "exprPrec" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "exprPrec" ((PCon "ELit" (PVar "l"))) (EIf (EApp (EVar "isNegLit") (EVar "l")) (EVar "precUnary") (EVar "precAtom")))
(DFunDef false "exprPrec" ((PCon "ENumLit" (PVar "n") PWild PWild PWild)) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EVar "precUnary") (EVar "precAtom")))
(DFunDef false "exprPrec" ((PCon "EVar" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EVarId" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EMethodRef" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EDictApp" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ETuple" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EArrayLit" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EListLit" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EMapLit" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ESetLit" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EStringInterp" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ERecordCreate" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ERecordUpdate" PWild PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EVariantUpdate" PWild PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ERangeList" PWild PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ERangeArray" PWild PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ESlice" PWild PWild PWild PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EFieldAccess" PWild PWild PWild)) (EVar "precPostfix"))
(DFunDef false "exprPrec" ((PCon "EIndex" PWild PWild PWild)) (EVar "precPostfix"))
(DFunDef false "exprPrec" ((PCon "EUnOp" PWild PWild PWild)) (EVar "precUnary"))
(DFunDef false "exprPrec" ((PCon "EApp" PWild PWild)) (EVar "precApp"))
(DFunDef false "exprPrec" ((PCon "EInfix" PWild PWild PWild)) (EVar "precInfix"))
(DFunDef false "exprPrec" ((PCon "EBinOp" (PVar "op") PWild PWild PWild)) (EApp (EVar "binopPrec") (EVar "op")))
(DFunDef false "exprPrec" ((PCon "ESection" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EAsPat" PWild PWild)) (EVar "precApp"))
(DFunDef false "exprPrec" ((PCon "ELam" PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "ELet" PWild PWild PWild PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "ELetGroup" PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EIf" PWild PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EMatch" PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EBlock" PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EDo" PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EAnnot" PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EHeadAnnot" PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EGuards" PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EVarAt" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EMethodAt" PWild PWild PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EDictAt" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "exprPrec") (EVar "e")))
(DTypeSig false "stripLocE" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "stripLocE" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "stripLocE") (EVar "e")))
(DFunDef false "stripLocE" ((PVar "e")) (EVar "e"))
(DTypeSig false "isKeywordBlock" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isKeywordBlock" ((PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "EMatch" PWild PWild) () (EVar "True")) (arm (PCon "EDo" PWild PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "isBareBlock" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isBareBlock" ((PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "EBlock" PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "isGuardsBody" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isGuardsBody" ((PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "EGuards" PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "isUnitLit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isUnitLit" ((PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "ELit" (PCon "LUnit")) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "isDelimitedBody" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isDelimitedBody" ((PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "EListLit" (PCons PWild PWild)) () (EVar "True")) (arm (PCon "EArrayLit" (PCons PWild PWild)) () (EVar "True")) (arm (PCon "ETuple" (PCons PWild PWild)) () (EVar "True")) (arm (PCon "ERecordCreate" PWild (PCons PWild PWild)) () (EVar "True")) (arm (PCon "ERecordUpdate" PWild PWild PWild) () (EVar "True")) (arm (PCon "EVariantUpdate" PWild PWild PWild) () (EVar "True")) (arm (PCon "EMapLit" PWild (PCons PWild PWild)) () (EVar "True")) (arm (PCon "ESetLit" PWild (PCons PWild PWild)) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "isHuggableArg" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isHuggableArg" ((PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "ELam" PWild PWild) () (EVar "True")) (arm (PCon "EBlock" PWild) () (EVar "True")) (arm (PCon "EDo" PWild PWild) () (EVar "True")) (arm (PCon "EMatch" PWild PWild) () (EVar "True")) (arm (PCon "EIf" PWild PWild PWild) () (EVar "True")) (arm (PCon "EListLit" (PCons PWild PWild)) () (EVar "True")) (arm (PCon "EArrayLit" (PCons PWild PWild)) () (EVar "True")) (arm (PCon "ETuple" (PCons PWild PWild)) () (EVar "True")) (arm (PCon "ERecordCreate" PWild (PCons PWild PWild)) () (EVar "True")) (arm (PCon "ERecordUpdate" PWild PWild PWild) () (EVar "True")) (arm (PCon "EVariantUpdate" PWild PWild PWild) () (EVar "True")) (arm (PCon "EMapLit" PWild (PCons PWild PWild)) () (EVar "True")) (arm (PCon "ESetLit" PWild (PCons PWild PWild)) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "appHugsLast" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "appHugsLast" ((PVar "e")) (EMatch (EApp (EApp (EVar "collectApp") (EListLit)) (EVar "e")) (arm (PTuple PWild (PVar "args")) () (EMatch (EApp (EVar "last") (EVar "args")) (arm (PCon "Some" (PVar "lastArg")) () (EBinOp "&&" (EApp (EVar "isHuggableArg") (EVar "lastArg")) (EApp (EApp (EVar "allList") (EVar "isSimpleArg")) (EApp (EVar "initOf") (EVar "args"))))) (arm (PCon "None") () (EVar "False"))))))
(DTypeSig false "initOf" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "initOf" ((PList)) (EListLit))
(DFunDef false "initOf" ((PList PWild)) (EListLit))
(DFunDef false "initOf" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EApp (EVar "initOf") (EVar "xs"))))
(DTypeSig false "isSimpleArg" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isSimpleArg" ((PVar "e")) (EApp (EVar "not") (EApp (EVar "isHuggableArg") (EVar "e"))))
(DTypeSig false "isFillAtom" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isFillAtom" ((PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "ENumLit" PWild PWild PWild PWild) () (EVar "True")) (arm (PCon "ELit" PWild) () (EVar "True")) (arm (PCon "EVar" PWild) () (EVar "True")) (arm (PCon "EVarId" PWild PWild) () (EVar "True")) (arm (PCon "EMethodRef" PWild) () (EVar "True")) (arm (PCon "EDictApp" PWild) () (EVar "True")) (arm (PCon "EUnOp" (PVar "op") (PVar "inner") PWild) () (EBinOp "&&" (EBinOp "==" (EVar "op") (ELit (LString "-"))) (EApp (EVar "isFillAtom") (EVar "inner")))) (arm PWild () (EVar "False"))))
(DTypeSig false "isFillable" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Bool")))
(DFunDef false "isFillable" ((PVar "es")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "listLen") (EVar "es")) (ELit (LInt 2))) (EApp (EApp (EVar "allList") (EVar "isFillAtom")) (EVar "es"))))
(DTypeSig false "collectionDoc" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Doc"))))))
(DFunDef false "collectionDoc" ((PVar "open_") (PVar "close_") (PVar "loc") (PVar "es")) (EBlock (DoLet false false (PVar "forced") (EApp (EApp (EVar "literalForced") (EVar "loc")) (EVar "es"))) (DoLet false false (PVar "ps") (EApp (EApp (EVar "map") (EVar "exprPiece")) (EVar "es"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "not") (EVar "forced")) (EApp (EVar "isFillable") (EVar "es"))) (EApp (EVar "not") (EApp (EVar "anyCommented") (EVar "ps")))) (EApp (EApp (EApp (EVar "filledDocs") (EVar "open_")) (EVar "close_")) (EApp (EApp (EVar "map") (ELam ((PVar "e")) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e")))) (EVar "es"))) (EApp (EApp (EApp (EApp (EVar "delimitedPieces") (EVar "open_")) (EVar "close_")) (EVar "forced")) (EVar "ps"))))))
(DTypeSig false "printExpr" (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "printExpr" ((PVar "minPrec") (PVar "e")) (EBlock (DoLet false false (PVar "ep") (EApp (EVar "exprPrec") (EVar "e"))) (DoLet false false (PVar "d") (EApp (EApp (EVar "printExprRaw") (EVar "None")) (EVar "e"))) (DoExpr (EIf (EBinOp "<" (EVar "ep") (EVar "minPrec")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "text") (ELit (LString ")"))))) (EVar "d")))))
(DTypeSig false "doKeyword" (TyFun (TyCon "Bool") (TyCon "String")))
(DFunDef false "doKeyword" ((PCon "True")) (ELit (LString "defer")))
(DFunDef false "doKeyword" ((PCon "False")) (ELit (LString "do")))
(DTypeSig false "printExprRaw" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "printExprRaw" (PWild (PCon "ELit" (PVar "l"))) (EApp (EVar "printLit") (EVar "l")))
(DFunDef false "printExprRaw" (PWild (PCon "ENumLit" (PVar "n") PWild PWild (PVar "lx"))) (EApp (EVar "text") (EIf (EBinOp "==" (EVar "lx") (ELit (LString ""))) (EApp (EVar "intToString") (EVar "n")) (EVar "lx"))))
(DFunDef false "printExprRaw" (PWild (PCon "EVar" (PVar "n"))) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" (PWild (PCon "EVarId" (PVar "n") PWild)) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" (PWild (PCon "EMethodRef" (PVar "n"))) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" (PWild (PCon "EDictApp" (PVar "n"))) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" (PWild (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EVar "printAppSpine") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))))
(DFunDef false "printExprRaw" (PWild (PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "map") (EVar "printPatAtom")) (EVar "pats")))) (EApp (EApp (EVar "sepBody") (ELit (LString " =>"))) (EVar "body"))))
(DFunDef false "printExprRaw" (PWild (PCon "ELet" PWild (PVar "isf") (PVar "pat") (PVar "rhs") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "printELet") (EVar "isf")) (EVar "pat")) (EVar "rhs")) (EVar "e2")))
(DFunDef false "printExprRaw" (PWild (PCon "ELetGroup" (PVar "bindings") (PVar "body"))) (EApp (EApp (EVar "letRecInDoc") (EVar "bindings")) (EVar "body")))
(DFunDef false "printExprRaw" (PWild (PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "printIf") (EVar "c")) (EVar "t")) (EVar "e")))
(DFunDef false "printExprRaw" (PWild (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "rf"))) (EApp (EVar "printBinOp") (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "rf"))))
(DFunDef false "printExprRaw" (PWild (PCon "EUnOp" (PVar "op") (PVar "e") PWild)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EApp (EVar "printExpr") (EVar "precUnary")) (EVar "e"))))
(DFunDef false "printExprRaw" (PWild (PCon "EFieldAccess" (PVar "e") (PVar "f") PWild)) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precPostfix")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ".")))) (EApp (EVar "text") (EVar "f")))))
(DFunDef false "printExprRaw" ((PVar "loc") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EApp (EVar "bracedPieces") (ELit (LString "{"))) (EApp (EApp (EVar "fieldForced") (EVar "loc")) (EVar "fs"))) (EApp (EApp (EVar "map") (EVar "fieldAssignPiece")) (EVar "fs"))))))
(DFunDef false "printExprRaw" ((PVar "loc") (PCon "ERecordUpdate" (PVar "e") (PVar "fs") PWild)) (EBlock (DoLet false false (PVar "baseD") (EApp (EVar "noClaimDoc") (ELam (PWild) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))))) (DoLet false false (PVar "headD") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "{ ")))) (EApp (EApp (EVar "Cat") (EVar "baseD")) (EApp (EVar "text") (ELit (LString " |")))))) (DoExpr (EApp (EApp (EApp (EVar "bracedPieces") (EApp (EVar "renderFlat") (EVar "headD"))) (EApp (EApp (EVar "fieldForced") (EVar "loc")) (EVar "fs"))) (EApp (EApp (EVar "map") (EVar "fieldAssignPiece")) (EVar "fs"))))))
(DFunDef false "printExprRaw" ((PVar "loc") (PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EBlock (DoLet false false (PVar "baseD") (EApp (EVar "noClaimDoc") (ELam (PWild) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))))) (DoLet false false (PVar "headD") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "c"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " { ")))) (EApp (EApp (EVar "Cat") (EVar "baseD")) (EApp (EVar "text") (ELit (LString " |"))))))) (DoExpr (EApp (EApp (EApp (EVar "bracedPieces") (EApp (EVar "renderFlat") (EVar "headD"))) (EApp (EApp (EVar "fieldForced") (EVar "loc")) (EVar "fs"))) (EApp (EApp (EVar "map") (EVar "fieldAssignPiece")) (EVar "fs"))))))
(DFunDef false "printExprRaw" ((PVar "loc") (PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EApp (EApp (EVar "collectionDoc") (ELit (LString "[|"))) (ELit (LString "|]"))) (EVar "loc")) (EVar "es")))
(DFunDef false "printExprRaw" ((PVar "loc") (PCon "EListLit" (PVar "es"))) (EApp (EApp (EApp (EApp (EVar "collectionDoc") (ELit (LString "["))) (ELit (LString "]"))) (EVar "loc")) (EVar "es")))
(DFunDef false "printExprRaw" ((PVar "loc") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EApp (EVar "bracedPieces") (ELit (LString "{"))) (EApp (EApp (EVar "kvForced") (EVar "loc")) (EVar "kvs"))) (EApp (EApp (EVar "map") (EVar "mapKvPiece")) (EVar "kvs"))))))
(DFunDef false "printExprRaw" ((PVar "loc") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EApp (EVar "bracedPieces") (ELit (LString "{"))) (EApp (EApp (EVar "literalForced") (EVar "loc")) (EVar "es"))) (EApp (EApp (EVar "map") (EVar "exprPiece")) (EVar "es"))))))
(DFunDef false "printExprRaw" ((PVar "loc") (PCon "ETuple" (PVar "es"))) (EApp (EApp (EApp (EApp (EVar "delimitedPieces") (ELit (LString "("))) (ELit (LString ")"))) (EApp (EApp (EVar "literalForced") (EVar "loc")) (EVar "es"))) (EApp (EApp (EVar "map") (EVar "exprPiece")) (EVar "es"))))
(DFunDef false "printExprRaw" (PWild (PCon "EIndex" (PVar "e") (PVar "i") PWild)) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precPostfix")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "[")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "i"))) (EApp (EVar "text") (ELit (LString "]")))))))
(DFunDef false "printExprRaw" (PWild (PCon "EMatch" (PVar "sc") (PVar "arms"))) (EApp (EApp (EVar "printMatch") (EVar "sc")) (EVar "arms")))
(DFunDef false "printExprRaw" (PWild (PCon "EGuards" (PVar "arms"))) (EApp (EVar "printGuardArms") (EVar "arms")))
(DFunDef false "printExprRaw" (PWild (PCon "ESection" (PCon "SecBare" (PVar "op")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printExprRaw" (PWild (PCon "ESection" (PCon "SecRight" (PVar "op") (PVar "e")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))) (EApp (EVar "text") (ELit (LString ")"))))))))
(DFunDef false "printExprRaw" (PWild (PCon "ESection" (PCon "SecLeft" (PVar "e") (PVar "op")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EVar "text") (ELit (LString " _)"))))))))
(DFunDef false "printExprRaw" (PWild (PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "x"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "@")))) (EApp (EApp (EVar "printExpr") (EVar "precAtom")) (EVar "e")))))
(DFunDef false "printExprRaw" (PWild (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "printBlock") (EVar "stmts")))
(DFunDef false "printExprRaw" (PWild (PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EVar "doKeyword") (EVar "d")))) (EApp (EVar "printBlock") (EVar "stmts"))))
(DFunDef false "printExprRaw" (PWild (PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " : ")))) (EApp (EVar "printType") (EVar "t")))))
(DFunDef false "printExprRaw" (PWild (PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e")))
(DFunDef false "printExprRaw" (PWild (PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EBinOp "+" (EVar "precInfix") (ELit (LInt 1)))) (EVar "l"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " `")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "` ")))) (EApp (EApp (EVar "printExpr") (EBinOp "+" (EVar "precInfix") (ELit (LInt 1)))) (EVar "r")))))))
(DFunDef false "printExprRaw" (PWild (PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "\"")))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (EVar "interpPartDoc")) (EVar "parts")))) (EApp (EVar "text") (ELit (LString "\""))))))
(DFunDef false "printExprRaw" (PWild (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "[")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "lo"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EIf (EVar "incl") (ELit (LString "..=")) (ELit (LString ".."))))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "hi"))) (EApp (EVar "text") (ELit (LString "]"))))))))
(DFunDef false "printExprRaw" (PWild (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "[|")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "lo"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EIf (EVar "incl") (ELit (LString "..=")) (ELit (LString ".."))))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "hi"))) (EApp (EVar "text") (ELit (LString "|]"))))))))
(DFunDef false "printExprRaw" (PWild (PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "incl") PWild)) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precPostfix")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ".[")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "lo"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EIf (EVar "incl") (ELit (LString "..=")) (ELit (LString ".."))))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "hi"))) (EApp (EVar "text") (ELit (LString "]")))))))))
(DFunDef false "printExprRaw" (PWild (PCon "EVarAt" (PVar "n") PWild)) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" (PWild (PCon "EMethodAt" (PVar "n") PWild PWild PWild)) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" (PWild (PCon "EDictAt" (PVar "n") PWild)) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" (PWild (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "printExprRaw") (EApp (EVar "Some") (EVar "l"))) (EVar "e")))
(DTypeSig false "fieldAssignPiece" (TyFun (TyCon "FieldAssign") (TyCon "Piece")))
(DFunDef false "fieldAssignPiece" ((PCon "FieldAssign" (PVar "k") (PVar "v"))) (EMatch (EApp (EVar "exprSpan") (EVar "v")) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EMatch (EApp (EApp (EApp (EVar "unitStartAt") (ELit (LInt 4))) (EVar "s")) (EVar "sc")) (arm (PTuple (PVar "s2") (PVar "sc2")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s2")) (EVar "sc2")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "k"))) (EApp (EApp (EVar "sepBody") (ELit (LString " ="))) (EVar "v"))))))))))
(DTypeSig false "mapKvPiece" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyCon "Piece")))
(DFunDef false "mapKvPiece" ((PTuple (PVar "k") (PVar "v"))) (EMatch (EApp (EVar "kvSpan") (ETuple (EVar "k") (EVar "v"))) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s")) (EVar "sc")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EApp (EVar "mapKvDoc") (EVar "k")) (EVar "v")))))))
(DTypeSig false "mapKvDoc" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "mapKvDoc" ((PVar "k") (PVar "v")) (EBlock (DoLet false false (PVar "kD") (EApp (EVar "noClaimDoc") (ELam (PWild) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "k"))))) (DoExpr (EApp (EApp (EVar "Cat") (EVar "kD")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " => ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "v")))))))
(DTypeSig false "interpPartDoc" (TyFun (TyCon "InterpPart") (TyCon "Doc")))
(DFunDef false "interpPartDoc" ((PCon "InterpStr" (PVar "s"))) (EApp (EVar "text") (EApp (EVar "stringEscaped") (EVar "s"))))
(DFunDef false "interpPartDoc" ((PCon "InterpExpr" (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "\\{")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EVar "renderFlat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))))) (EApp (EVar "text") (ELit (LString "}"))))))
(DTypeSig false "stringEscaped" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stringEscaped" ((PVar "s")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "escEChars") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0)))))
(DTypeSig false "escEChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "escEChars" ((PVar "cs") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "escSOne") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EVar "escEChars") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "sepBody" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "sepBody" ((PVar "sep") (PVar "body")) (EIf (EApp (EVar "isGuardsBody") (EVar "body")) (EApp (EVar "printExprBody") (EVar "body")) (EIf (EApp (EVar "isBareBlock") (EVar "body")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "sep"))) (EApp (EVar "printExprBody") (EVar "body"))) (EIf (EApp (EVar "isKeywordBlock") (EVar "body")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EBinOp "++" (EVar "sep") (ELit (LString " "))))) (EApp (EVar "printExprBody") (EVar "body"))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "s") (EApp (EVar "spanStart") (EApp (EVar "exprSpan") (EVar "body")))) (DoLet false false (PVar "leading") (EIf (EBinOp ">" (EVar "s") (ELit (LInt 0))) (EApp (EVar "popBefore") (EVar "s")) (EListLit))) (DoExpr (EIf (EApp (EVar "isNonEmptyL") (EVar "leading")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "sep"))) (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "leadingCommentsDoc") (EVar "leading")) (EVar "s"))) (EApp (EApp (EVar "soloDoc") (EVar "body")) (ELam (PWild) (EApp (EVar "printExprBody") (EVar "body")))))))) (EIf (EBinOp "||" (EApp (EVar "isDelimitedBody") (EVar "body")) (EApp (EVar "appHugsLast") (EVar "body"))) (EApp (EApp (EVar "Hang") (EVar "sep")) (EApp (EApp (EVar "soloDoc") (EVar "body")) (ELam (PWild) (EApp (EVar "printExprBody") (EVar "body"))))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "sep"))) (EApp (EVar "group") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "soloDoc") (EVar "body")) (ELam (PWild) (EApp (EVar "printExprBody") (EVar "body")))))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "printExprBody" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "printExprBody" ((PVar "e")) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e")))
(DTypeSig false "stmtPiece" (TyFun (TyCon "DoStmt") (TyCon "Piece")))
(DFunDef false "stmtPiece" ((PVar "st")) (EMatch (EApp (EVar "stmtSpan") (EVar "st")) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EMatch (EApp (EApp (EApp (EVar "unitStartAt") (ELit (LInt 1))) (EVar "s")) (EVar "sc")) (arm (PTuple (PVar "s2") (PVar "sc2")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s2")) (EVar "sc2")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EVar "printDoStmt") (EVar "st")))))))))
(DTypeSig false "printBlock" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "Doc")))
(DFunDef false "printBlock" ((PVar "stmts")) (EApp (EVar "indentBlock") (EApp (EVar "joinHard") (EApp (EVar "pieceDocsHard") (EApp (EApp (EVar "map") (EVar "stmtPiece")) (EVar "stmts"))))))
(DTypeSig false "printDoStmt" (TyFun (TyCon "DoStmt") (TyCon "Doc")))
(DFunDef false "printDoStmt" ((PCon "DoBind" (PVar "pat") (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPat") (EVar "pat"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " <- ")))) (EApp (EVar "printExprBody") (EVar "e")))))
(DFunDef false "printDoStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "printExprBody") (EVar "e")))
(DFunDef false "printDoStmt" ((PCon "DoLet" (PVar "isMut") PWild (PVar "pat") (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "let ")))) (EApp (EApp (EVar "Cat") (EIf (EVar "isMut") (EApp (EVar "text") (ELit (LString "mut "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPat") (EVar "pat"))) (EApp (EApp (EVar "sepBody") (ELit (LString " ="))) (EVar "e"))))))
(DFunDef false "printDoStmt" ((PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "x"))) (EApp (EApp (EVar "sepBody") (ELit (LString " ="))) (EVar "e"))))
(DFunDef false "printDoStmt" ((PCon "DoFieldAssign" (PVar "x") (PVar "fields") (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "x"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ".")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "fields")))) (EApp (EApp (EVar "sepBody") (ELit (LString " ="))) (EVar "e"))))))
(DTypeSig false "printELet" (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Doc"))))))
(DFunDef false "printELet" ((PCon "True") (PCon "PVar" (PVar "f") PWild) (PVar "rhs") (PVar "e2")) (EMatch (EApp (EApp (EVar "unwrapLams") (EListLit)) (EVar "rhs")) (arm (PTuple (PVar "args") (PVar "body")) () (EBlock (DoLet false false (PVar "headD") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "let ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "f"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "args")))))) (DoExpr (EApp (EApp (EApp (EVar "letInDoc") (EVar "headD")) (EVar "body")) (EVar "e2")))))))
(DFunDef false "printELet" (PWild (PVar "pat") (PVar "e1") (PVar "e2")) (EApp (EApp (EApp (EVar "letInDoc") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "let ")))) (EApp (EVar "printPat") (EVar "pat")))) (EVar "e1")) (EVar "e2")))
(DTypeSig false "letInDoc" (TyFun (TyCon "Doc") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Doc")))))
(DFunDef false "letInDoc" ((PVar "headD") (PVar "rhs") (PVar "e2")) (EBlock (DoLet false false (PVar "rhsD") (EApp (EVar "noClaimDoc") (ELam (PWild) (EApp (EVar "printExprBody") (EVar "rhs"))))) (DoLet false false (PVar "bodyD") (EApp (EApp (EVar "soloDoc") (EVar "e2")) (ELam (PWild) (EApp (EVar "printExprBody") (EVar "e2"))))) (DoExpr (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EVar "headD")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "Cat") (EVar "rhsD")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " in")))) (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EVar "bodyD")))))))))))
(DTypeSig false "unwrapLams" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "unwrapLams" ((PVar "acc") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EVar "unwrapLams") (EVar "acc")) (EVar "e")))
(DFunDef false "unwrapLams" ((PVar "acc") (PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "unwrapLams") (EBinOp "++" (EVar "acc") (EVar "pats"))) (EVar "body")))
(DFunDef false "unwrapLams" ((PVar "acc") (PVar "body")) (ETuple (EVar "acc") (EVar "body")))
(DTypeSig false "letRecInDoc" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "letRecInDoc" ((PList) (PVar "body")) (EApp (EVar "printExprBody") (EVar "body")))
(DFunDef false "letRecInDoc" ((PCons (PCon "LetBind" (PVar "name") (PVar "clauses")) (PVar "rest")) (PVar "body")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "letRecInDoc") (EVar "rest")) (EVar "body"))) (DoExpr (EMatch (EVar "clauses") (arm (PList (PCon "FunClause" (PVar "pats") (PVar "rhs"))) () (EBlock (DoLet false false (PVar "headD") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "let rec ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "pats")))))) (DoLet false false (PVar "rhsD") (EApp (EApp (EVar "withBound") (EApp (EVar "spanStart") (EApp (EVar "exprSpan") (EVar "body")))) (ELam (PWild) (EApp (EVar "printExprBody") (EVar "rhs"))))) (DoExpr (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EVar "headD")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "Cat") (EVar "rhsD")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " in")))) (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EVar "inner"))))))))))) (arm PWild () (EVar "inner"))))))
(DTypeSig false "printIf" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Doc")))))
(DFunDef false "printIf" ((PVar "c") (PVar "t") (PVar "els")) (EApp (EVar "group") (EApp (EApp (EApp (EVar "ifLadder") (EVar "c")) (EVar "t")) (EVar "els"))))
(DTypeSig false "ifLadder" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Doc")))))
(DFunDef false "ifLadder" ((PVar "c") (PVar "t") (PVar "els")) (EBlock (DoLet false false (PVar "condD") (EApp (EVar "noClaimDoc") (ELam (PWild) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "c"))))) (DoLet false false (PVar "thenD") (EApp (EApp (EVar "withBound") (EApp (EVar "spanStart") (EApp (EVar "exprSpan") (EVar "els")))) (ELam (PWild) (EApp (EApp (EVar "ifBranch") (ELit (LString "then"))) (EVar "t"))))) (DoLet false false (PVar "elseD") (EApp (EVar "ifElsePart") (EVar "els"))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "if ")))) (EApp (EApp (EVar "Cat") (EVar "condD")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "Cat") (EVar "thenD")) (EVar "elseD"))))))))
(DTypeSig false "ifElsePart" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "ifElsePart" ((PVar "els")) (EIf (EApp (EVar "isUnitLit") (EVar "els")) (EVar "Nil") (EIf (EVar "otherwise") (EMatch (EApp (EVar "stripLocE") (EVar "els")) (arm (PCon "EIf" (PVar "c2") (PVar "t2") (PVar "e2")) () (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "else ")))) (EApp (EApp (EApp (EVar "ifLadder") (EVar "c2")) (EVar "t2")) (EVar "e2"))))) (arm PWild () (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "ifBranch") (ELit (LString "else"))) (EVar "els"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ifBranch" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "ifBranch" ((PVar "kw") (PVar "b")) (EIf (EApp (EVar "isBareBlock") (EVar "b")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "kw"))) (EApp (EVar "printExprBody") (EVar "b"))) (EIf (EApp (EVar "isKeywordBlock") (EVar "b")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "kw"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printExprBody") (EVar "b")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "kw"))) (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "soloDoc") (EVar "b")) (ELam (PWild) (EApp (EVar "printExprBody") (EVar "b"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "printMatch" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Doc"))))
(DFunDef false "printMatch" ((PVar "sc") (PVar "arms")) (EBlock (DoLet false false (PVar "scD") (EApp (EVar "noClaimDoc") (ELam (PWild) (EApp (EVar "matchScrutineeDoc") (EVar "sc"))))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "match ")))) (EApp (EApp (EVar "Cat") (EVar "scD")) (EApp (EVar "printMatchArms") (EVar "arms")))))))
(DTypeSig false "matchScrutineeDoc" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "matchScrutineeDoc" ((PVar "sc")) (EBlock (DoLet false false (PVar "d") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "sc"))) (DoExpr (EIf (EBinOp ">=" (EApp (EVar "exprPrec") (EVar "sc")) (EVar "precAtom")) (EVar "d") (EMatch (EApp (EVar "exprSpan") (EVar "sc")) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EIf (EBinOp "&&" (EBinOp ">" (EVar "s") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EVar "pendingInside") (EVar "s")) (EVar "sc")) (EVar "en")) (EVar "ec"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "text") (ELit (LString ")"))))) (EApp (EApp (EVar "Alt") (EApp (EVar "text") (EApp (EVar "renderFlat") (EVar "d")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "text") (ELit (LString ")")))))))))))))
(DTypeSig false "armPiece" (TyFun (TyCon "Arm") (TyCon "Piece")))
(DFunDef false "armPiece" ((PVar "arm")) (EMatch (EApp (EVar "armSpan") (EVar "arm")) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EMatch (EApp (EApp (EApp (EVar "unitStartAt") (ELit (LInt 0))) (EVar "s")) (EVar "sc")) (arm (PTuple (PVar "s2") (PVar "sc2")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s2")) (EVar "sc2")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EVar "matchArmDoc") (EVar "arm")))))))))
(DTypeSig false "unitStartsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "unitStartsRef" () (EApp (EVar "Ref") (EApp (EVar "arrayFromList") (EListLit))))
(DTypeSig true "setUnitStarts" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int"))) (TyCon "Unit")))
(DFunDef false "setUnitStarts" ((PVar "ps")) (EApp (EApp (EVar "setRef") (EVar "unitStartsRef")) (EApp (EVar "arrayFromList") (EApp (EApp (EVar "sortBy") (EVar "cmpUnit")) (EVar "ps")))))
(DTypeSig false "cmpUnit" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyCon "Ordering"))))
(DFunDef false "cmpUnit" ((PTuple (PVar "k1") (PVar "l1") (PVar "c1")) (PTuple (PVar "k2") (PVar "l2") (PVar "c2"))) (EIf (EBinOp "/=" (EVar "k1") (EVar "k2")) (EApp (EApp (EVar "compare") (EVar "k1")) (EVar "k2")) (EApp (EApp (EVar "cmpPos") (ETuple (EVar "l1") (EVar "c1"))) (ETuple (EVar "l2") (EVar "c2")))))
(DTypeSig false "unitUpperBound" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))))
(DFunDef false "unitUpperBound" ((PVar "arr") (PVar "kind") (PVar "line") (PVar "col") (PVar "lo") (PVar "hi")) (EIf (EBinOp ">=" (EVar "lo") (EVar "hi")) (EVar "lo") (EBlock (DoLet false false (PVar "mid") (EBinOp "/" (EBinOp "+" (EVar "lo") (EVar "hi")) (ELit (LInt 2)))) (DoExpr (EMatch (EApp (EApp (EVar "index") (EVar "arr")) (EVar "mid")) (arm (PTuple (PVar "k") (PVar "l") (PVar "c")) () (EBlock (DoLet false false (PVar "le") (EBinOp "||" (EBinOp "<" (EVar "k") (EVar "kind")) (EBinOp "&&" (EBinOp "==" (EVar "k") (EVar "kind")) (EBinOp "||" (EBinOp "<" (EVar "l") (EVar "line")) (EBinOp "&&" (EBinOp "==" (EVar "l") (EVar "line")) (EBinOp "<=" (EVar "c") (EVar "col"))))))) (DoExpr (EIf (EVar "le") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "unitUpperBound") (EVar "arr")) (EVar "kind")) (EVar "line")) (EVar "col")) (EBinOp "+" (EVar "mid") (ELit (LInt 1)))) (EVar "hi")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "unitUpperBound") (EVar "arr")) (EVar "kind")) (EVar "line")) (EVar "col")) (EVar "lo")) (EVar "mid")))))))))))
(DTypeSig false "unitStartAt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "unitStartAt" ((PVar "kind") (PVar "line") (PVar "col")) (EIf (EBinOp "==" (EVar "line") (ELit (LInt 0))) (ETuple (ELit (LInt 0)) (ELit (LInt 0))) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "unitStartsRef"))) (DoLet false false (PVar "i") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "unitUpperBound") (EVar "arr")) (EVar "kind")) (EVar "line")) (EVar "col")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EIf (EBinOp "==" (EVar "i") (ELit (LInt 0))) (ETuple (EVar "line") (EVar "col")) (EMatch (EApp (EApp (EVar "index") (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (arm (PTuple (PVar "k") (PVar "l") (PVar "c")) () (EIf (EBinOp "==" (EVar "k") (EVar "kind")) (ETuple (EVar "l") (EVar "c")) (ETuple (EVar "line") (EVar "col"))))))))))
(DTypeSig false "printMatchArms" (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Doc")))
(DFunDef false "printMatchArms" ((PVar "arms")) (EApp (EVar "indentBlock") (EApp (EVar "joinHard") (EApp (EVar "pieceDocsHard") (EApp (EApp (EVar "map") (EVar "armPiece")) (EVar "arms"))))))
(DTypeSig false "matchArmDoc" (TyFun (TyCon "Arm") (TyCon "Doc")))
(DFunDef false "matchArmDoc" ((PCon "Arm" (PVar "pat") (PVar "guards") (PVar "body"))) (EBlock (DoLet false false (PVar "guardsD") (EApp (EVar "noClaimDoc") (ELam (PWild) (EApp (EVar "matchGuardsDoc") (EVar "guards"))))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "printPatArm") (EVar "pat"))) (EApp (EApp (EVar "Cat") (EVar "guardsD")) (EApp (EApp (EVar "sepBody") (ELit (LString " =>"))) (EVar "body")))))))
(DTypeSig false "matchGuardsDoc" (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyCon "Doc")))
(DFunDef false "matchGuardsDoc" ((PList)) (EVar "Nil"))
(DFunDef false "matchGuardsDoc" ((PVar "guards")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " if ")))) (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EVar "guardDoc")) (EVar "guards")))))
(DTypeSig false "guardDoc" (TyFun (TyCon "Guard") (TyCon "Doc")))
(DFunDef false "guardDoc" ((PCon "GBool" (PVar "g"))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "g")))
(DFunDef false "guardDoc" ((PCon "GBind" (PVar "gp") (PVar "g"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPat") (EVar "gp"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " <- ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "g")))))
(DTypeSig false "guardArmPiece" (TyFun (TyCon "GuardArm") (TyCon "Piece")))
(DFunDef false "guardArmPiece" ((PVar "arm")) (EMatch (EApp (EVar "guardArmSpan") (EVar "arm")) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s")) (EVar "sc")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EVar "guardArmDoc") (EVar "arm")))))))
(DTypeSig false "printGuardArms" (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyCon "Doc")))
(DFunDef false "printGuardArms" ((PVar "arms")) (EApp (EVar "indentBlock") (EApp (EVar "joinHard") (EApp (EVar "pieceDocsHard") (EApp (EApp (EVar "map") (EVar "guardArmPiece")) (EVar "arms"))))))
(DTypeSig false "guardArmDoc" (TyFun (TyCon "GuardArm") (TyCon "Doc")))
(DFunDef false "guardArmDoc" ((PCon "GuardArm" (PVar "guards") (PVar "body"))) (EBlock (DoLet false false (PVar "hd") (EApp (EVar "noClaimDoc") (ELam (PWild) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "| ")))) (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EVar "guardDoc")) (EVar "guards"))))))) (DoExpr (EApp (EApp (EVar "Cat") (EVar "hd")) (EApp (EApp (EVar "sepBody") (ELit (LString " ="))) (EVar "body"))))))
(DTypeSig false "printBinOp" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "printBinOp" ((PVar "e")) (EBlock (DoLet false false (PVar "op") (EApp (EVar "topOp") (EVar "e"))) (DoLet false false (PVar "prec") (EApp (EVar "binopPrec") (EVar "op"))) (DoExpr (EIf (EBinOp "==" (EVar "op") (ELit (LString ":="))) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "EBinOp" PWild (PVar "l") (PVar "r") PWild) () (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EBinOp "+" (EVar "precAssign") (ELit (LInt 1)))) (EVar "l"))) (EApp (EApp (EVar "sepBody") (ELit (LString " :="))) (EVar "r")))) (arm PWild () (EVar "Nil"))) (EBlock (DoLet false false (PVar "ra") (EApp (EVar "isRightAssoc") (EVar "op"))) (DoLet false false (PVar "headPrec") (EIf (EVar "ra") (EBinOp "+" (EVar "prec") (ELit (LInt 1))) (EVar "prec"))) (DoLet false false (PVar "rightPrec") (EBinOp "+" (EVar "prec") (ELit (LInt 1)))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "collectChain") (EVar "prec")) (EListLit)) (EVar "e")) (arm (PTuple (PVar "head") (PVar "rights")) () (EBlock (DoLet false false (PVar "headPiece") (EMatch (EApp (EVar "exprSpan") (EVar "head")) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s")) (EVar "sc")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EApp (EVar "printOperand") (EVar "headPrec")) (EVar "head"))))))) (DoLet false false (PVar "ps") (EBinOp "::" (EVar "headPiece") (EApp (EApp (EVar "map") (ELam ((PVar "r")) (EApp (EApp (EVar "rightPiece") (EVar "rightPrec")) (EVar "r")))) (EVar "rights")))) (DoLet false false (PVar "outs") (EApp (EApp (EVar "pieceDocs") (EVar "noSep")) (EVar "ps"))) (DoExpr (EApp (EVar "group") (EApp (EVar "nest") (EApp (EVar "joinLine") (EVar "outs"))))))))))))))
(DTypeSig false "topOp" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "topOp" ((PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "EBinOp" (PVar "op") PWild PWild PWild) () (EVar "op")) (arm PWild () (ELit (LString "")))))
(DTypeSig false "rightPiece" (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "String") (TyCon "Expr")) (TyCon "Piece"))))
(DFunDef false "rightPiece" ((PVar "rightPrec") (PTuple (PVar "o") (PVar "r"))) (EMatch (EApp (EVar "exprSpan") (EVar "r")) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s")) (EVar "sc")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "o"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "printOperand") (EVar "rightPrec")) (EVar "r")))))))))
(DTypeSig false "printOperand" (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "printOperand" ((PVar "prec") (PVar "e")) (EApp (EApp (EVar "printExpr") (EVar "prec")) (EVar "e")))
(DTypeSig false "collectChain" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr"))) (TyFun (TyCon "Expr") (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr"))))))))
(DFunDef false "collectChain" ((PVar "prec") (PVar "acc") (PCon "ELoc" (PVar "l") (PVar "e"))) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "EBinOp" (PVar "op") PWild PWild PWild) () (EIf (EBinOp "==" (EApp (EVar "binopPrec") (EVar "op")) (EVar "prec")) (EApp (EApp (EApp (EVar "collectChain") (EVar "prec")) (EVar "acc")) (EVar "e")) (ETuple (EApp (EApp (EVar "ELoc") (EVar "l")) (EVar "e")) (EVar "acc")))) (arm PWild () (ETuple (EApp (EApp (EVar "ELoc") (EVar "l")) (EVar "e")) (EVar "acc")))))
(DFunDef false "collectChain" ((PVar "prec") (PVar "acc") (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "rf"))) (EIf (EBinOp "/=" (EApp (EVar "binopPrec") (EVar "op")) (EVar "prec")) (ETuple (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "rf")) (EVar "acc")) (EIf (EApp (EVar "isRightAssoc") (EVar "op")) (ETuple (EVar "l") (EApp (EApp (EApp (EVar "rightSpine") (EVar "prec")) (EVar "op")) (EVar "r"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "collectChain") (EVar "prec")) (EBinOp "::" (ETuple (EVar "op") (EVar "r")) (EVar "acc"))) (EVar "l")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "collectChain" (PWild (PVar "acc") (PVar "head")) (ETuple (EVar "head") (EVar "acc")))
(DTypeSig false "rightSpine" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr")))))))
(DFunDef false "rightSpine" ((PVar "prec") (PVar "opBefore") (PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "EBinOp" (PVar "op") (PVar "l2") (PVar "r2") PWild) () (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "binopPrec") (EVar "op")) (EVar "prec")) (EApp (EVar "isRightAssoc") (EVar "op"))) (EBinOp "::" (ETuple (EVar "opBefore") (EVar "l2")) (EApp (EApp (EApp (EVar "rightSpine") (EVar "prec")) (EVar "op")) (EVar "r2"))) (EListLit (ETuple (EVar "opBefore") (EVar "e"))))) (arm PWild () (EListLit (ETuple (EVar "opBefore") (EVar "e"))))))
(DTypeSig false "printAppSpine" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "printAppSpine" ((PVar "e")) (EMatch (EApp (EApp (EVar "collectApp") (EListLit)) (EVar "e")) (arm (PTuple (PVar "head") (PList)) () (EApp (EApp (EVar "printExpr") (EVar "precApp")) (EVar "head"))) (arm (PTuple (PVar "head") (PVar "args")) () (EBlock (DoLet false false (PVar "headD") (EApp (EApp (EVar "printExpr") (EVar "precApp")) (EVar "head"))) (DoLet false false (PVar "ps") (EApp (EApp (EVar "map") (ELam ((PVar "a")) (EApp (EApp (EVar "argPiece") (EVar "head")) (EVar "a")))) (EVar "args"))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "appHugsLast") (EVar "e")) (EApp (EVar "not") (EApp (EVar "anyCommented") (EVar "ps")))) (EBlock (DoLet false false (PVar "initOuts") (EApp (EApp (EVar "pieceDocs") (EVar "noSep")) (EApp (EApp (EVar "map") (ELam ((PVar "a")) (EApp (EApp (EVar "argPiece") (EVar "head")) (EVar "a")))) (EApp (EVar "initOf") (EVar "args"))))) (DoLet false false (PVar "initDocs") (EApp (EApp (EVar "map") (EVar "pieceOutDoc")) (EVar "initOuts"))) (DoExpr (EMatch (EApp (EVar "last") (EVar "args")) (arm (PCon "Some" (PVar "lastArg")) () (EMatch (EApp (EApp (EVar "lastArgDocs") (EVar "head")) (EVar "lastArg")) (arm (PTuple (PVar "openD") (PVar "closedD")) () (EBlock (DoLet false false (PVar "explode") (EApp (EVar "group") (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EVar "headD")) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EApp (EApp (EVar "Cat") (EVar "Line")) (EVar "d")))) (EBinOp "++" (EVar "initDocs") (EListLit (EVar "closedD"))))))))) (DoLet false false (PVar "hug") (EApp (EApp (EVar "Cat") (EVar "headD")) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EVar "d")))) (EVar "initDocs")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EVar "openD"))))) (DoExpr (EApp (EVar "group") (EApp (EApp (EVar "Alt") (EVar "hug")) (EVar "explode")))))))) (arm (PCon "None") () (EVar "headD"))))) (EBlock (DoLet false false (PVar "outs") (EApp (EApp (EVar "pieceDocs") (EVar "noSep")) (EVar "ps"))) (DoExpr (EApp (EVar "group") (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EVar "headD")) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "o")) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "pieceOutDoc") (EVar "o"))))) (EVar "outs"))))))))))))))
(DTypeSig false "lastArgDocs" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyTuple (TyCon "Doc") (TyCon "Doc")))))
(DFunDef false "lastArgDocs" ((PVar "head") (PVar "arg")) (EMatch (EApp (EVar "stripLocE") (EVar "arg")) (arm (PCon "ELam" (PVar "pats") (PVar "body")) () (EBlock (DoLet false false (PVar "patsD") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "map") (EVar "printPatAtom")) (EVar "pats")))) (DoLet false false (PVar "bodyPart") (EApp (EApp (EVar "sepBody") (ELit (LString " =>"))) (EVar "body"))) (DoLet false false (PVar "openD") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EVar "patsD")) (EApp (EApp (EVar "Cat") (EApp (EVar "openBody") (EVar "bodyPart"))) (EApp (EVar "text") (ELit (LString ")"))))))) (DoLet false false (PVar "closedD") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EVar "patsD")) (EApp (EApp (EVar "Cat") (EVar "bodyPart")) (EApp (EVar "text") (ELit (LString ")"))))))) (DoExpr (ETuple (EVar "openD") (EVar "closedD"))))) (arm PWild () (EBlock (DoLet false false (PVar "d") (EApp (EApp (EVar "appArgDoc") (EVar "head")) (EVar "arg"))) (DoExpr (ETuple (EApp (EVar "openDoc") (EVar "d")) (EVar "d")))))))
(DTypeSig false "openBody" (TyFun (TyCon "Doc") (TyCon "Doc")))
(DFunDef false "openBody" ((PCon "Cat" (PVar "s") (PCon "Group" (PVar "g")))) (EApp (EApp (EVar "Cat") (EVar "s")) (EVar "g")))
(DFunDef false "openBody" ((PCon "Hang" (PVar "sep") (PVar "d"))) (EApp (EApp (EVar "hangInline") (EVar "sep")) (EVar "d")))
(DFunDef false "openBody" ((PVar "d")) (EVar "d"))
(DTypeSig false "openDoc" (TyFun (TyCon "Doc") (TyCon "Doc")))
(DFunDef false "openDoc" ((PCon "Group" (PVar "d"))) (EVar "d"))
(DFunDef false "openDoc" ((PCon "Cat" (PCon "Text" (PLit (LString "("))) (PCon "Cat" (PCon "Group" (PVar "d")) (PCon "Text" (PLit (LString ")")))))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "openDoc" ((PCon "Cat" (PCon "Text" (PLit (LString "("))) (PCon "Cat" (PVar "d") (PCon "Text" (PLit (LString ")")))))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "openDoc" ((PVar "d")) (EVar "d"))
(DTypeSig false "argPiece" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Piece"))))
(DFunDef false "argPiece" ((PVar "head") (PVar "arg")) (EMatch (EApp (EVar "exprSpan") (EVar "arg")) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s")) (EVar "sc")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EApp (EVar "appArgDoc") (EVar "head")) (EVar "arg")))))))
(DTypeSig false "appArgDoc" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "appArgDoc" ((PVar "head") (PVar "x")) (EIf (EBinOp "&&" (EApp (EVar "isTightNegLitArg") (EVar "x")) (EApp (EVar "not") (EApp (EVar "headIsNumericHead") (EApp (EVar "stripLocE") (EVar "head"))))) (EApp (EApp (EVar "printExprRaw") (EVar "None")) (EApp (EVar "stripLocE") (EVar "x"))) (EIf (EApp (EVar "isTightDerefArg") (EVar "x")) (EApp (EApp (EVar "printExprRaw") (EVar "None")) (EApp (EVar "stripLocE") (EVar "x"))) (EApp (EApp (EVar "printExpr") (EVar "precPostfix")) (EVar "x")))))
(DTypeSig false "isTightDerefArg" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isTightDerefArg" ((PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "EUnOp" (PLit (LString "!")) PWild PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "isTightNegLitArg" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isTightNegLitArg" ((PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "ELit" (PVar "l")) () (EApp (EVar "isNegLit") (EVar "l"))) (arm (PCon "ENumLit" (PVar "n") PWild PWild PWild) () (EBinOp "<" (EVar "n") (ELit (LInt 0)))) (arm PWild () (EVar "False"))))
(DTypeSig false "headIsNumericHead" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "headIsNumericHead" ((PCon "ENumLit" PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "headIsNumericHead" ((PCon "ELit" (PCon "LInt" PWild))) (EVar "True"))
(DFunDef false "headIsNumericHead" ((PCon "ELit" (PCon "LFloat" PWild))) (EVar "True"))
(DFunDef false "headIsNumericHead" (PWild) (EVar "False"))
(DTypeSig false "collectApp" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "collectApp" ((PVar "acc") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "collectApp") (EBinOp "::" (EVar "x") (EVar "acc"))) (EVar "f")))
(DFunDef false "collectApp" ((PVar "acc") (PCon "ELoc" (PVar "l") (PVar "e"))) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "EApp" (PVar "f") (PVar "x")) () (EApp (EApp (EVar "collectApp") (EVar "acc")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))) (arm PWild () (ETuple (EApp (EApp (EVar "ELoc") (EVar "l")) (EVar "e")) (EVar "acc")))))
(DFunDef false "collectApp" ((PVar "acc") (PVar "head")) (ETuple (EVar "head") (EVar "acc")))
(DTypeSig false "printDefRhs" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "printDefRhs" ((PVar "body")) (EMatch (EApp (EVar "stripLocE") (EVar "body")) (arm (PCon "EGuards" (PVar "arms")) () (EApp (EVar "printGuardArms") (EVar "arms"))) (arm (PCon "ELetGroup" (PVar "binds") (PVar "inner")) () (EApp (EApp (EVar "printWhere") (EVar "binds")) (EVar "inner"))) (arm PWild () (EApp (EApp (EVar "sepBody") (ELit (LString " ="))) (EVar "body")))))
(DTypeSig false "printWhere" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "printWhere" ((PVar "binds") (PVar "inner")) (EBlock (DoLet false false (PVar "bodyD") (EIf (EApp (EVar "isGuardsBody") (EVar "inner")) (EApp (EVar "printGuardArms") (EApp (EVar "guardArmsOf") (EVar "inner"))) (EApp (EApp (EVar "sepBody") (ELit (LString " ="))) (EVar "inner")))) (DoExpr (EApp (EApp (EVar "Cat") (EVar "bodyD")) (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "where")))) (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EVar "letGroupClauses") (EVar "binds"))))))))))
(DTypeSig false "guardArmsOf" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "GuardArm"))))
(DFunDef false "guardArmsOf" ((PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "EGuards" (PVar "arms")) () (EVar "arms")) (arm PWild () (EListLit))))
(DTypeSig false "letGroupClauses" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "Doc")))
(DFunDef false "letGroupClauses" ((PVar "bindings")) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EVar "joinHard") (EApp (EVar "pieceDocsHard") (EApp (EVar "clausePieces") (EVar "bindings"))))))
(DTypeSig false "clausePieces" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyCon "Piece"))))
(DFunDef false "clausePieces" ((PList)) (EListLit))
(DFunDef false "clausePieces" ((PCons (PCon "LetBind" (PVar "name") (PVar "clauses")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EVar "map") (ELam ((PVar "c")) (EApp (EApp (EVar "clausePiece") (EVar "name")) (EVar "c")))) (EVar "clauses")) (EApp (EVar "clausePieces") (EVar "rest"))))
(DTypeSig false "clausePiece" (TyFun (TyCon "String") (TyFun (TyCon "FunClause") (TyCon "Piece"))))
(DFunDef false "clausePiece" ((PVar "name") (PCon "FunClause" (PVar "pats") (PVar "rhs"))) (EMatch (EApp (EVar "clauseSpan") (EApp (EApp (EVar "FunClause") (EVar "pats")) (EVar "rhs"))) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EMatch (EApp (EApp (EApp (EVar "unitStartAt") (ELit (LInt 3))) (EVar "s")) (EVar "sc")) (arm (PTuple (PVar "s2") (PVar "sc2")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s2")) (EVar "sc2")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "defHeader") (EVar "name")) (EVar "pats"))) (EApp (EVar "printDefRhs") (EVar "rhs"))))))))))
(DTypeSig false "printUsePath" (TyFun (TyCon "UsePath") (TyFun (TyCon "Bool") (TyCon "Doc"))))
(DFunDef false "printUsePath" ((PCon "UseName" (PVar "names")) PWild) (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "names"))))
(DFunDef false "printUsePath" ((PCon "UseGroup" (PVar "names") (PVar "members")) (PVar "forced")) (EBlock (DoLet false false (PVar "items") (EApp (EApp (EVar "map") (EVar "useMemberDoc")) (EVar "members"))) (DoLet false false (PVar "body") (EIf (EVar "forced") (EApp (EApp (EApp (EApp (EVar "delimitedPieces") (ELit (LString "{"))) (ELit (LString "}"))) (EVar "True")) (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELam (PWild) (EVar "d"))))) (EVar "items"))) (EApp (EApp (EApp (EVar "filledDocs") (ELit (LString "{"))) (ELit (LString "}"))) (EVar "items")))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "names")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ".")))) (EVar "body"))))))
(DFunDef false "printUsePath" ((PCon "UseWild" (PVar "names")) PWild) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "names")))) (EApp (EVar "text") (ELit (LString ".*")))))
(DFunDef false "printUsePath" ((PCon "UseAlias" (PVar "names") (PVar "alias")) PWild) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "names")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " as ")))) (EApp (EVar "text") (EVar "alias")))))
(DTypeSig false "useMemberDoc" (TyFun (TyCon "UseMember") (TyCon "Doc")))
(DFunDef false "useMemberDoc" ((PCon "UseMember" (PVar "n") (PVar "allCtors") PWild (PVar "alias"))) (EBlock (DoLet false false (PVar "base") (EIf (EVar "allCtors") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EVar "text") (ELit (LString "(..)")))) (EApp (EVar "text") (EVar "n")))) (DoExpr (EMatch (EVar "alias") (arm (PCon "Some" (PVar "a")) () (EApp (EApp (EVar "Cat") (EVar "base")) (EApp (EVar "text") (EBinOp "++" (EBinOp "++" (ELit (LString " as ")) (EApp (EVar "display") (EVar "a"))) (ELit (LString "")))))) (arm (PCon "None") () (EVar "base"))))))
(DTypeSig false "printVariant" (TyFun (TyCon "Variant") (TyCon "Doc")))
(DFunDef false "printVariant" ((PCon "Variant" (PVar "name") (PCon "ConPos" (PVar "tys")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "t")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printTypeAtom") (EVar "t"))))) (EVar "tys")))))
(DFunDef false "printVariant" ((PCon "Variant" (PVar "name") (PCon "ConNamed" (PVar "fields") (PVar "nameOmitted")))) (EApp (EApp (EApp (EApp (EVar "recordVariantDoc") (EVar "name")) (EVar "fields")) (EVar "nameOmitted")) (EListLit)))
(DTypeSig false "recordVariantDoc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyCon "Doc"))))))
(DFunDef false "recordVariantDoc" ((PVar "name") (PVar "fields") (PVar "nameOmitted") (PVar "derives")) (EBlock (DoLet false false (PVar "namePart") (EIf (EVar "nameOmitted") (EApp (EVar "text") (ELit (LString "{"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EVar "text") (ELit (LString " {")))))) (DoLet false false (PVar "sep") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ",")))) (EVar "Line"))) (DoLet false false (PVar "derivesTail") (EIf (EApp (EVar "isEmptyL") (EVar "derives")) (EVar "Nil") (EApp (EApp (EVar "FlatAlt") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "printDerives") (EVar "derives"))))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printDerives") (EVar "derives")))))) (DoExpr (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EVar "namePart")) (EApp (EApp (EVar "Cat") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EVar "sep")) (EApp (EApp (EVar "map") (EVar "fieldTyDoc")) (EVar "fields")))) (EVar "trailingCommaDoc"))))) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "}")))) (EVar "derivesTail")))))))))
(DTypeSig false "fieldTyDoc" (TyFun (TyCon "Field") (TyCon "Doc")))
(DFunDef false "fieldTyDoc" ((PCon "Field" (PVar "fn") (PVar "ft"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "fn"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " : ")))) (EApp (EVar "printType") (EVar "ft")))))
(DTypeSig true "printNamedFieldData" (TyFun (TyCon "DataVis") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyCon "Doc"))))))))
(DFunDef false "printNamedFieldData" ((PVar "vis") (PVar "n") (PVar "params") (PVar "kinds") (PList (PCon "Variant" (PVar "cname") (PCon "ConNamed" (PVar "fields") (PVar "nameOmitted")))) (PVar "derives")) (EBlock (DoLet false false (PVar "eqPart") (EIf (EVar "nameOmitted") (EApp (EVar "text") (ELit (LString " = {"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "cname"))) (EApp (EVar "text") (ELit (LString " {"))))))) (DoLet false false (PVar "head") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "data ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "tyParamsDoc") (EVar "params")) (EVar "kinds"))) (EVar "eqPart"))))) (DoLet false false (PVar "body") (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "f")) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "Cat") (EApp (EVar "fieldTyDoc") (EVar "f"))) (EApp (EVar "text") (ELit (LString ","))))))) (EVar "fields"))))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EVar "text") (ELit (LString "}")))))) (DoLet false false (PVar "deriveDoc") (EIf (EApp (EVar "isEmptyL") (EVar "derives")) (EVar "Nil") (EApp (EVar "indentBlock") (EApp (EVar "printDerives") (EVar "derives"))))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "visPrefix") (EVar "vis"))) (EApp (EApp (EVar "Cat") (EVar "head")) (EApp (EApp (EVar "Cat") (EVar "body")) (EVar "deriveDoc")))))))
(DFunDef false "printNamedFieldData" ((PVar "vis") (PVar "n") (PVar "params") (PVar "kinds") (PVar "variants") (PVar "derives")) (EApp (EVar "printDecl") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dDataUnresolved") (EVar "vis")) (EVar "n")) (EVar "params")) (EVar "kinds")) (EVar "variants")) (EVar "derives"))))
(DTypeSig false "tyParamsDoc" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyCon "Doc"))))
(DFunDef false "tyParamsDoc" ((PVar "params") (PVar "kinds")) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "w")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "text") (EVar "w"))))) (EApp (EApp (EVar "tyParamSources") (EVar "params")) (EVar "kinds")))))
(DTypeSig false "printDerives" (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyCon "Doc")))
(DFunDef false "printDerives" ((PList)) (EVar "Nil"))
(DFunDef false "printDerives" ((PVar "derives")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "deriving (")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "deriveRefName")) (EVar "derives"))))) (EApp (EVar "text") (ELit (LString ")"))))))
(DTypeSig false "visPrefix" (TyFun (TyCon "DataVis") (TyCon "Doc")))
(DFunDef false "visPrefix" ((PCon "VisPublic")) (EApp (EVar "text") (ELit (LString "public export "))))
(DFunDef false "visPrefix" ((PCon "VisAbstract")) (EApp (EVar "text") (ELit (LString "export "))))
(DFunDef false "visPrefix" ((PCon "VisPrivate")) (EVar "Nil"))
(DTypeSig false "dataBodyDoc" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyCon "Doc"))))
(DFunDef false "dataBodyDoc" ((PList) (PVar "derives")) (EApp (EVar "derivesInline") (EVar "derives")))
(DFunDef false "dataBodyDoc" ((PList (PCon "Variant" (PVar "name") (PCon "ConNamed" (PVar "fields") (PVar "nameOmitted")))) (PVar "derives")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EApp (EApp (EVar "recordVariantDoc") (EVar "name")) (EVar "fields")) (EVar "nameOmitted")) (EVar "derives"))))
(DFunDef false "dataBodyDoc" ((PCons (PVar "v") (PVar "vs")) (PVar "derives")) (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "FlatAlt") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "text") (ELit (LString "| "))))) (EApp (EVar "text") (ELit (LString " "))))) (EApp (EVar "printVariant") (EVar "v")))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "v2")) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "FlatAlt") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "text") (ELit (LString "| "))))) (EApp (EVar "text") (ELit (LString " | "))))) (EApp (EVar "printVariant") (EVar "v2"))))) (EVar "vs")))) (EApp (EVar "derivesLineOrInline") (EVar "derives"))))))))
(DTypeSig false "derivesInline" (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyCon "Doc")))
(DFunDef false "derivesInline" ((PList)) (EVar "Nil"))
(DFunDef false "derivesInline" ((PVar "derives")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printDerives") (EVar "derives"))))
(DTypeSig false "derivesLineOrInline" (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyCon "Doc")))
(DFunDef false "derivesLineOrInline" ((PList)) (EVar "Nil"))
(DFunDef false "derivesLineOrInline" ((PVar "derives")) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "printDerives") (EVar "derives"))))
(DTypeSig true "printDataDeclCommented" (TyFun (TyCon "DataVis") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Doc")))))))))
(DFunDef false "printDataDeclCommented" ((PVar "vis") (PVar "n") (PVar "params") (PVar "kinds") (PVar "variants") (PVar "derives") (PVar "vcomments")) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "data ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "tyParamsDoc") (EVar "params")) (EVar "kinds"))))) (DoLet false false (PVar "variantDocs") (EApp (EApp (EVar "dataVariantDocsCommented") (EVar "variants")) (EVar "vcomments"))) (DoLet false false (PVar "deriveDoc") (EIf (EApp (EVar "isEmptyL") (EVar "derives")) (EVar "Nil") (EApp (EVar "indentBlock") (EApp (EVar "printDerives") (EVar "derives"))))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "visPrefix") (EVar "vis"))) (EApp (EApp (EVar "Cat") (EVar "head")) (EApp (EApp (EVar "Cat") (EVar "variantDocs")) (EVar "deriveDoc")))))))
(DTypeSig false "commentLinesDoc" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Doc")))
(DFunDef false "commentLinesDoc" ((PVar "cs")) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "c")) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EVar "text") (EVar "c"))))) (EVar "cs"))))
(DTypeSig false "trailingCommentsDoc" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Doc")))
(DFunDef false "trailingCommentsDoc" ((PVar "cs")) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "c")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "  ")))) (EApp (EVar "text") (EVar "c"))))) (EVar "cs"))))
(DTypeSig false "variantCommentedDoc" (TyFun (TyCon "Variant") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Doc"))))
(DFunDef false "variantCommentedDoc" ((PVar "v") (PTuple (PVar "leading") (PVar "trailing"))) (EApp (EApp (EVar "Cat") (EApp (EVar "commentLinesDoc") (EVar "leading"))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "| ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printVariant") (EVar "v"))) (EApp (EVar "trailingCommentsDoc") (EVar "trailing")))))))
(DTypeSig false "dataVariantDocsCommented" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Doc"))))
(DFunDef false "dataVariantDocsCommented" ((PList) PWild) (EVar "Nil"))
(DFunDef false "dataVariantDocsCommented" (PWild (PList)) (EVar "Nil"))
(DFunDef false "dataVariantDocsCommented" ((PCons (PVar "v") (PVar "vs")) (PCons (PVar "vc") (PVar "vcs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "variantCommentedDoc") (EVar "v")) (EVar "vc"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map2VariantComment") (EVar "vs")) (EVar "vcs")))))))
(DTypeSig false "map2VariantComment" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "Doc")))))
(DFunDef false "map2VariantComment" ((PList) PWild) (EListLit))
(DFunDef false "map2VariantComment" (PWild (PList)) (EListLit))
(DFunDef false "map2VariantComment" ((PCons (PVar "v") (PVar "vs")) (PCons (PVar "vc") (PVar "vcs"))) (EBinOp "::" (EApp (EApp (EVar "variantCommentedDoc") (EVar "v")) (EVar "vc")) (EApp (EApp (EVar "map2VariantComment") (EVar "vs")) (EVar "vcs"))))
(DTypeSig false "valueExportPrefix" (TyFun (TyCon "Bool") (TyCon "Doc")))
(DFunDef false "valueExportPrefix" ((PVar "pub")) (EIf (EVar "pub") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "export")))) (EVar "Hardline")) (EVar "Nil")))
(DTypeSig false "defHeader" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Doc"))))
(DFunDef false "defHeader" ((PVar "n") (PVar "pats")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "pats")))))
(DTypeSig false "importForcedRef" (TyApp (TyCon "Ref") (TyCon "Bool")))
(DFunDef false "importForcedRef" () (EApp (EVar "Ref") (EVar "False")))
(DTypeSig true "setImportForced" (TyFun (TyCon "Bool") (TyCon "Unit")))
(DFunDef false "setImportForced" ((PVar "b")) (EApp (EApp (EVar "setRef") (EVar "importForcedRef")) (EVar "b")))
(DTypeSig true "printDecl" (TyFun (TyCon "Decl") (TyCon "Doc")))
(DFunDef false "printDecl" ((PCon "DTypeSig" (PVar "pub") (PVar "n") (PVar "t"))) (EApp (EApp (EVar "Cat") (EApp (EVar "valueExportPrefix") (EVar "pub"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " : ")))) (EApp (EVar "sigTypeDoc") (EVar "t"))))))
(DFunDef false "printDecl" ((PCon "DExtern" (PVar "pub") (PVar "n") (PVar "t"))) (EApp (EApp (EVar "Cat") (EApp (EVar "valueExportPrefix") (EVar "pub"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "extern ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " : ")))) (EApp (EVar "sigTypeDoc") (EVar "t")))))))
(DFunDef false "printDecl" ((PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "defHeader") (EVar "n")) (EVar "pats"))) (EApp (EVar "printDefRhs") (EVar "body")))))
(DFunDef false "printDecl" ((PCon "DLetGroup" (PVar "pub") (PVar "bindings"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EVar "letGroupDecl") (EVar "bindings"))))
(DFunDef false "printDecl" ((PRec "DData" ((rf "dataVis" (PVar "vis")) (rf "dataName" (PVar "n")) (rf "dataParams" (PVar "params")) (rf "dataParamKinds" (PVar "kinds")) (rf "dataCtors" (PVar "variants")) (rf "dataDerives" (PVar "derives"))) false)) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "data ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "tyParamsDoc") (EVar "params")) (EVar "kinds"))))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "visPrefix") (EVar "vis"))) (EApp (EApp (EVar "Cat") (EVar "head")) (EApp (EApp (EVar "dataBodyDoc") (EVar "variants")) (EVar "derives")))))))
(DFunDef false "printDecl" ((PRec "DTypeAlias" ((rf "tyAliasPub" (PVar "pub")) (rf "tyAliasName" (PVar "n")) (rf "tyAliasParams" (PVar "params")) (rf "tyAliasParamKinds" (PVar "kinds")) (rf "tyAliasRhs" (PVar "rhs"))) false)) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "type ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "tyParamsDoc") (EVar "params")) (EVar "kinds"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EVar "printType") (EVar "rhs"))))))))
(DFunDef false "printDecl" ((PRec "DNewtype" ((rf "newtypePub" (PVar "pub")) (rf "newtypeName" (PVar "n")) (rf "newtypeParams" (PVar "params")) (rf "newtypeParamKinds" (PVar "kinds")) (rf "newtypeCtor" (PVar "con")) (rf "newtypeFieldTy" (PVar "fty")) (rf "newtypeDerives" (PVar "derives"))) false)) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "newtype ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "tyParamsDoc") (EVar "params")) (EVar "kinds"))))) (DoLet false false (PVar "body") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "con"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printTypeAtom") (EVar "fty")))))) (DoExpr (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EVar "head")) (EApp (EApp (EVar "Cat") (EVar "body")) (EApp (EVar "group") (EApp (EVar "nest") (EApp (EVar "derivesLineOrInline") (EVar "derives"))))))))))
(DFunDef false "printDecl" ((PRec "DInterface" ((rf "pub" None) (rf "def" None) (rf "name" None) (rf "typarams" None) (rf "typaramKinds" None) (rf "supers" None) (rf "methods" None)) false)) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EIf (EVar "def") (EApp (EVar "text") (ELit (LString "default "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "interface ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "tyParamsDoc") (EVar "typarams")) (EVar "typaramKinds"))) (EApp (EApp (EVar "Cat") (EApp (EVar "superDoc") (EVar "supers"))) (EIf (EApp (EVar "isEmptyL") (EVar "methods")) (EVar "Nil") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " where")))) (EApp (EVar "methodsBlock") (EApp (EApp (EVar "map") (EVar "ifaceMethodPiece")) (EVar "methods"))))))))))))
(DFunDef false "printDecl" ((PRec "DImpl" ((rf "pub" None) (rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None)) false)) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "impl ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "implHead") (EVar "iface")) (EVar "tys"))) (EApp (EApp (EVar "Cat") (EApp (EVar "reqsDoc") (EVar "reqs"))) (EIf (EApp (EVar "isEmptyL") (EVar "methods")) (EVar "Nil") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " where")))) (EApp (EVar "methodsBlock") (EApp (EApp (EVar "map") (EVar "implMethodPiece")) (EVar "methods"))))))))))
(DFunDef false "printDecl" ((PCon "DUse" (PVar "pub") (PVar "path") PWild)) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "import ")))) (EApp (EApp (EVar "printUsePath") (EVar "path")) (EUnOp "!" (EVar "importForcedRef"))))))
(DFunDef false "printDecl" ((PCon "DEffect" (PVar "pub") (PVar "name") (PVar "domain"))) (EApp (EApp (EVar "Cat") (EApp (EVar "effDeclHead") (EVar "pub"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EVar "effDomainDoc") (EVar "domain")))))
(DFunDef false "printDecl" ((PCon "DProp" (PVar "pub") (PVar "propName") (PVar "propParams") (PVar "propBody"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "prop ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EVar "escStringLit") (EVar "propName")))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (EVar "propParamDoc")) (EVar "propParams")))) (EApp (EVar "printDefRhs") (EVar "propBody")))))))
(DFunDef false "printDecl" ((PCon "DTest" (PVar "pub") (PVar "testName") (PVar "testBody"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "test ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EVar "escStringLit") (EVar "testName")))) (EApp (EVar "printDefRhs") (EVar "testBody"))))))
(DFunDef false "printDecl" ((PCon "DBench" (PVar "pub") (PVar "benchName") (PVar "benchBody"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "bench ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EVar "escStringLit") (EVar "benchName")))) (EApp (EVar "printDefRhs") (EVar "benchBody"))))))
(DFunDef false "printDecl" ((PCon "DAttrib" (PVar "attrs") (PVar "inner"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EVar "map") (EVar "attrDoc")) (EVar "attrs")))) (EApp (EVar "printDecl") (EVar "inner"))))
(DTypeSig false "methodsBlock" (TyFun (TyApp (TyCon "List") (TyCon "Piece")) (TyCon "Doc")))
(DFunDef false "methodsBlock" ((PVar "ps")) (EApp (EVar "indentBlock") (EApp (EVar "joinHard") (EApp (EVar "pieceDocsHard") (EVar "ps")))))
(DTypeSig false "propParamDoc" (TyFun (TyCon "PropParam") (TyCon "Doc")))
(DFunDef false "propParamDoc" ((PCon "PropParam" (PVar "x") PWild (PVar "ty"))) (EApp (EVar "text") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EVar "display") (EVar "x"))) (ELit (LString " : "))) (EApp (EVar "display") (EApp (EVar "ppTy") (EVar "ty")))) (ELit (LString ")")))))
(DTypeSig false "attrDoc" (TyFun (TyCon "Attr") (TyCon "Doc")))
(DFunDef false "attrDoc" ((PCon "AttrDeprecated" (PVar "msg"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EBinOp "++" (ELit (LString "@deprecated ")) (EApp (EVar "escStringLit") (EVar "msg"))))) (EVar "Hardline")))
(DFunDef false "attrDoc" ((PCon "AttrInline")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "@inline")))) (EVar "Hardline")))
(DFunDef false "attrDoc" ((PCon "AttrMustUse")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "@must_use")))) (EVar "Hardline")))
(DTypeSig false "letGroupDecl" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "Doc")))
(DFunDef false "letGroupDecl" ((PVar "bindings")) (EBlock (DoLet false false (PVar "docs") (EApp (EApp (EVar "letGroupDeclGo") (EVar "True")) (EVar "bindings"))) (DoExpr (EApp (EVar "concatD") (EVar "docs")))))
(DTypeSig false "letGroupDeclGo" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyCon "Doc")))))
(DFunDef false "letGroupDeclGo" (PWild (PList)) (EListLit))
(DFunDef false "letGroupDeclGo" ((PVar "first") (PCons (PCon "LetBind" (PVar "name") (PVar "clauses")) (PVar "rest"))) (EBlock (DoLet false false (PVar "r") (EApp (EApp (EApp (EVar "letGroupBindClauses") (EVar "first")) (EVar "name")) (EVar "clauses"))) (DoExpr (EMatch (EVar "r") (arm (PTuple (PVar "docs") (PVar "nextFirst")) () (EBinOp "++" (EVar "docs") (EApp (EApp (EVar "letGroupDeclGo") (EVar "nextFirst")) (EVar "rest"))))))))
(DTypeSig false "letGroupBindClauses" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyTuple (TyApp (TyCon "List") (TyCon "Doc")) (TyCon "Bool"))))))
(DFunDef false "letGroupBindClauses" ((PVar "first") PWild (PList)) (ETuple (EListLit) (EVar "first")))
(DFunDef false "letGroupBindClauses" ((PVar "first") (PVar "name") (PCons (PVar "c") (PVar "cs"))) (EBlock (DoLet false false (PVar "d") (EApp (EApp (EApp (EVar "letGroupDeclClause") (EVar "first")) (EVar "name")) (EVar "c"))) (DoLet false false (PVar "r") (EApp (EApp (EApp (EVar "letGroupBindClauses") (EVar "False")) (EVar "name")) (EVar "cs"))) (DoExpr (EMatch (EVar "r") (arm (PTuple (PVar "rest") (PVar "lastFirst")) () (ETuple (EBinOp "::" (EVar "d") (EVar "rest")) (EVar "lastFirst")))))))
(DTypeSig false "letGroupDeclClause" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "FunClause") (TyCon "Doc")))))
(DFunDef false "letGroupDeclClause" ((PVar "first") (PVar "name") (PCon "FunClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "Cat") (EIf (EVar "first") (EApp (EVar "text") (ELit (LString "let rec "))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EVar "text") (ELit (LString "with ")))))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "defHeader") (EVar "name")) (EVar "pats"))) (EApp (EVar "printDefRhs") (EVar "body")))))
(DTypeSig false "superDoc" (TyFun (TyApp (TyCon "List") (TyCon "Super")) (TyCon "Doc")))
(DFunDef false "superDoc" ((PList)) (EVar "Nil"))
(DFunDef false "superDoc" ((PVar "supers")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " requires ")))) (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EVar "oneSuper")) (EVar "supers")))))
(DTypeSig false "oneSuper" (TyFun (TyCon "Super") (TyCon "Doc")))
(DFunDef false "oneSuper" ((PRec "Super" ((rf "superHead" (PVar "n")) (rf "superParams" (PVar "ps"))) false)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "text") (EVar "p"))))) (EVar "ps")))))
(DTypeSig false "ifaceMethodPiece" (TyFun (TyCon "IfaceMethod") (TyCon "Piece")))
(DFunDef false "ifaceMethodPiece" ((PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "None") (PVar "l"))) (EMatch (EVar "l") (arm (PCon "Some" (PVar "loc")) () (EMatch (EApp (EVar "locSpan") (EVar "loc")) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s")) (EVar "sc")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EVar "ifaceMethodDoc") (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EVar "None")) (EVar "l")))))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELam (PWild) (EApp (EVar "ifaceMethodDoc") (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EVar "None")) (EVar "l"))))))))
(DFunDef false "ifaceMethodPiece" ((PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))) (PVar "l"))) (EBlock (DoLet false false (PVar "sp") (EApp (EApp (EVar "mergeSpan") (EApp (EApp (EVar "spansOf") (EVar "patSpan")) (EVar "pats"))) (EApp (EVar "exprSpan") (EVar "body")))) (DoExpr (EMatch (EVar "sp") (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s")) (EVar "sc")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EVar "ifaceMethodDoc") (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EVar "pats")) (EVar "body")))) (EVar "l"))))))))))
(DTypeSig false "ifaceMethodDoc" (TyFun (TyCon "IfaceMethod") (TyCon "Doc")))
(DFunDef false "ifaceMethodDoc" ((PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "None") PWild)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " : ")))) (EApp (EVar "sigTypeDoc") (EVar "ty")))))
(DFunDef false "ifaceMethodDoc" ((PCon "IfaceMethod" (PVar "n") PWild (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))) PWild)) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "defHeader") (EVar "n")) (EVar "pats"))) (EApp (EVar "printDefRhs") (EVar "body"))))
(DTypeSig false "implHead" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Doc"))))
(DFunDef false "implHead" ((PVar "iface") (PVar "tys")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "iface"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "t")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printTypeAtom") (EVar "t"))))) (EVar "tys")))))
(DTypeSig false "reqsDoc" (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyCon "Doc")))
(DFunDef false "reqsDoc" ((PList)) (EVar "Nil"))
(DFunDef false "reqsDoc" ((PVar "reqs")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " requires ")))) (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EVar "map") (EVar "oneReq")) (EVar "reqs")))))
(DTypeSig false "oneReq" (TyFun (TyCon "Require") (TyCon "Doc")))
(DFunDef false "oneReq" ((PRec "Require" ((rf "requireHead" (PVar "iface")) (rf "requireArgs" (PVar "args"))) false)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "iface"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map") (ELam ((PVar "t")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printTypeAtom") (EVar "t"))))) (EVar "args")))))
(DTypeSig false "implMethodPiece" (TyFun (TyCon "ImplMethod") (TyCon "Piece")))
(DFunDef false "implMethodPiece" ((PCon "ImplMethod" (PVar "n") (PVar "pats") (PVar "body"))) (EMatch (EApp (EApp (EVar "mergeSpan") (EApp (EApp (EVar "spansOf") (EVar "patSpan")) (EVar "pats"))) (EApp (EVar "exprSpan") (EVar "body"))) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EMatch (EApp (EApp (EApp (EVar "unitStartAt") (ELit (LInt 2))) (EVar "s")) (EVar "sc")) (arm (PTuple (PVar "s2") (PVar "sc2")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s2")) (EVar "sc2")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EVar "implMethodDoc") (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EVar "pats")) (EVar "body"))))))))))
(DTypeSig false "implMethodDoc" (TyFun (TyCon "ImplMethod") (TyCon "Doc")))
(DFunDef false "implMethodDoc" ((PCon "ImplMethod" (PVar "n") (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "defHeader") (EVar "n")) (EVar "pats"))) (EApp (EVar "printDefRhs") (EVar "body"))))
(DTypeSig true "ppTy" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "ppTy" ((PVar "t")) (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 0))) (EVar "t")))
(DTypeSig false "ppTyPrec" (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "ppTyPrec" (PWild (PRec "TyCon" ((rf "tyConName" (PVar "s"))) false)) (EApp (EVar "tyConSurface") (EVar "s")))
(DFunDef false "ppTyPrec" (PWild (PCon "TyVar" (PVar "s"))) (EVar "s"))
(DFunDef false "ppTyPrec" (PWild (PCon "TyTuple" (PVar "ts"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EApp (EVar "ppTyPrec") (ELit (LInt 0)))) (EVar "ts")))) (ELit (LString ")"))))
(DFunDef false "ppTyPrec" ((PVar "p") (PCon "TyApp" (PVar "f") (PVar "x"))) (EBlock (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 1))) (EVar "f")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 2))) (EVar "x")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 2))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyPrec" ((PVar "p") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 1))) (EVar "a")))) (ELit (LString " -> "))) (EApp (EVar "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 0))) (EVar "b")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 1))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyPrec" ((PVar "p") (PCon "TyEffect" (PVar "effs") (PVar "tail") (PVar "t"))) (EBlock (DoLet false false (PVar "inside") (EApp (EApp (EVar "ppEffInside") (EVar "effs")) (EVar "tail"))) (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EVar "display") (EVar "inside"))) (ELit (LString "> "))) (EApp (EVar "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 0))) (EVar "t")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 1))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyPrec" (PWild (PCon "TyRow" (PList) (PCons (PVar "a") (PCons (PVar "b") (PVar "rest"))) PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EBinOp "::" (EVar "a") (EBinOp "::" (EVar "b") (EVar "rest")))))) (ELit (LString ")"))))
(DFunDef false "ppTyPrec" (PWild (PCon "TyRow" (PVar "effs") (PVar "tail") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EVar "display") (EApp (EApp (EVar "ppEffInside") (EVar "effs")) (EVar "tail")))) (ELit (LString ">"))))
(DFunDef false "ppTyPrec" (PWild (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBlock (DoLet false false (PVar "csStr") (EMatch (EVar "cs") (arm (PList (PVar "c")) () (EApp (EVar "ppConstr") (EVar "c"))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "ppConstr")) (EVar "cs")))) (ELit (LString ")")))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "csStr"))) (ELit (LString " => "))) (EApp (EVar "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 0))) (EVar "t")))) (ELit (LString ""))))))
(DTypeSig false "ppEffInside" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "ppEffInside" ((PVar "effs") (PList)) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "ppEffAtom")) (EVar "effs"))))
(DFunDef false "ppEffInside" ((PList) (PVar "tails")) (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails")))
(DFunDef false "ppEffInside" ((PVar "effs") (PVar "tails")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "ppEffAtom")) (EVar "effs"))))) (ELit (LString " | "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails")))) (ELit (LString ""))))
(DTypeSig false "ppEffAtom" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "String")))
(DFunDef false "ppEffAtom" ((PTuple (PVar "l") (PCon "None"))) (EVar "l"))
(DFunDef false "ppEffAtom" ((PTuple (PVar "l") (PCon "Some" (PVar "s")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "l"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "escStringLit") (EVar "s")))) (ELit (LString ""))))
(DTypeSig false "effDomainDoc" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Doc")))
(DFunDef false "effDomainDoc" ((PCon "None")) (EVar "Nil"))
(DFunDef false "effDomainDoc" ((PCon "Some" (PVar "d"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "text") (EVar "d"))))
(DTypeSig false "effDeclHead" (TyFun (TyCon "Bool") (TyCon "Doc")))
(DFunDef false "effDeclHead" ((PCon "True")) (EApp (EVar "text") (ELit (LString "export effect "))))
(DFunDef false "effDeclHead" ((PCon "False")) (EApp (EVar "text") (ELit (LString "effect "))))
(DTypeSig false "ppConstr" (TyFun (TyCon "Constraint") (TyCon "String")))
(DFunDef false "ppConstr" ((PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PVar "args"))) false)) (EIf (EApp (EVar "isEmptyL") (EVar "args")) (EVar "iface") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EVar "map") (EApp (EVar "ppTyPrec") (ELit (LInt 2)))) (EVar "args"))))) (ELit (LString "")))))
(DTypeSig true "exprToString" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "exprToString" ((PVar "e")) (EApp (EVar "render") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))))
(DTypeSig true "declToString" (TyFun (TyCon "Decl") (TyCon "String")))
(DFunDef false "declToString" ((PVar "d")) (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "d"))))
(DTypeSig true "programToString" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))
(DFunDef false "programToString" ((PVar "decls")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "map") (EVar "declLine")) (EVar "decls"))))
(DTypeSig false "declLine" (TyFun (TyCon "Decl") (TyCon "String")))
(DFunDef false "declLine" ((PVar "d")) (EBinOp "++" (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "d"))) (ELit (LString "\n"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "DeriveRef" true) (mem "deriveRefName" false) (mem "dDataUnresolved" false) (mem "KindAnn" true) (mem "tyParamSources" false) (mem "Loc" true) (mem "Lit" true) (mem "Ty" true) (mem "Constraint" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "Section" true) (mem "FunClause" true) (mem "LetBind" true) (mem "Expr" true) (mem "UseMember" true) (mem "UsePath" true) (mem "PropParam" true) (mem "MethodDefault" true) (mem "IfaceMethod" true) (mem "Super" true) (mem "Require" true) (mem "ImplMethod" true) (mem "DataVis" true) (mem "Field" true) (mem "ConPayload" true) (mem "Variant" true) (mem "Decl" true) (mem "Attr" true))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "listLen" false) (mem "allList" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "escOneHex2" false))))
(DUse false (UseGroup ("list") ((mem "last" false) (mem "sortBy" false))))
(DData Public "Doc" () ((variant "Nil" (ConPos)) (variant "Text" (ConPos (TyCon "String"))) (variant "Cat" (ConPos (TyCon "Doc") (TyCon "Doc"))) (variant "Line" (ConPos)) (variant "Softline" (ConPos)) (variant "Hardline" (ConPos)) (variant "BlankLine" (ConPos)) (variant "Nest" (ConPos (TyCon "Int") (TyCon "Doc"))) (variant "Group" (ConPos (TyCon "Doc"))) (variant "FlatAlt" (ConPos (TyCon "Doc") (TyCon "Doc"))) (variant "Alt" (ConPos (TyCon "Doc") (TyCon "Doc"))) (variant "Hang" (ConPos (TyCon "String") (TyCon "Doc"))) (variant "LineComment" (ConPos (TyCon "String"))) (variant "Fill" (ConPos (TyCon "Bool") (TyApp (TyCon "List") (TyCon "Doc"))))) ())
(DTypeSig false "text" (TyFun (TyCon "String") (TyCon "Doc")))
(DFunDef false "text" ((PVar "s")) (EApp (EVar "Text") (EVar "s")))
(DTypeSig false "group" (TyFun (TyCon "Doc") (TyCon "Doc")))
(DFunDef false "group" ((PVar "d")) (EApp (EVar "Group") (EVar "d")))
(DTypeSig false "trailingCommaDoc" (TyCon "Doc"))
(DFunDef false "trailingCommaDoc" () (EApp (EApp (EVar "FlatAlt") (EApp (EVar "text") (ELit (LString ",")))) (EVar "Nil")))
(DTypeSig false "nest" (TyFun (TyCon "Doc") (TyCon "Doc")))
(DFunDef false "nest" ((PVar "d")) (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EVar "d")))
(DTypeSig false "sepBy" (TyFun (TyCon "Doc") (TyFun (TyApp (TyCon "List") (TyCon "Doc")) (TyCon "Doc"))))
(DFunDef false "sepBy" (PWild (PList)) (EVar "Nil"))
(DFunDef false "sepBy" (PWild (PList (PVar "x"))) (EVar "x"))
(DFunDef false "sepBy" ((PVar "sep") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "Cat") (EVar "x")) (EApp (EApp (EVar "Cat") (EVar "sep")) (EApp (EApp (EVar "sepBy") (EVar "sep")) (EVar "xs")))))
(DTypeSig false "concatD" (TyFun (TyApp (TyCon "List") (TyCon "Doc")) (TyCon "Doc")))
(DFunDef false "concatD" ((PList)) (EVar "Nil"))
(DFunDef false "concatD" ((PCons (PVar "d") (PVar "ds"))) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "concatD") (EVar "ds"))))
(DTypeSig false "indentBlock" (TyFun (TyCon "Doc") (TyCon "Doc")))
(DFunDef false "indentBlock" ((PVar "d")) (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EVar "d"))))
(DData Public "Mode" () ((variant "Flat" (ConPos)) (variant "Break" (ConPos))) ())
(DData Public "Item" () ((variant "Item" (ConPos (TyCon "Int") (TyCon "Mode") (TyCon "Doc")))) ())
(DTypeSig false "defaultWidth" (TyCon "Int"))
(DFunDef false "defaultWidth" () (ELit (LInt 80)))
(DTypeSig false "fillFlatDoc" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Doc")) (TyCon "Doc"))))
(DFunDef false "fillFlatDoc" (PWild (PList)) (EVar "Nil"))
(DFunDef false "fillFlatDoc" ((PCon "False") (PVar "ds")) (EApp (EApp (EVar "sepBy") (EVar "Line")) (EVar "ds")))
(DFunDef false "fillFlatDoc" ((PCon "True") (PVar "ds")) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "sepBy") (EVar "Line")) (EVar "ds"))))
(DTypeSig false "hangInline" (TyFun (TyCon "String") (TyFun (TyCon "Doc") (TyCon "Doc"))))
(DFunDef false "hangInline" ((PVar "sep") (PVar "d")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "sep"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EVar "d"))))
(DTypeSig false "fits" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Item")) (TyCon "Bool"))))
(DFunDef false "fits" ((PVar "w") PWild) (EIf (EBinOp "<" (EVar "w") (ELit (LInt 0))) (EVar "False") (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "fits" (PWild (PList)) (EVar "True"))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" PWild PWild (PCon "Nil")) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EVar "z")))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Cat" (PVar "a") (PVar "b"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "a")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "b")) (EVar "z")))))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Nest" (PVar "j") (PVar "d"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EBinOp "+" (EVar "i") (EVar "j"))) (EVar "m")) (EVar "d")) (EVar "z"))))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" PWild PWild (PCon "Text" (PVar "s"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EBinOp "-" (EVar "w") (EApp (EVar "stringLength") (EVar "s")))) (EVar "z")))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" PWild (PCon "Flat") (PCon "Line")) (PVar "z"))) (EApp (EApp (EVar "fits") (EBinOp "-" (EVar "w") (ELit (LInt 1)))) (EVar "z")))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" PWild (PCon "Flat") (PCon "Softline")) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EVar "z")))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Break") (PCon "Line")) PWild)) (EVar "True"))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Break") (PCon "Softline")) PWild)) (EVar "True"))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Break") (PCon "Hardline")) PWild)) (EVar "True"))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Flat") (PCon "Hardline")) PWild)) (EVar "False"))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Break") (PCon "BlankLine")) PWild)) (EVar "True"))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Flat") (PCon "BlankLine")) PWild)) (EVar "False"))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Group" (PVar "d"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "d")) (EVar "z"))))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "FlatAlt" PWild (PVar "b"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "b")) (EVar "z"))))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Alt" (PVar "a") PWild)) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "a")) (EVar "z"))))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Hang" (PVar "sep") (PVar "d"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EApp (EApp (EVar "hangInline") (EVar "sep")) (EVar "d"))) (EVar "z"))))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Flat") (PCon "LineComment" PWild)) (PVar "z"))) (EApp (EVar "restEndsLine") (EVar "z")))
(DFunDef false "fits" (PWild (PCons (PCon "Item" PWild (PCon "Break") (PCon "LineComment" PWild)) PWild)) (EVar "True"))
(DFunDef false "fits" ((PVar "w") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Fill" (PVar "sf") (PVar "ds"))) (PVar "z"))) (EApp (EApp (EVar "fits") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EApp (EApp (EVar "fillFlatDoc") (EVar "sf")) (EVar "ds"))) (EVar "z"))))
(DTypeSig false "restEndsLine" (TyFun (TyApp (TyCon "List") (TyCon "Item")) (TyCon "Bool")))
(DFunDef false "restEndsLine" ((PList)) (EVar "True"))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" PWild PWild (PCon "Nil")) (PVar "z"))) (EApp (EVar "restEndsLine") (EVar "z")))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Cat" (PVar "a") (PVar "b"))) (PVar "z"))) (EApp (EVar "restEndsLine") (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "a")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "b")) (EVar "z")))))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Nest" (PVar "j") (PVar "d"))) (PVar "z"))) (EApp (EVar "restEndsLine") (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EBinOp "+" (EVar "i") (EVar "j"))) (EVar "m")) (EVar "d")) (EVar "z"))))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" PWild PWild (PCon "Text" (PVar "s"))) (PVar "z"))) (EIf (EBinOp "==" (EVar "s") (ELit (LString ""))) (EApp (EVar "restEndsLine") (EVar "z")) (EVar "False")))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" PWild (PCon "Flat") (PCon "Line")) PWild)) (EVar "False"))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" PWild (PCon "Flat") (PCon "Softline")) (PVar "z"))) (EApp (EVar "restEndsLine") (EVar "z")))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" PWild (PCon "Break") (PCon "Line")) PWild)) (EVar "True"))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" PWild (PCon "Break") (PCon "Softline")) PWild)) (EVar "True"))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" PWild PWild (PCon "Hardline")) PWild)) (EVar "True"))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" PWild PWild (PCon "BlankLine")) PWild)) (EVar "True"))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Group" (PVar "d"))) (PVar "z"))) (EApp (EVar "restEndsLine") (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "d")) (EVar "z"))))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "FlatAlt" PWild (PVar "b"))) (PVar "z"))) (EApp (EVar "restEndsLine") (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "b")) (EVar "z"))))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Alt" (PVar "a") PWild)) (PVar "z"))) (EApp (EVar "restEndsLine") (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "a")) (EVar "z"))))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Hang" (PVar "sep") (PVar "d"))) (PVar "z"))) (EApp (EVar "restEndsLine") (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EApp (EApp (EVar "hangInline") (EVar "sep")) (EVar "d"))) (EVar "z"))))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" PWild PWild (PCon "LineComment" PWild)) PWild)) (EVar "False"))
(DFunDef false "restEndsLine" ((PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Fill" (PVar "sf") (PVar "ds"))) (PVar "z"))) (EApp (EVar "restEndsLine") (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EApp (EApp (EVar "fillFlatDoc") (EVar "sf")) (EVar "ds"))) (EVar "z"))))
(DTypeSig false "spaces" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "spaces" ((PVar "n")) (EIf (EBinOp "<=" (EVar "n") (ELit (LInt 0))) (ELit (LString "")) (EIf (EVar "otherwise") (EBinOp "++" (ELit (LString " ")) (EApp (EVar "spaces") (EBinOp "-" (EVar "n") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "newlineStr" (TyFun (TyCon "Int") (TyCon "String")))
(DFunDef false "newlineStr" ((PVar "i")) (EBinOp "++" (ELit (LString "\n")) (EApp (EVar "spaces") (EVar "i"))))
(DTypeSig false "itemBroken" (TyFun (TyCon "Item") (TyCon "Item")))
(DFunDef false "itemBroken" ((PCon "Item" (PVar "i") PWild (PVar "d"))) (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EVar "d")))
(DTypeSig false "go" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Item")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "go" (PWild (PList)) (EListLit))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" PWild PWild (PCon "Nil")) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EVar "z")))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Cat" (PVar "a") (PVar "b"))) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "a")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "m")) (EVar "b")) (EVar "z")))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PVar "m") (PCon "Nest" (PVar "j") (PVar "d"))) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EBinOp "+" (EVar "i") (EVar "j"))) (EVar "m")) (EVar "d")) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" PWild PWild (PCon "Text" (PVar "s"))) (PVar "z"))) (EBinOp "::" (EVar "s") (EApp (EApp (EVar "go") (EBinOp "+" (EVar "col") (EApp (EVar "stringLength") (EVar "s")))) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" PWild (PCon "Flat") (PCon "Line")) (PVar "z"))) (EBinOp "::" (ELit (LString " ")) (EApp (EApp (EVar "go") (EBinOp "+" (EVar "col") (ELit (LInt 1)))) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" PWild (PCon "Flat") (PCon "Softline")) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EVar "z")))
(DFunDef false "go" (PWild (PCons (PCon "Item" (PVar "i") (PCon "Break") (PCon "Line")) (PVar "z"))) (EBinOp "::" (EApp (EVar "newlineStr") (EVar "i")) (EApp (EApp (EVar "go") (EVar "i")) (EVar "z"))))
(DFunDef false "go" (PWild (PCons (PCon "Item" (PVar "i") (PCon "Break") (PCon "Softline")) (PVar "z"))) (EBinOp "::" (EApp (EVar "newlineStr") (EVar "i")) (EApp (EApp (EVar "go") (EVar "i")) (EVar "z"))))
(DFunDef false "go" (PWild (PCons (PCon "Item" (PVar "i") PWild (PCon "Hardline")) (PVar "z"))) (EBinOp "::" (EApp (EVar "newlineStr") (EVar "i")) (EApp (EApp (EVar "go") (EVar "i")) (EVar "z"))))
(DFunDef false "go" (PWild (PCons (PCon "Item" PWild PWild (PCon "BlankLine")) (PVar "z"))) (EBinOp "::" (ELit (LString "\n")) (EApp (EApp (EVar "go") (ELit (LInt 0))) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") PWild (PCon "Group" (PVar "d"))) (PVar "z"))) (EBlock (DoLet false false (PVar "flat") (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "d")) (EVar "z"))) (DoExpr (EIf (EApp (EApp (EVar "fits") (EBinOp "-" (EVar "defaultWidth") (EVar "col"))) (EDictApp "flat")) (EApp (EApp (EVar "go") (EVar "col")) (EDictApp "flat")) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EVar "d")) (EVar "z")))))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PCon "Flat") (PCon "FlatAlt" PWild (PVar "b"))) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "b")) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PCon "Break") (PCon "FlatAlt" (PVar "a") PWild)) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EVar "a")) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PCon "Flat") (PCon "Alt" (PVar "a") PWild)) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "a")) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PCon "Break") (PCon "Alt" (PVar "a") (PVar "b"))) (PVar "z"))) (EIf (EApp (EApp (EVar "fits") (EBinOp "-" (EVar "defaultWidth") (EVar "col"))) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EVar "a")) (EVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EVar "a")) (EVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EVar "b")) (EVar "z")))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PCon "Flat") (PCon "Hang" (PVar "sep") (PVar "d"))) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EApp (EApp (EVar "hangInline") (EVar "sep")) (EVar "d"))) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PCon "Break") (PCon "Hang" (PVar "sep") (PVar "d"))) (PVar "z"))) (EBlock (DoLet false false (PVar "inline") (EApp (EApp (EVar "hangInline") (EVar "sep")) (EVar "d"))) (DoExpr (EIf (EApp (EApp (EVar "fits") (EBinOp "-" (EVar "defaultWidth") (EVar "col"))) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "inline")) (EVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "inline")) (EVar "z"))) (EIf (EApp (EApp (EVar "fits") (EBinOp "-" (EBinOp "-" (EVar "defaultWidth") (EVar "i")) (ELit (LInt 2)))) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EVar "Flat")) (EVar "d")) (EVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "sep"))) (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EVar "Line")) (EVar "d"))))) (EVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EVar "inline")) (EVar "z"))))))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" PWild PWild (PCon "LineComment" (PVar "s"))) (PVar "z"))) (EBinOp "::" (EBinOp "++" (ELit (LString "  ")) (EVar "s")) (EApp (EApp (EVar "go") (EBinOp "+" (EBinOp "+" (EVar "col") (ELit (LInt 2))) (EApp (EVar "stringLength") (EVar "s")))) (EApp (EApp (EMethodRef "map") (EVar "itemBroken")) (EVar "z")))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PCon "Flat") (PCon "Fill" (PVar "sf") (PVar "ds"))) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EApp (EApp (EVar "fillFlatDoc") (EVar "sf")) (EVar "ds"))) (EVar "z"))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" PWild (PCon "Break") (PCon "Fill" PWild (PList))) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EVar "z")))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PCon "Break") (PCon "Fill" (PCon "False") (PCons (PVar "d") (PVar "ds")))) (PVar "z"))) (EApp (EApp (EVar "go") (EVar "col")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "d")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EApp (EApp (EVar "Fill") (EVar "True")) (EVar "ds"))) (EVar "z")))))
(DFunDef false "go" ((PVar "col") (PCons (PCon "Item" (PVar "i") (PCon "Break") (PCon "Fill" (PCon "True") (PCons (PVar "d") (PVar "ds")))) (PVar "z"))) (EBlock (DoLet false false (PVar "rest") (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "d")) (EBinOp "::" (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Break")) (EApp (EApp (EVar "Fill") (EVar "True")) (EVar "ds"))) (EVar "z")))) (DoExpr (EIf (EApp (EApp (EVar "fits") (EBinOp "-" (EBinOp "-" (EVar "defaultWidth") (EVar "col")) (ELit (LInt 1)))) (EListLit (EApp (EApp (EApp (EVar "Item") (EVar "i")) (EVar "Flat")) (EVar "d")))) (EBinOp "::" (ELit (LString " ")) (EApp (EApp (EVar "go") (EBinOp "+" (EVar "col") (ELit (LInt 1)))) (EVar "rest"))) (EBinOp "::" (EApp (EVar "newlineStr") (EVar "i")) (EApp (EApp (EVar "go") (EVar "i")) (EVar "rest")))))))
(DTypeSig true "render" (TyFun (TyCon "Doc") (TyCon "String")))
(DFunDef false "render" ((PVar "doc")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "go") (ELit (LInt 0))) (EListLit (EApp (EApp (EApp (EVar "Item") (ELit (LInt 0))) (EVar "Break")) (EVar "doc"))))))
(DTypeSig false "goFlat" (TyFun (TyApp (TyCon "List") (TyCon "Doc")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "goFlat" ((PList)) (EListLit))
(DFunDef false "goFlat" ((PCons (PCon "Nil") (PVar "z"))) (EApp (EVar "goFlat") (EVar "z")))
(DFunDef false "goFlat" ((PCons (PCon "Text" (PVar "s")) (PVar "z"))) (EBinOp "::" (EVar "s") (EApp (EVar "goFlat") (EVar "z"))))
(DFunDef false "goFlat" ((PCons (PCon "Line") (PVar "z"))) (EBinOp "::" (ELit (LString " ")) (EApp (EVar "goFlat") (EVar "z"))))
(DFunDef false "goFlat" ((PCons (PCon "Softline") (PVar "z"))) (EApp (EVar "goFlat") (EVar "z")))
(DFunDef false "goFlat" ((PCons (PCon "Hardline") (PVar "z"))) (EBinOp "::" (ELit (LString " ")) (EApp (EVar "goFlat") (EVar "z"))))
(DFunDef false "goFlat" ((PCons (PCon "BlankLine") (PVar "z"))) (EBinOp "::" (ELit (LString " ")) (EApp (EVar "goFlat") (EVar "z"))))
(DFunDef false "goFlat" ((PCons (PCon "Cat" (PVar "a") (PVar "b")) (PVar "z"))) (EApp (EVar "goFlat") (EBinOp "::" (EVar "a") (EBinOp "::" (EVar "b") (EVar "z")))))
(DFunDef false "goFlat" ((PCons (PCon "Nest" PWild (PVar "d")) (PVar "z"))) (EApp (EVar "goFlat") (EBinOp "::" (EVar "d") (EVar "z"))))
(DFunDef false "goFlat" ((PCons (PCon "Group" (PVar "d")) (PVar "z"))) (EApp (EVar "goFlat") (EBinOp "::" (EVar "d") (EVar "z"))))
(DFunDef false "goFlat" ((PCons (PCon "FlatAlt" PWild (PVar "b")) (PVar "z"))) (EApp (EVar "goFlat") (EBinOp "::" (EVar "b") (EVar "z"))))
(DFunDef false "goFlat" ((PCons (PCon "Alt" (PVar "a") PWild) (PVar "z"))) (EApp (EVar "goFlat") (EBinOp "::" (EVar "a") (EVar "z"))))
(DFunDef false "goFlat" ((PCons (PCon "Hang" (PVar "sep") (PVar "d")) (PVar "z"))) (EApp (EVar "goFlat") (EBinOp "::" (EApp (EApp (EVar "hangInline") (EVar "sep")) (EVar "d")) (EVar "z"))))
(DFunDef false "goFlat" ((PCons (PCon "LineComment" (PVar "s")) (PVar "z"))) (EBinOp "::" (EBinOp "++" (ELit (LString "  ")) (EVar "s")) (EApp (EVar "goFlat") (EVar "z"))))
(DFunDef false "goFlat" ((PCons (PCon "Fill" (PVar "sf") (PVar "ds")) (PVar "z"))) (EApp (EVar "goFlat") (EBinOp "::" (EApp (EApp (EVar "fillFlatDoc") (EVar "sf")) (EVar "ds")) (EVar "z"))))
(DTypeSig false "renderFlat" (TyFun (TyCon "Doc") (TyCon "String")))
(DFunDef false "renderFlat" ((PVar "d")) (EApp (EVar "stringConcat") (EApp (EVar "goFlat") (EListLit (EVar "d")))))
(DData Public "PComment" () ((variant "PComment" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "String") (TyCon "Bool")))) ())
(DTypeSig false "pcLine" (TyFun (TyCon "PComment") (TyCon "Int")))
(DFunDef false "pcLine" ((PCon "PComment" (PVar "l") PWild PWild PWild)) (EVar "l"))
(DTypeSig false "pcText" (TyFun (TyCon "PComment") (TyCon "String")))
(DFunDef false "pcText" ((PCon "PComment" PWild PWild (PVar "t") PWild)) (EVar "t"))
(DTypeSig false "pcCol" (TyFun (TyCon "PComment") (TyCon "Int")))
(DFunDef false "pcCol" ((PCon "PComment" PWild (PVar "c") PWild PWild)) (EVar "c"))
(DTypeSig false "pcStandalone" (TyFun (TyCon "PComment") (TyCon "Bool")))
(DFunDef false "pcStandalone" ((PCon "PComment" PWild PWild PWild (PVar "s"))) (EVar "s"))
(DTypeSig false "pcEndLine" (TyFun (TyCon "PComment") (TyCon "Int")))
(DFunDef false "pcEndLine" ((PCon "PComment" (PVar "l") PWild (PVar "t") PWild)) (EBinOp "+" (EVar "l") (EApp (EApp (EVar "countNewlines") (EApp (EVar "stringToChars") (EVar "t"))) (ELit (LInt 0)))))
(DTypeSig false "countNewlines" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyCon "Int"))))
(DFunDef false "countNewlines" ((PVar "cs") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (ELit (LInt 0)) (EIf (EBinOp "==" (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs")) (ELit (LChar "\n"))) (EBinOp "+" (ELit (LInt 1)) (EApp (EApp (EVar "countNewlines") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EIf (EVar "otherwise") (EApp (EApp (EVar "countNewlines") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "commentsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "PComment"))))
(DFunDef false "commentsRef" () (EApp (EVar "Ref") (EListLit)))
(DTypeSig false "commentBoundRef" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "commentBoundRef" () (EApp (EVar "Ref") (ELit (LInt 0))))
(DTypeSig false "commentsUsedRef" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "commentsUsedRef" () (EApp (EVar "Ref") (ELit (LInt 0))))
(DTypeSig true "setComments" (TyFun (TyApp (TyCon "List") (TyCon "PComment")) (TyFun (TyCon "Int") (TyCon "Unit"))))
(DFunDef false "setComments" ((PVar "cs") (PVar "bound")) (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentsRef")) (EVar "cs"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentBoundRef")) (EVar "bound"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "declBoundRef")) (EVar "bound"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentsUsedRef")) (ELit (LInt 0))))))
(DTypeSig false "declBoundRef" (TyApp (TyCon "Ref") (TyCon "Int")))
(DFunDef false "declBoundRef" () (EApp (EVar "Ref") (ELit (LInt 0))))
(DTypeSig true "takeLeftoverComments" (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyCon "PComment"))))
(DFunDef false "takeLeftoverComments" (PWild) (EBlock (DoLet false false (PVar "cs") (EUnOp "!" (EVar "commentsRef"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentsRef")) (EListLit))) (DoExpr (EVar "cs"))))
(DTypeSig true "commentsPlaced" (TyFun (TyCon "Unit") (TyCon "Int")))
(DFunDef false "commentsPlaced" (PWild) (EUnOp "!" (EVar "commentsUsedRef")))
(DTypeSig false "popBefore" (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "PComment"))))
(DFunDef false "popBefore" ((PVar "line")) (EBlock (DoLet false false (PVar "cs") (EUnOp "!" (EVar "commentsRef"))) (DoExpr (EMatch (EApp (EApp (EVar "spanBefore") (EVar "line")) (EVar "cs")) (arm (PTuple (PVar "mine") (PVar "rest")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentsRef")) (EVar "rest"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentsUsedRef")) (EBinOp "+" (EUnOp "!" (EVar "commentsUsedRef")) (EApp (EVar "listLen") (EVar "mine"))))) (DoExpr (EVar "mine"))))))))
(DTypeSig false "spanBefore" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PComment")) (TyTuple (TyApp (TyCon "List") (TyCon "PComment")) (TyApp (TyCon "List") (TyCon "PComment"))))))
(DFunDef false "spanBefore" (PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "spanBefore" ((PVar "line") (PCons (PVar "c") (PVar "rest"))) (EIf (EBinOp "<" (EApp (EVar "pcLine") (EVar "c")) (EVar "line")) (EMatch (EApp (EApp (EVar "spanBefore") (EVar "line")) (EVar "rest")) (arm (PTuple (PVar "mine") (PVar "left")) () (ETuple (EBinOp "::" (EVar "c") (EVar "mine")) (EVar "left")))) (EIf (EVar "otherwise") (ETuple (EListLit) (EBinOp "::" (EVar "c") (EVar "rest"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "popTrailingAt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "PComment")))))
(DFunDef false "popTrailingAt" ((PVar "line") (PVar "col")) (EBlock (DoLet false false (PVar "cs") (EUnOp "!" (EVar "commentsRef"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "partTrailing") (EVar "line")) (EVar "col")) (EVar "cs")) (arm (PTuple (PVar "mine") (PVar "rest")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentsRef")) (EVar "rest"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentsUsedRef")) (EBinOp "+" (EUnOp "!" (EVar "commentsUsedRef")) (EApp (EVar "listLen") (EVar "mine"))))) (DoExpr (EVar "mine"))))))))
(DTypeSig false "partTrailing" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PComment")) (TyTuple (TyApp (TyCon "List") (TyCon "PComment")) (TyApp (TyCon "List") (TyCon "PComment")))))))
(DFunDef false "partTrailing" (PWild PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "partTrailing" ((PVar "line") (PVar "col") (PCons (PVar "c") (PVar "rest"))) (EIf (EBinOp ">" (EApp (EVar "pcLine") (EVar "c")) (EVar "line")) (ETuple (EListLit) (EBinOp "::" (EVar "c") (EVar "rest"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EApp (EVar "pcLine") (EVar "c")) (EVar "line")) (EApp (EVar "not") (EApp (EVar "pcStandalone") (EVar "c")))) (EBinOp ">=" (EApp (EVar "pcCol") (EVar "c")) (EVar "col"))) (EMatch (EApp (EApp (EApp (EVar "partTrailing") (EVar "line")) (EVar "col")) (EVar "rest")) (arm (PTuple (PVar "mine") (PVar "left")) () (ETuple (EBinOp "::" (EVar "c") (EVar "mine")) (EVar "left")))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "partTrailing") (EVar "line")) (EVar "col")) (EVar "rest")) (arm (PTuple (PVar "mine") (PVar "left")) () (ETuple (EVar "mine") (EBinOp "::" (EVar "c") (EVar "left"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "popDanglingBefore" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "PComment")))))
(DFunDef false "popDanglingBefore" ((PVar "line") (PVar "col")) (EBlock (DoLet false false (PVar "cs") (EUnOp "!" (EVar "commentsRef"))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "partDangling") (EVar "line")) (EVar "col")) (EVar "cs")) (arm (PTuple (PVar "mine") (PVar "rest")) () (EBlock (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentsRef")) (EVar "rest"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentsUsedRef")) (EBinOp "+" (EUnOp "!" (EVar "commentsUsedRef")) (EApp (EVar "listLen") (EVar "mine"))))) (DoExpr (EVar "mine"))))))))
(DTypeSig false "partDangling" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PComment")) (TyTuple (TyApp (TyCon "List") (TyCon "PComment")) (TyApp (TyCon "List") (TyCon "PComment")))))))
(DFunDef false "partDangling" (PWild PWild (PList)) (ETuple (EListLit) (EListLit)))
(DFunDef false "partDangling" ((PVar "line") (PVar "col") (PCons (PCon "PComment" (PVar "cl") (PVar "cc") (PVar "t") (PVar "st")) (PVar "rest"))) (EIf (EBinOp ">=" (EVar "cl") (EVar "line")) (ETuple (EListLit) (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "PComment") (EVar "cl")) (EVar "cc")) (EVar "t")) (EVar "st")) (EVar "rest"))) (EIf (EBinOp ">=" (EVar "cc") (EVar "col")) (EMatch (EApp (EApp (EApp (EVar "partDangling") (EVar "line")) (EVar "col")) (EVar "rest")) (arm (PTuple (PVar "mine") (PVar "left")) () (ETuple (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "PComment") (EVar "cl")) (EVar "cc")) (EVar "t")) (EVar "st")) (EVar "mine")) (EVar "left")))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EApp (EVar "partDangling") (EVar "line")) (EVar "col")) (EVar "rest")) (arm (PTuple (PVar "mine") (PVar "left")) () (ETuple (EVar "mine") (EBinOp "::" (EApp (EApp (EApp (EApp (EVar "PComment") (EVar "cl")) (EVar "cc")) (EVar "t")) (EVar "st")) (EVar "left"))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "withBound" (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "Unit") (TyCon "Doc")) (TyCon "Doc"))))
(DFunDef false "withBound" ((PVar "b") (PVar "mk")) (EBlock (DoLet false false (PVar "saved") (EUnOp "!" (EVar "commentBoundRef"))) (DoLet false false (PVar "narrowed") (EBinOp "&&" (EBinOp ">" (EVar "b") (ELit (LInt 0))) (EBinOp "<" (EVar "b") (EVar "saved")))) (DoExpr (EIf (EVar "narrowed") (EApp (EApp (EVar "setRef") (EVar "commentBoundRef")) (EVar "b")) (ELit LUnit))) (DoLet false false (PVar "d") (EApp (EVar "mk") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentBoundRef")) (EVar "saved"))) (DoExpr (EVar "d"))))
(DTypeSig false "noClaimRef" (TyApp (TyCon "Ref") (TyCon "Bool")))
(DFunDef false "noClaimRef" () (EApp (EVar "Ref") (EVar "False")))
(DTypeSig false "noClaimDoc" (TyFun (TyFun (TyCon "Unit") (TyCon "Doc")) (TyCon "Doc")))
(DFunDef false "noClaimDoc" ((PVar "mk")) (EBlock (DoLet false false (PVar "saved") (EUnOp "!" (EVar "noClaimRef"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "noClaimRef")) (EVar "True"))) (DoLet false false (PVar "d") (EApp (EVar "mk") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "noClaimRef")) (EVar "saved"))) (DoExpr (EVar "d"))))
(DTypeSig false "pendingWithin" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))
(DFunDef false "pendingWithin" ((PVar "lo") (PVar "hi")) (EApp (EApp (EApp (EVar "anyWithin") (EVar "lo")) (EVar "hi")) (EUnOp "!" (EVar "commentsRef"))))
(DTypeSig false "anyWithin" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PComment")) (TyCon "Bool")))))
(DFunDef false "anyWithin" (PWild PWild (PList)) (EVar "False"))
(DFunDef false "anyWithin" ((PVar "lo") (PVar "hi") (PCons (PVar "c") (PVar "rest"))) (EBinOp "||" (EBinOp "&&" (EBinOp ">=" (EApp (EVar "pcLine") (EVar "c")) (EVar "lo")) (EBinOp "<=" (EApp (EVar "pcLine") (EVar "c")) (EVar "hi"))) (EApp (EApp (EApp (EVar "anyWithin") (EVar "lo")) (EVar "hi")) (EVar "rest"))))
(DTypeSig false "pendingInside" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "pendingInside" ((PVar "sl") (PVar "sc") (PVar "el") (PVar "ec")) (EApp (EApp (EApp (EApp (EApp (EVar "anyInside") (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec")) (EUnOp "!" (EVar "commentsRef"))))
(DTypeSig false "anyInside" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "PComment")) (TyCon "Bool")))))))
(DFunDef false "anyInside" (PWild PWild PWild PWild (PList)) (EVar "False"))
(DFunDef false "anyInside" ((PVar "sl") (PVar "sc") (PVar "el") (PVar "ec") (PCons (PCon "PComment" (PVar "cl") (PVar "cc") PWild PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "afterStart") (EBinOp "||" (EBinOp ">" (EVar "cl") (EVar "sl")) (EBinOp "&&" (EBinOp "==" (EVar "cl") (EVar "sl")) (EBinOp ">=" (EVar "cc") (EVar "sc"))))) (DoLet false false (PVar "beforeEnd") (EBinOp "||" (EBinOp "<" (EVar "cl") (EVar "el")) (EBinOp "&&" (EBinOp "==" (EVar "cl") (EVar "el")) (EBinOp "<" (EVar "cc") (EVar "ec"))))) (DoExpr (EBinOp "||" (EBinOp "&&" (EVar "afterStart") (EVar "beforeEnd")) (EApp (EApp (EApp (EApp (EApp (EVar "anyInside") (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec")) (EVar "rest"))))))
(DTypeSig false "noSpan" (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))
(DFunDef false "noSpan" () (ETuple (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0)) (ELit (LInt 0))))
(DTypeSig false "mergeSpan" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "mergeSpan" ((PTuple (PVar "a1") (PVar "c1") (PVar "b1") (PVar "d1")) (PTuple (PVar "a2") (PVar "c2") (PVar "b2") (PVar "d2"))) (EIf (EBinOp "==" (EVar "a1") (ELit (LInt 0))) (ETuple (EVar "a2") (EVar "c2") (EVar "b2") (EVar "d2")) (EIf (EBinOp "==" (EVar "a2") (ELit (LInt 0))) (ETuple (EVar "a1") (EVar "c1") (EVar "b1") (EVar "d1")) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "earliest") (ETuple (EVar "a1") (EVar "c1"))) (ETuple (EVar "a2") (EVar "c2"))) (arm (PTuple (PVar "sl") (PVar "sc")) () (EMatch (EApp (EApp (EVar "latest") (ETuple (EVar "b1") (EVar "d1"))) (ETuple (EVar "b2") (EVar "d2"))) (arm (PTuple (PVar "el") (PVar "ec")) () (ETuple (EVar "sl") (EVar "sc") (EVar "el") (EVar "ec")))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "earliest" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "earliest" ((PTuple (PVar "l1") (PVar "c1")) (PTuple (PVar "l2") (PVar "c2"))) (EIf (EBinOp "||" (EBinOp "<" (EVar "l1") (EVar "l2")) (EBinOp "&&" (EBinOp "==" (EVar "l1") (EVar "l2")) (EBinOp "<=" (EVar "c1") (EVar "c2")))) (ETuple (EVar "l1") (EVar "c1")) (ETuple (EVar "l2") (EVar "c2"))))
(DTypeSig false "latest" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "latest" ((PTuple (PVar "l1") (PVar "c1")) (PTuple (PVar "l2") (PVar "c2"))) (EIf (EBinOp "||" (EBinOp ">" (EVar "l1") (EVar "l2")) (EBinOp "&&" (EBinOp "==" (EVar "l1") (EVar "l2")) (EBinOp ">=" (EVar "c1") (EVar "c2")))) (ETuple (EVar "l1") (EVar "c1")) (ETuple (EVar "l2") (EVar "c2"))))
(DTypeSig false "spanStart" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyCon "Int")))
(DFunDef false "spanStart" ((PTuple (PVar "s") PWild PWild PWild)) (EVar "s"))
(DTypeSig false "spansOf" (TyFun (TyFun (TyVar "a") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "spansOf" (PWild (PList)) (EVar "noSpan"))
(DFunDef false "spansOf" ((PVar "f") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "f") (EVar "x"))) (EApp (EApp (EVar "spansOf") (EVar "f")) (EVar "xs"))))
(DTypeSig false "locSpan" (TyFun (TyCon "Loc") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "locSpan" ((PCon "Loc" PWild (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (ETuple (EVar "sl") (EVar "sc") (EVar "el") (EVar "ec")))
(DTypeSig false "exprSpan" (TyFun (TyCon "Expr") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "exprSpan" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "locSpan") (EVar "l")))
(DFunDef false "exprSpan" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "f"))) (EApp (EVar "exprSpan") (EVar "x"))))
(DFunDef false "exprSpan" ((PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "mergeSpan") (EApp (EApp (EVar "spansOf") (EVar "patSpan")) (EVar "pats"))) (EApp (EVar "exprSpan") (EVar "body"))))
(DFunDef false "exprSpan" ((PCon "ELet" PWild PWild (PVar "p") (PVar "rhs") (PVar "body"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "patSpan") (EVar "p"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "rhs"))) (EApp (EVar "exprSpan") (EVar "body")))))
(DFunDef false "exprSpan" ((PCon "EMatch" (PVar "sc") (PVar "arms"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "sc"))) (EApp (EApp (EVar "spansOf") (EVar "armSpan")) (EVar "arms"))))
(DFunDef false "exprSpan" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "c"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "t"))) (EApp (EVar "exprSpan") (EVar "e")))))
(DFunDef false "exprSpan" ((PCon "EBinOp" PWild (PVar "l") (PVar "r") PWild)) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "l"))) (EApp (EVar "exprSpan") (EVar "r"))))
(DFunDef false "exprSpan" ((PCon "EUnOp" PWild (PVar "e") PWild)) (EApp (EVar "exprSpan") (EVar "e")))
(DFunDef false "exprSpan" ((PCon "EInfix" PWild (PVar "l") (PVar "r"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "l"))) (EApp (EVar "exprSpan") (EVar "r"))))
(DFunDef false "exprSpan" ((PCon "EFieldAccess" (PVar "e") PWild PWild)) (EApp (EVar "exprSpan") (EVar "e")))
(DFunDef false "exprSpan" ((PCon "ETuple" (PVar "es"))) (EApp (EApp (EVar "spansOf") (EVar "exprSpan")) (EVar "es")))
(DFunDef false "exprSpan" ((PCon "EListLit" (PVar "es"))) (EApp (EApp (EVar "spansOf") (EVar "exprSpan")) (EVar "es")))
(DFunDef false "exprSpan" ((PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EVar "spansOf") (EVar "exprSpan")) (EVar "es")))
(DFunDef false "exprSpan" ((PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "lo"))) (EApp (EVar "exprSpan") (EVar "hi"))))
(DFunDef false "exprSpan" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "lo"))) (EApp (EVar "exprSpan") (EVar "hi"))))
(DFunDef false "exprSpan" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") PWild PWild)) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "e"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "lo"))) (EApp (EVar "exprSpan") (EVar "hi")))))
(DFunDef false "exprSpan" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "mergeSpan") (EApp (EApp (EVar "spansOf") (EVar "letBindSpan")) (EVar "binds"))) (EApp (EVar "exprSpan") (EVar "body"))))
(DFunDef false "exprSpan" ((PCon "ESection" (PCon "SecRight" PWild (PVar "e")))) (EApp (EVar "exprSpan") (EVar "e")))
(DFunDef false "exprSpan" ((PCon "ESection" (PCon "SecLeft" (PVar "e") PWild))) (EApp (EVar "exprSpan") (EVar "e")))
(DFunDef false "exprSpan" ((PCon "ESection" PWild)) (EVar "noSpan"))
(DFunDef false "exprSpan" ((PCon "EIndex" (PVar "e") (PVar "i") PWild)) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "e"))) (EApp (EVar "exprSpan") (EVar "i"))))
(DFunDef false "exprSpan" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "exprSpan") (EVar "e")))
(DFunDef false "exprSpan" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EVar "exprSpan") (EVar "e")))
(DFunDef false "exprSpan" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "spansOf") (EVar "stmtSpan")) (EVar "stmts")))
(DFunDef false "exprSpan" ((PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EVar "spansOf") (EVar "stmtSpan")) (EVar "stmts")))
(DFunDef false "exprSpan" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EVar "spansOf") (EVar "interpSpan")) (EVar "parts")))
(DFunDef false "exprSpan" ((PCon "EGuards" (PVar "arms"))) (EApp (EApp (EVar "spansOf") (EVar "guardArmSpan")) (EVar "arms")))
(DFunDef false "exprSpan" ((PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EVar "spansOf") (EVar "fieldAssignSpan")) (EVar "fs")))
(DFunDef false "exprSpan" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") PWild)) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "e"))) (EApp (EApp (EVar "spansOf") (EVar "fieldAssignSpan")) (EVar "fs"))))
(DFunDef false "exprSpan" ((PCon "EVariantUpdate" PWild (PVar "e") (PVar "fs"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "e"))) (EApp (EApp (EVar "spansOf") (EVar "fieldAssignSpan")) (EVar "fs"))))
(DFunDef false "exprSpan" ((PCon "EMapLit" PWild (PVar "kvs"))) (EApp (EApp (EVar "spansOf") (EVar "kvSpan")) (EVar "kvs")))
(DFunDef false "exprSpan" ((PCon "ESetLit" PWild (PVar "es"))) (EApp (EApp (EVar "spansOf") (EVar "exprSpan")) (EVar "es")))
(DFunDef false "exprSpan" ((PCon "EAsPat" PWild (PVar "e"))) (EApp (EVar "exprSpan") (EVar "e")))
(DFunDef false "exprSpan" (PWild) (EVar "noSpan"))
(DTypeSig false "interpSpan" (TyFun (TyCon "InterpPart") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "interpSpan" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "exprSpan") (EVar "e")))
(DFunDef false "interpSpan" (PWild) (EVar "noSpan"))
(DTypeSig false "kvSpan" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "kvSpan" ((PTuple (PVar "k") (PVar "v"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "exprSpan") (EVar "k"))) (EApp (EVar "exprSpan") (EVar "v"))))
(DTypeSig false "fieldAssignSpan" (TyFun (TyCon "FieldAssign") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "fieldAssignSpan" ((PCon "FieldAssign" PWild (PVar "v"))) (EApp (EVar "exprSpan") (EVar "v")))
(DTypeSig false "letBindSpan" (TyFun (TyCon "LetBind") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "letBindSpan" ((PCon "LetBind" PWild (PVar "clauses"))) (EApp (EApp (EVar "spansOf") (EVar "clauseSpan")) (EVar "clauses")))
(DTypeSig false "clauseSpan" (TyFun (TyCon "FunClause") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "clauseSpan" ((PCon "FunClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "mergeSpan") (EApp (EApp (EVar "spansOf") (EVar "patSpan")) (EVar "pats"))) (EApp (EVar "exprSpan") (EVar "body"))))
(DTypeSig false "patSpan" (TyFun (TyCon "Pat") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "patSpan" ((PCon "PVar" PWild (PVar "l"))) (EApp (EVar "locSpan") (EVar "l")))
(DFunDef false "patSpan" ((PCon "PAs" PWild (PVar "l") (PVar "p"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "locSpan") (EVar "l"))) (EApp (EVar "patSpan") (EVar "p"))))
(DFunDef false "patSpan" ((PCon "PCon" PWild (PVar "ps"))) (EApp (EApp (EVar "spansOf") (EVar "patSpan")) (EVar "ps")))
(DFunDef false "patSpan" ((PCon "PCons" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "patSpan") (EVar "a"))) (EApp (EVar "patSpan") (EVar "b"))))
(DFunDef false "patSpan" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "spansOf") (EVar "patSpan")) (EVar "ps")))
(DFunDef false "patSpan" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "spansOf") (EVar "patSpan")) (EVar "ps")))
(DFunDef false "patSpan" ((PCon "PRec" PWild (PVar "fs") PWild)) (EApp (EApp (EVar "spansOf") (EVar "recPatFieldSpan")) (EVar "fs")))
(DFunDef false "patSpan" (PWild) (EVar "noSpan"))
(DTypeSig false "recPatFieldSpan" (TyFun (TyCon "RecPatField") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "recPatFieldSpan" ((PCon "RecPatField" PWild (PVar "l") (PVar "q"))) (EMatch (EVar "q") (arm (PCon "Some" (PVar "p")) () (EApp (EApp (EVar "mergeSpan") (EApp (EVar "locSpan") (EVar "l"))) (EApp (EVar "patSpan") (EVar "p")))) (arm (PCon "None") () (EApp (EVar "locSpan") (EVar "l")))))
(DTypeSig false "guardSpan" (TyFun (TyCon "Guard") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "guardSpan" ((PCon "GBool" (PVar "e"))) (EApp (EVar "exprSpan") (EVar "e")))
(DFunDef false "guardSpan" ((PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "patSpan") (EVar "p"))) (EApp (EVar "exprSpan") (EVar "e"))))
(DTypeSig false "armSpan" (TyFun (TyCon "Arm") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "armSpan" ((PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "patSpan") (EVar "p"))) (EApp (EApp (EVar "mergeSpan") (EApp (EApp (EVar "spansOf") (EVar "guardSpan")) (EVar "gs"))) (EApp (EVar "exprSpan") (EVar "body")))))
(DTypeSig false "guardArmSpan" (TyFun (TyCon "GuardArm") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "guardArmSpan" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "mergeSpan") (EApp (EApp (EVar "spansOf") (EVar "guardSpan")) (EVar "gs"))) (EApp (EVar "exprSpan") (EVar "body"))))
(DTypeSig false "stmtSpan" (TyFun (TyCon "DoStmt") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "stmtSpan" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "exprSpan") (EVar "e")))
(DFunDef false "stmtSpan" ((PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "patSpan") (EVar "p"))) (EApp (EVar "exprSpan") (EVar "e"))))
(DFunDef false "stmtSpan" ((PCon "DoLet" PWild PWild (PVar "p") (PVar "e"))) (EApp (EApp (EVar "mergeSpan") (EApp (EVar "patSpan") (EVar "p"))) (EApp (EVar "exprSpan") (EVar "e"))))
(DFunDef false "stmtSpan" ((PCon "DoAssign" PWild (PVar "e"))) (EApp (EVar "exprSpan") (EVar "e")))
(DFunDef false "stmtSpan" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EApp (EVar "exprSpan") (EVar "e")))
(DData Private "Piece" () ((variant "Piece" (ConPos (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyFun (TyCon "Unit") (TyCon "Doc"))))) ())
(DData Private "PieceOut" () ((variant "PieceOut" (ConPos (TyCon "Bool") (TyCon "Doc")))) ())
(DTypeSig false "pieceOutDoc" (TyFun (TyCon "PieceOut") (TyCon "Doc")))
(DFunDef false "pieceOutDoc" ((PCon "PieceOut" PWild (PVar "d"))) (EVar "d"))
(DTypeSig false "exprPiece" (TyFun (TyCon "Expr") (TyCon "Piece")))
(DFunDef false "exprPiece" ((PVar "e")) (EMatch (EApp (EVar "exprSpan") (EVar "e")) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s")) (EVar "sc")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e")))))))
(DTypeSig false "pieceDocs" (TyFun (TyFun (TyCon "Bool") (TyCon "Doc")) (TyFun (TyApp (TyCon "List") (TyCon "Piece")) (TyApp (TyCon "List") (TyCon "PieceOut")))))
(DFunDef false "pieceDocs" ((PVar "sepAfter") (PVar "ps")) (EApp (EApp (EApp (EApp (EVar "pieceDocsGo") (EVar "sepAfter")) (EBinOp "+" (EApp (EVar "firstPieceCol") (EVar "ps")) (ELit (LInt 1)))) (ELit (LInt 0))) (EVar "ps")))
(DTypeSig false "pieceDocsHard" (TyFun (TyApp (TyCon "List") (TyCon "Piece")) (TyApp (TyCon "List") (TyCon "PieceOut"))))
(DFunDef false "pieceDocsHard" ((PVar "ps")) (EApp (EApp (EApp (EApp (EVar "pieceDocsGo") (EVar "noSep")) (EApp (EVar "firstPieceCol") (EVar "ps"))) (ELit (LInt 0))) (EVar "ps")))
(DTypeSig false "firstPieceCol" (TyFun (TyApp (TyCon "List") (TyCon "Piece")) (TyCon "Int")))
(DFunDef false "firstPieceCol" ((PCons (PCon "Piece" PWild (PVar "sc") PWild PWild PWild) PWild)) (EVar "sc"))
(DFunDef false "firstPieceCol" ((PList)) (ELit (LInt 0)))
(DTypeSig false "pieceDocsGo" (TyFun (TyFun (TyCon "Bool") (TyCon "Doc")) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Piece")) (TyApp (TyCon "List") (TyCon "PieceOut")))))))
(DFunDef false "pieceDocsGo" (PWild PWild PWild (PList)) (EListLit))
(DFunDef false "pieceDocsGo" ((PVar "sepAfter") (PVar "dangCol") (PVar "prevEnd") (PCons (PCon "Piece" (PVar "s") (PVar "sc") (PVar "en") (PVar "ec") (PVar "mk")) (PVar "rest"))) (EBlock (DoLet false false (PVar "isLast") (EApp (EVar "isEmptyL") (EVar "rest"))) (DoLet false false (PVar "bound") (EUnOp "!" (EVar "commentBoundRef"))) (DoLet false false (PVar "nextStart") (EMatch (EVar "rest") (arm (PCons (PCon "Piece" (PVar "s2") PWild PWild PWild PWild) PWild) () (EIf (EBinOp ">" (EVar "s2") (ELit (LInt 0))) (EVar "s2") (EVar "bound"))) (arm (PList) () (EVar "bound")))) (DoLet false false (PVar "claim") (EApp (EVar "not") (EUnOp "!" (EVar "noClaimRef")))) (DoLet false false (PVar "leading") (EIf (EBinOp "&&" (EVar "claim") (EBinOp ">" (EVar "s") (ELit (LInt 0)))) (EApp (EVar "popBefore") (EVar "s")) (EListLit))) (DoLet false false (PVar "firstLine") (EMatch (EVar "leading") (arm (PCons (PVar "c") PWild) () (EApp (EVar "pcLine") (EVar "c"))) (arm (PList) () (EVar "s")))) (DoLet false false (PVar "blankBefore") (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "prevEnd") (ELit (LInt 0))) (EBinOp ">" (EVar "s") (ELit (LInt 0)))) (EBinOp ">=" (EBinOp "-" (EVar "firstLine") (EVar "prevEnd")) (ELit (LInt 2))))) (DoLet false false (PVar "leadDoc") (EApp (EApp (EVar "leadingCommentsDoc") (EVar "leading")) (EVar "s"))) (DoLet false false (PVar "trailing") (EIf (EBinOp "&&" (EBinOp "&&" (EVar "claim") (EBinOp ">" (EVar "en") (ELit (LInt 0)))) (EBinOp ">" (EVar "nextStart") (EVar "en"))) (EApp (EApp (EVar "popTrailingAt") (EVar "en")) (EVar "ec")) (EListLit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentBoundRef")) (EVar "nextStart"))) (DoLet false false (PVar "d") (EApp (EVar "mk") (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "commentBoundRef")) (EVar "bound"))) (DoLet false false (PVar "trailDoc") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (EApp (EVar "LineComment") (EApp (EVar "pcText") (EVar "c"))))) (EVar "trailing")))) (DoLet false false (PVar "dangling") (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EVar "claim") (EVar "isLast")) (EBinOp ">" (EVar "s") (ELit (LInt 0)))) (EBinOp "==" (EVar "nextStart") (EUnOp "!" (EVar "declBoundRef")))) (EApp (EApp (EVar "popDanglingBefore") (EVar "nextStart")) (EVar "dangCol")) (EListLit))) (DoLet false false (PVar "dangDoc") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EVar "text") (EApp (EVar "pcText") (EVar "c")))))) (EVar "dangling")))) (DoLet false false (PVar "out") (EApp (EApp (EVar "Cat") (EVar "leadDoc")) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EApp (EVar "Cat") (EApp (EVar "sepAfter") (EVar "isLast"))) (EApp (EApp (EVar "Cat") (EVar "trailDoc")) (EVar "dangDoc")))))) (DoExpr (EBinOp "::" (EApp (EApp (EVar "PieceOut") (EVar "blankBefore")) (EVar "out")) (EApp (EApp (EApp (EApp (EVar "pieceDocsGo") (EVar "sepAfter")) (EVar "dangCol")) (EIf (EBinOp ">" (EVar "en") (ELit (LInt 0))) (EVar "en") (EVar "prevEnd"))) (EVar "rest"))))))
(DTypeSig false "leadingCommentsDoc" (TyFun (TyApp (TyCon "List") (TyCon "PComment")) (TyFun (TyCon "Int") (TyCon "Doc"))))
(DFunDef false "leadingCommentsDoc" ((PList) PWild) (EVar "Nil"))
(DFunDef false "leadingCommentsDoc" ((PCons (PVar "c") (PVar "rest")) (PVar "s")) (EBlock (DoLet false false (PVar "nextLine") (EMatch (EVar "rest") (arm (PCons (PVar "c2") PWild) () (EApp (EVar "pcLine") (EVar "c2"))) (arm (PList) () (EVar "s")))) (DoLet false false (PVar "gap") (EIf (EBinOp ">=" (EBinOp "-" (EVar "nextLine") (EApp (EVar "pcEndLine") (EVar "c"))) (ELit (LInt 2))) (EVar "BlankLine") (EVar "Nil"))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EVar "pcText") (EVar "c")))) (EApp (EApp (EVar "Cat") (EVar "gap")) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "leadingCommentsDoc") (EVar "rest")) (EVar "s"))))))))
(DTypeSig false "noSep" (TyFun (TyCon "Bool") (TyCon "Doc")))
(DFunDef false "noSep" (PWild) (EVar "Nil"))
(DTypeSig false "soloDoc" (TyFun (TyCon "Expr") (TyFun (TyFun (TyCon "Unit") (TyCon "Doc")) (TyCon "Doc"))))
(DFunDef false "soloDoc" ((PVar "e") (PVar "mk")) (EMatch (EApp (EVar "exprSpan") (EVar "e")) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EApp (EVar "joinLine") (EApp (EApp (EVar "pieceDocs") (EVar "noSep")) (EListLit (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s")) (EVar "sc")) (EVar "en")) (EVar "ec")) (EVar "mk"))))))))
(DTypeSig false "commaSep" (TyFun (TyCon "Bool") (TyCon "Doc")))
(DFunDef false "commaSep" ((PVar "isLast")) (EIf (EVar "isLast") (EVar "trailingCommaDoc") (EApp (EVar "text") (ELit (LString ",")))))
(DTypeSig false "joinHard" (TyFun (TyApp (TyCon "List") (TyCon "PieceOut")) (TyCon "Doc")))
(DFunDef false "joinHard" ((PList)) (EVar "Nil"))
(DFunDef false "joinHard" ((PCons (PCon "PieceOut" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "joinHardRest") (EVar "rest"))))
(DTypeSig false "joinHardRest" (TyFun (TyApp (TyCon "List") (TyCon "PieceOut")) (TyCon "Doc")))
(DFunDef false "joinHardRest" ((PList)) (EVar "Nil"))
(DFunDef false "joinHardRest" ((PCons (PCon "PieceOut" (PVar "blank") (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "Cat") (EIf (EVar "blank") (EVar "BlankLine") (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "joinHardRest") (EVar "rest"))))))
(DTypeSig false "joinLine" (TyFun (TyApp (TyCon "List") (TyCon "PieceOut")) (TyCon "Doc")))
(DFunDef false "joinLine" ((PList)) (EVar "Nil"))
(DFunDef false "joinLine" ((PCons (PCon "PieceOut" PWild (PVar "d")) (PVar "rest"))) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "pieceOutDoc") (EVar "p"))))) (EVar "rest")))))
(DTypeSig false "anyCommented" (TyFun (TyApp (TyCon "List") (TyCon "Piece")) (TyCon "Bool")))
(DFunDef false "anyCommented" ((PList)) (EVar "False"))
(DFunDef false "anyCommented" ((PVar "ps")) (EBlock (DoLet false false (PVar "lo") (EApp (EVar "spanStart") (EApp (EApp (EVar "spansOf") (EVar "pieceSpan")) (EVar "ps")))) (DoExpr (EBinOp "&&" (EBinOp ">" (EVar "lo") (ELit (LInt 0))) (EApp (EApp (EVar "pendingWithin") (EVar "lo")) (EBinOp "-" (EUnOp "!" (EVar "commentBoundRef")) (ELit (LInt 1))))))))
(DTypeSig false "pieceSpan" (TyFun (TyCon "Piece") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))))
(DFunDef false "pieceSpan" ((PCon "Piece" (PVar "s") (PVar "sc") (PVar "en") (PVar "ec") PWild)) (ETuple (EVar "s") (EVar "sc") (EVar "en") (EVar "ec")))
(DTypeSig false "delimitedPieces" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Piece")) (TyCon "Doc"))))))
(DFunDef false "delimitedPieces" ((PVar "open_") (PVar "close_") PWild (PList)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "open_"))) (EApp (EVar "text") (EVar "close_"))))
(DFunDef false "delimitedPieces" ((PVar "open_") (PVar "close_") (PVar "forced") (PVar "ps")) (EBlock (DoLet false false (PVar "outs") (EApp (EApp (EVar "pieceDocs") (EVar "commaSep")) (EVar "ps"))) (DoExpr (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "open_"))) (EApp (EApp (EVar "Cat") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EIf (EVar "forced") (EVar "Hardline") (EVar "Softline"))) (EApp (EVar "joinLine") (EVar "outs"))))) (EApp (EApp (EVar "Cat") (EVar "Softline")) (EApp (EVar "text") (EVar "close_")))))))))
(DTypeSig false "filledDocs" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Doc")) (TyCon "Doc")))))
(DFunDef false "filledDocs" ((PVar "open_") (PVar "close_") (PList)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "open_"))) (EApp (EVar "text") (EVar "close_"))))
(DFunDef false "filledDocs" ((PVar "open_") (PVar "close_") (PVar "items")) (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "open_"))) (EApp (EApp (EVar "Cat") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Softline")) (EApp (EApp (EVar "Fill") (EVar "False")) (EApp (EVar "commaJoinFill") (EVar "items")))))) (EApp (EApp (EVar "Cat") (EVar "Softline")) (EApp (EVar "text") (EVar "close_")))))))
(DTypeSig false "commaJoinFill" (TyFun (TyApp (TyCon "List") (TyCon "Doc")) (TyApp (TyCon "List") (TyCon "Doc"))))
(DFunDef false "commaJoinFill" ((PList)) (EListLit))
(DFunDef false "commaJoinFill" ((PList (PVar "d"))) (EListLit (EVar "d")))
(DFunDef false "commaJoinFill" ((PCons (PVar "d") (PVar "ds"))) (EBinOp "::" (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "text") (ELit (LString ",")))) (EApp (EVar "commaJoinFill") (EVar "ds"))))
(DTypeSig false "bracedPieces" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Piece")) (TyCon "Doc")))))
(DFunDef false "bracedPieces" ((PVar "open_") PWild (PList)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "open_"))) (EApp (EVar "text") (ELit (LString "}")))))
(DFunDef false "bracedPieces" ((PVar "open_") (PVar "forced") (PVar "ps")) (EBlock (DoLet false false (PVar "outs") (EApp (EApp (EVar "pieceDocs") (EVar "commaSep")) (EVar "ps"))) (DoExpr (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "open_"))) (EApp (EApp (EVar "Cat") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EIf (EVar "forced") (EVar "Hardline") (EVar "Line"))) (EApp (EVar "joinLine") (EVar "outs"))))) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "text") (ELit (LString "}"))))))))))
(DTypeSig false "trailingCommasRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "trailingCommasRef" () (EApp (EVar "Ref") (EApp (EVar "arrayFromList") (EListLit))))
(DTypeSig true "setTrailingCommas" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyCon "Unit")))
(DFunDef false "setTrailingCommas" ((PVar "cs")) (EApp (EApp (EVar "setRef") (EVar "trailingCommasRef")) (EApp (EVar "arrayFromList") (EApp (EApp (EVar "sortBy") (EVar "cmpPos")) (EVar "cs")))))
(DTypeSig false "cmpPos" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "Ordering"))))
(DFunDef false "cmpPos" ((PTuple (PVar "l1") (PVar "c1")) (PTuple (PVar "l2") (PVar "c2"))) (EIf (EBinOp "==" (EVar "l1") (EVar "l2")) (EApp (EApp (EMethodRef "compare") (EVar "c1")) (EVar "c2")) (EApp (EApp (EMethodRef "compare") (EVar "l1")) (EVar "l2"))))
(DTypeSig false "posLowerBound" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int")))))))
(DFunDef false "posLowerBound" ((PVar "arr") (PVar "line") (PVar "col") (PVar "lo") (PVar "hi")) (EIf (EBinOp ">=" (EVar "lo") (EVar "hi")) (EVar "lo") (EBlock (DoLet false false (PVar "mid") (EBinOp "/" (EBinOp "+" (EVar "lo") (EVar "hi")) (ELit (LInt 2)))) (DoExpr (EMatch (EApp (EApp (EMethodRef "index") (EVar "arr")) (EVar "mid")) (arm (PTuple (PVar "l") (PVar "c")) () (EIf (EBinOp "||" (EBinOp "<" (EVar "l") (EVar "line")) (EBinOp "&&" (EBinOp "==" (EVar "l") (EVar "line")) (EBinOp "<" (EVar "c") (EVar "col")))) (EApp (EApp (EApp (EApp (EApp (EVar "posLowerBound") (EVar "arr")) (EVar "line")) (EVar "col")) (EBinOp "+" (EVar "mid") (ELit (LInt 1)))) (EVar "hi")) (EApp (EApp (EApp (EApp (EApp (EVar "posLowerBound") (EVar "arr")) (EVar "line")) (EVar "col")) (EVar "lo")) (EVar "mid")))))))))
(DTypeSig false "hasTrailingComma" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "hasTrailingComma" ((PVar "lastLine") (PVar "lastCol") (PVar "endLine") (PVar "endCol")) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "trailingCommasRef"))) (DoLet false false (PVar "i") (EApp (EApp (EApp (EApp (EApp (EVar "posLowerBound") (EVar "arr")) (EVar "lastLine")) (EVar "lastCol")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "arr"))) (EVar "False") (EMatch (EApp (EApp (EMethodRef "index") (EVar "arr")) (EVar "i")) (arm (PTuple (PVar "l") (PVar "c")) () (EBinOp "||" (EBinOp "<" (EVar "l") (EVar "endLine")) (EBinOp "&&" (EBinOp "==" (EVar "l") (EVar "endLine")) (EBinOp "<" (EVar "c") (EVar "endCol"))))))))))
(DTypeSig false "exprEndPos" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "Int") (TyCon "Int")))))
(DFunDef false "exprEndPos" ((PCon "ELoc" (PCon "Loc" PWild PWild PWild (PVar "el") (PVar "ec")) PWild)) (EApp (EVar "Some") (ETuple (EVar "el") (EVar "ec"))))
(DFunDef false "exprEndPos" ((PCon "EApp" PWild (PVar "x"))) (EApp (EVar "exprEndPos") (EVar "x")))
(DFunDef false "exprEndPos" ((PCon "EBinOp" PWild PWild (PVar "r") PWild)) (EApp (EVar "exprEndPos") (EVar "r")))
(DFunDef false "exprEndPos" ((PCon "EFieldAccess" (PVar "e") PWild PWild)) (EApp (EVar "exprEndPos") (EVar "e")))
(DFunDef false "exprEndPos" (PWild) (EVar "None"))
(DTypeSig false "literalForced" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Bool"))))
(DFunDef false "literalForced" ((PCon "Some" (PCon "Loc" PWild PWild PWild (PVar "el") (PVar "ec"))) (PVar "es")) (EMatch (EApp (EVar "last") (EVar "es")) (arm (PCon "Some" (PVar "e")) () (EMatch (EApp (EVar "exprEndPos") (EVar "e")) (arm (PCon "Some" (PTuple (PVar "ll") (PVar "lc"))) () (EApp (EApp (EApp (EApp (EVar "hasTrailingComma") (EVar "ll")) (EVar "lc")) (EVar "el")) (EVar "ec"))) (arm (PCon "None") () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DFunDef false "literalForced" ((PCon "None") PWild) (EVar "False"))
(DTypeSig false "fieldForced" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "FieldAssign")) (TyCon "Bool"))))
(DFunDef false "fieldForced" ((PVar "loc") (PVar "fs")) (EApp (EApp (EVar "literalForced") (EVar "loc")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "f")) (EApp (EVar "fieldAssignValue") (EVar "f")))) (EVar "fs"))))
(DTypeSig false "fieldAssignValue" (TyFun (TyCon "FieldAssign") (TyCon "Expr")))
(DFunDef false "fieldAssignValue" ((PCon "FieldAssign" PWild (PVar "v"))) (EVar "v"))
(DTypeSig false "kvForced" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Expr") (TyCon "Expr"))) (TyCon "Bool"))))
(DFunDef false "kvForced" ((PVar "loc") (PVar "kvs")) (EApp (EApp (EVar "literalForced") (EVar "loc")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "kv")) (EApp (EVar "snd") (EVar "kv")))) (EVar "kvs"))))
(DTypeSig false "escapeCharLit" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "escapeCharLit" ((PVar "c")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "'"))) (ELit (LString "\\'")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "\\"))) (ELit (LString "\\\\")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "\n"))) (ELit (LString "\\n")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "\t"))) (ELit (LString "\\t")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "\r"))) (ELit (LString "\\r")) (EIf (EBinOp "==" (EVar "c") (ELit (LString "\0"))) (ELit (LString "\\0")) (EIf (EVar "otherwise") (EVar "c") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))
(DTypeSig false "escStringLit" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "escStringLit" ((PVar "s")) (EBinOp "++" (EBinOp "++" (ELit (LString "\"")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "escSChars") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0))))) (ELit (LString "\""))))
(DTypeSig false "escSChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "escSChars" ((PVar "cs") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "escSOne") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EVar "escSChars") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "escSOne" (TyFun (TyCon "Char") (TyCon "String")))
(DFunDef false "escSOne" ((PVar "c")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\\"))) (ELit (LString "\\\\")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\""))) (ELit (LString "\\\"")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\n"))) (ELit (LString "\\n")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\t"))) (ELit (LString "\\t")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\r"))) (ELit (LString "\\r")) (EIf (EBinOp "==" (EVar "c") (ELit (LChar "\0"))) (ELit (LString "\\0")) (EIf (EBinOp "<" (EApp (EVar "charCode") (EVar "c")) (ELit (LInt 32))) (EBinOp "++" (EBinOp "++" (ELit (LString "\\u{")) (EApp (EMethodRef "display") (EApp (EVar "escOneHex2") (EApp (EVar "charCode") (EVar "c"))))) (ELit (LString "}"))) (EIf (EVar "otherwise") (EApp (EVar "charToStr") (EVar "c")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))))
(DTypeSig false "printLit" (TyFun (TyCon "Lit") (TyCon "Doc")))
(DFunDef false "printLit" ((PCon "LInt" (PVar "n"))) (EApp (EVar "text") (EApp (EVar "intToString") (EVar "n"))))
(DFunDef false "printLit" ((PCon "LFloat" (PVar "f"))) (EBlock (DoLet false false (PVar "s") (EApp (EVar "floatToString") (EVar "f"))) (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "s"))) (DoExpr (EApp (EVar "text") (EIf (EBinOp "&&" (EBinOp ">" (EVar "n") (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "-" (EVar "n") (ELit (LInt 1)))) (EVar "n")) (EVar "s")) (ELit (LString ".")))) (EBinOp "++" (EVar "s") (ELit (LString "0"))) (EVar "s"))))))
(DFunDef false "printLit" ((PCon "LString" (PVar "s"))) (EApp (EVar "text") (EApp (EVar "escStringLit") (EVar "s"))))
(DFunDef false "printLit" ((PCon "LChar" (PVar "c"))) (EApp (EVar "text") (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EApp (EVar "escapeCharLit") (EVar "c"))) (ELit (LString "'")))))
(DFunDef false "printLit" ((PCon "LBool" (PVar "b"))) (EApp (EVar "text") (EIf (EVar "b") (ELit (LString "True")) (ELit (LString "False")))))
(DFunDef false "printLit" ((PCon "LUnit")) (EApp (EVar "text") (ELit (LString "()"))))
(DTypeSig false "isNegLit" (TyFun (TyCon "Lit") (TyCon "Bool")))
(DFunDef false "isNegLit" ((PCon "LInt" (PVar "n"))) (EBinOp "<" (EVar "n") (ELit (LInt 0))))
(DFunDef false "isNegLit" ((PCon "LFloat" (PVar "f"))) (EBlock (DoLet false false (PVar "s") (EApp (EVar "floatToString") (EVar "f"))) (DoExpr (EBinOp "&&" (EBinOp ">" (EApp (EVar "stringLength") (EVar "s")) (ELit (LInt 0))) (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (ELit (LInt 1))) (EVar "s")) (ELit (LString "-")))))))
(DFunDef false "isNegLit" (PWild) (EVar "False"))
(DTypeSig false "tyConSurface" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "tyConSurface" ((PLit (LString "__tuple2__"))) (ELit (LString "(,)")))
(DFunDef false "tyConSurface" ((PLit (LString "__tuple3__"))) (ELit (LString "(,,)")))
(DFunDef false "tyConSurface" ((PLit (LString "__tuple4__"))) (ELit (LString "(,,,)")))
(DFunDef false "tyConSurface" ((PLit (LString "__tuple5__"))) (ELit (LString "(,,,,)")))
(DFunDef false "tyConSurface" ((PLit (LString "__tuple6__"))) (ELit (LString "(,,,,,)")))
(DFunDef false "tyConSurface" ((PLit (LString "__tuple7__"))) (ELit (LString "(,,,,,,)")))
(DFunDef false "tyConSurface" ((PLit (LString "__tuple8__"))) (ELit (LString "(,,,,,,,)")))
(DFunDef false "tyConSurface" ((PVar "n")) (EVar "n"))
(DTypeSig false "printType" (TyFun (TyCon "Ty") (TyCon "Doc")))
(DFunDef false "printType" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EApp (EVar "text") (EApp (EVar "tyConSurface") (EVar "n"))))
(DFunDef false "printType" ((PCon "TyVar" (PVar "n"))) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printType" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printTypeAppLhs") (EVar "a"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printTypeAtom") (EVar "b")))))
(DFunDef false "printType" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printTypeFunLhs") (EVar "a"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " -> ")))) (EApp (EVar "printType") (EVar "b")))))
(DFunDef false "printType" ((PCon "TyTuple" (PVar "ts"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EVar "printType")) (EVar "ts")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printType" ((PCon "TyEffect" (PVar "es") (PVar "tail") (PVar "t"))) (EBlock (DoLet false false (PVar "inside") (EApp (EApp (EVar "effectInside") (EVar "es")) (EVar "tail"))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "<")))) (EApp (EApp (EVar "Cat") (EVar "inside")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "> ")))) (EApp (EVar "printTypeAppLhs") (EVar "t"))))))))
(DFunDef false "printType" ((PCon "TyRow" (PList) (PCons (PVar "a") (PCons (PVar "b") (PVar "rest"))) PWild)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EBinOp "::" (EVar "a") (EBinOp "::" (EVar "b") (EVar "rest")))))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printType" ((PCon "TyRow" (PVar "es") (PVar "tail") PWild)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "<")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "effectInside") (EVar "es")) (EVar "tail"))) (EApp (EVar "text") (ELit (LString ">"))))))
(DFunDef false "printType" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EApp (EApp (EVar "Cat") (EApp (EVar "constraintsDoc") (EVar "cs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " => ")))) (EApp (EVar "printType") (EVar "t")))))
(DTypeSig false "constraintsDoc" (TyFun (TyApp (TyCon "List") (TyCon "Constraint")) (TyCon "Doc")))
(DFunDef false "constraintsDoc" ((PList (PVar "c"))) (EApp (EVar "printConstraint") (EVar "c")))
(DFunDef false "constraintsDoc" ((PVar "cs")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EVar "printConstraint")) (EVar "cs")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DTypeSig false "sigTypeDoc" (TyFun (TyCon "Ty") (TyCon "Doc")))
(DFunDef false "sigTypeDoc" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EApp (EVar "constraintsDoc") (EVar "cs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =>")))) (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "arrowChain") (EVar "t"))))))))
(DFunDef false "sigTypeDoc" ((PVar "t")) (EApp (EVar "group") (EApp (EVar "nest") (EApp (EVar "arrowChain") (EVar "t")))))
(DTypeSig false "arrowChain" (TyFun (TyCon "Ty") (TyCon "Doc")))
(DFunDef false "arrowChain" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printTypeFunLhs") (EVar "a"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ->")))) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "arrowChain") (EVar "b"))))))
(DFunDef false "arrowChain" ((PVar "t")) (EApp (EVar "printType") (EVar "t")))
(DTypeSig false "effectInside" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Doc"))))
(DFunDef false "effectInside" ((PVar "es") (PList)) (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EVar "effAtomDoc")) (EVar "es"))))
(DFunDef false "effectInside" ((PList) (PVar "tails")) (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails"))))
(DFunDef false "effectInside" ((PVar "es") (PVar "tails")) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EVar "effAtomDoc")) (EVar "es")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " | ")))) (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails"))))))
(DTypeSig false "effAtomDoc" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "Doc")))
(DFunDef false "effAtomDoc" ((PTuple (PVar "l") (PCon "None"))) (EApp (EVar "text") (EVar "l")))
(DFunDef false "effAtomDoc" ((PTuple (PVar "l") (PCon "Some" (PVar "s")))) (EApp (EVar "text") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStringLit") (EVar "s")))) (ELit (LString "")))))
(DTypeSig false "printConstraint" (TyFun (TyCon "Constraint") (TyCon "Doc")))
(DFunDef false "printConstraint" ((PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PVar "args"))) false)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "iface"))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printTypeAtom") (EVar "a"))))) (EVar "args")))))
(DTypeSig false "printTypeAtom" (TyFun (TyCon "Ty") (TyCon "Doc")))
(DFunDef false "printTypeAtom" ((PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EApp (EVar "text") (EApp (EVar "tyConSurface") (EVar "n"))))
(DFunDef false "printTypeAtom" ((PCon "TyVar" (PVar "n"))) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printTypeAtom" ((PCon "TyTuple" (PVar "ts"))) (EApp (EVar "printType") (EApp (EVar "TyTuple") (EVar "ts"))))
(DFunDef false "printTypeAtom" ((PCon "TyRow" (PVar "es") (PVar "tail") (PVar "loc"))) (EApp (EVar "printType") (EApp (EApp (EApp (EVar "TyRow") (EVar "es")) (EVar "tail")) (EVar "loc"))))
(DFunDef false "printTypeAtom" ((PVar "t")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printType") (EVar "t"))) (EApp (EVar "text") (ELit (LString ")"))))))
(DTypeSig false "printTypeFunLhs" (TyFun (TyCon "Ty") (TyCon "Doc")))
(DFunDef false "printTypeFunLhs" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printType") (EApp (EApp (EVar "TyFun") (EVar "a")) (EVar "b")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printTypeFunLhs" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printType") (EApp (EApp (EVar "TyConstrained") (EVar "cs")) (EVar "t")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printTypeFunLhs" ((PVar "t")) (EApp (EVar "printType") (EVar "t")))
(DTypeSig false "printTypeAppLhs" (TyFun (TyCon "Ty") (TyCon "Doc")))
(DFunDef false "printTypeAppLhs" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EVar "printType") (EApp (EApp (EVar "TyApp") (EVar "a")) (EVar "b"))))
(DFunDef false "printTypeAppLhs" ((PVar "t")) (EApp (EVar "printTypeAtom") (EVar "t")))
(DTypeSig false "printPat" (TyFun (TyCon "Pat") (TyCon "Doc")))
(DFunDef false "printPat" ((PCon "PVar" (PVar "x") PWild)) (EApp (EVar "text") (EVar "x")))
(DFunDef false "printPat" ((PCon "PWild")) (EApp (EVar "text") (ELit (LString "_"))))
(DFunDef false "printPat" ((PCon "PLit" (PVar "l"))) (EApp (EVar "printLit") (EVar "l")))
(DFunDef false "printPat" ((PCon "PCon" (PVar "c") (PList))) (EApp (EVar "text") (EVar "c")))
(DFunDef false "printPat" ((PCon "PCon" (PVar "c") (PVar "pats"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "c"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "pats")))) (EApp (EVar "text") (ELit (LString ")")))))))
(DFunDef false "printPat" ((PCon "PCons" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPatAtom") (EVar "a"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " :: ")))) (EApp (EVar "printPat") (EVar "b")))))
(DFunDef false "printPat" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EVar "printPatArm")) (EVar "ps")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printPat" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "[")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EVar "printPatArm")) (EVar "ps")))) (EApp (EVar "text") (ELit (LString "]"))))))
(DFunDef false "printPat" ((PCon "PAs" (PVar "x") PWild (PVar "inner"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "x"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "@")))) (EApp (EVar "printPatAtom") (EVar "inner")))))
(DFunDef false "printPat" ((PCon "PRec" (PVar "name") (PVar "fields") (PVar "rest"))) (EBlock (DoLet false false (PVar "fieldDocs") (EApp (EApp (EMethodRef "map") (EVar "recPatFieldDoc")) (EVar "fields"))) (DoLet false false (PVar "all") (EIf (EVar "rest") (EBinOp "++" (EVar "fieldDocs") (EListLit (EApp (EVar "text") (ELit (LString "..."))))) (EVar "fieldDocs"))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " { ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EDictApp "all"))) (EApp (EVar "text") (ELit (LString " }")))))))))
(DFunDef false "printPat" ((PCon "PRng" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printLit") (EVar "lo"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EIf (EVar "incl") (ELit (LString "..=")) (ELit (LString ".."))))) (EApp (EVar "printLit") (EVar "hi")))))
(DTypeSig false "recPatFieldDoc" (TyFun (TyCon "RecPatField") (TyCon "Doc")))
(DFunDef false "recPatFieldDoc" ((PCon "RecPatField" (PVar "k") PWild (PCon "None"))) (EApp (EVar "text") (EVar "k")))
(DFunDef false "recPatFieldDoc" ((PCon "RecPatField" (PVar "k") PWild (PCon "Some" (PVar "q")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "k"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EVar "printPat") (EVar "q")))))
(DTypeSig false "printPatAtom" (TyFun (TyCon "Pat") (TyCon "Doc")))
(DFunDef false "printPatAtom" ((PCon "PVar" (PVar "x") (PVar "l"))) (EApp (EVar "printPat") (EApp (EApp (EVar "PVar") (EVar "x")) (EVar "l"))))
(DFunDef false "printPatAtom" ((PCon "PWild")) (EApp (EVar "printPat") (EVar "PWild")))
(DFunDef false "printPatAtom" ((PCon "PLit" (PVar "l"))) (EApp (EVar "printPat") (EApp (EVar "PLit") (EVar "l"))))
(DFunDef false "printPatAtom" ((PCon "PCon" (PVar "c") (PVar "ps"))) (EApp (EVar "printPat") (EApp (EApp (EVar "PCon") (EVar "c")) (EVar "ps"))))
(DFunDef false "printPatAtom" ((PCon "PTuple" (PVar "ps"))) (EApp (EVar "printPat") (EApp (EVar "PTuple") (EVar "ps"))))
(DFunDef false "printPatAtom" ((PCon "PList" (PVar "ps"))) (EApp (EVar "printPat") (EApp (EVar "PList") (EVar "ps"))))
(DFunDef false "printPatAtom" ((PCon "PRec" (PVar "n") (PVar "fs") (PVar "r"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPat") (EApp (EApp (EApp (EVar "PRec") (EVar "n")) (EVar "fs")) (EVar "r")))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printPatAtom" ((PCon "PRng" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EVar "printPat") (EApp (EApp (EApp (EVar "PRng") (EVar "lo")) (EVar "hi")) (EVar "incl"))))
(DFunDef false "printPatAtom" ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPat") (EVar "p"))) (EApp (EVar "text") (ELit (LString ")"))))))
(DTypeSig false "printPatArm" (TyFun (TyCon "Pat") (TyCon "Doc")))
(DFunDef false "printPatArm" ((PCon "PCon" (PVar "c") (PCons (PVar "p") (PVar "ps")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "c"))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "q")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "q"))))) (EBinOp "::" (EVar "p") (EVar "ps"))))))
(DFunDef false "printPatArm" ((PVar "p")) (EApp (EVar "printPat") (EVar "p")))
(DTypeSig false "precTop" (TyCon "Int"))
(DFunDef false "precTop" () (ELit (LInt 0)))
(DTypeSig false "precAssign" (TyCon "Int"))
(DFunDef false "precAssign" () (ELit (LInt 1)))
(DTypeSig false "precPipe" (TyCon "Int"))
(DFunDef false "precPipe" () (ELit (LInt 2)))
(DTypeSig false "precCompose" (TyCon "Int"))
(DFunDef false "precCompose" () (ELit (LInt 3)))
(DTypeSig false "precOr" (TyCon "Int"))
(DFunDef false "precOr" () (ELit (LInt 4)))
(DTypeSig false "precAnd" (TyCon "Int"))
(DFunDef false "precAnd" () (ELit (LInt 5)))
(DTypeSig false "precCmp" (TyCon "Int"))
(DFunDef false "precCmp" () (ELit (LInt 6)))
(DTypeSig false "precCons" (TyCon "Int"))
(DFunDef false "precCons" () (ELit (LInt 7)))
(DTypeSig false "precAppend" (TyCon "Int"))
(DFunDef false "precAppend" () (ELit (LInt 8)))
(DTypeSig false "precAdd" (TyCon "Int"))
(DFunDef false "precAdd" () (ELit (LInt 9)))
(DTypeSig false "precMul" (TyCon "Int"))
(DFunDef false "precMul" () (ELit (LInt 10)))
(DTypeSig false "precInfix" (TyCon "Int"))
(DFunDef false "precInfix" () (ELit (LInt 11)))
(DTypeSig false "precApp" (TyCon "Int"))
(DFunDef false "precApp" () (ELit (LInt 12)))
(DTypeSig false "precUnary" (TyCon "Int"))
(DFunDef false "precUnary" () (ELit (LInt 13)))
(DTypeSig false "precPostfix" (TyCon "Int"))
(DFunDef false "precPostfix" () (ELit (LInt 14)))
(DTypeSig false "precAtom" (TyCon "Int"))
(DFunDef false "precAtom" () (ELit (LInt 15)))
(DTypeSig false "binopPrec" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "binopPrec" ((PVar "op")) (EIf (EBinOp "==" (EVar "op") (ELit (LString ":="))) (EVar "precAssign") (EIf (EBinOp "==" (EVar "op") (ELit (LString "|>"))) (EVar "precPipe") (EIf (EBinOp "==" (EVar "op") (ELit (LString ">>"))) (EVar "precCompose") (EIf (EBinOp "==" (EVar "op") (ELit (LString "<<"))) (EVar "precCompose") (EIf (EBinOp "==" (EVar "op") (ELit (LString "||"))) (EVar "precOr") (EIf (EBinOp "==" (EVar "op") (ELit (LString "&&"))) (EVar "precAnd") (EIf (EBinOp "==" (EVar "op") (ELit (LString "=="))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString "/="))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString "<"))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString ">"))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString "<="))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString ">="))) (EVar "precCmp") (EIf (EBinOp "==" (EVar "op") (ELit (LString "::"))) (EVar "precCons") (EIf (EBinOp "==" (EVar "op") (ELit (LString "++"))) (EVar "precAppend") (EIf (EBinOp "==" (EVar "op") (ELit (LString "+"))) (EVar "precAdd") (EIf (EBinOp "==" (EVar "op") (ELit (LString "-"))) (EVar "precAdd") (EIf (EBinOp "==" (EVar "op") (ELit (LString "*"))) (EVar "precMul") (EIf (EBinOp "==" (EVar "op") (ELit (LString "/"))) (EVar "precMul") (EIf (EVar "otherwise") (EVar "precInfix") (EApp (EVar "__fallthrough__") (ELit LUnit))))))))))))))))))))))
(DTypeSig false "isRightAssoc" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isRightAssoc" ((PLit (LString "::"))) (EVar "True"))
(DFunDef false "isRightAssoc" ((PLit (LString ":="))) (EVar "True"))
(DFunDef false "isRightAssoc" (PWild) (EVar "False"))
(DTypeSig false "exprPrec" (TyFun (TyCon "Expr") (TyCon "Int")))
(DFunDef false "exprPrec" ((PCon "ELit" (PVar "l"))) (EIf (EApp (EVar "isNegLit") (EVar "l")) (EVar "precUnary") (EVar "precAtom")))
(DFunDef false "exprPrec" ((PCon "ENumLit" (PVar "n") PWild PWild PWild)) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EVar "precUnary") (EVar "precAtom")))
(DFunDef false "exprPrec" ((PCon "EVar" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EVarId" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EMethodRef" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EDictApp" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ETuple" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EArrayLit" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EListLit" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EMapLit" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ESetLit" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EStringInterp" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ERecordCreate" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ERecordUpdate" PWild PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EVariantUpdate" PWild PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ERangeList" PWild PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ERangeArray" PWild PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ESlice" PWild PWild PWild PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EFieldAccess" PWild PWild PWild)) (EVar "precPostfix"))
(DFunDef false "exprPrec" ((PCon "EIndex" PWild PWild PWild)) (EVar "precPostfix"))
(DFunDef false "exprPrec" ((PCon "EUnOp" PWild PWild PWild)) (EVar "precUnary"))
(DFunDef false "exprPrec" ((PCon "EApp" PWild PWild)) (EVar "precApp"))
(DFunDef false "exprPrec" ((PCon "EInfix" PWild PWild PWild)) (EVar "precInfix"))
(DFunDef false "exprPrec" ((PCon "EBinOp" (PVar "op") PWild PWild PWild)) (EApp (EVar "binopPrec") (EVar "op")))
(DFunDef false "exprPrec" ((PCon "ESection" PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EAsPat" PWild PWild)) (EVar "precApp"))
(DFunDef false "exprPrec" ((PCon "ELam" PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "ELet" PWild PWild PWild PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "ELetGroup" PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EIf" PWild PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EMatch" PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EBlock" PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EDo" PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EAnnot" PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EHeadAnnot" PWild PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EGuards" PWild)) (EVar "precTop"))
(DFunDef false "exprPrec" ((PCon "EVarAt" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EMethodAt" PWild PWild PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "EDictAt" PWild PWild)) (EVar "precAtom"))
(DFunDef false "exprPrec" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "exprPrec") (EVar "e")))
(DTypeSig false "stripLocE" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "stripLocE" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "stripLocE") (EVar "e")))
(DFunDef false "stripLocE" ((PVar "e")) (EVar "e"))
(DTypeSig false "isKeywordBlock" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isKeywordBlock" ((PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "EMatch" PWild PWild) () (EVar "True")) (arm (PCon "EDo" PWild PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "isBareBlock" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isBareBlock" ((PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "EBlock" PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "isGuardsBody" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isGuardsBody" ((PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "EGuards" PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "isUnitLit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isUnitLit" ((PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "ELit" (PCon "LUnit")) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "isDelimitedBody" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isDelimitedBody" ((PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "EListLit" (PCons PWild PWild)) () (EVar "True")) (arm (PCon "EArrayLit" (PCons PWild PWild)) () (EVar "True")) (arm (PCon "ETuple" (PCons PWild PWild)) () (EVar "True")) (arm (PCon "ERecordCreate" PWild (PCons PWild PWild)) () (EVar "True")) (arm (PCon "ERecordUpdate" PWild PWild PWild) () (EVar "True")) (arm (PCon "EVariantUpdate" PWild PWild PWild) () (EVar "True")) (arm (PCon "EMapLit" PWild (PCons PWild PWild)) () (EVar "True")) (arm (PCon "ESetLit" PWild (PCons PWild PWild)) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "isHuggableArg" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isHuggableArg" ((PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "ELam" PWild PWild) () (EVar "True")) (arm (PCon "EBlock" PWild) () (EVar "True")) (arm (PCon "EDo" PWild PWild) () (EVar "True")) (arm (PCon "EMatch" PWild PWild) () (EVar "True")) (arm (PCon "EIf" PWild PWild PWild) () (EVar "True")) (arm (PCon "EListLit" (PCons PWild PWild)) () (EVar "True")) (arm (PCon "EArrayLit" (PCons PWild PWild)) () (EVar "True")) (arm (PCon "ETuple" (PCons PWild PWild)) () (EVar "True")) (arm (PCon "ERecordCreate" PWild (PCons PWild PWild)) () (EVar "True")) (arm (PCon "ERecordUpdate" PWild PWild PWild) () (EVar "True")) (arm (PCon "EVariantUpdate" PWild PWild PWild) () (EVar "True")) (arm (PCon "EMapLit" PWild (PCons PWild PWild)) () (EVar "True")) (arm (PCon "ESetLit" PWild (PCons PWild PWild)) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "appHugsLast" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "appHugsLast" ((PVar "e")) (EMatch (EApp (EApp (EVar "collectApp") (EListLit)) (EVar "e")) (arm (PTuple PWild (PVar "args")) () (EMatch (EApp (EVar "last") (EVar "args")) (arm (PCon "Some" (PVar "lastArg")) () (EBinOp "&&" (EApp (EVar "isHuggableArg") (EVar "lastArg")) (EApp (EApp (EVar "allList") (EVar "isSimpleArg")) (EApp (EVar "initOf") (EVar "args"))))) (arm (PCon "None") () (EVar "False"))))))
(DTypeSig false "initOf" (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyApp (TyCon "List") (TyVar "a"))))
(DFunDef false "initOf" ((PList)) (EListLit))
(DFunDef false "initOf" ((PList PWild)) (EListLit))
(DFunDef false "initOf" ((PCons (PVar "x") (PVar "xs"))) (EBinOp "::" (EVar "x") (EApp (EVar "initOf") (EVar "xs"))))
(DTypeSig false "isSimpleArg" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isSimpleArg" ((PVar "e")) (EApp (EVar "not") (EApp (EVar "isHuggableArg") (EVar "e"))))
(DTypeSig false "isFillAtom" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isFillAtom" ((PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "ENumLit" PWild PWild PWild PWild) () (EVar "True")) (arm (PCon "ELit" PWild) () (EVar "True")) (arm (PCon "EVar" PWild) () (EVar "True")) (arm (PCon "EVarId" PWild PWild) () (EVar "True")) (arm (PCon "EMethodRef" PWild) () (EVar "True")) (arm (PCon "EDictApp" PWild) () (EVar "True")) (arm (PCon "EUnOp" (PVar "op") (PVar "inner") PWild) () (EBinOp "&&" (EBinOp "==" (EVar "op") (ELit (LString "-"))) (EApp (EVar "isFillAtom") (EVar "inner")))) (arm PWild () (EVar "False"))))
(DTypeSig false "isFillable" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Bool")))
(DFunDef false "isFillable" ((PVar "es")) (EBinOp "&&" (EBinOp ">=" (EApp (EVar "listLen") (EVar "es")) (ELit (LInt 2))) (EApp (EApp (EVar "allList") (EVar "isFillAtom")) (EVar "es"))))
(DTypeSig false "collectionDoc" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Doc"))))))
(DFunDef false "collectionDoc" ((PVar "open_") (PVar "close_") (PVar "loc") (PVar "es")) (EBlock (DoLet false false (PVar "forced") (EApp (EApp (EVar "literalForced") (EVar "loc")) (EVar "es"))) (DoLet false false (PVar "ps") (EApp (EApp (EMethodRef "map") (EVar "exprPiece")) (EVar "es"))) (DoExpr (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "not") (EVar "forced")) (EApp (EVar "isFillable") (EVar "es"))) (EApp (EVar "not") (EApp (EVar "anyCommented") (EVar "ps")))) (EApp (EApp (EApp (EVar "filledDocs") (EVar "open_")) (EVar "close_")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e")))) (EVar "es"))) (EApp (EApp (EApp (EApp (EVar "delimitedPieces") (EVar "open_")) (EVar "close_")) (EVar "forced")) (EVar "ps"))))))
(DTypeSig false "printExpr" (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "printExpr" ((PVar "minPrec") (PVar "e")) (EBlock (DoLet false false (PVar "ep") (EApp (EVar "exprPrec") (EVar "e"))) (DoLet false false (PVar "d") (EApp (EApp (EVar "printExprRaw") (EVar "None")) (EVar "e"))) (DoExpr (EIf (EBinOp "<" (EVar "ep") (EVar "minPrec")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "text") (ELit (LString ")"))))) (EVar "d")))))
(DTypeSig false "doKeyword" (TyFun (TyCon "Bool") (TyCon "String")))
(DFunDef false "doKeyword" ((PCon "True")) (ELit (LString "defer")))
(DFunDef false "doKeyword" ((PCon "False")) (ELit (LString "do")))
(DTypeSig false "printExprRaw" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "printExprRaw" (PWild (PCon "ELit" (PVar "l"))) (EApp (EVar "printLit") (EVar "l")))
(DFunDef false "printExprRaw" (PWild (PCon "ENumLit" (PVar "n") PWild PWild (PVar "lx"))) (EApp (EVar "text") (EIf (EBinOp "==" (EVar "lx") (ELit (LString ""))) (EApp (EVar "intToString") (EVar "n")) (EVar "lx"))))
(DFunDef false "printExprRaw" (PWild (PCon "EVar" (PVar "n"))) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" (PWild (PCon "EVarId" (PVar "n") PWild)) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" (PWild (PCon "EMethodRef" (PVar "n"))) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" (PWild (PCon "EDictApp" (PVar "n"))) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" (PWild (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EVar "printAppSpine") (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x"))))
(DFunDef false "printExprRaw" (PWild (PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EMethodRef "map") (EVar "printPatAtom")) (EVar "pats")))) (EApp (EApp (EVar "sepBody") (ELit (LString " =>"))) (EVar "body"))))
(DFunDef false "printExprRaw" (PWild (PCon "ELet" PWild (PVar "isf") (PVar "pat") (PVar "rhs") (PVar "e2"))) (EApp (EApp (EApp (EApp (EVar "printELet") (EVar "isf")) (EVar "pat")) (EVar "rhs")) (EVar "e2")))
(DFunDef false "printExprRaw" (PWild (PCon "ELetGroup" (PVar "bindings") (PVar "body"))) (EApp (EApp (EVar "letRecInDoc") (EVar "bindings")) (EVar "body")))
(DFunDef false "printExprRaw" (PWild (PCon "EIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "printIf") (EVar "c")) (EVar "t")) (EVar "e")))
(DFunDef false "printExprRaw" (PWild (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "rf"))) (EApp (EVar "printBinOp") (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "rf"))))
(DFunDef false "printExprRaw" (PWild (PCon "EUnOp" (PVar "op") (PVar "e") PWild)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EApp (EVar "printExpr") (EVar "precUnary")) (EVar "e"))))
(DFunDef false "printExprRaw" (PWild (PCon "EFieldAccess" (PVar "e") (PVar "f") PWild)) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precPostfix")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ".")))) (EApp (EVar "text") (EVar "f")))))
(DFunDef false "printExprRaw" ((PVar "loc") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EApp (EVar "bracedPieces") (ELit (LString "{"))) (EApp (EApp (EVar "fieldForced") (EVar "loc")) (EVar "fs"))) (EApp (EApp (EMethodRef "map") (EVar "fieldAssignPiece")) (EVar "fs"))))))
(DFunDef false "printExprRaw" ((PVar "loc") (PCon "ERecordUpdate" (PVar "e") (PVar "fs") PWild)) (EBlock (DoLet false false (PVar "baseD") (EApp (EVar "noClaimDoc") (ELam (PWild) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))))) (DoLet false false (PVar "headD") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "{ ")))) (EApp (EApp (EVar "Cat") (EVar "baseD")) (EApp (EVar "text") (ELit (LString " |")))))) (DoExpr (EApp (EApp (EApp (EVar "bracedPieces") (EApp (EVar "renderFlat") (EVar "headD"))) (EApp (EApp (EVar "fieldForced") (EVar "loc")) (EVar "fs"))) (EApp (EApp (EMethodRef "map") (EVar "fieldAssignPiece")) (EVar "fs"))))))
(DFunDef false "printExprRaw" ((PVar "loc") (PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EBlock (DoLet false false (PVar "baseD") (EApp (EVar "noClaimDoc") (ELam (PWild) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))))) (DoLet false false (PVar "headD") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "c"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " { ")))) (EApp (EApp (EVar "Cat") (EVar "baseD")) (EApp (EVar "text") (ELit (LString " |"))))))) (DoExpr (EApp (EApp (EApp (EVar "bracedPieces") (EApp (EVar "renderFlat") (EVar "headD"))) (EApp (EApp (EVar "fieldForced") (EVar "loc")) (EVar "fs"))) (EApp (EApp (EMethodRef "map") (EVar "fieldAssignPiece")) (EVar "fs"))))))
(DFunDef false "printExprRaw" ((PVar "loc") (PCon "EArrayLit" (PVar "es"))) (EApp (EApp (EApp (EApp (EVar "collectionDoc") (ELit (LString "[|"))) (ELit (LString "|]"))) (EVar "loc")) (EVar "es")))
(DFunDef false "printExprRaw" ((PVar "loc") (PCon "EListLit" (PVar "es"))) (EApp (EApp (EApp (EApp (EVar "collectionDoc") (ELit (LString "["))) (ELit (LString "]"))) (EVar "loc")) (EVar "es")))
(DFunDef false "printExprRaw" ((PVar "loc") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EApp (EVar "bracedPieces") (ELit (LString "{"))) (EApp (EApp (EVar "kvForced") (EVar "loc")) (EVar "kvs"))) (EApp (EApp (EMethodRef "map") (EVar "mapKvPiece")) (EVar "kvs"))))))
(DFunDef false "printExprRaw" ((PVar "loc") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EApp (EVar "bracedPieces") (ELit (LString "{"))) (EApp (EApp (EVar "literalForced") (EVar "loc")) (EVar "es"))) (EApp (EApp (EMethodRef "map") (EVar "exprPiece")) (EVar "es"))))))
(DFunDef false "printExprRaw" ((PVar "loc") (PCon "ETuple" (PVar "es"))) (EApp (EApp (EApp (EApp (EVar "delimitedPieces") (ELit (LString "("))) (ELit (LString ")"))) (EApp (EApp (EVar "literalForced") (EVar "loc")) (EVar "es"))) (EApp (EApp (EMethodRef "map") (EVar "exprPiece")) (EVar "es"))))
(DFunDef false "printExprRaw" (PWild (PCon "EIndex" (PVar "e") (PVar "i") PWild)) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precPostfix")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "[")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "i"))) (EApp (EVar "text") (ELit (LString "]")))))))
(DFunDef false "printExprRaw" (PWild (PCon "EMatch" (PVar "sc") (PVar "arms"))) (EApp (EApp (EVar "printMatch") (EVar "sc")) (EVar "arms")))
(DFunDef false "printExprRaw" (PWild (PCon "EGuards" (PVar "arms"))) (EApp (EVar "printGuardArms") (EVar "arms")))
(DFunDef false "printExprRaw" (PWild (PCon "ESection" (PCon "SecBare" (PVar "op")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "printExprRaw" (PWild (PCon "ESection" (PCon "SecRight" (PVar "op") (PVar "e")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))) (EApp (EVar "text") (ELit (LString ")"))))))))
(DFunDef false "printExprRaw" (PWild (PCon "ESection" (PCon "SecLeft" (PVar "e") (PVar "op")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EVar "text") (ELit (LString " _)"))))))))
(DFunDef false "printExprRaw" (PWild (PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "x"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "@")))) (EApp (EApp (EVar "printExpr") (EVar "precAtom")) (EVar "e")))))
(DFunDef false "printExprRaw" (PWild (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "printBlock") (EVar "stmts")))
(DFunDef false "printExprRaw" (PWild (PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EVar "doKeyword") (EVar "d")))) (EApp (EVar "printBlock") (EVar "stmts"))))
(DFunDef false "printExprRaw" (PWild (PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " : ")))) (EApp (EVar "printType") (EVar "t")))))
(DFunDef false "printExprRaw" (PWild (PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e")))
(DFunDef false "printExprRaw" (PWild (PCon "EInfix" (PVar "op") (PVar "l") (PVar "r"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EBinOp "+" (EVar "precInfix") (ELit (LInt 1)))) (EVar "l"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " `")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "op"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "` ")))) (EApp (EApp (EVar "printExpr") (EBinOp "+" (EVar "precInfix") (ELit (LInt 1)))) (EVar "r")))))))
(DFunDef false "printExprRaw" (PWild (PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "\"")))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (EVar "interpPartDoc")) (EVar "parts")))) (EApp (EVar "text") (ELit (LString "\""))))))
(DFunDef false "printExprRaw" (PWild (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "[")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "lo"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EIf (EVar "incl") (ELit (LString "..=")) (ELit (LString ".."))))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "hi"))) (EApp (EVar "text") (ELit (LString "]"))))))))
(DFunDef false "printExprRaw" (PWild (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "[|")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "lo"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EIf (EVar "incl") (ELit (LString "..=")) (ELit (LString ".."))))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "hi"))) (EApp (EVar "text") (ELit (LString "|]"))))))))
(DFunDef false "printExprRaw" (PWild (PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "incl") PWild)) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precPostfix")) (EVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ".[")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "lo"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EIf (EVar "incl") (ELit (LString "..=")) (ELit (LString ".."))))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "hi"))) (EApp (EVar "text") (ELit (LString "]")))))))))
(DFunDef false "printExprRaw" (PWild (PCon "EVarAt" (PVar "n") PWild)) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" (PWild (PCon "EMethodAt" (PVar "n") PWild PWild PWild)) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" (PWild (PCon "EDictAt" (PVar "n") PWild)) (EApp (EVar "text") (EVar "n")))
(DFunDef false "printExprRaw" (PWild (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "printExprRaw") (EApp (EVar "Some") (EVar "l"))) (EVar "e")))
(DTypeSig false "fieldAssignPiece" (TyFun (TyCon "FieldAssign") (TyCon "Piece")))
(DFunDef false "fieldAssignPiece" ((PCon "FieldAssign" (PVar "k") (PVar "v"))) (EMatch (EApp (EVar "exprSpan") (EVar "v")) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EMatch (EApp (EApp (EApp (EVar "unitStartAt") (ELit (LInt 4))) (EVar "s")) (EVar "sc")) (arm (PTuple (PVar "s2") (PVar "sc2")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s2")) (EVar "sc2")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "k"))) (EApp (EApp (EVar "sepBody") (ELit (LString " ="))) (EVar "v"))))))))))
(DTypeSig false "mapKvPiece" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyCon "Piece")))
(DFunDef false "mapKvPiece" ((PTuple (PVar "k") (PVar "v"))) (EMatch (EApp (EVar "kvSpan") (ETuple (EVar "k") (EVar "v"))) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s")) (EVar "sc")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EApp (EVar "mapKvDoc") (EVar "k")) (EVar "v")))))))
(DTypeSig false "mapKvDoc" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "mapKvDoc" ((PVar "k") (PVar "v")) (EBlock (DoLet false false (PVar "kD") (EApp (EVar "noClaimDoc") (ELam (PWild) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "k"))))) (DoExpr (EApp (EApp (EVar "Cat") (EVar "kD")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " => ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "v")))))))
(DTypeSig false "interpPartDoc" (TyFun (TyCon "InterpPart") (TyCon "Doc")))
(DFunDef false "interpPartDoc" ((PCon "InterpStr" (PVar "s"))) (EApp (EVar "text") (EApp (EVar "stringEscaped") (EVar "s"))))
(DFunDef false "interpPartDoc" ((PCon "InterpExpr" (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "\\{")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EVar "renderFlat") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))))) (EApp (EVar "text") (ELit (LString "}"))))))
(DTypeSig false "stringEscaped" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "stringEscaped" ((PVar "s")) (EApp (EVar "stringConcat") (EApp (EApp (EVar "escEChars") (EApp (EVar "stringToChars") (EVar "s"))) (ELit (LInt 0)))))
(DTypeSig false "escEChars" (TyFun (TyApp (TyCon "Array") (TyCon "Char")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "escEChars" ((PVar "cs") (PVar "i")) (EIf (EBinOp ">=" (EVar "i") (EApp (EVar "arrayLength") (EVar "cs"))) (EListLit) (EIf (EVar "otherwise") (EBinOp "::" (EApp (EVar "escSOne") (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "cs"))) (EApp (EApp (EVar "escEChars") (EVar "cs")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "sepBody" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "sepBody" ((PVar "sep") (PVar "body")) (EIf (EApp (EVar "isGuardsBody") (EVar "body")) (EApp (EVar "printExprBody") (EVar "body")) (EIf (EApp (EVar "isBareBlock") (EVar "body")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "sep"))) (EApp (EVar "printExprBody") (EVar "body"))) (EIf (EApp (EVar "isKeywordBlock") (EVar "body")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EBinOp "++" (EVar "sep") (ELit (LString " "))))) (EApp (EVar "printExprBody") (EVar "body"))) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "s") (EApp (EVar "spanStart") (EApp (EVar "exprSpan") (EVar "body")))) (DoLet false false (PVar "leading") (EIf (EBinOp ">" (EVar "s") (ELit (LInt 0))) (EApp (EVar "popBefore") (EVar "s")) (EListLit))) (DoExpr (EIf (EApp (EVar "isNonEmptyL") (EVar "leading")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "sep"))) (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "leadingCommentsDoc") (EVar "leading")) (EVar "s"))) (EApp (EApp (EVar "soloDoc") (EVar "body")) (ELam (PWild) (EApp (EVar "printExprBody") (EVar "body")))))))) (EIf (EBinOp "||" (EApp (EVar "isDelimitedBody") (EVar "body")) (EApp (EVar "appHugsLast") (EVar "body"))) (EApp (EApp (EVar "Hang") (EVar "sep")) (EApp (EApp (EVar "soloDoc") (EVar "body")) (ELam (PWild) (EApp (EVar "printExprBody") (EVar "body"))))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "sep"))) (EApp (EVar "group") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "soloDoc") (EVar "body")) (ELam (PWild) (EApp (EVar "printExprBody") (EVar "body")))))))))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "printExprBody" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "printExprBody" ((PVar "e")) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e")))
(DTypeSig false "stmtPiece" (TyFun (TyCon "DoStmt") (TyCon "Piece")))
(DFunDef false "stmtPiece" ((PVar "st")) (EMatch (EApp (EVar "stmtSpan") (EVar "st")) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EMatch (EApp (EApp (EApp (EVar "unitStartAt") (ELit (LInt 1))) (EVar "s")) (EVar "sc")) (arm (PTuple (PVar "s2") (PVar "sc2")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s2")) (EVar "sc2")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EVar "printDoStmt") (EVar "st")))))))))
(DTypeSig false "printBlock" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "Doc")))
(DFunDef false "printBlock" ((PVar "stmts")) (EApp (EVar "indentBlock") (EApp (EVar "joinHard") (EApp (EVar "pieceDocsHard") (EApp (EApp (EMethodRef "map") (EVar "stmtPiece")) (EVar "stmts"))))))
(DTypeSig false "printDoStmt" (TyFun (TyCon "DoStmt") (TyCon "Doc")))
(DFunDef false "printDoStmt" ((PCon "DoBind" (PVar "pat") (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPat") (EVar "pat"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " <- ")))) (EApp (EVar "printExprBody") (EVar "e")))))
(DFunDef false "printDoStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "printExprBody") (EVar "e")))
(DFunDef false "printDoStmt" ((PCon "DoLet" (PVar "isMut") PWild (PVar "pat") (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "let ")))) (EApp (EApp (EVar "Cat") (EIf (EVar "isMut") (EApp (EVar "text") (ELit (LString "mut "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPat") (EVar "pat"))) (EApp (EApp (EVar "sepBody") (ELit (LString " ="))) (EVar "e"))))))
(DFunDef false "printDoStmt" ((PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "x"))) (EApp (EApp (EVar "sepBody") (ELit (LString " ="))) (EVar "e"))))
(DFunDef false "printDoStmt" ((PCon "DoFieldAssign" (PVar "x") (PVar "fields") (PVar "e"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "x"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ".")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "fields")))) (EApp (EApp (EVar "sepBody") (ELit (LString " ="))) (EVar "e"))))))
(DTypeSig false "printELet" (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Doc"))))))
(DFunDef false "printELet" ((PCon "True") (PCon "PVar" (PVar "f") PWild) (PVar "rhs") (PVar "e2")) (EMatch (EApp (EApp (EVar "unwrapLams") (EListLit)) (EVar "rhs")) (arm (PTuple (PVar "args") (PVar "body")) () (EBlock (DoLet false false (PVar "headD") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "let ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "f"))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "args")))))) (DoExpr (EApp (EApp (EApp (EVar "letInDoc") (EVar "headD")) (EVar "body")) (EVar "e2")))))))
(DFunDef false "printELet" (PWild (PVar "pat") (PVar "e1") (PVar "e2")) (EApp (EApp (EApp (EVar "letInDoc") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "let ")))) (EApp (EVar "printPat") (EVar "pat")))) (EVar "e1")) (EVar "e2")))
(DTypeSig false "letInDoc" (TyFun (TyCon "Doc") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Doc")))))
(DFunDef false "letInDoc" ((PVar "headD") (PVar "rhs") (PVar "e2")) (EBlock (DoLet false false (PVar "rhsD") (EApp (EVar "noClaimDoc") (ELam (PWild) (EApp (EVar "printExprBody") (EVar "rhs"))))) (DoLet false false (PVar "bodyD") (EApp (EApp (EVar "soloDoc") (EVar "e2")) (ELam (PWild) (EApp (EVar "printExprBody") (EVar "e2"))))) (DoExpr (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EVar "headD")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "Cat") (EVar "rhsD")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " in")))) (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EVar "bodyD")))))))))))
(DTypeSig false "unwrapLams" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "unwrapLams" ((PVar "acc") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EVar "unwrapLams") (EVar "acc")) (EVar "e")))
(DFunDef false "unwrapLams" ((PVar "acc") (PCon "ELam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "unwrapLams") (EBinOp "++" (EVar "acc") (EVar "pats"))) (EVar "body")))
(DFunDef false "unwrapLams" ((PVar "acc") (PVar "body")) (ETuple (EVar "acc") (EVar "body")))
(DTypeSig false "letRecInDoc" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "letRecInDoc" ((PList) (PVar "body")) (EApp (EVar "printExprBody") (EVar "body")))
(DFunDef false "letRecInDoc" ((PCons (PCon "LetBind" (PVar "name") (PVar "clauses")) (PVar "rest")) (PVar "body")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "letRecInDoc") (EVar "rest")) (EVar "body"))) (DoExpr (EMatch (EVar "clauses") (arm (PList (PCon "FunClause" (PVar "pats") (PVar "rhs"))) () (EBlock (DoLet false false (PVar "headD") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "let rec ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "pats")))))) (DoLet false false (PVar "rhsD") (EApp (EApp (EVar "withBound") (EApp (EVar "spanStart") (EApp (EVar "exprSpan") (EVar "body")))) (ELam (PWild) (EApp (EVar "printExprBody") (EVar "rhs"))))) (DoExpr (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EVar "headD")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "Cat") (EVar "rhsD")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " in")))) (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EVar "inner"))))))))))) (arm PWild () (EVar "inner"))))))
(DTypeSig false "printIf" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Doc")))))
(DFunDef false "printIf" ((PVar "c") (PVar "t") (PVar "els")) (EApp (EVar "group") (EApp (EApp (EApp (EVar "ifLadder") (EVar "c")) (EVar "t")) (EVar "els"))))
(DTypeSig false "ifLadder" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Doc")))))
(DFunDef false "ifLadder" ((PVar "c") (PVar "t") (PVar "els")) (EBlock (DoLet false false (PVar "condD") (EApp (EVar "noClaimDoc") (ELam (PWild) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "c"))))) (DoLet false false (PVar "thenD") (EApp (EApp (EVar "withBound") (EApp (EVar "spanStart") (EApp (EVar "exprSpan") (EVar "els")))) (ELam (PWild) (EApp (EApp (EVar "ifBranch") (ELit (LString "then"))) (EVar "t"))))) (DoLet false false (PVar "elseD") (EApp (EVar "ifElsePart") (EVar "els"))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "if ")))) (EApp (EApp (EVar "Cat") (EVar "condD")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "Cat") (EVar "thenD")) (EVar "elseD"))))))))
(DTypeSig false "ifElsePart" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "ifElsePart" ((PVar "els")) (EIf (EApp (EVar "isUnitLit") (EVar "els")) (EVar "Nil") (EIf (EVar "otherwise") (EMatch (EApp (EVar "stripLocE") (EVar "els")) (arm (PCon "EIf" (PVar "c2") (PVar "t2") (PVar "e2")) () (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "else ")))) (EApp (EApp (EApp (EVar "ifLadder") (EVar "c2")) (EVar "t2")) (EVar "e2"))))) (arm PWild () (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "ifBranch") (ELit (LString "else"))) (EVar "els"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ifBranch" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "ifBranch" ((PVar "kw") (PVar "b")) (EIf (EApp (EVar "isBareBlock") (EVar "b")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "kw"))) (EApp (EVar "printExprBody") (EVar "b"))) (EIf (EApp (EVar "isKeywordBlock") (EVar "b")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "kw"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printExprBody") (EVar "b")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "kw"))) (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "soloDoc") (EVar "b")) (ELam (PWild) (EApp (EVar "printExprBody") (EVar "b"))))))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "printMatch" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Doc"))))
(DFunDef false "printMatch" ((PVar "sc") (PVar "arms")) (EBlock (DoLet false false (PVar "scD") (EApp (EVar "noClaimDoc") (ELam (PWild) (EApp (EVar "matchScrutineeDoc") (EVar "sc"))))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "match ")))) (EApp (EApp (EVar "Cat") (EVar "scD")) (EApp (EVar "printMatchArms") (EVar "arms")))))))
(DTypeSig false "matchScrutineeDoc" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "matchScrutineeDoc" ((PVar "sc")) (EBlock (DoLet false false (PVar "d") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "sc"))) (DoExpr (EIf (EBinOp ">=" (EApp (EVar "exprPrec") (EVar "sc")) (EVar "precAtom")) (EVar "d") (EMatch (EApp (EVar "exprSpan") (EVar "sc")) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EIf (EBinOp "&&" (EBinOp ">" (EVar "s") (ELit (LInt 0))) (EApp (EApp (EApp (EApp (EVar "pendingInside") (EVar "s")) (EVar "sc")) (EVar "en")) (EVar "ec"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "text") (ELit (LString ")"))))) (EApp (EApp (EVar "Alt") (EApp (EVar "text") (EApp (EVar "renderFlat") (EVar "d")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "text") (ELit (LString ")")))))))))))))
(DTypeSig false "armPiece" (TyFun (TyCon "Arm") (TyCon "Piece")))
(DFunDef false "armPiece" ((PVar "arm")) (EMatch (EApp (EVar "armSpan") (EVar "arm")) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EMatch (EApp (EApp (EApp (EVar "unitStartAt") (ELit (LInt 0))) (EVar "s")) (EVar "sc")) (arm (PTuple (PVar "s2") (PVar "sc2")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s2")) (EVar "sc2")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EVar "matchArmDoc") (EVar "arm")))))))))
(DTypeSig false "unitStartsRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int")))))
(DFunDef false "unitStartsRef" () (EApp (EVar "Ref") (EApp (EVar "arrayFromList") (EListLit))))
(DTypeSig true "setUnitStarts" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int"))) (TyCon "Unit")))
(DFunDef false "setUnitStarts" ((PVar "ps")) (EApp (EApp (EVar "setRef") (EVar "unitStartsRef")) (EApp (EVar "arrayFromList") (EApp (EApp (EVar "sortBy") (EVar "cmpUnit")) (EVar "ps")))))
(DTypeSig false "cmpUnit" (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyFun (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int")) (TyCon "Ordering"))))
(DFunDef false "cmpUnit" ((PTuple (PVar "k1") (PVar "l1") (PVar "c1")) (PTuple (PVar "k2") (PVar "l2") (PVar "c2"))) (EIf (EBinOp "/=" (EVar "k1") (EVar "k2")) (EApp (EApp (EMethodRef "compare") (EVar "k1")) (EVar "k2")) (EApp (EApp (EVar "cmpPos") (ETuple (EVar "l1") (EVar "c1"))) (ETuple (EVar "l2") (EVar "c2")))))
(DTypeSig false "unitUpperBound" (TyFun (TyApp (TyCon "Array") (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int"))) (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyCon "Int"))))))))
(DFunDef false "unitUpperBound" ((PVar "arr") (PVar "kind") (PVar "line") (PVar "col") (PVar "lo") (PVar "hi")) (EIf (EBinOp ">=" (EVar "lo") (EVar "hi")) (EVar "lo") (EBlock (DoLet false false (PVar "mid") (EBinOp "/" (EBinOp "+" (EVar "lo") (EVar "hi")) (ELit (LInt 2)))) (DoExpr (EMatch (EApp (EApp (EMethodRef "index") (EVar "arr")) (EVar "mid")) (arm (PTuple (PVar "k") (PVar "l") (PVar "c")) () (EBlock (DoLet false false (PVar "le") (EBinOp "||" (EBinOp "<" (EVar "k") (EVar "kind")) (EBinOp "&&" (EBinOp "==" (EVar "k") (EVar "kind")) (EBinOp "||" (EBinOp "<" (EVar "l") (EVar "line")) (EBinOp "&&" (EBinOp "==" (EVar "l") (EVar "line")) (EBinOp "<=" (EVar "c") (EVar "col"))))))) (DoExpr (EIf (EVar "le") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "unitUpperBound") (EVar "arr")) (EVar "kind")) (EVar "line")) (EVar "col")) (EBinOp "+" (EVar "mid") (ELit (LInt 1)))) (EVar "hi")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "unitUpperBound") (EVar "arr")) (EVar "kind")) (EVar "line")) (EVar "col")) (EVar "lo")) (EVar "mid")))))))))))
(DTypeSig false "unitStartAt" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyTuple (TyCon "Int") (TyCon "Int"))))))
(DFunDef false "unitStartAt" ((PVar "kind") (PVar "line") (PVar "col")) (EIf (EBinOp "==" (EVar "line") (ELit (LInt 0))) (ETuple (ELit (LInt 0)) (ELit (LInt 0))) (EBlock (DoLet false false (PVar "arr") (EUnOp "!" (EVar "unitStartsRef"))) (DoLet false false (PVar "i") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "unitUpperBound") (EVar "arr")) (EVar "kind")) (EVar "line")) (EVar "col")) (ELit (LInt 0))) (EApp (EVar "arrayLength") (EVar "arr")))) (DoExpr (EIf (EBinOp "==" (EVar "i") (ELit (LInt 0))) (ETuple (EVar "line") (EVar "col")) (EMatch (EApp (EApp (EMethodRef "index") (EVar "arr")) (EBinOp "-" (EVar "i") (ELit (LInt 1)))) (arm (PTuple (PVar "k") (PVar "l") (PVar "c")) () (EIf (EBinOp "==" (EVar "k") (EVar "kind")) (ETuple (EVar "l") (EVar "c")) (ETuple (EVar "line") (EVar "col"))))))))))
(DTypeSig false "printMatchArms" (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Doc")))
(DFunDef false "printMatchArms" ((PVar "arms")) (EApp (EVar "indentBlock") (EApp (EVar "joinHard") (EApp (EVar "pieceDocsHard") (EApp (EApp (EMethodRef "map") (EVar "armPiece")) (EVar "arms"))))))
(DTypeSig false "matchArmDoc" (TyFun (TyCon "Arm") (TyCon "Doc")))
(DFunDef false "matchArmDoc" ((PCon "Arm" (PVar "pat") (PVar "guards") (PVar "body"))) (EBlock (DoLet false false (PVar "guardsD") (EApp (EVar "noClaimDoc") (ELam (PWild) (EApp (EVar "matchGuardsDoc") (EVar "guards"))))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "printPatArm") (EVar "pat"))) (EApp (EApp (EVar "Cat") (EVar "guardsD")) (EApp (EApp (EVar "sepBody") (ELit (LString " =>"))) (EVar "body")))))))
(DTypeSig false "matchGuardsDoc" (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyCon "Doc")))
(DFunDef false "matchGuardsDoc" ((PList)) (EVar "Nil"))
(DFunDef false "matchGuardsDoc" ((PVar "guards")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " if ")))) (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EVar "guardDoc")) (EVar "guards")))))
(DTypeSig false "guardDoc" (TyFun (TyCon "Guard") (TyCon "Doc")))
(DFunDef false "guardDoc" ((PCon "GBool" (PVar "g"))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "g")))
(DFunDef false "guardDoc" ((PCon "GBind" (PVar "gp") (PVar "g"))) (EApp (EApp (EVar "Cat") (EApp (EVar "printPat") (EVar "gp"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " <- ")))) (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "g")))))
(DTypeSig false "guardArmPiece" (TyFun (TyCon "GuardArm") (TyCon "Piece")))
(DFunDef false "guardArmPiece" ((PVar "arm")) (EMatch (EApp (EVar "guardArmSpan") (EVar "arm")) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s")) (EVar "sc")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EVar "guardArmDoc") (EVar "arm")))))))
(DTypeSig false "printGuardArms" (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyCon "Doc")))
(DFunDef false "printGuardArms" ((PVar "arms")) (EApp (EVar "indentBlock") (EApp (EVar "joinHard") (EApp (EVar "pieceDocsHard") (EApp (EApp (EMethodRef "map") (EVar "guardArmPiece")) (EVar "arms"))))))
(DTypeSig false "guardArmDoc" (TyFun (TyCon "GuardArm") (TyCon "Doc")))
(DFunDef false "guardArmDoc" ((PCon "GuardArm" (PVar "guards") (PVar "body"))) (EBlock (DoLet false false (PVar "hd") (EApp (EVar "noClaimDoc") (ELam (PWild) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "| ")))) (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EVar "guardDoc")) (EVar "guards"))))))) (DoExpr (EApp (EApp (EVar "Cat") (EVar "hd")) (EApp (EApp (EVar "sepBody") (ELit (LString " ="))) (EVar "body"))))))
(DTypeSig false "printBinOp" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "printBinOp" ((PVar "e")) (EBlock (DoLet false false (PVar "op") (EApp (EVar "topOp") (EVar "e"))) (DoLet false false (PVar "prec") (EApp (EVar "binopPrec") (EVar "op"))) (DoExpr (EIf (EBinOp "==" (EVar "op") (ELit (LString ":="))) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "EBinOp" PWild (PVar "l") (PVar "r") PWild) () (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "printExpr") (EBinOp "+" (EVar "precAssign") (ELit (LInt 1)))) (EVar "l"))) (EApp (EApp (EVar "sepBody") (ELit (LString " :="))) (EVar "r")))) (arm PWild () (EVar "Nil"))) (EBlock (DoLet false false (PVar "ra") (EApp (EVar "isRightAssoc") (EVar "op"))) (DoLet false false (PVar "headPrec") (EIf (EVar "ra") (EBinOp "+" (EVar "prec") (ELit (LInt 1))) (EVar "prec"))) (DoLet false false (PVar "rightPrec") (EBinOp "+" (EVar "prec") (ELit (LInt 1)))) (DoExpr (EMatch (EApp (EApp (EApp (EVar "collectChain") (EVar "prec")) (EListLit)) (EVar "e")) (arm (PTuple (PVar "head") (PVar "rights")) () (EBlock (DoLet false false (PVar "headPiece") (EMatch (EApp (EVar "exprSpan") (EVar "head")) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s")) (EVar "sc")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EApp (EVar "printOperand") (EVar "headPrec")) (EVar "head"))))))) (DoLet false false (PVar "ps") (EBinOp "::" (EVar "headPiece") (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (EApp (EApp (EVar "rightPiece") (EVar "rightPrec")) (EVar "r")))) (EVar "rights")))) (DoLet false false (PVar "outs") (EApp (EApp (EVar "pieceDocs") (EVar "noSep")) (EVar "ps"))) (DoExpr (EApp (EVar "group") (EApp (EVar "nest") (EApp (EVar "joinLine") (EVar "outs"))))))))))))))
(DTypeSig false "topOp" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "topOp" ((PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "EBinOp" (PVar "op") PWild PWild PWild) () (EVar "op")) (arm PWild () (ELit (LString "")))))
(DTypeSig false "rightPiece" (TyFun (TyCon "Int") (TyFun (TyTuple (TyCon "String") (TyCon "Expr")) (TyCon "Piece"))))
(DFunDef false "rightPiece" ((PVar "rightPrec") (PTuple (PVar "o") (PVar "r"))) (EMatch (EApp (EVar "exprSpan") (EVar "r")) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s")) (EVar "sc")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "o"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EVar "printOperand") (EVar "rightPrec")) (EVar "r")))))))))
(DTypeSig false "printOperand" (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "printOperand" ((PVar "prec") (PVar "e")) (EApp (EApp (EVar "printExpr") (EVar "prec")) (EVar "e")))
(DTypeSig false "collectChain" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr"))) (TyFun (TyCon "Expr") (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr"))))))))
(DFunDef false "collectChain" ((PVar "prec") (PVar "acc") (PCon "ELoc" (PVar "l") (PVar "e"))) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "EBinOp" (PVar "op") PWild PWild PWild) () (EIf (EBinOp "==" (EApp (EVar "binopPrec") (EVar "op")) (EVar "prec")) (EApp (EApp (EApp (EVar "collectChain") (EVar "prec")) (EVar "acc")) (EVar "e")) (ETuple (EApp (EApp (EVar "ELoc") (EVar "l")) (EVar "e")) (EVar "acc")))) (arm PWild () (ETuple (EApp (EApp (EVar "ELoc") (EVar "l")) (EVar "e")) (EVar "acc")))))
(DFunDef false "collectChain" ((PVar "prec") (PVar "acc") (PCon "EBinOp" (PVar "op") (PVar "l") (PVar "r") (PVar "rf"))) (EIf (EBinOp "/=" (EApp (EVar "binopPrec") (EVar "op")) (EVar "prec")) (ETuple (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EVar "l")) (EVar "r")) (EVar "rf")) (EVar "acc")) (EIf (EApp (EVar "isRightAssoc") (EVar "op")) (ETuple (EVar "l") (EApp (EApp (EApp (EVar "rightSpine") (EVar "prec")) (EVar "op")) (EVar "r"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "collectChain") (EVar "prec")) (EBinOp "::" (ETuple (EVar "op") (EVar "r")) (EVar "acc"))) (EVar "l")) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "collectChain" (PWild (PVar "acc") (PVar "head")) (ETuple (EVar "head") (EVar "acc")))
(DTypeSig false "rightSpine" (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr")))))))
(DFunDef false "rightSpine" ((PVar "prec") (PVar "opBefore") (PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "EBinOp" (PVar "op") (PVar "l2") (PVar "r2") PWild) () (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "binopPrec") (EVar "op")) (EVar "prec")) (EApp (EVar "isRightAssoc") (EVar "op"))) (EBinOp "::" (ETuple (EVar "opBefore") (EVar "l2")) (EApp (EApp (EApp (EVar "rightSpine") (EVar "prec")) (EVar "op")) (EVar "r2"))) (EListLit (ETuple (EVar "opBefore") (EVar "e"))))) (arm PWild () (EListLit (ETuple (EVar "opBefore") (EVar "e"))))))
(DTypeSig false "printAppSpine" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "printAppSpine" ((PVar "e")) (EMatch (EApp (EApp (EVar "collectApp") (EListLit)) (EVar "e")) (arm (PTuple (PVar "head") (PList)) () (EApp (EApp (EVar "printExpr") (EVar "precApp")) (EVar "head"))) (arm (PTuple (PVar "head") (PVar "args")) () (EBlock (DoLet false false (PVar "headD") (EApp (EApp (EVar "printExpr") (EVar "precApp")) (EVar "head"))) (DoLet false false (PVar "ps") (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (EApp (EApp (EVar "argPiece") (EVar "head")) (EVar "a")))) (EVar "args"))) (DoExpr (EIf (EBinOp "&&" (EApp (EVar "appHugsLast") (EVar "e")) (EApp (EVar "not") (EApp (EVar "anyCommented") (EVar "ps")))) (EBlock (DoLet false false (PVar "initOuts") (EApp (EApp (EVar "pieceDocs") (EVar "noSep")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (EApp (EApp (EVar "argPiece") (EVar "head")) (EVar "a")))) (EApp (EVar "initOf") (EVar "args"))))) (DoLet false false (PVar "initDocs") (EApp (EApp (EMethodRef "map") (EVar "pieceOutDoc")) (EVar "initOuts"))) (DoExpr (EMatch (EApp (EVar "last") (EVar "args")) (arm (PCon "Some" (PVar "lastArg")) () (EMatch (EApp (EApp (EVar "lastArgDocs") (EVar "head")) (EVar "lastArg")) (arm (PTuple (PVar "openD") (PVar "closedD")) () (EBlock (DoLet false false (PVar "explode") (EApp (EVar "group") (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EVar "headD")) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EApp (EApp (EVar "Cat") (EVar "Line")) (EVar "d")))) (EBinOp "++" (EVar "initDocs") (EListLit (EVar "closedD"))))))))) (DoLet false false (PVar "hug") (EApp (EApp (EVar "Cat") (EVar "headD")) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EVar "d")))) (EVar "initDocs")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EVar "openD"))))) (DoExpr (EApp (EVar "group") (EApp (EApp (EVar "Alt") (EVar "hug")) (EVar "explode")))))))) (arm (PCon "None") () (EVar "headD"))))) (EBlock (DoLet false false (PVar "outs") (EApp (EApp (EVar "pieceDocs") (EVar "noSep")) (EVar "ps"))) (DoExpr (EApp (EVar "group") (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EVar "headD")) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "o")) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "pieceOutDoc") (EVar "o"))))) (EVar "outs"))))))))))))))
(DTypeSig false "lastArgDocs" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyTuple (TyCon "Doc") (TyCon "Doc")))))
(DFunDef false "lastArgDocs" ((PVar "head") (PVar "arg")) (EMatch (EApp (EVar "stripLocE") (EVar "arg")) (arm (PCon "ELam" (PVar "pats") (PVar "body")) () (EBlock (DoLet false false (PVar "patsD") (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EApp (EMethodRef "map") (EVar "printPatAtom")) (EVar "pats")))) (DoLet false false (PVar "bodyPart") (EApp (EApp (EVar "sepBody") (ELit (LString " =>"))) (EVar "body"))) (DoLet false false (PVar "openD") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EVar "patsD")) (EApp (EApp (EVar "Cat") (EApp (EVar "openBody") (EVar "bodyPart"))) (EApp (EVar "text") (ELit (LString ")"))))))) (DoLet false false (PVar "closedD") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EVar "patsD")) (EApp (EApp (EVar "Cat") (EVar "bodyPart")) (EApp (EVar "text") (ELit (LString ")"))))))) (DoExpr (ETuple (EVar "openD") (EVar "closedD"))))) (arm PWild () (EBlock (DoLet false false (PVar "d") (EApp (EApp (EVar "appArgDoc") (EVar "head")) (EVar "arg"))) (DoExpr (ETuple (EApp (EVar "openDoc") (EVar "d")) (EVar "d")))))))
(DTypeSig false "openBody" (TyFun (TyCon "Doc") (TyCon "Doc")))
(DFunDef false "openBody" ((PCon "Cat" (PVar "s") (PCon "Group" (PVar "g")))) (EApp (EApp (EVar "Cat") (EVar "s")) (EVar "g")))
(DFunDef false "openBody" ((PCon "Hang" (PVar "sep") (PVar "d"))) (EApp (EApp (EVar "hangInline") (EVar "sep")) (EVar "d")))
(DFunDef false "openBody" ((PVar "d")) (EVar "d"))
(DTypeSig false "openDoc" (TyFun (TyCon "Doc") (TyCon "Doc")))
(DFunDef false "openDoc" ((PCon "Group" (PVar "d"))) (EVar "d"))
(DFunDef false "openDoc" ((PCon "Cat" (PCon "Text" (PLit (LString "("))) (PCon "Cat" (PCon "Group" (PVar "d")) (PCon "Text" (PLit (LString ")")))))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "openDoc" ((PCon "Cat" (PCon "Text" (PLit (LString "("))) (PCon "Cat" (PVar "d") (PCon "Text" (PLit (LString ")")))))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "(")))) (EApp (EApp (EVar "Cat") (EVar "d")) (EApp (EVar "text") (ELit (LString ")"))))))
(DFunDef false "openDoc" ((PVar "d")) (EVar "d"))
(DTypeSig false "argPiece" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Piece"))))
(DFunDef false "argPiece" ((PVar "head") (PVar "arg")) (EMatch (EApp (EVar "exprSpan") (EVar "arg")) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s")) (EVar "sc")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EApp (EVar "appArgDoc") (EVar "head")) (EVar "arg")))))))
(DTypeSig false "appArgDoc" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "appArgDoc" ((PVar "head") (PVar "x")) (EIf (EBinOp "&&" (EApp (EVar "isTightNegLitArg") (EVar "x")) (EApp (EVar "not") (EApp (EVar "headIsNumericHead") (EApp (EVar "stripLocE") (EVar "head"))))) (EApp (EApp (EVar "printExprRaw") (EVar "None")) (EApp (EVar "stripLocE") (EVar "x"))) (EIf (EApp (EVar "isTightDerefArg") (EVar "x")) (EApp (EApp (EVar "printExprRaw") (EVar "None")) (EApp (EVar "stripLocE") (EVar "x"))) (EApp (EApp (EVar "printExpr") (EVar "precPostfix")) (EVar "x")))))
(DTypeSig false "isTightDerefArg" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isTightDerefArg" ((PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "EUnOp" (PLit (LString "!")) PWild PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "isTightNegLitArg" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isTightNegLitArg" ((PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "ELit" (PVar "l")) () (EApp (EVar "isNegLit") (EVar "l"))) (arm (PCon "ENumLit" (PVar "n") PWild PWild PWild) () (EBinOp "<" (EVar "n") (ELit (LInt 0)))) (arm PWild () (EVar "False"))))
(DTypeSig false "headIsNumericHead" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "headIsNumericHead" ((PCon "ENumLit" PWild PWild PWild PWild)) (EVar "True"))
(DFunDef false "headIsNumericHead" ((PCon "ELit" (PCon "LInt" PWild))) (EVar "True"))
(DFunDef false "headIsNumericHead" ((PCon "ELit" (PCon "LFloat" PWild))) (EVar "True"))
(DFunDef false "headIsNumericHead" (PWild) (EVar "False"))
(DTypeSig false "collectApp" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "collectApp" ((PVar "acc") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "collectApp") (EBinOp "::" (EVar "x") (EVar "acc"))) (EVar "f")))
(DFunDef false "collectApp" ((PVar "acc") (PCon "ELoc" (PVar "l") (PVar "e"))) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "EApp" (PVar "f") (PVar "x")) () (EApp (EApp (EVar "collectApp") (EVar "acc")) (EApp (EApp (EVar "EApp") (EVar "f")) (EVar "x")))) (arm PWild () (ETuple (EApp (EApp (EVar "ELoc") (EVar "l")) (EVar "e")) (EVar "acc")))))
(DFunDef false "collectApp" ((PVar "acc") (PVar "head")) (ETuple (EVar "head") (EVar "acc")))
(DTypeSig false "printDefRhs" (TyFun (TyCon "Expr") (TyCon "Doc")))
(DFunDef false "printDefRhs" ((PVar "body")) (EMatch (EApp (EVar "stripLocE") (EVar "body")) (arm (PCon "EGuards" (PVar "arms")) () (EApp (EVar "printGuardArms") (EVar "arms"))) (arm (PCon "ELetGroup" (PVar "binds") (PVar "inner")) () (EApp (EApp (EVar "printWhere") (EVar "binds")) (EVar "inner"))) (arm PWild () (EApp (EApp (EVar "sepBody") (ELit (LString " ="))) (EVar "body")))))
(DTypeSig false "printWhere" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Expr") (TyCon "Doc"))))
(DFunDef false "printWhere" ((PVar "binds") (PVar "inner")) (EBlock (DoLet false false (PVar "bodyD") (EIf (EApp (EVar "isGuardsBody") (EVar "inner")) (EApp (EVar "printGuardArms") (EApp (EVar "guardArmsOf") (EVar "inner"))) (EApp (EApp (EVar "sepBody") (ELit (LString " ="))) (EVar "inner")))) (DoExpr (EApp (EApp (EVar "Cat") (EVar "bodyD")) (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "where")))) (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EVar "letGroupClauses") (EVar "binds"))))))))))
(DTypeSig false "guardArmsOf" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "GuardArm"))))
(DFunDef false "guardArmsOf" ((PVar "e")) (EMatch (EApp (EVar "stripLocE") (EVar "e")) (arm (PCon "EGuards" (PVar "arms")) () (EVar "arms")) (arm PWild () (EListLit))))
(DTypeSig false "letGroupClauses" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "Doc")))
(DFunDef false "letGroupClauses" ((PVar "bindings")) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EVar "joinHard") (EApp (EVar "pieceDocsHard") (EApp (EVar "clausePieces") (EVar "bindings"))))))
(DTypeSig false "clausePieces" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyCon "Piece"))))
(DFunDef false "clausePieces" ((PList)) (EListLit))
(DFunDef false "clausePieces" ((PCons (PCon "LetBind" (PVar "name") (PVar "clauses")) (PVar "rest"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (EApp (EApp (EVar "clausePiece") (EVar "name")) (EVar "c")))) (EVar "clauses")) (EApp (EVar "clausePieces") (EVar "rest"))))
(DTypeSig false "clausePiece" (TyFun (TyCon "String") (TyFun (TyCon "FunClause") (TyCon "Piece"))))
(DFunDef false "clausePiece" ((PVar "name") (PCon "FunClause" (PVar "pats") (PVar "rhs"))) (EMatch (EApp (EVar "clauseSpan") (EApp (EApp (EVar "FunClause") (EVar "pats")) (EVar "rhs"))) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EMatch (EApp (EApp (EApp (EVar "unitStartAt") (ELit (LInt 3))) (EVar "s")) (EVar "sc")) (arm (PTuple (PVar "s2") (PVar "sc2")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s2")) (EVar "sc2")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "defHeader") (EVar "name")) (EVar "pats"))) (EApp (EVar "printDefRhs") (EVar "rhs"))))))))))
(DTypeSig false "printUsePath" (TyFun (TyCon "UsePath") (TyFun (TyCon "Bool") (TyCon "Doc"))))
(DFunDef false "printUsePath" ((PCon "UseName" (PVar "names")) PWild) (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "names"))))
(DFunDef false "printUsePath" ((PCon "UseGroup" (PVar "names") (PVar "members")) (PVar "forced")) (EBlock (DoLet false false (PVar "items") (EApp (EApp (EMethodRef "map") (EVar "useMemberDoc")) (EVar "members"))) (DoLet false false (PVar "body") (EIf (EVar "forced") (EApp (EApp (EApp (EApp (EVar "delimitedPieces") (ELit (LString "{"))) (ELit (LString "}"))) (EVar "True")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELam (PWild) (EVar "d"))))) (EVar "items"))) (EApp (EApp (EApp (EVar "filledDocs") (ELit (LString "{"))) (ELit (LString "}"))) (EVar "items")))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "names")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ".")))) (EVar "body"))))))
(DFunDef false "printUsePath" ((PCon "UseWild" (PVar "names")) PWild) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "names")))) (EApp (EVar "text") (ELit (LString ".*")))))
(DFunDef false "printUsePath" ((PCon "UseAlias" (PVar "names") (PVar "alias")) PWild) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString "."))) (EVar "names")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " as ")))) (EApp (EVar "text") (EVar "alias")))))
(DTypeSig false "useMemberDoc" (TyFun (TyCon "UseMember") (TyCon "Doc")))
(DFunDef false "useMemberDoc" ((PCon "UseMember" (PVar "n") (PVar "allCtors") PWild (PVar "alias"))) (EBlock (DoLet false false (PVar "base") (EIf (EVar "allCtors") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EVar "text") (ELit (LString "(..)")))) (EApp (EVar "text") (EVar "n")))) (DoExpr (EMatch (EVar "alias") (arm (PCon "Some" (PVar "a")) () (EApp (EApp (EVar "Cat") (EVar "base")) (EApp (EVar "text") (EBinOp "++" (EBinOp "++" (ELit (LString " as ")) (EApp (EMethodRef "display") (EVar "a"))) (ELit (LString "")))))) (arm (PCon "None") () (EVar "base"))))))
(DTypeSig false "printVariant" (TyFun (TyCon "Variant") (TyCon "Doc")))
(DFunDef false "printVariant" ((PCon "Variant" (PVar "name") (PCon "ConPos" (PVar "tys")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "t")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printTypeAtom") (EVar "t"))))) (EVar "tys")))))
(DFunDef false "printVariant" ((PCon "Variant" (PVar "name") (PCon "ConNamed" (PVar "fields") (PVar "nameOmitted")))) (EApp (EApp (EApp (EApp (EVar "recordVariantDoc") (EVar "name")) (EVar "fields")) (EVar "nameOmitted")) (EListLit)))
(DTypeSig false "recordVariantDoc" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Field")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyCon "Doc"))))))
(DFunDef false "recordVariantDoc" ((PVar "name") (PVar "fields") (PVar "nameOmitted") (PVar "derives")) (EBlock (DoLet false false (PVar "namePart") (EIf (EVar "nameOmitted") (EApp (EVar "text") (ELit (LString "{"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EVar "text") (ELit (LString " {")))))) (DoLet false false (PVar "sep") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString ",")))) (EVar "Line"))) (DoLet false false (PVar "derivesTail") (EIf (EApp (EVar "isEmptyL") (EVar "derives")) (EVar "Nil") (EApp (EApp (EVar "FlatAlt") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "printDerives") (EVar "derives"))))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printDerives") (EVar "derives")))))) (DoExpr (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EVar "namePart")) (EApp (EApp (EVar "Cat") (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "sepBy") (EVar "sep")) (EApp (EApp (EMethodRef "map") (EVar "fieldTyDoc")) (EVar "fields")))) (EVar "trailingCommaDoc"))))) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "}")))) (EVar "derivesTail")))))))))
(DTypeSig false "fieldTyDoc" (TyFun (TyCon "Field") (TyCon "Doc")))
(DFunDef false "fieldTyDoc" ((PCon "Field" (PVar "fn") (PVar "ft"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "fn"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " : ")))) (EApp (EVar "printType") (EVar "ft")))))
(DTypeSig true "printNamedFieldData" (TyFun (TyCon "DataVis") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyCon "Doc"))))))))
(DFunDef false "printNamedFieldData" ((PVar "vis") (PVar "n") (PVar "params") (PVar "kinds") (PList (PCon "Variant" (PVar "cname") (PCon "ConNamed" (PVar "fields") (PVar "nameOmitted")))) (PVar "derives")) (EBlock (DoLet false false (PVar "eqPart") (EIf (EVar "nameOmitted") (EApp (EVar "text") (ELit (LString " = {"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "cname"))) (EApp (EVar "text") (ELit (LString " {"))))))) (DoLet false false (PVar "head") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "data ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "tyParamsDoc") (EVar "params")) (EVar "kinds"))) (EVar "eqPart"))))) (DoLet false false (PVar "body") (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "Nest") (ELit (LInt 2))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "f")) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "Cat") (EApp (EVar "fieldTyDoc") (EVar "f"))) (EApp (EVar "text") (ELit (LString ","))))))) (EVar "fields"))))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EVar "text") (ELit (LString "}")))))) (DoLet false false (PVar "deriveDoc") (EIf (EApp (EVar "isEmptyL") (EVar "derives")) (EVar "Nil") (EApp (EVar "indentBlock") (EApp (EVar "printDerives") (EVar "derives"))))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "visPrefix") (EVar "vis"))) (EApp (EApp (EVar "Cat") (EVar "head")) (EApp (EApp (EVar "Cat") (EVar "body")) (EVar "deriveDoc")))))))
(DFunDef false "printNamedFieldData" ((PVar "vis") (PVar "n") (PVar "params") (PVar "kinds") (PVar "variants") (PVar "derives")) (EApp (EVar "printDecl") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "dDataUnresolved") (EVar "vis")) (EVar "n")) (EVar "params")) (EVar "kinds")) (EVar "variants")) (EVar "derives"))))
(DTypeSig false "tyParamsDoc" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyCon "Doc"))))
(DFunDef false "tyParamsDoc" ((PVar "params") (PVar "kinds")) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "w")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "text") (EVar "w"))))) (EApp (EApp (EVar "tyParamSources") (EVar "params")) (EVar "kinds")))))
(DTypeSig false "printDerives" (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyCon "Doc")))
(DFunDef false "printDerives" ((PList)) (EVar "Nil"))
(DFunDef false "printDerives" ((PVar "derives")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "deriving (")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "deriveRefName")) (EVar "derives"))))) (EApp (EVar "text") (ELit (LString ")"))))))
(DTypeSig false "visPrefix" (TyFun (TyCon "DataVis") (TyCon "Doc")))
(DFunDef false "visPrefix" ((PCon "VisPublic")) (EApp (EVar "text") (ELit (LString "public export "))))
(DFunDef false "visPrefix" ((PCon "VisAbstract")) (EApp (EVar "text") (ELit (LString "export "))))
(DFunDef false "visPrefix" ((PCon "VisPrivate")) (EVar "Nil"))
(DTypeSig false "dataBodyDoc" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyCon "Doc"))))
(DFunDef false "dataBodyDoc" ((PList) (PVar "derives")) (EApp (EVar "derivesInline") (EVar "derives")))
(DFunDef false "dataBodyDoc" ((PList (PCon "Variant" (PVar "name") (PCon "ConNamed" (PVar "fields") (PVar "nameOmitted")))) (PVar "derives")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EApp (EApp (EVar "recordVariantDoc") (EVar "name")) (EVar "fields")) (EVar "nameOmitted")) (EVar "derives"))))
(DFunDef false "dataBodyDoc" ((PCons (PVar "v") (PVar "vs")) (PVar "derives")) (EApp (EVar "group") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "FlatAlt") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "text") (ELit (LString "| "))))) (EApp (EVar "text") (ELit (LString " "))))) (EApp (EVar "printVariant") (EVar "v")))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "v2")) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "FlatAlt") (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "text") (ELit (LString "| "))))) (EApp (EVar "text") (ELit (LString " | "))))) (EApp (EVar "printVariant") (EVar "v2"))))) (EVar "vs")))) (EApp (EVar "derivesLineOrInline") (EVar "derives"))))))))
(DTypeSig false "derivesInline" (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyCon "Doc")))
(DFunDef false "derivesInline" ((PList)) (EVar "Nil"))
(DFunDef false "derivesInline" ((PVar "derives")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printDerives") (EVar "derives"))))
(DTypeSig false "derivesLineOrInline" (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyCon "Doc")))
(DFunDef false "derivesLineOrInline" ((PList)) (EVar "Nil"))
(DFunDef false "derivesLineOrInline" ((PVar "derives")) (EApp (EApp (EVar "Cat") (EVar "Line")) (EApp (EVar "printDerives") (EVar "derives"))))
(DTypeSig true "printDataDeclCommented" (TyFun (TyCon "DataVis") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyApp (TyCon "Option") (TyCon "KindAnn"))) (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyCon "DeriveRef")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Doc")))))))))
(DFunDef false "printDataDeclCommented" ((PVar "vis") (PVar "n") (PVar "params") (PVar "kinds") (PVar "variants") (PVar "derives") (PVar "vcomments")) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "data ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "tyParamsDoc") (EVar "params")) (EVar "kinds"))))) (DoLet false false (PVar "variantDocs") (EApp (EApp (EVar "dataVariantDocsCommented") (EVar "variants")) (EVar "vcomments"))) (DoLet false false (PVar "deriveDoc") (EIf (EApp (EVar "isEmptyL") (EVar "derives")) (EVar "Nil") (EApp (EVar "indentBlock") (EApp (EVar "printDerives") (EVar "derives"))))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "visPrefix") (EVar "vis"))) (EApp (EApp (EVar "Cat") (EVar "head")) (EApp (EApp (EVar "Cat") (EVar "variantDocs")) (EVar "deriveDoc")))))))
(DTypeSig false "commentLinesDoc" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Doc")))
(DFunDef false "commentLinesDoc" ((PVar "cs")) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EVar "text") (EVar "c"))))) (EVar "cs"))))
(DTypeSig false "trailingCommentsDoc" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Doc")))
(DFunDef false "trailingCommentsDoc" ((PVar "cs")) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "  ")))) (EApp (EVar "text") (EVar "c"))))) (EVar "cs"))))
(DTypeSig false "variantCommentedDoc" (TyFun (TyCon "Variant") (TyFun (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))) (TyCon "Doc"))))
(DFunDef false "variantCommentedDoc" ((PVar "v") (PTuple (PVar "leading") (PVar "trailing"))) (EApp (EApp (EVar "Cat") (EApp (EVar "commentLinesDoc") (EVar "leading"))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "| ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "printVariant") (EVar "v"))) (EApp (EVar "trailingCommentsDoc") (EVar "trailing")))))))
(DTypeSig false "dataVariantDocsCommented" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyCon "Doc"))))
(DFunDef false "dataVariantDocsCommented" ((PList) PWild) (EVar "Nil"))
(DFunDef false "dataVariantDocsCommented" (PWild (PList)) (EVar "Nil"))
(DFunDef false "dataVariantDocsCommented" ((PCons (PVar "v") (PVar "vs")) (PCons (PVar "vc") (PVar "vcs"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " =")))) (EApp (EVar "nest") (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "variantCommentedDoc") (EVar "v")) (EVar "vc"))) (EApp (EVar "concatD") (EApp (EApp (EVar "map2VariantComment") (EVar "vs")) (EVar "vcs")))))))
(DTypeSig false "map2VariantComment" (TyFun (TyApp (TyCon "List") (TyCon "Variant")) (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "Doc")))))
(DFunDef false "map2VariantComment" ((PList) PWild) (EListLit))
(DFunDef false "map2VariantComment" (PWild (PList)) (EListLit))
(DFunDef false "map2VariantComment" ((PCons (PVar "v") (PVar "vs")) (PCons (PVar "vc") (PVar "vcs"))) (EBinOp "::" (EApp (EApp (EVar "variantCommentedDoc") (EVar "v")) (EVar "vc")) (EApp (EApp (EVar "map2VariantComment") (EVar "vs")) (EVar "vcs"))))
(DTypeSig false "valueExportPrefix" (TyFun (TyCon "Bool") (TyCon "Doc")))
(DFunDef false "valueExportPrefix" ((PVar "pub")) (EIf (EVar "pub") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "export")))) (EVar "Hardline")) (EVar "Nil")))
(DTypeSig false "defHeader" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Doc"))))
(DFunDef false "defHeader" ((PVar "n") (PVar "pats")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printPatAtom") (EVar "p"))))) (EVar "pats")))))
(DTypeSig false "importForcedRef" (TyApp (TyCon "Ref") (TyCon "Bool")))
(DFunDef false "importForcedRef" () (EApp (EVar "Ref") (EVar "False")))
(DTypeSig true "setImportForced" (TyFun (TyCon "Bool") (TyCon "Unit")))
(DFunDef false "setImportForced" ((PVar "b")) (EApp (EApp (EVar "setRef") (EVar "importForcedRef")) (EVar "b")))
(DTypeSig true "printDecl" (TyFun (TyCon "Decl") (TyCon "Doc")))
(DFunDef false "printDecl" ((PCon "DTypeSig" (PVar "pub") (PVar "n") (PVar "t"))) (EApp (EApp (EVar "Cat") (EApp (EVar "valueExportPrefix") (EVar "pub"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " : ")))) (EApp (EVar "sigTypeDoc") (EVar "t"))))))
(DFunDef false "printDecl" ((PCon "DExtern" (PVar "pub") (PVar "n") (PVar "t"))) (EApp (EApp (EVar "Cat") (EApp (EVar "valueExportPrefix") (EVar "pub"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "extern ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " : ")))) (EApp (EVar "sigTypeDoc") (EVar "t")))))))
(DFunDef false "printDecl" ((PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "defHeader") (EVar "n")) (EVar "pats"))) (EApp (EVar "printDefRhs") (EVar "body")))))
(DFunDef false "printDecl" ((PCon "DLetGroup" (PVar "pub") (PVar "bindings"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EVar "letGroupDecl") (EVar "bindings"))))
(DFunDef false "printDecl" ((PRec "DData" ((rf "dataVis" (PVar "vis")) (rf "dataName" (PVar "n")) (rf "dataParams" (PVar "params")) (rf "dataParamKinds" (PVar "kinds")) (rf "dataCtors" (PVar "variants")) (rf "dataDerives" (PVar "derives"))) false)) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "data ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "tyParamsDoc") (EVar "params")) (EVar "kinds"))))) (DoExpr (EApp (EApp (EVar "Cat") (EApp (EVar "visPrefix") (EVar "vis"))) (EApp (EApp (EVar "Cat") (EVar "head")) (EApp (EApp (EVar "dataBodyDoc") (EVar "variants")) (EVar "derives")))))))
(DFunDef false "printDecl" ((PRec "DTypeAlias" ((rf "tyAliasPub" (PVar "pub")) (rf "tyAliasName" (PVar "n")) (rf "tyAliasParams" (PVar "params")) (rf "tyAliasParamKinds" (PVar "kinds")) (rf "tyAliasRhs" (PVar "rhs"))) false)) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "type ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "tyParamsDoc") (EVar "params")) (EVar "kinds"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EVar "printType") (EVar "rhs"))))))))
(DFunDef false "printDecl" ((PRec "DNewtype" ((rf "newtypePub" (PVar "pub")) (rf "newtypeName" (PVar "n")) (rf "newtypeParams" (PVar "params")) (rf "newtypeParamKinds" (PVar "kinds")) (rf "newtypeCtor" (PVar "con")) (rf "newtypeFieldTy" (PVar "fty")) (rf "newtypeDerives" (PVar "derives"))) false)) (EBlock (DoLet false false (PVar "head") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "newtype ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "tyParamsDoc") (EVar "params")) (EVar "kinds"))))) (DoLet false false (PVar "body") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " = ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "con"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printTypeAtom") (EVar "fty")))))) (DoExpr (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EVar "head")) (EApp (EApp (EVar "Cat") (EVar "body")) (EApp (EVar "group") (EApp (EVar "nest") (EApp (EVar "derivesLineOrInline") (EVar "derives"))))))))))
(DFunDef false "printDecl" ((PRec "DInterface" ((rf "pub" None) (rf "def" None) (rf "name" None) (rf "typarams" None) (rf "typaramKinds" None) (rf "supers" None) (rf "methods" None)) false)) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EIf (EVar "def") (EApp (EVar "text") (ELit (LString "default "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "interface ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "tyParamsDoc") (EVar "typarams")) (EVar "typaramKinds"))) (EApp (EApp (EVar "Cat") (EApp (EVar "superDoc") (EVar "supers"))) (EIf (EApp (EVar "isEmptyL") (EVar "methods")) (EVar "Nil") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " where")))) (EApp (EVar "methodsBlock") (EApp (EApp (EMethodRef "map") (EVar "ifaceMethodPiece")) (EVar "methods"))))))))))))
(DFunDef false "printDecl" ((PRec "DImpl" ((rf "pub" None) (rf "iface" None) (rf "tys" None) (rf "reqs" None) (rf "methods" None)) false)) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "impl ")))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "implHead") (EVar "iface")) (EVar "tys"))) (EApp (EApp (EVar "Cat") (EApp (EVar "reqsDoc") (EVar "reqs"))) (EIf (EApp (EVar "isEmptyL") (EVar "methods")) (EVar "Nil") (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " where")))) (EApp (EVar "methodsBlock") (EApp (EApp (EMethodRef "map") (EVar "implMethodPiece")) (EVar "methods"))))))))))
(DFunDef false "printDecl" ((PCon "DUse" (PVar "pub") (PVar "path") PWild)) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "import ")))) (EApp (EApp (EVar "printUsePath") (EVar "path")) (EUnOp "!" (EVar "importForcedRef"))))))
(DFunDef false "printDecl" ((PCon "DEffect" (PVar "pub") (PVar "name") (PVar "domain"))) (EApp (EApp (EVar "Cat") (EApp (EVar "effDeclHead") (EVar "pub"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "name"))) (EApp (EVar "effDomainDoc") (EVar "domain")))))
(DFunDef false "printDecl" ((PCon "DProp" (PVar "pub") (PVar "propName") (PVar "propParams") (PVar "propBody"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "prop ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EVar "escStringLit") (EVar "propName")))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (EVar "propParamDoc")) (EVar "propParams")))) (EApp (EVar "printDefRhs") (EVar "propBody")))))))
(DFunDef false "printDecl" ((PCon "DTest" (PVar "pub") (PVar "testName") (PVar "testBody"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "test ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EVar "escStringLit") (EVar "testName")))) (EApp (EVar "printDefRhs") (EVar "testBody"))))))
(DFunDef false "printDecl" ((PCon "DBench" (PVar "pub") (PVar "benchName") (PVar "benchBody"))) (EApp (EApp (EVar "Cat") (EIf (EVar "pub") (EApp (EVar "text") (ELit (LString "export "))) (EVar "Nil"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "bench ")))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EApp (EVar "escStringLit") (EVar "benchName")))) (EApp (EVar "printDefRhs") (EVar "benchBody"))))))
(DFunDef false "printDecl" ((PCon "DAttrib" (PVar "attrs") (PVar "inner"))) (EApp (EApp (EVar "Cat") (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (EVar "attrDoc")) (EVar "attrs")))) (EApp (EVar "printDecl") (EVar "inner"))))
(DTypeSig false "methodsBlock" (TyFun (TyApp (TyCon "List") (TyCon "Piece")) (TyCon "Doc")))
(DFunDef false "methodsBlock" ((PVar "ps")) (EApp (EVar "indentBlock") (EApp (EVar "joinHard") (EApp (EVar "pieceDocsHard") (EVar "ps")))))
(DTypeSig false "propParamDoc" (TyFun (TyCon "PropParam") (TyCon "Doc")))
(DFunDef false "propParamDoc" ((PCon "PropParam" (PVar "x") PWild (PVar "ty"))) (EApp (EVar "text") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString " (")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString " : "))) (EApp (EMethodRef "display") (EApp (EVar "ppTy") (EVar "ty")))) (ELit (LString ")")))))
(DTypeSig false "attrDoc" (TyFun (TyCon "Attr") (TyCon "Doc")))
(DFunDef false "attrDoc" ((PCon "AttrDeprecated" (PVar "msg"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EBinOp "++" (ELit (LString "@deprecated ")) (EApp (EVar "escStringLit") (EVar "msg"))))) (EVar "Hardline")))
(DFunDef false "attrDoc" ((PCon "AttrInline")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "@inline")))) (EVar "Hardline")))
(DFunDef false "attrDoc" ((PCon "AttrMustUse")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString "@must_use")))) (EVar "Hardline")))
(DTypeSig false "letGroupDecl" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyCon "Doc")))
(DFunDef false "letGroupDecl" ((PVar "bindings")) (EBlock (DoLet false false (PVar "docs") (EApp (EApp (EVar "letGroupDeclGo") (EVar "True")) (EVar "bindings"))) (DoExpr (EApp (EVar "concatD") (EVar "docs")))))
(DTypeSig false "letGroupDeclGo" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyApp (TyCon "List") (TyCon "Doc")))))
(DFunDef false "letGroupDeclGo" (PWild (PList)) (EListLit))
(DFunDef false "letGroupDeclGo" ((PVar "first") (PCons (PCon "LetBind" (PVar "name") (PVar "clauses")) (PVar "rest"))) (EBlock (DoLet false false (PVar "r") (EApp (EApp (EApp (EVar "letGroupBindClauses") (EVar "first")) (EVar "name")) (EVar "clauses"))) (DoExpr (EMatch (EVar "r") (arm (PTuple (PVar "docs") (PVar "nextFirst")) () (EBinOp "++" (EVar "docs") (EApp (EApp (EVar "letGroupDeclGo") (EVar "nextFirst")) (EVar "rest"))))))))
(DTypeSig false "letGroupBindClauses" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyTuple (TyApp (TyCon "List") (TyCon "Doc")) (TyCon "Bool"))))))
(DFunDef false "letGroupBindClauses" ((PVar "first") PWild (PList)) (ETuple (EListLit) (EVar "first")))
(DFunDef false "letGroupBindClauses" ((PVar "first") (PVar "name") (PCons (PVar "c") (PVar "cs"))) (EBlock (DoLet false false (PVar "d") (EApp (EApp (EApp (EVar "letGroupDeclClause") (EVar "first")) (EVar "name")) (EVar "c"))) (DoLet false false (PVar "r") (EApp (EApp (EApp (EVar "letGroupBindClauses") (EVar "False")) (EVar "name")) (EVar "cs"))) (DoExpr (EMatch (EVar "r") (arm (PTuple (PVar "rest") (PVar "lastFirst")) () (ETuple (EBinOp "::" (EVar "d") (EVar "rest")) (EVar "lastFirst")))))))
(DTypeSig false "letGroupDeclClause" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "FunClause") (TyCon "Doc")))))
(DFunDef false "letGroupDeclClause" ((PVar "first") (PVar "name") (PCon "FunClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "Cat") (EIf (EVar "first") (EApp (EVar "text") (ELit (LString "let rec "))) (EApp (EApp (EVar "Cat") (EVar "Hardline")) (EApp (EVar "text") (ELit (LString "with ")))))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "defHeader") (EVar "name")) (EVar "pats"))) (EApp (EVar "printDefRhs") (EVar "body")))))
(DTypeSig false "superDoc" (TyFun (TyApp (TyCon "List") (TyCon "Super")) (TyCon "Doc")))
(DFunDef false "superDoc" ((PList)) (EVar "Nil"))
(DFunDef false "superDoc" ((PVar "supers")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " requires ")))) (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EVar "oneSuper")) (EVar "supers")))))
(DTypeSig false "oneSuper" (TyFun (TyCon "Super") (TyCon "Doc")))
(DFunDef false "oneSuper" ((PRec "Super" ((rf "superHead" (PVar "n")) (rf "superParams" (PVar "ps"))) false)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "text") (EVar "p"))))) (EVar "ps")))))
(DTypeSig false "ifaceMethodPiece" (TyFun (TyCon "IfaceMethod") (TyCon "Piece")))
(DFunDef false "ifaceMethodPiece" ((PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "None") (PVar "l"))) (EMatch (EVar "l") (arm (PCon "Some" (PVar "loc")) () (EMatch (EApp (EVar "locSpan") (EVar "loc")) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s")) (EVar "sc")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EVar "ifaceMethodDoc") (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EVar "None")) (EVar "l")))))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELam (PWild) (EApp (EVar "ifaceMethodDoc") (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EVar "None")) (EVar "l"))))))))
(DFunDef false "ifaceMethodPiece" ((PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))) (PVar "l"))) (EBlock (DoLet false false (PVar "sp") (EApp (EApp (EVar "mergeSpan") (EApp (EApp (EVar "spansOf") (EVar "patSpan")) (EVar "pats"))) (EApp (EVar "exprSpan") (EVar "body")))) (DoExpr (EMatch (EVar "sp") (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s")) (EVar "sc")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EVar "ifaceMethodDoc") (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EVar "pats")) (EVar "body")))) (EVar "l"))))))))))
(DTypeSig false "ifaceMethodDoc" (TyFun (TyCon "IfaceMethod") (TyCon "Doc")))
(DFunDef false "ifaceMethodDoc" ((PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "None") PWild)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "n"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " : ")))) (EApp (EVar "sigTypeDoc") (EVar "ty")))))
(DFunDef false "ifaceMethodDoc" ((PCon "IfaceMethod" (PVar "n") PWild (PCon "Some" (PCon "MethodDefault" (PVar "pats") (PVar "body"))) PWild)) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "defHeader") (EVar "n")) (EVar "pats"))) (EApp (EVar "printDefRhs") (EVar "body"))))
(DTypeSig false "implHead" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyCon "Doc"))))
(DFunDef false "implHead" ((PVar "iface") (PVar "tys")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "iface"))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "t")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printTypeAtom") (EVar "t"))))) (EVar "tys")))))
(DTypeSig false "reqsDoc" (TyFun (TyApp (TyCon "List") (TyCon "Require")) (TyCon "Doc")))
(DFunDef false "reqsDoc" ((PList)) (EVar "Nil"))
(DFunDef false "reqsDoc" ((PVar "reqs")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " requires ")))) (EApp (EApp (EVar "sepBy") (EApp (EVar "text") (ELit (LString ", ")))) (EApp (EApp (EMethodRef "map") (EVar "oneReq")) (EVar "reqs")))))
(DTypeSig false "oneReq" (TyFun (TyCon "Require") (TyCon "Doc")))
(DFunDef false "oneReq" ((PRec "Require" ((rf "requireHead" (PVar "iface")) (rf "requireArgs" (PVar "args"))) false)) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (EVar "iface"))) (EApp (EVar "concatD") (EApp (EApp (EMethodRef "map") (ELam ((PVar "t")) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "printTypeAtom") (EVar "t"))))) (EVar "args")))))
(DTypeSig false "implMethodPiece" (TyFun (TyCon "ImplMethod") (TyCon "Piece")))
(DFunDef false "implMethodPiece" ((PCon "ImplMethod" (PVar "n") (PVar "pats") (PVar "body"))) (EMatch (EApp (EApp (EVar "mergeSpan") (EApp (EApp (EVar "spansOf") (EVar "patSpan")) (EVar "pats"))) (EApp (EVar "exprSpan") (EVar "body"))) (arm (PTuple (PVar "s") (PVar "sc") (PVar "en") (PVar "ec")) () (EMatch (EApp (EApp (EApp (EVar "unitStartAt") (ELit (LInt 2))) (EVar "s")) (EVar "sc")) (arm (PTuple (PVar "s2") (PVar "sc2")) () (EApp (EApp (EApp (EApp (EApp (EVar "Piece") (EVar "s2")) (EVar "sc2")) (EVar "en")) (EVar "ec")) (ELam (PWild) (EApp (EVar "implMethodDoc") (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EVar "pats")) (EVar "body"))))))))))
(DTypeSig false "implMethodDoc" (TyFun (TyCon "ImplMethod") (TyCon "Doc")))
(DFunDef false "implMethodDoc" ((PCon "ImplMethod" (PVar "n") (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "Cat") (EApp (EApp (EVar "defHeader") (EVar "n")) (EVar "pats"))) (EApp (EVar "printDefRhs") (EVar "body"))))
(DTypeSig true "ppTy" (TyFun (TyCon "Ty") (TyCon "String")))
(DFunDef false "ppTy" ((PVar "t")) (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 0))) (EVar "t")))
(DTypeSig false "ppTyPrec" (TyFun (TyCon "Int") (TyFun (TyCon "Ty") (TyCon "String"))))
(DFunDef false "ppTyPrec" (PWild (PRec "TyCon" ((rf "tyConName" (PVar "s"))) false)) (EApp (EVar "tyConSurface") (EVar "s")))
(DFunDef false "ppTyPrec" (PWild (PCon "TyVar" (PVar "s"))) (EVar "s"))
(DFunDef false "ppTyPrec" (PWild (PCon "TyTuple" (PVar "ts"))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ppTyPrec") (ELit (LInt 0)))) (EVar "ts")))) (ELit (LString ")"))))
(DFunDef false "ppTyPrec" ((PVar "p") (PCon "TyApp" (PVar "f") (PVar "x"))) (EBlock (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 1))) (EVar "f")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 2))) (EVar "x")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 2))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyPrec" ((PVar "p") (PCon "TyFun" (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 1))) (EVar "a")))) (ELit (LString " -> "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 0))) (EVar "b")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 1))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyPrec" ((PVar "p") (PCon "TyEffect" (PVar "effs") (PVar "tail") (PVar "t"))) (EBlock (DoLet false false (PVar "inside") (EApp (EApp (EVar "ppEffInside") (EVar "effs")) (EVar "tail"))) (DoLet false false (PVar "s") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EMethodRef "display") (EVar "inside"))) (ELit (LString "> "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 0))) (EVar "t")))) (ELit (LString "")))) (DoExpr (EIf (EBinOp ">=" (EVar "p") (ELit (LInt 1))) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "s")) (ELit (LString ")"))) (EVar "s")))))
(DFunDef false "ppTyPrec" (PWild (PCon "TyRow" (PList) (PCons (PVar "a") (PCons (PVar "b") (PVar "rest"))) PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EBinOp "::" (EVar "a") (EBinOp "::" (EVar "b") (EVar "rest")))))) (ELit (LString ")"))))
(DFunDef false "ppTyPrec" (PWild (PCon "TyRow" (PVar "effs") (PVar "tail") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "<")) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppEffInside") (EVar "effs")) (EVar "tail")))) (ELit (LString ">"))))
(DFunDef false "ppTyPrec" (PWild (PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EBlock (DoLet false false (PVar "csStr") (EMatch (EVar "cs") (arm (PList (PVar "c")) () (EApp (EVar "ppConstr") (EVar "c"))) (arm PWild () (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "ppConstr")) (EVar "cs")))) (ELit (LString ")")))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "csStr"))) (ELit (LString " => "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "ppTyPrec") (ELit (LInt 0))) (EVar "t")))) (ELit (LString ""))))))
(DTypeSig false "ppEffInside" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "ppEffInside" ((PVar "effs") (PList)) (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "ppEffAtom")) (EVar "effs"))))
(DFunDef false "ppEffInside" ((PList) (PVar "tails")) (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails")))
(DFunDef false "ppEffInside" ((PVar "effs") (PVar "tails")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "ppEffAtom")) (EVar "effs"))))) (ELit (LString " | "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " | "))) (EVar "tails")))) (ELit (LString ""))))
(DTypeSig false "ppEffAtom" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))) (TyCon "String")))
(DFunDef false "ppEffAtom" ((PTuple (PVar "l") (PCon "None"))) (EVar "l"))
(DFunDef false "ppEffAtom" ((PTuple (PVar "l") (PCon "Some" (PVar "s")))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "escStringLit") (EVar "s")))) (ELit (LString ""))))
(DTypeSig false "effDomainDoc" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "Doc")))
(DFunDef false "effDomainDoc" ((PCon "None")) (EVar "Nil"))
(DFunDef false "effDomainDoc" ((PCon "Some" (PVar "d"))) (EApp (EApp (EVar "Cat") (EApp (EVar "text") (ELit (LString " ")))) (EApp (EVar "text") (EVar "d"))))
(DTypeSig false "effDeclHead" (TyFun (TyCon "Bool") (TyCon "Doc")))
(DFunDef false "effDeclHead" ((PCon "True")) (EApp (EVar "text") (ELit (LString "export effect "))))
(DFunDef false "effDeclHead" ((PCon "False")) (EApp (EVar "text") (ELit (LString "effect "))))
(DTypeSig false "ppConstr" (TyFun (TyCon "Constraint") (TyCon "String")))
(DFunDef false "ppConstr" ((PRec "Constraint" ((rf "constraintHead" (PVar "iface")) (rf "constraintArgs" (PVar "args"))) false)) (EIf (EApp (EVar "isEmptyL") (EVar "args")) (EVar "iface") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ppTyPrec") (ELit (LInt 2)))) (EVar "args"))))) (ELit (LString "")))))
(DTypeSig true "exprToString" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "exprToString" ((PVar "e")) (EApp (EVar "render") (EApp (EApp (EVar "printExpr") (EVar "precTop")) (EVar "e"))))
(DTypeSig true "declToString" (TyFun (TyCon "Decl") (TyCon "String")))
(DFunDef false "declToString" ((PVar "d")) (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "d"))))
(DTypeSig true "programToString" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "String")))
(DFunDef false "programToString" ((PVar "decls")) (EApp (EVar "stringConcat") (EApp (EApp (EMethodRef "map") (EVar "declLine")) (EVar "decls"))))
(DTypeSig false "declLine" (TyFun (TyCon "Decl") (TyCon "String")))
(DFunDef false "declLine" ((PVar "d")) (EBinOp "++" (EApp (EVar "render") (EApp (EVar "printDecl") (EVar "d"))) (ELit (LString "\n"))))
