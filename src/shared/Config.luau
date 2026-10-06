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

Config.Version = "0.9.0-broodmother"

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
-- ECONOMY BASICS
-- =========================================================================

Config.Economy = {
	-- A brand-new profile starts with this much cash: five Forest eggs off
	-- the belt, so the tutorial fills most of your nests and the first few
	-- minutes have something to do. (Was 300; see docs/ECONOMY.md.)
	StartingCash = 500,
	-- Safety net so nobody can get stuck: a player with no eggs, no
	-- creatures, nothing in hand, no saved eggs and less cash than the
	-- cheapest egg gets a free egg placed in a nest.
	RescueEnabled = true,
	RescueEggId = "forest",
	RescueCheckInterval = 5,   -- seconds between checks
	RescueCooldown = 180,      -- per player, seconds between free eggs
	-- Selling is how you upgrade your nests. When every usable nest holds a
	-- cryptid and you could afford an egg, you get one hint per visit.
	SellHintEnabled = true,
}

-- =========================================================================
-- RARITY
-- Order matters: index 1 is the most common.
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

-- Which rarities luck boosts: Config.Luck.BoostedRarities (Rare and up).
-- Selling a cryptid pays its vault plus Config.Sell.RefundSeconds of its
-- income (see Config.Sell).

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
-- Weights are percentages (each egg's add up to 100; the roller normalizes
-- anyway). Luck pushes the Rare-and-up weights higher (Config.Luck).
-- HatchTime: seconds an egg sits in your nest before it hatches by itself.
-- The longer it takes, the longer it's out there to be stolen — so the
-- best eggs are the biggest targets.
-- RequiredRebirths gates the higher tiers. AnnounceInNest tells the whole
-- server when someone has one cooking ("go and get it").
-- =========================================================================

Config.EggOrder = { "forest", "swamp", "mountain", "deepsea", "sky", "void" }

Config.Eggs = {
	forest = {
		Id = "forest",
		Name = "Forest Egg",
		Price = 100,
		HatchTime = 40,
		RequiredRebirths = 0,
		Color = Color3.fromRGB(104, 138,  92),
		Weights = { Common = 50.00, Uncommon = 24.50, Rare = 15.20, Epic =  7.30, Legendary =  2.40, Mythic = 0.50, Secret = 0.10 },
	},
	swamp = {
		Id = "swamp",
		Name = "Swamp Egg",
		Price = 600,
		HatchTime = 60,
		RequiredRebirths = 0,
		Color = Color3.fromRGB( 86, 104,  70),
		Weights = { Common = 34.60, Uncommon = 28.60, Rare = 21.80, Epic = 10.90, Legendary =  3.10, Mythic = 0.85, Secret = 0.15 },
	},
	mountain = {
		Id = "mountain",
		Name = "Mountain Egg",
		Price = 4000,
		HatchTime = 90,
		RequiredRebirths = 0,
		Color = Color3.fromRGB(128, 134, 146),
		Weights = { Common = 19.80, Uncommon = 25.40, Rare = 28.90, Epic = 18.60, Legendary =  5.60, Mythic = 1.50, Secret = 0.20 },
	},
	deepsea = {
		Id = "deepsea",
		Name = "Deep Sea Egg",
		Price = 30000,
		HatchTime = 150,
		RequiredRebirths = 0,
		Color = Color3.fromRGB( 48,  86, 112),
		Weights = { Common =  8.50, Uncommon = 17.60, Rare = 31.60, Epic = 27.90, Legendary = 11.60, Mythic = 2.50, Secret = 0.30 },
	},
	sky = {
		Id = "sky",
		Name = "Sky Egg",
		Price = 250000,
		HatchTime = 240,
		RequiredRebirths = 1,
		AnnounceInNest = true,
		Color = Color3.fromRGB(158, 186, 216),
		Weights = { Common =  2.50, Uncommon =  8.60, Rare = 25.80, Epic = 36.40, Legendary = 20.20, Mythic = 5.90, Secret = 0.60 },
	},
	void = {
		Id = "void",
		Name = "Void Egg",
		Price = 2500000,
		HatchTime = 360,
		RequiredRebirths = 3,
		AnnounceInNest = true,
		Color = Color3.fromRGB( 42,  32,  56),
		Weights = { Common =  0.00, Uncommon =  2.00, Rare = 11.50, Epic = 31.40, Legendary = 36.10, Mythic = 16.70, Secret = 2.30 },
	},
}

-- =========================================================================
-- EGG BELT
-- Eggs are bought off a circular conveyor belt around the hub campfire,
-- first come first served. Which egg comes out is random (EggWeights), so
-- the rare eggs really are rare. A bought egg is carried home in your hand
-- and only becomes yours when you reach your camp's pad; a bat hit knocks
-- it loose and anyone can grab it.
-- =========================================================================

Config.Belt = {
	Enabled = true,
	SpawnInterval = 2,          -- seconds between eggs
	-- Chance of each egg coming out of the burrow (relative weights; the
	-- odds board at the belt shows them as percentages). Eggs a player
	-- hasn't unlocked yet (RequiredRebirths) still ride past them.
	EggWeights = { forest = 50, swamp = 26, mountain = 14, deepsea = 6.5, sky = 2.8, void = 0.7 },
	-- Eggs that make a server-wide announcement when they come out.
	AnnounceEggs = { sky = true, void = true },
	-- Name colour on each egg's floating label.
	LabelColors = {
		forest = Color3.fromRGB(235, 235, 225),
		swamp = Color3.fromRGB(140, 230, 120),
		mountain = Color3.fromRGB(120, 180, 255),
		deepsea = Color3.fromRGB(190, 120, 255),
		sky = Color3.fromRGB(255, 210, 80),
		void = Color3.fromRGB(255, 80, 120),
	},

	-- Shape. The belt circles the hub campfire.
	Radius = 22,                -- centre line of the belt, studs from the fire
	Width = 4.5,
	Height = 1.6,               -- belt surface above the ground
	ArcDegrees = 320,           -- how far round an egg rides; the rest is the burrow gap
	GapCenterDegrees = 90,      -- where the gap (burrows + arch) sits; 90 faces the hub spawn
	SlatCount = 80,             -- moving slats drawn on the belt

	-- Timing of one egg's ride.
	RiseTime = 1.2,             -- climbing out of the start burrow
	TravelTime = 30,            -- riding the belt (can be bought only now)
	SinkTime = 1.2,             -- sinking into the end burrow

	-- Carrying a bought egg home.
	CarryScale = 0.55,          -- egg size in your hand
	CarrySpeedMultiplier = 0.85,
	DroppedEggLifetime = 30,    -- a knocked-loose egg vanishes after this
	MaxEggs = 40,               -- safety cap on eggs alive at once
}

