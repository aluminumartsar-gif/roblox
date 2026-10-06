--!strict
-- Per-player shovel station upgrades: luck (dig baseline), timing-bar width, walk speed.
-- Each level adds PERCENT_PER_LEVEL% on that axis. Luck & green bar have no level cap and persist through rebirth.
-- Walk speed caps at MAX_WALK_SPEED_LEVEL and resets on rebirth.

export type StatId = "luck" | "greenBar" | "walkSpeed"

local ShovelUpgradeConfig = {}

ShovelUpgradeConfig.MAX_WALK_SPEED_LEVEL = 25
-- Kept for any legacy reads; walk-speed-only cap.
ShovelUpgradeConfig.MAX_LEVEL = ShovelUpgradeConfig.MAX_WALK_SPEED_LEVEL

-- Stat gain per purchased level (display + gameplay). Costs scale vs this former 1% baseline.
ShovelUpgradeConfig.PERCENT_PER_LEVEL = 5
ShovelUpgradeConfig.LEGACY_PERCENT_PER_LEVEL = 1

-- Progressive exponential curve; BASE_COST tuned so luck/greenBar tier 0 rounds to 10_000 cash.
-- Final prices snap to ROUND_CASH_STEP so UI stays clean (10k, 12k, 45k, …).
ShovelUpgradeConfig.BASE_COST = 1_740
ShovelUpgradeConfig.LEVEL_COST_GROWTH = 1.176
ShovelUpgradeConfig.REBIRTH_COST_MULT = 1.14
ShovelUpgradeConfig.ROUND_CASH_STEP = 1_000

-- Applied after base × growth × rebirth × PERCENT scale. Walk speed is deliberately much steeper.
ShovelUpgradeConfig.STAT_COST_MULTIPLIER = {
	luck = 1.15,
	greenBar = 1.15,
	walkSpeed = 4.75,
} :: { [StatId]: number }

local STAT_IDS: { StatId } = { "luck", "greenBar", "walkSpeed" }
ShovelUpgradeConfig.STAT_IDS = STAT_IDS

local DEFAULT_STAT_COST_MULT = 1

function ShovelUpgradeConfig.isStatId(value: any): boolean
	return value == "luck" or value == "greenBar" or value == "walkSpeed"
end

function ShovelUpgradeConfig.clampUnboundedLevel(level: number): number
	return math.max(0, math.floor(tonumber(level) or 0))
end

function ShovelUpgradeConfig.clampWalkSpeedLevel(level: number): number
	return math.clamp(math.floor(tonumber(level) or 0), 0, ShovelUpgradeConfig.MAX_WALK_SPEED_LEVEL)
end

function ShovelUpgradeConfig.clampLevelForStat(statId: StatId, level: number): number
	if statId == "walkSpeed" then
		return ShovelUpgradeConfig.clampWalkSpeedLevel(level)
	end
	return ShovelUpgradeConfig.clampUnboundedLevel(level)
end

function ShovelUpgradeConfig.isStatMaxed(statId: StatId, level: number): boolean
	if statId == "walkSpeed" then
		return ShovelUpgradeConfig.clampWalkSpeedLevel(level) >= ShovelUpgradeConfig.MAX_WALK_SPEED_LEVEL
	end
	return false
end

local function fractionPerLevel(): number
	return ShovelUpgradeConfig.PERCENT_PER_LEVEL / 100
end

-- Total bonus percent for UI (e.g. level 3 @ 5%/level → 15).
function ShovelUpgradeConfig.getTotalBonusPercentForStat(statId: StatId, level: number): number
	return ShovelUpgradeConfig.clampLevelForStat(statId, level) * ShovelUpgradeConfig.PERCENT_PER_LEVEL
end

function ShovelUpgradeConfig.getLuckMultiplier(level: number): number
	return 1 + ShovelUpgradeConfig.clampUnboundedLevel(level) * fractionPerLevel()
end

function ShovelUpgradeConfig.getBarSizeBonusFromUpgrade(level: number): number
	return ShovelUpgradeConfig.clampUnboundedLevel(level) * fractionPerLevel()
end

-- Floor on the dig-speed multiplier. At ~5% per level the formula 1/(1+L*0.05)
-- reaches 25% of base around L=60; we cap the floor here so absurd levels can
-- never collapse the countdown to zero (which would skip the animation).
local DIG_SPEED_MIN_MULTIPLIER = 0.25

-- Multiplier applied to a shovel's base digDuration (per ShovelConfig). Higher
-- greenBar levels shorten the countdown; the result is clamped above
-- DIG_SPEED_MIN_MULTIPLIER so a heavily-upgraded player still sees a brief
-- dig animation play before the brainrot reveal.
function ShovelUpgradeConfig.getDigDurationMultiplier(level: number): number
	local raw = 1 / (1 + ShovelUpgradeConfig.clampUnboundedLevel(level) * fractionPerLevel())
	return math.max(DIG_SPEED_MIN_MULTIPLIER, raw)
end

function ShovelUpgradeConfig.getWalkSpeedMultiplier(level: number): number
	return 1 + ShovelUpgradeConfig.clampWalkSpeedLevel(level) * fractionPerLevel()
end

local function roundCash(cost: number): number
	local step = ShovelUpgradeConfig.ROUND_CASH_STEP
	if step <= 1 then
		return math.max(1, math.floor(cost))
	end
	local n = math.max(1, math.floor(cost))
	local half = step // 2
	return math.max(step, math.floor((n + half) / step) * step)
end

function ShovelUpgradeConfig.getUpgradeCost(statId: StatId, currentLevel: number, rebirths: number): number
	local level = ShovelUpgradeConfig.clampLevelForStat(statId, currentLevel)
	local rb = math.max(0, math.floor(tonumber(rebirths) or 0))

	if statId == "walkSpeed" and level >= ShovelUpgradeConfig.MAX_WALK_SPEED_LEVEL then
		return 0
	end

	local rebirthFactor = ShovelUpgradeConfig.REBIRTH_COST_MULT ^ rb
	local raw = ShovelUpgradeConfig.BASE_COST
		* (ShovelUpgradeConfig.LEVEL_COST_GROWTH ^ level)
		* rebirthFactor
	-- Stronger per-level stat gain → scale cash cost vs old 1%-per-level tuning.
	local costScale = ShovelUpgradeConfig.PERCENT_PER_LEVEL / ShovelUpgradeConfig.LEGACY_PERCENT_PER_LEVEL
	local statMult = ShovelUpgradeConfig.STAT_COST_MULTIPLIER[statId] or DEFAULT_STAT_COST_MULT
	local exact = raw * costScale * statMult
	return roundCash(exact)
end

return ShovelUpgradeConfig
