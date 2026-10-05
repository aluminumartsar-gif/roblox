--!strict
--[[
	WorldService
	ServerScriptService/Server/Services/WorldService

	Sets the night lighting from Config.Atmosphere and builds the world
	(terrain + map) with MapBuilder. Starts right after ArtService (whose
	mesh templates the map clones), before anyone can spawn.

	The boot log prints the terrain time, total build time and part counts
	per category, so performance regressions show up in every play test.
	Studio: SAC_Debug "mapstats" prints the same.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local MapBuilder = require(ServerScriptService:WaitForChild("Server"):WaitForChild("Modules"):WaitForChild("MapBuilder"))

local WorldService = {}

local plots: { Model } = {}

--- Plot models in index order.
function WorldService.GetPlots(): { Model }
	return plots
end

--- One line describing the last build: timings, part counts, lights.
function WorldService.DescribeBuild(): string
	local stats = MapBuilder.LastStats
	if not stats then
		return "map not built yet"
	end
	local names = {}
	for name in pairs(stats.Parts) do
		table.insert(names, name)
	end
	table.sort(names)
	local counts = {}
	for _, name in ipairs(names) do
		table.insert(counts, string.format("%s %d", name, stats.Parts[name]))
	end
	return string.format("terrain %.0f ms, total %.0f ms, %d parts (%s), %d lights, props %d mesh / %d part-built",
		stats.TerrainMs, stats.TotalMs, stats.TotalParts, table.concat(counts, ", "),
		stats.Lights, stats.MeshProps, stats.FallbackProps)
end

function WorldService.Start()
	MapBuilder.ApplyAtmosphere()

	-- Runtime objects (eggs, creatures, carried items) live here, never
	-- inside Map, so a map rebuild can't take them with it.
	if not Workspace:FindFirstChild("Runtime") then
		local runtime = Instance.new("Folder")
		runtime.Name = "Runtime"
		runtime.Parent = Workspace
	end

	local _, builtPlots = MapBuilder.Build(Workspace)
	plots = builtPlots

	print(string.format("[SAC/World] Map built: %d plots — %s", #plots, WorldService.DescribeBuild()))
	if #plots ~= Config.Plot.Count then
		warn(string.format("[SAC/World] Expected %d plots, built %d", Config.Plot.Count, #plots))
	end
end

return WorldService
