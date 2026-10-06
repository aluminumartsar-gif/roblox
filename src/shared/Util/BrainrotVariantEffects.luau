local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local VariantConfig = require(ConfigFolder:WaitForChild("VariantConfig"))

local BrainrotVariantEffects = {}

local EFFECTS_FOLDER_NAME = "VariantEffects"
local VARIANT_ATTRIBUTE = "BrainrotVariantId"
local ORIGINAL_MATERIAL_ATTRIBUTE = "BrainrotOriginalMaterial"
local ORIGINAL_COLOR_ATTRIBUTE = "BrainrotOriginalColor"
local SCALE_ATTRIBUTE = "BrainrotVariantEffectScale"
local STASH_FOLDER_NAME = "StashedAppearances"
local APPEARANCE_LINK_NAME = "OriginalParent"

local function findRootPart(visual: Instance): BasePart?
	if visual:IsA("BasePart") then
		return visual
	end

	if visual:IsA("Model") then
		if visual.PrimaryPart then
			return visual.PrimaryPart
		end

		for _, descendant in visual:GetDescendants() do
			if descendant:IsA("BasePart") then
				return descendant
			end
		end
	end

	return nil
end

local function getVisualSize(visual: Instance): Vector3
	if visual:IsA("Model") then
		local _, size = visual:GetBoundingBox()
		return size
	end

	if visual:IsA("BasePart") then
		return visual.Size
	end

	return Vector3.new(4, 4, 4)
end

local function applyParticle(host: BasePart, config, scale: number): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = config.textureId
	emitter.Color = config.color
	emitter.Rate = config.rate
	emitter.Lifetime = config.lifetime
	emitter.Speed = config.speed or NumberRange.new(0.6, 1.4)
	emitter.RotSpeed = config.rotSpeed or NumberRange.new(-60, 60)
	emitter.LightEmission = config.lightEmission or 0.5
	emitter.LightInfluence = 0
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Acceleration = config.acceleration or Vector3.new(0, 1, 0)
	emitter.LockedToPart = false

	local sizeKeypoints = {}
	for _, keypoint in config.size.Keypoints do
		table.insert(sizeKeypoints, NumberSequenceKeypoint.new(keypoint.Time, keypoint.Value * scale, keypoint.Envelope * scale))
	end
	emitter.Size = NumberSequence.new(sizeKeypoints)

	if config.transparency then
		emitter.Transparency = config.transparency
	else
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.1),
			NumberSequenceKeypoint.new(1, 1),
		})
	end

	emitter.Parent = host
	return emitter
end

local function applyHighlight(visual: Instance, folder: Folder, config)
	local highlight = Instance.new("Highlight")
	highlight.Name = "VariantHighlight"
	highlight.Adornee = visual
	highlight.FillColor = config.fillColor or Color3.fromRGB(255, 255, 255)
	highlight.FillTransparency = if config.fillTransparency ~= nil then config.fillTransparency else 1
	highlight.OutlineColor = config.outlineColor or Color3.fromRGB(255, 255, 255)
	highlight.OutlineTransparency = if config.outlineTransparency ~= nil then config.outlineTransparency else 0
	-- Occluded keeps the highlight from bleeding through walls; AlwaysOnTop
	-- would feel like an X-ray overlay.
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = folder
	return highlight
end

local function applyMaterialOverride(visual: Instance, material: Enum.Material)
	local function override(part: BasePart)
		if part:GetAttribute(ORIGINAL_MATERIAL_ATTRIBUTE) == nil then
			part:SetAttribute(ORIGINAL_MATERIAL_ATTRIBUTE, part.Material.Name)
		end
		part.Material = material
	end

	if visual:IsA("BasePart") then
		override(visual)
	end

	for _, descendant in visual:GetDescendants() do
		if descendant:IsA("BasePart") then
			override(descendant)
		end
	end
end

local function restoreMaterials(visual: Instance)
	local function restore(part: BasePart)
		local original = part:GetAttribute(ORIGINAL_MATERIAL_ATTRIBUTE)
		if type(original) == "string" then
			local ok, materialEnum = pcall(function()
				return Enum.Material[original]
			end)
			if ok and materialEnum then
				part.Material = materialEnum
			end
			part:SetAttribute(ORIGINAL_MATERIAL_ATTRIBUTE, nil)
		end
	end

	if visual:IsA("BasePart") then
		restore(visual)
	end

	for _, descendant in visual:GetDescendants() do
		if descendant:IsA("BasePart") then
			restore(descendant)
		end
	end
