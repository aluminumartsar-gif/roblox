-- Validates and applies shovel purchases. This is the single source of truth
-- for whether a purchase is allowed: the client (whatever shop UI is wired
-- in) fires VendorPurchaseRequest with a shovel id, and on success this
-- service deducts cash, persists the new shovel id, hands the player a
-- fresh tool with the right visual, and broadcasts VendorPurchaseResult +
-- VendorSync so the UI can refresh without forcing a respawn.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local DigConfig = require(ConfigFolder:WaitForChild("DigConfig"))
local EconomyConfig = require(ConfigFolder:WaitForChild("EconomyConfig"))
local ShovelConfig = require(ConfigFolder:WaitForChild("ShovelConfig"))
local FormatUtil = require(UtilFolder:WaitForChild("FormatUtil"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))

local Components = script.Parent.Parent:WaitForChild("Components")
local ShovelComponent = require(Components:WaitForChild("ShovelComponent"))

local EconomyService = require(script.Parent:WaitForChild("EconomyService"))
local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))

local VendorService = {}
local started = false

-- Per-user request lock so a rapid double-click on the Buy button can't
-- double-deduct cash. Cleared as soon as the request is resolved either way.
local requestLockByUserId: { [number]: boolean } = {}

local purchaseRequestRemote = RemoteRegistry.getRemote(
	EconomyConfig.VENDOR_REMOTE_FOLDER,
	EconomyConfig.VENDOR_PURCHASE_REQUEST_REMOTE
)
local purchaseResultRemote = RemoteRegistry.getRemote(
	EconomyConfig.VENDOR_REMOTE_FOLDER,
	EconomyConfig.VENDOR_PURCHASE_RESULT_REMOTE
)
local vendorSyncRemote = RemoteRegistry.getRemote(
	EconomyConfig.VENDOR_REMOTE_FOLDER,
	EconomyConfig.VENDOR_SYNC_REMOTE
)
local economySyncRemote = RemoteRegistry.getRemote(
	EconomyConfig.REMOTE_FOLDER,
	EconomyConfig.ECONOMY_SYNC_REMOTE
)

local function fireEconomySnapshot(player: Player, extra)
	local snapshot = EconomyService.getSnapshot(player)
	snapshot.shovel = PlayerDataService.getShovel(player)
	if extra then
		for key, value in extra do
			snapshot[key] = value
		end
	end

	economySyncRemote:FireClient(player, snapshot)
end

local function fireSync(player: Player)
	vendorSyncRemote:FireClient(player, {
		shovel = PlayerDataService.getShovel(player),
	})
end

-- Reissues the player's currently equipped shovel tool so the new visual and
-- attribute take effect immediately, without waiting for a respawn or for the
-- DigService idle-cleanup path to rotate it. We blow away every Shovel-named
-- tool in both Backpack and the Character (whichever the player has it in
-- right now) and let DigService.ensureShovelEquipped recreate one on the next
-- dig click. If we left a stale tool around, the player would keep digging
-- with the old stats.
local function clearExistingShovels(player: Player)
	local function purge(container: Instance?)
		if not container then
			return
		end

		for _, child in container:GetChildren() do
			if child:IsA("Tool") and child.Name == DigConfig.TOOL_NAME then
				child:Destroy()
			end
		end
	end

	purge(player:FindFirstChild("Backpack"))
	purge(player.Character)
end

-- Ships a fresh tool right into the Backpack (or the Character if the player
-- currently has one equipped) so the upgrade is visible without needing them
-- to start a new dig session first. We don't auto-equip; the player picks it
-- up from the hotbar like any other tool.
local function reissueShovel(player: Player, shovelId: string)
	clearExistingShovels(player)

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return
	end

	local tool = ShovelComponent.create(DigConfig.TOOL_NAME, shovelId)
	if not tool then
		return
	end

	tool.Parent = backpack
end

local function fireFailure(player: Player, reason: string, message: string, payload)
	local response = {
		success = false,
		reason = reason,
		message = message,
		shovel = PlayerDataService.getShovel(player),
	}
	if payload then
		for key, value in payload do
			response[key] = value
		end
	end

	purchaseResultRemote:FireClient(player, response)
