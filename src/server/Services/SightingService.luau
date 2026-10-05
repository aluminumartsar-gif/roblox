--!strict
--[[
	SightingService
	ServerScriptService/Server/Services/SightingService

	Hook 2 (DESIGN.md §2): every so often a wild cryptid appears somewhere in
	The Wilds for a short while, and the whole server races to catch it.

	  schedule  — the first one Config.Sightings.FirstDelay after the first
	              player loads in; then a random gap (MinInterval..MaxInterval)
	              after the last one ended. One at a time, never while the
	              server is empty, and never during a Hunt (it waits
	              Config.Hunt.BusyRetry and tries again).
	  roll      — rarity from BaseWeights, shifted rarer per player online
	              (RarerPerPlayer, up to MaxPlayersForScaling); creature picked
	              uniformly within it (EggRoller.PickCreature).
	  spawn     — a clear, walkable spot in the Wilds ring found with
	              raycasts + a spatial query (no part names: the map art
	              changes), a light pillar and PointLight in the rarity colour,
	              a Capture prompt. Stationary on the server — prompts are
	              checked against the server's position (CLAUDE.md gotcha);
	              clients add a small idle bob locally.
	  capture   — a Config.Prompts.CaptureHold-second hold, tracked on the
	              server like a steal (time recorded on HoldBegan, Triggered
	              must come at least CaptureHold - HoldTolerance later). It's
	              CONTESTED: anyone starting a hold breaks everyone else's.
	              A Bat stun (BatService.Bonked) or losing health breaks
	              yours too. The broken holder's client is told
	              ("Interrupted") so it can reset the prompt ring.
	  carry     — the winner carries it home overhead like a stolen item:
	              StealService.CarryCaptured (Source = "Sighting"). This
	              service decorates that carry (pillar + outline, so anyone
	              can jump them) and narrates it; StealService runs the
	              carry itself (drop, pick up, claim, escape).
	  escape    — not caught within Duration: it slips back into the woods.

	Server -> client: SightingBanner (phase, info). To everyone:
	  "Started"   { SightingId, CreatureId, Name, Label, Rarity, Hint,
	                Position, StartedAt, ExpiresAt }
	  "Captured"  { SightingId, CarryId, CreatureId, Name, Label, Rarity,
	                By, ByUserId }
	  "Dropped"   { CarryId, Name, Label, Rarity, By, ByUserId, Position,
	                ExpiresAt }
	  "PickedUp"  { CarryId, Name, Label, Rarity, By, ByUserId }
	  "Claimed"   { CarryId, Name, Label, Rarity, By, ByUserId }
	  "Escaped"   { SightingId?, CarryId?, Name, Label, Rarity }
	To one player:
	  "Interrupted" { SightingId, By?, Quiet? }   (their hold was broken or
	                refused; Quiet = refused, no "interrupted" message)
	Times are workspace:GetServerTimeNow() values. Late joiners get the
	current state when their profile loads.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemVisuals = require(Shared:WaitForChild("ItemVisuals"))

local Server = ServerScriptService:WaitForChild("Server")
local Modules = Server:WaitForChild("Modules")
local Services = Server:WaitForChild("Services")
local RemoteGuard = require(Modules:WaitForChild("RemoteGuard"))
local Notifier = require(Modules:WaitForChild("Notifier"))
local EggRoller = require(Modules:WaitForChild("EggRoller"))
local DataService = require(Services:WaitForChild("DataService"))
local PlotService = require(Services:WaitForChild("PlotService"))
local NestService = require(Services:WaitForChild("NestService"))
local StealService = require(Services:WaitForChild("StealService"))
local BatService = require(Services:WaitForChild("BatService"))

type Carry = StealService.Carry

type Sighting = {
	Id: number,
	CreatureId: string,
	Rarity: string,
	Name: string,         -- "Mothman"
	Label: string,        -- "Epic Mothman"
	Hint: string,         -- "north-east Wilds, behind Alex's camp"
	Position: Vector3,    -- the ground under it
	Model: Model,
	Body: BasePart,       -- the model's PrimaryPart (holds the prompt)
	StartedAt: number,    -- server time
	ExpiresAt: number,    -- server time
}

type Hold = { Began: number, SightingId: number }

-- A capture on its way home (carried or lying loose), keyed by carry id.
type Capture = {
	CarryId: number,
	CreatureId: string,
	Name: string,
	Label: string,
	Rarity: string,
	Phase: string,        -- "Carried" | "Dropped"
	By: string,           -- display name of the current / last carrier
	ByUserId: number,
	Position: Vector3?,   -- where it lies, while dropped
	ExpiresAt: number?,   -- when it escapes, while dropped (server time)
}

local SightingService = {}

-- Directions on the map, clockwise from -Z ("north").
local COMPASS = { "north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west" }
-- Same ordering caveat as StealService: HoldEnded fires before Triggered,
-- so an abandoned hold is only forgotten after this grace period.
local HOLD_END_GRACE = 0.2
local NOTICE_THROTTLE = 2
local TICK = 0.5

local active: Sighting? = nil
local captures: { [number]: Capture } = {}
local holds: { [Player]: Hold } = {}
local lastNotice: { [Player]: number } = {}
local nextSightingId = 0
local nextAt: number? = nil -- os.clock() of the next spawn; nil = waiting for a player
local rng = Random.new()

local bannerRemote: RemoteEvent
local announceRemote: RemoteEvent
local runtimeFolder: Folder

local function log(fmt: string, ...: any)
	if Config.Debug.Verbose then
		print(string.format("[SAC/Sighting] " .. fmt, ...))
	end
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function throttledNotice(player: Player, text: string, kind: string?)
	local t = os.clock()
	if (lastNotice[player] or 0) + NOTICE_THROTTLE > t then
		return
	end
	lastNotice[player] = t
	Notifier.Send(player, text, kind or "Error")
end

--- "Epic Mothman" (Secret-style rarities show the name only).
local function labelFor(creatureId: string): string
	local def = Config.CreaturesById[creatureId]
	local rarity = def and Config.Rarities[def.Rarity]
	if not def or not rarity then
		return "cryptid"
	end
	if rarity.NeverRenderClearly then
		return def.Name
	end
	return rarity.DisplayName .. " " .. def.Name
end

local function rarityColor(rarity: string): Color3
	local def = Config.Rarities[rarity]
	return if def then def.Color else Color3.new(1, 1, 1)
end

--- Fires the server-wide banner to everyone.
local function broadcast(phase: string, info: { [string]: any })
	bannerRemote:FireAllClients(phase, info)
end

--- A server-wide toast (GlobalAnnounce), optionally skipping one player
--- who gets their own message instead.
local function announce(text: string, rarity: string, except: Player?)
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= except then
			announceRemote:FireClient(player, text, rarity)
		end
	end
end

--------------------------------------------------------------------------
-- Rarity roll
--------------------------------------------------------------------------

--- Spawn weights for a server with `playerCount` players: BaseWeights with
--- part of the most common rarity's weight moved into the rarer ones.
function SightingService.GetWeights(playerCount: number): { [string]: number }
	local s = Config.Sightings
	local base = s.BaseWeights
	local order: { string } = {}
	for _, rarity in ipairs(Config.RarityOrder) do
		if (base[rarity] or 0) > 0 and #(Config.CreaturesByRarity[rarity] or {}) > 0 then
			table.insert(order, rarity)
		end
	end
	local weights: { [string]: number } = {}
	for _, rarity in ipairs(order) do
		weights[rarity] = base[rarity]
	end
	if #order < 2 then
		return weights
	end

	local extraPlayers = math.max(0, math.min(playerCount, s.MaxPlayersForScaling) - 1)
	local fraction = math.clamp(extraPlayers * s.RarerPerPlayer, 0, 1)
	local lowest = order[1]
	local moved = weights[lowest] * fraction
	weights[lowest] -= moved
	local rarerTotal = 0
	for i = 2, #order do
		rarerTotal += base[order[i]]
	end
	for i = 2, #order do
		weights[order[i]] += moved * base[order[i]] / rarerTotal
	end
	return weights
end

local function rollRarity(): string?
	local weights = SightingService.GetWeights(#Players:GetPlayers())
	local total = 0
	for _, weight in pairs(weights) do
		total += weight
	end
	if total <= 0 then
		return nil
	end
	local roll = rng:NextNumber() * total
	local last: string? = nil
	for _, rarity in ipairs(Config.RarityOrder) do
		local weight = weights[rarity]
		if weight then
			last = rarity
			roll -= weight
			if roll < 0 then
				return rarity
			end
		end
	end
	return last -- floating-point leftovers
end

--------------------------------------------------------------------------
-- Finding a spot in The Wilds
--------------------------------------------------------------------------

local function newRaycastParams(): RaycastParams
	local exclude: { Instance } = { runtimeFolder }
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = false
	return params
end

--- The first walkable surface straight down at (x, z): terrain, or a
--- collidable visible part. Things you can walk through (leaves, invisible
--- helpers) are skipped and remembered in `params` for later rays.
local function castDown(x: number, z: number, params: RaycastParams): RaycastResult?
	local height = Config.Sightings.RaycastFromHeight
	local origin = Vector3.new(x, height, z)
	local direction = Vector3.new(0, -height * 2, 0)
	for _ = 1, 8 do
		local hit = Workspace:Raycast(origin, direction, params)
		if not hit then
			return nil
		end
		local instance = hit.Instance
		if instance:IsA("Terrain") then
			return hit
		end
		if instance:IsA("BasePart") and instance.CanCollide and instance.Transparency < 1 then
			return hit
		end
		params:AddToFilter(instance)
	end
	return nil
end

--- The ground position at (x, z) if it's a good place for a sighting.
local function clearSpot(x: number, z: number, params: RaycastParams, overlap: OverlapParams): Vector3?
	local s = Config.Sightings
	local hit = castDown(x, z, params)
	if not hit or hit.Material == Enum.Material.Water then
		return nil
	end
	if hit.Normal.Y < math.cos(math.rad(s.MaxSlope)) then
		return nil
	end
	local ground = hit.Position

	-- Flat enough all round? (Also catches the centre ray landing on top of
	-- a stump or rock: the ground around it is much lower.)
	local r = s.ClearanceRadius
	for _, offset in ipairs({ Vector2.new(r, 0), Vector2.new(-r, 0), Vector2.new(0, r), Vector2.new(0, -r) }) do
		local side = castDown(x + offset.X, z + offset.Y, params)
		if not side or side.Material == Enum.Material.Water then
			return nil
		end
		if math.abs(side.Position.Y - ground.Y) > s.MaxBumpiness then
			return nil
		end
	end

	-- Nothing solid standing there (trunks, rocks, walls). Huge parts are
	-- ground or hills, not obstacles.
	local boxCenter = CFrame.new(ground + Vector3.new(0, 1 + s.ClearanceHeight / 2, 0))
	local boxSize = Vector3.new(r * 2, s.ClearanceHeight, r * 2)
	for _, part in ipairs(Workspace:GetPartBoundsInBox(boxCenter, boxSize, overlap)) do
		if part.CanCollide and part.Transparency < 1 then
			local size = part.Size
			if math.max(size.X, size.Z) < s.GroundPartMinWidth then
				return nil
			end
		end
	end
	return ground
end

--- A clear spot somewhere in the Wilds ring. Falls back to the middle of
--- the ring (ground found by a ray, or y = 0) after SpawnAttempts tries.
local function findSpot(): (Vector3, number)
	local s = Config.Sightings
	local inner = Config.Map.WildsInnerRadius
	local outer = math.max(inner + 1, Config.Map.WildsOuterRadius - s.EdgeMargin)
	local params = newRaycastParams()
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = params.FilterDescendantsInstances

	for attempt = 1, s.SpawnAttempts do
		local angle = rng:NextNumber(0, math.pi * 2)
		-- Uniform over the ring's area, like MapBuilder's trees.
		local radius = math.sqrt(rng:NextNumber(inner * inner, outer * outer))
		local spot = clearSpot(math.cos(angle) * radius, math.sin(angle) * radius, params, overlap)
		if spot then
			return spot, attempt
		end
	end

	local angle = rng:NextNumber(0, math.pi * 2)
	local radius = (inner + outer) / 2
	local x, z = math.cos(angle) * radius, math.sin(angle) * radius
	local hit = castDown(x, z, params)
	warn(string.format("[SAC/Sighting] No clear spot after %d tries; using the middle of the ring", s.SpawnAttempts))
	local fallback = if hit then hit.Position else Vector3.new(x, 0, z)
	return fallback, 0
end

--- "north-east Wilds, behind Alex's camp" — the nearest camp, if it has an
--- owner, is the landmark players actually know.
local function hintFor(position: Vector3): string
	local angle = math.atan2(position.X, -position.Z) -- 0 = north (-Z), clockwise
	local index = math.floor(angle / (math.pi / 4) + 0.5) % #COMPASS + 1
	local hint = COMPASS[index] .. " Wilds"

	local nearest: PlotService.PlotRecord? = nil
	local best = math.huge
	for _, plot in ipairs(PlotService.GetPlots()) do
		local distance = (plot.CFrame.Position - position).Magnitude
		if distance < best then
			best = distance
			nearest = plot
		end
	end
	if nearest and nearest.Owner and nearest.Owner.Parent == Players then
		hint ..= string.format(", behind %s's camp", nearest.Owner.DisplayName)
	end
	return hint
end

--------------------------------------------------------------------------
-- Visuals
--------------------------------------------------------------------------

--- A light pillar (Beam) rising `height` studs from `basePoint`, attached
--- to `part` so it moves with it.
local function addPillar(part: BasePart, basePoint: Vector3, height: number, width: number, color: Color3)
	local bottom = Instance.new("Attachment")
	bottom.Name = "PillarBottom"
	bottom.Position = part.CFrame:PointToObjectSpace(basePoint)
	bottom.Parent = part
	local top = Instance.new("Attachment")
	top.Name = "PillarTop"
	top.Position = part.CFrame:PointToObjectSpace(basePoint + Vector3.new(0, height, 0))
	top.Parent = part

	local beam = Instance.new("Beam")
	beam.Name = "Pillar"
	beam.Attachment0 = bottom
	beam.Attachment1 = top
	beam.Color = ColorSequence.new(color)
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, Config.Sightings.PillarTransparency),
		NumberSequenceKeypoint.new(1, 1),
	})
	beam.Width0 = width
	beam.Width1 = width * 0.5
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.FaceCamera = true
	beam.Segments = 1
	beam.Parent = part
