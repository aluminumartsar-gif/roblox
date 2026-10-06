local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local BrainrotConfig = require(ConfigFolder:WaitForChild("BrainrotConfig"))
local LeaderboardConfig = require(ConfigFolder:WaitForChild("LeaderboardConfig"))
local BrainrotLeaderboardScore = require(UtilFolder:WaitForChild("BrainrotLeaderboardScore"))

local PlayerDataService = require(script.Parent:WaitForChild("PlayerDataService"))

local LeaderboardPodiumService = {}

local brainrotStore: OrderedDataStore? = nil
local rebirthStore: OrderedDataStore? = nil
local warnedBrainrotInitFail = false
local warnedRebirthInitFail = false

local nextLeaderboardPollAtClock = 0

local function scheduleLeaderboardPollCountdown()
	nextLeaderboardPollAtClock = os.clock() + LeaderboardConfig.POLL_INTERVAL_SEC
end

local function ensureBrainrotOrderedStore(): OrderedDataStore?
	if brainrotStore then
		return brainrotStore
	end
	local ok, res = pcall(function()
		return DataStoreService:GetOrderedDataStore(LeaderboardConfig.ORDERED_STORE_BRAINROT_RNG)
	end)
	if ok and res then
		warnedBrainrotInitFail = false
		brainrotStore = res
		return brainrotStore
	end
	if not warnedBrainrotInitFail then
		warnedBrainrotInitFail = true
		warn(("[LeaderboardPodium] Brainrot ODS unavailable: %s"):format(tostring(res)))
	end
	return nil
end

local function ensureRebirthOrderedStore(): OrderedDataStore?
	if rebirthStore then
		return rebirthStore
	end
	local ok, res = pcall(function()
		return DataStoreService:GetOrderedDataStore(LeaderboardConfig.ORDERED_STORE_REBIRTH)
	end)
	if ok and res then
		warnedRebirthInitFail = false
		rebirthStore = res
		return rebirthStore
	end
	if not warnedRebirthInitFail then
		warnedRebirthInitFail = true
		warn(("[LeaderboardPodium] Rebirth ODS unavailable: %s"):format(tostring(res)))
	end
	return nil
end

local function ensureAnyOrderedStoreInitialized(): boolean
	ensureBrainrotOrderedStore()
	ensureRebirthOrderedStore()
	return brainrotStore ~= nil or rebirthStore ~= nil
end

local function clampScore(raw: number): number
	local n = math.floor(tonumber(raw) or 0)
	return math.clamp(n, 0, LeaderboardConfig.MAX_ORDERED_SCORE)
end

function LeaderboardPodiumService.removeScoresForPlayer(player: Player)
	if not player or player.Parent == nil then
		return
	end

	ensureBrainrotOrderedStore()
	ensureRebirthOrderedStore()

	local key = tostring(player.UserId)
	if brainrotStore then
		pcall(function()
			brainrotStore:RemoveAsync(key)
		end)
	end
	if rebirthStore then
		pcall(function()
			rebirthStore:RemoveAsync(key)
		end)
	end

	task.defer(function()
		pcall(refreshAllBoards)
	end)
end

function LeaderboardPodiumService.pushScoresForPlayer(player: Player)
	if not player or player.Parent == nil then
		return
	end
	if not PlayerDataService.isLoaded(player) then
		return
	end
	if not ensureAnyOrderedStoreInitialized() then
		return
	end

	local data = PlayerDataService.getData(player)
	local key = tostring(player.UserId)
	local brainrotScore = clampScore(BrainrotLeaderboardScore.getBestRngDenominatorFromData(data))
	local rebirthScore = clampScore(data.rebirths or 0)

	if brainrotStore then
		local ok, err = pcall(function()
			brainrotStore:SetAsync(key, brainrotScore)
		end)
		if not ok then
			warn(("[LeaderboardPodium] Failed to save brainrot score for %s: %s"):format(player.Name, tostring(err)))
		end
	end

	if rebirthStore then
		local ok, err = pcall(function()
			rebirthStore:SetAsync(key, rebirthScore)
		end)
		if not ok then
			warn(("[LeaderboardPodium] Failed to save rebirth score for %s: %s"):format(player.Name, tostring(err)))
		end
	end

	task.defer(function()
		pcall(refreshAllBoards)
	end)
end

local function findDescendantByPath(root: Instance, path: string): Instance?
	local current: Instance? = root
	for segment in string.gmatch(path, "[^/]+") do
		if not current then
			return nil
		end
		current = current:FindFirstChild(segment)
	end
	return current
end

local function getBoardListSurfaceGui(boardModel: Model): SurfaceGui?
	local boardGui = findDescendantByPath(boardModel, LeaderboardConfig.BOARD_GUI_PATH_BOARD)
	return if boardGui and boardGui:IsA("SurfaceGui") then boardGui :: SurfaceGui else nil
