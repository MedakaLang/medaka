#!/usr/bin/env node
// browser_battery.mjs — run every battery program on the REAL playground page in
// system Chrome: set the editor buffer, click Run, capture the console pane.
// This is the arm a visitor actually experiences (the compile runs in the page's
// Web Worker, with its stack), so it can disagree with pg_compile.mjs in node.
//
// Usage: node test/visitor_battery/tools/browser_battery.mjs <baseUrl> [OUT_DIR] [nameSubstring]
//   e.g. node test/visitor_battery/tools/browser_battery.mjs https://medaka-lang.dev/
//        node test/visitor_battery/tools/browser_battery.mjs http://localhost:8099/ results/browser 17_
// Needs the Playwright driver: `npm --prefix playground/e2e install` (system
// Chrome is launched, never a Playwright-managed download — see playground/e2e/README.md).
// Output: OUT_DIR/<program>.browser.txt and OUT_DIR/browser_summary.tsv
//         (program, ok|TIMEOUT, wall ms, page-error count).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../../..');
const require = createRequire(path.join(root, 'playground/e2e/package.json'));
const { chromium } = require('playwright');

const [baseUrl, outArg, only] = process.argv.slice(2);
if (!baseUrl) { console.error('usage: browser_battery.mjs <baseUrl> [OUT_DIR] [nameSubstring]'); process.exit(2); }
const batteryDir = path.resolve(here, '..');
const outDir = outArg ? path.resolve(outArg) : path.join(batteryDir, 'results', 'browser');
fs.mkdirSync(outDir, { recursive: true });
const files = fs.readdirSync(batteryDir).filter((f) => f.endsWith('.mdk') && (!only || f.includes(only))).sort();

const browser = await chromium.launch({ channel: 'chrome' });
const page = await browser.newPage();
const pageErrors = [];
page.on('pageerror', (e) => pageErrors.push(String(e)));
page.on('console', (m) => { if (m.type() === 'error') pageErrors.push('console.error: ' + m.text()); });
await page.goto(baseUrl, { waitUntil: 'load' });
await page.waitForSelector('.cm-editor .cm-content', { timeout: 30000 });
await page.waitForSelector('#run-btn:not([disabled])', { timeout: 60000 });

const summary = [];
for (const f of files) {
  const name = f.replace(/\.mdk$/, '');
  const src = fs.readFileSync(path.join(batteryDir, f), 'utf8');
  pageErrors.length = 0;
  await page.evaluate((s) => {
    const v = window.__mdkView;
    v.dispatch({ changes: { from: 0, to: v.state.doc.length, insert: s } });
  }, src);
  await page.waitForSelector('#run-btn:not([disabled])', { timeout: 30000 });
  const before = await page.$eval('#console', (el) => el.textContent);
  const t0 = Date.now();
  await page.click('#run-btn');
  // Done when the console changed AND the Run button is enabled again, or 45 s.
  let text = before, done = false;
  while (Date.now() - t0 < 45000) {
    await page.waitForTimeout(250);
    text = await page.$eval('#console', (el) => el.textContent);
    const enabled = await page.$eval('#run-btn', (el) => !el.disabled);
    if (text !== before && enabled) { done = true; break; }
  }
  await page.waitForTimeout(300);
  text = await page.$eval('#console', (el) => el.textContent);
  const ms = Date.now() - t0;
  const body = `[${name}] done=${done} wall=${ms}ms\n--- console:\n${text.trim()}\n`
    + (pageErrors.length ? `--- page errors:\n${pageErrors.join('\n')}\n` : '');
  fs.writeFileSync(path.join(outDir, name + '.browser.txt'), body);
  summary.push(`${name}\t${done ? 'ok' : 'TIMEOUT'}\t${ms}\t${pageErrors.length}`);
  process.stderr.write(summary[summary.length - 1] + '\n');
}
fs.writeFileSync(path.join(outDir, 'browser_summary.tsv'), summary.join('\n') + '\n');
await browser.close();
