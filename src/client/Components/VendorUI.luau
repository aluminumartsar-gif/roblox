-- Shovel vendor panel. Rendered as a centered popup with an NPC portrait
-- header, current-cash chip, scrollable shovel cards with state-driven CTAs,
-- and a status line for purchase feedback.
--
-- VendorUI is a passive renderer: it knows nothing about remotes or proximity
-- detection. The owning controller calls `setSnapshot` to update money /
-- rebirths / current-shovel and `setStatus` to surface purchase results, and
-- registers a buy handler with `setBuyHandler`.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local IconAssets = require(ConfigFolder:WaitForChild("IconAssets"))
local ShovelConfig = require(ConfigFolder:WaitForChild("ShovelConfig"))
local FormatUtil = require(UtilFolder:WaitForChild("FormatUtil"))
local UIAnimations = require(script.Parent:WaitForChild("UIAnimations"))

local VendorUI = {}
VendorUI.__index = VendorUI

local THEME_PRIMARY = Color3.fromRGB(232, 168, 72)
local THEME_PRIMARY_DARK = Color3.fromRGB(176, 116, 36)
local THEME_PRIMARY_DEEP = Color3.fromRGB(96, 56, 12)
local PANEL_TOP = Color3.fromRGB(48, 36, 28)
local PANEL_BOTTOM = Color3.fromRGB(20, 14, 10)
local SURFACE = Color3.fromRGB(34, 26, 20)
local SURFACE_LIGHT = Color3.fromRGB(56, 42, 30)
local TEXT_PRIMARY = Color3.fromRGB(248, 244, 230)
local TEXT_SECONDARY = Color3.fromRGB(200, 184, 156)
local TEXT_MUTED = Color3.fromRGB(140, 124, 100)
local CASH_COLOR = Color3.fromRGB(120, 255, 166)
local LOCKED_COLOR = Color3.fromRGB(150, 130, 110)
local LOCKED_BG = Color3.fromRGB(56, 44, 36)
local AFFORD_COLOR = Color3.fromRGB(255, 196, 64)
local UNAFFORDABLE_COLOR = Color3.fromRGB(220, 96, 96)
local EQUIPPED_COLOR = Color3.fromRGB(120, 220, 140)
local STATUS_INFO = Color3.fromRGB(255, 220, 138)
local STATUS_ERROR = Color3.fromRGB(255, 138, 138)
local REBIRTH_COLOR = Color3.fromRGB(232, 90, 220)

-- Classic Roblox noob palette (Bright Yellow head, Bright Blue torso). Used by
-- the vendor portrait so Carlo reads as a friendly noob bust at a glance.
local NOOB_HEAD = Color3.fromRGB(245, 205, 48)
local NOOB_HEAD_OUTLINE = Color3.fromRGB(170, 130, 0)
local NOOB_TORSO = Color3.fromRGB(13, 105, 172)
local NOOB_FACE = Color3.fromRGB(20, 20, 20)

local CARD_HEIGHT = 124
local CARD_GAP_Y = 10
local SIDE_PADDING = 22
local HEADER_HEIGHT = 104
local STATUS_HEIGHT = 38
local CTA_WIDTH = 152
local INFO_LEFT_OFFSET = 128
local INFO_RIGHT_RESERVE = CTA_WIDTH + 28

local function addCorner(parent: Instance, radius: UDim)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = radius
	corner.Parent = parent
end

local function addStroke(parent: Instance, color: Color3, thickness: number, transparency: number?)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Transparency = transparency or 0
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = parent
end

local function addGradient(parent: Instance, topColor: Color3, bottomColor: Color3, rotation: number?)
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, topColor),
		ColorSequenceKeypoint.new(1, bottomColor),
	})
	gradient.Rotation = rotation or 90
	gradient.Parent = parent

	return gradient
end

local function addPadding(parent: Instance, top: number, right: number, bottom: number, left: number)
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, top)
	padding.PaddingRight = UDim.new(0, right)
	padding.PaddingBottom = UDim.new(0, bottom)
	padding.PaddingLeft = UDim.new(0, left)
	padding.Parent = parent
end

local function formatPercent(value: number): string
	return ("%d%%"):format(math.floor(value * 100 + 0.5))
