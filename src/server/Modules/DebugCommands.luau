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
	  dbg:Invoke("unprotect", "PlayerName")
	  dbg:Invoke("clearcooldown", "PlayerName")
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

	function commands.wipe(name)
		local player = findPlayer(name)
		if not player then
			return "no such player"
		end
		local fresh = ProfileTemplate.new()
		local ok = DataService.Mutate(player, function(data)
			for key in pairs(data) do
				(data :: any)[key] = nil
			end
			for key, value in pairs(fresh) do
				(data :: any)[key] = value
			end
		end)
		return "wipe ok=" .. tostring(ok)
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
