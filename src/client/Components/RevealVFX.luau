local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local BrainrotConfig = require(ConfigFolder:WaitForChild("BrainrotConfig"))

local CameraEffects = require(script.Parent:WaitForChild("CameraEffects"))
local DigVFX = require(script.Parent:WaitForChild("DigVFX"))

local RevealVFX = {}
local COLLECT_SOUND_ID = "rbxasset://sounds/button.wav"
local CYLINDER_UPRIGHT_CFRAME = CFrame.Angles(0, 0, math.rad(90))

local function randomHorizontalDirection()
	local angle = math.random() * math.pi * 2
	return Vector3.new(math.cos(angle), 0, math.sin(angle))
end

local function getUprightCylinderSize(height: number, diameter: number)
	return Vector3.new(height, diameter, diameter)
end

local function getUprightCylinderCFrame(position: Vector3)
	return CFrame.new(position) * CYLINDER_UPRIGHT_CFRAME
end

local function createSpark(position: Vector3, color: Color3, scale: number)
	local spark = Instance.new("Part")
	spark.Name = "RevealSpark"
	spark.Anchored = true
	spark.CanCollide = false
	spark.CastShadow = false
	spark.Material = Enum.Material.Neon
	spark.Color = color
	spark.Shape = Enum.PartType.Ball
	spark.Size = Vector3.new(0.18, 0.18, 0.18) * scale
	spark.CFrame = CFrame.new(position)
	spark.Parent = Workspace

	local endOffset = Vector3.new(math.random(-35, 35) / 10, math.random(8, 32) / 10, math.random(-35, 35) / 10)
	DigVFX.tween(spark, 0.65, Enum.EasingStyle.Quart, Enum.EasingDirection.Out, {
		CFrame = CFrame.new(position + endOffset),
		Size = Vector3.new(0.04, 0.04, 0.04),
		Transparency = 1,
	})

	DigVFX.addDebris(spark, 0.8)
end

local function createBurstStreak(position: Vector3, color: Color3, scale: number)
	local streak = Instance.new("Part")
	streak.Name = "RevealBurstStreak"
	streak.Anchored = true
	streak.CanCollide = false
	streak.CastShadow = false
	streak.Material = Enum.Material.Neon
	streak.Color = color
	streak.Transparency = 0.05

	local direction = randomHorizontalDirection()
	local startPosition = position + direction * (math.random(4, 12) / 10) + Vector3.new(0, math.random(6, 14) / 10, 0)
	local endPosition = position + direction * (math.random(28, 58) / 10) + Vector3.new(0, math.random(22, 54) / 10, 0)
	local length = (endPosition - startPosition).Magnitude
	streak.Size = Vector3.new(0.08, 0.08, length) * scale
	streak.CFrame = CFrame.lookAt((startPosition + endPosition) / 2, endPosition)
	streak.Parent = Workspace

	DigVFX.tween(streak, 0.42, Enum.EasingStyle.Quart, Enum.EasingDirection.Out, {
		CFrame = CFrame.lookAt(endPosition, endPosition + direction + Vector3.new(0, 1, 0)),
		Size = Vector3.new(0.02, 0.02, math.max(length * 0.25, 0.25)) * scale,
		Transparency = 1,
	})

	DigVFX.addDebris(streak, 0.55)
end

local function createRevealGlow(position: Vector3, color: Color3, rarityRank: number)
	local glow = Instance.new("Part")
	glow.Name = "RevealGlow"
	glow.Anchored = true
	glow.CanCollide = false
	glow.CastShadow = false
	glow.Transparency = 1
	glow.Size = Vector3.new(0.2, 0.2, 0.2)
	glow.CFrame = CFrame.new(position + Vector3.new(0, 1.8, 0))
	glow.Parent = Workspace

	local light = Instance.new("PointLight")
	light.Name = "RevealGlowLight"
	light.Color = color
	light.Brightness = 1.8 + rarityRank * 0.6
	light.Range = 10 + rarityRank * 2
	light.Parent = glow

	DigVFX.tween(light, 0.75, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, {
		Brightness = 0,
		Range = 4,
	})

	DigVFX.addDebris(glow, 0.9)
end

local function createRevealBeam(position: Vector3, color: Color3, rarityRank: number)
	local beam = Instance.new("Part")
	beam.Name = "RareRevealBeam"
	beam.Anchored = true
	beam.CanCollide = false
	beam.CastShadow = false
	beam.Transparency = 0.2
	beam.Material = Enum.Material.Neon
	beam.Color = color
	beam.Shape = Enum.PartType.Cylinder
	local diameter = 0.45 + rarityRank * 0.12
	local height = 8 + rarityRank * 2
	beam.Size = getUprightCylinderSize(height, diameter)
	beam.CFrame = getUprightCylinderCFrame(position + Vector3.new(0, height / 2, 0))
	beam.Parent = Workspace

	DigVFX.tween(beam, 0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, {
		Size = getUprightCylinderSize(height * 1.1, diameter * 1.7),
		Transparency = 1,
	})

	DigVFX.addDebris(beam, 0.9)
