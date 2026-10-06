--!strict
--[[
	HuntController
	StarterPlayerScripts/Client/Controllers/HuntController

	The client half of the Hunt (server: HuntService). Draws the Brood
	Mother and makes her frightening:

	  * Her model is built here, locally (the generated mesh template
	    Config.Art.Props.BroodMother, or a part-built fallback), and glides
	    to the position the server publishes on ReplicatedStorage.HuntState,
	    smoothed every frame. She rises out of her nest when the hunt starts
	    and sinks back into the ground when it ends.
	  * Warning: lights dim, fog thickens, a wail, and a banner counting
	    down to when she emerges.
	  * Dread, by distance: a heartbeat that speeds up as she gets closer,
	    blood-red screen edges and film grain (ScreenGui "HuntDread" on
	    Config.UI.Layers.HuntDread), and camera shake when she's very close.
	  * Caught: a jumpscare for the victim (her face fills the screen with a
	    scream, on its own ScreenGui at Config.UI.Layers.Jumpscare, above
	    every other UI); everyone nearby hears it.
	  * The banner (ScreenGui "HuntBanner" on Config.UI.Layers.Sighting): top
	    centre, just under Roblox's top bar (and the Base/Eggs buttons) —
	    charred wood washed blood red, a skull, her headline in the Display
	    font ("SHE'S COMING FOR YOU" pulses its edge), and a line with the
	    time left and advice that depends on you: carrying an egg ("she can
	    smell it — get it home"), or not. While it shows, the toast stack
	    stays below it (NotificationController.ReserveTop "Hunt") and the
	    sighting banner drops under it (SightingController). Sizes and look:
	    Config.UI.Banners.

	All of this is presentation. The server decides where she is and who
	she catches.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemVisuals = require(Shared:WaitForChild("ItemVisuals"))

local Components = script.Parent.Parent:WaitForChild("Components")
local Theme = require(Components:WaitForChild("Theme"))
local UI = require(Components:WaitForChild("UI"))
local HudLayout = require(Components:WaitForChild("HudLayout"))
local SoundController = require(script.Parent:WaitForChild("SoundController"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))

local HuntController = {}

local localPlayer = Players.LocalPlayer
local C = Theme.Colors

local RISE_TIME = 2.2
local SINK_SPEED = 3.5 -- studs per second while leaving
local SPECK_SIZE = 2 -- px, one fleck of film grain

local state: Configuration? = nil
local model: Model? = nil
local modelHeight = Config.Hunt.ModelHeight
local eye: PointLight? = nil

local shownPos: Vector3? = nil
local shownYaw = 0
local riseStart = 0
local sinkOffset = 0

local banner: Frame
local bannerScale: UIScale
local bannerEdge: UIStroke
local bannerTitle: TextLabel
local bannerSub: TextLabel
local vignette: { Frame } = {}
local grain: Frame
local heartbeat: Sound? = nil

local savedLighting: { Brightness: number, Density: number? }? = nil

--------------------------------------------------------------------------
-- Her model
--------------------------------------------------------------------------

local function block(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	if shape then
		p.Shape = shape
	end
	p.Parent = parent
	return p
end

--- A tall, gaunt figure: a pale cracked-egg skull with one glowing eye,
--- a ragged dark body, and long spindly limbs. Faces -Z; pivot at its feet.
local function buildFallback(): Model
	local h = Config.Hunt.ModelHeight
	local m = Instance.new("Model")
	m.Name = "BroodMother"
	local colors = Config.Hunt.FallbackColors
	local dark = colors.Body
	local bark = colors.Rags
	local bone = colors.Bone

	local body = block(m, "Body", Vector3.new(h * 0.22, h * 0.42, h * 0.16), CFrame.new(0, h * 0.58, 0) * CFrame.Angles(math.rad(-14), 0, 0), dark, Enum.Material.Slate)
	-- Ragged cloak: a few hanging strips.
	for i = -2, 2 do
		block(m, "Rag", Vector3.new(h * 0.06, h * 0.32, 0.25), CFrame.new(i * h * 0.05, h * 0.36, h * 0.06) * CFrame.Angles(math.rad(8), 0, math.rad(i * 4)), bark, Enum.Material.Fabric)
	end
	-- Long legs.
	for _, side in ipairs({ -1, 1 }) do
		block(m, "Leg", Vector3.new(h * 0.045, h * 0.42, h * 0.045), CFrame.new(side * h * 0.07, h * 0.2, 0) * CFrame.Angles(0, 0, math.rad(side * 6)), dark, Enum.Material.Slate)
		-- Arms: reaching forward and down, absurdly long.
		local shoulder = CFrame.new(side * h * 0.13, h * 0.76, -h * 0.04)
		block(m, "Arm", Vector3.new(h * 0.035, h * 0.36, h * 0.035), shoulder * CFrame.Angles(math.rad(-38), 0, math.rad(side * 14)) * CFrame.new(0, -h * 0.17, 0), dark, Enum.Material.Slate)
		local elbow = shoulder * CFrame.Angles(math.rad(-38), 0, math.rad(side * 14)) * CFrame.new(0, -h * 0.34, 0)
		block(m, "Forearm", Vector3.new(h * 0.03, h * 0.34, h * 0.03), elbow * CFrame.Angles(math.rad(-50), 0, 0) * CFrame.new(0, -h * 0.16, 0), dark, Enum.Material.Slate)
		local wrist = elbow * CFrame.Angles(math.rad(-50), 0, 0) * CFrame.new(0, -h * 0.32, 0)
		for f = -1, 1 do
			block(m, "Finger", Vector3.new(h * 0.012, h * 0.1, h * 0.012), wrist * CFrame.Angles(math.rad(-20), 0, math.rad(f * 18)) * CFrame.new(0, -h * 0.05, 0), bone)
		end
	end
	-- Skull: a pale cracked egg with one huge eye.
	local skullCf = CFrame.new(0, h * 0.88, -h * 0.06)
	local skull = block(m, "Skull", Vector3.new(h * 0.15, h * 0.2, h * 0.15), skullCf, bone, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	block(m, "Crack", Vector3.new(h * 0.005, h * 0.12, h * 0.16), skullCf * CFrame.Angles(0, 0, math.rad(25)), dark)
	local eyePart = block(m, "Eye", Vector3.new(h * 0.07, h * 0.07, h * 0.03), skullCf * CFrame.new(0, 0, -h * 0.07), Config.Hunt.Color, Enum.Material.Neon, Enum.PartType.Ball)
	local _ = skull
	m.PrimaryPart = body
	body.PivotOffset = body.CFrame:Inverse()
	local light = Instance.new("PointLight")
	light.Name = "EyeLight"
	light.Color = Config.Hunt.Color
	light.Range = 26
	light.Brightness = 3
	light.Parent = eyePart
	return m
end

--- Builds a fresh copy of her and returns it with its eye light. Touches no
--- module state: the jumpscare face is built with this too.
local function buildModel(): (Model, PointLight?)
	local template = ItemVisuals.GetTemplate("Props", "BroodMother")
	local m: Model
	if template then
		m = template:Clone()
		m.Name = "BroodMother"
		for _, d in ipairs(m:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
			end
		end
		-- A glowing eye light so she reads in the dark even as a mesh.
		local glow = Instance.new("PointLight")
		glow.Name = "EyeLight"
		glow.Color = Config.Hunt.Color
		glow.Range = 26
		glow.Brightness = 3
		local primary = m.PrimaryPart :: BasePart
		local holder = Instance.new("Attachment")
		holder.Name = "EyeAttachment"
		holder.Position = primary.CFrame:PointToObjectSpace(m:GetPivot().Position + Vector3.new(0, m:GetExtentsSize().Y * 0.88, -m:GetExtentsSize().Z * 0.3))
		holder.Parent = primary
		glow.Parent = holder
	else
		m = buildFallback()
	end

	-- A cold mist around her feet.
	local primary = m.PrimaryPart :: BasePart
	local feet = Instance.new("Attachment")
	feet.Name = "Mist"
	feet.Position = primary.CFrame:PointToObjectSpace(m:GetPivot().Position)
	feet.Parent = primary
	local mist = Instance.new("ParticleEmitter")
	mist.Color = ColorSequence.new(Config.Hunt.MistColor)
	mist.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.3, 0.55), NumberSequenceKeypoint.new(1, 1) })
	mist.Size = NumberSequence.new(4, 9)
	mist.Lifetime = NumberRange.new(2, 3.5)
	mist.Rate = 12
	mist.Speed = NumberRange.new(0.5, 1.5)
	mist.SpreadAngle = Vector2.new(180, 20)
	mist.LightInfluence = 0.3
	mist.Parent = feet

	local light: PointLight? = nil
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("PointLight") then
			light = d
		end
	end
	return m, light
end

local function showModel()
	if not model then
		local m, light = buildModel()
		model = m
		eye = light
		modelHeight = m:GetExtentsSize().Y
	end
	local m = model :: Model
	if m.Parent ~= Workspace then
		m.Parent = Workspace
	end
end

local function hideModel()
	if model then
		model.Parent = nil
	end
	shownPos = nil
	sinkOffset = 0
end

--------------------------------------------------------------------------
-- Screen: dread overlay and banner
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

--- Blood-red screen edges and film grain, faded in by setDread.
local function buildDread(playerGui: Instance)
	local tuning = Config.UI.Banners
	local gui = newScreenGui("HuntDread", Config.UI.Layers.HuntDread)

	-- Vignette: four edge frames fading inward.
	local depth = tuning.DreadEdgeDepth
	local edges = {
		{ AnchorPoint = Vector2.new(0, 0), Position = UDim2.fromScale(0, 0), Size = UDim2.fromScale(1, depth.Y), Rotation = 90 },
		{ AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.fromScale(1, depth.Y), Rotation = -90 },
		{ AnchorPoint = Vector2.new(0, 0), Position = UDim2.fromScale(0, 0), Size = UDim2.fromScale(depth.X, 1), Rotation = 0 },
		{ AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromScale(depth.X, 1), Rotation = 180 },
	}
	for _, e in ipairs(edges) do
		local edge = UI.new("Frame", {
			Name = "Vignette",
			AnchorPoint = e.AnchorPoint,
			Position = e.Position,
			Size = e.Size,
			BackgroundColor3 = C.BloodDeep,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = gui,
		}, {
			UI.new("UIGradient", {
				Rotation = e.Rotation,
				Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) }),
			}),
		})
		table.insert(vignette, edge)
	end

	-- Film grain: a handful of flickering specks, re-scattered every frame.
	grain = UI.new("Frame", {
		Name = "Grain",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = gui,
	})
	for _ = 1, tuning.DreadGrainSpecks do
		UI.new("Frame", {
			Name = "Speck",
			BorderSizePixel = 0,
			BackgroundColor3 = C.Text,
			Size = UDim2.fromOffset(SPECK_SIZE, SPECK_SIZE),
			Parent = grain,
		})
	end

	gui.Parent = playerGui
