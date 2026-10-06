-- Shared open/close animation helper used by all pack-style popup screens.
-- Handles both ScreenGui.Enabled and Frame.Visible containers.

local Players      = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UIManager    = require(script.Parent.UIManager)

local DEFAULT_OPEN_SPEED  = 0.35
local DEFAULT_CLOSE_SPEED = 0.25

export type ScreenHandle = {
	open: () -> (),
	close: () -> (),
}

export type ScreenConfig = {
	guiName: string,
	screen: ScreenGui | Frame,
	container: GuiObject,
	openButton: GuiButton,
	closeButton: GuiButton?,
	openSpeed: number?,
	closeSpeed: number?,
}

local function bind(cfg: ScreenConfig): ScreenHandle
	-- Re-resolve the ScreenGui from PlayerGui in case the caller is holding a
	-- ghost reference: Roblox wipes and re-clones every ResetOnSpawn=true
	-- ScreenGui during the first character spawn, and any reference grabbed
	-- before that wipe is now parentless. Then mark ResetOnSpawn=false so
	-- future respawns don't repeat the trick and orphan our bindings.
	local screen: ScreenGui | Frame = cfg.screen
	if screen:IsA("ScreenGui") and screen.Parent == nil then
		local playerGui = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if playerGui then
			local live = playerGui:FindFirstChild(screen.Name)
			if live and live:IsA("ScreenGui") then
				screen = live
			end
		end
	end
	local isScreenGui = screen:IsA("ScreenGui")
	if isScreenGui then
		(screen :: ScreenGui).ResetOnSpawn = false
	end
	local fullSize    = cfg.container.Size
	local isOpen      = false

	local openInfo  = TweenInfo.new(
		cfg.openSpeed  or DEFAULT_OPEN_SPEED,
		Enum.EasingStyle.Back, Enum.EasingDirection.Out
	)
	local closeInfo = TweenInfo.new(
		cfg.closeSpeed or DEFAULT_CLOSE_SPEED,
		Enum.EasingStyle.Quad, Enum.EasingDirection.Out
	)

	local openTween  = TweenService:Create(cfg.container, openInfo,  { Size = fullSize })
	local closeTween = TweenService:Create(cfg.container, closeInfo, { Size = UDim2.new(0, 0, 0, 0) })

	local function setVisible(v: boolean)
		if isScreenGui then
			(screen :: ScreenGui).Enabled = v
		else
			(screen :: Frame).Visible = v
		end
	end

	local function initFrame()
		setVisible(false)
		cfg.container.Visible     = true
		cfg.container.AnchorPoint = Vector2.new(0.5, 0.5)
		cfg.container.Position    = UDim2.new(0.5, 0, 0.5, 0)
		cfg.container.Size        = UDim2.new(0, 0, 0, 0)
	end

	local function open()
		if isOpen then return end
		UIManager.closeAllExcept(cfg.guiName)
		isOpen = true
		UIManager.setOpen(cfg.guiName, true)
		setVisible(true)
		openTween:Play()
	end

	local function close()
		if not isOpen then return end
		closeTween:Play()
	end

	closeTween.Completed:Connect(function()
		isOpen = false
		UIManager.setOpen(cfg.guiName, false)
		setVisible(false)
	end)

	cfg.openButton.Activated:Connect(function()
		if isOpen then close() else open() end
	end)

	if cfg.closeButton then
		cfg.closeButton.Activated:Connect(close)
	end

	UIManager.register(cfg.guiName, close)
	initFrame()

	return { open = open, close = close }
end

return { bind = bind }
