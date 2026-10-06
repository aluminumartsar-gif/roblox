local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local DigConfig = require(ConfigFolder:WaitForChild("DigConfig"))
local ShovelConfig = require(ConfigFolder:WaitForChild("ShovelConfig"))
local ShovelUpgradeConfig = require(ConfigFolder:WaitForChild("ShovelUpgradeConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))

local BrainrotSpawnService = require(script.Parent:WaitForChild("BrainrotSpawnService"))
local DigSiteService = require(script.Parent:WaitForChild("DigSiteService"))
local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))

local Components = script.Parent.Parent:WaitForChild("Components")
local ShovelComponent = require(Components:WaitForChild("ShovelComponent"))
local ShovelAnimator = require(Components:WaitForChild("ShovelAnimator"))

local DigService = {}
local started = false

-- How long the shovel stays equipped after the most recent dig action before
-- the server unequips it automatically. Generous so the player can deliberate
-- at the claim-or-risk decision without the shovel popping out of their hand.
local SHOVEL_IDLE_TIMEOUT = 20

-- Phase tag for sessions in the deep-dig flow.
local PHASE_STANDARD = "standard"
local PHASE_EXTRA = "extra"
local PHASE_COMMITTING = "committing"
local PHASE_BROKEN = "broken"
-- Countdown phase: server schedules a task.delay for the shovel's effective
-- digDuration and plays a looping shovel animation while we wait. When the
-- delay fires we transition to PHASE_EXTRA and roll the candidate brainrot
-- (existing rise-silhouette path takes over). PULL UP / KEEP DIGGING are
-- disallowed during PHASE_DIGGING; only DIG_STOP can interrupt the countdown.
local PHASE_DIGGING = "digging"

local activeSessionByUserId = {}
local cooldownByUserId = {}
local requestLockByUserId = {}
local spawnTicketByUserId = {}
local equippedShovelByUserId: { [number]: Tool } = {}
local shovelCleanupTokenByUserId: { [number]: any } = {}
local rng = Random.new()

local digStartedRemote = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.DIG_STARTED_REMOTE)
local digRejectedRemote = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.DIG_REJECTED_REMOTE)
local digStateRemote = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.DIG_STATE_REMOTE)
local digBrokenRemote = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.DIG_BROKEN_REMOTE)
local digCountdownStartedRemote = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.DIG_COUNTDOWN_STARTED_REMOTE)
local brainrotSpawnedRemote = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.BRAINROT_SPAWNED_REMOTE)

local function rejectDig(player: Player, message: string?)
	digRejectedRemote:FireClient(player, message or "Dig at the DigSite. Glowing circles have better luck!")
end

local function unequipShovel(userId: number)
	local shovel = equippedShovelByUserId[userId]
	if shovel then
		shovel:Destroy()
		equippedShovelByUserId[userId] = nil
	end
	shovelCleanupTokenByUserId[userId] = nil
end

local function ensureShovelEquipped(player: Player)
	local userId = player.UserId
	local character = player.Character
	if not character then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end

	local desiredShovelId = PlayerDataService.getShovel(player)

	-- A cached tool that still belongs to the character is reused unless the
	-- player just bought a new shovel, in which case its stored ShovelId
	-- attribute is stale and we rebuild from scratch so the visual + stats
	-- match the purchased tier.
	local existing = equippedShovelByUserId[userId]
	if existing and existing.Parent == character then
		if ShovelComponent.getShovelId(existing) == desiredShovelId then
			return true
		end

		existing:Destroy()
		equippedShovelByUserId[userId] = nil
	elseif existing then
		existing:Destroy()
		equippedShovelByUserId[userId] = nil
	end

	local shovel = ShovelComponent.create(DigConfig.TOOL_NAME, desiredShovelId)
	if not shovel then
		return false
	end

	shovel.Parent = character

	equippedShovelByUserId[userId] = shovel
	shovel.AncestryChanged:Connect(function(_, parent)
		if parent == nil and equippedShovelByUserId[userId] == shovel then
			equippedShovelByUserId[userId] = nil
		end
	end)

	return true
end

