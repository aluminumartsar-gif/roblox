--!strict
--[[
	MapBuilder
	ServerScriptService/Server/Modules/MapBuilder

	Builds the whole world from Config: terrain (ground, hills, paths), the
	hub (campfire, egg belt, Upgrades cabin, plaza, Totem, leaderboards,
	welcome arch), lantern-lit paths, the ring of plot campsites, The Wilds
	forest, and the boundary.

	The map is GENERATED. WorldService rebuilds it on every server boot, so
	the world always matches the code and Config. Editing parts or terrain by
	hand in Studio does nothing lasting — change Config or this file instead.

	Everything random uses Random.new(Config.Map.Seed) (plots use Seed +
	plot index), so the world is the same on every boot and every server.

	Art: props (trees, rocks, tents, lanterns, nests...) are cloned from the
	generated-mesh templates in ReplicatedStorage.ArtTemplates.Props (built
	by ArtService before WorldService runs) via prop(). When a template is
	missing (Edit-mode preview, a mesh that failed to load) prop() builds a
	cheap part version instead, so the map always builds.

	Terrain: cleared and refilled every boot. The ground surface is y = 0
	everywhere players build or walk between camps (hub, paths, meadow, plot
	ring); gentle hills exist only in The Wilds. Plot decks sit on top at
	Config.Plot.FloorHeight. Materials: Grass + LeafyGrass patches, Ground
	for the hub / paths / deer trails / under plots, Cobblestone plaza.
	Grass blades need Terrain > Decoration ticked once in Studio (it can't
	be set from a script).

	Plot local space: each plot's pivot CFrame looks at the hub, so local -Z
	is "toward the hub" (the door side) and +Z is the back wall. y = 0 is the
	ground; the deck top is at Config.Plot.FloorHeight.

	Structure produced (names/tags other code relies on are marked *):
	  Workspace.Terrain
	  Workspace.Map
	    Hub           (Model, Atomic streaming)
	      Campfire (FireCore part tagged Config.Map.HubCampfireTag*),
	      EggBelt (Bed/Track/Rail, Slats* tag BeltSlat, Burrow_* hole tag
	      Burrow* with Puff*), UpgradeShop (Counter* tag ShopBooth, ShopPrompt*),
	      Leaderboards/Board_<Key> (Screen* tag Config.Leaderboards.BoardTag,
	      attr Board*), WelcomeArch, Totem, lanterns, benches, HubSpawn*
	    Paths         lantern posts along each hub-to-plot path
	    Plots
	      Plot_1 .. Plot_N*  (Model, tag Plot*, Atomic streaming, attrs*)
	        Floor* (PrimaryPart), Walls/* (solid core), Palisade/*, Gate/*,
	        Door* (tag Door), Pad* (tag PlotPad), LockButton* (LockPrompt*),
	        Spawn*, Sign* (SignGui*, OwnerBillboard*),
	        Nests/Nest_1..Nest_12* (tag Nest; Base* PrimaryPart with
	        ItemAnchor*, Glow*, Lid), Decor/*
	    Wilds         trees, rocks, logs, bushes, mushrooms, fireflies
	    Boundary
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local BeltPath = require(Shared:WaitForChild("BeltPath"))
local ItemVisuals = require(Shared:WaitForChild("ItemVisuals"))

local MapBuilder = {}

export type BuildStats = {
	TerrainMs: number,
	TotalMs: number,
	TotalParts: number,
	Parts: { [string]: number },
	Lights: number,
	MeshProps: number,
	FallbackProps: number,
}

--- Filled in by Build(): part counts per category and timings.
MapBuilder.LastStats = nil :: BuildStats?

local TAU = math.pi * 2
local TERRAIN_DEPTH = 12   -- base ground slab thickness below y = 0 (3 voxels)
local PAINT_DEPTH = 4      -- one voxel: repaints the top layer without reshaping it
-- Terrain voxels are 4 studs, CENTRED on multiples of 4 (they span 4k-2 ..
-- 4k+2). A fill whose top is at y = 0 half-fills the voxel centred on 0,
-- which renders as a surface at y = 2 (measured). So every fill is shifted
-- down by VOXEL_OFFSET: the solid ground ends at y = -2 and its surface
-- lands exactly on y = 0, where the camps, hub and props expect it.
local VOXEL_OFFSET = 2
local MOUND_HEIGHT = 0.5   -- nest mound thickness
-- Items stand on a nest's ItemAnchor, 1.1 above the deck (as before the art pass).
local ITEM_HEIGHT_ABOVE_DECK = 1.1

local COLORS = {
	Deck = Color3.fromRGB(122, 88, 58),
	Wall = Color3.fromRGB(84, 58, 40),
	WallCore = Color3.fromRGB(52, 38, 28),
	Trim = Color3.fromRGB(60, 42, 30),
	Log = Color3.fromRGB(96, 68, 46),
	LogShades = { Color3.fromRGB(104, 74, 50), Color3.fromRGB(92, 66, 46), Color3.fromRGB(112, 82, 56) },
	LogEnd = Color3.fromRGB(176, 140, 96),
	Rock = Color3.fromRGB(96, 98, 104),
	Stone = Color3.fromRGB(120, 118, 112),
	Trunk = Color3.fromRGB(78, 56, 40),
	Leaves = { Color3.fromRGB(34, 64, 44), Color3.fromRGB(28, 56, 40), Color3.fromRGB(40, 72, 50) },
	Bush = Color3.fromRGB(44, 76, 46),
	Straw = Color3.fromRGB(150, 122, 74),
	Twig = Color3.fromRGB(120, 92, 60),
	NestHollow = Color3.fromRGB(60, 44, 30),
	CampGround = Color3.fromRGB(112, 90, 66),
	CampGrass = Color3.fromRGB(70, 96, 56),
	Mound = Color3.fromRGB(96, 76, 56),
	HubDirt = Color3.fromRGB(104, 86, 64),
	Canvas = Color3.fromRGB(150, 120, 86),
	CanvasDark = Color3.fromRGB(40, 32, 28),
	Door = Color3.fromRGB(255, 92, 64),
	LockButton = Color3.fromRGB(230, 70, 70),
	Metal = Color3.fromRGB(46, 46, 52),
	Roof = Color3.fromRGB(70, 48, 36),
	SignText = Color3.fromRGB(255, 232, 196),
	TotemPaint = { Color3.fromRGB(150, 70, 52), Color3.fromRGB(70, 104, 120), Color3.fromRGB(176, 140, 72) },
	Ember = Color3.fromRGB(255, 160, 80),
}

-- Per-build counters (reset by Build).
local lightCount = 0
local meshProps = 0
local fallbackProps = 0

--------------------------------------------------------------------------
-- Primitive helpers
--------------------------------------------------------------------------

type Props = { [string]: any }

--- Creates an anchored, smooth-surfaced part. `Parent` is applied last.
local function makePart(className: string, props: Props): BasePart
	local p = Instance.new(className) :: BasePart
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	local parent = props.Parent
	for key, value in pairs(props) do
		if key ~= "Parent" then
			(p :: any)[key] = value
		end
	end
	p.Parent = parent
	return p
end

local function block(props: Props): Part
	return makePart("Part", props) :: Part
end

--- A flat disc lying on the ground. `cf` is the disc centre.
local function disc(cf: CFrame, diameter: number, thickness: number, props: Props): Part
	props.Shape = Enum.PartType.Cylinder
	props.Size = Vector3.new(thickness, diameter, diameter)
	props.CFrame = cf * CFrame.Angles(0, 0, math.pi / 2)
	return block(props)
end

--- An upright cylinder (log post, trunk) standing on `baseCf`.
local function post(baseCf: CFrame, height: number, diameter: number, props: Props): Part
	props.Shape = Enum.PartType.Cylinder
	props.Size = Vector3.new(height, diameter, diameter)
	props.CFrame = baseCf * CFrame.new(0, height / 2, 0) * CFrame.Angles(0, 0, math.pi / 2)
	return block(props)
end

local function folder(name: string, parent: Instance): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

local function model(name: string, parent: Instance, atomic: boolean?): Model
	local m = Instance.new("Model")
	m.Name = name
	if atomic then
		m.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	end
	m.Parent = parent
	return m
end

--- Two sloped slabs meeting at a ridge that runs along the local X axis
--- of `ridgeCf` (which sits at the ridge line). Used for roofs and tents.
local function gable(ridgeCf: CFrame, ridgeLength: number, halfRun: number, pitchDegrees: number,
	thickness: number, props: Props, parent: Instance)
	local pitch = math.rad(pitchDegrees)
	local slabLength = halfRun / math.cos(pitch)
	local drop = halfRun * math.tan(pitch)
	for _, side in ipairs({ -1, 1 }) do
		local p = table.clone(props)
		p.Size = Vector3.new(ridgeLength, thickness, slabLength)
		-- Each slab hangs from the ridge toward its own side.
		p.CFrame = ridgeCf
			* CFrame.new(0, -drop / 2, side * halfRun / 2)
			* CFrame.Angles(side * pitch, 0, 0)
		p.Parent = parent
		block(p)
	end
end

--- A cylinder (log, rail, beam) running from `a` to `b`. Not for exactly
--- vertical logs — use post() for those.
local function logBetween(a: Vector3, b: Vector3, diameter: number, props: Props): Part
	local length = (b - a).Magnitude
	props.Shape = Enum.PartType.Cylinder
	props.Size = Vector3.new(length, diameter, diameter)
	-- lookAt points -Z along the log; turning 90 degrees about Y puts the
	-- cylinder's axis (local X) there instead.
	props.CFrame = CFrame.lookAt((a + b) / 2, b) * CFrame.Angles(0, math.pi / 2, 0)
	return block(props)
end

--- A PointLight. Counted so the build log shows how many lights the map has.
local function pointLight(parent: Instance, color: Color3, range: number, brightness: number, shadows: boolean?): PointLight
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = math.min(range, 60) -- Roblox's maximum
	light.Brightness = brightness
	light.Shadows = shadows == true
	light.Parent = parent
	lightCount += 1
	return light
end

--- An attachment at a world position inside `m`, for lights and effects on
--- mesh props (a mesh's centre is not where its lantern or fire is).
local function attachAt(m: Model, worldPosition: Vector3, name: string): Attachment?
	local host: BasePart? = m.PrimaryPart or (m:FindFirstChildWhichIsA("BasePart", true) :: BasePart?)
	if not host then
		return nil
	end
	local a = Instance.new("Attachment")
	a.Name = name
	a.Parent = host
	a.WorldPosition = worldPosition
	return a
end

--- An invisible volume of drifting, blinking fireflies.
local function fireflies(cf: CFrame, size: Vector3, rate: number, parent: Instance): BasePart
	local volume = block({
		Name = "Fireflies", Size = size, CFrame = cf, Transparency = 1,
		CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false, Parent = parent,
	})
	local e = Instance.new("ParticleEmitter")
	e.Name = "Fireflies"
	e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	e.Color = ColorSequence.new(Config.Map.FireflyColor)
	e.LightEmission = 1
	e.LightInfluence = 0
	e.Brightness = 2
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.15, 0.22),
		NumberSequenceKeypoint.new(0.85, 0.22),
		NumberSequenceKeypoint.new(1, 0),
	})
	-- Fade in, blink off and on once, fade out.
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, 0.05),
		NumberSequenceKeypoint.new(0.45, 0.85),
		NumberSequenceKeypoint.new(0.65, 0.05),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Lifetime = NumberRange.new(4, 7)
	e.Rate = rate
	e.Speed = NumberRange.new(0.3, 1.1)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Acceleration = Vector3.new(0, 0.12, 0)
	e.Drag = 0.4
	e.Shape = Enum.ParticleEmitterShape.Box
	e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	e.Parent = volume
	return volume
end

--------------------------------------------------------------------------
-- Props
-- prop(id, cf, options, parent) clones the mesh template for `id` (see
-- ArtService) or, when there is none, builds the part fallback below.
-- Every prop's pivot is its bottom centre, facing -Z, so `cf` is the spot
-- on the ground it stands on. Fallbacks are built at the origin at their
-- nominal height (Config.Map.PropHeights) and kept cheap: 1-9 parts.
--------------------------------------------------------------------------

type PropOptions = {
	Height: number?,    -- standing height in studs (default: the prop's own)
	Scale: number?,     -- extra multiplier on top of Height
	Collide: boolean?,  -- solid to players (default false: walk-through decor)
	Name: string?,
}

local PROP_HEIGHTS: { [string]: number } = Config.Map.PropHeights :: any

local FALLBACKS: { [string]: (Model) -> () } = {}

local function leaves(i: number): Color3
	return COLORS.Leaves[((i - 1) % #COLORS.Leaves) + 1]
end

function FALLBACKS.PineTree(m: Model)
	local h = PROP_HEIGHTS.PineTree
	post(CFrame.new(), h * 0.42, h * 0.07, { Name = "Trunk", Material = Enum.Material.Wood, Color = COLORS.Trunk, Parent = m })
	-- Two shrinking tiers: { base height, height, diameter } as fractions of h.
	for i, tier in ipairs({ { 0.2, 0.42, 0.5 }, { 0.55, 0.45, 0.28 } }) do
		post(CFrame.new(0, h * tier[1], 0), h * tier[2], h * tier[3], {
			Name = "Leaves", Material = Enum.Material.Grass, Color = leaves(i), Parent = m,
		})
	end
end

function FALLBACKS.RoundTree(m: Model)
	local h = PROP_HEIGHTS.RoundTree
	post(CFrame.new(), h * 0.5, h * 0.09, { Name = "Trunk", Material = Enum.Material.Wood, Color = COLORS.Trunk, Parent = m })
	block({ Name = "Crown", Shape = Enum.PartType.Ball, Size = Vector3.one * h * 0.6, CFrame = CFrame.new(0, h * 0.66, 0),
		Material = Enum.Material.Grass, Color = leaves(3), Parent = m })
	block({ Name = "Crown", Shape = Enum.PartType.Ball, Size = Vector3.one * h * 0.38, CFrame = CFrame.new(h * 0.17, h * 0.78, h * 0.1),
		Material = Enum.Material.Grass, Color = leaves(1), Parent = m })
end

function FALLBACKS.Bush(m: Model)
	block({ Name = "Leaves", Shape = Enum.PartType.Ball, Size = Vector3.one * 3.6, CFrame = CFrame.new(0, 1.2, 0),
		Material = Enum.Material.Grass, Color = COLORS.Bush, Parent = m })
end

function FALLBACKS.Rock(m: Model)
	block({ Name = "Rock", Size = Vector3.new(4, 3.2, 3.4), CFrame = CFrame.new(0, 1.4, 0) * CFrame.Angles(0.15, 0.4, -0.1),
		Material = Enum.Material.Slate, Color = COLORS.Rock, Parent = m })
end

function FALLBACKS.Boulder(m: Model)
	block({ Name = "Rock", Shape = Enum.PartType.Ball, Size = Vector3.one * 7, CFrame = CFrame.new(0, 3.2, 0),
		Material = Enum.Material.Rock, Color = COLORS.Rock, Parent = m })
	block({ Name = "Rock", Size = Vector3.new(5, 3.6, 4.6), CFrame = CFrame.new(2.6, 1.5, 1.4) * CFrame.Angles(0.2, 0.6, 0.1),
		Material = Enum.Material.Rock, Color = COLORS.Stone, Parent = m })
end

function FALLBACKS.Stump(m: Model)
	post(CFrame.new(), 2, 2.6, { Name = "Stump", Material = Enum.Material.Wood, Color = COLORS.Trunk, Parent = m })
	disc(CFrame.new(0, 2.02, 0), 2.2, 0.06, { Name = "Rings", Material = Enum.Material.Wood, Color = COLORS.LogEnd, Parent = m })
end

function FALLBACKS.FallenLog(m: Model)
	block({ Name = "Log", Shape = Enum.PartType.Cylinder, Size = Vector3.new(9, 1.9, 1.9), CFrame = CFrame.new(0, 0.95, 0),
		Material = Enum.Material.Wood, Color = COLORS.Trunk, Parent = m })
end

function FALLBACKS.Mushroom(m: Model)
	local glow = Config.Map.MushroomColor
	post(CFrame.new(), 1.5, 0.45, { Name = "Stem", Material = Enum.Material.SmoothPlastic, Color = COLORS.SignText, Parent = m })
	block({ Name = "Cap", Shape = Enum.PartType.Ball, Size = Vector3.one * 1.5, CFrame = CFrame.new(0, 1.7, 0),
		Material = Enum.Material.Neon, Color = glow, CastShadow = false, Parent = m })
	block({ Name = "Cap", Shape = Enum.PartType.Ball, Size = Vector3.one * 0.9, CFrame = CFrame.new(0.9, 0.5, 0.5),
		Material = Enum.Material.Neon, Color = glow, CastShadow = false, Parent = m })
end

function FALLBACKS.Tent(m: Model)
	local h = PROP_HEIGHTS.Tent
	local halfWidth = 5
	-- Ridge runs front to back, so the open end faces -Z.
	gable(CFrame.new(0, h, 0) * CFrame.Angles(0, math.pi / 2, 0), 8, halfWidth, math.deg(math.atan(h / halfWidth)), 0.3,
		{ Name = "Canvas", Material = Enum.Material.Fabric, Color = COLORS.Canvas }, m)
	-- Dark interior, kept low and narrow enough to stay under the canvas.
	block({ Name = "Inside", Size = Vector3.new(halfWidth * 1.04, h * 0.36, 7.2), CFrame = CFrame.new(0, h * 0.18, 0),
		Material = Enum.Material.Fabric, Color = COLORS.CanvasDark, Parent = m })
end

function FALLBACKS.Campfire(m: Model)
	for i = 1, 6 do
		local angle = (i / 6) * TAU
		block({ Name = "Stone", Shape = Enum.PartType.Ball, Size = Vector3.one * 1.1,
			CFrame = CFrame.new(math.cos(angle) * 2, 0.4, math.sin(angle) * 2),
			Material = Enum.Material.Slate, Color = COLORS.Rock, Parent = m })
	end
	-- Three logs leaning into a teepee.
	for i = 0, 2 do
		local angle = i * TAU / 3
		local foot = Vector3.new(math.cos(angle) * 1.3, 0.2, math.sin(angle) * 1.3)
		logBetween(foot, Vector3.new(0, 2.3, 0), 0.6, { Name = "Log", Material = Enum.Material.Wood, Color = COLORS.Log, Parent = m })
	end
end

function FALLBACKS.Lantern(m: Model)
	post(CFrame.new(), 5, 0.5, { Name = "Post", Material = Enum.Material.Wood, Color = COLORS.Trim, Parent = m })
	block({ Name = "Glass", Size = Vector3.new(1, 1.3, 1), CFrame = CFrame.new(0, 5.35, 0),
		Material = Enum.Material.Neon, Color = Config.Atmosphere.LanternColor, CastShadow = false, Parent = m })
	block({ Name = "Cap", Size = Vector3.new(1.3, 0.3, 1.3), CFrame = CFrame.new(0, 6.1, 0),
		Material = Enum.Material.Metal, Color = COLORS.Metal, Parent = m })
end

function FALLBACKS.LogBench(m: Model)
	block({ Name = "Seat", Shape = Enum.PartType.Cylinder, Size = Vector3.new(8, 1.3, 1.3), CFrame = CFrame.new(0, 1.85, 0),
		Material = Enum.Material.Wood, Color = COLORS.Log, Parent = m })
	for _, side in ipairs({ -1, 1 }) do
		block({ Name = "Leg", Size = Vector3.new(1.1, 1.3, 1.6), CFrame = CFrame.new(side * 2.9, 0.65, 0),
			Material = Enum.Material.Wood, Color = COLORS.Trunk, Parent = m })
	end
end

function FALLBACKS.Crate(m: Model)
	block({ Name = "Crate", Size = Vector3.new(3, 3, 3), CFrame = CFrame.new(0, 1.5, 0),
		Material = Enum.Material.WoodPlanks, Color = COLORS.Deck, Parent = m })
end

function FALLBACKS.Nest(m: Model)
	local h = PROP_HEIGHTS.Nest
	post(CFrame.new(), h, 6, { Name = "Twigs", Material = Enum.Material.Wood, Color = COLORS.Twig, Parent = m })
	disc(CFrame.new(0, h + 0.01, 0), 4.4, 0.06, { Name = "Hollow", Material = Enum.Material.Fabric, Color = COLORS.NestHollow, Parent = m })
end

function FALLBACKS.Totem(m: Model)
	local h = PROP_HEIGHTS.Totem
	local blockHeight = (h - 1.2) / 4
	for i = 1, 4 do
		block({ Name = "Carving", Size = Vector3.new(3.4, blockHeight, 3.4),
			CFrame = CFrame.new(0, blockHeight * (i - 0.5), 0) * CFrame.Angles(0, if i % 2 == 0 then 0.08 else -0.05, 0),
			Material = Enum.Material.Wood, Color = COLORS.TotemPaint[((i - 1) % #COLORS.TotemPaint) + 1], Parent = m })
	end
	block({ Name = "Wings", Size = Vector3.new(9, 0.9, 1.6), CFrame = CFrame.new(0, blockHeight * 3.4, 0.2),
		Material = Enum.Material.Wood, Color = COLORS.TotemPaint[3], Parent = m })
	block({ Name = "Cap", Size = Vector3.new(2.4, 1.2, 2.4), CFrame = CFrame.new(0, h - 0.6, 0),
		Material = Enum.Material.Wood, Color = COLORS.TotemPaint[1], Parent = m })
	for _, side in ipairs({ -1, 1 }) do
		block({ Name = "Eye", Size = Vector3.new(0.6, 0.45, 0.2), CFrame = CFrame.new(side * 0.8, blockHeight * 3.6, -1.75),
			Material = Enum.Material.Neon, Color = Config.Map.MushroomColor, CastShadow = false, Parent = m })
	end
end

function FALLBACKS.Signpost(m: Model)
	local h = PROP_HEIGHTS.Signpost
	post(CFrame.new(), h, 0.6, { Name = "Post", Material = Enum.Material.Wood, Color = COLORS.Trim, Parent = m })
	block({ Name = "Board", Size = Vector3.new(4, 1.2, 0.25), CFrame = CFrame.new(1.2, h * 0.8, 0),
		Material = Enum.Material.WoodPlanks, Color = COLORS.Wall, Parent = m })
end

--- Scales every part in `m` about `pivot` by `factor`, keeping the model's
--- pivot exactly where it was (the bottom centre).
local function scaleModel(m: Model, pivot: CFrame, factor: number)
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") then
			local relative = pivot:ToObjectSpace(d.CFrame)
			d.Size *= factor
			d.CFrame = pivot * (CFrame.new(relative.Position * factor) * relative.Rotation)
		elseif d:IsA("Attachment") then
			d.Position *= factor
		end
	end
	-- A template's pivot is stored as an offset from its PrimaryPart, which
	-- just moved; re-aim it at the original pivot.
	local primary = m.PrimaryPart
	if primary then
		primary.PivotOffset = primary.CFrame:ToObjectSpace(pivot)
	else
		m.WorldPivot = pivot
	end
end

--- Places prop `id` standing on `cf`. See the section comment above.
local function prop(id: string, cf: CFrame, options: PropOptions?, parent: Instance): Model
	local opts: PropOptions = options or {}
	local nominal = PROP_HEIGHTS[id] or 4
	local template = ItemVisuals.GetTemplate("Props", id)
	local m: Model
	local natural = nominal
	if template then
		m = template:Clone()
		natural = m:GetExtentsSize().Y
		meshProps += 1
	else
		m = Instance.new("Model")
		local build = FALLBACKS[id]
		if build then
			build(m)
		end
		m.WorldPivot = CFrame.new()
		fallbackProps += 1
	end
	m.Name = opts.Name or id

	local collide = opts.Collide == true
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = collide
			d.CanQuery = collide
			d.CanTouch = false
		end
	end

	local target = (opts.Height or nominal) * (opts.Scale or 1)
	local factor = if natural > 0 then target / natural else 1
	if math.abs(factor - 1) > 0.01 then
		scaleModel(m, m:GetPivot(), factor)
	end
	m:PivotTo(cf)
	m.Parent = parent
	return m
end

--- A lantern on a post, lit. Returns the model.
local function lantern(baseCf: CFrame, height: number, parent: Instance): Model
	local a = Config.Atmosphere
	local m = prop("Lantern", baseCf, { Height = height, Collide = true }, parent)
	local glow = attachAt(m, (baseCf * CFrame.new(0, height * 0.89, 0)).Position, "LightAttachment")
	if glow then
		pointLight(glow, a.LanternColor, a.LanternRange, a.LanternBrightness)
	end
	return m
end

--- A lit campfire: the Campfire prop (stone ring + logs) plus flames,
--- embers and a warm light on an invisible "FireCore" part, which is
--- returned (the hub tags it so sounds can play there).
local function campfire(cf: CFrame, scale: number, parent: Instance, shadows: boolean?): BasePart
	local a = Config.Atmosphere
	local fireModel = prop("Campfire", cf, { Scale = scale, Collide = true }, parent)
	local core = block({
		Name = "FireCore",
		Size = Vector3.new(1, 1, 1) * scale,
		CFrame = cf * CFrame.new(0, 1 * scale, 0),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		CastShadow = false,
		Parent = fireModel,
	})
	local fire = Instance.new("Fire")
	fire.Size = math.min(30, 3.2 * scale)
	fire.Heat = 9
	fire.Color = Color3.fromRGB(255, 140, 60)
	fire.SecondaryColor = Color3.fromRGB(255, 60, 20)
	fire.Parent = core
	pointLight(core, a.CampfireColor, a.CampfireRange * scale, a.CampfireBrightness, shadows)

	-- Embers drifting up out of the fire.
	local embers = Instance.new("ParticleEmitter")
	embers.Name = "Embers"
	embers.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	embers.Color = ColorSequence.new(COLORS.Ember)
	embers.LightEmission = 1
	embers.LightInfluence = 0
	embers.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.18 * scale), NumberSequenceKeypoint.new(1, 0) })
	embers.Lifetime = NumberRange.new(1.2, 2.4)
	embers.Rate = 4 * scale
	embers.Speed = NumberRange.new(2, 5)
	embers.SpreadAngle = Vector2.new(20, 20)
	embers.Acceleration = Vector3.new(0, 1.5, 0)
	embers.Drag = 1
	embers.Parent = core
	return core
end

--------------------------------------------------------------------------
-- Ground, hub, paths
--------------------------------------------------------------------------

local function plotAngle(index: number): number
	return (index - 1) / Config.Plot.Count * TAU
end

--- Unit vector on the ground plane at `angle` (radians from +X toward +Z).
local function dirAt(angle: number): Vector3
	return Vector3.new(math.cos(angle), 0, math.sin(angle))
end

--- Path `index` runs from the hub edge to plot `index`'s door.
local function pathEnds(index: number): (Vector3, Vector3)
	local dir = dirAt(plotAngle(index))
	return dir * (Config.Map.HubRadius - 4), dir * (Config.Plot.RingRadius - Config.Plot.Size.Z / 2 - 2)
end

--- Deer trails start between two plots and run out through The Wilds.
local function trailAngles(): { number }
	local list = {}
	local every = math.max(1, math.floor(Config.Map.TrailEvery))
	for i = 1, Config.Plot.Count, every do
		table.insert(list, plotAngle(i) + 0.5 / Config.Plot.Count * TAU)
	end
	return list
end

local function trailFrom(): number
	return Config.Plot.RingRadius - 10
end

local function trailTo(): number
	return Config.Map.WildsOuterRadius + 30
end

--- Distance on the ground plane from `p` to the segment a-b.
local function distanceToSegment(p: Vector3, a: Vector3, b: Vector3): number
	local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	local ap = Vector3.new(p.X - a.X, 0, p.Z - a.Z)
	local len2 = ab:Dot(ab)
	local t = if len2 > 0 then math.clamp(ap:Dot(ab) / len2, 0, 1) else 0
	return (ap - ab * t).Magnitude
end

local function nearTrail(pos: Vector3, clearance: number): boolean
	for _, angle in ipairs(trailAngles()) do
		local dir = dirAt(angle)
		if distanceToSegment(pos, dir * trailFrom(), dir * trailTo()) < clearance then
			return true
		end
	end
	return false
end

local function nearPath(pos: Vector3, clearance: number): boolean
	for i = 1, Config.Plot.Count do
		local a, b = pathEnds(i)
		if distanceToSegment(pos, a, b) < clearance then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------
-- Terrain
-- Rebuilt from scratch every boot: Clear(), then a few coarse fills
-- (FillBlock / FillCylinder / FillBall), which is fast. "Painting" a
-- material onto flat ground fills one voxel layer (y -4..0) that is already
-- solid, so it changes the material without changing the shape.
--------------------------------------------------------------------------

type HillBall = { Center: Vector3, Radius: number }
local hillBalls: { HillBall } = {}

local terrainParams = RaycastParams.new()
terrainParams.FilterType = Enum.RaycastFilterType.Include

--- Height of the terrain surface at (x, z), worked out from the hill balls
--- (flat ground is y = 0).
local function groundHeight(x: number, z: number): number
	local best = 0
	for _, ball in ipairs(hillBalls) do
		local dx, dz = x - ball.Center.X, z - ball.Center.Z
		local d2 = dx * dx + dz * dz
		local r2 = ball.Radius * ball.Radius
		if d2 < r2 then
			local y = ball.Center.Y + math.sqrt(r2 - d2)
			if y > best then
				best = y
			end
		end
	end
	return best
end

--- Where to stand something at (x, z): the real terrain surface if a ray
--- finds it close to where the maths says, else the maths.
local function surfaceY(x: number, z: number): number
	local guess = groundHeight(x, z)
	if guess <= 0 then
		return 0
	end
	local hit = Workspace:Raycast(Vector3.new(x, guess + 25, z), Vector3.new(0, -50, 0), terrainParams)
	if hit and math.abs(hit.Position.Y - guess) < 3 then
		return hit.Position.Y
	end
	return guess
end

local function buildTerrain(rng: Random): number
	local started = os.clock()
	local m = Config.Map
	local terrain = Workspace.Terrain
	terrain:Clear()
	table.clear(hillBalls)
	terrainParams.FilterDescendantsInstances = { terrain }

	for name, color in pairs(m.TerrainColors) do
		local ok, material = pcall(function()
			return (Enum.Material :: any)[name]
		end)
		if ok and material then
			terrain:SetMaterialColor(material, color)
		else
			warn("[SAC/Map] Config.Map.TerrainColors has an unknown material: " .. tostring(name))
		end
	end

	-- Base slab of grass, top surface exactly at y = 0.
	terrain:FillBlock(CFrame.new(0, -TERRAIN_DEPTH / 2 - VOXEL_OFFSET, 0), Vector3.new(m.GroundSize, TERRAIN_DEPTH, m.GroundSize), Enum.Material.Grass)

	local function paintDisc(x: number, z: number, radius: number, material: Enum.Material)
		terrain:FillCylinder(CFrame.new(x, -PAINT_DEPTH / 2 - VOXEL_OFFSET, z), PAINT_DEPTH, radius, material)
	end
	local function paintStrip(a: Vector3, b: Vector3, width: number, material: Enum.Material)
		local from, to = Vector3.new(a.X, 0, a.Z), Vector3.new(b.X, 0, b.Z)
		local length = (to - from).Magnitude
		if length < 0.1 then
			return
		end
		terrain:FillBlock(CFrame.lookAt((from + to) / 2, to) * CFrame.new(0, -PAINT_DEPTH / 2 - VOXEL_OFFSET, 0),
			Vector3.new(width, PAINT_DEPTH, length), material)
		paintDisc(to.X, to.Z, width / 2, material) -- rounded end
	end

	-- Variety: leafy grass and bare-earth patches over the meadow and woods
	-- (only where players can see them up close: inside the boundary).
	local patchReach = math.min(m.GroundSize / 2, m.BoundaryRadius)
	for _ = 1, m.TerrainPatchCount do
		local pos = dirAt(rng:NextNumber(0, TAU)) * rng:NextNumber(m.HubRadius + 12, patchReach)
		local radius = rng:NextNumber(7, 20)
		local roll = rng:NextNumber()
		local material = if roll < 0.7 then Enum.Material.LeafyGrass
			elseif roll < 0.85 then Enum.Material.Ground
			else Enum.Material.Mud
		paintDisc(pos.X, pos.Z, radius, material)
	end

	-- Gentle hills in The Wilds only: clusters of terrain balls poking a few
	-- studs out of the ground. Every ball's footprint stays outside the plot
	-- ring, and hills keep off the deer trails. (The same random numbers are
	-- drawn whatever is skipped, so the layout never shifts.)
	for _ = 1, m.HillCount do
		local center = dirAt(rng:NextNumber(0, TAU)) * rng:NextNumber(m.HillMinRadius, m.WildsOuterRadius + 40)
		local balls = rng:NextInteger(m.HillBallsEach[1], m.HillBallsEach[2])
		local clearOfTrails = not nearTrail(center, m.HillSpread + m.HillBallRadius[2] + m.TrailWidth)
		for _ = 1, balls do
			local ox = rng:NextNumber(-m.HillSpread, m.HillSpread)
			local oz = rng:NextNumber(-m.HillSpread, m.HillSpread)
			local radius = rng:NextNumber(m.HillBallRadius[1], m.HillBallRadius[2])
			local cap = math.min(rng:NextNumber(m.HillBallCap[1], m.HillBallCap[2]), radius)
			local material = if rng:NextNumber() < 0.3 then Enum.Material.LeafyGrass else Enum.Material.Grass
			local c = Vector3.new(center.X + ox, cap - radius, center.Z + oz)
			local footprint = math.sqrt(radius * radius - (radius - cap) ^ 2)
			if clearOfTrails and Vector3.new(c.X, 0, c.Z).Magnitude - footprint >= m.WildsInnerRadius - 12 then
				terrain:FillBall(c - Vector3.new(0, VOXEL_OFFSET, 0), radius, material)
				table.insert(hillBalls, { Center = c, Radius = radius })
			end
		end
	end

	-- A ring of taller mounds just past the boundary frames the edge.
	for i = 1, m.EdgeBermBalls do
		local angle = (i / m.EdgeBermBalls) * TAU + rng:NextNumber(-0.05, 0.05)
		local radius = m.EdgeBermRadius * rng:NextNumber(0.85, 1.15)
		local cap = math.min(m.EdgeBermCap * rng:NextNumber(0.7, 1.2), radius)
		local c = dirAt(angle) * m.EdgeBermDistance + Vector3.new(0, cap - radius, 0)
		terrain:FillBall(c - Vector3.new(0, VOXEL_OFFSET, 0), radius, Enum.Material.Grass)
		table.insert(hillBalls, { Center = c, Radius = radius })
	end

	-- Hub: cobblestone rim, dirt clearing, cobblestone plaza round the egg
	-- belt, and a dirt circle round the fire.
	paintDisc(0, 0, m.HubRadius, Enum.Material.Cobblestone)
	paintDisc(0, 0, m.HubRadius - 3, Enum.Material.Ground)
	paintDisc(0, 0, m.HubPlazaRadius, Enum.Material.Cobblestone)
	paintDisc(0, 0, m.HubFireCircleRadius, Enum.Material.Ground)

	-- Bare earth under each plot (stops grass blades poking through the deck).
	local p = Config.Plot
	for i = 1, p.Count do
		terrain:FillBlock(MapBuilder.GetPlotCFrame(i) * CFrame.new(0, -PAINT_DEPTH / 2 - VOXEL_OFFSET, 0),
			Vector3.new(p.Size.X + 6, PAINT_DEPTH, p.Size.Z + 6), Enum.Material.Ground)
	end

	-- Dirt paths from the hub to every door, and deer trails into the woods.
	for i = 1, p.Count do
		local a, b = pathEnds(i)
		paintStrip(a, b, m.PathWidth, Enum.Material.Ground)
	end
	for _, angle in ipairs(trailAngles()) do
		local dir = dirAt(angle)
		paintStrip(dir * trailFrom(), dir * trailTo(), m.TrailWidth, Enum.Material.Ground)
	end

	-- Rotated fills (plot paint, paths) smear up into the voxel above the
	-- ground, which piled dirt on top of the camp decks and buried the home
	-- pads (nobody could claim an egg). Empty every voxel from the one centred
	-- on y = 0 upward (y -2 .. 10) across the flat middle of the map, so the
	-- surface there is exactly y = 0. Hills only start beyond
	-- WildsInnerRadius - 12, so this never touches them.
	terrain:FillCylinder(CFrame.new(0, 4, 0), 12, m.WildsInnerRadius - 14, Enum.Material.Air)

	return (os.clock() - started) * 1000
end

local function buildCabin(name: string, cf: CFrame, signText: string, shopId: string, parent: Instance)
	-- `cf` is the floor centre; LookVector faces the hub (open front).
	local cabin = model(name, parent)
	local width, depth, wallHeight = 24, 18, 11
	local logDiameter = 1.4

	block({ Name = "Floor", Size = Vector3.new(width, 1, depth), CFrame = cf * CFrame.new(0, 0.5, 0),
		Material = Enum.Material.WoodPlanks, Color = COLORS.Deck, Parent = cabin })

	-- Log walls: stacked horizontal logs on the back and both sides, with
	-- the ends poking past the corners like a real log cabin.
	local rows = math.ceil(wallHeight / (logDiameter * 0.9))
	for r = 0, rows - 1 do
		local y = 1 + logDiameter / 2 + r * (wallHeight - logDiameter) / (rows - 1)
		local shade = COLORS.LogShades[(r % #COLORS.LogShades) + 1]
		block({ Name = "BackWall", Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(width + 1.6, logDiameter, logDiameter),
			CFrame = cf * CFrame.new(0, y, depth / 2 - logDiameter / 2),
			Material = Enum.Material.Wood, Color = shade, Parent = cabin })
		for _, side in ipairs({ -1, 1 }) do
			block({ Name = "SideWall", Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(depth + 1.6, logDiameter, logDiameter),
				CFrame = cf * CFrame.new(side * (width / 2 - logDiameter / 2), y + logDiameter * 0.45, 0) * CFrame.Angles(0, math.pi / 2, 0),
				Material = Enum.Material.Wood, Color = shade, Parent = cabin })
		end
	end
	-- Porch posts holding up the front of the roof.
	for _, side in ipairs({ -1, 1 }) do
		post(cf * CFrame.new(side * (width / 2 - 0.8), 1, -depth / 2 + 0.8), wallHeight + 1.5, 1.2,
			{ Name = "PorchPost", Material = Enum.Material.Wood, Color = COLORS.Trim, Parent = cabin })
	end
	-- Stone chimney with a lazy curl of smoke.
	local chimneyHeight = wallHeight + 9
	block({ Name = "Chimney", Size = Vector3.new(3, chimneyHeight, 3),
		CFrame = cf * CFrame.new(width / 2 - 4, 1 + chimneyHeight / 2, depth / 2 - 2),
		Material = Enum.Material.Cobblestone, Color = COLORS.Stone, Parent = cabin })
	local chimneyTop = block({ Name = "ChimneyTop", Size = Vector3.new(1, 1, 1),
		CFrame = cf * CFrame.new(width / 2 - 4, 1.5 + chimneyHeight, depth / 2 - 2), Transparency = 1,
		CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false, Parent = cabin })
	local smoke = Instance.new("Smoke")
	smoke.Color = Color3.fromRGB(150, 150, 160)
	smoke.Opacity = 0.08
	smoke.RiseVelocity = 3
	smoke.Size = 3
	smoke.Parent = chimneyTop

	gable(cf * CFrame.new(0, 1 + wallHeight + 5.2, 0), width + 2, depth / 2 + 1, 30, 0.8,
		{ Name = "Roof", Material = Enum.Material.WoodPlanks, Color = COLORS.Roof }, cabin)

	local counter = block({
		Name = "Counter",
		Size = Vector3.new(width - 6, 3.5, 2),
		CFrame = cf * CFrame.new(0, 1 + 1.75, -depth / 2 + 3),
		Material = Enum.Material.WoodPlanks,
		Color = COLORS.Trim,
		Parent = cabin,
	})
	counter:SetAttribute("ShopId", shopId)
	CollectionService:AddTag(counter, Config.Tags.ShopBooth)

	-- Opens the shop panel on the client (UpgradeShopController). Buying itself
	-- goes through a remote that re-checks you're at this counter.
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ShopPrompt"
	prompt.ActionText = "Browse"
	prompt.ObjectText = signText
	prompt.HoldDuration = Config.Prompts.ShopOpenHold
	prompt.MaxActivationDistance = Config.Prompts.MaxActivationDistance
	prompt.RequiresLineOfSight = Config.Prompts.RequiresLineOfSight
	prompt:SetAttribute("ShopId", shopId)
	prompt.Parent = counter

	local sign = block({
		Name = "Sign",
		Size = Vector3.new(16, 3.5, 0.5),
		CFrame = cf * CFrame.new(0, 1 + wallHeight + 1, -depth / 2 - 0.5),
		Material = Enum.Material.Wood,
		Color = COLORS.Trim,
		Parent = cabin,
	})
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.Parent = sign
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Fantasy
	label.TextScaled = true
	label.TextColor3 = COLORS.SignText
	label.Text = signText
	label.Parent = gui

	lantern(cf * CFrame.new(width / 2 + 2, 0, -depth / 2), 7, cabin)
	lantern(cf * CFrame.new(-width / 2 - 2, 0, -depth / 2), 7, cabin)
end

--------------------------------------------------------------------------
-- Egg belt (circles the campfire; see Shared/BeltPath for the motion)
--------------------------------------------------------------------------

local function signLabel(part: BasePart, face: Enum.NormalId, text: string, font: Enum.Font?)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.Parent = part
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = font or Enum.Font.Fantasy
	label.TextScaled = true
	label.TextColor3 = COLORS.SignText
	label.Text = text
	label.Parent = gui
end

--- One burrow: a mossy stone mound, flush with the belt, with a glowing
--- hole the eggs climb out of (start) or sink into (end).
local function burrow(which: string, angle: number, glow: Color3, parent: Instance)
	local b = Config.Belt
	local center = BeltPath.PointAt(angle, 0)
	local burrowModel = model("Burrow_" .. which, parent)
	local diameter = b.Width + 3
	post(CFrame.new(center), b.Height, diameter, {
		Name = "Mound", Material = Enum.Material.Slate, Color = COLORS.Rock, Parent = burrowModel,
	})
	post(CFrame.new(center), b.Height - 0.3, diameter + 0.8, {
		Name = "Moss", Material = Enum.Material.Grass, Color = Color3.fromRGB(52, 84, 50), Parent = burrowModel,
	})
	local rim = disc(CFrame.new(center + Vector3.new(0, b.Height + 0.03, 0)), 4.2, 0.06, {
		Name = "Rim", Material = Enum.Material.Neon, Color = glow,
		CanCollide = false, CanQuery = false, CanTouch = false, Parent = burrowModel,
	})
	local hole = disc(CFrame.new(center + Vector3.new(0, b.Height + 0.05, 0)), 3.5, 0.06, {
		Name = "Hole", Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(8, 6, 12),
		CanCollide = false, CanQuery = false, CanTouch = false, Parent = burrowModel,
	})
	hole:SetAttribute("Which", which)
	CollectionService:AddTag(hole, Config.Tags.Burrow)

	local light = Instance.new("PointLight")
	light.Color = glow
	light.Range = 12
	light.Brightness = 1.6
	light.Shadows = false
	light.Parent = rim

	-- A slow wisp of mist, always on.
	local mist = Instance.new("ParticleEmitter")
	mist.Name = "Mist"
	mist.Texture = "rbxasset://textures/particles/smoke_main.dds"
	mist.Color = ColorSequence.new(glow)
	mist.LightEmission = 0.6
	mist.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(1, 1) })
	mist.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 3) })
	mist.Lifetime = NumberRange.new(1.5, 2.5)
	mist.Rate = 3
	mist.Speed = NumberRange.new(1, 2)
	mist.SpreadAngle = Vector2.new(15, 15)
	mist.Parent = hole

	-- Burst the client fires as an egg comes out / goes in.
	local puff = Instance.new("ParticleEmitter")
	puff.Name = "Puff"
	puff.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	puff.Color = ColorSequence.new(glow)
	puff.LightEmission = 1
	puff.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 0) })
	puff.Lifetime = NumberRange.new(0.5, 0.9)
	puff.Rate = 0
	puff.Speed = NumberRange.new(4, 8)
	puff.SpreadAngle = Vector2.new(60, 60)
	puff.Parent = hole
end

local function buildOddsBoard(cf: CFrame, parent: Instance)
	-- `cf` is ground level, facing the reader.
	local board = model("OddsBoard", parent)
	for _, side in ipairs({ -1, 1 }) do
		post(cf * CFrame.new(side * 3.6, 0, 0), 8.5, 0.7, { Name = "Leg", Material = Enum.Material.Wood, Color = COLORS.Trim, Parent = board })
	end
	local panel = block({
		Name = "Panel", Size = Vector3.new(8, 6.5, 0.4), CFrame = cf * CFrame.new(0, 5.2, 0),
		Material = Enum.Material.WoodPlanks, Color = COLORS.Wall, Parent = board,
	})

	local total = 0
	for _, eggId in ipairs(Config.EggOrder) do
		total += Config.Belt.EggWeights[eggId] or 0
	end
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.Parent = panel
	local list = Instance.new("Frame")
	list.Size = UDim2.fromScale(1, 1)
	list.BackgroundTransparency = 1
	list.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = list
	local rows = #Config.EggOrder + 1
	local function row(order: number, text: string, color: Color3, font: Enum.Font)
		local label = Instance.new("TextLabel")
		label.LayoutOrder = order
		label.Size = UDim2.fromScale(0.9, 1 / rows)
		label.BackgroundTransparency = 1
		label.Font = font
		label.TextScaled = true
		label.TextColor3 = color
		label.Text = text
		label.Parent = list
	end
	row(0, "EGG BELT ODDS", COLORS.SignText, Enum.Font.Fantasy)
	for i, eggId in ipairs(Config.EggOrder) do
		local weight = Config.Belt.EggWeights[eggId] or 0
		local pct = if total > 0 then weight / total * 100 else 0
		local pctText = if pct >= 1 then string.format("%.0f%%", pct) else string.format("%.1f%%", pct)
		row(i, string.format("%s  %s", Config.Eggs[eggId].Name, pctText),
			Config.Belt.LabelColors[eggId] or COLORS.SignText, Enum.Font.GothamBold)
	end
end

local function buildBelt(parent: Instance)
	local b = Config.Belt
	local belt = model("EggBelt", parent)
	local segments = 64
	local start, arc = BeltPath.StartAngle, BeltPath.Arc
	local segmentAngle = arc / segments
	local bedHeight = b.Height - 0.2

	for i = 1, segments do
		local angle = start + (i - 0.5) * segmentAngle
		local base = BeltPath.FrameAt(angle, 0)
		local chord = 2 * b.Radius * math.sin(segmentAngle / 2)
		-- The bed: a solid wooden base you can stand on, the slats glide over it.
		block({
			Name = "Bed", Size = Vector3.new(b.Width, bedHeight, chord * 1.06),
			CFrame = base * CFrame.new(0, bedHeight / 2, 0),
			Material = Enum.Material.WoodPlanks, Color = COLORS.Log, Parent = belt,
		})
		block({
			Name = "Track", Size = Vector3.new(b.Width - 0.6, 0.05, chord * 1.06),
			CFrame = base * CFrame.new(0, bedHeight + 0.025, 0),
			Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(70, 66, 62),
			CanCollide = false, CanQuery = false, CanTouch = false, Parent = belt,
		})
		-- Iron rails along both edges.
		for _, side in ipairs({ -1, 1 }) do
			local railRadius = b.Radius + side * (b.Width / 2 + 0.15)
			local railChord = 2 * railRadius * math.sin(segmentAngle / 2)
			local railPoint = BeltPath.Center + Vector3.new(math.cos(angle) * railRadius, 0, math.sin(angle) * railRadius)
			block({
				Name = "Rail", Size = Vector3.new(0.35, 0.6, railChord * 1.08),
				CFrame = CFrame.lookAt(railPoint, railPoint + Vector3.new(-math.sin(angle), 0, math.cos(angle)))
					* CFrame.new(0, b.Height + 0.15, 0),
				Material = Enum.Material.Metal, Color = Color3.fromRGB(64, 66, 72), Parent = belt,
			})
		end
	end

	-- Slats. Built here once; each client slides them round the belt.
	local slats = folder("Slats", belt)
	local slatLength = BeltPath.SlatLength()
	for i = 1, b.SlatCount do
		local slat = block({
			Name = "Slat", Size = Vector3.new(b.Width - 0.8, 0.12, slatLength),
			CFrame = BeltPath.SlatCFrame(i, 0),
			Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(30, 30, 34),
			CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false, Parent = slats,
		})
		slat:SetAttribute("Index", i)
		CollectionService:AddTag(slat, Config.Tags.BeltSlat)
	end

	burrow("Start", BeltPath.StartAngle, Color3.fromRGB(120, 255, 170), belt)
	burrow("End", BeltPath.EndAngle, Color3.fromRGB(200, 130, 255), belt)

	-- An arch over the gap between the burrows: the way in to the campfire.
	local gapCenter = math.rad(b.GapCenterDegrees)
	local gapHalf = math.rad(360 - b.ArcDegrees) / 2
	local postAngle = gapHalf - 0.07
	local archHeight = 12
	local postPoints = {}
	for _, side in ipairs({ -1, 1 }) do
		local a = gapCenter + side * postAngle
		local p = BeltPath.PointAt(a, 0)
		table.insert(postPoints, p)
		post(CFrame.new(p), archHeight, 1.6, { Name = "ArchPost", Material = Enum.Material.Wood, Color = COLORS.Log, Parent = belt })
		lantern(CFrame.new(p + (p - BeltPath.Center).Unit * 1.6), 6, belt)
	end
	local mid = (postPoints[1] + postPoints[2]) / 2
	local outward = (mid - BeltPath.Center) * Vector3.new(1, 0, 1)
	outward = outward.Unit
	local span = (postPoints[1] - postPoints[2]).Magnitude
	local beamCf = CFrame.lookAt(mid + Vector3.new(0, archHeight, 0), mid + Vector3.new(0, archHeight, 0) + outward)
	block({
		Name = "ArchBeam", Size = Vector3.new(span + 3, 1.4, 1.4), CFrame = beamCf,
		Material = Enum.Material.Wood, Color = COLORS.Log, Parent = belt,
	})
	local sign = block({
		Name = "ArchSign", Size = Vector3.new(11, 2.6, 0.4), CFrame = beamCf * CFrame.new(0, -2.2, 0),
		Material = Enum.Material.Wood, Color = COLORS.Trim, Parent = belt,
	})
	-- Readable from both sides of the arch.
	signLabel(sign, Enum.NormalId.Back, "EGG BELT")
	signLabel(sign, Enum.NormalId.Front, "EGG BELT")

	-- Odds board outside the ring, just beside the arch, facing out.
	local boardAngle = gapCenter + gapHalf + math.rad(14)
	local boardPos = BeltPath.PointAt(boardAngle, 0) + Vector3.new(math.cos(boardAngle), 0, math.sin(boardAngle)) * 9
	buildOddsBoard(CFrame.lookAt(boardPos, boardPos + (boardPos - BeltPath.Center) * Vector3.new(1, 0, 1)), belt)
end

--------------------------------------------------------------------------
-- Hub extras: leaderboards and the welcome arch
--------------------------------------------------------------------------

--- A pointed stake top: a block turned 45 degrees about the local X axis,
--- so it reads as a point from either side of a row running along Z.
local function stakeTip(topCf: CFrame, diameter: number, props: Props): Part
	local side = diameter / math.sqrt(2)
	props.Size = Vector3.new(diameter * 0.92, side, side)
	props.CFrame = topCf * CFrame.Angles(math.rad(45), 0, 0)
	return block(props)
end

--- One wooden leaderboard. `cf` is ground level, LookVector toward the
--- reader. LeaderboardService fills the "List" frame on its screen.
local function buildLeaderboard(key: string, cf: CFrame, parent: Instance)
	local lb = Config.Leaderboards
	local spec = (lb.Boards :: any)[key]
	local board = model("Board_" .. key, parent)
	local width, height, bottom = 9, 11, 1.6

	for _, side in ipairs({ -1, 1 }) do
		post(cf * CFrame.new(side * (width / 2 + 0.45), 0, 0.15), bottom + height + 1.2, 1.1,
			{ Name = "Post", Material = Enum.Material.Wood, Color = COLORS.LogShades[2], Parent = board })
	end
	local screen = block({
		Name = "Screen", Size = Vector3.new(width, height, 0.5), CFrame = cf * CFrame.new(0, bottom + height / 2, 0),
		Material = Enum.Material.WoodPlanks, Color = COLORS.Wall, Parent = board,
	})
	gable(cf * CFrame.new(0, bottom + height + 1.5, 0.15), width + 2.6, 1.3, 28, 0.3,
		{ Name = "Roof", Material = Enum.Material.WoodPlanks, Color = COLORS.Roof }, board)
	screen:SetAttribute("Board", key)
	CollectionService:AddTag(screen, lb.BoardTag)

	local gui = Instance.new("SurfaceGui")
	gui.Name = "BoardGui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	gui.LightInfluence = 0 -- readable at night without a lamp
	gui.MaxDistance = 150
	gui.Parent = screen

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Position = UDim2.fromScale(0.04, 0.02)
	title.Size = UDim2.fromScale(0.92, 0.1)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.Fantasy
	title.TextScaled = true
	title.TextColor3 = COLORS.SignText
	title.Text = if spec then spec.Title else key
	title.Parent = gui

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.Position = UDim2.fromScale(0.04, 0.12)
	subtitle.Size = UDim2.fromScale(0.92, 0.05)
	subtitle.BackgroundTransparency = 1
	subtitle.Font = Enum.Font.GothamMedium
	subtitle.TextScaled = true
	subtitle.TextColor3 = Color3.fromRGB(220, 198, 164)
	subtitle.Text = if spec then spec.Subtitle else ""
	subtitle.Parent = gui

	local list = Instance.new("Frame")
	list.Name = "List"
	list.Position = UDim2.fromScale(0.04, 0.19)
	list.Size = UDim2.fromScale(0.92, 0.79)
	list.BackgroundTransparency = 1
	list.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.Name = "Layout"
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0.006, 0)
	layout.Parent = list

	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.Position = UDim2.fromScale(0.08, 0.4)
	status.Size = UDim2.fromScale(0.84, 0.16)
	status.BackgroundTransparency = 1
	status.Font = Enum.Font.GothamMedium
	status.TextScaled = true
	status.TextWrapped = true
	status.TextColor3 = Color3.fromRGB(220, 198, 164)
	status.Text = "Gathering the top campers..."
	status.Parent = gui
end

--- The "STEAL A CRYPTID" welcome arch. `cf`: ground centre, LookVector
--- toward the hub.
local function buildWelcomeArch(cf: CFrame, parent: Instance)
	local arch = model("WelcomeArch", parent)
	local span, height = 24, 16
	local a = Config.Atmosphere
	for _, side in ipairs({ -1, 1 }) do
		local base = cf * CFrame.new(side * span / 2, 0, 0)
		post(base, height, 2.4, { Name = "ArchPost", Material = Enum.Material.Wood, Color = COLORS.LogShades[1], Parent = arch })
		stakeTip(base * CFrame.new(0, height, 0) * CFrame.Angles(0, math.pi / 2, 0), 2.4,
			{ Name = "PostTip", Material = Enum.Material.Wood, Color = COLORS.LogShades[1], Parent = arch })
		-- A lantern hanging from the beam beside each post.
		local hang = base * CFrame.new(-side * 2, height - 6.4, 0)
		block({ Name = "Chain", Size = Vector3.new(0.15, 3.4, 0.15), CFrame = hang * CFrame.new(0, 2.4, 0),
			Material = Enum.Material.Metal, Color = COLORS.Metal, CanCollide = false, Parent = arch })
		local lamp = block({ Name = "Lantern", Size = Vector3.new(1.1, 1.4, 1.1), CFrame = hang,
			Material = Enum.Material.Neon, Color = a.LanternColor, CanCollide = false, CastShadow = false, Parent = arch })
		pointLight(lamp, a.LanternColor, a.LanternRange, a.LanternBrightness)
	end
	local left = (cf * CFrame.new(-span / 2 - 1.5, height - 1.6, 0)).Position
	local right = (cf * CFrame.new(span / 2 + 1.5, height - 1.6, 0)).Position
	logBetween(left, right, 1.8, { Name = "Beam", Material = Enum.Material.Wood, Color = COLORS.LogShades[2], Parent = arch })
	local sign = block({
		Name = "ArchSign", Size = Vector3.new(span - 6, 3.6, 0.5), CFrame = cf * CFrame.new(0, height - 4.3, 0),
		Material = Enum.Material.WoodPlanks, Color = COLORS.Trim, Parent = arch,
	})
	signLabel(sign, Enum.NormalId.Front, "STEAL A CRYPTID")
	signLabel(sign, Enum.NormalId.Back, "STEAL A CRYPTID")
end

local function buildHub(map: Folder, rng: Random)
	local hub = model("Hub", map, true)
	local m = Config.Map
	local r = m.HubRadius

	-- The fire everyone gathers round. Its core part is tagged so the
	-- sound controller can play a crackle there.
	local core = campfire(CFrame.new(0, 0, 0), 1.6, hub, true)
	CollectionService:AddTag(core, m.HubCampfireTag)

	-- Log benches round the fire, inside the belt ring (leaving the belt
	-- gap at GapCenterDegrees clear).
	local gapAngle = math.rad(Config.Belt.GapCenterDegrees)
	for i = 1, 5 do
		local angle = gapAngle + math.rad(36) + (i - 1) * TAU / 5
		local pos = dirAt(angle) * 12.5
		prop("LogBench", CFrame.lookAt(pos, Vector3.zero), { Collide = true }, hub)
	end

	-- The Upgrades cabin sits between two plot paths, facing the fire. (Eggs
	-- come from the belt round the fire, not a shop.)
	local half = 0.5 / Config.Plot.Count * TAU
	local function cabinCf(angle: number): CFrame
		local pos = Vector3.new(math.cos(angle), 0, math.sin(angle)) * (r - 22)
		return CFrame.lookAt(pos, Vector3.new(0, 0, 0))
	end
	buildBelt(hub)
	buildCabin("UpgradeShop", cabinCf(plotAngle(1 + Config.Plot.Count / 2) + half), "UPGRADES", "Upgrades", hub)

	-- Lanterns on posts round the cobblestone plaza.
	for i = 1, 8 do
		local angle = math.rad(22.5 + 45 * i)
		lantern(CFrame.lookAt(dirAt(angle) * (m.HubPlazaRadius + 1), Vector3.zero), 6.5, hub)
	end

	-- A lantern and a signpost at each path mouth.
	for i = 1, Config.Plot.Count do
		local lanternPos = dirAt(plotAngle(i) + math.rad(6)) * (r - 4)
		lantern(CFrame.lookAt(lanternPos, Vector3.zero), 7, hub)
		local signPos = dirAt(plotAngle(i) - math.rad(6)) * (r - 4)
		prop("Signpost", CFrame.lookAt(signPos, Vector3.zero), { Collide = true }, hub)
	end

	-- Benches further out, facing the fire.
	for _, degrees in ipairs({ 54, 162, 234, 306 }) do
		local pos = dirAt(gapAngle + math.rad(degrees - 90)) * 42
		prop("LogBench", CFrame.lookAt(pos, Vector3.zero), { Collide = true }, hub)
	end

	-- The carved Totem opposite the spawn side, flanked by lanterns.
	local totemAngle = gapAngle + math.pi
	local totemPos = dirAt(totemAngle) * 46
	prop("Totem", CFrame.lookAt(totemPos, Vector3.zero), { Collide = true }, hub)
	local totemSide = Vector3.new(-math.sin(totemAngle), 0, math.cos(totemAngle))
	for _, side in ipairs({ -1, 1 }) do
		lantern(CFrame.lookAt(totemPos + totemSide * side * 6, Vector3.zero), 6, hub)
	end

	-- The welcome arch on the spawn side.
	local archPos = dirAt(gapAngle) * 58
	buildWelcomeArch(CFrame.lookAt(archPos, Vector3.zero), hub)

	-- Three leaderboards between the first two paths, Order left to right.
	local boards = folder("Leaderboards", hub)
	local boardAngle = plotAngle(1) + half
	local boardSide = Vector3.new(-math.sin(boardAngle), 0, math.cos(boardAngle))
	local order = Config.Leaderboards.Order
	for i, key in ipairs(order) do
		local pos = dirAt(boardAngle) * 56 + boardSide * (i - (#order + 1) / 2) * 10.5
		buildLeaderboard(key, CFrame.lookAt(pos, Vector3.zero), boards)
	end

	-- A stone edge round the clearing, with gaps where the paths leave.
	local steps = 45
	for k = 0, steps - 1 do
		local angle = k / steps * TAU
		local yaw = rng:NextNumber(0, TAU)
		local scale = rng:NextNumber(0.6, 1.1)
		local clear = true
		for i = 1, Config.Plot.Count do
			local diff = math.abs((angle - plotAngle(i) + math.pi) % TAU - math.pi)
			if diff < math.rad(9) then
				clear = false
			end
		end
		if clear then
			prop("Rock", CFrame.new(dirAt(angle) * (r - 1.2)) * CFrame.Angles(0, yaw, 0), { Scale = scale, Collide = true }, hub)
		end
	end

	-- Fireflies drifting over the whole clearing.
	fireflies(CFrame.new(0, 6, 0), Vector3.new(r * 1.8, 8, r * 1.8), m.FireflyRate * 2, hub)

	-- Fallback spawn. PlotService moves each player to their own plot.
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "HubSpawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Size = Vector3.new(8, 1, 8)
	spawn.CFrame = CFrame.new(0, 0.5, Config.Belt.Radius + 16)
	spawn.Material = Enum.Material.Slate
	spawn.Color = COLORS.Rock
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.Parent = hub
	local decal = spawn:FindFirstChildOfClass("Decal")
	if decal then
		decal:Destroy()
	end
end

--- Lantern posts along each hub-to-plot path, alternating sides. (The
--- path itself is painted into the terrain by buildTerrain.)
local function buildPaths(map: Folder)
	local paths = folder("Paths", map)
	local m = Config.Map
	for i = 1, Config.Plot.Count do
		local a, b = pathEnds(i)
		local dir = (b - a).Unit
		local side = Vector3.new(-dir.Z, 0, dir.X)
		local length = (b - a).Magnitude
		local k = 1
		while k * m.PathLanternSpacing < length - 12 do
			local along = a + dir * (k * m.PathLanternSpacing)
			local s = if k % 2 == 0 then 1 else -1
			lantern(CFrame.lookAt(along + side * s * (m.PathWidth / 2 + 2), along), 6, paths)
			k += 1
		end
	end
end

--------------------------------------------------------------------------
-- Plots
--------------------------------------------------------------------------

--- The pivot CFrame of plot `index` (centre, ground level, facing the hub).
function MapBuilder.GetPlotCFrame(index: number): CFrame
	local angle = plotAngle(index)
	local pos = Vector3.new(math.cos(angle), 0, math.sin(angle)) * Config.Plot.RingRadius
	return CFrame.lookAt(pos, Vector3.new(0, 0, 0))
end

--- Local positions of each nest, in plot space.
function MapBuilder.GetNestOffsets(): { Vector3 }
	local p = Config.Plot
	local cols = p.NestGridColumns
	local rows = math.ceil(p.MaxNests / cols)
	local offsets = {}
	for k = 1, p.MaxNests do
		local c = (k - 1) % cols
		local r = math.floor((k - 1) / cols)
		local x = (c - (cols - 1) / 2) * p.NestSpacing
		-- Grid sits toward the back half, leaving room inside the door.
		local z = (r - (rows - 1) / 2) * p.NestSpacing + p.NestSpacing / 2
		offsets[k] = Vector3.new(x, p.FloorHeight, z)
	end
	return offsets
end

--- One nest: a low earth mound (Base, the PrimaryPart, holding ItemAnchor),
--- a glowing ring round it (Glow, lit by SetNestActive), the twig Nest prop,
--- and a stone Lid that covers the bowl while the nest is locked.
local function buildNest(plotCf: CFrame, plotIndex: number, nestIndex: number, offset: Vector3, parent: Instance, rng: Random)
	local nest = model("Nest_" .. nestIndex, parent)
	local cf = plotCf * CFrame.new(offset)

	local base = disc(cf * CFrame.new(0, MOUND_HEIGHT / 2, 0), 8.2, MOUND_HEIGHT, {
		Name = "Base", Material = Enum.Material.Ground, Color = COLORS.Mound, Parent = nest,
	})
	disc(cf * CFrame.new(0, MOUND_HEIGHT + 0.03, 0), 7.4, 0.06, {
		Name = "Glow", Material = Enum.Material.Neon, Color = Config.Rebirth.NestGlowColors[1],
		Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false, Parent = nest,
	})
	prop("Nest", cf * CFrame.new(0, MOUND_HEIGHT, 0) * CFrame.Angles(0, rng:NextNumber(0, TAU), 0), { Name = "Twigs" }, nest)
	-- The lid rests ON the rim (not down inside the bowl), so it shows on the
	-- solid part-built nest too.
	disc(cf * CFrame.new(0, MOUND_HEIGHT + PROP_HEIGHTS.Nest + 0.1, 0), 4.6, 0.3, {
		Name = "Lid", Material = Enum.Material.Slate, Color = Config.Map.NestLidColor,
		CanCollide = false, CanQuery = false, CanTouch = false, Parent = nest,
	})
	-- Where an egg or creature stands (NestService.GetItemCFrame). The base
	-- disc is rotated so its local +X is world up.
	local anchor = Instance.new("Attachment")
	anchor.Name = "ItemAnchor"
	anchor.Position = Vector3.new(ITEM_HEIGHT_ABOVE_DECK - MOUND_HEIGHT / 2, 0, 0)
	anchor.Parent = base

	nest.PrimaryPart = base
	nest:SetAttribute("PlotIndex", plotIndex)
	nest:SetAttribute("NestIndex", nestIndex)
	nest:SetAttribute("Active", false)
	CollectionService:AddTag(nest, Config.Tags.Nest)
end

--- A row of palisade logs (pointed tops) standing on the wall line from
--- `a` to `b` (plot-local, at deck height), plus a rail on each face.
local function palisadeRow(plotCf: CFrame, a: Vector3, b: Vector3, rng: Random, parent: Instance)
	local m = Config.Map
	local h = Config.Plot.WallHeight
	local diameter = m.PalisadeLogDiameter
	local length = (b - a).Magnitude
	local count = math.max(1, math.floor(length / m.PalisadeLogSpacing))
	local rowCf = plotCf * CFrame.lookAt(a, b) -- -Z runs along the row
	for i = 1, count do
		local along = (i - 0.5) * length / count
		local height = h + rng:NextNumber(0, 0.8)
		local shade = COLORS.LogShades[rng:NextInteger(1, #COLORS.LogShades)]
		local baseCf = rowCf * CFrame.new(0, 0, -along)
		post(baseCf, height, diameter, { Name = "Log", Material = Enum.Material.Wood, Color = shade, CanTouch = false, Parent = parent })
		stakeTip(baseCf * CFrame.new(0, height, 0), diameter,
			{ Name = "Tip", Material = Enum.Material.Wood, Color = shade, CanTouch = false, Parent = parent })
	end
	-- Rails: one low on the outside, one high on the inside. Which side is
	-- "inside" doesn't matter much from a distance; both read as bracing.
	for _, rail in ipairs({ { 0.3, 1 }, { 0.72, -1 } }) do
		local offset = Vector3.new(rail[2] * (diameter / 2 + 0.3), h * rail[1], 0)
		logBetween((rowCf * CFrame.new(offset)).Position, (rowCf * CFrame.new(offset + Vector3.new(0, 0, -length))).Position, 0.9,
			{ Name = "Rail", Material = Enum.Material.Wood, Color = COLORS.Trim, CanTouch = false, Parent = parent })
	end
end

local function buildPlot(index: number, plotsFolder: Folder)
	local p = Config.Plot
	local cf = MapBuilder.GetPlotCFrame(index)
	local half = p.Size.X / 2
	local depthHalf = p.Size.Z / 2
	local floorTop = p.FloorHeight
	local h, t, d = p.WallHeight, p.WallThickness, p.DoorWidth
	-- Each plot has its own random stream, so plots differ a little but a
	-- change to one never reshuffles the rest of the world.
	local rng = Random.new(Config.Map.Seed + index)

	local plot = model("Plot_" .. index, plotsFolder, true)

	-- Packed-dirt camp ground (the deck players stand on).
	local floor = block({
		Name = "Floor",
		Size = Vector3.new(p.Size.X, floorTop, p.Size.Z),
		CFrame = cf * CFrame.new(0, floorTop / 2, 0),
		Material = Enum.Material.Ground,
		Color = COLORS.CampGround,
		Parent = plot,
	})
	plot.PrimaryPart = floor

	-- A ramp up to the deck outside the doorway.
	local step = Instance.new("WedgePart")
	step.Name = "DoorStep"
	step.Anchored = true
	step.Size = Vector3.new(d + 4, floorTop, 3)
	step.CFrame = cf * CFrame.new(0, floorTop / 2, -depthHalf - 1.5)
	step.Material = Enum.Material.Ground
	step.Color = COLORS.CampGround
	step.Parent = plot

	-- Grass tufts round the edges of the camp.
	for _, patch in ipairs({ { -33, 2, 9 }, { 33, -6, 10 }, { -32, -28, 7 }, { 32, 14, 8 }, { -8, 36, 8 } }) do
		disc(cf * CFrame.new(patch[1], floorTop + 0.03, patch[2]), patch[3], 0.06, {
			Name = "Grass", Material = Enum.Material.Grass, Color = COLORS.CampGrass,
			CanCollide = false, CanQuery = false, CanTouch = false, Parent = plot,
		})
	end

	-- Walls: back, two sides, and a front wall split around the doorway.
	-- These solid cores are the real barrier (WallHeight, above jump
	-- height); the palisade logs are dressed round them.
	local walls = folder("Walls", plot)
	local wallY = floorTop + h / 2
	local wallProps = { Material = Enum.Material.Wood, Color = COLORS.WallCore, Parent = walls }
	local function wall(name: string, size: Vector3, offset: Vector3)
		local props = table.clone(wallProps)
		props.Name = name
		props.Size = size
		props.CFrame = cf * CFrame.new(offset)
		block(props)
	end
	wall("Back", Vector3.new(p.Size.X, h, t), Vector3.new(0, wallY, depthHalf - t / 2))
	wall("Left", Vector3.new(t, h, p.Size.Z), Vector3.new(-half + t / 2, wallY, 0))
	wall("Right", Vector3.new(t, h, p.Size.Z), Vector3.new(half - t / 2, wallY, 0))
	local frontSegment = (p.Size.X - d) / 2
	wall("FrontLeft", Vector3.new(frontSegment, h, t), Vector3.new(-(d / 2 + frontSegment / 2), wallY, -depthHalf + t / 2))
	wall("FrontRight", Vector3.new(frontSegment, h, t), Vector3.new(d / 2 + frontSegment / 2, wallY, -depthHalf + t / 2))

	-- Log palisade on the wall lines. The front rows stop at the gate posts.
	local palisade = folder("Palisade", plot)
	local backZ, frontZ, sideX = depthHalf - t / 2, -depthHalf + t / 2, half - t / 2
	local gateX = d / 2 + 2.6
	palisadeRow(cf, Vector3.new(-sideX, floorTop, backZ), Vector3.new(sideX, floorTop, backZ), rng, palisade)
	palisadeRow(cf, Vector3.new(-sideX, floorTop, frontZ), Vector3.new(-sideX, floorTop, backZ), rng, palisade)
	palisadeRow(cf, Vector3.new(sideX, floorTop, backZ), Vector3.new(sideX, floorTop, frontZ), rng, palisade)
	palisadeRow(cf, Vector3.new(-sideX, floorTop, frontZ), Vector3.new(-gateX, floorTop, frontZ), rng, palisade)
	palisadeRow(cf, Vector3.new(gateX, floorTop, frontZ), Vector3.new(sideX, floorTop, frontZ), rng, palisade)

	-- Door: the server keeps it open (non-colliding, invisible). Each client
	-- draws and collides it locally while the plot is locked — except for
	-- the owner, who walks through. PlotService also ejects intruders by
	-- position, so this part is never the security boundary.
	local door = block({
		Name = "Door",
		Size = Vector3.new(d, h, t),
		CFrame = cf * CFrame.new(0, wallY, -depthHalf + t / 2),
		Material = Enum.Material.ForceField,
		Color = COLORS.Door,
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		CastShadow = false,
		Parent = plot,
	})
	door:SetAttribute("PlotIndex", index)
	CollectionService:AddTag(door, Config.Tags.Door)

	-- The gate: two thick posts with pointed tops, a crossbeam above the
	-- camp sign, and a lantern hanging inside each post.
	local gate = folder("Gate", plot)
	local a = Config.Atmosphere
	local gateHeight = h + 6
	for _, side in ipairs({ -1, 1 }) do
		local postCf = cf * CFrame.new(side * (d / 2 + 1.3), floorTop, -depthHalf + t / 2)
		post(postCf, gateHeight, 2.6, { Name = "DoorPost", Material = Enum.Material.Wood, Color = COLORS.LogShades[3], Parent = gate })
		stakeTip(postCf * CFrame.new(0, gateHeight, 0) * CFrame.Angles(0, math.pi / 2, 0), 2.6,
			{ Name = "PostTip", Material = Enum.Material.Wood, Color = COLORS.LogShades[3], Parent = gate })
		local hang = postCf * CFrame.new(-side * 2.2, h - 0.6, -0.4)
		block({ Name = "Chain", Size = Vector3.new(0.15, 1.6, 0.15), CFrame = hang * CFrame.new(0, 1.4, 0),
			Material = Enum.Material.Metal, Color = COLORS.Metal, CanCollide = false, CanQuery = false, Parent = gate })
		local lamp = block({
			Name = "Lantern",
			Size = Vector3.new(1.1, 1.3, 1.1),
			CFrame = hang,
			Material = Enum.Material.Neon,
			Color = a.LanternColor,
			CanCollide = false,
			CanQuery = false,
			CastShadow = false,
			Parent = gate,
		})
		pointLight(lamp, a.LanternColor, a.LanternRange, a.LanternBrightness)
	end
	local beamY = floorTop + h + 4.9
	logBetween((cf * CFrame.new(-d / 2 - 3.2, beamY, -depthHalf + t / 2)).Position,
		(cf * CFrame.new(d / 2 + 3.2, beamY, -depthHalf + t / 2)).Position, 1.6,
		{ Name = "Crossbeam", Material = Enum.Material.Wood, Color = COLORS.LogShades[2], Parent = gate })

	local sign = block({
		Name = "Sign",
		Size = Vector3.new(d + 4, 3.5, 0.6),
		CFrame = cf * CFrame.new(0, floorTop + h + 2.5, -depthHalf - 0.2),
		Material = Enum.Material.Wood,
		Color = COLORS.Trim,
		Parent = plot,
	})
	local surface = Instance.new("SurfaceGui")
	surface.Name = "SignGui"
	surface.Face = Enum.NormalId.Front
	surface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surface.PixelsPerStud = 40
	surface.Parent = sign
	local ownerLabel = Instance.new("TextLabel")
	ownerLabel.Name = "Label"
	ownerLabel.Size = UDim2.fromScale(1, 1)
	ownerLabel.BackgroundTransparency = 1
	ownerLabel.Font = Enum.Font.Fantasy
	ownerLabel.TextScaled = true
	ownerLabel.TextColor3 = COLORS.SignText
	ownerLabel.Parent = surface
	-- Floating name so you can spot a camp from across the map. Hidden on
	-- vacant plots (SetPlotSign), and kept small so it doesn't crowd the HUD.
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "OwnerBillboard"
	billboard.Size = UDim2.fromOffset(190, 30)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
	billboard.MaxDistance = 220
	billboard.LightInfluence = 0
	billboard.Enabled = false
	billboard.Parent = sign
	local billboardLabel = Instance.new("TextLabel")
	billboardLabel.Name = "Label"
	billboardLabel.Size = UDim2.fromScale(1, 1)
	billboardLabel.BackgroundTransparency = 1
	billboardLabel.Font = Enum.Font.GothamBold
	billboardLabel.TextScaled = true
	billboardLabel.TextStrokeTransparency = 0.4
	billboardLabel.TextColor3 = COLORS.SignText
	billboardLabel.Parent = billboard

	-- Home pad just inside the door: a glowing circle in a ring of stones.
	-- Carried eggs and stolen loot are claimed by touching it (StealService).
	local padCf = cf * CFrame.new(0, floorTop, -depthHalf + 8)
	disc(padCf * CFrame.new(0, 0.05, 0), 11.5, 0.1, {
		Name = "PadStone", Material = Enum.Material.Slate, Color = COLORS.Stone,
		CanCollide = false, CanQuery = false, CanTouch = false, Parent = plot,
	})
	local pad = disc(padCf * CFrame.new(0, 0.15, 0), 9, 0.3, {
		Name = "Pad",
		Material = Enum.Material.Neon,
		Color = Config.Map.HomePadColor,
		Transparency = 0.45,
		CanCollide = false,
		CastShadow = false,
		Parent = plot,
	})
	pad:SetAttribute("PlotIndex", index)
	CollectionService:AddTag(pad, Config.Tags.PlotPad)
	for i = 1, 6 do
		local angle = (i / 6) * TAU + 0.3
		block({ Name = "PadRock", Shape = Enum.PartType.Ball, Size = Vector3.one * 1.3,
			CFrame = padCf * CFrame.new(math.cos(angle) * 5.4, 0.35, math.sin(angle) * 5.4),
			Material = Enum.Material.Slate, Color = COLORS.Rock, CanCollide = false, CanQuery = false, CanTouch = false, Parent = plot })
	end
	-- "HOME PAD" sign on a stake beside it, facing the door.
	local stakeCf = padCf * CFrame.new(7.6, 0, 0)
	post(stakeCf, 3.4, 0.4, { Name = "HomeSignStake", Material = Enum.Material.Wood, Color = COLORS.Trim, Parent = plot })
	local homeSign = block({
		Name = "HomeSign", Size = Vector3.new(4.4, 1.5, 0.25), CFrame = stakeCf * CFrame.new(0, 2.7, -0.3),
		Material = Enum.Material.WoodPlanks, Color = COLORS.Wall, CanCollide = false, Parent = plot,
	})
	signLabel(homeSign, Enum.NormalId.Front, "HOME PAD")

	-- Lock button: a big red button on a stump, inside the door on the left.
	local stumpCf = cf * CFrame.new(-16, floorTop, -depthHalf + 8)
	prop("Stump", stumpCf, { Height = 3, Collide = true, Name = "LockStump" }, plot)
	disc(stumpCf * CFrame.new(0, 3.08, 0), 2.4, 0.16, {
		Name = "LockButtonRim", Material = Enum.Material.Metal, Color = COLORS.Metal, Parent = plot,
	})
	local button = disc(stumpCf * CFrame.new(0, 3.35, 0), 1.8, 0.5, {
		Name = "LockButton",
		Material = Enum.Material.Neon,
		Color = COLORS.LockButton,
		Parent = plot,
	})
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "LockPrompt"
	prompt.ActionText = "Lock Camp"
	prompt.ObjectText = "Camp Lock"
	prompt.HoldDuration = 0
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.MaxActivationDistance = Config.Prompts.MaxActivationDistance
	prompt.RequiresLineOfSight = Config.Prompts.RequiresLineOfSight
	prompt.Parent = button

	-- Where the owner spawns: inside the door, facing the nests.
	block({
		Name = "Spawn",
		Size = Vector3.new(4, 0.2, 4),
		CFrame = cf * CFrame.new(0, floorTop + 0.1, -depthHalf + 16) * CFrame.Angles(0, math.pi, 0),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Parent = plot,
	})

	-- Nests
	local nests = folder("Nests", plot)
	for k, offset in ipairs(MapBuilder.GetNestOffsets()) do
		buildNest(cf, index, k, offset, nests, rng)
	end

	-- Decor (plot-local x, z; all outside the nest grid and the door area):
	-- a tent and supply crates back-left, a campfire with benches
	-- back-right, lanterns in the front corners, glowing mushrooms by the
	-- walls.
	local decor = folder("Decor", plot)
	local function at(x: number, z: number): CFrame
		return cf * CFrame.new(x, floorTop, z)
	end
	local function facing(x: number, z: number, tx: number, tz: number): CFrame
		local from = (cf * CFrame.new(x, floorTop, z)).Position
		local to = (cf * CFrame.new(tx, floorTop, tz)).Position
		return CFrame.lookAt(from, to)
	end
	prop("Tent", facing(-30, 30, 0, 4), { Collide = true }, decor)
	prop("Crate", at(-35, 18) * CFrame.Angles(0, rng:NextNumber(-0.3, 0.3), 0), { Collide = true }, decor)
	prop("Crate", at(-35, 18) * CFrame.new(0, 3, 0) * CFrame.Angles(0, rng:NextNumber(0.4, 0.9), 0), { Scale = 0.75, Collide = true }, decor)
	prop("Crate", at(-31.2, 16.5) * CFrame.Angles(0, rng:NextNumber(-0.5, 0.5), 0), { Scale = 0.85, Collide = true }, decor)
	campfire(at(30, 30), 1, decor)
	prop("LogBench", facing(30, 23.5, 30, 30), { Collide = true }, decor)
	prop("LogBench", facing(23.5, 30, 30, 30), { Collide = true }, decor)
	for _, side in ipairs({ -1, 1 }) do
		lantern(facing(side * 35, -24, 0, 0), 6, decor)
	end
	for _, spot in ipairs({ { 36, 8 }, { -36, -8 }, { 36, -14 }, { -36, 6 } }) do
		prop("Mushroom", at(spot[1], spot[2]) * CFrame.Angles(0, rng:NextNumber(0, TAU), 0),
			{ Scale = rng:NextNumber(0.7, 1.1) }, decor)
	end
	prop("Rock", at(35, 1) * CFrame.Angles(0, rng:NextNumber(0, TAU), 0), { Scale = 0.8, Collide = true }, decor)
	prop("Bush", at(-35, -16) * CFrame.Angles(0, rng:NextNumber(0, TAU), 0), {}, decor)

	plot:SetAttribute("PlotIndex", index)
	plot:SetAttribute("OwnerUserId", 0)
	plot:SetAttribute("OwnerName", "")
	plot:SetAttribute("LockedUntil", 0)
	plot:SetAttribute("LockCooldownUntil", 0)
	CollectionService:AddTag(plot, Config.Tags.Plot)

	MapBuilder.SetPlotSign(plot, nil)
	return plot
end

--- Updates a plot's sign and billboard. `ownerName` nil = vacant.
function MapBuilder.SetPlotSign(plot: Model, ownerName: string?)
	local sign = plot:FindFirstChild("Sign")
	if not sign then
		return
	end
	local text = if ownerName then (ownerName .. "'s Camp") else "Vacant Campsite"
	for _, guiName in ipairs({ "SignGui", "OwnerBillboard" }) do
		local gui = sign:FindFirstChild(guiName)
		local label = gui and gui:FindFirstChild("Label") :: TextLabel?
		if label then
			label.Text = text
			label.TextTransparency = if ownerName then 0 else 0.4
		end
	end
	local billboard = sign:FindFirstChild("OwnerBillboard") :: BillboardGui?
	if billboard then
		billboard.Enabled = ownerName ~= nil
	end
end

--- Shows a nest as usable (glowing ring, open bowl) or locked (no glow,
--- a stone lid over the bowl).
function MapBuilder.SetNestActive(nest: Model, active: boolean, glowColor: Color3?)
	nest:SetAttribute("Active", active)
	local glow = nest:FindFirstChild("Glow") :: BasePart?
	if glow then
		glow.Transparency = if active then Config.Map.NestGlowActiveTransparency else 1
		if glowColor then
			glow.Color = glowColor
		end
	end
	local lid = nest:FindFirstChild("Lid") :: BasePart?
	if lid then
		lid.Transparency = if active then 1 else 0
	end
end

--------------------------------------------------------------------------
-- The Wilds and boundary
--------------------------------------------------------------------------

-- Everything scattered outdoors is recorded in a coarse grid so placement
-- can keep things apart cheaply (hundreds of objects, thousands of tries).
local GRID_CELL = 24
local MAX_PLACED_RADIUS = 8
type Placed = { Position: Vector3, Radius: number }
local placedGrid: { [string]: { Placed } } = {}

local function isFree(pos: Vector3, radius: number): boolean
	local cx, cz = math.floor(pos.X / GRID_CELL), math.floor(pos.Z / GRID_CELL)
	local reach = math.ceil((radius + MAX_PLACED_RADIUS) / GRID_CELL)
	for gx = cx - reach, cx + reach do
		for gz = cz - reach, cz + reach do
			local cell = placedGrid[gx .. "," .. gz]
			if cell then
				for _, other in ipairs(cell) do
					local dx, dz = other.Position.X - pos.X, other.Position.Z - pos.Z
					local min = other.Radius + radius
					if dx * dx + dz * dz < min * min then
						return false
					end
				end
			end
		end
	end
	return true
end

local function markPlaced(pos: Vector3, radius: number)
	local key = math.floor(pos.X / GRID_CELL) .. "," .. math.floor(pos.Z / GRID_CELL)
	local cell = placedGrid[key]
	if not cell then
		cell = {}
		placedGrid[key] = cell
	end
	table.insert(cell, { Position = pos, Radius = radius })
end

--- True if `pos` is on (or within `margin` of) any plot.
local function insidePlot(pos: Vector3, margin: number): boolean
	local size = Config.Plot.Size
	for i = 1, Config.Plot.Count do
		local localPos = MapBuilder.GetPlotCFrame(i):PointToObjectSpace(Vector3.new(pos.X, 0, pos.Z))
		if math.abs(localPos.X) < size.X / 2 + margin and math.abs(localPos.Z) < size.Z / 2 + margin then
			return true
		end
	end
	return false
end

--- Tries up to 25x `count` random spots in the ring inner..outer (uniform
--- over area), placing at each spot that is free and passes `ok`.
local function scatter(rng: Random, count: number, inner: number, outer: number, radius: number,
	ok: ((Vector3) -> boolean)?, place: (Vector3) -> ())
	local placed, attempts = 0, 0
	while placed < count and attempts < count * 25 do
		attempts += 1
		local angle = rng:NextNumber(0, TAU)
		local distance = math.sqrt(rng:NextNumber(inner * inner, outer * outer))
		local pos = Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
		if isFree(pos, radius) and (ok == nil or ok(pos)) then
			markPlaced(pos, radius)
			place(pos)
			placed += 1
		end
	end
end

--- A standing spot on the terrain at `pos`, sunk a little so nothing floats
--- on a slope, with a random yaw.
local function groundCf(pos: Vector3, sink: number, rng: Random): CFrame
	return CFrame.new(pos.X, surfaceY(pos.X, pos.Z) - sink, pos.Z) * CFrame.Angles(0, rng:NextNumber(0, TAU), 0)
end

--- A pine or round tree. Leaves are walk-through; the trunk is solid
--- (`collide`) so players can't walk through it.
local function placeTree(pos: Vector3, rng: Random, parent: Instance, collide: boolean)
	local m = Config.Map
	local id = if rng:NextNumber() < m.PineTreeShare then "PineTree" else "RoundTree"
	local scale = rng:NextNumber(m.TreeScale[1], m.TreeScale[2])
	local cf = groundCf(pos, 0.6, rng)
	local tree = prop(id, cf, { Scale = scale, Name = "Tree" }, parent)
	tree.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	if collide then
		-- A part-built tree's own trunk is the collider (one part fewer, and
		-- visible, so SightingService's "something solid here?" check sees
		-- it). Mesh trees get an invisible trunk-sized collider instead.
		local trunk = tree:FindFirstChild("Trunk")
		if trunk and trunk:IsA("BasePart") then
			trunk.CanCollide = true
			trunk.CanQuery = true
		else
			post(cf, 10 * scale, 2 * scale, {
				Name = "TrunkCollider", Transparency = 1, CastShadow = false, CanTouch = false, Parent = tree,
			})
		end
	end
end

--- A glowing mushroom cluster; every MushroomLightEvery-th also lights
--- the ground round it.
local mushroomCount = 0
local function placeMushroom(cf: CFrame, scale: number, parent: Instance)
	local m = Config.Map
	local cluster = prop("Mushroom", cf, { Scale = scale }, parent)
	mushroomCount += 1
	if m.MushroomLightEvery > 0 and mushroomCount % m.MushroomLightEvery == 0 then
		local glow = attachAt(cluster, (cf * CFrame.new(0, 1.5 * scale, 0)).Position, "LightAttachment")
		if glow then
			pointLight(glow, m.MushroomColor, m.MushroomLightRange, m.MushroomLightBrightness)
		end
	end
end

local function buildWilds(map: Folder, rng: Random)
	local m = Config.Map
	local wilds = folder("Wilds", map)
	table.clear(placedGrid)
	mushroomCount = 0

	local inner, outer = m.WildsInnerRadius, m.WildsOuterRadius
	local meadowInner = m.HubRadius + 8

	-- The Wilds: anywhere in the ring except the deer trails.
	local function wildOk(radius: number): (Vector3) -> boolean
		return function(pos: Vector3): boolean
			return not nearTrail(pos, m.TrailWidth / 2 + radius + 2)
		end
	end
	-- The meadow between hub and plots: keep off the plots, paths and trails.
	local function meadowOk(radius: number): (Vector3) -> boolean
		return function(pos: Vector3): boolean
			return not insidePlot(pos, 6 + radius)
				and not nearPath(pos, m.PathWidth / 2 + radius + 3)
				and not nearTrail(pos, m.TrailWidth / 2 + radius + 2)
		end
	end

	-- Trees first (the biggest), then smaller things fill the gaps. The
	-- tree spacing leaves walkable lanes everywhere.
	local treeRadius = m.TreeMinSpacing / 2
	scatter(rng, m.WildsTreeCount, inner, outer, treeRadius, wildOk(treeRadius), function(pos)
		placeTree(pos, rng, wilds, true)
	end)

	-- A few trees in each gap between neighbouring plots.
	local gapHalfWidth = 14
	for i = 1, Config.Plot.Count do
		local gapAngle = plotAngle(i) + 0.5 / Config.Plot.Count * TAU
		local outward = dirAt(gapAngle)
		local sideways = Vector3.new(-outward.Z, 0, outward.X)
		for _ = 1, m.BetweenPlotTreesEach do
			local pos = outward * (Config.Plot.RingRadius + rng:NextNumber(-30, 40))
				+ sideways * rng:NextNumber(-gapHalfWidth, gapHalfWidth)
			if isFree(pos, treeRadius) and not insidePlot(pos, 4) and not nearTrail(pos, m.TrailWidth / 2 + treeRadius) then
				markPlaced(pos, treeRadius)
				placeTree(pos, rng, wilds, true)
			end
		end
	end

	-- The meadow: a light scatter so the walk between camps isn't bare.
	scatter(rng, m.MeadowTreeCount, meadowInner, inner, treeRadius, meadowOk(treeRadius), function(pos)
		placeTree(pos, rng, wilds, true)
	end)
	scatter(rng, m.MeadowBushCount, meadowInner, inner, 2.5, meadowOk(2.5), function(pos)
		prop("Bush", groundCf(pos, 0.3, rng), { Scale = rng:NextNumber(0.8, 1.4) }, wilds)
	end)
	scatter(rng, m.MeadowRockCount, meadowInner, inner, 2.5, meadowOk(2.5), function(pos)
		prop("Rock", groundCf(pos, 0.4, rng), { Scale = rng:NextNumber(0.6, 1.2), Collide = true }, wilds)
	end)
	scatter(rng, m.MeadowMushroomCount, meadowInner, inner, 2, meadowOk(2), function(pos)
		placeMushroom(groundCf(pos, 0.1, rng), rng:NextNumber(0.7, 1.2), wilds)
	end)

	-- The Wilds floor.
	scatter(rng, m.WildsBoulderCount, inner, outer, 6, wildOk(6), function(pos)
		prop("Boulder", groundCf(pos, 1, rng), { Scale = rng:NextNumber(0.7, 1.3), Collide = true }, wilds)
	end)
	scatter(rng, m.WildsRockCount, inner, outer, 2.5, wildOk(2.5), function(pos)
		prop("Rock", groundCf(pos, 0.4, rng), { Scale = rng:NextNumber(0.6, 1.4), Collide = true }, wilds)
	end)
	scatter(rng, m.WildsLogCount, inner, outer, 5.5, wildOk(5.5), function(pos)
		prop("FallenLog", groundCf(pos, 0.5, rng), { Scale = rng:NextNumber(0.8, 1.2), Collide = true }, wilds)
	end)
	scatter(rng, m.WildsStumpCount, inner, outer, 2, wildOk(2), function(pos)
		prop("Stump", groundCf(pos, 0.3, rng), { Scale = rng:NextNumber(0.8, 1.3), Collide = true }, wilds)
	end)
	scatter(rng, m.WildsBushCount, inner, outer, 2.5, wildOk(2.5), function(pos)
		prop("Bush", groundCf(pos, 0.3, rng), { Scale = rng:NextNumber(0.8, 1.6) }, wilds)
	end)
	scatter(rng, m.WildsMushroomCount, inner, outer, 2, wildOk(2), function(pos)
		placeMushroom(groundCf(pos, 0.1, rng), rng:NextNumber(0.8, 1.4), wilds)
	end)

	-- The tree line past The Wilds (on the berm). Only trees inside the
	-- boundary need colliders.
	scatter(rng, m.EdgeTreeCount, outer + 12, m.EdgeTreeOuterRadius, treeRadius, nil, function(pos)
		placeTree(pos, rng, wilds, pos.Magnitude < m.BoundaryRadius + 4)
	end)

	-- Fireflies drifting between the trees.
	for _ = 1, m.WildsFireflyPatches do
		local pos = dirAt(rng:NextNumber(0, TAU)) * rng:NextNumber(inner, outer)
		fireflies(CFrame.new(pos.X, surfaceY(pos.X, pos.Z) + 5, pos.Z), Vector3.new(70, 10, 70), m.FireflyRate, wilds)
	end
end

local function buildBoundary(map: Folder)
	local m = Config.Map
	local boundary = folder("Boundary", map)
	local segments = 48
	local length = TAU * m.BoundaryRadius / segments + 2
	for i = 1, segments do
		local angle = (i / segments) * TAU
		local pos = Vector3.new(math.cos(angle) * m.BoundaryRadius, m.BoundaryHeight / 2, math.sin(angle) * m.BoundaryRadius)
		block({
			Name = "Wall",
			Size = Vector3.new(length, m.BoundaryHeight, 2),
			CFrame = CFrame.lookAt(pos, Vector3.new(0, pos.Y, 0)),
			Transparency = 1,
			CanQuery = false,
			CanTouch = false,
			CastShadow = false,
			Parent = boundary,
		})
	end
end

--------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------

--------------------------------------------------------------------------
-- Lighting
--------------------------------------------------------------------------

--- Applies Config.Atmosphere to Lighting: moonlit night, fog that hides
--- the map edge, stars and a big moon (built-in Sky properties only),
--- bloom so fire and neon glow, and a light colour grade. Safe to run
--- repeatedly: it reuses the effects already there.
function MapBuilder.ApplyAtmosphere()
	local Lighting = game:GetService("Lighting")
	local a = Config.Atmosphere
	Lighting.ClockTime = a.ClockTime
	Lighting.GeographicLatitude = a.GeographicLatitude
	Lighting.Brightness = a.Brightness
	Lighting.Ambient = a.Ambient
	Lighting.OutdoorAmbient = a.OutdoorAmbient
	Lighting.ColorShift_Top = a.ColorShiftTop
	Lighting.ColorShift_Bottom = a.ColorShiftBottom
	Lighting.ExposureCompensation = a.ExposureCompensation
	Lighting.EnvironmentDiffuseScale = a.EnvironmentDiffuseScale
	Lighting.EnvironmentSpecularScale = a.EnvironmentSpecularScale
	Lighting.FogColor = a.FogColor

	local function ensureOfClass(className: string, name: string): Instance
		local existing = Lighting:FindFirstChildOfClass(className)
		if existing then
			return existing
		end
		local created = Instance.new(className)
		created.Name = name
		created.Parent = Lighting
		return created
	end

	local atmosphere = ensureOfClass("Atmosphere", "Atmosphere") :: Atmosphere
	atmosphere.Density = a.AtmosphereDensity
	atmosphere.Offset = a.AtmosphereOffset
	atmosphere.Haze = a.AtmosphereHaze
	atmosphere.Color = a.FogColor
	atmosphere.Decay = a.FogDecay
	atmosphere.Glare = 0

	local sky = ensureOfClass("Sky", "Sky") :: Sky
	sky.CelestialBodiesShown = true
	sky.StarCount = a.StarCount
	sky.MoonAngularSize = a.MoonAngularSize

	local bloom = ensureOfClass("BloomEffect", "Bloom") :: BloomEffect
	bloom.Enabled = true
	bloom.Intensity = a.BloomIntensity
	bloom.Size = a.BloomSize
	bloom.Threshold = a.BloomThreshold

	-- Our own grade, found by name so it never grabs another system's
	-- ColorCorrection (e.g. a sighting's VHS effect).
	local grade = Lighting:FindFirstChild("SAC_ColorGrade") :: ColorCorrectionEffect?
	if not grade then
		local created = Instance.new("ColorCorrectionEffect")
		created.Name = "SAC_ColorGrade"
		created.Parent = Lighting
		grade = created
	end
	assert(grade)
	grade.Enabled = true
	grade.Brightness = a.ColorBrightness
	grade.Contrast = a.ColorContrast
	grade.Saturation = a.ColorSaturation
	grade.TintColor = a.ColorTint

	local rays = Lighting:FindFirstChildOfClass("SunRaysEffect")
	if rays then
		rays.Enabled = a.SunRaysEnabled
	end
end

--------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------

local function countParts(root: Instance): number
	local n = 0
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			n += 1
		end
	end
	return n
end

--- Destroys any existing `parent.Map`, rebuilds the terrain and builds a
--- fresh map. Returns the Map folder and the plot models in index order.
--- Part counts and timings are left in MapBuilder.LastStats.
function MapBuilder.Build(parent: Instance): (Folder, { Model })
	local started = os.clock()
	local existing = parent:FindFirstChild("Map")
	if existing then
		existing:Destroy()
	end
	lightCount, meshProps, fallbackProps = 0, 0, 0

	local rng = Random.new(Config.Map.Seed)

	-- Terrain first: everything outdoors stands on it.
	local terrainMs = buildTerrain(rng)

	-- Build detached, parent once: one replication burst instead of
	-- thousands of small ones.
	local map = Instance.new("Folder")
	map.Name = "Map"

	buildHub(map, rng)
	buildPaths(map)

	local plotsFolder = folder("Plots", map)
	local plots: { Model } = {}
	for i = 1, Config.Plot.Count do
		plots[i] = buildPlot(i, plotsFolder)
	end

	buildWilds(map, rng)
	buildBoundary(map)

	local parts: { [string]: number } = {}
	local total = 0
	for _, child in ipairs(map:GetChildren()) do
		local n = countParts(child)
		parts[child.Name] = n
		total += n
	end

	map.Parent = parent

	MapBuilder.LastStats = {
		TerrainMs = terrainMs,
		TotalMs = (os.clock() - started) * 1000,
		TotalParts = total,
		Parts = parts,
		Lights = lightCount,
		MeshProps = meshProps,
		FallbackProps = fallbackProps,
	}
	return map, plots
end

return MapBuilder
