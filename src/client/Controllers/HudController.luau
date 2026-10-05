--!strict
--[[
	HudController
	StarterPlayerScripts/Client/Controllers/HudController

	Minimal HUD: cash and rebirths, plus a loud warning if the server is not
	saving. Placeholder styling — the real UI pass is Step 8. Built in code
	so the repo stays the single source of truth.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local ProfileController = require(script.Parent:WaitForChild("ProfileController"))

local HudController = {}

local function makeLabel(parent: Instance, name: string, order: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.LayoutOrder = order
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromOffset(0, 36)
	label.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
	label.BackgroundTransparency = 0.25
	label.TextColor3 = Color3.fromRGB(255, 236, 200)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 22
	label.Text = ""
	label.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = label

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 14)
	padding.PaddingRight = UDim.new(0, 14)
	padding.Parent = label

	return label
end

function HudController.Start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "HUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local bar = Instance.new("Frame")
	bar.Name = "TopBar"
	bar.AnchorPoint = Vector2.new(0.5, 0)
	bar.Position = UDim2.new(0.5, 0, 0, 8)
	bar.Size = UDim2.fromOffset(0, 36)
	bar.AutomaticSize = Enum.AutomaticSize.X
	bar.BackgroundTransparency = 1
	bar.Parent = gui

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = bar

	local cashLabel = makeLabel(bar, "Cash", 1)
	local rebirthLabel = makeLabel(bar, "Rebirths", 2)

	local warning = makeLabel(bar, "NotSaving", 3)
	warning.BackgroundColor3 = Color3.fromRGB(150, 30, 40)
	warning.TextColor3 = Color3.new(1, 1, 1)
	warning.TextSize = 16
	warning.Text = "PROGRESS NOT SAVING"
	warning.Visible = false

	gui.Parent = playerGui

	local function render(snapshot: { [string]: any })
		cashLabel.Text = "$" .. Config.FormatNumber(tonumber(snapshot.Cash) or 0)
		rebirthLabel.Text = "Rebirths " .. tostring(snapshot.Rebirths or 0)
		warning.Visible = snapshot.IsPersistent == false
	end

	ProfileController.Changed:Connect(render)
	local existing = ProfileController.Get()
	if existing then
		render(existing)
	else
		cashLabel.Text = "Loading..."
		rebirthLabel.Text = ""
	end
end

return HudController
