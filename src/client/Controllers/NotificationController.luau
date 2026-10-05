--!strict
--[[
	NotificationController
	StarterPlayerScripts/Client/Controllers/NotificationController

	Toast messages under the HUD bar. Fed by the server's Notify remote and
	by local code (e.g. the result of a button press).

	Each toast: an icon for its kind (Config.Feedback.ToastIcons), slides
	down into place and fades in, plays a soft sound (Config.Feedback.
	ToastSounds; silent if another sound just played, so it never piles on
	top of a hatch fanfare), and fades out after Config.UI.NotificationDuration.
	Server-wide announcements (GlobalAnnounce) are bigger and tinted with
	the rarity's colour.

	API (unchanged): NotificationController.Show(text, kind?, color?)
	  kind: "Info" | "Success" | "Warning" | "Error" | "Announce"
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Components = script.Parent.Parent:WaitForChild("Components")
local ScreenScale = require(Components:WaitForChild("ScreenScale"))
local Icon = require(Components:WaitForChild("Icon"))

local NotificationController = {}

local KIND_COLORS: { [string]: Color3 } = {
	Info = Color3.fromRGB(40, 44, 58),
	Success = Color3.fromRGB(38, 110, 70),
	Warning = Color3.fromRGB(150, 110, 30),
	Error = Color3.fromRGB(150, 40, 48),
	Announce = Color3.fromRGB(150, 110, 30),
}

local container: Frame? = nil
local sequence = 0

--- SoundController starts after this controller, so fetch it lazily (and
--- never wait for it).
local function playSound(kind: string)
	local name = Config.Feedback.ToastSounds[kind]
	local module = script.Parent:FindFirstChild("SoundController")
	if not name or not module or not module:IsA("ModuleScript") then
		return
	end
	local ok, controller = pcall(require, module)
	if ok and typeof(controller) == "table" and typeof(controller.Play) == "function" then
		controller.Play(name, if kind == "Error" then nil else { IfQuietFor = Config.Feedback.ToastSoundQuietFor })
	end
end

function NotificationController.Show(text: string, kind: string?, color: Color3?)
	if not container or text == "" then
		return
	end
	local frame = container :: Frame
	local toastKind = kind or "Info"
	local announce = toastKind == "Announce"

	-- Drop the oldest if we're at the cap.
	local toasts = {}
	for _, child in ipairs(frame:GetChildren()) do
		if child:IsA("Frame") and child.Name == "Toast" then
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
	local height = if announce then 40 else 34

	-- Holder keeps the slot in the list; the body inside slides into it.
	local holder = Instance.new("Frame")
	holder.Name = "Toast"
	holder.LayoutOrder = sequence
	holder.AutomaticSize = Enum.AutomaticSize.X
	holder.Size = UDim2.fromOffset(0, height)
	holder.BackgroundTransparency = 1

	local background = color or KIND_COLORS[toastKind] or KIND_COLORS.Info
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.AutomaticSize = Enum.AutomaticSize.X
	body.Size = UDim2.fromOffset(0, height)
	body.Position = UDim2.fromOffset(0, -14)
	body.BackgroundColor3 = background
	body.BackgroundTransparency = 1
	body.Parent = holder
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = body
	local stroke = Instance.new("UIStroke")
	stroke.Color = background:Lerp(Color3.new(1, 1, 1), 0.35)
	stroke.Thickness = if announce then 2 else 1
	stroke.Transparency = 1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = body
	if announce then
		-- A little shine across rarity-coloured announcements.
		local gradient = Instance.new("UIGradient")
		gradient.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(200, 200, 200))
		gradient.Rotation = 90
		gradient.Parent = body
	end
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 12)
	padding.Parent = body
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = body

	local iconName = Config.Feedback.ToastIcons[toastKind]
	local icon: ImageLabel? = nil
	if iconName then
		local image = Icon.new(iconName, height - 12, body)
		image.LayoutOrder = 1
		image.ImageTransparency = 1
		icon = image
	end

	local label = Instance.new("TextLabel")
	label.LayoutOrder = 2
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromOffset(0, height)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextTransparency = 1
	label.TextStrokeTransparency = 1
	label.Font = if announce then Enum.Font.GothamBlack else Enum.Font.GothamBold
	label.TextSize = if announce then 19 else 17
	label.Text = text
	label.Parent = body
	holder.Parent = frame

	-- Slide down + fade in.
	local inInfo = TweenInfo.new(Config.Feedback.ToastSlideTime, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	TweenService:Create(body, inInfo, { Position = UDim2.fromOffset(0, 0), BackgroundTransparency = 0.08 }):Play()
	TweenService:Create(label, inInfo, { TextTransparency = 0, TextStrokeTransparency = 0.7 }):Play()
	TweenService:Create(stroke, inInfo, { Transparency = 0.3 }):Play()
	if icon then
		TweenService:Create(icon, inInfo, { ImageTransparency = 0 }):Play()
	end
	playSound(toastKind)

	task.delay(Config.UI.NotificationDuration, function()
		if holder.Parent then
			local outInfo = TweenInfo.new(0.3)
			local fade = TweenService:Create(body, outInfo, { BackgroundTransparency = 1 })
			TweenService:Create(label, outInfo, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
			TweenService:Create(stroke, outInfo, { Transparency = 1 }):Play()
			if icon then
				TweenService:Create(icon, outInfo, { ImageTransparency = 1 }):Play()
			end
			fade:Play()
			fade.Completed:Wait()
			holder:Destroy()
		end
	end)
end

-- Banners at the top of the screen (sightings, the Hunt) reserve space so
-- toasts never cover them: key -> the banner's bottom edge in screen pixels.
local TOAST_GAP = 8
local reservations: { [string]: number } = {}
local stackBase: UDim2? = nil

local function placeStack()
	local frame = container
	local base = stackBase
	if not frame or not base then
		return
	end
	local lowest: number? = nil
	for _, bottom in pairs(reservations) do
		if not lowest or bottom > lowest then
			lowest = bottom
		end
	end
	if lowest then
		local gui = frame:FindFirstAncestorWhichIsA("LayerCollector")
		local guiTop = if gui and gui:IsA("ScreenGui") then gui.AbsolutePosition.Y else 0
		local wanted = lowest + TOAST_GAP - guiTop
		frame.Position = UDim2.new(base.X.Scale, base.X.Offset, base.Y.Scale, math.max(base.Y.Offset, wanted))
	else
		frame.Position = base
	end
end

--- Keeps the toast stack below a banner. `key` names the banner; `bottom`
--- is its bottom edge in screen pixels (AbsolutePosition.Y + AbsoluteSize.Y),
--- or nil when the banner hides.
function NotificationController.ReserveTop(key: string, bottom: number?)
	reservations[key] = bottom
	placeStack()
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
	ScreenScale.Apply(frame)

	local layout = Instance.new("UIListLayout")
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = frame

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	container = frame
	stackBase = frame.Position
	placeStack()

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local notify = remotes:WaitForChild("Notify") :: RemoteEvent
	notify.OnClientEvent:Connect(function(text, kind)
		if typeof(text) == "string" then
			NotificationController.Show(text, if typeof(kind) == "string" then kind else "Info")
		end
	end)

	-- Server-wide announcements (big hatches), tinted by rarity.
	local announce = remotes:WaitForChild("GlobalAnnounce") :: RemoteEvent
	announce.OnClientEvent:Connect(function(text, rarity)
		if typeof(text) ~= "string" then
			return
		end
		local rarityDef = typeof(rarity) == "string" and Config.Rarities[rarity]
		NotificationController.Show(text, "Announce", if rarityDef then rarityDef.Color else nil)
	end)
end

return NotificationController
