local TweenService = game:GetService("TweenService")

local ShovelComponent = require(script.Parent:WaitForChild("ShovelComponent"))

-- Server-side dig swing.
--
-- Two property tracks run in parallel from the server:
--   1. Tool.Grip on the equipped shovel  -> the shovel arcs through windup,
--      thrust, scoop, recover.
--   2. Motor6D.C0 on the digger's body joints (right shoulder/elbow, left
--      shoulder/elbow, waist, root) -> the character poses through the same
--      phases.
--
-- Both are server-authoritative replicated properties, so the changes
-- propagate to every client without fighting the local Animator. The Animator
-- continues to write Motor6D.Transform locally for idle/walk; that's layered
-- on top of our C0 offset (final pose = parent.CFrame * C0 * Transform), so
-- the dig pose stays put while subtle idle motion plays underneath.
--
-- Two entry points are exposed:
--   * playSwing      — a single windup → thrust → scoop → recover cycle, used
--                      for the legacy one-shot dig and any "hit cadence" caller.
--   * playLoopingDigging — chains full swings back-to-back for a target
--                      duration (the new countdown dig animation). Returns
--                      immediately; the coroutine self-cancels when the next
--                      generation tick is bumped (e.g. by stopLooping or by
--                      another caller).

local ShovelAnimator = {}

local REST_GRIP = ShovelComponent.DEFAULT_GRIP

-- Pure-rotation Tool.Grip deltas around the handle's local X axis. Slerp
-- between consecutive poses takes the SHORTEST angular arc, so we keep every
-- transition well under 180 degrees to avoid the shovel spinning through the
-- back side.
--
-- Heavier wind-up + deeper thrust than the original 80/-60/+15 tuning so the
-- looping dig animation reads as a meaty, repeated "raise and slam" rather
-- than a flick of the wrist. Transitions:
--   REST(0)   -> WINDUP(+92)  =  92 deg
--   WINDUP    -> THRUST(-72)  = 164 deg (still under 180)
--   THRUST    -> SCOOP(+22)   =  94 deg
--   SCOOP     -> REST(0)      =  22 deg
local WINDUP_GRIP = REST_GRIP * CFrame.Angles(math.rad(92), 0, 0)
local THRUST_GRIP = REST_GRIP * CFrame.Angles(math.rad(-72), 0, 0)
local SCOOP_GRIP = REST_GRIP * CFrame.Angles(math.rad(22), 0, 0)

-- Motor6D names for both R15 and R6. Missing motors are simply skipped per
-- character (R6 has no elbow joints, for example).
local MOTOR_NAMES = {
	rightShoulder = { "RightShoulder", "Right Shoulder" },
	leftShoulder = { "LeftShoulder", "Left Shoulder" },
	rightElbow = { "RightElbow" },
	leftElbow = { "LeftElbow" },
	waist = { "Waist" },
	rootJoint = { "RootJoint" },
}

-- Body pose offsets applied as motor.C0 = original * offset. Tuned so each
-- motor's per-phase angular travel stays under the slerp ambiguity threshold,
-- matching the shovel's windup -> thrust -> scoop -> recover phasing.
local REST_POSE = {} :: { [string]: CFrame }

-- Wind-up: rotate back, lift the shovel high over the shoulder. Slightly
-- exaggerated lean so the character visibly loads for the slam.
local WINDUP_POSE = {
	rightShoulder = CFrame.Angles(math.rad(-72), 0, math.rad(22)),
	leftShoulder = CFrame.Angles(math.rad(-58), 0, math.rad(-15)),
	rightElbow = CFrame.Angles(math.rad(-70), 0, 0),
	leftElbow = CFrame.Angles(math.rad(-55), 0, 0),
	waist = CFrame.Angles(math.rad(-10), math.rad(-18), 0),
	rootJoint = CFrame.Angles(0, math.rad(18), 0),
}

-- Thrust: explosive downward slam. Wider arc + more torso pitch sells weight.
local THRUST_POSE = {
	rightShoulder = CFrame.Angles(math.rad(62), 0, math.rad(-8)),
	leftShoulder = CFrame.Angles(math.rad(48), 0, math.rad(12)),
	rightElbow = CFrame.Angles(math.rad(-12), 0, 0),
	leftElbow = CFrame.Angles(math.rad(-18), 0, 0),
	waist = CFrame.Angles(math.rad(26), math.rad(12), 0),
	rootJoint = CFrame.Angles(0, math.rad(-12), 0),
}

-- Scoop: lift the dirt back up out of the hole.
local SCOOP_POSE = {
	rightShoulder = CFrame.Angles(math.rad(18), 0, math.rad(-6)),
	leftShoulder = CFrame.Angles(math.rad(14), 0, math.rad(12)),
	rightElbow = CFrame.Angles(math.rad(-60), 0, 0),
	leftElbow = CFrame.Angles(math.rad(-48), 0, 0),
	waist = CFrame.Angles(math.rad(10), 0, 0),
	rootJoint = CFrame.identity,
}

