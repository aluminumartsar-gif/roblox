-- Shared identifiers for the top-bar teleport flow. Both the client UI and the
-- server TeleportService key off these constants so the wire format is in one
-- place and future destinations only need an entry here + a server handler.

local TeleportConfig = {
	REMOTE_FOLDER = "TeleportRemotes",
	TELEPORT_REQUEST_REMOTE = "TeleportRequest",

	DESTINATION_BASE = "Base",
	DESTINATION_SHOP = "Shop",
	DESTINATION_SELL = "Sell",
	DESTINATION_UPGRADE = "Upgrade",

	-- Per-player cooldown between teleport requests on the server. Matches the
	-- pop-in delay of the buttons so honest taps always go through but spam
	-- clicks (or a malicious client) can't burn the physics budget.
	REQUEST_DEBOUNCE_SECONDS = 0.5,

	-- How far in front of the shopkeeper to land the player. Far enough that
	-- the character doesn't spawn inside the NPC, close enough that the
	-- existing ShopBoothController proximity check (12 stud open radius) fires
	-- on the very next heartbeat.
	SHOP_LANDING_OFFSET_STUDS = 6,

	-- Vertical lift applied on every teleport so the character doesn't clip
	-- into the floor part it's pivoted onto.
	TELEPORT_HEIGHT_OFFSET_STUDS = 4,
}

function TeleportConfig.isKnownDestination(destination: any): boolean
	return destination == TeleportConfig.DESTINATION_BASE
		or destination == TeleportConfig.DESTINATION_SHOP
		or destination == TeleportConfig.DESTINATION_SELL
		or destination == TeleportConfig.DESTINATION_UPGRADE
end

return TeleportConfig
