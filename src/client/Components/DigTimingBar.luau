local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local DigConfig = require(ConfigFolder:WaitForChild("DigConfig"))

-- Screen-space QTE bar anchored below the top HUD row.
--
-- Three display states:
--
--   "waiting"  - Player is on the dig site but hasn't clicked yet. The panel
--                shows instructions ("Click to start digging") with no bar.
--                A click calls onStartDig() so the controller can transition
--                to the active state.
--
--   "active"   - Standard (white) or extra (purple shimmer) phase. The track
--                and cursor are visible and the player clicks to stop the
--                cursor on the green zone.
--
--   "hidden"   - GUI is disabled entirely.

local DigTimingBar = {}
DigTimingBar.__index = DigTimingBar

-- Layout — PANEL_WIDTH/HEIGHT kept only as reference values for the
-- aspect ratio; actual sizing is done in scale so the panel shrinks
-- proportionally on small screens.
local PANEL_REF_W  = 460   -- reference width used to compute aspect ratio
local PANEL_REF_H  = 78    -- reference height used to compute aspect ratio
local CURSOR_X_SCALE = 0.018 -- track-width fraction; scales with resolution
local DOT_ROW_H    = 0.065 -- fraction of panel height for the hit-dots row

-- Standard phase colours
local PANEL_BG          = Color3.fromRGB(245, 243, 238)
local PANEL_BG_BOTTOM   = Color3.fromRGB(228, 224, 216)
local PANEL_STROKE      = Color3.fromRGB(200, 192, 180)
local TRACK_BG          = Color3.fromRGB(255, 255, 255)
local GREEN_COLOR       = Color3.fromRGB(80, 210, 100)
local GREEN_STROKE      = Color3.fromRGB(40, 160, 60)
local CURSOR_COLOR      = Color3.fromRGB(220, 60, 60)
local CURSOR_STROKE     = Color3.fromRGB(160, 30, 30)
local DOT_ACTIVE        = Color3.fromRGB(80, 210, 100)
local DOT_INACTIVE      = Color3.fromRGB(200, 200, 200)
local LABEL_COLOR       = Color3.fromRGB(255, 255, 255)
local HINT_COLOR        = Color3.fromRGB(255, 255, 255)
local LOCKED_TINT       = Color3.fromRGB(180, 175, 165)

-- Instruction overlay colours
local INSTR_TITLE_COLOR = Color3.fromRGB(255, 255, 255)
local INSTR_HINT_COLOR  = Color3.fromRGB(255, 255, 255)

-- Extra phase colours
local EXTRA_PANEL_BG     = Color3.fromRGB(85, 48, 155)
local EXTRA_PANEL_BOTTOM = Color3.fromRGB(58, 30, 115)
local EXTRA_PANEL_STROKE = Color3.fromRGB(255, 90, 215)
local EXTRA_TRACK_BG     = Color3.fromRGB(65, 36, 125)
local EXTRA_LABEL_COLOR  = Color3.fromRGB(255, 240, 90)
local EXTRA_HINT_COLOR   = Color3.fromRGB(255, 255, 255)

local SHIMMER_A = Color3.fromRGB(255, 80, 200)
local SHIMMER_B = Color3.fromRGB(255, 180, 240)

local PULLUP_BG     = Color3.fromRGB(255, 55, 175)
local PULLUP_BOTTOM = Color3.fromRGB(195, 20, 125)
local PULLUP_TEXT   = Color3.fromRGB(255, 255, 255)
local PULLUP_STROKE = Color3.fromRGB(255, 180, 240)

-- Progressive luck tier gradients (evaluated highest → lowest).
-- Each tier activates once luck reaches its threshold value.
local LUCK_TIERS = {
	{
		threshold = 25,
		gradient  = ColorSequence.new({
			ColorSequenceKeypoint.new(0,   Color3.fromRGB(240, 130, 255)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(180,  60, 255)),
			ColorSequenceKeypoint.new(1,   Color3.fromRGB(100, 180, 255)),
		}),
		stroke = Color3.fromRGB(60, 0, 120),
	},
	{
		threshold = 10,
		gradient  = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB( 60, 230, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB( 20, 140, 255)),
		}),
		stroke = Color3.fromRGB(0, 50, 130),
	},
	{
		threshold = 5,
		gradient  = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255,  80, 210)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(200,  30, 140)),
		}),
		stroke = Color3.fromRGB(100, 0, 70),
	},
	{
		threshold = 2,
		gradient  = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 165,  30)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255,  90,   0)),
		}),
		stroke = Color3.fromRGB(110, 35, 0),
	},
	{
		threshold = 0,
		gradient  = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 248,  80)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 205,  30)),
		}),
		stroke = Color3.fromRGB(90, 60, 0),
	},
}

