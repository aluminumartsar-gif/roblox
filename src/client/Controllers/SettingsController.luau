-- Wires the pack Settings ScreenGui to SettingsService.
-- The two Item slots in the Container map to Music and SFX enabled toggles.
-- Volume is preserved in SettingsService; toggle turns the group fully on/off.

local Players = game:GetService("Players")

local Services = script.Parent.Parent:WaitForChild("Services")
local UIKit    = script.Parent.Parent:WaitForChild("UIKit")

local SettingsService = require(Services:WaitForChild("SettingsService"))
local Screen          = require(UIKit:WaitForChild("Screen"))
local GuiResolve      = require(UIKit:WaitForChild("GuiResolve"))

local SettingsController = {}

local ON_COLOR  = Color3.fromRGB(80, 220, 120)
local OFF_COLOR = Color3.fromRGB(220, 80, 80)

local function refreshItem(item: Frame, label: string, enabled: boolean)
	local title = item:FindFirstChild("Title")
	local btn   = item:FindFirstChild("Button")
	if title then
		title.Text = label .. ": " .. if enabled then "ON" else "OFF"
	end
	if btn then
		btn.BackgroundColor3 = if enabled then ON_COLOR else OFF_COLOR
	end
end

function SettingsController.start()
	SettingsService.start()

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local screen    = playerGui:WaitForChild("Settings")
	local container = GuiResolve.waitChild(screen, "Container")
	if not container or not container:IsA("GuiObject") then return end
	local bg        = GuiResolve.waitChild(container, "Background")
	if not bg then return end
	local sideButtons = playerGui:WaitForChild("HUD"):WaitForChild("SideButtons")
	local openBtn = GuiResolve.sideToggleOpenButton(sideButtons, "SettingsBtn")
	if not openBtn then return end
	local navBar    = GuiResolve.waitChild(bg, "NavBar")
	local closeBtn  = navBar and navBar:FindFirstChild("CloseBtn") :: GuiButton

	Screen.bind({
		guiName    = "Settings",
		screen     = screen,
		container  = container,
		openButton = openBtn,
		closeButton = closeBtn,
	})

	local content     = GuiResolve.waitChild(bg, "Content")
	local scrollFrame = content and GuiResolve.waitChild(content, "ScrollingFrame")
	if not scrollFrame then return end
	local items: { Frame } = {}
	for _, child in scrollFrame:GetChildren() do
		if child:IsA("Frame") and child.Name == "Item" then
			table.insert(items, child)
		end
	end
	table.sort(items, function(a: Frame, b: Frame)
		return a.LayoutOrder < b.LayoutOrder
	end)

	local musicItem = items[1]
	local sfxItem   = items[2]

	local function refreshAll()
		local snap = SettingsService.getSnapshot()
		if musicItem then refreshItem(musicItem, "Music", snap.musicEnabled) end
		if sfxItem   then refreshItem(sfxItem,   "SFX",   snap.sfxEnabled)   end
	end

	if musicItem then
		local btn = musicItem:FindFirstChild("Button") :: GuiButton?
		if btn then
			btn.Activated:Connect(function()
				SettingsService.setMusicEnabled(not SettingsService.isMusicEnabled())
				refreshAll()
			end)
		end
	end

	if sfxItem then
		local btn = sfxItem:FindFirstChild("Button") :: GuiButton?
		if btn then
			btn.Activated:Connect(function()
				SettingsService.setSfxEnabled(not SettingsService.isSfxEnabled())
				refreshAll()
			end)
		end
	end

	SettingsService.onChange(function()
		refreshAll()
	end)
	refreshAll()
end

return SettingsController
