# Roblox UI preview renderer

Draws approximate "screenshots" of the game's 2D UI from JSON dumps of the GUI instance
tree (produced by the headless engine mock), so a UI redesign can be reviewed without
Roblox Studio.

```
node render.js <dump.json|dir> <outdir> [--scale 1]
```

For every dump it writes

* `<outdir>/<checkpoint>-<w>x<h>.html`: a self-contained page (dump, layout engine and
  fonts are all inlined). Open it in any browser and hover an icon placeholder to see its name.
* `<outdir>/<checkpoint>-<w>x<h>.png`: a Chromium screenshot at the dump's viewport size
  (multiplied by `--scale`).

| option | meaning |
| --- | --- |
| `--scale N` | device pixel ratio of the PNG (default 1; use 2 for a sharp zoomable image) |
| `--billboards over\|under\|off` | world-labels strip drawn over the ScreenGuis (default), under them, or not at all |
| `--rects` | also write `<name>.rects.json` with every GuiObject's absolute rect (handy for assertions) |
| `--no-png` | only write the HTML files |
| `--jobs N` | pages rendered in parallel (default 4) |
| `--offline-fonts` | never download fonts; use whatever is in the cache, else system fallbacks |

A directory input renders every `*.json` in it. A file may hold one dump object or an array
of them. The checkpoint name defaults to the file name. Warnings (unknown fonts, skipped roots,
unsupported rich-text tags, and so on) are printed under each result line.

**Requirements:** Node 18+ and Playwright with Chromium. The script tries `require('playwright')`
first, then `/opt/node-tools/node_modules/playwright`. `curl` is used for font downloads, with
Node's `fetch` as a fallback.

## Layout

```
render.js          CLI: reads dumps, resolves fonts, writes HTML, screenshots with Playwright
engine.js          in-page layout + renderer (runs in Chromium, or any browser opening the HTML)
lib/fontmap.js     Roblox font family / Enum.Font -> Google Fonts family + weight tables (shared)
lib/fonts.js       font download + cache (.font-cache/) and @font-face generation
lib/page.js        HTML template and page CSS (background scene, placeholders, ...)
fixtures/          hand-made test dumps (+ build.js / lib.js that generate them)
out/               renders of the fixtures
```

## How it works

1. **Fonts.** Node walks the dump, collects every (family, weight, italic) that text can use,
   including faces, weights, `<b>` and `<i>` inside rich text, and every character. It
   downloads only those faces from the Google Fonts CSS2 API and keeps the latin and
   latin-ext subsets, plus any other subset whose unicode-range covers characters in the dump.
   The downloads are cached in `.font-cache/` next to `render.js` and inlined as base64. If
   Google Fonts can't be reached, the TTFs are fetched from `raw.githubusercontent.com/google/fonts`
   instead (`PREVIEW_FONT_SOURCE=github` forces that path for testing). Unknown families (for
   example cloud `rbxassetid://` fonts) map to Inter, with a warning.
2. **Layout** runs in the page after `document.fonts` has loaded the faces. The engine computes
   absolute rects in JS, the way Roblox does. It does not rely on CSS flexbox. Text is measured
   with canvas `measureText`.
3. **Paint.** It emits one flat list of absolutely positioned divs, in Roblox paint order:
   ScreenGuis by `DisplayOrder` (ties keep dump order), then ZIndex with `Sibling` semantics
   (children above parents, siblings by ZIndex then child order) or `Global` semantics (every
   object in the ScreenGui sorted by ZIndex, ties in tree order). Clipping from
   `ClipsDescendants`, ScrollingFrames and CanvasGroups uses `clip-path`, and `Rotation` uses
   composed CSS transforms about each object's centre.
4. `window.__PREVIEW__` is set to `{done, warnings, stats}` and Playwright takes the screenshot.

## Reproduced closely

* UDim2 Position/Size against the parent's content box (after UIPadding), with AnchorPoint,
  `SizeConstraint` (RelativeXX/YY) and ScreenGui areas. A ScreenGui's area is the viewport minus
  the top `guiInset` unless `IgnoreGuiInset` is set (or `ScreenInsets` is None/DeviceSafeInsets).
