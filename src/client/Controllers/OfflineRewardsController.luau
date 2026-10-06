-- Shell: OfflineRewardsPopup ScreenGui.
-- Opened programmatically when the server signals offline earnings are ready.
-- TODO: wire to an OfflineEarningsService remote when server-side support exists.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local UIKit     = script.Parent.Parent:WaitForChild("UIKit")
local UIManager = require(UIKit:WaitForChild("UIManager"))
local GuiResolve = require(UIKit:WaitForChild("GuiResolve"))

local OfflineRewardsController = {}

local OPEN_INFO  = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local screen: ScreenGui?
local container: GuiObject?
local isOpen = false

local function close()
	if not isOpen or not container or not screen then return end
	local tween = TweenService:Create(container, CLOSE_INFO, { Size = UDim2.new(0, 0, 0, 0) })
	tween:Play()
	tween.Completed:Connect(function()
		isOpen = false
		if screen then screen.Enabled = false end
	end)
end

function OfflineRewardsController.open()
	if not screen or not container then return end
	UIManager.closeAllExcept("OfflineRewardsPopup")
	isOpen = true
	screen.Enabled = true
	TweenService:Create(container, OPEN_INFO, { Size = container:GetAttribute("FullSize") and
		UDim2.fromOffset(container:GetAttribute("FullSize_X"), container:GetAttribute("FullSize_Y"))
		or container.Size
	}):Play()
end

function OfflineRewardsController.start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local screenGui = playerGui:WaitForChild("OfflineRewardsPopup")
	local waited = GuiResolve.waitChild(screenGui, "Container")
	if not waited or not waited:IsA("GuiObject") then
		warn('[OfflineRewards] Expected ScreenGui "OfflineRewardsPopup" with child "Container". Popup disabled.')
		screen = nil
		container = nil
		return
	end

	-- Re-resolve the live ScreenGui in case our reference was orphaned by the
	-- first-spawn re-clone of ResetOnSpawn=true ScreenGuis.
	if waited.Parent and waited.Parent:IsA("ScreenGui") then
		screenGui = waited.Parent :: ScreenGui
	end

	screen = screenGui :: ScreenGui
	container = waited :: GuiObject

	-- Keep this ScreenGui across respawns; otherwise Roblox destroys and re-clones
	-- a fresh copy from StarterGui, leaving our remote-driven open() dead.
	(screen :: ScreenGui).ResetOnSpawn = false

	local fullSize = container.Size
	container:SetAttribute("FullSize_X", fullSize.X.Offset)
	container:SetAttribute("FullSize_Y", fullSize.Y.Offset)

	screen.Enabled        = false
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Position    = UDim2.new(0.5, 0, 0.5, 0)
	container.Size        = UDim2.new(0, 0, 0, 0)
	container.Visible     = true

	local bg = container:FindFirstChild("Background")
	local content = bg and bg:FindFirstChild("Content")
	local noBtn = content and content:FindFirstChild("No") :: GuiButton?
	if noBtn then
		noBtn.Activated:Connect(close)
	end

	UIManager.register("OfflineRewardsPopup", close)
	-- TODO: connect to server remote that fires when offline rewards are calculated
end

return OfflineRewardsController
