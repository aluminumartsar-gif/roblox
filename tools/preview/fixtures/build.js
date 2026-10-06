#!/usr/bin/env node
'use strict';
/* Generates the fixture dumps in this folder: node fixtures/build.js  (writes fixtures/*.json) */
const fs = require('fs');
const path = require('path');
const L = require('./lib');
const { U2, UD, V2, C, CS, NS, n, T, corner, stroke, pad, list, grid, vgrad, scale, FONT, label, frame, icon, screen, board, dump } = L;

const SIZES = [[1920, 1080], [749, 368]];
const out = {};

// ------------------------------------------------------------------ helpers
const HUES = ['#d9822b', '#4f9bd9', '#6cbf5a', '#c95dbd', '#d9c84f', '#5fc9c0', '#e0605a', '#8f7be0', '#b0b0b0', '#e09a5f'];
function chip(name, w, h, i = 0, props = {}, ...kids) {
  return frame(name, { Size: U2(0, w, 0, h), BackgroundColor3: C(HUES[i % HUES.length]), ...props },
    corner(3), label('L', name, { Size: U2(1, 0, 1, 0), TextSize: 13, TextColor3: C('#111111'), FontFace: FONT('Oswald', 'Bold') }), ...kids);
}
const chips = (count, sizes, props = {}) => Array.from({ length: count }, (_, i) => {
  const [w, h] = typeof sizes === 'function' ? sizes(i) : sizes;
  return chip(String.fromCharCode(65 + i), w, h, i, { LayoutOrder: i, ...props });
});
const area = (...kids) => frame('Inner', { Size: U2(1, 0, 1, 0), BackgroundTransparency: 1 }, ...kids);

// ------------------------------------------------------------------ layouts
function layouts(vw, vh, inset) {
  const panels = [
    ['UIListLayout vertical · Left/Top · pad 6', list({ Padding: UD(0, 6) }), ...chips(4, (i) => [60 + i * 30, 30])],
    ['vertical · Center/Center', list({ Padding: UD(0, 6), HorizontalAlignment: 'Center', VerticalAlignment: 'Center' }), ...chips(4, (i) => [60 + i * 30, 30])],
    ['vertical · Right/Bottom · UIPadding 12', pad(12), list({ Padding: UD(0, 6), HorizontalAlignment: 'Right', VerticalAlignment: 'Bottom' }), ...chips(4, (i) => [60 + i * 30, 30])],
    ['horizontal · Center/Center · pad 8', list({ FillDirection: 'Horizontal', Padding: UD(0, 8), HorizontalAlignment: 'Center', VerticalAlignment: 'Center' }), ...chips(4, (i) => [44, 40 + i * 25])],
    ['horizontal · Right/Bottom · SortOrder Name', list({ FillDirection: 'Horizontal', Padding: UD(0, 6), HorizontalAlignment: 'Right', VerticalAlignment: 'Bottom', SortOrder: 'Name' }),
      chip('C', 50, 50, 2, { LayoutOrder: 1 }), chip('A', 50, 70, 0, { LayoutOrder: 3 }), chip('B', 50, 90, 1, { LayoutOrder: 2 })],
    ['horizontal · Wraps · pad 6 · LayoutOrder', pad(6), list({ FillDirection: 'Horizontal', Padding: UD(0, 6), Wraps: true }),
      ...chips(10, (i) => [40 + ((i * 37) % 50), 34]).reverse()],
    ['HorizontalFlex Fill (top) · SpaceBetween (bottom)',
      frame('Top', { Size: U2(1, 0, 0.5, -4), BackgroundTransparency: 1 }, list({ FillDirection: 'Horizontal', Padding: UD(0, 6), HorizontalFlex: 'Fill', VerticalAlignment: 'Center' }), ...chips(3, [40, 40])),
      frame('Bottom', { Position: U2(0, 0, 0.5, 4), Size: U2(1, 0, 0.5, -4), BackgroundTransparency: 1 }, list({ FillDirection: 'Horizontal', HorizontalFlex: 'SpaceBetween', VerticalAlignment: 'Center' }), ...chips(4, [40, 40]))],
    ['vertical · Padding UDim(0.05,0) · hidden C skipped', list({ Padding: UD(0.05, 0), HorizontalAlignment: 'Center' }),
      ...chips(5, [160, 26]).map((c) => (c.name === 'C' ? { ...c, props: { ...c.props, Visible: false } } : c))],
    ['UIGridLayout 60x60 pad 6 · Left/Top', grid({ CellSize: U2(0, 60, 0, 60), CellPadding: U2(0, 6, 0, 6) }), ...chips(7, [0, 0])],
    ['grid · Center/Center (rows centred)', grid({ CellSize: U2(0, 60, 0, 60), CellPadding: U2(0, 6, 0, 6), HorizontalAlignment: 'Center', VerticalAlignment: 'Center' }), ...chips(7, [0, 0])],
    ['grid · Vertical · MaxCells 2 · StartCorner TopRight', grid({ CellSize: U2(0, 50, 0, 50), CellPadding: U2(0, 6, 0, 6), FillDirection: 'Vertical', FillDirectionMaxCells: 2, StartCorner: 'TopRight' }), ...chips(7, [0, 0])],
    ['grid · CellSize scale .3 · AspectRatio 1.6', n('UIGridLayout', 'UIGridLayout', { CellSize: U2(0.3, 0, 0.5, 0), CellPadding: U2(0.02, 0, 0.04, 0) }, n('UIAspectRatioConstraint', 'UIAspectRatioConstraint', { AspectRatio: 1.6 })), ...chips(5, [0, 0])],
    ['AnchorPoint at the 9 positions',
      ...[0, 0.5, 1].flatMap((ay, r) => [0, 0.5, 1].map((ax, c) => chip(`${ax},${ay}`, 64, 34, r * 3 + c, { Position: U2(ax, 0, ay, 0), AnchorPoint: V2(ax, ay) })))],
    ['UIScale 1.5: anchor .5 (left) vs anchor 0 (right)',
      frame('Ref1', { Position: U2(0.25, 0, 0.5, 0), AnchorPoint: V2(0.5, 0.5), Size: U2(0, 80, 0, 60), BackgroundTransparency: 1 }, stroke('#ffffff', 1, { ApplyStrokeMode: 'Border', Transparency: 0.5 })),
      chip('x1.5', 80, 60, 1, { Position: U2(0.25, 0, 0.5, 0), AnchorPoint: V2(0.5, 0.5), BackgroundTransparency: 0.35 }, scale(1.5)),
      frame('Ref2', { Position: U2(0.62, 0, 0.3, 0), Size: U2(0, 80, 0, 60), BackgroundTransparency: 1 }, stroke('#ffffff', 1, { ApplyStrokeMode: 'Border', Transparency: 0.5 })),
      chip('x1.5 ', 80, 60, 2, { Position: U2(0.62, 0, 0.3, 0), BackgroundTransparency: 0.35 }, scale(1.5))],
    ['AutomaticSize Y card (list+padding) · XY pill',
      frame('Card', { Position: U2(0, 8, 0, 8), Size: U2(0, 150, 0, 20), AutomaticSize: 'Y', BackgroundColor3: C(T.Raised) },
        corner(4), stroke(T.EdgeBright, 1), pad(8), list({ Padding: UD(0, 4) }),
        label('A', 'Auto height', { Size: U2(1, 0, 0, 18), TextXAlignment: 'Left', LayoutOrder: 1 }),
        label('B', 'grows to fit its three children plus padding', { Size: U2(1, 0, 0, 0), AutomaticSize: 'Y', TextWrapped: true, TextXAlignment: 'Left', TextSize: 14, TextColor3: C(T.TextDim), LayoutOrder: 2 }),
        chip('child', 60, 24, 3, { LayoutOrder: 3 })),
      label('Pill', 'AutomaticSize XY pill', { Position: U2(1, -8, 1, -8), AnchorPoint: V2(1, 1), AutomaticSize: 'XY', Size: U2(0, 0, 0, 0), BackgroundTransparency: 0, BackgroundColor3: C(T.Ember), TextColor3: C(T.TextOnAccent), FontFace: FONT('Oswald', 'Bold') }, corner(0, 1), pad(4, 12))],
    ['UISizeConstraint Max 120x60 · AspectRatio 2 in 1x1',
      frame('Clamped', { Size: U2(0.5, -8, 1, 0), BackgroundColor3: C(HUES[1]) }, n('UISizeConstraint', 'UISizeConstraint', { MaxSize: V2(120, 60) })),
      frame('Aspect', { Position: U2(0.5, 4, 0, 0), Size: U2(0.5, -4, 1, 0), BackgroundColor3: C(HUES[2]) }, n('UIAspectRatioConstraint', 'UIAspectRatioConstraint', { AspectRatio: 2 }))],
    ['Folder children ignore the layout · list Center',
      list({ FillDirection: 'Horizontal', HorizontalAlignment: 'Center', Padding: UD(0, 6) }), ...chips(3, [50, 50]),
      n('Folder', 'Extras', {}, chip('folder', 120, 30, 6, { Position: U2(0.5, 0, 1, -4), AnchorPoint: V2(0.5, 1) }))],
    ['UIFlexItem Fill on one item (list Horizontal)', list({ FillDirection: 'Horizontal', Padding: UD(0, 6), VerticalAlignment: 'Center' }),
      chip('A', 50, 50, 0, { LayoutOrder: 1 }), chip('grows', 50, 50, 1, { LayoutOrder: 2 }, n('UIFlexItem', 'UIFlexItem', { FlexMode: 'Fill' })), chip('C', 50, 50, 2, { LayoutOrder: 3 })],
    ['SizeConstraint RelativeYY (square from height)', chip('YY', 0, 0, 4, { Size: U2(0.8, 0, 0.8, 0), SizeConstraint: 'RelativeYY', Position: U2(0.5, 0, 0.5, 0), AnchorPoint: V2(0.5, 0.5) })],
    ['nested: list of AutomaticSize X rows', list({ Padding: UD(0, 6) }),
      ...['short', 'a little longer', 'the longest row of them all'].map((t, i) => frame('Row' + i, { LayoutOrder: i, Size: U2(0, 0, 0, 30), AutomaticSize: 'X', BackgroundColor3: C(T.Raised) },
        corner(4), pad(0, 10), list({ FillDirection: 'Horizontal', Padding: UD(0, 6), VerticalAlignment: 'Center' }),
        frame('Dot', { Size: U2(0, 10, 0, 10), BackgroundColor3: C(HUES[i]) }, corner(0, 1)),
        label('T', t, { Size: U2(0, 0, 1, 0), AutomaticSize: 'X', TextSize: 15, LayoutOrder: 2 })))],
  ];
  return dump('layouts', vw, vh, [screen('Board', {}, board(vw, vh, inset, panels.map(([t, ...k]) => [t, ...k])))]);
}

