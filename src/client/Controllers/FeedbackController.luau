--!strict
--[[
	FeedbackController
	StarterPlayerScripts/Client/Controllers/FeedbackController

	The "juice": what makes hatching, collecting and stealing feel good.
	Display only — every number shown comes from the server.

	  * Hatch reveal (HatchResult remote, only on the hatcher's screen): the
	    screen dims, light rays in the rarity colour turn behind the new
	    cryptid spinning in a ViewportFrame, a RARITY stamp punches in, then
	    the name, its income and the egg it came from. The shell crack is
	    followed by a sting that gets bigger with rarity. Legendary and up
	    add a camera shake and confetti; Secret gets TV static and a name
	    that won't hold still. Closes itself after a few seconds; a tap
	    skips it. Several hatches in a row queue up (and hurry).
	  * World burst at the nest (sparks + a flash in the rarity colour).
	    Other players near a Legendary+ hatch see a smaller one
	    (FeedbackCue "HatchBurst").
	  * Cash (CashCollected remote): a "+$1.2K" that pops and floats up from
	    the creature, gold sparks, and a coin sound that climbs in pitch
	    while you sweep along a row of creatures. (The HUD cash bounce is in
	    HudController.)
	  * FeedbackCue: bat hits (3D bonk + dust for everyone), belt purchase,
	    steal/pickup, claim, and the rebirth flash.
	  * Dropping what you carry plays a sound.

	Tunables: Config.Feedback. Sounds: Config.Sounds via SoundController.
]]

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemVisuals = require(Shared:WaitForChild("ItemVisuals"))

local SoundController = require(script.Parent:WaitForChild("SoundController"))

local FeedbackController = {}

local FX = Config.Feedback
local localPlayer = Players.LocalPlayer

-- Look, not balance: fixed style choices for the animations.
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local CONFETTI_COLORS = {
	Color3.fromRGB(255, 214, 90), Color3.fromRGB(255, 120, 150), Color3.fromRGB(120, 220, 255),
	Color3.fromRGB(150, 255, 160), Color3.fromRGB(255, 255, 255), Color3.fromRGB(200, 150, 255),
}
local GLYPHS = { "#", "%", "&", "?", "!", "/", "\\", "_", "~", "*", "@", "$" }
local CAMERA_FOV = 35
local STATIC_COLUMNS, STATIC_ROWS = 16, 9
local SECRET_TICK = 0.07

type Reveal = {
	CreatureId: string,
	Rarity: string,
	Mutation: string?,
	EggId: string?,
	Position: Vector3?,
}

local queue: { Reveal } = {}
local showing = false
local playerGui: PlayerGui
local fxGui: ScreenGui -- persistent full-screen layer for flashes and confetti

--------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------

local function tween(object: Instance, seconds: number, props: { [string]: any }, style: Enum.EasingStyle?, direction: Enum.EasingDirection?): Tween
	local t = TweenService:Create(object, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

--- The colour a rarity shows as. Secret's own colour is near-black.
local function accent(rarityName: string): Color3
	local rarity = Config.Rarities[rarityName]
	if not rarity then
		return WHITE
	end
	return if rarity.NeverRenderClearly then FX.SecretAccent else rarity.Color
end

local function scramble(length: number): string
	local out = table.create(length)
	for i = 1, length do
		out[i] = GLYPHS[math.random(1, #GLYPHS)]
	end
	return table.concat(out)
end

local function fxFolder(): Instance
	local folder = Workspace:FindFirstChild("SAC_ClientFX")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "SAC_ClientFX"
		folder.Parent = Workspace
	end
	return folder :: Instance
end

--- Phone scaling for short-lived UI (the reveal, the rebirth stamp): the
--- same rule as Components/ScreenScale, worked out once. ScreenScale.Apply
--- keeps camera connections alive forever, which would pile up with one
--- per hatch.
local function fixedScale(target: GuiObject)
	local tuning = Config.UI.ScreenScale
	local camera = Workspace.CurrentCamera
	local scale = Instance.new("UIScale")
	scale.Name = "ScreenScale"
	scale.Scale = if camera then math.clamp(camera.ViewportSize.Y / tuning.ReferenceHeight, tuning.Min, tuning.Max) else 1
	scale.Parent = target
end

local function nearCamera(position: Vector3, maxDistance: number): boolean
	local camera = Workspace.CurrentCamera
	return camera == nil or (camera.CFrame.Position - position).Magnitude <= maxDistance
end

local function label(parent: Instance, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamBlack
	l.TextScaled = true
	l.TextColor3 = WHITE
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	for key, value in pairs(props) do
		(l :: any)[key] = value
	end
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = BLACK
	stroke.Transparency = 0.2
	stroke.Parent = l
	l.Parent = parent
	return l
end

--------------------------------------------------------------------------
-- World bursts
--------------------------------------------------------------------------

local function burst(position: Vector3, color: Color3, count: number, scale: number)
	local part = Instance.new("Part")
	part.Name = "Burst"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.one
	part.CFrame = CFrame.new(position)

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color, color:Lerp(WHITE, 0.6))
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55 * scale),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.7, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(FX.BurstLifetime * 0.5, FX.BurstLifetime)
	emitter.Speed = NumberRange.new(FX.BurstSpeed.Min * scale, FX.BurstSpeed.Max * scale)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, -Workspace.Gravity * 0.06, 0)
	emitter.Drag = 2.5
	emitter.RotSpeed = NumberRange.new(-180, 180)
	emitter.Rate = 0
	emitter.Parent = part

	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = 3
	light.Range = 12 * scale
	light.Shadows = false
	light.Parent = part

	part.Parent = fxFolder()
	emitter:Emit(count)
	tween(light, 0.8, { Brightness = 0 })
	Debris:AddItem(part, FX.BurstLifetime + 0.5)
end

--------------------------------------------------------------------------
-- Screen effects: shake, confetti, flash
--------------------------------------------------------------------------

local SHAKE_BIND = "SAC_FeedbackShake"

local function shake(duration: number, strength: number)
	pcall(function()
		RunService:UnbindFromRenderStep(SHAKE_BIND)
	end)
	local started = os.clock()
	-- Runs just after the camera scripts each frame, so it never fights them
	-- and nothing needs restoring when it stops.
	RunService:BindToRenderStep(SHAKE_BIND, Enum.RenderPriority.Camera.Value + 1, function()
		local elapsed = os.clock() - started
		local camera = Workspace.CurrentCamera
		if elapsed >= duration or not camera then
			RunService:UnbindFromRenderStep(SHAKE_BIND)
			return
		end
		local k = strength * (1 - elapsed / duration)
		camera.CFrame *= CFrame.new((math.random() - 0.5) * 2 * k, (math.random() - 0.5) * 2 * k, 0)
	end)
end

local function confetti(parent: Instance, color: Color3)
	for _ = 1, FX.ConfettiCount do
		local piece = Instance.new("Frame")
		piece.Name = "Confetti"
		piece.AnchorPoint = Vector2.new(0.5, 0.5)
		piece.Size = UDim2.fromOffset(math.random(8, 12), math.random(14, 20))
		local startX = math.random()
		piece.Position = UDim2.new(startX, 0, -0.05 - math.random() * 0.15, 0)
		piece.BackgroundColor3 = if math.random() < 0.4 then color else CONFETTI_COLORS[math.random(1, #CONFETTI_COLORS)]
		piece.BorderSizePixel = 0
		piece.Rotation = math.random(0, 360)
		piece.ZIndex = 40
		piece.Parent = parent
		local fall = 1.6 + math.random() * 1.2
		tween(piece, fall, {
			Position = UDim2.new(startX + (math.random() - 0.5) * 0.3, 0, 1.08, 0),
			Rotation = piece.Rotation + math.random(-540, 540),
		}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		Debris:AddItem(piece, fall + 0.1)
	end
end

local function flash(color: Color3, seconds: number)
	local frame = Instance.new("Frame")
	frame.Name = "Flash"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = 0.15
	frame.BorderSizePixel = 0
	frame.ZIndex = 30
	frame.Parent = fxGui
	tween(frame, seconds, { BackgroundTransparency = 1 })
	Debris:AddItem(frame, seconds + 0.1)
end

--------------------------------------------------------------------------
-- Hatch reveal
--------------------------------------------------------------------------

--- The real income of the cryptid that just hatched (it includes rebirth
--- and pass bonuses), read off its nest model once it's drawn.
local function findHatchedModel(data: Reveal): Model?
	for _, model in ipairs(CollectionService:GetTagged(Config.Tags.Creature)) do
		if model:IsA("Model")
			and model:GetAttribute("OwnerUserId") == localPlayer.UserId
			and model:GetAttribute("CreatureId") == data.CreatureId then
			if not data.Position or (model:GetPivot().Position - data.Position).Magnitude < 4 then
				return model
			end
		end
	end
	return nil
end

local function buildRays(parent: Instance, color: Color3): Frame
	local rays = Instance.new("Frame")
	rays.Name = "Rays"
	rays.AnchorPoint = Vector2.new(0.5, 0.5)
	rays.Position = UDim2.fromScale(0.5, 0.42)
	rays.Size = UDim2.fromOffset(640, 640)
	rays.BackgroundTransparency = 1
	rays.Parent = parent
	for i = 1, FX.RayCount do
		local ray = Instance.new("Frame")
		ray.AnchorPoint = Vector2.new(0.5, 0.5)
		ray.Position = UDim2.fromScale(0.5, 0.5)
		ray.Size = UDim2.new(0, 46, 1, 0)
		ray.Rotation = (i - 1) * 180 / FX.RayCount
		ray.BackgroundColor3 = color
		ray.BorderSizePixel = 0
		ray.Parent = rays
		-- Bright in the middle, fading out to the tips.
		local gradient = Instance.new("UIGradient")
		gradient.Rotation = 90
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0.35),
			NumberSequenceKeypoint.new(1, 1),
		})
		gradient.Parent = ray
	end
	return rays
end

local function buildStatic(parent: Instance): (Frame, { Frame })
	local static = Instance.new("Frame")
	static.Name = "Static"
	static.Size = UDim2.fromScale(1, 1)
	static.BackgroundTransparency = 1
	static.ZIndex = 35
	static.Parent = parent
	local cells: { Frame } = {}
	for row = 0, STATIC_ROWS - 1 do
		for column = 0, STATIC_COLUMNS - 1 do
			local cell = Instance.new("Frame")
			cell.BorderSizePixel = 0
			cell.Position = UDim2.fromScale(column / STATIC_COLUMNS, row / STATIC_ROWS)
			cell.Size = UDim2.fromScale(1 / STATIC_COLUMNS + 0.002, 1 / STATIC_ROWS + 0.002)
			cell.ZIndex = 35
			cell.Parent = static
			table.insert(cells, cell)
		end
	end
	return static, cells
end

local function runReveal(data: Reveal, gui: ScreenGui, connections: { RBXScriptConnection })
	local def = Config.CreaturesById[data.CreatureId]
	local rarity = Config.Rarities[data.Rarity]
	local big = rarity.Index >= FX.BigRarityIndex
	local secret = rarity.NeverRenderClearly == true
	local color = accent(data.Rarity)
	local duration = if big then FX.HatchRevealBigDuration else FX.HatchRevealDuration
	if #queue > 0 then
		duration *= FX.HatchRevealQueuedFactor
	end

	-- Backdrop and the skip button (the whole screen).
	local backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = BLACK
	backdrop.BackgroundTransparency = 1
	backdrop.BorderSizePixel = 0
	backdrop.Parent = gui

	local stage = Instance.new("Frame")
	stage.Name = "Stage"
	stage.AnchorPoint = Vector2.new(0.5, 0.5)
	stage.Position = UDim2.fromScale(0.5, 0.46)
	stage.Size = UDim2.fromOffset(420, 440)
	stage.BackgroundTransparency = 1
	stage.Parent = gui
	fixedScale(stage)

	-- Inner frame with its own UIScale for the pop-in (the stage's UIScale
	-- belongs to the phone scaling).
	local pop = Instance.new("Frame")
	pop.Name = "Pop"
	pop.Size = UDim2.fromScale(1, 1)
	pop.BackgroundTransparency = 1
	pop.Parent = stage
	local popScale = Instance.new("UIScale")
	popScale.Scale = 0.4
	popScale.Parent = pop

	local rays = buildRays(pop, color)
	local glow = Instance.new("Frame")
	glow.Name = "Glow"
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.fromScale(0.5, 0.42)
	glow.Size = UDim2.fromOffset(250, 250)
	glow.BackgroundColor3 = color
	glow.BackgroundTransparency = 0.72
	glow.Parent = pop
	local glowCorner = Instance.new("UICorner")
	glowCorner.CornerRadius = UDim.new(0.5, 0)
	glowCorner.Parent = glow

	-- The cryptid itself.
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Creature"
	viewport.AnchorPoint = Vector2.new(0.5, 0.5)
	viewport.Position = UDim2.fromScale(0.5, 0.42)
	viewport.Size = UDim2.fromOffset(300, 300)
	viewport.BackgroundTransparency = 1
	viewport.Ambient = Color3.fromRGB(150, 150, 165)
	viewport.LightColor = WHITE
	viewport.LightDirection = Vector3.new(0.3, -1, 0.8)
	viewport.Parent = pop

	local model: Model? = nil
	local spinParts: { BasePart } = {}
	local okBuild, built = pcall(ItemVisuals.BuildCreature, data.CreatureId, data.Mutation)
	local spinCenter = Vector3.zero
	local basePivot = CFrame.new()
	if okBuild and built then
		local m = built :: Model
		m.Parent = viewport
		local camera = Instance.new("Camera")
		camera.FieldOfView = CAMERA_FOV
		camera.Parent = viewport
		viewport.CurrentCamera = camera
		local boxCf, size = m:GetBoundingBox()
		local radius = math.max(size.Magnitude / 2, 0.5)
		local distance = radius / math.tan(math.rad(CAMERA_FOV / 2)) * 1.05
		-- Creatures face -Z, so look at them from -Z.
		camera.CFrame = CFrame.lookAt(boxCf.Position + Vector3.new(0, radius * 0.25, -distance), boxCf.Position)
		spinCenter = Vector3.new(boxCf.Position.X, 0, boxCf.Position.Z)
		basePivot = m:GetPivot()
		for _, d in ipairs(m:GetDescendants()) do
			if d:IsA("BasePart") and d.Name ~= "Eye" then
				table.insert(spinParts, d)
			end
		end
		model = m
	else
		warn("[SAC/Feedback] couldn't build " .. tostring(data.CreatureId) .. " for the reveal: " .. tostring(built))
	end

	-- Text.
	local stamp = label(pop, {
		Name = "Stamp",
		Position = UDim2.fromScale(0.5, 0.05),
		Size = UDim2.fromOffset(380, 70),
		Text = string.upper(rarity.DisplayName),
		TextColor3 = color,
		Rotation = -6,
		TextTransparency = 1,
	})
	local stampStroke = stamp:FindFirstChildOfClass("UIStroke") :: UIStroke
	stampStroke.Thickness = 4
	stampStroke.Transparency = 1
	local stampScale = Instance.new("UIScale")
	stampScale.Scale = 3
	stampScale.Parent = stamp

	local nameLabel = label(pop, {
		Name = "CreatureName",
		Position = UDim2.fromScale(0.5, 0.8),
		Size = UDim2.fromOffset(420, 48),
		Text = def.Name,
		TextTransparency = 1,
	})
	local income = rarity.IncomePerSecond
	local mutation = data.Mutation and Config.Mutations[data.Mutation]
	if mutation then
		income *= mutation.IncomeMultiplier
	end
	local incomeLabel = label(pop, {
		Name = "Income",
		Position = UDim2.fromScale(0.5, 0.9),
		Size = UDim2.fromOffset(320, 34),
		Text = "+$" .. Config.FormatNumber(income) .. "/s",
		TextColor3 = FX.CashColor,
		TextTransparency = 1,
	})
	local eggDef = Config.Eggs[data.EggId or ""]
	local eggLabel = label(pop, {
		Name = "FromEgg",
		Position = UDim2.fromScale(0.5, 0.975),
		Size = UDim2.fromOffset(320, 24),
		Font = Enum.Font.GothamBold,
		Text = if eggDef then ("from a " .. eggDef.Name) else "",
		TextColor3 = Color3.fromRGB(255, 190, 120),
		TextTransparency = 1,
	})
	local hint = label(gui, {
		Name = "Hint",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -24),
		Size = UDim2.fromOffset(260, 26),
		Font = Enum.Font.GothamBold,
		Text = "Tap to continue",
		TextColor3 = Color3.fromRGB(220, 220, 220),
		TextTransparency = 1,
	})
	fixedScale(hint)

	local skip = Instance.new("TextButton")
	skip.Name = "Skip"
	skip.Size = UDim2.fromScale(1, 1)
	skip.BackgroundTransparency = 1
	skip.Text = ""
	skip.AutoButtonColor = false
	skip.ZIndex = 50
	skip:SetAttribute("SAC_NoClick", true)
	skip.Parent = gui

	local static: Frame? = nil
	local staticCells: { Frame } = {}
	if secret then
		static, staticCells = buildStatic(gui)
	end

	gui.Enabled = true

	-- Sound: the crack, then the rarity's sting.
	SoundController.Play("HatchCrack")
	task.delay(FX.HatchStingDelay, function()
		local sting = FX.HatchStings[data.Rarity]
		if sting then
			SoundController.Play(sting)
		end
	end)

	-- Animate in.
	tween(backdrop, 0.25, { BackgroundTransparency = 0.35 })
	tween(popScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
	task.delay(FX.HatchStingDelay, function()
		tween(stampScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		tween(stamp, 0.2, { TextTransparency = 0 })
		tween(stampStroke, 0.2, { Transparency = 0.1 })
	end)
	for i, l in ipairs({ nameLabel, incomeLabel, eggLabel }) do
		task.delay(0.35 + i * 0.12, function()
			tween(l, 0.25, { TextTransparency = 0 })
		end)
	end
	task.delay(1, function()
		tween(hint, 0.4, { TextTransparency = 0.2 })
	end)
	if big then
		task.delay(FX.HatchStingDelay, function()
			shake(FX.ShakeDuration, FX.ShakeStrength)
			confetti(gui, color)
		end)
	end

	-- The real income once the nest model is drawn.
	task.delay(0.3, function()
		local nestModel = findHatchedModel(data)
		local real = nestModel and tonumber(nestModel:GetAttribute("IncomePerSecond"))
		if real and incomeLabel.Parent then
			incomeLabel.Text = "+$" .. Config.FormatNumber(real) .. "/s"
		end
	end)

	-- Per-frame motion.
	local started = os.clock()
	local spin = 0
	local nextSecretTick = 0
	table.insert(connections, RunService.RenderStepped:Connect(function(dt)
		local elapsed = os.clock() - started
		rays.Rotation = (rays.Rotation + FX.RaySpinSpeed * dt) % 360
		local pulse = 250 + math.sin(elapsed * 4) * 14
		glow.Size = UDim2.fromOffset(pulse, pulse)
		spin += FX.CreatureSpinSpeed * dt
		if model then
			model:PivotTo(CFrame.new(spinCenter) * CFrame.Angles(0, spin, 0) * CFrame.new(-spinCenter) * basePivot)
		end
		if secret and elapsed >= nextSecretTick then
			nextSecretTick = elapsed + SECRET_TICK
			-- Never render clearly: flicker, jitter, scrambled name, static.
			for _, part in ipairs(spinParts) do
				part.Transparency = math.random() * 0.6
			end
			viewport.Position = UDim2.new(0.5, math.random(-5, 5), 0.42, math.random(-3, 3))
			nameLabel.Text = if math.random() < 0.75 then scramble(10) else def.Name
			local staticOn = elapsed < 1 or math.random() < 0.12
			if static then
				static.Visible = staticOn
				if staticOn then
					for _, cell in ipairs(staticCells) do
						local v = math.random()
						cell.BackgroundColor3 = Color3.new(v, v, v)
						cell.BackgroundTransparency = 0.35 + math.random() * 0.5
					end
				end
			end
		end
	end))

	-- Wait for a tap (after a moment) or the timer.
	local closed = false
	table.insert(connections, skip.Activated:Connect(function()
		if os.clock() - started >= FX.HatchRevealMinTime then
			closed = true
		end
	end))
	while not closed and os.clock() - started < duration do
		task.wait()
	end

	-- Animate out.
	tween(backdrop, 0.2, { BackgroundTransparency = 1 })
	tween(popScale, 0.2, { Scale = 0 }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
	tween(hint, 0.15, { TextTransparency = 1 })
	if static then
		static.Visible = false
	end
	task.wait(0.22)
end

local function pump()
	if showing then
		return
	end
	showing = true
	task.spawn(function()
		while #queue > 0 do
			local data = table.remove(queue, 1) :: Reveal
			local gui = Instance.new("ScreenGui")
			gui.Name = "HatchReveal"
			gui.ResetOnSpawn = false
			gui.IgnoreGuiInset = true
			gui.DisplayOrder = 30
			gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
			gui.Enabled = false
			gui.Parent = playerGui
			local connections: { RBXScriptConnection } = {}
			local ok, err = pcall(runReveal, data, gui, connections)
			if not ok then
				warn("[SAC/Feedback] hatch reveal failed: " .. tostring(err))
			end
			for _, connection in ipairs(connections) do
				connection:Disconnect()
			end
			gui:Destroy()
		end
		showing = false
	end)
end

local function onHatchResult(creatureId: any, rarityName: any, mutation: any, eggId: any, position: any)
	if typeof(creatureId) ~= "string" or typeof(rarityName) ~= "string" then
		return
	end
	local def = Config.CreaturesById[creatureId]
	local rarity = Config.Rarities[rarityName]
	if not def or not rarity then
		return
	end
	local data: Reveal = {
		CreatureId = creatureId,
		Rarity = rarityName,
		Mutation = if typeof(mutation) == "string" then mutation else nil,
		EggId = if typeof(eggId) == "string" then eggId else nil,
		Position = if typeof(position) == "Vector3" then position else nil,
	}
	-- The burst at the nest happens right away; the reveal may queue.
	if data.Position then
		burst(data.Position + Vector3.new(0, 2, 0), accent(rarityName), FX.BurstParticles, 1 + (rarity.Index - 1) * 0.15)
	end
	if #queue < FX.HatchQueueMax then
		table.insert(queue, data)
		pump()
	end
end

--------------------------------------------------------------------------
-- Cash
--------------------------------------------------------------------------

local streak = 0
local lastCashAt = -math.huge
local lastCashSoundAt = -math.huge
local popupAnchor: BasePart? = nil

local function getPopupAnchor(): BasePart
	if popupAnchor and popupAnchor.Parent then
		return popupAnchor
	end
	local part = Instance.new("Part")
	part.Name = "PopupAnchor"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.one
	part.CFrame = CFrame.new()
	part.Parent = fxFolder()
	popupAnchor = part
	return part
end

local function onCashCollected(amount: any, position: any)
	if typeof(amount) ~= "number" or typeof(position) ~= "Vector3" or amount <= 0 then
		return
	end
	if not nearCamera(position, FX.CashPopupMaxDistance) then
		return
	end

	-- Coin sound, pitching up while you sweep a row of creatures.
	local now = os.clock()
	streak = if now - lastCashAt <= FX.CashStreakWindow then streak + 1 else 0
	lastCashAt = now
	if now - lastCashSoundAt >= FX.CashSoundGap then
		lastCashSoundAt = now
		SoundController.Play("CashCollect", {
			PlaybackSpeed = math.min(FX.CashStreakPitchMax, 1 + streak * FX.CashStreakPitchStep),
		})
	end

	local bigAmount = amount >= FX.CashBigAmount
	local color = if bigAmount then FX.CashBigColor else FX.CashColor

	local attachment = Instance.new("Attachment")
	attachment.Name = "CashPopup"
	attachment.Parent = getPopupAnchor()
	attachment.WorldPosition = position

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Popup"
	billboard.Size = if bigAmount then UDim2.fromOffset(220, 60) else UDim2.fromOffset(160, 46)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = FX.CashPopupMaxDistance
	billboard.Parent = attachment

	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.GothamBlack
	text.TextScaled = true
	text.TextColor3 = color
	text.Text = "+$" .. Config.FormatNumber(amount)
	text.Parent = billboard
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = Color3.fromRGB(20, 40, 20)
	stroke.Parent = text
	local scale = Instance.new("UIScale")
	scale.Scale = 0.3
	scale.Parent = text

	tween(scale, 0.2, { Scale = 1 }, Enum.EasingStyle.Back)
	tween(attachment, FX.CashPopupTime, { Position = attachment.Position + Vector3.new(0, FX.CashPopupRise, 0) })
	task.delay(FX.CashPopupTime * 0.55, function()
		if text.Parent then
			tween(text, FX.CashPopupTime * 0.45, { TextTransparency = 1 })
			tween(stroke, FX.CashPopupTime * 0.45, { Transparency = 1 })
		end
	end)
	Debris:AddItem(attachment, FX.CashPopupTime + 0.15)

	burst(position, FX.CashBigColor, FX.CashBurstParticles, 0.45)
end

--------------------------------------------------------------------------
-- Cues
--------------------------------------------------------------------------

local function rebirthFx(rebirths: number)
	SoundController.Play("Rebirth")
	flash(WHITE, 0.9)
	confetti(fxGui, Color3.fromRGB(255, 214, 90))
	shake(FX.ShakeDuration, FX.ShakeStrength * 0.6)

	-- Holder carries the phone scaling; the label inside does the punch
	-- (one UIScale per object).
	local holder = Instance.new("Frame")
	holder.Name = "RebirthStamp"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.38)
	holder.Size = UDim2.fromOffset(460, 80)
	holder.BackgroundTransparency = 1
	holder.ZIndex = 41
	holder.Parent = fxGui
	fixedScale(holder)
	local banner = label(holder, {
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		Text = string.format("REBIRTH %d!", rebirths),
		TextColor3 = Color3.fromRGB(255, 214, 90),
		Rotation = -4,
		ZIndex = 41,
	})
	local punch = Instance.new("UIScale")
	punch.Scale = 3
	punch.Parent = banner
	tween(punch, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
	task.delay(2, function()
		tween(banner, 0.4, { TextTransparency = 1 })
		local stroke = banner:FindFirstChildOfClass("UIStroke")
		if stroke then
			tween(stroke, 0.4, { Transparency = 1 })
		end
		Debris:AddItem(holder, 0.5)
	end)
end

local function myPosition(): Vector3?
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

local function onCue(name: any, info: any)
	if typeof(name) ~= "string" then
		return
	end
	local data: { [string]: any } = if typeof(info) == "table" then info else {}
	local position = if typeof(data.Position) == "Vector3" then data.Position :: Vector3 else nil

	if name == "BatHit" and position then
		SoundController.PlayAt("BatHit", position)
		if nearCamera(position, FX.CashPopupMaxDistance) then
			burst(position, FX.BatDustColor, FX.BatDustParticles, 0.6)
		end
	elseif name == "HatchBurst" and position then
		if data.UserId == localPlayer.UserId or typeof(data.Rarity) ~= "string" then
			return -- our own hatch already got the full show
		end
		if nearCamera(position, FX.RemoteBurstMaxDistance) then
			burst(position + Vector3.new(0, 2, 0), accent(data.Rarity), FX.BurstParticlesRemote, 1.2)
			local sting = FX.HatchStings[data.Rarity]
			if sting then
				SoundController.PlayAt(sting, position, { RollOff = FX.RemoteBurstMaxDistance })
			end
		end
	elseif name == "Bought" then
		SoundController.Play("Purchase")
	elseif name == "Taken" then
		SoundController.Play(if data.Stolen then "StealSuccess" else "Pickup")
	elseif name == "Claimed" then
		SoundController.Play(if data.Stolen then "Purchase" else "Pickup")
		local here = myPosition()
		if here then
			burst(here, FX.CashBigColor, FX.CashBurstParticles * 2, 0.7)
		end
	elseif name == "Rebirth" then
		rebirthFx(tonumber(data.Rebirths) or 0)
	end
end

-- Dropping what you carry: the server drops a fresh model with Dropped set.
local lastCarryId: number? = nil

local function onCarriedItem(model: Instance)
	local carryId = model:GetAttribute("CarryId")
	if typeof(carryId) ~= "number" then
		return
	end
	if model:GetAttribute("CarrierUserId") == localPlayer.UserId and model:GetAttribute("Dropped") ~= true then
		lastCarryId = carryId
	elseif model:GetAttribute("Dropped") == true and carryId == lastCarryId then
		lastCarryId = nil
		SoundController.Play("Drop")
	end
end

--------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------

function FeedbackController.Start()
	playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

	fxGui = Instance.new("ScreenGui")
	fxGui.Name = "SAC_ScreenFX"
	fxGui.ResetOnSpawn = false
	fxGui.IgnoreGuiInset = true
	fxGui.DisplayOrder = 31
	fxGui.Parent = playerGui

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local hatchRemote = remotes:WaitForChild("HatchResult") :: RemoteEvent
	hatchRemote.OnClientEvent:Connect(onHatchResult)
	local cashRemote = remotes:WaitForChild("CashCollected") :: RemoteEvent
	cashRemote.OnClientEvent:Connect(onCashCollected)

	-- FeedbackCue is new at Step 8: don't hang if a server without it is running.
	task.spawn(function()
		local cueRemote = remotes:WaitForChild("FeedbackCue", 30)
		if cueRemote and cueRemote:IsA("RemoteEvent") then
			cueRemote.OnClientEvent:Connect(onCue)
		end
	end)

	for _, model in ipairs(CollectionService:GetTagged(Config.Tags.CarriedItem)) do
		onCarriedItem(model)
	end
	CollectionService:GetInstanceAddedSignal(Config.Tags.CarriedItem):Connect(onCarriedItem)
end

return FeedbackController
