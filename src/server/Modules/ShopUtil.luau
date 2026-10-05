--!strict
--[[
	ShopUtil
	ServerScriptService/Server/Modules/ShopUtil

	Shared checks for the hub shops.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local RemoteGuard = require(ServerScriptService:WaitForChild("Server"):WaitForChild("Modules"):WaitForChild("RemoteGuard"))

local ShopUtil = {}

--- True if the player is standing at a counter of the given shop
--- ("Eggs" / "Upgrades"), within Config.Shop.InteractDistance.
function ShopUtil.IsAtShop(player: Player, shopId: string): boolean
	for _, counter in ipairs(CollectionService:GetTagged(Config.Tags.ShopBooth)) do
		if counter:IsA("BasePart") and counter:GetAttribute("ShopId") == shopId then
			if RemoteGuard.IsWithinReach(player, counter.Position, Config.Shop.InteractDistance) then
				return true
			end
		end
	end
	return false
end

return ShopUtil