end

local function addLight(part: BasePart, color: Color3)
	local light = Instance.new("PointLight")
	light.Name = "SightingLight"
	light.Color = color
	light.Range = Config.Sightings.LightRange
	light.Brightness = Config.Sightings.LightBrightness
	light.Shadows = false
	light.Parent = part
end

--- StealService builds a new model every time a capture is picked up or
--- dropped; this dresses each one so the carrier is visible map-wide.
local function decorateCapture(model: Model, carry: any)
	local body = model.PrimaryPart
	if not body then
		return
	end
	local color = rarityColor(carry.Slot.Rarity)
	addPillar(body, body.Position, Config.Sightings.CarryPillarHeight, Config.Sightings.CarryPillarWidth, color)
	addLight(body, color)
	local outline = Instance.new("Highlight")
	outline.Name = "CaptureOutline"
	outline.FillColor = color
	outline.FillTransparency = 0.7
	outline.OutlineColor = color
	outline.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	outline.Parent = model
	model:SetAttribute("SightingCapture", true)
end

--------------------------------------------------------------------------
-- Holds
--------------------------------------------------------------------------

--- Breaks `player`'s capture hold (if any) and tells them why.
local function interrupt(player: Player, text: string, by: string?)
	local hold = holds[player]
	if not hold then
		return
	end
	holds[player] = nil
	Notifier.Send(player, text, "Warning")
	if player.Parent == Players then
		bannerRemote:FireClient(player, "Interrupted", { SightingId = hold.SightingId, By = by })
	end
	log("%s's hold interrupted: %s", player.Name, text)
