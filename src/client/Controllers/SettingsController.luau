--!strict
--[[
	SettingsController
	StarterPlayerScripts/Client/Controllers/SettingsController

	The settings screen ("campfire field kit" Window "Settings"), opened from
	the HUD's Settings tile. Two switches (ON looks lit, OFF looks plain):
	  * Music ON/OFF — the background music (SoundController's music group).
	  * Sound effects ON/OFF — every sound effect and the night ambience
	    (SoundController's effects group), plus any other Sound under
	    SoundService.
	The switches show SoundController's current state. For this session
	only for now.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Components = script.Parent.Parent:WaitForChild("Components")
local Theme = require(Components:WaitForChild("Theme"))
local UI = require(Components:WaitForChild("UI"))
local Icon = require(Components:WaitForChild("Icon"))
local Window = require(Components:WaitForChild("Window"))
local SoundController = require(script.Parent:WaitForChild("SoundController"))

local SettingsController = {}

local C = Theme.Colors
local TUNING = Config.UI.Retention.Settings

local window: Window.Window? = nil
local originalVolumes: { [Sound]: number } = {}

type Switch = { button: TextButton, icon: ImageLabel, onIcon: string, offIcon: string }

--- True for sounds SoundController manages (muted through its groups, and
--- their volumes change per play, so they must not be touched here).
local function isManaged(sound: Sound): boolean
	return sound.SoundGroup ~= nil or sound:FindFirstAncestor("SAC_Sounds") ~= nil
		or sound:FindFirstAncestor("SAC_SoundCheck") ~= nil
end

local function applySounds()
	local soundsOn = SoundController.SoundsEnabled()
	SoundController.SetSoundsEnabled(soundsOn)
	-- Anything else living in SoundService (not ours) follows the switch too.
	for _, sound in ipairs(SoundService:GetDescendants()) do
		if sound:IsA("Sound") and not isManaged(sound) then
			if originalVolumes[sound] == nil then
				originalVolumes[sound] = sound.Volume
			end
			sound.Volume = if soundsOn then originalVolumes[sound] else 0
		end
	end
end

local function paintSwitch(switch: Switch, on: boolean)
	UI.SetButtonText(switch.button, if on then "On" else "Off")
	UI.SetButtonVariant(switch.button, if on then TUNING.OnVariant else TUNING.OffVariant)
	Icon.set(switch.icon, if on then switch.onIcon else switch.offIcon)
	switch.icon.ImageColor3 = if on then C.Moon else C.TextFaint
end

--- One settings row: icon, name and a note on the left, the switch on the right.
local function buildRow(parent: Instance, order: number, title: string, note: string, onIcon: string, offIcon: string): Switch
	local row = UI.Card({
		Name = title,
		Size = UDim2.new(1, 0, 0, 66),
		LayoutOrder = order,
		Parent = parent,
	})
	local icon = UI.Icon(onIcon, 32, {
		Name = "Glyph",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 16, 0.5, 0),
		Parent = row,
	})
	UI.Text({
		Name = "Title",
		Role = "Heading",
		Weight = "Bold",
		Text = title,
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(62, 8),
		Size = UDim2.new(1, -190, 0, 28),
		Parent = row,
	})
	UI.Text({
		Name = "Note",
		Role = "Notes",
		Text = note,
		TextSize = 14,
		TextColor3 = C.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(62, 36),
		Size = UDim2.new(1, -190, 0, 20),
		Parent = row,
	})
	local button = UI.Button({
		Name = "Switch",
		Text = "On",
		Variant = TUNING.OnVariant,
		TextSize = 20,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(110, 44),
		Parent = row,
	})
	return { button = button, icon = icon, onIcon = onIcon, offIcon = offIcon }
end

function SettingsController.Open()
	local w = window
	if w then
		w:Open()
	end
end

function SettingsController.SoundsOn(): boolean
	return SoundController.SoundsEnabled()
end

function SettingsController.MusicOn(): boolean
	return SoundController.MusicEnabled()
end

function SettingsController.Start()
	local w = Window.new({
		Name = "Settings",
		Title = "Settings",
		Icon = "Settings",
		Size = TUNING.WindowSize,
	})
	window = w

	local list = UI.new("Frame", {
		Name = "Rows",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = w.Body,
	}, {
		UI.List({ Padding = 10 }),
	})

	local music = buildRow(list, 1, "Music", "The campfire tunes.", "Music", "MusicOff")
	local sounds = buildRow(list, 2, "Sound effects", "Clicks, coins, night woods.", "Sound", "SoundOff")
	UI.Text({
		Name = "Footnote",
		Role = "Notes",
		Text = "Settings last for this visit.",
		TextSize = 14,
		TextColor3 = C.TextFaint,
		Size = UDim2.new(1, 0, 0, 20),
		LayoutOrder = 3,
		Parent = list,
	})

	music.button.Activated:Connect(function()
		SoundController.SetMusicEnabled(not SoundController.MusicEnabled())
		paintSwitch(music, SoundController.MusicEnabled())
	end)
	sounds.button.Activated:Connect(function()
		SoundController.SetSoundsEnabled(not SoundController.SoundsEnabled())
		applySounds()
		paintSwitch(sounds, SoundController.SoundsEnabled())
	end)

	-- Show the real state every time the screen opens.
	local function paintAll()
		paintSwitch(music, SoundController.MusicEnabled())
		paintSwitch(sounds, SoundController.SoundsEnabled())
	end
	w.OnOpen = paintAll
	paintAll()

	-- Sounds added later (e.g. the steal alarm) follow the setting too.
	SoundService.DescendantAdded:Connect(function(d)
		if d:IsA("Sound") then
			task.defer(applySounds)
		end
	end)
end

return SettingsController
