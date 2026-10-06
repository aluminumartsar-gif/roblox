local TweenService = game:GetService("TweenService")

-- Shared RNG text styling. Maps an `rngDenominator` (i.e. the "N" in 1/N
-- odds) onto a per-tier UIGradient + optional rotation so the placard,
-- index, and inventory all show the same progression: white at the bottom,
-- subtle blue tints in the middle, and a full cosmic rainbow at the top.
--
-- Apply on any TextLabel that displays an RNG row; the helper is a no-op
-- below the lowest tier so plain rolls keep their owner's default color.
local RngTextStyle = {}

type RngTier = {
	minDenominator: number,
	gradient: ColorSequence,
	rotationSpeedDeg: number?,
	strokeTransparency: number?,
	strokeColor: Color3?,
}

local RNG_TIERS: { RngTier } = {
	-- "Cool blue" tier (100-999). Static so it reads as a calm rare badge
	-- rather than competing with the variant row's animation.
	{
		minDenominator = 100,
		gradient = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(170, 230, 255)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 255, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(110, 180, 255)),
		}),
	},
	-- "Violet" tier (1K-9K). Slow rotation introduces motion; the magenta
	-- shoulder reads as "stepping up from blue" toward the pink endgame.
	{
		minDenominator = 1_000,
		gradient = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(140, 120, 255)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(230, 200, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 130, 220)),
		}),
		rotationSpeedDeg = 90,
	},
	-- "Gold" tier (10K-99K). Warm shimmer evokes a legendary stamp without
	-- borrowing the variant Gold gradient verbatim; the lighter midpoint
	-- keeps the row legible against bright skyboxes.
	{
		minDenominator = 10_000,
		gradient = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 220, 110)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 250, 200)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 150, 60)),
		}),
		rotationSpeedDeg = 150,
	},
	-- "Aqua/Pink" tier (100K-999K). Preserves the original cyan→white→pink
	-- rainbow that earned the "blue and pink RNG text" love; lives at the
	-- Brainrot God band.
	{
		minDenominator = 100_000,
		gradient = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(80, 255, 255)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 255, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 64, 210)),
		}),
		rotationSpeedDeg = 225,
		strokeTransparency = 0.05,
	},
	-- "Prism" tier (1M-9M). Full hue sweep marks Secret-band drops; faster
	-- spin makes the row noticeably more alive than the Brainrot God tier.
	{
		minDenominator = 1_000_000,
		gradient = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 90, 90)),
			ColorSequenceKeypoint.new(0.2, Color3.fromRGB(255, 200, 90)),
			ColorSequenceKeypoint.new(0.4, Color3.fromRGB(120, 255, 140)),
			ColorSequenceKeypoint.new(0.6, Color3.fromRGB(80, 220, 255)),
			ColorSequenceKeypoint.new(0.8, Color3.fromRGB(180, 120, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 100, 220)),
		}),
		rotationSpeedDeg = 300,
		strokeTransparency = 0,
	},
	-- "Cosmic" tier (10M+). Galaxy-style deep purples + black-ink stroke
	-- so the rarest secrets read as otherworldly even at a glance.
	{
		minDenominator = 10_000_000,
		gradient = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 80, 200)),
			ColorSequenceKeypoint.new(0.25, Color3.fromRGB(190, 140, 255)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 255, 255)),
			ColorSequenceKeypoint.new(0.75, Color3.fromRGB(80, 200, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 80, 255)),
		}),
		rotationSpeedDeg = 380,
		strokeTransparency = 0,
		strokeColor = Color3.fromRGB(20, 0, 40),
	},
}

local function resolveTier(denominator: number?): RngTier?
	local resolved = tonumber(denominator) or 0
	for index = #RNG_TIERS, 1, -1 do
		local tier = RNG_TIERS[index]
		if resolved >= tier.minDenominator then
			return tier
		end
	end
	return nil
end

local function spinGradient(gradient: UIGradient, degreesPerSecond: number)
	if degreesPerSecond <= 0 then
		return
	end

	local duration = 360 / degreesPerSecond
	task.spawn(function()
		while gradient.Parent do
			local tween = TweenService:Create(
				gradient,
				TweenInfo.new(duration, Enum.EasingStyle.Linear),
				{ Rotation = gradient.Rotation + 360 }
			)
			tween:Play()
			tween.Completed:Wait()
		end
	end)
end

-- Applies the tiered gradient + optional rotation/stroke overrides for the
-- given RNG denominator. No-op when the denominator is below the lowest
-- tier so plain rolls keep their default color.
--
-- When a tier matches we force `TextColor3 = white` so the gradient renders
-- with its authored colors instead of being multiplied by the label's prior
-- tint (e.g. the inventory's lime ACCENT).
function RngTextStyle.apply(label: TextLabel, denominator: number?)
	local tier = resolveTier(denominator)
	if not tier then
		return
	end

	label.TextColor3 = Color3.new(1, 1, 1)

	if tier.strokeColor then
		label.TextStrokeColor3 = tier.strokeColor
		local stroke = label:FindFirstChildWhichIsA("UIStroke")
		if stroke then
			stroke.Color = tier.strokeColor
		end
	end
	if tier.strokeTransparency then
		label.TextStrokeTransparency = tier.strokeTransparency
	end

	local gradient = Instance.new("UIGradient")
	gradient.Color = tier.gradient
	gradient.Parent = label

	if tier.rotationSpeedDeg and tier.rotationSpeedDeg > 0 then
		spinGradient(gradient, tier.rotationSpeedDeg)
	end
end

return RngTextStyle
