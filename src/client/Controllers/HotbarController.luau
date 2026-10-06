-- Manages the client-side hotbar:
--   • Mirrors server hotbar state via HotbarSync.
--   • Tracks the player's selected slot (1–5 keybinds + UI clicks).
--   • On PlacementPrompt: auto-fires a place request using the selected slot,
--     or shows "Please pull out a Brainrot!" if nothing is selected.
--   • Plays a shrink/dissolve animation when BrainrotDespawn fires.
--   • Shows toast notifications from HotbarNotification.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local DigConfig = require(ConfigFolder:WaitForChild("DigConfig"))
local EconomyConfig = require(ConfigFolder:WaitForChild("EconomyConfig"))
local BrainrotConfig = require(ConfigFolder:WaitForChild("BrainrotConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))
local VariantConfig = require(ConfigFolder:WaitForChild("VariantConfig"))

local BrainrotVariantEffects = require(UtilFolder:WaitForChild("BrainrotVariantEffects"))

local InventoryMoveService = require(script.Parent.Parent:WaitForChild("Services"):WaitForChild("InventoryMoveService"))
local InventorySlotCard = require(script.Parent.Parent:WaitForChild("Components"):WaitForChild("InventorySlotCard"))
local FormatUtil = require(UtilFolder:WaitForChild("FormatUtil"))

local HotbarController = {}

-- ─── remotes ─────────────────────────────────────────────────────────────────

local hotbarSyncRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.HOTBAR_SYNC_REMOTE)
local backpackSyncRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.BACKPACK_SYNC_REMOTE)
local hotbarNotificationRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.HOTBAR_NOTIFICATION_REMOTE)
local brainrotDespawnRemote = RemoteRegistry.getRemote(DigConfig.REMOTE_FOLDER, DigConfig.BRAINROT_DESPAWN_REMOTE)
local placementPromptRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.PLOT_PLACEMENT_PROMPT_REMOTE)
local pickupPromptRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.PLOT_PICKUP_PROMPT_REMOTE)
local placeRequestRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.PLOT_PLACE_REQUEST_REMOTE)
local pickupRequestRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.PLOT_PICKUP_REQUEST_REMOTE)

-- ─── state ───────────────────────────────────────────────────────────────────

local hotbar: { any } = {}
local selectedSlot: number? = nil
local heldTool: Tool? = nil
local hotbarFullBanner: Frame? = nil
local rebirths = 0
local backpackCount: number = 0

-- Per-slot references populated in buildHotbarUI. Each slot owns an
-- InventorySlotCard that draws the thumbnail, name, variant badge and price.
type SlotData = {
	frame: GuiObject,
	card: any,
}
local slots: { SlotData } = {}

-- ─── toast notifications ──────────────────────────────────────────────────────

local toastLabel: TextLabel? = nil
local toastTicket = 0

local function showToast(text: string)
	local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return end

	if not toastLabel then
		local gui = Instance.new("ScreenGui")
		gui.Name = "HotbarToastGui"
		gui.ResetOnSpawn = false
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.Parent = playerGui

		toastLabel = Instance.new("TextLabel")
		toastLabel.Name = "Toast"
		toastLabel.AnchorPoint = Vector2.new(0.5, 0)
		toastLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
		toastLabel.BackgroundTransparency = 0.2
		toastLabel.BorderSizePixel = 0
		toastLabel.Font = Enum.Font.GothamBold
		toastLabel.Position = UDim2.fromScale(0.5, 0.08)
		toastLabel.Size = UDim2.fromScale(0.38, 0.06)
		toastLabel.TextColor3 = Color3.new(1, 1, 1)
		toastLabel.TextScaled = true
		toastLabel.TextStrokeTransparency = 0.5
		toastLabel.Visible = false
		Instance.new("UICorner").Parent = toastLabel
		toastLabel.Parent = gui
	end

	toastTicket += 1
	local ticket = toastTicket
	toastLabel.Text = text
	toastLabel.Visible = true

	task.delay(2, function()
		if toastTicket == ticket and toastLabel then
			toastLabel.Visible = false
		end
	end)
