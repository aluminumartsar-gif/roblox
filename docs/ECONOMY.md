# ECONOMY.md — progression check (Step 8)

*Written for the owner and the lead. Plain-English summary first, then the
numbers, then exactly what to change.*

## The short version

The current numbers give a great **first 30 seconds** (the tutorial gets a
cryptid hatched almost straight away) and a reasonable **first rebirth
(~28 min)**. Everything around those two moments has problems:

1. **Players get stuck with full nests.** There is no way to remove a
   cryptid. After about 13 minutes all 6 nests hold creatures and the only
   ways forward are a $5,000 nest upgrade or rebirth. Income then sits flat
   at about $20–30/s for the whole first hour, and **9% of players never
   hatch a Rare** (needed to rebirth) in 4 hours of play — they are stuck
   for good.
2. **The first upgrade comes at ~11 minutes** (good games: under 3), and in
   the first hour a player goes **~17 minutes without a single new goal**.
3. **Rebirth wipes you to $0 and empty nests.** Income crashes and takes a
   long time to come back, so rebirths 2 and 3 are slow (85 and 155 min) and
   a third of players never reach rebirth 3 in 4 hours.
4. **The egg ladder is too steep.** Each egg costs 10x the last but is only
   ~1.5–2x better, so Deep Sea arrives at ~85 min and Sky (1M) basically
   never in a 4-hour session.

The fix is two small features (the lead/owner must OK them) plus cheaper
numbers:

- **Release a cryptid** (new): hold a prompt on your own cryptid to let it go
  back to the woods, freeing its nest, for its vault plus 60 seconds of its
  income. This is the single biggest improvement.
- **Rebirth starting cash** (new): after a rebirth you start with $1,500,
  not $0.
- **Cheaper early upgrades**, a **flatter egg price ladder**, rebirth base
  cost **$75K**, and starting cash **$500** (already changed — it's in my
  Config section).

With all of that, a typical player gets: first cryptid 30 s, first upgrade
~4 min (25% of players under 2 min), 6 cryptids ~7 min, first Rare ~4 min,
Mountain eggs ~8 min, Deep Sea ~25 min, **rebirth 1 at ~34 min**, rebirth 2
~79 min, rebirth 3 ~129 min, and income keeps climbing (~$90/s at 1 h,
~$630/s at 4 h) instead of flat-lining.

---

## How the simulation works

