-- Renders the shovel catalogue inside the existing ItemShopPopup ScreenGui.
-- Drop-in replacement for VendorUI – exposes the same public API so
-- ShopBoothController only needs a one-line change:
--   VendorUI → ItemShopController
--
-- The ItemShopPopup background image, panel shape, fonts, and scroll frame
-- are all untouched. Each shovel gets its own cloned Item frame with:
--   HeaderText  → shovel displayName
--   BodyText    → tagline
--   BuyCash     → buy / state button  (coin cost / "OWNED" / "Rebirth X+")
--   BuyRobux    → hidden (shovels are coins-only)
--   Icon        → shovel portrait from IconAssets

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local IconAssets = require(ConfigFolder:WaitForChild("IconAssets"))
local ShovelConfig = require(ConfigFolder:WaitForChild("ShovelConfig"))
local FormatUtil = require(UtilFolder:WaitForChild("FormatUtil"))

local UIKit      = script.Parent.Parent:WaitForChild("UIKit")
local Screen = require(UIKit:WaitForChild("Screen"))
local GuiResolve = require(UIKit:WaitForChild("GuiResolve"))

local ItemShopController = {}
ItemShopController.__index = ItemShopController

local STATUS_INFO = Color3.fromRGB(255, 220, 138)
local STATUS_ERROR = Color3.fromRGB(255, 138, 138)
local STATUS_SUCCESS = Color3.fromRGB(120, 220, 140)

local COLOR_AFFORDABLE = Color3.fromRGB(80, 200, 120)
local COLOR_UNAFFORDABLE = Color3.fromRGB(220, 96, 96)
local COLOR_LOCKED = Color3.fromRGB(180, 150, 220)
local COLOR_EQUIPPED = Color3.fromRGB(100, 200, 255)

local COLOR_STAT_LUCK = Color3.fromRGB(255, 220, 96)
local COLOR_STAT_BAR  = Color3.fromRGB(100, 220, 130)

local CardState = {
	LOCKED = "LOCKED",
	AFFORDABLE = "AFFORDABLE",
	UNAFFORDABLE = "UNAFFORDABLE",
	EQUIPPED = "EQUIPPED",
}

local function resolveIconAsset(iconName: string?): string?
	if type(iconName) ~= "string" or iconName == "" then
		return nil
	end

	local assetId = (IconAssets :: any)[iconName]
	if type(assetId) ~= "string" or assetId == "" or assetId == "rbxassetid://0" then
		return nil
	end

	return assetId
end

local function resolveCardState(entry, currentRank: number, rebirths: number, cash: number): string
	if ShovelConfig.getRank(entry.id) <= currentRank then
		return CardState.EQUIPPED
	end

	if rebirths < entry.rebirthsRequired then
		return CardState.LOCKED
	end

	if cash < entry.cost then
		return CardState.UNAFFORDABLE
	end

	return CardState.AFFORDABLE
end

-- Builds a small pill-style TextLabel for displaying a single shovel stat.
local function makeStatChip(parent: Frame, text: string, color: Color3): TextLabel
	local chip = Instance.new("TextLabel")
	chip.AutomaticSize = Enum.AutomaticSize.X
	chip.Size = UDim2.fromScale(0, 1)
	chip.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
	chip.BackgroundTransparency = 0.3
	chip.BorderSizePixel = 0
	chip.Font = Enum.Font.GothamBold
	chip.Text = text
	chip.TextColor3 = color
	chip.TextScaled = false
	chip.TextSize = 11
	chip.TextXAlignment = Enum.TextXAlignment.Center
	chip.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = chip

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft  = UDim.new(0, 6)
	padding.PaddingRight = UDim.new(0, 6)
	padding.Parent = chip

	return chip
end

