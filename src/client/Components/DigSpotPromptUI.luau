local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

-- World-space billboard that hovers above the active dig spot. Owns its own
-- anchor part + BillboardGui and exposes two layouts:
--
--   findPhase  - shows "1/3 ... 3/3" progress while the player is still
--                clicking the ground to find the brainrot.
--   claimPhase - replaces the progress with a large PULL UP button, a
--                smaller "Dig deeper" risk button, current luck multiplier,
--                clear "X% chance to break shovel" text, and a CANCEL button.
--
-- The controller updates the prompt via :update(state) whenever the server
-- pushes a fresh dig state remote.

local DigSpotPromptUI = {}
DigSpotPromptUI.__index = DigSpotPromptUI

local PROMPT_OFFSET = Vector3.new(0, 6.5, 0)
-- Billboard hosts a panel + a timer "tab" above it. The extra height covers
-- the timer area so the panel layouts can keep their original geometry.
local PANEL_HEIGHT = 150
local TIMER_HEIGHT = 30
local TIMER_GAP = 4
local BILLBOARD_SIZE = UDim2.fromOffset(220, PANEL_HEIGHT + TIMER_HEIGHT + TIMER_GAP)
local BILLBOARD_STUDS_OFFSET = Vector3.new(0, 0, 0)
local BILLBOARD_LIGHT_INFLUENCE = 0
local BILLBOARD_DEPTH_TEST = false

local PANEL_BG_TOP = Color3.fromRGB(34, 26, 18)
local PANEL_BG_BOTTOM = Color3.fromRGB(20, 14, 10)
local PANEL_STROKE = Color3.fromRGB(220, 132, 32)

local TITLE_COLOR = Color3.fromRGB(255, 240, 200)
local PROGRESS_DOT_ACTIVE = Color3.fromRGB(255, 200, 92)
local PROGRESS_DOT_INACTIVE = Color3.fromRGB(80, 60, 40)

local PULL_UP_BG = Color3.fromRGB(255, 200, 92)
local PULL_UP_BG_BOTTOM = Color3.fromRGB(220, 132, 32)
local PULL_UP_TEXT = Color3.fromRGB(48, 22, 4)
local PULL_UP_STROKE = Color3.fromRGB(118, 60, 8)

local DIG_MORE_BG = Color3.fromRGB(72, 38, 30)
local DIG_MORE_BG_BOTTOM = Color3.fromRGB(56, 26, 22)
local DIG_MORE_STROKE = Color3.fromRGB(168, 64, 56)
local DIG_MORE_TEXT = Color3.fromRGB(255, 220, 210)

local CANCEL_BG = Color3.fromRGB(46, 38, 34)
local CANCEL_TEXT = Color3.fromRGB(220, 210, 198)
local CANCEL_STROKE = Color3.fromRGB(86, 74, 66)

local LUCK_TEXT_COLOR = Color3.fromRGB(255, 220, 130)
local LUCK_TEXT_DIM_COLOR = Color3.fromRGB(184, 162, 116)
local RISK_TEXT_COLOR = Color3.fromRGB(255, 196, 188)

-- Timer tab visuals. Sits above the main panel and counts down the dig
-- session deadline. Color shifts from neutral -> warning -> danger as the
-- remaining time drops past the thresholds below.
local TIMER_BG_NEUTRAL = Color3.fromRGB(28, 22, 16)
local TIMER_BG_WARNING = Color3.fromRGB(112, 50, 18)
local TIMER_BG_DANGER = Color3.fromRGB(168, 28, 28)
local TIMER_STROKE_NEUTRAL = Color3.fromRGB(220, 132, 32)
local TIMER_STROKE_DANGER = Color3.fromRGB(255, 132, 132)
local TIMER_TEXT_COLOR = Color3.fromRGB(255, 240, 200)
local TIMER_WARNING_THRESHOLD = 10
local TIMER_DANGER_THRESHOLD = 5

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

local function addGradient(parent: Instance, top: Color3, bottom: Color3): UIGradient
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, top),
		ColorSequenceKeypoint.new(1, bottom),
	})
	g.Rotation = 90
	g.Parent = parent
	return g
end