end

--- Every rule for "may this player capture this sighting right now?".
local function checkCapture(player: Player, sighting: Sighting): (boolean, string?)
	if active ~= sighting or serverNow() >= sighting.ExpiresAt then
		return false, nil
	end
	if not DataService.Get(player) then
		return false, "Your camp is still loading — try again in a moment."
	end
	if not PlotService.GetPlot(player) then
		return false, "You need a camp first."
	end
	if StealService.IsCarrying(player) then
		return false, "Your hands are full — drop off what you're carrying first."
	end
	if BatService.IsStunned(player) then
		return false, "You're seeing stars — wait a second!"
	end
	if not NestService.FindEmptyNest(player) then
		return false, "You have no empty nest to bring it home to."
	end
	if not RemoteGuard.IsWithinReach(player, sighting.Body.Position) then
		return false, nil
	end
	return true, nil
end

--------------------------------------------------------------------------
-- Ending a sighting
--------------------------------------------------------------------------

local function scheduleNext()
	local s = Config.Sightings
	nextAt = os.clock() + rng:NextNumber(s.MinInterval, math.max(s.MinInterval, s.MaxInterval))
end

--- Takes the wild cryptid out of the world and books the next one.
local function clearActive(sighting: Sighting)
	if active ~= sighting then
		return
	end
	active = nil
	table.clear(holds)
	sighting.Model:Destroy()
	scheduleNext()