end

local function formatLuck(baseLuck: number): string
	local bonus = (baseLuck - 1) * 100
	if bonus <= 0 then
		return "+0%"
	end

	return ("+%d%%"):format(math.floor(bonus + 0.5))
end

local function formatHits(requiredHits: number): string
	if requiredHits == 1 then
		return "1 hit"
	end

	return ("%d hits"):format(requiredHits)
end

-- Returns the IconAssets entry for an iconName if present and not the
-- "rbxassetid://0" placeholder used while an icon hasn't been uploaded.
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

-- Procedural shovel silhouette built out of frames. Used as a fallback for
-- shovels that don't yet have an uploaded icon, so the card never renders an
-- empty swatch.
local function buildProceduralShovel(swatch: Frame, accent: Color3, bladeColor: Color3)
	-- swatch is 104×104px; all sizes are fractions of that square
	local handle = Instance.new("Frame")
	handle.Name = "Handle"
	handle.AnchorPoint = Vector2.new(0.5, 0.5)
	handle.Position = UDim2.fromScale(0.5, 0.36)
	handle.Size = UDim2.fromScale(0.077, 0.538)
	handle.BackgroundColor3 = Color3.fromRGB(190, 138, 80)
	handle.BorderSizePixel = 0
	handle.Rotation = 14
	handle.Parent = swatch
	addCorner(handle, UDim.new(0, 4))

	local neck = Instance.new("Frame")
	neck.Name = "Neck"
	neck.AnchorPoint = Vector2.new(0.5, 0.5)
	neck.Position = UDim2.fromScale(0.575, 0.65)
	neck.Size = UDim2.fromScale(0.096, 0.135)
	neck.BackgroundColor3 = bladeColor
	neck.BorderSizePixel = 0
	neck.Rotation = 14
	neck.Parent = swatch
	addCorner(neck, UDim.new(0, 3))

	local blade = Instance.new("Frame")
	blade.Name = "Blade"
	blade.AnchorPoint = Vector2.new(0.5, 0.5)
	blade.Position = UDim2.fromScale(0.6, 0.78)
	blade.Size = UDim2.fromScale(0.442, 0.308)
	blade.BackgroundColor3 = bladeColor
	blade.BorderSizePixel = 0
	blade.Rotation = 14
	blade.Parent = swatch
	addCorner(blade, UDim.new(0, 6))
	addStroke(blade, accent, 1.5, 0.3)
end

local function buildIconSwatch(parent: Instance, accent: Color3, bladeColor: Color3, iconName: string?)
	-- card is ~1070×124px at reference; swatch occupies the left square slot
	local swatch = Instance.new("Frame")
	swatch.Name = "IconSwatch"
	swatch.Position = UDim2.fromScale(0.013, 0.113)
	swatch.Size = UDim2.fromScale(0.097, 0.839)
	swatch.BackgroundColor3 = Color3.fromRGB(20, 14, 10)
	swatch.BorderSizePixel = 0
	swatch.Parent = parent
	addCorner(swatch, UDim.new(0.15, 0))
	addGradient(swatch, Color3.fromRGB(48, 36, 24), Color3.fromRGB(14, 10, 6))
	addStroke(swatch, accent, 2, 0.25)

	local assetId = resolveIconAsset(iconName)
	if assetId then
		local image = Instance.new("ImageLabel")
		image.Name = "ShovelIcon"
		image.AnchorPoint = Vector2.new(0.5, 0.5)
		image.Position = UDim2.fromScale(0.5, 0.5)
		image.Size = UDim2.fromScale(0.92, 0.92)
		image.BackgroundTransparency = 1
		image.Image = assetId
		image.ScaleType = Enum.ScaleType.Fit
		image.Parent = swatch
	else
		buildProceduralShovel(swatch, accent, bladeColor)
	end

	return swatch
end

