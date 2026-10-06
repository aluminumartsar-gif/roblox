local VariantConfig = {}

VariantConfig.NORMAL_ID = "Normal"

export type ParticleConfig = {
	textureId: string,
	color: ColorSequence,
	rate: number,
	size: NumberSequence,
	lifetime: NumberRange,
	speed: NumberRange?,
	rotSpeed: NumberRange?,
	lightEmission: number?,
	transparency: NumberSequence?,
	acceleration: Vector3?,
}

export type HighlightConfig = {
	fillColor: Color3?,
	fillTransparency: number?,
	outlineColor: Color3?,
	outlineTransparency: number?,
}

export type VariantEntry = {
	id: string,
	displayName: string,
	weight: number,
	rarityRank: number,
	valueMultiplier: number,
	glowColor: Color3?,
	glowBrightness: number?,
	glowRange: number?,
	rainbowGlow: boolean?,
	particle: ParticleConfig?,
	secondaryParticle: ParticleConfig?,
	materialOverride: Enum.Material?,
	bodyColor: Color3?,
	rainbowBody: boolean?,
	highlight: HighlightConfig?,
	nameColor: Color3,
}

local function transparencyFadeOut()
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
end

local function bellSize(start: number, peak: number)
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, start),
		NumberSequenceKeypoint.new(0.4, peak),
		NumberSequenceKeypoint.new(1, 0),
	})
end

