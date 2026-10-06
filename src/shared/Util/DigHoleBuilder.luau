local TweenService = game:GetService("TweenService")

-- Builds a layered "recessed pit" illusion that visibly reads as a hole
-- in the ground rather than a flat sticker. The dig surface is an opaque
-- BasePart (terrain can't be carved into it), so the illusion is composed
-- entirely of above-floor geometry working together:
--   1. A lumpy rim of displaced dirt clumps that visually raises the
--      surrounding ground (making the center read as "lower").
--   2. Sloped wall segments tilted inward like the inside of a moat -
--      the eye reads these as pit walls descending into the earth.
--   3. A stack of progressively smaller, darker discs ending in a
--      near-black "void" disc that fakes ambient-occlusion depth.
--   4. A few embedded bed stones for texture at the bottom.
--   5. Optional dust emitter for fresh holes that are still settling.
--
-- The same builder runs on the client (during-dig hole) and the server
-- (persistent dug spot) so the two never visually disagree.
local DigHoleBuilder = {}

DigHoleBuilder.DIRT_COLOR = Color3.fromRGB(116, 83, 54)
DigHoleBuilder.DIRT_DARK = Color3.fromRGB(72, 54, 42)
DigHoleBuilder.PIT_VOID_COLOR = Color3.fromRGB(8, 5, 3)
DigHoleBuilder.STONE_COLOR_BASE = Color3.fromRGB(82, 76, 68)
DigHoleBuilder.STONE_COLOR_LIGHT = Color3.fromRGB(118, 108, 96)

local FLAT_CYLINDER_CFRAME = CFrame.Angles(0, 0, math.rad(90))

local DEFAULT_RIM_CHUNK_COUNT = 12
local DEFAULT_WALL_SEGMENT_COUNT = 7
local DEFAULT_INNER_LAYER_COUNT = 4
local DEFAULT_BED_STONE_COUNT = 3

local PIT_LAYERS_FOLDER_NAME = "PitLayers"
local WALLS_FOLDER_NAME = "Walls"
local RIM_FOLDER_NAME = "Rim"
local STONES_FOLDER_NAME = "Stones"
local PIT_CENTER_NAME = "PitCenter"
local DUST_ANCHOR_NAME = "DustAnchor"

local RIM_CHUNK_COUNT_ATTR = "RimChunkCount"
local STONE_COUNT_ATTR = "StoneCount"
local RADIUS_ATTR = "HoleRadius"
local DEPTH_ATTR = "HoleDepth"
local POSITION_ATTR = "HolePosition"
local WALL_ANGLE_ATTR = "WallAngle"
local LAYER_INDEX_ATTR = "LayerIndex"

export type Spec = {
	radius: number,
	depth: number,
	position: Vector3,
	parent: Instance,
	rng: Random?,
	includeDust: boolean?,
	rimChunkCount: number?,
	wallSegmentCount: number?,
	innerLayerCount: number?,
	bedStoneCount: number?,
}

local function getRng(rng: Random?): Random
	return rng or Random.new()
end

local function getFlatCylinderSize(diameter: number, height: number): Vector3
	return Vector3.new(height, diameter, diameter)
end

local function flatCylinderCFrame(position: Vector3): CFrame
	return CFrame.new(position) * FLAT_CYLINDER_CFRAME
end

local function prepareSpotPart(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
end

local function tweenOrSet(instance: Instance, duration: number, goals: { [string]: any })
	if duration <= 0 then
		for property, value in goals do
			(instance :: any)[property] = value
		end
		return
	end

	local info = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(instance, info, goals):Play()
end

local function ensureFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function newAnchoredPart(name: string): Part
	local part = Instance.new("Part")
	part.Name = name
	prepareSpotPart(part)
	return part
end

-- Pit layers stack from the rim inward, each one smaller in diameter and
-- darker than the last. Each layer sits slightly higher than the previous
-- so deeper (darker) layers render on top when viewed from above, faking
-- an ambient-occlusion gradient down into the pit.
local function buildOrUpdatePitLayer(model: Model, position: Vector3, radius: number, depth: number, layerIndex: number, layerCount: number, tweenDuration: number)
	local layersFolder = ensureFolder(model, PIT_LAYERS_FOLDER_NAME)
	local name = ("PitLayer%d"):format(layerIndex)
	local part = layersFolder:FindFirstChild(name) :: Part?

	local t = layerIndex / layerCount
	local layerDiameter = math.max(0.2, radius * 2 * (1 - t * 0.65))
	local layerY = 0.05 + t * 0.05
	local color = DigHoleBuilder.DIRT_COLOR:Lerp(DigHoleBuilder.PIT_VOID_COLOR, math.clamp(t * 0.95 + depth * 0.05, 0, 1))
	local material = if t > 0.6 then Enum.Material.SmoothPlastic else Enum.Material.Ground
	local targetSize = getFlatCylinderSize(layerDiameter, 0.08)
	local targetCFrame = flatCylinderCFrame(position + Vector3.new(0, layerY, 0))

	if not part then
		local created = newAnchoredPart(name)
		created:SetAttribute(LAYER_INDEX_ATTR, layerIndex)
		created.Shape = Enum.PartType.Cylinder
		created.Material = material
		created.Color = color
		created.Size = targetSize
		created.CFrame = targetCFrame
		created.Parent = layersFolder
		return
	end

	part.Material = material
	tweenOrSet(part, tweenDuration, {
		Size = targetSize,
		CFrame = targetCFrame,
		Color = color,
	})
end

-- The pitch-black "void" disc the eye reads as the bottom of the pit.
-- Sized as a fraction of the hole radius so it grows with the pit but
-- always stays a clear dark center against the surrounding layers.
local function buildOrUpdatePitCenter(model: Model, position: Vector3, radius: number, depth: number, tweenDuration: number)
	local part = model:FindFirstChild(PIT_CENTER_NAME) :: Part?
	local centerDiameter = math.max(0.25, radius * 0.85)
	local centerY = 0.18 + depth * 0.04
	local targetSize = getFlatCylinderSize(centerDiameter, 0.08)
	local targetCFrame = flatCylinderCFrame(position + Vector3.new(0, centerY, 0))

	if not part then
		local created = newAnchoredPart(PIT_CENTER_NAME)
		created.Shape = Enum.PartType.Cylinder
		created.Material = Enum.Material.SmoothPlastic
		created.Color = DigHoleBuilder.PIT_VOID_COLOR
		created.Transparency = 0.05
		created.Size = targetSize
		created.CFrame = targetCFrame
		created.Parent = model
		return
	end

	tweenOrSet(part, tweenDuration, {
		Size = targetSize,
		CFrame = targetCFrame,
	})
end

-- Walls are short, broad earthen ramps nested just inside the rim. They
-- MUST stay shorter than the surrounding rim chunks so they read as the
-- inner slope of the pit, not as teeth poking up out of it. Two key
-- constraints prevent the "fangs converging at the center" failure mode:
--   1. wallHeight is capped at ~0.4 studs regardless of pit radius, so
--      large pits don't get proportionally taller walls.
--   2. segmentWidth is computed against the wall TOP's inner circumference
--      (where the chords are tightest), so wide pits with many segments
--      can't overlap themselves at the meeting point.
-- The stored WallAngle attribute lets a later grow() call reposition the
-- same segment without picking a new angle.
local MAX_WALL_HEIGHT = 0.4
local MIN_WALL_HEIGHT = 0.22
local WALL_BOTTOM_DISTANCE_RATIO = 0.88
local WALL_LEAN_PER_HEIGHT = 1.3
local WALL_TOP_CHORD_FILL = 0.95

local function buildOrUpdateWall(model: Model, position: Vector3, radius: number, depth: number, wallIndex: number, wallCount: number, rng: Random, tweenDuration: number)
	local wallsFolder = ensureFolder(model, WALLS_FOLDER_NAME)
	local name = ("Wall%d"):format(wallIndex)
	local part = wallsFolder:FindFirstChild(name) :: Part?

	local angle = if part then part:GetAttribute(WALL_ANGLE_ATTR) :: number? else nil
	if not angle then
		angle = (wallIndex / wallCount) * math.pi * 2 + rng:NextNumber(-0.04, 0.04)
	end

	local depthFactor = math.clamp(depth, 0.3, 1.2)
	local wallHeight = math.clamp(radius * 0.18 * depthFactor, MIN_WALL_HEIGHT, MAX_WALL_HEIGHT)
	local bottomDistance = radius * WALL_BOTTOM_DISTANCE_RATIO
	local leanInset = wallHeight * WALL_LEAN_PER_HEIGHT
	local topDistance = math.max(0.2, bottomDistance - leanInset)
	local segmentWidth = (2 * math.pi * topDistance / wallCount) * WALL_TOP_CHORD_FILL

	local outward = Vector3.new(math.cos(angle), 0, math.sin(angle))
	local tangent = Vector3.new(-math.sin(angle), 0, math.cos(angle))
	local bottomMid = position + outward * bottomDistance
	local topMid = position + outward * topDistance + Vector3.new(0, wallHeight, 0)
	local mid = (bottomMid + topMid) * 0.5
	local upVec = (topMid - bottomMid).Unit
	local segmentLength = (topMid - bottomMid).Magnitude
	local cf = CFrame.fromMatrix(mid, tangent, upVec)
	local targetSize = Vector3.new(segmentWidth, segmentLength, 0.16)

	if not part then
		local created = newAnchoredPart(name)
		created:SetAttribute(WALL_ANGLE_ATTR, angle)
		created.Material = Enum.Material.Ground
		-- Tinted slightly darker than the rim clumps so the eye reads
		-- the slope as recessed earth, not raised mound.
		created.Color = DigHoleBuilder.DIRT_COLOR:Lerp(DigHoleBuilder.DIRT_DARK, 0.4 + rng:NextNumber(-0.05, 0.1))
		created.Size = targetSize
		created.CFrame = cf
		created.Parent = wallsFolder
		return
	end

	tweenOrSet(part, tweenDuration, {
		Size = targetSize,
		CFrame = cf,
	})
end

-- Rim clumps are additive: every grow() pass adds more thrown clods on
-- top of the existing ones rather than reshuffling, which matches the
-- physical idea of "each swing kicks more earth onto the rim."
local function addRimChunks(model: Model, position: Vector3, radius: number, additionalCount: number, rng: Random)
	if additionalCount <= 0 then
		return
	end

	local rimFolder = ensureFolder(model, RIM_FOLDER_NAME)
	local existingCount = (model:GetAttribute(RIM_CHUNK_COUNT_ATTR) :: number?) or 0

	for i = 1, additionalCount do
		local globalIndex = existingCount + i
		local angle = rng:NextNumber(0, math.pi * 2)
		local distance = radius + rng:NextNumber(-0.15, 0.30)
		local height = rng:NextNumber(0.28, 0.55)
		local part = newAnchoredPart(("RimChunk%d"):format(globalIndex))
		part.Material = Enum.Material.Ground
		part.Color = DigHoleBuilder.DIRT_COLOR:Lerp(DigHoleBuilder.DIRT_DARK, rng:NextNumber(0, 0.4))
		part.Size = Vector3.new(rng:NextNumber(0.45, 0.75), height, rng:NextNumber(0.45, 0.75))
		part.CFrame = CFrame.new(
			position + Vector3.new(math.cos(angle) * distance, height * 0.5 - 0.02, math.sin(angle) * distance)
		) * CFrame.Angles(rng:NextNumber(-0.4, 0.4), angle + rng:NextNumber(-0.5, 0.5), rng:NextNumber(-0.4, 0.4))
		part.Parent = rimFolder
	end

	model:SetAttribute(RIM_CHUNK_COUNT_ATTR, existingCount + additionalCount)
end

-- Bed stones are also additive so deeper holes accumulate more visible
-- rocks at the bottom, reinforcing the sense of having dug further down.
local function addBedStones(model: Model, position: Vector3, radius: number, additionalCount: number, rng: Random)
	if additionalCount <= 0 then
		return
	end

	local stonesFolder = ensureFolder(model, STONES_FOLDER_NAME)
	local existingCount = (model:GetAttribute(STONE_COUNT_ATTR) :: number?) or 0

	for i = 1, additionalCount do
		local globalIndex = existingCount + i
		local angle = rng:NextNumber(0, math.pi * 2)
		local distance = rng:NextNumber(0, math.max(0, radius * 0.3))
		local size = rng:NextNumber(0.18, 0.32)
		local part = newAnchoredPart(("Stone%d"):format(globalIndex))
		part.Material = Enum.Material.Slate
		part.Color = DigHoleBuilder.STONE_COLOR_BASE:Lerp(DigHoleBuilder.STONE_COLOR_LIGHT, rng:NextNumber(0, 0.5))
		part.Size = Vector3.new(size, size * 0.7, size * rng:NextNumber(0.8, 1.2))
		part.CFrame = CFrame.new(
			position + Vector3.new(math.cos(angle) * distance, 0.22 + size * 0.25, math.sin(angle) * distance)
		) * CFrame.Angles(rng:NextNumber(-0.3, 0.3), rng:NextNumber(0, math.pi), rng:NextNumber(-0.3, 0.3))
		part.Parent = stonesFolder
	end

	model:SetAttribute(STONE_COUNT_ATTR, existingCount + additionalCount)
end

local function ensureDustEmitter(model: Model, position: Vector3)
	local existing = model:FindFirstChild(DUST_ANCHOR_NAME)
	if existing then
		return
	end

	local anchor = newAnchoredPart(DUST_ANCHOR_NAME)
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.CFrame = CFrame.new(position + Vector3.new(0, 0.25, 0))
	anchor.Parent = model

	local attachment = Instance.new("Attachment")
	attachment.Name = "DustAttachment"
	attachment.Parent = anchor

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Dust"
	emitter.Texture = "rbxasset://textures/particles/smoke_main.dds"
	emitter.Color = ColorSequence.new(
		DigHoleBuilder.DIRT_COLOR:Lerp(Color3.new(1, 1, 1), 0.35),
		DigHoleBuilder.DIRT_COLOR
	)
	emitter.LightEmission = 0.05
	emitter.Rate = 4
	emitter.Lifetime = NumberRange.new(0.8, 1.4)
	emitter.Speed = NumberRange.new(0.5, 1.2)
	emitter.SpreadAngle = Vector2.new(45, 45)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.45),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.65),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-30, 30)
	emitter.Parent = attachment