local function buildStatChip(parent: Instance, layoutOrder: number, label: string, value: string, valueColor: Color3)
	-- Chip height fills parent statRow; AutomaticSize=X determines width
	local chip = Instance.new("Frame")
	chip.Name = "StatChip"
	chip.LayoutOrder = layoutOrder
	chip.AutomaticSize = Enum.AutomaticSize.X
	chip.Size = UDim2.new(0, 0, 1, 0)
	chip.BackgroundColor3 = Color3.fromRGB(22, 16, 12)
	chip.BorderSizePixel = 0
	chip.Parent = parent
	addCorner(chip, UDim.new(0, 6))
	addPadding(chip, 0, 8, 0, 8)
	addStroke(chip, valueColor, 1, 0.55)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = chip

	local labelText = Instance.new("TextLabel")
	labelText.LayoutOrder = 1
	labelText.AutomaticSize = Enum.AutomaticSize.X
	labelText.BackgroundTransparency = 1
	labelText.Size = UDim2.new(0, 0, 1, 0)
	labelText.Font = Enum.Font.GothamMedium
	labelText.Text = label
	labelText.TextColor3 = TEXT_MUTED
	labelText.TextScaled = true
	labelText.TextYAlignment = Enum.TextYAlignment.Center
	labelText.Parent = chip

	local valueText = Instance.new("TextLabel")
	valueText.LayoutOrder = 2
	valueText.AutomaticSize = Enum.AutomaticSize.X
	valueText.BackgroundTransparency = 1
	valueText.Size = UDim2.new(0, 0, 1, 0)
	valueText.Font = Enum.Font.GothamBold
	valueText.Text = value
	valueText.TextColor3 = valueColor
	valueText.TextScaled = true
	valueText.TextYAlignment = Enum.TextYAlignment.Center
	valueText.Parent = chip
end

local CardState = {
	LOCKED = "LOCKED",
	AFFORDABLE = "AFFORDABLE",
	UNAFFORDABLE = "UNAFFORDABLE",
	EQUIPPED = "EQUIPPED",
}

local function resolveCardState(entry, currentRank: number, rebirths: number, cash: number)
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

local function setButtonStroke(button: TextButton, color: Color3, transparency: number)
	-- Reset stroke before each state so we don't accumulate strokes from
	-- previous passes (the state can change every snapshot).
	for _, child in button:GetChildren() do
		if child:IsA("UIStroke") then
			child:Destroy()
		end
	end

	addStroke(button, color, 2, transparency)
end

local function setButtonGradient(button: TextButton, topColor: Color3, bottomColor: Color3)
	local existing = button:FindFirstChildOfClass("UIGradient")
	if existing then
		existing:Destroy()
	end

	addGradient(button, topColor, bottomColor)
end

local function applyButtonState(button: TextButton, actionLabel: TextLabel, priceLabel: TextLabel, state: string, entry)
	if state == CardState.AFFORDABLE then
		actionLabel.Text = "BUY"
		actionLabel.TextColor3 = Color3.fromRGB(76, 44, 6)
		priceLabel.Text = if entry.cost > 0 then FormatUtil.money(entry.cost) else "FREE"
		priceLabel.TextColor3 = Color3.fromRGB(36, 22, 4)
		setButtonGradient(button, AFFORD_COLOR, THEME_PRIMARY_DARK)
		button.AutoButtonColor = false
		button.Active = true
		setButtonStroke(button, THEME_PRIMARY_DEEP, 0.2)
	elseif state == CardState.UNAFFORDABLE then
		actionLabel.Text = "NEED"
		actionLabel.TextColor3 = UNAFFORDABLE_COLOR
		priceLabel.Text = FormatUtil.money(math.max(0, entry.cost))
		priceLabel.TextColor3 = UNAFFORDABLE_COLOR
		setButtonGradient(button, Color3.fromRGB(64, 28, 28), Color3.fromRGB(38, 18, 18))
		button.AutoButtonColor = false
		button.Active = true
		setButtonStroke(button, UNAFFORDABLE_COLOR, 0.45)
	elseif state == CardState.LOCKED then
		actionLabel.Text = "LOCKED"
		actionLabel.TextColor3 = LOCKED_COLOR
		priceLabel.Text = ("Rebirth %d+"):format(entry.rebirthsRequired)
		priceLabel.TextColor3 = REBIRTH_COLOR
		setButtonGradient(button, LOCKED_BG, Color3.fromRGB(34, 26, 20))
		button.AutoButtonColor = false
		button.Active = false
		setButtonStroke(button, LOCKED_COLOR, 0.55)
	elseif state == CardState.EQUIPPED then
		actionLabel.Text = "OWNED"
		actionLabel.TextColor3 = EQUIPPED_COLOR
		priceLabel.Text = "Equipped"
		priceLabel.TextColor3 = EQUIPPED_COLOR
		setButtonGradient(button, Color3.fromRGB(28, 56, 36), Color3.fromRGB(18, 36, 24))
		button.AutoButtonColor = false
		button.Active = false
		setButtonStroke(button, EQUIPPED_COLOR, 0.4)
	end
