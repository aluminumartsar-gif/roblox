--!strict
--[[
	StealController
	StarterPlayerScripts/Client/Controllers/StealController

	The client side of stealing:

	  * Owner alarm. The server's StealAlarm remote drives a blood-red banner
	    (with the thief's name) whose glow pulses while your egg is in danger,
	    an alarm sound, and a red outline on the item — first on the nest
	    item being stolen, then on the item while it's carried or dropped,
	    visible through walls so the owner can chase it. Dropped turns the
	    banner ember ("grab it back!"); "got away" is dark red, "home safe"
	    moss green.
	  * Carrier banner. While you carry something: what it is, and how long
	    until it runs home. A charred-wood strip with an ember edge (stolen),
	    moss (a bought belt egg) or moonlight (a captured wild cryptid).
	  * Dropped items: the owner's prompt reads "Take back"; hidden for anyone
	    already carrying something.

	Both banners sit at the top centre (ScreenGui "StealUI", draw order
	Config.UI.Layers.Steal): under Roblox's top bar, the HUD's Base/Eggs
	buttons and any sighting/Hunt banner, the alarm above the carry banner.
	They reserve that space with NotificationController.ReserveTop("Steal",
	...) so toasts slide in below them.

	The tutorial panel sits under these banners. While it shows it holds the
	toast reservation for both of us (TutorialController calls
	SetPanelBelow), so neither of us ever stacks under the other's
	reservation:
	  StealController.BannerBottom() -> number?  -- bottom of the visible banners
	                                             -- (screen px, like ReserveTop), or nil
	  StealController.BannersChanged             -- Signal: they showed, hid or moved
	  StealController.SetPanelBelow(key?)        -- a panel reserving under `key` sits below

	Look and timings: Config.UI.Tutorial.StealAlerts. Display only — every
	rule is enforced on the server.
]]

local CollectionService = game:GetService("CollectionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Signal = require(Shared:WaitForChild("Util"):WaitForChild("Signal"))

local Components = script.Parent.Parent:WaitForChild("Components")
local Theme = require(Components:WaitForChild("Theme"))
local UI = require(Components:WaitForChild("UI"))
local Icon = require(Components:WaitForChild("Icon"))
local SoundController = require(script.Parent:WaitForChild("SoundController"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))

local StealController = {}

--- Fires when the steal banners show, hide or move (TutorialController
--- re-places its panel under them).
StealController.BannersChanged = Signal.new()

local localPlayer = Players.LocalPlayer
local C = Theme.Colors
local look = Config.UI.Tutorial.StealAlerts
local layout = Config.UI.Layout

-- NotificationController.ReserveTop key for the banners.
local RESERVE_KEY = "Steal"

--------------------------------------------------------------------------
-- Banner styles (theme colours; the alarm's depends on the phase, the
-- carry banner's on where the item came from)
--------------------------------------------------------------------------

type Style = {
	Top: Color3,     -- fill gradient, top to bottom
	Mid: Color3,
	Bottom: Color3,
	Edge: Color3,
	Text: Color3,
	Accent: Color3,  -- icon tint
	Icon: string,
	Pulse: boolean,  -- a bone-white glow beats over it while the item is in danger
}

local ALARM_STYLES: { [string]: Style } = {
	Started = {
		Top = C.BloodBright, Mid = C.Blood, Bottom = C.BloodDeep, Edge = C.BloodBright,
		Text = C.Text, Accent = C.Text, Icon = "Warning", Pulse = true,
	},
	Stolen = {
		Top = C.BloodBright, Mid = C.Blood, Bottom = C.BloodDeep, Edge = C.BloodBright,
		Text = C.Text, Accent = C.Text, Icon = "Warning", Pulse = true,
	},
	Dropped = {
		Top = C.EmberBright, Mid = C.Ember, Bottom = C.EmberDeep, Edge = C.EmberBright,
		Text = C.TextOnAccent, Accent = C.TextOnAccent, Icon = "Warning", Pulse = true,
	},
	Claimed = {
		Top = C.BloodDeep, Mid = C.BloodDeep, Bottom = C.Panel, Edge = C.Blood,
		Text = C.Text, Accent = C.BloodBright, Icon = "Skull", Pulse = false,
	},
	Returned = {
		Top = C.MossBright, Mid = C.Moss, Bottom = C.MossDeep, Edge = C.MossBright,
		Text = C.TextOnAccent, Accent = C.TextOnAccent, Icon = "Home", Pulse = false,
	},
}

local function carryStyle(accent: Color3): Style
	return {
		Top = C.PanelTop, Mid = C.Panel, Bottom = C.Panel, Edge = accent,
		Text = C.Text, Accent = accent, Icon = "Grab", Pulse = false,
	}
end

local CARRY_STYLES: { [string]: Style } = {
	Belt = carryStyle(C.Moss),       -- a bought egg
	Sighting = carryStyle(C.Moon),   -- a captured wild cryptid
	Stolen = carryStyle(C.Ember),    -- anything else: stolen, with a timer
}

--------------------------------------------------------------------------
-- Banners
--------------------------------------------------------------------------

type Banner = {
	frame: Frame,
	fill: UIGradient,
	edge: UIStroke,
	glow: Frame,
	icon: ImageLabel,
	label: TextLabel,
	style: string?,  -- key of the style last painted (repaint only on change)
	pulse: Tween?,
}

local gui: ScreenGui? = nil
local origin: Frame -- zero-size frame at the gui's (0, 0): converts screen px to gui px
local stack: Frame
local stackScale: UIScale
local alarm: Banner
local carry: Banner

local panelBelowKey: string? = nil
local bannerBottom: number? = nil

local function makeBanner(name: string): Banner
	local frame = UI.new("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(look.Width, look.Height),
		BackgroundColor3 = Color3.new(1, 1, 1), -- white base: the gradient gives the colour
		BorderSizePixel = 0,
		Visible = false,
		Parent = stack,
	}) :: Frame
	UI.Corner().Parent = frame
	local fill = UI.new("UIGradient", { Name = "Fill", Rotation = 90, Parent = frame }) :: UIGradient
	local edge = UI.Stroke({ Name = "Edge", Thickness = 2, Parent = frame }) :: UIStroke
	local glow = UI.new("Frame", {
		Name = "Glow",
		BackgroundColor3 = C.Text,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
		Parent = frame,
	}, { UI.Corner() }) :: Frame
	local icon = UI.Icon("Warning", look.IconSize, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, look.Padding, 0.5, 0),
		ZIndex = 2,
		Parent = frame,
	})
	local textLeft = look.Padding * 2 + look.IconSize
	local label = UI.Text({
		Name = "Label",
		Role = "Heading",
		Weight = "Bold",
		Text = "",
		RichText = false, -- names are shown as typed
		TextScaled = true,
		TextWrapped = true,
		Position = UDim2.fromOffset(textLeft, look.TextPadding),
		Size = UDim2.new(1, -(textLeft + look.Padding), 1, -look.TextPadding * 2),
		ZIndex = 2,
		Parent = frame,
	})
	UI.new("UITextSizeConstraint", {
		MaxTextSize = look.TextSize,
		MinTextSize = look.MinTextSize,
		Parent = label,
	})
	return {
		frame = frame,
		fill = fill,
		edge = edge,
		glow = glow,
		icon = icon,
		label = label,
		style = nil,
		pulse = nil,
	}
