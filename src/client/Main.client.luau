--!strict
--[[
	Main
	StarterPlayerScripts/Client/Main

	The single client entry point. Waits for the server's Remotes folder,
	requires Config, then starts every controller in a fixed order.

	Controllers are added to CONTROLLER_ORDER as they are built. Each exposes
	a `Start()` function.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local ClientRoot = script.Parent
local ControllersFolder = ClientRoot:WaitForChild("Controllers")

-- Controllers start in this order. Add to the list as steps land.
local CONTROLLER_ORDER: { string } = {
	"ProfileController",
	"NotificationController",
	"HudController",
	"PlotController",
	"EggShopController",
	"NestVisualsController",
	"StealController",
	"UpgradeShopController",
	"RebirthController",
	-- Step 7: "SightingController", "CodexController",
}

local function log(fmt: string, ...: any)
	print(string.format("[SAC/client] " .. fmt, ...))
end

local function warnf(fmt: string, ...: any)
	warn(string.format("[SAC/client] " .. fmt, ...))
end

local startClock = os.clock()

-- The server creates Remotes at boot; the client must not assume it is there.
local remotes = ReplicatedStorage:WaitForChild("Remotes", 30)
if not remotes then
	warnf("Remotes folder never appeared. The server did not boot correctly.")
	return
end

local remoteCount = #remotes:GetChildren()
log("Connected as %s — Config v%s, %d remotes", localPlayer.Name, Config.Version, remoteCount)

local startedCount = 0
for _, controllerName in ipairs(CONTROLLER_ORDER) do
	local moduleScript = ControllersFolder:FindFirstChild(controllerName)
	if not moduleScript then
		warnf("Controller '%s' is in CONTROLLER_ORDER but does not exist", controllerName)
		continue
	end

	local ok, controllerOrErr = pcall(require, moduleScript)
	if not ok then
		warnf("Controller '%s' failed to require: %s", controllerName, tostring(controllerOrErr))
		continue
	end

	local controller = controllerOrErr
	if typeof(controller) ~= "table" or typeof(controller.Start) ~= "function" then
		warnf("Controller '%s' does not expose a Start() function", controllerName)
		continue
	end

	local startOk, startErr = pcall(controller.Start)
	if startOk then
		startedCount += 1
		log("Started %s", controllerName)
	else
		warnf("Controller '%s' errored during Start(): %s", controllerName, tostring(startErr))
	end
end

log("Client ready — %d/%d controllers started in %.1f ms",
	startedCount, #CONTROLLER_ORDER, (os.clock() - startClock) * 1000)