end

-- ─── hotbar full banner ───────────────────────────────────────────────────────

local function isHotbarFull(): boolean
	local count = 0
	for i = 1, EconomyConfig.HOTBAR_SIZE do
		if hotbar[i] ~= nil then
			count += 1
		end
	end
	return count >= EconomyConfig.HOTBAR_SIZE
end

local function updateFullBanner()
	if not hotbarFullBanner then return end
	hotbarFullBanner.Visible = isHotbarFull() and backpackCount >= EconomyConfig.BACKPACK_SIZE
end

-- ─── UI helpers ───────────────────────────────────────────────────────────────

local function getRarityColor(item: any): Color3
	if not item or type(item.id) ~= "string" then
		return Color3.fromRGB(180, 180, 180)
	end
	local entry = BrainrotConfig.getById(item.id)
	return if entry then entry.color else Color3.fromRGB(180, 180, 180)
end

-- Returns the formatted display name for a hotbar item, e.g. "(Gold) Noobini Pizzanini".
local function getItemDisplayName(item: any): string
	if not item or type(item.id) ~= "string" then return "?" end
	local variantId = item.variantId
	local isNormal = (variantId == nil or variantId == VariantConfig.NORMAL_ID)
	if isNormal then
		return item.id
	end
	local ok, variantEntry = pcall(VariantConfig.getById, variantId)
	local variantName = (ok and variantEntry and variantEntry.displayName) or variantId
	return ("(%s) %s"):format(variantName, item.id)
end

-- ─── slot UI rebuild ──────────────────────────────────────────────────────────

local function rebuildSlot(slotIndex: number)
	local s = slots[slotIndex]
	if not s then return end

	local item = hotbar[slotIndex]

	-- Slot frame is only visible when occupied — this gives the dynamic
	-- "grows as you pick up brainrots" effect without empty placeholder slots.
	s.frame.Visible = (item ~= nil)

	s.card.render(item, { rebirths = rebirths, slotNumber = slotIndex })
	s.card.setSelected(slotIndex == selectedSlot, true)
end

local function rebuildAllSlots()
	for i = 1, #slots do
		rebuildSlot(i)
	end
	updateFullBanner()
end

-- ─── held brainrot tool ───────────────────────────────────────────────────────

local HELD_SCALE_HEIGHT = 5.0

local function destroyHeldTool()
	if heldTool then
		heldTool:Destroy()
		heldTool = nil
	end
end

local function findModelRootPart(model: Model): BasePart?
	for _, partName in { "RootPart", "FakeRootPart", "HumanoidRootPart" } do
		local found = model:FindFirstChild(partName, true)
		if found and found:IsA("BasePart") then
			return found :: BasePart
		end
	end
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	for _, desc in model:GetDescendants() do
		if desc:IsA("BasePart") then
			return desc :: BasePart
		end
	end
	return nil
end

-- Brainrot models are exported from Blender with a Ry(180°) baked into every
-- part, equivalent to EulerAnglesXYZ(-180, 0, -180). Motor6D C0/C1 offsets are
-- calibrated for that orientation, so we must keep it when positioning the model.
local HELD_MODEL_ROT = CFrame.Angles(0, math.pi, 0)

