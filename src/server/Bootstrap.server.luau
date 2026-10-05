--!strict
--[[
	Bootstrap
	ServerScriptService/Server/Bootstrap

	The single server entry point. Requires Config, sanity-checks it, creates
	the Remotes folder, then starts every service in a fixed order.

	Services are added to SERVICE_ORDER as they are built. Each service module
	exposes a `Start()` function and is required lazily here so that a broken
	service produces one clear error instead of a require cascade.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

-- PlotService spawns each character at its owner's plot once the profile
-- and plot are ready. Set this before anything can yield, so nobody gets
-- auto-spawned into a world that isn't built yet. (Also saved as a place
-- setting by tools/place-settings.luau, as a second line of defence.)
Players.CharacterAutoLoads = false

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local ServerRoot = ServerScriptService:WaitForChild("Server")
local ServicesFolder = ServerRoot:WaitForChild("Services")

-- Services start in this order. Add to the list as steps land.
local SERVICE_ORDER: { string } = {
	"WorldService",     -- build the map first, before anyone can spawn
	"DataService",
	"MovementService",
	"PlotService",
	-- Step 3: "EggService", "IncomeService",
	-- Step 4: "StealService",
	-- Step 5: "RebirthService", "UpgradeService",
	-- Step 6: "MonetizationService",
	-- Step 7: "SightingService", "CodexService",
}

local function log(fmt: string, ...: any)
	print(string.format("[SAC] " .. fmt, ...))
end

local function warnf(fmt: string, ...: any)
	warn(string.format("[SAC] " .. fmt, ...))
end

--------------------------------------------------------------------------
-- Config sanity check
-- Catches designer typos at boot rather than three hours into a session.
--------------------------------------------------------------------------

local function validateConfig(): (boolean, { string })
	local problems: { string } = {}

	-- Every rarity in RarityOrder must have an entry with a matching index.
	for i, rarity in ipairs(Config.RarityOrder) do
		local entry = Config.Rarities[rarity]
		if not entry then
			table.insert(problems, "RarityOrder lists '" .. rarity .. "' but Config.Rarities has no entry")
		elseif entry.Index ~= i then
			table.insert(problems, string.format("Rarity '%s' has Index %d but is at position %d in RarityOrder", rarity, entry.Index, i))
		end
	end

	-- Every rarity must be represented by at least one creature, and every
	-- egg must reference only known rarities.
	for _, rarity in ipairs(Config.RarityOrder) do
		local list = Config.CreaturesByRarity[rarity]
		if not list or #list == 0 then
			table.insert(problems, "No creatures defined for rarity '" .. rarity .. "'")
		end
	end

	for _, eggId in ipairs(Config.EggOrder) do
		local egg = Config.Eggs[eggId]
		if not egg then
			table.insert(problems, "EggOrder lists '" .. eggId .. "' but Config.Eggs has no entry")
		else
			local total = 0
			for rarity, weight in pairs(egg.Weights) do
				if not Config.Rarities[rarity] then
					table.insert(problems, string.format("Egg '%s' has a weight for unknown rarity '%s'", eggId, rarity))
				end
				if weight < 0 then
					table.insert(problems, string.format("Egg '%s' has a negative weight for '%s'", eggId, rarity))
				end
				total += weight
			end
			if total <= 0 then
				table.insert(problems, string.format("Egg '%s' has no positive weights", eggId))
			end
		end
	end

	-- Heat multipliers must name real rarities and never shrink a weight.
	for rarity, multiplier in pairs(Config.Heat.MaxMultiplierByRarity) do
		if not Config.Rarities[rarity] then
			table.insert(problems, string.format("Heat.MaxMultiplierByRarity names unknown rarity '%s'", rarity))
		elseif typeof(multiplier) ~= "number" or multiplier < 1 then
			table.insert(problems, string.format("Heat.MaxMultiplierByRarity.%s must be a number >= 1", rarity))
		end
	end

	-- Upgrade level 1 must always be free, and costs must increase.
	for _, upgradeId in ipairs(Config.UpgradeOrder) do
		local up = Config.Upgrades[upgradeId]
		if not up then
			table.insert(problems, "UpgradeOrder lists '" .. upgradeId .. "' but Config.Upgrades has no entry")
		else
			if up.Levels[1].Cost ~= 0 then
				table.insert(problems, string.format("Upgrade '%s' level 1 must cost 0", upgradeId))
			end
			for i = 2, #up.Levels do
				if up.Levels[i].Cost <= up.Levels[i - 1].Cost then
					table.insert(problems, string.format("Upgrade '%s' level %d does not cost more than level %d", upgradeId, i, i - 1))
				end
			end
		end
	end

	-- Every declared remote needs a direction, and client->server remotes
	-- need a rate limit.
	for name, spec in pairs(Config.Remotes) do
		if spec.Direction ~= "ClientToServer" and spec.Direction ~= "ServerToClient" then
			table.insert(problems, string.format("Remote '%s' has an invalid Direction", name))
		end
		if spec.Direction == "ClientToServer" and not spec.MaxPerMinute then
			table.insert(problems, string.format("Remote '%s' is client-to-server but has no MaxPerMinute", name))
		end
		if spec.Kind ~= "Event" and spec.Kind ~= "Function" then
			table.insert(problems, string.format("Remote '%s' has an invalid Kind", name))
		end
	end

	return #problems == 0, problems
end

--------------------------------------------------------------------------
-- Remotes
-- Created here so there is exactly one place remotes come into existence.
--------------------------------------------------------------------------

local function buildRemotes(): (Folder, number)
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end
	assert(remotes)

	local created = 0
	for name, spec in pairs(Config.Remotes) do
		local className = spec.Kind == "Function" and "RemoteFunction" or "RemoteEvent"
		local existing = remotes:FindFirstChild(name)
		if existing and existing.ClassName ~= className then
			existing:Destroy()
			existing = nil
		end
		if not existing then
			local remote = Instance.new(className)
			remote.Name = name
			remote.Parent = remotes
			created += 1
		end
	end

	return remotes, created
end

--------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------

local startClock = os.clock()

log("Booting Steal a Cryptid  (Config v%s)", Config.Version)

local configOk, configProblems = validateConfig()
if configOk then
	log("Config OK — %d creatures, %d eggs, %d upgrades, %d remotes",
		#Config.Creatures, #Config.EggOrder, #Config.UpgradeOrder, (function()
			local n = 0
			for _ in pairs(Config.Remotes) do n += 1 end
			return n
		end)())
