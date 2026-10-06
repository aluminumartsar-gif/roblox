-- Client-side weather presenter. Subscribes to WeatherService's start/end
-- remotes, asks for an initial sync on join, and dispatches each effect's
-- visual VFX (lighting, atmosphere, particles, sound) plus the bottom-right
-- WeatherTrayUI HUD chip.
--
-- Each effect owns uniquely-named Lighting children (e.g.
-- "Weather_Storm_ColorCorrection") so multiple effects can run simultaneously
-- without trampling each other or the EnvironmentService baseline. The Night
-- effect is the only one that needs to write Lighting.ClockTime; it captures
-- WeatherConfig.BASE_CLOCK_TIME when it ends and tweens back.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local DigConfig = require(ConfigFolder:WaitForChild("DigConfig"))
local WeatherConfig = require(ConfigFolder:WaitForChild("WeatherConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))

local Components = script.Parent.Parent:WaitForChild("Components")
local WeatherTrayUI = require(Components:WaitForChild("WeatherTrayUI"))

local WeatherController = {}
local started = false

local trayUI: any = nil
local activeHandles: { [string]: any } = {}

local FADE_IN = TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_OUT = TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

-- Helpers ------------------------------------------------------------------

local function makeColorCorrection(name: string, props): ColorCorrectionEffect
	local effect = Instance.new("ColorCorrectionEffect")
	effect.Name = name
	effect.Brightness = 0
	effect.Contrast = 0
	effect.Saturation = 0
	effect.TintColor = Color3.new(1, 1, 1)
	for key, value in props do
		(effect :: any)[key] = value
	end
	effect.Parent = Lighting
	return effect
end

local function tweenToTransparent(effect: ColorCorrectionEffect)
	local tween = TweenService:Create(effect, FADE_OUT, {
		Brightness = 0,
		Contrast = 0,
		Saturation = 0,
		TintColor = Color3.new(1, 1, 1),
	})
	tween:Play()
	tween.Completed:Once(function()
		effect:Destroy()
	end)
end

-- Per-effect handlers ------------------------------------------------------

local handlers: { [WeatherConfig.WeatherId]: {
	enable: () -> any,
	disable: (any) -> (),
} } = {}

handlers.Night = {
	enable = function()
		local night = WeatherConfig.EFFECTS.Night
		local clockTween = TweenService:Create(
			Lighting,
			TweenInfo.new(4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
			{ ClockTime = night.clockTime or 22 }
		)
		clockTween:Play()

		-- Slight positive brightness + cool tint reads as moonlight rather
		-- than darkening the scene further. ClockTime is already doing the
		-- heavy "it's night" lift, so visuals just need a tone shift.
		local effect = makeColorCorrection("Weather_Night_ColorCorrection", {
			Brightness = 0.06,
			Saturation = -0.03,
			TintColor = Color3.fromRGB(180, 195, 230),
		})

		return { clockTween = clockTween, colorCorrection = effect }
	end,

	disable = function(state)
		if state.clockTween then
			state.clockTween:Cancel()
		end

		TweenService:Create(
			Lighting,
			TweenInfo.new(3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
			{ ClockTime = WeatherConfig.BASE_CLOCK_TIME }
		):Play()

		if state.colorCorrection and state.colorCorrection.Parent then
			tweenToTransparent(state.colorCorrection)
		end
	end,
}

local function buildRainEmitter(parent: BasePart, intensity: number): ParticleEmitter
	local rain = Instance.new("ParticleEmitter")
	rain.Name = "WeatherRainDrops"
	rain.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	rain.LightEmission = 0.1
	rain.Color = ColorSequence.new(Color3.fromRGB(170, 195, 220))
	rain.Rate = intensity
	rain.Lifetime = NumberRange.new(0.6, 0.95)
	rain.Speed = NumberRange.new(45, 60)
	rain.SpreadAngle = Vector2.new(2, 2)
	rain.Acceleration = Vector3.new(0, -120, 0)
	rain.Rotation = NumberRange.new(0, 0)
	rain.EmissionDirection = Enum.NormalId.Bottom
	rain.Drag = 0.4
	rain.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.16),
		NumberSequenceKeypoint.new(1, 0.16),
	})
	rain.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(0.85, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	rain.Parent = parent
	return rain
end

-- Builds a part that hovers RAIN_LIFT studs above the local character and
-- follows the player via a Heartbeat connection so rain falls wherever they
-- stand, not just over the dig site floor.
local RAIN_VOLUME_SIZE = Vector3.new(80, 4, 80)
local RAIN_LIFT = 40

local function buildPlayerRainVolume(name: string): (BasePart, RBXScriptConnection)
	local volume = Instance.new("Part")
	volume.Name = name
	volume.Anchored = true
	volume.CanCollide = false
	volume.CanQuery = false
	volume.CanTouch = false
	volume.CastShadow = false
	volume.Massless = true
	volume.Transparency = 1
	volume.Size = RAIN_VOLUME_SIZE
	volume.Parent = Workspace

	local function updatePosition()
		local character = Players.LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			volume.Position = root.Position + Vector3.new(0, RAIN_LIFT, 0)
		end
	end

	updatePosition()
	local connection = RunService.Heartbeat:Connect(updatePosition)
	return volume, connection
end

handlers.Rain = {
	enable = function()
		local effect = makeColorCorrection("Weather_Rain_ColorCorrection", {
			Saturation = -0.04,
			Brightness = -0.03,
			TintColor = Color3.fromRGB(220, 230, 240),
		})

		local volume, connection = buildPlayerRainVolume("WeatherRainVolume")
		local emitter = buildRainEmitter(volume, 350)

		return { volume = volume, connection = connection, emitter = emitter, colorCorrection = effect }
	end,

	disable = function(state)
		if state.connection then
			state.connection:Disconnect()
		end
		if state.emitter then
			state.emitter.Rate = 0
		end
		if state.volume then
			task.delay(1, function()
				if state.volume and state.volume.Parent then
					state.volume:Destroy()
				end
			end)
		end
		if state.colorCorrection and state.colorCorrection.Parent then
			tweenToTransparent(state.colorCorrection)
		end
	end,
}

handlers.Fog = {
	enable = function()
		-- Capture and bump the live Atmosphere instance owned by
		-- EnvironmentService rather than parenting our own (only one Atmosphere
		-- can exist at a time in Lighting, so additive override is safest).
		local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
		local baselineDensity = if atmosphere then atmosphere.Density else nil
		local baselineHaze = if atmosphere then atmosphere.Haze else nil

		if atmosphere then
			TweenService:Create(atmosphere, FADE_IN, {
				Density = 0.55,
				Haze = 1.6,
			}):Play()
		end

		local effect = makeColorCorrection("Weather_Fog_ColorCorrection", {
			Brightness = -0.02,
			Saturation = -0.06,
			TintColor = Color3.fromRGB(220, 220, 230),
		})

		return {
			atmosphere = atmosphere,
			baselineDensity = baselineDensity,
			baselineHaze = baselineHaze,
			colorCorrection = effect,
		}
	end,

	disable = function(state)
		if state.atmosphere and state.baselineDensity ~= nil then
			TweenService:Create(state.atmosphere, FADE_OUT, {
				Density = state.baselineDensity,
				Haze = state.baselineHaze,
			}):Play()
		end
		if state.colorCorrection and state.colorCorrection.Parent then
			tweenToTransparent(state.colorCorrection)
		end
	end,
}

handlers.Storm = {
	enable = function()
		local effect = makeColorCorrection("Weather_Storm_ColorCorrection", {
			Brightness = -0.18,
			Contrast = 0.1,
			Saturation = -0.08,
			TintColor = Color3.fromRGB(170, 180, 210),
		})

		-- Periodic distant thunder. Cheap built-in asset; the random gap keeps
		-- it from feeling looped.
		local thunderActive = true
		task.spawn(function()
			while thunderActive do
				task.wait(math.random(8, 18))
				if not thunderActive then
					return
				end
				local thunder = Instance.new("Sound")
				thunder.Name = "WeatherStormThunder"
				thunder.SoundId = "rbxasset://sounds/snap.mp3"
				thunder.Volume = 0.35
				thunder.PlaybackSpeed = 0.55
				thunder.Parent = SoundService
				thunder:Play()
				thunder.Ended:Once(function()
					thunder:Destroy()
				end)
			end
		end)

		local volume, connection = buildPlayerRainVolume("WeatherStormVolume")
		local emitter = buildRainEmitter(volume, 900)

		local state: any = {
			colorCorrection = effect,
			volume = volume,
			connection = connection,
			emitter = emitter,
			stopThunder = function()
				thunderActive = false
			end,
		}

		return state
	end,

	disable = function(state)
		if state.stopThunder then
			state.stopThunder()
		end
		if state.connection then
			state.connection:Disconnect()
		end
		if state.emitter then
			state.emitter.Rate = 0
		end
		if state.volume then
			task.delay(1, function()
				if state.volume and state.volume.Parent then
					state.volume:Destroy()
				end
			end)
		end
		if state.colorCorrection and state.colorCorrection.Parent then
			tweenToTransparent(state.colorCorrection)
		end
	end,
}

handlers.Aurora = {
	enable = function()
		local effect = makeColorCorrection("Weather_Aurora_ColorCorrection", {
			Brightness = 0.05,
			Saturation = 0.4,
			TintColor = Color3.fromRGB(180, 255, 220),
		})

		-- Slow color cycle so the sky tint reads as a moving aurora rather
		-- than a static green wash.
		local cycleActive = true
		task.spawn(function()
			local palette = {
				Color3.fromRGB(180, 255, 220),
				Color3.fromRGB(200, 200, 255),
				Color3.fromRGB(255, 200, 240),
			}
			local index = 1
			while cycleActive do
				task.wait(4)
				if not cycleActive or not effect.Parent then
					return
				end
				index = (index % #palette) + 1
				TweenService:Create(effect, TweenInfo.new(4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
					TintColor = palette[index],
				}):Play()
			end
		end)

		local volume, auroraConnection = buildPlayerRainVolume("WeatherAuroraVolume")
		volume.Size = Vector3.new(80, 6, 80)
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "WeatherAuroraSparkles"
		emitter.LightEmission = 0.95
		emitter.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(180, 255, 220)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(220, 220, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 220, 240)),
		})
		emitter.Rate = 22
		emitter.Lifetime = NumberRange.new(2.6, 4.2)
		emitter.Speed = NumberRange.new(0.6, 1.4)
		emitter.SpreadAngle = Vector2.new(35, 35)
		emitter.Acceleration = Vector3.new(0, -1.0, 0)
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.RotSpeed = NumberRange.new(-30, 30)
		emitter.EmissionDirection = Enum.NormalId.Bottom
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.5),
			NumberSequenceKeypoint.new(0.5, 0.4),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.3),
			NumberSequenceKeypoint.new(0.7, 0.55),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Parent = volume

		return {
			colorCorrection = effect,
			volume = volume,
			connection = auroraConnection,
			emitter = emitter,
			stopCycle = function()
				cycleActive = false
			end,
		}
	end,

	disable = function(state)
		if state.stopCycle then
			state.stopCycle()
		end
		if state.connection then
			state.connection:Disconnect()
		end
		if state.emitter then
			state.emitter.Rate = 0
		end
		if state.volume then
			task.delay(1, function()
				if state.volume and state.volume.Parent then
					state.volume:Destroy()
				end
			end)
		end
		if state.colorCorrection and state.colorCorrection.Parent then
			tweenToTransparent(state.colorCorrection)
		end
	end,
}

