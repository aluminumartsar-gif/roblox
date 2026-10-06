local FormatUtil = {}

-- Use compact suffixes from 1k up so cash labels read as "25k" instead of
-- "25640". Values below 1k stay as plain integers because there's no shorter
-- form, and values from 1k..10k keep one decimal so small prices like 1.5k
-- don't visually collapse to "1k".
local COMPACT_THRESHOLD = 1_000
-- Largest-first: every step is ×1000 (short scale). Without T/Qa/Qi (etc.),
-- anything past ~999B incorrectly stays on "B" and prints giant digit strings.
local SUFFIXES = {
	{ value = 1_000_000_000_000_000_000_000_000, suffix = "Sp" },
	{ value = 1_000_000_000_000_000_000_000, suffix = "Sx" },
	{ value = 1_000_000_000_000_000_000, suffix = "Qi" },
	{ value = 1_000_000_000_000_000, suffix = "Qa" },
	{ value = 1_000_000_000_000, suffix = "T" },
	{ value = 1_000_000_000, suffix = "B" },
	{ value = 1_000_000, suffix = "M" },
	{ value = 1_000, suffix = "k" },
}

local function trimDecimalZeros(text: string)
	local trimmed = text:gsub("%.0$", "")
	return trimmed
end

function FormatUtil.compactNumber(value: number)
	local flooredValue = math.floor(value)
	local absValue = math.abs(flooredValue)
	if absValue < COMPACT_THRESHOLD then
		return tostring(flooredValue)
	end

	for _, suffixData in SUFFIXES do
		if absValue >= suffixData.value then
			local compactValue = flooredValue / suffixData.value
			if math.abs(compactValue) >= 10 then
				return ("%d%s"):format(math.floor(compactValue), suffixData.suffix)
			end

			return ("%s%s"):format(trimDecimalZeros(("%.1f"):format(compactValue)), suffixData.suffix)
		end
	end

	return tostring(flooredValue)
end

function FormatUtil.money(value: number)
	return "$" .. FormatUtil.compactNumber(value)
end

function FormatUtil.multiplier(value: number)
	return ("%.2fx"):format(value)
end

return FormatUtil
