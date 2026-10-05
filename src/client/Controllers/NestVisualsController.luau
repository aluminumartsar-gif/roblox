--!strict
--[[
	NestVisualsController
	StarterPlayerScripts/Client/Controllers/NestVisualsController

	Client-side dressing for eggs and creatures sitting in nests, driven
	entirely by the model attributes NestService and IncomeService set:

	  * Eggs: floating label with a heat bar (everyone sees it — a hot egg
	    is a target, which is the point), a glow that brightens with heat,
	    and the Hatch prompt shown only to the owner.
	  * Creatures: floating label with name, rarity colour, income per
	    second and a vault bar. Secret creatures flicker and never show a
	    clear name or body.

	Works with StreamingEnabled: models arrive/leave via CollectionService.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local NestVisualsController = {}

local localPlayer = Players.LocalPlayer

-- Secret creatures currently on this client, for the flicker loop.
local secrets: { [Model]: boolean } = {}

local function makeBillboard(adornee: BasePart, height: number): (BillboardGui, Frame)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Info"
	billboard.Size = UDim2.fromOffset(170, 58)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, height, 0)
	billboard.MaxDistance = 90
	billboard.LightInfluence = 0
	billboard.Adornee = adornee
	billboard.Parent = adornee

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundTransparency = 1
	frame.Parent = billboard
	local layout = Instance.new("UIListLayout")
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = frame
	return billboard, frame
end

local function textLine(parent: Instance, order: number, size: number): TextLabel
	local l = Instance.new("TextLabel")
	l.LayoutOrder = order
	l.Size = UDim2.new(1, 0, 0, size)
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamBold
	l.TextScaled = true
	l.TextColor3 = Color3.new(1, 1, 1)
	l.TextStrokeTransparency = 0.35
	l.Parent = parent
	return l
end

local function bar(parent: Instance, order: number, color: Color3): Frame
	local back = Instance.new("Frame")
	back.LayoutOrder = order
	back.Size = UDim2.new(0.8, 0, 0, 8)
	back.BackgroundColor3 = Color3.fromRGB(20, 20, 26)
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
	return fill
end

local function isMine(model: Instance): boolean
	return model:GetAttribute("OwnerUserId") == localPlayer.UserId
end

--------------------------------------------------------------------------
-- Eggs
--------------------------------------------------------------------------

local function setupEgg(model: Instance)
	if not model:IsA("Model") then
		return
	end
	local shell = model.PrimaryPart or model:WaitForChild("Shell", 5) :: BasePart?
	if not shell then
		return
	end
	local egg = Config.Eggs[model:GetAttribute("EggId") or ""]
	if not egg then
		return
	end

	local _, frame = makeBillboard(shell, shell.Size.Y / 2 + 2.2)
	local name = textLine(frame, 1, 20)
	name.Text = egg.Name
	name.TextColor3 = egg.Color:Lerp(Color3.new(1, 1, 1), 0.5)
	local heatText = textLine(frame, 2, 18)
	local heatFill = bar(frame, 3, Color3.fromRGB(255, 140, 60))
	local glow = shell:FindFirstChild("HeatGlow") :: PointLight?

	local function render()
		local heat = tonumber(model:GetAttribute("Heat")) or 0
		local fraction = math.clamp(heat / Config.Heat.Max, 0, 1)
		heatText.Text = if fraction >= 1 then "MAX HEAT" else string.format("Heat %d%%", math.floor(heat))
		heatText.TextColor3 = Color3.fromRGB(255, 220, 160):Lerp(Color3.fromRGB(255, 90, 40), fraction)
		heatFill.Size = UDim2.fromScale(fraction, 1)
		if glow then
			glow.Brightness = fraction * 2.5
			glow.Range = 6 + fraction * 8
		end
	end
	render()
	model:GetAttributeChangedSignal("Heat"):Connect(render)
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

local function setupCreature(model: Instance)
	if not model:IsA("Model") then
		return
	end
	local body = model.PrimaryPart or model:WaitForChild("Body", 5) :: BasePart?
	if not body then
		return
	end
	local def = Config.CreaturesById[model:GetAttribute("CreatureId") or ""]
	if not def then
		return
	end
	local rarity = Config.Rarities[def.Rarity]
	local secret = rarity.NeverRenderClearly == true

	local headroom = body.Size.Y / 2 + math.min(body.Size.X, body.Size.Z) * 0.7 + 1.8
	local billboard, frame = makeBillboard(body, headroom)
	billboard.Size = UDim2.fromOffset(180, 76)

	local name = textLine(frame, 1, 20)
	name.Text = def.Name -- Secret's label is scrambled by flickerSecrets()
	name.TextColor3 = if secret then Color3.fromRGB(230, 230, 230) else rarity.Color
	local rarityLine = textLine(frame, 2, 15)
	rarityLine.Text = string.upper(rarity.DisplayName)
	rarityLine.TextColor3 = if secret then Color3.fromRGB(255, 60, 60) else rarity.Color
	local incomeLine = textLine(frame, 3, 17)
	incomeLine.TextColor3 = Color3.fromRGB(150, 255, 160)
	local vaultFill = bar(frame, 4, Color3.fromRGB(110, 220, 120))
	local vaultLine = textLine(frame, 5, 14)
	vaultLine.TextColor3 = Color3.fromRGB(220, 220, 220)

	local function render()
		local income = tonumber(model:GetAttribute("IncomePerSecond")) or rarity.IncomePerSecond
		local vault = tonumber(model:GetAttribute("Vault")) or 0
		local cap = tonumber(model:GetAttribute("VaultCap")) or 1
		incomeLine.Text = "$" .. Config.FormatNumber(income) .. "/s"
		local fraction = if cap > 0 then math.clamp(vault / cap, 0, 1) else 0
		vaultFill.Size = UDim2.fromScale(fraction, 1)
		vaultFill.BackgroundColor3 = if fraction >= 1 then Color3.fromRGB(255, 170, 60) else Color3.fromRGB(110, 220, 120)
		local vaultText = "$" .. Config.FormatNumber(vault) .. " / $" .. Config.FormatNumber(cap)
		if fraction >= 1 and isMine(model) then
			vaultText ..= "  FULL — collect!"
		end
		vaultLine.Text = vaultText
	end
	render()
	for _, attr in ipairs({ "Vault", "VaultCap", "IncomePerSecond" }) do
		model:GetAttributeChangedSignal(attr):Connect(render)
	end

	if secret then
		secrets[model] = true
		model.AncestryChanged:Connect(function(_, parent)
			if not parent then
				secrets[model] = nil
			end
		end)
	end
end

local function flickerSecrets()
	for model in pairs(secrets) do
		if not model.Parent then
			secrets[model] = nil
			continue
		end
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and d.Name ~= "Eye" then
				d.Transparency = math.random() * 0.6
				d.Color = Color3.fromHSV(0, 0, math.random() * 0.25)
			end
		end
		local body = model.PrimaryPart
		local info = body and body:FindFirstChild("Info")
		local frame = info and info:FindFirstChildOfClass("Frame")
		local nameLabel = frame and frame:FindFirstChildOfClass("TextLabel")
		if nameLabel then
			nameLabel.Text = if math.random() < 0.7 then scramble(10) else "[REDACTED]"
		end
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

	for _, model in ipairs(CollectionService:GetTagged(Config.Tags.Creature)) do
		task.spawn(setupCreature, model)
	end
	CollectionService:GetInstanceAddedSignal(Config.Tags.Creature):Connect(setupCreature)

	task.spawn(function()
		while true do
			task.wait(0.12)
			if next(secrets) then
				flickerSecrets()
			end
		end
	end)

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
