local TweenService = game:GetService("TweenService")

local FormatUtil = require(script.Parent:WaitForChild("FormatUtil"))
local RngTextStyle = require(script.Parent:WaitForChild("RngTextStyle"))
local ConfigFolder = script.Parent.Parent:WaitForChild("Config")
local VariantConfig = require(ConfigFolder:WaitForChild("VariantConfig"))
local IconAssets = require(ConfigFolder:WaitForChild("IconAssets"))

local BrainrotPlacard = {}

local DEFAULT_MAX_DISTANCE = 30
local DROP_LABEL_ATTRIBUTE = "BrainrotDropLabel"

local DEFAULT_NAME_COLOR = Color3.fromRGB(248, 244, 240)
local DEFAULT_RARITY_COLOR = Color3.new(1, 1, 1)
-- Bumped from RGB(80, 255, 120). The brighter lime cuts through outdoor
-- backdrops and gives the cash row the same "alive" feel as the variant tier.
local EARNINGS_COLOR = Color3.fromRGB(130, 255, 150)
local STROKE_COLOR = Color3.new(0, 0, 0)

-- Row layout weights are renormalized at create-time to fit whichever rows are
-- visible. Earnings is the second-most prominent row (after the brainrot's
-- name) and sits directly above it so the cash icon and rate land where the
-- eye lands first. Variant slots between rarity and earnings, name anchors
-- the bottom.
local ROW_DEFINITIONS = {
	{ key = "rng", layoutOrder = 1, sizeY = 0.24 },
	{ key = "rarity", layoutOrder = 2, sizeY = 0.24 },
	{ key = "variant", layoutOrder = 3, sizeY = 0.26 },
	{ key = "earnings", layoutOrder = 4, sizeY = 0.34 },
	{ key = "name", layoutOrder = 5, sizeY = 0.28 },
}

-- Tier rows (rng/rarity/earnings) share LuckiestGuy with the variant row so
-- the placard reads as one cohesive set of badges. The brainrot's actual name
-- keeps FredokaOne for personality and remains the calm anchor.
local DATA_ROW_FONT = Enum.Font.LuckiestGuy

-- Per-variant placard styling. Each entry tweaks the variant row to feel like
-- the variant itself: gold shimmers, lava blazes, rainbow rotates, bloodrot
-- looks ominous. Variants without an entry fall back to the variant's
-- displayName + nameColor, so the placard still renders for new variants
-- before bespoke styling is authored.
type VariantStyle = {
	text: string,
	font: Enum.Font?,
	gradient: ColorSequence?,
	gradientRotationSpeedDeg: number?,
	strokeColor: Color3?,
	strokeTransparency: number?,
}

local VARIANT_STYLES: { [string]: VariantStyle } = {
	Gold = {
		text = "✦ GOLD ✦",
		gradient = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 230, 130)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 250, 200)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 195, 50)),
		}),
		gradientRotationSpeedDeg = 90,
	},
	Diamond = {
		text = "◆ DIAMOND ◆",
		gradient = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(170, 235, 255)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 255, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 200, 255)),
		}),
		gradientRotationSpeedDeg = 60,
	},
	Lava = {
		text = "▲ LAVA ▲",
		gradient = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 220, 80)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 110, 40)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(140, 30, 10)),
		}),
		strokeColor = Color3.fromRGB(40, 0, 0),
		strokeTransparency = 0.1,
	},
	Rainbow = {
		text = "★ RAINBOW ★",
		gradient = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 80, 80)),
			ColorSequenceKeypoint.new(0.2, Color3.fromRGB(255, 200, 80)),
			ColorSequenceKeypoint.new(0.4, Color3.fromRGB(120, 255, 120)),
			ColorSequenceKeypoint.new(0.6, Color3.fromRGB(80, 200, 255)),
			ColorSequenceKeypoint.new(0.8, Color3.fromRGB(180, 120, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 100, 220)),
		}),
		gradientRotationSpeedDeg = 220,
	},
	Galaxy = {
		text = "✧ GALAXY ✧",
		gradient = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(190, 140, 255)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(80, 50, 180)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 255, 255)),
		}),
		gradientRotationSpeedDeg = 120,
	},
	Bloodrot = {
		text = "✠ BLOODROT ✠",
		gradient = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 50, 50)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(140, 0, 0)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(40, 0, 0)),
		}),
		strokeColor = Color3.fromRGB(20, 0, 0),
		strokeTransparency = 0,
	},
	Candy = {
		text = "♥ CANDY ♥",
		gradient = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 180, 230)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(150, 230, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 240, 180)),
		}),
		gradientRotationSpeedDeg = 180,
	},
}