end

local function buildCTAButton(parent: Instance): (TextButton, TextLabel, TextLabel)
	-- Card is ~1070×124px; button is right-anchored at 14.2% width × 58.1% height
	local button = Instance.new("TextButton")
	button.Name = "CTA"
	button.AnchorPoint = Vector2.new(1, 0.5)
	button.Position = UDim2.fromScale(0.985, 0.5)
	button.Size = UDim2.fromScale(0.142, 0.581)
	button.AutoButtonColor = false
	button.Text = ""
	button.BackgroundColor3 = AFFORD_COLOR
	button.BorderSizePixel = 0
	button.Parent = parent
	addCorner(button, UDim.new(0, 14))

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0.028, 0)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = button

	local actionLabel = Instance.new("TextLabel")
	actionLabel.Name = "Action"
	actionLabel.LayoutOrder = 1
	actionLabel.BackgroundTransparency = 1
	actionLabel.Size = UDim2.new(1, 0, 0.194, 0)
	actionLabel.Font = Enum.Font.GothamBold
	actionLabel.Text = "BUY"
	actionLabel.TextScaled = true
	actionLabel.TextColor3 = Color3.fromRGB(48, 28, 4)
	actionLabel.Parent = button

	local priceLabel = Instance.new("TextLabel")
	priceLabel.Name = "Price"
	priceLabel.LayoutOrder = 2
	priceLabel.BackgroundTransparency = 1
	priceLabel.Size = UDim2.fromScale(0.895, 0.333)
	priceLabel.Font = Enum.Font.GothamBlack
	priceLabel.Text = ""
	priceLabel.TextScaled = true
	priceLabel.TextColor3 = Color3.fromRGB(36, 22, 4)
	priceLabel.Parent = button

	return button, actionLabel, priceLabel
end

