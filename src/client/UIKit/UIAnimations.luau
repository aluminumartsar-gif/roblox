local CollectionService = game:GetService("CollectionService")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")
local PlayerGUI         = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")

local BUTTON = {
	HoverScale   = 1.05,
	PressScale   = 0.95,
	HoverSpeed   = 0.15,
	PressSpeed   = 0.08,
	ReleaseSpeed = 0.12,
}

local ALERT = {
	Angle      = 20,
	SwingSpeed = 0.35,
	PauseTime  = 0.4,
}

local FLARE = {
	RotationSpeed = 10,
}

local FLOAT = {
	Angle      = 6,
	SwingSpeed = 2.0,
	PulseScale = 1.06,
	PulseSpeed = 2.0,
}

local SHIMMER = {
	SwipeSpeed = 0.6,
	PauseTime  = 2.5,
}

local GRADIENT_MOVE = {
	Speed  = 1.5,
	Easing = 2.0,
}

local TWEEN_INFO = {
	Hover        = TweenInfo.new(BUTTON.HoverSpeed,      Enum.EasingStyle.Quad,   Enum.EasingDirection.Out),
	Press        = TweenInfo.new(BUTTON.PressSpeed,      Enum.EasingStyle.Quad,   Enum.EasingDirection.Out),
	Release      = TweenInfo.new(BUTTON.ReleaseSpeed,    Enum.EasingStyle.Quad,   Enum.EasingDirection.Out),
	Swing        = TweenInfo.new(ALERT.SwingSpeed,       Enum.EasingStyle.Sine,   Enum.EasingDirection.InOut),
	Center       = TweenInfo.new(ALERT.SwingSpeed * 0.5, Enum.EasingStyle.Sine,   Enum.EasingDirection.Out),
	Flare        = TweenInfo.new(FLARE.RotationSpeed,    Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1, false, 0),
	Sway         = TweenInfo.new(FLOAT.SwingSpeed,       Enum.EasingStyle.Sine,   Enum.EasingDirection.InOut),
	Pulse        = TweenInfo.new(FLOAT.PulseSpeed,       Enum.EasingStyle.Sine,   Enum.EasingDirection.InOut),
	ShimmerSweep = TweenInfo.new(SHIMMER.SwipeSpeed,     Enum.EasingStyle.Quad,   Enum.EasingDirection.InOut),
}

local function saveOriginalSize(element: GuiObject)
	element:SetAttribute("OriginalSize_XS", element.Size.X.Scale)
	element:SetAttribute("OriginalSize_XO", element.Size.X.Offset)
	element:SetAttribute("OriginalSize_YS", element.Size.Y.Scale)
	element:SetAttribute("OriginalSize_YO", element.Size.Y.Offset)
end

local function getOriginalSize(element: GuiObject): UDim2
	return UDim2.new(
		element:GetAttribute("OriginalSize_XS"),
		element:GetAttribute("OriginalSize_XO"),
		element:GetAttribute("OriginalSize_YS"),
		element:GetAttribute("OriginalSize_YO")
	)
end

local function scaleSize(original: UDim2, factor: number): UDim2
	return UDim2.new(
		original.X.Scale  * factor,
		original.X.Offset * factor,
		original.Y.Scale  * factor,
		original.Y.Offset * factor
	)
end

local STABLE_WRAP_ATTR = "UIButtonStableHoverWrapped"
local INNER_BUTTON_NAME = "__UIButtonInner"

local function tweenSize(element: GuiObject, tweenInfo: TweenInfo, targetSize: UDim2)
	TweenService:Create(element, tweenInfo, { Size = targetSize }):Play()
end

local function tweenUiScale(scale: UIScale, tweenInfo: TweenInfo, target: number)
	TweenService:Create(scale, tweenInfo, { Scale = target }):Play()
end

-- UIListLayout (and sibling UILayout siblings) reallocates siblings when element
-- Size changes. Keep a fixed-size slot under the layout and tween UIScale inside.
local function parentUsesUILayout(button: GuiObject): boolean
	local host = button.Parent
	if not host then
		return false
	end
	for _, child in host:GetChildren() do
		if child:IsA("UILayout") then
			return true
		end
	end
	return false
end

