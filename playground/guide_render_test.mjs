// guide_render_test.mjs — assertion gate for the docs render machine
// (playground/render_docs.mjs).
//
// Standalone and deterministic: it renders a doc set into a scratch directory and
// asserts the properties the site depends on. No network, no built ./medaka — it
// grades the renderer, not the compiler.
//
//   node playground/guide_render_test.mjs               # grades docs/guide
//   node playground/guide_render_test.mjs --src <dir>   # grades any doc set
//
// Exit 0 = all assertions passed. Exit 1 = at least one failed (each printed).
//
// What it proves
//   1. every non-excluded source `.md` produced exactly one `.html` page
//   2. NO relative `.md` href survives into the rendered HTML — the 44 cross-
//      chapter links are rewritten to their `.html` targets
//   3. every internal `href="X.html"` names a page that was actually emitted
//   4. every heading carries a stable, unique `id`, and every TOC entry points at
//      one that exists on that page
//   5. every page is non-empty (a blanked chapter is a failure, not a pass)
//   6. every fenced block became a `.codeblock` with a KNOWN `data-lang` and a
//      recoverable non-empty `data-source` — one per fence in the source
//   7. an unknown fence label is REFUSED, not silently rendered as prose

import { readdirSync, readFileSync, mkdtempSync, rmSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, resolve, dirname, basename } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

import { renderDocSet } from './render_docs.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..');

const KNOWN_LANGS = new Set(['medaka', 'medaka-expect', 'medaka-project', 'medaka-nocheck', 'toml', 'plain']);

let failures = 0;
const check = (ok, what) => {
  if (!ok) { failures++; console.error(`FAIL  ${what}`); }
};
const note = (what) => console.log(`ok    ${what}`);

// ── arguments ───────────────────────────────────────────────────────────────
let src = join(REPO_ROOT, 'docs', 'guide');
const exclude = ['OUTLINE.md'];
for (let i = 2; i < process.argv.length; i++) {
  if (process.argv[i] === '--src') src = resolve(process.argv[++i]);
  else { console.error(`unknown argument: ${process.argv[i]}`); process.exit(2); }
}