-- Clones the template Item frame, fills in shovel data, and returns the card
-- plus an applyState closure the controller calls on every snapshot refresh.
local function buildCard(
	template: Frame,
	entry,
	scrollFrame: ScrollingFrame,
	onBuy: (any) -> ()
): (Frame, (number, number, number) -> ())
	local card = template:Clone()
	card.Name = entry.id
	card.Visible = true

	local bg = card:FindFirstChild("Background") :: ImageLabel?
	local buyRobux = bg and bg:FindFirstChild("BuyRobux") :: ImageButton?
	local buyCash = bg and bg:FindFirstChild("BuyCash") :: ImageButton?
	local itemImg = bg and bg:FindFirstChild("Item") :: ImageLabel?
	local iconImg = itemImg and itemImg:FindFirstChild("Icon") :: ImageLabel?

	local headerText = card:FindFirstChild("HeaderText") :: TextLabel?
	local bodyText = card:FindFirstChild("BodyText") :: TextLabel?
	local cashTitle = buyCash and buyCash:FindFirstChild("Title") :: TextLabel?

	if headerText then
		headerText.Text = entry.displayName
	end

	if bodyText then
		bodyText.Text = entry.tagline
	end

	-- Stat chips: only render chips for stats that actually have a bonus so
	-- the starter shovel (no bonuses) shows nothing instead of placeholder text.
	do
		local luckPct = math.round((entry.stats.baseLuck - 1) * 100)
		-- Compare this shovel's countdown duration against the starter shovel
		-- (Wooden, 5.0s baseline) so the chip reads "+X% Dig Speed" relative to
		-- the default. Tiers with no improvement (e.g. the starter itself)
		-- show nothing.
		local defaultStats = ShovelConfig.getEffectiveStats(ShovelConfig.getDefaultId())
		local baseDur = defaultStats.digDuration or entry.stats.digDuration or 1
		local entryDur = entry.stats.digDuration or baseDur
		local speedPct = if entryDur > 0 then math.round(((baseDur / entryDur) - 1) * 100) else 0

		if luckPct > 0 or speedPct > 0 then
			local statsRow = Instance.new("Frame")
			statsRow.Name = "StatsRow"
			statsRow.BackgroundTransparency = 1
			statsRow.Size = UDim2.new(1, 0, 0, 18)
			statsRow.AutomaticSize = Enum.AutomaticSize.X
			statsRow.Parent = card

			local layout = Instance.new("UIListLayout")
			layout.FillDirection = Enum.FillDirection.Horizontal
			layout.SortOrder = Enum.SortOrder.LayoutOrder
			layout.Padding = UDim.new(0, 5)
			layout.VerticalAlignment = Enum.VerticalAlignment.Center
			layout.Parent = statsRow

			if luckPct > 0 then
				makeStatChip(statsRow, "+" .. luckPct .. "% Luck", COLOR_STAT_LUCK).LayoutOrder = 1
			end
			if speedPct > 0 then
				makeStatChip(statsRow, "+" .. speedPct .. "% Dig Speed", COLOR_STAT_BAR).LayoutOrder = 2
			end
		end
	end

	if iconImg then
		local assetId = resolveIconAsset(entry.iconName)
		if assetId then
			iconImg.Image = assetId
		end
	end

	-- Shovels have no Robux purchase; hide that button so the layout is clean.
	if buyRobux then
		buyRobux.Visible = false
	end

	if buyCash then
		buyCash.Activated:Connect(function()
			if not buyCash.Active then
				return
			end

			onBuy(entry)
		end)
	end

	local function applyState(currentRank: number, rebirths: number, cash: number)
		local state = resolveCardState(entry, currentRank, rebirths, cash)

		if cashTitle then
			if state == CardState.EQUIPPED then
				cashTitle.Text = "OWNED"
				cashTitle.TextColor3 = COLOR_EQUIPPED
			elseif state == CardState.LOCKED then
				cashTitle.Text = ("Rebirth %d+"):format(entry.rebirthsRequired)
				cashTitle.TextColor3 = COLOR_LOCKED
			elseif state == CardState.AFFORDABLE then
				cashTitle.Text = if entry.cost > 0 then FormatUtil.money(entry.cost) else "FREE"
				cashTitle.TextColor3 = COLOR_AFFORDABLE
			elseif state == CardState.UNAFFORDABLE then
				cashTitle.Text = FormatUtil.money(entry.cost)
				cashTitle.TextColor3 = COLOR_UNAFFORDABLE
			end
		end

		if buyCash then
			buyCash.Active = state == CardState.AFFORDABLE
			buyCash.AutoButtonColor = state == CardState.AFFORDABLE
		end
	end

	card.Parent = scrollFrame
	return card, applyState
end

