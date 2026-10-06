# CLAUDE.md — Steal a Cryptid

Working rules and conventions for this project. Read this first, every session.

## What this is

A Roblox "steal-a-" style RNG game. Buy cryptid eggs, incubate them in nests on
your plot, hatch them into cryptids that print cash, and steal from everyone
else. Cozy-spooky night woods. See [DESIGN.md](DESIGN.md) for the full design
and [TASKS.md](TASKS.md) for the build order and current status.

**Roles:** the user is the designer/owner and is *not* a Luau expert. Claude owns
the engineering. Explain things in plain English. Never leave the user to debug
Luau.

## Non-negotiable rules

### 1. Studio is not the source of truth — the repo is
Every script created or edited in Studio is mirrored to `src/` in this repo with
the same name and hierarchy, and committed. Nothing lives only inside Studio.
If a script exists in Studio and not in `src/`, that is a bug.

### 2. Server-authoritative everything
Cash, rolls, hatches, steals, purchases, upgrades, rebirths — all decided on the
server. Clients send *intent* only, through RemoteEvents/RemoteFunctions.

On **every** client→server remote the server must validate:
- **Ownership** — does this player actually own the thing they named?
- **Distance** — is the player within `Config.Prompts.MaxActivationDistance`
  (12 studs) plus `ServerDistanceSlack` of the target?
- **Cooldowns** — per-action timers held server-side.
- **Rate limits** — `Config.Remotes[name].MaxPerMinute`, plus the global
  `Config.RemoteGlobalMaxPerMinute` backstop.
- **State** — is the action even legal right now (nest empty? plot locked?)

Never trust a price, an odds value, a rarity, an item id, a slot index, or a
player reference sent from the client. Look everything up server-side from
`Config` and the server's own state.

### 3. Config-driven
Every tunable number lives in **one** ModuleScript:
`ReplicatedStorage/Shared/Config` (`src/shared/Config.luau`).

Odds, prices, incomes, timers, distances, cooldowns, rate limits, colors, asset
ids. If a designer might want to change it, it goes in Config. No magic numbers
in logic files. No duplicating a Config value into a local constant.

### 4. ProximityPrompts for all hold-to-interact actions
Buy, hatch, steal, capture, collect, lock. This gets mobile support for free.
Hold durations come from `Config.Prompts`.

### 5. Small steps
One numbered step at a time. After each step:
1. Run a play test through the MCP
2. Read the console, fix every error and warning
3. Screenshot
4. Mirror scripts to `src/` and commit
5. **STOP** and report in plain English: what works, what to check in Studio,
   any decisions needed
6. Wait for the user to say "go" before starting the next step

### 6. Studio settings the user must flip
Some things Claude cannot do. When a step needs one, stop and give exact click
paths, then wait:
- **Enable Studio Access to API Services** — File → Game Settings → Security
- **Allow HTTP Requests** — File → Game Settings → Security
- **Two-player test** — Test tab → Clients and Servers → set Players to 2 → Start

### 7. Keep the docs current
`CLAUDE.md` (these rules), `DESIGN.md` (the design), `TASKS.md` (checklist).
Update them as part of the step they change, not later.

## Conventions

### Layout

| Studio                                            | Repo                       |
|---------------------------------------------------|----------------------------|
| `ReplicatedStorage/Shared`                        | `src/shared/`              |
| `ReplicatedStorage/Shared/Config` (ModuleScript)  | `src/shared/Config.luau`   |
| `ReplicatedStorage/Shared/Util/*`                 | `src/shared/Util/`         |
| `ReplicatedStorage/Remotes`                       | created at runtime by the server |
| `ServerScriptService/Server/Services/*`           | `src/server/Services/`     |
| `ServerScriptService/Server/Modules/*`            | `src/server/Modules/`      |
| `ServerScriptService/Server/Bootstrap` (Script)   | `src/server/Bootstrap.server.luau` |
| `StarterPlayerScripts/Client/Controllers/*`       | `src/client/Controllers/`  |
| `StarterPlayerScripts/Client/Components/*`        | `src/client/Components/`   |
| `StarterPlayerScripts/Client/Main` (LocalScript)  | `src/client/Main.client.luau` |
| `StarterGui/*`                                    | `src/starterGui/`          |

File suffixes follow Rojo: `.server.luau` = Script, `.client.luau` =
LocalScript, plain `.luau` = ModuleScript.