-- Creates a Roblox Tool that raises the character's arm (via the Animate
-- LocalScript) and renders the brainrot model at the hand each frame.
--
-- Key design: RootPart stays Anchored permanently. We set its CFrame on every
-- RenderStepped, which is guaranteed to fire before the frame is drawn.
-- Anchored parts are never touched by the physics solver, so gravity and
-- ToolGrip timing are completely irrelevant. The model's own built-in
-- WeldConstraints (FakeRootPart, VfxInstance → RootPart) and Motor6D joints
-- (mesh parts → FakeRootPart) propagate RootPart's CFrame to everything else.
local function createHeldTool(item: any): Tool?
	if not item or type(item.id) ~= "string" then return nil end

	local character = localPlayer.Character
	if not character then return nil end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return nil end

	local brainrotsFolder = ReplicatedStorage:FindFirstChild("Brainrots")
	local template = brainrotsFolder and brainrotsFolder:FindFirstChild(item.id)
	if not template then return nil end

	-- Arm-raise tool: the Animate LocalScript detects any Tool child of the
	-- character and plays the hold animation. The Handle is anchored so it
	-- never falls regardless of ToolGrip Motor6D state.
	local tool = Instance.new("Tool")
	tool.Name = "HeldBrainrot"
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	tool.Grip = CFrame.new(0, -HELD_SCALE_HEIGHT * 0.5, 0)
	tool:SetAttribute("BrainrotId", item.id)
	tool:SetAttribute("VariantId", item.variantId or "")

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.1, 0.1, 0.1)
	handle.Transparency = 1
	handle.CanCollide = false
	handle.CanTouch = false
	handle.Massless = true
	handle.Anchored = true
	handle.Parent = tool

	local visual = template:Clone()

	local toDestroy = {}
	for _, desc in visual:GetDescendants() do
		if desc:IsA("BillboardGui") or desc:IsA("ProximityPrompt") or desc:IsA("BaseScript") then
			table.insert(toDestroy, desc)
		end
	end
	for _, inst in toDestroy do
		inst:Destroy()
	end

	local statsTarget: BasePart? = nil

	if visual:IsA("Model") then
		local _, size = visual:GetBoundingBox()
		if size.Y > 0 then
			visual:ScaleTo(HELD_SCALE_HEIGHT * visual:GetScale() / size.Y)
		end

		local rootPart = findModelRootPart(visual)
		if not rootPart then
			visual:Destroy()
			tool:Destroy()
			return nil
		end

		visual.PrimaryPart = rootPart
		statsTarget = rootPart

		rootPart.Anchored = true  -- stays anchored; CFrame set by RenderStepped loop
		rootPart.CanCollide = false
		rootPart.CanTouch = false
		rootPart.Massless = true

		for _, desc in visual:GetDescendants() do
			if desc:IsA("BasePart") and desc ~= rootPart then
				desc.Anchored = false
				desc.CanCollide = false
				desc.CanTouch = false
				desc.Massless = true
			end
		end

		visual.Parent = tool

		if item.variantId then
			BrainrotVariantEffects.apply(visual, rootPart, item.variantId)
		end

		local rightHand = character:FindFirstChild("RightHand")
			or character:FindFirstChild("Right Arm")
		local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?

		if rightHand then
			local conn: RBXScriptConnection
			conn = RunService.RenderStepped:Connect(function()
				if not rootPart.Parent then
					conn:Disconnect()
					return
				end
				-- Place the model's root at the hand's world position.
				-- Apply the player's yaw so the brainrot faces the same
				-- direction as the character, then apply the Ry(180°) baked
				-- rotation that compensates for the Blender export convention.
				local yaw = if hrp then select(2, hrp.CFrame:ToEulerAnglesYXZ()) else 0
				rootPart.CFrame = CFrame.new(rightHand.Position) * CFrame.Angles(0, yaw, 0) * HELD_MODEL_ROT
			end)

			tool.Destroying:Connect(function()
				conn:Disconnect()
			end)
		end

	elseif visual:IsA("BasePart") then
		local maxDim = math.max(visual.Size.X, visual.Size.Y, visual.Size.Z)
		if maxDim > 0 then
			visual.Size = visual.Size * math.min(HELD_SCALE_HEIGHT / maxDim, 1)
		end
		visual.Anchored = false
		visual.CanCollide = false
		visual.CanTouch = false
		visual.Massless = true
		visual.CFrame = CFrame.new()
		statsTarget = visual
		visual.Parent = tool

		if item.variantId then
			BrainrotVariantEffects.apply(visual, visual, item.variantId)
		end

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = handle
		weld.Part1 = visual
		weld.Parent = handle

	else
		visual:Destroy()
		tool:Destroy()
		return nil
	end

	if statsTarget then
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "HeldBrainrotStats"
		billboard.Size = UDim2.new(0, 200, 0, 55)
		billboard.StudsOffset = Vector3.new(0, HELD_SCALE_HEIGHT + 1, 0)
		billboard.AlwaysOnTop = false
		billboard.Parent = statsTarget

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Size = UDim2.fromScale(1, 0.58)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Font = Enum.Font.GothamBold
		nameLabel.Text = getItemDisplayName(item)
		nameLabel.TextColor3 = getRarityColor(item)
		nameLabel.TextScaled = true
		nameLabel.TextStrokeTransparency = 0.35
		nameLabel.Parent = billboard

		local valueLabel = Instance.new("TextLabel")
		valueLabel.Position = UDim2.fromScale(0, 0.6)
		valueLabel.Size = UDim2.fromScale(1, 0.4)
		valueLabel.BackgroundTransparency = 1
		valueLabel.Font = Enum.Font.GothamBold
		local heldRate = EconomyConfig.computeEarningsRate(item.value or 0, EconomyConfig.getCashMultiplier(rebirths))
		valueLabel.Text = FormatUtil.money(heldRate) .. "/s"
		valueLabel.TextColor3 = Color3.fromRGB(100, 220, 100)
		valueLabel.TextScaled = true
		valueLabel.TextStrokeTransparency = 0.35
		valueLabel.Parent = billboard
	end

	-- Parent to character last so the Animate script raises the arm.
	tool.Parent = character
	return tool
