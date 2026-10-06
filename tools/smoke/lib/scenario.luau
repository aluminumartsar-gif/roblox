--!nocheck
-- The scripted play session. Each step sets Report.step so findings say
-- when they happened. Virtual time only: a full run is a few seconds real.

local roblox = require("@lune/roblox")
local Classes = require("./classes")
local Inst = require("./inst")
local Loader = require("./loader")
local Report = require("./report")
local Sched = require("./sched")
local Services = require("./services")
local Signal = require("./signal")
local Util = require("./util")
local World = require("./world")

local S = Inst.S
local get = Inst.get

local Vector3 = roblox.Vector3
local Vector2 = roblox.Vector2
local CFrame = roblox.CFrame
local Enum = roblox.Enum

local Scenario = {}

Scenario.options = {
	waitAbort = 5, -- seconds before an infinite WaitForChild is aborted (0 = never)
	maxClicksPerScreen = 120,
}

local function step(name: string)
	Report.step = name
end

local function advance(seconds: number)
	Sched.advance(seconds)
end

local function playerGui()
	return Inst.findChild(S[World.player], "PlayerGui")
end

local function svc(name)
	return Services.byClass[name]
end

--------------------------------------------------------------------------
-- WaitForChild watchdog
--------------------------------------------------------------------------

local warnedInfinite = {}

function Scenario.checkWaits()
	local now = Sched.now
	local abortAfter = Scenario.options.waitAbort
	for _, w in Inst.pendingWaits do
		if w.done or w.timeout then
			continue
		end
		local waited = now - w.start
		if waited >= 5 and not warnedInfinite[w] then
			warnedInfinite[w] = true
			if abortAfter <= 0 then
				Report.add(
					"WARN",
					"Infinite-yield risks",
					string.format("Infinite yield possible on '%s:WaitForChild(\"%s\")'", Inst.fullName(w.parent), w.name),
					w.location
				)
			end
		end
		if abortAfter > 0 and waited >= abortAfter then
			w.done = true
			Report.add(
				"FAIL",
				"WaitForChild never resolved",
				string.format(
					"WaitForChild never resolved: %s (no timeout: in Roblox this thread waits forever; the harness aborted it after %ss so the run could go on)",
					w.path,
					tostring(abortAfter)
				),
				w.location
			)
			Sched.resume(w.co, nil, "[smoke-abort] WaitForChild never resolved: " .. w.path)
		end
	end
	local live = {}
	for _, w in Inst.pendingWaits do
		if not w.done then
			table.insert(live, w)
		end
	end
	Inst.pendingWaits = live
end

--------------------------------------------------------------------------
-- UI helpers
--------------------------------------------------------------------------

--- Visible on screen: every GuiObject up the chain Visible, the
--- LayerCollector Enabled and in PlayerGui.
local function isShown(inst): boolean
	local pg = playerGui()
	local cur = inst
	while cur do
		local st = S[cur]
		if st.destroyed then
			return false
		end
		local rec = st.info.rec
		if rec.isA.GuiObject then
			if not get(cur, "Visible") then
				return false
			end
		elseif rec.isA.LayerCollector then
			if not get(cur, "Enabled") then
				return false
			end
			return Inst.isDescendantOf(cur, pg)
		end
		cur = st.parent
	end
	return false
end
Scenario.isShown = isShown

local function layerOf(inst)
	local cur = inst
	while cur do
		if S[cur].info.rec.isA.LayerCollector then
			return cur
		end
		cur = S[cur].parent
	end
	return nil
end

local function pathIn(inst, root)
	local parts = {}
	local cur = inst
	while cur and cur ~= root do
		local name = S[cur].name
		-- Same-named siblings get #n so they count as different buttons.
		local parent = S[cur].parent
		if parent then
			local n, mine, total = 0, 0, 0
			for _, sib in S[parent].children do
				if S[sib].name == name then
					n += 1
					total += 1
					if sib == cur then
						mine = n
					end
				end
			end
			if total > 1 then
				name ..= "#" .. mine
			end
		end
		table.insert(parts, 1, name)
		cur = parent
	end
	return table.concat(parts, ".")
end

local function inputObject(touch: boolean, state, position: Vector2)
	local io = Inst.create("InputObject")
	local st = S[io]
	st.props.UserInputType = if touch then Enum.UserInputType.Touch else Enum.UserInputType.MouseButton1
	st.props.UserInputState = state
	st.props.KeyCode = Enum.KeyCode.Unknown
	st.props.Position = Vector3.new(position.X, position.Y, 0)
	st.props.Delta = Vector3.zero
	return io
end

