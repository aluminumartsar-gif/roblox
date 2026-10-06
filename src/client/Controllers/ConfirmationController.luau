-- Shell: ConfirmationPopup ScreenGui.
-- Opened programmatically with a message and Yes/No callbacks.
-- Used as a reusable confirm dialog by other controllers.
-- TODO: replace the makeSimpleModal inline dialogs with this once it is wired.

local Players = game:GetService("Players")

local UIKit     = script.Parent.Parent:WaitForChild("UIKit")
local UIManager = require(UIKit:WaitForChild("UIManager"))
local Screen    = require(UIKit:WaitForChild("Screen"))
local GuiResolve = require(UIKit:WaitForChild("GuiResolve"))

local ConfirmationController = {}

local handle: { open: () -> (), close: () -> () }?
local onYesCallback: (() -> ())?
local onNoCallback:  (() -> ())?

-- Programmatically open the popup with message text and callbacks.
function ConfirmationController.prompt(message: string, onYes: () -> (), onNo: (() -> ())?)
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local screen    = playerGui:WaitForChild("ConfirmationPopup")
	local container = GuiResolve.waitChild(screen, "Container")
	if not container or not container:IsA("GuiObject") then return end
	local bg        = GuiResolve.waitChild(container, "Background")
	if not bg then return end
	local content   = bg:FindFirstChild("Content")

	if content then
		local msgLabel = content:FindFirstChildWhichIsA("TextLabel") :: TextLabel?
		if msgLabel then msgLabel.Text = message end
	end

	onYesCallback = onYes
	onNoCallback  = onNo

	if handle then handle.open() end
end

function ConfirmationController.start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local screen    = playerGui:WaitForChild("ConfirmationPopup")
	local container = GuiResolve.waitChild(screen, "Container")
	if not container or not container:IsA("GuiObject") then return end
	local bg        = GuiResolve.waitChild(container, "Background")
	if not bg then return end
	local content   = bg:FindFirstChild("Content")

	local noBtn = content and content:FindFirstChild("No") :: GuiButton?
	local yesBtn = content and content:FindFirstChild("Yes") :: GuiButton?

	local dummyBtn = Instance.new("ImageButton")
	dummyBtn.Visible = false
	dummyBtn.Parent  = screen

	handle = Screen.bind({
		guiName    = "ConfirmationPopup",
		screen     = screen,
		container  = container,
		openButton = dummyBtn,
	})

	if yesBtn then
		yesBtn.Activated:Connect(function()
			if handle then handle.close() end
			if onYesCallback then
				local cb = onYesCallback
				onYesCallback = nil
				cb()
			end
		end)
	end

	if noBtn then
		noBtn.Activated:Connect(function()
			if handle then handle.close() end
			if onNoCallback then
				local cb = onNoCallback
				onNoCallback = nil
				cb()
			end
		end)
	end
end

return ConfirmationController
