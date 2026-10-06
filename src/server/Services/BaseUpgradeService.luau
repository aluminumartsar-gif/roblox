local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local EconomyConfig = require(ConfigFolder:WaitForChild("EconomyConfig"))
local PlotConfig = require(ConfigFolder:WaitForChild("PlotConfig"))
local FormatUtil = require(UtilFolder:WaitForChild("FormatUtil"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))

local CollectService = require(script.Parent:WaitForChild("CollectService"))
local EconomyService = require(script.Parent:WaitForChild("EconomyService"))
local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))

local BaseUpgradeService = {}

-- Tiny in-process listener registry so PlotService (or anything else) can be
-- notified after a successful upgrade without us having to require PlotService
-- here. Keeps the dependency graph one-way: PlotService -> BaseUpgradeService.
local upgradedListeners: { (Player, number) -> () } = {}

local upgradeRequestRemote = RemoteRegistry.getRemote(
	EconomyConfig.REMOTE_FOLDER,
	EconomyConfig.BASE_UPGRADE_REQUEST_REMOTE
)
local upgradeResultRemote = RemoteRegistry.getRemote(
	EconomyConfig.REMOTE_FOLDER,
	EconomyConfig.BASE_UPGRADE_RESULT_REMOTE
)
local economySyncRemote = RemoteRegistry.getRemote(
	EconomyConfig.REMOTE_FOLDER,
	EconomyConfig.ECONOMY_SYNC_REMOTE
)

local function fireEconomySnapshot(player: Player, extra)
	local snapshot = EconomyService.getSnapshot(player)
	snapshot.baseTier = PlayerDataService.getBaseTier(player)
	if extra then
		for key, value in extra do
			snapshot[key] = value
		end
	end

	economySyncRemote:FireClient(player, snapshot)
end

local function notifyUpgraded(player: Player, tier: number)
	for _, listener in upgradedListeners do
		local ok, err = pcall(listener, player, tier)
		if not ok then
			warn(("[BaseUpgrade] Listener error: %s"):format(tostring(err)))
		end
	end
end

local function fireFailure(player: Player, message: string, payload)
	local response = {
		success = false,
		message = message,
		baseTier = PlayerDataService.getBaseTier(player),
	}
	if payload then
		for key, value in payload do
			response[key] = value
		end
	end

	upgradeResultRemote:FireClient(player, response)
	fireEconomySnapshot(player)
end

function BaseUpgradeService.onUpgraded(listener: (Player, number) -> ())
	table.insert(upgradedListeners, listener)
end

function BaseUpgradeService.getUpgradePreview(player: Player)
	PlayerDataService.waitForData(player)

	local data = PlayerDataService.getData(player)
	local currentTier = PlotConfig.clampTier(data.baseTier)
	local nextTierIndex, nextTier = PlotConfig.getNextTier(currentTier)
	if not nextTierIndex or not nextTier then
		return {
			currentTier = currentTier,
			isMaxTier = true,
		}
	end

	return {
		currentTier = currentTier,
		nextTier = nextTierIndex,
		isMaxTier = false,
		displayName = nextTier.displayName,
		rebirths = nextTier.rebirths,
		cost = nextTier.cost,
		canAfford = data.money >= nextTier.cost,
		hasRebirths = data.rebirths >= nextTier.rebirths,
	}
end

function BaseUpgradeService.tryUpgrade(player: Player)
	PlayerDataService.waitForData(player)

	local data = PlayerDataService.getData(player)
	local currentTier = PlotConfig.clampTier(data.baseTier)
	local nextTierIndex, nextTier = PlotConfig.getNextTier(currentTier)
	if not nextTierIndex or not nextTier then
		fireFailure(player, "Your base is already at the highest tier.")
		return false
	end

	if data.rebirths < nextTier.rebirths then
		local missing = nextTier.rebirths - data.rebirths
		fireFailure(player, ("Need %d more rebirth%s to unlock the %s."):format(
			missing,
			if missing == 1 then "" else "s",
			nextTier.displayName
		))
		return false
	end

	if data.money < nextTier.cost then
		local missing = nextTier.cost - data.money
		fireFailure(player, ("Need %s more to unlock the %s."):format(
			FormatUtil.money(missing),
			nextTier.displayName
		))
		return false
	end

	if nextTier.cost > 0 then
		PlayerDataService.addMoney(player, -nextTier.cost, "BaseUpgrade")
	end
	local newTier = PlayerDataService.setBaseTier(player, nextTierIndex)

	-- Persist immediately on every successful upgrade. Without this, the new
	-- tier only hits the DataStore when the player leaves or the server
	-- shuts down, so a crash between purchase and disconnect would refund
	-- the floor on rejoin. SetAsync runs on its own thread so the response
	-- back to the player isn't blocked on DataStore latency.
	task.spawn(PlayerDataService.savePlayer, player)

	notifyUpgraded(player, newTier)

	upgradeResultRemote:FireClient(player, {
		success = true,
		baseTier = newTier,
		displayName = nextTier.displayName,
		message = "now open!",
		accentColor = nextTier.accentColor,
	})
	CollectService.syncPlayer(player)
	fireEconomySnapshot(player, { baseTierUpgraded = true })

	return true
end

function BaseUpgradeService.start()
	upgradeRequestRemote.OnServerEvent:Connect(function(player)
		BaseUpgradeService.tryUpgrade(player)
	end)
end

return BaseUpgradeService
