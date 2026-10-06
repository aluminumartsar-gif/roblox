local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local BrainrotConfig = require(ConfigFolder:WaitForChild("BrainrotConfig"))
local VariantConfig = require(ConfigFolder:WaitForChild("VariantConfig"))
local BrainrotPlacard = require(UtilFolder:WaitForChild("BrainrotPlacard"))
local BrainrotVisualFactory = require(UtilFolder:WaitForChild("BrainrotVisualFactory"))

local BrainrotDropComponent = {}
local BURIED_SILHOUETTE_COLOR = Color3.fromRGB(14, 12, 20)
local BURIED_OUTLINE_COLOR = Color3.fromRGB(60, 52, 80)
local DIRT_COLORS = {
	Color3.fromRGB(70, 48, 32),
	Color3.fromRGB(92, 62, 38),
	Color3.fromRGB(112, 82, 52),
}

-- Default rise depth and rest lift used when callers don't specify their own.
-- The rest lift keeps the model's bounding-box bottom a hair above the ground
-- so it doesn't z-fight with the dirt patch underneath.
local DEFAULT_RISE_DEPTH = 7
local DEFAULT_REST_LIFT = 0.05
local DEFAULT_RISE_TIME = 1.1

local function connectOnce(signal, callback)
	local connection
	connection = signal:Connect(function(...)
		if connection then
			connection:Disconnect()
			connection = nil
		end

		callback(...)
	end)

	return connection
end

