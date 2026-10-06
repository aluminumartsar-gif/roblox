-- Proximity-based sell station UI for the Workspace.Sell stand.
--
-- When the player walks within OPEN_RADIUS_STUDS of the sell-stand shopkeeper
-- a compact panel slides in. The panel presents three actions:
--   1. Sell the first brainrot in their hotbar.
--   2. Sell everything in their hotbar + backpack.
--   3. Dismiss the panel.
--
-- Proximity uses hysteresis: the panel opens at OPEN_RADIUS and stays open
-- until the player passes CLOSE_RADIUS, preventing flicker at the boundary.
-- An explicit "Leave" close also suppresses auto-reopen until they walk clear.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local EconomyConfig = require(ConfigFolder:WaitForChild("EconomyConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))
local WorkspaceModelFind = require(UtilFolder:WaitForChild("WorkspaceModelFind"))
local IconAssets = require(ConfigFolder:WaitForChild("IconAssets"))
local FormatUtil = require(UtilFolder:WaitForChild("FormatUtil"))

local Components = script.Parent.Parent:WaitForChild("Components")
local UIAnimations = require(Components:WaitForChild("UIAnimations"))

-- HotbarController owns the "currently held" brainrot: the slot the player has
-- selected (keybind/click) and is visibly holding in-hand. We sell that slot.
local HotbarController = require(script.Parent:WaitForChild("HotbarController"))

local SellBoothController = {}

local SELL_MODEL_NAME = "Sell"
local OPEN_RADIUS_STUDS = 12
local CLOSE_RADIUS_STUDS = 22
local CHECK_INTERVAL_SECONDS = 1 / 6

-- ─── colours ──────────────────────────────────────────────────────────────────

local BG             = Color3.fromRGB(11, 12, 18)
local BG_CARD        = Color3.fromRGB(17, 19, 30)
local BG_CARD_LIGHT  = Color3.fromRGB(23, 26, 40)
local BORDER         = Color3.fromRGB(38, 42, 68)
local BORDER_BRIGHT  = Color3.fromRGB(60, 68, 110)

local TEXT_PRIMARY   = Color3.fromRGB(230, 235, 255)
local TEXT_SECONDARY = Color3.fromRGB(140, 150, 190)
local TEXT_MUTED     = Color3.fromRGB(85, 92, 130)

local GOLD           = Color3.fromRGB(255, 196, 56)
local GOLD_DIM       = Color3.fromRGB(180, 135, 30)
local GREEN          = Color3.fromRGB(52, 222, 140)
local GREEN_DIM      = Color3.fromRGB(28, 140, 86)

local STATUS_SUCCESS = Color3.fromRGB(70, 220, 150)
local STATUS_ERROR   = Color3.fromRGB(255, 110, 110)

local FLOAT_COLOR    = Color3.fromRGB(255, 230, 80)
local FLOAT_STROKE   = Color3.fromRGB(30, 110, 55)

local localPlayer = Players.LocalPlayer

-- ─── utility ──────────────────────────────────────────────────────────────────

local function corner(parent: Instance, radius: UDim): UICorner
	local c = Instance.new("UICorner")
	c.CornerRadius = radius
	c.Parent = parent
	return c
end

local function stroke(parent: Instance, thickness: number, color: Color3, transparency: number?): UIStroke
	local s = Instance.new("UIStroke")
	s.Thickness = thickness
	s.Color = color
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function gradient(parent: Instance, top: Color3, bot: Color3, rotation: number?): UIGradient
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, top),
		ColorSequenceKeypoint.new(1, bot),
	})
	g.Rotation = rotation or 90
	g.Parent = parent
	return g
end

local function padding(parent: Instance, top: number, bot: number, left: number, right: number): UIPadding
	local p = Instance.new("UIPadding")
	p.PaddingTop    = UDim.new(0, top)
	p.PaddingBottom = UDim.new(0, bot)
	p.PaddingLeft   = UDim.new(0, left)
	p.PaddingRight  = UDim.new(0, right)
	p.Parent = parent
	return p
