local ContentProvider = game:GetService("ContentProvider")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local CameraEffects = require(script.Parent:WaitForChild("CameraEffects"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local DigSiteConfig = require(ConfigFolder:WaitForChild("DigSiteConfig"))
local DigHoleBuilder = require(UtilFolder:WaitForChild("DigHoleBuilder"))

local DigVFX = {}

DigVFX.DIRT_COLOR = Color3.fromRGB(116, 83, 54)
DigVFX.STONE_COLOR = Color3.fromRGB(85, 77, 68)

local activeHolesByKey = {}
local FLAT_CYLINDER_CFRAME = CFrame.Angles(0, 0, math.rad(90))
-- Dirt-shovel SFX. Only assets from Roblox-licensed publishers (e.g.
-- ProSoundEffects) survive Roblox's audio-privacy rules in third-party
-- experiences; private user uploads load silently and were the cause of
-- "the dig sound only plays half the time" when mixed into the pool.
-- Variety per hit comes from the wider PlaybackSpeed jitter in playDigSound
-- below, so a single licensed source still sounds non-mechanical.
local DIG_SOUND_IDS = {
	"rbxassetid://9114083260", -- Dirt Dig Dirt Throws From Shovel 1 (ProSoundEffects)
}
local DUST_PUFFS_PER_HIT = 3
local FINAL_DUST_PUFFS = 4
local FINAL_DIRT_CHUNKS = 5

-- Persistent Sound templates parented to SoundService so the asset stays
-- loaded for the session. Each playDigSound call clones one of these instead
-- of creating a fresh Sound; the clone inherits the loaded buffer and starts
-- immediately, fixing the "first dig is silent / sound is delayed" symptom
-- caused by calling :Play() on an un-loaded SoundId.
local digSoundTemplates: { Sound } = {}
do
	local templateFolder = Instance.new("Folder")
	templateFolder.Name = "DigSoundTemplates"
	templateFolder.Parent = SoundService

	for _, soundId in DIG_SOUND_IDS do
		local template = Instance.new("Sound")
		template.Name = "DigImpactTemplate"
		template.SoundId = soundId
		template.Volume = 0.7
		template.RollOffMaxDistance = 55
		template.Parent = templateFolder
		table.insert(digSoundTemplates, template)
	end

	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(digSoundTemplates)
		end)
	end)
end

local function getHoleKey(position: Vector3)
	return ("%d:%d"):format(math.floor(position.X + 0.5), math.floor(position.Z + 0.5))
end

local function getFlatCylinderSize(diameter: number, height: number)
	return Vector3.new(height, diameter, diameter)
end

