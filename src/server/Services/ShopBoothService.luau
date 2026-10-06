-- Lightweight tagging for the developer-placed Workspace.Shop and Workspace.Sell
-- models: silences the default Roblox name+health display on the shopkeeper NPCs,
-- stamps attributes that future systems can hook off of, and removes legacy 3D text.
--
-- Stand labels are world-space SurfaceGui Parts named "StandSign" placed directly
-- inside each model in Studio. This service no longer generates them at runtime.
--
-- All proximity / open-shop logic lives on the client (see ShopBoothController);
-- this service stays cosmetic-only so the server stays cheap.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UtilFolder = Shared:WaitForChild("Util")
local WorkspaceModelFind = require(UtilFolder:WaitForChild("WorkspaceModelFind"))

local ShopBoothService = {}
local started = false

local SHOP_MODEL_NAME = "Shop"
local SELL_MODEL_NAME = "Sell"
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
	npc:SetAttribute(SHOPKEEPER_ROLE_ATTRIBUTE, "ShovelMerchant")

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
	-- ── Shop booth ────────────────────────────────────────────────────────────
	local shopModel = WorkspaceModelFind.findNamedModel(Workspace, SHOP_MODEL_NAME)
	if shopModel and shopModel:IsA("Model") then
		shopModel:SetAttribute("IsShopBooth", true)
		purgeLegacyTags(shopModel)

		local npc = findShopkeeperModel(shopModel)
		if npc then
			configureShopkeeper(npc)
		else
			warn("[ShopBooth] No Humanoid found inside Workspace.Shop; skipping shopkeeper configuration.")
		end

		purgeLegacyLabels(shopModel)
	else
		warn("[ShopBooth] Workspace.Shop is missing or not a Model; nothing to configure.")
	end

	-- ── Sell stand ────────────────────────────────────────────────────────────
	local sellModel = WorkspaceModelFind.findNamedModel(Workspace, SELL_MODEL_NAME)
	if sellModel and sellModel:IsA("Model") then
		sellModel:SetAttribute("IsSellStand", true)
		purgeLegacyTags(sellModel)

		local npc = findShopkeeperModel(sellModel)
		if npc then
			configureShopkeeper(npc)
		end

		purgeLegacyLabels(sellModel)
	else
		warn("[ShopBooth] Workspace.Sell is missing or not a Model; skipping sell stand label.")
	end
end

function ShopBoothService.start()
	if started then
		return
	end
	started = true

	-- Defer one frame so any other startup code that mutates the stand models
	-- settles before we touch them. Cheap insurance against race conditions.
	task.defer(function()
		local ok, err = pcall(configureOnce)
		if not ok then
			warn(("[ShopBooth] Failed to configure stands: %s"):format(tostring(err)))
		end
	end)
end

return ShopBoothService
