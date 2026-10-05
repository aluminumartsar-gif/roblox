--!strict
--[[
	TravelService
	ServerScriptService/Server/Services/TravelService

	Fast travel for the HUD's Base and Shop buttons. Travel(destination):
	  "Home"         -> your plot's spawn point
	  "EggShop"      -> in front of the Egg Shop counter
	  "UpgradeShop"  -> in front of the Upgrades counter

	Refused while carrying a stolen item (thieves walk), while stunned, on
	cooldown (Config.Travel.Cooldown), or when Config.Travel.Enabled is off.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Server = ServerScriptService:WaitForChild("Server")
local Modules = Server:WaitForChild("Modules")
local Services = Server:WaitForChild("Services")
local RemoteGuard = require(Modules:WaitForChild("RemoteGuard"))
local PlotService = require(Services:WaitForChild("PlotService"))
local StealService = require(Services:WaitForChild("StealService"))
local BatService = require(Services:WaitForChild("BatService"))

local TravelService = {}

local SHOP_IDS: { [string]: string } = { EggShop = "Eggs", UpgradeShop = "Upgrades" }

local function counterCFrame(shopId: string): CFrame?
	for _, counter in ipairs(CollectionService:GetTagged(Config.Tags.ShopBooth)) do
		if counter:IsA("BasePart") and counter:GetAttribute("ShopId") == shopId then
			-- The counter faces the hub; stand on the hub side of it, facing it.
			local spot = counter.CFrame * CFrame.new(0, 2, -6)
			return CFrame.lookAt(spot.Position, Vector3.new(counter.Position.X, spot.Position.Y, counter.Position.Z))
		end
	end
	return nil
end

function TravelService.Travel(player: Player, destination: any): RemoteGuard.Result
	if not Config.Travel.Enabled then
		return { Ok = false, Message = "Fast travel is off." }
	end
	if destination ~= "Home" and not SHOP_IDS[destination] then
		return { Ok = false, Message = "Unknown destination." }
	end
	if StealService.IsCarrying(player) then
		return { Ok = false, Message = "You can't fast travel while carrying something — run!" }
	end
	if BatService.IsStunned(player) then
		return { Ok = false, Message = "You're stunned!" }
	end
	local wait = RemoteGuard.Cooldowns.Remaining(player, "Travel")
	if wait > 0 then
		return { Ok = false, Message = string.format("Fast travel recharging (%ds).", math.ceil(wait)) }
	end
	local character = player.Character
	if not RemoteGuard.GetRoot(player) or not character then
		return { Ok = false, Message = "Respawning..." }
	end

	local target: CFrame?
	if destination == "Home" then
		local plot = PlotService.GetPlot(player)
		target = plot and plot.SpawnCFrame * CFrame.new(0, 3, 0)
	else
		target = counterCFrame(SHOP_IDS[destination])
	end
	if not target then
		return { Ok = false, Message = "Can't get there right now." }
	end

	RemoteGuard.Cooldowns.Start(player, "Travel", Config.Travel.Cooldown)
	pcall(function()
		player:RequestStreamAroundAsync(target.Position, 3)
	end)
	if player.Character == character and character.Parent then
		character:PivotTo(target)
	end
	return { Ok = true }
end

function TravelService.Start()
	RemoteGuard.BindFunction("Travel", function(player: Player, destination: any): RemoteGuard.Result
		return TravelService.Travel(player, destination)
	end)
end

return TravelService
