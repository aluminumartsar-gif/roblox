--!strict
--[[
	UI
	StarterPlayerScripts/Client/Components/UI

	Builders for the "campfire field kit" look (colours and fonts come from
	Components/Theme, which reads Config.UI.Theme). Every screen in the game
	is made from these, so they all match.

	GENERIC
	  UI.new(className, props, children?)     -- any instance; props.Parent is set last
	  UI.Corner(px?) / UI.Stroke(props?) / UI.Padding(all | {Top,Right,Bottom,Left})
	  UI.List(props?) / UI.Grid(props?) / UI.Gradient(colorSequence, rotation?)
	  UI.Tween(instance, seconds, props, style?, direction?) -> Tween

	TEXT
	  UI.Text(props)        -- TextLabel. props.Role = "Display"|"Heading"|"Body"|"Notes"|"Mono",
	                        -- props.Weight = "Regular"|"Medium"|"SemiBold"|"Bold"
	  UI.Title(text, size, props?)   -- big horror title with a burnt ember edge

	SURFACES
	  UI.Panel(props)       -- charred-wood window body (props.Rivets = true for corner nails)
	  UI.Card(props)        -- raised card; props.Accent = Color3 draws a top strip
	  UI.Inset(props)       -- sunken well (lists, bar tracks, inputs)
	  UI.Paper(props)       -- field-journal paper (Codex, notes)
	  UI.Divider(props?)    -- thin rule that fades at both ends

	CONTROLS
	  UI.Button(props)      -- props: Text, Variant ("Primary"|"Secondary"|"Danger"|"Cash"|
	                        --   "Moon"|"Ghost"), Icon, IconSize, TextSize, OnClick, Uppercase
	  UI.SetButtonText(button, text) / UI.SetButtonVariant(button, variant)
	  UI.SetButtonEnabled(button, enabled)    -- greys it out (visual only; handlers still run)
	  UI.SetButtonIcon(button, iconName?)
	  UI.IconButton(props)  -- square HUD tile: Icon, Label, Size, OnClick
	  UI.SetBadge(target, shown, text?)       -- red "!" bubble on any GuiObject
	  UI.Tab(props) / UI.SetTabSelected(tab, selected)
	  UI.Input(props)       -- themed TextBox in a well; returns (frame, textBox)

	DISPLAY
	  UI.Icon(name, size, props?)              -- tinted glyph (Components/Icon)
	  UI.ProgressBar(props) / UI.SetProgress(bar, alpha, seconds?)
	  UI.Pill(props) / UI.SetPill(pill, text?, color?)
	  UI.ScrollList(props)  -- themed ScrollingFrame with a list or grid layout and
	                        -- automatic canvas size
	  UI.Scale(frame)       -- shrink/grow pixel-sized UI with the screen (ScreenScale)

	Buttons are TextButtons with Text = "" whose visible text is the child
	TextLabel "Label" (inside "Content"). SoundController gives every button
	its click sound automatically.
]]

local TweenService = game:GetService("TweenService")

local Components = script.Parent
local Theme = require(Components:WaitForChild("Theme"))
local Icon = require(Components:WaitForChild("Icon"))
local ScreenScale = require(Components:WaitForChild("ScreenScale"))

local C = Theme.Colors
local T = Theme.Tuning

local UI = {}

--------------------------------------------------------------------------
-- Generic
--------------------------------------------------------------------------

function UI.new(className: string, props: { [string]: any }?, children: { any }?): any
	local instance = Instance.new(className)
	local parent = nil
	if props then
		for key, value in pairs(props) do
			if key == "Parent" then
				parent = value
			else
				(instance :: any)[key] = value
			end
		end
	end
	if children then
		for _, child in ipairs(children) do
			child.Parent = instance
		end
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

function UI.Corner(px: number?): any
	return UI.new("UICorner", { CornerRadius = UDim.new(0, px or T.Corner) })
end

function UI.Stroke(props: { [string]: any }?): any
	local stroke = UI.new("UIStroke", {
		Color = C.Edge,
		Thickness = 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		LineJoinMode = Enum.LineJoinMode.Round,
	})
	if props then
		for key, value in pairs(props) do
			(stroke :: any)[key] = value
		end
	end
	return stroke
