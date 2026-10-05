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
    into the profile before the final save.
  - `ProfileLoaded` signal — start per-player systems here, not on
    `PlayerAdded` (the profile isn't there yet).
- **Adding** a profile field: add it to `ProfileTemplate.new()`. Reconcile fills
  it in for existing players. No version bump.
- **Changing/removing** a field: bump `SchemaVersion` and add a migration.
  Never delete old migrations.
- Nests are a dense array; an empty nest is `false`, never `nil`.
- If a profile can't load safely, kick. Never play on a blank profile.
- Studio-only test hook: `ServerStorage.SAC_Debug:Invoke("give"|"dump"|"save"|"wipe"|"status", playerName, ...)`.
  Must be used via a BindableFunction because MCP/command-bar code runs in a
  separate Luau VM and gets its own copies of modules.

### Verifying a push
After pushing scripts to Studio, run `tools/checksum.sh` locally and the body
of `tools/checksum.luau` in the Edit datamodel. The outputs must be identical
line for line — that proves the repo and Studio match byte-for-byte, and that
Studio has no scripts the repo doesn't.

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
- `generate_mesh`, `generate_texture`, `generate_material`,
  `generate_procedural_model` — art generation (art pass, Step 8)

`execute_luau` needs `studio_id` and `datamodel_type` (`Edit`, `Server` or
`Client`). Get `studio_id` from `list_roblox_studios` at the start of a session;
it changes when Studio restarts.

**Writing scripts into Studio:** write the file in `src/` first, then push it:
- small change to an existing script → `multi_edit` with the same edit
- new or heavily rewritten script → `execute_luau` setting `.Source` from a
  `[==[ ... ]==]` long string (check the file has no `]==]` first)

Then verify with the checksum tools. `studio_id` changes every time Studio
restarts — re-run `list_roblox_studios` at the start of each session.
