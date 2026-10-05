--!strict
--[[
	BoostService
	ServerScriptService/Server/Services/BoostService

	The one place that answers "how much does this player get?":
	luck, income multiplier, hatch speed, nest capacity, vault cap.
	Every system that needs one of these asks here, so a new source of a
	bonus (a pass, a potion, a rebirth, a codex page) is added in one place.

	Game passes arrive in Step 6. Until then the pass checker always says
	"no"; Step 6 calls SetPassChecker() with the real MarketplaceService
	lookup and every pass effect below starts working.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local DataService = require(ServerScriptService:WaitForChild("Server"):WaitForChild("Services"):WaitForChild("DataService"))

local BoostService = {}

local passChecker: (Player, string) -> boolean = function()
	return false
end

--- Step 6 installs the real game-pass lookup here.
function BoostService.SetPassChecker(checker: (Player, string) -> boolean)
	passChecker = checker
end

function BoostService.HasPass(player: Player, passName: string): boolean
	return passChecker(player, passName)
end

local function buffActive(data: any, buffName: string): boolean
	local expiry = data.Buffs and data.Buffs[buffName]
	return typeof(expiry) == "number" and expiry > os.time()
end

--- Number of rarity pages the player has fully photographed (Step 7).
local function completedCodexPages(data: any): number
	local pages = 0
	for _, rarity in ipairs(Config.RarityOrder) do
		local all = true
		for _, creature in ipairs(Config.CreaturesByRarity[rarity]) do
			if not data.Codex[creature.Id] then
				all = false
				break
			end
		end
		if all then
			pages += 1
		end
	end
	return pages
end

--- Luck as an additive percent (e.g. 35 = +35%), capped.
function BoostService.GetLuckPercent(player: Player): number
	local data = DataService.Get(player)
	if not data then
		return 0
	end
	local luck = data.Rebirths * Config.Luck.PerRebirthPercent
	if buffActive(data, "Luck") then
		luck += Config.Luck.PotionPercent
	end
	if BoostService.HasPass(player, "Vip") then
		luck += Config.Luck.VipPercent
	end
	luck += completedCodexPages(data) * Config.Luck.CodexPageCompletePercent
	return math.min(luck, Config.Luck.MaxPercent)
end

--- Player-wide income multiplier (rebirths, 2x Cash pass).
function BoostService.GetIncomeMultiplier(player: Player): number
	local data = DataService.Get(player)
	if not data then
		return 1
	end
	local multiplier = 1 + data.Rebirths * Config.Rebirth.IncomeBonusPerRebirth
	if BoostService.HasPass(player, "DoubleCash") then
		multiplier *= Config.DoubleCashMultiplier
	end
	return multiplier
end

--- Cash per second one creature slot earns for this player.
function BoostService.GetCreatureIncome(player: Player, slot: any): number
	local rarity = Config.Rarities[slot.Rarity or ""]
	if not rarity then
		return 0
	end
	local income = rarity.IncomePerSecond
	local mutation = slot.Mutation and Config.Mutations[slot.Mutation]
	if mutation then
		income *= mutation.IncomeMultiplier
	end
	return income * BoostService.GetIncomeMultiplier(player)
end

--- How fast this player's eggs incubate, as a multiplier on real time
--- (Hatch Speed upgrade x Hatch Boost buff).
function BoostService.GetHatchSpeedMultiplier(player: Player): number
	local data = DataService.Get(player)
	if not data then
		return 1
	end
	local multiplier = Config.GetUpgradeValue("IncubationSpeed", data.Upgrades.IncubationSpeed)
	if buffActive(data, "HatchSpeed") then
		multiplier *= Config.DevProducts.HatchBoost.Multiplier
	end
	return multiplier
end

--- How many nests the player can use.
function BoostService.GetNestCapacity(player: Player): number
	local data = DataService.Get(player)
	if not data then
		return 0
	end
	local capacity = Config.GetUpgradeValue("NestSlots", data.Upgrades.NestSlots)
	if BoostService.HasPass(player, "ExtraNests") then
		capacity += Config.GamePasses.ExtraNests.BonusNests
	end
	return math.min(capacity, Config.Plot.MaxNests)
end

--- Most uncollected cash one creature can hold: the Vault Size upgrade, or
--- Config.Income.MinVaultSeconds of that creature's own income, whichever
--- is bigger. Without a slot, just the upgrade value.
function BoostService.GetVaultCap(player: Player, slot: any?): number
	local data = DataService.Get(player)
	if not data then
		return 0
	end
	local cap = Config.GetUpgradeValue("VaultSize", data.Upgrades.VaultSize)
	if slot and Config.Income.MinVaultSeconds > 0 then
		cap = math.max(cap, math.floor(BoostService.GetCreatureIncome(player, slot) * Config.Income.MinVaultSeconds))
	end
	return cap
end

function BoostService.Start() end

return BoostService
