#!/usr/bin/env node
'use strict';
/*
 * render.js — draw approximate "screenshots" of a Roblox game's 2D UI from JSON dumps.
 *
 *   node render.js <dump.json|dir> <outdir> [--scale 1] [--billboards over|under|off]
 *                  [--no-png] [--rects] [--jobs 4] [--offline-fonts]
 *
 * For each dump writes <outdir>/<checkpoint>-<w>x<h>.html (self-contained) and .png.
 */
const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');
const { collectFontNeeds, buildFonts } = require('./lib/fonts');
const { buildHtml } = require('./lib/page');

const USAGE = `usage: node render.js <dump.json|dir> <outdir> [options]

  --scale N             device pixel ratio of the PNG (default 1; 2 = retina-sharp)
  --billboards MODE     world-labels strip: over (default) | under the ScreenGuis | off
  --no-png              only write the HTML files
  --rects               also write <name>.rects.json with every object's absolute rect
  --jobs N              pages rendered in parallel (default 4)
  --offline-fonts       do not download fonts (system fallbacks only)
`;

function parseArgs(argv) {
  const o = { pos: [], scale: 1, billboards: 'over', png: true, rects: false, jobs: 4, offline: false };
  for (let i = 0; i < argv.length; i++) {
    let a = argv[i], v = null;
    const eq = a.indexOf('=');
    if (a.startsWith('--') && eq > 0) { v = a.slice(eq + 1); a = a.slice(0, eq); }
    const val = () => (v !== null ? v : argv[++i]);
    if (a === '--scale') o.scale = parseFloat(val());
    else if (a === '--billboards') o.billboards = val();
    else if (a === '--no-png') o.png = false;
    else if (a === '--rects') o.rects = true;
    else if (a === '--jobs' || a === '-j') o.jobs = Math.max(1, parseInt(val(), 10) || 1);
    else if (a === '--offline-fonts') o.offline = true;
    else if (a === '-h' || a === '--help') { process.stdout.write(USAGE); process.exit(0); }
    else if (a.startsWith('-')) { console.error(`unknown option ${a}\n\n${USAGE}`); process.exit(2); }
    else o.pos.push(a);
  }
  if (o.pos.length !== 2) { console.error(USAGE); process.exit(2); }
  if (!(o.scale > 0 && o.scale <= 4)) { console.error('--scale must be in (0, 4]'); process.exit(2); }
  if (!['over', 'under', 'off'].includes(o.billboards)) { console.error('--billboards must be over|under|off'); process.exit(2); }
  return o;
}

function loadPlaywright() {
  for (const m of ['playwright', '/opt/node-tools/node_modules/playwright', 'playwright-core']) {
    try { return require(m); } catch (e) { /* try next */ }
  }
  throw new Error('Playwright not found: set NODE_PATH to a node_modules containing playwright');
}

function listInputs(input) {
  const st = fs.statSync(input);
  if (!st.isDirectory()) return [input];
  return fs.readdirSync(input).filter((f) => f.toLowerCase().endsWith('.json') && !f.endsWith('.rects.json') && f !== 'index.json')
    .sort().map((f) => path.join(input, f));
}

// Lua encoders write an empty table as {} — make every children list an array.
function normalise(n) {
  if (!n || typeof n !== 'object') return;
  if (!Array.isArray(n.children)) n.children = n.children && typeof n.children === 'object' ? Object.values(n.children) : [];
  if (!n.props || Array.isArray(n.props)) n.props = {};
  if (!n.attrs || Array.isArray(n.attrs)) n.attrs = {};
  for (const c of n.children) normalise(c);
}