### Code style
- `--!strict` at the top of every file. Fix type errors rather than silencing.
- One Service per file. Each exposes `Service.Start()` and is started in order
  by `Bootstrap`. No service requires another service at the top level — take
  dependencies inside `Start()` or via a registry, to avoid require cycles.
- `PascalCase` for modules, services and functions; `camelCase` for locals;
  `SCREAMING_CASE` for file-local constants that are *not* designer-tunable.
- Prefer `task.spawn` / `task.delay` over `spawn` / `delay`.
- Every `pcall` around a DataStore or MarketplaceService call must log the
  failure with enough context to find it.
- Tag world objects with `CollectionService` using `Config.Tags.*` — never
  search the workspace by name.

### Remotes
- Declared in `Config.Remotes`. The server creates them at boot under
  `ReplicatedStorage/Remotes`; the client waits for them.
- Names are always read from Config, never typed as literals.
- Every client→server handler starts with the same guard block: rate limit →
  ownership → distance → cooldown → state.

### Data
- Player state lives in one profile table per player, session-locked by
  `Modules/SessionStore`. **Only `DataService` touches DataStores.**
- Write through the DataService API, never by poking the table and hoping:
  - `AddCash(player, amount, reason)` / `TrySpendCash(player, amount, reason)`
    — validate the amount, update stats + leaderstats, push to the client.
    `TrySpendCash` is the only way to spend: the check and the deduction
    cannot be split.
  - `Mutate(player, fn)` — any other change. Don't yield inside `fn`.
  - `SaveNow(player)` — after anything the player would be furious to lose
    (Robux purchases).
  - `OnBeforeRelease(hook)` — write transient state (e.g. a carried item) back
    into the profile before the final save. `IsShuttingDown()` tells a
    server shutdown apart from a player choosing to leave.
  - `OnAfterRelease(hook)` — `(player, saved)` after the final save (which
    is retried); `saved == false` means the stored profile is the last
    earlier save.
  - `HoldSaves(player)` / `ReleaseSaves(player)` — keep autosave and
    SaveNow back for a moment (steal claims; see Gotchas).
  - `ProfileLoaded` signal — start per-player systems here, not on
    `PlayerAdded` (the profile isn't there yet).
- **Adding** a profile field: add it to `ProfileTemplate.new()`. Reconcile fills
  it in for existing players. No version bump.
- **Changing/removing** a field: bump `SchemaVersion` and add a migration.
  Never delete old migrations.
- Nests are a dense array; an empty nest is `false`, never `nil`.
- If a profile can't load safely, kick. Never play on a blank profile.
- Studio-only test hook: `ServerStorage.SAC_Debug:Invoke(command, playerName, ...)`.
  Commands are listed at the top of `Modules/DebugCommands` (status, give,
  dump, save, wipe, plots, resetlock, simulate, giveegg, setprogress, hatch,
  sell, setslot, nests, carries, carry, unprotect, clearcooldown, snapshot,
  restore, receipt, pass, belt, beltspawn, beltroll, knock, hunt, huntend,
  huntstate, sighting, sightingend, sightings, codex, codexadd, codexclear,
  retention, dailyskip, dailymiss, spinready, gifttime, offline, hatchfx,
  cashfx, tutorial, mapstats, leaderboard).
  Must be used via a BindableFunction because MCP/command-bar code runs in a
  separate Luau VM and gets its own copies of modules.

### Remotes in practice
- Bind every client→server remote with `RemoteGuard.BindFunction` /
  `BindEvent`. That gives the rate limit and pcall for free; handlers still
  do ownership, distance (`RemoteGuard.IsWithinReach`), cooldowns
  (`RemoteGuard.Cooldowns`) and state themselves.
- RemoteFunctions return `{ Ok = bool, Message = string?, ... }`.
- ProximityPrompt `Triggered` is client-fireable from anywhere by exploit
  tools: re-check owner and distance in the handler, same as a remote.
- Server → player messages go through `Modules/Notifier`.

### World and movement
- **The map is generated** by `Modules/MapBuilder` from `Config.Map` and
  `Config.Plot`, rebuilt on every server boot by `WorldService`. Never
  hand-edit map parts in Studio; change Config or MapBuilder. After changing
  MapBuilder, re-run `tools/place-settings.luau` in Edit to refresh the
  saved preview.
- Runtime objects (eggs, creatures, carried items) go in `Workspace.Runtime`,
  never inside `Workspace.Map`.
- **Only `MovementService` sets `Humanoid.WalkSpeed`.** Other systems call
  `MovementService.SetModifier(player, key, multiplier)`.
- `Players.CharacterAutoLoads` is off; `PlotService` loads and respawns
  characters at the owner's plot.
- Find world objects by CollectionService tag (`Config.Tags`), and expect
  them to stream in and out on the client (StreamingEnabled).
- Edit-only place settings live in `tools/place-settings.luau`.

### Eggs, creatures and boosts
- **Luck, income multiplier, hatch speed, nest capacity and vault cap come
  from `BoostService` only.** A new bonus source (pass, potion, rebirth,
  codex) is added there, nowhere else. Game passes go through
  `BoostService.HasPass`, wired to MarketplaceService in Step 6.
- Change what's in a nest only through `NestService` (`SetSlot`, `TakeSlot`,
  `PlaceEgg`, `Hatch`, `Sell`). It saves, pushes and redraws in one go.
