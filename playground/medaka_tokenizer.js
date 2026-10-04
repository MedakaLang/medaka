// medaka_tokenizer.js — a hand-written stream tokenizer for Medaka, matching the
// compiler lexer's token classes (compiler/frontend/lexer.mdk; census in
// PLAYGROUND-EDITOR-DESIGN.md §5).  It is a CodeMirror-6 StreamParser body, but
// it has NO CodeMirror imports so it can be unit-tested in isolation over any
// object implementing the CM6 StringStream surface (peek/next/eat/eatSpace/
// match/eol/pos/string).  medaka_lang.js wires it into a real StreamLanguage.
//
// token() returns one of these class names per token (mapped to highlight tags
// by medaka_lang.js's tokenTable):
//   keyword comment string character number typeName constructor variableName
//   operator punctuation bool escape interpolation typeVar effectLabel effectVar
//
// typeVar is a lowercase identifier in type position; effectLabel an uppercase
// name inside a `< … >` row or the name after `effect`; effectVar a lowercase
// name inside a row (`e` in `<e>`, `<Clock | e>`).  Like typeName, all three
// are positional guesses.
//
// typeName vs constructor is a POSITIONAL guess, not a parse: an uppercase
// identifier is a type in type position and a constructor everywhere else.
// Type position is line-local — it opens at a single `:` (an annotation),
// after `data`/`type`/`newtype`/`interface`/`impl`/`requires`/`deriving`/
// `import`, and closes at end of line or at the `=` of an annotated binding.
// Inside a `data` body (which spans its indented continuation lines) the
// first uppercase name after each `=` / `|` is the constructor and the rest
// of that alternative is types. A top-level (column-0) line resets both.
//
// The stateful pieces are handled through the parser state object:
//   blockComment : nesting depth of `{- {- -} -}` block comments (0 = outside)
//   strKind      : 'normal' | 'triple' when currently scanning a string body,
//                  else null
//   interpStack  : stack of { brace, kind } frames for `"a \{expr} b"` string
//                  interpolation — each frame remembers the enclosing string
//                  kind to resume when its `{`/`}` balance returns to 0
//                  (interpolations nest: `"\{ f "\{x}" }"`).
//   typePos      : true while in type position on the current line
//   decl         : 'data' | 'alias' | null — the top-level declaration the
//                  current line belongs to, for the `=` / `|` rules above
//   ctorNext     : true when the next uppercase name is a constructor
//   last         : text of the last operator/punctuation token on the line, or
//                  null if the last significant token was anything else
//   depth        : open `( [ {` count while in type position (carry-over test)
//   angle        : open type-position `<` count (effect rows)
//   effHead      : true after the `effect` keyword until its name is read
//   imp          : true on an `import` line (and its carried-over lines), whose lowercase
//                  names are not type variables
//   pdepth       : open `( [ {` count in ALL positions (line-local; reset at column 0)
//   ascAt        : pdepth where the current type position was opened by a `:` from
//                  expression position (an ascription or signature), else null. A
//                  `)` that closes below it, a keyword like `in`/`then`/`else`, or an
//                  arithmetic operator / `,` at that depth ends the type position.

// The keyword set, mirroring lexer.mdk's `keywordOrIdent` table.  True/False are
// NOT here — they lex as TUpper (uppercase), handled as `bool` below.  Derive the
// authority, don't trust a count (this comment claimed "28" for a 32-element set):
//   grep -n '^keywordOrIdent "' compiler/frontend/lexer.mdk
// `record` was removed from this set by #62 — it is an ordinary identifier now.
// (`internal` is here but not in `keywordOrIdent`; it is a modifier the
// playground colours, not a lexer keyword.)
export const KEYWORDS = new Set([
  'let', 'rec', 'with', 'mut', 'in', 'if', 'then', 'else', 'match', 'data',
  'interface', 'default', 'impl', 'import', 'export', 'public',
  'where', 'of', 'do', 'defer', 'as', 'extern', 'requires', 'deriving', 'type',
  'newtype', 'prop', 'test', 'bench', 'effect', 'internal', 'function',
]);

