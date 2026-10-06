--!strict
-- Maps named icons (sourced from the local vector-icon-pack PNGs in
-- assets/icons/) to their uploaded Roblox asset IDs. The IDs are written
-- here automatically by the bulk-import flow that reads the assets folder
-- and listens for BulkImportService.AssetImported events; see
-- assets/icons/README.md for the upload steps.
--
-- Until an icon is uploaded its entry is "rbxassetid://0", which Roblox
-- silently renders as a transparent image. UI consumers should still
-- continue to function (just without the icon visible).

export type IconName =
	"Backpack"
	| "Book"
	| "Home"
	| "Rebirth"
	| "Gem"
	| "Luck"
	| "Close"
	| "Plus"
	| "Shop"
	| "Settings"
	| "Shovel"
	| "WoodenShovel"
	| "IronShovel"
	| "SteelShovel"
	| "GoldShovel"
	| "DiamondShovel"
	| "ObsidianShovel"
	| "BrainrotShovel"
	| "Cash"
	| "WeatherNight"
	| "WeatherRain"
	| "WeatherFog"
	| "WeatherStorm"
	| "WeatherAurora"

local IconAssets: { [IconName]: string } = {
	Backpack = "rbxassetid://82861236907905",
	Book = "rbxassetid://111630944127601",
	Home = "rbxassetid://0",
	Rebirth = "rbxassetid://104402029372536",
	Gem = "rbxassetid://126829028564083",
	Luck = "rbxassetid://109347213399784",
	Close = "rbxassetid://106243116040944",
	Plus = "rbxassetid://0",
	Shop = "rbxassetid://139879870675401",
	Settings = "rbxassetid://130100236267631",
	Shovel = "rbxassetid://0",
	WoodenShovel = "rbxassetid://136733883150680",
	IronShovel = "rbxassetid://109063093649545",
	SteelShovel = "rbxassetid://119558133885745",
	GoldShovel = "rbxassetid://120902900090245",
	DiamondShovel = "rbxassetid://135871662949661",
	ObsidianShovel = "rbxassetid://123544979442023",
	BrainrotShovel = "rbxassetid://100900160583923",
	Cash = "rbxassetid://135269735731878",
	WeatherNight = "rbxassetid://75653445151346",
	WeatherRain = "rbxassetid://95097842219715",
	WeatherFog = "rbxassetid://72085555108341",
	WeatherStorm = "rbxassetid://126504770634057",
	WeatherAurora = "rbxassetid://101063685007939",
}

return IconAssets
