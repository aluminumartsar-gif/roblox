local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local DigConfig = require(ConfigFolder:WaitForChild("DigConfig"))
local DigSiteConfig = require(ConfigFolder:WaitForChild("DigSiteConfig"))
local EconomyConfig = require(ConfigFolder:WaitForChild("EconomyConfig"))
local DigHoleBuilder = require(UtilFolder:WaitForChild("DigHoleBuilder"))

local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))
local WeatherService = require(script.Parent:WaitForChild("WeatherService"))

local DigSiteService = {}
local started = false

local rng = Random.new()
local digArea = nil
local activeSpots: { any } = {}
local spotsFolder: Folder? = nil
local dugSpotFolder: Folder? = nil
local lastSpotPosition: Vector3? = nil

local DIRT_COLOR = Color3.fromRGB(116, 83, 54)
local DIRT_DARK = Color3.fromRGB(72, 54, 42)
local FLAT_CYLINDER_CFRAME = CFrame.Angles(0, 0, math.rad(90))

local dugSpots = {}
local isPositionDug

local function getDigSite()
	return Workspace:FindFirstChild(DigSiteConfig.MODEL_NAME)
end

local function getOrCreateChildFolder(parent: Instance, name: string)
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end

	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function isInFolder(instance: Instance, folder: Instance?)
	return folder ~= nil and instance:IsDescendantOf(folder)
end

local function findFloor(container: Instance)
	local floor = container:FindFirstChild(DigSiteConfig.FLOOR_NAME, true)
	if floor and floor:IsA("BasePart") then
		return floor
	end

	for _, descendant in container:GetDescendants() do
		if descendant:IsA("BasePart")
			and not isInFolder(descendant, spotsFolder)
			and not isInFolder(descendant, dugSpotFolder)
			and descendant.Name ~= DigSiteConfig.GROUND_SPOT_MARKER_NAME
			and descendant.Name ~= DigSiteConfig.DUG_SPOT_MARKER_NAME
		then
			return descendant
		end
	end

	if container:IsA("BasePart") then
		return container
	end

	return nil
end

local function getSpawnPoints(container: Instance, floor: BasePart)
	local spawnPoints = {}
	local spawnsFolder = container:FindFirstChild(DigSiteConfig.HOTSPOT_SPAWNS_NAME, true)

	if spawnsFolder then
		for _, descendant in spawnsFolder:GetDescendants() do
			if descendant:IsA("BasePart") then
				table.insert(spawnPoints, descendant)
			end
		end
	end

	if #spawnPoints == 0 then
		table.insert(spawnPoints, floor)
	end

	return spawnPoints
end

-- Roblox's terrain decoration draws grass blades on every Grass-material
-- voxel surface. The dig floor part sits a hair above the underlying terrain,
-- so those blades poke up through the dirt patch and look like they're
-- levitating. Replacing Grass with Ground inside the floor footprint kills
-- the decoration without removing any of the terrain you can stand on, and
-- leaves the surrounding green grass untouched.
local TERRAIN_CLEAR_PADDING = 4
local TERRAIN_CLEAR_DEPTH = 12
local TERRAIN_CLEAR_LIFT = 1
local terrainClearedFor: { [BasePart]: boolean } = {}

local function clearGrassUnderFloor(floor: BasePart)
	if terrainClearedFor[floor] then
		return
	end

	local terrain = Workspace.Terrain
	if not terrain or not terrain.ReplaceMaterial then
		return
	end

	local minPoint = floor.Position - Vector3.new(
		floor.Size.X * 0.5 + TERRAIN_CLEAR_PADDING,
		TERRAIN_CLEAR_DEPTH,
		floor.Size.Z * 0.5 + TERRAIN_CLEAR_PADDING
	)
	local maxPoint = floor.Position + Vector3.new(
		floor.Size.X * 0.5 + TERRAIN_CLEAR_PADDING,
		TERRAIN_CLEAR_LIFT,
		floor.Size.Z * 0.5 + TERRAIN_CLEAR_PADDING
	)
	local region = Region3.new(minPoint, maxPoint):ExpandToGrid(4)

	-- ReplaceMaterial throws if the region is empty terrain; swallow that
	-- because an empty region is a no-op success for our purposes.
	pcall(function()
		terrain:ReplaceMaterial(region, 4, Enum.Material.Grass, Enum.Material.Ground)
	end)

	terrainClearedFor[floor] = true
end

local function buildDigArea(container: Instance)
	local floor = findFloor(container)
	if not floor then
		return nil
	end

	clearGrassUnderFloor(floor)

	return {
		container = container,
		floor = floor,
		spawnPoints = getSpawnPoints(container, floor),
	}
end

local function refreshDigArea()
	local digSite = getDigSite()
	if not digSite then
		spotsFolder = nil
		dugSpotFolder = nil
		digArea = nil
		return
	end

	spotsFolder = getOrCreateChildFolder(digSite, DigSiteConfig.ACTIVE_SPOTS_FOLDER_NAME)
	dugSpotFolder = getOrCreateChildFolder(digSite, DigSiteConfig.DUG_SPOTS_FOLDER_NAME)
	digArea = buildDigArea(digSite)
end

local function isPointOnFloor(position: Vector3, floor: BasePart)
	local localPosition = floor.CFrame:PointToObjectSpace(position)
	local halfSize = floor.Size * 0.5
	local padding = DigSiteConfig.DIG_SURFACE_PADDING

	return math.abs(localPosition.X) <= halfSize.X + padding
		and math.abs(localPosition.Z) <= halfSize.Z + padding
		and math.abs(localPosition.Y) <= halfSize.Y + DigSiteConfig.DIG_SURFACE_HEIGHT_TOLERANCE
end

local function getTierConfig(tierName: string)
	return DigSiteConfig.GROUND_SPOT_TIERS[tierName]
		or DigSiteConfig.GROUND_SPOT_TIERS[DigSiteConfig.DEFAULT_GROUND_SPOT_TIER]
end

local function rollTier()
	local totalWeight = 0
	for _, tierConfig in DigSiteConfig.GROUND_SPOT_TIERS do
		totalWeight += tierConfig.weight or 1
	end

	local pick = rng:NextNumber(0, totalWeight)
	local running = 0
	for tierName, tierConfig in DigSiteConfig.GROUND_SPOT_TIERS do
		running += tierConfig.weight or 1
		if pick <= running then
			return tierName, tierConfig
		end
	end

	return DigSiteConfig.DEFAULT_GROUND_SPOT_TIER, getTierConfig(DigSiteConfig.DEFAULT_GROUND_SPOT_TIER)
end

local function getRandomSurfacePoint(part: BasePart)
	local margin = DigSiteConfig.GROUND_SPOT_FOOTPRINT * 0.5
	local halfX = math.max(0, part.Size.X * 0.5 - margin)
	local halfZ = math.max(0, part.Size.Z * 0.5 - margin)
	local offset = Vector3.new(rng:NextNumber(-halfX, halfX), part.Size.Y * 0.5 + 0.1, rng:NextNumber(-halfZ, halfZ))

	return part.CFrame:PointToWorldSpace(offset)
end

local function getHorizontalDistance(left: Vector3, right: Vector3)
	return (Vector3.new(left.X, 0, left.Z) - Vector3.new(right.X, 0, right.Z)).Magnitude
end

local function isFarFromExistingSpots(position: Vector3)
	for _, spot in activeSpots do
		if getHorizontalDistance(position, spot.position) < DigSiteConfig.GROUND_SPOT_MIN_REPEAT_DISTANCE then
			return false
		end
	end

	if lastSpotPosition and getHorizontalDistance(position, lastSpotPosition) < DigSiteConfig.GROUND_SPOT_MIN_REPEAT_DISTANCE * 0.6 then
		return false
	end

	return true
end

local function getSpotSpawnArea(spawnArea: BasePart)
	if not digArea then
		return spawnArea
	end

	if spawnArea == digArea.floor then
		return spawnArea
	end

	if spawnArea.Size.X <= DigSiteConfig.GROUND_SPOT_FOOTPRINT or spawnArea.Size.Z <= DigSiteConfig.GROUND_SPOT_FOOTPRINT then
		return digArea.floor
	end

	return spawnArea
end

