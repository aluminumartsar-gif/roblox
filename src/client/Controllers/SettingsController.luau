--!strict
--[[
	SettingsController
	StarterPlayerScripts/Client/Controllers/SettingsController

	The settings screen, on the STUD kit's Settings popup.
	  * Sounds ON/OFF — every sound effect and the night ambience
	    (SoundController's effects group), plus any other Sound under
	    SoundService.
	  * Music ON/OFF — the background music (SoundController's music group).
	For this session only for now.
]]

local SoundService = game:GetService("SoundService")

local Kit = require(script.Parent.Parent:WaitForChild("Components"):WaitForChild("Kit"))
local SoundController = require(script.Parent:WaitForChild("SoundController"))

local SettingsController = {}

local popup: Kit.Popup
local soundsOn = true
local musicOn = true
local originalVolumes: { [Sound]: number } = {}

--- True for sounds SoundController manages (muted through its groups, and
--- their volumes change per play, so they must not be touched here).
local function isManaged(sound: Sound): boolean
	return sound.SoundGroup ~= nil or sound:FindFirstAncestor("SAC_Sounds") ~= nil
		or sound:FindFirstAncestor("SAC_SoundCheck") ~= nil
end

local function applySounds()
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

function SettingsController.Open()
	popup:Open()
end

function SettingsController.SoundsOn(): boolean
	return soundsOn
end

function SettingsController.MusicOn(): boolean
	return musicOn
end

function SettingsController.Start()
	local gui = Kit.Mount("Settings")
	popup = Kit.Popup(gui)

	local list = Kit.Deep(gui.Container, "ScrollingFrame")
	Kit.FitCanvas(list)
	for _, item in ipairs(list:GetChildren()) do
		if item.Name == "Item" then
			local title = item:FindFirstChild("Title")
			local button = item:FindFirstChild("Button")
			local label = title and title:IsA("TextLabel") and title.Text or ""
			if label == "Music" and button and button:IsA("GuiButton") then
				Kit.SetButtonText(button, "ON")
				button.Activated:Connect(function()
					musicOn = not musicOn
					Kit.SetButtonText(button, if musicOn then "ON" else "OFF")
					Kit.SetButtonEnabled(button, musicOn)
					SoundController.SetMusicEnabled(musicOn)
				end)
			elseif label == "Music" then
				item.Visible = false
			elseif label == "Sounds" and button and button:IsA("GuiButton") then
				Kit.SetButtonText(button, "ON")
				button.Activated:Connect(function()
					soundsOn = not soundsOn
					Kit.SetButtonText(button, if soundsOn then "ON" else "OFF")
					Kit.SetButtonEnabled(button, soundsOn)
					applySounds()
				end)
			end
		end
	end

	-- Sounds added later (e.g. the steal alarm) follow the setting too.
	SoundService.DescendantAdded:Connect(function(d)
		if d:IsA("Sound") then
			task.defer(applySounds)
		end
	end)
end

return SettingsController
