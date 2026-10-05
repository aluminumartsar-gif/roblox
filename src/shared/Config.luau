--!strict
--[[
	Config
	ReplicatedStorage/Shared/Config

	SINGLE SOURCE OF TRUTH for every tunable number in Steal a Cryptid.
	Designers tune this file. Logic lives elsewhere and reads from here.

	Rules for this file:
	  * No game logic, no services, no requires of other game modules.
	  * Pure data + a few tiny pure helper functions at the bottom.
	  * Every number a designer might want to change belongs HERE, not inline.

	Conventions:
	  * All money values are in Cash (the only soft currency).
	  * All durations are in SECONDS unless the key says otherwise.
	  * All distances are in STUDS.
	  * Rarity weights are expressed as percentages that sum to 100 for
	    readability; the roll code normalizes, so they do not have to.
]]

local Config = {}

-- =========================================================================
-- VERSION / DEBUG
-- =========================================================================

Config.Version = "0.7.0-step6"

Config.Debug = {
	-- Master switch for verbose server logging.
	Verbose = true,
	-- Prints a roll-distribution simulation on server start (Step 3).
	RunOddsSimulationOnStart = false,
	SimulationRolls = 10000,
	-- Gives new profiles a pile of cash for testing. MUST be false at launch.
	GrantTestCash = false,
	TestCashAmount = 100000,
}

-- =========================================================================
-- RARITY
-- Order matters: index 1 is the most common. "Rare and above" for the heat
-- bonus means every rarity at HeatBonusMinIndex or higher.
-- =========================================================================

Config.RarityOrder = {
	"Common",
	"Uncommon",
	"Rare",
	"Epic",
	"Legendary",
	"Mythic",
	"Secret",
}

-- Which rarities heat and luck boost, and by how much, is set per rarity
-- in Config.Heat.MaxMultiplierByRarity (Rare and above).

Config.Rarities = {
	Common = {
		Index = 1,
		DisplayName = "Common",
		Color = Color3.fromRGB(175, 180, 186),
		IncomePerSecond = 1,
		-- Chat / banner announcement threshold handled by AnnounceOnHatch.
		AnnounceOnHatch = false,
	},
	Uncommon = {
		Index = 2,
		DisplayName = "Uncommon",
		Color = Color3.fromRGB(94, 196, 118),
		IncomePerSecond = 4,
		AnnounceOnHatch = false,
	},
	Rare = {
		Index = 3,
		DisplayName = "Rare",
		Color = Color3.fromRGB(78, 154, 241),
		IncomePerSecond = 15,
		AnnounceOnHatch = false,
	},
	Epic = {
		Index = 4,
		DisplayName = "Epic",
		Color = Color3.fromRGB(167, 105, 240),
		IncomePerSecond = 60,
		AnnounceOnHatch = false,
	},
	Legendary = {
		Index = 5,
		DisplayName = "Legendary",
		Color = Color3.fromRGB(246, 178, 59),
		IncomePerSecond = 250,
		AnnounceOnHatch = true,
	},
	Mythic = {
		Index = 6,
		DisplayName = "Mythic",
		Color = Color3.fromRGB(240, 74, 106),
		IncomePerSecond = 1200,
		AnnounceOnHatch = true,
	},
	Secret = {
		Index = 7,
		DisplayName = "???",
		Color = Color3.fromRGB(22, 22, 26),
		IncomePerSecond = 6000,
		AnnounceOnHatch = true,
		-- Secret cryptids never render clearly.
		NeverRenderClearly = true,
	},
}

-- Rebirth requires owning at least one creature of this rarity or higher.
Config.RebirthMinRarityIndex = 3 -- Rare

-- =========================================================================
-- CREATURES (30)
-- Id must be stable forever: it is what gets written into player profiles.
-- Only real folklore cryptids (public domain) for Common..Legendary.
-- Mythic and Secret are originals owned by this game.
-- PlaceholderColor / PlaceholderSize drive the part-based art until the
-- art pass replaces them with meshes.
-- =========================================================================