-- Move layout-only children off the clickable before it becomes percentage-sized in the slot.
-- Otherwise UIList/UIFlex may treat the Frame slot differently than the tagged GuiButton did.
local function transplantLayoutSizingGuides(from: GuiButton, to: GuiObject)
	for _, ch in from:GetChildren() do
		if
			ch:IsA("UIPadding")
			or ch:IsA("UISizeConstraint")
			or ch:IsA("UIAspectRatioConstraint")
			or ch.ClassName == "UIFlexItem"
		then
			ch.Parent = to
		end
	end
end

local function installStableScaledHover(button: GuiButton): UIScale
	local existingScale = button:FindFirstChild("HoverUIScale")
	if existingScale and existingScale:IsA("UIScale") then
		return existingScale
	end

	local outerName = button.Name
	local slotParent = button.Parent
	assert(slotParent, "UIButton.Parent is nil")

	local slot = Instance.new("Frame")
	slot.BackgroundTransparency = 1
	slot.BorderSizePixel = 0
	slot.Name = outerName
	slot.Visible = button.Visible
	slot.LayoutOrder = button.LayoutOrder
	slot.ZIndex = button.ZIndex

	transplantLayoutSizingGuides(button, slot)

	slot.AutomaticSize = button.AutomaticSize
	slot.Size = button.Size

	button.AutomaticSize = Enum.AutomaticSize.None
	button.Size = UDim2.fromScale(1, 1)

	button.Name = INNER_BUTTON_NAME
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.Position = UDim2.fromScale(0.5, 0.5)

	button.Parent = slot
	slot.Parent = slotParent

	button:GetPropertyChangedSignal("Visible"):Connect(function()
		slot.Visible = button.Visible
	end)

	local scale = Instance.new("UIScale")
	scale.Name = "HoverUIScale"
	scale.Scale = 1
	scale.Parent = button

	button:SetAttribute(STABLE_WRAP_ATTR, true)

	return scale
end

local function applyBoundaryClipping(element: GuiObject, container: GuiObject)
	RunService.RenderStepped:Connect(function()
		local elemPos  = element.AbsolutePosition
		local elemSize = element.AbsoluteSize
		local contPos  = container.AbsolutePosition
		local contSize = container.AbsoluteSize

		element.Visible = not (
			elemPos.X + elemSize.X < contPos.X
			or elemPos.X > contPos.X + contSize.X
			or elemPos.Y + elemSize.Y < contPos.Y
			or elemPos.Y > contPos.Y + contSize.Y
		)
	end)
end

local function findClippingAncestor(element: GuiObject): GuiObject?
	local ancestor = element.Parent
	while ancestor do
		if ancestor:IsA("GuiObject") and ancestor.ClipsDescendants then
			return ancestor
		end
		ancestor = ancestor.Parent
	end
	return nil
end

local function applyButton(button: GuiButton)
	if not button:IsDescendantOf(PlayerGUI) then return end

	local useScaledHover = parentUsesUILayout(button)
	local hoverScaleUi: UIScale? = nil
	if useScaledHover then
		hoverScaleUi = installStableScaledHover(button)
	else
		saveOriginalSize(button)
	end

	local isPressed = false
	local isHovered = false

	button.MouseEnter:Connect(function()
		isHovered = true
		if isPressed then return end
		if hoverScaleUi then
			tweenUiScale(hoverScaleUi, TWEEN_INFO.Hover, BUTTON.HoverScale)
		else
			tweenSize(button, TWEEN_INFO.Hover, scaleSize(getOriginalSize(button), BUTTON.HoverScale))
		end
	end)

	button.MouseLeave:Connect(function()
		isHovered = false
		if isPressed then return end
		if hoverScaleUi then
			tweenUiScale(hoverScaleUi, TWEEN_INFO.Hover, 1)
		else
			tweenSize(button, TWEEN_INFO.Hover, getOriginalSize(button))
		end
	end)

	button.MouseButton1Down:Connect(function()
		isPressed = true
		if hoverScaleUi then
			tweenUiScale(hoverScaleUi, TWEEN_INFO.Press, BUTTON.PressScale)
		else
			tweenSize(button, TWEEN_INFO.Press, scaleSize(getOriginalSize(button), BUTTON.PressScale))
		end
		game.SoundService.Button_Pressed_Sound:Play()
	end)

	button.MouseButton1Up:Connect(function()
		isPressed = false
		local targetFac = if isHovered then BUTTON.HoverScale else 1
		if hoverScaleUi then
			tweenUiScale(hoverScaleUi, TWEEN_INFO.Release, targetFac)
		else
			tweenSize(button, TWEEN_INFO.Release, scaleSize(getOriginalSize(button), targetFac))
		end
	end)
