--!strict
--[[
	SoundController
	StarterPlayerScripts/Client/Controllers/SoundController

	Every sound in the game is played through here, by name. The names and
	asset ids live in Config.Sounds; an unknown name does nothing (Studio
	warns once), so a missing sound can never break a feature.

	  SoundController.Play(name, opts?)                 -- 2D ("in your head")
	  SoundController.PlayAt(name, positionOrPart, opts?) -- 3D, in the world
	    opts: { Volume?, PlaybackSpeed?, RollOff?, IfQuietFor? }
	      IfQuietFor = seconds: skip this sound if any other sound started
	      that recently (stops toasts piling on top of a hatch fanfare).
	  Both return the Sound (or nil). A Looped sound (e.g. SightingAmbience)
	  keeps playing until the caller does sound:Destroy().

	Also runs the background audio: the music loop, the night ambience, a
	far-off owl now and then, and the crackle at the hub campfire (at parts
	tagged Config.Feedback.CampfireTag if the map tags any, otherwise at the
	hub centre, where the campfire is).

	Settings: two SoundGroups under SoundService. "Sounds" OFF mutes every
	effect and the ambience; "Music" OFF mutes the music. SettingsController
	calls SetSoundsEnabled / SetMusicEnabled.

	Every button click plays UIClick and every kit popup opening plays
	UIOpen, hooked here once for the whole UI. Kit buttons (tagged
	"UIButton") keep the kit's own click instead; any button can opt out
	with the attribute SAC_NoClick = true.

	Safe to call before Start(): Play/PlayAt set themselves up on first use.
]]

local CollectionService = game:GetService("CollectionService")
local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local BeltPath = require(Shared:WaitForChild("BeltPath"))

local SoundController = {}

type SoundDef = {
	Id: string,
	Volume: number?,
	PlaybackSpeed: number?,
	Looped: boolean?,
	RollOff: number?,
	Group: string?,
}

export type PlayOpts = {
	Volume: number?,
	PlaybackSpeed: number?,
	RollOff: number?,
	IfQuietFor: number?,
}

local FX = Config.Feedback
local localPlayer = Players.LocalPlayer

-- The STUD kit's tag for buttons it animates (and gives its own click).
local KIT_BUTTON_TAG = "UIButton"

-- Set up lazily by ensureSetup().
local effectsGroup: SoundGroup? = nil
local musicGroup: SoundGroup? = nil
local poolFolder: Folder? = nil
local anchorPart: BasePart? = nil

local pools: { [string]: { Sound } } = {}
local warned: { [string]: boolean } = {}
local lastPlayAt = -math.huge
local soundsOn = true
local musicOn = true
local startedAt = os.clock()

--------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------

local function ensureSetup()
	if effectsGroup then
		return
	end
	local effects = Instance.new("SoundGroup")
	effects.Name = "SAC_Effects"
	effects.Volume = 1
	effects.Parent = SoundService
	effectsGroup = effects

	local music = Instance.new("SoundGroup")
	music.Name = "SAC_Music"
	music.Volume = 1
	music.Parent = SoundService
	musicGroup = music

	local folder = Instance.new("Folder")
	folder.Name = "SAC_Sounds"
	folder.Parent = SoundService
	poolFolder = folder

	-- One invisible, client-only part; 3D sounds at a position ride on
	-- Attachments under it. Client-made parts never stream out.
	local fxFolder = Workspace:FindFirstChild("SAC_ClientFX")
	if not fxFolder then
		fxFolder = Instance.new("Folder")
		fxFolder.Name = "SAC_ClientFX"
		fxFolder.Parent = Workspace
	end
	local anchor = Instance.new("Part")
	anchor.Name = "SoundAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one
	anchor.CFrame = CFrame.new()
	anchor.Parent = fxFolder
	anchorPart = anchor
end

local function getDef(name: string): SoundDef?
	local def = (Config.Sounds :: any)[name]
	if typeof(def) ~= "table" or typeof(def.Id) ~= "string" or def.Id == "" then
		if not warned[name] and RunService:IsStudio() then
			warned[name] = true
			warn("[SAC/Sound] No sound called '" .. tostring(name) .. "' in Config.Sounds (ignored)")
		end
		return nil
	end
	return def :: SoundDef
end

local function groupFor(def: SoundDef): SoundGroup?
	return if def.Group == "Music" then musicGroup else effectsGroup
end

local function configure(sound: Sound, def: SoundDef, opts: PlayOpts?)
	sound.SoundId = def.Id
	sound.Volume = (opts and opts.Volume) or def.Volume or 0.5
	sound.PlaybackSpeed = (opts and opts.PlaybackSpeed) or def.PlaybackSpeed or 1
	sound.Looped = def.Looped == true
	sound.SoundGroup = groupFor(def)
end

