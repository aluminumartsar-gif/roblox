-- Manages the backpack overflow panel (HUD.Inventory).
-- Toggled open/closed by pressing B. Renders backpack items using the same
-- polished InventorySlotCard the hotbar uses (3D thumbnail + name + variant
-- badge + price pill), so the two inventories look identical.
--
-- Drag-and-drop: each slot fires InventoryMoveService.beginDrag on InputBegan
-- (mouse-down or touch-start). Releasing over another slot commits the move.
-- Drag onto a hotbar slot moves the item to that hotbar position; drag onto
-- another backpack slot swaps the two.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder   = Shared:WaitForChild("Util")
local EconomyConfig  = require(ConfigFolder:WaitForChild("EconomyConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))

local InventoryMoveService = require(script.Parent.Parent:WaitForChild("Services"):WaitForChild("InventoryMoveService"))
local InventorySlotCard = require(script.Parent.Parent:WaitForChild("Components"):WaitForChild("InventorySlotCard"))
local GuiResolve = require(script.Parent.Parent:WaitForChild("UIKit"):WaitForChild("GuiResolve"))

local BackpackController = {}

-- ─── remotes ─────────────────────────────────────────────────────────────────

local backpackSyncRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.BACKPACK_SYNC_REMOTE)

-- ─── state ───────────────────────────────────────────────────────────────────

local backpack: { any } = {}
local inventoryFrame: Frame? = nil
local scrollFrame: ScrollingFrame? = nil
local isOpen = false
local rebirths = 0

-- ─── slot builder ────────────────────────────────────────────────────────────

local function buildSlot(item: any, index: number): ImageButton
	local slot = Instance.new("ImageButton")
	slot.Name = "BackpackSlot"
	slot.LayoutOrder = index
	slot.BackgroundTransparency = 1
	slot.Image = ""
	slot.AutoButtonColor = false
	slot.AutomaticSize = Enum.AutomaticSize.None
	-- Tag so InventoryMoveService drop detection can identify this as a backpack slot.
	slot:SetAttribute("BackpackSlotIndex", index)

	-- Same polished card as the hotbar (thumbnail + name + variant badge + price),
	-- minus the keybind number badge.
	local card = InventorySlotCard.attach(slot, { showNumber = false })
	card.render(item, { rebirths = rebirths })

	-- The slot is itself a GuiButton, so it captures drag input directly.
	local slotIndex = index
	slot.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		InventoryMoveService.beginDrag(
			"backpack",
			slotIndex,
			item,
			input.Position.X,
			input.Position.Y
		)
	end)

	slot.MouseEnter:Connect(function()
		InventoryMoveService.notifyHover("backpack", slotIndex)
	end)
	slot.MouseLeave:Connect(function()
		InventoryMoveService.clearHover("backpack", slotIndex)
	end)

	return slot
end

-- ─── grid rebuild ─────────────────────────────────────────────────────────────

local function rebuildGrid()
	local sf = scrollFrame
	if not sf then return end

	for _, child in sf:GetChildren() do
		if child.Name == "BackpackSlot" or child.Name == "EmptyLabel" then
			child:Destroy()
		end
	end

	if #backpack == 0 then
		local lbl = Instance.new("TextLabel")
		lbl.Name = "EmptyLabel"
		lbl.Size = UDim2.fromScale(1, 0.08)
		lbl.BackgroundTransparency = 1
		lbl.Font = Enum.Font.GothamBold
		lbl.Text = "Backpack is empty"
		lbl.TextColor3 = Color3.fromRGB(160, 160, 180)
		lbl.TextScaled = true
		lbl.Parent = sf
		return
	end

	for i, item in backpack do
		buildSlot(item, i).Parent = sf
	end

	local layout = sf:FindFirstChildOfClass("UIGridLayout")
	if layout then
		sf.CanvasSize = UDim2.fromOffset(0, layout.AbsoluteContentSize.Y + 16)
	end
end

-- ─── open / close ────────────────────────────────────────────────────────────

local function setOpen(open: boolean)
	isOpen = open
	if inventoryFrame then
		inventoryFrame.Visible = open
	end
	if open then
		rebuildGrid()
	end
end

local function toggle()
	setOpen(not isOpen)
end

-- ─── start ────────────────────────────────────────────────────────────────────