local function buildCard(parent: Instance, entry, layoutOrder: number, onBuy: (any) -> ())
	-- List is ~1070×692px at reference; each card is full width × 17.9% of list height
	local card = Instance.new("Frame")
	card.Name = entry.id
	card.LayoutOrder = layoutOrder
	card.Size = UDim2.new(1, 0, 0.179, 0)
	card.BackgroundColor3 = SURFACE
	card.BorderSizePixel = 0
	card.Parent = parent
	addCorner(card, UDim.new(0, 16))
	addGradient(card, SURFACE_LIGHT, SURFACE)
	addStroke(card, entry.visual.accentColor, 2, 0.45)

	buildIconSwatch(card, entry.visual.accentColor, entry.visual.bladeColor, entry.iconName)

	-- INFO_LEFT_OFFSET=128/1070=0.120, INFO_RIGHT_RESERVE=180/1070=0.168 → content width = 0.712
	local name = Instance.new("TextLabel")
	name.Name = "ProductName"
	name.BackgroundTransparency = 1
	name.Position = UDim2.fromScale(0.120, 0.113)
	name.Size = UDim2.new(0.712, 0, 0.194, 0)
	name.Font = Enum.Font.GothamBlack
	name.Text = entry.displayName
	name.TextColor3 = TEXT_PRIMARY
	name.TextScaled = true
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextYAlignment = Enum.TextYAlignment.Center
	name.Parent = card

	local tagline = Instance.new("TextLabel")
	tagline.Name = "Tagline"
	tagline.BackgroundTransparency = 1
	tagline.Position = UDim2.fromScale(0.120, 0.339)
	tagline.Size = UDim2.new(0.712, 0, 0.226, 0)
	tagline.Font = Enum.Font.GothamMedium
	tagline.Text = entry.tagline
	tagline.TextColor3 = TEXT_SECONDARY
	tagline.TextScaled = true
	tagline.TextWrapped = true
	tagline.TextXAlignment = Enum.TextXAlignment.Left
	tagline.TextYAlignment = Enum.TextYAlignment.Top
	tagline.Parent = card

	local statRow = Instance.new("Frame")
	statRow.Name = "StatRow"
	statRow.AnchorPoint = Vector2.new(0, 1)
	statRow.BackgroundTransparency = 1
	statRow.Position = UDim2.new(0.120, 0, 0.887, 0)
	statRow.Size = UDim2.new(0.712, 0, 0.194, 0)
	statRow.Parent = card

	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	rowLayout.Padding = UDim.new(0.008, 0)
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Parent = statRow

	buildStatChip(statRow, 1, "Hits", formatHits(entry.stats.requiredHits), TEXT_PRIMARY)
	buildStatChip(statRow, 2, "Break", formatPercent(entry.stats.breakPerHit), Color3.fromRGB(255, 168, 120))
	buildStatChip(statRow, 3, "Luck", formatLuck(entry.stats.baseLuck), Color3.fromRGB(255, 220, 96))

	local rebirthChip
	if entry.rebirthsRequired > 0 then
		rebirthChip = Instance.new("TextLabel")
		rebirthChip.Name = "RebirthChip"
		rebirthChip.LayoutOrder = 4
		rebirthChip.AutomaticSize = Enum.AutomaticSize.X
		rebirthChip.Size = UDim2.new(0, 0, 1, 0)
		rebirthChip.BackgroundColor3 = Color3.fromRGB(22, 16, 12)
		rebirthChip.BorderSizePixel = 0
		rebirthChip.Font = Enum.Font.GothamBold
		rebirthChip.Text = ("  Rebirth %d+  "):format(entry.rebirthsRequired)
		rebirthChip.TextColor3 = REBIRTH_COLOR
		rebirthChip.TextScaled = true
		rebirthChip.Parent = statRow
		addCorner(rebirthChip, UDim.new(0, 6))
		addStroke(rebirthChip, REBIRTH_COLOR, 1, 0.55)
	end

	local button, actionLabel, priceLabel = buildCTAButton(card)
	UIAnimations.bindHover(button, { hoverScale = 1.05, pressScale = 0.93 })

	button.Activated:Connect(function()
		if not button.Active then
			return
		end

		onBuy(entry)
	end)

	-- Each card stores a closure the panel-level setSnapshot calls to refresh
	-- visual state without re-creating the card. Avoids reflow churn when
	-- sync messages stream in.
	local cardApi = {
		entry = entry,
		applyState = function(currentRank: number, rebirths: number, cash: number)
			local state = resolveCardState(entry, currentRank, rebirths, cash)
			applyButtonState(button, actionLabel, priceLabel, state, entry)

			if state == CardState.LOCKED then
				name.TextColor3 = TEXT_MUTED
				tagline.TextColor3 = TEXT_MUTED
				if rebirthChip then
					rebirthChip.TextColor3 = Color3.fromRGB(255, 130, 130)
				end
			else
				name.TextColor3 = TEXT_PRIMARY
				tagline.TextColor3 = TEXT_SECONDARY
				if rebirthChip then
					rebirthChip.TextColor3 = REBIRTH_COLOR
				end
			end
		end,
	}

	return cardApi
end