end

local function buildFailureMessage(check, entry): (string, { [string]: any })
	if check.reason == "UNKNOWN_SHOVEL" then
		return "That shovel doesn't exist.", {}
	elseif check.reason == "ALREADY_OWNED" then
		return ("You already own the %s or better."):format(entry.displayName), {}
	elseif check.reason == "LOCKED_REBIRTHS" then
		local missing = check.missingRebirths or 0
		local message = ("Need %d more rebirth%s to unlock the %s."):format(
			missing,
			if missing == 1 then "" else "s",
			entry.displayName
		)
		return message, {
			missingRebirths = missing,
		}
	elseif check.reason == "INSUFFICIENT_CASH" then
		local missing = check.missingCash or 0
		local message = ("Need %s more to buy the %s."):format(
			FormatUtil.money(missing),
			entry.displayName
		)
		return message, {
			missingCash = missing,
		}
	end

	return "Purchase rejected.", {}
end

local function tryPurchase(player: Player, requestedId: any)
	if type(requestedId) ~= "string" then
		fireFailure(player, "UNKNOWN_SHOVEL", "That shovel doesn't exist.")
		return
	end

	PlayerDataService.waitForData(player)

	local data = PlayerDataService.getData(player)
	local currentShovelId = PlayerDataService.getShovel(player)
	local check = ShovelConfig.canPurchase(currentShovelId, requestedId, data.rebirths, data.money)

	if not check.ok then
		local entry = check.entry
		if not entry then
			fireFailure(player, check.reason or "UNKNOWN_SHOVEL", "That shovel doesn't exist.")
			return
		end

		local message, payload = buildFailureMessage(check, entry)
		payload.shovelId = entry.id
		fireFailure(player, check.reason or "UNKNOWN_SHOVEL", message, payload)
		return
	end

	local entry = check.entry
	if not entry then
		fireFailure(player, "UNKNOWN_SHOVEL", "That shovel doesn't exist.")
		return
	end

	if entry.cost > 0 then
		PlayerDataService.setMoney(player, math.max(0, data.money - entry.cost))
	end
	PlayerDataService.setShovel(player, entry.id)
	reissueShovel(player, entry.id)

	-- Persist immediately on every successful upgrade. Without this, a crash
	-- between purchase and disconnect would refund the shovel but keep the
	-- cash deduction — bad outcome. Mirrors the BaseUpgradeService pattern.
	task.spawn(PlayerDataService.savePlayer, player)

	purchaseResultRemote:FireClient(player, {
		success = true,
		shovel = entry.id,
		shovelId = entry.id,
		displayName = entry.displayName,
		cost = entry.cost,
		message = ("Purchased %s!"):format(entry.displayName),
	})
	fireSync(player)
	fireEconomySnapshot(player, { shovelPurchased = entry.id })
end

local function onPurchaseRequest(player: Player, requestedId: any)
	local userId = player.UserId
	if requestLockByUserId[userId] then
		return
	end
	requestLockByUserId[userId] = true

	local ok, err = pcall(tryPurchase, player, requestedId)
	requestLockByUserId[userId] = nil

	if not ok then
		warn(("[Vendor] Purchase failed for %s: %s"):format(player.Name, tostring(err)))
		fireFailure(player, "UNKNOWN_SHOVEL", "Purchase rejected.")
	end
end

function VendorService.start()
	if started then
		return
	end
	started = true

	if purchaseRequestRemote:GetAttribute("VendorServiceBound") then
		return
	end
	purchaseRequestRemote:SetAttribute("VendorServiceBound", true)

	purchaseRequestRemote.OnServerEvent:Connect(onPurchaseRequest)

	-- Initial sync per join: the client uses this to render correct state
	-- (Equipped badge, locked rows) the first time the panel opens.
	local function syncOnLoad(player: Player)
		task.spawn(function()
			PlayerDataService.waitForData(player)
			if not player.Parent then
				return
			end

			fireSync(player)
		end)
	end

	Players.PlayerAdded:Connect(syncOnLoad)
	for _, player in Players:GetPlayers() do
		syncOnLoad(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		requestLockByUserId[player.UserId] = nil
	end)
end

return VendorService
