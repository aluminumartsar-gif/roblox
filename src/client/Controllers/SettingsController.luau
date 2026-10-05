--!strict
--[[
	SettingsController
	StarterPlayerScripts/Client/Controllers/SettingsController

	The settings screen, on the STUD kit's Settings popup.
	  * Sounds ON/OFF — mutes this player's UI sounds (button clicks, the
	    steal alarm). For this session only for now; saving settings to the
	    profile is a Step 8 polish item.
	  * Music — hidden until the game has music.
]]

local SoundService = game:GetService("SoundService")

local Kit = require(script.Parent.Parent:WaitForChild("Components"):WaitForChild("Kit"))

local SettingsController = {}

local popup: Kit.Popup
local soundsOn = true
local originalVolumes: { [Sound]: number } = {}

local function applySounds()
	for _, sound in ipairs(SoundService:GetDescendants()) do
		if sound:IsA("Sound") then
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
			if label == "Music" then
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