end

local function findLeaderboardTimerLabel(boardModel: Model): TextLabel?
	local timerPart = boardModel:FindFirstChild(LeaderboardConfig.TIMER_PART_NAME)
	if not timerPart then
		return nil
	end

	local guiContainer = timerPart:FindFirstChild(LeaderboardConfig.TIMER_GUI_CHILD_NAME)
	local surfaceGui = if guiContainer and guiContainer:IsA("SurfaceGui") then guiContainer :: SurfaceGui else timerPart:FindFirstChildOfClass("SurfaceGui")
	if not surfaceGui then
		return nil
	end

	local labeled = surfaceGui:FindFirstChild(LeaderboardConfig.TIMER_LABEL_CHILD_NAME)
	if labeled and labeled:IsA("TextLabel") then
		return labeled :: TextLabel
	end

	return surfaceGui:FindFirstChildWhichIsA("TextLabel")
end

local function formatLeaderboardPollCountdown(secondsRemaining: number): string
	local total = math.max(0, math.floor(secondsRemaining + 0.5))
	if total <= 0 then
		return "Updating..."
	end
	local m = math.floor(total / 60)
	local s = total % 60
	if m <= 0 then
		return ("Next refresh: %ds"):format(total)
	end
	return ("Next refresh: %d:%02d"):format(m, s)
end

local function updateLeaderboardTimers()
	local folder = Workspace:FindFirstChild(LeaderboardConfig.WORKSPACE_FOLDER_NAME)
	if not folder then
		return
	end

	local secs = math.max(0, math.ceil(nextLeaderboardPollAtClock - os.clock()))
	local text = formatLeaderboardPollCountdown(secs)

	for _, modelName in ipairs({ LeaderboardConfig.BRAINROT_MODEL_NAME, LeaderboardConfig.REBIRTH_MODEL_NAME }) do
		local boardModel = folder:FindFirstChild(modelName)
		if boardModel and boardModel:IsA("Model") then
			local label = findLeaderboardTimerLabel(boardModel :: Model)
			if label then
				label.Text = text
			end
		end
	end
end

local function destroyListRowsExceptTemplate(list: ScrollingFrame)
	for _, child in list:GetChildren() do
		if string.match(child.Name, "^Row_%d+$") then
			child:Destroy()
		end
	end
end

local function parseOrderedUserKey(keyRaw: unknown): number?
	if type(keyRaw) == "number" then
		local n = math.floor(keyRaw)
		if n > 0 then
			return n
		end
		return nil
	end

	if type(keyRaw) ~= "string" then
		return nil
	end

	local trimmed = string.match(keyRaw, "^%s*(.-)%s*$") or keyRaw
	local num = tonumber(trimmed)
	if not num then
		return nil
	end

	local userid = math.floor(num)
	return if userid > 0 then userid else nil
end

local function scrubLegacyListGadgets(list: ScrollingFrame)
	local badPad = list:FindFirstChild("_PodiumScrollPad")
	if badPad then
		badPad:Destroy()
	end
	list:SetAttribute("_LeaderboardCanvasBound", nil)
end

local function applyScrollSizingFromFixedRows(list: ScrollingFrame, rowCount: number)
	list.AutomaticCanvasSize = Enum.AutomaticSize.None
	list.ScrollingEnabled = true
	list.Active = true
	list.ScrollingDirection = Enum.ScrollingDirection.Y

	local layout = list:FindFirstChildOfClass("UIListLayout")
	local gapBetween = if layout then layout.Padding.Offset else 0
	local rowsH = rowCount * LeaderboardConfig.LIST_ROW_FIXED_HEIGHT_PX
	local gapsTotal = gapBetween * math.max(0, rowCount - 1)
	local contentPx = math.max(0, rowsH + gapsTotal) + LeaderboardConfig.LIST_SCROLL_VERTICAL_PADDING_PX

	local vp = math.max(1, list.AbsoluteWindowSize.Y)
	local padded = math.max(contentPx, vp + 2)

	list.CanvasPosition = Vector2.zero
	list.CanvasSize = UDim2.new(1, 0, 0, math.ceil(padded))
end

local function applyRowSizingAndTypography(root: GuiObject, rank: number)
	root.Visible = true
	root.LayoutOrder = rank
	root.Size = UDim2.new(1, 0, 0, LeaderboardConfig.LIST_ROW_FIXED_HEIGHT_PX)
	root.AutomaticSize = Enum.AutomaticSize.None

	local minSz = LeaderboardConfig.LIST_ROW_MIN_TEXT_SIZE
	for _, d in root:GetDescendants() do
		if d:IsA("TextLabel") or d:IsA("TextBox") then
			local t = d :: TextLabel
			t.TextScaled = false
			if t.TextSize < minSz then
				t.TextSize = minSz
			end
		elseif d:IsA("TextButton") then
			local t = d :: TextButton
			t.TextScaled = false
			if t.TextSize < minSz then
				t.TextSize = minSz
			end
		end
	end