end

-- ─── model helpers ────────────────────────────────────────────────────────────

local function findSellModel(): Model?
	return WorkspaceModelFind.findNamedModel(Workspace, SELL_MODEL_NAME)
end

local function findShopkeeper(sellModel: Model): Model?
	for _, descendant in sellModel:GetDescendants() do
		if descendant:IsA("Humanoid") then
			local model = descendant.Parent
			if model and model:IsA("Model") then
				return model
			end
		end
	end
	return nil
end

local function findAnchor(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then return root end
	local primary = model.PrimaryPart
	if primary and primary:IsA("BasePart") then return primary end
	local torso = model:FindFirstChild("Torso")
	if torso and torso:IsA("BasePart") then return torso end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then return d end
	end
	return nil
end

local function getCharacterRoot(): BasePart?
	local character = localPlayer.Character
	if not character then return nil end
	local root = character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- ─── cash float animation ─────────────────────────────────────────────────────

local function spawnCashFloat(screenGui: ScreenGui, amount: number)
	local label = Instance.new("TextLabel")
	label.Name = "CashFloat"
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position = UDim2.new(0.5, 0, 1, -180)
	label.Size = UDim2.new(0, 320, 0, 60)
	label.BackgroundTransparency = 1
	label.Text = ("+%s"):format(FormatUtil.money(amount))
	label.TextColor3 = FLOAT_COLOR
	label.Font = Enum.Font.GothamBlack
	label.TextSize = 38
	label.TextStrokeColor3 = FLOAT_STROKE
	label.TextStrokeTransparency = 0
	label.ZIndex = 100
	label.Parent = screenGui

	local floatStroke = Instance.new("UIStroke")
	floatStroke.Thickness = 2.5
	floatStroke.Color = FLOAT_STROKE
	floatStroke.Transparency = 0.05
	floatStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	floatStroke.Parent = label

	local uiScale = Instance.new("UIScale")
	uiScale.Scale = 0.2
	uiScale.Parent = label
	TweenService:Create(uiScale, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1.08,
	}):Play()
	task.delay(0.28, function()
		if uiScale.Parent then
			TweenService:Create(uiScale, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Scale = 1,
			}):Play()
		end
	end)

	local floatDuration = 1.7
	TweenService:Create(label, TweenInfo.new(floatDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, 0, 1, -320),
	}):Play()

	task.delay(floatDuration * 0.42, function()
		if not label.Parent then return end
		local fadeInfo = TweenInfo.new(floatDuration * 0.58, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(label, fadeInfo, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		TweenService:Create(floatStroke, fadeInfo, { Transparency = 1 }):Play()
	end)

	local coinCount = math.min(8, 2 + math.floor(math.log10(math.max(amount, 10))))
	for i = 1, coinCount do
		task.delay((i - 1) * 0.048, function()
			local coin = Instance.new("ImageLabel")
			coin.Name = "CashCoin"
			coin.AnchorPoint = Vector2.new(0.5, 0.5)
			coin.Position = UDim2.new(0.5, math.random(-40, 40), 1, -180)
			coin.Size = UDim2.fromOffset(28, 28)
			coin.BackgroundTransparency = 1
			coin.Image = IconAssets.Cash
			coin.ImageColor3 = GOLD
			coin.ZIndex = 99
			coin.Parent = screenGui

			local cs = Instance.new("UIScale")
			cs.Scale = 0
			cs.Parent = coin
			TweenService:Create(cs, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
				Scale = 1,
			}):Play()

			local angle = (i / coinCount) * math.pi * 2 + (math.random() - 0.5) * 0.7
			local spreadX = math.cos(angle) * (0.12 + math.random() * 0.1)
			local upward = -70 - math.random() * 55
			local coinDur = 0.85 + math.random() * 0.4

			TweenService:Create(coin, TweenInfo.new(coinDur, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Position = UDim2.new(0.5 + spreadX, math.random(-25, 25), 1, -180 + upward),
			}):Play()

			task.delay(coinDur * 0.35, function()
				if coin.Parent then
					TweenService:Create(coin, TweenInfo.new(coinDur * 0.65, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
						ImageTransparency = 1,
					}):Play()
				end
			end)
			task.delay(coinDur + 0.1, function()
				if coin.Parent then coin:Destroy() end
			end)
		end)
	end

	task.delay(floatDuration + 0.2, function()
		if label.Parent then label:Destroy() end
	end)
end

-- ─── UI construction ──────────────────────────────────────────────────────────

local function buildUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "SellDialogue"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 20
	screenGui.Enabled = false
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")

	-- Drop shadow.
	local shadow = Instance.new("Frame")
	shadow.Name = "Shadow"
	shadow.Size = UDim2.new(0, 510, 0, 0)
	shadow.AnchorPoint = Vector2.new(0.5, 1)
	shadow.Position = UDim2.new(0.5, 4, 1, -114)
	shadow.BackgroundColor3 = Color3.new(0, 0, 0)
	shadow.BackgroundTransparency = 0.42
	shadow.BorderSizePixel = 0
	shadow.AutomaticSize = Enum.AutomaticSize.Y
	shadow.Parent = screenGui
	corner(shadow, UDim.new(0, 16))

	-- Main panel.
	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.new(0, 500, 0, 0)
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.new(0.5, 0, 1, -120)
	panel.BackgroundColor3 = BG_CARD
	panel.BorderSizePixel = 0
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.Parent = screenGui
	corner(panel, UDim.new(0, 14))
	stroke(panel, 1.5, BORDER_BRIGHT, 0.2)
	gradient(panel, BG_CARD_LIGHT, BG_CARD)

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 0)
	layout.Parent = panel

	-- ── Header ────────────────────────────────────────────────────────────────

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 72)
	header.BackgroundColor3 = BG
	header.BorderSizePixel = 0
	header.LayoutOrder = 1
	header.ClipsDescendants = true
	header.Parent = panel
	corner(header, UDim.new(0, 14))

	-- Fill bottom of header to merge cleanly into body.
	local headerFill = Instance.new("Frame")
	headerFill.Size = UDim2.new(1, 0, 0, 14)
	headerFill.AnchorPoint = Vector2.new(0, 1)
	headerFill.Position = UDim2.new(0, 0, 1, 0)
	headerFill.BackgroundColor3 = BG
	headerFill.BorderSizePixel = 0
	headerFill.Parent = header

	-- Subtle gold shimmer across the header.
	UIAnimations.addShineSweep(header, { intervalSeconds = 4, travelSeconds = 0.7, intensity = 0.18 })

	-- Left gold accent stripe.
	local accentStripe = Instance.new("Frame")
	accentStripe.Size = UDim2.new(0, 4, 0.65, 0)
	accentStripe.AnchorPoint = Vector2.new(0, 0.5)
	accentStripe.Position = UDim2.new(0, 14, 0.42, 0)
	accentStripe.BackgroundColor3 = GOLD
	accentStripe.BorderSizePixel = 0
	accentStripe.ZIndex = 3
	accentStripe.Parent = header
	corner(accentStripe, UDim.new(1, 0))

	-- Coin icon.
	local coinIcon = Instance.new("ImageLabel")
	coinIcon.Name = "CoinIcon"
	coinIcon.Size = UDim2.new(0, 32, 0, 32)
	coinIcon.AnchorPoint = Vector2.new(0, 0.5)
	coinIcon.Position = UDim2.new(0, 28, 0.38, 0)
	coinIcon.BackgroundTransparency = 1
	coinIcon.Image = IconAssets.Cash
	coinIcon.ImageColor3 = GOLD
	coinIcon.ScaleType = Enum.ScaleType.Fit
	coinIcon.ZIndex = 3
	coinIcon.Parent = header
	UIAnimations.bindIdlePulse(coinIcon, { peakScale = 1.12, period = 2.4 })

	-- "SELL STATION" title.
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, -80, 0, 28)
	title.Position = UDim2.new(0, 70, 0, 14)
	title.BackgroundTransparency = 1
	title.Text = "SELL STATION"
	title.TextColor3 = TEXT_PRIMARY
	title.Font = Enum.Font.GothamBlack
	title.TextSize = 17
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 3
	title.Parent = header

	-- Subtitle line.
	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.Size = UDim2.new(1, -80, 0, 20)
	subtitle.Position = UDim2.new(0, 70, 0, 40)
	subtitle.BackgroundTransparency = 1
	subtitle.Text = "Trade your brainrots for cold hard cash"
	subtitle.TextColor3 = TEXT_SECONDARY
	subtitle.Font = Enum.Font.Gotham
	subtitle.TextSize = 12
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.ZIndex = 3
	subtitle.Parent = header

	-- ── Body ──────────────────────────────────────────────────────────────────

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Size = UDim2.new(1, 0, 0, 0)
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.LayoutOrder = 2
	body.Parent = panel

	local bodyLayout = Instance.new("UIListLayout")
	bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
	bodyLayout.Padding = UDim.new(0, 8)
	bodyLayout.Parent = body
	padding(body, 14, 14, 14, 14)

	-- ── Status bar ────────────────────────────────────────────────────────────

	local statusFrame = Instance.new("Frame")
	statusFrame.Name = "StatusFrame"
	statusFrame.Size = UDim2.new(1, 0, 0, 0)
	statusFrame.BackgroundTransparency = 1
	statusFrame.BorderSizePixel = 0
	statusFrame.AutomaticSize = Enum.AutomaticSize.Y
	statusFrame.LayoutOrder = 10
	statusFrame.Visible = false
	statusFrame.Parent = body

	local statusBg = Instance.new("Frame")
	statusBg.Size = UDim2.new(1, 0, 0, 36)
	statusBg.BackgroundColor3 = Color3.fromRGB(20, 30, 22)
	statusBg.BorderSizePixel = 0
	statusBg.Parent = statusFrame
	corner(statusBg, UDim.new(0, 8))
	stroke(statusBg, 1, STATUS_SUCCESS, 0.5)

	local statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "StatusLabel"
	statusLabel.Size = UDim2.new(1, -16, 1, 0)
	statusLabel.Position = UDim2.new(0, 8, 0, 0)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Text = ""
	statusLabel.TextColor3 = STATUS_SUCCESS
	statusLabel.Font = Enum.Font.GothamBold
	statusLabel.TextSize = 13
	statusLabel.TextXAlignment = Enum.TextXAlignment.Center
	statusLabel.TextYAlignment = Enum.TextYAlignment.Center
	statusLabel.TextWrapped = true
	statusLabel.Parent = statusBg

	return {
		screenGui  = screenGui,
		panel      = panel,
		body       = body,
		statusFrame = statusFrame,
		statusBg   = statusBg,
		statusLabel = statusLabel,
	}
