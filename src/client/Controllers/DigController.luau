local Players = game:GetService("Players")
local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local DigConfig = require(ConfigFolder:WaitForChild("DigConfig"))
local DigSiteConfig = require(ConfigFolder:WaitForChild("DigSiteConfig"))
local EconomyConfig = require(ConfigFolder:WaitForChild("EconomyConfig"))
local ShovelUpgradeConfig = require(ConfigFolder:WaitForChild("ShovelUpgradeConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))

local Components = script.Parent.Parent:WaitForChild("Components")
local CameraEffects  = require(Components:WaitForChild("CameraEffects"))
-- Step 3 of the dig minigame rework: the screen-space DigTimingBar is gone.
-- DigPullGauge is the new worldspace component anchored at the dig spot;
-- it shows the rising silhouette + odds + PULL UP / KEEP DIGGING buttons.
-- See src/client/Components/DigPullGauge.luau.
local DigPullGauge   = require(Components:WaitForChild("DigPullGauge"))
local DirtSplashUI   = require(Components:WaitForChild("DirtSplashUI"))

-- Shovel-snap SFX (miss/break): dirt-impact source pitched to ~1.9× crack.
local SNAP_SOUND_ID       = "rbxassetid://9114083260"
local SNAP_SOUND_DURATION = 0.28
local snapSoundTemplate: Sound

-- Green-zone hit SFX: a proper bell asset so the hit sounds bright and
-- rewarding rather than like a dirt thud.  Cut off at HIT_SOUND_DURATION
-- so only the initial strike transient plays, not the full ring-out.
local HIT_BELL_ID       = "rbxassetid://4590662766"
local HIT_SOUND_DURATION = 0.38
local hitBellTemplate: Sound

do
	local templateFolder = Instance.new("Folder")
	templateFolder.Name = "ShovelSnapTemplates"
	templateFolder.Parent = SoundService

	snapSoundTemplate = Instance.new("Sound")
	snapSoundTemplate.Name = "ShovelSnapTemplate"
	snapSoundTemplate.SoundId = SNAP_SOUND_ID
	snapSoundTemplate.Volume = 0.9
	snapSoundTemplate.Parent = templateFolder

	hitBellTemplate = Instance.new("Sound")
	hitBellTemplate.Name = "HitBellTemplate"
	hitBellTemplate.SoundId = HIT_BELL_ID
	hitBellTemplate.Volume = 0.9
	hitBellTemplate.Parent = templateFolder

	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync({ snapSoundTemplate, hitBellTemplate })
		end)
	end)
end

-- Persistent red flash overlay, lazy-created the first time snap effects fire.
local snapFlashFrame: Frame? = nil

local function getSnapFlashFrame(): Frame
	if snapFlashFrame then
		return snapFlashFrame :: Frame
	end

	local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	local flashGui = Instance.new("ScreenGui")
	flashGui.Name = "ShovelSnapFlashGui"
	flashGui.ResetOnSpawn = false
	flashGui.IgnoreGuiInset = true
	flashGui.DisplayOrder = 20
	flashGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	flashGui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "RedFlash"
	frame.Size = UDim2.fromScale(1, 1)
	frame.Position = UDim2.fromScale(0, 0)
	frame.BackgroundColor3 = Color3.fromRGB(210, 25, 25)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.ZIndex = 10
	frame.Parent = flashGui

	snapFlashFrame = frame
	return frame
end

-- Bright bell "ting" for landing inside the green zone.
-- Uses a dedicated bell asset (not the dirt-shovel sound) pitched into the
-- high register so it reads as a clean, exciting success cue.
local function playHitSound()
	local sound = hitBellTemplate:Clone()
	-- Slight random pitch keeps rapid hits from sounding mechanical.
	sound.PlaybackSpeed = math.random(128, 145) / 100
	sound.Volume = 0.82
	sound.Parent = SoundService
	sound:Play()
	task.delay(HIT_SOUND_DURATION, function()
		sound:Stop()
		sound:Destroy()
	end)
end

