--!strict
-- Reusable UI animation helpers used across HUD panels and buttons.
-- Goal: keep tween logic consistent (durations, easing, cleanup) so the whole
-- HUD has the same playful, bouncy personality regardless of who built the UI.

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local UIAnimations = {}

local POP_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0, false, 0)
local SETTLE_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function getOrAddScale(parent: Instance): UIScale
	local existing = parent:FindFirstChildOfClass("UIScale")
	if existing then
		return existing
	end

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = parent

	return scale
end

local function isMouseOrTouchInput(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

-- Bouncy "pop in" entrance. Plays once on call.
function UIAnimations.popIn(instance: GuiObject, options: { delay: number?, fromScale: number?, duration: number? }?)
	local fromScale = (options and options.fromScale) or 0.6
	local delaySeconds = (options and options.delay) or 0
	local duration = (options and options.duration) or 0.32

	local scale = getOrAddScale(instance)
	scale.Scale = fromScale

	task.delay(delaySeconds, function()
		if not instance.Parent then
			return
		end

		TweenService:Create(scale, TweenInfo.new(duration, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Scale = 1,
		}):Play()
	end)
end

-- Hover bounce + optional rotation tilt. Releases the press state cleanly when
-- the cursor leaves the button mid-press.
function UIAnimations.bindHover(button: GuiButton, options: {
	hoverScale: number?,
	pressScale: number?,
	tiltDegrees: number?,
}?)
	local hoverScale = (options and options.hoverScale) or 1.07
	local pressScale = (options and options.pressScale) or 0.93
	local tiltDegrees = (options and options.tiltDegrees) or 0

	local scale = getOrAddScale(button)
	local baseRotation = button.Rotation
	local hovered = false
	local pressed = false

	local function refreshTween()
		local targetScale = if pressed then pressScale elseif hovered then hoverScale else 1
		local targetRotation = if hovered and not pressed then baseRotation + tiltDegrees else baseRotation
		local tweenInfo = if pressed then PRESS_TWEEN elseif hovered then POP_TWEEN else SETTLE_TWEEN

		TweenService:Create(scale, tweenInfo, { Scale = targetScale }):Play()
		TweenService:Create(button, tweenInfo, { Rotation = targetRotation }):Play()
	end

	button.MouseEnter:Connect(function()
		hovered = true
		refreshTween()
	end)

	button.MouseLeave:Connect(function()
		hovered = false
		pressed = false
		refreshTween()
	end)

	button.InputBegan:Connect(function(input: InputObject)
		if not isMouseOrTouchInput(input) then
			return
		end

		pressed = true
		if input.UserInputType == Enum.UserInputType.Touch then
			hovered = true
		end
		refreshTween()
	end)

	button.InputEnded:Connect(function(input: InputObject)
		if not isMouseOrTouchInput(input) then
			return
		end

		pressed = false
		if input.UserInputType == Enum.UserInputType.Touch then
			hovered = false
		end
		refreshTween()
	end)
end

-- Gentle vertical bobbing. Returns a cancel function so callers can stop the
-- animation when their owning instance is destroyed.
function UIAnimations.bindIdleFloat(instance: GuiObject, options: { amplitude: number?, period: number?, phase: number? }?): () -> ()
	local amplitude = (options and options.amplitude) or 4
	local period = (options and options.period) or 1.8
	local phase = (options and options.phase) or 0
	local startPosition = instance.Position
	local cancelled = false

	local connection: RBXScriptConnection
	connection = RunService.Heartbeat:Connect(function()
		if cancelled or not instance.Parent then
			connection:Disconnect()
			return
		end

		local offset = math.sin((os.clock() + phase) * (math.pi * 2) / period) * amplitude
		instance.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset, startPosition.Y.Scale, startPosition.Y.Offset + offset)
	end)

	return function()
		cancelled = true
		instance.Position = startPosition
		if connection.Connected then
			connection:Disconnect()
		end
	end
end

-- Pulses a UIScale up and down forever. Useful for "look at me" buttons.
function UIAnimations.bindIdlePulse(instance: GuiObject, options: { peakScale: number?, period: number? }?)
	local peakScale = (options and options.peakScale) or 1.05
	local period = (options and options.period) or 1.4
	local scale = getOrAddScale(instance)

	task.spawn(function()
		while instance.Parent do
			TweenService:Create(scale, TweenInfo.new(period * 0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
				Scale = peakScale,
			}):Play()
			task.wait(period * 0.5)
			TweenService:Create(scale, TweenInfo.new(period * 0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
				Scale = 1,
			}):Play()
			task.wait(period * 0.5)
		end
	end)
end

-- Slowly spins an icon, used for the rebirth/loading icons.
function UIAnimations.bindIdleSpin(instance: GuiObject, options: { degreesPerSecond: number? }?): () -> ()
	local degreesPerSecond = (options and options.degreesPerSecond) or 18
	local cancelled = false

	local connection: RBXScriptConnection
	connection = RunService.Heartbeat:Connect(function(deltaTime: number)
		if cancelled or not instance.Parent then
			connection:Disconnect()
			return
		end

		instance.Rotation = (instance.Rotation + deltaTime * degreesPerSecond) % 360
	end)

	return function()
		cancelled = true
		if connection.Connected then
			connection:Disconnect()
		end
	end