end

local function escape(reason: string)
	local sighting = active
	if not sighting then
		return
	end
	clearActive(sighting)
	broadcast("Escaped", {
		SightingId = sighting.Id,
		Name = sighting.Name,
		Label = sighting.Label,
		Rarity = sighting.Rarity,
	})
	if #Players:GetPlayers() > 0 then
		announce(string.format("The %s slipped back into the woods. Keep your eyes open...", sighting.Label), sighting.Rarity)
	end
	log("sighting %d escaped (%s)", sighting.Id, reason)
end

local function capture(player: Player, sighting: Sighting)
	if not StealService.CarryCaptured(player, sighting.CreatureId, sighting.Rarity) then
		throttledNotice(player, "It wriggled free — try again!")
		return
	end
	local carry = StealService.GetCarry(player)
	clearActive(sighting)
	if not carry then
		return -- can't happen: CarryCaptured just attached it
	end

	captures[carry.Id] = {
		CarryId = carry.Id,
		CreatureId = sighting.CreatureId,
		Name = sighting.Name,
		Label = sighting.Label,
		Rarity = sighting.Rarity,
		Phase = "Carried",
		By = player.DisplayName,
		ByUserId = player.UserId,
		Position = nil,
		ExpiresAt = nil,
	}
	broadcast("Captured", {
		SightingId = sighting.Id,
		CarryId = carry.Id,
		CreatureId = sighting.CreatureId,
		Name = sighting.Name,
		Label = sighting.Label,
		Rarity = sighting.Rarity,
		By = player.DisplayName,
		ByUserId = player.UserId,
	})
	Notifier.Send(player, string.format("You caught the %s! Get it to your camp's pad — everyone can see you.", sighting.Label), "Success")
	announce(string.format("%s caught the %s! Stop them before they get home!", player.DisplayName, sighting.Label), sighting.Rarity, player)
	log("%s captured sighting %d (%s) as carry %d", player.Name, sighting.Id, sighting.CreatureId, carry.Id)
