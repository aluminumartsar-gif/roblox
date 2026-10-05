--!strict
--[[
	SightingController
	StarterPlayerScripts/Client/Controllers/SightingController

	The client side of Sightings (Hook 2). Display only — the server
	(SightingService) decides everything and tells us through the
	SightingBanner remote (phase, info).

	  banner    top-centre, just under the kit's Base/Eggs buttons: rarity
	            colour, what it is, where, and the countdown. Then who has the
	            capture ("stop them!"), whether it's loose, and how it ended.
	            While it shows, the toast stack is nudged down below it.
	  markers   a floating label (always on top, with distance) over the
	            sighting so people can find it, and over a capture on its way
	            home. The sighting marker sits on a local, invisible anchor at
	            the position the server sent, so it works even while the
	            model is streamed out (StreamingEnabled).
	  VHS       inside Config.Sightings.VhsRadius of the sighting the screen
	            turns to found footage: ColorCorrection (tint, less colour,
	            more contrast), scanlines, a little grain, a tracking band, a
	            red "REC" with a timecode, and a slight FOV wobble — all faded
	            by distance and removed cleanly when you leave or it ends.
	            Cheap: a dozen frames, one ColorCorrection, no images.
	  bob       the wild model bobs gently on this client only (the server
	            keeps it still: prompts are checked against its position).
	  prompt    when the server says our hold was broken ("Interrupted"),
	            the Capture prompt's ring is reset.
	  sounds    SightingHorn on start, SightingAmbience near it,
	            CaptureSuccess when you catch it (SoundController; skipped
	            quietly if it isn't there).
]]

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Components = script.Parent.Parent:WaitForChild("Components")
local ScreenScale = require(Components:WaitForChild("ScreenScale"))
local Icon = require(Components:WaitForChild("Icon"))

local SightingController = {}

local localPlayer = Players.LocalPlayer

-- Layout (not designer tunables). The kit's top buttons fill the top
-- 11.5% of the screen; the banner starts just below them.
local BANNER_TOP = 0.12
local BANNER_SIZE = Vector2.new(440, 60)
local TOAST_GAP = 6
local FLASH_SECONDS = 5
local PROMPT_RESET_DELAY = 0.15
local UI_REFRESH = 0.2
local GRAIN_REFRESH = 1 / 15
local SCANLINE_BLOCKS = 8
local VHS_FADE_SPEED = 3       -- how fast the effect fades in/out (per second)
local MARKER_HEIGHT = 9        -- studs above the ground for the sighting marker
local BAND_SECONDS = 4         -- the tracking band crosses the screen this often

type Info = { [string]: any }

local current: Info? = nil   -- the wild sighting ("Started")
-- Captures on their way home, by CarryId (Phase = "Carried" | "Dropped").
-- Usually one, but a carrier has no timer, so a new sighting can be
-- caught while an older capture is still out.
local captures: { [any]: Info } = {}
local flash: { Title: string, Text: string, Rarity: string?, Until: number }? = nil

local SoundController: any = nil

-- UI
local banner: Frame
local bannerStroke: UIStroke
local bannerTitle: TextLabel
local bannerText: TextLabel
local sightingMarker: BillboardGui
local sightingMarkerText: TextLabel
local captureMarker: BillboardGui
local captureMarkerText: TextLabel
local sightingAnchor: Part
local dropAnchor: Part

-- VHS
local vhsGui: ScreenGui
local scanBlocks: { Frame } = {}
local band: Frame
local grain: { Frame } = {}
local recLabel: TextLabel
local timeLabel: TextLabel
local vignette: { Frame } = {}
local colorCorrection: ColorCorrectionEffect
local vhsStrength = 0
local fovCamera: Camera? = nil
local fovOffset = 0
local lastAmbience = 0
local ambience: Sound? = nil -- the looped SightingAmbience while you're near

local toastStack: GuiObject? = nil
local toastBase: UDim2? = nil

local bobBases: { [Model]: CFrame } = setmetatable({}, { __mode = "k" }) :: any

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function formatClock(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function rarityColor(rarity: any): Color3
	local def = typeof(rarity) == "string" and Config.Rarities[rarity]
	if not def or def.NeverRenderClearly then
		return Color3.fromRGB(235, 235, 240)
	end
	return def.Color
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

local function textLabel(parent: Instance, name: string, font: Enum.Font): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = font
	label.TextScaled = true
	label.TextStrokeTransparency = 0.6
	label.Parent = parent
	return label
end

local function buildBanner(gui: ScreenGui)
	banner = Instance.new("Frame")
	banner.Name = "SightingBanner"
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, BANNER_TOP, 0)
	banner.Size = UDim2.fromOffset(BANNER_SIZE.X, BANNER_SIZE.Y)
	banner.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
	banner.BackgroundTransparency = 0.12
	banner.Visible = false
	banner.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = banner
	bannerStroke = Instance.new("UIStroke")
	bannerStroke.Thickness = 2.5
	bannerStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	bannerStroke.Parent = banner
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 12)
	padding.PaddingRight = UDim.new(0, 14)
	padding.PaddingTop = UDim.new(0, 6)
	padding.PaddingBottom = UDim.new(0, 6)
	padding.Parent = banner

	bannerTitle = textLabel(banner, "Title", Enum.Font.GothamBlack)
	bannerTitle.Size = UDim2.new(1, 0, 0.55, 0)
	bannerTitle.TextXAlignment = Enum.TextXAlignment.Left
	bannerText = textLabel(banner, "Detail", Enum.Font.GothamBold)
	bannerText.Position = UDim2.new(0, 0, 0.57, 0)
	bannerText.Size = UDim2.new(1, 0, 0.43, 0)
	bannerText.TextXAlignment = Enum.TextXAlignment.Left
	bannerText.TextColor3 = Color3.fromRGB(225, 228, 236)
	Icon.addLeft(banner, "Eye", 34, 2)
	ScreenScale.Apply(banner)
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

