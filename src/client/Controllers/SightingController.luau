--!strict
--[[
	SightingController
	StarterPlayerScripts/Client/Controllers/SightingController

	The client side of Sightings (Hook 2). Display only — the server
	(SightingService) decides everything and tells us through the
	SightingBanner remote (phase, info).

	  banner    top centre, just under Roblox's top bar (and the Base/Eggs
	            buttons), on Config.UI.Layers.Sighting; while the Hunt is on
	            it drops under the Hunt banner so neither hides the other.
	            A charred-wood strip edged and lit in the rarity colour: an
	            icon for what's happening, what it is, where (the server's
	            rough direction hint) and a countdown chip (turns red near
	            the end). Then who has the capture ("stop them!"), whether
	            it's loose, and how it ended (a short flash: brought home,
	            got away, she took it). While it shows, the toast stack is
	            nudged down below it (NotificationController.ReserveTop
	            "Sighting").
	  markers   a floating label (always on top: the name in the rarity
	            colour, the distance under it) over the sighting so people
	            can find it, and over a capture on its way home. The
	            sighting marker sits on a local, invisible anchor at the
	            position the server sent, so it works even while the model
	            is streamed out (StreamingEnabled).
	  VHS       inside Config.Sightings.VhsRadius of the sighting the screen
	            turns to found footage (Config.UI.Layers.Vhs, under the HUD):
	            ColorCorrection (tint, less colour, more contrast),
	            scanlines, a little grain, a tracking band, a blinking red
	            "REC" with a timecode in the Mono font, and a slight FOV
	            wobble — all faded by distance and removed cleanly when you
	            leave or it ends. Cheap: a dozen frames, one ColorCorrection,
	            no images.
	  bob       the wild model bobs gently on this client only (the server
	            keeps it still: prompts are checked against its position).
	  prompt    when the server says our hold was broken ("Interrupted"),
	            the Capture prompt's ring is reset.
	  sounds    SightingHorn on start, SightingAmbience near it,
	            CaptureSuccess when you catch it (SoundController; skipped
	            quietly if it isn't there).

	Sizes, icons and timings: Config.UI.Banners.
]]

