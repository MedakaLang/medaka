// smoke.spec.mjs — a short cross-engine smoke of the playground's workers.
//
// Usage: node e2e/smoke.spec.mjs <base-url> <screenshots-dir> <engine>
//   <engine> is chromium (the system Google Chrome, as the other specs use),
//   firefox (Playwright's bundled Firefox) or webkit (Playwright's bundled WebKit,
//   emulating an iPhone 15 so the phone layout is the one exercised).
// Started by lib/run-server-and-tests.mjs once per engine, after the Chrome-only
// specs.
//
// WebKit applies the page's Cross-Origin-Embedder-Policy to every module a module
// worker imports, where Chrome checks only the worker script itself, so a header
// rule missing for an imported module kills Run on every iOS browser while Chrome
// stays green (#3881). The checks below are the ones that go red when that
// happens:
//   1. the page is crossOriginIsolated;
//   2. the default program runs to its output and the "compiled & ran" footer
//      (compiler-worker.js, which imports compile.mjs and wat2wasm.js);
//   3. a type error gets an inline diagnostic (language-worker.js, the other
//      module worker; Run is not clicked, so nothing else can produce it);
//   4. test/async_fixtures/overlap_sleeps.mdk prints "overlapped" (worker.js
//      blocking on Atomics.wait across three concurrent sleeps);
//   5. no page error and no Cross-Origin-Embedder-Policy refusal in the console
//      of the page or any of its workers.
//
// EXPECTED_FAIL lists checks known to fail on one engine. Such a check prints
// XFAIL while it fails and FAILS the run once it passes: that is the signal to
// delete its entry.
import { chromium, firefox, webkit, devices } from 'playwright';
import fs from 'node:fs';
import { ANIMATION_EXAMPLES } from '../animation_examples.mjs';

const [, , BASE_URL, SCREENSHOT_DIR, ENGINE] = process.argv;
const ENGINES = {
  chromium: { type: chromium, launch: { channel: 'chrome' }, context: {} },
  firefox: { type: firefox, launch: {}, context: {} },
  webkit: { type: webkit, launch: {}, context: { ...devices['iPhone 15'] } },
};
if (!BASE_URL || !SCREENSHOT_DIR || !ENGINES[ENGINE]) {
  console.error('usage: node smoke.spec.mjs <base-url> <screenshots-dir> <chromium|firefox|webkit>');
  process.exit(2);
}

const EXPECTED_FAIL = {};

// stdout of the default program (EXAMPLES.shapes in main.js), as `medaka run` prints it.
const DEFAULT_OUTPUT = 'areas: [3.14159, 12.0]\n';
const FOOTER = '✓ compiled & ran in ';
const TYPE_ERROR_SAMPLE = 'main = println (1 + "hello")\n';
const OVERLAP = fs.readFileSync(
  new URL('../../test/async_fixtures/overlap_sleeps.mdk', import.meta.url), 'utf8');
const COEP_REFUSAL = /cross-origin-embedder-policy/i;

let failures = 0;
function check(id, name, cond, detail) {
  const xfail = EXPECTED_FAIL[ENGINE]?.[id];
  const tag = `[${ENGINE}] ${name}`;
  if (xfail) {
    if (cond) {
      failures++;
      console.log(`  FAIL  ${tag} — passed, but is listed as an expected failure (${xfail}); delete its EXPECTED_FAIL entry`);
    } else {
      console.log(`  XFAIL ${tag} — ${xfail}${detail ? ' — ' + detail : ''}`);
    }
  } else if (cond) {
    console.log(`  PASS  ${tag}`);
  } else {
    failures++;
    console.log(`  FAIL  ${tag}${detail ? ' — ' + detail : ''}`);
  }
}

function setSource(page, src) {
  return page.evaluate((s) => {
    const v = window.__mdkView;
    v.dispatch({ changes: { from: 0, to: v.state.doc.length, insert: s } });
  }, src);
}

// Clicks Run and returns the console text once Run is enabled again, followed by
// the status line, which is where a compiler-worker failure is reported. The click
// handler clears the console and disables Run before its first await, so the wait
// below cannot see the previous run's state.
async function run(page) {
  await page.waitForSelector('#run-btn:not([disabled])', { timeout: 30000 });
  await page.click('#run-btn');
  await page.waitForSelector('#run-btn:not([disabled])', { timeout: 30000 });
  await page.waitForTimeout(300);
  return page.evaluate(() =>
    document.querySelector('#console').textContent
      + '\nstatus: ' + document.querySelector('#status').textContent);
}