end

--- Colours a banner (only when the style changes, so the pulse keeps its beat).
local function paint(banner: Banner, key: string, style: Style)
	if banner.style == key then
		return
	end
	banner.style = key
	banner.fill.Color = Theme.Sequence(style.Top, style.Bottom, style.Mid)
	banner.edge.Color = style.Edge
	banner.label.TextColor3 = style.Text
	banner.icon.ImageColor3 = style.Accent
	Icon.set(banner.icon, style.Icon)
	local pulse = banner.pulse
	if pulse then
		pulse:Cancel()
		banner.pulse = nil
	end
	banner.glow.BackgroundTransparency = 1
	if style.Pulse then
		local tween = TweenService:Create(
			banner.glow,
			TweenInfo.new(look.PulseTime, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ BackgroundTransparency = look.PulseTransparency }
		)
		tween:Play()
		banner.pulse = tween
	end
end

--- Shows or hides a banner. Returns true if it just appeared.
local function setShown(banner: Banner, shown: boolean): boolean
	if banner.frame.Visible == shown then
		return false
	end
	banner.frame.Visible = shown
	if not shown then
		-- Forget the style so the next show restarts its pulse.
		local pulse = banner.pulse
		if pulse then
			pulse:Cancel()
			banner.pulse = nil
		end
		banner.style = nil
	end
	return shown
