local ContentProvider = game:GetService("ContentProvider")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local IconAssets = require(ConfigFolder:WaitForChild("IconAssets"))
local FormatUtil = require(UtilFolder:WaitForChild("FormatUtil"))

local DigVFX = require(script.Parent:WaitForChild("DigVFX"))

local CashCollectVFX = {}

-- Layered SFX: a cash-register "kaching" plus a built-in chime so the burst
-- still lands even if the kaching upload is unavailable in this experience.
-- (Only Roblox-licensed audio publishers reliably play in third-party games;
-- see the matching note in DigVFX.) Both stay parented to SoundService for the
-- session so their buffers stay loaded across collects.
local CASH_SOUND_ID = "rbxassetid://7112275565"
local CHIME_SOUND_ID = "rbxasset://sounds/electronicpingshort.wav"

local CASH_GREEN = Color3.fromRGB(120, 235, 130)
local CASH_GREEN_DARK = Color3.fromRGB(46, 130, 64)
local CASH_GOLD = Color3.fromRGB(255, 232, 110)
local CASH_GOLD_DEEP = Color3.fromRGB(255, 175, 36)

local MIN_BILLS = 8
local MAX_BILLS = 22
local BILL_PART_SIZE = Vector3.new(1, 1, 1)
local BILL_BILLBOARD_SIZE = UDim2.fromScale(1.8, 1.1)
local AMOUNT_BILLBOARD_SIZE = UDim2.fromScale(7, 2.4)

local localPlayer = Players.LocalPlayer

local function preloadSounds(sounds: { Sound })
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(sounds)
		end)
	end)
end

local soundTemplates: { kaching: Sound, chime: Sound }
do
	local folder = SoundService:FindFirstChild("CashCollectSoundTemplates")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "CashCollectSoundTemplates"
		folder.Parent = SoundService
	end

	local kaching = Instance.new("Sound")
	kaching.Name = "CashKaChing"
	kaching.SoundId = CASH_SOUND_ID
	kaching.Volume = 0.85
	kaching.RollOffMaxDistance = 65
	kaching.Parent = folder

	local chime = Instance.new("Sound")
	chime.Name = "CashChime"
	chime.SoundId = CHIME_SOUND_ID
	chime.Volume = 0.75
	chime.RollOffMaxDistance = 55
	chime.Parent = folder

	soundTemplates = { kaching = kaching, chime = chime }
	preloadSounds({ kaching, chime })
end

local function makeAnchorPart(name: string, position: Vector3): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = BILL_PART_SIZE
	part.CFrame = CFrame.new(position)
	part.Parent = Workspace

	return part
end

local function playSoundAt(template: Sound, position: Vector3, pitch: number, volume: number?)
	local emitter = makeAnchorPart("CashSoundEmitter", position)

	local sound = template:Clone()
	sound.PlaybackSpeed = pitch
	if volume then
		sound.Volume = volume
	end
	sound.Parent = emitter
	sound:Play()

	-- Mirrors the DigVFX cleanup heuristic: TimeLength is only known once the
	-- buffer is loaded, so fall back to a generous floor that still lets the
	-- first-ever collect play through end-to-end.
	local lifetime = if sound.TimeLength > 0 then sound.TimeLength + 0.5 else 3
	Debris:AddItem(emitter, lifetime)
end

local function spawnCashBill(origin: Vector3)
	local part = makeAnchorPart("CashBillVFX", origin)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "CashBillboard"
	billboard.Size = BILL_BILLBOARD_SIZE
	billboard.AlwaysOnTop = false
	billboard.LightInfluence = 0
	billboard.MaxDistance = 200
	billboard.Parent = part

	local image = Instance.new("ImageLabel")
	image.Name = "Bill"
	image.BackgroundTransparency = 1
	image.Size = UDim2.fromScale(1, 1)
	image.Image = IconAssets.Cash
	-- Tint half the bills gold so the burst reads as cash + coins instead of a
	-- monochrome wall of green icons.
	image.ImageColor3 = if math.random() < 0.5 then CASH_GREEN else CASH_GOLD
	image.Parent = billboard

	local angle = math.random() * math.pi * 2
	local horizontalDistance = math.random(22, 60) / 10
	local verticalRise = math.random(18, 38) / 10
	local fallDepth = math.random(12, 26) / 10
	local horizontal = Vector3.new(math.cos(angle), 0, math.sin(angle)) * horizontalDistance

	local riseDuration = 0.32 + math.random() * 0.16
	local fallDuration = 0.55 + math.random() * 0.2

	local rise = TweenService:Create(part, TweenInfo.new(riseDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = CFrame.new(origin + horizontal * 0.55 + Vector3.new(0, verticalRise, 0)),
	})
	rise:Play()

	rise.Completed:Once(function()
		if not part.Parent then
			return
		end

		TweenService:Create(part, TweenInfo.new(fallDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			CFrame = CFrame.new(origin + horizontal + Vector3.new(0, -fallDepth, 0)),
		}):Play()

		TweenService:Create(image, TweenInfo.new(fallDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			ImageTransparency = 1,
		}):Play()
	end)

	Debris:AddItem(part, riseDuration + fallDuration + 0.25)
