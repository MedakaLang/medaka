#!/usr/bin/env node
// Drive the real playground page in system Chrome over every battery program.
// usage: node browser_battery.mjs <baseUrl> <batteryDir> <outDir> [onlyGlobSubstring]
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
const require = createRequire('/root/medaka/.claude/worktrees/swirling-munching-kahn/playground/e2e/package.json');
const { chromium } = require('playwright');

const [baseUrl, batteryDir, outDir, only] = process.argv.slice(2);
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
  // Wait until the console changes AND the run button is re-enabled (run finished),
  // or 45s.
  let text = before, done = false;
  while (Date.now() - t0 < 45000) {
    await page.waitForTimeout(250);
    text = await page.$eval('#console', (el) => el.textContent);
    const enabled = await page.$eval('#run-btn', (el) => !el.disabled);
    if (text !== before && enabled) { done = true; break; }
  }
  // give any late tail output a moment
  await page.waitForTimeout(300);
  text = await page.$eval('#console', (el) => el.textContent);
  const ms = Date.now() - t0;
  const body = `[${name}] done=${done} wall=${ms}ms\n--- console:\n${text.trim()}\n` + (pageErrors.length ? `--- page errors:\n${pageErrors.join('\n')}\n` : '');
  fs.writeFileSync(path.join(outDir, name + '.browser.txt'), body);
  summary.push(`${name}\t${done ? 'ok' : 'TIMEOUT'}\t${ms}\t${pageErrors.length}`);
  process.stderr.write(summary[summary.length - 1] + '\n');
}
fs.writeFileSync(path.join(outDir, 'browser_summary.tsv'), summary.join('\n') + '\n');
await browser.close();
