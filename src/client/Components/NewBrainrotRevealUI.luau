local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local IconAssets = require(ConfigFolder:WaitForChild("IconAssets"))
local VariantConfig = require(ConfigFolder:WaitForChild("VariantConfig"))
local BrainrotVisualFactory = require(UtilFolder:WaitForChild("BrainrotVisualFactory"))
local FormatUtil = require(UtilFolder:WaitForChild("FormatUtil"))
local ThumbnailBounds = require(script.Parent:WaitForChild("ThumbnailBounds"))

local NewBrainrotRevealUI = {}
NewBrainrotRevealUI.__index = NewBrainrotRevealUI

local BRAINROTS_FOLDER_NAME = "Brainrots"
local THUMBNAIL_DEFAULT_ASPECT_RATIO = 1.1
local THUMBNAIL_FIELD_OF_VIEW = 28
local THUMBNAIL_LOOK_VECTOR = Vector3.new(0, -0.04, -1).Unit
local THUMBNAIL_PADDING = 1.16
local TEXT_PRIMARY = Color3.fromRGB(245, 248, 255)
local TEXT_SECONDARY = Color3.fromRGB(177, 188, 214)
local PANEL_TOP = Color3.fromRGB(31, 35, 58)
local PANEL_BOTTOM = Color3.fromRGB(7, 9, 18)
local SHINE_COLOR = Color3.fromRGB(255, 255, 255)
local DEFAULT_RARITY_COLOR = Color3.fromRGB(120, 255, 166)
local REVEAL_SOUND_ID = "rbxasset://sounds/button.wav"

export type RevealPayload = {
	brainrotId: string,
	variantId: string?,
	rarity: string?,
	rarityRank: number?,
	baseValue: number?,
	earningsRate: number?,
	rngText: string?,
	color: Color3?,
	revealColor: Color3?,
}

type RevealUI = typeof(setmetatable({} :: {
	_gui: ScreenGui,
	_overlay: Frame,
	_card: Frame,
	_title: TextLabel,
	_name: TextLabel,
	_rarity: TextLabel,
	_odds: TextLabel,
	_earnings: TextLabel,
	_earningsStroke: UIStroke,
	_viewportHolder: Frame,
	_viewport: ViewportFrame,
	_glowStroke: UIStroke,
	_cardStroke: UIStroke,
	_shine: Frame,
	_shineGradient: UIGradient,
	_sparkleLayer: Frame,
	_closeButton: ImageButton,
	_queue: { RevealPayload },
	_isShowing: boolean,
}, NewBrainrotRevealUI))

