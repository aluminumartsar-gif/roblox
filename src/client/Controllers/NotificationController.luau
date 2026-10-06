--!strict
--[[
	NotificationController
	StarterPlayerScripts/Client/Controllers/NotificationController

	Toast messages at the top centre of the screen, under any banner. Fed by
	the server's Notify remote and by local code (e.g. the result of a button
	press).

	Each toast is a charred field-kit card: a coloured strip down its left
	edge, a matching border and an icon (Config.Feedback.ToastIcons) show
	the kind — Info moonlight blue, Success moss green, Warning ember,
	Error blood red (colours: Config.UI.Toasts.KindColors). It slides down
	into place and fades in, plays a soft sound (Config.Feedback.ToastSounds;
	silent if another sound just played, so it never piles on top of a hatch
	fanfare; errors always sound), and fades out after
	Config.UI.NotificationDuration. Long messages wrap onto a second line
	instead of running off a phone screen. At most Config.UI.MaxNotifications
	show at once; a new one pushes the oldest out.
	Server-wide announcements (GlobalAnnounce) are bigger cards tinted with
	the rarity's colour (Theme.RarityColor, so Secret stays readable).

	API (unchanged): NotificationController.Show(text, kind?, color?)
	  kind: "Info" | "Success" | "Warning" | "Error" | "Announce"
	  color: overrides the kind's colour (announcements pass the rarity's).

	Top-centre stacking: banners (sightings, the Hunt) and the tutorial
	panel call ReserveTop(key, bottomPx | nil); toasts sit below the lowest
	one. ReservedBottom(except?) gives the lowest reserved edge (in screen
	pixels) ignoring one key, and ReservationsChanged fires on any change,
	so a panel can place itself under the banners.

	Look: Config.UI.Toasts. Draw order: Config.UI.Layers.Toast.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Signal = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Util"):WaitForChild("Signal"))
local Components = script.Parent.Parent:WaitForChild("Components")
local Theme = require(Components:WaitForChild("Theme"))
local UI = require(Components:WaitForChild("UI"))
local HudLayout = require(Components:WaitForChild("HudLayout"))

local NotificationController = {}

--- Fires after any ReserveTop call (banners and panels moved or hid).
NotificationController.ReservationsChanged = Signal.new()

local C = Theme.Colors
local LOOK = Config.UI.Toasts

local container: Frame? = nil
local sequence = 0

--- A colour from Theme.Colors by name (Config.UI.Toasts names them).
local function themeColor(name: string?, fallback: Color3): Color3
	local color = if name then (C :: any)[name] else nil
	return if typeof(color) == "Color3" then color else fallback
end

--- SoundController starts after this controller, so fetch it lazily (and
--- never wait for it).
local function playSound(kind: string)
	local name = Config.Feedback.ToastSounds[kind]
	local module = script.Parent:FindFirstChild("SoundController")
	if not name or not module or not module:IsA("ModuleScript") then
		return
	end
	local ok, controller = pcall(require, module)
	if ok and typeof(controller) == "table" and typeof(controller.Play) == "function" then
		controller.Play(name, if kind == "Error" then nil else { IfQuietFor = Config.Feedback.ToastSoundQuietFor })
	end
end

-- One property of one toast part that fades: the instance, the property
-- and its value while the toast is fully shown.
type Fade = { Target: Instance, Property: string, Shown: number }

local function addFade(fades: { Fade }, target: Instance, property: string, shown: number)
	table.insert(fades, { Target = target, Property = property, Shown = shown })
end

local function fadeTo(fades: { Fade }, info: TweenInfo, hidden: boolean)
	for _, fade in ipairs(fades) do
		if fade.Target.Parent then
			UI.Tween(fade.Target, info.Time, { [fade.Property] = if hidden then 1 else fade.Shown }, info.EasingStyle, info.EasingDirection)
		end
	end
end

