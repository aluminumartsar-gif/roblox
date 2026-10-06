--!strict
--[[
	SpinWheelController
	StarterPlayerScripts/Client/Controllers/SpinWheelController

	The prize wheel ("campfire field kit" Window "SpinWheel"), opened from
	the HUD's Spin tile.

	  wheel       one coloured segment per Config.Retention.Spin.Prizes entry,
	              clockwise from the top, each with the prize's icon and short
	              label; dark spokes between them, a hub, and the ember pointer
	              at Spin.PointerAngle (the top).
	  status      spins left, the countdown to the next free spin, "Round and
	              round..." while it turns, then what you won.
	  SPIN        asks the server to spin. The SERVER picks the prize, gives it
	              and says which segment it was; we then turn the wheel to land
	              on that segment (a tick sound per segment passed, a fanfare
	              at the end) and show what you won. Shows how many spins you
	              have; under it, whether the free spin is ready (or when it
	              is) and how many extra (bought) spins you have.
	  +3 SPINS    buys the Extra Spins product (Robux; the server prompts).

	HUD: red "!" while a spin is ready ("Spin!"); otherwise the tile counts
	down to the next free one.

	Display only: RetentionService rolls the prize.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Components = script.Parent.Parent:WaitForChild("Components")
local Theme = require(Components:WaitForChild("Theme"))
local UI = require(Components:WaitForChild("UI"))
local Icon = require(Components:WaitForChild("Icon"))
local Window = require(Components:WaitForChild("Window"))
local HudController = require(script.Parent:WaitForChild("HudController"))
local Retention = require(script.Parent:WaitForChild("DailyRewardsController"))

local SpinWheelController = {}

local C = Theme.Colors
local SPIN = Config.Retention.Spin
local TUNING = Config.UI.Retention.Spin
local TICK_MIN_GAP = 0.04 -- seconds; stops the tick sound machine-gunning at full speed

type Slot = { icon: ImageLabel, label: TextLabel, angle: number }

local window: Window.Window? = nil
local wheel: GuiObject? = nil
local slots: { Slot } = {}
local spinButton: TextButton? = nil
local buyButton: TextButton? = nil
local statusLabel: TextLabel? = nil
local statusPunch: UIScale? = nil
local freeLabel: TextLabel? = nil
local extraLabel: TextLabel? = nil
local spinning = false
local buying = false
local resultText: string? = nil -- shown on the status line after a spin, until the next one

local function spinState(): { [string]: any }?
	local s = Retention.GetState()
	return s and s.Spin
end

--- Spins available right now: bought ones, plus the free one once its time
--- has come (even if the server hasn't sent fresh state since).
local function spinsNow(spin: { [string]: any }?): number
	if not spin then
		return 0
	end
	local freeReady = (tonumber(spin.NextFreeAt) or 0) <= Retention.ServerNow()
	return (tonumber(spin.Extra) or 0) + (if freeReady then 1 else 0)
end

local function themeColor(name: string, fallback: Color3): Color3
	local color = (C :: any)[name]
	return if typeof(color) == "Color3" then color else fallback
end

--- "4 hours", "1 hour", "90 minutes".
local function durationText(seconds: number): string
	if seconds >= 3600 and seconds % 3600 == 0 then
		local hours = seconds // 3600
		return if hours == 1 then "hour" else string.format("%d hours", hours)
	end
	local minutes = math.max(1, seconds // 60)
	return if minutes == 1 then "minute" else string.format("%d minutes", minutes)
end

--------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------

local function renderSlots()
	local spin = spinState()
	local prizes = spin and spin.Prizes or {}
	for i, slot in ipairs(slots) do
		local prize = prizes[i]
		slot.icon.Visible = prize ~= nil
		slot.label.Text = if prize then tostring(prize.Short or "") else ""
		if prize then
			local name = prize.Icon
			Icon.set(slot.icon, if typeof(name) == "string" and Config.Icons[name] then name else "Star")
		end
	end
end

local function renderStatus()
	local spin = spinState()
	local spins = spinsNow(spin)
	local text: string
	if not spin then
		text = "Loading..."
	elseif not spin.Enabled then
		text = "The wheel is resting for now."
	elseif spinning then
		text = "Round and round..."
	elseif resultText then
		text = "You won " .. resultText .. "!"
	elseif spins > 0 then
		text = if spins == 1 then "You have 1 spin!" else string.format("You have %d spins!", spins)
	else
		local remaining = (tonumber(spin.NextFreeAt) or 0) - Retention.ServerNow()
		text = "Free spin in " .. Retention.FormatClock(remaining)
	end
	if statusLabel then
		statusLabel.Text = text
	end

	-- Free / extra spin lines under SPIN.
	if freeLabel then
		if not spin or not spin.Enabled then
			freeLabel.Text = "Free spin: -"
		else
			local remaining = (tonumber(spin.NextFreeAt) or 0) - Retention.ServerNow()
			freeLabel.Text = if remaining <= 0 then "Free spin: READY"
				else "Next free spin in " .. Retention.FormatClock(remaining)
			freeLabel.TextColor3 = if remaining <= 0 then C.MossBright else C.TextDim
		end
	end
	if extraLabel then
		extraLabel.Text = "Extra spins: " .. tostring(if spin then tonumber(spin.Extra) or 0 else 0)
	end

	if spinButton then
		local label = if spinning then "..." elseif spins > 0 then string.format("SPIN (%d)", spins) else "NO SPINS"
		UI.SetButtonText(spinButton, label)
		UI.SetButtonEnabled(spinButton, spins > 0 and not spinning)
	end
	if buyButton then
		local product = Config.DevProducts.ExtraSpins
		UI.SetButtonText(buyButton, string.format("+%d SPINS  %s", product.Count, Retention.PriceText("ExtraSpins")))
	end
end

local function renderHud()
	local spin = spinState()
	if not spin or not spin.Enabled then
		HudController.SetAlert("SpinBtn", false)
		HudController.SetCaption("SpinBtn", "Spin")
		return
	end
	local spins = spinsNow(spin)
	local readyNow = spins > 0
	HudController.SetAlert("SpinBtn", readyNow)
	if readyNow then
		HudController.SetCaption("SpinBtn", "Spin!")
	else
		HudController.SetCaption("SpinBtn", Retention.FormatClock((tonumber(spin.NextFreeAt) or 0) - Retention.ServerNow()))
	end
end

--------------------------------------------------------------------------
-- Spinning
--------------------------------------------------------------------------

--- Turns the wheel so slot `index` ends up under the pointer, ticking for
--- every slot that passes. Yields until it stops.
local function animateTo(index: number)
	local w = wheel
	local slot = slots[index]
	if not w or not slot then
		return
	end
	local segment = 360 / math.max(1, #slots)
	-- Land somewhere inside the slot, not always dead centre.
	local jitter = (math.random() - 0.5) * segment * 0.5
	local start = w.Rotation % 360
	w.Rotation = start
	local landing = (SPIN.PointerAngle - slot.angle + jitter - start) % 360
	local target = start + SPIN.ExtraTurns * 360 + landing

	local tween = TweenService:Create(w, TweenInfo.new(SPIN.SpinTime, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Rotation = target })
	local lastStep = math.floor(start / segment)
	local lastTick = 0
	local connection = RunService.RenderStepped:Connect(function()
		local step = math.floor(w.Rotation / segment)
		if step ~= lastStep then
			lastStep = step
			local now = os.clock()
			if now - lastTick >= TICK_MIN_GAP then
				lastTick = now
				Retention.Play("SpinTick")
			end
		end
	end)
	tween:Play()
	tween.Completed:Wait()
	connection:Disconnect()
	w.Rotation = target % 360
end

--- The status line pops when you win.
local function punchStatus()
	local punch = statusPunch
	if punch then
		punch.Scale = TUNING.WinPunchScale
		UI.Tween(punch, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
	end
end

local function spin()
	local s = spinState()
	if spinning or not s or spinsNow(s) <= 0 then
		if s and spinsNow(s) <= 0 then
			Retention.Play("Error")
		end
		return
	end
	spinning = true
	resultText = nil
	renderStatus()
	Retention.Play("UIClick")
	local result = Retention.Invoke("SpinWheel")
	if result and result.Ok and typeof(result.Index) == "number" then
		animateTo(result.Index)
		resultText = tostring(result.Text or "a prize")
		Retention.Play("SpinWin")
		spinning = false
		renderStatus()
		punchStatus()
		return
	end
	spinning = false
	renderStatus()
end

local function buySpins()
	if buying then
		return
	end
	buying = true
	Retention.Play("UIClick")
	Retention.Invoke("PromptPurchase", "Product", "ExtraSpins")
	buying = false
end

--------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------

--- A thin bar from the wheel's centre out to `length` px at `angle`
--- (degrees clockwise from the top). The holder is centred on the wheel and
--- rotates about it; only its top half is painted.
local function radialBar(parent: Instance, angle: number, width: number, length: number, color: Color3, zIndex: number, name: string): Frame
	local holder = UI.new("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(width, length * 2),
		Rotation = angle,
		BackgroundTransparency = 1,
		ZIndex = zIndex,
		Parent = parent,
	})
	UI.new("Frame", {
		Name = "Paint",
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 0.5),
		ZIndex = zIndex,
		Parent = holder,
	})
	return holder
end

--- The wheel, centred in `area`. Returns the rotating frame.
local function buildWheel(area: Frame): GuiObject
	local radius = TUNING.WheelRadius
	local rim = TUNING.RimWidth
	local count = math.max(1, #SPIN.Prizes)
	local segment = 360 / count

	-- Back plate and rim (don't turn).
	UI.new("Frame", {
		Name = "Plate",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset((radius + rim) * 2, (radius + rim) * 2),
		BackgroundColor3 = C.Inset,
		BorderSizePixel = 0,
		ZIndex = 1,
		Parent = area,
	}, {
		UI.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		UI.Stroke({ Color = C.Shadow, Thickness = 2, Transparency = 0.3 }),
	})

	local turning = UI.new("Frame", {
		Name = "Wheel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(radius * 2, radius * 2),
		BackgroundTransparency = 1,
		ZIndex = 2,
		Parent = area,
	}) :: Frame

	-- Segments: a fan of thin bars each (GUI frames can't be wedge-shaped).
	-- Segment i is centred on (i-1) * segment degrees, so prize 1 starts
	-- under a pointer at the top.
	local bars = math.max(1, math.ceil(segment / TUNING.FanStep))
	local step = segment / bars
	local barWidth = math.ceil(2 * math.pi * radius * step / 360) + 1
	local palette = TUNING.Segments
	for i = 1, count do
		local style = palette[((i - 1) % #palette) + 1]
		local fill = themeColor(style.Fill, C.Raised)
		local centre = (i - 1) * segment
		local first = centre - segment / 2
		for k = 1, bars do
			radialBar(turning, first + (k - 0.5) * step, barWidth, radius, fill, 1 + i, "Seg" .. i)
		end
	end

	-- Spokes between segments, drawn over the fans' soft edges.
	for i = 1, count do
		radialBar(turning, (i - 1) * segment - segment / 2, TUNING.SpokeWidth, radius, C.Inset, count + 3, "Spoke")
	end

	-- Prize icon + short label, near the rim of each segment.
	for i = 1, count do
		local style = palette[((i - 1) % #palette) + 1]
		local textColor = themeColor(style.Text, C.Text)
		local angle = (i - 1) * segment
		local holder = UI.new("Frame", {
			Name = "Prize" .. i,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(radius * 2, radius * 2),
			Rotation = angle,
			BackgroundTransparency = 1,
			ZIndex = count + 4,
			Parent = turning,
		})
		local icon = UI.Icon("Star", math.floor(radius * 0.24), {
			Name = "Icon",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0, math.floor(radius * 0.26)),
			ImageColor3 = textColor,
			Visible = false,
			ZIndex = count + 4,
			Parent = holder,
		})
		local label = UI.Text({
			Name = "Label",
			Role = "Heading",
			Weight = "Bold",
			Text = "",
			RichText = false,
			TextScaled = true,
			TextWrapped = true,
			TextColor3 = textColor,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0, math.floor(radius * 0.5)),
			Size = UDim2.fromOffset(math.floor(radius * 0.46), math.floor(radius * 0.22)),
			ZIndex = count + 4,
			Parent = holder,
		})
		UI.new("UITextSizeConstraint", { MaxTextSize = 17, MinTextSize = 9, Parent = label })
		table.insert(slots, { icon = icon, label = label, angle = angle })
	end

	-- Rim ring over the segments' outer ends (doesn't turn).
	UI.new("Frame", {
		Name = "Rim",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(radius * 2, radius * 2),
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = area,
	}, {
		UI.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		UI.Stroke({ Color = C.Edge, Thickness = rim }),
	})

	-- Hub (doesn't turn).
	local hub = TUNING.HubRadius
	UI.new("Frame", {
		Name = "Hub",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(hub * 2, hub * 2),
		BackgroundColor3 = C.Raised,
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = area,
	}, {
		UI.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		UI.Stroke({ Color = C.EdgeBright, Thickness = 2 }),
		UI.Icon("Spinner", math.floor(hub * 1.2), {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			ImageColor3 = C.Ember,
			ZIndex = 4,
		}),
	})

	-- Pointer: an ember diamond over the rim at PointerAngle, tip inward.
	local pointerAngle = math.rad(SPIN.PointerAngle)
	local size = TUNING.PointerSize
	local out = radius + rim - size * 0.1
	UI.new("Frame", {
		Name = "Pointer",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, math.floor(math.sin(pointerAngle) * out), 0.5, -math.floor(math.cos(pointerAngle) * out)),
		Size = UDim2.fromOffset(size, size),
		Rotation = 45 + SPIN.PointerAngle,
		BackgroundColor3 = C.Ember,
		BorderSizePixel = 0,
		ZIndex = 5,
		Parent = area,
	}, {
		UI.new("UICorner", { CornerRadius = UDim.new(0, 3) }),
		UI.Stroke({ Color = C.EmberDeep, Thickness = 2 }),
		UI.new("Frame", {
			Name = "Nail",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(math.floor(size * 0.3), math.floor(size * 0.3)),
			BackgroundColor3 = C.EmberBright,
			BorderSizePixel = 0,
			ZIndex = 5,
		}, { UI.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }) }),
	})

	return turning
end

local function build()
	local w = Window.new({
		Name = "SpinWheel",
		Title = "Prize Wheel",
		Icon = "Spinner",
		Size = TUNING.WindowSize,
	})
	window = w
	w.OnOpen = function()
		resultText = nil
		renderSlots()
		renderStatus()
	end
	local body = w.Body

	-- Left: the wheel (with room for the pointer), full body height.
	local wheelSpace = TUNING.WheelRadius * 2 + TUNING.RimWidth * 2 + TUNING.PointerSize
	local area = UI.new("Frame", {
		Name = "WheelArea",
		BackgroundTransparency = 1,
		Size = UDim2.new(0, wheelSpace, 1, 0),
		Parent = body,
	}) :: Frame
	wheel = buildWheel(area)
	if #slots ~= #SPIN.Prizes then
		warn(string.format("[SAC/Spin] the wheel has %d slots but Config has %d prizes", #slots, #SPIN.Prizes))
	end

	-- Right: status, free/extra spins, SPIN and buy.
	local column = UI.new("Frame", {
		Name = "Controls",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(1, -wheelSpace, 1, 0),
		Parent = body,
	}, {
		UI.List({ Padding = 8, HorizontalAlignment = Enum.HorizontalAlignment.Center }),
	})

	-- The status text sits centred in a holder so its win "punch" grows
	-- from the middle.
	local statusHolder = UI.new("Frame", {
		Name = "StatusHolder",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 62),
		LayoutOrder = 1,
		Parent = column,
	})
	local status = UI.Text({
		Name = "Status",
		Role = "Heading",
		Weight = "Bold",
		Text = "Loading...",
		RichText = false,
		TextSize = 24,
		TextScaled = true,
		TextWrapped = true,
		TextColor3 = C.Text,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		Parent = statusHolder,
	})
	UI.new("UITextSizeConstraint", { MaxTextSize = 24, MinTextSize = 12, Parent = status })
	statusLabel = status
	statusPunch = UI.new("UIScale", { Name = "Punch", Parent = status }) :: UIScale

	UI.Text({
		Name = "Note",
		Role = "Notes",
		Text = string.format("One free spin every %s. The woods pick the prize.", durationText(SPIN.FreeEvery)),
		TextSize = 15,
		TextWrapped = true,
		TextColor3 = C.TextDim,
		Size = UDim2.new(1, 0, 0, 40),
		LayoutOrder = 2,
		Parent = column,
	})

	freeLabel = UI.Text({
		Name = "Free",
		Role = "Heading",
		Weight = "SemiBold",
		Text = "",
		RichText = false,
		TextSize = 17,
		TextColor3 = C.TextDim,
		Size = UDim2.new(1, 0, 0, 22),
		LayoutOrder = 3,
		Parent = column,
	})
	extraLabel = UI.Text({
		Name = "Extra",
		Role = "Heading",
		Weight = "SemiBold",
		Text = "",
		RichText = false,
		TextSize = 17,
		TextColor3 = C.TextDim,
		Size = UDim2.new(1, 0, 0, 22),
		LayoutOrder = 4,
		Parent = column,
	})

	local spinBtn = UI.Button({
		Name = "SpinBtn",
		Text = "Spin",
		Variant = "Primary",
		Icon = "Spinner",
		TextSize = 26,
		Size = UDim2.new(1, 0, 0, 60),
		LayoutOrder = 5,
		Parent = column,
		OnClick = function()
			task.spawn(spin)
		end,
	})
	-- spin() plays its own click (only when a spin actually starts; an
	-- error sound instead when there's none left).
	spinBtn:SetAttribute("SAC_NoClick", true)
	spinButton = spinBtn

	local buyBtn = UI.Button({
		Name = "BuySpinsBtn",
		Text = "+3 Spins",
		Variant = "Moon",
		Icon = "Robux",
		TextSize = 19,
		Size = UDim2.new(1, 0, 0, 48),
		LayoutOrder = 6,
		Parent = column,
		OnClick = function()
			task.spawn(buySpins)
		end,
	})
	buyBtn:SetAttribute("SAC_NoClick", true) -- buySpins() plays the click
	buyButton = buyBtn
end

function SpinWheelController.Open()
	local w = window
	if w then
		w:Open()
	end
end

function SpinWheelController.Start()
	build()
	HudController.Bind("SpinBtn", SpinWheelController.Open, "Spin", "Spinner")
	HudController.SetAlert("SpinBtn", false)

	Retention.StateChanged:Connect(function()
		renderSlots()
		renderStatus()
		renderHud()
	end)
	if Retention.GetState() then
		renderSlots()
		renderStatus()
		renderHud()
	end

	task.spawn(function()
		while true do
			task.wait(1)
			renderHud()
			local w = window
			if w and w:IsOpen() and not spinning then
				renderStatus()
			end
		end
	end)
end

return SpinWheelController