end

--------------------------------------------------------------------------
-- Spawning
--------------------------------------------------------------------------

local function startedInfo(sighting: Sighting): { [string]: any }
	return {
		SightingId = sighting.Id,
		CreatureId = sighting.CreatureId,
		Name = sighting.Name,
		Label = sighting.Label,
		Rarity = sighting.Rarity,
		Hint = sighting.Hint,
		Position = sighting.Position,
		StartedAt = sighting.StartedAt,
		ExpiresAt = sighting.ExpiresAt,
	}
end

local function captureInfo(entry: Capture): { [string]: any }
	return {
		CarryId = entry.CarryId,
		CreatureId = entry.CreatureId,
		Name = entry.Name,
		Label = entry.Label,
		Rarity = entry.Rarity,
		By = entry.By,
		ByUserId = entry.ByUserId,
		Position = entry.Position,
		ExpiresAt = entry.ExpiresAt,
	}
end

local function wirePrompt(sighting: Sighting, prompt: ProximityPrompt)
	prompt.PromptButtonHoldBegan:Connect(function(player: Player)
		local ok, reason = checkCapture(player, sighting)
		if not ok then
			if reason then
				throttledNotice(player, reason)
			end
			holds[player] = nil
			-- Reset their ring: this hold can't win.
			bannerRemote:FireClient(player, "Interrupted", { SightingId = sighting.Id, Quiet = true })
			return
		end
		-- Contested: starting a hold breaks everyone else's.
		for other, hold in pairs(holds) do
			if other ~= player and hold.SightingId == sighting.Id then
				interrupt(other, string.format("%s jumped in — your capture was interrupted!", player.DisplayName), player.DisplayName)
			end
		end
		local hold: Hold = { Began = os.clock(), SightingId = sighting.Id }
		holds[player] = hold
		-- Expire it on the server even if HoldEnded never arrives, so an
		-- abandoned hold can't be cashed in later.
		task.delay(Config.Prompts.CaptureHold + Config.Steal.HoldMaxOverrun, function()
			if holds[player] == hold then
				holds[player] = nil
			end
		end)
	end)

	-- When a hold COMPLETES, Roblox fires HoldEnded before Triggered: only
	-- forget the hold if Triggered hasn't consumed it after a moment.
	prompt.PromptButtonHoldEnded:Connect(function(player: Player)
		local hold = holds[player]
		if not hold then
			return
		end
		task.delay(HOLD_END_GRACE, function()
			if holds[player] == hold then
				holds[player] = nil
			end
		end)
	end)

	prompt.Triggered:Connect(function(player: Player)
		local hold = holds[player]
		holds[player] = nil
		if not hold or hold.SightingId ~= sighting.Id then
			return -- refused at the start, interrupted, or fired without a hold
		end
		local elapsed = os.clock() - hold.Began
		if elapsed < Config.Prompts.CaptureHold - Config.Steal.HoldTolerance then
			warn(string.format("[SAC/Sighting] Rejected %s: capture hold too short (possible exploit)", player.Name))
			return
		end
		if elapsed > Config.Prompts.CaptureHold + Config.Steal.HoldMaxOverrun then
			warn(string.format("[SAC/Sighting] Rejected %s: stale capture hold (possible exploit)", player.Name))
			return
		end
		local ok, reason = checkCapture(player, sighting)
		if not ok then
			if reason then
				throttledNotice(player, reason)
			end
			return
		end
		capture(player, sighting)
	end)
