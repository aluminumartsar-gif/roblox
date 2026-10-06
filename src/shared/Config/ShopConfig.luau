--!strict
-- Static catalogue of shop products. Products are scaffolded as in-game cash
-- purchases; the Buy buttons in the shop UI surface a "coming soon" status
-- until a server-side ShopService is wired up to validate purchases, deduct
-- money, and apply the boost.
--
-- To wire a real purchase flow:
--   1. Add a `ShopPurchaseRequest` remote in EconomyConfig.
--   2. Build a ShopService on the server that validates the player has the
--      required cash, deducts it via PlayerDataService, and applies the boost.
--   3. Update ShopController on the client to fire the remote and react to a
--      ShopPurchaseResult remote.

local ShopConfig = {}

ShopConfig.REMOTE_FOLDER = "ShopRemotes"
ShopConfig.PURCHASE_REQUEST_REMOTE = "ShopPurchaseRequest"
ShopConfig.PURCHASE_RESULT_REMOTE = "ShopPurchaseResult"

export type ProductCurrency = "Cash" | "Robux"

export type Product = {
	id: string,
	name: string,
	description: string,
	priceText: string,
	currency: ProductCurrency,
	price: number,
	icon: string,
	accent: Color3,
}

local CURRENCY_CASH: ProductCurrency = "Cash"
local CURRENCY_ROBUX: ProductCurrency = "Robux"

ShopConfig.Products = {
	{
		id = "LuckyCharm",
		name = "Lucky Charm",
		description = "+25% luck for 5 minutes. Stack with hotspots and rebirth luck for jackpot digs.",
		priceText = "$500",
		currency = CURRENCY_CASH,
		price = 500,
		icon = "Luck",
		accent = Color3.fromRGB(255, 230, 96),
	},
	{
		id = "CashRush",
		name = "Cash Rush",
		description = "+50% cash from every brainrot you sell for 5 minutes.",
		priceText = "$1,000",
		currency = CURRENCY_CASH,
		price = 1000,
		icon = "Gem",
		accent = Color3.fromRGB(120, 255, 166),
	},
	{
		id = "AutoDig",
		name = "Auto-Dig (Pro)",
		description = "Your shovel digs by itself for 2 minutes. Great for grinding rare brainrots.",
		priceText = "$2,500",
		currency = CURRENCY_CASH,
		price = 2500,
		icon = "Plus",
		accent = Color3.fromRGB(154, 212, 255),
	},
	{
		id = "PremiumPass",
		name = "Premium Pass",
		description = "Permanent +10% cash and +10% luck on every dig. Show off the gold trail.",
		priceText = "199 R$",
		currency = CURRENCY_ROBUX,
		price = 199,
		icon = "Rebirth",
		accent = Color3.fromRGB(232, 72, 155),
	},
} :: { Product }

return ShopConfig
