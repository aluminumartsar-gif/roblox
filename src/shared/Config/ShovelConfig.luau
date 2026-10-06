--!strict
-- Catalogue of shovels sold by the in-world vendor. Each entry defines the
-- gameplay stats consumed by DigService when starting a session and the
-- visual style consumed by ShovelComponent when rebuilding the tool. The
-- Starter shovel is free at rebirth 0. Other shovels need a minimum rebirth
-- count and cash at the vendor (Iron is rebirth 0 + cash so the first upgrade
-- is money‑gated only).

local ShovelConfig = {}

export type ShovelStats = {
	requiredHits: number,
	breakPerHit: number,
	baseLuck: number,
	-- Multiplicative bonus applied to the timing-bar green zone width.
	-- 0.15 means the green zone is 15% wider than baseline.
	-- Vestigial: the timing bar minigame is gone (Step 3 of the dig rework)
	-- but the field is kept on the type so older tooling/UI that reads it
	-- still type-checks. New gameplay scaling uses digDuration instead.
	barSizeBonus: number,
	-- Base countdown duration (seconds) the player waits while the looping
	-- shovel animation plays before a brainrot candidate is revealed.
	-- Better shovels reduce this; the Dig Speed upgrade reduces it further
	-- via ShovelUpgradeConfig.getDigDurationMultiplier.
	digDuration: number,
}

export type ShovelVisual = {
	handleColor: Color3,
	handleMaterial: Enum.Material,
	bladeColor: Color3,
	bladeMaterial: Enum.Material,
	accentColor: Color3,
	gripColor: Color3,
	gripMaterial: Enum.Material,
}

export type ShovelEntry = {
	id: string,
	displayName: string,
	tagline: string,
	rebirthsRequired: number,
	cost: number,
	stats: ShovelStats,
	visual: ShovelVisual,
	-- Optional. Name of an entry in IconAssets used by UI to render the
	-- shovel's portrait/logo. Shovels without an icon fall back to the
	-- procedural shovel silhouette built out of frames.
	iconName: string?,
}

ShovelConfig.DEFAULT_ID = "Wooden"