A deterministic Monte-Carlo model (200 players with fixed random seeds, so
every run gives the same answer) of one typical player over 4 hours of play,
using the real Config tables and the real `Config.GetRarityChances` for
every hatch. It ran in Studio's Edit datamodel against an **unparented clone
of Config** (nothing was added to the place). The economy tables in Studio's
copy were checked value-by-value against the repo before running
(prices, weights, incomes, upgrades, rebirth, belt, heat, luck — identical;
only `Config.Economy` was missing from Studio's older copy, so the sim
supplied the repo's starting cash).

What the simulated player does:

- **Belt:** one egg every `Config.Belt.SpawnInterval` (2 s), picked by
  `Config.Belt.EggWeights`. They wait for the best tier they can afford
  (spreading cash over up to 2 free nests), accept one tier lower, and take
  anything affordable after 40 s. **They win a wanted egg 50% of the time**
  (other players, missed taps).
- **Travel:** HUD Eggs fast travel (3 s, respecting the 8 s cooldown) to the
  belt; carrying home is walked: 196 studs from the arch to the pad at
  walk speed × `Belt.CarrySpeedMultiplier`.
- **Heat:** the first egg is hatched immediately (the tutorial says so). The
  "realistic" player then hatches the next 5 at 25% heat (impatient new
  player) and everything after at **70%**. Variants at 25% / 70% / 100%
  below.
- **Income & vaults:** income by rarity × (1 + 0.25 × rebirths); vault cap =
  max(Vault Size, 10 min of income). They collect every 90 s while home.
- **Upgrades:** cheapest available first, as soon as they can afford it and
  still keep $100 per empty nest for eggs; they stop buying upgrades once
  they own a Rare+ and have half the rebirth cost saved.
- **Rebirth:** as soon as they can afford it and own a Rare+ creature.
  Resets cash, nests and upgrades, exactly like `Config.Rebirth.Resets`.
- **Rescue egg:** modelled as built (free Forest egg when you have nothing).
- **Not modelled:** stealing (assumed to balance out), Robux, sightings,
  codex luck, daily/spin/gift/offline rewards (these only speed things up).

The full source is at the end of this file; re-run it any time the economy
numbers change.

---

## Results as built

Times are minutes of play: median [25th..75th percentile]. "never in X%" =
that share of players didn't get there in 4 hours.

| Milestone | As built (hatch at 70%) | As built, realistic (first 6 at 25%) |
|---|---|---|
| First cryptid | 0.5 | 0.5 |
| First upgrade (any) | 11.5 [9.9..13.2] | 8.3 [6.5..10.9] |
| First Rare+ | 8.2 (never in 9%) | 4.0 (never in 12%) |
| 6 cryptids at once | 12.8 | 7.1 |
| Can afford Swamp ($1K) | 8.3 | 5.6 |
| Can afford Mountain ($10K) | 14.4 | 13.5 |
| Can afford Deep Sea ($100K) | 84.8 (never in 12%) | 83.8 (never in 15%) |
| Can afford Sky ($1M, R1+) | never in 94% | never in 94% |
| Can afford Void ($25M, R3+) | never | never |
| Nest Slots L2 ($5K) | 11.4 | 8.2 |
| Nest Slots L3 ($25K) | never in 88% | never in 80% |
| Incubation L2 ($7.5K) | 14.2 | 11.3 |
| Vault Size L2 ($10K) | 16.6 | 16.1 |
| Walk Speed L2 ($12K) | 20.6 | 21.2 |
| Lock Duration L2 ($15K) | 25.3 | 27.2 |
| **Rebirth 1** ($50K) | **27.8** [16.2..45.8] (never in 9%) | 29.4 (never in 12%) |
| Rebirth 2 ($110K) | 85.3 (never in 14%) | 86.8 (never in 15%) |
| Rebirth 3 ($242K) | 154.7 (never in 36%) | 159.6 (never in 36%) |
| Longest stretch with no new goal, hour 1 | **17.4** | 17.9 |

Income per second (median player):

| | 2m | 5m | 10m | 15m | 20m | 30m | 45m | 60m | 90m | 120m | 180m | 240m |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| As built | $1 | $1 | $29 | $35 | $27 | $21 | $27 | $30 | $47 | $48 | $54 | $67 |
| As built, realistic | $1 | $14 | $29 | $29 | $30 | $18 | $26 | $24 | $34 | $48 | $64 | $73 |

The dip after ~25 min is rebirth 1 wiping everything; the flat line after
that is full nests with no way to replace weak cryptids.

### Compared with good Roblox simulator pacing

| Target | As built | Verdict |
|---|---|---|
| First meaningful upgrade < 3 min | 8–12 min | **Too slow** |
| A fresh goal every few minutes | up to 17 min with nothing new | **Too slow** |
| First rebirth ~30–60 min | ~28 min median, but 9–12% never | Timing fine, the "never" is a bug-level problem |
| Rebirth should feel like a power-up | income drops for 20+ min after | **Feels like a punishment** |
| Long-term goals stay reachable | Deep Sea 85 min, Sky/Void never | **Ladder too steep** |

---

## What's wrong, in order of importance

### 1. No way to free a nest (needs a small feature)
DESIGN.md says "every creature you keep is an egg you can't cook", but the
game has no way *not* to keep one. Once 6 nests hold Commons you can only
wait for $5K (nest 7), and nests 8+ cost $25K–$15M. 9% of players never see a
Rare in 4 hours, and without a Rare they can never rebirth. Getting robbed
is currently the only way to free a nest.

**Proposal — Release:** a "Release" ProximityPrompt (owner only, ~1 s hold,
`Config.Prompts`) on your own cryptids. It pays the cryptid's vault plus
**60 seconds of its income** and empties the nest (`NestService.SetSlot(…,
false)`). Simulated effect: income at 4 h goes from $67/s to $446/s, rebirth 3
from 155 to 114 min, and nobody is stuck without a Rare (0% "never").
Suggested Config:

```lua
Config.Release = {
	Enabled = true,
	RefundSeconds = 60,   -- pays vault + this many seconds of the cryptid's income
}
-- and in Config.Prompts:
ReleaseHold = 1,
```

Keep the refund small: with Release, hatching eggs quickly (high
throughput) earns more than waiting for heat (see "Heat" below), and a big
refund would make churning even stronger.

### 2. Rebirth leaves you with nothing (needs a one-line change)
After a rebirth you have $0, no nests and no upgrades; the only way back is
the 3-minute rescue egg. Rebirth 2 and 3 therefore take far longer than the
cost growth suggests.

**Proposal:** `Config.Rebirth.StartingCash = 1500` and in RebirthService,
after the reset, set Cash to that (not via AddCash, so it doesn't count as
earned). With it: rebirth 2 at 79 min instead of 86, rebirth 3 at 129 instead
of 148, and the income dip after rebirth 1 recovers in ~10 min instead of
~25. (Simulated with Release on; "$0 after rebirth" variant below.)

### 3. Upgrades start too expensive
The cheapest upgrade is $5,000 while a new player earns $1–30/s, so the
first one lands at 8–12 minutes. Proposed ladders start at $200–$1,500 and
grow ~5–7x per level, so there's something to buy every few minutes for the
first half hour.

### 4. Egg prices go up 10x per tier but value only ~1.5–2x
Expected income per hatch (luck 0), measured with `Config.GetRarityChances`:

| Egg | Price now | EV heat 0 | EV heat 70 | EV heat 100 | Usual result (median) at 70% |
|---|---:|---:|---:|---:|---|
| Forest | $100 | $15.1/s | $38.4/s | $46.3/s | Uncommon |
| Swamp | $1K | $19.8/s | $45.9/s | $54.0/s | Uncommon |
| Mountain | $10K | $34.7/s | $73.0/s | $82.9/s | Rare |
| Deep Sea | $100K | $63.1/s | $116.1/s | $127.2/s | Rare |
| Sky | $1M | $124.8/s | $200.7/s | $213.4/s | Epic |
| Void | $25M | $343.0/s | $479.3/s | $496.6/s | Legendary |

Notes: EV is dominated by the rare tail (most of a Forest egg's $15/s is
Legendary+), so most hatches earn far less than EV. **Swamp is barely better
than Forest** at 10x the price. Proposed prices flatten the ladder (~5–8x per
tier) so each tier arrives on a sensible schedule.

### 5. Vault Size does almost nothing
`Config.Income.MinVaultSeconds = 600` already lets every cryptid hold 10
minutes of its own income, and an active player collects every 1–2 minutes,
so the Vault Size upgrade only matters to players who go AFK for 10+
minutes. Not urgent — the cheaper prices below at least make it a cheap early
goal. Optional later idea: make Vault Size raise the *minutes* a vault holds
(10 → 15 → 20 → 30 → 45 → 60) instead of a flat cash amount (code change in
BoostService.GetVaultCap).

### 6. Heat is a lottery dial, not an income dial
With Release in the game, impatient hatching (25%) out-earns patient
hatching (100%): at 60 min $146/s vs $63/s, rebirth 1 at 30 vs 39 min. Heat
still triples a Forest egg's EV (15 → 46) and is the way to hunt
Legendaries, Mythics and the Secret, which is a fine role for it. Making heat
much stronger (Rare x3 … Secret x12) did **not** change this (throughput still
wins) and sped the whole economy up ~40%, so I don't recommend it. If the
owner wants patience to pay in cash too, the lever is the Release refund
(keep it small) or a future "heat also raises mutation chance" (mutations are
already in Config, switched off).

---

## Recommended changes

### Already changed (my section)
| Key | Was | Now | Why |
|---|---:|---:|---|
| `Config.Economy.StartingCash` | 300 | **500** | Five Forest eggs during the tutorial; more of the first nests fill straight away. Only affects brand-new profiles. |

### Config values for the lead to apply (exact numbers)

**Egg prices** (`Config.Eggs.<id>.Price`; weights, unlocks and belt chances
unchanged):

| Egg | Now | Proposed |
|---|---:|---:|
| forest | 100 | 100 |
| swamp | 1,000 | **600** |
| mountain | 10,000 | **4,000** |
| deepsea | 100,000 | **30,000** |
| sky | 1,000,000 | **250,000** |
| void | 25,000,000 | **2,500,000** |

**Upgrade costs** (`Config.Upgrades.<id>.Levels[n].Cost`; every `Value`
unchanged; level 1 stays 0):

| Upgrade | L2 | L3 | L4 | L5 | L6 | L7 |
|---|---:|---:|---:|---:|---:|---:|
| NestSlots now | 5,000 | 25,000 | 120,000 | 600,000 | 3,000,000 | 15,000,000 |
| NestSlots **proposed** | **1,000** | **6,000** | **30,000** | **150,000** | **750,000** | **4,000,000** |
| IncubationSpeed now | 7,500 | 40,000 | 200,000 | 1,000,000 | 6,000,000 | — |
| IncubationSpeed **proposed** | **200** | **3,000** | **20,000** | **120,000** | **750,000** | — |
| VaultSize now | 10,000 | 60,000 | 350,000 | 2,000,000 | 12,000,000 | — |
| VaultSize **proposed** | **2,500** | **15,000** | **100,000** | **600,000** | **4,000,000** | — |
| LockDuration now | 15,000 | 80,000 | 450,000 | 2,500,000 | — | — |
| LockDuration **proposed** | **1,500** | **10,000** | **60,000** | **400,000** | — | — |
| WalkSpeed now | 12,000 | 65,000 | 380,000 | 2,200,000 | — | — |
| WalkSpeed **proposed** | **500** | **5,000** | **40,000** | **300,000** | — | — |

**Rebirth:** `Config.Rebirth.BaseCost` 50,000 → **75,000** (CostGrowth 2.2
unchanged: rebirths cost $75K, $165K, $363K…). With everything else cheaper,
$50K came at ~28 min; $75K lands rebirth 1 at ~34 min, inside the 30–60 min
target.

**Unchanged on purpose:** rarity incomes, egg weights, belt weights, heat
multipliers, heat time (10 min), luck, vault minimum.

**Robux cash packs:** with cheaper eggs the packs buy more (Pocket Change
$25K was 2.5 Mountain eggs, it'd be 6). That's generous rather than broken;
if the owner wants the same value as before, scale them to roughly
**$10K / $120K / $2M** (`Config.DevProducts.CashSmall/CashMedium/CashLarge.Amount`
and their Description text).

### Features for the lead/owner to OK (small code changes)
1. **Release a cryptid** — see problem 1. NestService (prompt + handler with
   the usual owner/distance/hold checks, `SetSlot(player, i, false)`, pay
   via `DataService.AddCash(player, vault + income * RefundSeconds,
   "release")`), plus a client confirm if desired. Refuse while the
   cryptid is Away (being stolen).
2. **Rebirth starting cash** — see problem 2. RebirthService: after the
   reset, `DataService.Mutate(player, function(d) d.Cash =
   Config.Rebirth.StartingCash end)`.

Both are needed for the "proposed" numbers below; without Release the price
changes alone still help the first 30 minutes but the mid-game stays flat
(see "P4 without Release").

---

## Results with the proposals

"P4" = all proposed Config values + Release (60 s refund) + $1,500 after
rebirth, realistic player. Columns to the right switch one thing off.

| Milestone | **P4 (proposed)** | P4 without Release | P4, $0 after rebirth |
|---|---|---|---|
| First cryptid | 0.5 | 0.5 | 0.5 |
| First upgrade (any) | **4.3** [1.9..4.8] | 4.3 | 4.3 |
| First Rare+ | 4.0 | 3.9 (never in 5%) | 4.0 |
| 6 cryptids at once | 7.0 | 5.7 | 7.0 |
| Can afford Swamp | 4.7 | 4.8 | 4.7 |
| Can afford Mountain | 7.5 | 7.0 | 7.5 |
| Can afford Deep Sea | 25.1 | 27.5 | 25.1 |
| Can afford Sky (R1+) | 125 | 162 (never in 34%) | 145 |
| Can afford Void (R3+) | 198 (never in 97%) | never | 211 (never in 99%) |
| Incubation L2 / L3 / L4 | 4.3 / 8.2 / 21.8 | 4.3 / 8.2 / 23.9 | same as P4 |
| Walk Speed L2 / L3 | 4.7 / 9.8 | 4.7 / 9.8 | same |
| Nest Slots L2 / L3 / L4 | 5.2 / 12.1 / 27.2 | 5.5 / 12.5 / 35.2 | same |
| Lock Duration L2 / L3 | 6.1 / 14.6 | 6.3 / 15.3 | same |
| Vault Size L2 / L3 | 7.1 / 17.8 | 7.2 / 18.5 | same |
| **Rebirth 1** | **33.8** [24.8..46.2] | 39.5 (never in 5%) | 33.8 |
| Rebirth 2 | 78.8 | 98.1 (never in 10%) | 85.5 |
| Rebirth 3 | 129.4 | 167.1 (never in 37%) | 148.3 |
| Longest stretch with no new goal, hour 1 | **9.1** | 12.0 | 11.7 |

Income per second (median):

| | 2m | 5m | 10m | 15m | 20m | 30m | 45m | 60m | 90m | 120m | 180m | 240m |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **P4** | $1 | $33 | $36 | $57 | $68 | $82 | $76 | $93 | $125 | $214 | $314 | $630 |
| P4 without Release | $1 | $33 | $37 | $41 | $42 | $50 | $34 | $46 | $43 | $92 | $117 | $159 |
| P4, $0 after rebirth | $1 | $33 | $36 | $54 | $52 | $58 | $27 | $55 | $91 | $139 | $294 | $330 |

Heat strategy with the P4 numbers (same player, different hatch heat):

| Hatch at | Rebirth 1 | Rebirth 2 | Rebirth 3 | Income 60 min | Income 240 min |
|---|---|---|---|---|---|
| 25% | 29.8 | 66.2 | 114.1 | $146 | $1.03K |
| 70% | 33.8 | 78.8 | 129.4 | $93 | $630 |
| 100% | 38.5 | 85.0 | 139.6 | $63 | $376 |

(The last table's 25%/100% rows were run on "P3", identical to P4 except
Incubation L2 at $250 instead of $200 — a difference that only moves the
first upgrade.)

### Remaining gaps
- **First upgrade ~4 min** (target < 3). The first few minutes are the
  tutorial plus eggs heating; a quarter of players buy Incubation L2 before
  2 min. Good enough; the tutorial's last card points at the Upgrades cabin.
- **The first ~4 minutes earn ~$1/s** (one cryptid while the rest heat up).
  That's the heat hook doing its job; the tutorial fills this time.
- **Void** remains a long-term goal (needs rebirth 3 + $2.5M): ~3.3 h.
  That's appropriate for the top egg.

---

## Re-running the simulation

Paste the source below into Studio's command bar (or MCP `execute_luau`,
Edit datamodel). It only `require`s an **unparented clone** of Config, so it
changes nothing in the place. It registers `_G.SAC_EconSim`; then run, e.g.:

```lua
print(_G.SAC_EconSim("as built", nil, {}))
print(_G.SAC_EconSim("realistic", nil, { earlyHatches = 6, earlyThreshold = 25 }))
print(_G.SAC_EconSim("with release", function(C)
	C.Rebirth.BaseCost = 75000 -- any Config overrides for this run
end, { earlyHatches = 6, earlyThreshold = 25, release = true, sellSeconds = 60, rebirthCashAfter = 1500 }))
```

Keep each command bar call to about 3 variants (200 runs ≈ 8 s each).
Note Studio's Edit copy of Config must match the repo (push first) — or
apply the repo values in the override function as above.

### Source

```lua
-- Steal a Cryptid economy simulation. Read-only: requires an UNPARENTED clone
-- of Config, so nothing is added to the place. Run in the Edit datamodel.
-- Registers _G.SAC_EconSim(name, overrideFn?, params?) -> report text.
local Config = require(game:GetService("ReplicatedStorage").Shared.Config:Clone())
Config.Economy = Config.Economy or {}
Config.Economy.StartingCash = Config.Economy.StartingCash or 300

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
	heatThreshold = 70,   -- hatch at this heat (players: 60..100)
	earlyThreshold = 70,  -- heat used for the first `earlyHatches` hatches before rebirth 1
	earlyHatches = 0,
	firstHatchNow = true, -- the tutorial has them hatch the first egg right away
	collectInterval = 90,
	gotWantedChance = 0.5, -- chance they win a wanted egg as it rides past
	travelToBelt = 3,      -- HUD Eggs fast travel + settle
	carryDistance = 196,   -- arch -> own pad, studs (walked, carrying)
	release = false,       -- can free a nest by releasing the worst creature
	sellSeconds = 0,       -- a release pays this many seconds of the creature's income
	rebirthCashAfter = 0,  -- cash right after a rebirth
	saveFraction = 0.5,    -- stop buying upgrades once cash >= this * rebirth cost (and a Rare+ is owned)
	impatience = 40,       -- seconds at the belt before taking any affordable egg
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
	local function rollRarity(eggId, heat, luck)
		local ch = C.GetRarityChances(eggId, heat, luck)
		local r = rng:NextNumber()
		for _, rar in ipairs(C.RarityOrder) do
			r -= ch[rar]
			if r <= 0 then return rar end
		end
		return "Common"
	end

	local s = {
		cash = C.Economy.StartingCash, rebirths = 0, upgrades = {}, nests = {},
		phase = "home", timer = 0, carryEgg = nil, beltWait = 0, lastCollect = 0,
		lastTravel = -999, lastRescue = -999, hatches = 0,
	}
	for _, id in ipairs(C.UpgradeOrder) do s.upgrades[id] = 1 end
	local res = { miles = {}, rarSeen = {}, eggAfford = {}, upgrade = {}, rebirth = {}, income = {} }

	local function cap() return C.GetUpgradeValue("NestSlots", s.upgrades.NestSlots) end
	local function incomeMult() return 1 + s.rebirths * C.Rebirth.IncomeBonusPerRebirth end
	local function luck() return s.rebirths * C.Luck.PerRebirthPercent end
	local function heatRate() return C.Heat.Max / C.Heat.SecondsToMax * C.GetUpgradeValue("IncubationSpeed", s.upgrades.IncubationSpeed) end
	local function creatureIncome(slot) return C.Rarities[slot.rarity].IncomePerSecond * incomeMult() end
	local function vaultCap(slot)
		return math.max(C.GetUpgradeValue("VaultSize", s.upgrades.VaultSize), creatureIncome(slot) * C.Income.MinVaultSeconds)
	end
	local function counts()
		local free, eggs, creatures, rarePlus = 0, 0, 0, false
		for i = 1, cap() do
			local n = s.nests[i]
			if not n then free += 1
			elseif n.kind == "Egg" then eggs += 1
			else
				creatures += 1
				if C.GetRarityIndex(n.rarity) >= C.RebirthMinRarityIndex then rarePlus = true end
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
	-- The best egg tier they'd aim for: spread the cash over up to 2 free nests.
	local function wantedTier(free)
		local budget = s.cash / math.max(1, math.min(free, 2))
		local best = 0
		for i, id in ipairs(eggOrder) do
			if unlocked(id) and C.Eggs[id].Price <= budget then best = i end
		end
		if best == 0 then
			for i, id in ipairs(eggOrder) do
				if unlocked(id) and C.Eggs[id].Price <= s.cash then best = i end
			end
		end
		return best
	end
	-- Income a player "usually" gets from an egg (Common..Epic only).
	local function typicalIncome(id)
		local ch = C.GetRarityChances(id, P.heatThreshold, luck())
		local v = 0
		for _, rar in ipairs({ "Common", "Uncommon", "Rare", "Epic" }) do v += ch[rar] * C.Rarities[rar].IncomePerSecond end
		return v * incomeMult()
	end
	local function placeEgg(id)
		for i = 1, cap() do
			if not s.nests[i] then s.nests[i] = { kind = "Egg", egg = id, heat = 0 } return true end
		end
		return false
	end
	local function collect(t)
		for i = 1, C.Plot.MaxNests do
			local n = s.nests[i]
			if n and n.kind == "Creature" then s.cash += n.vault n.vault = 0 end
		end
		s.lastCollect = t
	end
	-- Upgrades: cheapest first, keeping enough for a Forest egg per free nest.
	local function reserve()
		return (counts()) * C.Eggs[eggOrder[1]].Price
	end
	local function buyUpgrades(t, saving)
		if saving then return end
		local bought = true
		while bought do
			bought = false
			local bestId, bestCost = nil, math.huge
			for _, id in ipairs(C.UpgradeOrder) do
				local cost = C.GetUpgradeNextCost(id, s.upgrades[id])
				if cost and cost < bestCost then bestId, bestCost = id, cost end
			end
			if bestId and s.cash >= bestCost + reserve() then
				s.cash -= bestCost
				s.upgrades[bestId] += 1
				local key = bestId .. " L" .. s.upgrades[bestId] .. " (R" .. s.rebirths .. ")"
				if not res.upgrade[key] then res.upgrade[key] = t end
				if not res.firstUpgrade then res.firstUpgrade = t end
				table.insert(res.miles, t)
				bought = true
			end
		end
	end

	local nextSample = 1
	local t = 0
	while t < P.horizon do
		t += P.dt
		for i = 1, C.Plot.MaxNests do
			local n = s.nests[i]
			if n then
				if n.kind == "Egg" then n.heat = math.min(C.Heat.Max, n.heat + heatRate() * P.dt)
				else n.vault = math.min(vaultCap(n), n.vault + creatureIncome(n) * P.dt) end
			end
		end
		for _, id in ipairs(eggOrder) do
			if not res.eggAfford[id] and unlocked(id) and s.cash >= C.Eggs[id].Price then
				res.eggAfford[id] = t
				table.insert(res.miles, t)
			end
		end
		local free, eggs, creatures, rarePlus = counts()
		if creatures >= 1 and not res.firstCreature then res.firstCreature = t end
		if creatures >= 6 and not res.six then res.six = t end
		if rarePlus and not res.firstRare then res.firstRare = t end
		local cost = C.GetRebirthCost(s.rebirths)
		if rarePlus and s.cash >= cost and s.phase ~= "carrying" then
			s.rebirths += 1
			res.rebirth[s.rebirths] = t
			table.insert(res.miles, t)
			s.cash = P.rebirthCashAfter
			s.nests = {}
			for _, id in ipairs(C.UpgradeOrder) do s.upgrades[id] = 1 end
			s.phase = "home"
		end
		local saving = rarePlus and s.cash >= P.saveFraction * C.GetRebirthCost(s.rebirths)

		if s.phase == "home" then
			if t - s.lastCollect >= P.collectInterval then collect(t) end
			local threshold = if s.rebirths == 0 and s.hatches < P.earlyHatches then P.earlyThreshold else P.heatThreshold
			for i = 1, cap() do
				local n = s.nests[i]
				if n and n.kind == "Egg" and (n.heat >= threshold or (P.firstHatchNow and s.hatches == 0)) then
					local rar = rollRarity(n.egg, n.heat, luck())
					s.nests[i] = { kind = "Creature", rarity = rar, vault = 0 }
					s.hatches += 1
					if not res.rarSeen[rar] then
						res.rarSeen[rar] = t
						table.insert(res.miles, t)
					end
				end
			end
			free, eggs, creatures, rarePlus = counts()
			-- NestService rescue egg
			if C.Economy.RescueEnabled ~= false and eggs == 0 and creatures == 0 and s.cash < C.Eggs[eggOrder[1]].Price
				and t - s.lastRescue >= (C.Economy.RescueCooldown or 180) then
				placeEgg(C.Economy.RescueEggId or eggOrder[1])
				s.lastRescue = t
			end
			if P.release and free == 0 and eggs == 0 then
				local tier = wantedTier(1)
				if tier > 0 then
					local worstI, worstInc = nil, math.huge
					for i = 1, cap() do
						local n = s.nests[i]
						if n and n.kind == "Creature" and creatureIncome(n) < worstInc then worstI, worstInc = i, creatureIncome(n) end
					end
					if worstI and typicalIncome(eggOrder[tier]) > worstInc * 1.5 then
						s.cash += worstInc * P.sellSeconds + s.nests[worstI].vault
						s.nests[worstI] = nil
						free = 1
					end
				end
			end
			local tier = wantedTier(free)
			local wantsUpgrade = false
			if not saving then
				for _, id in ipairs(C.UpgradeOrder) do
					local c = C.GetUpgradeNextCost(id, s.upgrades[id])
					if c and s.cash >= c + reserve() then wantsUpgrade = true end
				end
			end
			if ((free > 0 and tier > 0) or wantsUpgrade) and t - s.lastTravel >= C.Travel.Cooldown then
				collect(t)
				s.phase = "toBelt"; s.timer = P.travelToBelt; s.lastTravel = t
			end
		elseif s.phase == "toBelt" then
			s.timer -= P.dt
			if s.timer <= 0 then s.phase = "atBelt"; s.beltWait = 0; buyUpgrades(t, saving) end
		elseif s.phase == "atBelt" then
			s.beltWait += P.dt
			if (t % C.Belt.SpawnInterval) == 0 then
				local id = rollBelt()
				local tier = wantedTier(math.max(free, 1))
				local ok = unlocked(id) and C.Eggs[id].Price <= s.cash and free > 0
					and (eggIndex[id] >= tier - 1 or s.beltWait >= P.impatience)
				if ok and rng:NextNumber() < P.gotWantedChance then
					s.cash -= C.Eggs[id].Price
					s.carryEgg = id
					local speed = C.GetUpgradeValue("WalkSpeed", s.upgrades.WalkSpeed) * C.Belt.CarrySpeedMultiplier
					s.phase = "carrying"; s.timer = P.carryDistance / speed + 2
				end
			end
			if s.phase == "atBelt" and (free == 0 or wantedTier(math.max(free, 1)) == 0) then
				s.phase = "walkHome"; s.timer = P.travelToBelt + 5
			end
		elseif s.phase == "carrying" then
			s.timer -= P.dt
			if s.timer <= 0 then
				placeEgg(s.carryEgg); s.carryEgg = nil; s.phase = "home"
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
	return string.format("%.1fm", sec / 60)
end

local function runVariant(name, overrideFn, params)
	P = table.clone(DEFAULTS)
	for k, v in pairs(params or {}) do P[k] = v end
	local backup = {}
	for k, v in pairs(Config) do if type(v) == "table" then backup[k] = v; Config[k] = deepCopy(v) end end
	local all = {}
	local ok, err = pcall(function()
		if overrideFn then overrideFn(Config) end
		for r = 1, P.runs do table.insert(all, runOnce(Config, r)) end
	end)
	for k, v in pairs(backup) do Config[k] = v end
	if not ok then return "ERROR " .. tostring(err) end

	local lines = { "== " .. name .. " (" .. #all .. " runs; median [p25..p75]) ==" }
	local function stat(label, get)
		local xs, never = {}, 0
		for _, r in ipairs(all) do local v = get(r) if v then table.insert(xs, v) else never += 1 end end
		table.insert(lines, string.format("%-30s %s [%s..%s]%s", label, fmtT(pct(xs, 0.5)), fmtT(pct(xs, 0.25)), fmtT(pct(xs, 0.75)),
			if never > 0 then string.format("  (never in %d%%)", math.floor(never / #all * 100)) else ""))
	end
	stat("first creature", function(r) return r.firstCreature end)
	stat("first upgrade (any)", function(r) return r.firstUpgrade end)
	stat("first Rare+", function(r) return r.firstRare end)
	stat("6 creatures at once", function(r) return r.six end)
	for _, id in ipairs(Config.EggOrder) do stat("can afford " .. id, function(r) return r.eggAfford[id] end) end
	local keys = {}
	for _, r in ipairs(all) do for k in pairs(r.upgrade) do if k:find("%(R0%)") then keys[k] = true end end end
	local sorted = {}
	for k in pairs(keys) do table.insert(sorted, k) end
	table.sort(sorted)
	for _, k in ipairs(sorted) do stat("upg " .. k, function(r) return r.upgrade[k] end) end
	for n = 1, 3 do stat("rebirth " .. n, function(r) return r.rebirth[n] end) end
	-- "Fresh goal" pacing: longest wait between milestones in the first hour.
	local gaps = {}
	for _, r in ipairs(all) do
		table.sort(r.miles)
		local last, worst = 0, 0
		for _, m in ipairs(r.miles) do
			if m > 3600 then break end
			worst = math.max(worst, m - last)
			last = m
		end
		worst = math.max(worst, 3600 - last)
		table.insert(gaps, worst)
	end
	stat("longest no-milestone gap, hr 1", function(r) return nil end)
	lines[#lines] = string.format("%-30s %s [%s..%s]", "longest goal gap in hour 1", fmtT(pct(gaps, 0.5)), fmtT(pct(gaps, 0.25)), fmtT(pct(gaps, 0.75)))
	local inc = {}
	for _, m in ipairs(SAMPLES) do
		local xs = {}
		for _, r in ipairs(all) do if r.income[m] then table.insert(xs, r.income[m]) end end
		table.insert(inc, string.format("%dm:$%s", m, Config.FormatNumber(pct(xs, 0.5) or 0)))
	end
	table.insert(lines, "income/s median: " .. table.concat(inc, "  "))
	return table.concat(lines, "\n")
end

_G.SAC_EconSim = runVariant
return "registered"
```
