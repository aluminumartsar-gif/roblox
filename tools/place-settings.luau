--[[
	place-settings.luau

	Place settings that can only be changed in Edit mode (not by scripts at
	runtime), kept here so they're recorded in the repo. Run the body in
	Studio's Edit datamodel via the MCP or the command bar, then save the
	place. Safe to run repeatedly.

	It also builds a PREVIEW of the generated map so the place shows the
	world in Edit mode. The server replaces it on every boot; editing those
	parts by hand does nothing lasting.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

-- Command-bar/MCP code caches every module it has ever required, so after
-- Config changes the real Shared modules would load stale. Work with a
-- fresh copy of Shared swapped in, and put the real one back at the end.
local realShared = ReplicatedStorage.Shared
local freshShared = realShared:Clone()
realShared.Parent = nil
freshShared.Parent = ReplicatedStorage

local log = {}
local ok, err = pcall(function()
	local Config = require(freshShared.Config)

	-- Streaming: only stream what's near each player. (The radius properties
	-- aren't scriptable in current Studio; Roblox's defaults apply.)
	Workspace.StreamingEnabled = Config.Performance.StreamingEnabled
	table.insert(log, "StreamingEnabled=" .. tostring(Workspace.StreamingEnabled))

	-- PlotService spawns characters itself (Bootstrap also sets this at runtime).
	Players.CharacterAutoLoads = false
	table.insert(log, "CharacterAutoLoads=false")

	-- The default template baseplate and the empty Step 0 folders are replaced
	-- by the generated Map.
	for _, name in ipairs({ "Baseplate", "Hub", "Plots", "Wilds" }) do
		local existing = Workspace:FindFirstChild(name)
		if existing and (name == "Baseplate" or #existing:GetChildren() == 0) then
			existing:Destroy()
			table.insert(log, "removed Workspace." .. name)
		end
	end

	-- Map preview (terrain + parts) and the night lighting. Clone the module
	-- so we always run the current source, not a copy the command bar cached
	-- earlier. There are no mesh templates in Edit mode, so props use their
	-- part-built fallbacks here; live servers use the meshes.
	local MapBuilder = require(ServerScriptService.Server.Modules.MapBuilder:Clone())
	MapBuilder.ApplyAtmosphere()
	table.insert(log, "applied Config.Atmosphere to Lighting")
	local map, plots = MapBuilder.Build(Workspace)
	table.insert(log, string.format("built map preview: %d plots, %d instances", #plots, #map:GetDescendants()))
	local stats = MapBuilder.LastStats
	if stats then
		local counts = {}
		for name, n in pairs(stats.Parts) do
			table.insert(counts, name .. " " .. n)
		end
		table.sort(counts)
		table.insert(log, string.format("terrain %.0f ms, total %.0f ms, %d parts (%s), %d lights",
			stats.TerrainMs, stats.TotalMs, stats.TotalParts, table.concat(counts, ", "), stats.Lights))
	end

	-- Grass blades on the Grass terrain material. Scripts can't set this
	-- (Terrain.Decoration isn't scriptable), so just report it.
	local okDecoration, decoration = pcall(function()
		return (Workspace.Terrain :: any).Decoration
	end)
	table.insert(log, if okDecoration
		then "Terrain.Decoration=" .. tostring(decoration)
		else "Terrain.Decoration: tick it by hand (Explorer > Terrain > Properties > Decoration)")
end)

freshShared:Destroy()
realShared.Parent = ReplicatedStorage
if not ok then
	error(err)
end

return table.concat(log, "\n")