end

-- ─── slot selection ───────────────────────────────────────────────────────────

local function setSelected(slot: number?)
	selectedSlot = slot
	destroyHeldTool()
	if slot then
		local item = hotbar[slot]
		if item then
			heldTool = createHeldTool(item)
		end
	end
	rebuildAllSlots()
end

local function toggleSelect(slot: number)
	setSelected(if selectedSlot == slot then nil else slot)
end

-- ─── despawn animation ────────────────────────────────────────────────────────

local function playDespawnAnimation(dropId: string, duration: number)
	local dropsFolder = Workspace:FindFirstChild("BrainrotDrops")
	if not dropsFolder then return end

	local model: Instance? = nil
	for _, child in dropsFolder:GetChildren() do
		if child:GetAttribute("DropId") == dropId then
			model = child
			break
		end
	end
	if not model then return end

	local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

	-- Fade every visible element inside each BillboardGui. The placard's row
	-- frames (e.g. EarningsRow in BrainrotPlacard) are plain Frames, so the
	-- old GroupTransparency tween threw — only CanvasGroup has that property.
	-- Walk the descendants instead and tween whichever transparency property
	-- each instance type actually exposes.
	for _, desc in model:GetDescendants() do
		if desc:IsA("BillboardGui") then
			for _, child in desc:GetDescendants() do
				if child:IsA("TextLabel") or child:IsA("TextButton") or child:IsA("TextBox") then
					TweenService:Create(child, tweenInfo, {
						TextTransparency = 1,
						TextStrokeTransparency = 1,
					}):Play()
				elseif child:IsA("ImageLabel") or child:IsA("ImageButton") then
					TweenService:Create(child, tweenInfo, {
						ImageTransparency = 1,
						BackgroundTransparency = 1,
					}):Play()
				elseif child:IsA("Frame") then
					if child.BackgroundTransparency < 1 then
						TweenService:Create(child, tweenInfo, { BackgroundTransparency = 1 }):Play()
					end
				elseif child:IsA("UIStroke") then
					TweenService:Create(child, tweenInfo, { Transparency = 1 }):Play()
				end
			end
		end
	end

	if model:IsA("Model") then
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				TweenService:Create(part, tweenInfo, {
					Size = Vector3.new(0.01, 0.01, 0.01),
					Transparency = 1,
				}):Play()
			end
		end
		local highlight = model:FindFirstChildWhichIsA("Highlight")
		if highlight then
			TweenService:Create(highlight, tweenInfo, {
				FillTransparency = 1,
				OutlineTransparency = 1,
			}):Play()
		end
	elseif model:IsA("BasePart") then
		TweenService:Create(model, tweenInfo, {
			Size = Vector3.new(0.01, 0.01, 0.01),
			Transparency = 1,
		}):Play()
	end