end

local function safeSetTextLabel(parent: Instance?, name: string, text: string)
	if not parent then
		return
	end
	local label = parent:FindFirstChild(name)
	if label and label:IsA("TextLabel") then
		label.Text = text
	end
end

local function assignRowHeadshot(scope: GuiObject?, userId: number)
	if not scope or userId <= 0 then
		return
	end
	local url = ("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150"):format(userId)

	local function apply(inst: Instance): boolean
		if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
			(inst :: any).Image = url
			return true
		end
		return false
	end

	local direct = scope:FindFirstChild("Icon")
	if direct and apply(direct) then
		return
	end
	for _, desc in scope:GetDescendants() do
		if desc.Name == "Icon" and apply(desc) then
			break
		end
	end
end

local function fillScrollingList(boardGui: SurfaceGui, entries: { { userId: number, score: number } }, scoreLabel: string)
	local list = boardGui:FindFirstChild("List")
	if not list or not list:IsA("ScrollingFrame") then
		return
	end
	local template = list:FindFirstChild("Template")
	if not template or not template:IsA("GuiObject") then
		return
	end
	template.Visible = false

	destroyListRowsExceptTemplate(list)
	scrubLegacyListGadgets(list)

	local rowCount = #entries
	for rank = 1, rowCount do
		local row = entries[rank]
		local cloneRoot = template:Clone()
		cloneRoot.Name = ("Row_%d"):format(rank)
		cloneRoot.Parent = list

		if cloneRoot:IsA("GuiObject") then
			applyRowSizingAndTypography(cloneRoot :: GuiObject, rank)
		end

		local cell: Instance = cloneRoot
		local inner = cloneRoot:FindFirstChild("Frame")
		if inner then
			cell = inner
		end

		safeSetTextLabel(cell, "Rank", ("#%d"):format(rank))
		local displayName = "..."
		local okName, resolved = pcall(Players.GetNameFromUserIdAsync, Players, row.userId)
		if okName and type(resolved) == "string" then
			displayName = resolved
		end
		safeSetTextLabel(cell, "Name", displayName)
		safeSetTextLabel(cell, "Value", scoreLabel == "brainrot" and BrainrotConfig.formatRngOdds(row.score) or tostring(math.floor(row.score)))

		local rowGui = if cloneRoot:IsA("GuiObject") then cloneRoot :: GuiObject else nil
		if rowGui then
			assignRowHeadshot(rowGui, row.userId)
		end
	end

	applyScrollSizingFromFixedRows(list, rowCount)

	task.defer(function()
		task.wait()
		applyScrollSizingFromFixedRows(list, rowCount)
	end)
end

local function applyAvatarToDummy(dummyModel: Model, userId: number?)
	local humanoid = dummyModel:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	if userId and userId > 0 then
		local okDesc, desc = pcall(function()
			return Players:GetHumanoidDescriptionFromUserId(userId :: number)
		end)
		if okDesc and desc then
			local okApply, errApply = pcall(function()
				humanoid:ApplyDescription(desc :: HumanoidDescription)
			end)
			if okApply then
				return
			else
				warn(("[LeaderboardPodium] ApplyDescription failed: %s"):format(tostring(errApply)))
			end
		end
	end

	local okReset, errReset = pcall(function()
		humanoid:ApplyDescription(Instance.new("HumanoidDescription"))
	end)
	if not okReset then
		warn(("[LeaderboardPodium] ApplyDescription reset failed: %s"):format(tostring(errReset)))
	end
end

local function updateDummies(boardModel: Model, topThree: { { userId: number, score: number } })
	for index = 1, 3 do
		local dummyName = LeaderboardConfig.DUMMY_NAMES[index]
		local dummy = if dummyName then boardModel:FindFirstChild(dummyName) else nil
		if dummy and dummy:IsA("Model") then
			local entry = topThree[index]
			if entry then
				applyAvatarToDummy(dummy, entry.userId)
			else
				applyAvatarToDummy(dummy, nil)
			end
		end
	end
end

local function ingestSortedPage(
	out: { { userId: number, score: number } },
	page: { any },
	maxEntries: number
)
	for _, data in ipairs(page) do
		if #out >= maxEntries then
			return
		end
		local keyRaw = if type(data) == "table" then (data.key or data.Key) else nil
		local valueRaw = if type(data) == "table" then (data.value or data.Value) else nil
		local userid = parseOrderedUserKey(keyRaw)
		if userid then
			table.insert(out, {
				userId = userid,
				score = tonumber(valueRaw) or 0,
			})
		end
	end
end

