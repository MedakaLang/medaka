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
//   8. every `kind-medaka` codeblock carries a footer with EXACTLY ONE of the
//      `pg-run` / `pg-not-runnable` classes, and the split the render produced
//      equals `classifyRunnable` recomputed independently over each block's
//      recovered `data-source` (§7.4's ▶-button promise, asserted at PR time)
//   9. every internal `href="X.html#frag"` resolves to a real heading id on the
//      TARGET page X — not merely to an emitted page, and not merely to the
//      citing page's own TOC (check 4)
//  10. syntax highlighting is LOSSLESS — stripping the `<span class="tok-...">`
//      wrappers from any rendered `<code>` body reproduces that block's
//      `data-source` exactly, and only `kind-medaka` bodies carry spans at all

import { readdirSync, readFileSync, mkdtempSync, rmSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, resolve, dirname, basename } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

import { renderDocSet, classifyRunnable, decodeEntities, shippedModules } from './render_docs.mjs';

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
// Optional, and NOT what CI passes (test/diff_compiler_guide_render.sh runs this
// gate with --src only, so it needs no built playground/dist). It is threaded
// anyway so that check 8 grades the SAME rule the render applied under either
// invocation: whatever `shipped` the render saw, the recomputation sees too —
// including `null`, which skips conjunct 4 on both sides rather than on one.
let distDir = null;
const exclude = ['OUTLINE.md'];
for (let i = 2; i < process.argv.length; i++) {
  if (process.argv[i] === '--src') src = resolve(process.argv[++i]);
  else if (process.argv[i] === '--dist') distDir = resolve(process.argv[++i]);
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
      distDir,
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
  let totalRunnable = 0;
  let totalNotRunnable = 0;
  // Check 9 needs EVERY page's heading ids before it can grade ANY page's
  // outbound fragments, so the two are collected here and validated in a second
  // pass below — the same shape as `emitted`, one entry per rendered page.
  const idsByPage = new Map();
  const fragmentRefs = [];

  // The shipped-module set the render just used. Recomputing `classifyRunnable`
  // against a DIFFERENTLY-derived set would grade the render against a rule it
  // was never given, so it is derived once, from the same input, by the same
  // exported helper the renderer itself calls.
  const shipped = shippedModules(distDir);
  let totalHighlighted = 0;
  let spanCount = 0;

  // One `.codeblock` div, opening attributes through the closing `</div>`. The
  // trailing group is the FOOTER: empty for every non-`medaka` kind, and the
  // `codeblock-actions` div for `kind-medaka`. The non-greedy tail stops at the
  // first `</div>\n`, which is the block's own closer — the footer's inner
  // `</div>` is followed by `</div>`, not by a newline.
  // Group 5 is the `<code>` BODY, which since F-guide-syntax-highlight is no
  // longer plain-escaped text but token `<span>`s (playground/highlight_medaka.mjs).
  // Check 10 grades it against group 4 (`data-source`); the footer is now group 6.
  const BLOCK_RE = /<div class="codeblock kind-([a-z]+)" data-lang="([^"]*)" data-fence="([^"]*)" data-source="([\s\S]*?)"><pre><code[^>]*>([\s\S]*?)<\/code><\/pre>([\s\S]*?)<\/div>\n/g;

  for (const page of pages) {
    const html = readFileSync(join(out, page.outFile), 'utf8');
    const where = page.outFile;

    // 2. no relative .md href survived. (Absolute repository URLs legitimately
    // end in .md — those are OUT of the doc set and are not rewrites.)
    const relMd = [...html.matchAll(/href="([^"]*\.md[^"]*)"/g)]
      .map((m) => m[1]).filter((h) => !/^[a-z][a-z0-9+.-]*:/i.test(h));
    check(relMd.length === 0, `${where}: no relative .md href survives (found ${relMd.join(', ')})`);

    // 3. every SIBLING .html href (no leading "../" — those deliberately leave the
    //    doc set, e.g. S-2's "open in playground" / back-to-playground links)
    //    names a page that was actually emitted.
    for (const m of html.matchAll(/href="([^":#]+\.html)(#[^"]*)?"/g)) {
      if (m[1].startsWith('../')) continue;
      check(emitted.has(m[1]), `${where}: internal link ${m[1]} names an emitted page`);
      if (m[2]) fragmentRefs.push({ from: where, target: m[1], frag: m[2].slice(1) });
      totalLinksRewritten++;
    }
    // Same-page fragments (`href="#id"`) are graded by the same map, against
    // this page's own id set — check 4 only covers the generated TOC, so an
    // author's hand-written `[see below](#typo)` was invisible until now.
    for (const m of html.matchAll(/href="#([^"]+)"/g)) {
      fragmentRefs.push({ from: where, target: where, frag: m[1] });
    }

    // 4. heading ids unique; every TOC target exists.
    const ids = [...html.matchAll(/<h[1-6] id="([^"]+)"/g)].map((m) => m[1]);
    check(new Set(ids).size === ids.length, `${where}: heading ids are unique`);
    check(ids.length > 0, `${where}: has at least one anchored heading`);
    check(page.toc.length > 0, `${where}: has a non-empty TOC`);
    const idSet = new Set(ids);
    idsByPage.set(where, idSet);
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
    const blocks = [...html.matchAll(BLOCK_RE)];
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

    // 8. §7.4's promise: every runnable block's u25b6 button leads to a program
    //    that actually runs, and every non-runnable one says so VISIBLY. Two
    //    conjuncts, both of which a regression could break silently:
    //      (a) STRUCTURAL — a `kind-medaka` block carries a footer with exactly
    //          one of `pg-run` / `pg-not-runnable`. Never both (incoherent),
    //          never neither (a dropped footer is a silently absent button,
    //          which NOTES.md calls out as worse than a wrong one).
    //      (b) CLASSIFICATION — the split the render produced equals
    //          `classifyRunnable` recomputed here, independently, over each
    //          block's recovered `data-source`. This mirrors the MISCLASSIFIED
    //          check in playground/guide_wasm_differential.mjs, which is
    //          deliberately NOT a PR gate (it needs a built playground.wasm);
    //          without it here, a change that attached a u25b6 to every block, or
    //          to none, is green on every required check.
    //    Scoped to `kind-medaka` because `runnableFooter` is only ever called for
    //    that kind (render_docs.mjs `code()`); `kind-output`/`toml`/`plain`
    //    blocks correctly have no footer at all.
    for (const b of blocks) {
      const [, kind, lang, , rawSource, , footer] = b;
      if (kind !== 'medaka') {
        check(footer === '', `${where}: kind-${kind} codeblock carries no runnability footer`);
        continue;
      }
      const hasRun = /class="pg-run"/.test(footer);
      const hasNot = /class="pg-not-runnable"/.test(footer);
      check(hasRun !== hasNot,
        `${where}: kind-medaka codeblock (${lang}) footer carries exactly one of ` +
        `pg-run / pg-not-runnable (pg-run=${hasRun}, pg-not-runnable=${hasNot})`);
      // `data-source` is `escapeHtml(text)`; `decodeEntities` is its inverse, and
      // is the renderer's own, so the two cannot drift apart.
      const source = decodeEntities(rawSource);
      const want = classifyRunnable(lang, source, shipped);
      check(hasRun === want.runnable,
        `${where}: kind-medaka codeblock (${lang}) rendered ` +
        `${hasRun ? 'pg-run' : 'pg-not-runnable'} but the rule says ` +
        `${want.runnable ? 'runnable' : `not runnable (${want.reason})`}`);
      if (want.runnable) totalRunnable++; else totalNotRunnable++;
    }

    // 10. HIGHLIGHTING IS LOSSLESS. `kind-medaka` bodies are token-wrapped by
    //     playground/highlight_medaka.mjs; every other kind stays plain. Either
    //     way, deleting the span tags from the rendered body must reproduce the
    //     block's `data-source` — which is `escapeHtml(text)` — CHARACTER FOR
    //     CHARACTER. A highlighter that drops, reorders, or double-escapes even
    //     one character ships a code sample that no longer compiles, and does it
    //     invisibly: the page still renders, the u25b6 button still works (it
    //     reads `data-source`, not the body), and only a reader copying the
    //     visible text finds out. Whole-body equality, deliberately not a spot
    //     check and deliberately not scoped to `kind-medaka`.
    for (const b of blocks) {
      const [, kind, lang, , rawSource, codeBody] = b;
      const stripped = codeBody.replace(/<span class="tok-[A-Za-z]+">/g, '').replace(/<\/span>/g, '');
      check(stripped === rawSource,
        `${where}: kind-${kind} codeblock (${lang}) highlighting is lossless ` +
        `(stripped body ${stripped === rawSource ? 'matches' : 'DIFFERS from'} data-source)`);
      if (kind === 'medaka') {
        totalHighlighted++;
        spanCount += (codeBody.match(/<span class="tok-/g) ?? []).length;
      } else {
        // Non-source kinds must not be highlighted at all: `medaka-expect` is
        // documented stdout, `toml`/`plain` are not Medaka source. A stray span
        // here means the kind partition in `code()` drifted.
        check(!codeBody.includes('<span'),
          `${where}: kind-${kind} codeblock (${lang}) body carries no token spans`);
      }
    }
  }
  note(`${totalLinksRewritten} internal .html link(s) all resolve to emitted pages`);
  note(`${totalCodeblocks} code block(s) all carry a known data-lang and a recoverable data-source`);
  note(`${totalHighlighted} kind-medaka block(s) carry ${spanCount} token span(s); `
    + `every code body strips back to its data-source exactly`);
  note(`${totalRunnable} runnable / ${totalNotRunnable} not-runnable medaka block(s), `
    + `each with exactly one footer class matching the recomputed rule`
    + `${shipped === null ? ' (no --dist: the unshipped-import conjunct is skipped on BOTH sides)' : ''}`);

  // ── 9. cross-page fragment resolution ─────────────────────────────────────
  // Check 3 proves `X.html` names an emitted page; check 4 proves this page's own
  // TOC resolves. Neither looks at a link's `#fragment` against the TARGET page's
  // headings, so `04-data-modeling.md#no-such-anchor` rendered, resolved, and
  // passed clean — a dead in-set anchor that ships as a link to nowhere. This is
  // the second pass the id map was collected for.
  let deadFragments = 0;
  for (const ref of fragmentRefs) {
    const targetIds = idsByPage.get(ref.target);
    if (!targetIds) continue;   // already reported by check 3 as an unemitted page
    const ok = targetIds.has(ref.frag);
    if (!ok) deadFragments++;
    check(ok, `${ref.from}: link to ${ref.target}#${ref.frag} resolves to a heading on ${ref.target}`);
  }
  if (deadFragments === 0) {
    note(`${fragmentRefs.length} fragment link(s) all resolve to a heading on their target page`);
  }

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
