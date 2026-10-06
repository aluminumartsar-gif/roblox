local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder   = Shared:WaitForChild("Util")

local DigSiteConfig   = require(ConfigFolder:WaitForChild("DigSiteConfig"))
local EconomyConfig   = require(ConfigFolder:WaitForChild("EconomyConfig"))
local RemoteRegistry        = require(UtilFolder:WaitForChild("RemoteRegistry"))
local FormatUtil            = require(UtilFolder:WaitForChild("FormatUtil"))
local WeatherSchedule       = require(UtilFolder:WaitForChild("WeatherSchedule"))
local BrainrotVisualFactory = require(UtilFolder:WaitForChild("BrainrotVisualFactory"))

local Components      = script.Parent.Parent:WaitForChild("Components")
local LuckCounterUI   = require(Components:WaitForChild("LuckCounterUI"))
local ThumbnailBounds = require(Components:WaitForChild("ThumbnailBounds"))
local RebirthRainVFX  = require(Components:WaitForChild("RebirthRainVFX"))

local UIKit      = script.Parent.Parent:WaitForChild("UIKit")
local Screen     = require(UIKit:WaitForChild("Screen"))
local GuiResolve = require(UIKit:WaitForChild("GuiResolve"))

local BRAINROTS_FOLDER = ReplicatedStorage:WaitForChild("Brainrots")
local THUMB_LOOK       = Vector3.new(-0.32, -0.14, -1).Unit
local THUMB_FOV        = 28
-- Slightly tighter than 1 so small brainrots fill more of the slot.
local THUMB_PAD        = 0.72

local RebirthController = {}

local localPlayer = Players.LocalPlayer
local LUCK_CHECK_INTERVAL = 0.15

-- ── Viewport helpers ──────────────────────────────────────────────────────────

local function sanitize(inst: Instance)
	if inst:IsA("BaseScript") or inst:IsA("ProximityPrompt") or inst:IsA("BillboardGui") then
		inst:Destroy()
		return
	end
	if inst:IsA("BasePart") then
		inst.Anchored   = true
		inst.CanCollide = false
		inst.CanTouch   = false
	end
end

local function populateSlotViewport(slot: ImageLabel, brainrotId: string)
	local clippingItems = slot:FindFirstChild("ClippingItems")
	if not clippingItems then return end

	local icon = clippingItems:FindFirstChild("Icon")
	if icon then icon:Destroy() end
	local existing = clippingItems:FindFirstChildOfClass("ViewportFrame")
	if existing then existing:Destroy() end

	local template = BRAINROTS_FOLDER:FindFirstChild(brainrotId)
	if not template then return end

	local vp              = Instance.new("ViewportFrame")
	vp.Name               = "Icon"
	vp.BackgroundTransparency = 1
	vp.AnchorPoint        = Vector2.new(0, 0)
	vp.Position           = UDim2.fromScale(0, 0)
	vp.Size               = UDim2.fromScale(1, 1)
	vp.LightColor         = Color3.fromRGB(255, 248, 240)
	vp.Ambient            = Color3.fromRGB(110, 112, 135)
	vp.ZIndex             = 1
	vp.Parent             = clippingItems

	local world = Instance.new("WorldModel")
	world.Parent = vp

	local clone = template:Clone()
	for _, d in clone:GetDescendants() do sanitize(d) end
	sanitize(clone)
	clone.Parent = world

	if clone:IsA("Model") then
		BrainrotVisualFactory.startIdle(clone)
	end

	local center, size = ThumbnailBounds.getVisibleBounds(clone)

	local cam = Instance.new("Camera")
	cam.FieldOfView = THUMB_FOV
	cam.Parent = vp

	local keyPart = Instance.new("Part")
	keyPart.Name = "RebirthThumbKeyLight"
	keyPart.Anchored = true
	keyPart.CanCollide = false
	keyPart.CanTouch = false
	keyPart.Transparency = 1
	keyPart.Size = Vector3.one
	keyPart.Parent = world

	local keyLight = Instance.new("PointLight")
	keyLight.Brightness = 5.5
	keyLight.Range = math.max(size.Magnitude * 5, 18)
	keyLight.Color = Color3.fromRGB(255, 245, 230)
	keyLight.Parent = keyPart

	local fillPart = Instance.new("Part")
	fillPart.Name = "RebirthThumbFillLight"
	fillPart.Anchored = true
	fillPart.CanCollide = false
	fillPart.CanTouch = false
	fillPart.Transparency = 1
	fillPart.Size = Vector3.one
	fillPart.Parent = world

	local fillLight = Instance.new("PointLight")
	fillLight.Brightness = 2
	fillLight.Range = math.max(size.Magnitude * 4, 14)
	fillLight.Color = Color3.fromRGB(190, 210, 255)
	fillLight.Parent = fillPart

	local function applyFraming()
		local vpSize = vp.AbsoluteSize
		if vpSize.X < 2 or vpSize.Y < 2 then
			return
		end
		local aspect = vpSize.X / vpSize.Y
		local dist = math.max(
			ThumbnailBounds.getFramingDistance(center, size, THUMB_LOOK, THUMB_FOV, aspect, THUMB_PAD),
			4
		)
		local offset = center - THUMB_LOOK * dist
		cam.CFrame = CFrame.new(offset, center)
		keyPart.CFrame = CFrame.new(center - THUMB_LOOK * (dist * 0.32), center)
		fillPart.CFrame = CFrame.new(center + THUMB_LOOK * (dist * 0.26), center)
	end

	applyFraming()
	task.defer(applyFraming)
	vp:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyFraming)

	vp.CurrentCamera = cam