end

function UI.Padding(padding: any): any
	if type(padding) == "number" then
		local u = UDim.new(0, padding)
		return UI.new("UIPadding", { PaddingTop = u, PaddingBottom = u, PaddingLeft = u, PaddingRight = u })
	end
	local p: { [string]: any } = padding or {}
	return UI.new("UIPadding", {
		PaddingTop = UDim.new(0, p.Top or 0),
		PaddingRight = UDim.new(0, p.Right or 0),
		PaddingBottom = UDim.new(0, p.Bottom or 0),
		PaddingLeft = UDim.new(0, p.Left or 0),
	})
end

function UI.List(props: { [string]: any }?): any
	local layout = UI.new("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		FillDirection = Enum.FillDirection.Vertical,
		Padding = UDim.new(0, 8),
	})
	if props then
		for key, value in pairs(props) do
			if key == "Padding" and type(value) == "number" then
				layout.Padding = UDim.new(0, value)
			else
				(layout :: any)[key] = value
			end
		end
	end
	return layout
end

function UI.Grid(props: { [string]: any }?): any
	local layout = UI.new("UIGridLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		CellSize = UDim2.fromOffset(120, 140),
		CellPadding = UDim2.fromOffset(10, 10),
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
	})
	if props then
		for key, value in pairs(props) do
			(layout :: any)[key] = value
		end
	end
	return layout
end

function UI.Gradient(color: ColorSequence, rotation: number?): any
	return UI.new("UIGradient", { Color = color, Rotation = rotation or 90 })
end

function UI.Tween(instance: Instance, seconds: number, props: { [string]: any }, style: Enum.EasingStyle?, direction: Enum.EasingDirection?): Tween
	local tween = TweenService:Create(
		instance,
		TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out),
		props
	)
	tween:Play()
	return tween
end

function UI.Scale(frame: GuiObject): UIScale
	return ScreenScale.Apply(frame)
end

--------------------------------------------------------------------------
-- Text
--------------------------------------------------------------------------

local function applyProps(instance: Instance, props: { [string]: any }?, skip: { [string]: boolean }?)
	if not props then
		return
	end
	local parent = nil
	for key, value in pairs(props) do
		if key == "Parent" then
			parent = value
		elseif not (skip and skip[key]) then
			(instance :: any)[key] = value
		end
	end
	if parent then
		instance.Parent = parent
	end
end

local TEXT_SKIP = { Role = true, Weight = true, Accent = true, Rivets = true }

function UI.Text(props: { [string]: any }?): TextLabel
	local p: { [string]: any } = props or {}
	local label = UI.new("TextLabel", {
		Name = "Text",
		BackgroundTransparency = 1,
		FontFace = Theme.Font(p.Role or "Body", p.Weight or (if p.Role == "Heading" then "Bold" else nil)),
		TextColor3 = C.Text,
		TextSize = 18,
		RichText = true,
		Size = UDim2.new(1, 0, 0, 22),
		TextWrapped = false,
	})
	applyProps(label, p, TEXT_SKIP)
	return label
end