local function prepareVfxPart(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CastShadow = false
end

local function getFlatCylinderCFrame(position: Vector3)
	return CFrame.new(position) * FLAT_CYLINDER_CFRAME
end

function DigVFX.addDebris(instance: Instance, lifetime: number)
	Debris:AddItem(instance, lifetime)
	return instance
end

function DigVFX.tween(instance: Instance, duration: number, easingStyle: Enum.EasingStyle, easingDirection: Enum.EasingDirection, goals)
	local createdTween = TweenService:Create(instance, TweenInfo.new(duration, easingStyle, easingDirection), goals)
	createdTween:Play()
	return createdTween
end

function DigVFX.createFlatRing(position: Vector3, color: Color3, startSize: number, endSize: number, duration: number, transparency: number?)
	local ring = Instance.new("Part")
	ring.Name = "DigRing"
	prepareVfxPart(ring)
	ring.Transparency = transparency or 0.25
	ring.Material = Enum.Material.Neon
	ring.Color = color
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = getFlatCylinderSize(startSize, 0.08)
	ring.CFrame = getFlatCylinderCFrame(position + Vector3.new(0, 0.04, 0))
	ring.Parent = Workspace

	DigVFX.tween(ring, duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, {
		Size = getFlatCylinderSize(endSize, 0.08),
		Transparency = 1,
	})

	DigVFX.addDebris(ring, duration + 0.1)
	return ring
end

function DigVFX.spawnDustPuff(position: Vector3, scale: number, color: Color3?)
	local puff = Instance.new("Part")
	puff.Name = "DigDust"
	prepareVfxPart(puff)
	puff.Transparency = 0.62
	puff.Material = Enum.Material.SmoothPlastic
	puff.Color = color or DigVFX.DIRT_COLOR
	puff.Shape = Enum.PartType.Cylinder
	puff.Size = getFlatCylinderSize(0.9 * scale, 0.08 * scale)
	puff.CFrame = getFlatCylinderCFrame(position + Vector3.new(math.random(-18, 18) / 20, 0.08, math.random(-18, 18) / 20))
	puff.Parent = Workspace

	DigVFX.tween(puff, 0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, {
		Size = getFlatCylinderSize(puff.Size.Y * 2.2, puff.Size.X),
		Transparency = 1,
		CFrame = puff.CFrame + Vector3.new(0, 0.12 * scale, 0),
	})

	DigVFX.addDebris(puff, 0.7)
end

function DigVFX.spawnDirtChunk(position: Vector3, scale: number)
	local chunk = Instance.new("Part")
	chunk.Name = "DirtChunk"
	prepareVfxPart(chunk)
	chunk.Material = Enum.Material.Ground
	chunk.Color = if math.random() > 0.3 then DigVFX.DIRT_COLOR else DigVFX.STONE_COLOR
	chunk.Size = Vector3.new(
		math.random(18, 35) / 100,
		math.random(14, 28) / 100,
		math.random(18, 35) / 100
	) * scale

	local startOffset = Vector3.new(math.random(-18, 18) / 20, 0.12, math.random(-18, 18) / 20)
	local endOffset = Vector3.new(math.random(-42, 42) / 20, math.random(10, 22) / 10, math.random(-42, 42) / 20)
	chunk.CFrame = CFrame.new(position + startOffset) * CFrame.Angles(math.random(), math.random(), math.random())
	chunk.Parent = Workspace

	DigVFX.tween(chunk, 0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, {
		CFrame = CFrame.new(position + endOffset) * CFrame.Angles(math.random(), math.random(), math.random()),
		Transparency = 0.15,
	})

	task.delay(0.45, function()
		if chunk.Parent then
			DigVFX.tween(chunk, 0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In, {
				CFrame = chunk.CFrame + Vector3.new(0, -1.4, 0),
				Transparency = 1,
			})
		end
	end)

	DigVFX.addDebris(chunk, 0.9)
end

local function playDigSound(position: Vector3, progress: number, isFinalHit: boolean)
	local template = digSoundTemplates[math.random(1, #digSoundTemplates)]
	if not template then
		return
	end

	local emitter = Instance.new("Part")
	emitter.Name = "DigSoundEmitter"
	prepareVfxPart(emitter)
	emitter.Transparency = 1
	emitter.Size = Vector3.new(0.2, 0.2, 0.2)
	emitter.CFrame = CFrame.new(position)
	emitter.Parent = Workspace

	local sound = template:Clone()
	sound.Name = "DigImpactSound"
	sound.Volume = if isFinalHit then 1.0 else 0.9
	-- Wider jitter (~0.85x..1.18x) keeps a single source from sounding
	-- mechanical on rapid back-to-back hits.
	sound.PlaybackSpeed = math.random(85, 118) / 100 + progress * 0.05
	sound.Parent = emitter
	sound:Play()

	-- TimeLength is 0 until the asset is loaded; fall back to a generous
	-- floor so a not-yet-loaded clone still has time to play through once the
	-- preload finishes.
	local lifetime = if sound.TimeLength > 0 then sound.TimeLength + 0.5 else 3
	DigVFX.addDebris(emitter, lifetime)
end

local function scatterRimChunks(position: Vector3, radius: number, count: number)
	for _ = 1, count do
		local angle = math.random() * math.pi * 2
		local distance = radius + math.random(-18, 18) / 100
		local chunk = Instance.new("Part")
		chunk.Name = "FreshDirtClod"
		prepareVfxPart(chunk)
		chunk.Material = Enum.Material.Ground
		chunk.Color = DigVFX.DIRT_COLOR:Lerp(DigVFX.STONE_COLOR, math.random(0, 35) / 100)
		chunk.Size = Vector3.new(math.random(22, 48) / 100, math.random(10, 22) / 100, math.random(18, 42) / 100)
		chunk.CFrame = CFrame.new(
			position + Vector3.new(math.cos(angle) * distance, 0.12, math.sin(angle) * distance)
		) * CFrame.Angles(math.random(), math.random(), math.random())
		chunk.Parent = Workspace

		DigVFX.tween(chunk, 0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out, {
			CFrame = chunk.CFrame + Vector3.new(0, math.random(6, 14) / 100, 0),
		})
		DigVFX.addDebris(chunk, 5)
	end
end

-- Maps dig progress onto the layered 3D pit geometry so the hole visibly
-- carves deeper and wider with each successful hit. During the risk/extra
-- phase (currentHit > totalStandardHits) the pit keeps growing on a
-- soft-saturating curve instead of capping at the standard final size.
function DigVFX.refreshHole(position: Vector3, currentHit: number, totalStandardHits: number, isFinalHit: boolean)
	local key = getHoleKey(position)
	local hole = activeHolesByKey[key]

	local holeTunables = DigSiteConfig.DUG_HOLE
	local maxRimCount = holeTunables.RIM_CHUNK_COUNT
	local maxStoneCount = holeTunables.BED_STONE_COUNT
	local safeTotal = math.max(1, totalStandardHits)
	local standardProgress = math.clamp(currentHit / safeTotal, 0.15, 1)
	local extraHits = math.max(0, currentHit - safeTotal)
	local extraGrowth = extraHits / (extraHits + holeTunables.EXTRA_GROWTH_SATURATION)

	local radius = 0.9 + standardProgress * 1.2 + extraGrowth * holeTunables.EXTRA_GROWTH_MAX_RADIUS
	local depth = 0.4 + standardProgress * 0.6 + extraGrowth * holeTunables.EXTRA_GROWTH_MAX_DEPTH
	-- Start at ~half the final rim count on hit 1 so the first hole already
	-- reads as "dirt has been kicked out" instead of a tiny clean ring, then
	-- ramp up to the full count by the final standard hit. Extra hits keep
	-- piling more clods on so the rim visibly thickens as the player risks.
	local targetRimCount = math.max(6, math.floor(maxRimCount * (0.5 + standardProgress * 0.5) + extraGrowth * holeTunables.EXTRA_GROWTH_MAX_RIM_BONUS))
	local targetStoneCount = math.max(1, math.floor(maxStoneCount * (0.4 + standardProgress * 0.6) + extraGrowth * holeTunables.EXTRA_GROWTH_MAX_STONE_BONUS))

	local spec: DigHoleBuilder.Spec = {
		position = position,
		radius = radius,
		depth = depth,
		parent = Workspace,
		includeDust = true,
		rimChunkCount = targetRimCount,
		wallSegmentCount = holeTunables.WALL_SEGMENT_COUNT,
		innerLayerCount = holeTunables.INNER_LAYER_COUNT,
		bedStoneCount = targetStoneCount,
	}

	if not hole or not hole.model.Parent then
		local model = DigHoleBuilder.create(spec)
		hole = { model = model, refreshToken = 0 }
		activeHolesByKey[key] = hole
	else
		DigHoleBuilder.grow(hole.model, spec, 0.24)
	end

	hole.refreshToken += 1
	local refreshToken = hole.refreshToken

	-- Per-hit thrown clods on top of the static rim. These animate up into
	-- place and then debris-clear, layering "freshly disturbed" motion on
	-- top of the persistent pit silhouette.
	scatterRimChunks(position, radius, if isFinalHit then 5 else 2)
	task.delay(if isFinalHit then 7 else 2.5, function()
		if activeHolesByKey[key] ~= hole or hole.refreshToken ~= refreshToken or not hole.model.Parent then
			return
		end

		DigHoleBuilder.fadeOut(hole.model, 0.7)
		DigVFX.addDebris(hole.model, 0.85)
		activeHolesByKey[key] = nil
	end)
end

function DigVFX.spawnGroundPulse(position: Vector3)
	DigVFX.createFlatRing(position, Color3.fromRGB(128, 104, 75), 1.1, 5.5, 0.55)
	for _ = 1, DUST_PUFFS_PER_HIT do
		DigVFX.spawnDustPuff(position, math.random(80, 120) / 100)
	end
end

-- Dramatic dirt eruption fired when a brainrot bursts out of the ground.
-- Sends a ring of arcing chunks, central vertical jets, a ground shockwave,
-- and rising dust billows. scale (default 1) grows with rarity.
function DigVFX.spawnDirtEruption(position: Vector3, scale: number?)
	local s = math.max(0.5, scale or 1)

	-- Radial ring: chunks arc outward and upward from the dig hole.
	local ringCount = 10
	for i = 1, ringCount do
		local angle = (i / ringCount) * math.pi * 2 + (math.random() * 2 - 1) * 0.35
		local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local outRadius = (math.random(9, 22) / 10) * s

		local chunk = Instance.new("Part")
		chunk.Name = "EruptionChunk"
		prepareVfxPart(chunk)
		chunk.Material = Enum.Material.Ground
		chunk.Color = if math.random() > 0.28 then DigVFX.DIRT_COLOR else DigVFX.STONE_COLOR
		chunk.Size = Vector3.new(
			math.random(20, 42) / 100,
			math.random(16, 36) / 100,
			math.random(20, 42) / 100
		) * s
		chunk.CFrame = CFrame.new(position + Vector3.new(0, 0.18, 0))
			* CFrame.Angles(math.random(), math.random(), math.random())
		chunk.Parent = Workspace

		local peakHeight = (math.random(28, 58) / 10) * s
		local peakPos = position + dir * outRadius + Vector3.new(0, peakHeight, 0)
		local riseDur = math.random(25, 40) / 100

		DigVFX.tween(chunk, riseDur, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, {
			CFrame = CFrame.new(peakPos)
				* CFrame.Angles(math.random() * 4, math.random() * 4, math.random() * 4),
		})

		task.delay(riseDur, function()
			if not chunk.Parent then return end
			local landPos = peakPos + dir * (math.random(4, 12) / 10)
				- Vector3.new(0, peakHeight * 0.55, 0)
			DigVFX.tween(chunk, math.random(22, 35) / 100, Enum.EasingStyle.Quad, Enum.EasingDirection.In, {
				CFrame = CFrame.new(landPos)
					* CFrame.Angles(math.random() * 4, math.random() * 4, math.random() * 4),
				Transparency = 1,
			})
		end)

		DigVFX.addDebris(chunk, 1.0)
	end

	-- Central vertical jets: a cluster of chunks shooting straight up.
	for _ = 1, 5 do
		local offset = Vector3.new(math.random(-9, 9) / 10, 0.1, math.random(-9, 9) / 10)
		local jet = Instance.new("Part")
		jet.Name = "EruptionJet"
		prepareVfxPart(jet)
		jet.Material = Enum.Material.Ground
		jet.Color = DigVFX.DIRT_COLOR
		jet.Size = Vector3.new(
			math.random(12, 26) / 100,
			math.random(26, 46) / 100,
			math.random(12, 26) / 100
		) * s
		jet.CFrame = CFrame.new(position + offset)
		jet.Parent = Workspace

		local jetHeight = (math.random(42, 76) / 10) * s
		local riseTime = math.random(20, 32) / 100

		DigVFX.tween(jet, riseTime, Enum.EasingStyle.Quart, Enum.EasingDirection.Out, {
			CFrame = CFrame.new(position + offset + Vector3.new(
				math.random(-4, 4) / 10, jetHeight, math.random(-4, 4) / 10
			)) * CFrame.Angles(math.random() * 3, math.random() * 3, math.random() * 3),
		})

		task.delay(riseTime, function()
			if not jet.Parent then return end
			DigVFX.tween(jet, 0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.In, {
				Transparency = 1,
			})
		end)

		DigVFX.addDebris(jet, 0.85)
	end

	-- Ground shockwave ring.
	DigVFX.createFlatRing(position, DigVFX.DIRT_COLOR, 0.4, 5.5 * s, 0.42, 0.08)

	-- Rising dust billows that expand and fade upward.
	for _ = 1, 5 do
		local puff = Instance.new("Part")
		puff.Name = "EruptionDustBillow"
		prepareVfxPart(puff)
		puff.Transparency = 0.48
		puff.Material = Enum.Material.SmoothPlastic
		puff.Color = DigVFX.DIRT_COLOR:Lerp(Color3.fromRGB(185, 165, 135), 0.45)
		puff.Shape = Enum.PartType.Ball
		local ps = (math.random(45, 95) / 100) * s
		puff.Size = Vector3.new(ps, ps, ps)
		puff.CFrame = CFrame.new(position + Vector3.new(
			math.random(-14, 14) / 10, 0.3, math.random(-14, 14) / 10
		))
		puff.Parent = Workspace

		local upDist = (math.random(22, 42) / 10) * s
		DigVFX.tween(puff, 0.62, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, {
			Size = Vector3.new(ps * 2.8, ps * 2.8, ps * 2.8),
			Transparency = 1,
			CFrame = puff.CFrame + Vector3.new(
				math.random(-6, 6) / 10, upDist, math.random(-6, 6) / 10
			),
		})

		DigVFX.addDebris(puff, 0.72)
	end
end

local function spawnFinalImpact(position: Vector3, progress: number)
	DigVFX.createFlatRing(position, Color3.fromRGB(168, 132, 84), 1.4, 7.5 + progress * 1.5, 0.5, 0.18)
	DigVFX.createFlatRing(position, Color3.fromRGB(80, 58, 38), 0.7, 4.2 + progress, 0.32, 0.3)

	for _ = 1, FINAL_DUST_PUFFS do
		DigVFX.spawnDustPuff(position, math.random(115, 165) / 100)
	end

	for _ = 1, FINAL_DIRT_CHUNKS do
		DigVFX.spawnDirtChunk(position, 1.25 + progress * 0.55)
	end
end

function DigVFX.playSequence(diggingPlayer: Player, localPlayer: Player, digPosition: Vector3, digDuration: number, hitIndex: number?, requiredHits: number?)
	local safeDuration = if typeof(digDuration) == "number" and digDuration > 0 then digDuration else 0.45
	local totalHits = if typeof(requiredHits) == "number" and requiredHits > 0
		then requiredHits
		else math.max(1, math.floor(safeDuration / 0.45))
	local currentHit = if typeof(hitIndex) == "number" and hitIndex > 0 then hitIndex else totalHits
	local progress = math.clamp(currentHit / totalHits, 0.15, 1)
	local isLocalDig = diggingPlayer == localPlayer
	local isFinalHit = currentHit >= totalHits

	DigVFX.refreshHole(digPosition, currentHit, totalHits, isFinalHit)

	local stepCount = if hitIndex then 1 else totalHits
	for step = 1, stepCount do
		local delayTime = (step - 1) * (safeDuration / stepCount)
		task.delay(delayTime, function()
			local isStepFinal = isFinalHit and (hitIndex ~= nil or step == stepCount)
			playDigSound(digPosition, progress, isStepFinal)
			DigVFX.spawnGroundPulse(digPosition)

			local burstScale = 1 + progress * 0.7
			for _ = 1, 2 + currentHit do
				DigVFX.spawnDirtChunk(digPosition, burstScale)
			end

			if isStepFinal then
				spawnFinalImpact(digPosition, progress)
			end

			if isLocalDig then
				local shakeIntensity = if isStepFinal then 0.18 + progress * 0.18 else 0.08 + progress * 0.12
				task.spawn(CameraEffects.shake, localPlayer, 0.18, shakeIntensity)
			end
		end)
	end
end

return DigVFX
