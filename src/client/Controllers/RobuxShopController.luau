--!strict
--[[
	RobuxShopController
	StarterPlayerScripts/Client/Controllers/RobuxShopController

	The Robux Store: a "campfire field kit" window (Components/Window) opened
	from the HUD's Store tile and the "+" next to the cash. One scrolling
	list of sections, in the order Config.UI.Shops.Store.Sections gives:

	  Boosts        -> Luck Potion, Hatch Boost, Instant Hatch   (cards)
	  Game Passes   -> the 5 game passes                         (cards)
	  Cash          -> the 3 cash packs                          (cards)
	  Starter Pack  -> 3-Egg Bundle                              (wide banner)
	  Defense       -> Emergency Lock                            (wide banner)

	Every item shows its icon, name, a highlight line (minutes for a potion,
	"+$25K" for a cash pack...), its description and a blue Robux button
	with the price Roblox reports once the item's id is set. Until then the
	item shows a SOON tag; a pass you already own shows OWNED. Buying sends
	only ("Pass" | "Product", key) to the server, which checks everything
	and opens the Roblox prompt itself.

	Also: the VIP chat tag, and Open / Buy / PriceText for other UI (the
	HUD's quick-buy offers use them).
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Components = script.Parent.Parent:WaitForChild("Components")
local Theme = require(Components:WaitForChild("Theme"))
local UI = require(Components:WaitForChild("UI"))
local Window = require(Components:WaitForChild("Window"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))

local RobuxShopController = {}

local localPlayer = Players.LocalPlayer
local C = Theme.Colors
local tuning = Config.UI.Shops.Store

-- One buy slot per item: the Robux button, or the OWNED / SOON tag in its place.
type Entry = { kind: string, key: string, button: TextButton, tag: Frame }
local entries: { Entry } = {}
local prices: { [string]: number } = {}
local window: Window.Window
local busy = false

local function itemFor(kind: string, key: string): any
	return if kind == "Pass" then Config.GamePasses[key] else Config.DevProducts[key]
end

local function fetchPrice(kind: string, key: string)
	local item = itemFor(kind, key)
	local priceKey = kind .. ":" .. key
	if item.Id == 0 or prices[priceKey] then
		return
	end
	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(item.Id,
				if kind == "Pass" then Enum.InfoType.GamePass else Enum.InfoType.Product)
		end)
		if ok and info and info.PriceInRobux then
			prices[priceKey] = info.PriceInRobux
		elseif not ok then
			warn(string.format("[SAC/Store] GetProductInfo failed for %s %s (id %s): %s",
				kind, key, tostring(item.Id), tostring(info)))
		end
	end)
end

--- "Owned" (a pass you have), "Soon" (no id set yet) or "Price".
local function itemState(kind: string, key: string): string
	local item = itemFor(kind, key)
	if kind == "Pass" and localPlayer:GetAttribute("Pass_" .. key) then
		return "Owned"
	elseif item.Id == 0 then
		return "Soon"
	end
	return "Price"
end

--- What a buy button should say for this item right now.
function RobuxShopController.PriceText(kind: string, key: string): string
	local state = itemState(kind, key)
	if state == "Owned" then
		return "OWNED"
	elseif state == "Soon" then
		return "SOON"
	end
	local price = prices[kind .. ":" .. key]
	return if price then ("R$" .. price) else "..."
end

function RobuxShopController.Buy(kind: string, key: string)
	if busy or (kind == "Pass" and localPlayer:GetAttribute("Pass_" .. key)) then
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
end

function RobuxShopController.Open()
	window:Open()
end

local function refresh()
	for _, entry in ipairs(entries) do
		local state = itemState(entry.kind, entry.key)
		entry.button.Visible = state == "Price"
		entry.tag.Visible = state ~= "Price"
		if state == "Owned" then
			UI.SetPill(entry.tag, "OWNED", C.Moss)
		elseif state == "Soon" then
			UI.SetPill(entry.tag, "SOON", C.TextDim)
		else
			-- The button already carries the Robux icon, so drop PriceText's "R$".
			local text = string.gsub(RobuxShopController.PriceText(entry.kind, entry.key), "^R%$", "")
			UI.SetButtonText(entry.button, text)
		end
	end
end

--------------------------------------------------------------------------
-- Building the screen
--------------------------------------------------------------------------

--- Icon and highlight colour for an item.
local function accentFor(kind: string, item: any): Color3
	if kind == "Pass" then
		return C.EmberBright
	elseif item.Kind == "Cash" then
		return C.Moss
	elseif item.Kind == "Buff" then
		return C.Moon
	end
	return C.Ember
end

--- The short line under an item's name, or nil.
local function highlightFor(kind: string, item: any): string?
	if kind == "Pass" then
		return nil
	elseif item.Kind == "Buff" then
		return string.format("%d minutes", item.Duration // 60)
	elseif item.Kind == "Cash" then
		return "+$" .. Config.FormatNumber(item.Amount)
	elseif item.Effect == "InstantHatch" then
		return "Your best egg"
	elseif item.Effect == "ExtendLock" then
		return string.format("Lock your camp NOW for %d min", Config.Plot.EmergencyLockBonus // 60)
	elseif item.Effect == "GrantEggs" then
		local egg = Config.Eggs[item.EggId]
		return string.format("%d x %s", item.Count, if egg then egg.Name else "Egg")
	end
	return nil
end

--- The Robux button for an item, with its OWNED / SOON tag in the same spot.
local function buySlot(kind: string, key: string, props: { [string]: any }): Frame
	local slot = UI.new("Frame", {
		Name = "BuySlot",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(tuning.PriceButton.X, tuning.PriceButton.Y),
	}) :: Frame
	local button = UI.Button({
		Name = "Buy",
		Variant = "Moon",
		Icon = "Robux",
		Text = "...",
		TextSize = tuning.PriceTextSize,
		Size = UDim2.fromScale(1, 1),
		OnClick = function()
			RobuxShopController.Buy(kind, key)
		end,
		Parent = slot,
	})
	local tag = UI.Pill({
		Name = "Tag",
		Text = "SOON",
		Color = C.TextDim,
		TextSize = 16,
		Height = math.floor(tuning.PriceButton.Y * 0.75),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Visible = false,
		Parent = slot,
	})
	for name, value in pairs(props) do
		(slot :: any)[name] = value
	end
	table.insert(entries, { kind = kind, key = key, button = button, tag = tag })
	fetchPrice(kind, key)
	return slot
end

local function iconTile(iconName: string, size: number, accent: Color3, props: { [string]: any }): Frame
	local tile = UI.Inset({ Name = "IconTile", Size = UDim2.fromOffset(size, size) })
	UI.Icon(iconName, math.floor(size * 0.65), {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		ImageColor3 = accent,
		Parent = tile,
	})
	for name, value in pairs(props) do
		(tile :: any)[name] = value
	end
	return tile
end

--- A grid card: icon, name, highlight, description, buy button at the bottom.
local function itemCard(kind: string, key: string, order: number, parent: Instance)
	local item = itemFor(kind, key)
	local accent = accentFor(kind, item)
	local card = UI.Card({ Name = key, Accent = accent, LayoutOrder = order, Parent = parent })

	local priceHeight = tuning.PriceButton.Y
	local content = UI.new("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, -(priceHeight + 12)),
		Parent = card,
	}, {
		UI.Padding({ Top = 12, Left = 10, Right = 10 }),
		UI.List({ HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = 4 }),
	})
	iconTile(item.Icon, 52, accent, { LayoutOrder = 1, Parent = content })
	UI.Text({
		Name = "ItemName",
		Role = "Heading",
		Text = item.DisplayName,
		TextSize = 20,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, 0, 0, 24),
		LayoutOrder = 2,
		Parent = content,
	})
	local highlight = highlightFor(kind, item)
	if highlight then
		UI.Text({
			Name = "Highlight",
			Role = "Heading",
			Weight = "SemiBold",
			Text = highlight,
			TextSize = 16,
			TextColor3 = accent,
			Size = UDim2.new(1, 0, 0, 20),
			LayoutOrder = 3,
			Parent = content,
		})
	end
	UI.Text({
		Name = "Description",
		Role = "Body",
		Text = item.Description,
		TextSize = 14,
		TextColor3 = C.TextDim,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Size = UDim2.new(1, 0, 0, 54),
		LayoutOrder = 4,
		Parent = content,
	})

	buySlot(kind, key, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -10),
		Parent = card,
	})