local rng = Random.new()

local function addCorner(parent: Instance, radius: UDim)
	local c = Instance.new("UICorner")
	c.CornerRadius = radius
	c.Parent = parent
end

local function addStroke(parent: Instance, color: Color3, thickness: number, transparency: number?)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Parent = parent
	return s
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

local function buildGui(playerGui: Instance)
	local gui = Instance.new("ScreenGui")
	gui.Name = "DigTimingBarGui"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 20
	-- Match HUD pack (LuckCounter, EquippedShovel) so top anchors align with
	-- TopButtons instead of sitting under the core-gui inset.
	gui.IgnoreGuiInset = false
	gui.Enabled = false
	gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0)
	-- Scale-based X and Y so placement stays consistent across resolutions.
	-- Clear the top teleport row; value tuned with IgnoreGuiInset = false.
	panel.Position = UDim2.new(0.5, 0, 0.2, 0)
	-- Width is 28 % of the viewport; height is driven by the aspect ratio
	-- constraint so the panel stays the same shape at every resolution.
	-- UISizeConstraint clamps the pixel size so it never gets too large on
	-- a 4 K display or too tiny on a very small window.
	panel.Size = UDim2.new(0.42, 0, 0, 0)
	panel.BackgroundColor3 = PANEL_BG
	panel.BackgroundTransparency = 1
	panel.BorderSizePixel = 0
	panel.Parent = gui
	addCorner(panel, UDim.new(0, 14))
	local panelGrad = addGradient(panel, PANEL_BG, PANEL_BG_BOTTOM)
	local panelStroke = addStroke(panel, PANEL_STROKE, 2, 1)

	local panelAspect = Instance.new("UIAspectRatioConstraint")
	panelAspect.AspectRatio = PANEL_REF_W / PANEL_REF_H   -- ≈ 3.96
	panelAspect.DominantAxis = Enum.DominantAxis.Width
	panelAspect.AspectType   = Enum.AspectType.ScaleWithParentSize
	panelAspect.Parent = panel

	local panelSizeClamp = Instance.new("UISizeConstraint")
	panelSizeClamp.MaxSize = Vector2.new(460, 78)
	panelSizeClamp.MinSize = Vector2.new(180, 30)
	panelSizeClamp.Parent = panel

	-- Instruction overlay — covers the bar area with "click to dig" text.
	-- Visible only in the waiting state; all other elements are hidden then.
	local instrOverlay = Instance.new("Frame")
	instrOverlay.Name = "InstrOverlay"
	instrOverlay.AnchorPoint = Vector2.new(0.5, 0.5)
	instrOverlay.Position = UDim2.fromScale(0.5, 0.5)
	instrOverlay.Size = UDim2.fromScale(1, 1)
	instrOverlay.BackgroundTransparency = 1
	instrOverlay.Visible = false
	instrOverlay.Parent = panel

	local instrTitle = Instance.new("TextLabel")
	instrTitle.Name = "Title"
	instrTitle.AnchorPoint = Vector2.new(0.5, 0.5)
	instrTitle.Position = UDim2.fromScale(0.5, 0.38)
	instrTitle.Size = UDim2.new(1, -24, 0.38, 0)
	instrTitle.BackgroundTransparency = 1
	instrTitle.Font = Enum.Font.GothamBlack
	instrTitle.Text = "DIG SITE"
	instrTitle.TextColor3 = INSTR_TITLE_COLOR
	instrTitle.TextScaled = true
	instrTitle.TextStrokeColor3 = Color3.new(0, 0, 0)
	instrTitle.TextStrokeTransparency = 0.35
	instrTitle.Parent = instrOverlay

	local instrHint = Instance.new("TextLabel")
	instrHint.Name = "Hint"
	instrHint.AnchorPoint = Vector2.new(0.5, 0.5)
	instrHint.Position = UDim2.fromScale(0.5, 0.74)
	instrHint.Size = UDim2.new(1, -28, 0.23, 0)
	instrHint.BackgroundTransparency = 1
	instrHint.Font = Enum.Font.GothamBold
	instrHint.Text = "Click anywhere to start digging"
	instrHint.TextColor3 = INSTR_HINT_COLOR
	instrHint.TextScaled = true
	instrHint.TextStrokeColor3 = Color3.new(0, 0, 0)
	instrHint.TextStrokeTransparency = 0.45
	instrHint.Parent = instrOverlay

	-- Header: phase title and (in extra phase) luck readout side-by-side so
	-- luck never projects above the panel into the top HUD.
	local headerRow = Instance.new("Frame")
	headerRow.Name = "HeaderRow"
	headerRow.AnchorPoint = Vector2.new(0.5, 0)
	headerRow.Position = UDim2.new(0.5, 0, 0.02, 0)
	headerRow.Size = UDim2.new(1, -20, 0.24, 0)
	headerRow.BackgroundTransparency = 1
	headerRow.Parent = panel

	local phaseLabel = Instance.new("TextLabel")
	phaseLabel.Name = "PhaseLabel"
	phaseLabel.AnchorPoint = Vector2.new(0, 0.5)
	phaseLabel.Position = UDim2.new(0, 6, 0.5, 0)
	phaseLabel.Size = UDim2.new(0.56, -8, 0.78, 0)
	phaseLabel.BackgroundTransparency = 1
	phaseLabel.Font = Enum.Font.GothamBlack
	phaseLabel.Text = "DIG"
	phaseLabel.TextColor3 = LABEL_COLOR
	phaseLabel.TextScaled = true
	phaseLabel.TextXAlignment = Enum.TextXAlignment.Left
	phaseLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	phaseLabel.TextStrokeTransparency = 0.35
	phaseLabel.Parent = headerRow

	-- Track (bar background; hidden while instructions overlay is shown)
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0.5, 0)
	track.Position = UDim2.new(0.5, 0, 0.28, 0)
	track.Size = UDim2.new(1, -16, 0.48, 0)
	track.BackgroundColor3 = TRACK_BG
	track.BorderSizePixel = 0
	track.ClipsDescendants = true
	track.Parent = panel
	addCorner(track, UDim.new(0.5, 0))
	local trackGrad = addGradient(track, TRACK_BG, TRACK_BG)

	local greenZone = Instance.new("Frame")
	greenZone.Name = "GreenZone"
	greenZone.AnchorPoint = Vector2.new(0, 0.5)
	greenZone.Position = UDim2.fromScale(0.4, 0.5)
	greenZone.Size = UDim2.fromScale(0.17, 0.9)
	greenZone.BackgroundColor3 = GREEN_COLOR
	greenZone.BorderSizePixel = 0
	greenZone.Parent = track
	addCorner(greenZone, UDim.new(0.5, 0))
	addStroke(greenZone, GREEN_STROKE, 1, 0.15)

	local cursor = Instance.new("Frame")
	cursor.Name = "Cursor"
	cursor.AnchorPoint = Vector2.new(0.5, 0.5)
	cursor.Position = UDim2.fromScale(0, 0.5)
	cursor.Size = UDim2.new(CURSOR_X_SCALE, 0, 0.92, 0)
	cursor.BackgroundColor3 = CURSOR_COLOR
	cursor.BorderSizePixel = 0
	cursor.ZIndex = 5
	cursor.Parent = track
	addCorner(cursor, UDim.new(0, 3))
	addStroke(cursor, CURSOR_STROKE, 1.5, 0.1)

	-- Hint text below the track (hidden with instructions overlay)
	local hintLabel = Instance.new("TextLabel")
	hintLabel.Name = "HintLabel"
	hintLabel.AnchorPoint = Vector2.new(0.5, 0)
	hintLabel.Position = UDim2.new(0.5, 0, 0.785, 0)
	hintLabel.Size = UDim2.new(1, -24, 0.14, 0)
	hintLabel.BackgroundTransparency = 1
	hintLabel.Font = Enum.Font.GothamBold
	hintLabel.Text = "CLICK TO STOP"
	hintLabel.TextColor3 = HINT_COLOR
	hintLabel.TextScaled = true
	hintLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	hintLabel.TextStrokeTransparency = 0.45
	hintLabel.Parent = panel

	-- Progress dots row (hidden with instructions overlay)
	local dotsRow = Instance.new("Frame")
	dotsRow.Name = "DotsRow"
	dotsRow.AnchorPoint = Vector2.new(0.5, 0)
	dotsRow.Position = UDim2.new(0.5, 0, 0.915, 0)
	dotsRow.Size = UDim2.new(1, -32, DOT_ROW_H, 0)
	dotsRow.BackgroundTransparency = 1
	dotsRow.Parent = panel

	local dotsLayout = Instance.new("UIListLayout")
	dotsLayout.FillDirection = Enum.FillDirection.Horizontal
	dotsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	dotsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	dotsLayout.Padding = UDim.new(0.02, 0)
	dotsLayout.Parent = dotsRow

	local pullUpButton = Instance.new("TextButton")
	pullUpButton.Name = "PullUpButton"
	pullUpButton.AnchorPoint = Vector2.new(0.5, 0)
	pullUpButton.Position = UDim2.new(0.5, 0, 1.02, 0)
	pullUpButton.Size = UDim2.new(0.98, 0, 0.4, 0)
	pullUpButton.BackgroundColor3 = PULLUP_BG
	pullUpButton.AutoButtonColor = false
	pullUpButton.BorderSizePixel = 0
	pullUpButton.Text = ""
	pullUpButton.Visible = false
	pullUpButton.Parent = panel
	addCorner(pullUpButton, UDim.new(0, 10))
	addGradient(pullUpButton, PULLUP_BG, PULLUP_BOTTOM)
	addStroke(pullUpButton, PULLUP_STROKE, 2, 0.05)

	-- Text lives in a child label so the button's UIGradient (which tints both
	-- background and text on a TextButton) doesn't recolor the white text.
	local pullUpLabel = Instance.new("TextLabel")
	pullUpLabel.Name = "Label"
	pullUpLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	pullUpLabel.Position = UDim2.fromScale(0.5, 0.5)
	pullUpLabel.Size = UDim2.fromScale(1, 1)
	pullUpLabel.BackgroundTransparency = 1
	pullUpLabel.BorderSizePixel = 0
	pullUpLabel.Font = Enum.Font.GothamBlack
	pullUpLabel.Text = "PULL UP BRAINROT"
	pullUpLabel.TextColor3 = PULLUP_TEXT
	pullUpLabel.TextScaled = true
	pullUpLabel.TextStrokeTransparency = 1
	pullUpLabel.Parent = pullUpButton

	-- Luck multiplier (extra phase only): sits in the header row; updated by setLuck().
	local luckDisplay = Instance.new("TextLabel")
	luckDisplay.Name                   = "LuckDisplay"
	luckDisplay.AnchorPoint            = Vector2.new(1, 0.5)
	luckDisplay.Position               = UDim2.new(1, -6, 0.5, 0)
	luckDisplay.Size                   = UDim2.new(0.42, 0, 0.78, 0)
	luckDisplay.BackgroundTransparency = 1
	luckDisplay.Font                   = Enum.Font.GothamBlack
	luckDisplay.Text                   = ""
	luckDisplay.TextColor3             = Color3.fromRGB(255, 248, 80)
	luckDisplay.TextScaled             = true
	luckDisplay.TextXAlignment         = Enum.TextXAlignment.Right
	luckDisplay.TextStrokeColor3       = Color3.fromRGB(90, 60, 0)
	luckDisplay.TextStrokeTransparency = 0
	luckDisplay.Visible                = false
	luckDisplay.ZIndex                 = panel.ZIndex + 2
	luckDisplay.Parent                 = headerRow

	local luckGrad = Instance.new("UIGradient")
	luckGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 248,  80)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 205,  30)),
	})
	luckGrad.Rotation = 90
	luckGrad.Parent   = luckDisplay

	return {
		gui          = gui,
		panel        = panel,
		panelGrad    = panelGrad,
		panelStroke  = panelStroke,
		instrOverlay = instrOverlay,
		headerRow    = headerRow,
		phaseLabel   = phaseLabel,
		track        = track,
		trackGrad    = trackGrad,
		greenZone    = greenZone,
		cursor       = cursor,
		hintLabel    = hintLabel,
		dotsRow      = dotsRow,
		pullUpButton = pullUpButton,
		luckDisplay  = luckDisplay,
		luckGrad     = luckGrad,
	}