end

local function applyBodyColor(visual: Instance, color: Color3)
	local function override(part: BasePart)
		if part:GetAttribute(ORIGINAL_COLOR_ATTRIBUTE) == nil then
			part:SetAttribute(ORIGINAL_COLOR_ATTRIBUTE, part.Color)
		end
		part.Color = color
	end

	if visual:IsA("BasePart") then
		override(visual)
	end

	for _, descendant in visual:GetDescendants() do
		if descendant:IsA("BasePart") then
			override(descendant)
		end
	end
end

local function restoreColors(visual: Instance)
	local function restore(part: BasePart)
		local original = part:GetAttribute(ORIGINAL_COLOR_ATTRIBUTE)
		if typeof(original) == "Color3" then
			part.Color = original
			part:SetAttribute(ORIGINAL_COLOR_ATTRIBUTE, nil)
		end
	end

	if visual:IsA("BasePart") then
		restore(visual)
	end

	for _, descendant in visual:GetDescendants() do
		if descendant:IsA("BasePart") then
			restore(descendant)
		end
	end
end

-- SurfaceAppearance's ColorMap visually overrides BasePart.Color, so we move
-- any SurfaceAppearance into a stash folder under the variant effects root
-- while a body recolor is active and reparent them back when the variant is
-- cleared. An ObjectValue link records the original BasePart so we don't have
-- to guess on restore.
local function stashSurfaceAppearances(visual: Instance, effectsFolder: Folder)
	local stash: Folder? = nil

	for _, descendant in visual:GetDescendants() do
		if not descendant:IsA("SurfaceAppearance") then
			continue
		end

		local parentPart = descendant.Parent
		if not parentPart or not parentPart:IsA("BasePart") then
			continue
		end

		if not stash then
			stash = Instance.new("Folder")
			stash.Name = STASH_FOLDER_NAME
			stash.Parent = effectsFolder
		end

		local link = Instance.new("ObjectValue")
		link.Name = APPEARANCE_LINK_NAME
		link.Value = parentPart
		link.Parent = descendant
		descendant.Parent = stash
	end
end

local function restoreSurfaceAppearances(visual: Instance)
	local effects = visual:FindFirstChild(EFFECTS_FOLDER_NAME)
	if not effects then
		return
	end

	local stash = effects:FindFirstChild(STASH_FOLDER_NAME)
	if not stash then
		return
	end

	for _, appearance in stash:GetChildren() do
		if not appearance:IsA("SurfaceAppearance") then
			continue
		end

		local link = appearance:FindFirstChild(APPEARANCE_LINK_NAME)
		local target = if link and link:IsA("ObjectValue") then link.Value else nil
		if link then
			link:Destroy()
		end

		if target and target:IsA("BasePart") and target:IsDescendantOf(visual) then
			appearance.Parent = target
		else
			appearance:Destroy()
		end
	end
end

local function startRainbowGlow(light: PointLight, folder: Folder)
	local hue = 0
	local connection
	connection = RunService.Heartbeat:Connect(function(dt)
		if not light.Parent or not folder.Parent then
			if connection then
				connection:Disconnect()
				connection = nil
			end
			return
		end

		hue = (hue + dt * 0.35) % 1
		light.Color = Color3.fromHSV(hue, 0.85, 1)
	end)

	folder.Destroying:Connect(function()
		if connection then
			connection:Disconnect()
			connection = nil
		end
	end)
end

