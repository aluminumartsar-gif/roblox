local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local DigConfig = require(ConfigFolder:WaitForChild("DigConfig"))
local EconomyConfig = require(ConfigFolder:WaitForChild("EconomyConfig"))
local TeleportConfig = require(ConfigFolder:WaitForChild("TeleportConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))

RemoteRegistry.ensureRemotes(DigConfig.REMOTE_FOLDER, {
	DigConfig.DIG_REQUEST_REMOTE,
	DigConfig.DIG_STARTED_REMOTE,
	DigConfig.DIG_REJECTED_REMOTE,
	DigConfig.DIG_STOP_REMOTE,
	DigConfig.DIG_CLAIM_REMOTE,
	DigConfig.DIG_MISS_REMOTE,
	DigConfig.DIG_STATE_REMOTE,
	DigConfig.DIG_BROKEN_REMOTE,
	DigConfig.DIG_COUNTDOWN_STARTED_REMOTE,
	DigConfig.DIG_SITE_ENTERED_REMOTE,
	DigConfig.DIG_SITE_LEFT_REMOTE,
	DigConfig.BRAINROT_SPAWNED_REMOTE,
	DigConfig.BRAINROT_COLLECTED_REMOTE,
	DigConfig.BRAINROT_DESPAWN_REMOTE,
})

RemoteRegistry.ensureRemotes(DigConfig.WEATHER_REMOTE_FOLDER, {
	DigConfig.WEATHER_STARTED_REMOTE,
	DigConfig.WEATHER_ENDED_REMOTE,
	DigConfig.WEATHER_SYNC_REMOTE,
})

RemoteRegistry.ensureRemotes(EconomyConfig.REMOTE_FOLDER, {
	EconomyConfig.INVENTORY_SYNC_REMOTE,
	EconomyConfig.ECONOMY_SYNC_REMOTE,
	EconomyConfig.ECONOMY_SYNC_REQUEST_REMOTE,
	EconomyConfig.REBIRTH_REQUEST_REMOTE,
	EconomyConfig.REBIRTH_RESULT_REMOTE,
	EconomyConfig.BASE_UPGRADE_REQUEST_REMOTE,
	EconomyConfig.BASE_UPGRADE_RESULT_REMOTE,
	EconomyConfig.SHOVEL_UPGRADE_REQUEST_REMOTE,
	EconomyConfig.SHOVEL_UPGRADE_RESULT_REMOTE,
	EconomyConfig.PLOT_PLACEMENT_PROMPT_REMOTE,
	EconomyConfig.PLOT_PLACE_REQUEST_REMOTE,
	EconomyConfig.PLOT_PICKUP_PROMPT_REMOTE,
	EconomyConfig.PLOT_PICKUP_REQUEST_REMOTE,
	EconomyConfig.PLOT_SLOT_SYNC_REMOTE,
	EconomyConfig.CASH_COLLECT_FX_REMOTE,
	EconomyConfig.INDEX_SYNC_REMOTE,
	EconomyConfig.NEW_BRAINROT_FOUND_REMOTE,
	EconomyConfig.PAD_UNLOCK_REMOTE,
	EconomyConfig.HOTBAR_SYNC_REMOTE,
	EconomyConfig.HOTBAR_NOTIFICATION_REMOTE,
	EconomyConfig.BACKPACK_SYNC_REMOTE,
	EconomyConfig.INVENTORY_MOVE_REMOTE,
	EconomyConfig.SELL_ITEM_REQUEST_REMOTE,
	EconomyConfig.SELL_ALL_REQUEST_REMOTE,
	EconomyConfig.SELL_RESULT_REMOTE,
	EconomyConfig.RARE_ANNOUNCE_REMOTE,
})

RemoteRegistry.ensureRemotes(EconomyConfig.VENDOR_REMOTE_FOLDER, {
	EconomyConfig.VENDOR_PURCHASE_REQUEST_REMOTE,
	EconomyConfig.VENDOR_PURCHASE_RESULT_REMOTE,
	EconomyConfig.VENDOR_SYNC_REMOTE,
	EconomyConfig.VENDOR_OPEN_REMOTE,
})

RemoteRegistry.ensureRemotes(TeleportConfig.REMOTE_FOLDER, {
	TeleportConfig.TELEPORT_REQUEST_REMOTE,
})

local Services = script.Parent:WaitForChild("Services")
local PlayerDataService = require(Services:WaitForChild("PlayerDataService"))

print("[Bootstrap] Server systems starting")

PlayerDataService.start()

local LeaderboardPodiumService = require(Services:WaitForChild("LeaderboardPodiumService"))
LeaderboardPodiumService.start()

local WeatherService = require(Services:WaitForChild("WeatherService"))
local DigService = require(Services:WaitForChild("DigService"))
local DigSiteService = require(Services:WaitForChild("DigSiteService"))
local CollectService = require(Services:WaitForChild("CollectService"))
local HotbarService = require(Services:WaitForChild("HotbarService"))
local RebirthService = require(Services:WaitForChild("RebirthService"))
local BaseUpgradeService = require(Services:WaitForChild("BaseUpgradeService"))
local PlotService = require(Services:WaitForChild("PlotService"))
local EnvironmentService = require(Services:WaitForChild("EnvironmentService"))
local VendorService = require(Services:WaitForChild("VendorService"))
local ShopBoothService = require(Services:WaitForChild("ShopBoothService"))
local ShovelUpgradeService = require(Services:WaitForChild("ShovelUpgradeService"))
local UpgradeBoothService = require(Services:WaitForChild("UpgradeBoothService"))
local SellService = require(Services:WaitForChild("SellService"))
local TeleportService = require(Services:WaitForChild("TeleportService"))
local AdminService = require(Services:WaitForChild("AdminService"))
local RareAnnounceService = require(Services:WaitForChild("RareAnnounceService"))

EnvironmentService.start()
WeatherService.start()
DigSiteService.start()
DigService.start()
CollectService.start()
RareAnnounceService.start()
HotbarService.start()
RebirthService.start()
BaseUpgradeService.start()
PlotService.start()
VendorService.start()
ShopBoothService.start()
ShovelUpgradeService.start()
UpgradeBoothService.start()
SellService.start()
TeleportService.start()
AdminService.start()

print("[Bootstrap] Server systems started")
