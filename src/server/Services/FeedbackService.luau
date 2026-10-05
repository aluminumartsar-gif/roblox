--!strict
--[[
	FeedbackService
	ServerScriptService/Server/Services/FeedbackService

	Presentation only: tells clients when something worth celebrating (or
	wincing at) happened, so FeedbackController can play the right sound
	and effect. Nothing here changes game state, and nothing a client sends
	is trusted — there are no client->server remotes at all.

	Remotes (server -> client):
	  HatchResult    fired by NestService.Hatch to the hatcher
	  CashCollected  fired by IncomeService.Collect to the collector
	  FeedbackCue    (cue, info), fired from here:
	    "HatchBurst" {Position, Rarity, UserId}  everyone, Legendary+ hatches
	    "BatHit"     {Position}                  everyone, a bat connected
	    "Bought"     {}                          buyer, an egg off the belt
	    "Taken"      {Stolen}                    taker, steal/pickup succeeded
	    "Claimed"    {Stolen}                    claimer, item reached their pad
	    (RebirthService fires "Rebirth" {Rebirths} to the player itself.)

	Studio test hooks (DebugCommands): FeedbackService.DebugHatch and
	FeedbackService.DebugCash fire the client effects without touching data.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Server = ServerScriptService:WaitForChild("Server")
local Modules = Server:WaitForChild("Modules")
local Services = Server:WaitForChild("Services")
local RemoteGuard = require(Modules:WaitForChild("RemoteGuard"))
local PlotService = require(Services:WaitForChild("PlotService"))
local NestService = require(Services:WaitForChild("NestService"))
local StealService = require(Services:WaitForChild("StealService"))
local BatService = require(Services:WaitForChild("BatService"))

local FeedbackService = {}

local cueRemote: RemoteEvent? = nil

-- Carries that came from a steal or a pickup (ItemTaken), so a Carrying
-- flag without one of these is a fresh belt purchase.
local takenCarryIds: { [number]: boolean } = {}

local function cue(): RemoteEvent
	if not cueRemote then
		cueRemote = RemoteGuard.GetClientEvent("FeedbackCue")
	end
	return cueRemote :: RemoteEvent
end

local function sendTo(player: Player, name: string, info: { [string]: any })
	if player.Parent == Players then
		cue():FireClient(player, name, info)
	end
end

local function sendAll(name: string, info: { [string]: any })
	cue():FireAllClients(name, info)
end

local function rootPosition(player: Player): Vector3?
	local root = RemoteGuard.GetRoot(player)
	return root and root.Position
end

--- Where the hatch effects go: the nest the egg sat in.
local function nestPosition(player: Player, nestIndex: number): Vector3?
	local plot = PlotService.GetPlot(player)
	if not plot or not plot.Nests[nestIndex] then
		return nil
	end
	local ok, cf = pcall(NestService.GetItemCFrame, plot, nestIndex)
	return if ok then cf.Position else nil
end

--------------------------------------------------------------------------
-- Studio test hooks
--------------------------------------------------------------------------

--- Fires a hatch reveal on `player`'s screen (no data change). `which` is
--- a creature id or a rarity name (a random creature of that rarity).
function FeedbackService.DebugHatch(player: Player, which: string?): string
	local def = Config.CreaturesById[which or ""]
	if not def then
		local list = Config.CreaturesByRarity[which or ""] or Config.CreaturesByRarity.Legendary
		def = list[math.random(1, #list)]
	end
	local position = nestPosition(player, 1) or rootPosition(player)
	RemoteGuard.GetClientEvent("HatchResult"):FireClient(player, def.Id, def.Rarity, nil, Config.EggOrder[math.random(1, #Config.EggOrder)], position)
	if position and Config.GetRarityIndex(def.Rarity) >= Config.Feedback.BigRarityIndex then
		sendAll("HatchBurst", { Position = position, Rarity = def.Rarity, UserId = player.UserId })
	end
	return string.format("hatch reveal for %s: %s (%s)", player.Name, def.Name, def.Rarity)
end

--- Fires a cash popup at the player (no cash is given).
function FeedbackService.DebugCash(player: Player, amount: number): string
	local position = rootPosition(player)
	if not position then
		return player.Name .. " has no character"
	end
	RemoteGuard.GetClientEvent("CashCollected"):FireClient(player, amount, position + Vector3.new(0, 3, 0))
	return string.format("cash popup +$%s for %s", Config.FormatNumber(amount), player.Name)
end

--------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------

function FeedbackService.Start()
	cue()

	-- Big hatches: a burst everyone nearby can see. (The hatcher's own
	-- reveal comes from NestService's HatchResult.)
	NestService.Hatched:Connect(function(player: Player, nestIndex: number, result: any)
		if Config.GetRarityIndex(result.Rarity) < Config.Feedback.BigRarityIndex then
			return
		end
		local position = nestPosition(player, nestIndex)
		if position then
			sendAll("HatchBurst", { Position = position, Rarity = result.Rarity, UserId = player.UserId })
		end
	end)

	StealService.ItemTaken:Connect(function(player: Player, carry: any)
		takenCarryIds[carry.Id] = true
		sendTo(player, "Taken", { Stolen = carry.Source ~= "Belt" })
	end)

	StealService.Claimed:Connect(function(player: Player, carry: any)
		takenCarryIds[carry.Id] = nil
		sendTo(player, "Claimed", { Stolen = carry.Source ~= "Belt" })
	end)

	-- A dropped carry is forgotten here (a later pickup fires ItemTaken
	-- again), so the table can't grow for the life of the server.
	StealService.ItemDropped:Connect(function(_player: Player, carry: any)
		takenCarryIds[carry.Id] = nil
	end)

	-- A belt purchase puts an egg in your hand without an ItemTaken; spot
	-- it from the Carrying flag. (Deferred a moment: depending on signal
	-- timing the flag can be seen before ItemTaken has fired.)
	local function watch(player: Player)
		player:GetAttributeChangedSignal("Carrying"):Connect(function()
			if player:GetAttribute("Carrying") ~= true then
				return
			end
			task.delay(0.1, function()
				local carry = StealService.GetCarry(player)
				if carry and carry.Source == "Belt" and not takenCarryIds[carry.Id] then
					takenCarryIds[carry.Id] = true -- only once per carry
					sendTo(player, "Bought", {})
				end
			end)
		end)
	end
	Players.PlayerAdded:Connect(watch)
	for _, player in ipairs(Players:GetPlayers()) do
		watch(player)
	end

	-- Bat hits (BatService.Bonked: (target, swinger)).
	local bonked = (BatService :: any).Bonked
	if bonked then
		bonked:Connect(function(target: Player)
			local position = rootPosition(target)
			if position then
				sendAll("BatHit", { Position = position })
			end
		end)
	end
end

return FeedbackService
