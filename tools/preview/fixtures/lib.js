'use strict';
/* Tiny DSL for hand-writing dump fixtures. Every node gets Roblox's effective default props,
 * the way the headless mock exports them, so fixtures look like real dumps. */

const U2 = (xs, xo, ys, yo) => ({ t: 'UDim2', xs, xo, ys, yo });
const UD = (s, o) => ({ t: 'UDim', s, o });
const V2 = (x, y) => ({ t: 'Vector2', x, y });
function C(hex, g, b) {
  if (typeof hex === 'number') return { t: 'Color3', r: +(hex / 255).toFixed(4), g: +(g / 255).toFixed(4), b: +(b / 255).toFixed(4) };
  const n = parseInt(hex.replace('#', ''), 16);
  return { t: 'Color3', r: +(((n >> 16) & 255) / 255).toFixed(4), g: +(((n >> 8) & 255) / 255).toFixed(4), b: +((n & 255) / 255).toFixed(4) };
}
const E = (en, name) => ({ t: 'Enum', enum: en, name });
const FONT = (fam, weight = 'Regular', style = 'Normal') => ({
  t: 'Font', family: fam.startsWith('rbx') ? fam : `rbxasset://fonts/families/${fam}.json`, weight, style,
});
function CS(...kps) { // CS([0,'#fff'],[1,'#000'])
  return { t: 'ColorSequence', kps: kps.map(([time, hex]) => { const c = C(hex); return { time, r: c.r, g: c.g, b: c.b }; }) };
}
const NS = (...kps) => ({ t: 'NumberSequence', kps: kps.map(([time, value]) => ({ time, value })) });