local CLOSE_WORDS = { "close", "back", "skip", "cancel", "exit", "x" }

local function closeLike(inst): boolean
	local name = string.lower(S[inst].name)
	for _, w in CLOSE_WORDS do
		if name == w or string.find(name, w, 1, true) and #w > 1 then
			return true
		end
	end
	return false
end

local clickedCount = 0

local function click(button)
	local touch = Services.profile.touch
	local x, y, w, h = Classes.absRect(button)
	local pos = Vector2.new(x + w / 2, y + h / 2)
	local layer = layerOf(button)
	local guiName = if layer then S[layer].name else "?"
	local stats = Report.stats.clicked
	stats[guiName] = stats[guiName] or {}
	local path = pathIn(button, layer)
	stats[guiName][path] = (stats[guiName][path] or 0) + 1
	clickedCount += 1

	local began = inputObject(touch, Enum.UserInputState.Begin, pos)
	local ended = inputObject(touch, Enum.UserInputState.End, pos)
	if not touch then
		Inst.fire(button, "MouseEnter", pos.X, pos.Y)
	end
	Inst.fire(button, "InputBegan", began)
	if touch then
		Inst.fire(button, "TouchTap", { pos })
	end
	Inst.fire(button, "MouseButton1Down", pos.X, pos.Y)
	Inst.fire(button, "InputEnded", ended)
	Inst.fire(button, "MouseButton1Up", pos.X, pos.Y)
	Inst.fire(button, "MouseButton1Click")
	Inst.fire(button, "Activated", ended, 1)
	if not touch then
		Inst.fire(button, "MouseLeave", pos.X, pos.Y)
	end
	Sched.drain()
	advance(0.15)
end

--- Clicks every visible, active button under PlayerGui (new ones that
--- appear after a click get their turn in the next round).
local function clickAll(label: string)
	local done = {}
	local total = 0
	for _ = 1, 8 do
		local list = {}
		for _, d in Inst.descendants(playerGui()) do
			local st = S[d]
			if st.info.rec.isA.GuiButton then
				local layer = layerOf(d)
				local guiName = if layer then S[layer].name else "?"
				local found = Report.stats.buttonsFound
				found[guiName] = found[guiName] or {}
				found[guiName][pathIn(d, layer)] = true
				if not done[d] and isShown(d) and get(d, "Active") ~= false and get(d, "Interactable") ~= false then
					table.insert(list, d)
				end
			end
		end
		if #list == 0 then
			break
		end
		table.sort(list, function(a, b)
			local ca, cb = closeLike(a), closeLike(b)
			if ca ~= cb then
				return cb
			end
			return S[a].id < S[b].id
		end)
		for _, b in list do
			if total >= Scenario.options.maxClicksPerScreen then
				return total
			end
			done[b] = true
			if isShown(b) then
				click(b)
				total += 1
			end
		end
	end
	return total
end

local function focusTextBoxes()
	for _, d in Inst.descendants(playerGui()) do
		if S[d].className == "TextBox" and isShown(d) then
			Classes.focusedBox = function()
				return d
			end
			Inst.fire(d, "Focused")
			Inst.setRaw(d, S[d], "Text", "smoke test")
			Inst.fire(d, "FocusLost", true, inputObject(false, Enum.UserInputState.End, Vector2.zero))
			Classes.focusedBox = function()
				return nil
			end
			advance(0.1)
		end
	end
end

--------------------------------------------------------------------------
-- ScreenGui bookkeeping
--------------------------------------------------------------------------

Inst.Behaviors.LayerCollector = {
	parentChanged = function(proxy, st, old, new)
		if new and S[new].className == "PlayerGui" then
			local guis = Report.stats.screenGuis
			local key = st.name
			guis[key] = guis[key] or {
				class = st.className,
				createdAt = st.createdAt,
				count = 0,
			}
			guis[key].count += 1
		end
	end,
}

local function recordScreenGuiState()
	for _, gui in S[playerGui()].children do
		local st = S[gui]
		local entry = Report.stats.screenGuis[st.name]
		if entry and st.info.rec.isA.LayerCollector then
			if st.info.rec.props.DisplayOrder then
				entry.displayOrder = get(gui, "DisplayOrder")
			end
			entry.resetOnSpawn = get(gui, "ResetOnSpawn")
			entry.enabled = get(gui, "Enabled")
		end
	end
end

--------------------------------------------------------------------------
-- Prompts
--------------------------------------------------------------------------

