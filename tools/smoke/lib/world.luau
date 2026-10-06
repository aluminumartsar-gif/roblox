--!nocheck
-- The fake server: what src/server would have put in the data model by the
-- time the client runs, plus answers to the client's remotes and the
-- server->client events the scenario fires. Shapes follow the real server
-- code (DataService snapshot, RetentionService state, SightingService /
-- StealService / HuntService infos, MapBuilder names and tags).
--
-- World objects are built with the game's own Shared/ItemVisuals, loaded in
-- a separate "server" module realm (its own copy of Config), so eggs and
-- creatures look exactly like the server's.

local roblox = require("@lune/roblox")
local Inst = require("./inst")
local Loader = require("./loader")
local Report = require("./report")
local Sched = require("./sched")
local Services = require("./services")
local Util = require("./util")
local Classes = require("./classes")

local S = Inst.S
local get = Inst.get

local Vector3 = roblox.Vector3
local Vector2 = roblox.Vector2
local CFrame = roblox.CFrame
local Color3 = roblox.Color3
local UDim2 = roblox.UDim2
local Enum = roblox.Enum

local World = {}

World.remotes = {}
World.plots = {}
World.items = {} -- "plot:nest" -> model
World.player = nil
World.other = nil
World.data = nil -- the local player's profile (server side)
World.carryId = 100

--------------------------------------------------------------------------
-- Instance helpers (server side: no API checks needed, but use real props)
--------------------------------------------------------------------------

local function new(className: string, props: { [string]: any }?, parent: any?): any
	local inst = Inst.create(className)
	local st = S[inst]
	if props then
		for k, v in props do
			if k == "Name" then
				st.name = v
			else
				local p = st.info.rec.props[k]
				assert(p, "world: " .. className .. " has no property " .. k)
				local s = st.info.setters[k]
				if s then
					s(inst, st, v)
				else
					st.props[k] = v
				end
			end
		end
	end
	if parent then
		Inst.setParent(inst, st, parent, true)
	end
	return inst
end
World.new = new

local function setParent(inst, parent)
	Inst.setParent(inst, S[inst], parent, true)
end

local function attr(inst, name, value)
	Inst.setAttribute(inst, name, value)
end

local function serverNow(): number
	return Sched.EPOCH + Sched.now
end
World.serverNow = serverNow

local function svc(name)
	return Services.byClass[name]
end

--------------------------------------------------------------------------
-- Server-side modules (separate realm)
--------------------------------------------------------------------------

local serverRealm
local Config, ItemVisuals, BeltPath, ProfileTemplate

local function serverRequire(inst)
	local result
	local co = Sched.run(function()
		result = serverRealm.require(inst)
	end, "fake server require")
	assert(result ~= nil, "world: server-side require failed for " .. Inst.fullName(inst))
	return result
end

--------------------------------------------------------------------------
-- Remotes
--------------------------------------------------------------------------

World.handlers = {} -- remote name -> function(player, ...) -> response

local function logCall(remote, kind: string, args)
	local name = S[remote].name
	Report.stats.remoteCounts[name] = (Report.stats.remoteCounts[name] or 0) + 1
	if #Report.stats.remoteCalls < 300 then
		table.insert(Report.stats.remoteCalls, {
			name = name,
			kind = kind,
			args = Util.showArgs(args, args.n),
			t = Sched.now,
			step = Report.step,
			loc = Report.callerLocation(),
		})
	end
end

local function copyArgs(args)
	local out = { n = args.n }
	for i = 1, args.n do
		out[i] = Util.deepCopy(args[i])
	end
	return out
end

Classes.remoteHooks = {
	fireServer = function(remote, args)
		logCall(remote, "FireServer", args)
		local handler = World.handlers[S[remote].name]
		if handler then
			local copied = copyArgs(args)
			Sched.after(0.05, function()
				handler(World.player, table.unpack(copied, 1, copied.n))
			end)
		end
	end,
	invokeServer = function(remote, args)
		logCall(remote, "InvokeServer", args)
		local copied = copyArgs(args)
		Sched.sleep(0.1) -- round trip
		local handler = World.handlers[S[remote].name]
		local result
		if handler then
			result = handler(World.player, table.unpack(copied, 1, copied.n))
		else
			result = { Ok = false, Message = "smoke: no fake handler for " .. S[remote].name }
		end
		return Util.deepCopy(result)
	end,
}

--- Server -> client event to the local player (args are copied like Roblox).
function World.fire(remoteName: string, ...: any)
	local remote = World.remotes[remoteName]
	assert(remote, "world: no remote " .. remoteName)
	local args = copyArgs(table.pack(...))
	Inst.fire(remote, "OnClientEvent", table.unpack(args, 1, args.n))
	Sched.drain()
end

--------------------------------------------------------------------------
-- Profile and retention payloads
--------------------------------------------------------------------------

function World.snapshot()
	local d = World.data
	return {
		Cash = d.Cash,
		Rebirths = d.Rebirths,
		Nests = d.Nests,
		Upgrades = d.Upgrades,
		Codex = d.Codex,
		Buffs = d.Buffs,
		Stats = d.Stats,
		IsPersistent = World.persistent ~= false,
		ServerTime = math.floor(serverNow()),
	}