end

local function createJackpotBurst(position: Vector3, color: Color3, rarityRank: number)
	createRevealGlow(position, color, rarityRank)
	DigVFX.createFlatRing(position, Color3.new(1, 1, 1), 1.2, 7 + rarityRank * 1.4, 0.38, 0.12)
	DigVFX.createFlatRing(position, color, 2.4, 10 + rarityRank * 2, 0.8, 0)

	for _ = 1, 10 + rarityRank * 3 do
		createBurstStreak(position, color:Lerp(Color3.new(1, 1, 1), 0.25), 0.85 + rarityRank * 0.06)
	end

	for _ = 1, 8 + rarityRank * 2 do
		DigVFX.spawnDirtChunk(position, 1.2 + rarityRank * 0.18)
	end
end

local function getCollectTarget(player: Player)
	local character = player.Character
	if not character then
		return nil
	end

	local upperTorso = character:FindFirstChild("UpperTorso")
	local torso = character:FindFirstChild("Torso")
	local root = character:FindFirstChild("HumanoidRootPart")
	if upperTorso and upperTorso:IsA("BasePart") then
		return upperTorso
	end
	if torso and torso:IsA("BasePart") then
		return torso
	end
	if root and root:IsA("BasePart") then
		return root
	end

	return nil
end

local function getFrontCollectPosition(player: Player, fallbackPosition: Vector3)
	local character = player.Character
	if not character then
		return fallbackPosition
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return fallbackPosition
	end

	return root.Position + root.CFrame.LookVector * 4 + Vector3.new(0, 1.5, 0)
end

local function findDrop(dropId: string)
	local dropsFolder = Workspace:FindFirstChild("BrainrotDrops")
	if not dropsFolder then
		return nil
	end

	for _ = 1, 20 do
		for _, child in dropsFolder:GetChildren() do
			if child:GetAttribute("DropId") == dropId then
				return child
			end
		end
		task.wait(0.05)
	end

	return nil
end

local function getInstancePosition(instance: Instance)
	if instance:IsA("Model") then
		return instance:GetPivot().Position
	end
	if instance:IsA("BasePart") then
		return instance.Position
	end

	return nil
end

local function setVisualCollecting(instance: Instance)
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BillboardGui") or descendant:IsA("ProximityPrompt") then
			descendant.Enabled = false
		elseif descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.CanTouch = false
		end
	end
end

local function createCollectSpark(position: Vector3, color: Color3)
	local spark = Instance.new("Part")
	spark.Name = "CollectBoopSpark"
	spark.Anchored = true
	spark.CanCollide = false
	spark.CastShadow = false
	spark.Material = Enum.Material.Neon
	spark.Color = color
	spark.Shape = Enum.PartType.Ball
	spark.Size = Vector3.new(0.16, 0.16, 0.16)
	spark.CFrame = CFrame.new(position)
	spark.Parent = Workspace

	local endOffset = Vector3.new(math.random(-12, 12) / 10, math.random(-4, 12) / 10, math.random(-12, 12) / 10)
	DigVFX.tween(spark, 0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, {
		CFrame = CFrame.new(position + endOffset),
		Size = Vector3.new(0.03, 0.03, 0.03),
		Transparency = 1,
	})

	Debris:AddItem(spark, 0.45)
end

local function playBoop(target: BasePart?)
	local sound = Instance.new("Sound")
	sound.Name = "BrainrotCollectBoop"
	sound.SoundId = COLLECT_SOUND_ID
	sound.Volume = 0.9
	sound.PlaybackSpeed = 1.35
	sound.RollOffMaxDistance = 55
	sound.Parent = target or Workspace
	sound:Play()
	Debris:AddItem(sound, 1)
end

local function tweenModelPivot(model: Model, targetCFrame: CFrame, duration: number)
	local pivotValue = Instance.new("CFrameValue")
	pivotValue.Value = model:GetPivot()

	local pivotConnection = pivotValue.Changed:Connect(function(value)
		if model.Parent then
			model:PivotTo(value)
		end
	end)

	local pivotTween = TweenService:Create(
		pivotValue,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Value = targetCFrame }
	)
	pivotTween:Play()
	pivotTween.Completed:Once(function()
		pivotConnection:Disconnect()
		pivotValue:Destroy()
	end)

	return pivotTween
end

local function tweenModelToTarget(model: Model, targetCFrame: CFrame, duration: number)
	local pivotValue = Instance.new("CFrameValue")
	pivotValue.Value = model:GetPivot()
	local scaleValue = Instance.new("NumberValue")
	scaleValue.Value = 1
	local startScale = model:GetScale()

	local pivotConnection = pivotValue.Changed:Connect(function(value)
		if model.Parent then
			model:PivotTo(value)
		end
	end)
	local scaleConnection = scaleValue.Changed:Connect(function(value)
		if model.Parent then
			model:ScaleTo(startScale * value)
		end
	end)

	local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Back, Enum.EasingDirection.In)
	local pivotTween = TweenService:Create(pivotValue, tweenInfo, { Value = targetCFrame })
	local scaleTween = TweenService:Create(scaleValue, TweenInfo.new(duration * 0.8, Enum.EasingStyle.Quart, Enum.EasingDirection.In), { Value = 0.08 })
	pivotTween:Play()
	scaleTween:Play()

	pivotTween.Completed:Once(function()
		pivotConnection:Disconnect()
		scaleConnection:Disconnect()
		pivotValue:Destroy()
		scaleValue:Destroy()
	end)
