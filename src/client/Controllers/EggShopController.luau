--!strict
--[[
	EggShopController
	StarterPlayerScripts/Client/Controllers/EggShopController

	The Egg Shop panel. Opens from the Egg Shop counter's prompt, closes when
	you walk away. Each row shows price, rebirth lock, and the odds of a
	Legendary-or-better at heat 0 vs full heat — the patience hook, up front.

	Everything shown here is read from Config for display only. The server
	re-checks every purchase (price, lock, distance, free nest, cash).
]]

local ProximityPromptService = game:GetService("ProximityPromptService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local ShopPanel = require(script.Parent.Parent:WaitForChild("Components"):WaitForChild("ShopPanel"))
local ProfileController = require(script.Parent:WaitForChild("ProfileController"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))

local EggShopController = {}

local localPlayer = Players.LocalPlayer

local panel: ShopPanel.Panel
local rows: { [string]: { button: TextButton, note: TextLabel } } = {}
local busy = false

local function topOdds(eggId: string, heat: number): number
	local c = Config.GetRarityChances(eggId, heat, 0)
	return (c.Legendary or 0) + (c.Mythic or 0) + (c.Secret or 0)
end

local function formatPercent(p: number): string
	local pct = p * 100
	if pct >= 10 then
		return string.format("%.0f%%", pct)
	elseif pct >= 1 then
		return string.format("%.1f%%", pct)
	end
	return string.format("%.2f%%", pct)
end

local function refresh()
	local snapshot = ProfileController.Get()
	local cash = snapshot and tonumber(snapshot.Cash) or 0
	local rebirths = snapshot and tonumber(snapshot.Rebirths) or 0
	for eggId, row in pairs(rows) do
		local egg = Config.Eggs[eggId]
		if rebirths < egg.RequiredRebirths then
			row.button.Text = "LOCKED"
			row.button.BackgroundColor3 = Color3.fromRGB(70, 72, 80)
			row.note.Text = string.format("Unlocks at Rebirth %d", egg.RequiredRebirths)
		else
			row.button.Text = "$" .. Config.FormatNumber(egg.Price)
			row.button.BackgroundColor3 = if cash >= egg.Price
				then Color3.fromRGB(46, 140, 80)
				else Color3.fromRGB(110, 60, 60)
			row.note.Text = string.format("Legendary+  %s  →  %s at max heat",
				formatPercent(topOdds(eggId, 0)), formatPercent(topOdds(eggId, Config.Heat.Max)))
		end
	end
end

local function buy(eggId: string)
	if busy then
		return
	end
	busy = true
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("BuyEgg") :: RemoteFunction
	local ok, result = pcall(function()
		return remote:InvokeServer(eggId)
	end)
	busy = false
	if ok and typeof(result) == "table" then
		NotificationController.Show(tostring(result.Message or ""), if result.Ok then "Success" else "Error")
	else
		NotificationController.Show("Couldn't reach the server.", "Error")
	end
end

local function build()
	panel = ShopPanel.new("EggShop", "EGG SHOP", "Egg")
	panel.OnOpen = refresh

	for order, eggId in ipairs(Config.EggOrder) do
		local egg = Config.Eggs[eggId]
		local row = ShopPanel.Row(panel.List, order)
		row.Name = eggId

		local swatch = Instance.new("Frame")
		swatch.Size = UDim2.fromOffset(36, 46)
		swatch.Position = UDim2.fromOffset(10, 9)
		swatch.BackgroundColor3 = egg.Color
		swatch.Parent = row
		local swatchCorner = Instance.new("UICorner")
		swatchCorner.CornerRadius = UDim.new(0.5, 0)
		swatchCorner.Parent = swatch

		ShopPanel.Label(row, {
			Name = "EggName", Text = egg.Name, Font = Enum.Font.GothamBold, TextSize = 17,
			Position = UDim2.fromOffset(56, 8), Size = UDim2.new(1, -170, 0, 24),
		})
		local note = ShopPanel.Label(row, {
			Name = "Note", Text = "", TextSize = 13, TextColor3 = Color3.fromRGB(200, 190, 170),
			TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
			Position = UDim2.fromOffset(56, 32), Size = UDim2.new(1, -170, 0, 30),
		})
		local button = ShopPanel.Button(row, {
			Name = "Buy", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0),
			Size = UDim2.fromOffset(100, 44),
		})
		button.Activated:Connect(function()
			buy(eggId)
		end)

		rows[eggId] = { button = button, note = note }
	end
end

function EggShopController.Open(counter: BasePart?)
	panel:Open(counter)
end

function EggShopController.Close()
	panel:Close()
end

function EggShopController.IsOpen(): boolean
	return panel ~= nil and panel:IsOpen()
end

function EggShopController.Start()
	build()

	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, player: Player)
		if player ~= localPlayer or prompt.Name ~= "ShopPrompt" or prompt:GetAttribute("ShopId") ~= "Eggs" then
			return
		end
		local counter = prompt.Parent
		if counter and counter:IsA("BasePart") then
			EggShopController.Open(counter)
		end
	end)

	ProfileController.Changed:Connect(function()
		if panel:IsOpen() then
			refresh()
		end
	end)
end

return EggShopController