end

local function applySpec(model: Model, spec: Spec, tweenDuration: number)
	local rng = getRng(spec.rng)
	local position = spec.position
	local radius = math.max(0.5, spec.radius)
	local depth = math.clamp(spec.depth, 0.1, 2)
	local layerCount = spec.innerLayerCount or DEFAULT_INNER_LAYER_COUNT
	local wallCount = spec.wallSegmentCount or DEFAULT_WALL_SEGMENT_COUNT
	local targetRimCount = spec.rimChunkCount or DEFAULT_RIM_CHUNK_COUNT
	local targetStoneCount = spec.bedStoneCount or DEFAULT_BED_STONE_COUNT

	model:SetAttribute(RADIUS_ATTR, radius)
	model:SetAttribute(DEPTH_ATTR, depth)
	model:SetAttribute(POSITION_ATTR, position)

	for layerIndex = 1, layerCount do
		buildOrUpdatePitLayer(model, position, radius, depth, layerIndex, layerCount, tweenDuration)
	end

	buildOrUpdatePitCenter(model, position, radius, depth, tweenDuration)

	for wallIndex = 1, wallCount do
		buildOrUpdateWall(model, position, radius, depth, wallIndex, wallCount, rng, tweenDuration)
	end

	local existingRim = (model:GetAttribute(RIM_CHUNK_COUNT_ATTR) :: number?) or 0
	addRimChunks(model, position, radius, math.max(0, targetRimCount - existingRim), rng)

	local existingStones = (model:GetAttribute(STONE_COUNT_ATTR) :: number?) or 0
	addBedStones(model, position, radius, math.max(0, targetStoneCount - existingStones), rng)

	if spec.includeDust then
		ensureDustEmitter(model, position)
	end
end

function DigHoleBuilder.create(spec: Spec): Model
	local model = Instance.new("Model")
	model.Name = "DigHole"
	applySpec(model, spec, 0)
	model.Parent = spec.parent
	return model
end

function DigHoleBuilder.grow(model: Model, spec: Spec, tweenDuration: number)
	applySpec(model, spec, tweenDuration)
end

-- Adds N extra freshly-thrown rim clods on top of whatever the spec already
-- requested. Used by callers (e.g. the per-hit "kicked dirt" pass) that
-- want to keep stacking debris without bumping the spec's rim count.
function DigHoleBuilder.addRimDebris(model: Model, position: Vector3, radius: number, count: number, rng: Random?)
	addRimChunks(model, position, radius, count, getRng(rng))
end

function DigHoleBuilder.fadeOut(model: Model, duration: number)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			tweenOrSet(descendant, duration, { Transparency = 1 })
		elseif descendant:IsA("ParticleEmitter") then
			descendant.Enabled = false
		end
	end
end

return DigHoleBuilder