end

-- ─── sell button builder ──────────────────────────────────────────────────────

-- Creates a prominent sell action button.
--   accentColor  – glow/border/icon color for this action
--   dimColor     – darker variant for background gradient
--   isPrimary    – true for main sell buttons (taller, more visual weight)
local function buildSellButton(
	parent: Frame,
	order: number,
	icon: string?,
	label: string,
	sublabel: string,
	accentColor: Color3,
	dimColor: Color3,
	isPrimary: boolean,
	onClick: () -> ()
): TextButton
	local height = if isPrimary then 64 else 44

	local btn = Instance.new("TextButton")
	btn.Name = "Btn" .. order
	btn.Size = UDim2.new(1, 0, 0, height)
	btn.Text = ""
	btn.BackgroundColor3 = BG
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = false
	btn.LayoutOrder = order
	btn.Parent = parent
	corner(btn, UDim.new(0, 10))

	-- Background gradient tinted with the accent.
	local bg = Instance.new("Frame")
	bg.Name = "BG"
	bg.Size = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3 = BG
	bg.BorderSizePixel = 0
	bg.ZIndex = 1
	bg.Parent = btn
	corner(bg, UDim.new(0, 10))
	gradient(bg, Color3.fromRGB(
		math.floor(accentColor.R * 255 * 0.08),
		math.floor(accentColor.G * 255 * 0.08),
		math.floor(accentColor.B * 255 * 0.08)
	), BG)

	-- Border glow.
	local btnStroke = stroke(btn, 1.5, accentColor, 0.65)

	-- Left accent bar.
	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(0, 3, 0.55, 0)
	bar.AnchorPoint = Vector2.new(0, 0.5)
	bar.Position = UDim2.new(0, 12, 0.5, 0)
	bar.BackgroundColor3 = accentColor
	bar.BorderSizePixel = 0
	bar.ZIndex = 3
	bar.Parent = btn
	corner(bar, UDim.new(1, 0))

	-- Icon.
	local iconOffset = 24
	if icon then
		iconOffset = 52
		local iconImg = Instance.new("ImageLabel")
		iconImg.Name = "Icon"
		iconImg.Size = UDim2.new(0, 24, 0, 24)
		iconImg.AnchorPoint = Vector2.new(0, 0.5)
		iconImg.Position = UDim2.new(0, 24, 0.5, 0)
		iconImg.BackgroundTransparency = 1
		iconImg.Image = icon
		iconImg.ImageColor3 = accentColor
		iconImg.ScaleType = Enum.ScaleType.Fit
		iconImg.ZIndex = 3
		iconImg.Parent = btn
	end

	-- Main label.
	local mainLabel = Instance.new("TextLabel")
	mainLabel.Name = "Label"
	mainLabel.Size = UDim2.new(1, -(iconOffset + 14), 0, if isPrimary then 24 else height)
	mainLabel.Position = UDim2.new(0, iconOffset, 0, if isPrimary then 10 else 0)
	mainLabel.BackgroundTransparency = 1
	mainLabel.Text = label
	mainLabel.TextColor3 = TEXT_PRIMARY
	mainLabel.Font = Enum.Font.GothamBold
	mainLabel.TextSize = if isPrimary then 15 else 14
	mainLabel.TextXAlignment = Enum.TextXAlignment.Left
	mainLabel.TextYAlignment = if isPrimary then Enum.TextYAlignment.Bottom else Enum.TextYAlignment.Center
	mainLabel.ZIndex = 3
	mainLabel.Parent = btn

	-- Sub-label (only on primary buttons).
	if isPrimary and sublabel ~= "" then
		local sub = Instance.new("TextLabel")
		sub.Name = "SubLabel"
		sub.Size = UDim2.new(1, -(iconOffset + 14), 0, 18)
		sub.Position = UDim2.new(0, iconOffset, 0, 36)
		sub.BackgroundTransparency = 1
		sub.Text = sublabel
		sub.TextColor3 = TEXT_SECONDARY
		sub.Font = Enum.Font.Gotham
		sub.TextSize = 12
		sub.TextXAlignment = Enum.TextXAlignment.Left
		sub.TextYAlignment = Enum.TextYAlignment.Top
		sub.ZIndex = 3
		sub.Parent = btn
	end

	-- Hover / press state tweens.
	local idleColor  = BG
	local hoverColor = Color3.fromRGB(
		math.clamp(math.floor(accentColor.R * 255 * 0.13 + 11), 0, 255),
		math.clamp(math.floor(accentColor.G * 255 * 0.13 + 12), 0, 255),
		math.clamp(math.floor(accentColor.B * 255 * 0.13 + 18), 0, 255)
	)
	local pressColor = Color3.fromRGB(
		math.clamp(math.floor(accentColor.R * 255 * 0.2 + 8), 0, 255),
		math.clamp(math.floor(accentColor.G * 255 * 0.2 + 8), 0, 255),
		math.clamp(math.floor(accentColor.B * 255 * 0.2 + 12), 0, 255)
	)

	local tweenIn    = TweenService:Create(bg, TweenInfo.new(0.12), { BackgroundColor3 = hoverColor })
	local tweenOut   = TweenService:Create(bg, TweenInfo.new(0.15), { BackgroundColor3 = idleColor })
	local tweenPress = TweenService:Create(bg, TweenInfo.new(0.06), { BackgroundColor3 = pressColor })
	local strokeIn   = TweenService:Create(btnStroke, TweenInfo.new(0.12), { Transparency = 0 })
	local strokeOut  = TweenService:Create(btnStroke, TweenInfo.new(0.15), { Transparency = 0.65 })

	btn.MouseEnter:Connect(function()
		tweenIn:Play()
		strokeIn:Play()
	end)
	btn.MouseLeave:Connect(function()
		tweenOut:Play()
		strokeOut:Play()
	end)
	btn.MouseButton1Down:Connect(function()
		tweenPress:Play()
	end)
	btn.MouseButton1Up:Connect(function()
		tweenIn:Play()
		onClick()
	end)

	return btn
