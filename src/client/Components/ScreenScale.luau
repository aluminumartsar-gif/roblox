--!strict
--[[
	ScreenScale
	StarterPlayerScripts/Client/Components/ScreenScale

	Our own UI (plot panel, buff chips, toasts, steal banners) is sized in
	pixels, which looks right on a monitor and huge on a phone. The STUD kit
	sizes everything relative to the screen instead. ScreenScale adds a
	UIScale to one of our frames so it shrinks and grows with the screen
	height, the same way the kit does. Tunables: Config.UI.ScreenScale.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local ScreenScale = {}

function ScreenScale.Apply(target: GuiObject): UIScale
	local tuning = Config.UI.ScreenScale
	local scale = Instance.new("UIScale")
	scale.Name = "ScreenScale"
	scale.Parent = target

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
			local height = camera.ViewportSize.Y
			scale.Scale = math.clamp(height / tuning.ReferenceHeight, tuning.Min, tuning.Max)
		end
		connection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(update)
		update()
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watch)
	watch()
	return scale
end

return ScreenScale