local function pickSpotPosition()
	local fallbackPosition = nil

	for _ = 1, DigSiteConfig.GROUND_SPOT_POSITION_ATTEMPTS do
		local spawnArea = getSpotSpawnArea(digArea.spawnPoints[rng:NextInteger(1, #digArea.spawnPoints)])
		local position = getRandomSurfacePoint(spawnArea)

		if isPointOnFloor(position, digArea.floor) and not isPositionDug(position) then
			fallbackPosition = fallbackPosition or position

			if isFarFromExistingSpots(position) then
				return position
			end
		end
	end

	return fallbackPosition
end

local function prepareSpotPart(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
end

local function formatMultiplier(value: number): string
	if value == math.floor(value) then
		return ("×%d"):format(value)
	end
	return ("×%.1f"):format(value)
end

-- Color cycle used by Eldritch and Cosmic tiers. The palette intentionally
-- skips through hot, cold, and otherworldly hues so the outline shimmers
-- across the entire visible spectrum rather than fading between neighboring
-- shades and reading as a single drift.
local ANIMATED_HIGHLIGHT_PALETTE = {
	Color3.fromRGB(255, 120, 255),
	Color3.fromRGB(120, 200, 255),
	Color3.fromRGB(120, 255, 180),
	Color3.fromRGB(255, 230, 120),
	Color3.fromRGB(255, 130, 100),
	Color3.fromRGB(180, 120, 255),
}
local ANIMATED_HIGHLIGHT_STEP = 1.1

local function animateHighlightColors(highlight: Highlight)
	task.spawn(function()
		local index = 0
		while highlight.Parent do
			index = (index % #ANIMATED_HIGHLIGHT_PALETTE) + 1
			local target = ANIMATED_HIGHLIGHT_PALETTE[index]
			TweenService:Create(
				highlight,
				TweenInfo.new(ANIMATED_HIGHLIGHT_STEP, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ FillColor = target, OutlineColor = target }
			):Play()
			task.wait(ANIMATED_HIGHLIGHT_STEP)
		end
	end)
end

-- Single source of truth for marker visibility: every tier ends up with one
-- of these so even the cheapest Common spot stays readable from a few studs
-- out, and Mythic-and-up tiers get AlwaysOnTop so they punch through walls
-- and other dig spots.
local function applyHighlight(model: Model, tierConfig)
	local highlight = Instance.new("Highlight")
	highlight.Name = "TierHighlight"
	highlight.FillColor = tierConfig.highlightFillColor or tierConfig.accentColor
	highlight.OutlineColor = tierConfig.highlightOutlineColor or tierConfig.accentColor
	highlight.FillTransparency = tierConfig.highlightFillTransparency or 0.7
	highlight.OutlineTransparency = tierConfig.highlightOutlineTransparency or 0
	highlight.DepthMode = if tierConfig.highlightAlwaysOnTop
		then Enum.HighlightDepthMode.AlwaysOnTop
		else Enum.HighlightDepthMode.Occluded
	highlight.Parent = model

	if tierConfig.animatedHighlight then
		animateHighlightColors(highlight)
	end

	return highlight
end

-- Theme palette mirrors DigSpotPromptUI so the floating billboard reads
-- as part of the same UI family as the in-game dig prompt instead of a
-- bolt-on debug label. Only the stroke + ribbon use the per-tier accent
-- color, which keeps "tier identity at a glance" without making the panel
-- itself fight for attention with the rest of the screen.
local BILLBOARD_PANEL_TOP = Color3.fromRGB(38, 28, 20)
local BILLBOARD_PANEL_BOTTOM = Color3.fromRGB(20, 14, 10)
local BILLBOARD_TEXT_LIGHT = Color3.fromRGB(255, 240, 200)
local BILLBOARD_TIMER_BG = Color3.fromRGB(18, 12, 8)
local BILLBOARD_RIBBON_TEXT = Color3.fromRGB(28, 18, 10)

-- Floating billboard above the dig spot. Layout:
--   [TIER ribbon — tier-accent pill at top]
--   [×N multiplier — large, tier-accent]
--   [LUCK subtitle — cream]
--   [⏱ timer chip — dark pill with cream digits]
-- Per-tier `billboardMaxDistance` lets the rare-and-up tiers stay legible
-- across the whole dig site while Common keeps the global default range.
local function buildSpotBillboard(position: Vector3, tierName: string, tierConfig, parent: Model)
	local luckMultiplier = tierConfig.luckMultiplier
	local accentColor = tierConfig.accentColor
	local maxDistance = tierConfig.billboardMaxDistance or DigSiteConfig.GROUND_SPOT_BILLBOARD_RANGE

	local anchor = Instance.new("Part")
	anchor.Name = "BillboardAnchor"
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.CFrame = CFrame.new(position + Vector3.new(0, 0.1, 0))
	anchor.Parent = parent

	-- Stud-sized billboard so it scales naturally with distance like any
	-- other 3D object — far away spots become small badges, close spots
	-- read clearly. Per-tier `billboardSize` lets the rare tiers spawn
	-- physically larger so they stay legible at their longer view ranges
	-- (Common at 35 studs can use a small badge, Cosmic at 250 needs to
	-- be massive so its ×250 LUCK is still readable from across the map).
	-- UDim2.fromOffset (the previous behavior) locked a constant pixel
	-- footprint regardless of distance, which made spots feel oversized
	-- when standing next to them.
	local sizeStuds = tierConfig.billboardSize or DigSiteConfig.GROUND_SPOT_BILLBOARD_DEFAULT_SIZE
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "TierLabel"
	billboard.Adornee = anchor
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Size = UDim2.fromScale(sizeStuds.X, sizeStuds.Y)
	billboard.StudsOffset = Vector3.new(0, sizeStuds.Y * 0.5 + 1.6, 0)
	billboard.MaxDistance = maxDistance
	billboard.ResetOnSpawn = false
	billboard.Parent = anchor

	-- Soft glow halo behind the panel: low-saturation tier-accent disc with
	-- heavy transparency so the panel pops off the world without needing a
	-- huge stroke. Sits behind everything else with negative ZIndex.
	local halo = Instance.new("Frame")
	halo.Name = "Halo"
	halo.AnchorPoint = Vector2.new(0.5, 0.5)
	halo.Position = UDim2.fromScale(0.5, 0.5)
	halo.Size = UDim2.fromScale(1.15, 1.25)
	halo.BackgroundColor3 = accentColor
	halo.BackgroundTransparency = 0.82
	halo.BorderSizePixel = 0
	halo.ZIndex = 0
	halo.Parent = billboard

	local haloCorner = Instance.new("UICorner")
	haloCorner.CornerRadius = UDim.new(0.35, 0)
	haloCorner.Parent = halo

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.fromScale(1, 1)
	panel.BackgroundColor3 = BILLBOARD_PANEL_TOP
	panel.BackgroundTransparency = 0.04
	panel.BorderSizePixel = 0
	panel.ZIndex = 1
	panel.Parent = billboard

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0.18, 0)
	panelCorner.Parent = panel

	local panelGradient = Instance.new("UIGradient")
	panelGradient.Color = ColorSequence.new(BILLBOARD_PANEL_TOP, BILLBOARD_PANEL_BOTTOM)
	panelGradient.Rotation = 90
	panelGradient.Parent = panel

	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = accentColor
	panelStroke.Thickness = 2.5
	panelStroke.Transparency = 0.08
	panelStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	panelStroke.Parent = panel

	-- Tier ribbon at the top: tier-accent pill with the tier name in dark
	-- text. Reads as a quality badge so the player gets the rarity in two
	-- places (color + word) without needing to parse a small label.
	local ribbon = Instance.new("Frame")
	ribbon.Name = "TierRibbon"
	ribbon.AnchorPoint = Vector2.new(0.5, 0)
	ribbon.Position = UDim2.fromScale(0.5, 0.06)
	ribbon.Size = UDim2.fromScale(0.78, 0.21)
	ribbon.BackgroundColor3 = accentColor
	ribbon.BorderSizePixel = 0
	ribbon.ZIndex = 2
	ribbon.Parent = panel

	local ribbonCorner = Instance.new("UICorner")
	ribbonCorner.CornerRadius = UDim.new(0.5, 0)
	ribbonCorner.Parent = ribbon

	local ribbonGradient = Instance.new("UIGradient")
	ribbonGradient.Color = ColorSequence.new(
		accentColor:Lerp(Color3.new(1, 1, 1), 0.25),
		accentColor:Lerp(Color3.new(0, 0, 0), 0.15)
	)
	ribbonGradient.Rotation = 90
	ribbonGradient.Parent = ribbon

	local ribbonStroke = Instance.new("UIStroke")
	ribbonStroke.Color = accentColor:Lerp(Color3.new(0, 0, 0), 0.45)
	ribbonStroke.Thickness = 1.5
	ribbonStroke.Transparency = 0.2
	ribbonStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ribbonStroke.Parent = ribbon

	-- Use a darker version of the tier color for the ribbon text on bright
	-- tiers (Common/Uncommon/Rare/Legendary) and a light cream on the
	-- darker tiers (Mythic, Eldritch). Brightness check via a perceptual
	-- weighted sum so dark tiers don't get unreadable dark-on-dark text.
	local ribbonBrightness = accentColor.R * 0.299 + accentColor.G * 0.587 + accentColor.B * 0.114
	local ribbonTextColor = if ribbonBrightness > 0.55
		then BILLBOARD_RIBBON_TEXT
		else BILLBOARD_TEXT_LIGHT

	local tierLabel = Instance.new("TextLabel")
	tierLabel.Name = "TierName"
	tierLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	tierLabel.Position = UDim2.fromScale(0.5, 0.5)
	tierLabel.Size = UDim2.fromScale(0.92, 0.78)
	tierLabel.BackgroundTransparency = 1
	tierLabel.Font = Enum.Font.GothamBlack
	tierLabel.Text = tierName:upper()
	tierLabel.TextColor3 = ribbonTextColor
	tierLabel.TextScaled = true
	tierLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	tierLabel.TextStrokeTransparency = if ribbonBrightness > 0.55 then 0.85 else 0.35
	tierLabel.ZIndex = 3
	tierLabel.Parent = ribbon

	-- Big multiplier number. The accent color stays here so the tier value
	-- is readable at a glance from across the dig site, but the panel
	-- around it is now warm brown so the overall plate doesn't drown in
	-- accent color the way the old design did.
	local multLabel = Instance.new("TextLabel")
	multLabel.Name = "Multiplier"
	multLabel.AnchorPoint = Vector2.new(0.5, 0)
	multLabel.Position = UDim2.fromScale(0.5, 0.30)
	multLabel.Size = UDim2.fromScale(0.94, 0.36)
	multLabel.BackgroundTransparency = 1
	multLabel.Font = Enum.Font.GothamBlack
	multLabel.Text = formatMultiplier(luckMultiplier)
	multLabel.TextColor3 = accentColor:Lerp(Color3.new(1, 1, 1), 0.15)
	multLabel.TextScaled = true
	multLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	multLabel.TextStrokeTransparency = 0.15
	multLabel.ZIndex = 2
	multLabel.Parent = panel

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.AnchorPoint = Vector2.new(0.5, 0)
	subtitle.Position = UDim2.fromScale(0.5, 0.62)
	subtitle.Size = UDim2.fromScale(0.85, 0.13)
	subtitle.BackgroundTransparency = 1
	subtitle.Font = Enum.Font.GothamBold
	subtitle.Text = "LUCK"
	subtitle.TextColor3 = BILLBOARD_TEXT_LIGHT
	subtitle.TextScaled = true
	subtitle.TextStrokeColor3 = Color3.new(0, 0, 0)
	subtitle.TextStrokeTransparency = 0.4
	subtitle.ZIndex = 2
	subtitle.Parent = panel

	-- Timer chip: dark pill at the bottom with cream text. Visually
	-- distinct from the multiplier so the player can read the deadline
	-- without their eye scanning over the value first.
	local timerChip = Instance.new("Frame")
	timerChip.Name = "TimerChip"
	timerChip.AnchorPoint = Vector2.new(0.5, 1)
	timerChip.Position = UDim2.fromScale(0.5, 0.94)
	timerChip.Size = UDim2.fromScale(0.42, 0.18)
	timerChip.BackgroundColor3 = BILLBOARD_TIMER_BG
	timerChip.BackgroundTransparency = 0.05
	timerChip.BorderSizePixel = 0
	timerChip.ZIndex = 2
	timerChip.Parent = panel

	local timerCorner = Instance.new("UICorner")
	timerCorner.CornerRadius = UDim.new(0.5, 0)
	timerCorner.Parent = timerChip

	local timerStroke = Instance.new("UIStroke")
	timerStroke.Color = accentColor:Lerp(Color3.fromRGB(255, 240, 200), 0.5)
	timerStroke.Thickness = 1.2
	timerStroke.Transparency = 0.3
	timerStroke.Parent = timerChip

	local timerLabel = Instance.new("TextLabel")
	timerLabel.Name = "Timer"
	timerLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	timerLabel.Position = UDim2.fromScale(0.5, 0.5)
	timerLabel.Size = UDim2.fromScale(0.88, 0.82)
	timerLabel.BackgroundTransparency = 1
	timerLabel.Font = Enum.Font.GothamBold
	timerLabel.Text = ("%ds"):format(math.ceil(DigSiteConfig.GROUND_SPOT_LIFETIME))
	timerLabel.TextColor3 = BILLBOARD_TEXT_LIGHT
	timerLabel.TextScaled = true
	timerLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	timerLabel.TextStrokeTransparency = 0.5
	timerLabel.ZIndex = 3
	timerLabel.Parent = timerChip

	return timerLabel
end

local function getFlatCylinderSize(diameter: number, height: number)
	return Vector3.new(height, diameter, diameter)
end

local function flatCylinderCFrame(position: Vector3)
	return CFrame.new(position) * FLAT_CYLINDER_CFRAME
end

-- Tiny invisible anchor part with NO rotation, used to host particle
-- attachments that need a world-aligned local Y axis (i.e. anything that
-- emits via EmissionDirection.Top expecting "up"). Parts using
-- flatCylinderCFrame have their local +Y axis rotated to world -X, so
-- attaching emitters directly would shoot particles sideways instead of
-- up. This anchor sidesteps the rotation entirely.
local function createWorldAlignedAnchor(parent: Instance, worldPosition: Vector3): BasePart
	local anchor = Instance.new("Part")
	anchor.Name = "FXAnchor"
	anchor.Size = Vector3.new(0.05, 0.05, 0.05)
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.CFrame = CFrame.new(worldPosition)
	anchor.Parent = parent
	return anchor
end

-- Common tier base: cracked dirt patch with displaced clods and faint
-- surface fissures. Reused as the earth base by Rare and Epic since those
-- tiers are essentially "dirt + something interesting peeking through"; the
-- Common branch additionally calls decorateAsCommonSpot to add a pulse +
-- warm light, while higher tiers paint over the patch with their own glow
-- and ignore the returned patch part.
local function buildMoundMarker(model: Model, position: Vector3): Part
	local patch = Instance.new("Part")
	patch.Name = "MoundPatch"
	prepareSpotPart(patch)
	patch.Material = Enum.Material.Ground
	patch.Color = DIRT_COLOR:Lerp(DIRT_DARK, 0.18)
	patch.Shape = Enum.PartType.Cylinder
	patch.Size = getFlatCylinderSize(2.6, 0.12)
	patch.Transparency = 0.05
	patch.CFrame = flatCylinderCFrame(position + Vector3.new(0, 0.06, 0))
	patch.Parent = model

	for index = 1, 4 do
		local angle = (index / 4) * math.pi * 2 + rng:NextNumber(-0.4, 0.4)
		local distance = rng:NextNumber(0.5, 1.1)
		local clod = Instance.new("Part")
		clod.Name = "MoundClod" .. index
		prepareSpotPart(clod)
		clod.Material = Enum.Material.Ground
		clod.Color = DIRT_COLOR:Lerp(DIRT_DARK, rng:NextNumber(0, 0.5))
		clod.Size = Vector3.new(rng:NextNumber(0.32, 0.55), rng:NextNumber(0.14, 0.22), rng:NextNumber(0.3, 0.55))
		clod.CFrame = CFrame.new(
			position + Vector3.new(math.cos(angle) * distance, clod.Size.Y * 0.5 + 0.08, math.sin(angle) * distance)
		) * CFrame.Angles(rng:NextNumber(-0.3, 0.3), rng:NextNumber(0, math.pi), rng:NextNumber(-0.3, 0.3))
		clod.Parent = model
	end

	-- Three jittered cracking lines etched into the patch surface so the
	-- Common spot reads as "freshly disturbed earth" rather than a plain
	-- circle of dirt.
	for index = 1, 3 do
		local angle = (index / 3) * math.pi * 2 + rng:NextNumber(-0.4, 0.4)
		local crack = Instance.new("Part")
		crack.Name = "MoundCrack" .. index
		prepareSpotPart(crack)
		crack.Material = Enum.Material.Ground
		crack.Color = DIRT_DARK
		crack.Size = Vector3.new(rng:NextNumber(0.7, 1.2), 0.04, rng:NextNumber(0.05, 0.09))
		crack.CFrame = CFrame.new(position + Vector3.new(0, 0.13, 0))
			* CFrame.Angles(0, angle, 0)
			* CFrame.new(rng:NextNumber(0.1, 0.4), 0, 0)
		crack.Parent = model
	end

	return patch
end

-- Step 2 of the dig minigame rework: Common spots were brown-on-brown and
-- effectively invisible past ~12 studs, which broke the new "only dig on
-- spots" rule (players couldn't find the cheapest tier). This decorator
-- runs only on the Common branch — higher tiers still get the inert base —
-- and adds a slow transparency pulse plus a low-key warm point light. The
-- pulse uses the same TweenInfo cadence as the Glint shimmer so both tiers
-- breathe at a similar rhythm; the light is intentionally weaker than
-- Epic's GemGlow (0.75 / range 5) so Common doesn't read as a high tier.
local function decorateAsCommonSpot(patch: Part, tierConfig)
	if not patch then
		return
	end

	local pulseInfo = TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	TweenService:Create(patch, pulseInfo, { Transparency = 0.3 }):Play()

	local light = Instance.new("PointLight")
	light.Name = "MoundGlow"
	light.Brightness = 0.55
	light.Color = tierConfig.accentColor
	light.Range = 4
	light.Shadows = false
	light.Parent = patch
end

-- Uncommon tier: green-tinted patch with moss tufts and two slim sprouts
-- poking up. Quietly organic so it stands out from Common's plain dirt
-- without competing with the higher tiers' glowing visuals.
local function buildMossPatchMarker(model: Model, position: Vector3, tierConfig)
	local patch = Instance.new("Part")
	patch.Name = "MossPatch"
	prepareSpotPart(patch)
	patch.Material = Enum.Material.Ground
	patch.Color = DIRT_COLOR:Lerp(Color3.fromRGB(90, 130, 70), 0.32)
	patch.Shape = Enum.PartType.Cylinder
	patch.Size = getFlatCylinderSize(2.9, 0.12)
	patch.Transparency = 0.05
	patch.CFrame = flatCylinderCFrame(position + Vector3.new(0, 0.06, 0))
	patch.Parent = model

	for index = 1, 3 do
		local angle = (index / 3) * math.pi * 2 + rng:NextNumber(-0.4, 0.4)
		local distance = rng:NextNumber(0.4, 1.0)
		local tuft = Instance.new("Part")
		tuft.Name = "MossTuft" .. index
		prepareSpotPart(tuft)
		tuft.Material = Enum.Material.Grass
		tuft.Color = tierConfig.accentColor:Lerp(Color3.fromRGB(60, 110, 50), 0.4)
		tuft.Shape = Enum.PartType.Ball
		tuft.Size = Vector3.new(rng:NextNumber(0.45, 0.7), rng:NextNumber(0.25, 0.4), rng:NextNumber(0.45, 0.7))
		tuft.CFrame = CFrame.new(
			position + Vector3.new(math.cos(angle) * distance, tuft.Size.Y * 0.5 + 0.08, math.sin(angle) * distance)
		) * CFrame.Angles(rng:NextNumber(-0.2, 0.2), rng:NextNumber(0, math.pi), rng:NextNumber(-0.2, 0.2))
		tuft.Parent = model
	end

	-- Two thin upright sprouts using neon-green so they catch the eye even
	-- against the green moss; topped with a small leaf wedge.
	for index = 1, 2 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local distance = rng:NextNumber(0.2, 0.5)
		local stem = Instance.new("Part")
		stem.Name = "MossStem" .. index
		prepareSpotPart(stem)
		stem.Material = Enum.Material.Neon
		stem.Color = tierConfig.accentColor
		stem.Shape = Enum.PartType.Cylinder
		stem.Size = Vector3.new(0.55, 0.08, 0.08)
		stem.CFrame = CFrame.new(
			position + Vector3.new(math.cos(angle) * distance, 0.4, math.sin(angle) * distance)
		) * CFrame.Angles(0, 0, math.rad(90))
		stem.Parent = model

		local leaf = Instance.new("Part")
		leaf.Name = "MossLeaf" .. index
		prepareSpotPart(leaf)
		leaf.Material = Enum.Material.Neon
		leaf.Color = tierConfig.accentColor:Lerp(Color3.new(1, 1, 1), 0.2)
		leaf.Shape = Enum.PartType.Block
		leaf.Size = Vector3.new(0.06, 0.16, 0.22)
		leaf.CFrame = CFrame.new(
			position + Vector3.new(math.cos(angle) * distance, 0.7, math.sin(angle) * distance)
		) * CFrame.Angles(math.rad(rng:NextNumber(-25, 25)), rng:NextNumber(0, math.pi), math.rad(rng:NextNumber(-15, 15)))
		leaf.Parent = model
	end

	-- World-aligned anchor: patch is flat-cylinder rotated so a directly
	-- parented attachment would emit drift particles sideways instead of
	-- up. Anchor sits a hair above the patch so leaves spawn at ground.
	local leafAnchor = createWorldAlignedAnchor(model, position + Vector3.new(0, 0.18, 0))
	local attachment = Instance.new("Attachment")
	attachment.Parent = leafAnchor

	-- Sparse leaf-drift particles. Low rate keeps Uncommon visually quiet
	-- compared to the sparkle-heavy Rare and Epic tiers.
	local leaves = Instance.new("ParticleEmitter")
	leaves.Name = "MossDrift"
	leaves.LightEmission = 0.4
	leaves.Color = ColorSequence.new(tierConfig.accentColor, tierConfig.accentColor:Lerp(Color3.new(1, 1, 1), 0.3))
	leaves.Rate = 1.5
	leaves.Lifetime = NumberRange.new(1.5, 2.5)
	leaves.Speed = NumberRange.new(0.3, 0.7)
	leaves.SpreadAngle = Vector2.new(120, 120)
	leaves.EmissionDirection = Enum.NormalId.Top
	leaves.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.18),
		NumberSequenceKeypoint.new(1, 0),
	})
	leaves.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	leaves.Acceleration = Vector3.new(0, 1.2, 0)
	leaves.Parent = attachment

	local light = Instance.new("PointLight")
	light.Name = "MossGlow"
	light.Brightness = 0.6
	light.Color = tierConfig.accentColor
	light.Range = 4
	light.Shadows = false
	light.Parent = patch
end

-- Rare tier: dirt patch with three half-buried blue sapphire shards at
-- varied tilts, plus a thin shimmer stripe rising off the brightest shard.
-- The shards sell "buried gem cache" without needing a flashy beam, and
-- the shimmer + sparkle particles handle visibility from a distance.
-- Renamed from CoinGlint to GemShard so the visual matches the canonical
-- Rare = blue convention rather than treading on Legendary's gold.
local function buildGemShardMarker(model: Model, position: Vector3, tierConfig)
	buildMoundMarker(model, position)

	local brightestShard
	for index = 1, 3 do
		local angle = (index / 3) * math.pi * 2 + rng:NextNumber(-0.5, 0.5)
		local distance = rng:NextNumber(0.25, 0.85)
		local tilt = math.rad(rng:NextNumber(20, 60))
		local shard = Instance.new("Part")
		shard.Name = "GemShard" .. index
		prepareSpotPart(shard)
		shard.Material = Enum.Material.Glass
		shard.Color = tierConfig.accentColor
		shard.Reflectance = 0.4
		shard.Transparency = 0.15
		shard.Size = Vector3.new(0.28, 0.65, 0.32)
		shard.CFrame = CFrame.new(
			position + Vector3.new(math.cos(angle) * distance, 0.32, math.sin(angle) * distance)
		) * CFrame.Angles(tilt, angle, math.rad(rng:NextNumber(-20, 20)))
		shard.Parent = model

		if index == 1 then
			brightestShard = shard
		end
	end

	-- Vertical shimmer stripe right over the lead shard. Slow tween between
	-- 0.2 and 0.8 transparency reads as "catching the light" without being
	-- a permanent column of glow.
	local shimmer = Instance.new("Part")
	shimmer.Name = "GemShimmer"
	prepareSpotPart(shimmer)
	shimmer.Material = Enum.Material.Neon
	shimmer.Color = tierConfig.accentColor:Lerp(Color3.new(1, 1, 1), 0.4)
	shimmer.Shape = Enum.PartType.Cylinder
	shimmer.Size = Vector3.new(1.2, 0.18, 0.18)
	shimmer.Transparency = 0.4
	shimmer.CFrame = CFrame.new(brightestShard.Position + Vector3.new(0, 0.7, 0))
		* CFrame.Angles(0, 0, math.rad(90))
	shimmer.Parent = model

	local shimmerInfo = TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	TweenService:Create(shimmer, shimmerInfo, { Transparency = 0.85 }):Play()

	local attachment = Instance.new("Attachment")
	attachment.Name = "GemParticles"
	attachment.Parent = brightestShard

	local particles = Instance.new("ParticleEmitter")
	particles.Name = "GemSparkles"
	particles.LightEmission = 0.9
	particles.Color = ColorSequence.new(tierConfig.accentColor, Color3.new(1, 1, 1))
	particles.Rate = 4
	particles.Lifetime = NumberRange.new(0.7, 1.2)
	particles.Speed = NumberRange.new(0.6, 1.4)
	particles.SpreadAngle = Vector2.new(160, 160)
	particles.EmissionDirection = Enum.NormalId.Top
	particles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.22),
		NumberSequenceKeypoint.new(1, 0),
	})
	particles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	particles.Parent = attachment

	local light = Instance.new("PointLight")
	light.Name = "GemGlow"
	light.Brightness = 1.0
	light.Color = tierConfig.accentColor
	light.Range = 5
	light.Shadows = false
	light.Parent = brightestShard
