local BrainrotConfig = {}

local EconomyConfig = require(script.Parent:WaitForChild("EconomyConfig"))
local VariantConfig = require(script.Parent:WaitForChild("VariantConfig"))

local RARITY_DATA = {
	Common = {
		rank = 1,
		color = Color3.fromRGB(166, 255, 184),
		revealColor = Color3.fromRGB(166, 255, 184),
	},
	Rare = {
		rank = 2,
		color = Color3.fromRGB(154, 212, 255),
		revealColor = Color3.fromRGB(154, 212, 255),
	},
	Epic = {
		rank = 3,
		color = Color3.fromRGB(218, 166, 255),
		revealColor = Color3.fromRGB(218, 166, 255),
	},
	Legendary = {
		rank = 4,
		color = Color3.fromRGB(255, 191, 92),
		revealColor = Color3.fromRGB(255, 191, 92),
	},
	Mythic = {
		rank = 5,
		color = Color3.fromRGB(255, 96, 96),
		revealColor = Color3.fromRGB(255, 96, 96),
	},
	["Brainrot God"] = {
		rank = 6,
		color = Color3.fromRGB(255, 64, 210),
		revealColor = Color3.fromRGB(255, 64, 210),
	},
	Secret = {
		rank = 7,
		color = Color3.fromRGB(80, 255, 255),
		revealColor = Color3.fromRGB(80, 255, 255),
	},
}

local function getDefaultWeight(baseValue: number)
	return 1 / math.max(1, baseValue)
end

-- `idleAnimationId` is optional and consumed by `BrainrotVisualFactory`. Accepts a
-- bare numeric id (`"12345678"` / `12345678`) or a fully qualified
-- `rbxassetid://12345678` string. Leave nil to fall back to the
-- `DefaultIdleAnimationId` attribute on the `ReplicatedStorage.Brainrots` folder.
local function entry(
	id: string,
	rarity: string,
	baseValue: number,
	weightOverride: number?,
	idleAnimationId: (string | number)?
)
	local rarityData = RARITY_DATA[rarity]

	return {
		id = id,
		-- Keep default roll odds tied to the displayed RNG denominator.
		weight = weightOverride or getDefaultWeight(baseValue),
		color = rarityData.color,
		rarity = rarity,
		rarityRank = rarityData.rank,
		baseValue = baseValue,
		revealColor = rarityData.revealColor,
		idleAnimationId = idleAnimationId,
	}
end

local function formatInteger(value: number)
	local text = tostring(math.floor(value))
	local result = text

	while true do
		local updated, replacements = result:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
		result = updated
		if replacements == 0 then
			break
		end
	end

	return result
end

