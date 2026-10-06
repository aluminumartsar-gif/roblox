-- A polished, reusable inventory slot "card", shared by the hotbar and the
-- backpack grid. It renders a brainrot as a real 3D thumbnail (ViewportFrame)
-- plus a clean name, a variant badge, a compact green price pill, an optional
-- slot-number badge, and an animated selection glow.
--
-- The card is *attached* into an existing host GuiObject (a hotbar Item frame
-- or a backpack slot button). It neutralises the host's own visuals and draws
-- everything itself, so callers keep their existing drag/drop and click wiring
-- on the host untouched — only the look changes.
--
-- Thumbnails are expensive to build, so they are cached per (brainrotId,
-- variantId) and only re-rendered when the item identity actually changes.
-- Selection and price updates never rebuild the viewport.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder   = Shared:WaitForChild("Util")
local BrainrotConfig  = require(ConfigFolder:WaitForChild("BrainrotConfig"))
local VariantConfig   = require(ConfigFolder:WaitForChild("VariantConfig"))
local EconomyConfig   = require(ConfigFolder:WaitForChild("EconomyConfig"))
local FormatUtil      = require(UtilFolder:WaitForChild("FormatUtil"))
local ThumbnailBounds = require(script.Parent:WaitForChild("ThumbnailBounds"))

local InventorySlotCard = {}

-- ─── palette ───────────────────────────────────────────────────────────────

local CARD_TOP        = Color3.fromRGB(38, 42, 64)
local CARD_BOTTOM     = Color3.fromRGB(14, 16, 26)
local PRICE_TOP       = Color3.fromRGB(74, 200, 110)
local PRICE_BOTTOM    = Color3.fromRGB(36, 130, 70)
local PRICE_STROKE    = Color3.fromRGB(20, 78, 44)
local SELECT_GLOW     = Color3.fromRGB(255, 226, 104)
local NUMBER_BG       = Color3.fromRGB(12, 14, 22)
local DEFAULT_RARITY  = Color3.fromRGB(184, 190, 208)

local BRAINROTS_FOLDER_NAME = "Brainrots"
local THUMB_FOV     = 24
local THUMB_LOOK    = Vector3.new(0, -0.02, -1).Unit
local THUMB_PADDING = 1.22

local SELECT_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- ─── small builders ──────────────────────────────────────────────────────────

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
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
	return stroke
end

local function addGradient(parent: Instance, top: Color3, bottom: Color3, rotation: number?)
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(top, bottom)
	gradient.Rotation = rotation or 90
	gradient.Parent = parent
	return gradient
end

-- ─── thumbnail rendering ──────────────────────────────────────────────────────

local function sanitizeViewportClone(instance: Instance)
	if instance:IsA("BaseScript") or instance:IsA("ProximityPrompt") or instance:IsA("BillboardGui") then
		instance:Destroy()
		return
	end
	if instance:IsA("BasePart") then
		instance.Anchored = true
		instance.CanCollide = false
		instance.CanTouch = false
	end
end

local function clearViewport(viewport: ViewportFrame)
	for _, child in viewport:GetChildren() do
		if not child:IsA("UICorner") then
			child:Destroy()
		end
	end
	viewport.CurrentCamera = nil
end

-- Applies only the *static* part of a variant's look — body colour + material —
-- to a cloned model. We deliberately skip BrainrotVisualFactory.applyVariant
-- here: its particles, point lights and highlights aren't rendered inside a
-- ViewportFrame, and its rainbow variants spin up a per-frame Heartbeat loop
-- that would re-tint parts (and force a viewport re-render) forever on every
-- cached thumbnail. The variant badge + name colour carry the rest.
local function applyStaticVariantTint(clone: Instance, variantId: string?)
	if not variantId or variantId == VariantConfig.NORMAL_ID or not VariantConfig.isKnown(variantId) then
		return
	end

	local entry = VariantConfig.getById(variantId)
	local bodyColor = entry.bodyColor
	local material = entry.materialOverride
	if not bodyColor and not material then
		return
	end

	local function tint(part: BasePart)
		if bodyColor then part.Color = bodyColor end
		if material then part.Material = material end
	end

	if clone:IsA("BasePart") then
		tint(clone)
	end
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("BasePart") then
			tint(descendant)
		end
	end