- **No heat.** An egg counts `slot.Incubated` seconds up to its
  `Config.Eggs[id].HatchTime` and `NestService` hatches it by itself. Only
  eggs are stealable (`Config.Steal.StealableKinds`); creatures are sold.
- The one exception to "write through the DataService API": the incubation
  and income ticks write `slot.Incubated` / `slot.Vault` straight into the
  profile every second without a client push. Display goes through model
  attributes (`Progress`, `Remaining`, `Vault`).
- Rolls happen in `Modules/EggRoller` on the server. Never roll on a client.
- **Art:** `Shared/ItemVisuals` builds eggs and creatures (client and
  server). It clones generated-mesh templates from
  `ReplicatedStorage.ArtTemplates`, which `ArtService` builds at boot from
  `Config.Art` (ids + heights; `docs/ART.md` has the prompts). Missing or
  failed meshes fall back to block art, so an asset can never break the game.
  The art direction is **scary**: menacing folklore cryptids, not cute.
- **The Hunt:** `HuntService` owns the Brood Mother's logical position and
  publishes it on `ReplicatedStorage.HuntState` attributes; `HuntController`
  draws her locally (like the belt). Catches are decided on the server;
  `StealService.Reclaim` takes back what a caught player carries.

### Egg belt
- Eggs are only sold on the belt (`EggBeltService`). Which egg spawns is
  `Config.Belt.EggWeights`; the odds board is generated from the same table,
  and `SAC_Debug beltroll` proves the picker matches it.
- **Belt motion is client-side.** The server places each belt egg once and
  never moves it; it only stores `SpawnTime`. `Shared/BeltPath` turns age
  into a position, used by `EggBeltController` (drawing, every frame) and by
  the server (reach checks). Change the path in BeltPath only, so both sides
  stay in step. The same trick moves the slats. Exception: the Buy prompt
  lives on an invisible `BuyAnchor` the server also moves (see gotchas).
- A bought egg is a StealService carry with `Source = "Belt"` (no owner, no
  timer while held, left hand). Anything that treats carries as "stolen"
  must check `carry.Source` — e.g. locking is only refused for stolen items.

### Shops, upgrades, rebirth
- Screens are popup Windows built from our UI components — see "UI" below.
- Buying anything at a hub shop checks `ShopUtil.IsAtShop(player, shopId)`.
- After changing upgrade levels (purchase, rebirth, restore), call
  `UpgradeService.ApplyEffects(player)` so nests and walk speed update.
- Rebirth resets exactly `Config.Rebirth.Resets`; add a new resettable key
  in RebirthService *and* the Bootstrap whitelist together.

### Robux
- All Robux logic is in `MonetizationService`. Passes reach the rest of the
  game only through `BoostService.HasPass` (and `Pass_<Key>` player
  attributes for the client).
- The client sends only `("Pass" | "Product", key)`; the server looks up the
  id, refuses `Id = 0`, checks the item makes sense, and prompts itself.
- `ProcessReceiptForKey` is the idempotent core; never grant a product any
  other way. A grant function must not yield.
- Test without real ids via `SAC_Debug` `receipt` (fake purchase through the
  real code) and `pass` (fake ownership, this session only).

### UI (the "campfire field kit")
- Every screen is built from our own components in
  `StarterPlayerScripts/Client/Components/` — the purchased STUD kit and its
  `Components/Kit` bridge are gone (Step 10). The look: charred-wood panels,
  bone text, ember orange for the main action, moonlight blue for info and
  Robux, blood red for danger, moss green for cash, field-journal paper for
  notes; Creepster titles, Oswald for buttons/labels/numbers, SpecialElite
  for flavour text.