local function makeAnchor(): BasePart
	local part = Instance.new("Part")
	part.Name = "DigSpotPromptAnchor"
	part.Size = Vector3.new(0.1, 0.1, 0.1)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.Transparency = 1
	part.Parent = Workspace
	return part
end

local function formatLuck(luck: number): string
	if luck >= 10 then
		return ("x%d LUCK"):format(math.floor(luck + 0.5))
	end
	return ("x%.1f LUCK"):format(luck)
end

local function formatCountdown(seconds: number): string
	local clamped = math.max(0, seconds)
	if clamped < 10 then
		return ("%.1fs"):format(clamped)
	end
	return ("%ds"):format(math.ceil(clamped))
end

local function buildTimerBadge(parent: Instance)
	local frame = Instance.new("Frame")
	frame.Name = "TimerBadge"
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, 0, 0)
	frame.Size = UDim2.fromScale(0.5, 0.163)
	frame.BackgroundColor3 = TIMER_BG_NEUTRAL
	frame.BackgroundTransparency = 0.05
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = parent
	addCorner(frame, UDim.new(0.4, 0))
	local stroke = addStroke(frame, TIMER_STROKE_NEUTRAL, 2, 0.05)

	local label = Instance.new("TextLabel")
	label.Name = "TimerLabel"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(0.92, 0.92)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.Text = "30s"
	label.TextColor3 = TIMER_TEXT_COLOR
	label.TextScaled = true
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextStrokeTransparency = 0.4
	label.Parent = frame

	return {
		frame = frame,
		stroke = stroke,
		label = label,
	}
end

local function buildFindLayout(parent: Instance)
	local container = Instance.new("Frame")
	container.Name = "FindLayout"
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Position = UDim2.fromScale(0.5, 0.5)
	container.Size = UDim2.fromScale(1, 1)
	container.BackgroundTransparency = 1
	container.Visible = false
	container.Parent = parent

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.fromScale(0.5, 0.053)
	title.Size = UDim2.fromScale(0.927, 0.16)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBlack
	title.Text = "DIGGING..."
	title.TextColor3 = TITLE_COLOR
	title.TextScaled = true
	title.TextStrokeColor3 = Color3.new(0, 0, 0)
	title.TextStrokeTransparency = 0.4
	title.Parent = container

	local hint = Instance.new("TextLabel")
	hint.Name = "Hint"
	hint.AnchorPoint = Vector2.new(0.5, 1)
	hint.Position = UDim2.fromScale(0.5, 0.933)
	hint.Size = UDim2.fromScale(0.927, 0.12)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.GothamBold
	hint.Text = "CLICK GROUND TO DIG"
	hint.TextColor3 = TITLE_COLOR
	hint.TextScaled = true
	hint.TextStrokeColor3 = Color3.new(0, 0, 0)
	hint.TextStrokeTransparency = 0.45
	hint.Parent = container

	local dotsRow = Instance.new("Frame")
	dotsRow.Name = "Dots"
	dotsRow.AnchorPoint = Vector2.new(0.5, 0.5)
	dotsRow.Position = UDim2.fromScale(0.5, 0.5)
	dotsRow.Size = UDim2.fromScale(0.873, 0.213)
	dotsRow.BackgroundTransparency = 1
	dotsRow.Parent = container

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0.052, 0)
	layout.Parent = dotsRow

	return {
		container = container,
		title = title,
		hint = hint,
		dotsRow = dotsRow,
		dots = {},
	}
end

