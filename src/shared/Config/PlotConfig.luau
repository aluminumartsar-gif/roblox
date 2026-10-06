local PlotConfig = {
	PLOT_FOLDER_NAME = "Bases",
	LEGACY_PLOT_FOLDER_NAME = "Plots",
	PLOT_COUNT = 6,
	PLOT_MODEL_NAME = "Base",
	PLOT_NAME_PREFIX = "Base",
	LEGACY_PLOT_NAME_PREFIX = "Plot",
	PAD_GROUP_NAME = "PadGroup",
	PAD_GROUP_NAME_PREFIX = "PadGroup",
	FLOOR_NAME_PREFIX = "Floor",
	SPAWN_LOCATION_NAME = "SpawnLocation",
	PAD_NAME = "Pad",
	COLLECT_PAD_NAME = "Collect",
	DISPLAY_POINT_NAME = "DisplayPoint",
	PLACED_VISUAL_NAME = "PlacedBrainrot",
	PLACARD_NAME = "BrainrotPlacard",
	PLACARD_MAX_DISTANCE = 24,
	UPGRADE_PAD_NAME = "UpgradePad",
	UPGRADE_PROMPT_NAME = "PlotUpgradePrompt",
	ENTRANCE_POST_LEFT_NAME = "EntrancePost1",
	ENTRANCE_POST_RIGHT_NAME = "EntrancePost2",
	BASE_PLACARD_NAME = "BaseOwnerPlacard",
	-- Positive forward = anchor sits OUTSIDE the entrance on the grass,
	-- alongside the SpawnLocation/EntranceWalkway (which are ~5 studs
	-- outward from the entrance midpoint and ~10 studs deep).
	-- Positive side = anchor sits on the EntrancePost2 side of the walkway,
	-- pushed just past the walkway's right edge so the sign reads as standing
	-- next to the spawn pad rather than out alone in the grass.
	-- Sign post stays at entrance-post ground level so it never clips the
	-- raised wooden base floor.
	BASE_PLACARD_FORWARD_OFFSET = 5,
	BASE_PLACARD_SIDE_OFFSET = 6.5,
	BASE_PLACARD_MAX_DISTANCE = 200,
	UPGRADE_PROMPT_HOLD_DURATION = 0.6,
	UPGRADE_PROMPT_MAX_DISTANCE = 10,
	UPGRADE_PROMPT_ACTION_TEXT = "Upgrade Floor",
	LOCKED_PAD_LABEL_NAME = "LockedSlotLabel",
	LOCKED_PAD_TEXT = "Locked",
	COLLECT_DEBOUNCE_SECONDS = 1,
	PLACE_DEBOUNCE_SECONDS = 1,
	UPGRADE_DEBOUNCE_SECONDS = 1.5,
	PLOT_OWNER_ATTRIBUTE = "PlotOwnerUserId",
	PLOT_TIER_ATTRIBUTE = "PlotTier",
	PLACE_PROMPT_NAME = "PlotPlacePrompt",
	PLACE_PROMPT_HOLD_DURATION = 0.5,
	PLACE_PROMPT_MAX_DISTANCE = 10,
	PLACE_PROMPT_ACTION_TEXT = "Place Brainrot",
	PICKUP_PROMPT_ACTION_TEXT = "Pick Up Brainrot",
	PROMPT_KEY_CODE = Enum.KeyCode.E,
}

PlotConfig.MAX_TIER = 4
PlotConfig.STARTING_TIER = 1

-- Cost in coins for each successive pad slot within a floor tier.
-- Index 1 is always 0 (the first pad on each floor is free to use once
-- that floor is unlocked). Index N is the cost to unlock the Nth pad on
-- that floor. Costs increase steeply so players spend progressively more
-- to fill each floor.
PlotConfig.PAD_SLOT_COSTS_BY_TIER = {
	[1] = { 0, 100,    300,    900,    2_700,    8_100   },
	[2] = { 0, 5_000,  15_000, 45_000, 135_000,  405_000 },
	[3] = { 0, 100_000, 300_000, 900_000, 2_700_000, 8_100_000 },
	[4] = { 0, 5_000_000, 15_000_000, 45_000_000, 135_000_000, 405_000_000 },
}

