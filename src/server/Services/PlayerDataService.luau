local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local EconomyConfig = require(ConfigFolder:WaitForChild("EconomyConfig"))
local PlotConfig = require(ConfigFolder:WaitForChild("PlotConfig"))
local ShovelConfig = require(ConfigFolder:WaitForChild("ShovelConfig"))
local ShovelUpgradeConfig = require(ConfigFolder:WaitForChild("ShovelUpgradeConfig"))
local VariantConfig = require(ConfigFolder:WaitForChild("VariantConfig"))

local HOTBAR_SIZE = EconomyConfig.HOTBAR_SIZE
local BACKPACK_SIZE = EconomyConfig.BACKPACK_SIZE

-- Increment this whenever the hotbar schema changes in a way that requires
-- clearing saved hotbar data on next login (e.g. a bad migration rollout).
local HOTBAR_VERSION = 3
local FormatUtil = require(UtilFolder:WaitForChild("FormatUtil"))

local PlayerDataService = {}

local SAVE_DEBOUNCE = 4 -- seconds to wait before flushing a debounced save
local LOAD_RETRIES = 3  -- max GetAsync attempts before giving up
local LOAD_RETRY_WAIT = 2 -- seconds between retry attempts
local AUTOSAVE_INTERVAL = 60 -- seconds between periodic saves

local store = nil
local datastoreAvailable = false
local dataByUserId = {}
local loadedByUserId = {}
-- Set when ALL GetAsync retries fail; prevents overwriting real data with defaults on disconnect.
local loadFailedByUserId = {}
-- task thread ids for pending debounced saves, keyed by UserId.
local pendingSaveByUserId = {}

local function getStore()
	if store ~= nil then
		return store
	end

	local success, result = pcall(function()
		return DataStoreService:GetDataStore(EconomyConfig.DATASTORE_NAME)
	end)

	if success then
		store = result
		datastoreAvailable = true
	else
		datastoreAvailable = false
		warn(("[Data] DataStore unavailable; using session-only data: %s"):format(tostring(result)))
	end

	return store
end

local function getDefaultData()
	return {
		version = EconomyConfig.DATA_VERSION,
		money = EconomyConfig.STARTING_MONEY,
		rebirths = EconomyConfig.STARTING_REBIRTHS,
		baseTier = PlotConfig.STARTING_TIER,
		shovel = ShovelConfig.getDefaultId(),
		-- Legacy bag kept in schema so existing player saves load cleanly.
		-- New brainrots go to `hotbar` only. Rebirth requirements consume hotbar.
		inventory = {},
		hotbar = {},
		backpack = {},
		placedBrainrots = {},
		foundBrainrots = {},
		foundBrainrotVariants = {},
		-- Keys are tostring(slotIndex), value is true when the pad is unlocked.
		-- The first pad on each floor is auto-unlocked when that floor is revealed.
		unlockedPads = {},
		oneTimeGrants = {},
		-- Shovel station upgrades: PERCENT_PER_LEVEL% per track level; walk resets on rebirth.
		shovelUpgrades = {
			luck = 0,
			greenBar = 0,
			walkSpeed = 0,
		},
	}
end

local function markVariantFound(data, brainrotId: string, variantId: string)
	local bucket = data.foundBrainrotVariants[brainrotId]
	if type(bucket) ~= "table" then
		bucket = {}
		data.foundBrainrotVariants[brainrotId] = bucket
	end
	bucket[variantId] = true
end

local function migrateVariantFields(data)
	for _, item in data.inventory do
		if type(item) == "table" and type(item.id) == "string" then
			if not VariantConfig.isKnown(item.variantId) then
				item.variantId = VariantConfig.NORMAL_ID
			end
		end
	end

	for _, placement in data.placedBrainrots do
		if type(placement) == "table" and type(placement.id) == "string" then
			if not VariantConfig.isKnown(placement.variantId) then
				placement.variantId = VariantConfig.NORMAL_ID
			end
		end
	end
end

