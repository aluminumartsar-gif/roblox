--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local IconAssets = require(ConfigFolder:WaitForChild("IconAssets"))

type IconName = IconAssets.IconName

local IconImage = {}

export type IconOptions = {
	name: string?,
	anchorPoint: Vector2?,
	position: UDim2?,
	size: UDim2?,
	zIndex: number?,
	color: Color3?,
	rotation: number?,
	scaleType: Enum.ScaleType?,
}

local function applyOptions(label: ImageLabel, options: IconOptions?)
	if options == nil then
		return
	end

	if options.name ~= nil then
		label.Name = options.name
	end
	if options.anchorPoint ~= nil then
		label.AnchorPoint = options.anchorPoint
	end
	if options.position ~= nil then
		label.Position = options.position
	end
	if options.size ~= nil then
		label.Size = options.size
	end
	if options.zIndex ~= nil then
		label.ZIndex = options.zIndex
	end
	if options.color ~= nil then
		label.ImageColor3 = options.color
	end
	if options.rotation ~= nil then
		label.Rotation = options.rotation
	end
	if options.scaleType ~= nil then
		label.ScaleType = options.scaleType
	end
end

function IconImage.create(icon: IconName, options: IconOptions?): ImageLabel
	local label = Instance.new("ImageLabel")
	label.Name = (options and options.name) or (icon .. "Icon")
	label.BackgroundTransparency = 1
	label.Image = IconAssets[icon]
	label.ScaleType = Enum.ScaleType.Fit
	applyOptions(label, options)

	return label
end

function IconImage.add(parent: Instance, icon: IconName, options: IconOptions?): ImageLabel
	local label = IconImage.create(icon, options)
	label.Parent = parent

	return label
end

function IconImage.createButton(icon: IconName, options: IconOptions?): ImageButton
	local button = Instance.new("ImageButton")
	button.Name = (options and options.name) or (icon .. "Button")
	button.BackgroundTransparency = 1
	button.AutoButtonColor = false
	button.Image = IconAssets[icon]
	button.ScaleType = Enum.ScaleType.Fit
	applyOptions(button :: any, options)

	return button
end

return IconImage
