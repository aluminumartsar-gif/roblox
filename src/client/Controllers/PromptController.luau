--!strict
--[[
	PromptController
	StarterPlayerScripts/Client/Controllers/PromptController

	Draws every ProximityPrompt ("hold E to steal", "Buy $1.2K", "Capture",
	"Lock Camp", ...) in the campfire field kit look instead of Roblox's
	default grey bubble. Follows the structure of Roblox's official
	custom-prompt sample:

	  * every prompt in the Workspace (the ones there now and every one that
	    streams in later) is switched to Style = Custom, on this client only
	  * ProximityPromptService.PromptShown(prompt, inputType) builds a
	    BillboardGui in PlayerGui, adorned to the prompt's part (or
	    attachment; a model uses its PrimaryPart), always on top:
	      - a charred plate
	      - an ember key cap with the key: the keyboard key, the gamepad
	        button's image, or a tap icon on touch screens
	      - ObjectText (small, dim, top line) and ActionText (bold)
	      - a hold-progress bar that fills over HoldDuration while the key
	        is held (PromptButtonHoldBegan / PromptButtonHoldEnded) and drains
	        when it's let go; taps (HoldDuration 0, e.g. the belt Buy) have
	        no bar and just pop when they fire
	  * PromptHidden (or the prompt being disabled or removed) shrinks it away
	  * touch, and mouse clicks on clickable prompts: the plate is a button
	    that calls prompt:InputHoldBegin() on press and InputHoldEnd() on
	    release, exactly like Roblox's own touch prompts
	  * ActionText / ObjectText / HoldDuration / key changes made while it
	    shows (the Sell price, "Take back", ...) update it live

	Accent rule: the key cap and bar use the UI button variant named in
	Config.UI.Prompts.AccentByName[prompt.Name] (default
	Config.UI.Prompts.DefaultAccent, ember). StealService names every steal
	prompt "StealPrompt", so steals are blood red.

	Never changes how a prompt behaves: reach, hold time, line of sight,
	Enabled, parent and position are left exactly as the server and other
	controllers set them (see CLAUDE.md: the server checks triggers against
	where it thinks the part is, and holds on moving prompts get cut off).

	Config.UI.CustomPrompts = false leaves Roblox's default prompts
	completely untouched. If building a prompt's UI ever fails, every prompt
	goes back to Roblox's default style so nobody is left unable to interact.

	Tunables: Config.UI.Prompts.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Components = script.Parent.Parent:WaitForChild("Components")
local Theme = require(Components:WaitForChild("Theme"))
local UI = require(Components:WaitForChild("UI"))

local PromptController = {}

local localPlayer = Players.LocalPlayer

local C = Theme.Colors
local P = Config.UI.Prompts

-- Gamepad button images come from Roblox in their own colours: no tint.
local NO_TINT = Color3.new(1, 1, 1)
-- Keys whose name is longer than this use the smaller key-cap text size.
local SHORT_KEY_LENGTH = 2

type View = {
	prompt: ProximityPrompt,
	billboard: BillboardGui,
	plate: Frame,
	scale: UIScale,
	keyCap: Frame,
	keyScale: UIScale,
	keyText: TextLabel,
	keyImage: ImageLabel,
	action: TextLabel,
	object: TextLabel,
	bar: Frame,
	fill: Frame,
	button: TextButton?,
	inputType: Enum.ProximityPromptInputType,
	baseScale: number,
	holding: boolean,          -- our button started a hold (touch / mouse)
	holdInput: InputObject?,   -- the touch / click that started it
	inputWatch: RBXScriptConnection?,
	fillTween: Tween?,
	connections: { RBXScriptConnection },
	closed: boolean,
}

local views: { [ProximityPrompt]: View } = {}
local playerGui: Instance? = nil
local failed = false -- a build error switched everything back to Roblox's default

local function warnf(fmt: string, ...: any)
	warn(string.format("[SAC/Prompts] " .. fmt, ...))
end

--- Same maths as Components/ScreenScale, read once per layout (a billboard
--- is rebuilt every time its prompt shows, so it needs no live watcher).
local function screenScale(): number
	local tuning = Config.UI.ScreenScale
	local camera = Workspace.CurrentCamera
	local height = if camera then camera.ViewportSize.Y else tuning.ReferenceHeight
	return math.clamp(height / tuning.ReferenceHeight, tuning.Min, tuning.Max)
end

local function accentFor(prompt: ProximityPrompt)
	local name = P.AccentByName[prompt.Name] or P.DefaultAccent
	return UI.Variants[name] or UI.Variants.Primary
end

--- What the billboard hangs on: the prompt's part or attachment, or a
--- model's PrimaryPart (else its first part).
local function adorneeFor(prompt: ProximityPrompt): Instance?
	local parent = prompt.Parent
	if not parent then
		return nil
	end
	if parent:IsA("BasePart") or parent:IsA("Attachment") then
		return parent
	end
	if parent:IsA("Model") then
		return parent.PrimaryPart or parent:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

--------------------------------------------------------------------------
-- Key cap
--------------------------------------------------------------------------

local function setKey(view: View)
	local prompt = view.prompt
	local text: string? = nil
	local image: string? = nil
	local tint = view.keyText.TextColor3

	if view.inputType == Enum.ProximityPromptInputType.Touch then
		image = Config.Icons[P.TouchIcon]
	elseif view.inputType == Enum.ProximityPromptInputType.Gamepad then
		local ok, result = pcall(function()
			return UserInputService:GetImageForKeyCode(prompt.GamepadKeyCode)
		end)
		if ok and typeof(result) == "string" and result ~= "" then
			image = result
			tint = NO_TINT
		else
			text = (string.gsub(prompt.GamepadKeyCode.Name, "^Button", ""))
		end
	else
		local ok, result = pcall(function()
			return UserInputService:GetStringForKeyCode(prompt.KeyboardKeyCode)
		end)
		text = if ok and typeof(result) == "string" and result ~= "" then result else prompt.KeyboardKeyCode.Name
	end

	if image then
		view.keyImage.Image = image
		view.keyImage.ImageColor3 = tint
		view.keyImage.Visible = true
		view.keyText.Visible = false
	else
		local key = string.upper(text or "")
		view.keyText.Text = key
		view.keyText.TextSize = if #key > SHORT_KEY_LENGTH then P.KeyTextSizeLong else P.KeyTextSize
		view.keyText.Visible = true
		view.keyImage.Visible = false
	end
end

--------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------

--- Sizes the plate to its text and the billboard to the plate. Called on
--- show, when the prompt's text changes, and when the font finishes loading
--- (TextBounds changes).
local function layout(view: View)
	local prompt = view.prompt
	local actionText = if P.UppercaseAction then string.upper(prompt.ActionText) else prompt.ActionText
	local hasAction = actionText ~= ""
	local hasObject = prompt.ObjectText ~= ""

	-- Text block centred on the key cap: object line on top, action below.
	-- Labels are MaxTextWidth wide (transparent past the text) so their
	-- TextBounds measure the text, cut off with "..." past that width.
	local height = P.Height
	local textX = P.Padding + P.KeySize + P.Gap
	local keyTop = (height - P.KeySize) / 2
	local actionHeight = P.ActionTextSize + 3
	local objectHeight = P.ObjectTextSize + 2
	local blockHeight = (if hasAction then actionHeight else 0) + (if hasObject then objectHeight else 0)
	local top = keyTop + (P.KeySize - blockHeight) / 2
	view.object.Position = UDim2.fromOffset(textX, top)
	view.object.Size = UDim2.fromOffset(P.MaxTextWidth, objectHeight)
	view.action.Position = UDim2.fromOffset(textX, top + (if hasObject then objectHeight else 0))
	view.action.Size = UDim2.fromOffset(P.MaxTextWidth, actionHeight)

	view.action.Text = actionText
	view.action.Visible = hasAction
	view.action.AutoLocalize = prompt.AutoLocalize
	view.object.Text = prompt.ObjectText
	view.object.Visible = hasObject
	view.object.AutoLocalize = prompt.AutoLocalize

	local textWidth = 0
	if hasAction then
		textWidth = math.max(textWidth, view.action.TextBounds.X)
	end
	if hasObject then
		textWidth = math.max(textWidth, view.object.TextBounds.X)
	end
	textWidth = math.min(math.ceil(textWidth), P.MaxTextWidth)

	-- A prompt with no text is just the key cap on a square plate.
	local width = height
	if hasAction or hasObject then
		width = textX + textWidth + P.Padding + P.Gap
	end

	view.bar.Visible = prompt.HoldDuration > 0

	local s = screenScale()
	if s ~= view.baseScale then
		-- (Only on a real change, so a text update never cuts a pop short.)
		view.baseScale = s
		view.scale.Scale = s
	end
	view.plate.Size = UDim2.fromOffset(width, height)
	local pixelWidth = width * s
	local pixelHeight = height * s
	view.billboard.Size = UDim2.fromOffset(pixelWidth, pixelHeight)
	view.billboard.SizeOffset = Vector2.new(prompt.UIOffset.X / pixelWidth, prompt.UIOffset.Y / pixelHeight)
end

--------------------------------------------------------------------------
-- Hold progress
--------------------------------------------------------------------------

local function stopFill(view: View)
	if view.fillTween then
		view.fillTween:Cancel()
		view.fillTween = nil
	end
end

local function tweenFill(view: View, alpha: number, seconds: number)
	stopFill(view)
	local goal = UDim2.fromScale(alpha, 1)
	if seconds <= 0 then
		view.fill.Size = goal
		return
	end
	local tween = TweenService:Create(view.fill, TweenInfo.new(seconds, Enum.EasingStyle.Linear), { Size = goal })
	view.fillTween = tween
	tween:Play()
end

local function onHoldBegan(view: View)
	local duration = view.prompt.HoldDuration
	if duration > 0 then
		view.fill.Size = UDim2.fromScale(0, 1)
		tweenFill(view, 1, duration)
	end
	UI.Tween(view.keyScale, Theme.Tuning.HoverTime, { Scale = P.KeyPressScale })
end

local function onHoldEnded(view: View)
	-- When a hold completes, Roblox fires HoldEnded just before Triggered;
	-- Triggered then fills the bar again, so draining here is safe.
	tweenFill(view, 0, P.HoldResetTime)
	UI.Tween(view.keyScale, Theme.Tuning.HoverTime, { Scale = 1 }, Enum.EasingStyle.Back)
end

local function onTriggered(view: View)
	if view.prompt.HoldDuration > 0 then
		tweenFill(view, 1, 0)
	end
	view.scale.Scale = view.baseScale * P.TriggerPunch
	UI.Tween(view.scale, P.TriggerPunchTime, { Scale = view.baseScale }, Enum.EasingStyle.Back)
end

local function onTriggerEnded(view: View)
	tweenFill(view, 0, P.HoldResetTime)
	UI.Tween(view.keyScale, Theme.Tuning.HoverTime, { Scale = 1 }, Enum.EasingStyle.Back)
end

--------------------------------------------------------------------------
-- Touch / mouse input
--------------------------------------------------------------------------

local function isPress(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1
end

--- Ends a hold our button started (finger lifted, click released, or the
--- prompt went away mid-hold). Safe to call more than once.
local function release(view: View)
	if not view.holding then
		return
	end
	view.holding = false
	view.holdInput = nil
	if view.inputWatch then
		view.inputWatch:Disconnect()
		view.inputWatch = nil
	end
	local prompt = view.prompt
	pcall(function()
		prompt:InputHoldEnd()
	end)
end

--- Does this input ending let go of the hold our button started? A touch
--- must be the same finger (lifting the thumbstick finger must not end a
--- steal); the mouse button may arrive as a different InputObject.
local function endsHold(view: View, input: InputObject): boolean
	local held = view.holdInput
	if not view.holding or not held then
		return false
	end
	if input == held then
		return true
	end
	return held.UserInputType == Enum.UserInputType.MouseButton1
		and input.UserInputType == Enum.UserInputType.MouseButton1
end

local function makeClickable(view: View)
	local button = UI.new("TextButton", {
		Name = "Input",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Selectable = false,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 10,
		Parent = view.plate,
	}) :: TextButton
	-- The prompt's own action makes the sound; no UI click on top.
	button:SetAttribute("SAC_NoClick", true)
	view.button = button
	view.billboard.Active = true

	table.insert(view.connections, button.InputBegan:Connect(function(input: InputObject)
		if not isPress(input) or input.UserInputState == Enum.UserInputState.Change or view.holding or view.closed then
			return
		end
		view.holding = true
		view.holdInput = input
		-- Let go anywhere (even after sliding off the plate) ends the hold;
		-- UserInputService.InputEnded in Start() is the backstop.
		view.inputWatch = input:GetPropertyChangedSignal("UserInputState"):Connect(function()
			local state = input.UserInputState
			if state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
				release(view)
			end
		end)
		local prompt = view.prompt
		pcall(function()
			prompt:InputHoldBegin()
		end)
	end))
	table.insert(view.connections, button.InputEnded:Connect(function(input: InputObject)
		if endsHold(view, input) then
			release(view)
		end
	end))
end

--------------------------------------------------------------------------
-- Build / remove
--------------------------------------------------------------------------

local function hide(view: View, instant: boolean?)
	if view.closed then
		return
	end
	view.closed = true
	if views[view.prompt] == view then
		views[view.prompt] = nil
	end
	release(view)
	stopFill(view)
	for _, connection in ipairs(view.connections) do
		connection:Disconnect()
	end
	table.clear(view.connections)
	if view.button then
		view.button.Active = false
	end
	local billboard = view.billboard
	if instant then
		billboard:Destroy()
		return
	end
	UI.Tween(view.scale, P.HideTime, { Scale = view.baseScale * P.HideToScale }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	task.delay(P.HideTime, function()
		billboard:Destroy()
	end)
end

local function build(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType, adornee: Instance, parent: Instance): View
	local accent = accentFor(prompt)

	local billboard = UI.new("BillboardGui", {
		Name = "Prompt_" .. prompt.Name,
		AlwaysOnTop = true,
		LightInfluence = 0,
		ClipsDescendants = false, -- the plate pops slightly past its edges
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Active = false,
		Size = UDim2.fromOffset(P.Height, P.Height),
		Adornee = adornee,
	}) :: BillboardGui

	local plate = UI.Panel({
		Name = "Plate",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(P.Height, P.Height),
		BackgroundTransparency = P.PlateTransparency,
		Parent = billboard,
	})
	local scale = UI.new("UIScale", { Name = "Scale", Parent = plate }) :: UIScale

	-- Ember key cap (shaped like a UI.Button of the accent variant).
	local keyCap = UI.new("Frame", {
		Name = "KeyCap",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, P.Padding, 0.5, 0),
		Size = UDim2.fromOffset(P.KeySize, P.KeySize),
		BackgroundColor3 = NO_TINT,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = plate,
	}, {
		UI.Corner(Theme.Tuning.Corner),
		UI.Gradient(Theme.Sequence(accent.Top, accent.Bottom, accent.Mid), 90),
		UI.Stroke({ Color = accent.Edge, Thickness = 1.5 }),
	}) :: Frame
	local keyScale = UI.new("UIScale", { Name = "Press", Parent = keyCap }) :: UIScale
	UI.new("Frame", {
		Name = "Sheen",
		BackgroundColor3 = NO_TINT,
		BackgroundTransparency = accent.Sheen,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(4, 2),
		Size = UDim2.new(1, -8, 0, 1),
		ZIndex = 3,
		Parent = keyCap,
	})
	local keyText = UI.Text({
		Name = "Key",
		Role = "Heading",
		Weight = "Bold",
		RichText = false,
		Text = "",
		TextColor3 = accent.Text,
		TextSize = P.KeyTextSize,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 4,
		Parent = keyCap,
	})
	local keyImage = UI.Icon(P.TouchIcon, math.floor(P.KeySize * 0.6), {
		Name = "KeyImage",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		ImageColor3 = accent.Text,
		Visible = false,
		ZIndex = 4,
		Parent = keyCap,
	})

	local object = UI.Text({
		Name = "ObjectText",
		Role = "Body",
		RichText = false,
		TextColor3 = C.TextDim,
		TextSize = P.ObjectTextSize,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 2,
		Parent = plate,
	})
	local action = UI.Text({
		Name = "ActionText",
		Role = "Heading",
		Weight = "Bold",
		RichText = false,
		TextColor3 = C.Text,
		TextSize = P.ActionTextSize,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 2,
		Parent = plate,
	})

	local bar = UI.ProgressBar({
		Name = "HoldBar",
		Color = accent.Mid,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -P.BarInset),
		Size = UDim2.new(1, -2 * P.Padding, 0, P.BarHeight),
		ZIndex = 2,
		Parent = plate,
	})
	local fill = bar:FindFirstChild("Fill") :: Frame
	fill.ZIndex = 3

	local view: View = {
		prompt = prompt,
		billboard = billboard,
		plate = plate,
		scale = scale,
		keyCap = keyCap,
		keyScale = keyScale,
		keyText = keyText,
		keyImage = keyImage,
		action = action,
		object = object,
		bar = bar,
		fill = fill,
		button = nil,
		inputType = inputType,
		baseScale = 1,
		holding = false,
		holdInput = nil,
		inputWatch = nil,
		fillTween = nil,
		connections = {},
		closed = false,
	}

	setKey(view)
	if inputType == Enum.ProximityPromptInputType.Touch or prompt.ClickablePrompt then
		makeClickable(view)
	end

	-- Parent first so TextBounds are measured, then size to the text.
	billboard.Parent = parent
	local ok, err = pcall(function(): string?
		layout(view)
		return nil
	end)
	if not ok then
		billboard:Destroy()
		error(err, 0)
	end

	return view
end

local function show(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType)
	local existing = views[prompt]
	if existing then
		-- Shown again (e.g. the input type changed): start fresh.
		hide(existing, true)
	end
	local gui = playerGui
	local adornee = adorneeFor(prompt)
	if not gui or not adornee then
		return
	end

	local view = build(prompt, inputType, adornee, gui)
	views[prompt] = view

	local connections = view.connections
	table.insert(connections, prompt.PromptButtonHoldBegan:Connect(function()
		onHoldBegan(view)
	end))
	table.insert(connections, prompt.PromptButtonHoldEnded:Connect(function()
		onHoldEnded(view)
	end))
	table.insert(connections, prompt.Triggered:Connect(function()
		onTriggered(view)
	end))
	table.insert(connections, prompt.TriggerEnded:Connect(function()
		onTriggerEnded(view)
	end))
	table.insert(connections, prompt.Changed:Connect(function(property: string)
		if property == "Enabled" then
			-- Roblox hides a disabled prompt itself; don't wait for it.
			if not prompt.Enabled then
				hide(view)
			end
		elseif property == "KeyboardKeyCode" or property == "GamepadKeyCode" then
			setKey(view)
		elseif property == "ActionText" or property == "ObjectText" or property == "HoldDuration"
			or property == "UIOffset" or property == "AutoLocalize" then
			layout(view)
		end
	end))
	-- The font can finish loading after the first layout.
	table.insert(connections, view.action:GetPropertyChangedSignal("TextBounds"):Connect(function()
		layout(view)
	end))
	table.insert(connections, view.object:GetPropertyChangedSignal("TextBounds"):Connect(function()
		layout(view)
	end))
	table.insert(connections, prompt.AncestryChanged:Connect(function()
		if not prompt:IsDescendantOf(Workspace) then
			hide(view)
		end
	end))

	-- Pop in.
	view.scale.Scale = view.baseScale * P.ShowFromScale
	UI.Tween(view.scale, P.ShowTime, { Scale = view.baseScale }, Enum.EasingStyle.Back)
end

--------------------------------------------------------------------------
-- Style switching
--------------------------------------------------------------------------

local function adopt(instance: Instance)
	if not failed and instance:IsA("ProximityPrompt") then
		instance.Style = Enum.ProximityPromptStyle.Custom
	end
end

--- Something went wrong building our UI: give every prompt back to
--- Roblox's default look rather than leave players unable to interact.
local function fallBackToDefault(err: any)
	if failed then
		return
	end
	failed = true
	warnf("custom prompt UI failed, using Roblox's default prompts: %s", tostring(err))
	for _, view in pairs(views) do
		hide(view, true)
	end
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d:IsA("ProximityPrompt") then
			d.Style = Enum.ProximityPromptStyle.Default
		end
	end
end

--------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------

function PromptController.Start()
	if not Config.UI.CustomPrompts then
		return
	end
	playerGui = localPlayer:WaitForChild("PlayerGui")

	for _, d in ipairs(Workspace:GetDescendants()) do
		adopt(d)
	end
	Workspace.DescendantAdded:Connect(adopt)

	ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType)
		if failed then
			return
		end
		if prompt.Style ~= Enum.ProximityPromptStyle.Custom then
			-- Roblox already drew its own bubble for this one (it appeared
			-- before we could switch it); ours takes over from the next show.
			adopt(prompt)
			return
		end
		local ok, err = pcall(function(): string?
			show(prompt, inputType)
			return nil
		end)
		if not ok then
			fallBackToDefault(err)
		end
	end)
	ProximityPromptService.PromptHidden:Connect(function(prompt: ProximityPrompt)
		local view = views[prompt]
		if view then
			hide(view)
		end
	end)
	-- A click released off the plate still ends the hold it started.
	UserInputService.InputEnded:Connect(function(input: InputObject)
		for _, view in pairs(views) do
			if endsHold(view, input) then
				release(view)
			end
		end
	end)
end

return PromptController