// Multi-char operators, longest-first so a plain string match never truncates a
// longer operator (lexer.mdk scanOp, 725-775).
const OP3 = ['...'];
const OP2 = ['==', '/=', '<=', '>=', '&&', '||', '::', '++', '|>', '>>', '<<',
  '=>', '->', '<-', '[|', '|]', '{.', '.*', '..', '.=', '@|'];
const OP1_SET = '+-*/%<>=:.|!?@~^&$';   // single-char operator chars
const PUNCT_SET = '()[],;';             // delimiters (not braces — see below)

export function startState() {
  return { blockComment: 0, strKind: null, interpStack: [], typePos: false, decl: null, ctorNext: false, last: null, depth: 0, angle: 0, effHead: false, imp: false, pdepth: 0, ascAt: null };
}

export function copyState(s) {
  return {
    blockComment: s.blockComment,
    strKind: s.strKind,
    interpStack: s.interpStack.map((f) => ({ brace: f.brace, kind: f.kind })),
    typePos: s.typePos, decl: s.decl, ctorNext: s.ctorNext,
    last: s.last, depth: s.depth, angle: s.angle,
    effHead: s.effHead, imp: s.imp, pdepth: s.pdepth, ascAt: s.ascAt,
  };
}

export function token(stream, state) {
  if (state.blockComment > 0) return tokenBlockComment(stream, state);
  if (state.strKind) return tokenString(stream, state);
  const type = tokenCode(stream, state);
  if (type !== null && type !== 'comment') {
    state.last = (type === 'operator' || type === 'punctuation')
      ? stream.string.slice(stream.start, stream.pos) : null;
  }
  return type;
}

// Inside a `{- … -}` block comment (possibly spanning lines / nested).
function tokenBlockComment(stream, state) {
  while (!stream.eol()) {
    if (stream.match('{-')) { state.blockComment++; continue; }
    if (stream.match('-}')) {
      state.blockComment--;
      if (state.blockComment <= 0) { state.blockComment = 0; break; }
      continue;
    }
    stream.next();
  }
  return 'comment';
}

// Inside a string body (normal `"…"` or triple `"""…"""`).  Emits one token:
// either the interpolation opener `\{` (switching to code), the closing
// delimiter, an escape, or a run of literal text.
function tokenString(stream, state) {
  const triple = state.strKind === 'triple';

  // interpolation opener `\{` — begins an embedded code region
  if (stream.match('\\{')) {
    state.interpStack.push({ brace: 1, kind: state.strKind });
    state.strKind = null;
    return 'interpolation';
  }

  // closing delimiter
  if (triple) {
    if (stream.match('"""')) { state.strKind = null; return 'string'; }
  } else if (stream.match('"')) {
    state.strKind = null;
    return 'string';
  }

  // escape sequence (normal strings process escapes; triples treat `\` as
  // literal except before `{`, already handled above)
  if (!triple && stream.peek() === '\\') {
    stream.next();                       // backslash
    if (!stream.eol()) {
      const e = stream.next();
      if (e === 'u' && stream.peek() === '{') {
        while (!stream.eol() && stream.next() !== '}') { /* \u{HEX} */ }
      }
    }
    return 'escape';
  }

  // literal run up to the next special char (`"`, `\`, or EOL)
  while (!stream.eol()) {
    const c = stream.peek();
    if (c === '"' || c === '\\') break;
    stream.next();
  }
  // Guard against a zero-width token (StreamLanguage requires progress): if we
  // consumed nothing, take one char so we always advance.
  if (stream.eol() && stream.pos === stream.start) { /* handled by caller */ }
  return 'string';
}

// Keywords that put the rest of the line in type position.
const TYPE_HEAD = new Set(['interface', 'impl', 'requires', 'deriving', 'import', 'effect']);