ShovelConfig.Shovels = {
	{
		id = "Wooden",
		displayName = "Wooden Shovel",
		tagline = "Standard issue. Gets the job done.",
		rebirthsRequired = 0,
		cost = 0,
		iconName = "WoodenShovel",
		stats = {
			requiredHits = 1,
			breakPerHit = 0.10,
			baseLuck = 1.00,
			barSizeBonus = 0.00,
			digDuration = 5.0,
		},
		visual = {
			handleColor = Color3.fromRGB(126, 83, 45),
			handleMaterial = Enum.Material.Wood,
			bladeColor = Color3.fromRGB(92, 96, 105),
			bladeMaterial = Enum.Material.Metal,
			accentColor = Color3.fromRGB(180, 140, 90),
			gripColor = Color3.fromRGB(70, 70, 74),
			gripMaterial = Enum.Material.Metal,
		},
	},
	{
		id = "Copper",
		displayName = "Copper Shovel",
		tagline = "Soft metal edge. A small step up from bark.",
		rebirthsRequired = 0,
		cost = 12_500,
		stats = {
			requiredHits = 1,
			breakPerHit = 0.096,
			baseLuck = 1.03,
			barSizeBonus = 0.035,
			digDuration = 4.5,
		},
		visual = {
			handleColor = Color3.fromRGB(110, 72, 46),
			handleMaterial = Enum.Material.Wood,
			bladeColor = Color3.fromRGB(184, 110, 72),
			bladeMaterial = Enum.Material.Metal,
			accentColor = Color3.fromRGB(255, 160, 110),
			gripColor = Color3.fromRGB(62, 48, 38),
			gripMaterial = Enum.Material.Metal,
		},
	},
	{
		id = "Iron",
		displayName = "Iron Shovel",
		tagline = "Forged steel head. Sturdier than the starter.",
		rebirthsRequired = 0,
		cost = 25_000,
		iconName = "IronShovel",
		stats = {
			requiredHits = 1,
			breakPerHit = 0.09,
			baseLuck = 1.05,
			barSizeBonus = 0.05,
			digDuration = 4.0,
		},
		visual = {
			handleColor = Color3.fromRGB(92, 70, 48),
			handleMaterial = Enum.Material.Wood,
			bladeColor = Color3.fromRGB(168, 172, 178),
			bladeMaterial = Enum.Material.Metal,
			accentColor = Color3.fromRGB(220, 220, 224),
			gripColor = Color3.fromRGB(56, 56, 60),
			gripMaterial = Enum.Material.Metal,
		},
	},
	{
		id = "Cobalt",
		displayName = "Cobalt Shovel",
		tagline = "Blue-tempered alloy. Holds an edge longer.",
		rebirthsRequired = 1,
		cost = 175_000,
		stats = {
			requiredHits = 1,
			breakPerHit = 0.086,
			baseLuck = 1.065,
			barSizeBonus = 0.065,
			digDuration = 3.6,
		},
		visual = {
			handleColor = Color3.fromRGB(52, 64, 92),
			handleMaterial = Enum.Material.Wood,
			bladeColor = Color3.fromRGB(72, 118, 170),
			bladeMaterial = Enum.Material.Metal,
			accentColor = Color3.fromRGB(120, 210, 255),
			gripColor = Color3.fromRGB(38, 44, 58),
			gripMaterial = Enum.Material.Metal,
		},
	},
	{
		id = "Steel",
		displayName = "Steel Shovel",
		tagline = "Hardened blade. Cuts through dirt cleaner.",
		rebirthsRequired = 2,
		cost = 250_000,
		iconName = "SteelShovel",
		stats = {
			requiredHits = 1,
			breakPerHit = 0.08,
			baseLuck = 1.10,
			barSizeBonus = 0.10,
			digDuration = 3.2,
		},
		visual = {
			handleColor = Color3.fromRGB(70, 56, 44),
			handleMaterial = Enum.Material.Wood,
			bladeColor = Color3.fromRGB(208, 214, 222),
			bladeMaterial = Enum.Material.Metal,
			accentColor = Color3.fromRGB(140, 200, 255),
			gripColor = Color3.fromRGB(40, 44, 50),
			gripMaterial = Enum.Material.Metal,
		},
	},
	{
		id = "Titanium",
		displayName = "Titanium Shovel",
		tagline = "Lightweight, viciously strong. Fewer swings to pay off.",
		rebirthsRequired = 3,
		cost = 1_500_000,
		stats = {
			requiredHits = 1,
			breakPerHit = 0.076,
			baseLuck = 1.117,
			barSizeBonus = 0.117,
			digDuration = 2.8,
		},
		visual = {
			handleColor = Color3.fromRGB(88, 86, 92),
			handleMaterial = Enum.Material.Metal,
			bladeColor = Color3.fromRGB(210, 212, 218),
			bladeMaterial = Enum.Material.Metal,
			accentColor = Color3.fromRGB(255, 255, 255),
			gripColor = Color3.fromRGB(48, 48, 52),
			gripMaterial = Enum.Material.Metal,
		},
	},
	{
		id = "Gold",
		displayName = "Gold Shovel",
		tagline = "Lucky touch. Pulls richer rolls out of the dirt.",
		rebirthsRequired = 4,
		cost = 2_500_000,
		iconName = "GoldShovel",
		stats = {
			requiredHits = 1,
			breakPerHit = 0.07,
			baseLuck = 1.15,
			barSizeBonus = 0.15,
			digDuration = 2.4,
		},
		visual = {
			handleColor = Color3.fromRGB(120, 78, 36),
			handleMaterial = Enum.Material.Wood,
			bladeColor = Color3.fromRGB(255, 213, 84),
			bladeMaterial = Enum.Material.Foil,
			accentColor = Color3.fromRGB(255, 240, 150),
			gripColor = Color3.fromRGB(204, 156, 40),
			gripMaterial = Enum.Material.Foil,
		},
	},
	{
		id = "Platinum",
		displayName = "Platinum Shovel",
		tagline = "Dense, polished, almost unfair.",
		rebirthsRequired = 5,
		cost = 15_000_000,
		stats = {
			requiredHits = 1,
			breakPerHit = 0.065,
			baseLuck = 1.185,
			barSizeBonus = 0.19,
			digDuration = 2.1,
		},
		visual = {
			handleColor = Color3.fromRGB(90, 98, 110),
			handleMaterial = Enum.Material.Metal,
			bladeColor = Color3.fromRGB(230, 235, 242),
			bladeMaterial = Enum.Material.Foil,
			accentColor = Color3.fromRGB(200, 220, 255),
			gripColor = Color3.fromRGB(58, 64, 76),
			gripMaterial = Enum.Material.Metal,
		},
	},
	{
		id = "Diamond",
		displayName = "Diamond Shovel",
		tagline = "Crystal-tipped. Slices through dirt like nothing.",
		rebirthsRequired = 6,
		cost = 25_000_000,
		iconName = "DiamondShovel",
		stats = {
			requiredHits = 1,
			breakPerHit = 0.06,
			baseLuck = 1.25,
			barSizeBonus = 0.25,
			digDuration = 1.8,
		},
		visual = {
			handleColor = Color3.fromRGB(56, 80, 110),
			handleMaterial = Enum.Material.Metal,
			bladeColor = Color3.fromRGB(150, 230, 255),
			bladeMaterial = Enum.Material.Foil,
			accentColor = Color3.fromRGB(220, 250, 255),
			gripColor = Color3.fromRGB(40, 64, 96),
			gripMaterial = Enum.Material.Metal,
		},
	},
	{
		id = "Amethyst",
		displayName = "Amethyst Shovel",
		tagline = "Violet crystal core channels weirdly good RNG.",
		rebirthsRequired = 7,
		cost = 48_000_000,
		stats = {
			requiredHits = 1,
			breakPerHit = 0.0575,
			baseLuck = 1.29,
			barSizeBonus = 0.29,
			digDuration = 1.6,
		},
		visual = {
			handleColor = Color3.fromRGB(68, 44, 92),
			handleMaterial = Enum.Material.Slate,
			bladeColor = Color3.fromRGB(170, 110, 220),
			bladeMaterial = Enum.Material.Glass,
			accentColor = Color3.fromRGB(230, 180, 255),
			gripColor = Color3.fromRGB(40, 28, 56),
			gripMaterial = Enum.Material.Slate,
		},
	},
	{
		id = "Sapphire",
		displayName = "Sapphire Shovel",
		tagline = "Ocean-bright facets catch fortune on every swing.",
		rebirthsRequired = 8,
		cost = 140_000_000,
		stats = {
			requiredHits = 1,
			breakPerHit = 0.055,
			baseLuck = 1.33,
			barSizeBonus = 0.33,
			digDuration = 1.4,
		},
		visual = {
			handleColor = Color3.fromRGB(36, 52, 92),
			handleMaterial = Enum.Material.Metal,
			bladeColor = Color3.fromRGB(64, 110, 220),
			bladeMaterial = Enum.Material.Glass,
			accentColor = Color3.fromRGB(130, 200, 255),
			gripColor = Color3.fromRGB(28, 38, 64),
			gripMaterial = Enum.Material.Metal,
		},
	},
	{
		id = "Obsidian",
		displayName = "Obsidian Shovel",
		tagline = "Volcanic glass. Doesn't chip, doesn't quit.",
		rebirthsRequired = 9,
		cost = 250_000_000,
		iconName = "ObsidianShovel",
		stats = {
			requiredHits = 1,
			breakPerHit = 0.05,
			baseLuck = 1.40,
			barSizeBonus = 0.40,
			digDuration = 1.25,
		},
		visual = {
			handleColor = Color3.fromRGB(28, 24, 32),
			handleMaterial = Enum.Material.Slate,
			bladeColor = Color3.fromRGB(40, 30, 60),
			bladeMaterial = Enum.Material.Glass,
			accentColor = Color3.fromRGB(200, 100, 255),
			gripColor = Color3.fromRGB(20, 16, 24),
			gripMaterial = Enum.Material.Slate,
		},
	},
	{
		id = "Netherite",
		displayName = "Netherite Shovel",
		tagline = "Ancient alloy. Digs like it has something to prove.",
		rebirthsRequired = 10,
		cost = 420_000_000,
		stats = {
			requiredHits = 1,
			breakPerHit = 0.0475,
			baseLuck = 1.465,
			barSizeBonus = 0.455,
			digDuration = 1.1,
		},
		visual = {
			handleColor = Color3.fromRGB(48, 38, 52),
			handleMaterial = Enum.Material.Asphalt,
			bladeColor = Color3.fromRGB(64, 52, 70),
			bladeMaterial = Enum.Material.Metal,
			accentColor = Color3.fromRGB(255, 120, 80),
			gripColor = Color3.fromRGB(28, 22, 32),
			gripMaterial = Enum.Material.Metal,
		},
	},
	{
		id = "Crystal",
		displayName = "Crystal Shovel",
		tagline = "Prismatic edge refracts luck into your pockets.",
		rebirthsRequired = 11,
		cost = 1_100_000_000,
		stats = {
			requiredHits = 1,
			breakPerHit = 0.043,
			baseLuck = 1.56,
			barSizeBonus = 0.53,
			digDuration = 1.0,
		},
		visual = {
			handleColor = Color3.fromRGB(64, 90, 110),
			handleMaterial = Enum.Material.Glass,
			bladeColor = Color3.fromRGB(255, 200, 230),
			bladeMaterial = Enum.Material.Glass,
			accentColor = Color3.fromRGB(180, 255, 255),
			gripColor = Color3.fromRGB(44, 62, 78),
			gripMaterial = Enum.Material.Glass,
		},
	},
	{
		id = "Astral",
		displayName = "Astral Shovel",
		tagline = "Barely tethered to this plane. Almost the final form.",
		rebirthsRequired = 12,
		cost = 2_750_000_000,
		stats = {
			requiredHits = 1,
			breakPerHit = 0.037,
			baseLuck = 1.64,
			barSizeBonus = 0.62,
			digDuration = 0.9,
		},
		visual = {
			handleColor = Color3.fromRGB(32, 40, 78),
			handleMaterial = Enum.Material.Neon,
			bladeColor = Color3.fromRGB(140, 100, 255),
			bladeMaterial = Enum.Material.Neon,
			accentColor = Color3.fromRGB(255, 230, 140),
			gripColor = Color3.fromRGB(24, 30, 58),
			gripMaterial = Enum.Material.Neon,
		},
	},
	{
		id = "Brainrot",
		displayName = "Brainrot Shovel",
		tagline = "One-shot legend. The ground gives up immediately.",
		rebirthsRequired = 13,
		cost = 5_000_000_000,
		iconName = "BrainrotShovel",
		stats = {
			requiredHits = 1,
			breakPerHit = 0.03,
			baseLuck = 1.75,
			barSizeBonus = 0.75,
			digDuration = 0.8,
		},
		visual = {
			handleColor = Color3.fromRGB(255, 80, 200),
			handleMaterial = Enum.Material.Neon,
			bladeColor = Color3.fromRGB(255, 220, 90),
			bladeMaterial = Enum.Material.Neon,
			accentColor = Color3.fromRGB(120, 255, 255),
			gripColor = Color3.fromRGB(255, 130, 240),
			gripMaterial = Enum.Material.Neon,
		},
	},
} :: { ShovelEntry }

