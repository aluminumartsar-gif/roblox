-- Random weather effects that all stack multiplicatively into the dig luck
-- pipeline. Each effect rolls per-slot using a deterministic seed derived from
-- (slot, weather.salt) so every Roblox server -- regardless of region or
-- uptime -- agrees on which effects are active at any given second.
--
-- See WeatherSchedule (in shared/Util) for the per-slot active check.

export type WeatherId = "Night" | "Rain" | "Fog" | "Storm" | "Aurora"

export type WeatherEffect = {
	id: WeatherId,
	displayName: string,
	description: string,
	luckMultiplier: number,

	-- Schedule knobs.
	activeSeconds: number,        -- how long this effect runs once it triggers
	startChancePerSlot: number,   -- probability per SLOT_SECONDS slot that it triggers
	salt: number,                 -- per-effect RNG salt; keep distinct primes-ish

	-- Visual / HUD knobs.
	iconName: string,             -- key into IconAssets
	tintColor: Color3,
	clockTime: number?,           -- override Lighting.ClockTime while active (Night only today)
}

local WeatherConfig = {
	-- Slot length used for the deterministic schedule. Smaller = finer-grained
	-- start times (more "random" feeling) but more iterations per check.
	SLOT_SECONDS = 60,

	-- Server polling cadence for active-set diffing. Cheap; just bounds how
	-- soon a started/ended remote fires after the schedule transitions.
	TICK_SECONDS = 1,

	-- Lighting.ClockTime baseline that EnvironmentService configures. Restored
	-- when no clockTime-overriding effect is active.
	BASE_CLOCK_TIME = 16.5,

	EFFECTS = {} :: { [WeatherId]: WeatherEffect },
}

WeatherConfig.EFFECTS.Night = {
	id = "Night",
	displayName = "Night",
	description = "+1.25x luck",
	luckMultiplier = 1.25,
	activeSeconds = 300,
	startChancePerSlot = 0.0375,
	salt = 0xA1F3C7,
	iconName = "WeatherNight",
	tintColor = Color3.fromRGB(120, 130, 180),
	-- Dusk-ish "moonlit" hour rather than deep midnight, so the dig site
	-- stays readable without losing the night mood.
	clockTime = 20.5,
}

WeatherConfig.EFFECTS.Rain = {
	id = "Rain",
	displayName = "Rain",
	description = "+1.25x luck",
	luckMultiplier = 1.25,
	activeSeconds = 480,
	startChancePerSlot = 0.06,
	salt = 0x4B7C1F,
	iconName = "WeatherRain",
	tintColor = Color3.fromRGB(120, 160, 195),
}

WeatherConfig.EFFECTS.Fog = {
	id = "Fog",
	displayName = "Fog",
	description = "+1.5x luck",
	luckMultiplier = 1.5,
	activeSeconds = 360,
	startChancePerSlot = 0.0375,
	salt = 0x9D52E3,
	iconName = "WeatherFog",
	tintColor = Color3.fromRGB(195, 195, 205),
}

WeatherConfig.EFFECTS.Storm = {
	id = "Storm",
	displayName = "Storm",
	description = "+2x luck",
	luckMultiplier = 2.0,
	activeSeconds = 180,
	startChancePerSlot = 0.009,
	salt = 0x2E16BD,
	iconName = "WeatherStorm",
	tintColor = Color3.fromRGB(120, 100, 160),
}

WeatherConfig.EFFECTS.Aurora = {
	id = "Aurora",
	displayName = "Aurora",
	description = "+3x luck",
	luckMultiplier = 3.0,
	activeSeconds = 240,
	startChancePerSlot = 0.006,
	salt = 0x73A4C9,
	iconName = "WeatherAurora",
	tintColor = Color3.fromRGB(120, 220, 180),
}

return WeatherConfig