local function buildClaimLayout(parent: Instance)
	local container = Instance.new("Frame")
	container.Name = "ClaimLayout"
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Position = UDim2.fromScale(0.5, 0.5)
	container.Size = UDim2.fromScale(1, 1)
	container.BackgroundTransparency = 1
	container.Visible = false
	container.Parent = parent

	local luckLabel = Instance.new("TextLabel")
	luckLabel.Name = "LuckLabel"
	luckLabel.AnchorPoint = Vector2.new(0.5, 0)
	luckLabel.Position = UDim2.fromScale(0.5, 0.04)
	luckLabel.Size = UDim2.fromScale(0.927, 0.12)
	luckLabel.BackgroundTransparency = 1
	luckLabel.Font = Enum.Font.GothamBlack
	luckLabel.Text = "x1.0 LUCK"
	luckLabel.TextColor3 = LUCK_TEXT_DIM_COLOR
	luckLabel.TextScaled = true
	luckLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	luckLabel.TextStrokeTransparency = 0.4
	luckLabel.Parent = container

	local pullUpButton = Instance.new("TextButton")
	pullUpButton.Name = "PullUpButton"
	pullUpButton.AnchorPoint = Vector2.new(0.5, 0)
	pullUpButton.Position = UDim2.fromScale(0.5, 0.187)
	pullUpButton.Size = UDim2.fromScale(0.909, 0.293)
	pullUpButton.BackgroundColor3 = PULL_UP_BG
	pullUpButton.AutoButtonColor = false
	pullUpButton.BorderSizePixel = 0
	pullUpButton.Font = Enum.Font.GothamBlack
	pullUpButton.Text = "PULL UP BRAINROT"
	pullUpButton.TextColor3 = PULL_UP_TEXT
	pullUpButton.TextScaled = true
	pullUpButton.TextStrokeColor3 = Color3.fromRGB(255, 248, 220)
	pullUpButton.TextStrokeTransparency = 0.55
	pullUpButton.Parent = container
	addCorner(pullUpButton, UDim.new(0.23, 0))
	addGradient(pullUpButton, PULL_UP_BG, PULL_UP_BG_BOTTOM)
	addStroke(pullUpButton, PULL_UP_STROKE, 2, 0.05)

	local digMoreButton = Instance.new("TextButton")
	digMoreButton.Name = "DigMoreButton"
	digMoreButton.AnchorPoint = Vector2.new(0, 1)
	digMoreButton.Position = UDim2.fromScale(0.036, 0.947)
	digMoreButton.Size = UDim2.fromScale(0.59, 0.24)
	digMoreButton.BackgroundColor3 = DIG_MORE_BG
	digMoreButton.AutoButtonColor = false
	digMoreButton.BorderSizePixel = 0
	digMoreButton.Font = Enum.Font.GothamBold
	digMoreButton.Text = "DIG DEEPER\n0% chance to break"
	digMoreButton.TextColor3 = DIG_MORE_TEXT
	digMoreButton.TextScaled = true
	digMoreButton.TextStrokeColor3 = Color3.new(0, 0, 0)
	digMoreButton.TextStrokeTransparency = 0.45
	digMoreButton.Parent = container
	addCorner(digMoreButton, UDim.new(0.22, 0))
	addGradient(digMoreButton, DIG_MORE_BG, DIG_MORE_BG_BOTTOM)
	addStroke(digMoreButton, DIG_MORE_STROKE, 2, 0.1)

	local cancelButton = Instance.new("TextButton")
	cancelButton.Name = "CancelButton"
	cancelButton.AnchorPoint = Vector2.new(1, 1)
	cancelButton.Position = UDim2.fromScale(0.964, 0.947)
	cancelButton.Size = UDim2.fromScale(0.313, 0.24)
	cancelButton.BackgroundColor3 = CANCEL_BG
	cancelButton.AutoButtonColor = false
	cancelButton.BorderSizePixel = 0
	cancelButton.Font = Enum.Font.GothamBold
	cancelButton.Text = "CANCEL"
	cancelButton.TextColor3 = CANCEL_TEXT
	cancelButton.TextScaled = true
	cancelButton.TextStrokeColor3 = Color3.new(0, 0, 0)
	cancelButton.TextStrokeTransparency = 0.45
	cancelButton.Parent = container
	addCorner(cancelButton, UDim.new(0.22, 0))
	addStroke(cancelButton, CANCEL_STROKE, 2, 0.2)

	return {
		container = container,
		luckLabel = luckLabel,
		pullUpButton = pullUpButton,
		digMoreButton = digMoreButton,
		cancelButton = cancelButton,
	}
end