local function applyBuriedSilhouette(visual: Instance)
	local dirtInstances = {}
	local dirtClumpCount = 0

	local function createDirtClump(part: BasePart)
		if dirtClumpCount >= 22 or part.Size.Magnitude < 0.45 then
			return
		end
		dirtClumpCount += 1

		local maxAxis = math.max(part.Size.X, part.Size.Y, part.Size.Z)
		local size = math.clamp(maxAxis * math.random(10, 20) / 100, 0.16, 0.7)
		local clump = Instance.new("Part")
		clump.Name = "BuriedDirtClump"
		clump.Anchored = false
		clump.CanCollide = false
		clump.CanTouch = false
		clump.CanQuery = false
		clump.Massless = true
		clump.CastShadow = false
		clump.Material = Enum.Material.Ground
		clump.Color = DIRT_COLORS[math.random(1, #DIRT_COLORS)]
		clump.Size = Vector3.new(size * math.random(70, 130) / 100, size * math.random(45, 90) / 100, size * math.random(70, 130) / 100)
		clump.CFrame = part.CFrame
			* CFrame.new(
				math.random(-45, 45) / 100 * part.Size.X,
				math.random(-45, 45) / 100 * part.Size.Y,
				math.random(-45, 45) / 100 * part.Size.Z
			)
			* CFrame.Angles(math.random(), math.random(), math.random())
		clump.Parent = visual

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = part
		weld.Part1 = clump
		weld.Parent = clump

		table.insert(dirtInstances, clump)
	end

	-- Highlight overlays a uniform fill across every BasePart in the model,
	-- including ones with SurfaceAppearance/PBR maps that ignore Color3 and
	-- MeshPart TextureID. Manipulating those properties from a normal script
	-- is restricted, so the overlay is the only reliable way to keep the
	-- buried preview consistently dark and secretive across all templates.
	local highlight = Instance.new("Highlight")
	highlight.Name = "BuriedSilhouette"
	highlight.FillColor = BURIED_SILHOUETTE_COLOR
	highlight.FillTransparency = 0
	highlight.OutlineColor = BURIED_OUTLINE_COLOR
	highlight.OutlineTransparency = 0.4
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Adornee = visual
	highlight.Parent = visual

	if visual:IsA("BasePart") then
		createDirtClump(visual)
	end

	for _, descendant in visual:GetDescendants() do
		if descendant:IsA("BasePart") then
			createDirtClump(descendant)
		end
	end

	return function(duration: number)
		local fadeDuration = math.max(duration or 0, 0)

		if highlight.Parent then
			if fadeDuration <= 0 then
				highlight:Destroy()
			else
				local tween = TweenService:Create(
					highlight,
					TweenInfo.new(fadeDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ FillTransparency = 1, OutlineTransparency = 1 }
				)
				tween:Play()
				connectOnce(tween.Completed, function()
					if highlight.Parent then
						highlight:Destroy()
					end
				end)
			end
		end

		for _, dirtInstance in dirtInstances do
			if dirtInstance.Parent then
				dirtInstance:Destroy()
			end
		end
	end
end

-- Distance from the pivot down to the bottom of the model's bounding box, in
-- world units (positive = pivot above bottom, negative = pivot below bottom).
-- Used to align the resting position so the visible bottom sits on the ground
-- regardless of where the template author parked the pivot.
local function computePivotToBottomY(visual: Instance): number
	if visual:IsA("Model") then
		local cf, size = visual:GetBoundingBox()
		local pivot = visual:GetPivot()
		return pivot.Position.Y - (cf.Position.Y - size.Y / 2)
	elseif visual:IsA("BasePart") then
		return visual.Size.Y / 2
	end
	return 0
end

-- Server-driven Tweens replicate as a single Tween instance, so each client
-- runs its own local interpolation on the property. That's much smoother than
-- per-Heartbeat PivotTo writes, which only reach clients at network frequency
-- and produced the choppy stop-motion rise we used to see.
local function tweenRoot(rootPart: BasePart, targetCFrame: CFrame, duration: number)
	local tween = TweenService:Create(
		rootPart,
		TweenInfo.new(math.max(duration, 0), Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CFrame = targetCFrame }
	)
	tween:Play()
	return tween
end

-- For a Model the tween target is the root part's CFrame, computed by undoing
-- the part's PivotOffset so the model's pivot lands exactly on `pivotCFrame`.
local function pivotCFrameToRootCFrame(rootPart: BasePart, pivotCFrame: CFrame): CFrame
	return pivotCFrame * rootPart.PivotOffset:Inverse()
end

function BrainrotDropComponent.create(config)
	local digPosition = config.digPosition
	if typeof(digPosition) ~= "Vector3" then
		warn("[BrainrotDropComponent] config.digPosition is required")
		return nil
	end

	local riseDepth = config.riseDepth or DEFAULT_RISE_DEPTH
	local restLift = config.restLift or DEFAULT_REST_LIFT
	local riseTime = config.riseTime or DEFAULT_RISE_TIME

	-- Spawn the visual deep underground so the buried silhouette is hidden
	-- under the dirt while the player swings. The reveal target is computed
	-- after the model is created (we need its bounding box for the offset).
	local spawnPosition = Vector3.new(digPosition.X, digPosition.Y - riseDepth, digPosition.Z)

	local brainrot, rootPart = BrainrotVisualFactory.create(config.id, {
		parent = config.parent,
		cframe = CFrame.new(spawnPosition),
		targetHeight = BrainrotVisualFactory.WORLD_TARGET_HEIGHT,
		fallbackColor = config.color,
		fallbackSize = Vector3.new(4, 4, 4),
		animateIdle = false,
		allowFallback = false,
	})
	if not brainrot or not rootPart then
		return nil
	end

	-- Variant glow/particles are added after the buried silhouette is restored,
	-- so the dirt-covered drop stays mysterious until reveal.
	local restoreSilhouette = applyBuriedSilhouette(brainrot)

	-- Now that the model is scaled and parented, measure its actual pivot
	-- offset so the rest position lands the visible bottom on the ground.
	local pivotToBottomY = computePivotToBottomY(brainrot)
	local revealPosition = Vector3.new(
		digPosition.X,
		digPosition.Y + restLift + pivotToBottomY,
		digPosition.Z
	)

	local rngDenominator = tonumber(config.rngDenominator) or 1
	local hasVariant = VariantConfig.hasVariant(config.variantId)
	-- BrainrotPlacard renders the variant on its own dedicated row when
	-- variantId is set, so the name row gets the plain brainrot id.
	local nameColor = if hasVariant
		then VariantConfig.getNameColor(config.variantId)
		else (config.revealColor or config.color)
	local placard = BrainrotPlacard.create({
		parent = rootPart,
		name = "BrainrotPlacard",
		rngText = BrainrotConfig.formatRngOdds(rngDenominator),
		rngDenominator = rngDenominator,
		rarity = config.rarity,
		rarityColor = config.revealColor or config.color,
		displayName = config.id,
		nameColor = nameColor,
		variantId = config.variantId,
		-- Mirrors the cash row shown on placed brainrots at the base, so the
		-- dig reveal previews exactly what the player will earn per second
		-- once it's collected and dropped onto a slot.
		earningsRate = config.earningsRate,
		-- Position via the model's bounding box so the placard sits cleanly
		-- above the brainrot's top once it rises out of the ground, no matter
		-- where the rootPart lives inside the model.
		aboveModel = brainrot,
		headroom = 1,
		-- Drops are short-lived reveals: keep them visible at any range so
		-- distant players can still see what just spawned.
		maxDistance = 0,
		enabled = false,
		markAsDropLabel = true,
	})
	local billboard = placard.billboard

	local isRevealed = false

	local function pivotCFrameAtY(y: number): CFrame
		return CFrame.new(digPosition.X, y, digPosition.Z)
	end

	local function setProgress(progress: number, duration: number?)
		local safeProgress = math.clamp(progress, 0, 1)
		local targetPivotY = spawnPosition.Y + (revealPosition.Y - spawnPosition.Y) * safeProgress
		local targetPivotCFrame = pivotCFrameAtY(targetPivotY)
		local riseDuration = if typeof(duration) == "number" and duration >= 0 then duration else riseTime

		if brainrot:IsA("Model") then
			return tweenRoot(rootPart, pivotCFrameToRootCFrame(rootPart, targetPivotCFrame), riseDuration)
		end

		return tweenRoot(rootPart, targetPivotCFrame, riseDuration)
	end

	local function stopIdle()
		if brainrot:IsA("Model") then
			-- Removes the procedural idle tag so the client-side controller
			-- stops driving PivotTo on this model. Important during collection
			-- so the fly-to-player tween isn't fought by the bob/sway loop.
			CollectionService:RemoveTag(brainrot, BrainrotVisualFactory.PROCEDURAL_IDLE_TAG)
		end
	end

	local function reveal(duration: number?)
		if isRevealed then
			return
		end

		isRevealed = true
		local riseTween = setProgress(1, duration)
		task.delay(config.labelDelay or 0.35, function()
			placard.setEnabled(true)
		end)
		restoreSilhouette(0.22)

		-- Kick the idle off only after the rise finishes. The procedural idle
		-- captures the model's pivot at trackModel time and then drives
		-- PivotTo every RenderStepped, which would otherwise yank the model
		-- back to whatever mid-rise pose was on screen when the tag arrived
		-- and look like the brainrot got "stuck" in the dirt.
		local function startIdleAfterRise()
			if brainrot.Parent then
				BrainrotVisualFactory.startIdle(brainrot)
			end
		end
		if riseTween then
			connectOnce(riseTween.Completed, startIdleAfterRise)
		else
			startIdleAfterRise()
		end

		-- Wait for the silhouette restore tween to settle before applying the
		-- variant material override; otherwise restoreSilhouette would overwrite
		-- the variant's Material when its tween completes.
		if config.variantId then
			task.delay(0.25, function()
				if brainrot.Parent then
					BrainrotVisualFactory.applyVariant(brainrot, config.variantId)
				end
			end)
		end
	end

	if config.autoRise ~= false then
		local riseTween = setProgress(1, riseTime)
		connectOnce(riseTween.Completed, function()
			reveal(0)
		end)
	end

	return {
		model = brainrot,
		billboard = billboard,
		spawnPosition = spawnPosition,
		revealPosition = revealPosition,
		setProgress = setProgress,
		reveal = reveal,
		stopIdle = stopIdle,
	}
end

return BrainrotDropComponent