type MotorCache = {
	motors: { [string]: Motor6D },
	originals: { [string]: CFrame },
	cleanupConnection: RBXScriptConnection?,
}

local generationByTool: { [Tool]: number } = {}
local activeTweensByTool: { [Tool]: { Tween } } = {}
local cleanupBoundByTool: { [Tool]: boolean } = {}
local motorCacheByCharacter: { [Model]: MotorCache } = {}

local function findMotor(character: Model, names: { string }): Motor6D?
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("Motor6D") and table.find(names, descendant.Name) then
			return descendant
		end
	end

	return nil
end

local function getCharacter(tool: Tool): Model?
	local parent = tool.Parent
	if parent and parent:IsA("Model") and parent:FindFirstChildOfClass("Humanoid") then
		return parent
	end
	return nil
end

local function clearMotorCacheFor(character: Model)
	local cache = motorCacheByCharacter[character]
	if not cache then
		return
	end
	if cache.cleanupConnection then
		cache.cleanupConnection:Disconnect()
		cache.cleanupConnection = nil
	end
	motorCacheByCharacter[character] = nil
end

local function getMotorCache(character: Model): MotorCache
	local existing = motorCacheByCharacter[character]
	if existing then
		return existing
	end

	local motors: { [string]: Motor6D } = {}
	local originals: { [string]: CFrame } = {}
	for key, names in MOTOR_NAMES do
		local motor = findMotor(character, names)
		if motor then
			motors[key] = motor
			originals[key] = motor.C0
		end
	end

	local cache: MotorCache = {
		motors = motors,
		originals = originals,
		cleanupConnection = nil,
	}

	cache.cleanupConnection = character.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			clearMotorCacheFor(character)
		end
	end)

	motorCacheByCharacter[character] = cache
	return cache
end

local function offsetFor(pose: { [string]: CFrame }, key: string): CFrame
	return pose[key] or CFrame.identity
end

local function cancelActiveTweens(tool: Tool)
	local tweens = activeTweensByTool[tool]
	if not tweens then
		return
	end
	for _, tween in tweens do
		tween:Cancel()
	end
	activeTweensByTool[tool] = nil
end

local function bindCleanup(tool: Tool)
	if cleanupBoundByTool[tool] then
		return
	end
	cleanupBoundByTool[tool] = true

	tool.AncestryChanged:Connect(function(_, parent)
		if parent ~= nil then
			return
		end
		cancelActiveTweens(tool)
		generationByTool[tool] = nil
		cleanupBoundByTool[tool] = nil
	end)
end

-- Shared phase runner used by both single-shot playSwing and the looping dig
-- animation. Drives Tool.Grip + every cached Motor6D.C0 toward (toolTarget,
-- pose) in parallel, waits for completion, and returns false if the
-- generation was bumped while we were tweening (so callers can bail out).
local function runPhase(
	tool: Tool,
	generation: number,
	motorCache: MotorCache?,
	toolTarget: CFrame,
	pose: { [string]: CFrame },
	time: number,
	style: Enum.EasingStyle,
	direction: Enum.EasingDirection
): boolean
	if generationByTool[tool] ~= generation or not tool.Parent then
		return false
	end

	local info = TweenInfo.new(time, style, direction)
	local tweens: { Tween } = {}

	local toolTween = TweenService:Create(tool, info, { Grip = toolTarget })
	table.insert(tweens, toolTween)

	if motorCache then
		for key, motor in motorCache.motors do
			local original = motorCache.originals[key]
			if motor and motor.Parent and original then
				local target = original * offsetFor(pose, key)
				local motorTween = TweenService:Create(motor, info, { C0 = target })
				table.insert(tweens, motorTween)
			end
		end
	end

	activeTweensByTool[tool] = tweens

	for _, tween in tweens do
		tween:Play()
	end

	toolTween.Completed:Wait()

	if activeTweensByTool[tool] == tweens then
		activeTweensByTool[tool] = nil
	end

	return generationByTool[tool] == generation and tool.Parent ~= nil
end