end

-- Epic tier: cracked geode shell with a cluster of five crystal shards in
-- varied heights and rotations. Brightest shard pulses; the surrounding
-- broken-rock pieces sell the "geode just split open" silhouette so the
-- visual reads as much more substantial than the old single jewel tip.
local function buildCrystalGeodeMarker(model: Model, position: Vector3, tierConfig)
	buildMoundMarker(model, position)

	local shellColor = Color3.fromRGB(72, 64, 78)

	-- Five broken geode shards arranged in a partial ring around the
	-- crystals. Gap on one side so the cluster isn't fully boxed in and the
	-- crystals stay visible from across the dig site.
	for index = 1, 5 do
		local angle = (index / 6) * math.pi * 2 + 0.3
		local distance = rng:NextNumber(0.85, 1.05)
		local shell = Instance.new("Part")
		shell.Name = "GeodeShell" .. index
		prepareSpotPart(shell)
		shell.Material = Enum.Material.Slate
		shell.Color = shellColor:Lerp(Color3.fromRGB(40, 32, 50), rng:NextNumber(0, 0.5))
		shell.Size = Vector3.new(rng:NextNumber(0.45, 0.7), rng:NextNumber(0.4, 0.65), rng:NextNumber(0.3, 0.45))
		shell.CFrame = CFrame.new(
			position + Vector3.new(math.cos(angle) * distance, shell.Size.Y * 0.5 + 0.06, math.sin(angle) * distance)
		) * CFrame.Angles(math.rad(rng:NextNumber(-25, 25)), angle + rng:NextNumber(-0.3, 0.3), math.rad(rng:NextNumber(-25, 25)))
		shell.Parent = model
	end

	-- Five crystals: a tall central spire plus four surrounding shards.
	-- Sizes drop toward the outside so the cluster has visual hierarchy.
	local crystalPlacements = {
		{ x = 0, z = 0, height = 1.05, scale = 1.0 },
		{ x = 0.35, z = 0.05, height = 0.7, scale = 0.75 },
		{ x = -0.3, z = 0.1, height = 0.65, scale = 0.7 },
		{ x = 0.05, z = -0.32, height = 0.6, scale = 0.7 },
		{ x = -0.15, z = 0.3, height = 0.55, scale = 0.65 },
	}

	local brightestCrystal
	for index, placement in crystalPlacements do
		local crystal = Instance.new("Part")
		crystal.Name = "GeodeCrystal" .. index
		prepareSpotPart(crystal)
		crystal.Material = Enum.Material.Neon
		crystal.Color = tierConfig.accentColor:Lerp(Color3.new(1, 1, 1), index == 1 and 0.15 or 0.0)
		crystal.Reflectance = 0.3
		crystal.Size = Vector3.new(0.32 * placement.scale, placement.height, 0.32 * placement.scale)
		crystal.Transparency = 0.1
		crystal.CFrame = CFrame.new(position + Vector3.new(placement.x, placement.height * 0.5 + 0.1, placement.z))
			* CFrame.Angles(
				math.rad(rng:NextNumber(-12, 12)),
				math.rad(rng:NextNumber(0, 360)),
				math.rad(rng:NextNumber(-12, 12))
			)
		crystal.Parent = model

		if index == 1 then
			brightestCrystal = crystal
		end
	end

	local pulseInfo = TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	TweenService:Create(brightestCrystal, pulseInfo, { Transparency = 0.4 }):Play()

	local attachment = Instance.new("Attachment")
	attachment.Name = "GeodeParticles"
	attachment.Parent = brightestCrystal

	local particles = Instance.new("ParticleEmitter")
	particles.Name = "GeodeSparkles"
	particles.LightEmission = 0.9
	particles.Color = ColorSequence.new(tierConfig.accentColor, Color3.new(1, 1, 1))
	particles.Rate = 6
	particles.Lifetime = NumberRange.new(0.7, 1.3)
	particles.Speed = NumberRange.new(0.6, 1.3)
	particles.SpreadAngle = Vector2.new(160, 160)
	particles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.24),
		NumberSequenceKeypoint.new(1, 0),
	})
	particles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	particles.Parent = attachment

	local light = Instance.new("PointLight")
	light.Name = "GeodeGlow"
	light.Brightness = 1.4
	light.Color = tierConfig.accentColor
	light.Range = 7
	light.Shadows = false
	light.Parent = brightestCrystal