local function markExistingBrainrotsFound(data)
	for _, item in data.inventory do
		if type(item) == "table" and type(item.id) == "string" then
			data.foundBrainrots[item.id] = true
			markVariantFound(data, item.id, item.variantId or VariantConfig.NORMAL_ID)
		end
	end

	for _, placement in data.placedBrainrots do
		if type(placement) == "table" and type(placement.id) == "string" then
			data.foundBrainrots[placement.id] = true
			markVariantFound(data, placement.id, placement.variantId or VariantConfig.NORMAL_ID)
		end
	end
end

local function normalizeData(rawData)
	local data = if type(rawData) == "table" then rawData else getDefaultData()

	data.version = EconomyConfig.DATA_VERSION
	data.money = tonumber(data.money) or EconomyConfig.STARTING_MONEY
	data.rebirths = tonumber(data.rebirths) or EconomyConfig.STARTING_REBIRTHS
	data.oneTimeGrants = if type(data.oneTimeGrants) == "table" then data.oneTimeGrants else {}
	data.baseTier = PlotConfig.clampTier(tonumber(data.baseTier) or PlotConfig.STARTING_TIER)
	data.shovel = if ShovelConfig.isKnown(data.shovel) then data.shovel else ShovelConfig.getDefaultId()
	data.inventory = if type(data.inventory) == "table" then data.inventory else {}
	data.placedBrainrots = if type(data.placedBrainrots) == "table" then data.placedBrainrots else {}
	data.foundBrainrots = if type(data.foundBrainrots) == "table" then data.foundBrainrots else {}
	data.foundBrainrotVariants = if type(data.foundBrainrotVariants) == "table" then data.foundBrainrotVariants else {}
	data.unlockedPads = if type(data.unlockedPads) == "table" then data.unlockedPads else {}

	-- Hotbar: versioned reset so any previously bad migration (v1 moved old
	-- inventory items into hotbar incorrectly) is cleared on login.
	-- Only preserves the hotbar if it was saved with the current version.
	if type(data.hotbar) ~= "table" or data.hotbarVersion ~= HOTBAR_VERSION then
		data.hotbar = {}
		data.hotbarVersion = HOTBAR_VERSION
	end

	-- Clamp hotbar to max size in case of data corruption.
	while #data.hotbar > HOTBAR_SIZE do
		table.remove(data.hotbar)
	end

	-- Backpack: overflow storage beyond the 8-slot hotbar.
	data.backpack = if type(data.backpack) == "table" then data.backpack else {}
	while #data.backpack > BACKPACK_SIZE do
		table.remove(data.backpack)
	end

	-- Migration: any slot that already has a brainrot placed is implicitly
	-- unlocked so existing players don't lose access to their occupied pads.
	for slotKey in data.placedBrainrots do
		data.unlockedPads[slotKey] = true
	end
	-- Auto-unlock the first pad on each unlocked floor so new players can place
	-- immediately. The first pad on a floor has position 1 within that floor,
	-- which maps to the firstSlot of each tier's slot range.
	local autoUnlockedTier = PlotConfig.clampTier(data.baseTier)
	for tier = 1, autoUnlockedTier do
		local firstSlot = PlotConfig.getSlotRange(tier)
		data.unlockedPads[tostring(firstSlot)] = true
	end
	migrateVariantFields(data)
	markExistingBrainrotsFound(data)

	if type(data.shovelUpgrades) ~= "table" then
		data.shovelUpgrades = {
			luck = 0,
			greenBar = 0,
			walkSpeed = 0,
		}
	else
		data.shovelUpgrades.luck = ShovelUpgradeConfig.clampUnboundedLevel(data.shovelUpgrades.luck)
		data.shovelUpgrades.greenBar = ShovelUpgradeConfig.clampUnboundedLevel(data.shovelUpgrades.greenBar)
		data.shovelUpgrades.walkSpeed = ShovelUpgradeConfig.clampWalkSpeedLevel(data.shovelUpgrades.walkSpeed)
	end

	return data
end

local function getKey(player: Player)
	return ("player_%d"):format(player.UserId)
end