-- Plays a single dig swing on the given equipped Tool over `duration` seconds.
-- Safe to call again before the previous swing finishes; the in-flight tweens
-- are cancelled and the new swing starts from the current grip/joint poses so
-- back-to-back digs flow smoothly.
function ShovelAnimator.playSwing(tool: Tool?, duration: number)
	if not tool or not tool.Parent then
		return
	end

	bindCleanup(tool)

	local generation = (generationByTool[tool] or 0) + 1
	generationByTool[tool] = generation

	cancelActiveTweens(tool)

	local character = getCharacter(tool)
	local motorCache: MotorCache? = if character then getMotorCache(character) else nil

	local safeDuration = math.max(0.22, duration)
	local windupTime = safeDuration * 0.30
	local thrustTime = safeDuration * 0.18
	local scoopTime = safeDuration * 0.22
	local recoverTime = safeDuration * 0.30

	task.spawn(function()
		if not runPhase(tool, generation, motorCache, WINDUP_GRIP, WINDUP_POSE, windupTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out) then
			return
		end
		if not runPhase(tool, generation, motorCache, THRUST_GRIP, THRUST_POSE, thrustTime, Enum.EasingStyle.Quint, Enum.EasingDirection.In) then
			return
		end
		if not runPhase(tool, generation, motorCache, SCOOP_GRIP, SCOOP_POSE, scoopTime, Enum.EasingStyle.Back, Enum.EasingDirection.Out) then
			return
		end
		if not runPhase(tool, generation, motorCache, REST_GRIP, REST_POSE, recoverTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out) then
			return
		end
	end)
end

-- Tuning for the looping dig animation. Each full swing is roughly
-- SWING_DURATION_DEFAULT seconds; we sub-divide that into windup/thrust/
-- scoop/recover at the same ratios as playSwing so the cadence reads
-- consistently regardless of whether one swing or twelve are played.
local SWING_DURATION_DEFAULT = 0.55
local SWING_DURATION_MIN = 0.32

-- Chains shovel swings back-to-back for `totalDuration` seconds (or until the
-- generation is bumped by another caller / stopLooping). At least one full
-- swing always plays even if totalDuration is short: the per-swing length is
-- shrunk to fit so the player still sees a complete windup→thrust→scoop on
-- the fastest shovel tiers. Safe to call again to restart; the in-flight loop
-- is cancelled like any other generation bump.
function ShovelAnimator.playLoopingDigging(tool: Tool?, totalDuration: number, swingDurationOverride: number?)
	if not tool or not tool.Parent then
		return
	end

	bindCleanup(tool)

	local generation = (generationByTool[tool] or 0) + 1
	generationByTool[tool] = generation

	cancelActiveTweens(tool)

	local character = getCharacter(tool)
	local motorCache: MotorCache? = if character then getMotorCache(character) else nil

	local total = math.max(0.1, totalDuration)
	-- Shrink the per-swing length so at least one full swing fits inside
	-- short countdowns (e.g. the Brainrot Shovel at 0.8s total).
	local swingDuration = math.clamp(
		swingDurationOverride or SWING_DURATION_DEFAULT,
		SWING_DURATION_MIN,
		math.max(SWING_DURATION_MIN, total)
	)

	local startedAt = os.clock()
	local endsAt = startedAt + total

	task.spawn(function()
		while true do
			if generationByTool[tool] ~= generation or not tool.Parent then
				return
			end

			local now = os.clock()
			if now >= endsAt then
				-- Loop has covered the full countdown; the caller (DigService)
				-- handles teardown / the next pose, so leave the shovel
				-- wherever the last completed phase left it.
				return
			end

			local windupTime = swingDuration * 0.30
			local thrustTime = swingDuration * 0.18
			local scoopTime = swingDuration * 0.22
			local recoverTime = swingDuration * 0.30

			if not runPhase(tool, generation, motorCache, WINDUP_GRIP, WINDUP_POSE, windupTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out) then
				return
			end
			if not runPhase(tool, generation, motorCache, THRUST_GRIP, THRUST_POSE, thrustTime, Enum.EasingStyle.Quint, Enum.EasingDirection.In) then
				return
			end
			if not runPhase(tool, generation, motorCache, SCOOP_GRIP, SCOOP_POSE, scoopTime, Enum.EasingStyle.Back, Enum.EasingDirection.Out) then
				return
			end
			if not runPhase(tool, generation, motorCache, REST_GRIP, REST_POSE, recoverTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out) then
				return
			end
		end
	end)
end

local STOP_RECOVER_DURATION = 0.18

-- Aborts any in-flight playSwing / playLoopingDigging on this tool and tweens
-- the grip + joints back to their rest poses over STOP_RECOVER_DURATION.
-- Safe to call when nothing is running; in that case it just re-asserts rest.
function ShovelAnimator.stopLooping(tool: Tool?)
	if not tool or not tool.Parent then
		return
	end

	bindCleanup(tool)

	local generation = (generationByTool[tool] or 0) + 1
	generationByTool[tool] = generation

	cancelActiveTweens(tool)

	local character = getCharacter(tool)
	local motorCache: MotorCache? = if character then getMotorCache(character) else nil

	task.spawn(function()
		runPhase(tool, generation, motorCache, REST_GRIP, REST_POSE, STOP_RECOVER_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	end)
end

return ShovelAnimator