end

local function getDigSite()
	return Workspace:FindFirstChild(DigSiteConfig.MODEL_NAME)
end

local function getActiveSpotsFolder()
	local digSite = getDigSite()
	return digSite and digSite:FindFirstChild(DigSiteConfig.ACTIVE_SPOTS_FOLDER_NAME)
end

local function getNearbyGroundSpotMultiplier(rootPosition: Vector3): number
	local activeSpotsFolder = getActiveSpotsFolder()
	if not activeSpotsFolder then return 1 end
	local best = 1
	for _, marker in activeSpotsFolder:GetChildren() do
		if marker:IsA("Model") and marker.Name == DigSiteConfig.GROUND_SPOT_MARKER_NAME then
			local position = marker:GetAttribute(DigSiteConfig.GROUND_SPOT_POSITION_ATTRIBUTE)
			if typeof(position) == "Vector3" then
				local delta = Vector3.new(rootPosition.X - position.X, 0, rootPosition.Z - position.Z)
				if delta.Magnitude <= DigSiteConfig.GROUND_SPOT_RADIUS then
					local luck = tonumber(marker:GetAttribute(DigSiteConfig.GROUND_SPOT_LUCK_ATTRIBUTE)) or 1
					if luck > best then best = luck end
				end
			end
		end
	end
	return best
end

local function getBonusLuckMultiplier(): number
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then return 1 end
	return getNearbyGroundSpotMultiplier(root.Position) * WeatherSchedule.getLuckMultiplier(os.time())
end

local function getContentTitles(content: Instance): { TextLabel }
	local titles: { TextLabel } = {}
	for _, child in content:GetChildren() do
		if child:IsA("TextLabel") and child.Name == "Title" then
			table.insert(titles, child)
		end
	end
	table.sort(titles, function(a: TextLabel, b: TextLabel)
		return a.LayoutOrder < b.LayoutOrder
	end)
	return titles
end

local function getContentItems(content: Instance): { ImageLabel }
	local items: { ImageLabel } = {}
	for _, child in content:GetChildren() do
		if child:IsA("ImageLabel") and child.Name == "Item" then
			table.insert(items, child)
		end
	end
	table.sort(items, function(a: ImageLabel, b: ImageLabel)
		return a.Position.X.Scale < b.Position.X.Scale
	end)
	return items
end