else
	warnf("Config has %d problem(s):", #configProblems)
	for _, problem in ipairs(configProblems) do
		warnf("  - %s", problem)
	end
end

local remotesFolder, remotesCreated = buildRemotes()
log("Remotes ready (%d created) at %s", remotesCreated, remotesFolder:GetFullName())

local startedCount = 0
for _, serviceName in ipairs(SERVICE_ORDER) do
	local moduleScript = ServicesFolder:FindFirstChild(serviceName)
	if not moduleScript then
		warnf("Service '%s' is in SERVICE_ORDER but does not exist", serviceName)
		continue
	end

	local ok, serviceOrErr = pcall(require, moduleScript)
	if not ok then
		warnf("Service '%s' failed to require: %s", serviceName, tostring(serviceOrErr))
		continue
	end

	local service = serviceOrErr
	if typeof(service) ~= "table" or typeof(service.Start) ~= "function" then
		warnf("Service '%s' does not expose a Start() function", serviceName)
		continue
	end

	local startOk, startErr = pcall(service.Start)
	if startOk then
		startedCount += 1
		log("Started %s", serviceName)
	else
		warnf("Service '%s' errored during Start(): %s", serviceName, tostring(startErr))
	end
end

log("Boot complete — %d/%d services started in %.1f ms",
	startedCount, #SERVICE_ORDER, (os.clock() - startClock) * 1000)

-- Studio-only test hooks. Never runs on a live server.
if RunService:IsStudio() then
	local debugModule = ServerRoot:WaitForChild("Modules"):FindFirstChild("DebugCommands")
	if debugModule then
		local ok, err = pcall(function()
			require(debugModule).Start()
		end)
		if not ok then
			warnf("DebugCommands failed: %s", tostring(err))
		end
	end
end
