--!strict
--[[
	NestVisualsController
	StarterPlayerScripts/Client/Controllers/NestVisualsController

	Client-side dressing for eggs and creatures sitting in nests, driven
	entirely by the model attributes NestService and IncomeService set:

	  * Labels are sized in STUDS (BillboardGui Size in scale), so they
	    shrink with distance instead of crowding a phone screen, sit just
	    above the model's real height (generated meshes vary in size), and
	    hide beyond Config.Feedback.NestLabelMaxDistance.
	      Eggs:      name + heat bar ("MAX" when full). Everyone sees it —
	                 a hot egg is a target, which is the point.
	      Creatures: name in its rarity colour + "$X/s". On YOUR creatures
	                 only, a vault bar with "$X" ("FULL" pulses).
	    Eggs glow brighter as they heat up.
	  * Prompts: owner sees Hatch; others see Steal unless the camp is
	    locked/protected or they're carrying (display only; the server
	    re-checks everything).
	  * Secret creatures flicker and never show a clear name or body.
	  * Life: creatures near the camera breathe and slowly look around
	    (each on its own rhythm); eggs at high heat wobble; Legendary+ get a
	    faint aura of sparks in their rarity colour. Motion is client-only:
	    the server never moves nest models after placing them, and the
	    exact base pivot is restored when a model goes out of range.

	Works with StreamingEnabled: models arrive/leave via CollectionService,
	and a model that streams out and back in keeps its true base pivot.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local NestVisualsController = {}

local FX = Config.Feedback
local localPlayer = Players.LocalPlayer

local WHITE = Color3.new(1, 1, 1)
local BAR_BACK = Color3.fromRGB(20, 20, 26)
local HEAT_COLOR = Color3.fromRGB(255, 140, 60)
local VAULT_COLOR = Color3.fromRGB(110, 220, 120)
local VAULT_FULL_COLOR = Color3.fromRGB(255, 170, 60)
local INCOME_COLOR = Color3.fromRGB(150, 255, 160)

-- Secret creatures currently on this client -> their name label, for the
-- flicker loop.
local secrets: { [Model]: TextLabel } = {}

--------------------------------------------------------------------------
-- Label building (sizes are in studs: scale units on a BillboardGui)
--------------------------------------------------------------------------

--- A stud-sized billboard just above the top of `model`.
local function makeBillboard(model: Model, adornee: BasePart, size: Vector2): (BillboardGui, Frame)
	local boxCf, boxSize = model:GetBoundingBox()
	local top = boxCf.Position.Y + boxSize.Y / 2
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Info"
	billboard.Size = UDim2.fromScale(size.X, size.Y)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, top - adornee.Position.Y + FX.NestLabelGap + size.Y / 2, 0)
	billboard.MaxDistance = FX.NestLabelMaxDistance
	billboard.LightInfluence = 0
	billboard.Adornee = adornee
	billboard.Parent = adornee

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundTransparency = 1
	frame.Parent = billboard
	local layout = Instance.new("UIListLayout")
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0.03, 0)
	layout.Parent = frame
	return billboard, frame
end

--- A text row taking `height` (0..1) of the label.
local function textLine(parent: Instance, order: number, height: number): TextLabel
	local l = Instance.new("TextLabel")
	l.LayoutOrder = order
	l.Size = UDim2.fromScale(1, height)
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamBold
	l.TextScaled = true
	l.TextColor3 = WHITE
	l.TextStrokeTransparency = 0.35
	l.Parent = parent
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = FX.NestLabelMaxTextSize
	limit.Parent = l
	return l
end

--- A rounded bar taking `height` of the label, with a text label on top.
local function bar(parent: Instance, order: number, height: number, color: Color3): (Frame, TextLabel)
	local back = Instance.new("Frame")
	back.LayoutOrder = order
	back.Size = UDim2.fromScale(0.85, height)
	back.BackgroundColor3 = BAR_BACK
	back.BackgroundTransparency = 0.2
	back.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = back
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = color
	fill.Parent = back
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0.5, 0)
	fillCorner.Parent = fill
	local text = Instance.new("TextLabel")
	text.Name = "Text"
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.GothamBlack
	text.TextScaled = true
	text.TextColor3 = WHITE
	text.TextStrokeTransparency = 0.3
	text.ZIndex = 2
	text.Parent = back
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = FX.NestLabelMaxTextSize
	limit.Parent = text
	return fill, text
