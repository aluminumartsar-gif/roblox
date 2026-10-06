--!strict
--[[
	FeedbackController
	StarterPlayerScripts/Client/Controllers/FeedbackController

	The "juice": what makes hatching, collecting and stealing feel good.
	Display only — every number shown comes from the server.

	  * Hatch reveal (HatchResult remote, only on the hatcher's screen): the
	    screen dims, light rays in the rarity colour turn behind the new
	    cryptid spinning in a ViewportFrame, a RARITY stamp (horror font, in
	    a rubber-stamp box) punches in, then a charred plate fades in with
	    the cryptid's name, its income and the egg it came from. The shell
	    crack is followed by a sting that gets bigger with rarity. Legendary
	    and up add a camera shake and confetti; Secret gets TV static and a
	    name that won't hold still. Closes itself after a few seconds; the
	    Skip button (top right) closes it early. Several hatches in a row
	    queue up (and hurry). While you carry something home the reveal
	    waits until you drop it off.
	    The reveal's ScreenGui is called "HatchReveal" and sits in PlayerGui
	    from the moment a reveal is due until it closes: CodexController
	    holds its "NEW CODEX ENTRY" polaroid while it is there, so the two
	    celebrations play one after the other.
	  * World burst at the nest (sparks + a flash in the rarity colour).
	    Other players near a Legendary+ hatch see a smaller one
	    (FeedbackCue "HatchBurst").
	  * Cash (CashCollected remote): a "+$1.2K" that pops and floats up from
	    the creature (moss green, gold for big amounts), gold sparks, and a
	    coin sound that climbs in pitch while you sweep along a row of
	    creatures. (The HUD cash count-up and bounce are in HudController.)
	  * FeedbackCue: bat hits (3D bonk + dust for everyone), belt purchase,
	    steal/pickup, claim, and rebirth (a flash, then confetti and a
	    "REBIRTH N!" stamp).
	  * Dropping what you carry plays a sound.

	Layers (Config.UI.Layers): the reveal on Reveal, the rebirth flash on
	Flash, the rebirth stamp and confetti on Celebration.
	Tunables: Config.Feedback (timings, amounts), Config.UI.Toasts (look).
	Sounds: Config.Sounds via SoundController.
]]

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local ItemVisuals = require(Shared:WaitForChild("ItemVisuals"))

local Components = script.Parent.Parent:WaitForChild("Components")
local Theme = require(Components:WaitForChild("Theme"))
local UI = require(Components:WaitForChild("UI"))

local SoundController = require(script.Parent:WaitForChild("SoundController"))

local FeedbackController = {}

local FX = Config.Feedback
local LOOK = Config.UI.Toasts
local LAYERS = Config.UI.Layers
local C = Theme.Colors
local localPlayer = Players.LocalPlayer

-- Look, not balance: fixed style choices for the animations.
local WHITE = Color3.new(1, 1, 1) -- neutral light / gradient base, not a palette colour
local GLYPHS = { "#", "%", "&", "?", "!", "/", "\\", "_", "~", "*", "@", "$" }
local CAMERA_FOV = 35
local STATIC_COLUMNS, STATIC_ROWS = 16, 9
local SECRET_TICK = 0.07
-- Reveal stage geometry, px at the reference height (the stage scales).
local STAGE_SIZE = Vector2.new(420, 440)
local CREATURE_Y = 0.42 -- centre of the cryptid, as a fraction of the stage height
local CREATURE_SIZE = 300
local RAYS_SIZE = 640
local RAY_WIDTH = 46
local GLOW_SIZE = 250
local GLOW_PULSE = 14
local PLATE_TOP = 326 -- px from the top of the stage
local PLATE_WIDTH = 380
local STAMP_HEIGHT = 76
local SKIP_SIZE = Vector2.new(120, 40)
local SKIP_TOP = 64 -- px from the very top of the screen (clears Roblox's top bar)
local REBIRTH_STAMP_SIZE = Vector2.new(460, 80)
local DISPLAY_MIN_SIZE = 28 -- the Display font is only legible this big

type Reveal = {
	CreatureId: string,
	Rarity: string,
	Mutation: string?,
	EggId: string?,
	Position: Vector3?,
}

-- One property of one part that fades in: the instance, the property and
-- its value once shown.
type Fade = { Target: Instance, Property: string, Shown: number }

local queue: { Reveal } = {}
local showing = false
local playerGui: PlayerGui
local fxGui: ScreenGui -- persistent full-screen layer for flashes
local celebrationGui: ScreenGui -- persistent layer for the rebirth stamp and confetti

--------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------

local function tween(object: Instance, seconds: number, props: { [string]: any }, style: Enum.EasingStyle?, direction: Enum.EasingDirection?): Tween
	return UI.Tween(object, seconds, props, style, direction)
end

--- A colour from Theme.Colors by name (Config.UI.Toasts names them).
local function themeColor(name: string?, fallback: Color3): Color3
	local color = if name then (C :: any)[name] else nil
	return if typeof(color) == "Color3" then color else fallback
end

local CONFETTI_COLORS: { Color3 } = {}
for _, name in ipairs(LOOK.ConfettiColors) do
	table.insert(CONFETTI_COLORS, themeColor(name, C.Text))
end

--- The colour a rarity shows as in the effects. Secret's own colour is
--- near-black, so the rays, glow and stamp use Config.Feedback.SecretAccent.
local function accent(rarityName: string): Color3
	local rarity = Config.Rarities[rarityName]
	if not rarity then
		return C.Text
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

--- A dark outline round a label's text so it reads over the 3D world.
--- Starts hidden (fade it in with the text).
local function outline(label: TextLabel, color: Color3, thickness: number): UIStroke
	return UI.Stroke({
		Name = "Outline",
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Color = color,
		Thickness = thickness,
		Transparency = 1,
		Parent = label,
	}) :: UIStroke
end

--- Big horror-font text (Display, via UI.Title) that shrinks to fit its
--- box but never below the legible size. Starts hidden.
local function displayText(text: string, maxSize: number, props: { [string]: any }): (TextLabel, UIStroke)
	local label = UI.Title(text, maxSize, props)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextScaled = true
	label.RichText = false
	label.TextTransparency = 1
	UI.new("UITextSizeConstraint", {
		MaxTextSize = maxSize,
		MinTextSize = math.min(DISPLAY_MIN_SIZE, maxSize),
		Parent = label,
	})
	local edge = label:FindFirstChildOfClass("UIStroke") :: UIStroke
	edge.Transparency = 1
	return label, edge
end

local function fadeIn(fades: { Fade }, seconds: number)
	for _, fade in ipairs(fades) do
		tween(fade.Target, seconds, { [fade.Property] = fade.Shown })
	end
end

local function fadeOut(fades: { Fade }, seconds: number)
	for _, fade in ipairs(fades) do
		tween(fade.Target, seconds, { [fade.Property] = 1 })
	end
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
		local startX = math.random()
		local piece = UI.new("Frame", {
			Name = "Confetti",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(math.random(8, 12), math.random(14, 20)),
			Position = UDim2.new(startX, 0, -0.05 - math.random() * 0.15, 0),
			BackgroundColor3 = if math.random() < 0.4 or #CONFETTI_COLORS == 0
				then color
				else CONFETTI_COLORS[math.random(1, #CONFETTI_COLORS)],
			BorderSizePixel = 0,
			Rotation = math.random(0, 360),
			ZIndex = 40,
			Parent = parent,
		}) :: Frame
		local fall = 1.6 + math.random() * 1.2
		tween(piece, fall, {
			Position = UDim2.new(startX + (math.random() - 0.5) * 0.3, 0, 1.08, 0),
			Rotation = piece.Rotation + math.random(-540, 540),
		}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		Debris:AddItem(piece, fall + 0.1)
	end
end

local function flash(color: Color3, seconds: number)
	local frame = UI.new("Frame", {
		Name = "Flash",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = color,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		ZIndex = 30,
		Parent = fxGui,
	})
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
	local rays = UI.new("Frame", {
		Name = "Rays",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, CREATURE_Y),
		Size = UDim2.fromOffset(RAYS_SIZE, RAYS_SIZE),
		BackgroundTransparency = 1,
		ZIndex = 1,
		Parent = parent,
	}) :: Frame
	for i = 1, FX.RayCount do
		UI.new("Frame", {
			Name = "Ray",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(0, RAY_WIDTH, 1, 0),
			Rotation = (i - 1) * 180 / FX.RayCount,
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Parent = rays,
		}, {
			-- Bright in the middle, fading out to the tips.
			UI.new("UIGradient", {
				Rotation = 90,
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 1),
					NumberSequenceKeypoint.new(0.5, 0.35),
					NumberSequenceKeypoint.new(1, 1),
				}),
			}),
		})
	end
	return rays
end

local function buildStatic(parent: Instance): (Frame, { Frame })
	local static = UI.new("Frame", {
		Name = "Static",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 35,
		Parent = parent,
	}) :: Frame
	local cells: { Frame } = {}
	for row = 0, STATIC_ROWS - 1 do
		for column = 0, STATIC_COLUMNS - 1 do
			local cell = UI.new("Frame", {
				BorderSizePixel = 0,
				Position = UDim2.fromScale(column / STATIC_COLUMNS, row / STATIC_ROWS),
				Size = UDim2.fromScale(1 / STATIC_COLUMNS + 0.002, 1 / STATIC_ROWS + 0.002),
				ZIndex = 35,
				Parent = static,
			}) :: Frame
			table.insert(cells, cell)
		end
	end
	return static, cells
end

--- The RARITY stamp: the rarity's name in the horror font inside a
--- rubber-stamp box, tilted. Returns the box, its punch scale and fades.
local function buildStamp(parent: Instance, text: string, color: Color3): (Frame, UIScale, { Fade })
	local box = UI.new("Frame", {
		Name = "Stamp",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.06),
		Size = UDim2.fromOffset(0, STAMP_HEIGHT),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		Rotation = -6,
		ZIndex = 5,
		Parent = parent,
	}, {
		UI.Corner(Theme.Tuning.Corner),
		UI.Padding({ Left = 18, Right = 18 }),
	}) :: Frame
	local border = UI.Stroke({ Name = "Border", Color = color, Thickness = 3, Transparency = 1, Parent = box }) :: UIStroke
	local label = UI.Title(text, LOOK.RevealStampTextSize, {
		Name = "Rarity",
		TextColor3 = color,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTransparency = 1,
		RichText = false,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		ZIndex = 5,
		Parent = box,
	})
	-- A heavy dark edge instead of the title's ember one, so any rarity
	-- colour reads over the rays.
	local edge = label:FindFirstChildOfClass("UIStroke") :: UIStroke
	edge.Color = C.Shadow
	edge.Thickness = 4
	edge.Transparency = 1
	local punch = UI.new("UIScale", { Name = "Punch", Scale = 3, Parent = box }) :: UIScale
	return box, punch, {
		{ Target = label, Property = "TextTransparency", Shown = 0 },
		{ Target = edge, Property = "Transparency", Shown = 0.1 },
		{ Target = border, Property = "Transparency", Shown = 0.15 },
	}