end

--------------------------------------------------------------------------
-- Placement (top centre, under the top bar and any banner above)
--------------------------------------------------------------------------

--- Gui y (px from the very top of the screen) just under Roblox's top bar
--- and the HUD's Base/Eggs buttons, which sit in the top-bar row.
local function topCentreBase(scale: number): number
	local insetY = GuiService:GetGuiInset().Y
	local travelBottom = math.max(layout.TravelTop, layout.TravelTop * scale) + layout.TravelHeight * scale
	return math.max(insetY, travelBottom) + layout.TopGap * scale
end

local function place()
	if not gui then
		return
	end
	local alarmShown = alarm.frame.Visible
	local count = (if alarmShown then 1 else 0) + (if carry.frame.Visible then 1 else 0)
	carry.frame.Position = UDim2.new(0.5, 0, 0, if alarmShown then look.Height + look.Gap else 0)

	-- While the tutorial panel is below us it holds the toast reservation
	-- for both, so ours must be clear and theirs is the one to ignore.
	local belowKey = panelBelowKey
	if belowKey then
		NotificationController.ReserveTop(RESERVE_KEY, nil)
	end
	local scale = stackScale.Scale
	local originY = origin.AbsolutePosition.Y
	local top = topCentreBase(scale)
	local above = NotificationController.ReservedBottom(belowKey or RESERVE_KEY)
	if above then
		top = math.max(top, above - originY + Config.UI.Tutorial.StackGap * scale)
	end
	top = math.floor(top + 0.5)
	stack.Position = UDim2.new(0.5, 0, 0, top)

	local bottom: number? = nil
	if count > 0 then
		bottom = originY + top + (count * look.Height + (count - 1) * look.Gap) * scale
	end
	if not belowKey then
		NotificationController.ReserveTop(RESERVE_KEY, bottom)
	end
	if bottom ~= bannerBottom then
		bannerBottom = bottom
		StealController.BannersChanged:Fire()
	end
end

--- Bottom edge of the visible steal banners in screen px (the same space
--- as NotificationController.ReserveTop), or nil when none shows.
function StealController.BannerBottom(): number?
	return bannerBottom
end

--- A panel that reserves the top under `key` sits below the banners (the
--- tutorial). While set, the banners stack under every reservation but that
--- one and leave the toast reservation to it. nil when it goes away.
function StealController.SetPanelBelow(key: string?)
	if panelBelowKey == key then
		return
	end
	panelBelowKey = key
	place()
end

--------------------------------------------------------------------------
-- Owner alarm
--------------------------------------------------------------------------

type AlarmState = { Phase: string, Info: { [string]: any }, Until: number? }
local alarmState: AlarmState? = nil
local watchedNestIndex: number? = nil

