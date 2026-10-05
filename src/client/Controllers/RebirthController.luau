--!strict
--[[
	RebirthController
	StarterPlayerScripts/Client/Controllers/RebirthController

	The rebirth confirmation screen, opened from the plot panel's REBIRTH
	button. Shows the cost, whether the player meets the Rare+ requirement,
	and exactly what they lose, keep and gain — then a confirm button.

	The checklist here is a preview from the latest profile snapshot; the
	server re-checks everything in RebirthService.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local ShopPanel = require(script.Parent.Parent:WaitForChild("Components"):WaitForChild("ShopPanel"))
local ProfileController = require(script.Parent:WaitForChild("ProfileController"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))

local RebirthController = {}

local GOOD = Color3.fromRGB(150, 255, 160)
local BAD = Color3.fromRGB(255, 130, 130)

local panel: ShopPanel.Panel
local costLine: TextLabel
local rareLine: TextLabel
local gainLine: TextLabel
local confirm: TextButton
local busy = false

local function resetsText(): string
	local names = { Cash = "cash", Nests = "eggs & cryptids", Upgrades = "upgrades" }
	local parts = {}
	for _, key in ipairs(Config.Rebirth.Resets) do
		table.insert(parts, names[key] or key)
	end
	return table.concat(parts, ", ")
end

local function refresh()
	local snapshot = ProfileController.Get()
	if not snapshot then
		return
	end
	local rebirths = tonumber(snapshot.Rebirths) or 0
	local cash = tonumber(snapshot.Cash) or 0
	local cost = Config.GetRebirthCost(rebirths)
	local nextRebirth = rebirths + 1

	panel.Title.Text = "REBIRTH " .. nextRebirth

	local canAfford = cash >= cost
	costLine.Text = string.format("Cost: $%s   (you have $%s)", Config.FormatNumber(cost), Config.FormatNumber(cash))
	costLine.TextColor3 = if canAfford then GOOD else BAD

	local minRarity = Config.RarityOrder[Config.RebirthMinRarityIndex]
	local hasRare = false
	for _, slot in ipairs(snapshot.Nests or {}) do
		if typeof(slot) == "table" and slot.Kind == "Creature" and not slot.Away
			and Config.GetRarityIndex(slot.Rarity) >= Config.RebirthMinRarityIndex then
			hasRare = true
		end
	end
	rareLine.Text = string.format("Needs a %s or better cryptid at home: %s", minRarity, if hasRare then "yes" else "no")
	rareLine.TextColor3 = if hasRare then GOOD else BAD

	local unlock = ""
	for _, eggId in ipairs(Config.EggOrder) do
		if Config.Eggs[eggId].RequiredRebirths == nextRebirth then
			unlock = "\nUnlocks the " .. Config.Eggs[eggId].Name .. "!"
		end
	end
	gainLine.Text = string.format("You gain: income +%d%% (total), luck +%d%% (total), a new nest glow.%s",
		math.floor(nextRebirth * Config.Rebirth.IncomeBonusPerRebirth * 100 + 0.5),
		nextRebirth * Config.Luck.PerRebirthPercent, unlock)

	local ready = canAfford and hasRare
	confirm.Text = if ready then "REBIRTH" else "NOT YET"
	confirm.BackgroundColor3 = if ready then Color3.fromRGB(150, 90, 200) else Color3.fromRGB(70, 72, 80)
end

local function doRebirth()
	if busy then
		return
	end
	busy = true
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("DoRebirth") :: RemoteFunction
	local ok, result = pcall(function()
		return remote:InvokeServer()
	end)
	busy = false
	if ok and typeof(result) == "table" then
		NotificationController.Show(tostring(result.Message or ""), if result.Ok then "Success" else "Error")
		if result.Ok then
			panel:Close()
		end
	else
		NotificationController.Show("Couldn't reach the server.", "Error")
	end
end

local function line(order: number, height: number, text: string): TextLabel
	local row = ShopPanel.Row(panel.List, order, height)
	return ShopPanel.Label(row, {
		Text = text, TextSize = 15, TextWrapped = true,
		Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -24, 1, 0),
	})
end

function RebirthController.Open()
	panel:Open()
end

function RebirthController.Start()
	panel = ShopPanel.new("Rebirth", "REBIRTH")
	panel.OnOpen = refresh

	costLine = line(1, 40, "")
	rareLine = line(2, 40, "")
	line(3, 52, "You lose: " .. resetsText() .. ".").TextColor3 = BAD
	line(4, 52, "You keep: your rebirths, codex, game passes and active potions.")
	gainLine = line(5, 64, "")

	local row = ShopPanel.Row(panel.List, 6, 60)
	row.BackgroundTransparency = 1
	confirm = ShopPanel.Button(row, {
		Name = "Confirm", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.7, 0, 0, 48), TextSize = 18,
	})
	confirm.Activated:Connect(doRebirth)

	ProfileController.Changed:Connect(function()
		if panel:IsOpen() then
			refresh()
		end
	end)
end

return RebirthController