-- Drives a hue cycle across every BasePart in the visual. Originals are
-- snapshotted into the same `BrainrotOriginalColor` attribute used by
-- `applyBodyColor`, so `restoreColors` (run from `clear`) puts them back.
-- An optional Highlight tracks the same hue offset by a small amount so the
-- outline reads as part of the rainbow rather than a static colored frame.
local function startRainbowBody(visual: Instance, folder: Folder, highlight: Highlight?)
	local parts: { BasePart } = {}

	local function track(part: BasePart)
		if part:GetAttribute(ORIGINAL_COLOR_ATTRIBUTE) == nil then
			part:SetAttribute(ORIGINAL_COLOR_ATTRIBUTE, part.Color)
		end
		table.insert(parts, part)
	end

	if visual:IsA("BasePart") then
		track(visual)
	end

	for _, descendant in visual:GetDescendants() do
		if descendant:IsA("BasePart") then
			track(descendant)
		end
	end

	if #parts == 0 then
		return
	end

	local hue = 0
	local connection: RBXScriptConnection?
	connection = RunService.Heartbeat:Connect(function(dt)
		if not folder.Parent then
			if connection then
				connection:Disconnect()
				connection = nil
			end
			return
		end

		hue = (hue + dt * 0.25) % 1
		local bodyColor = Color3.fromHSV(hue, 0.85, 1)
		for _, part in parts do
			if part.Parent then
				part.Color = bodyColor
			end
		end

		if highlight and highlight.Parent then
			highlight.FillColor = bodyColor
			highlight.OutlineColor = Color3.fromHSV((hue + 0.08) % 1, 0.6, 1)
		end
	end)

	folder.Destroying:Connect(function()
		if connection then
			connection:Disconnect()
			connection = nil
		end
	end)
end

local function clearEffectsFolder(visual: Instance)
	local existing = visual:FindFirstChild(EFFECTS_FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
end

function BrainrotVariantEffects.clear(visual: Instance)
	if not visual then
		return
	end

	-- Order matters: stashed SurfaceAppearances live inside the effects folder,
	-- so reparent them back BEFORE the folder is destroyed.
	restoreSurfaceAppearances(visual)
	clearEffectsFolder(visual)
	restoreMaterials(visual)
	restoreColors(visual)
	visual:SetAttribute(VARIANT_ATTRIBUTE, nil)
end

function BrainrotVariantEffects.apply(visual: Instance, rootPart: BasePart?, variantId: string?)
	if not visual then
		return
	end

	if not VariantConfig.isKnown(variantId) or variantId == VariantConfig.NORMAL_ID then
		BrainrotVariantEffects.clear(visual)
		return
	end

	BrainrotVariantEffects.clear(visual)

	local entry = VariantConfig.getById(variantId)
	local host = rootPart or findRootPart(visual)
	if not host then
		return
	end

	visual:SetAttribute(VARIANT_ATTRIBUTE, entry.id)

	local folder = Instance.new("Folder")
	folder.Name = EFFECTS_FOLDER_NAME
	folder.Parent = visual

	local size = getVisualSize(visual)
	local largestAxis = math.max(size.X, size.Y, size.Z, 1)
	local scale = math.clamp(largestAxis / 6, 0.5, 2.5)
	visual:SetAttribute(SCALE_ATTRIBUTE, scale)

	if entry.glowColor or entry.rainbowGlow then
		local light = Instance.new("PointLight")
		light.Name = "VariantGlow"
		light.Color = entry.glowColor or Color3.fromRGB(255, 255, 255)
		light.Brightness = (entry.glowBrightness or 2) * scale
		light.Range = (entry.glowRange or 12) * scale
		light.Shadows = false
		light.Parent = host

		if entry.rainbowGlow then
			startRainbowGlow(light, folder)
		end
	end

	if entry.particle then
		applyParticle(host, entry.particle, scale)
	end
	if entry.secondaryParticle then
		applyParticle(host, entry.secondaryParticle, scale)
	end

	if entry.bodyColor or entry.rainbowBody then
		stashSurfaceAppearances(visual, folder)
	end

	if entry.bodyColor then
		applyBodyColor(visual, entry.bodyColor)
	end

	if entry.materialOverride then
		applyMaterialOverride(visual, entry.materialOverride)
	end

	local highlightInstance: Highlight? = nil
	if entry.highlight then
		highlightInstance = applyHighlight(visual, folder, entry.highlight)
	end

	if entry.rainbowBody then
		startRainbowBody(visual, folder, highlightInstance)
	end
end

function BrainrotVariantEffects.getActiveVariant(visual: Instance): string?
	local value = visual:GetAttribute(VARIANT_ATTRIBUTE)
	if type(value) == "string" then
		return value
	end

	return nil
end

return BrainrotVariantEffects