- **Never hard-code a colour or font in a screen.** Colours come from
  `Theme.Colors` (`Config.UI.Theme.Colors`) or `Theme.RarityColor(r)` (the
  Secret rarity's near-black is swapped for a readable colour); fonts from
  `UI.Text({ Role, Weight })` / `Theme.Fonts`. The Display (horror) font is
  only for text 28 px and up. Server code (signs, belt labels, leaderboards)
  reads `Config.UI.Theme` directly and sets `FontFace = Font.fromName(...)`.
- `Components/UI` builds everything: text, panels, cards, paper, buttons
  (variants: Primary = the one main action, Cash = in-game $, Moon = Robux
  and info, Danger = risky confirms, Secondary = neutral, Ghost = minor),
  HUD tiles, "!" badges, tabs, inputs, progress bars, pills, scroll lists.
  Its header lists every builder. `UI.new(class, props)` returns `any`, so
  **property names in props tables are not type-checked** — the smoke
  harness catches them (see "Testing without Studio").
- `Components/Window` is every popup: `Window.new({ Name, Title, Icon, Size,
  Info })`, `window.Body`, `:Open(counter?)` (walking away from `counter`
  closes it), `:Close()`, `Window.CloseAll/AnyOpen/Get`. One open at a time.
  Contract: the ScreenGui is Enabled only while it shows and has a direct
  child `Container` (SoundController's open sound and the auto-open checks
  rely on it). Windows shrink themselves to fit phones.
- Layout and draw order are shared so screens never overlap:
  `Config.UI.Layout` (HUD clusters in px at the 650 px reference height —
  travel buttons in the top-bar row, camp panel top left, side tiles left
  middle, Daily + quick-buys right middle, buffs/cash/hotbar bottom centre;
  bottom corners stay clear for the phone thumbstick and jump) and
  `Config.UI.Layers` (every `ScreenGui.DisplayOrder` — never a literal).
  Pixel-sized HUD pieces call `UI.Scale(frame)` (ScreenScale: screen height
  / 650, clamped `Config.UI.ScreenScale`).
- Top centre is a stack: sighting/Hunt banners, then steal banners, then the
  tutorial panel, then toasts. Each panel calls
  `NotificationController.ReserveTop(key, bottomPx | nil)`; a panel that sits
  under others uses `ReservedBottom(exceptKey)` and re-places on
  `ReservationsChanged` (StealController also fires `BannersChanged`).
- HUD buttons other screens own: `HudController.Bind(name, fn, caption?,
  icon?)` for "IndexBtn" (Codex), "GiftBtn", "SpinBtn", "DailyBtn"; then
  `SetAlert(name, on)` / `SetCaption(name, text)`. Tiles stay hidden until
  bound. The HUD ScreenGui is named "HUD".
- Each screen area keeps its own tunables in `Config.UI.<Area>` (Hud, Shops,
  Codex, Retention, Toasts, Tutorial, Banners, Labels, Prompts, Hotbar).
- **Prompts and hotbar are ours too.** `PromptController` draws every
  ProximityPrompt in the theme (client-side `Style = Custom`; touch/click
  calls `InputHoldBegin/End`; steal prompts are blood red via
  `Config.UI.Prompts.AccentByName`). It never changes reach, hold time, line
  of sight, Enabled or parent. `HotbarController` replaces Roblox's backpack
  bar (keys 1–9, tap, gamepad shoulders). `Config.UI.CustomPrompts` /
  `CustomHotbar = false` puts Roblox's defaults back instantly.
- Fast travel (HUD Base/Eggs) is server-side in `TravelService`.
- Test new UI at a phone size too (Studio: Test → Device → a phone; here:
  `tools/preview/shoot.sh` renders 749x368).

### Icons
- The owner's RhosGFX vector icon pack (`../vector-icon-pack.zip`). Its
  license allows use in this game but **forbids redistributing the files and
  using them as input to AI systems**. So: pick icons by file name, never
  open the PNGs, keep extracted files in the scratchpad (never in the repo),
  and verify uploads by load status. The owner OK'd screenshots of the
  finished UI. (The preview renderer draws placeholders and never fetches
  icon images.)
- Every icon is the pack's single-colour "Flat White" glyph, tinted in code
  (`ImageColor3`, default `Theme.Colors.Text`), so they all match. Upload
  flow: `tools/serve-icons.ps1` + the MCP `upload_image` tool; ids go in
  `Config.Icons`. Use them via `Components/Icon` (`Icon.new`, `Icon.addLeft`)
  or the `Icon =` prop of the UI builders. Bootstrap rejects icon names
  missing from `Config.Icons` in Config tables; `Icon.new` warns on unknown
  names.

### Test data
Studio play tests use their own DataStore scope (`Config.Data.StudioStoreScope`),
separate from live servers (`StoreScope`), so testing never touches real
players. The owner's Studio save still matters to them: don't leave
debug-spawned items in it (snapshot before, restore after).
- **Prefer test accounts for destructive tests** (rebirth, wipes): ask the
  owner to start Test → Clients and Servers with 1 player and test on
  "Player1". The owner's real save is never touched.
- If the owner is playing the live game, their save is session-locked by
  that live server and solo Studio Play will be kicked — that's the lock
  working. Use a test account instead.
- `snapshot` / `restore` debug commands exist for when the real save must
  be used.

### Gotchas learned the hard way
- **ProximityPrompt event order:** when a hold completes, Roblox fires
  `PromptButtonHoldEnded` *before* `Triggered`. Never treat HoldEnded alone
  as "they let go" — defer that decision (StealService waits 0.2s and checks
  whether Triggered consumed the hold).
- **Server-side hold timing:** record the time on `PromptButtonHoldBegan`
  and require `Triggered` to come at least HoldDuration − tolerance later,
  and no more than HoldDuration + `Config.Steal.HoldMaxOverrun` later.
  Expire abandoned holds on the server too (a `task.delay`) — never rely
  on the client sending HoldEnded.
- **Luau local functions can't be called above their definition** — the
  name is nil there. Forward-declare (`local publish: (T) -> ()`) and assign
  later with `function publish(...)`.
- **Stealing is dupe-safe only because** the owner's slot stays (marked
  Away) until the claim, and the claim removes it from the owner and adds it
  to the thief in one synchronous step, then saves the owner first — and
  `DataService.HoldSaves(thief)` keeps the thief's autosave/SaveNow back
  until that owner save succeeds (or its retries run out). A leaving
  owner's forfeit only becomes claimable once their final save succeeds
  (`DataService.OnAfterRelease`); a shutdown never forfeits.