--- Big horror-face title with a burnt ember edge. Display font is only
--- legible large: keep size >= 28.
function UI.Title(text: string, size: number, props: { [string]: any }?): TextLabel
	local label = UI.Text({
		Name = "Title",
		Role = "Display",
		Text = text,
		TextSize = size,
		Size = UDim2.new(1, 0, 0, size + 6),
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	UI.Stroke({
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Color = C.EmberDeep,
		Thickness = 2,
		Transparency = 0.15,
		Parent = label,
	})
	applyProps(label, props, TEXT_SKIP)
	return label
end

--------------------------------------------------------------------------
-- Surfaces
--------------------------------------------------------------------------

local function addRivets(frame: GuiObject)
	for i, corner in ipairs({ Vector2.new(0, 0), Vector2.new(1, 0), Vector2.new(0, 1), Vector2.new(1, 1) }) do
		local inset = 7
		UI.new("Frame", {
			Name = "Rivet" .. i,
			AnchorPoint = corner,
			Position = UDim2.new(corner.X, if corner.X == 0 then inset else -inset, corner.Y, if corner.Y == 0 then inset else -inset),
			Size = UDim2.fromOffset(6, 6),
			BackgroundColor3 = C.EdgeBright,
			BorderSizePixel = 0,
			ZIndex = frame.ZIndex + 1,
			Parent = frame,
		}, {
			UI.Corner(3),
			UI.Stroke({ Color = C.Shadow, Transparency = 0.3 }),
		})
	end
end

function UI.Panel(props: { [string]: any }?): Frame
	local p: { [string]: any } = props or {}
	local frame = UI.new("Frame", {
		Name = "Panel",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
	}, {
		UI.Corner(T.Corner),
		UI.Gradient(Theme.Sequence(C.PanelTop, C.Panel, C.Panel), 90),
		UI.Stroke({ Color = C.Edge, Thickness = T.Stroke }),
	})
	if p.Rivets then
		addRivets(frame)
	end
	applyProps(frame, p, TEXT_SKIP)
	return frame
end

function UI.Card(props: { [string]: any }?): Frame
	local p: { [string]: any } = props or {}
	local frame = UI.new("Frame", {
		Name = "Card",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(120, 140),
	}, {
		UI.Corner(T.CornerSmall),
		UI.Gradient(Theme.Sequence(C.RaisedTop, C.Raised), 90),
		UI.Stroke({ Color = C.Edge }),
	})
	if p.Accent then
		UI.new("Frame", {
			Name = "Accent",
			BackgroundColor3 = p.Accent,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 3),
			ZIndex = (p.ZIndex or 1) + 1,
			Parent = frame,
		}, { UI.Corner(T.CornerSmall) })
	end
	applyProps(frame, p, TEXT_SKIP)
	return frame
end

function UI.Inset(props: { [string]: any }?): Frame
	local frame = UI.new("Frame", {
		Name = "Inset",
		BackgroundColor3 = C.Inset,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
	}, {
		UI.Corner(T.CornerSmall),
		UI.Stroke({ Color = C.Edge, Transparency = 0.45 }),
	})
	applyProps(frame, props, TEXT_SKIP)
	return frame
end

function UI.Paper(props: { [string]: any }?): Frame
	local frame = UI.new("Frame", {
		Name = "Paper",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(160, 200),
	}, {
		UI.Corner(2),
		UI.Gradient(Theme.Sequence(C.Paper, C.PaperDark), 100),
		UI.Stroke({ Color = C.Ink, Transparency = 0.55 }),
	})
	applyProps(frame, props, TEXT_SKIP)
	return frame
end

function UI.Divider(props: { [string]: any }?): Frame
	local p: { [string]: any } = props or {}
	local frame = UI.new("Frame", {
		Name = "Divider",
		BackgroundColor3 = p.Color or C.Edge,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 1),
	}, {
		UI.new("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.15, 0),
				NumberSequenceKeypoint.new(0.85, 0),
				NumberSequenceKeypoint.new(1, 1),
			}),
		}),
	})
	applyProps(frame, p, { Color = true })
	return frame
end

--------------------------------------------------------------------------
-- Icons
--------------------------------------------------------------------------

function UI.Icon(name: string, size: number, props: { [string]: any }?): ImageLabel
	local parent = props and props.Parent
	local label = Icon.new(name, size, nil, nil)
	applyProps(label, props, { Parent = true })
	if parent then
		label.Parent = parent
	end
	return label
end

--------------------------------------------------------------------------
-- Buttons
--------------------------------------------------------------------------

type Variant = {
	Top: Color3,
	Mid: Color3,
	Bottom: Color3,
	Edge: Color3,
	Text: Color3,
	Sheen: number,
	Transparency: number?,
	EdgeTransparency: number?,
}

local function deepen(color: Color3, amount: number): Color3
	return color:Lerp(Color3.new(0, 0, 0), amount)
end