-- Walks all ODS pages until `maxEntries` rows or no more data (global sorted order, not session-only).
local function fetchGlobalSortedEntries(
	store: OrderedDataStore,
	descending: boolean,
	maxEntries: number,
	pageFetchSize: number
): { { userId: number, score: number } }
	local out: { { userId: number, score: number } } = {}
	local chunk = math.clamp(pageFetchSize, 1, 100)

	local ok, pagesOrErr = pcall(function()
		return store:GetSortedAsync(descending, chunk)
	end)
	if not ok then
		warn(("[LeaderboardPodium] GetSortedAsync failed: %s"):format(tostring(pagesOrErr)))
		return out
	end

	local pages = pagesOrErr :: any
	local hopCap = math.min(512, math.max(24, math.ceil(maxEntries / chunk) + 8))
	local hops = 0

	while true do
		hops += 1
		if hops > hopCap then
			warn("[LeaderboardPodium] Pagination stopped at safety cap.")
			break
		end

		local page = pages:GetCurrentPage()
		ingestSortedPage(out, page :: { any }, maxEntries)

		if #out >= maxEntries then
			break
		end

		local finished = (pages :: any).IsFinished == true
		if finished then
			break
		end

		local advOk, advErr = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)
		if not advOk then
			warn(("[LeaderboardPodium] AdvanceToNextPageAsync failed: %s"):format(tostring(advErr)))
			break
		end
	end

	return out
end

local function refreshBoardModel(boardModel: Model, store: OrderedDataStore?, scoreKind: string)
	if not store then
		return
	end

	local boardGui = getBoardListSurfaceGui(boardModel)
	if not boardGui then
		return
	end

	local entries = fetchGlobalSortedEntries(
		store,
		false,
		LeaderboardConfig.MAX_LEADERBOARD_LIST_ENTRIES,
		LeaderboardConfig.ODS_PAGE_FETCH_SIZE
	)
	fillScrollingList(boardGui, entries, scoreKind)

	local topThree = {}
	for i = 1, math.min(3, #entries) do
		topThree[i] = entries[i]
	end
	updateDummies(boardModel, topThree)
end

local function refreshAllBoardsCore()
	if not ensureAnyOrderedStoreInitialized() then
		return
	end

	local folder = Workspace:FindFirstChild(LeaderboardConfig.WORKSPACE_FOLDER_NAME)
	if not folder then
		return
	end

	local brainrotModel = folder:FindFirstChild(LeaderboardConfig.BRAINROT_MODEL_NAME)
	local rebirthModel = folder:FindFirstChild(LeaderboardConfig.REBIRTH_MODEL_NAME)

	if brainrotModel and brainrotModel:IsA("Model") and brainrotStore then
		refreshBoardModel(brainrotModel :: Model, brainrotStore, "brainrot")
	end
	if rebirthModel and rebirthModel:IsA("Model") and rebirthStore then
		refreshBoardModel(rebirthModel :: Model, rebirthStore, "rebirth")
	end
end

local function refreshAllBoards()
	local ok, err = pcall(refreshAllBoardsCore)
	if not ok then
		warn(("[LeaderboardPodium] refreshAllBoards failed: %s"):format(tostring(err)))
	end
	scheduleLeaderboardPollCountdown()
	task.defer(updateLeaderboardTimers)
end

function LeaderboardPodiumService.start()
	scheduleLeaderboardPollCountdown()
	ensureAnyOrderedStoreInitialized()
	if brainrotStore == nil and rebirthStore == nil then
		warn(
			"[LeaderboardPodium] Ordered Data Stores are not available — nothing global can load. Publish this place to Roblox, "
				.. "enable Game Settings → Security → Enable Studio Access to API Services (for Studio test servers), "
				.. "or test on a live game server. Stores: BrainrotRngRare_v3, RebirthCount_v3."
		)
	end

	-- Replay push after profile load completes (cheap idempotent writes). Covers races where notifyLeaderboardsPush
	-- deferred before APIs were usable, plus late joiners.
	local function enqueuePush(player: Player)
		if not player.Parent then
			return
		end
		task.spawn(function()
			PlayerDataService.waitForData(player, 30)
			if player.Parent then
				LeaderboardPodiumService.pushScoresForPlayer(player)
			end
		end)
	end

	for _, player in Players:GetPlayers() do
		enqueuePush(player)
	end

	Players.PlayerAdded:Connect(enqueuePush)

	task.spawn(function()
		while true do
			task.wait(1)
			updateLeaderboardTimers()
		end
	end)

	task.defer(function()
		task.wait(2)
		pcall(refreshAllBoards)
	end)

	task.spawn(function()
		while true do
			task.wait(LeaderboardConfig.POLL_INTERVAL_SEC)
			pcall(refreshAllBoards)
		end
	end)
end

return LeaderboardPodiumService
