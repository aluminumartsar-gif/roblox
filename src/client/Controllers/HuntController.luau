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
	  * Dread, by distance: a heartbeat that speeds up as she gets closer, a
	    dark red vignette, film grain, and camera shake when she's very close.
	  * Caught: a jumpscare for the victim (her face fills the screen with a
	    scream); everyone nearby hears it.
	  * A banner with the time left and advice that depends on you: carrying
	    an egg ("she can smell it — get it home"), or not.

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
local ScreenScale = require(Components:WaitForChild("ScreenScale"))
local SoundController = require(script.Parent:WaitForChild("SoundController"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))

local HuntController = {}

local localPlayer = Players.LocalPlayer

local RISE_TIME = 2.2
local SINK_SPEED = 3.5 -- studs per second while leaving

local state: Configuration? = nil
local model: Model? = nil
local modelHeight = Config.Hunt.ModelHeight
local eye: PointLight? = nil

local shownPos: Vector3? = nil
local shownYaw = 0
local riseStart = 0
local sinkOffset = 0

local gui: ScreenGui
local banner: Frame
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
	local dark = Color3.fromRGB(20, 17, 18)
	local bark = Color3.fromRGB(38, 30, 27)
	local bone = Color3.fromRGB(214, 206, 188)

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

local function buildModel(): Model
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
	modelHeight = m:GetExtentsSize().Y

	-- A cold mist around her feet.
	local primary = m.PrimaryPart :: BasePart
	local feet = Instance.new("Attachment")
	feet.Name = "Mist"
	feet.Position = primary.CFrame:PointToObjectSpace(m:GetPivot().Position)
	feet.Parent = primary
	local mist = Instance.new("ParticleEmitter")
	mist.Color = ColorSequence.new(Color3.fromRGB(30, 26, 30))
	mist.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.3, 0.55), NumberSequenceKeypoint.new(1, 1) })
	mist.Size = NumberSequence.new(4, 9)
	mist.Lifetime = NumberRange.new(2, 3.5)
	mist.Rate = 12
	mist.Speed = NumberRange.new(0.5, 1.5)
	mist.SpreadAngle = Vector2.new(180, 20)
	mist.LightInfluence = 0.3
	mist.Parent = feet

	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("PointLight") then
			eye = d
		end
	end
	return m
end

local function showModel()
	if not model then
		model = buildModel()
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
-- Screen effects
--------------------------------------------------------------------------

local function label(parent: Instance, size: number, font: Enum.Font): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, size)
	l.Font = font
	l.TextSize = size
	l.TextColor3 = Color3.new(1, 1, 1)
	l.TextStrokeTransparency = 0.4
	l.Parent = parent
	return l
end

