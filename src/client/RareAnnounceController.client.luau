local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local RareAnnounceConfig = require(ConfigFolder:WaitForChild("RareAnnounceConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))

local rareAnnounceRemote = RemoteRegistry.getRemote(
	RareAnnounceConfig.REMOTE_FOLDER,
	RareAnnounceConfig.RARE_ANNOUNCE_REMOTE
)

local function findReplicatedTextChannel(channelName: string): TextChannel?
	local textChannelsFolder = TextChatService:FindFirstChild("TextChannels")
	if textChannelsFolder and textChannelsFolder:IsA("Folder") then
		local ch = textChannelsFolder:FindFirstChild(channelName)
		if ch and ch:IsA("TextChannel") then
			return ch
		end
	end

	local direct = TextChatService:FindFirstChild(channelName)
	if direct and direct:IsA("TextChannel") then
		return direct
	end

	if textChannelsFolder and textChannelsFolder:IsA("Folder") then
		local waited = textChannelsFolder:WaitForChild(channelName, 20)
		if waited and waited:IsA("TextChannel") then
			return waited
		end
	end

	local waitedDirect = TextChatService:WaitForChild(channelName, 8)
	if waitedDirect and waitedDirect:IsA("TextChannel") then
		return waitedDirect
	end

	return nil
end

local function resolveAnnounceChannel(which: string): TextChannel?
	if which == "global" then
		return findReplicatedTextChannel(RareAnnounceConfig.CHANNEL_NAME_GLOBAL)
	end

	if which == "here" then
		local ch = findReplicatedTextChannel(RareAnnounceConfig.CHANNEL_NAME_HERE)
		if ch then
			return ch
		end
		-- Best-effort fallback if custom channel is missing (chat version / load order).
		local textChannelsFolder = TextChatService:FindFirstChild("TextChannels")
		if textChannelsFolder and textChannelsFolder:IsA("Folder") then
			for _, name in { "RBXSystem", "RBXGeneral" } do
				local fb = textChannelsFolder:FindFirstChild(name)
				if fb and fb:IsA("TextChannel") then
					return fb
				end
			end
		end
	end

	return nil
end

local function displayAnnounce(which: string, text: string)
	task.defer(function()
		local channel = resolveAnnounceChannel(which)
		if channel then
			pcall(function()
				channel:DisplaySystemMessage(text, "RareAnnounce")
			end)
		end
	end)
end

local function applyChatWindowHeightScale()
	local scale = RareAnnounceConfig.CHAT_WINDOW_HEIGHT_SCALE
	if type(scale) ~= "number" then
		return
	end

	local clamped = math.clamp(scale, 0.5, 2)

	local function setOn(window: Instance)
		if window:IsA("ChatWindowConfiguration") then
			(window :: ChatWindowConfiguration).HeightScale = clamped
			return true
		end
		return false
	end

	local existing = TextChatService:FindFirstChildWhichIsA("ChatWindowConfiguration")
	if existing and setOn(existing) then
		return
	end

	local conn: RBXScriptConnection?
	conn = TextChatService.ChildAdded:Connect(function(child)
		if setOn(child) then
			if conn then
				conn:Disconnect()
			end
		end
	end)
end

local function bindChannelTabsWhenReady()
	local tabs = TextChatService:FindFirstChildWhichIsA("ChannelTabsConfiguration")
	if tabs then
		tabs.Enabled = true
		return
	end
	local conn: RBXScriptConnection?
	conn = TextChatService.ChildAdded:Connect(function(child)
		if child:IsA("ChannelTabsConfiguration") then
			child.Enabled = true
			if conn then
				conn:Disconnect()
			end
		end
	end)
end

bindChannelTabsWhenReady()
applyChatWindowHeightScale()

rareAnnounceRemote.OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" then
		return
	end
	local which = payload.channel
	local text = payload.text
	if which ~= "here" and which ~= "global" then
		return
	end
	if type(text) ~= "string" or text == "" then
		return
	end
	displayAnnounce(which, text)
end)
