--!strict
--[[
	EggBeltController
	StarterPlayerScripts/Client/Controllers/EggBeltController

	Draws the egg belt moving. The server places each belt egg once and
	stores its spawn time; this slides our own view of every egg and slat
	along Shared/BeltPath each frame, so the motion is perfectly smooth and
	costs no network traffic. The server checks purchases against the same
	path maths.

	Also:
	  * a sparkle puff from the burrow as an egg climbs out or sinks in
	  * Buy prompts only show while an egg is riding, while your hands are
	    free, and for eggs you've unlocked; locked eggs say which rebirth
	    unlocks them
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local BeltPath = require(Shared:WaitForChild("BeltPath"))

local ProfileController = require(script.Parent:WaitForChild("ProfileController"))

local EggBeltController = {}

local localPlayer = Players.LocalPlayer

local SPIN_SPEED = 0.6 -- radians per second, purely for looks
local LOCKED_COLOR = Color3.fromRGB(170, 170, 170)

type EggView = {
	model: Model,
	spawnTime: number,
	eggId: string,
	phase: string,
	prompt: ProximityPrompt?,
	price: TextLabel?,
}

local views: { [Model]: EggView } = {}
local slats: { [BasePart]: number } = {}
local burrows: { [string]: BasePart } = {}

local function puff(which: string)
	local hole = burrows[which]
	local emitter = hole and hole:FindFirstChild("Puff")
	if emitter and emitter:IsA("ParticleEmitter") then
		emitter:Emit(14)
	end
end

local function rebirths(): number
	local snapshot = ProfileController.Get()
	return snapshot and tonumber(snapshot.Rebirths) or 0
end

--- Prompt visibility and the price line, for this player.
local function refreshView(view: EggView)
	local def = Config.Eggs[view.eggId]
	if not def then
		return
	end
	local locked = rebirths() < def.RequiredRebirths
	if view.price then
		if locked then
			view.price.Text = string.format("Rebirth %d", def.RequiredRebirths)
			view.price.TextColor3 = LOCKED_COLOR
		else
			view.price.Text = "$" .. Config.FormatNumber(def.Price)
			view.price.TextColor3 = Color3.fromRGB(120, 255, 140)
		end
	end
	if view.prompt then
		view.prompt.Enabled = view.phase == "Riding" and not locked and localPlayer:GetAttribute("Carrying") ~= true
	end
end

local function track(model: Instance)
	if not model:IsA("Model") or views[model] then
		return
	end
	local spawnTime = model:GetAttribute("SpawnTime")
	local eggId = model:GetAttribute("EggId")
	if typeof(spawnTime) ~= "number" or typeof(eggId) ~= "string" then
		return
	end
	local shell = model.PrimaryPart
	local label = shell and shell:FindFirstChild("Label")
	local view: EggView = {
		model = model,
		spawnTime = spawnTime,
		eggId = eggId,
		phase = BeltPath.Phase(Workspace:GetServerTimeNow() - spawnTime),
		prompt = shell and shell:FindFirstChild("BuyPrompt") :: ProximityPrompt?,
		price = label and label:FindFirstChild("Price") :: TextLabel?,
	}
	views[model] = view
	if view.phase == "Rising" then
		puff("Start")
	end
	refreshView(view)
end

local function trackSlat(part: Instance)
	local index = part:GetAttribute("Index")
	if part:IsA("BasePart") and typeof(index) == "number" then
		slats[part] = index
	end
end

local function trackBurrow(part: Instance)
	local which = part:GetAttribute("Which")
	if part:IsA("BasePart") and typeof(which) == "string" then
		burrows[which] = part
	end
end

local function step()
	local now = Workspace:GetServerTimeNow()

	-- Slats, in one bulk move.
	local parts: { BasePart } = {}
	local frames: { CFrame } = {}
	for part, index in pairs(slats) do
		if part.Parent then
			table.insert(parts, part)
			table.insert(frames, BeltPath.SlatCFrame(index, now))
		else
			slats[part] = nil
		end
	end
	if #parts > 0 then
		Workspace:BulkMoveTo(parts, frames, Enum.BulkMoveMode.FireCFrameChanged)
	end

	-- Eggs.
	for model, view in pairs(views) do
		if not model.Parent then
			views[model] = nil
			continue
		end
		local age = now - view.spawnTime
		local phase = BeltPath.Phase(age)
		if phase ~= view.phase then
			view.phase = phase
			if phase == "Sinking" then
				puff("End")
			end
			refreshView(view)
		end
		model:PivotTo(BeltPath.EggCFrame(math.min(age, BeltPath.Lifetime())) * CFrame.Angles(0, age * SPIN_SPEED, 0))
	end
end

function EggBeltController.Start()
	for _, model in ipairs(CollectionService:GetTagged(Config.Tags.BeltEgg)) do
		track(model)
	end
	CollectionService:GetInstanceAddedSignal(Config.Tags.BeltEgg):Connect(function(model)
		task.defer(track, model) -- let the egg's parts arrive first
	end)
	CollectionService:GetInstanceRemovedSignal(Config.Tags.BeltEgg):Connect(function(model)
		views[model :: Model] = nil
	end)

	for _, part in ipairs(CollectionService:GetTagged(Config.Tags.BeltSlat)) do
		trackSlat(part)
	end
	CollectionService:GetInstanceAddedSignal(Config.Tags.BeltSlat):Connect(trackSlat)

	for _, part in ipairs(CollectionService:GetTagged(Config.Tags.Burrow)) do
		trackBurrow(part)
	end
	CollectionService:GetInstanceAddedSignal(Config.Tags.Burrow):Connect(trackBurrow)

	local function refreshAll()
		for _, view in pairs(views) do
			refreshView(view)
		end
	end
	ProfileController.Changed:Connect(refreshAll)
	localPlayer:GetAttributeChangedSignal("Carrying"):Connect(refreshAll)

	RunService.RenderStepped:Connect(step)
end

return EggBeltController
