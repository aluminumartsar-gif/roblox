--!strict
--[[
	HotbarController
	StarterPlayerScripts/Client/Controllers/HotbarController

	Our own tool hotbar in the campfire field kit look, replacing Roblox's
	backpack bar. Bottom centre of the screen, under the cash block
	(Config.UI.Layout.HotbarBottom / HotbarSlot, scaled with the screen):

	  * one slot per tool: everything in the Backpack plus the one in hand
	    (in the Character)
	  * stable order: the tool names in Config.UI.Hotbar.ToolOrder first
	    (the Bat, then the Field Camera), then any others by name
	  * each slot shows its key number and an icon: Config.UI.Hotbar.ToolIcons
	    (BaseballBat, Camera), else the tool's own TextureId, else its initials
	  * keys 1..9 and a click / tap toggle that tool (Humanoid:EquipTool /
	    UnequipTools); gamepad shoulder buttons (Config.UI.Hotbar
	    GamepadPrevious / GamepadNext) cycle through them
	  * the tool in hand has an ember edge and sits slightly larger
	  * number keys are left alone while typing (a focused TextBox, chat, or
	    anything else that already handled the key)
	  * respawns (new Character and Backpack), tools given or taken, and
	    death (the bar hides until the next spawn) are all followed

	CodexController watches the Field Camera's Equipped / Unequipped itself;
	equipping through Humanoid:EquipTool fires those exactly like Roblox's
	backpack did.

	Config.UI.CustomHotbar = false leaves Roblox's backpack completely
	untouched (this controller does nothing). When true, Roblox's backpack is
	turned off with StarterGui:SetCoreGuiEnabled, retried because it can
	refuse in the first moments of a session.

	Tunables: Config.UI.Hotbar, Config.UI.Layout.HotbarBottom / HotbarSlot.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Components = script.Parent.Parent:WaitForChild("Components")
local Theme = require(Components:WaitForChild("Theme"))
local UI = require(Components:WaitForChild("UI"))

local HotbarController = {}

local localPlayer = Players.LocalPlayer

local C = Theme.Colors
local T = Theme.Tuning
local H = Config.UI.Hotbar
local L = Config.UI.Layout

-- A tool's own TextureId image is shown in its own colours: no tint.
local NO_TINT = Color3.new(1, 1, 1)
-- Slot number sits in the top-left corner, this far in.
local KEY_OFFSET = UDim2.fromOffset(5, 2)
-- A tool with no icon shows up to this many initials ("Field Camera" -> "FC").
local MAX_INITIALS = 2

-- Number row keys, in slot order.
local NUMBER_KEYS: { Enum.KeyCode } = {
	Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three,
	Enum.KeyCode.Four, Enum.KeyCode.Five, Enum.KeyCode.Six,
	Enum.KeyCode.Seven, Enum.KeyCode.Eight, Enum.KeyCode.Nine,
}
local KEY_TO_INDEX: { [Enum.KeyCode]: number } = {}
for index, keyCode in ipairs(NUMBER_KEYS) do
	KEY_TO_INDEX[keyCode] = index
end

type Slot = {
	tool: Tool,
	button: TextButton,
	edge: UIStroke,
	fill: UIGradient,
	scale: UIScale,
	number: TextLabel,
	tooltip: Frame,
	equipped: boolean,
	hovering: boolean,
	connections: { RBXScriptConnection },
}

local bar: Frame? = nil
local slots: { [Tool]: Slot } = {}
local order: { Tool } = {}           -- tools in slot order (index = key number)
local firstSeen: { [Tool]: number } = {}
local seenCount = 0

local backpack: Instance? = nil
local character: Model? = nil
local humanoid: Humanoid? = nil
local backpackConnections: { RBXScriptConnection } = {}
local characterConnections: { RBXScriptConnection } = {}
local humanoidConnections: { RBXScriptConnection } = {}

local refreshQueued = false

local function disconnectAll(list: { RBXScriptConnection })
	for _, connection in ipairs(list) do
		connection:Disconnect()
	end
	table.clear(list)
end

local function alive(): boolean
	local h = humanoid
	return h ~= nil and h.Parent ~= nil and h.Health > 0 and h:GetState() ~= Enum.HumanoidStateType.Dead
end

--------------------------------------------------------------------------
-- Equip
--------------------------------------------------------------------------

--- Equips the tool, or puts it away if it's already in hand.
local function toggle(tool: Tool)
	local h = humanoid
	local char = character
	if not h or not char or not alive() then
		return
	end
	if tool.Parent == char then
		h:UnequipTools()
	elseif backpack and tool.Parent == backpack then
		h:EquipTool(tool)
	end
end

local function toggleIndex(index: number)
	local tool = order[index]
	if tool then
		toggle(tool)
	end
end

--- Gamepad: equip the next / previous slot; stepping past either end puts
--- the tool away.
local function cycle(direction: number)
	local count = #order
	if count == 0 then
		return
	end
	local current = 0
	for index, tool in ipairs(order) do
		if character and tool.Parent == character then
			current = index
			break
		end
	end
	local nextIndex
	if current == 0 then
		nextIndex = if direction > 0 then 1 else count
	else
		nextIndex = current + direction
		if nextIndex < 1 or nextIndex > count then
			-- Past either end: empty hands, like Roblox's own backpack.
			local h = humanoid
			if h and alive() then
				h:UnequipTools()
			end
			return
		end
	end
	local tool = order[nextIndex]
	if tool and tool.Parent ~= character then
		toggle(tool)
	end
end

--------------------------------------------------------------------------
-- Slots
--------------------------------------------------------------------------

local function initials(name: string): string
	local letters = ""
	for word in string.gmatch(name, "%w+") do
		letters ..= string.sub(word, 1, 1)
		if #letters >= MAX_INITIALS then
			break
		end
	end
	if letters == "" then
		letters = string.sub(name, 1, 1)
	end
	return string.upper(letters)
end

local function paint(slot: Slot)
	if slot.equipped then
		slot.edge.Color = C.Ember
		slot.edge.Thickness = H.EquippedEdge
		slot.fill.Color = Theme.Sequence(Theme.Mix(C.RaisedTop, C.Ember, H.EquippedGlow), C.Panel)
		slot.number.TextColor3 = C.EmberBright
	else
		slot.edge.Color = if slot.hovering then C.EdgeBright else C.Edge
		slot.edge.Thickness = H.EdgeThickness
		slot.fill.Color = Theme.Sequence(C.RaisedTop, C.Panel)
		slot.number.TextColor3 = C.TextDim
	end
end

local function restScale(slot: Slot): number
	return if slot.equipped then H.EquippedScale else 1
end

local function buildSlot(tool: Tool, parent: Instance): Slot
	local size = L.HotbarSlot
	local button = UI.new("TextButton", {
		Name = "Slot",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = NO_TINT,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(size, size),
		Parent = parent,
	}) :: TextButton
	UI.Corner(T.Corner).Parent = button
	local fill = UI.Gradient(Theme.Sequence(C.RaisedTop, C.Panel), 90) :: UIGradient
	fill.Parent = button
	local edge = UI.Stroke({ Name = "Edge", Color = C.Edge, Thickness = H.EdgeThickness, Parent = button }) :: UIStroke
	local scale = UI.new("UIScale", { Name = "Press", Parent = button }) :: UIScale

	-- Icon: our glyph for known tools, else the tool's own image, else initials.
	local iconName = H.ToolIcons[tool.Name]
	if iconName then
		UI.Icon(iconName, H.IconSize, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.55),
			ImageColor3 = C.Text,
			Parent = button,
		})
	elseif tool.TextureId ~= "" then
		UI.new("ImageLabel", {
			Name = "Icon",
			BackgroundTransparency = 1,
			Image = tool.TextureId,
			ImageColor3 = NO_TINT,
			ScaleType = Enum.ScaleType.Fit,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.55),
			Size = UDim2.fromOffset(H.IconSize, H.IconSize),
			Parent = button,
		})
	else
		UI.Text({
			Name = "Initials",
			Role = "Heading",
			Weight = "Bold",
			RichText = false,
			Text = initials(tool.Name),
			TextSize = H.InitialsTextSize,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.55),
			Size = UDim2.fromOffset(size, H.InitialsTextSize + 4),
			Parent = button,
		})
	end

	local number = UI.Text({
		Name = "Key",
		Role = "Heading",
		Weight = "Bold",
		RichText = false,
		Text = "",
		TextSize = H.KeyTextSize,
		TextColor3 = C.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = KEY_OFFSET,
		Size = UDim2.fromOffset(H.KeyTextSize, H.KeyTextSize + 2),
		Parent = button,
	})

	-- Mouse hover: the tool's ToolTip on a small plate above the slot
	-- (Roblox's backpack did the same).
	local tooltip = UI.new("Frame", {
		Name = "Tooltip",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0, -H.TooltipGap),
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 5,
		Parent = button,
	}, {
		UI.Corner(T.CornerSmall),
		UI.Stroke({ Color = C.Edge }),
		UI.Padding({ Top = 4, Bottom = 4, Left = 8, Right = 8 }),
	}) :: Frame
	local tooltipText = UI.Text({
		Name = "Label",
		Role = "Body",
		RichText = false,
		Text = tool.ToolTip,
		TextSize = H.TooltipTextSize,
		TextWrapped = true,
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		ZIndex = 6,
		Parent = tooltip,
	})
	UI.new("UISizeConstraint", { MaxSize = Vector2.new(H.TooltipMaxWidth, math.huge), Parent = tooltipText })

	local slot: Slot = {
		tool = tool,
		button = button,
		edge = edge,
		fill = fill,
		scale = scale,
		number = number,
		tooltip = tooltip,
		equipped = false,
		hovering = false,
		connections = {},
	}

	-- Hover / press feel (same timings as UI.Button).
	table.insert(slot.connections, button.MouseEnter:Connect(function()
		slot.hovering = true
		tooltip.Visible = tool.ToolTip ~= ""
		paint(slot)
	end))
	table.insert(slot.connections, button.MouseLeave:Connect(function()
		slot.hovering = false
		tooltip.Visible = false
		paint(slot)
		UI.Tween(scale, T.HoverTime, { Scale = restScale(slot) })
	end))
	table.insert(slot.connections, button.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			UI.Tween(scale, T.HoverTime * 0.6, { Scale = restScale(slot) * T.ButtonPressScale })
		end
	end))
	table.insert(slot.connections, button.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			UI.Tween(scale, T.HoverTime, { Scale = restScale(slot) }, Enum.EasingStyle.Back)
		end
	end))
	table.insert(slot.connections, button.Activated:Connect(function()
		toggle(tool)
	end))
	table.insert(slot.connections, tool:GetPropertyChangedSignal("ToolTip"):Connect(function()
		tooltipText.Text = tool.ToolTip
		if tool.ToolTip == "" then
			tooltip.Visible = false
		end
	end))

	paint(slot)
	return slot
