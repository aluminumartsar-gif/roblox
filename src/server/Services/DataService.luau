--!strict
--[[
	DataService
	ServerScriptService/Server/Services/DataService

	Owns every player's profile for the lifetime of their session. Nothing
	else in the game reads or writes a DataStore; everything else asks this.

	Lifecycle
	  join    -> take the session lock, load, normalize, build leaderstats,
	             fire ProfileLoaded, push a snapshot to the client
	  playing -> other services mutate through the API below; every change
	             is pushed to the client (coalesced to once per frame)
	  every Config.Data.AutosaveInterval seconds -> save, keep the lock
	  leave   -> run BeforeRelease hooks, save, release the lock
	  shutdown (BindToClose) -> release everyone in parallel

	Failure policy: if a profile cannot be loaded safely, the player is
	KICKED with a clear message. Letting them play on a blank profile would
	overwrite their real save the moment we autosaved. Losing a session is
	annoying; losing a save is unforgivable.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Signal = require(Shared:WaitForChild("Util"):WaitForChild("Signal"))

local Modules = ServerScriptService:WaitForChild("Server"):WaitForChild("Modules")
local ProfileTemplate = require(Modules:WaitForChild("ProfileTemplate"))
local SessionStore = require(Modules:WaitForChild("SessionStore"))

type ProfileData = ProfileTemplate.ProfileData

type Session = {
	Player: Player,
	Key: string,
	Data: ProfileData,
	LoadedAt: number,           -- os.time()
	PlaytimeMark: number,       -- os.clock() of the last playtime accounting
	PushPending: boolean,
	Releasing: boolean,
	Leaderstats: Folder?,
}

local DataService = {}

--- Fired as (player, data) once a profile is loaded and ready to use.
DataService.ProfileLoaded = Signal.new()
--- Fired as (player, newCash, delta, reason) whenever cash changes.
DataService.CashChanged = Signal.new()

local sessions: { [Player]: Session } = {}
local loading: { [Player]: boolean } = {}
local beforeReleaseHooks: { (Player, ProfileData) -> () } = {}

local store: any = nil
local profileUpdatedRemote: RemoteEvent? = nil
local shuttingDown = false

local function log(fmt: string, ...: any)
	if Config.Debug.Verbose then
		print(string.format("[SAC/Data] " .. fmt, ...))
	end
end

local function warnf(fmt: string, ...: any)
	warn(string.format("[SAC/Data] " .. fmt, ...))
end

local function keyFor(userId: number): string
	return "Player_" .. tostring(userId)
end

local function isValidAmount(amount: any): boolean
	return typeof(amount) == "number"
		and amount == amount           -- not NaN
		and amount ~= math.huge
		and amount >= 0
end

--------------------------------------------------------------------------
-- Leaderstats
--------------------------------------------------------------------------

local function buildLeaderstats(session: Session)
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"

	local cash = Instance.new("IntValue")
	cash.Name = "Cash"
	cash.Value = session.Data.Cash
	cash.Parent = folder

	local rebirths = Instance.new("IntValue")
	rebirths.Name = "Rebirths"
	rebirths.Value = session.Data.Rebirths
	rebirths.Parent = folder

	folder.Parent = session.Player
	session.Leaderstats = folder
end

local function syncLeaderstats(session: Session)
	local folder = session.Leaderstats
	if not folder then
		return
	end
	local cash = folder:FindFirstChild("Cash") :: IntValue?
	local rebirths = folder:FindFirstChild("Rebirths") :: IntValue?
	if cash then
		cash.Value = session.Data.Cash
	end
	if rebirths then
		rebirths.Value = session.Data.Rebirths
	end
end

--------------------------------------------------------------------------
-- Client push
-- The client gets a read-only snapshot. It is display data only: nothing
-- the client sends back is ever trusted.
--------------------------------------------------------------------------

local function buildClientSnapshot(session: Session): { [string]: any }
	local data = session.Data
	return {
		Cash = data.Cash,
		Rebirths = data.Rebirths,
		Nests = data.Nests,
		Upgrades = data.Upgrades,
		Codex = data.Codex,
		Buffs = data.Buffs,
		Stats = data.Stats,
		-- Lets the client warn the player when nothing is being saved.
		IsPersistent = not store.IsMock,
		ServerTime = os.time(),
	}
end

local function pushNow(session: Session)
	session.PushPending = false
	if not profileUpdatedRemote or not session.Player.Parent then
		return
	end
	profileUpdatedRemote:FireClient(session.Player, buildClientSnapshot(session))
end

--- Queues a client push. Many changes in one frame produce one push.
local function schedulePush(session: Session)
	if session.PushPending then
		return
	end
	session.PushPending = true
	task.defer(function()
		if session.PushPending and sessions[session.Player] == session then
			pushNow(session)
		end
	end)
end

--------------------------------------------------------------------------
-- Saving
--------------------------------------------------------------------------

local function accountPlaytime(session: Session)
	local now = os.clock()
	local elapsed = now - session.PlaytimeMark
	session.PlaytimeMark = now
	if elapsed > 0 then
		session.Data.Stats.Playtime = (session.Data.Stats.Playtime or 0) + math.floor(elapsed)
	end
end

local function saveSession(session: Session, release: boolean): boolean
	accountPlaytime(session)
	local ok, reason = store:SaveAsync(session.Key, session.Data, release)

	if not ok and reason == "LostLock" and not release then
		-- Another server owns this profile now. Our copy is stale; every
		-- further change this server makes would be lost or, worse, would
		-- fight with the real one. Get the player out.
		warnf("%s lost their session lock mid-session; kicking", session.Player.Name)
		session.Player:Kick("Your data was opened in another server. Please rejoin.")
	end

	return ok
end

local function releaseSession(session: Session)
	if session.Releasing then
		return
	end
	session.Releasing = true

	-- Give other services a last chance to write into the profile
	-- (e.g. return a carried item). Synchronous, in registration order.
	for _, hook in ipairs(beforeReleaseHooks) do
		local ok, err = pcall(hook, session.Player, session.Data)
		if not ok then
			warnf("BeforeRelease hook errored for %s: %s", session.Player.Name, tostring(err))
		end
	end

	local ok = saveSession(session, true)
	if ok then
		log("Released %s (cash=%d, playtime=%ds)", session.Player.Name, session.Data.Cash, session.Data.Stats.Playtime)
	else
		warnf("Final save FAILED for %s (userId %d)", session.Player.Name, session.Player.UserId)
	end

	if sessions[session.Player] == session then
		sessions[session.Player] = nil
	end
end

--------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	if shuttingDown or sessions[player] or loading[player] then
		return
	end
	loading[player] = true

	-- `loading[player]` stays set until this function has finished every
	-- DataStore call, so shutdown can wait for it. Clear it on every exit.
	local key = keyFor(player.UserId)
	local result = store:LoadAsync(key)

	if not result.Ok then
		loading[player] = nil
		warnf("Could not load %s (%s)", player.Name, tostring(result.Reason))
		if player.Parent then
			if result.Reason == "Locked" then
				player:Kick("Your save is still open in another server. Wait a few seconds and rejoin.")
			else
				player:Kick("Roblox data servers didn't respond, so we couldn't load your save safely. Please rejoin.")
			end
		end
		return
	end

	local data: ProfileData
	if result.IsNew or result.Data == nil then
		data = ProfileTemplate.new()
	else
		data = result.Data
	end

	-- Normalize mutates in place, so keep an untouched copy: if it throws,
	-- we hand the lock back with exactly what we loaded, never a half-
	-- repaired profile.
	local untouched = ProfileTemplate.DeepCopy(data)
	local normalized, normalizeErr = pcall(ProfileTemplate.Normalize, data, player.Name)
	if not normalized then
		warnf("Normalize FAILED for %s: %s — releasing untouched data", player.Name, tostring(normalizeErr))
		store:ReleaseAsync(key, untouched)
		loading[player] = nil
		if player.Parent then
			player:Kick("Something went wrong loading your save. It hasn't been changed. Please rejoin.")
		end
		return
	end

	local now = os.time()
	local stats = data.Stats
	stats.JoinCount = (stats.JoinCount or 0) + 1
	if (stats.FirstJoinAt or 0) == 0 then
		stats.FirstJoinAt = now
	end
	stats.LastJoinAt = now

	-- The player left, or the server started shutting down, while we were
	-- loading. Either way nobody will release this later (PlayerRemoving
	-- and BindToClose already ran without a session to release), so we
	-- hold the lock and must hand it straight back.
	if shuttingDown or not player.Parent then
		log("%s: %s during load; releasing", player.Name, shuttingDown and "server closing" or "left")
		store:ReleaseAsync(key, data)
		loading[player] = nil
		return
	end

	local session: Session = {
		Player = player,
		Key = key,
		Data = data,
		LoadedAt = now,
		PlaytimeMark = os.clock(),
		PushPending = false,
		Releasing = false,
		Leaderstats = nil,
	}
	sessions[player] = session
	loading[player] = nil

	buildLeaderstats(session)
	log("Loaded %s — %s profile, cash=%d, rebirths=%d, joins=%d%s",
		player.Name,
		result.IsNew and "NEW" or "existing",
		data.Cash, data.Rebirths, stats.JoinCount,
		store.IsMock and "  [IN-MEMORY: NOT SAVED]" or "")

	DataService.ProfileLoaded:Fire(player, data)
	pushNow(session)
end

local function onPlayerRemoving(player: Player)
	local session = sessions[player]
	if session then
		releaseSession(session)
	end
end

--------------------------------------------------------------------------
-- Autosave and shutdown
--------------------------------------------------------------------------

local function autosaveLoop()
	while not shuttingDown do
		task.wait(Config.Data.AutosaveInterval)
		if shuttingDown then
			break
		end

		-- Snapshot the list, then spread the writes across a few seconds
		-- so a full server does not hit the DataStore in one burst.
		local list: { Session } = {}
		for _, session in pairs(sessions) do
			if not session.Releasing then
				table.insert(list, session)
			end
		end

		local spacing = if #list > 0 then math.min(1, 5 / #list) else 0
		local saved = 0
		for _, session in ipairs(list) do
			if shuttingDown then
				break
			end
			if sessions[session.Player] == session and not session.Releasing then
				if saveSession(session, false) then
					saved += 1
				end
			end
			task.wait(spacing)
		end

		if #list > 0 then
			log("Autosaved %d/%d profiles", saved, #list)
		end
	end
end

local function onServerClose()
	shuttingDown = true

	local pending = 0
	for _, session in pairs(sessions) do
		pending += 1
		task.spawn(function()
			releaseSession(session)
			pending -= 1
		end)
	end

	-- Wait for everything in flight, including loads that are mid-air.
	local deadline = os.clock() + Config.Data.BindToCloseTimeout
	while (pending > 0 or next(loading) ~= nil) and os.clock() < deadline do
		task.wait(0.1)
	end

	if pending > 0 then
		warnf("Shutdown timed out with %d profile(s) still saving", pending)
	end
end

--------------------------------------------------------------------------
-- Public API
-- Every other service goes through these. None of them trust the caller
-- to have validated anything.
--------------------------------------------------------------------------

--- The live profile, or nil if not loaded. Read freely; to WRITE, use
--- Mutate / AddCash / TrySpendCash so the client is told about it.
function DataService.Get(player: Player): ProfileData?
	local session = sessions[player]
	return session and session.Data or nil
end

function DataService.IsLoaded(player: Player): boolean
	local session = sessions[player]
	return session ~= nil and not session.Releasing
end

--- Yields until the profile is loaded, the player leaves, or timeout.
function DataService.WaitForData(player: Player, timeout: number?): ProfileData?
	local deadline = os.clock() + (timeout or 30)
	while player.Parent and os.clock() < deadline do
		local session = sessions[player]
		if session then
			return session.Data
		end
		task.wait(0.1)
	end
	return nil
end

function DataService.GetCash(player: Player): number
	local session = sessions[player]
	return session and session.Data.Cash or 0
end

--- Adds cash. Returns false (and changes nothing) on a bad amount or an
--- unloaded player. `reason` is for logs only.
function DataService.AddCash(player: Player, amount: number, reason: string): boolean
	local session = sessions[player]
	if not session or session.Releasing then
		return false
	end
	if not isValidAmount(amount) then
		warnf("AddCash rejected bad amount %s for %s (%s)", tostring(amount), player.Name, reason)
		return false
	end
	amount = math.floor(amount)
	if amount == 0 then
		return true
	end
	if amount > Config.Income.AbsoluteMaxSingleCollect then
		warnf("AddCash rejected %d for %s (%s): over the absolute sanity cap", amount, player.Name, reason)
		return false
	end

	local data = session.Data
	data.Cash += amount
	data.Stats.TotalCashEarned = (data.Stats.TotalCashEarned or 0) + amount

	syncLeaderstats(session)
	schedulePush(session)
	DataService.CashChanged:Fire(player, data.Cash, amount, reason)
	return true
end

--- Spends cash if the player can afford it. Returns true only if the
--- cash was actually taken. The check and the deduction cannot be split.
function DataService.TrySpendCash(player: Player, amount: number, reason: string): boolean
	local session = sessions[player]
	if not session or session.Releasing then
		return false
	end
	if not isValidAmount(amount) then
		warnf("TrySpendCash rejected bad amount %s for %s (%s)", tostring(amount), player.Name, reason)
		return false
	end
	amount = math.floor(amount)

	local data = session.Data
	if data.Cash < amount then
		return false
	end

	data.Cash -= amount
	data.Stats.TotalCashSpent = (data.Stats.TotalCashSpent or 0) + amount

	syncLeaderstats(session)
	schedulePush(session)
	DataService.CashChanged:Fire(player, data.Cash, -amount, reason)
	return true
end

--- Runs `mutator(data)` against the live profile, then syncs leaderstats
--- and pushes to the client. Returns false if the player is not loaded or
--- the mutator errors. Do not yield inside the mutator.
function DataService.Mutate(player: Player, mutator: (ProfileData) -> ()): boolean
	local session = sessions[player]
	if not session or session.Releasing then
		return false
	end
	local ok, err = pcall(mutator, session.Data)
	if not ok then
		warnf("Mutate errored for %s: %s", player.Name, tostring(err))
	end
	-- Push even on error: a partial mutation is still the server's truth.
	syncLeaderstats(session)
	schedulePush(session)
	return ok
end

--- Tells the client the profile changed, after a direct write.
function DataService.MarkChanged(player: Player)
	local session = sessions[player]
	if session then
		syncLeaderstats(session)
		schedulePush(session)
	end
end

--- Saves immediately (yields). Use after something the player would be
--- furious to lose, such as a Robux purchase.
function DataService.SaveNow(player: Player): boolean
	local session = sessions[player]
	if not session or session.Releasing then
		return false
	end
	return saveSession(session, false)
end

--- Registers a hook that runs synchronously just before a profile is
--- saved for the last time. Use it to write back transient state.
function DataService.OnBeforeRelease(hook: (Player, ProfileData) -> ())
	table.insert(beforeReleaseHooks, hook)
end

--- True if saves really persist (false = in-memory fallback).
function DataService.IsPersistent(): boolean
	return store ~= nil and not store.IsMock
end

--------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------

function DataService.Start()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	profileUpdatedRemote = remotes:WaitForChild("ProfileUpdated") :: RemoteEvent

	store = SessionStore.new({
		Name = Config.Data.StoreName,
		Scope = Config.Data.StoreScope,
		RetryCount = Config.Data.LoadRetryCount,
		RetryBaseDelay = Config.Data.LoadRetryBaseDelay,
		StaleAfter = Config.Data.SessionLockStaleAfter,
		-- Studio play tests are often stopped mid-load; don't lock the
		-- developer out of their own save for minutes afterwards.
		TakeOverStudioLocks = true,
	})

	if store:ProbeAsync() then
		log("Persistence ON — DataStore '%s' scope '%s'", Config.Data.StoreName, Config.Data.StoreScope)
	else
		warnf("Persistence OFF — using an in-memory store. Progress will NOT be saved.")
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	-- Players who joined before this service started (common in Studio).
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end

	game:BindToClose(onServerClose)
	task.spawn(autosaveLoop)
end

return DataService