local function scheduleShovelCleanup(player: Player)
	local userId = player.UserId
	local token = {}
	shovelCleanupTokenByUserId[userId] = token

	task.delay(SHOVEL_IDLE_TIMEOUT, function()
		if shovelCleanupTokenByUserId[userId] ~= token then
			return
		end
		shovelCleanupTokenByUserId[userId] = nil

		-- If the player started another session in the meantime, leave it alone.
		local session = activeSessionByUserId[userId]
		if session and session.phase ~= PHASE_BROKEN then
			return
		end

		unequipShovel(userId)
	end)
end

local function getGroundPositionInFrontOfPlayer(player: Player)
	local character = player.Character
	if not character then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { character }
	raycastParams.IgnoreWater = true

	local lookVector = root.CFrame.LookVector
	local forward = Vector3.new(lookVector.X, 0, lookVector.Z)
	if forward.Magnitude < 0.001 then
		forward = Vector3.new(0, 0, -1)
	else
		forward = forward.Unit
	end

	local targetPosition = root.Position + forward * DigConfig.DIG_FORWARD_DISTANCE
	local result = Workspace:Raycast(targetPosition + Vector3.new(0, 8, 0), Vector3.new(0, -24, 0), raycastParams)
	return if result then result.Position else targetPosition - Vector3.new(0, 3, 0)
end

local function getValidDigContext(player: Player, digPosition: Vector3)
	local character = player.Character
	if not character then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end

	local delta = digPosition - root.Position
	if delta.Magnitude > DigConfig.MAX_DIG_DISTANCE then
		return nil
	end

	return DigSiteService.getDigContext(player, digPosition)
end

-- Forward declaration so createSession can wire up the session-timeout
-- callback before the function itself is defined further down the file.
local expireSession

local function clearSession(userId: number, session)
	if activeSessionByUserId[userId] == session then
		activeSessionByUserId[userId] = nil
	end
end

local function createSession(userId: number, digPosition: Vector3, digContext, shovelStats: ShovelConfig.ShovelStats)
	spawnTicketByUserId[userId] = (spawnTicketByUserId[userId] or 0) + 1

	-- Snapshot the shovel's stats at session start. We don't want a mid-dig
	-- shovel swap (e.g. player buys a new tier between hits) to mutate the
	-- break/luck math part-way through the session, since that produces
	-- inconsistent risk feedback. The next session will pick up the new
	-- stats automatically.
	local player = Players:GetPlayerByUserId(userId)
	local shovelUpgrades = if player then PlayerDataService.getShovelUpgrades(player) else { luck = 0, greenBar = 0, walkSpeed = 0 }
	local luckMult = ShovelUpgradeConfig.getLuckMultiplier(shovelUpgrades.luck)

	local contextLuck = (digContext and digContext.luckMultiplier) or 1
	local baselineLuck = contextLuck * shovelStats.baseLuck * luckMult

	local now = os.clock()
	local session = {
		position = digPosition,
		context = digContext,
		hits = 0,
		extraHits = 0,
		-- Seed lastHitAt to `now` so the chain-timeout check in
		-- getActiveSession doesn't immediately trip during the countdown
		-- (the session can sit in PHASE_DIGGING for several seconds with no
		-- actual hits yet on the very first click).
		lastHitAt = now,
		phase = PHASE_STANDARD,
		ticket = spawnTicketByUserId[userId],
		-- Per-session countdown bookkeeping. digTicket increments every time
		-- a fresh countdown starts so any in-flight task.delay completion
		-- can detect that it's been superseded (e.g. by cancel + redig).
		digTicket = 0,
		digDuration = 0,
		baselineLuck = baselineLuck,
		currentLuck = baselineLuck,
		shovelRequiredHits = shovelStats.requiredHits,
		shovelBreakPerHit = shovelStats.breakPerHit,
		shovelBaseLuck = shovelStats.baseLuck,
		shovelDigDuration = shovelStats.digDuration or 1,
		shovelUpgradeLuckMult = luckMult,
		shovelUpgradeSpeedMult = ShovelUpgradeConfig.getDigDurationMultiplier(shovelUpgrades.greenBar),
		startedAt = now,
		expiresAt = now + DigConfig.DIG_SESSION_TIMEOUT,
	}
	activeSessionByUserId[userId] = session

	-- Hard session timeout. Locked to the spawnTicket so a session that
	-- already ended (commit / break / cancel / new session) is left alone.
	local sessionTicket = session.ticket
	task.delay(DigConfig.DIG_SESSION_TIMEOUT, function()
		local current = activeSessionByUserId[userId]
		if not current or current.ticket ~= sessionTicket then
			return
		end
		if current.phase == PHASE_COMMITTING or current.phase == PHASE_BROKEN then
			return
		end

		local player = Players:GetPlayerByUserId(userId)
		if not player then
			clearSession(userId, current)
			return
		end

		expireSession(player, current)
	end)

	return session
