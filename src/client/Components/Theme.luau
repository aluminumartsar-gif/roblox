--!strict
--[[
	Theme
	StarterPlayerScripts/Client/Components/Theme

	The "campfire field kit" look, read from Config.UI.Theme. Screens never
	hard-code a colour or font: they ask Theme.

	  Theme.Colors.Ember                    -- palette (Config.UI.Theme.Colors)
	  Theme.Font("Heading", "Bold")         -- a Font for a role and weight
	  Theme.Fonts.Display                   -- ready-made Fonts (see below)
	  Theme.RarityColor("Epic")             -- rarity colour, readable on dark UI
	  Theme.Mix(a, b, t)                    -- blend two colours
	  Theme.Sequence(top, bottom, mid?)     -- vertical ColorSequence helper
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local tuning = Config.UI.Theme

local Theme = {}

Theme.Colors = tuning.Colors
Theme.Tuning = tuning

local WEIGHTS: { [string]: Enum.FontWeight } = {
	Light = Enum.FontWeight.Light,
	Regular = Enum.FontWeight.Regular,
	Medium = Enum.FontWeight.Medium,
	SemiBold = Enum.FontWeight.SemiBold,
	Bold = Enum.FontWeight.Bold,
	Heavy = Enum.FontWeight.Heavy,
}

--- A Font for a role in Config.UI.Theme.Fonts ("Display", "Heading",
--- "Body", "Notes", "Mono") and an optional weight name.
function Theme.Font(role: string, weight: string?): Font
	local family = tuning.Fonts[role] or tuning.Fonts.Body
	return Font.fromName(family, WEIGHTS[weight or "Regular"] or Enum.FontWeight.Regular)
end

Theme.Fonts = {
	Display = Theme.Font("Display"),
	Heading = Theme.Font("Heading", "Bold"),
	HeadingSemi = Theme.Font("Heading", "SemiBold"),
	Body = Theme.Font("Body", "Regular"),
	BodyMedium = Theme.Font("Body", "Medium"),
	Notes = Theme.Font("Notes"),
	Mono = Theme.Font("Mono", "Bold"),
}

function Theme.Mix(a: Color3, b: Color3, t: number): Color3
	return a:Lerp(b, t)
end

--- Rarity colour for UI. The Secret rarity's own colour is near-black, so
--- text and tags use Colors.SecretText instead.
function Theme.RarityColor(rarity: string): Color3
	local info = Config.Rarities[rarity]
	if not info then
		return Theme.Colors.TextDim
	end
	if info.NeverRenderClearly then
		return Theme.Colors.SecretText
	end
	return info.Color
end

--- Top-to-bottom ColorSequence (use with a UIGradient at Rotation 90).
function Theme.Sequence(top: Color3, bottom: Color3, middle: Color3?): ColorSequence
	if middle then
		return ColorSequence.new({
			ColorSequenceKeypoint.new(0, top),
			ColorSequenceKeypoint.new(0.45, middle),
			ColorSequenceKeypoint.new(1, bottom),
		})
	end
	return ColorSequence.new(top, bottom)
end

return Theme