local function createLeaderstats(player: Player, data)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		leaderstats = Instance.new("Folder")
		leaderstats.Name = "leaderstats"
		leaderstats.Parent = player
	end

	local money = leaderstats:FindFirstChild("Money")
	if money and not money:IsA("StringValue") then
		money:Destroy()
		money = nil
	end
	if not money then
		money = Instance.new("StringValue")
		money.Name = "Money"
		money.Parent = leaderstats
	end
	money.Value = FormatUtil.compactNumber(data.money)

	local rebirths = leaderstats:FindFirstChild("Rebirths")
	if not rebirths then
		rebirths = Instance.new("IntValue")
		rebirths.Name = "Rebirths"
		rebirths.Parent = leaderstats
	end
	rebirths.Value = data.rebirths
end

local function updateLeaderstats(player: Player)
	local data = PlayerDataService.getData(player)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		createLeaderstats(player, data)
		return
	end

	local money = leaderstats:FindFirstChild("Money")
	if money and money:IsA("StringValue") then
		money.Value = FormatUtil.compactNumber(data.money)
	else
		createLeaderstats(player, data)
	end

	local rebirths = leaderstats:FindFirstChild("Rebirths")
	if rebirths then
		rebirths.Value = data.rebirths
	end
end

local function notifyLeaderboardsPush(player: Player)
	task.defer(function()
		local ok, mod = pcall(function()
			return require(script.Parent:WaitForChild("LeaderboardPodiumService"))
		end)
		if ok and mod and mod.pushScoresForPlayer then
			mod.pushScoresForPlayer(player)
		end
	end)
end

local function loadPlayer(player: Player)
	local dataStore = getStore()
	if not datastoreAvailable or not dataStore then
		local data = normalizeData(getDefaultData())
		dataByUserId[player.UserId] = data
		loadedByUserId[player.UserId] = true
		createLeaderstats(player, data)
		notifyLeaderboardsPush(player)
		return
	end

	local success, result
	for attempt = 1, LOAD_RETRIES do
		success, result = pcall(function()
			return dataStore:GetAsync(getKey(player))
		end)
		if success then
			break
		end
		warn(("[Data] Load attempt %d/%d failed for %s: %s"):format(attempt, LOAD_RETRIES, player.Name, tostring(result)))
		if attempt < LOAD_RETRIES then
			task.wait(LOAD_RETRY_WAIT)
			if not player.Parent then
				return
			end
		end
	end

	if not success then
		-- All retries failed. Give the player a usable session but flag this
		-- UserId so savePlayer will refuse to write, preventing default data
		-- from overwriting the real save that lives in the DataStore.
		warn(("[Data] All load attempts failed for %s; session is read-only to protect real data."):format(player.Name))
		loadFailedByUserId[player.UserId] = true
		local data = normalizeData(getDefaultData())
		dataByUserId[player.UserId] = data
		loadedByUserId[player.UserId] = true
		createLeaderstats(player, data)
		return
	end

	local data = normalizeData(result)
	dataByUserId[player.UserId] = data
	loadedByUserId[player.UserId] = true
	createLeaderstats(player, data)
	notifyLeaderboardsPush(player)
end

function PlayerDataService.getData(player: Player)
	local data = dataByUserId[player.UserId]
	if not data then
		data = getDefaultData()
		dataByUserId[player.UserId] = data
	end

	return data
end

function PlayerDataService.isLoaded(player: Player)
	return loadedByUserId[player.UserId] == true
end

function PlayerDataService.waitForData(player: Player, timeout: number?)
	local deadline = os.clock() + (timeout or 10)
	while player.Parent and not PlayerDataService.isLoaded(player) and os.clock() < deadline do
		task.wait()
	end

	return PlayerDataService.getData(player)
end

-- ─── hotbar ───────────────────────────────────────────────────────────────────

function PlayerDataService.getHotbar(player: Player)
	return PlayerDataService.getData(player).hotbar
end

function PlayerDataService.isHotbarFull(player: Player): boolean
	return #PlayerDataService.getData(player).hotbar >= HOTBAR_SIZE