end

function DigTimingBar.new()
	local self = setmetatable({}, DigTimingBar)

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local elems = buildGui(playerGui)

	self._elems          = elems
	self._dots           = {} :: { Frame }
	self._phase          = "standard"
	self._isWaiting      = false
	self._cursorFraction = 0
	self._cursorDir      = 1
	self._greenFraction  = 0.4
	self._greenWidth     = DigConfig.TIMING_BAR_BASE_GREEN_SIZE
	self._speed          = DigConfig.TIMING_BAR_BASE_SPEED
	self._lockUntil      = 0
	self._shimmerOffset  = 0
	self._shimmerDir     = 1
	self._onStop         = nil :: ((success: boolean) -> ())?
	self._onPullUp       = nil :: (() -> ())?
	self._onStartDig     = nil :: (() -> ())?
	self._heartbeat      = nil :: RBXScriptConnection?
	self._inputConn      = nil :: RBXScriptConnection?

	elems.pullUpButton.Activated:Connect(function()
		if self._onPullUp then
			self._onPullUp()
		end
	end)

	self._inputConn = UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end

		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		if not elems.gui.Enabled then
			return
		end

		-- Waiting state: the first click starts the dig bar rather than stopping it.
		if self._isWaiting then
			if self._onStartDig then
				self._onStartDig()
			end
			return
		end

		local now = os.clock()
		if now < self._lockUntil then
			return
		end

		local cursorPos = self._cursorFraction
		local greenLeft = self._greenFraction
		local greenRight = greenLeft + self._greenWidth
		local success = cursorPos >= greenLeft and cursorPos <= greenRight

		if self._onStop then
			self._onStop(success)
		end
	end)

	self:_startHeartbeat()

	return self
