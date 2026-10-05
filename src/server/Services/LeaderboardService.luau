--!strict
--[[
	LeaderboardService
	ServerScriptService/Server/Services/LeaderboardService

	Global all-time leaderboards on three wooden boards in the hub. The
	boards are built by MapBuilder: each has a "Screen" part tagged
	Config.Leaderboards.BoardTag with a "Board" attribute, and a SurfaceGui
	("BoardGui") with a "List" frame and a "Status" label that this service
	fills in.

	  Board      Score (read from the profile, never written to it)
	  Cash       Stats.TotalCashEarned
	  Rebirths   Rebirths
	  Steals     Stats.StealsCommitted

	  * Writes: every online player's scores once per UpdateInterval, spread
	    out across the players so the DataStore budget never spikes, plus
	    once more as they leave (DataService OnBeforeRelease hook; hooks
	    must not yield, so the write runs in its own thread, and server
	    shutdown waits up to ShutdownFlushTimeout for it). Only scores that
	    changed since the last write are sent. Test players (UserId <= 0,
	    Studio's Clients and Servers test) are never written.
	  * Reads: the top TopCount of each board every RefreshInterval, then
	    redraws the boards: rank, avatar headshot, name, value. Names come
	    from players in the server, else UserService / Players lookups,
	    cached for the server's lifetime.
	  * Storage: one OrderedDataStore per board, named
	    Config.Data.StoreName .. "_" .. Store, with the same scope as
	    DataService (Config.Data.StudioStoreScope in Studio, StoreScope live).
	  * No DataStore access (Studio without API access, or DataStores down):
	    the boards say "Leaderboards unavailable here" until a read works.
	    Every DataStore call is pcall'd and failures are logged with context.

	Studio: SAC_Debug "leaderboard" writes everyone now and refreshes.
]]

local CollectionService = game:GetService("CollectionService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local UserService = game:GetService("UserService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Services = ServerScriptService:WaitForChild("Server"):WaitForChild("Services")
local DataService = require(Services:WaitForChild("DataService"))

local LeaderboardService = {}

-- OrderedDataStore values are 64-bit integers; stay well inside them.
local MAX_SCORE = 2 ^ 53

type BoardSpec = { Title: string, Subtitle: string, Store: string, Prefix: string }
type Entry = { UserId: number, Value: number }
type BoardState = {
	Key: string,
	Store: OrderedDataStore?,
	Entries: { Entry },
	Attempted: boolean, -- a read has been tried at least once
	EverOk: boolean,    -- a read has worked at least once
}

local specs: { [string]: BoardSpec } = Config.Leaderboards.Boards :: any
local boards: { [string]: BoardState } = {}
local lastWritten: { [number]: { [string]: number } } = {}
local nameCache: { [number]: string } = {}
local pendingWrites = 0
local refreshing = false

local function log(fmt: string, ...: any)
	print(string.format("[SAC/Leaderboard] " .. fmt, ...))
end

local function warnf(fmt: string, ...: any)
	warn(string.format("[SAC/Leaderboard] " .. fmt, ...))
end

--------------------------------------------------------------------------
-- Scores
--------------------------------------------------------------------------

-- How each board's score is read from a profile.
local SCORE_READERS: { [string]: (any) -> any } = {
	Cash = function(data)
		return data.Stats and data.Stats.TotalCashEarned
	end,
	Rebirths = function(data)
		return data.Rebirths
	end,
	Steals = function(data)
		return data.Stats and data.Stats.StealsCommitted
	end,
}

--- The player's score on every board, as whole numbers. Reads only.
local function scoresFrom(data: any): { [string]: number }
	local scores: { [string]: number } = {}
	for _, key in ipairs(Config.Leaderboards.Order) do
		local reader = SCORE_READERS[key]
		if reader then
			local ok, value = pcall(reader, data)
			local n = if ok then tonumber(value) else nil
			if n and n == n then -- (n ~= n only for NaN)
				scores[key] = math.clamp(math.floor(n), 0, MAX_SCORE)
			end
		end
	end
	return scores
end

--- Sends the scores that changed since the last write. Yields.
local function writeScores(userId: number, scores: { [string]: number }, context: string)
	if userId <= 0 then
		return
	end
	pendingWrites += 1
	local written = lastWritten[userId]
	if not written then
		written = {}
		lastWritten[userId] = written
	end
	assert(written)
	for key, value in pairs(scores) do
		local board = boards[key]
		local store = board and board.Store
		if store and value > 0 and written[key] ~= value then
			local ok, err = pcall(function()
				store:SetAsync(tostring(userId), value)
			end)
			if ok then
				written[key] = value
			else
				warnf("writing %s=%d for user %d (%s) failed: %s", key, value, userId, context, tostring(err))
			end
		end
	end
	if context == "leave" then
		lastWritten[userId] = nil
	end
	pendingWrites -= 1
end

local function writePlayer(player: Player, context: string)
	if not DataService.IsLoaded(player) then
		return
	end
	local data = DataService.Get(player)
	if data then
		writeScores(player.UserId, scoresFrom(data), context)
	end
end

--------------------------------------------------------------------------
-- Reading the top lists
--------------------------------------------------------------------------

local function readBoard(board: BoardState): boolean
	board.Attempted = true
	local store = board.Store
	if not store then
		return false
	end
	local ok, result = pcall(function()
		local pages = store:GetSortedAsync(false, Config.Leaderboards.TopCount)
		return pages:GetCurrentPage()
	end)
	if not ok then
		warnf("reading the top %s failed: %s", board.Key, tostring(result))
		return false
	end
	local entries: { Entry } = {}
	for _, item in ipairs(result :: { any }) do
		local userId = tonumber(item.key)
		local value = tonumber(item.value)
		if userId and value then
			table.insert(entries, { UserId = userId, Value = value })
		end
	end
	board.Entries = entries
	board.EverOk = true
	return true
end

--- Fills nameCache for these user ids. Yields (web lookups).
local function resolveNames(ids: { number })
	local missing: { number } = {}
	for _, id in ipairs(ids) do
		local player = Players:GetPlayerByUserId(id)
		if player then
			nameCache[id] = player.DisplayName
		elseif not nameCache[id] and id > 0 and not table.find(missing, id) then
			table.insert(missing, id)
		end
	end
	if #missing == 0 then
		return
	end
	local ok, infos = pcall(function()
		return UserService:GetUserInfosByUserIdsAsync(missing)
	end)
	if ok and infos then
		for _, info in ipairs(infos) do
			nameCache[info.Id] = if info.DisplayName ~= "" then info.DisplayName else info.Username
		end
	else
		warnf("looking up %d names failed: %s", #missing, tostring(infos))
	end
	for _, id in ipairs(missing) do
		if not nameCache[id] then
			local found, name = pcall(function()
				return Players:GetNameFromUserIdAsync(id)
			end)
			if found and typeof(name) == "string" then
				nameCache[id] = name
			end
		end
	end
end

--------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------

local function label(parent: Instance, name: string, x: number, width: number, text: string,
	color: Color3, align: Enum.TextXAlignment): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.Position = UDim2.fromScale(x, 0.1)
	l.Size = UDim2.fromScale(width, 0.8)
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamBold
	l.TextScaled = true
	l.TextColor3 = color
	l.TextXAlignment = align
	l.Text = text
	l.Parent = parent
	return l
end

local function renderBoard(screen: Instance)
	local key = screen:GetAttribute("Board")
	local board = if typeof(key) == "string" then boards[key] else nil
	local gui = screen:FindFirstChild("BoardGui")
	local list = gui and gui:FindFirstChild("List")
	local status = gui and gui:FindFirstChild("Status") :: TextLabel?
	if not board or not list then
		return
	end
	local lb = Config.Leaderboards
	local spec = specs[board.Key]

	for _, child in ipairs(list:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	local message: string? = nil
	if not board.EverOk then
		message = if board.Attempted then "Leaderboards unavailable here" else "Gathering the top campers..."
	elseif #board.Entries == 0 then
		message = "No scores yet. Be the first!"
	end
	if status then
		status.Visible = message ~= nil
		status.Text = message or ""
	end
	if message then
		return
	end

	for rank, entry in ipairs(board.Entries) do
		local row = Instance.new("Frame")
		row.Name = "Row"
		row.LayoutOrder = rank
		row.Size = UDim2.fromScale(1, 0.094)
		row.BackgroundColor3 = Color3.new(0, 0, 0)
		row.BackgroundTransparency = if rank % 2 == 1 then 0.72 else 0.84
		row.BorderSizePixel = 0
		row.Parent = list
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.2, 0)
		corner.Parent = row

		local color = lb.RankColors[rank] or lb.RowColor
		label(row, "Rank", 0.01, 0.1, tostring(rank), color, Enum.TextXAlignment.Center)

		local head = Instance.new("ImageLabel")
		head.Name = "Avatar"
		head.Position = UDim2.fromScale(0.12, 0.06)
		head.Size = UDim2.fromScale(0.1, 0.88)
		head.BackgroundColor3 = Color3.fromRGB(40, 34, 30)
		head.BackgroundTransparency = 0.3
		if entry.UserId > 0 then
			head.Image = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48", entry.UserId)
		end
		head.Parent = row
		local aspect = Instance.new("UIAspectRatioConstraint")
		aspect.AspectRatio = 1
		aspect.Parent = head
		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(0.5, 0)
		round.Parent = head

		local name = nameCache[entry.UserId] or ("Camper " .. tostring(entry.UserId))
		label(row, "Name", 0.24, 0.46, name, lb.RowColor, Enum.TextXAlignment.Left)
		local prefix = if spec then spec.Prefix else ""
		label(row, "Value", 0.71, 0.27, prefix .. Config.FormatNumber(entry.Value), color, Enum.TextXAlignment.Right)
	end
end

local function renderAll()
	for _, screen in ipairs(CollectionService:GetTagged(Config.Leaderboards.BoardTag)) do
		local ok, err = pcall(renderBoard, screen)
		if not ok then
			warnf("drawing board %s failed: %s", screen:GetFullName(), tostring(err))
		end
	end
end

--- Re-reads every board and redraws them. Yields.
function LeaderboardService.Refresh()
	if refreshing then
		return
	end
	refreshing = true
	local ok, err = pcall(function()
		local ids: { number } = {}
		for _, key in ipairs(Config.Leaderboards.Order) do
			local board = boards[key]
			if board and readBoard(board) then
				for _, entry in ipairs(board.Entries) do
					table.insert(ids, entry.UserId)
				end
			end
		end
		resolveNames(ids)
	end)
	refreshing = false
	if not ok then
		warnf("refresh errored: %s", tostring(err))
	end
	renderAll()
end

--- Writes every online player's scores now, then refreshes. Yields.
--- (Studio debug command.)
function LeaderboardService.FlushNow()
	for _, player in ipairs(Players:GetPlayers()) do
		writePlayer(player, "debug")
	end
	LeaderboardService.Refresh()
end

--- One line per board: store, state and the top entry. (Debug.)
function LeaderboardService.Describe(): string
	local lines = {}
	for _, key in ipairs(Config.Leaderboards.Order) do
		local board = boards[key]
		if not board then
			table.insert(lines, key .. ": not started")
		else
			local top = board.Entries[1]
			table.insert(lines, string.format("%s: store %s, %s, %d entries%s", key,
				if board.Store then "open" else "MISSING",
				if board.EverOk then "reads OK" elseif board.Attempted then "reads FAILING" else "not read yet",
				#board.Entries,
				if top then string.format(", #1 %s = %d", nameCache[top.UserId] or tostring(top.UserId), top.Value) else ""))
		end
	end
	table.insert(lines, string.format("pending writes: %d", pendingWrites))
	return table.concat(lines, "\n")
end

--------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------

function LeaderboardService.Start()
	local lb = Config.Leaderboards
	local scope = if RunService:IsStudio() then Config.Data.StudioStoreScope else Config.Data.StoreScope

	for _, key in ipairs(lb.Order) do
		local board: BoardState = { Key = key, Store = nil, Entries = {}, Attempted = false, EverOk = false }
		local spec = specs[key]
		if not spec then
			warnf("Config.Leaderboards.Order lists '%s' but Boards has no entry", key)
		elseif not SCORE_READERS[key] then
			warnf("no score reader for board '%s'", key)
		elseif lb.Enabled then
			local storeName = Config.Data.StoreName .. "_" .. spec.Store
			local ok, store = pcall(function()
				return DataStoreService:GetOrderedDataStore(storeName, scope)
			end)
			if ok then
				board.Store = store
			else
				warnf("couldn't open OrderedDataStore '%s' (scope '%s'): %s", storeName, scope, tostring(store))
			end
		end
		boards[key] = board
	end

	if not lb.Enabled then
		for _, board in pairs(boards) do
			board.Attempted = true
		end
		renderAll()
		log("disabled in Config.Leaderboards")
		return
	end

	-- Boards that appear later (a map rebuild) get drawn straight away.
	CollectionService:GetInstanceAddedSignal(lb.BoardTag):Connect(function(screen)
		task.defer(renderBoard, screen)
	end)

	-- A last write as each player leaves. Hooks must not yield, so take a
	-- copy of the scores now and send them from a thread of their own.
	DataService.OnBeforeRelease(function(player: Player, data)
		local scores = scoresFrom(data)
		task.spawn(writeScores, player.UserId, scores, "leave")
	end)

	-- On shutdown, give those leave-writes a moment to land. (DataService's
	-- own shutdown releases everyone, which fires the hook above.)
	game:BindToClose(function()
		local startedAt = os.clock()
		local deadline = startedAt + lb.ShutdownFlushTimeout
		while (pendingWrites > 0 or os.clock() < startedAt + 1) and os.clock() < deadline do
			task.wait(0.1)
		end
		if pendingWrites > 0 then
			warnf("shutdown: %d leaderboard write(s) didn't finish", pendingWrites)
		end
	end)

	-- Periodic writes, spread evenly across whoever is online.
	task.spawn(function()
		while true do
			local list = Players:GetPlayers()
			if #list == 0 then
				task.wait(lb.UpdateInterval)
			else
				local gap = lb.UpdateInterval / #list
				for _, player in ipairs(list) do
					if player.Parent == Players then
						task.spawn(writePlayer, player, "periodic")
					end
					task.wait(gap)
				end
			end
		end
	end)

	-- Periodic reads.
	task.spawn(function()
		renderAll()
		task.wait(lb.FirstRefreshDelay)
		while true do
			LeaderboardService.Refresh()
			task.wait(lb.RefreshInterval)
		end
	end)

	log("started (%d boards, scope '%s')", #lb.Order, scope)
end

return LeaderboardService
