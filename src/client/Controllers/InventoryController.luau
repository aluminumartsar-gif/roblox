-- Thin wrapper that keeps the inventory grid in sync for the Index screen
-- (which brainrots you have ever discovered). Placement and pickup flows are
-- now owned by HotbarController; this module only listens for inventorySync
-- and economy-sync-request so the Index UI stays up to date.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local EconomyConfig = require(ConfigFolder:WaitForChild("EconomyConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))

local InventoryController = {}

local localPlayer = Players.LocalPlayer

function InventoryController.start()
	local inventorySyncRemote = RemoteRegistry.getRemote(
		EconomyConfig.REMOTE_FOLDER,
		EconomyConfig.INVENTORY_SYNC_REMOTE
	)
	local economySyncRequestRemote = RemoteRegistry.getRemote(
		EconomyConfig.REMOTE_FOLDER,
		EconomyConfig.ECONOMY_SYNC_REQUEST_REMOTE
	)

	-- Request a full economy snapshot on start so the cash display and any
	-- rebirth UI populate immediately without waiting for the first server push.
	economySyncRequestRemote:FireServer()

	-- inventorySyncRemote payloads are still fired by CollectService for legacy
	-- callers and the Index screen. No action needed here — the Index controller
	-- subscribes directly to this remote itself.
	inventorySyncRemote.OnClientEvent:Connect(function(_payload)
		-- intentionally no-op; Index controller handles its own subscription
	end)
end

return InventoryController