end

function DigTimingBar:_startHeartbeat()
	if self._heartbeat then
		return
	end

	self._heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		if not self._elems.gui.Enabled then
			return
		end

		-- Don't advance the cursor while showing instructions.
		if self._isWaiting then
			return
		end

		local now = os.clock()
		local locked = now < self._lockUntil

		local advance = dt / self._speed
		self._cursorFraction = self._cursorFraction + advance * self._cursorDir
		if self._cursorFraction >= 1 then
			self._cursorFraction = 1
			self._cursorDir = -1
		elseif self._cursorFraction <= 0 then
			self._cursorFraction = 0
			self._cursorDir = 1
		end

		self._elems.cursor.Position = UDim2.fromScale(self._cursorFraction, 0.5)
		self._elems.cursor.BackgroundColor3 = if locked then LOCKED_TINT else CURSOR_COLOR

		if self._phase == "extra" then
			self._shimmerOffset = self._shimmerOffset + self._shimmerDir * dt * 0.6
			if self._shimmerOffset >= 1 then
				self._shimmerOffset = 1
				self._shimmerDir = -1
			elseif self._shimmerOffset <= 0 then
				self._shimmerOffset = 0
				self._shimmerDir = 1
			end

			local t = self._shimmerOffset
			local blended = SHIMMER_A:Lerp(SHIMMER_B, t)
			self._elems.trackGrad.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, blended),
				ColorSequenceKeypoint.new(1, EXTRA_TRACK_BG),
			})
		end
	end)