local function simulatePrompt(prompt)
	local pps = svc("ProximityPromptService")
	local player = World.player
	local inputType = if Services.profile.touch then Enum.ProximityPromptInputType.Touch else Enum.ProximityPromptInputType.Keyboard
	Inst.fire(pps, "PromptShown", prompt, inputType)
	Inst.fire(prompt, "PromptShown", inputType)
	advance(0.3)
	local hold = get(prompt, "HoldDuration")
	if hold > 0 then
		Inst.fire(pps, "PromptButtonHoldBegan", prompt, player)
		Inst.fire(prompt, "PromptButtonHoldBegan", player)
		advance(hold)
		-- Roblox fires HoldEnded before Triggered when a hold completes.
		Inst.fire(pps, "PromptButtonHoldEnded", prompt, player)
		Inst.fire(prompt, "PromptButtonHoldEnded", player)
	end
	Inst.fire(pps, "PromptTriggered", prompt, player)
	Inst.fire(prompt, "Triggered", player)
	advance(0.2)
	Inst.fire(pps, "PromptTriggerEnded", prompt, player)
	Inst.fire(prompt, "TriggerEnded", player)
	advance(0.5)
	Inst.fire(pps, "PromptHidden", prompt)
	Inst.fire(prompt, "PromptHidden")
	advance(0.2)
end

--------------------------------------------------------------------------
-- The steps
--------------------------------------------------------------------------

local sendInput -- defined below

local function stepStart(clientRealm, client)
	step("1 start")
	local main = Inst.findChild(S[client], "Main")
	for _, d in Inst.descendants(client) do
		if S[d].className == "LocalScript" and get(d, "Enabled") ~= false then
			Loader.runScript(clientRealm, d)
		end
	end
	if not main then
		Report.add("FAIL", "Main start failures", "No LocalScript called Main in the Client folder", nil)
	end
	advance(0.5)
	World.claimPlot()
	advance(4.5)
	World.retention.startedAt = Sched.now
	World.pushProfile()
	World.pushRetention()
	advance(3)
end

local function hatch(nestIndex: number, creatureId: string, eggId: string)
	local Config = World.Config
	local def = Config.CreaturesById[creatureId]
	local data = World.data
	data.Nests[nestIndex] = { Kind = "Creature", CreatureId = creatureId, Rarity = def.Rarity, Vault = 0, AcquiredAt = math.floor(World.serverNow()), LastIncomeAt = math.floor(World.serverNow()) }
	data.Stats.Hatches += 1
	data.Stats.HatchesByRarity[def.Rarity] = (data.Stats.HatchesByRarity[def.Rarity] or 0) + 1
	local wasNew = not data.Codex[creatureId]
	data.Codex[creatureId] = true
	local model = World.placeCreature(1, nestIndex, 1, creatureId, 0)
	local position = World.itemCFrame(1, nestIndex).Position
	World.fire("HatchResult", creatureId, def.Rarity, nil, eggId, position)
	if Config.GetRarityIndex(def.Rarity) >= Config.Feedback.BigRarityIndex then
		World.fire("FeedbackCue", "HatchBurst", { Position = position, Rarity = def.Rarity, UserId = 1 })
	end
	World.pushProfile()
	if wasNew then
		World.fire("CodexDiscovered", creatureId, { IsNew = true, PageCompleted = nil, Source = "Hatch" })
		World.notify(string.format("New Codex entry: %s!", def.Name), "Success")
	end
	return model
end