Config.Creatures = {
	-- ---------------- Common (6) ----------------
	{ Id = "jackalope",       Name = "Jackalope",            Rarity = "Common",    PlaceholderColor = Color3.fromRGB(168, 129,  92), PlaceholderSize = Vector3.new(2.0, 2.4, 3.0) },
	{ Id = "hodag",           Name = "Hodag",                Rarity = "Common",    PlaceholderColor = Color3.fromRGB( 92,  86,  70), PlaceholderSize = Vector3.new(3.0, 2.2, 4.0) },
	{ Id = "drop_bear",       Name = "Drop Bear",            Rarity = "Common",    PlaceholderColor = Color3.fromRGB(120, 102,  84), PlaceholderSize = Vector3.new(2.6, 3.0, 2.6) },
	{ Id = "snallygaster",    Name = "Snallygaster",         Rarity = "Common",    PlaceholderColor = Color3.fromRGB(104, 112, 104), PlaceholderSize = Vector3.new(4.0, 2.4, 3.2) },
	{ Id = "gremlin",         Name = "Gremlin",              Rarity = "Common",    PlaceholderColor = Color3.fromRGB(122, 150,  96), PlaceholderSize = Vector3.new(1.8, 2.2, 1.8) },
	{ Id = "wolpertinger",    Name = "Wolpertinger",         Rarity = "Common",    PlaceholderColor = Color3.fromRGB(148, 120,  88), PlaceholderSize = Vector3.new(2.0, 2.2, 2.8) },

	-- ---------------- Uncommon (6) ----------------
	{ Id = "chupacabra",      Name = "Chupacabra",           Rarity = "Uncommon",  PlaceholderColor = Color3.fromRGB( 84,  72,  72), PlaceholderSize = Vector3.new(2.4, 2.8, 4.0) },
	{ Id = "nightcrawler",    Name = "Fresno Nightcrawler",  Rarity = "Uncommon",  PlaceholderColor = Color3.fromRGB(226, 226, 230), PlaceholderSize = Vector3.new(1.6, 4.0, 1.6) },
	{ Id = "loveland_frog",   Name = "Loveland Frog",        Rarity = "Uncommon",  PlaceholderColor = Color3.fromRGB( 96, 158, 104), PlaceholderSize = Vector3.new(2.2, 3.0, 2.2) },
	{ Id = "goatman",         Name = "Goatman",              Rarity = "Uncommon",  PlaceholderColor = Color3.fromRGB(110,  92,  78), PlaceholderSize = Vector3.new(2.6, 4.2, 2.2) },
	{ Id = "bray_road",       Name = "Beast of Bray Road",   Rarity = "Uncommon",  PlaceholderColor = Color3.fromRGB( 88,  66,  50), PlaceholderSize = Vector3.new(2.8, 3.6, 4.2) },
	{ Id = "squonk",          Name = "Squonk",               Rarity = "Uncommon",  PlaceholderColor = Color3.fromRGB(140, 128, 148), PlaceholderSize = Vector3.new(2.4, 2.4, 3.0) },

	-- ---------------- Rare (5) ----------------
	{ Id = "yeti",            Name = "Yeti",                 Rarity = "Rare",      PlaceholderColor = Color3.fromRGB(232, 238, 245), PlaceholderSize = Vector3.new(3.4, 5.0, 3.0) },
	{ Id = "ogopogo",         Name = "Ogopogo",              Rarity = "Rare",      PlaceholderColor = Color3.fromRGB( 54, 110, 118), PlaceholderSize = Vector3.new(2.4, 2.4, 7.0) },
	{ Id = "dover_demon",     Name = "Dover Demon",          Rarity = "Rare",      PlaceholderColor = Color3.fromRGB(216, 196, 168), PlaceholderSize = Vector3.new(2.0, 3.2, 2.0) },
	{ Id = "flatwoods",       Name = "Flatwoods Monster",    Rarity = "Rare",      PlaceholderColor = Color3.fromRGB( 76, 168, 132), PlaceholderSize = Vector3.new(2.6, 5.4, 2.0) },
	{ Id = "jersey_devil",    Name = "Jersey Devil",         Rarity = "Rare",      PlaceholderColor = Color3.fromRGB(102,  70,  86), PlaceholderSize = Vector3.new(4.4, 3.4, 3.0) },

	-- ---------------- Epic (5) ----------------
	{ Id = "mothman",         Name = "Mothman",              Rarity = "Epic",      PlaceholderColor = Color3.fromRGB( 62,  54,  74), PlaceholderSize = Vector3.new(5.0, 4.2, 2.4) },
	{ Id = "bigfoot",         Name = "Bigfoot",              Rarity = "Epic",      PlaceholderColor = Color3.fromRGB( 74,  58,  44), PlaceholderSize = Vector3.new(3.6, 5.6, 3.0) },
	{ Id = "thunderbird",     Name = "Thunderbird",          Rarity = "Epic",      PlaceholderColor = Color3.fromRGB( 58,  70, 104), PlaceholderSize = Vector3.new(7.0, 3.0, 3.4) },
	{ Id = "bunyip",          Name = "Bunyip",               Rarity = "Epic",      PlaceholderColor = Color3.fromRGB( 70,  90,  72), PlaceholderSize = Vector3.new(3.6, 3.2, 5.4) },
	{ Id = "death_worm",      Name = "Mongolian Death Worm", Rarity = "Epic",      PlaceholderColor = Color3.fromRGB(180,  70,  64), PlaceholderSize = Vector3.new(2.2, 2.2, 6.4) },

	-- ---------------- Legendary (4) ----------------
	{ Id = "nessie",          Name = "Nessie",               Rarity = "Legendary", PlaceholderColor = Color3.fromRGB( 46,  96,  90), PlaceholderSize = Vector3.new(3.0, 4.6, 9.0) },
	{ Id = "kraken",          Name = "Kraken",               Rarity = "Legendary", PlaceholderColor = Color3.fromRGB( 92,  48,  74), PlaceholderSize = Vector3.new(6.0, 4.0, 6.0) },
	{ Id = "ningen",          Name = "Ningen",               Rarity = "Legendary", PlaceholderColor = Color3.fromRGB(240, 242, 246), PlaceholderSize = Vector3.new(3.4, 6.0, 3.0) },
	{ Id = "mokele_mbembe",   Name = "Mokele-Mbembe",        Rarity = "Legendary", PlaceholderColor = Color3.fromRGB( 84,  94,  62), PlaceholderSize = Vector3.new(3.4, 6.4, 8.0) },

	-- ---------------- Mythic (3) — originals ----------------
	{ Id = "the_static",      Name = "The Static",           Rarity = "Mythic",    PlaceholderColor = Color3.fromRGB(198, 198, 204), PlaceholderSize = Vector3.new(3.2, 5.2, 3.2) },
	{ Id = "the_signal",      Name = "The Signal",           Rarity = "Mythic",    PlaceholderColor = Color3.fromRGB( 96, 214, 226), PlaceholderSize = Vector3.new(2.8, 6.0, 2.8) },
	{ Id = "the_hollow",      Name = "The Hollow",           Rarity = "Mythic",    PlaceholderColor = Color3.fromRGB( 28,  26,  34), PlaceholderSize = Vector3.new(3.6, 5.6, 3.6) },

	-- ---------------- Secret (1) — original, never renders clearly ----------
	{ Id = "redacted",        Name = "[REDACTED]",           Rarity = "Secret",    PlaceholderColor = Color3.fromRGB( 18,  18,  20), PlaceholderSize = Vector3.new(3.4, 5.4, 3.4) },
}