local function formatClock(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function setOutline(model: Instance, on: boolean)
	local existing = model:FindFirstChild("StealOutline")
	if on and not existing then
		local highlight = Instance.new("Highlight")
		highlight.Name = "StealOutline"
		highlight.FillTransparency = look.OutlineFillTransparency
		highlight.FillColor = C.Blood
		highlight.OutlineColor = C.BloodBright
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		highlight.Parent = model
	elseif not on and existing then
		existing:Destroy()
	end
end

local function myNestItem(nestIndex: number?): Instance?
	if not nestIndex then
		return nil
	end
	local runtime = Workspace:FindFirstChild("Runtime")
	if not runtime then
		return nil
	end
	for _, model in ipairs(runtime:GetChildren()) do
		if model:GetAttribute("OwnerUserId") == localPlayer.UserId
			and model:GetAttribute("NestIndex") == nestIndex
			and not CollectionService:HasTag(model, Config.Tags.CarriedItem) then
			return model
		end
	end
	return nil
end

local function playAlarm(times: number)
	task.spawn(function()
		for i = 1, times do
			SoundController.Play("StealAlarm")
			if i < times then
				task.wait(Config.Feedback.AlarmRepeatGap)
			end
		end
	end)
end

local function setAlarm(phase: string, info: { [string]: any }, showFor: number?)
	local state: AlarmState = {
		Phase = phase,
		Info = info,
		Until = if showFor then os.clock() + showFor else nil,
	}
	alarmState = state
end

local function onAlarm(phase: string, info: { [string]: any })
	local thief = tostring(info.Thief or "Someone")
	local item = tostring(info.Item or "cryptid")

	-- Outline on the nest item only while a hold is in progress.
	if watchedNestIndex then
		local previous = myNestItem(watchedNestIndex)
		if previous then
			setOutline(previous, false)
		end
		watchedNestIndex = nil
	end

	if phase == "Started" then
		watchedNestIndex = tonumber(info.NestIndex)
		local target = myNestItem(watchedNestIndex)
		if target then
			setOutline(target, true)
		end
		setAlarm(phase, info, look.StartedShowTime)
		playAlarm(look.AlarmRings.Started)
	elseif phase == "Stopped" then
		if alarmState and alarmState.Phase == "Started" then
			alarmState = nil
		end
	elseif phase == "Stolen" or phase == "Dropped" then
		setAlarm(phase, info, nil)
		playAlarm(if phase == "Stolen" then look.AlarmRings.Stolen else look.AlarmRings.Dropped)
	elseif phase == "Claimed" or phase == "Returned" then
		setAlarm(phase, info, look.EndedShowTime)
	end

	local state = alarmState
	if state then
		state.Info.Thief = thief
		state.Info.Item = item
	end
end

local function hideAlarm()
	alarmState = nil
	setShown(alarm, false)
end

local function renderAlarm()
	local state = alarmState
	if not state then
		setShown(alarm, false)
		return
	end
	if state.Until and os.clock() > state.Until then
		hideAlarm()
		return
	end

	local info = state.Info
	local remaining = (tonumber(info.ReturnAt) or 0) - Workspace:GetServerTimeNow()
	local text
	if state.Phase == "Started" then
		text = string.format("%s is stealing your %s!", info.Thief, info.Item)
	elseif state.Phase == "Stolen" then
		text = string.format("%s grabbed your %s! Bat them! (home in %s)", info.Thief, info.Item, formatClock(remaining))
	elseif state.Phase == "Dropped" then
		text = string.format("Your %s is on the ground — grab it back! (%s)", info.Item, formatClock(remaining))
	elseif state.Phase == "Claimed" then
		text = string.format("%s got away with your %s.", info.Thief, info.Item)
	else -- Returned
		text = string.format("Your %s is home safe.", info.Item)
	end
	if (state.Phase == "Stolen" or state.Phase == "Dropped") and remaining <= 0 then
		hideAlarm()
		return
	end
	alarm.label.Text = text
	paint(alarm, state.Phase, ALARM_STYLES[state.Phase] or ALARM_STYLES.Returned)
	if setShown(alarm, true) then
		-- A quick drop-in so it catches the eye.
		alarm.frame.Position = UDim2.new(0.5, 0, 0, -look.DropIn)
		UI.Tween(alarm.frame, look.DropInTime, { Position = UDim2.fromScale(0.5, 0) },
			Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	end
end

--------------------------------------------------------------------------
-- Carried / dropped items
--------------------------------------------------------------------------

local function updateCarried(model: Instance)
	local mine = model:GetAttribute("OwnerUserId") == localPlayer.UserId
	setOutline(model, mine)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == "PickupPrompt" then
			d.ActionText = if mine then "Take back" elseif model:GetAttribute("Source") == "Belt" then "Grab egg" else "Pick up"
			d.Enabled = mine or localPlayer:GetAttribute("Carrying") ~= true
		end
	end
end

local function myCarriedModel(): Instance?
	for _, model in ipairs(CollectionService:GetTagged(Config.Tags.CarriedItem)) do
		if model:GetAttribute("CarrierUserId") == localPlayer.UserId and not model:GetAttribute("Dropped") then
			return model
		end
	end
	return nil
end

local function renderCarrying()
	if localPlayer:GetAttribute("Carrying") ~= true then
		setShown(carry, false)
		return
	end
	local model = myCarriedModel()
	local label = model and model:GetAttribute("ItemLabel") or "stolen item"
	local source = model and model:GetAttribute("Source")
	if source == "Belt" then
		-- A bought egg: no timer, but anyone can knock it loose.
		carry.label.Text = string.format("Carrying %s — take it to your camp's pad!", tostring(label))
		paint(carry, "Belt", CARRY_STYLES.Belt)
	elseif source == "Sighting" then
		-- A captured wild cryptid: no timer while held, but it's lit up.
		carry.label.Text = string.format("Carrying %s — get it to your camp's pad! Everyone can see you.", tostring(label))
		paint(carry, "Sighting", CARRY_STYLES.Sighting)
	else
		local returnAt = model and model:GetAttribute("ReturnAt")
		if typeof(returnAt) == "number" then
			local remaining = returnAt - Workspace:GetServerTimeNow()
			carry.label.Text = string.format("Carrying %s — run to your camp's pad! (%s)", tostring(label), formatClock(remaining))
		else
			carry.label.Text = string.format("Carrying %s — run to your camp's pad!", tostring(label))
		end
		paint(carry, "Stolen", CARRY_STYLES.Stolen)
	end
	setShown(carry, true)
end

local function refresh()
	renderAlarm()
	renderCarrying()
	place()
end

--------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------

function StealController.Start()
	local screen = UI.new("ScreenGui", {
		Name = "StealUI",
		ResetOnSpawn = false,
		IgnoreGuiInset = true, -- placed from the very top, like the HUD's top row
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = Config.UI.Layers.Steal,
	}) :: ScreenGui
	origin = UI.new("Frame", {
		Name = "Origin",
		BackgroundTransparency = 1,
		Size = UDim2.new(),
		Parent = screen,
	}) :: Frame
	stack = UI.new("Frame", {
		Name = "Banners",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(look.Width, 0),
		BackgroundTransparency = 1,
		Parent = screen,
	}) :: Frame
	stackScale = UI.Scale(stack)
	alarm = makeBanner("Alarm")
	carry = makeBanner("Carrying")
	screen.Parent = localPlayer:WaitForChild("PlayerGui")
	gui = screen

	NotificationController.ReservationsChanged:Connect(place)

	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("StealAlarm") :: RemoteEvent
	remote.OnClientEvent:Connect(function(phase, info)
		if typeof(phase) == "string" and typeof(info) == "table" then
			onAlarm(phase, info)
			refresh()
		end
	end)

	for _, model in ipairs(CollectionService:GetTagged(Config.Tags.CarriedItem)) do
		updateCarried(model)
	end
	CollectionService:GetInstanceAddedSignal(Config.Tags.CarriedItem):Connect(function(model)
		task.defer(updateCarried, model) -- let descendants arrive first
	end)

	task.spawn(function()
		while true do
			refresh()
			for _, model in ipairs(CollectionService:GetTagged(Config.Tags.CarriedItem)) do
				updateCarried(model)
			end
			task.wait(look.RefreshInterval)
		end
	end)
end

return StealController