local DEFAULT_VARIANT_FONT = Enum.Font.LuckiestGuy

local DEFAULT_HEADROOM_STUDS = 1
local FALLBACK_STUDS_OFFSET = Vector3.new(0, 3, 0)

-- Returns a world-space vertical offset (relative to `parent`) such that the
-- bottom of the placard ends up `headroom` studs above the top of `model`.
-- This sidesteps the "placard floats inside the brainrot's body" issue that
-- happens with a fixed studsOffset when the rootPart isn't at the model's
-- center. Only the Y component is non-zero; the placard stays aligned to the
-- part horizontally.
local function computeAboveModelOffset(parent: Instance, model: Instance, headroom: number): Vector3
	if not parent:IsA("BasePart") then
		return Vector3.new(0, headroom, 0)
	end

	local topY: number?
	if model:IsA("Model") then
		local cframe, size = model:GetBoundingBox()
		topY = cframe.Position.Y + size.Y / 2
	elseif model:IsA("BasePart") then
		topY = model.Position.Y + model.Size.Y / 2
	end

	if not topY then
		return Vector3.new(0, headroom, 0)
	end

	local heightAboveParent = topY - parent.Position.Y
	return Vector3.new(0, heightAboveParent + headroom, 0)
end

export type PlacardConfig = {
	parent: Instance,
	name: string?,
	rngText: string?,
	rngDenominator: number?,
	rarity: string?,
	rarityColor: Color3?,
	displayName: string,
	nameColor: Color3?,
	variantId: string?,
	earningsRate: number?,
	maxDistance: number?,
	studsOffset: Vector3?,
	-- Pass the brainrot's visual Model (or BasePart) and the placard will
	-- position itself above the model's actual top using GetBoundingBox,
	-- instead of relying on a fixed `studsOffset`. Use this so tall models
	-- don't end up with the placard buried inside their geometry. When set,
	-- `studsOffset` is ignored.
	aboveModel: Instance?,
	-- Studs of clear space between the model's top and the bottom of the
	-- placard stack. Defaults to 1 stud, only used when `aboveModel` is set.
	headroom: number?,
	enabled: boolean?,
	markAsDropLabel: boolean?,
}

export type Placard = {
	billboard: BillboardGui,
	setEnabled: (boolean) -> (),
	destroy: () -> (),
}

local function createLabel(
	parent: Instance,
	text: string,
	color: Color3,
	layoutOrder: number,
	heightScale: number,
	font: Enum.Font?
)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, heightScale)
	label.Font = font or Enum.Font.FredokaOne
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	label.TextStrokeColor3 = STROKE_COLOR
	-- Tightened from 0.4 / thickness 2 so every row reads as printed-on
	-- against bright outdoor backdrops instead of floating.
	label.TextStrokeTransparency = 0.15
	label.LayoutOrder = layoutOrder
	label.Parent = parent

	local stroke = Instance.new("UIStroke")
	stroke.Color = STROKE_COLOR
	stroke.Thickness = 2.5
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Parent = label

	return label
end

-- Spins a UIGradient on the given label so animated variants (rainbow, gold
-- shimmer, galaxy drift) read as alive instead of static. Speed is in degrees
-- per second; one full revolution stays smooth thanks to the linear tween.
local function spinGradient(gradient: UIGradient, degreesPerSecond: number)
	if degreesPerSecond <= 0 then
		return
	end

	local duration = 360 / degreesPerSecond
	task.spawn(function()
		while gradient.Parent do
			local tween = TweenService:Create(
				gradient,
				TweenInfo.new(duration, Enum.EasingStyle.Linear),
				{ Rotation = gradient.Rotation + 360 }
			)
			tween:Play()
			tween.Completed:Wait()
		end
	end)
end

local function applyVariantStyling(label: TextLabel, style: VariantStyle)
	if style.strokeColor then
		label.TextStrokeColor3 = style.strokeColor
		local stroke = label:FindFirstChildWhichIsA("UIStroke")
		if stroke then
			stroke.Color = style.strokeColor
		end
	end
	if style.strokeTransparency then
		label.TextStrokeTransparency = style.strokeTransparency
	end

	if style.gradient then
		local gradient = Instance.new("UIGradient")
		gradient.Color = style.gradient
		gradient.Parent = label

		if style.gradientRotationSpeedDeg then
			spinGradient(gradient, style.gradientRotationSpeedDeg)
		end
	end