-- =========================================================================
-- MUTATIONS (wired up in a later step; the data lives here from day one so
-- profiles can carry a Mutation field without a migration)
-- =========================================================================

Config.MutationsEnabled = false

Config.MutationOrder = { "Shiny", "Radioactive", "Spectral" }

Config.Mutations = {
	Shiny       = { DisplayName = "Shiny",       IncomeMultiplier = 1.5, Chance = 0.0400, Color = Color3.fromRGB(255, 226, 128) },
	Radioactive = { DisplayName = "Radioactive", IncomeMultiplier = 3.0, Chance = 0.0100, Color = Color3.fromRGB(140, 255,  90) },
	Spectral    = { DisplayName = "Spectral",    IncomeMultiplier = 5.0, Chance = 0.0025, Color = Color3.fromRGB(150, 210, 255) },
}

-- =========================================================================
-- EGGS
-- Weights are percentages. They do not need to sum to 100 (the roller
-- normalizes) but they are written to for readability.
-- RequiredRebirths gates the higher tiers.
-- =========================================================================

Config.EggOrder = { "forest", "swamp", "mountain", "deepsea", "sky", "void" }

Config.Eggs = {
	forest = {
		Id = "forest",
		Name = "Forest Egg",
		Price = 100,
		RequiredRebirths = 0,
		Color = Color3.fromRGB(104, 138,  92),
		HatchTimeHint = "Any time",
		Weights = { Common = 55.00, Uncommon = 27.00, Rare = 12.00, Epic =  4.50, Legendary =  1.20, Mythic = 0.25, Secret = 0.05 },
	},
	swamp = {
		Id = "swamp",
		Name = "Swamp Egg",
		Price = 1000,
		RequiredRebirths = 0,
		Color = Color3.fromRGB( 86, 104,  70),
		Weights = { Common = 40.00, Uncommon = 33.00, Rare = 18.00, Epic =  7.00, Legendary =  1.60, Mythic = 0.35, Secret = 0.05 },
	},
	mountain = {
		Id = "mountain",
		Name = "Mountain Egg",
		Price = 10000,
		RequiredRebirths = 0,
		Color = Color3.fromRGB(128, 134, 146),
		Weights = { Common = 25.00, Uncommon = 32.00, Rare = 26.00, Epic = 13.00, Legendary =  3.20, Mythic = 0.72, Secret = 0.08 },
	},
	deepsea = {
		Id = "deepsea",
		Name = "Deep Sea Egg",
		Price = 100000,
		RequiredRebirths = 0,
		Color = Color3.fromRGB( 48,  86, 112),
		Weights = { Common = 12.00, Uncommon = 25.00, Rare = 32.00, Epic = 22.00, Legendary =  7.50, Mythic = 1.35, Secret = 0.15 },
	},
	sky = {
		Id = "sky",
		Name = "Sky Egg",
		Price = 1000000,
		RequiredRebirths = 1,
		Color = Color3.fromRGB(158, 186, 216),
		Weights = { Common =  4.00, Uncommon = 14.00, Rare = 30.00, Epic = 33.00, Legendary = 15.00, Mythic = 3.70, Secret = 0.30 },
	},
	void = {
		Id = "void",
		Name = "Void Egg",
		Price = 25000000,
		RequiredRebirths = 3,
		Color = Color3.fromRGB( 42,  32,  56),
		Weights = { Common =  0.00, Uncommon =  4.00, Rare = 16.00, Epic = 34.00, Legendary = 32.00, Mythic = 12.50, Secret = 1.50 },
	},
}

-- =========================================================================
-- HEAT (Hook 1 — patience odds)
-- =========================================================================

Config.Heat = {
	Max = 100,
	-- Seconds for a nest to go 0 -> Max with no modifiers.
	SecondsToMax = 600, -- 10 minutes
	-- Server tick rate for heat accrual.
	TickInterval = 1,
	-- Weight multiplier each rarity reaches at full heat. Heat scales it
	-- linearly from x1 at heat 0, then all weights are renormalized:
	--   multiplier = 1 + (MaxMultiplier - 1) * (heat / Max)
	-- Rarer outcomes climb faster, so heat keeps pushing odds toward the top
	-- even on high-tier eggs that are already mostly Rare+.
	-- Rarities not listed here get no heat (or luck) boost.
	MaxMultiplierByRarity = {
		Rare = 2,
		Epic = 3,
		Legendary = 4,
		Mythic = 5,
		Secret = 6,
	},
	-- A stolen egg keeps its heat.
	ThiefKeepsHeat = true,
}

-- =========================================================================
-- LUCK
-- Luck is a percentage bonus applied on top of the heat multiplier to
-- Rare+ weights. Sources stack additively.
-- =========================================================================

-- This is the only place luck amounts are defined; BoostService adds them up.
Config.Luck = {
	PerRebirthPercent = 10,   -- +10% luck per rebirth
	VipPercent = 10,          -- VIP gamepass
	PotionPercent = 50,       -- Luck Potion dev product (duration: DevProducts.LuckPotion)
	CodexPageCompletePercent = 5, -- per completed rarity page (Step 7)
	MaxPercent = 500,         -- hard cap so nothing runs away
}

-- =========================================================================
-- SHOPS
-- =========================================================================

Config.Shop = {
	-- Buying needs you standing at the shop counter, within this many studs.
	-- (Generous, because the counter is wide; the shop panel closes if you
	-- wander further than this.)
	InteractDistance = 22,
}

-- =========================================================================
-- PLOT / NESTS
-- =========================================================================