local function buildPortrait(parent: Instance)
	-- Header is ~1114×104px at reference. Portrait sits left-center.
	-- frame: 82px → 82/1114=0.074 wide, 82/104=0.788 tall
	local frame = Instance.new("Frame")
	frame.Name = "Portrait"
	frame.AnchorPoint = Vector2.new(0, 0.5)
	frame.Position = UDim2.fromScale(0.020, 0.5)
	frame.Size = UDim2.fromScale(0.074, 0.788)
	frame.BackgroundColor3 = THEME_PRIMARY
	frame.BorderSizePixel = 0
	frame.Parent = parent
	addCorner(frame, UDim.new(0.5, 0))
	addGradient(frame, Color3.fromRGB(255, 220, 130), THEME_PRIMARY_DARK, 0)
	addStroke(frame, THEME_PRIMARY_DEEP, 3, 0.1)

	-- frame is ~82×82px; torso 38×28 → 0.463×0.341
	local torso = Instance.new("Frame")
	torso.Name = "Torso"
	torso.AnchorPoint = Vector2.new(0.5, 1)
	torso.Position = UDim2.fromScale(0.5, 0.94)
	torso.Size = UDim2.fromScale(0.463, 0.341)
	torso.BackgroundColor3 = NOOB_TORSO
	torso.BorderSizePixel = 0
	torso.ZIndex = 2
	torso.Parent = frame
	addCorner(torso, UDim.new(0, 8))

	-- head 50×50 inside 82×82 frame → 0.610×0.610
	local head = Instance.new("Frame")
	head.Name = "Head"
	head.AnchorPoint = Vector2.new(0.5, 0.5)
	head.Position = UDim2.fromScale(0.5, 0.42)
	head.Size = UDim2.fromScale(0.610, 0.610)
	head.BackgroundColor3 = NOOB_HEAD
	head.BorderSizePixel = 0
	head.ZIndex = 3
	head.Parent = frame
	addCorner(head, UDim.new(0.5, 0))
	addStroke(head, NOOB_HEAD_OUTLINE, 1.5, 0.5)

	-- eyes inside head (50×50); offset 9/50=0.18 from centre; size 5×7 → 0.10×0.14
	for _, sign in { -1, 1 } do
		local eye = Instance.new("Frame")
		eye.Name = "Eye"
		eye.AnchorPoint = Vector2.new(0.5, 0.5)
		eye.Position = UDim2.new(0.5 + sign * 0.18, 0, 0.4, 0)
		eye.Size = UDim2.fromScale(0.10, 0.14)
		eye.BackgroundColor3 = NOOB_FACE
		eye.BorderSizePixel = 0
		eye.Parent = head
		addCorner(eye, UDim.new(0, 2))
	end

	-- smile bar inside head; 18×3 → 0.36×0.06
	local mouth = Instance.new("Frame")
	mouth.Name = "Mouth"
	mouth.AnchorPoint = Vector2.new(0.5, 0.5)
	mouth.Position = UDim2.fromScale(0.5, 0.7)
	mouth.Size = UDim2.fromScale(0.36, 0.06)
	mouth.BackgroundColor3 = NOOB_FACE
	mouth.BorderSizePixel = 0
	mouth.Parent = head
	addCorner(mouth, UDim.new(0, 2))

	-- corner pips; 3×4 → 0.06×0.08; offset 11/50=0.22
	for _, sign in { -1, 1 } do
		local cornerPip = Instance.new("Frame")
		cornerPip.Name = "MouthCorner"
		cornerPip.AnchorPoint = Vector2.new(0.5, 0.5)
		cornerPip.Position = UDim2.new(0.5 + sign * 0.22, 0, 0.66, 0)
		cornerPip.Size = UDim2.fromScale(0.06, 0.08)
		cornerPip.BackgroundColor3 = NOOB_FACE
		cornerPip.BorderSizePixel = 0
		cornerPip.Parent = head
		addCorner(cornerPip, UDim.new(0, 1))
	end
end

