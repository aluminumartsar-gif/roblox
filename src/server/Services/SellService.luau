-- Handles brainrot selling at the Workspace.Sell stand. Clients fire either
-- SellItemRequest (sell a single hotbar slot by index) or SellAllRequest
-- (clear the entire hotbar + backpack). The server validates, awards cash,
-- then fires back SellResult along with the standard HotbarSync / BackpackSync
-- / EconomySync so every listener stays up to date.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local EconomyConfig = require(ConfigFolder:WaitForChild("EconomyConfig"))
local BrainrotConfig = require(ConfigFolder:WaitForChild("BrainrotConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))

local EconomyService = require(script.Parent:WaitForChild("EconomyService"))
local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))

local SellService = {}

-- ─── remotes ──────────────────────────────────────────────────────────────────

local sellItemRequestRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.SELL_ITEM_REQUEST_REMOTE)
local sellAllRequestRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.SELL_ALL_REQUEST_REMOTE)
local sellResultRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.SELL_RESULT_REMOTE)
local hotbarSyncRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.HOTBAR_SYNC_REMOTE)
local backpackSyncRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.BACKPACK_SYNC_REMOTE)
local economySyncRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.ECONOMY_SYNC_REMOTE)

-- ─── helpers ──────────────────────────────────────────────────────────────────

local function computeItemCash(player: Player, item): number
	if type(item) ~= "table" then
		return 0
	end
	return EconomyService.getCashReward(player, item)
end

local function getDisplayName(item): string
	if type(item) ~= "table" or type(item.id) ~= "string" then
		return "Brainrot"
	end
	local revealData = BrainrotConfig.getRevealData(item.id)
	return if revealData and type(revealData.displayName) == "string" then revealData.displayName else item.id
end

local function syncAll(player: Player)
	hotbarSyncRemote:FireClient(player, PlayerDataService.getHotbar(player))
	backpackSyncRemote:FireClient(player, PlayerDataService.getBackpack(player))
	local snapshot = EconomyService.getSnapshot(player)
	economySyncRemote:FireClient(player, snapshot)
end

-- ─── sell single item ─────────────────────────────────────────────────────────

local function handleSellItem(player: Player, slotIndex: any)
	-- Validate the slot index from the untrusted client.
	local slot = tonumber(slotIndex)
	if not slot or slot < 1 or slot ~= math.floor(slot) then
		sellResultRemote:FireClient(player, {
			success = false,
			message = "Invalid slot.",
			cashEarned = 0,
		})
		return
	end

	local hotbar = PlayerDataService.getHotbar(player)
	local item = hotbar[slot]
	if not item then
		sellResultRemote:FireClient(player, {
			success = false,
			message = "Nothing to sell in that slot!",
			cashEarned = 0,
		})
		return
	end

	local cash = computeItemCash(player, item)
	local name = getDisplayName(item)

	PlayerDataService.removeHotbarItemBySlot(player, slot)
	PlayerDataService.addMoney(player, cash, "sell_item")

	task.spawn(PlayerDataService.savePlayer, player)
	syncAll(player)

	sellResultRemote:FireClient(player, {
		success = true,
		message = ('Sold %s for $%d!'):format(name, cash),
		cashEarned = cash,
	})
end

-- ─── sell all ─────────────────────────────────────────────────────────────────

local function handleSellAll(player: Player)
	local hotbar = PlayerDataService.getHotbar(player)
	local backpack = PlayerDataService.getBackpack(player)

	local totalCash = 0
	local totalItems = 0

	-- Tally hotbar back-to-front so removal indices stay valid.
	for i = #hotbar, 1, -1 do
		local item = hotbar[i]
		totalCash += computeItemCash(player, item)
		totalItems += 1
		PlayerDataService.removeHotbarItemBySlot(player, i)
	end

	-- Tally backpack back-to-front.
	for i = #backpack, 1, -1 do
		local item = backpack[i]
		totalCash += computeItemCash(player, item)
		totalItems += 1
		PlayerDataService.removeBackpackItemBySlot(player, i)
	end

	if totalItems == 0 then
		sellResultRemote:FireClient(player, {
			success = false,
			message = "You have nothing to sell!",
			cashEarned = 0,
		})
		return
	end

	PlayerDataService.addMoney(player, totalCash, "sell_all")

	task.spawn(PlayerDataService.savePlayer, player)
	syncAll(player)

	sellResultRemote:FireClient(player, {
		success = true,
		message = ('Sold %d brainrot%s for $%d!'):format(
			totalItems,
			if totalItems == 1 then "" else "s",
			totalCash
		),
		cashEarned = totalCash,
	})
end

-- ─── lifecycle ────────────────────────────────────────────────────────────────

function SellService.start()
	sellItemRequestRemote.OnServerEvent:Connect(function(player, slotIndex)
		local ok, err = pcall(handleSellItem, player, slotIndex)
		if not ok then
			warn(("[SellService] SellItemRequest error for %s: %s"):format(player.Name, tostring(err)))
		end
	end)

	sellAllRequestRemote.OnServerEvent:Connect(function(player)
		local ok, err = pcall(handleSellAll, player)
		if not ok then
			warn(("[SellService] SellAllRequest error for %s: %s"):format(player.Name, tostring(err)))
		end
	end)
end

return SellService