end

--- Spawns a sighting now. `forced` (debug) may name a rarity or a
--- creature id. Returns (ok, message).
local function spawnSighting(forced: string?): (boolean, string)
	if active then
		return false, "a sighting is already active"
	end

	local creatureId: string
	local rarity: string
	if forced and Config.CreaturesById[forced] then
		creatureId = forced
		rarity = Config.CreaturesById[forced].Rarity
	else
		local rolled = if forced and Config.Rarities[forced] then forced else rollRarity()
		if not rolled or #(Config.CreaturesByRarity[rolled] or {}) == 0 then
			return false, "no rarity to roll (check Config.Sightings.BaseWeights)"
		end
		rarity = rolled
		creatureId = EggRoller.PickCreature(rarity, rng).Id
	end
	local def = Config.CreaturesById[creatureId]

	local position, attempts = findSpot()

	local model = ItemVisuals.BuildCreature(creatureId)
	model.Name = "WildCryptid"
	model:PivotTo(CFrame.new(position) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0))
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true -- stays put on the server, always
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
	local body = model.PrimaryPart
	if not body then
		model:Destroy()
		return false, "creature model has no PrimaryPart"
	end

	nextSightingId += 1
	local now = serverNow()
	local sighting: Sighting = {
		Id = nextSightingId,
		CreatureId = creatureId,
		Rarity = rarity,
		Name = def.Name,
		Label = labelFor(creatureId),
		Hint = hintFor(position),
		Position = position,
		Model = model,
		Body = body,
		StartedAt = now,
		ExpiresAt = now + Config.Sightings.Duration,
	}

	local color = rarityColor(rarity)
	addPillar(body, position, Config.Sightings.PillarHeight, Config.Sightings.PillarWidth, color)
	addLight(body, color)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "CapturePrompt"
	prompt.ActionText = "Capture"
	prompt.ObjectText = sighting.Label
	prompt.HoldDuration = Config.Prompts.CaptureHold
	prompt.MaxActivationDistance = Config.Prompts.MaxActivationDistance
	prompt.RequiresLineOfSight = Config.Prompts.RequiresLineOfSight
	prompt.Parent = body
	wirePrompt(sighting, prompt)

	model:SetAttribute("CreatureId", creatureId)
	model:SetAttribute("Rarity", rarity)
	model:SetAttribute("ItemLabel", sighting.Label)
	model:SetAttribute("SightingId", sighting.Id)
	model:SetAttribute("ExpiresAt", sighting.ExpiresAt)
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	CollectionService:AddTag(model, Config.Tags.WildCryptid)
	model.Parent = runtimeFolder

	active = sighting
	nextAt = nil
	broadcast("Started", startedInfo(sighting))
	announce(string.format("Sighting! A wild %s is in the %s. Catch it before it's gone!", sighting.Label, sighting.Hint), rarity)
	log("sighting %d: %s at (%.0f, %.0f, %.0f), spot found on try %d",
		sighting.Id, creatureId, position.X, position.Y, position.Z, attempts)
	return true, string.format("spawned %s at %s (%s)", sighting.Label, tostring(position), sighting.Hint)