end

local function applyAlert(image: GuiObject)
	if not image:IsDescendantOf(PlayerGUI) then return end
	local clippingAncestor = findClippingAncestor(image)
	if clippingAncestor then applyBoundaryClipping(image, clippingAncestor) end

	local function swing()
		local swingRight  = TweenService:Create(image, TWEEN_INFO.Swing,  { Rotation =  ALERT.Angle })
		local swingLeft   = TweenService:Create(image, TWEEN_INFO.Swing,  { Rotation = -ALERT.Angle })
		local swingCenter = TweenService:Create(image, TWEEN_INFO.Center, { Rotation = 0 })

		swingRight:Play()
		swingRight.Completed:Connect(function()
			swingLeft:Play()
			swingLeft.Completed:Connect(function()
				swingCenter:Play()
				swingCenter.Completed:Connect(function()
					task.wait(ALERT.PauseTime)
					swing()
				end)
			end)
		end)
	end
	swing()
end

local function applyFlare(image: GuiObject)
	if not image:IsDescendantOf(PlayerGUI) then return end
	local clippingAncestor = findClippingAncestor(image)
	if clippingAncestor then applyBoundaryClipping(image, clippingAncestor) end
	TweenService:Create(image, TWEEN_INFO.Flare, { Rotation = 360 }):Play()
end

local function applyFloat(image: GuiObject)
	if not image:IsDescendantOf(PlayerGUI) then return end
	saveOriginalSize(image)
	local original = getOriginalSize(image)
	local clippingAncestor = findClippingAncestor(image)
	if clippingAncestor then applyBoundaryClipping(image, clippingAncestor) end

	local function sway()
		local swayRight = TweenService:Create(image, TWEEN_INFO.Sway, { Rotation =  FLOAT.Angle })
		local swayLeft  = TweenService:Create(image, TWEEN_INFO.Sway, { Rotation = -FLOAT.Angle })
		swayRight:Play()
		swayRight.Completed:Connect(function()
			swayLeft:Play()
			swayLeft.Completed:Connect(sway)
		end)
	end

	local function pulse()
		local pulseOut = TweenService:Create(image, TWEEN_INFO.Pulse, { Size = scaleSize(original, FLOAT.PulseScale) })
		local pulseIn  = TweenService:Create(image, TWEEN_INFO.Pulse, { Size = original })
		pulseOut:Play()
		pulseOut.Completed:Connect(function()
			pulseIn:Play()
			pulseIn.Completed:Connect(pulse)
		end)
	end

	sway()
	pulse()
end

local function applyShimmer(stroke: UIStroke)
	if not stroke:IsDescendantOf(PlayerGUI) then return end
	local gradient = stroke:FindFirstChildOfClass("UIGradient")
	if not gradient then
		warn("UIShimmer: No UIGradient found inside UIStroke on " .. stroke.Parent.Name)
		return
	end

	local function sweep()
		gradient.Offset = Vector2.new(-1, 0)
		local sweepTween = TweenService:Create(gradient, TWEEN_INFO.ShimmerSweep, { Offset = Vector2.new(1, 0) })
		sweepTween:Play()
		sweepTween.Completed:Connect(function()
			task.wait(SHIMMER.PauseTime)
			sweep()
		end)
	end
	sweep()
end

local function applyGradientMove(gradient: UIGradient)
	if not gradient:IsDescendantOf(PlayerGUI) then return end
	local offset = 0
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function(dt: number)
		if not gradient.Parent then
			connection:Disconnect()
			return
		end
		offset -= GRADIENT_MOVE.Speed * dt
		if offset <= -1 then
			offset += 2
		end
		gradient.Offset = Vector2.new(0, offset)
	end)
end

local tags = {
	{ name = "UIButton",       fn = applyButton       },
	{ name = "UIAlert",        fn = applyAlert        },
	{ name = "UIFlare",        fn = applyFlare        },
	{ name = "UIFloat",        fn = applyFloat        },
	{ name = "UIShimmer",      fn = applyShimmer      },
	{ name = "UIGradientMove", fn = applyGradientMove },
}

for _, tag in tags do
	for _, element in CollectionService:GetTagged(tag.name) do
		tag.fn(element)
	end
	CollectionService:GetInstanceAddedSignal(tag.name):Connect(tag.fn)
end

return {}