local function addCorner(parent: Instance, radius: UDim | number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = if typeof(radius) == "UDim" then radius else UDim.new(0, radius)
	corner.Parent = parent
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

local function tween(instance: Instance, duration: number, easingStyle: Enum.EasingStyle, easingDirection: Enum.EasingDirection, goals)
	local tweenInfo = TweenInfo.new(duration, easingStyle, easingDirection)
	local activeTween = TweenService:Create(instance, tweenInfo, goals)
	activeTween:Play()

	return activeTween
end

local function clearChildren(parent: Instance)
	for _, child in parent:GetChildren() do
		child:Destroy()
	end
end

local function clearViewportContents(viewport: ViewportFrame)
	for _, child in viewport:GetChildren() do
		if not child:IsA("UICorner") then
			child:Destroy()
		end
	end
	viewport.CurrentCamera = nil
end

local function playRevealSound(rarityRank: number)
	local sound = Instance.new("Sound")
	sound.Name = "NewBrainrotRevealSound"
	sound.SoundId = REVEAL_SOUND_ID
	sound.Volume = if rarityRank >= 6 then 0.95 elseif rarityRank >= 4 then 0.8 else 0.6
	sound.PlaybackSpeed = 1 + math.min(rarityRank, 7) * 0.04

	-- Route through the SFX SoundGroup if SettingsService has created it so the
	-- player's SFX volume slider applies. Falls back to direct playback when
	-- the group is missing (e.g. during early bootstrap).
	local sfxGroup = SoundService:FindFirstChild("SFX")
	if sfxGroup and sfxGroup:IsA("SoundGroup") then
		sound.SoundGroup = sfxGroup
	end

	sound.Parent = SoundService
	sound:Play()

	task.delay(1.2, function()
		sound:Destroy()
	end)
end

local function getRevealTitle(rarity: string?, rarityRank: number)
	if rarity == "Secret" then
		return "NEW SECRET BRAINROT!"
	end
	if rarityRank >= 6 then
		return "NEW GOD BRAINROT FOUND!"
	end

	return "NEW BRAINROT FOUND!"
end

function NewBrainrotRevealUI.new(): RevealUI
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "NewBrainrotRevealGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 85
	gui.Enabled = false
	gui.Parent = playerGui

	local overlay = Instance.new("Frame")
	overlay.Name = "Overlay"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	overlay.BackgroundTransparency = 1
	overlay.BorderSizePixel = 0
	overlay.Parent = gui

	local sparkleLayer = Instance.new("Frame")
	sparkleLayer.Name = "Sparkles"
	sparkleLayer.Size = UDim2.fromScale(1, 1)
	sparkleLayer.BackgroundTransparency = 1
	sparkleLayer.BorderSizePixel = 0
	sparkleLayer.Parent = overlay

	local card = Instance.new("Frame")
	card.Name = "RevealCard"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromScale(0.4, 0.62)
	card.BackgroundColor3 = PANEL_TOP
	card.BackgroundTransparency = 1
	card.BorderSizePixel = 0
	card.ClipsDescendants = true
	card.Parent = overlay
	addCorner(card, UDim.new(0.05, 0))
	addGradient(card, PANEL_TOP, PANEL_BOTTOM)
	local cardStroke = addStroke(card, DEFAULT_RARITY_COLOR, 3, 1)

	local glowStroke = Instance.new("UIStroke")
	glowStroke.Name = "GlowStroke"
	glowStroke.Color = DEFAULT_RARITY_COLOR
	glowStroke.Thickness = 9
	glowStroke.Transparency = 1
	glowStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	glowStroke.Parent = card

	-- The shine fills the full card and is invisible by default; the visible
	-- streak comes from the UIGradient's Transparency NumberSequence (a thin
	-- bright peak surrounded by full transparency). Animating the gradient's
	-- Offset slides the streak across without the Frame ever leaving the
	-- card, so we don't depend on ClipsDescendants for rotated children, and
	-- the streak reads as part of the card surface instead of a flat slab.
	-- ZIndex is bumped above the other card children (default 1) so the
	-- streak draws over the title, viewport, and stat labels in Sibling mode.
	local shine = Instance.new("Frame")
	shine.Name = "Shine"
	shine.AnchorPoint = Vector2.new(0.5, 0.5)
	shine.Position = UDim2.fromScale(0.5, 0.5)
	shine.Size = UDim2.fromScale(1, 1)
	shine.BackgroundColor3 = SHINE_COLOR
	shine.BackgroundTransparency = 0
	shine.BorderSizePixel = 0
	shine.Rotation = 0
	shine.ZIndex = 50
	shine.Parent = card

	local shineGradient = Instance.new("UIGradient")
	shineGradient.Name = "ShineGradient"
	shineGradient.Rotation = 70
	shineGradient.Color = ColorSequence.new(SHINE_COLOR)
	shineGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0.00, 1.00),
		NumberSequenceKeypoint.new(0.42, 1.00),
		NumberSequenceKeypoint.new(0.48, 0.55),
		NumberSequenceKeypoint.new(0.50, 0.35),
		NumberSequenceKeypoint.new(0.52, 0.55),
		NumberSequenceKeypoint.new(0.58, 1.00),
		NumberSequenceKeypoint.new(1.00, 1.00),
	})
	shineGradient.Offset = Vector2.new(-1, 0)
	shineGradient.Parent = shine

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromScale(0.07, 0.06)
	title.Size = UDim2.fromScale(0.76, 0.12)
	title.Font = Enum.Font.GothamBlack
	title.Text = "NEW BRAINROT FOUND!"
	title.TextColor3 = TEXT_PRIMARY
	title.TextScaled = true
	title.TextTransparency = 1
	title.Parent = card

	local viewportHolder = Instance.new("Frame")
	viewportHolder.Name = "ViewportHolder"
	viewportHolder.AnchorPoint = Vector2.new(0.5, 0)
	viewportHolder.Position = UDim2.fromScale(0.5, 0.2)
	viewportHolder.Size = UDim2.fromScale(0.48, 0.44)
	viewportHolder.BackgroundColor3 = Color3.fromRGB(20, 24, 40)
	viewportHolder.BackgroundTransparency = 1
	viewportHolder.BorderSizePixel = 0
	viewportHolder.Parent = card
	addCorner(viewportHolder, 26)
	addGradient(viewportHolder, Color3.fromRGB(52, 60, 90), Color3.fromRGB(13, 16, 29))
	addStroke(viewportHolder, Color3.fromRGB(255, 255, 255), 1, 0.85)

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Viewport"
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.BackgroundTransparency = 1
	viewport.BorderSizePixel = 0
	viewport.Ambient = Color3.fromRGB(255, 255, 255)
	viewport.LightColor = Color3.fromRGB(255, 255, 255)
	viewport.LightDirection = Vector3.new(-0.25, -1, -0.45)
	viewport.Parent = viewportHolder
	addCorner(viewport, 26)

	local name = Instance.new("TextLabel")
	name.Name = "BrainrotName"
	name.BackgroundTransparency = 1
	name.Position = UDim2.fromScale(0.07, 0.62)
	name.Size = UDim2.fromScale(0.86, 0.09)
	name.Font = Enum.Font.GothamBlack
	name.TextColor3 = TEXT_PRIMARY
	name.TextScaled = true
	name.TextTransparency = 1
	name.Parent = card

	local earnings = Instance.new("TextLabel")
	earnings.Name = "Earnings"
	earnings.AnchorPoint = Vector2.new(0.5, 0.5)
	earnings.BackgroundTransparency = 1
	earnings.Position = UDim2.fromScale(0.5, 0.79)
	earnings.Size = UDim2.fromScale(0.86, 0.12)
	earnings.Font = Enum.Font.GothamBlack
	earnings.Text = "+$0/s"
	earnings.TextColor3 = DEFAULT_RARITY_COLOR
	earnings.TextScaled = true
	earnings.TextTransparency = 1
	earnings.Parent = card

	local earningsStroke = Instance.new("UIStroke")
	earningsStroke.Name = "EarningsGlow"
	earningsStroke.Color = DEFAULT_RARITY_COLOR
	earningsStroke.Thickness = 4
	earningsStroke.Transparency = 1
	earningsStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	earningsStroke.Parent = earnings

	local rarity = Instance.new("TextLabel")
	rarity.Name = "Rarity"
	rarity.BackgroundTransparency = 1
	rarity.Position = UDim2.fromScale(0.16, 0.88)
	rarity.Size = UDim2.fromScale(0.32, 0.07)
	rarity.Font = Enum.Font.GothamBold
	rarity.TextColor3 = DEFAULT_RARITY_COLOR
	rarity.TextScaled = true
	rarity.TextTransparency = 1
	rarity.Parent = card

	local odds = Instance.new("TextLabel")
	odds.Name = "Odds"
	odds.BackgroundTransparency = 1
	odds.Position = UDim2.fromScale(0.52, 0.88)
	odds.Size = UDim2.fromScale(0.32, 0.07)
	odds.Font = Enum.Font.GothamBold
	odds.TextColor3 = TEXT_SECONDARY
	odds.TextScaled = true
	odds.TextTransparency = 1
	odds.Parent = card

	local closeButton = Instance.new("ImageButton")
	closeButton.Name = "CloseButton"
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.new(0.97, 0, 0.03, 0)
	closeButton.Size = UDim2.fromOffset(30, 30)
	closeButton.BackgroundColor3 = Color3.fromRGB(50, 55, 80)
	closeButton.BackgroundTransparency = 1
	closeButton.BorderSizePixel = 0
	closeButton.AutoButtonColor = false
	closeButton.Image = IconAssets.Close
	closeButton.ImageColor3 = TEXT_PRIMARY
	closeButton.ImageTransparency = 1
	closeButton.ScaleType = Enum.ScaleType.Fit
	closeButton.ZIndex = 60
	closeButton.Parent = card
	addCorner(closeButton, 6)
	addStroke(closeButton, Color3.fromRGB(255, 255, 255), 1, 0.7)

	return setmetatable({
		_gui = gui,
		_overlay = overlay,
		_card = card,
		_title = title,
		_name = name,
		_rarity = rarity,
		_odds = odds,
		_earnings = earnings,
		_earningsStroke = earningsStroke,
		_viewportHolder = viewportHolder,
		_viewport = viewport,
		_glowStroke = glowStroke,
		_cardStroke = cardStroke,
		_shine = shine,
		_shineGradient = shineGradient,
		_sparkleLayer = sparkleLayer,
		_closeButton = closeButton,
		_queue = {},
		_isShowing = false,
	}, NewBrainrotRevealUI)