local function stepServerEvents()
	local Config = World.Config
	local now = World.serverNow

	step("2a toasts")
	World.notify("Welcome back to camp!", "Info")
	advance(0.5)
	World.notify("Bought a Forest Egg!", "Success")
	advance(0.5)
	World.notify("That camp is locked.", "Warning")
	advance(0.5)
	World.notify("Not enough cash (need $600).", "Error")
	advance(0.5)
	World.fire("GlobalAnnounce", "Player2 hatched a Mythic The Static!", "Mythic")
	advance(0.5)
	World.fire("GlobalAnnounce", "The wheel paid out big!", "Legendary")
	World.fire("GlobalAnnounce", "Server message with no rarity")
	advance(5)

	step("2b cash and cues")
	local creaturePos = World.itemCFrame(1, 2).Position
	World.moveCharacter(creaturePos + Vector3.new(0, 3, -6))
	World.fire("CashCollected", 250, creaturePos + Vector3.new(0, 3, 0))
	advance(0.3)
	World.fire("CashCollected", 25000, creaturePos + Vector3.new(0, 3, 0))
	advance(0.3)
	World.fire("FeedbackCue", "BatHit", { Position = creaturePos + Vector3.new(4, 2, 0) })
	World.fire("FeedbackCue", "HatchBurst", { Position = World.itemCFrame(2, 3).Position, Rarity = "Legendary", UserId = 2 })
	World.fire("FeedbackCue", "Bought", {})
	World.fire("FeedbackCue", "Taken", { Stolen = true })
	World.fire("FeedbackCue", "Claimed", { Stolen = false })
	advance(2)

	step("2c hatch reveal")
	hatch(1, "jackalope", "forest")
	advance(6)
	hatch(3, "nessie", "swamp")
	advance(0.4)
	hatch(4, "redacted", "void")
	advance(14)
	-- Incubation/vault ticks on the models (NestService / IncomeService)
	World.placeEgg(1, 5, 1, "mountain", 0.5)
	local egg = World.items["1:5"]
	for i = 1, 6 do
		Inst.setAttribute(egg, "Progress", math.min(1, 0.5 + i * 0.08))
		Inst.setAttribute(egg, "Remaining", math.max(0, 45 - i * 8))
		local creature = World.items["1:2"]
		Inst.setAttribute(creature, "Vault", 1200 + i * 4000)
		advance(1)
	end

	step("2d codex")
	World.data.Codex.bigfoot = true
	World.fire("CodexDiscovered", "bigfoot", { IsNew = true, PageCompleted = nil, Source = "Photo" })
	advance(4)
	World.data.Codex.gremlin = true
	World.fire("CodexDiscovered", "gremlin", { IsNew = true, PageCompleted = "Common", Source = "Photo" })
	World.fire("GlobalAnnounce", "Player1 completed the Common page of their Codex! (+5% luck forever)", "Common")
	World.pushProfile()
	advance(8)

	step("2e sighting")
	local home = World.rootPosition()
	local spot = home + Vector3.new(90, 0, 0)
	local startedAt = now()
	World.wildCryptid("yeti", spot, 1, startedAt + Config.Sightings.Duration)
	local started = {
		SightingId = 1,
		CreatureId = "yeti",
		Name = "Yeti",
		Label = "Yeti",
		Rarity = "Rare",
		Hint = "Deep in the north woods",
		Position = spot,
		StartedAt = startedAt,
		ExpiresAt = startedAt + Config.Sightings.Duration,
	}
	World.fire("SightingBanner", "Started", started)
	World.notify("A wild Yeti was spotted! Deep in the north woods.", "Info")
	advance(3)
	World.moveCharacter(spot + Vector3.new(0, 3, 20))
	advance(3)
	World.fire("SightingBanner", "Interrupted", { SightingId = 1, By = "Player2" })
	advance(1)
	-- Player2 catches it.
	for _, m in Inst.getTagged(Config.Tags.WildCryptid) do
		Inst.destroy(m)
	end
	local carryModel = World.carryModel({ creatureId = "yeti", source = "Sighting", label = "Yeti", carrierId = 2, carryId = 501 })
	World.fire("SightingBanner", "Captured", {
		SightingId = 1, CarryId = 501, CreatureId = "yeti", Name = "Yeti", Label = "Yeti", Rarity = "Rare", By = "Player2", ByUserId = 2,
	})
	advance(2)
	Inst.destroy(carryModel)
	local dropAt = spot + Vector3.new(5, 0, 5)
	World.carryModel({ creatureId = "yeti", source = "Sighting", label = "Yeti", dropped = true, carryId = 501, position = dropAt })
	World.fire("SightingBanner", "Dropped", {
		CarryId = 501, CreatureId = "yeti", Name = "Yeti", Label = "Yeti", Rarity = "Rare", By = "Player2", ByUserId = 2,
		Position = dropAt, ExpiresAt = now() + Config.Sightings.DroppedLifetime,
	})
	advance(2)
	for _, m in Inst.getTagged(Config.Tags.CarriedItem) do
		Inst.destroy(m)
	end
	Inst.setAttribute(World.player, "Carrying", true)
	local mine = World.carryModel({ creatureId = "yeti", source = "Sighting", label = "Yeti", carrierId = 1, carryId = 501 })
	World.fire("SightingBanner", "PickedUp", {
		CarryId = 501, CreatureId = "yeti", Name = "Yeti", Label = "Yeti", Rarity = "Rare", By = "Player1", ByUserId = 1,
	})
	advance(3)
	Inst.destroy(mine)
	Inst.setAttribute(World.player, "Carrying", false)
	World.data.Nests[6] = { Kind = "Creature", CreatureId = "yeti", Rarity = "Rare", Vault = 0, AcquiredAt = math.floor(now()), LastIncomeAt = math.floor(now()) }
	World.placeCreature(1, 6, 1, "yeti", 0)
	World.fire("SightingBanner", "Claimed", {
		CarryId = 501, CreatureId = "yeti", Name = "Yeti", Label = "Yeti", Rarity = "Rare", By = "Player1", ByUserId = 1,
	})
	World.fire("FeedbackCue", "Claimed", { Stolen = false })
	World.pushProfile()
	advance(3)
	-- A second sighting that gets away.
	local s2 = now()
	World.wildCryptid("mothman", spot, 2, s2 + Config.Sightings.Duration)
	World.fire("SightingBanner", "Started", {
		SightingId = 2, CreatureId = "mothman", Name = "Mothman", Label = "Mothman", Rarity = "Epic",
		Hint = "Near the old totem", Position = spot, StartedAt = s2, ExpiresAt = s2 + Config.Sightings.Duration,
	})
	advance(3)
	for _, m in Inst.getTagged(Config.Tags.WildCryptid) do
		Inst.destroy(m)
	end
	World.fire("SightingBanner", "Escaped", { SightingId = 2, Name = "Mothman", Label = "Mothman", Rarity = "Epic" })
	World.fire("GlobalAnnounce", "The Mothman slipped back into the woods. Keep your eyes open...", "Epic")
	advance(6)

	step("2f hunt")
	World.moveCharacter(home + Vector3.new(0, 3, 0))
	local hs = World.huntState
	local startsAt = now() + Config.Hunt.WarningTime
	local nestPos = home + Vector3.new(160, 0, 0)
	Inst.setAttribute(hs, "Phase", "Warning")
	Inst.setAttribute(hs, "StartsAt", startsAt)
	Inst.setAttribute(hs, "EndsAt", startsAt + Config.Hunt.Duration)
	Inst.setAttribute(hs, "Position", nestPos)
	World.fire("HuntEvent", "Warning", { StartsAt = startsAt, Position = nestPos })
	advance(4)
	local endsAt = now() + Config.Hunt.Duration
	Inst.setAttribute(hs, "Phase", "Hunting")
	Inst.setAttribute(hs, "EndsAt", endsAt)
	Inst.setAttribute(hs, "TargetUserId", 1)
	World.fire("HuntEvent", "Started", { EndsAt = endsAt })
	Inst.setAttribute(World.player, "Carrying", true)
	for i = 1, 25 do
		local alpha = i / 25
		local pos = nestPos:Lerp(World.rootPosition() + Vector3.new(4, -3, 0), alpha)
		Inst.setAttribute(hs, "Position", pos)
		Inst.setAttribute(hs, "Yaw", alpha * math.pi)
		advance(0.2)
	end
	World.fire("HuntEvent", "Caught", { UserId = 2, Name = "Player2", Item = "Rare Yeti", Position = home + Vector3.new(30, 0, 0) })
	advance(1)
	Inst.setAttribute(World.player, "Carrying", false)
	World.fire("HuntEvent", "Caught", { UserId = 1, Name = "Player1", Item = nil, Position = World.rootPosition() })
	World.notify(Config.Hunt.Name .. " caught you! Stay near the fire or inside a camp.", "Error")
	advance(3)
	Inst.setAttribute(hs, "Phase", "Leaving")
	Inst.setAttribute(hs, "TargetUserId", 0)
	advance(2)
	Inst.setAttribute(hs, "Phase", "Idle")
	World.fire("HuntEvent", "Ended", { Caught = 2 })
	advance(3)

	step("2g steal alarm")
	World.fire("StealAlarm", "Started", { Thief = "Player2", Item = "Common Jackalope", NestIndex = 1 })
	advance(2)
	World.fire("StealAlarm", "Stopped", { Thief = "Player2", NestIndex = 1 })
	advance(1)
	World.fire("StealAlarm", "Started", { Thief = "Player2", Item = "Forest Egg", NestIndex = 5 })
	advance(2)
	local returnAt = now() + Config.Steal.UnclaimedReturnTime
	World.data.Nests[5] = { Kind = "Egg", EggId = "mountain", Incubated = 40, Vault = 0, Away = true, AwayThief = 2, AcquiredAt = 0, LastIncomeAt = 0 }
	World.removeItem(1, 5)
	local stolen = World.carryModel({ eggId = "mountain", source = "Steal", label = "Mountain Egg", carrierId = 2, ownerId = 1, ownerName = "Player1", returnAt = returnAt, carryId = 601 })
	World.fire("StealAlarm", "Stolen", { Item = "Mountain Egg", NestIndex = 5, ReturnAt = returnAt, Thief = "Player2", CarryId = 601 })
	advance(3)
	Inst.destroy(stolen)
	World.carryModel({ eggId = "mountain", source = "Steal", label = "Mountain Egg", dropped = true, ownerId = 1, ownerName = "Player1", returnAt = returnAt, carryId = 601, position = World.rootPosition() + Vector3.new(10, -3, 0) })
	World.fire("StealAlarm", "Dropped", { Item = "Mountain Egg", NestIndex = 5, ReturnAt = returnAt, Thief = "Player2", CarryId = 601 })
	advance(2)
	for _, m in Inst.getTagged(Config.Tags.CarriedItem) do
		Inst.destroy(m)
	end
	World.data.Nests[5] = { Kind = "Egg", EggId = "mountain", Incubated = 40, Vault = 0, AcquiredAt = 0, LastIncomeAt = 0 }
	World.placeEgg(1, 5, 1, "mountain", 0.44)
	World.fire("StealAlarm", "Returned", { Item = "Mountain Egg", NestIndex = 5, ReturnAt = returnAt, Thief = "Player2", CarryId = 601 })
	World.pushProfile()
	advance(2)
	World.fire("StealAlarm", "Stolen", { Item = "Mountain Egg", NestIndex = 5, ReturnAt = now() + 60, Thief = "Player2", CarryId = 602 })
	advance(2)
	World.fire("StealAlarm", "Claimed", { Item = "Mountain Egg", NestIndex = 5, ReturnAt = now() + 58, Thief = "Player2", CarryId = 602 })
	advance(5)

	step("2h belt purchase")
	World.fire("FeedbackCue", "Bought", {})
	Inst.setAttribute(World.player, "Carrying", true)
	local bought = World.carryModel({ eggId = "forest", source = "Belt", label = "Forest Egg", carrierId = 1, carryId = 701 })
	World.data.Stats.EggsBought += 1
	World.data.Cash -= 100
	World.pushProfile()
	advance(3)
	Inst.destroy(bought)
	Inst.setAttribute(World.player, "Carrying", false)
	-- Every usable nest is full: the server saves it for the next free nest.
	table.insert(World.data.PendingEggs, "forest")
	World.notify("Your nests are full: the Forest Egg is saved for your next free nest.", "Info")
	World.fire("FeedbackCue", "Claimed", { Stolen = false })
	World.pushProfile()
	advance(2)

	step("2i rebirth")
	World.data.Rebirths = 1
	World.fire("FeedbackCue", "Rebirth", { Rebirths = 1 })
	World.fire("GlobalAnnounce", "Player1 was reborn! (Rebirth 1)", "Legendary")
	World.pushProfile()
	advance(4)

	step("2j retention")
	World.retention.dailyCanClaim = true
	World.retention.spinsExtra = 2
	World.pushRetention()
	World.persistent = false
	World.pushProfile()
	advance(2)
	World.persistent = true
	World.pushProfile()
	advance(1)
