--!strict
-- Client-side settings store. Owns user audio preferences, applies them to
-- SoundService SoundGroups so any Sound that opts into the Music or SFX group
-- automatically respects the player's volume + mute, and exposes an OnChange
-- callback so the SettingsUI (and any future consumer) can react.
--
-- Settings are session-only today (kept in memory). To persist across rejoins,
-- thread them through PlayerDataService and seed them on `start`.

local SoundService = game:GetService("SoundService")

local SettingsService = {}

local MUSIC_GROUP_NAME = "Music"
local SFX_GROUP_NAME = "SFX"
local DEFAULT_MUSIC_VOLUME = 0.5
local DEFAULT_SFX_VOLUME = 0.8

export type SettingKey = "musicVolume" | "sfxVolume" | "musicEnabled" | "sfxEnabled"

export type SettingsSnapshot = {
	musicVolume: number,
	sfxVolume: number,
	musicEnabled: boolean,
	sfxEnabled: boolean,
}

local state: SettingsSnapshot = {
	musicVolume = DEFAULT_MUSIC_VOLUME,
	sfxVolume = DEFAULT_SFX_VOLUME,
	musicEnabled = true,
	sfxEnabled = true,
}

local listeners: { (SettingKey, any) -> () } = {}
local started = false

local function ensureSoundGroup(name: string): SoundGroup
	local existing = SoundService:FindFirstChild(name)
	if existing and existing:IsA("SoundGroup") then
		return existing
	elseif existing then
		existing:Destroy()
	end

	local group = Instance.new("SoundGroup")
	group.Name = name
	group.Volume = 1
	group.Parent = SoundService

	return group
end

local function getMusicGroup(): SoundGroup
	return ensureSoundGroup(MUSIC_GROUP_NAME)
end

local function getSfxGroup(): SoundGroup
	return ensureSoundGroup(SFX_GROUP_NAME)
end

local function clampVolume(value: number): number
	if value ~= value then
		return 0
	end

	return math.clamp(value, 0, 1)
end

local function applyMusicVolume()
	local group = getMusicGroup()
	group.Volume = if state.musicEnabled then state.musicVolume else 0
end

local function applySfxVolume()
	local group = getSfxGroup()
	group.Volume = if state.sfxEnabled then state.sfxVolume else 0
end

local function notify(key: SettingKey, value: any)
	for _, listener in listeners do
		task.spawn(listener, key, value)
	end
end

function SettingsService.start()
	if started then
		return
	end
	started = true

	getMusicGroup()
	getSfxGroup()
	applyMusicVolume()
	applySfxVolume()
end

function SettingsService.getSnapshot(): SettingsSnapshot
	return {
		musicVolume = state.musicVolume,
		sfxVolume = state.sfxVolume,
		musicEnabled = state.musicEnabled,
		sfxEnabled = state.sfxEnabled,
	}
end

function SettingsService.getMusicVolume(): number
	return state.musicVolume
end

function SettingsService.getSfxVolume(): number
	return state.sfxVolume
end

function SettingsService.isMusicEnabled(): boolean
	return state.musicEnabled
end

function SettingsService.isSfxEnabled(): boolean
	return state.sfxEnabled
end

function SettingsService.setMusicVolume(value: number)
	local clamped = clampVolume(value)
	if clamped == state.musicVolume then
		return
	end

	state.musicVolume = clamped
	applyMusicVolume()
	notify("musicVolume", clamped)
end

function SettingsService.setSfxVolume(value: number)
	local clamped = clampVolume(value)
	if clamped == state.sfxVolume then
		return
	end

	state.sfxVolume = clamped
	applySfxVolume()
	notify("sfxVolume", clamped)
end

function SettingsService.setMusicEnabled(enabled: boolean)
	if enabled == state.musicEnabled then
		return
	end

	state.musicEnabled = enabled
	applyMusicVolume()
	notify("musicEnabled", enabled)
end

function SettingsService.setSfxEnabled(enabled: boolean)
	if enabled == state.sfxEnabled then
		return
	end

	state.sfxEnabled = enabled
	applySfxVolume()
	notify("sfxEnabled", enabled)
end

function SettingsService.getMusicSoundGroup(): SoundGroup
	return getMusicGroup()
end

function SettingsService.getSfxSoundGroup(): SoundGroup
	return getSfxGroup()
end

-- Subscribe to setting changes. Returns a disconnect function.
function SettingsService.onChange(callback: (SettingKey, any) -> ()): () -> ()
	table.insert(listeners, callback)

	return function()
		for index, registered in listeners do
			if registered == callback then
				table.remove(listeners, index)
				return
			end
		end
	end
end

return SettingsService