end

-- Renders the brainrot model into the viewport, framed by its visible bounds.
-- Returns true on success, false if the model template is missing.
local function renderThumbnail(viewport: ViewportFrame, brainrotId: string, variantId: string?): boolean
	clearViewport(viewport)

	local folder = ReplicatedStorage:FindFirstChild(BRAINROTS_FOLDER_NAME)
	local template = if folder then folder:FindFirstChild(brainrotId) else nil
	if not template then
		return false
	end

	local clone = template:Clone()
	for _, descendant in clone:GetDescendants() do
		sanitizeViewportClone(descendant)
	end
	sanitizeViewportClone(clone)

	applyStaticVariantTint(clone, variantId)

	local camera = Instance.new("Camera")
	camera.Parent = viewport

	local center, size = ThumbnailBounds.getVisibleBounds(clone)
	local viewportSize = viewport.AbsoluteSize
	local aspectRatio = if viewportSize.Y > 0 then viewportSize.X / viewportSize.Y else 1
	local distance = math.max(
		ThumbnailBounds.getFramingDistance(center, size, THUMB_LOOK, THUMB_FOV, aspectRatio, THUMB_PADDING),
		3
	)
	camera.FieldOfView = THUMB_FOV
	camera.CFrame = CFrame.new(center - THUMB_LOOK * distance, center)

	-- Skinned/rigged meshes only render inside a ViewportFrame when they live
	-- under a WorldModel — without it the thumbnail comes up blank. (This is why
	-- the brainrot reveal screen wraps its model the same way.)
	local world = Instance.new("WorldModel")
	world.Parent = viewport
	clone.Parent = world

	viewport.CurrentCamera = camera
	return true
end

-- ─── card ──────────────────────────────────────────────────────────────────

export type Card = {
	instance: Frame,
	render: (item: any, ctx: { rebirths: number?, slotNumber: number? }?) -> (),
	setSelected: (selected: boolean, animate: boolean?) -> (),
	destroy: () -> (),
}

