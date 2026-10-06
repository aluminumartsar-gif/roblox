--!strict
--[[
	Window
	StarterPlayerScripts/Client/Components/Window

	Popup screens in the "campfire field kit" look (replaces the STUD kit's
	Kit.Popup). One window is open at a time; opening one closes the rest.

	  local window = Window.new({
	      Name = "Store",               -- ScreenGui name
	      Title = "Store",              -- big title in the header
	      Icon = "Shop",                -- Config.Icons name (optional)
	      Size = Vector2.new(760, 470), -- design size in px at the reference
	                                    -- screen height (shrinks to fit phones)
	      Info = "Pages 0/7",           -- optional right-hand header text
	      Backdrop = true,              -- dim the world behind (default true)
	  })
	  window.OnOpen = function() refresh() end
	  window.Body       -- Frame under the header: put the screen's contents here
	  window:Open(counter?)  -- counter: a BasePart; walking away from it closes
	  window:Close() / window:IsOpen() / window:SetTitle(t) / window:SetInfo(t)

	  Window.CloseAll(except?) / Window.AnyOpen(except?) / Window.Get(name)

	Contract other code relies on: the ScreenGui is Enabled only while the
	window shows, and its direct child is a frame named "Container" (the
	open sound in SoundController and the auto-open checks in
	DailyRewardsController look for exactly that).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Components = script.Parent
local Theme = require(Components:WaitForChild("Theme"))
local UI = require(Components:WaitForChild("UI"))

local C = Theme.Colors
local W = Theme.Tuning.Window
local scaleTuning = Config.UI.ScreenScale

local localPlayer = Players.LocalPlayer

export type Window = {
	Name: string,
	Gui: ScreenGui,
	Container: Frame,
	Panel: Frame,
	Header: Frame,
	Body: Frame,
	TitleLabel: TextLabel,
	InfoLabel: TextLabel,
	CloseButton: TextButton,
	OnOpen: (() -> ())?,
	OnClose: (() -> ())?,
	Open: (self: Window, counter: BasePart?) -> (),
	Close: (self: Window) -> (),
	IsOpen: (self: Window) -> boolean,
	SetTitle: (self: Window, text: string) -> (),
	SetInfo: (self: Window, text: string?) -> (),
}

local Window = {}
Window.__index = Window

local windows: { any } = {}

--------------------------------------------------------------------------
-- Registry
--------------------------------------------------------------------------

function Window.CloseAll(except: any?)
	for _, w in ipairs(windows) do
		if w ~= except then
			w:Close()
		end
	end
end

function Window.AnyOpen(except: any?): boolean
	for _, w in ipairs(windows) do
		if w ~= except and w._open then
			return true
		end
	end
	return false
end

function Window.Get(name: string): any?
	for _, w in ipairs(windows) do
		if w.Name == name then
			return w
		end
	end
	return nil
end

--------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------

local function fitScale(container: Frame, design: Vector2): UIScale
	local scale = UI.new("UIScale", { Name = "Fit", Parent = container }) :: UIScale
	local connection: RBXScriptConnection? = nil
	local function watch()
		if connection then
			connection:Disconnect()
		end
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		local function update()
			local viewport = camera.ViewportSize
			local inset = GuiService:GetGuiInset().Y
			local margin = W.ScreenMargin * 2
			local byHeight = viewport.Y / scaleTuning.ReferenceHeight
			local fitY = (viewport.Y - inset - margin) / design.Y
			local fitX = (viewport.X - margin) / design.X
			scale.Scale = math.max(0.3, math.min(scaleTuning.Max, math.max(scaleTuning.Min, byHeight), fitY, fitX))
		end
		connection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(update)
		update()
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watch)
	watch()
	return scale
end

function Window.new(props: { [string]: any }): Window
	local design: Vector2 = props.Size or Vector2.new(640, 420)
	local headerHeight = W.HeaderHeight

	local gui = UI.new("ScreenGui", {
		Name = props.Name or "Window",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = props.DisplayOrder or Config.UI.Layers.Window,
		Enabled = false,
	}) :: ScreenGui

	local backdrop = UI.new("Frame", {
		Name = "Backdrop",
		BackgroundColor3 = C.Backdrop,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = props.Backdrop ~= false,
		Parent = gui,
	}) :: Frame

	-- Centred in the area under Roblox's top bar.
	local container = UI.new("Frame", {
		Name = "Container",
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(design.X, design.Y),
		Parent = gui,
	}) :: Frame
	local function centre()
		local inset = GuiService:GetGuiInset().Y
		container.Position = UDim2.new(0.5, 0, 0.5, math.floor(inset / 2))
	end
	centre()
	fitScale(container, design)

	-- Inner frame carries the open/close "pop" so it doesn't fight the fit scale.
	local pop = UI.new("Frame", {
		Name = "Pop",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = container,
	}) :: Frame
	local popScale = UI.new("UIScale", { Name = "PopScale", Parent = pop }) :: UIScale

	UI.new("Frame", {
		Name = "Shadow",
		BackgroundColor3 = C.Shadow,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 6),
		Size = UDim2.fromScale(1, 1),
		Parent = pop,
	}, { UI.Corner(Theme.Tuning.Corner + 2) })

	local panel = UI.Panel({ Name = "Panel", Rivets = true, Parent = pop })

	-- Header: icon, title, info, close.
	local header = UI.new("Frame", {
		Name = "Header",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, headerHeight),
		Parent = panel,
	}, {
		UI.Corner(Theme.Tuning.Corner),
		UI.Gradient(Theme.Sequence(Theme.Mix(C.PanelTop, C.EmberDeep, 0.22), C.PanelTop), 90),
	}) :: Frame
	-- Square off the header's bottom corners.
	UI.new("Frame", {
		Name = "Square",
		BackgroundColor3 = C.PanelTop,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, Theme.Tuning.Corner),
		Parent = header,
	})
	UI.Divider({
		Name = "Rule",
		Color = C.Ember,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 2),
		ZIndex = 2,
		Parent = header,
	})

	local left = 18
	if props.Icon then
		UI.Icon(props.Icon, 30, {
			Name = "TitleIcon",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 18, 0.5, 0),
			ImageColor3 = C.Ember,
			ZIndex = 2,
			Parent = header,
		})
		left = 58
	end
	local title = UI.Title(props.Title or "", 36, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, left, 0.5, 1),
		Size = UDim2.new(0.6, -left, 0, 42),
		ZIndex = 2,
		Parent = header,
	})
	local info = UI.Text({
		Name = "Info",
		Role = "Heading",
		Weight = "SemiBold",
		Text = props.Info or "",
		TextSize = 18,
		TextColor3 = C.TextDim,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -70, 0.5, 0),
		Size = UDim2.new(0.4, -70, 0, 24),
		ZIndex = 2,
		Parent = header,
	})
	local close = UI.Button({
		Name = "CloseBtn",
		Variant = "Ghost",
		Icon = "Close",
		IconSize = 18,
		Text = "",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(38, 38),
		ZIndex = 3,
		Parent = header,
	})
	-- The empty label would still take a sliver of the row; drop it.
	local closeContent = close:FindFirstChild("Content")
	local closeLabel = closeContent and closeContent:FindFirstChild("Label")
	if closeLabel then
		closeLabel:Destroy()
	end

	local body = UI.new("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, headerHeight),
		Size = UDim2.new(1, 0, 1, -headerHeight),
		Parent = panel,
	}, { UI.Padding(16) }) :: Frame

	local self = setmetatable({}, Window) :: any
	self.Name = gui.Name
	self.Gui = gui
	self.Container = container
	self.Panel = panel
	self.Header = header
	self.Body = body
	self.TitleLabel = title
	self.InfoLabel = info
	self.CloseButton = close
	self._backdrop = backdrop
	self._popScale = popScale
	self._open = false
	self._counter = nil :: BasePart?
	self._closeThread = nil :: thread?

	close.Activated:Connect(function()
		self:Close()
	end)

	-- Close when the player walks away from the counter it was opened at.
	task.spawn(function()
		while not self._destroyed do
			task.wait(0.3)
			local counter = self._counter
			if counter and self._open then
				local character = localPlayer.Character
				local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
				if not root or not counter.Parent
					or (root.Position - counter.Position).Magnitude > Config.Shop.InteractDistance then
					self:Close()
				end
			end
		end
	end)

	gui.Destroying:Connect(function()
		self._destroyed = true
		local index = table.find(windows, self)
		if index then
			table.remove(windows, index)
		end
	end)

	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(centre)
	table.insert(windows, self)
	return self