local function playSnapEffects()
	-- Crack/snap sound: high pitch gives a sharp crack; hard-stopped after
	-- SNAP_SOUND_DURATION so only the initial transient is heard.
	local sound = snapSoundTemplate:Clone()
	sound.PlaybackSpeed = math.random(185, 210) / 100
	sound.Parent = SoundService
	sound:Play()
	task.delay(SNAP_SOUND_DURATION, function()
		sound:Stop()
		sound:Destroy()
	end)

	-- Brief red vignette flash that fades out quickly.
	local flash = getSnapFlashFrame()
	flash.BackgroundTransparency = 0.3
	TweenService:Create(
		flash,
		TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	):Play()

	-- Short camera shake to sell the impact.
	task.spawn(CameraEffects.shake, localPlayer, 0.32, 0.26)
end

local PROXIMITY_CHECK_INTERVAL = 0.18
local DIG_PROXIMITY_PADDING    = 0
local DIG_PROXIMITY_HEIGHT     = 12

local DEFAULT_WALK_SPEED  = 16
local DEFAULT_JUMP_HEIGHT = 7.35

local DigController = {}
local started = false

local hintLabel: TextLabel? = nil
local hintTicket = 0
local isMovementLocked = false

local walkSpeedUpgradeLevel = 0

local function effectiveWalkSpeed(): number
	return DEFAULT_WALK_SPEED * ShovelUpgradeConfig.getWalkSpeedMultiplier(walkSpeedUpgradeLevel)
end

local function applyEconomyWalkPayload(payload: any)
	if type(payload) ~= "table" then
		return
	end

	local up = payload.shovelUpgrades
	if type(up) ~= "table" or up.walkSpeed == nil then
		return
	end

		walkSpeedUpgradeLevel = ShovelUpgradeConfig.clampWalkSpeedLevel(up.walkSpeed)
	if not isMovementLocked then
		local character = localPlayer.Character
		if character then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.WalkSpeed = effectiveWalkSpeed()
			end
		end
	end
end

local function lockMovement()
	if isMovementLocked then return end
	isMovementLocked = true
	local character = localPlayer.Character
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	humanoid.WalkSpeed  = 0
	humanoid.JumpHeight = 0
end

local function unlockMovement()
	if not isMovementLocked then return end
	isMovementLocked = false
	local character = localPlayer.Character
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	humanoid.WalkSpeed  = effectiveWalkSpeed()
	humanoid.JumpHeight = DEFAULT_JUMP_HEIGHT
end

local digRequestRemote: RemoteEvent?     = nil
local digStopRemote: RemoteEvent?        = nil
local digClaimRemote: RemoteEvent?       = nil
local digSiteEnteredRemote: RemoteEvent? = nil
local digSiteLeftRemote: RemoteEvent?    = nil

local digGauge: any        = nil
local isAtDigSite          = false
local localCooldownUntil   = 0
local hasActiveSession     = false
local lastSessionPhase: string = "idle"

local lastKnownRequiredHits = DigConfig.DIG_REQUIRED_HITS

-- Tracks the latest server-issued candidate revision the gauge has shown
-- so we don't replay the rise animation on idle / cooldown state pushes
-- where the candidate is unchanged. Server increments candidateRevision
-- only on swings; see DigService.rollAndStoreCandidate.
local lastSeenCandidateRevision = 0

local function disableRobloxBackpack()
	task.spawn(function()
		for _ = 1, 10 do
			local ok = pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
			end)
			if ok then
				return
			end

			task.wait(0.25)
		end
	end)
end

