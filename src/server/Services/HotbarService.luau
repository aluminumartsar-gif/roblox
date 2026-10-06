-- Manages each player's hotbar: an ordered list of up to HOTBAR_SIZE brainrot
-- items that persists across sessions. Items arrive here from two sources:
--   1. World drops (dug brainrots) via `pickup(player, dropId)`.
--   2. Plot pad pick-ups (removing a placed brainrot) via `addItem(player, item)`.
-- Placement consumes a slot via `removeSlot(player, slotIndex)`.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local DigConfig = require(ConfigFolder:WaitForChild("DigConfig"))
local EconomyConfig = require(ConfigFolder:WaitForChild("EconomyConfig"))
local VariantConfig = require(ConfigFolder:WaitForChild("VariantConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))

local CollectService = require(script.Parent:WaitForChild("CollectService"))
local EconomyService = require(script.Parent:WaitForChild("EconomyService"))
local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))
local RareAnnounceService = require(script.Parent:WaitForChild("RareAnnounceService"))

local HotbarService = {}

local hotbarSyncRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.HOTBAR_SYNC_REMOTE)
local hotbarNotificationRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.HOTBAR_NOTIFICATION_REMOTE)
local backpackSyncRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.BACKPACK_SYNC_REMOTE)
local inventoryMoveRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.INVENTORY_MOVE_REMOTE)
local brainrotCollectedRemote = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.BRAINROT_COLLECTED_REMOTE)
local economySyncRequestRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.ECONOMY_SYNC_REQUEST_REMOTE)

local collectingDrops: { [string]: boolean } = {}

local function syncPlayer(player: Player)
	local hotbar = PlayerDataService.getHotbar(player)
	hotbarSyncRemote:FireClient(player, hotbar)
end

local function syncBackpack(player: Player)
	local backpack = PlayerDataService.getBackpack(player)
	backpackSyncRemote:FireClient(player, backpack)
end

local function notify(player: Player, message: string)
	hotbarNotificationRemote:FireClient(player, message)
end

-- Called from BrainrotSpawnService when the player triggers the pickup prompt
-- on a world drop. `dropData` is the active drop record from BrainrotSpawnService.
function HotbarService.pickup(player: Player, dropId: string, dropData)
	if collectingDrops[dropId] then
		return false
	end

	if not dropData or not dropData.isRevealed then
		return false
	end

	if dropData.ownerUserId ~= player.UserId then
		return false
	end

	-- Reject only when both hotbar and backpack are full.
	local hotbarFull = PlayerDataService.isHotbarFull(player)
	if hotbarFull and PlayerDataService.isBackpackFull(player) then
		notify(player, "Inventory full! Place or sell a brainrot first.")
		return false
	end

	collectingDrops[dropId] = true

	-- Stop idle animation and hide the placard before the fly tween starts.
	if dropData.component and dropData.component.stopIdle then
		dropData.component.stopIdle()
	end
	if dropData.billboard and dropData.billboard.Parent then
		dropData.billboard.Enabled = false
	end

	-- Track discovery first so markBrainrotFound sees the brainrot as new before
	-- addHotbarItem/addBackpackItem stamp foundBrainrots[id] = true themselves.
	local resolvedVariantId = if VariantConfig.isKnown(dropData.variantId) then dropData.variantId else VariantConfig.NORMAL_ID
	CollectService.trackFound(player, dropData.brainrotId, resolvedVariantId)

	-- Build the inventory entry and route to hotbar or backpack overflow.
	local entry = EconomyService.createInventoryEntry(dropData.brainrotId, dropData.variantId)
	local wentToBackpack = false

	if not hotbarFull then
		local added = PlayerDataService.addHotbarItem(player, entry)
		if not added then
			-- Race: hotbar filled between the full-check and now; try backpack.
			if PlayerDataService.isBackpackFull(player) then
				collectingDrops[dropId] = nil
				notify(player, "Inventory full! Place or sell a brainrot first.")
				return false
			end
			PlayerDataService.addBackpackItem(player, entry)
			wentToBackpack = true
		end
	else
		local added = PlayerDataService.addBackpackItem(player, entry)
		if not added then
			collectingDrops[dropId] = nil
			notify(player, "Inventory full! Place or sell a brainrot first.")
			return false
		end
		wentToBackpack = true
	end

	-- Fire the fly-to-player VFX; all clients see the brainrot zoom toward
	-- the owner so the pickup reads as clearly "claimed."
	brainrotCollectedRemote:FireAllClients(player, dropId, dropData.brainrotId, DigConfig.COLLECT_FLY_TIME)

	RareAnnounceService.notifyRarePickup(player, dropData)

	PlayerDataService.scheduleSave(player)

	if wentToBackpack then
		notify(player, "Hotbar Full! Brainrot sent to Backpack (press B).")
		syncBackpack(player)
	else
		syncPlayer(player)
	end

	return true, dropId
