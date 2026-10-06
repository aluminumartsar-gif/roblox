-- Bottom-left HUD logo for the player's currently equipped shovel. Hovering the
-- mouse over the logo reveals a tooltip with the shovel's display name,
-- tagline, and stat chips (hits to break, break-per-hit %, luck bonus).
--
-- The component is a passive renderer: the owning controller calls `setShovel`
-- whenever the equipped shovel changes (via economy / vendor sync remotes) and
-- the UI rebuilds the logo + tooltip text without recreating the ScreenGui.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local IconAssets = require(ConfigFolder:WaitForChild("IconAssets"))
local ShovelConfig = require(ConfigFolder:WaitForChild("ShovelConfig"))

local Components = script.Parent
local UIAnimations = require(Components:WaitForChild("UIAnimations"))

local EquippedShovelUI = {}
EquippedShovelUI.__index = EquippedShovelUI

local LOGO_SIZE = 92
local LOGO_MARGIN_LEFT = 22
-- Standard bottom margin. The LuckCounterUI pill now sits above this logo
-- (y = -(22 + LOGO_SIZE + 12)), so nothing stacks below it.
local LOGO_MARGIN_BOTTOM = 22
local TOOLTIP_OFFSET_X = 12
local TOOLTIP_WIDTH = 252
local TOOLTIP_PADDING = 12

local PANEL_TOP = Color3.fromRGB(48, 36, 28)
local PANEL_BOTTOM = Color3.fromRGB(20, 14, 10)
local SURFACE = Color3.fromRGB(28, 22, 18)
local SURFACE_LIGHT = Color3.fromRGB(48, 36, 24)
local STROKE_DEEP = Color3.fromRGB(14, 10, 6)
local TEXT_PRIMARY = Color3.fromRGB(248, 244, 230)
local TEXT_SECONDARY = Color3.fromRGB(200, 184, 156)
local TEXT_MUTED = Color3.fromRGB(140, 124, 100)
local CHIP_BG = Color3.fromRGB(22, 16, 12)
local STAT_HIT_COLOR = TEXT_PRIMARY
local STAT_BREAK_COLOR = Color3.fromRGB(255, 168, 120)
local STAT_LUCK_COLOR = Color3.fromRGB(255, 220, 96)
local LABEL_COLOR = Color3.fromRGB(248, 244, 230)
local LABEL_OUTLINE = Color3.fromRGB(0, 0, 0)

local function addCorner(parent: Instance, radius: UDim)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = radius
	corner.Parent = parent
end

local function addStroke(parent: Instance, color: Color3, thickness: number, transparency: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Transparency = transparency or 0
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = parent
	return stroke
end

local function addGradient(parent: Instance, topColor: Color3, bottomColor: Color3, rotation: number?)
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, topColor),
		ColorSequenceKeypoint.new(1, bottomColor),
	})
	gradient.Rotation = rotation or 90
	gradient.Parent = parent
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

-- Builds the same "stylised shovel out of frames" silhouette VendorUI uses, so
-- shovels without an uploaded icon still get a recognisable logo.
local function buildProceduralShovel(parent: Frame, accent: Color3, bladeColor: Color3)
	local handle = Instance.new("Frame")
	handle.Name = "Handle"
	handle.AnchorPoint = Vector2.new(0.5, 0.5)
	handle.Position = UDim2.fromScale(0.5, 0.36)
	handle.Size = UDim2.fromScale(0.085, 0.6)
	handle.BackgroundColor3 = Color3.fromRGB(190, 138, 80)
	handle.BorderSizePixel = 0
	handle.Rotation = 14
	handle.Parent = parent
	addCorner(handle, UDim.new(0, 4))

	local neck = Instance.new("Frame")
	neck.Name = "Neck"
	neck.AnchorPoint = Vector2.new(0.5, 0.5)
	neck.Position = UDim2.fromScale(0.575, 0.65)
	neck.Size = UDim2.fromScale(0.1, 0.16)
	neck.BackgroundColor3 = bladeColor
	neck.BorderSizePixel = 0
	neck.Rotation = 14
	neck.Parent = parent
	addCorner(neck, UDim.new(0, 3))

	local blade = Instance.new("Frame")
	blade.Name = "Blade"
	blade.AnchorPoint = Vector2.new(0.5, 0.5)
	blade.Position = UDim2.fromScale(0.6, 0.78)
	blade.Size = UDim2.fromScale(0.46, 0.34)
	blade.BackgroundColor3 = bladeColor
	blade.BorderSizePixel = 0
	blade.Rotation = 14
	blade.Parent = parent
	addCorner(blade, UDim.new(0, 6))
	addStroke(blade, accent, 1.5, 0.3)
