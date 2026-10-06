local RunService = game:GetService("RunService")

local DigVFX = require(script.Parent:WaitForChild("DigVFX"))

local CharacterAnimator = {}

-- Client-side body motion + dust puff timing for the dig swing. The visible
-- shovel swing itself is driven SERVER SIDE (see Server/Components/
-- ShovelAnimator) by tweening Tool.Grip; the server is authoritative for that
-- property so the swing replicates to every client without fighting any local
-- Animator. Here we add a best-effort overlay of body motion via direct
-- Motor6D.Transform writes from a RenderStepped callback at
-- RenderPriority.Last. On rigs/configs where these writes land cleanly the
-- arms will swing along; if they get overwritten by an animation track, the
-- shovel still swings on its own and nothing here breaks anything.

local MOTOR_NAMES = {
	rightShoulder = { "RightShoulder", "Right Shoulder" },
	leftShoulder = { "LeftShoulder", "Left Shoulder" },
	rightElbow = { "RightElbow" },
	leftElbow = { "LeftElbow" },
	waist = { "Waist" },
	rootJoint = { "RootJoint", "Root" },
}
local POSE_KEYS = { "rightShoulder", "leftShoulder", "rightElbow", "leftElbow", "waist", "rootJoint" }

-- Pose offsets are RELATIVE rotations applied as the joint's Transform on
-- top of its rest C0. Four-phase shovel dig matching the server-side
-- Tool.Grip phases: wind back over right shoulder with hip turn, thrust the
-- blade down-and-forward into the dirt, scoop it back toward the chest, then
-- recover.
local REST_POSE = {} :: { [string]: CFrame }

local WINDUP_POSE = {
	rightShoulder = CFrame.Angles(math.rad(-90), 0, math.rad(35)),
	leftShoulder = CFrame.Angles(math.rad(-80), 0, math.rad(-30)),
	rightElbow = CFrame.Angles(math.rad(-95), 0, 0),
	leftElbow = CFrame.Angles(math.rad(-70), 0, 0),
	waist = CFrame.Angles(math.rad(-10), math.rad(-25), 0),
	rootJoint = CFrame.Angles(0, math.rad(20), 0),
}

local THRUST_POSE = {
	rightShoulder = CFrame.Angles(math.rad(70), 0, math.rad(-8)),
	leftShoulder = CFrame.Angles(math.rad(55), 0, math.rad(15)),
	rightElbow = CFrame.Angles(math.rad(-15), 0, 0),
	leftElbow = CFrame.Angles(math.rad(-20), 0, 0),
	waist = CFrame.Angles(math.rad(35), math.rad(15), 0),
	rootJoint = CFrame.Angles(0, math.rad(-15), 0),
}

local SCOOP_POSE = {
	rightShoulder = CFrame.Angles(math.rad(20), 0, math.rad(-5)),
	leftShoulder = CFrame.Angles(math.rad(15), 0, math.rad(10)),
	rightElbow = CFrame.Angles(math.rad(-75), 0, 0),
	leftElbow = CFrame.Angles(math.rad(-65), 0, 0),
	waist = CFrame.Angles(math.rad(10), math.rad(5), 0),
	rootJoint = CFrame.Angles(0, math.rad(-5), 0),
}

local function easeOutQuad(t: number): number
	local inv = 1 - t
	return 1 - inv * inv
end

local function easeInQuint(t: number): number
	return t * t * t * t * t
end

local function easeOutBack(t: number): number
	local c1 = 1.70158
	local c3 = c1 + 1
	local d = t - 1
	return 1 + c3 * d * d * d + c1 * d * d
end

type Phase = {
	name: string,
	from: { [string]: CFrame },
	to: { [string]: CFrame },
	fraction: number,
	ease: (number) -> number,
}

local PHASES: { Phase } = {
	{ name = "windup", from = REST_POSE, to = WINDUP_POSE, fraction = 0.30, ease = easeOutQuad },
	{ name = "thrust", from = WINDUP_POSE, to = THRUST_POSE, fraction = 0.18, ease = easeInQuint },
	{ name = "scoop", from = THRUST_POSE, to = SCOOP_POSE, fraction = 0.22, ease = easeOutBack },
	{ name = "recover", from = SCOOP_POSE, to = REST_POSE, fraction = 0.30, ease = easeOutQuad },
}