function BackpackController.start()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local hud       = playerGui:WaitForChild("HUD")

	-- Cell sizing keys off the hotbar's slot width so the backpack grid matches it.
	local toolBar = hud:FindFirstChild("ToolBar")

	local screen  = hud:WaitForChild("Inventory") :: Frame
	local bg      = GuiResolve.waitChild(screen, "Background")
	local content = bg and GuiResolve.waitChild(bg, "Content")
	local sf      = content and GuiResolve.waitChild(content, "ScrollingFrame") :: ScrollingFrame
	if not bg or not content or not sf then
		warn("[Backpack] Expected HUD > Inventory > Background > Content > ScrollingFrame. Backpack disabled.")
		return
	end

	inventoryFrame = screen
	scrollFrame    = sf

	screen.Visible = false

	for _, child in sf:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	local existingList = sf:FindFirstChildOfClass("UIListLayout")
	if existingList then existingList:Destroy() end

	local grid = Instance.new("UIGridLayout")
	grid.CellPadding = UDim2.new(0.01, 0, 0.01, 0)
	grid.SortOrder   = Enum.SortOrder.LayoutOrder
	grid.Parent      = sf

	local padding = sf:FindFirstChildOfClass("UIPadding")
	if not padding then
		padding = Instance.new("UIPadding")
		padding.PaddingTop   = UDim.new(0.01, 0)
		padding.PaddingLeft  = UDim.new(0.01, 0)
		padding.PaddingRight = UDim.new(0.01, 0)
		padding.Parent       = sf
	end

	local function hotbarSlotSize(): number
		if toolBar and toolBar.AbsoluteSize.X > 0 then
			return math.max(30, math.floor(toolBar.AbsoluteSize.X / 9))
		end
		return math.max(30, math.floor(math.max(1, sf.AbsoluteSize.X - 42) / 5))
	end

	local function refreshCellSize()
		local cellSize = hotbarSlotSize()
		grid.CellSize = UDim2.fromOffset(cellSize, cellSize)
		sf.CanvasSize = UDim2.fromOffset(0, grid.AbsoluteContentSize.Y + 16)
	end

	sf:GetPropertyChangedSignal("AbsoluteSize"):Connect(refreshCellSize)
	if toolBar then
		toolBar:GetPropertyChangedSignal("AbsoluteSize"):Connect(refreshCellSize)
	end
	grid:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		sf.CanvasSize = UDim2.fromOffset(0, grid.AbsoluteContentSize.Y + 16)
	end)
	task.defer(refreshCellSize)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.KeyCode == Enum.KeyCode.B then
			toggle()
		end
	end)

	if toolBar then
		local bagBtn = toolBar:FindFirstChild("BagBtn")
		if bagBtn then
			local clickable = bagBtn:FindFirstChildWhichIsA("GuiButton") or bagBtn
			if clickable:IsA("GuiButton") then
				(clickable :: GuiButton).Activated:Connect(toggle)
			end
		end
	end

	local sideButtons = hud:FindFirstChild("SideButtons")
	if sideButtons then
		local btn = sideButtons:FindFirstChild("BackpackBtn")
		if btn then
			local clickable = btn:FindFirstChild("Container")
				or btn:FindFirstChildWhichIsA("GuiButton")
			if clickable and clickable:IsA("GuiButton") then
				(clickable :: GuiButton).Activated:Connect(toggle)
			elseif btn:IsA("GuiButton") then
				(btn :: GuiButton).Activated:Connect(toggle)
			end
		end
	end

	backpackSyncRemote.OnClientEvent:Connect(function(newBackpack)
		if type(newBackpack) ~= "table" then return end
		backpack = newBackpack
		if isOpen then
			rebuildGrid()
		end
	end)

	local economySyncRemote = RemoteRegistry.getRemote(EconomyConfig.REMOTE_FOLDER, EconomyConfig.ECONOMY_SYNC_REMOTE)
	economySyncRemote.OnClientEvent:Connect(function(payload)
		if type(payload) == "table" and payload.rebirths ~= nil then
			rebirths = tonumber(payload.rebirths) or rebirths
			if isOpen then
				rebuildGrid()
			end
		end
	end)
end

function BackpackController.getBackpack(): { any }
	return backpack
end

return BackpackController