- **Terrain heights are not what the numbers say.** Voxels are centred on
  multiples of 4: a FillBlock topped at y = 0 renders its surface at y = 2,
  FillCylinder paint lifts the ground it paints by ~2 studs, and an air cut
  starting at y = -2 drops it to -2. MapBuilder fills 2 studs low
  (`VOXEL_OFFSET`), paints discs as FillBlock strips, and cuts air from y = 0
  up. Always measure with a raycast **after a frame's wait** (collision
  updates a beat later) — this once buried every home pad and nobody could
  claim an egg.
- **The client owns its character's position.** Every reach check reads
  a position the client can teleport; claims also check travel time from
  where the carry started (`Config.Steal.CarryTravelSlack`).

- **Edit-mode tool code caches modules.** Code run in the Edit datamodel
  (MCP or command bar) keeps every module it has required, so after Config
  changes it sees the old Config. Require clones, or swap in a fresh copy of
  `Shared` as `tools/place-settings.luau` does. Play tests are unaffected.
- **Roblox checks prompt triggers on the server** against where the SERVER
  thinks the prompt's part is (solo Play doesn't enforce this — only a
  Clients and Servers test shows it). A prompt on a part that only clients
  move silently stops working. Belt eggs keep their prompt on a BuyAnchor
  the server moves 10x a second.
- **Holds on moving prompts get cut off** when another prompt becomes the
  nearest mid-hold. Moving targets use a tap (`BeltBuyHold = 0`).
- **Prompts on moving belt eggs:** drive them in tests with
  `prompt:InputHoldBegin()` / `InputHoldEnd()` from the Client datamodel
  while standing at the belt edge; simulated E key presses didn't complete
  the hold.

### Multi-client tests through the MCP
- **Re-identify windows every session and assert in every client call**
  (`assert(game.Players.LocalPlayer.Name == "Player2")`). Mixing up which
  window is which player cost a long false-bug hunt in Step 4.
- Background threads (`task.spawn`) started inside an `execute_luau` call
  are cleaned up when the call returns — a prompt hold started in one gets
  released early. Do holds start-to-finish inside a single call.
- Toasts last `Config.UI.NotificationDuration` (4s); read them within a
  second of the action, not after a 3s hold.
- Server code changes need a fresh test session (Rojo writes to Edit only).
  Batch fixes before asking the owner to restart.