end

--- The banner: top centre under the top bar, same spot as the sighting
--- banner (which moves under this one while it shows).
local function buildBanner(playerGui: Instance)
	local tuning = Config.UI.Banners
	local gui = newScreenGui("HuntBanner", Config.UI.Layers.Sighting)
	local size = tuning.HuntSize

	banner = UI.Panel({
		Name = "Banner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(size.X, size.Y),
		Visible = false,
		Parent = gui,
	})
	-- Charred wood washed blood red from the top, with a blood edge.
	local wash = banner:FindFirstChildOfClass("UIGradient")
	if wash then
		wash.Color = Theme.Sequence(C.BloodDeep, C.Panel)
	end
	bannerEdge = banner:FindFirstChildOfClass("UIStroke") :: UIStroke
	bannerEdge.Color = C.Blood
	UI.Padding({ Left = tuning.PaddingX, Right = tuning.PaddingX, Top = tuning.PaddingY, Bottom = tuning.PaddingY }).Parent = banner

	UI.Icon(tuning.HuntIcon, tuning.IconSize, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		ImageColor3 = C.Blood,
		Parent = banner,
	})

	local textLeft = tuning.IconSize + tuning.IconGap
	local column = UI.new("Frame", {
		Name = "Text",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(textLeft, 0),
		Size = UDim2.new(1, -textLeft, 1, 0),
		Parent = banner,
	}, {
		UI.List({ Padding = 0, VerticalAlignment = Enum.VerticalAlignment.Center }),
	})

	-- Headline: the Display font at a fixed size (it's only legible large),
	-- with a dark edge so the red reads on the red wash.
	bannerTitle = UI.Title("", tuning.HuntTitleSize, {
		Name = "Title",
		RichText = false,
		TextColor3 = C.BloodBright,
		TextTruncate = Enum.TextTruncate.AtEnd,
		LayoutOrder = 1,
		Parent = column,
	})
	local titleEdge = bannerTitle:FindFirstChildOfClass("UIStroke")
	if titleEdge then
		titleEdge.Color = C.Shadow
	end

	bannerSub = UI.Text({
		Name = "Detail",
		Role = "Heading",
		Weight = "SemiBold",
		RichText = false,
		TextColor3 = C.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, tuning.HuntTextSize + 4),
		LayoutOrder = 2,
		Parent = column,
	})
	fitText(bannerSub, tuning.HuntTextSize)

	bannerScale = UI.Scale(banner)
	gui.Parent = playerGui
