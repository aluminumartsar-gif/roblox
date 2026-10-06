-- Cosmetic tagging for Workspace.Upgrade (shovel stat station). Proximity UX is client-side.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UtilFolder = Shared:WaitForChild("Util")
local WorkspaceModelFind = require(UtilFolder:WaitForChild("WorkspaceModelFind"))

local UpgradeBoothService = {}
local started = false

local UPGRADE_MODEL_NAME = "Upgrade"
local LEGACY_NAME_TAG = "ShopkeeperNameTag"
local LEGACY_3D_TEXT = "3D Text Maker: Shop"
local SHOPKEEPER_ROLE_ATTRIBUTE = "ShopkeeperRole"
local STAND_LABEL_NAME = "StandLabel"

local function findShopkeeperModel(shopModel: Instance): Model?
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

local function purgeLegacyTags(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant.Name == LEGACY_NAME_TAG or descendant.Name == LEGACY_3D_TEXT then
			descendant:Destroy()
		end
	end
end

local function configureShopkeeper(npc: Model)
	npc:SetAttribute(SHOPKEEPER_ROLE_ATTRIBUTE, "ShovelUpgrader")

	purgeLegacyTags(npc)

	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayName = ""
		humanoid.NameDisplayDistance = 0
		humanoid.HealthDisplayDistance = 0
	end
end

local function purgeLegacyLabels(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant.Name == STAND_LABEL_NAME then
			descendant:Destroy()
		end
	end
end

local function configureOnce()
	local upgradeModel = WorkspaceModelFind.findNamedModel(Workspace, UPGRADE_MODEL_NAME)
	if upgradeModel and upgradeModel:IsA("Model") then
		upgradeModel:SetAttribute("IsUpgradeBooth", true)
		purgeLegacyTags(upgradeModel)

		local npc = findShopkeeperModel(upgradeModel)
		if npc then
			configureShopkeeper(npc)
		else
			warn("[UpgradeBooth] No Humanoid found inside Workspace.Upgrade; skipping NPC configuration.")
		end

		purgeLegacyLabels(upgradeModel)
	else
		warn("[UpgradeBooth] Workspace.Upgrade is missing or not a Model; skipping.")
	end
end

function UpgradeBoothService.start()
	if started then
		return
	end
	started = true

	task.defer(function()
		local ok, err = pcall(configureOnce)
		if not ok then
			warn(("[UpgradeBooth] Failed to configure: %s"):format(tostring(err)))
		end
	end)
end

return UpgradeBoothService