// ------------------------------------------------------------------ text
const LOREM = 'The Mothman was last seen near the old ranger tower. Bring a lantern, keep your eggs warm and never leave your camp unlocked after dark.';
function text(vw, vh, inset) {
  const box = (name, txt, props = {}, ...kids) => label(name, txt, { BackgroundTransparency: 0.85, BackgroundColor3: C('#ffffff'), TextSize: 15, ...props }, ...kids);
  const panels = [
    ['TextXAlignment × TextYAlignment', grid({ CellSize: U2(0.333, -4, 0.333, -4), CellPadding: U2(0, 6, 0, 6) }),
      ...['Top', 'Center', 'Bottom'].flatMap((y, r) => ['Left', 'Center', 'Right'].map((x, c) => box(`${x}${y}`, `${x}/${y}`, { LayoutOrder: r * 3 + c, TextXAlignment: x, TextYAlignment: y, TextSize: 13 })))],
    ['TextWrapped · Left/Top · LineHeight 1', box('Wrap', LOREM, { Size: U2(1, 0, 1, 0), TextWrapped: true, TextXAlignment: 'Left', TextYAlignment: 'Top', FontFace: FONT('SourceSansPro') })],
    ['TextTruncate AtEnd (wrapped + single line)',
      box('W', LOREM, { Size: U2(1, 0, 0, 62), TextWrapped: true, TextTruncate: 'AtEnd', TextXAlignment: 'Left', TextYAlignment: 'Top' }),
      box('S', 'Legendary Golden Mothman Egg (incubating)', { Position: U2(0, 0, 0, 74), Size: U2(0, 200, 0, 28), TextTruncate: 'AtEnd', TextXAlignment: 'Left' }),
      box('N', 'Legendary Golden Mothman Egg (no truncate)', { Position: U2(0, 0, 0, 112), Size: U2(0, 200, 0, 28), TextXAlignment: 'Left' })],
    ['TextScaled (+UITextSizeConstraint Max 24, + wrap)',
      box('S1', 'SCALED', { Size: U2(0.5, -4, 0.5, -4), TextScaled: true, FontFace: FONT('Oswald', 'Bold') }),
      box('S2', 'SCALED', { Position: U2(0.5, 4, 0, 0), Size: U2(0.5, -4, 0.25, -4), TextScaled: true, FontFace: FONT('Oswald', 'Bold') }),
      box('S3', 'capped at 24', { Position: U2(0.5, 4, 0.25, 0), Size: U2(0.5, -4, 0.25, -4), TextScaled: true }, n('UITextSizeConstraint', 'UITextSizeConstraint', { MaxTextSize: 24 })),
      box('S4', 'Hatch your egg before dawn', { Position: U2(0, 0, 0.5, 4), Size: U2(1, 0, 0.5, -4), TextScaled: true, TextWrapped: true, FontFace: FONT('Creepster') })],
    ['RichText tags', box('Rich',
      '<b>Bold</b> <i>italic</i> <u>under</u> <s>strike</s> <font color="#FF7800">orange</font> <font color="rgb(120,200,92)">rgb()</font><br/>' +
      '<font size="26">big</font> <font size="11">small</font> <font face="Creepster">Creepy</font> <font family="rbxasset://fonts/families/SpecialElite.json">typewriter</font><br/>' +
      '<stroke color="#c62c24" thickness="2">stroked</stroke> &lt;escaped&gt; &amp; <font weight="heavy">heavy</font> <uppercase>upper</uppercase> <mark color="#38547a">marked</mark><!-- hidden comment --> <foo>unknown</foo>',
      { Size: U2(1, 0, 1, 0), RichText: true, TextXAlignment: 'Left', TextYAlignment: 'Top', TextSize: 17, LineHeight: 1.15 }, pad(6))],
    ['Text strokes: legacy · UIStroke 2 · 3 · 50% · Border',
      list({ Padding: UD(0, 4) }),
      label('Legacy', 'TextStrokeTransparency 0', { LayoutOrder: 1, Size: U2(1, 0, 0, 30), TextSize: 22, FontFace: FONT('Oswald', 'Bold'), TextStrokeTransparency: 0, TextStrokeColor3: C('#000000') }),
      label('S2', 'UIStroke Thickness 2', { LayoutOrder: 2, Size: U2(1, 0, 0, 30), TextSize: 22, FontFace: FONT('Oswald', 'Bold') }, stroke('#000000', 2)),
      label('S3', 'CREEPSTER 3px', { LayoutOrder: 3, Size: U2(1, 0, 0, 34), TextSize: 30, FontFace: FONT('Creepster'), TextColor3: C(T.EmberBright) }, stroke(T.BloodDeep, 3)),
      label('S4', 'stroke 50% transparent', { LayoutOrder: 4, Size: U2(1, 0, 0, 30), TextSize: 22, FontFace: FONT('Oswald', 'Bold') }, stroke('#c62c24', 3, { Transparency: 0.5 })),
      label('S5', 'ApplyStrokeMode Border', { LayoutOrder: 5, Size: U2(1, -8, 0, 28), TextSize: 16 }, stroke(T.Moon, 2, { ApplyStrokeMode: 'Border' }), corner(4))],
    ['LineHeight 1.5 (left) vs 0.8 (right)',
      box('LH15', 'one\ntwo\nthree', { Size: U2(0.5, -4, 1, 0), LineHeight: 1.5, TextSize: 20 }),
      box('LH08', 'one\ntwo\nthree', { Position: U2(0.5, 4, 0, 0), Size: U2(0.5, -4, 1, 0), LineHeight: 0.8, TextSize: 20 })],
    ['AutomaticSize X chips in a wrapping list', pad(4), list({ FillDirection: 'Horizontal', Wraps: true, Padding: UD(0, 6) }),
      ...[['Common', '#b0aca4'], ['Uncommon', '#7ac85c'], ['Rare', '#4f9bd9'], ['Epic', '#a46ee0'], ['Legendary', '#f0b030'], ['Mythic', '#e0605a'], ['SECRET', T.Secret], ['x2 cash for 15m', T.Ember]]
        .map(([t, col], i) => label('Chip' + i, t, { LayoutOrder: i, Size: U2(0, 0, 0, 26), AutomaticSize: 'X', BackgroundTransparency: 0, BackgroundColor3: C(T.Raised), TextColor3: C(col), TextSize: 15, FontFace: FONT('Oswald', 'SemiBold') }, corner(0, 1), pad(0, 10), stroke(col, 1, { ApplyStrokeMode: 'Border', Transparency: 0.4 })))],
    ['AutomaticSize Y wrapped note (SpecialElite on Paper)',
      label('Note', 'Field note #12: tracks lead north from the creek. Something large, two-legged, and in no hurry.', {
        Size: U2(0, 240, 0, 40), AutomaticSize: 'Y', TextWrapped: true, BackgroundTransparency: 0, BackgroundColor3: C(T.Paper),
        TextColor3: C(T.Ink), FontFace: FONT('SpecialElite'), TextSize: 15, TextXAlignment: 'Left', TextYAlignment: 'Top', Rotation: -2, Position: U2(0, 20, 0, 10),
      }, pad(10), corner(2))],
    ['Fonts (FontFace families & weights)', list({ Padding: UD(0, 0) }),
      ...[['Creepster', 'Regular', 'Creepster — STEAL A CRYPTID'], ['Oswald', 'Light', 'Oswald Light 300'], ['Oswald', 'Regular', 'Oswald Regular 400'], ['Oswald', 'Bold', 'Oswald Bold 700'],
        ['SpecialElite', 'Regular', 'Special Elite typewriter'], ['Inconsolata', 'Bold', 'Inconsolata Bold 12:34:56'], ['GothamSSm', 'Bold', 'Gotham Bold (Montserrat)'], ['GothamSSm', 'Heavy', 'Gotham Black (Montserrat 900)'],
        ['FredokaOne', 'Regular', 'Fredoka One'], ['SourceSansPro', 'Regular', 'Source Sans Pro'], ['BuilderSans', 'Bold', 'Builder Sans Bold (Inter)'], ['rbxassetid://12187371840', 'Regular', 'cloud font id -> fallback']]
        .map(([f, w, t], i) => label('F' + i, t, { LayoutOrder: i, Size: U2(1, 0, 0, 15), TextSize: 14, TextXAlignment: 'Left', FontFace: FONT(f, w) })),
      n('TextLabel', 'LegacyFont', { LayoutOrder: 99, Size: U2(1, 0, 0, 15), Text: 'legacy Font=GothamBold, no FontFace', TextSize: 14, TextXAlignment: 'Left', BackgroundTransparency: 1, TextColor3: C(T.Moon), FontFace: undefined, Font: L.E('Font', 'GothamBold') })],
    ['UIGradient on text · TextTransparency .5',
      label('G', 'EMBER GLOW', { Size: U2(1, 0, 0.5, 0), TextSize: 44, FontFace: FONT('Creepster'), TextColor3: C('#ffffff') }, vgrad(T.EmberBright, T.EmberDeep), stroke('#000000', 2)),
      label('TT', 'half transparent text', { Position: U2(0, 0, 0.5, 0), Size: U2(1, 0, 0.5, 0), TextSize: 24, TextTransparency: 0.5, FontFace: FONT('Oswald', 'Bold') })],
    ['TextBox placeholder · TextButton',
      n('TextBox', 'Code', { Size: U2(1, 0, 0, 36), Text: '', PlaceholderText: 'Enter a code…', PlaceholderColor3: C(T.TextFaint), TextColor3: C(T.Text), BackgroundColor3: C(T.Inset), BorderSizePixel: 0, TextSize: 16, FontFace: FONT('Oswald'), TextXAlignment: 'Left' }, pad(0, 10), corner(4), stroke(T.Edge, 1, { ApplyStrokeMode: 'Border' })),
      n('TextButton', 'Redeem', { Position: U2(0, 0, 0, 46), Size: U2(1, 0, 0, 40), Text: 'REDEEM', BackgroundColor3: C(T.Ember), BorderSizePixel: 0, TextColor3: C(T.TextOnAccent), TextSize: 20, FontFace: FONT('Oswald', 'Bold') }, corner(6), vgrad(T.EmberBright, T.Ember))],
  ];
  return dump('text', vw, vh, [screen('Board', {}, board(vw, vh, inset, panels, { cols: 4, cw: 440, ch: 260 }))]);
}

