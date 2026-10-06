-- Rich text for rare pickup announcements in TextChat (DisplaySystemMessage).

local BrainrotConfig = require(script.Parent.Parent:WaitForChild("Config"):WaitForChild("BrainrotConfig"))
local VariantConfig = require(script.Parent.Parent:WaitForChild("Config"):WaitForChild("VariantConfig"))
local FormatUtil = require(script.Parent:WaitForChild("FormatUtil"))

local RareAnnounceRichText = {}

local function color3ToHex(c: Color3): string
	local r = math.clamp(math.floor(c.R * 255 + 0.5), 0, 255)
	local g = math.clamp(math.floor(c.G * 255 + 0.5), 0, 255)
	local b = math.clamp(math.floor(c.B * 255 + 0.5), 0, 255)
	return string.format("#%02X%02X%02X", r, g, b)
end

local function escapePlain(s: string): string
	return (s
		:gsub("&", "&amp;")
		:gsub("<", "&lt;")
		:gsub(">", "&gt;")
		:gsub('"', "&quot;"))
end

-- Brighter accent by combined RNG denominator (matches “rarer = punchier” in chat).
local function tierAccentColor(denom: number): Color3
	if denom >= 100_000_000 then
		return Color3.fromRGB(80, 255, 255)
	end
	if denom >= 10_000_000 then
		return Color3.fromRGB(255, 96, 96)
	end
	if denom >= 5_000_000 then
		return Color3.fromRGB(255, 64, 210)
	end
	if denom >= 500_000 then
		return Color3.fromRGB(218, 166, 255)
	end
	if denom >= 100_000 then
		return Color3.fromRGB(154, 212, 255)
	end
	return Color3.fromRGB(166, 255, 184)
end

function RareAnnounceRichText.buildAnnouncement(
	displayName: string,
	denom: number,
	brainrotId: string,
	variantId: string?
)
	local reveal = BrainrotConfig.getRevealData(brainrotId, variantId)
	local resolvedVariant = if VariantConfig.isKnown(variantId) then variantId else VariantConfig.NORMAL_ID

	local oddsPlain = ("1/%s"):format(FormatUtil.compactNumber(math.max(1, math.floor(denom))))

	local nameHex = color3ToHex(tierAccentColor(denom))
	local muteHex = "#B8BCC4"
	local bangHex = "#FFFFFF"

	local brainrotHex = color3ToHex(reveal.revealColor)
	local oddsLerpTarget = reveal.revealColor
	local titleChunks: { string }

	if resolvedVariant ~= VariantConfig.NORMAL_ID then
		local variantEntry = VariantConfig.getById(resolvedVariant)
		local variantHex = color3ToHex(VariantConfig.getNameColor(resolvedVariant))
		oddsLerpTarget = VariantConfig.getNameColor(resolvedVariant)
		titleChunks = {
			('<font color="%s">'):format(variantHex),
			escapePlain(variantEntry.displayName),
			"</font>",
			('<font color="%s"> </font>'):format(muteHex),
			('<font color="%s">'):format(brainrotHex),
			escapePlain(brainrotId),
			"</font>",
		}
	else
		titleChunks = {
			('<font color="%s">'):format(brainrotHex),
			escapePlain(brainrotId),
			"</font>",
		}
	end

	local oddsHex = color3ToHex(tierAccentColor(denom):Lerp(oddsLerpTarget, 0.35))

	local safeName = escapePlain(displayName)
	local safeOdds = escapePlain(oddsPlain)

	return table.concat({
		('<font color="%s">'):format(nameHex),
		safeName,
		"</font>",
		('<font color="%s"> got </font>'):format(muteHex),
		table.concat(titleChunks),
		('<font color="%s"> (</font>'):format(muteHex),
		('<font color="%s">'):format(oddsHex),
		safeOdds,
		"</font>",
		('<font color="%s">)</font>'):format(muteHex),
		('<font color="%s">!</font>'):format(bangHex),
	})
end

return RareAnnounceRichText
