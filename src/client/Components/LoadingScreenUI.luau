local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local IconImage = require(script.Parent:WaitForChild("IconImage"))

local LoadingScreenUI = {}
LoadingScreenUI.__index = LoadingScreenUI

local BG_TOP      = Color3.fromRGB(10, 6, 20)
local BG_BOT      = Color3.fromRGB(3, 2, 7)
local DIRT_TOP_C  = Color3.fromRGB(58, 33, 13)
local DIRT_BOT_C  = Color3.fromRGB(22, 12, 4)
local GOLD        = Color3.fromRGB(255, 210, 40)
local GOLD_BRIGHT = Color3.fromRGB(255, 248, 120)
local ORANGE      = Color3.fromRGB(255, 138, 28)
local NEON_GREEN  = Color3.fromRGB(80, 255, 120)
local PURPLE      = Color3.fromRGB(160, 60, 255)
local WHITE       = Color3.new(1, 1, 1)
local WARM_GRAY   = Color3.fromRGB(185, 165, 130)
local DARK_FILL   = Color3.fromRGB(20, 12, 38)

local STATUS_MESSAGES = {
	"Sharpening the sigma shovel...",
	"Feeding the brainrot...",
	"Summoning the skibidi spirits...",
	"Charging up the gyatt...",
	"Sorting rare brainrots...",
	"Calibrating Ohio energy...",
	"Polishing the gem collection...",
	"Unlocking peak rizz potential...",
}

local function addCorner(parent: Instance, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

local function addStroke(parent: Instance, color: Color3, thickness: number, transparency: number?)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Transparency = transparency or 0
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
end

local function addGradient(parent: Instance, colorA: Color3, colorB: Color3, rotation: number?)
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, colorA),
		ColorSequenceKeypoint.new(1, colorB),
	})
	gradient.Rotation = rotation or 90
	gradient.Parent = parent
	return gradient
end

local function addGlowBlob(parent: Instance, name: string, position: UDim2, size: UDim2, color: Color3, transparency: number)
	local blob = Instance.new("Frame")
	blob.Name = name
	blob.AnchorPoint = Vector2.new(0.5, 0.5)
	blob.Position = position
	blob.Size = size
	blob.BackgroundColor3 = color
	blob.BackgroundTransparency = transparency
	blob.BorderSizePixel = 0
	blob.Parent = parent
	addCorner(blob, 999)
	return blob
end

local function addDirtParticle(parent: Instance, index: number)
	local size = 9 + (index * 4) % 14
	local startX = 0.04 + (index * 0.137) % 0.92
	local startY = 0.72 + (index * 0.073) % 0.24
	local driftDir = ((index % 3) - 1) * 0.04
	local duration = 2.6 + (index % 5) * 0.55

	local particle = Instance.new("Frame")
	particle.Name = "Dirt" .. index
	particle.AnchorPoint = Vector2.new(0.5, 0.5)
	particle.Position = UDim2.fromScale(startX, startY)
	particle.Size = UDim2.fromOffset(size, math.ceil(size * 0.72))
	particle.BackgroundColor3 = Color3.fromRGB(52 + index % 22, 30 + index % 10, 9 + index % 6)
	particle.BackgroundTransparency = 0.2
	particle.BorderSizePixel = 0
	particle.Rotation = index * 41
	particle.Parent = parent
	addCorner(particle, 4)

	task.spawn(function()
		task.wait(index * 0.16)
		while particle.Parent do
			particle.Position = UDim2.fromScale(startX, startY)
			particle.BackgroundTransparency = 0.2

			TweenService:Create(particle, TweenInfo.new(duration * 0.78, Enum.EasingStyle.Sine), {
				Position = UDim2.fromScale(startX + driftDir, startY - 0.58),
				BackgroundTransparency = 0.1,
			}):Play()
			task.wait(duration * 0.78)
			if not particle.Parent then
				break
			end

			TweenService:Create(particle, TweenInfo.new(duration * 0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				BackgroundTransparency = 1,
			}):Play()
			task.wait(duration * 0.27)
		end
	end)

	return particle