// ------------------------------------------------------------------ visuals
function visuals(vw, vh, inset) {
  const sq = (name, props = {}, ...kids) => frame(name, { Size: U2(0, 56, 0, 56), BackgroundColor3: C(T.Moon), ...props }, ...kids);
  const row = (pd = 10) => list({ FillDirection: 'Horizontal', Padding: UD(0, pd), VerticalAlignment: 'Center', HorizontalAlignment: 'Center' });
  const caption = (t, i) => label('Cap' + i, t, { Size: U2(1, 0, 0, 14), Position: U2(0, 0, 1, 2), TextSize: 11, TextColor3: C(T.TextDim) });
  const panels = [
    ['UICorner 0 · 4 · 12 · (0.5,0) · (1,0) on a bar', row(),
      ...[[0, 0], [0, 4], [0, 12], [0.5, 0]].map(([s, o], i) => sq('C' + i, { LayoutOrder: i }, corner(o, s), caption(`${s},${o}`, i))),
      frame('Pill', { LayoutOrder: 9, Size: U2(0, 90, 0, 30), BackgroundColor3: C(T.Ember) }, corner(0, 1))],
    ['UIStroke Border 1 · 2 · 4 · Inner · Center', row(14),
      ...[[1, 'Outer'], [2, 'Outer'], [4, 'Outer'], [4, 'Inner'], [4, 'Center']].map(([th, pos], i) => sq('S' + i, { LayoutOrder: i, BackgroundColor3: C(T.Raised) }, corner(8),
        stroke(T.Ember, th, { ApplyStrokeMode: 'Border', BorderStrokePosition: L.E('BorderStrokePosition', pos) }), caption(`${th} ${pos}`, i)))],
    ['UIStroke: 50% · gradient stroke · square corners', row(18),
      sq('T', { LayoutOrder: 1, BackgroundColor3: C(T.Raised) }, stroke('#ffffff', 3, { ApplyStrokeMode: 'Border', Transparency: 0.5 })),
      sq('G', { LayoutOrder: 2, BackgroundColor3: C(T.Raised), Size: U2(0, 90, 0, 56) }, corner(10), n('UIStroke', 'UIStroke', { Thickness: 3, Color: C('#ffffff'), ApplyStrokeMode: L.E('ApplyStrokeMode', 'Border') }, n('UIGradient', 'UIGradient', { Color: CS([0, T.Ember], [1, T.Moon]) }))),
      sq('M', { LayoutOrder: 3, BackgroundColor3: C(T.Raised) }, stroke(T.Moss, 3, { ApplyStrokeMode: 'Border', LineJoinMode: L.E('LineJoinMode', 'Miter') }))],
    ['UIGradient Rotation 0 · 90 · 45 · -30 · 180', row(8),
      ...[0, 90, 45, -30, 180].map((r, i) => sq('G' + i, { LayoutOrder: i, BackgroundColor3: C('#ffffff') }, corner(4), n('UIGradient', 'UIGradient', { Color: CS([0, T.Ember], [1, T.MoonDeep]), Rotation: r }), caption(String(r), i)))],
    ['Gradient: transparency fade · Offset .3 · rainbow · tinted', row(8),
      frame('Fade', { LayoutOrder: 1, Size: U2(0, 70, 0, 56), BackgroundColor3: C(T.Blood) }, n('UIGradient', 'UIGradient', { Transparency: NS([0, 0], [1, 1]) })),
      frame('Off', { LayoutOrder: 2, Size: U2(0, 70, 0, 56), BackgroundColor3: C('#ffffff') }, n('UIGradient', 'UIGradient', { Color: CS([0, '#000000'], [1, '#ffffff']), Offset: V2(0.3, 0) })),
      frame('Rainbow', { LayoutOrder: 3, Size: U2(0, 70, 0, 56), BackgroundColor3: C('#ffffff') }, n('UIGradient', 'UIGradient', { Color: CS([0, '#ff0000'], [0.2, '#ffff00'], [0.4, '#00ff00'], [0.6, '#00ffff'], [0.8, '#0000ff'], [1, '#ff00ff']), Rotation: 90 })),
      frame('Tint', { LayoutOrder: 4, Size: U2(0, 70, 0, 56), BackgroundColor3: C(T.Moss) }, corner(0, 0.5), n('UIGradient', 'UIGradient', { Color: CS([0, '#ffffff'], [1, '#333333']), Rotation: 90, Transparency: NS([0, 0], [0.5, 0.2], [1, 0.6]) }))],
    ['BorderSizePixel 1 · 3 Outline · 3 Inset · with UICorner (no border)', row(14),
      sq('B1', { LayoutOrder: 1, BorderSizePixel: 1, BorderColor3: C('#ffffff') }),
      sq('B3', { LayoutOrder: 2, BorderSizePixel: 3, BorderColor3: C(T.Blood) }),
      sq('B3i', { LayoutOrder: 3, BorderSizePixel: 3, BorderColor3: C(T.Blood), BorderMode: L.E('BorderMode', 'Inset') }),
      sq('BC', { LayoutOrder: 4, BorderSizePixel: 3, BorderColor3: C(T.Blood) }, corner(8))],
    ['BackgroundTransparency 0 · .25 · .5 · .75 over a stripe',
      frame('Stripe', { Position: U2(0, 0, 0.5, -10), Size: U2(1, 0, 0, 20), BackgroundColor3: C('#ffffff') }),
      frame('Row', { Size: U2(1, 0, 1, 0), BackgroundTransparency: 1 }, row(10), ...[0, 0.25, 0.5, 0.75].map((t, i) => sq('T' + i, { LayoutOrder: i, BackgroundColor3: C(T.Blood), BackgroundTransparency: t }, caption(String(t), i))))],
    ['Rotation 15° (child rotates with it) · nested -30°',
      frame('Rot', { Position: U2(0.3, 0, 0.5, 0), AnchorPoint: V2(0.5, 0.5), Size: U2(0, 120, 0, 70), Rotation: 15, BackgroundColor3: C(T.MoonDeep) }, corner(6),
        label('T', 'rotated 15°', { Size: U2(1, 0, 0.5, 0), TextSize: 16 }),
        frame('Kid', { Position: U2(1, -10, 1, -10), Size: U2(0, 40, 0, 24), BackgroundColor3: C(T.Ember), Rotation: -30 })),
      frame('Ghost', { Position: U2(0.75, 0, 0.5, 0), AnchorPoint: V2(0.5, 0.5), Size: U2(0, 100, 0, 60), Rotation: -10, BackgroundColor3: C(T.Moss), BackgroundTransparency: 0.3 })],
    ['ZIndexBehavior Sibling: parent A(Z2)>child a(Z1) > B(Z1)'],
    ['ZIndexBehavior Global: a(Z1) < B(Z1) < A(Z2)'],
    ['ClipsDescendants false (left) / true (right)',
      ...[false, true].map((cl, i) => frame('Clip' + i, { Position: U2(i * 0.5, 14, 0, 14), Size: U2(0.5, -28, 1, -28), BackgroundColor3: C(T.Raised), ClipsDescendants: cl },
        frame('Big', { Position: U2(0.5, 0, 0.5, 0), Size: U2(0, 150, 0, 40), BackgroundColor3: C(T.Ember), Rotation: 0 }),
        label('Long', 'text spills past the edge', { Position: U2(0, 4, 0, 4), Size: U2(0, 60, 0, 20), TextXAlignment: 'Left', TextSize: 14 })))],
    ['ScrollingFrame: list + AutomaticCanvasSize Y · CanvasPosition',
      n('ScrollingFrame', 'Scroll', { Size: U2(0.5, -6, 1, 0), BackgroundColor3: C(T.Panel), BorderSizePixel: 0, CanvasSize: U2(0, 0, 0, 0), AutomaticCanvasSize: L.E('AutomaticSize', 'Y'), ScrollBarThickness: 6, ScrollBarImageColor3: C(T.EdgeBright) },
        pad(6), list({ Padding: UD(0, 4) }),
        ...Array.from({ length: 12 }, (_, i) => label('Row' + i, `row ${i + 1}`, { LayoutOrder: i, Size: U2(1, -8, 0, 22), BackgroundTransparency: 0, BackgroundColor3: C(i % 2 ? T.Raised : T.RaisedTop), TextXAlignment: 'Left', TextSize: 14 }, pad(0, 6)))),
      n('ScrollingFrame', 'Scrolled', { Position: U2(0.5, 6, 0, 0), Size: U2(0.5, -6, 1, 0), BackgroundColor3: C(T.Panel), BorderSizePixel: 0, CanvasSize: U2(0, 0, 0, 400), CanvasPosition: V2(0, 120), ScrollBarThickness: 8 },
        ...Array.from({ length: 8 }, (_, i) => label('Abs' + i, `y=${i * 50}`, { Position: U2(0, 8, 0, i * 50), Size: U2(1, -24, 0, 40), BackgroundTransparency: 0, BackgroundColor3: C(HUES[i]), TextColor3: C('#111111'), TextSize: 14 })))],
    ['CanvasGroup GroupTransparency .5 · ViewportFrame · VideoFrame',
      n('CanvasGroup', 'Group', { Size: U2(0, 110, 0, 110), BackgroundColor3: C(T.Raised), BorderSizePixel: 0, GroupTransparency: 0.5 }, corner(8),
        frame('A', { Position: U2(0, 10, 0, 10), Size: U2(0, 60, 0, 60), BackgroundColor3: C(T.Ember) }), frame('B', { Position: U2(0, 40, 0, 40), Size: U2(0, 60, 0, 60), BackgroundColor3: C(T.Moon) })),
      n('ViewportFrame', 'EggModel', { Position: U2(0, 124, 0, 0), Size: U2(0, 110, 0, 110), BackgroundTransparency: 1, BorderSizePixel: 0 }),
      n('VideoFrame', 'Trailer', { Position: U2(0, 124, 0, 120), Size: U2(0, 160, 0, 60), BackgroundTransparency: 1, BorderSizePixel: 0 })],
    ['Images: Stretch · Fit · Crop · Slice · Tile · tint · 50% · tiny', grid({ CellSize: U2(0, 76, 0, 76), CellPadding: U2(0, 8, 0, 8) }),
      ...[['Stretch', {}], ['Fit', { ScaleType: 'Fit' }], ['Crop', { ScaleType: 'Crop' }], ['Slice', { ScaleType: 'Slice' }], ['Tile', { ScaleType: 'Tile' }],
        ['tint', { ImageColor3: C(T.Ember) }], ['half', { ImageTransparency: 0.5 }]]
        .map(([nm, p], i) => n('ImageLabel', 'Img' + nm, { LayoutOrder: i, Image: 'rbxassetid://123456' + i, BackgroundTransparency: 1, BorderSizePixel: 0, ...p, $attrs: i === 6 ? {} : { IconName: nm === 'tint' ? 'flame' : 'egg-' + nm.toLowerCase() } })),
      frame('Tiny', { LayoutOrder: 8, BackgroundTransparency: 1 }, n('ImageLabel', 'TinyIcon', { Size: U2(0, 12, 0, 12), Image: 'rbxassetid://1', BackgroundTransparency: 1, ImageColor3: C(T.Moss) }),
        n('ImageButton', 'Btn', { Position: U2(0, 20, 0, 0), Size: U2(0, 56, 0, 24), Image: 'rbxassetid://2', BackgroundColor3: C(T.Raised), BorderSizePixel: 0, $attrs: { IconName: 'sell' } }, corner(4)))],
    ['DisplayOrder: blue (DO 6, listed first) over orange (DO 5)'],
    ['IgnoreGuiInset: see the bars at the very top'],
  ];
  // ZIndex demos: they need their own ScreenGuis (ZIndexBehavior is per ScreenGui), so they are
  // drawn over board panels 8, 9, 14 using the same board geometry.
  const cols = 5, cw = 360, ch = 236, gap = 12;
  const rows = Math.ceil(panels.length / cols);
  const bw = cols * cw + (cols - 1) * gap + 24, bh = rows * ch + (rows - 1) * gap + 24;
  const top = 40;
  const s = Math.min((vw - 16) / bw, (vh - inset - top - 16) / bh);
  const overlay = (idx, kids) => frame('Over' + idx, {
    AnchorPoint: V2(0.5, 0.5), Position: U2(0.5, 0, 0.5, top / 2), Size: U2(0, bw, 0, bh), BackgroundTransparency: 1,
  }, scale(+s.toFixed(4)), frame('Cell', {
    Position: U2(0, 12 + (idx % cols) * (cw + gap) + 8, 0, 12 + Math.floor(idx / cols) * (ch + gap) + 28),
    Size: U2(0, cw - 16, 0, ch - 36), BackgroundTransparency: 1,
  }, ...kids));
  const zdemo = (global) => overlay(global ? 9 : 8, [
    frame('A', { Position: U2(0, 20, 0, 20), Size: U2(0, 140, 0, 110), BackgroundColor3: C(T.MoonDeep), ZIndex: 2 },
      label('LA', 'A  Z=2', { Size: U2(1, 0, 0, 22), TextSize: 15, TextXAlignment: 'Left' }, pad(0, 6)),
      frame('a', { Position: U2(0, 60, 0, 50), Size: U2(0, 150, 0, 80), BackgroundColor3: C(T.Ember), ZIndex: 1 },
        label('La', 'a (child of A) Z=1', { Size: U2(1, 0, 1, 0), TextSize: 14, TextColor3: C('#111111') }))),
    frame('B', { Position: U2(0, 150, 0, 70), Size: U2(0, 150, 0, 90), BackgroundColor3: C(T.Moss), ZIndex: 1 },
      label('LB', 'B  Z=1', { Size: U2(1, 0, 0, 22), Position: U2(0, 0, 1, -22), TextSize: 15, TextColor3: C('#111111'), TextXAlignment: 'Right' }, pad(0, 6))),
  ]);
  const roots = [
    screen('Board', {}, board(vw, vh, inset, panels, { top })),
    screen('ZSibling', { DisplayOrder: 1, ZIndexBehavior: L.E('ZIndexBehavior', 'Sibling') }, zdemo(false)),
    screen('ZGlobal', { DisplayOrder: 1, ZIndexBehavior: L.E('ZIndexBehavior', 'Global') }, zdemo(true)),
    screen('BlueOver', { DisplayOrder: 6 }, overlay(14, [frame('Blue', { Position: U2(0, 90, 0, 40), Size: U2(0, 120, 0, 100), BackgroundColor3: C('#3b7dd8') }, label('t', 'DO 6', { Size: U2(1, 0, 1, 0), TextSize: 20 }))])),
    screen('OrangeUnder', { DisplayOrder: 5 }, overlay(14, [frame('Orange', { Position: U2(0, 30, 0, 10), Size: U2(0, 120, 0, 100), BackgroundColor3: C(T.Ember) }, label('t', 'DO 5', { Size: U2(1, 0, 0.5, 0), TextSize: 20, TextColor3: C('#111111') }))])),
    screen('Disabled', { Enabled: false, DisplayOrder: 99 }, frame('MustNotShow', { Size: U2(1, 0, 1, 0), BackgroundColor3: C('#ff0000') }, label('X', 'DISABLED SCREENGUI VISIBLE — BUG', { Size: U2(1, 0, 1, 0), TextSize: 60 }))),
    screen('InsetIgnored', { IgnoreGuiInset: true, DisplayOrder: 2 },
      label('Bar', 'IgnoreGuiInset = true → y = 0', { Position: U2(0.5, -330, 0, 0), Size: U2(0, 320, 0, 28), BackgroundTransparency: 0.1, BackgroundColor3: C(T.Moss), TextColor3: C('#111111'), TextSize: 15, FontFace: FONT('Oswald', 'Bold') })),
    screen('InsetRespected', { IgnoreGuiInset: false, DisplayOrder: 2 },
      label('Bar', 'IgnoreGuiInset = false → y = inset', { Position: U2(0.5, 10, 0, 0), Size: U2(0, 320, 0, 28), BackgroundTransparency: 0.1, BackgroundColor3: C(T.Blood), TextSize: 15, FontFace: FONT('Oswald', 'Bold') })),
  ];
  // listing order deliberately puts the higher DisplayOrder first
  return dump('visuals', vw, vh, roots);
}