local VARIANTS: { [string]: Variant } = {
	Primary = { Top = C.EmberBright, Mid = C.Ember, Bottom = C.EmberDeep, Edge = deepen(C.EmberDeep, 0.35), Text = C.TextOnAccent, Sheen = 0.5 },
	Secondary = { Top = C.RaisedTop, Mid = C.Raised, Bottom = C.Panel, Edge = C.Edge, Text = C.Text, Sheen = 0.88 },
	Danger = { Top = C.BloodBright, Mid = C.Blood, Bottom = C.BloodDeep, Edge = deepen(C.BloodDeep, 0.3), Text = C.Text, Sheen = 0.62 },
	Cash = { Top = C.MossBright, Mid = C.Moss, Bottom = C.MossDeep, Edge = deepen(C.MossDeep, 0.35), Text = C.TextOnAccent, Sheen = 0.5 },
	Moon = { Top = C.MoonBright, Mid = C.Moon, Bottom = C.MoonDeep, Edge = deepen(C.MoonDeep, 0.35), Text = C.TextOnAccent, Sheen = 0.55 },
	Ghost = { Top = C.Panel, Mid = C.Panel, Bottom = C.Inset, Edge = C.Edge, Text = C.TextDim, Sheen = 1, Transparency = 0.35 },
	Disabled = { Top = C.Inset, Mid = C.Inset, Bottom = C.Inset, Edge = C.Edge, Text = C.TextFaint, Sheen = 1, EdgeTransparency = 0.4 },
}

UI.Variants = VARIANTS

local function paint(button: GuiButton)
	local enabled = button:GetAttribute("Enabled") ~= false
	local name: string = if enabled then ((button:GetAttribute("Variant") :: string?) or "Primary") else "Disabled"
	local v = VARIANTS[name] or VARIANTS.Primary
	local fill = button:FindFirstChild("Fill") :: UIGradient?
	if fill then
		fill.Color = Theme.Sequence(v.Top, v.Bottom, v.Mid)
	end
	button.BackgroundTransparency = v.Transparency or 0
	local edge = button:FindFirstChild("Edge") :: UIStroke?
	if edge then
		edge.Color = v.Edge
		edge.Transparency = v.EdgeTransparency or 0
	end
	local sheen = button:FindFirstChild("Sheen") :: Frame?
	if sheen then
		sheen.BackgroundTransparency = v.Sheen
	end
	local content = button:FindFirstChild("Content")
	if content then
		local label = content:FindFirstChild("Label") :: TextLabel?
		if label then
			label.TextColor3 = v.Text
		end
		local icon = content:FindFirstChild("Icon") :: ImageLabel?
		if icon then
			icon.ImageColor3 = v.Text
		end
	end
end

local function hookPress(button: GuiButton, scale: UIScale, onHover: ((boolean) -> ())?)
	local hoverTime = T.HoverTime
	button.MouseEnter:Connect(function()
		if onHover then
			onHover(true)
		end
	end)
	button.MouseLeave:Connect(function()
		if onHover then
			onHover(false)
		end
		UI.Tween(scale, hoverTime, { Scale = 1 })
	end)
	button.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			UI.Tween(scale, hoverTime * 0.6, { Scale = T.ButtonPressScale })
		end
	end)
	button.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			UI.Tween(scale, hoverTime, { Scale = 1 }, Enum.EasingStyle.Back)
		end
	end)
end

local BUTTON_SKIP = {
	Text = true, Variant = true, Icon = true, IconSize = true, TextSize = true,
	OnClick = true, Uppercase = true, Role = true, Weight = true,
}

