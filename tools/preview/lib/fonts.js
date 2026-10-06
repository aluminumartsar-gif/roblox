'use strict';
/*
 * fonts.js — figures out which web fonts a dump needs, downloads them once into
 * .font-cache/ (Google Fonts CSS2 API, falling back to raw TTFs from github.com/google/fonts),
 * and returns @font-face rules with the font data inlined so each HTML file is self-contained.
 */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFile } = require('child_process');
const FM = require('./fontmap');

const CACHE = path.join(__dirname, '..', '.font-cache');
const UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36';
const TEXT_CLASSES = new Set(['TextLabel', 'TextButton', 'TextBox']);

function sha(s) { return crypto.createHash('sha1').update(s).digest('hex').slice(0, 16); }

function curl(url) {
  return new Promise((resolve, reject) => {
    execFile('curl', ['-sS', '-L', '--fail', '--max-time', '30', '-A', UA, url],
      { encoding: 'buffer', maxBuffer: 64 * 1024 * 1024 }, (err, stdout, stderr) => {
        if (err) {
          if (err.code === 'ENOENT') return reject(Object.assign(new Error('curl not found'), { noCurl: true }));
          return reject(new Error(`GET ${url}: ${String(stderr || err.message).trim()}`));
        }
        resolve(stdout);
      });
  });
}

async function httpGet(url) {
  try {
    return await curl(url);
  } catch (e) {
    if (!e.noCurl) throw e;
    const r = await fetch(url, { headers: { 'user-agent': UA } });
    if (!r.ok) throw new Error(`GET ${url}: HTTP ${r.status}`);
    return Buffer.from(await r.arrayBuffer());
  }
}

/** Cached GET; returns Buffer or null on failure (failures are cached for this process only). */
const failed = new Set();
async function cachedGet(url, ext) {
  const file = path.join(CACHE, 'http', sha(url) + ext);
  if (fs.existsSync(file)) return fs.readFileSync(file);
  if (failed.has(url)) return null;
  try {
    const buf = await httpGet(url);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, buf);
    return buf;
  } catch (e) {
    failed.add(url);
    return null;
  }
}

// ---------------------------------------------------------------- needs

/** Walk a dump and record every (family key, weight, italic) its text could use, plus all characters. */
function collectFontNeeds(dump, acc) {
  acc = acc || { combos: new Map(), chars: new Set() };
  const add = (key, weight, italic) => {
    const id = `${key}|${weight}|${italic ? 1 : 0}`;
    if (!acc.combos.has(id)) acc.combos.set(id, { key, weight, italic: !!italic });
  };
  const walk = (n) => {
    if (!n || typeof n !== 'object') return;
    const p = n.props || {};
    if (TEXT_CLASSES.has(n.class) || p.FontFace) {
      const base = FM.decodeFont(p.FontFace, p.Font);
      add(base.key, base.weight, base.italic);
      const text = [p.Text, p.PlaceholderText].filter((t) => typeof t === 'string').join('');
      for (const ch of text) acc.chars.add(ch);
      if (p.RichText && /</.test(text)) {
        const keys = new Set([base.key]);
        const weights = new Set([base.weight]);
        const italics = new Set([base.italic]);
        if (/<b>/i.test(text)) weights.add(700);
        if (/<i>/i.test(text)) italics.add(true);
        const tagRe = /<font\b([^>]*)>/gi;
        let m;
        while ((m = tagRe.exec(text))) {
          const attrs = m[1];
          const face = /\b(?:face|family)\s*=\s*["']([^"']+)["']/i.exec(attrs);
          if (face) {
            const f = FM.decodeFace(face[1]);
            keys.add(f.key);
            if (f.weight) weights.add(f.weight);
          }
          const wt = /\bweight\s*=\s*["']([^"']+)["']/i.exec(attrs);
          if (wt) weights.add(FM.weightNum(wt[1], 400));
        }
        for (const k of keys) for (const w of weights) for (const it of italics) add(k, w, it);
      }
    }
    for (const c of n.children || []) walk(c);
  };
  for (const r of dump.roots || []) walk(r);
  return acc;
}