end

local function removeSlot(slot: Slot)
	disconnectAll(slot.connections)
	slot.button:Destroy()
end

local function setEquipped(slot: Slot, equipped: boolean)
	if slot.equipped == equipped then
		return
	end
	slot.equipped = equipped
	paint(slot)
	UI.Tween(slot.scale, T.HoverTime, { Scale = restScale(slot) }, Enum.EasingStyle.Back)
end

--------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------

local function rank(tool: Tool): number
	for index, name in ipairs(H.ToolOrder) do
		if tool.Name == name then
			return index
		end
	end
	return #H.ToolOrder + 1
end

local function collectTools(): { Tool }
	local list: { Tool } = {}
	local function add(container: Instance?)
		if not container then
			return
		end
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") and not table.find(list, child) then
				table.insert(list, child)
				if not firstSeen[child] then
					seenCount += 1
					firstSeen[child] = seenCount
				end
			end
		end
	end
	add(backpack)
	add(character)
	table.sort(list, function(a: Tool, b: Tool): boolean
		local rankA, rankB = rank(a), rank(b)
		if rankA ~= rankB then
			return rankA < rankB
		end
		if a.Name ~= b.Name then
			return a.Name < b.Name
		end
		return firstSeen[a] < firstSeen[b]
	end)
	return list
