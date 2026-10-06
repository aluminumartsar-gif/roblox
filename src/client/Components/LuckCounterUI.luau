local Players = game:GetService("Players")

local IconImage = require(script.Parent:WaitForChild("IconImage"))
local UIAnimations = require(script.Parent:WaitForChild("UIAnimations"))

local LuckCounterUI = {}

local PANEL_TOP    = Color3.fromRGB(48, 36, 28)
local PANEL_BOTTOM = Color3.fromRGB(20, 14, 10)
local STROKE_DEEP  = Color3.fromRGB(14, 10, 6)
local DIVIDER_COLOR = Color3.fromRGB(58, 44, 34)
local TEXT_MUTED   = Color3.fromRGB(140, 124, 100)
local LUCK_COLOR   = Color3.fromRGB(96, 220, 108)
local LUCK_STROKE  = Color3.fromRGB(18, 70, 32)

-- Reference design: 152 × 64 px. All internal scale values are derived from
-- these dimensions so the layout stays proportional at every screen size.
local REF_W = 152
local REF_H = 64

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

local function addGradient(parent: Instance, topColor: Color3, bottomColor: Color3)
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, topColor),
		ColorSequenceKeypoint.new(1, bottomColor),
	})
	gradient.Rotation = 90
	gradient.Parent = parent
end

local function addDropShadow(parent: GuiObject)
	local shadow = Instance.new("Frame")
	shadow.Name = "Shadow"
	shadow.AnchorPoint = Vector2.new(0.5, 0.5)
	shadow.Position = UDim2.new(0.5, 0, 0.5, 0)
	shadow.Size = UDim2.new(1, 0, 1.1, 0)
	shadow.BackgroundColor3 = Color3.new(0, 0, 0)
	shadow.BackgroundTransparency = 0.6
	shadow.BorderSizePixel = 0
	shadow.ZIndex = (parent.ZIndex or 1) - 1
	shadow.Parent = parent
	addCorner(shadow, UDim.new(0.25, 0))
end

local function formatLuckMultiplier(value: number)
	if value >= 1000 then
		return ("x%.2fK"):format(value / 1000)
	end

	return ("x%.2f"):format(value)
end

function LuckCounterUI.new()
	local self = setmetatable({}, { __index = LuckCounterUI })

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "LuckCounterGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.DisplayOrder = 20
	gui.Parent = playerGui

	local pill = Instance.new("Frame")
	pill.Name = "LuckCounter"
	pill.AnchorPoint = Vector2.new(0, 1)
	pill.BackgroundColor3 = PANEL_TOP
	pill.BorderSizePixel = 0
	-- Sits above the EquippedShovelUI logo (22px margin + 92px logo + 12px gap).
	pill.Position = UDim2.fromScale(0.012, 0.88)
	pill.Size = UDim2.new(0.11, 0, 0.09, 0)
	pill.Parent = gui

	local aspectRatio = Instance.new("UIAspectRatioConstraint")
	aspectRatio.AspectRatio = REF_W / REF_H
	aspectRatio.AspectType = Enum.AspectType.FitWithinMaxSize
	aspectRatio.DominantAxis = Enum.DominantAxis.Width
	aspectRatio.Parent = pill

	-- Corner radius as a proportion of the height so it stays consistent.
	addCorner(pill, UDim.new(14 / REF_H, 0))
	addGradient(pill, PANEL_TOP, PANEL_BOTTOM)
	addStroke(pill, STROKE_DEEP, 2, 0.1)
	addDropShadow(pill)

	-- All children use scale relative to REF_W × REF_H so they stay in
	-- proportion across every screen size.

	local clover = IconImage.add(pill, "Luck", {
		name = "CloverIcon",
		anchorPoint = Vector2.new(0, 0.5),
		position = UDim2.new(9 / REF_W, 0, 0.5, 0),
		size = UDim2.new(42 / REF_W, 0, 42 / REF_H, 0),
	})

	local divider = Instance.new("Frame")
	divider.Name = "Divider"
	divider.AnchorPoint = Vector2.new(0, 0.5)
	divider.BackgroundColor3 = DIVIDER_COLOR
	divider.BorderSizePixel = 0
	divider.Position = UDim2.new(58 / REF_W, 0, 0.5, 0)
	divider.Size = UDim2.new(1 / REF_W, 0, 36 / REF_H, 0)
	divider.Parent = pill

	-- Right section: "LUCK" label stacked above the multiplier value.
	local rightContainer = Instance.new("Frame")
	rightContainer.Name = "RightContainer"
	rightContainer.AnchorPoint = Vector2.new(1, 0.5)
	rightContainer.BackgroundTransparency = 1
	rightContainer.Position = UDim2.new((REF_W - 10) / REF_W, 0, 0.5, 0)
	rightContainer.Size = UDim2.new(82 / REF_W, 0, 40 / REF_H, 0)
	rightContainer.Parent = pill

	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Vertical
	listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	listLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(1 / 40, 0)
	listLayout.Parent = rightContainer

	local labelText = Instance.new("TextLabel")
	labelText.Name = "Label"
	labelText.BackgroundTransparency = 1
	labelText.Size = UDim2.new(1, 0, 13 / 40, 0)
	labelText.Font = Enum.Font.GothamBold
	labelText.Text = "LUCK"
	labelText.TextColor3 = TEXT_MUTED
	labelText.TextScaled = true
	labelText.TextXAlignment = Enum.TextXAlignment.Center
	labelText.LayoutOrder = 1
	labelText.Parent = rightContainer

	local labelConstraint = Instance.new("UITextSizeConstraint")
	labelConstraint.MaxTextSize = 12
	labelConstraint.MinTextSize = 6
	labelConstraint.Parent = labelText

	local valueLabel = Instance.new("TextLabel")
	valueLabel.Name = "Value"
	valueLabel.BackgroundTransparency = 1
	valueLabel.Size = UDim2.new(1, 0, 26 / 40, 0)
	valueLabel.Font = Enum.Font.GothamBlack
	valueLabel.Text = "x1.00"
	valueLabel.TextColor3 = LUCK_COLOR
	valueLabel.TextScaled = true
	valueLabel.TextStrokeColor3 = LUCK_STROKE
	valueLabel.TextStrokeTransparency = 0.3
	valueLabel.TextXAlignment = Enum.TextXAlignment.Center
	valueLabel.LayoutOrder = 2
	valueLabel.Parent = rightContainer

	local sizeConstraint = Instance.new("UITextSizeConstraint")
	sizeConstraint.MaxTextSize = 22
	sizeConstraint.MinTextSize = 9
	sizeConstraint.Parent = valueLabel

	UIAnimations.popIn(pill, { delay = 0.45, fromScale = 0.5 })
	self._cloverSpinCancel = UIAnimations.bindIdleSpin(clover, { degreesPerSecond = -8 })

	self.pill = pill
	self.clover = clover
	self.valueLabel = valueLabel
	self.luckMultiplier = 1

	return self
end

function LuckCounterUI:setLuckMultiplier(luckMultiplier: number)
	local nextMultiplier = math.max(1, luckMultiplier or 1)
	if math.abs(nextMultiplier - self.luckMultiplier) < 0.001 then
		return
	end

	self.luckMultiplier = nextMultiplier
	self.valueLabel.Text = formatLuckMultiplier(nextMultiplier)

	UIAnimations.bump(self.pill, { peakScale = 1.12, duration = 0.28 })
end

return LuckCounterUI
