local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local BrainrotConfig = require(ConfigFolder:WaitForChild("BrainrotConfig"))
local DigConfig = require(ConfigFolder:WaitForChild("DigConfig"))
local VariantConfig = require(ConfigFolder:WaitForChild("VariantConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))

local EconomyService = require(script.Parent:WaitForChild("EconomyService"))
local Components = script.Parent.Parent:WaitForChild("Components")
local BrainrotDropComponent = require(Components:WaitForChild("BrainrotDropComponent"))

local dropsFolder = Workspace:FindFirstChild("BrainrotDrops")
if not dropsFolder then
	dropsFolder = Instance.new("Folder")
	dropsFolder.Name = "BrainrotDrops"
	dropsFolder.Parent = Workspace
end

local BrainrotSpawnService = {}
local activeDrops = {}
local sanitizerStarted = false
local DUPLICATE_CLEANUP_RADIUS = 8

local brainrotDespawnRemote = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.BRAINROT_DESPAWN_REMOTE)

-- HotbarService is required lazily inside pickup to avoid a circular require
-- (HotbarService requires CollectService, which is required before this module
-- in Bootstrap, so a top-level require would resolve before HotbarService exists).
local function getHotbarService()
	return require(script.Parent:WaitForChild("HotbarService"))
end

local function sanitizeDropDescendant(descendant: Instance)
	if descendant:GetAttribute("BrainrotFallbackVisual") == true then
		descendant:Destroy()
		return
	end

	if descendant:IsA("Part")
		and descendant.Shape == Enum.PartType.Ball
		and descendant.Material == Enum.Material.Neon
		and descendant:FindFirstChildOfClass("ProximityPrompt")
	then
		descendant:Destroy()
		return
	end

	if descendant:IsA("BillboardGui") and descendant:GetAttribute("BrainrotDropLabel") ~= true then
		descendant:Destroy()
		return
	end

	-- Allow ProximityPrompts that were added by the server as legitimate pickup
	-- prompts (tagged with IsPickupPrompt = true). Destroy all others to prevent
	-- exploits (players adding their own prompts to the drops folder).
	if descendant:IsA("ProximityPrompt") then
		if not descendant:GetAttribute("IsPickupPrompt") then
			descendant:Destroy()
		end
		return
	end
end

local function startDropSanitizer()
	if sanitizerStarted then
		return
	end
	sanitizerStarted = true

	for _, descendant in dropsFolder:GetDescendants() do
		sanitizeDropDescendant(descendant)
	end

	dropsFolder.DescendantAdded:Connect(sanitizeDropDescendant)
end

startDropSanitizer()

local function getSpawnLockName(player: Player)
	return ("SpawnLock_%d"):format(player.UserId)
end

local function tryAcquireSpawnLock(player: Player)
	local lockName = getSpawnLockName(player)
	local now = os.clock()
	local lockedUntil = dropsFolder:GetAttribute(lockName)
	if type(lockedUntil) == "number" and now < lockedUntil then
		return false
	end

	dropsFolder:SetAttribute(lockName, now + 1.5)
	return true
end

local function releaseSpawnLock(player: Player)
	dropsFolder:SetAttribute(getSpawnLockName(player), nil)
end

local function getDropPosition(drop: Instance)
	if drop:IsA("BasePart") then
		return drop.Position
	end
	if drop:IsA("Model") then
		local pivot = drop:GetPivot()
		return pivot.Position
	end

	return nil
end

local function cleanupDrop(dropId: string)
	local dropData = activeDrops[dropId]
	if not dropData then
		return
	end

	if dropData.model and dropData.model.Parent then
		dropData.model:Destroy()
	end

	activeDrops[dropId] = nil

	local HotbarService = getHotbarService()
	HotbarService.releaseCollectingDrop(dropId)
end

local function cleanupDuplicateDrops(player: Player, keepModel: Instance, center: Vector3)
	for _, child in dropsFolder:GetChildren() do
		if child ~= keepModel then
			local dropPosition = getDropPosition(child)
			local ownerUserId = child:GetAttribute("OwnerUserId")
			if ownerUserId == nil and dropPosition and (dropPosition - center).Magnitude <= DUPLICATE_CLEANUP_RADIUS then
				child:Destroy()
			end
		end
	end
end

-- Plays the despawn animation for all clients then destroys the model.
local function despawnDrop(dropId: string)
	local dropData = activeDrops[dropId]
	if not dropData then
		return
	end

	-- Hide the pickup prompt so no one can trigger it mid-animation.
	if dropData.pickupPrompt and dropData.pickupPrompt.Parent then
		dropData.pickupPrompt.Enabled = false
	end
	if dropData.billboard and dropData.billboard.Parent then
		dropData.billboard.Enabled = false
	end

	-- Tell all clients to play the shrink/dissolve animation.
	brainrotDespawnRemote:FireAllClients(dropId, DigConfig.DESPAWN_ANIM_DURATION)

	task.delay(DigConfig.DESPAWN_ANIM_DURATION + 0.1, function()
		cleanupDrop(dropId)
	end)
end

local function getContextLuck(context): number
	if type(context) == "table" then
		return tonumber(context.luckMultiplier) or 1
	end
	return 1
end

local function rollAndBuildSpawnRecord(spawnContext)
	local roll = BrainrotConfig.rollRandom(nil, spawnContext)
	local variantRoll = VariantConfig.rollRandom(nil, spawnContext)
	local revealData = BrainrotConfig.getRevealData(roll.id, variantRoll.id)
	return roll, variantRoll, revealData
end

-- Step 3 of the dig minigame rework: each dig click rolls a *candidate*
-- the player can choose to claim ("PULL UP") or reroll ("KEEP DIGGING").
-- The candidate is rolled here, replicated to the client for the gauge UI,
-- and locked into the session so the eventual commit spawns the brainrot
-- the player actually saw — never a fresh roll. Returns a flat table that
-- is safe to FireClient as-is and is also accepted back by the spawn path
-- as the `prerolled` argument so the locked candidate becomes the drop.
function BrainrotSpawnService.rollCandidate(spawnContext)
	local roll, variantRoll, revealData = rollAndBuildSpawnRecord(spawnContext)
	return {
		brainrotId = roll.id,
		variantId = variantRoll.id,
		rarity = revealData.rarity,
		rarityRank = revealData.rarityRank,
		rngDenominator = revealData.rngDenominator,
		rngText = revealData.rngText,
		color = revealData.color,
		revealColor = revealData.revealColor,
	}
end

-- Reconstructs the entry/revealData/variantRoll triple from a previously
-- rolled candidate so createBuriedForPlayer can spawn the locked brainrot
-- without a fresh roll. Falls back to a fresh roll if the candidate has
-- been corrupted (missing fields, unknown ids) so a malformed candidate
-- never blocks the dig from completing.
local function resolvePrerolledRecord(prerolled, spawnContext)
	if type(prerolled) ~= "table" then
		return rollAndBuildSpawnRecord(spawnContext)
	end

	local entry = BrainrotConfig.getById(prerolled.brainrotId)
	if not entry then
		return rollAndBuildSpawnRecord(spawnContext)
	end

	local variantId = prerolled.variantId or VariantConfig.NORMAL_ID
	local variantEntry = VariantConfig.getById(variantId)
	local revealData = BrainrotConfig.getRevealData(entry.id, variantEntry.id)
	return entry, variantEntry, revealData
end

-- Attaches the E-hold pickup ProximityPrompt to the drop's root part.
-- The attribute is set BEFORE parenting so the sanitizer's DescendantAdded
-- callback sees it already tagged and skips destruction.
local function addPickupPrompt(rootPart: BasePart, dropId: string, ownerUserId: number): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt:SetAttribute("IsPickupPrompt", true)
	prompt.Name = "PickupPrompt"
	prompt.ActionText = "Pick Up"
	prompt.ObjectText = ""
	prompt.HoldDuration = DigConfig.PICKUP_PROMPT_HOLD_DURATION
	prompt.MaxActivationDistance = DigConfig.PICKUP_PROMPT_MAX_DISTANCE
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.RequiresLineOfSight = false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OneGlobally
	prompt.Parent = rootPart

	prompt.Triggered:Connect(function(player: Player)
		if player.UserId ~= ownerUserId then
			return
		end

		local dropData = activeDrops[dropId]
		if not dropData then
			return
		end

		local HotbarService = getHotbarService()
		local success = HotbarService.pickup(player, dropId, dropData)
		if success then
			task.delay(DigConfig.COLLECT_FLY_TIME + 0.15, function()
				cleanupDrop(dropId)
			end)
		end
	end)

	return prompt
end

function BrainrotSpawnService.createBuriedForPlayer(player: Player, digPosition: Vector3, spawnContext, prerolled)
	if not tryAcquireSpawnLock(player) then
		return nil
	end

	-- When a prerolled candidate is supplied (the new "lock the silhouette"
	-- flow from DigService), spawn that exact brainrot. Otherwise fall back
	-- to the legacy fresh-roll behaviour.
	local roll, variantRoll, revealData = resolvePrerolledRecord(prerolled, spawnContext)
	local dropId = HttpService:GenerateGUID(false)
	local earningsRate = EconomyService.previewEarningsRate(player, roll.id, variantRoll.id)
	local drop = BrainrotDropComponent.create({
		id = roll.id,
		variantId = variantRoll.id,
		color = roll.color,
		rarity = revealData.rarity,
		rngDenominator = revealData.rngDenominator,
		revealColor = revealData.revealColor,
		earningsRate = earningsRate,
		parent = dropsFolder,
		digPosition = digPosition,
		riseDepth = DigConfig.SPAWN_RISE_DEPTH,
		riseTime = DigConfig.SPAWN_RISE_TIME,
		labelDelay = 0.5,
		autoRise = false,
	})
	if not drop then
		releaseSpawnLock(player)
		warn(("[BrainrotSpawn] Could not spawn %s because no matching model exists in ReplicatedStorage.Brainrots."):format(roll.id))
		return nil
	end

	drop.model:SetAttribute("DropId", dropId)
	drop.model:SetAttribute("OwnerUserId", player.UserId)
	drop.model:SetAttribute("VariantId", variantRoll.id)
	cleanupDuplicateDrops(player, drop.model, drop.revealPosition)

	activeDrops[dropId] = {
		id = dropId,
		ownerUserId = player.UserId,
		brainrotId = roll.id,
		variantId = variantRoll.id,
		rarity = revealData.rarity,
		rarityRank = revealData.rarityRank,
		rngDenominator = revealData.rngDenominator,
		rngText = revealData.rngText,
		color = revealData.color,
		revealColor = revealData.revealColor,
		digPosition = digPosition,
		position = drop.revealPosition,
		model = drop.model,
		billboard = drop.billboard,
		component = drop,
		pickupPrompt = nil,
		isRevealed = false,
	}

	-- Small countdown billboard adorned to the same root part as the placard.
	-- Positioned just below the placard so it reads as a despawn warning row.
	local placardBill = activeDrops[dropId].billboard
	local timerBillRoot = placardBill and placardBill.Parent
	if timerBillRoot and timerBillRoot:IsA("BasePart") then
		local placardOffset = placardBill.StudsOffsetWorldSpace
		local timerBill = Instance.new("BillboardGui")
		timerBill.Name = "DropTimerBill"
		timerBill:SetAttribute("BrainrotDropLabel", true)
		timerBill.AlwaysOnTop = true
		timerBill.LightInfluence = 0
		timerBill.Size = UDim2.fromOffset(72, 26)
		timerBill.StudsOffsetWorldSpace = Vector3.new(0, placardOffset.Y + 1.5, 0)
		timerBill.MaxDistance = 45
		timerBill.ResetOnSpawn = false
		timerBill.Enabled = false
		timerBill.Parent = timerBillRoot

		local timerBg = Instance.new("Frame")
		timerBg.Size = UDim2.fromScale(1, 1)
		timerBg.BackgroundColor3 = Color3.fromRGB(20, 15, 10)
		timerBg.BackgroundTransparency = 0.18
		timerBg.BorderSizePixel = 0
		timerBg.Parent = timerBill

		local timerCorner = Instance.new("UICorner")
		timerCorner.CornerRadius = UDim.new(0.4, 0)
		timerCorner.Parent = timerBg

		local timerStroke = Instance.new("UIStroke")
		timerStroke.Color = Color3.fromRGB(255, 175, 80)
		timerStroke.Thickness = 1.5
		timerStroke.Transparency = 0.2
		timerStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		timerStroke.Parent = timerBg

		local timerLabel = Instance.new("TextLabel")
		timerLabel.Name = "DropTimer"
		timerLabel.Size = UDim2.fromScale(1, 1)
		timerLabel.BackgroundTransparency = 1
		timerLabel.Font = Enum.Font.GothamBold
		timerLabel.Text = ("%ds"):format(DigConfig.DROP_LIFETIME)
		timerLabel.TextColor3 = Color3.fromRGB(255, 175, 80)
		timerLabel.TextScaled = true
		timerLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
		timerLabel.TextStrokeTransparency = 0.2
		timerLabel.Parent = timerBg

		task.delay(DigConfig.SPAWN_RISE_TIME + 0.5, function()
			if timerBill.Parent then
				timerBill.Enabled = true
			end
		end)

		local dropExpiry = os.clock() + DigConfig.DROP_LIFETIME
		task.spawn(function()
			while timerBill.Parent do
				local secondsLeft = math.ceil(dropExpiry - os.clock())
				if secondsLeft <= 0 then
					break
				end
				timerLabel.Text = ("%ds"):format(secondsLeft)
				task.wait(1)
			end
		end)
	end

	-- Despawn after DROP_LIFETIME if the player never picks it up.
	task.delay(DigConfig.DROP_LIFETIME, function()
		if activeDrops[dropId] then
			despawnDrop(dropId)
		end
	end)
	task.delay(1.5, function()
		releaseSpawnLock(player)
	end)
	task.spawn(function()
		for _ = 1, 20 do
			task.wait(0.05)
			if not drop.model.Parent then
				return
			end
			cleanupDuplicateDrops(player, drop.model, drop.revealPosition)
		end
	end)

	return {
		dropId = dropId,
		brainrotId = roll.id,
		variantId = variantRoll.id,
		rarity = revealData.rarity,
		rarityRank = revealData.rarityRank,
		rngDenominator = revealData.rngDenominator,
		rngText = revealData.rngText,
		color = revealData.color,
		revealColor = revealData.revealColor,
		position = digPosition,
		spawnContext = spawnContext,
	}
end

function BrainrotSpawnService.setDigProgress(dropId: string, progress: number, duration: number?)
	local dropData = activeDrops[dropId]
	if not dropData or not dropData.component then
		return false
	end

	dropData.component.setProgress(progress, duration)
	return true
end

function BrainrotSpawnService.revealDrop(dropId: string, duration: number?)
	local dropData = activeDrops[dropId]
	if not dropData or not dropData.component or dropData.isRevealed then
		return false
	end

	dropData.isRevealed = true
	dropData.component.reveal(duration)

	-- Attach the pickup prompt after the rise animation finishes so the
	-- player can't accidentally trigger it mid-emerge.
	local riseDuration = if typeof(duration) == "number" then duration else DigConfig.SPAWN_RISE_TIME
	task.delay(riseDuration, function()
		local current = activeDrops[dropId]
		if not current or not current.model or not current.model.Parent then
			return
		end

		-- Find the root part to attach the prompt to.
		local rootPart: BasePart? = nil
		if current.model:IsA("BasePart") then
			rootPart = current.model
		elseif current.model:IsA("Model") then
			rootPart = current.model.PrimaryPart or current.model:FindFirstChildWhichIsA("BasePart")
		end

		if rootPart then
			local prompt = addPickupPrompt(rootPart, dropId, current.ownerUserId)
			current.pickupPrompt = prompt
		end
	end)

	return true
end

function BrainrotSpawnService.cancelDrop(dropId: string?)
	if not dropId then
		return
	end

	cleanupDrop(dropId)
end

function BrainrotSpawnService.spawnForPlayer(player: Player, digPosition: Vector3, spawnContext, prerolled)
	local spawnResult = BrainrotSpawnService.createBuriedForPlayer(player, digPosition, spawnContext, prerolled)
	if not spawnResult then
		return nil
	end

	BrainrotSpawnService.revealDrop(spawnResult.dropId, DigConfig.SPAWN_RISE_TIME)
	return spawnResult
end

return BrainrotSpawnService
