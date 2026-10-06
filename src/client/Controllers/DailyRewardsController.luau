-- Shell: open/close DailyRewards ScreenGui from HUD.BottomRight.DailyBtn.
-- TODO: wire to a DailyRewardsService when server-side daily reward tracking exists.

local Players = game:GetService("Players")

local UIKit      = script.Parent.Parent:WaitForChild("UIKit")
local Screen     = require(UIKit:WaitForChild("Screen"))
local GuiResolve = require(UIKit:WaitForChild("GuiResolve"))

local DailyRewardsController = {}

function DailyRewardsController.start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local screen    = playerGui:WaitForChild("DailyRewards")
	local container = GuiResolve.waitChild(screen, "Container")
	if not container or not container:IsA("GuiObject") then return end
	local bg        = GuiResolve.waitChild(container, "Background")
	if not bg then return end
	local bottomRight = playerGui:WaitForChild("HUD"):WaitForChild("BottomRight")
	local openBtn = GuiResolve.sideToggleOpenButton(bottomRight, "DailyBtn")
	if not openBtn then return end
	local navBar    = GuiResolve.waitChild(bg, "NavBar")
	local closeBtn  = navBar and navBar:FindFirstChild("CloseBtn") :: GuiButton

	Screen.bind({
		guiName    = "DailyRewards",
		screen     = screen,
		container  = container,
		openButton = openBtn,
		closeButton = closeBtn,
	})
end

return DailyRewardsController
