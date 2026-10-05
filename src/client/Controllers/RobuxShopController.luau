--!strict
--[[
	RobuxShopController
	StarterPlayerScripts/Client/Controllers/RobuxShopController

	The Robux Shop, built on the STUD kit's Store screen. The kit's sections
	are found by what they contain (not their order), then filled from
	Config:

	  Featured (3 coloured cards)  -> Luck Potion, Nest Warmer, Max Heat
	  Gamepasses                   -> the 5 game passes
	  Currency                     -> the 3 cash packs
	  Starter Pack banner          -> 3-Egg Bundle
	  "Server Luck" card           -> Emergency Lock (section renamed)

	Prices come from Roblox once an item's id is set ("SOON" until then);
	owned passes show OWNED. Buying sends only ("Pass" | "Product", key) to
	the server, which checks everything and opens the Roblox prompt itself.

	Also: the VIP chat tag, and Open / Buy / PriceText for other UI (the
	HUD's quick-buy offers use them).
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Kit = require(script.Parent.Parent:WaitForChild("Components"):WaitForChild("Kit"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))

local RobuxShopController = {}

local localPlayer = Players.LocalPlayer

local FEATURED = { "LuckPotion", "NestWarmer", "MaxHeat" }
local CURRENCY = { "CashSmall", "CashMedium", "CashLarge" }
-- Which kit pass card each pass uses (the 5th is a copy of the Green card).
local PASS_CARDS = {
	DoubleCash = "Gamepass [Green]",
	ExtraNests = "Gamepass [Purple]",
	Vip = "Gamepass [Orange]",
	AutoCollect = "Gamepass [Red]",
	ExtendedLock = "Gamepass [Green]", -- cloned
}

type Entry = { kind: string, key: string, button: Instance }
local entries: { Entry } = {}
local prices: { [string]: number } = {}
local popup: Kit.Popup
local busy = false

local function itemFor(kind: string, key: string): any
	return if kind == "Pass" then Config.GamePasses[key] else Config.DevProducts[key]
end

local function fetchPrice(kind: string, key: string)
	local item = itemFor(kind, key)
	if item.Id == 0 or prices[kind .. ":" .. key] then
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

--- What a buy button should say for this item right now.
function RobuxShopController.PriceText(kind: string, key: string): string
	local item = itemFor(kind, key)
	if kind == "Pass" and localPlayer:GetAttribute("Pass_" .. key) then
		return "OWNED"
	elseif item.Id == 0 then
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
	popup:Open()
end

local function refresh()
	for _, entry in ipairs(entries) do
		Kit.SetButtonText(entry.button, RobuxShopController.PriceText(entry.kind, entry.key))
	end
end

local function register(kind: string, key: string, button: Instance?)
	if not button or not button:IsA("GuiButton") then
		return
	end
	table.insert(entries, { kind = kind, key = key, button = button })
	button.Activated:Connect(function()
		RobuxShopController.Buy(kind, key)
	end)
	fetchPrice(kind, key)
end

local function setIcon(image: Instance?, iconName: string?)
	if image and iconName and Config.Icons[iconName] and (image:IsA("ImageLabel") or image:IsA("ImageButton")) then
		image.Image = Config.Icons[iconName]
	end
end

--------------------------------------------------------------------------
-- Filling each kit section
--------------------------------------------------------------------------

local function fillFeatured(content: Instance)
	local cards = Kit.ChildrenNamed(content, "EggFrame")
	table.sort(cards, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	for i, card in ipairs(cards) do
		local key = FEATURED[i]
		if not key then
			Kit.Hide(card)
			continue
		end
		local product = Config.DevProducts[key]
		local names = Kit.ChildrenNamed(card, "ItemName")
		Kit.SetText(names[1], product.DisplayName)
		for j = 2, #names do
			Kit.Hide(names[j])
		end
		local amounts = Kit.ChildrenNamed(card, "Amount")
		local label = if product.Kind == "Buff" then string.format("%d minutes", product.Duration // 60) else "Your best egg"
		Kit.SetText(amounts[1], label)
		for j = 2, #amounts do
			Kit.Hide(amounts[j])
		end
		local buys = Kit.ChildrenNamed(card, "Buy")
		for j = 2, #buys do
			Kit.Hide(buys[j])
		end
		register("Product", key, buys[1])
		local clipping = card:FindFirstChild("ClippingItems")
		setIcon(clipping and clipping:FindFirstChild("Item"), product.Icon)
		-- The kit's scrolling preview strip shows its own sample items.
		Kit.Hide(card:FindFirstChild("Container"))
	end
end

-- The kit's card sections are fixed-height boxes laid out for two rows of
-- cards, with card heights as a fraction of the box. If our cards wrap to
-- more rows, make the box taller and the cards proportionally shorter
-- (so each card keeps its on-screen size) instead of letting them spill.
local KIT_SECTION_ROWS = 2

local function fitRows(content: Instance)
	local layout = content:FindFirstChildOfClass("UIListLayout")
	local aspect = content:FindFirstChildOfClass("UIAspectRatioConstraint")
	if not layout or not aspect then
		return
	end
	local cards: { GuiObject } = {}
	for _, child in ipairs(content:GetChildren()) do
		if child:IsA("GuiObject") and child.Visible then
			table.insert(cards, child)
		end
	end
	local index: { [GuiObject]: number } = {}
	for i, card in ipairs(cards) do
		index[card] = i
	end
	table.sort(cards, function(a, b)
		if a.LayoutOrder ~= b.LayoutOrder then
			return a.LayoutOrder < b.LayoutOrder
		end
		return index[a] < index[b]
	end)
	local gap = layout.Padding.Scale
	local rows, x = 0, 0
	for _, card in ipairs(cards) do
		local width = card.Size.X.Scale
		if rows == 0 or x + gap + width > 1.001 then
			rows += 1
			x = width
		else
			x += gap + width
		end
	end
	if rows <= KIT_SECTION_ROWS then
		return
	end
	local grow = rows / KIT_SECTION_ROWS
	aspect.AspectRatio /= grow
	for _, card in ipairs(cards) do
		card.Size = UDim2.new(card.Size.X.Scale, card.Size.X.Offset, card.Size.Y.Scale / grow, card.Size.Y.Offset)
	end
end

local function fillPasses(content: Instance)
	-- Make the extra card first, while the Green template is untouched.
	local green = content:FindFirstChild("Gamepass [Green]")
	local extra = green and green:Clone()
	if extra then
		extra.Name = "Gamepass [Extra]"
		extra.LayoutOrder = 99
		extra.Parent = content
	end
	local iconTemplate = green and green:FindFirstChild("ClippingItems") and green.ClippingItems:FindFirstChild("Icon")

	local used: { [Instance]: boolean } = {}
	for _, key in ipairs(Config.GamePassOrder) do
		local pass = Config.GamePasses[key]
		local card = if key == "ExtendedLock" then extra else content:FindFirstChild(PASS_CARDS[key])
		if card then
			used[card] = true
			local names = Kit.ChildrenNamed(card, "ItemName")
			Kit.SetText(names[1], pass.DisplayName)
			Kit.SetText(names[2], pass.Description)
			for j = 3, #names do
				Kit.Hide(names[j])
			end
			if names[2] then
				names[2].TextWrapped = true
			end
			Kit.Hide(card:FindFirstChild("GiftBtn"))
			local clipping = card:FindFirstChild("ClippingItems")
			if clipping and not clipping:FindFirstChild("Icon") and iconTemplate then
				iconTemplate:Clone().Parent = clipping -- the Red card ships without one
			end
			card.Visible = true -- the kit ships the Red card hidden
			setIcon(clipping and clipping:FindFirstChild("Icon"), pass.Icon)
			register("Pass", key, card:FindFirstChild("Buy"))
		end
	end
	for _, child in ipairs(content:GetChildren()) do
		if child:IsA("GuiObject") and not used[child] then
			child.Visible = false
		end
	end
	fitRows(content)
end

local function fillCurrency(content: Instance)
	local cards = {}
	for _, child in ipairs(content:GetChildren()) do
		if child:IsA("GuiObject") then
			table.insert(cards, child)
		end
	end
	-- Order by the amount printed on the kit's sample card ("+$100k" <
	-- "+$500k" < "+$1M" ...), so the cheapest pack takes the first card.
	local function amountOf(card: Instance): number
		local label = card:FindFirstChild("ItemName")
		local text = if label and label:IsA("TextLabel") then label.Text else ""
		local number, suffix = text:match("([%d%.]+)%s*([kKmMbB]?)")
		local value = tonumber(number) or math.huge
		local scale = ({ k = 1e3, K = 1e3, m = 1e6, M = 1e6, b = 1e9, B = 1e9 })[suffix or ""] or 1
		return value * scale
	end
	table.sort(cards, function(a, b)
		return amountOf(a) < amountOf(b)
	end)
	for i, card in ipairs(cards) do
		local key = CURRENCY[i]
		if not key then
			card.Visible = false
			continue
		end
		local product = Config.DevProducts[key]
		Kit.SetText(card:FindFirstChild("ItemName"), "+$" .. Config.FormatNumber(product.Amount))
		Kit.Hide(card:FindFirstChild("GiftBtn"))
		register("Product", key, card:FindFirstChild("Buy"))
	end
end

local function fillStarterPack(content: Instance)
	local card = content:FindFirstChild("StarterPack")
	if not card then
		return
	end
	local product = Config.DevProducts.EggBundle
	Kit.SetText(card:FindFirstChild("ItemName"), product.DisplayName .. "!")
	Kit.Hide(card:FindFirstChild("GiftBtn"))
	local clipping = card:FindFirstChild("ClippingItems")
	if clipping then
		for _, child in ipairs(clipping:GetChildren()) do
			if child.Name == "Icon" then
				setIcon(child, "Egg")
				-- Each tile carries a sample caption ("+100k", "VIP", ...); the
				-- second label on the last tile is the "OP!" sticker, kept.
				Kit.SetText(child:FindFirstChildWhichIsA("TextLabel"), "Egg")
			end
		end
	end
	register("Product", "EggBundle", card:FindFirstChild("Buy"))
end

local function fillDefense(content: Instance)
	local card = content:FindFirstChild("LuckFrame")
	if not card then
		return
	end
	for _, label in ipairs(card:GetChildren()) do
		if label.Name == "ItemName" and label:IsA("TextLabel") then
			if label.Text == "Server Luck" then
				label.Text = Config.DevProducts.EmergencyLock.DisplayName
			elseif label.Text:find("minutes") then
				label.Text = string.format("Lock your camp NOW for %d min", Config.Plot.EmergencyLockBonus // 60)
			else
				label.Visible = false -- the "1X > 2X" labels
			end
		end
	end
	Kit.Hide(card:FindFirstChild("GiftBtn"))
	local clipping = card:FindFirstChild("ClippingItems")
	setIcon(clipping and clipping:FindFirstChild("Icon"), "Lock")
	register("Product", "EmergencyLock", card:FindFirstChild("Buy"))
end

local function build()
	local gui = Kit.Mount("Shop")
	popup = Kit.Popup(gui)
	popup.OnOpen = refresh

	local list = Kit.Deep(gui, "ScrollingFrame") :: ScrollingFrame
	Kit.FitCanvas(list)
	for _, child in ipairs(list:GetChildren()) do
		if child.Name == "Divider" then
			local title = child:FindFirstChild("Title")
			if title and title.Text == "Featured" then
				title.Text = "Boosts"
			elseif title and title.Text == "Server Luck" then
				title.Text = "Defense"
			end
		elseif child.Name == "Content" then
			if child:FindFirstChild("EggFrame") then
				fillFeatured(child)
			elseif child:FindFirstChild("Gamepass [Orange]") then
				fillPasses(child)
			elseif child:FindFirstChild("StarterPack") then
				fillStarterPack(child)
			elseif child:FindFirstChild("LuckFrame") then
				fillDefense(child)
			else
				fillCurrency(child)
			end
		end
	end
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
	build()
	setupVipTag()
	-- Prices arrive and passes get bought while the shop may be open.
	task.spawn(function()
		while true do
			task.wait(0.5)
			if popup:IsOpen() then
				refresh()
			end
		end
	end)
end

return RobuxShopController
