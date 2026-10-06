-- Client-side drag-and-drop manager for inventory / hotbar slot moves.
--
-- Controllers call InventoryMoveService.beginDrag() on InputBegan.
-- Drop detection uses MouseEnter / MouseLeave: each slot calls
-- InventoryMoveService.notifyHover / clearHover as the cursor enters/leaves it.
-- When the mouse button is released the current hover target is used as the
-- drop destination.
--
-- If the user releases before crossing the drag threshold the optional
-- `onClickFn` callback is invoked, allowing hotbar slots to equip on click.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder   = Shared:WaitForChild("Util")
local EconomyConfig  = require(ConfigFolder:WaitForChild("EconomyConfig"))
local BrainrotConfig = require(ConfigFolder:WaitForChild("BrainrotConfig"))
local VariantConfig  = require(ConfigFolder:WaitForChild("VariantConfig"))
local FormatUtil     = require(UtilFolder:WaitForChild("FormatUtil"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))

local InventoryMoveService = {}

-- ─── remotes ─────────────────────────────────────────────────────────────────

local inventoryMoveRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.INVENTORY_MOVE_REMOTE)

-- ─── economy state ────────────────────────────────────────────────────────────

local rebirths = 0
local economySyncRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.ECONOMY_SYNC_REMOTE)
economySyncRemote.OnClientEvent:Connect(function(payload)
	if type(payload) == "table" and payload.rebirths ~= nil then
		rebirths = tonumber(payload.rebirths) or rebirths
	end
end)

-- ─── constants ───────────────────────────────────────────────────────────────

local DRAG_THRESHOLD_SQ = 10 * 10
local GHOST_W = 130
local GHOST_H = 72

-- ─── hover state ─────────────────────────────────────────────────────────────

type HoverTarget = {
	sourceType : "hotbar" | "backpack",
	slot       : number,
}

local hoveredTarget: HoverTarget? = nil

-- Called by slot input targets on MouseEnter while a drag might be active.
function InventoryMoveService.notifyHover(sourceType: "hotbar" | "backpack", slot: number)
	hoveredTarget = { sourceType = sourceType, slot = slot }
end

-- Called by slot input targets on MouseLeave.
function InventoryMoveService.clearHover(sourceType: "hotbar" | "backpack", slot: number)
	local h = hoveredTarget
	if h and h.sourceType == sourceType and h.slot == slot then
		hoveredTarget = nil
	end
end

-- ─── drag state ──────────────────────────────────────────────────────────────

type ActiveDrag = {
	sourceType : "hotbar" | "backpack",
	sourceSlot : number,
	item       : any,
	startPos   : Vector2,
	hasDragged : boolean,
	onClickFn  : (() -> ())?,
	ghost      : ScreenGui?,
	conns      : { RBXScriptConnection },
}

local activeDrag: ActiveDrag? = nil

-- ─── helpers ─────────────────────────────────────────────────────────────────

local function getRarityColor(item: any): Color3
	if not item or type(item.id) ~= "string" then
		return Color3.fromRGB(180, 180, 180)
	end
	local entry = BrainrotConfig.getById(item.id)
	return if entry then entry.color else Color3.fromRGB(180, 180, 180)
end

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

-- ─── ghost ───────────────────────────────────────────────────────────────────

local function createGhost(item: any, posX: number, posY: number): ScreenGui
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name           = "InventoryDragGhost"
	gui.DisplayOrder   = 200
	gui.ResetOnSpawn   = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent         = playerGui

	local color = getRarityColor(item)

	local frame = Instance.new("Frame")
	frame.Name                   = "Ghost"
	frame.Size                   = UDim2.fromOffset(GHOST_W, GHOST_H)
	frame.AnchorPoint            = Vector2.new(0.5, 0.5)
	frame.Position               = UDim2.fromOffset(posX, posY)
	frame.BackgroundColor3       = Color3.fromRGB(24, 27, 43)
	frame.BackgroundTransparency = 0.05
	frame.BorderSizePixel        = 0
	frame.Rotation               = -4
	frame.ZIndex                 = 10
	frame.Parent                 = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.14, 0)
	corner.Parent       = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color     = color
	stroke.Thickness = 2.5
	stroke.Parent    = frame

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size                   = UDim2.new(1, -12, 0, 34)
	nameLabel.Position               = UDim2.fromOffset(6, 6)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font                   = Enum.Font.GothamBold
	nameLabel.Text                   = getItemDisplayName(item)
	nameLabel.TextColor3             = color
	nameLabel.TextScaled             = true
	nameLabel.TextWrapped            = true
	nameLabel.TextStrokeTransparency = 0.4
	nameLabel.ZIndex                 = 11
	nameLabel.Parent                 = frame

	local pricePill = Instance.new("Frame")
	pricePill.Name                   = "PricePill"
	pricePill.AnchorPoint            = Vector2.new(0.5, 1)
	pricePill.Position               = UDim2.new(0.5, 0, 1, -6)
	pricePill.Size                   = UDim2.new(1, -12, 0, 22)
	pricePill.BackgroundColor3       = Color3.fromRGB(52, 160, 86)
	pricePill.BorderSizePixel        = 0
	pricePill.ZIndex                 = 11
	pricePill.Parent                 = frame
	local pillCorner = Instance.new("UICorner")
	pillCorner.CornerRadius = UDim.new(0.5, 0)
	pillCorner.Parent       = pricePill

	local valueLabel = Instance.new("TextLabel")
	valueLabel.Size                   = UDim2.fromScale(0.9, 0.8)
	valueLabel.AnchorPoint            = Vector2.new(0.5, 0.5)
	valueLabel.Position               = UDim2.fromScale(0.5, 0.5)
	valueLabel.BackgroundTransparency = 1
	valueLabel.Font                   = Enum.Font.GothamBlack
	local rate = EconomyConfig.computeEarningsRate(item.value or 0, EconomyConfig.getCashMultiplier(rebirths))
	valueLabel.Text                   = FormatUtil.money(rate) .. "/s"
	valueLabel.TextColor3             = Color3.fromRGB(255, 255, 255)
	valueLabel.TextScaled             = true
	valueLabel.TextStrokeTransparency = 0.5
	valueLabel.ZIndex                 = 12
	valueLabel.Parent                 = pricePill

	return gui
