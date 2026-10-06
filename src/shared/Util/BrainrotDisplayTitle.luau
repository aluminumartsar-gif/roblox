local VariantConfig = require(script.Parent.Parent:WaitForChild("Config"):WaitForChild("VariantConfig"))

local BrainrotDisplayTitle = {}

function BrainrotDisplayTitle.format(brainrotId: string, variantId: string?): string
	local resolved = if VariantConfig.isKnown(variantId) then variantId else VariantConfig.NORMAL_ID
	if resolved == VariantConfig.NORMAL_ID then
		return brainrotId
	end

	local variantEntry = VariantConfig.getById(resolved)
	return ("%s %s"):format(variantEntry.displayName, brainrotId)
end

return BrainrotDisplayTitle
