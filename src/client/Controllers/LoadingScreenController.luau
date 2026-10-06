local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Components = script.Parent.Parent:WaitForChild("Components")
local LoadingScreenUI = require(Components:WaitForChild("LoadingScreenUI"))

local LoadingScreenController = {}

local MIN_DISPLAY_TIME = 2.25
local MAX_DISPLAY_TIME = 8
local PROGRESS_TICK = 0.08

local started = false

local function getPreloadTargets()
	local targets = {}

	local shared = ReplicatedStorage:WaitForChild("Shared", 5)
	if shared then
		table.insert(targets, shared)
	end

	local brainrots = ReplicatedStorage:FindFirstChild("Brainrots")
	if brainrots then
		table.insert(targets, brainrots)
	end

	return targets
end

local function preloadTargets(targets: { Instance })
	if #targets == 0 then
		return
	end

	pcall(function()
		ContentProvider:PreloadAsync(targets)
	end)
end

function LoadingScreenController.start()
	if started then
		return
	end
	started = true

	local ui = LoadingScreenUI.new()
	local startedAt = os.clock()
	local loadComplete = false
	local isActive = true

	task.spawn(function()
		if not game:IsLoaded() then
			ui:setStatus("Loading world...")
			game.Loaded:Wait()
		end
		if not isActive then
			return
		end
		ui:setProgress(0.3)

		if not Players.LocalPlayer.Character then
			ui:setStatus("Spawning character...")
			Players.LocalPlayer.CharacterAdded:Wait()
		end
		if not isActive then
			return
		end
		ui:setProgress(0.55)

		ui:setStatus("Preloading game assets...")
		preloadTargets(getPreloadTargets())
		if not isActive then
			return
		end
		ui:setProgress(0.9)

		loadComplete = true
	end)

	while not loadComplete and os.clock() - startedAt < MAX_DISPLAY_TIME do
		local elapsed = os.clock() - startedAt
		local simulatedProgress = math.min(0.88, 0.12 + elapsed / MAX_DISPLAY_TIME * 0.7)
		ui:setProgress(simulatedProgress)
		task.wait(PROGRESS_TICK)
	end

	local remainingDisplayTime = MIN_DISPLAY_TIME - (os.clock() - startedAt)
	if remainingDisplayTime > 0 then
		task.wait(remainingDisplayTime)
	end

	isActive = false
	ui:finish()
end

return LoadingScreenController
