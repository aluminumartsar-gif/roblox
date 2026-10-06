local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UtilFolder = Shared:WaitForChild("Util")

return require(UtilFolder:WaitForChild("FormatUtil"))
