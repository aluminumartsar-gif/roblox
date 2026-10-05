--!strict
--[[
	EggRoller
	ServerScriptService/Server/Modules/EggRoller

	The hatch roll. Server only — the client never rolls anything.

	  1. Rarity: weighted by Config.GetRarityChances(egg, luck), which
	     applies luck to the Rare-and-up weights, then renormalizes.
	  2. Creature: uniform among that rarity's creatures.
	  3. Mutation: only when Config.MutationsEnabled.

	Simulate() runs thousands of rolls through exactly the same code path and
	compares what came out with what Config says should come out.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local EggRoller = {}

export type HatchResult = {
	CreatureId: string,
	Rarity: string,
	Mutation: string?,
}

local defaultRng = Random.new()

function EggRoller.RollRarity(eggId: string, luckPercent: number, rng: Random?): string
	local chances = Config.GetRarityChances(eggId, luckPercent)
	local roll = (rng or defaultRng):NextNumber() -- [0, 1)
	local cumulative = 0
	for _, rarity in ipairs(Config.RarityOrder) do
		cumulative += chances[rarity] or 0
		if roll < cumulative then
			return rarity
		end
	end
	-- Floating-point rounding can leave the cumulative total a hair under 1.
	-- Fall back to the rarest rarity this egg can actually produce.
	for i = #Config.RarityOrder, 1, -1 do
		local rarity = Config.RarityOrder[i]
		if (chances[rarity] or 0) > 0 then
			return rarity
		end
	end
	return Config.RarityOrder[1]
end

function EggRoller.PickCreature(rarity: string, rng: Random?): any
	local pool = Config.CreaturesByRarity[rarity]
	assert(pool and #pool > 0, "No creatures for rarity " .. rarity)
	return pool[(rng or defaultRng):NextInteger(1, #pool)]
end

function EggRoller.RollMutation(rng: Random?): string?
	if not Config.MutationsEnabled then
		return nil
	end
	-- Rarest first, so a single roll can land in at most one bucket.
	local roll = (rng or defaultRng):NextNumber()
	local cumulative = 0
	for i = #Config.MutationOrder, 1, -1 do
		local name = Config.MutationOrder[i]
		cumulative += Config.Mutations[name].Chance
		if roll < cumulative then
			return name
		end
	end
	return nil
end

function EggRoller.Hatch(eggId: string, luckPercent: number): HatchResult
	local rarity = EggRoller.RollRarity(eggId, luckPercent)
	local creature = EggRoller.PickCreature(rarity)
	return {
		CreatureId = creature.Id,
		Rarity = rarity,
		Mutation = EggRoller.RollMutation(),
	}
end

--------------------------------------------------------------------------
-- Simulation
--------------------------------------------------------------------------

--- Rolls `rolls` times and returns counts per rarity.
function EggRoller.Simulate(eggId: string, luckPercent: number, rolls: number, seed: number?): { [string]: number }
	local rng = Random.new(seed or os.clock() * 1e6)
	local counts: { [string]: number } = {}
	for _, rarity in ipairs(Config.RarityOrder) do
		counts[rarity] = 0
	end
	for _ = 1, rolls do
		local rarity = EggRoller.RollRarity(eggId, luckPercent, rng)
		counts[rarity] += 1
	end
	return counts
end

--- A readable table: expected vs observed per rarity, with a z-score.
--- |z| above 4 would be a real problem (it essentially never happens by
--- chance); a few values around 2 across a big table are normal.
function EggRoller.SimulationReport(eggId: string, luckPercent: number, rolls: number, seed: number?): (string, number)
	local counts = EggRoller.Simulate(eggId, luckPercent, rolls, seed)
	local chances = Config.GetRarityChances(eggId, luckPercent)
	local lines = {
		string.format("%s  luck %d%%  (%d rolls)", Config.Eggs[eggId].Name, luckPercent, rolls),
		string.format("  %-10s %9s %9s %7s", "rarity", "expected", "observed", "z"),
	}
	local worstZ = 0
	for _, rarity in ipairs(Config.RarityOrder) do
		local p = chances[rarity] or 0
		local observed = counts[rarity] / rolls
		local z = 0
		if p > 0 and p < 1 then
			z = (observed - p) / math.sqrt(p * (1 - p) / rolls)
		elseif p == 0 and counts[rarity] > 0 then
			z = math.huge -- something rolled that should be impossible
		end
		worstZ = math.max(worstZ, math.abs(z))
		table.insert(lines, string.format("  %-10s %8.3f%% %8.3f%% %+7.2f", rarity, p * 100, observed * 100, z))
	end
	return table.concat(lines, "\n"), worstZ
end

return EggRoller
