--!strict
--[[
	NestService
	ServerScriptService/Server/Services/NestService

	Owns what sits in each nest, and its model in the world.

	  * Source of truth is the owner's profile: data.Nests[i] is an egg slot,
	    a creature slot, or false. This service turns that into models in
	    Workspace.Runtime when a plot is claimed, and clears them on release.
	  * Incubation: every Config.Incubation.TickInterval, each egg's
	    Incubated seconds grow by dt * BoostService.GetHatchSpeedMultiplier.
	    Written straight into the profile without a client push (it changes
	    every second); clients read the egg model's Progress / Remaining
	    attributes. When an egg reaches its HatchTime it hatches by itself.
	    An egg that's away (being carried by a thief) doesn't incubate.
	  * Hatch: rolls on the server with the owner's luck, swaps the slot to a
	    creature, fires HatchResult to the owner for the reveal.
	  * Sell: owner-only prompt on a creature. Pays its vault plus
	    Config.Sell.RefundSeconds of its income and empties the nest.
	  * Big eggs (Config.Eggs[id].AnnounceInNest) are announced to the whole
	    server when they land in a nest — an open invitation to thieves.

	Model attributes (read by the client's NestVisualsController):
	  all:      Kind ("Egg"|"Creature"), OwnerUserId, PlotIndex, NestIndex
	  egg:      EggId, Progress (0..1), Remaining (seconds at the current speed)
	  creature: CreatureId, Rarity, Mutation, Vault, VaultCap, IncomePerSecond
	            (the income ones are kept up to date by IncomeService)

	StealService moves eggs with SetAway / SetSlot.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Signal = require(Shared:WaitForChild("Util"):WaitForChild("Signal"))

local Server = ServerScriptService:WaitForChild("Server")
local Modules = Server:WaitForChild("Modules")
local Services = Server:WaitForChild("Services")
local EggRoller = require(Modules:WaitForChild("EggRoller"))
local ItemVisuals = require(Shared:WaitForChild("ItemVisuals"))
local RemoteGuard = require(Modules:WaitForChild("RemoteGuard"))
local Notifier = require(Modules:WaitForChild("Notifier"))
local DataService = require(Services:WaitForChild("DataService"))
local BoostService = require(Services:WaitForChild("BoostService"))
local PlotService = require(Services:WaitForChild("PlotService"))

type PlotRecord = PlotService.PlotRecord

local NestService = {}

--- Fired as (owner, plot, nestIndex, model, slot) after a nest's model is
--- (re)built. IncomeService hooks creature touches here.
NestService.ItemRendered = Signal.new()
--- Fired as (owner, nestIndex, result) after a successful hatch.
NestService.Hatched = Signal.new()
--- Fired as (owner, nestIndex, creatureId, amount) after a creature is sold.
NestService.Sold = Signal.new()

-- plotIndex -> nestIndex -> model
local visuals: { [number]: { [number]: Model } } = {}

local runtimeFolder: Folder

local function log(fmt: string, ...: any)
	if Config.Debug.Verbose then
		print(string.format("[SAC/Nest] " .. fmt, ...))
	end
end

local function formatClock(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

--------------------------------------------------------------------------
-- Slots
--------------------------------------------------------------------------

function NestService.GetSlot(player: Player, nestIndex: number): any
	local data = DataService.Get(player)
	if not data then
		return nil
	end
	local slot = data.Nests[nestIndex]
	return if slot == false then nil else slot
end

function NestService.GetCapacity(player: Player): number
	return BoostService.GetNestCapacity(player)
end

--- First empty nest the player can use, or nil.
function NestService.FindEmptyNest(player: Player): number?
	local data = DataService.Get(player)
	if not data then
		return nil
	end
	for i = 1, NestService.GetCapacity(player) do
		if data.Nests[i] == false then
			return i
		end
	end
	return nil
end

function NestService.CountUsed(player: Player): number
	local data = DataService.Get(player)
	if not data then
		return 0
	end
	local used = 0
	for _, slot in ipairs(data.Nests) do
		if slot ~= false then
			used += 1
		end
	end
	return used
end

--- Seconds of incubation an egg needs (its HatchTime).
function NestService.GetHatchTime(eggId: string): number
	local egg = Config.Eggs[eggId]
	return if egg then egg.HatchTime else 60
end

--- 0..1 incubation progress of an egg slot.
function NestService.GetProgress(slot: any): number
	if not slot or slot.Kind ~= "Egg" then
		return 0
	end
	return math.clamp((slot.Incubated or 0) / NestService.GetHatchTime(slot.EggId), 0, 1)
end

local function newEggSlot(eggId: string, incubated: number): any
	local now = os.time()
	return { Kind = "Egg", EggId = eggId, Incubated = incubated, Vault = 0, AcquiredAt = now, LastIncomeAt = now }
end

local function newCreatureSlot(result: EggRoller.HatchResult): any
	local now = os.time()
	return {
		Kind = "Creature",
		CreatureId = result.CreatureId,
		Rarity = result.Rarity,
		Mutation = result.Mutation,
		Vault = 0,
		AcquiredAt = now,
		LastIncomeAt = now,
	}
end

--------------------------------------------------------------------------
-- Visuals
--------------------------------------------------------------------------

function NestService.GetVisual(plotIndex: number, nestIndex: number): Model?
	local byNest = visuals[plotIndex]
	return byNest and byNest[nestIndex]
end

--- Where an item stands on a nest: on the nest's anchor, facing the door.
function NestService.GetItemCFrame(plot: PlotRecord, nestIndex: number): CFrame
	local nest = plot.Nests[nestIndex]
	local base = nest.PrimaryPart :: BasePart
	local anchor = base:FindFirstChild("ItemAnchor") :: Attachment
	return CFrame.new(anchor.WorldPosition) * plot.CFrame.Rotation
end

local function clearVisual(plotIndex: number, nestIndex: number)
	local byNest = visuals[plotIndex]
	local model = byNest and byNest[nestIndex]
	if model then
		model:Destroy()
		byNest[nestIndex] = nil
	end
end

--- Pushes an egg's progress onto its model for the label.
local function updateEggAttributes(model: Model, slot: any, speed: number)
	local hatchTime = NestService.GetHatchTime(slot.EggId)
	local incubated = math.clamp(slot.Incubated or 0, 0, hatchTime)
	local progress = math.floor(incubated / hatchTime * 1000) / 1000
	local remaining = math.ceil((hatchTime - incubated) / math.max(speed, 0.01))
	if model:GetAttribute("Progress") ~= progress then
		model:SetAttribute("Progress", progress)
	end
	if model:GetAttribute("Remaining") ~= remaining then
		model:SetAttribute("Remaining", remaining)
	end
end

local sellFromPrompt: (Player, PlotRecord, number) -> ()

local function addSellPrompt(model: Model, slot: any, plot: PlotRecord, nestIndex: number)
	if not Config.Sell.Enabled then
		return
	end
	local def = Config.CreaturesById[slot.CreatureId]
	local rarityIndex = Config.GetRarityIndex(slot.Rarity or "")
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "SellPrompt"
	prompt.ActionText = "Sell"
	prompt.ObjectText = if def then def.Name else "Cryptid"
	prompt.HoldDuration = if rarityIndex >= Config.Sell.RareHoldFromIndex
		then Config.Prompts.SellHoldRare
		else Config.Prompts.SellHold
	prompt.MaxActivationDistance = Config.Prompts.MaxActivationDistance
	prompt.RequiresLineOfSight = Config.Prompts.RequiresLineOfSight
	-- Only the owner ever sees it (NestVisualsController); the server checks too.
	prompt.Enabled = false
	prompt.Parent = model.PrimaryPart
	prompt.Triggered:Connect(function(player)
		sellFromPrompt(player, plot, nestIndex)
	end)
end

--- Rebuilds the model for one nest from the owner's profile.
function NestService.RenderNest(plot: PlotRecord, nestIndex: number)
	clearVisual(plot.Index, nestIndex)
	local owner = plot.Owner
	if not owner then
		return
	end
	local slot = NestService.GetSlot(owner, nestIndex)
	if not slot or slot.Away then
		-- Away = being carried by a thief; StealService draws it.
		return
	end

	local model: Model
	if slot.Kind == "Egg" then
		model = ItemVisuals.BuildEgg(slot.EggId)
		model:SetAttribute("EggId", slot.EggId)
		updateEggAttributes(model, slot, BoostService.GetHatchSpeedMultiplier(owner))
		CollectionService:AddTag(model, Config.Tags.Egg)
	else
		model = ItemVisuals.BuildCreature(slot.CreatureId, slot.Mutation)
		model:SetAttribute("CreatureId", slot.CreatureId)
		model:SetAttribute("Rarity", slot.Rarity)
		if slot.Mutation then
			model:SetAttribute("Mutation", slot.Mutation)
		end
		model:SetAttribute("Vault", math.floor(slot.Vault))
		model:SetAttribute("VaultCap", BoostService.GetVaultCap(owner, slot))
		model:SetAttribute("IncomePerSecond", BoostService.GetCreatureIncome(owner, slot))
		CollectionService:AddTag(model, Config.Tags.Creature)
		addSellPrompt(model, slot, plot, nestIndex)
	end

	model:SetAttribute("Kind", slot.Kind)
	model:SetAttribute("OwnerUserId", owner.UserId)
	model:SetAttribute("PlotIndex", plot.Index)
	model:SetAttribute("NestIndex", nestIndex)
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	model:PivotTo(NestService.GetItemCFrame(plot, nestIndex))
	model.Parent = runtimeFolder

	visuals[plot.Index] = visuals[plot.Index] or {}
	visuals[plot.Index][nestIndex] = model

	NestService.ItemRendered:Fire(owner, plot, nestIndex, model, slot)
end

function NestService.RenderPlot(plot: PlotRecord)
	for nestIndex = 1, Config.Plot.MaxNests do
		NestService.RenderNest(plot, nestIndex)
	end
end

local function clearPlot(plotIndex: number)
	for nestIndex = 1, Config.Plot.MaxNests do
		clearVisual(plotIndex, nestIndex)
	end
	visuals[plotIndex] = nil
end

--------------------------------------------------------------------------
-- Changing slots
--------------------------------------------------------------------------

local function announce(text: string, rarity: string)
	RemoteGuard.GetClientEvent("GlobalAnnounce"):FireAllClients(text, rarity)
end

--- A big egg just landed in a nest: tell everyone where to find it.
local function announceBigEgg(player: Player, slot: any)
	local egg = Config.Eggs[slot.EggId]
	if not egg or not egg.AnnounceInNest then
		return
	end
	local remaining = (egg.HatchTime - (slot.Incubated or 0)) / math.max(BoostService.GetHatchSpeedMultiplier(player), 0.01)
	announce(string.format("%s has a %s hatching at their camp in %s. Go get it!",
		player.DisplayName, string.upper(egg.Name), formatClock(remaining)), "Legendary")
end

--- Puts a slot (or false) into a nest, saves, pushes, and redraws.
function NestService.SetSlot(player: Player, nestIndex: number, slot: any)
	DataService.Mutate(player, function(data)
		data.Nests[nestIndex] = if slot == nil then false else slot
	end)
	local plot = PlotService.GetPlot(player)
	if plot then
		NestService.RenderNest(plot, nestIndex)
	end
	if slot and slot.Kind == "Egg" then
		announceBigEgg(player, slot)
	end
end

--- Marks a nest's item as away (being carried by a thief) or home again.
--- An away item keeps its nest reserved, isn't drawn, and doesn't tick.
function NestService.SetAway(player: Player, nestIndex: number, away: boolean, thiefUserId: number?, immuneUntil: number?)
	DataService.Mutate(player, function(data)
		local slot = data.Nests[nestIndex]
		if slot == false then
			return
		end
		slot.Away = if away then true else nil
		slot.AwayThief = if away then thiefUserId else nil
		if immuneUntil then
			slot.ImmuneUntil = immuneUntil
		end
	end)
	local plot = PlotService.GetPlot(player)
	if plot then
		NestService.RenderNest(plot, nestIndex)
	end
end

--- Removes and returns a nest's slot. nil if empty.
function NestService.TakeSlot(player: Player, nestIndex: number): any
	local slot = NestService.GetSlot(player, nestIndex)
	if slot then
		NestService.SetSlot(player, nestIndex, false)
	end
	return slot
end

--- Places a new egg in the first free nest. Returns the nest index, or nil
--- if there's no room. Does NOT charge — the caller handles payment.
--- `incubated` is seconds of progress it already has (default 0).
function NestService.PlaceEgg(player: Player, eggId: string, incubated: number?): number?
	assert(Config.Eggs[eggId], "Unknown egg " .. tostring(eggId))
	local nestIndex = NestService.FindEmptyNest(player)
	if not nestIndex then
		return nil
	end
	local hatchTime = NestService.GetHatchTime(eggId)
	NestService.SetSlot(player, nestIndex, newEggSlot(eggId, math.clamp(incubated or 0, 0, hatchTime)))
	return nestIndex
end

--- The player's most valuable egg in a nest (ties: the one with the most
--- time left), or nil. Used by Instant Hatch.
function NestService.FindBestEgg(player: Player): number?
	local data = DataService.Get(player)
	if not data then
		return nil
	end
	local bestIndex, bestPrice, bestProgress = nil, -1, math.huge
	for i, slot in ipairs(data.Nests) do
		if slot ~= false and slot.Kind == "Egg" and not slot.Away then
			local price = Config.Eggs[slot.EggId].Price
			local progress = NestService.GetProgress(slot)
			if price > bestPrice or (price == bestPrice and progress < bestProgress) then
				bestIndex, bestPrice, bestProgress = i, price, progress
			end
		end
	end
	return bestIndex
end

--------------------------------------------------------------------------
-- Hatching
--------------------------------------------------------------------------

--- Hatches the egg in `nestIndex` right now. Returns the result, or nil if
--- there was no egg there. Never yields.
function NestService.Hatch(player: Player, nestIndex: number): EggRoller.HatchResult?
	local slot = NestService.GetSlot(player, nestIndex)
	if not slot or slot.Kind ~= "Egg" or slot.Away then
		return nil
	end

	local eggId = slot.EggId
	local luck = BoostService.GetLuckPercent(player)
	local result = EggRoller.Hatch(eggId, luck)

	-- The check above and this write happen with no yield between them, so
	-- a double-trigger can't hatch the same egg twice.
	DataService.Mutate(player, function(data)
		data.Nests[nestIndex] = newCreatureSlot(result)
		data.Stats.Hatches = (data.Stats.Hatches or 0) + 1
		data.Stats.HatchesByRarity[result.Rarity] = (data.Stats.HatchesByRarity[result.Rarity] or 0) + 1
	end)
	local plot = PlotService.GetPlot(player)
	if plot then
		NestService.RenderNest(plot, nestIndex)
	end

	-- The hatcher's celebration (FeedbackController): presentation only.
	-- (pcall: a missing nest anchor must never cut the hatch short — the
	-- slot is already a creature, and the log/toast/Hatched below must run.)
	if player.Parent ~= nil then
		local okCf, itemCf = pcall(function()
			return if plot then NestService.GetItemCFrame(plot, nestIndex) else nil
		end)
		local nestPosition = if okCf and itemCf then itemCf.Position else nil
		RemoteGuard.GetClientEvent("HatchResult"):FireClient(player,
			result.CreatureId, result.Rarity, result.Mutation, eggId, nestPosition)
	end

	local def = Config.CreaturesById[result.CreatureId]
	local rarity = Config.Rarities[result.Rarity]
	log("%s hatched %s (%s) from %s, luck %d%%", player.Name, def.Name, result.Rarity, eggId, luck)

	if rarity.AnnounceOnHatch then
		if rarity.NeverRenderClearly then
			announce(string.format("%s hatched something that shouldn't exist...", player.DisplayName), result.Rarity)
		else
			announce(string.format("%s hatched a %s %s!", player.DisplayName, string.upper(rarity.DisplayName), def.Name), result.Rarity)
		end
	end

	NestService.Hatched:Fire(player, nestIndex, result)
	return result
end

--------------------------------------------------------------------------
-- Selling
--------------------------------------------------------------------------

--- What selling this creature slot pays right now.
function NestService.GetSellValue(player: Player, slot: any): number
	if not slot or slot.Kind ~= "Creature" then
		return 0
	end
	local income = BoostService.GetCreatureIncome(player, slot)
	return math.floor((slot.Vault or 0) + income * Config.Sell.RefundSeconds)
end

--- Sells the creature in `nestIndex`. Returns the cash paid (0 = nothing).
--- All checks (ownership, distance) are the caller's job.
function NestService.Sell(player: Player, nestIndex: number): number
	local slot = NestService.GetSlot(player, nestIndex)
	if not slot or slot.Kind ~= "Creature" or slot.Away then
		return 0
	end
	local amount = NestService.GetSellValue(player, slot)
	local plot = PlotService.GetPlot(player)
	local model = plot and NestService.GetVisual(plot.Index, nestIndex)
	local position = if model then model:GetPivot().Position else nil

	-- Empty the nest first, then pay; nothing yields in between.
	NestService.SetSlot(player, nestIndex, false)
	DataService.Mutate(player, function(data)
		data.Stats.CreaturesSold = (data.Stats.CreaturesSold or 0) + 1
	end)
	if amount > 0 then
		DataService.AddCash(player, amount, "sell")
		if position then
			RemoteGuard.GetClientEvent("CashCollected"):FireClient(player, amount, position)
		end
	end

	local def = Config.CreaturesById[slot.CreatureId]
	local rarity = Config.Rarities[slot.Rarity or ""]
	Notifier.Send(player, string.format("Sold your %s%s for $%s. Nest %d is free.",
		if rarity and not rarity.NeverRenderClearly then rarity.DisplayName .. " " else "",
		if def then def.Name else "cryptid", Config.FormatNumber(amount), nestIndex), "Success")
	log("%s sold %s from nest %d for %d", player.Name, slot.CreatureId, nestIndex, amount)
	NestService.Sold:Fire(player, nestIndex, slot.CreatureId, amount)
	return amount
end

sellFromPrompt = function(player: Player, plot: PlotRecord, nestIndex: number)
	if plot.Owner ~= player or not Config.Sell.Enabled then
		return
	end
	local model = NestService.GetVisual(plot.Index, nestIndex)
	if not model or not model.PrimaryPart then
		return
	end
	-- Prompts can be fired from anywhere by exploit tools.
	if not RemoteGuard.IsWithinReach(player, model.PrimaryPart.Position) then
		return
	end
	NestService.Sell(player, nestIndex)
end

--------------------------------------------------------------------------
-- Incubation
--------------------------------------------------------------------------

local function tickIncubation(dt: number)
	local due: { { owner: Player, nestIndex: number } } = {}
	for _, plot in ipairs(PlotService.GetPlots()) do
		local owner = plot.Owner
		local data = owner and DataService.Get(owner)
		if owner and data then
			local speed = BoostService.GetHatchSpeedMultiplier(owner)
			for nestIndex, slot in ipairs(data.Nests) do
				if slot ~= false and slot.Kind == "Egg" and not slot.Away then
					local hatchTime = NestService.GetHatchTime(slot.EggId)
					slot.Incubated = math.min(hatchTime, (slot.Incubated or 0) + speed * dt)
					local model = NestService.GetVisual(plot.Index, nestIndex)
					if model then
						updateEggAttributes(model, slot, speed)
					end
					if slot.Incubated >= hatchTime then
						table.insert(due, { owner = owner, nestIndex = nestIndex })
					end
				end
			end
		end
	end
	-- Hatch after the sweep so nothing changes under the loop.
	for _, entry in ipairs(due) do
		local ok, err = pcall(NestService.Hatch, entry.owner, entry.nestIndex)
		if not ok then
			warn(string.format("[SAC/Nest] hatching %s nest %d errored: %s", entry.owner.Name, entry.nestIndex, tostring(err)))
		end
	end
end

--------------------------------------------------------------------------
-- Rescue (Config.Economy): nobody can get stuck with nothing to do
--------------------------------------------------------------------------

local lastRescue: { [Player]: number } = {}

local function cheapestStarterEggPrice(): number
	local cheapest = math.huge
	for _, egg in pairs(Config.Eggs) do
		if egg.RequiredRebirths == 0 and egg.Price < cheapest then
			cheapest = egg.Price
		end
	end
	return cheapest
end

local function checkRescue()
	local economy = Config.Economy
	local cheapest = cheapestStarterEggPrice()
	for _, plot in ipairs(PlotService.GetPlots()) do
		local owner = plot.Owner
		local data = owner and DataService.Get(owner)
		if owner and data
			and data.Cash < cheapest
			and #data.PendingEggs == 0
			and owner:GetAttribute("Carrying") ~= true
			and NestService.CountUsed(owner) == 0
			and (lastRescue[owner] or -math.huge) + economy.RescueCooldown <= os.clock()
		then
			local nestIndex = NestService.PlaceEgg(owner, economy.RescueEggId, 0)
			if nestIndex then
				lastRescue[owner] = os.clock()
				Notifier.Send(owner, string.format("The woods left you a gift: a free %s in nest %d!",
					Config.Eggs[economy.RescueEggId].Name, nestIndex), "Success")
				log("rescued %s with a free %s", owner.Name, economy.RescueEggId)
			end
		end
	end
end

-- Players already told (this visit) that selling frees nests.
local sellHinted: { [Player]: boolean } = {}

--- Every usable nest holds a cryptid and they could afford an egg: remind
--- them (once per visit) that selling is how you make room.
local function checkSellHint()
	if not Config.Economy.SellHintEnabled or not Config.Sell.Enabled then
		return
	end
	local cheapest = cheapestStarterEggPrice()
	for _, plot in ipairs(PlotService.GetPlots()) do
		local owner = plot.Owner
		local data = owner and DataService.Get(owner)
		if owner and data and not sellHinted[owner] and data.Cash >= cheapest then
			local capacity = NestService.GetCapacity(owner)
			local allCreatures = capacity > 0
			for i = 1, capacity do
				local slot = data.Nests[i]
				if slot == false or slot.Kind ~= "Creature" then
					allCreatures = false
					break
				end
			end
			if allCreatures then
				sellHinted[owner] = true
				Notifier.Send(owner, "Your nests are full! Hold Sell on your weakest cryptid to make room for a better egg.", "Info")
			end
		end
	end
end

--------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------

function NestService.Start()
	runtimeFolder = Workspace:WaitForChild("Runtime") :: Folder

	PlotService.PlotClaimed:Connect(function(_player: Player, plot: PlotRecord)
		NestService.RenderPlot(plot)
	end)
	PlotService.PlotReleased:Connect(function(_player: Player, plot: PlotRecord)
		clearPlot(plot.Index)
	end)
	-- Plots claimed before this service started.
	for _, plot in ipairs(PlotService.GetPlots()) do
		if plot.Owner then
			NestService.RenderPlot(plot)
		end
	end

	task.spawn(function()
		local last = os.clock()
		while true do
			task.wait(Config.Incubation.TickInterval)
			local now = os.clock()
			local ok, err = pcall(tickIncubation, now - last)
			last = now
			if not ok then
				warn("[SAC/Nest] incubation tick errored: " .. tostring(err))
			end
		end
	end)

	assert(Config.Eggs[Config.Economy.RescueEggId], "Config.Economy.RescueEggId is not an egg")
	task.spawn(function()
		while true do
			task.wait(Config.Economy.RescueCheckInterval)
			if Config.Economy.RescueEnabled then
				local ok, err = pcall(checkRescue)
				if not ok then
					warn("[SAC/Nest] rescue check errored: " .. tostring(err))
				end
			end
			local ok, err = pcall(checkSellHint)
			if not ok then
				warn("[SAC/Nest] sell hint check errored: " .. tostring(err))
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastRescue[player] = nil
		sellHinted[player] = nil
	end)

	-- Optional boot-time odds check (Config.Debug.RunOddsSimulationOnStart).
	if Config.Debug.RunOddsSimulationOnStart then
		task.spawn(function()
			for _, eggId in ipairs(Config.EggOrder) do
				local report = EggRoller.SimulationReport(eggId, 0, Config.Debug.SimulationRolls)
				print(report)
			end
		end)
	end
end

return NestService