function ItemShopController.new()
	local self = setmetatable({}, ItemShopController)

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local screen = playerGui:WaitForChild("ItemShopPopup") :: ScreenGui
	local containerWait = GuiResolve.waitChild(screen, "Container")
	if not containerWait or not containerWait:IsA("GuiObject") then
		warn('[ItemShopController] Expected ScreenGui "ItemShopPopup" with child "Container". Shovel booth UI disabled.')
		return nil :: any
	end
	local container = containerWait :: GuiObject
	local bgWait = GuiResolve.waitChild(container, "Background")
	if not bgWait then
		warn('[ItemShopController] Expected ItemShopPopup > Container > Background. Shovel booth UI disabled.')
		return nil :: any
	end
	local bg = bgWait :: ImageLabel
	local navBarWait = GuiResolve.waitChild(bg, "NavBar")
	local contentWait = GuiResolve.waitChild(bg, "Content")
	if not navBarWait or not contentWait then
		warn('[ItemShopController] Expected ItemShopPopup > Container > Background > NavBar/Content. Shovel booth UI disabled.')
		return nil :: any
	end
	local navBar = navBarWait :: Frame
	local content = contentWait :: Frame
	local scrollWait = GuiResolve.waitChild(content, "ScrollingFrame")
	if not scrollWait then
		warn('[ItemShopController] Expected ItemShopPopup > Container > Background > Content > ScrollingFrame. Shovel booth UI disabled.')
		return nil :: any
	end
	local scrollFrame = scrollWait :: ScrollingFrame

	local closeBtn = navBar:FindFirstChild("CloseBtn") :: ImageButton?

	local titleLabel = navBar:FindFirstChild("Title") :: TextLabel?
	if titleLabel then
		titleLabel.Text = "Shovel Shop"
	end

	-- Grab one Item frame as the clone template, then clear the rest so the
	-- list starts empty before we populate it from ShovelConfig.
	local template: Frame? = nil
	for _, child in scrollFrame:GetChildren() do
		if child:IsA("Frame") and child.Name == "Item" then
			if not template then
				template = child:Clone()
				template.Visible = false
			end
			child:Destroy()
		end
	end

	scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.None
	scrollFrame.CanvasSize = UDim2.fromScale(0, 0)
	scrollFrame.ScrollingDirection = Enum.ScrollingDirection.Y
	scrollFrame.ScrollingEnabled = true
	scrollFrame.ScrollBarImageTransparency = 0
	scrollFrame.ScrollBarThickness = 8

	-- Manually sync canvas height from the UIListLayout so scale-based item
	-- sizes and nested UIAspectRatioConstraints don't confuse AutomaticCanvasSize.
	local listLayout = scrollFrame:FindFirstChildOfClass("UIListLayout")
	if listLayout then
		local function syncCanvas()
			scrollFrame.CanvasSize = UDim2.fromOffset(0, listLayout.AbsoluteContentSize.Y)
		end
		listLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(syncCanvas)
		task.defer(syncCanvas)
	end

	local cards: { applyState: (number, number, number) -> () } = {}
	local onBuyHandler: ((any) -> ())?
	local onCloseHandler: (() -> ())?

	if template then
		for _, entry in ShovelConfig.Shovels do
			local _, applyState = buildCard(template, entry, scrollFrame, function(selected)
				if onBuyHandler then
					onBuyHandler(selected)
				end
			end)

			table.insert(cards, { applyState = applyState })
		end
	end

	-- Status label overlaid at the bottom of the background panel.
	local statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "StatusLabel"
	statusLabel.AnchorPoint = Vector2.new(0.5, 1)
	statusLabel.Position = UDim2.fromScale(0.5, 0.96)
	statusLabel.Size = UDim2.fromScale(0.92, 0.06)
	statusLabel.BackgroundTransparency = 1
	statusLabel.ZIndex = 10
	statusLabel.Font = Enum.Font.GothamBold
	statusLabel.Text = ""
	statusLabel.TextColor3 = STATUS_INFO
	statusLabel.TextScaled = true
	statusLabel.TextWrapped = true
	statusLabel.Parent = bg

	-- Dummy open button: callers use ShopBoothController's proximity system
	-- to open; the button is never shown.
	local dummyBtn = Instance.new("ImageButton")
	dummyBtn.Visible = false
	dummyBtn.Parent = screen

	-- Register with UIManager and wire animations. Close button is connected
	-- manually below so we can also invoke onCloseHandler.
	local handle = Screen.bind({
		guiName = "ItemShopPopup",
		screen = screen,
		container = container,
		openButton = dummyBtn,
	})

	if closeBtn then
		closeBtn.Activated:Connect(function()
			if onCloseHandler then
				onCloseHandler()
			else
				handle.close()
			end
		end)
	end

	self._handle = handle
	self._screen = screen
	self._cards = cards
	self._statusLabel = statusLabel
	self._statusToken = 0
	self._snapshot = {
		shovel = ShovelConfig.getDefaultId(),
		money = 0,
		rebirths = 0,
	}

	function self.setBuyHandler(_, handler)
		onBuyHandler = handler
	end

	function self.setCloseHandler(_, handler)
		onCloseHandler = handler
	end

	return self
end

function ItemShopController.setSnapshot(self, snapshot)
	if type(snapshot) ~= "table" then
		return
	end

	if snapshot.shovel ~= nil then
		self._snapshot.shovel = snapshot.shovel
	end
	if snapshot.money ~= nil then
		self._snapshot.money = snapshot.money
	end
	if snapshot.rebirths ~= nil then
		self._snapshot.rebirths = snapshot.rebirths
	end

	local currentRank = ShovelConfig.getRank(self._snapshot.shovel)
	for _, card in self._cards do
		card.applyState(currentRank, self._snapshot.rebirths, self._snapshot.money)
	end
end

function ItemShopController.setStatus(self, message: string, kind: string?)
	local label = self._statusLabel
	label.Text = message

	if kind == "error" then
		label.TextColor3 = STATUS_ERROR
	elseif kind == "success" then
		label.TextColor3 = STATUS_SUCCESS
	else
		label.TextColor3 = STATUS_INFO
	end

	if message == "" then
		return
	end

	self._statusToken += 1
	local token = self._statusToken
	task.delay(3.5, function()
		if self._statusToken == token then
			ItemShopController.setStatus(self, "")
		end
	end)
end

function ItemShopController.open(self)
	self._handle.open()
end

function ItemShopController.close(self)
	self._handle.close()
end

function ItemShopController.isOpen(self): boolean
	return self._screen.Enabled
end

-- Compatibility stub: ShopBoothController.client.luau calls .start(); the
-- real initialisation happens inside ShopBoothController via .new().
function ItemShopController.start() end

return ItemShopController
