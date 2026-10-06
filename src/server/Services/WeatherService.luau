-- Server-side weather authority. The schedule itself is fully deterministic
-- (see Shared.Util.WeatherSchedule), so this module is mostly a replication
-- shim: it diffs the active set every TICK_SECONDS and fires started/ended
-- remotes for transitions, plus answers a sync remote for newly-joined clients
-- so they don't have to wait for the next start/end edge to populate their UI.
--
-- The module deliberately does NOT push state on every tick -- the client
-- recomputes the same schedule locally from os.time(), so the only thing that
-- needs to cross the wire is "this id just turned on/off."

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")
local DigConfig = require(ConfigFolder:WaitForChild("DigConfig"))
local WeatherConfig = require(ConfigFolder:WaitForChild("WeatherConfig"))
local RemoteRegistry = require(UtilFolder:WaitForChild("RemoteRegistry"))
local WeatherSchedule = require(UtilFolder:WaitForChild("WeatherSchedule"))

local WeatherService = {}
local started = false

local startedRemote: RemoteEvent? = nil
local endedRemote: RemoteEvent? = nil
local syncRemote: RemoteEvent? = nil

-- Mirror of the active set so the tick loop can detect transitions cheaply
-- without holding more than the diff state.
type ActiveEntry = {
	luckMultiplier: number,
	startedAt: number,
	expiresAt: number,
}

local activeById: { [WeatherConfig.WeatherId]: ActiveEntry } = {}

local function snapshotActive(): { { id: WeatherConfig.WeatherId, expiresAt: number } }
	local snapshot = {}
	for id, entry in activeById do
		table.insert(snapshot, { id = id, expiresAt = entry.expiresAt })
	end
	return snapshot
end

local function rebuildActive(now: number): {
	added: { { id: WeatherConfig.WeatherId, expiresAt: number } },
	removed: { WeatherConfig.WeatherId },
}
	local added: { { id: WeatherConfig.WeatherId, expiresAt: number } } = {}
	local removed: { WeatherConfig.WeatherId } = {}

	local current = WeatherSchedule.getActive(now)
	local seen: { [WeatherConfig.WeatherId]: boolean } = {}

	for _, weather in current do
		seen[weather.id] = true
		local existing = activeById[weather.id]
		if not existing or existing.startedAt ~= weather.startedAt then
			-- A "new occurrence" either is a fresh start or a same-id occurrence
			-- whose start slot moved (only possible across server clock skew or
			-- pause; we treat it as a new event so the client gets a fresh UI).
			activeById[weather.id] = {
				luckMultiplier = weather.luckMultiplier,
				startedAt = weather.startedAt,
				expiresAt = weather.expiresAt,
			}
			table.insert(added, { id = weather.id, expiresAt = weather.expiresAt })
		end
	end

	for id in activeById do
		if not seen[id] then
			activeById[id] = nil
			table.insert(removed, id)
		end
	end

	return { added = added, removed = removed }
end

local function fireDiff(diff)
	if not startedRemote or not endedRemote then
		return
	end

	for _, entry in diff.added do
		startedRemote:FireAllClients(entry.id, entry.expiresAt)
	end
	for _, id in diff.removed do
		endedRemote:FireAllClients(id)
	end
end

local function onSyncRequest(player: Player)
	if not syncRemote then
		return
	end

	syncRemote:FireClient(player, snapshotActive())
end

-- Public: ground truth multiplier used by the dig pipeline. Computed live so
-- it never lags the schedule even between ticks.
function WeatherService.getLuckMultiplier(): number
	return WeatherSchedule.getLuckMultiplier(os.time())
end

-- Public: snapshot for any server-side consumer that wants to inspect what's
-- currently running (e.g. for analytics or debug commands).
function WeatherService.getActive()
	return WeatherSchedule.getActive(os.time())
end

function WeatherService.start()
	if started then
		return
	end
	started = true

	startedRemote = RemoteRegistry.ensureRemote(DigConfig.WEATHER_REMOTE_FOLDER, DigConfig.WEATHER_STARTED_REMOTE)
	endedRemote = RemoteRegistry.ensureRemote(DigConfig.WEATHER_REMOTE_FOLDER, DigConfig.WEATHER_ENDED_REMOTE)
	syncRemote = RemoteRegistry.ensureRemote(DigConfig.WEATHER_REMOTE_FOLDER, DigConfig.WEATHER_SYNC_REMOTE)

	-- Sync request handler. Clients fire this on join with no payload; the
	-- server replies on the same remote with the current active list so the
	-- client UI hydrates without waiting for the next started/ended edge.
	local syncRemoteTyped = syncRemote :: RemoteEvent
	syncRemoteTyped.OnServerEvent:Connect(function(player)
		onSyncRequest(player)
	end)

	-- Late-binding fallback: even without the explicit sync request we hand
	-- new joiners the active set so the HUD never starts empty mid-event.
	Players.PlayerAdded:Connect(function(player)
		task.defer(onSyncRequest, player)
	end)

	-- Seed the cache without firing remotes (no clients yet to receive the
	-- "started" edge anyway; they'll get the active set via sync on join).
	rebuildActive(os.time())

	task.spawn(function()
		while started do
			task.wait(WeatherConfig.TICK_SECONDS)
			local diff = rebuildActive(os.time())
			if #diff.added > 0 or #diff.removed > 0 then
				fireDiff(diff)
			end
		end
	end)
end

return WeatherService
