--!strict
--[[
	PlotController
	StarterPlayerScripts/Client/Controllers/PlotController

	Client-side plot presentation:
	  * Doors. The server keeps every door open; this draws and collides a
	    door locally while its plot is locked — except your own, which you
	    see faintly and walk through. (The server ejects intruders by
	    position, so this is presentation, not security.)
	  * Lock prompts. Only your own plot's lock button shows a prompt.
	  * Plot panel: Lock button with countdown, and nests used.

	Works with StreamingEnabled: plots arrive and leave via CollectionService
	signals, and the panel reads Player attributes, which always replicate.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local ProfileController = require(script.Parent:WaitForChild("ProfileController"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))

local PlotController = {}

local localPlayer = Players.LocalPlayer

type DoorState = { locked: boolean, mine: boolean }
local doorStates: { [BasePart]: DoorState } = {}

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function formatClock(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function isMine(plot: Instance): boolean
	return plot:GetAttribute("OwnerUserId") == localPlayer.UserId
end

--------------------------------------------------------------------------
-- Doors and prompts
--------------------------------------------------------------------------

local function updateDoor(door: BasePart)
	local plot = door.Parent
	if not plot or not CollectionService:HasTag(plot, Config.Tags.Plot) then
		return
	end
	local lockedUntil = plot:GetAttribute("LockedUntil")
	local locked = typeof(lockedUntil) == "number" and now() < lockedUntil
	local mine = isMine(plot)

	local previous = doorStates[door]
	if previous and previous.locked == locked and previous.mine == mine then
		return
	end
	doorStates[door] = { locked = locked, mine = mine }

	if locked then
		door.Transparency = if mine then 0.8 else 0.25
		door.CanCollide = not mine
	else
		door.Transparency = 1
		door.CanCollide = false
	end
end

local function setPromptVisibility(prompt: ProximityPrompt, plot: Instance)
	prompt.Enabled = isMine(plot)
end

local function updatePrompts(plot: Instance)
	for _, descendant in ipairs(plot:GetDescendants()) do
		if descendant:IsA("ProximityPrompt") and descendant.Name == "LockPrompt" then
			setPromptVisibility(descendant, plot)
		end
	end
end

local function trackPlot(plot: Instance)
	updatePrompts(plot)
	plot:GetAttributeChangedSignal("OwnerUserId"):Connect(function()
		updatePrompts(plot)
		local door = plot:FindFirstChild("Door")
		if door and door:IsA("BasePart") then
			doorStates[door] = nil
			updateDoor(door)
		end
	end)
	-- Prompts can stream in after the model itself.
	plot.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("ProximityPrompt") and descendant.Name == "LockPrompt" then
			setPromptVisibility(descendant, plot)
		end
	end)
end

--------------------------------------------------------------------------
-- Plot panel
--------------------------------------------------------------------------

local function buildPanel(): (TextButton, TextLabel)
	local gui = Instance.new("ScreenGui")
	gui.Name = "PlotPanel"
	gui.ResetOnSpawn = false

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.AnchorPoint = Vector2.new(0, 0.5)
	frame.Position = UDim2.new(0, 12, 0.45, 0)
	frame.Size = UDim2.fromOffset(170, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
	frame.BackgroundTransparency = 0.25
	frame.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 8)
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = frame
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = frame

	local nests = Instance.new("TextLabel")
	nests.Name = "Nests"
	nests.LayoutOrder = 1
	nests.Size = UDim2.new(1, 0, 0, 22)
	nests.BackgroundTransparency = 1
	nests.Font = Enum.Font.GothamBold
	nests.TextSize = 16
	nests.TextColor3 = Color3.fromRGB(255, 236, 200)
	nests.TextXAlignment = Enum.TextXAlignment.Left
	nests.Text = "Nests -/-"
	nests.Parent = frame

	local button = Instance.new("TextButton")
	button.Name = "Lock"
	button.LayoutOrder = 2
	button.Size = UDim2.new(1, 0, 0, 44) -- tall enough for a thumb
	button.Font = Enum.Font.GothamBold
	button.TextSize = 16
	button.TextColor3 = Color3.new(1, 1, 1)
	button.AutoButtonColor = true
	button.Text = "LOCK CAMP"
	button.Parent = frame
	local buttonCorner = Instance.new("UICorner")
	buttonCorner.CornerRadius = UDim.new(0, 8)
	buttonCorner.Parent = button

	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	return button, nests
end

local LOCK_READY = Color3.fromRGB(46, 140, 80)
local LOCK_ACTIVE = Color3.fromRGB(50, 100, 170)
local LOCK_COOLDOWN = Color3.fromRGB(70, 72, 80)

local function renderLockButton(button: TextButton)
	if not localPlayer:GetAttribute("PlotIndex") then
		button.Text = "NO CAMP"
		button.BackgroundColor3 = LOCK_COOLDOWN
		return
	end
	local t = now()
	local lockedUntil = localPlayer:GetAttribute("PlotLockedUntil") or 0
	local cooldownUntil = localPlayer:GetAttribute("PlotLockCooldownUntil") or 0
	if lockedUntil > t then
		button.Text = "LOCKED " .. formatClock(lockedUntil - t)
		button.BackgroundColor3 = LOCK_ACTIVE
	elseif cooldownUntil > t then
		button.Text = "RECHARGE " .. formatClock(cooldownUntil - t)
		button.BackgroundColor3 = LOCK_COOLDOWN
	else
		button.Text = "LOCK CAMP"
		button.BackgroundColor3 = LOCK_READY
	end
end

local function renderNests(label: TextLabel, snapshot: { [string]: any }?)
	if not snapshot or typeof(snapshot.Nests) ~= "table" or typeof(snapshot.Upgrades) ~= "table" then
		return
	end
	local used = 0
	for _, slot in ipairs(snapshot.Nests) do
		if slot ~= false then
			used += 1
		end
	end
	local capacity = Config.GetUpgradeValue("NestSlots", snapshot.Upgrades.NestSlots or 1)
	label.Text = string.format("Nests %d/%d", used, capacity)
end

--------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------

function PlotController.Start()
	for _, plot in ipairs(CollectionService:GetTagged(Config.Tags.Plot)) do
		trackPlot(plot)
	end
	CollectionService:GetInstanceAddedSignal(Config.Tags.Plot):Connect(trackPlot)

	CollectionService:GetInstanceRemovedSignal(Config.Tags.Door):Connect(function(door)
		doorStates[door :: BasePart] = nil
	end)

	local lockButton, nestsLabel = buildPanel()
	local lockRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("LockPlot") :: RemoteFunction
	local busy = false
	lockButton.Activated:Connect(function()
		if busy then
			return
		end
		busy = true
		local ok, result = pcall(function()
			return lockRemote:InvokeServer()
		end)
		busy = false
		if ok and typeof(result) == "table" then
			NotificationController.Show(tostring(result.Message or ""), if result.Ok then "Success" else "Error")
		else
			NotificationController.Show("Couldn't reach the server.", "Error")
		end
	end)

	ProfileController.Changed:Connect(function(snapshot)
		renderNests(nestsLabel, snapshot)
	end)
	renderNests(nestsLabel, ProfileController.Get())

	-- Doors and the countdown both depend on the clock, so tick them.
	task.spawn(function()
		while true do
			for _, door in ipairs(CollectionService:GetTagged(Config.Tags.Door)) do
				if door:IsA("BasePart") then
					updateDoor(door)
				end
			end
			renderLockButton(lockButton)
			task.wait(0.2)
		end
	end)
end

return PlotController
