--!strict
--[[
	NestVisualsController
	StarterPlayerScripts/Client/Controllers/NestVisualsController

	Client-side dressing for eggs and creatures sitting in nests, driven
	entirely by the model attributes NestService and IncomeService set:

	  * Labels are sized in STUDS (BillboardGui Size in scale), so they
	    shrink with distance instead of crowding a phone screen, sit just
	    above the model's real height (generated meshes vary in size), and
	    hide beyond Config.Feedback.NestLabelMaxDistance. They use the
	    campfire field kit look (Components/Theme, UI): Oswald text with a
	    dark outline, bars in a sunken well like the screens' progress bars.
	      Eggs:      name + an ember countdown bar to hatching. Everyone sees
	                 it — an egg that's nearly done is a target, which is the
	                 point. In the last stretch (Config.Incubation.
	                 AlmostReadyFraction) the bar brightens, its edge glows
	                 and pulses, and it reads "HATCHING m:ss".
	      Creatures: name in its rarity colour (Secret: SecretText, scrambled)
	                 + "$X/s" in moss green. On YOUR creatures only, a moss
	                 vault bar with "$X" ("FULL" turns ember and pulses).
	    Eggs glow brighter as they get closer to hatching, and in the last
	    stretch they throw a light pillar into the sky that the whole map
	    can see.
	  * Prompts: owners see Sell on their cryptids (with the price); others
	    see Steal on eggs unless the camp is locked/protected or they're
	    carrying (display only; the server re-checks everything).
	  * Secret creatures flicker and never show a clear name or body.
	  * Life: creatures near the camera breathe and slowly look around
	    (each on its own rhythm); eggs about to hatch wobble; Legendary+ get a
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

local Components = script.Parent.Parent:WaitForChild("Components")
local Theme = require(Components:WaitForChild("Theme"))
local UI = require(Components:WaitForChild("UI"))

local NestVisualsController = {}

local FX = Config.Feedback
local L = Config.UI.Labels
local C = Theme.Colors
local localPlayer = Players.LocalPlayer

local WHITE = Color3.new(1, 1, 1) -- maths only: aura sparks fade toward white
-- World light / pillar colours for an incubating egg and one about to hatch.
local HATCH_GLOW = C.EmberBright
local ALMOST_GLOW = C.BloodBright

-- Label layout, as fractions of the label (not designer tunables: the label
-- sizes themselves are Config.Feedback.*LabelSize).
local ROW_GAP = 0.03
local BAR_WIDTH = 0.85
local BAR_FADE = 0.7 -- an egg bar's glowing edge pulses down to this transparency
local VAULT_FADE = 0.6 -- a full vault's fill pulses down to this transparency

--- The shading UI.ProgressBar gives its fill (light top, deep bottom).
local function fillSequence(color: Color3): ColorSequence
	return Theme.Sequence(color:Lerp(WHITE, 0.35), color:Lerp(C.Shadow, 0.35), color)
end

-- Built once: bars swap between these when their state changes, so the
-- per-second redraws never allocate a new sequence.
local EGG_FILL = fillSequence(C.Ember)
local EGG_ALMOST_FILL = fillSequence(C.EmberBright)
local VAULT_FILL = fillSequence(C.Moss)
local VAULT_FULL_FILL = fillSequence(C.Ember)

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

	local frame = UI.new("Frame", {
		Name = "Rows",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = billboard,
	})
	UI.List({
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Bottom,
		Padding = UDim.new(ROW_GAP, 0),
		Parent = frame,
	})
	return billboard, frame
end

--- Caps scaled text so a label isn't enormous right next to you.
local function capText(label: TextLabel)
	UI.new("UITextSizeConstraint", { MaxTextSize = FX.NestLabelMaxTextSize, Parent = label })
end

--- A text row taking `height` (0..1) of the label: Oswald with a dark
--- outline so it reads against the night woods.
local function textLine(parent: Instance, name: string, order: number, height: number, weight: string): TextLabel
	local l = UI.Text({
		Name = name,
		Role = "Heading",
		Weight = weight,
		LayoutOrder = order,
		Size = UDim2.fromScale(1, height),
		TextScaled = true,
		RichText = false, -- Secret names scramble into symbols like "&"
		TextStrokeColor3 = C.Shadow,
		TextStrokeTransparency = L.TextStroke,
		Parent = parent,
	})
	capText(l)
	return l
end

type Bar = {
	frame: Frame,
	fill: Frame,
	gradient: UIGradient?,
	text: TextLabel,
	edge: UIStroke?, -- the well's border; an egg about to hatch makes it glow
}

--- A progress bar (UI.ProgressBar: sunken well, shaded fill, centred
--- caption) taking `height` of the label.
local function bar(parent: Instance, order: number, height: number, sequence: ColorSequence): Bar
	local frame = UI.ProgressBar({
		LayoutOrder = order,
		Size = UDim2.fromScale(BAR_WIDTH, height),
		Text = "",
		Parent = parent,
	}) :: Frame
	local fill = frame:FindFirstChild("Fill") :: Frame
	local gradient = fill:FindFirstChildOfClass("UIGradient")
	if gradient then
		gradient.Color = sequence
	end
	local text = frame:FindFirstChild("Label") :: TextLabel
	text.TextScaled = true
	text.RichText = false
	capText(text)
	return {
		frame = frame,
		fill = fill,
		gradient = gradient,
		text = text,
		edge = frame:FindFirstChildOfClass("UIStroke"),
	}
end

--- Starts a looping fade on `instance` (the caller cancels it).
local function pulse(instance: Instance, seconds: number, goal: { [string]: any }): Tween
	local tween = TweenService:Create(instance,
		TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), goal)
	tween:Play()
	return tween
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
				local progress = tonumber(model:GetAttribute("Progress")) or 0
				if progress >= FX.EggWobbleProgress then
					-- Wobbles in little fits, harder the closer it is to hatching.
					local k = math.clamp((progress - FX.EggWobbleProgress) / math.max(0.01, 1 - FX.EggWobbleProgress), 0, 1)
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
	local name = textLine(frame, "Title", 1, 0.5, "Bold")
	name.Text = egg.Name
	name.TextColor3 = egg.Color:Lerp(C.Text, 0.5)
	local hatch = bar(frame, 2, 0.42, EGG_FILL)
	local edge = hatch.edge
	-- The well's own border, put back when an egg stops being "almost".
	local edgeColor = if edge then edge.Color else C.Edge
	local edgeThickness = if edge then edge.Thickness else 1
	local edgeTransparency = if edge then edge.Transparency else 0
	local glow = shell:FindFirstChild("HatchGlow") :: PointLight?
	local pillar: BasePart? = nil
	local edgePulse: Tween? = nil
	local wasAlmost: boolean? = nil

	-- The last stretch: a light pillar into the night sky over the egg, so
	-- everyone on the map knows something good is about to hatch here.
	local function setPillar(on: boolean)
		if on and not pillar then
			local p = Instance.new("Part")
			p.Name = "AlmostPillar"
			p.Shape = Enum.PartType.Cylinder
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			p.CastShadow = false
			p.Material = Enum.Material.Neon
			p.Color = egg.Color:Lerp(ALMOST_GLOW, 0.5)
			p.Transparency = 0.7
			local height = 70
			p.Size = Vector3.new(height, 1.6, 1.6)
			p.CFrame = CFrame.new(shell.Position + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2)
			-- Outside the model so the egg's wobble doesn't swing it; it goes
			-- when the egg does (hatched, stolen, streamed out).
			p.Parent = Workspace
			pillar = p
		elseif not on and pillar then
			pillar:Destroy()
			pillar = nil
		end
	end

	-- Only on a change of state: brighter fill, a pulsing ember edge on the
	-- bar, and the pillar.
	local function setAlmost(almost: boolean)
		if almost == wasAlmost then
			return
		end
		wasAlmost = almost
		if hatch.gradient then
			hatch.gradient.Color = if almost then EGG_ALMOST_FILL else EGG_FILL
		end
		if edgePulse then
			edgePulse:Cancel()
			edgePulse = nil
		end
		if edge then
			if almost then
				edge.Color = C.EmberBright
				edge.Thickness = L.BarGlowThickness
				edge.Transparency = 0
				edgePulse = pulse(edge, L.EggAlmostPulseTime, { Transparency = BAR_FADE })
			else
				edge.Color = edgeColor
				edge.Thickness = edgeThickness
				edge.Transparency = edgeTransparency
			end
		end
		setPillar(almost)
	end

	local function render()
		if not model:IsDescendantOf(game) then
			return -- streamed out / gone: never leave a pillar behind (redrawn on return)
		end
		local progress = math.clamp(tonumber(model:GetAttribute("Progress")) or 0, 0, 1)
		local remaining = math.max(0, math.floor(tonumber(model:GetAttribute("Remaining")) or 0))
		local almost = progress >= Config.Incubation.AlmostReadyFraction
		local clock = string.format("%d:%02d", remaining // 60, remaining % 60)
		hatch.text.Text = if almost then "HATCHING " .. clock else clock
		UI.SetProgress(hatch.frame, progress)
		if glow then
			glow.Brightness = progress * 2.5
			glow.Range = 6 + progress * 8
			glow.Color = if almost then ALMOST_GLOW else HATCH_GLOW
		end
		setAlmost(almost)
	end
	render()
	model:GetAttributeChangedSignal("Progress"):Connect(render)
	model:GetAttributeChangedSignal("Remaining"):Connect(render)

	-- Hatched, stolen or streamed out: the pillar lives outside the model,
	-- and the pulse would keep running on a dead label. Forget the state so
	-- a model that streams back in gets its pillar and glow again.
	model.AncestryChanged:Connect(function()
		if model:IsDescendantOf(game) then
			render()
			return
		end
		if edgePulse then
			edgePulse:Cancel()
			edgePulse = nil
		end
		if pillar then
			pillar:Destroy()
			pillar = nil
		end
		wasAlmost = nil
	end)

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
			if d.Name == "SellPrompt" then
				d.Enabled = mine
				if mine then
					-- Vault plus RefundSeconds of income, as NestService pays it.
					local vault = tonumber(model:GetAttribute("Vault")) or 0
					local income = tonumber(model:GetAttribute("IncomePerSecond")) or 0
					d.ActionText = "Sell $" .. Config.FormatNumber(math.floor(vault + income * Config.Sell.RefundSeconds))
				end
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
		local rows = existing:FindFirstChild("Rows")
		local nameLabel = rows and rows:FindFirstChild("Title")
		if secret and nameLabel and nameLabel:IsA("TextLabel") then
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
	local name = textLine(frame, "Title", 1, nameHeight, "Bold")
	name.Text = def.Name -- Secret's label is scrambled by flickerSecrets()
	name.TextColor3 = Theme.RarityColor(def.Rarity) -- Secret: SecretText, readable at night
	local incomeLine = textLine(frame, "Income", 2, incomeHeight, "SemiBold")
	incomeLine.TextColor3 = C.MossBright

	local vault: Bar? = if mine then bar(frame, 3, 0.28, VAULT_FILL) else nil
	local fullPulse: Tween? = nil
	local wasFull: boolean? = nil

	local function render()
		if not model:IsDescendantOf(game) then
			return -- streamed out / sold: redrawn if it comes back
		end
		local income = tonumber(model:GetAttribute("IncomePerSecond")) or rarity.IncomePerSecond
		incomeLine.Text = "$" .. Config.FormatNumber(income) .. "/s"
		if vault then
			local amount = tonumber(model:GetAttribute("Vault")) or 0
			local cap = tonumber(model:GetAttribute("VaultCap")) or 1
			local fraction = if cap > 0 then math.clamp(amount / cap, 0, 1) else 0
			local full = fraction >= 1
			UI.SetProgress(vault.frame, fraction)
			vault.text.Text = if full then "FULL" else "$" .. Config.FormatNumber(amount)
			if full ~= wasFull then
				wasFull = full
				if vault.gradient then
					vault.gradient.Color = if full then VAULT_FULL_FILL else VAULT_FILL
				end
				if fullPulse then
					fullPulse:Cancel()
					fullPulse = nil
				end
				vault.fill.BackgroundTransparency = 0
				if full then
					fullPulse = pulse(vault.fill, L.VaultFullPulseTime, { BackgroundTransparency = VAULT_FADE })
				end
			end
		end
	end
	render()
	for _, attr in ipairs({ "Vault", "VaultCap", "IncomePerSecond" }) do
		model:GetAttributeChangedSignal(attr):Connect(render)
	end
	if vault then
		-- Sold or streamed out: stop the pulse; redraw if it streams back in.
		model.AncestryChanged:Connect(function()
			if model:IsDescendantOf(game) then
				render()
				return
			end
			if fullPulse then
				fullPulse:Cancel()
				fullPulse = nil
			end
			wasFull = nil
		end)
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
