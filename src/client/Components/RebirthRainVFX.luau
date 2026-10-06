--!strict
-- Fullscreen rain of falling rebirth icons played on a successful rebirth.
-- Call RebirthRainVFX.play(playerGui) once per rebirth; it is self-cleaning.

local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ICON_ID       = "rbxassetid://104402029372536"
local DISPLAY_ORDER = 100
local TOTAL_ICONS   = 30
local WAVE1_COUNT   = 18     -- spawned immediately
local LIFETIME      = 3.5    -- seconds before ScreenGui is destroyed

local ICON_SIZE_MIN = 50
local ICON_SIZE_MAX = 110
local FALL_DUR_MIN  = 1.0
local FALL_DUR_MAX  = 2.1
local SPIN_MIN      = 60     -- degrees per second
local SPIN_MAX      = 200
local WAVE2_MAX_DELAY = 0.65

local rng = Random.new()

local RebirthRainVFX = {}

local function makeIcon(parent: Frame): ImageLabel
	local size   = rng:NextInteger(ICON_SIZE_MIN, ICON_SIZE_MAX)
	local startX = rng:NextNumber(0.02, 0.98)
	local driftX = rng:NextNumber(-0.06, 0.06)

	local icon       = Instance.new("ImageLabel")
	icon.Name        = "RebirthIcon"
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position    = UDim2.new(startX, 0, -0.12, 0)
	icon.Size        = UDim2.fromOffset(size, size)
	icon.BackgroundTransparency = 1
	icon.Image       = ICON_ID
	icon.ImageColor3 = Color3.new(1, 1, 1)
	icon.ScaleType   = Enum.ScaleType.Fit
	icon.ZIndex      = 2
	icon.Parent      = parent

	-- Entrance pop
	local uiScale   = Instance.new("UIScale")
	uiScale.Scale   = 0.3
	uiScale.Parent  = icon
	TweenService:Create(
		uiScale,
		TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }
	):Play()

	-- Continuous spin
	local spinSpeed = rng:NextNumber(SPIN_MIN, SPIN_MAX)
	local spinDir   = if rng:NextInteger(0, 1) == 0 then 1 else -1
	local spinConn: RBXScriptConnection
	spinConn = RunService.Heartbeat:Connect(function(dt: number)
		if not icon.Parent then
			spinConn:Disconnect()
			return
		end
		icon.Rotation = (icon.Rotation + dt * spinSpeed * spinDir) % 360
	end)

	-- Fall tween
	local fallDur  = rng:NextNumber(FALL_DUR_MIN, FALL_DUR_MAX)
	local targetX  = math.clamp(startX + driftX, 0, 1)
	local tween = TweenService:Create(
		icon,
		TweenInfo.new(fallDur, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Position = UDim2.new(targetX, 0, 1.12, 0) }
	)
	tween:Play()

	-- Fade out in the final 35% of the fall
	task.delay(fallDur * 0.65, function()
		if not icon.Parent then return end
		TweenService:Create(
			icon,
			TweenInfo.new(fallDur * 0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ ImageTransparency = 1 }
		):Play()
	end)

	return icon
end

function RebirthRainVFX.play(playerGui: PlayerGui)
	local gui            = Instance.new("ScreenGui")
	gui.Name             = "RebirthRainVFX"
	gui.DisplayOrder     = DISPLAY_ORDER
	gui.ResetOnSpawn     = false
	gui.IgnoreGuiInset   = true
	gui.Parent           = playerGui

	local frame              = Instance.new("Frame")
	frame.Name               = "Rain"
	frame.Size               = UDim2.fromScale(1, 1)
	frame.BackgroundTransparency = 1
	frame.ClipsDescendants   = false
	frame.ZIndex             = 1
	frame.Parent             = gui

	-- Wave 1: burst of icons spawned immediately
	for _ = 1, WAVE1_COUNT do
		makeIcon(frame)
	end

	-- Wave 2: staggered tail
	for i = 1, TOTAL_ICONS - WAVE1_COUNT do
		local delay = rng:NextNumber(0.05, WAVE2_MAX_DELAY)
		task.delay(delay, function()
			if frame.Parent then
				makeIcon(frame)
			end
		end)
	end

	-- Auto-cleanup
	task.delay(LIFETIME, function()
		if gui.Parent then
			gui:Destroy()
		end
	end)
end

return RebirthRainVFX
