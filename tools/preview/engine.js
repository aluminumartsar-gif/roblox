/*
 * engine.js — runs inside the preview page (Chromium or any modern browser).
 *
 * Reads the embedded dump (#rbx-dump) and config (#rbx-cfg), computes Roblox-style
 * absolute rects for every GuiObject itself (UDim2 + AnchorPoint, UIPadding, UIListLayout,
 * UIGridLayout, AutomaticSize, constraints, UIScale, ScrollingFrame canvases), measures text
 * with canvas measureText once the web fonts are loaded, then emits a flat list of absolutely
 * positioned divs in Roblox paint order (DisplayOrder, then ZIndex with Sibling/Global rules).
 *
 * When finished it sets window.__PREVIEW__ = { done, warnings, stats, rects? }.
 */
(function () {
  'use strict';

  const FM = window.RBXFONTS;
  const DUMP = JSON.parse(document.getElementById('rbx-dump').textContent);
  const CFG = JSON.parse(document.getElementById('rbx-cfg').textContent);

  const warnings = [];
  const warned = new Set();
  function warn(m) { if (!warned.has(m)) { warned.add(m); warnings.push(m); } }

  // ------------------------------------------------------------------ values

  const isNum = (v) => typeof v === 'number' && isFinite(v);
  function num(v, d) {
    if (isNum(v)) return v;
    if (typeof v === 'string' && v.trim() !== '' && isFinite(+v)) return +v;
    return d;
  }
  const bool = (v, d) => (typeof v === 'boolean' ? v : d);
  const str = (v, d) => (typeof v === 'string' ? v : d);
  function en(v, d) {
    if (v == null) return d;
    if (typeof v === 'string') { const i = v.lastIndexOf('.'); return i >= 0 ? v.slice(i + 1) : v; }
    if (typeof v === 'object' && typeof v.name === 'string') return v.name;
    return d;
  }
  const Z2 = { xs: 0, xo: 0, ys: 0, yo: 0 };
  function U2(v, d) {
    if (!v || typeof v !== 'object') return d || Z2;
    if (Array.isArray(v)) return { xs: +v[0] || 0, xo: +v[1] || 0, ys: +v[2] || 0, yo: +v[3] || 0 };
    return { xs: num(v.xs, 0), xo: num(v.xo, 0), ys: num(v.ys, 0), yo: num(v.yo, 0) };
  }
  function UD(v, d) {
    if (!v || typeof v !== 'object') return d || { s: 0, o: 0 };
    return { s: num(v.s, 0), o: num(v.o, 0) };
  }
  function V2(v, dx, dy) {
    if (!v || typeof v !== 'object') return { x: dx, y: dy };
    return { x: num(v.x, dx), y: num(v.y, dy) };
  }
  const clamp = (x, a, b) => Math.max(a, Math.min(b, x));
  const clamp01 = (x) => clamp(x, 0, 1);
  function C3(v, d) {
    if (!v || typeof v !== 'object') return d;
    return { r: clamp01(num(v.r, 0)), g: clamp01(num(v.g, 0)), b: clamp01(num(v.b, 0)) };
  }
  const rgb255 = (r, g, b) => ({ r: r / 255, g: g / 255, b: b / 255 });
  function rgba(c, a) {
    return `rgba(${Math.round(c.r * 255)},${Math.round(c.g * 255)},${Math.round(c.b * 255)},${+clamp01(a).toFixed(3)})`;
  }
  const mulC = (a, b) => ({ r: a.r * b.r, g: a.g * b.g, b: a.b * b.b });
  const px = (v) => +v.toFixed(2) + 'px';
  function esc(s) { return s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }

  function colorSeq(v) {
    if (v && Array.isArray(v.kps) && v.kps.length) {
      return v.kps.map((k) => ({ t: num(k.time, 0), r: clamp01(num(k.r, 1)), g: clamp01(num(k.g, 1)), b: clamp01(num(k.b, 1)) }))
        .sort((a, b) => a.t - b.t);
    }
    if (v && v.t === 'Color3') { const c = C3(v, { r: 1, g: 1, b: 1 }); return [{ t: 0, ...c }, { t: 1, ...c }]; }
    return [{ t: 0, r: 1, g: 1, b: 1 }, { t: 1, r: 1, g: 1, b: 1 }];
  }
  function numSeq(v, d) {
    if (v && Array.isArray(v.kps) && v.kps.length) {
      return v.kps.map((k) => ({ t: num(k.time, 0), v: num(k.value, d) })).sort((a, b) => a.t - b.t);
    }
    if (isNum(v)) return [{ t: 0, v }, { t: 1, v }];
    return [{ t: 0, v: d }, { t: 1, v: d }];
  }
  function sample(seq, t, keys) {
    if (t <= seq[0].t) return seq[0];
    const last = seq[seq.length - 1];
    if (t >= last.t) return last;
    for (let i = 1; i < seq.length; i++) {
      const b = seq[i];
      if (t <= b.t) {
        const a = seq[i - 1];
        const f = b.t - a.t > 1e-9 ? (t - a.t) / (b.t - a.t) : 0;
        const o = {};
        for (const k of keys) o[k] = a[k] + (b[k] - a[k]) * f;
        return o;
      }
    }
    return last;
  }

  // ------------------------------------------------------------------ tree

  const GUI = new Set(['Frame', 'ScrollingFrame', 'CanvasGroup', 'TextLabel', 'TextButton', 'TextBox',
    'ImageLabel', 'ImageButton', 'ViewportFrame', 'VideoFrame']);
  const TEXT = new Set(['TextLabel', 'TextButton', 'TextBox']);
  const IMAGE = new Set(['ImageLabel', 'ImageButton']);
  const LAYOUTS = new Set(['UIListLayout', 'UIGridLayout', 'UIPageLayout', 'UITableLayout']);
  const MODS = new Set(['UIPadding', 'UICorner', 'UIStroke', 'UIGradient', 'UIScale', 'UIAspectRatioConstraint',
    'UISizeConstraint', 'UITextSizeConstraint', 'UIFlexItem', ...LAYOUTS]);
  const IGNORED_SILENT = new Set(['LocalScript', 'Script', 'ModuleScript', 'StringValue', 'NumberValue', 'IntValue',
    'BoolValue', 'ObjectValue', 'Color3Value', 'Configuration', 'Sound', 'UIDragDetector', 'BindableEvent',
    'RemoteEvent', 'Camera', 'WorldModel', 'Model', 'Part', 'MeshPart', 'Highlight', 'Attachment']);

  let elCount = 0;
  function hasGuiDescendant(n) {
    for (const c of n.children || []) if (GUI.has(c.class) || hasGuiDescendant(c)) return true;
    return false;
  }
  function makeEl(node, parent, viaFolder, path) {
    const el = {
      node, cls: node.class, name: str(node.name, ''), p: node.props || {}, a: node.attrs || {},
      parent, viaFolder, kids: [], mods: { strokes: [] }, cache: new Map(), idx: 0,
      path: path ? path + '.' + str(node.name, '?') : str(node.name, '?'),
    };
    if (GUI.has(el.cls)) elCount++;
    for (const c of node.children || []) attach(el, c, false);
    el.kids.forEach((k, i) => { k.idx = i; });
    return el;
  }
  function attach(el, c, viaFolder) {
    if (!c || typeof c !== 'object') return;
    const cls = c.class;
    if (GUI.has(cls)) el.kids.push(makeEl(c, el, viaFolder, el.path));
    else if (cls === 'Folder') for (const cc of c.children || []) attach(el, cc, true);
    else if (MODS.has(cls)) {
      const p = c.props || {};
      const sub = (name) => (c.children || []).find((x) => x.class === name);
      if (cls === 'UIStroke') el.mods.strokes.push({ p, grad: sub('UIGradient') ? sub('UIGradient').props || {} : null });
      else if (LAYOUTS.has(cls)) {
        if (!el.mods.layout) {
          const ar = sub('UIAspectRatioConstraint');
          el.mods.layout = { cls, p, aspect: ar ? ar.props || {} : null };
          if (cls === 'UITableLayout') warn('UITableLayout is approximated as a UIListLayout');
        }
      } else if (!el.mods[cls]) el.mods[cls] = p;
    } else if (!IGNORED_SILENT.has(cls) && hasGuiDescendant(c)) {
      warn(`ignored ${cls} "${c.name}" and the GUI objects inside it (not rendered by Roblox either)`);
    }
  }
  const visible = (el) => bool(el.p.Visible, true);
  const uiScale = (el) => (el.mods.UIScale ? Math.max(0, num(el.mods.UIScale.Scale, 1)) : 1);

  // ------------------------------------------------------------------ geometry

  const AL = { Left: 0, Top: 0, Center: 0.5, Right: 1, Bottom: 1 };
  const ZP = { l: 0, r: 0, t: 0, b: 0 };
  function padOf(el, w, h, k) {
    const P = el.mods.UIPadding;
    if (!P) return ZP;
    const L = UD(P.PaddingLeft), R = UD(P.PaddingRight), T = UD(P.PaddingTop), B = UD(P.PaddingBottom);
    return { l: w * L.s + L.o * k, r: w * R.s + R.o * k, t: h * T.s + T.o * k, b: h * B.s + B.o * k };
  }
  function innerOf(box, pad) {
    return { x: box.x + pad.l, y: box.y + pad.t, w: Math.max(0, box.w - pad.l - pad.r), h: Math.max(0, box.h - pad.t - pad.b) };
  }
  function autoAxes(el) {
    const a = en(el.p.AutomaticSize, 'None');
    return { ax: a === 'X' || a === 'XY', ay: a === 'Y' || a === 'XY' };
  }
  function baseSize(el, pw, ph, k) {
    const s = U2(el.p.Size);
    let bx = pw, by = ph;
    const sc = en(el.p.SizeConstraint, 'RelativeXY');
    if (sc === 'RelativeXX') by = pw; else if (sc === 'RelativeYY') bx = ph;
    return { w: bx * s.xs + s.xo * k, h: by * s.ys + s.yo * k };
  }
  function applyConstraints(el, w, h, k) {
    const SC = el.mods.UISizeConstraint;
    if (SC) {
      const mn = V2(SC.MinSize, 0, 0), mx = V2(SC.MaxSize, Infinity, Infinity);
      w = clamp(w, mn.x * k, Math.max(mn.x * k, mx.x * k));
      h = clamp(h, mn.y * k, Math.max(mn.y * k, mx.y * k));
    }
    const AR = el.mods.UIAspectRatioConstraint;
    if (AR) {
      const r = num(AR.AspectRatio, 1) || 1;
      const type = en(AR.AspectType, 'FitWithinMaxSize');
      const dom = en(AR.DominantAxis, 'Width');
      if (type === 'ScaleWithParentSize') { if (dom === 'Width') h = w / r; else w = h * r; }
      else if (w / Math.max(h, 1e-9) > r) w = h * r; else h = w / r;
    }
    return { w: Math.max(0, w), h: Math.max(0, h) };
  }
  /** Final (pre-UIScale) size of el inside a parent content box of pw x ph at offset multiplier k. */
  function measure(el, pw, ph, k) {
    const key = pw.toFixed(3) + ',' + ph.toFixed(3) + ',' + k;
    let r = el.cache.get(key);
    if (r) return r;
    const b = baseSize(el, pw, ph, k);
    let w = Math.max(0, b.w), h = Math.max(0, b.h);
    const { ax, ay } = autoAxes(el);
    if (ax || ay) {
      const s = uiScale(el) || 1;
      const ce = contentExtent(el, w * s, h * s, k * s, ax, ay, k);
      if (ax) w = Math.max(w, ce.w / s);
      if (ay) h = Math.max(h, ce.h / s);
    }
    r = applyConstraints(el, w, h, k);
    el.cache.set(key, r);
    return r;
  }
  /** Rect of child c (screen space, after c's UIScale about its anchor) inside content box `box`. */
  function childRect(c, box, k) {
    const sz = measure(c, box.w, box.h, k);
    const s = uiScale(c);
    const pos = U2(c.p.Position), ap = V2(c.p.AnchorPoint, 0, 0);
    const ax = box.x + box.w * pos.xs + pos.xo * k, ay = box.y + box.h * pos.ys + pos.yo * k;
    return { x: ax - ap.x * sz.w * s, y: ay - ap.y * sz.h * s, w: sz.w * s, h: sz.h * s };
  }
  /** Size of el's content (text bounds / layout run / children extents) incl. padding, for AutomaticSize. */
  function contentExtent(el, W, H, kc, ax, ay, kParent) {
    const pad = padOf(el, W, H, kc);
    const inner = { x: 0, y: 0, w: Math.max(0, W - pad.l - pad.r), h: Math.max(0, H - pad.t - pad.b) };
    let cw = 0, ch = 0;
    if (TEXT.has(el.cls) && !bool(el.p.TextScaled, false)) {
      let maxW = inner.w;
      if (ax) {
        const SC = el.mods.UISizeConstraint;
        const mx = SC ? V2(SC.MaxSize, Infinity, Infinity).x * kc : Infinity;
        maxW = isFinite(mx) ? Math.max(0, mx - pad.l - pad.r) : Infinity;
      }
      const tl = layoutText(el, maxW, inner.h, kc, true);
      if (tl) { cw = tl.w; ch = tl.h; }
    }
    const L = el.mods.layout;
    if (L) {
      const run = runLayout(el, L, inner, kc);
      cw = Math.max(cw, run.cw);
      ch = Math.max(ch, run.ch);
    }
    for (const c of el.kids) {
      if (!visible(c) || (L && !c.viaFolder)) continue;
      const r = childRect(c, inner, kc);
      cw = Math.max(cw, r.x + r.w);
      ch = Math.max(ch, r.y + r.h);
    }
    return { w: cw + pad.l + pad.r, h: ch + pad.t + pad.b };
  }

  // ------------------------------------------------------------------ layouts

  function sortedKids(el, p) {
    const kids = el.kids.filter((c) => !c.viaFolder && visible(c));
    const so = en(p.SortOrder, 'LayoutOrder');
    const byName = (a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
    if (so === 'LayoutOrder') kids.sort((a, b) => (num(a.p.LayoutOrder, 0) - num(b.p.LayoutOrder, 0)) || byName(a, b) || a.idx - b.idx);
    else if (so === 'Name') kids.sort((a, b) => byName(a, b) || a.idx - b.idx);
    return kids;
  }
  function runLayout(el, L, box, k) {
    if (L.cls === 'UIGridLayout') return gridLayout(el, L, box, k);
    return listLayout(el, L, box, k);
  }
  function flexMode(fi) { return fi ? en(fi.FlexMode, 'None') : 'None'; }

  function listLayout(el, L, box, k) {
    const p = L.p;
    const isPage = L.cls === 'UIPageLayout';
    const horiz = en(p.FillDirection, isPage ? 'Horizontal' : 'Vertical') === 'Horizontal';
    const ha = AL[en(p.HorizontalAlignment, isPage ? 'Center' : 'Left')] ?? 0;
    const va = AL[en(p.VerticalAlignment, isPage ? 'Center' : 'Top')] ?? 0;
    const mainA = horiz ? ha : va, crossA = horiz ? va : ha;
    const padU = UD(p.Padding);
    const mainSize = horiz ? box.w : box.h, crossSize = horiz ? box.h : box.w;
    const gap = mainSize * padU.s + padU.o * k;
    const wraps = bool(p.Wraps, false);
    const mainFlex = en(horiz ? p.HorizontalFlex : p.VerticalFlex, 'None');
    const crossFlex = en(horiz ? p.VerticalFlex : p.HorizontalFlex, 'None');
    const ila = en(p.ItemLineAlignment, 'Automatic');
    const items = sortedKids(el, p).map((c) => {
      const sz = measure(c, box.w, box.h, k);
      const s = uiScale(c);
      const fi = flexMode(c.mods.UIFlexItem) !== 'None' ? c.mods.UIFlexItem : null;
      return { c, main: (horiz ? sz.w : sz.h) * s, cross: (horiz ? sz.h : sz.w) * s, fi };
    });
    const lines = [];
    let cur = [], used = 0;
    for (const it of items) {
      const add = (cur.length ? gap : 0) + it.main;
      if (wraps && cur.length && used + add > mainSize + 0.01) { lines.push(cur); cur = []; used = 0; }
      used += (cur.length ? gap : 0) + it.main;
      cur.push(it);
    }
    if (cur.length) lines.push(cur);

    const infos = lines.map((line) => {
      const sum = () => line.reduce((a, it) => a + it.main, 0) + gap * Math.max(0, line.length - 1);
      let total = sum();
      let free = mainSize - total;
      const flexers = line.filter((it) => it.fi);
      if (flexers.length || mainFlex === 'Fill') {
        const parts = flexers.length ? flexers : line;
        if (free > 0) {
          const wts = parts.map((it) => {
            const m = flexMode(it.fi);
            if (!it.fi) return 1;
            if (m === 'Grow' || m === 'Fill') return 1;
            if (m === 'Custom') return Math.max(0, num(it.fi.GrowRatio, 0));
            return 0;
          });
          const tw = wts.reduce((a, b) => a + b, 0);
          if (tw > 0) parts.forEach((it, i) => { it.main += free * wts[i] / tw; });
        } else if (free < 0) {
          const wts = parts.map((it) => {
            const m = flexMode(it.fi);
            let r = 1;
            if (it.fi) r = m === 'Shrink' || m === 'Fill' ? 1 : m === 'Custom' ? Math.max(0, num(it.fi.ShrinkRatio, 0)) : 0;
            return r * it.main;
          });
          const tw = wts.reduce((a, b) => a + b, 0);
          if (tw > 0) parts.forEach((it, i) => { it.main = Math.max(0, it.main + free * wts[i] / tw); });
        }
        total = sum();
        free = mainSize - total;
      }
      let start = free * mainA, between = gap;
      if (free > 0 && line.length) {
        if (mainFlex === 'SpaceBetween' && line.length > 1) { start = 0; between = gap + free / (line.length - 1); }
        else if (mainFlex === 'SpaceAround') { const s = free / line.length; start = s / 2; between = gap + s; }
        else if (mainFlex === 'SpaceEvenly') { const s = free / (line.length + 1); start = s; between = gap + s; }
      }
      const lineCross = line.reduce((a, it) => Math.max(a, it.cross), 0);
      return { line, start, between, total, lineCross };
    });

    const crossExtent = wraps
      ? infos.reduce((a, li) => a + li.lineCross, 0) + gap * Math.max(0, infos.length - 1)
      : infos.reduce((a, li) => Math.max(a, li.lineCross), 0);
    const rects = new Map();
    let crossPos = wraps ? (crossSize - crossExtent) * crossA : 0;
    for (const li of infos) {
      let mainPos = li.start;
      const lc = wraps ? li.lineCross : crossSize;
      for (const it of li.line) {
        let ia = it.fi ? en(it.fi.ItemLineAlignment, 'Automatic') : 'Automatic';
        if (ia === 'Automatic') ia = ila;
        let cs = it.cross, ca = crossA;
        if (ia === 'Start') ca = 0; else if (ia === 'Center') ca = 0.5; else if (ia === 'End') ca = 1;
        else if (ia === 'Stretch') { ca = 0; cs = lc; }
        if (crossFlex === 'Fill') { ca = 0; cs = lc; }
        const cpos = crossPos + (lc - cs) * ca;
        rects.set(it.c, horiz
          ? { x: box.x + mainPos, y: box.y + cpos, w: it.main, h: cs }
          : { x: box.x + cpos, y: box.y + mainPos, w: cs, h: it.main });
        mainPos += it.main + li.between;
      }
      if (wraps) crossPos += li.lineCross + gap;
    }
    const mainExtent = infos.reduce((a, li) => Math.max(a, li.total), 0);
    return horiz ? { rects, cw: mainExtent, ch: crossExtent } : { rects, cw: crossExtent, ch: mainExtent };
  }

  function gridLayout(el, L, box, k) {
    const p = L.p;
    const cs = U2(p.CellSize, { xs: 0, xo: 100, ys: 0, yo: 100 }), cp = U2(p.CellPadding, { xs: 0, xo: 5, ys: 0, yo: 5 });
    let cw = Math.max(0, box.w * cs.xs + cs.xo * k), ch = Math.max(0, box.h * cs.ys + cs.yo * k);
    const gx = box.w * cp.xs + cp.xo * k, gy = box.h * cp.ys + cp.yo * k;
    if (L.aspect) {
      const r = num(L.aspect.AspectRatio, 1) || 1;
      if (en(L.aspect.AspectType, 'FitWithinMaxSize') === 'ScaleWithParentSize') {
        if (en(L.aspect.DominantAxis, 'Width') === 'Width') ch = cw / r; else cw = ch * r;
      } else if (cw / Math.max(ch, 1e-9) > r) cw = ch * r; else ch = cw / r;
    }
    const horiz = en(p.FillDirection, 'Horizontal') === 'Horizontal';
    const maxCells = Math.max(0, Math.floor(num(p.FillDirectionMaxCells, 0)));
    const items = sortedKids(el, p);
    const n = items.length;
    let per = horiz ? Math.floor((box.w + gx) / (cw + gx || 1) + 1e-6) : Math.floor((box.h + gy) / (ch + gy || 1) + 1e-6);
    per = Math.max(1, per);
    if (maxCells > 0) per = Math.min(per, maxCells);
    const nLines = Math.ceil(n / per);
    const ha = AL[en(p.HorizontalAlignment, 'Left')] ?? 0, va = AL[en(p.VerticalAlignment, 'Top')] ?? 0;
    const sc = en(p.StartCorner, 'TopLeft');
    const fromRight = /Right$/.test(sc), fromBottom = /^Bottom/.test(sc);
    const cols = horiz ? Math.min(n, per) : nLines, rows = horiz ? nLines : Math.min(n, per);
    const blockW = cols * cw + Math.max(0, cols - 1) * gx, blockH = rows * ch + Math.max(0, rows - 1) * gy;
    const rects = new Map();
    items.forEach((c, i) => {
      const line = Math.floor(i / per), pos = i % per;
      const inLine = Math.min(per, n - line * per);
      let x, y;
      if (horiz) {
        const lineW = inLine * cw + (inLine - 1) * gx;
        const col = fromRight ? inLine - 1 - pos : pos;
        const row = fromBottom ? rows - 1 - line : line;
        x = (box.w - lineW) * ha + col * (cw + gx);
        y = (box.h - blockH) * va + row * (ch + gy);
      } else {
        const lineH = inLine * ch + (inLine - 1) * gy;
        const row = fromBottom ? inLine - 1 - pos : pos;
        const col = fromRight ? cols - 1 - line : line;
        y = (box.h - lineH) * va + row * (ch + gy);
        x = (box.w - blockW) * ha + col * (cw + gx);
      }
      rects.set(c, { x: box.x + x, y: box.y + y, w: cw, h: ch });
    });
    return { rects, cw: n ? blockW : 0, ch: n ? blockH : 0 };
  }

  // ------------------------------------------------------------------ text

  // single quotes: these strings end up inside style="..." attributes
  const FALLBACK_STACK = "'DejaVu Sans', 'Noto Color Emoji', 'Segoe UI Emoji', 'Apple Color Emoji', sans-serif";
  const familyCache = new Map();
  function cssFamily(key) {
    let f = familyCache.get(key);
    if (f) return f;
    let fam = (CFG.fontMap && CFG.fontMap[key]) || FM.FAMILY[key];
    if (!fam) { fam = FM.FALLBACK_FAMILY; warn(`unknown font family "${key}" -> ${fam}`); }
    f = `'${fam.replace(/'/g, '')}', ${FALLBACK_STACK}`;
    familyCache.set(key, f);
    return f;
  }
  function fontCss(st, f) {
    return `${st.italic ? 'italic ' : ''}${st.weight} ${+(st.sz * f).toFixed(2)}px ${cssFamily(st.key)}`;
  }
  const mctx = document.createElement('canvas').getContext('2d');
  let mFont = '';
  const mCache = new Map();
  function textWidth(font, s) {
    const key = font + '\u0001' + s;
    let w = mCache.get(key);
    if (w === undefined) {
      if (mFont !== font) { mctx.font = font; mFont = font; }
      w = mctx.measureText(s).width;
      mCache.set(key, w);
    }
    return w;
  }

  const ENT = { lt: '<', gt: '>', quot: '"', apos: "'", amp: '&', nbsp: ' ' };
  function decodeEntities(s) {
    return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (m, e) => {
      if (e[0] === '#') { const cp = e[1] === 'x' || e[1] === 'X' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10); return isFinite(cp) ? String.fromCodePoint(cp) : m; }
      return ENT[e.toLowerCase()] ?? m;
    });
  }
  function parseColorAttr(v) {
    if (!v) return null;
    v = v.trim();
    let m = /^#?([0-9a-f]{6})$/i.exec(v);
    if (m) { const n = parseInt(m[1], 16); return rgb255((n >> 16) & 255, (n >> 8) & 255, n & 255); }
    m = /^#?([0-9a-f]{3})$/i.exec(v);
    if (m) { const h = m[1]; return rgb255(parseInt(h[0] + h[0], 16), parseInt(h[1] + h[1], 16), parseInt(h[2] + h[2], 16)); }
    m = /^rgb\s*\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*\)$/i.exec(v);
    if (m) return rgb255(+m[1], +m[2], +m[3]);
    return null;
  }
  function parseAttrs(s) {
    const o = {};
    const re = /([a-zA-Z]+)\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'>]+))/g;
    let m;
    while ((m = re.exec(s))) o[m[1].toLowerCase()] = m[3] ?? m[4] ?? m[5];
    return o;
  }
  const RICH_TAGS = new Set(['b', 'i', 'u', 's', 'font', 'stroke', 'uppercase', 'uc', 'smallcaps', 'sc', 'mark']);

  function pushText(runs, t, st) {
    if (!t) return;
    const parts = t.replace(/\r\n?/g, '\n').split('\n');
    parts.forEach((p, i) => {
      if (i) runs.push({ br: true });
      if (p) runs.push({ text: st.upper ? p.toUpperCase() : p, style: st });
    });
  }
  function parseRich(text, base) {
    const runs = [];
    const stack = [base];
    const re = /<!--[\s\S]*?-->|<\s*(\/?)\s*([a-zA-Z]+)((?:\s+[^>]*?)?)\s*(\/?)\s*>/g;
    let last = 0, m;
    while ((m = re.exec(text))) {
      pushText(runs, decodeEntities(text.slice(last, m.index)), stack[stack.length - 1]);
      last = re.lastIndex;
      if (m[0].startsWith('<!--')) continue;
      const closing = !!m[1], tag = m[2].toLowerCase(), selfClose = !!m[4];
      if (tag === 'br') { runs.push({ br: true }); continue; }
      if (!RICH_TAGS.has(tag)) { warn(`rich text: unsupported tag <${tag}> stripped`); continue; }
      if (closing) {
        for (let i = stack.length - 1; i > 0; i--) if (stack[i].tag === tag) { stack.length = i; break; }
        continue;
      }
      const cur = stack[stack.length - 1];
      const ns = Object.assign({}, cur, { tag });
      const a = parseAttrs(m[3] || '');
      switch (tag) {
        case 'b': ns.weight = 700; break;
        case 'i': ns.italic = true; break;
        case 'u': ns.underline = true; break;
        case 's': ns.strike = true; break;
        case 'uppercase': case 'uc': ns.upper = true; break;
        case 'smallcaps': case 'sc': ns.upper = true; ns.sz = cur.sz * 0.8; break;
        case 'font': {
          const c = parseColorAttr(a.color);
          if (c) ns.color = c;
          if (a.size && isFinite(+a.size)) ns.sz = +a.size;
          const face = a.face || a.family;
          if (face) {
            const f = FM.decodeFace(face);
            ns.key = f.key;
            if (f.weight) ns.weight = f.weight;
            if (f.italic) ns.italic = true;
          }
          if (a.weight) ns.weight = FM.weightNum(a.weight, cur.weight);
          if (a.transparency && isFinite(+a.transparency)) ns.alpha = cur.alpha * (1 - clamp01(+a.transparency));
          break;
        }
        case 'stroke': {
          const c = parseColorAttr(a.color) || { r: 0, g: 0, b: 0 };
          ns.stroke = { color: c, thick: num(a.thickness, 1), alpha: 1 - clamp01(num(a.transparency, 0)) };
          break;
        }
        case 'mark': {
          const c = parseColorAttr(a.color) || { r: 1, g: 1, b: 0 };
          ns.mark = { color: c, alpha: 1 - clamp01(num(a.transparency, 0)) };
          break;
        }
      }
      if (!selfClose) stack.push(ns);
    }
    pushText(runs, decodeEntities(text.slice(last)), stack[stack.length - 1]);
    return runs;
  }
  /** Runs -> units: {br} | {sp, pieces} | {word, pieces}; a word may span several styled pieces. */
  function toUnits(runs) {
    const units = [];
    let word = null;
    for (const r of runs) {
      if (r.br) { word = null; units.push({ br: true }); continue; }
      const parts = r.text.replace(/\t/g, '    ').split(/( +)/);
      for (const part of parts) {
        if (!part) continue;
        if (part[0] === ' ') { word = null; units.push({ sp: true, pieces: [{ text: part, style: r.style }] }); }
        else {
          if (!word) { word = { word: true, pieces: [] }; units.push(word); }
          word.pieces.push({ text: part, style: r.style });
        }
      }
    }
    return units;
  }
  function pw(piece, f) {
    const key = f;
    if (piece._f !== key) { piece._f = key; piece._w = textWidth(fontCss(piece.style, f), piece.text); }
    return piece._w;
  }
  const unitW = (u, f) => u.pieces.reduce((a, p) => a + pw(p, f), 0);

  /** Greedy line breaking. Returns {lines:[{pieces,w,maxSz}], overflowWord}. */
  function wrapUnits(units, f, maxW, wrap, breakWords, baseSz) {
    const EPS = 0.5;
    const lines = [];
    let overflowWord = false;
    const newLine = (soft) => ({ pieces: [], w: 0, wTrail: 0, words: 0, soft, maxSz: 0 });
    let cur = newLine(false);
    let pendSp = null;
    const addPieces = (line, pieces) => {
      for (const p of pieces) {
        const q = { text: p.text, style: p.style };
        line.pieces.push(q);
        line.wTrail += pw(q, f);
        line.maxSz = Math.max(line.maxSz, p.style.sz);
      }
    };
    const addWord = (line, u) => { addPieces(line, u.pieces); line.words++; line.w = line.wTrail; };
    const pushCur = () => { lines.push(cur); };
    const breakWord = (u) => {
      // split a too-long word into chunks that fit maxW, by grapheme
      const chars = [];
      for (const p of u.pieces) for (const ch of Array.from(p.text)) chars.push({ text: ch, style: p.style });
      let chunk = [], cw = 0;
      for (const c of chars) {
        const w = pw(c, f);
        if (chunk.length && cw + w > maxW + EPS) {
          addWord(cur, { pieces: mergePieces(chunk) });
          pushCur(); cur = newLine(true);
          chunk = []; cw = 0;
        }
        chunk.push(c); cw += w;
      }
      if (chunk.length) addWord(cur, { pieces: mergePieces(chunk) });
    };
    for (const u of units) {
      if (u.br) { pushCur(); cur = newLine(false); pendSp = null; continue; }
      if (u.sp) {
        if (cur.soft && cur.words === 0) continue;
        pendSp = pendSp ? { sp: true, pieces: pendSp.pieces.concat(u.pieces) } : u;
        continue;
      }
      const ww = unitW(u, f);
      const sw = pendSp ? unitW(pendSp, f) : 0;
      if (!wrap || cur.words === 0 || cur.w + sw + ww <= maxW + EPS) {
        if (pendSp) addPieces(cur, pendSp.pieces);
        pendSp = null;
        if (wrap && cur.words === 0 && cur.wTrail + ww > maxW + EPS) {
          overflowWord = true;
          if (breakWords) { breakWord(u); continue; }
        }
        addWord(cur, u);
      } else {
        pushCur();
        cur = newLine(true);
        pendSp = null;
        if (ww > maxW + EPS) { overflowWord = true; if (breakWords) { breakWord(u); continue; } }
        addWord(cur, u);
      }
    }
    if (pendSp) addPieces(cur, pendSp.pieces);
    pushCur();
    for (const l of lines) if (!l.maxSz) l.maxSz = baseSz;
    return { lines, overflowWord };
  }
  function mergePieces(chars) {
    const out = [];
    for (const c of chars) {
      const last = out[out.length - 1];
      if (last && last.style === c.style) last.text += c.text; else out.push({ text: c.text, style: c.style });
    }
    return out;
  }
  function blockSize(lines, f, lh) {
    let w = 0, h = 0;
    for (const l of lines) { w = Math.max(w, l.w); h += l.maxSz * f * lh; }
    return { w, h };
  }
  function truncateLine(line, maxW, f) {
    const lastStyle = line.pieces.length ? line.pieces[line.pieces.length - 1].style : null;
    if (!lastStyle) return;
    const ell = { text: '...', style: lastStyle };
    const ew = pw(ell, f);
    // drop trailing characters until it fits
    const chars = [];
    for (const p of line.pieces) for (const ch of Array.from(p.text)) chars.push({ text: ch, style: p.style });
    let w = chars.reduce((a, c) => a + pw(c, f), 0);
    while (chars.length && w + ew > maxW + 0.5) { w -= pw(chars.pop(), f); }
    while (chars.length && chars[chars.length - 1].text === ' ') { w -= pw(chars.pop(), f); }
    line.pieces = mergePieces(chars.concat([ell]));
    line.w = w + ew;
  }

  function textOf(el) {
    let t = str(el.p.Text, '');
    let ph = false;
    if (el.cls === 'TextBox' && t === '') { t = str(el.p.PlaceholderText, ''); ph = true; }
    const mvg = num(el.p.MaxVisibleGraphemes, -1);
    if (mvg >= 0 && !bool(el.p.RichText, false)) t = Array.from(t).slice(0, mvg).join('');
    return { t, ph };
  }
  function baseStyle(el, ph, k) {
    const f = FM.decodeFont(el.p.FontFace, el.p.Font);
    const textA = 1 - clamp01(num(el.p.TextTransparency, 0));
    const color = ph ? C3(el.p.PlaceholderColor3, { r: 0.7, g: 0.7, b: 0.7 }) : C3(el.p.TextColor3, rgb255(27, 42, 53));
    let stroke = null;
    const ctx = el.mods.strokes.find((s) => bool(s.p.Enabled, true) && en(s.p.ApplyStrokeMode, 'Contextual') === 'Contextual');
    if (ctx) {
      const T = num(ctx.p.Thickness, 1);
      if (T > 0) stroke = { color: C3(ctx.p.Color, { r: 0, g: 0, b: 0 }), thick: T * k, alpha: (1 - clamp01(num(ctx.p.Transparency, 0))) * textA, grad: ctx.grad };
    } else {
      const sT = num(el.p.TextStrokeTransparency, 1);
      if (sT < 1) stroke = { color: C3(el.p.TextStrokeColor3, { r: 0, g: 0, b: 0 }), thick: 1, alpha: 1 - clamp01(sT), legacy: true };
    }
    return { key: f.key, weight: f.weight, italic: f.italic, sz: num(el.p.TextSize, 14), color, alpha: textA, stroke, tag: '' };
  }

  /**
   * Lay out el's text in a box of maxW x maxH at offset multiplier k.
   * Returns {lines, w, h, f, lh} (f = px multiplier applied to Roblox text sizes) or null when there is no text.
   */
  function layoutText(el, maxW, maxH, k, measureOnly) {
    const { t, ph } = textOf(el);
    if (t === '') return null;
    const rich = bool(el.p.RichText, false);
    const base = baseStyle(el, ph, k);
    const runs = rich && /[<&]/.test(t) ? parseRich(t, base) : (() => { const r = []; pushText(r, t, base); return r; })();
    const units = toUnits(runs);
    const lh = num(el.p.LineHeight, 1) || 1;
    const scaled = bool(el.p.TextScaled, false);
    const wrapped = bool(el.p.TextWrapped, false);
    let f = k;
    let res;
    if (scaled && !measureOnly) {
      const TSC = el.mods.UITextSizeConstraint;
      const minS = Math.max(1, TSC ? num(TSC.MinTextSize, 1) : 1);
      const maxS = Math.min(100, TSC ? num(TSC.MaxTextSize, 100) : 100);
      const fits = (S) => {
        const ff = (S * k) / base.sz;
        const r = wrapUnits(units, ff, maxW, true, false, base.sz);
        const b = blockSize(r.lines, ff, lh);
        return !r.overflowWord && b.w <= maxW + 0.5 && b.h <= maxH + 0.5;
      };
      let lo = minS, hi = Math.max(minS, maxS), best = minS;
      if (fits(hi)) best = hi;
      else {
        while (hi - lo > 0.5) {
          const mid = (lo + hi) / 2;
          if (fits(mid)) { best = mid; lo = mid; } else hi = mid;
        }
        best = Math.floor(best);
        if (best < minS) best = minS;
      }
      f = (best * k) / base.sz;
      res = wrapUnits(units, f, maxW, true, false, base.sz);
    } else {
      res = wrapUnits(units, f, maxW, wrapped || false, true, base.sz);
    }
    let lines = res.lines;
    const trunc = en(el.p.TextTruncate, 'None');
    if (!measureOnly && trunc !== 'None' && !scaled && isFinite(maxW)) {
      if (wrapped) {
        let acc = 0, keep = 0;
        for (const l of lines) { const h = l.maxSz * f * lh; if (keep > 0 && acc + h > maxH + 0.5) break; acc += h; keep++; }
        if (keep < lines.length) { lines = lines.slice(0, keep); truncateLine(lines[keep - 1], maxW, f); }
      } else {
        for (const l of lines) if (l.w > maxW + 0.5) truncateLine(l, maxW, f);
      }
    }
    const b = blockSize(lines, f, lh);
    return { lines, w: b.w, h: b.h, f, lh, base };
  }

  function strokeShadow(T, colorCss) {
    const out = [];
    const n = clamp(Math.round(2 * Math.PI * T), 8, 32);
    for (let i = 0; i < n; i++) {
      const a = (i / n) * Math.PI * 2;
      out.push(`${px(Math.cos(a) * T)} ${px(Math.sin(a) * T)} 0 ${colorCss}`);
    }
    if (T > 1.6) {
      const m = Math.max(8, n >> 1);
      for (let i = 0; i < m; i++) {
        const a = ((i + 0.5) / m) * Math.PI * 2;
        out.push(`${px(Math.cos(a) * T * 0.55)} ${px(Math.sin(a) * T * 0.55)} 0 ${colorCss}`);
      }
    }
    return out.join(',');
  }
  function spanCss(st, f, layer) {
    let css = `font:${fontCss(st, f)};line-height:inherit;`;
    const deco = [st.underline && 'underline', st.strike && 'line-through'].filter(Boolean).join(' ');
    if (layer === 'stroke') {
      const s = st.stroke;
      if (!s || s.alpha <= 0.001) return css + 'color:transparent;';
      const c = rgba(s.color, 1);
      return css + `color:${c};text-shadow:${strokeShadow(Math.max(0.5, s.thick), c)};opacity:${+s.alpha.toFixed(3)};`;
    }
    if (layer === 'fill') css += `color:${rgba(st.color, st.alpha)};`;
    if (deco) css += `text-decoration:${deco};`;
    if (st.mark) css += `background:${rgba(st.mark.color, st.mark.alpha)};`;
    return css;
  }
  function textHtml(el, w, h, k, extraTop) {
    if (!TEXT.has(el.cls)) return '';
    const pad = padOf(el, w, h, k);
    const box = innerOf({ x: 0, y: 0, w, h }, pad);
    const tl = layoutText(el, box.w, box.h, k, false);
    if (!tl || !tl.lines.length) return '';
    const xa = AL[en(el.p.TextXAlignment, 'Center')] ?? 0.5;
    const ya = AL[en(el.p.TextYAlignment, 'Center')] ?? 0.5;
    const top = box.y + (box.h - tl.h) * ya;
    const clipText = bool(el.p.ClipsDescendants, false);
    const anyStroke = tl.base.stroke || tl.lines.some((l) => l.pieces.some((p) => p.style.stroke));
    const grad = activeGradient(el);
    const build = (layer) => {
      let s = '';
      for (const l of tl.lines) {
        const lh = l.maxSz * tl.f * tl.lh;
        const lx = box.x + (box.w - l.w) * xa;
        const st0 = l.pieces.length ? l.pieces[0].style : tl.base;
        s += `<div class="ln" style="font:${fontCss(st0, tl.f)};height:${px(lh)};line-height:${px(lh)};margin-left:${px(lx)}">`;
        for (const p of l.pieces) s += `<span style="${spanCss(p.style, tl.f, layer)}">${esc(p.text)}</span>`;
        s += '</div>';
      }
      return s;
    };
    const cls = 'tx' + (clipText ? ' clip' : '');
    let out = '';
    if (anyStroke) out += `<div class="${cls}"><div style="margin-top:${px(top)}">${build('stroke')}</div></div>`;
    if (grad) {
      const g = gradientCss(grad, tl.base.color, tl.base.alpha, w, h);
      out += `<div class="${cls} gt" style="background-image:${g}"><div style="margin-top:${px(top)}">${build('grad')}</div></div>`;
    } else {
      out += `<div class="${cls}"><div style="margin-top:${px(top)}">${build('fill')}</div></div>`;
    }
    return out;
  }

  // ------------------------------------------------------------------ visuals

  function activeGradient(el) {
    const g = el.mods.UIGradient;
    return g && bool(g.Enabled, true) ? g : null;
  }
  /** CSS linear-gradient emulating a UIGradient (UV-space rotation, Offset) multiplied with base colour/alpha. */
  function gradientCss(g, baseC, baseA, w, h) {
    const cs = colorSeq(g.Color), ts = numSeq(g.Transparency, 0);
    const th = (num(g.Rotation, 0) * Math.PI) / 180;
    const off = V2(g.Offset, 0, 0);
    const W = Math.max(w, 1), H = Math.max(h, 1);
    const dx = Math.cos(th) / W, dy = Math.sin(th) / H;
    const dl = Math.hypot(dx, dy) || 1;
    const a = Math.atan2(dx, -dy); // css angle (radians), 0 = to top
    const L = Math.abs(W * Math.sin(a)) + Math.abs(H * Math.cos(a));
    const shift = -(off.x * Math.cos(th) + off.y * Math.sin(th));
    const times = new Set([0, 1]);
    cs.forEach((k) => times.add(k.t));
    ts.forEach((k) => times.add(k.t));
    const sorted = [...times].sort((x, y) => x - y);
    // densify a little so interpolation between colour and transparency keys stays faithful
    const ts2 = [];
    for (let i = 0; i < sorted.length; i++) {
      ts2.push(sorted[i]);
      if (i + 1 < sorted.length && sorted[i + 1] - sorted[i] > 0.25) ts2.push((sorted[i] + sorted[i + 1]) / 2);
    }
    const stops = ts2.map((t) => {
      const c = sample(cs, t, ['r', 'g', 'b']);
      const tr = sample(ts, t, ['v']).v;
      const col = mulC(baseC, c);
      const p = 0.5 + (t - 0.5 + shift) / (dl * L);
      return `${rgba(col, baseA * (1 - clamp01(tr)))} ${+(p * 100).toFixed(3)}%`;
    });
    return `linear-gradient(${+((a * 180) / Math.PI).toFixed(3)}deg,${stops.join(',')})`;
  }
  function cornerRadius(el, w, h, k) {
    const c = el.mods.UICorner;
    if (!c) return 0;
    const r = UD(c.CornerRadius, { s: 0, o: 8 });
    return Math.max(0, Math.min(Math.min(w, h) * r.s + r.o * k, Math.min(w, h) / 2));
  }
  function strokeRings(el, w, h, k, rad) {
    let out = '';
    const isText = TEXT.has(el.cls);
    for (const s of el.mods.strokes) {
      if (!bool(s.p.Enabled, true)) continue;
      const mode = en(s.p.ApplyStrokeMode, 'Contextual');
      if (mode === 'Contextual' && isText) continue;
      const T = num(s.p.Thickness, 1) * k;
      if (T <= 0) continue;
      const alpha = 1 - clamp01(num(s.p.Transparency, 0));
      if (alpha <= 0.001) continue;
      const col = C3(s.p.Color, { r: 0, g: 0, b: 0 });
      const posn = en(s.p.BorderStrokePosition, 'Outer');
      const off = posn === 'Inner' ? 0 : posn === 'Center' ? T / 2 : T;
      const round = en(s.p.LineJoinMode, 'Round') === 'Round';
      const outerR = rad > 0 ? rad + off : round ? off : 0;
      const geo = `left:${px(-off)};top:${px(-off)};width:${px(w + 2 * off)};height:${px(h + 2 * off)};border-radius:${px(outerR)};`;
      if (s.grad && bool(s.grad.Enabled, true)) {
        out += `<div class="ring" style="${geo}padding:${px(T)};background:${gradientCss(s.grad, col, alpha, w + 2 * off, h + 2 * off)};` +
          '-webkit-mask:linear-gradient(#000 0 0) content-box,linear-gradient(#000 0 0);-webkit-mask-composite:xor;mask-composite:exclude;"></div>';
      } else {
        out += `<div class="ring" style="${geo}border:${px(T)} solid ${rgba(col, alpha)};"></div>`;
      }
    }
    return out;
  }
  const IMG_GLYPH = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="2.5"/><circle cx="9" cy="9.5" r="1.8"/><path d="M4 18l5.5-5.5 4 4 2.5-2.5L20 18"/></svg>';
  function iconName(el) {
    const a = el.a || {}, pa = (el.parent && el.parent.a) || {};
    return str(a.IconName, '') || str(a.Icon, '') || str(pa.IconName, '') || el.name || 'image';
  }
  function imageHtml(el, w, h, k, rad) {
    if (!IMAGE.has(el.cls)) return '';
    const img = str(el.p.Image, '');
    if (!img) return '';
    const it = clamp01(num(el.p.ImageTransparency, 0));
    if (it >= 0.999 || w < 2 || h < 2) return '';
    let col = C3(el.p.ImageColor3, { r: 1, g: 1, b: 1 });
    let a = 1 - it;
    const g = activeGradient(el);
    if (g) { // tint the placeholder by the gradient's mid colour / transparency
      col = mulC(col, sample(colorSeq(g.Color), 0.5, ['r', 'g', 'b']));
      a *= 1 - clamp01(sample(numSeq(g.Transparency, 0), 0.5, ['v']).v);
    }
    const st = en(el.p.ScaleType, 'Stretch');
    let bx = 0, by = 0, bw = w, bh = h;
    if (st === 'Fit') { const s = Math.min(w, h); bx = (w - s) / 2; by = (h - s) / 2; bw = bh = s; }
    const r = rad > 0 ? Math.min(rad, Math.min(bw, bh) / 2) : Math.min(8, Math.min(bw, bh) * 0.2);
    const name = iconName(el);
    let inner = '';
    if (bw >= 12 && bh >= 12) {
      const gs = Math.round(clamp(Math.min(bw, bh) * 0.4, 8, 28));
      const fit = (fs) => name.length * 0.62 * fs <= (bw - 4) * 0.92;
      let fs = clamp(Math.floor(Math.min(bh * 0.2, 11)), 0, 11);
      while (fs >= 7 && !fit(fs)) fs--;
      const showName = fs >= 7;
      if (showName && bh >= gs + fs + 8) {
        inner = `<span class="gl" style="width:${gs}px;height:${gs}px">${IMG_GLYPH}</span><span class="nm" style="font-size:${fs}px">${esc(name)}</span>`;
      } else {
        let fs2 = clamp(Math.floor(Math.min(bh * 0.45, 11)), 0, 11);
        while (fs2 >= 7 && !fit(fs2)) fs2--;
        if (fs2 >= 7 && bw >= 28) inner = `<span class="nm" style="font-size:${fs2}px">${esc(name)}</span>`;
        else inner = `<span class="gl" style="width:${gs}px;height:${gs}px">${IMG_GLYPH}</span>`;
      }
    }
    const kind = st === 'Slice' ? ' slice' : st === 'Tile' ? ' tile' : '';
    return `<div class="ph${kind}" title="${esc(name)} (${esc(img)})" style="left:${px(bx)};top:${px(by)};width:${px(bw)};height:${px(bh)};` +
      `border-radius:${px(r)};color:${rgba(col, a)};border-color:${rgba(col, a * 0.8)};background-color:${rgba(col, a * 0.1)}">${inner}</div>`;
  }
  function viewportHtml(el, w, h, rad) {
    if (el.cls !== 'ViewportFrame' && el.cls !== 'VideoFrame') return '';
    const label = (el.cls === 'VideoFrame' ? '▶ video · ' : '3D · ') + (el.name || el.cls);
    const fs = clamp(Math.floor(Math.min(h * 0.18, 11)), 7, 11);
    return `<div class="vp" style="border-radius:${px(rad)}">${w > 30 && h > 14 ? `<span style="font-size:${fs}px">${esc(label)}</span>` : ''}</div>`;
  }

  // ------------------------------------------------------------------ placement

  function intersect(a, b) {
    if (!a) return { ...b };
    const x = Math.max(a.x, b.x), y = Math.max(a.y, b.y);
    const r = Math.min(a.x + a.w, b.x + b.w), bt = Math.min(a.y + a.h, b.y + b.h);
    return { x, y, w: Math.max(0, r - x), h: Math.max(0, bt - y) };
  }
  function scrollCanvas(el, rect, k) {
    const cs = U2(el.p.CanvasSize, { xs: 0, xo: 0, ys: 2, yo: 0 });
    let cw = rect.w * cs.xs + cs.xo * k, ch = rect.h * cs.ys + cs.yo * k;
    const acs = en(el.p.AutomaticCanvasSize, 'None');
    if (acs !== 'None') {
      const ax = acs === 'X' || acs === 'XY', ay = acs === 'Y' || acs === 'XY';
      const ce = contentExtent(el, Math.max(cw, ax ? 0 : cw), Math.max(ch, 0), k, ax, ay, k);
      if (ax) cw = Math.max(cw, ce.w);
      if (ay) ch = Math.max(ch, ce.h);
    }
    cw = Math.max(cw, rect.w);
    ch = Math.max(ch, rect.h);
    const cp = V2(el.p.CanvasPosition, 0, 0);
    el.scroll = { cw, ch, cx: cp.x * k, cy: cp.y * k };
    return { x: rect.x - cp.x * k, y: rect.y - cp.y * k, w: cw, h: ch };
  }
  function place(el, rect, k, ctx) {
    el.abs = rect;
    el.k = k;
    el.placed = true;
    el.clip = ctx.clip;
    const rot = num(el.p.Rotation, 0);
    el.xf = rot ? ctx.xf.concat([{ cx: rect.x + rect.w / 2, cy: rect.y + rect.h / 2, deg: rot }]) : ctx.xf;
    let alpha = ctx.alpha;
    if (el.cls === 'CanvasGroup') alpha *= 1 - clamp01(num(el.p.GroupTransparency, 0));
    el.alphaMul = alpha;
    let clip = ctx.clip;
    const clips = el.cls === 'ScrollingFrame' || el.cls === 'CanvasGroup' || bool(el.p.ClipsDescendants, false);
    if (clips && !el.xf.length) clip = intersect(clip, rect);
    const box = el.cls === 'ScrollingFrame' ? scrollCanvas(el, rect, k) : rect;
    placeChildren(el, box, k, { clip, xf: el.xf, alpha });
  }
  function placeChildren(el, box, k, ctx) {
    const inner = innerOf(box, padOf(el, box.w, box.h, k));
    const L = el.mods.layout;
    const rects = L ? runLayout(el, L, inner, k).rects : null;
    for (const c of el.kids) {
      if (!visible(c)) continue;
      const r = (rects && rects.get(c)) || childRect(c, inner, k);
      place(c, r, k * uiScale(c), ctx);
    }
  }

  // ------------------------------------------------------------------ paint order & DOM

  function paintOrder(root, behavior) {
    const list = [];
    if (behavior === 'Global') {
      const all = [];
      (function walk(e) { for (const c of e.kids) if (c.placed) { all.push(c); walk(c); } })(root);
      all.forEach((e, i) => { e.treeIdx = i; });
      all.sort((a, b) => (num(a.p.ZIndex, 1) - num(b.p.ZIndex, 1)) || a.treeIdx - b.treeIdx);
      const pos = new Map(all.map((e, i) => [e, i]));
      const after = new Map();
      for (const e of all) {
        if (e.cls !== 'ScrollingFrame') continue;
        let m = pos.get(e);
        (function walk(x) { for (const c of x.kids) if (c.placed) { m = Math.max(m, pos.get(c)); walk(c); } })(e);
        if (!after.has(m)) after.set(m, []);
        after.get(m).push({ sb: e });
      }
      all.forEach((e, i) => { list.push(e); if (after.has(i)) list.push(...after.get(i)); });
    } else {
      (function walk(e) {
        const ks = e.kids.filter((c) => c.placed).sort((a, b) => (num(a.p.ZIndex, 1) - num(b.p.ZIndex, 1)) || a.idx - b.idx);
        for (const c of ks) {
          list.push(c);
          walk(c);
          if (c.cls === 'ScrollingFrame') list.push({ sb: c });
        }
      })(root);
    }
    return list;
  }
  function frameCss(el) {
    const r = el.abs;
    const x0 = Math.round(r.x), y0 = Math.round(r.y), x1 = Math.round(r.x + r.w), y1 = Math.round(r.y + r.h);
    const w = Math.max(0, x1 - x0), h = Math.max(0, y1 - y0);
    let css = `left:${x0}px;top:${y0}px;width:${w}px;height:${h}px;`;
    if (el.clip) {
      const c = el.clip;
      const t = Math.round(c.y) - y0, l = Math.round(c.x) - x0, rr = x1 - Math.round(c.x + c.w), b = y1 - Math.round(c.y + c.h);
      css += `clip-path:inset(${t}px ${rr}px ${b}px ${l}px);`;
    }
    if (el.xf.length) {
      css += `transform-origin:${-x0}px ${-y0}px;transform:` +
        el.xf.map((t) => `translate(${px(t.cx)},${px(t.cy)}) rotate(${t.deg}deg) translate(${px(-t.cx)},${px(-t.cy)})`).join(' ') + ';';
    }
    if (el.alphaMul < 0.999) css += `opacity:${+el.alphaMul.toFixed(3)};`;
    return { css, w, h, x0, y0 };
  }
  function clippedAway(el) {
    if (!el.clip) return false;
    if (el.clip.w <= 0 || el.clip.h <= 0) return true;
    if (TEXT.has(el.cls)) return false; // text can overflow its box
    const r = el.abs, c = el.clip, m = 8;
    return r.x > c.x + c.w + m || r.y > c.y + c.h + m || r.x + r.w < c.x - m || r.y + r.h < c.y - m;
  }
  function elementHtml(el) {
    if (clippedAway(el)) return '';
    const { css: base, w, h } = frameCss(el);
    const k = el.k;
    let css = base;
    const rad = cornerRadius(el, w, h, k);
    if (rad > 0) css += `border-radius:${px(rad)};`;
    const bgA = 1 - clamp01(num(el.p.BackgroundTransparency, 0));
    const bgC = C3(el.p.BackgroundColor3, rgb255(163, 162, 165));
    const grad = activeGradient(el);
    if (bgA > 0.001) css += `background:${grad ? gradientCss(grad, bgC, bgA, w, h) : rgba(bgC, bgA)};`;
    const bsp = num(el.p.BorderSizePixel, 0);
    if (bsp > 0 && bgA > 0.001 && !el.mods.UICorner) {
      const bc = rgba(C3(el.p.BorderColor3, rgb255(27, 42, 53)), bgA);
      const mode = en(el.p.BorderMode, 'Outline');
      const B = bsp * k;
      css += mode === 'Inset' ? `box-shadow:inset 0 0 0 ${px(B)} ${bc};`
        : mode === 'Middle' ? `box-shadow:0 0 0 ${px(B / 2)} ${bc},inset 0 0 0 ${px(B / 2)} ${bc};`
          : `box-shadow:0 0 0 ${px(B)} ${bc};`;
    }
    const inner = imageHtml(el, w, h, k, rad) + viewportHtml(el, w, h, rad) + strokeRings(el, w, h, k, rad) + textHtml(el, w, h, k);
    return `<div class="g" data-p="${esc(el.path)}" style="${css}">${inner}</div>`;
  }
  function scrollbarHtml(el) {
    const s = el.scroll;
    if (!s || clippedAway(el)) return '';
    const T = num(el.p.ScrollBarThickness, 12) * el.k;
    if (T <= 0) return '';
    const dir = en(el.p.ScrollingDirection, 'XY');
    const r = el.abs;
    const col = C3(el.p.ScrollBarImageColor3, { r: 0.8, g: 0.8, b: 0.8 });
    const a = el.p.ScrollBarImageColor3 ? 1 - clamp01(num(el.p.ScrollBarImageTransparency, 0)) : 0.45;
    if (a <= 0.001) return '';
    const { css: base } = frameCss(el);
    let out = '';
    if ((dir === 'Y' || dir === 'XY') && s.ch > r.h + 0.5) {
      const th = Math.max(T, (r.h * r.h) / s.ch), ty = clamp((s.cy / Math.max(1, s.ch - r.h)) * (r.h - th), 0, r.h - th);
      const side = en(el.p.VerticalScrollBarPosition, 'Right') === 'Left' ? 'left' : 'right';
      out += `<div class="sb" style="${side}:0;top:${px(ty)};width:${px(T)};height:${px(th)};border-radius:${px(T / 2)};background:${rgba(col, a)}"></div>`;
    }
    if ((dir === 'X' || dir === 'XY') && s.cw > r.w + 0.5) {
      const tw = Math.max(T, (r.w * r.w) / s.cw), tx = clamp((s.cx / Math.max(1, s.cw - r.w)) * (r.w - tw), 0, r.w - tw);
      out += `<div class="sb" style="bottom:0;left:${px(tx)};height:${px(T)};width:${px(tw)};border-radius:${px(T / 2)};background:${rgba(col, a)}"></div>`;
    }
    return out ? `<div class="g" style="${base}">${out}</div>` : '';
  }
  function paintHtml(list) {
    let s = '';
    for (const it of list) s += it.sb ? scrollbarHtml(it.sb) : elementHtml(it);
    return s;
  }

  // ------------------------------------------------------------------ roots

  function isBillboard(n) {
    const a = n.attrs || {};
    return n.class === 'BillboardGui' || n.billboard === true || n.isBillboard === true || n.kind === 'billboard' ||
      (Array.isArray(n.flags) && n.flags.some((f) => /billboard/i.test(f))) ||
      a.Billboard === true || a.IsBillboard === true || a.WorldLabel === true || a.__billboard === true;
  }
  function layoutScreen(node, area) {
    const root = makeEl(node, null, false, '');
    root.path = str(node.name, 'ScreenGui');
    root.kids.forEach((c) => { c.path = root.path + '.' + c.name; });
    fixPaths(root);
    root.abs = area; root.k = 1; root.xf = []; root.alphaMul = 1;
    placeChildren(root, area, 1, { clip: null, xf: [], alpha: 1 });
    return root;
  }
  function fixPaths(e) { for (const c of e.kids) { c.path = e.path + '.' + c.name; fixPaths(c); } }

  function billboardStrip(boards, W, H) {
    const items = [];
    for (let n of boards) {
      if (GUI.has(n.class)) {
        // a GuiObject flagged as a world label: draw the object itself at its pixel size
        const s0 = U2((n.props || {}).Size);
        n = { class: 'BillboardGui', name: n.name, props: { Size: { t: 'UDim2', xs: s0.xs, xo: s0.xo, ys: s0.ys, yo: s0.yo } },
          children: [{ ...n, props: { ...(n.props || {}), Position: { t: 'UDim2', xs: 0, xo: 0, ys: 0, yo: 0 },
            Size: { t: 'UDim2', xs: 1, xo: 0, ys: 1, yo: 0 }, AnchorPoint: { t: 'Vector2', x: 0, y: 0 } } }] };
      }
      const p = n.props || {};
      if (p.Enabled === false) continue;
      const s = U2(p.Size);
      if (s.xs !== 0 || s.ys !== 0) { warn(`BillboardGui "${n.name}" uses a scale (stud) Size; skipped in the world-labels strip`); continue; }
      if (s.xo <= 0 || s.yo <= 0) continue;
      items.push({ n, w: s.xo, h: s.yo });
    }
    if (!items.length) return { html: '', count: 0 };
    // world labels keep their pixel size in Roblox, but the review strip may shrink to stay out of the way
    const maxW = Math.min(W - 24, Math.max(W * 0.42, 220));
    const maxH = Math.max(H * 0.32, 90);
    const CAP = 13, GAP = 10, PADX = 10, TITLE = 16;
    let f = 1, rows, stripW, stripH;
    for (let iter = 0; iter < 14; iter++) {
      rows = [];
      let row = [], rw = 0;
      for (const it of items) {
        const iw = Math.max(it.w * f, 40);
        if (row.length && rw + GAP + iw > maxW - 2 * PADX) { rows.push({ row, rw }); row = []; rw = 0; }
        rw += (row.length ? GAP : 0) + iw;
        row.push(it);
      }
      if (row.length) rows.push({ row, rw });
      stripW = Math.max(190, Math.max(...rows.map((r) => r.rw)) + 2 * PADX);
      stripH = TITLE + rows.reduce((a, r) => a + CAP + Math.max(...r.row.map((it) => it.h * f)) + GAP, 0) + 2;
      if ((stripH <= maxH && stripW <= maxW + 1) || f < 0.15) break;
      f *= 0.85;
    }
    const sx = W - 12 - stripW, sy = H - 12 - stripH;
    let html = `<div class="bbpanel" style="left:${px(sx)};top:${px(sy)};width:${px(stripW)};height:${px(stripH)}"><div class="bbtitle">WORLD LABELS (BillboardGui)${f < 0.999 ? ` · ${Math.round(f * 100)}%` : ''}</div></div>`;
    let y = sy + TITLE;
    for (const r of rows) {
      let x = sx + PADX;
      const rowH = Math.max(...r.row.map((it) => it.h * f));
      for (const it of r.row) {
        const iw = it.w * f, ih = it.h * f;
        const cellW = Math.max(iw, 40);
        html += `<div class="bbcap" style="left:${px(x)};top:${px(y)};width:${px(Math.max(cellW, 40))}">${esc(it.n.name || 'BillboardGui')}</div>`;
        const area = { x: x + (cellW - iw) / 2, y: y + CAP, w: iw, h: ih };
        html += `<div class="bbbox" style="left:${px(area.x)};top:${px(area.y)};width:${px(iw)};height:${px(ih)}"></div>`;
        const root = makeEl(it.n, null, false, '');
        root.path = 'billboard:' + (it.n.name || '?');
        fixPaths(root);
        placeChildren(root, area, f, { clip: bool((it.n.props || {}).ClipsDescendants, false) ? area : null, xf: [], alpha: 1 });
        html += paintHtml(paintOrder(root, en((it.n.props || {}).ZIndexBehavior, 'Sibling')));
        x += cellW + GAP;
      }
      y += CAP + rowH + GAP;
    }
    return { html, count: items.length };
  }

  // ------------------------------------------------------------------ scene & chrome

  function rng(seed) { let s = seed >>> 0; return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; }; }
  function pinePath(x, base, h, w) {
    const pts = [[x, base - h]];
    const tiers = [[0.28, 0.2], [0.55, 0.34], [0.84, 0.5]];
    for (const [ty, tw] of tiers) { pts.push([x + w * tw, base - h + h * ty]); pts.push([x + w * tw * 0.45, base - h + h * ty - h * 0.02]); }
    pts.pop();
    pts.push([x + w * 0.07, base - h * 0.16], [x + w * 0.07, base], [x - w * 0.07, base], [x - w * 0.07, base - h * 0.16]);
    for (let i = tiers.length - 1; i >= 0; i--) {
      const [ty, tw] = tiers[i];
      if (i < tiers.length - 1) pts.push([x - w * tw * 0.45, base - h + h * tiers[i + 1][0] - h * 0.02]);
      pts.push([x - w * tw, base - h + h * ty]);
    }
    return 'M' + pts.map((p) => p[0].toFixed(1) + ' ' + p[1].toFixed(1)).join('L') + 'Z';
  }
  function sceneHtml(W, H) {
    const r = rng(1337 + W * 7 + H);
    let stars = '';
    for (let i = 0; i < Math.round((W * H) / 26000); i++) {
      const x = r() * W, y = r() * H * 0.55, s = r() < 0.15 ? 1.6 : 1;
      stars += `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="${s}" fill="rgba(210,225,255,${(0.15 + r() * 0.35).toFixed(2)})"/>`;
    }
    const layer = (n, hMin, hMax, fill, off) => {
      let d = '';
      for (let i = 0; i < n; i++) {
        const x = (i / n) * W + (r() - 0.5) * (W / n) + off;
        const h = H * (hMin + r() * (hMax - hMin));
        d += pinePath(x, H + 2, h, h * 0.4);
      }
      return `<path d="${d}" fill="${fill}"/>`;
    };
    const n = Math.max(8, Math.round(W / 60));
    return `<div id="sky"></div><svg id="woods" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">` +
      stars +
      `<ellipse cx="${W * 0.5}" cy="${H * 1.02}" rx="${W * 0.38}" ry="${H * 0.2}" fill="url(#glow)"/>` +
      '<defs><radialGradient id="glow"><stop offset="0" stop-color="rgba(255,150,70,0.13)"/><stop offset="1" stop-color="rgba(255,120,40,0)"/></radialGradient></defs>' +
      layer(n, 0.13, 0.24, '#0c1626', 0) +
      layer(Math.round(n * 0.8), 0.09, 0.17, '#060b13', W / n / 2) +
      `<rect x="0" y="${H - H * 0.035}" width="${W}" height="${H * 0.04}" fill="#04070c"/></svg>`;
  }
  function chromeHtml(W, H, inset) {
    let s = '';
    if (inset > 0) {
      const bh = Math.max(16, Math.min(44, inset - 14)), by = (inset - bh) / 2;
      s += `<div class="tbline" style="top:${inset}px"></div>`;
      s += `<div class="tbbtn" style="left:16px;top:${px(by)};width:${bh * 2 + 4}px;height:${bh}px;border-radius:${bh / 2}px"><i style="width:${bh * 0.5}px;height:${bh * 0.5}px"></i><i style="width:${bh * 0.5}px;height:${bh * 0.5}px"></i></div>`;
      s += `<div class="tbbtn" style="right:16px;top:${px(by)};width:${bh}px;height:${bh}px;border-radius:${bh / 2}px"><i style="width:${bh * 0.5}px;height:${bh * 0.5}px"></i></div>`;
    }
    s += `<div class="stamp" style="${W < 1000 ? 'font-size:9px;line-height:12px' : ''}">PREVIEW — approximate render, icons are placeholders · ${esc(String(DUMP.checkpoint || ''))} · ${W}×${H}</div>`;
    return s;
  }

  // ------------------------------------------------------------------ main

  async function loadFonts() {
    const faces = CFG.faces || [];
    const sample = CFG.sample || 'AaBbGg0123';
    const timeout = new Promise((res) => setTimeout(() => res('timeout'), 10000));
    const loads = Promise.all(faces.map((f) => document.fonts.load(`${f.style} ${f.weight} 16px "${f.family}"`, sample).catch(() => null)));
    const r = await Promise.race([loads.then(() => 'ok'), timeout]);
    if (r === 'timeout') warn('web fonts did not finish loading within 10 s; text may use fallback fonts');
    await document.fonts.ready;
    for (const f of faces) if (!document.fonts.check(`${f.style} ${f.weight} 16px "${f.family}"`, 'A')) warn(`font not available: ${f.family} ${f.weight} ${f.style}`);
  }

  async function main() {
    const t0 = performance.now();
    await loadFonts();
    const t1 = performance.now();
    const W = Math.round(num(DUMP.viewport && DUMP.viewport.w, 1920)), H = Math.round(num(DUMP.viewport && DUMP.viewport.h, 1080));
    const inset = num(DUMP.guiInset, 0);
    const stage = document.getElementById('stage');
    stage.style.width = W + 'px';
    stage.style.height = H + 'px';

    const screens = [], boards = [];
    (DUMP.roots || []).forEach((n, i) => {
      if (!n || typeof n !== 'object') return;
      if (isBillboard(n)) boards.push(n);
      else if (n.class === 'ScreenGui') screens.push({ n, i });
      else if (GUI.has(n.class)) { warn(`root ${n.class} "${n.name}" is not in a ScreenGui; drawn as if in one`); screens.push({ n: { class: 'ScreenGui', name: n.name, props: {}, children: [n] }, i }); }
      else if (n.class === 'SurfaceGui') warn(`SurfaceGui "${n.name}" skipped (in-world surface)`);
      else warn(`root ${n.class} "${n.name}" skipped`);
    });
    const enabled = screens.filter((s) => bool((s.n.props || {}).Enabled, true));
    enabled.sort((a, b) => (num((a.n.props || {}).DisplayOrder, 0) - num((b.n.props || {}).DisplayOrder, 0)) || a.i - b.i);
    let uiHtml = '';
    const roots = [];
    for (const { n } of enabled) {
      const p = n.props || {};
      const fullScreen = bool(p.IgnoreGuiInset, false) || ['None', 'DeviceSafeInsets'].includes(en(p.ScreenInsets, ''));
      const area = fullScreen ? { x: 0, y: 0, w: W, h: H } : { x: 0, y: inset, w: W, h: Math.max(0, H - inset) };
      const root = layoutScreen(n, area);
      roots.push(root);
      uiHtml += paintHtml(paintOrder(root, en(p.ZIndexBehavior, 'Sibling')));
    }
    const bb = CFG.billboards === 'off' ? { html: '', count: 0 } : billboardStrip(boards, W, H);
    const t2 = performance.now();
    const under = CFG.billboards === 'under';
    stage.innerHTML = `<div id="scene">${sceneHtml(W, H)}</div>` +
      (under ? `<div id="bb">${bb.html}</div>` : '') +
      `<div id="ui">${uiHtml}</div>` +
      (!under ? `<div id="bb">${bb.html}</div>` : '') +
      `<div id="chrome">${chromeHtml(W, H, inset)}</div>`;
    const t3 = performance.now();

    let rects;
    if (CFG.rects) {
      rects = {};
      const walk = (e) => { for (const c of e.kids) if (c.placed) { const r = c.abs; rects[c.path] = [+r.x.toFixed(2), +r.y.toFixed(2), +r.w.toFixed(2), +r.h.toFixed(2)]; walk(c); } };
      roots.forEach(walk);
    }
    window.__PREVIEW__ = {
      done: true, warnings, rects,
      stats: {
        guiObjects: elCount, screenGuis: enabled.length, billboards: bb.count, domNodes: stage.getElementsByTagName('*').length,
        fontMs: Math.round(t1 - t0), layoutMs: Math.round(t2 - t1), domMs: Math.round(t3 - t2),
      },
    };
  }

  main().catch((e) => {
    console.error(e);
    window.__PREVIEW__ = { done: true, error: String(e && e.stack || e), warnings };
  });
})();