-- Attaches a card into `host`. `opts.showNumber` toggles the slot-number badge.
function InventorySlotCard.attach(host: GuiObject, opts: { showNumber: boolean? }?): Card
	opts = opts or {}
	local showNumber = opts.showNumber == true

	-- Neutralise the host so only the card shows through.
	if host:IsA("ImageButton") or host:IsA("ImageLabel") then
		(host :: ImageButton).ImageTransparency = 1
	end
	if host:IsA("GuiButton") then
		(host :: GuiButton).AutoButtonColor = false
	end
	host.BackgroundTransparency = 1
	host.ClipsDescendants = false
	for _, child in host:GetChildren() do
		if child:IsA("TextLabel") or child:IsA("ImageLabel") then
			child.Visible = false
		end
	end

	local originalHostZ = host.ZIndex

	-- Root card frame fills the host and owns a UIScale for the selection pop.
	local card = Instance.new("Frame")
	card.Name = "SlotCard"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromScale(1, 1)
	card.BackgroundColor3 = CARD_TOP
	card.BorderSizePixel = 0
	card.ZIndex = 2
	card.Parent = host
	addCorner(card, 0.16)
	local bgGradient = addGradient(card, CARD_TOP, CARD_BOTTOM)
	local rarityStroke = addStroke(card, DEFAULT_RARITY, 2, 0.05)

	local cardScale = Instance.new("UIScale")
	cardScale.Scale = 1
	cardScale.Parent = card

	-- Selection glow — a thicker, normally-invisible outer stroke.
	local glowStroke = Instance.new("UIStroke")
	glowStroke.Name = "GlowStroke"
	glowStroke.Color = SELECT_GLOW
	glowStroke.Thickness = 5
	glowStroke.Transparency = 1
	glowStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	glowStroke.Parent = card

	-- Thumbnail.
	local thumbHolder = Instance.new("Frame")
	thumbHolder.Name = "ThumbHolder"
	thumbHolder.AnchorPoint = Vector2.new(0.5, 0)
	thumbHolder.Position = UDim2.fromScale(0.5, 0.03)
	thumbHolder.Size = UDim2.fromScale(0.96, 0.7)
	thumbHolder.BackgroundTransparency = 1
	thumbHolder.ZIndex = 3
	thumbHolder.Parent = card

	local thumb = Instance.new("ViewportFrame")
	thumb.Name = "Thumb"
	thumb.Size = UDim2.fromScale(1, 1)
	thumb.BackgroundTransparency = 1
	thumb.BorderSizePixel = 0
	thumb.Ambient = Color3.fromRGB(200, 204, 220)
	thumb.LightColor = Color3.fromRGB(255, 255, 255)
	thumb.LightDirection = Vector3.new(-0.3, -1, -0.45)
	thumb.ZIndex = 3
	thumb.Parent = thumbHolder

	-- Fallback glyph shown when a model template is missing.
	local fallback = Instance.new("TextLabel")
	fallback.Name = "Fallback"
	fallback.Size = UDim2.fromScale(1, 1)
	fallback.BackgroundTransparency = 1
	fallback.Font = Enum.Font.GothamBlack
	fallback.Text = "?"
	fallback.TextColor3 = DEFAULT_RARITY
	fallback.TextScaled = true
	fallback.Visible = false
	fallback.ZIndex = 4
	fallback.Parent = thumbHolder

	-- Price pill — the only text on the card.
	local pricePill = Instance.new("Frame")
	pricePill.Name = "PricePill"
	pricePill.AnchorPoint = Vector2.new(0.5, 1)
	pricePill.Position = UDim2.fromScale(0.5, 0.97)
	pricePill.Size = UDim2.fromScale(0.88, 0.24)
	pricePill.BackgroundColor3 = PRICE_TOP
	pricePill.BorderSizePixel = 0
	pricePill.ZIndex = 5
	pricePill.Parent = card
	addCorner(pricePill, 0.5)
	addGradient(pricePill, PRICE_TOP, PRICE_BOTTOM)
	addStroke(pricePill, PRICE_STROKE, 1.5, 0.1)

	local priceText = Instance.new("TextLabel")
	priceText.Name = "PriceText"
	priceText.AnchorPoint = Vector2.new(0.5, 0.5)
	priceText.Position = UDim2.fromScale(0.5, 0.5)
	priceText.Size = UDim2.fromScale(0.9, 0.74)
	priceText.BackgroundTransparency = 1
	priceText.Font = Enum.Font.GothamBlack
	priceText.Text = "$0/s"
	priceText.TextColor3 = Color3.fromRGB(255, 255, 255)
	priceText.TextScaled = true
	priceText.TextStrokeTransparency = 0.6
	priceText.ZIndex = 6
	priceText.Parent = pricePill

	-- Small, low-key slot-number chip (top-left). Variant/rarity are conveyed by
	-- the card's border colour and the model tint, not by extra text.
	local numberBadge = Instance.new("Frame")
	numberBadge.Name = "NumberBadge"
	numberBadge.AnchorPoint = Vector2.new(0, 0)
	numberBadge.Position = UDim2.fromScale(0.05, 0.05)
	numberBadge.Size = UDim2.fromScale(0.24, 0.24)
	numberBadge.BackgroundColor3 = NUMBER_BG
	numberBadge.BackgroundTransparency = 0.25
	numberBadge.BorderSizePixel = 0
	numberBadge.Visible = false
	numberBadge.ZIndex = 7
	numberBadge.Parent = card
	addCorner(numberBadge, 0.35)
	local numberAspect = Instance.new("UIAspectRatioConstraint")
	numberAspect.AspectRatio = 1
	numberAspect.Parent = numberBadge
	addStroke(numberBadge, Color3.fromRGB(255, 255, 255), 1, 0.65)

	local numberText = Instance.new("TextLabel")
	numberText.Name = "NumberText"
	numberText.AnchorPoint = Vector2.new(0.5, 0.5)
	numberText.Position = UDim2.fromScale(0.5, 0.5)
	numberText.Size = UDim2.fromScale(0.72, 0.72)
	numberText.BackgroundTransparency = 1
	numberText.Font = Enum.Font.GothamBold
	numberText.Text = ""
	numberText.TextColor3 = Color3.fromRGB(230, 232, 240)
	numberText.TextScaled = true
	numberText.ZIndex = 8
	numberText.Parent = numberBadge

	-- ── state ──
	local renderedKey: string? = nil
	local isSelected = false

	local function render(item: any, ctx)
		ctx = ctx or {}

		if not item or type(item.id) ~= "string" then
			card.Visible = false
			renderedKey = nil
			return
		end
		card.Visible = true

		local entry = BrainrotConfig.getById(item.id)
		local rarityColor = if entry then entry.color else DEFAULT_RARITY

		local variantId = item.variantId
		local hasVariant = variantId ~= nil
			and variantId ~= VariantConfig.NORMAL_ID
			and VariantConfig.isKnown(variantId)
		local variantEntry = if hasVariant then VariantConfig.getById(variantId) else nil
		local accent = if variantEntry then variantEntry.nameColor else rarityColor

		-- Rarity (and any variant) is conveyed by the border colour + model tint,
		-- not by extra text — keeping each slot quiet and readable.
		bgGradient.Color = ColorSequence.new(rarityColor:Lerp(CARD_TOP, 0.74), CARD_BOTTOM)
		rarityStroke.Color = accent

		local rate = EconomyConfig.computeEarningsRate(
			item.value or 0,
			EconomyConfig.getCashMultiplier(ctx.rebirths or 0)
		)
		priceText.Text = FormatUtil.money(rate) .. "/s"

		if showNumber and ctx.slotNumber then
			numberBadge.Visible = true
			numberText.Text = tostring(ctx.slotNumber)
		else
			numberBadge.Visible = false
		end

		-- Thumbnail is the expensive part — only rebuild on identity change.
		local key = item.id .. "|" .. tostring(variantId or "")
		if key ~= renderedKey then
			renderedKey = key
			local ok = false
			local success, result = pcall(renderThumbnail, thumb, item.id, variantId)
			if success then
				ok = result
			end
			fallback.Visible = not ok
			fallback.TextColor3 = rarityColor
		end
	end

	local function setSelected(selected: boolean, animate: boolean?)
		if selected == isSelected then
			-- Still keep host Z correct (cheap, idempotent).
			host.ZIndex = if selected then originalHostZ + 10 else originalHostZ
			return
		end
		isSelected = selected
		host.ZIndex = if selected then originalHostZ + 10 else originalHostZ

		local glowTransparency = if selected then 0.2 else 1
		local targetScale = if selected then 1.07 else 1

		if animate == false then
			glowStroke.Transparency = glowTransparency
			cardScale.Scale = targetScale
		else
			TweenService:Create(glowStroke, SELECT_TWEEN, { Transparency = glowTransparency }):Play()
			TweenService:Create(cardScale, SELECT_TWEEN, { Scale = targetScale }):Play()
		end
	end

	local function destroy()
		clearViewport(thumb)
		card:Destroy()
	end

	return {
		instance = card,
		render = render,
		setSelected = setSelected,
		destroy = destroy,
	}
end

return InventorySlotCard