end

function World.pushProfile()
	World.fire("ProfileUpdated", World.snapshot())
	local ls = Inst.findChild(S[World.player], "leaderstats")
	if ls then
		local cash = Inst.findChild(S[ls], "Cash")
		if cash then
			Inst.setRaw(cash, S[cash], "Value", math.floor(World.data.Cash))
		end
	end
end

local function itemText(item): string
	local R = Config.Retention
	if item.Kind == "Cash" then
		return "$" .. Config.FormatNumber(math.max(item.Base or 0, (item.Minutes or 0) * 60 * 5))
	elseif item.Kind == "Egg" then
		local egg = Config.Eggs[item.EggId or ""] or Config.Eggs.forest
		local count = item.Count or 1
		return if count > 1 then string.format("%dx %s", count, egg.Name) else egg.Name
	elseif item.Kind == "Buff" then
		return string.format("%s %dm", R.BuffNames[item.Buff or ""] or tostring(item.Buff), (item.Duration or 0) // 60)
	elseif item.Kind == "InstantHatch" then
		return "Instant Hatch"
	end
	return "?"
end

local function describe(reward)
	local R = Config.Retention
	local parts = {}
	for _, item in reward.Items do
		table.insert(parts, itemText(item))
	end
	local first = reward.Items[1]
	local icon = R.Icons.Cash
	if first then
		icon = if first.Kind == "Buff" then (R.Icons[first.Buff or ""] or R.Icons.Cash) else (R.Icons[first.Kind] or R.Icons.Cash)
	end
	return {
		Text = reward.Label or table.concat(parts, " + "),
		Detail = table.concat(parts, " + "),
		Short = reward.Label or parts[1] or "?",
		Icon = icon,
	}
end

World.retention = {
	dailyCanClaim = true,
	dailyDay = 1,
	spinsExtra = 0,
	freeSpinReady = true,
	giftsClaimed = {},
	pendingOffline = 1840,
	awaySeconds = 3 * 3600,
	computed = true,
	startedAt = 0,
}

function World.retentionState()
	local R = Config.Retention
	local r = World.retention
	local now = math.floor(serverNow())
	local dailyRewards = {}
	for i, reward in R.Daily.Rewards do
		dailyRewards[i] = describe(reward)
	end
	local prizes = {}
	for i, prize in R.Spin.Prizes do
		prizes[i] = describe(prize)
	end
	local gifts = {}
	for i, gift in R.Playtime.Gifts do
		local entry = describe(gift)
		entry.UnlockAt = math.floor(Sched.EPOCH + r.startedAt) + (gift.Minutes or 0) * 60
		entry.Claimed = r.giftsClaimed[i] == true
		gifts[i] = entry
	end
	return {
		ServerNow = now,
		Daily = {
			Enabled = R.Daily.Enabled,
			CanClaim = r.dailyCanClaim,
			Day = r.dailyDay,
			ClaimedCount = if r.dailyCanClaim then r.dailyDay - 1 else r.dailyDay,
			NextClaimAt = if r.dailyCanClaim then 0 else (now // R.Daily.DayLength + 1) * R.Daily.DayLength,
			Rewards = dailyRewards,
		},
		Spin = {
			Enabled = R.Spin.Enabled,
			FreeReady = r.freeSpinReady,
			NextFreeAt = if r.freeSpinReady then 0 else now + R.Spin.FreeEvery,
			Extra = r.spinsExtra,
			Spins = (if r.freeSpinReady then 1 else 0) + r.spinsExtra,
			Prizes = prizes,
		},
		Gifts = {
			Enabled = R.Playtime.Enabled,
			List = gifts,
		},
		Offline = {
			Enabled = R.Offline.Enabled,
			Pending = r.pendingOffline,
			AwaySeconds = r.awaySeconds,
			Computed = r.computed,
		},
	}
end

function World.pushRetention()
	World.fire("RetentionState", World.retentionState())
end

--------------------------------------------------------------------------
-- The map (names, tags and attributes as MapBuilder makes them)
--------------------------------------------------------------------------

local function plotCFrame(index: number): CFrame
	local angle = (index - 1) / Config.Plot.Count * math.pi * 2
	local pos = Vector3.new(math.cos(angle), 0, math.sin(angle)) * Config.Plot.RingRadius
	return CFrame.lookAt(pos, Vector3.new(0, 0, 0))
end
World.plotCFrame = plotCFrame

local function nestOffset(k: number): Vector3
	local p = Config.Plot
	local cols = p.NestGridColumns
	local rows = math.ceil(p.MaxNests / cols)
	local c = (k - 1) % cols
	local r = math.floor((k - 1) / cols)
	local x = (c - (cols - 1) / 2) * p.NestSpacing
	local z = (r - (rows - 1) / 2) * p.NestSpacing + p.NestSpacing / 2
	return Vector3.new(x, p.FloorHeight, z)
end

local function part(name: string, cf: CFrame, size: Vector3, parent, props: { [string]: any }?)
	local all = { Name = name, CFrame = cf, Size = size, Anchored = true }
	if props then
		for k, v in props do
			all[k] = v
		end
	end
	return new("Part", all, parent)
end

local function prompt(name: string, parent, actionText: string, objectText: string, hold: number, extra: { [string]: any }?)
	local props = {
		Name = name,
		ActionText = actionText,
		ObjectText = objectText,
		HoldDuration = hold,
		MaxActivationDistance = Config.Prompts.MaxActivationDistance,
		RequiresLineOfSight = Config.Prompts.RequiresLineOfSight,
	}
	if extra then
		for k, v in extra do
			props[k] = v
		end
	end
	return new("ProximityPrompt", props, parent)
end

local function buildPlot(index: number, parent)
	local cf = plotCFrame(index)
	local plot = new("Model", { Name = "Plot_" .. index }, nil)
	local floor = part("Floor", cf * CFrame.new(0, Config.Plot.FloorHeight / 2, 0), Config.Plot.Size, plot)
	plot.PrimaryPart = floor
	local half = Config.Plot.Size.Z / 2
	local door = part("Door", cf * CFrame.new(0, 7, -half), Vector3.new(Config.Plot.DoorWidth, 14, 1), plot, { Transparency = 1, CanCollide = false })
	attr(door, "PlotIndex", index)
	Inst.addTag(door, Config.Tags.Door)
	local pad = part("Pad", cf * CFrame.new(0, 1.15, -half + 10), Vector3.new(0.3, 9, 9), plot, { Material = Enum.Material.Neon })
	attr(pad, "PlotIndex", index)
	Inst.addTag(pad, Config.Tags.PlotPad)
	local button = part("LockButton", cf * CFrame.new(-16, 4.35, -half + 8), Vector3.new(0.5, 1.8, 1.8), plot, { Material = Enum.Material.Neon })
	prompt("LockPrompt", button, "Lock Camp", "Camp Lock", 0, { KeyboardKeyCode = Enum.KeyCode.E })
	part("Spawn", cf * CFrame.new(0, 1.1, -half + 16) * CFrame.Angles(0, math.pi, 0), Vector3.new(4, 0.2, 4), plot, { Transparency = 1, CanCollide = false })
	local sign = part("Sign", cf * CFrame.new(0, 16, -half - 1), Vector3.new(16, 3.5, 0.5), plot)
	local signGui = new("SurfaceGui", { Name = "SignGui" }, sign)
	new("TextLabel", { Name = "Label", Text = "", Size = UDim2.fromScale(1, 1) }, signGui)
	local billboard = new("BillboardGui", { Name = "OwnerBillboard", Size = UDim2.fromScale(10, 2) }, sign)
	new("TextLabel", { Name = "Label", Text = "", Size = UDim2.fromScale(1, 1) }, billboard)
	local nests = new("Folder", { Name = "Nests" }, plot)
	for k = 1, Config.Plot.MaxNests do
		local ncf = cf * CFrame.new(nestOffset(k))
		local nest = new("Model", { Name = "Nest_" .. k }, nests)
		local base = part("Base", ncf * CFrame.new(0, 0.4, 0) * CFrame.Angles(0, 0, math.pi / 2), Vector3.new(0.8, 8.2, 8.2), nest, { Shape = Enum.PartType.Cylinder })
		new("Attachment", { Name = "ItemAnchor", CFrame = CFrame.new(0.6, 0, 0) }, base)
		part("Glow", ncf * CFrame.new(0, 0.83, 0), Vector3.new(0.06, 7.4, 7.4), nest, { Transparency = 1, Material = Enum.Material.Neon })
		part("Lid", ncf * CFrame.new(0, 2.5, 0), Vector3.new(0.3, 4.6, 4.6), nest)
		nest.PrimaryPart = base
		attr(nest, "PlotIndex", index)
		attr(nest, "NestIndex", k)
		attr(nest, "Active", k <= 6)
		Inst.addTag(nest, Config.Tags.Nest)
	end
	attr(plot, "PlotIndex", index)
	attr(plot, "OwnerUserId", 0)
	attr(plot, "OwnerName", "")
	attr(plot, "LockedUntil", 0)
	attr(plot, "LockCooldownUntil", 0)
	Inst.addTag(plot, Config.Tags.Plot)
	setParent(plot, parent)
	World.plots[index] = plot
	return plot
end

local function itemCFrame(plotIndex: number, nestIndex: number): CFrame
	local cf = plotCFrame(plotIndex)
	return CFrame.new((cf * CFrame.new(nestOffset(nestIndex))).Position + Vector3.new(0, 1, 0)) * cf.Rotation
end
World.itemCFrame = itemCFrame

local function buildHub(map)
	local hub = new("Folder", { Name = "Hub" }, map)
	local campfire = new("Model", { Name = "Campfire" }, hub)
	local core = part("FireCore", CFrame.new(0, 1.25, 0), Vector3.new(3, 2.5, 3), campfire, { Material = Enum.Material.Neon })
	Inst.addTag(core, Config.Map.HubCampfireTag)
	new("PointLight", { Name = "Glow", Range = 40 }, core)

	local belt = new("Model", { Name = "EggBelt" }, hub)
	local slats = new("Folder", { Name = "Slats" }, belt)
	for i = 1, 12 do
		local slat = part("Slat", BeltPath.SlatCFrame(i, serverNow()), Vector3.new(4, 0.2, 1), slats)
		attr(slat, "Index", i)
		Inst.addTag(slat, Config.Tags.BeltSlat)
	end
	for _, which in { "Start", "End" } do
		local angle = if which == "Start" then BeltPath.StartAngle else BeltPath.EndAngle
		local hole = part("Burrow_" .. which, BeltPath.FrameAt(angle, 0.1), Vector3.new(5, 0.2, 5), belt)
		attr(hole, "Which", which)
		Inst.addTag(hole, Config.Tags.Burrow)
		new("ParticleEmitter", { Name = "Mist", Rate = 2 }, hole)
		new("ParticleEmitter", { Name = "Puff", Rate = 0 }, hole)
	end

	local shop = new("Model", { Name = "UpgradeShop" }, hub)
	local counter = part("Counter", CFrame.new(40, 2.75, 40), Vector3.new(14, 3.5, 2), shop)
	attr(counter, "ShopId", "Upgrades")
	Inst.addTag(counter, Config.Tags.ShopBooth)
	local shopPrompt = prompt("ShopPrompt", counter, "Browse", "Upgrades", Config.Prompts.ShopOpenHold)
	attr(shopPrompt, "ShopId", "Upgrades")
	World.shopCounter = counter

	part("HubSpawn", CFrame.new(0, 0.6, 50), Vector3.new(6, 0.2, 6), hub, { Transparency = 1, CanCollide = false })
end

--------------------------------------------------------------------------
-- Nest items, belt eggs, carried items, wild cryptids
--------------------------------------------------------------------------

local function runtime()
	return Inst.findChild(S[svc("Workspace")], "Runtime")
end

function World.removeItem(plotIndex: number, nestIndex: number)
	local key = plotIndex .. ":" .. nestIndex
	local old = World.items[key]
	if old then
		Inst.destroy(old)
		World.items[key] = nil
	end
end

function World.placeEgg(plotIndex: number, nestIndex: number, ownerId: number, eggId: string, progress: number)
	World.removeItem(plotIndex, nestIndex)
	local model = ItemVisuals.BuildEgg(eggId)
	attr(model, "EggId", eggId)
	attr(model, "Progress", progress)
	attr(model, "Remaining", math.ceil(Config.Eggs[eggId].HatchTime * (1 - progress)))
	Inst.addTag(model, Config.Tags.Egg)
	attr(model, "Kind", "Egg")
	attr(model, "OwnerUserId", ownerId)
	attr(model, "PlotIndex", plotIndex)
	attr(model, "NestIndex", nestIndex)
	model:PivotTo(itemCFrame(plotIndex, nestIndex))
	if ownerId ~= World.player and ownerId ~= 1 then
		prompt("StealPrompt", model.PrimaryPart, "Steal", Config.Eggs[eggId].Name, Config.Prompts.StealHold)
	else
		prompt("StealPrompt", model.PrimaryPart, "Steal", Config.Eggs[eggId].Name, Config.Prompts.StealHold)
	end
	setParent(model, runtime())
	World.items[plotIndex .. ":" .. nestIndex] = model
	return model
end

function World.placeCreature(plotIndex: number, nestIndex: number, ownerId: number, creatureId: string, vault: number)
	World.removeItem(plotIndex, nestIndex)
	local def = Config.CreaturesById[creatureId]
	local model = ItemVisuals.BuildCreature(creatureId, nil)
	attr(model, "CreatureId", creatureId)
	attr(model, "Rarity", def.Rarity)
	attr(model, "Vault", math.floor(vault))
	attr(model, "VaultCap", 25000)
	attr(model, "IncomePerSecond", Config.Rarities[def.Rarity].IncomePerSecond * 1.25)
	Inst.addTag(model, Config.Tags.Creature)
	local rarityIndex = Config.GetRarityIndex(def.Rarity)
	prompt("SellPrompt", model.PrimaryPart, "Sell", def.Name,
		if rarityIndex >= Config.Sell.RareHoldFromIndex then Config.Prompts.SellHoldRare else Config.Prompts.SellHold,
		{ Enabled = false })
	attr(model, "Kind", "Creature")
	attr(model, "OwnerUserId", ownerId)
	attr(model, "PlotIndex", plotIndex)
	attr(model, "NestIndex", nestIndex)
	model:PivotTo(itemCFrame(plotIndex, nestIndex))
	setParent(model, runtime())
	World.items[plotIndex .. ":" .. nestIndex] = model
	return model
end

function World.spawnBeltEgg(eggId: string, age: number)
	local def = Config.Eggs[eggId]
	local folder = Inst.findChild(S[runtime()], "EggBelt")
	local model = ItemVisuals.BuildEgg(eggId)
	S[model].name = "BeltEgg"
	attr(model, "BeltEggId", math.random(1, 100000))
	attr(model, "EggId", eggId)
	attr(model, "SpawnTime", serverNow() - age)
	model:PivotTo(BeltPath.EggCFrame(0))
	local shell = model.PrimaryPart
	local anchor = part("BuyAnchor", BeltPath.EggCFrame(age) * CFrame.new(0, 1.7, 0), ItemVisuals.EggSize, model, { Transparency = 1, CanCollide = false })
	prompt("BuyPrompt", anchor, "Buy", def.Name, Config.Prompts.BeltBuyHold)
	local billboard = new("BillboardGui", { Name = "Label", Size = UDim2.fromScale(3.8, 1.15), StudsOffset = Vector3.new(0, 2.8, 0) }, shell)
	new("TextLabel", { Name = "EggName", Text = def.Name, Size = UDim2.fromScale(1, 0.55) }, billboard)
	new("TextLabel", { Name = "Price", Text = "$" .. Config.FormatNumber(def.Price), Size = UDim2.fromScale(1, 0.45), Position = UDim2.fromScale(0, 0.55) }, billboard)
	Inst.addTag(model, Config.Tags.BeltEgg)
	setParent(model, folder)
	return model
end

--- A carried (or dropped) item model, as StealService builds it.
function World.carryModel(opts)
	World.carryId += 1
	local id = opts.carryId or World.carryId
	local model = if opts.eggId then ItemVisuals.BuildEgg(opts.eggId) else ItemVisuals.BuildCreature(opts.creatureId, nil)
	attr(model, "Source", opts.source)
	attr(model, "Kind", if opts.eggId then "Egg" else "Creature")
	if opts.eggId then
		attr(model, "EggId", opts.eggId)
		attr(model, "Progress", 0.4)
	else
		attr(model, "CreatureId", opts.creatureId)
		attr(model, "Rarity", Config.CreaturesById[opts.creatureId].Rarity)
	end
	attr(model, "ItemLabel", opts.label)
	attr(model, "OwnerUserId", opts.ownerId or 0)
	attr(model, "OwnerName", opts.ownerName or "")
	if opts.returnAt then
		attr(model, "ReturnAt", opts.returnAt)
	end
	attr(model, "CarryId", id)
	if opts.dropped then
		attr(model, "Dropped", true)
		prompt("PickupPrompt", model.PrimaryPart, "Pick up", opts.label, Config.Steal.PickupHold)
		model:PivotTo(CFrame.new(opts.position or Vector3.new(0, 1, 60)))
	else
		attr(model, "CarrierUserId", opts.carrierId)
		local carrier = if opts.carrierId == 1 then World.player else World.other
		local character = get(carrier, "Character")
		local root = character and Inst.findChild(S[character], "HumanoidRootPart")
		local at = if root then get(root, "Position") else Vector3.new(0, 3, 60)
		model:PivotTo(CFrame.new(at + Config.Steal.CarryOffset))
	end
	Inst.addTag(model, Config.Tags.CarriedItem)
	setParent(model, runtime())
	return model, id
end

function World.wildCryptid(creatureId: string, position: Vector3, sightingId: number, expiresAt: number)
	local def = Config.CreaturesById[creatureId]
	local model = ItemVisuals.BuildCreature(creatureId, nil)
	S[model].name = "WildCryptid"
	model:PivotTo(CFrame.new(position))
	prompt("CapturePrompt", model.PrimaryPart, "Capture", def.Name, Config.Prompts.CaptureHold)
	attr(model, "CreatureId", creatureId)
	attr(model, "Rarity", def.Rarity)
	attr(model, "ItemLabel", def.Name)
	attr(model, "SightingId", sightingId)
	attr(model, "ExpiresAt", expiresAt)
	Inst.addTag(model, Config.Tags.WildCryptid)
	setParent(model, runtime())
	return model
end

--------------------------------------------------------------------------
-- Players, characters, tools
--------------------------------------------------------------------------

local function newPlayer(name: string, userId: number)
	local player = new("Player", { Name = name, DisplayName = name, UserId = userId }, nil)
	return player
end

function World.makeCharacter(player, cf: CFrame)
	local st = S[player]
	local character = new("Model", { Name = st.name }, nil)
	local root = part("HumanoidRootPart", cf, Vector3.new(2, 2, 1), character, { Transparency = 1, CanCollide = false })
	part("Head", cf * CFrame.new(0, 1.5, 0), Vector3.new(1.2, 1.2, 1.2), character)
	part("UpperTorso", cf * CFrame.new(0, 0.2, 0), Vector3.new(2, 1.6, 1), character)
	part("LowerTorso", cf * CFrame.new(0, -0.8, 0), Vector3.new(2, 0.4, 1), character)
	part("RightHand", cf * CFrame.new(1.5, -0.6, 0), Vector3.new(0.4, 0.4, 0.4), character)
	part("LeftHand", cf * CFrame.new(-1.5, -0.6, 0), Vector3.new(0.4, 0.4, 0.4), character)
	local humanoid = new("Humanoid", { Name = "Humanoid", WalkSpeed = 16, MaxHealth = 100, Health = 100 }, character)
	new("Animator", { Name = "Animator" }, humanoid)
	character.PrimaryPart = root
	return character, humanoid, root
end

local function giveTools(player)
	local backpack = Inst.findChild(S[player], "Backpack")
	-- The Bat (BatService)
	local bat = new("Tool", {
		Name = Config.Bat.Name,
		ToolTip = "Bonk thieves to make them drop what they stole",
		TextureId = Config.Icons.BaseballBat,
		CanBeDropped = false,
		RequiresHandle = true,
		Grip = CFrame.new(0, -1.6, 0),
	}, nil)
	part("Handle", CFrame.new(), Vector3.new(0.35, 2.2, 0.35), bat, { CanCollide = false, Massless = true })
	part("Barrel", CFrame.new(0, 1.4, 0), Vector3.new(0.55, 1.6, 0.55), bat, { CanCollide = false, Massless = true })
	new("Sound", { Name = "Swing", SoundId = "rbxassetid://12222216", Volume = 0.5 }, bat)
	setParent(bat, backpack)
	-- The Field Camera (CodexService)
	local camTool = new("Tool", {
		Name = Config.Codex.CameraToolName,
		ToolTip = "Photograph cryptids for your Codex",
		TextureId = Config.Icons.Camera,
		CanBeDropped = false,
		RequiresHandle = true,
		Grip = CFrame.new(0, -0.45, 0.1),
	}, nil)
	local body = part("Handle", CFrame.new(), Vector3.new(1.2, 0.8, 0.6), camTool, { CanCollide = false, Massless = true })
	for _, n in { "Lens", "Glass", "Viewfinder", "RecLight" } do
		local p = part(n, CFrame.new(0.15, 0, -0.45), Vector3.new(0.35, 0.55, 0.55), camTool, { CanCollide = false, Massless = true })
		new("WeldConstraint", { Part0 = body, Part1 = p }, body)
	end
	setParent(camTool, backpack)
end
World.giveTools = giveTools

--- Spawns (or respawns) a player's character at their camp.
function World.spawnCharacter(player, plotIndex: number)
	local st = S[player]
	local old = st.props.Character
	if old then
		Inst.fire(player, "CharacterRemoving", old)
		Inst.destroy(old)
	end
	local cf = plotCFrame(plotIndex) * CFrame.new(0, 4, -Config.Plot.Size.Z / 2 + 16)
	local character, humanoid = World.makeCharacter(player, cf)
	Inst.setRaw(player, st, "Character", character)
	setParent(character, svc("Workspace"))
	if player == World.player then
		local camera = get(svc("Workspace"), "CurrentCamera")
		Inst.setRaw(camera, S[camera], "CameraSubject", humanoid)
		Classes.setPartCFrame(camera, S[camera], CFrame.lookAt(cf.Position + Vector3.new(0, 12, 18), cf.Position))
	end
	Inst.fire(player, "CharacterAdded", character)
	Inst.fire(player, "CharacterAppearanceLoaded", character)
	Sched.drain()
	return character
end

function World.moveCharacter(position: Vector3)
	local character = get(World.player, "Character")
	local root = character and Inst.findChild(S[character], "HumanoidRootPart")
	if root then
		character:PivotTo(CFrame.new(position))
	end
end

function World.rootPosition(): Vector3
	local character = get(World.player, "Character")
	local root = character and Inst.findChild(S[character], "HumanoidRootPart")
	return if root then get(root, "Position") else Vector3.zero
end

--------------------------------------------------------------------------
-- Remote handlers (response shapes from the real services)
--------------------------------------------------------------------------

local function notify(text: string, kind: string)
	World.fire("Notify", text, kind)
end
World.notify = notify

local function installHandlers()
	local H = World.handlers
	H.BuyUpgrade = function(player, upgradeId)
		local up = typeof(upgradeId) == "string" and Config.Upgrades[upgradeId]
		if not up then
			return { Ok = false, Message = "That upgrade doesn't exist." }
		end
		local level = World.data.Upgrades[upgradeId] or 1
		if level >= #up.Levels then
			return { Ok = false, Message = up.DisplayName .. " is already maxed." }
		end
		World.data.Upgrades[upgradeId] = level + 1
		Sched.defer(World.pushProfile)
		return { Ok = true, Message = string.format("%s upgraded to %s!", up.DisplayName, tostring(up.Levels[level + 1].Value)), Level = level + 1 }
	end
	H.DoRebirth = function(player)
		World.data.Rebirths += 1
		local rebirths = World.data.Rebirths
		Sched.defer(function()
			World.fire("FeedbackCue", "Rebirth", { Rebirths = rebirths })
			World.pushProfile()
		end)
		return {
			Ok = true,
			Message = string.format("Rebirth %d! Income +%d%%, luck +%d%%.", rebirths, rebirths * 25, rebirths * 10),
			Rebirths = rebirths,
		}
	end
	H.LockPlot = function(player)
		local now = serverNow()
		local untilT = now + 60
		attr(player, "PlotLockedUntil", untilT)
		attr(player, "PlotLockCooldownUntil", now + Config.Plot.LockCooldown)
		attr(World.plots[1], "LockedUntil", untilT)
		attr(World.plots[1], "LockCooldownUntil", now + Config.Plot.LockCooldown)
		return { Ok = true, Message = "Camp locked for 60s." }
	end
	H.PromptPurchase = function(player, kind, key)
		local list = if kind == "Pass" then Config.GamePasses elseif kind == "Product" then Config.DevProducts else nil
		local item = list and list[key]
		if not item then
			return { Ok = false, Message = "That item doesn't exist." }
		end
		if item.Id == 0 then
			return { Ok = false, Message = item.DisplayName .. " isn't on sale yet." }
		end
		return { Ok = true }
	end
	H.Travel = function(player, destination)
		if destination ~= "Base" and destination ~= "Eggs" and destination ~= "Shop" then
			return { Ok = false, Message = "Unknown destination." }
		end
		return { Ok = true }
	end
	H.TakePhoto = function(player, creatureId)
		local id = if typeof(creatureId) == "string" and Config.CreaturesById[creatureId] then creatureId else "mothman"
		local isNew = not World.data.Codex[id]
		World.data.Codex[id] = true
		if isNew then
			Sched.defer(function()
				World.fire("CodexDiscovered", id, { IsNew = true, PageCompleted = nil, Source = "Photo" })
				notify("New Codex entry: " .. Config.CreaturesById[id].Name .. "!", "Success")
				World.pushProfile()
			end)
		end
		return { Ok = true, IsNew = isNew, CreatureId = id, PageCompleted = nil }
	end
	H.ClaimDaily = function(player)
		local r = World.retention
		if not r.dailyCanClaim then
			return { Ok = false, Message = "Already claimed today. Next reward in 12:00." }
		end
		r.dailyCanClaim = false
		local text = describe(Config.Retention.Daily.Rewards[r.dailyDay]).Text
		Sched.defer(function()
			notify(string.format("Day %d reward: %s!", r.dailyDay, text), "Success")
			World.pushRetention()
		end)
		return { Ok = true, Day = r.dailyDay, Text = text }
	end
	H.SpinWheel = function(player)
		local r = World.retention
		if not r.freeSpinReady and r.spinsExtra <= 0 then
			return { Ok = false, Message = "No spins left. Your next free spin is in 3:59:59." }
		end
		if r.freeSpinReady then
			r.freeSpinReady = false
		else
			r.spinsExtra -= 1
		end
		local index = 3
		local text = describe(Config.Retention.Spin.Prizes[index]).Text
		Sched.defer(World.pushRetention)
		return { Ok = true, Index = index, Text = text }
	end
	H.ClaimPlaytimeGift = function(player, index)
		local gifts = Config.Retention.Playtime.Gifts
		if typeof(index) ~= "number" or index ~= math.floor(index) or index < 1 or index > #gifts then
			return { Ok = false, Message = "That gift doesn't exist." }
		end
		local r = World.retention
		if r.giftsClaimed[index] then
			return { Ok = false, Message = "You already opened that gift." }
		end
		r.giftsClaimed[index] = true
		local text = describe(gifts[index]).Text
		Sched.defer(World.pushRetention)
		return { Ok = true, Index = index, Text = text }
	end
	H.ClaimOffline = function(player)
		local r = World.retention
		local amount = r.pendingOffline
		if amount <= 0 then
			return { Ok = false, Message = "There's no offline cash to claim." }
		end
		r.pendingOffline = 0
		World.data.Cash += amount
		Sched.defer(function()
			World.pushRetention()
			World.pushProfile()
		end)
		return { Ok = true, Amount = amount }
	end
end

--------------------------------------------------------------------------
-- Build everything that exists before the client starts
--------------------------------------------------------------------------

function World.build(options)
	local game = Services.game
	local RS = svc("ReplicatedStorage")
	local ws = svc("Workspace")
	local players = svc("Players")

	-- Server-side code realm (its own module cache and Config).
	serverRealm = Loader.newRealm("server", false)
	World.serverRealm = serverRealm
	local shared = Inst.findChild(S[RS], "Shared")
	assert(shared, "world: ReplicatedStorage.Shared was not built (check default.project.json)")
	Config = serverRequire(Inst.findChild(S[shared], "Config"))
	ItemVisuals = serverRequire(Inst.findChild(S[shared], "ItemVisuals"))
	BeltPath = serverRequire(Inst.findChild(S[shared], "BeltPath"))
	World.Config = Config
	World.BeltPath = BeltPath
	local serverTree = Loader.buildPath("src/server", "Server", nil)
	local modules = serverTree and Inst.findChild(S[serverTree], "Modules")
	local templateModule = modules and Inst.findChild(S[modules], "ProfileTemplate")
	ProfileTemplate = if templateModule then serverRequire(templateModule) else nil

	-- Remotes (RemoteGuard creates one per Config.Remotes entry)
	local remotes = new("Folder", { Name = "Remotes" }, nil)
	for _, name in Util.sortedKeys(Config.Remotes) do
		local def = Config.Remotes[name]
		local className = if def.Kind == "Function" then "RemoteFunction" else "RemoteEvent"
		World.remotes[name] = new(className, { Name = name }, remotes)
	end
	setParent(remotes, RS)

	-- The Hunt's replicated state (HuntService)
	local hunt = new("Configuration", { Name = "HuntState" }, nil)
	attr(hunt, "Phase", "Idle")
	attr(hunt, "Position", Vector3.zero)
	attr(hunt, "Yaw", 0)
	attr(hunt, "TargetUserId", 0)
	attr(hunt, "StartsAt", 0)
	attr(hunt, "EndsAt", 0)
	setParent(hunt, RS)
	World.huntState = hunt

	-- Lighting as WorldService leaves it
	local lighting = svc("Lighting")
	Inst.setRaw(lighting, S[lighting], "ClockTime", Config.Atmosphere.ClockTime)
	Inst.setRaw(lighting, S[lighting], "Brightness", Config.Atmosphere.Brightness)
	new("Atmosphere", { Name = "Atmosphere", Density = Config.Atmosphere.AtmosphereDensity }, lighting)
	new("ColorCorrectionEffect", { Name = "SAC_ColorGrade" }, lighting)

	-- Map
	local map = new("Folder", { Name = "Map" }, nil)
	buildHub(map)
	local plotsFolder = new("Folder", { Name = "Plots" }, map)
	for index = 1, 3 do
		buildPlot(index, plotsFolder)
	end
	setParent(map, ws)
	local rt = new("Folder", { Name = "Runtime" }, ws)
	new("Folder", { Name = "EggBelt" }, rt)

	-- Players
	local player = newPlayer("Player1", 1)
	World.player = player
	Classes.localPlayer = player
	new("PlayerGui", { Name = "PlayerGui" }, player)
	new("Backpack", { Name = "Backpack" }, player)
	local playerScripts = new("PlayerScripts", { Name = "PlayerScripts" }, player)
	local leaderstats = new("Folder", { Name = "leaderstats" }, player)
	new("IntValue", { Name = "Cash", Value = 0 }, leaderstats)
	new("IntValue", { Name = "Rebirths", Value = 0 }, leaderstats)
	setParent(player, players)
	World.playerScripts = playerScripts

	local other = newPlayer("Player2", 2)
	World.other = other
	new("Backpack", { Name = "Backpack" }, other)
	setParent(other, players)

	-- Plot 2 is Player2's, with things worth stealing; plot 3 is empty.
	attr(World.plots[2], "OwnerUserId", 2)
	attr(World.plots[2], "OwnerName", "Player2")
	World.placeEgg(2, 1, 2, "swamp", 0.85)
	World.placeCreature(2, 2, 2, "redacted", 3000)
	World.placeCreature(2, 3, 2, "nessie", 9000)
	World.spawnCharacter(other, 2)

	-- Belt eggs already riding
	World.spawnBeltEgg("forest", 5)
	World.spawnBeltEgg("sky", 12)

	-- The local player's profile (DataService: ProfileTemplate.new + play)
	local data = if ProfileTemplate then ProfileTemplate.new() else {
		Cash = 500, Rebirths = 0, Nests = {}, Upgrades = {}, Codex = {}, Buffs = {}, Stats = { Hatches = 0, EggsBought = 0 },
	}
	data.Cash = 2500
	data.Nests[1] = { Kind = "Egg", EggId = "forest", Incubated = 10, Vault = 0, AcquiredAt = math.floor(serverNow()), LastIncomeAt = math.floor(serverNow()) }
	data.Nests[2] = { Kind = "Creature", CreatureId = "mothman", Rarity = "Epic", Vault = 1200, AcquiredAt = math.floor(serverNow()), LastIncomeAt = math.floor(serverNow()) }
	data.Codex.mothman = true
	data.Buffs.Luck = math.floor(serverNow()) + 600
	data.Stats.EggsBought = 1
	World.data = data

	installHandlers()
end

--- What PlotService.claim + DataService do once the profile has loaded.
function World.claimPlot()
	local player = World.player
	local plot = World.plots[1]
	local now = serverNow()
	attr(plot, "OwnerUserId", 1)
	attr(plot, "OwnerName", "Player1")
	attr(plot, "ProtectedUntil", now + Config.Steal.NewPlayerSpawnLock)
	attr(player, "PlotIndex", 1)
	attr(player, "NestCapacity", Config.GetUpgradeValue("NestSlots", 1))
	attr(player, "ProtectedUntil", now + Config.Steal.NewPlayerSpawnLock)
	attr(player, "PlotLockedUntil", 0)
	attr(player, "PlotLockCooldownUntil", 0)
	World.placeEgg(1, 1, 1, "forest", 0.25)
	World.placeCreature(1, 2, 1, "mothman", 1200)
	World.spawnCharacter(player, 1)
	giveTools(player)
	Sched.drain()
end

--- Copies the Client folder into PlayerScripts and returns it.
function World.installClient(clientFolder)
	local copy = Inst.clone(clientFolder)
	setParent(copy, World.playerScripts)
	return copy
end

return World
