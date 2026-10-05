--!strict
--[[
	Icon
	StarterPlayerScripts/Client/Components/Icon

	Makes an ImageLabel for a named icon from Config.Icons.

	  Icon.new("Cash", 28, parent)                         -- 28x28
	  Icon.new("Lock", 22, button, { Position = ... })     -- extra properties

	Unknown names produce an empty (transparent) label and a warning, so a
	typo never breaks a screen.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Icon = {}

function Icon.new(name: string, size: number, parent: Instance?, props: { [string]: any }?): ImageLabel
	local image = Config.Icons[name]
	if not image then
		warn("[SAC/Icon] Unknown icon '" .. tostring(name) .. "'")
	end
	local label = Instance.new("ImageLabel")
	label.Name = "Icon"
	label.BackgroundTransparency = 1
	label.Image = image or ""
	label.ScaleType = Enum.ScaleType.Fit
	label.Size = UDim2.fromOffset(size, size)
	if props then
		for key, value in pairs(props) do
			(label :: any)[key] = value
		end
	end
	label.Parent = parent
	return label
end

--- Puts an icon at the left edge of a text element (button, label) and
--- pads the text so they don't overlap. Returns the icon.
function Icon.addLeft(target: GuiObject, name: string, size: number, inset: number?): ImageLabel
	local gap = inset or 8
	local padding = target:FindFirstChildOfClass("UIPadding")
	if not padding then
		padding = Instance.new("UIPadding")
		padding.Parent = target
	end
	(padding :: UIPadding).PaddingLeft = UDim.new(0, gap + size + 6)
	-- UIPadding shifts children too, so position the icon back into the
	-- padded margin: content starts at gap+size+6, the icon sits at gap.
	return Icon.new(name, size, target, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, -(size + 6), 0.5, 0),
		ZIndex = target.ZIndex + 1,
	})
end

return Icon
