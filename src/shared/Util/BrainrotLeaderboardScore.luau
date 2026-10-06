-- Best displayed RNG rarity (max combined denominator) from saved index data.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local BrainrotConfig = require(ConfigFolder:WaitForChild("BrainrotConfig"))
local VariantConfig = require(ConfigFolder:WaitForChild("VariantConfig"))

local BrainrotLeaderboardScore = {}

function BrainrotLeaderboardScore.getBestRngDenominatorFromData(data: any): number
	if type(data) ~= "table" then
		return 0
	end

	local foundBrainrots = data.foundBrainrots
	local foundBrainrotVariants = data.foundBrainrotVariants
	if type(foundBrainrots) ~= "table" then
		return 0
	end

	local best = 0

	for brainrotId, found in foundBrainrots do
		if found == true and type(brainrotId) == "string" then
			local bucket = if type(foundBrainrotVariants) == "table" then foundBrainrotVariants[brainrotId] else nil
			local usedVariantRow = false
			if type(bucket) == "table" then
				for variantId, variantFound in bucket do
					if variantFound == true and type(variantId) == "string" and VariantConfig.isKnown(variantId) then
						usedVariantRow = true
						local reveal = BrainrotConfig.getRevealData(brainrotId, variantId)
						local d = tonumber(reveal.rngDenominator) or 0
						if d > best then
							best = d
						end
					end
				end
			end
			if not usedVariantRow then
				local reveal = BrainrotConfig.getRevealData(brainrotId, VariantConfig.NORMAL_ID)
				local d = tonumber(reveal.rngDenominator) or 0
				if d > best then
					best = d
				end
			end
		end
	end

	return best
end

return BrainrotLeaderboardScore
