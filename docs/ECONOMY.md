# ECONOMY.md — progression check (auto-hatch design)

*Written for the owner and the lead. The plain-English summary comes first,
then the numbers, then exactly what to change. Re-run on 2026-10-05 for the
current design: no heat, eggs hatch by themselves, fixed odds per egg, only
eggs can be stolen, Sell, the Hunt, Sightings, Codex and the retention
rewards. The previous check was for the old heat design, which is gone.*

## The short version

The new design fixed the old problems. Nobody gets stuck any more, there's
something new to do every few minutes, and the first upgrade comes inside 3
minutes. **The one problem is the opposite of last time: the game is now too
fast.**

- **Rebirth 1 comes at ~16 minutes** (target 30–60), and at **~14 minutes**
  for a real new player who also gets the daily reward, the free spin and the
  playtime gifts. Rebirths 2 and 3 follow at about 36 and 61 minutes. Income
  goes from $150/s at 10 minutes to $3,000/s at 4 hours.
- The reason is that **every egg is a lottery ticket with the jackpot
  included.** A $100 Forest egg has a 0.5% Mythic ($1,200/s) and a 0.1%
  Secret ($6,000/s) chance. With Sell, a player opens ~280 eggs in 4 hours, so
  the jackpots keep landing, and each one pays for a rebirth in minutes.
- **Selling is what keeps the game moving.** A simulated player who never
  sells stalls at ~$70/s, and 8–32% of them never rebirth. The game mentions
  Sell only in the last tutorial card and in the belt's "No empty nest" message.

**Proposed fix (Config only, no code):**

| Change | From | To |
|---|---:|---:|
| `Config.Rebirth.BaseCost` | 75,000 | **400,000** |
| `Config.Rebirth.CostGrowth` | 2.2 | **2.3** |
| 15-minute playtime gift: `Minutes` on its Cash item | 5 | **2** |
| 40-minute playtime gift: `Minutes` on its Cash item | 10 | **4** |

With these changes: **rebirth 1 at ~34 min** (~30 min with all first-session
rewards), rebirth 2 ~77 min, rebirth 3 ~139 min, Void eggs ~3.2 h. First
upgrade is still 2.5 min, nobody stalls, and the longest wait between goals
in hour 1 is ~8 min (that's the save-up for the rebirth itself).

Nothing else needs to change. Egg prices, hatch times, upgrade costs,
Sell.RefundSeconds, belt weights and starting cash were all tested and are
fine as they are (see "Levers that don't matter much").

---

## How the simulation works

A Monte-Carlo model of one typical player over 4 hours: 200 players with
fixed seeds, so every run gives the same answer. It uses the real Config
tables, the real `Config.GetRarityChances(egg, luck)` for every hatch and
`Config.GetRebirthCost` / `GetUpgradeValue` / `GetUpgradeNextCost`. It ran in
Studio's Edit datamodel against an **unparented clone of Config**, so nothing
was added to the place. At the time, Studio's Config was the same size as the
repo's (91,927 bytes), and the egg, sell, rebirth and economy values were
spot-checked against it. The source is in the appendix.

What the simulated player does, second by second:

- **Start:** `Config.Economy.StartingCash` ($500). If they have no eggs, no
  cryptids and less than $100, they get the rescue egg (Forest, 180 s
  cooldown), as NestService does.
- **Belt:** one egg every `Belt.SpawnInterval` (2 s), picked by
  `Belt.EggWeights`. They aim for the best tier they can afford, splitting
  their cash over up to 2 free nests. They also take one tier lower, and
  anything affordable after 40 s of waiting. **They win a wanted egg 50% of
  the time** (other players, missed taps). Eggs they haven't unlocked ride past.
- **Travel:** fast travel to the belt takes 3 s and respects `Travel.Cooldown`
  (8 s). The walk home carrying the egg is 196 studs at Walk Speed ×
  `Belt.CarrySpeedMultiplier`.
- **Incubation:** each egg counts up to `Eggs[id].HatchTime` at the Hatch
  Speed upgrade's rate (× `HatchBoost.Multiplier` while a Hatch Boost is
  active). It hatches by itself with fixed odds plus luck. The player makes
  no choices here.