-- Starting values for nest count, walk speed, lock duration and vault cap
-- are level 1 of their tracks in Config.Upgrades — that is the only place
-- they are defined.
Config.Plot = {
	-- Plots in the ring. Set the place's Server Size (max players) to match:
	-- a player who can't get a plot is turned away with a message.
	Count = 10,
	RingRadius = 260,         -- studs from hub centre to plot centre
	Size = Vector3.new(80, 1, 80),
	FloorHeight = 1,          -- plot deck top sits this far above the ground
	WallHeight = 14,          -- comfortably above a character's ~7 stud jump
	WallThickness = 1.5,
	DoorWidth = 12,
	-- Nests
	MaxNests = 12,
	NestGridColumns = 3,
	NestSpacing = 16,
	-- Owner perks
	OwnerWalkSpeedBonus = 0.15, -- +15% on your own plot
	-- Lock. Duration comes from the LockDuration upgrade track.
	-- The cooldown is measured from the moment the lock is activated, so
	-- with 60s locks and a 300s cooldown the base is open 4 min of every 5.
	LockCooldown = 300,
	-- false: the HUD Lock button works from anywhere on the map.
	-- true:  you must be standing on your own plot to lock it.
	LockRequiresPresence = false,
	ExtendedLockDuration = 180, -- Extended Lock gamepass (Step 6)
	EmergencyLockBonus = 120,   -- Emergency Lock dev product adds this (Step 6)
	-- How often the server re-checks who is standing on which plot (owner
	-- speed bonus, ejecting intruders from locked plots).
	EnforceInterval = 0.25,
}

-- =========================================================================
-- MAP (built by code from these numbers; see Modules/MapBuilder)
-- =========================================================================

Config.Map = {
	-- Seed for tree/rock placement. Same seed = same forest every boot.
	Seed = 1337,
	GroundSize = 1300,        -- square, centred on the hub
	GroundColor = Color3.fromRGB(46, 62, 40),
	PathColor = Color3.fromRGB(92, 74, 54),
	PathWidth = 12,
	HubRadius = 75,
	-- The Wilds: forest ring outside the plots where sightings spawn.
	WildsInnerRadius = 345,
	WildsOuterRadius = 560,
	WildsTreeCount = 240,
	WildsRockCount = 40,
	TreeMinSpacing = 14,
	-- Scattered trees between neighbouring plots, for the campsite feel.
	BetweenPlotTreesEach = 3,
	-- Invisible wall that keeps players inside the map.
	BoundaryRadius = 600,
	BoundaryHeight = 120,
}

-- =========================================================================
-- INCOME / COLLECTION
-- =========================================================================

Config.Income = {
	TickInterval = 1,
	-- Sanity cap: server refuses any single collect larger than this.
	-- Recomputed against owned creatures; this is the absolute backstop.
	AbsoluteMaxSingleCollect = 500000000,
	CollectTouchCooldown = 0.25,
	AutoCollectInterval = 5, -- Auto Collect gamepass
	-- Each creature's vault holds at least this many seconds of its own
	-- income, or the Vault Size upgrade's amount if that's bigger. Stops a
	-- Mythic/Secret from filling a $25K vault in seconds and then earning
	-- nothing. Set to 0 to use the Vault Size upgrade alone.
	MinVaultSeconds = 600,
	-- Offline earnings are OFF for now; revisit after launch economy data.
	OfflineEarningsEnabled = false,
}

-- =========================================================================
-- STEALING (Hook: the whole point)
-- =========================================================================

-- Hold time to steal is Config.Prompts.StealHold; reach is the prompt
-- distance (Config.Prompts), re-checked on the server.
Config.Steal = {
	CarrySpeedMultiplier = 0.75,      -- -25% walk speed while carrying
	StealCooldown = 30,               -- per thief, after a successful (claimed) steal
	SameItemImmunity = 120,           -- an item can't be stolen again within 2 min
	UnclaimedReturnTime = 60,         -- from the moment of the steal; carried or dropped
	-- Spawn protection: your camp can't be stolen from right after you join.
	-- Starting a steal yourself ends it early.
	NewPlayerSpawnLock = 300,         -- first ever join: 5 minutes
	ReturningPlayerSpawnLock = 120,   -- every later join: 2 minutes
	-- Hold time to pick up a dropped item (anyone, including the owner).
	PickupHold = 1,
	-- The server rejects a steal/pickup whose hold was shorter than the
	-- prompt's HoldDuration minus this (stops instant-steal exploits).
	HoldTolerance = 0.35,
	-- Carried item sits this far above the thief's HumanoidRootPart, and is
	-- shrunk to fit within MaxCarrySize studs so huge cryptids stay sane.
	CarryOffset = Vector3.new(0, 3.5, 0),
	MaxCarrySize = 6,
	-- Owner's uncollected vault cash is paid to the OWNER at the moment of the
	-- steal (thieves take the cryptid, not the wallet).
	PayOwnerVaultOnSteal = true,
	-- If the owner leaves while their item is being carried, it's forfeited
	-- (the thief can still claim it). Stops rage-quitting to save an item.
	OwnerLeavingForfeits = true,
}

Config.Bat = {
	Name = "Bat",
	Cooldown = 0.5,
	StunDuration = 1.0,
	-- After being stunned, a player can't be stunned again for this long
	-- (stops two players stun-locking someone).
	StunImmunity = 1.5,
	KnockbackVelocity = 60,
	KnockbackUp = 22,
	Range = 8,
	-- Targets must be roughly in front of the swing (dot product of the
	-- facing direction and the direction to the target).
	FrontDot = 0.2,
	-- true: anyone's Bat knocks a stolen item loose. false: only the item's owner.
	AnyoneCanDisarm = true,
	-- The Bat only disarms thieves; it does no damage.
	Damage = 0,
}

-- =========================================================================
-- SIGHTINGS (Hook 2 — Step 7)
-- =========================================================================

