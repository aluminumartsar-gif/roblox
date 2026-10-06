local EconomyConfig = {
	DATASTORE_NAME = "BrainrotPlayerData_v5",
	DATA_VERSION = 6,
	REMOTE_FOLDER = "EconomyRemotes",
	INVENTORY_SYNC_REMOTE = "InventorySync",
	ECONOMY_SYNC_REMOTE = "EconomySync",
	ECONOMY_SYNC_REQUEST_REMOTE = "EconomySyncRequest",
	REBIRTH_REQUEST_REMOTE = "RebirthRequest",
	REBIRTH_RESULT_REMOTE = "RebirthResult",
	BASE_UPGRADE_REQUEST_REMOTE = "BaseUpgradeRequest",
	BASE_UPGRADE_RESULT_REMOTE = "BaseUpgradeResult",
	SHOVEL_UPGRADE_REQUEST_REMOTE = "ShovelUpgradeRequest",
	SHOVEL_UPGRADE_RESULT_REMOTE = "ShovelUpgradeResult",
	PLOT_PLACEMENT_PROMPT_REMOTE = "PlotPlacementPrompt",
	PLOT_PLACE_REQUEST_REMOTE = "PlotPlaceRequest",
	PLOT_PICKUP_PROMPT_REMOTE = "PlotPickupPrompt",
	PLOT_PICKUP_REQUEST_REMOTE = "PlotPickupRequest",
	PLOT_SLOT_SYNC_REMOTE = "PlotSlotSync",
	CASH_COLLECT_FX_REMOTE = "CashCollectFX",
	INDEX_SYNC_REMOTE = "IndexSync",
	NEW_BRAINROT_FOUND_REMOTE = "NewBrainrotFound",
	PAD_UNLOCK_REMOTE = "PadUnlock",
	HOTBAR_SYNC_REMOTE = "HotbarSync",
	HOTBAR_NOTIFICATION_REMOTE = "HotbarNotification",
	BACKPACK_SYNC_REMOTE = "BackpackSync",
	INVENTORY_MOVE_REMOTE = "InventoryMove",
	SELL_ITEM_REQUEST_REMOTE = "SellItemRequest",
	SELL_ALL_REQUEST_REMOTE = "SellAllRequest",
	SELL_RESULT_REMOTE = "SellResult",
	RARE_ANNOUNCE_REMOTE = "RareAnnounce",
	HOTBAR_SIZE = 8,
	BACKPACK_SIZE = 16,

	VENDOR_REMOTE_FOLDER = "VendorRemotes",
	VENDOR_PURCHASE_REQUEST_REMOTE = "VendorPurchaseRequest",
	VENDOR_PURCHASE_RESULT_REMOTE = "VendorPurchaseResult",
	VENDOR_SYNC_REMOTE = "VendorSync",
	VENDOR_OPEN_REMOTE = "VendorOpen",
	STARTING_MONEY = 0,
	STARTING_REBIRTHS = 0,
	REBIRTH_CASH_MULTIPLIER = 1.25,
	REBIRTH_LUCK_MULTIPLIER = 1.15,
	REBIRTH_BASE_COST = 50_000,
	REBIRTH_COST_GROWTH = 10,
	BRAINROT_VALUE_MULTIPLIER = 0.7,
	LEVEL_VALUE_MULTIPLIER = 0.25,
	RARITY_VALUE_MULTIPLIER = 0.08,
	PLOT_ONLINE_INCOME_MULTIPLIER = 0.35,
	PLOT_OFFLINE_INCOME_MULTIPLIER = 0.05,
	PLOT_OFFLINE_EARNINGS_CAP_SECONDS = 8 * 60 * 60,
	SELL_VALUE_MULTIPLIER = 20,
}

