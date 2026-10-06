'use strict';
// Reads a Cloudflare Pages `_headers` file and answers "which headers does this
// path receive".  Semantics follow
// https://developers.cloudflare.com/pages/configuration/headers/ : every rule whose
// URL pattern matches contributes its headers (rules stack); `*` is a greedy splat
// and `:name` a placeholder matching one path segment.  Used by server.js so the
// local server and the e2e harness see the same headers a deploy would send.

const fs = require('fs');

function parseHeaders(text) {
  const rules = [];
  let cur = null;
  for (const raw of text.split('\n')) {
    if (/^\s*(#|$)/.test(raw)) continue;
    if (/^\s/.test(raw)) {
      const i = raw.indexOf(':');
      if (cur && i > 0) cur.headers.push([raw.slice(0, i).trim(), raw.slice(i + 1).trim()]);
    } else {
      cur = { pattern: raw.trim(), headers: [] };
      rules.push(cur);
    }
  }
  return rules;
}

function patternRegex(pattern) {
  const esc = (s) => s.replace(/[.+?^${}()|[\]\\]/g, '\\$&');
  const src = pattern.split('*').map((part) =>
    part.split(/(:[A-Za-z_][A-Za-z0-9_]*)/).map((seg, i) => (i % 2 ? '[^/]+' : esc(seg))).join('')
  ).join('.*');
  return new RegExp('^' + src + '$');
}

// Returns [[name, value], ...] in rule order.
function headersFor(rules, urlPath) {
  const out = [];
  for (const r of rules) if (patternRegex(r.pattern).test(urlPath)) out.push(...r.headers);
  return out;
}

function loadRules(file) {
  return fs.existsSync(file) ? parseHeaders(fs.readFileSync(file, 'utf8')) : [];
}

module.exports = { parseHeaders, headersFor, loadRules };
