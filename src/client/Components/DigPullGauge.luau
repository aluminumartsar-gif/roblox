local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UtilFolder = Shared:WaitForChild("Util")
local BrainrotVisualFactory = require(UtilFolder:WaitForChild("BrainrotVisualFactory"))

local CameraEffects = require(script.Parent:WaitForChild("CameraEffects"))

-- DigPullGauge — worldspace gauge that displays a brainrot silhouette rising
-- out of the dirt at a dig spot. Each call to `showCandidate` represents a
-- fresh server-rolled candidate the player can either PULL UP (claim) or
-- KEEP DIGGING (reroll, with snap risk past the safe zone).
--
-- Step 1 of the dig minigame rework: pure visual component with a stable
-- public API. Callers wire up the actual dig session in later steps.

local DigPullGauge = {}
DigPullGauge.__index = DigPullGauge

-- ── Worldspace silhouette ─────────────────────────────────────────────────
-- The silhouette stays in worldspace so it can break out of the dig spot
-- with a real rise animation. All info / controls moved to a ScreenGui in
-- the next block below (see PANEL_*) — keeping the panel in a BillboardGui
-- caused three problems that the user surfaced: it scaled with camera
-- distance (huge close, tiny far), it overlapped neighbouring spot tier
-- billboards in the world, and TextButton clicks weren't reliably reported
-- as `processed` to UserInputService.InputBegan.
local SILHOUETTE_TARGET_HEIGHT = 3.0        -- normalized silhouette height in studs
local SILHOUETTE_RISE_OFFSET = 4            -- studs below ground at the start of the rise
local SILHOUETTE_REST_HEIGHT = 0.8          -- studs above the spot when fully risen
local BOB_AMPLITUDE = 0.15
local BOB_PERIOD = 1.2

-- ── Screen panel ──────────────────────────────────────────────────────────
-- The panel is authored as 280×280 pixels (see PANEL_BASE_SIZE) and then
-- rescaled via a UIScale on the container so it never dominates small or
-- portrait viewports. PANEL_POSITION_OFF uses a *scale* x offset (1.5 of
-- screen width) so the slide-out works regardless of how wide the panel is
-- once UIScale is applied — using a fixed pixel offset like the original
-- `(1, 300, 0.5, 0)` would leave the panel partially on-screen on small
-- devices where the scaled panel can be wider than 300 px relative to the
-- screen.
local PANEL_BASE_SIZE = UDim2.fromOffset(280, 280)
local PANEL_ANCHOR = Vector2.new(1, 0.5)
-- Flush to the inner edge of the viewport holder's padding so margins scale
-- with resolution (replacing the old fixed −24 px offset).
local PANEL_POSITION_ON = UDim2.new(1, 0, 0.5, 0)
local PANEL_POSITION_OFF = UDim2.new(1.5, 0, 0.5, 0)
-- Scale + px mix: gutters breathe on large screens while tiny offsets keep
-- phones readable next to curved display corners.
local PANEL_HOLDER_MARGIN_X = UDim.new(0.014, 6)
local PANEL_HOLDER_MARGIN_Y = UDim.new(0.024, 0)
local PANEL_SLIDE_IN_DURATION = 0.28
local PANEL_SLIDE_OUT_DURATION = 0.20

-- Viewport-driven scaling. The panel was designed for a 1080p reference, so
-- we scale by min(viewport.X, viewport.Y) / PANEL_SCALE_REF and clamp so
-- the panel stays usable on phones without ballooning on 4K monitors. Using
-- the smaller viewport axis means a portrait phone shrinks the panel as
-- expected (instead of using the longer screen edge and over-sizing it).
local PANEL_SCALE_REF = 1080
local PANEL_SCALE_MIN = 0.48
local PANEL_SCALE_MAX = 1.30

-- Aspect limits for very wide or very tall viewports — keeps the drawer from
-- covering almost the whole HUD on skinny portrait windows / foldables.
local PANEL_WIDE_MAX_HEIGHT_FRAC = 0.92
local PANEL_TALL_MAX_WIDTH_FRAC = 0.5

local function computePanelScale(): number
	local camera = Workspace.CurrentCamera
	if not camera then
		return 1
	end
	local viewport = camera.ViewportSize
	if viewport.X <= 0 or viewport.Y <= 0 then
		return 1
	end
	local minAxis = math.min(viewport.X, viewport.Y)
	local scale =
		math.clamp(minAxis / PANEL_SCALE_REF, PANEL_SCALE_MIN, PANEL_SCALE_MAX)
	local maxByAspect = math.min(
		(viewport.X * PANEL_TALL_MAX_WIDTH_FRAC) / PANEL_BASE_SIZE.X.Offset,
		(viewport.Y * PANEL_WIDE_MAX_HEIGHT_FRAC) / PANEL_BASE_SIZE.Y.Offset
	)
	return math.min(scale, maxByAspect)
end

-- ── Animation timing ───────────────────────────────────────────────────────
local RISE_DURATION = 0.55
local RISE_FADE_DURATION = 0.35
local DROP_DURATION = 0.30
local DROP_FADE_DURATION = 0.25
local SNAP_KICK_DURATION = 0.12
local SNAP_DROP_DURATION = 0.40
local SNAP_FLASH_FADE_DURATION = 0.50
local SNAP_SHAKE_DURATION = 0.32
local SNAP_SHAKE_INTENSITY = 0.26

-- ── Color tokens (panel + chrome) ──────────────────────────────────────────
-- Palette pulled from the rest of the in-game UI for visual coherence:
-- HotbarController uses navy (22, 24, 38) panels with bright gold (255, 220,
-- 60) selection strokes and confirm/cancel buttons in saturated green
-- (80, 200, 120) and red (220, 70, 70). The dig gauge mirrors that:
-- navy panel + gold rim, green CLAIM button (KEEP BRAINROT), amber REROLL
-- button (KEEP DIGGING). Saturated, chunky, "brainrot game" aesthetic.
local PANEL_BG = Color3.fromRGB(28, 30, 50)
local PANEL_BG_BOTTOM = Color3.fromRGB(14, 16, 30)
local PANEL_STROKE = Color3.fromRGB(255, 220, 60)
local PANEL_SHADOW_COLOR = Color3.fromRGB(0, 0, 0)

-- Rarity ribbon header — the rarity tier color fills a banner at the top of
-- the panel, with a darker tinted stroke. Both colors are derived at
-- runtime from rarityColor in _setRarityHeader; these tokens are just the
-- defaults until a candidate arrives.
local RIBBON_DEFAULT_COLOR = Color3.fromRGB(110, 130, 170)

-- KEEP BRAINROT (was PULL UP) — the "claim it" button. Reuses the bright
-- green from the Hotbar pickup confirm so players read it as the
-- affirmative action immediately.
local CLAIM_BG = Color3.fromRGB(95, 215, 130)
local CLAIM_BOTTOM = Color3.fromRGB(40, 160, 85)
local CLAIM_STROKE = Color3.fromRGB(220, 255, 220)
local CLAIM_TEXT = Color3.fromRGB(255, 255, 255)

local LUCK_GOLD_TOP = Color3.fromRGB(255, 230, 90)
local LUCK_GOLD_BOTTOM = Color3.fromRGB(255, 175, 30)
local LUCK_STROKE = Color3.fromRGB(90, 60, 0)

-- KEEP DIGGING — the reroll. Amber gradient signals "tempting but not
-- the safe pick"; turns red-stroked when phase = risky (see
-- _applyPhaseStyle). Dark text on the bright fill keeps it legible.
local REROLL_BG = Color3.fromRGB(255, 200, 70)
local REROLL_BOTTOM = Color3.fromRGB(220, 140, 30)
local REROLL_STROKE = Color3.fromRGB(255, 240, 180)
local REROLL_TEXT = Color3.fromRGB(60, 36, 0)

local SUBTEXT_SAFE_COLOR = Color3.fromRGB(80, 50, 0)
local SUBTEXT_RISKY_COLOR = Color3.fromRGB(255, 88, 88)
-- Subtext stroke: safe line uses soft white halo on amber; risky line needs a
-- dark rim on warm gradient so coral fill stays legible (white+faint washes out).
local SUBTEXT_SAFE_STROKE_COLOR = Color3.fromRGB(255, 255, 255)
local SUBTEXT_SAFE_STROKE_TRANSPARENCY = 0.6
local SUBTEXT_RISKY_STROKE_COLOR = Color3.fromRGB(28, 14, 0)
local SUBTEXT_RISKY_STROKE_TRANSPARENCY = 0.08

