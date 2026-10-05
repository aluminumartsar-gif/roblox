--!strict
--[[
	ItemVisuals
	ServerScriptService/Server/Modules/ItemVisuals

	Builds the placeholder models for eggs and creatures. Pure builders: no
	game state, no tags, no prompts — callers add those. Step 4 reuses these
	for items carried overhead.

	Every model's pivot is the BOTTOM CENTRE, so `model:PivotTo(cf)` stands it
	on `cf`. Creatures face their pivot's -Z (LookVector).

	Placeholder art: a body block in the creature's Config colour and size,
	a head, and glowing eyes. The Secret rarity never renders clearly. The
	art pass replaces these builders and nothing else has to change.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local ItemVisuals = {}

ItemVisuals.EggSize = Vector3.new(2.6, 3.4, 2.6)

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

--- An egg standing on the origin. The shell carries a PointLight named
--- HeatGlow that clients brighten as heat rises.
function ItemVisuals.BuildEgg(eggId: string): Model
	local egg = Config.Eggs[eggId]
	assert(egg, "Unknown egg " .. tostring(eggId))
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

	local glow = Instance.new("PointLight")
	glow.Name = "HeatGlow"
	glow.Color = Color3.fromRGB(255, 140, 60)
	glow.Range = 10
	glow.Brightness = 0
	glow.Shadows = false
	glow.Parent = shell

	model.PrimaryPart = shell
	shell.PivotOffset = CFrame.new(0, -size.Y / 2, 0)
	return model
end

--- A creature standing on the origin, facing -Z.
function ItemVisuals.BuildCreature(creatureId: string, mutation: string?): Model
	local def = Config.CreaturesById[creatureId]
	assert(def, "Unknown creature " .. tostring(creatureId))
	local rarity = Config.Rarities[def.Rarity]
	local size: Vector3 = def.PlaceholderSize
	local secret = rarity.NeverRenderClearly == true

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

	-- Mutations (when enabled) get a coloured outline.
	local mutationDef = mutation and Config.Mutations[mutation]
	if mutationDef then
		local highlight = Instance.new("Highlight")
		highlight.FillTransparency = 1
		highlight.OutlineColor = mutationDef.Color
		highlight.Parent = model
	end

	model.PrimaryPart = body
	body.PivotOffset = CFrame.new(0, -size.Y / 2, 0)
	return model
end

return ItemVisuals
