--!strict
--[[
	MonetizationService
	ServerScriptService/Server/Services/MonetizationService

	Robux: game passes, developer products, and ProcessReceipt.

	Game passes
	  * Ownership is checked with MarketplaceService on join and cached for
	    the session. A purchase mid-session (PromptGamePassPurchaseFinished)
	    is only a hint: it is verified with UserOwnsGamePassAsync (a few
	    retries) before the cache is updated, because exploit clients can
	    fake that event. BoostService asks here via its pass
	    checker, so every pass effect (2x cash, +4 nests, auto collect, VIP
	    luck/glow, extended lock) works without other services knowing about
	    MarketplaceService.
	  * Player attributes Pass_<Key> tell the client what's owned (shop
	    "OWNED" labels, VIP chat tag).

	Developer products — ProcessReceipt is IDEMPOTENT:
	  1. Unknown player / profile not loaded -> NotProcessedYet (Roblox
	     retries later, e.g. when they rejoin).
	  2. PurchaseId already in the profile -> already granted. Make sure it's
	     saved, then PurchaseGranted. Never grant twice.
	  3. Otherwise record the PurchaseId and grant the reward in the same
	     synchronous step (no yield between), then SaveNow. Only report
	     PurchaseGranted once that save succeeded; if it failed, report
	     NotProcessedYet and the retry lands in case 2.

	Prompting: the client only ever sends ("Pass" | "Product", key). The
	server looks up the real id in Config, refuses unconfigured ids (0),
	checks the product makes sense right now (e.g. a free nest for the egg
	bundle), and prompts the purchase itself. Prices are never taken from
	the client.

	Retention (Step 7.5): the Extra Spins and Double Offline Cash products
	write straight into data.Retention (RetentionService starts later, so it
	can't be required here); ProductGranted tells RetentionService to refresh
	the player's screens. RetentionService reuses GrantInstantHatch / ExtendBuff /
	GrantEggs / GetTotalCreatureIncome so prizes behave exactly like the
	products.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Signal = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Util"):WaitForChild("Signal"))

local Server = ServerScriptService:WaitForChild("Server")
local Modules = Server:WaitForChild("Modules")
local Services = Server:WaitForChild("Services")
local RemoteGuard = require(Modules:WaitForChild("RemoteGuard"))
local Notifier = require(Modules:WaitForChild("Notifier"))
local DataService = require(Services:WaitForChild("DataService"))
local BoostService = require(Services:WaitForChild("BoostService"))
local PlotService = require(Services:WaitForChild("PlotService"))
local NestService = require(Services:WaitForChild("NestService"))

local MonetizationService = {}

--- Fired as (player, productKey) after a developer product was granted
--- (RetentionService listens so its screens update after Extra Spins /
--- Double Offline Cash). Not fired for a retried receipt.
MonetizationService.ProductGranted = Signal.new()

local ownedPasses: { [Player]: { [string]: boolean } } = {}
local passKeyById: { [number]: string } = {}
local productKeyById: { [number]: string } = {}

-- Verifying a mid-session pass purchase (not designer-tunable: plumbing for
-- the UserOwnsGamePassAsync re-check). Waits attempt * BACKOFF seconds.
local PASS_VERIFY_ATTEMPTS = 3
local PASS_VERIFY_BACKOFF = 1

local function log(fmt: string, ...: any)
	print(string.format("[SAC/Robux] " .. fmt, ...))
end

--------------------------------------------------------------------------
-- Game passes
--------------------------------------------------------------------------

function MonetizationService.OwnsPass(player: Player, key: string): boolean
	local owned = ownedPasses[player]
	return owned ~= nil and owned[key] == true
end

--- Records ownership and applies the live effects.
local function setPassOwned(player: Player, key: string, owned: boolean)
	ownedPasses[player] = ownedPasses[player] or {}
	if ownedPasses[player][key] == owned then
		return
	end
	ownedPasses[player][key] = owned
	player:SetAttribute("Pass_" .. key, owned or nil)
	-- Nest count (+4 Nests) and nest glow (VIP) are drawn by PlotService.
	PlotService.RefreshNests(player)
end

local function loadPasses(player: Player)
	for key, pass in pairs(Config.GamePasses) do
		if pass.Id ~= 0 then
			local ok, owns = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, pass.Id)
			end)
			if ok then
				if owns then
					setPassOwned(player, key, true)
				end
			else
				warn(string.format("[SAC/Robux] Couldn't check %s for %s: %s", key, player.Name, tostring(owns)))
			end
		end
	end
end

