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
	  * Camp panel (ScreenGui "PlotPanel", frame "Panel"): one row, top left,
	    Config.UI.Layout.TopGap under Roblox's top bar and CampHeight tall
	    (the HUD's side tiles start below it). Shows the spawn-protection
	    timer while it runs, nests used / capacity, and the Lock button:
	    LOCK CAMP (ember) -> LOCKED m:ss (moonlight) -> RECHARGE m:ss
	    (greyed). Pressing it always asks the server, which answers with a
	    toast (locked, or why not); NO CAMP while you have no plot.
	    Built on Components/UI, scaled with the screen.

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
local Components = script.Parent.Parent:WaitForChild("Components")
local Theme = require(Components:WaitForChild("Theme"))
local UI = require(Components:WaitForChild("UI"))
local Icon = require(Components:WaitForChild("Icon"))

local PlotController = {}

local localPlayer = Players.LocalPlayer

local C = Theme.Colors
local layout = Config.UI.Layout
local tuning = Config.UI.Hud

-- Space between the camp panel's edge and the Lock button (px).
local CAMP_PADDING = 4

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

--- A text label with an icon on its left, for the camp panel row.
local function campLabel(frame: Frame, name: string, order: number, iconName: string, color: Color3, text: string): TextLabel
	local label = UI.Text({
		Name = name,
		Role = "Heading",
		Weight = "Bold",
		Text = text,
		TextSize = tuning.CampTextSize,
		TextColor3 = color,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.fromOffset(0, tuning.CampIconSize + 2),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = order,
		Parent = frame,
	})
	local icon = Icon.addLeft(label, iconName, tuning.CampIconSize, 0)
	icon.ImageColor3 = color
	return label
end

local function buildPanel(): (TextButton, TextLabel, TextLabel)
	local gui = UI.new("ScreenGui", {
		Name = "PlotPanel",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = Config.UI.Layers.Hud,
	}) :: ScreenGui

	-- One compact row, top left under Roblox's top bar (this ScreenGui
	-- keeps the inset) and above the HUD's side tiles.
	local frame = UI.Panel({
		Name = "Panel",
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(0, layout.CampHeight),
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = gui,
	})
	UI.Padding({ Top = CAMP_PADDING, Bottom = CAMP_PADDING, Left = 10, Right = CAMP_PADDING }).Parent = frame
	UI.List({
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = 12,
	}).Parent = frame
	-- Scales with the screen; the margins (px at the reference height) scale too.
	local scale = UI.Scale(frame)
	local function place()
		frame.Position = UDim2.fromOffset(layout.EdgeMargin * scale.Scale, layout.TopGap * scale.Scale)
	end
	scale:GetPropertyChangedSignal("Scale"):Connect(place)
	place()

	local protection = campLabel(frame, "Protection", 0, "Shield", C.Moon, "")
	protection.Visible = false
	local nests = campLabel(frame, "Nests", 1, "Egg", C.Text, "Nests -/-")
	local button = UI.Button({
		Name = "Lock",
		Variant = "Primary",
		Icon = "Lock",
		IconSize = tuning.CampIconSize,
		Text = "Lock camp",
		TextSize = tuning.CampTextSize,
		Size = UDim2.fromOffset(tuning.LockWidth, layout.CampHeight - 2 * CAMP_PADDING), -- tall enough for a thumb
		LayoutOrder = 2,
		Parent = frame,
	})

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

-- The Lock button's look: "Ready" (ember, the main action), "Locked"
-- (moonlight, counting down), "Recharge" and "NoCamp" (greyed out; a press
-- still asks the server, which explains the refusal).
local lockState: string? = nil

local function renderLockButton(button: TextButton)
	local state: string, text: string
	if not localPlayer:GetAttribute("PlotIndex") then
		state, text = "NoCamp", "NO CAMP"
	else
		local t = now()
		local lockedUntil = localPlayer:GetAttribute("PlotLockedUntil") or 0
		local cooldownUntil = localPlayer:GetAttribute("PlotLockCooldownUntil") or 0
		if lockedUntil > t then
			state, text = "Locked", "LOCKED " .. formatClock(lockedUntil - t)
		elseif cooldownUntil > t then
			state, text = "Recharge", "RECHARGE " .. formatClock(cooldownUntil - t)
		else
			state, text = "Ready", "LOCK CAMP"
		end
	end
	UI.SetButtonText(button, text)
	-- Repaint only on a change, so a hover highlight isn't wiped every tick.
	if state ~= lockState then
		lockState = state
		UI.SetButtonVariant(button, if state == "Locked" then "Moon" else "Primary")
		UI.SetButtonEnabled(button, state == "Ready" or state == "Locked")
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
			task.wait(tuning.CampTickInterval)
		end
	end)
end

return PlotController
