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
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService = game:GetService("HttpService")

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