BrainrotConfig.Pool = {
	entry("Noobini Pizzanini", "Common", 1),
	entry("Lirilì Larilà", "Common", 3),
	entry("Tim Cheese", "Common", 5),
	entry("Fluriflura", "Common", 7),
	entry("Talpa Di Fero", "Common", 9),
	entry("Svinina Bombardino", "Common", 10),
	entry("Pipi Kiwi", "Common", 13),
	entry("Pipi Corni", "Common", 14),

	entry("Trippi Troppi", "Rare", 15),
	entry("Gangster Footera", "Rare", 30),
	entry("Bandito Bobritto", "Rare", 35),
	entry("Boneca Ambalabu", "Rare", 40),
	entry("Cacto Hipopotamo", "Rare", 50),
	entry("Ta Ta Ta Ta Sahur", "Rare", 55),
	entry("Tric Trac Baraboom", "Rare", 65),
	entry("Pipi Avocado", "Rare", 70),

	entry("Cappuccino Assassino", "Epic", 75),
	entry("Brr Brr Patapim", "Epic", 100),
	entry("Trulimero Trulicina", "Epic", 125),
	entry("Bambini Crostini", "Epic", 135),
	entry("Bananita Dolphinita", "Epic", 150),
	entry("Perochello Lemonchello", "Epic", 160),
	entry("Brri Brri Bicus Dicus Bombicus", "Epic", 175),
	entry("Avocadini Guffo", "Epic", 225),
	entry("Ti Ti Ti Sahur", "Epic", 225),
	entry("Salamino Penguino", "Epic", 250),
	entry("Penguino Cocosino", "Epic", 300),

	entry("Chimpanzini Bananini", "Legendary", 300),
	entry("Ballerina Cappuccina", "Legendary", 500),
	entry("Burbaloni Loliloli", "Legendary", 600),
	entry("Chef Crabracadabra", "Legendary", 600),
	entry("Lionel Cactuseli", "Legendary", 650),
	entry("Glorbo Fruttodrillo", "Legendary", 750),
	entry("Blueberrinni Octopusini", "Legendary", 1000),
	entry("Strawberrelli Flamingelli", "Legendary", 1100),
	entry("Cocosini Mama", "Legendary", 1200),
	entry("Pandaccini Bananini", "Legendary", 1250),
	entry("Pi Pi Watermelon", "Legendary", 1300),
	entry("Sigma Boy", "Legendary", 1350),

	entry("Frigo Camelo", "Mythic", 1900),
	entry("Orangutini Ananassini", "Mythic", 2000),
	entry("Rhino Toasterino", "Mythic", 2100),
	entry("Bombardiro Crocodilo", "Mythic", 2500),
	entry("Spioniro Golubiro", "Mythic", 3500),
	entry("Bombombini Gusini", "Mythic", 5000),
	entry("Zibra Zubra Zibralini", "Mythic", 6000),
	entry("Tigrilini Watermelini", "Mythic", 6500),
	entry("Avocadorilla", "Mythic", 7000),
	entry("Cavallo Virtuoso", "Mythic", 7500),
	entry("Gorillo Watermelondrillo", "Mythic", 8000),
	entry("Ganganzelli Trulala", "Mythic", 9000),

	entry("Cocofanto Elefanto", "Brainrot God", 17500),
	entry("Girafa Celestre", "Brainrot God", 20000),
	entry("Gattatino Neonino", "Brainrot God", 35000),
	entry("Matteo", "Brainrot God", 50000),
	entry("Tralalero Tralala", "Brainrot God", 50000),
	entry("Los Crocodillitos", "Brainrot God", 55000),
	entry("Tigroligre Frutonni", "Brainrot God", 60000),
	entry("Odin Din Din Dun", "Brainrot God", 75000),
	entry("Statutino Libertino", "Brainrot God", 75000),
	entry("Tukanno Bananno", "Brainrot God", 100000),
	entry("Espresso Signora", "Brainrot God", 70000),
	entry("Orcalero Orcala", "Brainrot God", 100000),
	entry("Trenostruzzo Turbo 3000", "Brainrot God", 150000),
	entry("Trippi Troppi Troppa Trippa", "Brainrot God", 175000),
	entry("Ballerino Lololo", "Brainrot God", 200000),
	entry("Los Tungtungtungcitos", "Brainrot God", 210000),
	entry("Piccione Macchina", "Brainrot God", 225000),

	entry("La Vacca Saturno Saturnita", "Secret", 300000),
	entry("Agarrini la Palini", "Secret", 425000),
	entry("Chimpanzini Spiderini", "Secret", 325000),
	entry("Los Tralaleritos", "Secret", 500000),
	entry("Torrtuginni Dragonfrutini", "Secret", 350000),
	entry("Las Tralaleritas", "Secret", 650000),
	entry("Las Vaquitas Saturnitas", "Secret", 750000),
	entry("Graipuss Medussi", "Secret", 1000000),
	entry("Tung Tung Tung Sahur", "Secret", 1500000),
	entry("Pot Hotspot", "Secret", 2500000),
	entry("Chicleteira Bicicleteira", "Secret", 3500000),
	entry("La Grande Combinasion", "Secret", 10000000),
	entry("Los Combinasionas", "Secret", 15000000),
	entry("Nuclearo Dinossauro", "Secret", 15000000),
	entry("Garama and Madundung", "Secret", 50000000),
	entry("Dragon Cannelloni", "Secret", 100000000),
}

