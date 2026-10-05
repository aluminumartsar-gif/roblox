# TASKS.md — Steal a Cryptid

Build order and status. One step at a time; stop and report after each.
See [CLAUDE.md](CLAUDE.md) for the working rules and [DESIGN.md](DESIGN.md) for
the design.

**Status key:** `[ ]` not started · `[~]` in progress · `[x]` done · `[!]` blocked on the owner

---

## Step 0 — Foundation `[x]`

- [x] Verify the Roblox Studio MCP is connected and list its tools
- [x] Inspect the open place (`Place1`, placeId `129517233521666`, empty baseplate)
- [x] Create the repo at `C:\Users\sfsen\Games\StealACryptid`
- [x] Write `CLAUDE.md`, `DESIGN.md`, `TASKS.md`
- [x] Rojo project file, `.gitignore`, `aftman.toml`
- [x] Write the full `Config` ModuleScript (`src/shared/Config.luau`)
- [x] Build the folder skeleton in Studio
- [x] Push `Config` into Studio and verify it requires cleanly
- [x] Prove a play test can be started and console output read
- [x] Screenshot, commit

**Deliverable:** an empty but correctly-shaped place with a complete, tunable
Config, and a proven MCP loop (edit → play test → read console → screenshot →
commit).

---

## Step 1 — Data layer `[x]`

- [x] ProfileStore was not available (not in inventory or Creator Store
      search), so wrote `SessionStore` — a session-locked DataStore wrapper
      (lock taken inside the same UpdateAsync as the read, heartbeat, stale
      takeover after 30 min, exponential backoff, refuses to write if the lock
      was lost). Falls back to an in-memory store with a red HUD warning if
      DataStores are unreachable.
- [x] Profile schema (`ProfileTemplate`): cash, rebirths, 12-slot nests,
      upgrades, codex, purchases (for idempotent receipts), buffs, stats,
      spawn lock. Reconcile for added fields, migration chain for changed
      ones, repair pass for corrupt data.
- [x] Autosave every 60s (staggered), save + release on leave, `BindToClose`
- [x] `leaderstats`: Cash, Rebirths
- [x] Join / leave lifecycle; kicks with a clear message rather than ever
      playing on a blank profile if a load fails
- [x] `ProfileUpdated` push to the client (coalesced to one per frame);
      `ProfileController` caches it client-side; minimal HUD shows cash
- [x] Studio-only debug hook: `ServerStorage.SAC_Debug` (give/dump/save/wipe/status)
- [x] `tools/checksum.sh` + `tools/checksum.luau` for repo↔Studio verification

**Tested:** join (new profile) → +$12,345 → leave → raw DataStore record
shows cash saved and lock released → rejoin → cash restored, join count 2.
Simulated second server: load refused (Locked), overwrite refused
(LostLock), real save untouched. Corrupt-profile repair verified.
Negative/NaN/infinite cash amounts rejected.

---

## Step 2 — Map `[ ]`

- [ ] Hub with Egg Shop and Upgrade Shop buildings
- [ ] 10 plots in a ring, each with base, walls, door, plot pad
- [ ] The Wilds ring outside the plots
- [ ] Night lighting, fog, lanterns (`Config.Atmosphere`)
- [ ] Plot claim on join / release on leave, with nameplate
- [ ] Door opens only for the owner
- [ ] Lock button: 60s lock, 5-min cooldown
- [ ] Owner +15% walk speed on their own plot
- [ ] `StreamingEnabled`

**Test:** 2 clients — both claim plots, doors respect ownership, lock works.

---

## Step 3 — Eggs, heat, hatching, income `[ ]`

- [ ] Egg Shop purchase flow: buy → placed in an empty nest → blocked with a
      message if none free
- [ ] Heat accrual (0→100 over 10 min), modified by the Incubation Speed
      upgrade and Nest Warmer
- [ ] Hatch prompt → server-side weighted roll using
      `Config.GetRarityChances(eggId, heat, luck)`
- [ ] Creature spawns in the nest (part-based placeholder + billboard name)
- [ ] Income accrual into a per-creature vault, capped by the Vault Size
      upgrade
- [ ] Touch to collect, with the sanity cap
- [ ] **10,000-roll simulation** printing the rarity distribution at heat 0 and
      heat 100, to sanity-check the odds

**Test:** buy → wait → hatch → collect. Simulation output matches the intended
table.

---

## Step 4 — Stealing `[ ]`

- [ ] 3-second steal prompt on eggs and creatures on unlocked plots
- [ ] Carry overhead at −25% speed; cannot lock own base while carrying
- [ ] Claim by touching your own plot pad
- [ ] Owner alarm + red outline + thief's name on screen
- [ ] Bat starter tool: knockback + 1s stun, 0.5s cooldown
- [ ] Drop on death or Bat hit; anyone can pick up
- [ ] Unclaimed items return home after 60s
- [ ] 30s steal cooldown; 2-min same-item immunity; 5-min new-player spawn lock
- [ ] Stolen eggs keep their heat