end

local function stepOpenAndClick(clientRealm, client)
	step("3 open screens and click")
	local controllers = Inst.findChild(S[client], "Controllers")
	local opened = {}
	-- Whatever is on screen first (HUD, plot panel, tutorial...)
	clickAll("initial")
	focusTextBoxes()
	if controllers then
		for _, module in S[controllers].children do
			local entry = clientRealm.cache[module]
			if entry and entry.state == "loaded" and type(entry.value) == "table" then
				for _, fnName in { "Open" } do
					local fn = entry.value[fnName]
					if type(fn) == "function" then
						step("3 " .. S[module].name .. "." .. fnName)
						table.insert(opened, S[module].name .. "." .. fnName)
						Sched.run(fn, S[module].name .. "." .. fnName .. "()")
						advance(1)
						clickAll(S[module].name)
						focusTextBoxes()
						advance(0.5)
					end
				end
			end
		end
	end
	Report.stats.opened = opened
	step("3 keys and actions")
	sendInput()
	clickAll("after input")
	-- The shop counter prompt (UpgradeShopController opens on PromptTriggered)
	step("3 shop prompt")
	local counter = World.shopCounter
	local shopPrompt = counter and Inst.findChild(S[counter], "ShopPrompt")
	if shopPrompt then
		World.moveCharacter(Inst.get(counter, "Position") + Vector3.new(0, 3, -6))
		simulatePrompt(shopPrompt)
		advance(1)
		clickAll("shop")
	end
	recordScreenGuiState()
