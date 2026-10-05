--!strict
--[[
	WorldService
	ServerScriptService/Server/Services/WorldService

	Sets the night lighting from Config.Atmosphere and builds the map with
	MapBuilder. Starts first, so the world exists before anyone spawns.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local MapBuilder = require(ServerScriptService:WaitForChild("Server"):WaitForChild("Modules"):WaitForChild("MapBuilder"))

local WorldService = {}

local plots: { Model } = {}

local function applyLighting()
	local a = Config.Atmosphere
	Lighting.ClockTime = a.ClockTime
	Lighting.Brightness = a.Brightness
	Lighting.Ambient = a.Ambient
	Lighting.OutdoorAmbient = a.OutdoorAmbient
	Lighting.FogColor = a.FogColor

	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if not atmosphere then
		atmosphere = Instance.new("Atmosphere")
		atmosphere.Parent = Lighting
	end
	assert(atmosphere)
	atmosphere.Density = a.AtmosphereDensity
	atmosphere.Haze = a.AtmosphereHaze
	atmosphere.Color = a.FogColor
	atmosphere.Decay = a.FogDecay
	atmosphere.Glare = 0
end

--- Plot models in index order.
function WorldService.GetPlots(): { Model }
	return plots
end

function WorldService.Start()
	applyLighting()

	local started = os.clock()
	local map, builtPlots = MapBuilder.Build(Workspace)
	plots = builtPlots

	-- Runtime objects (eggs, creatures, carried items) live here, never
	-- inside Map, so a map rebuild can't take them with it.
	if not Workspace:FindFirstChild("Runtime") then
		local runtime = Instance.new("Folder")
		runtime.Name = "Runtime"
		runtime.Parent = Workspace
	end

	print(string.format("[SAC/World] Map built: %d plots, %d parts in %.0f ms",
		#plots, #map:GetDescendants(), (os.clock() - started) * 1000))
end

return WorldService
