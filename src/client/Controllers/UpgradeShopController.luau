--!strict
--[[
	UpgradeShopController
	StarterPlayerScripts/Client/Controllers/UpgradeShopController

	The Upgrade Shop: a "campfire field kit" window (Components/Window)
	opened by the "Browse" prompt on the Upgrades cabin counter. Walking
	away from the counter closes it.

	One row per track in Config.UpgradeOrder: the upgrade's icon, its name
	and level ("Lv 3"), current value -> next value (or MAX), and a green
	cash button with the price — greyed out while you can't afford it, MAX
	when the track is full. The icon pops when a level is bought.

	Buying sends only the upgrade id (BuyUpgrade); the server re-checks
	everything (real id, not maxed, at the counter, can afford) and its
	answer is shown as a toast.
]]

local ProximityPromptService = game:GetService("ProximityPromptService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Components = script.Parent.Parent:WaitForChild("Components")
local Theme = require(Components:WaitForChild("Theme"))
local UI = require(Components:WaitForChild("UI"))
local Window = require(Components:WaitForChild("Window"))
local ProfileController = require(script.Parent:WaitForChild("ProfileController"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))

local UpgradeShopController = {}

local localPlayer = Players.LocalPlayer
local C = Theme.Colors
local tuning = Config.UI.Shops.Upgrades

type Row = {
	upgradeId: string,
	level: TextLabel,
	current: TextLabel,
	nextValue: TextLabel,
	buy: TextButton,
	pop: UIScale,
	shownLevel: number?,
}
local rows: { Row } = {}
local window: Window.Window
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
		row.level.Text = "Lv " .. level
		row.current.Text = formatValue(row.upgradeId, Config.GetUpgradeValue(row.upgradeId, level))
		if cost then
			row.nextValue.Text = formatValue(row.upgradeId, Config.GetUpgradeValue(row.upgradeId, level + 1))
			row.nextValue.TextColor3 = C.Moss
			UI.SetButtonText(row.buy, "$" .. Config.FormatNumber(cost))
			UI.SetButtonEnabled(row.buy, cash >= cost)
		else
			row.nextValue.Text = "MAX"
			row.nextValue.TextColor3 = C.EmberBright
			UI.SetButtonText(row.buy, "MAX")
			UI.SetButtonEnabled(row.buy, false)
		end
		-- A level went up while the shop is showing: pop the icon.
		local shown = row.shownLevel
		if shown and level > shown and window:IsOpen() then
			row.pop.Scale = tuning.PunchScale
			UI.Tween(row.pop, tuning.PunchTime, { Scale = 1 }, Enum.EasingStyle.Back)
		end
		row.shownLevel = level
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

local function buildRow(upgradeId: string, order: number, parent: Instance)
	local upgrade = Config.Upgrades[upgradeId]
	local height = tuning.RowHeight
	local card = UI.Card({
		Name = "Upgrade_" .. upgradeId,
		Size = UDim2.new(1, 0, 0, height),
		LayoutOrder = order,
		Parent = parent,
	})

	-- Icon tile (anchored at its centre so the pop grows evenly).
	local tileSize = height - 18
	local tile = UI.Inset({
		Name = "IconTile",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 10 + math.floor(tileSize / 2), 0.5, 0),
		Size = UDim2.fromOffset(tileSize, tileSize),
		Parent = card,
	})
	local pop = UI.new("UIScale", { Name = "Pop", Parent = tile }) :: UIScale
	UI.Icon(upgrade.Icon, math.floor(tileSize * 0.64), {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		ImageColor3 = C.EmberBright,
		Parent = tile,
	})

	-- Name and level.
	local left = 10 + tileSize + 12
	UI.Text({
		Name = "UpgradeName",
		Role = "Heading",
		Text = upgrade.DisplayName,
		TextSize = 21,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.new(0, left, 0.5, -24),
		Size = UDim2.fromOffset(170, 26),
		Parent = card,
	})
	local level = UI.Text({
		Name = "Level",
		Role = "Heading",
		Weight = "SemiBold",
		Text = "Lv 1",
		TextSize = 16,
		TextColor3 = C.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.new(0, left, 0.5, 2),
		Size = UDim2.fromOffset(170, 20),
		Parent = card,
	})

	-- Current value -> next value.
	local buySize = tuning.BuyButton
	local values = UI.new("Frame", {
		Name = "Values",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, left + 180, 0.5, 0),
		Size = UDim2.new(1, -(left + 180 + buySize.X + 24), 0, 30),
		Parent = card,
	}, {
		UI.List({
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = 6,
		}),
	})
	local function valueLabel(name: string, order: number, color: Color3): TextLabel
		return UI.Text({
			Name = name,
			Role = "Heading",
			Text = "",
			TextSize = 20,
			TextColor3 = color,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromScale(0, 1),
			LayoutOrder = order,
			Parent = values,
		})
	end
	local current = valueLabel("Current", 1, C.Text)
	UI.Icon("ChevronRight", 18, { LayoutOrder = 2, ImageColor3 = C.TextDim, Parent = values })
	local nextValue = valueLabel("Next", 3, C.Moss)

	-- Buy button. Greyed out is only a look: a tap still asks the server,
	-- which answers with the reason (not enough cash, already maxed).
	local button = UI.Button({
		Name = "Buy",
		Variant = "Cash",
		Text = "$0",
		TextSize = 20,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(buySize.X, buySize.Y),
		OnClick = function()
			buy(upgradeId)
		end,
		Parent = card,
	})

	table.insert(rows, {
		upgradeId = upgradeId,
		level = level,
		current = current,
		nextValue = nextValue,
		buy = button,
		pop = pop,
		shownLevel = nil,
	})
end

local function build()
	window = Window.new({
		Name = "Upgrades",
		Title = "Upgrades",
		Icon = "Upgrade",
		Size = tuning.Size,
		FlexHeight = true, -- the list scrolls: on a phone keep the text size, shorten the window
	})
	window.OnOpen = refresh

	local list = UI.ScrollList({ Name = "List", Gap = tuning.RowGap, Parent = window.Body })
	for order, upgradeId in ipairs(Config.UpgradeOrder) do
		buildRow(upgradeId, order, list)
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
			window:Open(counter)
		end
	end)

	ProfileController.Changed:Connect(function()
		if window:IsOpen() then
			refresh()
		end
	end)
end

return UpgradeShopController