end

--------------------------------------------------------------------------
-- Captures on their way home (StealService runs the carry)
--------------------------------------------------------------------------

local function onItemTaken(player: Player, carry: Carry)
	local entry = captures[carry.Id]
	if carry.Source ~= "Sighting" or not entry then
		return
	end
	entry.Phase = "Carried"
	entry.By = player.DisplayName
	entry.ByUserId = player.UserId
	entry.Position = nil
	entry.ExpiresAt = nil
	broadcast("PickedUp", captureInfo(entry))
	announce(string.format("%s grabbed the loose %s! Stop them before they get home!", player.DisplayName, entry.Label), entry.Rarity, player)
end

local function onItemDropped(player: Player, carry: Carry)
	local entry = captures[carry.Id]
	if carry.Source ~= "Sighting" or not entry then
		return
	end
	entry.Phase = "Dropped"
	entry.By = player.DisplayName
	entry.ByUserId = player.UserId
	entry.Position = if carry.Model then carry.Model:GetPivot().Position else nil
	entry.ExpiresAt = carry.ReturnAtServer
	broadcast("Dropped", captureInfo(entry))
	announce(string.format("%s dropped the %s! Anyone can grab it!", player.DisplayName, entry.Label), entry.Rarity, player)
end

local function onClaimed(player: Player, carry: Carry, _nestIndex: number)
	local entry = captures[carry.Id]
	if carry.Source ~= "Sighting" or not entry then
		return
	end
	captures[carry.Id] = nil
	entry.By = player.DisplayName
	entry.ByUserId = player.UserId
	broadcast("Claimed", captureInfo(entry))
	announce(string.format("%s brought a wild %s home!", player.DisplayName, entry.Label), entry.Rarity)
	log("%s claimed capture carry %d", player.Name, carry.Id)
end

local function onCaptureEscaped(carry: Carry, reason: string)
	local entry = captures[carry.Id]
	if not entry then
		return
	end
	captures[carry.Id] = nil
	-- The Brood Mother taking it back isn't "it got away": HuntEvent
	-- "Caught" already tells everyone, so no server-wide announce then.
	local takenBack = reason == Config.Hunt.ReclaimReason
	broadcast("Escaped", {
		CarryId = entry.CarryId,
		Name = entry.Name,
		Label = entry.Label,
		Rarity = entry.Rarity,
		TakenBack = takenBack,
	})
	if not takenBack and #Players:GetPlayers() > 0 then
		announce(string.format("The %s got away into the woods!", entry.Label), entry.Rarity)
	end
	log("capture carry %d escaped (%s)", carry.Id, reason)
end

--------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------

local function hookCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid or not humanoid:IsA("Humanoid") then
		return
	end
	-- Taking damage breaks a capture hold.
	local lastHealth = humanoid.Health
	humanoid.HealthChanged:Connect(function(health: number)
		if health < lastHealth and holds[player] then
			interrupt(player, "You got hurt — capture interrupted!", nil)
		end
		lastHealth = health
	end)
end

--- Late joiners: show them what's going on right now.
local function syncPlayer(player: Player)
	local sighting = active
	if sighting then
		bannerRemote:FireClient(player, "Started", startedInfo(sighting))
	end
	for _, entry in pairs(captures) do
		bannerRemote:FireClient(player, if entry.Phase == "Dropped" then "Dropped" else "PickedUp", captureInfo(entry))
	end
end

--- True while a Hunt (HuntService) is on. Read from the HuntState object
--- it publishes, so this service never has to require a later one.
local function huntActive(): boolean
	local state = ReplicatedStorage:FindFirstChild("HuntState")
	local phase = state and state:GetAttribute("Phase")
	return phase ~= nil and phase ~= "Idle"
end