end

-- Builds a soft "light -> base -> dark" gradient around `baseColor` so any
-- single-color row (rarity tier, earnings rate) reads as a static glossy badge
-- without authoring per-color gradients. Lightening lerps toward white,
-- darkening lerps toward black; the base color sits in the middle.
local function tintedGradient(baseColor: Color3): ColorSequence
	local lightenAmount = 0.45
	local darkenAmount = 0.4

	local light = baseColor:Lerp(Color3.new(1, 1, 1), lightenAmount)
	local dark = baseColor:Lerp(Color3.new(0, 0, 0), darkenAmount)

	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, light),
		ColorSequenceKeypoint.new(0.5, baseColor),
		ColorSequenceKeypoint.new(1, dark),
	})
end

local function applyTintedGradient(label: TextLabel, baseColor: Color3)
	local gradient = Instance.new("UIGradient")
	gradient.Color = tintedGradient(baseColor)
	gradient.Rotation = 90
	gradient.Parent = label
end

-- Builds a horizontally-packed earnings row: cash icon on the left, dollar
-- amount on the right, both centered as a group. The icon is sized to a
-- square that matches the row height via SizeConstraint.RelativeYY (X scale
-- references the parent's Y dimension). Returns the inner TextLabel so the
-- caller can apply the lime gradient to the text without touching the icon.
local function buildEarningsRow(
	parent: Instance,
	text: string,
	color: Color3,
	layoutOrder: number,
	heightScale: number,
	font: Enum.Font?
): TextLabel
	local row = Instance.new("Frame")
	row.Name = "EarningsRow"
	row.BackgroundTransparency = 1
	row.Size = UDim2.fromScale(1, heightScale)
	row.LayoutOrder = layoutOrder
	row.Parent = parent

	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Padding = UDim.new(0.04, 0)
	rowLayout.Parent = row

	local icon = Instance.new("ImageLabel")
	icon.Name = "CashIcon"
	icon.BackgroundTransparency = 1
	icon.Image = IconAssets.Cash
	icon.ScaleType = Enum.ScaleType.Fit
	-- RelativeYY makes both Size scales reference the parent's Y dimension,
	-- producing a square sized exactly to the row's height regardless of how
	-- the placard's vertical sizing renormalizes.
	icon.SizeConstraint = Enum.SizeConstraint.RelativeYY
	icon.Size = UDim2.fromScale(1, 1)
	icon.LayoutOrder = 1
	icon.Parent = row

	local label = Instance.new("TextLabel")
	label.Name = "EarningsText"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(0.62, 0, 1, 0)
	label.Font = font or Enum.Font.FredokaOne
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	label.TextStrokeColor3 = STROKE_COLOR
	label.TextStrokeTransparency = 0.15
	label.LayoutOrder = 2
	label.Parent = row

	local stroke = Instance.new("UIStroke")
	stroke.Color = STROKE_COLOR
	stroke.Thickness = 2.5
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Parent = label

	return label
end

local function resolveVariantRow(variantId: string?): { text: string, color: Color3, style: VariantStyle? }?
	if not VariantConfig.hasVariant(variantId) then
		return nil
	end

	local entry = VariantConfig.getById(variantId)
	local style = VARIANT_STYLES[entry.id]
	local text = if style and style.text then style.text else string.upper(entry.displayName)
	return {
		text = text,
		color = entry.nameColor,
		style = style,
	}
end

local function buildRowText(config: PlacardConfig)
	local rows = {}

	if config.rngText and config.rngText ~= "" then
		rows.rng = {
			text = ("RNG %s"):format(config.rngText),
			color = Color3.fromRGB(255, 255, 255),
			font = DATA_ROW_FONT,
		}
	end

	if config.rarity and config.rarity ~= "" then
		rows.rarity = {
			text = string.upper(config.rarity),
			color = config.rarityColor or DEFAULT_RARITY_COLOR,
			font = DATA_ROW_FONT,
			tintGradient = config.rarityColor or DEFAULT_RARITY_COLOR,
		}
	end

	local variantRow = resolveVariantRow(config.variantId)
	if variantRow then
		rows.variant = {
			text = variantRow.text,
			color = variantRow.color,
			style = variantRow.style,
			font = (variantRow.style and variantRow.style.font) or DEFAULT_VARIANT_FONT,
		}
	end

	rows.name = {
		text = config.displayName,
		color = config.nameColor or DEFAULT_NAME_COLOR,
	}

	if typeof(config.earningsRate) == "number" then
		rows.earnings = {
			text = ("%s/s"):format(FormatUtil.money(config.earningsRate)),
			color = EARNINGS_COLOR,
			font = DATA_ROW_FONT,
			tintGradient = EARNINGS_COLOR,
			withCashIcon = true,
		}
	end

	return rows
end

function BrainrotPlacard.create(config: PlacardConfig): Placard
	assert(config.parent, "BrainrotPlacard.create requires `parent`")
	assert(config.displayName, "BrainrotPlacard.create requires `displayName`")

	local existingName = config.name or "BrainrotPlacard"
	local existing = config.parent:FindFirstChild(existingName)
	if existing then
		existing:Destroy()
	end

	local rows = buildRowText(config)

	-- Collect only the row definitions that have content this placard, then
	-- renormalize their sizeY weights so they always sum to 1. This way adding
	-- the variant row (or omitting rarity/earnings) keeps the stack flush
	-- without overflowing or leaving a gap.
	local visibleDefinitions = {}
	local totalSizeY = 0
	for _, definition in ROW_DEFINITIONS do
		if rows[definition.key] then
			table.insert(visibleDefinitions, definition)
			totalSizeY += definition.sizeY
		end
	end

	local visibleRowCount = #visibleDefinitions

	-- World-space stud dimensions so the placard scales with distance (shrinks
	-- as the player walks away) instead of holding a fixed pixel footprint.
	-- Width matches the UpgradeBillboard convention; height grows one slot per
	-- visible row so the stack never feels cramped or wasted.
	local heightPerRow = 0.6
	local height = math.max(heightPerRow * visibleRowCount, heightPerRow * 2)

	-- `aboveModel` wins when both are provided; that path measures the actual
	-- bounding box and clears the model regardless of where the rootPart sits
	-- inside it. `studsOffset` remains as an explicit override for callers
	-- that want exact placement (the default is the legacy 3-stud lift).
	local studsOffset: Vector3
	if config.aboveModel then
		local headroom = config.headroom or DEFAULT_HEADROOM_STUDS
		studsOffset = computeAboveModelOffset(config.parent, config.aboveModel, headroom)
	else
		studsOffset = config.studsOffset or FALLBACK_STUDS_OFFSET
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = existingName
	billboard.Size = UDim2.fromScale(4.5, height)
	billboard.StudsOffsetWorldSpace = studsOffset
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = config.maxDistance or DEFAULT_MAX_DISTANCE
	billboard.Enabled = config.enabled ~= false
	if config.markAsDropLabel then
		billboard:SetAttribute(DROP_LABEL_ATTRIBUTE, true)
	end

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	-- 1 px between rows so each tier reads on its own instead of the stack
	-- collapsing into one wall of text.
	layout.Padding = UDim.new(0.01, 0)
	layout.Parent = billboard

	local labels = {}
	for _, definition in visibleDefinitions do
		local row = rows[definition.key]
		local heightScale = if totalSizeY > 0 then definition.sizeY / totalSizeY else definition.sizeY
		if row.withCashIcon then
			labels[definition.key] = buildEarningsRow(
				billboard,
				row.text,
				row.color,
				definition.layoutOrder,
				heightScale,
				row.font
			)
		else
			labels[definition.key] = createLabel(
				billboard,
				row.text,
				row.color,
				definition.layoutOrder,
				heightScale,
				row.font
			)
		end
	end

	if labels.rng then
		RngTextStyle.apply(labels.rng, config.rngDenominator)
	end

	if labels.rarity and rows.rarity and rows.rarity.tintGradient then
		applyTintedGradient(labels.rarity, rows.rarity.tintGradient)
	end

	if labels.earnings and rows.earnings and rows.earnings.tintGradient then
		applyTintedGradient(labels.earnings, rows.earnings.tintGradient)
	end

	if labels.variant and rows.variant and rows.variant.style then
		applyVariantStyling(labels.variant, rows.variant.style)
	end

	billboard.Parent = config.parent

	local placard
	placard = {
		billboard = billboard,
		setEnabled = function(enabled: boolean)
			if billboard.Parent then
				billboard.Enabled = enabled
			end
		end,
		destroy = function()
			if billboard.Parent then
				billboard:Destroy()
			end
		end,
	}

	return placard
end

return BrainrotPlacard