function UI.Button(props: { [string]: any }): TextButton
	local p = props
	local button = UI.new("TextButton", {
		Name = "Button",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(160, 44),
		ClipsDescendants = false,
	}) :: TextButton
	button:SetAttribute("Variant", p.Variant or "Primary")
	button:SetAttribute("Enabled", true)
	button:SetAttribute("Uppercase", p.Uppercase ~= false)

	UI.Corner(T.Corner).Parent = button
	UI.new("UIGradient", { Name = "Fill", Rotation = 90, Parent = button })
	UI.Stroke({ Name = "Edge", Thickness = 1.5, Parent = button })
	local scale = UI.new("UIScale", { Name = "Press", Parent = button })
	UI.new("Frame", {
		Name = "Sheen",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Position = UDim2.new(0, 5, 0, 2),
		Size = UDim2.new(1, -10, 0, 1),
		Parent = button,
	})

	local content = UI.new("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = button,
	}, {
		UI.List({
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = 6,
		}),
		UI.Padding({ Left = 8, Right = 8 }),
	})
	if p.Icon then
		local size = p.IconSize or math.floor((p.TextSize or 20) * 1.15)
		UI.Icon(p.Icon, size, { LayoutOrder = 1, Parent = content })
	end
	local text = tostring(p.Text or "")
	UI.Text({
		Name = "Label",
		Role = p.Role or "Heading",
		Weight = p.Weight or "Bold",
		Text = if p.Uppercase ~= false then string.upper(text) else text,
		TextSize = p.TextSize or 20,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		LayoutOrder = 2,
		Parent = content,
	})

	applyProps(button, p, BUTTON_SKIP)
	paint(button)

	local edge = button:FindFirstChild("Edge") :: UIStroke
	hookPress(button, scale, function(hovering)
		if button:GetAttribute("Enabled") == false then
			return
		end
		if hovering then
			edge.Color = C.EmberBright
		else
			paint(button)
		end
	end)

	if p.OnClick then
		button.Activated:Connect(p.OnClick)
	end
	return button
end

function UI.SetButtonText(button: Instance?, text: string)
	if not button then
		return
	end
	local content = button:FindFirstChild("Content")
	local label = content and content:FindFirstChild("Label") :: TextLabel?
	if label then
		label.Text = if button:GetAttribute("Uppercase") ~= false then string.upper(text) else text
	end
end

function UI.SetButtonVariant(button: Instance?, variant: string)
	if button and button:IsA("GuiButton") then
		button:SetAttribute("Variant", variant)
		paint(button)
	end
end

--- Greys a button out (or restores it). Visual only, like the old kit
--- helper: Activated still fires, so handlers check state themselves.
function UI.SetButtonEnabled(button: Instance?, enabled: boolean)
	if button and button:IsA("GuiButton") then
		button:SetAttribute("Enabled", enabled)
		paint(button)
	end
end

function UI.SetButtonIcon(button: Instance?, iconName: string?)
	if not button then
		return
	end
	local content = button:FindFirstChild("Content")
	if not content then
		return
	end
	local icon = content:FindFirstChild("Icon") :: ImageLabel?
	if not iconName then
		if icon then
			icon:Destroy()
		end
		return
	end
	if icon then
		Icon.set(icon, iconName)
	else
		local label = content:FindFirstChild("Label") :: TextLabel?
		local size = if label then math.floor(label.TextSize * 1.15) else 22
		UI.Icon(iconName, size, { LayoutOrder = 1, Parent = content })
		paint(button :: any)
	end
end

--- Square HUD tile: an icon with a caption under it.
--- props: Icon, Label, Size (px, default 60), OnClick, plus any property.
function UI.IconButton(props: { [string]: any }): TextButton
	local p = props
	local size = p.Size or 60
	local tile = UI.new("TextButton", {
		Name = "IconButton",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(size, size),
	}) :: TextButton
	UI.Corner(8).Parent = tile
	UI.Gradient(Theme.Sequence(C.RaisedTop, C.Panel), 90).Parent = tile
	local edge = UI.Stroke({ Name = "Edge", Color = C.Edge, Thickness = 1.5, Parent = tile })
	local scale = UI.new("UIScale", { Name = "Press", Parent = tile })

	local iconSize = math.floor(size * 0.5)
	local icon = UI.Icon(p.Icon or "Star", iconSize, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, math.floor(size * 0.12)),
		Parent = tile,
	})
	local caption = UI.Text({
		Name = "Caption",
		Role = "Heading",
		Weight = "Bold",
		Text = string.upper(p.Label or ""),
		TextSize = math.max(12, math.floor(size * 0.22)),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -3),
		Size = UDim2.new(1, -4, 0, math.floor(size * 0.24)),
		TextColor3 = C.TextDim,
		Parent = tile,
	})

	hookPress(tile, scale, function(hovering)
		edge.Color = if hovering then C.Ember else C.Edge
		icon.ImageColor3 = if hovering then C.EmberBright else C.Text
		caption.TextColor3 = if hovering then C.Text else C.TextDim
	end)

	applyProps(tile, p, { Icon = true, Label = true, Size = true, OnClick = true })
	if p.OnClick then
		tile.Activated:Connect(p.OnClick)
	end
	return tile