end

function NewBrainrotRevealUI:_setViewportBrainrot(brainrotId: string, rarityColor: Color3, variantId: string?)
	clearViewportContents(self._viewport)

	local brainrotsFolder = ReplicatedStorage:FindFirstChild(BRAINROTS_FOLDER_NAME)
	local template = if brainrotsFolder then brainrotsFolder:FindFirstChild(brainrotId) else nil
	if not template then
		local fallback = Instance.new("TextLabel")
		fallback.BackgroundTransparency = 1
		fallback.Size = UDim2.fromScale(1, 1)
		fallback.Font = Enum.Font.GothamBlack
		fallback.Text = "?"
		fallback.TextColor3 = rarityColor
		fallback.TextScaled = true
		fallback.Parent = self._viewport
		return
	end

	local world = Instance.new("WorldModel")
	world.Parent = self._viewport

	local clone = template:Clone()
	for _, descendant in clone:GetDescendants() do
		sanitizeViewportClone(descendant)
	end
	sanitizeViewportClone(clone)
	if variantId and variantId ~= VariantConfig.NORMAL_ID then
		BrainrotVisualFactory.applyVariant(clone, variantId)
	end

	local camera = Instance.new("Camera")
	camera.Parent = self._viewport

	local center, size = ThumbnailBounds.getVisibleBounds(clone)
	local largestAxis = math.max(size.X, size.Y, size.Z)
	local viewportSize = self._viewportHolder.AbsoluteSize
	local aspectRatio = if viewportSize.Y > 0 then viewportSize.X / viewportSize.Y else THUMBNAIL_DEFAULT_ASPECT_RATIO
	local distance = math.max(
		ThumbnailBounds.getFramingDistance(center, size, THUMBNAIL_LOOK_VECTOR, THUMBNAIL_FIELD_OF_VIEW, aspectRatio, THUMBNAIL_PADDING),
		4
	)
	camera.FieldOfView = THUMBNAIL_FIELD_OF_VIEW
	camera.CFrame = CFrame.new(center - THUMBNAIL_LOOK_VECTOR * distance, center)

	clone.Parent = world
	if clone:IsA("Model") then
		BrainrotVisualFactory.startIdle(clone)
	end

	local lightPart = Instance.new("Part")
	lightPart.Name = "RevealThumbnailLight"
	lightPart.Anchored = true
	lightPart.CanCollide = false
	lightPart.CanTouch = false
	lightPart.Transparency = 1
	lightPart.Size = Vector3.new(1, 1, 1)
	lightPart.CFrame = CFrame.new(center - THUMBNAIL_LOOK_VECTOR * (distance * 0.35), center)
	lightPart.Parent = world

	local light = Instance.new("PointLight")
	light.Color = rarityColor
	light.Brightness = 5.5
	light.Range = math.max(largestAxis * 5, 18)
	light.Parent = lightPart

	self._viewport.CurrentCamera = camera