local function showHint(text: string)
	local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return
	end

	if not hintLabel then
		local gui = Instance.new("ScreenGui")
		gui.Name = "DigSiteHintGui"
		gui.ResetOnSpawn = false
		gui.Parent = playerGui

		hintLabel = Instance.new("TextLabel")
		hintLabel.Name = "Hint"
		hintLabel.AnchorPoint = Vector2.new(0.5, 0)
		hintLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
		hintLabel.BackgroundTransparency = 0.2
		hintLabel.BorderSizePixel = 0
		hintLabel.Font = Enum.Font.GothamBold
		hintLabel.Position = UDim2.fromScale(0.5, 0.30)
		hintLabel.Size = UDim2.fromScale(0.36, 0.06)
		hintLabel.TextColor3 = Color3.new(1, 1, 1)
		hintLabel.TextScaled = true
		hintLabel.TextStrokeTransparency = 0.6
		hintLabel.Visible = false
		hintLabel.Parent = gui
	end

	hintTicket += 1
	local currentTicket = hintTicket
	hintLabel.Text = text
	hintLabel.Visible = true

	task.delay(1.4, function()
		if currentTicket == hintTicket and hintLabel then
			hintLabel.Visible = false
		end
	end)
end

local function getDigSite(): Instance?
	return game:GetService("Workspace"):FindFirstChild(DigSiteConfig.MODEL_NAME)
end

local function findFloorPart(digSite: Instance): BasePart?
	local floor = digSite:FindFirstChild(DigSiteConfig.FLOOR_NAME, true)
	if floor and floor:IsA("BasePart") then
		return floor
	end

	for _, descendant in digSite:GetDescendants() do
		if descendant:IsA("BasePart") then
			return descendant
		end
	end

	if digSite:IsA("BasePart") then
		return digSite
	end

	return nil
end

local function getCharacterRoot()
	local character = localPlayer.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	return root
end

local function isCharacterAtDigSite(): boolean
	local root = getCharacterRoot()
	if not root then
		return false
	end

	local digSite = getDigSite()
	if not digSite then
		return false
	end

	local floor = findFloorPart(digSite)
	if not floor then
		return false
	end

	local localPosition = floor.CFrame:PointToObjectSpace(root.Position)
	local halfSize = floor.Size * 0.5
	local horizontalPadding = DigSiteConfig.DIG_SURFACE_PADDING + DIG_PROXIMITY_PADDING

	return math.abs(localPosition.X) <= halfSize.X + horizontalPadding
		and math.abs(localPosition.Z) <= halfSize.Z + horizontalPadding
		and math.abs(localPosition.Y) <= halfSize.Y + DIG_PROXIMITY_HEIGHT
end

local function tryDig()
	if not digRequestRemote then
		return
	end

	local now = os.clock()
	if now < localCooldownUntil then
		return
	end

	local root = getCharacterRoot()
	if not root then
		return
	end

	-- Raycast downward to find the actual floor surface so the server stores a
	-- ground-level position for the hole. root.Position is ~3 studs above the
	-- floor, which caused markDug to place a floating hole.
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { localPlayer.Character }
	local rayResult = Workspace:Raycast(root.Position, Vector3.new(0, -12, 0), rayParams)
	local digPosition = if rayResult then rayResult.Position else root.Position

	-- Step 3 of the dig minigame rework: the timing bar previously enforced
	-- a per-hit input lock for DIG_HIT_COOLDOWN; with the gauge taking over
	-- that's gone, so we soft-rate-limit clicks to roughly the shovel swing
	-- duration. Without it, rapid clicks can outpace the silhouette's
	-- drop+rise animation and queue stale candidates the player never sees.
	localCooldownUntil = now + math.max(DigConfig.DIG_HIT_COOLDOWN, DigConfig.DIG_HIT_DURATION)
	digRequestRemote:FireServer(digPosition)
end

local function fireCancel()
	if not digStopRemote then
		return
	end
	if not hasActiveSession then
		return
	end

	digStopRemote:FireServer()
end

local function firePullUp()
	if not digClaimRemote then
		return
	end

	digClaimRemote:FireServer()
end

local function setAtDigSite(value: boolean)
	if isAtDigSite == value then
		return
	end
	isAtDigSite = value

	if value then
		if digSiteEnteredRemote then
			digSiteEnteredRemote:FireServer()
		end
		-- Dig anywhere in the site; glowing patches are an optional luck
		-- buff, not a requirement. The gauge attaches itself on the first
		-- DIG_STATE so a one-click loop is the entire prompt: dig once,
		-- the brainrot rises, decide KEEP BRAINROT or KEEP DIGGING.
		showHint("Click to dig — keep your brainrot or reroll for more luck!")
	else
		if digSiteLeftRemote then
			digSiteLeftRemote:FireServer()
		end
		if hasActiveSession then
			fireCancel()
		end
		unlockMovement()
		if digGauge then
			digGauge:detach()
		end
		lastSeenCandidateRevision = 0
	end
