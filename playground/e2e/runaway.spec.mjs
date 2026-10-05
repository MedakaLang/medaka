// runaway.spec.mjs — a runaway print loop stops at the time limit (#3795).
//
// Usage: node e2e/runaway.spec.mjs <base-url> <screenshots-dir>
// Started by lib/run-server-and-tests.mjs after playground.spec.mjs.
//
// The program prints forever. The page must stay responsive the whole time
// (a `page.evaluate` probe every ~2 s answers within PROBE_TIMEOUT_MS), show the
// existing "stopped after 10 s" message within the limit plus a margin, and never
// crash.
import { chromium } from 'playwright';

const [, , BASE_URL, SCREENSHOT_DIR] = process.argv;
if (!BASE_URL || !SCREENSHOT_DIR) {
  console.error('usage: node runaway.spec.mjs <base-url> <screenshots-dir>');
  process.exit(2);
}

const RUNAWAY = 'go n =\n  println n\n  go (n + 1)\n\nmain = go 0\n';
const STOP_MSG = "stopped after 10 s (the playground's time limit)";
const STOP_DEADLINE_MS = 25000; // 10 s limit + compile and teardown margin
const PROBE_EVERY_MS = 2000;
const PROBE_TIMEOUT_MS = 4000;

let failures = 0;
function check(name, cond, detail) {
  if (cond) {
    console.log(`  PASS  ${name}`);
  } else {
    failures++;
    console.log(`  FAIL  ${name}${detail ? ' — ' + detail : ''}`);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Resolves 'ok' if the page answers, 'slow' if it does not within PROBE_TIMEOUT_MS.
function probe(page) {
  return Promise.race([
    page.evaluate(() => 1).then(() => 'ok', () => 'dead'),
    sleep(PROBE_TIMEOUT_MS).then(() => 'slow'),
  ]);
}

async function main() {
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  const page = await browser.newPage();
  let crashed = false;
  page.on('crash', () => { crashed = true; });
  try {
    console.log('Test: runaway print loop stops at the limit (#3795)');
    await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('.cm-editor .cm-content', { timeout: 15000 });
    await page.evaluate((s) => {
      const v = window.__mdkView;
      v.dispatch({ changes: { from: 0, to: v.state.doc.length, insert: s } });
    }, RUNAWAY);
    await page.waitForSelector('#run-btn:not([disabled])', { timeout: 15000 });
    await page.click('#run-btn');
    const t0 = Date.now();

    const results = [];
    let stopped = false;
    while (Date.now() - t0 < STOP_DEADLINE_MS) {
      const r = await probe(page);
      results.push(r);
      if (r !== 'ok') break;
      stopped = await page.evaluate(
        (m) => document.querySelector('#console').textContent.includes(m), STOP_MSG)
        .catch(() => false);
      if (stopped) break;
      await sleep(PROBE_EVERY_MS);
    }
    const ms = Date.now() - t0;
    console.log(`  probes: ${results.join(',')} (${ms} ms)`);
    check('page answered every responsiveness probe', results.length > 0 && results.every((r) => r === 'ok'), results.join(','));
    check(`stop message appeared within ${STOP_DEADLINE_MS} ms (${ms} ms)`, stopped);
    check('page did not crash', !crashed);
    const lines = await page.evaluate(() => document.querySelector('#console').children.length).catch(() => -1);
    console.log(`  console span count after stop: ${lines}`);
    const enabled = await page.evaluate(() => !document.querySelector('#run-btn').disabled).catch(() => false);
    check('Run is re-enabled after the stop', enabled);
  } catch (e) {
    console.error('Harness error:', e.message);
    failures++;
    try { await page.screenshot({ path: `${SCREENSHOT_DIR}/ERROR_runaway.png` }); } catch {}
  } finally {
    await browser.close();
  }
  console.log(failures === 0 ? '\nRUNAWAY CHECKS PASSED' : `\n${failures} RUNAWAY CHECK(S) FAILED`);
  process.exit(failures === 0 ? 0 : 1);
}

main();
