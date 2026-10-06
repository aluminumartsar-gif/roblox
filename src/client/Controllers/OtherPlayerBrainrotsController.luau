-- Renders held-brainrot visuals on every other player's character.
--
-- HotbarController creates a "HeldBrainrot" Tool on the LOCAL client and
-- positions its model via RenderStepped on anchored parts — that approach
-- does not replicate to other clients because anchored-part CFrames written
-- by a client are not sent to the server or peers.
--
-- This controller compensates: for every OTHER player's character it watches
-- for a "HeldBrainrot" Tool (which DOES replicate via Roblox's normal
-- character replication), then spawns a purely local visual model and tracks
-- the character's hand each frame, mirroring the logic in HotbarController.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local localPlayer = Players.LocalPlayer

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UtilFolder = Shared:WaitForChild("Util")
local BrainrotVariantEffects = require(UtilFolder:WaitForChild("BrainrotVariantEffects"))
local VariantConfig = require(Shared:WaitForChild("Config"):WaitForChild("VariantConfig"))

local HELD_SCALE_HEIGHT = 5.0
local HELD_MODEL_ROT = CFrame.Angles(0, math.pi, 0)
local FAR_AWAY = CFrame.new(0, -5000, 0)

local OtherPlayerBrainrotsController = {}

local function findModelRootPart(model: Model): BasePart?
	for _, partName in { "RootPart", "FakeRootPart", "HumanoidRootPart" } do
		local found = model:FindFirstChild(partName, true)
		if found and found:IsA("BasePart") then
			return found :: BasePart
		end
	end
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	for _, desc in model:GetDescendants() do
		if desc:IsA("BasePart") then
			return desc :: BasePart
		end
	end
	return nil
end

local function stripUiAndScripts(instance: Instance)
	local toDestroy = {}
	for _, desc in instance:GetDescendants() do
		if desc:IsA("BillboardGui") or desc:IsA("ProximityPrompt") or desc:IsA("BaseScript") then
			table.insert(toDestroy, desc)
		end
	end
	for _, inst in toDestroy do
		inst:Destroy()
	end
end

-- Spawns a locally-rendered copy of the held brainrot model and tracks
-- `character`'s hand position each frame.  Cleans up when `tool` is destroyed.
local function spawnVisualForTool(character: Model, tool: Tool)
	local brainrotId = tool:GetAttribute("BrainrotId")
	if type(brainrotId) ~= "string" or brainrotId == "" then return end

	local variantId: string? = tool:GetAttribute("VariantId")
	if variantId == "" then variantId = nil end

	local brainrotsFolder = ReplicatedStorage:FindFirstChild("Brainrots")
	local template = brainrotsFolder and brainrotsFolder:FindFirstChild(brainrotId)
	if not template then return end

	local visual = template:Clone()
	stripUiAndScripts(visual)

	local renderConn: RBXScriptConnection? = nil
	local destroyingConn: RBXScriptConnection? = nil

	local function cleanup()
		if renderConn then
			renderConn:Disconnect()
			renderConn = nil
		end
		if destroyingConn then
			destroyingConn:Disconnect()
			destroyingConn = nil
		end
		if visual.Parent then
			visual:Destroy()
		end
	end

	local rightHand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?

	if visual:IsA("Model") then
		local _, size = visual:GetBoundingBox()
		if size.Y > 0 then
			visual:ScaleTo(HELD_SCALE_HEIGHT * visual:GetScale() / size.Y)
		end

		local rootPart = findModelRootPart(visual)
		if not rootPart then
			visual:Destroy()
			return
		end

		visual.PrimaryPart = rootPart

		rootPart.Anchored = true
		rootPart.CanCollide = false
		rootPart.CanTouch = false
		rootPart.Massless = true
		rootPart.CFrame = FAR_AWAY

		for _, desc in visual:GetDescendants() do
			if desc:IsA("BasePart") and desc ~= rootPart then
				desc.Anchored = false
				desc.CanCollide = false
				desc.CanTouch = false
				desc.Massless = true
			end
		end

		visual.Parent = workspace

		if variantId and VariantConfig.isKnown(variantId) then
			BrainrotVariantEffects.apply(visual, rootPart, variantId)
		end

		if rightHand then
			renderConn = RunService.RenderStepped:Connect(function()
				if not rootPart.Parent or not tool.Parent then
					cleanup()
					return
				end
				local yaw = if hrp then select(2, hrp.CFrame:ToEulerAnglesYXZ()) else 0
				rootPart.CFrame = CFrame.new(rightHand.Position) * CFrame.Angles(0, yaw, 0) * HELD_MODEL_ROT
			end)
		end

	elseif visual:IsA("BasePart") then
		local maxDim = math.max(visual.Size.X, visual.Size.Y, visual.Size.Z)
		if maxDim > 0 then
			visual.Size = visual.Size * math.min(HELD_SCALE_HEIGHT / maxDim, 1)
		end
		visual.Anchored = true
		visual.CanCollide = false
		visual.CanTouch = false
		visual.Massless = true
		visual.CFrame = FAR_AWAY
		visual.Parent = workspace

		if variantId and VariantConfig.isKnown(variantId) then
			BrainrotVariantEffects.apply(visual, visual, variantId)
		end

		if rightHand then
			renderConn = RunService.RenderStepped:Connect(function()
				if not visual.Parent or not tool.Parent then
					cleanup()
					return
				end
				local yaw = if hrp then select(2, hrp.CFrame:ToEulerAnglesYXZ()) else 0
				visual.CFrame = CFrame.new(rightHand.Position) * CFrame.Angles(0, yaw, 0) * HELD_MODEL_ROT
			end)
		end

	else
		visual:Destroy()
		return
	end

	destroyingConn = tool.Destroying:Connect(cleanup)
end

local function watchCharacter(character: Model)
	for _, child in character:GetChildren() do
		if child:IsA("Tool") and child.Name == "HeldBrainrot" then
			task.spawn(spawnVisualForTool, character, child :: Tool)
		end
	end

	character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") and child.Name == "HeldBrainrot" then
			task.spawn(spawnVisualForTool, character, child :: Tool)
		end
	end)
end

local function watchPlayer(player: Player)
	if player == localPlayer then return end

	if player.Character then
		watchCharacter(player.Character)
	end

	player.CharacterAdded:Connect(function(character)
		watchCharacter(character)
	end)
end

function OtherPlayerBrainrotsController.start()
	for _, player in Players:GetPlayers() do
		task.spawn(watchPlayer, player)
	end
	Players.PlayerAdded:Connect(watchPlayer)
end

return OtherPlayerBrainrotsController