end

-- ─── placement flow ───────────────────────────────────────────────────────────

local function onPlacementPrompt(payload)
	if type(payload) ~= "table" then return end

	local padSlotIndex = tonumber(payload.slotIndex)
	if not padSlotIndex then return end

	if not selectedSlot then
		showToast("Please pull out a Brainrot!")
		return
	end

	local item = hotbar[selectedSlot]
	if not item then
		showToast("Please pull out a Brainrot!")
		setSelected(nil)
		return
	end

	placeRequestRemote:FireServer({
		slotIndex = padSlotIndex,
		hotbarSlot = selectedSlot,
	})

	setSelected(nil)
end

-- ─── pickup prompt (occupied pad) ────────────────────────────────────────────

local function onPickupPrompt(payload)
	if type(payload) ~= "table" then return end

	local slotIndex = payload.slotIndex
	local displayName = type(payload.displayName) == "string" and payload.displayName or "Brainrot"

	local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return end

	local hud = playerGui:FindFirstChild("HUD")
	local parent: Instance = hud or playerGui

	local overlay = Instance.new("Frame")
	overlay.Name = "PickupModal"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	overlay.BackgroundTransparency = 0.5
	overlay.ZIndex = 20
	overlay.Parent = parent

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromScale(0.68, 0.28)
	panel.BackgroundColor3 = Color3.fromRGB(22, 24, 38)
	panel.BorderSizePixel = 0
	panel.ZIndex = 21
	panel.Parent = overlay
	Instance.new("UICorner").Parent = panel

	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.fromScale(0.5, 0.08)
	label.Size = UDim2.fromScale(0.9, 0.5)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.Text = ("Pick up %s?"):format(displayName)
	label.TextColor3 = Color3.fromRGB(245, 245, 255)
	label.TextScaled = true
	label.TextWrapped = true
	label.ZIndex = 22
	label.Parent = panel

	local yesBtn = Instance.new("TextButton")
	yesBtn.AnchorPoint = Vector2.new(1, 1)
	yesBtn.Position = UDim2.fromScale(0.49, 0.94)
	yesBtn.Size = UDim2.fromScale(0.38, 0.3)
	yesBtn.BackgroundColor3 = Color3.fromRGB(80, 200, 120)
	yesBtn.Font = Enum.Font.GothamBlack
	yesBtn.Text = "Pick Up"
	yesBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	yesBtn.TextScaled = true
	yesBtn.ZIndex = 22
	yesBtn.Parent = panel
	Instance.new("UICorner").Parent = yesBtn

	local noBtn = Instance.new("TextButton")
	noBtn.AnchorPoint = Vector2.new(0, 1)
	noBtn.Position = UDim2.fromScale(0.51, 0.94)
	noBtn.Size = UDim2.fromScale(0.38, 0.3)
	noBtn.BackgroundColor3 = Color3.fromRGB(200, 70, 70)
	noBtn.Font = Enum.Font.GothamBlack
	noBtn.Text = "Cancel"
	noBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	noBtn.TextScaled = true
	noBtn.ZIndex = 22
	noBtn.Parent = panel
	Instance.new("UICorner").Parent = noBtn

	yesBtn.Activated:Connect(function()
		overlay:Destroy()
		pickupRequestRemote:FireServer({ slotIndex = slotIndex })
	end)
	noBtn.Activated:Connect(function()
		overlay:Destroy()
	end)
