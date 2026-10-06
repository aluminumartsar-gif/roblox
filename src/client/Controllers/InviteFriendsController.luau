local Players       = game:GetService("Players")
local SocialService = game:GetService("SocialService")

local UIKit     = script.Parent.Parent:WaitForChild("UIKit")
local GuiResolve = require(UIKit:WaitForChild("GuiResolve"))

local InviteFriendsController = {}

function InviteFriendsController.start()
	local localPlayer = Players.LocalPlayer
	local playerGui   = localPlayer:WaitForChild("PlayerGui")
	local sideButtons = playerGui:WaitForChild("HUD"):WaitForChild("SideButtons")
	local inviteBtn = GuiResolve.sideToggleOpenButton(sideButtons, "InviteBtn")
	if not inviteBtn then
		return
	end

	local canInvite = false
	task.spawn(function()
		local ok, result = pcall(function()
			return SocialService:CanSendGameInviteAsync(localPlayer)
		end)
		canInvite = ok and result == true
	end)

	inviteBtn.Activated:Connect(function()
		if canInvite then
			SocialService:PromptGameInvite(localPlayer)
		end
	end)
end

return InviteFriendsController
