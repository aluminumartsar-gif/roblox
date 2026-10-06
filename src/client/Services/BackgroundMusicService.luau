--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Services = script.Parent
local SettingsService = require(Services:WaitForChild("SettingsService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local MusicConfig = require(ConfigFolder:WaitForChild("MusicConfig"))

local BackgroundMusicService = {}

local started = false
local currentSound: Sound? = nil
local activeTween: Tween? = nil

local function findTrack(trackId: string): MusicConfig.Track?
	for _, track in MusicConfig.Tracks do
		if track.id == trackId then
			return track
		end
	end

	return nil
end

local function stopActiveTween()
	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end
end

local function fadeVolume(sound: Sound, targetVolume: number)
	stopActiveTween()

	local tween = TweenService:Create(
		sound,
		TweenInfo.new(MusicConfig.FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Volume = targetVolume }
	)

	activeTween = tween
	tween.Completed:Once(function()
		if activeTween == tween then
			activeTween = nil
		end
	end)
	tween:Play()
end

local function buildSound(track: MusicConfig.Track): Sound
	local sound = Instance.new("Sound")
	sound.Name = "BackgroundMusic_" .. track.id
	sound.SoundId = track.soundId
	sound.Volume = 0
	sound.Looped = true
	sound.PlaybackSpeed = track.playbackSpeed or 1
	sound.SoundGroup = SettingsService.getMusicSoundGroup()
	sound.Parent = SoundService
	return sound
end

function BackgroundMusicService.start()
	if started then
		return
	end
	started = true

	SettingsService.start()

	local track = findTrack(MusicConfig.DEFAULT_TRACK_ID) or MusicConfig.Tracks[1]
	if not track then
		return
	end

	currentSound = buildSound(track)
	currentSound:Play()
	fadeVolume(currentSound, track.volume)
end

function BackgroundMusicService.stop()
	if not currentSound then
		return
	end

	local sound = currentSound
	currentSound = nil
	stopActiveTween()

	local tween = TweenService:Create(
		sound,
		TweenInfo.new(MusicConfig.FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Volume = 0 }
	)
	tween.Completed:Once(function()
		sound:Destroy()
	end)
	tween:Play()
end

return BackgroundMusicService