end

function DigTimingBar:_stopHeartbeat()
	if self._heartbeat then
		self._heartbeat:Disconnect()
		self._heartbeat = nil
	end
end

function DigTimingBar:_setBarElementsVisible(visible: boolean)
	local elems = self._elems
	elems.headerRow.Visible  = visible
	elems.track.Visible      = visible
	elems.hintLabel.Visible  = visible
	elems.dotsRow.Visible    = visible
end

function DigTimingBar:_rebuildDots(total: number)
	local dotsRow = self._elems.dotsRow
	for _, dot in self._dots do
		dot:Destroy()
	end
	table.clear(self._dots)

	for i = 1, total do
		local dot = Instance.new("Frame")
		dot.Name = ("Dot%d"):format(i)
		dot.Size = UDim2.new(0, 0, 0.88, 0)
		dot.BackgroundColor3 = DOT_INACTIVE
		dot.BorderSizePixel = 0
		dot.Parent = dotsRow
		local dotAspect = Instance.new("UIAspectRatioConstraint")
		dotAspect.AspectRatio = 1
		dotAspect.DominantAxis = Enum.DominantAxis.Height
		dotAspect.Parent = dot
		addCorner(dot, UDim.new(0.5, 0))
		addStroke(dot, Color3.new(0, 0, 0), 1.5, 0.5)
		self._dots[i] = dot
	end
