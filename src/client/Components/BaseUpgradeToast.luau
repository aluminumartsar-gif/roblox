local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local UIAnimations = require(script.Parent:WaitForChild("UIAnimations"))

local BaseUpgradeToast = {}
BaseUpgradeToast.__index = BaseUpgradeToast

local SUCCESS_PRIMARY = Color3.fromRGB(255, 200, 60)
local SUCCESS_DEEP = Color3.fromRGB(120, 70, 6)
local FAILURE_PRIMARY = Color3.fromRGB(220, 90, 90)
local FAILURE_DEEP = Color3.fromRGB(110, 24, 24)
local TEXT_DARK = Color3.fromRGB(40, 22, 4)
local TEXT_LIGHT = Color3.fromRGB(255, 248, 230)

local SHOWN_POSITION = UDim2.fromScale(0.5, 0.03)
local HIDDEN_POSITION = UDim2.new(0.5, 0, -0.18, 0)
local SLIDE_IN = TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SLIDE_OUT = TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local SUCCESS_VISIBLE_SECONDS = 4
local FAILURE_VISIBLE_SECONDS = 3.5

local function addCorner(parent: Instance, radius: UDim)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = radius
	corner.Parent = parent
end

local function addStroke(parent: Instance, color: Color3, thickness: number, transparency: number?)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Transparency = transparency or 0
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = parent
	return stroke
end

local function addGradient(parent: Instance, topColor: Color3, bottomColor: Color3, rotation: number?)
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, topColor),
		ColorSequenceKeypoint.new(1, bottomColor),
	})
	gradient.Rotation = rotation or 90
	gradient.Parent = parent
	return gradient
end

local function addDropShadow(parent: GuiObject)
	local shadow = Instance.new("Frame")
	shadow.Name = "Shadow"
	shadow.AnchorPoint = Vector2.new(0.5, 0.5)
	shadow.Position = UDim2.fromScale(0.5, 0.54)
	shadow.Size = UDim2.fromScale(1.04, 1.1)
	shadow.BackgroundColor3 = Color3.new(0, 0, 0)
	shadow.BackgroundTransparency = 0.55
	shadow.BorderSizePixel = 0
	shadow.ZIndex = (parent.ZIndex or 1) - 1
	shadow.Parent = parent
	addCorner(shadow, UDim.new(0.25, 0))
end

local function lighten(color: Color3, amount: number)
	return Color3.new(
		math.clamp(color.R + amount, 0, 1),
		math.clamp(color.G + amount, 0, 1),
		math.clamp(color.B + amount, 0, 1)
	)
end

function BaseUpgradeToast.new()
	local self = setmetatable({}, BaseUpgradeToast)

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "BaseUpgradeToastGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 35
	gui.Enabled = false
	gui.Parent = playerGui

	local banner = Instance.new("Frame")
	banner.Name = "Banner"
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = HIDDEN_POSITION
	banner.Size = UDim2.fromScale(0.32, 0.09)
	banner.BackgroundColor3 = SUCCESS_PRIMARY
	banner.BorderSizePixel = 0
	banner.Parent = gui
	addCorner(banner, UDim.new(0.23, 0))
	local bannerGradient = addGradient(banner, SUCCESS_PRIMARY, SUCCESS_DEEP)
	local bannerStroke = addStroke(banner, SUCCESS_DEEP, 4, 0.05)
	addDropShadow(banner)
	local shineOverlay = UIAnimations.addShineSweep(banner, { intervalSeconds = 2.4, travelSeconds = 0.7, intensity = 0.5 })

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.fromScale(0.5, 0.1)
	title.Size = UDim2.fromScale(0.88, 0.4)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBlack
	title.Text = "FLOOR UNLOCKED"
	title.TextColor3 = TEXT_DARK
	title.TextScaled = true
	title.TextStrokeColor3 = TEXT_LIGHT
	title.TextStrokeTransparency = 0.45
	title.Parent = banner

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.AnchorPoint = Vector2.new(0.5, 1)
	subtitle.Position = UDim2.new(0.5, 0, 0.88, 0)
	subtitle.Size = UDim2.fromScale(0.88, 0.31)
	subtitle.BackgroundTransparency = 1
	subtitle.Font = Enum.Font.GothamBold
	subtitle.Text = ""
	subtitle.TextColor3 = TEXT_DARK
	subtitle.TextScaled = true
	subtitle.TextStrokeColor3 = TEXT_LIGHT
	subtitle.TextStrokeTransparency = 0.6
	subtitle.Parent = banner

	self.gui = gui
	self.banner = banner
	self.bannerGradient = bannerGradient
	self.bannerStroke = bannerStroke
	self.shineOverlay = shineOverlay
	self.title = title
	self.subtitle = subtitle
	self.hideToken = 0

	return self
end

function BaseUpgradeToast:_applyTheme(success: boolean, accentColor: Color3?)
	local primary = if success
		then (accentColor or SUCCESS_PRIMARY)
		else FAILURE_PRIMARY
	local deep = if success then SUCCESS_DEEP else FAILURE_DEEP

	self.banner.BackgroundColor3 = primary
	self.bannerGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, lighten(primary, 0.15)),
		ColorSequenceKeypoint.new(1, deep),
	})
	self.bannerStroke.Color = deep

	if success then
		self.title.Text = "FLOOR UNLOCKED"
		self.title.TextColor3 = TEXT_DARK
		self.subtitle.TextColor3 = TEXT_DARK
		if self.shineOverlay then
			self.shineOverlay.Visible = true
		end
	else
		self.title.Text = "UPGRADE BLOCKED"
		self.title.TextColor3 = TEXT_LIGHT
		self.subtitle.TextColor3 = TEXT_LIGHT
		if self.shineOverlay then
			self.shineOverlay.Visible = false
		end
	end
end

function BaseUpgradeToast:show(payload)
	if not self.gui then
		return
	end

	local success = payload and payload.success == true
	local accentColor = if typeof(payload.accentColor) == "Color3" then payload.accentColor else nil

	local fallbackMessage = if success then "New floor added to your tower!" else "Upgrade unavailable."
	local hasMessage = type(payload.message) == "string" and payload.message ~= ""
	local message = if hasMessage then payload.message else fallbackMessage
	local subtitleText = if success and payload.displayName
		then ("%s - %s"):format(payload.displayName, message)
		else message

	self:_applyTheme(success, accentColor)
	self.subtitle.Text = subtitleText

	self.gui.Enabled = true
	self.banner.Position = HIDDEN_POSITION
	TweenService:Create(self.banner, SLIDE_IN, { Position = SHOWN_POSITION }):Play()
	UIAnimations.bump(self.banner, { peakScale = 1.12, duration = 0.32 })

	self.hideToken += 1
	local token = self.hideToken
	local visibleFor = if success then SUCCESS_VISIBLE_SECONDS else FAILURE_VISIBLE_SECONDS

	task.delay(visibleFor, function()
		if self.hideToken == token then
			self:hide()
		end
	end)
end

function BaseUpgradeToast:hide()
	if not self.gui then
		return
	end

	local tween = TweenService:Create(self.banner, SLIDE_OUT, { Position = HIDDEN_POSITION })
	tween:Play()
	tween.Completed:Once(function()
		if self.gui then
			self.gui.Enabled = false
		end
	end)
end

function BaseUpgradeToast:Destroy()
	if self.gui then
		self.gui:Destroy()
		self.gui = nil
	end
end

return BaseUpgradeToast
