--!strict
--[[
	StealController
	StarterPlayerScripts/Client/Controllers/StealController

	The client side of stealing:

	  * Owner alarm. The server's StealAlarm remote drives a red banner (with
	    the thief's name), an alarm sound, and a red outline on the item —
	    first on the nest item being stolen, then on the item while it's
	    carried or dropped, visible through walls so the owner can chase it.
	  * Carrier banner. While you carry something: what it is, and how long
	    until it runs home.
	  * Dropped items: the owner's prompt reads "Take back"; hidden for anyone
	    already carrying something.

	Display only — every rule is enforced on the server.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Icon = require(script.Parent.Parent:WaitForChild("Components"):WaitForChild("Icon"))

local StealController = {}

local localPlayer = Players.LocalPlayer

local ALARM_SOUND = "rbxasset://sounds/electronicpingshort.wav"
local OUTLINE = Color3.fromRGB(255, 50, 50)

local alarmBanner: TextLabel
local carryBanner: TextLabel
local alarmSound: Sound

type AlarmState = { Phase: string, Info: { [string]: any }, Until: number? }
local alarmState: AlarmState? = nil
local watchedNestIndex: number? = nil

local function formatClock(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function banner(parent: Instance, name: string, position: UDim2, color: Color3): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = position
	label.Size = UDim2.new(0.92, 0, 0, 46)
	label.BackgroundColor3 = color
	label.BackgroundTransparency = 0.08
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Visible = false
	label.Parent = parent
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(620, 46)
	constraint.Parent = label
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = label
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 12)
	padding.PaddingRight = UDim.new(0, 12)
	padding.PaddingTop = UDim.new(0, 6)
	padding.PaddingBottom = UDim.new(0, 6)
	padding.Parent = label
	return label
end

local function setOutline(model: Instance, on: boolean)
	local existing = model:FindFirstChild("StealOutline")
	if on and not existing then
		local highlight = Instance.new("Highlight")
		highlight.Name = "StealOutline"
		highlight.FillTransparency = 0.8
		highlight.FillColor = OUTLINE
		highlight.OutlineColor = OUTLINE
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		highlight.Parent = model
	elseif not on and existing then
		existing:Destroy()
	end
end

local function myNestItem(nestIndex: number?): Instance?
	if not nestIndex then
		return nil
	end
	local runtime = Workspace:FindFirstChild("Runtime")
	if not runtime then
		return nil
	end
	for _, model in ipairs(runtime:GetChildren()) do
		if model:GetAttribute("OwnerUserId") == localPlayer.UserId
			and model:GetAttribute("NestIndex") == nestIndex
			and not CollectionService:HasTag(model, Config.Tags.CarriedItem) then
			return model
		end
	end
	return nil
end

local function playAlarm(times: number)
	task.spawn(function()
		for _ = 1, times do
			alarmSound:Play()
			task.wait(0.25)
		end
	end)
end

--------------------------------------------------------------------------
-- Owner alarm
--------------------------------------------------------------------------

local function onAlarm(phase: string, info: { [string]: any })
	local thief = tostring(info.Thief or "Someone")
	local item = tostring(info.Item or "cryptid")

	-- Outline on the nest item only while a hold is in progress.
	if watchedNestIndex then
		local previous = myNestItem(watchedNestIndex)
		if previous then
			setOutline(previous, false)
		end
		watchedNestIndex = nil
	end

	if phase == "Started" then
		watchedNestIndex = tonumber(info.NestIndex)
		local target = myNestItem(watchedNestIndex)
		if target then
			setOutline(target, true)
		end
		alarmState = { Phase = phase, Info = info, Until = os.clock() + 6 }
		playAlarm(3)
	elseif phase == "Stopped" then
		if alarmState and alarmState.Phase == "Started" then
			alarmState = nil
		end
	elseif phase == "Stolen" or phase == "Dropped" then
		alarmState = { Phase = phase, Info = info, Until = nil }
		playAlarm(if phase == "Stolen" then 4 else 2)
	elseif phase == "Claimed" or phase == "Returned" then
		alarmState = { Phase = phase, Info = info, Until = os.clock() + 4 }
	end

	if alarmState then
		alarmState.Info.Thief = thief
		alarmState.Info.Item = item
	end
end

local function renderAlarm()
	local state = alarmState
	if not state then
		alarmBanner.Visible = false
		return
	end
	if state.Until and os.clock() > state.Until then
		alarmState = nil
		alarmBanner.Visible = false
		return
	end

	local info = state.Info
	local remaining = (tonumber(info.ReturnAt) or 0) - Workspace:GetServerTimeNow()
	local text
	local color = Color3.fromRGB(190, 30, 40)
	if state.Phase == "Started" then
		text = string.format("%s is stealing your %s!", info.Thief, info.Item)
	elseif state.Phase == "Stolen" then
		text = string.format("%s grabbed your %s! Bat them! (home in %s)", info.Thief, info.Item, formatClock(remaining))
	elseif state.Phase == "Dropped" then
		text = string.format("Your %s is on the ground — grab it back! (%s)", info.Item, formatClock(remaining))
		color = Color3.fromRGB(190, 120, 20)
	elseif state.Phase == "Claimed" then
		text = string.format("%s got away with your %s.", info.Thief, info.Item)
		color = Color3.fromRGB(90, 30, 40)
	else -- Returned
		text = string.format("Your %s is home safe.", info.Item)
		color = Color3.fromRGB(40, 120, 70)
	end
	if (state.Phase == "Stolen" or state.Phase == "Dropped") and remaining <= 0 then
		alarmState = nil
		alarmBanner.Visible = false
		return
	end
	alarmBanner.Text = text
	alarmBanner.BackgroundColor3 = color
	alarmBanner.Visible = true
end

--------------------------------------------------------------------------
-- Carried / dropped items
--------------------------------------------------------------------------

local function updateCarried(model: Instance)
	local mine = model:GetAttribute("OwnerUserId") == localPlayer.UserId
	setOutline(model, mine)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == "PickupPrompt" then
			d.ActionText = if mine then "Take back" else "Pick up"
			d.Enabled = mine or localPlayer:GetAttribute("Carrying") ~= true
		end
	end
end

local function myCarriedModel(): Instance?
	for _, model in ipairs(CollectionService:GetTagged(Config.Tags.CarriedItem)) do
		if model:GetAttribute("CarrierUserId") == localPlayer.UserId and not model:GetAttribute("Dropped") then
			return model
		end
	end
	return nil
end

local function renderCarrying()
	if localPlayer:GetAttribute("Carrying") ~= true then
		carryBanner.Visible = false
		return
	end
	local model = myCarriedModel()
	local label = model and model:GetAttribute("ItemLabel") or "stolen item"
	local remaining = model and ((model:GetAttribute("ReturnAt") or 0) - Workspace:GetServerTimeNow()) or 0
	carryBanner.Text = string.format("Carrying %s — run to your camp's pad! (%s)", tostring(label), formatClock(remaining))
	carryBanner.Visible = true
end

--------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------

function StealController.Start()
	local gui = Instance.new("ScreenGui")
	gui.Name = "StealUI"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 8
	alarmBanner = banner(gui, "Alarm", UDim2.new(0.5, 0, 0.22, 0), Color3.fromRGB(190, 30, 40))
	carryBanner = banner(gui, "Carrying", UDim2.new(0.5, 0, 1, -150), Color3.fromRGB(150, 90, 20))
	Icon.addLeft(alarmBanner, "Warning", 32)
	Icon.addLeft(carryBanner, "Grab", 32)
	gui.Parent = localPlayer:WaitForChild("PlayerGui")

	alarmSound = Instance.new("Sound")
	alarmSound.Name = "StealAlarm"
	alarmSound.SoundId = ALARM_SOUND
	alarmSound.Volume = 0.8
	alarmSound.Parent = SoundService

	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("StealAlarm") :: RemoteEvent
	remote.OnClientEvent:Connect(function(phase, info)
		if typeof(phase) == "string" and typeof(info) == "table" then
			onAlarm(phase, info)
		end
	end)

	for _, model in ipairs(CollectionService:GetTagged(Config.Tags.CarriedItem)) do
		updateCarried(model)
	end
	CollectionService:GetInstanceAddedSignal(Config.Tags.CarriedItem):Connect(function(model)
		task.defer(updateCarried, model) -- let descendants arrive first
	end)

	task.spawn(function()
		while true do
			renderAlarm()
			renderCarrying()
			for _, model in ipairs(CollectionService:GetTagged(Config.Tags.CarriedItem)) do
				updateCarried(model)
			end
			task.wait(0.2)
		end
	end)
end

return StealController