Config.Sightings = {
	Enabled = false, -- turned on in Step 7
	MinInterval = 360,  -- 6 minutes
	MaxInterval = 600,  -- 10 minutes
	Duration = 90,
	-- Capture hold time: Config.Prompts.CaptureHold.
	-- Base spawn odds; shifted rarer as the server fills up.
	BaseWeights = { Rare = 60, Epic = 30, Legendary = 9, Mythic = 1 },
	-- Per player online, shift this fraction of Rare weight into Epic+.
	RarerPerPlayer = 0.03,
	MaxPlayersForScaling = 20,
	-- Spawn area is The Wilds ring: Config.Map.WildsInnerRadius..OuterRadius.
	-- VHS effect radius around the sighting.
	VhsRadius = 120,
	VhsTint = Color3.fromRGB(196, 214, 196),
	VhsFovWobble = 2.5,
}

-- =========================================================================
-- CODEX (Hook 3 — Step 7)
-- =========================================================================

Config.Codex = {
	Enabled = false,
	CameraToolName = "Field Camera",
	PhotoCooldown = 2,
	MaxPhotoDistance = 60,
	-- Completing every creature in a rarity page grants permanent luck:
	-- the amount is Config.Luck.CodexPageCompletePercent.
	SurvivesRebirth = true,
}

-- =========================================================================
-- REBIRTH
-- =========================================================================

Config.Rebirth = {
	BaseCost = 50000,
	CostGrowth = 2.2,           -- cost = BaseCost * Growth ^ rebirths
	IncomeBonusPerRebirth = 0.25, -- +25% income
	-- Luck per rebirth: Config.Luck.PerRebirthPercent.
	-- What a rebirth wipes. RebirthService does exactly this list; anything
	-- not listed (rebirth count, codex, game passes, active potions, stats,
	-- purchase history) is kept. Supported entries: "Cash", "Nests",
	-- "Upgrades" — Bootstrap rejects anything else at boot.
	Resets = { "Cash", "Nests", "Upgrades" },
	-- Tell the whole server when someone rebirths.
	Announce = true,
	-- Cosmetic nest glow per rebirth count (cycles).
	NestGlowColors = {
		Color3.fromRGB(255, 214, 140),
		Color3.fromRGB(140, 226, 255),
		Color3.fromRGB(196, 140, 255),
		Color3.fromRGB(140, 255, 178),
		Color3.fromRGB(255, 140, 178),
		Color3.fromRGB(255, 120,  80),
	},
}

-- =========================================================================
-- UPGRADE SHOP
-- Each upgrade is a list of levels. Level 1 is the starting state and always
-- costs 0. Costs are absolute (not cumulative deltas).
-- =========================================================================

Config.UpgradeOrder = { "NestSlots", "IncubationSpeed", "VaultSize", "LockDuration", "WalkSpeed" }

Config.Upgrades = {
	NestSlots = {
		DisplayName = "Nest Slots",
		Icon = "Egg",
		Description = "More nests means more eggs cooking at once.",
		Levels = {
			{ Cost = 0,        Value = 6 },
			{ Cost = 5000,     Value = 7 },
			{ Cost = 25000,    Value = 8 },
			{ Cost = 120000,   Value = 9 },
			{ Cost = 600000,   Value = 10 },
			{ Cost = 3000000,  Value = 11 },
			{ Cost = 15000000, Value = 12 },
		},
	},
	IncubationSpeed = {
		DisplayName = "Incubation Speed",
		Icon = "Fire",
		Description = "Heat builds faster. Value is a multiplier on heat gain.",
		Levels = {
			{ Cost = 0,        Value = 1.00 },
			{ Cost = 7500,     Value = 1.15 },
			{ Cost = 40000,    Value = 1.30 },
			{ Cost = 200000,   Value = 1.50 },
			{ Cost = 1000000,  Value = 1.75 },
			{ Cost = 6000000,  Value = 2.00 },
		},
	},
	VaultSize = {
		DisplayName = "Vault Size",
		Icon = "Safe",
		Description = "How much uncollected cash a creature can hold.",
		Levels = {
			{ Cost = 0,        Value = 25000 },
			{ Cost = 10000,    Value = 75000 },
			{ Cost = 60000,    Value = 250000 },
			{ Cost = 350000,   Value = 1000000 },
			{ Cost = 2000000,  Value = 5000000 },
			{ Cost = 12000000, Value = 25000000 },
		},
	},
	LockDuration = {
		DisplayName = "Lock Duration",
		Icon = "Lock",
		Description = "How long your door stays locked, in seconds.",
		Levels = {
			{ Cost = 0,        Value = 60 },
			{ Cost = 15000,    Value = 75 },
			{ Cost = 80000,    Value = 90 },
			{ Cost = 450000,   Value = 110 },
			{ Cost = 2500000,  Value = 135 },
		},
	},
	WalkSpeed = {
		DisplayName = "Walk Speed",
		Icon = "Speed",
		Description = "Move faster everywhere. Value is studs/second.",
		Levels = {
			{ Cost = 0,        Value = 16 },
			{ Cost = 12000,    Value = 18 },
			{ Cost = 65000,    Value = 20 },
			{ Cost = 380000,   Value = 22 },
			{ Cost = 2200000,  Value = 24 },
		},
	},
}

-- =========================================================================
-- MONETIZATION
-- Every Id is 0 until the real asset is created in the Creator Dashboard.
-- Code MUST treat an Id of 0 as "not configured" and skip it gracefully.
-- =========================================================================

Config.GamePassOrder = { "DoubleCash", "ExtraNests", "AutoCollect", "Vip", "ExtendedLock" }

