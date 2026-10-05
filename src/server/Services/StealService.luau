--!strict
--[[
	StealService
	ServerScriptService/Server/Services/StealService

	The whole life of a stolen item:

	  steal   — non-owner holds the item's Steal prompt for Config.Prompts.
	            StealHold seconds on an unlocked, unprotected plot. The server
	            re-checks everything at the end of the hold, including that
	            the hold really lasted that long (exploit tools can fire a
	            prompt instantly).
	  carry   — the item rides above the thief's head; thief moves at
	            CarrySpeedMultiplier and can't lock their own camp.
	  drop    — thief dies or is hit by a Bat: the item lands where they
	            stood and anyone can pick it up (the owner picking it up
	            sends it straight home).
	  claim   — thief touches their own plot's pad with a free nest: the item
	            moves into their profile.
	  return  — UnclaimedReturnTime after the steal, if not claimed, the item
	            goes home.

	Eggs bought off the egg belt (EggBeltService) use the same carry, with
	Source = "Belt": held in the left hand, no return timer while held, no
	previous owner. A bat hit knocks one loose for anyone to grab (gone after
	Config.Belt.DroppedEggLifetime); reaching your pad places it in a nest
	(or PendingEggs if they filled up); leaving mid-carry saves it to
	PendingEggs, since it was paid for.

	Where the item lives while it's out (this is what keeps it dupe-safe):
	the OWNER's profile keeps the slot, marked Away. Nothing is added to the
	thief until the claim, and the claim removes it from the owner in the
	same step. If the server dies mid-carry, the owner's saved slot is still
	Away and ProfileTemplate sends it home on their next load. The thief's
	save never had it.

	Owner alerts go through the StealAlarm remote:
	  ("Started" | "Stopped" | "Stolen" | "Dropped" | "Claimed" | "Returned", info)
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
local ItemVisuals = require(Modules:WaitForChild("ItemVisuals"))
local ProfileTemplate = require(Modules:WaitForChild("ProfileTemplate"))
local RemoteGuard = require(Modules:WaitForChild("RemoteGuard"))
local Notifier = require(Modules:WaitForChild("Notifier"))
local DataService = require(Services:WaitForChild("DataService"))
local PlotService = require(Services:WaitForChild("PlotService"))
local NestService = require(Services:WaitForChild("NestService"))
local IncomeService = require(Services:WaitForChild("IncomeService"))
local MovementService = require(Services:WaitForChild("MovementService"))

type PlotRecord = PlotService.PlotRecord

export type Carry = {
	Id: number,
	Source: string,          -- "Steal" (from a nest) or "Belt" (bought off the egg belt)
	Owner: Player?,          -- nil once the owner has left (forfeited)
	OwnerUserId: number,
	OwnerName: string,
	NestIndex: number,
	Slot: any,               -- copy of the slot as it was when stolen
	ReturnAt: number,        -- os.clock()
	ReturnAtServer: number,  -- workspace:GetServerTimeNow(), for client countdowns
	Carrier: Player?,        -- nil while dropped
	Model: Model?,
}

local StealService = {}

--- (thief, carry) after a successful steal or pickup.
StealService.ItemTaken = Signal.new()
--- (thief, carry, nestIndex) after a claim.
StealService.Claimed = Signal.new()

local carries: { [number]: Carry } = {}
local carryByCarrier: { [Player]: Carry } = {}
local nextCarryId = 0

-- player -> prompt -> os.clock() the hold began; and whether we alarmed.
local holdStarts: { [Player]: { [ProximityPrompt]: number } } = {}
local holdAlarmed: { [Player]: { [ProximityPrompt]: boolean } } = {}
-- Throttle for repeated "can't steal" / "no nest" messages.
local lastNotice: { [Player]: number } = {}

local alarmRemote: RemoteEvent
local runtimeFolder: Folder

local function log(fmt: string, ...: any)
	if Config.Debug.Verbose then
		print(string.format("[SAC/Steal] " .. fmt, ...))
	end
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function throttledNotice(player: Player, text: string, kind: string?)
	local t = os.clock()
	if (lastNotice[player] or 0) + 2 > t then
		return
	end
	lastNotice[player] = t
	Notifier.Send(player, text, kind or "Error")
end

local function formatClock(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

--- "Rare Yeti", "Forest Egg (62% heat)", "???"
local function itemLabel(slot: any): string
	if slot.Kind == "Egg" then
		local egg = Config.Eggs[slot.EggId]
		if slot.Heat == nil then
			return egg and egg.Name or "Egg" -- fresh off the belt
		end
		return string.format("%s (%d%% heat)", egg and egg.Name or "Egg", math.floor(slot.Heat or 0))
	end
	local def = Config.CreaturesById[slot.CreatureId]
	local rarity = def and Config.Rarities[def.Rarity]
	if not def or not rarity then
		return "cryptid"
	end
	if rarity.NeverRenderClearly then
		return def.Name
	end
	return rarity.DisplayName .. " " .. def.Name
end

local function alarm(owner: Player?, phase: string, carry: Carry?, extra: { [string]: any }?)
	if not owner or owner.Parent ~= Players then
		return
	end
	local info: { [string]: any } = extra or {}
	if carry then
		info.Item = itemLabel(carry.Slot)
		info.NestIndex = carry.NestIndex
		info.ReturnAt = carry.ReturnAtServer
		info.Thief = if carry.Carrier then carry.Carrier.DisplayName else info.Thief
		info.CarryId = carry.Id
	end
	alarmRemote:FireClient(owner, phase, info)
end

--------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------

function StealService.GetCarry(player: Player): Carry?
	return carryByCarrier[player]
end

function StealService.IsCarrying(player: Player): boolean
	return carryByCarrier[player] ~= nil
end

--------------------------------------------------------------------------
-- Visuals for carried and dropped items
--------------------------------------------------------------------------

local function buildItemModel(carry: Carry): Model
	local slot = carry.Slot
	local model = if slot.Kind == "Egg"
		then ItemVisuals.BuildEgg(slot.EggId)
		else ItemVisuals.BuildCreature(slot.CreatureId, slot.Mutation)

	-- Keep huge cryptids carryable.
	local size = model:GetExtentsSize()
	local largest = math.max(size.X, size.Y, size.Z)
	if largest > Config.Steal.MaxCarrySize then
		model:ScaleTo(Config.Steal.MaxCarrySize / largest)
	end

	model:SetAttribute("Source", carry.Source)
	model:SetAttribute("Kind", slot.Kind)
	if slot.Kind == "Egg" then
		model:SetAttribute("EggId", slot.EggId)
		model:SetAttribute("Heat", slot.Heat)
	else
		model:SetAttribute("CreatureId", slot.CreatureId)
		model:SetAttribute("Rarity", slot.Rarity)
	end
	model:SetAttribute("ItemLabel", itemLabel(slot))
	model:SetAttribute("OwnerUserId", carry.OwnerUserId)
	model:SetAttribute("OwnerName", carry.OwnerName)
	if carry.ReturnAtServer < math.huge then
		model:SetAttribute("ReturnAt", carry.ReturnAtServer)
	end
	model:SetAttribute("CarryId", carry.Id)
	CollectionService:AddTag(model, Config.Tags.CarriedItem)
	return model
end

local function destroyModel(carry: Carry)
	if carry.Model then
		carry.Model:Destroy()
		carry.Model = nil
	end
end

--- Clears everything about the current carrier (speed, attribute, model).
local function releaseCarrier(carry: Carry)
	local carrier = carry.Carrier
	if carrier then
		if carryByCarrier[carrier] == carry then
			carryByCarrier[carrier] = nil
		end
		MovementService.SetModifier(carrier, "Carrying", nil)
		carrier:SetAttribute("Carrying", nil)
		carry.Carrier = nil
	end
	destroyModel(carry)
end

local function attachToCarrier(carry: Carry, player: Player): boolean
	local root = RemoteGuard.GetRoot(player)
	local character = player.Character
	if not root or not character then
		return false
	end

	-- Stolen items ride overhead; a bought egg is held in the left hand
	-- (the bat goes in the right).
	local anchor: BasePart = root
	if carry.Source == "Belt" then
		local hand = character:FindFirstChild("LeftHand") or character:FindFirstChild("Left Arm")
		if hand and hand:IsA("BasePart") then
			anchor = hand
		end
	end

	local model = buildItemModel(carry)
	model:SetAttribute("CarrierUserId", player.UserId)
	if carry.Source == "Belt" then
		model:ScaleTo(Config.Belt.CarryScale)
	end
	local primary = model.PrimaryPart :: BasePart
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.Massless = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			if part ~= primary then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = primary
				weld.Part1 = part
				weld.Parent = primary
			end
		end
	end
	if anchor == root then
		model:PivotTo(root.CFrame * CFrame.new(Config.Steal.CarryOffset))
	else
		-- Egg centred just below and in front of the palm.
		local height = model:GetExtentsSize().Y
		model:PivotTo(anchor.CFrame * CFrame.new(0, -0.45 - height / 2, -0.35))
	end
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = anchor
	weld.Part1 = primary
	weld.Parent = primary
	model.Name = "CarriedItem"
	model.Parent = character

	carry.Model = model
	carry.Carrier = player
	carryByCarrier[player] = carry
	MovementService.SetModifier(player, "Carrying",
		if carry.Source == "Belt" then Config.Belt.CarrySpeedMultiplier else Config.Steal.CarrySpeedMultiplier)
	player:SetAttribute("Carrying", true)
	return true
end

--------------------------------------------------------------------------
-- Ending a carry
--------------------------------------------------------------------------

local function forget(carry: Carry)
	carries[carry.Id] = nil
end

--- Sends the item back to its owner's nest.
local function returnHome(carry: Carry, reason: string)
	local carrier = carry.Carrier
	releaseCarrier(carry)
	forget(carry)

	if carry.Source == "Belt" then
		-- A bought egg has no home but its buyer's camp: once it's been
		-- lying loose too long, it's gone.
		log("belt egg carry %d vanished (%s)", carry.Id, reason)
		return
	end

	local owner = carry.Owner
	if owner and owner.Parent == Players then
		local immuneUntil = os.time() + Config.Steal.SameItemImmunity
		NestService.SetAway(owner, carry.NestIndex, false, nil, immuneUntil)
		Notifier.Send(owner, string.format("Your %s is home safe.", itemLabel(carry.Slot)), "Success")
		alarm(owner, "Returned", carry)
	end
	if carrier and carrier.Parent == Players then
		local text = if owner
			then string.format("The %s escaped back home.", itemLabel(carry.Slot))
			else string.format("The %s vanished into the woods.", itemLabel(carry.Slot))
		Notifier.Send(carrier, text, "Warning")
	end
	log("carry %d returned (%s)", carry.Id, reason)
end

--- Drops whatever `player` is carrying where they stand.
function StealService.Drop(player: Player, reason: string)
	local carry = carryByCarrier[player]
	if not carry then
		return
	end

	-- Where to put it: the ground under the carrier.
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local origin = if root then root.Position elseif carry.Model then carry.Model:GetPivot().Position else nil
	releaseCarrier(carry)

	if not origin then
		returnHome(carry, "dropped nowhere")
		return
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = { runtimeFolder }
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			table.insert(exclude, p.Character)
		end
	end
	params.FilterDescendantsInstances = exclude
	local hit = Workspace:Raycast(origin + Vector3.new(0, 2, 0), Vector3.new(0, -60, 0), params)
	if not hit then
		returnHome(carry, "dropped into the void")
		return
	end

	local model = buildItemModel(carry)
	model:SetAttribute("Dropped", true)
	model:PivotTo(CFrame.new(hit.Position))
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "PickupPrompt"
	prompt.ActionText = "Pick up"
	prompt.ObjectText = itemLabel(carry.Slot)
	prompt.HoldDuration = Config.Steal.PickupHold
	prompt.MaxActivationDistance = Config.Prompts.MaxActivationDistance
	prompt.RequiresLineOfSight = Config.Prompts.RequiresLineOfSight
	prompt.Parent = model.PrimaryPart

	local starts: { [Player]: number } = {}
	prompt.PromptButtonHoldBegan:Connect(function(picker)
		starts[picker] = os.clock()
	end)
	-- Same ordering caveat as steal prompts: forget an abandoned hold only
	-- after giving Triggered a moment to consume it, so an old hold can't be
	-- reused later for an instant pickup.
	prompt.PromptButtonHoldEnded:Connect(function(picker)
		local began = starts[picker]
		if not began then
			return
		end
		task.delay(0.2, function()
			if starts[picker] == began then
				starts[picker] = nil
			end
		end)
	end)
	prompt.Triggered:Connect(function(picker)
		local began = starts[picker]
		starts[picker] = nil
		StealService.TryPickup(picker, carry, began)
	end)

	model.Parent = runtimeFolder
	carry.Model = model

	if carry.Source == "Belt" then
		-- Loose eggs are anyone's, for a little while.
		carry.ReturnAt = os.clock() + Config.Belt.DroppedEggLifetime
		carry.ReturnAtServer = serverNow() + Config.Belt.DroppedEggLifetime
		model:SetAttribute("ReturnAt", carry.ReturnAtServer)
		Notifier.Send(player, string.format("You dropped the %s! Grab it before someone else does.", itemLabel(carry.Slot)), "Warning")
		log("belt egg carry %d dropped by %s (%s)", carry.Id, player.Name, reason)
		return
	end

	Notifier.Send(player, string.format("You dropped the %s!", itemLabel(carry.Slot)), "Warning")
	if carry.Owner then
		Notifier.Send(carry.Owner, string.format("Your %s was knocked loose — grab it back!", itemLabel(carry.Slot)), "Warning")
		alarm(carry.Owner, "Dropped", carry, { Thief = player.DisplayName })
	end
	log("carry %d dropped by %s (%s)", carry.Id, player.Name, reason)
end

--- A bought (or picked-up) belt egg reaches its carrier's pad.
local function claimBeltEgg(player: Player, carry: Carry)
	local eggId = carry.Slot.EggId
	releaseCarrier(carry)
	forget(carry)
	local nestIndex = NestService.PlaceEgg(player, eggId, 0)
	if nestIndex then
		Notifier.Send(player, string.format("%s is in nest %d. Let it heat up!", itemLabel(carry.Slot), nestIndex), "Success")
	else
		-- Nests filled up while it was being carried: it waits for the next
		-- free nest (MonetizationService places pending eggs).
		DataService.Mutate(player, function(d)
			table.insert(d.PendingEggs, eggId)
		end)
		Notifier.Send(player, string.format("Your nests are full — the %s goes in the next free one.", itemLabel(carry.Slot)), "Info")
	end
	log("%s brought belt egg carry %d (%s) home", player.Name, carry.Id, eggId)
	task.spawn(DataService.SaveNow, player)
	StealService.Claimed:Fire(player, carry, nestIndex or 0)
end

local function claim(player: Player, carry: Carry)
	if carry.Source == "Belt" then
		claimBeltEgg(player, carry)
		return
	end
	local nestIndex = NestService.FindEmptyNest(player)
	if not nestIndex then
		throttledNotice(player, "No empty nest! Hatch something or make room, quick.")
		return
	end

	-- Remove from the owner and add to the thief in one synchronous step.
	local owner = carry.Owner
	if owner and owner.Parent == Players then
		local current = NestService.GetSlot(owner, carry.NestIndex)
		if not current or not current.Away then
			-- The owner's copy isn't marked as out. Giving the thief one now
			-- would duplicate it, so refuse and send it home instead.
			warn(string.format("[SAC/Steal] Claim of carry %d refused: owner's slot is not Away", carry.Id))
			returnHome(carry, "owner slot mismatch")
			return
		end
		NestService.SetSlot(owner, carry.NestIndex, false)
		DataService.Mutate(owner, function(d)
			d.Stats.StealsSuffered = (d.Stats.StealsSuffered or 0) + 1
		end)
	end

	local slot = ProfileTemplate.DeepCopy(carry.Slot)
	slot.Away = nil
	slot.AwayThief = nil
	slot.Vault = 0
	slot.StolenFrom = carry.OwnerUserId
	slot.ImmuneUntil = os.time() + Config.Steal.SameItemImmunity
	slot.AcquiredAt = os.time()
	slot.LastIncomeAt = os.time()
	NestService.SetSlot(player, nestIndex, slot)
	DataService.Mutate(player, function(d)
		d.Stats.StealsCommitted = (d.Stats.StealsCommitted or 0) + 1
	end)

	RemoteGuard.Cooldowns.Start(player, "Steal", Config.Steal.StealCooldown)
	releaseCarrier(carry)
	forget(carry)

	Notifier.Send(player, string.format("Got away with the %s! It's in nest %d.", itemLabel(carry.Slot), nestIndex), "Success")
	if owner and owner.Parent == Players then
		alarm(owner, "Claimed", carry, { Thief = player.DisplayName })
		Notifier.Send(owner, string.format("%s got away with your %s.", player.DisplayName, itemLabel(carry.Slot)), "Error")
	end
	log("%s claimed carry %d (%s) into nest %d", player.Name, carry.Id, itemLabel(carry.Slot), nestIndex)

	-- Save the owner's loss first, then the thief's gain: if the server died
	-- between the two writes, the item would be lost rather than duplicated.
	task.spawn(function()
		if owner and owner.Parent == Players then
			DataService.SaveNow(owner)
		end
		if player.Parent == Players then
			DataService.SaveNow(player)
		end
	end)

	StealService.Claimed:Fire(player, carry, nestIndex)
end

--------------------------------------------------------------------------
-- Starting a steal
--------------------------------------------------------------------------

local function holdWasLongEnough(began: number?, required: number): boolean
	return began ~= nil and (os.clock() - began) >= required - Config.Steal.HoldTolerance
end

--- Every rule for "may this player steal this nest's item right now?".
--- Returns (true, slot) or (false, reason).
local function checkSteal(thief: Player, plot: PlotRecord, nestIndex: number): (boolean, any)
	local owner = plot.Owner
	if not owner or owner == thief then
		return false, nil
	end
	local slot = NestService.GetSlot(owner, nestIndex)
	if not slot or slot.Away then
		return false, "Nothing to steal there."
	end
	if PlotService.IsLocked(plot) then
		return false, "This camp is locked."
	end
	if PlotService.IsProtected(plot) then
		return false, string.format("%s just arrived — protected for %s.",
			owner.DisplayName, formatClock(PlotService.ProtectionRemaining(plot)))
	end
	if slot.ImmuneUntil and slot.ImmuneUntil > os.time() then
		return false, string.format("That was just stolen — it's guarded for %s.", formatClock(slot.ImmuneUntil - os.time()))
	end
	if carryByCarrier[thief] then
		return false, "You're already carrying something."
	end
	local cooldown = RemoteGuard.Cooldowns.Remaining(thief, "Steal")
	if cooldown > 0 then
		return false, string.format("Catch your breath — you can steal again in %ds.", math.ceil(cooldown))
	end
	if not PlotService.GetPlot(thief) then
		return false, "You need a camp first."
	end
	if not NestService.FindEmptyNest(thief) then
		return false, "You have no empty nest to bring it home to."
	end
	local model = NestService.GetVisual(plot.Index, nestIndex)
	if not model or not model.PrimaryPart or not RemoteGuard.IsWithinReach(thief, model.PrimaryPart.Position) then
		return false, nil
	end
	return true, slot
end

local function performSteal(thief: Player, plot: PlotRecord, nestIndex: number, slot: any)
	local owner = plot.Owner :: Player

	-- The owner keeps what the creature had already earned.
	if slot.Kind == "Creature" and Config.Steal.PayOwnerVaultOnSteal then
		IncomeService.Collect(owner, nestIndex)
	end

	nextCarryId += 1
	local carry: Carry = {
		Id = nextCarryId,
		Source = "Steal",
		Owner = owner,
		OwnerUserId = owner.UserId,
		OwnerName = owner.DisplayName,
		NestIndex = nestIndex,
		Slot = ProfileTemplate.DeepCopy(NestService.GetSlot(owner, nestIndex)),
		ReturnAt = os.clock() + Config.Steal.UnclaimedReturnTime,
		ReturnAtServer = serverNow() + Config.Steal.UnclaimedReturnTime,
		Carrier = nil,
		Model = nil,
	}

	if not attachToCarrier(carry, thief) then
		return -- thief has no living character; nothing changed yet
	end
	carries[carry.Id] = carry
	NestService.SetAway(owner, nestIndex, true, thief.UserId)
	PlotService.EndProtection(thief)

	Notifier.Send(thief, string.format("You grabbed the %s! Get it to your camp's pad — it runs home in %ds.",
		itemLabel(carry.Slot), Config.Steal.UnclaimedReturnTime), "Success")
	alarm(owner, "Stolen", carry)
	log("%s stole %s from %s (carry %d)", thief.Name, itemLabel(carry.Slot), owner.Name, carry.Id)

	StealService.ItemTaken:Fire(thief, carry)
end

local function wireStealPrompt(plot: PlotRecord, nestIndex: number, model: Model, slot: any)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "StealPrompt"
	prompt.ActionText = "Steal"
	prompt.ObjectText = itemLabel(slot)
	prompt.HoldDuration = Config.Prompts.StealHold
	prompt.MaxActivationDistance = Config.Prompts.MaxActivationDistance
	prompt.RequiresLineOfSight = Config.Prompts.RequiresLineOfSight
	prompt.Parent = model.PrimaryPart

	prompt.PromptButtonHoldBegan:Connect(function(thief: Player)
		local ok, reasonOrSlot = checkSteal(thief, plot, nestIndex)
		if not ok then
			if typeof(reasonOrSlot) == "string" then
				throttledNotice(thief, reasonOrSlot)
			end
			return
		end
		holdStarts[thief] = holdStarts[thief] or {}
		holdStarts[thief][prompt] = os.clock()
		holdAlarmed[thief] = holdAlarmed[thief] or {}
		holdAlarmed[thief][prompt] = true
		alarm(plot.Owner, "Started", nil, {
			Thief = thief.DisplayName,
			Item = itemLabel(reasonOrSlot),
			NestIndex = nestIndex,
		})
	end)

	-- When a hold COMPLETES, Roblox fires HoldEnded before Triggered. So
	-- HoldEnded can't mean "they let go" on its own: wait a moment, and only
	-- treat it as abandoned if Triggered didn't consume the hold meanwhile.
	prompt.PromptButtonHoldEnded:Connect(function(thief: Player)
		local starts = holdStarts[thief]
		local began = starts and starts[prompt]
		if not began then
			return
		end
		task.delay(0.2, function()
			local current = holdStarts[thief]
			if not current or current[prompt] ~= began then
				return -- consumed by Triggered, or a new hold started
			end
			current[prompt] = nil
			local alarmed = holdAlarmed[thief]
			if alarmed and alarmed[prompt] then
				alarmed[prompt] = nil
				alarm(plot.Owner, "Stopped", nil, { Thief = thief.DisplayName, NestIndex = nestIndex })
			end
		end)
	end)

	prompt.Triggered:Connect(function(thief: Player)
		local began = holdStarts[thief] and holdStarts[thief][prompt]
		if holdStarts[thief] then
			holdStarts[thief][prompt] = nil
		end
		if holdAlarmed[thief] then
			holdAlarmed[thief][prompt] = nil -- don't send "Stopped" after this
		end
		if began == nil then
			-- Either refused when the hold began (they were told why) or the
			-- prompt was fired without a hold at all. Nothing to do either way.
			return
		end
		if not holdWasLongEnough(began, Config.Prompts.StealHold) then
			warn(string.format("[SAC/Steal] Rejected %s: steal hold too short (possible exploit)", thief.Name))
			alarm(plot.Owner, "Stopped", nil, { Thief = thief.DisplayName, NestIndex = nestIndex })
			return
		end
		local ok, reasonOrSlot = checkSteal(thief, plot, nestIndex)
		if not ok then
			if typeof(reasonOrSlot) == "string" then
				throttledNotice(thief, reasonOrSlot)
			end
			alarm(plot.Owner, "Stopped", nil, { Thief = thief.DisplayName, NestIndex = nestIndex })
			return
		end
		performSteal(thief, plot, nestIndex, reasonOrSlot)
	end)
end

--------------------------------------------------------------------------
-- Picking up a dropped item
--------------------------------------------------------------------------

function StealService.TryPickup(player: Player, carry: Carry, began: number?)
	if carries[carry.Id] ~= carry or carry.Carrier ~= nil or not carry.Model then
		return
	end
	if began == nil then
		return
	end
	if not holdWasLongEnough(began, Config.Steal.PickupHold) then
		warn(string.format("[SAC/Steal] Rejected %s: pickup hold too short (possible exploit)", player.Name))
		return
	end
	local primary = carry.Model.PrimaryPart
	if not primary or not RemoteGuard.IsWithinReach(player, primary.Position) then
		return
	end

	if carry.Source == "Belt" then
		if carryByCarrier[player] then
			throttledNotice(player, "You're already carrying something.")
			return
		end
		if not PlotService.GetPlot(player) or not NestService.FindEmptyNest(player) then
			throttledNotice(player, "You have no empty nest to bring it home to.")
			return
		end
		destroyModel(carry)
		if not attachToCarrier(carry, player) then
			return
		end
		carry.ReturnAt = math.huge -- in someone's hand again: no timer
		carry.ReturnAtServer = math.huge
		Notifier.Send(player, string.format("You grabbed a %s! Take it to your camp's pad.", itemLabel(carry.Slot)), "Success")
		log("%s picked up belt egg carry %d", player.Name, carry.Id)
		StealService.ItemTaken:Fire(player, carry)
		return
	end

	-- The owner grabbing it back sends it straight home.
	if carry.Owner == player then
		returnHome(carry, "rescued by owner")
		return
	end

	if carryByCarrier[player] then
		throttledNotice(player, "You're already carrying something.")
		return
	end
	if not PlotService.GetPlot(player) or not NestService.FindEmptyNest(player) then
		throttledNotice(player, "You have no empty nest to bring it home to.")
		return
	end

	destroyModel(carry)
	if not attachToCarrier(carry, player) then
		return
	end
	PlotService.EndProtection(player)
	Notifier.Send(player, string.format("You picked up the %s! Get it to your pad.", itemLabel(carry.Slot)), "Success")
	alarm(carry.Owner, "Stolen", carry)
	log("%s picked up carry %d", player.Name, carry.Id)
	StealService.ItemTaken:Fire(player, carry)
end

--------------------------------------------------------------------------
-- Eggs bought off the belt
--------------------------------------------------------------------------

--- Puts a freshly bought belt egg in `player`'s hand. It becomes theirs
--- when they reach their pad (claimBeltEgg); a bat hit or death drops it
--- for anyone to grab. Returns false (nothing changed) if the player has
--- no living character — the caller refunds.
function StealService.CarryBought(player: Player, eggId: string): boolean
	if carryByCarrier[player] or not Config.Eggs[eggId] then
		return false
	end
	nextCarryId += 1
	local carry: Carry = {
		Id = nextCarryId,
		Source = "Belt",
		Owner = nil,
		OwnerUserId = 0,
		OwnerName = "",
		NestIndex = 0,
		Slot = { Kind = "Egg", EggId = eggId },
		ReturnAt = math.huge,
		ReturnAtServer = math.huge,
		Carrier = nil,
		Model = nil,
	}
	if not attachToCarrier(carry, player) then
		return false
	end
	carries[carry.Id] = carry
	log("%s bought a %s off the belt (carry %d)", player.Name, eggId, carry.Id)
	return true
end

--------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------

local function hookCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if humanoid then
		humanoid.Died:Connect(function()
			StealService.Drop(player, "died")
		end)
	end
end

function StealService.Start()
	alarmRemote = RemoteGuard.GetClientEvent("StealAlarm")
	runtimeFolder = Workspace:WaitForChild("Runtime") :: Folder

	-- Every item drawn in a nest gets a Steal prompt.
	NestService.ItemRendered:Connect(function(_owner: Player, plot: PlotRecord, nestIndex: number, model: Model, slot: any)
		wireStealPrompt(plot, nestIndex, model, slot)
	end)
	for _, plot in ipairs(PlotService.GetPlots()) do
		if plot.Owner then
			NestService.RenderPlot(plot) -- re-render so existing items get prompts
		end
	end

	-- Claim pads.
	for _, pad in ipairs(CollectionService:GetTagged(Config.Tags.PlotPad)) do
		if pad:IsA("BasePart") then
			pad.CanTouch = true
			pad.Touched:Connect(function(hit)
				local character = hit:FindFirstAncestorOfClass("Model")
				local player = character and Players:GetPlayerFromCharacter(character)
				local carry = player and carryByCarrier[player]
				if not player or not carry then
					return
				end
				local plot = PlotService.GetPlot(player)
				if not plot or plot.Index ~= pad:GetAttribute("PlotIndex") then
					return
				end
				if not RemoteGuard.IsWithinReach(player, pad.Position, 12) then
					return
				end
				claim(player, carry)
			end)
		end
	end

	-- You can't lock your own camp while carrying stolen goods. (A bought
	-- egg is fine.)
	PlotService.AddLockCheck(function(player: Player)
		local carry = carryByCarrier[player]
		if carry and carry.Source == "Steal" then
			return false, "You can't lock your camp while carrying a stolen item."
		end
		return true, nil
	end)

	-- Death and resets drop the item.
	local function hookPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			hookCharacter(player, character)
		end)
		player.CharacterRemoving:Connect(function()
			StealService.Drop(player, "character removed")
		end)
		if player.Character then
			task.spawn(hookCharacter, player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(hookPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		hookPlayer(player)
	end

	-- Owner leaving while their item is out: forfeit (or return), decided
	-- here because this hook can still write to the owner's profile.
	DataService.OnBeforeRelease(function(owner: Player, data: any)
		-- Leaving with an egg in hand: you paid for it, so it's saved for
		-- your next free nest.
		local held = carryByCarrier[owner]
		if held and held.Source == "Belt" then
			table.insert(data.PendingEggs, held.Slot.EggId)
			releaseCarrier(held)
			forget(held)
			log("%s left holding belt egg carry %d; saved as pending", owner.Name, held.Id)
		end

		for _, carry in pairs(carries) do
			if carry.Owner == owner then
				if Config.Steal.OwnerLeavingForfeits then
					data.Nests[carry.NestIndex] = false
					carry.Owner = nil
					if carry.Carrier then
						Notifier.Send(carry.Carrier, "The owner left — it's yours if you get it home!", "Success")
					end
					log("owner %s left; carry %d forfeited", owner.Name, carry.Id)
				else
					local slot = data.Nests[carry.NestIndex]
					if slot ~= false then
						slot.Away = nil
						slot.AwayThief = nil
					end
					releaseCarrier(carry)
					forget(carry)
				end
			end
		end
	end)

	-- Thief leaving: the item goes home.
	Players.PlayerRemoving:Connect(function(player)
		local carry = carryByCarrier[player]
		if carry and carry.Source == "Belt" then
			-- Normally OnBeforeRelease above already saved it; this covers
			-- the case where this handler runs first.
			local eggId = carry.Slot.EggId
			DataService.Mutate(player, function(d)
				table.insert(d.PendingEggs, eggId)
			end)
			releaseCarrier(carry)
			forget(carry)
		elseif carry then
			returnHome(carry, "carrier left")
		end
		holdStarts[player] = nil
		holdAlarmed[player] = nil
		lastNotice[player] = nil
	end)

	-- Return timer.
	task.spawn(function()
		while true do
			task.wait(0.25)
			local t = os.clock()
			for _, carry in pairs(carries) do
				if t >= carry.ReturnAt then
					local ok, err = pcall(returnHome, carry, "timed out")
					if not ok then
						warn("[SAC/Steal] return errored: " .. tostring(err))
						forget(carry)
					end
				end
			end
		end
	end)
end

--- Debug: a readable list of everything in transit.
function StealService.DebugState(): string
	local lines = {}
	for id, carry in pairs(carries) do
		table.insert(lines, string.format("carry %d: %s from %s nest %d, %s, returns in %.0fs",
			id, itemLabel(carry.Slot), if carry.Source == "Belt" then "the belt" else carry.OwnerName, carry.NestIndex,
			if carry.Carrier then ("carried by " .. carry.Carrier.Name) else "dropped",
			carry.ReturnAt - os.clock()))
	end
	return #lines > 0 and table.concat(lines, "\n") or "nothing in transit"
end

return StealService
