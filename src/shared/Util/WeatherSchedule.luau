-- Deterministic schedule shared by WeatherService (server) and the HUD-side
-- consumers (RebirthController for the LuckCounter, WeatherTrayUI for live
-- countdowns). Identical inputs (os.time + WeatherConfig) on every Roblox
-- server produce identical outputs, so the world is always in sync without
-- MessagingService or DataStore round-trips.
--
-- Algorithm (per effect):
--   1. Slice time into SLOT_SECONDS-sized slots: slot = floor(now / SLOT_SECONDS).
--   2. For each slot in [now's slot, now's slot - activeSlots], seed an RNG
--      with (slot, weather.salt) and roll start. The earliest matching slot
--      whose start..start+activeSeconds window still contains `now` defines
--      the active occurrence.
--   3. The effect is active iff such a slot exists; expiresAt is start + activeSeconds.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local WeatherConfig = require(ConfigFolder:WaitForChild("WeatherConfig"))

type WeatherEffect = WeatherConfig.WeatherEffect

local WeatherSchedule = {}

export type ActiveWeather = {
	id: WeatherConfig.WeatherId,
	luckMultiplier: number,
	startedAt: number,
	expiresAt: number,
}

-- Mixed-prime hash so adjacent slots produce uncorrelated seeds. The factor
-- 73856093 is a common large prime used in spatial hashes; combined with the
-- per-effect salt it gives every (slot, weather) pair its own RNG stream.
local function seedFor(slot: number, salt: number): number
	-- Random.new accepts any number; force into a 32-bit-ish integer range so
	-- the seed is stable across platforms.
	return (slot * 73856093 + salt * 19349663) % 2147483647
end

local function rollsActive(slot: number, weather: WeatherEffect): boolean
	local rng = Random.new(seedFor(slot, weather.salt))
	return rng:NextNumber() < weather.startChancePerSlot
end

-- Returns the most recent slot at or before currentSlot that rolled this
-- weather on AND whose start..start+activeSeconds window still contains `now`.
-- Returns nil if the weather isn't active right now.
local function findActiveStartSlot(weather: WeatherEffect, now: number): number?
	local slotSeconds = WeatherConfig.SLOT_SECONDS
	local currentSlot = math.floor(now / slotSeconds)
	local activeSlots = math.ceil(weather.activeSeconds / slotSeconds)

	-- Walk newest -> oldest so the first match is the active occurrence and
	-- we exit early once we pass beyond what could still be running.
	for offset = 0, activeSlots do
		local slot = currentSlot - offset
		if rollsActive(slot, weather) then
			local startedAt = slot * slotSeconds
			if now < startedAt + weather.activeSeconds then
				return slot
			end
		end
	end

	return nil
end

-- Public: snapshot of every effect that is active at `now`.
function WeatherSchedule.getActive(now: number): { ActiveWeather }
	local active: { ActiveWeather } = {}
	for _, weather in WeatherConfig.EFFECTS do
		local slot = findActiveStartSlot(weather, now)
		if slot then
			local startedAt = slot * WeatherConfig.SLOT_SECONDS
			table.insert(active, {
				id = weather.id,
				luckMultiplier = weather.luckMultiplier,
				startedAt = startedAt,
				expiresAt = startedAt + weather.activeSeconds,
			})
		end
	end
	return active
end

-- Public: convenience helper that returns the multiplicative product of every
-- active weather effect's luckMultiplier (1 if none are active).
function WeatherSchedule.getLuckMultiplier(now: number): number
	local total = 1
	for _, weather in WeatherConfig.EFFECTS do
		if findActiveStartSlot(weather, now) then
			total *= weather.luckMultiplier
		end
	end
	return total
end

-- Public: query a specific effect. Used by the tray UI to recompute its
-- per-icon countdown without re-walking the whole config every tick.
function WeatherSchedule.getActiveFor(id: WeatherConfig.WeatherId, now: number): ActiveWeather?
	local weather = WeatherConfig.EFFECTS[id]
	if not weather then
		return nil
	end

	local slot = findActiveStartSlot(weather, now)
	if not slot then
		return nil
	end

	local startedAt = slot * WeatherConfig.SLOT_SECONDS
	return {
		id = weather.id,
		luckMultiplier = weather.luckMultiplier,
		startedAt = startedAt,
		expiresAt = startedAt + weather.activeSeconds,
	}
end

return WeatherSchedule