end

-- Break chance for the Nth extra hit (1-indexed): the first extra hit (the
-- (requiredHits+1)th total dig) is breakPerHit, the second 2*breakPerHit,
-- and so on, capped at 100%. breakPerHit is shovel-specific so the curve
-- gets gentler as the player upgrades their tool.
local function getBreakChanceForExtraHit(extraHitIndex: number, breakPerHit: number): number
	local n = math.max(1, extraHitIndex)
	local chance = n * breakPerHit
	return math.clamp(chance, 0, 1)
end

-- Luck after N survived extra hits: baseline × MULT^N (each deep hit applies to base stack).
local function getLuckAfterExtraHits(baselineLuck: number, extraHitsSurvived: number): number
	local n = math.max(0, extraHitsSurvived)
	return baselineLuck * (DigConfig.EXTRA_HIT_LUCK_MULT ^ n)
end

local function getSecondsRemaining(session): number
	if not session or not session.expiresAt then
		return 0
	end
	return math.max(0, session.expiresAt - os.clock())
end

local function fireSessionState(player: Player, session)
	local breakPerHit = session.shovelBreakPerHit or DigConfig.EXTRA_HIT_BREAK_PER_HIT
	local nextRisk = getBreakChanceForExtraHit(session.extraHits + 1, breakPerHit)
	digStateRemote:FireClient(player, {
		phase = session.phase,
		hits = session.hits,
		extraHits = session.extraHits,
		requiredHits = session.shovelRequiredHits or DigConfig.DIG_REQUIRED_HITS,
		riskNext = nextRisk,
		luckMultiplier = session.currentLuck,
		baselineLuck = session.baselineLuck,
		position = session.position,
		secondsRemaining = getSecondsRemaining(session),
		sessionTimeout = DigConfig.DIG_SESSION_TIMEOUT,
		-- Effective countdown duration for the upcoming or in-flight dig,
		-- so the client gauge can stay in sync if a state push lands while
		-- PHASE_DIGGING is active (e.g. luck/context refresh mid-countdown).
		digDuration = session.digDuration or 0,
		candidate = session.candidate,
		candidateRevision = session.candidateRevision or 0,
	})
end