end

function PlayerDataService.addHotbarItem(player: Player, item): boolean
	local data = PlayerDataService.getData(player)
	if #data.hotbar >= HOTBAR_SIZE then
		return false
	end
	table.insert(data.hotbar, item)
	data.hotbarVersion = HOTBAR_VERSION
	if type(item) == "table" and type(item.id) == "string" then
		data.foundBrainrots[item.id] = true
		markVariantFound(data, item.id, item.variantId or VariantConfig.NORMAL_ID)
	end
	return true
end

function PlayerDataService.removeHotbarItemBySlot(player: Player, slotIndex: number)
	local data = PlayerDataService.getData(player)
	local item = data.hotbar[slotIndex]
	if item then
		table.remove(data.hotbar, slotIndex)
	end
	return item
end

-- ─── backpack ─────────────────────────────────────────────────────────────────

function PlayerDataService.getBackpack(player: Player)
	return PlayerDataService.getData(player).backpack
end

function PlayerDataService.isBackpackFull(player: Player): boolean
	return #PlayerDataService.getData(player).backpack >= BACKPACK_SIZE
end

function PlayerDataService.addBackpackItem(player: Player, item): boolean
	local data = PlayerDataService.getData(player)
	if #data.backpack >= BACKPACK_SIZE then
		return false
	end
	table.insert(data.backpack, item)
	if type(item) == "table" and type(item.id) == "string" then
		data.foundBrainrots[item.id] = true
		markVariantFound(data, item.id, item.variantId or VariantConfig.NORMAL_ID)
	end
	return true
end

function PlayerDataService.removeBackpackItemBySlot(player: Player, slotIndex: number)
	local data = PlayerDataService.getData(player)
	local item = data.backpack[slotIndex]
	if item then
		table.remove(data.backpack, slotIndex)
	end
	return item
end

-- Swaps two slots within the backpack.  Both slots must be occupied.
function PlayerDataService.swapBackpackSlots(player: Player, slotA: number, slotB: number): boolean
	local data = PlayerDataService.getData(player)
	local a = data.backpack[slotA]
	local b = data.backpack[slotB]
	if not a or not b then return false end
	data.backpack[slotA] = b
	data.backpack[slotB] = a
	return true
end

-- Swaps two slots within the hotbar.  Both slots must be occupied.
function PlayerDataService.swapHotbarSlots(player: Player, slotA: number, slotB: number): boolean
	local data = PlayerDataService.getData(player)
	local a = data.hotbar[slotA]
	local b = data.hotbar[slotB]
	if not a or not b then return false end
	data.hotbar[slotA] = b
	data.hotbar[slotB] = a
	return true
end

