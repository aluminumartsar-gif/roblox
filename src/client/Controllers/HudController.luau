--!strict
--[[
	HudController
	StarterPlayerScripts/Client/Controllers/HudController

	Top bar: cash, rebirths, active buffs (with time left), and a loud
	warning if the server is not saving. Built in code so the repo stays the
	single source of truth. Placeholder styling — the real UI pass is Step 8.

	Buff expiry times are server os.time() values; the snapshot carries the
	server's clock (ServerTime) so countdowns don't depend on the player's
	own clock being right.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local Icon = require(script.Parent.Parent:WaitForChild("Components"):WaitForChild("Icon"))
local ProfileController = require(script.Parent:WaitForChild("ProfileController"))

local HudController = {}

-- Which icon and label each buff shows on the HUD.
local BUFFS: { { key: string, icon: string } } = {
	{ key = "Luck", icon = "Potion" },
	{ key = "HeatRate", icon = "Bonfire" },
}

local function pill(parent: Instance, name: string, order: number, iconName: string?): TextLabel
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

	if iconName then
		Icon.addLeft(label, iconName, 26, 6)
	end
	return label
end

local function formatClock(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
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

	local cashLabel = pill(bar, "Cash", 1, "Cash")
	local rebirthLabel = pill(bar, "Rebirths", 2, "Rebirth")

	local buffLabels: { [string]: TextLabel } = {}
	for i, buff in ipairs(BUFFS) do
		local chip = pill(bar, "Buff_" .. buff.key, 2 + i, buff.icon)
		chip.TextSize = 18
		chip.TextColor3 = Color3.fromRGB(180, 255, 190)
		chip.Visible = false
		buffLabels[buff.key] = chip
	end

	local warning = pill(bar, "NotSaving", 10, "Warning")
	warning.BackgroundColor3 = Color3.fromRGB(150, 30, 40)
	warning.TextColor3 = Color3.new(1, 1, 1)
	warning.TextSize = 16
	warning.Text = "PROGRESS NOT SAVING"
	warning.Visible = false

	gui.Parent = playerGui

	-- Server clock at the moment the latest snapshot arrived.
	local snapshotServerTime = 0
	local snapshotClock = os.clock()

	local function render(snapshot: { [string]: any })
		cashLabel.Text = "$" .. Config.FormatNumber(tonumber(snapshot.Cash) or 0)
		rebirthLabel.Text = tostring(snapshot.Rebirths or 0)
		warning.Visible = snapshot.IsPersistent == false
	end

	local function renderBuffs()
		local snapshot = ProfileController.Get()
		local buffs = snapshot and snapshot.Buffs or {}
		local serverNow = snapshotServerTime + (os.clock() - snapshotClock)
		for key, chip in pairs(buffLabels) do
			local expiry = tonumber(buffs[key])
			local remaining = if expiry then expiry - serverNow else 0
			chip.Visible = remaining > 0
			if remaining > 0 then
				chip.Text = formatClock(remaining)
			end
		end
	end

	ProfileController.Changed:Connect(function(snapshot)
		snapshotServerTime = tonumber(snapshot.ServerTime) or os.time()
		snapshotClock = os.clock()
		render(snapshot)
		renderBuffs()
	end)
	local existing = ProfileController.Get()
	if existing then
		snapshotServerTime = tonumber(existing.ServerTime) or os.time()
		render(existing)
	else
		cashLabel.Text = "..."
		rebirthLabel.Text = ""
	end

	task.spawn(function()
		while true do
			task.wait(0.5)
			renderBuffs()
		end
	end)
end

return HudController