// ------------------------------------------------------------------ the HUD (realistic composite)
function hudScreens(vw, vh) {
  const s = +Math.min(1.2, Math.max(0.7, vh / 650)).toFixed(4);
  const btn = (name, txt, ic, color, i) => n('TextButton', name, {
    LayoutOrder: i, Size: U2(0, 0, 0, 40), AutomaticSize: 'X', Text: '', BackgroundColor3: C(T.Raised), BorderSizePixel: 0,
  }, corner(6), vgrad(T.RaisedTop, T.Raised), stroke(T.Edge, 2, { ApplyStrokeMode: 'Border' }), pad(0, 14, 0, 10),
  list({ FillDirection: 'Horizontal', VerticalAlignment: 'Center', Padding: UD(0, 6) }),
  icon('Icon', ic, { Size: U2(0, 24, 0, 24), ImageColor3: C(color), LayoutOrder: 1 }),
  label('Label', txt, { Size: U2(0, 0, 1, 0), AutomaticSize: 'X', TextSize: 18, FontFace: FONT('Oswald', 'Bold'), LayoutOrder: 2 }));
  const sideBtn = (txt, ic, i, badge) => n('ImageButton', txt, {
    LayoutOrder: i, Image: '', BackgroundColor3: C(T.Raised), BorderSizePixel: 0, $attrs: { IconName: ic },
  }, corner(6), vgrad(T.RaisedTop, T.Raised), stroke(T.Edge, 2, { ApplyStrokeMode: 'Border' }),
  icon('Icon', ic, { Position: U2(0.5, 0, 0, 8), AnchorPoint: V2(0.5, 0), Size: U2(0, 34, 0, 34) }),
  label('Label', txt, { Position: U2(0, 0, 1, -4), AnchorPoint: V2(0, 1), Size: U2(1, 0, 0, 16), TextSize: 14, TextColor3: C(T.TextDim), FontFace: FONT('Oswald', 'Medium') }),
  badge && frame('Badge', { Position: U2(1, -2, 0, 2), AnchorPoint: V2(0.5, 0.5), Size: U2(0, 20, 0, 20), BackgroundColor3: C(T.Blood), ZIndex: 3 },
    corner(0, 1), stroke('#000000', 1.5, { ApplyStrokeMode: 'Border', Transparency: 0.3 }),
    label('N', badge, { Size: U2(1, 0, 1, 0), TextSize: 13, FontFace: FONT('Oswald', 'Bold'), ZIndex: 3 })));
  const bar = (name, frac, color, txt, i) => frame(name, { LayoutOrder: i, Size: U2(1, 0, 0, 18), BackgroundColor3: C(T.Inset) }, corner(4),
    frame('Fill', { Size: U2(frac, 0, 1, 0), BackgroundColor3: C(color) }, corner(4), vgrad('#ffffff', '#9a9a9a')),
    label('Text', txt, { Size: U2(1, 0, 1, 0), TextSize: 13, FontFace: FONT('Oswald', 'Medium'), TextStrokeTransparency: 0.6 }));
  const slot = (i, name, sel) => frame('Slot' + i, { LayoutOrder: i, Size: U2(0, 58, 0, 58), BackgroundColor3: C(T.Panel), BackgroundTransparency: 0.15 },
    corner(6), stroke(sel ? T.Ember : T.Edge, sel ? 3 : 1.5, { ApplyStrokeMode: 'Border' }),
    name && icon('Icon', name, { Position: U2(0.5, 0, 0.5, 2), AnchorPoint: V2(0.5, 0.5), Size: U2(0, 36, 0, 36) }),
    label('Key', String(i), { Position: U2(0, 5, 0, 2), Size: U2(0, 12, 0, 14), TextSize: 12, TextColor3: C(T.TextFaint), TextXAlignment: 'Left' }));
  const toast = (i, rich, ic, col) => frame('Toast' + i, { LayoutOrder: i, Size: U2(0, 0, 0, 0), AutomaticSize: 'XY', BackgroundColor3: C(T.Panel), BackgroundTransparency: 0.1 },
    corner(6), stroke(col, 1.5, { ApplyStrokeMode: 'Border', Transparency: 0.2 }), pad(8, 14, 8, 10),
    list({ FillDirection: 'Horizontal', VerticalAlignment: 'Center', Padding: UD(0, 8) }),
    icon('Icon', ic, { Size: U2(0, 22, 0, 22), ImageColor3: C(col), LayoutOrder: 1 }),
    label('Msg', rich, { LayoutOrder: 2, Size: U2(0, 0, 0, 0), AutomaticSize: 'XY', RichText: true, TextSize: 16, FontFace: FONT('Oswald') }));

  return [
    screen('Vignette', { IgnoreGuiInset: true, DisplayOrder: -1 },
      frame('Shade', { Size: U2(1, 0, 1, 0), BackgroundColor3: C('#000000') },
        n('UIGradient', 'UIGradient', { Rotation: 90, Transparency: NS([0, 0.35], [0.22, 1], [0.78, 1], [1, 0.25]) }))),
    screen('HUD', { DisplayOrder: 0, ResetOnSpawn: false },
      frame('TopCenter', { AnchorPoint: V2(0.5, 0), Position: U2(0.5, 0, 0, 8), Size: U2(0, 0, 0, 40), AutomaticSize: 'X', BackgroundTransparency: 1 },
        scale(s), list({ FillDirection: 'Horizontal', Padding: UD(0, 8), VerticalAlignment: 'Center' }),
        btn('Base', 'BASE', 'tent', T.Ember, 1), btn('Eggs', 'EGGS', 'egg', T.Moon, 2)),
      frame('CampPanel', { Position: U2(0, 12, 0, 8), Size: U2(0, 230, 0, 0), AutomaticSize: 'Y', BackgroundTransparency: 0.12 },
        scale(s), corner(6), vgrad(T.PanelTop, T.Panel), stroke(T.Edge, 2, { ApplyStrokeMode: 'Border' }), pad(10), list({ Padding: UD(0, 7) }),
        label('Title', 'YOUR CAMP', { LayoutOrder: 1, Size: U2(1, 0, 0, 22), TextXAlignment: 'Left', TextSize: 20, TextColor3: C(T.Ember), FontFace: FONT('Oswald', 'Bold') },
          label('Plot', 'PLOT 3', { Position: U2(1, 0, 0.5, 0), AnchorPoint: V2(1, 0.5), Size: U2(0, 0, 0, 18), AutomaticSize: 'X', TextSize: 13, TextColor3: C(T.TextDim), FontFace: FONT('Inconsolata', 'Bold') })),
        bar('Protection', 0.64, T.Moss, 'Protected · 3:12', 2),
        label('Nests', '<font color="#eee4ce">Nests</font>  <b>3</b>/6 incubating', { LayoutOrder: 3, Size: U2(1, 0, 0, 18), RichText: true, TextXAlignment: 'Left', TextSize: 15, TextColor3: C(T.TextDim) }),
        n('TextButton', 'Lock', { LayoutOrder: 4, Size: U2(1, 0, 0, 34), Text: 'LOCK BASE (30s)', BackgroundColor3: C(T.Blood), BorderSizePixel: 0, TextColor3: C(T.Text), TextSize: 17, FontFace: FONT('Oswald', 'Bold') },
          corner(6), vgrad(T.BloodBright, T.Blood), stroke(T.BloodDeep, 2, { ApplyStrokeMode: 'Border' }))),
      frame('SideButtons', { AnchorPoint: V2(0, 0.5), Position: U2(0, 12, 0.5, 0), Size: U2(0, 146, 0, 0), AutomaticSize: 'Y', BackgroundTransparency: 1 },
        scale(s), grid({ CellSize: U2(0, 69, 0, 66), CellPadding: U2(0, 8, 0, 8) }),
        ...[['Store', 'cart'], ['Codex', 'book'], ['Gifts', 'gift', '3'], ['Spin', 'wheel'], ['Rebirth', 'rebirth'], ['Invite', 'friends'], ['Settings', 'gear']]
          .map(([t, ic, b], i) => sideBtn(t, ic, i, b))),
      frame('CashPill', { AnchorPoint: V2(0.5, 1), Position: U2(0.5, 0, 1, -84 * s), Size: U2(0, 0, 0, 44), AutomaticSize: 'X', BackgroundColor3: C(T.Panel), BackgroundTransparency: 0.1 },
        scale(s), corner(0, 1), stroke(T.MossDeep, 2, { ApplyStrokeMode: 'Border' }), pad(0, 16, 0, 10),
        list({ FillDirection: 'Horizontal', VerticalAlignment: 'Center', Padding: UD(0, 8) }),
        icon('Coin', 'coins', { LayoutOrder: 1, Size: U2(0, 28, 0, 28), ImageColor3: C(T.EmberBright) }),
        label('Cash', '$1.25M', { LayoutOrder: 2, Size: U2(0, 0, 1, 0), AutomaticSize: 'X', TextSize: 30, TextColor3: C(T.MossBright), FontFace: FONT('Oswald', 'Bold') }, stroke('#0b1a08', 2)),
        label('Rate', '+$4.2K/s', { LayoutOrder: 3, Size: U2(0, 0, 1, 0), AutomaticSize: 'X', TextSize: 15, TextColor3: C(T.Moss), FontFace: FONT('Inconsolata', 'Bold'), TextYAlignment: 'Bottom' }, pad(0, 0, 9, 0))),
      frame('Hotbar', { AnchorPoint: V2(0.5, 1), Position: U2(0.5, 0, 1, -12), Size: U2(0, 0, 0, 58), AutomaticSize: 'X', BackgroundTransparency: 1 },
        scale(s), list({ FillDirection: 'Horizontal', Padding: UD(0, 6) }),
        ...[['lantern', 1], ['net', 0], ['egg', 0], [null, 0], [null, 0], ['trap', 0]].map(([ic, sel], i) => slot(i + 1, ic, sel))),
      frame('Daily', { AnchorPoint: V2(1, 0.5), Position: U2(1, -12, 0.45, 0), Size: U2(0, 190, 0, 0), AutomaticSize: 'Y', BackgroundColor3: C(T.Raised) },
        scale(s), corner(8), vgrad(T.RaisedTop, T.Panel), stroke(T.Ember, 2, { ApplyStrokeMode: 'Border', Transparency: 0.3 }), pad(10), list({ Padding: UD(0, 6), HorizontalAlignment: 'Center' }),
        label('Head', 'DAILY CACHE', { LayoutOrder: 1, Size: U2(1, 0, 0, 20), TextSize: 18, TextColor3: C(T.EmberBright), FontFace: FONT('Oswald', 'Bold') }),
        icon('Chest', 'chest', { LayoutOrder: 2, Size: U2(0, 64, 0, 64), ImageColor3: C(T.EmberBright) }),
        label('Body', 'Day <b>4</b> reward: <font color="#FFC268">Golden Egg</font>', { LayoutOrder: 3, Size: U2(1, 0, 0, 0), AutomaticSize: 'Y', TextWrapped: true, RichText: true, TextSize: 15 }),
        label('Timer', 'ready in 02:41:17', { LayoutOrder: 4, Size: U2(1, 0, 0, 16), TextSize: 14, TextColor3: C(T.TextDim), FontFace: FONT('Inconsolata', 'Bold') }),
        n('TextButton', 'Claim', { LayoutOrder: 5, Size: U2(1, 0, 0, 32), Text: 'CLAIM', TextColor3: C(T.TextOnAccent), TextSize: 17, FontFace: FONT('Oswald', 'Bold'), BackgroundColor3: C(T.Ember), BorderSizePixel: 0, AutoButtonColor: true },
          corner(6), vgrad(T.EmberBright, T.Ember))),
      frame('Toasts', { AnchorPoint: V2(1, 0), Position: U2(1, -12, 0, 8), Size: U2(0, 360, 0, 200), BackgroundTransparency: 1 },
        scale(s), list({ Padding: UD(0, 6), HorizontalAlignment: 'Right' }),
        toast(1, '<b>Mothman</b> hatched! <font color="#D6D2E8"><b>SECRET</b></font>', 'sparkle', T.Secret),
        toast(2, '+<font color="#B8EE8E">$12,400</font> collected', 'coins', T.Moss),
        toast(3, '<font color="#FF6252">Someone is stealing from you!</font>', 'alert', T.Blood))),
  ];
}
function hud(vw, vh, inset) {
  const boards = [
    n('BillboardGui', 'NestLabel', { Size: U2(0, 180, 0, 64), AlwaysOnTop: true },
      frame('Bg', { Size: U2(1, 0, 1, 0), BackgroundTransparency: 0.25 }, corner(6), stroke(T.Edge, 1.5, { ApplyStrokeMode: 'Border' }),
        list({ HorizontalAlignment: 'Center', VerticalAlignment: 'Center', Padding: UD(0, 1) }),
        label('Name', 'Jersey Devil Egg', { LayoutOrder: 1, Size: U2(1, 0, 0, 20), TextSize: 17, FontFace: FONT('Oswald', 'Bold') }),
        label('Rarity', 'EPIC', { LayoutOrder: 2, Size: U2(1, 0, 0, 14), TextSize: 13, TextColor3: C('#a46ee0'), FontFace: FONT('Oswald', 'SemiBold') }),
        label('Timer', 'hatches in 1:42', { LayoutOrder: 3, Size: U2(1, 0, 0, 14), TextSize: 13, TextColor3: C(T.TextDim), FontFace: FONT('Inconsolata', 'Bold') }))),
    n('BillboardGui', 'OwnerTag', { Size: U2(0, 220, 0, 36) },
      label('Owner', "aluminumartsar's camp", { Size: U2(1, 0, 1, 0), TextSize: 22, TextColor3: C(T.EmberBright), FontFace: FONT('Creepster') }, stroke('#000000', 2))),
    n('BillboardGui', 'PlotSign', { Size: U2(8, 0, 2, 0) }, label('T', 'scale-sized (skipped)', { Size: U2(1, 0, 1, 0) })),
  ];
  return dump('hud', vw, vh, [...hudScreens(vw, vh), ...boards]);
}
function hudShop(vw, vh, inset) {
  const s = +Math.min(1.2, Math.max(0.7, vh / 650)).toFixed(4);
  // windows shrink further if they would not fit (like Window.luau)
  const ws = +Math.min(s, (vh - inset - 28) / 430, (vw - 28) / 560).toFixed(4);
  const card = (i, name, rarity, col, price) => frame('Item' + i, { LayoutOrder: i, BackgroundColor3: C(T.Raised) },
    corner(6), vgrad(T.RaisedTop, T.Raised), stroke(col, 1.5, { ApplyStrokeMode: 'Border', Transparency: 0.35 }),
    icon('Icon', 'egg', { Position: U2(0.5, 0, 0, 8), AnchorPoint: V2(0.5, 0), Size: U2(0, 56, 0, 56), ImageColor3: C(col) }),
    label('Name', name, { Position: U2(0, 6, 0, 68), Size: U2(1, -12, 0, 18), TextSize: 15, FontFace: FONT('Oswald', 'SemiBold'), TextTruncate: 'AtEnd' }),
    label('Rarity', rarity, { Position: U2(0, 6, 0, 86), Size: U2(1, -12, 0, 14), TextSize: 12, TextColor3: C(col), FontFace: FONT('Oswald', 'Medium') }),
    label('Price', price, { Position: U2(0.5, 0, 1, -6), AnchorPoint: V2(0.5, 1), Size: U2(0, 0, 0, 22), AutomaticSize: 'X', BackgroundTransparency: 0, BackgroundColor3: C(T.MossDeep), TextColor3: C(T.MossBright), TextSize: 14, FontFace: FONT('Oswald', 'Bold') }, corner(0, 1), pad(0, 10)));
  const items = [['Mothman Egg', 'SECRET', T.Secret, '$25M'], ['Jersey Devil Egg', 'EPIC', '#a46ee0', '$1.2M'], ['Wendigo Egg', 'LEGENDARY', '#f0b030', '$8M'],
    ['Skunk Ape Egg', 'RARE', '#4f9bd9', '$250K'], ['Jackalope Egg', 'UNCOMMON', T.Moss, '$40K'], ['Chupacabra Egg', 'RARE', '#4f9bd9', '$300K'],
    ['Fresno Nightcrawler Egg', 'COMMON', '#b0aca4', '$5K'], ['Bigfoot Egg', 'MYTHIC', '#e0605a', '$60M'], ['Thunderbird Egg', 'EPIC', '#a46ee0', '$2M'],
    ['Lizard Man Egg', 'COMMON', '#b0aca4', '$8K'], ['Dover Demon Egg', 'UNCOMMON', T.Moss, '$55K'], ['Flatwoods Egg', 'LEGENDARY', '#f0b030', '$9.5M']];
  const shop = screen('Shop', { DisplayOrder: 10, IgnoreGuiInset: true },
    frame('Backdrop', { Size: U2(1, 0, 1, 0), BackgroundColor3: C(T.Backdrop), BackgroundTransparency: 0.5 }),
    frame('Window', { AnchorPoint: V2(0.5, 0.5), Position: U2(0.5, 0, 0.5, inset / 2), Size: U2(0, 560, 0, 430), BackgroundColor3: C(T.Panel) },
      scale(ws), corner(8), stroke(T.Edge, 2, { ApplyStrokeMode: 'Border' }),
      frame('Header', { Size: U2(1, 0, 0, 58), BackgroundColor3: C(T.PanelTop) }, corner(8), vgrad(T.RaisedTop, T.PanelTop),
        label('Title', 'THE TRADING POST', { Position: U2(0, 18, 0, 0), Size: U2(1, -80, 1, 0), TextXAlignment: 'Left', TextSize: 34, FontFace: FONT('Creepster'), TextColor3: C(T.EmberBright) }, stroke('#000000', 2)),
        n('TextButton', 'Close', { AnchorPoint: V2(1, 0.5), Position: U2(1, -12, 0.5, 0), Size: U2(0, 36, 0, 36), Text: 'X', TextSize: 20, FontFace: FONT('Oswald', 'Bold'), TextColor3: C(T.Text), BackgroundColor3: C(T.Blood), BorderSizePixel: 0 }, corner(6))),
      frame('Tabs', { Position: U2(0, 14, 0, 66), Size: U2(1, -28, 0, 30), BackgroundTransparency: 1 }, list({ FillDirection: 'Horizontal', Padding: UD(0, 6) }),
        ...['EGGS', 'GEAR', 'BOOSTS'].map((t, i) => label('Tab' + t, t, { LayoutOrder: i, Size: U2(0, 0, 1, 0), AutomaticSize: 'X', BackgroundTransparency: 0, BackgroundColor3: C(i === 0 ? T.Ember : T.Raised), TextColor3: C(i === 0 ? T.TextOnAccent : T.TextDim), TextSize: 15, FontFace: FONT('Oswald', 'Bold') }, corner(4), pad(0, 14)))),
      n('ScrollingFrame', 'Items', { Position: U2(0, 14, 0, 104), Size: U2(1, -28, 1, -118), BackgroundColor3: C(T.Inset), BackgroundTransparency: 0.3, BorderSizePixel: 0, CanvasSize: U2(0, 0, 0, 0), AutomaticCanvasSize: L.E('AutomaticSize', 'Y'), ScrollBarThickness: 6, ScrollBarImageColor3: C(T.EdgeBright) },
        corner(6), pad(8), grid({ CellSize: U2(0, 120, 0, 136), CellPadding: U2(0, 8, 0, 8), HorizontalAlignment: 'Center' }),
        ...items.map((it, i) => card(i, ...it)))));
  return dump('hud-shop', vw, vh, [...hudScreens(vw, vh), shop]);
}

