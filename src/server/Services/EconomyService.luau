local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local BrainrotConfig = require(ConfigFolder:WaitForChild("BrainrotConfig"))
local EconomyConfig = require(ConfigFolder:WaitForChild("EconomyConfig"))
local ShovelUpgradeConfig = require(ConfigFolder:WaitForChild("ShovelUpgradeConfig"))
local VariantConfig = require(ConfigFolder:WaitForChild("VariantConfig"))

local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))

local EconomyService = {}

function EconomyService.getBrainrotValue(brainrotId: string, level: number, variantId: string?)
	return BrainrotConfig.getValue(brainrotId, level, variantId)
end

function EconomyService.createInventoryEntry(brainrotId: string, variantId: string?)
	local revealData = BrainrotConfig.getRevealData(brainrotId)
	local resolvedVariantId = if VariantConfig.isKnown(variantId) then variantId else VariantConfig.NORMAL_ID
	local level = 1
	local value = EconomyService.getBrainrotValue(brainrotId, level, resolvedVariantId)

	return {
		uid = HttpService:GenerateGUID(false),
		id = brainrotId,
		variantId = resolvedVariantId,
		level = level,
		rarity = revealData.rarity,
		rarityRank = revealData.rarityRank,
		value = value,
		collectedAt = os.time(),
	}
end

-- Hook for the future variant upgrade mechanic. Mutates the inventory item in
-- place, recomputes its value with the new variant multiplier, and returns the
-- updated entry. Callers are responsible for re-firing inventory sync.
function EconomyService.setItemVariant(player: Player, itemUid: string, newVariantId: string)
	if not VariantConfig.isKnown(newVariantId) then
		return nil
	end

	local data = PlayerDataService.getData(player)
	for _, item in data.inventory do
		if item.uid == itemUid then
			item.variantId = newVariantId
			item.value = EconomyService.getBrainrotValue(item.id, item.level, newVariantId)
			return item
		end
	end

	return nil
end

function EconomyService.getCashReward(player: Player, inventoryEntry)
	local data = PlayerDataService.getData(player)
	local multiplier = EconomyConfig.getCashMultiplier(data.rebirths)

	return EconomyConfig.computeEarningsRate(inventoryEntry.value, multiplier) * EconomyConfig.SELL_VALUE_MULTIPLIER
end

-- Preview the per-second cash a freshly-rolled brainrot would generate for
-- `player` if placed at their base right now. Mirrors getCashReward so the
-- dig drop placard reads the same as the placement placard once collected.
function EconomyService.previewEarningsRate(player: Player, brainrotId: string, variantId: string?): number
	local data = PlayerDataService.getData(player)
	local multiplier = EconomyConfig.getCashMultiplier(data.rebirths)
	local baseValue = EconomyService.getBrainrotValue(brainrotId, 1, variantId)
	return EconomyConfig.computeEarningsRate(baseValue, multiplier)
end

function EconomyService.awardForBrainrot(player: Player, inventoryEntry)
	warn(("[Economy] Ignored direct brainrot award for %s; cash must be collected from a placed plot."):format(player.Name))
	return 0
end

function EconomyService.getSnapshot(player: Player)
	local publicData = PlayerDataService.getPublicData(player)
	local requirements = EconomyConfig.getRebirthRequirements(publicData.rebirths)
	local counts = PlayerDataService.getHotbarCounts(player)
	local requirementStatus = {}
	local requirementsMet = true

	for _, requirement in requirements do
		local owned = counts[requirement.id] or 0
		local required = requirement.count or 1
		local met = owned >= required
		requirementsMet = requirementsMet and met
		table.insert(requirementStatus, {
			id = requirement.id,
			required = required,
			owned = owned,
			met = met,
		})
	end

	local shovelUpgrades = PlayerDataService.getShovelUpgrades(player)
	local rb = publicData.rebirths

	return {
		money = publicData.money,
		rebirths = publicData.rebirths,
		baseTier = publicData.baseTier,
		cashMultiplier = publicData.cashMultiplier,
		luckMultiplier = publicData.luckMultiplier,
		rebirthCost = publicData.rebirthCost,
		rebirthRequirements = requirementStatus,
		canRebirth = publicData.money >= publicData.rebirthCost and requirementsMet,
		shovelUpgrades = shovelUpgrades,
		shovelUpgradeCosts = {
			luck = ShovelUpgradeConfig.getUpgradeCost("luck", shovelUpgrades.luck, rb),
			greenBar = ShovelUpgradeConfig.getUpgradeCost("greenBar", shovelUpgrades.greenBar, rb),
			walkSpeed = ShovelUpgradeConfig.getUpgradeCost("walkSpeed", shovelUpgrades.walkSpeed, rb),
		},
	}
end

return EconomyService