-- =========================================================================
-- INCUBATION
-- An egg in your nest counts up to its HatchTime (Config.Eggs) and hatches
-- by itself. Hatch Speed (upgrade) and Hatch Boost (product) make it count
-- faster. A stolen egg keeps the progress it had (it doesn't count while
-- it's being carried), so an egg that's nearly done is the juiciest thing
-- on the map — and it says so: in its last stretch it glows and throws a
-- light pillar into the sky that everyone can see.
-- =========================================================================

Config.Incubation = {
	TickInterval = 1,           -- server tick, seconds
	AlmostReadyFraction = 0.8,  -- progress at which the egg starts to glow + pillar
}

-- =========================================================================
-- LUCK
-- Luck is a percentage bonus on the weights of the rarities listed in
-- BoostedRarities (Rare and up): weight x (1 + luck / 100). Sources stack
-- additively.
-- =========================================================================

-- This is the only place luck amounts are defined; BoostService adds them up.
Config.Luck = {
	PerRebirthPercent = 10,   -- +10% luck per rebirth
	VipPercent = 10,          -- VIP gamepass
	PotionPercent = 50,       -- Luck Potion dev product (duration: DevProducts.LuckPotion)
	CodexPageCompletePercent = 5, -- per completed rarity page (Step 7)
	MaxPercent = 500,         -- hard cap so nothing runs away
	BoostedRarities = { Rare = true, Epic = true, Legendary = true, Mythic = true, Secret = true },
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
-- FAST TRAVEL (the HUD's Base / Shop buttons)
-- Never while carrying anything: a thief has to walk the loot home.
-- =========================================================================

Config.Travel = {
	Enabled = true,
	Cooldown = 8,      -- seconds between teleports, per player
}

-- =========================================================================
-- MAP (built by code from these numbers; see Modules/MapBuilder)
-- =========================================================================

Config.Map = {
	-- Seed for every random placement (trees, rocks, hills, decor). Same
	-- seed = same world on every boot and every server.
	Seed = 1337,
	-- Square of terrain, centred on the hub. Reaches well past the boundary
	-- and the edge tree line, so the end of the world is never in view.
	GroundSize = 1500,
	-- (Kept for older code; the ground is Terrain now, coloured by TerrainColors.)
	GroundColor = Color3.fromRGB(46, 62, 40),
	PathColor = Color3.fromRGB(92, 74, 54),
	PathWidth = 12,
	HubRadius = 75,
	-- The Wilds: forest ring outside the plots where sightings spawn.
	WildsInnerRadius = 345,
	WildsOuterRadius = 560,
	WildsTreeCount = 330,
	WildsRockCount = 30,      -- small rocks
	WildsBoulderCount = 22,
	WildsBushCount = 110,
	WildsLogCount = 22,       -- fallen logs (jumpable)
	WildsStumpCount = 16,
	WildsMushroomCount = 34,  -- glowing teal clusters
	TreeMinSpacing = 13,      -- trunk to trunk; keeps the woods walkable
	-- Scattered trees between neighbouring plots, for the campsite feel.
	BetweenPlotTreesEach = 4,
	-- The meadow between the hub and the plot ring: light scatter only.
	MeadowTreeCount = 18,
	MeadowBushCount = 40,
	MeadowRockCount = 14,
	MeadowMushroomCount = 10,
	-- A thick tree line past The Wilds so the map edge reads as deep forest.
	EdgeTreeCount = 90,
	EdgeTreeOuterRadius = 660,
	-- Deer trails: clear, dirt-painted lanes from the plot ring out through
	-- The Wilds (one every TrailEvery plot gaps), so sightings are reachable.
	TrailEvery = 2,
	TrailWidth = 8,
	-- Gentle hills, only in The Wilds (plots, paths and hub stay flat at
	-- y = 0). Each hill is a cluster of overlapping terrain balls.
	HillCount = 26,
	HillBallsEach = { 4, 7 },       -- min, max balls per hill
	HillBallRadius = { 34, 46 },    -- studs
	HillBallCap = { 3, 9 },         -- how far each ball pokes above y = 0
	HillSpread = 26,                -- how far a hill's balls scatter
	HillMinRadius = 372,            -- no hill centre closer to the hub than this
	-- A ring of taller mounds past the boundary frames the map edge.
	EdgeBermBalls = 30,
	EdgeBermRadius = 60,
	EdgeBermCap = 16,
	EdgeBermDistance = 652,         -- ball centres, studs from the hub
	-- Hub: a cobblestone plaza round the egg belt, dirt round the fire.
	HubPlazaRadius = 36,
	HubFireCircleRadius = 18,
	-- Scale range for trees (1 = the prop's standing height).
	TreeScale = { 0.8, 1.35 },
	PineTreeShare = 0.62,           -- the rest are round trees
	-- Lantern posts along each hub-to-plot path.
	PathLanternSpacing = 40,
	-- Fireflies (ParticleEmitters): per emitter volume.
	FireflyColor = Color3.fromRGB(214, 255, 140),
	FireflyRate = 5,
	WildsFireflyPatches = 10,
	-- Glowing mushrooms: every Nth cluster also lights the ground.
	MushroomColor = Color3.fromRGB(90, 255, 220),
	MushroomLightEvery = 3,
	MushroomLightRange = 10,
	MushroomLightBrightness = 1.2,
	-- Plot palisade: vertical logs with pointed tops in front of a solid
	-- wall core (the core is the real collision, Config.Plot.WallHeight tall).
	PalisadeLogDiameter = 3,
	PalisadeLogSpacing = 3.6,
	-- Nest glow ring (SetNestActive): see-through amounts.
	NestGlowActiveTransparency = 0.25,
	NestLidColor = Color3.fromRGB(72, 74, 80), -- stone lid on locked nests
	HomePadColor = Color3.fromRGB(110, 230, 170),
	-- CollectionService tag on the hub campfire's fire part (sounds use it).
	HubCampfireTag = "SAC_HubCampfire",
	-- Standing height of each prop when it has to be built from parts (no
	-- mesh template). Meshes use their own height from Config.Art.Props.
	PropHeights = {
		PineTree = 26, RoundTree = 18, Bush = 3, Rock = 3, Boulder = 7, Stump = 2,
		FallenLog = 2, Mushroom = 2.5, Tent = 7, Campfire = 2.5, Lantern = 6,
		LogBench = 2.5, Crate = 3, Nest = 1.6, Totem = 14, Signpost = 7,
	},
	-- Terrain material colours (Workspace.Terrain:SetMaterialColor).
	TerrainColors = {
		Grass = Color3.fromRGB(70, 96, 56),
		LeafyGrass = Color3.fromRGB(58, 84, 50),
		Ground = Color3.fromRGB(110, 88, 64),
		Mud = Color3.fromRGB(84, 66, 50),
		Cobblestone = Color3.fromRGB(116, 112, 106),
		Rock = Color3.fromRGB(96, 98, 104),
	},
	-- Grass/dirt patches painted over the meadow and the woods.
	TerrainPatchCount = 140,
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
	-- Offline earnings (Step 7.5) are set up in Config.Retention.Offline.
}

-- =========================================================================
-- STEALING (Hook: the whole point)
-- =========================================================================

-- Hold time to steal is Config.Prompts.StealHold; reach is the prompt
-- distance (Config.Prompts), re-checked on the server.
Config.Steal = {
	CarrySpeedMultiplier = 0.75,      -- -25% walk speed while carrying
	-- What can be stolen out of a nest. The game is about stealing EGGS:
	-- cryptids you've hatched are yours to keep. (Add Creature = true to
	-- make hatched cryptids stealable too; every rule below still applies.)
	StealableKinds = { Egg = true },
	StealCooldown = 20,               -- per thief, after a successful (claimed) steal
	SameItemImmunity = 120,           -- an item can't be stolen again within 2 min
	UnclaimedReturnTime = 60,         -- from the moment of the steal; carried or dropped
	-- Spawn protection: your camp can't be stolen from right after you join.
	-- Starting a steal yourself ends it early.
	NewPlayerSpawnLock = 300,         -- first ever join: 5 minutes
	ReturningPlayerSpawnLock = 120,   -- a later join after ReturningLockMinAway offline: 2 minutes
	-- A fresh ReturningPlayerSpawnLock only after this long offline; a quicker
	-- rejoin just resumes whatever protection was left (saved in the profile
	-- as SpawnLockUntil), so rejoining can't keep a camp unstealable.
	ReturningLockMinAway = 600,
	-- Hold time to pick up a dropped item (anyone, including the owner).
	PickupHold = 1,
	-- The server rejects a steal/pickup/capture whose hold was shorter than
	-- the prompt's HoldDuration minus this (stops instant-steal exploits).
	HoldTolerance = 0.35,
	-- ...or whose Triggered came more than this long after the hold should
	-- have finished (an abandoned hold can't be cashed in later).
	HoldMaxOverrun = 1.5,
	-- Teleport check on claims: reaching your pad must take at least
	-- (flat distance from where the carry started) / (fastest legal carry
	-- speed * CarryTravelSlack) - CarryTravelGrace seconds.
	CarryTravelSlack = 1.5,
	CarryTravelGrace = 1,
	-- Carried item sits this far above the thief's HumanoidRootPart, and is
	-- shrunk to fit within MaxCarrySize studs so huge cryptids stay sane.
	CarryOffset = Vector3.new(0, 3.5, 0),
	MaxCarrySize = 6,
	-- Owner's uncollected vault cash is paid to the OWNER at the moment of the
	-- steal (thieves take the cryptid, not the wallet).
	PayOwnerVaultOnSteal = true,
	-- If the owner leaves while their item is being carried, it's forfeited
	-- (the thief can still claim it). Stops rage-quitting to save an item.
	-- Never on a server shutdown: then the item stays in the owner's nest.
	OwnerLeavingForfeits = true,
}

-- Selling a cryptid (owner only, ProximityPrompt on the cryptid): pays its
-- uncollected vault plus RefundSeconds of its income, and frees the nest
-- for a better egg.
Config.Sell = {
	Enabled = true,
	RefundSeconds = 60,
	-- Rarities that use the longer Config.Prompts.SellHoldRare hold.
	RareHoldFromIndex = 5, -- Legendary and up
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

-- Built in Step 7: Services/SightingService (server) and
-- Controllers/SightingController (banner, marker, VHS effect).
Config.Sightings = {
	Enabled = true,
	-- The first sighting comes this long after the first player loads in
	-- (a fresh or emptied server); after that, a random gap between
	-- MinInterval and MaxInterval, counted from when the last one ended
	-- (captured or escaped). Never while the server is empty.
	FirstDelay = 120,
	MinInterval = 360,  -- 6 minutes
	MaxInterval = 600,  -- 10 minutes
	Duration = 90,      -- seconds the wild cryptid stays before it escapes
	-- Capture hold time: Config.Prompts.CaptureHold.
	-- Base spawn odds; shifted rarer as the server fills up.
	BaseWeights = { Rare = 60, Epic = 30, Legendary = 9, Mythic = 1 },
	-- For each player online beyond the first, move this fraction of the
	-- most common rarity's weight (Rare) into the rarer ones (Epic+), in
	-- proportion to their base weights. Capped at MaxPlayersForScaling.
	RarerPerPlayer = 0.03,
	MaxPlayersForScaling = 20,

	-- Where it appears: a random spot in The Wilds ring
	-- (Config.Map.WildsInnerRadius..WildsOuterRadius), kept EdgeMargin studs
	-- inside the outer edge. A spot must be open ground: a ray down hits
	-- something walkable (terrain or a collidable part, not water), the ground
	-- is no steeper than MaxSlope degrees and no bumpier than MaxBumpiness
	-- studs across ClearanceRadius, and nothing collidable stands within
	-- ClearanceRadius x ClearanceHeight of it (parts wider than
	-- GroundPartMinWidth count as ground, not obstacles). Up to SpawnAttempts
	-- tries, then the middle of the ring at a random angle.
	EdgeMargin = 25,
	SpawnAttempts = 30,
	ClearanceRadius = 7,
	ClearanceHeight = 9,
	MaxSlope = 30,
	MaxBumpiness = 2.5,
	GroundPartMinWidth = 80,
	RaycastFromHeight = 300, -- rays start this high above the spot

	-- How it looks (rarity colour). A light pillar (Beam) rises from the
	-- wild cryptid so it can be seen across the map at night.
	PillarHeight = 160,
	PillarWidth = 4,
	PillarTransparency = 0.35, -- at the bottom; fades to invisible at the top
	LightRange = 28,
	LightBrightness = 3,
	-- While someone carries a capture home: a shorter pillar over them and
	-- a rarity-coloured outline visible through walls.
	CarryPillarHeight = 110,
	CarryPillarWidth = 2.5,

	-- Knocked out of a carrier's hands: anyone (with a free nest) can grab
	-- it for this long, then it escapes into the woods for good.
	DroppedLifetime = 30,

	-- Client-only polish.
	-- VHS "found footage" effect within VhsRadius of the sighting, full
	-- strength within VhsFullRadius.
	VhsRadius = 120,
	VhsFullRadius = 40,
	VhsTint = Color3.fromRGB(196, 214, 196),
	VhsSaturation = -0.45,  -- ColorCorrection at full strength
	VhsContrast = 0.18,
	VhsBrightness = -0.02,
	VhsFovWobble = 2.5,     -- degrees, at full strength
	VhsFovWobbleSpeed = 1.4, -- wobbles per second (roughly)
	VhsScanlineTransparency = 0.82, -- 1 = invisible
	VhsGrainDots = 26,       -- specks of grain on screen at once
	-- SightingAmbience replays this often while you're inside VhsRadius.
	AmbienceInterval = 12,
	-- The floating "this way" marker over the sighting (and over a capture
	-- on its way home) hides once you're this close.
	MarkerHideWithin = 18,
	-- The wild cryptid bobs a little on each client (visual only; the
	-- server keeps it still, because prompts are checked against the
	-- server's position).
	IdleBobHeight = 0.35,
	IdleBobSpeed = 1.6,
}

-- =========================================================================
-- CODEX (Hook 3 — Step 7)
-- =========================================================================

-- Every player gets a Field Camera each spawn. Photographing a cryptid (in
-- any nest, a wild sighting, or one being carried) logs it in their Codex;
-- hatching or claiming one logs it too. Completing every creature in a
-- rarity page grants permanent luck: Config.Luck.CodexPageCompletePercent
-- per page (BoostService adds it up). The Codex survives rebirth (it is not
-- in Config.Rebirth.Resets).
Config.Codex = {
	Enabled = true,
	CameraToolName = "Field Camera",
	PhotoCooldown = 2,           -- seconds between photos, per player (server-checked)
	MaxPhotoDistance = 60,       -- studs from your character to the cryptid
	                             -- (server allows + Config.Prompts.ServerDistanceSlack)
	SurvivesRebirth = true,

	-- Aiming (client). If the shot through the pointer / screen centre hits
	-- no cryptid, the closest one within this many degrees of the centre of
	-- the screen counts instead (forgiving on phones).
	FallbackConeDegrees = 14,
	TargetRefreshInterval = 0.1, -- seconds between viewfinder target checks

	-- Line of sight (server, lenient). Parts more see-through than this,
	-- and parts you can walk through, don't block a photo.
	LosIgnoreTransparency = 0.5,
	LosMaxPierce = 8,            -- see-through parts skipped per ray before giving up
	LosLenientRise = 4,          -- also try from this many studs above the head
	                             -- (third-person cameras see a bit higher)

	-- Camera tool look.
	ToolBodyColor = Color3.fromRGB(38, 38, 44),
	ToolLensColor = Color3.fromRGB(70, 110, 140),

	-- Feedback timings (client), seconds.
	ShutterFlashTime = 0.35,
	NewEntryBannerTime = 3.2,    -- the "NEW CODEX ENTRY" polaroid
	PageBannerTime = 5,          -- the "<Rarity> page complete!" banner
	HatchCelebrationDelay = 2.5, -- wait for the hatch reveal before the polaroid
	MaxQueuedCelebrations = 4,   -- more than this at once collapses into one toast

	-- Codex screen.
	CardsPerRow = 5,
	CardCameraFov = 30,
	CardCameraPadding = 1.1,     -- >1 leaves a little space round the creature
	EvidenceTint = Color3.fromRGB(255, 240, 214),     -- warm "old photo" tint
	EvidenceAmbient = Color3.fromRGB(140, 130, 118),
	EvidenceLight = Color3.fromRGB(255, 236, 205),
	EvidenceBorder = Color3.fromRGB(236, 226, 204),
	ScanlineTransparency = 0.82, -- 1 = no scanlines
	SecretGlitchInterval = 0.12, -- how often the Secret's photo flickers

	-- One line per creature for its Codex file. Folklore facts in our own
	-- words for Common..Legendary; Mythic and Secret are this game's own.
	Blurbs = {
		jackalope = "A jackrabbit with antelope horns. Old Western campfire tales say it can copy voices and sings along with cowboys after dark.",
		hodag = "A horned, spike-backed brute from the Wisconsin logging camps. Loggers swore you could smell it before you saw it.",
		drop_bear = "Australia's meat-eating cousin of the koala, said to drop out of gum trees onto visitors. Locals keep a straight face about it.",
		snallygaster = "A winged, beaked terror of Maryland's hills. Barns there were once painted with seven-pointed stars to keep it away.",
		gremlin = "Airmen in the Second World War blamed these tiny pests for every engine that sputtered and every tool that went missing.",
		wolpertinger = "A Bavarian hare with antlers, wings and fangs. They say it only shows itself at dusk, under a full moon.",

		chupacabra = "The 'goat-sucker' of Puerto Rico, first reported in 1995 after farm animals turned up drained in the night.",
		nightcrawler = "Just a pair of white legs, strolling along on their own. First spotted on a home security camera in Fresno, California.",
		loveland_frog = "A four-foot frog that walks upright, reported beside a road in Loveland, Ohio. One witness said it carried a sparking wand.",
		goatman = "Half man, half goat, said to haunt the back roads of Maryland. Blamed for every strange noise in the woods.",
		bray_road = "A wolf-like beast seen walking on two legs along a quiet country road near Elkhorn, Wisconsin.",
		squonk = "A warty, miserable creature of Pennsylvania's hemlock forests. Corner one and it dissolves into a puddle of its own tears.",

		yeti = "The 'Abominable Snowman' of the Himalayas, known mostly from huge footprints pressed into the high mountain snow.",
		ogopogo = "A long, humped serpent said to live in Okanagan Lake in British Columbia. Boaters still keep an eye on the water.",
		dover_demon = "Seen over two nights in 1977 in Dover, Massachusetts: a thin, pale thing with a huge melon-shaped head and glowing eyes.",
		flatwoods = "A towering figure with a spade-shaped hood, met by a group of kids on a hilltop in Flatwoods, West Virginia, in 1952.",
		jersey_devil = "A winged, hoofed creature of New Jersey's Pine Barrens, said to be the thirteenth child of a woman called Mother Leeds.",

		mothman = "A man-sized figure with great wings and glowing red eyes, reported around Point Pleasant, West Virginia, in 1966.",
		bigfoot = "The big, shy ape-man of North American forests, also called Sasquatch. Plenty of footprints, never a clear photo. Until now?",
		thunderbird = "A giant bird from the stories of many Indigenous peoples of North America, whose wingbeats were said to roll like thunder.",
		bunyip = "From Aboriginal Australian stories: a creature that lurks in swamps, creeks and billabongs, heard booming in the night.",
		death_worm = "A fat red worm said to live under the sands of the Gobi Desert. Herders warn it can spit poison from a distance.",

		nessie = "The long-necked resident of Loch Ness, Scotland. Its most famous photo, from 1934, turned out to be a toy submarine.",
		kraken = "A sea monster from the tales of Norwegian sailors, so enormous it could be mistaken for an island.",
		ningen = "A huge, pale, human-shaped thing said to drift in the icy seas near Antarctica, glimpsed at night from passing ships.",
		mokele_mbembe = "Said to live in the swamps of the Congo River basin. Its name is often translated as 'one who stops the flow of rivers'.",

		the_static = "It turns up as snow on every screen nearby. When the picture comes back, it is standing a little closer.",
		the_signal = "A tall shape that hums at the edge of radio range. Campers who tune in hear their own voices answering back.",
		the_hollow = "A gap in the dark, shaped like something with arms. Lanterns dim as it passes, and the crickets go quiet.",

		redacted = "FILE INCOMPLETE. Every photo of this subject develops blank. The field notes stop halfway through a sentence.",
	},
}

-- =========================================================================
-- RETENTION (Step 7.5): Daily Rewards, Spin Wheel, Playtime Gifts,
-- Offline Earnings. RetentionService decides and grants everything on the
-- server; the screens only show it.
--
-- A reward is { Items = { item, item, ... }, Label = "optional text" }.
-- Item kinds:
--   { Kind = "Cash", Base = 500, Minutes = 5 }
--       max(Base, Minutes of the player's current creature income), so cash
--       stays worth having at every stage. Capped at MaxCashReward.
--   { Kind = "Egg", EggId = "swamp", Count = 1 }
--       goes in a free nest, else is saved for the next free nest. An egg the
--       player hasn't unlocked yet becomes the best egg they have unlocked.
--   { Kind = "Buff", Buff = "Luck" | "HatchSpeed", Duration = 600 }
--       same as the Luck Potion / Hatch Boost; adds time to a running one.
--   { Kind = "InstantHatch", Count = 1 }
--       same as the Instant Hatch product (hatches your best egg now, else
--       saved for the next egg).
-- =========================================================================

export type RetentionItem = {
	Kind: string,
	Base: number?,
	Minutes: number?,
	EggId: string?,
	Count: number?,
	Buff: string?,
	Duration: number?,
}
export type RetentionReward = {
	Items: { RetentionItem },
	Label: string?,      -- shown instead of the generated text
	Weight: number?,     -- spin wheel only: relative chance
	Announce: boolean?,  -- spin wheel only: tell the whole server
	Minutes: number?,    -- playtime gifts only: unlocks after this many minutes
}

local dailyRewards: { RetentionReward } = {
	{ Items = { { Kind = "Cash", Base = 500, Minutes = 3 } } },
	{ Items = { { Kind = "Egg", EggId = "swamp", Count = 1 } } },
	{ Items = { { Kind = "Cash", Base = 2000, Minutes = 8 } } },
	{ Items = { { Kind = "Buff", Buff = "Luck", Duration = 900 } } },
	{ Items = { { Kind = "Cash", Base = 5000, Minutes = 15 } } },
	{ Items = { { Kind = "Egg", EggId = "mountain", Count = 1 }, { Kind = "Buff", Buff = "HatchSpeed", Duration = 900 } } },
	-- Day 7: the big one.
	{ Items = {
		{ Kind = "Cash", Base = 25000, Minutes = 45 },
		{ Kind = "Egg", EggId = "deepsea", Count = 1 },
		{ Kind = "Buff", Buff = "Luck", Duration = 1800 },
	} },
}

-- One prize per slot on the kit's wheel (it has 6), clockwise from the top.
local spinPrizes: { RetentionReward } = {
	{ Weight = 30, Items = { { Kind = "Cash", Base = 300, Minutes = 2 } } },
	{ Weight = 16, Items = { { Kind = "Egg", EggId = "mountain", Count = 1 } } },
	{ Weight = 24, Items = { { Kind = "Cash", Base = 1500, Minutes = 8 } } },
	{ Weight = 16, Label = "Boost Pack", Items = {
		{ Kind = "Buff", Buff = "Luck", Duration = 600 },
		{ Kind = "Buff", Buff = "HatchSpeed", Duration = 600 },
	} },
	{ Weight = 8, Items = { { Kind = "InstantHatch", Count = 1 } } },
	{ Weight = 6, Announce = true, Items = { { Kind = "Cash", Base = 10000, Minutes = 30 } } },
}

-- Unlock one after another during a single visit (the clock restarts every
-- time you join a server).
local playtimeGifts: { RetentionReward } = {
	{ Minutes = 2,  Items = { { Kind = "Cash", Base = 200, Minutes = 1 } } },
	{ Minutes = 5,  Items = { { Kind = "Cash", Base = 500, Minutes = 2 } } },
	{ Minutes = 10, Items = { { Kind = "Egg", EggId = "swamp", Count = 1 } } },
	{ Minutes = 15, Items = { { Kind = "Cash", Base = 1500, Minutes = 2 } } },
	{ Minutes = 25, Items = { { Kind = "Buff", Buff = "HatchSpeed", Duration = 600 } } },
	{ Minutes = 40, Items = { { Kind = "Cash", Base = 5000, Minutes = 4 } } },
	{ Minutes = 60, Items = { { Kind = "Egg", EggId = "mountain", Count = 1 }, { Kind = "Buff", Buff = "Luck", Duration = 900 } } },
}

Config.Retention = {
	-- Biggest single cash reward (daily, spin, gift, offline). Must stay
	-- below Config.Income.AbsoluteMaxSingleCollect or the grant is refused.
	MaxCashReward = 200000000,
	-- Claims save at once, but never more often than this per player.
	SaveDebounce = 6,
	-- The server re-sends everyone's retention state this often (keeps the
	-- income-scaled cash amounts on the screens current).
	StatePushInterval = 60,
	-- Icon (Config.Icons name) shown for each reward kind / buff.
	Icons = { Cash = "Cash", Egg = "Egg", Luck = "Potion", HatchSpeed = "Bonfire", InstantHatch = "Fire" },
	-- Short names for buffs in reward text.
	BuffNames = { Luck = "Luck Potion", HatchSpeed = "Hatch Boost" },

	Daily = {
		Enabled = true,
		-- A day is a UTC calendar day (os.time() // DayLength). Claim on the
		-- day after your last claim to keep the streak; miss a day and it
		-- starts again at day 1. After day 7 it goes round again.
		DayLength = 86400,
		Rewards = dailyRewards,     -- exactly 7 (the kit screen has 7 cards)
		AutoOpenDelay = 3,          -- seconds after joining before the screen pops up
		ClaimCooldown = 1,
	},

	Spin = {
		Enabled = true,
		FreeEvery = 4 * 3600,       -- one free spin every 4 hours (a new player has one ready)
		Prizes = spinPrizes,
		-- Seconds between spins; the server refuses spins faster than this.
		-- Keep it no longer than SpinTime, or a spin pressed the moment the
		-- wheel stops gets refused.
		Cooldown = 4,
		SpinTime = 4,               -- how long the wheel turns (the server tells you the prize after this)
		ExtraTurns = 5,             -- client: full turns before it settles
		-- Client: where the wheel's pointer is, in degrees clockwise from the
		-- top. Change this if the prize lands next to the pointer, not under it.
		PointerAngle = 0,
		-- Client: which of the kit's wheel colours to show
		-- ("SpinWheelPink", "SpinWheelOrange" or "SpinWheelRainbow").
		WheelStyle = "SpinWheelOrange",
	},

	Playtime = {
		Enabled = true,
		Gifts = playtimeGifts,
		ClaimCooldown = 0.5,
	},

	Offline = {
		Enabled = true,
		MinAwaySeconds = 300,       -- away less than 5 minutes: nothing
		MaxHours = 8,               -- at most 8 hours count
		Fraction = 0.25,            -- share of normal creature income earned while away
		HeartbeatInterval = 60,     -- how often "last seen" is written while online
		-- Wait this long after joining before working out offline cash, so
		-- game passes (2x Cash) have been checked.
		ComputeDelay = 5,
		-- If a Double purchase arrives with nothing left to double, this is
		-- given instead: max(Base, Minutes of creature income).
		DoubleFallbackBase = 2000,
		DoubleFallbackMinutes = 5,
		ClaimCooldown = 1,
	},
}

-- =========================================================================
-- LEADERBOARDS (Step 8)
-- =========================================================================

Config.Leaderboards = {
	Enabled = true,
	-- CollectionService tag on each board's screen part (MapBuilder builds
	-- three wooden boards in the hub). The part's "Board" attribute is one
	-- of the keys in Order.
	BoardTag = "SAC_Leaderboard",
	Order = { "Cash", "Rebirths", "Steals" },
	-- Store: OrderedDataStore name (prefixed with Config.Data.StoreName; the
	-- scope is the same as DataService: StudioStoreScope in Studio).
	Boards = {
		Cash = { Title = "TOP EARNERS", Subtitle = "All-time cash earned", Store = "LB_TotalCash", Prefix = "$" },
		Rebirths = { Title = "MOST REBIRTHS", Subtitle = "Fresh starts taken", Store = "LB_Rebirths", Prefix = "" },
		Steals = { Title = "MASTER THIEVES", Subtitle = "Eggs stolen", Store = "LB_Steals", Prefix = "" },
	},
	TopCount = 10,
	-- Each online player's scores are written once per UpdateInterval
	-- (spread out across players), and once more when they leave.
	UpdateInterval = 120,
	-- The boards re-read the top lists this often.
	RefreshInterval = 60,
	FirstRefreshDelay = 6,    -- seconds after boot before the first read
	ShutdownFlushTimeout = 8, -- server close waits this long for leave-writes
	RankColors = {
		Color3.fromRGB(255, 210, 90),  -- 1st
		Color3.fromRGB(214, 220, 232), -- 2nd
		Color3.fromRGB(222, 150, 96),  -- 3rd
	},
	RowColor = Color3.fromRGB(255, 236, 206),
}

-- =========================================================================
-- FIRST-JOIN TUTORIAL (Step 8)
-- Client only (TutorialController). Shown to anyone who has never hatched
-- an egg; each step ticks itself off from the player's real progress, so
-- nothing is saved and no remote is needed.
-- =========================================================================

Config.Tutorial = {
	Enabled = true,
	CheckInterval = 0.25,       -- seconds between progress checks / re-aiming the guide
	StepDoneDelay = 1.6,        -- how long "Nice!" shows before the next step
	-- Instruction panel (our own UI; ScreenScale shrinks it on phones).
	PanelTop = 0.125,           -- fraction of screen height: just under the kit HUD's Base/Eggs buttons
	PanelWidth = 470,           -- pixels at Config.UI.ScreenScale.ReferenceHeight
	DisplayOrder = 2,           -- over the kit HUD (1), under kit popups (5), steal banners (8), toasts (10)
	SkipConfirmTime = 3,        -- seconds the "tap again to skip" prompt waits for a second tap
	-- 3D guide: a glowing line from you to the target plus a bouncing arrow over it.
	BeamColorNear = Color3.fromRGB(255, 214, 120), -- the player's end
	BeamColorFar = Color3.fromRGB(120, 255, 180),  -- the target's end
	BeamWidth = 0.7,
	BeamHideDistance = 9,       -- studs: hide the line once you're this close
	MarkerHeight = 9,           -- studs above the target (clears the egg/creature labels)
	MarkerBounce = 1.2,         -- studs up and down
	MarkerBounceSpeed = 3.5,    -- radians per second
	MarkerSize = 56,            -- pixels
	-- Egg belt step: further than this from the belt, the guide points at
	-- the arch; closer, at the nearest egg you can buy.
	BeltNearDistance = 45,
	ArchOutside = 8,            -- studs outside the belt ring for the arch target
	EggMinRideLeft = 4,         -- don't point at an egg about to sink into the end burrow
	-- "Take it home" step: seconds after your hands empty before the panel
	-- says you lost the egg (claiming at the pad empties them a moment
	-- before the filled nest shows up here).
	LostEggGrace = 1,
}

-- =========================================================================
-- SOUNDS (Step 8). Name -> { Id, Volume, ... }. Only Roblox-hosted audio
-- that loads in this experience goes here.
--
-- Played by name through the client's SoundController:
--   SoundController.Play("CashCollect")            -- 2D (UI / "in your head")
--   SoundController.PlayAt("BatHit", position)     -- 3D, in the world
-- A name missing from this table is silently ignored, so a typo never
-- breaks a feature (Studio prints a warning once).
--
-- Fields: Id (rbxassetid), Volume (0..1), PlaybackSpeed (pitch, 1 = normal),
-- Looped, RollOff (3D only: studs at which it fades out completely).
-- Every id here is free public audio from Roblox's own library, Pro Sound
-- Effects, APM Music or Daily Sounds (checked public at Step 8). To swap a
-- sound, paste a new id; Studio's console lists any that fail to load.
-- =========================================================================

Config.Sounds = {
	-- UI
	UIClick          = { Id = "rbxassetid://15675032796",  Volume = 0.35 },                       -- Roblox UI Small Click
	UIOpen           = { Id = "rbxassetid://17208405682",  Volume = 0.35 },                       -- Roblox GUI Swipe
	Purchase         = { Id = "rbxassetid://17208380755",  Volume = 0.6 },                        -- Roblox GUI Purchase
	Notify           = { Id = "rbxassetid://17208372272",  Volume = 0.35 },                       -- Roblox GUI Notification Low
	Error            = { Id = "rbxassetid://17208353912",  Volume = 0.45 },                       -- Roblox GUI Negative
	-- Cash
	CashCollect      = { Id = "rbxassetid://130378474223829", Volume = 0.5 },                     -- Daily Sounds Coin Pickup
	-- Hatching: the crack, then one sting per rarity (rarer = bigger)
	HatchCrack       = { Id = "rbxassetid://9113959343",   Volume = 0.8 },                        -- Crack Egg Crunchy (PSE)
	HatchCommon      = { Id = "rbxassetid://15675055424",  Volume = 0.6 },                        -- Roblox UI Cute Pop
	HatchRare        = { Id = "rbxassetid://17208327798",  Volume = 0.7 },                        -- Roblox GUI Aura
	HatchEpic        = { Id = "rbxassetid://15675043410",  Volume = 0.7 },                        -- Roblox UI Tonal Stinger
	HatchLegendary   = { Id = "rbxassetid://1836286949",   Volume = 0.7 },                        -- APM "Top Ranking 1"
	HatchMythic      = { Id = "rbxassetid://1841354419",   Volume = 0.75 },                       -- APM "Supernaturalizer Hit 2"
	HatchSecret      = { Id = "rbxassetid://9038129814",   Volume = 0.8, PlaybackSpeed = 0.85 },  -- APM "Ghosting The Machine" (detuned)
	-- Stealing and the Bat
	StealAlarm       = { Id = "rbxassetid://80890994815283", Volume = 0.6 },                      -- Daily Sounds Warning Beeps
	StealSuccess     = { Id = "rbxassetid://1840076509",   Volume = 0.6 },                        -- APM "Through the Roof" sting
	BatHit           = { Id = "rbxassetid://9125380872",   Volume = 0.7, RollOff = 90 },          -- PSE wood bat whack
	Pickup           = { Id = "rbxassetid://17208323435",  Volume = 0.5 },                        -- Roblox GUI Equip
	Drop             = { Id = "rbxassetid://96795857757261", Volume = 0.5 },                      -- Daily Sounds Power Down
	LockOn           = { Id = "rbxassetid://9114144270",   Volume = 0.7, RollOff = 70 },          -- PSE deadbolt turn
	LockOff          = { Id = "rbxassetid://9114144264",   Volume = 0.6, PlaybackSpeed = 1.15, RollOff = 70 }, -- PSE deadbolt (higher)
	-- Rebirth
	Rebirth          = { Id = "rbxassetid://1836370627",   Volume = 0.7 },                        -- APM "Realisation"
	-- Sightings (Step 7)
	SightingHorn     = { Id = "rbxassetid://5692517175",   Volume = 0.6, PlaybackSpeed = 0.8 },   -- low foghorn
	SightingAmbience = { Id = "rbxassetid://9114244977",   Volume = 0.45, Looped = true, RollOff = 160 }, -- PSE "Electric Forest" ghostly bed
	CaptureSuccess   = { Id = "rbxassetid://1836369905",   Volume = 0.7 },                        -- APM "Thats It"
	-- Codex (Step 7)
	CameraShutter    = { Id = "rbxassetid://17208312548",  Volume = 0.6 },                        -- Roblox GUI Camera Shutter
	CodexNew         = { Id = "rbxassetid://17208361335",  Volume = 0.5 },                        -- Roblox GUI Notification High
	PageComplete     = { Id = "rbxassetid://1836370010",   Volume = 0.7 },                        -- APM "Blap 2"
	-- Retention (Step 7.5)
	DailyClaim       = { Id = "rbxassetid://9113849492",   Volume = 0.6 },                        -- PSE coins jingle
	SpinTick         = { Id = "rbxassetid://15675059323",  Volume = 0.3, PlaybackSpeed = 1.2 },   -- Roblox UI Bright Click
	SpinWin          = { Id = "rbxassetid://15675043410",  Volume = 0.7, PlaybackSpeed = 1.1 },   -- Roblox UI Tonal Stinger (higher)
	GiftClaim        = { Id = "rbxassetid://17208204604",  Volume = 0.6 },                        -- Roblox GUI Bubble
	-- Music and ambience (loops). Music obeys the Music setting; everything
	-- else obeys the Sounds setting.
	MusicMain        = { Id = "rbxassetid://1837630034",   Volume = 0.14, Looped = true, Group = "Music" }, -- APM "The Horrors" (low, under everything)
	AmbientNight     = { Id = "rbxassetid://9112835631",   Volume = 0.22, Looped = true },        -- PSE night: cricket + owls
	AmbientDread     = { Id = "rbxassetid://9125351530",   Volume = 0.12, Looped = true },        -- PSE "Afterworld Ambience": breathing, creaks (the woods are watching)
	Campfire         = { Id = "rbxassetid://9112780462",   Volume = 0.55, Looped = true, RollOff = 45 }, -- PSE fireplace crackle
	Owl              = { Id = "rbxassetid://9117181540",   Volume = 0.3, RollOff = 200 },         -- PSE owl hooting (random, far off)
	-- The Hunt (the Brood Mother)
	HuntWarning      = { Id = "rbxassetid://1843779857",   Volume = 0.6 },                        -- APM "Low Drone 15"
	HuntWail         = { Id = "rbxassetid://9120574965",   Volume = 0.8, PlaybackSpeed = 0.8 },   -- PSE waterphone burst, slowed: her wail
	Heartbeat        = { Id = "rbxassetid://9043365842",   Volume = 0, Looped = true },           -- APM "Heartbeat 02 96BPM" (volume driven by distance)
	Jumpscare        = { Id = "rbxassetid://9043346594",   Volume = 1, RollOff = 140 },           -- APM "Horror Scream 16"
}

-- =========================================================================
-- FEEDBACK / JUICE (Step 8): hatch reveal, cash popups, effects.
-- Read by FeedbackController, NestVisualsController, SoundController,
-- NotificationController and FeedbackService.
-- =========================================================================

Config.Feedback = {
	-- Hatch reveal (the celebration on the hatcher's screen)
	HatchRevealDuration = 3.2,       -- seconds before it closes itself (tap skips)
	HatchRevealBigDuration = 4.2,    -- Legendary and better stay up a little longer
	HatchQueueMax = 3,               -- hatches waiting to be shown; extra ones are skipped
	HatchStingDelay = 0.25,          -- gap between the shell crack and the rarity sting
	HatchRevealMinTime = 0.4,        -- taps before this don't skip (no accidental skips)
	HatchRevealQueuedFactor = 0.6,   -- with more hatches waiting, each reveal is this much shorter
	-- Which Config.Sounds sting plays for each rarity.
	HatchStings = {
		Common = "HatchCommon", Uncommon = "HatchCommon", Rare = "HatchRare", Epic = "HatchEpic",
		Legendary = "HatchLegendary", Mythic = "HatchMythic", Secret = "HatchSecret",
	},
	BigRarityIndex = 5,              -- this rarity index and up (Legendary+) gets shake, confetti, aura
	RayCount = 10,                   -- light rays behind the creature
	RaySpinSpeed = 25,               -- degrees per second
	CreatureSpinSpeed = 1.1,         -- radians per second in the viewport
	ShakeDuration = 0.45,            -- Legendary+ camera shake
	ShakeStrength = 0.35,            -- studs of camera offset at the start of the shake
	ConfettiCount = 46,              -- pieces of confetti for Legendary+
	SecretAccent = Color3.fromRGB(255, 50, 60), -- Secret's own colour is near-black; text and glow use this
	-- World burst at the nest when something hatches
	BurstParticles = 40,             -- your own hatch
	BurstParticlesRemote = 22,       -- someone else's Legendary+ hatch, seen from nearby
	RemoteBurstMaxDistance = 260,    -- studs; further away than this you don't see others' bursts
	BurstLifetime = 1.4,
	BurstSpeed = NumberRange.new(8, 18), -- studs per second the sparks fly out
	BatDustParticles = 10,           -- puff where a bat lands
	BatDustColor = Color3.fromRGB(235, 225, 200),

	-- Cash popups
	CashPopupRise = 4,               -- studs the "+$X" floats up
	CashPopupTime = 1.1,             -- seconds on screen
	CashPopupMaxDistance = 120,      -- don't draw popups further away than this
	CashSoundGap = 0.09,             -- at most one coin sound this often
	CashStreakWindow = 1.5,          -- collects closer together than this raise the coin pitch
	CashStreakPitchStep = 0.05,
	CashStreakPitchMax = 1.4,
	CashCountUpTime = 0.45,          -- HUD cash counts up to the new value over this long
	CashPunchScale = 1.15,           -- HUD cash label grows to this, then settles
	CashBigAmount = 10000,           -- popups this big or bigger are gold and larger (colours: Config.UI.Toasts)
	CashBigColor = Color3.fromRGB(255, 214, 90), -- gold sparks in the world (collects, claims)
	CashBurstParticles = 8,          -- little gold sparks per collect

	-- Nest labels (sized in studs, so they shrink with distance)
	NestLabelMaxDistance = 70,       -- labels hide further away than this
	NestLabelGap = 0.8,              -- studs between the top of the model and the label
	CreatureLabelSize = Vector2.new(6.5, 2.0),     -- width, height (studs): name + income
	CreatureLabelOwnSize = Vector2.new(6.5, 3.0),  -- your own creature: + vault bar
	EggLabelSize = Vector2.new(5.5, 2.0),          -- name + hatch countdown bar
	NestLabelMaxTextSize = 30,       -- px cap so labels aren't enormous when you stand right next to them

	-- Life: idle motion for creatures and eggs in nests (client only)
	IdleMaxDistance = 90,            -- only animate within this many studs of the camera
	IdleBobHeight = 0.12,            -- studs of breathing bob
	IdleBobSpeed = 1.6,              -- radians per second
	IdleYawDegrees = 9,              -- slow look-around, each side
	IdleYawSpeed = 0.35,
	EggWobbleProgress = 0.8,         -- eggs this close to hatching (0..1) wobble
	EggWobbleDegrees = 6,            -- just before hatching
	EggWobbleSpeed = 14,
	AuraRate = 5,                    -- Legendary+ aura particles per second

	-- Toasts
	ToastSlideTime = 0.25,
	ToastIcons = { Info = "Bell", Success = "CheckMark", Warning = "Warning", Error = "Warning", Announce = "Star" },
	ToastSounds = { Info = "Notify", Success = "Notify", Warning = "Notify", Error = "Error", Announce = "Notify" },
	ToastSoundQuietFor = 0.5,        -- a toast stays silent if another sound started this recently
	-- Sound playback
	SoundVoicesPerName = 4,          -- copies of one sound that can overlap
	DefaultRollOff = 100,            -- 3D sounds fade out completely by this many studs
	DefaultRollOffMin = 10,          -- ...and start fading beyond this
	SoundMaxLifetime = 20,           -- safety clean-up for one-shot 3D sounds
	StudioSoundCheck = true,         -- in Studio, print which Config.Sounds ids failed to load
	AlarmRepeatGap = 1.1,            -- seconds between StealAlarm repeats (the clip is about 1s)
	-- Ambience
	OwlMinInterval = 45,             -- a far-off owl hoots every 45..110 seconds
	OwlMaxInterval = 110,
	OwlDistance = NumberRange.new(60, 100), -- studs away from you, in a random direction
	OwlHeight = 20,                  -- up in the trees
	MusicFadeTime = 2,
	-- Hub campfire crackle: plays on the parts MapBuilder tags with
	-- Config.Map.HubCampfireTag (the hub fire's core). If none has streamed
	-- in yet, it sits at the hub centre, where the campfire is.
	CampfireTag = Config.Map.HubCampfireTag,
	CampfireHeight = 2,
}

-- =========================================================================
-- ART (Step 8). Generated meshes for creatures, eggs and props.
--
-- Each entry: { Mesh = "rbxassetid://...", Texture = "rbxassetid://...",
--   Height = studs, Yaw = degrees }. Height is the model's standing height;
--   Yaw turns the mesh so the creature faces -Z (the way it looks at the
--   door). ArtService turns these into templates under
--   ReplicatedStorage.ArtTemplates at boot; ItemVisuals clones them. Anything
--   missing here (or that fails to load) falls back to the block placeholder,
--   so a broken asset can never break the game.
-- =========================================================================

Config.Art = {
	-- Prompts, QA notes and how to regenerate: docs/ART.md.
	Creatures = {
		jackalope = { Mesh = "rbxassetid://131681255958586", Texture = "rbxassetid://79054338605187", Height = 3, Yaw = 0 },
		hodag = { Mesh = "rbxassetid://112139235538943", Texture = "rbxassetid://111351156320288", Height = 3, Yaw = 0 },
		drop_bear = { Mesh = "rbxassetid://103810274470439", Texture = "rbxassetid://107743726194616", Height = 3, Yaw = 0 },
		snallygaster = { Mesh = "rbxassetid://94810624728859", Texture = "rbxassetid://140476442674641", Height = 3, Yaw = 0 },
		gremlin = { Mesh = "rbxassetid://122939913645135", Texture = "rbxassetid://103548199248869", Height = 3, Yaw = 0 },
		wolpertinger = { Mesh = "rbxassetid://135528267883620", Texture = "rbxassetid://93241747302662", Height = 3, Yaw = 0 },
		chupacabra = { Mesh = "rbxassetid://130689751068861", Texture = "rbxassetid://83735307547478", Height = 3.6, Yaw = 0 },
		nightcrawler = { Mesh = "rbxassetid://132300026238480", Texture = "rbxassetid://126215002906504", Height = 3.6, Yaw = 0 },
		loveland_frog = { Mesh = "rbxassetid://112903869774176", Texture = "rbxassetid://113847998897304", Height = 3.6, Yaw = 0 },
		goatman = { Mesh = "rbxassetid://106004579622983", Texture = "rbxassetid://124830824690754", Height = 3.6, Yaw = 0 },
		bray_road = { Mesh = "rbxassetid://80700709050180", Texture = "rbxassetid://77749288711735", Height = 3.6, Yaw = 0 },
		squonk = { Mesh = "rbxassetid://130028451418667", Texture = "rbxassetid://128347868467618", Height = 3.6, Yaw = 0 },
		yeti = { Mesh = "rbxassetid://71417033105011", Texture = "rbxassetid://81052759386079", Height = 4.4, Yaw = 0 },
		ogopogo = { Mesh = "rbxassetid://119501796851037", Texture = "rbxassetid://131581534909188", Height = 4.4, Yaw = 0 },
		dover_demon = { Mesh = "rbxassetid://127820108357810", Texture = "rbxassetid://128404826249463", Height = 4.4, Yaw = 0 },
		flatwoods = { Mesh = "rbxassetid://95978287199268", Texture = "rbxassetid://114948872465345", Height = 4.4, Yaw = 0 },
		jersey_devil = { Mesh = "rbxassetid://133077204186004", Texture = "rbxassetid://112001839476144", Height = 4.4, Yaw = 0 },
		mothman = { Mesh = "rbxassetid://107438722643971", Texture = "rbxassetid://135727397672515", Height = 5.2, Yaw = 0 },
		bigfoot = { Mesh = "rbxassetid://124745552711970", Texture = "rbxassetid://89032616199124", Height = 5.2, Yaw = 0 },
		thunderbird = { Mesh = "rbxassetid://118963594307595", Texture = "rbxassetid://82598969794423", Height = 5.2, Yaw = 0 },
		bunyip = { Mesh = "rbxassetid://113317298872835", Texture = "rbxassetid://123505522201560", Height = 5.2, Yaw = 0 },
		death_worm = { Mesh = "rbxassetid://72402313990350", Texture = "rbxassetid://88869529137142", Height = 5.2, Yaw = 0 },
		nessie = { Mesh = "rbxassetid://105933576488987", Texture = "rbxassetid://115855645034356", Height = 4.4, Yaw = 0 },
		kraken = { Mesh = "rbxassetid://72768183058923", Texture = "rbxassetid://137691239141461", Height = 6.2, Yaw = 0 },
		ningen = { Mesh = "rbxassetid://117659548202346", Texture = "rbxassetid://83752095862825", Height = 6.2, Yaw = 0 },
		mokele_mbembe = { Mesh = "rbxassetid://120339522011118", Texture = "rbxassetid://84784757685916", Height = 6.2, Yaw = 0 },
		the_static = { Mesh = "rbxassetid://95556272454043", Texture = "rbxassetid://78106021129534", Height = 6.4, Yaw = 0 },
		the_signal = { Mesh = "rbxassetid://103819770144469", Texture = "rbxassetid://91451924433938", Height = 6.4, Yaw = 0 },
		the_hollow = { Mesh = "rbxassetid://88078350984363", Texture = "rbxassetid://125532570798335", Height = 6.4, Yaw = 0 },
		redacted = { Mesh = "rbxassetid://120127131863803", Texture = "rbxassetid://108522663384059", Height = 6.4, Yaw = 0 },
	},
	Eggs = {
		forest = { Mesh = "rbxassetid://128755161420008", Texture = "rbxassetid://113316397783775", Height = 3.4, Yaw = 0 },
		swamp = { Mesh = "rbxassetid://117946403371475", Texture = "rbxassetid://94687691990628", Height = 3.4, Yaw = 0 },
		mountain = { Mesh = "rbxassetid://120477806906855", Texture = "rbxassetid://85325511736961", Height = 3.4, Yaw = 0 },
		deepsea = { Mesh = "rbxassetid://87607024621959", Texture = "rbxassetid://94220551670754", Height = 3.4, Yaw = 0 },
		sky = { Mesh = "rbxassetid://128991196430590", Texture = "rbxassetid://80597578119558", Height = 3.4, Yaw = 0 },
		void = { Mesh = "rbxassetid://107844197297365", Texture = "rbxassetid://92962855209984", Height = 3.4, Yaw = 0 },
	},
	Props = {
		BroodMother = { Mesh = "rbxassetid://82525672471592", Texture = "rbxassetid://92308619353136", Height = 16, Yaw = 0 },
		BroodNest = { Mesh = "rbxassetid://92051071995688", Texture = "rbxassetid://136342658450558", Height = 4, Yaw = 0 },
		PineTree = { Mesh = "rbxassetid://120978045480952", Texture = "rbxassetid://99906053858043", Height = 26, Yaw = 0 },
		RoundTree = { Mesh = "rbxassetid://137352084557648", Texture = "rbxassetid://73858969692287", Height = 18, Yaw = 0 },
		Bush = { Mesh = "rbxassetid://113515846658272", Texture = "rbxassetid://82770608079115", Height = 3, Yaw = 0 },
		Rock = { Mesh = "rbxassetid://104204045661071", Texture = "rbxassetid://134156184554572", Height = 3, Yaw = 0 },
		Boulder = { Mesh = "rbxassetid://122868846112775", Texture = "rbxassetid://138895984433120", Height = 6, Yaw = 0 },
		Stump = { Mesh = "rbxassetid://77014346713469", Texture = "rbxassetid://93505119968562", Height = 2, Yaw = 0 },
		FallenLog = { Mesh = "rbxassetid://119148576956714", Texture = "rbxassetid://75875174676139", Height = 2.4, Yaw = 0 },
		Mushroom = { Mesh = "rbxassetid://121976905947599", Texture = "rbxassetid://103288479519348", Height = 2.5, Yaw = 0 },
		Tent = { Mesh = "rbxassetid://113005939175837", Texture = "rbxassetid://121224824088418", Height = 7, Yaw = 0 },
		Campfire = { Mesh = "rbxassetid://134781419754335", Texture = "rbxassetid://101049878330451", Height = 2.5, Yaw = 0 },
		Lantern = { Mesh = "rbxassetid://136230819142612", Texture = "rbxassetid://76117696975394", Height = 6, Yaw = 0 },
		LogBench = { Mesh = "rbxassetid://101656690216689", Texture = "rbxassetid://120458372602051", Height = 2.5, Yaw = 0 },
		Crate = { Mesh = "rbxassetid://126832556889214", Texture = "rbxassetid://137093063646573", Height = 3, Yaw = 0 },
		Nest = { Mesh = "rbxassetid://84706038882341", Texture = "rbxassetid://97704595335257", Height = 1.6, Yaw = 0 },
		Totem = { Mesh = "rbxassetid://80341899594440", Texture = "rbxassetid://136490453925914", Height = 14, Yaw = 0 },
		Signpost = { Mesh = "rbxassetid://105253205156519", Texture = "rbxassetid://133934530233307", Height = 7, Yaw = 0 },
	},
	-- Every creature mesh is drawn this much bigger than its Height above
	-- (one knob to make the cryptids loom over their nests).
	CreatureScale = 1.35,
	-- Boot waits up to this long for the meshes (they load in parallel,
	-- usually in a second or two). Anything not ready by then uses the
	-- placeholder for this server's lifetime.
	LoadTimeout = 20,
}

-- =========================================================================
-- THE HUNT — the Brood Mother (the scary twist)
-- Every few minutes the night deepens and the Brood Mother, the mother of
-- every cryptid egg in the woods, comes out of The Wilds to take her eggs
-- back. She hunts whoever is carrying an egg (a stolen one or a fresh one
-- off the belt). Camps and the hub campfire's light are safe: she won't
-- cross into them. If she catches you she takes the egg back (a stolen egg
-- goes home to its owner; anything else is gone) and you're stunned.
-- =========================================================================

Config.Hunt = {
	Enabled = true,
	Name = "The Brood Mother",
	FirstDelay = 240,          -- seconds after the first player loads
	MinInterval = 420,         -- between hunts (start to start)
	MaxInterval = 600,
	WarningTime = 10,          -- lights flicker and she wails before she emerges
	Duration = 70,             -- how long she hunts
	LeaveTime = 6,             -- sinking back into the woods

	-- Movement. Players walk at 16 and carry eggs at 16 * 0.85 (belt) or
	-- 16 * 0.75 (stolen), so a carrier caught in the open is in trouble.
	Speed = 15,
	ChaseSpeedBonus = 2,       -- extra speed while she's chasing a carrier
	TurnSpeed = 4,             -- how fast she swings toward a new heading (rad/s)
	HoverHeight = 0,           -- feet this far above the ground under her
	TickRate = 15,             -- server position updates per second

	-- Senses
	SenseRadius = 260,         -- she smells eggs this far away
	StalkRadius = 90,          -- she'll go after empty-handed players this close
	CatchRadius = 6,
	VictimCooldown = 25,       -- seconds before she goes after the same player again
	RetargetInterval = 0.5,
	-- Gives up on a target she hasn't got GiveUpProgress studs closer to in
	-- GiveUpTime seconds (stuck against a camp, the fire or the map edge).
	GiveUpTime = 3,
	GiveUpProgress = 2,

	-- Where she can't go
	SafeInCamps = true,        -- never enters a camp (any camp)
	CampfireSafeRadius = 70,   -- never enters this far from the hub centre (the fire keeps her back)
	BoundaryMargin = 12,       -- stays this far inside Config.Map.BoundaryRadius

	-- The reason StealService.Reclaim gets when she takes something back
	-- (SightingService reads it to word a captured cryptid's loss).
	ReclaimReason = "brood mother",
	-- Her jumpscare screen sits above every other UI (toasts 10, StealUI 8,
	-- Codex celebration 15, feedback fx 30/31).
	JumpscareDisplayOrder = 40,

	-- Getting caught
	StunDuration = 2.5,
	KnockbackVelocity = 45,

	-- Client-side dread (HuntController)
	DreadRadius = 140,         -- heartbeat / vignette start at this distance
	ShakeRadius = 35,          -- camera shake inside this distance
	DimLights = 0.6,           -- Lighting brightness multiplier while she hunts
	FogDensityBonus = 0.18,    -- thicker fog while she hunts
	Color = Color3.fromRGB(255, 70, 60), -- her eye / banner colour
	ModelHeight = 16,          -- fallback model size (the mesh is Config.Art.Props.BroodMother)

	-- Don't start a hunt while a wild sighting is running (and vice versa
	-- the sighting scheduler waits); retry after this long.
	BusyRetry = 30,
}

-- =========================================================================
-- REBIRTH
-- =========================================================================

Config.Rebirth = {
	-- Rebirths cost $400K, $920K, $2.12M, $4.87M... (docs/ECONOMY.md: first
	-- rebirth ~30 min into a real first session, then growing climbs).
	BaseCost = 400000,
	CostGrowth = 2.3,           -- cost = BaseCost * Growth ^ rebirths
	-- Cash you start with after a rebirth (instead of $0), so the climb back
	-- starts at once. Set directly, not counted as earned.
	StartingCash = 1500,
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
		Description = "More nests means more eggs hatching at once.",
		Levels = {
			{ Cost = 0,        Value = 6 },
			{ Cost = 1000,     Value = 7 },
			{ Cost = 6000,     Value = 8 },
			{ Cost = 30000,    Value = 9 },
			{ Cost = 150000,   Value = 10 },
			{ Cost = 750000,   Value = 11 },
			{ Cost = 4000000,  Value = 12 },
		},
	},
	IncubationSpeed = {
		DisplayName = "Hatch Speed",
		Icon = "Fire",
		Description = "Eggs hatch faster. Value is a speed multiplier on incubation.",
		Levels = {
			{ Cost = 0,        Value = 1.00 },
			{ Cost = 200,      Value = 1.20 },
			{ Cost = 3000,     Value = 1.40 },
			{ Cost = 20000,    Value = 1.60 },
			{ Cost = 120000,   Value = 1.80 },
			{ Cost = 750000,   Value = 2.00 },
		},
	},
	VaultSize = {
		DisplayName = "Vault Size",
		Icon = "Safe",
		Description = "How much uncollected cash a creature can hold.",
		Levels = {
			{ Cost = 0,        Value = 25000 },
			{ Cost = 2500,     Value = 75000 },
			{ Cost = 15000,    Value = 250000 },
			{ Cost = 100000,   Value = 1000000 },
			{ Cost = 600000,   Value = 5000000 },
			{ Cost = 4000000,  Value = 25000000 },
		},
	},
	LockDuration = {
		DisplayName = "Lock Duration",
		Icon = "Lock",
		Description = "How long your door stays locked, in seconds.",
		Levels = {
			{ Cost = 0,        Value = 60 },
			{ Cost = 1500,     Value = 75 },
			{ Cost = 10000,    Value = 90 },
			{ Cost = 60000,    Value = 110 },
			{ Cost = 400000,   Value = 135 },
		},
	},
	WalkSpeed = {
		DisplayName = "Walk Speed",
		Icon = "Speed",
		Description = "Move faster everywhere. Value is studs/second.",
		Levels = {
			{ Cost = 0,        Value = 16 },
			{ Cost = 500,      Value = 18 },
			{ Cost = 5000,     Value = 20 },
			{ Cost = 40000,    Value = 22 },
			{ Cost = 300000,   Value = 24 },
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
	"LuckPotion", "HatchBoost", "InstantHatch", "EmergencyLock", "EggBundle",
	-- Step 7.5: sold only from their own screens (Spin Wheel, Offline popup).
	"ExtraSpins", "OfflineDouble",
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
	HatchBoost    = { Id = 0, DisplayName = "Hatch Boost",   RobuxHint =  29, Icon = "Bonfire",   Kind = "Buff", Buff = "HatchSpeed", Duration = 600, Multiplier = 2,
		Description = "Your eggs hatch 2x faster for 10 minutes." },
	-- Hatches your most valuable egg right now (ties: the one with the most
	-- time left). With no egg in a nest, it's saved and used on your next one.
	InstantHatch  = { Id = 0, DisplayName = "Instant Hatch", RobuxHint =  99, Icon = "Fire",      Kind = "Instant", Effect = "InstantHatch",
		Description = "Hatch your best egg right now — no waiting, no thieves." },
	-- Locks your camp right now for EmergencyLockBonus seconds (ignores the
	-- cooldown), or adds that much to a lock that's already running.
	EmergencyLock = { Id = 0, DisplayName = "Emergency Lock",RobuxHint =  49, Icon = "Lock",      Kind = "Instant", Effect = "ExtendLock",
		Description = "Lock your camp for 2 minutes, right now." },
	-- Eggs that don't fit are saved and placed as soon as a nest frees up.
	EggBundle     = { Id = 0, DisplayName = "3-Egg Bundle",  RobuxHint =  79, Icon = "GiftBox",   Kind = "Instant", Effect = "GrantEggs", EggId = "forest", Count = 3,
		Description = "Three Forest Eggs, straight into your nests." },
	-- Step 7.5 (retention). Sold from the Spin Wheel and the Offline Earnings
	-- popup, not the Store. Granted by MonetizationService.
	ExtraSpins    = { Id = 0, DisplayName = "3 Extra Spins", RobuxHint =  49, Icon = "Luck",      Kind = "Instant", Effect = "ExtraSpins", Count = 3,
		Description = "Three more spins of the prize wheel." },
	-- Pays the waiting offline cash twice over. If it was already claimed,
	-- pays it once more (the second half); with nothing to double, a small
	-- cash gift (Config.Retention.Offline.DoubleFallback*).
	OfflineDouble = { Id = 0, DisplayName = "Double Offline Cash", RobuxHint = 25, Icon = "Cash", Kind = "Instant", Effect = "DoubleOffline",
		Description = "Double what your cryptids earned while you were away." },
}

-- =========================================================================
-- DATA / PERSISTENCE
-- =========================================================================

Config.Data = {
	StoreName = "StealACryptid",
	-- Live servers save here. Bump it to wipe live data (only before launch).
	StoreScope = "live1",
	-- Studio play tests save here instead, so testing never touches real
	-- players' saves. ("v1" is where all pre-launch testing was saved.)
	StudioStoreScope = "v1",
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
	-- The final (release) save is retried this many times, backing off from
	-- LoadRetryBaseDelay and doubling, but never past ReleaseSaveDeadline
	-- seconds in all (it must finish inside BindToCloseTimeout).
	ReleaseSaveRetryCount = 4,
	ReleaseSaveDeadline = 20,
	-- After a steal claim the thief's saves are held until the owner's loss
	-- is on disk (dupe safety). A hold is ignored after this many seconds.
	SaveHoldTimeout = 30,
	-- A steal claim retries the owner's save this many times (2, 4, 8s apart)
	-- before letting the thief's save through anyway.
	ClaimOwnerSaveRetries = 3,
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
	BuyUpgrade        = { Kind = "Function", Direction = "ClientToServer", MaxPerMinute = 30 },
	DoRebirth         = { Kind = "Function", Direction = "ClientToServer", MaxPerMinute = 6 },
	LockPlot          = { Kind = "Function", Direction = "ClientToServer", MaxPerMinute = 20 },
	-- (Stealing, picking up and the Bat are prompts / a tool / a pad touch,
	-- all handled server-side, so they need no remotes.)
	PromptPurchase    = { Kind = "Function", Direction = "ClientToServer", MaxPerMinute = 30 },
	Travel            = { Kind = "Function", Direction = "ClientToServer", MaxPerMinute = 20 },

	-- ---- Sightings (Step 7) ----
	-- SightingBanner (above) carries (phase, info) to everyone: "Started",
	-- "Captured", "Dropped", "PickedUp", "Claimed", "Escaped"; and to one
	-- player, "Interrupted" (their capture hold was broken). See
	-- Services/SightingService for each info table.
	-- Capturing is a ProximityPrompt, so it needs no client->server remote.

	-- ---- Codex (Step 7) ----
	TakePhoto         = { Kind = "Function", Direction = "ClientToServer", MaxPerMinute = 40 },
	CodexDiscovered   = { Kind = "Event",    Direction = "ServerToClient" },

	-- ---- Retention (Step 7.5) ----
	ClaimDaily        = { Kind = "Function", Direction = "ClientToServer", MaxPerMinute = 20 },
	SpinWheel         = { Kind = "Function", Direction = "ClientToServer", MaxPerMinute = 20 },
	ClaimPlaytimeGift = { Kind = "Function", Direction = "ClientToServer", MaxPerMinute = 30 },
	ClaimOffline      = { Kind = "Function", Direction = "ClientToServer", MaxPerMinute = 10 },
	RetentionState    = { Kind = "Event",    Direction = "ServerToClient" },

	-- ---- Feedback / juice (Step 8) ----
	-- HatchResult: (creatureId, rarity, mutation, eggId, nestPosition) to the hatcher.
	-- CashCollected: (amount, position) to the collector.
	-- FeedbackCue: (cue, info) — small presentation-only events:
	--   "BatHit" {Position} to everyone; "HatchBurst" {Position, Rarity, UserId}
	--   to everyone (Legendary+); "Bought" / "Taken" {Stolen} / "Claimed"
	--   {Stolen} / "Rebirth" {Rebirths} to the one player.
	HatchResult       = { Kind = "Event",    Direction = "ServerToClient" },
	CashCollected     = { Kind = "Event",    Direction = "ServerToClient" },
	FeedbackCue       = { Kind = "Event",    Direction = "ServerToClient" },

	-- ---- The Hunt (the Brood Mother) ----
	-- HuntEvent: (phase, info) to everyone: "Warning", "Started", "Caught",
	-- "Ended". Her position is replicated through ReplicatedStorage.HuntState
	-- attributes, not a remote.
	HuntEvent         = { Kind = "Event",    Direction = "ServerToClient" },
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
	BeltBuyHold = 0,              -- buying off the belt is a tap: a hold gets cut off when a
	                              -- different moving egg becomes the nearest
	StealHold = 3,
	SellHold = 1,                 -- selling one of your cryptids
	SellHoldRare = 2.5,           -- ...a Legendary or better (harder to do by accident)
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
	BeltEgg = "SAC_BeltEgg",
	BeltSlat = "SAC_BeltSlat",
	Burrow = "SAC_Burrow",
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
	GeographicLatitude = 30,     -- tilts the moon so it hangs over the woods
	Brightness = 1.6,            -- strength of the moonlight
	-- Cold blue moonlight and shadow fill; still bright enough on a phone.
	OutdoorAmbient = Color3.fromRGB(70, 80, 108),
	Ambient = Color3.fromRGB(40, 42, 58),
	ColorShiftTop = Color3.fromRGB(120, 146, 200),    -- tint of the moonlight
	ColorShiftBottom = Color3.fromRGB(0, 0, 0),
	ExposureCompensation = 0.25,
	EnvironmentDiffuseScale = 0.35,
	EnvironmentSpecularScale = 0.25,
	FogColor = Color3.fromRGB(44, 52, 70),     -- Atmosphere.Color
	FogDecay = Color3.fromRGB(26, 30, 46),     -- Atmosphere.Decay
	AtmosphereDensity = 0.4,
	AtmosphereOffset = 0.2,                    -- thicker fog toward the horizon
	AtmosphereHaze = 2,
	-- Sky (built-in properties only, no images): stars and a big moon.
	StarCount = 3000,
	MoonAngularSize = 16,
	-- Post effects. Bloom makes neon and fire glow; ColorCorrection grades.
	BloomIntensity = 0.7,
	BloomSize = 30,
	BloomThreshold = 1.5,
	ColorBrightness = 0.03,
	ColorContrast = 0.1,
	ColorSaturation = 0.05,
	ColorTint = Color3.fromRGB(246, 244, 255),
	SunRaysEnabled = false,     -- no sun at 2am
	CampfireColor = Color3.fromRGB(255, 150, 70),
	CampfireRange = 40,
	CampfireBrightness = 3,
	LanternColor = Color3.fromRGB(255, 196, 128),
	LanternRange = 26,
	LanternBrightness = 2.2,
	-- Every player carries a small lantern glow, so the dark woods stay
	-- playable and you can see other players' lights moving at night.
	PlayerLantern = {
		Enabled = true,
		Color = Color3.fromRGB(255, 186, 120),
		Range = 24,
		Brightness = 1.1,
	},
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
	-- Every icon is the pack's single-colour "Flat White" glyph, uploaded
	-- for the UI revamp. Code tints them (ImageColor3, default
	-- Config.UI.Theme.Colors.Text), so one image serves every colour and
	-- the whole game reads as one icon family.
	-- Currency and shop
	Robux = "rbxassetid://105833566519916",
	Cash = "rbxassetid://74487654589473",
	CoinStack = "rbxassetid://89488322828081",
	Wallet = "rbxassetid://122084609624833",
	PiggyBank = "rbxassetid://94730188442712",
	Gem = "rbxassetid://132602711563683",
	Shop = "rbxassetid://121919807993307",
	Gamepass = "rbxassetid://88821044083569",
	Ticket = "rbxassetid://98280081311906",
	-- Things in the world
	Egg = "rbxassetid://104111505743123",
	Fire = "rbxassetid://96165261773109",
	Bonfire = "rbxassetid://117119819651307",
	Lantern = "rbxassetid://115693142556570",
	Torch = "rbxassetid://99444790707610",
	BaseballBat = "rbxassetid://76437298919842",
	Camera = "rbxassetid://91633563261882",
	Potion = "rbxassetid://95585247404287",
	Safe = "rbxassetid://84773992852717",
	Chest = "rbxassetid://88417341667361",
	Key = "rbxassetid://101601685000133",
	Bone = "rbxassetid://94171236666182",
	Tree = "rbxassetid://89306497624502",
	Moon = "rbxassetid://125640024053910",
	-- Spooky
	Skull = "rbxassetid://127706985638475",
	Ghost = "rbxassetid://78605697616893",
	Tombstone = "rbxassetid://94807296092056",
	Web = "rbxassetid://135361596687128",
	Paw = "rbxassetid://104423411021181",
	Eye = "rbxassetid://114757828937691",
	-- Actions and status
	Home = "rbxassetid://121464750150043",
	Lock = "rbxassetid://117625849792120",
	Shield = "rbxassetid://102853307149668",
	Grab = "rbxassetid://103486150645704",
	Hand = "rbxassetid://132575405960609",
	Run = "rbxassetid://78020291085130",
	Speed = "rbxassetid://116309529406677",
	Upgrade = "rbxassetid://74202754920428",
	Rebirth = "rbxassetid://75566655495691",
	Luck = "rbxassetid://122891234817249",
	LightningBolt = "rbxassetid://93316172124003",
	Magnet = "rbxassetid://105353555481457",
	Hourglass = "rbxassetid://104116147530627",
	Clock = "rbxassetid://122990770061099",
	Target = "rbxassetid://140192867211928",
	Spectate = "rbxassetid://110919155709371",
	LocationPin = "rbxassetid://121409723828128",
	Compass = "rbxassetid://108710563709141",
	Map = "rbxassetid://101034592347157",
	-- Screens
	Book = "rbxassetid://130522880941475",
	Scroll = "rbxassetid://93121157366520",
	Clipboard = "rbxassetid://73298629620657",
	MagnifyingGlass = "rbxassetid://127870921105625",
	GiftBox = "rbxassetid://81839231619581",
	DailyRewards = "rbxassetid://139213378452996",
	Calendar = "rbxassetid://84817061220085",
	Spinner = "rbxassetid://88479908591871",
	AddFriend = "rbxassetid://76971070541516",
	Friends = "rbxassetid://113676153853915",
	Settings = "rbxassetid://110025327203303",
	Backpack = "rbxassetid://98201508358244",
	Trophy = "rbxassetid://124870733195816",
	Crown = "rbxassetid://85838272268758",
	Star = "rbxassetid://138465762155657",
	Sparkle = "rbxassetid://123682485307732",
	Stats = "rbxassetid://71516755624708",
	-- Interface
	Close = "rbxassetid://120990793869637",
	Plus = "rbxassetid://75417703403662",
	CheckMark = "rbxassetid://135952755059560",
	Warning = "rbxassetid://133141074647003",
	Exclamation = "rbxassetid://102488163524850",
	Info = "rbxassetid://110873944160022",
	QuestionMark = "rbxassetid://129304276201508",
	Bell = "rbxassetid://130245520903844",
	ChevronLeft = "rbxassetid://96329382662670",
	ChevronRight = "rbxassetid://78452096323597",
	Sound = "rbxassetid://101569494313519",
	SoundOff = "rbxassetid://75579401097516",
	Music = "rbxassetid://86573771345782",
	MusicOff = "rbxassetid://85949669918652",
}

Config.UI = {
	NotificationDuration = 4,
	MaxNotifications = 4,
	BannerDuration = 8,
	-- Pixel-sized UI scales with screen height so it fits phones:
	-- scale = screen height / ReferenceHeight, kept between Min and Max.
	-- Windows also shrink further if they still wouldn't fit.
	ScreenScale = { ReferenceHeight = 650, Min = 0.7, Max = 1.2 },
	-- Cash abbreviation suffixes.
	NumberSuffixes = { "", "K", "M", "B", "T", "Qa", "Qi" },

	-- THEME: "campfire field kit". Charred-wood panels, bone text, ember
	-- orange for the main action, cold moonlight blue for info, blood red
	-- for danger, moss green for cash. Every screen reads its colours and
	-- fonts from here (through Components/Theme), so restyling the whole
	-- game is a matter of editing this table.
	Theme = {
		Colors = {
			Backdrop = Color3.fromRGB(5, 5, 8),         -- dims the world behind a window
			Panel = Color3.fromRGB(21, 18, 16),         -- window body
			PanelTop = Color3.fromRGB(36, 30, 25),      -- top of the window gradient
			Raised = Color3.fromRGB(39, 33, 28),        -- cards and rows
			RaisedTop = Color3.fromRGB(52, 44, 36),
			Inset = Color3.fromRGB(12, 10, 9),          -- sunken wells, bar tracks, inputs
			Edge = Color3.fromRGB(84, 67, 50),          -- weathered-wood borders
			EdgeBright = Color3.fromRGB(150, 120, 84),  -- hovered borders
			Text = Color3.fromRGB(238, 228, 206),       -- bone: main text and icons
			TextDim = Color3.fromRGB(170, 158, 138),    -- ash: secondary text
			TextFaint = Color3.fromRGB(108, 99, 88),    -- smoke: disabled / hints
			TextOnAccent = Color3.fromRGB(30, 19, 10),  -- text on ember/moss/moon buttons
			Ember = Color3.fromRGB(240, 136, 48),       -- primary accent (campfire)
			EmberBright = Color3.fromRGB(255, 194, 104),
			EmberDeep = Color3.fromRGB(160, 60, 22),
			Moon = Color3.fromRGB(150, 186, 226),       -- info accent (moonlight)
			MoonBright = Color3.fromRGB(206, 226, 248),
			MoonDeep = Color3.fromRGB(56, 84, 122),
			Blood = Color3.fromRGB(198, 44, 36),        -- danger / steal / the Hunt
			BloodBright = Color3.fromRGB(255, 98, 82),
			BloodDeep = Color3.fromRGB(92, 14, 12),
			Moss = Color3.fromRGB(122, 200, 92),        -- cash / success
			MossBright = Color3.fromRGB(184, 238, 142),
			MossDeep = Color3.fromRGB(42, 96, 36),
			Paper = Color3.fromRGB(226, 212, 182),      -- field-journal paper (Codex, notes)
			PaperDark = Color3.fromRGB(184, 166, 130),
			Ink = Color3.fromRGB(42, 33, 26),           -- text on paper
			Shadow = Color3.fromRGB(0, 0, 0),
			-- The Secret rarity's own colour is near-black, which vanishes on
			-- dark panels; UI text and tags use this instead.
			SecretText = Color3.fromRGB(214, 210, 232),
		},
		-- Roblox font family names (Font.fromName). Display is a horror
		-- face for big titles only (28px and up); Heading for buttons,
		-- labels and numbers; Notes is a typewriter for field-note flavour.
		Fonts = {
			Display = "Creepster",
			Heading = "Oswald",
			Body = "Oswald",
			Notes = "SpecialElite",
			Mono = "Inconsolata",
		},
		Corner = 6,            -- px, panels and buttons
		CornerSmall = 4,       -- px, cards, pills, bars
		Stroke = 2,            -- px, panel borders
		ButtonPressScale = 0.94,
		HoverTime = 0.12,      -- seconds, hover/press tweens
		Window = {
			OpenTime = 0.22,             -- seconds
			CloseTime = 0.14,
			OpenFromScale = 0.92,        -- windows grow from this to full size
			BackdropTransparency = 0.5,  -- 1 = no dimming
			HeaderHeight = 58,           -- px at reference size
			ScreenMargin = 14,           -- px kept clear around a window
		},
	},

	-- Where the HUD clusters sit (px at the reference height; the HUD
	-- scales with the screen). Shared by the HUD, the hotbar, the tutorial
	-- panel and the toasts so they never overlap:
	--   top centre   Base / Eggs travel buttons (in the top-bar row)
	--   top left     camp panel (protection, nests, lock), under the top bar
	--   left middle  side buttons (Store, Codex, Gifts, Spin, Rebirth, Invite, Settings)
	--   right middle Daily + quick-buy offers
	--   bottom centre buff chips, cash, then the tool hotbar at the very bottom
	-- The bottom corners stay clear for the phone thumbstick and jump button.
	-- Offsets scale with the HUD too (HudController lays out on a canvas in
	-- these units). Checked on a 749x368 phone (scale 0.7, 58 px top bar):
	-- camp panel 64-100 px from the top; side tiles (2 columns of 4) start
	-- under it at 104 and end 94 px above the bottom, clear of the
	-- thumbstick; the right cluster is centred (132-236), above the jump
	-- button; cash sits 55 px up, over a hotbar that tops out at <= 49.
	Layout = {
		EdgeMargin = 12,        -- px from the screen's left/right edges to HUD clusters
		TopGap = 8,             -- px between Roblox's top bar and the camp panel
		CampHeight = 52,        -- px, the camp panel's height (the side tiles start below it)
		TravelTop = 10,         -- px from the very top of the screen to the Base/Eggs buttons
		TravelHeight = 46,
		SideButtonSize = 56,    -- px HUD tiles (side tiles and Daily)
		SideButtonGap = 6,
		HotbarBottom = 10,      -- px from the bottom edge to the hotbar slots
		HotbarSlot = 56,
		CashBottom = 78,        -- px from the bottom edge to the bottom of the cash block (clears the hotbar)
	},

	-- Which screen draws over which (ScreenGui.DisplayOrder). Higher is on top.
	Layers = {
		Vhs = -1,          -- sighting found-footage overlay, under everything
		World = 0,         -- full-screen tints (Hunt vignette sits on its own layer below)
		Hud = 1,
		Tutorial = 2,
		Window = 5,        -- popup screens (one open at a time)
		HuntDread = 5,
		Sighting = 7,
		Steal = 8,
		Toast = 10,
		Celebration = 15,
		Reveal = 30,
		Flash = 31,
		Jumpscare = 40,
	},

	-- Custom-drawn ProximityPrompts and tool hotbar in the theme. Set false
	-- to fall back to Roblox's default look instantly.
	CustomPrompts = true,
	CustomHotbar = true,

	-- HUD tiles, cash block, buff chips, travel buttons, camp panel (HudController, PlotController).
	-- Sizes are px at the reference height (they scale with the screen).
	Hud = {
		SideColumns = 2,             -- side tiles grid (Store, Codex, Gifts, Spin, Rebirth, Invite, Settings)
		-- Cash block (bottom centre)
		CashTextSize = 34,
		CashIconSize = 30,
		CashRowHeight = 44,
		StatusTextSize = 15,         -- "Rebirth 2 · +20% cash" under the cash
		AddButtonSize = 40,          -- the "+" next to the cash (opens the Store)
		AddIconSize = 20,
		AddButtonVariant = "Cash",   -- UI.Button variant of the "+"
		CashPunchTime = 0.35,        -- seconds the cash takes to settle after its punch (size: Config.Feedback.CashPunchScale)
		-- Buff chips and the "PROGRESS NOT SAVING" warning, just above the cash
		ChipHeight = 26,
		ChipTextSize = 15,
		ChipIconSize = 18,
		ChipGap = 6,
		-- Base / Eggs travel buttons (top centre; height is Layout.TravelHeight)
		TravelWidth = 124,
		TravelGap = 8,
		TravelTextSize = 20,
		TravelVariant = "Secondary",
		-- Quick-buy offers (right middle): a tile with a Robux price strip
		OfferSize = 64,              -- tile width (and the height above the price strip)
		OfferPriceHeight = 22,
		OfferPriceTextSize = 13,
		-- Camp panel (top left; height is Layout.CampHeight)
		CampTextSize = 16,
		CampIconSize = 20,
		LockWidth = 150,             -- fits "RECHARGE 5:00"
		-- Refresh rates (seconds)
		TickInterval = 0.5,          -- buff countdowns, rebirth "!", offer prices
		CampTickInterval = 0.2,      -- doors, lock countdown, protection timer
	},

	-- Store, Upgrades and Rebirth screens (RobuxShopController, UpgradeShopController, RebirthController).
	-- Sizes are px at the reference screen height; windows shrink to fit phones.
	Shops = {
		Store = {
			Size = Vector2.new(780, 480),        -- window design size
			CardSize = Vector2.new(172, 236),    -- one item card (four fit in a row)
			CardGap = 10,
			BannerHeight = 96,                   -- wide one-item rows (Starter Pack, Defense)
			PriceButton = Vector2.new(140, 40),  -- Robux buy button (or its OWNED / SOON tag)
			PriceTextSize = 19,
			RefreshInterval = 0.5,               -- s; prices and owned passes re-read while open
			-- Sections, top to bottom. Kind: "Pass" (Config.GamePasses) or
			-- "Product" (Config.DevProducts). Style: "Cards" (a grid of cards)
			-- or "Banner" (one wide row per item).
			Sections = {
				{ Title = "Boosts", Icon = "Potion", Kind = "Product", Style = "Cards",
					Keys = { "LuckPotion", "HatchBoost", "InstantHatch" } },
				{ Title = "Game Passes", Icon = "Gamepass", Kind = "Pass", Style = "Cards",
					Keys = Config.GamePassOrder },
				{ Title = "Cash", Icon = "Cash", Kind = "Product", Style = "Cards",
					Keys = { "CashSmall", "CashMedium", "CashLarge" } },
				{ Title = "Starter Pack", Icon = "GiftBox", Kind = "Product", Style = "Banner",
					Keys = { "EggBundle" } },
				{ Title = "Defense", Icon = "Shield", Kind = "Product", Style = "Banner",
					Keys = { "EmergencyLock" } },
			},
			-- Chat tag in front of a VIP pass owner's name, on every client.
			VipChatTag = "[VIP]",
			VipChatColor = Color3.fromRGB(255, 200, 60),
		},
		Upgrades = {
			Size = Vector2.new(660, 470),        -- window design size
			RowHeight = 68,
			RowGap = 8,
			BuyButton = Vector2.new(150, 44),
			PunchScale = 1.25,                   -- a row's icon pops to this when a level is bought
			PunchTime = 0.3,                     -- s
		},
		Rebirth = {
			Size = Vector2.new(720, 500),        -- window design size
			BarTime = 0.35,                      -- s; the cash bar slides to its new fill
			ColumnHeight = 190,                  -- the lose / keep / gain columns
			ButtonSize = Vector2.new(260, 50),
			ConfirmSize = Vector2.new(460, 236), -- the "are you sure?" box over the screen
			ConfirmDim = 0.3,                    -- transparency of the dimming behind it
			ConfirmPopTime = 0.18,               -- s
			ConfirmTitle = "Rebirth?",
			ColumnTitles = { Lose = "You lose", Keep = "You keep", Gain = "You gain" },
			-- "You lose" lines, one per entry of Config.Rebirth.Resets.
			-- Cash's %s is Config.Rebirth.StartingCash.
			Lose = {
				Cash = { Text = "Cash (restart at $%s)", Icon = "Cash" },
				Nests = { Text = "Eggs and cryptids", Icon = "Egg" },
				Upgrades = { Text = "Upgrades", Icon = "Upgrade" },
			},
			-- "You keep" lines (see Config.Rebirth: what a rebirth doesn't reset).
			Keep = {
				{ Text = "Codex entries", Icon = "Book" },
				{ Text = "Game passes", Icon = "Gamepass" },
				{ Text = "Active potions", Icon = "Potion" },
				{ Text = "Rebirth bonuses", Icon = "Rebirth" },
			},
			-- "You gain" line for the egg the next rebirth unlocks (%s = egg name).
			UnlockText = "Unlocks the %s",
		},
	},

	-- Codex screen, field camera viewfinder, new-entry polaroid (CodexController).
	-- Sizes are px at the reference screen height; the window and overlays
	-- shrink to fit phones. (Feature tunables — photo lighting, cards per
	-- row, timings, blurbs — stay in Config.Codex.)
	Codex = {
		-- The Codex window. Its width follows from the cards: a filter
		-- column, then Config.Codex.CardsPerRow cards of CardSize.
		WindowHeight = 500,
		TabSize = Vector2.new(156, 44),        -- one rarity filter tab (left column)
		TabGap = 5,
		ColumnGap = 12,                        -- between the filter tabs and the cards
		TopRowHeight = 40,                     -- the DISCOVERED bar and the search box
		SearchWidth = 240,
		CardSize = Vector2.new(112, 152),      -- one evidence-photo card
		CardGap = 10,
		CardPhotoMargin = 6,                   -- paper showing round a card's photo
		UnknownPaperDim = 0.35,                -- undiscovered cards' paper is this much darker (0..1)
		ExhibitFormat = "EXHIBIT %02d",        -- case number under each photo (%d = Config order)
		EmptyText = "No cryptids match that search.",
		-- A cryptid's file (tap a card): big polaroid + journal page.
		FilePolaroidSize = Vector2.new(236, 292),
		BackButtonSize = Vector2.new(130, 44),
		-- The Secret's photo flickers through these tints (Lit = discovered).
		GlitchLit = { Color3.fromRGB(255, 255, 255), Color3.fromRGB(255, 70, 70), Color3.fromRGB(150, 150, 160) },
		GlitchDark = { Color3.fromRGB(0, 0, 0), Color3.fromRGB(45, 0, 0), Color3.fromRGB(28, 28, 32) },

		-- Celebrations (layer Config.UI.Layers.Celebration).
		PolaroidSize = Vector2.new(220, 270),  -- the "NEW CODEX ENTRY" polaroid
		PolaroidY = 0.62,                      -- its centre, as a fraction of the screen height
		                                       -- (low enough to clear the page banner on a phone)
		PolaroidInTime = 0.55,                 -- s, slide in (out: SlideOutTime)
		PageBannerSize = Vector2.new(560, 56), -- "<Rarity> page complete!" banner
		PageBannerTop = 60,                    -- px from the top of the screen
		PageBannerInTime = 0.45,               -- s
		PageBannerDelay = 0.6,                 -- s after its polaroid starts
		SlideOutTime = 0.35,                   -- s
		RevealWaitMax = 10,                    -- s; longest wait for a hatch reveal to finish first

		-- Field Camera viewfinder (layer World, under the HUD) and shutter
		-- flash (layer Flash, over everything).
		Viewfinder = {
			EdgeShade = 0.45,                    -- darkened screen edges (1 = none)
			EdgeDepth = Vector2.new(0.12, 0.18), -- how far they reach in (fraction of width / height)
			FrameInset = Vector2.new(0.07, 0.1), -- corner brackets, fraction of the screen from each edge
			BracketSize = 48,
			BracketThickness = 5,
			InfoOffset = 30,                     -- px from the screen centre down to the target name
			HighlightFill = 0.85,                -- fill transparency of the aimed-at cryptid
		},
		FlashColor = Color3.fromRGB(255, 255, 255),
		FlashStart = 0.05,                     -- flash transparency at the shutter (fades to 1)
	},

	-- Daily Rewards, Spin Wheel, Playtime Gifts, Offline Earnings and Settings screens.
	-- (Reward data and the wheel's spin timing live in Config.Retention.)
	-- Sizes are px at the reference screen height; windows shrink to fit phones.
	Retention = {
		Daily = {
			WindowSize = Vector2.new(720, 400),
			CardWidth = 82,          -- days 1-6
			BigCardWidth = 140,      -- day 7, the big one
			CardHeight = 170,
			CardGap = 8,
			PulseScale = 1.05,       -- today's card gently grows to this and back
			PulseTime = 0.6,         -- seconds per half-breath
			-- The join-time auto-open waits for a clear screen (offline popup
			-- dealt with, nothing else open) for at most this many seconds.
			AutoOpenGiveUp = 120,
		},
		Spin = {
			WindowSize = Vector2.new(680, 430),
			WheelRadius = 150,
			RimWidth = 6,
			HubRadius = 26,
			SpokeWidth = 5,          -- dark dividers between prizes
			PointerSize = 28,
			-- Each prize segment is painted as a fan of thin bars this many
			-- degrees apart (smaller = smoother edges, more instances).
			FanStep = 2.5,
			-- Segment colours, clockwise from prize 1 (Theme colour names);
			-- Text is the colour of the prize label on that segment.
			Segments = {
				{ Fill = "Ember", Text = "TextOnAccent" },
				{ Fill = "MoonDeep", Text = "Text" },
				{ Fill = "Moss", Text = "TextOnAccent" },
				{ Fill = "EmberDeep", Text = "Text" },
				{ Fill = "Moon", Text = "TextOnAccent" },
				{ Fill = "Blood", Text = "Text" },
			},
			WinPunchScale = 1.15,    -- the "You won" line pops to this and settles
		},
		Gifts = {
			WindowSize = Vector2.new(560, 380),
			BarMinFill = 0.03,       -- a sliver of the bar always shows while a gift is counting
		},
		Offline = {
			WindowSize = Vector2.new(580, 320),
		},
		Settings = {
			WindowSize = Vector2.new(460, 280),
			OnVariant = "Moon",      -- UI.Button variant of a switch that is ON
			OffVariant = "Secondary",
		},
	},

	-- Toasts, hatch reveal, cash popups and celebrations (NotificationController, FeedbackController).
	-- Colours here are names from Theme.Colors above. Timings and amounts
	-- live in Config.Feedback.
	Toasts = {
		-- Toast cards: charred field-kit cards whose edge strip, border and
		-- icon show the kind. Announcements are bigger and take the rarity's colour.
		Top = 52,                 -- px under Roblox's top bar to the first toast when no banner is up
		BannerGap = 8,            -- px kept between the lowest banner / tutorial panel and the toasts
		Gap = 6,                  -- px between toasts
		Height = 36,              -- px, smallest card height (one line)
		AnnounceHeight = 44,
		TextSize = 18,            -- Heading font
		AnnounceTextSize = 22,
		IconSize = 22,
		AnnounceIconSize = 28,
		MaxWidth = 460,           -- px of text before a long message wraps onto another line
		AnnounceMaxWidth = 560,
		SlideFrom = 14,           -- px a card drops in from
		FadeOutTime = 0.3,        -- seconds
		CardTransparency = 0.06,
		KindColors = { Info = "Moon", Success = "Moss", Warning = "Ember", Error = "Blood", Announce = "EmberBright" },
		AnnounceTint = 0.25,      -- how much of the rarity colour soaks into an announcement card (0..1)

		-- Hatch reveal. The RARITY stamp and the cryptid's name use the
		-- Display font, so keep those two at 28 or more.
		RevealBackdrop = 0.35,    -- transparency of the dimming behind the reveal (1 = none)
		RevealStampTextSize = 60,
		RevealNameTextSize = 42,
		RevealIncomeTextSize = 28,
		RevealEggTextSize = 20,
		RevealPlateTransparency = 0.12, -- the charred plate under the name, income and egg
		RevealAmbient = Color3.fromRGB(150, 150, 165), -- light on the cryptid in the reveal
		SkipTextColor = "TextDim",
		ConfettiColors = { "EmberBright", "Ember", "Text", "MoonBright", "MossBright", "BloodBright" },

		-- Cash popups ("+$X" over the cryptid; big = Config.Feedback.CashBigAmount and up)
		CashPopupSize = Vector2.new(160, 46),
		CashPopupBigSize = Vector2.new(220, 60),
		CashPopupColor = "MossBright",
		CashPopupBigColor = "EmberBright",

		-- Rebirth celebration (flash, confetti, "REBIRTH N!" stamp)
		RebirthFlashColor = "Text",
		RebirthStampColor = "EmberBright",
		RebirthStampTextSize = 76,
		RebirthStampTime = 2,     -- seconds the stamp stays before it fades
	},

	-- Tutorial panel and steal alerts (TutorialController, StealController).
	Tutorial = {
	},

	-- Sighting and Hunt banners, markers and overlays (SightingController, HuntController).
	Banners = {
	},

	-- Nest labels, belt egg labels and in-world signs (NestVisualsController, EggBeltController, server signs).
	Labels = {
	},

	-- Themed "hold E" ProximityPrompts (PromptController).
	Prompts = {
	},

	-- Themed tool hotbar (HotbarController).
	Hotbar = {
	},
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

--- True if luck boosts this rarity (Config.Luck.BoostedRarities).
function Config.IsBoostedRarity(rarity: string): boolean
	return Config.Luck.BoostedRarities[rarity] == true
end

--- The multiplier luck applies to one rarity's weight.
--- Unboosted rarities (Common, Uncommon) always return 1.
--- luckPercent: additive percent, e.g. 25
function Config.GetBoostMultiplier(rarity: string, luckPercent: number?): number
	if not Config.IsBoostedRarity(rarity) then
		return 1
	end
	local luck = math.clamp(luckPercent or 0, 0, Config.Luck.MaxPercent)
	return 1 + luck / 100
end

--- Builds the normalized rarity chance table for an egg at a given luck.
--- Returns { [rarity] = probability } summing to 1.
function Config.GetRarityChances(eggId: string, luckPercent: number?): { [string]: number }
	local egg = Config.Eggs[eggId]
	assert(egg, "Unknown egg id: " .. tostring(eggId))

	local weighted: { [string]: number } = {}
	local total = 0

	for _, rarity in ipairs(Config.RarityOrder) do
		local w = (egg.Weights[rarity] or 0) * Config.GetBoostMultiplier(rarity, luckPercent)
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