end

-- ─── leave button builder ─────────────────────────────────────────────────────

local function buildLeaveButton(parent: Frame, order: number, onClick: () -> ()): TextButton
	local btn = Instance.new("TextButton")
	btn.Name = "LeaveBtn"
	btn.Size = UDim2.new(1, 0, 0, 34)
	btn.Text = "Leave"
	btn.BackgroundColor3 = Color3.fromRGB(18, 20, 32)
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = false
	btn.TextColor3 = TEXT_MUTED
	btn.Font = Enum.Font.Gotham
	btn.TextSize = 13
	btn.LayoutOrder = order
	btn.Parent = parent
	corner(btn, UDim.new(0, 8))
	stroke(btn, 1, BORDER, 0.3)

	local tweenIn  = TweenService:Create(btn, TweenInfo.new(0.12), {
		BackgroundColor3 = Color3.fromRGB(26, 28, 44),
		TextColor3 = TEXT_SECONDARY,
	})
	local tweenOut = TweenService:Create(btn, TweenInfo.new(0.15), {
		BackgroundColor3 = Color3.fromRGB(18, 20, 32),
		TextColor3 = TEXT_MUTED,
	})

	btn.MouseEnter:Connect(function() tweenIn:Play() end)
	btn.MouseLeave:Connect(function() tweenOut:Play() end)
	btn.MouseButton1Up:Connect(function()
		tweenOut:Play()
		onClick()
	end)

	return btn
