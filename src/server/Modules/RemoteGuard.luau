--!strict
--[[
	RemoteGuard
	ServerScriptService/Server/Modules/RemoteGuard

	Every client -> server remote goes through here. It enforces the parts of
	the guard block that are the same for every remote, so no handler can
	forget them:

	  * Rate limit — a token bucket per player per remote, sized from
	    Config.Remotes[name].MaxPerMinute, plus a global bucket per player
	    from Config.RemoteGlobalMaxPerMinute.
	  * Errors — handlers run in pcall; a crash returns a generic failure to
	    the client and a full warning to the server log, never a stack trace
	    to the client.
	  * Return shape — RemoteFunction handlers return a Result table:
	      { Ok = true, ... }  or  { Ok = false, Message = "why" }

	Ownership, distance, cooldowns and state are specific to each action, so
	handlers still do those themselves, using the helpers below
	(IsWithinReach, Cooldowns).

	The client is never trusted. Handlers receive raw `...any` arguments and
	must type-check every one.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

export type Result = { Ok: boolean, Message: string?, [string]: any }

local RemoteGuard = {}

local GLOBAL_KEY = "__global"
local LOG_THROTTLE_SECONDS = 10

type Bucket = { tokens: number, updatedAt: number }

-- player -> remoteName -> bucket
local buckets: { [Player]: { [string]: Bucket } } = {}
-- player -> last time we logged a rate-limit hit (avoid log floods)
local lastLimitLog: { [Player]: number } = {}

local remotesFolder: Folder? = nil

local function getRemotesFolder(): Folder
	if not remotesFolder then
		remotesFolder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
	end
	return remotesFolder :: Folder
end

--- Takes one token from the bucket. Capacity = maxPerMinute, refilling at
--- maxPerMinute / 60 per second. Allows short bursts, caps sustained spam.
local function takeToken(player: Player, key: string, maxPerMinute: number): boolean
	local playerBuckets = buckets[player]
	if not playerBuckets then
		playerBuckets = {}
		buckets[player] = playerBuckets
	end

	local now = os.clock()
	local bucket = playerBuckets[key]
	if not bucket then
		bucket = { tokens = maxPerMinute, updatedAt = now }
		playerBuckets[key] = bucket
	end

	local refill = (now - bucket.updatedAt) * (maxPerMinute / 60)
	bucket.tokens = math.min(maxPerMinute, bucket.tokens + refill)
	bucket.updatedAt = now

	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

local function passesRateLimit(player: Player, remoteName: string): boolean
	local spec = Config.Remotes[remoteName]
	local perRemote = spec and spec.MaxPerMinute or 30

	-- Per-remote first; only spend a global token if that passed, so spam
	-- on one remote can't drain the player's budget for every other remote.
	local okRemote = takeToken(player, remoteName, perRemote)
	local okGlobal = okRemote and takeToken(player, GLOBAL_KEY, Config.RemoteGlobalMaxPerMinute)

	if okRemote and okGlobal then
		return true
	end

	local now = os.clock()
	if (lastLimitLog[player] or 0) + LOG_THROTTLE_SECONDS < now then
		lastLimitLog[player] = now
		warn(string.format("[SAC/RemoteGuard] Rate limited %s on %s (%s)",
			player.Name, remoteName, okRemote and "global limit" or "per-remote limit"))
	end
	return false
end

local function getRemote(remoteName: string, className: string): Instance
	local spec = Config.Remotes[remoteName]
	assert(spec, "RemoteGuard: '" .. remoteName .. "' is not declared in Config.Remotes")
	assert(spec.Direction == "ClientToServer", "RemoteGuard: '" .. remoteName .. "' is not a ClientToServer remote")
	local remote = getRemotesFolder():WaitForChild(remoteName, 10)
	assert(remote and remote:IsA(className), "RemoteGuard: '" .. remoteName .. "' is missing or not a " .. className)
	return remote :: Instance
end

--------------------------------------------------------------------------
-- Binding
--------------------------------------------------------------------------

--- Binds a RemoteFunction. `handler(player, ...)` must return a Result.
function RemoteGuard.BindFunction(remoteName: string, handler: (Player, ...any) -> Result)
	local remote = getRemote(remoteName, "RemoteFunction") :: RemoteFunction

	remote.OnServerInvoke = function(player: Player, ...: any): Result
		if not passesRateLimit(player, remoteName) then
			return { Ok = false, Message = "Slow down a little." }
		end

		local ok, result = pcall(handler, player, ...)
		if not ok then
			warn(string.format("[SAC/RemoteGuard] %s handler errored for %s: %s",
				remoteName, player.Name, tostring(result)))
			return { Ok = false, Message = "Something went wrong. Try again." }
		end
		if typeof(result) ~= "table" or typeof(result.Ok) ~= "boolean" then
			warn(string.format("[SAC/RemoteGuard] %s handler returned a non-Result value", remoteName))
			return { Ok = false, Message = "Something went wrong. Try again." }
		end
		return result
	end
end

--- Binds a client -> server RemoteEvent. `handler(player, ...)` returns nothing.
function RemoteGuard.BindEvent(remoteName: string, handler: (Player, ...any) -> ())
	local remote = getRemote(remoteName, "RemoteEvent") :: RemoteEvent

	remote.OnServerEvent:Connect(function(player: Player, ...: any)
		if not passesRateLimit(player, remoteName) then
			return
		end
		local ok, err = pcall(handler, player, ...)
		if not ok then
			warn(string.format("[SAC/RemoteGuard] %s handler errored for %s: %s",
				remoteName, player.Name, tostring(err)))
		end
	end)
end

--- A server -> client RemoteEvent declared in Config.Remotes.
function RemoteGuard.GetClientEvent(remoteName: string): RemoteEvent
	local spec = Config.Remotes[remoteName]
	assert(spec and spec.Direction == "ServerToClient", "RemoteGuard: '" .. remoteName .. "' is not a ServerToClient remote")
	return getRemotesFolder():WaitForChild(remoteName) :: RemoteEvent
end

--------------------------------------------------------------------------
-- Helpers for the per-action checks
--------------------------------------------------------------------------

--- The player's HumanoidRootPart, if they have a living character.
function RemoteGuard.GetRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

--- True if the player's character is within reach of `position`.
--- Default reach is the prompt distance plus a little slack for latency.
function RemoteGuard.IsWithinReach(player: Player, position: Vector3, maxDistance: number?): boolean
	local root = RemoteGuard.GetRoot(player)
	if not root then
		return false
	end
	local reach = maxDistance or (Config.Prompts.MaxActivationDistance + Config.Prompts.ServerDistanceSlack)
	return (root.Position - position).Magnitude <= reach
end

--- Per-player cooldown timers, keyed by action name.
---   if not RemoteGuard.Cooldowns.Ready(player, "Steal") then ... end
---   RemoteGuard.Cooldowns.Start(player, "Steal", 30)
local cooldowns: { [Player]: { [string]: number } } = {}

RemoteGuard.Cooldowns = {}

function RemoteGuard.Cooldowns.Remaining(player: Player, action: string): number
	local until_ = cooldowns[player] and cooldowns[player][action]
	if not until_ then
		return 0
	end
	return math.max(0, until_ - os.clock())
end

function RemoteGuard.Cooldowns.Ready(player: Player, action: string): boolean
	return RemoteGuard.Cooldowns.Remaining(player, action) <= 0
end

function RemoteGuard.Cooldowns.Start(player: Player, action: string, seconds: number)
	local map = cooldowns[player]
	if not map then
		map = {}
		cooldowns[player] = map
	end
	map[action] = os.clock() + seconds
end

-- Forget everything about a player when they leave.
Players.PlayerRemoving:Connect(function(player)
	buckets[player] = nil
	lastLimitLog[player] = nil
	cooldowns[player] = nil
end)

return RemoteGuard
