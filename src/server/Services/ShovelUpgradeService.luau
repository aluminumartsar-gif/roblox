--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local EconomyConfig = require(ConfigFolder:WaitForChild("EconomyConfig"))
local ShovelUpgradeConfig = require(ConfigFolder:WaitForChild("ShovelUpgradeConfig"))
local FormatUtil = require(UtilFolder:WaitForChild("FormatUtil"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))

local EconomyService = require(script.Parent:WaitForChild("EconomyService"))
local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))

local ShovelUpgradeService = {}

local upgradeRequestRemote = RemoteRegistry.getRemote(
	EconomyConfig.REMOTE_FOLDER,
	EconomyConfig.SHOVEL_UPGRADE_REQUEST_REMOTE
)
local upgradeResultRemote = RemoteRegistry.getRemote(
	EconomyConfig.REMOTE_FOLDER,
	EconomyConfig.SHOVEL_UPGRADE_RESULT_REMOTE
)
local economySyncRemote = RemoteRegistry.getRemote(
	EconomyConfig.REMOTE_FOLDER,
	EconomyConfig.ECONOMY_SYNC_REMOTE
)

local function fireEconomySnapshot(player: Player, extra: { [string]: any }?)
	local snapshot = EconomyService.getSnapshot(player)
	if extra then
		for key, value in extra do
			snapshot[key] = value
		end
	end

	economySyncRemote:FireClient(player, snapshot)
end

local function fireFailure(player: Player, message: string, extra: { [string]: any }?)
	local response = {
		success = false,
		message = message,
	}
	if extra then
		for key, value in extra do
			response[key] = value
		end
	end

	upgradeResultRemote:FireClient(player, response)
	fireEconomySnapshot(player)
end

function ShovelUpgradeService.tryPurchase(player: Player, statIdRaw: any)
	PlayerDataService.waitForData(player)

	if typeof(statIdRaw) ~= "string" then
		fireFailure(player, "Invalid upgrade.")
		return false
	end

	local statId: ShovelUpgradeConfig.StatId?
	if statIdRaw == "luck" then
		statId = "luck"
	elseif statIdRaw == "greenBar" then
		statId = "greenBar"
	elseif statIdRaw == "walkSpeed" then
		statId = "walkSpeed"
	end

	if not statId then
		fireFailure(player, "Invalid upgrade.")
		return false
	end

	local data = PlayerDataService.getData(player)
	local upgrades = PlayerDataService.getShovelUpgrades(player)
	local current = upgrades[statId]
	if ShovelUpgradeConfig.isStatMaxed(statId, current) then
		fireFailure(player, "This upgrade is maxed out.")
		return false
	end

	local cost = ShovelUpgradeConfig.getUpgradeCost(statId, current, data.rebirths)
	if cost <= 0 then
		fireFailure(player, "This upgrade is maxed out.")
		return false
	end

	if data.money < cost then
		local missing = cost - data.money
		fireFailure(player, ("Need %s more."):format(FormatUtil.money(missing)), {
			cost = cost,
			money = data.money,
			statId = statId,
		})
		return false
	end

	local previousMoney = data.money
	PlayerDataService.setMoney(player, math.max(0, previousMoney - cost))
	local newLevel = PlayerDataService.incrementShovelUpgrade(player, statId)
	if not newLevel then
		PlayerDataService.setMoney(player, previousMoney)
		fireFailure(player, "Upgrade failed. Try again.")
		return false
	end

	task.spawn(PlayerDataService.savePlayer, player)

	local nextUpgrades = PlayerDataService.getShovelUpgrades(player)
	local moneyAfter = PlayerDataService.getData(player).money
	upgradeResultRemote:FireClient(player, {
		success = true,
		statId = statId,
		newLevel = newLevel,
		shovelUpgrades = nextUpgrades,
		cost = cost,
		money = moneyAfter,
	})

	fireEconomySnapshot(player)

	return true
end

function ShovelUpgradeService.start()
	upgradeRequestRemote.OnServerEvent:Connect(function(player: Player, statId: any)
		ShovelUpgradeService.tryPurchase(player, statId)
	end)
end

return ShovelUpgradeService