local entriesById = {}

for _, entry in BrainrotConfig.Pool do
	entriesById[entry.id] = entry
end

function BrainrotConfig.getById(brainrotId: string)
	return entriesById[brainrotId]
end

function BrainrotConfig.getIdleAnimationId(brainrotId: string): (string | number)?
	local found = entriesById[brainrotId]
	return if found then found.idleAnimationId else nil
end

function BrainrotConfig.getRevealData(brainrotId: string, variantId: string?)
	local entry = BrainrotConfig.getById(brainrotId)
	if not entry then
		return {
			rarity = "Unknown",
			rarityRank = 1,
			baseValue = 0,
			rngDenominator = 1,
			rngText = "1/1",
			variantId = variantId or VariantConfig.NORMAL_ID,
			color = Color3.new(1, 1, 1),
			revealColor = Color3.new(1, 1, 1),
		}
	end

	-- Combine the brainrot's base RNG denominator with the variant's odds so
	-- a Rainbow Tim Cheese reads "1/1666" instead of repeating Tim Cheese's
	-- base "1/5". Normal returns 1x, leaving the displayed odds untouched.
	local resolvedVariantId = variantId or VariantConfig.NORMAL_ID
	local variantDenominator = VariantConfig.getOddsDenominator(resolvedVariantId)
	local combinedDenominator = entry.baseValue * variantDenominator

	return {
		rarity = entry.rarity,
		rarityRank = entry.rarityRank,
		baseValue = entry.baseValue,
		rngDenominator = combinedDenominator,
		rngText = BrainrotConfig.formatRngOdds(combinedDenominator),
		variantId = resolvedVariantId,
		color = entry.color,
		revealColor = entry.revealColor,
	}
end

function BrainrotConfig.formatRngOdds(denominator: number)
	return ("1/%s"):format(formatInteger(math.max(1, denominator or 1)))
end

function BrainrotConfig.getValue(brainrotId: string, level: number, variantId: string?)
	local entry = BrainrotConfig.getById(brainrotId)
	if not entry then
		return 0
	end

	local safeLevel = math.max(1, level or 1)
	local levelMultiplier = 1 + (safeLevel - 1) * EconomyConfig.LEVEL_VALUE_MULTIPLIER
	local rarityMultiplier = 1 + (entry.rarityRank - 1) * EconomyConfig.RARITY_VALUE_MULTIPLIER
	local variantMultiplier = VariantConfig.getValueMultiplier(variantId)

	return math.max(
		1,
		math.floor(entry.baseValue * EconomyConfig.BRAINROT_VALUE_MULTIPLIER * levelMultiplier * rarityMultiplier * variantMultiplier)
	)
end

local function getEffectiveWeight(entry, luckMultiplier: number)
	if luckMultiplier <= 1 then
		return entry.weight
	end

	return entry.weight * (1 + (entry.rarityRank - 1) * (luckMultiplier - 1))
end

function BrainrotConfig.rollRandom(randomObject: Random?, rollContext)
	local rng = randomObject or Random.new()
	local luckMultiplier = if type(rollContext) == "table" then tonumber(rollContext.luckMultiplier) or 1 else 1
	local totalWeight = 0

	for _, entry in BrainrotConfig.Pool do
		totalWeight += getEffectiveWeight(entry, luckMultiplier)
	end

	local pick = rng:NextNumber(0, totalWeight)
	local running = 0

	for _, entry in BrainrotConfig.Pool do
		running += getEffectiveWeight(entry, luckMultiplier)
		if pick <= running then
			return entry
		end
	end

	return BrainrotConfig.Pool[1]
end

return BrainrotConfig