VariantConfig.Pool = {
	{
		id = "Normal",
		displayName = "Normal",
		weight = 855,
		rarityRank = 1,
		valueMultiplier = 1.0,
		nameColor = Color3.fromRGB(248, 244, 240),
	},
	{
		id = "Gold",
		displayName = "Gold",
		weight = 100,
		rarityRank = 2,
		valueMultiplier = 1.5,
		bodyColor = Color3.fromRGB(255, 215, 80),
		materialOverride = Enum.Material.Foil,
		highlight = {
			fillColor = Color3.fromRGB(255, 220, 110),
			fillTransparency = 0.6,
			outlineColor = Color3.fromRGB(255, 240, 150),
			outlineTransparency = 0.05,
		},
		particle = {
			textureId = "rbxasset://textures/particles/sparkles_main.dds",
			color = ColorSequence.new(Color3.fromRGB(255, 215, 0), Color3.fromRGB(255, 240, 150)),
			rate = 7,
			size = bellSize(0.15, 0.4),
			lifetime = NumberRange.new(0.5, 1.0),
			speed = NumberRange.new(0.4, 1.0),
			rotSpeed = NumberRange.new(-90, 90),
			lightEmission = 0.6,
			transparency = transparencyFadeOut(),
		},
		nameColor = Color3.fromRGB(255, 215, 0),
	},
	{
		id = "Diamond",
		displayName = "Diamond",
		weight = 30,
		rarityRank = 3,
		valueMultiplier = 2.0,
		bodyColor = Color3.fromRGB(110, 210, 255),
		materialOverride = Enum.Material.Foil,
		highlight = {
			fillColor = Color3.fromRGB(170, 230, 255),
			fillTransparency = 0.85,
			outlineColor = Color3.fromRGB(210, 245, 255),
			outlineTransparency = 0.05,
		},
		particle = {
			textureId = "rbxasset://textures/particles/sparkles_main.dds",
			color = ColorSequence.new(Color3.fromRGB(180, 235, 255), Color3.fromRGB(255, 255, 255)),
			rate = 8,
			size = bellSize(0.14, 0.38),
			lifetime = NumberRange.new(0.6, 1.1),
			speed = NumberRange.new(0.4, 1.0),
			rotSpeed = NumberRange.new(-120, 120),
			lightEmission = 0.7,
			transparency = transparencyFadeOut(),
		},
		nameColor = Color3.fromRGB(150, 230, 255),
	},
	{
		id = "Lava",
		displayName = "Lava",
		weight = 10,
		rarityRank = 4,
		valueMultiplier = 3.0,
		bodyColor = Color3.fromRGB(190, 65, 20),
		materialOverride = Enum.Material.CrackedLava,
		glowColor = Color3.fromRGB(255, 100, 30),
		glowBrightness = 3,
		glowRange = 16,
		highlight = {
			fillColor = Color3.fromRGB(255, 120, 40),
			fillTransparency = 0.72,
			outlineColor = Color3.fromRGB(255, 160, 60),
			outlineTransparency = 0.05,
		},
		particle = {
			textureId = "rbxasset://textures/particles/fire_main.dds",
			color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 220, 80)),
				ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 110, 30)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 30, 10)),
			}),
			rate = 18,
			size = bellSize(0.25, 0.7),
			lifetime = NumberRange.new(0.7, 1.4),
			speed = NumberRange.new(1.5, 3),
			rotSpeed = NumberRange.new(-60, 60),
			lightEmission = 0.9,
			transparency = transparencyFadeOut(),
			acceleration = Vector3.new(0, 4, 0),
		},
		secondaryParticle = {
			textureId = "rbxasset://textures/particles/smoke_main.dds",
			color = ColorSequence.new(Color3.fromRGB(80, 40, 30)),
			rate = 5,
			size = bellSize(0.4, 1.1),
			lifetime = NumberRange.new(1.2, 2),
			speed = NumberRange.new(0.6, 1.4),
			rotSpeed = NumberRange.new(-30, 30),
			lightEmission = 0.05,
			transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.55),
				NumberSequenceKeypoint.new(1, 1),
			}),
			acceleration = Vector3.new(0, 2, 0),
		},
		nameColor = Color3.fromRGB(255, 130, 50),
	},
	{
		id = "Rainbow",
		displayName = "Rainbow",
		weight = 3,
		rarityRank = 5,
		valueMultiplier = 5.0,
		rainbowBody = true,
		materialOverride = Enum.Material.Foil,
		highlight = {
			-- Initial colors are placeholders; the rainbow heartbeat overwrites
			-- FillColor and OutlineColor each frame.
			fillColor = Color3.fromRGB(255, 255, 255),
			fillTransparency = 0.85,
			outlineColor = Color3.fromRGB(255, 255, 255),
			outlineTransparency = 0.05,
		},
		particle = {
			textureId = "rbxasset://textures/particles/sparkles_main.dds",
			color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 80, 80)),
				ColorSequenceKeypoint.new(0.2, Color3.fromRGB(255, 200, 80)),
				ColorSequenceKeypoint.new(0.4, Color3.fromRGB(120, 255, 120)),
				ColorSequenceKeypoint.new(0.6, Color3.fromRGB(80, 200, 255)),
				ColorSequenceKeypoint.new(0.8, Color3.fromRGB(180, 120, 255)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 100, 220)),
			}),
			rate = 12,
			size = bellSize(0.18, 0.5),
			lifetime = NumberRange.new(0.7, 1.4),
			speed = NumberRange.new(0.8, 1.8),
			rotSpeed = NumberRange.new(-180, 180),
			lightEmission = 0.75,
			transparency = transparencyFadeOut(),
		},
		nameColor = Color3.fromRGB(255, 180, 220),
	},
	{
		id = "Galaxy",
		displayName = "Galaxy",
		weight = 1,
		rarityRank = 6,
		valueMultiplier = 10.0,
		bodyColor = Color3.fromRGB(45, 25, 100),
		materialOverride = Enum.Material.Foil,
		highlight = {
			fillColor = Color3.fromRGB(150, 110, 240),
			fillTransparency = 0.85,
			outlineColor = Color3.fromRGB(200, 160, 255),
			outlineTransparency = 0.05,
		},
		particle = {
			textureId = "rbxasset://textures/particles/sparkles_main.dds",
			color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(190, 140, 255)),
				ColorSequenceKeypoint.new(0.5, Color3.fromRGB(120, 80, 220)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(40, 20, 90)),
			}),
			rate = 14,
			size = bellSize(0.18, 0.45),
			lifetime = NumberRange.new(0.9, 1.8),
			speed = NumberRange.new(0.6, 1.4),
			rotSpeed = NumberRange.new(-200, 200),
			lightEmission = 0.85,
			transparency = transparencyFadeOut(),
		},
		secondaryParticle = {
			textureId = "rbxasset://textures/particles/sparkles_main.dds",
			color = ColorSequence.new(Color3.fromRGB(255, 255, 255)),
			rate = 8,
			size = bellSize(0.08, 0.22),
			lifetime = NumberRange.new(1.4, 2.5),
			speed = NumberRange.new(0.2, 0.6),
			rotSpeed = NumberRange.new(-40, 40),
			lightEmission = 1,
			transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.4),
				NumberSequenceKeypoint.new(0.5, 0.1),
				NumberSequenceKeypoint.new(1, 1),
			}),
		},
		nameColor = Color3.fromRGB(180, 130, 255),
	},
	{
		id = "Bloodrot",
		displayName = "Bloodrot",
		weight = 0.7,
		rarityRank = 7,
		valueMultiplier = 20.0,
		bodyColor = Color3.fromRGB(75, 10, 10),
		materialOverride = Enum.Material.Slate,
		highlight = {
			fillColor = Color3.fromRGB(180, 25, 25),
			fillTransparency = 0.85,
			outlineColor = Color3.fromRGB(220, 50, 50),
			outlineTransparency = 0.05,
		},
		particle = {
			textureId = "rbxasset://textures/particles/smoke_main.dds",
			color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(140, 0, 0)),
				ColorSequenceKeypoint.new(0.6, Color3.fromRGB(80, 0, 0)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(20, 0, 0)),
			}),
			rate = 10,
			size = bellSize(0.3, 0.85),
			lifetime = NumberRange.new(1, 2),
			speed = NumberRange.new(0.4, 1),
			rotSpeed = NumberRange.new(-40, 40),
			lightEmission = 0.3,
			transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.3),
				NumberSequenceKeypoint.new(1, 1),
			}),
			acceleration = Vector3.new(0, -1.5, 0),
		},
		secondaryParticle = {
			textureId = "rbxasset://textures/particles/sparkles_main.dds",
			color = ColorSequence.new(Color3.fromRGB(255, 30, 30)),
			rate = 6,
			size = bellSize(0.13, 0.32),
			lifetime = NumberRange.new(0.5, 1.0),
			speed = NumberRange.new(0.5, 1.2),
			rotSpeed = NumberRange.new(-100, 100),
			lightEmission = 0.85,
			transparency = transparencyFadeOut(),
		},
		nameColor = Color3.fromRGB(220, 50, 50),
	},
	{
		id = "Candy",
		displayName = "Candy",
		weight = 0.3,
		rarityRank = 8,
		valueMultiplier = 50.0,
		bodyColor = Color3.fromRGB(255, 145, 215),
		materialOverride = Enum.Material.SmoothPlastic,
		highlight = {
			fillColor = Color3.fromRGB(255, 200, 235),
			fillTransparency = 0.85,
			outlineColor = Color3.fromRGB(255, 220, 245),
			outlineTransparency = 0.05,
		},
		particle = {
			textureId = "rbxasset://textures/particles/sparkles_main.dds",
			color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 180, 230)),
				ColorSequenceKeypoint.new(0.5, Color3.fromRGB(150, 230, 255)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 240, 180)),
			}),
			rate = 16,
			size = bellSize(0.2, 0.55),
			lifetime = NumberRange.new(0.8, 1.6),
			speed = NumberRange.new(0.8, 1.6),
			rotSpeed = NumberRange.new(-220, 220),
			lightEmission = 0.85,
			transparency = transparencyFadeOut(),
		},
		secondaryParticle = {
			textureId = "rbxasset://textures/particles/sparkles_main.dds",
			color = ColorSequence.new(Color3.fromRGB(255, 255, 255)),
			rate = 8,
			size = bellSize(0.09, 0.25),
			lifetime = NumberRange.new(0.6, 1.2),
			speed = NumberRange.new(0.4, 1),
			rotSpeed = NumberRange.new(-60, 60),
			lightEmission = 1,
			transparency = transparencyFadeOut(),
		},
		nameColor = Color3.fromRGB(255, 170, 220),
	},
}

