local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local IconAssets = require(ConfigFolder:WaitForChild("IconAssets"))
local FormatUtil = require(UtilFolder:WaitForChild("FormatUtil"))

local UpgradePurchaseVFX = {}

local KACHING_SOUND_ID = "rbxassetid://7112275565"

local LABEL_COLOR = Color3.fromRGB(255, 226, 80)
local LABEL_STROKE = Color3.fromRGB(46, 120, 64)
local COIN_GREEN = Color3.fromRGB(120, 235, 130)
local COIN_GOLD = Color3.fromRGB(255, 206, 70)

local function playKaChing()
	local sound = Instance.new("Sound")
	sound.SoundId = KACHING_SOUND_ID
	sound.Volume = 0.5
	sound.Parent = SoundService
	sound:Play()
	local lifetime = if sound.TimeLength > 0 then sound.TimeLength + 0.35 else 2.5
	Debris:AddItem(sound, lifetime)
end

local function coinCountForAmount(amount: number): number
	local magnitude = math.log10(math.max(amount, 10))
	return math.clamp(math.floor(9 + magnitude * 2.5), 10, 22)
end

-- Full-screen overlay on the upgrade popup: bill/coin burst + spent-cash pulse.
function UpgradePurchaseVFX.play(screenGui: ScreenGui, amount: number)
	if not screenGui or not screenGui.Parent then
		return
	end

	local host = Instance.new("Frame")
	host.Name = "UpgradeCashBurst"
	host.BackgroundTransparency = 1
	host.BorderSizePixel = 0
	host.Size = UDim2.fromScale(1, 1)
	host.Position = UDim2.fromScale(0, 0)
	host.ZIndex = 500
	host.Parent = screenGui

	playKaChing()

	local cx = 0.5
	local cy = 0.36

	if typeof(amount) == "number" and amount > 0 then
		local label = Instance.new("TextLabel")
		label.Name = "SpendFlash"
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.new(cx, 0, cy, 0)
		label.Size = UDim2.fromOffset(380, 80)
		label.BackgroundTransparency = 1
		label.Text = ("-%s"):format(FormatUtil.money(amount))
		label.TextColor3 = LABEL_COLOR
		label.Font = Enum.Font.GothamBlack
		label.TextSize = 44
		label.TextStrokeColor3 = LABEL_STROKE
		label.TextStrokeTransparency = 0
		label.ZIndex = 502
		label.Parent = host

		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2.5
		stroke.Color = LABEL_STROKE
		stroke.Transparency = 0.05
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		stroke.Parent = label

		local uiScale = Instance.new("UIScale")
		uiScale.Scale = 0.2
		uiScale.Parent = label

		TweenService:Create(uiScale, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Scale = 1.12,
		}):Play()
		task.delay(0.28, function()
			if uiScale.Parent then
				TweenService:Create(uiScale, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Scale = 1,
				}):Play()
			end
		end)

		local hold = 0.55
		task.delay(hold, function()
			if not label.Parent then
				return
			end
			local fade = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			TweenService:Create(label, fade, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
			TweenService:Create(stroke, fade, { Transparency = 1 }):Play()
		end)
	end

	local n = coinCountForAmount(if typeof(amount) == "number" then amount else 0)
	for i = 1, n do
		task.delay((i - 1) * 0.032, function()
			if not host.Parent then
				return
			end

			local coin = Instance.new("ImageLabel")
			coin.Name = "BurstCoin"
			coin.AnchorPoint = Vector2.new(0.5, 0.5)
			coin.Position = UDim2.new(cx, math.random(-55, 55), cy, math.random(-35, 35))
			coin.Size = UDim2.fromOffset(30, 30)
			coin.BackgroundTransparency = 1
			coin.Image = IconAssets.Cash
			coin.ImageColor3 = if math.random() < 0.5 then COIN_GREEN else COIN_GOLD
			coin.ZIndex = 501
			coin.Parent = host

			local cs = Instance.new("UIScale")
			cs.Scale = 0
			cs.Parent = coin
			TweenService:Create(cs, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
				Scale = 1,
			}):Play()

			local angle = (i / n) * math.pi * 2 + (math.random() - 0.5) * 0.85
			local spreadX = math.cos(angle) * (0.17 + math.random() * 0.11)
			local spreadY = -math.random(55, 115) / 300 - math.abs(math.sin(angle)) * 0.06
			local dur = 0.75 + math.random() * 0.35

			TweenService:Create(coin, TweenInfo.new(dur, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Position = UDim2.new(cx + spreadX, math.random(-28, 28), cy + spreadY, math.random(-15, 15)),
			}):Play()

			task.delay(dur * 0.35, function()
				if coin.Parent then
					TweenService:Create(coin, TweenInfo.new(dur * 0.65, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
						ImageTransparency = 1,
					}):Play()
				end
			end)
		end)
	end

	Debris:AddItem(host, 2.1)
end

return UpgradePurchaseVFX
