// highlight_medaka.mjs — static, dependency-free Medaka syntax highlighting for
// the RENDERED guide (playground/render_docs.mjs), driven by the SAME tokenizer
// the live playground editor uses (playground/medaka_tokenizer.js).
//
// The playground gets its highlighting from CodeMirror 6: medaka_lang.js wraps
// medaka_tokenizer.js in a `StreamLanguage`, and CM drives `token(stream, state)`
// line by line over its own `StringStream`. The guide is static HTML with no
// CodeMirror, so this module supplies the two missing halves:
//
//   1. `StringStream` — a ~40-line adapter over one line of text, implementing
//      EXACTLY the surface medaka_tokenizer.js actually calls (peek, next, eol,
//      match, eatSpace, skipToEnd, and the pos/start fields). Deliberately NOT
//      the full CM6 StringStream API: an unimplemented method that the tokenizer
//      never calls cannot rot, but a half-implemented one can.
//
//   2. `highlightMedaka(source)` — the driver, replacing CM's viewport loop. It
//      returns an HTML string for the inside of a `<code>` element: every token
//      wrapped in `<span class="tok-KIND">`, everything else plain-escaped.
//
// Two invariants this file exists to hold:
//
//   LOSSLESS — stripping every `<span …>` / `</span>` from the output yields
//   exactly `escapeHtml(source)`. Highlighting decorates; it never edits. This
//   is asserted for the whole real corpus by playground/guide_render_test.mjs
//   ("highlighting is lossless"), because a highlighter that silently drops a
//   character ships a code sample that does not compile.
//
//   STATE THREADS — `startState()` is called ONCE per block and the same mutable
//   state object is passed through every line of it, exactly as CodeMirror does.
//   `{- … -}` block comments and `"""…"""` strings span lines, and their scanner
//   state (`blockComment` depth, `strKind`, `interpStack`) lives in that object.
//   Resetting per line would mis-highlight every multi-line comment or string
//   from its second line on — silently, since the output is still well-formed.

import { startState, token } from './medaka_tokenizer.js';

// Same escaping the renderer uses for `data-source` and for un-highlighted
// bodies (render_docs.mjs `escapeHtml`), so the two agree character for
// character — the losslessness check compares them directly.
const escapeHtml = (s) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
   .replace(/"/g, '&quot;').replace(/'/g, '&#39;');

// The token-class strings medaka_tokenizer.js can return (its header census).
// `null` is also a legal return — "consumed, no highlight" — and is NOT here.
// An unexpected class would produce a `tok-` span with no CSS rule, i.e. silent
// under-highlighting, so it is refused loudly instead.
const TOKEN_CLASSES = new Set([
  'keyword', 'comment', 'string', 'character', 'number', 'typeName',
  'variableName', 'operator', 'punctuation', 'bool', 'escape', 'interpolation',
]);

// ── the StringStream adapter ────────────────────────────────────────────────
// One instance per LINE (CodeMirror's granularity — the tokenizer never sees a
// newline, and `eol()` is how it learns a line ended). Semantics follow CM6's
// StringStream: `match` with a string tests/consumes a literal prefix at `pos`;
// with a `^`-anchored RegExp it returns the match ARRAY (the tokenizer reads
// `[0]` off it) and consumes it unless `consume === false`.
export class StringStream {
  constructor(string) {
    this.string = string;
    this.pos = 0;
    this.start = 0;
  }

  eol() { return this.pos >= this.string.length; }

  peek() { return this.string.charAt(this.pos) || undefined; }

  next() {
    if (this.pos < this.string.length) return this.string.charAt(this.pos++);
    return undefined;
  }

  eatSpace() {
    const from = this.pos;
    while (/[\s ]/.test(this.string.charAt(this.pos))) this.pos++;
    return this.pos > from;
  }

  skipToEnd() { this.pos = this.string.length; }

  match(pattern, consume) {
    if (typeof pattern === 'string') {
      if (this.string.startsWith(pattern, this.pos)) {
        if (consume !== false) this.pos += pattern.length;
        return true;
      }
      return undefined;   // CM returns undefined, not false, on a string miss
    }
    const m = this.string.slice(this.pos).match(pattern);
    if (m && m.index > 0) return null;          // pattern was not `^`-anchored
    if (m && consume !== false) this.pos += m[0].length;
    return m;
  }
}

// ── the driver ──────────────────────────────────────────────────────────────
// Returns the HTML for the inside of a `<code>` element. Adjacent tokens of the
// same class are merged into one span (purely cosmetic — it keeps a line of
// prose inside a comment from becoming forty spans; it cannot affect the text).
export function highlightMedaka(source) {
  const state = startState();
  const lines = source.split('\n');
  const out = [];

  for (let i = 0; i < lines.length; i++) {
    if (i > 0) out.push('\n');
    const line = lines[i];
    const stream = new StringStream(line);

    let runClass = null;     // class of the run being accumulated (null = plain)
    let runText = '';
    const flush = () => {
      if (runText === '') return;
      const escaped = escapeHtml(runText);
      out.push(runClass === null ? escaped : `<span class="tok-${runClass}">${escaped}</span>`);
      runText = '';
    };

    while (!stream.eol()) {
      stream.start = stream.pos;
      const style = token(stream, state);
      // Zero-width token guard. medaka_tokenizer.js notes the case itself (see
      // its `tokenString` comment, "handled by caller"): a token function can
      // return having consumed nothing — e.g. a lone `"` inside a `"""` body,
      // where the closing-delimiter match fails and the literal run stops
      // immediately on the same quote. CodeMirror's own loop would throw; here
      // it would HANG the site build, so force one character of progress and
      // keep the style the tokenizer chose. Never remove this: the corpus is
      // author-written and an adversarial block must not wedge the build.
      if (stream.pos === stream.start) stream.pos++;

      const text = line.slice(stream.start, stream.pos);
      const cls = style === null || style === undefined ? null : style;
      if (cls !== null && !TOKEN_CLASSES.has(cls)) {
        throw new Error(
          `highlightMedaka: medaka_tokenizer.js returned unknown token class ` +
          `"${cls}". Add it to TOKEN_CLASSES here and give it a --tok-${cls} ` +
          `colour in render_docs.mjs's stylesheet, or the guide renders it unstyled.`);
      }
      if (cls === runClass) { runText += text; } else { flush(); runClass = cls; runText = text; }
    }
    flush();
  }

  return out.join('');
}