-- RobuxHint is only shown as a label until the real Id is set; once an Id is
-- set, the price shown comes from Roblox (MarketplaceService), never from here.
Config.GamePasses = {
	DoubleCash   = { Id = 0, DisplayName = "2x Cash",       RobuxHint = 399, Icon = "LightningBolt", Description = "All cryptid income doubled, forever." },
	ExtraNests   = { Id = 0, DisplayName = "+4 Nests",      RobuxHint = 299, Icon = "Plus",          Description = "Four extra nest slots on top of your upgrades.", BonusNests = 4 },
	AutoCollect  = { Id = 0, DisplayName = "Auto Collect",  RobuxHint = 149, Icon = "Magnet",        Description = "Cash collects itself. No more running laps." },
	Vip          = { Id = 0, DisplayName = "VIP",           RobuxHint = 599, Icon = "Crown",         Description = "VIP chat tag, +10% luck, gold nests." },
	ExtendedLock = { Id = 0, DisplayName = "Extended Lock", RobuxHint = 199, Icon = "Hourglass",     Description = "Your camp lock lasts 3 minutes instead of 1." },
}

-- Nest glow colour for VIPs (overrides the rebirth colour).
Config.VipNestGlow = Color3.fromRGB(255, 200, 60)

Config.DoubleCashMultiplier = 2

Config.DevProductOrder = {
	"CashSmall", "CashMedium", "CashLarge",
	"LuckPotion", "NestWarmer", "MaxHeat", "EmergencyLock", "EggBundle",
}

-- Kinds: "Cash" (Amount), "Buff" (Buff name + Duration; buying again while
-- active extends it), "Instant" (Effect). See MonetizationService.
Config.DevProducts = {
	CashSmall     = { Id = 0, DisplayName = "Pocket Change", RobuxHint =  99, Icon = "Cash",      Kind = "Cash", Amount = 25000,
		Description = "$25K cash." },
	CashMedium    = { Id = 0, DisplayName = "Stash",         RobuxHint = 399, Icon = "CoinStack", Kind = "Cash", Amount = 300000,
		Description = "$300K cash." },
	CashLarge     = { Id = 0, DisplayName = "Hoard",         RobuxHint = 999, Icon = "Safe",      Kind = "Cash", Amount = 5000000,
		Description = "$5M cash." },
	LuckPotion    = { Id = 0, DisplayName = "Luck Potion",   RobuxHint =  49, Icon = "Potion",    Kind = "Buff", Buff = "Luck", Duration = 900,
		Description = "+50% luck for 15 minutes." },
	NestWarmer    = { Id = 0, DisplayName = "Nest Warmer",   RobuxHint =  29, Icon = "Bonfire",   Kind = "Buff", Buff = "HeatRate", Duration = 600, Multiplier = 2,
		Description = "Eggs heat up 2x faster for 10 minutes." },
	-- Goes to your most valuable egg that isn't already at max heat. With no
	-- such egg, it's saved and applied to your next egg automatically.
	MaxHeat       = { Id = 0, DisplayName = "Max Heat",      RobuxHint =  99, Icon = "Fire",      Kind = "Instant", Effect = "MaxHeatOneEgg",
		Description = "Instantly max the heat of your best egg." },
	-- Locks your camp right now for EmergencyLockBonus seconds (ignores the
	-- cooldown), or adds that much to a lock that's already running.
	EmergencyLock = { Id = 0, DisplayName = "Emergency Lock",RobuxHint =  49, Icon = "Lock",      Kind = "Instant", Effect = "ExtendLock",
		Description = "Lock your camp for 2 minutes, right now." },
	-- Eggs that don't fit are saved and placed as soon as a nest frees up.
	EggBundle     = { Id = 0, DisplayName = "3-Egg Bundle",  RobuxHint =  79, Icon = "GiftBox",   Kind = "Instant", Effect = "GrantEggs", EggId = "forest", Count = 3,
		Description = "Three Forest Eggs, straight into your nests." },
}

-- =========================================================================
-- DATA / PERSISTENCE
-- =========================================================================

Config.Data = {
	StoreName = "StealACryptid",
	-- Bump this to wipe live data. Only do this before launch.
	StoreScope = "v1",
	AutosaveInterval = 60,
	LoadRetryCount = 5,
	LoadRetryBaseDelay = 1,     -- seconds; doubles each retry
	-- A server that crashed leaves its lock behind. Its heartbeat refreshes
	-- on every autosave, so after this many seconds of silence the lock is
	-- treated as dead and the player can load elsewhere. Keep it several
	-- times AutosaveInterval. Misjudging it cannot duplicate data (see
	-- SessionStore); it can only cost progress since the last save.
	SessionLockStaleAfter = 300,
	BindToCloseTimeout = 25,
}

-- =========================================================================
-- REMOTES
-- Every remote name in the game is declared here so nothing is a magic
-- string, and every one carries its own server-side rate limit.
-- Kind: "Event" (client -> server fire) or "Function" (client -> server invoke)
-- MaxPerMinute: hard server-side rate limit per player.
-- =========================================================================