-- Sent after any session teardown (commit, cancel) so the client can hide
-- the world-space dig prompt and reset its visuals. Break fires its own
-- broken-phase state which the client also treats as a reset. The idle
-- payload uses the player's currently-equipped shovel's required-hits so
-- the prompt UI dot count matches what the next session will actually need.
local function fireIdleState(player: Player)
	local shovelStats = ShovelConfig.getEffectiveStats(PlayerDataService.getShovel(player))
	local upgrades = PlayerDataService.getShovelUpgrades(player)
	local upMult = ShovelUpgradeConfig.getDigDurationMultiplier(upgrades.greenBar)
	local idleDuration = math.max(
		DigConfig.DIG_COUNTDOWN_MIN_DURATION,
		(shovelStats.digDuration or 1) * upMult
	)
	digStateRemote:FireClient(player, {
		phase = "idle",
		hits = 0,
		extraHits = 0,
		requiredHits = shovelStats.requiredHits,
		riskNext = 0,
		luckMultiplier = 1,
		baselineLuck = 1,
		position = nil,
		-- Effective duration the next dig will take, so the prompt UI can
		-- preview the countdown before the player even clicks (e.g. "5s
		-- dig — KEEP DIGGING" / "0.8s dig — Brainrot Shovel").
		digDuration = idleDuration,
	})
end

local function cancelSession(userId: number)
	local session = activeSessionByUserId[userId]
	if session then
		-- Bump the dig ticket so any in-flight countdown completion task
		-- detects the cancel and bails out instead of incrementing hits /
		-- rolling a candidate against a dead session.
		session.digTicket = (session.digTicket or 0) + 1
		local tool = equippedShovelByUserId[userId]
		if tool then
			ShovelAnimator.stopLooping(tool)
		end
		local player = Players:GetPlayerByUserId(userId)
		if player then
			fireIdleState(player)
		end
	end

	activeSessionByUserId[userId] = nil
end

local function buildSpawnContext(session)
	local baselineContext = session.context or {}
	local merged = {}
	for key, value in pairs(baselineContext) do
		merged[key] = value
	end
	merged.luckMultiplier = session.currentLuck
	merged.deepDigExtraHits = session.extraHits
	return merged
end

-- Step 3 of the dig minigame rework: every swing rolls a *candidate*
-- (silhouette) the player can choose to claim or reroll. The candidate is
-- locked into the session so the eventual commit spawns the brainrot the
-- player actually saw, never a fresh roll. The revision counter lets the
-- client tell new candidates from idle state pushes and only re-trigger
-- the rise animation when the silhouette actually changes.
local function rollAndStoreCandidate(session)
	local spawnContext = buildSpawnContext(session)
	local candidate = BrainrotSpawnService.rollCandidate(spawnContext)
	-- Replicate the luck used for this roll alongside the result so the
	-- client gauge can show "x1.50 LUCK" without recomputing.
	candidate.luckMultiplier = session.currentLuck
	session.candidate = candidate
	session.candidateRevision = (session.candidateRevision or 0) + 1
	return candidate
end

-- Forward declaration so commitSession can be referenced before definition.
local commitSession

local function getActiveSession(userId: number, now: number)
	local session = activeSessionByUserId[userId]
	if not session then
		return nil
	end

	if session.phase == PHASE_COMMITTING or session.phase == PHASE_BROKEN then
		return nil
	end

	-- Click mode keeps sessions alive between clicks; the safety-net chain
	-- timeout is huge to avoid surprising the player at the claim-or-risk
	-- decision. If it ever does trip, just cancel.
	local timedOut = now - session.lastHitAt > DigConfig.DIG_CHAIN_TIMEOUT
	if timedOut then
		cancelSession(userId)
		return nil
	end

	return session
end

local function fireBreak(player: Player, session)
	local position = session.position
	-- Even when the shovel snaps the dirt is still disturbed, so the spot
	-- becomes a regular dug hole and counts against fresh-spot validation.
	-- Failures from markDug are non-fatal here: they just mean the position
	-- already had a marker (race with another break/timeout) so we leave the
	-- existing one alone.
	session.phase = PHASE_BROKEN
	DigSiteService.markDug(position, session.extraHits)
	digBrokenRemote:FireClient(player, {
		position = position,
		extraHits = session.extraHits,
	})
	digStateRemote:FireClient(player, {
		phase = PHASE_BROKEN,
		hits = session.hits,
		extraHits = session.extraHits,
		requiredHits = session.shovelRequiredHits or DigConfig.DIG_REQUIRED_HITS,
		riskNext = 0,
		luckMultiplier = session.currentLuck,
		baselineLuck = session.baselineLuck,
		position = position,
		secondsRemaining = 0,
		sessionTimeout = DigConfig.DIG_SESSION_TIMEOUT,
	})

	cooldownByUserId[player.UserId] = os.clock() + DigConfig.BREAK_COOLDOWN
	clearSession(player.UserId, session)
	-- Drop the shovel after a beat so the player gets a clear break beat
	-- before it pops back for the next attempt.
	scheduleShovelCleanup(player)

	-- After the snap animation has played, send a fresh idle state so the
	-- client's lastSessionPhase mirror flips off "broken". Without this the
	-- floor-click handler in DigController stays gated on the broken phase
	-- forever and every subsequent click silently no-ops — looking exactly
	-- like "I can't dig anywhere else after my shovel breaks." The other
	-- session-ending paths (commitSession, expireSession, cancelSession)
	-- all call fireIdleState already; this is the missing one.
	local userIdForIdle = player.UserId
	task.delay(DigConfig.BREAK_COOLDOWN, function()
		local refreshed = Players:GetPlayerByUserId(userIdForIdle)
		if refreshed then
			fireIdleState(refreshed)
		end
	end)
end

expireSession = function(player: Player, session)
	if session.phase == PHASE_COMMITTING or session.phase == PHASE_BROKEN then
		return
	end

	local userId = player.UserId
	-- Stamp the spot as dug so the player can't camp the same hole; matches
	-- the broken-shovel behaviour but without the snap notification.
	session.phase = PHASE_BROKEN
	session.digTicket = (session.digTicket or 0) + 1
	local tool = equippedShovelByUserId[userId]
	if tool then
		ShovelAnimator.stopLooping(tool)
	end
	DigSiteService.markDug(session.position, session.extraHits)
	clearSession(userId, session)
	cooldownByUserId[userId] = os.clock() + DigConfig.DIG_COOLDOWN
	scheduleShovelCleanup(player)

	-- Hint + idle state so the prompt UI tears down cleanly. Reuse the
	-- existing reject hint path for the player-facing message.
	digRejectedRemote:FireClient(player, "Took too long! That dirt is now packed.")
	fireIdleState(player)
end

commitSession = function(player: Player, session)
	if session.phase == PHASE_COMMITTING or session.phase == PHASE_BROKEN then
		return
	end

	session.phase = PHASE_COMMITTING
	local userId = player.UserId
	local spawnTicket = session.ticket
	local commitContext = buildSpawnContext(session)

	-- Tell the client we're committing right away so the silhouette gauge
	-- can clear out of the dig spot before the actual brainrot rises out
	-- of the same position. Without this the gauge would still be visible
	-- 0.45s later when BrainrotSpawnService spawns the drop in the same
	-- world position, causing a brief visual overlap.
	fireSessionState(player, session)

	task.delay(DigConfig.DIG_REVEAL_DELAY, function()
		local resolvedPlayer = Players:GetPlayerByUserId(userId)
		if not resolvedPlayer then
			clearSession(userId, session)
			return
		end

		if spawnTicketByUserId[userId] ~= spawnTicket then
			clearSession(userId, session)
			return
		end

		if not DigSiteService.markDug(session.position, session.extraHits) then
			clearSession(userId, session)
			return
		end

		-- Spawn the brainrot the player saw in the silhouette gauge. The
		-- candidate was rolled on the swing that landed them here and has
		-- been locked into session.candidate ever since, so the rise reveal
		-- always matches what the player chose to PULL UP — never a fresh
		-- roll. resolvePrerolledRecord in BrainrotSpawnService falls back
		-- to a clean roll if the candidate is missing/corrupted, so commit
		-- still completes if anything ever drops the candidate field.
		local commitResult = BrainrotSpawnService.spawnForPlayer(
			resolvedPlayer,
			session.position,
			commitContext,
			session.candidate
		)
		if commitResult then
			brainrotSpawnedRemote:FireAllClients(resolvedPlayer, commitResult.dropId, commitResult.brainrotId, commitResult.position, {
				rarity = commitResult.rarity,
				rarityRank = commitResult.rarityRank,
				color = commitResult.color,
				revealColor = commitResult.revealColor,
				variantId = commitResult.variantId,
			})
		end

		clearSession(userId, session)

		local refreshedPlayer = Players:GetPlayerByUserId(userId)
		if refreshedPlayer then
			scheduleShovelCleanup(refreshedPlayer)
			cooldownByUserId[userId] = os.clock() + DigConfig.DIG_COOLDOWN
			fireIdleState(refreshedPlayer)
		end
	end)
end

-- Resolves the per-dig countdown duration for `player` given their current
-- shovel tier and Dig-Speed (greenBar) upgrade level. Floored at
-- DIG_COUNTDOWN_MIN_DURATION so heavily-upgraded players still see a brief
-- animation before the brainrot reveal.
local function computeDigDuration(session): number
	local baseDur = session.shovelDigDuration or 1
	local upMult = session.shovelUpgradeSpeedMult or 1
	return math.max(DigConfig.DIG_COUNTDOWN_MIN_DURATION, baseDur * upMult)
end

-- Resolves a swing: increments hits, runs the extra-phase break-chance roll
-- (now at the END of the countdown so the suspense matters), transitions the
-- session phase, refreshes luck, rolls and pushes the candidate to the
-- client. Called from the countdown-completion task scheduled by
-- beginCountdown.
local function resolveSwing(player: Player, session)
	local userId = player.UserId
	local now = os.clock()

	session.hits += 1
	session.lastHitAt = now
	local hitIndex = session.hits
	local requiredHits = session.shovelRequiredHits or DigConfig.DIG_REQUIRED_HITS
	local isStandardHit = hitIndex <= requiredHits
	local isStandardComplete = hitIndex == requiredHits
	local isExtraHit = hitIndex > requiredHits

	-- Extra-phase break roll runs AFTER the countdown plays so the player
	-- watches the full dig animation and the snap lands as a dramatic
	-- payoff at the end (rather than aborting the animation up-front).
	if isExtraHit then
		local breakPerHit = session.shovelBreakPerHit or DigConfig.EXTRA_HIT_BREAK_PER_HIT
		local breakChance = getBreakChanceForExtraHit(session.extraHits + 1, breakPerHit)
		if breakChance > 0 and rng:NextNumber() < breakChance then
			fireBreak(player, session)
			return
		end
	end

	if isStandardHit then
		if isStandardComplete then
			-- "Found it!" The dig now sits in the claim-or-risk window; the
			-- player can click KEEP BRAINROT to claim or KEEP DIGGING to
			-- start another countdown for a fresh roll.
			session.phase = PHASE_EXTRA
		end
	elseif isExtraHit then
		local extraIndex = session.extraHits + 1
		session.extraHits = extraIndex
		-- Multiplicative on session baseline so shovel/rebirth/spot luck stays
		-- the "base" that each deep hit amplifies.
		session.currentLuck = getLuckAfterExtraHits(session.baselineLuck, extraIndex)
		session.phase = PHASE_EXTRA
	end

	cooldownByUserId[userId] = now + DigConfig.DIG_HIT_COOLDOWN
	scheduleShovelCleanup(player)

	-- Roll a fresh candidate for the silhouette gauge using the now-final
	-- currentLuck for this swing. This is what the client will display rising
	-- out of the dirt; the player can KEEP BRAINROT to lock it in or KEEP
	-- DIGGING to reroll. commitSession spawns whatever candidate is current
	-- at claim time, so the silhouette and the actual loot always match.
	rollAndStoreCandidate(session)
	fireSessionState(player, session)
end

-- Transitions the session into PHASE_DIGGING, plays a looping shovel
-- animation, fires the DIG_COUNTDOWN_STARTED remote, and schedules the
-- delayed completion. digTicket is bumped so any in-flight completion task
-- from a prior countdown becomes a no-op if it lands after a cancel/re-dig.
local function beginCountdown(player: Player, session)
	local userId = player.UserId
	local now = os.clock()

	session.phase = PHASE_DIGGING
	session.lastHitAt = now
	session.digTicket = (session.digTicket or 0) + 1
	local digTicket = session.digTicket
	local digDuration = computeDigDuration(session)
	session.digDuration = digDuration
	session.digStartedAt = now
	session.digEndsAt = now + digDuration

	local tool = equippedShovelByUserId[userId]
	if tool then
		ShovelAnimator.playLoopingDigging(tool, digDuration)
	end

	-- The "standard" dig swing notification is repurposed for the countdown
	-- start: clients that still listen to digStartedRemote (e.g. for other-
	-- player VFX) can keep working without a separate hook.
	digStartedRemote:FireAllClients(player, session.position, digDuration, session.hits + 1, session.shovelRequiredHits or DigConfig.DIG_REQUIRED_HITS)
	digCountdownStartedRemote:FireClient(player, {
		duration = digDuration,
		position = session.position,
		phase = PHASE_DIGGING,
	})

	-- Push the state right away so the gauge knows we're in PHASE_DIGGING
	-- and can render the countdown ring. The candidate stays whatever was
	-- last rolled (or nil on the first dig); the client gauge ignores
	-- duplicate candidateRevisions, so this won't accidentally retrigger
	-- the rise animation on a stale silhouette.
	fireSessionState(player, session)

	task.delay(digDuration, function()
		local current = activeSessionByUserId[userId]
		if not current or current ~= session then
			return
		end
		if current.digTicket ~= digTicket then
			return
		end
		if current.phase ~= PHASE_DIGGING then
			return
		end

		local resolvedPlayer = Players:GetPlayerByUserId(userId)
		if not resolvedPlayer then
			clearSession(userId, current)
			return
		end

		resolveSwing(resolvedPlayer, current)
	end)
end

local function onDigRequest(player: Player, digPosition: Vector3)
	if typeof(digPosition) ~= "Vector3" then
		return
	end

	local userId = player.UserId
	if requestLockByUserId[userId] then
		return
	end
	requestLockByUserId[userId] = true

	local now = os.clock()
	local nextAllowedDig = cooldownByUserId[userId] or 0
	if now < nextAllowedDig then
		requestLockByUserId[userId] = nil
		return
	end

	local session = getActiveSession(userId, now)

	-- Reject a fresh click while a countdown is already running on the same
	-- spot. The looping animation + countdown ring own the screen during
	-- this window; the next legitimate action is either CANCEL or waiting
	-- for the countdown to land in PHASE_EXTRA.
	if session and session.phase == PHASE_DIGGING then
		requestLockByUserId[userId] = nil
		return
	end

	if not session then
		-- After a snap, the broken spot is already markDug'd, so any
		-- redig of that exact position bounces with "Already dug here!"
		-- through getValidDigContext below. The old must-move-3-studs
		-- guard that used to live here was harmful — it blocked clicks
		-- on neighbouring spots whenever the character itself hadn't
		-- physically walked away yet — and the dug-spot check is enough
		-- on its own.

		-- In click mode, the client sends the floor click position. If the
		-- snap to that exact spot fails server-side validation, fall back to
		-- the ground in front of the player so the dig still has a chance to
		-- land cleanly.
		local targetDigPosition = digPosition
		local digContext, rejectReason = getValidDigContext(player, targetDigPosition)
		-- Don't attempt a fallback position when the clicked spot is already dug;
		-- the player should see the "Already dug here!" hint instead of being
		-- silently rerouted to wherever the fallback lands.
		if not digContext and rejectReason ~= "Already dug here!" then
			local fallback = getGroundPositionInFrontOfPlayer(player)
			if fallback then
				digContext, rejectReason = getValidDigContext(player, fallback)
				if digContext then
					targetDigPosition = fallback
				end
			end
		end

		if not digContext then
			rejectDig(player, rejectReason)
			requestLockByUserId[userId] = nil
			return
		end

		local shovelStats = ShovelConfig.getEffectiveStats(PlayerDataService.getShovel(player))
		session = createSession(userId, targetDigPosition, digContext, shovelStats)
	end

	if session.phase == PHASE_COMMITTING or session.phase == PHASE_BROKEN then
		requestLockByUserId[userId] = nil
		return
	end

	local sessionContext, rejectReason = getValidDigContext(player, session.position)
	if not sessionContext then
		rejectDig(player, rejectReason)
		cancelSession(userId)
		requestLockByUserId[userId] = nil
		return
	end
	-- Refresh session context so any luck swings (gold rush ending mid-dig,
	-- ground spot consumed, etc.) take effect for the eventual commit roll.
	session.context = sessionContext
	if session.phase == PHASE_STANDARD then
		local contextLuck = sessionContext.luckMultiplier or 1
		local luckMult = session.shovelUpgradeLuckMult or 1
		session.baselineLuck = contextLuck * (session.shovelBaseLuck or 1) * luckMult
		session.currentLuck = math.max(session.currentLuck, session.baselineLuck)
	end

	if not ensureShovelEquipped(player) then
		cancelSession(userId)
		requestLockByUserId[userId] = nil
		return
	end

	requestLockByUserId[userId] = nil
	beginCountdown(player, session)
end

-- "I missed the green zone." Fired by the client when the player stops the
-- timing bar cursor outside the green target while a session is active.
-- Treated as a break regardless of phase so the hole is marked dug and the
-- shovel snaps, giving miss = fail consequences in both standard and extra.
local function onDigMiss(player: Player)
	local userId = player.UserId
	local session = activeSessionByUserId[userId]
	if not session then
		return
	end

	if session.phase == PHASE_COMMITTING or session.phase == PHASE_BROKEN then
		return
	end

	fireBreak(player, session)
end

-- "I'm done with this dig." Fired by client on cancel / walk-off. Always
-- tears the session down regardless of phase; players use the explicit
-- PULL UP claim remote to actually take their loot.
local function onDigStop(player: Player)
	local userId = player.UserId
	local session = activeSessionByUserId[userId]
	if not session then
		return
	end

	if session.phase == PHASE_COMMITTING or session.phase == PHASE_BROKEN then
		return
	end

	cancelSession(userId)
end

-- "Pull up the brainrot." Fired by client on PULL UP click. After the Step
-- 3 rework the player can claim from either phase: every swing rolls a
-- candidate, so PULL UP is valid the moment the first candidate exists. We
-- still reject claims with no candidate (impossible in practice — the
-- session is created on the same click that produces the first roll — but
-- guarded so a malformed payload can't commit a nil-spawn).
local function onDigClaim(player: Player)
	local userId = player.UserId
	local session = activeSessionByUserId[userId]
	if not session then
		return
	end

	if session.phase ~= PHASE_STANDARD and session.phase ~= PHASE_EXTRA then
		return
	end

	if not session.candidate then
		return
	end

	commitSession(player, session)
end

function DigService.start()
	if started then
		return
	end
	started = true

	local digRequestRemote = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.DIG_REQUEST_REMOTE)
	if digRequestRemote:GetAttribute("DigServiceBound") then
		return
	end
	digRequestRemote:SetAttribute("DigServiceBound", true)

	digRequestRemote.OnServerEvent:Connect(onDigRequest)

	local digStopRemote = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.DIG_STOP_REMOTE)
	digStopRemote.OnServerEvent:Connect(onDigStop)

	local digClaimRemote = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.DIG_CLAIM_REMOTE)
	digClaimRemote.OnServerEvent:Connect(onDigClaim)

	local digMissRemote = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.DIG_MISS_REMOTE)
	digMissRemote.OnServerEvent:Connect(onDigMiss)

	-- Equip the shovel as soon as the player steps onto the dig site so it is
	-- visible the entire time they are there, not just when a dig request fires.
	local digSiteEnteredRemote = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.DIG_SITE_ENTERED_REMOTE)
	digSiteEnteredRemote.OnServerEvent:Connect(function(player: Player)
		ensureShovelEquipped(player)
	end)

	-- Remove the shovel immediately when the player leaves the dig site,
	-- unless the server is in the middle of committing a dig (pull-up reveal
	-- in flight) — in that case the existing cleanup schedule handles it.
	local digSiteLeftRemote = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.DIG_SITE_LEFT_REMOTE)
	digSiteLeftRemote.OnServerEvent:Connect(function(player: Player)
		local userId = player.UserId
		local session = activeSessionByUserId[userId]
		if session and session.phase == PHASE_COMMITTING then
			return
		end
		-- Defensive cancel: if the player walks off mid-countdown, tear the
		-- session down here as well. The client also fires DIG_STOP on
		-- walk-off, but that depends on hasActiveSession tracking; calling
		-- cancelSession here guarantees the scheduled completion task gets
		-- invalidated even if the client message is missed or delayed.
		if session and session.phase == PHASE_DIGGING then
			cancelSession(userId)
		end
		unequipShovel(userId)
	end)

	local function bindCharacterCleanup(player: Player)
		player.CharacterAdded:Connect(function()
			-- The previous character (and its shovel) was destroyed; clear the
			-- cached reference so the next dig request equips a fresh shovel.
			equippedShovelByUserId[player.UserId] = nil
			shovelCleanupTokenByUserId[player.UserId] = nil
			cancelSession(player.UserId)
		end)
	end

	Players.PlayerAdded:Connect(bindCharacterCleanup)
	for _, player in Players:GetPlayers() do
		bindCharacterCleanup(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		cancelSession(player.UserId)
		unequipShovel(player.UserId)
		cooldownByUserId[player.UserId] = nil
		requestLockByUserId[player.UserId] = nil
		spawnTicketByUserId[player.UserId] = nil
	end)
end

DigService.bind = DigService.start

return DigService