VariantConfig.Variants = {}
for _, entry in VariantConfig.Pool do
	VariantConfig.Variants[entry.id] = entry
end

function VariantConfig.getById(variantId: string?): VariantEntry
	if type(variantId) ~= "string" then
		return VariantConfig.Variants[VariantConfig.NORMAL_ID]
	end

	return VariantConfig.Variants[variantId] or VariantConfig.Variants[VariantConfig.NORMAL_ID]
end

function VariantConfig.isKnown(variantId: string?): boolean
	return type(variantId) == "string" and VariantConfig.Variants[variantId] ~= nil
end

function VariantConfig.getValueMultiplier(variantId: string?): number
	local entry = VariantConfig.getById(variantId)
	return entry.valueMultiplier or 1
end

function VariantConfig.getDisplayName(variantId: string?): string
	return VariantConfig.getById(variantId).displayName
end

function VariantConfig.getNameColor(variantId: string?): Color3
	return VariantConfig.getById(variantId).nameColor
end

local cachedTotalWeight: number? = nil

function VariantConfig.getTotalWeight(): number
	if cachedTotalWeight then
		return cachedTotalWeight
	end

	local total = 0
	for _, entry in VariantConfig.Pool do
		total += entry.weight
	end

	cachedTotalWeight = total
	return total