Config.Remotes = {
	-- Server -> client pushes (no rate limit needed, server owns them)
	ProfileUpdated    = { Kind = "Event",    Direction = "ServerToClient" },
	Notify            = { Kind = "Event",    Direction = "ServerToClient" },
	SightingBanner    = { Kind = "Event",    Direction = "ServerToClient" },
	StealAlarm        = { Kind = "Event",    Direction = "ServerToClient" },
	GlobalAnnounce    = { Kind = "Event",    Direction = "ServerToClient" },

	-- Client -> server intents (all validated + rate limited server-side)
	-- (Hatching is a ProximityPrompt and collecting is a touch; both are
	-- handled server-side, so neither needs a remote.)
	BuyEgg            = { Kind = "Function", Direction = "ClientToServer", MaxPerMinute = 60 },
	BuyUpgrade        = { Kind = "Function", Direction = "ClientToServer", MaxPerMinute = 30 },
	DoRebirth         = { Kind = "Function", Direction = "ClientToServer", MaxPerMinute = 6 },
	LockPlot          = { Kind = "Function", Direction = "ClientToServer", MaxPerMinute = 20 },
	-- (Stealing, picking up and the Bat are prompts / a tool / a pad touch,
	-- all handled server-side, so they need no remotes.)
	BeginCapture      = { Kind = "Function", Direction = "ClientToServer", MaxPerMinute = 30 },
	TakePhoto         = { Kind = "Function", Direction = "ClientToServer", MaxPerMinute = 30 },
	PromptPurchase    = { Kind = "Function", Direction = "ClientToServer", MaxPerMinute = 30 },
}

-- Generic backstop: any single player firing more than this many remotes
-- per minute in total is throttled and logged.
Config.RemoteGlobalMaxPerMinute = 600

-- =========================================================================
-- INTERACTION (ProximityPrompts everywhere, so mobile works for free)
-- =========================================================================

Config.Prompts = {
	MaxActivationDistance = 12,   -- must match the server distance check
	ServerDistanceSlack = 4,      -- server allows MaxActivationDistance + slack
	ShopOpenHold = 0,             -- opening a shop panel is a tap
	HatchHold = 0.5,
	StealHold = 3,
	CaptureHold = 5,
	RequiresLineOfSight = false,
}

-- =========================================================================
-- COLLECTIONSERVICE TAGS
-- =========================================================================

Config.Tags = {
	Plot = "SAC_Plot",
	Nest = "SAC_Nest",
	Egg = "SAC_Egg",
	Creature = "SAC_Creature",
	CarriedItem = "SAC_CarriedItem",
	PlotPad = "SAC_PlotPad",
	Door = "SAC_Door",
	ShopBooth = "SAC_ShopBooth",
	WildCryptid = "SAC_WildCryptid",
}

-- =========================================================================
-- ATMOSPHERE (cozy-spooky night woods)
-- =========================================================================

-- Applied to Lighting by WorldService on every server boot. Fog is done with
-- the Atmosphere object (Roblox ignores Lighting.FogStart/FogEnd whenever
-- an Atmosphere exists), so tune Density/Haze for how far you can see.
Config.Atmosphere = {
	ClockTime = 0.5,             -- just past midnight
	Brightness = 1.2,
	OutdoorAmbient = Color3.fromRGB(46, 52, 66),
	Ambient = Color3.fromRGB(28, 30, 40),
	FogColor = Color3.fromRGB(38, 44, 56),     -- Atmosphere.Color
	FogDecay = Color3.fromRGB(24, 28, 40),     -- Atmosphere.Decay
	AtmosphereDensity = 0.42,
	AtmosphereHaze = 2.2,
	CampfireColor = Color3.fromRGB(255, 150, 70),
	CampfireRange = 40,
	CampfireBrightness = 3,
	LanternColor = Color3.fromRGB(255, 196, 128),
	LanternRange = 28,
	LanternBrightness = 2.4,
}

-- =========================================================================
-- UI
-- =========================================================================

-- =========================================================================
-- ICONS
-- Image assets from the RhosGFX vector icon pack, uploaded to the owner's
-- Roblox account. Name -> asset id. UI code refers to icons by name only.
-- The raw PNGs are licensed for use in this game but NOT for redistribution:
-- never commit them to the repo or share them.
-- =========================================================================

Config.Icons = {
	-- Uploaded for this game (Step 6)
	Robux = "rbxassetid://111461010960091",
	Home = "rbxassetid://123278209206320",
	Lock = "rbxassetid://79542927644203",
	Upgrade = "rbxassetid://101319211084955",
	Gamepass = "rbxassetid://97711607224924",
	Egg = "rbxassetid://96459853179308",
	Fire = "rbxassetid://79862891039155",
	BaseballBat = "rbxassetid://113980187844791",
	Shield = "rbxassetid://115529544163308",
	Grab = "rbxassetid://97364533673870",
	Warning = "rbxassetid://112550258471968",
	Bell = "rbxassetid://78916320743820",
	Camera = "rbxassetid://89819558395404",
	Crown = "rbxassetid://129810016065953",
	Magnet = "rbxassetid://95284966114108",
	Potion = "rbxassetid://121906053120526",
	Bonfire = "rbxassetid://93731199519470",
	Hourglass = "rbxassetid://122764375935062",
	Speed = "rbxassetid://135674501611736",
	CoinStack = "rbxassetid://128861081204402",
	GiftBox = "rbxassetid://77760913775552",
	LightningBolt = "rbxassetid://98253934440745",
	Trophy = "rbxassetid://108181704297182",
	Eye = "rbxassetid://122929953240700",
	Star = "rbxassetid://122945360107517",
	CheckMark = "rbxassetid://94964356674369",
	Safe = "rbxassetid://138634362320979",
	Plus = "rbxassetid://119968095935919",
	-- Already on the owner's account from an earlier project
	Cash = "rbxassetid://135269735731878",
	Gem = "rbxassetid://126829028564083",
	Luck = "rbxassetid://109347213399784",
	Rebirth = "rbxassetid://104402029372536",
	Shop = "rbxassetid://139879870675401",
	Settings = "rbxassetid://130100236267631",
	Book = "rbxassetid://111630944127601",
	Close = "rbxassetid://106243116040944",
	Backpack = "rbxassetid://82861236907905",
}

Config.UI = {
	NotificationDuration = 4,
	MaxNotifications = 4,
	BannerDuration = 8,
	-- Bottom bar buttons, in order.
	BottomButtons = { "Eggs", "Upgrades", "Rebirth", "Codex", "Robux" },
	-- Cash abbreviation suffixes.
	NumberSuffixes = { "", "K", "M", "B", "T", "Qa", "Qi" },
}