function DigSpotPromptUI.new()
	local self = setmetatable({}, DigSpotPromptUI)

	local localPlayer = Players.LocalPlayer
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local anchor = makeAnchor()

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DigSpotPrompt"
	billboard.Adornee = anchor
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = BILLBOARD_LIGHT_INFLUENCE
	billboard.ResetOnSpawn = false
	billboard.Size = BILLBOARD_SIZE
	billboard.StudsOffsetWorldSpace = BILLBOARD_STUDS_OFFSET
	billboard.MaxDistance = 60
	billboard.Active = true
	if BILLBOARD_DEPTH_TEST then
		billboard.AlwaysOnTop = false
	end
	-- Mounting under PlayerGui keeps it from being deleted by the workspace
	-- sanitizers / drop cleanup that scrub random BillboardGuis from
	-- BrainrotDrops, while the Adornee anchor pins it in 3D space.
	billboard.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	-- Anchored to the bottom of the BillboardGui so the timer badge can sit
	-- in the reserved area above without overlapping the existing layouts.
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.new(0.5, 0, 1, 0)
	panel.Size = UDim2.fromScale(1, 0.815)
	panel.BackgroundColor3 = PANEL_BG_TOP
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.Parent = billboard
	addCorner(panel, UDim.new(0.12, 0))
	addGradient(panel, PANEL_BG_TOP, PANEL_BG_BOTTOM)
	addStroke(panel, PANEL_STROKE, 3, 0.1)

	local timer = buildTimerBadge(billboard)
	local find = buildFindLayout(panel)
	local claim = buildClaimLayout(panel)

	self._localPlayer = localPlayer
	self._anchor = anchor
	self._billboard = billboard
	self._panel = panel
	self._find = find
	self._claim = claim
	self._timer = timer
	self._timerDeadline = nil
	self._timerHeartbeat = nil
	self._isShown = false
	self._currentDots = 0
	self._onPullUp = nil
	self._onDigMore = nil
	self._onCancel = nil

	billboard.Enabled = false

	claim.pullUpButton.Activated:Connect(function()
		if self._onPullUp then
			self._onPullUp()
		end
	end)
	claim.digMoreButton.Activated:Connect(function()
		if self._onDigMore then
			self._onDigMore()
		end
	end)
	claim.cancelButton.Activated:Connect(function()
		if self._onCancel then
			self._onCancel()
		end
	end)

	return self
end

function DigSpotPromptUI:setCallbacks(callbacks)
	self._onPullUp = callbacks.onPullUp
	self._onDigMore = callbacks.onDigMore
	self._onCancel = callbacks.onCancel
end

function DigSpotPromptUI:_setAnchorPosition(position: Vector3?)
	if not position or not self._anchor then
		return
	end
	self._anchor.CFrame = CFrame.new(position + PROMPT_OFFSET)
end

function DigSpotPromptUI:_setDots(activeCount: number, totalCount: number)
	local dotsRow = self._find.dotsRow
	local dots = self._find.dots

	if #dots ~= totalCount then
		for _, dot in dots do
			dot:Destroy()
		end
		table.clear(dots)
		for index = 1, totalCount do
			local dot = Instance.new("Frame")
			dot.Name = ("Dot%d"):format(index)
			dot.LayoutOrder = index
			dot.Size = UDim2.fromScale(0.125, 0.75)
			dot.BackgroundColor3 = PROGRESS_DOT_INACTIVE
			dot.BorderSizePixel = 0
			dot.Parent = dotsRow
			addCorner(dot, UDim.new(0.5, 0))
			addStroke(dot, Color3.new(0, 0, 0), 2, 0.4)
			dots[index] = dot
		end
	end

	for index, dot in dots do
		dot.BackgroundColor3 = if index <= activeCount then PROGRESS_DOT_ACTIVE else PROGRESS_DOT_INACTIVE
	end
end

function DigSpotPromptUI:_showLayout(which: string)
	self._find.container.Visible = which == "find"
	self._claim.container.Visible = which == "claim"
end

function DigSpotPromptUI:_renderTimer(secondsRemaining: number)
	local timer = self._timer
	if not timer or not timer.frame then
		return
	end

	timer.label.Text = formatCountdown(secondsRemaining)

	-- Color step: neutral until the warning threshold, deepens through orange,
	-- then snaps to red in the final stretch. Matches a stoplight metaphor so
	-- the player can sense urgency without parsing the digits.
	local bg, stroke
	if secondsRemaining <= TIMER_DANGER_THRESHOLD then
		bg = TIMER_BG_DANGER
		stroke = TIMER_STROKE_DANGER
	elseif secondsRemaining <= TIMER_WARNING_THRESHOLD then
		bg = TIMER_BG_WARNING
		stroke = TIMER_STROKE_NEUTRAL
	else
		bg = TIMER_BG_NEUTRAL
		stroke = TIMER_STROKE_NEUTRAL
	end
	timer.frame.BackgroundColor3 = bg
	timer.stroke.Color = stroke