end

-- Adds a pre-built item directly to the hotbar (used when picking up from a
-- plot pad). Overflows to the backpack when the hotbar is full.
function HotbarService.addItem(player: Player, item): boolean
	if not PlayerDataService.isHotbarFull(player) then
		local added = PlayerDataService.addHotbarItem(player, item)
		if added then
			PlayerDataService.scheduleSave(player)
			syncPlayer(player)
			return true
		end
	end

	-- Hotbar full — try backpack overflow.
	if PlayerDataService.isBackpackFull(player) then
		notify(player, "Inventory full! Place or sell a brainrot first.")
		return false
	end

	local added = PlayerDataService.addBackpackItem(player, item)
	if not added then
		notify(player, "Inventory full! Place or sell a brainrot first.")
		return false
	end

	PlayerDataService.scheduleSave(player)
	notify(player, "Hotbar Full! Brainrot sent to Backpack (press B).")
	syncBackpack(player)
	return true
end

-- Removes the item at `slotIndex` (1-based) from the hotbar and returns it.
-- Called by PlotService after a successful placement.
function HotbarService.removeSlot(player: Player, slotIndex: number)
	local item = PlayerDataService.removeHotbarItemBySlot(player, slotIndex)
	if item then
		PlayerDataService.scheduleSave(player)
		syncPlayer(player)
	end
	return item
end

function HotbarService.getHotbar(player: Player)
	return PlayerDataService.getHotbar(player)
end

function HotbarService.removeBackpackSlot(player: Player, slotIndex: number)
	local item = PlayerDataService.removeBackpackItemBySlot(player, slotIndex)
	if item then
		PlayerDataService.scheduleSave(player)
		syncBackpack(player)
	end
	return item
end

function HotbarService.syncPlayer(player: Player)
	syncPlayer(player)
end

function HotbarService.syncBackpack(player: Player)
	syncBackpack(player)
end

function HotbarService.releaseCollectingDrop(dropId: string)
	collectingDrops[dropId] = nil
end

function HotbarService.start()
	-- Fire the initial hotbar snapshot when a player's data is ready so the
	-- client can render the correct state without waiting for a pickup.
	local function onPlayerReady(player: Player)
		PlayerDataService.waitForData(player)
		if player.Parent then
			syncPlayer(player)
			syncBackpack(player)
		end
	end

	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerReady, player)
	end

	Players.PlayerAdded:Connect(function(player)
		task.spawn(onPlayerReady, player)
	end)

	-- Re-send the hotbar snapshot whenever any controller requests an economy
	-- refresh. This ensures controllers that connected their listeners after the
	-- initial one-shot sync don't stay stuck on stale (or default-empty) state.
	economySyncRequestRemote.OnServerEvent:Connect(function(player: Player)
		PlayerDataService.waitForData(player)
		if player.Parent then
			syncPlayer(player)
			syncBackpack(player)
		end
	end)

	inventoryMoveRemote.OnServerEvent:Connect(function(player: Player, action: unknown, slotA: unknown, slotB: unknown)
		if type(action) ~= "string" then return end
		local a = tonumber(slotA)
		local b = tonumber(slotB)
		if not a then return end

		if action == "swap_backpack" then
			if not b then return end
			if PlayerDataService.swapBackpackSlots(player, a, b) then
				PlayerDataService.scheduleSave(player)
				syncBackpack(player)
			end
		elseif action == "swap_hotbar" then
			if not b then return end
			if PlayerDataService.swapHotbarSlots(player, a, b) then
				PlayerDataService.scheduleSave(player)
				syncPlayer(player)
			end
		elseif action == "backpack_to_hotbar" then
			if not b then return end
			if PlayerDataService.moveBackpackToHotbar(player, a, b) then
				PlayerDataService.scheduleSave(player)
				syncPlayer(player)
				syncBackpack(player)
			else
				notify(player, "Hotbar full! Place or sell a brainrot first.")
			end
		elseif action == "hotbar_to_backpack" then
			if not b then return end
			if PlayerDataService.moveHotbarToBackpack(player, a, b) then
				PlayerDataService.scheduleSave(player)
				syncPlayer(player)
				syncBackpack(player)
			else
				notify(player, "Inventory full! Place or sell a brainrot first.")
			end
		end
	end)
end

return HotbarService
