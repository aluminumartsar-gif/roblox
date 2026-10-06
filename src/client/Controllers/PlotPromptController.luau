local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local PlotConfig = require(ConfigFolder:WaitForChild("PlotConfig"))

local LocalPlayer = Players.LocalPlayer

local PlotPromptController = {}

local trackedPlots: { [Model]: RBXScriptConnection } = {}

local function isPlotModel(instance: Instance)
	return instance:IsA("Model")
		and (
			instance.Name == PlotConfig.PLOT_MODEL_NAME
			or instance.Name:match("^" .. PlotConfig.PLOT_NAME_PREFIX .. "%d+$") ~= nil
			or instance.Name:match("^" .. PlotConfig.LEGACY_PLOT_NAME_PREFIX .. "%d+$") ~= nil
		)
end

-- Place prompts: client force-enables for owner, force-disables for everyone
-- else. The server creates these once and never toggles them, so the client
-- safely owns the Enabled state.
-- Upgrade prompts: server toggles Enabled per-tier, so the client must NOT
-- force-enable for the owner (it would clobber the server's "already on this
-- floor" disable). We only force-disable for non-owners.
local function applyPromptVisibility(plot: Model)
	local ownerUserId = plot:GetAttribute(PlotConfig.PLOT_OWNER_ATTRIBUTE)
	local isOwner = ownerUserId == LocalPlayer.UserId

	for _, descendant in plot:GetDescendants() do
		if descendant:IsA("ProximityPrompt") then
			if descendant.Name == PlotConfig.PLACE_PROMPT_NAME then
				descendant.Enabled = isOwner
			elseif descendant.Name == PlotConfig.UPGRADE_PROMPT_NAME and not isOwner then
				descendant.Enabled = false
			end
		end
	end
end

local function isOwnerGatedPrompt(instance: Instance)
	return instance:IsA("ProximityPrompt")
		and (instance.Name == PlotConfig.PLACE_PROMPT_NAME or instance.Name == PlotConfig.UPGRADE_PROMPT_NAME)
end

local function trackPlot(plot: Model)
	if trackedPlots[plot] then
		return
	end

	applyPromptVisibility(plot)

	local connection = plot:GetAttributeChangedSignal(PlotConfig.PLOT_OWNER_ATTRIBUTE):Connect(function()
		applyPromptVisibility(plot)
	end)
	trackedPlots[plot] = connection

	plot.DescendantAdded:Connect(function(descendant)
		if not isOwnerGatedPrompt(descendant) then
			return
		end

		local isOwner = plot:GetAttribute(PlotConfig.PLOT_OWNER_ATTRIBUTE) == LocalPlayer.UserId
		if descendant.Name == PlotConfig.PLACE_PROMPT_NAME then
			descendant.Enabled = isOwner
		elseif descendant.Name == PlotConfig.UPGRADE_PROMPT_NAME and not isOwner then
			descendant.Enabled = false
		end
	end)
end

local function untrackPlot(plot: Model)
	local connection = trackedPlots[plot]
	if connection then
		connection:Disconnect()
		trackedPlots[plot] = nil
	end
end

local function watchContainer(container: Instance)
	for _, child in container:GetChildren() do
		if isPlotModel(child) then
			trackPlot(child)
		end
	end

	container.ChildAdded:Connect(function(child)
		if isPlotModel(child) then
			trackPlot(child)
		end
	end)

	container.ChildRemoved:Connect(function(child)
		if isPlotModel(child) then
			untrackPlot(child)
		end
	end)
end

function PlotPromptController.start()
	local basesFolder = Workspace:FindFirstChild(PlotConfig.PLOT_FOLDER_NAME)
	if basesFolder then
		watchContainer(basesFolder)
	end

	local legacyFolder = Workspace:FindFirstChild(PlotConfig.LEGACY_PLOT_FOLDER_NAME)
	if legacyFolder then
		watchContainer(legacyFolder)
	end

	watchContainer(Workspace)
end

return PlotPromptController