function loadDumps(file) {
  let data;
  try { data = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { throw new Error(`${file}: not valid JSON (${e.message})`); }
  const arr = Array.isArray(data) ? data : [data];
  return arr.map((d, i) => {
    if (!d || typeof d !== 'object' || !Array.isArray(d.roots)) throw new Error(`${file}: expected {checkpoint, viewport, roots:[...]}`);
    for (const r of d.roots) normalise(r);
    const vp = d.viewport || {};
    const w = Math.round(Number(vp.w) || 1920), h = Math.round(Number(vp.h) || 1080);
    const base = path.basename(file, path.extname(file));
    const checkpoint = String(d.checkpoint || (arr.length > 1 ? `${base}-${i + 1}` : base));
    return { file, dump: Object.assign({}, d, { checkpoint, viewport: { w, h } }) };
  });
}

const safeName = (s) => s.replace(/[^\w.-]+/g, '_');

async function main() {
  const opt = parseArgs(process.argv.slice(2));
  const [input, outdir] = opt.pos;
  fs.mkdirSync(outdir, { recursive: true });
  const jobs = [];
  for (const f of listInputs(input)) {
    try { jobs.push(...loadDumps(f)); } catch (e) { console.error(`error: ${e.message}`); process.exitCode = 1; }
  }
  if (!jobs.length) { console.error('no dumps to render'); process.exit(1); }

  // 1) build the HTML pages (fonts are downloaded once and cached in .font-cache/)
  for (const j of jobs) {
    const needs = collectFontNeeds(j.dump);
    const fonts = await buildFonts(needs, { offline: opt.offline });
    const sample = [...new Set([...'AaBbGgQq0123456789', ...needs.chars])].join('');
    const cfg = { fontMap: fonts.map, faces: fonts.faces, sample, billboards: opt.billboards, rects: opt.rects };
    const { w, h } = j.dump.viewport;
    j.name = `${safeName(j.dump.checkpoint)}-${w}x${h}`;
    j.html = path.join(outdir, j.name + '.html');
    j.png = path.join(outdir, j.name + '.png');
    j.fontWarnings = fonts.warnings;
    fs.writeFileSync(j.html, buildHtml({ dump: j.dump, fontCss: fonts.css, cfg }));
  }
  if (!opt.png && !opt.rects) {
    for (const j of jobs) console.log(`html  ${j.html}`);
    return;
  }

  // 2) render each page in Chromium and screenshot it
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch();
  let failures = 0;
  const queue = jobs.slice();
  async function worker() {
    for (let j = queue.shift(); j; j = queue.shift()) {
      const t0 = Date.now();
      const { w, h } = j.dump.viewport;
      const ctx = await browser.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: opt.scale });
      const page = await ctx.newPage();
      const pageErrors = [];
      page.on('pageerror', (e) => pageErrors.push(e.message));
      try {
        await page.goto(pathToFileURL(path.resolve(j.html)).href);
        await page.waitForFunction(() => window.__PREVIEW__ && window.__PREVIEW__.done, null, { timeout: 120000 });
        const res = await page.evaluate(() => window.__PREVIEW__);
        if (res.error) throw new Error(res.error);
        if (opt.png) await page.screenshot({ path: j.png, clip: { x: 0, y: 0, width: w, height: h } });
        if (opt.rects && res.rects) fs.writeFileSync(path.join(outdir, j.name + '.rects.json'), JSON.stringify(res.rects, null, 1));
        const s = res.stats;
        console.log(`ok    ${j.name}: ${s.guiObjects} GUI objects, ${s.screenGuis} ScreenGuis, ${s.billboards} billboards; ` +
          `layout ${s.layoutMs} ms, total ${Date.now() - t0} ms -> ${opt.png ? j.png : j.html}`);
        const warns = [...j.fontWarnings, ...res.warnings, ...pageErrors];
        warns.slice(0, 25).forEach((m) => console.log(`  !   ${m}`));
        if (warns.length > 25) console.log(`  !   ... ${warns.length - 25} more warnings`);
      } catch (e) {
        failures++;
        console.error(`FAIL  ${j.name}: ${e.message.split('\n')[0]}`);
        pageErrors.forEach((m) => console.error(`  !   ${m}`));
      } finally {
        await ctx.close();
      }
    }
  }
  await Promise.all(Array.from({ length: Math.min(opt.jobs, jobs.length) }, worker));
  await browser.close();
  if (failures) process.exitCode = 1;
}

main().catch((e) => { console.error(e.stack || String(e)); process.exit(1); });