**Test:** 2 clients — steal, defend with the Bat, drop, re-steal, timeout return.

---

## Step 5 — Rebirth and the Upgrade Shop `[ ]`

- [ ] Rebirth: cost curve, Rare+ requirement, reset/keep sets
- [ ] +25% income and +10% luck per rebirth; nest glow color
- [ ] Sky egg unlock at 1, Void at 3
- [ ] Upgrade Shop UI + purchase flow for all five upgrade tracks

**Test:** rebirth at the threshold, confirm what resets and what survives.

---

## Step 6 — Robux `[ ]`

- [ ] Game pass ownership checks and effects (2× Cash, +4 Nests, Auto Collect,
      VIP, Extended Lock)
- [ ] Dev products and their effects
- [ ] **Idempotent `ProcessReceipt`** — record the PurchaseId before granting
- [ ] Robux Shop UI
- [ ] Graceful handling of unconfigured (`Id = 0`) products

**Test:** Studio test purchases; double-grant attempt must be rejected.
**Owner action needed:** create the passes and products in the Creator
Dashboard and paste the IDs into `Config`.

---

## Step 7 — Sightings and Codex `[ ]`

- [ ] Sighting scheduler (6–10 min), spawn in The Wilds, 90s lifetime
- [ ] Server-wide banner + countdown
- [ ] Player-count-weighted rarity
- [ ] VHS filter near the sighting (tint, grain, FOV wobble)
- [ ] 5-second contested capture hold; damage or a rival hold interrupts
- [ ] Winner carries it home like a stolen item
- [ ] Camera tool → Codex entries as grainy ViewportFrames
- [ ] Rarity-page completion → permanent luck; survives rebirth

**Test:** force a sighting, contest it with 2 clients, carry it home.

---

## Step 8 — Polish and launch `[ ]`

- [ ] UI pass: HUD, bottom bar, plot panel, notification feed, banner
- [ ] Free Roblox sounds and particles; unique Secret hatch sound
- [ ] Global leaderboard
- [ ] First-join tutorial
- [ ] Mobile check on a phone-sized viewport
- [ ] Anti-exploit audit — every remote re-checked against the rules in
      CLAUDE.md §2
- [ ] Performance check — part counts, StreamingEnabled, memory over time
- [ ] Art pass: replace placeholder creatures with generated meshes
- [ ] Launch checklist: icon, thumbnails, description, Creator Dashboard
      monetization

---

## Owner action queue

Things only the owner can do. Ticked when done.

- [x] **Enable Studio Access to API Services** — confirmed working at Step 1
- [ ] **Allow HTTP Requests** — File → Game Settings → Security (only if we end
      up needing it)
- [ ] **Two-player test setup** — Test tab → Clients and Servers → Players: 2
      (needed for Steps 2 and 4)
- [ ] **Create game passes and dev products**, paste IDs into `Config` — Step 6

---

## Open questions for the owner

### 1. The heat bonus fades out on high-tier eggs

Measured from the real Config at Step 0. Heat multiplies Rare+ weights by ×4 at
full heat and then renormalizes — so the boost only has room to work when there
is a lot of Common/Uncommon weight to squeeze out.

| Egg    | Legendary @ heat 0 | @ heat 100 | Effective gain |
|--------|-------------------:|-----------:|---------------:|
| Forest | 1.20%              | 3.12%      | **×2.6**       |
| Void   | 32.0%              | 33.0%      | **×1.03**      |

So Hook 1 — the hatch-now-or-wait decision that the whole game is built on —
is strong for new players and nearly meaningless for endgame players, who are
exactly the ones with the most to lose from a steal.

Three ways to go:

- **(a) Leave it.** Heat is an early/mid-game hook; endgame tension comes from
  raw egg value instead. Simplest, and arguably fine.
- **(b) Rarity-scaled boost.** Boost each rarity by a factor that grows with its
  index (Rare ×2, Epic ×3, Legendary ×4, Mythic ×5, Secret ×6 at full heat)
  instead of one flat ×4 for everything Rare+. The distribution then keeps
  shifting rightward at every tier.
- **(c) Rebalance the high eggs.** Give Sky and Void more Common/Uncommon base
  weight so heat has something to eat, making them high-variance rather than
  just flatly better.

Claude's recommendation: **(b)**. It is a one-line change in
`Config.GetBoostMultiplier` plus a per-rarity table, it keeps every existing
price and weight, and it makes a max-heat Void egg the single most exciting
object in the game — which is what the steal mechanic needs to stay hot at
endgame. Not doing it until you say so. **Needed before Step 3.**

### 2. Spawn lock: first join only, or every join? *(needed before Step 4)*

The design says "new players get a 5-minute spawn lock." Your nests persist
between sessions, so a returning player's plot is full of loot the instant
they spawn, before they've had a chance to look around.

- **First join only** — literal reading; protects true newcomers.
- **Every join** — protects anyone who just loaded in. Common in the genre.

Claude's recommendation: **every join**, but shorter for returning players
(e.g. 5 min first join, 2 min after) — both numbers in Config.
