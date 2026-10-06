--!strict
-- Background music catalogue. Keep music asset IDs here so the active track can
-- be swapped without touching playback code.

local MusicConfig = {}

export type Track = {
	id: string,
	name: string,
	soundId: string,
	volume: number,
	playbackSpeed: number?,
}

MusicConfig.DEFAULT_TRACK_ID = "ParadiseFalls"
MusicConfig.FADE_TIME = 1.5

MusicConfig.Tracks = {
	{
		id = "ParadiseFalls",
		name = "Paradise Falls",
		soundId = "rbxassetid://1837879082",
		volume = 0.18,
		playbackSpeed = 1,
	},
	{
		id = "LofiChillA",
		name = "Lofi Chill A",
		soundId = "rbxassetid://9043887091",
		volume = 0.22,
		playbackSpeed = 1,
	},
} :: { Track }

return MusicConfig
