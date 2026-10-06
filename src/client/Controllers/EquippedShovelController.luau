-- Drives the bottom-left "currently equipped shovel" HUD logo. The controller
-- listens to the same EconomySync, VendorSync, and VendorPurchaseResult
-- streams the shop booth subscribes to so the logo (and its hover tooltip)
-- always reflects the player's authoritative equipped shovel.
--
-- The controller is a thin glue layer: it doesn't own any data, it just maps
-- remote payloads to `EquippedShovelUI:setShovel`. The UI component is the
-- passive renderer.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local EconomyConfig = require(ConfigFolder:WaitForChild("EconomyConfig"))
local ShovelConfig = require(ConfigFolder:WaitForChild("ShovelConfig"))
local DigSiteConfig = require(ConfigFolder:WaitForChild("DigSiteConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))

local Components = script.Parent.Parent:WaitForChild("Components")
local EquippedShovelUI = require(Components:WaitForChild("EquippedShovelUI"))

local PROXIMITY_CHECK_INTERVAL = 0.18
local DIG_PROXIMITY_PADDING    = 6
local DIG_PROXIMITY_HEIGHT     = 12

local function isCharacterAtDigSite(): boolean
	local localPlayer = Players.LocalPlayer
	local character = localPlayer.Character
	if not character then
		return false
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end

	local digSite = game:GetService("Workspace"):FindFirstChild(DigSiteConfig.MODEL_NAME)
	if not digSite then
		return false
	end

	local floor = digSite:FindFirstChild(DigSiteConfig.FLOOR_NAME, true)
	if not floor then
		for _, d in digSite:GetDescendants() do
			if d:IsA("BasePart") then
				floor = d
				break
			end
		end
	end
	if not floor or not floor:IsA("BasePart") then
		return false
	end

	local localPos = (floor :: BasePart).CFrame:PointToObjectSpace(root.Position)
	local halfSize = (floor :: BasePart).Size * 0.5
	local hPad = DigSiteConfig.DIG_SURFACE_PADDING + DIG_PROXIMITY_PADDING

	return math.abs(localPos.X) <= halfSize.X + hPad
		and math.abs(localPos.Z) <= halfSize.Z + hPad
		and math.abs(localPos.Y) <= halfSize.Y + DIG_PROXIMITY_HEIGHT
end

local EquippedShovelController = {}

function EquippedShovelController.start()
	local economySyncRemote = RemoteRegistry.getRemote(
		EconomyConfig.REMOTE_FOLDER,
		EconomyConfig.ECONOMY_SYNC_REMOTE
	)
	local economySyncRequestRemote = RemoteRegistry.getRemote(
		EconomyConfig.REMOTE_FOLDER,
		EconomyConfig.ECONOMY_SYNC_REQUEST_REMOTE
	)
	local vendorSyncRemote = RemoteRegistry.getRemote(
		EconomyConfig.VENDOR_REMOTE_FOLDER,
		EconomyConfig.VENDOR_SYNC_REMOTE
	)
	local vendorPurchaseResultRemote = RemoteRegistry.getRemote(
		EconomyConfig.VENDOR_REMOTE_FOLDER,
		EconomyConfig.VENDOR_PURCHASE_RESULT_REMOTE
	)

	local ui = EquippedShovelUI.new()
	-- Seed with the default so the logo never renders empty before the first
	-- EconomySync arrives.
	ui:setShovel(ShovelConfig.getOrDefault(nil))

	local function adoptShovel(shovelId: any)
		if type(shovelId) ~= "string" or not ShovelConfig.isKnown(shovelId) then
			return
		end

		ui:setShovel(ShovelConfig.getOrDefault(shovelId))
	end

	economySyncRemote.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end

		adoptShovel(payload.shovel)
	end)

	vendorSyncRemote.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end

		adoptShovel(payload.shovel)
	end)

	vendorPurchaseResultRemote.OnClientEvent:Connect(function(result)
		if type(result) ~= "table" then
			return
		end

		adoptShovel(result.shovel)
	end)

	-- Fire the initial sync request in case no other controller has done so
	-- yet. EconomySyncRequest is idempotent server-side: extra requests just
	-- re-send the latest snapshot to this client.
	economySyncRequestRemote:FireServer()

	-- Show the shovel HUD only while the player is inside the dig site.
	task.spawn(function()
		local wasAtSite = false
		while true do
			local atSite = isCharacterAtDigSite()
			if atSite ~= wasAtSite then
				wasAtSite = atSite
				if atSite then
					ui:show()
				else
					ui:hide()
				end
			end
			task.wait(PROXIMITY_CHECK_INTERVAL)
		end
	end)
end

return EquippedShovelController
