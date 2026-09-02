# FMT comment placement — design

**Status:** the design below replaced the 2026-07-01 line-index splice
machinery (three special-cased declaration shapes plus a verbatim safety net
for everything else) on 2026-09-02. The git history of this file carries the
earlier design and the "finding L" incident that motivated it.

## The problem

Comments are not in the AST. The lexer captures them out of band
(`collectComments`, `compiler/frontend/lexer.mdk`: line, column, lexeme) and
the parser records each declaration's line span (`parseWithPositions`,
`compiler/frontend/parser.mdk`). A formatter that reflows a declaration by
width cannot put a comment back by *line number*, because the output lines no
longer correspond to the source lines. The earlier design handled exactly three
shapes (data variants, operator chains, block statements) and copied every other
commented declaration through verbatim — which made `fmt --check` report
hand-laid-out code as formatted.

## The design

Comments are attached to **layout units** while the document is built, by the
printer itself (`compiler/tools/printer.mdk`, section "Comments" and "Pieces").

1. `medaka fmt` (`compiler/tools/fmt.mdk`) hands the printer each
   declaration's interior comments, ascending by line, each flagged
   *standalone* (nothing but whitespace precedes it on its source line) or
   *trailing*, together with the line bound past which no comment belongs to
   the declaration (`setComments`).
2. Every sequence the printer lays out — block statements, match arms, guard
   arms, collection elements, record fields, application arguments, operator
   chain operands, interface/impl methods — is a list of `Piece`s: the unit's
   source span (start line, start column, end line, read off the `ELoc`
   wrappers and pattern locations inside it) and its doc builder.
3. `pieceDocs` walks the pieces in order. Before building a piece it pops every
   pending comment above the piece's start line and emits them as their own
   lines; after building it, it pops the pending trailing comments before the
   next piece's start line and anchors them to the piece as `LineComment`
   nodes; after the last piece it claims standalone comments that are indented
   at least as deep as the sequence (shallower ones document the enclosing
   sequence's next unit). Nested sequences see a bound equal to the next
   outer piece's start line, so a comment is claimed by the innermost unit
   whose span reaches it.
4. A `LineComment` ends its output line: `fits` refuses to lay a flat candidate
   across one, so every enclosing group breaks, while a group that *precedes*
   the comment on the line is measured only up to it. A comma is glued to a
   piece *before* its trailing comment.
5. A blank line in the source between two statements or arms is preserved as
   one `BlankLine` (an empty output line with no indentation).
6. Any comment the walk did not place is left pending. `fmt.mdk` then emits
   the declaration's **original source text** instead (no comment moves or
   disappears), and the final accounting (`checkCommentCount`) refuses to
   produce output at all if the number of comments emitted differs from the
   number captured.

`data` declarations keep their own per-variant / per-field placement
(`printDataDeclCommented`, `printNamedFieldData`): variants carry no source
locations, and the parser's variant-line side-channel already places those
comments exactly.

## Invariants and how they are tested

- `test/diff_compiler_fmt_roundtrip.sh`: over every tracked `.mdk` that is
  meant to parse, `parse(fmt(f)) == parse(f)`, `fmt(fmt(f)) == fmt(f)`, and
  no trailing whitespace.
- `test/diff_compiler_fmt.sh`: golden output for `test/fmt_fixtures/` and
  `test/parse_fixtures/`.
- The comment count invariant runs on every `fmt` invocation.