async function main() {
  const spec = ENGINES[ENGINE];
  const browser = await spec.type.launch(spec.launch);
  const context = await browser.newContext(spec.context);
  const page = await context.newPage();
  const pageErrors = [];
  const coepRefusals = [];
  const onConsole = (where) => (msg) => {
    if (COEP_REFUSAL.test(msg.text())) coepRefusals.push(`${where}: ${msg.text()}`);
  };
  page.on('pageerror', (e) => pageErrors.push(e.message));
  page.on('console', onConsole('page'));
  page.on('worker', (w) => w.on('console', onConsole(`worker ${w.url()}`)));

  try {
    console.log(`Smoke [${ENGINE}] ${BASE_URL}`);
    await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('.cm-editor .cm-content', { timeout: 15000 });

    check('isolated', 'page is crossOriginIsolated',
      await page.evaluate(() => window.crossOriginIsolated === true));

    const out = await run(page).catch((e) => `harness: ${e.message}`);
    check('default', 'default program prints its output and the footer',
      out.includes(DEFAULT_OUTPUT) && out.includes(FOOTER), JSON.stringify(out.slice(-300)));
    await page.screenshot({ path: `${SCREENSHOT_DIR}/smoke_${ENGINE}_1_run.png` });

    await setSource(page, TYPE_ERROR_SAMPLE);
    const squiggle = await page.waitForSelector('.cm-lintRange-error', { timeout: 30000 })
      .then(() => true, () => false);
    check('diagnostic', 'a type error gets an inline diagnostic (language worker)', squiggle);
    await page.screenshot({ path: `${SCREENSHOT_DIR}/smoke_${ENGINE}_2_diagnostic.png` });

    await setSource(page, OVERLAP);
    const ov = await run(page).catch((e) => `harness: ${e.message}`);
    check('overlap', 'overlap_sleeps prints "overlapped"',
      /^overlapped$/m.test(ov) && ov.includes(FOOTER), JSON.stringify(ov.slice(-300)));
    await page.screenshot({ path: `${SCREENSHOT_DIR}/smoke_${ENGINE}_3_async.png` });

    for (const [id, expectedSource] of Object.entries(ANIMATION_EXAMPLES)) {
      await page.selectOption('#example-select', id);
      check(`${id}-picker`, `${id}: picker restores the shared editable source`,
        await page.evaluate(() => window.__mdkView.state.doc.toString()) === expectedSource);
      await page.click('#share-btn');
      await page.waitForFunction(() => location.hash.startsWith('#code='));
      await setSource(page, 'main = println "unsaved edit"\n');
      await page.reload({ waitUntil: 'domcontentloaded' });
      await page.waitForSelector('.cm-editor .cm-content');
      check(`${id}-share`, `${id}: permalink restores the complete source`,
        await page.evaluate(() => window.__mdkView.state.doc.toString()) === expectedSource);
      await page.click('#run-btn');
      await page.waitForFunction(() => !document.getElementById('run-btn').disabled && document.getElementById('status').textContent === 'running…', null, { timeout: 60000 });
      const snapshot = () => page.evaluate(() => document.getElementById('animation-canvas').toDataURL());
      const first = await snapshot();
      await page.waitForFunction(before => document.getElementById('animation-canvas').toDataURL() !== before,
        first, { timeout: 10000 });
      check(`${id}-pixels`, `${id}: canvas pixels change`, await snapshot() !== first);
      await page.click('#stop-btn');
      const stopped = await snapshot();
      await page.waitForTimeout(100);
      check(`${id}-stop`, `${id}: Stop holds the last picture`, await snapshot() === stopped
        && await page.locator('#status').textContent() === 'stopped');
      await page.click('#run-btn');
      await page.waitForFunction(() => !document.getElementById('run-btn').disabled && document.getElementById('status').textContent === 'running…', null, { timeout: 60000 });
      const rerun = await snapshot();
      await page.waitForFunction(before => document.getElementById('animation-canvas').toDataURL() !== before,
        rerun, { timeout: 10000 });
      check(`${id}-rerun`, `${id}: clean rerun animates`, await snapshot() !== rerun);
      await page.click('#stop-btn');
      await page.screenshot({ path: `${SCREENSHOT_DIR}/smoke_${ENGINE}_${id}.png` });
    }
  } catch (e) {
    console.error(`Harness error [${ENGINE}]:`, e.message);
    console.error(await page.locator('#console').textContent());
    console.error('status:', await page.locator('#status').textContent());
    failures++;
    try { await page.screenshot({ path: `${SCREENSHOT_DIR}/ERROR_smoke_${ENGINE}.png` }); } catch {}
  } finally {
    check('pageerror', 'no page error', pageErrors.length === 0, pageErrors.join(' | '));
    check('coep', 'no Cross-Origin-Embedder-Policy refusal in the console',
      coepRefusals.length === 0, coepRefusals.join(' | '));
    await browser.close();
  }
  console.log(failures === 0 ? `\nSMOKE [${ENGINE}] PASSED` : `\n${failures} SMOKE [${ENGINE}] CHECK(S) FAILED`);
  process.exit(failures === 0 ? 0 : 1);
}

main();
