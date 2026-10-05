--!strict
--[[
	MovementService
	ServerScriptService/Server/Services/MovementService

	The only thing that sets Humanoid.WalkSpeed. Other systems register
	named multipliers instead of writing WalkSpeed themselves, so effects
	stack instead of overwriting each other:

	  MovementService.SetModifier(player, "OwnPlot", 1.15)   -- home bonus
	  MovementService.SetModifier(player, "Carrying", 0.75)  -- Step 4
	  MovementService.SetModifier(player, "OwnPlot", nil)    -- remove

	Final speed = WalkSpeed upgrade value * product of all modifiers.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local DataService = require(ServerScriptService:WaitForChild("Server"):WaitForChild("Services"):WaitForChild("DataService"))

local MovementService = {}

local modifiers: { [Player]: { [string]: number } } = {}

local function baseSpeed(player: Player): number
	local data = DataService.Get(player)
	local level = if data then data.Upgrades.WalkSpeed else 1
	return Config.GetUpgradeValue("WalkSpeed", level)
end

--- Recomputes and applies the player's walk speed.
function MovementService.Refresh(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local speed = baseSpeed(player)
	for _, multiplier in pairs(modifiers[player] or {}) do
		speed *= multiplier
	end
	-- Only write on change; WalkSpeed replicates on every write.
	if math.abs(humanoid.WalkSpeed - speed) > 0.01 then
		humanoid.WalkSpeed = speed
	end
end

--- Sets (or with nil, clears) a named speed multiplier.
function MovementService.SetModifier(player: Player, key: string, multiplier: number?)
	local map = modifiers[player]
	if not map then
		map = {}
		modifiers[player] = map
	end
	if map[key] == multiplier then
		return
	end
	map[key] = multiplier
	MovementService.Refresh(player)
end

function MovementService.GetModifier(player: Player, key: string): number?
	local map = modifiers[player]
	return map and map[key]
end

function MovementService.Start()
	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			character:WaitForChild("Humanoid", 10)
			MovementService.Refresh(player)
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		modifiers[player] = nil
	end)
end

return MovementService