end

function NewBrainrotRevealUI:_spawnSparkle(rarityColor: Color3, rarityRank: number)
	local sparkle = Instance.new("Frame")
	sparkle.Name = "Sparkle"
	sparkle.AnchorPoint = Vector2.new(0.5, 0.5)
	sparkle.Position = UDim2.fromScale(math.random(12, 88) / 100, math.random(14, 82) / 100)
	local size = math.random(8, 14) + rarityRank
	sparkle.Size = UDim2.fromOffset(size, size)
	sparkle.BackgroundColor3 = if math.random() > 0.35 then rarityColor else Color3.fromRGB(255, 255, 255)
	sparkle.BackgroundTransparency = 0.1
	sparkle.BorderSizePixel = 0
	sparkle.Rotation = 45
	sparkle.Parent = self._sparkleLayer
	addCorner(sparkle, 4)

	local travelX = math.random(-30, 30)
	local travelY = -math.random(35, 90)
	tween(sparkle, 0.7, Enum.EasingStyle.Quart, Enum.EasingDirection.Out, {
		Position = sparkle.Position + UDim2.fromOffset(travelX, travelY),
		Size = UDim2.fromOffset(2, 2),
		BackgroundTransparency = 1,
		Rotation = sparkle.Rotation + 180,
	})

	task.delay(0.75, function()
		sparkle:Destroy()
	end)