end

local function buildGui()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	buildDread(playerGui)
	buildBanner(playerGui)
end

local function setDread(amount: number)
	-- amount 0..1
	local strength = Config.UI.Banners.DreadStrength
	for _, f in ipairs(vignette) do
		f.BackgroundTransparency = 1 - amount * strength
	end
	grain.Visible = amount > 0.15
	if grain.Visible then
		for _, speck in ipairs(grain:GetChildren()) do
			if speck:IsA("Frame") then
				speck.Position = UDim2.fromScale(math.random(), math.random())
				speck.BackgroundTransparency = 1 - math.random() * amount * 0.6
			end
		end
	end
	local hb = heartbeat
	if hb then
		hb.Volume = amount * 0.9
		hb.PlaybackSpeed = 0.85 + amount * 0.75
	end
end

local function dimLights(on: boolean)
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if on then
		if savedLighting then
			return
		end
		savedLighting = {
			Brightness = Lighting.Brightness,
			Density = if atmosphere then atmosphere.Density else nil,
		}
		local info = TweenInfo.new(2.5, Enum.EasingStyle.Sine)
		TweenService:Create(Lighting, info, { Brightness = Lighting.Brightness * Config.Hunt.DimLights }):Play()
		if atmosphere then
			TweenService:Create(atmosphere, info, { Density = math.min(1, atmosphere.Density + Config.Hunt.FogDensityBonus) }):Play()
		end
	else
		local saved = savedLighting
		if not saved then
			return
		end
		savedLighting = nil
		local info = TweenInfo.new(3, Enum.EasingStyle.Sine)
		TweenService:Create(Lighting, info, { Brightness = saved.Brightness }):Play()
		if atmosphere and saved.Density then
			TweenService:Create(atmosphere, info, { Density = saved.Density }):Play()
		end
	end