local CollectionService = game:GetService("CollectionService")
local GuiService = game:GetService("GuiService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Components = script.Parent.Parent:WaitForChild("Components")
local Theme = require(Components:WaitForChild("Theme"))
local UI = require(Components:WaitForChild("UI"))
local HudLayout = require(Components:WaitForChild("HudLayout"))
local Icon = require(Components:WaitForChild("Icon"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))

local SightingController = {}

local localPlayer = Players.LocalPlayer
local C = Theme.Colors

-- Behaviour constants (not designer tunables).
local PROMPT_RESET_DELAY = 0.15
local UI_REFRESH = 0.2
local GRAIN_REFRESH = 1 / 15
local SCANLINE_BLOCKS = 8
local VHS_FADE_SPEED = 3       -- how fast the effect fades in/out (per second)
local MARKER_HEIGHT = 9        -- studs above the ground for the sighting marker
local MARKER_LIFT = 4          -- studs the floating label sits above its anchor
local BAND_SECONDS = 4         -- the tracking band crosses the screen this often
local REC_BLINK_ON = 0.6       -- of each second the REC dot shows
local REC_SHADOW = 0.4         -- REC text shadow opacity at full strength
local NEUTRAL_TINT = Color3.new(1, 1, 1) -- ColorCorrection tint that changes nothing

type Info = { [string]: any }

local current: Info? = nil   -- the wild sighting ("Started")
-- Captures on their way home, by CarryId (Phase = "Carried" | "Dropped").
-- Usually one, but a carrier has no timer, so a new sighting can be
-- caught while an older capture is still out.
local captures: { [any]: Info } = {}
local flash: { Title: string, Text: string, Rarity: string?, Icon: string, Until: number }? = nil

local SoundController: any = nil

-- UI
local banner: Frame
local bannerScale: UIScale
local bannerStroke: UIStroke
local bannerWash: UIGradient
local bannerIcon: ImageLabel
local bannerColumn: Frame
local bannerTitle: TextLabel
local bannerText: TextLabel
local timerChip: Frame
local timerLabel: TextLabel
local shownColor: Color3? = nil
local shownIcon: string? = nil
local sightingMarker: BillboardGui
local sightingMarkerName: TextLabel
local sightingMarkerDistance: TextLabel
local captureMarker: BillboardGui
local captureMarkerName: TextLabel
local captureMarkerDistance: TextLabel
local sightingAnchor: Part
local dropAnchor: Part

-- VHS
local vhsGui: ScreenGui
local scanBlocks: { Frame } = {}
local band: Frame
local grain: { Frame } = {}
local recCorner: Frame
local recScale: UIScale
local recLabel: TextLabel
local timeLabel: TextLabel
local vignette: { Frame } = {}
local colorCorrection: ColorCorrectionEffect
local vhsStrength = 0
local fovCamera: Camera? = nil
local fovOffset = 0
local lastAmbience = 0
local ambience: Sound? = nil -- the looped SightingAmbience while you're near

local bobBases: { [Model]: CFrame } = setmetatable({}, { __mode = "k" }) :: any

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function formatClock(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

--- Rarity colour readable on the dark UI (Secret's near-black is swapped
--- for SecretText); bone white when the server sent no rarity.
local function rarityColor(rarity: any): Color3
	if typeof(rarity) == "string" then
		return Theme.RarityColor(rarity)
	end
	return C.Text
end

local function play(name: string)
	if SoundController and typeof(SoundController.Play) == "function" then
		pcall(SoundController.Play, name)
	end
end

--- Returns the Sound SoundController made (a Looped one is ours to Destroy).
local function playAt(name: string, where: Instance | Vector3): Sound?
	if SoundController and typeof(SoundController.PlayAt) == "function" then
		local ok, sound = pcall(SoundController.PlayAt, name, where)
		if ok and typeof(sound) == "Instance" and sound:IsA("Sound") then
			return sound
		end
	end
	return nil
end

--- The capture the local player is carrying, if any.
local function myCapture(): Info?
	if localPlayer:GetAttribute("Carrying") ~= true then
		return nil
	end
	for _, info in pairs(captures) do
		if info.Phase == "Carried" and info.ByUserId == localPlayer.UserId then
			return info
		end
	end
	return nil
end

--- The capture worth pointing at for everyone else: a loose one first
--- (the one escaping soonest), else one someone else is carrying.
local function otherCapture(): Info?
	local best: Info? = nil
	for _, info in pairs(captures) do
		if info.Phase == "Dropped" then
			if not best or best.Phase ~= "Dropped"
				or (tonumber(info.ExpiresAt) or 0) < (tonumber(best.ExpiresAt) or 0) then
				best = info
			end
		elseif info.ByUserId ~= localPlayer.UserId and not best then
			best = info
		end
	end
	return best
end

local function myRoot(): BasePart?
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

--- Where "you" are for distances: your character, else the camera.
local function myPosition(): Vector3?
	local root = myRoot()
	if root then
		return root.Position
	end
	local camera = Workspace.CurrentCamera
	return camera and camera.CFrame.Position
end

--------------------------------------------------------------------------
-- Building the UI
--------------------------------------------------------------------------

local function newScreenGui(name: string, displayOrder: number): ScreenGui
	return UI.new("ScreenGui", {
		Name = name,
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = displayOrder,
	})
end

--- Shrinks a label's text to fit its box, never larger than maxSize.
local function fitText(label: TextLabel, maxSize: number)
	label.TextScaled = true
	UI.new("UITextSizeConstraint", { MaxTextSize = maxSize, Parent = label })
end

--- A dark outline so text reads over the 3D world.
local function shadowEdge(label: TextLabel)
	UI.Stroke({
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Color = C.Shadow,
		Thickness = 1.5,
		Transparency = 0.2,
		Parent = label,
	})
end

--- Where the top banners start, in px from the very top of the screen
--- (IgnoreGuiInset): under Roblox's top bar and the Base/Eggs travel
--- buttons, and below the camp panel when a banner widthPx wide would
--- cover it (narrow screens; Components/HudLayout).
local function bannerTop(scale: number, widthPx: number): number
	local gui = banner and banner:FindFirstAncestorWhichIsA("LayerCollector")
	if gui then
		return HudLayout.TopCentreTop(gui, scale, widthPx)
	end
	return HudLayout.TopCentreBase(scale)
end

local function buildBanner(gui: ScreenGui)
	local tuning = Config.UI.Banners
	local size = tuning.SightingSize
	banner = UI.Panel({
		Name = "SightingBanner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(size.X, size.Y),
		Visible = false,
		Parent = gui,
	})
	bannerWash = banner:FindFirstChildOfClass("UIGradient") :: UIGradient
	bannerStroke = banner:FindFirstChildOfClass("UIStroke") :: UIStroke
	UI.Padding({ Left = tuning.PaddingX, Right = tuning.PaddingX, Top = tuning.PaddingY, Bottom = tuning.PaddingY }).Parent = banner

	bannerIcon = UI.Icon(tuning.SightingIcons.Wild, tuning.IconSize, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Parent = banner,
	})
	shownIcon = tuning.SightingIcons.Wild

	local textLeft = tuning.IconSize + tuning.IconGap
	bannerColumn = UI.new("Frame", {
		Name = "Text",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(textLeft, 0),
		Size = UDim2.new(1, -textLeft, 1, 0),
		Parent = banner,
	}, {
		UI.List({ Padding = 0, VerticalAlignment = Enum.VerticalAlignment.Center }),
	})
	bannerTitle = UI.Text({
		Name = "Title",
		Role = "Heading",
		Weight = "Bold",
		RichText = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, tuning.SightingTitleSize + 6),
		LayoutOrder = 1,
		Parent = bannerColumn,
	})
	fitText(bannerTitle, tuning.SightingTitleSize)
	bannerText = UI.Text({
		Name = "Detail",
		Role = "Body",
		Weight = "Medium",
		RichText = false,
		TextColor3 = C.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, tuning.SightingTextSize + 4),
		LayoutOrder = 2,
		Parent = bannerColumn,
	})
	fitText(bannerText, tuning.SightingTextSize)

	-- Countdown chip on the right (only while something is counting down).
	timerChip = UI.Inset({
		Name = "Timer",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(tuning.TimerSize.X, tuning.TimerSize.Y),
		Visible = false,
		Parent = banner,
	})
	UI.List({
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = 4,
		Parent = timerChip,
	})
	UI.Icon(tuning.TimerIcon, tuning.TimerTextSize, {
		LayoutOrder = 1,
		ImageColor3 = C.TextDim,
		Parent = timerChip,
	})
	timerLabel = UI.Text({
		Name = "Time",
		Role = "Heading",
		Weight = "Bold",
		RichText = false,
		TextSize = tuning.TimerTextSize,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		LayoutOrder = 2,
		Parent = timerChip,
	})

	bannerScale = UI.Scale(banner)
