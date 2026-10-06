-- Drives proximity open/close for Workspace.Upgrade and opens ItemUpgradesController.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local EconomyConfig = require(ConfigFolder:WaitForChild("EconomyConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))
local WorkspaceModelFind = require(UtilFolder:WaitForChild("WorkspaceModelFind"))

local Controllers = script.Parent
local ItemUpgradesController = require(Controllers:WaitForChild("ItemUpgradesController"))

local UpgradeBoothController = {}

local MODEL_NAME = "Upgrade"
local OPEN_RADIUS_STUDS = 12
local CLOSE_RADIUS_STUDS = 22
local CHECK_INTERVAL_SECONDS = 1 / 6

local localPlayer = Players.LocalPlayer

local function findUpgradeModel(): Model?
	return WorkspaceModelFind.findNamedModel(Workspace, MODEL_NAME)
end

local function findShopkeeper(shopModel: Model): Model?
	for _, descendant in shopModel:GetDescendants() do
		if descendant:IsA("Humanoid") then
			local model = descendant.Parent
			if model and model:IsA("Model") then
				return model
			end
		end
	end

	return nil
end

local function findShopkeeperAnchor(npc: Model): BasePart?
	local root = npc:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end

	local primary = npc.PrimaryPart
	if primary and primary:IsA("BasePart") then
		return primary
	end

	local torso = npc:FindFirstChild("Torso")
	if torso and torso:IsA("BasePart") then
		return torso
	end

	for _, descendant in npc:GetDescendants() do
		if descendant:IsA("BasePart") then
			return descendant
		end
	end

	return nil
end

local function getCharacterRoot(): BasePart?
	local character = localPlayer.Character
	if not character then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end

	return nil
end

function UpgradeBoothController.start()
	ItemUpgradesController.start()

	local manuallyClosed = false

	ItemUpgradesController.setManualCloseHandler(function()
		manuallyClosed = true
		ItemUpgradesController.close()
	end)

	local economySyncRemote = RemoteRegistry.getRemote(
		EconomyConfig.REMOTE_FOLDER,
		EconomyConfig.ECONOMY_SYNC_REMOTE
	)
	local economySyncRequestRemote = RemoteRegistry.getRemote(
		EconomyConfig.REMOTE_FOLDER,
		EconomyConfig.ECONOMY_SYNC_REQUEST_REMOTE
	)

	economySyncRemote.OnClientEvent:Connect(function(payload)
		ItemUpgradesController.applyEconomyPayload(payload)
	end)

	economySyncRequestRemote:FireServer()

	local cachedModel: Model? = nil
	local cachedKeeper: Model? = nil
	local cachedAnchor: BasePart? = nil

	Workspace.DescendantAdded:Connect(function(inst: Instance)
		if inst:IsA("Model") and inst.Name == MODEL_NAME then
			cachedModel = nil
			cachedKeeper = nil
			cachedAnchor = nil
		end
	end)

	local function resolveAnchor(): BasePart?
		if cachedAnchor and cachedAnchor.Parent then
			return cachedAnchor
		end

		if not cachedModel or not cachedModel.Parent then
			cachedModel = findUpgradeModel()
			cachedKeeper = nil
		end
		if not cachedModel then
			return nil
		end

		if not cachedKeeper or not cachedKeeper.Parent then
			cachedKeeper = findShopkeeper(cachedModel)
		end
		if not cachedKeeper then
			return nil
		end

		cachedAnchor = findShopkeeperAnchor(cachedKeeper)
		return cachedAnchor
	end

	local lastCheckAt = 0

	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now - lastCheckAt < CHECK_INTERVAL_SECONDS then
			return
		end
		lastCheckAt = now

		local anchor = resolveAnchor()
		if not anchor then
			return
		end

		local root = getCharacterRoot()
		if not root then
			if ItemUpgradesController.isOpen() then
				ItemUpgradesController.close()
			end
			manuallyClosed = false
			return
		end

		local distance = (root.Position - anchor.Position).Magnitude

		if ItemUpgradesController.isOpen() then
			if manuallyClosed then
				if distance > CLOSE_RADIUS_STUDS then
					manuallyClosed = false
				end
				return
			end

			if distance > CLOSE_RADIUS_STUDS then
				ItemUpgradesController.close()
			end
			return
		end

		if manuallyClosed then
			if distance > CLOSE_RADIUS_STUDS then
				manuallyClosed = false
			end
			return
		end

		if distance <= OPEN_RADIUS_STUDS then
			ItemUpgradesController.refreshUI()
			ItemUpgradesController.open()
		end
	end)
end

return UpgradeBoothController
