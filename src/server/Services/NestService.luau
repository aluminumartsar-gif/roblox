--!strict
--[[
	NestService
	ServerScriptService/Server/Services/NestService

	Owns what sits in each nest, and its model in the world.

	  * Source of truth is the owner's profile: data.Nests[i] is an egg slot,
	    a creature slot, or false. This service turns that into models in
	    Workspace.Runtime when a plot is claimed, and clears them on release.
	  * Heat: every Config.Heat.TickInterval, each egg gains heat at
	    (Max / SecondsToMax) * BoostService.GetHeatRateMultiplier(owner).
	    Written straight into the profile without a client push (it changes
	    every second); clients read it from the egg model's Heat attribute.
	  * Hatch: the egg's prompt, owner only. Rolls on the server with the
	    egg's current heat and the owner's luck, swaps the slot to a creature.

	Model attributes (read by the client's NestVisualsController):
	  all:      Kind ("Egg"|"Creature"), OwnerUserId, PlotIndex, NestIndex
	  egg:      EggId, Heat
	  creature: CreatureId, Rarity, Mutation, Vault, VaultCap, IncomePerSecond
	            (the income ones are kept up to date by IncomeService)

	Step 4 (stealing) moves items with TakeSlot / PutSlot.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Signal = require(Shared:WaitForChild("Util"):WaitForChild("Signal"))

local Server = ServerScriptService:WaitForChild("Server")
local Modules = Server:WaitForChild("Modules")
local Services = Server:WaitForChild("Services")
local EggRoller = require(Modules:WaitForChild("EggRoller"))
local ItemVisuals = require(Modules:WaitForChild("ItemVisuals"))
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

-- plotIndex -> nestIndex -> model
local visuals: { [number]: { [number]: Model } } = {}

local runtimeFolder: Folder

local function log(fmt: string, ...: any)
	if Config.Debug.Verbose then
		print(string.format("[SAC/Nest] " .. fmt, ...))
	end
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

local function newEggSlot(eggId: string, heat: number): any
	local now = os.time()
	return { Kind = "Egg", EggId = eggId, Heat = heat, Vault = 0, AcquiredAt = now, LastIncomeAt = now }
end

local function newCreatureSlot(result: EggRoller.HatchResult): any
	local now = os.time()
	return {
		Kind = "Creature",
		CreatureId = result.CreatureId,
		Rarity = result.Rarity,
		Mutation = result.Mutation,
		Heat = 0,
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

local function addHatchPrompt(model: Model, eggName: string)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "HatchPrompt"
	prompt.ActionText = "Hatch"
	prompt.ObjectText = eggName
	prompt.HoldDuration = Config.Prompts.HatchHold
	prompt.MaxActivationDistance = Config.Prompts.MaxActivationDistance
	prompt.RequiresLineOfSight = Config.Prompts.RequiresLineOfSight
	prompt.Parent = model.PrimaryPart
	return prompt
end

local hatchFromPrompt: (Player, PlotRecord, number) -> ()

--- Rebuilds the model for one nest from the owner's profile.
function NestService.RenderNest(plot: PlotRecord, nestIndex: number)
	clearVisual(plot.Index, nestIndex)
	local owner = plot.Owner
	if not owner then
		return
	end
	local slot = NestService.GetSlot(owner, nestIndex)
	if not slot or slot.Away then
		-- Away = being carried by a thief; StealService draws it overhead.
		return
	end

	local model: Model
	if slot.Kind == "Egg" then
		model = ItemVisuals.BuildEgg(slot.EggId)
		model:SetAttribute("EggId", slot.EggId)
		model:SetAttribute("Heat", math.floor(slot.Heat * 10) / 10)
		CollectionService:AddTag(model, Config.Tags.Egg)
		local prompt = addHatchPrompt(model, Config.Eggs[slot.EggId].Name)
		prompt.Triggered:Connect(function(player)
			hatchFromPrompt(player, plot, nestIndex)
		end)
	else
		model = ItemVisuals.BuildCreature(slot.CreatureId, slot.Mutation)
		model:SetAttribute("CreatureId", slot.CreatureId)
		model:SetAttribute("Rarity", slot.Rarity)
		if slot.Mutation then
			model:SetAttribute("Mutation", slot.Mutation)
		end
		model:SetAttribute("Vault", math.floor(slot.Vault))
		model:SetAttribute("VaultCap", BoostService.GetVaultCap(owner))
		model:SetAttribute("IncomePerSecond", BoostService.GetCreatureIncome(owner, slot))
		CollectionService:AddTag(model, Config.Tags.Creature)
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

--- Puts a slot (or false) into a nest, saves, pushes, and redraws.
function NestService.SetSlot(player: Player, nestIndex: number, slot: any)
	DataService.Mutate(player, function(data)
		data.Nests[nestIndex] = if slot == nil then false else slot
	end)
	local plot = PlotService.GetPlot(player)
	if plot then
		NestService.RenderNest(plot, nestIndex)
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

--- Removes and returns a nest's slot (Step 4: stealing). nil if empty.
function NestService.TakeSlot(player: Player, nestIndex: number): any
	local slot = NestService.GetSlot(player, nestIndex)
	if slot then
		NestService.SetSlot(player, nestIndex, false)
	end
	return slot
end

--- Places a new egg in the first free nest. Returns the nest index, or nil
--- if there's no room. Does NOT charge — the caller handles payment.
function NestService.PlaceEgg(player: Player, eggId: string, heat: number?): number?
	assert(Config.Eggs[eggId], "Unknown egg " .. tostring(eggId))
	local nestIndex = NestService.FindEmptyNest(player)
	if not nestIndex then
		return nil
	end
	NestService.SetSlot(player, nestIndex, newEggSlot(eggId, heat or 0))
	return nestIndex
end

--------------------------------------------------------------------------
-- Hatching
--------------------------------------------------------------------------

local function announce(text: string, rarity: string)
	RemoteGuard.GetClientEvent("GlobalAnnounce"):FireAllClients(text, rarity)
end

--- Hatches the egg in `nestIndex`. Returns the result, or nil if there was
--- no egg there. All checks (ownership, distance) are the caller's job.
function NestService.Hatch(player: Player, nestIndex: number): EggRoller.HatchResult?
	local slot = NestService.GetSlot(player, nestIndex)
	if not slot or slot.Kind ~= "Egg" or slot.Away then
		return nil
	end

	local heat = slot.Heat
	local luck = BoostService.GetLuckPercent(player)
	local result = EggRoller.Hatch(slot.EggId, heat, luck)

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

	local def = Config.CreaturesById[result.CreatureId]
	local rarity = Config.Rarities[result.Rarity]
	log("%s hatched %s (%s) from %s at heat %.0f, luck %d%%",
		player.Name, def.Name, result.Rarity, slot.EggId, heat, luck)

	Notifier.Send(player, string.format("You hatched %s %s! (heat %d%%)",
		rarity.DisplayName, def.Name, math.floor(heat)), "Success")

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

hatchFromPrompt = function(player: Player, plot: PlotRecord, nestIndex: number)
	if plot.Owner ~= player then
		return -- Step 4 gives non-owners a steal prompt instead
	end
	local model = NestService.GetVisual(plot.Index, nestIndex)
	if not model or not model.PrimaryPart then
		return
	end
	-- Prompts can be fired from anywhere by exploit tools.
	if not RemoteGuard.IsWithinReach(player, model.PrimaryPart.Position) then
		return
	end
	NestService.Hatch(player, nestIndex)
end

--------------------------------------------------------------------------
-- Heat
--------------------------------------------------------------------------

local function tickHeat(dt: number)
	local h = Config.Heat
	local baseRate = h.Max / h.SecondsToMax
	for _, plot in ipairs(PlotService.GetPlots()) do
		local owner = plot.Owner
		local data = owner and DataService.Get(owner)
		if owner and data then
			local rate = baseRate * BoostService.GetHeatRateMultiplier(owner)
			for nestIndex, slot in ipairs(data.Nests) do
				if slot ~= false and slot.Kind == "Egg" and not slot.Away and slot.Heat < h.Max then
					slot.Heat = math.min(h.Max, slot.Heat + rate * dt)
					local model = NestService.GetVisual(plot.Index, nestIndex)
					if model then
						model:SetAttribute("Heat", math.floor(slot.Heat * 10) / 10)
					end
				end
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
			task.wait(Config.Heat.TickInterval)
			local now = os.clock()
			local ok, err = pcall(tickHeat, now - last)
			last = now
			if not ok then
				warn("[SAC/Nest] heat tick errored: " .. tostring(err))
			end
		end
	end)

	-- Optional boot-time odds check (Config.Debug.RunOddsSimulationOnStart).
	if Config.Debug.RunOddsSimulationOnStart then
		task.spawn(function()
			for _, eggId in ipairs(Config.EggOrder) do
				for _, heat in ipairs({ 0, Config.Heat.Max }) do
					local report = EggRoller.SimulationReport(eggId, heat, 0, Config.Debug.SimulationRolls)
					print(report)
				end
			end
		end)
	end
end

return NestService