end

--- The Skip button, top right under the Roblox top bar. Eggs hatch on
--- their own, so the reveal can open mid-chase: nothing in it may cover
--- the screen and eat input (the thumbstick, jump button and tool taps
--- must keep working). Everything else in the reveal is a non-Active
--- Frame or label. Starts invisible; fades in after a moment.
local function buildSkip(parent: Instance): (TextButton, { Fade })
	local skip = UI.new("TextButton", {
		Name = "Skip",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, SKIP_TOP),
		Size = UDim2.fromOffset(SKIP_SIZE.X, SKIP_SIZE.Y),
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		ZIndex = 50,
	}, {
		UI.Corner(Theme.Tuning.Corner),
	}) :: TextButton
	skip:SetAttribute("SAC_NoClick", true)
	local edge = UI.Stroke({ Name = "Edge", Color = C.Edge, Thickness = 1.5, Transparency = 1, Parent = skip }) :: UIStroke
	local hint = UI.Text({
		Name = "Hint",
		Role = "Heading",
		Weight = "SemiBold",
		Text = "SKIP",
		RichText = false,
		TextSize = 20,
		TextColor3 = themeColor(LOOK.SkipTextColor, C.TextDim),
		TextTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 51,
		Parent = skip,
	})
	fixedScale(skip)
	skip.Parent = parent
	return skip, {
		{ Target = skip, Property = "BackgroundTransparency", Shown = 0.45 },
		{ Target = edge, Property = "Transparency", Shown = 0.3 },
		{ Target = hint, Property = "TextTransparency", Shown = 0.1 },
	}
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

	-- Backdrop (the whole screen; a plain Frame, so touches pass through).
	local backdrop = UI.new("Frame", {
		Name = "Backdrop",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.Backdrop,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 1,
		Parent = gui,
	})

	local stage = UI.new("Frame", {
		Name = "Stage",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.46),
		Size = UDim2.fromOffset(STAGE_SIZE.X, STAGE_SIZE.Y),
		BackgroundTransparency = 1,
		ZIndex = 2,
		Parent = gui,
	}) :: Frame
	fixedScale(stage)

	-- Inner frame with its own UIScale for the pop-in (the stage's UIScale
	-- belongs to the phone scaling).
	local pop = UI.new("Frame", {
		Name = "Pop",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = stage,
	})
	local popScale = UI.new("UIScale", { Scale = 0.4, Parent = pop }) :: UIScale

	local rays = buildRays(pop, color)
	local glow = UI.new("Frame", {
		Name = "Glow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, CREATURE_Y),
		Size = UDim2.fromOffset(GLOW_SIZE, GLOW_SIZE),
		BackgroundColor3 = color,
		BackgroundTransparency = 0.72,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = pop,
	}, {
		UI.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
	}) :: Frame

	-- The cryptid itself.
	local viewport = UI.new("ViewportFrame", {
		Name = "Creature",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, CREATURE_Y),
		Size = UDim2.fromOffset(CREATURE_SIZE, CREATURE_SIZE),
		BackgroundTransparency = 1,
		Ambient = LOOK.RevealAmbient,
		LightColor = WHITE,
		LightDirection = Vector3.new(0.3, -1, 0.8),
		ZIndex = 4,
		Parent = pop,
	}) :: ViewportFrame

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

	-- The RARITY stamp.
	local _, stampPunch, stampFades = buildStamp(pop, string.upper(rarity.DisplayName), color)

	-- The charred plate with the name, income and egg (one line each).
	local plate = UI.Panel({
		Name = "Plate",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, PLATE_TOP),
		Size = UDim2.fromOffset(PLATE_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = pop,
	})
	local plateEdge = plate:FindFirstChildOfClass("UIStroke") :: UIStroke
	plateEdge.Color = Theme.Mix(C.Edge, color, 0.5)
	plateEdge.Transparency = 1
	UI.List({ HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = 2 }).Parent = plate
	UI.Padding({ Top = 6, Bottom = 8, Left = 10, Right = 10 }).Parent = plate

	local nameLabel, nameEdge = displayText(def.Name, LOOK.RevealNameTextSize, {
		Name = "CreatureName",
		Size = UDim2.new(1, 0, 0, LOOK.RevealNameTextSize + 4),
		LayoutOrder = 1,
		ZIndex = 3,
		Parent = plate,
	})

	local income = rarity.IncomePerSecond
	local mutation = data.Mutation and Config.Mutations[data.Mutation]
	if mutation then
		income *= mutation.IncomeMultiplier
	end
	local incomeLabel = UI.Text({
		Name = "Income",
		Role = "Heading",
		Text = "+$" .. Config.FormatNumber(income) .. "/s",
		RichText = false,
		TextSize = LOOK.RevealIncomeTextSize,
		TextColor3 = C.MossBright,
		TextTransparency = 1,
		Size = UDim2.new(1, 0, 0, LOOK.RevealIncomeTextSize + 4),
		LayoutOrder = 2,
		ZIndex = 3,
		Parent = plate,
	})
	local incomeEdge = outline(incomeLabel, C.Shadow, 1.5)

	local eggDef = Config.Eggs[data.EggId or ""]
	local eggLabel = UI.Text({
		Name = "FromEgg",
		Role = "Notes",
		Text = if eggDef then ("from a " .. eggDef.Name) else "",
		RichText = false,
		TextSize = LOOK.RevealEggTextSize,
		TextColor3 = C.EmberBright,
		TextTransparency = 1,
		Size = UDim2.new(1, 0, 0, LOOK.RevealEggTextSize + 4),
		LayoutOrder = 3,
		ZIndex = 3,
		Parent = plate,
	})

	local lines: { { Fade } } = {
		{
			{ Target = plate, Property = "BackgroundTransparency", Shown = LOOK.RevealPlateTransparency },
			{ Target = plateEdge, Property = "Transparency", Shown = 0 },
			{ Target = nameLabel, Property = "TextTransparency", Shown = 0 },
			{ Target = nameEdge, Property = "Transparency", Shown = 0.15 },
		},
		{
			{ Target = incomeLabel, Property = "TextTransparency", Shown = 0 },
			{ Target = incomeEdge, Property = "Transparency", Shown = 0.3 },
		},
		{
			{ Target = eggLabel, Property = "TextTransparency", Shown = 0 },
		},
	}

	local skip, skipFades = buildSkip(gui)

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
	tween(backdrop, 0.25, { BackgroundTransparency = LOOK.RevealBackdrop })
	tween(popScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
	task.delay(FX.HatchStingDelay, function()
		tween(stampPunch, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		fadeIn(stampFades, 0.2)
	end)
	for i, fades in ipairs(lines) do
		task.delay(0.35 + i * 0.12, function()
			fadeIn(fades, 0.25)
		end)
	end
	task.delay(1, function()
		fadeIn(skipFades, 0.4)
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
		local pulse = GLOW_SIZE + math.sin(elapsed * 4) * GLOW_PULSE
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
			viewport.Position = UDim2.new(0.5, math.random(-5, 5), CREATURE_Y, math.random(-3, 3))
			nameLabel.Text = if math.random() < 0.75 then scramble(10) else def.Name
			local staticOn = elapsed < 1 or math.random() < 0.12
			if static then
				static.Visible = staticOn
				if staticOn then
					for _, cell in ipairs(staticCells) do
						cell.BackgroundColor3 = Theme.Mix(C.Shadow, C.Text, math.random())
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
	fadeOut(skipFades, 0.15)
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
			-- The reveal's ScreenGui goes into PlayerGui now, even if the
			-- reveal has to wait for a carry: CodexController holds its
			-- polaroid while a "HatchReveal" is there.
			local gui = UI.new("ScreenGui", {
				Name = "HatchReveal",
				ResetOnSpawn = false,
				IgnoreGuiInset = true,
				DisplayOrder = LAYERS.Reveal,
				ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
				Enabled = false,
				Parent = playerGui,
			}) :: ScreenGui
			-- Hold the reveal while the player carries something home (a thief
			-- or the Brood Mother may be on them); the nest burst already
			-- played, and the reveal opens once they've dropped it off.
			while localPlayer:GetAttribute("Carrying") == true do
				localPlayer:GetAttributeChangedSignal("Carrying"):Wait()
			end
			local data = table.remove(queue, 1) :: Reveal
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
	local color = if bigAmount then themeColor(LOOK.CashPopupBigColor, C.EmberBright) else themeColor(LOOK.CashPopupColor, C.MossBright)
	local size = if bigAmount then LOOK.CashPopupBigSize else LOOK.CashPopupSize

	local attachment = Instance.new("Attachment")
	attachment.Name = "CashPopup"
	attachment.Parent = getPopupAnchor()
	attachment.WorldPosition = position

	local billboard = UI.new("BillboardGui", {
		Name = "Popup",
		Size = UDim2.fromOffset(size.X, size.Y),
		AlwaysOnTop = true,
		LightInfluence = 0,
		MaxDistance = FX.CashPopupMaxDistance,
		Parent = attachment,
	})

	local text = UI.Text({
		Name = "Amount",
		Role = "Heading",
		Text = "+$" .. Config.FormatNumber(amount),
		RichText = false,
		TextScaled = true,
		TextColor3 = color,
		Size = UDim2.fromScale(1, 1),
		Parent = billboard,
	})
	local stroke = UI.Stroke({
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Color = C.Shadow,
		Thickness = 2.5,
		Transparency = 0.1,
		Parent = text,
	})
	local scale = UI.new("UIScale", { Scale = 0.3, Parent = text })

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
	local stampColor = themeColor(LOOK.RebirthStampColor, C.EmberBright)
	SoundController.Play("Rebirth")
	flash(themeColor(LOOK.RebirthFlashColor, C.Text), 0.9)
	confetti(celebrationGui, stampColor)
	shake(FX.ShakeDuration, FX.ShakeStrength * 0.6)

	-- Holder carries the phone scaling; the label inside does the punch
	-- (one UIScale per object).
	local holder = UI.new("Frame", {
		Name = "RebirthStamp",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.38),
		Size = UDim2.fromOffset(REBIRTH_STAMP_SIZE.X, REBIRTH_STAMP_SIZE.Y),
		BackgroundTransparency = 1,
		ZIndex = 41,
		Parent = celebrationGui,
	}) :: Frame
	fixedScale(holder)
	local banner, edge = displayText(string.format("REBIRTH %d!", rebirths), LOOK.RebirthStampTextSize, {
		Name = "Banner",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		TextColor3 = stampColor,
		Rotation = -4,
		ZIndex = 41,
		Parent = holder,
	})
	edge.Thickness = 3
	banner.TextTransparency = 0
	edge.Transparency = 0.1
	local punch = UI.new("UIScale", { Scale = 3, Parent = banner })
	tween(punch, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
	task.delay(LOOK.RebirthStampTime, function()
		tween(banner, 0.4, { TextTransparency = 1 })
		tween(edge, 0.4, { Transparency = 1 })
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

	fxGui = UI.new("ScreenGui", {
		Name = "SAC_ScreenFX",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = LAYERS.Flash,
		Parent = playerGui,
	}) :: ScreenGui
	celebrationGui = UI.new("ScreenGui", {
		Name = "SAC_Celebration",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = LAYERS.Celebration,
		Parent = playerGui,
	}) :: ScreenGui

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