-- Moves a backpack item to a hotbar slot.
-- If the hotbar slot is occupied, the two items are swapped.
-- If the hotbar slot is vacant (> #hotbar), the item is appended to the hotbar
-- provided there is room.  Returns false if the move is not possible.
function PlayerDataService.moveBackpackToHotbar(player: Player, backpackSlot: number, hotbarSlot: number): boolean
	local data = PlayerDataService.getData(player)
	local bpItem = data.backpack[backpackSlot]
	if not bpItem then return false end

	local hbItem = data.hotbar[hotbarSlot]

	if hbItem then
		data.hotbar[hotbarSlot] = bpItem
		data.backpack[backpackSlot] = hbItem
	else
		if #data.hotbar >= HOTBAR_SIZE then return false end
		table.remove(data.backpack, backpackSlot)
		if hotbarSlot <= #data.hotbar then
			table.insert(data.hotbar, hotbarSlot, bpItem)
		else
			table.insert(data.hotbar, bpItem)
		end
	end
	return true
end

-- Moves a hotbar item to a backpack slot.
-- If the backpack slot is occupied, the two items are swapped.
-- If backpack slot is vacant (> #backpack), the item is appended provided
-- there is room.  Returns false if the move is not possible.
function PlayerDataService.moveHotbarToBackpack(player: Player, hotbarSlot: number, backpackSlot: number): boolean
	local data = PlayerDataService.getData(player)
	local hbItem = data.hotbar[hotbarSlot]
	if not hbItem then return false end

	local bpItem = data.backpack[backpackSlot]

	if bpItem then
		data.hotbar[hotbarSlot] = bpItem
		data.backpack[backpackSlot] = hbItem
	else
		if #data.backpack >= BACKPACK_SIZE then return false end
		table.remove(data.hotbar, hotbarSlot)
		if backpackSlot <= #data.backpack then
			table.insert(data.backpack, backpackSlot, hbItem)
		else
			table.insert(data.backpack, hbItem)
		end
	end
	return true
end

-- Returns combined counts from hotbar + legacy inventory bag.
-- The inventory bag is checked too so old players who earned brainrots under
-- the previous system don't lose their rebirth eligibility after the switch.
function PlayerDataService.getHotbarCounts(player: Player)
	local data = PlayerDataService.getData(player)
	local counts = {}

	for _, item in data.hotbar do
		local itemId = item.id
		if type(itemId) == "string" then
			counts[itemId] = (counts[itemId] or 0) + 1
		end
	end

	for _, item in data.backpack do
		local itemId = item.id
		if type(itemId) == "string" then
			counts[itemId] = (counts[itemId] or 0) + 1
		end
	end

	-- Include legacy inventory items so existing-player rebirths still work.
	for _, item in data.inventory do
		local itemId = item.id
		if type(itemId) == "string" then
			counts[itemId] = (counts[itemId] or 0) + 1
		end
	end

	return counts
end

function PlayerDataService.getMissingHotbarRequirements(player: Player, requirements)
	local counts = PlayerDataService.getHotbarCounts(player)
	local missing = {}
	for _, requirement in requirements do
		local owned = counts[requirement.id] or 0
		local required = requirement.count or 1
		if owned < required then
			table.insert(missing, {
				id = requirement.id,
				required = required,
				owned = owned,
				missing = required - owned,
			})
		end
	end
	return missing
end

-- Consumes items from hotbar first, then falls back to the legacy inventory
-- bag so existing players aren't blocked from rebirthing after the switch.
function PlayerDataService.consumeHotbarRequirements(player: Player, requirements)
	local missing = PlayerDataService.getMissingHotbarRequirements(player, requirements)
	if #missing > 0 then
		return false, missing
	end

	local data = PlayerDataService.getData(player)
	for _, requirement in requirements do
		local remaining = requirement.count or 1

		-- Drain hotbar first.
		local i = #data.hotbar
		while i >= 1 and remaining > 0 do
			if data.hotbar[i].id == requirement.id then
				table.remove(data.hotbar, i)
				remaining -= 1
			end
			i -= 1
		end

		-- Fall back to backpack for whatever is still owed.
		if remaining > 0 then
			local j = #data.backpack
			while j >= 1 and remaining > 0 do
				if data.backpack[j].id == requirement.id then
					table.remove(data.backpack, j)
					remaining -= 1
				end
				j -= 1
			end
		end

		-- Fall back to legacy inventory last.
		if remaining > 0 then
			local j = #data.inventory
			while j >= 1 and remaining > 0 do
				if data.inventory[j].id == requirement.id then
					table.remove(data.inventory, j)
					remaining -= 1
				end
				j -= 1
			end
		end
	end

	return true, {}
end

-- ─── public data ──────────────────────────────────────────────────────────────

function PlayerDataService.getPublicData(player: Player)
	local data = PlayerDataService.getData(player)

	return {
		money = math.floor(data.money),
		rebirths = data.rebirths,
		baseTier = PlotConfig.clampTier(data.baseTier),
		shovel = if ShovelConfig.isKnown(data.shovel) then data.shovel else ShovelConfig.getDefaultId(),
		cashMultiplier = EconomyConfig.getCashMultiplier(data.rebirths),
		luckMultiplier = EconomyConfig.getLuckMultiplier(data.rebirths),
		rebirthCost = EconomyConfig.getRebirthCost(data.rebirths),
		inventory = data.inventory,
		hotbar = data.hotbar,
		placedBrainrots = data.placedBrainrots,
		foundBrainrots = data.foundBrainrots,
		foundBrainrotVariants = data.foundBrainrotVariants,
		unlockedPads = data.unlockedPads,
	}
end

function PlayerDataService.getBaseTier(player: Player)
	return PlotConfig.clampTier(PlayerDataService.getData(player).baseTier)
end

function PlayerDataService.setBaseTier(player: Player, tier: number)
	local data = PlayerDataService.getData(player)
	data.baseTier = PlotConfig.clampTier(tier)
	return data.baseTier
end

function PlayerDataService.getShovel(player: Player): string
	local data = PlayerDataService.getData(player)
	if ShovelConfig.isKnown(data.shovel) then
		return data.shovel
	end

	data.shovel = ShovelConfig.getDefaultId()
	return data.shovel
end

function PlayerDataService.setShovel(player: Player, shovelId: string): string?
	if not ShovelConfig.isKnown(shovelId) then
		return nil
	end

	local data = PlayerDataService.getData(player)
	data.shovel = shovelId
	return data.shovel
end

function PlayerDataService.getShovelUpgrades(player: Player)
	local data = PlayerDataService.getData(player)
	local u = data.shovelUpgrades
	return {
		luck = ShovelUpgradeConfig.clampUnboundedLevel(u.luck),
		greenBar = ShovelUpgradeConfig.clampUnboundedLevel(u.greenBar),
		walkSpeed = ShovelUpgradeConfig.clampWalkSpeedLevel(u.walkSpeed),
	}
end

function PlayerDataService.resetWalkSpeedShovelUpgrade(player: Player)
	local data = PlayerDataService.getData(player)
	data.shovelUpgrades.walkSpeed = 0
end

-- Returns `newLevel` when the stat was incremented by 1 (walk speed stops at cap).
function PlayerDataService.incrementShovelUpgrade(player: Player, statId: ShovelUpgradeConfig.StatId): number?
	if not ShovelUpgradeConfig.isStatId(statId) then
		return nil
	end

	local data = PlayerDataService.getData(player)
	local u = data.shovelUpgrades
	local current: number
	if statId == "luck" then
		current = ShovelUpgradeConfig.clampUnboundedLevel(u.luck)
	elseif statId == "greenBar" then
		current = ShovelUpgradeConfig.clampUnboundedLevel(u.greenBar)
	else
		current = ShovelUpgradeConfig.clampWalkSpeedLevel(u.walkSpeed)
	end

	if statId == "walkSpeed" and current >= ShovelUpgradeConfig.MAX_WALK_SPEED_LEVEL then
		return nil
	end

	local nextLevel = current + 1
	if statId == "luck" then
		u.luck = nextLevel
	elseif statId == "greenBar" then
		u.greenBar = nextLevel
	else
		u.walkSpeed = nextLevel
	end
	return nextLevel
end

local VALID_MONEY_SOURCES = {
	PlotCollect = true,
	BaseUpgrade = true,
	PadUnlock = true,
}

function PlayerDataService.addMoney(player: Player, amount: number, source: string?)
	if not VALID_MONEY_SOURCES[source or ""] then
		warn(("[Data] Ignored money award for %s from invalid source: %s"):format(player.Name, tostring(source)))
		return PlayerDataService.getData(player).money
	end

	local data = PlayerDataService.getData(player)
	data.money = math.max(0, data.money + amount)
	updateLeaderstats(player)

	return data.money
end

function PlayerDataService.setMoney(player: Player, amount: number)
	local data = PlayerDataService.getData(player)
	data.money = math.max(0, amount)
	updateLeaderstats(player)
end

function PlayerDataService.addInventoryItem(player: Player, item)
	local data = PlayerDataService.getData(player)
	table.insert(data.inventory, item)
	if type(item) == "table" and type(item.id) == "string" then
		data.foundBrainrots[item.id] = true
		markVariantFound(data, item.id, item.variantId or VariantConfig.NORMAL_ID)
	end

	return item
end

function PlayerDataService.markBrainrotFound(player: Player, brainrotId: string, variantId: string?)
	local data = PlayerDataService.getData(player)
	local wasFound = data.foundBrainrots[brainrotId] == true
	data.foundBrainrots[brainrotId] = true

	local resolvedVariantId = if VariantConfig.isKnown(variantId) then variantId else VariantConfig.NORMAL_ID
	local bucket = data.foundBrainrotVariants[brainrotId]
	local wasVariantFound = type(bucket) == "table" and bucket[resolvedVariantId] == true
	markVariantFound(data, brainrotId, resolvedVariantId)

	return not wasFound, not wasVariantFound
end

function PlayerDataService.removeInventoryItemByUid(player: Player, itemUid: string)
	local data = PlayerDataService.getData(player)

	for index, item in data.inventory do
		if item.uid == itemUid then
			table.remove(data.inventory, index)
			return item
		end
	end

	return nil
end

function PlayerDataService.getInventoryCounts(player: Player)
	local data = PlayerDataService.getData(player)
	local counts = {}

	for _, item in data.inventory do
		local itemId = item.id
		if type(itemId) == "string" then
			counts[itemId] = (counts[itemId] or 0) + 1
		end
	end

	return counts
end

function PlayerDataService.getMissingInventoryRequirements(player: Player, requirements)
	local counts = PlayerDataService.getInventoryCounts(player)
	local missing = {}

	for _, requirement in requirements do
		local owned = counts[requirement.id] or 0
		local required = requirement.count or 1
		if owned < required then
			table.insert(missing, {
				id = requirement.id,
				required = required,
				owned = owned,
				missing = required - owned,
			})
		end
	end

	return missing
end

function PlayerDataService.consumeInventoryRequirements(player: Player, requirements)
	local missing = PlayerDataService.getMissingInventoryRequirements(player, requirements)
	if #missing > 0 then
		return false, missing
	end

	local data = PlayerDataService.getData(player)
	for _, requirement in requirements do
		local remaining = requirement.count or 1
		local index = #data.inventory
		while index >= 1 and remaining > 0 do
			if data.inventory[index].id == requirement.id then
				table.remove(data.inventory, index)
				remaining -= 1
			end
			index -= 1
		end
	end

	return true, {}
end

function PlayerDataService.setPlacedBrainrot(player: Player, slotIndex: number, placement)
	local data = PlayerDataService.getData(player)
	data.placedBrainrots[tostring(slotIndex)] = placement

	return placement
end

function PlayerDataService.getPlacedBrainrot(player: Player, slotIndex: number)
	local data = PlayerDataService.getData(player)

	return data.placedBrainrots[tostring(slotIndex)]
end

function PlayerDataService.clearPlacedBrainrot(player: Player, slotIndex: number)
	local data = PlayerDataService.getData(player)
	data.placedBrainrots[tostring(slotIndex)] = nil
end

function PlayerDataService.isPadUnlocked(player: Player, slotIndex: number): boolean
	local data = PlayerDataService.getData(player)
	return data.unlockedPads[tostring(slotIndex)] == true
end

function PlayerDataService.unlockPad(player: Player, slotIndex: number)
	local data = PlayerDataService.getData(player)
	data.unlockedPads[tostring(slotIndex)] = true
end

function PlayerDataService.getUnlockedPads(player: Player)
	return PlayerDataService.getData(player).unlockedPads
end

function PlayerDataService.incrementRebirths(player: Player)
	local data = PlayerDataService.getData(player)
	data.rebirths += 1
	updateLeaderstats(player)

	return data.rebirths
end

function PlayerDataService.resetPlayer(player: Player)
	local data = normalizeData(getDefaultData())
	dataByUserId[player.UserId] = data
	loadFailedByUserId[player.UserId] = nil

	local dataStore = getStore()
	if datastoreAvailable and dataStore then
		local success, result = pcall(function()
			dataStore:SetAsync(getKey(player), data)
		end)
		if not success then
			warn(("[Data] Failed to wipe %s: %s"):format(player.Name, tostring(result)))
		end
	end

	updateLeaderstats(player)

	task.defer(function()
		if not player.Parent then
			return
		end

		local okLB, LeaderboardPodiumService = pcall(function()
			return require(script.Parent:WaitForChild("LeaderboardPodiumService"))
		end)
		if okLB and LeaderboardPodiumService and LeaderboardPodiumService.removeScoresForPlayer then
			LeaderboardPodiumService.removeScoresForPlayer(player)
		end

		local okCollect, CollectService = pcall(function()
			return require(script.Parent:WaitForChild("CollectService"))
		end)
		if okCollect and CollectService then
			CollectService.syncPlayer(player)
		end

		local okHotbar, HotbarService = pcall(function()
			return require(script.Parent:WaitForChild("HotbarService"))
		end)
		if okHotbar and HotbarService then
			HotbarService.syncPlayer(player)
			HotbarService.syncBackpack(player)
		end

		local okPlot, PlotService = pcall(function()
			return require(script.Parent:WaitForChild("PlotService"))
		end)
		if okPlot and PlotService and PlotService.refreshAfterDataReset then
			PlotService.refreshAfterDataReset(player)
		end
	end)

	return data
end

function PlayerDataService.savePlayer(player: Player)
	local userId = player.UserId
	local data = dataByUserId[userId]
	if not data then
		return true
	end

	if loadFailedByUserId[userId] then
		warn(("[Data] Skipping save for %s — original load failed, refusing to overwrite DataStore."):format(player.Name))
		return false
	end

	local dataStore = getStore()
	if not datastoreAvailable or not dataStore then
		return true
	end

	local success, result = pcall(function()
		dataStore:SetAsync(getKey(player), data)
	end)

	if not success then
		warn(("[Data] Failed to save %s: %s"):format(player.Name, tostring(result)))
	end

	return success
end

-- Schedules a save after SAVE_DEBOUNCE seconds. Calling this repeatedly within
-- that window resets the timer, so rapid mutations (hotbar drags, sell loops)
-- collapse into a single DataStore write.
function PlayerDataService.scheduleSave(player: Player)
	local userId = player.UserId
	local existing = pendingSaveByUserId[userId]
	if existing then
		task.cancel(existing)
	end
	pendingSaveByUserId[userId] = task.delay(SAVE_DEBOUNCE, function()
		pendingSaveByUserId[userId] = nil
		if player.Parent then
			PlayerDataService.savePlayer(player)
		end
	end)
end

function PlayerDataService.start()
	for _, player in Players:GetPlayers() do
		task.spawn(loadPlayer, player)
	end

	Players.PlayerAdded:Connect(loadPlayer)

	Players.PlayerRemoving:Connect(function(player)
		local userId = player.UserId
		-- Flush any pending debounced save immediately.
		local pending = pendingSaveByUserId[userId]
		if pending then
			task.cancel(pending)
			pendingSaveByUserId[userId] = nil
		end
		PlayerDataService.savePlayer(player)
		task.defer(function()
			dataByUserId[userId] = nil
			loadedByUserId[userId] = nil
			loadFailedByUserId[userId] = nil
		end)
	end)

	-- Periodic autosave so a server crash loses at most AUTOSAVE_INTERVAL seconds.
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_INTERVAL)
			for _, player in Players:GetPlayers() do
				task.spawn(PlayerDataService.savePlayer, player)
			end
		end
	end)

	-- Parallel BindToClose: all players are saved concurrently so we don't
	-- time out sequentially on a full server.
	game:BindToClose(function()
		local playerList = Players:GetPlayers()
		if #playerList == 0 then return end

		local remaining = #playerList
		local finished = Instance.new("BindableEvent")

		for _, player in playerList do
			task.spawn(function()
				PlayerDataService.savePlayer(player)
				remaining -= 1
				if remaining <= 0 then
					finished:Fire()
				end
			end)
		end

		finished.Event:Wait()
		finished:Destroy()
	end)
end

return PlayerDataService