function NotificationController.Show(text: string, kind: string?, color: Color3?)
	if not container or text == "" then
		return
	end
	local frame = container :: Frame
	local toastKind = kind or "Info"
	local announce = toastKind == "Announce"

	-- Drop the oldest if we're at the cap.
	local toasts = {}
	for _, child in ipairs(frame:GetChildren()) do
		if child:IsA("Frame") and child.Name == "Toast" then
			table.insert(toasts, child)
		end
	end
	table.sort(toasts, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	while #toasts >= Config.UI.MaxNotifications do
		local oldest = table.remove(toasts, 1)
		if oldest then
			oldest:Destroy()
		end
	end

	sequence += 1
	local height = if announce then LOOK.AnnounceHeight else LOOK.Height
	local kindColors: { [string]: string } = LOOK.KindColors
	local accent = color or themeColor(kindColors[toastKind], themeColor(kindColors.Info, C.Moon))
	local fades: { Fade } = {}

	-- Holder keeps the slot in the list; the card inside slides into it.
	local holder = UI.new("Frame", {
		Name = "Toast",
		LayoutOrder = sequence,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, height),
		BackgroundTransparency = 1,
	}) :: Frame

	-- The card: charred wood, tinted by the rarity colour for announcements.
	local top = if announce then Theme.Mix(C.PanelTop, accent, LOOK.AnnounceTint) else C.RaisedTop
	local bottom = if announce then Theme.Mix(C.Panel, accent, LOOK.AnnounceTint * 0.5) else C.Panel
	local body = UI.new("Frame", {
		Name = "Body",
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, height),
		Position = UDim2.fromOffset(0, -LOOK.SlideFrom),
		BackgroundColor3 = Color3.new(1, 1, 1), -- white base: the gradient gives the colour
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = holder,
	}, {
		UI.Corner(Theme.Tuning.Corner),
		UI.Gradient(Theme.Sequence(top, bottom), 90),
	}) :: Frame
	addFade(fades, body, "BackgroundTransparency", LOOK.CardTransparency)

	local stroke = UI.Stroke({
		Name = "Edge",
		Color = if announce then accent else Theme.Mix(C.Edge, accent, 0.45),
		Thickness = if announce then 2 else 1,
		Transparency = 1,
		Parent = body,
	})
	addFade(fades, stroke, "Transparency", if announce then 0.1 else 0.25)

	-- The kind's colour down the left edge.
	local stripWidth = if announce then 4 else 3
	local strip = UI.new("Frame", {
		Name = "Strip",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 4, 0.5, 0),
		Size = UDim2.new(0, stripWidth, 1, -10),
		BackgroundColor3 = accent,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = body,
	}, { UI.Corner(2) })
	addFade(fades, strip, "BackgroundTransparency", 0)

	-- Icon and text, side by side.
	local content = UI.new("Frame", {
		Name = "Content",
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, height),
		BackgroundTransparency = 1,
		Parent = body,
	}, {
		UI.List({
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = 8,
		}),
		UI.Padding({ Left = 4 + stripWidth + 8, Right = 14, Top = 5, Bottom = 5 }),
	})

	local iconName = Config.Feedback.ToastIcons[toastKind]
	if iconName then
		local icon = UI.Icon(iconName, if announce then LOOK.AnnounceIconSize else LOOK.IconSize, {
			LayoutOrder = 1,
			ImageColor3 = accent,
			ImageTransparency = 1,
			Parent = content,
		})
		addFade(fades, icon, "ImageTransparency", 0)
	end

	local textSize = if announce then LOOK.AnnounceTextSize else LOOK.TextSize
	local label = UI.Text({
		Name = "Message",
		Role = "Heading",
		Weight = if announce then "Bold" else "SemiBold",
		Text = text,
		RichText = false, -- show messages exactly as sent
		TextSize = textSize,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.Text,
		TextTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, textSize + 4),
		LayoutOrder = 2,
		Parent = content,
	})
	-- Wrap instead of running off the screen.
	UI.new("UISizeConstraint", {
		MaxSize = Vector2.new(if announce then LOOK.AnnounceMaxWidth else LOOK.MaxWidth, math.huge),
		Parent = label,
	})
	addFade(fades, label, "TextTransparency", 0)

	holder.Parent = frame

	-- Slide down + fade in.
	local inInfo = TweenInfo.new(Config.Feedback.ToastSlideTime, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	UI.Tween(body, inInfo.Time, { Position = UDim2.fromOffset(0, 0) }, inInfo.EasingStyle, inInfo.EasingDirection)
	fadeTo(fades, inInfo, false)
	playSound(toastKind)

	task.delay(Config.UI.NotificationDuration, function()
		if holder.Parent then
			fadeTo(fades, TweenInfo.new(LOOK.FadeOutTime), true)
			task.delay(LOOK.FadeOutTime, function()
				holder:Destroy()
			end)
		end
	end)
end

-- Banners at the top of the screen (sightings, the Hunt) reserve space so
-- toasts never cover them: key -> the banner's bottom edge in screen pixels.
local reservations: { [string]: number } = {}
local stackBase: UDim2? = nil

local function placeStack()
	local frame = container
	local base = stackBase
	if not frame or not base then
		return
	end
	local lowest: number? = nil
	for _, bottom in pairs(reservations) do
		if not lowest or bottom > lowest then
			lowest = bottom
		end
	end
	-- On a narrow screen the toasts would cover the camp panel: go below it.
	local list = frame:FindFirstChildOfClass("UIListLayout")
	local scale = frame:FindFirstChildOfClass("UIScale")
	local widest = if list then list.AbsoluteContentSize.X else 0
	if widest > 0 then
		local camp = HudLayout.CampClearance(widest, if scale then scale.Scale else 1)
		if camp and (not lowest or camp > lowest) then
			lowest = camp
		end
	end
	local gui = frame:FindFirstAncestorWhichIsA("LayerCollector")
	if lowest then
		local guiTop = if gui and gui:IsA("ScreenGui") then gui.AbsolutePosition.Y else 0
		local wanted = lowest + LOOK.BannerGap - guiTop
		frame.Position = UDim2.new(base.X.Scale, base.X.Offset, base.Y.Scale, math.max(base.Y.Offset, wanted))
	else
		frame.Position = base
	end

	-- Never run down over the HUD's cash and buff timers (or off the
	-- screen): drop the oldest toasts until the newest ones fit.
	if gui and gui:IsA("ScreenGui") then
		local limit = gui.AbsoluteSize.Y - HudLayout.BottomReserve() - LOOK.BannerGap
		local toasts: { Frame } = {}
		for _, child in ipairs(frame:GetChildren()) do
			if child:IsA("Frame") and child.Name == "Toast" then
				table.insert(toasts, child)
			end
		end
		table.sort(toasts, function(a, b)
			return a.LayoutOrder < b.LayoutOrder
		end)
		local bottom = frame.Position.Y.Offset + frame.AbsoluteSize.Y
		local gap = if list then list.Padding.Offset * (if scale then scale.Scale else 1) else 0
		while #toasts > 1 and bottom > limit do
			local oldest = table.remove(toasts, 1) :: Frame
			bottom -= oldest.AbsoluteSize.Y + gap
			oldest:Destroy()
		end
	end
