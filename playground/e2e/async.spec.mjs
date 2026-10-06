// async.spec.mjs — a sleeping async program runs in the playground (design WA-3).
//
// Usage: node e2e/async.spec.mjs <base-url> <screenshots-dir> [<no-isolation-base-url>]
// Started by lib/run-server-and-tests.mjs after runaway.spec.mjs. The third URL is
// a server that omits COOP/COEP, standing in for a misconfigured deploy; without it
// the no-isolation case is skipped.
//
// (a) two 200 ms sleeps under `concurrent`: every line shows, in order, with the
//     "compiled & ran" footer.
// (b) a 15 s sleep hits the 10 s limit; the pre-sleep output survives and the page
//     stays responsive while the worker is blocked in Atomics.wait.
// (b2) 300 lines printed before a 15 s sleep all show after the stop.
// (b3) a partial line (no newline) printed before a 15 s sleep survives the stop.
// (c) without isolation the first sleep is a named CapabilityError, not a hang.
import { chromium } from 'playwright';

const [, , BASE_URL, SCREENSHOT_DIR, NOISO_URL] = process.argv;
if (!BASE_URL || !SCREENSHOT_DIR) {
  console.error('usage: node async.spec.mjs <base-url> <screenshots-dir> [<no-isolation-base-url>]');
  process.exit(2);
}

const STOP_MSG = "stopped after 10 s (the playground's time limit)";
const ISOLATION_MSG = '`sleep` needs cross-origin isolation, which this deployment does not provide';
const PROBE_TIMEOUT_MS = 4000;

const prog = (sleeps, ms) => `import async.{Async, liftIO, sleep, concurrent}
import time.{millis}

main : Async <Clock, Stdout> Unit
main = defer
  liftIO (u => putStrLn "before")
  _ <- concurrent [${sleeps.map(() => `sleep (millis ${ms})`).join(', ')}]
  liftIO (u => putStrLn "after")
`;

const burstProg = (n, ms) => `import async.{Async, liftIO, sleep}
import time.{millis}

burst : Int -> <Stdout> Unit
burst n =
  if n > ${n} then () else
    putStrLn ("L" ++ debug n)
    burst (n + 1)

main : Async <Clock, Stdout> Unit
main = defer
  liftIO (u => burst 1)
  _ <- sleep (millis ${ms})
  liftIO (u => putStrLn "after")
`;

const partialProg = (ms) => `import async.{Async, liftIO, sleep}
import time.{millis}

main : Async <Clock, Stdout> Unit
main = defer
  liftIO (u => putStr "partial")
  _ <- sleep (millis ${ms})
  liftIO (u => putStrLn "after")
`;

let failures = 0;
function check(name, cond, detail) {
  if (cond) console.log(`  PASS  ${name}`);
  else { failures++; console.log(`  FAIL  ${name}${detail ? ' — ' + detail : ''}`); }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function probe(page) {
  return Promise.race([
    page.evaluate(() => 1).then(() => 'ok', () => 'dead'),
    sleep(PROBE_TIMEOUT_MS).then(() => 'slow'),
  ]);
}

async function open(browser, url) {
  const page = await browser.newPage();
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('.cm-editor .cm-content', { timeout: 15000 });
  return page;
}

async function startRun(page, src) {
  await page.evaluate((s) => {
    const v = window.__mdkView;
    v.dispatch({ changes: { from: 0, to: v.state.doc.length, insert: s } });
  }, src);
  await page.waitForSelector('#run-btn:not([disabled])', { timeout: 15000 });
  await page.click('#run-btn');
  await sleep(300);
}
const consoleText = (page) => page.evaluate(() => document.querySelector('#console').textContent);

async function main() {
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  try {
    const page = await open(browser, BASE_URL);

    console.log('Test: two concurrent 200 ms sleeps run to the end');
    check('page is cross-origin isolated', await page.evaluate(() => window.crossOriginIsolated));
    await startRun(page, prog([0, 1], 200));
    await page.waitForSelector('#run-btn:not([disabled])', { timeout: 30000 });
    await sleep(300);
    const a = await consoleText(page);
    check('before/after in order with the footer',
      /before\nafter\n/.test(a) && a.includes('compiled & ran'), JSON.stringify(a.slice(-200)));

    console.log('Test: a 15 s sleep stops at the limit with earlier output intact');
    await startRun(page, prog([0], 15000));
    const t0 = Date.now();
    const probes = [];
    let b = '';
    while (Date.now() - t0 < 25000) {
      probes.push(await probe(page));
      b = await consoleText(page).catch(() => '');
      if (b.includes(STOP_MSG)) break;
      await sleep(1500);
    }
    check('page answered every probe while the worker slept', probes.length > 0 && probes.every((p) => p === 'ok'), probes.join(','));
    check('stop message shown with "before" intact', b.includes(STOP_MSG) && b.includes('before\n'), JSON.stringify(b.slice(0, 200)));
    check('Run is re-enabled', await page.evaluate(() => !document.querySelector('#run-btn').disabled));

    console.log('Test: 300 lines printed before a 15 s sleep all survive the stop');
    await startRun(page, burstProg(300, 15000));
    const t1 = Date.now();
    let d = '';
    while (Date.now() - t1 < 25000) {
      d = await consoleText(page).catch(() => '');
      if (d.includes(STOP_MSG)) break;
      await sleep(1500);
    }
    const lines = d.match(/^L\d+$/gm) || [];
    check('stop message shown', d.includes(STOP_MSG), JSON.stringify(d.slice(-200)));
    check('lines 1 to 300 intact',
      lines.length === 300 && lines[0] === 'L1' && lines[299] === 'L300' && lines.every((l, i) => l === `L${i + 1}`),
      `count=${lines.length} first=${lines[0]} last=${lines[lines.length - 1]}`);

    console.log('Test: a partial line printed before a 15 s sleep survives the stop');
    await startRun(page, partialProg(15000));
    const t2 = Date.now();
    let f = '';
    while (Date.now() - t2 < 25000) {
      f = await consoleText(page).catch(() => '');
      if (f.includes(STOP_MSG)) break;
      await sleep(1500);
    }
    check('stop message shown and the unterminated "partial" is intact', f.includes(STOP_MSG) && f.includes('partial'), JSON.stringify(f.slice(-200)));

    if (NOISO_URL) {
      console.log('Test: without isolation the first sleep is a named error');
      const p2 = await open(browser, NOISO_URL);
      check('page is NOT cross-origin isolated', !(await p2.evaluate(() => window.crossOriginIsolated)));
      await startRun(p2, prog([0], 200));
      await p2.waitForSelector('#run-btn:not([disabled])', { timeout: 15000 });
      await sleep(300);
      const c = await consoleText(p2);
      check('CapabilityError names the missing isolation, no hang', c.includes(ISOLATION_MSG) && !c.includes('after\n'), JSON.stringify(c.slice(-250)));
      console.log('  (c) console: ' + JSON.stringify(c));
    } else {
      console.log('Test: no-isolation case skipped (no third URL)');
    }
  } catch (e) {
    console.error('Harness error:', e.message);
    failures++;
  } finally {
    await browser.close();
  }
  console.log(failures === 0 ? '\nASYNC CHECKS PASSED' : `\n${failures} ASYNC CHECK(S) FAILED`);
  process.exit(failures === 0 ? 0 : 1);
}

main();