* UIListLayout: SortOrder (LayoutOrder then Name, or Name), FillDirection, Padding (UDim scale
  is relative to the parent's size along the fill axis), alignment of the run and of each item
  across it, `Wraps`, `HorizontalFlex`/`VerticalFlex` (Fill, SpaceBetween/Around/Evenly), basic
  UIFlexItem. Only visible GuiObjects that are direct children take part. Their Position and
  AnchorPoint are ignored, as in Roblox. Children inside a Folder are not laid out.
* UIGridLayout: CellSize/CellPadding relative to the parent, FillDirection,
  FillDirectionMaxCells, alignment, StartCorner, and a UIAspectRatioConstraint under the layout.
* AutomaticSize X/Y/XY grows an object to fit its text bounds, its list/grid content size, or
  its children's extents, plus padding. The computed Size is the minimum, and the object grows
  around its AnchorPoint. `AutomaticCanvasSize` works the same way.
* UISizeConstraint, UIAspectRatioConstraint (FitWithinMaxSize, ScaleWithParentSize with
  DominantAxis), UITextSizeConstraint.
* UIScale scales the object about its AnchorPoint. The subtree is laid out at that scale:
  offsets, text sizes, stroke widths and corner radii all scale.
* ScrollingFrame: the canvas is `max(CanvasSize, window size, automatic content)`. Content is
  offset by CanvasPosition and clipped to the frame. A thumb `ScrollBarThickness` wide is drawn
  on the overflowing axis (right side, or left with `VerticalScrollBarPosition = Left`).
* Backgrounds with transparency, UICorner (scale relative to the smaller side, capped at a
  pill), BorderSizePixel/BorderColor3/BorderMode (hidden when there is a UICorner, as in Roblox).
* UIStroke Border is drawn outside the edge (`BorderStrokePosition` Center/Inner honoured) and
  follows the corner radius. UIStroke Contextual on text is a text outline whose opacity follows
  TextTransparency. The legacy TextStroke is a 1 px outline.
* UIGradient: Color and Transparency sequences multiply the object's colour and alpha, with
  Rotation and Offset applied in the object's own 0..1 space as in Roblox. It is applied to the
  background, to text (gradient-filled glyphs), to a UIStroke that has a gradient child, and as
  a mid-point tint to image placeholders.
* Text: TextSize, colour and transparency, X/Y alignment, TextWrapped (breaks at spaces and
  splits words that are too long), TextTruncate (`...`), TextScaled (largest size up to 100 px
  that fits, respecting UITextSizeConstraint), LineHeight, TextBox PlaceholderText. RichText
  supports `<b> <i> <u> <s> <br/> <font color|size|face|family|weight|transparency>`,
  `<stroke color|thickness|transparency>`, `<mark>`, `<uppercase>/<uc>`, `<smallcaps>/<sc>`,
  comments and the `&lt; &gt; &amp; &quot; &apos;` entities. Other tags are stripped with a warning.

## Approximations

* **Fonts** are Google Fonts stand-ins: GothamSSm uses Montserrat (a little wider than
  Gotham), BuilderSans uses Inter, SourceSansPro uses Source Sans 3, Zekton uses Orbitron,
  Guru/Accanthis use EB Garamond, HighwayGothic uses Overpass, and so on (see
  `lib/fontmap.js`). Oswald, Creepster, Special Elite, Inconsolata and Fredoka One are the real
  faces. TextSize is treated as the CSS em size, and glyphs sit in their `TextSize × LineHeight`
  line box with CSS half-leading. Line breaks, TextBounds and AutomaticSize widths can therefore
  differ from Roblox by a few pixels. Missing weights fall back to the nearest available weight
  without synthetic bold or italic.
* **Images are never fetched.** Every `Image` is a tidy dashed placeholder in ImageColor3 /
  ImageTransparency, labelled with `attrs.IconName`, else `attrs.Icon`, else the parent's
  `IconName`, else the object's name. `Fit` assumes a square image. `Slice` is drawn dotted and
  `Tile` as a faint grid. ImageRectOffset/Size, SliceCenter and ResampleMode are ignored.
* **ViewportFrame / VideoFrame** are a dark hatched box with the object's name. The 3D or video
  content is not rendered.
* **CanvasGroup**: GroupTransparency is applied to each descendant, so overlapping children show
  through each other instead of fading as one layer. GroupColor3 is ignored.
* **Rotation** with clipping: rotated objects don't clip their descendants, as in Roblox. A
  non-rotated clipping ancestor of a rotated object clips in the rotated object's frame.
* **UIGradient** on rich text uses one gradient for the whole label, so per-run colours are lost.
  Under a gradient, the text colour is multiplied by the gradient as in Roblox, which can make
  text on a gradient button look tinted.
* **Text strokes** are a ring of text-shadows, which gives round joins. Thick strokes on
  condensed fonts merge into a band, as they do in Roblox. LineJoinMode only changes the
  outer-corner rounding of border strokes.
* **Layout details** not knowable from the dump: equal LayoutOrder is broken by Name, then by
  child order. Partly filled grid rows are aligned individually. UITableLayout is drawn as a
  UIListLayout, and UIPageLayout shows its pages in a row.
* **TextScaled** always wraps at word boundaries, never splits a word, and caps at 100 px (times
  UIScale). Both TextTruncate modes cut by character.
* **BillboardGuis** (class `BillboardGui`, or a root flagged with `billboard: true`, `flags`, or
  an attribute such as `IsBillboard`) are drawn flat in a "world labels" strip at the bottom
  right, at their pixel `Size`, each captioned with its name. The strip shrinks (shown as a
  percentage) on small screens. Billboards sized in studs (scale) are skipped with a warning.
  World position, distance scaling and LightInfluence are ignored.
* **Scene**: the 3D world is replaced by a dark night-woods backdrop (sky gradient, warm low
  glow, pine silhouettes, a few stars) so semi-transparent UI reads roughly as it would in
  game. Faint placeholders show the Roblox topbar buttons and the `guiInset` line. A
  "PREVIEW — approximate render, icons are placeholders" stamp sits bottom-left.

**Not supported:** SurfaceGuis (skipped with a warning), hover/press/selection states,
tweens and animation, TextBox cursor and selection, MaxVisibleGraphemes on rich text, Roblox
CoreGui (chat, leaderboard, backpack) beyond the topbar hint, ScrollBarImage art,
ElasticBehavior and ScrollBarInset.

## Fixtures

`fixtures/build.js` generates the dumps with the default properties filled in, the way the mock
exports them, using the game's "campfire field kit" palette. Each fixture is built at
1920×1080 and 749×368 (guiInset 58).

| fixture | exercises |
| --- | --- |
| `layouts-*` | list layouts in every alignment, padding (offset and scale), SortOrder Name, Wraps, flex Fill/SpaceBetween, UIFlexItem, hidden children, Folder children, grids (alignment, vertical + MaxCells + StartCorner, scale cells + aspect), the 9 AnchorPoints, UIScale about anchor 0.5 vs 0, AutomaticSize Y card and XY pill, size/aspect constraints, RelativeYY, nested AutomaticSize X rows |
| `text-*` | the alignment matrix, wrapping, truncation, TextScaled (+constraint), rich text, legacy and UIStroke text strokes, LineHeight, AutomaticSize chips, wrapped note on a rotated card, the font family/weight table (incl. an unknown cloud font and a legacy `Font` enum), gradient text, TextTransparency, TextBox placeholder |
| `visuals-*` | corners, Border strokes (Outer/Inner/Center, transparent, gradient, miter), gradients (rotations, fade, offset, rainbow), borders, transparency, rotation (nested), ZIndexBehavior Sibling vs Global, ClipsDescendants, ScrollingFrames (auto canvas, CanvasPosition), CanvasGroup, ViewportFrame/VideoFrame, image ScaleTypes and tints, DisplayOrder stacking (listed in reverse), a disabled ScreenGui, IgnoreGuiInset true vs false |
| `hud-*` | a realistic HUD: full-screen vignette (IgnoreGuiInset), camp panel, travel buttons, side-button grid with badge, cash pill, hotbar, daily card, toasts, all with UIScale, plus billboards (one is stud-sized and skipped) |
| `hud-shop-*` | the HUD under a modal shop window (DisplayOrder 10, dim backdrop, scrolling item grid) |
| `perf-1920x1080` | 2,406 nodes (480 inventory cards in a scrolling grid). Layout takes about 60 ms and the whole page about 0.45 s |

Regenerate and render them with:

```
node fixtures/build.js
node render.js fixtures out
```