end

--- Keeps the toast stack below a banner. `key` names the banner; `bottom`
--- is its bottom edge in screen pixels (AbsolutePosition.Y + AbsoluteSize.Y),
--- or nil when the banner hides.
function NotificationController.ReserveTop(key: string, bottom: number?)
	if reservations[key] == bottom then
		return
	end
	reservations[key] = bottom
	placeStack()
	NotificationController.ReservationsChanged:Fire()
end

--- The lowest reserved bottom edge (screen pixels) of every reservation
--- except `except`, or nil if there are none.
function NotificationController.ReservedBottom(except: string?): number?
	local lowest: number? = nil
	for key, bottom in pairs(reservations) do
		if key ~= except and (not lowest or bottom > lowest) then
			lowest = bottom
		end
	end
	return lowest
end

function NotificationController.Start()
	local gui = UI.new("ScreenGui", {
		Name = "Notifications",
		ResetOnSpawn = false,
		DisplayOrder = Config.UI.Layers.Toast,
	}) :: ScreenGui

	local frame = UI.new("Frame", {
		Name = "Stack",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, LOOK.Top),
		Size = UDim2.new(0.9, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = gui,
	}, {
		UI.List({
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Padding = LOOK.Gap,
		}),
	}) :: Frame
	UI.Scale(frame)

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	container = frame
	stackBase = frame.Position
	placeStack()
	-- Re-place when a toast changes the stack's width, and when the camp
	-- panel moves or resizes (relayed to everything that follows
	-- ReservationsChanged, so banners and the tutorial card re-place too).
	local list = frame:FindFirstChildOfClass("UIListLayout")
	if list then
		list:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(placeStack)
	end
	HudLayout.Changed:Connect(function()
		placeStack()
		NotificationController.ReservationsChanged:Fire()
	end)

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local notify = remotes:WaitForChild("Notify") :: RemoteEvent
	notify.OnClientEvent:Connect(function(text, kind)
		if typeof(text) == "string" then
			NotificationController.Show(text, if typeof(kind) == "string" then kind else "Info")
		end
	end)

	-- Server-wide announcements (big hatches), tinted by rarity.
	local announce = remotes:WaitForChild("GlobalAnnounce") :: RemoteEvent
	announce.OnClientEvent:Connect(function(text, rarity)
		if typeof(text) ~= "string" then
			return
		end
		local known = typeof(rarity) == "string" and Config.Rarities[rarity] ~= nil
		NotificationController.Show(text, "Announce", if known then Theme.RarityColor(rarity) else nil)
	end)
end

return NotificationController
