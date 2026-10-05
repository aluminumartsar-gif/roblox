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

local Config = require(ReplicatedStorage.Shared.Config:Clone())
local log = {}

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

-- Map preview. Clone the module so we always run the current source, not a
-- copy the command bar cached earlier.
local MapBuilder = require(ServerScriptService.Server.Modules.MapBuilder:Clone())
local map, plots = MapBuilder.Build(Workspace)
table.insert(log, string.format("built map preview: %d plots, %d instances", #plots, #map:GetDescendants()))

return table.concat(log, "\n")