- **Income and vaults:** `Rarities[r].IncomePerSecond` × (1 + 0.25 per
  rebirth). Vault cap = max(Vault Size, 600 s of the creature's own income).
  They collect every 90 s while home, and before each belt trip.
- **Upgrades:** they buy the cheapest one as soon as they can afford it and
  still keep $100 per empty nest for eggs. They stop buying once they're
  saving for a rebirth (they own a Rare+ and have half the cost).
- **Selling:** when every nest is full, they sell the weakest cryptid (never
  their last Rare+) if they can afford an egg whose *typical* income
  (Common..Legendary, ignoring the Mythic/Secret jackpots) is at least **2×**
  that cryptid's income. Selling pays vault + `Sell.RefundSeconds` (60) of
  income.
- **Rebirth:** as soon as they can afford it and own a Rare+, and aren't
  carrying anything. It resets cash to `Rebirth.StartingCash` ($1,500), nests
  and upgrades, exactly like `Config.Rebirth.Resets`. Each rebirth gives +10%
  luck and +25% income. Sky unlocks at rebirth 1, Void at 3.
- **Theft (eggs only):** each egg in a nest has a steady per-second chance of
  being stolen: 20% per 90 s, ×1.5 for announced eggs (Sky/Void), and none
  during the 300 s new-player spawn lock. So slow, big eggs are the juicy
  targets. That works out to **11% of all eggs lost**: ~9% of Forest eggs,
  ~31% of Deep Sea, ~60–75% of unguarded Sky/Void eggs. In return, after
  bringing a belt egg home, they go on a 50 s raid 45% of the time and come
  back with an egg of about their own tier, 0–80% done. They steal about as
  many eggs as they lose, and stolen eggs are free.
- **The Hunt:** hunts follow `Config.Hunt` (first at 240 s, then every
  420–600 s, 70 s each plus warning and leave time). A player who buys an egg
  while she's out waits by the fire half the time; otherwise they walk and are
  caught 30% of the time (belt egg gone, stunned). About 4–5 catches per 4 hours.
- **Extras** (the "+ extras" columns only):
  - Daily day 1, the free spin (rolled by its weights) and every playtime
    gift, applied exactly as Config describes them: Cash = max(Base, Minutes
    of income), Eggs go to a free nest or are saved, and Buffs and Instant
    Hatch work as they do in game.
  - Sightings per `Config.Sightings`, never during a hunt. This player wins
    20% of them (a server of 8), and a win takes a 60 s trip.
  - Codex luck from hatching alone (photos would make it a bit faster).
- **Not modelled:** Robux (passes, products, cash packs), offline earnings,
  the Bat, locking your camp. The theft rates above stand in for all of the
  stealing back and forth.

A "goal" is any of: a new egg tier affordable for the first time, a rarity
seen for the first time, an upgrade bought, or a rebirth. "Stalled" means 60+
minutes with no new goal at some point in the 4 hours.

---

## Results as built

Minutes of play: median [25th..75th percentile]. "never X%" means that share
of players didn't get there in 4 hours. Upgrade levels are before the first
rebirth (rebirth resets them).

| Milestone | As built | As built + extras | **Proposed** | **Proposed + extras** |
|---|---|---|---|---|
| First cryptid | 1.1 | 1.0 | 1.1 | 1.0 |
| First upgrade | **2.5** [2.1..2.9] | 0.1 | **2.5** | 0.1 |
| First Rare+ | 2.3 | 1.6 | 2.3 | 1.6 |
| First sell | 3.7 | 3.7 | 3.7 | 3.7 |
| 6 cryptids at once | 4.8 | 4.3 | 4.8 | 4.2 |
| Can afford Swamp ($600) | 2.7 | 0.1 | 2.7 | 0.1 |
| Can afford Mountain ($4K) | 5.7 | 3.7 | 5.7 | 3.7 |
| Can afford Deep Sea ($30K) | 13.5 | 10.6 | 13.5 | 10.6 |
| Can afford Sky ($250K, R1+) | 58.2 | 40.0 | 61.7 | 54.2 |
| Can afford Void ($2.5M, R3+) | 180 (never 3%) | 163 | 194 (never 13%) | 180 (never 8%) |
| Hatch Speed L2 / L3 / L4 / L5 | 2.5 / 5.8 / 13.0 (never 24%) / — | 0.1 / 4.4 / 10.6 / — | 2.5 / 5.8 / 12.6 / 26.3 | 0.1 / 4.4 / 9.9 / 23.3 |
| Walk Speed L2 / L3 / L4 | 3.1 / 6.5 / — | 1.4 / 5.8 / — | 3.1 / 6.5 / 16.3 | 1.4 / 5.8 / 13.9 |
| Nest Slots L2 / L3 / L4 / L5 | 3.5 / 7.6 / 15.7 (never 52%) / — | 2.2 / 5.8 / 12.1 / — | 3.5 / 7.5 / 14.1 / 30.0 (never 42%) | 2.2 / 5.8 / 11.7 / 26.5 |
| Lock Duration L2 / L3 / L4 | 4.2 / 9.5 / — | 3.0 / 7.1 / — | 4.2 / 9.2 / 18.8 | 3.0 / 6.6 / 15.1 |
| Vault Size L2 / L3 / L4 | 5.6 / 11.4 / — | 3.6 / 9.2 / — | 5.6 / 11.2 / 22.5 | 3.6 / 8.4 / 19.4 |
| **Rebirth 1** | **16.3** [12.6..21.8] | **13.6** [6.8..15.2] | **33.7** [26.1..42.1] | **29.6** [19.5..36.9] |
| Rebirth 2 | 36.2 | 31.4 | 76.6 | 66.2 |
| Rebirth 3 | 60.9 | 48.6 | 139.2 | 125.0 |
| Rebirth 4 | 91.5 | 76.0 | 201.5 (never 25%) | 184.5 (never 18%) |
| Longest stretch with no new goal, hour 1 | 6.0 [4.9..7.2] | 5.5 | 7.9 [6.3..9.3] | 7.7 |
| Stalled (60+ min, no new goal) | 0% | 0% | 0% | 0% |

"—" = most players rebirth before reaching that level.

**Income per second** (median player; dips are rebirths resetting the nests):

| | 2m | 5m | 10m | 15m | 20m | 30m | 45m | 60m | 90m | 120m | 180m | 240m |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| As built | $8 | $74 | $154 | $169 | $169 | $211 | $360 | $558 | $1.09K | $1.58K | $2.2K | $3.07K |
| As built + extras | $17 | $93 | $132 | $120 | $150 | $413 | $269 | $847 | $1.34K | $1.64K | $2.34K | $3.22K |
| **Proposed** | $8 | $76 | $199 | $375 | $480 | $610 | $450 | $813 | $987 | $1.47K | $1.71K | $1.96K |
| Proposed + extras | $17 | $96 | $229 | $405 | $445 | $670 | $395 | $976 | $1.13K | $1.47K | $1.82K | $2.46K |

Per player over 4 hours (as built): ~280 eggs placed, ~180 cryptids sold,
~31 eggs stolen from them (11%), ~28 stolen by them, ~5 Brood Mother catches,
~1 sighting won (with extras).

### Compared with good Roblox simulator pacing

| Target | As built | Proposed |
|---|---|---|
| First upgrade < 3 min | 2.5 min (0.1 with the daily reward) | same |
| A new goal every few minutes | longest gap ~6 min | ~8 min, and that gap *is* the rebirth save-up (the progress bar is the goal) |
| First rebirth 30–60 min | **16 min** (14 with rewards): too fast | **34 min** (30 with rewards) |
| Rebirths keep spacing out | 16 → 36 → 61 → 92: every ~25 min, the loop gets samey | 34 → 77 → 139 → 202: each one a bigger climb |
| Nobody stuck | 0% stalled (selling players) | 0% stalled |
| Long-term goals stay reachable | Sky ~1 h, Void ~3 h | Sky ~1 h, Void ~3.2 h |

### How many players get stuck

- **Players who sell: nobody.** 0% stalled in every variant. Without heat,
  a Rare+ is easy (25% of Forest eggs), so the rebirth requirement never
  blocks anyone (first Rare+ at ~2 min).
- **Players who never sell:** income flat at ~$55–90/s for the whole session.
  As built: 8% never rebirth, 12% stall for an hour or more, hour-1 gap 13.5
  min. Proposed: 32% never rebirth, 38% stall. A **picky seller** (only
  sells for a 4× better egg) is fine: rebirth 1 at 42 min, 2% stall.
- So the real "stuck" risk is a player who doesn't know Sell exists. See
  "Outside Config" below.

---

## Why it's fast, and which levers matter

Income per egg at luck 0, from the Config weights (`GetRarityChances`):

| Egg | Price | Hatch | Mean income (EV) | Typical (no Mythic/Secret) | Most likely result | Rare+ chance | Pays for itself (EV) |
|---|---:|---:|---:|---:|---|---:|---:|
| Forest | $100 | 0:40 | $26.1/s | $14.1/s | Common | 25.5% | 4 s |
| Swamp | $600 | 1:00 | $38.2/s | $19.1/s | Uncommon | 36.8% | 16 s |
| Mountain | $4K | 1:30 | $60.7/s | $30.7/s | Rare | 54.8% | 66 s |
| Deep Sea | $30K | 2:30 | $99.3/s | $51.3/s | Rare | 73.9% | 5 min |
| Sky | $250K | 4:00 | $183/s | $76.6/s | Epic | 88.9% | 23 min |
| Void | $2.5M | 6:00 | $449/s | $111/s | Legendary | 98.0% | 93 min |

- Cheap eggs pay for themselves in seconds, so the only real limit is
  **nests**. Selling turns nest space into extra rolls. About half the EV of
  a cheap egg is the Mythic/Secret jackpot, so income is lumpy (wide p25..p75)
  and grows fast once a player opens hundreds of eggs.
- **Rebirth cost is the lever that works, but it's weak.** Rebirth 1 for a
  cost of $75K / $150K / $200K / $250K / $300K / $400K lands at 16 / ~26 /
  ~27 / ~30 / 30 / 34 minutes ($150K–$250K are quick scans, see the note
  below). That's why the proposed number is so much bigger than it looks like
  it should be.
- **The playtime gifts are worth a lot.** Their cash scales with income: the
  15-minute gift pays 5 minutes of income (~$100K at that point) and the
  40-minute gift pays 10 minutes. At a $300K rebirth with all extras on,
  rebirth 2 lands at exactly minute 40 for a quarter of players. That's the
  gift paying for it.
  Trimming those two to 2 and 4 minutes of income moves the with-extras
  rebirth 1 from 21 to 25 min (at $300K). Rewards alone: rebirth 1 30 → 20 min
  at $300K. Sightings alone: almost no effect (~1 win per 4 h). Codex alone:
  none.

### Levers that don't matter much (tested, kept as they are)

These are all with the proposed rebirth cost:

| Variant | Rebirth 1 | Rebirth 2 | Rebirth 3 | Note |
|---|---|---|---|---|
| Proposed (hatch 40/60/90/150/240/360) | 33.7 | 76.6 | 139.2 | |
| Hatch times ~1.5× (45/90/150/240/360/480) | 37.1 | 81.7 | 142.0 | eggs lost to theft rise 11% → 16%; first cryptid 1.2 min |
| `Sell.RefundSeconds` 20 | 33.3 | 74.1 | 136.1 | |
| `Sell.RefundSeconds` 180 | 32.5 | 72.1 | 130.1 | |
| No theft, no Hunt (as built) | 14.9 | 33.5 | 56.5 | theft + Hunt cost ~1.5 min on rebirth 1 |

- **Hatch time** is a *theft-tension* dial, not a pacing dial. Leave it where
  it is: longer eggs mostly mean more of them get stolen. Forest's 40 s also
  keeps the tutorial's first hatch at about a minute.
- **Sell refund** barely matters. What a sale is worth is the free nest, not
  the cash. 60 s is fine. It isn't a money printer either. A "churner" who
  sells everything below Epic as soon as a Forest egg is affordable reaches
  rebirth 1 no sooner (34.5 vs 34.5 min), because belt trips are the
  bottleneck. Their late income does run higher ($4K/s vs $2.2K/s at 4 h).
  With a 120 s refund they'd gain ~3 min. *(quick scan)*
- **Egg prices and belt weights** only shift when each tier first becomes
  affordable. They're fine. Deep Sea at ~13 min and Sky at ~1 h are good goals.
  Testing Sky at $150K and Deep Sea at $40K moved the rebirths by less than
  3 minutes, and Sky from ~61 to ~54 min. *(quick scan)*

*Quick scans* (rebirth costs $150K–$250K, the churner, the price scan) ran in
a Python copy of the same model, for fast tuning. It was checked against the
Studio runs (as built: rebirth 1 17.7 vs 16.3 min, rebirth 3 61.8 vs 60.9).
Every other number in this file comes from the Studio runs.

---

## Recommended changes

### Config values for the lead to apply (exact numbers)

```lua
-- Config.Rebirth
BaseCost = 400000,  -- was 75000
CostGrowth = 2.3,   -- was 2.2   (rebirths cost $400K, $920K, $2.12M, $4.87M...)

-- Config.Retention playtimeGifts (the local table above Config.Retention)
{ Minutes = 15, Items = { { Kind = "Cash", Base = 1500, Minutes = 2 } } },  -- Minutes was 5
{ Minutes = 40, Items = { { Kind = "Cash", Base = 5000, Minutes = 4 } } },  -- Minutes was 10
```

Also update DESIGN.md §7 ("Cost: `$400,000 × 2.3^rebirths`") and the
`IncomeBonusPerRebirth` comment if it mentions the old cost.

**Unchanged on purpose:** every `HatchTime`, egg prices, rarity weights and
incomes, upgrade costs and values, `Sell.RefundSeconds` (60),
`Belt.EggWeights`, `Economy.StartingCash` ($500), `Rebirth.StartingCash`
($1,500), luck, `Income.MinVaultSeconds`.

**Alternative if the owner wants faster rebirths:** $300K × 2.4 (same gift
trim) gives rebirth 1 at ~30 min (~25 with extras), rebirth 2 ~65, rebirth 3
~119.

### Outside Config (for the lead/owner to decide; small code/UI changes)

1. **Teach selling properly.** It's the one thing that separates a smooth
   game from a stalled one. Right now Sell is mentioned only in the
   tutorial's last card and in the belt's "No empty nest!" message. Ideas,
   cheapest first:
   - When every nest is full and the player can afford a better egg, show a
     one-time toast plus a pulse on the weakest cryptid's Sell prompt.
   - Add a tutorial step after the 6th cryptid: "Sell your weakest cryptid".
2. **Show rebirth progress on the HUD** (cash / rebirth cost). The longest
   gap in hour 1 (~8 min) is the save-up for the rebirth, and a visible bar
   turns it into a goal.
3. **Cash packs** (`DevProducts.CashSmall/Medium/Large`: $25K / $300K / $5M)
   are flat amounts. Incomes reach $1–2K/s within 2 hours, so the packs stop
   mattering quickly. Consider max(Amount, N minutes of income), like the
   retention rewards. That's a MonetizationService change.
4. **Vault Size is still weak.** `MinVaultSeconds = 600` gives every cryptid
   10 minutes of storage, so the upgrade only matters to AFK players. It's
   the last upgrade most players buy (L4 ~23 min). Not urgent. The old idea
   still stands: make it raise the minutes a vault holds (10 → 15 → 20 → 30 →
   45 → 60) in BoostService.GetVaultCap.
5. **Playtime gifts restart on every join.** A player who rejoins every 15
   minutes collects the 2/5/10/15-minute gifts over and over. The trim above
   limits the damage. If it shows up in analytics, make the clock daily.

---

## Re-running the simulation

Studio must be in **Edit** (not in a play test). Paste the source below into
the command bar or MCP `execute_luau` (Edit datamodel). It only `require`s an
**unparented clone** of Config, so it changes nothing in the place. It
registers `_G.SAC_EconSim(name, overrideFn?, params?)`, which returns a text
report. Then, e.g.:

```lua
print(_G.SAC_EconSim("as built", nil, {}))
print(_G.SAC_EconSim("as built + extras", nil, { rewards = true, sightings = true, codex = true }))
print(_G.SAC_EconSim("proposed", function(C)
	C.Rebirth.BaseCost = 400000; C.Rebirth.CostGrowth = 2.3   -- any Config overrides for this run
	for _, g in ipairs(C.Retention.Playtime.Gifts) do
		for _, it in ipairs(g.Items) do
			if it.Kind == "Cash" and g.Minutes == 15 then it.Minutes = 2 end
			if it.Kind == "Cash" and g.Minutes == 40 then it.Minutes = 4 end
		end
	end
end, { rewards = true, sightings = true, codex = true }))
print(_G.SAC_EconSim("never sells", nil, { sell = false }))
```

Each variant takes ~10 s (200 runs × 4 h at 1 s steps). Keep it to about 3
per call. Studio's Config must match the repo (Rojo pushes it), or put the
repo values in the override function. Every assumption (belt win chance,
theft rates, Hunt catch chance, sell rule...) is a `params` key. See
`DEFAULTS` at the top of the source.

### Source

```lua
-- Steal a Cryptid economy simulation -- auto-hatch design (profile SchemaVersion 2).
-- Read-only: requires an UNPARENTED clone of Config, so nothing is added to the
-- place. Run in the Edit datamodel (MCP execute_luau or the command bar).
-- Registers _G.SAC_EconSim(name, overrideFn?, params?) -> report text.
local Config = require(game:GetService("ReplicatedStorage").Shared.Config:Clone())

local function deepCopy(t)
	if type(t) ~= "table" then return t end
	local c = {}
	for k, v in pairs(t) do c[k] = deepCopy(v) end
	return c
end

local DEFAULTS = {
	runs = 200,
	horizon = 4 * 3600,
	dt = 1,
	collectInterval = 90,    -- collect vaults this often while home
	gotWantedChance = 0.5,   -- chance they win a wanted egg as it rides past
	travelToBelt = 3,        -- HUD Eggs fast travel + settle
	carryDistance = 196,     -- belt arch -> own pad, studs (walked, carrying)
	impatience = 40,         -- seconds at the belt before taking any affordable egg
	saveFraction = 0.5,      -- "saving for rebirth" once cash >= this * cost (and a Rare+ is owned)
	saveEggShare = 0.25,     -- while saving, an egg may cost at most this share of cash
	sell = true,             -- sell the weakest cryptid to make room for a better egg
	sellRatio = 2,           -- ... if the egg's typical income >= this x the cryptid's income
	-- Theft (eggs only). Losses are a per-second risk while an egg incubates,
	-- so slow eggs are more exposed, and announced eggs (Sky/Void) more so.
	theft = true,
	lossPer90s = 0.20,       -- chance an egg is stolen per 90 s in a nest (calibrated: ~11% of eggs lost)
	announceRisk = 1.5,
	spawnLock = 300,         -- Config.Steal.NewPlayerSpawnLock: no losses before this
	stealChance = 0.45,      -- after bringing a bought egg home, chance they also steal one (~as many as they lose)
	raidTime = 50,           -- seconds a steal trip takes
	-- The Hunt (Config.Hunt schedule). Carriers caught in the open lose the egg.
	hunt = true,
	huntWaitChance = 0.5,    -- a carrier who sees a hunt waits at the fire until it ends
	huntCatchChance = 0.3,   -- one who walks through it anyway is caught this often
	-- Extras a real first session has (off by default)
	rewards = false,         -- daily day 1 + the free spin + playtime gifts
	codex = false,           -- page completion luck (hatches only, no photos)
	sightings = false,
	sightingWinChance = 0.2, -- share of sightings this player captures (contested)
	sightingTrip = 60,
	playersOnline = 8,
}
local P = table.clone(DEFAULTS)
local SAMPLES = { 2, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240 }

local function runOnce(C, seed)
	local rng = Random.new(seed)
	local eggOrder = C.EggOrder
	local eggIndex = {}
	for i, id in ipairs(eggOrder) do eggIndex[id] = i end
	local beltTotal = 0
	for _, id in ipairs(eggOrder) do beltTotal += C.Belt.EggWeights[id] or 0 end
	local function rollBelt()
		local r = rng:NextNumber() * beltTotal
		for _, id in ipairs(eggOrder) do
			r -= C.Belt.EggWeights[id] or 0
			if r <= 0 then return id end
		end
		return eggOrder[1]
	end
	local function rollFrom(ch)
		local total = 0
		for _, rar in ipairs(C.RarityOrder) do total += ch[rar] or 0 end
		local r = rng:NextNumber() * total
		for _, rar in ipairs(C.RarityOrder) do
			r -= ch[rar] or 0
			if r < 0 then return rar end
		end
		return "Common"
	end

	-- Hunt windows (warning -> leave) and sightings that avoid them.
	local hunts = {}
	if P.hunt and C.Hunt.Enabled then
		local start = C.Hunt.FirstDelay
		while start < P.horizon do
			local s0 = start + C.Hunt.WarningTime
			table.insert(hunts, { s0, s0 + C.Hunt.Duration + C.Hunt.LeaveTime })
			start += rng:NextNumber(C.Hunt.MinInterval, C.Hunt.MaxInterval)
		end
	end
	local function huntEnd(t0, t1)
		for _, h in ipairs(hunts) do
			if h[1] < t1 and h[2] > t0 then return h[2] end
		end
		return nil
	end
	local sightings = {}
	local sightWeights = {}
	if P.sightings and C.Sightings.Enabled then
		local start = C.Sightings.FirstDelay
		while start < P.horizon do
			local e = huntEnd(start, start + C.Sightings.Duration)
			if e then
				start = e + C.Hunt.BusyRetry
			else
				sightings[math.floor(start)] = true
				start += C.Sightings.Duration + rng:NextNumber(C.Sightings.MinInterval, C.Sightings.MaxInterval)
			end
		end
		-- SightingService.GetWeights for playersOnline
		local base, order = C.Sightings.BaseWeights, {}
		for _, rar in ipairs(C.RarityOrder) do
			if (base[rar] or 0) > 0 then table.insert(order, rar) sightWeights[rar] = base[rar] end
		end
		local frac = math.clamp((math.min(P.playersOnline, C.Sightings.MaxPlayersForScaling) - 1) * C.Sightings.RarerPerPlayer, 0, 1)
		local moved = sightWeights[order[1]] * frac
		sightWeights[order[1]] -= moved
		local rarer = 0
		for i = 2, #order do rarer += base[order[i]] end
		for i = 2, #order do sightWeights[order[i]] += moved * base[order[i]] / rarer end
	end

	-- First-session rewards: daily day 1, the free spin, playtime gifts.
	local rewards = {}
	if P.rewards then
		local R = C.Retention
		if R.Daily.Enabled then table.insert(rewards, { t = 4, items = R.Daily.Rewards[1].Items }) end
		if R.Spin.Enabled then
			local total = 0
			for _, p in ipairs(R.Spin.Prizes) do total += p.Weight or 1 end
			local r = rng:NextNumber() * total
			for _, p in ipairs(R.Spin.Prizes) do
				r -= p.Weight or 1
				if r <= 0 then table.insert(rewards, { t = 10, items = p.Items }) break end
			end
		end
		if R.Playtime.Enabled then
			for _, g in ipairs(R.Playtime.Gifts) do table.insert(rewards, { t = g.Minutes * 60, items = g.Items }) end
		end
	end

	local s = {
		cash = C.Economy.StartingCash, rebirths = 0, upgrades = {}, nests = {}, pending = {},
		phase = "home", timer = 0, carryEgg = nil, beltWait = 0, lastCollect = 0,
		lastTravel = -999, lastRescue = -999, hatches = 0,
		hatchBoostUntil = 0, luckUntil = 0, instant = 0, codex = {}, pages = 0, capture = nil,
	}
	for _, id in ipairs(C.UpgradeOrder) do s.upgrades[id] = 1 end
	local res = { miles = {}, rarSeen = {}, eggAfford = {}, upgrade = {}, rebirth = {}, income = {},
		placed = 0, lost = 0, stolen = 0, caught = 0, sold = 0, captured = 0 }

	local function cap() return math.min(C.GetUpgradeValue("NestSlots", s.upgrades.NestSlots), C.Plot.MaxNests) end
	local function incomeMult() return 1 + s.rebirths * C.Rebirth.IncomeBonusPerRebirth end
	local function luck(t)
		local l = s.rebirths * C.Luck.PerRebirthPercent + s.pages * C.Luck.CodexPageCompletePercent
		if t < s.luckUntil then l += C.Luck.PotionPercent end
		return math.min(l, C.Luck.MaxPercent)
	end
	local function hatchSpeed(t)
		local m = C.GetUpgradeValue("IncubationSpeed", s.upgrades.IncubationSpeed)
		if t < s.hatchBoostUntil then m *= C.DevProducts.HatchBoost.Multiplier end
		return m
	end
	local function creatureIncome(n) return C.Rarities[n.rarity].IncomePerSecond * incomeMult() end
	local function vaultCap(n)
		return math.max(C.GetUpgradeValue("VaultSize", s.upgrades.VaultSize), creatureIncome(n) * C.Income.MinVaultSeconds)
	end
	local function isRarePlus(n) return C.GetRarityIndex(n.rarity) >= C.RebirthMinRarityIndex end
	local function counts()
		local free, eggs, creatures, rarePlus = 0, 0, 0, 0
		for i = 1, cap() do
			local n = s.nests[i]
			if not n then free += 1
			elseif n.kind == "Egg" then eggs += 1
			else
				creatures += 1
				if isRarePlus(n) then rarePlus += 1 end
			end
		end
		return free, eggs, creatures, rarePlus
	end
	local function totalIncome()
		local t = 0
		for i = 1, C.Plot.MaxNests do
			local n = s.nests[i]
			if n and n.kind == "Creature" then t += creatureIncome(n) end
		end
		return t
	end
	local function unlocked(id) return s.rebirths >= C.Eggs[id].RequiredRebirths end
	local function tierFor(budget)
		local best = 0
		for i, id in ipairs(eggOrder) do
			if unlocked(id) and C.Eggs[id].Price <= budget then best = i end
		end
		return best
	end
	-- Best egg tier they'd aim for: spread cash over up to 2 free nests; while
	-- saving for a rebirth, spend only a small share on eggs.
	local function wantedTier(free, saving)
		local budget = s.cash / math.max(1, math.min(free, 2))
		if saving then return tierFor(math.min(budget, s.cash * P.saveEggShare)) end
		local tier = tierFor(budget)
		if tier == 0 then tier = tierFor(s.cash) end
		return tier
	end
	-- What a player "usually" gets from an egg: Common..Legendary (no Mythic/Secret jackpots).
	local function typicalIncome(id, t)
		local ch = C.GetRarityChances(id, luck(t))
		local v = 0
		for _, rar in ipairs({ "Common", "Uncommon", "Rare", "Epic", "Legendary" }) do
			v += (ch[rar] or 0) * C.Rarities[rar].IncomePerSecond
		end
		return v * incomeMult()
	end
	local function mile(t) table.insert(res.miles, t) end
	local function logCodex(id)
		if not P.codex or s.codex[id] then return end
		s.codex[id] = true
		local pages = 0
		for _, rar in ipairs(C.RarityOrder) do
			local all = true
			for _, cr in ipairs(C.CreaturesByRarity[rar]) do
				if not s.codex[cr.Id] then all = false break end
			end
			if all then pages += 1 end
		end
		s.pages = pages
	end
	local function addCreature(i, rar, t)
		local pool = C.CreaturesByRarity[rar]
		logCodex(pool[rng:NextInteger(1, #pool)].Id)
		s.nests[i] = { kind = "Creature", rarity = rar, vault = 0 }
		if not res.rarSeen[rar] then res.rarSeen[rar] = t mile(t) end
	end
	local function hatch(i, t)
		local n = s.nests[i]
		addCreature(i, rollFrom(C.GetRarityChances(n.egg, luck(t))), t)
		s.hatches += 1
	end
	local function freeNest()
		for i = 1, cap() do if not s.nests[i] then return i end end
		return nil
	end
	local function placeEgg(id, incubated)
		local i = freeNest()
		if not i then return nil end
		s.nests[i] = { kind = "Egg", egg = id, inc = incubated or 0 }
		res.placed += 1
		return i
	end
	local function collect(t)
		for i = 1, C.Plot.MaxNests do
			local n = s.nests[i]
			if n and n.kind == "Creature" then s.cash += n.vault n.vault = 0 end
		end
		s.lastCollect = t
	end
	local function grant(items, t)
		for _, it in ipairs(items) do
			if it.Kind == "Cash" then
				s.cash += math.min(C.Retention.MaxCashReward, math.max(it.Base or 0, math.floor((it.Minutes or 0) * 60 * totalIncome())))
			elseif it.Kind == "Egg" then
				local id = it.EggId
				if not unlocked(id) then
					local bestPrice = -1
					for _, e in ipairs(eggOrder) do
						if unlocked(e) and C.Eggs[e].Price > bestPrice then id, bestPrice = e, C.Eggs[e].Price end
					end
				end
				for _ = 1, it.Count or 1 do table.insert(s.pending, id) end
			elseif it.Kind == "Buff" then
				local key = if it.Buff == "Luck" then "luckUntil" else "hatchBoostUntil"
				s[key] = math.max(s[key], t) + (it.Duration or 0)
			elseif it.Kind == "InstantHatch" then
				s.instant += it.Count or 1
			end
		end
	end
	-- Upgrades: cheapest first, keeping enough for a Forest egg per free nest.
	local function reserve() return (counts()) * C.Eggs[eggOrder[1]].Price end
	local function nextUpgrade()
		local bestId, bestCost = nil, math.huge
		for _, id in ipairs(C.UpgradeOrder) do
			local cost = C.GetUpgradeNextCost(id, s.upgrades[id])
			if cost and cost < bestCost then bestId, bestCost = id, cost end
		end
		return bestId, bestCost
	end
	local function buyUpgrades(t, saving)
		if saving then return end
		while true do
			local id, cost = nextUpgrade()
			if not id or s.cash < cost + reserve() then return end
			s.cash -= cost
			s.upgrades[id] += 1
			local key = id .. " L" .. s.upgrades[id] .. " (R" .. s.rebirths .. ")"
			if not res.upgrade[key] then res.upgrade[key] = t end
			if not res.firstUpgrade then res.firstUpgrade = t end
			mile(t)
		end
	end
	-- Sell the weakest cryptid (never the last Rare+). Returns true if sold.
	local function trySell(t, saving, rarePlus, need)
		local worstI, worstInc = nil, math.huge
		for i = 1, cap() do
			local n = s.nests[i]
			if n and n.kind == "Creature" and not (rarePlus <= 1 and isRarePlus(n)) and creatureIncome(n) < worstInc then
				worstI, worstInc = i, creatureIncome(n)
			end
		end
		if not worstI then return false end
		if need then
			if not need(s.nests[worstI]) then return false end
		else
			local value = s.nests[worstI].vault + worstInc * C.Sell.RefundSeconds
			s.cash += value
			local tier = wantedTier(1, saving)
			s.cash -= value
			if tier == 0 or typicalIncome(eggOrder[tier], t) < P.sellRatio * worstInc then return false end
		end
		s.cash += s.nests[worstI].vault + worstInc * C.Sell.RefundSeconds
		s.nests[worstI] = nil
		res.sold += 1
		if not res.firstSell then res.firstSell = t end
		return true
	end

	local hazard = -math.log(1 - P.lossPer90s) / 90
	local nextSample, nextReward = 1, 1
	table.sort(rewards, function(a, b) return a.t < b.t end)
	local t = 0
	while t < P.horizon do
		t += P.dt
		-- Nests: eggs count up and hatch by themselves; creatures fill vaults.
		local speed = hatchSpeed(t)
		for i = 1, C.Plot.MaxNests do
			local n = s.nests[i]
			if n then
				if n.kind == "Egg" then
					local egg = C.Eggs[n.egg]
					n.inc = math.min(egg.HatchTime, n.inc + speed * P.dt)
					if n.inc >= egg.HatchTime then
						hatch(i, t)
					elseif P.theft and t > P.spawnLock
						and rng:NextNumber() < hazard * P.dt * (if egg.AnnounceInNest then P.announceRisk else 1) then
						s.nests[i] = nil
						res.lost += 1
					end
				else
					n.vault = math.min(vaultCap(n), n.vault + creatureIncome(n) * P.dt)
				end
			end
		end
		-- Rewards, saved eggs, Instant Hatch.
		while rewards[nextReward] and t >= rewards[nextReward].t do
			grant(rewards[nextReward].items, t)
			nextReward += 1
		end
		while #s.pending > 0 and freeNest() do placeEgg(table.remove(s.pending, 1), 0) end
		if s.instant > 0 then
			local bestI, bestTier = nil, 0
			for i = 1, cap() do
				local n = s.nests[i]
				if n and n.kind == "Egg" and eggIndex[n.egg] > bestTier then bestI, bestTier = i, eggIndex[n.egg] end
			end
			if bestI then hatch(bestI, t) s.instant -= 1 end
		end
		-- Milestones
		for _, id in ipairs(eggOrder) do
			if not res.eggAfford[id] and unlocked(id) and s.cash >= C.Eggs[id].Price then
				res.eggAfford[id] = t
				mile(t)
			end
		end
		local free, eggs, creatures, rarePlus = counts()
		if creatures >= 1 and not res.firstCreature then res.firstCreature = t end
		if creatures >= 6 and not res.six then res.six = t end
		if rarePlus > 0 and not res.firstRare then res.firstRare = t end
		-- Rebirth as soon as affordable with a Rare+ (not mid-carry).
		local cost = C.GetRebirthCost(s.rebirths)
		local busy = s.phase == "carrying" or s.phase == "raid" or s.phase == "trip"
		if rarePlus > 0 and s.cash >= cost and not busy then
			s.rebirths += 1
			res.rebirth[s.rebirths] = t
			mile(t)
			s.cash = C.Rebirth.StartingCash or 0
			s.nests = {}
			for _, id in ipairs(C.UpgradeOrder) do s.upgrades[id] = 1 end
			s.phase = "home"
			free, eggs, creatures, rarePlus = counts()
		end
		local saving = rarePlus > 0 and s.cash >= P.saveFraction * C.GetRebirthCost(s.rebirths)
		-- Rescue egg (NestService): nothing at all and too poor for a Forest egg.
		if C.Economy.RescueEnabled and eggs == 0 and creatures == 0 and #s.pending == 0 and s.phase ~= "carrying"
			and s.cash < C.Eggs[eggOrder[1]].Price and t - s.lastRescue >= C.Economy.RescueCooldown then
			placeEgg(C.Economy.RescueEggId, 0)
			s.lastRescue = t
			free, eggs, creatures, rarePlus = counts()
		end
		-- A sighting: some players go for it; a capture is a free Rare+.
		if sightings[t] and (s.phase == "home" or s.phase == "atBelt") and rng:NextNumber() < P.sightingWinChance then
			local ok = free > 0
			if not ok and P.sell then
				ok = trySell(t, saving, rarePlus, function(n) return not isRarePlus(n) end)
			end
			if ok then
				s.capture = rollFrom(sightWeights)
				s.phase = "trip"; s.timer = P.sightingTrip
			end
		end

		if s.phase == "home" then
			if t - s.lastCollect >= P.collectInterval then collect(t) end
			if P.sell and C.Sell.Enabled and free == 0 and #s.pending == 0 then
				if trySell(t, saving, rarePlus) then free = 1 end
			end
			local tier = wantedTier(free, saving)
			local wantsUpgrade = false
			if not saving then
				local id, c = nextUpgrade()
				wantsUpgrade = id ~= nil and s.cash >= c + reserve()
			end
			if ((free > #s.pending and tier > 0) or wantsUpgrade) and t - s.lastTravel >= C.Travel.Cooldown then
				collect(t)
				s.phase = "toBelt"; s.timer = P.travelToBelt; s.lastTravel = t
			end
		elseif s.phase == "toBelt" then
			s.timer -= P.dt
			if s.timer <= 0 then s.phase = "atBelt"; s.beltWait = 0; buyUpgrades(t, saving) end
		elseif s.phase == "atBelt" then
			s.beltWait += P.dt
			if (t % C.Belt.SpawnInterval) == 0 and free > 0 then
				local id = rollBelt()
				local tier = wantedTier(free, saving)
				local ok = unlocked(id) and C.Eggs[id].Price <= s.cash and tier > 0
					and (eggIndex[id] >= tier - 1 or s.beltWait >= P.impatience)
					and (not saving or C.Eggs[id].Price <= s.cash * P.saveEggShare)
				if ok and rng:NextNumber() < P.gotWantedChance then
					s.cash -= C.Eggs[id].Price
					s.carryEgg = id
					local walk = C.GetUpgradeValue("WalkSpeed", s.upgrades.WalkSpeed) * C.Belt.CarrySpeedMultiplier
					local carryTime = P.carryDistance / walk + 2
					s.phase = "carrying"; s.timer = carryTime
					local e = huntEnd(t, t + carryTime)
					if e then
						if rng:NextNumber() < P.huntWaitChance then
							s.timer = (e - t) + carryTime -- wait it out by the fire
						elseif rng:NextNumber() < P.huntCatchChance then
							s.carryEgg = nil -- caught: belt egg gone, stunned
							res.caught += 1
							s.timer = carryTime * 0.5 + C.Hunt.StunDuration
						end
					end
				end
			end
			if s.phase == "atBelt" and (free == 0 or wantedTier(free, saving) == 0) then
				s.phase = "walkHome"; s.timer = P.travelToBelt + 5
			end
		elseif s.phase == "carrying" then
			s.timer -= P.dt
			if s.timer <= 0 then
				s.phase = "home"
				if s.carryEgg then
					placeEgg(s.carryEgg, 0)
					s.carryEgg = nil
					-- Sometimes they go and steal one too (eggs only).
					if P.theft and rng:NextNumber() < P.stealChance and freeNest() and not huntEnd(t, t + P.raidTime) then
						s.phase = "raid"; s.timer = P.raidTime
					end
				end
			end
		elseif s.phase == "raid" then
			s.timer -= P.dt
			if s.timer <= 0 then
				s.phase = "home"
				local maxTier = tierFor(math.huge)
				local tier = math.clamp(math.max(1, wantedTier(1, false)) + rng:NextInteger(-1, 1), 1, maxTier)
				local id = eggOrder[tier]
				if placeEgg(id, rng:NextNumber() * 0.8 * C.Eggs[id].HatchTime) then res.stolen += 1 end
			end
		elseif s.phase == "trip" then
			s.timer -= P.dt
			if s.timer <= 0 then
				s.phase = "home"
				local i = freeNest()
				if i and s.capture then
					addCreature(i, s.capture, t)
					res.captured += 1
				end
				s.capture = nil
			end
		elseif s.phase == "walkHome" then
			s.timer -= P.dt
			if s.timer <= 0 then s.phase = "home" end
		end
		while SAMPLES[nextSample] and t >= SAMPLES[nextSample] * 60 do
			res.income[SAMPLES[nextSample]] = totalIncome()
			nextSample += 1
		end
	end
	return res
end

local function pct(list, q)
	if #list == 0 then return nil end
	table.sort(list)
	return list[math.max(1, math.floor(q * #list + 0.5))]
end
local function fmtT(sec)
	if not sec then return "never" end
	return string.format("%.1f", sec / 60)
end

local function runVariant(name, overrideFn, params)
	P = table.clone(DEFAULTS)
	for k, v in pairs(params or {}) do P[k] = v end
	local backup = {}
	for k, v in pairs(Config) do
		if type(v) == "table" then backup[k] = v; Config[k] = deepCopy(v) end
	end
	local all = {}
	local ok, err = pcall(function()
		if overrideFn then overrideFn(Config) end
		for r = 1, P.runs do table.insert(all, runOnce(Config, r)) end
	end)
	for k, v in pairs(backup) do Config[k] = v end
	if not ok then return "ERROR " .. tostring(err) end

	local lines = { "== " .. name .. " (" .. #all .. " runs; minutes, median [p25..p75]) ==" }
	local function stat(label, get)
		local xs, never = {}, 0
		for _, r in ipairs(all) do
			local v = get(r)
			if v then table.insert(xs, v) else never += 1 end
		end
		table.insert(lines, string.format("%-26s %s [%s..%s]%s", label, fmtT(pct(xs, 0.5)), fmtT(pct(xs, 0.25)), fmtT(pct(xs, 0.75)),
			if never > 0 then string.format(" never %d%%", math.floor(never / #all * 100 + 0.5)) else ""))
	end
	stat("first creature", function(r) return r.firstCreature end)
	stat("first upgrade", function(r) return r.firstUpgrade end)
	stat("first Rare+", function(r) return r.firstRare end)
	stat("6 creatures", function(r) return r.six end)
	stat("first sell", function(r) return r.firstSell end)
	for _, id in ipairs(Config.EggOrder) do stat("afford " .. id, function(r) return r.eggAfford[id] end) end
	local keys = {}
	for _, r in ipairs(all) do
		for k in pairs(r.upgrade) do if k:find("%(R0%)") then keys[k] = true end end
	end
	local sorted = {}
	for k in pairs(keys) do table.insert(sorted, k) end
	table.sort(sorted)
	for _, k in ipairs(sorted) do stat((k:gsub(" %(R0%)", "")), function(r) return r.upgrade[k] end) end
	for n = 1, 4 do stat("rebirth " .. n, function(r) return r.rebirth[n] end) end
	-- Longest wait between milestones in hour 1, and over the 4 h.
	local gaps, stalled = {}, 0
	for _, r in ipairs(all) do
		table.sort(r.miles)
		local last, worst, last4, worst4 = 0, 0, 0, 0
		for _, m in ipairs(r.miles) do
			if m <= 3600 then worst = math.max(worst, m - last) last = m end
			worst4 = math.max(worst4, m - last4)
			last4 = m
		end
		worst = math.max(worst, 3600 - last)
		worst4 = math.max(worst4, P.horizon - last4)
		table.insert(gaps, worst)
		if worst4 >= 3600 then stalled += 1 end
	end
	table.insert(lines, string.format("%-26s %s [%s..%s]", "longest goal gap, hour 1", fmtT(pct(gaps, 0.5)), fmtT(pct(gaps, 0.25)), fmtT(pct(gaps, 0.75))))
	table.insert(lines, string.format("stalled (60+ min with no new goal in 4 h): %d%%", math.floor(stalled / #all * 100 + 0.5)))
	local inc = {}
	for _, m in ipairs(SAMPLES) do
		local xs = {}
		for _, r in ipairs(all) do if r.income[m] then table.insert(xs, r.income[m]) end end
		table.insert(inc, string.format("%d:%s", m, Config.FormatNumber(pct(xs, 0.5) or 0)))
	end
	table.insert(lines, "income/s: " .. table.concat(inc, " "))
	local placed, lost, stolen, caught, sold, cap = 0, 0, 0, 0, 0, 0
	for _, r in ipairs(all) do
		placed += r.placed; lost += r.lost; stolen += r.stolen; caught += r.caught; sold += r.sold; cap += r.captured
	end
	table.insert(lines, string.format("per run: eggs placed %.0f, stolen from you %.0f (%.0f%%), you stole %.0f, hunt-caught %.1f, sold %.0f, sightings won %.1f",
		placed / #all, lost / #all, lost / math.max(1, placed) * 100, stolen / #all, caught / #all, sold / #all, cap / #all))
	return table.concat(lines, "\n")
end

_G.SAC_EconSim = runVariant
return "registered"
```