end

local function buildStatChip(parent: Instance, layoutOrder: number, label: string, value: string, valueColor: Color3)
	-- Chip height fills parent statRow; AutomaticSize=X determines width
	local chip = Instance.new("Frame")
	chip.Name = "StatChip_" .. label
	chip.LayoutOrder = layoutOrder
	chip.AutomaticSize = Enum.AutomaticSize.X
	chip.Size = UDim2.new(0, 0, 1, 0)
	chip.BackgroundColor3 = CHIP_BG
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
	labelText.Name = "Label"
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
	valueText.Name = "Value"
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

	return valueText
end

local function buildTooltip(parent: ScreenGui)
	-- TOOLTIP_WIDTH=252px; at 1920 screen width → 252/1920=0.131 of screen
	local frame = Instance.new("Frame")
	frame.Name = "ShovelTooltip"
	-- Anchored bottom-left of the tooltip rectangle so the controller can
	-- align its bottom edge with the bottom of the shovel logo and let it
	-- grow upward as the body wraps.
	frame.AnchorPoint = Vector2.new(0, 1)
	frame.Size = UDim2.new(0.131, 0, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundColor3 = PANEL_BOTTOM
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.ZIndex = 50
	frame.Parent = parent
	addCorner(frame, UDim.new(0.05, 0))
	addGradient(frame, PANEL_TOP, PANEL_BOTTOM)
	addStroke(frame, STROKE_DEEP, 2, 0.1)
	addPadding(frame, TOOLTIP_PADDING, TOOLTIP_PADDING, TOOLTIP_PADDING, TOOLTIP_PADDING)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = frame

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.LayoutOrder = 1
	title.BackgroundTransparency = 1
	title.AutomaticSize = Enum.AutomaticSize.Y
	title.Size = UDim2.new(1, 0, 0, 22)
	title.Font = Enum.Font.GothamBlack
	title.Text = ""
	title.TextColor3 = TEXT_PRIMARY
	title.TextScaled = true
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextYAlignment = Enum.TextYAlignment.Top
	title.ZIndex = frame.ZIndex + 1
	title.Parent = frame

	local tagline = Instance.new("TextLabel")
	tagline.Name = "Tagline"
	tagline.LayoutOrder = 2
	tagline.BackgroundTransparency = 1
	tagline.AutomaticSize = Enum.AutomaticSize.Y
	tagline.Size = UDim2.new(1, 0, 0, 0)
	-- Italic Gotham requires the FontFace API; the legacy Enum.Font has no
	-- italic variant of Gotham.
	tagline.FontFace = Font.new("rbxasset://fonts/families/Gotham.json", Enum.FontWeight.Medium, Enum.FontStyle.Italic)
	tagline.Text = ""
	tagline.TextColor3 = TEXT_SECONDARY
	tagline.TextSize = 13
	tagline.TextWrapped = true
	tagline.TextXAlignment = Enum.TextXAlignment.Left
	tagline.TextYAlignment = Enum.TextYAlignment.Top
	tagline.ZIndex = frame.ZIndex + 1
	tagline.Parent = frame

	-- statRow height: 26px pixel (cannot safely use scale inside auto-Y frame)
	local statRow = Instance.new("Frame")
	statRow.Name = "StatRow"
	statRow.LayoutOrder = 3
	statRow.BackgroundTransparency = 1
	statRow.Size = UDim2.new(1, 0, 0, 26)
	statRow.ZIndex = frame.ZIndex + 1
	statRow.Parent = frame

	local statLayout = Instance.new("UIListLayout")
	statLayout.FillDirection = Enum.FillDirection.Horizontal
	statLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	statLayout.Padding = UDim.new(0.024, 0)
	statLayout.SortOrder = Enum.SortOrder.LayoutOrder
	statLayout.Parent = statRow

	local hitsValue = buildStatChip(statRow, 1, "Hits", "", STAT_HIT_COLOR)
	local breakValue = buildStatChip(statRow, 2, "Break", "", STAT_BREAK_COLOR)
	local luckValue = buildStatChip(statRow, 3, "Luck", "", STAT_LUCK_COLOR)

	return {
		frame = frame,
		title = title,
		tagline = tagline,
		hitsValue = hitsValue,
		breakValue = breakValue,
		luckValue = luckValue,
	}
end

-- Positions the tooltip to the right of the shovel logo, with its bottom edge
-- aligned to the bottom of the logo. We read the absolute position from the
-- logo button so the tooltip lines up correctly even after viewport resizes.
local function positionTooltip(self)
	local logoPos = self.button.AbsolutePosition
	local logoSize = self.button.AbsoluteSize
	local guiInsetY = self.gui.IgnoreGuiInset and 0 or 36
	local absSize = self.gui.AbsoluteSize

	local x = logoPos.X + logoSize.X + TOOLTIP_OFFSET_X
	local y = logoPos.Y + logoSize.Y - guiInsetY
	self.tooltip.frame.Position = UDim2.fromScale(x / absSize.X, y / absSize.Y)
end

local function showTooltip(self)
	if not self.entry then
		return
	end

	positionTooltip(self)
	self.tooltip.frame.Visible = true
end

local function hideTooltip(self)
	self.tooltip.frame.Visible = false
end

function EquippedShovelUI.new()
	local self = setmetatable({}, EquippedShovelUI)

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "EquippedShovelGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.DisplayOrder = 22
	gui.Parent = playerGui

	-- ImageButton acts as the hover surface. The icon image (or procedural
	-- shovel silhouette) is parented inside it and swapped per-shovel.
	-- The button itself is fully transparent (no fill, gradient, stroke, or
	-- shadow) so the shovel icon floats directly on the world view.
	-- Logo button: LOGO_SIZE=92px, margins 22px each.
	-- At 1920×1080 reference: x=22/1920=0.011, y=1-(22/1080)=0.980; size=92/1920×92/1080=0.048×0.085
	local button = Instance.new("ImageButton")
	button.Name = "EquippedShovelLogo"
	button.AnchorPoint = Vector2.new(0, 1)
	button.Position = UDim2.fromScale(0.011, 0.980)
	button.Size = UDim2.fromScale(0.048, 0.085)
	button.BackgroundTransparency = 1
	button.AutoButtonColor = false
	button.Image = ""
	button.BorderSizePixel = 0
	button.Parent = gui

	-- Container that holds whichever shovel rendering is active (image or
	-- procedural). Cleared and rebuilt each `setShovel` call so we don't
	-- leak old children when the player upgrades shovels.
	local iconContainer = Instance.new("Frame")
	iconContainer.Name = "IconContainer"
	iconContainer.AnchorPoint = Vector2.new(0.5, 0.5)
	iconContainer.Position = UDim2.fromScale(0.5, 0.45)
	iconContainer.Size = UDim2.fromScale(0.96, 0.96)
	iconContainer.BackgroundTransparency = 1
	iconContainer.Parent = button

	-- Bottom-strip name label so the player can read the shovel name without
	-- needing to hover. Same outlined GothamBlack treatment used for the
	-- side button labels.
	-- nameLabel: anchored bottom-centre of button; offset 4/92=0.043 from bottom
	-- width: (1 - 10/92) = 0.891; height: 0.24 of button
	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "NameLabel"
	nameLabel.AnchorPoint = Vector2.new(0.5, 1)
	nameLabel.Position = UDim2.new(0.5, 0, 0.957, 0)
	nameLabel.Size = UDim2.fromScale(0.891, 0.24)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.GothamBlack
	nameLabel.Text = ""
	nameLabel.TextColor3 = LABEL_COLOR
	nameLabel.TextScaled = true
	nameLabel.ZIndex = button.ZIndex + 2
	nameLabel.Parent = button

	local nameStroke = Instance.new("UIStroke")
	nameStroke.Color = LABEL_OUTLINE
	nameStroke.Thickness = 2
	nameStroke.LineJoinMode = Enum.LineJoinMode.Round
	nameStroke.Parent = nameLabel

	local nameSizeConstraint = Instance.new("UITextSizeConstraint")
	nameSizeConstraint.MaxTextSize = 14
	nameSizeConstraint.MinTextSize = 9
	nameSizeConstraint.Parent = nameLabel

	-- Hidden until the player steps on the dig site; show() triggers the pop-in.
	button.Visible = false

	UIAnimations.bindHover(button, { hoverScale = 1.06, pressScale = 0.96 })

	self.gui = gui
	self.button = button
	self.iconContainer = iconContainer
	self.nameLabel = nameLabel
	self.tooltip = buildTooltip(gui)
	self.entry = nil :: any
	self._hasPopped = false

	button.MouseEnter:Connect(function()
		showTooltip(self)
	end)
	button.MouseLeave:Connect(function()
		hideTooltip(self)
	end)

	-- Reposition the tooltip on viewport resize so it doesn't drift away
	-- from the logo when the player rotates a tablet or resizes the window.
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			if self.tooltip.frame.Visible then
				positionTooltip(self)
			end
		end)
	end

	return self
