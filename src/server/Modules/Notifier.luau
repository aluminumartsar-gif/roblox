--!strict
--[[
	Notifier
	ServerScriptService/Server/Modules/Notifier

	Sends a toast to one player or everyone, through the Notify remote.
	Kinds: "Info" | "Success" | "Warning" | "Error".
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Notifier = {}

local remote: RemoteEvent? = nil

local function getRemote(): RemoteEvent
	if not remote then
		remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Notify") :: RemoteEvent
	end
	return remote :: RemoteEvent
end

function Notifier.Send(player: Player, text: string, kind: string?)
	if player.Parent ~= Players then
		return
	end
	getRemote():FireClient(player, text, kind or "Info")
end

function Notifier.SendAll(text: string, kind: string?)
	getRemote():FireAllClients(text, kind or "Info")
end

return Notifier