-- Tier ladder. Each entry describes one physical floor that gets revealed
-- when the player upgrades to that tier. `slotsOnThisFloor` is the number of
-- NEW PadGroups added by the floor; the cumulative slot count for a tier is
-- the sum of all entries up to and including that tier (see
-- PlotConfig.getCumulativeSlots).
PlotConfig.TIERS = {
	[1] = {
		displayName = "Floor 1",
		floorName = "Floor1",
		rebirths = 0,
		cost = 0,
		slotsOnThisFloor = 6,
		accentColor = Color3.fromRGB(80, 220, 255),
	},
	[2] = {
		displayName = "Floor 2",
		floorName = "Floor2",
		rebirths = 1,
		cost = 5_000,
		slotsOnThisFloor = 6,
		accentColor = Color3.fromRGB(190, 110, 255),
	},
	[3] = {
		displayName = "Floor 3",
		floorName = "Floor3",
		rebirths = 3,
		cost = 100_000,
		slotsOnThisFloor = 6,
		accentColor = Color3.fromRGB(255, 90, 200),
	},
	[4] = {
		displayName = "Rooftop",
		floorName = "Floor4",
		rebirths = 7,
		cost = 5_000_000,
		slotsOnThisFloor = 6,
		accentColor = Color3.fromRGB(255, 215, 110),
	},
}

local cumulativeSlotCache: { number } = {}
do
	local running = 0
	for tier = 1, PlotConfig.MAX_TIER do
		running += PlotConfig.TIERS[tier].slotsOnThisFloor
		cumulativeSlotCache[tier] = running
	end
end

PlotConfig.SLOT_COUNT = cumulativeSlotCache[PlotConfig.MAX_TIER]

function PlotConfig.getPlotName(index: number)
	return ("%s%d"):format(PlotConfig.PLOT_NAME_PREFIX, index)
end

function PlotConfig.getLegacyPlotName(index: number)
	return ("%s%d"):format(PlotConfig.LEGACY_PLOT_NAME_PREFIX, index)
end

function PlotConfig.getPadGroupName(index: number)
	return ("%s%d"):format(PlotConfig.PAD_GROUP_NAME_PREFIX, index)
end

function PlotConfig.getFloorName(tierIndex: number)
	local tier = PlotConfig.TIERS[tierIndex]
	if tier and tier.floorName then
		return tier.floorName
	end

	return ("%s%d"):format(PlotConfig.FLOOR_NAME_PREFIX, tierIndex)
end

function PlotConfig.clampTier(tier: number?)
	local resolved = tonumber(tier) or PlotConfig.STARTING_TIER
	if resolved < PlotConfig.STARTING_TIER then
		return PlotConfig.STARTING_TIER
	end
	if resolved > PlotConfig.MAX_TIER then
		return PlotConfig.MAX_TIER
	end

	return resolved
end

function PlotConfig.getTier(tier: number)
	return PlotConfig.TIERS[PlotConfig.clampTier(tier)]
end

function PlotConfig.getCumulativeSlots(tier: number)
	return cumulativeSlotCache[PlotConfig.clampTier(tier)] or 0
end

function PlotConfig.getMaxSlots()
	return cumulativeSlotCache[PlotConfig.MAX_TIER] or 0
end

function PlotConfig.getNextTier(tier: number)
	local resolved = PlotConfig.clampTier(tier)
	if resolved >= PlotConfig.MAX_TIER then
		return nil
	end

	return resolved + 1, PlotConfig.TIERS[resolved + 1]
end

-- Returns the slot range owned by a given tier as [firstSlot, lastSlot]
-- (1-indexed, cumulative). Useful when binding pads on a per-floor basis.
function PlotConfig.getSlotRange(tier: number)
	local resolved = PlotConfig.clampTier(tier)
	local lastSlot = cumulativeSlotCache[resolved] or 0
	local previousLastSlot = if resolved > 1 then (cumulativeSlotCache[resolved - 1] or 0) else 0
	return previousLastSlot + 1, lastSlot
end

-- Returns the coin cost to unlock a pad given its global slot index.
-- The first pad on each floor is always free (cost 0). Subsequent pads on
-- the same floor cost progressively more. Returns 0 for out-of-range slots.
function PlotConfig.getPadUnlockCost(globalSlotIndex: number): number
	for tier = 1, PlotConfig.MAX_TIER do
		local firstSlot, lastSlot = PlotConfig.getSlotRange(tier)
		if globalSlotIndex >= firstSlot and globalSlotIndex <= lastSlot then
			local positionOnFloor = globalSlotIndex - firstSlot + 1
			local tierCosts = PlotConfig.PAD_SLOT_COSTS_BY_TIER[tier]
			if tierCosts then
				return tierCosts[positionOnFloor] or 0
			end
			return 0
		end
	end
	return 0
end

return PlotConfig
