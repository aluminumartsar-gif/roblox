--!strict
--[[
	ItemVisuals
	ReplicatedStorage/Shared/ItemVisuals

	Builds the models for eggs and creatures. Pure builders: no game state,
	no tags, no prompts — callers add those. Shared so the client can build
	the same models for UI (Codex pages, the hatch reveal).

	Every model's pivot is the BOTTOM CENTRE, so `model:PivotTo(cf)` stands it
	on `cf`. Creatures face their pivot's -Z (LookVector).

	Art comes from generated meshes (Config.Art). The server's ArtService
	turns those into templates under ReplicatedStorage.ArtTemplates at boot
	(Creatures/<id>, Eggs/<id>); these builders clone a template when one
	exists. Without one (asset not configured, or it failed to load) they
	fall back to the block placeholder, so a missing asset never breaks
	anything.

	Contract callers rely on:
	  * egg:      PrimaryPart named "Shell", with a PointLight "HeatGlow"
	  * creature: PrimaryPart named "Body"; parts named "Eye" are left alone
	              by the Secret flicker
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local ItemVisuals = {}

ItemVisuals.EggSize = Vector3.new(2.6, 3.4, 2.6)

--- Name of the folder ArtService fills with templates.
ItemVisuals.TemplateFolderName = "ArtTemplates"

local function part(props: { [string]: any }): BasePart
	local p = Instance.new(props.ClassName or "Part") :: BasePart
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in pairs(props) do
		if key ~= "ClassName" and key ~= "Parent" then
			(p :: any)[key] = value
		end
	end
	p.Parent = props.Parent
	return p
end

--- The template for `id` in ArtTemplates/<kind>, or nil.
function ItemVisuals.GetTemplate(kind: string, id: string): Model?
	local root = ReplicatedStorage:FindFirstChild(ItemVisuals.TemplateFolderName)
	local folder = root and root:FindFirstChild(kind)
	local template = folder and folder:FindFirstChild(id)
	if template and template:IsA("Model") and template.PrimaryPart then
		return template
	end
	return nil
end

--- A fresh copy of a template, with every part safe to drop in the world.
local function cloneTemplate(template: Model, name: string): Model
	local model = template:Clone()
	model.Name = name
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
	return model
end

--------------------------------------------------------------------------
-- Eggs
--------------------------------------------------------------------------

local function addHeatGlow(shell: BasePart)
	local glow = Instance.new("PointLight")
	glow.Name = "HeatGlow"
	glow.Color = Color3.fromRGB(255, 140, 60)
	glow.Range = 10
	glow.Brightness = 0
	glow.Shadows = false
	glow.Parent = shell
end

local function buildPlaceholderEgg(eggId: string): Model
	local egg = Config.Eggs[eggId]
	local size = ItemVisuals.EggSize

	local model = Instance.new("Model")
	model.Name = "Egg"

	local shell = part({
		Name = "Shell",
		Size = size,
		CFrame = CFrame.new(0, size.Y / 2, 0),
		Color = egg.Color,
		Material = Enum.Material.SmoothPlastic,
		Parent = model,
	})
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = shell

	-- A band of speckles so eggs read as eggs and not balls.
	for i = 1, 6 do
		local angle = (i / 6) * math.pi * 2
		part({
			ClassName = "Part",
			Name = "Speckle",
			Shape = Enum.PartType.Ball,
			Size = Vector3.one * 0.45,
			CFrame = CFrame.new(math.cos(angle) * size.X * 0.47, size.Y * 0.55, math.sin(angle) * size.Z * 0.47),
			Color = egg.Color:Lerp(Color3.new(1, 1, 1), 0.45),
			Material = Enum.Material.SmoothPlastic,
			Parent = model,
		})
	end

	addHeatGlow(shell)
	model.PrimaryPart = shell
	shell.PivotOffset = CFrame.new(0, -size.Y / 2, 0)
	return model
end

--- An egg standing on the origin. The shell carries a PointLight named
--- HeatGlow that clients brighten as heat rises.
function ItemVisuals.BuildEgg(eggId: string): Model
	assert(Config.Eggs[eggId], "Unknown egg " .. tostring(eggId))
	local template = ItemVisuals.GetTemplate("Eggs", eggId)
	if not template then
		return buildPlaceholderEgg(eggId)
	end
	local model = cloneTemplate(template, "Egg")
	local shell = model.PrimaryPart :: BasePart
	shell.Name = "Shell"
	if not shell:FindFirstChild("HeatGlow") then
		addHeatGlow(shell)
	end
	return model
end

--------------------------------------------------------------------------
-- Creatures
--------------------------------------------------------------------------

local function buildPlaceholderCreature(def: any, secret: boolean): Model
	local size: Vector3 = def.PlaceholderSize

	local model = Instance.new("Model")
	model.Name = "Creature"

	local material = if secret then Enum.Material.ForceField else Enum.Material.SmoothPlastic
	local body = part({
		Name = "Body",
		Size = size,
		CFrame = CFrame.new(0, size.Y / 2, 0),
		Color = def.PlaceholderColor,
		Material = material,
		Parent = model,
	})

	local headSize = math.min(size.X, size.Z) * 0.7
	local headCf = CFrame.new(0, size.Y + headSize * 0.3, -size.Z * 0.2)
	part({
		Name = "Head",
		Shape = Enum.PartType.Ball,
		Size = Vector3.one * headSize,
		CFrame = headCf,
		Color = def.PlaceholderColor:Lerp(Color3.new(0, 0, 0), 0.15),
		Material = material,
		Parent = model,
	})

	local eyeColor = if secret then Color3.fromRGB(255, 40, 40) else Color3.fromRGB(255, 250, 220)
	for _, side in ipairs({ -1, 1 }) do
		part({
			Name = "Eye",
			Shape = Enum.PartType.Ball,
			Size = Vector3.one * math.max(0.3, headSize * 0.18),
			CFrame = headCf * CFrame.new(side * headSize * 0.22, headSize * 0.08, -headSize * 0.42),
			Color = eyeColor,
			Material = Enum.Material.Neon,
			Parent = model,
		})
	end

	model.PrimaryPart = body
	body.PivotOffset = CFrame.new(0, -size.Y / 2, 0)
	return model
end

--- A creature standing on the origin, facing -Z.
function ItemVisuals.BuildCreature(creatureId: string, mutation: string?): Model
	local def = Config.CreaturesById[creatureId]
	assert(def, "Unknown creature " .. tostring(creatureId))
	local rarity = Config.Rarities[def.Rarity]
	local secret = rarity.NeverRenderClearly == true

	local model: Model
	local template = ItemVisuals.GetTemplate("Creatures", creatureId)
	if template then
		model = cloneTemplate(template, "Creature")
		local body = model.PrimaryPart :: BasePart
		body.Name = "Body"
		if secret then
			-- Never renders clearly: a shimmering silhouette.
			for _, d in ipairs(model:GetDescendants()) do
				if d:IsA("BasePart") then
					d.Material = Enum.Material.ForceField
					d.Color = Color3.fromRGB(20, 20, 24)
				end
			end
		end
	else
		model = buildPlaceholderCreature(def, secret)
	end

	-- Mutations (when enabled) get a coloured outline.
	local mutationDef = mutation and Config.Mutations[mutation]
	if mutationDef then
		local highlight = Instance.new("Highlight")
		highlight.FillTransparency = 1
		highlight.OutlineColor = mutationDef.Color
		highlight.Parent = model
	end

	return model
end

return ItemVisuals