type Motors = { [string]: Motor6D }
type CharacterState = {
	motors: Motors,
	generation: number,
	activeStepName: string?,
	cleanupConnection: RBXScriptConnection?,
}

local stateByCharacter: { [Model]: CharacterState } = {}
local nextStepId = 0

local function findMotor(character: Model, names: { string }): Motor6D?
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("Motor6D") and table.find(names, descendant.Name) then
			return descendant
		end
	end

	return nil
end

local function refreshMotors(state: CharacterState, character: Model)
	for key, names in MOTOR_NAMES do
		local current = state.motors[key]
		if not current or not current.Parent then
			local motor = findMotor(character, names)
			if motor then
				state.motors[key] = motor
			else
				state.motors[key] = nil
			end
		end
	end
end

local function getOrInitState(character: Model): CharacterState
	local existing = stateByCharacter[character]
	if existing then
		refreshMotors(existing, character)
		return existing
	end

	local state: CharacterState = {
		motors = {},
		generation = 0,
		activeStepName = nil,
		cleanupConnection = nil,
	}

	refreshMotors(state, character)

	state.cleanupConnection = character.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			if state.cleanupConnection then
				state.cleanupConnection:Disconnect()
				state.cleanupConnection = nil
			end
			if state.activeStepName then
				pcall(function()
					RunService:UnbindFromRenderStep(state.activeStepName :: string)
				end)
				state.activeStepName = nil
			end
			stateByCharacter[character] = nil
		end
	end)

	stateByCharacter[character] = state
	return state
end

local function offsetFor(pose: { [string]: CFrame }, key: string): CFrame
	return pose[key] or CFrame.identity
end

local function clearTransforms(motors: Motors)
	for _, motor in motors do
		motor.Transform = CFrame.identity
	end
end

function CharacterAnimator.playShovel(character: Model, duration: number, digPosition: Vector3)
	if not character or not character.Parent then
		return
	end

	local state = getOrInitState(character)

	-- Bumping the generation invalidates any in-flight swing for this same
	-- character so back-to-back digs don't double-fire dust puffs or leave
	-- the previous render-step callback fighting the new one.
	state.generation += 1
	local generation = state.generation

	if state.activeStepName then
		local previous = state.activeStepName
		pcall(function()
			RunService:UnbindFromRenderStep(previous)
		end)
		state.activeStepName = nil
	end

	local safeDuration = math.max(0.22, duration)

	nextStepId += 1
	local stepName = "DigSwing_" .. tostring(nextStepId)
	state.activeStepName = stepName

	local startTime = os.clock()
	local hasFiredDust = false

	local function finish()
		clearTransforms(state.motors)
		if state.activeStepName == stepName then
			state.activeStepName = nil
		end
		pcall(function()
			RunService:UnbindFromRenderStep(stepName)
		end)
	end

	local function step(_deltaTime: number)
		if state.generation ~= generation or not character.Parent then
			finish()
			return
		end

		local elapsed = os.clock() - startTime
		if elapsed >= safeDuration then
			finish()
			return
		end

		local accum = 0
		local activePhase: Phase = PHASES[#PHASES]
		local phaseStart = 0
		for _, phase in PHASES do
			local phaseDuration = safeDuration * phase.fraction
			if elapsed < accum + phaseDuration then
				activePhase = phase
				phaseStart = accum
				break
			end
			accum += phaseDuration
		end

		local phaseDuration = math.max(0.0001, safeDuration * activePhase.fraction)
		local rawAlpha = math.clamp((elapsed - phaseStart) / phaseDuration, 0, 1)
		local alpha = activePhase.ease(rawAlpha)

		for _, key in POSE_KEYS do
			local motor = state.motors[key]
			if motor and motor.Parent then
				local fromOffset = offsetFor(activePhase.from, key)
				local toOffset = offsetFor(activePhase.to, key)
				motor.Transform = fromOffset:Lerp(toOffset, alpha)
			end
		end

		-- Blade just drove into the dirt at the start of the scoop phase:
		-- kick up a puff once.
		if not hasFiredDust and activePhase.name == "scoop" then
			hasFiredDust = true
			DigVFX.spawnDustPuff(digPosition, 0.9)
		end
	end

	RunService:BindToRenderStep(stepName, Enum.RenderPriority.Last.Value, step)
end

return CharacterAnimator