end

local function tweenPartToTarget(part: BasePart, targetCFrame: CFrame, duration: number)
	local targetSize = Vector3.new(
		math.max(part.Size.X * 0.08, 0.05),
		math.max(part.Size.Y * 0.08, 0.05),
		math.max(part.Size.Z * 0.08, 0.05)
	)

	TweenService:Create(part, TweenInfo.new(duration, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
		CFrame = targetCFrame,
		Size = targetSize,
		Transparency = 1,
	}):Play()
end

function RevealVFX.play(diggingPlayer: Player, localPlayer: Player, brainrotId: string, position: Vector3, revealData)
	local fallbackData = BrainrotConfig.getRevealData(brainrotId)
	local rarityRank = revealData and revealData.rarityRank or fallbackData.rarityRank
	local revealColor = revealData and revealData.revealColor or fallbackData.revealColor

	-- Dirt eruption: fires for every rarity, grows with rank.
	DigVFX.spawnDirtEruption(position, 0.9 + rarityRank * 0.14)

	DigVFX.createFlatRing(position, revealColor, 1.8, 5 + rarityRank * 1.5, 0.75, 0.05)
	DigVFX.createFlatRing(position, Color3.new(1, 1, 1), 0.8, 2.5 + rarityRank, 0.45, 0.25)

	for _ = 1, 6 + rarityRank * 4 do
		createSpark(position + Vector3.new(0, 1, 0), revealColor, 0.8 + rarityRank * 0.08)
	end

	for _ = 1, 4 + rarityRank do
		DigVFX.spawnDustPuff(position, 1 + rarityRank * 0.12, revealColor:Lerp(DigVFX.DIRT_COLOR, 0.65))
	end

	if rarityRank >= 4 then
		createRevealBeam(position, revealColor, rarityRank)
		createJackpotBurst(position, revealColor, rarityRank)
	end

	if rarityRank >= 5 then
		task.delay(0.15, function()
			DigVFX.createFlatRing(position, revealColor, 2, 11 + rarityRank * 1.7, 0.95, 0)
			for _ = 1, 8 do
				createBurstStreak(position, Color3.new(1, 1, 1), 1.15)
			end
		end)
	end

	if diggingPlayer == localPlayer then
		task.spawn(CameraEffects.shake, localPlayer, 0.42 + rarityRank * 0.07, CameraEffects.getRevealShakeIntensity(rarityRank) * 1.2)
	end
end

function RevealVFX.playCollect(owner: Player, _localPlayer: Player, dropId: string, brainrotId: string, duration: number?)
	local drop = findDrop(dropId)
	local target = getCollectTarget(owner)
	if not drop or not target then
		if target then
			playBoop(target)
		end
		return
	end

	local fallbackData = BrainrotConfig.getRevealData(brainrotId)
	local collectDuration = if typeof(duration) == "number" and duration > 0 then duration else 0.55
	local startPosition = getInstancePosition(drop)
	local targetPosition = target.Position + Vector3.new(0, 0.35, 0)
	local targetCFrame = CFrame.new(targetPosition)
	local frontPosition = getFrontCollectPosition(owner, startPosition or targetPosition)
	local frontCFrame = CFrame.new(frontPosition)
	local approachDuration = math.max(collectDuration * 0.45, 0.15)
	local inventoryDuration = math.max(collectDuration * 0.55, 0.2)

	setVisualCollecting(drop)
	DigVFX.createFlatRing(targetPosition, fallbackData.revealColor, 0.5, 2.2, 0.35, 0.1)
	if startPosition then
		for _ = 1, 8 do
			createCollectSpark(startPosition, fallbackData.revealColor)
		end
	end

	local function finishCollect()
		if not drop.Parent then
			return
		end

		if drop:IsA("Model") then
			tweenModelToTarget(drop, targetCFrame, inventoryDuration)
		elseif drop:IsA("BasePart") then
			tweenPartToTarget(drop, targetCFrame, inventoryDuration)
		end

		task.delay(inventoryDuration * 0.82, function()
			playBoop(target)
			for _ = 1, 10 do
				createCollectSpark(targetPosition, fallbackData.revealColor)
			end
		end)
	end

	if drop:IsA("Model") then
		local approachTween = tweenModelPivot(drop, frontCFrame, approachDuration)
		approachTween.Completed:Once(finishCollect)
	elseif drop:IsA("BasePart") then
		local approachTween = TweenService:Create(
			drop,
			TweenInfo.new(approachDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ CFrame = frontCFrame }
		)
		approachTween:Play()
		approachTween.Completed:Once(finishCollect)
	end
end

return RevealVFX
