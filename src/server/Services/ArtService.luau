--!strict
--[[
	ArtService
	ServerScriptService/Server/Services/ArtService

	Turns the generated meshes listed in Config.Art into ready-to-clone
	templates under ReplicatedStorage.ArtTemplates:

	  ArtTemplates
	    Creatures/<creatureId>   Model, PrimaryPart = the mesh
	    Eggs/<eggId>
	    Props/<propId>

	Each template stands on the origin (pivot = bottom centre, identity
	rotation) facing -Z, scaled to the entry's Height. ItemVisuals and
	MapBuilder clone these; anything missing falls back to block art.

	Runs first at boot and waits (up to Config.Art.LoadTimeout) for every
	mesh, loading them all in parallel, so the map and the first nests are
	drawn with the real art. A mesh that fails to load is logged and simply
	left out — the game never depends on an asset loading.

	ReplicatedStorage replicates to every client, so the client-side
	builders (Codex pages, the hatch reveal) see the same templates.
]]

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemVisuals = require(Shared:WaitForChild("ItemVisuals"))

local ArtService = {}

local KINDS = { "Creatures", "Eggs", "Props" }

local root: Folder

local function log(fmt: string, ...: any)
	print(string.format("[SAC/Art] " .. fmt, ...))
end

local function warnf(fmt: string, ...: any)
	warn(string.format("[SAC/Art] " .. fmt, ...))
end

--- Loads one mesh as a MeshPart. Tries the Content API first (current
--- engine), then the older string-id form.
local function loadMeshPart(meshId: string): MeshPart?
	local ok, result = pcall(function()
		return (AssetService :: any):CreateMeshPartAsync(Content.fromUri(meshId))
	end)
	if not ok or typeof(result) ~= "Instance" then
		ok, result = pcall(function()
			return (AssetService :: any):CreateMeshPartAsync(meshId)
		end)
	end
	if ok and typeof(result) == "Instance" and result:IsA("MeshPart") then
		return result
	end
	warnf("couldn't load mesh %s: %s", meshId, tostring(result))
	return nil
end

local function buildTemplate(kind: string, id: string, spec: any): Model?
	if typeof(spec) ~= "table" or typeof(spec.Mesh) ~= "string" or spec.Mesh == "" then
		return nil
	end
	local meshPart = loadMeshPart(spec.Mesh)
	if not meshPart then
		return nil
	end

	if typeof(spec.Texture) == "string" and spec.Texture ~= "" then
		local ok, err = pcall(function()
			meshPart.TextureID = spec.Texture
		end)
		if not ok then
			warnf("couldn't set texture on %s/%s: %s", kind, id, tostring(err))
		end
	end

	-- Scale to the requested standing height.
	local natural = meshPart.Size
	local height = tonumber(spec.Height) or natural.Y
	if kind == "Creatures" then
		height *= Config.Art.CreatureScale or 1
	end
	local factor = if natural.Y > 0 then height / natural.Y else 1
	meshPart.Size = natural * factor

	meshPart.Name = "Mesh"
	meshPart.Anchored = true
	meshPart.CanCollide = false
	meshPart.CanQuery = false
	meshPart.CanTouch = false
	meshPart.CastShadow = true
	meshPart.DoubleSided = false

	local yaw = math.rad(tonumber(spec.Yaw) or 0)
	meshPart.CFrame = CFrame.new(0, meshPart.Size.Y / 2, 0) * CFrame.Angles(0, yaw, 0)

	local model = Instance.new("Model")
	model.Name = id
	meshPart.Parent = model
	model.PrimaryPart = meshPart
	-- Pivot at the world origin with no rotation = bottom centre, facing -Z.
	meshPart.PivotOffset = meshPart.CFrame:Inverse()
	return model
end

--- True once a template exists for this kind/id.
function ArtService.Has(kind: string, id: string): boolean
	return ItemVisuals.GetTemplate(kind, id) ~= nil
end

function ArtService.Start()
	local existing = ReplicatedStorage:FindFirstChild(ItemVisuals.TemplateFolderName)
	if existing then
		existing:Destroy() -- always rebuilt from Config, like the map
	end
	root = Instance.new("Folder")
	root.Name = ItemVisuals.TemplateFolderName

	local folders: { [string]: Folder } = {}
	for _, kind in ipairs(KINDS) do
		local folder = Instance.new("Folder")
		folder.Name = kind
		folder.Parent = root
		folders[kind] = folder
	end

	local startClock = os.clock()
	local pending, loaded, failed = 0, 0, 0
	local wanted: { [string]: number } = {}

	for _, kind in ipairs(KINDS) do
		local specs = (Config.Art :: any)[kind] or {}
		wanted[kind] = 0
		for id, spec in pairs(specs) do
			wanted[kind] += 1
			pending += 1
			task.spawn(function()
				local ok, template = pcall(buildTemplate, kind, id, spec)
				if ok and template then
					template.Parent = folders[kind]
					loaded += 1
				else
					if not ok then
						warnf("building %s/%s errored: %s", kind, id, tostring(template))
					end
					failed += 1
				end
				pending -= 1
			end)
		end
	end

	-- Parent now so templates that finish later still get used by anything
	-- built after them.
	root.Parent = ReplicatedStorage

	local deadline = os.clock() + Config.Art.LoadTimeout
	while pending > 0 and os.clock() < deadline do
		task.wait(0.05)
	end

	log("%d meshes ready, %d failed, %d still loading after %.1fs (creatures %d/%d, eggs %d/%d, props %d/%d)",
		loaded, failed, pending, os.clock() - startClock,
		#folders.Creatures:GetChildren(), wanted.Creatures,
		#folders.Eggs:GetChildren(), wanted.Eggs,
		#folders.Props:GetChildren(), wanted.Props)
end

return ArtService