--- Studio testing only (DebugCommands): pretend a pass is owned.
function MonetizationService.DebugSetPass(player: Player, key: string, owned: boolean)
	assert(Config.GamePasses[key], "Unknown pass " .. key)
	setPassOwned(player, key, owned)
end

--------------------------------------------------------------------------
-- Developer products
--------------------------------------------------------------------------

--- Cash per second all of the player's creatures at home earn right now
--- (creatures out being stolen don't count). Used to scale cash rewards.
function MonetizationService.GetTotalCreatureIncome(player: Player): number
	local data = DataService.Get(player)
	if not data then
		return 0
	end
	local total = 0
	for _, slot in ipairs(data.Nests) do
		if slot ~= false and slot.Kind == "Creature" and not slot.Away then
			total += BoostService.GetCreatureIncome(player, slot)
		end
	end
	return total
end

--- Hatches the player's best egg right now (NestService.FindBestEgg: most
--- expensive egg type; ties go to the one with the most time left).
--- Returns true if an egg hatched. Never yields.
local function applyInstantHatch(player: Player): boolean
	local nestIndex = NestService.FindBestEgg(player)
	if not nestIndex then
		return false
	end
	return NestService.Hatch(player, nestIndex) ~= nil
end

--- Instant Hatch, as the product does it: the best egg hatches now, or the
--- hatch is saved for the next egg. Never yields. Returns true if an egg
--- hatched right away. (Also used by RetentionService for wheel prizes.)
function MonetizationService.GrantInstantHatch(player: Player): boolean
	if applyInstantHatch(player) then
		return true
	end
	DataService.Mutate(player, function(d)
		d.PendingInstantHatch += 1
	end)
	return false
end

--- Adds time to a buff ("Luck" / "HatchSpeed"), as the potions do: a running
--- buff is extended. Never yields. (Also used by RetentionService.)
function MonetizationService.ExtendBuff(player: Player, buffName: string, duration: number)
	DataService.Mutate(player, function(d)
		local now = os.time()
		d.Buffs[buffName] = math.max(now, d.Buffs[buffName] or 0) + duration
	end)
end

--- Puts eggs in free nests; any that don't fit are saved in PendingEggs and
--- placed when a nest frees up. Never yields. Returns (placed, saved).
--- (Also used by RetentionService.)
function MonetizationService.GrantEggs(player: Player, eggId: string, count: number): (number, number)
	local placed, saved = 0, 0
	for _ = 1, count do
		if NestService.PlaceEgg(player, eggId, 0) then
			placed += 1
		else
			DataService.Mutate(player, function(d)
				table.insert(d.PendingEggs, eggId)
			end)
			saved += 1
		end
	end
	return placed, saved
end

--- Double Offline Cash: what it would pay right now, and why. Mirrors the
--- grant below, so RequestPurchase can refuse when there's nothing to double.
local function offlineDoubleAmount(player: Player): (number, string)
	local data = DataService.Get(player)
	local retention = data and data.Retention
	if retention and retention.PendingOffline > 0 then
		return retention.PendingOffline * 2, "Pending"
	elseif retention and retention.LastOfflineAmount > 0 then
		return retention.LastOfflineAmount, "Last"
	end
	local offline = Config.Retention.Offline
	local fallback = math.max(offline.DoubleFallbackBase,
		math.floor(MonetizationService.GetTotalCreatureIncome(player) * offline.DoubleFallbackMinutes * 60))
	-- AddCash refuses more than AbsoluteMaxSingleCollect, and a refused
	-- grant would leave the receipt retrying forever.
	return math.min(fallback, Config.Retention.MaxCashReward, Config.Income.AbsoluteMaxSingleCollect), "Fallback"
end