const GUIOBJ = {
  Position: U2(0, 0, 0, 0), Size: U2(0, 0, 0, 0), AnchorPoint: V2(0, 0), Visible: true, ZIndex: 1, LayoutOrder: 0,
  Rotation: 0, BackgroundColor3: C(163, 162, 165), BackgroundTransparency: 0, BorderSizePixel: 1,
  BorderColor3: C(27, 42, 53), ClipsDescendants: false, AutomaticSize: E('AutomaticSize', 'None'),
};
const TEXTP = {
  Text: 'Label', TextColor3: C(27, 42, 53), TextSize: 14, TextTransparency: 0, TextStrokeColor3: C(0, 0, 0),
  TextStrokeTransparency: 1, TextXAlignment: E('TextXAlignment', 'Center'), TextYAlignment: E('TextYAlignment', 'Center'),
  TextWrapped: false, TextScaled: false, TextTruncate: E('TextTruncate', 'None'), RichText: false,
  FontFace: FONT('SourceSansPro'), LineHeight: 1,
};
const IMAGEP = { Image: '', ImageColor3: C(255, 255, 255), ImageTransparency: 0, ScaleType: E('ScaleType', 'Stretch') };
const DEFAULTS = {
  ScreenGui: { Enabled: true, DisplayOrder: 0, IgnoreGuiInset: false, ZIndexBehavior: E('ZIndexBehavior', 'Sibling') },
  BillboardGui: { Enabled: true, Size: U2(0, 200, 0, 50), AlwaysOnTop: false, ClipsDescendants: false, ZIndexBehavior: E('ZIndexBehavior', 'Sibling') },
  Frame: GUIOBJ, CanvasGroup: { ...GUIOBJ, GroupTransparency: 0 },
  ViewportFrame: GUIOBJ, VideoFrame: GUIOBJ,
  ScrollingFrame: { ...GUIOBJ, CanvasSize: U2(0, 0, 2, 0), AutomaticCanvasSize: E('AutomaticSize', 'None'), ScrollBarThickness: 12 },
  TextLabel: { ...GUIOBJ, ...TEXTP }, TextButton: { ...GUIOBJ, ...TEXTP, Text: 'Button' }, TextBox: { ...GUIOBJ, ...TEXTP, Text: '' },
  ImageLabel: { ...GUIOBJ, ...IMAGEP }, ImageButton: { ...GUIOBJ, ...IMAGEP },
  UIListLayout: {
    FillDirection: E('FillDirection', 'Vertical'), HorizontalAlignment: E('HorizontalAlignment', 'Left'),
    VerticalAlignment: E('VerticalAlignment', 'Top'), Padding: UD(0, 0), SortOrder: E('SortOrder', 'LayoutOrder'),
    Wraps: false, HorizontalFlex: E('UIFlexAlignment', 'None'), VerticalFlex: E('UIFlexAlignment', 'None'),
  },
  UIGridLayout: {
    CellSize: U2(0, 100, 0, 100), CellPadding: U2(0, 5, 0, 5), FillDirection: E('FillDirection', 'Horizontal'),
    FillDirectionMaxCells: 0, HorizontalAlignment: E('HorizontalAlignment', 'Left'),
    VerticalAlignment: E('VerticalAlignment', 'Top'), SortOrder: E('SortOrder', 'LayoutOrder'), StartCorner: E('StartCorner', 'TopLeft'),
  },
  UIPadding: { PaddingTop: UD(0, 0), PaddingBottom: UD(0, 0), PaddingLeft: UD(0, 0), PaddingRight: UD(0, 0) },
  UICorner: { CornerRadius: UD(0, 8) },
  UIStroke: { Color: C(0, 0, 0), Thickness: 1, Transparency: 0, ApplyStrokeMode: E('ApplyStrokeMode', 'Contextual'), Enabled: true },
  UIGradient: { Color: CS([0, '#ffffff'], [1, '#ffffff']), Transparency: NS([0, 0], [1, 0]), Rotation: 0, Offset: V2(0, 0), Enabled: true },
  UIScale: { Scale: 1 },
  UIAspectRatioConstraint: { AspectRatio: 1, AspectType: E('AspectType', 'FitWithinMaxSize'), DominantAxis: E('DominantAxis', 'Width') },
  UISizeConstraint: { MinSize: V2(0, 0), MaxSize: V2(1e9, 1e9) },
  UITextSizeConstraint: { MinTextSize: 1, MaxTextSize: 100 },
  UIFlexItem: { FlexMode: E('UIFlexMode', 'None'), GrowRatio: 1, ShrinkRatio: 1 },
  Folder: {},
};
const ENUMS = {
  AutomaticSize: 'AutomaticSize', AutomaticCanvasSize: 'AutomaticSize', TextXAlignment: 'TextXAlignment',
  TextYAlignment: 'TextYAlignment', TextTruncate: 'TextTruncate', ScaleType: 'ScaleType', FillDirection: 'FillDirection',
  HorizontalAlignment: 'HorizontalAlignment', VerticalAlignment: 'VerticalAlignment', SortOrder: 'SortOrder',
  HorizontalFlex: 'UIFlexAlignment', VerticalFlex: 'UIFlexAlignment', StartCorner: 'StartCorner',
  ApplyStrokeMode: 'ApplyStrokeMode', ZIndexBehavior: 'ZIndexBehavior', AspectType: 'AspectType', DominantAxis: 'DominantAxis',
  FlexMode: 'UIFlexMode', BorderMode: 'BorderMode', BorderStrokePosition: 'BorderStrokePosition', ScrollingDirection: 'ScrollingDirection',
  ItemLineAlignment: 'ItemLineAlignment', SizeConstraint: 'SizeConstraint', LineJoinMode: 'LineJoinMode',
};

/** n(cls, name, props, ...children) — props may use plain strings for enums. Attributes go in props.$attrs. */
function n(cls, name, props = {}, ...children) {
  const p = { ...(DEFAULTS[cls] || {}) };
  let attrs = {};
  for (const [k, v] of Object.entries(props)) {
    if (k === '$attrs') { attrs = v; continue; }
    p[k] = typeof v === 'string' && ENUMS[k] ? E(ENUMS[k], v) : v;
  }
  return { class: cls, name, props: p, attrs, children: children.flat().filter(Boolean) };
}

// palette from Config.UI.Theme ("campfire field kit")
const T = {
  Backdrop: '#050508', Panel: '#151210', PanelTop: '#241e19', Raised: '#27211c', RaisedTop: '#342c24', Inset: '#0c0a09',
  Edge: '#544332', EdgeBright: '#967854', Text: '#eee4ce', TextDim: '#aa9e8a', TextFaint: '#6c6358', TextOnAccent: '#1e130a',
  Ember: '#f08830', EmberBright: '#ffc268', EmberDeep: '#a03c16', Moon: '#96bae2', MoonBright: '#cee2f8', MoonDeep: '#38547a',
  Blood: '#c62c24', BloodBright: '#ff6252', BloodDeep: '#5c0e0c', Moss: '#7ac85c', MossBright: '#b8ee8e', MossDeep: '#2a6024',
  Paper: '#e2d4b6', Ink: '#2a211a', Secret: '#d6d2e8',
};

