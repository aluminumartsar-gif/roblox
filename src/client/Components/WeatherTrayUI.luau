-- Bottom-right HUD strip of currently-active weather effects. Each effect is a
-- small icon chip; hovering it (mouse only) reveals a tooltip with the name,
-- description, and a live countdown to expiry. Pop-in on add, fade-out on
-- remove. The same WeatherSchedule helper the server uses drives the
-- countdown so the tooltip is always exactly in sync with reality.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local WeatherConfig = require(ConfigFolder:WaitForChild("WeatherConfig"))
local IconAssets = require(ConfigFolder:WaitForChild("IconAssets"))

local Components = script.Parent
local IconImage = require(Components:WaitForChild("IconImage"))
local UIAnimations = require(Components:WaitForChild("UIAnimations"))

local WeatherTrayUI = {}
WeatherTrayUI.__index = WeatherTrayUI

-- Reference screen height used to derive proportional pixel sizes at runtime.
local REF_H = 1080
-- Chip height as a fraction of screen height. At 1080p → 88 px; scales up/down
-- with resolution. The tray height and each chip are re-computed whenever the
-- ScreenGui's AbsoluteSize changes so the HUD stays proportional on every device.
local CHIP_H_SCALE = 88 / REF_H
local CHIP_GAP_PX  = 8           -- gap between chips (pixels; scales with chip)
local TOOLTIP_OFFSET_Y = 12
local FADE_OUT_TIME = 0.18
local FADE_OUT_TWEEN = TweenInfo.new(FADE_OUT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local TEXT_PRIMARY = Color3.fromRGB(255, 255, 255)
local TEXT_SHADOW = Color3.fromRGB(0, 0, 0)
local TOOLTIP_BG = Color3.fromRGB(28, 30, 38)
local TOOLTIP_STROKE = Color3.fromRGB(0, 0, 0)

local function darken(color: Color3, amount: number): Color3
	return color:Lerp(Color3.new(0, 0, 0), amount)
end

local function addCorner(parent: Instance, radius: UDim)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = radius
	corner.Parent = parent
end

local function addStroke(parent: Instance, color: Color3, thickness: number, transparency: number?)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Transparency = transparency or 0
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = parent
	return stroke
end

local function addGradient(parent: Instance, topColor: Color3, bottomColor: Color3)
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, topColor),
		ColorSequenceKeypoint.new(1, bottomColor),
	})
	gradient.Rotation = 90
	gradient.Parent = parent
end

local function formatCountdown(seconds: number): string
	local clamped = math.max(0, math.floor(seconds + 0.5))
	local mins = math.floor(clamped / 60)
	local secs = clamped % 60
	return ("%d:%02d"):format(mins, secs)
end

-- Tooltip is parented to the tray ScreenGui rather than the chip so it can
-- escape the chip's clipping bounds and so its z-order is above neighbouring
-- chips. Position is set per-chip on hover.
local function buildTooltip(parent: ScreenGui): { frame: Frame, title: TextLabel, body: TextLabel, countdown: TextLabel }
	local frame = Instance.new("Frame")
	frame.Name = "WeatherTooltip"
	frame.AnchorPoint = Vector2.new(1, 1)
	-- 300×130 px at 1920×1080 reference → scale so the tooltip grows with screen size.
	frame.Size = UDim2.fromScale(300 / 1920, 130 / REF_H)
	frame.BackgroundColor3 = TOOLTIP_BG
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.ZIndex = 50
	frame.Parent = parent
	addCorner(frame, UDim.new(0.12, 0))
	addStroke(frame, TOOLTIP_STROKE, 2, 0.1)

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0.09, 0)
	padding.PaddingBottom = UDim.new(0.09, 0)
	padding.PaddingLeft = UDim.new(0.063, 0)
	padding.PaddingRight = UDim.new(0.063, 0)
	padding.Parent = frame

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0.023, 0)
	layout.Parent = frame

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.fromScale(1, 0.26)
	title.Font = Enum.Font.GothamBlack
	title.TextScaled = true
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = TEXT_PRIMARY
	title.TextStrokeColor3 = TEXT_SHADOW
	title.TextStrokeTransparency = 0.45
	title.Text = ""
	title.LayoutOrder = 1
	title.ZIndex = frame.ZIndex + 1
	title.Parent = frame

	local titleConstraint = Instance.new("UITextSizeConstraint")
	titleConstraint.MaxTextSize = 26
	titleConstraint.MinTextSize = 10
	titleConstraint.Parent = title

	local body = Instance.new("TextLabel")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Size = UDim2.fromScale(1, 0.21)
	body.Font = Enum.Font.GothamSemibold
	body.TextScaled = true
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.TextColor3 = Color3.fromRGB(220, 220, 230)
	body.Text = ""
	body.LayoutOrder = 2
	body.ZIndex = frame.ZIndex + 1
	body.Parent = frame

	local bodyConstraint = Instance.new("UITextSizeConstraint")
	bodyConstraint.MaxTextSize = 20
	bodyConstraint.MinTextSize = 9
	bodyConstraint.Parent = body

	local countdown = Instance.new("TextLabel")
	countdown.Name = "Countdown"
	countdown.BackgroundTransparency = 1
	countdown.Size = UDim2.fromScale(1, 0.21)
	countdown.Font = Enum.Font.GothamMedium
	countdown.TextScaled = true
	countdown.TextXAlignment = Enum.TextXAlignment.Left
	countdown.TextColor3 = Color3.fromRGB(170, 200, 255)
	countdown.Text = ""
	countdown.LayoutOrder = 3
	countdown.ZIndex = frame.ZIndex + 1
	countdown.Parent = frame

	local countdownConstraint = Instance.new("UITextSizeConstraint")
	countdownConstraint.MaxTextSize = 18
	countdownConstraint.MinTextSize = 8
	countdownConstraint.Parent = countdown

	return { frame = frame, title = title, body = body, countdown = countdown }