end

-- ─── controller ───────────────────────────────────────────────────────────────

function SellBoothController.start()
	local sellItemRequestRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.SELL_ITEM_REQUEST_REMOTE)
	local sellAllRequestRemote  = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.SELL_ALL_REQUEST_REMOTE)
	local sellResultRemote      = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.SELL_RESULT_REMOTE)

	local ui = buildUI()

	local statusTicket = 0

	local function setStatus(message: string, isError: boolean)
		ui.statusLabel.Text = message
		ui.statusLabel.TextColor3 = if isError then STATUS_ERROR else STATUS_SUCCESS
		ui.statusBg.BackgroundColor3 = if isError
			then Color3.fromRGB(36, 14, 14)
			else Color3.fromRGB(14, 30, 20)
		local borderStroke = ui.statusBg:FindFirstChildWhichIsA("UIStroke")
		if borderStroke then
			borderStroke.Color = if isError then STATUS_ERROR else STATUS_SUCCESS
		end
		ui.statusFrame.Visible = true

		statusTicket += 1
		local ticket = statusTicket
		task.delay(4, function()
			if statusTicket == ticket then
				ui.statusFrame.Visible = false
			end
		end)
	end

	local function clearStatus()
		statusTicket += 1
		ui.statusFrame.Visible = false
	end

	local manuallyClosed = false
	local isOpen = false

	local function openPanel()
		if isOpen then return end
		isOpen = true
		clearStatus()
		ui.screenGui.Enabled = true
		ui.panel.Position = UDim2.new(0.5, 0, 1, 80)
		TweenService:Create(ui.panel, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Position = UDim2.new(0.5, 0, 1, -120),
		}):Play()
	end

	local function closePanel()
		if not isOpen then return end
		isOpen = false
		TweenService:Create(ui.panel, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = UDim2.new(0.5, 0, 1, 80),
		}):Play()
		task.delay(0.22, function()
			ui.screenGui.Enabled = false
		end)
	end

	-- Sell the brainrot the player is currently holding (their selected slot).
	buildSellButton(ui.body, 1, IconAssets.Cash,
		"Sell Brainrot", "Sells the brainrot you're holding",
		GREEN, GREEN_DIM, true, function()
			local heldSlot = HotbarController.getSelectedSlot()
			if not heldSlot or not HotbarController.getHotbar()[heldSlot] then
				setStatus("Not Holding Brainrot!", true)
				return
			end
			sellItemRequestRemote:FireServer(heldSlot)
		end)

	-- Sell everything.
	buildSellButton(ui.body, 2, IconAssets.Cash,
		"Sell Everything", "Sells every item across your entire hotbar",
		GOLD, GOLD_DIM, true, function()
			sellAllRequestRemote:FireServer()
		end)

	-- Leave.
	buildLeaveButton(ui.body, 3, function()
		manuallyClosed = true
		closePanel()
	end)

	sellResultRemote.OnClientEvent:Connect(function(result)
		if type(result) ~= "table" then return end

		if result.success and type(result.cashEarned) == "number" and result.cashEarned > 0 then
			spawnCashFloat(ui.screenGui, result.cashEarned)
		end

		local message = result.message
		if type(message) ~= "string" or message == "" then return end
		setStatus(message, not result.success)
	end)

	-- ─── proximity loop ───────────────────────────────────────────────────────

	local cachedSellModel: Model? = nil
	local cachedShopkeeper: Model? = nil
	local cachedAnchor: BasePart? = nil

	Workspace.DescendantAdded:Connect(function(inst: Instance)
		if inst:IsA("Model") and inst.Name == SELL_MODEL_NAME then
			cachedSellModel  = nil
			cachedShopkeeper = nil
			cachedAnchor     = nil
		end
	end)

	local function resolveAnchor(): BasePart?
		if cachedAnchor and cachedAnchor.Parent then
			return cachedAnchor
		end
		if not cachedSellModel or not cachedSellModel.Parent then
			cachedSellModel  = findSellModel()
			cachedShopkeeper = nil
		end
		if not cachedSellModel then return nil end
		if not cachedShopkeeper or not cachedShopkeeper.Parent then
			cachedShopkeeper = findShopkeeper(cachedSellModel)
		end
		local anchorModel = cachedShopkeeper or cachedSellModel
		cachedAnchor = findAnchor(anchorModel)
		return cachedAnchor
	end

	local lastCheckAt = 0

	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now - lastCheckAt < CHECK_INTERVAL_SECONDS then return end
		lastCheckAt = now

		local anchor = resolveAnchor()
		if not anchor then return end

		local root = getCharacterRoot()
		if not root then
			if isOpen then closePanel() end
			manuallyClosed = false
			return
		end

		local distance = (root.Position - anchor.Position).Magnitude

		if isOpen then
			if manuallyClosed then
				if distance > CLOSE_RADIUS_STUDS then manuallyClosed = false end
				return
			end
			if distance > CLOSE_RADIUS_STUDS then closePanel() end
			return
		end

		if manuallyClosed then
			if distance > CLOSE_RADIUS_STUDS then manuallyClosed = false end
			return
		end

		if distance <= OPEN_RADIUS_STUDS then openPanel() end
	end)
end

return SellBoothController
