# Client smoke test (headless)

Runs the real client code (`src/client` + `src/shared`, built the way Rojo
builds `default.project.json`) inside a mock Roblox engine, plays a scripted
session against a fake server, and reports everything that would have
errored in Studio. No Studio, no Roblox install: it runs on
[Lune](https://github.com/lune-org/lune) and takes a few seconds.

```bash
bash tools/smoke/run.sh                 # desktop + phone profiles, full report
bash tools/smoke/run.sh --list          # ...plus the PlayerGui tree after the session
bash tools/smoke/run.sh --profile phone # one profile (desktop | phone | both)
bash tools/smoke/run.sh --verbose       # ...plus every print/warn the game made
bash tools/smoke/run.sh --fixture validation   # self-test: deliberate mistakes must all be caught
bash tools/smoke/run.sh --fixture components   # builds every Components/UI + Window piece
bash tools/smoke/run.sh --snapshots out/ [--viewport 1920x1080]   # GUI tree as JSON per UI checkpoint
bash tools/smoke/run.sh --help
```

Exit code: `0` no failures, `1` failures, `2` harness errors (a bug in the
harness, not the game), `3` a run crashed. With `--fixture`, the fixture's
`expect.txt` (if any) decides instead: every listed mistake must be caught.
With `--snapshots`, `0` means the snapshots were written (game failures are
still printed).

The first run downloads Lune (latest release tag) and Roblox's API dump into
`tools/.lune/` (git-ignored). Delete that folder to update them; pin Lune
with `LUNE_VERSION=0.10.5 bash tools/smoke/run.sh`.

## What a run does

Each device profile (desktop 1920x1080 mouse+keyboard, phone 844x390
touch-only) runs in its own Lune process with a fresh engine:

1. **Start**: builds the data model, has the fake server create everything
   the real one would (Remotes per `Config.Remotes`, `HuntState`, the map's
   tagged plots/nests/pads/doors/lock buttons/belt/shop counter, nest eggs and
   creatures built with the game's own `Shared/ItemVisuals`, belt eggs,
   Player1 + Player2), runs `Client.Main` from `PlayerScripts`, claims a
   camp, spawns the character with the Bat and Field Camera, then sends
   `ProfileUpdated` (a `ProfileTemplate.new()` snapshot, as DataService
   builds it) and `RetentionState` at 5 s.
2. **Server events**, with realistic payloads taken from the services: every
   toast kind, `GlobalAnnounce`, cash popups and every `FeedbackCue`, three
   hatch reveals (Common, Legendary, Secret), Codex discoveries and a
   completed page, a sighting (started, interrupted, captured, dropped,
   picked up, claimed, and one that escapes), a Hunt (warning, chase, someone
   caught, you caught = jumpscare, leaving, ended), the steal alarm in every
   phase, a belt purchase carried home, a rebirth, retention updates.
3. **Screens**: calls every loaded controller's `Open()`, fires the
   Upgrades counter prompt, and clicks every visible, active button under
   PlayerGui (`MouseEnter`, `InputBegan/Ended`, `MouseButton1Down/Up/Click`,
   `Activated`; touch input on the phone profile) - new buttons that appear
   get clicked too. Then keys (E, Q, 1, 2, Tab, Escape) or a screen tap
   through `UserInputService`, and every `ContextActionService` action.
4. **Tools and prompts**: equips, activates and unequips each tool; shows,
   holds (HoldEnded before Triggered, like Roblox), triggers and hides one
   of each ProximityPrompt in the world plus a custom-style mock prompt.
5. **Resize**: viewport 1920x1080 -> 749x368 -> 1280x720.
6. **Respawn**: like Roblox, every ScreenGui with `ResetOnSpawn = true` is
   destroyed, the Backpack is replaced, a new character arrives with
   `CharacterAdded`; then 60 more seconds.

All of it on a virtual clock (30 frames per virtual second, RunService
events every frame, `task.wait`/`delay`/`defer`, `tick`, `os.clock`,
`os.time`, `GetServerTimeNow` all virtual), so ~4 minutes of play take ~3 s.

## The report

* **FAILURES** - errors in any script, event handler or thread (with the
  game file:line and traceback); modules that errored while loading (with the
  root cause when it came from another module); require cycles; `Main`'s
  "failed to require"/"errored during Start()" warnings (with the root
  cause); errors that were caught and then `warn()`ed; API misuse checked
  against Roblox's reflection data: unknown or uncreatable classes, unknown
  members, wrong value types, bad enum items or the wrong enum, writes to
  read-only properties, unknown services, bad arguments to engine methods,
  untweenable tweens, unsupported attribute types; `WaitForChild` that never
  resolved.
* **WARNINGS** - `warn()` output, calls to real Roblox methods the harness
  only stubs (they returned nil), infinite-yield risks, UI destroyed on
  respawn because of `ResetOnSpawn`, suspicious values (non-booleans in bool
  properties, ...).
* **NOTES** - errors swallowed by a `pcall` in game code, project paths that
  weren't built.
* **SUMMARY** - controllers started N/M (and why each other one didn't),
  every ScreenGui/BillboardGui put in PlayerGui with its DisplayOrder and the
  line that created it, buttons clicked/existing per ScreenGui, screens
  opened, prompts simulated, every remote call with its arguments.

`WaitForChild` with no timeout waits forever in Roblox. The harness reports
it as a failure and, after 5 virtual seconds (Roblox's "Infinite yield
possible" moment), raises an error in that thread so the rest of the session
can still be tested. `--wait-abort 0` turns that off and shows literally what
Studio would do (e.g. Main stuck on the first controller that needs it).

## Snapshots (`--snapshots <dir>`)

For drawing preview images of the UI without Studio. Starts the client with
the viewport already at `--viewport` (default 1920x1080; `--profile phone`
for touch input flags), with a mid-game save (cash, rebirth 1, an active Luck
buff), then visits checkpoints and writes `<dir>/<checkpoint>.json` for each:

`hud`, then one per popup opened through the controller's `Open()`
(`robuxshop`, `upgradeshop` - through the counter's ShopPrompt if there is no
`Open()` -, `rebirth`, `codex`, `dailyrewards`, `spinwheel`, `playtimegifts`,
`offlineearnings`, `settings`; the previous one is closed first with
`Window.CloseAll`/`Kit.CloseAll`), `toasts` (every kind + an Announce in a
rarity colour), `reveal` (Legendary hatch, after the stamp lands),
`tutorial` (fresh player, step 2), `sighting`, `hunt` (chase banner),
`steal` (alarm), `prompt` (Steal / Forest Egg, 3 s hold, 1.5 s in), `hotbar`
(two tools, one equipped). A checkpoint whose controller doesn't exist or
didn't load is skipped; `<dir>/index.json` lists what was written and what
was skipped and why. Before each dump, tweens that end within a second are
finished (goal values applied) and longer ones are set to their current
interpolated value.

Each checkpoint file:

```json
{ "checkpoint": "hud", "viewport": { "w": 1920, "h": 1080 }, "guiInset": 58,
  "roots": [ node, ... ] }
```

`roots` holds every ScreenGui under PlayerGui (enabled or not; `"kind":
"screen"`) and every BillboardGui under PlayerGui or Workspace (`"kind":
"billboard"`, `"container": "PlayerGui" | "Workspace"`, `"parentPath"`); roots
also carry `"path"`. A node is

```json
{ "class": "TextLabel", "name": "Title", "props": { ... }, "attrs": { ... }, "children": [ node, ... ] }
```

with the **effective** value (set or default) of the GUI properties (Position,
Size, AnchorPoint, Visible, ZIndex, LayoutOrder, Rotation, colours and
transparencies, borders, ClipsDescendants, AutomaticSize, all text
properties incl. FontFace, image properties incl. ScaleType/SliceCenter,
scrolling properties, PlaceholderText, Enabled, DisplayOrder, IgnoreGuiInset,
ZIndexBehavior, billboard AlwaysOnTop/StudsOffset/ExtentsOffset/MaxDistance/
Adornee, ...) and, for UI modifiers, their own properties only (UIListLayout,
UIGridLayout, UIPadding, UICorner, UIStroke, UIGradient, UIScale, the size
and aspect-ratio constraints, UIFlexItem). Children are GUI objects, UI
modifiers and Folders (3D content of ViewportFrames is left out). Encodings:

| type | JSON |
|---|---|
| number / string / bool | as is (non-finite numbers, e.g. `MaxDistance = inf`, are left out) |
| UDim2 | `{"t":"UDim2","xs":0,"xo":10,"ys":1,"yo":-4}` |
| UDim | `{"t":"UDim","s":0,"o":8}` |
| Vector2 / Vector3 | `{"t":"Vector2","x":0,"y":0}` / `{"t":"Vector3","x":0,"y":0,"z":0}` |
| Color3 | `{"t":"Color3","r":1,"g":0.5,"b":0}` (0..1) |
| Font | `{"t":"Font","family":"rbxasset://fonts/families/Oswald.json","weight":"Bold","style":"Normal"}` |
| EnumItem | `{"t":"Enum","enum":"TextXAlignment","name":"Left"}` |
| ColorSequence | `{"t":"ColorSequence","kps":[{"time":0,"r":1,"g":1,"b":1}, ...]}` |
| NumberSequence | `{"t":"NumberSequence","kps":[{"time":0,"value":0}, ...]}` |
| Rect | `{"t":"Rect","x0":0,"y0":0,"x1":10,"y1":10}` |
| Instance | `{"t":"Ref","path":"Workspace.Map.Plots.Plot_1.Sign"}` |

## What it can and cannot catch

It **can** catch anything that throws at runtime on these code paths, any
misuse of the engine API that Roblox would reject (checked against Lune's
copy of Roblox's reflection database plus the API dump), never-resolving
waits, require problems, and UI that disappears on respawn.

It **cannot**:

* compute layout or geometry: no rendering, no real AbsoluteSize/Position
  (a rough parent-relative estimate is returned; layouts, constraints,
  AutomaticSize and UIScale are ignored), no text measuring beyond an
  estimate. Overlapping or off-screen UI is not detected - use `--snapshots`
  and look.
* simulate physics or the world: no collisions, `Touched`, raycasts (always
  nil), pathfinding, animation playback, sound playback (sounds "play" for 2
  virtual seconds), StreamingEnabled.
* run the server: the fake server answers remotes with plausible success
  tables and fires events from a script; it doesn't run `src/server` (it only
  reuses `ProfileTemplate` and the shared modules). Server bugs and
  client/server disagreements that need the real server are out of reach.
* type-check (use `tools/analyze.sh`), or know about behaviour the API
  dump doesn't describe. Signals fire immediately (not Roblox's deferred
  mode); tweens jump to their goal when they finish.
* load the STUD UI kit (`vendor/stud/STUD.rbxm` is git-ignored and absent),
  so the controllers that still use `Components/Kit` fail - correctly.

## Files

* `run.sh` - downloads Lune + API dump, runs `main.luau`.
* `main.luau` - arguments, one child process per profile, merged report.
* `lib/` - `sched` (virtual clock, threads), `signal`, `reflect` (DB + API
  dump), `inst` (the validating mock Instance), `classes` (per-class
  behaviour), `services`, `datatypes` (TweenInfo, Random, DateTime,
  RaycastParams, checked `Enum`), `loader` (Rojo tree, script environments,
  `require`), `world` (the fake server), `scenario`, `snapshot`, `report`.
* `fixtures/<name>/` - stand-ins for `src/client` (`--fixture <name>`);
  `include.txt` borrows real `src/client` folders, `expect.txt` lists the
  failures that must be reported.