end

function DigTimingBar:_updateDots(activeCount: number)
	local isExtra = self._phase == "extra"
	for i, dot in self._dots do
		if isExtra then
			dot.BackgroundColor3 = DOT_ACTIVE
		else
			dot.BackgroundColor3 = if i <= activeCount then DOT_ACTIVE else DOT_INACTIVE
		end
	end
end

function DigTimingBar:_applyPhaseStyle()
	local elems = self._elems
	local isExtra = self._phase == "extra"

	-- Panel background is always transparent; only the track and labels change.
	elems.panelStroke.Transparency = 1

	if isExtra then
		elems.phaseLabel.TextColor3  = EXTRA_LABEL_COLOR
		elems.hintLabel.TextColor3   = EXTRA_HINT_COLOR
		elems.hintLabel.Text         = "MISS = SNAP!"
		elems.track.BackgroundColor3 = EXTRA_TRACK_BG
		elems.pullUpButton.Visible   = true
		elems.luckDisplay.Visible    = true
	else
		elems.phaseLabel.TextColor3  = LABEL_COLOR
		elems.hintLabel.TextColor3   = HINT_COLOR
		elems.hintLabel.Text         = "CLICK TO STOP"
		elems.track.BackgroundColor3 = TRACK_BG
		elems.trackGrad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, TRACK_BG),
			ColorSequenceKeypoint.new(1, TRACK_BG),
		})
		elems.pullUpButton.Visible  = false
		elems.luckDisplay.Visible   = false
	end
end

-- Shows the "waiting" state: instructions panel visible, bar hidden.
-- The player must click to transition to the active bar.
function DigTimingBar:showInstructions()
	self._isWaiting = true
	-- Reset to standard white style so the instructions use the light panel.
	if self._phase ~= "standard" then
		self._phase = "standard"
		self:_applyPhaseStyle()
	end
	self._elems.instrOverlay.Visible = true
	self:_setBarElementsVisible(false)
	self._elems.gui.Enabled = true
end

-- Transitions from instructions (or hidden) to the active sweeping bar.
function DigTimingBar:show()
	self._isWaiting = false
	self._elems.instrOverlay.Visible = false
	self:_setBarElementsVisible(true)
	-- Re-apply phase style so hint text is correct after the transition.
	self:_applyPhaseStyle()
	self._elems.gui.Enabled = true
end

function DigTimingBar:hide()
	self._isWaiting = false
	self._elems.gui.Enabled = false
end

function DigTimingBar:isVisible(): boolean
	return self._elems.gui.Enabled
end

-- Picks a new random green zone position. The cursor keeps its current
-- position so there is no jarring snap; only the target zone moves.
function DigTimingBar:reset(greenWidth: number, speed: number)
	self._greenWidth = math.clamp(greenWidth, DigConfig.TIMING_BAR_MIN_GREEN_SIZE, 1)
	self._speed      = math.max(speed, DigConfig.TIMING_BAR_MIN_DURATION)

	local padding = DigConfig.TIMING_BAR_GREEN_PADDING
	local maxLeft = 1 - self._greenWidth - padding
	local minLeft = padding
	self._greenFraction = rng:NextNumber(minLeft, math.max(minLeft, maxLeft))

	local elems = self._elems
	elems.greenZone.Position = UDim2.fromScale(self._greenFraction, 0.5)
	elems.greenZone.Size     = UDim2.fromScale(self._greenWidth, 0.9)
	if self._phase ~= "extra" then
		elems.hintLabel.Text = "CLICK TO STOP"
	end