// Keywords and operators that cannot continue a type, so they end an ascription's
// type position (`xs : List Int in …`, `(a : Int) + b`). `->`, `=>`, `<`, `>`, `*`
// and `|` are absent: they occur inside types.
const ASCRIPTION_END = new Set(['in', 'then', 'else', 'of', 'do', 'if', 'let', 'match']);
const ASCRIPTION_END_OPS = new Set(['+', '-', '/', '%', '==', '/=', '<=', '>=', '&&', '||', '++', '|>', '>>', '<<', '::', '<-']);

function endsAscription(state) {
  return state.typePos && state.ascAt !== null && state.ascAt > 0 &&
    state.pdepth === state.ascAt && state.angle === 0;
}

function closeAscription(state) {
  state.typePos = false; state.ascAt = null; state.depth = 0; state.angle = 0;
}

// A `)` `]` `}` that closes the delimiter an ascription was opened inside ends it.
function closeDelim(state) {
  if (state.pdepth > 0) state.pdepth--;
  if (state.typePos && state.ascAt !== null && state.pdepth < state.ascAt) closeAscription(state);
}

function tokenCode(stream, state) {
  if (stream.pos === 0) {
    // Line start. A column-0 line is a new top-level declaration; an indented
    // one continues the current declaration (type position only inside a
    // data body — an impl/interface body is expressions again).
    const indented = stream.peek() === ' ' || stream.peek() === '\t';
    if (!indented) { state.decl = null; state.ctorNext = false; state.pdepth = 0; }
    const open = state.depth > 0 && (state.last === ',' || state.last === '(' ||
                                     state.last === '<' || state.last === '{');
    const carry = indented && state.typePos &&
      (state.last === '->' || state.last === ':' || state.last === '>' || open ||
       stream.match(/^\s*->/, false) !== null);
    if (!carry) { state.depth = 0; state.angle = 0; state.ascAt = null; }
    state.last = null;
    state.effHead = false; state.imp = carry ? state.imp : false;
    state.typePos = carry || state.decl === 'data' || state.decl === 'alias';
  }
  if (stream.eatSpace()) return null;

  const c = stream.peek();

  // line comment `-- … EOL`
  if (c === '-' && stream.match('--', false)) { stream.skipToEnd(); return 'comment'; }

  // block comment open `{-`
  if (c === '{' && stream.match('{-')) { state.blockComment = 1; return tokenBlockComment(stream, state); }

  // string / char literals
  if (c === '"') {
    if (stream.match('"""')) { state.strKind = 'triple'; return 'string'; }
    stream.match('"');
    state.strKind = 'normal';
    return 'string';
  }
  if (c === "'") return tokenChar(stream);

  // numbers: radix (0x/0b/0o) first, then decimal int / float (no sci-notation)
  if (c >= '0' && c <= '9') {
    if (stream.match(/^0x[0-9a-fA-F][0-9a-fA-F_]*/) ||
        stream.match(/^0b[01][01_]*/) ||
        stream.match(/^0o[0-7][0-7_]*/)) return 'number';
    stream.match(/^[0-9][0-9_]*(\.[0-9][0-9_]*)?/);   // int or `int.frac`
    return 'number';
  }

  // backtick infix operator `` `f` ``
  if (c === '`') {
    stream.next();
    while (!stream.eol() && stream.next() !== '`') { /* to closing backtick */ }
    return 'operator';
  }

  // uppercase identifier (TUpper): types / constructors; True/False are bools
  if (c >= 'A' && c <= 'Z') {
    const w = stream.match(/^[A-Za-z0-9_]+/)[0];
    if (w === 'True' || w === 'False') return 'bool';
    if (state.effHead) { state.effHead = false; return 'effectLabel'; }
    if (state.angle > 0) return 'effectLabel';
    if (state.ctorNext) { state.ctorNext = false; state.typePos = true; return 'constructor'; }
    if (state.typePos) return 'typeName';
    // `M.get`: a module alias, neither a type nor a constructor — keep it neutral.
    if (stream.peek() === '.' && /^\.[A-Za-z_]/.test(stream.string.slice(stream.pos, stream.pos + 2))) return 'typeName';
    return 'constructor';
  }

  // lowercase / underscore identifier or keyword
  if ((c >= 'a' && c <= 'z') || c === '_') {
    const w = stream.match(/^[A-Za-z0-9_]+/)[0];
    if (KEYWORDS.has(w)) {
      if (w === 'data' || w === 'newtype') { state.decl = 'data'; state.typePos = true; }
      else if (w === 'type') { state.decl = 'alias'; state.typePos = true; }
      else if (TYPE_HEAD.has(w)) state.typePos = true;
      if (w === 'effect') state.effHead = true;
      if (w === 'import') state.imp = true;
      if (state.ascAt !== null && ASCRIPTION_END.has(w)) closeAscription(state);
      return 'keyword';
    }
    if (state.angle > 0) return 'effectVar';
    // a record field name (`{ x : Int }`) is followed by `:`; it is not a type variable
    if (state.typePos && !state.imp && !stream.match(/^\s*:(?!:)/, false)) return 'typeVar';
    return 'variableName';
  }

  // multi-char operators (longest-first)
  for (const op of OP3) if (stream.match(op)) return 'operator';
  for (const op of OP2) {
    if (stream.match(op)) {
      if (ASCRIPTION_END_OPS.has(op) && endsAscription(state)) closeAscription(state);
      return 'operator';
    }
  }

  // plain delimiters
  if (PUNCT_SET.indexOf(c) >= 0) {
    stream.next();
    if (c === '(' || c === '[') state.pdepth++;
    else if (c === ')' || c === ']') closeDelim(state);
    if (state.typePos) {
      if (c === '(' || c === '[') state.depth++;
      else if (c === ')' || c === ']') state.depth = Math.max(0, state.depth - 1);
    }
    if (c === ',' && state.typePos && state.ascAt !== null && state.pdepth === state.ascAt && state.angle === 0) closeAscription(state);
    return 'punctuation';
  }

  // braces: interpolation-brace tracking when inside a `\{ … }`, else record punct
  if (c === '{' || c === '}') {
    stream.next();
    const top = state.interpStack[state.interpStack.length - 1];
    if (!top) { if (c === '{') state.pdepth++; else closeDelim(state); }
    if (!top && c === '{') state.ctorNext = false;
    if (!top && state.typePos) state.depth = Math.max(0, state.depth + (c === '{' ? 1 : -1));
    if (top) {
      if (c === '{') { top.brace++; return 'punctuation'; }
      top.brace--;
      if (top.brace <= 0) { state.interpStack.pop(); state.strKind = top.kind; return 'interpolation'; }
      return 'punctuation';
    }
    return 'punctuation';
  }

  // single-char operators — three of them move the type/constructor position
  if (OP1_SET.indexOf(c) >= 0) {
    stream.next();
    if (ASCRIPTION_END_OPS.has(c) && endsAscription(state)) closeAscription(state);
    if (c === ':') { if (!state.typePos) state.ascAt = state.pdepth; state.typePos = true; }
    else if (c === '<' && state.typePos) {
      if (state.ascAt !== null && state.ascAt > 0 && state.pdepth === state.ascAt && state.angle === 0 &&
          !stream.match(/^\s*([A-Z>]|[a-z_][A-Za-z0-9_]*\s*[>|,])/, false)) closeAscription(state);
      else { state.angle++; state.depth++; }
    }
    else if (c === '>' && state.angle > 0) { state.angle--; state.depth = Math.max(0, state.depth - 1); }
    else if (c === '=' && state.angle > 0) { /* a row's `Label=domain` binding */ }
    else if (c === '=') {
      state.ascAt = null;
      if (state.decl === 'data') state.ctorNext = true;
      else if (state.decl !== 'alias') state.typePos = false;
    } else if (c === '|' && state.decl === 'data') state.ctorNext = true;
    return 'operator';
  }

  // anything else: consume one char, unstyled
  stream.next();
  return null;
}

function tokenChar(stream) {
  stream.next();                          // opening '
  while (!stream.eol()) {
    const d = stream.next();
    if (d === '\\') { if (!stream.eol()) stream.next(); continue; }
    if (d === "'") break;
  }
  return 'character';
}