end

--------------------------------------------------------------------------
-- Methods
--------------------------------------------------------------------------

function Window:Open(counter: BasePart?)
	self._counter = counter
	if self.OnOpen then
		self.OnOpen()
	end
	if self._open then
		return
	end
	Window.CloseAll(self)
	self._open = true
	self._closeThread = nil
	self.Gui.Enabled = true
	self._popScale.Scale = W.OpenFromScale
	TweenService:Create(self._popScale, TweenInfo.new(W.OpenTime, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	if self._backdrop.Visible then
		self._backdrop.BackgroundTransparency = 1
		TweenService:Create(self._backdrop, TweenInfo.new(W.OpenTime), { BackgroundTransparency = W.BackdropTransparency }):Play()
	end
end

function Window:Close()
	self._counter = nil
	if not self._open then
		return
	end
	self._open = false
	if self.OnClose then
		task.spawn(self.OnClose)
	end
	TweenService:Create(self._popScale, TweenInfo.new(W.CloseTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = W.OpenFromScale }):Play()
	TweenService:Create(self._backdrop, TweenInfo.new(W.CloseTime), { BackgroundTransparency = 1 }):Play()
	local thread
	thread = task.delay(W.CloseTime, function()
		if self._closeThread == thread and not self._open then
			self.Gui.Enabled = false
		end
	end)
	self._closeThread = thread
end

function Window:IsOpen(): boolean
	return self._open
end

function Window:SetTitle(text: string)
	self.TitleLabel.Text = text
end

function Window:SetInfo(text: string?)
	self.InfoLabel.Text = text or ""
end

return Window
