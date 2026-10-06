local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local DigConfig = require(ConfigFolder:WaitForChild("DigConfig"))
local EconomyConfig = require(ConfigFolder:WaitForChild("EconomyConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))

local Components = script.Parent.Parent:WaitForChild("Components")
local CameraEffects = require(Components:WaitForChild("CameraEffects"))
local CashCollectVFX = require(Components:WaitForChild("CashCollectVFX"))
local CharacterAnimator = require(Components:WaitForChild("CharacterAnimator"))
local DigVFX = require(Components:WaitForChild("DigVFX"))
local RevealVFX = require(Components:WaitForChild("RevealVFX"))

local VFXController = {}

function VFXController.start()
	local digStartedRemote = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.DIG_STARTED_REMOTE)
	local brainrotSpawnedRemote = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.BRAINROT_SPAWNED_REMOTE)
	local brainrotCollectedRemote = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.BRAINROT_COLLECTED_REMOTE)
	local cashCollectFxRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.CASH_COLLECT_FX_REMOTE)

	digStartedRemote.OnClientEvent:Connect(function(diggingPlayer: Player, digPosition: Vector3, digDuration: number, hitIndex: number?, requiredHits: number?)
		local safeDuration = if typeof(digDuration) == "number" and digDuration > 0 then digDuration else DigConfig.DIG_HIT_DURATION
		DigVFX.playSequence(diggingPlayer, localPlayer, digPosition, safeDuration, hitIndex, requiredHits)

		local character = diggingPlayer.Character
		if character then
			task.spawn(CharacterAnimator.playShovel, character, safeDuration, digPosition)
		end

		if diggingPlayer == localPlayer then
			task.spawn(CameraEffects.playDigMotion, localPlayer, safeDuration)
		end
	end)

	brainrotSpawnedRemote.OnClientEvent:Connect(function(diggingPlayer: Player, _dropId: string, brainrotId: string, position: Vector3, revealData)
		RevealVFX.play(diggingPlayer, localPlayer, brainrotId, position, revealData)
	end)

	brainrotCollectedRemote.OnClientEvent:Connect(function(owner: Player, dropId: string, brainrotId: string, duration: number?)
		RevealVFX.playCollect(owner, localPlayer, dropId, brainrotId, duration)
	end)

	cashCollectFxRemote.OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" then
			return
		end

		CashCollectVFX.play(payload.amount, payload.position)
	end)
end

return VFXController
