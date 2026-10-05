--!strict
--[[
	HuntService
	ServerScriptService/Server/Services/HuntService

	The Hunt — the game's scary twist (Config.Hunt).

	Every MinInterval..MaxInterval seconds the night deepens and the Brood
	Mother — mother of every cryptid egg in the woods — comes out of The
	Wilds to take her eggs back:

	  Warning  (WarningTime)  lights flicker, she wails, a nest of black
	                          branches appears where she'll emerge
	  Hunting  (Duration)     she glides after whoever is carrying an egg
	                          (a stolen one or a fresh one off the belt);
	                          with no carrier near, she stalks anyone close
	  Leaving  (LeaveTime)    she sinks back into the woods

	She is a ghost: she floats through trees and rocks, but she will never
	cross into a camp (any camp) or into the hub campfire's light, so those
	are safe. If she catches you: a jumpscare, a stun and a knockback, and
	she takes back what you're carrying (a stolen egg goes home to its
	owner; a belt egg or a captured cryptid is gone).

	She is NOT a physical model on the server. The server owns her logical
	position and publishes it as attributes on ReplicatedStorage.HuntState
	(Phase, Position, Yaw, TargetUserId, StartsAt, EndsAt); every client
	draws her locally and smooths between updates (HuntController). That
	keeps her smooth at a distance and immune to StreamingEnabled — the same
	idea as the egg belt. Catches are decided here, by distance.

	Remote: HuntEvent (server -> all clients):
	  ("Warning", {StartsAt, Position})  ("Started", {EndsAt})
	  ("Caught", {UserId, Name, Item?, Position})  ("Ended", {Caught})
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
local DataService = require(Services:WaitForChild("DataService"))
local PlotService = require(Services:WaitForChild("PlotService"))
local MovementService = require(Services:WaitForChild("MovementService"))
local StealService = require(Services:WaitForChild("StealService"))

local HuntService = {}

local TAU = math.pi * 2
local HUB_CENTRE = Vector3.new(0, 0, 0)

type HuntPhase = "Idle" | "Warning" | "Hunting" | "Leaving"

local state: Configuration
local eventRemote: RemoteEvent
local runtimeFolder: Folder

local phase: HuntPhase = "Idle"
local position = Vector3.zero
local heading = Vector3.new(0, 0, -1)
local target: Player? = nil
local wanderPoint: Vector3? = nil
local caughtCount = 0
local victimCooldown: { [Player]: number } = {}
local stunned: { [Player]: number } = {}
-- Players she gave up on (couldn't get closer): not targeted until then.
local giveUpUntil: { [Player]: number } = {}
-- Progress toward the current target: best flat distance and when it improved.
local bestDistToTarget = math.huge
local bestDistAt = 0
local nestModel: Model? = nil
local forceStart = false
local forceEnd = false

local function log(fmt: string, ...: any)
	if Config.Debug.Verbose then
		print(string.format("[SAC/Hunt] " .. fmt, ...))
	end
end

--- Starts tracking progress toward a (new) target from scratch.
local function resetProgress()
	bestDistToTarget = math.huge
	bestDistAt = os.clock()
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

--------------------------------------------------------------------------
-- Where she may go
--------------------------------------------------------------------------

local GROUND_PARAMS = RaycastParams.new()
GROUND_PARAMS.FilterType = Enum.RaycastFilterType.Include

local function refreshGroundFilter()
	local include: { Instance } = { Workspace.Terrain }
	local map = Workspace:FindFirstChild("Map")
	local ground = map and map:FindFirstChild("Ground")
	if ground then
		table.insert(include, ground)
	end
	GROUND_PARAMS.FilterDescendantsInstances = include
end

--- Height of the ground (terrain / ground part) under a point.
local function groundY(x: number, z: number): number
	local hit = Workspace:Raycast(Vector3.new(x, 400, z), Vector3.new(0, -800, 0), GROUND_PARAMS)
	return if hit then hit.Position.Y else 0
end

--- True if any camp's footprint (plus a margin) contains this point.
local function inAnyCamp(point: Vector3, margin: number): boolean
	local half = Config.Plot.Size / 2
	for _, plot in ipairs(PlotService.GetPlots()) do
		local localPos = plot.CFrame:PointToObjectSpace(Vector3.new(point.X, plot.CFrame.Position.Y, point.Z))
		if math.abs(localPos.X) <= half.X + margin and math.abs(localPos.Z) <= half.Z + margin then
			return true
		end
	end
	return false
end

local function inCampfireLight(point: Vector3, margin: number): boolean
	return flat(point - HUB_CENTRE).Magnitude < Config.Hunt.CampfireSafeRadius + margin
end

--- Somewhere she must not step.
local function forbidden(point: Vector3): boolean
	local h = Config.Hunt
	if h.SafeInCamps and inAnyCamp(point, 4) then
		return true
	end
	if inCampfireLight(point, 2) then
		return true
	end
	return flat(point - HUB_CENTRE).Magnitude > Config.Map.BoundaryRadius - h.BoundaryMargin
end

--- A player she can never reach: hugging the map edge, past where she
--- can go (BoundaryMargin, minus ~2 studs lost to her look-ahead probe)
--- plus her catch reach. She doesn't chase them.
local function outOfReach(p: Vector3): boolean
	local h = Config.Hunt
	return flat(p - HUB_CENTRE).Magnitude > Config.Map.BoundaryRadius - h.BoundaryMargin - 2 + h.CatchRadius - 1
end

--- Is this player somewhere she won't follow?
local function isSafe(root: BasePart): boolean
	local p = root.Position
	return (Config.Hunt.SafeInCamps and inAnyCamp(p, 0)) or inCampfireLight(p, 0)
end

local function randomWildsPoint(rng: Random): Vector3
	local m = Config.Map
	for _ = 1, 20 do
		local angle = rng:NextNumber(0, TAU)
		local radius = rng:NextNumber(m.WildsInnerRadius + 20, m.WildsOuterRadius - 30)
		local p = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		if not forbidden(p) then
			return p
		end
	end
	return Vector3.new(m.WildsInnerRadius + 40, 0, 0)
end

--- A point somewhere players actually are: the open ground between the
--- campfire light and the plot ring, or just outside the ring.
local function randomProwlPoint(rng: Random): Vector3
	local inner = Config.Hunt.CampfireSafeRadius + 15
	local outer = Config.Plot.RingRadius + Config.Plot.Size.X
	for _ = 1, 20 do
		local angle = rng:NextNumber(0, TAU)
		local radius = rng:NextNumber(inner, outer)
		local p = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		if not forbidden(p) then
			return p
		end
	end
	return randomWildsPoint(rng)
end

--------------------------------------------------------------------------
-- State publishing
--------------------------------------------------------------------------

local function publish()
	state:SetAttribute("Phase", phase)
	state:SetAttribute("Position", position)
	state:SetAttribute("Yaw", math.atan2(-heading.X, -heading.Z))
	state:SetAttribute("TargetUserId", if target then target.UserId else 0)
end

local function setPhase(newPhase: HuntPhase)
	phase = newPhase
	state:SetAttribute("Phase", newPhase)
end

--------------------------------------------------------------------------
-- Her nest (marks where she emerges)
--------------------------------------------------------------------------

local function buildFallbackNest(): Model
	local model = Instance.new("Model")
	model.Name = "BroodNest"
	local rng = Random.new(7)
	local centre: BasePart? = nil
	for i = 1, 14 do
		local angle = (i / 14) * TAU
		local branch = Instance.new("Part")
		branch.Name = "Branch"
		branch.Anchored = true
		branch.CanCollide = false
		branch.CanQuery = false
		branch.CanTouch = false
		branch.Material = Enum.Material.Wood
		branch.Color = Color3.fromRGB(28, 22, 20)
		branch.Size = Vector3.new(0.7, 0.7, rng:NextNumber(7, 11))
		branch.CFrame = CFrame.new(math.cos(angle) * 4.5, 1.2, math.sin(angle) * 4.5)
			* CFrame.Angles(rng:NextNumber(-0.5, 0.5), angle + math.pi / 2 + rng:NextNumber(-0.4, 0.4), rng:NextNumber(-0.3, 0.3))
		branch.Parent = model
		centre = centre or branch
	end
	local glow = Instance.new("Part")
	glow.Name = "Glow"
	glow.Shape = Enum.PartType.Cylinder
	glow.Anchored = true
	glow.CanCollide = false
	glow.CanQuery = false
	glow.CanTouch = false
	glow.Material = Enum.Material.Neon
	glow.Color = Config.Hunt.Color
	glow.Transparency = 0.55
	glow.Size = Vector3.new(0.4, 7, 7)
	glow.CFrame = CFrame.new(0, 0.3, 0) * CFrame.Angles(0, 0, math.pi / 2)
	glow.Parent = model
	model.PrimaryPart = glow
	glow.PivotOffset = glow.CFrame:Inverse()
	return model
end

local function placeNest(at: Vector3)
	if nestModel then
		nestModel:Destroy()
	end
	local template = ItemVisuals.GetTemplate("Props", "BroodNest")
	local model: Model
	if template then
		model = template:Clone()
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
			end
		end
	else
		model = buildFallbackNest()
	end
	model.Name = "BroodNest"
	local light = Instance.new("PointLight")
	light.Color = Config.Hunt.Color
	light.Range = 22
	light.Brightness = 2
	light.Parent = model.PrimaryPart
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	model:PivotTo(CFrame.new(at.X, groundY(at.X, at.Z), at.Z))
	model.Parent = runtimeFolder
	nestModel = model
end

local function removeNest()
	if nestModel then
		nestModel:Destroy()
		nestModel = nil
	end
end

--------------------------------------------------------------------------
-- Catching
--------------------------------------------------------------------------

local function stun(player: Player, from: Vector3)
	local root = RemoteGuard.GetRoot(player)
	local until_ = os.clock() + Config.Hunt.StunDuration
	stunned[player] = until_
	MovementService.SetModifier(player, "BroodMother", 0)
	MovementService.SetJumpBlocked(player, "BroodMother", true)
	task.delay(Config.Hunt.StunDuration, function()
		if stunned[player] == until_ then
			stunned[player] = nil
			MovementService.SetModifier(player, "BroodMother", nil)
			MovementService.SetJumpBlocked(player, "BroodMother", false)
		end
	end)

	if root then
		local away = flat(root.Position - from)
		local direction = if away.Magnitude > 0.1 then away.Unit else Vector3.new(0, 0, 1)
		local attachment = Instance.new("Attachment")
		attachment.Name = "BroodKnockback"
		attachment.Parent = root
		local velocity = Instance.new("LinearVelocity")
		velocity.Attachment0 = attachment
		velocity.RelativeTo = Enum.ActuatorRelativeTo.World
		velocity.MaxForce = 1e6
		velocity.VectorVelocity = direction * Config.Hunt.KnockbackVelocity + Vector3.new(0, 18, 0)
		velocity.Parent = root
		task.delay(0.18, function()
			velocity:Destroy()
			attachment:Destroy()
		end)
	end
end

--- Takes back whatever the player is carrying. Returns a label for it.
local function reclaim(player: Player): string?
	local carry = StealService.GetCarry(player)
	if not carry then
		return nil
	end
	local slot = carry.Slot
	local label: string
	if slot.Kind == "Egg" then
		local egg = Config.Eggs[slot.EggId]
		label = if egg then egg.Name else "egg"
	else
		local def = Config.CreaturesById[slot.CreatureId]
		label = if def then def.Name else "cryptid"
	end
	StealService.Reclaim(player, Config.Hunt.ReclaimReason)
	return label
end

local function catch(player: Player)
	victimCooldown[player] = os.clock() + Config.Hunt.VictimCooldown
	if target == player then
		target = nil
		resetProgress()
	end
	local item = reclaim(player)
	stun(player, position)
	caughtCount += 1

	local data = DataService.Get(player)
	if data then
		DataService.Mutate(player, function(d)
			d.Stats.CaughtByMother = (d.Stats.CaughtByMother or 0) + 1
		end)
	end

	if item then
		Notifier.Send(player, string.format("%s took back the %s!", Config.Hunt.Name, item), "Error")
	else
		Notifier.Send(player, string.format("%s caught you! Stay near the fire or inside a camp.", Config.Hunt.Name), "Error")
	end
	eventRemote:FireAllClients("Caught", {
		UserId = player.UserId,
		Name = player.DisplayName,
		Item = item,
		Position = position,
	})
	log("caught %s%s", player.Name, if item then (" and took back " .. item) else "")
end

--------------------------------------------------------------------------
-- Hunting behaviour
--------------------------------------------------------------------------

local function eligible(player: Player): BasePart?
	if (victimCooldown[player] or 0) > os.clock() or stunned[player] then
		return nil
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = RemoteGuard.GetRoot(player)
	if not root or not humanoid or humanoid.Health <= 0 then
		return nil
	end
	if isSafe(root) then
		return nil
	end
	return root
end

local function pickTarget(): Player?
	local h = Config.Hunt
	local bestCarrier: Player? = nil
	local bestCarrierDist = math.huge
	local bestOther: Player? = nil
	local bestOtherDist = math.huge
	for _, player in ipairs(Players:GetPlayers()) do
		local root = eligible(player)
		if root and not outOfReach(root.Position) and (giveUpUntil[player] or 0) <= os.clock() then
			local dist = flat(root.Position - position).Magnitude
			if StealService.IsCarrying(player) then
				if dist <= h.SenseRadius and dist < bestCarrierDist then
					bestCarrier, bestCarrierDist = player, dist
				end
			elseif dist <= h.StalkRadius and dist < bestOtherDist then
				bestOther, bestOtherDist = player, dist
			end
		end
	end
	return bestCarrier or bestOther
end

local function rotate(v: Vector3, angle: number): Vector3
	local c, s = math.cos(angle), math.sin(angle)
	return Vector3.new(v.X * c - v.Z * s, 0, v.X * s + v.Z * c)
end

local STEER_TRIES = { 0, math.rad(35), -math.rad(35), math.rad(70), -math.rad(70), math.rad(110), -math.rad(110), math.rad(150), -math.rad(150) }

local function step(dt: number, rng: Random)
	local h = Config.Hunt

	-- Where to?
	local goal: Vector3
	local chasing = false
	local root = target and eligible(target)
	if root and outOfReach(root.Position) then
		root = nil -- hugging the map edge: she can't get there
	end
	if target and root then
		goal = root.Position
		chasing = StealService.IsCarrying(target)
		-- Not getting any closer (boxed in, or they outrun her)? Give up on
		-- them for a while and prowl instead of jittering in place.
		local now = os.clock()
		local dist = flat(goal - position).Magnitude
		if dist < bestDistToTarget - h.GiveUpProgress then
			bestDistToTarget = dist
			bestDistAt = now
		elseif now - bestDistAt > h.GiveUpTime then
			log("gave up on %s", target.Name)
			giveUpUntil[target] = now + h.VictimCooldown
			target = nil
			chasing = false
			wanderPoint = randomProwlPoint(rng)
			goal = wanderPoint :: Vector3
		end
	else
		target = nil
		if not wanderPoint or flat(wanderPoint - position).Magnitude < 8 then
			wanderPoint = randomProwlPoint(rng)
		end
		goal = wanderPoint :: Vector3
	end

	local toGoal = flat(goal - position)
	if toGoal.Magnitude > 0.5 then
		local desired = toGoal.Unit
		-- Turn smoothly toward the goal.
		local cross = heading.X * desired.Z - heading.Z * desired.X
		local dot = math.clamp(heading:Dot(desired), -1, 1)
		local angle = math.atan2(cross, dot)
		local maxTurn = h.TurnSpeed * dt
		heading = rotate(heading, math.clamp(angle, -maxTurn, maxTurn))
		if heading.Magnitude < 0.01 then
			heading = desired
		end
		heading = heading.Unit
	end

	local speed = h.Speed + (if chasing then h.ChaseSpeedBonus else 0)
	local distance = math.min(speed * dt, toGoal.Magnitude)
	if distance <= 0 then
		return
	end

	-- Slide around camps and the campfire light rather than into them.
	for _, offset in ipairs(STEER_TRIES) do
		local direction = rotate(heading, offset)
		local nextPos = position + direction * distance
		local probe = position + direction * (distance + 6)
		if not forbidden(nextPos) and not forbidden(probe) then
			position = Vector3.new(nextPos.X, groundY(nextPos.X, nextPos.Z) + h.HoverHeight, nextPos.Z)
			if offset ~= 0 then
				heading = direction
			end
			return
		end
	end
	-- Boxed in: pick somewhere else to go.
	wanderPoint = randomProwlPoint(rng)
end

local function checkCatches()
	local h = Config.Hunt
	for _, player in ipairs(Players:GetPlayers()) do
		local root = eligible(player)
		if root and flat(root.Position - position).Magnitude <= h.CatchRadius
			and math.abs(root.Position.Y - position.Y) < 14 then
			catch(player)
		end
	end
end

--------------------------------------------------------------------------
-- One hunt, start to finish
--------------------------------------------------------------------------

local function runHunt(rng: Random)
	local h = Config.Hunt
	caughtCount = 0
	victimCooldown = {}
	giveUpUntil = {}
	target = nil
	resetProgress()
	wanderPoint = nil
	forceEnd = false
	refreshGroundFilter()

	-- Warning
	local emerge = randomWildsPoint(rng)
	position = Vector3.new(emerge.X, groundY(emerge.X, emerge.Z), emerge.Z)
	heading = flat(HUB_CENTRE - position).Unit
	placeNest(position)
	local startsAt = serverNow() + h.WarningTime
	state:SetAttribute("StartsAt", startsAt)
	state:SetAttribute("EndsAt", startsAt + h.Duration)
	setPhase("Warning")
	publish()
	eventRemote:FireAllClients("Warning", { StartsAt = startsAt, Position = position })
	log("warning — she emerges at %s in %ds", tostring(position), h.WarningTime)
	local warnUntil = os.clock() + h.WarningTime
	while os.clock() < warnUntil and not forceEnd do
		task.wait(0.2)
	end

	-- Hunting
	setPhase("Hunting")
	local endsAt = serverNow() + h.Duration
	state:SetAttribute("EndsAt", endsAt)
	eventRemote:FireAllClients("Started", { EndsAt = endsAt })
	log("hunting for %ds", h.Duration)

	local huntUntil = os.clock() + h.Duration
	local interval = 1 / h.TickRate
	local lastTick = os.clock()
	local lastRetarget = 0
	while os.clock() < huntUntil and not forceEnd do
		task.wait(interval)
		local now = os.clock()
		local dt = math.min(now - lastTick, 0.25)
		lastTick = now
		if now - lastRetarget >= h.RetargetInterval then
			lastRetarget = now
			local best = pickTarget()
			if best ~= target then
				target = best
				resetProgress()
				if best then
					wanderPoint = nil
				end
			end
		end
		local ok, err = pcall(step, dt, rng)
		if not ok then
			warn("[SAC/Hunt] step errored: " .. tostring(err))
		end
		local caughtOk, caughtErr = pcall(checkCatches)
		if not caughtOk then
			warn("[SAC/Hunt] catch check errored: " .. tostring(caughtErr))
		end
		publish()
	end

	-- Leaving
	target = nil
	setPhase("Leaving")
	publish()
	task.wait(h.LeaveTime)
	removeNest()
	setPhase("Idle")
	state:SetAttribute("TargetUserId", 0)
	eventRemote:FireAllClients("Ended", { Caught = caughtCount })
	if caughtCount == 0 then
		Notifier.SendAll(string.format("%s slipped back into the woods... empty-handed.", Config.Hunt.Name), "Info")
	end
	log("ended — caught %d", caughtCount)
end

--------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------

--- True from the warning until she's gone.
function HuntService.IsActive(): boolean
	return phase ~= "Idle"
end

--- Debug: start a hunt now (the scheduler picks it up within a second).
function HuntService.DebugStart(): string
	if phase ~= "Idle" then
		return "already hunting (" .. phase .. ")"
	end
	forceStart = true
	return "hunt starting"
end

--- Debug: end the current hunt now.
function HuntService.DebugEnd(): string
	if phase == "Idle" then
		return "no hunt running"
	end
	forceEnd = true
	return "hunt ending"
end

function HuntService.DebugState(): string
	return string.format("phase=%s pos=%s target=%s caught=%d", phase, tostring(position),
		if target then target.Name else "none", caughtCount)
end

--- A sighting is running, or a captured wild cryptid is still out (carried
--- home or lying dropped): its banner owns the screen until it's settled.
local function sightingActive(): boolean
	return #CollectionService:GetTagged(Config.Tags.WildCryptid) > 0
		or StealService.CountSource("Sighting") > 0
end

function HuntService.Start()
	eventRemote = RemoteGuard.GetClientEvent("HuntEvent")
	runtimeFolder = Workspace:WaitForChild("Runtime") :: Folder

	state = Instance.new("Configuration")
	state.Name = "HuntState"
	state:SetAttribute("Phase", "Idle")
	state:SetAttribute("Position", Vector3.zero)
	state:SetAttribute("Yaw", 0)
	state:SetAttribute("TargetUserId", 0)
	state:SetAttribute("StartsAt", 0)
	state:SetAttribute("EndsAt", 0)
	state.Parent = ReplicatedStorage

	Players.PlayerRemoving:Connect(function(player)
		victimCooldown[player] = nil
		giveUpUntil[player] = nil
		stunned[player] = nil
		if target == player then
			target = nil
		end
	end)

	if not Config.Hunt.Enabled then
		return
	end

	task.spawn(function()
		local rng = Random.new()
		-- Wait for someone to be in the server, then the first delay.
		while #Players:GetPlayers() == 0 do
			task.wait(1)
		end
		local nextAt = os.clock() + Config.Hunt.FirstDelay
		while true do
			task.wait(0.5)
			local due = forceStart or os.clock() >= nextAt
			if due and #Players:GetPlayers() > 0 then
				if sightingActive() and not forceStart then
					nextAt = os.clock() + Config.Hunt.BusyRetry
				else
					forceStart = false
					local ok, err = pcall(runHunt, rng)
					if not ok then
						warn("[SAC/Hunt] hunt errored: " .. tostring(err))
						removeNest()
						setPhase("Idle")
						target = nil
						state:SetAttribute("TargetUserId", 0)
						-- Clients restore their lights and fog only on "Ended".
						local endedOk, endedErr = pcall(function()
							eventRemote:FireAllClients("Ended", { Caught = caughtCount })
						end)
						if not endedOk then
							warn("[SAC/Hunt] couldn't send Ended after error: " .. tostring(endedErr))
						end
					end
					nextAt = os.clock() + rng:NextNumber(Config.Hunt.MinInterval, Config.Hunt.MaxInterval)
				end
			end
		end
	end)
end

return HuntService
