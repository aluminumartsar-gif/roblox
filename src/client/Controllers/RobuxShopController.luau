--!strict
--[[
	RobuxShopController
	StarterPlayerScripts/Client/Controllers/RobuxShopController

	The Robux Shop: a ROBUX button on the right edge opens a panel with the
	game passes and developer products from Config, each with its icon.

	  * Price: fetched from Roblox for configured ids (so it always matches
	    what the purchase prompt will charge); "SOON" while the id is 0.
	  * Owned passes show OWNED (from Pass_<Key> player attributes, which the
	    server sets).
	  * Buying sends only ("Pass" | "Product", key) to the server, which
	    checks everything and opens the Roblox purchase prompt itself.

	Also adds the VIP chat tag for any player who owns the VIP pass.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Components = script.Parent.Parent:WaitForChild("Components")
local ShopPanel = require(Components:WaitForChild("ShopPanel"))
local Icon = require(Components:WaitForChild("Icon"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))

local RobuxShopController = {}

local localPlayer = Players.LocalPlayer

local GOLD = Color3.fromRGB(255, 200, 60)

type Row = { kind: string, key: string, button: TextButton }
local rows: { Row } = {}
local prices: { [string]: number } = {} -- "Pass:Vip" -> Robux, once fetched
local panel: ShopPanel.Panel
local busy = false

local function itemFor(kind: string, key: string): any
	return if kind == "Pass" then Config.GamePasses[key] else Config.DevProducts[key]
end

local function fetchPrice(kind: string, key: string)
	local item = itemFor(kind, key)
	if item.Id == 0 then
		return
	end
	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(item.Id,
				if kind == "Pass" then Enum.InfoType.GamePass else Enum.InfoType.Product)
		end)
		if ok and info and info.PriceInRobux then
			prices[kind .. ":" .. key] = info.PriceInRobux
		end
	end)
end

local function refresh()
	for _, row in ipairs(rows) do
		local item = itemFor(row.kind, row.key)
		if row.kind == "Pass" and localPlayer:GetAttribute("Pass_" .. row.key) then
			row.button.Text = "OWNED"
			row.button.BackgroundColor3 = Color3.fromRGB(46, 110, 70)
		elseif item.Id == 0 then
			row.button.Text = "SOON"
			row.button.BackgroundColor3 = Color3.fromRGB(70, 72, 80)
		else
			local price = prices[row.kind .. ":" .. row.key]
			row.button.Text = if price then ("R$ " .. price) else "..."
			row.button.BackgroundColor3 = Color3.fromRGB(46, 140, 80)
		end
	end
end

local function buy(kind: string, key: string)
	if busy then
		return
	end
	if kind == "Pass" and localPlayer:GetAttribute("Pass_" .. key) then
		return
	end
	busy = true
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("PromptPurchase") :: RemoteFunction
	local ok, result = pcall(function()
		return remote:InvokeServer(kind, key)
	end)
	busy = false
	if not ok or typeof(result) ~= "table" then
		NotificationController.Show("Couldn't reach the server.", "Error")
	elseif not result.Ok then
		NotificationController.Show(tostring(result.Message or ""), "Error")
	end
	-- On success the Roblox purchase prompt is now open; the server thanks
	-- the player once the purchase actually goes through.
end

local function section(order: number, text: string)
	local row = ShopPanel.Row(panel.List, order, 30)
	row.BackgroundTransparency = 1
	ShopPanel.Label(row, {
		Text = text, Font = Enum.Font.GothamBlack, TextSize = 15, TextColor3 = GOLD,
		Position = UDim2.fromOffset(6, 0), Size = UDim2.new(1, -12, 1, 0),
	})
end

local function itemRow(order: number, kind: string, key: string)
	local item = itemFor(kind, key)
	local row = ShopPanel.Row(panel.List, order, 70)
	row.Name = kind .. "_" .. key
	Icon.new(item.Icon or "Robux", 46, row, {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0),
	})
	ShopPanel.Label(row, {
		Name = "ItemName", Text = item.DisplayName, Font = Enum.Font.GothamBold, TextSize = 17,
		Position = UDim2.fromOffset(66, 8), Size = UDim2.new(1, -180, 0, 22),
	})
	ShopPanel.Label(row, {
		Name = "Description", Text = item.Description or "", TextSize = 13, TextWrapped = true,
		TextColor3 = Color3.fromRGB(200, 190, 170), TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(66, 32), Size = UDim2.new(1, -180, 0, 34),
	})
	local button = ShopPanel.Button(row, {
		Name = "Buy", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(96, 44),
	})
	button.Activated:Connect(function()
		buy(kind, key)
	end)
	table.insert(rows, { kind = kind, key = key, button = button })
	fetchPrice(kind, key)
end

local function buildOpenButton()
	local gui = Instance.new("ScreenGui")
	gui.Name = "RobuxButton"
	gui.ResetOnSpawn = false

	local button = Instance.new("ImageButton")
	button.Name = "Open"
	button.AnchorPoint = Vector2.new(1, 0.5)
	button.Position = UDim2.new(1, -12, 0.45, 0)
	button.Size = UDim2.fromOffset(72, 72)
	button.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
	button.BackgroundTransparency = 0.2
	button.Image = ""
	button.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = button
	local stroke = Instance.new("UIStroke")
	stroke.Color = GOLD
	stroke.Thickness = 2
	stroke.Parent = button

	Icon.new("Robux", 40, button, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 6) })
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position = UDim2.new(0.5, 0, 1, -4)
	label.Size = UDim2.new(1, -4, 0, 16)
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextColor3 = GOLD
	label.Text = "ROBUX"
	label.Parent = button

	button.Activated:Connect(function()
		if panel:IsOpen() then
			panel:Close()
		else
			panel:Open()
		end
	end)

	gui.Parent = localPlayer:WaitForChild("PlayerGui")
end

--- VIP chat tag, shown on every client for any player who owns VIP.
local function setupVipTag()
	TextChatService.OnIncomingMessage = function(message: TextChatMessage)
		local properties = Instance.new("TextChatMessageProperties")
		local source = message.TextSource
		local speaker = source and Players:GetPlayerByUserId(source.UserId)
		if speaker and speaker:GetAttribute("Pass_Vip") then
			properties.PrefixText = "<font color='#FFC83C'>[VIP]</font> " .. message.PrefixText
		end
		return properties
	end
end

function RobuxShopController.Start()
	panel = ShopPanel.new("RobuxShop", "ROBUX SHOP", "Robux")
	panel.OnOpen = refresh

	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end
	section(nextOrder(), "GAME PASSES — forever")
	for _, key in ipairs(Config.GamePassOrder) do
		itemRow(nextOrder(), "Pass", key)
	end
	section(nextOrder(), "ITEMS")
	for _, key in ipairs(Config.DevProductOrder) do
		itemRow(nextOrder(), "Product", key)
	end

	buildOpenButton()
	setupVipTag()

	-- Owned flags and fetched prices change while the panel may be open.
	task.spawn(function()
		while true do
			task.wait(0.5)
			if panel:IsOpen() then
				refresh()
			end
		end
	end)
end

return RobuxShopController
