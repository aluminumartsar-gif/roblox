local Players = game:GetService("Players")

local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))

local AdminService = {}

local function isAdmin(player: Player): boolean
	return player.UserId == game.CreatorId
end

local function findPlayerByName(name: string): Player?
	local nameLower = name:lower()
	for _, player in Players:GetPlayers() do
		if player.Name:lower() == nameLower or player.DisplayName:lower() == nameLower then
			return player
		end
	end
	return nil
end

local function onChat(player: Player, message: string)
	if not isAdmin(player) then
		return
	end

	local command, arg = message:match("^:(%S+)%s*(.*)")
	if not command then
		return
	end

	command = command:lower()

	if command == "resetall" then
		local targets = Players:GetPlayers()
		for _, target in targets do
			PlayerDataService.resetPlayer(target)
			print(("[Admin] Reset data for %s"):format(target.Name))
		end
		print(("[Admin] Reset data for %d player(s)"):format(#targets))

	elseif command == "resetdata" then
		local targetName = arg ~= "" and arg or nil
		if not targetName then
			warn("[Admin] Usage: :resetdata <username>")
			return
		end
		local target = findPlayerByName(targetName)
		if not target then
			warn(("[Admin] Player not found: %s"):format(targetName))
			return
		end
		PlayerDataService.resetPlayer(target)
		print(("[Admin] Reset data for %s"):format(target.Name))
	end
end

function AdminService.start()
	Players.PlayerAdded:Connect(function(player)
		player.Chatted:Connect(function(message)
			onChat(player, message)
		end)
	end)

	for _, player in Players:GetPlayers() do
		player.Chatted:Connect(function(message)
			onChat(player, message)
		end)
	end
end

return AdminService