local function newMarker(name: string): (BillboardGui, TextLabel)
	local marker = Instance.new("BillboardGui")
	marker.Name = name
	marker.ResetOnSpawn = false
	marker.AlwaysOnTop = true
	marker.LightInfluence = 0
	marker.Size = UDim2.fromOffset(190, 46)
	marker.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
	marker.MaxDistance = math.huge
	marker.Enabled = false
	local label = textLabel(marker, "Text", Enum.Font.GothamBlack)
	label.Size = UDim2.fromScale(1, 1)
	label.TextStrokeTransparency = 0.2
	marker.Parent = localPlayer:WaitForChild("PlayerGui")
	return marker, label
end

--- Full-screen frame with a vertical UIGradient on its transparency.
local function gradientFrame(parent: Instance, name: string, keypoints: { NumberSequenceKeypoint }): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.Parent = parent
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Transparency = NumberSequence.new(keypoints)
	gradient.Parent = frame
	return frame
end

local function buildVhs(playerGui: Instance)
	vhsGui = Instance.new("ScreenGui")
	vhsGui.Name = "SightingVHS"
	vhsGui.ResetOnSpawn = false
	vhsGui.IgnoreGuiInset = true
	vhsGui.DisplayOrder = -1 -- under the HUD
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
	band.BackgroundColor3 = Color3.new(1, 1, 1)
	band.Size = UDim2.fromScale(1, 0.07)

	-- Grain specks.
	for i = 1, s.VhsGrainDots do
		local dot = Instance.new("Frame")
		dot.Name = "Grain"
		dot.BorderSizePixel = 0
		dot.BackgroundColor3 = if i % 2 == 0 then Color3.new(1, 1, 1) else Color3.new(0, 0, 0)
		dot.Size = UDim2.fromOffset(2, 2)
		dot.Parent = vhsGui
		table.insert(grain, dot)
	end

	-- "● REC" and a timecode, top right (inside the safe area).
	local corner = Instance.new("Frame")
	corner.Name = "Rec"
	corner.BackgroundTransparency = 1
	corner.AnchorPoint = Vector2.new(1, 0)
	corner.Position = UDim2.new(1, -20, 0, 52)
	corner.Size = UDim2.fromOffset(150, 52)
	corner.Parent = vhsGui
	recLabel = textLabel(corner, "Rec", Enum.Font.Code)
	recLabel.Size = UDim2.new(1, 0, 0.55, 0)
	recLabel.TextXAlignment = Enum.TextXAlignment.Right
	recLabel.TextColor3 = Color3.fromRGB(255, 50, 50)
	recLabel.Text = "● REC"
	timeLabel = textLabel(corner, "Time", Enum.Font.Code)
	timeLabel.Position = UDim2.fromScale(0, 0.58)
	timeLabel.Size = UDim2.new(1, 0, 0.42, 0)
	timeLabel.TextXAlignment = Enum.TextXAlignment.Right
	ScreenScale.Apply(corner)

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
	if not toastStack or not toastStack.Parent then
		local notifications = localPlayer.PlayerGui:FindFirstChild("Notifications")
		local stack = notifications and notifications:FindFirstChild("Stack")
		if not stack or not stack:IsA("GuiObject") then
			return
		end
		toastStack = stack
		toastBase = stack.Position
	end
	local stack = toastStack :: GuiObject
	local base = toastBase :: UDim2
	if bannerVisible then
		local gui = stack:FindFirstAncestorWhichIsA("LayerCollector")
		local guiTop = if gui and gui:IsA("ScreenGui") then gui.AbsolutePosition.Y else 0
		local wanted = banner.AbsolutePosition.Y + banner.AbsoluteSize.Y + TOAST_GAP - guiTop
		stack.Position = UDim2.new(base.X.Scale, base.X.Offset, base.Y.Scale, math.max(base.Y.Offset, wanted))
	else
		stack.Position = base
	end