function RebirthController.start()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local screen    = playerGui:WaitForChild("Rebirth")
	local container = GuiResolve.waitChild(screen, "Container")
	if not container or not container:IsA("GuiObject") then return end
	local bg        = GuiResolve.waitChild(container, "Background")
	if not bg then return end
	local content   = GuiResolve.waitChild(bg, "Content")
	if not content then return end
	local sideButtons = playerGui:WaitForChild("HUD"):WaitForChild("SideButtons")
	local openBtn = GuiResolve.sideToggleOpenButton(sideButtons, "RebirthBtn")
	if not openBtn then return end
	local navBar    = GuiResolve.waitChild(bg, "NavBar")
	local closeBtn  = navBar and navBar:FindFirstChild("CloseBtn") :: GuiButton
	local claimBtn  = content:FindFirstChild("ClaimBtn") :: ImageButton

	Screen.bind({
		guiName    = "Rebirth",
		screen     = screen,
		container  = container,
		openButton = openBtn,
		closeButton = closeBtn,
	})

	local bar       = content:FindFirstChild("Bar")
	local insideBar = bar and bar:FindFirstChild("InsideBar") :: Frame

	local titles = getContentTitles(content)
	local infoTitle    = titles[1]
	local detailTitle  = titles[2]
	local rewardTitle  = titles[3]

	local itemSlots  = getContentItems(content)

	local economySyncRemote = RemoteRegistry.getRemote(
		EconomyConfig.REMOTE_FOLDER,
		EconomyConfig.ECONOMY_SYNC_REMOTE
	)
	local economySyncRequestRemote = RemoteRegistry.getRemote(
		EconomyConfig.REMOTE_FOLDER,
		EconomyConfig.ECONOMY_SYNC_REQUEST_REMOTE
	)
	local rebirthRequestRemote = RemoteRegistry.getRemote(
		EconomyConfig.REMOTE_FOLDER,
		EconomyConfig.REBIRTH_REQUEST_REMOTE
	)
	local rebirthResultRemote = RemoteRegistry.getRemote(
		EconomyConfig.REMOTE_FOLDER,
		EconomyConfig.REBIRTH_RESULT_REMOTE
	)

	local luckCounter = LuckCounterUI.new()
	local rebirthLuckMultiplier = 1
	local bonusLuckMultiplier   = 1
	local lastBonusCheck        = 0
	local canRebirth            = false
	local slotBrainrotIds: { [number]: string } = {}

	local function refreshLuckCounter()
		luckCounter:setLuckMultiplier(rebirthLuckMultiplier * bonusLuckMultiplier)
	end

	local function updateUI(snapshot)
		if type(snapshot) ~= "table" then return end
		local money       = snapshot.money or 0
		local cost        = math.max(1, snapshot.rebirthCost or 1)
		local rebirths    = snapshot.rebirths or 0
		local cashMult    = snapshot.cashMultiplier or 1
		local luckMult    = snapshot.luckMultiplier or 1
		local requirements = snapshot.rebirthRequirements or {}
		canRebirth        = snapshot.canRebirth == true

		rebirthLuckMultiplier = luckMult
		refreshLuckCounter()

		if insideBar then
			insideBar.Size = UDim2.fromScale(math.clamp(money / cost, 0, 1), 1)
		end

		if infoTitle then
			infoTitle.Text = ("Rebirth #%d"):format(rebirths + 1)
		end
		if detailTitle then
			detailTitle.Text = ("%s / %s"):format(FormatUtil.money(money), FormatUtil.money(cost))
		end
		if rewardTitle then
			rewardTitle.Text = ("Cash %s\nLuck %s"):format(
				FormatUtil.multiplier(cashMult),
				FormatUtil.multiplier(luckMult)
			)
		end
		if claimBtn then
			local claimTitle = claimBtn:FindFirstChild("Title") :: TextLabel?
			if claimTitle then
				claimTitle.Text = if canRebirth then "REBIRTH" else "NOT READY"
			end
		end

		local visibleSlots: { ImageLabel } = {}
		for i, slot in itemSlots do
			local req = requirements[i]
			slot.Visible = req ~= nil
			local slotTitle = slot:FindFirstChild("Title") :: TextLabel?
			if slotTitle then
				if req then
					slotTitle.Text = ("%s %d/%d"):format(req.id or "?", req.owned or 0, req.required or 1)
					slotTitle.TextColor3 = if req.met
						then Color3.fromRGB(80, 220, 120)
						else Color3.fromRGB(220, 80, 80)
					local brainrotId = req.id or ""
					if slotBrainrotIds[i] ~= brainrotId then
						slotBrainrotIds[i] = brainrotId
						populateSlotViewport(slot, brainrotId)
					end
					table.insert(visibleSlots, slot)
				else
					slotBrainrotIds[i] = nil
					slotTitle.Text = ""
				end
			end
		end

		-- Center visible slots horizontally
		local n = #visibleSlots
		if n > 0 then
			local ITEM_SPACING = 0.227
			local startX = 0.5 - (n - 1) * ITEM_SPACING / 2
			for idx, slot in visibleSlots do
				local x = startX + (idx - 1) * ITEM_SPACING
				slot.Position = UDim2.fromScale(x, slot.Position.Y.Scale)
			end
		end
	end

	if claimBtn then
		claimBtn.Activated:Connect(function()
			if canRebirth then
				rebirthRequestRemote:FireServer()
			end
		end)
	end

	economySyncRemote.OnClientEvent:Connect(updateUI)

	rebirthResultRemote.OnClientEvent:Connect(function(result)
		if type(result) ~= "table" then return end
		if result.success then
			RebirthRainVFX.play(playerGui)
		else
			local claimTitle = claimBtn and claimBtn:FindFirstChild("Title") :: TextLabel?
			if claimTitle then
				local original = claimTitle.Text
				claimTitle.Text = result.message or "Failed"
				task.delay(2, function()
					if claimTitle.Text == (result.message or "Failed") then
						claimTitle.Text = original
					end
				end)
			end
		end
	end)

	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now - lastBonusCheck < LUCK_CHECK_INTERVAL then return end
		lastBonusCheck = now
		local nextBonus = getBonusLuckMultiplier()
		if math.abs(nextBonus - bonusLuckMultiplier) < 0.001 then return end
		bonusLuckMultiplier = nextBonus
		refreshLuckCounter()
	end)

	economySyncRequestRemote:FireServer()
end

return RebirthController
