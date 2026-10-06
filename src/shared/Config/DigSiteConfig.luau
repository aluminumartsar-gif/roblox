local DigSiteConfig = {
	MODEL_NAME = "DigSite",
	FLOOR_NAME = "Floor",
	HOTSPOT_SPAWNS_NAME = "HotspotSpawns",

	-- Ground spots: small, diegetic surface tells the player can stumble across.
	-- Replaces the old single "DIG HERE!" billboard hotspot with a quiet pool of
	-- subtle markers in three rarity flavours.
	ACTIVE_SPOTS_FOLDER_NAME = "ActiveSpots",
	GROUND_SPOT_MARKER_NAME = "GroundSpot",
	DEFAULT_GROUND_SPOT_TIER = "Common",

	DIG_SURFACE_PADDING = 2,
	DIG_SURFACE_HEIGHT_TOLERANCE = 8,

	GROUND_SPOT_RADIUS = 4,
	GROUND_SPOT_MIN_REPEAT_DISTANCE = 10,
	GROUND_SPOT_POSITION_ATTEMPTS = 12,
	GROUND_SPOT_LIFETIME = 45,
	GROUND_SPOT_SPAWN_INTERVAL = 6,
	GROUND_SPOT_MAX_ACTIVE = 8,
	GROUND_SPOT_PROXIMITY_SOUND_RANGE = 8,
	GROUND_SPOT_FOOTPRINT = 3,
	GROUND_SPOT_POSITION_ATTRIBUTE = "Position",
	GROUND_SPOT_LUCK_ATTRIBUTE = "LuckMultiplier",
	GROUND_SPOT_TIER_ATTRIBUTE = "Tier",
	GROUND_SPOT_BILLBOARD_RANGE = 35,
	-- World-space (studs) size of the floating tier billboard. Stud-sized
	-- so it shrinks with distance like any other 3D prop. Per-tier
	-- `billboardSize` overrides scale this up for the rare tiers so they
	-- stay readable at their longer `billboardMaxDistance` view ranges.
	GROUND_SPOT_BILLBOARD_DEFAULT_SIZE = Vector2.new(2.6, 1.9),

	-- Ten tiers from Common → Cosmic. Weights sum to 100.
	-- Each tier has a distinct visual style so players can identify value
	-- at a glance, and a floating billboard always shows the exact multiplier.
	-- Mythic-and-above tiers use AlwaysOnTop highlights so they read across
	-- the whole dig site; sub-Mythic tiers use Occluded so they only pop
	-- when the player has line-of-sight, keeping the lot from looking
	-- visually busy with low-stakes spots.
	GROUND_SPOT_TIERS = {
		Common = {
			style = "Mound",
			luckMultiplier = 1.5,
			weight = 42,
			accentColor = Color3.fromRGB(180, 148, 100),
			highlightFillColor = Color3.fromRGB(220, 190, 140),
			highlightOutlineColor = Color3.fromRGB(180, 148, 100),
			highlightFillTransparency = 0.9,
			highlightOutlineTransparency = 0.4,
			highlightAlwaysOnTop = false,
		},
		Uncommon = {
			style = "MossPatch",
			luckMultiplier = 2,
			weight = 24,
			accentColor = Color3.fromRGB(140, 200, 110),
			highlightFillColor = Color3.fromRGB(170, 220, 130),
			highlightOutlineColor = Color3.fromRGB(140, 200, 110),
			highlightFillTransparency = 0.85,
			highlightOutlineTransparency = 0.3,
			highlightAlwaysOnTop = false,
		},
		Rare = {
			style = "GemShard",
			luckMultiplier = 3,
			weight = 17,
			accentColor = Color3.fromRGB(80, 160, 255),
			highlightFillColor = Color3.fromRGB(140, 200, 255),
			highlightOutlineColor = Color3.fromRGB(80, 160, 255),
			highlightFillTransparency = 0.8,
			highlightOutlineTransparency = 0.2,
			highlightAlwaysOnTop = false,
		},
		Epic = {
			style = "CrystalGeode",
			luckMultiplier = 5,
			weight = 9,
			accentColor = Color3.fromRGB(200, 100, 255),
			highlightFillColor = Color3.fromRGB(220, 140, 255),
			highlightOutlineColor = Color3.fromRGB(200, 100, 255),
			highlightFillTransparency = 0.75,
			highlightOutlineTransparency = 0.15,
			highlightAlwaysOnTop = false,
		},
		Legendary = {
			style = "MagmaVent",
			luckMultiplier = 8,
			weight = 4,
			accentColor = Color3.fromRGB(255, 140, 40),
			highlightFillColor = Color3.fromRGB(255, 180, 80),
			highlightOutlineColor = Color3.fromRGB(255, 100, 20),
			highlightFillTransparency = 0.65,
			highlightOutlineTransparency = 0.05,
			highlightAlwaysOnTop = true,
			billboardMaxDistance = 60,
			billboardSize = Vector2.new(3.4, 2.5),
		},
		Mythic = {
			style = "VoidRift",
			luckMultiplier = 15,
			weight = 3,
			accentColor = Color3.fromRGB(255, 70, 70),
			highlightFillColor = Color3.fromRGB(255, 100, 100),
			highlightOutlineColor = Color3.fromRGB(255, 50, 50),
			highlightFillTransparency = 0.55,
			highlightOutlineTransparency = 0,
			highlightAlwaysOnTop = true,
			billboardMaxDistance = 70,
			billboardSize = Vector2.new(4.0, 2.9),
		},
		Celestial = {
			style = "StarFragment",
			luckMultiplier = 30,
			weight = 0.7,
			accentColor = Color3.fromRGB(180, 220, 255),
			highlightFillColor = Color3.fromRGB(220, 240, 255),
			highlightOutlineColor = Color3.fromRGB(180, 220, 255),
			highlightFillTransparency = 0.45,
			highlightOutlineTransparency = 0,
			highlightAlwaysOnTop = true,
			billboardMaxDistance = 80,
			billboardSize = Vector2.new(4.6, 3.3),
		},
		Divine = {
			style = "HeavensMark",
			luckMultiplier = 70,
			weight = 0.2,
			accentColor = Color3.fromRGB(255, 225, 120),
			highlightFillColor = Color3.fromRGB(255, 240, 180),
			highlightOutlineColor = Color3.fromRGB(255, 215, 90),
			highlightFillTransparency = 0.4,
			highlightOutlineTransparency = 0,
			highlightAlwaysOnTop = true,
			billboardMaxDistance = 120,
			billboardSize = Vector2.new(6.4, 4.6),
		},
		Eldritch = {
			style = "CosmicEye",
			luckMultiplier = 130,
			weight = 0.07,
			accentColor = Color3.fromRGB(120, 220, 200),
			highlightFillColor = Color3.fromRGB(140, 240, 220),
			highlightOutlineColor = Color3.fromRGB(120, 220, 200),
			highlightFillTransparency = 0.35,
			highlightOutlineTransparency = 0,
			highlightAlwaysOnTop = true,
			animatedHighlight = true,
			billboardMaxDistance = 180,
			billboardSize = Vector2.new(9.0, 6.4),
		},
		Cosmic = {
			style = "GalaxyWhirl",
			luckMultiplier = 250,
			weight = 0.03,
			accentColor = Color3.fromRGB(200, 140, 255),
			highlightFillColor = Color3.fromRGB(255, 200, 255),
			highlightOutlineColor = Color3.fromRGB(220, 160, 255),
			highlightFillTransparency = 0.3,
			highlightOutlineTransparency = 0,
			highlightAlwaysOnTop = true,
			animatedHighlight = true,
			billboardMaxDistance = 250,
			billboardSize = Vector2.new(13.0, 9.4),
		},
	},

	-- Dug crater visuals. The dirt patch left behind after a dig is rendered
	-- as a 3D recessed pit via DigHoleBuilder, not flat decals.
	DUG_SPOTS_FOLDER_NAME = "DugSpots",
	DUG_SPOT_MARKER_NAME = "DugSpot",
	DUG_SPOT_BLOCK_RADIUS = 6,
	DUG_SPOT_MARKER_SIZE = 4.2,
	DUG_SPOT_MARKER_HEIGHT = 0.08,
	-- Per-spot lifetime (in seconds) before a dug hole is auto-cleared. Each
	-- hole expires on its own timeline rather than a synchronized site-wide
	-- reset so newly dug spots always get the full window.
	DUG_SPOT_LIFETIME = 120,
	-- How often the cleanup loop sweeps the dug-spot list looking for ones
	-- past their per-spot expiry. Cheap; just bounds how stale a finished
	-- hole can sit before its visuals tear down.
	DUG_SPOT_CLEANUP_INTERVAL = 5,

	-- Tunables for the layered 3D pit illusion (DigHoleBuilder). Both the
	-- during-dig hole (client) and the persistent dug spot (server) read
	-- from these so the visuals stay consistent.
	DUG_HOLE = {
		RIM_CHUNK_COUNT = 12,
		WALL_SEGMENT_COUNT = 7,
		INNER_LAYER_COUNT = 4,
		BED_STONE_COUNT = 3,
		MAX_DEPTH_VISUAL = 1.0,
		-- Extra freshly-thrown rim clods the server piles on top of the
		-- persistent dug spot so it still reads as "just dug" the moment
		-- the brainrot pops out.
		PERSISTENT_EXTRA_RIM_DEBRIS = 8,
		-- Risk-phase ("extra hits") growth: each extra hit past
		-- DIG_REQUIRED_HITS keeps widening and deepening the pit on a
		-- soft-saturating curve so the player visibly sees the reward of
		-- their risk. growth = extraHits / (extraHits + SATURATION) -> 0..1
		-- Both the during-dig hole and the persistent dug spot apply the
		-- same curve so the handoff at commit/break has no visible pop.
		EXTRA_GROWTH_MAX_RADIUS = 1.2,
		EXTRA_GROWTH_MAX_DEPTH = 0.5,
		EXTRA_GROWTH_SATURATION = 4,
		EXTRA_GROWTH_MAX_RIM_BONUS = 6,
		EXTRA_GROWTH_MAX_STONE_BONUS = 3,
	},

}

return DigSiteConfig