end

--- Input that isn't a GUI click: keys (desktop) or a screen tap (phone)
--- through UserInputService, and every ContextActionService action.
function sendInput()
	local uis = svc("UserInputService")
	local touch = Services.profile.touch
	local inputs = {}
	if touch then
		table.insert(inputs, { type = Enum.UserInputType.Touch, key = Enum.KeyCode.Unknown })
	else
		for _, key in { Enum.KeyCode.E, Enum.KeyCode.Q, Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Tab, Enum.KeyCode.Escape } do
			table.insert(inputs, { type = Enum.UserInputType.Keyboard, key = key })
		end
		table.insert(inputs, { type = Enum.UserInputType.MouseButton1, key = Enum.KeyCode.Unknown })
	end
	for _, i in inputs do
		local function make(state)
			local io = Inst.create("InputObject")
			local st = S[io]
			st.props.UserInputType = i.type
			st.props.UserInputState = state
			st.props.KeyCode = i.key
			st.props.Position = Vector3.new(Classes.viewport.X / 2, Classes.viewport.Y / 2, 0)
			st.props.Delta = Vector3.zero
			return io
		end
		Inst.fire(uis, "InputBegan", make(Enum.UserInputState.Begin), false)
		if i.type == Enum.UserInputType.Touch then
			Inst.fire(uis, "TouchStarted", make(Enum.UserInputState.Begin), false)
			Inst.fire(uis, "TouchTap", { Vector2.new(Classes.viewport.X / 2, Classes.viewport.Y / 2) }, false)
			Inst.fire(uis, "TouchEnded", make(Enum.UserInputState.End), false)
		end
		advance(0.05)
		Inst.fire(uis, "InputEnded", make(Enum.UserInputState.End), false)
		advance(0.25)
	end
	local names = Util.sortedKeys(Services.actions)
	for _, name in names do
		local action = Services.actions[name]
		if action then
			local io = Inst.create("InputObject")
			local st = S[io]
			st.props.UserInputType = if touch then Enum.UserInputType.Touch else Enum.UserInputType.Keyboard
			st.props.UserInputState = Enum.UserInputState.Begin
			st.props.KeyCode = Enum.KeyCode.Unknown
			st.props.Position = Vector3.zero
			Sched.run(action.fn, "ContextActionService action " .. name .. " bound at " .. tostring(action.location), name, Enum.UserInputState.Begin, io)
			advance(0.1)
			Sched.run(action.fn, "ContextActionService action " .. name, name, Enum.UserInputState.End, io)
			advance(0.2)
		end
	end
	Report.stats.actions = names
