--!strict
--[[
	SessionStore
	ServerScriptService/Server/Modules/SessionStore

	A minimal session-locked DataStore wrapper. This exists because
	ProfileStore was not available to add to this place; if it ever is, this
	module is the thing to replace, and DataService is the only caller.

	The problem it solves: a player can be in two servers at once (rejoining
	fast, teleports, Roblox duplicating a session). Without a lock, both
	servers hold a stale copy and the last one to save wins — which is how
	players lose everything and how duplication exploits work.

	The guarantee: at most one server holds a given key at a time. A server
	takes the lock inside the same UpdateAsync that reads the data, so the
	read and the claim cannot interleave. It refreshes a heartbeat while it
	holds the lock, and every write re-checks that the lock is still ours
	before overwriting. A lock whose heartbeat has gone stale (the owning
	server crashed) can be taken over after StaleAfter seconds.

	Stored record shape:
	  {
	    Data      = <the profile>,
	    Lock      = { Owner = string, PlaceId = number, Heartbeat = number } | nil,
	    CreatedAt = number,
	    UpdatedAt = number,
	  }
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local SessionStore = {}
SessionStore.__index = SessionStore

export type LoadResult = {
	Ok: boolean,
	Data: any?,
	Reason: string?,     -- "Locked" | "Failed" | nil
	IsNew: boolean,
}

-- One identity per running server. In Studio, game.JobId is empty, so we
-- generate one — otherwise every Studio session would look like the same
-- lock owner and would happily steal from itself.
local SERVER_OWNER_ID: string = if RunService:IsStudio() or game.JobId == ""
	then "studio-" .. HttpService:GenerateGUID(false)
	else game.JobId

export type Options = {
	Name: string,
	Scope: string?,
	RetryCount: number?,
	RetryBaseDelay: number?,
	StaleAfter: number?,
	Mock: boolean?,
}

--------------------------------------------------------------------------
-- Mock backing store
-- Used when DataStores are unreachable (API Services off, or an offline
-- Studio session). Keeps development unblocked, loses everything on
-- restart, and says so loudly and repeatedly.
--------------------------------------------------------------------------

local MockBackend = {}
MockBackend.__index = MockBackend

function MockBackend.new()
	return setmetatable({ _data = {} }, MockBackend)
end

function MockBackend:UpdateAsync(key: string, transform: (any) -> any)
	local current = self._data[key]
	local updated = transform(current)
	if updated ~= nil then
		self._data[key] = updated
	end
	return self._data[key]
end

function MockBackend:GetAsync(key: string)
	return self._data[key]
end

--------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------

function SessionStore.new(options: Options)
	local self = setmetatable({}, SessionStore)

	self.Name = options.Name
	self.Scope = options.Scope
	self.RetryCount = options.RetryCount or 5
	self.RetryBaseDelay = options.RetryBaseDelay or 1
	self.StaleAfter = options.StaleAfter or 1800
	self.OwnerId = SERVER_OWNER_ID

	-- key -> true while this server holds the lock
	self._held = {}
	self.IsMock = false

	if options.Mock then
		self._backend = MockBackend.new()
		self.IsMock = true
	else
		local ok, backendOrErr = pcall(function()
			return DataStoreService:GetDataStore(options.Name, options.Scope)
		end)
		if ok then
			self._backend = backendOrErr
		else
			warn(string.format(
				"[SAC/SessionStore] Could not open DataStore '%s': %s. Falling back to an IN-MEMORY store: nothing will persist.",
				options.Name, tostring(backendOrErr)))
			self._backend = MockBackend.new()
			self.IsMock = true
		end
	end

	return self
end

--- Probes whether DataStores actually work from here, and flips to the mock
--- backend if they do not. Call once at startup, before any load.
--- Returns true if real persistence is available.
function SessionStore:ProbeAsync(): boolean
	if self.IsMock then
		return false
	end

	local ok, err = pcall(function()
		return self._backend:GetAsync("__probe__")
	end)

	if ok then
		return true
	end

	warn(string.format(
		"[SAC/SessionStore] DataStore probe failed: %s\n" ..
		"  Falling back to an IN-MEMORY store. NOTHING WILL SAVE.\n" ..
		"  In Studio: File > Game Settings > Security > Enable Studio Access to API Services.",
		tostring(err)))
	self._backend = MockBackend.new()
	self.IsMock = true
	return false
end

--------------------------------------------------------------------------
-- Internals
--------------------------------------------------------------------------

local function freshRecord(): any
	local now = os.time()
	return { Data = nil, Lock = nil, CreatedAt = now, UpdatedAt = now }
end

function SessionStore:_lockIsForeign(lock: any): boolean
	if not lock then
		return false
	end
	if lock.Owner == self.OwnerId then
		return false
	end
	local age = os.time() - (tonumber(lock.Heartbeat) or 0)
	return age < self.StaleAfter
end

function SessionStore:_makeLock(): any
	return { Owner = self.OwnerId, PlaceId = game.PlaceId, Heartbeat = os.time() }
end

--------------------------------------------------------------------------
-- Load
--------------------------------------------------------------------------

--- Takes the lock and returns the stored data (nil if the key is new).
--- Retries with exponential backoff while another live server holds it.
function SessionStore:LoadAsync(key: string): LoadResult
	local lastError: string? = nil
	local lastFailureWasLock = false

	for attempt = 1, self.RetryCount do
		local blockedBy: any = nil
		local isNew = false

		local ok, resultOrErr = pcall(function()
			return self._backend:UpdateAsync(key, function(record)
				-- Roblox may call this transform more than once (it retries
				-- on write conflicts), so reset per-call state every time.
				blockedBy = nil
				isNew = false
				record = record or freshRecord()

				if self:_lockIsForeign(record.Lock) then
					blockedBy = record.Lock
					return nil -- cancel the write, do not take the lock
				end

				isNew = record.Data == nil
				record.Lock = self:_makeLock()
				record.UpdatedAt = os.time()
				return record
			end)
		end)

		if ok and not blockedBy then
			self._held[key] = true
			return {
				Ok = true,
				Data = resultOrErr and resultOrErr.Data or nil,
				IsNew = isNew,
			}
		end

		if not ok then
			lastFailureWasLock = false
			lastError = tostring(resultOrErr)
			warn(string.format("[SAC/SessionStore] Load '%s' attempt %d/%d failed: %s",
				key, attempt, self.RetryCount, lastError))
		else
			lastFailureWasLock = true
			local age = os.time() - (tonumber(blockedBy.Heartbeat) or 0)
			lastError = string.format("locked by %s (%ds ago)", tostring(blockedBy.Owner), age)
			warn(string.format("[SAC/SessionStore] Load '%s' attempt %d/%d: %s",
				key, attempt, self.RetryCount, lastError))
		end

		if attempt < self.RetryCount then
			task.wait(self.RetryBaseDelay * (2 ^ (attempt - 1)))
		end
	end

	return {
		Ok = false,
		Data = nil,
		Reason = if lastFailureWasLock then "Locked" else "Failed",
		IsNew = false,
	}
end

--------------------------------------------------------------------------
-- Save
--------------------------------------------------------------------------

--- Writes `data` and refreshes the heartbeat. If `release` is true, drops
--- the lock so another server can take over immediately.
---
--- Refuses to write if the lock has been taken by another server — that
--- means our copy is stale and writing it would undo their work.
function SessionStore:SaveAsync(key: string, data: any, release: boolean?): (boolean, string?)
	local lostLock = false

	local ok, err = pcall(function()
		self._backend:UpdateAsync(key, function(record)
			lostLock = false -- may be called more than once; see LoadAsync
			record = record or freshRecord()

			if self:_lockIsForeign(record.Lock) then
				lostLock = true
				return nil -- another server owns this now; do not clobber
			end

			record.Data = data
			record.UpdatedAt = os.time()
			record.Lock = if release then nil else self:_makeLock()
			return record
		end)
	end)

	if release then
		self._held[key] = nil
	end

	if lostLock then
		warn(string.format(
			"[SAC/SessionStore] Refused to save '%s': the session lock was taken by another server. " ..
			"This server's copy is stale and was discarded.", key))
		return false, "LostLock"
	end

	if not ok then
		warn(string.format("[SAC/SessionStore] Save '%s' failed: %s", key, tostring(err)))
		return false, tostring(err)
	end

	return true
end

--- Saves and releases in one write.
function SessionStore:ReleaseAsync(key: string, data: any): (boolean, string?)
	return self:SaveAsync(key, data, true)
end

--- True while this server believes it holds the lock for `key`.
function SessionStore:Holds(key: string): boolean
	return self._held[key] == true
end

return SessionStore
