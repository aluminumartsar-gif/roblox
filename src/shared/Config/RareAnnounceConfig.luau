local EconomyConfig = require(script.Parent:WaitForChild("EconomyConfig"))

-- Tunable RNG gates: combined denominator from BrainrotConfig + variant (same as rngDenominator on drops).
local RareAnnounceConfig = {
	SERVER_THRESHOLD = 20_000,
	GLOBAL_THRESHOLD = 500_000,
	MESSAGING_TOPIC = "BrainrotGlobalRare_v1",
	-- Engine spatial tab name (client posts rare "here" lines here; server does not create this channel).
	CHANNEL_NAME_HERE = "Here",
	CHANNEL_NAME_GLOBAL = "Global",
	REMOTE_FOLDER = EconomyConfig.REMOTE_FOLDER,
	RARE_ANNOUNCE_REMOTE = "RareAnnounce",
	-- Default TextChat window height scale is 1; reduce to clear bottom-left HUD (allowed range 0.5–2).
	CHAT_WINDOW_HEIGHT_SCALE = 0.62,
}

return RareAnnounceConfig
