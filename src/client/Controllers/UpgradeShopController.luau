--!strict
--[[
	UpgradeShopController
	StarterPlayerScripts/Client/Controllers/UpgradeShopController

	The Upgrade Shop, on the STUD kit's Item Upgrades popup, opened from the
	Upgrades cabin counter. One row per track in Config.UpgradeOrder:
	icon + level, current value -> next value, and the price (or MAX).
	The server re-checks every purchase.
]]

local ProximityPromptService = game:GetService("ProximityPromptService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Kit = require(script.Parent.Parent:WaitForChild("Components"):WaitForChild("Kit"))
local ProfileController = require(script.Parent:WaitForChild("ProfileController"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))

local UpgradeShopController = {}

local localPlayer = Players.LocalPlayer

type Row = {
	upgradeId: string,
	level: TextLabel?,
	current: TextLabel?,
	nextValue: TextLabel?,
	buy: GuiButton,
}
local rows: { Row } = {}
local popup: Kit.Popup
local busy = false

local function formatValue(upgradeId: string, value: number): string
	if upgradeId == "IncubationSpeed" then
		return string.format("x%.2f", value)
	elseif upgradeId == "VaultSize" then
		return "$" .. Config.FormatNumber(value)
	elseif upgradeId == "LockDuration" then
		return value .. "s"
	end
	return tostring(value)
end

local function refresh()
	local snapshot = ProfileController.Get()
	local cash = snapshot and tonumber(snapshot.Cash) or 0
	local levels = snapshot and snapshot.Upgrades or {}
	for _, row in ipairs(rows) do
		local level = tonumber(levels[row.upgradeId]) or 1
		local cost = Config.GetUpgradeNextCost(row.upgradeId, level)
		Kit.SetText(row.level, "Lv" .. level)
		Kit.SetText(row.current, formatValue(row.upgradeId, Config.GetUpgradeValue(row.upgradeId, level)))
		if cost then
			Kit.SetText(row.nextValue, formatValue(row.upgradeId, Config.GetUpgradeValue(row.upgradeId, level + 1)))
			Kit.SetButtonText(row.buy, "$" .. Config.FormatNumber(cost))
			Kit.SetButtonEnabled(row.buy, cash >= cost)
		else
			Kit.SetText(row.nextValue, "MAX")
			Kit.SetButtonText(row.buy, "MAX")
			Kit.SetButtonEnabled(row.buy, false)
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
	local gui = Kit.Mount("ItemUpgradesPopup")
	popup = Kit.Popup(gui)
	popup.OnOpen = refresh

	local navBar = Kit.Deep(gui.Container, "NavBar")
	Kit.SetText(navBar:FindFirstChild("Title"), "UPGRADES")
	local navIcon = navBar:FindFirstChild("Icon")
	if navIcon and navIcon:IsA("ImageLabel") then
		navIcon.Image = Config.Icons.Upgrade
	end

	local list = Kit.Deep(gui.Container, "ScrollingFrame")
	Kit.FitCanvas(list)
	local template: Instance? = nil
	for _, item in ipairs(list:GetChildren()) do
		if item.Name == "Item" then
			template = template or item:Clone()
			item:Destroy()
		end
	end
	assert(template, "Kit Item Upgrades popup has no rows")

	for order, upgradeId in ipairs(Config.UpgradeOrder) do
		local upgrade = Config.Upgrades[upgradeId]
		local row = (template :: Instance):Clone() :: Frame
		row.Name = "Upgrade_" .. upgradeId
		row.LayoutOrder = order

		local background = row:FindFirstChild("Background") :: Instance
		Kit.SetText(background:FindFirstChildWhichIsA("TextLabel"), upgrade.DisplayName)

		-- Inside the background: the icon tile (has an Icon) and the
		-- "next value" box (doesn't). The "current value" box sits outside.
		local tile, nextBox
		for _, child in ipairs(background:GetChildren()) do
			if child.Name == "Item" then
				if child:FindFirstChild("Icon") then
					tile = child
				else
					nextBox = child
				end
			end
		end
		local currentBox = row:FindFirstChild("Item")

		local tileIcon = tile and tile:FindFirstChild("Icon")
		if tileIcon and tileIcon:IsA("ImageLabel") and upgrade.Icon then
			tileIcon.Image = Config.Icons[upgrade.Icon]
		end

		Kit.Hide(background:FindFirstChild("BuyRobux"))
		local buyButton = background:FindFirstChild("BuyCash") :: GuiButton
		buyButton.Activated:Connect(function()
			buy(upgradeId)
		end)

		row.Parent = list
		table.insert(rows, {
			upgradeId = upgradeId,
			level = tile and tile:FindFirstChildWhichIsA("TextLabel"),
			current = currentBox and currentBox:FindFirstChildWhichIsA("TextLabel"),
			nextValue = nextBox and nextBox:FindFirstChildWhichIsA("TextLabel"),
			buy = buyButton,
		})
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
			popup:Open(counter)
		end
	end)

	ProfileController.Changed:Connect(function()
		if popup:IsOpen() then
			refresh()
		end
	end)
end

return UpgradeShopController
