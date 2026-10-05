--!strict
--[[
	UpgradeService
	ServerScriptService/Server/Services/UpgradeService

	The Upgrade Shop. BuyUpgrade(upgradeId) buys the next level of one track
	in Config.Upgrades. The server checks, in order: a real upgrade id, not
	already at max, standing at the Upgrades counter, can afford it — then
	raises the level and applies the effect right away:

	  NestSlots        -> more nests light up (PlotService.RefreshNests)
	  WalkSpeed        -> MovementService.Refresh
	  IncubationSpeed, VaultSize, LockDuration
	                   -> read live by the heat tick, income tick and lock,
	                      so there's nothing to push
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Server = ServerScriptService:WaitForChild("Server")
local Modules = Server:WaitForChild("Modules")
local Services = Server:WaitForChild("Services")
local RemoteGuard = require(Modules:WaitForChild("RemoteGuard"))
local ShopUtil = require(Modules:WaitForChild("ShopUtil"))
local DataService = require(Services:WaitForChild("DataService"))
local PlotService = require(Services:WaitForChild("PlotService"))
local MovementService = require(Services:WaitForChild("MovementService"))

local UpgradeService = {}

local function formatValue(upgradeId: string, value: number): string
	if upgradeId == "IncubationSpeed" then
		return string.format("x%.2f", value)
	elseif upgradeId == "VaultSize" then
		return "$" .. Config.FormatNumber(value)
	elseif upgradeId == "LockDuration" then
		return value .. "s"
	end
	return tostring(value)
end

--- Applies the live effect of an upgrade level change.
function UpgradeService.ApplyEffects(player: Player)
	PlotService.RefreshNests(player)
	MovementService.Refresh(player)
end

function UpgradeService.Buy(player: Player, upgradeId: any): RemoteGuard.Result
	if typeof(upgradeId) ~= "string" or not Config.Upgrades[upgradeId] then
		return { Ok = false, Message = "That upgrade doesn't exist." }
	end
	local upgrade = Config.Upgrades[upgradeId]

	local data = DataService.Get(player)
	if not data then
		return { Ok = false, Message = "Still loading your save..." }
	end
	local level = data.Upgrades[upgradeId] or 1
	local cost = Config.GetUpgradeNextCost(upgradeId, level)
	if not cost then
		return { Ok = false, Message = upgrade.DisplayName .. " is already maxed." }
	end
	if not ShopUtil.IsAtShop(player, "Upgrades") then
		return { Ok = false, Message = "Walk up to the Upgrade Shop to buy." }
	end
	if not DataService.TrySpendCash(player, cost, "upgrade:" .. upgradeId) then
		return { Ok = false, Message = string.format("Not enough cash (need $%s).", Config.FormatNumber(cost)) }
	end

	DataService.Mutate(player, function(d)
		d.Upgrades[upgradeId] = level + 1
	end)
	UpgradeService.ApplyEffects(player)

	local newValue = Config.GetUpgradeValue(upgradeId, level + 1)
	return {
		Ok = true,
		Message = string.format("%s upgraded to %s!", upgrade.DisplayName, formatValue(upgradeId, newValue)),
		Level = level + 1,
	}
end

function UpgradeService.Start()
	RemoteGuard.BindFunction("BuyUpgrade", function(player: Player, upgradeId: any): RemoteGuard.Result
		return UpgradeService.Buy(player, upgradeId)
	end)
end

return UpgradeService