end

function NewBrainrotRevealUI:_burstSparkles(rarityColor: Color3, rarityRank: number)
	local count = 10 + rarityRank * 4
	for index = 1, count do
		task.delay((index - 1) * 0.018, function()
			self:_spawnSparkle(rarityColor, rarityRank)
		end)
	end
end

function NewBrainrotRevealUI:_animateEarnings(target: number, duration: number, color: Color3)
	local resolvedTarget = math.max(0, math.floor(target))
	self._earnings.TextColor3 = color
	self._earningsStroke.Color = color
	self._earnings.Text = ("+%s/s"):format(FormatUtil.money(0))

	if resolvedTarget <= 0 then
		return
	end

	local counter = Instance.new("NumberValue")
	counter.Value = 0
	local connection
	connection = counter.Changed:Connect(function(value)
		if not self._earnings.Parent then
			return
		end
		self._earnings.Text = ("+%s/s"):format(FormatUtil.money(math.floor(value)))
	end)

	local countTweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	local countTween = TweenService:Create(counter, countTweenInfo, { Value = resolvedTarget })
	countTween:Play()
	countTween.Completed:Once(function()
		if connection then
			connection:Disconnect()
			connection = nil
		end
		counter:Destroy()
		if not self._earnings.Parent then
			return
		end

		self._earnings.Text = ("+%s/s"):format(FormatUtil.money(resolvedTarget))

		local pulseUp = TweenService:Create(
			self._earningsStroke,
			TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Transparency = 0.2, Thickness = 6 }
		)
		pulseUp:Play()
		pulseUp.Completed:Once(function()
			if not self._earnings.Parent then
				return
			end
			tween(self._earningsStroke, 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, {
				Transparency = 0.6,
				Thickness = 4,
			})
		end)

		local punchUp = TweenService:Create(
			self._earnings,
			TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Size = UDim2.fromScale(0.94, 0.14) }
		)
		punchUp:Play()
		punchUp.Completed:Once(function()
			if not self._earnings.Parent then
				return
			end
			tween(self._earnings, 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, {
				Size = UDim2.fromScale(0.86, 0.12),
			})
		end)
	end)
end