end

local function setGhostPosition(gui: ScreenGui, x: number, y: number)
	local frame = gui:FindFirstChild("Ghost") :: Frame?
	if frame then
		frame.Position = UDim2.fromOffset(x, y)
	end
end

-- ─── drag lifecycle ──────────────────────────────────────────────────────────

local function cleanupDrag()
	local d = activeDrag
	if not d then return end
	activeDrag = nil
	for _, c in d.conns do c:Disconnect() end
	if d.ghost then d.ghost:Destroy() end
end

local function commitDrop()
	local d = activeDrag
	if not d then return end

	local src    = { sourceType = d.sourceType, sourceSlot = d.sourceSlot }
	local target = hoveredTarget
	cleanupDrag()

	if not target then return end
	if target.sourceType == src.sourceType and target.slot == src.sourceSlot then return end

	if src.sourceType == "backpack" and target.sourceType == "backpack" then
		inventoryMoveRemote:FireServer("swap_backpack", src.sourceSlot, target.slot)
	elseif src.sourceType == "hotbar" and target.sourceType == "hotbar" then
		inventoryMoveRemote:FireServer("swap_hotbar", src.sourceSlot, target.slot)
	elseif src.sourceType == "backpack" and target.sourceType == "hotbar" then
		inventoryMoveRemote:FireServer("backpack_to_hotbar", src.sourceSlot, target.slot)
	elseif src.sourceType == "hotbar" and target.sourceType == "backpack" then
		inventoryMoveRemote:FireServer("hotbar_to_backpack", src.sourceSlot, target.slot)
	end
end

-- ─── public API ──────────────────────────────────────────────────────────────

-- Begin tracking a potential drag from the given source slot.
-- `onClickFn` is called if the user releases without crossing the drag threshold.
function InventoryMoveService.beginDrag(
	sourceType : "hotbar" | "backpack",
	sourceSlot : number,
	item       : any,
	startX     : number,
	startY     : number,
	onClickFn  : (() -> ())?
)
	cleanupDrag()
	if not item then return end

	local conns: { RBXScriptConnection } = {}

	activeDrag = {
		sourceType = sourceType,
		sourceSlot = sourceSlot,
		item       = item,
		startPos   = Vector2.new(startX, startY),
		hasDragged = false,
		onClickFn  = onClickFn,
		ghost      = nil,
		conns      = conns,
	}

	table.insert(conns, UserInputService.InputChanged:Connect(function(input)
		local d = activeDrag
		if not d then return end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		local x = input.Position.X
		local y = input.Position.Y

		if not d.hasDragged then
			local dx = x - d.startPos.X
			local dy = y - d.startPos.Y
			if dx * dx + dy * dy >= DRAG_THRESHOLD_SQ then
				d.hasDragged = true
				d.ghost = createGhost(d.item, x, y)
			end
		elseif d.ghost then
			setGhostPosition(d.ghost, x, y)
		end
	end))

	table.insert(conns, UserInputService.InputEnded:Connect(function(input)
		local d = activeDrag
		if not d then return end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		if d.hasDragged then
			commitDrop()
		else
			local clickFn = d.onClickFn
			cleanupDrag()
			if clickFn then clickFn() end
		end
	end))

	table.insert(conns, UserInputService.WindowFocusReleased:Connect(cleanupDrag))
end

return InventoryMoveService