end

-- ─── keybinds ─────────────────────────────────────────────────────────────────

local SLOT_KEYCODES = {
	[Enum.KeyCode.One]   = 1,
	[Enum.KeyCode.Two]   = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four]  = 4,
	[Enum.KeyCode.Five]  = 5,
	[Enum.KeyCode.Six]   = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
}

local function bindKeybinds()
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		local slot = SLOT_KEYCODES[input.KeyCode]
		if slot and slot <= EconomyConfig.HOTBAR_SIZE then
			toggleSelect(slot)
		end
	end)
end

-- ─── build hotbar UI ─────────────────────────────────────────────────────────

local function buildHotbarUI(toolbarFrame: Frame)
	slots = {}

	-- Scale the toolbar up ~40% taller so the name + value text is readable.
	local sz = toolbarFrame.Size
	toolbarFrame.Size = UDim2.new(sz.X.Scale, sz.X.Offset, sz.Y.Scale, math.round(sz.Y.Offset * 1.4))

	-- Collect all children named "Item", sorted left→right by screen position.
	local items: { GuiObject } = {}
	for _, child in toolbarFrame:GetChildren() do
		if child.Name == "Item" and child:IsA("GuiObject") then
			table.insert(items, child)
		end
	end
	table.sort(items, function(a, b)
		return a.AbsolutePosition.X < b.AbsolutePosition.X
	end)

	-- Build up to HOTBAR_SIZE slots from the Item frames in the ToolBar.
	-- All slots start hidden; rebuildSlot makes each one visible only when occupied.
	local count = math.min(#items, EconomyConfig.HOTBAR_SIZE)

	for _, frame in items do
		frame.Visible = false
	end

	for i = 1, count do
		local frame = items[i]

		-- Build the polished slot card (thumbnail + name + variant badge + price).
		local card = InventorySlotCard.attach(frame, { showNumber = true })

		slots[i] = {
			frame = frame,
			card = card,
		}

		-- Tag the frame so InventoryMoveService can identify it as a hotbar slot on drop.
		frame:SetAttribute("HotbarSlotIndex", i)

		-- Wire drag + click.  InputBegan starts the potential drag via InventoryMoveService;
		-- if the mouse barely moves before release, the onClickFn fires toggleSelect instead.
		local slotIndex = i
		local inputTarget: GuiObject

		if frame:IsA("GuiButton") then
			inputTarget = frame
		else
			local clickBtn = Instance.new("TextButton")
			clickBtn.Name = "HotbarClickOverlay"
			clickBtn.Size = UDim2.fromScale(1, 1)
			clickBtn.BackgroundTransparency = 1
			clickBtn.Text = ""
			clickBtn.ZIndex = 100
			clickBtn.Parent = frame
			inputTarget = clickBtn
		end

		inputTarget.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1
				and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			local item = hotbar[slotIndex]
			if not item then return end
			InventoryMoveService.beginDrag(
				"hotbar",
				slotIndex,
				item,
				input.Position.X,
				input.Position.Y,
				function() toggleSelect(slotIndex) end
			)
		end)

		inputTarget.MouseEnter:Connect(function()
			InventoryMoveService.notifyHover("hotbar", slotIndex)
		end)
		inputTarget.MouseLeave:Connect(function()
			InventoryMoveService.clearHover("hotbar", slotIndex)
		end)
	end

	rebuildAllSlots()

	-- ── Hotbar Full banner ─────────────────────────────────────────────────
	-- Sits just above the toolbar, hidden until all slots are occupied.
	local banner = Instance.new("Frame")
	banner.Name = "HotbarFullBanner"
	banner.AnchorPoint = Vector2.new(0.5, 1)
	banner.Position = UDim2.new(0.5, 0, 0, -6)
	banner.Size = UDim2.new(0.65, 0, 0, 40)
	banner.BackgroundColor3 = Color3.fromRGB(210, 30, 30)
	banner.BackgroundTransparency = 0
	banner.BorderSizePixel = 0
	banner.ZIndex = 50
	banner.Visible = false
	local bannerCorner = Instance.new("UICorner")
	bannerCorner.CornerRadius = UDim.new(0.35, 0)
	bannerCorner.Parent = banner

	local bannerStroke = Instance.new("UIStroke")
	bannerStroke.Color = Color3.fromRGB(255, 100, 100)
	bannerStroke.Thickness = 2
	bannerStroke.Parent = banner

	local bannerLabel = Instance.new("TextLabel")
	bannerLabel.Size = UDim2.fromScale(1, 1)
	bannerLabel.BackgroundTransparency = 1
	bannerLabel.Font = Enum.Font.GothamBlack
	bannerLabel.Text = "INVENTORY FULL!"
	bannerLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	bannerLabel.TextScaled = true
	bannerLabel.TextStrokeTransparency = 0.4
	bannerLabel.ZIndex = 51
	bannerLabel.Parent = banner
	banner.Parent = toolbarFrame

	hotbarFullBanner = banner
	updateFullBanner()