end

local function showBanner(title: string, text: string, rarity: any)
	local color = rarityColor(rarity)
	bannerTitle.Text = title
	bannerTitle.TextColor3 = color
	bannerText.Text = text
	bannerStroke.Color = color
	banner.Visible = true
end

local function renderBanner()
	local now = serverNow()
	local mine = myCapture()
	local sighting = current
	local cap = otherCapture()

	if mine then
		showBanner(string.format("YOU CAUGHT THE %s!", string.upper(tostring(mine.Label))),
			"Get it to your camp's pad! Everyone can see you.", mine.Rarity)
	elseif sighting then
		local remaining = (tonumber(sighting.ExpiresAt) or now) - now
		showBanner(string.format("SIGHTING: %s", string.upper(tostring(sighting.Label))),
			string.format("%s  ·  %s left", tostring(sighting.Hint), formatClock(remaining)), sighting.Rarity)
	elseif cap and cap.Phase == "Dropped" then
		local remaining = (tonumber(cap.ExpiresAt) or now) - now
		showBanner(string.format("THE %s IS LOOSE!", string.upper(tostring(cap.Label))),
			string.format("Grab it before it runs off  ·  %s", formatClock(remaining)), cap.Rarity)
	elseif cap then
		showBanner(string.format("%s HAS THE %s", string.upper(tostring(cap.By)), string.upper(tostring(cap.Label))),
			"Stop them before they get home!", cap.Rarity)
	elseif flash and os.clock() < flash.Until then
		showBanner(flash.Title, flash.Text, flash.Rarity)
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
		sightingMarkerText.Text = string.format("%s\n%s", tostring(sighting.Label), text)
		sightingMarkerText.TextColor3 = rarityColor(sighting.Rarity)
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
		captureMarkerText.Text = string.format("%s (loose!)\n%s", tostring(cap.Label), text)
	else
		captureMarkerText.Text = string.format("%s has it!\n%s", tostring(cap.By), text)
	end
	captureMarkerText.TextColor3 = rarityColor(cap.Rarity)
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
	colorCorrection.TintColor = Color3.new(1, 1, 1):Lerp(s.VhsTint, k)
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

	local blinkOn = (t % 1) < 0.6
	recLabel.Text = if blinkOn then "● REC" else "   REC"
	recLabel.TextTransparency = 1 - k
	timeLabel.TextTransparency = 1 - k
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

local function setFlash(title: string, text: string, rarity: any)
	flash = {
		Title = title,
		Text = text,
		Rarity = if typeof(rarity) == "string" then rarity else nil,
		Until = os.clock() + FLASH_SECONDS,
	}
end

local function onBanner(phase: string, info: Info)
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
				if who == "You" then "your" else (tostring(info.By) .. "'s")), info.Rarity)
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
			setFlash("IT GOT AWAY", string.format("The %s slipped back into the woods.", tostring(info.Label)), info.Rarity)
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
	local gui = Instance.new("ScreenGui")
	gui.Name = "SightingUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 7
	buildBanner(gui)
	gui.Parent = playerGui

	sightingAnchor = newAnchor("SAC_SightingAnchor")
	dropAnchor = newAnchor("SAC_SightingDropAnchor")
	sightingMarker, sightingMarkerText = newMarker("SightingMarker")
	captureMarker, captureMarkerText = newMarker("CaptureMarker")
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