local function configure3D(sound: Sound, def: SoundDef, opts: PlayOpts?)
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = FX.DefaultRollOffMin
	sound.RollOffMaxDistance = (opts and opts.RollOff) or def.RollOff or FX.DefaultRollOff
end

--- true if this play should be skipped because something else just played.
local function tooSoon(opts: PlayOpts?): boolean
	local quiet = opts and opts.IfQuietFor
	return quiet ~= nil and os.clock() - lastPlayAt < quiet
end

--------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------

--- Plays a sound with no position (UI, stings, music). Returns the Sound.
function SoundController.Play(name: string, opts: PlayOpts?): Sound?
	local def = getDef(name)
	if not def or tooSoon(opts) then
		return nil
	end
	ensureSetup()
	lastPlayAt = os.clock()

	if def.Looped then
		-- Loops are owned by the caller (they Destroy it to stop).
		local loop = Instance.new("Sound")
		loop.Name = name
		configure(loop, def, opts)
		loop.Parent = poolFolder
		loop:Play()
		return loop
	end

	-- Small pool per name so rapid repeats overlap instead of cutting off.
	local pool = pools[name]
	if not pool then
		pool = {}
		pools[name] = pool
	end
	local sound: Sound? = nil
	for _, candidate in ipairs(pool) do
		if not candidate.IsPlaying then
			sound = candidate
			break
		end
	end
	if not sound then
		if #pool < FX.SoundVoicesPerName then
			local fresh = Instance.new("Sound")
			fresh.Name = name
			fresh.Parent = poolFolder
			table.insert(pool, fresh)
			sound = fresh
		else
			-- All busy: restart the oldest one.
			local oldest = table.remove(pool, 1) :: Sound
			table.insert(pool, oldest)
			sound = oldest
		end
	end
	local chosen = sound :: Sound
	configure(chosen, def, opts)
	chosen.TimePosition = 0
	chosen:Play()
	return chosen
end

--- Plays a sound in the world, at a position or on a part/attachment (it
--- follows a part as it moves). Returns the Sound.
function SoundController.PlayAt(name: string, target: Vector3 | Instance, opts: PlayOpts?): Sound?
	local def = getDef(name)
	if not def or tooSoon(opts) then
		return nil
	end
	ensureSetup()
	lastPlayAt = os.clock()

	local parent: Instance
	local holder: Attachment? = nil
	if typeof(target) == "Vector3" then
		local attachment = Instance.new("Attachment")
		attachment.Name = "Sound_" .. name
		attachment.Parent = anchorPart
		attachment.WorldPosition = target
		holder = attachment
		parent = attachment
	elseif typeof(target) == "Instance" and (target:IsA("BasePart") or target:IsA("Attachment")) then
		parent = target
	else
		return nil
	end

	local sound = Instance.new("Sound")
	sound.Name = "SAC_" .. name
	configure(sound, def, opts)
	configure3D(sound, def, opts)
	sound.Parent = parent
	sound:Play()

	if not def.Looped then
		local function cleanUp()
			if holder then
				holder:Destroy()
			else
				sound:Destroy()
			end
		end
		sound.Ended:Connect(cleanUp)
		task.delay(FX.SoundMaxLifetime, function()
			if sound.Parent then
				cleanUp()
			end
		end)
	elseif holder then
		-- A looped sound at a position: destroying the sound frees the anchor.
		local attachment = holder
		sound.Destroying:Connect(function()
			attachment:Destroy()
		end)
	end
	return sound
end

function SoundController.SetSoundsEnabled(on: boolean)
	soundsOn = on
	ensureSetup()
	local group = effectsGroup :: SoundGroup
	group.Volume = if on then 1 else 0
end

function SoundController.SetMusicEnabled(on: boolean)
	musicOn = on
	ensureSetup()
	local group = musicGroup :: SoundGroup
	group.Volume = if on then 1 else 0
end

function SoundController.SoundsEnabled(): boolean
	return soundsOn
end

function SoundController.MusicEnabled(): boolean
	return musicOn
end

--- The SoundGroup our sounds play through (for other code making its own
--- Sounds that should obey the Sounds setting).
function SoundController.EffectsGroup(): SoundGroup
	ensureSetup()
	return effectsGroup :: SoundGroup
end

--------------------------------------------------------------------------
-- Background audio
--------------------------------------------------------------------------

local function fadeIn(sound: Sound?, seconds: number)
	if not sound then
		return
	end
	local target = sound.Volume
	sound.Volume = 0
	TweenService:Create(sound, TweenInfo.new(seconds), { Volume = target }):Play()
end