end

local function newAnchor(name: string): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.Parent = Workspace
	return part
end

--- A floating label: the name on top, the distance under it.
local function newMarker(name: string): (BillboardGui, TextLabel, TextLabel)
	local tuning = Config.UI.Banners
	local marker = UI.new("BillboardGui", {
		Name = name,
		ResetOnSpawn = false,
		AlwaysOnTop = true,
		LightInfluence = 0,
		Size = UDim2.fromOffset(tuning.MarkerSize.X, tuning.MarkerSize.Y),
		StudsOffsetWorldSpace = Vector3.new(0, MARKER_LIFT, 0),
		MaxDistance = math.huge,
		Enabled = false,
	}) :: BillboardGui
	local title = UI.Text({
		Name = "Text",
		Role = "Heading",
		Weight = "Bold",
		RichText = false,
		Size = UDim2.fromScale(1, 0.58),
		Parent = marker,
	})
	fitText(title, tuning.MarkerNameSize)
	shadowEdge(title)
	local distance = UI.Text({
		Name = "Distance",
		Role = "Mono",
		Weight = "Bold",
		RichText = false,
		TextColor3 = C.Text,
		Position = UDim2.fromScale(0, 0.58),
		Size = UDim2.fromScale(1, 0.42),
		Parent = marker,
	})
	fitText(distance, tuning.MarkerDistanceSize)
	shadowEdge(distance)
	marker.Parent = localPlayer:WaitForChild("PlayerGui")
	return marker, title, distance
end