local function buildGui()
	gui = Instance.new("ScreenGui")
	gui.Name = "Hunt"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 5

	-- Vignette: four edge frames fading inward.
	local edges = {
		{ AnchorPoint = Vector2.new(0, 0), Position = UDim2.fromScale(0, 0), Size = UDim2.fromScale(1, 0.32), Rotation = 90 },
		{ AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.fromScale(1, 0.32), Rotation = -90 },
		{ AnchorPoint = Vector2.new(0, 0), Position = UDim2.fromScale(0, 0), Size = UDim2.fromScale(0.28, 1), Rotation = 0 },
		{ AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromScale(0.28, 1), Rotation = 180 },
	}
	for _, e in ipairs(edges) do
		local f = Instance.new("Frame")
		f.AnchorPoint = e.AnchorPoint
		f.Position = e.Position
		f.Size = e.Size
		f.BackgroundColor3 = Color3.fromRGB(70, 0, 0)
		f.BorderSizePixel = 0
		f.BackgroundTransparency = 1
		f.Parent = gui
		local g = Instance.new("UIGradient")
		g.Rotation = e.Rotation
		g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
		g.Parent = f
		table.insert(vignette, f)
	end

	-- Film grain: a handful of flickering specks, re-scattered every frame.
	grain = Instance.new("Frame")
	grain.Name = "Grain"
	grain.BackgroundTransparency = 1
	grain.Size = UDim2.fromScale(1, 1)
	grain.Visible = false
	grain.Parent = gui
	for _ = 1, 40 do
		local speck = Instance.new("Frame")
		speck.BorderSizePixel = 0
		speck.BackgroundColor3 = Color3.new(1, 1, 1)
		speck.Size = UDim2.fromOffset(2, 2)
		speck.Parent = grain
	end

	-- Banner, just below the kit's Base/Eggs buttons (they fill the top
	-- 11.5% of the screen) — the same spot as the sighting banner.
	banner = Instance.new("Frame")
	banner.Name = "Banner"
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0.12, 0)
	banner.Size = UDim2.fromOffset(460, 62)
	banner.BackgroundColor3 = Color3.fromRGB(16, 6, 8)
	banner.BackgroundTransparency = 0.15
	banner.Visible = false
	banner.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = banner
	local stroke = Instance.new("UIStroke")
	stroke.Color = Config.Hunt.Color
	stroke.Thickness = 2
	stroke.Parent = banner
	local list = Instance.new("UIListLayout")
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Padding = UDim.new(0, 2)
	list.Parent = banner
	bannerTitle = label(banner, 24, Enum.Font.GothamBlack)
	bannerTitle.TextColor3 = Config.Hunt.Color
	bannerSub = label(banner, 16, Enum.Font.GothamBold)
	ScreenScale.Apply(banner)

	gui.Parent = localPlayer:WaitForChild("PlayerGui")
end

local function setDread(amount: number)
	-- amount 0..1
	for _, f in ipairs(vignette) do
		f.BackgroundTransparency = 1 - amount * 0.75
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
	local overlay = Instance.new("Frame")
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 0
	overlay.ZIndex = 50
	overlay.Parent = gui

	-- Her face, filling the screen.
	local viewport = Instance.new("ViewportFrame")
	viewport.AnchorPoint = Vector2.new(0.5, 0.5)
	viewport.Position = UDim2.fromScale(0.5, 0.5)
	viewport.Size = UDim2.fromScale(0.6, 0.6)
	viewport.BackgroundTransparency = 1
	viewport.Ambient = Color3.fromRGB(150, 140, 140)
	viewport.LightColor = Config.Hunt.Color
	viewport.LightDirection = Vector3.new(0, -0.3, 1)
	viewport.ZIndex = 51
	viewport.Parent = overlay
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

	local flash = Instance.new("Frame")
	flash.Size = UDim2.fromScale(1, 1)
	flash.BackgroundColor3 = Config.Hunt.Color
	flash.BackgroundTransparency = 0.3
	flash.ZIndex = 52
	flash.Parent = overlay

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
		overlay:Destroy()
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
	banner.Visible = true
	reserveBanner(true)
	local carrying = localPlayer:GetAttribute("Carrying") == true
	if phase == "Warning" then
		bannerTitle.Text = "Something stirs in the woods..."
		bannerSub.Text = string.format("%s wakes in %s — get your eggs home!", Config.Hunt.Name, formatClock((s:GetAttribute("StartsAt") or now) - now))
	elseif phase == "Hunting" then
		local mine = s:GetAttribute("TargetUserId") == localPlayer.UserId
		bannerTitle.Text = if mine then "SHE'S COMING FOR YOU" else string.upper(Config.Hunt.Name) .. " IS HUNTING"
		local left = formatClock((s:GetAttribute("EndsAt") or now) - now)
		bannerSub.Text = if carrying
			then string.format("She can smell your egg. Get it home!  %s", left)
			else string.format("Stay inside a camp or by the campfire.  %s", left)
	else
		bannerTitle.Text = "She's going back into the woods..."
		bannerSub.Text = ""
	end

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
		dimLights(false)
		local hb = heartbeat
		if hb then
			hb:Destroy()
			heartbeat = nil
		end
		setDread(0)
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