end

-- ─── start ────────────────────────────────────────────────────────────────────

function HotbarController.getSelectedSlot(): number?
	return selectedSlot
end

function HotbarController.getHotbar(): { any }
	return hotbar
end

function HotbarController.start()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local hud = playerGui:WaitForChild("HUD")

	local toolbarFrame = hud:FindFirstChild("ToolBar") :: Frame?
	if toolbarFrame then
		-- Defer one frame so AbsolutePosition values are populated before sorting.
		task.defer(function()
			buildHotbarUI(toolbarFrame)
		end)
	else
		warn("[HotbarController] No 'ToolBar' frame found in HUD — hotbar UI will not render.")
	end

	bindKeybinds()

	local economySyncRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.ECONOMY_SYNC_REMOTE)
	economySyncRemote.OnClientEvent:Connect(function(payload)
		if type(payload) == "table" and payload.rebirths ~= nil then
			rebirths = tonumber(payload.rebirths) or rebirths
			rebuildAllSlots()
		end
	end)

	hotbarSyncRemote.OnClientEvent:Connect(function(newHotbar)
		if type(newHotbar) ~= "table" then return end
		hotbar = newHotbar
		if selectedSlot and not hotbar[selectedSlot] then
			selectedSlot = nil
			destroyHeldTool()
		end
		rebuildAllSlots()
	end)

	backpackSyncRemote.OnClientEvent:Connect(function(newBackpack)
		if type(newBackpack) ~= "table" then return end
		backpackCount = #newBackpack
		updateFullBanner()
	end)

	-- Request the current hotbar state now that the listener is connected.
	-- The initial server-side sync fires once when data loads and can arrive
	-- before this listener was registered, leaving the hotbar UI blank.
	local economySyncRequestRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.ECONOMY_SYNC_REQUEST_REMOTE)
	economySyncRequestRemote:FireServer()

	hotbarNotificationRemote.OnClientEvent:Connect(function(message)
		if type(message) == "string" then
			showToast(message)
		end
	end)

	brainrotDespawnRemote.OnClientEvent:Connect(function(dropId, duration)
		if type(dropId) == "string" then
			playDespawnAnimation(dropId, tonumber(duration) or DigConfig.DESPAWN_ANIM_DURATION)
		end
	end)

	placementPromptRemote.OnClientEvent:Connect(onPlacementPrompt)
	pickupPromptRemote.OnClientEvent:Connect(onPickupPrompt)

	-- When the character is removed (death/respawn), the tool is destroyed with
	-- it; clear the reference so we don't hold a dangling pointer.
	localPlayer.CharacterRemoving:Connect(function()
		heldTool = nil
	end)
end

return HotbarController
