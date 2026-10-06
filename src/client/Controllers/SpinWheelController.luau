-- Shell: SpinWheel ScreenGui.
-- No direct HUD button; opened programmatically.
-- TODO: wire open/close to a SpinWheelService trigger when that feature exists.

local Players = game:GetService("Players")

local UIKit      = script.Parent.Parent:WaitForChild("UIKit")
local UIManager  = require(UIKit:WaitForChild("UIManager"))

local SpinWheelController = {}

local closeHandle: (() -> ())?

function SpinWheelController.open()
	if closeHandle then
		UIManager.closeAllExcept("SpinWheel")
	end
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local screen    = playerGui:WaitForChild("SpinWheel")
	screen.Enabled  = true
end

function SpinWheelController.close()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local screen    = playerGui:FindFirstChild("SpinWheel") :: ScreenGui?
	if screen then
		screen.Enabled = false
	end
end

function SpinWheelController.start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	-- Wait until after the first character spawn so the ResetOnSpawn=true
	-- re-clone has settled; otherwise we'd hold a parentless ghost reference.
	if not Players.LocalPlayer.Character then
		Players.LocalPlayer.CharacterAdded:Wait()
	end
	local screen = playerGui:FindFirstChild("SpinWheel") :: ScreenGui?
	if not screen then
		screen = (playerGui:WaitForChild("SpinWheel", 30) :: ScreenGui?)
	end
	if not screen then
		warn("[SpinWheel] ScreenGui not present in PlayerGui; controller disabled.")
		return
	end
	-- Keep across respawns so the registered close handler stays meaningful.
	screen.ResetOnSpawn = false
	screen.Enabled      = false
	UIManager.register("SpinWheel", SpinWheelController.close)
end

return SpinWheelController