end

function EquippedShovelUI.show(self)
	if self.button.Visible then
		return
	end

	self.button.Visible = true

	if not self._hasPopped then
		self._hasPopped = true
		UIAnimations.popIn(self.button, { fromScale = 0.5 })
	end
end

function EquippedShovelUI.hide(self)
	hideTooltip(self)
	self.button.Visible = false
end

-- Render the logo + tooltip for the given ShovelEntry. Called by the owning
-- controller every time the player's equipped shovel changes.
function EquippedShovelUI.setShovel(self, entry: ShovelConfig.ShovelEntry?)
	local resolved = entry or ShovelConfig.getOrDefault(nil)
	if self.entry and self.entry.id == resolved.id then
		return
	end

	self.entry = resolved

	local accent = resolved.visual.accentColor

	-- Wipe whatever icon rendering was active before so we don't double-draw
	-- when upgrading shovels.
	for _, child in self.iconContainer:GetChildren() do
		child:Destroy()
	end

	local assetId = resolveIconAsset(resolved.iconName)
	if assetId then
		local image = Instance.new("ImageLabel")
		image.Name = "ShovelIcon"
		image.AnchorPoint = Vector2.new(0.5, 0.5)
		image.Position = UDim2.fromScale(0.5, 0.5)
		image.Size = UDim2.fromScale(1, 1)
		image.BackgroundTransparency = 1
		image.Image = assetId
		image.ScaleType = Enum.ScaleType.Fit
		image.Parent = self.iconContainer
	else
		buildProceduralShovel(self.iconContainer, accent, resolved.visual.bladeColor)
	end

	-- Strip the redundant " Shovel" suffix on the bottom strip so the label
	-- doesn't get squeezed too small ("Brainrot Shovel" -> "BRAINROT").
	local shortName = resolved.displayName:gsub(" Shovel$", "")
	self.nameLabel.Text = shortName:upper()

	self.tooltip.title.Text = resolved.displayName
	self.tooltip.tagline.Text = resolved.tagline
	self.tooltip.hitsValue.Text = formatHits(resolved.stats.requiredHits)
	self.tooltip.breakValue.Text = formatPercent(resolved.stats.breakPerHit)
	self.tooltip.luckValue.Text = formatLuck(resolved.stats.baseLuck)

	if self.tooltip.frame.Visible then
		positionTooltip(self)
	end
end

function EquippedShovelUI.Destroy(self)
	hideTooltip(self)
	if self.gui then
		self.gui:Destroy()
		self.gui = nil :: any
	end
end

return EquippedShovelUI
