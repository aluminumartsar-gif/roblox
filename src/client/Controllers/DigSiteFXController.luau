local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local DigSiteConfig = require(ConfigFolder:WaitForChild("DigSiteConfig"))

local DigSiteFXController = {}
local started = false

local PROXIMITY_CHECK_INTERVAL = 0.18
local PROXIMITY_CHIME_ID = "rbxasset://sounds/electronicpingshort.wav"

-- Pitch ramp per tier so the chime audibly hints at value as the player
-- crosses into a spot. Pitched in roughly equal-temperament steps so each
-- tier feels like a distinct rung. The default fallback covers any future
-- tier name added to the config without a corresponding entry here.
local TIER_CHIME_PITCH = {
	Common = 1.0,
	Uncommon = 1.05,
	Rare = 1.12,
	Epic = 1.25,
	Legendary = 1.4,
	Mythic = 1.6,
	Celestial = 1.8,
	Divine = 2.0,
	Eldritch = 2.2,
	Cosmic = 2.5,
}
local DEFAULT_CHIME_PITCH = 1

local function getDigSite()
	return Workspace:FindFirstChild(DigSiteConfig.MODEL_NAME)
end

local function getActiveSpotsFolder()
	local digSite = getDigSite()
	if not digSite then
		return nil
	end

	return digSite:FindFirstChild(DigSiteConfig.ACTIVE_SPOTS_FOLDER_NAME)
end

local function setupProximityChime()
	local sound = Instance.new("Sound")
	sound.Name = "GroundSpotChime"
	sound.SoundId = PROXIMITY_CHIME_ID
	sound.Volume = 0.65
	sound.Parent = SoundService

	-- Track which spots the player is currently inside so we only chime when
	-- they cross the threshold (not every frame they stand on it).
	local insideSpots: { [Model]: boolean } = {}

	task.spawn(function()
		while started do
			task.wait(PROXIMITY_CHECK_INTERVAL)

			local character = localPlayer.Character
			local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
			local activeSpotsFolder = getActiveSpotsFolder()

			if not root or not root:IsA("BasePart") or not activeSpotsFolder then
				if next(insideSpots) ~= nil then
					table.clear(insideSpots)
				end
				continue
			end

			local rootPosition = root.Position
			local seen: { [Model]: boolean } = {}
			local range = DigSiteConfig.GROUND_SPOT_PROXIMITY_SOUND_RANGE

			for _, marker in activeSpotsFolder:GetChildren() do
				if marker:IsA("Model") and marker.Name == DigSiteConfig.GROUND_SPOT_MARKER_NAME then
					local position = marker:GetAttribute(DigSiteConfig.GROUND_SPOT_POSITION_ATTRIBUTE)
					if typeof(position) == "Vector3" then
						local horizontalDelta = Vector3.new(rootPosition.X - position.X, 0, rootPosition.Z - position.Z)
						if horizontalDelta.Magnitude <= range then
							seen[marker] = true
							if not insideSpots[marker] then
								insideSpots[marker] = true
								local tier = marker:GetAttribute(DigSiteConfig.GROUND_SPOT_TIER_ATTRIBUTE)
								-- Pitch the chime up a bit for rarer tiers so the audio cue
								-- still hints at "something better" without being loud.
								-- Driven by a table so newly added tiers don't silently fall
								-- through to the default pitch.
								local playbackSpeed = TIER_CHIME_PITCH[tier] or DEFAULT_CHIME_PITCH
								sound.PlaybackSpeed = playbackSpeed
								sound:Play()
							end
						end
					end
				end
			end

			for marker in insideSpots do
				if not seen[marker] then
					insideSpots[marker] = nil
				end
			end
		end
	end)
end

function DigSiteFXController.start()
	if started then
		return
	end
	started = true

	setupProximityChime()
end

return DigSiteFXController