end

local function spawnAmountLabel(origin: Vector3, amount: number)
	local startPosition = origin + Vector3.new(0, 1.6, 0)
	local part = makeAnchorPart("CashAmountLabel", startPosition)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "CashAmountBillboard"
	billboard.Size = AMOUNT_BILLBOARD_SIZE
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = 220
	billboard.Parent = part

	local label = Instance.new("TextLabel")
	label.Name = "Amount"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.Text = ("+%s"):format(FormatUtil.money(amount))
	label.TextColor3 = CASH_GOLD
	label.TextStrokeColor3 = CASH_GREEN_DARK
	label.TextStrokeTransparency = 0
	label.TextScaled = true
	label.Parent = billboard

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = CASH_GOLD_DEEP
	stroke.Transparency = 0.1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Parent = label

	-- Pop in: the label briefly oversizes so the eye snaps to it before the
	-- bills steal the attention; UIScale animates instead of TextSize since
	-- the label uses TextScaled.
	local uiScale = Instance.new("UIScale")
	uiScale.Scale = 0.6
	uiScale.Parent = label

	local rise = 3.4
	local totalDuration = 1.05

	TweenService:Create(uiScale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1.1,
	}):Play()

	task.delay(0.18, function()
		if uiScale.Parent then
			TweenService:Create(uiScale, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Scale = 1,
			}):Play()
		end
	end)

	TweenService:Create(part, TweenInfo.new(totalDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = CFrame.new(startPosition + Vector3.new(0, rise, 0)),
	}):Play()

	task.delay(totalDuration * 0.45, function()
		if not label.Parent then
			return
		end

		local fadeInfo = TweenInfo.new(totalDuration * 0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(label, fadeInfo, {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		}):Play()
		TweenService:Create(stroke, fadeInfo, { Transparency = 1 }):Play()
	end)

	Debris:AddItem(part, totalDuration + 0.3)
end

local function getLocalRootPosition(): Vector3?
	local character = localPlayer.Character
	if not character then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end

	return nil
end

-- Resolves where the burst should originate. Server-supplied positions win so
-- the FX lines up with the collect pad the player actually walked on; if the
-- payload omits one (e.g. legacy callers), fall back to the local character so
-- the player still gets feedback at their feet rather than the world origin.
local function resolveOrigin(serverPosition: Vector3?): Vector3
	if typeof(serverPosition) == "Vector3" then
		return serverPosition + Vector3.new(0, 0.8, 0)
	end

	local rootPosition = getLocalRootPosition()
	if rootPosition then
		return rootPosition + Vector3.new(0, 1.5, 0)
	end

	return Vector3.new(0, 5, 0)
end

local function getBillCount(amount: number): number
	-- Scale bill density with the magnitude of the payout (log scale) so a
	-- $50 trickle still shows a few bills and a multi-million haul feels chunky
	-- without overflowing the scene with hundreds of icons.
	local magnitude = math.log10(math.max(amount, 1))
	local scaled = MIN_BILLS + math.floor(magnitude * 3)
	return math.clamp(scaled, MIN_BILLS, MAX_BILLS)
end

function CashCollectVFX.play(amount: number, serverPosition: Vector3?)
	if typeof(amount) ~= "number" or amount <= 0 then
		return
	end

	local origin = resolveOrigin(serverPosition)

	-- Ground impact ring + dust gives the burst a sense of weight before the
	-- bills launch. Reuses DigVFX helpers so we share the same look-and-feel
	-- as the dig/reveal feedback elsewhere.
	DigVFX.createFlatRing(origin, CASH_GOLD, 1.6, 6.5, 0.55, 0.1)
	DigVFX.createFlatRing(origin, CASH_GREEN, 0.8, 3.8, 0.4, 0.2)

	local billCount = getBillCount(amount)
	for _ = 1, billCount do
		spawnCashBill(origin)
	end

	spawnAmountLabel(origin, amount)

	playSoundAt(soundTemplates.kaching, origin, 0.96 + math.random(-4, 4) / 100, nil)
	playSoundAt(soundTemplates.chime, origin, 1.18 + math.random(-4, 4) / 100, nil)
end

return CashCollectVFX