function NewBrainrotRevealUI:_play(payload: RevealPayload)
	local brainrotId = payload.brainrotId
	local variantId = if VariantConfig.isKnown(payload.variantId) then payload.variantId else VariantConfig.NORMAL_ID
	local variantEntry = VariantConfig.getById(variantId)
	local hasVariant = variantId ~= VariantConfig.NORMAL_ID
	local rarityRank = math.max(1, math.floor(payload.rarityRank or 1))
	local rarityColor = payload.revealColor or payload.color or DEFAULT_RARITY_COLOR
	local overlayTransparency = if rarityRank >= 6 then 0.18 elseif rarityRank >= 4 then 0.28 else 0.42
	local strokeColor = if hasVariant then variantEntry.nameColor else rarityColor
	local earningsTarget = math.max(0, math.floor(tonumber(payload.earningsRate) or 0))

	clearChildren(self._sparkleLayer)
	self:_setViewportBrainrot(brainrotId, rarityColor, variantId)
	self._title.Text = getRevealTitle(payload.rarity, rarityRank)
	self._name.Text = if hasVariant then ("%s %s"):format(variantEntry.displayName, brainrotId) else brainrotId
	self._name.TextColor3 = if hasVariant then variantEntry.nameColor else TEXT_PRIMARY
	self._rarity.Text = string.upper(payload.rarity or "Unknown")
	self._odds.Text = payload.rngText or "1/?"
	self._rarity.TextColor3 = rarityColor
	self._cardStroke.Color = strokeColor
	self._glowStroke.Color = strokeColor
	self._earnings.TextColor3 = rarityColor
	self._earnings.Text = ("+%s/s"):format(FormatUtil.money(0))
	self._earnings.Size = UDim2.fromScale(0.86, 0.12)
	self._earningsStroke.Color = rarityColor
	self._earningsStroke.Thickness = 4
	self._card.Size = if rarityRank >= 6 then UDim2.fromScale(0.45, 0.68) else UDim2.fromScale(0.4, 0.62)

	self._gui.Enabled = true
	self._overlay.BackgroundTransparency = 1
	self._card.BackgroundTransparency = 1
	self._card.Size = UDim2.fromScale(0.28, 0.43)
	self._card.Rotation = -4
	self._title.TextTransparency = 1
	self._name.TextTransparency = 1
	self._rarity.TextTransparency = 1
	self._odds.TextTransparency = 1
	self._earnings.TextTransparency = 1
	self._earningsStroke.Transparency = 1
	self._viewportHolder.BackgroundTransparency = 1
	self._cardStroke.Transparency = 1
	self._glowStroke.Transparency = 1
	self._shineGradient.Offset = Vector2.new(-1, 0)
	self._closeButton.BackgroundTransparency = 1
	self._closeButton.ImageTransparency = 1

	playRevealSound(rarityRank)
	self:_burstSparkles(rarityColor, rarityRank)

	tween(self._overlay, 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, {
		BackgroundTransparency = overlayTransparency,
	})
	tween(self._card, 0.38, Enum.EasingStyle.Back, Enum.EasingDirection.Out, {
		BackgroundTransparency = 0,
		Rotation = 0,
		Size = if rarityRank >= 6 then UDim2.fromScale(0.45, 0.68) else UDim2.fromScale(0.4, 0.62),
	})
	tween(self._cardStroke, 0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, {
		Transparency = 0.08,
	})
	tween(self._glowStroke, 0.38, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, {
		Transparency = if rarityRank >= 4 then 0.45 else 0.7,
	})
	tween(self._viewportHolder, 0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, {
		BackgroundTransparency = 0,
	})
	tween(self._title, 0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, {
		TextTransparency = 0,
	})
	task.delay(0.12, function()
		tween(self._name, 0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, { TextTransparency = 0 })
		tween(self._rarity, 0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, { TextTransparency = 0 })
		tween(self._odds, 0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, { TextTransparency = 0 })
		tween(self._earnings, 0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, { TextTransparency = 0 })
	end)
	task.delay(0.16, function()
		tween(self._shineGradient, 0.65, Enum.EasingStyle.Quart, Enum.EasingDirection.Out, {
			Offset = Vector2.new(1, 0),
		})
	end)

	-- Kick off the hero count-up just after the card lands and the earnings
	-- label has faded in. Land the final value around t=1.85s so the stroke
	-- pulse and scale punch land near the middle of the 3s hold.
	task.delay(0.45, function()
		self:_animateEarnings(earningsTarget, 1.4, rarityColor)
	end)

	if rarityRank >= 4 then
		task.delay(0.32, function()
			self:_burstSparkles(rarityColor, rarityRank)
			tween(self._glowStroke, 0.26, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, { Transparency = 0.25 })
			task.delay(0.28, function()
				tween(self._glowStroke, 0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, { Transparency = 0.5 })
			end)
		end)
	end

	if rarityRank >= 6 then
		task.delay(0.72, function()
			self:_burstSparkles(rarityColor, rarityRank)
			tween(self._overlay, 0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, { BackgroundTransparency = 0.08 })
			task.delay(0.18, function()
				tween(self._overlay, 0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, { BackgroundTransparency = overlayTransparency })
			end)
		end)
	end

	-- Mid-hold celebration beat: re-sweep the shine and burst more sparkles so
	-- the longer 3s window stays alive instead of feeling like dead air.
	task.delay(1.6, function()
		self._shineGradient.Offset = Vector2.new(-1, 0)
		tween(self._shineGradient, 0.7, Enum.EasingStyle.Quart, Enum.EasingDirection.Out, {
			Offset = Vector2.new(1, 0),
		})
		self:_burstSparkles(rarityColor, rarityRank)
	end)

	-- Late escalation for rare+ rolls only — keeps commons from feeling spammy.
	if rarityRank >= 4 then
		task.delay(2.5, function()
			self:_burstSparkles(rarityColor, rarityRank)
		end)
	end

	-- Show the close button once the card has fully animated in, then wait for
	-- the player to dismiss it themselves.
	task.delay(0.5, function()
		tween(self._closeButton, 0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, {
			BackgroundTransparency = 0.35,
			ImageTransparency = 0,
		})
	end)

	local closeSignal = Instance.new("BindableEvent")
	local closeConn = self._closeButton.Activated:Connect(function()
		closeSignal:Fire()
	end)
	closeSignal.Event:Wait()
	closeConn:Disconnect()
	closeSignal:Destroy()

	tween(self._closeButton, 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In, {
		BackgroundTransparency = 1,
		ImageTransparency = 1,
	})

	tween(self._card, 0.28, Enum.EasingStyle.Back, Enum.EasingDirection.In, {
		BackgroundTransparency = 1,
		Rotation = 4,
		Size = UDim2.fromScale(0.28, 0.43),
	})
	tween(self._overlay, 0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.In, {
		BackgroundTransparency = 1,
	})
	tween(self._title, 0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In, { TextTransparency = 1 })
	tween(self._name, 0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In, { TextTransparency = 1 })
	tween(self._rarity, 0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In, { TextTransparency = 1 })
	tween(self._odds, 0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In, { TextTransparency = 1 })
	tween(self._earnings, 0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In, { TextTransparency = 1 })
	tween(self._earningsStroke, 0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In, { Transparency = 1 })

	task.wait(0.3)
	self._gui.Enabled = false
	clearChildren(self._sparkleLayer)
	clearViewportContents(self._viewport)
end

function NewBrainrotRevealUI:_processQueue()
	if self._isShowing then
		return
	end

	self._isShowing = true
	while #self._queue > 0 do
		local payload = table.remove(self._queue, 1)
		if type(payload.brainrotId) == "string" and payload.brainrotId ~= "" then
			self:_play(payload)
		end
	end
	self._isShowing = false
end

function NewBrainrotRevealUI:show(payload: RevealPayload)
	if type(payload) ~= "table" or type(payload.brainrotId) ~= "string" then
		return
	end

	table.insert(self._queue, payload)
	task.spawn(function()
		self:_processQueue()
	end)
end

return NewBrainrotRevealUI
