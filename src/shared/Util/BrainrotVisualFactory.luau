local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local BrainrotConfig = require(ConfigFolder:WaitForChild("BrainrotConfig"))
local BrainrotVariantEffects = require(script.Parent:WaitForChild("BrainrotVariantEffects"))

local BrainrotVisualFactory = {}

BrainrotVisualFactory.MODEL_FOLDER_NAME = "Brainrots"
BrainrotVisualFactory.WORLD_TARGET_HEIGHT = 8.4
BrainrotVisualFactory.BRAINROT_ID_ATTRIBUTE = "BrainrotId"
BrainrotVisualFactory.DEFAULT_IDLE_ANIMATION_FOLDER_ATTRIBUTE = "DefaultIdleAnimationId"
-- Brainrots that fall back to procedural idle get tagged so a client-side
-- controller can animate them on RenderStepped (asset-based idles stay on the
-- Animator path and don't need this tag).
BrainrotVisualFactory.PROCEDURAL_IDLE_TAG = "BrainrotProceduralIdle"

local ROOT_PART_NAMES = { "RootPart", "FakeRootPart", "HumanoidRootPart" }
local ANIMATION_ID_ATTRIBUTES = { "IdleAnimationId", "AnimationId", "IdleAnimation" }

local function getBrainrotsFolder()
	return ReplicatedStorage:FindFirstChild(BrainrotVisualFactory.MODEL_FOLDER_NAME)
end

local function findRootPart(instance: Instance)
	if instance:IsA("BasePart") then
		return instance
	end

	if instance:IsA("Model") then
		for _, partName in ROOT_PART_NAMES do
			local namedPart = instance:FindFirstChild(partName, true)
			if namedPart and namedPart:IsA("BasePart") then
				instance.PrimaryPart = namedPart
				return namedPart
			end
		end

		if instance.PrimaryPart then
			return instance.PrimaryPart
		end

		for _, descendant in instance:GetDescendants() do
			if descendant:IsA("BasePart") then
				instance.PrimaryPart = descendant
				return descendant
			end
		end
	end

	return nil
end

local function anchorModelRoot(model: Model, rootPart: BasePart)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = descendant == rootPart
		end
	end
end

local function normalizeAnimationId(value): string?
	if typeof(value) ~= "string" and typeof(value) ~= "number" then
		return nil
	end

	local animationId = tostring(value)
	if animationId == "" then
		return nil
	end

	if animationId:match("^%d+$") then
		return "rbxassetid://" .. animationId
	end

	return animationId
end

local function getAnimationIdFromAttributes(instance: Instance)
	for _, attributeName in ANIMATION_ID_ATTRIBUTES do
		local animationId = normalizeAnimationId(instance:GetAttribute(attributeName))
		if animationId then
			return animationId
		end
	end

	return nil
end

local function findAnimation(model: Model)
	local fallbackAnimation = nil

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Animation") and normalizeAnimationId(descendant.AnimationId) then
			if descendant.Name:lower():find("idle") then
				return descendant
			end

			fallbackAnimation = fallbackAnimation or descendant
		end
	end

	return fallbackAnimation
end

local function createAnimation(parent: Instance, animationId: string)
	local animation = Instance.new("Animation")
	animation.Name = "BrainrotIdleAnimation"
	animation.AnimationId = animationId
	animation.Parent = parent

	return animation
end

-- Brainrot id is whatever uniquely identifies a template in `BrainrotConfig`.
-- We resolve it from (in order): an explicit attribute, the model's name, or the
-- caller's hint. Viewport clones keep the template name, so `model.Name` is a
-- safe fallback for client-side `startIdle` calls.
local function resolveBrainrotId(model: Model, hint: string?): string?
	local attributeId = model:GetAttribute(BrainrotVisualFactory.BRAINROT_ID_ATTRIBUTE)
	if typeof(attributeId) == "string" and attributeId ~= "" then
		return attributeId
	end

	if hint and hint ~= "" then
		return hint
	end

	if model.Name and model.Name ~= "" then
		return model.Name
	end

	return nil
end

local function getDefaultFolderAnimationId(): string?
	local folder = getBrainrotsFolder()
	if not folder then
		return nil
	end

	return normalizeAnimationId(folder:GetAttribute(BrainrotVisualFactory.DEFAULT_IDLE_ANIMATION_FOLDER_ATTRIBUTE))
end

local function resolveAnimationIdFromConfig(brainrotId: string?): string?
	if not brainrotId then
		return nil
	end

	return normalizeAnimationId(BrainrotConfig.getIdleAnimationId(brainrotId))
end

local function tryStartAssetIdle(model: Model, controller: AnimationController, brainrotIdHint: string?): boolean
	local resolvedId = resolveBrainrotId(model, brainrotIdHint)

	local animation = findAnimation(model)
	if not animation then
		local animationId = resolveAnimationIdFromConfig(resolvedId)
			or getAnimationIdFromAttributes(model)
			or getAnimationIdFromAttributes(controller)
			or getDefaultFolderAnimationId()
		if animationId then
			animation = createAnimation(controller, animationId)
		end
	end

	if not animation then
		return false
	end

	local animator = controller:FindFirstChildWhichIsA("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = controller
	end

	local success, trackOrError = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not success then
		warn(("[BrainrotVisualFactory] Failed to load animation for %s: %s"):format(model.Name, tostring(trackOrError)))
		return false
	end

	local track = trackOrError
	track.Priority = Enum.AnimationPriority.Idle
	track.Looped = true
	track:Play()
	return true
end

local function startIdleForModel(model: Model, brainrotIdHint: string?)
	if model:GetAttribute("BrainrotIdleStarted") then
		return
	end

	local controller = model:FindFirstChildWhichIsA("AnimationController", true)
	if controller and tryStartAssetIdle(model, controller, brainrotIdHint) then
		model:SetAttribute("BrainrotIdleStarted", true)
		return
	end

	-- No uploaded Animation asset available; flag the model for the client-side
	-- procedural idle controller. Tagging (instead of driving the animation
	-- here) keeps the motion off the server and synced to RenderStepped for
	-- smooth playback in both world spawns and UI viewports.
	local rootPart = model.PrimaryPart or findRootPart(model)
	if rootPart then
		CollectionService:AddTag(model, BrainrotVisualFactory.PROCEDURAL_IDLE_TAG)
		model:SetAttribute("BrainrotIdleStarted", true)
	end
end

function BrainrotVisualFactory.startIdle(visual: Instance, brainrotId: string?)
	if visual:IsA("Model") then
		startIdleForModel(visual, brainrotId)
	end
end

function BrainrotVisualFactory.hasTemplate(brainrotId: string)
	local folder = getBrainrotsFolder()
	return folder ~= nil and folder:FindFirstChild(brainrotId) ~= nil
end

local function prepareDescendant(descendant: Instance)
	if descendant:IsA("ProximityPrompt") or descendant:IsA("BillboardGui") then
		descendant:Destroy()
		return
	end

	if descendant:IsA("BasePart") then
		descendant.Anchored = false
		descendant.CanCollide = false
		descendant.CanTouch = false
		descendant.Massless = true
	end
end

local function prepareVisual(visual: Instance)
	prepareDescendant(visual)

	for _, descendant in visual:GetDescendants() do
		prepareDescendant(descendant)
	end
end

local function scaleModelToHeight(model: Model, targetHeight: number?)
	if not targetHeight then
		return
	end

	local _, size = model:GetBoundingBox()
	if size.Y <= 0 then
		return
	end

	model:ScaleTo(targetHeight / size.Y)
end

local function createFallback(options)
	local fallback = Instance.new("Part")
	fallback.Name = options.name or options.brainrotId
	fallback:SetAttribute("BrainrotFallbackVisual", true)
	fallback.Shape = Enum.PartType.Block
	fallback.Material = Enum.Material.SmoothPlastic
	fallback.Color = options.fallbackColor or Color3.new(1, 1, 1)
	fallback.Anchored = true
	fallback.CanCollide = false
	fallback.CanTouch = false
	fallback.Transparency = 1
	fallback.Size = Vector3.new(0.2, 0.2, 0.2)
	fallback.CFrame = options.cframe or CFrame.new()
	fallback.Parent = options.parent

	return fallback, fallback
end

function BrainrotVisualFactory.create(brainrotId: string, options)
	options = options or {}
	options.brainrotId = brainrotId

	local folder = getBrainrotsFolder()
	local template = if folder then folder:FindFirstChild(brainrotId) else nil
	if not template then
		if options.allowFallback == false then
			warn(("[BrainrotVisualFactory] Missing Brainrots.%s; skipping fallback visual."):format(brainrotId))
			return nil, nil
		end

		return createFallback(options)
	end

	local visual = template:Clone()
	visual.Name = options.name or brainrotId
	visual:SetAttribute(BrainrotVisualFactory.BRAINROT_ID_ATTRIBUTE, brainrotId)
	prepareVisual(visual)

	if visual:IsA("Model") then
		scaleModelToHeight(visual, options.targetHeight)
		visual:PivotTo(options.cframe or CFrame.new())
	elseif visual:IsA("BasePart") then
		visual.Anchored = true
		visual.CFrame = options.cframe or CFrame.new()
	else
		visual:Destroy()
		if options.allowFallback == false then
			warn(("[BrainrotVisualFactory] %s is not a Model or BasePart; skipping fallback visual."):format(brainrotId))
			return nil, nil
		end

		return createFallback(options)
	end

	local rootPart = findRootPart(visual)
	if not rootPart then
		visual:Destroy()
		if options.allowFallback == false then
			warn(("[BrainrotVisualFactory] %s has no BasePart root; skipping fallback visual."):format(brainrotId))
			return nil, nil
		end

		return createFallback(options)
	end

	if visual:IsA("Model") then
		anchorModelRoot(visual, rootPart)
	end

	visual.Parent = options.parent
	if visual:IsA("Model") and options.animateIdle ~= false then
		startIdleForModel(visual, brainrotId)
	end

	if options.variantId then
		BrainrotVariantEffects.apply(visual, rootPart, options.variantId)
	end

	return visual, rootPart
end

function BrainrotVisualFactory.applyVariant(visual: Instance, variantId: string?)
	BrainrotVariantEffects.apply(visual, nil, variantId)
end

return BrainrotVisualFactory