end

--- Red "!" bubble in the top-right corner of target. Pulses while shown.
function UI.SetBadge(target: GuiObject, shown: boolean, text: string?)
	local badge = target:FindFirstChild("Badge") :: Frame?
	if not shown then
		if badge then
			badge.Visible = false
		end
		return
	end
	if not badge then
		local made = UI.new("Frame", {
			Name = "Badge",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(1, -4, 0, 4),
			Size = UDim2.fromOffset(20, 20),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = C.Blood,
			BorderSizePixel = 0,
			ZIndex = target.ZIndex + 5,
			Parent = target,
		}, {
			UI.Corner(10),
			UI.Stroke({ Color = C.BloodDeep, Thickness = 1.5 }),
			UI.Padding({ Left = 6, Right = 6 }),
		}) :: Frame
		UI.Text({
			Name = "Label",
			Role = "Heading",
			Text = "!",
			TextSize = 14,
			Size = UDim2.fromScale(0, 1),
			AutomaticSize = Enum.AutomaticSize.X,
			ZIndex = target.ZIndex + 6,
			Parent = made,
		})
		local pulse = UI.new("UIScale", { Parent = made })
		TweenService:Create(
			pulse,
			TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Scale = 1.15 }
		):Play()
		badge = made
	end
	local b = badge :: Frame
	b.Visible = true
	local label = b:FindFirstChild("Label") :: TextLabel?
	if label then
		label.Text = text or "!"
	end
end

--- A tab (filter / section switch). props: Text, Icon?, Color (accent when
--- selected, default Ember), Bar ("Bottom" | "Left"), TextSize, OnClick.
function UI.Tab(props: { [string]: any }): TextButton
	local p = props
	local tab = UI.new("TextButton", {
		Name = "Tab",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.Raised,
		BackgroundTransparency = 0.6,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(120, 36),
	}) :: TextButton
	tab:SetAttribute("Selected", false)
	UI.Corner(T.CornerSmall).Parent = tab
	UI.Stroke({ Name = "Edge", Color = C.Edge, Transparency = 0.5, Parent = tab })
	local accent = p.Color or C.Ember
	local vertical = p.Bar == "Left"
	UI.new("Frame", {
		Name = "Bar",
		BackgroundColor3 = accent,
		BorderSizePixel = 0,
		AnchorPoint = if vertical then Vector2.new(0, 0.5) else Vector2.new(0.5, 1),
		Position = if vertical then UDim2.new(0, 0, 0.5, 0) else UDim2.new(0.5, 0, 1, 0),
		Size = if vertical then UDim2.new(0, 3, 1, -8) else UDim2.new(1, -10, 0, 3),
		Visible = false,
		Parent = tab,
	}, { UI.Corner(2) })
	local content = UI.new("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = tab,
	}, {
		UI.List({
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = if vertical then Enum.HorizontalAlignment.Left else Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = 6,
		}),
		UI.Padding({ Left = if vertical then 12 else 6, Right = 6 }),
	})
	if p.Icon then
		UI.Icon(p.Icon, p.IconSize or 18, { LayoutOrder = 1, ImageColor3 = C.TextDim, Parent = content })
	end
	UI.Text({
		Name = "Label",
		Role = "Heading",
		Weight = "SemiBold",
		Text = string.upper(tostring(p.Text or "")),
		TextSize = p.TextSize or 18,
		TextColor3 = C.TextDim,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		LayoutOrder = 2,
		Parent = content,
	})
	tab:SetAttribute("AccentColor", accent)
	tab.MouseEnter:Connect(function()
		if not tab:GetAttribute("Selected") then
			tab.BackgroundTransparency = 0.35
		end
	end)
	tab.MouseLeave:Connect(function()
		if not tab:GetAttribute("Selected") then
			tab.BackgroundTransparency = 0.6
		end
	end)
	applyProps(tab, p, { Text = true, Icon = true, IconSize = true, Color = true, Bar = true, TextSize = true, OnClick = true })
	if p.OnClick then
		tab.Activated:Connect(p.OnClick)
	end
	return tab