end

-- Legendary tier: cracked basalt slab with glowing magma seams threading
-- through it. Embers rise from the seams, a heat-haze emitter blurs the air
-- above, and the orange light flickers irregularly to sell live volcanic
-- activity. Replaces the old cyan geyser, which read closer to a "treasure"
-- effect than to its tier name.
local function buildMagmaVentMarker(model: Model, position: Vector3, tierConfig)
	local slab = Instance.new("Part")
	slab.Name = "BasaltSlab"
	prepareSpotPart(slab)
	slab.Material = Enum.Material.Slate
	slab.Color = Color3.fromRGB(38, 30, 28)
	slab.Shape = Enum.PartType.Cylinder
	slab.Size = getFlatCylinderSize(3.0, 0.14)
	slab.Transparency = 0.05
	slab.CFrame = flatCylinderCFrame(position + Vector3.new(0, 0.07, 0))
	slab.Parent = model

	-- Four magma seams cut across the slab at varied angles. Each seam pulses
	-- on its own cadence so the ground looks like it's breathing heat.
	local seamCount = 4
	for index = 1, seamCount do
		local angle = (index / seamCount) * math.pi + rng:NextNumber(-0.3, 0.3)
		local seamLen = rng:NextNumber(1.6, 2.5)
		local seam = Instance.new("Part")
		seam.Name = "MagmaSeam" .. index
		prepareSpotPart(seam)
		seam.Material = Enum.Material.Neon
		seam.Color = tierConfig.accentColor
		seam.Size = Vector3.new(seamLen, 0.06, rng:NextNumber(0.12, 0.22))
		seam.Transparency = 0.2
		seam.CFrame = CFrame.new(position + Vector3.new(rng:NextNumber(-0.3, 0.3), 0.15, rng:NextNumber(-0.3, 0.3)))
			* CFrame.Angles(0, angle, 0)
		seam.Parent = model

		local seamPulse = TweenInfo.new(rng:NextNumber(0.9, 1.4), Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
		TweenService:Create(seam, seamPulse, { Transparency = 0.55 }):Play()
	end

	-- Smaller bright "lava splatter" droplets scattered across the slab to
	-- break up the seam grid pattern.
	for index = 1, 4 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local dist = rng:NextNumber(0.3, 1.0)
		local splatter = Instance.new("Part")
		splatter.Name = "LavaSplatter" .. index
		prepareSpotPart(splatter)
		splatter.Material = Enum.Material.Neon
		splatter.Color = tierConfig.accentColor:Lerp(Color3.fromRGB(255, 230, 120), 0.4)
		splatter.Shape = Enum.PartType.Ball
		splatter.Size = Vector3.new(rng:NextNumber(0.16, 0.26), rng:NextNumber(0.16, 0.26), rng:NextNumber(0.16, 0.26))
		splatter.Transparency = 0.2
		splatter.CFrame = CFrame.new(position + Vector3.new(math.cos(angle) * dist, 0.18, math.sin(angle) * dist))
		splatter.Parent = model
	end

	local emitterAnchor = createWorldAlignedAnchor(model, position + Vector3.new(0, 0.2, 0))
	local attachment = Instance.new("Attachment")
	attachment.Parent = emitterAnchor

	local embers = Instance.new("ParticleEmitter")
	embers.Name = "MagmaEmbers"
	embers.LightEmission = 1
	embers.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, tierConfig.accentColor),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 90, 30)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(40, 8, 4)),
	})
	embers.Rate = 16
	embers.Lifetime = NumberRange.new(1.0, 1.8)
	embers.Speed = NumberRange.new(2.5, 5)
	embers.SpreadAngle = Vector2.new(22, 22)
	embers.EmissionDirection = Enum.NormalId.Top
	embers.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.28),
		NumberSequenceKeypoint.new(0.5, 0.18),
		NumberSequenceKeypoint.new(1, 0),
	})
	embers.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(1, 1),
	})
	embers.RotSpeed = NumberRange.new(-60, 60)
	embers.Parent = attachment

	-- Heat-haze emitter: faint, very transparent puffs to suggest hot air
	-- shimmer above the slab.
	local heat = Instance.new("ParticleEmitter")
	heat.Name = "HeatHaze"
	heat.LightEmission = 0.2
	heat.Color = ColorSequence.new(Color3.fromRGB(255, 200, 160), Color3.fromRGB(255, 230, 200))
	heat.Rate = 4
	heat.Lifetime = NumberRange.new(1.5, 2.5)
	heat.Speed = NumberRange.new(0.8, 1.5)
	heat.SpreadAngle = Vector2.new(70, 70)
	heat.EmissionDirection = Enum.NormalId.Top
	heat.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(1, 1.6),
	})
	heat.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.85),
		NumberSequenceKeypoint.new(0.4, 0.9),
		NumberSequenceKeypoint.new(1, 1),
	})
	heat.Parent = attachment

	local light = Instance.new("PointLight")
	light.Name = "MagmaGlow"
	light.Brightness = 2.4
	light.Color = tierConfig.accentColor
	light.Range = 9
	light.Shadows = false
	light.Parent = slab

	-- Irregular flicker via stuttering tween. Two short tween calls back to
	-- back at randomized brightness sells real fire flicker much better than
	-- a single sine wave.
	task.spawn(function()
		while light.Parent do
			local highInfo = TweenInfo.new(rng:NextNumber(0.18, 0.35), Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			TweenService:Create(light, highInfo, { Brightness = rng:NextNumber(2.2, 3.0) }):Play()
			task.wait(rng:NextNumber(0.18, 0.35))
			local lowInfo = TweenInfo.new(rng:NextNumber(0.15, 0.3), Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			TweenService:Create(light, lowInfo, { Brightness = rng:NextNumber(1.4, 2.0) }):Play()
			task.wait(rng:NextNumber(0.15, 0.3))
		end
	end)
end

-- Mythic tier: a dark void rift tears through the earth, venting crimson
-- energy upward. The 7 jittered cracks now feed into a recessed central
-- "tear" cylinder that breathes in sync with the cracks, and the deep red
-- PointLight stutters like an angry ember instead of holding a steady
-- brightness. Reads as something cosmic and slightly alive at a glance.
local function buildVoidRiftMarker(model: Model, position: Vector3, tierConfig)
	local voidDisc = Instance.new("Part")
	voidDisc.Name = "VoidDisc"
	prepareSpotPart(voidDisc)
	voidDisc.Material = Enum.Material.SmoothPlastic
	voidDisc.Color = Color3.fromRGB(8, 4, 4)
	voidDisc.Shape = Enum.PartType.Cylinder
	voidDisc.Size = getFlatCylinderSize(3.2, 0.08)
	voidDisc.Transparency = 0.05
	voidDisc.CFrame = flatCylinderCFrame(position + Vector3.new(0, 0.1, 0))
	voidDisc.Parent = model

	-- Recessed central "tear" cylinder. Sits in the middle of the void disc
	-- and breathes in transparency so the cracks look like they're feeding
	-- a bleeding wound rather than just radiating from a point.
	local tear = Instance.new("Part")
	tear.Name = "VoidTear"
	prepareSpotPart(tear)
	tear.Material = Enum.Material.Neon
	tear.Color = tierConfig.accentColor
	tear.Shape = Enum.PartType.Cylinder
	tear.Size = getFlatCylinderSize(0.9, 0.05)
	tear.Transparency = 0.1
	tear.CFrame = flatCylinderCFrame(position + Vector3.new(0, 0.16, 0))
	tear.Parent = model

	local tearPulse = TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	TweenService:Create(tear, tearPulse, { Transparency = 0.6 }):Play()

	-- 7 cracks: prime count + strong jitter breaks symmetry so the pattern
	-- reads as shattered earth rather than a clock or compass rose.
	local baseAngles = { 0.18, 0.88, 1.52, 2.31, 3.05, 3.78, 5.1 }
	for index, baseAngle in baseAngles do
		local angle = baseAngle + rng:NextNumber(-0.28, 0.28)
		local crackLen = rng:NextNumber(0.6, 1.7)
		-- Offset the crack origin slightly off-center so they don't all
		-- converge at a single point.
		local originOffset = rng:NextNumber(0, 0.35)
		local crackPart = Instance.new("Part")
		crackPart.Name = "VoidCrack" .. index
		prepareSpotPart(crackPart)
		crackPart.Material = Enum.Material.Neon
		crackPart.Color = tierConfig.accentColor
		crackPart.Size = Vector3.new(crackLen, 0.07, rng:NextNumber(0.08, 0.16))
		crackPart.Transparency = 0.25
		crackPart.CFrame = CFrame.new(
			position + Vector3.new(
				math.cos(angle) * (originOffset + crackLen * 0.5),
				0.18,
				math.sin(angle) * (originOffset + crackLen * 0.5)
			)
		) * CFrame.Angles(0, angle, 0)
		crackPart.Parent = model

		local crackPulse = TweenInfo.new(rng:NextNumber(0.65, 1.15), Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
		TweenService:Create(crackPart, crackPulse, { Transparency = 0.68 }):Play()
	end

	-- Small dark debris fragments scattered across the void disc to break up
	-- the clean circle and make it feel more violently fractured.
	for index = 1, 5 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local dist = rng:NextNumber(0.2, 1.2)
		local frag = Instance.new("Part")
		frag.Name = "VoidFrag" .. index
		prepareSpotPart(frag)
		frag.Material = Enum.Material.SmoothPlastic
		frag.Color = Color3.fromRGB(6, 2, 2)
		frag.Size = Vector3.new(rng:NextNumber(0.14, 0.34), 0.09, rng:NextNumber(0.12, 0.28))
		frag.Transparency = 0.15
		frag.CFrame = CFrame.new(
			position + Vector3.new(math.cos(angle) * dist, 0.14, math.sin(angle) * dist)
		) * CFrame.Angles(rng:NextNumber(-0.2, 0.2), rng:NextNumber(0, math.pi), rng:NextNumber(-0.2, 0.2))
		frag.Parent = model
	end

	local emitterAnchor = createWorldAlignedAnchor(model, position + Vector3.new(0, 0.18, 0))
	local attachment = Instance.new("Attachment")
	attachment.Parent = emitterAnchor

	local particles = Instance.new("ParticleEmitter")
	particles.Name = "VoidEmbers"
	particles.LightEmission = 0.9
	particles.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, tierConfig.accentColor),
		ColorSequenceKeypoint.new(0.45, Color3.fromRGB(255, 140, 60)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(30, 10, 10)),
	})
	particles.Rate = 18
	particles.Lifetime = NumberRange.new(1.0, 1.8)
	particles.Speed = NumberRange.new(2.5, 5.5)
	particles.SpreadAngle = Vector2.new(30, 30)
	particles.EmissionDirection = Enum.NormalId.Top
	particles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.28),
		NumberSequenceKeypoint.new(0.6, 0.16),
		NumberSequenceKeypoint.new(1, 0),
	})
	particles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(0.7, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	particles.RotSpeed = NumberRange.new(-90, 90)
	particles.Parent = attachment

	local swirl = Instance.new("ParticleEmitter")
	swirl.Name = "VoidSwirl"
	swirl.LightEmission = 0.5
	swirl.Color = ColorSequence.new(Color3.fromRGB(60, 0, 0), Color3.fromRGB(20, 0, 0))
	swirl.Rate = 8
	swirl.Lifetime = NumberRange.new(1.2, 2.0)
	swirl.Speed = NumberRange.new(0.5, 1.5)
	swirl.SpreadAngle = Vector2.new(180, 180)
	swirl.EmissionDirection = Enum.NormalId.Top
	swirl.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	swirl.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	swirl.Parent = attachment

	local light = Instance.new("PointLight")
	light.Name = "VoidLight"
	light.Brightness = 2.5
	light.Color = tierConfig.accentColor
	light.Range = 12
	light.Shadows = false
	light.Parent = voidDisc

	-- Slow brightness wobble so the rift pulses with the cracks instead of
	-- holding a static glow. Slower cadence than Magma so it reads as
	-- something more sinister and patient.
	task.spawn(function()
		while light.Parent do
			TweenService:Create(
				light,
				TweenInfo.new(rng:NextNumber(1.0, 1.6), Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ Brightness = rng:NextNumber(2.8, 3.6) }
			):Play()
			task.wait(rng:NextNumber(1.0, 1.6))
			TweenService:Create(
				light,
				TweenInfo.new(rng:NextNumber(0.9, 1.4), Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ Brightness = rng:NextNumber(1.8, 2.4) }
			):Play()
			task.wait(rng:NextNumber(0.9, 1.4))
		end
	end)
end

-- Celestial tier: smoking meteor crater with an embedded white-cyan star
-- shard. A vertical "starlight" beam fades from solid at the shard up to
-- empty at ~12 studs, sparkles drift around the impact point, and a bright
-- cyan light brightens the whole area. Sub-1% rarity, so the beam is the
-- spotting cue: a player can see it from anywhere on the dig site.
local function buildStarFragmentMarker(model: Model, position: Vector3, tierConfig)
	local crater = Instance.new("Part")
	crater.Name = "StarCrater"
	prepareSpotPart(crater)
	crater.Material = Enum.Material.Slate
	crater.Color = Color3.fromRGB(38, 32, 36)
	crater.Shape = Enum.PartType.Cylinder
	crater.Size = getFlatCylinderSize(3.4, 0.1)
	crater.Transparency = 0.05
	crater.CFrame = flatCylinderCFrame(position + Vector3.new(0, 0.06, 0))
	crater.Parent = model

	-- Charred-edge ring: 8 small dark stones arranged around the crater rim
	-- so it reads as scorched impact debris.
	for index = 1, 8 do
		local angle = (index / 8) * math.pi * 2
		local stone = Instance.new("Part")
		stone.Name = "CraterStone" .. index
		prepareSpotPart(stone)
		stone.Material = Enum.Material.Slate
		stone.Color = Color3.fromRGB(28, 22, 24)
		stone.Size = Vector3.new(rng:NextNumber(0.3, 0.5), rng:NextNumber(0.18, 0.3), rng:NextNumber(0.3, 0.5))
		stone.CFrame = CFrame.new(position + Vector3.new(math.cos(angle) * 1.55, stone.Size.Y * 0.5 + 0.06, math.sin(angle) * 1.55))
			* CFrame.Angles(rng:NextNumber(-0.3, 0.3), rng:NextNumber(0, math.pi), rng:NextNumber(-0.3, 0.3))
		stone.Parent = model
	end

	-- Embedded star shard at a 30° tilt, neon white-cyan with a pulse.
	local shard = Instance.new("Part")
	shard.Name = "StarShard"
	prepareSpotPart(shard)
	shard.Material = Enum.Material.Neon
	shard.Color = tierConfig.accentColor:Lerp(Color3.new(1, 1, 1), 0.4)
	shard.Reflectance = 0.4
	shard.Size = Vector3.new(0.45, 1.6, 0.45)
	shard.Transparency = 0.05
	shard.CFrame = CFrame.new(position + Vector3.new(0, 0.85, 0))
		* CFrame.Angles(math.rad(30), math.rad(rng:NextNumber(0, 360)), math.rad(rng:NextNumber(-15, 15)))
	shard.Parent = model

	local shardPulse = TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	TweenService:Create(shard, shardPulse, { Transparency = 0.35 }):Play()

	-- Vertical starlight beam: 3 stacked cylinders with progressively higher
	-- transparency so the beam reads as fading into the sky rather than
	-- hard-cutting at a fixed height.
	local beamHeights = { 4, 4, 4 }
	local beamTransparency = { 0.55, 0.75, 0.9 }
	local beamWidth = { 0.7, 0.55, 0.4 }
	local cumulativeY = 1.5
	for index = 1, 3 do
		local segment = Instance.new("Part")
		segment.Name = "StarBeam" .. index
		prepareSpotPart(segment)
		segment.Material = Enum.Material.Neon
		segment.Color = tierConfig.accentColor
		segment.Shape = Enum.PartType.Cylinder
		segment.Size = Vector3.new(beamHeights[index], beamWidth[index], beamWidth[index])
		segment.Transparency = beamTransparency[index]
		segment.CFrame = CFrame.new(position + Vector3.new(0, cumulativeY + beamHeights[index] * 0.5, 0))
			* CFrame.Angles(0, 0, math.rad(90))
		segment.Parent = model
		cumulativeY += beamHeights[index]
	end

	-- Sparkles spread 180° so they fan out from the tilted shard freely;
	-- their parent's tilt actually helps sell "stardust falling off the
	-- shard". Anchor on the shard itself.
	local sparkleAttachment = Instance.new("Attachment")
	sparkleAttachment.Parent = shard

	local sparkles = Instance.new("ParticleEmitter")
	sparkles.Name = "StarSparkles"
	sparkles.LightEmission = 1
	sparkles.Color = ColorSequence.new(tierConfig.accentColor, Color3.new(1, 1, 1))
	sparkles.Rate = 12
	sparkles.Lifetime = NumberRange.new(1.2, 2.0)
	sparkles.Speed = NumberRange.new(1.5, 3.0)
	sparkles.SpreadAngle = Vector2.new(180, 180)
	sparkles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.32),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparkles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	sparkles.RotSpeed = NumberRange.new(-90, 90)
	sparkles.Parent = sparkleAttachment

	-- Slow rising swirl that drifts upward along the beam to draw the eye
	-- toward the sky cue. Needs its own world-aligned anchor so the narrow
	-- 8° spread actually points up rather than tilting with the shard.
	local riseAnchor = createWorldAlignedAnchor(model, position + Vector3.new(0, 0.5, 0))
	local riseAttachment = Instance.new("Attachment")
	riseAttachment.Parent = riseAnchor

	local rise = Instance.new("ParticleEmitter")
	rise.Name = "StarRise"
	rise.LightEmission = 0.9
	rise.Color = ColorSequence.new(tierConfig.accentColor:Lerp(Color3.new(1, 1, 1), 0.5), Color3.new(1, 1, 1))
	rise.Rate = 6
	rise.Lifetime = NumberRange.new(2.0, 3.0)
	rise.Speed = NumberRange.new(2.5, 4.0)
	rise.SpreadAngle = Vector2.new(8, 8)
	rise.EmissionDirection = Enum.NormalId.Top
	rise.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(1, 0.05),
	})
	rise.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	rise.Parent = riseAttachment

	local light = Instance.new("PointLight")
	light.Name = "StarGlow"
	light.Brightness = 3
	light.Color = tierConfig.accentColor:Lerp(Color3.new(1, 1, 1), 0.3)
	light.Range = 14
	light.Shadows = false
	light.Parent = shard