end

-- Returns N such that 1/N is the probability of rolling this variant on any
-- given roll. Normal returns 1 so callers can multiply by a brainrot's base
-- denominator without inflating the displayed odds when no variant applies.
function VariantConfig.getOddsDenominator(variantId: string?): number
	if variantId == nil or variantId == VariantConfig.NORMAL_ID then
		return 1
	end

	local entry = VariantConfig.Variants[variantId]
	if not entry or entry.weight <= 0 then
		return 1
	end

	return VariantConfig.getTotalWeight() / entry.weight
end

function VariantConfig.hasVariant(variantId: string?): boolean
	return type(variantId) == "string"
		and variantId ~= ""
		and variantId ~= VariantConfig.NORMAL_ID
		and VariantConfig.Variants[variantId] ~= nil
end

local function getEffectiveWeight(entry: VariantEntry, luckMultiplier: number)
	if luckMultiplier <= 1 then
		return entry.weight
	end

	-- Mirrors BrainrotConfig.getEffectiveWeight: rarer entries (higher rank)
	-- gain more weight as luck rises, while Normal stays flat.
	return entry.weight * (1 + (entry.rarityRank - 1) * (luckMultiplier - 1))
end

function VariantConfig.rollRandom(randomObject: Random?, rollContext: { luckMultiplier: number? }?): VariantEntry
	local rng = randomObject or Random.new()
	local luckMultiplier = if type(rollContext) == "table" then tonumber(rollContext.luckMultiplier) or 1 else 1
	local totalWeight = 0

	for _, entry in VariantConfig.Pool do
		totalWeight += getEffectiveWeight(entry, luckMultiplier)
	end

	local pick = rng:NextNumber(0, totalWeight)
	local running = 0

	for _, entry in VariantConfig.Pool do
		running += getEffectiveWeight(entry, luckMultiplier)
		if pick <= running then
			return entry
		end
	end

	return VariantConfig.Variants[VariantConfig.NORMAL_ID]
end

return VariantConfig