--- Grants a product's reward. Must not yield. Returns a thank-you line.
local function grantProduct(player: Player, key: string): string
	local product = Config.DevProducts[key]
	if product.Kind == "Cash" then
		assert(DataService.AddCash(player, product.Amount, "robux:" .. key), "AddCash refused")
		return string.format("+$%s!", Config.FormatNumber(product.Amount))

	elseif product.Kind == "Buff" then
		MonetizationService.ExtendBuff(player, product.Buff, product.Duration)
		return string.format("%s active!", product.DisplayName)

	elseif product.Effect == "InstantHatch" then
		if MonetizationService.GrantInstantHatch(player) then
			return "Your best egg hatched!"
		end
		return "Instant Hatch saved: it'll hatch your next egg the moment it lands."

	elseif product.Effect == "ExtendLock" then
		PlotService.EmergencyLock(player, Config.Plot.EmergencyLockBonus)
		return "Camp locked!"

	elseif product.Effect == "GrantEggs" then
		local placed, saved = MonetizationService.GrantEggs(player, product.EggId, product.Count)
		if saved > 0 then
			return string.format("%d egg(s) placed, %d saved for when a nest frees up.", placed, saved)
		end
		return string.format("%d eggs placed in your nests!", placed)

	elseif product.Effect == "ExtraSpins" then
		DataService.Mutate(player, function(d)
			d.Retention.SpinExtra += product.Count
		end)
		return string.format("%d extra spins added to the wheel!", product.Count)

	elseif product.Effect == "DoubleOffline" then
		-- Read and clear in the same synchronous step as the payment, so a
		-- Claim racing this receipt can't pay the same cash twice.
		local amount, source = offlineDoubleAmount(player)
		assert(DataService.AddCash(player, amount, "robux:" .. key), "AddCash refused")
		DataService.Mutate(player, function(d)
			if source == "Pending" then
				d.Retention.PendingOffline = 0 -- paid twice over just now
			end
			-- Doubled either way: nothing is left to double.
			d.Retention.LastOfflineAmount = 0
		end)
		if source == "Fallback" then
			return string.format("Your offline cash was already doubled, so here's +$%s instead.", Config.FormatNumber(amount))
		end
		return string.format("Offline cash doubled: +$%s!", Config.FormatNumber(amount))
	end

	error("Unhandled product " .. key)
end

--- The idempotent core of ProcessReceipt, split out so Studio tests can
--- drive it with a fake PurchaseId. Returns a ProductPurchaseDecision.
function MonetizationService.ProcessReceiptForKey(player: Player, purchaseId: string, key: string, robuxSpent: number?): Enum.ProductPurchaseDecision
	local data = DataService.Get(player)
	if not data then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Already granted (a retry): just make sure it's on disk.
	if data.Purchases[purchaseId] then
		if DataService.SaveNow(player) then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Record and grant in one synchronous step. If the grant throws, undo
	-- the record so Roblox's retry can try again.
	DataService.Mutate(player, function(d)
		d.Purchases[purchaseId] = os.time()
		d.Stats.RobuxSpent = (d.Stats.RobuxSpent or 0) + (robuxSpent or 0)
	end)
	local ok, thanksOrErr = pcall(grantProduct, player, key)
	if not ok then
		warn(string.format("[SAC/Robux] Granting %s to %s failed: %s", key, player.Name, tostring(thanksOrErr)))
		DataService.Mutate(player, function(d)
			d.Purchases[purchaseId] = nil
		end)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	-- The reward is in the profile now (whether or not the save below works).
	MonetizationService.ProductGranted:Fire(player, key)

	if not DataService.SaveNow(player) then
		warn(string.format("[SAC/Robux] Granted %s to %s but the save failed; asking Roblox to retry", key, player.Name))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	log("%s bought %s (purchase %s)", player.Name, key, purchaseId)
	Notifier.Send(player, "Thanks! " .. thanksOrErr, "Success")
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local function processReceipt(receipt: any): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not DataService.WaitForData(player, 15) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local key = productKeyById[receipt.ProductId]
	if not key then
		warn(string.format("[SAC/Robux] Receipt for unknown product id %s — is it in Config.DevProducts?", tostring(receipt.ProductId)))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	return MonetizationService.ProcessReceiptForKey(player, tostring(receipt.PurchaseId), key, receipt.CurrencySpent)
end