end

--- A wide one-item row: icon on the left, text in the middle, buy on the right.
local function itemBanner(kind: string, key: string, order: number, parent: Instance)
	local item = itemFor(kind, key)
	local accent = accentFor(kind, item)
	local card = UI.Card({
		Name = key,
		Accent = accent,
		Size = UDim2.new(1, 0, 0, tuning.BannerHeight),
		LayoutOrder = order,
		Parent = parent,
	})
	local tileSize = 64
	local left = 14 + tileSize + 14
	iconTile(item.Icon, tileSize, accent, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 14, 0.5, 0),
		Parent = card,
	})
	local text = UI.new("Frame", {
		Name = "Text",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, left, 0.5, 0),
		Size = UDim2.new(1, -(left + tuning.PriceButton.X + 28), 0, 72),
		Parent = card,
	}, {
		UI.List({ Padding = 2, VerticalAlignment = Enum.VerticalAlignment.Center }),
	})
	UI.Text({
		Name = "ItemName",
		Role = "Heading",
		Text = item.DisplayName,
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 26),
		LayoutOrder = 1,
		Parent = text,
	})
	local highlight = highlightFor(kind, item)
	if highlight then
		UI.Text({
			Name = "Highlight",
			Role = "Heading",
			Weight = "SemiBold",
			Text = highlight,
			TextSize = 16,
			TextColor3 = accent,
			TextXAlignment = Enum.TextXAlignment.Left,
			Size = UDim2.new(1, 0, 0, 20),
			LayoutOrder = 2,
			Parent = text,
		})
	end
	UI.Text({
		Name = "Description",
		Role = "Body",
		Text = item.Description,
		TextSize = 14,
		TextColor3 = C.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, 0, 0, 20),
		LayoutOrder = 3,
		Parent = text,
	})

	buySlot(kind, key, {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Parent = card,
	})