local DOT_INACTIVE = Color3.fromRGB(60, 64, 96)
local DOT_ACTIVE = Color3.fromRGB(95, 215, 130)

local RHYTHM_TRACK_BG = Color3.fromRGB(38, 42, 70)
local RHYTHM_FILL = Color3.fromRGB(120, 220, 255)
local RHYTHM_CHAIN_TEXT = Color3.fromRGB(255, 240, 140)

local SNAP_FLASH_COLOR = Color3.fromRGB(210, 25, 25)

-- Countdown mode (PHASE_DIGGING): the panel swaps its rarity / odds / luck /
-- buttons row for a single "DIGGING..." header, a big countdown timer, a
-- horizontal progress fill, and a CANCEL button. Tokens here keep the visual
-- language consistent with the rest of the gauge (dark navy panel, gold
-- progress, red cancel mirroring the snap-flash hue).
local COUNTDOWN_HEADER_TEXT_COLOR = Color3.fromRGB(255, 240, 200)
local COUNTDOWN_HEADER_STROKE = Color3.fromRGB(60, 36, 0)
local COUNTDOWN_TIMER_TEXT_COLOR = Color3.fromRGB(255, 240, 110)
local COUNTDOWN_TRACK_BG = Color3.fromRGB(38, 42, 70)
local COUNTDOWN_FILL_TOP = Color3.fromRGB(255, 220, 70)
local COUNTDOWN_FILL_BOTTOM = Color3.fromRGB(220, 140, 30)
local COUNTDOWN_CANCEL_BG = Color3.fromRGB(220, 70, 70)
local COUNTDOWN_CANCEL_BOTTOM = Color3.fromRGB(150, 30, 30)
local COUNTDOWN_CANCEL_STROKE = Color3.fromRGB(255, 200, 200)
local COUNTDOWN_CANCEL_TEXT = Color3.fromRGB(255, 255, 255)

local COUNTDOWN_BILLBOARD_SIZE = UDim2.fromOffset(140, 60)
local COUNTDOWN_BILLBOARD_OFFSET = Vector3.new(0, 4.5, 0)

-- ── Silhouette ─────────────────────────────────────────────────────────────
local SILHOUETTE_BLACK = Color3.fromRGB(0, 0, 0)
local FALLBACK_RARITY_COLOR = Color3.fromRGB(180, 180, 180)
local FALLBACK_SILHOUETTE_SIZE = Vector3.new(2.4, SILHOUETTE_TARGET_HEIGHT, 1.6)

-- ── Dirt particle burst ────────────────────────────────────────────────────
local DIRT_COLOR_LIGHT = Color3.fromRGB(116, 83, 54)
local DIRT_COLOR_DARK = Color3.fromRGB(72, 54, 42)

-- ───────────────────────────────────────────────────────────────────────────
-- Static helpers
-- ───────────────────────────────────────────────────────────────────────────

local function addCorner(parent: Instance, radius: UDim)
	local c = Instance.new("UICorner")
	c.CornerRadius = radius
	c.Parent = parent
end

local function addStroke(parent: Instance, color: Color3, thickness: number, transparency: number?)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Parent = parent
	return s
end

local function addGradient(parent: Instance, top: Color3, bottom: Color3): UIGradient
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, top),
		ColorSequenceKeypoint.new(1, bottom),
	})
	g.Rotation = 90
	g.Parent = parent
	return g
end

-- "1 in 1,250" — comma-grouped odds string. Handles huge denominators (Mythic
-- and Brainrot God tiers can run into the millions) without scientific notation.
local function formatOdds(denominator: number): string
	local n = math.max(1, math.floor(denominator + 0.5))
	local text = tostring(n)
	while true do
		local updated, replacements = text:gsub("^(%d+)(%d%d%d)", "%1,%2")
		text = updated
		if replacements == 0 then
			break
		end
	end
	return ("1 in %s"):format(text)
end

local function formatLuckMultiplier(value: number): string
	if value >= 10 then
		return ("x%d"):format(math.floor(value + 0.5))
	end
	return ("x%.2f"):format(value)
end

local function makeAnchorPart(name: string, position: Vector3): BasePart
	local anchor = Instance.new("Part")
	anchor.Name = name
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Position = position
	return anchor
end

local function disconnectAll(connections: { RBXScriptConnection })
	for _, conn in connections do
		conn:Disconnect()
	end
	table.clear(connections)
end

-- Walks all descendants and turns the visual into a pure-black silhouette.
-- Decals/textures/lights are stripped so nothing competes with the Highlight
-- outline that the caller adornes afterwards. Returns the BaseParts that
-- need to participate in transparency tweens.
local function applySilhouetteStyling(visual: Instance): { BasePart }
	local parts: { BasePart } = {}

	local function styleBasePart(part: BasePart)
		part.Color = SILHOUETTE_BLACK
		part.Material = Enum.Material.SmoothPlastic
		part.Reflectance = 0
		part.CastShadow = false
		part.Transparency = 0
		table.insert(parts, part)
	end

	if visual:IsA("BasePart") then
		styleBasePart(visual)
	end

	for _, descendant in visual:GetDescendants() do
		if descendant:IsA("BasePart") then
			styleBasePart(descendant)
		elseif descendant:IsA("Decal")
			or descendant:IsA("Texture")
			or descendant:IsA("SurfaceAppearance")
		then
			descendant:Destroy()
		elseif descendant:IsA("ParticleEmitter")
			or descendant:IsA("Beam")
			or descendant:IsA("Trail")
		then
			descendant.Enabled = false
		elseif descendant:IsA("PointLight")
			or descendant:IsA("SpotLight")
			or descendant:IsA("SurfaceLight")
		then
			descendant:Destroy()
		end
	end

	return parts
end

local function attachRarityHighlight(visual: Instance, rarityColor: Color3): Highlight
	local highlight = Instance.new("Highlight")
	highlight.Name = "RarityOutline"
	highlight.Adornee = visual
	highlight.FillColor = SILHOUETTE_BLACK
	highlight.FillTransparency = 0
	highlight.OutlineColor = rarityColor
	highlight.OutlineTransparency = 0
	-- Occluded means the silhouette is hidden by the dirt floor while it's
	-- still underground during the rise animation, so the emergence feels
	-- like it's actually breaking through the ground.
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = visual
	return highlight
end

local function spawnDirtBurst(position: Vector3)
	local emitterPart = Instance.new("Part")
	emitterPart.Name = "DigPullGaugeDirtBurst"
	emitterPart.Size = Vector3.new(0.2, 0.2, 0.2)
	emitterPart.Anchored = true
	emitterPart.CanCollide = false
	emitterPart.CanQuery = false
	emitterPart.CanTouch = false
	emitterPart.CastShadow = false
	emitterPart.Transparency = 1
	emitterPart.CFrame = CFrame.new(position)
	emitterPart.Parent = Workspace

	local attachment = Instance.new("Attachment")
	attachment.Parent = emitterPart

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "DirtParticles"
	emitter.LightEmission = 0
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, DIRT_COLOR_LIGHT),
		ColorSequenceKeypoint.new(1, DIRT_COLOR_DARK),
	})
	emitter.Lifetime = NumberRange.new(0.3, 0.55)
	emitter.Rate = 0
	emitter.Speed = NumberRange.new(6, 11)
	emitter.SpreadAngle = Vector2.new(35, 35)
	emitter.Acceleration = Vector3.new(0, -22, 0)
	emitter.Drag = 1.2
	emitter.RotSpeed = NumberRange.new(-180, 180)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.45),
		NumberSequenceKeypoint.new(1, 0.05),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Parent = attachment

	emitter:Emit(18)

	Debris:AddItem(emitterPart, 0.9)
end

local function createFallbackSilhouette(parent: Instance, cframe: CFrame): (BasePart, BasePart)
	local part = Instance.new("Part")
	part.Name = "DigPullGaugeSilhouetteFallback"
	part.Shape = Enum.PartType.Block
	part.Size = FALLBACK_SILHOUETTE_SIZE
	part.Color = SILHOUETTE_BLACK
	part.Material = Enum.Material.SmoothPlastic
	part.Reflectance = 0
	part.CastShadow = false
	part.Transparency = 0
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CFrame = cframe
	part.Parent = parent
	return part, part