end

local function stepToolsAndPrompts()
	step("4 tools")
	local player = World.player
	local backpack = Inst.findChild(S[player], "Backpack")
	local character = get(player, "Character")
	if backpack and character then
		for _, tool in table.clone(S[backpack].children) do
			if S[tool].info.rec.isA.Tool then
				step("4 tool " .. S[tool].name)
				Inst.setParent(tool, S[tool], character)
				advance(1)
				Inst.fire(tool, "Activated")
				advance(1.5)
				Inst.fire(tool, "Deactivated")
				clickAll("tool " .. S[tool].name)
				Inst.setParent(tool, S[tool], backpack)
				advance(0.5)
			end
		end
	end

	step("4 prompts")
	local Config = World.Config
	-- A sighting to capture, a dropped item to pick up.
	local home = World.rootPosition()
	World.wildCryptid("dover_demon", home + Vector3.new(20, 0, 0), 3, World.serverNow() + 90)
	World.carryModel({ eggId = "swamp", source = "Steal", label = "Swamp Egg", dropped = true, ownerId = 2, ownerName = "Player2", carryId = 801, position = home + Vector3.new(8, -3, 0) })
	-- A mock prompt with every display field set.
	local mockPart = World.new("Part", { Name = "SmokePromptPart", CFrame = CFrame.new(home + Vector3.new(4, 0, 0)), Size = Vector3.one, Anchored = true }, Services.byClass.Workspace)
	World.new("ProximityPrompt", {
		Name = "SmokePrompt",
		ActionText = "Inspect",
		ObjectText = "Smoke Test",
		HoldDuration = 1,
		KeyboardKeyCode = Enum.KeyCode.F,
		Style = Enum.ProximityPromptStyle.Custom,
	}, mockPart)
	local prompts = {}
	for _, d in Inst.descendants(Services.byClass.Workspace) do
		if S[d].className == "ProximityPrompt" then
			table.insert(prompts, d)
		end
	end
	-- One of each name is enough.
	local seen = {}
	for _, p in prompts do
		local name = S[p].name
		if not seen[name] then
			seen[name] = true
			step("4 prompt " .. name)
			simulatePrompt(p)
		end
	end
	Report.stats.prompts = Util.sortedKeys(seen)
	clickAll("after prompts")
end

local function stepResize()
	step("5 resize")
	for _, size in { Vector2.new(1920, 1080), Vector2.new(749, 368), Vector2.new(1280, 720) } do
		Services.setViewport(size)
		Sched.drain()
		advance(1)
	end