-- =========================================================================
-- PERFORMANCE
-- =========================================================================

Config.Performance = {
	-- Applied in Edit mode by tools/place-settings.luau. The streaming radii
	-- aren't scriptable in current Studio, so Roblox's defaults are used.
	StreamingEnabled = true,
	MaxCreaturePartsEach = 12,
}

-- =========================================================================
-- DERIVED LOOKUPS (built once at require time)
-- =========================================================================

local creaturesById: { [string]: any } = {}
local creaturesByRarity: { [string]: { any } } = {}

for _, rarity in ipairs(Config.RarityOrder) do
	creaturesByRarity[rarity] = {}
end

for _, creature in ipairs(Config.Creatures) do
	assert(creaturesById[creature.Id] == nil, "Duplicate creature Id: " .. creature.Id)
	assert(Config.Rarities[creature.Rarity] ~= nil, "Unknown rarity on " .. creature.Id)
	creaturesById[creature.Id] = creature
	table.insert(creaturesByRarity[creature.Rarity], creature)
end

Config.CreaturesById = creaturesById
Config.CreaturesByRarity = creaturesByRarity

-- =========================================================================
-- PURE HELPERS
-- No side effects, no services. Safe to call from client or server.
-- =========================================================================

--- Returns the rarity's position in RarityOrder, or 0 if unknown.
function Config.GetRarityIndex(rarity: string): number
	local entry = Config.Rarities[rarity]
	return entry and entry.Index or 0
end

--- True if this rarity gets the Heat / Luck weight bonus.
function Config.IsBoostedRarity(rarity: string): boolean
	return Config.Heat.MaxMultiplierByRarity[rarity] ~= nil
end

--- The multiplier applied to one rarity's weight at a given heat and luck.
--- Unboosted rarities (Common, Uncommon) always return 1.
--- heat: 0..Config.Heat.Max      luckPercent: additive percent, e.g. 25
function Config.GetBoostMultiplier(rarity: string, heat: number, luckPercent: number?): number
	local maxMultiplier = Config.Heat.MaxMultiplierByRarity[rarity]
	if not maxMultiplier then
		return 1
	end
	local h = math.clamp(heat or 0, 0, Config.Heat.Max)
	local heatPart = 1 + (maxMultiplier - 1) * (h / Config.Heat.Max)
	local luck = math.clamp(luckPercent or 0, 0, Config.Luck.MaxPercent)
	return heatPart * (1 + luck / 100)
end

--- Builds the normalized rarity chance table for an egg at a given heat/luck.
--- Returns { [rarity] = probability } summing to 1.
function Config.GetRarityChances(eggId: string, heat: number, luckPercent: number?): { [string]: number }
	local egg = Config.Eggs[eggId]
	assert(egg, "Unknown egg id: " .. tostring(eggId))

	local weighted: { [string]: number } = {}
	local total = 0

	for _, rarity in ipairs(Config.RarityOrder) do
		local w = (egg.Weights[rarity] or 0) * Config.GetBoostMultiplier(rarity, heat, luckPercent)
		weighted[rarity] = w
		total += w
	end

	local chances: { [string]: number } = {}
	if total <= 0 then
		-- Degenerate config; fall back to all-Common so nothing errors live.
		for _, rarity in ipairs(Config.RarityOrder) do
			chances[rarity] = rarity == "Common" and 1 or 0
		end
		return chances
	end

	for rarity, w in pairs(weighted) do
		chances[rarity] = w / total
	end
	return chances
end

--- Cost of the player's next rebirth.
function Config.GetRebirthCost(currentRebirths: number): number
	return math.floor(Config.Rebirth.BaseCost * (Config.Rebirth.CostGrowth ^ math.max(0, currentRebirths)))
end

--- Value of an upgrade at a given level (1-indexed, clamped).
function Config.GetUpgradeValue(upgradeId: string, level: number): number
	local up = Config.Upgrades[upgradeId]
	assert(up, "Unknown upgrade: " .. tostring(upgradeId))
	local lv = math.clamp(math.floor(level or 1), 1, #up.Levels)
	return up.Levels[lv].Value
end

--- Cost to go from `level` to `level + 1`, or nil if already maxed.
function Config.GetUpgradeNextCost(upgradeId: string, level: number): number?
	local up = Config.Upgrades[upgradeId]
	assert(up, "Unknown upgrade: " .. tostring(upgradeId))
	local nextLevel = math.floor(level or 1) + 1
	if nextLevel > #up.Levels then
		return nil
	end
	return up.Levels[nextLevel].Cost
end

--- Formats cash for UI: 1234567 -> "1.23M"
function Config.FormatNumber(n: number): string
	local negative = n < 0
	n = math.abs(n)
	local suffixes = Config.UI.NumberSuffixes
	local tier = 1
	while n >= 1000 and tier < #suffixes do
		n /= 1000
		tier += 1
	end
	local digits
	if tier == 1 then
		digits = string.format("%d", math.floor(n))
	elseif n < 10 then
		digits = string.format("%.2f", math.floor(n * 100) / 100)
	elseif n < 100 then
		digits = string.format("%.1f", math.floor(n * 10) / 10)
	else
		digits = string.format("%d", math.floor(n))
	end
	-- "1.00" -> "1", "1.50" -> "1.5", "10.0" -> "10" (only after a decimal point)
	if string.find(digits, ".", 1, true) then
		digits = string.gsub(digits, "%.?0+$", "")
	end
	return (negative and "-" or "") .. digits .. suffixes[tier]
end

table.freeze(Config.RarityOrder)
table.freeze(Config.EggOrder)

return Config