--------------------------------------------------------------------------
-- Pending rewards (eggs that didn't fit, Instant Hatch with no egg)
--------------------------------------------------------------------------

local function applyPending()
	for _, player in ipairs(Players:GetPlayers()) do
		local data = DataService.Get(player)
		if data and PlotService.GetPlot(player) then
			if #data.PendingEggs > 0 and NestService.FindEmptyNest(player) then
				local eggId = data.PendingEggs[1]
				if NestService.PlaceEgg(player, eggId, 0) then
					DataService.Mutate(player, function(d)
						table.remove(d.PendingEggs, 1)
					end)
					Notifier.Send(player, "A saved " .. Config.Eggs[eggId].Name .. " was placed in your nest.", "Success")
				end
			end
			if data.PendingInstantHatch > 0 and applyInstantHatch(player) then
				DataService.Mutate(player, function(d)
					d.PendingInstantHatch -= 1
				end)
				Notifier.Send(player, "Your saved Instant Hatch hatched your best egg!", "Success")
			end
		end
	end
end

--------------------------------------------------------------------------
-- Prompting
--------------------------------------------------------------------------

function MonetizationService.RequestPurchase(player: Player, kind: any, key: any): RemoteGuard.Result
	if typeof(kind) ~= "string" or typeof(key) ~= "string" then
		return { Ok = false, Message = "That item doesn't exist." }
	end

	if kind == "Pass" then
		local pass = Config.GamePasses[key]
		if not pass then
			return { Ok = false, Message = "That item doesn't exist." }
		end
		if pass.Id == 0 then
			return { Ok = false, Message = pass.DisplayName .. " is coming soon!" }
		end
		if MonetizationService.OwnsPass(player, key) then
			return { Ok = false, Message = "You already own " .. pass.DisplayName .. "." }
		end
		MarketplaceService:PromptGamePassPurchase(player, pass.Id)
		return { Ok = true }

	elseif kind == "Product" then
		local product = Config.DevProducts[key]
		if not product then
			return { Ok = false, Message = "That item doesn't exist." }
		end
		if product.Id == 0 then
			return { Ok = false, Message = product.DisplayName .. " is coming soon!" }
		end
		if not PlotService.GetPlot(player) then
			return { Ok = false, Message = "You need a camp first." }
		end
		if product.Effect == "GrantEggs" and not NestService.FindEmptyNest(player) then
			return { Ok = false, Message = "You need an empty nest for the bundle — make room first." }
		end
		if product.Effect == "DoubleOffline" then
			local _, source = offlineDoubleAmount(player)
			if source == "Fallback" then
				return { Ok = false, Message = "There's no offline cash to double right now." }
			end
		end
		MarketplaceService:PromptProductPurchase(player, product.Id)
		return { Ok = true }
	end

	return { Ok = false, Message = "That item doesn't exist." }
end

--------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------

function MonetizationService.Start()
	for key, pass in pairs(Config.GamePasses) do
		if pass.Id ~= 0 then
			passKeyById[pass.Id] = key
		end
	end
	for key, product in pairs(Config.DevProducts) do
		if product.Id ~= 0 then
			productKeyById[product.Id] = key
		end
	end

	BoostService.SetPassChecker(MonetizationService.OwnsPass)
	MarketplaceService.ProcessReceipt = processReceipt

	-- Exploit clients can make this event fire with purchased = true without
	-- buying anything, so `purchased` is only a hint: ownership is confirmed
	-- with UserOwnsGamePassAsync before the cache is touched.
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, passId: number, purchased: boolean)
		local key = passKeyById[passId]
		if not (purchased and key) then
			return
		end
		task.spawn(function()
			for attempt = 1, PASS_VERIFY_ATTEMPTS do
				local ok, owns = pcall(function()
					return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
				end)
				if not player.Parent then
					return
				end
				if ok and owns then
					setPassOwned(player, key, true)
					Notifier.Send(player, "Thanks! " .. Config.GamePasses[key].DisplayName .. " is yours.", "Success")
					log("%s bought pass %s", player.Name, key)
					return
				elseif not ok then
					warn(string.format("[SAC/Robux] Couldn't verify %s for %s: %s", key, player.Name, tostring(owns)))
				end
				-- Short backoff; a real purchase updates the server's ownership cache.
				task.wait(attempt * PASS_VERIFY_BACKOFF)
			end
			log("%s: PromptGamePassPurchaseFinished for %s not confirmed by UserOwnsGamePassAsync", player.Name, key)
		end)
	end)

	RemoteGuard.BindFunction("PromptPurchase", function(player: Player, kind: any, key: any): RemoteGuard.Result
		return MonetizationService.RequestPurchase(player, kind, key)
	end)

	-- Check passes once each player's profile is in (their plot exists by
	-- then, so pass effects can be drawn).
	DataService.ProfileLoaded:Connect(function(player: Player)
		task.spawn(loadPasses, player)
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		if DataService.IsLoaded(player) then
			task.spawn(loadPasses, player)
		end
	end
	Players.PlayerRemoving:Connect(function(player)
		ownedPasses[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(2)
			local ok, err = pcall(applyPending)
			if not ok then
				warn("[SAC/Robux] pending rewards errored: " .. tostring(err))
			end
		end
	end)

	local configured = 0
	for _ in pairs(passKeyById) do configured += 1 end
	for _ in pairs(productKeyById) do configured += 1 end
	log("Ready — %d of %d passes/products have real ids", configured, (function()
		local n = 0
		for _ in pairs(Config.GamePasses) do n += 1 end
		for _ in pairs(Config.DevProducts) do n += 1 end
		return n
	end)())
end

return MonetizationService
