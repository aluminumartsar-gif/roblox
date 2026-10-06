local CollectionService = game:GetService("CollectionService")
local RunService        = game:GetService("RunService")
local PlayerGUI         = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")

local SCROLLER = {
	Speed   = 40,
	Padding = 0,
}

local function applyScroller(scrollFrame: ScrollingFrame)
	if not scrollFrame:IsDescendantOf(PlayerGUI) then return end
	scrollFrame.ScrollingEnabled = false

	local originals: { GuiObject } = {}
	for _, child in scrollFrame:GetChildren() do
		if child:IsA("GuiObject") then
			table.insert(originals, child)
		end
	end
	if #originals == 0 then return end

	local totalWidth = 0
	for _, item in originals do
		totalWidth += item.AbsoluteSize.X + SCROLLER.Padding
	end

	for _, item in originals do
		local clone  = item:Clone()
		clone.Position = UDim2.fromOffset(item.AbsolutePosition.X + totalWidth, item.AbsolutePosition.Y)
		clone.Parent   = scrollFrame
	end

	scrollFrame.CanvasSize     = UDim2.fromOffset(totalWidth * 2, 0)
	scrollFrame.CanvasPosition = Vector2.new(0, 0)

	RunService.RenderStepped:Connect(function(dt: number)
		local newX = scrollFrame.CanvasPosition.X + SCROLLER.Speed * dt
		if newX >= totalWidth then
			newX -= totalWidth
		end
		scrollFrame.CanvasPosition = Vector2.new(newX, 0)
	end)
end

for _, scroller in CollectionService:GetTagged("UIScroller") do
	applyScroller(scroller)
end
CollectionService:GetInstanceAddedSignal("UIScroller"):Connect(applyScroller)

return {}
