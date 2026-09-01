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
      default: throw new Error(`unknown argument: ${a}`);
    }
  }
  if (!opts.src || !opts.out) throw new Error('both --src and --out are required');
  return opts;
}

// ── the renderer ────────────────────────────────────────────────────────────
export function renderDocSet(opts) {
  const { src, out, exclude, repoUrl, repoRoot } = opts;
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
    renderPage({ src, file, inSet, repoUrl, repoRoot, docTitle, pages }));

  rmSync(out, { recursive: true, force: true });
  mkdirSync(out, { recursive: true });
  for (const page of rendered) writeFileSync(join(out, page.outFile), page.html);
  writeFileSync(join(out, 'guide.css'), STYLESHEET);

  return rendered;
}

function renderPage({ src, file, inSet, repoUrl, repoRoot, docTitle, pages }) {
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
        return `<div class="codeblock kind-${kind}"`
          + ` data-lang="${escapeHtml(label || 'plain')}"`
          + ` data-fence="${escapeHtml(info)}"`
          + ` data-source="${escapeHtml(text)}">`
          + `<pre><code class="language-${escapeHtml(label || 'plain')}">`
          + `${escapeHtml(text)}</code></pre></div>\n`;
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
    html: pageShell({ pageTitle, docTitle, body, toc, outFile, pages }),
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
function pageShell({ pageTitle, docTitle, body, toc, outFile, pages }) {
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

const STYLESHEET = `/* Generated by playground/render_docs.mjs — do not edit by hand. */
:root { --fg:#1b1b1f; --bg:#fff; --muted:#5a5a66; --rule:#e2e2ea; --accent:#0a6cbe;
        --code-bg:#f6f7f9; --out-bg:#f1f6f1; }
@media (prefers-color-scheme: dark) {
  :root { --fg:#e6e6ea; --bg:#16161a; --muted:#a0a0ad; --rule:#2c2c34; --accent:#6fb4f0;
          --code-bg:#1e1e24; --out-bg:#1a221c; }
}
* { box-sizing: border-box; }
body { margin:0; color:var(--fg); background:var(--bg); font:16px/1.65 -apple-system,
       BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
.layout { display:flex; gap:2rem; max-width:1180px; margin:0 auto; padding:2rem 1.25rem; }
.chapters { flex:0 0 15rem; font-size:.9rem; }
.chapters h2 { font-size:.8rem; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); }
.chapters ul, .toc ul { list-style:none; margin:0; padding:0; }
.chapters li { margin:.3rem 0; }
.chapters a.here { font-weight:600; }
main { flex:1 1 auto; min-width:0; }
a { color:var(--accent); }
h1,h2,h3 { line-height:1.25; margin:2rem 0 .75rem; }
h1 { margin-top:0; }
h1 .anchor, h2 .anchor, h3 .anchor { float:left; margin-left:-1.1em; padding-right:.3em;
       color:var(--muted); opacity:0; text-decoration:none; }
h1:hover .anchor, h2:hover .anchor, h3:hover .anchor { opacity:1; }
.toc { border:1px solid var(--rule); border-radius:6px; padding:.75rem 1rem; margin-bottom:2rem;
       font-size:.9rem; }
.toc h2 { font-size:.8rem; text-transform:uppercase; letter-spacing:.06em; color:var(--muted);
       margin:0 0 .5rem; }
.toc li { margin:.2rem 0; }
.toc .toc-h3 { padding-left:1rem; }
.codeblock { margin:1rem 0; }
.codeblock pre { margin:0; padding:.85rem 1rem; overflow-x:auto; border-radius:6px;
       background:var(--code-bg); border:1px solid var(--rule); }
.codeblock.kind-output pre { background:var(--out-bg); }
code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size:.9em; }
:not(pre) > code { background:var(--code-bg); padding:.1em .35em; border-radius:4px; }
table { border-collapse:collapse; }
th, td { border:1px solid var(--rule); padding:.4rem .6rem; text-align:left; }
blockquote { margin:1rem 0; padding:.1rem 1rem; border-left:3px solid var(--rule); color:var(--muted); }
@media (max-width:820px) { .layout { flex-direction:column; } .chapters { flex:none; } }
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