end

local function sectionHeader(title: string, iconName: string, order: number, parent: Instance)
	local header = UI.new("Frame", {
		Name = "Header_" .. title,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 32),
		LayoutOrder = order,
		Parent = parent,
	})
	UI.Icon(iconName, 22, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 2, 0.5, -1),
		ImageColor3 = C.Ember,
		Parent = header,
	})
	UI.Text({
		Name = "Title",
		Role = "Heading",
		Text = string.upper(title),
		TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(32, 0),
		Size = UDim2.new(1, -32, 1, -2),
		Parent = header,
	})
	UI.Divider({
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Parent = header,
	})
end

local function build()
	window = Window.new({
		Name = "Store",
		Title = "Store",
		Icon = "Shop",
		Size = tuning.Size,
		FlexHeight = true, -- the list scrolls: on a phone keep the text size, shorten the window
	})
	window.OnOpen = refresh

	-- The canvas grows with what's in it (AutomaticCanvasSize).
	local list = UI.ScrollList({ Name = "List", Gap = 10, Parent = window.Body })
	for i, section in ipairs(tuning.Sections) do
		sectionHeader(section.Title, section.Icon, i * 2 - 1, list)
		local items = UI.new("Frame", {
			Name = "Items_" .. section.Title,
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = i * 2,
			Parent = list,
		})
		if section.Style == "Banner" then
			UI.List({ Padding = tuning.CardGap }).Parent = items
		else
			UI.Grid({
				CellSize = UDim2.fromOffset(tuning.CardSize.X, tuning.CardSize.Y),
				CellPadding = UDim2.fromOffset(tuning.CardGap, tuning.CardGap),
				Parent = items,
			})
		end
		for order, key in ipairs(section.Keys) do
			if itemFor(section.Kind, key) == nil then
				warn("[SAC/Store] Unknown " .. section.Kind .. " '" .. key .. "' in Config.UI.Shops.Store.Sections")
			elseif section.Style == "Banner" then
				itemBanner(section.Kind, key, order, items)
			else
				itemCard(section.Kind, key, order, items)
			end
		end
	end
	refresh()
end

--- VIP chat tag, shown on every client for any player who owns VIP.
local function setupVipTag()
	local prefix = string.format("<font color='#%s'>%s</font> ", tuning.VipChatColor:ToHex(), tuning.VipChatTag)
	TextChatService.OnIncomingMessage = function(message: TextChatMessage)
		local properties = Instance.new("TextChatMessageProperties")
		local source = message.TextSource
		local speaker = source and Players:GetPlayerByUserId(source.UserId)
		if speaker and speaker:GetAttribute("Pass_Vip") then
			properties.PrefixText = prefix .. message.PrefixText
		end
		return properties
	end
end

function RobuxShopController.Start()
	build()
	setupVipTag()
	-- Prices arrive and passes get bought while the shop may be open.
	task.spawn(function()
		while true do
			task.wait(tuning.RefreshInterval)
			if window:IsOpen() then
				refresh()
			end
		end
	end)
end

return RobuxShopController