end

local function refresh()
	local frame = bar
	if not frame then
		return
	end
	local tools = collectTools()
	while #tools > H.MaxSlots do
		table.remove(tools)
	end

	local keep: { [Tool]: boolean } = {}
	for _, tool in ipairs(tools) do
		keep[tool] = true
	end
	for tool, slot in pairs(slots) do
		if not keep[tool] then
			removeSlot(slot)
			slots[tool] = nil
		end
	end
	for tool in pairs(firstSeen) do
		if not tool.Parent then
			firstSeen[tool] = nil
		end
	end

	for index, tool in ipairs(tools) do
		local slot = slots[tool]
		if not slot then
			slot = buildSlot(tool, frame)
			slots[tool] = slot
		end
		slot.button.LayoutOrder = index
		slot.button.Name = "Slot" .. index
		slot.number.Text = tostring(index)
		setEquipped(slot, character ~= nil and tool.Parent == character)
	end
	order = tools

	frame.Visible = #tools > 0 and alive()
end

local function scheduleRefresh()
	if refreshQueued then
		return
	end
	refreshQueued = true
	-- Coalesce: equipping moves a tool out of the Backpack and into the
	-- Character in two events; redraw once after both.
	task.defer(function()
		refreshQueued = false
		refresh()
	end)
end