// ---------------------------------------------------------------- google fonts

function parseFontCss(css) {
  const out = [];
  const re = /(?:\/\*\s*([\w-]+)\s*\*\/\s*)?@font-face\s*{([^}]*)}/g;
  let m;
  while ((m = re.exec(css))) {
    const body = m[2];
    const get = (prop) => { const r = new RegExp(prop + '\\s*:\\s*([^;]+);').exec(body); return r ? r[1].trim() : null; };
    const src = /url\(([^)]+)\)/.exec(body);
    if (!src) continue;
    out.push({
      subset: m[1] || 'all', family: (get('font-family') || '').replace(/['"]/g, ''),
      style: get('font-style') || 'normal', weight: get('font-weight') || '400',
      url: src[1].replace(/['"]/g, ''), unicodeRange: get('unicode-range'),
    });
  }
  return out;
}

function rangeHits(range, codepoints) {
  if (!range) return true;
  const parts = range.split(',').map((s) => s.trim().replace(/^U\+/i, ''));
  for (const part of parts) {
    let lo, hi;
    if (part.includes('-')) { const [a, b] = part.split('-'); lo = parseInt(a, 16); hi = parseInt(b, 16); }
    else if (part.includes('?')) { lo = parseInt(part.replace(/\?/g, '0'), 16); hi = parseInt(part.replace(/\?/g, 'F'), 16); }
    else { lo = hi = parseInt(part, 16); }
    for (const cp of codepoints) if (cp >= lo && cp <= hi) return true;
  }
  return false;
}

function cssUrl(family, tuples, hasItalic) {
  const fam = family.replace(/ /g, '+');
  if (tuples.length === 1 && tuples[0].w === 400 && !tuples[0].i) return `https://fonts.googleapis.com/css2?family=${fam}&display=block`;
  let spec;
  if (hasItalic) spec = ':ital,wght@' + tuples.map((t) => `${t.i ? 1 : 0},${t.w}`).sort().join(';');
  else spec = ':wght@' + [...new Set(tuples.map((t) => t.w))].sort((a, b) => a - b).join(';');
  return `https://fonts.googleapis.com/css2?family=${fam}${spec}&display=block`;
}

async function googleFaces(family, tuples, hasItalic, codepoints) {
  let css = await cachedGet(cssUrl(family, tuples, hasItalic), '.css');
  if (!css) {
    // unknown availability: probe each tuple separately, then plain regular
    const parts = [];
    for (const t of tuples) { const c = await cachedGet(cssUrl(family, [t], hasItalic), '.css'); if (c) parts.push(c.toString()); }
    if (!parts.length) { const c = await cachedGet(cssUrl(family, [{ w: 400, i: false }], false), '.css'); if (c) parts.push(c.toString()); }
    if (!parts.length) return null;
    css = Buffer.from(parts.join('\n'));
  }
  const faces = parseFontCss(css.toString()).filter((f) => f.subset === 'latin' || f.subset === 'latin-ext' || f.subset === 'all' || rangeHits(f.unicodeRange, codepoints));
  const out = [];
  for (const f of faces) {
    const buf = await cachedGet(f.url, '.woff2');
    if (!buf) continue;
    out.push({ family, style: f.style, weight: f.weight, unicodeRange: f.unicodeRange, format: 'woff2', mime: 'font/woff2', data: buf });
  }
  return out.length ? out : null;
}

// ---------------------------------------------------------------- github fallback

const WEIGHT_NAMES = { 100: 'Thin', 200: 'ExtraLight', 300: 'Light', 400: 'Regular', 500: 'Medium', 600: 'SemiBold', 700: 'Bold', 800: 'ExtraBold', 900: 'Black' };
const AXES = ['[wght]', '[wdth,wght]', '[opsz,wght]', '[opsz,wdth,wght]', '[ital,wght]'];

async function githubFaces(family, tuples) {
  const dir = family.toLowerCase().replace(/[^a-z0-9]/g, '');
  const base = family.replace(/ /g, '');
  const out = [];
  for (const lic of ['ofl', 'apache', 'ufl']) {
    const root = `https://raw.githubusercontent.com/google/fonts/main/${lic}/${dir}/`;
    // variable fonts first: one file covers every weight
    let gotVar = false;
    for (const italic of [false, true]) {
      if (italic && !tuples.some((t) => t.i)) continue;
      for (const ax of AXES) {
        const name = `${base}${italic ? '-Italic' : ''}${ax}.ttf`;
        const buf = await cachedGet(root + encodeURIComponent(name), '.ttf');
        if (buf) { out.push({ family, style: italic ? 'italic' : 'normal', weight: '100 900', data: buf, format: 'truetype', mime: 'font/ttf' }); gotVar = true; break; }
      }
    }
    if (!gotVar) {
      for (const t of tuples) {
        const wn = WEIGHT_NAMES[t.w] || 'Regular';
        const name = `${base}-${t.i ? (wn === 'Regular' ? 'Italic' : wn + 'Italic') : wn}.ttf`;
        const buf = await cachedGet(root + name, '.ttf');
        if (buf) out.push({ family, style: t.i ? 'italic' : 'normal', weight: String(t.w), data: buf, format: 'truetype', mime: 'font/ttf' });
      }
    }
    if (out.length) return out;
  }
  return null;
}

// ---------------------------------------------------------------- public

/**
 * Resolve font needs into embeddable faces.
 * Returns { css, faces:[{family,weight,style}], map:{key:cssFamily}, warnings:[] }.
 */
async function buildFonts(needs, opts = {}) {
  const warnings = [];
  const map = {};
  const byFamily = new Map(); // google family -> Map(id -> {w,i})
  const codepoints = [...needs.chars].map((c) => c.codePointAt(0));
  for (const { key, weight, italic } of needs.combos.values()) {
    let fam = FM.FAMILY[key];
    if (!fam) {
      fam = FM.FALLBACK_FAMILY;
      warnings.push(`unknown font family "${key}" -> using ${fam}`);
    }
    map[key] = fam;
    const info = FM.GOOGLE[fam] || { w: [400], i: false, unknown: true };
    const w = info.unknown ? weight : FM.matchWeight(info.w, weight);
    const i = !!(italic && info.i);
    if (!byFamily.has(fam)) byFamily.set(fam, new Map());
    byFamily.get(fam).set(`${w}|${i}`, { w, i });
  }
  // always have the fallback family available for stray rich-text faces
  if (!byFamily.has(FM.FALLBACK_FAMILY)) byFamily.set(FM.FALLBACK_FAMILY, new Map([['400|false', { w: 400, i: false }]]));

  const rules = [];
  const faces = [];
  for (const [fam, tmap] of byFamily) {
    const tuples = [...tmap.values()];
    const info = FM.GOOGLE[fam] || { i: true };
    const skipGoogle = process.env.PREVIEW_FONT_SOURCE === 'github'; // testing aid for the fallback path
    let got = opts.offline || skipGoogle ? null : await googleFaces(fam, tuples, !!info.i, codepoints);
    if (!got && !opts.offline) {
      got = await githubFaces(fam, tuples);
      if (got) warnings.push(`Google Fonts unreachable for ${fam}; used TTF from github.com/google/fonts`);
    }
    if (!got) { warnings.push(`could not download font ${fam}; the browser will substitute a system font`); continue; }
    for (const f of got) {
      rules.push(`@font-face{font-family:'${f.family}';font-style:${f.style};font-weight:${f.weight};font-display:block;` +
        `src:url(data:${f.mime};base64,${f.data.toString('base64')}) format('${f.format}');` +
        (f.unicodeRange ? `unicode-range:${f.unicodeRange};` : '') + '}');
    }
    for (const t of tuples) faces.push({ family: fam, weight: t.w, style: t.i ? 'italic' : 'normal' });
  }
  return { css: rules.join('\n'), faces, map, warnings };
}

module.exports = { collectFontNeeds, buildFonts, CACHE };