end

local function startProximityWatcher()
	task.spawn(function()
		while started do
			setAtDigSite(isCharacterAtDigSite())
			task.wait(PROXIMITY_CHECK_INTERVAL)
		end
	end)
end

-- Step 3 of the dig minigame rework: applyState drives the worldspace
-- DigPullGauge instead of the old screen-space DigTimingBar. Each state
-- push includes the latest server-rolled candidate (silhouette + odds +
-- luck multiplier); we only re-trigger the rise animation when the
-- candidateRevision actually advances so duplicate state pushes don't
-- replay the animation. The gauge attaches to state.position when the
-- first standard/extra state arrives and detaches on idle/broken/committing.
local function applyState(state)
	if type(state) ~= "table" then
		return
	end

	local phase     = if type(state.phase) == "string" then state.phase else "idle"
	local prevPhase = lastSessionPhase
	lastSessionPhase = phase

	-- "digging" counts as an active session so walk-off / cancel paths fire
	-- DIG_STOP for the in-flight countdown too. Without this, leaving the
	-- dig site mid-countdown would let the server's task.delay complete
	-- silently and spawn a brainrot the player never claimed.
	if phase == "standard" or phase == "extra" or phase == "digging" then
		hasActiveSession = true
	else
		hasActiveSession = false
	end

	if not digGauge then
		return
	end

	-- Movement lock: the player should stay put while the countdown ring is
	-- visible so they can't drift off the dig spot mid-animation. Unlocked
	-- the moment the countdown resolves into the standard/extra reveal so
	-- they can move between digs if they want.
	if phase == "digging" then
		lockMovement()
	elseif phase == "standard" or phase == "extra" then
		unlockMovement()
	end

	if phase == "idle" or phase == "broken" or phase == "committing" then
		unlockMovement()
		if digGauge:isAttached() then
			-- The broken-phase state piggybacks on digBrokenRemote which
			-- already plays the gauge's snap animation; we just need to
			-- detach after that animation has had time to settle. For idle
			-- and committing we play the drop tween so the silhouette
			-- recedes cleanly before the brainrot rises out of the same
			-- spot (committing) or before the next session starts (idle).
			local detachDelay
			if phase == "broken" then
				detachDelay = 0.7
			else
				digGauge:playDropAnimation()
				detachDelay = 0.35
			end
			task.delay(detachDelay, function()
				if digGauge and not hasActiveSession then
					digGauge:detach()
				end
			end)
		end
		lastSeenCandidateRevision = 0
		return
	end

	local hits         = tonumber(state.hits) or 0
	local extraHits    = tonumber(state.extraHits) or 0
	local requiredHits = tonumber(state.requiredHits) or DigConfig.DIG_REQUIRED_HITS
	local luck         = tonumber(state.luckMultiplier) or 1
	local riskNext     = tonumber(state.riskNext) or 0
	lastKnownRequiredHits = requiredHits

	-- First state of a fresh session: anchor the gauge at the dig spot.
	-- state.position is the locked-in session position from the server,
	-- which has already passed must-be-on-a-spot validation in Step 2.
	if not digGauge:isAttached() then
		if typeof(state.position) == "Vector3" then
			digGauge:attachToSpot(state.position)
		else
			return
		end
	end

	digGauge:setHits(hits, requiredHits)
	digGauge:setLuck(luck)
	-- Countdown push: the server fires DIG_STATE alongside the dedicated
	-- DIG_COUNTDOWN_STARTED remote, but since the two arrive in arbitrary
	-- order (and the gauge is attached on whichever lands first), kick the
	-- countdown overlay up here too if state.digDuration is present. The
	-- corresponding handler in start() runs hideCountdown / showCountdown
	-- with ticket bumping so a duplicate call is a no-op.
	if phase == "standard" then
		digGauge:setPhase("safe")
	elseif phase == "extra" then
		digGauge:setPhase("risky", riskNext * 100)
		if prevPhase ~= "extra" then
			DirtSplashUI.jackpot()
		end
	elseif phase == "digging" then
		local dur = tonumber(state.digDuration) or 0
		if dur > 0 then
			digGauge:showCountdown(dur)
		end
	end

	-- Show the new candidate when the server stamps a fresh roll. Ignore
	-- duplicate revisions so re-broadcasts don't trigger a redundant
	-- drop+rise loop on the silhouette. Skip during PHASE_DIGGING — the
	-- countdown overlay covers the panel and showCandidate would prematurely
	-- tear it down + reveal the previous candidate while the loop animation
	-- is still running.
	if phase ~= "digging" then
		local candidate = state.candidate
		local revision = tonumber(state.candidateRevision) or 0
		if type(candidate) == "table" and revision > lastSeenCandidateRevision then
			lastSeenCandidateRevision = revision
			digGauge:showCandidate({
				brainrotId = candidate.brainrotId,
				rarityName = candidate.rarity or "?",
				rarityColor = candidate.color,
				oddsDenominator = tonumber(candidate.rngDenominator) or 1,
				luckMultiplier = tonumber(candidate.luckMultiplier) or luck,
			})
		end
	end