const scratch = mkdtempSync(join(tmpdir(), 'guide-render-'));
try {
  // ── 1. render ─────────────────────────────────────────────────────────────
  const out = join(scratch, 'out');
  let pages;
  try {
    pages = renderDocSet({
      src, out, exclude, title: 'The Medaka Guide',
      repoUrl: 'https://github.com/MedakaLang/medaka/blob/main',
      // Derived from --src rather than pinned to this checkout, so pointing the
      // gate at a scratch COPY of a doc set (the red-before-green demonstration)
      // still resolves that copy's out-of-set `../…` links the same way.
      repoRoot: resolve(src, '..', '..'),
    });
  } catch (err) {
    console.error(`FAIL  render threw: ${err.message}`);
    process.exit(1);
  }

  const sources = readdirSync(src).filter((f) => f.endsWith('.md') && !exclude.includes(f)).sort();
  check(pages.length === sources.length,
    `page count ${pages.length} == source count ${sources.length}`);
  const emitted = new Set(readdirSync(out).filter((f) => f.endsWith('.html')));
  for (const s of sources) {
    check(emitted.has(s.replace(/\.md$/, '.html')), `emitted a page for ${s}`);
  }
  note(`rendered ${pages.length} page(s) from ${basename(src)}/`);

  // ── 2..6. per-page properties ─────────────────────────────────────────────
  let totalLinksRewritten = 0;
  let totalCodeblocks = 0;

  for (const page of pages) {
    const html = readFileSync(join(out, page.outFile), 'utf8');
    const where = page.outFile;

    // 2. no relative .md href survived. (Absolute repository URLs legitimately
    // end in .md — those are OUT of the doc set and are not rewrites.)
    const relMd = [...html.matchAll(/href="([^"]*\.md[^"]*)"/g)]
      .map((m) => m[1]).filter((h) => !/^[a-z][a-z0-9+.-]*:/i.test(h));
    check(relMd.length === 0, `${where}: no relative .md href survives (found ${relMd.join(', ')})`);

    // 3. every internal .html href names an emitted page.
    for (const m of html.matchAll(/href="([^":#]+\.html)(#[^"]*)?"/g)) {
      check(emitted.has(m[1]), `${where}: internal link ${m[1]} names an emitted page`);
      totalLinksRewritten++;
    }

    // 4. heading ids unique; every TOC target exists.
    const ids = [...html.matchAll(/<h[1-6] id="([^"]+)"/g)].map((m) => m[1]);
    check(new Set(ids).size === ids.length, `${where}: heading ids are unique`);
    check(ids.length > 0, `${where}: has at least one anchored heading`);
    check(page.toc.length > 0, `${where}: has a non-empty TOC`);
    const idSet = new Set(ids);
    for (const entry of page.toc) {
      check(idSet.has(entry.id), `${where}: TOC entry #${entry.id} resolves to a heading`);
    }
    check(html.includes('class="toc"'), `${where}: TOC is present in the emitted HTML`);

    // 5. non-empty page.
    const article = html.match(/<article>([\s\S]*)<\/article>/)?.[1] ?? '';
    const text = article.replace(/<[^>]*>/g, '').replace(/\s+/g, ' ').trim();
    check(text.length > 400, `${where}: article body is substantive (${text.length} chars)`);

    // 6. one .codeblock per source fence, each with a known lang and a
    //    recoverable source. Counted over LABELLED fence openers, which are
    //    unambiguous: an opener carries an info string, a closer never does.
    //    (A leading `> ` allows for fences nested in a blockquote; unlabelled
    //    fences and 4-space-indented blocks also become codeblocks, hence `>=`
    //    on the total.)
    const md = readFileSync(join(src, page.srcFile), 'utf8');
    const labelledOpens = (md.match(/^\s*(> )?```[A-Za-z]/gm) ?? []).length;
    const blocks = [...html.matchAll(/<div class="codeblock kind-([a-z]+)" data-lang="([^"]*)" data-fence="([^"]*)" data-source="([\s\S]*?)"><pre>/g)];
    const labelledBlocks = blocks.filter((b) => b[3] !== '').length;
    check(labelledBlocks === labelledOpens,
      `${where}: ${labelledBlocks} labelled codeblocks == ${labelledOpens} labelled source fences`);
    check(blocks.length >= labelledOpens,
      `${where}: ${blocks.length} total codeblocks >= ${labelledOpens} labelled fences`);
    for (const b of blocks) {
      check(KNOWN_LANGS.has(b[2]), `${where}: codeblock data-lang "${b[2]}" is a known label`);
      check(b[4].length > 0, `${where}: codeblock data-source is non-empty`);
    }
    totalCodeblocks += blocks.length;
  }
  note(`${totalLinksRewritten} internal .html link(s) all resolve to emitted pages`);
  note(`${totalCodeblocks} code block(s) all carry a known data-lang and a recoverable data-source`);

  // ── 7. an unknown fence label must be REFUSED ─────────────────────────────
  const bad = join(scratch, 'badfence');
  mkdirSync(bad, { recursive: true });
  writeFileSync(join(bad, 'a.md'), '# A\n\n## S\n\n```rust\nfn main() {}\n```\n');
  let refused = false;
  try {
    renderDocSet({ src: bad, out: join(scratch, 'badout'), exclude: [], title: 't', repoUrl: '', repoRoot: REPO_ROOT });
  } catch (err) {
    refused = /unknown fence label/.test(err.message);
  }
  check(refused, 'an unknown fence label is refused rather than rendered as prose');
  if (refused) note('unknown fence label refused');
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

if (failures > 0) {
  console.error(`\nguide_render_test: ${failures} assertion(s) FAILED`);
  process.exit(1);
}
console.log('\nguide_render_test: all assertions passed');
