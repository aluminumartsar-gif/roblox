local Lighting = game:GetService("Lighting")

local EnvironmentService = {}
local started = false

local function ensureChild(class: string, name: string?): Instance
	local target: Instance? = nil
	if name then
		target = Lighting:FindFirstChild(name)
		if target and target.ClassName ~= class then
			target:Destroy()
			target = nil
		end
	else
		target = Lighting:FindFirstChildOfClass(class)
	end

	if target then
		return target
	end

	local instance = Instance.new(class)
	if name then
		instance.Name = name
	end
	instance.Parent = Lighting
	return instance
end

local function applyLightingCore()
	Lighting.Ambient = Color3.fromRGB(100, 70, 130)
	Lighting.OutdoorAmbient = Color3.fromRGB(170, 150, 200)
	Lighting.Brightness = 2.6
	Lighting.ClockTime = 16.5
	Lighting.GeographicLatitude = 25
	Lighting.ColorShift_Top = Color3.fromRGB(255, 180, 100)
	Lighting.ColorShift_Bottom = Color3.fromRGB(90, 80, 220)
	Lighting.EnvironmentDiffuseScale = 1
	Lighting.EnvironmentSpecularScale = 1
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 0.35
	Lighting.FogStart = 600
	Lighting.FogEnd = 5000
	Lighting.FogColor = Color3.fromRGB(245, 200, 180)
end

local function applySky()
	local sky = ensureChild("Sky") :: Sky
	sky.SkyboxBk = "rbxassetid://6444884337"
	sky.SkyboxFt = "rbxassetid://6444884337"
	sky.SkyboxLf = "rbxassetid://6444884337"
	sky.SkyboxRt = "rbxassetid://6444884337"
	sky.SkyboxUp = "rbxassetid://6412503613"
	sky.SkyboxDn = "rbxassetid://6444884785"
	sky.SunAngularSize = 14
	sky.MoonAngularSize = 11
	sky.StarCount = 3000
	sky.CelestialBodiesShown = true
end

local function applyAtmosphere()
	local atmosphere = ensureChild("Atmosphere") :: Atmosphere
	atmosphere.Density = 0.19
	atmosphere.Offset = 0.15
	atmosphere.Color = Color3.fromRGB(200, 180, 255)
	atmosphere.Decay = Color3.fromRGB(180, 80, 60)
	atmosphere.Glare = 0.8
	atmosphere.Haze = 0.38
end

local function applyPostEffects()
	local bloom = ensureChild("BloomEffect") :: BloomEffect
	bloom.Enabled = true
	bloom.Intensity = 1.12
	bloom.Size = 26
	bloom.Threshold = 1.2

	local sunRays = ensureChild("SunRaysEffect") :: SunRaysEffect
	sunRays.Enabled = true
	sunRays.Intensity = 0.08
	sunRays.Spread = 0.85

	local depthOfField = ensureChild("DepthOfFieldEffect") :: DepthOfFieldEffect
	depthOfField.Enabled = false

	local colorCorrection = ensureChild("ColorCorrectionEffect") :: ColorCorrectionEffect
	colorCorrection.Enabled = true
	colorCorrection.Brightness = 0.05
	colorCorrection.Contrast = 0.18
	colorCorrection.Saturation = 0.60
	colorCorrection.TintColor = Color3.fromRGB(255, 240, 220)
end

function EnvironmentService.applyLighting()
	applyLightingCore()
	applySky()
	applyAtmosphere()
	applyPostEffects()
end

function EnvironmentService.start()
	if started then
		return
	end
	started = true

	EnvironmentService.applyLighting()
	print("[Environment] Lighting applied")
end

return EnvironmentService