end

-- ───────────────────────────────────────────────────────────────────────────
-- Panel construction
-- ───────────────────────────────────────────────────────────────────────────

local function buildPanel(parent: GuiObject)
	-- Drop shadow: a slightly darker, slightly offset frame behind the
	-- main panel adds depth without us needing an actual ShadowImage. It
	-- sits at the same scale, just nudged down/right and parented under
	-- the panel so it always renders behind.
	local shadow = Instance.new("Frame")
	shadow.Name = "Shadow"
	shadow.AnchorPoint = Vector2.new(0.5, 0.5)
	shadow.Position = UDim2.new(0.5, 4, 0.5, 6)
	shadow.Size = UDim2.fromScale(1, 1)
	shadow.BackgroundColor3 = PANEL_SHADOW_COLOR
	shadow.BackgroundTransparency = 0.55
	shadow.BorderSizePixel = 0
	shadow.ZIndex = 0
	shadow.Parent = parent
	addCorner(shadow, UDim.new(0, 16))

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromScale(1, 1)
	panel.BackgroundColor3 = PANEL_BG
	panel.BorderSizePixel = 0
	-- Active = true makes the panel absorb stray screen clicks that land
	-- on the gauge background but miss the buttons. Without it those would
	-- pass through to the world and fire another dig swing on desktop.
	panel.Active = true
	panel.ZIndex = 1
	panel.Parent = parent
	addCorner(panel, UDim.new(0, 16))
	addGradient(panel, PANEL_BG, PANEL_BG_BOTTOM)
	addStroke(panel, PANEL_STROKE, 3, 0.05)

	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Vertical
	listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	listLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 8)
	listLayout.Parent = panel

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 10)
	padding.PaddingBottom = UDim.new(0, 14)
	padding.PaddingLeft = UDim.new(0, 14)
	padding.PaddingRight = UDim.new(0, 14)
	padding.Parent = panel

	-- Rarity ribbon — a colored banner across the top that shows the
	-- rarity tier (COMMON / RARE / EPIC / etc.) in its tier color. This
	-- replaces the previous flat rarity label and gives the panel a
	-- proper "card header" feel.
	local rarityRibbon = Instance.new("Frame")
	rarityRibbon.Name = "RarityRibbon"
	rarityRibbon.LayoutOrder = 1
	rarityRibbon.Size = UDim2.new(1, 0, 0, 38)
	rarityRibbon.BackgroundColor3 = RIBBON_DEFAULT_COLOR
	rarityRibbon.BorderSizePixel = 0
	rarityRibbon.Parent = panel
	addCorner(rarityRibbon, UDim.new(0, 10))
	local ribbonGradient = addGradient(rarityRibbon, RIBBON_DEFAULT_COLOR, RIBBON_DEFAULT_COLOR)
	local ribbonStroke = addStroke(rarityRibbon, Color3.fromRGB(0, 0, 0), 2, 0.4)

	local rarityLabel = Instance.new("TextLabel")
	rarityLabel.Name = "RarityLabel"
	rarityLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	rarityLabel.Position = UDim2.fromScale(0.5, 0.5)
	rarityLabel.Size = UDim2.new(1, -16, 0.78, 0)
	rarityLabel.BackgroundTransparency = 1
	rarityLabel.Font = Enum.Font.GothamBlack
	rarityLabel.Text = "—"
	rarityLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	rarityLabel.TextScaled = true
	rarityLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	rarityLabel.TextStrokeTransparency = 0
	rarityLabel.Parent = rarityRibbon

	local oddsLabel = Instance.new("TextLabel")
	oddsLabel.Name = "OddsLabel"
	oddsLabel.LayoutOrder = 2
	oddsLabel.Size = UDim2.new(1, 0, 0, 22)
	oddsLabel.BackgroundTransparency = 1
	oddsLabel.Font = Enum.Font.GothamBold
	oddsLabel.Text = "1 in 1"
	oddsLabel.TextColor3 = Color3.fromRGB(220, 220, 240)
	oddsLabel.TextScaled = true
	oddsLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	oddsLabel.TextStrokeTransparency = 0.4
	oddsLabel.Parent = panel

	local luckLabel = Instance.new("TextLabel")
	luckLabel.Name = "LuckLabel"
	luckLabel.LayoutOrder = 3
	luckLabel.Size = UDim2.new(1, 0, 0, 28)
	luckLabel.BackgroundTransparency = 1
	luckLabel.Font = Enum.Font.GothamBlack
	luckLabel.Text = "x1.00 LUCK"
	luckLabel.TextColor3 = LUCK_GOLD_TOP
	luckLabel.TextScaled = true
	luckLabel.TextStrokeColor3 = LUCK_STROKE
	luckLabel.TextStrokeTransparency = 0
	luckLabel.Parent = panel

	local luckGrad = Instance.new("UIGradient")
	luckGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, LUCK_GOLD_TOP),
		ColorSequenceKeypoint.new(1, LUCK_GOLD_BOTTOM),
	})
	luckGrad.Rotation = 90
	luckGrad.Parent = luckLabel

	-- Hit-progress dots: kept in the tree (so _rebuildDots etc. still
	-- resolves) but hidden by default. With every shovel set to
	-- requiredHits = 1, the row would just show a single dot which only
	-- adds visual clutter; if hit progression ever returns, _rebuildDots
	-- can flip dotsRow.Visible back on.
	local dotsRow = Instance.new("Frame")
	dotsRow.Name = "DotsRow"
	dotsRow.LayoutOrder = 4
	dotsRow.Size = UDim2.new(1, 0, 0, 16)
	dotsRow.BackgroundTransparency = 1
	dotsRow.Visible = false
	dotsRow.Parent = panel

	local dotsLayout = Instance.new("UIListLayout")
	dotsLayout.FillDirection = Enum.FillDirection.Horizontal
	dotsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	dotsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	dotsLayout.Padding = UDim.new(0, 8)
	dotsLayout.Parent = dotsRow

	-- Rhythm window placeholder. Hidden until the chain/rhythm mechanic
	-- actually ships; keeping the node in the tree means the references
	-- below (rhythmFill, chainLabel) stay valid for forward compatibility
	-- without leaving an empty 14-px gap in the panel.
	local rhythmRow = Instance.new("Frame")
	rhythmRow.Name = "RhythmRow"
	rhythmRow.LayoutOrder = 5
	rhythmRow.Size = UDim2.new(1, 0, 0, 14)
	rhythmRow.BackgroundTransparency = 1
	rhythmRow.Visible = false
	rhythmRow.Parent = panel

	local rhythmTrack = Instance.new("Frame")
	rhythmTrack.Name = "Track"
	rhythmTrack.AnchorPoint = Vector2.new(0.5, 0.5)
	rhythmTrack.Position = UDim2.fromScale(0.5, 0.5)
	rhythmTrack.Size = UDim2.new(0.7, 0, 0, 6)
	rhythmTrack.BackgroundColor3 = RHYTHM_TRACK_BG
	rhythmTrack.BorderSizePixel = 0
	rhythmTrack.Parent = rhythmRow
	addCorner(rhythmTrack, UDim.new(0.5, 0))

	local rhythmFill = Instance.new("Frame")
	rhythmFill.Name = "Fill"
	rhythmFill.AnchorPoint = Vector2.new(0.5, 0.5)
	rhythmFill.Position = UDim2.fromScale(0.5, 0.5)
	rhythmFill.Size = UDim2.fromScale(0, 1)
	rhythmFill.BackgroundColor3 = RHYTHM_FILL
	rhythmFill.BorderSizePixel = 0
	rhythmFill.Parent = rhythmTrack
	addCorner(rhythmFill, UDim.new(0.5, 0))

	local chainLabel = Instance.new("TextLabel")
	chainLabel.Name = "ChainLabel"
	chainLabel.AnchorPoint = Vector2.new(1, 0.5)
	chainLabel.Position = UDim2.new(1, -4, 0.5, 0)
	chainLabel.Size = UDim2.new(0.32, 0, 1, 0)
	chainLabel.BackgroundTransparency = 1
	chainLabel.Font = Enum.Font.GothamBold
	chainLabel.Text = ""
	chainLabel.TextColor3 = RHYTHM_CHAIN_TEXT
	chainLabel.TextScaled = true
	chainLabel.TextXAlignment = Enum.TextXAlignment.Right
	chainLabel.TextStrokeColor3 = Color3.fromRGB(60, 40, 0)
	chainLabel.TextStrokeTransparency = 0.4
	chainLabel.Visible = false
	chainLabel.Parent = rhythmRow

	local pullUpButton = Instance.new("TextButton")
	pullUpButton.Name = "KeepBrainrotButton"
	pullUpButton.LayoutOrder = 6
	pullUpButton.Size = UDim2.new(1, 0, 0, 60)
	pullUpButton.BackgroundColor3 = CLAIM_BG
	pullUpButton.AutoButtonColor = true
	pullUpButton.BorderSizePixel = 0
	pullUpButton.Text = ""
	pullUpButton.Parent = panel
	addCorner(pullUpButton, UDim.new(0, 12))
	addGradient(pullUpButton, CLAIM_BG, CLAIM_BOTTOM)
	addStroke(pullUpButton, CLAIM_STROKE, 3, 0.05)

	-- Text in a child label keeps the button's UIGradient from tinting it.
	local pullUpLabel = Instance.new("TextLabel")
	pullUpLabel.Name = "Label"
	pullUpLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	pullUpLabel.Position = UDim2.fromScale(0.5, 0.5)
	pullUpLabel.Size = UDim2.new(1, -18, 0.78, 0)
	pullUpLabel.BackgroundTransparency = 1
	pullUpLabel.Font = Enum.Font.GothamBlack
	pullUpLabel.Text = "KEEP BRAINROT"
	pullUpLabel.TextColor3 = CLAIM_TEXT
	pullUpLabel.TextScaled = true
	pullUpLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	pullUpLabel.TextStrokeTransparency = 0
	pullUpLabel.Parent = pullUpButton

	local keepButton = Instance.new("TextButton")
	keepButton.Name = "KeepDiggingButton"
	keepButton.LayoutOrder = 7
	keepButton.Size = UDim2.new(1, 0, 0, 54)
	keepButton.BackgroundColor3 = REROLL_BG
	keepButton.AutoButtonColor = true
	keepButton.BorderSizePixel = 0
	keepButton.Text = ""
	keepButton.Parent = panel
	addCorner(keepButton, UDim.new(0, 12))
	addGradient(keepButton, REROLL_BG, REROLL_BOTTOM)
	addStroke(keepButton, REROLL_STROKE, 3, 0.05)

	local keepTitle = Instance.new("TextLabel")
	keepTitle.Name = "Title"
	keepTitle.AnchorPoint = Vector2.new(0.5, 0)
	keepTitle.Position = UDim2.new(0.5, 0, 0.06, 0)
	keepTitle.Size = UDim2.new(1, -14, 0.52, 0)
	keepTitle.BackgroundTransparency = 1
	keepTitle.Font = Enum.Font.GothamBlack
	keepTitle.Text = "KEEP DIGGING"
	keepTitle.TextColor3 = REROLL_TEXT
	keepTitle.TextScaled = true
	keepTitle.TextStrokeColor3 = Color3.fromRGB(255, 255, 255)
	keepTitle.TextStrokeTransparency = 0.6
	keepTitle.Parent = keepButton

	local keepSubtext = Instance.new("TextLabel")
	keepSubtext.Name = "Subtext"
	keepSubtext.AnchorPoint = Vector2.new(0.5, 1)
	keepSubtext.Position = UDim2.new(0.5, 0, 0.94, 0)
	keepSubtext.Size = UDim2.new(1, -14, 0.36, 0)
	keepSubtext.BackgroundTransparency = 1
	keepSubtext.Font = Enum.Font.GothamBold
	keepSubtext.Text = "Reroll for more luck"
	keepSubtext.TextColor3 = SUBTEXT_SAFE_COLOR
	keepSubtext.TextScaled = true
	keepSubtext.TextStrokeColor3 = SUBTEXT_SAFE_STROKE_COLOR
	keepSubtext.TextStrokeTransparency = SUBTEXT_SAFE_STROKE_TRANSPARENCY
	keepSubtext.Parent = keepButton

	-- Countdown overlay: a full-panel Frame that's hidden by default and
	-- shown during PHASE_DIGGING. Parented to the OUTER container (sibling
	-- of `panel`, not a child of it) so the panel's UIListLayout doesn't
	-- treat it as another row that pushes the rarity/odds/buttons down
	-- underneath. With this layout the overlay covers the entire panel
	-- area while the reveal content keeps rendering underneath — when the
	-- countdown ends, hideCountdown() flips this invisible and the reveal
	-- snaps right back into place for showCandidate().
	local countdownGroup = Instance.new("Frame")
	countdownGroup.Name = "CountdownGroup"
	countdownGroup.AnchorPoint = Vector2.new(0.5, 0.5)
	countdownGroup.Position = UDim2.fromScale(0.5, 0.5)
	countdownGroup.Size = UDim2.new(1, 0, 1, 0)
	countdownGroup.BackgroundColor3 = PANEL_BG
	countdownGroup.BorderSizePixel = 0
	countdownGroup.Active = true
	countdownGroup.Visible = false
	countdownGroup.ZIndex = 6
	countdownGroup.Parent = parent
	addCorner(countdownGroup, UDim.new(0, 16))
	addStroke(countdownGroup, PANEL_STROKE, 3, 0.05)
	addGradient(countdownGroup, PANEL_BG, PANEL_BG_BOTTOM)

	local countdownPadding = Instance.new("UIPadding")
	countdownPadding.PaddingTop = UDim.new(0, 18)
	countdownPadding.PaddingBottom = UDim.new(0, 18)
	countdownPadding.PaddingLeft = UDim.new(0, 18)
	countdownPadding.PaddingRight = UDim.new(0, 18)
	countdownPadding.Parent = countdownGroup

	local countdownLayout = Instance.new("UIListLayout")
	countdownLayout.FillDirection = Enum.FillDirection.Vertical
	countdownLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	countdownLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	countdownLayout.SortOrder = Enum.SortOrder.LayoutOrder
	countdownLayout.Padding = UDim.new(0, 14)
	countdownLayout.Parent = countdownGroup

	local countdownHeader = Instance.new("TextLabel")
	countdownHeader.Name = "CountdownHeader"
	countdownHeader.LayoutOrder = 1
	countdownHeader.Size = UDim2.new(1, 0, 0, 36)
	countdownHeader.BackgroundTransparency = 1
	countdownHeader.Font = Enum.Font.GothamBlack
	countdownHeader.Text = "DIGGING..."
	countdownHeader.TextColor3 = COUNTDOWN_HEADER_TEXT_COLOR
	countdownHeader.TextScaled = true
	countdownHeader.TextStrokeColor3 = COUNTDOWN_HEADER_STROKE
	countdownHeader.TextStrokeTransparency = 0
	countdownHeader.Parent = countdownGroup

	local countdownTimer = Instance.new("TextLabel")
	countdownTimer.Name = "CountdownTimer"
	countdownTimer.LayoutOrder = 2
	countdownTimer.Size = UDim2.new(1, 0, 0, 78)
	countdownTimer.BackgroundTransparency = 1
	countdownTimer.Font = Enum.Font.GothamBlack
	countdownTimer.Text = "5.0s"
	countdownTimer.TextColor3 = COUNTDOWN_TIMER_TEXT_COLOR
	countdownTimer.TextScaled = true
	countdownTimer.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	countdownTimer.TextStrokeTransparency = 0
	countdownTimer.Parent = countdownGroup

	local countdownTrack = Instance.new("Frame")
	countdownTrack.Name = "CountdownTrack"
	countdownTrack.LayoutOrder = 3
	countdownTrack.Size = UDim2.new(1, 0, 0, 14)
	countdownTrack.BackgroundColor3 = COUNTDOWN_TRACK_BG
	countdownTrack.BorderSizePixel = 0
	countdownTrack.Parent = countdownGroup
	addCorner(countdownTrack, UDim.new(0.5, 0))

	local countdownFill = Instance.new("Frame")
	countdownFill.Name = "CountdownFill"
	countdownFill.AnchorPoint = Vector2.new(0, 0.5)
	countdownFill.Position = UDim2.fromScale(0, 0.5)
	countdownFill.Size = UDim2.fromScale(0, 1)
	countdownFill.BackgroundColor3 = COUNTDOWN_FILL_TOP
	countdownFill.BorderSizePixel = 0
	countdownFill.Parent = countdownTrack
	addCorner(countdownFill, UDim.new(0.5, 0))
	addGradient(countdownFill, COUNTDOWN_FILL_TOP, COUNTDOWN_FILL_BOTTOM)

	local cancelButton = Instance.new("TextButton")
	cancelButton.Name = "CancelButton"
	cancelButton.LayoutOrder = 4
	cancelButton.Size = UDim2.new(1, 0, 0, 56)
	cancelButton.BackgroundColor3 = COUNTDOWN_CANCEL_BG
	cancelButton.AutoButtonColor = true
	cancelButton.BorderSizePixel = 0
	cancelButton.Text = ""
	cancelButton.Parent = countdownGroup
	addCorner(cancelButton, UDim.new(0, 12))
	addGradient(cancelButton, COUNTDOWN_CANCEL_BG, COUNTDOWN_CANCEL_BOTTOM)
	addStroke(cancelButton, COUNTDOWN_CANCEL_STROKE, 3, 0.05)

	local cancelLabel = Instance.new("TextLabel")
	cancelLabel.Name = "Label"
	cancelLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	cancelLabel.Position = UDim2.fromScale(0.5, 0.5)
	cancelLabel.Size = UDim2.new(1, -18, 0.78, 0)
	cancelLabel.BackgroundTransparency = 1
	cancelLabel.Font = Enum.Font.GothamBlack
	cancelLabel.Text = "CANCEL"
	cancelLabel.TextColor3 = COUNTDOWN_CANCEL_TEXT
	cancelLabel.TextScaled = true
	cancelLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	cancelLabel.TextStrokeTransparency = 0
	cancelLabel.Parent = cancelButton

	return {
		panel = panel,
		shadow = shadow,
		rarityRibbon = rarityRibbon,
		ribbonGradient = ribbonGradient,
		ribbonStroke = ribbonStroke,
		rarityLabel = rarityLabel,
		oddsLabel = oddsLabel,
		luckLabel = luckLabel,
		dotsRow = dotsRow,
		rhythmFill = rhythmFill,
		chainLabel = chainLabel,
		pullUpButton = pullUpButton,
		pullUpLabel = pullUpLabel,
		keepButton = keepButton,
		keepTitle = keepTitle,
		keepSubtext = keepSubtext,
		countdownGroup = countdownGroup,
		countdownHeader = countdownHeader,
		countdownTimer = countdownTimer,
		countdownTrack = countdownTrack,
		countdownFill = countdownFill,
		cancelButton = cancelButton,
		cancelLabel = cancelLabel,
	}
