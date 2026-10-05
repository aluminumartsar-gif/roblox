--!strict
--[[
	BatService
	ServerScriptService/Server/Services/BatService

	Every player gets a Bat. A swing (server-side, Tool.Activated):
	  * cooldown Config.Bat.Cooldown per swinger; stunned players can't swing
	  * hits the nearest other player within Config.Bat.Range who is roughly
	    in front (Config.Bat.FrontDot) — or very close in any direction
	  * the target is knocked back and stunned (can't move or jump) for
	    Config.Bat.StunDuration, then can't be stunned again for
	    Config.Bat.StunImmunity (no stun-locking)
	  * if the target is carrying a stolen item, they drop it
	    (any swinger if Config.Bat.AnyoneCanDisarm, else only the owner);
	    an egg bought off the belt is knocked loose by anyone
	  * no damage

	Knockback uses a LinearVelocity constraint: player characters are
	simulated by their own client, and constraints replicate to it, whereas
	a velocity set by the server would be ignored.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Server = ServerScriptService:WaitForChild("Server")
local Modules = Server:WaitForChild("Modules")
local Services = Server:WaitForChild("Services")
local RemoteGuard = require(Modules:WaitForChild("RemoteGuard"))
local Notifier = require(Modules:WaitForChild("Notifier"))
local MovementService = require(Services:WaitForChild("MovementService"))
local StealService = require(Services:WaitForChild("StealService"))

local BatService = {}

local SWING_SOUND = "rbxasset://sounds/swordslash.wav"
local CLOSE_RANGE = 3 -- within this, direction doesn't matter

local lastSwing: { [Player]: number } = {}
local stunnedUntil: { [Player]: number } = {}
local immuneUntil: { [Player]: number } = {}

function BatService.IsStunned(player: Player): boolean
	return (stunnedUntil[player] or 0) > os.clock()
end

local function knockback(root: BasePart, direction: Vector3)
	local attachment = Instance.new("Attachment")
	attachment.Name = "BatKnockback"
	attachment.Parent = root
	local velocity = Instance.new("LinearVelocity")
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.MaxForce = 1e6
	velocity.VectorVelocity = direction * Config.Bat.KnockbackVelocity + Vector3.new(0, Config.Bat.KnockbackUp, 0)
	velocity.Parent = root
	Debris:AddItem(velocity, 0.18)
	Debris:AddItem(attachment, 0.18)
end

local function stun(target: Player)
	local t = os.clock()
	stunnedUntil[target] = t + Config.Bat.StunDuration
	immuneUntil[target] = t + Config.Bat.StunDuration + Config.Bat.StunImmunity
	MovementService.SetModifier(target, "Stunned", 0)
	MovementService.SetJumpBlocked(target, "Stunned", true)
	task.delay(Config.Bat.StunDuration, function()
		if target.Parent == Players then
			MovementService.SetModifier(target, "Stunned", nil)
			MovementService.SetJumpBlocked(target, "Stunned", false)
		end
	end)
end

local function hit(attacker: Player, target: Player, direction: Vector3)
	-- Knock loose anything they're carrying.
	local carry = StealService.GetCarry(target)
	if carry and (carry.Source == "Belt" or Config.Bat.AnyoneCanDisarm or carry.OwnerUserId == attacker.UserId) then
		StealService.Drop(target, "bat by " .. attacker.Name)
	end

	if (immuneUntil[target] or 0) > os.clock() then
		return -- recently stunned: still disarmed above, but no knockback
	end
	local targetRoot = RemoteGuard.GetRoot(target)
	if targetRoot then
		knockback(targetRoot, direction)
	end
	stun(target)
	Notifier.Send(target, "Bonked by " .. attacker.DisplayName .. "!", "Warning")
end

function BatService.Swing(player: Player)
	local t = os.clock()
	if (lastSwing[player] or 0) + Config.Bat.Cooldown > t then
		return
	end
	if BatService.IsStunned(player) then
		return
	end
	local root = RemoteGuard.GetRoot(player)
	if not root then
		return
	end
	lastSwing[player] = t

	local facing = root.CFrame.LookVector * Vector3.new(1, 0, 1)
	facing = if facing.Magnitude > 0 then facing.Unit else Vector3.new(0, 0, -1)

	local best: Player? = nil
	local bestDistance = math.huge
	local bestDirection = facing
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			local otherRoot = RemoteGuard.GetRoot(other)
			if otherRoot then
				local offset = otherRoot.Position - root.Position
				local distance = offset.Magnitude
				if distance <= Config.Bat.Range and distance < bestDistance then
					local flat = offset * Vector3.new(1, 0, 1)
					local direction = if flat.Magnitude > 0 then flat.Unit else facing
					if distance <= CLOSE_RANGE or facing:Dot(direction) >= Config.Bat.FrontDot then
						best = other
						bestDistance = distance
						bestDirection = direction
					end
				end
			end
		end
	end

	if best then
		hit(player, best, bestDirection)
	end
end

local function giveBat(player: Player)
	local backpack = player:WaitForChild("Backpack", 10)
	if not backpack or backpack:FindFirstChild(Config.Bat.Name) then
		return
	end

	local tool = Instance.new("Tool")
	tool.Name = Config.Bat.Name
	tool.ToolTip = "Bonk thieves to make them drop what they stole"
	tool.TextureId = Config.Icons.BaseballBat
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	tool.Grip = CFrame.new(0, -1.6, 0)

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.5, 4, 0.5)
	handle.Color = Color3.fromRGB(150, 108, 66)
	handle.Material = Enum.Material.Wood
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool

	local tip = Instance.new("Part")
	tip.Name = "Barrel"
	tip.Shape = Enum.PartType.Cylinder
	tip.Size = Vector3.new(1.8, 0.8, 0.8)
	tip.Color = Color3.fromRGB(130, 92, 56)
	tip.Material = Enum.Material.Wood
	tip.CanCollide = false
	tip.Massless = true
	tip.CFrame = handle.CFrame * CFrame.new(0, 1.6, 0) * CFrame.Angles(0, 0, math.pi / 2)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = tip
	weld.Parent = handle
	tip.Parent = tool

	local sound = Instance.new("Sound")
	sound.Name = "Swing"
	sound.SoundId = SWING_SOUND
	sound.Volume = 0.6
	sound.Parent = handle

	tool.Activated:Connect(function()
		if tool.Parent ~= player.Character then
			return
		end
		sound:Play()
		BatService.Swing(player)
	end)

	tool.Parent = backpack
end

function BatService.Start()
	local function hookPlayer(player: Player)
		player.CharacterAdded:Connect(function()
			giveBat(player)
		end)
		if player.Character then
			task.spawn(giveBat, player)
		end
	end
	Players.PlayerAdded:Connect(hookPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		hookPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		lastSwing[player] = nil
		stunnedUntil[player] = nil
		immuneUntil[player] = nil
	end)
end

return BatService
