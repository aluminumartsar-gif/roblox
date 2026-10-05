--!strict
--[[
	UpgradeShopController
	StarterPlayerScripts/Client/Controllers/UpgradeShopController

	The Upgrade Shop panel, opened from the Upgrades cabin counter. One row
	per track in Config.UpgradeOrder: level, current value -> next value,
	and the price (or MAX). The server re-checks every purchase.
]]

local ProximityPromptService = game:GetService("ProximityPromptService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local ShopPanel = require(script.Parent.Parent:WaitForChild("Components"):WaitForChild("ShopPanel"))
local Icon = require(script.Parent.Parent:WaitForChild("Components"):WaitForChild("Icon"))
local ProfileController = require(script.Parent:WaitForChild("ProfileController"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))

local UpgradeShopController = {}

local localPlayer = Players.LocalPlayer

local panel: ShopPanel.Panel
local rows: { [string]: { button: TextButton, detail: TextLabel } } = {}
local busy = false

local function formatValue(upgradeId: string, value: number): string
	if upgradeId == "IncubationSpeed" then
		return string.format("x%.2f", value)
	elseif upgradeId == "VaultSize" then
		return "$" .. Config.FormatNumber(value)
	elseif upgradeId == "LockDuration" then
		return value .. "s"
	elseif upgradeId == "NestSlots" then
		return value .. " nests"
	end
	return tostring(value)
end

local function refresh()
	local snapshot = ProfileController.Get()
	local cash = snapshot and tonumber(snapshot.Cash) or 0
	local levels = snapshot and snapshot.Upgrades or {}
	for upgradeId, row in pairs(rows) do
		local upgrade = Config.Upgrades[upgradeId]
		local level = tonumber(levels[upgradeId]) or 1
		local maxLevel = #upgrade.Levels
		local current = formatValue(upgradeId, Config.GetUpgradeValue(upgradeId, level))
		local cost = Config.GetUpgradeNextCost(upgradeId, level)
		if cost then
			local nextValue = formatValue(upgradeId, Config.GetUpgradeValue(upgradeId, level + 1))
			row.detail.Text = string.format("Lv %d/%d   %s  →  %s", level, maxLevel, current, nextValue)
			row.button.Text = "$" .. Config.FormatNumber(cost)
			row.button.BackgroundColor3 = if cash >= cost
				then Color3.fromRGB(46, 140, 80)
				else Color3.fromRGB(110, 60, 60)
		else
			row.detail.Text = string.format("Lv %d/%d   %s", level, maxLevel, current)
			row.button.Text = "MAX"
			row.button.BackgroundColor3 = Color3.fromRGB(70, 72, 80)
		end
	end
end

local function buy(upgradeId: string)
	if busy then
		return
	end
	busy = true
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("BuyUpgrade") :: RemoteFunction
	local ok, result = pcall(function()
		return remote:InvokeServer(upgradeId)
	end)
	busy = false
	if ok and typeof(result) == "table" then
		NotificationController.Show(tostring(result.Message or ""), if result.Ok then "Success" else "Error")
	else
		NotificationController.Show("Couldn't reach the server.", "Error")
	end
end

local function build()
	panel = ShopPanel.new("UpgradeShop", "UPGRADES", "Upgrade")
	panel.OnOpen = refresh

	for order, upgradeId in ipairs(Config.UpgradeOrder) do
		local upgrade = Config.Upgrades[upgradeId]
		local row = ShopPanel.Row(panel.List, order, 76)
		row.Name = upgradeId
		Icon.new(upgrade.Icon or "Upgrade", 42, row, {
			AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0),
		})

		ShopPanel.Label(row, {
			Name = "UpgradeName", Text = upgrade.DisplayName, Font = Enum.Font.GothamBold, TextSize = 17,
			Position = UDim2.fromOffset(62, 6), Size = UDim2.new(1, -178, 0, 22),
		})
		ShopPanel.Label(row, {
			Name = "Description", Text = upgrade.Description, TextSize = 12,
			TextColor3 = Color3.fromRGB(190, 180, 160), TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
			Position = UDim2.fromOffset(62, 28), Size = UDim2.new(1, -178, 0, 26),
		})
		local detail = ShopPanel.Label(row, {
			Name = "Detail", Text = "", TextSize = 13, Font = Enum.Font.GothamBold,
			TextColor3 = Color3.fromRGB(150, 255, 160),
			Position = UDim2.fromOffset(62, 54), Size = UDim2.new(1, -178, 0, 18),
		})
		local button = ShopPanel.Button(row, {
			Name = "Buy", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0),
			Size = UDim2.fromOffset(100, 44),
		})
		button.Activated:Connect(function()
			buy(upgradeId)
		end)

		rows[upgradeId] = { button = button, detail = detail }
	end
end

function UpgradeShopController.Start()
	build()

	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, player: Player)
		if player ~= localPlayer or prompt.Name ~= "ShopPrompt" or prompt:GetAttribute("ShopId") ~= "Upgrades" then
			return
		end
		local counter = prompt.Parent
		if counter and counter:IsA("BasePart") then
			panel:Open(counter)
		end
	end)

	ProfileController.Changed:Connect(function()
		if panel:IsOpen() then
			refresh()
		end
	end)
end

return UpgradeShopController