end

-- ───────────────────────────────────────────────────────────────────────────
-- Class: lifecycle
-- ───────────────────────────────────────────────────────────────────────────

function DigPullGauge.new()
	local self = setmetatable({
		_world = nil :: Folder?,
		_spotAnchor = nil :: BasePart?,
		_screenGui = nil :: ScreenGui?,
		_panelContainer = nil :: Frame?,
		_panelTween = nil :: Tween?,
		_ui = nil :: any,
		_silhouette = nil :: Instance?,
		_silhouetteRoot = nil :: BasePart?,
		_silhouetteParts = {} :: { BasePart },
		_silhouetteHighlight = nil :: Highlight?,
		_spotPosition = nil :: Vector3?,
		_baseSilhouetteCFrame = nil :: CFrame?,
		_isAttached = false,
		_isVisible = false,
		_bobConnection = nil :: RBXScriptConnection?,
		_bobOriginCFrame = nil :: CFrame?,
		_bobStartTime = 0,
		_motionTicket = 0,
		_phase = "safe" :: string,
		_snapRiskPercent = 0,
		_hits = 0,
		_requiredHits = 3,
		_dots = {} :: { Frame },
		_flashGui = nil :: ScreenGui?,
		_flashFrame = nil :: Frame?,
		_onPullUp = nil :: (() -> ())?,
		_onKeepDigging = nil :: (() -> ())?,
		_onCancel = nil :: (() -> ())?,
		_connections = {} :: { RBXScriptConnection },
		-- Countdown-mode state. _countdownTicket is bumped any time a fresh
		-- countdown is started (or hideCountdown is called) so a stale
		-- per-frame update task that's still sleeping when a new countdown
		-- arrives can detect that it's been superseded and bail out.
		_countdownActive = false,
		_countdownTicket = 0,
		_countdownStartTime = 0,
		_countdownDuration = 0,
		_countdownConnection = nil :: RBXScriptConnection?,
		_countdownBillboard = nil :: BillboardGui?,
		_countdownBillboardTimer = nil :: TextLabel?,
		_countdownBillboardUIScale = nil :: UIScale?,
	}, DigPullGauge)
	return self