end

function UI.SetTabSelected(tab: Instance?, selected: boolean)
	if not tab or not tab:IsA("GuiButton") then
		return
	end
	tab:SetAttribute("Selected", selected)
	local accent: Color3 = (tab:GetAttribute("AccentColor") :: Color3?) or C.Ember
	tab.BackgroundTransparency = if selected then 0 else 0.6
	local edge = tab:FindFirstChild("Edge") :: UIStroke?
	if edge then
		edge.Color = if selected then accent else C.Edge
		edge.Transparency = if selected then 0.2 else 0.5
	end
	local bar = tab:FindFirstChild("Bar") :: Frame?
	if bar then
		bar.Visible = selected
	end
	local content = tab:FindFirstChild("Content")
	if content then
		local label = content:FindFirstChild("Label") :: TextLabel?
		if label then
			label.TextColor3 = if selected then C.Text else C.TextDim
		end
		local icon = content:FindFirstChild("Icon") :: ImageLabel?
		if icon then
			icon.ImageColor3 = if selected then accent else C.TextDim
		end
	end
end

--- Themed text box in a sunken well. Returns (frame, textBox).
--- props: PlaceholderText, Icon (default "MagnifyingGlass", false for none),
--- Size, TextSize, plus any frame property.
function UI.Input(props: { [string]: any }): (Frame, TextBox)
	local p = props
	local frame = UI.Inset({ Name = "Input", Size = p.Size or UDim2.fromOffset(220, 36) })
	local stroke = frame:FindFirstChildOfClass("UIStroke") :: UIStroke
	local left = 10
	if p.Icon ~= false then
		UI.Icon(p.Icon or "MagnifyingGlass", 18, {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 10, 0.5, 0),
			ImageColor3 = C.TextFaint,
			Parent = frame,
		})
		left = 36
	end
	local box = UI.new("TextBox", {
		Name = "Box",
		BackgroundTransparency = 1,
		ClearTextOnFocus = false,
		FontFace = Theme.Fonts.Body,
		PlaceholderColor3 = C.TextFaint,
		PlaceholderText = p.PlaceholderText or "",
		Text = "",
		TextColor3 = C.Text,
		TextSize = p.TextSize or 17,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.new(0, left, 0, 0),
		Size = UDim2.new(1, -left - 8, 1, 0),
		Parent = frame,
	}) :: TextBox
	box.Focused:Connect(function()
		stroke.Color = C.Ember
		stroke.Transparency = 0
	end)
	box.FocusLost:Connect(function()
		stroke.Color = C.Edge
		stroke.Transparency = 0.45
	end)
	applyProps(frame, p, { PlaceholderText = true, Icon = true, Size = true, TextSize = true })
	return frame, box
end

--------------------------------------------------------------------------
-- Display
--------------------------------------------------------------------------

--- props: Color (fill, default Ember), Size, Text (optional centred label),
--- TextSize, plus any frame property. The fill is the child "Fill".
function UI.ProgressBar(props: { [string]: any }?): Frame
	local p: { [string]: any } = props or {}
	local color: Color3 = p.Color or C.Ember
	local bar = UI.Inset({ Name = "Bar", Size = p.Size or UDim2.fromOffset(200, 14) })
	local fill = UI.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
		Parent = bar,
	}, {
		UI.Corner(T.CornerSmall),
		UI.Gradient(Theme.Sequence(color:Lerp(Color3.new(1, 1, 1), 0.35), deepen(color, 0.35), color), 90),
	})
	fill:SetAttribute("Alpha", 0)
	if p.Text then
		UI.Text({
			Name = "Label",
			Role = "Heading",
			Text = p.Text,
			TextSize = p.TextSize or 14,
			Size = UDim2.fromScale(1, 1),
			ZIndex = bar.ZIndex + 2,
			Parent = bar,
		})
		UI.Stroke({ ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual, Color = C.Shadow, Transparency = 0.3, Parent = bar:FindFirstChild("Label") })
	end
	applyProps(bar, p, { Color = true, Size = true, Text = true, TextSize = true })
	return bar
end

