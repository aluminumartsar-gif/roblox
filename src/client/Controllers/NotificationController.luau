--!strict
--[[
	NotificationController
	StarterPlayerScripts/Client/Controllers/NotificationController

	Toast messages under the HUD bar. Fed by the server's Notify remote and
	by local code (e.g. the result of a button press).
	Placeholder styling — the real UI pass is Step 8.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local NotificationController = {}

local KIND_COLORS: { [string]: Color3 } = {
	Info = Color3.fromRGB(40, 44, 58),
	Success = Color3.fromRGB(38, 110, 70),
	Warning = Color3.fromRGB(150, 110, 30),
	Error = Color3.fromRGB(150, 40, 48),
}

local container: Frame? = nil
local sequence = 0

function NotificationController.Show(text: string, kind: string?)
	if not container or text == "" then
		return
	end
	local frame = container :: Frame

	-- Drop the oldest if we're at the cap.
	local toasts = {}
	for _, child in ipairs(frame:GetChildren()) do
		if child:IsA("TextLabel") then
			table.insert(toasts, child)
		end
	end
	table.sort(toasts, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	while #toasts >= Config.UI.MaxNotifications do
		table.remove(toasts, 1):Destroy()
	end

	sequence += 1
	local label = Instance.new("TextLabel")
	label.LayoutOrder = sequence
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromOffset(0, 32)
	label.BackgroundColor3 = KIND_COLORS[kind or "Info"] or KIND_COLORS.Info
	label.BackgroundTransparency = 0.1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = Enum.Font.GothamMedium
	label.TextSize = 17
	label.Text = text
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = label
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 12)
	padding.PaddingRight = UDim.new(0, 12)
	padding.Parent = label
	label.Parent = frame

	task.delay(Config.UI.NotificationDuration, function()
		if label.Parent then
			local fade = TweenService:Create(label, TweenInfo.new(0.3), { BackgroundTransparency = 1, TextTransparency = 1 })
			fade:Play()
			fade.Completed:Wait()
			label:Destroy()
		end
	end)
end

function NotificationController.Start()
	local gui = Instance.new("ScreenGui")
	gui.Name = "Notifications"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 10

	local frame = Instance.new("Frame")
	frame.Name = "Stack"
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, 0, 52)
	frame.Size = UDim2.new(0.9, 0, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundTransparency = 1
	frame.Parent = gui

	local layout = Instance.new("UIListLayout")
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = frame

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	container = frame

	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Notify") :: RemoteEvent
	remote.OnClientEvent:Connect(function(text, kind)
		if typeof(text) == "string" then
			NotificationController.Show(text, if typeof(kind) == "string" then kind else "Info")
		end
	end)
end

return NotificationController
