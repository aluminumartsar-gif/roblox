local TweenService = game:GetService("TweenService")

local FormatUtil = require(script.Parent:WaitForChild("FormatUtil"))
local IconAssets = require(script.Parent.Parent:WaitForChild("Config"):WaitForChild("IconAssets"))

local UpgradeBillboard = {}

local DEFAULT_MAX_DISTANCE = 60

-- Card sizes are in studs (UDim2.fromScale) so the billboard behaves like a
-- real in-world sign: small from across the base and bigger as the player
-- walks up to the pad. All child sizes are scale-based for the same reason;
-- mixing pixel-based children with a stud-based billboard would make the
-- layout balloon on close approach.
local CARD_WIDTH_STUDS = 4.5
local CARD_HEIGHT_ACTIVE_STUDS = 2.4
local CARD_HEIGHT_COMPACT_STUDS = 0.85

-- Card surface and stroke colors are unique to each state so the player can
-- read at a glance whether a floor is the next purchase, already owned, or
-- still gated by a higher tier.
local CARD_BG = Color3.fromRGB(18, 16, 28)
local CARD_BG_TOP = Color3.fromRGB(34, 28, 56)
local UNLOCKED_BG = Color3.fromRGB(20, 32, 22)
local UNLOCKED_BG_TOP = Color3.fromRGB(38, 64, 44)
local LOCKED_BG = Color3.fromRGB(22, 22, 28)
local LOCKED_BG_TOP = Color3.fromRGB(44, 44, 54)
local MAX_BG = Color3.fromRGB(42, 28, 8)
local MAX_BG_TOP = Color3.fromRGB(96, 64, 16)

local TEXT_PRIMARY = Color3.fromRGB(255, 255, 255)
local TEXT_DIM = Color3.fromRGB(180, 180, 195)
local TEXT_DEEP_DIM = Color3.fromRGB(140, 140, 160)
local COST_COLOR = Color3.fromRGB(140, 255, 160)
local REBIRTH_COLOR = Color3.fromRGB(220, 170, 255)
local UNLOCKED_COLOR = Color3.fromRGB(170, 255, 180)
local MAX_COLOR = Color3.fromRGB(255, 220, 110)
local STROKE_COLOR = Color3.fromRGB(0, 0, 0)

local TITLE_FONT = Enum.Font.LuckiestGuy
local VALUE_FONT = Enum.Font.LuckiestGuy
local LABEL_FONT = Enum.Font.FredokaOne

export type Config = {
	parent: BasePart,
	name: string?,
	studsOffset: Vector3?,
	maxDistance: number?,
}

export type Billboard = {
	instance: BillboardGui,
	setNext: (tierName: string, cost: number, rebirths: number, accentColor: Color3) -> (),
	setUnlocked: (tierName: string) -> (),
	setLocked: (tierName: string) -> (),
	setMax: (tierName: string) -> (),
	destroy: () -> (),
}

local function addCorner(parent: Instance, scale: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(scale, 0)
	corner.Parent = parent
	return corner
end

local function addStroke(parent: Instance, color: Color3, thickness: number, transparency: number?)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Transparency = transparency or 0
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
	return stroke
end

local function addGradient(parent: Instance, top: Color3, bottom: Color3, rotation: number?)
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, top),
		ColorSequenceKeypoint.new(1, bottom),
	})
	gradient.Rotation = rotation or 90
	gradient.Parent = parent
	return gradient
end

-- Padding values are scales (0..1) of the parent so the layout shrinks and
-- grows with the billboard's stud-based size.
local function addPadding(parent: Instance, vertical: number, horizontal: number)
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(vertical, 0)
	padding.PaddingBottom = UDim.new(vertical, 0)
	padding.PaddingLeft = UDim.new(horizontal, 0)
	padding.PaddingRight = UDim.new(horizontal, 0)
	padding.Parent = parent
	return padding
end

local function lighten(color: Color3, amount: number)
	return Color3.new(
		math.clamp(color.R + amount, 0, 1),
		math.clamp(color.G + amount, 0, 1),
		math.clamp(color.B + amount, 0, 1)
	)
end

-- Tweens the stroke transparency in a loop so the active "next upgrade" card
-- breathes gently and reads as interactive. Stops itself once the stroke is
-- destroyed (state changed to unlocked / locked / max).
local function pulseStroke(stroke: UIStroke, baseTransparency: number)
	task.spawn(function()
		while stroke.Parent do
			local out = TweenService:Create(
				stroke,
				TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ Transparency = math.max(0, baseTransparency - 0.4) }
			)
			out:Play()
			out.Completed:Wait()
			if not stroke.Parent then
				break
			end
			local back = TweenService:Create(
				stroke,
				TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ Transparency = baseTransparency }
			)
			back:Play()
			back.Completed:Wait()
		end
	end)