end

-- Divine tier: a gold rune circle on the ground with a downpour of holy
-- light pouring from above. The rune ring slowly rotates, gold feathers
-- drift down out of the pillar, and both a PointLight and a SpotLight
-- aimed up keep the spot blindingly visible from anywhere on the lot.
local function buildHeavensMarkMarker(model: Model, position: Vector3, tierConfig)
	-- Outer rune ring: gold neon disc.
	local outerRing = Instance.new("Part")
	outerRing.Name = "RuneOuterRing"
	prepareSpotPart(outerRing)
	outerRing.Material = Enum.Material.Neon
	outerRing.Color = tierConfig.accentColor
	outerRing.Shape = Enum.PartType.Cylinder
	outerRing.Size = getFlatCylinderSize(3.6, 0.05)
	outerRing.Transparency = 0.35
	outerRing.CFrame = flatCylinderCFrame(position + Vector3.new(0, 0.07, 0))
	outerRing.Parent = model

	-- Inner mask disc cuts the outer ring into a hollow ring shape (roughly).
	local innerMask = Instance.new("Part")
	innerMask.Name = "RuneInnerMask"
	prepareSpotPart(innerMask)
	innerMask.Material = Enum.Material.SmoothPlastic
	innerMask.Color = Color3.fromRGB(20, 16, 8)
	innerMask.Shape = Enum.PartType.Cylinder
	innerMask.Size = getFlatCylinderSize(2.6, 0.04)
	innerMask.Transparency = 0.3
	innerMask.CFrame = flatCylinderCFrame(position + Vector3.new(0, 0.085, 0))
	innerMask.Parent = model

	-- Inner sigil cross: two crossed neon strips inside the masked area.
	for index = 1, 2 do
		local strip = Instance.new("Part")
		strip.Name = "RuneStrip" .. index
		prepareSpotPart(strip)
		strip.Material = Enum.Material.Neon
		strip.Color = tierConfig.accentColor:Lerp(Color3.new(1, 1, 1), 0.25)
		strip.Size = Vector3.new(2.2, 0.04, 0.18)
		strip.Transparency = 0.2
		strip.CFrame = CFrame.new(position + Vector3.new(0, 0.11, 0))
			* CFrame.Angles(0, math.rad(index * 45), 0)
		strip.Parent = model
	end

	-- Four glyph slits sitting on the outer ring. Held by a hidden rotator
	-- part whose CFrame ticks every frame to rotate the glyphs around the
	-- circle. Because Anchored parts don't follow welds, we update glyph
	-- CFrames directly each tick instead.
	local glyphs = {}
	for index = 1, 4 do
		local glyph = Instance.new("Part")
		glyph.Name = "RuneGlyph" .. index
		prepareSpotPart(glyph)
		glyph.Material = Enum.Material.SmoothPlastic
		glyph.Color = Color3.fromRGB(20, 16, 8)
		glyph.Size = Vector3.new(0.45, 0.08, 0.18)
		glyph.Parent = model
		glyphs[index] = glyph
	end

	task.spawn(function()
		local startTime = os.clock()
		while glyphs[1] and glyphs[1].Parent do
			local elapsed = os.clock() - startTime
			for index, glyph in glyphs do
				local angle = (index / #glyphs) * math.pi * 2 + elapsed * 0.4
				glyph.CFrame = CFrame.new(position + Vector3.new(math.cos(angle) * 1.65, 0.11, math.sin(angle) * 1.65))
					* CFrame.Angles(0, angle + math.pi * 0.5, 0)
			end
			task.wait(1 / 30)
		end
	end)

	-- Gold light pillar pouring from above. 4 stacked cylinders going up
	-- with progressive transparency so the pillar fades into the sky.
	local pillarHeights = { 6, 6, 6, 6 }
	local pillarTransparency = { 0.55, 0.7, 0.82, 0.92 }
	local pillarWidth = { 2.4, 2.0, 1.5, 1.0 }
	local pillarY = 0.5
	for index = 1, 4 do
		local segment = Instance.new("Part")
		segment.Name = "HeavenPillar" .. index
		prepareSpotPart(segment)
		segment.Material = Enum.Material.Neon
		segment.Color = tierConfig.accentColor
		segment.Shape = Enum.PartType.Cylinder
		segment.Size = Vector3.new(pillarHeights[index], pillarWidth[index], pillarWidth[index])
		segment.Transparency = pillarTransparency[index]
		segment.CFrame = CFrame.new(position + Vector3.new(0, pillarY + pillarHeights[index] * 0.5, 0))
			* CFrame.Angles(0, 0, math.rad(90))
		segment.Parent = model
		pillarY += pillarHeights[index]
	end

	-- World-aligned anchor at the top of the pillar. Required because
	-- outerRing is rotated by flatCylinderCFrame, which would skew the
	-- attachment's local axes and send the falling feathers sideways.
	local featherAnchor = createWorldAlignedAnchor(model, position + Vector3.new(0, 22, 0))
	local attachment = Instance.new("Attachment")
	attachment.Parent = featherAnchor

	-- Falling feather/dust particles dripping out of the pillar.
	local feathers = Instance.new("ParticleEmitter")
	feathers.Name = "HolyFeathers"
	feathers.LightEmission = 0.7
	feathers.Color = ColorSequence.new(tierConfig.accentColor, Color3.new(1, 1, 1))
	feathers.Rate = 10
	feathers.Lifetime = NumberRange.new(3.0, 4.5)
	feathers.Speed = NumberRange.new(1.0, 2.0)
	feathers.SpreadAngle = Vector2.new(20, 20)
	feathers.EmissionDirection = Enum.NormalId.Bottom
	feathers.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(1, 0.1),
	})
	feathers.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	feathers.Acceleration = Vector3.new(0, -0.5, 0)
	feathers.RotSpeed = NumberRange.new(-30, 30)
	feathers.Parent = attachment

	-- Ground-level sparkle attachment placed via a world-aligned anchor so
	-- the omnidirectional sparkle spread reads consistently with gravity.
	local sparkleAnchor = createWorldAlignedAnchor(model, position + Vector3.new(0, 0.25, 0))
	local groundAttach = Instance.new("Attachment")
	groundAttach.Parent = sparkleAnchor

	local groundSparkles = Instance.new("ParticleEmitter")
	groundSparkles.Name = "RuneSparkles"
	groundSparkles.LightEmission = 1
	groundSparkles.Color = ColorSequence.new(tierConfig.accentColor, Color3.new(1, 1, 1))
	groundSparkles.Rate = 8
	groundSparkles.Lifetime = NumberRange.new(0.8, 1.4)
	groundSparkles.Speed = NumberRange.new(0.5, 1.2)
	groundSparkles.SpreadAngle = Vector2.new(180, 180)
	groundSparkles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 0),
	})
	groundSparkles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	groundSparkles.Parent = groundAttach

	local pointLight = Instance.new("PointLight")
	pointLight.Name = "HeavenGlow"
	pointLight.Brightness = 3.5
	pointLight.Color = tierConfig.accentColor
	pointLight.Range = 16
	pointLight.Shadows = false
	pointLight.Parent = outerRing

	-- SpotLight aimed straight up so the pillar has a real-light backbone
	-- in addition to the neon parts.
	local spotLight = Instance.new("SpotLight")
	spotLight.Name = "HeavenSpot"
	spotLight.Brightness = 4
	spotLight.Color = tierConfig.accentColor
	spotLight.Range = 30
	spotLight.Angle = 30
	spotLight.Face = Enum.NormalId.Top
	spotLight.Shadows = false
	spotLight.Parent = outerRing

	-- Soft pulse on the outer ring so the rune visibly "breathes" rather
	-- than holding a steady glow.
	local ringPulse = TweenInfo.new(2.0, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	TweenService:Create(outerRing, ringPulse, { Transparency = 0.55 }):Play()
end

-- Eldritch tier: a dark eye-shaped recess in the ground stares up. The iris
-- color-cycles through cosmic horror hues, four glyphs orbit at a low
-- altitude, and dark tentacle-wisp particles rise from the eye. Animated
-- highlight (handled by tier config) makes the outline shift colors with
-- the iris so the whole thing reads as alive and unwell.
local function buildCosmicEyeMarker(model: Model, position: Vector3, tierConfig)
	-- Sclera: large flat black disc.
	local sclera = Instance.new("Part")
	sclera.Name = "EyeSclera"
	prepareSpotPart(sclera)
	sclera.Material = Enum.Material.SmoothPlastic
	sclera.Color = Color3.fromRGB(10, 8, 14)
	sclera.Shape = Enum.PartType.Cylinder
	sclera.Size = getFlatCylinderSize(3.5, 0.1)
	sclera.Transparency = 0.05
	sclera.CFrame = flatCylinderCFrame(position + Vector3.new(0, 0.08, 0))
	sclera.Parent = model

	-- Iris: glowing inner cylinder, tweens through cyan/green/magenta.
	local iris = Instance.new("Part")
	iris.Name = "EyeIris"
	prepareSpotPart(iris)
	iris.Material = Enum.Material.Neon
	iris.Color = tierConfig.accentColor
	iris.Shape = Enum.PartType.Cylinder
	iris.Size = getFlatCylinderSize(1.6, 0.08)
	iris.Transparency = 0.1
	iris.CFrame = flatCylinderCFrame(position + Vector3.new(0, 0.13, 0))
	iris.Parent = model

	-- Pupil: tiny dark cylinder dead center.
	local pupil = Instance.new("Part")
	pupil.Name = "EyePupil"
	prepareSpotPart(pupil)
	pupil.Material = Enum.Material.SmoothPlastic
	pupil.Color = Color3.fromRGB(4, 2, 6)
	pupil.Shape = Enum.PartType.Cylinder
	pupil.Size = getFlatCylinderSize(0.55, 0.06)
	pupil.Transparency = 0.05
	pupil.CFrame = flatCylinderCFrame(position + Vector3.new(0, 0.18, 0))
	pupil.Parent = model

	-- Iris color cycle: tween Color through the eldritch palette and have
	-- the PointLight + reflectance subtly track the same hue.
	local irisLight = Instance.new("PointLight")
	irisLight.Name = "EyeGlow"
	irisLight.Brightness = 3
	irisLight.Color = tierConfig.accentColor
	irisLight.Range = 14
	irisLight.Shadows = false
	irisLight.Parent = iris

	local irisPalette = {
		Color3.fromRGB(120, 220, 200),
		Color3.fromRGB(140, 255, 140),
		Color3.fromRGB(220, 140, 255),
		Color3.fromRGB(120, 200, 255),
	}
	task.spawn(function()
		local index = 0
		while iris.Parent do
			index = (index % #irisPalette) + 1
			local target = irisPalette[index]
			local info = TweenInfo.new(1.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
			TweenService:Create(iris, info, { Color = target }):Play()
			TweenService:Create(irisLight, info, { Color = target }):Play()
			task.wait(1.5)
		end
	end)

	-- Four floating glyph parts orbiting the eye at low altitude.
	local glyphs = {}
	for index = 1, 4 do
		local glyph = Instance.new("Part")
		glyph.Name = "EyeGlyph" .. index
		prepareSpotPart(glyph)
		glyph.Material = Enum.Material.Neon
		glyph.Color = tierConfig.accentColor:Lerp(Color3.new(1, 1, 1), 0.3)
		glyph.Size = Vector3.new(0.32, 0.5, 0.05)
		glyph.Transparency = 0.25
		glyph.Parent = model
		glyphs[index] = glyph
	end

	task.spawn(function()
		local startTime = os.clock()
		while glyphs[1] and glyphs[1].Parent do
			local elapsed = os.clock() - startTime
			for index, glyph in glyphs do
				local angle = (index / #glyphs) * math.pi * 2 + elapsed * 0.6
				local altitude = 1.6 + math.sin(elapsed * 1.2 + index) * 0.25
				glyph.CFrame = CFrame.new(position + Vector3.new(math.cos(angle) * 1.4, altitude, math.sin(angle) * 1.4))
					* CFrame.Angles(0, angle + math.pi * 0.5, math.rad(20))
			end
			task.wait(1 / 30)
		end
	end)

	-- World-aligned anchor; iris is flatCylinderCFrame'd so its local axes
	-- don't match world up.
	local tentacleAnchor = createWorldAlignedAnchor(model, position + Vector3.new(0, 0.25, 0))
	local attachment = Instance.new("Attachment")
	attachment.Parent = tentacleAnchor

	-- Dark tentacle wisps rising and curling outward.
	local tentacles = Instance.new("ParticleEmitter")
	tentacles.Name = "EyeTentacles"
	tentacles.LightEmission = 0.4
	tentacles.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(40, 20, 60)),
		ColorSequenceKeypoint.new(0.5, tierConfig.accentColor),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(20, 10, 40)),
	})
	tentacles.Rate = 12
	tentacles.Lifetime = NumberRange.new(2.0, 3.5)
	tentacles.Speed = NumberRange.new(2.0, 4.0)
	tentacles.SpreadAngle = Vector2.new(40, 40)
	tentacles.EmissionDirection = Enum.NormalId.Top
	tentacles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(0.5, 0.9),
		NumberSequenceKeypoint.new(1, 0.2),
	})
	tentacles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(0.5, 0.6),
		NumberSequenceKeypoint.new(1, 1),
	})
	tentacles.RotSpeed = NumberRange.new(-180, 180)
	tentacles.Acceleration = Vector3.new(0, -1, 0)
	tentacles.Parent = attachment