// ------------------------------------------------------------------ perf (~2000 nodes)
function perf(vw, vh, inset) {
  const cards = [];
  for (let i = 0; i < 480; i++) {
    cards.push(frame('Card' + i, { LayoutOrder: i, BackgroundColor3: C(T.Raised) }, corner(4), stroke(T.Edge, 1, { ApplyStrokeMode: 'Border' }),
      icon('Icon', 'egg', { Position: U2(0.5, 0, 0, 4), AnchorPoint: V2(0.5, 0), Size: U2(0, 30, 0, 30), ImageColor3: C(HUES[i % 10]) }),
      label('Name', 'Cryptid #' + i, { Position: U2(0, 2, 1, -16), Size: U2(1, -4, 0, 14), TextSize: 12, TextScaled: i % 3 === 0, FontFace: FONT('Oswald') })));
  }
  return dump('perf', vw, vh, [screen('Inventory', {}, frame('Panel', { AnchorPoint: V2(0.5, 0.5), Position: U2(0.5, 0, 0.5, 0), Size: U2(1, -40, 1, -40), BackgroundTransparency: 0.1 },
    corner(8), pad(10), n('ScrollingFrame', 'Grid', { Size: U2(1, 0, 1, 0), BackgroundTransparency: 1, BorderSizePixel: 0, CanvasSize: U2(0, 0, 0, 0), AutomaticCanvasSize: L.E('AutomaticSize', 'Y'), ScrollBarThickness: 6 },
      grid({ CellSize: U2(0, 76, 0, 58), CellPadding: U2(0, 4, 0, 4) }), ...cards)))]);
}

const FIXTURES = { layouts, text, visuals, hud, 'hud-shop': hudShop, perf };
for (const [name, fn] of Object.entries(FIXTURES)) {
  for (const [w, h] of name === 'perf' ? [[1920, 1080]] : SIZES) {
    const d = fn(w, h, 58);
    fs.writeFileSync(path.join(__dirname, `${name}-${w}x${h}.json`), JSON.stringify(d, null, 1));
  }
}
function count(nd) { return 1 + (nd.children || []).reduce((a, c) => a + count(c), 0); }
console.log('perf nodes:', JSON.parse(fs.readFileSync(path.join(__dirname, 'perf-1920x1080.json'))).roots.reduce((a, r) => a + count(r), 0));