end

local function clearChildren(frame: GuiObject)
	for _, child in frame:GetChildren() do
		if
			child:IsA("GuiObject")
			or child:IsA("UIGradient")
			or child:IsA("UIStroke")
			or child:IsA("UICorner")
			or child:IsA("UIPadding")
			or child:IsA("UIListLayout")
		then
			child:Destroy()
		end
	end
end

local function createTitle(
	parent: Instance,
	text: string,
	color: Color3,
	font: Enum.Font,
	layoutOrder: number,
	heightScale: number
)
	local label = Instance.new("TextLabel")
	label.Name = "Title"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, heightScale, 0)
	label.Font = font
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	label.TextStrokeColor3 = STROKE_COLOR
	label.TextStrokeTransparency = 0.15
	label.LayoutOrder = layoutOrder
	label.Parent = parent

	local stroke = Instance.new("UIStroke")
	stroke.Color = STROKE_COLOR
	stroke.Thickness = 1.5
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Parent = label

	return label
end

local function createInfoRow(
	parent: Instance,
	labelText: string,
	valueText: string,
	valueColor: Color3,
	layoutOrder: number,
	heightScale: number,
	valueIcon: string?
)
	local row = Instance.new("Frame")
	row.Name = labelText
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, heightScale, 0)
	row.LayoutOrder = layoutOrder
	row.Parent = parent

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0, 0.5)
	label.Position = UDim2.new(0, 0, 0.5, 0)
	label.Size = UDim2.new(0.4, 0, 1, 0)
	label.Font = LABEL_FONT
	label.Text = labelText
	label.TextColor3 = TEXT_DIM
	label.TextScaled = true
	label.TextStrokeColor3 = STROKE_COLOR
	label.TextStrokeTransparency = 0.4
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = row

	-- When a `valueIcon` is provided the value column reserves a square-shaped
	-- icon slot at the right edge (sized to the row's height) and the text
	-- slot shrinks to make room. The icon and text read as a single
	-- right-aligned group, e.g. "$5,000 [cash]".
	local hasIcon = valueIcon ~= nil and valueIcon ~= ""
	local iconSlotScale = if hasIcon then 0.16 else 0
	local valueWidth = UDim2.new(0.6 - iconSlotScale, 0, 1, 0)
	local valuePosition = UDim2.new(1 - iconSlotScale, 0, 0.5, 0)

	local value = Instance.new("TextLabel")
	value.Name = "Value"
	value.BackgroundTransparency = 1
	value.AnchorPoint = Vector2.new(1, 0.5)
	value.Position = valuePosition
	value.Size = valueWidth
	value.Font = VALUE_FONT
	value.Text = valueText
	value.TextColor3 = valueColor
	value.TextScaled = true
	value.TextStrokeColor3 = STROKE_COLOR
	value.TextStrokeTransparency = 0.2
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.Parent = row

	local valueStroke = Instance.new("UIStroke")
	valueStroke.Color = STROKE_COLOR
	valueStroke.Thickness = 1.25
	valueStroke.LineJoinMode = Enum.LineJoinMode.Round
	valueStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	valueStroke.Parent = value

	if hasIcon then
		local icon = Instance.new("ImageLabel")
		icon.Name = "ValueIcon"
		icon.AnchorPoint = Vector2.new(1, 0.5)
		icon.Position = UDim2.new(1, 0, 0.5, 0)
		-- RelativeYY: both Size scales reference the row's height, so a (1,1)
		-- scale produces a square sized to match the row's own height.
		icon.SizeConstraint = Enum.SizeConstraint.RelativeYY
		icon.Size = UDim2.fromScale(1, 1)
		icon.BackgroundTransparency = 1
		icon.Image = IconAssets[valueIcon] or ""
		icon.ScaleType = Enum.ScaleType.Fit
		icon.Parent = row
	end

	return row
end

local function buildEmptyCard(billboard: BillboardGui): Frame
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.BackgroundColor3 = CARD_BG
	card.BorderSizePixel = 0
	card.Size = UDim2.fromScale(1, 1)
	card.Parent = billboard
	addCorner(card, 0.08)
	return card
end

local function applyActiveLayout(card: Frame, accentColor: Color3, tierName: string, cost: number, rebirths: number)
	clearChildren(card)
	card.BackgroundColor3 = CARD_BG
	addCorner(card, 0.08)
	addGradient(card, lighten(CARD_BG_TOP, 0.05), CARD_BG)
	local stroke = addStroke(card, accentColor, 1.5, 0.05)
	pulseStroke(stroke, 0.05)
	addPadding(card, 0.06, 0.05)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	layout.Padding = UDim.new(0.025, 0)
	layout.Parent = card

	-- Row scale heights need to sum (with the layout gaps) to no more than the
	-- card's interior height after UIPadding is subtracted, or the bottom row
	-- gets clipped. Card padding eats 12% (6% top + 6% bottom) leaving 88%
	-- usable; rows + 3 layout gaps below come out to ~84%.
	local titleText = ("UNLOCK %s"):format(string.upper(tierName))
	local title = createTitle(card, titleText, TEXT_PRIMARY, TITLE_FONT, 1, 0.3)
	addGradient(title, lighten(accentColor, 0.25), accentColor, 90)

	local divider = Instance.new("Frame")
	divider.Name = "Divider"
	divider.BackgroundColor3 = accentColor
	divider.BackgroundTransparency = 0.45
	divider.BorderSizePixel = 0
	divider.Size = UDim2.new(0.85, 0, 0.02, 0)
	divider.LayoutOrder = 2
	divider.Parent = card

	createInfoRow(card, "Cost", FormatUtil.money(cost), COST_COLOR, 3, 0.22, "Cash")

	local rebirthValue = if rebirths == 1 then "1 Rebirth" else ("%d Rebirths"):format(rebirths)
	createInfoRow(card, "Need", rebirthValue, REBIRTH_COLOR, 4, 0.22, "Rebirth")
end

local function applyCompactLayout(
	card: Frame,
	bgColor: Color3,
	bgTopColor: Color3,
	strokeColor: Color3,
	textColor: Color3,
	titleText: string
)
	clearChildren(card)
	card.BackgroundColor3 = bgColor
	addCorner(card, 0.18)
	addGradient(card, bgTopColor, bgColor)
	addStroke(card, strokeColor, 1, 0.4)
	addPadding(card, 0.12, 0.06)

	local title = createTitle(card, titleText, textColor, TITLE_FONT, 1, 1)
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.Position = UDim2.fromScale(0.5, 0.5)
	title.Size = UDim2.fromScale(1, 1)
end

function UpgradeBillboard.create(config: Config): Billboard
	assert(config.parent and config.parent:IsA("BasePart"), "UpgradeBillboard.create requires `parent` BasePart")

	local existingName = config.name or "UpgradePadBillboard"
	local existing = config.parent:FindFirstChild(existingName)
	if existing then
		existing:Destroy()
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = existingName
	billboard.Size = UDim2.fromScale(CARD_WIDTH_STUDS, CARD_HEIGHT_ACTIVE_STUDS)
	billboard.StudsOffsetWorldSpace = config.studsOffset or Vector3.new(0, 3.4, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = config.maxDistance or DEFAULT_MAX_DISTANCE
	billboard.Parent = config.parent

	local card = buildEmptyCard(billboard)

	local placard
	placard = {
		instance = billboard,
		setNext = function(tierName: string, cost: number, rebirths: number, accentColor: Color3)
			billboard.Size = UDim2.fromScale(CARD_WIDTH_STUDS, CARD_HEIGHT_ACTIVE_STUDS)
			applyActiveLayout(card, accentColor, tierName, cost, rebirths)
		end,
		setUnlocked = function(tierName: string)
			billboard.Size = UDim2.fromScale(CARD_WIDTH_STUDS, CARD_HEIGHT_COMPACT_STUDS)
			applyCompactLayout(
				card,
				UNLOCKED_BG,
				UNLOCKED_BG_TOP,
				UNLOCKED_COLOR,
				UNLOCKED_COLOR,
				("%s ✓"):format(string.upper(tierName))
			)
		end,
		setLocked = function(tierName: string)
			billboard.Size = UDim2.fromScale(CARD_WIDTH_STUDS, CARD_HEIGHT_COMPACT_STUDS)
			applyCompactLayout(
				card,
				LOCKED_BG,
				LOCKED_BG_TOP,
				TEXT_DEEP_DIM,
				TEXT_DIM,
				("LOCKED — %s"):format(string.upper(tierName))
			)
		end,
		setMax = function(tierName: string)
			billboard.Size = UDim2.fromScale(CARD_WIDTH_STUDS, CARD_HEIGHT_COMPACT_STUDS)
			applyCompactLayout(
				card,
				MAX_BG,
				MAX_BG_TOP,
				MAX_COLOR,
				MAX_COLOR,
				("★ %s ★"):format(string.upper(tierName))
			)
		end,
		destroy = function()
			if billboard.Parent then
				billboard:Destroy()
			end
		end,
	}

	placard.setLocked("")

	return placard
end

return UpgradeBillboard