end

function WeatherTrayUI.new()
	local self = setmetatable({}, WeatherTrayUI)

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "WeatherTrayGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.DisplayOrder = 25
	gui.Parent = playerGui

	-- Right-aligned horizontal strip anchored to the right side of the screen.
	-- Width auto-sizes to fit the active chips; height is set in pixels derived
	-- from the screen resolution so everything scales like the rest of the HUD.
	local tray = Instance.new("Frame")
	tray.Name = "Tray"
	tray.AnchorPoint = Vector2.new(1, 1)
	tray.Position = UDim2.new(1, -12, 0.97, 0)
	tray.AutomaticSize = Enum.AutomaticSize.X
	tray.Size = UDim2.fromOffset(0, 88)   -- height overridden by _applyScale below
	tray.BackgroundTransparency = 1
	tray.Parent = gui

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, CHIP_GAP_PX)
	layout.Parent = tray

	self.gui = gui
	self.tray = tray
	self.tooltip = buildTooltip(gui)
	self.chipsById = {} :: { [string]: any }
	self.tooltipChipId = nil :: string?
	self.tooltipConnection = nil :: RBXScriptConnection?

	-- Recompute chip + tray pixel sizes from the live screen height. Called once
	-- on first frame (gui.AbsoluteSize is (0,0) before parenting) and again
	-- whenever the viewport is resized (PC window resize / tablet rotation).
	local function applyScale()
		local screenH = gui.AbsoluteSize.Y
		if screenH <= 0 then
			return
		end
		local chipPx = math.round(CHIP_H_SCALE * screenH)
		local gapPx  = math.max(4, math.round(chipPx * (CHIP_GAP_PX / 64)))
		tray.Size = UDim2.fromOffset(0, chipPx)
		layout.Padding = UDim.new(0, gapPx)
		for _, chip in self.chipsById do
			chip.button.Size = UDim2.fromOffset(chipPx, chipPx)
		end
	end

	self._applyScale = applyScale

	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyScale)
	task.defer(applyScale)

	return self
end

local function refreshTooltipText(self, chipId: string)
	local chip = self.chipsById[chipId]
	if not chip then
		return
	end

	local weather = WeatherConfig.EFFECTS[chipId]
	if not weather then
		return
	end

	self.tooltip.title.Text = weather.displayName
	self.tooltip.body.Text = weather.description
	local remaining = math.max(0, chip.expiresAt - os.time())
	self.tooltip.countdown.Text = formatCountdown(remaining) .. " remaining"
end

local function positionTooltip(self, chip)
	local chipPos = chip.button.AbsolutePosition
	local chipSize = chip.button.AbsoluteSize
	local guiInsetY = self.gui.IgnoreGuiInset and 0 or 36

	-- Tooltip anchor is bottom-right, so position to the chip's top-right
	-- corner so the tooltip floats up above and aligned right with the chip.
	local x = chipPos.X + chipSize.X
	local y = chipPos.Y - TOOLTIP_OFFSET_Y - guiInsetY
	local guiSize = self.gui.AbsoluteSize
	self.tooltip.frame.Position = UDim2.fromScale(x / guiSize.X, y / guiSize.Y)
