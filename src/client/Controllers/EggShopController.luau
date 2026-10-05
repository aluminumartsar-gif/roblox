--!strict
--[[
	EggShopController
	StarterPlayerScripts/Client/Controllers/EggShopController

	The Egg Shop, on the STUD kit's Item Shop popup. Opens from the Egg Shop
	counter's prompt, closes when you walk away. One row per egg: name, the
	odds of a Legendary-or-better at heat 0 vs full heat (the patience hook,
	up front), and the price — or LOCKED until the required rebirth.

	Display only; the server re-checks every purchase (price, lock,
	distance, free nest, cash).
]]

local ProximityPromptService = game:GetService("ProximityPromptService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Kit = require(script.Parent.Parent:WaitForChild("Components"):WaitForChild("Kit"))
local ProfileController = require(script.Parent:WaitForChild("ProfileController"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))

local EggShopController = {}

local localPlayer = Players.LocalPlayer

type Row = { eggId: string, buy: GuiButton, body: TextLabel? }
local rows: { Row } = {}
local popup: Kit.Popup
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
	for _, row in ipairs(rows) do
		local egg = Config.Eggs[row.eggId]
		if rebirths < egg.RequiredRebirths then
			Kit.SetButtonText(row.buy, "LOCKED")
			Kit.SetButtonEnabled(row.buy, false)
			Kit.SetText(row.body, string.format("Unlocks at Rebirth %d", egg.RequiredRebirths))
		else
			Kit.SetButtonText(row.buy, "$" .. Config.FormatNumber(egg.Price))
			Kit.SetButtonEnabled(row.buy, cash >= egg.Price)
			Kit.SetText(row.body, string.format("Legendary+ chance:\n%s → %s at max heat",
				formatPercent(topOdds(row.eggId, 0)), formatPercent(topOdds(row.eggId, Config.Heat.Max))))
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
	local gui = Kit.Mount("ItemShopPopup")
	popup = Kit.Popup(gui)
	popup.OnOpen = refresh

	local navBar = Kit.Deep(gui.Container, "NavBar")
	Kit.SetText(navBar:FindFirstChild("Title"), "EGG SHOP")
	local navIcon = navBar:FindFirstChild("Icon")
	if navIcon and navIcon:IsA("ImageLabel") then
		navIcon.Image = Config.Icons.Egg
	end

	-- Use a row that has a cash button as the template; drop the samples.
	local list = Kit.Deep(gui.Container, "ScrollingFrame")
	Kit.FitCanvas(list)
	local template: Instance? = nil
	for _, item in ipairs(list:GetChildren()) do
		if item.Name == "Item" then
			if not template and item:FindFirstChild("BuyCash", true) then
				template = item:Clone()
			end
			item:Destroy()
		end
	end
	assert(template, "Kit Item Shop has no row with a BuyCash button")

	for order, eggId in ipairs(Config.EggOrder) do
		local egg = Config.Eggs[eggId]
		local row = (template :: Instance):Clone() :: Frame
		row.Name = "Egg_" .. eggId
		row.LayoutOrder = order
		Kit.SetText(Kit.Deep(row, "HeaderText"), egg.Name)
		local body = Kit.Deep(row, "BodyText")
		if body then
			body.TextWrapped = true
		end
		local tile = Kit.Deep(row, "Item")
		local icon = tile and tile:FindFirstChild("Icon")
		if icon and icon:IsA("ImageLabel") then
			icon.Image = Config.Icons.Egg
			icon.ImageColor3 = egg.Color:Lerp(Color3.new(1, 1, 1), 0.35)
		end
		Kit.Hide(Kit.Deep(row, "BuyRobux"))
		local buyButton = Kit.Deep(row, "BuyCash") :: GuiButton
		buyButton.Activated:Connect(function()
			buy(eggId)
		end)
		row.Parent = list
		table.insert(rows, { eggId = eggId, buy = buyButton, body = body })
	end
end

function EggShopController.Open(counter: BasePart?)
	popup:Open(counter)
end

function EggShopController.Close()
	popup:Close()
end

function EggShopController.IsOpen(): boolean
	return popup ~= nil and popup:IsOpen()
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
		if popup:IsOpen() then
			refresh()
		end
	end)
end

return EggShopController