local entriesById: { [string]: ShovelEntry } = {}
local entryIndexById: { [string]: number } = {}

for index, entry in ShovelConfig.Shovels do
	entriesById[entry.id] = entry
	entryIndexById[entry.id] = index
end

function ShovelConfig.getDefaultId(): string
	return ShovelConfig.DEFAULT_ID
end

function ShovelConfig.getById(shovelId: string?): ShovelEntry?
	if type(shovelId) ~= "string" then
		return nil
	end

	return entriesById[shovelId]
end

function ShovelConfig.getOrDefault(shovelId: string?): ShovelEntry
	local entry = ShovelConfig.getById(shovelId)
	if entry then
		return entry
	end

	return entriesById[ShovelConfig.DEFAULT_ID]
end

function ShovelConfig.isKnown(shovelId: string?): boolean
	return ShovelConfig.getById(shovelId) ~= nil
end

-- Returns the gameplay stats for a shovel id, falling back to the default
-- shovel's stats for unknown ids so DigService never breaks on a stale value.
function ShovelConfig.getEffectiveStats(shovelId: string?): ShovelStats
	return ShovelConfig.getOrDefault(shovelId).stats
end

function ShovelConfig.getVisual(shovelId: string?): ShovelVisual
	return ShovelConfig.getOrDefault(shovelId).visual
