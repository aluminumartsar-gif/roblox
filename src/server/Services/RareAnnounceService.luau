local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local RareAnnounceRichText = require(UtilFolder:WaitForChild("RareAnnounceRichText"))
local RareAnnounceConfig = require(ConfigFolder:WaitForChild("RareAnnounceConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))

local RareAnnounceService = {}

local started = false
local channelGlobal: TextChannel? = nil
local rareAnnounceRemote = RemoteRegistry.getRemote(
	RareAnnounceConfig.REMOTE_FOLDER,
	RareAnnounceConfig.RARE_ANNOUNCE_REMOTE
)

type DropLike = {
	brainrotId: string,
	variantId: string?,
	rngDenominator: number?,
	rngText: string?,
}

-- Prefer the engine TextChannels folder when present; otherwise parent to TextChatService so channels still replicate.
local function getAnnounceChannelParent(): Instance
	local existing = TextChatService:FindFirstChild("TextChannels")
	if existing and existing:IsA("Folder") then
		return existing
	end

	local ok, waited = pcall(function()
		return TextChatService:WaitForChild("TextChannels", 20)
	end)
	if ok and waited and waited:IsA("Folder") then
		return waited
	end

	return TextChatService
end

local function getOrCreateChannel(parent: Instance, channelName: string): TextChannel
	local existing = parent:FindFirstChild(channelName)
	if existing and existing:IsA("TextChannel") then
		return existing
	end

	local channel = Instance.new("TextChannel")
	channel.Name = channelName
	channel:SetAttribute("RareAnnounceChannel", true)
	channel.Parent = parent
	return channel
end

local function destroyLegacyRareChannels(parent: Instance)
	for _, legacyName in { "RareHere", "RareGlobal" } do
		local old = parent:FindFirstChild(legacyName)
		if old and old:IsA("TextChannel") then
			old:Destroy()
		end
	end
	local oldLocal = parent:FindFirstChild("Local")
	if oldLocal and oldLocal:IsA("TextChannel") and oldLocal:GetAttribute("RareAnnounceChannel") == true then
		oldLocal:Destroy()
	end
end

-- Never create a second "Here" tab: use the engine spatial channel. Remove any old custom duplicate we made.
local function destroyCustomHereChannelDuplicates()
	local hereName = RareAnnounceConfig.CHANNEL_NAME_HERE
	local function destroyIfOurs(inst: Instance?)
		if
			inst
			and inst:IsA("TextChannel")
			and inst.Name == hereName
			and inst:GetAttribute("RareAnnounceChannel") == true
		then
			inst:Destroy()
		end
	end
	destroyIfOurs(TextChatService:FindFirstChild(hereName))
	local folder = TextChatService:FindFirstChild("TextChannels")
	if folder and folder:IsA("Folder") then
		destroyIfOurs(folder:FindFirstChild(hereName))
	end
end

-- Every `TextChannel` named "Global" under TextChatService becomes a tab — including nested paths.
-- Collapse to a single instance under the canonical parent (fixes duplicate Global tabs).
local function dedupeGlobalAnnounceChannels(canonicalParent: Instance)
	local name = RareAnnounceConfig.CHANNEL_NAME_GLOBAL
	local matches: { TextChannel } = {}
	for _, inst in TextChatService:GetDescendants() do
		if inst:IsA("TextChannel") and inst.Name == name then
			table.insert(matches, inst :: TextChannel)
		end
	end

	if #matches == 0 then
		return
	end

	if #matches == 1 then
		local only = matches[1]
		if only.Parent ~= canonicalParent then
			only.Parent = canonicalParent
		end
		if only:GetAttribute("RareAnnounceChannel") ~= true then
			only:SetAttribute("RareAnnounceChannel", true)
		end
		return
	end

	local function score(ch: TextChannel): number
		local s = 0
		if ch.Parent == canonicalParent then
			s += 1000
		end
		if ch:GetAttribute("RareAnnounceChannel") == true then
			s += 100
		end
		return s
	end

	local keeper = matches[1]
	for i = 2, #matches do
		if score(matches[i]) > score(keeper) then
			keeper = matches[i]
		end
	end

	for _, ch in matches do
		if ch ~= keeper then
			ch:Destroy()
		end
	end

	if keeper.Parent ~= canonicalParent then
		keeper.Parent = canonicalParent
	end
	if keeper:GetAttribute("RareAnnounceChannel") ~= true then
		keeper:SetAttribute("RareAnnounceChannel", true)
	end
end

local function addPlayerToChannel(channel: TextChannel?, userId: number)
	if not channel then
		return
	end
	pcall(function()
		channel:AddUserAsync(userId)
	end)
end

local function announceToClients(which: "here" | "global", text: string)
	rareAnnounceRemote:FireAllClients({
		channel = which,
		text = text,
	})
end

local function tryPublishGlobal(payload: { [string]: any })
	local encoded = HttpService:JSONEncode(payload)
	local ok, err = pcall(function()
		MessagingService:PublishAsync(RareAnnounceConfig.MESSAGING_TOPIC, encoded)
	end)
	if not ok then
		warn(("[RareAnnounce] PublishAsync failed: %s"):format(tostring(err)))
	end
end

local function trySubscribe()
	local ok, err = pcall(function()
		MessagingService:SubscribeAsync(RareAnnounceConfig.MESSAGING_TOPIC, function(message: string)
			task.defer(function()
				local okDecode, decoded = pcall(HttpService.JSONDecode, HttpService, message)
				if not okDecode or type(decoded) ~= "table" then
					return
				end
				local text = decoded.text
				if type(text) ~= "string" or text == "" then
					return
				end
				announceToClients("global", text)
			end)
		end)
	end)
	if not ok then
		warn(("[RareAnnounce] SubscribeAsync failed: %s"):format(tostring(err)))
	end
end

function RareAnnounceService.start()
	if started then
		return
	end
	started = true

	local okSetup, setupErr = pcall(function()
		local parent = getAnnounceChannelParent()
		destroyLegacyRareChannels(parent)
		destroyCustomHereChannelDuplicates()

		channelGlobal = getOrCreateChannel(parent, RareAnnounceConfig.CHANNEL_NAME_GLOBAL)
		dedupeGlobalAnnounceChannels(parent)
		local globalChannel = parent:FindFirstChild(RareAnnounceConfig.CHANNEL_NAME_GLOBAL)
		channelGlobal = (globalChannel and globalChannel:IsA("TextChannel")) and globalChannel or nil

		for _, player in Players:GetPlayers() do
			addPlayerToChannel(channelGlobal, player.UserId)
		end

		Players.PlayerAdded:Connect(function(player)
			addPlayerToChannel(channelGlobal, player.UserId)
		end)
	end)
	if not okSetup then
		warn(("[RareAnnounce] TextChannel setup failed: %s"):format(tostring(setupErr)))
		channelGlobal = nil
	end

	trySubscribe()
end

function RareAnnounceService.notifyRarePickup(player: Player, dropData: DropLike)
	local brainrotId = dropData.brainrotId
	if type(brainrotId) ~= "string" then
		return
	end

	local denom = tonumber(dropData.rngDenominator) or 0
	if denom < RareAnnounceConfig.SERVER_THRESHOLD then
		return
	end

	local displayName = player.DisplayName ~= "" and player.DisplayName or player.Name
	local okLine, lineOrErr = pcall(function()
		return RareAnnounceRichText.buildAnnouncement(displayName, denom, brainrotId, dropData.variantId)
	end)
	if not okLine then
		warn(("[RareAnnounce] buildAnnouncement failed: %s"):format(tostring(lineOrErr)))
		return
	end
	local line = lineOrErr :: string

	if denom >= RareAnnounceConfig.SERVER_THRESHOLD then
		announceToClients("here", line)
	end

	if denom >= RareAnnounceConfig.GLOBAL_THRESHOLD then
		announceToClients("global", line)
		tryPublishGlobal({
			v = 1,
			text = line,
			userId = player.UserId,
			sentAt = os.time(),
		})
	end
end

return RareAnnounceService