end

function DigPullGauge:isAttached(): boolean
	return self._isAttached
end

function DigPullGauge:isVisible(): boolean
	return self._isAttached and self._isVisible
end

function DigPullGauge:setCallbacks(callbacks: {
	onPullUp: (() -> ())?,
	onKeepDigging: (() -> ())?,
	onCancel: (() -> ())?,
})
	self._onPullUp = callbacks.onPullUp
	self._onKeepDigging = callbacks.onKeepDigging
	self._onCancel = callbacks.onCancel
end

function DigPullGauge:attachToSpot(spotPosition: Vector3, _faceCFrame: CFrame?)
	if self._isAttached then
		self:detach()
	end

	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end
	local userId = localPlayer.UserId

	-- Worldspace folder holds only the silhouette + dirt particles. Info /
	-- controls are drawn in a screen-space ScreenGui below so they don't
	-- scale with camera distance, don't overlap neighbouring tier
	-- billboards, and reliably receive button clicks on desktop.
	local world = Instance.new("Folder")
	world.Name = ("DigPullGaugeWorld_%d"):format(userId)
	world.Parent = Workspace

	local spotAnchor = makeAnchorPart("SpotAnchor", spotPosition)
	spotAnchor.Parent = world

	-- Screen-space panel. The container Frame owns the size/position so the
	-- inner panel built by buildPanel can stay as fromScale(1, 1) and reuse
	-- the same layout the BillboardGui-flavoured version had.
	local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		world:Destroy()
		return
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "DigPullGaugeScreen"
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 12
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = playerGui

	-- Holder gives scale-based gutters so the anchored panel clears the viewport
	-- edge on ultrawide, portrait phones, etc. Children use the inset rect.
	local panelHolder = Instance.new("Frame")
	panelHolder.Name = "PanelViewportHolder"
	panelHolder.Size = UDim2.fromScale(1, 1)
	panelHolder.Position = UDim2.fromScale(0, 0)
	panelHolder.BackgroundTransparency = 1
	panelHolder.BorderSizePixel = 0
	panelHolder.Parent = screenGui
	local holderPad = Instance.new("UIPadding")
	holderPad.PaddingRight = PANEL_HOLDER_MARGIN_X
	holderPad.PaddingTop = PANEL_HOLDER_MARGIN_Y
	holderPad.PaddingBottom = PANEL_HOLDER_MARGIN_Y
	holderPad.Parent = panelHolder

	local panelContainer = Instance.new("Frame")
	panelContainer.Name = "PanelContainer"
	panelContainer.AnchorPoint = PANEL_ANCHOR
	panelContainer.Size = PANEL_BASE_SIZE
	panelContainer.Position = PANEL_POSITION_OFF
	panelContainer.BackgroundTransparency = 1
	panelContainer.Parent = panelHolder

	-- UIScale rescales the whole panel uniformly based on viewport so the
	-- pixel-perfect 280×280 layout shrinks on phones / portrait windows and
	-- grows modestly on large monitors. We keep a reference on the instance
	-- so the viewport listener below can update it without a closure capture
	-- over a stale `self`.
	local panelScale = Instance.new("UIScale")
	panelScale.Name = "ViewportScale"
	panelScale.Parent = panelContainer

	local camera = Workspace.CurrentCamera
	local function refreshResponsiveGuiScale()
		local s = computePanelScale()
		if panelScale.Parent then
			panelScale.Scale = s
		end
		local countdownScale = self._countdownBillboardUIScale
		if countdownScale and countdownScale.Parent then
			countdownScale.Scale = s
		end
	end

	refreshResponsiveGuiScale()

	if camera then
		table.insert(
			self._connections,
			camera:GetPropertyChangedSignal("ViewportSize"):Connect(refreshResponsiveGuiScale)
		)
	end

	local ui = buildPanel(panelContainer)

	table.insert(self._connections, ui.pullUpButton.Activated:Connect(function()
		if self._onPullUp then
			self._onPullUp()
		end
	end))
	table.insert(self._connections, ui.keepButton.Activated:Connect(function()
		if self._onKeepDigging then
			self._onKeepDigging()
		end
	end))
	table.insert(self._connections, ui.cancelButton.Activated:Connect(function()
		if self._onCancel then
			self._onCancel()
		end
	end))

	self._world = world
	self._spotAnchor = spotAnchor
	self._screenGui = screenGui
	self._panelContainer = panelContainer
	self._ui = ui
	self._spotPosition = spotPosition
	self._baseSilhouetteCFrame = CFrame.new(
		spotPosition + Vector3.new(0, SILHOUETTE_REST_HEIGHT, 0)
	)
	self._isAttached = true
	self._isVisible = true
	self._dots = {}

	self:_rebuildDots(self._requiredHits)
	self:_updateDotState()
	self:_applyPhaseStyle()

	-- Slide the panel in from off-screen right. Back-Out gives a subtle
	-- overshoot that makes the entrance feel like a "drawer" snapping into
	-- place rather than just sliding linearly.
	if self._panelTween then
		self._panelTween:Cancel()
	end
	self._panelTween = TweenService:Create(
		panelContainer,
		TweenInfo.new(PANEL_SLIDE_IN_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Position = PANEL_POSITION_ON }
	)
	self._panelTween:Play()
