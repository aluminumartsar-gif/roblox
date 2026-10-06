local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local EconomyConfig = require(ConfigFolder:WaitForChild("EconomyConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))

local Components = script.Parent.Parent:WaitForChild("Components")
local NewBrainrotRevealUI = require(Components:WaitForChild("NewBrainrotRevealUI"))

local NewBrainrotRevealController = {}

function NewBrainrotRevealController.start()
	local ui = NewBrainrotRevealUI.new()
	local newBrainrotFoundRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.NEW_BRAINROT_FOUND_REMOTE)

	newBrainrotFoundRemote.OnClientEvent:Connect(function(payload)
		ui:show(payload)
	end)
end

return NewBrainrotRevealController
