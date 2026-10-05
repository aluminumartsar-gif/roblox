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
local SoundController = require(script.Parent:WaitForChild("SoundController"))
local Icon = require(script.Parent.Parent:WaitForChild("Components"):WaitForChild("Icon"))
local ScreenScale = require(script.Parent.Parent:WaitForChild("Components"):WaitForChild("ScreenScale"))

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

	-- Someone else's door clunking shut/open nearby. (Your own lock plays
	-- in the plot panel's tick; the first sighting of a door is silent.)
	if previous and previous.locked ~= locked and not mine then
		SoundController.PlayAt(if locked then "LockOn" else "LockOff", door)
	end

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

local function buildPanel(): (TextButton, TextLabel, TextLabel)
	local gui = Instance.new("ScreenGui")
	gui.Name = "PlotPanel"
	gui.ResetOnSpawn = false

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	-- One compact row, top-left under the Roblox top bar and above the kit
	-- HUD's side buttons (a column didn't fit there on phones).
	frame.AnchorPoint = Vector2.new(0, 0)
	frame.Position = UDim2.new(0.01, 0, 0.015, 0)
	frame.Size = UDim2.fromOffset(0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.XY
	frame.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
	frame.BackgroundTransparency = 0.25
	frame.Parent = gui
	ScreenScale.Apply(frame)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 6)
	padding.PaddingBottom = UDim.new(0, 6)
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 6)
	padding.Parent = frame
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 12)
	layout.Parent = frame

	local nests = Instance.new("TextLabel")
	nests.Name = "Nests"
	nests.LayoutOrder = 1
	nests.Size = UDim2.fromOffset(0, 22)
	nests.AutomaticSize = Enum.AutomaticSize.X
	nests.BackgroundTransparency = 1
	nests.Font = Enum.Font.GothamBold
	nests.TextSize = 18
	nests.TextColor3 = Color3.fromRGB(255, 236, 200)
	nests.TextXAlignment = Enum.TextXAlignment.Left
	nests.Text = "Nests -/-"
	nests.Parent = frame
	Icon.addLeft(nests, "Egg", 20, 0)

	local button = Instance.new("TextButton")
	button.Name = "Lock"
	button.LayoutOrder = 2
	button.Size = UDim2.fromOffset(170, 44) -- tall enough for a thumb
	button.Font = Enum.Font.GothamBold
	button.TextSize = 16
	button.TextColor3 = Color3.new(1, 1, 1)
	button.AutoButtonColor = true
	button.Text = "LOCK CAMP"
	button.Parent = frame
	Icon.addLeft(button, "Lock", 28)
	local buttonCorner = Instance.new("UICorner")
	buttonCorner.CornerRadius = UDim.new(0, 8)
	buttonCorner.Parent = button

	local protection = Instance.new("TextLabel")
	protection.Name = "Protection"
	protection.LayoutOrder = 0
	protection.Size = UDim2.fromOffset(0, 20)
	protection.AutomaticSize = Enum.AutomaticSize.X
	protection.BackgroundTransparency = 1
	protection.Font = Enum.Font.GothamBold
	protection.TextSize = 16
	protection.TextColor3 = Color3.fromRGB(140, 210, 255)
	protection.TextXAlignment = Enum.TextXAlignment.Left
	protection.Visible = false
	protection.Parent = frame
	Icon.addLeft(protection, "Shield", 18, 0)

	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	return button, nests, protection
end

local function renderProtection(label: TextLabel)
	local remaining = (localPlayer:GetAttribute("ProtectedUntil") or 0) - now()
	label.Visible = remaining > 0
	if remaining > 0 then
		label.Text = "Protected " .. formatClock(remaining)
	end
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
	-- Capacity comes from the server (it includes passes); fall back to the
	-- upgrade value until the attribute arrives.
	local capacity = localPlayer:GetAttribute("NestCapacity")
		or Config.GetUpgradeValue("NestSlots", snapshot.Upgrades.NestSlots or 1)
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

	local lockButton, nestsLabel, protectionLabel = buildPanel()
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
	-- Your own camp's lock sound plays on the switch (from any lock source:
	-- button, stump prompt, Emergency Lock).
	local wasLocked: boolean? = nil
	task.spawn(function()
		while true do
			for _, door in ipairs(CollectionService:GetTagged(Config.Tags.Door)) do
				if door:IsA("BasePart") then
					updateDoor(door)
				end
			end
			local lockedNow = (localPlayer:GetAttribute("PlotLockedUntil") or 0) > now()
			if wasLocked ~= nil and lockedNow ~= wasLocked then
				SoundController.Play(if lockedNow then "LockOn" else "LockOff")
			end
			wasLocked = lockedNow
			renderLockButton(lockButton)
			renderProtection(protectionLabel)
			task.wait(0.2)
		end
	end)
end

return PlotController