end

--------------------------------------------------------------------------
-- Jumpscare
--------------------------------------------------------------------------

local function jumpscare()
	SoundController.Play("Jumpscare")
	-- Its own ScreenGui above every other UI (toasts, banners, popups), so
	-- her face really fills the screen. Gone when the scare fades.
	local scareGui = newScreenGui("HuntJumpscare", Config.UI.Layers.Jumpscare)
	scareGui.Parent = localPlayer:WaitForChild("PlayerGui")
	local overlay = UI.new("Frame", {
		Name = "Overlay",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.Shadow,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		ZIndex = 50,
		Parent = scareGui,
	}) :: Frame

	-- Her face, filling the screen.
	local viewport = UI.new("ViewportFrame", {
		Name = "Face",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.6, 0.6),
		BackgroundTransparency = 1,
		Ambient = Config.UI.Banners.JumpscareAmbient,
		LightColor = Config.Hunt.Color,
		LightDirection = Vector3.new(0, -0.3, 1),
		ZIndex = 51,
		Parent = overlay,
	}) :: ViewportFrame
	local face = buildModel()
	face:PivotTo(CFrame.new())
	face.Parent = viewport
	local camera = Instance.new("Camera")
	local height = face:GetExtentsSize().Y
	local headPos = Vector3.new(0, height * 0.8, 0)
	camera.CFrame = CFrame.lookAt(headPos + Vector3.new(0, -height * 0.04, -height * 0.62), headPos)
	camera.FieldOfView = 50
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local flash = UI.new("Frame", {
		Name = "Flash",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Config.Hunt.Color,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		ZIndex = 52,
		Parent = overlay,
	}) :: Frame

	TweenService:Create(viewport, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = UDim2.fromScale(1.6, 1.6) }):Play()
	TweenService:Create(flash, TweenInfo.new(0.5), { BackgroundTransparency = 1 }):Play()

	-- Shake the whole thing.
	local start = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local t = os.clock() - start
		local strength = math.max(0, 1 - t / 0.9) * 0.03
		viewport.Position = UDim2.fromScale(0.5 + (math.random() - 0.5) * strength, 0.5 + (math.random() - 0.5) * strength)
		if t > 0.9 then
			conn:Disconnect()
		end
	end)

	task.delay(0.9, function()
		local fade = TweenService:Create(overlay, TweenInfo.new(0.5), { BackgroundTransparency = 1 })
		TweenService:Create(viewport, TweenInfo.new(0.4), { ImageTransparency = 1 }):Play()
		fade:Play()
		fade.Completed:Wait()
		scareGui:Destroy()
	end)