end

function DigPullGauge:detach()
	self._motionTicket += 1
	self:_stopBobbing()
	self:_stopCountdownTracking()
	disconnectAll(self._connections)

	self._countdownActive = false
	self._countdownBillboardUIScale = nil
	if self._countdownBillboard then
		self._countdownBillboard:Destroy()
		self._countdownBillboard = nil
	end
	self._countdownBillboardTimer = nil

	if self._panelTween then
		self._panelTween:Cancel()
		self._panelTween = nil
	end

	if self._silhouette then
		self._silhouette:Destroy()
		self._silhouette = nil
	end
	self._silhouetteRoot = nil
	self._silhouetteParts = {}
	self._silhouetteHighlight = nil

	if self._world then
		self._world:Destroy()
		self._world = nil
	end
	self._spotAnchor = nil

	-- Slide the panel off-screen before destroying it so the dismount has
	-- a beat instead of popping out. The ScreenGui itself is destroyed
	-- after the slide completes; clear our references up front so callers
	-- that re-enter detach() don't double-destroy the gui.
	local screenGui = self._screenGui
	local panelContainer = self._panelContainer
	self._screenGui = nil
	self._panelContainer = nil
	self._ui = nil
	self._dots = {}

	if screenGui and panelContainer and panelContainer.Parent then
		local slideOut = TweenService:Create(
			panelContainer,
			TweenInfo.new(PANEL_SLIDE_OUT_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Position = PANEL_POSITION_OFF }
		)
		slideOut.Completed:Connect(function()
			if screenGui.Parent then
				screenGui:Destroy()
			end
		end)
		slideOut:Play()
	elseif screenGui then
		screenGui:Destroy()
	end

	if self._flashGui then
		self._flashGui:Destroy()
		self._flashGui = nil
		self._flashFrame = nil
	end

	self._spotPosition = nil
	self._baseSilhouetteCFrame = nil
	self._bobOriginCFrame = nil
	self._isAttached = false
	self._isVisible = false
end

function DigPullGauge:Destroy()
	self:detach()
	self._onPullUp = nil
	self._onKeepDigging = nil
	self._onCancel = nil
end

-- ───────────────────────────────────────────────────────────────────────────
-- Setters: phase, hits, luck, rhythm
-- ───────────────────────────────────────────────────────────────────────────

function DigPullGauge:setHits(hits: number, requiredHits: number?)
	self._hits = math.max(0, math.floor(hits))
	if requiredHits and requiredHits ~= self._requiredHits then
		self._requiredHits = math.max(1, math.floor(requiredHits))
		self:_rebuildDots(self._requiredHits)
	end
	self:_updateDotState()
end

function DigPullGauge:setPhase(phase: string, snapRiskPercent: number?)
	if phase ~= "safe" and phase ~= "risky" then
		return
	end
	self._phase = phase
	self._snapRiskPercent = snapRiskPercent or 0
	self:_applyPhaseStyle()
end

-- Updates the gold luck multiplier readout without disturbing the silhouette.
-- Useful when the server sends a luck-only refresh between rolls.
function DigPullGauge:setLuck(currentLuck: number)
	if not self._ui then
		return
	end
	self._ui.luckLabel.Text = formatLuckMultiplier(currentLuck) .. " LUCK"
end

-- ───────────────────────────────────────────────────────────────────────────
-- Countdown mode (PHASE_DIGGING)
-- ───────────────────────────────────────────────────────────────────────────

local function formatCountdownTimer(secondsRemaining: number): string
	local s = math.max(0, secondsRemaining)
	if s >= 10 then
		return ("%ds"):format(math.floor(s + 0.5))
	end
	return ("%.1fs"):format(s)
end

function DigPullGauge:_ensureCountdownBillboard()
	if not self._isAttached or not self._spotAnchor then
		return
	end
	if self._countdownBillboard and self._countdownBillboard.Parent then
		if self._countdownBillboardUIScale then
			self._countdownBillboardUIScale.Scale = computePanelScale()
		end
		return
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DigCountdownBillboard"
	billboard.Adornee = self._spotAnchor
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Size = COUNTDOWN_BILLBOARD_SIZE
	billboard.StudsOffsetWorldSpace = COUNTDOWN_BILLBOARD_OFFSET
	billboard.ResetOnSpawn = false
	billboard.Parent = self._world or self._spotAnchor

	local bg = Instance.new("Frame")
	bg.Name = "Bg"
	bg.AnchorPoint = Vector2.new(0.5, 0.5)
	bg.Position = UDim2.fromScale(0.5, 0.5)
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = PANEL_BG
	bg.BackgroundTransparency = 0.15
	bg.BorderSizePixel = 0
	bg.Parent = billboard
	addCorner(bg, UDim.new(0, 10))
	addStroke(bg, PANEL_STROKE, 2, 0.1)
	addGradient(bg, PANEL_BG, PANEL_BG_BOTTOM)

	local bbScale = Instance.new("UIScale")
	bbScale.Name = "ViewportScale"
	bbScale.Scale = computePanelScale()
	bbScale.Parent = bg
	self._countdownBillboardUIScale = bbScale

	local timer = Instance.new("TextLabel")
	timer.Name = "Timer"
	timer.AnchorPoint = Vector2.new(0.5, 0.5)
	timer.Position = UDim2.fromScale(0.5, 0.5)
	timer.Size = UDim2.new(1, -10, 1, -10)
	timer.BackgroundTransparency = 1
	timer.Font = Enum.Font.GothamBlack
	timer.Text = "5.0s"
	timer.TextColor3 = COUNTDOWN_TIMER_TEXT_COLOR
	timer.TextScaled = true
	timer.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	timer.TextStrokeTransparency = 0
	timer.Parent = bg

	self._countdownBillboard = billboard
	self._countdownBillboardTimer = timer
end

function DigPullGauge:_destroyCountdownBillboard()
	self._countdownBillboardUIScale = nil
	if self._countdownBillboard then
		self._countdownBillboard:Destroy()
		self._countdownBillboard = nil
	end
	self._countdownBillboardTimer = nil
end

function DigPullGauge:_stopCountdownTracking()
	if self._countdownConnection then
		self._countdownConnection:Disconnect()
		self._countdownConnection = nil
	end
end