end

function ShovelConfig.getRank(shovelId: string?): number
	if type(shovelId) ~= "string" then
		return 0
	end

	return entryIndexById[shovelId] or 0
end

-- Strict equality check on the catalogue order: a player can never buy the
-- shovel they already own, and may not "downgrade" to an earlier tier.
function ShovelConfig.isUpgradeFrom(currentId: string?, targetId: string): boolean
	return ShovelConfig.getRank(targetId) > ShovelConfig.getRank(currentId)
end

export type PurchaseFailureReason =
	"UNKNOWN_SHOVEL"
	| "ALREADY_OWNED"
	| "LOCKED_REBIRTHS"
	| "INSUFFICIENT_CASH"

export type PurchaseCheck = {
	ok: boolean,
	reason: PurchaseFailureReason?,
	missingRebirths: number?,
	missingCash: number?,
	entry: ShovelEntry?,
}

-- Single source of truth for vendor validation. Returns ok=true when the
-- purchase can be applied; otherwise returns a typed reason plus the deltas
-- needed to satisfy the requirement so the UI can surface useful messages.
function ShovelConfig.canPurchase(
	currentShovelId: string?,
	targetShovelId: string,
	rebirths: number,
	cash: number
): PurchaseCheck
	local entry = ShovelConfig.getById(targetShovelId)
	if not entry then
		return { ok = false, reason = "UNKNOWN_SHOVEL" }
	end

	if not ShovelConfig.isUpgradeFrom(currentShovelId, targetShovelId) then
		return { ok = false, reason = "ALREADY_OWNED", entry = entry }
	end

	if rebirths < entry.rebirthsRequired then
		return {
			ok = false,
			reason = "LOCKED_REBIRTHS",
			missingRebirths = entry.rebirthsRequired - rebirths,
			entry = entry,
		}
	end

	if cash < entry.cost then
		return {
			ok = false,
			reason = "INSUFFICIENT_CASH",
			missingCash = entry.cost - cash,
			entry = entry,
		}
	end

	return { ok = true, entry = entry }
end

return ShovelConfig
