-- Authoritative teleport handler for top-bar teleport buttons (base, shop,
-- sell booth, shovel upgrade booth).
--
-- Runs on the server because:
--   * Plot ownership and the per-base SpawnLocation are server-owned state
--     (see PlotService) so only the server can resolve the correct destination
--     for a given player.
--   * Pivoting the player's character on the server keeps the move replicated
--     consistently and prevents a malicious client from teleporting to
--     arbitrary world positions.
--
-- Destinations are validated against TeleportConfig and a small per-player
-- debounce keeps spam clicks from burning physics work.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local TeleportConfig = require(ConfigFolder:WaitForChild("TeleportConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))
local WorkspaceModelFind = require(UtilFolder:WaitForChild("WorkspaceModelFind"))

local PlotService = require(script.Parent:WaitForChild("PlotService"))

local TeleportService = {}

local SHOP_MODEL_NAME = "Shop"
local SELL_MODEL_NAME = "Sell"
local UPGRADE_MODEL_NAME = "Upgrade"

local started = false
local lastRequestByUserId: { [number]: number } = {}

-- Mirrors the lookup ShopBoothController uses on the client: the build has
-- the shopkeeper nested under Workspace.Shop.<unnamed model> with a Humanoid,
-- so finding the Humanoid first makes us robust to renames.
local function findShopkeeperAnchor(shopModel: Model): BasePart?
	for _, descendant in shopModel:GetDescendants() do
		if descendant:IsA("Humanoid") then
			local model = descendant.Parent
			if model and model:IsA("Model") then
				local root = model:FindFirstChild("HumanoidRootPart")
				if root and root:IsA("BasePart") then
					return root
				end

				local primary = model.PrimaryPart
				if primary then
					return primary
				end

				local torso = model:FindFirstChild("Torso")
				if torso and torso:IsA("BasePart") then
					return torso
				end
			end
		end
	end

	return nil
end

local function teleportCharacterFacingNpc(character: Model, boothModelName: string): boolean
	local boothModel = WorkspaceModelFind.findNamedModel(Workspace, boothModelName)
	if not boothModel or not boothModel:IsA("Model") then
		return false
	end

	local anchor = findShopkeeperAnchor(boothModel)
	if not anchor then
		return false
	end

	-- Land the player a few studs in front of the NPC using its forward vector.
	local lookVector = anchor.CFrame.LookVector
	local horizontal = Vector3.new(lookVector.X, 0, lookVector.Z)
	if horizontal.Magnitude > 1e-3 then
		horizontal = horizontal.Unit
	else
		horizontal = Vector3.new(0, 0, 1)
	end

	local landingPosition = anchor.Position
		+ horizontal * TeleportConfig.SHOP_LANDING_OFFSET_STUDS
		+ Vector3.new(0, TeleportConfig.TELEPORT_HEIGHT_OFFSET_STUDS, 0)

	character:PivotTo(CFrame.lookAt(landingPosition, anchor.Position))
	return true
end

local function teleportToShop(player: Player): boolean
	local character = player.Character
	if not character then
		return false
	end
	return teleportCharacterFacingNpc(character, SHOP_MODEL_NAME)
end

local function teleportToSell(player: Player): boolean
	local character = player.Character
	if not character then
		return false
	end
	return teleportCharacterFacingNpc(character, SELL_MODEL_NAME)
end

local function teleportToUpgrade(player: Player): boolean
	local character = player.Character
	if not character then
		return false
	end
	return teleportCharacterFacingNpc(character, UPGRADE_MODEL_NAME)
end

local function onTeleportRequest(player: Player, destination: any)
	if not TeleportConfig.isKnownDestination(destination) then
		return
	end

	local now = os.clock()
	local nextAllowed = lastRequestByUserId[player.UserId] or 0
	if now < nextAllowed then
		return
	end
	lastRequestByUserId[player.UserId] = now + TeleportConfig.REQUEST_DEBOUNCE_SECONDS

	if destination == TeleportConfig.DESTINATION_BASE then
		PlotService.teleportPlayerHome(player)
	elseif destination == TeleportConfig.DESTINATION_SHOP then
		teleportToShop(player)
	elseif destination == TeleportConfig.DESTINATION_SELL then
		teleportToSell(player)
	elseif destination == TeleportConfig.DESTINATION_UPGRADE then
		teleportToUpgrade(player)
	end
end

function TeleportService.start()
	if started then
		return
	end
	started = true

	local requestRemote = RemoteRegistry.getRemote(
		TeleportConfig.REMOTE_FOLDER,
		TeleportConfig.TELEPORT_REQUEST_REMOTE
	)

	requestRemote.OnServerEvent:Connect(onTeleportRequest)

	Players.PlayerRemoving:Connect(function(player)
		lastRequestByUserId[player.UserId] = nil
	end)
end

return TeleportService