-- Switches the panel into countdown mode for `durationSeconds`. The reveal
-- content (rarity ribbon / odds / luck / pull-up / keep-digging buttons) is
-- covered by the countdown overlay; per-frame updates tween the progress fill
-- and update both the panel timer + worldspace billboard timer. The
-- accompanying CANCEL button fires the onCancel callback registered via
-- setCallbacks; callers should route that to a DIG_STOP server fire so the
-- session is torn down without penalty.
function DigPullGauge:showCountdown(durationSeconds: number)
	if not self._isAttached or not self._ui then
		return
	end

	local duration = math.max(0.05, tonumber(durationSeconds) or 0)
	self._countdownTicket += 1
	local ticket = self._countdownTicket
	self._countdownActive = true
	self._countdownDuration = duration
	self._countdownStartTime = os.clock()

	-- Pause the silhouette bobbing while we're in countdown mode; any
	-- in-flight rise/drop tween is also cancelled by the next motionTicket
	-- bump from showCandidate when the countdown ends.
	self:_stopBobbing()

	-- Reveal the countdown overlay over the rarity/odds/luck/buttons rows.
	self._ui.countdownGroup.Visible = true
	self._ui.countdownFill.Size = UDim2.fromScale(0, 1)
	self._ui.countdownTimer.Text = formatCountdownTimer(duration)

	self:_ensureCountdownBillboard()
	if self._countdownBillboardTimer then
		self._countdownBillboardTimer.Text = formatCountdownTimer(duration)
	end

	-- Per-frame update so both the panel timer text + horizontal progress
	-- fill + worldspace billboard timer stay in sync. We don't TweenService
	-- this because the text label needs frame-accurate countdown values and
	-- TweenService doesn't directly tween strings.
	self:_stopCountdownTracking()
	self._countdownConnection = RunService.Heartbeat:Connect(function()
		if ticket ~= self._countdownTicket then
			return
		end
		if not self._countdownActive or not self._ui then
			return
		end

		local elapsed = os.clock() - self._countdownStartTime
		local remaining = math.max(0, self._countdownDuration - elapsed)
		local progress = if self._countdownDuration > 0
			then math.clamp(elapsed / self._countdownDuration, 0, 1)
			else 1

		self._ui.countdownTimer.Text = formatCountdownTimer(remaining)
		self._ui.countdownFill.Size = UDim2.fromScale(progress, 1)
		if self._countdownBillboardTimer then
			self._countdownBillboardTimer.Text = formatCountdownTimer(remaining)
		end

		if remaining <= 0 then
			-- Snap the progress + timer to zero so the visual end state is
			-- precise even if the actual server-side completion arrives a
			-- few frames later via DIG_STATE. The heartbeat keeps running
			-- until hideCountdown bumps the ticket; that lets us avoid a
			-- one-frame flicker between "0.0s" and the silhouette reveal.
			self._ui.countdownTimer.Text = formatCountdownTimer(0)
			self._ui.countdownFill.Size = UDim2.fromScale(1, 1)
			if self._countdownBillboardTimer then
				self._countdownBillboardTimer.Text = formatCountdownTimer(0)
			end
		end
	end)
end

-- Tears down the countdown overlay + worldspace billboard and bumps the
-- countdown ticket so any sleeping per-frame update bails out. Safe to call
-- repeatedly. Called automatically by showCandidate so the reveal can take
-- the panel back over cleanly.
function DigPullGauge:hideCountdown()
	self._countdownTicket += 1
	self._countdownActive = false
	self:_stopCountdownTracking()
	self:_destroyCountdownBillboard()

	if self._ui and self._ui.countdownGroup then
		self._ui.countdownGroup.Visible = false
	end
end

function DigPullGauge:setRhythmWindow(widthFraction: number)
	if not self._ui then
		return
	end
	local w = math.clamp(widthFraction, 0, 1)
	self._ui.rhythmFill.Size = UDim2.fromScale(w, 1)
end

function DigPullGauge:setRhythmChain(chainCount: number)
	if not self._ui then
		return
	end
	local count = math.max(0, math.floor(chainCount))
	if count <= 0 then
		self._ui.chainLabel.Visible = false
		self._ui.chainLabel.Text = ""
	else
		self._ui.chainLabel.Visible = true
		self._ui.chainLabel.Text = ("CHAIN x%d"):format(count)
	end
end

function DigPullGauge:playRhythmTick()
	-- Step 4 hooks the chain feedback into this. For Step 1 the API exists
	-- but the visual is a no-op so callers can safely wire it up early.
end

-- ───────────────────────────────────────────────────────────────────────────
-- showCandidate + rise/drop/snap animations
-- ───────────────────────────────────────────────────────────────────────────

function DigPullGauge:showCandidate(params: {
	brainrotId: string,
	rarityName: string,
	rarityColor: Color3?,
	oddsDenominator: number,
	luckMultiplier: number,
})
	if not self._isAttached or not self._ui then
		return
	end

	-- A fresh candidate is always preceded by the countdown completing; tear
	-- down the countdown UI before the reveal so the rarity ribbon + buttons
	-- snap back into place underneath where the overlay used to be.
	self:hideCountdown()

	-- Update billboard text immediately so the new info is in place by the
	-- time the rising silhouette settles.
	self:_setRarityHeader(params.rarityName, params.rarityColor)
	self._ui.oddsLabel.Text = formatOdds(params.oddsDenominator)
	self._ui.luckLabel.Text = formatLuckMultiplier(params.luckMultiplier) .. " LUCK"

	self._motionTicket += 1
	local ticket = self._motionTicket
	local rarityColor = params.rarityColor or FALLBACK_RARITY_COLOR
	local brainrotId = params.brainrotId

	task.spawn(function()
		if self._silhouette then
			self:playDropAnimation()
			task.wait(math.max(DROP_DURATION, DROP_FADE_DURATION) + 0.05)
			if ticket ~= self._motionTicket then
				return
			end
			if self._silhouette then
				self._silhouette:Destroy()
				self._silhouette = nil
				self._silhouetteRoot = nil
				self._silhouetteParts = {}
				self._silhouetteHighlight = nil
			end
		end

		if ticket ~= self._motionTicket then
			return
		end

		if not self:_buildSilhouette(brainrotId, rarityColor) then
			return
		end

		if ticket ~= self._motionTicket then
			return
		end

		if self._spotPosition then
			spawnDirtBurst(self._spotPosition + Vector3.new(0, 0.2, 0))
		end

		self:playRiseAnimation()
	end)
end