--------------------------------------------------------------------------
-- Backpack, character and humanoid
--------------------------------------------------------------------------

local function onToolMoved(child: Instance)
	if child:IsA("Tool") then
		scheduleRefresh()
	end
end

local function watchBackpack(container: Instance)
	disconnectAll(backpackConnections)
	backpack = container
	table.insert(backpackConnections, container.ChildAdded:Connect(onToolMoved))
	table.insert(backpackConnections, container.ChildRemoved:Connect(onToolMoved))
	table.insert(backpackConnections, container.AncestryChanged:Connect(function()
		if container.Parent == nil and backpack == container then
			disconnectAll(backpackConnections)
			backpack = nil
			scheduleRefresh()
		end
	end))
	scheduleRefresh()
end

local function watchHumanoid(h: Humanoid)
	disconnectAll(humanoidConnections)
	humanoid = h
	table.insert(humanoidConnections, h.Died:Connect(scheduleRefresh))
	table.insert(humanoidConnections, h.HealthChanged:Connect(function(health: number)
		if health <= 0 then
			scheduleRefresh()
		end
	end))
	scheduleRefresh()
end

local function watchCharacter(model: Model)
	disconnectAll(characterConnections)
	disconnectAll(humanoidConnections)
	character = model
	humanoid = nil
	table.insert(characterConnections, model.ChildAdded:Connect(function(child: Instance)
		if child:IsA("Humanoid") then
			watchHumanoid(child)
		else
			onToolMoved(child)
		end
	end))
	table.insert(characterConnections, model.ChildRemoved:Connect(onToolMoved))
	local h = model:FindFirstChildOfClass("Humanoid")
	if h then
		watchHumanoid(h)
	end
	scheduleRefresh()
end

local function forgetCharacter()
	disconnectAll(characterConnections)
	disconnectAll(humanoidConnections)
	character = nil
	humanoid = nil
	scheduleRefresh()
end

--------------------------------------------------------------------------
-- Roblox's backpack
--------------------------------------------------------------------------

local function hideCoreBackpack()
	task.spawn(function()
		for _ = 1, H.CoreGuiRetries do
			local ok = pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
			end)
			if ok and not StarterGui:GetCoreGuiEnabled(Enum.CoreGuiType.Backpack) then
				return
			end
			task.wait(H.CoreGuiRetryDelay)
		end
		warn("[SAC/Hotbar] Couldn't turn off Roblox's backpack; both hotbars may show.")
	end)
end

--------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------

function HotbarController.Start()
	if not Config.UI.CustomHotbar then
		return
	end
	hideCoreBackpack()

	local gui = UI.new("ScreenGui", {
		Name = "Hotbar",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = Config.UI.Layers.Hud,
	}) :: ScreenGui
	local frame = UI.new("Frame", {
		Name = "Bar",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -L.HotbarBottom),
		Size = UDim2.fromOffset(0, L.HotbarSlot),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		Visible = false,
		Parent = gui,
	}, {
		UI.List({
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = H.Gap,
		}),
	}) :: Frame
	UI.Scale(frame)
	bar = frame
	gui.Parent = localPlayer:WaitForChild("PlayerGui")

	-- Backpack (a new one every spawn).
	local current = localPlayer:FindFirstChildOfClass("Backpack")
	if current then
		watchBackpack(current)
	end
	localPlayer.ChildAdded:Connect(function(child: Instance)
		if child:IsA("Backpack") then
			watchBackpack(child)
		end
	end)

	-- Character.
	if localPlayer.Character then
		watchCharacter(localPlayer.Character)
	end
	localPlayer.CharacterAdded:Connect(watchCharacter)
	localPlayer.CharacterRemoving:Connect(function(model: Model)
		if character == model then
			forgetCharacter()
		end
	end)

	-- Keys 1..9 and gamepad shoulder buttons.
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed or UserInputService:GetFocusedTextBox() ~= nil then
			return
		end
		local keyCode = input.KeyCode
		if input.UserInputType == Enum.UserInputType.Keyboard then
			local index = KEY_TO_INDEX[keyCode]
			if index then
				toggleIndex(index)
			end
		elseif keyCode == H.GamepadNext then
			cycle(1)
		elseif keyCode == H.GamepadPrevious then
			cycle(-1)
		end
	end)

	scheduleRefresh()
end

return HotbarController
