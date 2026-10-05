--!strict
--[[
	DebugCommands
	ServerScriptService/Server/Modules/DebugCommands

	STUDIO ONLY. Bootstrap refuses to start this in a live server.

	Exposes ServerStorage/SAC_Debug (a BindableFunction) so tests run from
	the command bar or the MCP can poke the live game. A BindableFunction is
	used rather than _G because command-bar code runs in a different Luau VM
	than game scripts and would get its own separate copy of every module.

	Usage (Server side of a play test):
	  local dbg = game.ServerStorage.SAC_Debug
	  dbg:Invoke("status")
	  dbg:Invoke("give", "PlayerName", 5000)
	  dbg:Invoke("dump", "PlayerName")
	  dbg:Invoke("save", "PlayerName")
	  dbg:Invoke("wipe", "PlayerName")   -- resets to a fresh profile
	  dbg:Invoke("plots")                -- who owns what, lock state
	  dbg:Invoke("resetlock", "PlayerName")
	  dbg:Invoke("simulate", 10000)      -- odds check, every egg, heat 0 & max
	  dbg:Invoke("giveegg", "PlayerName", "forest", heat)
	  dbg:Invoke("setheat", "PlayerName", 100)
	  dbg:Invoke("hatch", "PlayerName", nestIndex)
	  dbg:Invoke("setslot", "PlayerName", nestIndex, "egg"|"creature"|"empty", id, heat)
	  dbg:Invoke("nests", "PlayerName")
	  dbg:Invoke("carries")              -- everything currently stolen/in transit
	  dbg:Invoke("belt")                 -- eggs on the belt right now
	  dbg:Invoke("beltspawn", "void")    -- put a chosen egg on the belt
	  dbg:Invoke("beltroll", 100000)     -- roll the belt picker: checks the odds board
	  dbg:Invoke("knock", "PlayerName")  -- drop what they carry, like a bat hit
	  dbg:Invoke("unprotect", "PlayerName")
	  dbg:Invoke("clearcooldown", "PlayerName")
	  dbg:Invoke("snapshot", "PlayerName") / dbg:Invoke("restore", "PlayerName")
	  dbg:Invoke("receipt", "PlayerName", "LuckPotion", purchaseId?)  -- fake dev product purchase
	  dbg:Invoke("pass", "PlayerName", "Vip", true|false)              -- fake pass ownership
	  dbg:Invoke("codex", "PlayerName")                       -- list Codex entries, pages, luck
	  dbg:Invoke("codexadd", "PlayerName", "yeti"|"Rare"|"all") -- log entries (a rarity: celebrates the last one)
	  dbg:Invoke("codexclear", "PlayerName")                  -- empty their Codex
	  dbg:Invoke("retention", "PlayerName")      -- daily/spin/gifts/offline state (JSON)
	  dbg:Invoke("dailyskip", "PlayerName")      -- pretend the last daily claim was yesterday (streak continues)
	  dbg:Invoke("dailymiss", "PlayerName", 2)   -- pretend it was 2+ days ago (streak resets to day 1)
	  dbg:Invoke("spinready", "PlayerName")      -- free spin ready now
	  dbg:Invoke("gifttime", "PlayerName", 10)   -- move this visit's playtime clock 10 minutes on
	  dbg:Invoke("offline", "PlayerName", 3600)  -- add offline cash for 3600s away + show the popup
	  dbg:Invoke("sighting")                     -- spawn a wild cryptid now (rolled like a real one)
	  dbg:Invoke("sighting", "Legendary")        -- ...of a chosen rarity, or a creature id ("mothman")
	  dbg:Invoke("sightingend")                  -- make the current sighting escape
	  dbg:Invoke("sightings")                    -- sighting state, captures in transit, current odds
	  dbg:Invoke("hatchfx", "PlayerName", "Secret"|"nessie")  -- hatch reveal on screen only (no data change)
	  dbg:Invoke("cashfx", "PlayerName", 12500)               -- "+$12.5K" popup + coin sound only (no cash given)
	  dbg:Invoke("mapstats")                     -- map build: terrain/total ms, parts per category, lights
	  dbg:Invoke("leaderboard")                  -- write everyone's scores now, re-read the boards, report
	  dbg:Invoke("tutorial", "PlayerName")           -- replay the first-join tutorial (done steps skip)
	  dbg:Invoke("tutorial", "PlayerName", "fresh")  -- wipe to a new profile, then replay every step
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Services = ServerScriptService:WaitForChild("Server"):WaitForChild("Services")
local Modules = ServerScriptService:WaitForChild("Server"):WaitForChild("Modules")

local DebugCommands = {}

local function findPlayer(name: any): Player?
	if typeof(name) ~= "string" then
		local all = Players:GetPlayers()
		return all[1]
	end
	local lowered = string.lower(name)
	for _, player in ipairs(Players:GetPlayers()) do
		if string.lower(player.Name) == lowered or string.lower(player.DisplayName) == lowered then
			return player
		end
	end
	return nil
end

function DebugCommands.Start()
	assert(RunService:IsStudio(), "DebugCommands must never run outside Studio")

	local DataService = require(Services:WaitForChild("DataService"))
	local ProfileTemplate = require(Modules:WaitForChild("ProfileTemplate"))

	local commands: { [string]: (...any) -> any } = {}

	function commands.status()
		local lines = { "persistent=" .. tostring(DataService.IsPersistent()) }
		for _, player in ipairs(Players:GetPlayers()) do
			local data = DataService.Get(player)
			table.insert(lines, string.format("%s loaded=%s cash=%s rebirths=%s",
				player.Name, tostring(data ~= nil),
				data and tostring(data.Cash) or "-",
				data and tostring(data.Rebirths) or "-"))
		end
		return table.concat(lines, "\n")
	end

	function commands.give(name, amount)
		local player = findPlayer(name)
		if not player then
			return "no such player"
		end
		local ok = DataService.AddCash(player, tonumber(amount) or 0, "debug")
		return string.format("give ok=%s cash=%d", tostring(ok), DataService.GetCash(player))
	end

	function commands.dump(name)
		local player = findPlayer(name)
		local data = player and DataService.Get(player)
		if not data then
			return "not loaded"
		end
		return HttpService:JSONEncode(data)
	end

	function commands.save(name)
		local player = findPlayer(name)
		if not player then
			return "no such player"
		end
		return "save ok=" .. tostring(DataService.SaveNow(player))
	end

	-- Replaces a player's whole profile and redraws everything that shows it.
	local function replaceProfile(player: Player, replacement: { [string]: any }): boolean
		local ok = DataService.Mutate(player, function(data)
			for key in pairs(data) do
				(data :: any)[key] = nil
			end
			for key, value in pairs(replacement) do
				(data :: any)[key] = value
			end
		end)
		local PlotService = require(Services:WaitForChild("PlotService"))
		local NestService = require(Services:WaitForChild("NestService"))
		local MovementService = require(Services:WaitForChild("MovementService"))
		local plot = PlotService.GetPlot(player)
		if plot then
			NestService.RenderPlot(plot)
		end
		PlotService.RefreshNests(player)
		MovementService.Refresh(player)
		return ok
	end

	function commands.wipe(name)
		local player = findPlayer(name)
		if not player then
			return "no such player"
		end
		return "wipe ok=" .. tostring(replaceProfile(player, ProfileTemplate.new()))
	end

	-- snapshot/restore: run destructive tests (rebirth) on a real save and
	-- put it back exactly. Snapshots live in server memory only.
	local snapshots: { [number]: string } = {}

	function commands.snapshot(name)
		local player = findPlayer(name)
		local data = player and DataService.Get(player)
		if not player or not data then
			return "not loaded"
		end
		snapshots[player.UserId] = HttpService:JSONEncode(data)
		return string.format("snapshot of %s saved (%d bytes)", player.Name, #snapshots[player.UserId])
	end

	function commands.restore(name)
		local player = findPlayer(name)
		if not player or not snapshots[player.UserId] then
			return "no snapshot"
		end
		local restored = HttpService:JSONDecode(snapshots[player.UserId])
		local ok = replaceProfile(player, ProfileTemplate.Normalize(restored, player.Name .. " (restore)"))
		return "restore ok=" .. tostring(ok) .. ", save ok=" .. tostring(DataService.SaveNow(player))
	end

	local PlotService = require(Services:WaitForChild("PlotService"))

	function commands.plots()
		local now = workspace:GetServerTimeNow()
		local lines = {}
		for _, plot in ipairs(PlotService.GetPlots()) do
			table.insert(lines, string.format("Plot %d owner=%s locked=%s (%.0fs) cooldown=%.0fs",
				plot.Index,
				plot.Owner and plot.Owner.Name or "-",
				tostring(PlotService.IsLocked(plot)),
				math.max(0, plot.LockedUntil - now),
				math.max(0, plot.LockCooldownUntil - now)))
		end
		return table.concat(lines, "\n")
	end

	-- Clears a player's lock and cooldown so lock tests don't wait 5 min.
	function commands.resetlock(name)
		local player = findPlayer(name)
		local plot = player and PlotService.GetPlot(player)
		if not plot then
			return "no plot"
		end
		plot.LockedUntil = 0
		plot.LockCooldownUntil = 0
		plot.Model:SetAttribute("LockedUntil", 0)
		plot.Model:SetAttribute("LockCooldownUntil", 0)
		player:SetAttribute("PlotLockedUntil", 0)
		player:SetAttribute("PlotLockCooldownUntil", 0)
		return "lock reset for " .. player.Name
	end

	local NestService = require(Services:WaitForChild("NestService"))
	local EggRoller = require(Modules:WaitForChild("EggRoller"))

	-- 10k-roll check of every egg at heat 0 and max heat (Step 3 deliverable).
	function commands.simulate(rolls)
		local n = tonumber(rolls) or 10000
		local out = {}
		local worst = 0
		for _, eggId in ipairs(Config.EggOrder) do
			for _, heat in ipairs({ 0, Config.Heat.Max }) do
				local report, worstZ = EggRoller.SimulationReport(eggId, heat, 0, n)
				worst = math.max(worst, worstZ)
				table.insert(out, report)
			end
		end
		table.insert(out, string.format("Worst |z| across all tables: %.2f  (below ~4 = consistent with Config)", worst))
		return table.concat(out, "\n")
	end

	-- Places an egg without charging (test only).
	function commands.giveegg(name, eggId, heat)
		local player = findPlayer(name)
		if not player then
			return "no such player"
		end
		local nestIndex = NestService.PlaceEgg(player, eggId or "forest", tonumber(heat) or 0)
		return if nestIndex then ("egg in nest " .. nestIndex) else "no empty nest"
	end

	-- Sets the heat of every egg the player owns.
	function commands.setheat(name, heat)
		local player = findPlayer(name)
		local data = player and DataService.Get(player)
		local plot = player and PlotService.GetPlot(player)
		if not data or not plot then
			return "not loaded"
		end
		local count = 0
		for i, slot in ipairs(data.Nests) do
			if slot ~= false and slot.Kind == "Egg" then
				slot.Heat = math.clamp(tonumber(heat) or 0, 0, Config.Heat.Max)
				local model = NestService.GetVisual(plot.Index, i)
				if model then
					model:SetAttribute("Heat", slot.Heat)
				end
				count += 1
			end
		end
		return "set heat on " .. count .. " egg(s)"
	end

	-- Hatches a nest directly (skips the prompt's distance check).
	function commands.hatch(name, nestIndex)
		local player = findPlayer(name)
		if not player then
			return "no such player"
		end
		local result = NestService.Hatch(player, tonumber(nestIndex) or 1)
		return if result then string.format("%s (%s)", result.CreatureId, result.Rarity) else "no egg there"
	end

	-- Puts anything in a nest: ("egg", eggId, heat) / ("creature", creatureId) / ("empty").
	function commands.setslot(name, nestIndex, kind, id, heat)
		local player = findPlayer(name)
		local index = tonumber(nestIndex)
		if not player or not index then
			return "usage: setslot(player, nestIndex, egg|creature|empty, id, heat?)"
		end
		local now = os.time()
		if kind == "egg" and Config.Eggs[id] then
			NestService.SetSlot(player, index, { Kind = "Egg", EggId = id, Heat = tonumber(heat) or 0, Vault = 0, AcquiredAt = now, LastIncomeAt = now })
		elseif kind == "creature" and Config.CreaturesById[id] then
			NestService.SetSlot(player, index, { Kind = "Creature", CreatureId = id, Rarity = Config.CreaturesById[id].Rarity, Heat = 0, Vault = 0, AcquiredAt = now, LastIncomeAt = now })
		elseif kind == "empty" then
			NestService.SetSlot(player, index, false)
		else
			return "bad kind or id"
		end
		return "nest " .. index .. " set"
	end

	local StealService = require(Services:WaitForChild("StealService"))
	local RemoteGuard = require(Modules:WaitForChild("RemoteGuard"))

	function commands.carries()
		return StealService.DebugState()
	end

	local EggBeltService = require(Services:WaitForChild("EggBeltService"))

	function commands.belt()
		return EggBeltService.DebugState()
	end

	-- Rolls the belt picker many times: checks the odds board is honest.
	function commands.beltroll(count)
		return EggBeltService.DebugRoll(tonumber(count) or 100000)
	end

	-- Puts a specific egg on the belt now (e.g. to test a Void Egg).
	function commands.beltspawn(eggId)
		return EggBeltService.DebugSpawn(tostring(eggId))
	end

	-- Knocks whatever a player is carrying out of their hands, as a bat hit would.
	function commands.knock(name)
		local player = findPlayer(name)
		if not player then
			return "no such player"
		end
		if not StealService.IsCarrying(player) then
			return player.Name .. " isn't carrying anything"
		end
		StealService.Drop(player, "debug knock")
		return "knocked loose"
	end

	-- Ends spawn protection right away (tests can't wait 5 minutes).
	function commands.unprotect(name)
		local player = findPlayer(name)
		if not player then
			return "no such player"
		end
		PlotService.EndProtection(player)
		return "protection ended for " .. player.Name
	end

	function commands.clearcooldown(name)
		local player = findPlayer(name)
		if not player then
			return "no such player"
		end
		RemoteGuard.Cooldowns.Start(player, "Steal", 0)
		return "steal cooldown cleared for " .. player.Name
	end

	local MonetizationService = require(Services:WaitForChild("MonetizationService"))

	-- Runs a developer-product purchase through the real idempotent receipt
	-- code. Pass the same purchaseId twice to test double-grant protection.
	function commands.receipt(name, productKey, purchaseId)
		local player = findPlayer(name)
		if not player then
			return "no such player"
		end
		if not Config.DevProducts[productKey] then
			return "unknown product: " .. tostring(productKey)
		end
		local id = tostring(purchaseId or HttpService:GenerateGUID(false))
		local decision = MonetizationService.ProcessReceiptForKey(player, id, productKey, Config.DevProducts[productKey].RobuxHint)
		return string.format("%s (purchase %s) -> %s", productKey, id, decision.Name)
	end

	-- Pretends a game pass is owned (or not) for this session.
	function commands.pass(name, passKey, owned)
		local player = findPlayer(name)
		if not player then
			return "no such player"
		end
		if not Config.GamePasses[passKey] then
			return "unknown pass: " .. tostring(passKey)
		end
		MonetizationService.DebugSetPass(player, passKey, owned ~= false)
		return string.format("%s %s %s", player.Name, if owned ~= false then "now owns" else "no longer owns", passKey)
	end

	function commands.nests(name)
		local player = findPlayer(name)
		local data = player and DataService.Get(player)
		if not data then
			return "not loaded"
		end
		local lines = {}
		for i, slot in ipairs(data.Nests) do
			if slot ~= false then
				if slot.Kind == "Egg" then
					table.insert(lines, string.format("%d: Egg %s heat=%.1f", i, slot.EggId, slot.Heat))
				else
					table.insert(lines, string.format("%d: %s (%s) vault=%.1f", i, slot.CreatureId, slot.Rarity, slot.Vault))
				end
			end
		end
		return #lines > 0 and table.concat(lines, "\n") or "all nests empty"
	end

	-- Codex (Step 7)
	function commands.codex(name)
		local player = findPlayer(name)
		local data = player and DataService.Get(player)
		if not player or not data then
			return "not loaded"
		end
		local CodexService = require(Services:WaitForChild("CodexService"))
		local BoostService = require(Services:WaitForChild("BoostService"))
		local total, found = 0, 0
		local lines = {}
		for _, rarity in ipairs(Config.RarityOrder) do
			local ids = {}
			local list = Config.CreaturesByRarity[rarity]
			for _, creature in ipairs(list) do
				total += 1
				if data.Codex[creature.Id] then
					found += 1
					table.insert(ids, creature.Id)
				end
			end
			table.insert(lines, string.format("%s %d/%d: %s", rarity, #ids, #list,
				#ids > 0 and table.concat(ids, ", ") or "-"))
		end
		table.insert(lines, 1, string.format("%s codex %d/%d, pages complete %d, luck now +%d%%, photos taken %s",
			player.Name, found, total, CodexService.CountCompletePages(player),
			math.floor(BoostService.GetLuckPercent(player)), tostring(data.Stats.PhotosTaken or 0)))
		return table.concat(lines, "\n")
	end

	function commands.codexadd(name, what)
		local player = findPlayer(name)
		if not player or not DataService.Get(player) then
			return "not loaded"
		end
		local CodexService = require(Services:WaitForChild("CodexService"))
		local key = string.lower(tostring(what or ""))
		if Config.CreaturesById[key] then
			local isNew, page = CodexService.Discover(player, key, "Debug")
			return string.format("%s: %s%s", key, if isNew then "added" else "already known",
				if page then (", " .. page .. " page complete") else "")
		end
		local ids: { string } = {}
		for _, rarity in ipairs(Config.RarityOrder) do
			if key == "all" or key == string.lower(rarity) then
				for _, creature in ipairs(Config.CreaturesByRarity[rarity]) do
					table.insert(ids, creature.Id)
				end
			end
		end
		if #ids == 0 then
			return "codexadd: give a creature id, a rarity or \"all\""
		end
		-- A whole rarity: silent except the last one, so exactly one
		-- celebration (and the page-complete banner) shows. "all": silent.
		local added = 0
		for i, id in ipairs(ids) do
			local silent = key == "all" or i < #ids
			if CodexService.Discover(player, id, "Debug", silent) then
				added += 1
			end
		end
		return string.format("added %d new entr%s (%d asked)", added, added == 1 and "y" or "ies", #ids)
	end

	function commands.codexclear(name)
		local player = findPlayer(name)
		if not player or not DataService.Get(player) then
			return "not loaded"
		end
		DataService.Mutate(player, function(d)
			table.clear(d.Codex)
		end)
		return "codex cleared for " .. player.Name
	end

	-- Retention (Step 7.5): daily rewards, spin wheel, playtime gifts, offline cash.
	local function retentionPlayer(name: any): (any, Player?)
		local player = findPlayer(name)
		if not player or not DataService.Get(player) then
			return nil, nil
		end
		return require(Services:WaitForChild("RetentionService")), player
	end

	function commands.retention(name)
		local RetentionService, player = retentionPlayer(name)
		if not player then
			return "not loaded"
		end
		return RetentionService.DebugState(player)
	end

	function commands.dailyskip(name)
		local RetentionService, player = retentionPlayer(name)
		if not player then
			return "not loaded"
		end
		return RetentionService.DebugDailyShift(player, 1)
	end

	function commands.dailymiss(name, days)
		local RetentionService, player = retentionPlayer(name)
		if not player then
			return "not loaded"
		end
		return RetentionService.DebugDailyShift(player, math.max(2, tonumber(days) or 2))
	end

	function commands.spinready(name)
		local RetentionService, player = retentionPlayer(name)
		if not player then
			return "not loaded"
		end
		return RetentionService.DebugSpinReady(player)
	end

	function commands.gifttime(name, minutes)
		local RetentionService, player = retentionPlayer(name)
		if not player then
			return "not loaded"
		end
		return RetentionService.DebugGiftTime(player, tonumber(minutes) or 5)
	end

	function commands.offline(name, seconds)
		local RetentionService, player = retentionPlayer(name)
		if not player then
			return "not loaded"
		end
		return RetentionService.DebugOffline(player, tonumber(seconds) or 3600)
	end

	-- Sightings (Step 7): spawn one now (optionally a rarity or creature id),
	-- make the current one escape, or show the state + current odds.
	function commands.sighting(what)
		local SightingService = require(Services:WaitForChild("SightingService"))
		return SightingService.DebugSpawn(if typeof(what) == "string" then what else nil)
	end

	function commands.sightingend()
		local SightingService = require(Services:WaitForChild("SightingService"))
		return SightingService.DebugEnd()
	end

	function commands.sightings()
		local SightingService = require(Services:WaitForChild("SightingService"))
		return SightingService.DebugState()
	end

	-- Hatch reveal without hatching: a rarity name (random creature of it)
	-- or a creature id. Legendary+ also shows the burst to everyone nearby.
	function commands.hatchfx(name, which)
		local player = findPlayer(name)
		if not player then
			return "no such player"
		end
		local FeedbackService = require(Services:WaitForChild("FeedbackService"))
		return FeedbackService.DebugHatch(player, if typeof(which) == "string" then which else nil)
	end

	-- Cash popup + coin sound at the player, without giving any cash.
	function commands.cashfx(name, amount)
		local player = findPlayer(name)
		if not player then
			return "no such player"
		end
		local FeedbackService = require(Services:WaitForChild("FeedbackService"))
		return FeedbackService.DebugCash(player, tonumber(amount) or 1234)
	end

	-- World art pass (Step 8): how the map build went.
	function commands.mapstats()
		local WorldService = require(Services:WaitForChild("WorldService"))
		return WorldService.DescribeBuild()
	end

	-- Leaderboards (Step 8): write everyone's scores now, re-read, report.
	function commands.leaderboard()
		local LeaderboardService = require(Services:WaitForChild("LeaderboardService"))
		LeaderboardService.FlushNow()
		return LeaderboardService.Describe()
	end

	-- First-join tutorial (Step 8): replay it on that player's screen. With
	-- "fresh", wipe them to a brand-new profile first (same as `wipe`) so
	-- every step shows; without it, steps they've already done skip
	-- themselves. The client's TutorialController watches this attribute.
	function commands.tutorial(name, fresh)
		local player = findPlayer(name)
		if not player then
			return "no such player"
		end
		local wiped = ""
		if fresh == "fresh" then
			wiped = " (" .. tostring(commands.wipe(player.Name)) .. ")"
		end
		local count = player:GetAttribute("TutorialReplay")
		player:SetAttribute("TutorialReplay", (if typeof(count) == "number" then count else 0) + 1)
		return "tutorial replay sent to " .. player.Name .. wiped
	end

	local existing = ServerStorage:FindFirstChild("SAC_Debug")
	if existing then
		existing:Destroy()
	end

	local bindable = Instance.new("BindableFunction")
	bindable.Name = "SAC_Debug"
	bindable.OnInvoke = function(command: string, ...: any)
		local handler = commands[string.lower(tostring(command))]
		if not handler then
			return "unknown command: " .. tostring(command)
		end
		local ok, result = pcall(handler, ...)
		return if ok then result else ("error: " .. tostring(result))
	end
	bindable.Parent = ServerStorage

	print("[SAC/Debug] Debug commands ready at ServerStorage.SAC_Debug (Studio only)")
end

return DebugCommands
