// tests/playground.spec.mjs — Medaka CM6 playground end-to-end checks.
//
// Drives the SYSTEM Google Chrome (channel: 'chrome') against a real browser —
// no headless-only "logic" test, no Playwright browser download (blocked by
// TLS interception on this machine; see playground/e2e/README.md). Requires:
//   - node v24+ on PATH (system v20 can't run the finalized-WasmGC module)
//   - playground/dist/{playground.wasm,runtime.mdk,core.mdk} already built
//     (bash playground/build_playground_wasm.sh) — this harness does NOT build it
//   - a running static server (see lib/server.mjs), started by run.sh
//
// Usage: node tests/playground.spec.mjs <base-url> <screenshots-dir>
//
// 2026-07 layout redesign: the page is now a single centered "quiet column" —
// slim header, dismissible funnel strip (#funnel-strip / #funnel-dismiss),
// toolbar (examples picker #example-select, #share-btn, #run-btn), the CM6
// editor (#editor, unchanged), and ONE unified console (#console) that
// replaces the old three-pane stdout/stderr/problems layout — stdout renders
// plain, stderr/problems render inline in that same pane (see main.js).
import { chromium } from 'playwright';
import fs from 'node:fs';

const [, , BASE_URL, SCREENSHOT_DIR] = process.argv;
if (!BASE_URL || !SCREENSHOT_DIR) {
  console.error('usage: node playground.spec.mjs <base-url> <screenshots-dir>');
  process.exit(2);
}

const DEFAULT_SAMPLE =
  'main =\n  println (sum [1,2,3,4,5])\n  println "hello from Medaka!"\n';
const TYPE_ERROR_SAMPLE = 'main = println (1 + "hello")\n';

let failures = 0;
function check(name, cond, detail) {
  if (cond) {
    console.log(`  PASS  ${name}`);
  } else {
    failures++;
    console.log(`  FAIL  ${name}${detail ? ' — ' + detail : ''}`);
  }
}

// Phone-width header: the page must not scroll sideways, the link row must be
// replaced by a hamburger, and opening it must reveal the links. `menu` is the
// <details> selector for that header (.b-menu on the apex, .site-nav-menu on a
// rendered doc page); `row` is the wide-viewport link row it replaces.
async function checkPhoneHeader(browser, url, label, { menu, row }) {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const p = await ctx.newPage();
  try {
    await p.goto(url, { waitUntil: 'domcontentloaded' });
    await p.waitForSelector(menu + ' summary', { timeout: 15000 });
    const scrollW = await p.evaluate(() => document.documentElement.scrollWidth);
    check(`${label}: no horizontal overflow at 390px (scrollWidth ${scrollW})`, scrollW <= 390);
    const rowHidden = await p.$eval(row, (el) => getComputedStyle(el).display === 'none');
    check(`${label}: wide link row hidden at 390px`, rowHidden);
    const summaryShown = await p.$eval(menu + ' summary', (el) => el.getBoundingClientRect().width > 0);
    check(`${label}: hamburger visible at 390px`, summaryShown);
    await p.click(menu + ' summary');
    const linkCount = await p.$$eval(menu + ' nav a', (as) => as.filter((a) => a.getBoundingClientRect().height > 0).length);
    check(`${label}: opening the menu reveals the links (got ${linkCount})`, linkCount >= 4);
    const scrollWOpen = await p.evaluate(() => document.documentElement.scrollWidth);
    check(`${label}: open menu does not overflow either (scrollWidth ${scrollWOpen})`, scrollWOpen <= 390);
  } finally {
    await ctx.close();
  }
}

function setSource(page, src) {
  return page.evaluate((s) => {
    const v = window.__mdkView;
    v.dispatch({ changes: { from: 0, to: v.state.doc.length, insert: s } });
  }, src);
}

// Battery program sources are read from test/visitor_battery/, never copied.
const batterySource = (name) =>
  fs.readFileSync(new URL(`../../../test/visitor_battery/${name}.mdk`, import.meta.url), 'utf8');

