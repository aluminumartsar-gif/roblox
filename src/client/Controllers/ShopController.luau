-- Wires the pack Shop ScreenGui open/close to HUD.SideButtons.ShopBtn.
-- Purchase button logic is handled globally by UIKit/Purchases.luau via
-- UIButton CollectionService tags + ProductId/ProductType child values
-- on each buy button.

local Players = game:GetService("Players")

local UIKit      = script.Parent.Parent:WaitForChild("UIKit")
local Screen     = require(UIKit:WaitForChild("Screen"))
local GuiResolve = require(UIKit:WaitForChild("GuiResolve"))

local ShopController = {}

function ShopController.start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local screen    = playerGui:WaitForChild("Shop")
	local container = GuiResolve.waitChild(screen, "Container")
	if not container or not container:IsA("GuiObject") then return end

	local sideButtons = playerGui:WaitForChild("HUD"):WaitForChild("SideButtons")
	local openBtn = GuiResolve.sideToggleOpenButton(sideButtons, "ShopBtn")
	if not openBtn then return end

	local background = container:FindFirstChild("Background")
	local navBar = background and background:FindFirstChild("NavBar")
	local closeBtn = navBar and navBar:FindFirstChild("CloseBtn") :: GuiButton?

	Screen.bind({
		guiName    = "Shop",
		screen     = screen,
		container  = container,
		openButton = openBtn,
		closeButton = closeBtn,
	})
end

return ShopController
