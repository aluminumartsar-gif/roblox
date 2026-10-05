--!strict
--[[
	ShopPanel
	StarterPlayerScripts/Client/Components/ShopPanel

	The shared modal used by the Egg Shop, Upgrade Shop and Rebirth screens:
	a centred panel with a title, a close button and a scrolling list.
	Opened at a shop counter, it closes itself when you walk away.
	Placeholder styling — the real UI pass is Step 8.

	  local panel = ShopPanel.new("EggShop", "EGG SHOP")
	  local row = ShopPanel.Row(panel.List, 1)
	  ShopPanel.Label(row, { Text = "Forest Egg", ... })
	  ShopPanel.Button(row, { Text = "$100", ... })
	  panel:Open(counterPart)   -- or panel:Open() for no walk-away close
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Icon = require(script.Parent:WaitForChild("Icon"))

local ShopPanel = {}
ShopPanel.__index = ShopPanel

export type Panel = {
	Gui: ScreenGui,
	Frame: Frame,
	Title: TextLabel,
	List: ScrollingFrame,
	OnOpen: (() -> ())?,
	Open: (self: Panel, counter: BasePart?) -> (),
	Close: (self: Panel) -> (),
	IsOpen: (self: Panel) -> boolean,
}

local TEXT = Color3.fromRGB(255, 236, 200)

function ShopPanel.Label(parent: Instance, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.TextColor3 = TEXT
	l.Font = Enum.Font.GothamMedium
	l.TextXAlignment = Enum.TextXAlignment.Left
	for key, value in pairs(props) do
		(l :: any)[key] = value
	end
	l.Parent = parent
	return l
end

function ShopPanel.Button(parent: Instance, props: { [string]: any }): TextButton
	local b = Instance.new("TextButton")
	b.Font = Enum.Font.GothamBold
	b.TextSize = 16
	b.TextColor3 = Color3.new(1, 1, 1)
	b.BackgroundColor3 = Color3.fromRGB(46, 140, 80)
	for key, value in pairs(props) do
		(b :: any)[key] = value
	end
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = b
	b.Parent = parent
	return b
end

--- A list row with a rounded background. Height defaults to 64px.
function ShopPanel.Row(list: Instance, order: number, height: number?): Frame
	local row = Instance.new("Frame")
	row.LayoutOrder = order
	row.Size = UDim2.new(1, -8, 0, height or 64)
	row.BackgroundColor3 = Color3.fromRGB(36, 38, 48)
	row.Parent = list
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = row
	return row
end

function ShopPanel.new(name: string, title: string, iconName: string?): Panel
	local self = setmetatable({}, ShopPanel) :: any

	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.DisplayOrder = 5

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.52)
	frame.Size = UDim2.fromScale(0.92, 0.72)
	frame.BackgroundColor3 = Color3.fromRGB(24, 26, 34)
	frame.BackgroundTransparency = 0.05
	frame.Parent = gui
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(480, 560)
	constraint.Parent = frame
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = frame

	local titleLabel = ShopPanel.Label(frame, {
		Name = "Title", Text = title, Font = Enum.Font.GothamBlack, TextSize = 22,
		Size = UDim2.new(1, -70, 0, 44), Position = UDim2.fromOffset(16, 6),
	})
	if iconName then
		Icon.addLeft(titleLabel, iconName, 32, 0)
	end

	local close = ShopPanel.Button(frame, {
		Name = "Close", Text = "X", Font = Enum.Font.GothamBlack, TextSize = 20,
		BackgroundColor3 = Color3.fromRGB(120, 40, 48),
		AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 8),
		Size = UDim2.fromOffset(40, 40),
	})

	local list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.Position = UDim2.fromOffset(10, 56)
	list.Size = UDim2.new(1, -20, 1, -66)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 6
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.Parent = frame
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	self.Gui = gui
	self.Frame = frame
	self.Title = titleLabel
	self.List = list
	self._counter = nil :: BasePart?

	close.Activated:Connect(function()
		self:Close()
	end)

	-- Close when the player walks away from the counter it was opened at.
	task.spawn(function()
		while gui.Parent do
			task.wait(0.3)
			local counter = self._counter
			if counter and gui.Enabled then
				local character = Players.LocalPlayer.Character
				local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
				if not root or not counter.Parent
					or (root.Position - counter.Position).Magnitude > Config.Shop.InteractDistance then
					self:Close()
				end
			end
		end
	end)

	return self
end

function ShopPanel:Open(counter: BasePart?)
	self._counter = counter
	if self.OnOpen then
		self.OnOpen()
	end
	self.Gui.Enabled = true
end

function ShopPanel:Close()
	self._counter = nil
	self.Gui.Enabled = false
end

function ShopPanel:IsOpen(): boolean
	return self.Gui.Enabled
end

return ShopPanel