-- Dispatch -----------------------------------------------------------------

local function activateEffect(id: WeatherConfig.WeatherId, expiresAt: number)
	local weather = WeatherConfig.EFFECTS[id]
	if not weather then
		return
	end

	if activeHandles[id] then
		-- Same effect re-fired (server marked a new occurrence). Tear down
		-- the old one before re-arming so visuals don't double up.
		local handler = handlers[id]
		if handler then
			handler.disable(activeHandles[id])
		end
		activeHandles[id] = nil
	end

	local handler = handlers[id]
	if handler then
		activeHandles[id] = handler.enable()
	end

	if trayUI then
		trayUI:show(id, expiresAt)
	end
end

local function deactivateEffect(id: WeatherConfig.WeatherId)
	local handler = handlers[id]
	local state = activeHandles[id]
	if handler and state then
		handler.disable(state)
	end
	activeHandles[id] = nil

	if trayUI then
		trayUI:hide(id)
	end
end

function WeatherController.start()
	if started then
		return
	end
	started = true

	trayUI = WeatherTrayUI.new()

	local startedRemote = RemoteRegistry.getRemote(DigConfig.WEATHER_REMOTE_FOLDER, DigConfig.WEATHER_STARTED_REMOTE)
	local endedRemote = RemoteRegistry.getRemote(DigConfig.WEATHER_REMOTE_FOLDER, DigConfig.WEATHER_ENDED_REMOTE)
	local syncRemote = RemoteRegistry.getRemote(DigConfig.WEATHER_REMOTE_FOLDER, DigConfig.WEATHER_SYNC_REMOTE)

	startedRemote.OnClientEvent:Connect(function(id: WeatherConfig.WeatherId, expiresAt: number)
		if typeof(id) ~= "string" or typeof(expiresAt) ~= "number" then
			return
		end
		activateEffect(id, expiresAt)
	end)

	endedRemote.OnClientEvent:Connect(function(id: WeatherConfig.WeatherId)
		if typeof(id) ~= "string" then
			return
		end
		deactivateEffect(id)
	end)

	syncRemote.OnClientEvent:Connect(function(snapshot)
		if typeof(snapshot) ~= "table" then
			return
		end

		-- Reconcile against snapshot: enable anything in snapshot that isn't
		-- live, leave anything already running alone (server will fire ended
		-- separately if it expired between sync request and reply).
		local seen: { [string]: boolean } = {}
		for _, entry in snapshot do
			if typeof(entry) == "table" and typeof(entry.id) == "string" then
				seen[entry.id] = true
				if not activeHandles[entry.id] then
					activateEffect(entry.id, entry.expiresAt or os.time())
				end
			end
		end

		for id in activeHandles do
			if not seen[id] then
				deactivateEffect(id)
			end
		end
	end)

	-- Ask the server for the current active set. Player_added on the server
	-- also fires sync as a fallback, but the client-driven request guarantees
	-- a fast hydrate even if the server's defer slipped a frame.
	syncRemote:FireServer()

	-- Defensive: if the local player respawned and we somehow lost the tray,
	-- the next sync rebuilds visuals from scratch (handlers are idempotent
	-- via the activeHandles guard above).
	Players.LocalPlayer.CharacterAdded:Connect(function()
		syncRemote:FireServer()
	end)
end

return WeatherController