function DigPullGauge:playRiseAnimation()
	if not self._silhouetteRoot or not self._spotPosition then
		return
	end

	local rest = self._baseSilhouetteCFrame
		or CFrame.new(self._spotPosition + Vector3.new(0, SILHOUETTE_REST_HEIGHT, 0))
	local startCF = rest * CFrame.new(0, -SILHOUETTE_RISE_OFFSET, 0)
	self._silhouetteRoot.CFrame = startCF

	-- Back-Out gives a subtle overshoot so the silhouette lands with a little
	-- pop rather than just settling — sells the "burst out of the dirt" feel.
	TweenService:Create(
		self._silhouetteRoot,
		TweenInfo.new(RISE_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ CFrame = rest }
	):Play()

	local fadeInfo = TweenInfo.new(RISE_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, part in self._silhouetteParts do
		TweenService:Create(part, fadeInfo, { Transparency = 0 }):Play()
	end
	if self._silhouetteHighlight then
		TweenService:Create(self._silhouetteHighlight, fadeInfo, {
			FillTransparency = 0,
			OutlineTransparency = 0,
		}):Play()
	end

	-- Latch the bob start to this exact silhouette so a follow-up showCandidate
	-- mid-rise doesn't accidentally leave bobbing running on a stale model.
	local silhouetteSnapshot = self._silhouette
	task.delay(RISE_DURATION + 0.05, function()
		if silhouetteSnapshot ~= self._silhouette then
			return
		end
		if not self._silhouetteRoot or not self._silhouetteRoot.Parent then
			return
		end
		self:_startBobbing(rest)
	end)
end

function DigPullGauge:playDropAnimation()
	if not self._silhouetteRoot or not self._spotPosition then
		return
	end
	self:_stopBobbing()

	local rest = self._baseSilhouetteCFrame
		or CFrame.new(self._spotPosition + Vector3.new(0, SILHOUETTE_REST_HEIGHT, 0))
	local target = rest * CFrame.new(0, -SILHOUETTE_RISE_OFFSET, 0)

	TweenService:Create(
		self._silhouetteRoot,
		TweenInfo.new(DROP_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ CFrame = target }
	):Play()

	local fadeInfo = TweenInfo.new(DROP_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	for _, part in self._silhouetteParts do
		TweenService:Create(part, fadeInfo, { Transparency = 1 }):Play()
	end
	if self._silhouetteHighlight then
		TweenService:Create(self._silhouetteHighlight, fadeInfo, {
			FillTransparency = 1,
			OutlineTransparency = 1,
		}):Play()
	end
end

function DigPullGauge:playSnapAnimation()
	if not self._isAttached then
		return
	end
	self._motionTicket += 1
	self:_stopBobbing()

	local root = self._silhouetteRoot
	if root and root.Parent then
		local rest = self._baseSilhouetteCFrame or root.CFrame
		local kicked = rest
			* CFrame.Angles(
				math.rad(math.random(-15, 15)),
				math.rad(math.random(-15, 15)),
				math.rad(math.random(-15, 15))
			)
			* CFrame.new(0, -0.4, 0)

		TweenService:Create(
			root,
			TweenInfo.new(SNAP_KICK_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ CFrame = kicked }
		):Play()

		local parts = self._silhouetteParts
		local highlight = self._silhouetteHighlight
		task.delay(SNAP_KICK_DURATION, function()
			if not root.Parent then
				return
			end
			local fall = kicked * CFrame.new(0, -SILHOUETTE_RISE_OFFSET - 2, 0)
			TweenService:Create(
				root,
				TweenInfo.new(SNAP_DROP_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.In),
				{ CFrame = fall }
			):Play()

			local fadeInfo =
				TweenInfo.new(SNAP_DROP_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			for _, part in parts do
				if part.Parent then
					TweenService:Create(part, fadeInfo, { Transparency = 1 }):Play()
				end
			end
			if highlight and highlight.Parent then
				TweenService:Create(highlight, fadeInfo, {
					FillTransparency = 1,
					OutlineTransparency = 1,
				}):Play()
			end
		end)
	end

	self:_playSnapFlash()

	local localPlayer = Players.LocalPlayer
	if localPlayer then
		task.spawn(CameraEffects.shake, localPlayer, SNAP_SHAKE_DURATION, SNAP_SHAKE_INTENSITY)
	end
end

-- ───────────────────────────────────────────────────────────────────────────
-- Internal helpers
-- ───────────────────────────────────────────────────────────────────────────

function DigPullGauge:_setRarityHeader(rarityName: string, rarityColor: Color3?)
	if not self._ui then
		return
	end
	local color = rarityColor or FALLBACK_RARITY_COLOR

	self._ui.rarityLabel.Text = string.upper(tostring(rarityName))
	-- White text on the colored ribbon reads better than tinted text and
	-- matches the rest of the game's UI (e.g. hotbar buttons use white
	-- text on saturated fills).
	self._ui.rarityLabel.TextColor3 = Color3.fromRGB(255, 255, 255)

	-- Tint the ribbon background with the rarity color and a slightly
	-- darker shade at the bottom for a chunky, card-game gradient.
	local darker = Color3.new(
		color.R * 0.55,
		color.G * 0.55,
		color.B * 0.55
	)
	self._ui.rarityRibbon.BackgroundColor3 = color
	if self._ui.ribbonGradient then
		self._ui.ribbonGradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, color),
			ColorSequenceKeypoint.new(1, darker),
		})
	end
	if self._ui.ribbonStroke then
		self._ui.ribbonStroke.Color = darker
	end
end

function DigPullGauge:_buildSilhouette(brainrotId: string, rarityColor: Color3): boolean
	if not self._world or not self._spotPosition then
		return false
	end

	local startCFrame = CFrame.new(
		self._spotPosition + Vector3.new(0, SILHOUETTE_REST_HEIGHT - SILHOUETTE_RISE_OFFSET, 0)
	)

	local visual: Instance?
	local rootPart: BasePart?

	if BrainrotVisualFactory.hasTemplate(brainrotId) then
		visual, rootPart = BrainrotVisualFactory.create(brainrotId, {
			parent = self._world,
			cframe = startCFrame,
			targetHeight = SILHOUETTE_TARGET_HEIGHT,
			animateIdle = false,
			name = "DigPullGaugeSilhouette",
			allowFallback = false,
		})
	end

	if not visual or not rootPart then
		visual, rootPart = createFallbackSilhouette(self._world, startCFrame)
	end

	local parts = applySilhouetteStyling(visual)
	-- Start fully transparent so the rise animation can fade in cleanly.
	for _, part in parts do
		part.Transparency = 1
	end
	local highlight = attachRarityHighlight(visual, rarityColor)
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 1

	self._silhouette = visual
	self._silhouetteRoot = rootPart
	self._silhouetteParts = parts
	self._silhouetteHighlight = highlight
	return true
end

function DigPullGauge:_rebuildDots(total: number)
	if not self._ui then
		return
	end
	for _, dot in self._dots do
		dot:Destroy()
	end
	table.clear(self._dots)

	for i = 1, total do
		local dot = Instance.new("Frame")
		dot.Name = ("Dot%d"):format(i)
		dot.Size = UDim2.new(0, 14, 0, 14)
		dot.BackgroundColor3 = DOT_INACTIVE
		dot.BorderSizePixel = 0
		dot.Parent = self._ui.dotsRow
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = dot
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(0, 0, 0)
		stroke.Thickness = 1
		stroke.Transparency = 0.4
		stroke.Parent = dot
		table.insert(self._dots, dot)
	end
end

function DigPullGauge:_updateDotState()
	for i, dot in self._dots do
		dot.BackgroundColor3 = if i <= self._hits then DOT_ACTIVE else DOT_INACTIVE
	end
end

function DigPullGauge:_applyPhaseStyle()
	if not self._ui then
		return
	end
	if self._phase == "risky" then
		local risk = self._snapRiskPercent or 0
		self._ui.keepSubtext.Text = ("Snap risk: %d%%"):format(math.floor(risk + 0.5))
		self._ui.keepSubtext.TextColor3 = SUBTEXT_RISKY_COLOR
		self._ui.keepSubtext.TextStrokeColor3 = SUBTEXT_RISKY_STROKE_COLOR
		self._ui.keepSubtext.TextStrokeTransparency = SUBTEXT_RISKY_STROKE_TRANSPARENCY
	else
		self._ui.keepSubtext.Text = "Reroll for more luck"
		self._ui.keepSubtext.TextColor3 = SUBTEXT_SAFE_COLOR
		self._ui.keepSubtext.TextStrokeColor3 = SUBTEXT_SAFE_STROKE_COLOR
		self._ui.keepSubtext.TextStrokeTransparency = SUBTEXT_SAFE_STROKE_TRANSPARENCY
	end
end

function DigPullGauge:_startBobbing(restCFrame: CFrame)
	self:_stopBobbing()
	self._bobOriginCFrame = restCFrame
	self._bobStartTime = os.clock()

	self._bobConnection = RunService.Heartbeat:Connect(function()
		local root = self._silhouetteRoot
		local origin = self._bobOriginCFrame
		if not root or not root.Parent or not origin then
			self:_stopBobbing()
			return
		end
		local t = (os.clock() - self._bobStartTime) / BOB_PERIOD
		local offsetY = math.sin(t * math.pi * 2) * BOB_AMPLITUDE
		root.CFrame = origin * CFrame.new(0, offsetY, 0)
	end)
end

function DigPullGauge:_stopBobbing()
	if self._bobConnection then
		self._bobConnection:Disconnect()
		self._bobConnection = nil
	end
	self._bobOriginCFrame = nil
end

function DigPullGauge:_playSnapFlash()
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end
	local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return
	end

	if not self._flashGui or not self._flashGui.Parent then
		local gui = Instance.new("ScreenGui")
		gui.Name = "DigPullGaugeFlashGui"
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = 25
		gui.Parent = playerGui

		local frame = Instance.new("Frame")
		frame.Name = "RedFlash"
		frame.AnchorPoint = Vector2.new(0, 0)
		frame.Position = UDim2.fromScale(0, 0)
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = SNAP_FLASH_COLOR
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.Parent = gui

		self._flashGui = gui
		self._flashFrame = frame
	end

	if self._flashFrame then
		self._flashFrame.BackgroundTransparency = 0.3
		TweenService:Create(
			self._flashFrame,
			TweenInfo.new(SNAP_FLASH_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 1 }
		):Play()
	end
end

return DigPullGauge
