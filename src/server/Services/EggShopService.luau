--!strict
--[[
	EggShopService
	ServerScriptService/Server/Services/EggShopService

	Buying eggs. The client opens the shop panel from the Egg Shop counter's
	prompt and sends BuyEgg(eggId). The server checks, in order:

	  1. eggId is a real egg (string, known id) — never trust the client
	  2. the player meets its rebirth requirement
	  3. the player is standing at an Egg Shop counter
	  4. the player has a plot and a free nest   (checked BEFORE charging)
	  5. the player can afford it                (TrySpendCash: check+take)

	then places the egg. Steps 4-5 and the placement run with no yield in
	between, so the nest can't be taken by a second purchase mid-flight.

	Price, odds and requirements always come from Config, never the client.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Server = ServerScriptService:WaitForChild("Server")
local Modules = Server:WaitForChild("Modules")
local Services = Server:WaitForChild("Services")
local RemoteGuard = require(Modules:WaitForChild("RemoteGuard"))
local DataService = require(Services:WaitForChild("DataService"))
local PlotService = require(Services:WaitForChild("PlotService"))
local NestService = require(Services:WaitForChild("NestService"))

local EggShopService = {}

local function isAtShop(player: Player, shopId: string): boolean
	for _, counter in ipairs(CollectionService:GetTagged(Config.Tags.ShopBooth)) do
		if counter:IsA("BasePart") and counter:GetAttribute("ShopId") == shopId then
			if RemoteGuard.IsWithinReach(player, counter.Position, Config.Shop.InteractDistance) then
				return true
			end
		end
	end
	return false
end

function EggShopService.Buy(player: Player, eggId: any): RemoteGuard.Result
	if typeof(eggId) ~= "string" or #eggId > 32 then
		return { Ok = false, Message = "That egg doesn't exist." }
	end
	local egg = Config.Eggs[eggId]
	if not egg then
		return { Ok = false, Message = "That egg doesn't exist." }
	end

	local data = DataService.Get(player)
	if not data then
		return { Ok = false, Message = "Still loading your save..." }
	end
	if data.Rebirths < egg.RequiredRebirths then
		return { Ok = false, Message = string.format("%s unlocks at Rebirth %d.", egg.Name, egg.RequiredRebirths) }
	end
	if not isAtShop(player, "Eggs") then
		return { Ok = false, Message = "Walk up to the Egg Shop to buy." }
	end
	if not PlotService.GetPlot(player) then
		return { Ok = false, Message = "You don't have a camp yet." }
	end
	if not NestService.FindEmptyNest(player) then
		return { Ok = false, Message = "No empty nest! Hatch an egg or upgrade your nests first." }
	end
	if not DataService.TrySpendCash(player, egg.Price, "egg:" .. eggId) then
		return { Ok = false, Message = string.format("Not enough cash (need $%s).", Config.FormatNumber(egg.Price)) }
	end

	local nestIndex = NestService.PlaceEgg(player, eggId, 0)
	if not nestIndex then
		-- Can't happen given the check above with no yield between, but
		-- never take money without giving the egg.
		DataService.AddCash(player, egg.Price, "refund:" .. eggId)
		return { Ok = false, Message = "No empty nest! Your cash was refunded." }
	end

	DataService.Mutate(player, function(d)
		d.Stats.EggsBought = (d.Stats.EggsBought or 0) + 1
	end)

	return {
		Ok = true,
		Message = string.format("%s placed in nest %d. Let it heat up!", egg.Name, nestIndex),
		NestIndex = nestIndex,
	}
end

function EggShopService.Start()
	RemoteGuard.BindFunction("BuyEgg", function(player: Player, eggId: any): RemoteGuard.Result
		return EggShopService.Buy(player, eggId)
	end)
end

return EggShopService