end

-- Diagonal shine bar that periodically sweeps across the parent. Implemented
-- as a UIGradient on a transparent overlay frame so the sweep is naturally
-- masked to the parent's exact shape (rounded corners, etc.) without relying
-- on ClipsDescendants — which doesn't reliably clip rotated children and was
-- letting tall white streaks bleed past button bounds.
function UIAnimations.addShineSweep(parent: GuiObject, options: {
	intervalSeconds: number?,
	travelSeconds: number?,
	intensity: number?,
}?): Frame
	local intervalSeconds = (options and options.intervalSeconds) or 4
	local travelSeconds = (options and options.travelSeconds) or 0.7
	local intensity = (options and options.intensity) or 0.55

	local overlay = Instance.new("Frame")
	overlay.Name = "ShineOverlay"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Color3.new(1, 1, 1)
	overlay.BackgroundTransparency = 1 - intensity
	overlay.BorderSizePixel = 0
	overlay.ZIndex = (parent.ZIndex or 1) + 5
	overlay.Parent = parent

	-- Mirror the parent's UICorner so the overlay tucks inside rounded edges.
	local parentCorner = parent:FindFirstChildOfClass("UICorner")
	if parentCorner then
		local overlayCorner = Instance.new("UICorner")
		overlayCorner.CornerRadius = parentCorner.CornerRadius
		overlayCorner.Parent = overlay
	end

	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 20
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.45, 1),
		NumberSequenceKeypoint.new(0.5, 0.1),
		NumberSequenceKeypoint.new(0.55, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Offset = Vector2.new(-1.2, 0)
	gradient.Parent = overlay

	task.spawn(function()
		while overlay.Parent do
			task.wait(intervalSeconds)
			if not overlay.Parent then
				return
			end

			gradient.Offset = Vector2.new(-1.2, 0)
			TweenService:Create(gradient, TweenInfo.new(travelSeconds, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
				Offset = Vector2.new(1.2, 0),
			}):Play()
		end
	end)

	return overlay
end

-- Soft outer glow drawn as an extra UIStroke that gently pulses opacity.
function UIAnimations.addGlowStroke(parent: GuiObject, color: Color3, options: {
	thickness: number?,
	period: number?,
	minTransparency: number?,
	maxTransparency: number?,
}?): UIStroke
	local thickness = (options and options.thickness) or 6
	local period = (options and options.period) or 1.6
	local minTransparency = (options and options.minTransparency) or 0.45
	local maxTransparency = (options and options.maxTransparency) or 0.85

	local stroke = Instance.new("UIStroke")
	stroke.Name = "GlowStroke"
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Transparency = maxTransparency
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = parent

	task.spawn(function()
		while stroke.Parent do
			TweenService:Create(stroke, TweenInfo.new(period * 0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
				Transparency = minTransparency,
			}):Play()
			task.wait(period * 0.5)
			TweenService:Create(stroke, TweenInfo.new(period * 0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
				Transparency = maxTransparency,
			}):Play()
			task.wait(period * 0.5)
		end
	end)

	return stroke
end

-- Animates a panel "in" with a bouncy scale + fade.
function UIAnimations.openPanel(panel: GuiObject, options: { duration: number?, fromScale: number? }?)
	local duration = (options and options.duration) or 0.28
	local fromScale = (options and options.fromScale) or 0.5

	local scale = getOrAddScale(panel)
	scale.Scale = fromScale
	panel.Visible = true

	TweenService:Create(scale, TweenInfo.new(duration, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1,
	}):Play()
end

-- Animates a panel "out", hiding it after the tween settles.
function UIAnimations.closePanel(panel: GuiObject, options: { duration: number?, toScale: number? }?)
	local duration = (options and options.duration) or 0.18
	local toScale = (options and options.toScale) or 0.6

	local scale = getOrAddScale(panel)
	local tween = TweenService:Create(scale, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Scale = toScale,
	})
	tween:Play()
	tween.Completed:Once(function()
		panel.Visible = false
		scale.Scale = 1
	end)
end

-- Quick "kick" used to acknowledge value changes (e.g. luck multiplier).
function UIAnimations.bump(instance: GuiObject, options: { peakScale: number?, duration: number? }?)
	local peakScale = (options and options.peakScale) or 1.18
	local duration = (options and options.duration) or 0.22

	local scale = getOrAddScale(instance)
	scale.Scale = peakScale
	TweenService:Create(scale, TweenInfo.new(duration, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1,
	}):Play()
end

-- Helper for callers that don't want to pull UserInputService themselves when
-- they need to know if the current device supports hover.
function UIAnimations.hasHover(): boolean
	return UserInputService.MouseEnabled
end

return UIAnimations
