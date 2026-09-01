// render_docs.mjs — the ONE Markdown→HTML render machine for the Medaka site.
//
// Renders every `.md` file in a doc-set directory into a standalone HTML page,
// using the committed `marked` bundle at vendor/marked/marked.js (no network, no
// npm install at render time).
//
// It is deliberately doc-set-agnostic: the input directory is an argument, so the
// same generator serves docs/guide today and the ~28-page stdlib reference later
// (#2384) without a second implementation.
//
//   node render_docs.mjs --src <dir> --out <dir> [options]
//
// Options
//   --src <dir>        input directory to enumerate `*.md` from   (required)
//   --out <dir>        output directory for the rendered pages    (required)
//   --exclude <a,b>    basenames NOT to render (still link-rewritable? no — an
//                      excluded page is not in the rendered set, so links to it
//                      fall through to the external rule below)
//   --title <text>     doc-set title, used in <title> and the page header
//   --repo-url <url>   base URL that repo-relative links which leave the doc set
//                      are rewritten against (default: the GitHub blob URL for
//                      `main`). Pass `--repo-url ''` to leave them untouched.
//   --repo-root <dir>  repo root used to resolve those out-of-set links
//                      (default: the parent of this script's directory)
//   --playground-url <href>  href to the playground's index.html from a
//                      rendered page, used for the "open in playground" links
//                      and the back-to-playground nav (default: '../index.html')
//
// Output contract (S-2 "open in playground" links and S-3 site wiring depend on
// this shape — see playground/NOTES.md):
//
//   <div class="codeblock" data-lang="medaka" data-fence="medaka"
//        data-source="<HTML-escaped raw fence body>">
//     <pre><code class="language-medaka">…escaped source…</code></pre>
//   </div>
//
// `data-source` carries the exact fence body, so a later pass can recover the
// program text without re-parsing the Markdown. `data-lang` is the normalized
// fence label (the token before any `:` or whitespace); `data-fence` is the raw
// info string.
//
// Fence labels are a CLOSED SET (KNOWN_FENCES below). An unknown label is a hard
// error, not a silent fall-through to unhighlighted prose: a doc that grows a new
// fence kind must teach this renderer about it.

import { readdirSync, readFileSync, mkdirSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join, resolve, dirname, basename, relative, posix } from 'node:path';
import { fileURLToPath } from 'node:url';

import { Marked } from './vendor/marked/marked.js';

const HERE = dirname(fileURLToPath(import.meta.url));

// ── fence labels ────────────────────────────────────────────────────────────
// Every label the doc corpus uses, with the CSS class the block gets. `medaka*`
// blocks are Medaka source in one of four dispositions; `toml` is a manifest.
const KNOWN_FENCES = {
  'medaka': 'medaka',            // a complete, checkable program
  'medaka-expect': 'output',     // the expected stdout of the block above it
  'medaka-project': 'medaka',    // a multi-file project listing
  'medaka-nocheck': 'medaka',    // a fragment, deliberately not standalone
  'toml': 'toml',                // a medaka.toml manifest
  '': 'plain',                   // an unlabelled fence (shell transcripts, trees)
};