After the owner starts Test → Clients and Servers, `list_roblox_studios`
shows one extra Studio per window (names are null). Call `get_studio_state`
on each: the one whose focused datamodel is `Server` is the server; for the
others, run `game.Players.LocalPlayer.Name` in the Client datamodel to see
which player it is. Moving characters server-side (`PivotTo`) and walking
them client-side (`Humanoid:MoveTo`) both work.

### Verifying a push
After pushing scripts to Studio, run `tools/checksum.sh` locally and the body
of `tools/checksum.luau` in the Edit datamodel. The outputs must be identical
line for line — that proves the repo and Studio match byte-for-byte, and that
Studio has no scripts the repo doesn't.

### Static type check
`bash tools/analyze-summary.sh` runs luau-lsp (installed by aftman; Roblox
type definitions are downloaded to the git-ignored `tools/.luau/` — the
script prints the command if they're missing) over `src/` and lists each
problem once. Run it before every push. The existing code carries a few
dozen classic-solver nits that are harmless ("Key 'X' not found in external
type 'Instance'", guarded "could be nil", Signal "Expected this to be",
pcall "Function only returns 1 value"); anything else in a file you touched
is a real bug.

### Testing without Studio (cloud sessions)
A cloud session has no Studio. Before pushing client changes from one, run:
- `bash tools/analyze-summary.sh` — the type check above (works on Linux too;
  needs `rojo`, `luau-lsp` and the type definitions).
- `bash tools/smoke/run.sh` — loads the real `src/client` + `src/shared` in a
  mock Roblox engine (Lune), validates every class, property, enum and value
  type against Roblox's API dump, drives a scenario (server events, every
  button, prompts, tools, resizes, respawn) on PC and phone profiles, and
  reports what would error in Studio. 0 failures expected. `--list` prints
  the GUI tree. It has no physics, layout or real server; see its README.
- `bash tools/preview/shoot.sh` — approximate "screenshots" of every screen
  at 1920x1080 and 749x368 (smoke `--snapshots` + a Chromium renderer with
  the real fonts; icons are placeholders). Good for layout, colours and
  wording; the final look is still checked in Studio.
These never replace a Studio play test: say so when reporting.

### Content rules (legal)
- Common through Legendary are **real folklore cryptids** — public domain.
- Mythic and Secret are **originals** created for this game.
- **Never** use creepypasta or artist-owned characters (e.g. Siren Head,
  Slenderman), and no trademarked names.

## MCP notes

The Roblox Studio MCP is connected. Useful tools:
- `execute_luau` — run Luau in the Edit / Server / Client datamodel
- `script_read`, `multi_edit`, `script_grep` — read/edit scripts in place
- `search_game_tree`, `inspect_instance` — inspect the tree
- `get_console_output` — read the output window
- `start_stop_play` — start/stop a play test
- `screen_capture` — screenshot Studio
- `generate_mesh` — art generation (see `docs/ART.md`). **A play test
  kills in-flight generation jobs** ("Model generation should only be called
  from the server"): pause generation before play-testing. Run at most 2
  jobs at once; prompts with violent words fail moderation.

`execute_luau` needs `studio_id` and `datamodel_type` (`Edit`, `Server` or
`Client`). Get `studio_id` from `list_roblox_studios` at the start of a session;
it changes when Studio restarts.

**Writing scripts into Studio — Rojo (primary):**
1. At the start of a session, run `rojo serve default.project.json` from this
   folder as a background command (port 34872), and ask the owner to click
   **Connect** in the Rojo plugin. Check `rojo sourcemap` first if the tree
   changed, so connecting never deletes something that lives only in Studio.
2. Edit files in `src/` only. Rojo pushes every save into Studio's Edit
   datamodel within a second or two. Never edit synced scripts in Studio:
   sync is one-way and Studio edits get overwritten.
3. Rojo writes to the **Edit** datamodel. Stop any running play test first
   (or restart it) so the test uses the new code.
4. Verify with the checksum tools after every batch of edits.

Instances that are *not* scripts (map parts, folders under Workspace,
ServerStorage assets) are not Rojo-managed. Build them with `execute_luau`,
and keep the code that builds them in `src/` as a builder module so they
can be regenerated.

**Fallback if Rojo isn't connected:** push via `multi_edit` (small edits) or
`execute_luau` setting `.Source` from a `[==[ ... ]==]` long string (check the
file has no `]==]` first), then verify with the checksum tools.

`studio_id` changes every time Studio restarts — re-run
`list_roblox_studios` at the start of each session.