-- Each tier requires exactly 1 of each listed brainrot so players never grind
-- multiples of the same brainrot. Difficulty scales by rarity, not quantity.
-- Tier index = current rebirths + 1 (tier 20 is the 20th rebirth). Beyond the
-- last explicit row, counts on that row scale up via getRebirthRequirements.
EconomyConfig.REBIRTH_REQUIREMENTS = {
	-- Tier 1 → Rare
	{
		{ id = "Trippi Troppi", count = 1 },
		{ id = "Boneca Ambalabu", count = 1 },
	},
	-- Tier 2 → Epic
	{
		{ id = "Cappuccino Assassino", count = 1 },
		{ id = "Brr Brr Patapim", count = 1 },
	},
	-- Tier 3 → Epic + Legendary
	{
		{ id = "Penguino Cocosino", count = 1 },
		{ id = "Chimpanzini Bananini", count = 1 },
	},
	-- Tier 4 → Legendary + Mythic
	{
		{ id = "Blueberrinni Octopusini", count = 1 },
		{ id = "Frigo Camelo", count = 1 },
	},
	-- Tier 5 → Mythic + Brainrot God
	{
		{ id = "Bombardiro Crocodilo", count = 1 },
		{ id = "Cocofanto Elefanto", count = 1 },
	},
	-- Tier 6 → Brainrot God + Secret
	{
		{ id = "Matteo", count = 1 },
		{ id = "La Vacca Saturno Saturnita", count = 1 },
	},
	-- Tiers 7–19 → Brainrot God + Secret (roughly ramping; secrets get rarer)
	{
		{ id = "Tralalero Tralala", count = 1 },
		{ id = "Chimpanzini Spiderini", count = 1 },
	},
	{
		{ id = "Girafa Celestre", count = 1 },
		{ id = "Agarrini la Palini", count = 1 },
	},
	{
		{ id = "Los Crocodillitos", count = 1 },
		{ id = "Torrtuginni Dragonfrutini", count = 1 },
	},
	{
		{ id = "Tigroligre Frutonni", count = 1 },
		{ id = "Las Vaquitas Saturnitas", count = 1 },
	},
	{
		{ id = "Odin Din Din Dun", count = 1 },
		{ id = "Graipuss Medussi", count = 1 },
	},
	{
		{ id = "Statutino Libertino", count = 1 },
		{ id = "Tung Tung Tung Sahur", count = 1 },
	},
	{
		{ id = "Tukanno Bananno", count = 1 },
		{ id = "Pot Hotspot", count = 1 },
	},
	{
		{ id = "Espresso Signora", count = 1 },
		{ id = "Chicleteira Bicicleteira", count = 1 },
	},
	{
		{ id = "Orcalero Orcala", count = 1 },
		{ id = "La Grande Combinasion", count = 1 },
	},
	{
		{ id = "Trenostruzzo Turbo 3000", count = 1 },
		{ id = "Los Combinasionas", count = 1 },
	},
	{
		{ id = "Trippi Troppi Troppa Trippa", count = 1 },
		{ id = "Nuclearo Dinossauro", count = 1 },
	},
	{
		{ id = "Ballerino Lololo", count = 1 },
		{ id = "Garama and Madundung", count = 1 },
	},
	{
		{ id = "Gattatino Neonino", count = 1 },
		{ id = "Piccione Macchina", count = 1 },
	},
	{
		{ id = "Los Tungtungtungcitos", count = 1 },
		{ id = "Dragon Cannelloni", count = 1 },
	},
	-- Tier 20 → capstone secret pair (was tier 7 / ~rebirth 6)
	{
		{ id = "Los Tralaleritos", count = 1 },
		{ id = "Las Tralaleritas", count = 1 },
	},
}

local function copyRequirements(requirements, extraCount: number?)
	local copied = {}

	for _, requirement in requirements do
		table.insert(copied, {
			id = requirement.id,
			count = requirement.count + (extraCount or 0),
		})
	end

	return copied
end

function EconomyConfig.getCashMultiplier(rebirths: number)
	return EconomyConfig.REBIRTH_CASH_MULTIPLIER ^ rebirths
end

-- Single source of truth for the per-second cash a brainrot generates while
-- placed on a base. `baseValue` is the brainrot's stored `value` (rarity *
-- variant * base income basis); `cashMultiplier` is the player's current
-- rebirth multiplier (use 1 for "base" displays). Floored to keep the in-world
-- placard, server payouts, and inventory UI in lock-step.
function EconomyConfig.computeEarningsRate(baseValue: number, cashMultiplier: number?): number
	local resolvedValue = tonumber(baseValue) or 0
	local resolvedMultiplier = tonumber(cashMultiplier) or 1
	return math.max(1, math.floor(resolvedValue * resolvedMultiplier * EconomyConfig.PLOT_ONLINE_INCOME_MULTIPLIER))
end

function EconomyConfig.getLuckMultiplier(rebirths: number)
	return EconomyConfig.REBIRTH_LUCK_MULTIPLIER ^ rebirths
end

function EconomyConfig.getRebirthCost(rebirths: number)
	return math.floor(EconomyConfig.REBIRTH_BASE_COST * (EconomyConfig.REBIRTH_COST_GROWTH ^ rebirths))
end

function EconomyConfig.getRebirthRequirements(rebirths: number)
	local tierIndex = math.max(1, rebirths + 1)
	local requirements = EconomyConfig.REBIRTH_REQUIREMENTS[tierIndex]
	if requirements then
		return copyRequirements(requirements)
	end

	local extraCount = tierIndex - #EconomyConfig.REBIRTH_REQUIREMENTS
	return copyRequirements(EconomyConfig.REBIRTH_REQUIREMENTS[#EconomyConfig.REBIRTH_REQUIREMENTS], extraCount)
end

return EconomyConfig
