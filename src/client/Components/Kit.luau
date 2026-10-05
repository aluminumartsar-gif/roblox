--!strict
--[[
	Kit
	StarterPlayerScripts/Client/Components/Kit

	Glue between the game and the STUD UI kit (ReplicatedStorage.UIKit, a
	purchased pack synced from vendor/stud/ by Rojo — see CLAUDE.md "UI kit").

	The kit's screens live in ReplicatedStorage as templates. Controllers call
	Kit.Mount(name) to put a copy in the player's UI and then drive it with
	real game data. The kit's own screen/shop scripts are NOT used (its shop
	prompted purchases client-side); only its visual modules are:

	  Kit.Start()   — preloads the kit's images (so buttons aren't blank boxes
	                  on first open) and starts UIAnimations / UIEffects /
	                  UIScroller (hover, pulse, float, flare, star clicks).
	  Kit.Mount(n)  — clones a kit ScreenGui into PlayerGui, strips the kit's
	                  sample ProductId/ProductType values, returns the copy.
	  Kit.Popup(g)  — the kit's bouncy open/close on g.Container, one popup
	                  open at a time, close button wired, optional
	                  close-when-you-walk-away-from-a-counter.
]]

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Kit = {}

local localPlayer = Players.LocalPlayer
local kitRoot = ReplicatedStorage:WaitForChild("UIKit")
local templates = kitRoot:WaitForChild("StarterGui")

local OPEN_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

export type Popup = {
	Gui: ScreenGui,
	Container: GuiObject,
	OnOpen: (() -> ())?,
	Open: (self: Popup, counter: BasePart?) -> (),
	Close: (self: Popup) -> (),
	IsOpen: (self: Popup) -> boolean,
}

local popups: { Popup } = {}
local started = false

--------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------

function Kit.Start()
	if started then
		return
	end
	started = true

	-- Fetch every kit image up front; without this the first open of each
	-- screen shows empty boxes while images download.
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync({ templates })
		end)
	end)

	local modules = kitRoot:WaitForChild("StarterPlayerScripts"):WaitForChild("UIController")
	for _, name in ipairs({ "UIAnimations", "UIEffects", "UIScroller" }) do
		local module = modules:FindFirstChild(name)
		if module then
			local ok, err = pcall(require, module)
			if not ok then
				warn("[SAC/Kit] " .. name .. " failed: " .. tostring(err))
			end
		end
	end
end

--------------------------------------------------------------------------
-- Mounting
--------------------------------------------------------------------------

--- Puts a copy of a kit screen in the player's UI and returns it.
function Kit.Mount(name: string): ScreenGui
	Kit.Start()
	local template = templates:WaitForChild(name) :: ScreenGui
	local gui = template:Clone()
	gui.ResetOnSpawn = false
	-- The kit's sample purchase wiring: never used, so never left lying around.
	for _, d in ipairs(gui:GetDescendants()) do
		if (d.Name == "ProductId" or d.Name == "ProductType") and d:IsA("ValueBase") then
			d:Destroy()
		end
	end
	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	return gui
end

--- First descendant with this name (the kit nests things inconsistently).
function Kit.Deep(root: Instance, name: string): any
	return root:FindFirstChild(name, true)
end

--- Children with this name, sorted left-to-right then top-to-bottom.
function Kit.ChildrenNamed(parent: Instance, name: string): { any }
	local found = {}
	for _, child in ipairs(parent:GetChildren()) do
		if child.Name == name then
			table.insert(found, child)
		end
	end
	table.sort(found, function(a: any, b: any)
		if a:IsA("GuiObject") and b:IsA("GuiObject") then
			if math.abs(a.Position.Y.Scale - b.Position.Y.Scale) > 0.01 then
				return a.Position.Y.Scale < b.Position.Y.Scale
			end
			return a.Position.X.Scale < b.Position.X.Scale
		end
		return false
	end)
	return found
end

function Kit.SetText(label: Instance?, text: string)
	if label and (label:IsA("TextLabel") or label:IsA("TextButton")) then
		label.Text = text
	end
end

function Kit.Hide(instance: Instance?)
	if instance and instance:IsA("GuiObject") then
		instance.Visible = false
	end
end

--- Sets the "Title" text inside a kit button.
function Kit.SetButtonText(button: Instance?, text: string)
	if not button then
		return
	end
	local title = button:FindFirstChild("Title")
	Kit.SetText(title, text)
end

--- Greys a kit button out (or restores it). Kit buttons are images, so this
--- tints the image rather than recolouring a background.
function Kit.SetButtonEnabled(button: Instance?, enabled: boolean)
	if button and (button:IsA("ImageButton") or button:IsA("ImageLabel")) then
		button.ImageColor3 = if enabled then Color3.new(1, 1, 1) else Color3.fromRGB(120, 120, 120)
	end
end

--- Kit scrolling lists have a fixed canvas height sized for the kit's own
--- sample rows. Keep the canvas exactly as tall as what we actually put in
--- it, so nothing past the kit's original length gets cut off.
function Kit.FitCanvas(scroller: ScrollingFrame)
	local layout = scroller:FindFirstChildWhichIsA("UIGridStyleLayout")
	if not layout then
		return
	end
	local padding = scroller:FindFirstChildOfClass("UIPadding")
	local function fit()
		local extra = 0
		if padding then
			extra = padding.PaddingTop.Offset + padding.PaddingBottom.Offset
				+ (padding.PaddingTop.Scale + padding.PaddingBottom.Scale) * scroller.AbsoluteSize.Y
		end
		scroller.CanvasSize = UDim2.new(0, 0, 0, math.ceil(layout.AbsoluteContentSize.Y + extra))
	end
	layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(fit)
	scroller:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	fit()
end

--------------------------------------------------------------------------
-- Popups
--------------------------------------------------------------------------

local Popup = {}
Popup.__index = Popup

function Kit.CloseAll(except: Popup?)
	for _, popup in ipairs(popups) do
		if popup ~= except then
			popup:Close()
		end
	end
end

function Kit.Popup(gui: ScreenGui): Popup
	local container = gui:WaitForChild("Container") :: GuiObject
	local self = setmetatable({}, Popup) :: any
	self.Gui = gui
	self.Container = container
	self._fullSize = container.Size
	self._open = false
	self._counter = nil :: BasePart?

	-- Start hidden: centred, zero size, screen disabled.
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Position = UDim2.fromScale(0.5, 0.5)
	container.Visible = true
	container.Size = UDim2.new()
	gui.Enabled = false

	self._closeTween = TweenService:Create(container, CLOSE_INFO, { Size = UDim2.new() })
	self._closeTween.Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed and not self._open then
			gui.Enabled = false
		end
	end)

	local closeButton = Kit.Deep(container, "CloseBtn")
	if closeButton and closeButton:IsA("GuiButton") then
		closeButton.Activated:Connect(function()
			self:Close()
		end)
	end

	-- Close when the player walks away from the counter it was opened at.
	task.spawn(function()
		while gui.Parent do
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

	table.insert(popups, self)
	return self
end

function Popup:Open(counter: BasePart?)
	self._counter = counter
	if self.OnOpen then
		self.OnOpen()
	end
	if self._open then
		return
	end
	Kit.CloseAll(self)
	self._open = true
	self._closeTween:Cancel()
	self.Gui.Enabled = true
	TweenService:Create(self.Container, OPEN_INFO, { Size = self._fullSize }):Play()
end

function Popup:Close()
	self._counter = nil
	if not self._open then
		return
	end
	self._open = false
	self._closeTween:Play()
end

function Popup:IsOpen(): boolean
	return self._open
end

return Kit