end

function DigController.start()
	if started then
		return
	end
	started = true

	disableRobloxBackpack()

	digRequestRemote     = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.DIG_REQUEST_REMOTE)
	digStopRemote        = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.DIG_STOP_REMOTE)
	digClaimRemote       = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.DIG_CLAIM_REMOTE)
	digSiteEnteredRemote = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.DIG_SITE_ENTERED_REMOTE)
	digSiteLeftRemote    = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.DIG_SITE_LEFT_REMOTE)
	local digRejectedRemote = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.DIG_REJECTED_REMOTE)
	local digStateRemote    = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.DIG_STATE_REMOTE)
	local digBrokenRemote   = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.DIG_BROKEN_REMOTE)
	local digCountdownStartedRemote = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.DIG_COUNTDOWN_STARTED_REMOTE)
	local economySyncRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.ECONOMY_SYNC_REMOTE)
	local economySyncRequestRemote = RemoteRegistry.getRemote(
		EconomyConfig.REMOTE_FOLDER,
		EconomyConfig.ECONOMY_SYNC_REQUEST_REMOTE
	)

	economySyncRemote.OnClientEvent:Connect(applyEconomyWalkPayload)
	economySyncRequestRemote:FireServer()

	digRejectedRemote.OnClientEvent:Connect(function(message)
		showHint(if type(message) == "string" then message else "Click the ground to dig!")
	end)


	digStateRemote.OnClientEvent:Connect(applyState)

	-- Countdown start. Payload: { duration, position, phase }. The
	-- corresponding DigStateRemote push lands the same tick to update
	-- hits/luck; we let that handler refresh the gauge metadata while we
	-- own the explicit countdown overlay flow here.
	digCountdownStartedRemote.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		local duration = tonumber(payload.duration)
		if not duration or duration <= 0 then
			return
		end

		hasActiveSession = true
		lastSessionPhase = "digging"
		lockMovement()
		-- Extend the local click rate-limit to cover the whole countdown so
		-- a follow-up click doesn't immediately retrigger tryDig once the
		-- server rejects the duplicate request. Server already gates this
		-- with PHASE_DIGGING but the local gate keeps the UI responsive.
		localCooldownUntil = math.max(localCooldownUntil, os.clock() + duration)

		if digGauge then
			if not digGauge:isAttached() and typeof(payload.position) == "Vector3" then
				digGauge:attachToSpot(payload.position)
			end
			if digGauge:isAttached() then
				digGauge:showCountdown(duration)
			end
		end
	end)

	digBrokenRemote.OnClientEvent:Connect(function(_payload)
		unlockMovement()
		localCooldownUntil = os.clock() + DigConfig.BREAK_COOLDOWN
		hasActiveSession = false
		lastSeenCandidateRevision = 0
		if digGauge and digGauge:isAttached() then
			digGauge:playSnapAnimation()
			task.delay(0.7, function()
				if digGauge and not hasActiveSession then
					digGauge:detach()
				end
			end)
		end
		playSnapEffects()
		showHint("Your shovel snapped!")

		-- Belt-and-braces: the server schedules a follow-up idle state to
		-- flip lastSessionPhase off "broken", but if that message ever
		-- gets lost the floor-click handler would stay gated forever and
		-- the player can't dig again. Reset locally after the cooldown as
		-- a safety net.
		local breakResetCooldown = DigConfig.BREAK_COOLDOWN
		task.delay(breakResetCooldown, function()
			if lastSessionPhase == "broken" then
				lastSessionPhase = "idle"
			end
		end)
	end)

	digGauge = DigPullGauge.new()
	digGauge:setCallbacks({
		onPullUp = function()
			firePullUp()
		end,
		onKeepDigging = function()
			-- The session position is locked server-side from the very first
			-- swing, so the click position the client sends here is ignored
			-- by getActiveSession's continuation path. We just need to fire
			-- DIG_REQUEST and the server takes the next swing on the same
			-- spot.
			tryDig()
		end,
		onCancel = function()
			-- CANCEL clicked during the countdown. Tear the session down
			-- on the server (no penalty, no spot marker) and locally clear
			-- any rate-limit so the player can start a fresh dig
			-- immediately. fireCancel sends DIG_STOP iff hasActiveSession.
			fireCancel()
			localCooldownUntil = 0
			if digGauge then
				digGauge:hideCountdown()
			end
			unlockMovement()
		end,
	})

	-- Floor / spot click handler. Originally went through
	-- UserInputService.InputBegan with a `processed` filter, but a
	-- BillboardGui's TextButton clicks weren't reliably reporting
	-- `processed=true` here on desktop — clicks on the gauge background
	-- and even on the PULL UP button itself fell through to this handler
	-- and re-fired DIG_REQUEST as another swing, which is why PULL UP
	-- looked broken. Mouse.Button1Down is documented to NOT fire when the
	-- click is over a GUI element, so it's the right primitive for the
	-- "click the floor to swing" half of the loop. Touch input on mobile
	-- still goes through InputBegan with the processed guard, since touch
	-- routing to BillboardGui buttons works correctly there.
	local function handleFloorClick()
		if not isAtDigSite then
			return
		end
		if lastSessionPhase == "committing" or lastSessionPhase == "broken" then
			return
		end
		-- During PHASE_DIGGING the countdown overlay + CANCEL button own the
		-- input flow; floor clicks here would only get rejected server-side
		-- and confuse the player with spurious optimistic hit feedback.
		if lastSessionPhase == "digging" then
			return
		end

		-- (No must-move gate — broken spots are already marked dug, so
		-- any redig of the same hole bounces with "Already dug here!"
		-- via the server, while clicks on a different spot start a fresh
		-- session immediately. The localCooldownUntil + BREAK_COOLDOWN
		-- timer below still gives the snap effect a beat to play.)

		-- Lightweight per-hit feedback so the click feels punchy even before
		-- the server's state echo arrives. The server still authoritatively
		-- updates the gauge via DIG_STATE → applyState.
		if hasActiveSession then
			playHitSound()
			DirtSplashUI.burst()
		end
		tryDig()
	end

	local mouse = localPlayer:GetMouse()
	if mouse then
		mouse.Button1Down:Connect(handleFloorClick)
	end

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		handleFloorClick()
	end)

	localPlayer.CharacterAdded:Connect(function(character)
		hasActiveSession = false
		lastSessionPhase = "idle"
		isMovementLocked = false
		lastSeenCandidateRevision = 0
		setAtDigSite(false)
		if digGauge then
			digGauge:detach()
		end
		task.defer(function()
			if character.Parent == nil then
				return
			end
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid and not isMovementLocked then
				humanoid.WalkSpeed = effectiveWalkSpeed()
			end
		end)
	end)

	startProximityWatcher()
end

return DigController