function UI.SetProgress(bar: Instance?, alpha: number, seconds: number?)
	local fill = bar and bar:FindFirstChild("Fill") :: Frame?
	if not fill then
		return
	end
	local a = math.clamp(alpha, 0, 1)
	fill:SetAttribute("Alpha", a)
	fill.Visible = a > 0
	local goal = UDim2.fromScale(a, 1)
	if seconds and seconds > 0 then
		UI.Tween(fill, seconds, { Size = goal })
	else
		fill.Size = goal
	end
end

--- Small tag ("OWNED", "SOON", a rarity). props: Text, Color (text + edge),
--- Filled (solid background, dark text), TextSize, Height.
function UI.Pill(props: { [string]: any }): Frame
	local p = props
	local color: Color3 = p.Color or C.TextDim
	local height = p.Height or 24
	local pill = UI.new("Frame", {
		Name = "Pill",
		BackgroundColor3 = if p.Filled then color else C.Inset,
		BackgroundTransparency = if p.Filled then 0 else 0.15,
		BorderSizePixel = 0,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, height),
	}, {
		UI.Corner(math.floor(height / 2)),
		UI.Stroke({ Name = "Edge", Color = if p.Filled then deepen(color, 0.4) else color, Transparency = if p.Filled then 0 else 0.35 }),
		UI.Padding({ Left = 9, Right = 9 }),
	})
	pill:SetAttribute("Filled", p.Filled == true)
	UI.Text({
		Name = "Label",
		Role = "Heading",
		Weight = "SemiBold",
		Text = string.upper(tostring(p.Text or "")),
		TextSize = p.TextSize or 14,
		TextColor3 = if p.Filled then C.TextOnAccent else color,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		Parent = pill,
	})
	applyProps(pill, p, { Text = true, Color = true, Filled = true, TextSize = true, Height = true })
	return pill
end

function UI.SetPill(pill: Instance?, text: string?, color: Color3?)
	if not pill then
		return
	end
	local label = pill:FindFirstChild("Label") :: TextLabel?
	if label and text then
		label.Text = string.upper(text)
	end
	if color and pill:IsA("Frame") then
		local filled = pill:GetAttribute("Filled") == true
		local edge = pill:FindFirstChild("Edge") :: UIStroke?
		if filled then
			pill.BackgroundColor3 = color
			if edge then
				edge.Color = deepen(color, 0.4)
			end
		else
			if label then
				label.TextColor3 = color
			end
			if edge then
				edge.Color = color
			end
		end
	end
end

--- Themed scrolling list. props: Layout ("List" | "Grid"), Padding (inner,
--- px), Gap (between items, px), CellSize (grid), Direction ("Y" | "X"),
--- plus any ScrollingFrame property. Canvas grows with the contents.
function UI.ScrollList(props: { [string]: any }?): ScrollingFrame
	local p: { [string]: any } = props or {}
	local horizontal = p.Direction == "X"
	local scroller = UI.new("ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = if horizontal then Enum.AutomaticSize.X else Enum.AutomaticSize.Y,
		ScrollingDirection = if horizontal then Enum.ScrollingDirection.X else Enum.ScrollingDirection.Y,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = C.EdgeBright,
		ScrollBarImageTransparency = 0.2,
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
		HorizontalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
		ElasticBehavior = Enum.ElasticBehavior.WhenScrollable,
	}) :: ScrollingFrame
	local gap = p.Gap or 8
	if p.Layout == "Grid" then
		UI.Grid({
			CellSize = p.CellSize or UDim2.fromOffset(120, 140),
			CellPadding = UDim2.fromOffset(gap, gap),
			FillDirection = if horizontal then Enum.FillDirection.Vertical else Enum.FillDirection.Horizontal,
			Parent = scroller,
		})
	else
		UI.List({
			Padding = gap,
			FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Parent = scroller,
		})
	end
	local pad = p.Padding or 6
	UI.Padding({ Top = pad, Bottom = pad, Left = pad, Right = pad + (if horizontal then 0 else 4) }).Parent = scroller
	applyProps(scroller, p, { Layout = true, Padding = true, Gap = true, CellSize = true, Direction = true })
	return scroller
end

return UI
