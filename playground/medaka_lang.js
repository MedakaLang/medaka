// medaka_lang.js — wires the hand-written Medaka tokenizer (medaka_tokenizer.js)
// into a CodeMirror 6 StreamLanguage, and defines a dark HighlightStyle matching
// the playground palette (bg #0e1320 / text #d6dde8, accents #5fd38f / #8ab4ff).
//
// Imports CodeMirror through the `codemirror` bare specifier resolved by the
// import-map in index.html to the vendored single-ESM bundle
// (vendor/codemirror/codemirror.js) — no bundler at serve time.

import {
  StreamLanguage, LanguageSupport, HighlightStyle, syntaxHighlighting, tags,
} from 'codemirror';
import { startState, copyState, token } from './medaka_tokenizer.js';

// Map the tokenizer's class-name strings to Lezer highlight tags.
const tokenTable = {
  keyword: tags.keyword,
  comment: tags.comment,
  string: tags.string,
  character: tags.character,
  number: tags.number,
  typeName: tags.typeName,
  constructor: tags.className,
  variableName: tags.variableName,
  operator: tags.operator,
  punctuation: tags.punctuation,
  bool: tags.bool,
  escape: tags.escape,
  interpolation: tags.special(tags.string),
};

const medakaStream = StreamLanguage.define({
  name: 'medaka',
  startState,
  copyState,
  token,
  languageData: {
    commentTokens: { line: '--', block: { open: '{-', close: '-}' } },
    closeBrackets: { brackets: ['(', '[', '{', '"', "'"] },
  },
  tokenTable,
});

// Dark highlight style — cohesive with the two named UI accents.
export const medakaHighlightStyle = HighlightStyle.define([
  { tag: tags.keyword, color: '#5fd38f' },
  { tag: tags.comment, color: '#6e7781', fontStyle: 'italic' },
  { tag: tags.string, color: '#f0c674' },
  { tag: tags.character, color: '#f0c674' },
  { tag: tags.special(tags.string), color: '#ffb86c' },
  { tag: tags.escape, color: '#ffb86c' },
  { tag: tags.number, color: '#79c0ff' },
  { tag: tags.bool, color: '#8ab4ff' },
  { tag: tags.typeName, color: '#8ab4ff' },
  { tag: tags.className, color: '#d29cf5' },
  { tag: tags.variableName, color: '#d6dde8' },
  { tag: tags.operator, color: '#a9b1ba' },
  { tag: tags.punctuation, color: '#8b949e' },
]);

export function medaka() {
  return new LanguageSupport(medakaStream, [syntaxHighlighting(medakaHighlightStyle)]);
}
