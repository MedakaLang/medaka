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

function setSource(page, src) {
  return page.evaluate((s) => {
    const v = window.__mdkView;
    v.dispatch({ changes: { from: 0, to: v.state.doc.length, insert: s } });
  }, src);
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
