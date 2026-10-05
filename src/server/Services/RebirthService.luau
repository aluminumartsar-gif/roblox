--!strict
--[[
	RebirthService
	ServerScriptService/Server/Services/RebirthService

	DoRebirth: trade everything in for a permanent boost.

	Requirements (all checked on the server):
	  * cash >= Config.GetRebirthCost(rebirths)
	  * at least one creature of rarity index >= Config.RebirthMinRarityIndex
	    (Rare+) sitting in a nest at home
	  * not carrying anything (stolen egg, belt egg or captured cryptid), and
	    none of your own eggs out being stolen — wiping your nests mid-steal
	    would make that egg vanish for both players

	Effect: resets exactly Config.Rebirth.Resets (Cash / Nests / Upgrades),
	adds one rebirth. Everything else is kept. The bonuses themselves
	(+income, +luck, glow colour, Sky/Void unlocks) are read from the rebirth
	count by BoostService, PlotService and EggBeltService — nothing to grant
	here beyond the count.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Server = ServerScriptService:WaitForChild("Server")
local Modules = Server:WaitForChild("Modules")
local Services = Server:WaitForChild("Services")
local ProfileTemplate = require(Modules:WaitForChild("ProfileTemplate"))
local RemoteGuard = require(Modules:WaitForChild("RemoteGuard"))
local DataService = require(Services:WaitForChild("DataService"))
local PlotService = require(Services:WaitForChild("PlotService"))
local NestService = require(Services:WaitForChild("NestService"))
local StealService = require(Services:WaitForChild("StealService"))
local UpgradeService = require(Services:WaitForChild("UpgradeService"))

local RebirthService = {}

--- (ok, reason) — whether the player may rebirth right now.
function RebirthService.Check(player: Player): (boolean, string?)
	local data = DataService.Get(player)
	if not data then
		return false, "Still loading your save..."
	end
	if StealService.IsCarrying(player) then
		return false, "You can't rebirth while carrying something. Drop it off at your camp first."
	end

	local hasRarePlus = false
	for _, slot in ipairs(data.Nests) do
		if slot ~= false then
			if slot.Away then
				return false, "One of your eggs is being stolen. Get it back first."
			end
			if slot.Kind == "Creature" and Config.GetRarityIndex(slot.Rarity) >= Config.RebirthMinRarityIndex then
				hasRarePlus = true
			end
		end
	end
	if not hasRarePlus then
		local rarity = Config.RarityOrder[Config.RebirthMinRarityIndex]
		return false, string.format("You need a %s or better cryptid at home to rebirth.", rarity)
	end

	local cost = Config.GetRebirthCost(data.Rebirths)
	if data.Cash < cost then
		return false, string.format("Rebirth costs $%s.", Config.FormatNumber(cost))
	end
	return true, nil
end

function RebirthService.Rebirth(player: Player): RemoteGuard.Result
	local ok, reason = RebirthService.Check(player)
	if not ok then
		return { Ok = false, Message = reason }
	end

	local data = DataService.Get(player) :: any
	local cost = Config.GetRebirthCost(data.Rebirths)
	if not DataService.TrySpendCash(player, cost, "rebirth") then
		return { Ok = false, Message = string.format("Rebirth costs $%s.", Config.FormatNumber(cost)) }
	end

	local fresh = ProfileTemplate.new()
	DataService.Mutate(player, function(d)
		for _, key in ipairs(Config.Rebirth.Resets) do
			if key == "Cash" then
				d.Cash = Config.Rebirth.StartingCash -- a head start, not counted as earned
			elseif key == "Nests" then
				d.Nests = fresh.Nests
			elseif key == "Upgrades" then
				d.Upgrades = fresh.Upgrades
			end
		end
		d.Rebirths += 1
		d.Stats.LastRebirthAt = os.time()
	end)

	local rebirths = data.Rebirths
	local plot = PlotService.GetPlot(player)
	if plot then
		NestService.RenderPlot(plot) -- clears the old eggs and creatures
	end
	UpgradeService.ApplyEffects(player) -- nest count, glow colour, walk speed

	task.spawn(DataService.SaveNow, player)

	-- The rebirther's flash + fanfare (FeedbackController): presentation only.
	RemoteGuard.GetClientEvent("FeedbackCue"):FireClient(player, "Rebirth", { Rebirths = rebirths })

	if Config.Rebirth.Announce then
		RemoteGuard.GetClientEvent("GlobalAnnounce"):FireAllClients(
			string.format("%s reached Rebirth %d!", player.DisplayName, rebirths), "Legendary")
	end
	print(string.format("[SAC/Rebirth] %s rebirthed to %d (paid $%d)", player.Name, rebirths, cost))

	local unlock = ""
	for _, eggId in ipairs(Config.EggOrder) do
		if Config.Eggs[eggId].RequiredRebirths == rebirths then
			unlock = " " .. Config.Eggs[eggId].Name .. " unlocked!"
		end
	end
	return {
		Ok = true,
		Message = string.format("Rebirth %d! Income +%d%%, luck +%d%%.%s",
			rebirths,
			math.floor(rebirths * Config.Rebirth.IncomeBonusPerRebirth * 100 + 0.5),
			rebirths * Config.Luck.PerRebirthPercent,
			unlock),
		Rebirths = rebirths,
	}
end

function RebirthService.Start()
	RemoteGuard.BindFunction("DoRebirth", function(player: Player): RemoteGuard.Result
		return RebirthService.Rebirth(player)
	end)
end

return RebirthService