// ── tiny helpers ────────────────────────────────────────────────────────────
const escapeHtml = (s) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
   .replace(/"/g, '&quot;').replace(/'/g, '&#39;');

// ── "open in playground" runnability partition ─────────────────────────────
// A fenced block is RUNNABLE in the browser playground iff ALL of:
//   1. its normalized fence label is exactly `medaka` (not `medaka-project` —
//      multi-file, the playground has one buffer; not `medaka-nocheck` — a
//      fragment never meant to stand alone; and not `medaka-expect`/`toml`/an
//      unlabelled fence, none of which are Medaka source to run at all), AND
//   2. its source contains no call to a host capability the playground's wasm
//      import object stubs out (playground/worker.js `capabilityStub`):
//      readFile, writeFile, readLine, readLines, getEnv, fileExists, args,
//      exit. Calling one of these does not fail to COMPILE — the wasm module
//      loads fine — it throws a `CapabilityError` at run time instead of
//      producing the documented output, which is worse than no link.
// Everything outside that partition gets a deliberate, visible "not runnable"
// note instead of a link — never a silently absent one. See playground/NOTES.md
// for the corpus counts this partition currently produces.
const UNSUPPORTED_CALL_RE =
  /\b(readFile|writeFile|readLine|readLines|getEnv|fileExists|args|exit)\b/;

function classifyRunnable(label, text) {
  if (label === 'medaka-project') {
    return { runnable: false, reason: 'multi-file project — the playground runs a single source buffer' };
  }
  if (label === 'medaka-nocheck') {
    return { runnable: false, reason: 'a fragment, not a standalone program' };
  }
  const m = text.match(UNSUPPORTED_CALL_RE);
  if (m) {
    return { runnable: false, reason: `uses \`${m[1]}\`, which the browser playground has no host support for` };
  }
  return { runnable: true };
}

// Mirrors playground/main.js `encodeProgram` byte-for-byte: UTF-8 bytes -> base64
// -> URL-safe (`+`->`-`, `/`->`_`, trailing `=` stripped). A pure string
// transform, so the build can compute it without any browser runtime.
function encodeProgram(src) {
  return Buffer.from(src, 'utf8').toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function runnableFooter(status, text, playgroundUrl) {
  if (status.runnable) {
    const href = `${playgroundUrl}#code=${encodeProgram(text)}`;
    return `<div class="codeblock-actions">`
      + `<a class="pg-run" href="${escapeHtml(href)}" rel="noopener">&#9654; Open in Playground</a>`
      + `</div>`;
  }
  return `<div class="codeblock-actions">`
    + `<span class="pg-not-runnable">Not runnable in the playground: ${escapeHtml(status.reason)}</span>`
    + `</div>`;
}

// Slug from heading TEXT, GitHub-flavoured: lowercase, drop everything that is
// not a word char / space / hyphen, spaces → hyphens. Collision-safe via a
// per-page seen-count suffix, so two identically-titled headings get stable,
// distinct anchors in document order.
function slugger() {
  const seen = new Map();
  return (text) => {
    const base = text.toLowerCase().trim()
      .replace(/<[^>]*>/g, '')
      .replace(/[^\w\s-]/g, '')
      .replace(/\s+/g, '-')
      .replace(/-+/g, '-')
      .replace(/^-|-$/g, '') || 'section';
    const n = seen.get(base) ?? 0;
    seen.set(base, n + 1);
    return n === 0 ? base : `${base}-${n}`;
  };
}

function parseArgs(argv) {
  const opts = {
    src: null, out: null, exclude: [], title: null,
    repoUrl: 'https://github.com/MedakaLang/medaka/blob/main',
    repoRoot: resolve(HERE, '..'),
    // Relative (or absolute) href to the playground's index.html, from a
    // rendered page. Default assumes the convention `build_site.sh` (S-3) is
    // expected to follow: this doc set's pages land one directory below the
    // playground root (e.g. site/guide/*.html next to site/index.html).
    playgroundUrl: '../index.html',
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => {
      if (i + 1 >= argv.length) throw new Error(`${a} needs a value`);
      return argv[++i];
    };
    switch (a) {
      case '--src': opts.src = resolve(next()); break;
      case '--out': opts.out = resolve(next()); break;
      case '--exclude': opts.exclude = next().split(',').map((s) => s.trim()).filter(Boolean); break;
      case '--title': opts.title = next(); break;
      case '--repo-url': opts.repoUrl = next().replace(/\/+$/, ''); break;
      case '--repo-root': opts.repoRoot = resolve(next()); break;
      case '--playground-url': opts.playgroundUrl = next(); break;
      default: throw new Error(`unknown argument: ${a}`);
    }
  }
  if (!opts.src || !opts.out) throw new Error('both --src and --out are required');
  return opts;
}

// ── the renderer ────────────────────────────────────────────────────────────
export function renderDocSet(opts) {
  const { src, out, exclude, repoUrl, repoRoot, playgroundUrl = '../index.html' } = opts;
  if (!existsSync(src)) throw new Error(`--src does not exist: ${src}`);

  // Enumerate the doc set from the DIRECTORY — never a hardcoded chapter list, so
  // a new chapter appears on the site by existing.
  const pages = readdirSync(src)
    .filter((f) => f.endsWith('.md'))
    .filter((f) => !exclude.includes(f))
    .sort();
  if (pages.length === 0) throw new Error(`no .md files to render in ${src}`);

  // The rendered set, by source basename — the link rewriter's authority for
  // "is this target one of my own pages?".
  const inSet = new Set(pages);
  const docTitle = opts.title ?? basename(src);

  const rendered = pages.map((file) =>
    renderPage({ src, file, inSet, repoUrl, repoRoot, docTitle, pages, playgroundUrl }));

  rmSync(out, { recursive: true, force: true });
  mkdirSync(out, { recursive: true });
  for (const page of rendered) writeFileSync(join(out, page.outFile), page.html);
  writeFileSync(join(out, 'guide.css'), STYLESHEET);

  return rendered;
}

function renderPage({ src, file, inSet, repoUrl, repoRoot, docTitle, pages, playgroundUrl }) {
  const markdown = readFileSync(join(src, file), 'utf8');
  const slug = slugger();
  const toc = [];
  const md = new Marked({ gfm: true, breaks: false });
  // Errors are COLLECTED, not thrown from inside a renderer hook: marked wraps a
  // throw from a hook with "Please report this to markedjs/marked", which points
  // a reader at the wrong project. We report them all ourselves after the parse.
  const errors = [];

  md.use({
    renderer: {
      heading({ tokens, depth }) {
        const text = this.parser.parseInline(tokens);
        const plain = this.parser.parseInline(tokens).replace(/<[^>]*>/g, '');
        const id = slug(plain);
        if (depth >= 2 && depth <= 3) toc.push({ id, depth, text: plain });
        return `<h${depth} id="${id}">`
          + `<a class="anchor" href="#${id}" aria-label="Permalink">#</a>${text}`
          + `</h${depth}>\n`;
      },

      code({ text, lang }) {
        const info = (lang ?? '').trim();
        // `medaka-nocheck: some prose about why` — the label is the token before
        // any `:` or whitespace; the rest is a human note.
        const label = info.split(/[\s:]/, 1)[0];
        if (!(label in KNOWN_FENCES)) {
          errors.push(
            `${file}: unknown fence label \`${label}\` (info string: \`${info}\`). ` +
            `Teach playground/render_docs.mjs about it — an unknown label must not ` +
            `silently render as unhighlighted prose.`);
        }
        const kind = KNOWN_FENCES[label] ?? 'unknown';
        const footer = kind === 'medaka'
          ? runnableFooter(classifyRunnable(label, text), text, playgroundUrl)
          : '';
        return `<div class="codeblock kind-${kind}"`
          + ` data-lang="${escapeHtml(label || 'plain')}"`
          + ` data-fence="${escapeHtml(info)}"`
          + ` data-source="${escapeHtml(text)}">`
          + `<pre><code class="language-${escapeHtml(label || 'plain')}">`
          + `${escapeHtml(text)}</code></pre>${footer}</div>\n`;
      },

      link({ href, title, tokens }) {
        const body = this.parser.parseInline(tokens);
        const rewritten = rewriteHref(href, { file, src, inSet, repoUrl, repoRoot, errors });
        const t = title ? ` title="${escapeHtml(title)}"` : '';
        const ext = /^https?:/.test(rewritten) ? ' rel="noopener"' : '';
        return `<a href="${escapeHtml(rewritten)}"${t}${ext}>${body}</a>`;
      },
    },
  });

  const body = md.parse(markdown);
  if (errors.length > 0) throw new Error(errors.join('\n  '));
  const outFile = file.replace(/\.md$/, '.html');
  const pageTitle = (markdown.match(/^#\s+(.+)$/m)?.[1] ?? basename(file, '.md')).trim();

  return {
    srcFile: file,
    outFile,
    title: pageTitle,
    toc,
    html: pageShell({ pageTitle, docTitle, body, toc, outFile, pages, playgroundUrl }),
  };
}

// Rewrite one href.
//   - in-set `.md` (optionally with a #fragment)  → the sibling `.html` page
//   - out-of-set repo-relative path               → repoUrl + the repo-relative path
//   - anything else (absolute URL, bare #anchor)  → untouched
//
// The SOURCE `.md` files are never edited — `make docs-links` gates those, and the
// rewrite lives entirely in the rendered output.
function rewriteHref(href, { file, src, inSet, repoUrl, repoRoot, errors }) {
  if (!href || /^[a-z][a-z0-9+.-]*:/i.test(href) || href.startsWith('#') || href.startsWith('//')) {
    return href;
  }
  const hash = href.indexOf('#');
  const path = hash === -1 ? href : href.slice(0, hash);
  const frag = hash === -1 ? '' : href.slice(hash);
  if (!path) return href;

  // A bare sibling name that is one of our own rendered pages.
  if (!path.includes('/') && path.endsWith('.md')) {
    if (!inSet.has(path)) {
      // A cross-chapter link naming a sibling that is not in the rendered set is
      // a BROKEN link, not an out-of-set one. Falling through to the repository
      // rewrite below would quietly turn it into a plausible-looking GitHub URL
      // that 404s, so refuse instead.
      errors.push(
        `${file}: cross-chapter link \`${href}\` names \`${path}\`, which is not ` +
        `in the rendered doc set (missing, or excluded from rendering).`);
      return href;
    }
    return path.replace(/\.md$/, '.html') + frag;
  }

  // Everything else relative points OUT of the doc set (../spec/SYNTAX.md,
  // ../../stdlib/core.mdk, …). Those pages are not rendered here, so a `.html`
  // rewrite would manufacture a 404; send them at the repository instead.
  if (!repoUrl) return href;
  const abs = resolve(dirname(join(src, file)), path);
  const rel = relative(repoRoot, abs);
  if (rel.startsWith('..')) return href;   // escapes the repo — leave it alone
  return `${repoUrl}/${rel.split(/[\\/]/).join(posix.sep)}${frag}`;
}

// ── page shell ──────────────────────────────────────────────────────────────
function pageShell({ pageTitle, docTitle, body, toc, outFile, pages, playgroundUrl }) {
  const tocHtml = toc.length === 0 ? '' :
    `<nav class="toc" aria-label="On this page">\n<h2>On this page</h2>\n<ul>\n`
    + toc.map((h) => `<li class="toc-h${h.depth}"><a href="#${h.id}">${h.text}</a></li>`).join('\n')
    + `\n</ul>\n</nav>\n`;

  const chapters = pages.map((p) => {
    const href = p.replace(/\.md$/, '.html');
    const here = href === outFile ? ' class="here" aria-current="page"' : '';
    return `<li><a href="${href}"${here}>${escapeHtml(basename(p, '.md'))}</a></li>`;
  }).join('\n');

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(pageTitle)} — ${escapeHtml(docTitle)}</title>
<link rel="stylesheet" href="guide.css">
</head>
<body>
<header class="site-nav">
<a class="site-nav-back" href="${escapeHtml(playgroundUrl)}">&larr; Playground</a>
<span class="site-nav-title">${escapeHtml(docTitle)}</span>
</header>
<div class="layout">
<nav class="chapters" aria-label="Chapters">
<h2>${escapeHtml(docTitle)}</h2>
<ul>
${chapters}
</ul>
</nav>
<main>
${tocHtml}<article>
${body}</article>
</main>
</div>
</body>
</html>
`;
}

// Design tokens copied VERBATIM from playground/index.html's `:root` (~line 39)
// — same dark chrome, same fixed (non-media-query) theme; the playground itself
// has no light-mode arm, so the guide doesn't invent one either.
const STYLESHEET = `/* Generated by playground/render_docs.mjs — do not edit by hand. */
:root {
  --bg: #0b0e14;
  --panel: #11151d;
  --panel-2: #161b24;
  --line: #232a36;
  --ink: #d6dbe3;
  --muted: #8b93a1;
  --faint: #5c6470;
  --gold: #e2b96f;
  --gold-bright: #f0cd8e;
  --ok: #6fcf97;
  --err: #f47067;
  --code-bg: #0d1117;
  --mono: "SF Mono", "Cascadia Code", "Fira Code", Menlo, Consolas, monospace;
  --ui: system-ui, -apple-system, "Segoe UI", sans-serif;
}
*, *::before, *::after { box-sizing: border-box; }
html { background: #07090d; }
body { margin:0; color:var(--ink); background:var(--bg); font:16px/1.65 var(--ui); }
a { color:var(--gold); text-decoration:none; }
a:hover { color:var(--gold-bright); text-decoration:underline; }

.site-nav { display:flex; align-items:center; gap:1rem; padding:.85rem 1.25rem;
       background:var(--panel); border-bottom:1px solid var(--line); position:sticky; top:0;
       z-index:10; }
.site-nav-back { color:var(--muted); font:500 .85rem var(--ui); }
.site-nav-back:hover { color:var(--ink); }
.site-nav-title { color:var(--faint); font-size:.8rem; text-transform:uppercase;
       letter-spacing:.06em; }

.layout { display:flex; gap:2.5rem; max-width:1180px; margin:0 auto; padding:2rem 1.25rem; }
.chapters { flex:0 0 15rem; font-size:.88rem; }
.chapters h2, .toc h2 { font-size:.75rem; text-transform:uppercase; letter-spacing:.06em;
       color:var(--faint); margin:0 0 .6rem; }
.chapters ul, .toc ul { list-style:none; margin:0; padding:0; }
.chapters li { margin:.35rem 0; }
.chapters a { color:var(--muted); }
.chapters a:hover { color:var(--ink); }
.chapters a.here { color:var(--gold); font-weight:600; }
main { flex:1 1 auto; min-width:0; max-width:42rem; }

h1,h2,h3 { line-height:1.3; margin:2rem 0 .75rem; color:var(--ink); }
h1 { margin-top:0; font-size:1.7rem; }
h2 { font-size:1.3rem; border-bottom:1px solid var(--line); padding-bottom:.3rem; }
h3 { font-size:1.05rem; }
h1 .anchor, h2 .anchor, h3 .anchor { float:left; margin-left:-1.15em; padding-right:.3em;
       color:var(--faint); opacity:0; text-decoration:none; }
h1:hover .anchor, h2:hover .anchor, h3:hover .anchor { opacity:1; }
p, li { color:var(--ink); }

.toc { border:1px solid var(--line); background:var(--panel); border-radius:8px;
       padding:.85rem 1.1rem; margin-bottom:2rem; font-size:.88rem; }
.toc li { margin:.25rem 0; }
.toc a { color:var(--muted); }
.toc a:hover { color:var(--gold); }
.toc .toc-h3 { padding-left:1rem; }

.codeblock { margin:1.1rem 0; border:1px solid var(--line); border-radius:8px;
       overflow:hidden; background:var(--code-bg); }
.codeblock pre { margin:0; padding:.9rem 1.1rem; overflow-x:auto; background:var(--code-bg); }
.codeblock.kind-output pre { background:var(--panel-2); }
.codeblock.kind-output { border-color:var(--line); }
code, pre { font-family:var(--mono); font-size:.88em; }
:not(pre) > code { background:var(--panel-2); color:var(--ink); padding:.15em .4em;
       border-radius:4px; }

.codeblock-actions { border-top:1px solid var(--line); background:var(--panel);
       padding:.5rem .9rem; font:500 .8rem var(--ui); }
.pg-run { color:var(--gold); }
.pg-run:hover { color:var(--gold-bright); }
.pg-not-runnable { color:var(--faint); font-style:italic; }

table { border-collapse:collapse; }
th, td { border:1px solid var(--line); padding:.4rem .7rem; text-align:left; }
blockquote { margin:1rem 0; padding:.15rem 1.1rem; border-left:3px solid var(--gold);
       color:var(--muted); }
@media (max-width:820px) {
  .layout { flex-direction:column; }
  .chapters { flex:none; }
  main { max-width:none; }
}
`;

// ── CLI ─────────────────────────────────────────────────────────────────────
if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  try {
    const opts = parseArgs(process.argv.slice(2));
    const pages = renderDocSet(opts);
    for (const p of pages) console.log(`  ${p.srcFile} -> ${p.outFile}  (${p.toc.length} TOC entries)`);
    console.log(`rendered ${pages.length} page(s) into ${opts.out}`);
  } catch (err) {
    console.error(`render_docs: ${err.message}`);
    process.exit(1);
  }
}