end

function DigSpotPromptUI:_stopTimerHeartbeat()
	if self._timerHeartbeat then
		self._timerHeartbeat:Disconnect()
		self._timerHeartbeat = nil
	end
end

function DigSpotPromptUI:_hideTimer()
	self:_stopTimerHeartbeat()
	self._timerDeadline = nil
	if self._timer and self._timer.frame then
		self._timer.frame.Visible = false
	end
end

function DigSpotPromptUI:setSecondsRemaining(secondsRemaining: number?)
	if not self._timer or not self._timer.frame then
		return
	end

	if typeof(secondsRemaining) ~= "number" or secondsRemaining <= 0 then
		self:_hideTimer()
		return
	end

	-- Recalibrate the deadline against the local clock so successive state
	-- pushes (e.g. on each hit) keep the visible counter in sync with the
	-- server-authoritative timeout.
	self._timerDeadline = os.clock() + secondsRemaining
	self._timer.frame.Visible = true
	self:_renderTimer(secondsRemaining)

	if not self._timerHeartbeat then
		self._timerHeartbeat = RunService.Heartbeat:Connect(function()
			local deadline = self._timerDeadline
			if not deadline then
				self:_stopTimerHeartbeat()
				return
			end

			local remaining = deadline - os.clock()
			if remaining <= 0 then
				self:_renderTimer(0)
				return
			end

			self:_renderTimer(remaining)
		end)
	end
end

function DigSpotPromptUI:hide()
	self:_hideTimer()

	if not self._isShown then
		return
	end
	self._isShown = false

	if self._billboard then
		self._billboard.Enabled = false
	end
	if self._panel then
		self._panel.BackgroundTransparency = 0.05
	end
end

function DigSpotPromptUI:_show()
	if self._isShown then
		return
	end
	self._isShown = true

	if self._billboard then
		self._billboard.Enabled = true
	end
end

function DigSpotPromptUI:showFindPhase(position: Vector3, hits: number, requiredHits: number)
	self:_setAnchorPosition(position)
	self:_setDots(hits, requiredHits)

	-- Slightly different prompt text depending on how close they are; reads
	-- a touch more dynamic than a static "1/3 ... 2/3".
	local title
	if hits <= 0 then
		title = "DIG"
	elseif hits >= requiredHits then
		title = "FOUND IT!"
	else
		title = ("%d / %d"):format(hits, requiredHits)
	end
	self._find.title.Text = title

	self:_showLayout("find")
	self:_show()
end

function DigSpotPromptUI:showClaimPhase(position: Vector3, luckMultiplier: number, riskNext: number)
	self:_setAnchorPosition(position)

	local luck = math.max(1, luckMultiplier or 1)
	self._claim.luckLabel.Text = formatLuck(luck)
	self._claim.luckLabel.TextColor3 = if luck > 1.001 then LUCK_TEXT_COLOR else LUCK_TEXT_DIM_COLOR

	local risk = math.clamp(riskNext or 0, 0, 1)
	local riskPercent = math.floor(risk * 100 + 0.5)
	self._claim.digMoreButton.Text = ("DIG DEEPER\n%d%% chance to break"):format(riskPercent)
	-- Red tint scales with risk so the player sees the button get angrier as
	-- the next swing gets riskier; pure visual polish, no behavior change.
	local tintWeight = math.clamp(risk, 0, 1)
	self._claim.digMoreButton.TextColor3 = DIG_MORE_TEXT:Lerp(RISK_TEXT_COLOR, tintWeight)

	self:_showLayout("claim")
	self:_show()
end

function DigSpotPromptUI:Destroy()
	self:_stopTimerHeartbeat()
	if self._billboard then
		self._billboard:Destroy()
		self._billboard = nil
	end
	if self._anchor then
		self._anchor:Destroy()
		self._anchor = nil
	end
end

return DigSpotPromptUI