end

function DigTimingBar:lockInput(duration: number)
	self._lockUntil = os.clock() + duration
end

function DigTimingBar:setPhase(phase: string)
	if self._phase == phase then
		return
	end
	self._phase = phase
	self:_applyPhaseStyle()
end

function DigTimingBar:setHits(hits: number, required: number)
	if #self._dots ~= required then
		self:_rebuildDots(required)
	end
	self:_updateDots(hits)

	local isExtra = self._phase == "extra"
	if isExtra then
		self._elems.phaseLabel.Text = "DIG DEEPER"
	elseif hits <= 0 then
		self._elems.phaseLabel.Text = "DIG"
	else
		self._elems.phaseLabel.Text = ("%d / %d"):format(hits, required)
	end
end

function DigTimingBar:setLuck(luck: number)
	if self._phase ~= "extra" then
		return
	end
	local formatted = if luck >= 10
		then ("x%d LUCK"):format(math.floor(luck + 0.5))
		else ("x%.1f LUCK"):format(luck)
	self._elems.luckDisplay.Text = formatted

	-- Apply the highest tier whose threshold the current luck meets.
	local luckGrad = self._elems.luckGrad
	for _, tier in LUCK_TIERS do
		if luck >= tier.threshold then
			luckGrad.Color = tier.gradient
			self._elems.luckDisplay.TextStrokeColor3 = tier.stroke
			break
		end
	end
end

function DigTimingBar:setCallbacks(callbacks: {
	onStop: ((boolean) -> ())?,
	onPullUp: (() -> ())?,
	onCancel: (() -> ())?,
	onStartDig: (() -> ())?,
})
	self._onStop     = callbacks.onStop
	self._onPullUp   = callbacks.onPullUp
	self._onStartDig = callbacks.onStartDig
end

-- Plays a polished hit animation: the cursor flashes bright and widens,
-- the green zone pulses outward, and the track briefly illuminates.
-- Call this immediately after a successful stop, before resetting the bar.
function DigTimingBar:playHitAnimation()
	local elems = self._elems
	local ts = TweenService

	-- Cursor: flash yellow-white and briefly widen, then spring back.
	ts:Create(elems.cursor, TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundColor3 = Color3.fromRGB(255, 255, 160),
		Size             = UDim2.new(CURSOR_X_SCALE * 2.2, 0, 0.98, 0),
	}):Play()
	task.delay(0.07, function()
		if not elems.cursor.Parent then return end
		ts:Create(elems.cursor, TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			BackgroundColor3 = CURSOR_COLOR,
			Size             = UDim2.new(CURSOR_X_SCALE, 0, 0.92, 0),
		}):Play()
	end)

	-- Green zone: scale outward then snap back.
	local gw = self._greenWidth
	ts:Create(elems.greenZone, TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(gw * 1.3, 1.15),
	}):Play()
	task.delay(0.07, function()
		if not elems.greenZone.Parent then return end
		ts:Create(elems.greenZone, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Size = UDim2.fromScale(gw, 0.9),
		}):Play()
	end)

	-- Track: briefly flash light green then fade to the phase color.
	ts:Create(elems.track, TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundColor3 = Color3.fromRGB(140, 255, 160),
	}):Play()
	task.delay(0.07, function()
		if not elems.track.Parent then return end
		local targetColor = if self._phase == "extra" then EXTRA_TRACK_BG else TRACK_BG
		ts:Create(elems.track, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundColor3 = targetColor,
		}):Play()
	end)
end

function DigTimingBar:Destroy()
	self:_stopHeartbeat()
	if self._inputConn then
		self._inputConn:Disconnect()
		self._inputConn = nil
	end
	if self._elems and self._elems.gui then
		self._elems.gui:Destroy()
	end
end

return DigTimingBar
