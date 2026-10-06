local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UtilFolder = Shared:WaitForChild("Util")
local BrainrotVisualFactory = require(UtilFolder:WaitForChild("BrainrotVisualFactory"))

local BrainrotIdleController = {}
local started = false

-- Subtle bob + sway applied every frame so rigged brainrots still feel alive
-- when no Animation asset has been uploaded for them. Tune these to taste.
local BOB_STUDS = 0.15
local BOB_HZ = 0.8
local SWAY_DEGREES = 2
local SWAY_HZ = 0.55

type IdleState = {
	baseCFrame: CFrame,
	phase: number,
	destroyingConnection: RBXScriptConnection,
}

local activeIdles: { [Model]: IdleState } = {}
local renderConnection: RBXScriptConnection? = nil
local startClock = os.clock()

local function stopTracking(model: Model)
	local state = activeIdles[model]
	if not state then
		return
	end

	state.destroyingConnection:Disconnect()
	activeIdles[model] = nil
end

local function stepIdles()
	local t = os.clock() - startClock
	local swayRadians = math.rad(SWAY_DEGREES)
	local hasAny = false

	for model, state in activeIdles do
		if not model.Parent then
			stopTracking(model)
			continue
		end

		hasAny = true
		local phase = state.phase
		local bob = BOB_STUDS * math.sin(t * BOB_HZ * math.pi * 2 + phase)
		local sway = swayRadians * math.sin(t * SWAY_HZ * math.pi * 2 + phase * 0.5)
		-- `PivotTo` handles both rig shapes the factory produces: world spawns
		-- (only the root is anchored, Motor6D children follow) and UI viewport
		-- clones (every part anchored, moved as a rigid group).
		model:PivotTo(state.baseCFrame * CFrame.new(0, bob, 0) * CFrame.Angles(0, sway, 0))
	end

	if not hasAny and renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
end

local function ensureRenderLoop()
	if renderConnection then
		return
	end

	-- RenderStepped fires once per rendered frame right before the scene is
	-- drawn, so transforms written here appear with no one-frame lag. It's
	-- also independent of physics throttling, which avoids the choppiness we
	-- saw when driving the idle from Heartbeat on the server.
	renderConnection = RunService.RenderStepped:Connect(stepIdles)
end

local function trackModel(model: Model)
	if activeIdles[model] then
		return
	end
	if not model.Parent then
		return
	end

	activeIdles[model] = {
		-- Capture the placement pivot at start so oscillation is relative to
		-- wherever the caller put the model rather than the origin.
		baseCFrame = model:GetPivot(),
		-- Per-model phase offset so a group of visible brainrots doesn't bob
		-- in perfect lockstep.
		phase = math.random() * math.pi * 2,
		destroyingConnection = model.Destroying:Connect(function()
			stopTracking(model)
		end),
	}

	ensureRenderLoop()
end

function BrainrotIdleController.start()
	if started then
		return
	end
	started = true

	local tag = BrainrotVisualFactory.PROCEDURAL_IDLE_TAG

	for _, model in CollectionService:GetTagged(tag) do
		if model:IsA("Model") then
			trackModel(model)
		end
	end

	CollectionService:GetInstanceAddedSignal(tag):Connect(function(instance)
		if instance:IsA("Model") then
			trackModel(instance)
		end
	end)

	CollectionService:GetInstanceRemovedSignal(tag):Connect(function(instance)
		if instance:IsA("Model") then
			stopTracking(instance)
		end
	end)
end

return BrainrotIdleController