function VendorUI.new()
	local self = setmetatable({}, VendorUI)

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "VendorGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 6
	gui.Enabled = true
	gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "VendorPanel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromScale(0.58, 0.78)
	panel.BackgroundColor3 = PANEL_BOTTOM
	panel.Visible = false
	panel.Parent = gui
	addCorner(panel, UDim.new(0.025, 0))
	addGradient(panel, PANEL_TOP, PANEL_BOTTOM)
	addStroke(panel, THEME_PRIMARY, 2, 0.3)

	-- Header: 10.4% of panel height (104/842). Portrait + title + right controls.
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0.1235, 0)
	header.Parent = panel

	buildPortrait(header)

	-- rightControls: 232/1114=0.208 wide, 42/104=0.404 tall within header
	local rightControls = Instance.new("Frame")
	rightControls.Name = "RightControls"
	rightControls.AnchorPoint = Vector2.new(1, 0.5)
	rightControls.Position = UDim2.fromScale(0.980, 0.5)
	rightControls.Size = UDim2.fromScale(0.208, 0.404)
	rightControls.BackgroundTransparency = 1
	rightControls.Parent = header

	local rightLayout = Instance.new("UIListLayout")
	rightLayout.FillDirection = Enum.FillDirection.Horizontal
	rightLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	rightLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	rightLayout.Padding = UDim.new(0.052, 0)
	rightLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rightLayout.Parent = rightControls

	-- cashChip: 176/232=0.759 wide inside rightControls
	local cashChip = Instance.new("Frame")
	cashChip.Name = "CashChip"
	cashChip.LayoutOrder = 1
	cashChip.Size = UDim2.fromScale(0.759, 1)
	cashChip.BackgroundColor3 = Color3.fromRGB(14, 18, 14)
	cashChip.BorderSizePixel = 0
	cashChip.Parent = rightControls
	addCorner(cashChip, UDim.new(0, 12))
	addStroke(cashChip, CASH_COLOR, 2, 0.35)

	local cashLabel = Instance.new("TextLabel")
	cashLabel.Name = "CashLabel"
	cashLabel.BackgroundTransparency = 1
	cashLabel.Size = UDim2.fromScale(1, 1)
	cashLabel.Font = Enum.Font.GothamBlack
	cashLabel.Text = "$0"
	cashLabel.TextColor3 = CASH_COLOR
	cashLabel.TextScaled = true
	cashLabel.Parent = cashChip

	-- closeButton: 42/232=0.181 wide
	local closeButton = Instance.new("TextButton")
	closeButton.Name = "CloseButton"
	closeButton.LayoutOrder = 2
	closeButton.Size = UDim2.fromScale(0.181, 1)
	closeButton.BackgroundColor3 = Color3.fromRGB(60, 32, 32)
	closeButton.AutoButtonColor = false
	closeButton.Font = Enum.Font.GothamBlack
	closeButton.Text = "X"
	closeButton.TextColor3 = Color3.fromRGB(255, 222, 222)
	closeButton.TextScaled = true
	closeButton.Parent = rightControls
	addCorner(closeButton, UDim.new(0, 10))
	addStroke(closeButton, Color3.fromRGB(255, 138, 138), 2, 0.35)
	UIAnimations.bindHover(closeButton, { hoverScale = 1.1, pressScale = 0.92 })

	-- titleGroup fills the middle slot; portrait(82) + gap(18) = 100px from left
	-- right side reserved: rightControls(232) + gap(24) + sidePad(22) = 278px
	-- total excluded: 22+82+18+278 = 400px → title width = (1114-400)/1114 = 0.641
	local titleGroup = Instance.new("Frame")
	titleGroup.Name = "TitleGroup"
	titleGroup.Position = UDim2.fromScale(0.110, 0)
	titleGroup.Size = UDim2.fromScale(0.641, 1)
	titleGroup.BackgroundTransparency = 1
	titleGroup.Parent = header

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromScale(0, 0.212)
	title.Size = UDim2.new(1, 0, 0.308, 0)
	title.Font = Enum.Font.GothamBlack
	title.Text = "Carlo's Shovel Stand"
	title.TextColor3 = TEXT_PRIMARY
	title.TextScaled = true
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextYAlignment = Enum.TextYAlignment.Center
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.Parent = titleGroup

	local titleGradient = Instance.new("UIGradient")
	titleGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 248, 220)),
		ColorSequenceKeypoint.new(1, THEME_PRIMARY),
	})
	titleGradient.Rotation = 90
	titleGradient.Parent = title

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.BackgroundTransparency = 1
	subtitle.Position = UDim2.fromScale(0, 0.538)
	subtitle.Size = UDim2.new(1, 0, 0.212, 0)
	subtitle.FontFace = Font.new("rbxasset://fonts/families/Gotham.json", Enum.FontWeight.Medium, Enum.FontStyle.Italic)
	subtitle.Text = "\"Diggin's hard work. Better tool, better loot, friend.\""
	subtitle.TextColor3 = TEXT_SECONDARY
	subtitle.TextScaled = true
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.TextTruncate = Enum.TextTruncate.AtEnd
	subtitle.Parent = titleGroup

	-- List: starts below header (100/842=0.119 from top); width excludes side
	-- padding (44/1114=0.040); height excludes header + status + gap
	-- (150/842=0.178 total reserved → list height = 0.822 of panel)
	local list = Instance.new("ScrollingFrame")
	list.Name = "CardList"
	list.AnchorPoint = Vector2.new(0.5, 0)
	list.Position = UDim2.new(0.5, 0, 0.119, 0)
	list.Size = UDim2.fromScale(0.9605, 0.8219)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 6
	list.ScrollBarImageColor3 = THEME_PRIMARY
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.fromScale(0, 0)
	list.Parent = panel

	local listPadding = Instance.new("UIPadding")
	listPadding.PaddingTop = UDim.new(0.009, 0)
	listPadding.PaddingBottom = UDim.new(0.017, 0)
	listPadding.PaddingLeft = UDim.new(0.004, 0)
	listPadding.PaddingRight = UDim.new(0.009, 0)
	listPadding.Parent = list

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0.014, 0)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	-- Status bar: anchored bottom-centre, 10/842=0.012 from bottom edge
	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.AnchorPoint = Vector2.new(0.5, 1)
	status.Position = UDim2.new(0.5, 0, 0.988, 0)
	status.Size = UDim2.new(0.9605, 0, 0.0451, 0)
	status.BackgroundColor3 = Color3.fromRGB(34, 28, 16)
	status.BackgroundTransparency = 1
	status.Font = Enum.Font.GothamBold
	status.Text = ""
	status.TextColor3 = STATUS_INFO
	status.TextScaled = true
	status.TextWrapped = true
	status.Parent = panel
	addCorner(status, UDim.new(0, 12))
	addStroke(status, THEME_PRIMARY, 2, 1)

	local cards = {}

	local onBuyHandler
	local onCloseHandler

	for index, entry in ShovelConfig.Shovels do
		local card = buildCard(list, entry, index, function(selected)
			if onBuyHandler then
				onBuyHandler(selected)
			end
		end)

		table.insert(cards, card)
	end

	closeButton.Activated:Connect(function()
		if onCloseHandler then
			onCloseHandler()
		else
			UIAnimations.closePanel(panel)
		end
	end)

	self.gui = gui
	self.panel = panel
	self.cashLabel = cashLabel
	self.status = status
	self.statusToken = 0
	self.cards = cards
	self.snapshot = {
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

function VendorUI.setSnapshot(self, snapshot)
	if type(snapshot) ~= "table" then
		return
	end

	if snapshot.shovel ~= nil then
		self.snapshot.shovel = snapshot.shovel
	end
	if snapshot.money ~= nil then
		self.snapshot.money = snapshot.money
	end
	if snapshot.rebirths ~= nil then
		self.snapshot.rebirths = snapshot.rebirths
	end

	self.cashLabel.Text = FormatUtil.money(self.snapshot.money)

	local currentRank = ShovelConfig.getRank(self.snapshot.shovel)
	for _, card in self.cards do
		card.applyState(currentRank, self.snapshot.rebirths, self.snapshot.money)
	end
end

function VendorUI.setStatus(self, message: string, kind: string?)
	self.status.Text = message
	if kind == "error" then
		self.status.TextColor3 = STATUS_ERROR
	elseif kind == "success" then
		self.status.TextColor3 = EQUIPPED_COLOR
	else
		self.status.TextColor3 = STATUS_INFO
	end

	if message == "" then
		self.status.BackgroundTransparency = 1
		local stroke = self.status:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Transparency = 1
		end
		return
	end

	self.status.BackgroundTransparency = 0.15
	local stroke = self.status:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Transparency = 0.4
	end

	self.statusToken += 1
	local token = self.statusToken

	task.delay(3.5, function()
		if self.statusToken == token then
			VendorUI.setStatus(self, "")
		end
	end)
end

function VendorUI.open(self)
	if self.panel.Visible then
		return
	end

	UIAnimations.openPanel(self.panel)
end

function VendorUI.close(self)
	if not self.panel.Visible then
		return
	end

	UIAnimations.closePanel(self.panel)
end

function VendorUI.isOpen(self): boolean
	return self.panel.Visible
end

return VendorUI
