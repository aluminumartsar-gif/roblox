# Steal a Cryptid

A Roblox "steal-a-" style RNG game. Buy cryptid eggs, incubate them in nests on
your plot, hatch them into cryptids that print cash, and steal from everyone
else.

- [DESIGN.md](DESIGN.md) — the design
- [TASKS.md](TASKS.md) — build order and status
- [CLAUDE.md](CLAUDE.md) — engineering rules and conventions

Every tunable number lives in one place: [`src/shared/Config.luau`](src/shared/Config.luau).

## Layout

| Repo | Studio |
|------|--------|
| `src/shared/` | `ReplicatedStorage/Shared` |
| `src/server/` | `ServerScriptService/Server` |
| `src/client/` | `StarterPlayerScripts/Client` |

Scripts are authored here and pushed into Studio via the Roblox Studio MCP.
The repo is the source of truth; Studio is a build target.
