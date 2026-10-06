'use strict';
/* page.js — assembles the self-contained preview HTML (fonts, dump, engine all inline). */
const fs = require('fs');
const path = require('path');

const ENGINE = path.join(__dirname, '..', 'engine.js');
const FONTMAP = path.join(__dirname, 'fontmap.js');

const CSS = `
html,body{margin:0;padding:0;background:#07090d}
body{min-height:100vh;display:flex;align-items:safe center;justify-content:safe center}
#stage{position:relative;overflow:hidden;background:#05080f;flex:none}
#scene,#ui,#bb,#chrome{position:absolute;left:0;top:0;width:100%;height:100%}
#scene,#chrome{pointer-events:none}
#sky{position:absolute;inset:0;background:
  radial-gradient(ellipse 60% 38% at 50% 104%,rgba(255,146,64,.16),rgba(255,120,40,.05) 48%,rgba(0,0,0,0) 72%),
  radial-gradient(ellipse 55% 45% at 22% 8%,rgba(120,150,210,.10),rgba(0,0,0,0) 70%),
  radial-gradient(ellipse 130% 100% at 50% 35%,#13203a 0%,#0b1426 42%,#060a13 78%,#04060b 100%)}
#woods{position:absolute;left:0;top:0}
.g{position:absolute;box-sizing:border-box}
.ring{position:absolute;box-sizing:border-box}
.tx{position:absolute;left:0;top:0;right:0;bottom:0;white-space:pre;font-synthesis:none;font-kerning:normal;
  font-variant-ligatures:normal;letter-spacing:0;word-spacing:0}
.tx.clip{overflow:hidden}
.tx.gt{-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent;color:transparent}
.ln{white-space:pre}
.ph{position:absolute;box-sizing:border-box;border:1px dashed;display:flex;flex-direction:column;align-items:center;
  justify-content:center;gap:1px;overflow:hidden;font-family:"DejaVu Sans Mono",Menlo,Consolas,monospace}
.ph .gl{display:block;opacity:.7;flex:none}
.ph .gl svg{width:100%;height:100%;display:block}
.ph .nm{max-width:94%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;line-height:1.2;opacity:.9;flex:none}
.ph.slice{border-style:dotted}
.ph.tile{background-image:linear-gradient(to right,color-mix(in srgb,currentColor 35%,transparent) 1px,transparent 1px),
  linear-gradient(to bottom,color-mix(in srgb,currentColor 35%,transparent) 1px,transparent 1px);background-size:12px 12px}
.vp{position:absolute;inset:0;box-sizing:border-box;border:1px solid rgba(160,180,220,.18);display:flex;align-items:center;
  justify-content:center;color:rgba(200,215,240,.6);font-family:"DejaVu Sans",sans-serif;overflow:hidden;
  background:repeating-linear-gradient(135deg,rgba(255,255,255,.07) 0 1px,rgba(0,0,0,0) 1px 9px),rgba(8,10,18,.82)}
.sb{position:absolute}
.bbpanel{position:absolute;background:rgba(5,8,14,.6);border:1px solid rgba(255,255,255,.14);border-radius:6px;box-sizing:border-box}
.bbtitle{font:600 9px/14px "DejaVu Sans",sans-serif;letter-spacing:.08em;color:rgba(220,230,255,.6);padding:2px 10px;
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.bbcap{position:absolute;font:9px/12px "DejaVu Sans Mono",monospace;color:rgba(220,230,255,.7);white-space:nowrap;overflow:hidden;
  text-overflow:ellipsis;text-align:center}
.bbbox{position:absolute;outline:1px dashed rgba(255,255,255,.2)}
.tbline{position:absolute;left:0;right:0;border-top:1px dashed rgba(255,255,255,.10)}
.tbbtn{position:absolute;background:rgba(18,20,26,.5);display:flex;align-items:center;justify-content:space-evenly}
.tbbtn i{display:block;border-radius:50%;background:rgba(255,255,255,.2)}
.stamp{position:absolute;left:8px;bottom:6px;font:10px/14px "DejaVu Sans",sans-serif;color:rgba(255,255,255,.62);
  background:rgba(0,0,0,.5);padding:1px 7px;border-radius:4px;white-space:nowrap}
`;

function scriptSafe(s) { return s.replace(/<\/(script)/gi, '<\\/$1'); }
function jsonSafe(o) {
  return JSON.stringify(o).replace(/</g, '\\u003c').replace(/[\u2028\u2029]/g, (c) => '\\u' + c.charCodeAt(0).toString(16));
}
function escHtml(s) { return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }

function buildHtml({ dump, fontCss, cfg }) {
  const engine = fs.readFileSync(ENGINE, 'utf8');
  const fontmap = fs.readFileSync(FONTMAP, 'utf8');
  const w = dump.viewport.w, h = dump.viewport.h;
  return `<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=${w}">
<title>${escHtml(dump.checkpoint)} ${w}×${h} — Roblox UI preview</title>
<style>${fontCss}</style>
<style>${CSS}</style>
</head><body>
<div id="stage" style="width:${w}px;height:${h}px"></div>
<script id="rbx-dump" type="application/json">${jsonSafe(dump)}</script>
<script id="rbx-cfg" type="application/json">${jsonSafe(cfg)}</script>
<script>${scriptSafe(fontmap)}</script>
<script>${scriptSafe(engine)}</script>
</body></html>
`;
}

module.exports = { buildHtml };