end

local function isMine(model: Instance): boolean
	return model:GetAttribute("OwnerUserId") == localPlayer.UserId
end

--- Waits briefly for a nest model's primary part (models stream in whole,
--- but be safe).
local function primaryOf(model: Model, name: string): BasePart?
	local primary = model.PrimaryPart
	if primary then
		return primary
	end
	local found = model:WaitForChild(name, 5)
	return if found and found:IsA("BasePart") then found else nil
end

--------------------------------------------------------------------------
-- Life: idle motion (client only)
--------------------------------------------------------------------------

type Life = {
	model: Model,
	base: CFrame,
	isEgg: boolean,
	phase: number,
	phase2: number,
	moved: boolean,
}

local lives: { [Model]: Life } = {}
-- The server-placed pivot of every nest model we've seen. Weak keys: an
-- entry goes away with its model. Kept across stream-out/in so a model
-- that comes back while still offset is put back exactly.
local basePivots: { [Model]: CFrame } = setmetatable({}, { __mode = "k" }) :: any

local function addLife(model: Model, isEgg: boolean)
	if model:GetAttribute("NestIndex") == nil then
		return -- only items sitting in a nest; anything else may be moved by other code
	end
	local base = basePivots[model]
	if not base then
		base = model:GetPivot()
		basePivots[model] = base
	end
	lives[model] = {
		model = model,
		base = base,
		isEgg = isEgg,
		phase = math.random() * math.pi * 2,
		phase2 = math.random() * math.pi * 2,
		moved = false,
	}
end

local function removeLife(model: Instance)
	local life = lives[model :: Model]
	if life then
		lives[model :: Model] = nil
		if life.moved and model.Parent then
			(model :: Model):PivotTo(life.base)
		end
	end
end

local function stepLife()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local cameraPos = camera.CFrame.Position
	local t = os.clock()
	for model, life in pairs(lives) do
		if not model.Parent then
			lives[model] = nil
			continue
		end
		local offset: CFrame? = nil
		if (life.base.Position - cameraPos).Magnitude <= FX.IdleMaxDistance then
			if life.isEgg then
				local heat = tonumber(model:GetAttribute("Heat")) or 0
				if heat >= FX.EggWobbleHeat then
					-- Wobbles in little fits, harder the hotter it is.
					local k = math.clamp((heat - FX.EggWobbleHeat) / math.max(1, Config.Heat.Max - FX.EggWobbleHeat), 0, 1)
					local amplitude = math.rad(FX.EggWobbleDegrees) * (0.4 + 0.6 * k)
					local fit = math.max(0, math.sin(t * 1.7 + life.phase)) ^ 4
					local angle = amplitude * fit * math.sin(t * FX.EggWobbleSpeed)
					offset = CFrame.Angles(angle, 0, angle * 0.6)
				end
			else
				local bob = (math.sin(t * FX.IdleBobSpeed + life.phase) + 1) * 0.5 * FX.IdleBobHeight
				local yaw = math.rad(FX.IdleYawDegrees) * math.sin(t * FX.IdleYawSpeed + life.phase2)
				offset = CFrame.new(0, bob, 0) * CFrame.Angles(0, yaw, 0)
			end
		end
		if offset then
			model:PivotTo(life.base * offset)
			life.moved = true
		elseif life.moved then
			model:PivotTo(life.base)
			life.moved = false
		end
	end
end

--- Faint sparks around a Legendary+ creature.
local function addAura(body: BasePart, color: Color3)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Aura"
	emitter.Color = ColorSequence.new(color, color:Lerp(WHITE, 0.5))
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.28),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(1.2, 2)
	emitter.Speed = NumberRange.new(0.3, 1)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, 1.2, 0)
	emitter.Rate = FX.AuraRate
	emitter.Parent = body
	local light = Instance.new("PointLight")
	light.Name = "AuraLight"
	light.Color = color
	light.Brightness = 0.8
	light.Range = 8
	light.Shadows = false
	light.Parent = body
end

--------------------------------------------------------------------------
-- Eggs
--------------------------------------------------------------------------

