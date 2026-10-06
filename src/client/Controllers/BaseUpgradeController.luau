local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local EconomyConfig = require(ConfigFolder:WaitForChild("EconomyConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))

local Components = script.Parent.Parent:WaitForChild("Components")
local BaseUpgradeToast = require(Components:WaitForChild("BaseUpgradeToast"))

local BaseUpgradeController = {}

function BaseUpgradeController.start()
	local resultRemote = RemoteRegistry.getRemote(
		EconomyConfig.REMOTE_FOLDER,
		EconomyConfig.BASE_UPGRADE_RESULT_REMOTE
	)

	local toast = BaseUpgradeToast.new()

	resultRemote.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end

		toast:show(payload)
	end)
end

return BaseUpgradeController
