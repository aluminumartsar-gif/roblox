--!strict
--[[
	MonetizationService
	ServerScriptService/Server/Services/MonetizationService

	Robux: game passes, developer products, and ProcessReceipt.

	Game passes
	  * Ownership is checked with MarketplaceService on join and cached for
	    the session; a purchase mid-session (PromptGamePassPurchaseFinished)
	    updates the cache at once. BoostService asks here via its pass
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
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

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

local ownedPasses: { [Player]: { [string]: boolean } } = {}
local passKeyById: { [number]: string } = {}
local productKeyById: { [number]: string } = {}

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

--- Puts the player's best not-yet-maxed egg at max heat. "Best" = most
--- expensive egg type; ties go to the coolest egg. Returns true if applied.
local function applyMaxHeat(player: Player): boolean
	local data = DataService.Get(player)
	if not data then
		return false
	end
	local bestIndex, bestPrice, bestHeat = nil, -1, math.huge
	for i, slot in ipairs(data.Nests) do
		if slot ~= false and slot.Kind == "Egg" and not slot.Away and slot.Heat < Config.Heat.Max then
			local price = Config.Eggs[slot.EggId].Price
			if price > bestPrice or (price == bestPrice and slot.Heat < bestHeat) then
				bestIndex, bestPrice, bestHeat = i, price, slot.Heat
			end
		end
	end
	if not bestIndex then
		return false
	end
	return NestService.SetEggHeat(player, bestIndex, Config.Heat.Max)
end

--- Grants a product's reward. Must not yield. Returns a thank-you line.
local function grantProduct(player: Player, key: string): string
	local product = Config.DevProducts[key]
	if product.Kind == "Cash" then
		assert(DataService.AddCash(player, product.Amount, "robux:" .. key), "AddCash refused")
		return string.format("+$%s!", Config.FormatNumber(product.Amount))

	elseif product.Kind == "Buff" then
		DataService.Mutate(player, function(d)
			local now = os.time()
			d.Buffs[product.Buff] = math.max(now, d.Buffs[product.Buff] or 0) + product.Duration
		end)
		return string.format("%s active!", product.DisplayName)

	elseif product.Effect == "MaxHeatOneEgg" then
		if applyMaxHeat(player) then
			return "Your best egg is at max heat!"
		end
		DataService.Mutate(player, function(d)
			d.PendingMaxHeat += 1
		end)
		return "Max Heat saved — it'll hit your next egg."

	elseif product.Effect == "ExtendLock" then
		PlotService.EmergencyLock(player, Config.Plot.EmergencyLockBonus)
		return "Camp locked!"

	elseif product.Effect == "GrantEggs" then
		local placed, saved = 0, 0
		for _ = 1, product.Count do
			if NestService.PlaceEgg(player, product.EggId, 0) then
				placed += 1
			else
				DataService.Mutate(player, function(d)
					table.insert(d.PendingEggs, product.EggId)
				end)
				saved += 1
			end
		end
		if saved > 0 then
			return string.format("%d egg(s) placed, %d saved for when a nest frees up.", placed, saved)
		end
		return string.format("%d eggs placed in your nests!", placed)
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
-- Pending rewards (eggs that didn't fit, Max Heat with no egg)
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
			if data.PendingMaxHeat > 0 and applyMaxHeat(player) then
				DataService.Mutate(player, function(d)
					d.PendingMaxHeat -= 1
				end)
				Notifier.Send(player, "Your saved Max Heat warmed your best egg!", "Success")
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

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, passId: number, purchased: boolean)
		local key = passKeyById[passId]
		if purchased and key then
			setPassOwned(player, key, true)
			Notifier.Send(player, "Thanks! " .. Config.GamePasses[key].DisplayName .. " is yours.", "Success")
			log("%s bought pass %s", player.Name, key)
		end
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
