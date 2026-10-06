local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local BrainrotConfig = require(ConfigFolder:WaitForChild("BrainrotConfig"))
local EconomyConfig = require(ConfigFolder:WaitForChild("EconomyConfig"))
local VariantConfig = require(ConfigFolder:WaitForChild("VariantConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))

local EconomyService = require(script.Parent:WaitForChild("EconomyService"))
local LeaderboardPodiumService = require(script.Parent:WaitForChild("LeaderboardPodiumService"))
local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))

local CollectService = {}

local inventorySyncRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.INVENTORY_SYNC_REMOTE)
local economySyncRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.ECONOMY_SYNC_REMOTE)
local economySyncRequestRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.ECONOMY_SYNC_REQUEST_REMOTE)
local indexSyncRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.INDEX_SYNC_REMOTE)
local newBrainrotFoundRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.NEW_BRAINROT_FOUND_REMOTE)

local function fireInventorySnapshot(player: Player)
	local publicData = PlayerDataService.getPublicData(player)
	inventorySyncRemote:FireClient(player, {
		inventory = publicData.inventory,
	})
end

local function fireIndexSnapshot(player: Player)
	local publicData = PlayerDataService.getPublicData(player)
	indexSyncRemote:FireClient(player, {
		foundBrainrots = publicData.foundBrainrots,
		foundBrainrotVariants = publicData.foundBrainrotVariants,
	})
end

local function fireEconomySnapshot(player: Player, extra)
	local snapshot = EconomyService.getSnapshot(player)
	if extra then
		for key, value in extra do
			snapshot[key] = value
		end
	end

	economySyncRemote:FireClient(player, snapshot)
end

local function fireNewBrainrotFound(player: Player, brainrotId: string, variantId: string)
	local revealData = BrainrotConfig.getRevealData(brainrotId, variantId)
	local earningsRate = EconomyService.previewEarningsRate(player, brainrotId, variantId)
	newBrainrotFoundRemote:FireClient(player, {
		brainrotId = brainrotId,
		variantId = variantId,
		rarity = revealData.rarity,
		rarityRank = revealData.rarityRank,
		baseValue = revealData.baseValue,
		earningsRate = earningsRate,
		rngText = revealData.rngText,
		color = revealData.color,
		revealColor = revealData.revealColor,
	})
end

-- Marks a brainrot as discovered in the player's index without adding it to
-- any bag. Called by HotbarService after a successful world-drop pickup so
-- the index and new-brainrot reveal still fire correctly.
function CollectService.trackFound(player: Player, brainrotId: string, variantId: string?)
	PlayerDataService.waitForData(player)

	local resolvedVariantId = if VariantConfig.isKnown(variantId) then variantId else VariantConfig.NORMAL_ID
	local isNewBrainrot, isNewVariant = PlayerDataService.markBrainrotFound(player, brainrotId, resolvedVariantId)

	if isNewBrainrot then
		fireNewBrainrotFound(player, brainrotId, resolvedVariantId)
	end
	if isNewBrainrot or isNewVariant then
		fireIndexSnapshot(player)
		LeaderboardPodiumService.pushScoresForPlayer(player)
	end
end

-- Legacy path kept for any internal callers that still add directly to the
-- old inventory bag (e.g. migration or future sell-station refunds).
function CollectService.addToInventory(player: Player, brainrotId: string, variantId: string?)
	PlayerDataService.waitForData(player)

	local resolvedVariantId = if VariantConfig.isKnown(variantId) then variantId else VariantConfig.NORMAL_ID
	local isNewBrainrot, isNewVariant = PlayerDataService.markBrainrotFound(player, brainrotId, resolvedVariantId)
	local entry = EconomyService.createInventoryEntry(brainrotId, resolvedVariantId)
	PlayerDataService.addInventoryItem(player, entry)

	fireInventorySnapshot(player)
	if isNewBrainrot then
		fireNewBrainrotFound(player, brainrotId, resolvedVariantId)
	end
	if isNewBrainrot or isNewVariant then
		fireIndexSnapshot(player)
	end
	fireEconomySnapshot(player)

	LeaderboardPodiumService.pushScoresForPlayer(player)

	return entry
end

function CollectService.getInventory(player: Player)
	return PlayerDataService.getPublicData(player).inventory
end

function CollectService.syncPlayer(player: Player)
	PlayerDataService.waitForData(player)
	fireInventorySnapshot(player)
	fireIndexSnapshot(player)
	fireEconomySnapshot(player)
end

function CollectService.syncEconomy(player: Player, extra)
	PlayerDataService.waitForData(player)
	fireEconomySnapshot(player, extra)
end

function CollectService.start()
	for _, player in Players:GetPlayers() do
		task.defer(CollectService.syncPlayer, player)
	end

	Players.PlayerAdded:Connect(function(player)
		task.defer(CollectService.syncPlayer, player)
	end)

	economySyncRequestRemote.OnServerEvent:Connect(function(player)
		CollectService.syncPlayer(player)
	end)
end

return CollectService
