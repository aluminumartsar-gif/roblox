local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local ShovelConfig = require(ConfigFolder:WaitForChild("ShovelConfig"))

local ShovelComponent = {}

local TEMPLATE_NAME = "Shovel"
-- Bumped from 4 -> 5 so any tool created before the shovel-tier system is
-- rebuilt on the next character spawn (see DigService.bindCharacterCleanup).
-- This guarantees the player can never end up holding a stale tool that
-- ignores their purchased shovel id.
local TOOL_VERSION = 5
local DEFAULT_GRIP = CFrame.new(0, -0.8, -0.25) * CFrame.Angles(math.rad(-18), 0, 0)
local SHOVEL_ID_ATTRIBUTE = "ShovelId"

ShovelComponent.DEFAULT_GRIP = DEFAULT_GRIP
ShovelComponent.SHOVEL_ID_ATTRIBUTE = SHOVEL_ID_ATTRIBUTE

local function createPart(name: string, size: Vector3, material: Enum.Material, color: Color3)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Material = material
	part.Color = color
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true

	return part
end

local function weldToHandle(handle: BasePart, part: BasePart, offset: CFrame)
	part.CFrame = handle.CFrame * offset

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = part
	weld.Parent = part
end

local function weldTemplatePartsToHandle(tool: Tool, handle: BasePart)
	for _, descendant in tool:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= handle then
			local weld = Instance.new("WeldConstraint")
			weld.Name = "ShovelHandleWeld"
			weld.Part0 = handle
			weld.Part1 = descendant
			weld.Parent = descendant
		end
	end
end

-- Names used in the template imported from Studio. We try these first when
-- repainting a cloned template so each part gets its tier-appropriate paint
-- and material, and fall back to "anything not-the-handle" so even a custom
-- template still recolors cleanly.
local HANDLE_PART_NAME = "Handle"
local BLADE_PART_NAMES = {
	Blade = true,
	BladeNeck = true,
}
local GRIP_PART_NAMES = {
	TopGrip = true,
}

local function applyVisualToTemplate(tool: Tool, visual)
	for _, descendant in tool:GetDescendants() do
		if not descendant:IsA("BasePart") then
			continue
		end

		if descendant.Name == HANDLE_PART_NAME then
			descendant.Color = visual.handleColor
			descendant.Material = visual.handleMaterial
		elseif BLADE_PART_NAMES[descendant.Name] then
			descendant.Color = visual.bladeColor
			descendant.Material = visual.bladeMaterial
		elseif GRIP_PART_NAMES[descendant.Name] then
			descendant.Color = visual.gripColor
			descendant.Material = visual.gripMaterial
		else
			descendant.Color = visual.bladeColor
			descendant.Material = visual.bladeMaterial
		end
	end
end

local function sanitizeTool(tool: Tool, toolName: string, shovelId: string, visual)
	tool.Name = toolName
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = "Dig up brainrots"
	tool.Grip = DEFAULT_GRIP
	tool:SetAttribute("DigToolVersion", TOOL_VERSION)
	tool:SetAttribute(SHOVEL_ID_ATTRIBUTE, shovelId)

	for _, descendant in tool:GetDescendants() do
		if descendant:IsA("BaseScript") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.Massless = true
		end
	end

	applyVisualToTemplate(tool, visual)

	local handle = tool:FindFirstChild("Handle")
	if handle and handle:IsA("BasePart") then
		handle.CanTouch = false
		handle.CanQuery = false
		weldTemplatePartsToHandle(tool, handle)
	end
end

local function cloneTemplate(toolName: string, shovelId: string, visual)
	local template = ReplicatedStorage:FindFirstChild(TEMPLATE_NAME)
	if not template or not template:IsA("Tool") then
		return nil
	end

	local tool = template:Clone()
	sanitizeTool(tool, toolName, shovelId, visual)

	return tool
end

local function buildFromScratch(toolName: string, shovelId: string, visual)
	local tool = Instance.new("Tool")
	tool.Name = toolName
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = "Dig up brainrots"
	tool.Grip = DEFAULT_GRIP
	tool:SetAttribute("DigToolVersion", TOOL_VERSION)
	tool:SetAttribute(SHOVEL_ID_ATTRIBUTE, shovelId)

	local handle = createPart("Handle", Vector3.new(0.24, 3.45, 0.24), visual.handleMaterial, visual.handleColor)
	handle.Parent = tool

	local topGrip = createPart("TopGrip", Vector3.new(0.95, 0.18, 0.18), visual.gripMaterial, visual.gripColor)
	topGrip.Parent = tool

	local neck = createPart("BladeNeck", Vector3.new(0.34, 0.32, 0.34), visual.bladeMaterial, visual.bladeColor)
	neck.Parent = tool

	local blade = createPart("Blade", Vector3.new(0.95, 0.18, 1.18), visual.bladeMaterial, visual.bladeColor)
	blade.Parent = tool

	weldToHandle(handle, topGrip, CFrame.new(0, 1.72, 0) * CFrame.Angles(0, 0, math.rad(90)))
	weldToHandle(handle, neck, CFrame.new(0, -1.7, -0.05))
	weldToHandle(handle, blade, CFrame.new(0, -2.15, -0.28) * CFrame.Angles(math.rad(-12), 0, 0))

	return tool
end

-- Backwards compatible: callers that don't pass a shovelId get the default
-- (Wooden) shovel, which preserves pre-vendor behaviour.
function ShovelComponent.create(toolName: string, shovelId: string?)
	local resolvedId = if ShovelConfig.isKnown(shovelId) then shovelId :: string else ShovelConfig.getDefaultId()
	local visual = ShovelConfig.getVisual(resolvedId)

	local templateTool = cloneTemplate(toolName, resolvedId, visual)
	if templateTool then
		return templateTool
	end

	return buildFromScratch(toolName, resolvedId, visual)
end

function ShovelComponent.isCurrent(tool: Tool)
	return tool:GetAttribute("DigToolVersion") == TOOL_VERSION
end

function ShovelComponent.getShovelId(tool: Tool): string?
	local id = tool:GetAttribute(SHOVEL_ID_ATTRIBUTE)
	if type(id) == "string" then
		return id
	end

	return nil
end

return ShovelComponent