// Runs `name` through the page and returns the console text once Run re-enables.
async function runBattery(page, name, timeout = 30000) {
  await setSource(page, batterySource(name));
  await page.waitForSelector('#run-btn:not([disabled])', { timeout: 15000 });
  await page.click('#run-btn');
  await page.waitForFunction(
    () => !document.querySelector('#run-btn').disabled
      && /runtime error|stack overflow|not available|native-only|stopped after|error\]|\n/.test(document.querySelector('#console').textContent),
    null, { timeout });
  await page.waitForTimeout(300);
  return (await page.$eval('#console', (el) => el.textContent)).trim();
}

async function main() {
  const browser = await chromium.launch({ channel: 'chrome' });
  const page = await (await browser.newContext()).newPage();
  const pageErrors = [];
  page.on('pageerror', (e) => pageErrors.push(e.message));

  try {
    console.log(`Loading ${BASE_URL} ...`);
    await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });

    // ── Test 1: page loads + CM6 mounts ────────────────────────────────────
    console.log('Test: CM6 editor mounts');
    await page.waitForSelector('.cm-editor .cm-content', { timeout: 15000 });
    const noTextarea = !(await page.$('#editor textarea'));
    const hasCmEditor = !!(await page.$('.cm-editor'));
    check('CM6 .cm-editor present, legacy textarea gone', noTextarea && hasCmEditor);
    await page.screenshot({ path: `${SCREENSHOT_DIR}/01_loaded.png` });

    // ── Test 1b: funnel strip renders + dismisses (persists via localStorage)
    console.log('Test: funnel strip renders + dismisses');
    const funnelVisible = await page.$eval('#funnel-strip', (el) => getComputedStyle(el).display !== 'none');
    check('funnel strip visible on first load', funnelVisible);
    await page.click('#funnel-dismiss');
    const funnelHiddenAfterClick = await page.$eval('#funnel-strip', (el) => getComputedStyle(el).display === 'none');
    check('funnel strip hidden after dismiss click', funnelHiddenAfterClick);
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForSelector('.cm-editor .cm-content', { timeout: 15000 });
    const funnelStillHidden = await page.$eval('#funnel-strip', (el) => getComputedStyle(el).display === 'none');
    check('funnel strip stays hidden across reload (localStorage)', funnelStillHidden);

    // ── Test 1c: phone-width header (apex) ──────────────────────────────────
    console.log('Test: phone-width header on the apex');
    await checkPhoneHeader(browser, BASE_URL, 'apex', { menu: '.b-menu', row: '.b-head .links' });

    // ── Test 2: syntax highlighting active ─────────────────────────────────
    console.log('Test: syntax highlighting');
    const spanCount = await page.$$eval('.cm-content span', (ss) => ss.length);
    const distinctColors = await page.$$eval('.cm-content span', (ss) => {
      const colors = new Set(ss.map((s) => getComputedStyle(s).color).filter(Boolean));
      return colors.size;
    });
    check(`>5 highlighted spans (got ${spanCount})`, spanCount > 5);
    check(`>=3 distinct token colors (got ${distinctColors})`, distinctColors >= 3);
    await page.screenshot({ path: `${SCREENSHOT_DIR}/02_highlighting.png` });

    // ── Test 3: default sample runs, console shows expected output ─────────
    console.log('Test: default sample runs');
    await setSource(page, DEFAULT_SAMPLE);
    await page.waitForSelector('#run-btn:not([disabled])', { timeout: 15000 });
    await page.click('#run-btn');
    // Tolerate a timeout here so a flaky Run does not abort the independent
    // hover/completion tests below (Run compiles in a Web Worker whose stack can
    // overflow the compiler's deep recursion — a pre-existing limitation, see the
    // module-cache note in compile.mjs).
    try {
      await page.waitForFunction(
        () => document.getElementById('console')?.textContent?.includes('hello'),
        null,
        { timeout: 30000 },
      );
    } catch { /* the checks below will record the failure */ }
    const consoleText = (await page.$eval('#console', (el) => el.textContent)).trim();
    check('console contains "hello from Medaka!"', consoleText.includes('hello from Medaka!'), consoleText);
    check('console contains sum result "15"', consoleText.includes('15'), consoleText);
    check('console shows a compiled&ran meta line', consoleText.includes('compiled & ran in'), consoleText);
    await page.screenshot({ path: `${SCREENSHOT_DIR}/03_run_output.png` });

    // ── Test 4: type error -> inline squiggle + gutter marker + console problem
    console.log('Test: type-error squiggle');
    await setSource(page, TYPE_ERROR_SAMPLE);
    // Tolerate a timeout (analyze also runs in the worker — same pre-existing
    // deep-recursion limitation) so the hover/completion tests still run.
    try { await page.waitForSelector('.cm-lintRange-error, .cm-lint-marker-error', { timeout: 8000 }); } catch { /* checks below record it */ }
    const hasSquiggle = !!(await page.$('.cm-lintRange-error'));
    const hasGutterMarker = !!(await page.$('.cm-lint-marker-error'));
    // Re-run so the console (which only gets problems populated on Run, same as
    // the old #problems pane) reflects the current buffer's diagnostics.
    await page.click('#run-btn');
    try {
      await page.waitForFunction(
        () => document.getElementById('console')?.textContent?.includes('No impl of Num for String'),
        null,
        { timeout: 15000 },
      );
    } catch { /* checks below record it */ }
    const consoleProblemsText = (await page.$eval('#console', (el) => el.textContent).catch(() => ''));
    check('inline squiggle (.cm-lintRange-error) present', hasSquiggle);
    check('gutter marker (.cm-lint-marker-error) present', hasGutterMarker);
    check(
      'console reports "No impl of Num for String"',
      consoleProblemsText.includes('No impl of Num for String'),
      consoleProblemsText.slice(0, 200),
    );
    await page.screenshot({ path: `${SCREENSHOT_DIR}/04_squiggle.png` });

    // ── Test 5: hover an identifier → its inferred type ──────────────────────
    // hover/completion run on the MAIN THREAD (a Web Worker's stack is too small
    // for the compiler's deep recursion; see main.js).  We assert the browser's
    // language-service DATA path deterministically via window.__mdkLang (the exact
    // provider the CM6 tooltip calls), then best-effort-trigger the visual tooltip
    // for the screenshot — CM6's synthetic-mouse hover timing is too flaky to gate.
    console.log('Test: hover-type');
    const HOVER_SAMPLE = 'double : Int -> Int\ndouble x = x + x\n\nmain = println (double 21)\n';
    await setSource(page, HOVER_SAMPLE);
    await page.waitForTimeout(2000); // let the main-thread module warm up (tier-up)
    // Deterministic: call the language service the CM6 provider uses (line 1 = the
    // `double` definition, col 0).
    const hoverValue = await page.evaluate(async (src) => {
      const h = await window.__mdkLang.hover(src, 1, 0);
      return (h && h.contents && h.contents.value) || null;
    }, HOVER_SAMPLE);
    check('hover returns `double : Int -> Int`', !!hoverValue && hoverValue.includes('double : Int -> Int'), JSON.stringify(hoverValue));

    // Best-effort: trigger the actual CM6 hover tooltip for the screenshot.
    const hoverCoords = await page.evaluate(() => {
      const v = window.__mdkView;
      const line = v.state.doc.line(2);
      const c = v.coordsAtPos(line.from + 2);
      return c ? { x: (c.left + c.right) / 2, y: (c.top + c.bottom) / 2 } : null;
    });
    let sawTooltip = false;
    if (hoverCoords) {
      for (let attempt = 0; attempt < 5 && !sawTooltip; attempt++) {
        await page.mouse.move(6, 6);
        await page.waitForTimeout(200);
        await page.mouse.move(hoverCoords.x - 3, hoverCoords.y);
        await page.mouse.move(hoverCoords.x, hoverCoords.y);
        try { await page.waitForSelector('.cm-mdk-hover', { timeout: 2500 }); sawTooltip = true; } catch { /* retry */ }
      }
    }
    console.log('  (hover tooltip rendered in UI: ' + sawTooltip + ')');
    await page.screenshot({ path: `${SCREENSHOT_DIR}/05_hover.png` });

    // ── Test 6: prefix → prefix-filtered completion list ─────────────────────
    console.log('Test: autocomplete');
    // Deterministic: assert the completion provider's data via __mdkLang.
    const completionLabels = await page.evaluate(async () => {
      const items = await window.__mdkLang.complete('main = pr\n', 0, 9); // prefix `pr`
      return (items || []).map((i) => i.label);
    });
    check('completion returns a non-empty list for prefix `pr`', completionLabels.length > 0, JSON.stringify(completionLabels));
    check('completion lists `println`', completionLabels.includes('println'), JSON.stringify(completionLabels.slice(0, 8)));

    // Best-effort: trigger the actual CM6 autocomplete popup for the screenshot.
    await page.evaluate(() => {
      const v = window.__mdkView;
      v.dispatch({ changes: { from: 0, to: v.state.doc.length, insert: 'main = ' } });
      v.dispatch({ selection: { anchor: v.state.doc.length } });
      v.focus();
    });
    await page.keyboard.type('pri', { delay: 70 });
    let sawPopup = false;
    for (let attempt = 0; attempt < 5 && !sawPopup; attempt++) {
      try { await page.waitForSelector('.cm-tooltip-autocomplete li', { timeout: 2500 }); sawPopup = true; }
      catch { await page.keyboard.press('Control+Space').catch(() => {}); }
    }
    console.log('  (autocomplete popup rendered in UI: ' + sawPopup + ')');
    await page.screenshot({ path: `${SCREENSHOT_DIR}/06_completion.png` });

    // ── Test 7: examples picker loads an example that runs ───────────────────
    console.log('Test: examples picker');
    await page.selectOption('#example-select', 'hello');
    const helloSrc = await page.evaluate(() => window.__mdkView.state.doc.toString());
    check('picking "hello" example loads its source', helloSrc.includes('hello from Medaka!'), helloSrc.slice(0, 60));
    await page.waitForSelector('#run-btn:not([disabled])', { timeout: 15000 });
    await page.click('#run-btn');
    try {
      await page.waitForFunction(
        () => document.getElementById('console')?.textContent?.includes('hello from Medaka!'),
        null,
        { timeout: 30000 },
      );
    } catch { /* recorded below */ }
    const helloConsole = (await page.$eval('#console', (el) => el.textContent)).trim();
    check('"hello" example runs and prints greeting', helloConsole.includes('hello from Medaka!'), helloConsole);
    await page.screenshot({ path: `${SCREENSHOT_DIR}/07_examples.png` });

    // ── Test 8: Share round-trip (set hash -> reload -> editor has program) ──
    console.log('Test: share permalink round-trip');
    await page.selectOption('#example-select', 'pipeline');
    await page.waitForTimeout(300);
    try {
      await page.context().grantPermissions(['clipboard-read', 'clipboard-write']);
    } catch { /* some Chrome builds don't support this permission name; continue */ }
    await page.click('#share-btn');
    await page.waitForTimeout(300);
    const hashAfterShare = await page.evaluate(() => window.location.hash);
    check('Share sets a #code= hash', hashAfterShare.startsWith('#code='), hashAfterShare.slice(0, 40));
    const pipelineSrcBeforeReload = await page.evaluate(() => window.__mdkView.state.doc.toString());
    const urlWithHash = BASE_URL.replace(/#.*$/, '') + hashAfterShare;
    await page.goto(urlWithHash, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('.cm-editor .cm-content', { timeout: 15000 });
    const srcAfterReload = await page.evaluate(() => window.__mdkView.state.doc.toString());
    check('editor content survives hash round-trip', srcAfterReload === pipelineSrcBeforeReload, srcAfterReload.slice(0, 60));
    await page.screenshot({ path: `${SCREENSHOT_DIR}/08_share_roundtrip.png` });

    // ── Test 9/10: the rendered guide (site layout only) ─────────────────────
    // These only exist in the DEPLOYED tree (playground/site/, assembled by
    // build_site.sh); the dev tree has no guide/ at all. E2E_EXPECT_GUIDE — set
    // by `SITE=1 bash playground/e2e/run.sh`, and settable by hand for a live
    // origin — is what makes them mandatory rather than skipped, so "the guide
    // is missing" can never read as "the guide tests passed".
    if (!process.env.E2E_EXPECT_GUIDE) {
      console.log('Skipping guide-route tests (E2E_EXPECT_GUIDE unset — dev tree has no guide/).');
      console.log('  Run them with: SITE=1 bash playground/e2e/run.sh');
    } else {
      const base = BASE_URL.replace(/#.*$/, '').replace(/\/$/, '');
      const GUIDE_ENTRY = '/guide/00-introduction.html';

      // ── Test 9: the apex links into the guide, and the guide links back ────
      console.log('Test: guide route');
      await page.goto(base + '/', { waitUntil: 'domcontentloaded' });
      const guideHref = await page.getAttribute('.links a[href*="guide/"]', 'href');
      check('apex header links into the guide', !!guideHref, String(guideHref));

      const entryStatus = (await page.goto(base + GUIDE_ENTRY, { waitUntil: 'domcontentloaded' })).status();
      check(`${GUIDE_ENTRY} loads (200)`, entryStatus === 200, `status ${entryStatus}`);

      // The bare /guide/ route — the one Val approved by name, and the one a
      // reader types rather than clicks. render_docs.mjs emits guide/index.html
      // precisely so a static host has something to serve here; without it this
      // is a 404 while every chapter page is fine, which is invisible to anyone
      // who only ever follows links.
      const bareGuide = await page.evaluate(async (u) => (await fetch(u)).status, base + '/guide/');
      check('bare /guide/ route serves a directory index (200)', bareGuide === 200, `status ${bareGuide}`);

      // The Advanced Topics section (docs/advanced, rendered by
      // build_advanced_docs.sh into site/advanced/) is a sibling doc set with
      // the same shape: an apex link, a landing page, a bare route, and a
      // cross-link INTO the guide that must resolve on this origin (the
      // renderer's --sibling rewrite) rather than leaving for GitHub.
      // The `.links` header exists only on the apex page; the guide chapter the
      // previous check left us on has the doc-set nav instead, so go back first.
      await page.goto(base + '/', { waitUntil: 'domcontentloaded' });
      const advHref = await page.evaluate(() => document.querySelector('.links a[href*="advanced/"]')?.getAttribute('href') ?? null);
      check('apex header links into the advanced topics', !!advHref, String(advHref));
      const advStatus = (await page.goto(base + '/advanced/00-about.html', { waitUntil: 'domcontentloaded' })).status();
      check('/advanced/00-about.html loads (200)', advStatus === 200, `status ${advStatus}`);
      const bareAdv = await page.evaluate(async (u) => (await fetch(u)).status, base + '/advanced/');
      check('bare /advanced/ route serves a directory index (200)', bareAdv === 200, `status ${bareAdv}`);
      const advToGuide = await page.evaluate(() => document.querySelector('article a[href^="../guide/"]')?.getAttribute('href') ?? null);
      check('advanced landing page links into the guide on this origin', !!advToGuide && advToGuide.endsWith('.html'), String(advToGuide));
      if (advToGuide) {
        const advToGuideStatus = await page.evaluate(async (h) => (await fetch(h)).status, advToGuide);
        check(`that cross-link resolves (${advToGuide} -> ${advToGuideStatus})`, advToGuideStatus === 200);
      }
      await page.goto(base + GUIDE_ENTRY, { waitUntil: 'domcontentloaded' });

      // A chapter page: real rendered content, not an empty shell.
      const chapterStatus = (await page.goto(base + '/guide/03-functions.html', { waitUntil: 'domcontentloaded' })).status();
      check('a chapter page loads (200)', chapterStatus === 200, `status ${chapterStatus}`);
      const chapterH1 = await page.$eval('h1', (el) => el.textContent.trim()).catch(() => '');
      check('chapter page has a heading', chapterH1.length > 0, chapterH1);
      const chapterBlocks = await page.$$eval('.codeblock.kind-medaka', (els) => els.length);
      check(`chapter page renders medaka code blocks (got ${chapterBlocks})`, chapterBlocks > 0);
      const backHref = await page.getAttribute('.site-nav-back', 'href');
      const backStatus = await page.evaluate(async (h) => (await fetch(h)).status, backHref);
      check(`guide "← Playground" back link resolves (${backHref} -> ${backStatus})`, backStatus === 200);
      await page.screenshot({ path: `${SCREENSHOT_DIR}/09_guide_chapter.png` });

      // The rendered doc pages carry the other header (render_docs.mjs .site-nav);
      // same phone-width contract as the apex.
      console.log('Test: phone-width header on a guide page');
      await checkPhoneHeader(browser, base + '/guide/03-functions.html', 'guide page',
        { menu: '.site-nav-menu', row: '.site-nav-links' });

      // "Open in Playground" must land the EXACT block source in the editor.
      console.log('Test: guide "Open in Playground" round-trip');
      const firstRun = await page.evaluate(() => {
        const a = document.querySelector('a.pg-run');
        if (!a) return null;
        return { href: a.getAttribute('href'), source: a.closest('.codeblock').getAttribute('data-source') };
      });
      check('chapter page offers an "Open in Playground" link', !!firstRun);
      if (firstRun) {
        await page.click('a.pg-run');
        await page.waitForSelector('.cm-editor .cm-content', { timeout: 15000 });
        const inEditor = await page.evaluate(() => window.__mdkView.state.doc.toString());
        check('the linked block\'s source arrives verbatim in the editor',
          inEditor.trim() === firstRun.source.trim(), JSON.stringify(inEditor.slice(0, 80)));
        await page.screenshot({ path: `${SCREENSHOT_DIR}/10_guide_open_in_playground.png` });
      }

      // ── Test 10: a real browser produces the guide's DOCUMENTED output ─────
      // The tie between this browser and playground/guide_wasm_differential.mjs,
      // which checks all 65 runnable examples out-of-browser: both are asked the
      // same question — does the example print what the `medaka-expect` fence
      // beside it says it prints — so agreeing here is evidence that the
      // differential's wasm engine and this Chrome's agree.
      console.log('Test: guide examples produce their documented output IN THE BROWSER');
      await page.goto(base + '/guide/01-quick-start.html', { waitUntil: 'domcontentloaded' });
      const samples = (await page.evaluate(() => {
        const out = [];
        const blocks = [...document.querySelectorAll('.codeblock')];
        for (let i = 0; i + 1 < blocks.length; i++) {
          const a = blocks[i].querySelector('a.pg-run');
          if (!a) continue;
          if (!blocks[i + 1].classList.contains('kind-output')) continue;
          out.push({
            href: a.getAttribute('href'),
            source: blocks[i].getAttribute('data-source'),
            expect: blocks[i + 1].getAttribute('data-source'),
          });
        }
        return out;
      })).slice(0, 3);
      check(`found guide examples with a documented output (got ${samples.length})`, samples.length >= 2);
      for (const [i, s] of samples.entries()) {
        // about:blank first: consecutive samples differ only in the URL's HASH,
        // and a same-document hash change does NOT reload — without this the
        // editor keeps the previous sample and the console keeps its output,
        // which reads as a pass for whichever sample happened to run first.
        await page.goto('about:blank');
        await page.goto(base + '/guide/' + s.href, { waitUntil: 'domcontentloaded' });
        await page.waitForSelector('.cm-editor .cm-content', { timeout: 15000 });
        // Belt and braces on the same hazard: assert we are about to run THIS
        // sample's program, not a leftover one.
        const loaded = await page.evaluate(() => window.__mdkView.state.doc.toString());
        check(`guide sample ${i + 1} loads its own source into the editor`,
          loaded.trim() === s.source.trim(), JSON.stringify(loaded.slice(0, 80)));
        await page.waitForSelector('#run-btn:not([disabled])', { timeout: 20000 });
        await page.click('#run-btn');
        const want = s.expect.trim();
        try {
          await page.waitForFunction(
            (w) => document.getElementById('console')?.textContent?.includes(w),
            want.split('\n')[0],
            { timeout: 40000 },
          );
        } catch { /* the check below records it */ }
        const got = (await page.$eval('#console', (el) => el.textContent)).trim();
        const allLines = want.split('\n').every((ln) => got.includes(ln));
        check(`guide sample ${i + 1} prints its documented output in the browser`, allLines,
          `want ${JSON.stringify(want)} / got ${JSON.stringify(got.slice(0, 200))}`);
      }
      await page.screenshot({ path: `${SCREENSHOT_DIR}/11_guide_sample_run.png` });
    }

    // ── Test 12: the published stdlib reference (site layout only) ───────────
    // #2384's second published doc set, and the SAME shape as the guide block
    // above on purpose: the dev tree has no stdlib/ at all, so E2E_EXPECT_STDLIB
    // — set by `SITE=1 bash playground/e2e/run.sh`, and settable by hand against
    // a live origin — is what makes these mandatory rather than skipped. "The
    // stdlib reference is missing" must never read as "the stdlib tests passed".
    //
    // Deliberately NOT here: any "the doctests run in the browser" check. Val's
    // ruling (#2384 §0.3) is suppress-not-stamp — the rendered reference carries
    // no runnable stdlib doctests, so there is nothing to run and a check that
    // pretended otherwise would be asserting a property the site does not have.
    //
    // Also deliberately narrow: this is a REAL-BROWSER confirmation of a handful
    // of structural facts, not a link audit. The whole-set link integrity of the
    // 905-entry index is graded elsewhere — by playground/guide_render_test.mjs
    // (renderer output, at PR time) and by playground/verify_stdlib_deploy.sh
    // (a live origin, on demand). Duplicating that here would trade 30 seconds
    // of nightly wall-clock for a claim two other things already make better.
    if (!process.env.E2E_EXPECT_STDLIB) {
      console.log('Skipping /stdlib-route tests (E2E_EXPECT_STDLIB unset — dev tree has no stdlib/).');
      console.log('  Run them with: SITE=1 bash playground/e2e/run.sh');
    } else {
      console.log('Test: /stdlib route');
      const base = BASE_URL.replace(/#.*$/, '').replace(/\/$/, '');

      // The apex nav must actually offer the reference — an unlinked page that
      // happens to be deployed is not a published reference.
      await page.goto(base + '/', { waitUntil: 'domcontentloaded' });
      const stdlibHref = await page.getAttribute('.links a[href*="stdlib/"]', 'href');
      check('apex header links into the stdlib reference', !!stdlibHref, String(stdlibHref));

      // The bare /stdlib/ route — what a reader types rather than clicks. Same
      // hazard the guide block records: without an index.html a static host
      // 404s here while every module page is fine, invisible to link-followers.
      const bareStdlib = await page.evaluate(async (u) => (await fetch(u)).status, base + '/stdlib/');
      check('bare /stdlib/ route serves a directory index (200)', bareStdlib === 200, `status ${bareStdlib}`);

      // …and it must be the GENERATED library index, not render_docs.mjs's
      // synthetic chapter list. The entry links are the discriminator: the
      // synthetic index has ~28 plain page links and no #anchors at all.
      const idxStatus = (await page.goto(base + '/stdlib/', { waitUntil: 'domcontentloaded' })).status();
      check('/stdlib/ index page loads (200)', idxStatus === 200, `status ${idxStatus}`);
      const entries = await page.$$eval('li > a[href*=".html#"]', (as) =>
        as.map((a) => a.getAttribute('href')));
      check(`/stdlib/ index is the generated reference (got ${entries.length} entry links)`,
        entries.length > 100, `${entries.length} entry links`);
      await page.screenshot({ path: `${SCREENSHOT_DIR}/12_stdlib_index.png` });

      // A module page: real rendered content, not an empty shell. Derived from
      // the index's own first entry rather than hardcoded, so a module rename
      // moves this check with the tree instead of rotting into a false red.
      const firstEntry = entries[0] ?? '';
      const modulePage = firstEntry.split('#')[0];
      check('index entry links name a module page', !!modulePage, String(firstEntry));
      if (modulePage) {
        const modStatus = (await page.goto(base + '/stdlib/' + modulePage, { waitUntil: 'domcontentloaded' })).status();
        check(`module page ${modulePage} loads (200)`, modStatus === 200, `status ${modStatus}`);
        const modH1 = await page.$eval('h1', (el) => el.textContent.trim()).catch(() => '');
        check('module page has a heading', modH1.length > 0, modH1);
        const modText = await page.$eval('article', (el) => el.textContent.replace(/\s+/g, ' ').trim()).catch(() => '');
        check(`module page has substantive content (${modText.length} chars)`, modText.length > 400);
        const modBlocks = await page.$$eval('.codeblock', (els) => els.length);
        check(`module page renders code blocks (got ${modBlocks})`, modBlocks > 0);

        // A DEEP entry link — the thing the whole index is made of. The page
        // status alone is not the claim: the #anchor must land on a real
        // heading, which is the half a plain 200 cannot see.
        const frag = firstEntry.includes('#') ? firstEntry.split('#')[1] : '';
        const anchorOk = await page.evaluate((f) => {
          const el = document.getElementById(f);
          return !!el && /^H[1-6]$/.test(el.tagName);
        }, frag);
        check(`deep entry link #${frag} resolves to a heading on ${modulePage}`, anchorOk);

        // The way back out. A reference a reader cannot leave is a dead end.
        const backHref = await page.getAttribute('.site-nav-back', 'href');
        const backStatus = await page.evaluate(async (h) => (await fetch(h)).status, backHref);
        check(`stdlib "← Playground" back link resolves (${backHref} -> ${backStatus})`, backStatus === 200);
        await page.screenshot({ path: `${SCREENSHOT_DIR}/13_stdlib_module.png` });
      }
    }

    // Console truthfulness (#3691): each message appears once, names the real cause.
    {
      console.log('Test: console tells the truth');
      await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });
      await page.waitForSelector('.cm-editor .cm-content', { timeout: 15000 });
      const div = await runBattery(page, '13_int_div_zero');
      check('13 div-by-zero: runtime error shown exactly once, unbracketed',
        div.split('division by zero').length === 2 && !div.includes('[runtime error'), JSON.stringify(div));
      const rec = await runBattery(page, '14_deep_recursion');
      check('14 deep recursion: names the browser stack limit',
        rec.includes('stack overflow: recursion too deep for the browser; the native compiler has a larger stack')
          && !rec.includes('instantiate failed'), JSON.stringify(rec));
      const stdin = await runBattery(page, '34_stdin');
      check('34 readLine: names the extern as unavailable in the browser',
        stdin.includes('readLine is not available in the browser playground')
          && !stdin.includes('compiler trap'), JSON.stringify(stdin));
      const asy = await runBattery(page, '64_async_defer');
      check('64 import async: the deferred program runs and prints 3',
        /(^|\n)3\n/.test(asy) && asy.includes('compiled & ran')
          && !asy.includes('native-only'), JSON.stringify(asy));
      const inf = await runBattery(page, '51_infinite_loop', 40000);
      check('51 infinite loop: states the time limit',
        inf.includes("stopped after 10 s (the playground's time limit)")
          && !inf.includes('killed: time limit'), JSON.stringify(inf));
    }

    // Console keeps up with output (#3719): 5,000 printed lines render promptly,
    // in order, with the pane scrolled to the last line. Measured ~1.4 s on the
    // batched console vs ~20.8 s when every line forced a layout.
    {
      console.log('Test: console keeps up with 5,000 lines');
      await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });
      await page.waitForSelector('.cm-editor .cm-content', { timeout: 15000 });
      await setSource(page, batterySource('43_large_output'));
      await page.waitForSelector('#run-btn:not([disabled])', { timeout: 15000 });
      const t0 = Date.now();
      await page.click('#run-btn');
      await page.waitForFunction(
        () => document.querySelector('#console').textContent.includes('compiled & ran'),
        null, { timeout: 60000 });
      const ms = Date.now() - t0;
      check(`5,000 lines rendered in ${ms} ms (ceiling 8000 ms)`, ms < 8000);
      const big = await page.$eval('#console', (el) => {
        const lines = el.textContent.split('\n').filter((l) => /^\d+$/.test(l));
        const inOrder = lines.length === 5000 && lines.every((l, i) => Number(l) === i + 1);
        return { inOrder, atBottom: el.scrollHeight - el.scrollTop - el.clientHeight < 4 };
      });
      check('5,000 lines appear complete and in order', big.inOrder, JSON.stringify(big));
      check('console is scrolled to the last line', big.atBottom, JSON.stringify(big));
      await runBattery(page, '13_int_div_zero');
      const stderrCount = await page.$$eval('#console .con-stderr', (els) => els.length);
      check('stderr output keeps its con-stderr class', stderrCount > 0, String(stderrCount));
    }

    if (pageErrors.length) {
      console.log('Uncaught page errors observed during run:', pageErrors);
    }
  } catch (e) {
    console.error('Harness error:', e.message);
    failures++;
    try { await page.screenshot({ path: `${SCREENSHOT_DIR}/ERROR.png` }); } catch {}
  } finally {
    await browser.close();
  }

  if (failures === 0) {
    console.log('\nALL CHECKS PASSED');
    process.exit(0);
  } else {
    console.log(`\n${failures} CHECK(S) FAILED`);
    process.exit(1);
  }
}

main();