// frequently used bits
const corner = (o = 6, s = 0) => n('UICorner', 'UICorner', { CornerRadius: UD(s, o) });
const stroke = (hex, th = 1, props = {}) => n('UIStroke', 'UIStroke', { Color: C(hex), Thickness: th, ...props });
const pad = (t, r = t, b = t, l = r) => n('UIPadding', 'UIPadding', { PaddingTop: UD(0, t), PaddingRight: UD(0, r), PaddingBottom: UD(0, b), PaddingLeft: UD(0, l) });
const list = (props = {}) => n('UIListLayout', 'UIListLayout', props);
const grid = (props = {}) => n('UIGridLayout', 'UIGridLayout', props);
const vgrad = (top, bottom, props = {}) => n('UIGradient', 'UIGradient', { Color: CS([0, top], [1, bottom]), Rotation: 90, ...props });
const scale = (s) => n('UIScale', 'UIScale', { Scale: s });
const font = FONT;

function label(name, text, props = {}, ...children) {
  return n('TextLabel', name, {
    Text: text, BackgroundTransparency: 1, BorderSizePixel: 0, TextColor3: C(T.Text), FontFace: FONT('Oswald'),
    TextSize: 16, ...props,
  }, ...children);
}
function frame(name, props = {}, ...children) {
  return n('Frame', name, { BorderSizePixel: 0, BackgroundColor3: C(T.Panel), ...props }, ...children);
}
function icon(name, iconName, props = {}) {
  return n('ImageLabel', name, {
    Image: 'rbxassetid://1000000' + (iconName.length * 7919 % 1000), BackgroundTransparency: 1, BorderSizePixel: 0,
    ScaleType: 'Fit', $attrs: { IconName: iconName }, ...props,
  });
}
function screen(name, props = {}, ...children) { return n('ScreenGui', name, props, ...children); }

/** A grid "test board" of labelled panels, scaled to fit the viewport (exercises UIScale too). */
function board(vw, vh, inset, panels, opts = {}) {
  const cols = opts.cols || 5, cw = opts.cw || 360, ch = opts.ch || 236, gap = 12;
  const rows = Math.ceil(panels.length / cols);
  const bw = cols * cw + (cols - 1) * gap + 24, bh = rows * ch + (rows - 1) * gap + 24;
  const top = opts.top || 0;
  const s = Math.min((vw - 16) / bw, (vh - inset - top - 16) / bh);
  return frame('Board', {
    AnchorPoint: V2(0.5, 0.5), Position: U2(0.5, 0, 0.5, top / 2), Size: U2(0, bw, 0, bh), BackgroundTransparency: 1,
  }, scale(+s.toFixed(4)), pad(12), grid({ CellSize: U2(0, cw, 0, ch), CellPadding: U2(0, gap, 0, gap) }),
  panels.map(([title, ...kids], i) => frame('P' + String(i).padStart(2, '0'), {
    LayoutOrder: i, BackgroundColor3: C(T.Panel), BackgroundTransparency: 0.08,
  }, corner(6), stroke(T.Edge, 1, { ApplyStrokeMode: 'Border' }),
  label('Title', title, { Position: U2(0, 10, 0, 4), Size: U2(1, -20, 0, 20), TextXAlignment: 'Left', TextSize: 14, TextColor3: C(T.TextDim), FontFace: FONT('Oswald', 'Medium') }),
  frame('Area', { Position: U2(0, 8, 0, 28), Size: U2(1, -16, 1, -36), BackgroundColor3: C(T.Inset), BackgroundTransparency: 0.2 },
    corner(4), ...kids))));
}

function dump(checkpoint, vw, vh, roots, inset = 58) {
  return { checkpoint, viewport: { w: vw, h: vh }, guiInset: inset, roots };
}

module.exports = { U2, UD, V2, C, E, FONT, CS, NS, n, T, corner, stroke, pad, list, grid, vgrad, scale, font, label, frame, icon, screen, board, dump };