local function startCampfire()
	local tag = FX.CampfireTag
	local fallback: Sound? = nil
	local tagged: { [Instance]: Sound } = {}
	local seenTagged = false

	local function addTagged(part: Instance)
		if tagged[part] or not part:IsA("BasePart") then
			return
		end
		seenTagged = true
		if fallback then
			fallback:Destroy()
			fallback = nil
		end
		local sound = SoundController.PlayAt("Campfire", part)
		if sound then
			tagged[part] = sound
		end
	end
	for _, part in ipairs(CollectionService:GetTagged(tag)) do
		addTagged(part)
	end
	CollectionService:GetInstanceAddedSignal(tag):Connect(addTagged)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(function(part)
		local sound = tagged[part]
		tagged[part] = nil
		if sound then
			sound:Destroy()
		end
	end)

	-- No tagged campfire yet (not streamed in): crackle at the hub centre,
	-- where MapBuilder puts the hub campfire.
	if not seenTagged then
		fallback = SoundController.PlayAt("Campfire", BeltPath.Center + Vector3.new(0, FX.CampfireHeight, 0))
	end
end

local function startOwls()
	task.spawn(function()
		while true do
			task.wait(FX.OwlMinInterval + math.random() * (FX.OwlMaxInterval - FX.OwlMinInterval))
			local camera = Workspace.CurrentCamera
			if camera then
				local angle = math.random() * math.pi * 2
				local range: NumberRange = FX.OwlDistance
				local distance = range.Min + math.random() * (range.Max - range.Min)
				local offset = Vector3.new(math.cos(angle) * distance, FX.OwlHeight, math.sin(angle) * distance)
				SoundController.PlayAt("Owl", camera.CFrame.Position + offset)
			end
		end
	end)
end

--------------------------------------------------------------------------
-- UI hooks: clicks and popups
--------------------------------------------------------------------------

local function hookButton(button: GuiButton)
	button.Activated:Connect(function()
		-- Kit buttons already click (the kit's UIAnimations plays its own
		-- sound for anything tagged UIButton).
		if button:GetAttribute("SAC_NoClick") ~= true and not CollectionService:HasTag(button, KIT_BUTTON_TAG) then
			SoundController.Play("UIClick")
		end
	end)
end

local function hookScreen(gui: ScreenGui)
	-- Kit popups have a Container and are shown by enabling the ScreenGui.
	gui:GetPropertyChangedSignal("Enabled"):Connect(function()
		if gui.Enabled and gui:FindFirstChild("Container") and os.clock() - startedAt > 2 then
			SoundController.Play("UIOpen")
		end
	end)
end

local function hookUi()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	for _, d in ipairs(playerGui:GetDescendants()) do
		if d:IsA("GuiButton") then
			hookButton(d)
		elseif d:IsA("ScreenGui") then
			hookScreen(d)
		end
	end
	playerGui.DescendantAdded:Connect(function(d)
		if d:IsA("GuiButton") then
			hookButton(d)
		elseif d:IsA("ScreenGui") then
			hookScreen(d)
		end
	end)
end

--------------------------------------------------------------------------
-- Studio self-check: tells the developer which ids don't load
--------------------------------------------------------------------------

local function studioCheck()
	if not RunService:IsStudio() or not FX.StudioSoundCheck then
		return
	end
	task.delay(5, function()
		ensureSetup()
		local folder = Instance.new("Folder")
		folder.Name = "SAC_SoundCheck"
		folder.Parent = SoundService
		local probes: { Sound } = {}
		for name, def in pairs(Config.Sounds :: any) do
			local probe = Instance.new("Sound")
			probe.Name = name
			probe.SoundId = def.Id
			probe.Volume = 0
			probe.Parent = folder
			table.insert(probes, probe)
		end
		pcall(function()
			ContentProvider:PreloadAsync(probes)
		end)
		task.wait(8)
		local failed = {}
		for _, probe in ipairs(probes) do
			if not probe.IsLoaded or probe.TimeLength <= 0 then
				table.insert(failed, probe.Name)
			end
		end
		table.sort(failed)
		if #failed == 0 then
			print(string.format("[SAC/Sound] all %d sounds loaded", #probes))
		else
			warn(string.format("[SAC/Sound] %d of %d sounds did NOT load: %s", #failed, #probes, table.concat(failed, ", ")))
		end
		folder:Destroy()
	end)
end

--------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------

function SoundController.Start()
	ensureSetup()
	startedAt = os.clock()

	-- Warm the cache so the first click/coin isn't silent.
	task.spawn(function()
		local warm: { Instance } = {}
		for _, def in pairs(Config.Sounds :: any) do
			local s = Instance.new("Sound")
			s.SoundId = def.Id
			table.insert(warm, s)
		end
		pcall(function()
			ContentProvider:PreloadAsync(warm)
		end)
	end)

	task.spawn(hookUi)

	-- Background audio, after the world has had a moment to load.
	task.delay(2, function()
		fadeIn(SoundController.Play("MusicMain"), FX.MusicFadeTime)
		fadeIn(SoundController.Play("AmbientNight"), FX.MusicFadeTime)
		fadeIn(SoundController.Play("AmbientDread"), FX.MusicFadeTime)
		startCampfire()
		startOwls()
	end)

	studioCheck()
end

return SoundController
