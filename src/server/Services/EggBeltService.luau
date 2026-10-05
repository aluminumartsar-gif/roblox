--!strict
--[[
	EggBeltService
	ServerScriptService/Server/Services/EggBeltService

	The egg belt round the hub campfire — the only place to buy eggs.

	Every Config.Belt.SpawnInterval seconds a random egg (Config.Belt.
	EggWeights) climbs out of the start burrow, rides the belt and sinks
	into the end burrow. First come, first served: the first player to
	finish holding its Buy prompt gets it, the egg leaves the belt, and it
	goes in their hand (StealService.CarryBought). It only becomes theirs
	when they reach their camp's pad — a bat hit knocks it loose for anyone.

	The visible egg costs no network traffic: the server places it once and
	stores only its spawn time, and clients slide their own view of it along
	the path (Shared/BeltPath + EggBeltController). The Buy prompt sits on an
	invisible BuyAnchor that the server DOES move (10x a second), because
	Roblox rejects a prompt trigger if the server thinks the prompt is out of
	reach. The server's own reach check uses the exact path maths.

	A purchase is checked in order: egg still for sale and riding, hold
	really lasted, save loaded, rebirth requirement, hands free, not
	stunned, has a camp and a free nest, within reach of where the egg is
	right now, can afford it (TrySpendCash). Nothing yields in between, so
	two players can't both buy the same egg.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local BeltPath = require(Shared:WaitForChild("BeltPath"))

local Server = ServerScriptService:WaitForChild("Server")
local Modules = Server:WaitForChild("Modules")
local Services = Server:WaitForChild("Services")
local ItemVisuals = require(Modules:WaitForChild("ItemVisuals"))
local RemoteGuard = require(Modules:WaitForChild("RemoteGuard"))
local Notifier = require(Modules:WaitForChild("Notifier"))
local DataService = require(Services:WaitForChild("DataService"))
local PlotService = require(Services:WaitForChild("PlotService"))
local NestService = require(Services:WaitForChild("NestService"))
local StealService = require(Services:WaitForChild("StealService"))
local BatService = require(Services:WaitForChild("BatService"))

local EggBeltService = {}

type BeltEgg = {
	Id: number,
	EggId: string,
	SpawnTime: number, -- workspace:GetServerTimeNow() when it started rising
	Model: Model,
	Anchor: BasePart, -- invisible part carrying the Buy prompt; the server moves it
	Sold: boolean,
}

local eggs: { [number]: BeltEgg } = {}
local nextId = 0
local rng = Random.new()
local beltFolder: Folder
local lastNotice: { [Player]: number } = {}
local lastAttempt: { [Player]: number } = {}

local EGG_CENTRE_HEIGHT = ItemVisuals.EggSize.Y / 2

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function log(fmt: string, ...: any)
	if Config.Debug.Verbose then
		print(string.format("[SAC/Belt] " .. fmt, ...))
	end
end

local function notice(player: Player, text: string)
	local t = os.clock()
	if (lastNotice[player] or 0) + 1.5 > t then
		return
	end
	lastNotice[player] = t
	Notifier.Send(player, text, "Error")
end

--- A random egg id, by Config.Belt.EggWeights.
local function pickEggId(): string
	local total = 0
	for _, eggId in ipairs(Config.EggOrder) do
		total += Config.Belt.EggWeights[eggId] or 0
	end
	local roll = rng:NextNumber() * total
	for _, eggId in ipairs(Config.EggOrder) do
		roll -= Config.Belt.EggWeights[eggId] or 0
		if roll <= 0 then
			return eggId
		end
	end
	return Config.EggOrder[1]
end

local function label(parent: Instance, name: string, text: string, color: Color3, yScale: number, heightScale: number)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Position = UDim2.fromScale(0, yScale)
	l.Size = UDim2.fromScale(1, heightScale)
	l.Font = Enum.Font.GothamBlack
	l.TextScaled = true
	l.TextColor3 = color
	l.TextStrokeTransparency = 0.35
	l.Text = text
	l.Parent = parent
end

local function remove(egg: BeltEgg)
	eggs[egg.Id] = nil
	egg.Model:Destroy()
end

--------------------------------------------------------------------------
-- Buying
--------------------------------------------------------------------------

function EggBeltService.Buy(player: Player, egg: BeltEgg, began: number?): RemoteGuard.Result
	local def = Config.Eggs[egg.EggId]
	if eggs[egg.Id] ~= egg or egg.Sold then
		return { Ok = false, Message = "Too slow — someone else got it!" }
	end
	local hold = Config.Prompts.BeltBuyHold
	if hold > 0 and (began == nil or os.clock() - began < hold - Config.Steal.HoldTolerance) then
		return { Ok = false } -- fired without a real hold
	end
	local age = serverNow() - egg.SpawnTime
	if BeltPath.Phase(age) ~= "Riding" then
		return { Ok = false, Message = "That one's gone." }
	end
	local data = DataService.Get(player)
	if not data then
		return { Ok = false, Message = "Still loading your save..." }
	end
	if data.Rebirths < def.RequiredRebirths then
		return { Ok = false, Message = string.format("%s unlocks at Rebirth %d.", def.Name, def.RequiredRebirths) }
	end
	if StealService.IsCarrying(player) then
		return { Ok = false, Message = "Your hands are full!" }
	end
	if BatService.IsStunned(player) then
		return { Ok = false, Message = "You're stunned!" }
	end
	if not PlotService.GetPlot(player) then
		return { Ok = false, Message = "You don't have a camp yet." }
	end
	if not NestService.FindEmptyNest(player) then
		return { Ok = false, Message = "No empty nest! Hatch an egg or upgrade your nests first." }
	end
	local eggCentre = BeltPath.EggCFrame(age).Position + Vector3.new(0, EGG_CENTRE_HEIGHT, 0)
	if not RemoteGuard.IsWithinReach(player, eggCentre) then
		return { Ok = false, Message = "Get closer to the belt." }
	end
	if not DataService.TrySpendCash(player, def.Price, "belt:" .. egg.EggId) then
		return { Ok = false, Message = string.format("Not enough cash (need $%s).", Config.FormatNumber(def.Price)) }
	end

	egg.Sold = true
	remove(egg)
	if not StealService.CarryBought(player, egg.EggId) then
		-- No living character to hold it. Never take money without the egg.
		DataService.AddCash(player, def.Price, "refund:belt:" .. egg.EggId)
		return { Ok = false, Message = "Couldn't hand you the egg — your cash was refunded." }
	end
	DataService.Mutate(player, function(d)
		d.Stats.EggsBought = (d.Stats.EggsBought or 0) + 1
	end)
	log("%s bought %s (belt egg %d)", player.Name, egg.EggId, egg.Id)
	return { Ok = true, Message = string.format("Got a %s! Carry it to your camp's pad — watch out for bats.", def.Name) }
end

local function wirePrompt(egg: BeltEgg, anchor: BasePart)
	local def = Config.Eggs[egg.EggId]
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "BuyPrompt"
	prompt.ActionText = "Buy $" .. Config.FormatNumber(def.Price)
	prompt.ObjectText = def.Name
	prompt.HoldDuration = Config.Prompts.BeltBuyHold
	prompt.MaxActivationDistance = Config.Prompts.MaxActivationDistance
	prompt.RequiresLineOfSight = Config.Prompts.RequiresLineOfSight
	prompt.Parent = anchor

	local starts: { [Player]: number } = {}
	prompt.PromptButtonHoldBegan:Connect(function(player)
		starts[player] = os.clock()
	end)
	-- HoldEnded fires before Triggered when a hold completes (see
	-- CLAUDE.md gotchas), so only forget a hold after Triggered had its turn.
	prompt.PromptButtonHoldEnded:Connect(function(player)
		local began = starts[player]
		task.delay(0.2, function()
			if starts[player] == began then
				starts[player] = nil
			end
		end)
	end)
	prompt.Triggered:Connect(function(player)
		local began = starts[player]
		starts[player] = nil
		local t = os.clock()
		if (lastAttempt[player] or 0) + 0.2 > t then
			return
		end
		lastAttempt[player] = t
		local result = EggBeltService.Buy(player, egg, began)
		if result.Ok then
			Notifier.Send(player, result.Message or "", "Success")
		elseif result.Message then
			notice(player, result.Message)
		end
	end)
end

--------------------------------------------------------------------------
-- Spawning
--------------------------------------------------------------------------

local function spawnEgg(eggId: string, spawnTime: number): BeltEgg
	nextId += 1
	local def = Config.Eggs[eggId]
	local model = ItemVisuals.BuildEgg(eggId)
	model.Name = "BeltEgg"
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	model:SetAttribute("BeltEggId", nextId)
	model:SetAttribute("EggId", eggId)
	model:SetAttribute("SpawnTime", spawnTime)
	-- The visible egg stays at the burrow on the server; each client moves
	-- its own view. Only the invisible BuyAnchor is moved here, because
	-- Roblox checks a prompt trigger against where the server thinks the
	-- prompt is.
	model:PivotTo(BeltPath.EggCFrame(0))
	local shell = model.PrimaryPart :: BasePart
	local anchor = Instance.new("Part")
	anchor.Name = "BuyAnchor"
	anchor.Size = ItemVisuals.EggSize
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CFrame = BeltPath.EggCFrame(math.max(0, serverNow() - spawnTime)) * CFrame.new(0, EGG_CENTRE_HEIGHT, 0)
	anchor.Parent = model

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Label"
	billboard.Size = UDim2.fromScale(4.6, 1.4) -- studs: shrinks with distance
	billboard.StudsOffset = Vector3.new(0, ItemVisuals.EggSize.Y / 2 + 1.1, 0)
	billboard.LightInfluence = 0
	billboard.MaxDistance = 90
	billboard.Parent = shell
	label(billboard, "EggName", def.Name, Config.Belt.LabelColors[eggId] or Color3.new(1, 1, 1), 0, 0.55)
	label(billboard, "Price", "$" .. Config.FormatNumber(def.Price), Color3.fromRGB(120, 255, 140), 0.55, 0.45)

	if Config.Belt.AnnounceEggs[eggId] then
		local sparkle = Instance.new("ParticleEmitter")
		sparkle.Name = "RareSparkle"
		sparkle.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		sparkle.Color = ColorSequence.new(Config.Belt.LabelColors[eggId] or Color3.new(1, 1, 1))
		sparkle.LightEmission = 1
		sparkle.Size = NumberSequence.new(0.4, 0)
		sparkle.Lifetime = NumberRange.new(0.8, 1.2)
		sparkle.Rate = 12
		sparkle.Speed = NumberRange.new(1, 2)
		sparkle.SpreadAngle = Vector2.new(180, 180)
		sparkle.Parent = shell
	end

	local egg: BeltEgg = { Id = nextId, EggId = eggId, SpawnTime = spawnTime, Model = model, Anchor = anchor, Sold = false }
	wirePrompt(egg, anchor)
	CollectionService:AddTag(model, Config.Tags.BeltEgg)
	model.Parent = beltFolder
	eggs[egg.Id] = egg
	return egg
end

local function countEggs(): number
	local n = 0
	for _ in pairs(eggs) do
		n += 1
	end
	return n
end

--------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------

function EggBeltService.Start()
	local runtime = Workspace:WaitForChild("Runtime")
	local existing = runtime:FindFirstChild("EggBelt")
	if existing then
		existing:Destroy()
	end
	beltFolder = Instance.new("Folder")
	beltFolder.Name = "EggBelt"
	beltFolder.Parent = runtime

	if not Config.Belt.Enabled then
		warn("[SAC/Belt] Config.Belt.Enabled is off — no eggs will spawn")
		return
	end

	-- Fill the belt so the first players don't find it empty: eggs already
	-- part-way round, as if it had been running.
	local now = serverNow()
	local interval = Config.Belt.SpawnInterval
	local age = Config.Belt.RiseTime + Config.Belt.TravelTime - interval
	while age > Config.Belt.RiseTime do
		spawnEgg(pickEggId(), now - age)
		age -= interval
	end

	local nextSpawn = now
	task.spawn(function()
		while true do
			task.wait(0.1)
			local t = serverNow()
			if t >= nextSpawn then
				nextSpawn = t + interval
				if countEggs() < Config.Belt.MaxEggs then
					local eggId = pickEggId()
					spawnEgg(eggId, t)
					if Config.Belt.AnnounceEggs[eggId] then
						Notifier.SendAll(string.format("A %s just came out on the egg belt!", Config.Eggs[eggId].Name), "Announce")
					end
				end
			end
			local lifetime = BeltPath.Lifetime()
			for _, egg in pairs(eggs) do
				if t - egg.SpawnTime > lifetime + 0.5 then
					remove(egg)
				else
					egg.Anchor.CFrame = BeltPath.EggCFrame(math.min(t - egg.SpawnTime, lifetime))
						* CFrame.new(0, EGG_CENTRE_HEIGHT, 0)
				end
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastNotice[player] = nil
		lastAttempt[player] = nil
	end)
end

--- Debug: put a specific egg on the belt right now.
function EggBeltService.DebugSpawn(eggId: string): string
	if not Config.Eggs[eggId] then
		return "unknown egg " .. tostring(eggId)
	end
	local egg = spawnEgg(eggId, serverNow())
	return string.format("spawned %s (belt egg %d)", eggId, egg.Id)
end

--- Debug: what's on the belt.
function EggBeltService.DebugState(): string
	local lines = {}
	local t = serverNow()
	for id, egg in pairs(eggs) do
		local age = t - egg.SpawnTime
		table.insert(lines, string.format("%d %s %s %.1fs", id, egg.EggId, BeltPath.Phase(age), age))
	end
	table.sort(lines)
	return #lines > 0 and table.concat(lines, "\n") or "belt empty"
end

--- Debug: roll `count` belt eggs with the real picker and report the mix.
function EggBeltService.DebugRoll(count: number): string
	local counts: { [string]: number } = {}
	for _ = 1, count do
		local eggId = pickEggId()
		counts[eggId] = (counts[eggId] or 0) + 1
	end
	local out = {}
	for _, eggId in ipairs(Config.EggOrder) do
		table.insert(out, string.format("%s %.2f%%", eggId, (counts[eggId] or 0) / count * 100))
	end
	return table.concat(out, ", ")
end

--- Debug: the spawn time and current world position of a belt egg.
function EggBeltService.DebugEggPosition(id: number): Vector3?
	local egg = eggs[id]
	if not egg then
		return nil
	end
	return BeltPath.EggCFrame(serverNow() - egg.SpawnTime).Position
end

return EggBeltService