end

function LoadingScreenUI.new()
	local self = setmetatable({}, LoadingScreenUI)

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "LoadingScreenGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 1000
	gui.Parent = playerGui

	-- Full-screen background
	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = BG_BOT
	root.BorderSizePixel = 0
	root.Parent = gui
	addGradient(root, BG_TOP, BG_BOT, 115)

	-- Earthy dirt ground at the bottom
	local dirtLayer = Instance.new("Frame")
	dirtLayer.Name = "DirtLayer"
	dirtLayer.AnchorPoint = Vector2.new(0, 1)
	dirtLayer.Position = UDim2.fromScale(0, 1)
	dirtLayer.Size = UDim2.fromScale(1, 0.3)
	dirtLayer.BackgroundColor3 = DIRT_TOP_C
	dirtLayer.BorderSizePixel = 0
	dirtLayer.ZIndex = 2
	dirtLayer.Parent = root
	addGradient(dirtLayer, DIRT_TOP_C, DIRT_BOT_C, 90)

	-- Subtle scalloped top-edge of dirt
	for i = 1, 8 do
		local bump = Instance.new("Frame")
		bump.Name = "Bump" .. i
		bump.AnchorPoint = Vector2.new(0.5, 1)
		bump.Position = UDim2.new((i - 1) / 7, 0, 0, 4)
		bump.Size = UDim2.fromOffset(180, 22)
		bump.BackgroundColor3 = DIRT_TOP_C
		bump.BackgroundTransparency = 0.35
		bump.BorderSizePixel = 0
		bump.ZIndex = 2
		bump.Parent = dirtLayer
		addCorner(bump, 999)
	end

	-- Atmospheric glow blobs (behind content)
	addGlowBlob(root, "PurpleGlow", UDim2.fromScale(0.12, 0.32), UDim2.fromScale(0.6, 0.62), PURPLE, 0.84)
	addGlowBlob(root, "GoldGlow",   UDim2.fromScale(0.88, 0.6),  UDim2.fromScale(0.55, 0.58), GOLD,   0.86)
	addGlowBlob(root, "OrangeGlow", UDim2.fromScale(0.5, 0.78),  UDim2.fromScale(0.65, 0.32), ORANGE, 0.9)

	-- Dirt particles rising from the ground
	for i = 1, 20 do
		addDirtParticle(root, i)
	end

	-- Content layer (sits above everything)
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.fromScale(1, 1)
	content.BackgroundTransparency = 1
	content.ZIndex = 5
	content.Parent = root

	-- BrainrotShovel icon centered at top
	local shovel = IconImage.add(content, "BrainrotShovel", {
		name = "ShovelIcon",
		anchorPoint = Vector2.new(0.5, 0.5),
		position = UDim2.fromScale(0.5, 0.28),
		size = UDim2.fromOffset(140, 140),
		zIndex = 6,
	})

	-- "DIG A BRAINROT!" — big gold title
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromScale(0.5, 0.42)
	title.Size = UDim2.fromScale(0.84, 0.13)
	title.Font = Enum.Font.GothamBlack
	title.Text = "DIG A BRAINROT!"
	title.TextColor3 = GOLD
	title.TextScaled = true
	title.ZIndex = 6
	title.Parent = content

	local titleGradient = addGradient(title, GOLD_BRIGHT, ORANGE, 0)

	local titleStroke = Instance.new("UIStroke")
	titleStroke.Color = Color3.fromRGB(70, 33, 0)
	titleStroke.Thickness = 5
	titleStroke.Transparency = 0
	titleStroke.Parent = title

	-- Tagline
	local tagline = Instance.new("TextLabel")
	tagline.Name = "Tagline"
	tagline.AnchorPoint = Vector2.new(0.5, 0)
	tagline.BackgroundTransparency = 1
	tagline.Position = UDim2.fromScale(0.5, 0.56)
	tagline.Size = UDim2.fromScale(0.58, 0.044)
	tagline.Font = Enum.Font.GothamMedium
	tagline.Text = "The ultimate brainrot excavation experience"
	tagline.TextColor3 = WARM_GRAY
	tagline.TextScaled = true
	tagline.ZIndex = 6
	tagline.Parent = content

	-- Progress section
	local progressSection = Instance.new("Frame")
	progressSection.Name = "ProgressSection"
	progressSection.AnchorPoint = Vector2.new(0.5, 0)
	progressSection.BackgroundTransparency = 1
	progressSection.Position = UDim2.fromScale(0.5, 0.65)
	progressSection.Size = UDim2.fromScale(0.6, 0.2)
	progressSection.ZIndex = 6
	progressSection.Parent = content

	-- Progress track
	local progressBack = Instance.new("Frame")
	progressBack.Name = "ProgressBack"
	progressBack.AnchorPoint = Vector2.new(0.5, 0)
	progressBack.Position = UDim2.fromScale(0.5, 0)
	progressBack.Size = UDim2.new(1, 0, 0, 30)
	progressBack.BackgroundColor3 = DARK_FILL
	progressBack.BorderSizePixel = 0
	progressBack.ZIndex = 6
	progressBack.Parent = progressSection
	addCorner(progressBack, 15)
	addStroke(progressBack, GOLD, 2, 0.55)

	-- Progress fill
	local progressFill = Instance.new("Frame")
	progressFill.Name = "ProgressFill"
	progressFill.Size = UDim2.fromScale(0.03, 1)
	progressFill.BackgroundColor3 = GOLD
	progressFill.BorderSizePixel = 0
	progressFill.ZIndex = 7
	progressFill.Parent = progressBack
	addCorner(progressFill, 15)
	addGradient(progressFill, GOLD_BRIGHT, ORANGE, 0)

	-- Shimmer streak on the fill
	local shimmer = Instance.new("Frame")
	shimmer.Name = "Shimmer"
	shimmer.AnchorPoint = Vector2.new(0, 0)
	shimmer.Position = UDim2.fromScale(-0.5, 0)
	shimmer.Size = UDim2.fromScale(0.38, 1)
	shimmer.BackgroundColor3 = WHITE
	shimmer.BackgroundTransparency = 1
	shimmer.BorderSizePixel = 0
	shimmer.ZIndex = 8
	shimmer.Parent = progressFill
	addCorner(shimmer, 15)
	local shimmerGrad = Instance.new("UIGradient")
	shimmerGrad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.35, 0.55),
		NumberSequenceKeypoint.new(0.65, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	shimmerGrad.Rotation = 0
	shimmerGrad.Parent = shimmer

	-- Percent label
	local percentLabel = Instance.new("TextLabel")
	percentLabel.Name = "Percent"
	percentLabel.AnchorPoint = Vector2.new(0.5, 0)
	percentLabel.BackgroundTransparency = 1
	percentLabel.Position = UDim2.fromScale(0.5, 0.46)
	percentLabel.Size = UDim2.new(1, 0, 0, 30)
	percentLabel.Font = Enum.Font.GothamBlack
	percentLabel.Text = "0%"
	percentLabel.TextColor3 = GOLD
	percentLabel.TextScaled = true
	percentLabel.ZIndex = 6
	percentLabel.Parent = progressSection
	local percentStroke = Instance.new("UIStroke")
	percentStroke.Color = Color3.fromRGB(55, 28, 0)
	percentStroke.Thickness = 2
	percentStroke.Transparency = 0
	percentStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	percentStroke.Parent = percentLabel

	-- Status message
	local statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "Status"
	statusLabel.AnchorPoint = Vector2.new(0.5, 0)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Position = UDim2.fromScale(0.5, 0.75)
	statusLabel.Size = UDim2.new(1.2, 0, 0, 22)
	statusLabel.Font = Enum.Font.GothamMedium
	statusLabel.Text = STATUS_MESSAGES[1]
	statusLabel.TextColor3 = NEON_GREEN
	statusLabel.TextScaled = true
	statusLabel.ZIndex = 6
	statusLabel.Parent = progressSection

	-- Entry animation: black overlay fades out + content pops in
	local blackOverlay = Instance.new("Frame")
	blackOverlay.Name = "BlackOverlay"
	blackOverlay.Size = UDim2.fromScale(1, 1)
	blackOverlay.BackgroundColor3 = Color3.new(0, 0, 0)
	blackOverlay.BackgroundTransparency = 0
	blackOverlay.BorderSizePixel = 0
	blackOverlay.ZIndex = 100
	blackOverlay.Parent = root
	TweenService:Create(blackOverlay, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()

	local contentScale = Instance.new("UIScale")
	contentScale.Scale = 0.93
	contentScale.Parent = content
	TweenService:Create(contentScale, TweenInfo.new(0.55, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()

	-- Shovel swing
	task.spawn(function()
		while shovel.Parent do
			TweenService:Create(shovel, TweenInfo.new(0.65, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { Rotation = -28 }):Play()
			task.wait(0.65)
			TweenService:Create(shovel, TweenInfo.new(0.65, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { Rotation = 28 }):Play()
			task.wait(0.65)
		end
	end)

	-- Shimmer slide loop
	task.spawn(function()
		while shimmer.Parent do
			TweenService:Create(shimmer, TweenInfo.new(1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
				Position = UDim2.fromScale(1.15, 0),
			}):Play()
			task.wait(2.4)
			shimmer.Position = UDim2.fromScale(-0.5, 0)
		end
	end)

	-- Status message rotation
	task.spawn(function()
		local idx = 1
		while statusLabel.Parent do
			task.wait(1.35)
			idx = idx % #STATUS_MESSAGES + 1
			statusLabel.Text = STATUS_MESSAGES[idx]
		end
	end)

	-- Continuous gradient animations
	local renderConnection = RunService.RenderStepped:Connect(function(dt)
		titleGradient.Rotation = (titleGradient.Rotation + dt * 55) % 360
	end)

	self.gui = gui
	self.root = root
	self.content = content
	self.progressFill = progressFill
	self.percentLabel = percentLabel
	self.statusLabel = statusLabel
	self.renderConnection = renderConnection
	self.lastProgress = 0

	return self
end

function LoadingScreenUI:setProgress(progress: number)
	local clamped = math.clamp(progress, self.lastProgress, 1)
	self.lastProgress = clamped
	self.percentLabel.Text = ("%d%%"):format(math.floor(clamped * 100 + 0.5))
	TweenService:Create(self.progressFill, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(math.max(0.03, clamped), 1),
	}):Play()
end

function LoadingScreenUI:setStatus(text: string)
	self.statusLabel.Text = text
end

function LoadingScreenUI:finish()
	self:setProgress(1)
	self:setStatus("Ready to dig!")
	task.wait(0.4)

	local fadeInfo = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(self.root, fadeInfo, { BackgroundTransparency = 1 }):Play()

	for _, desc in self.gui:GetDescendants() do
		if desc:IsA("TextLabel") then
			TweenService:Create(desc, fadeInfo, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		elseif desc:IsA("Frame") then
			TweenService:Create(desc, fadeInfo, { BackgroundTransparency = 1 }):Play()
		elseif desc:IsA("UIStroke") then
			TweenService:Create(desc, fadeInfo, { Transparency = 1 }):Play()
		elseif desc:IsA("ImageLabel") then
			TweenService:Create(desc, fadeInfo, { ImageTransparency = 1 }):Play()
		end
	end

	task.wait(0.55)
	self:destroy()
end

function LoadingScreenUI:destroy()
	if self.renderConnection then
		self.renderConnection:Disconnect()
		self.renderConnection = nil
	end
	if self.gui then
		self.gui:Destroy()
		self.gui = nil
	end
end

return LoadingScreenUI
