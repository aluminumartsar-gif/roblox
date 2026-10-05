--!strict
--[[
	MapBuilder
	ServerScriptService/Server/Modules/MapBuilder

	Builds the whole world from Config: ground, hub (campfire, egg belt,
	Upgrades cabin, spawn), paths, the ring of plots, The Wilds, and the boundary.

	The map is GENERATED. WorldService rebuilds it on every server boot, so
	the world always matches the code and Config. Editing parts by hand in
	Studio does nothing lasting — change Config or this file instead. (This
	is deliberate for the placeholder phase; the art pass may switch to a
	hand-built map.)

	Everything random uses Random.new(Config.Map.Seed), so the forest is the
	same on every boot and every server.

	Plot local space: each plot's pivot CFrame looks at the hub, so local -Z
	is "toward the hub" (the door side) and +Z is the back wall. y = 0 is the
	ground; the deck top is at Config.Plot.FloorHeight.

	Structure produced:
	  Workspace.Map
	    Ground
	    Hub           (Model, Atomic streaming)
	    Paths
	    Plots
	      Plot_1 .. Plot_N   (Model, tag Plot, Atomic streaming)
	        Floor, Walls/*, Door (tag Door), Pad (tag PlotPad), LockButton,
	        Spawn, Sign, Nests/Nest_1..Nest_12 (tag Nest), Decor/*
	    Wilds         (trees and rocks)
	    Boundary
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local BeltPath = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BeltPath"))

local MapBuilder = {}

local TAU = math.pi * 2

local COLORS = {
	Deck = Color3.fromRGB(122, 88, 58),
	Wall = Color3.fromRGB(84, 58, 40),
	Trim = Color3.fromRGB(60, 42, 30),
	Log = Color3.fromRGB(96, 68, 46),
	Rock = Color3.fromRGB(96, 98, 104),
	Trunk = Color3.fromRGB(78, 56, 40),
	Leaves = { Color3.fromRGB(34, 64, 44), Color3.fromRGB(28, 56, 40), Color3.fromRGB(40, 72, 50) },
	Straw = Color3.fromRGB(150, 122, 74),
	HubDirt = Color3.fromRGB(104, 86, 64),
	Canvas = Color3.fromRGB(150, 120, 86),
	Door = Color3.fromRGB(255, 92, 64),
	Pad = Color3.fromRGB(110, 210, 140),
	LockButton = Color3.fromRGB(230, 70, 70),
	Roof = Color3.fromRGB(70, 48, 36),
	SignText = Color3.fromRGB(255, 232, 196),
}

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

local function lantern(baseCf: CFrame, height: number, parent: Instance)
	local a = Config.Atmosphere
	post(baseCf, height, 0.6, { Name = "LanternPost", Material = Enum.Material.Wood, Color = COLORS.Trim, Parent = parent })
	local light = block({
		Name = "Lantern",
		Size = Vector3.new(1.2, 1.4, 1.2),
		CFrame = baseCf * CFrame.new(0, height + 0.7, 0),
		Material = Enum.Material.Neon,
		Color = a.LanternColor,
		CanCollide = false,
		CastShadow = false,
		Parent = parent,
	})
	local pointLight = Instance.new("PointLight")
	pointLight.Color = a.LanternColor
	pointLight.Range = a.LanternRange
	pointLight.Brightness = a.LanternBrightness
	pointLight.Shadows = false
	pointLight.Parent = light
end

local function campfire(cf: CFrame, scale: number, parent: Instance)
	local a = Config.Atmosphere
	local fireModel = model("Campfire", parent)
	-- Ring of stones
	for i = 1, 8 do
		local angle = (i / 8) * TAU
		block({
			Name = "Stone",
			Shape = Enum.PartType.Ball,
			Size = Vector3.one * 1.4 * scale,
			CFrame = cf * CFrame.new(math.cos(angle) * 2.6 * scale, 0.4 * scale, math.sin(angle) * 2.6 * scale),
			Material = Enum.Material.Slate,
			Color = COLORS.Rock,
			Parent = fireModel,
		})
	end
	-- Crossed logs
	for i = 0, 2 do
		block({
			Name = "Log",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(4 * scale, 0.8 * scale, 0.8 * scale),
			CFrame = cf * CFrame.new(0, 0.5 * scale, 0) * CFrame.Angles(0, i * math.pi / 3, 0),
			Material = Enum.Material.Wood,
			Color = COLORS.Log,
			CanCollide = false,
			Parent = fireModel,
		})
	end
	local core = block({
		Name = "FireCore",
		Size = Vector3.new(1, 1, 1) * scale,
		CFrame = cf * CFrame.new(0, 1 * scale, 0),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Parent = fireModel,
	})
	local fire = Instance.new("Fire")
	fire.Size = 5 * scale
	fire.Heat = 9
	fire.Color = Color3.fromRGB(255, 140, 60)
	fire.SecondaryColor = Color3.fromRGB(255, 60, 20)
	fire.Parent = core
	local light = Instance.new("PointLight")
	light.Color = a.CampfireColor
	light.Range = a.CampfireRange * scale
	light.Brightness = a.CampfireBrightness
	light.Shadows = true
	light.Parent = core
end

--------------------------------------------------------------------------
-- Ground, hub, paths
--------------------------------------------------------------------------

local function buildGround(map: Folder)
	local size = Config.Map.GroundSize
	block({
		Name = "Ground",
		Size = Vector3.new(size, 2, size),
		CFrame = CFrame.new(0, -1, 0),
		Material = Enum.Material.Grass,
		Color = Config.Map.GroundColor,
		Parent = map,
	})
end

local function buildCabin(name: string, cf: CFrame, signText: string, shopId: string, parent: Instance)
	-- `cf` is the floor centre; LookVector faces the hub (open front).
	local cabin = model(name, parent)
	local width, depth, wallHeight = 24, 18, 11
	local t = 1

	block({ Name = "Floor", Size = Vector3.new(width, 1, depth), CFrame = cf * CFrame.new(0, 0.5, 0),
		Material = Enum.Material.WoodPlanks, Color = COLORS.Deck, Parent = cabin })
	block({ Name = "BackWall", Size = Vector3.new(width, wallHeight, t), CFrame = cf * CFrame.new(0, 1 + wallHeight / 2, depth / 2 - t / 2),
		Material = Enum.Material.Wood, Color = COLORS.Wall, Parent = cabin })
	for _, side in ipairs({ -1, 1 }) do
		block({ Name = "SideWall", Size = Vector3.new(t, wallHeight, depth), CFrame = cf * CFrame.new(side * (width / 2 - t / 2), 1 + wallHeight / 2, 0),
			Material = Enum.Material.Wood, Color = COLORS.Wall, Parent = cabin })
	end

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

local function plotAngle(index: number): number
	return (index - 1) / Config.Plot.Count * TAU
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

local function buildHub(map: Folder)
	local hub = model("Hub", map, true)
	local r = Config.Map.HubRadius

	disc(CFrame.new(0, 0.06, 0), r * 2, 0.12, {
		Name = "Clearing", Material = Enum.Material.Ground, Color = COLORS.HubDirt,
		CanCollide = false, CanQuery = false, CanTouch = false, Parent = hub,
	})

	campfire(CFrame.new(0, 0, 0), 1.6, hub)

	-- Log benches around the fire
	for i = 1, 5 do
		local angle = (i / 5) * TAU + 0.3
		block({
			Name = "Bench",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(7, 1.4, 1.4),
			CFrame = CFrame.new(math.cos(angle) * 13, 0.7, math.sin(angle) * 13) * CFrame.Angles(0, -angle + math.pi / 2, 0),
			Material = Enum.Material.Wood,
			Color = COLORS.Log,
			Parent = hub,
		})
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

	-- One lantern beside each path mouth.
	for i = 1, Config.Plot.Count do
		local angle = plotAngle(i) + math.rad(6)
		lantern(CFrame.new(math.cos(angle) * (r - 4), 0, math.sin(angle) * (r - 4)), 7, hub)
	end

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

local function buildPaths(map: Folder)
	local paths = folder("Paths", map)
	local startR = Config.Map.HubRadius - 4
	local endR = Config.Plot.RingRadius - Config.Plot.Size.Z / 2 + 2
	local length = endR - startR
	for i = 1, Config.Plot.Count do
		local angle = plotAngle(i)
		local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local mid = dir * (startR + length / 2)
		block({
			Name = "Path_" .. i,
			Size = Vector3.new(Config.Map.PathWidth, 0.1, length),
			CFrame = CFrame.lookAt(mid + Vector3.new(0, 0.05, 0), mid + dir + Vector3.new(0, 0.05, 0)),
			Material = Enum.Material.Ground,
			Color = Config.Map.PathColor,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			Parent = paths,
		})
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

local function buildNest(plotCf: CFrame, plotIndex: number, nestIndex: number, offset: Vector3, parent: Instance)
	local nest = model("Nest_" .. nestIndex, parent)
	local cf = plotCf * CFrame.new(offset)

	local base = disc(cf * CFrame.new(0, 0.5, 0), 7, 1, {
		Name = "Base", Material = Enum.Material.Fabric, Color = COLORS.Straw, Parent = nest,
	})
	disc(cf * CFrame.new(0, 1.02, 0), 5, 0.1, {
		Name = "Glow", Material = Enum.Material.Neon, Color = Config.Rebirth.NestGlowColors[1],
		Transparency = 0.9, CanCollide = false, CanQuery = false, CanTouch = false, Parent = nest,
	})
	-- Where an egg or creature sits. Steps 3+ parent visuals relative to this.
	local anchor = Instance.new("Attachment")
	anchor.Name = "ItemAnchor"
	anchor.Position = Vector3.new(0.6, 0, 0) -- base is rotated; +X local = up
	anchor.Parent = base

	nest.PrimaryPart = base
	nest:SetAttribute("PlotIndex", plotIndex)
	nest:SetAttribute("NestIndex", nestIndex)
	nest:SetAttribute("Active", false)
	CollectionService:AddTag(nest, Config.Tags.Nest)
end

local function buildPlot(index: number, plotsFolder: Folder)
	local p = Config.Plot
	local cf = MapBuilder.GetPlotCFrame(index)
	local half = p.Size.X / 2
	local depthHalf = p.Size.Z / 2
	local floorTop = p.FloorHeight
	local h, t, d = p.WallHeight, p.WallThickness, p.DoorWidth

	local plot = model("Plot_" .. index, plotsFolder, true)

	local floor = block({
		Name = "Floor",
		Size = Vector3.new(p.Size.X, floorTop, p.Size.Z),
		CFrame = cf * CFrame.new(0, floorTop / 2, 0),
		Material = Enum.Material.WoodPlanks,
		Color = COLORS.Deck,
		Parent = plot,
	})
	plot.PrimaryPart = floor

	-- Walls: back, two sides, and a front wall split around the doorway.
	local walls = folder("Walls", plot)
	local wallY = floorTop + h / 2
	local wallProps = { Material = Enum.Material.Wood, Color = COLORS.Wall, Parent = walls }
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

	-- Door posts with lanterns, and the owner sign above the doorway.
	for _, side in ipairs({ -1, 1 }) do
		local postCf = cf * CFrame.new(side * (d / 2 + 0.7), floorTop, -depthHalf + t / 2)
		post(postCf, h + 5, 1.4, { Name = "DoorPost", Material = Enum.Material.Wood, Color = COLORS.Trim, Parent = plot })
		local lamp = block({
			Name = "Lantern",
			Size = Vector3.new(1.2, 1.4, 1.2),
			CFrame = postCf * CFrame.new(0, h + 5.7, 0),
			Material = Enum.Material.Neon,
			Color = Config.Atmosphere.LanternColor,
			CanCollide = false,
			CastShadow = false,
			Parent = plot,
		})
		local light = Instance.new("PointLight")
		light.Color = Config.Atmosphere.LanternColor
		light.Range = Config.Atmosphere.LanternRange
		light.Brightness = Config.Atmosphere.LanternBrightness
		light.Shadows = false
		light.Parent = lamp
	end

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
	local signLabel = Instance.new("TextLabel")
	signLabel.Name = "Label"
	signLabel.Size = UDim2.fromScale(1, 1)
	signLabel.BackgroundTransparency = 1
	signLabel.Font = Enum.Font.Fantasy
	signLabel.TextScaled = true
	signLabel.TextColor3 = COLORS.SignText
	signLabel.Parent = surface
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

	-- Claim pad just inside the door (thieves deliver here in Step 4).
	local pad = block({
		Name = "Pad",
		Size = Vector3.new(10, 0.2, 6),
		CFrame = cf * CFrame.new(0, floorTop + 0.1, -depthHalf + 8),
		Material = Enum.Material.Neon,
		Color = COLORS.Pad,
		Transparency = 0.45,
		CanCollide = false,
		CastShadow = false,
		Parent = plot,
	})
	pad:SetAttribute("PlotIndex", index)
	CollectionService:AddTag(pad, Config.Tags.PlotPad)

	-- Lock button on a stump, inside the door on the left.
	local stumpCf = cf * CFrame.new(-16, floorTop, -depthHalf + 8)
	post(stumpCf, 3, 2.6, { Name = "LockStump", Material = Enum.Material.Wood, Color = COLORS.Log, Parent = plot })
	local button = block({
		Name = "LockButton",
		Size = Vector3.new(1.8, 0.5, 1.8),
		CFrame = stumpCf * CFrame.new(0, 3.25, 0),
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
		buildNest(cf, index, k, offset, nests)
	end

	-- Decor: a tent in the back-left corner and a small fire back-right.
	local decor = folder("Decor", plot)
	gable(cf * CFrame.new(-half + 9, floorTop + 5, depthHalf - 9) * CFrame.Angles(0, math.pi / 2, 0),
		9, 4, 52, 0.4, { Name = "Tent", Material = Enum.Material.Fabric, Color = COLORS.Canvas, CanCollide = false }, decor)
	campfire(cf * CFrame.new(half - 9, floorTop, depthHalf - 9), 0.8, decor)

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

--- Shows a nest as usable (glowing) or locked (dim).
function MapBuilder.SetNestActive(nest: Model, active: boolean, glowColor: Color3?)
	nest:SetAttribute("Active", active)
	local glow = nest:FindFirstChild("Glow") :: BasePart?
	if glow then
		glow.Transparency = if active then 0.55 else 0.9
		if glowColor then
			glow.Color = glowColor
		end
	end
end

--------------------------------------------------------------------------
-- The Wilds and boundary
--------------------------------------------------------------------------

local function buildTree(position: Vector3, scale: number, rng: Random, parent: Instance)
	local tree = model("Tree", parent, true)
	local base = CFrame.new(position) * CFrame.Angles(0, rng:NextNumber(0, TAU), 0)
	local trunkHeight = 7 * scale
	post(base, trunkHeight, 1.8 * scale, { Name = "Trunk", Material = Enum.Material.Wood, Color = COLORS.Trunk, Parent = tree })

	local leaf = COLORS.Leaves[rng:NextInteger(1, #COLORS.Leaves)]
	local y = trunkHeight * 0.55
	for tier = 0, 2 do
		local diameter = (11 - tier * 3) * scale
		local height = 4 * scale
		post(base * CFrame.new(0, y, 0), height, diameter, {
			Name = "Leaves", Material = Enum.Material.Grass, Color = leaf,
			CanCollide = false, CanQuery = false, CanTouch = false, Parent = tree,
		})
		y += height * 0.8
	end
end

local function buildRock(position: Vector3, scale: number, rng: Random, parent: Instance)
	block({
		Name = "Rock",
		Size = Vector3.new(rng:NextNumber(3, 6), rng:NextNumber(2, 4), rng:NextNumber(3, 6)) * scale,
		CFrame = CFrame.new(position + Vector3.new(0, 0.6 * scale, 0))
			* CFrame.Angles(rng:NextNumber(-0.3, 0.3), rng:NextNumber(0, TAU), rng:NextNumber(-0.3, 0.3)),
		Material = Enum.Material.Slate,
		Color = COLORS.Rock,
		Parent = parent,
	})
end

local function buildWilds(map: Folder, rng: Random)
	local m = Config.Map
	local wilds = folder("Wilds", map)
	local placed: { Vector3 } = {}

	local function farEnough(pos: Vector3, minDistance: number): boolean
		for _, other in ipairs(placed) do
			if (other - pos).Magnitude < minDistance then
				return false
			end
		end
		return true
	end

	-- Uniform over the ring's AREA (sqrt), not its radius, so the outer edge
	-- isn't sparser than the inner edge.
	local function randomInRing(inner: number, outer: number): Vector3
		local angle = rng:NextNumber(0, TAU)
		local radius = math.sqrt(rng:NextNumber(inner * inner, outer * outer))
		return Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
	end

	local attempts = 0
	local trees = 0
	while trees < m.WildsTreeCount and attempts < m.WildsTreeCount * 20 do
		attempts += 1
		local pos = randomInRing(m.WildsInnerRadius, m.WildsOuterRadius)
		if farEnough(pos, m.TreeMinSpacing) then
			table.insert(placed, pos)
			buildTree(pos, rng:NextNumber(0.85, 1.35), rng, wilds)
			trees += 1
		end
	end

	for _ = 1, m.WildsRockCount do
		buildRock(randomInRing(m.WildsInnerRadius, m.WildsOuterRadius), rng:NextNumber(0.7, 1.5), rng, wilds)
	end

	-- A few trees in each gap between neighbouring plots.
	local gapHalfWidth = 14
	for i = 1, Config.Plot.Count do
		local gapAngle = plotAngle(i) + 0.5 / Config.Plot.Count * TAU
		local outward = Vector3.new(math.cos(gapAngle), 0, math.sin(gapAngle))
		local sideways = Vector3.new(-outward.Z, 0, outward.X)
		for _ = 1, m.BetweenPlotTreesEach do
			local pos = outward * (Config.Plot.RingRadius + rng:NextNumber(-30, 40))
				+ sideways * rng:NextNumber(-gapHalfWidth, gapHalfWidth)
			buildTree(pos, rng:NextNumber(0.8, 1.15), rng, wilds)
		end
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

--- Destroys any existing `parent.Map` and builds a fresh one.
--- Returns the Map folder and the plot models in index order.
function MapBuilder.Build(parent: Instance): (Folder, { Model })
	local existing = parent:FindFirstChild("Map")
	if existing then
		existing:Destroy()
	end

	local rng = Random.new(Config.Map.Seed)

	-- Build detached, parent once: one replication burst instead of
	-- thousands of small ones.
	local map = Instance.new("Folder")
	map.Name = "Map"

	buildGround(map)
	buildHub(map)
	buildPaths(map)

	local plotsFolder = folder("Plots", map)
	local plots: { Model } = {}
	for i = 1, Config.Plot.Count do
		plots[i] = buildPlot(i, plotsFolder)
	end

	buildWilds(map, rng)
	buildBoundary(map)

	map.Parent = parent
	return map, plots
end

return MapBuilder