--- Full-screen frame with a vertical UIGradient on its transparency.
local function gradientFrame(parent: Instance, name: string, keypoints: { NumberSequenceKeypoint }): Frame
	return UI.new("Frame", {
		Name = name,
		BorderSizePixel = 0,
		BackgroundColor3 = C.Shadow,
		Parent = parent,
	}, {
		UI.new("UIGradient", {
			Rotation = 90,
			Transparency = NumberSequence.new(keypoints),
		}),
	})
end

--- One line of the REC corner (Mono font, right-aligned, faded with the effect).
local function recText(parent: Instance, name: string, color: Color3): TextLabel
	local label = UI.Text({
		Name = name,
		Role = "Mono",
		Weight = "Bold",
		RichText = false,
		TextColor3 = color,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextStrokeColor3 = C.Shadow,
		TextStrokeTransparency = 1,
		TextScaled = true,
		Parent = parent,
	})
	return label
end

local function buildVhs(playerGui: Instance)
	vhsGui = newScreenGui("SightingVHS", Config.UI.Layers.Vhs) -- under the HUD
	vhsGui.Enabled = false

	-- Scanlines: each block is 10 soft dark lines (a gradient can hold 20
	-- keypoints), stacked down the screen.
	local s = Config.Sightings
	local stripes: { NumberSequenceKeypoint } = {}
	for i = 0, 19 do
		table.insert(stripes, NumberSequenceKeypoint.new(i / 19, if i % 2 == 0 then s.VhsScanlineTransparency else 1))
	end
	for i = 1, SCANLINE_BLOCKS do
		local block = gradientFrame(vhsGui, "Scanlines", stripes)
		block.Position = UDim2.fromScale(0, (i - 1) / SCANLINE_BLOCKS)
		block.Size = UDim2.fromScale(1, 1 / SCANLINE_BLOCKS)
		table.insert(scanBlocks, block)
	end

	-- Dark top and bottom edges.
	local top = gradientFrame(vhsGui, "VignetteTop", {
		NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1),
	})
	top.Size = UDim2.fromScale(1, 0.18)
	local bottom = gradientFrame(vhsGui, "VignetteBottom", {
		NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.35),
	})
	bottom.AnchorPoint = Vector2.new(0, 1)
	bottom.Position = UDim2.fromScale(0, 1)
	bottom.Size = UDim2.fromScale(1, 0.18)
	vignette = { top, bottom }

	-- A pale tracking band that rolls down the screen.
	band = gradientFrame(vhsGui, "TrackingBand", {
		NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.85), NumberSequenceKeypoint.new(1, 1),
	})
	band.BackgroundColor3 = C.Text
	band.Size = UDim2.fromScale(1, 0.07)

	-- Grain specks: light and dark.
	for i = 1, s.VhsGrainDots do
		local dot = UI.new("Frame", {
			Name = "Grain",
			BorderSizePixel = 0,
			BackgroundColor3 = if i % 2 == 0 then C.Text else C.Shadow,
			Size = UDim2.fromOffset(2, 2),
			Parent = vhsGui,
		}) :: Frame
		table.insert(grain, dot)
	end

	-- "● REC" and a timecode, top right, under the top bar (placed by
	-- updateVhs, since the top bar's height is only known at runtime).
	local recSize = Config.UI.Banners.RecSize
	recCorner = UI.new("Frame", {
		Name = "Rec",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(recSize.X, recSize.Y),
		Parent = vhsGui,
	})
	recLabel = recText(recCorner, "Rec", C.BloodBright)
	recLabel.Size = UDim2.new(1, 0, 0.55, 0)
	recLabel.Text = "● REC"
	timeLabel = recText(recCorner, "Time", C.Text)
	timeLabel.Position = UDim2.fromScale(0, 0.58)
	timeLabel.Size = UDim2.new(1, 0, 0.42, 0)
	recScale = UI.Scale(recCorner)

	vhsGui.Parent = playerGui

	colorCorrection = Instance.new("ColorCorrectionEffect")
	colorCorrection.Name = "SAC_SightingVHS"
	colorCorrection.Enabled = false
	colorCorrection.Parent = Lighting
end

--------------------------------------------------------------------------
-- Banner
--------------------------------------------------------------------------

--- Keeps the toast stack (NotificationController) below the banner while
--- the banner shows, and puts it back after.
local function placeToasts(bannerVisible: boolean)
	NotificationController.ReserveTop("Sighting",
		if bannerVisible then banner.AbsolutePosition.Y + banner.AbsoluteSize.Y else nil)
end

--- True while the Hunt is on (HuntController's banner owns the top spot).
local function huntActive(): boolean
	local huntState = ReplicatedStorage:FindFirstChild("HuntState")
	local phase = huntState and huntState:GetAttribute("Phase")
	return phase ~= nil and phase ~= "Idle"
end

--- Top centre under the top bar; under the Hunt banner while she's out.
local function placeBanner()
	local tuning = Config.UI.Banners
	local scale = bannerScale.Scale
	local hunt = huntActive()
	-- Under the Hunt banner its width decides whether both drop below the
	-- camp panel, so measure the wider of the two.
	local width = if hunt then math.max(banner.AbsoluteSize.X, tuning.HuntSize.X * scale) else banner.AbsoluteSize.X
	local top = bannerTop(scale, width)
	if hunt then
		top += (tuning.HuntSize.Y + tuning.Gap) * scale
	end
	banner.Position = UDim2.new(0.5, 0, 0, top)
end

--- Shows the countdown chip with `seconds` left, or hides it (nil); the
--- text column takes the room when it's hidden.
local function setTimer(seconds: number?)
	local tuning = Config.UI.Banners
	local textLeft = tuning.IconSize + tuning.IconGap
	if seconds then
		timerLabel.Text = formatClock(seconds)
		timerLabel.TextColor3 = if seconds <= tuning.TimerUrgentBelow then C.BloodBright else C.Text
		timerChip.Visible = true
		bannerColumn.Size = UDim2.new(1, -(textLeft + tuning.TimerSize.X + tuning.IconGap), 1, 0)
	else
		timerChip.Visible = false
		bannerColumn.Size = UDim2.new(1, -textLeft, 1, 0)
	end
end

local function showBanner(title: string, text: string, rarity: any, iconName: string, seconds: number?)
	local color = rarityColor(rarity)
	bannerTitle.Text = title
	bannerTitle.TextColor3 = color
	bannerText.Text = text
	if color ~= shownColor then
		shownColor = color
		bannerStroke.Color = color
		bannerIcon.ImageColor3 = color
		-- A faint wash of the rarity colour at the top of the wood.
		bannerWash.Color = Theme.Sequence(Theme.Mix(C.PanelTop, color, Config.UI.Banners.RarityWash), C.Panel)
	end
	if iconName ~= shownIcon then
		shownIcon = iconName
		Icon.set(bannerIcon, iconName)
	end
	setTimer(seconds)
	banner.Visible = true
end

local function renderBanner()
	local now = serverNow()
	local icons = Config.UI.Banners.SightingIcons
	-- Sit just under the Hunt banner while she's out, so neither hides the other.
	placeBanner()
	local mine = myCapture()
	local sighting = current
	local cap = otherCapture()

	if mine then
		showBanner(string.format("YOU CAUGHT THE %s!", string.upper(tostring(mine.Label))),
			"Get it to your camp's pad! Everyone can see you.", mine.Rarity, icons.Mine, nil)
	elseif sighting then
		local remaining = (tonumber(sighting.ExpiresAt) or now) - now
		showBanner(string.format("SIGHTING: %s", string.upper(tostring(sighting.Label))),
			tostring(sighting.Hint), sighting.Rarity, icons.Wild, remaining)
	elseif cap and cap.Phase == "Dropped" then
		local remaining = (tonumber(cap.ExpiresAt) or now) - now
		showBanner(string.format("THE %s IS LOOSE!", string.upper(tostring(cap.Label))),
			"Grab it before it runs off", cap.Rarity, icons.Loose, remaining)
	elseif cap then
		showBanner(string.format("%s HAS THE %s", string.upper(tostring(cap.By)), string.upper(tostring(cap.Label))),
			"Stop them before they get home!", cap.Rarity, icons.Carried, nil)
	elseif flash and os.clock() < flash.Until then
		showBanner(flash.Title, flash.Text, flash.Rarity, flash.Icon, nil)
	else
		flash = nil
		banner.Visible = false
	end
	placeToasts(banner.Visible)
end

--------------------------------------------------------------------------
-- Markers
--------------------------------------------------------------------------

local function distanceText(position: Vector3): (string, number)
	local me = myPosition()
	local distance = if me then (me - position).Magnitude else 0
	return string.format("%d studs", math.floor(distance + 0.5)), distance
end

--- The model StealService built for this capture, if streamed in here.
local function captureModel(carryId: any): Model?
	for _, model in ipairs(CollectionService:GetTagged(Config.Tags.CarriedItem)) do
		if model:IsA("Model") and model:GetAttribute("CarryId") == carryId and model.PrimaryPart then
			return model
		end
	end
	return nil
end

local function renderMarkers()
	local hideWithin = Config.Sightings.MarkerHideWithin

	local sighting = current
	if sighting and typeof(sighting.Position) == "Vector3" then
		local position = sighting.Position :: Vector3
		sightingAnchor.CFrame = CFrame.new(position + Vector3.new(0, MARKER_HEIGHT, 0))
		local text, distance = distanceText(position)
		sightingMarkerName.Text = tostring(sighting.Label)
		sightingMarkerName.TextColor3 = rarityColor(sighting.Rarity)
		sightingMarkerDistance.Text = text
		sightingMarker.Adornee = sightingAnchor
		sightingMarker.Enabled = distance > hideWithin
	else
		sightingMarker.Enabled = false
	end

	local cap = otherCapture()
	if not cap then
		captureMarker.Enabled = false
		return
	end
	local model = captureModel(cap.CarryId)
	local adornee: BasePart? = if model then model.PrimaryPart else nil
	if not adornee and cap.Phase == "Dropped" and typeof(cap.Position) == "Vector3" then
		dropAnchor.CFrame = CFrame.new(cap.Position :: Vector3)
		adornee = dropAnchor
	end
	if not adornee then
		captureMarker.Enabled = false -- carrier streamed out: the banner still says who
		return
	end
	local text, distance = distanceText(adornee.Position)
	if cap.Phase == "Dropped" then
		captureMarkerName.Text = string.format("%s (loose!)", tostring(cap.Label))
	else
		captureMarkerName.Text = string.format("%s has it!", tostring(cap.By))
	end
	captureMarkerName.TextColor3 = rarityColor(cap.Rarity)
	captureMarkerDistance.Text = text
	captureMarker.Adornee = adornee
	captureMarker.Enabled = distance > hideWithin
end

--------------------------------------------------------------------------
-- VHS effect + idle bob (every frame, cheap when far away)
--------------------------------------------------------------------------

local function setFovOffset(offset: number)
	local camera = Workspace.CurrentCamera
	if fovCamera ~= camera then
		fovCamera = camera
		fovOffset = 0 -- a new camera never had our offset
	end
	if not camera then
		return
	end
	-- Apply only the change, so anything else adjusting FOV keeps working.
	camera.FieldOfView += offset - fovOffset
	fovOffset = offset
end

--- The REC corner sits top right, under Roblox's top bar.
local function placeRec()
	local layout = Config.UI.Layout
	local scale = recScale.Scale
	local inset = GuiService:GetGuiInset()
	recCorner.Position = UDim2.new(1, -layout.EdgeMargin * scale, 0, inset.Y + layout.TopGap * scale)
end

local grainClock = 0
local function updateVhs(dt: number, distance: number?)
	local s = Config.Sightings
	local target = 0
	if distance then
		if distance <= s.VhsFullRadius then
			target = 1
		elseif distance < s.VhsRadius then
			target = 1 - (distance - s.VhsFullRadius) / math.max(1, s.VhsRadius - s.VhsFullRadius)
		end
	end
	vhsStrength += (target - vhsStrength) * math.min(1, dt * VHS_FADE_SPEED)
	if target == 0 and vhsStrength < 0.01 then
		vhsStrength = 0
	end
	local k = vhsStrength

	if k <= 0 then
		if vhsGui.Enabled then
			vhsGui.Enabled = false
			colorCorrection.Enabled = false
			setFovOffset(0)
		end
		return
	end

	vhsGui.Enabled = true
	colorCorrection.Enabled = true
	colorCorrection.TintColor = NEUTRAL_TINT:Lerp(s.VhsTint, k)
	colorCorrection.Saturation = s.VhsSaturation * k
	colorCorrection.Contrast = s.VhsContrast * k
	colorCorrection.Brightness = s.VhsBrightness * k

	local t = os.clock()
	setFovOffset(math.sin(t * s.VhsFovWobbleSpeed * math.pi * 2) * s.VhsFovWobble * k)

	for _, block in ipairs(scanBlocks) do
		block.BackgroundTransparency = 1 - k
	end
	for _, frame in ipairs(vignette) do
		frame.BackgroundTransparency = 1 - k
	end
	band.BackgroundTransparency = 1 - k
	band.Position = UDim2.fromScale(0, ((t / BAND_SECONDS) % 1) * 1.1 - 0.07)

	grainClock += dt
	if grainClock >= GRAIN_REFRESH then
		grainClock = 0
		for _, dot in ipairs(grain) do
			dot.Position = UDim2.fromScale(math.random(), math.random())
			dot.BackgroundTransparency = 1 - k * math.random() * 0.6
		end
	end

	placeRec()
	local blinkOn = (t % 1) < REC_BLINK_ON
	recLabel.Text = if blinkOn then "● REC" else "   REC"
	recLabel.TextTransparency = 1 - k
	timeLabel.TextTransparency = 1 - k
	recLabel.TextStrokeTransparency = 1 - k * REC_SHADOW
	timeLabel.TextStrokeTransparency = 1 - k * REC_SHADOW
	local sighting = current
	local elapsed = if sighting then serverNow() - (tonumber(sighting.StartedAt) or serverNow()) else 0
	elapsed = math.max(0, math.floor(elapsed))
	timeLabel.Text = string.format("SP %02d:%02d:%02d", elapsed // 3600, (elapsed // 60) % 60, elapsed % 60)
end

local function updateBob(distance: number?)
	local s = Config.Sightings
	if not distance or distance > s.VhsRadius then
		return
	end
	local offset = math.sin(os.clock() * s.IdleBobSpeed * math.pi * 2) * s.IdleBobHeight
	for _, model in ipairs(CollectionService:GetTagged(Config.Tags.WildCryptid)) do
		if model:IsA("Model") and model.PrimaryPart then
			local base = bobBases[model]
			if not base then
				base = model:GetPivot()
				bobBases[model] = base
			end
			model:PivotTo((base :: CFrame) * CFrame.new(0, offset, 0))
		end
	end
end

local function onFrame(dt: number)
	local sighting = current
	local distance: number? = nil
	if sighting and typeof(sighting.Position) == "Vector3" then
		local me = myPosition()
		if me then
			distance = (me - (sighting.Position :: Vector3)).Magnitude
		end
	end
	updateVhs(dt, distance)
	updateBob(distance)

	-- Ambience while you're close. A looped SightingAmbience (Config.Sounds)
	-- is started once and stopped when you leave or the sighting ends; a
	-- one-shot is replayed every AmbienceInterval.
	local near = distance ~= nil and distance <= Config.Sightings.VhsRadius
	local loop = ambience
	if near then
		if not (loop and loop.Parent) and os.clock() - lastAmbience >= Config.Sightings.AmbienceInterval then
			lastAmbience = os.clock()
			local sound = playAt("SightingAmbience", sightingAnchor)
			if sound and sound.Looped then
				ambience = sound
			end
		end
	elseif loop then
		ambience = nil
		loop:Destroy()
	end
end

--------------------------------------------------------------------------
-- Server messages
--------------------------------------------------------------------------

--- Our hold was broken (or refused): reset the Capture prompt's ring.
local function resetPrompts()
	for _, model in ipairs(CollectionService:GetTagged(Config.Tags.WildCryptid)) do
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("ProximityPrompt") and d.Name == "CapturePrompt" and d.Enabled then
				local prompt = d
				pcall(function()
					prompt:InputHoldEnd()
				end)
				-- Toggling it off and on is what reliably clears the ring.
				prompt.Enabled = false
				task.delay(PROMPT_RESET_DELAY, function()
					if prompt.Parent then
						prompt.Enabled = true
					end
				end)
			end
		end
	end
end

local function setFlash(title: string, text: string, rarity: any, iconName: string)
	flash = {
		Title = title,
		Text = text,
		Rarity = if typeof(rarity) == "string" then rarity else nil,
		Icon = iconName,
		Until = os.clock() + Config.UI.Banners.FlashSeconds,
	}
end

local function onBanner(phase: string, info: Info)
	local icons = Config.UI.Banners.SightingIcons
	if phase == "Started" then
		current = info
		lastAmbience = 0
		play("SightingHorn")
	elseif phase == "Captured" then
		if current and current.SightingId == info.SightingId then
			current = nil
		end
		info.Phase = "Carried"
		if info.CarryId ~= nil then
			captures[info.CarryId] = info
		end
		if info.ByUserId == localPlayer.UserId then
			play("CaptureSuccess")
		else
			play("Notify")
		end
	elseif phase == "PickedUp" then
		info.Phase = "Carried"
		if info.CarryId ~= nil then
			captures[info.CarryId] = info
		end
	elseif phase == "Dropped" then
		info.Phase = "Dropped"
		if info.CarryId ~= nil then
			captures[info.CarryId] = info
		end
	elseif phase == "Claimed" then
		if info.CarryId ~= nil then
			captures[info.CarryId] = nil
		end
		local who = if info.ByUserId == localPlayer.UserId then "You" else tostring(info.By)
		setFlash(string.format("%s BROUGHT IT HOME", string.upper(who)),
			string.format("The %s now lives at %s camp.", tostring(info.Label),
				if who == "You" then "your" else (tostring(info.By) .. "'s")), info.Rarity, icons.Claimed)
	elseif phase == "Escaped" then
		local matched = false
		if info.SightingId ~= nil and current and current.SightingId == info.SightingId then
			current = nil
			matched = true
		end
		if info.CarryId ~= nil and captures[info.CarryId] then
			captures[info.CarryId] = nil
			matched = true
		end
		if matched then
			if info.TakenBack == true then
				setFlash("SHE TOOK IT", string.format("%s took the %s.", Config.Hunt.Name, tostring(info.Label)), info.Rarity, icons.TakenBack)
			else
				setFlash("IT GOT AWAY", string.format("The %s slipped back into the woods.", tostring(info.Label)), info.Rarity, icons.Escaped)
			end
		end
	elseif phase == "Interrupted" then
		resetPrompts()
		if not info.Quiet then
			play("Error")
		end
	end
	renderBanner()
	renderMarkers()
end

--------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------

function SightingController.Start()
	local soundModule = script.Parent:FindFirstChild("SoundController")
	if soundModule and soundModule:IsA("ModuleScript") then
		local ok, result = pcall(require, soundModule)
		if ok and typeof(result) == "table" then
			SoundController = result
		end
	end

	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local gui = newScreenGui("SightingUI", Config.UI.Layers.Sighting)
	buildBanner(gui)
	gui.Parent = playerGui

	sightingAnchor = newAnchor("SAC_SightingAnchor")
	dropAnchor = newAnchor("SAC_SightingDropAnchor")
	sightingMarker, sightingMarkerName, sightingMarkerDistance = newMarker("SightingMarker")
	captureMarker, captureMarkerName, captureMarkerDistance = newMarker("CaptureMarker")
	buildVhs(playerGui)

	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("SightingBanner") :: RemoteEvent
	remote.OnClientEvent:Connect(function(phase, info)
		if typeof(phase) == "string" and typeof(info) == "table" then
			onBanner(phase, info)
		end
	end)

	-- A wild model that streams out and back in comes back at its true
	-- spot; forget the old base so the bob starts from there.
	CollectionService:GetInstanceRemovedSignal(Config.Tags.WildCryptid):Connect(function(model)
		if model:IsA("Model") then
			bobBases[model] = nil
		end
	end)

	local warned = false
	RunService.RenderStepped:Connect(function(dt)
		local ok, err = pcall(onFrame, dt)
		if not ok and not warned then
			warned = true -- once, not 60 times a second
			warn("[SAC/Sighting] frame update errored: " .. tostring(err))
		end
	end)

	task.spawn(function()
		while true do
			task.wait(UI_REFRESH)
			-- A sighting whose time ran out with no word from the server
			-- (e.g. a missed message) shouldn't hang around on screen.
			local sighting = current
			if sighting and serverNow() > (tonumber(sighting.ExpiresAt) or 0) + 5 then
				current = nil
			end
			for carryId, info in pairs(captures) do
				if info.Phase == "Dropped" and serverNow() > (tonumber(info.ExpiresAt) or 0) + 5 then
					captures[carryId] = nil
				end
			end
			renderBanner()
			renderMarkers()
		end
	end)
end

return SightingController