end

--------------------------------------------------------------------------
-- Per frame
--------------------------------------------------------------------------

local function formatClock(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local shakeAmount = 0
local reservedBottom: number? = nil

--- Keeps the toast stack below the banner while it shows.
local function reserveBanner(visible: boolean)
	local bottom = if visible then banner.AbsolutePosition.Y + banner.AbsoluteSize.Y else nil
	if bottom ~= reservedBottom then
		reservedBottom = bottom
		NotificationController.ReserveTop("Hunt", bottom)
	end
end

--- Pulses the banner's edge while she's coming for you; steady otherwise.
local function pulseEdge(targeted: boolean)
	local tuning = Config.UI.Banners
	local base = Theme.Tuning.Stroke
	if targeted then
		local wave = 0.5 + 0.5 * math.sin(os.clock() * tuning.HuntPulseSpeed * math.pi * 2)
		bannerEdge.Thickness = base + tuning.HuntPulseThickness * wave
		bannerEdge.Color = C.Blood:Lerp(C.BloodBright, wave)
	else
		bannerEdge.Thickness = base
		bannerEdge.Color = C.Blood
	end
end

local function update(dt: number)
	local s = state
	if not s then
		return
	end
	local phase = s:GetAttribute("Phase")
	local now = Workspace:GetServerTimeNow()

	if phase == "Idle" or phase == nil then
		banner.Visible = false
		reserveBanner(false)
		hideModel()
		setDread(0)
		shakeAmount = 0
		return
	end

	-- Banner
	local scale = bannerScale.Scale
	banner.Position = UDim2.new(0.5, 0, 0, bannerTop(scale, Config.UI.Banners.HuntSize.X * scale))
	banner.Visible = true
	reserveBanner(true)
	local carrying = localPlayer:GetAttribute("Carrying") == true
	local targeted = false
	if phase == "Warning" then
		bannerTitle.Text = "Something stirs in the woods..."
		bannerSub.Text = string.format("%s wakes in %s — get your eggs home!", Config.Hunt.Name, formatClock((s:GetAttribute("StartsAt") or now) - now))
	elseif phase == "Hunting" then
		local mine = s:GetAttribute("TargetUserId") == localPlayer.UserId
		targeted = mine
		bannerTitle.Text = if mine then "SHE'S COMING FOR YOU" else string.upper(Config.Hunt.Name) .. " IS HUNTING"
		local left = formatClock((s:GetAttribute("EndsAt") or now) - now)
		bannerSub.Text = if carrying
			then string.format("She can smell what you're carrying. Get it home!  %s", left)
			else string.format("Stay inside a camp or by the campfire.  %s", left)
	else
		bannerTitle.Text = "She's going back into the woods..."
		bannerSub.Text = ""
	end
	pulseEdge(targeted)

	-- Her model
	if phase == "Warning" then
		hideModel()
		riseStart = os.clock()
		setDread(0)
		return
	end
	showModel()
	local m = model :: Model
	local target = s:GetAttribute("Position")
	if typeof(target) ~= "Vector3" then
		return
	end
	local yaw = tonumber(s:GetAttribute("Yaw")) or 0
	local pos = shownPos
	if not pos then
		pos = target
		shownYaw = yaw
	end
	local alpha = 1 - math.exp(-dt * 8)
	pos = (pos :: Vector3):Lerp(target, alpha)
	shownPos = pos
	local diff = (yaw - shownYaw + math.pi) % (2 * math.pi) - math.pi
	shownYaw += diff * (1 - math.exp(-dt * 6))

	-- Rise from the ground at the start, sink at the end.
	local rise = math.clamp((os.clock() - riseStart) / RISE_TIME, 0, 1)
	if phase == "Leaving" then
		sinkOffset += SINK_SPEED * dt
	end
	local t = os.clock()
	local sway = math.sin(t * 1.3) * 0.08
	local bob = math.sin(t * 2.1) * 0.25
	local yOffset = -modelHeight * (1 - rise) - sinkOffset + bob
	m:PivotTo(CFrame.new((pos :: Vector3) + Vector3.new(0, yOffset, 0)) * CFrame.Angles(0, shownYaw, sway))
	if eye then
		(eye :: PointLight).Brightness = 2.5 + math.sin(t * 9) * 0.6
	end

	-- Dread by distance
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root and phase == "Hunting" then
		local dist = (root.Position - (pos :: Vector3)).Magnitude
		local dread = math.clamp(1 - dist / Config.Hunt.DreadRadius, 0, 1)
		setDread(dread)
		shakeAmount = if dist < Config.Hunt.ShakeRadius then (1 - dist / Config.Hunt.ShakeRadius) else 0
	else
		setDread(0)
		shakeAmount = 0
	end
end

--- Puts the lights, fog and heartbeat back. Safe to call more than once.
local function cleanup()
	dimLights(false)
	local hb = heartbeat
	if hb then
		hb:Destroy()
		heartbeat = nil
	end
	setDread(0)
end

local function onEvent(phase: any, info: any)
	if typeof(info) ~= "table" then
		info = {}
	end
	if phase == "Warning" then
		dimLights(true)
		SoundController.Play("HuntWarning")
		NotificationController.Show("The fire gutters... something is waking up in the woods.", "Warning")
	elseif phase == "Started" then
		riseStart = os.clock()
		SoundController.Play("HuntWail")
		if not heartbeat then
			heartbeat = SoundController.Play("Heartbeat", { Volume = 0 })
		end
	elseif phase == "Caught" then
		if info.UserId == localPlayer.UserId then
			jumpscare()
		else
			if typeof(info.Position) == "Vector3" then
				SoundController.PlayAt("Jumpscare", info.Position, { Volume = 0.6 })
			end
			if typeof(info.Name) == "string" then
				local text = if typeof(info.Item) == "string"
					then string.format("%s caught %s and took back the %s!", Config.Hunt.Name, info.Name, info.Item)
					else string.format("%s caught %s!", Config.Hunt.Name, info.Name)
				NotificationController.Show(text, "Warning")
			end
		end
	elseif phase == "Ended" then
		cleanup()
	end
end

function HuntController.Start()
	buildGui()
	state = ReplicatedStorage:WaitForChild("HuntState", 30) :: Configuration?
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("HuntEvent") :: RemoteEvent
	remote.OnClientEvent:Connect(onEvent)

	-- Joined mid-hunt: catch up.
	local s = state
	if s then
		-- Back to Idle without an "Ended" (lost, or never sent): restore anyway.
		s:GetAttributeChangedSignal("Phase"):Connect(function()
			if s:GetAttribute("Phase") == "Idle" then
				cleanup()
			end
		end)
		local phase = s:GetAttribute("Phase")
		if phase == "Warning" or phase == "Hunting" then
			dimLights(true)
			if phase == "Hunting" then
				riseStart = os.clock() - RISE_TIME
				heartbeat = SoundController.Play("Heartbeat", { Volume = 0 })
			end
		end
	end

	RunService.RenderStepped:Connect(function(dt)
		local ok, err = pcall(update, dt)
		if not ok then
			warn("[SAC/Hunt] update errored: " .. tostring(err))
		end
	end)

	-- Camera shake runs after the camera has updated.
	RunService:BindToRenderStep("SAC_HuntShake", Enum.RenderPriority.Camera.Value + 1, function()
		if shakeAmount > 0 then
			local camera = Workspace.CurrentCamera
			local a = shakeAmount * 0.35
			camera.CFrame = camera.CFrame * CFrame.Angles(
				math.rad((math.random() - 0.5) * a * 4),
				math.rad((math.random() - 0.5) * a * 4),
				0)
		end
	end)
end

return HuntController
