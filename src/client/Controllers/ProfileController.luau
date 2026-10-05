--!strict
--[[
	ProfileController
	StarterPlayerScripts/Client/Controllers/ProfileController

	Holds the latest profile snapshot the server pushed. Every other UI reads
	from here instead of listening to the remote itself.

	This is DISPLAY data. The client never sends it back and the server never
	trusts anything derived from it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Util"):WaitForChild("Signal"))

local ProfileController = {}

--- Fired as (snapshot, previous) whenever the server pushes a new profile.
ProfileController.Changed = Signal.new()

local current: { [string]: any }? = nil

function ProfileController.Get(): { [string]: any }?
	return current
end

--- Yields until the first snapshot arrives.
function ProfileController.WaitForProfile(): { [string]: any }
	while not current do
		ProfileController.Changed:Wait()
	end
	return current :: { [string]: any }
end

function ProfileController.Start()
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("ProfileUpdated") :: RemoteEvent
	remote.OnClientEvent:Connect(function(snapshot)
		if typeof(snapshot) ~= "table" then
			return
		end
		local previous = current
		current = snapshot
		ProfileController.Changed:Fire(snapshot, previous)
	end)
end

return ProfileController