local function tick()
	local sighting = active
	if #Players:GetPlayers() == 0 then
		-- Nobody to see it: no sightings until someone loads in again.
		if sighting then
			escape("server empty")
		end
		nextAt = nil
		return
	end
	if sighting then
		if serverNow() >= sighting.ExpiresAt then
			escape("timed out")
		elseif sighting.Model.Parent == nil then
			escape("model removed")
		end
		return
	end
	if Config.Sightings.Enabled and nextAt and os.clock() >= nextAt then
		if huntActive() then
			-- One big event at a time: wait for the Brood Mother to leave.
			nextAt = os.clock() + Config.Hunt.BusyRetry
			return
		end
		local ok, message = spawnSighting(nil)
		if not ok then
			warn("[SAC/Sighting] spawn failed: " .. message)
			scheduleNext()
		end
	end
end

function SightingService.Start()
	bannerRemote = RemoteGuard.GetClientEvent("SightingBanner")
	announceRemote = RemoteGuard.GetClientEvent("GlobalAnnounce")
	runtimeFolder = Workspace:WaitForChild("Runtime") :: Folder

	StealService.SetDecorator("Sighting", decorateCapture)
	StealService.ItemTaken:Connect(onItemTaken)
	StealService.ItemDropped:Connect(onItemDropped)
	StealService.Claimed:Connect(onClaimed)
	StealService.CaptureEscaped:Connect(onCaptureEscaped)

	BatService.Bonked:Connect(function(target: Player, swinger: Player)
		if holds[target] then
			interrupt(target, string.format("%s bonked you — capture interrupted!", swinger.DisplayName), swinger.DisplayName)
		end
	end)

	DataService.ProfileLoaded:Connect(function(player: Player)
		-- The first player in a fresh (or emptied) server starts the clock.
		if not active and nextAt == nil then
			nextAt = os.clock() + Config.Sightings.FirstDelay
		end
		syncPlayer(player)
	end)
	-- Profiles that loaded before this service started.
	for _, player in ipairs(Players:GetPlayers()) do
		if DataService.IsLoaded(player) and nextAt == nil then
			nextAt = os.clock() + Config.Sightings.FirstDelay
		end
	end

	local function hookPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			hookCharacter(player, character)
		end)
		if player.Character then
			task.spawn(hookCharacter, player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(hookPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		hookPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		holds[player] = nil
		lastNotice[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(TICK)
			local ok, err = pcall(tick)
			if not ok then
				warn("[SAC/Sighting] tick errored: " .. tostring(err))
			end
		end
	end)
end

--------------------------------------------------------------------------
-- Debug (Studio: SAC_Debug sighting / sightingend / sightings)
--------------------------------------------------------------------------

--- Spawns one now. `what` = a rarity ("Legendary") or creature id ("mothman").
function SightingService.DebugSpawn(what: string?): string
	if what ~= nil and not Config.Rarities[what] and not Config.CreaturesById[what] then
		return "unknown rarity or creature id: " .. tostring(what)
	end
	local _, message = spawnSighting(what)
	return message
end

function SightingService.DebugEnd(): string
	if not active then
		return "no active sighting"
	end
	escape("debug")
	return "sighting escaped"
end

function SightingService.DebugState(): string
	local lines = { "enabled=" .. tostring(Config.Sightings.Enabled) }
	local sighting = active
	if sighting then
		table.insert(lines, string.format("active #%d: %s at %s (%s), %.0fs left, %d hold(s)",
			sighting.Id, sighting.Label, tostring(sighting.Position), sighting.Hint,
			sighting.ExpiresAt - serverNow(), (function()
				local n = 0
				for _ in pairs(holds) do
					n += 1
				end
				return n
			end)()))
	else
		table.insert(lines, if nextAt
			then string.format("next sighting in %.0fs", nextAt - os.clock())
			else "waiting for a player to load in")
	end
	for _, entry in pairs(captures) do
		table.insert(lines, string.format("capture carry %d: %s, %s by %s", entry.CarryId, entry.Label, entry.Phase, entry.By))
	end
	local count = #Players:GetPlayers()
	local weights = SightingService.GetWeights(count)
	local total = 0
	for _, w in pairs(weights) do
		total += w
	end
	local parts = {}
	for _, rarity in ipairs(Config.RarityOrder) do
		if weights[rarity] then
			table.insert(parts, string.format("%s %.1f%%", rarity, weights[rarity] / total * 100))
		end
	end
	table.insert(lines, string.format("odds with %d player(s): %s", count, table.concat(parts, ", ")))
	return table.concat(lines, "\n")
end

return SightingService
