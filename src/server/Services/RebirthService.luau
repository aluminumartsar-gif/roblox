local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local EconomyConfig = require(ConfigFolder:WaitForChild("EconomyConfig"))
local FormatUtil = require(UtilFolder:WaitForChild("FormatUtil"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))

local CollectService = require(script.Parent:WaitForChild("CollectService"))
local EconomyService = require(script.Parent:WaitForChild("EconomyService"))
local LeaderboardPodiumService = require(script.Parent:WaitForChild("LeaderboardPodiumService"))
local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))

local RebirthService = {}

local rebirthRequestRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.REBIRTH_REQUEST_REMOTE)
local rebirthResultRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.REBIRTH_RESULT_REMOTE)
local economySyncRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.ECONOMY_SYNC_REMOTE)

local function fireEconomySnapshot(player: Player, extra)
	local snapshot = EconomyService.getSnapshot(player)
	if extra then
		for key, value in extra do
			snapshot[key] = value
		end
	end

	economySyncRemote:FireClient(player, snapshot)
end

local function getMissingRequirementMessage(missing)
	local names = {}
	for index, requirement in missing do
		if index > 2 then
			table.insert(names, ("and %d more"):format(#missing - 2))
			break
		end

		table.insert(names, ("%s x%d"):format(requirement.id, requirement.missing))
	end

	return "Need required brainrots: " .. table.concat(names, ", ") .. "."
end

function RebirthService.tryRebirth(player: Player)
	PlayerDataService.waitForData(player)

	local data = PlayerDataService.getData(player)
	local cost = EconomyConfig.getRebirthCost(data.rebirths)
	local requirements = EconomyConfig.getRebirthRequirements(data.rebirths)
	-- Requirements are now checked against the player's hotbar (the new
	-- "inventory"). Old players whose legacy inventory was migrated to the
	-- hotbar on load will satisfy these checks automatically.
	local missingRequirements = PlayerDataService.getMissingHotbarRequirements(player, requirements)
	if data.money < cost then
		local missing = cost - data.money
		rebirthResultRemote:FireClient(player, {
			success = false,
			message = ("Need %s more Money to rebirth."):format(FormatUtil.compactNumber(missing)),
			cost = cost,
			money = data.money,
		})
		fireEconomySnapshot(player)
		return false
	end
	if #missingRequirements > 0 then
		rebirthResultRemote:FireClient(player, {
			success = false,
			message = getMissingRequirementMessage(missingRequirements),
			cost = cost,
			money = data.money,
			missingRequirements = missingRequirements,
		})
		fireEconomySnapshot(player)
		return false
	end

	local consumed = PlayerDataService.consumeHotbarRequirements(player, requirements)
	if not consumed then
		rebirthResultRemote:FireClient(player, {
			success = false,
			message = "Missing required brainrots.",
			cost = cost,
			money = data.money,
		})
		fireEconomySnapshot(player)
		return false
	end
	PlayerDataService.setMoney(player, 0)
	local newRebirths = PlayerDataService.incrementRebirths(player)
	PlayerDataService.resetWalkSpeedShovelUpgrade(player)
	local newCashMultiplier = EconomyConfig.getCashMultiplier(newRebirths)
	local newLuckMultiplier = EconomyConfig.getLuckMultiplier(newRebirths)

	rebirthResultRemote:FireClient(player, {
		success = true,
		message = ("Rebirth complete! Cash is now %.2fx and luck is now %.2fx."):format(newCashMultiplier, newLuckMultiplier),
		rebirths = newRebirths,
		cashMultiplier = newCashMultiplier,
		luckMultiplier = newLuckMultiplier,
	})

	CollectService.syncPlayer(player)

	-- Sync hotbar so the client removes the consumed items from the UI.
	local HotbarService = require(script.Parent:WaitForChild("HotbarService"))
	HotbarService.syncPlayer(player)

	fireEconomySnapshot(player, {
		rebirthed = true,
	})

	LeaderboardPodiumService.pushScoresForPlayer(player)

	return true
end

function RebirthService.start()
	rebirthRequestRemote.OnServerEvent:Connect(function(player)
		RebirthService.tryRebirth(player)
	end)
end

return RebirthService