end

-- Cosmic tier: a spiral galaxy spins in the ground, six stars orbit the
-- center, a tall rainbow particle column streams skyward, and concentric
-- shockwave rings pulse outward every few seconds. The Highlight is
-- driven through the rainbow palette by tier config (animatedHighlight),
-- and the PointLight color tween follows the same palette so the entire
-- spot reads as a slowly rotating multicolor beacon.
local function buildGalaxyWhirlMarker(model: Model, position: Vector3, tierConfig)
	-- Three stacked thin neon discs at slightly different rotations to fake
	-- a spiral galaxy when they overlap.
	local discParts = {}
	for index = 1, 3 do
		local disc = Instance.new("Part")
		disc.Name = "GalaxyDisc" .. index
		prepareSpotPart(disc)
		disc.Material = Enum.Material.Neon
		disc.Color = tierConfig.accentColor
		disc.Shape = Enum.PartType.Cylinder
		disc.Size = getFlatCylinderSize(4.2 - (index - 1) * 0.4, 0.05)
		disc.Transparency = 0.3 + (index - 1) * 0.1
		disc.CFrame = flatCylinderCFrame(position + Vector3.new(0, 0.06 + (index - 1) * 0.04, 0))
		disc.Parent = model
		discParts[index] = disc
	end

	-- Center "black hole" mask cylinder.
	local core = Instance.new("Part")
	core.Name = "GalaxyCore"
	prepareSpotPart(core)
	core.Material = Enum.Material.SmoothPlastic
	core.Color = Color3.fromRGB(6, 4, 12)
	core.Shape = Enum.PartType.Cylinder
	core.Size = getFlatCylinderSize(0.8, 0.06)
	core.Transparency = 0.05
	core.CFrame = flatCylinderCFrame(position + Vector3.new(0, 0.2, 0))
	core.Parent = model

	-- Six small "stars" orbiting the center at varied radii and altitudes.
	local stars = {}
	local starRadii = { 1.4, 1.4, 1.6, 1.6, 1.8, 1.8 }
	local starAltitudes = { 0.18, 0.6, 0.18, 0.6, 0.18, 0.6 }
	for index = 1, 6 do
		local star = Instance.new("Part")
		star.Name = "GalaxyStar" .. index
		prepareSpotPart(star)
		star.Material = Enum.Material.Neon
		star.Color = tierConfig.accentColor:Lerp(Color3.new(1, 1, 1), 0.5)
		star.Shape = Enum.PartType.Ball
		star.Size = Vector3.new(0.32, 0.32, 0.32)
		star.Transparency = 0.1
		star.Parent = model
		stars[index] = { part = star, radius = starRadii[index], altitude = starAltitudes[index] }
	end

	task.spawn(function()
		local startTime = os.clock()
		while stars[1] and stars[1].part.Parent do
			local elapsed = os.clock() - startTime
			for index, entry in stars do
				local angle = (index / #stars) * math.pi * 2 + elapsed * 0.8
				entry.part.CFrame = CFrame.new(position + Vector3.new(
					math.cos(angle) * entry.radius,
					entry.altitude,
					math.sin(angle) * entry.radius
				))
			end
			task.wait(1 / 30)
		end
	end)

	-- Slow disc rotations so the spiral looks like it's churning. Each disc
	-- spins at a slightly different rate.
	task.spawn(function()
		local startTime = os.clock()
		local speeds = { 0.25, -0.35, 0.5 }
		while discParts[1] and discParts[1].Parent do
			local elapsed = os.clock() - startTime
			for index, disc in discParts do
				local angle = elapsed * speeds[index]
				disc.CFrame = CFrame.new(position + Vector3.new(0, 0.06 + (index - 1) * 0.04, 0))
					* CFrame.Angles(0, angle, 0)
					* FLAT_CYLINDER_CFRAME
			end
			task.wait(1 / 30)
		end
	end)

	-- World-aligned anchor for the column emitter. core is flat-cylinder
	-- rotated so attaching here directly would shoot the rainbow column
	-- sideways instead of up the spire.
	local columnAnchor = createWorldAlignedAnchor(model, position + Vector3.new(0, 0.3, 0))
	local attachment = Instance.new("Attachment")
	attachment.Parent = columnAnchor

	-- Tall rainbow particle column streaming upward.
	local column = Instance.new("ParticleEmitter")
	column.Name = "GalaxyColumn"
	column.LightEmission = 1
	column.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 120, 255)),
		ColorSequenceKeypoint.new(0.25, Color3.fromRGB(120, 200, 255)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(120, 255, 180)),
		ColorSequenceKeypoint.new(0.75, Color3.fromRGB(255, 230, 120)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 130, 200)),
	})
	column.Rate = 30
	column.Lifetime = NumberRange.new(2.5, 4.0)
	column.Speed = NumberRange.new(4.0, 7.0)
	column.SpreadAngle = Vector2.new(15, 15)
	column.EmissionDirection = Enum.NormalId.Top
	column.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(0.5, 0.7),
		NumberSequenceKeypoint.new(1, 0),
	})
	column.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	column.RotSpeed = NumberRange.new(-180, 180)
	column.Parent = attachment

	-- Dust-ring particles that drift outward at ground level so the spiral
	-- feels surrounded by accreting material.
	local dust = Instance.new("ParticleEmitter")
	dust.Name = "GalaxyDust"
	dust.LightEmission = 0.7
	dust.Color = ColorSequence.new(Color3.fromRGB(180, 140, 255), Color3.fromRGB(255, 200, 255))
	dust.Rate = 16
	dust.Lifetime = NumberRange.new(1.5, 2.5)
	dust.Speed = NumberRange.new(2.0, 3.5)
	dust.SpreadAngle = Vector2.new(180, 180)
	dust.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(1, 0),
	})
	dust.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	dust.Parent = attachment

	local pointLight = Instance.new("PointLight")
	pointLight.Name = "GalaxyGlow"
	pointLight.Brightness = 4
	pointLight.Color = tierConfig.accentColor
	pointLight.Range = 22
	pointLight.Shadows = false
	pointLight.Parent = core

	local spotLight = Instance.new("SpotLight")
	spotLight.Name = "GalaxySpot"
	spotLight.Brightness = 5
	spotLight.Color = tierConfig.accentColor
	spotLight.Range = 50
	spotLight.Angle = 25
	spotLight.Face = Enum.NormalId.Top
	spotLight.Shadows = false
	spotLight.Parent = core

	-- Color cycle the central PointLight to mirror the rainbow column.
	local lightPalette = {
		Color3.fromRGB(255, 120, 255),
		Color3.fromRGB(120, 200, 255),
		Color3.fromRGB(120, 255, 180),
		Color3.fromRGB(255, 230, 120),
		Color3.fromRGB(255, 130, 200),
	}
	task.spawn(function()
		local index = 0
		while pointLight.Parent do
			index = (index % #lightPalette) + 1
			local target = lightPalette[index]
			local info = TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
			TweenService:Create(pointLight, info, { Color = target }):Play()
			TweenService:Create(spotLight, info, { Color = target }):Play()
			task.wait(1.1)
		end
	end)

	-- Periodic shockwave rings: spawn a flat neon disc that rapidly scales
	-- outward and fades. Spawn cadence ~2.5s so the player gets a regular
	-- visual heartbeat from across the map.
	task.spawn(function()
		while model.Parent do
			task.wait(2.5)
			if not model.Parent then
				break
			end
			local ring = Instance.new("Part")
			ring.Name = "GalaxyShockwave"
			prepareSpotPart(ring)
			ring.Material = Enum.Material.Neon
			ring.Color = lightPalette[rng:NextInteger(1, #lightPalette)]
			ring.Shape = Enum.PartType.Cylinder
			ring.Size = getFlatCylinderSize(1.0, 0.06)
			ring.Transparency = 0.1
			ring.CFrame = flatCylinderCFrame(position + Vector3.new(0, 0.18, 0))
			ring.Parent = model

			local growInfo = TweenInfo.new(2.0, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			TweenService:Create(ring, growInfo, {
				Size = getFlatCylinderSize(10, 0.06),
				Transparency = 1,
			}):Play()
			task.delay(2.05, function()
				if ring then
					ring:Destroy()
				end
			end)
		end
	end)
end

local function createGroundSpotMarker(position: Vector3, tierName: string, tierConfig)
	if not spotsFolder then
		return nil
	end

	local model = Instance.new("Model")
	model.Name = DigSiteConfig.GROUND_SPOT_MARKER_NAME
	model:SetAttribute(DigSiteConfig.GROUND_SPOT_TIER_ATTRIBUTE, tierName)
	model:SetAttribute(DigSiteConfig.GROUND_SPOT_LUCK_ATTRIBUTE, tierConfig.luckMultiplier)
	model:SetAttribute(DigSiteConfig.GROUND_SPOT_POSITION_ATTRIBUTE, position)

	if tierConfig.style == "GalaxyWhirl" then
		buildGalaxyWhirlMarker(model, position, tierConfig)
	elseif tierConfig.style == "CosmicEye" then
		buildCosmicEyeMarker(model, position, tierConfig)
	elseif tierConfig.style == "HeavensMark" then
		buildHeavensMarkMarker(model, position, tierConfig)
	elseif tierConfig.style == "StarFragment" then
		buildStarFragmentMarker(model, position, tierConfig)
	elseif tierConfig.style == "VoidRift" then
		buildVoidRiftMarker(model, position, tierConfig)
	elseif tierConfig.style == "MagmaVent" then
		buildMagmaVentMarker(model, position, tierConfig)
	elseif tierConfig.style == "CrystalGeode" then
		buildCrystalGeodeMarker(model, position, tierConfig)
	elseif tierConfig.style == "GemShard" then
		buildGemShardMarker(model, position, tierConfig)
	elseif tierConfig.style == "MossPatch" then
		buildMossPatchMarker(model, position, tierConfig)
	else
		local patch = buildMoundMarker(model, position)
		decorateAsCommonSpot(patch, tierConfig)
	end

	-- Every tier gets a Highlight so spots stay readable even when the
	-- player is far enough away that the per-tier glow falls off, and the
	-- top tiers (AlwaysOnTop in their tier config) punch through walls so
	-- the whole server can locate a Cosmic spawn.
	applyHighlight(model, tierConfig)

	local timerLabel = buildSpotBillboard(position, tierName, tierConfig, model)

	model.Parent = spotsFolder
	return model, timerLabel
end

local function destroyGroundSpot(spot)
	if spot.marker and spot.marker.Parent then
		spot.marker:Destroy()
	end

	for index, candidate in activeSpots do
		if candidate == spot then
			table.remove(activeSpots, index)
			break
		end
	end
end

local function destroyDugSpot(dugSpot)
	if dugSpot.marker and dugSpot.marker.Parent then
		dugSpot.marker:Destroy()
	end

	for index, candidate in dugSpots do
		if candidate == dugSpot then
			table.remove(dugSpots, index)
			break
		end
	end
end

function isPositionDug(position: Vector3)
	local now = os.clock()
	for index = #dugSpots, 1, -1 do
		local dugSpot = dugSpots[index]
		if now >= dugSpot.expiresAt then
			-- Expired: prune lazily so the position is no longer treated as
			-- blocked. A periodic sweep also clears these but checking here
			-- guarantees freshness whenever a dig validation runs.
			destroyDugSpot(dugSpot)
		elseif getHorizontalDistance(position, dugSpot.position) <= DigSiteConfig.DUG_SPOT_BLOCK_RADIUS then
			return true
		end
	end

	return false
end

-- Persistent dug-spot marker built from the same DigHoleBuilder used by
-- the during-dig client visuals, so the moment the brainrot pops out
-- of the ground the player's local hole is replaced by a server-replicated
-- pit of identical shape (no visible pop). The size scales with the
-- session's extraHits using the exact same soft-saturating curve as the
-- client's per-hit growth, so a deeply-risked dig commits to a larger
-- persistent crater than a quick three-hit dig.
local function createDugSpotMarker(position: Vector3, extraHits: number?)
	if not dugSpotFolder then
		return nil
	end

	local holeTunables = DigSiteConfig.DUG_HOLE
	local safeExtra = math.max(0, extraHits or 0)
	local extraGrowth = safeExtra / (safeExtra + holeTunables.EXTRA_GROWTH_SATURATION)
	local radius = DigSiteConfig.DUG_SPOT_MARKER_SIZE * 0.5 + extraGrowth * holeTunables.EXTRA_GROWTH_MAX_RADIUS
	local depth = holeTunables.MAX_DEPTH_VISUAL + extraGrowth * holeTunables.EXTRA_GROWTH_MAX_DEPTH
	local rimChunkCount = holeTunables.RIM_CHUNK_COUNT + math.floor(extraGrowth * holeTunables.EXTRA_GROWTH_MAX_RIM_BONUS)
	local bedStoneCount = holeTunables.BED_STONE_COUNT + math.floor(extraGrowth * holeTunables.EXTRA_GROWTH_MAX_STONE_BONUS)

	local model = DigHoleBuilder.create({
		position = position,
		radius = radius,
		depth = depth,
		parent = dugSpotFolder,
		rng = rng,
		includeDust = false,
		rimChunkCount = rimChunkCount,
		wallSegmentCount = holeTunables.WALL_SEGMENT_COUNT,
		innerLayerCount = holeTunables.INNER_LAYER_COUNT,
		bedStoneCount = bedStoneCount,
	})
	model.Name = DigSiteConfig.DUG_SPOT_MARKER_NAME

	DigHoleBuilder.addRimDebris(model, position, radius, holeTunables.PERSISTENT_EXTRA_RIM_DEBRIS, rng)

	return model
end

local function findGroundSpotForPosition(position: Vector3)
	local now = os.clock()
	local nearest = nil
	local nearestLuck = 1

	-- Pick the highest-luck spot the dig position falls inside. Lets the player
	-- benefit from whichever tier they actually landed on rather than whichever
	-- spot we happen to iterate over first.
	for index = #activeSpots, 1, -1 do
		local spot = activeSpots[index]

		if now >= spot.expiresAt then
			destroyGroundSpot(spot)
		elseif getHorizontalDistance(position, spot.position) <= DigSiteConfig.GROUND_SPOT_RADIUS then
			if spot.luckMultiplier > nearestLuck then
				nearest = spot
				nearestLuck = spot.luckMultiplier
			end
		end
	end

	return nearest
end

local function trySpawnSpot()
	if not digArea or not spotsFolder then
		return
	end

	if #activeSpots >= DigSiteConfig.GROUND_SPOT_MAX_ACTIVE then
		return
	end

	local position = pickSpotPosition()
	if not position then
		return
	end

	local tierName, tierConfig = rollTier()
	local marker, spotTimerLabel = createGroundSpotMarker(position, tierName, tierConfig)
	if not marker then
		return
	end

	local expiresAt = os.clock() + DigSiteConfig.GROUND_SPOT_LIFETIME
	local spot = {
		position = position,
		tierName = tierName,
		luckMultiplier = tierConfig.luckMultiplier,
		expiresAt = expiresAt,
		marker = marker,
	}

	table.insert(activeSpots, spot)
	lastSpotPosition = position

	task.delay(DigSiteConfig.GROUND_SPOT_LIFETIME + 0.05, function()
		destroyGroundSpot(spot)
	end)

	if spotTimerLabel then
		task.spawn(function()
			while spotTimerLabel.Parent do
				local secondsLeft = math.ceil(expiresAt - os.clock())
				if secondsLeft <= 0 then
					break
				end
				spotTimerLabel.Text = ("%ds"):format(secondsLeft)
				task.wait(1)
			end
		end)
	end
end

local function expireSpots(now: number)
	for index = #activeSpots, 1, -1 do
		if now >= activeSpots[index].expiresAt then
			destroyGroundSpot(activeSpots[index])
		end
	end
end

local function isPositionInDigArea(position: Vector3)
	if not digArea then
		return false
	end

	return isPointOnFloor(position, digArea.floor)
end

local function expireDugSpots(now: number)
	for index = #dugSpots, 1, -1 do
		if now >= dugSpots[index].expiresAt then
			destroyDugSpot(dugSpots[index])
		end
	end
end

function DigSiteService.markDug(position: Vector3, extraHits: number?)
	if not digArea then
		refreshDigArea()
	end

	if not digArea or not isPositionInDigArea(position) or isPositionDug(position) then
		return false
	end

	-- If the dig consumed a ground spot, despawn it immediately so the pool
	-- refills with a fresh one rather than leaving the now-redundant marker.
	for index = #activeSpots, 1, -1 do
		local spot = activeSpots[index]
		if getHorizontalDistance(position, spot.position) <= DigSiteConfig.GROUND_SPOT_RADIUS then
			destroyGroundSpot(spot)
		end
	end

	table.insert(dugSpots, {
		position = position,
		marker = createDugSpotMarker(position, extraHits),
		expiresAt = os.clock() + DigSiteConfig.DUG_SPOT_LIFETIME,
	})
	return true
end

function DigSiteService.getDigContext(player: Player, position: Vector3)
	if not digArea then
		refreshDigArea()
	end

	if not isPositionInDigArea(position) then
		return nil, "Dig at the DigSite!"
	end

	if isPositionDug(position) then
		return nil, "Already dug here!"
	end

	-- Spots are an opt-in luck buff, not a gate. Digging anywhere in the
	-- DigSite is allowed; landing on a glowing patch just stacks its
	-- tier multiplier on top of the player's baseline luck. (We tried
	-- gating on spots in an earlier pass — players found it frustrating
	-- when no good spot was up, and the loop felt better with free dig.)
	local groundSpot = findGroundSpotForPosition(position)
	local groundSpotLuckMultiplier = if groundSpot then groundSpot.luckMultiplier else 1
	local groundSpotTierName = if groundSpot then groundSpot.tierName else nil

	local data = PlayerDataService.getData(player)
	local rebirthLuckMultiplier = EconomyConfig.getLuckMultiplier(data.rebirths)
	local weatherLuckMultiplier = WeatherService.getLuckMultiplier()

	local friendCount = 0
	for _, otherPlayer in Players:GetPlayers() do
		if otherPlayer ~= player then
			local ok, isFriend = pcall(function()
				return player:IsFriendsWith(otherPlayer.UserId)
			end)
			if ok and isFriend then
				friendCount += 1
			end
		end
	end
	local friendLuckMultiplier = 1 + friendCount * DigConfig.FRIEND_LUCK_PER_FRIEND

	-- Pure multiplicative stacking: rebirth, ground spot, weather, and friends
	-- all multiply in. Weather is uncapped on purpose so rare alignments feel
	-- like a windfall. Friends reward cooperative play in a shared server.
	local luckMultiplier = rebirthLuckMultiplier * groundSpotLuckMultiplier * weatherLuckMultiplier * friendLuckMultiplier

	return {
		isHotspot = groundSpotLuckMultiplier > 1,
		hotspotTier = groundSpotTierName,
		luckMultiplier = luckMultiplier,
		rebirthLuckMultiplier = rebirthLuckMultiplier,
		hotspotLuckMultiplier = groundSpotLuckMultiplier,
		groundSpotLuckMultiplier = groundSpotLuckMultiplier,
		weatherLuckMultiplier = weatherLuckMultiplier,
		friendLuckMultiplier = friendLuckMultiplier,
		friendCount = friendCount,
	}
end

function DigSiteService.start()
	if started then
		return
	end
	started = true

	refreshDigArea()

	task.spawn(function()
		task.wait(2)
		while started do
			expireSpots(os.clock())
			trySpawnSpot()
			task.wait(DigSiteConfig.GROUND_SPOT_SPAWN_INTERVAL)
		end
	end)

	task.spawn(function()
		while started do
			task.wait(DigSiteConfig.DUG_SPOT_CLEANUP_INTERVAL)
			expireDugSpots(os.clock())
		end
	end)
end

return DigSiteService