end

local function showTooltip(self, chipId: string)
	local chip = self.chipsById[chipId]
	if not chip then
		return
	end

	self.tooltipChipId = chipId
	refreshTooltipText(self, chipId)
	positionTooltip(self, chip)
	self.tooltip.frame.Visible = true

	if self.tooltipConnection then
		self.tooltipConnection:Disconnect()
	end
	self.tooltipConnection = RunService.Heartbeat:Connect(function()
		if self.tooltipChipId ~= chipId then
			return
		end
		refreshTooltipText(self, chipId)
		positionTooltip(self, chip)
	end)
end

local function hideTooltip(self, chipId: string?)
	if chipId and self.tooltipChipId ~= chipId then
		return
	end

	self.tooltipChipId = nil
	self.tooltip.frame.Visible = false
	if self.tooltipConnection then
		self.tooltipConnection:Disconnect()
		self.tooltipConnection = nil
	end
end

local function buildChip(self, weather: WeatherConfig.WeatherEffect, expiresAt: number)
	local button = Instance.new("ImageButton")
	button.Name = "WeatherChip_" .. weather.id
	button.AnchorPoint = Vector2.new(0, 0)
	-- Pixel size is set by _applyScale (called right after this returns).
	-- 88 is the fallback if AbsoluteSize hasn't been computed yet.
	local chipPx = math.max(88, math.round(CHIP_H_SCALE * self.gui.AbsoluteSize.Y))
	button.Size = UDim2.fromOffset(chipPx, chipPx)
	button.BackgroundColor3 = weather.tintColor
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.Image = ""
	button.LayoutOrder = 1
	button.Parent = self.tray

	addCorner(button, UDim.new(0.5, 0))
	addGradient(button, weather.tintColor, darken(weather.tintColor, 0.25))
	addStroke(button, darken(weather.tintColor, 0.55), 2, 0.1)

	local icon = IconImage.add(button, weather.iconName :: any, {
		name = "WeatherIcon",
		anchorPoint = Vector2.new(0.5, 0.5),
		position = UDim2.fromScale(0.5, 0.5),
		size = UDim2.fromScale(0.7, 0.7),
	})
	-- IconAssets entries default to rbxassetid://0 until the bulk-import
	-- flow populates them, so guard against a missing entry without crashing
	-- the whole HUD.
	if not IconAssets[weather.iconName :: any] then
		icon.ImageColor3 = TEXT_PRIMARY
	end

	UIAnimations.popIn(button, { duration = 0.28, fromScale = 0.4 })

	button.MouseEnter:Connect(function()
		showTooltip(self, weather.id)
	end)
	button.MouseLeave:Connect(function()
		hideTooltip(self, weather.id)
	end)

	return { button = button, expiresAt = expiresAt }
end

-- Public: show or refresh a chip for the given effect id.
function WeatherTrayUI:show(id: string, expiresAt: number)
	local weather = WeatherConfig.EFFECTS[id]
	if not weather then
		return
	end

	local existing = self.chipsById[id]
	if existing then
		existing.expiresAt = expiresAt
		if self.tooltipChipId == id then
			refreshTooltipText(self, id)
		end
		return
	end

	self.chipsById[id] = buildChip(self, weather, expiresAt)
	-- Re-apply pixel sizes so the new chip is immediately the right size.
	if self._applyScale then
		self._applyScale()
	end
end

-- Public: tear down a chip when its effect ends.
function WeatherTrayUI:hide(id: string)
	local chip = self.chipsById[id]
	if not chip then
		return
	end

	self.chipsById[id] = nil
	if self.tooltipChipId == id then
		hideTooltip(self, id)
	end

	-- Fade out and destroy. UIScale tween for the chip; setting a tween on a
	-- non-existent UIScale would be a no-op, so push it through transparency.
	local button = chip.button
	local fade = TweenService:Create(button, FADE_OUT_TWEEN, {
		ImageTransparency = 1,
		BackgroundTransparency = 1,
	})
	fade:Play()
	fade.Completed:Once(function()
		if button and button.Parent then
			button:Destroy()
		end
	end)
end

function WeatherTrayUI:Destroy()
	hideTooltip(self, nil)
	if self.gui then
		self.gui:Destroy()
		self.gui = nil
	end
end

return WeatherTrayUI