local function setupEgg(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	local model = instance :: Model
	local shell = primaryOf(model, "Shell")
	if not shell then
		return
	end
	if shell:FindFirstChild("Info") then
		addLife(model, true) -- already dressed (seen twice): just keep it moving
		return
	end
	local egg = Config.Eggs[model:GetAttribute("EggId") or ""]
	if not egg then
		return
	end

	local size: Vector2 = FX.EggLabelSize
	local _, frame = makeBillboard(model, shell, size)
	local name = textLine(frame, 1, 0.5)
	name.Text = egg.Name
	name.TextColor3 = egg.Color:Lerp(WHITE, 0.5)
	local heatFill, heatText = bar(frame, 2, 0.42, HEAT_COLOR)
	local glow = shell:FindFirstChild("HeatGlow") :: PointLight?

	local function render()
		local heat = tonumber(model:GetAttribute("Heat")) or 0
		local fraction = math.clamp(heat / Config.Heat.Max, 0, 1)
		heatText.Text = if fraction >= 1 then "MAX" else string.format("%d%%", math.floor(heat))
		heatFill.Size = UDim2.fromScale(fraction, 1)
		heatFill.BackgroundColor3 = Color3.fromRGB(255, 200, 90):Lerp(Color3.fromRGB(255, 70, 30), fraction)
		if glow then
			glow.Brightness = fraction * 2.5
			glow.Range = 6 + fraction * 8
		end
	end
	render()
	model:GetAttributeChangedSignal("Heat"):Connect(render)

	addLife(model, true)
end

--------------------------------------------------------------------------
-- Prompts on nest items
-- Owner sees Hatch (eggs). Everyone else sees Steal — unless the camp is
-- locked or spawn-protected, or they're already carrying something. This
-- is only about what's shown; the server re-checks every rule.
--------------------------------------------------------------------------

local function plotModel(index: any): Instance?
	local map = Workspace:FindFirstChild("Map")
	local plots = map and map:FindFirstChild("Plots")
	return plots and plots:FindFirstChild("Plot_" .. tostring(index))
end

local function updateItemPrompts(model: Instance)
	local mine = isMine(model)
	local plot = plotModel(model:GetAttribute("PlotIndex"))
	local now = Workspace:GetServerTimeNow()
	local locked = plot ~= nil and (plot:GetAttribute("LockedUntil") or 0) > now
	local protected = plot ~= nil and (plot:GetAttribute("ProtectedUntil") or 0) > now
	local carrying = localPlayer:GetAttribute("Carrying") == true
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("ProximityPrompt") then
			if d.Name == "HatchPrompt" then
				d.Enabled = mine
			elseif d.Name == "StealPrompt" then
				d.Enabled = not mine and not locked and not protected and not carrying
			end
		end
	end
end

local function updateAllItemPrompts()
	for _, tag in ipairs({ Config.Tags.Egg, Config.Tags.Creature }) do
		for _, model in ipairs(CollectionService:GetTagged(tag)) do
			updateItemPrompts(model)
		end
	end
end

--------------------------------------------------------------------------
-- Creatures
--------------------------------------------------------------------------

local GLYPHS = { "#", "%", "&", "?", "!", "/", "\\", "_", "~", "*" }

local function scramble(length: number): string
	local out = table.create(length)
	for i = 1, length do
		out[i] = GLYPHS[math.random(1, #GLYPHS)]
	end
	return table.concat(out)
end

local function setupCreature(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	local model = instance :: Model
	local body = primaryOf(model, "Body")
	if not body then
		return
	end
	local creatureId = model:GetAttribute("CreatureId")
	local def = if typeof(creatureId) == "string" then Config.CreaturesById[creatureId] else nil
	if not def then
		return
	end
	local rarity = Config.Rarities[def.Rarity]
	local secret = rarity.NeverRenderClearly == true
	local existing = body:FindFirstChild("Info")
	if existing then
		-- Already dressed (seen twice): just keep it moving and flickering.
		addLife(model, false)
		local frame = existing:FindFirstChildOfClass("Frame")
		local nameLabel = frame and frame:FindFirstChildOfClass("TextLabel")
		if secret and nameLabel then
			secrets[model] = nameLabel
		end
		return
	end
	local mine = isMine(model)

	local size: Vector2 = if mine then FX.CreatureLabelOwnSize else FX.CreatureLabelSize
	local _, frame = makeBillboard(model, body, size)

	-- Rows as fractions of the label height.
	local nameHeight = if mine then 0.36 else 0.55
	local incomeHeight = if mine then 0.28 else 0.4
	local name = textLine(frame, 1, nameHeight)
	name.Text = def.Name -- Secret's label is scrambled by flickerSecrets()
	name.TextColor3 = if secret then FX.SecretAccent else rarity.Color
	local incomeLine = textLine(frame, 2, incomeHeight)
	incomeLine.TextColor3 = INCOME_COLOR

	local vaultFill: Frame? = nil
	local vaultText: TextLabel? = nil
	if mine then
		local fill, text = bar(frame, 3, 0.28, VAULT_COLOR)
		vaultFill = fill
		vaultText = text
	end
	local pulse: Tween? = nil

	local function render()
		local income = tonumber(model:GetAttribute("IncomePerSecond")) or rarity.IncomePerSecond
		incomeLine.Text = "$" .. Config.FormatNumber(income) .. "/s"
		if vaultFill and vaultText then
			local vault = tonumber(model:GetAttribute("Vault")) or 0
			local cap = tonumber(model:GetAttribute("VaultCap")) or 1
			local fraction = if cap > 0 then math.clamp(vault / cap, 0, 1) else 0
			local full = fraction >= 1
			vaultFill.Size = UDim2.fromScale(fraction, 1)
			vaultText.Text = if full then "FULL" else "$" .. Config.FormatNumber(vault)
			if full and not pulse then
				vaultFill.BackgroundColor3 = VAULT_FULL_COLOR
				local tween = TweenService:Create(vaultFill,
					TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
					{ BackgroundTransparency = 0.6 })
				tween:Play()
				pulse = tween
			elseif not full and pulse then
				pulse:Cancel()
				pulse = nil
				vaultFill.BackgroundTransparency = 0
				vaultFill.BackgroundColor3 = VAULT_COLOR
			end
		end
	end
	render()
	for _, attr in ipairs({ "Vault", "VaultCap", "IncomePerSecond" }) do
		model:GetAttributeChangedSignal(attr):Connect(render)
	end

	if secret then
		secrets[model] = name
	end
	if rarity.Index >= FX.BigRarityIndex then
		addAura(body, if secret then FX.SecretAccent else rarity.Color)
	end
	addLife(model, false)
end

-- Parts each Secret flickers (cached; "Eye" parts stay steady).
local secretParts: { [Model]: { BasePart } } = setmetatable({}, { __mode = "k" }) :: any

local function flickerSecrets()
	for model, nameLabel in pairs(secrets) do
		if not model.Parent then
			secrets[model] = nil
			continue
		end
		local parts = secretParts[model]
		if not parts then
			local list: { BasePart } = {}
			for _, d in ipairs(model:GetDescendants()) do
				if d:IsA("BasePart") and d.Name ~= "Eye" then
					table.insert(list, d)
				end
			end
			secretParts[model] = list
			parts = list
		end
		for _, part in ipairs(parts :: { BasePart }) do
			part.Transparency = math.random() * 0.6
			part.Color = Color3.fromHSV(0, 0, math.random() * 0.25)
		end
		nameLabel.Text = if math.random() < 0.7 then scramble(10) else "[REDACTED]"
	end
end

--------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------

function NestVisualsController.Start()
	for _, model in ipairs(CollectionService:GetTagged(Config.Tags.Egg)) do
		task.spawn(setupEgg, model)
	end
	CollectionService:GetInstanceAddedSignal(Config.Tags.Egg):Connect(setupEgg)
	CollectionService:GetInstanceRemovedSignal(Config.Tags.Egg):Connect(removeLife)

	for _, model in ipairs(CollectionService:GetTagged(Config.Tags.Creature)) do
		task.spawn(setupCreature, model)
	end
	CollectionService:GetInstanceAddedSignal(Config.Tags.Creature):Connect(setupCreature)
	CollectionService:GetInstanceRemovedSignal(Config.Tags.Creature):Connect(function(model)
		removeLife(model)
		secrets[model :: Model] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(0.12)
			if next(secrets) then
				flickerSecrets()
			end
		end
	end)

	RunService.RenderStepped:Connect(stepLife)

	-- Prompt visibility depends on locks, protection and carrying, which all
	-- change over time, so re-evaluate a few times a second.
	CollectionService:GetInstanceAddedSignal(Config.Tags.Egg):Connect(updateItemPrompts)
	CollectionService:GetInstanceAddedSignal(Config.Tags.Creature):Connect(updateItemPrompts)
	task.spawn(function()
		while true do
			updateAllItemPrompts()
			task.wait(0.3)
		end
	end)
end

return NestVisualsController
