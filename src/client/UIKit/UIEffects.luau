local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Players          = game:GetService("Players")

local CLICK_EFFECT = {
	MinStars    = 4,
	MaxStars    = 6,
	MinSize     = 6,
	MaxSize     = 25,
	MinDistance = 30,
	MaxDistance = 60,
	Duration    = 0.4,
	Color       = Color3.fromRGB(255, 255, 255),
	StarChar    = "★",
}

local LOCAL_PLAYER = Players.LocalPlayer
local TWEEN_INFO   = TweenInfo.new(CLICK_EFFECT.Duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWO_PI       = math.pi * 2

local effectGui               = Instance.new("ScreenGui")
effectGui.Name                = "UIEffectsGui"
effectGui.ResetOnSpawn        = false
effectGui.IgnoreGuiInset      = true
effectGui.ZIndexBehavior      = Enum.ZIndexBehavior.Sibling
effectGui.DisplayOrder        = 10
effectGui.Parent              = LOCAL_PLAYER.PlayerGui

local function randomRange(min: number, max: number): number
	return min + math.random() * (max - min)
end

local function spawnStarEffect(position: Vector2)
	local starCount = math.random(CLICK_EFFECT.MinStars, CLICK_EFFECT.MaxStars)
	for i = 1, starCount do
		local angle    = ((i / starCount) * TWO_PI) + randomRange(-0.3, 0.3)
		local distance = randomRange(CLICK_EFFECT.MinDistance, CLICK_EFFECT.MaxDistance)
		local size     = randomRange(CLICK_EFFECT.MinSize, CLICK_EFFECT.MaxSize)
		local targetX  = position.X + math.cos(angle) * distance
		local targetY  = position.Y + math.sin(angle) * distance

		local star                   = Instance.new("TextLabel")
		star.Name                    = "ClickStar"
		star.AnchorPoint             = Vector2.new(0.5, 0.5)
		star.Position                = UDim2.fromOffset(position.X, position.Y)
		star.Size                    = UDim2.fromOffset(size, size)
		star.BackgroundTransparency  = 1
		star.Text                    = CLICK_EFFECT.StarChar
		star.TextColor3              = CLICK_EFFECT.Color
		star.TextScaled              = true
		star.Font                    = Enum.Font.GothamBold
		star.TextTransparency        = 0
		star.ZIndex                  = 999
		star.Parent                  = effectGui

		local moveTween = TweenService:Create(star, TWEEN_INFO, { Position = UDim2.fromOffset(targetX, targetY) })
		local fadeTween = TweenService:Create(star, TWEEN_INFO, { TextTransparency = 1 })
		moveTween:Play()
		fadeTween:Play()
		moveTween.Completed:Connect(function()
			star:Destroy()
		end)
	end
end

UserInputService.InputBegan:Connect(function(input: InputObject, _gameProcessed: boolean)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		spawnStarEffect(UserInputService:GetMouseLocation())
	end
end)

return {}
