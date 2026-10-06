-- Shell: open/close Rewards ScreenGui from HUD.SideButtons.GiftBtn.
-- TODO: wire to a RewardsService when server-side rewards tracking exists.

local Players = game:GetService("Players")

local UIKit      = script.Parent.Parent:WaitForChild("UIKit")
local Screen     = require(UIKit:WaitForChild("Screen"))
local GuiResolve = require(UIKit:WaitForChild("GuiResolve"))

local RewardsController = {}

function RewardsController.start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local screen    = playerGui:WaitForChild("Rewards")
	local container = GuiResolve.waitChild(screen, "Container")
	if not container or not container:IsA("GuiObject") then return end
	local bg        = GuiResolve.waitChild(container, "Background")
	if not bg then return end
	local sideButtons = playerGui:WaitForChild("HUD"):WaitForChild("SideButtons")
	local openBtn = GuiResolve.sideToggleOpenButton(sideButtons, "GiftBtn")
	if not openBtn then return end
	local navBar    = GuiResolve.waitChild(bg, "NavBar")
	local closeBtn  = navBar and navBar:FindFirstChild("CloseBtn") :: GuiButton

	Screen.bind({
		guiName    = "Rewards",
		screen     = screen,
		container  = container,
		openButton = openBtn,
		closeButton = closeBtn,
	})
end

return RewardsController