end

local function stepRespawn()
	step("6 respawn")
	local player = World.player
	local pg = playerGui()
	-- Roblox resets PlayerGui on spawn: every LayerCollector with
	-- ResetOnSpawn = true is destroyed.
	for _, gui in table.clone(S[pg].children) do
		local st = S[gui]
		if st.info.rec.isA.LayerCollector and get(gui, "ResetOnSpawn") then
			Report.add(
				"WARN",
				"UI destroyed on respawn (ResetOnSpawn = true)",
				string.format("%s '%s' was destroyed when the character respawned (set ResetOnSpawn = false, or rebuild it on CharacterAdded)", st.className, st.name),
				st.createdAt
			)
			Inst.destroy(gui)
		end
	end
	-- New Backpack, new tools (BatService / CodexService give them on spawn)
	local oldBackpack = Inst.findChild(S[player], "Backpack")
	local character = get(player, "Character")
	if character then
		Inst.fire(player, "CharacterRemoving", character)
	end
	if oldBackpack then
		Inst.destroy(oldBackpack)
	end
	World.new("Backpack", { Name = "Backpack" }, player)
	World.spawnCharacter(player, 1)
	World.giveTools(player)
	Sched.drain()
	advance(60)
end

--------------------------------------------------------------------------
-- Listing the PlayerGui tree (--list)
--------------------------------------------------------------------------

local function describe(inst, indent, out)
	local st = S[inst]
	local rec = st.info.rec
	if not rec.isA.GuiBase2d then
		return -- corners, strokes, layouts, scripts: noise here
	end
	local bits = { st.className .. " " .. st.name }
	if rec.isA.GuiObject then
		table.insert(bits, if get(inst, "Visible") then "visible" else "hidden")
	elseif rec.isA.LayerCollector then
		table.insert(bits, if get(inst, "Enabled") then "enabled" else "disabled")
		if rec.props.DisplayOrder then
			table.insert(bits, "DisplayOrder=" .. tostring(get(inst, "DisplayOrder")))
		end
	end
	if rec.props.Text then
		local text = tostring(get(inst, "Text"))
		if text ~= "" then
			text = string.gsub(text, "\n", " / ")
			if #text > 70 then
				text = string.sub(text, 1, 67) .. "..."
			end
			table.insert(bits, string.format("%q", text))
		end
	end
	if rec.isA.GuiButton then
		table.insert(bits, "[button]")
	end
	table.insert(out, string.rep("  ", indent) .. table.concat(bits, "  "))
	-- Children, with runs of identical subtrees collapsed ("x26").
	local blocks = {}
	for _, c in st.children do
		local sub = {}
		describe(c, indent + 1, sub)
		if #sub > 0 then
			local text = table.concat(sub, "\n")
			local last = blocks[#blocks]
			if last and last.text == text then
				last.n += 1
			else
				table.insert(blocks, { text = text, n = 1, first = sub[1], rest = table.move(sub, 2, #sub, 1, {}) })
			end
		end
	end
	for _, b in blocks do
		table.insert(out, b.first .. (if b.n > 1 then string.format("  (x%d)", b.n) else ""))
		for _, line in b.rest do
			table.insert(out, line)
		end
	end
end

function Scenario.listTree(): string
	local out = {}
	for _, gui in S[playerGui()].children do
		describe(gui, 0, out)
	end
	return table.concat(out, "\n")
end

--------------------------------------------------------------------------
-- Run
--------------------------------------------------------------------------

function Scenario.run(clientRealm, client, options)
	options = options or {}
	for k, v in options do
		Scenario.options[k] = v
	end
	Sched.afterFrame = Scenario.checkWaits
	stepStart(clientRealm, client)
	if not options.startOnly then
		stepServerEvents()
		stepOpenAndClick(clientRealm, client)
		stepToolsAndPrompts()
		stepResize()
		stepRespawn()
	else
		advance(10)
	end
	step("end")
	recordScreenGuiState()
	-- Anything still waiting forever.
	for _, w in Inst.pendingWaits do
		if not w.done and not w.timeout then
			Report.add(
				"FAIL",
				"WaitForChild never resolved",
				string.format("WaitForChild never resolved: %s (still waiting at the end of the scenario, no timeout)", w.path),
				w.location
			)
		end
	end
	Report.stats.buttonsClicked = clickedCount
	Report.stats.virtualSeconds = Sched.now
	Report.stats.frames = Sched.frameCount
	Report.stats.instances = Inst.created
	Report.stats.calls = Services.calls
end

return Scenario
