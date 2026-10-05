--!strict
--[[
	ProfileTemplate
	ServerScriptService/Server/Modules/ProfileTemplate

	The shape of a player's saved data, plus the rules for bringing an old
	saved profile up to the current shape.

	Two separate mechanisms, and the difference matters:

	  * RECONCILE fills in keys that exist in the template but are missing
	    from the saved data. This is how you ADD a field. It needs no
	    migration and no version bump — just add it to Template.

	  * MIGRATE runs when you need to CHANGE or REMOVE an existing field,
	    or reinterpret one. That needs a version bump and a migration
	    function, because reconcile alone cannot know the old meaning.

	Nests are a dense array of length Config.Plot.MaxNests. An empty nest is
	the boolean `false`, never nil — JSON arrays cannot carry holes, so a nil
	in the middle would silently truncate the array on save.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local ProfileTemplate = {}

-- Bump this ONLY when you add a migration below.
ProfileTemplate.SchemaVersion = 1

-- How many purchase receipts to remember for idempotency. Roblox retries a
-- failed receipt for a limited window, so this only has to outlive that.
ProfileTemplate.MaxRememberedPurchases = 200

export type NestSlot = {
	Kind: string,            -- "Egg" | "Creature"
	EggId: string?,          -- set when Kind == "Egg"
	CreatureId: string?,     -- set when Kind == "Creature"
	Rarity: string?,         -- set when Kind == "Creature"
	Mutation: string?,       -- reserved for the mutation layer
	Heat: number,            -- 0..Config.Heat.Max, meaningful for eggs
	Vault: number,           -- uncollected cash, meaningful for creatures
	AcquiredAt: number,      -- os.time() when it entered this nest
	LastIncomeAt: number,    -- os.time() of the last income tick
	StolenFrom: number?,     -- userId, if this was taken from someone
	Away: boolean?,          -- being carried by a thief right now (Step 4)
	AwayThief: number?,      -- userId of the thief while Away
	ImmuneUntil: number?,    -- os.time(); can't be stolen again before this
}

export type ProfileData = {
	SchemaVersion: number,
	Cash: number,
	Rebirths: number,
	Nests: { any },                       -- NestSlot | false
	Upgrades: { [string]: number },       -- upgradeId -> level (1-indexed)
	Codex: { [string]: boolean },         -- creatureId -> discovered
	Purchases: { [string]: number },      -- PurchaseId -> os.time() granted
	Buffs: { [string]: number },          -- buffName -> expiry os.time()
	Stats: { [string]: any },
	SpawnLockUntil: number,
	PendingEggs: { string },              -- bought eggs waiting for a free nest
	PendingMaxHeat: number,               -- Max Heat purchases waiting for an egg
	Retention: RetentionData,             -- Step 7.5 (RetentionService)
}

-- Daily rewards, spin wheel and offline earnings (RetentionService). All
-- times are os.time() values. Playtime gifts are per server visit, so they
-- live in server memory, not here.
export type RetentionData = {
	DailyLastDay: number,      -- UTC day number (os.time() // DayLength) of the last daily claim; 0 = never
	DailyStreak: number,       -- which day of the 7-day cycle was claimed last (0..7)
	SpinNextFreeAt: number,    -- the free spin is ready from this time (0 = ready now)
	SpinExtra: number,         -- bought spins not used yet
	LastSeenAt: number,        -- last time this player was known to be online
	PendingOffline: number,    -- offline cash waiting to be claimed
	LastOfflineAmount: number, -- the last offline cash claimed (what "Double" pays again)
}

--------------------------------------------------------------------------
-- The template
--------------------------------------------------------------------------

local function buildEmptyNests(): { any }
	local nests = table.create(Config.Plot.MaxNests, false)
	for i = 1, Config.Plot.MaxNests do
		nests[i] = false
	end
	return nests
end

local function buildDefaultUpgrades(): { [string]: number }
	local upgrades = {}
	for _, upgradeId in ipairs(Config.UpgradeOrder) do
		upgrades[upgradeId] = 1 -- level 1 is the free starting level
	end
	return upgrades
end

--- A brand new profile. Always returns a fresh deep copy.
function ProfileTemplate.new(): ProfileData
	return {
		SchemaVersion = ProfileTemplate.SchemaVersion,
		Cash = if Config.Debug.GrantTestCash then Config.Debug.TestCashAmount else Config.Economy.StartingCash,
		Rebirths = 0,
		Nests = buildEmptyNests(),
		Upgrades = buildDefaultUpgrades(),
		Codex = {},
		Purchases = {},
		Buffs = {},
		Stats = {
			TotalCashEarned = 0,
			TotalCashSpent = 0,
			Hatches = 0,
			HatchesByRarity = {},
			EggsBought = 0,
			StealsCommitted = 0,
			StealsSuffered = 0,
			CapturesWon = 0,
			Playtime = 0,
			JoinCount = 0,
			FirstJoinAt = 0,  -- filled on first load
			LastJoinAt = 0,
		},
		SpawnLockUntil = 0,
		PendingEggs = {},
		PendingMaxHeat = 0,
		Retention = {
			DailyLastDay = 0,
			DailyStreak = 0,
			SpinNextFreeAt = 0, -- a brand-new player has a free spin ready
			SpinExtra = 0,
			LastSeenAt = 0,
			PendingOffline = 0,
			LastOfflineAmount = 0,
		},
	}
end

--------------------------------------------------------------------------
-- Migrations
-- Index N migrates a profile from SchemaVersion N to N + 1.
-- Never delete a migration, even when it looks obsolete: a player who has
-- not logged in for a year still needs to walk the whole chain.
--------------------------------------------------------------------------

local Migrations: { (ProfileData) -> () } = {
	-- [1] = function(data) ... end,  -- v1 -> v2
}

--------------------------------------------------------------------------
-- Reconcile
--------------------------------------------------------------------------

--- Recursively fills missing keys in `data` from `template`.
--- Does not touch keys that already exist, and never removes anything.
local function reconcileInto(data: { [any]: any }, template: { [any]: any })
	for key, templateValue in pairs(template) do
		local existing = data[key]
		if existing == nil then
			if typeof(templateValue) == "table" then
				local copy = {}
				reconcileInto(copy, templateValue)
				data[key] = copy
			else
				data[key] = templateValue
			end
		elseif typeof(templateValue) == "table" and typeof(existing) == "table" then
			reconcileInto(existing, templateValue)
		end
	end
end

--------------------------------------------------------------------------
-- Repair
-- Defends against data that is the right shape but nonsensical, whether
-- from an old bug, a partial write, or tampering upstream.
--------------------------------------------------------------------------

local function repair(data: ProfileData, context: string): { string }
	local fixes: { string } = {}

	local function fix(message: string)
		table.insert(fixes, message)
	end

	-- Cash and rebirths must be sane non-negative numbers.
	if typeof(data.Cash) ~= "number" or data.Cash ~= data.Cash or data.Cash < 0 then
		fix(string.format("Cash was %s, reset to 0", tostring(data.Cash)))
		data.Cash = 0
	end
	data.Cash = math.floor(data.Cash)

	if typeof(data.Rebirths) ~= "number" or data.Rebirths < 0 then
		fix(string.format("Rebirths was %s, reset to 0", tostring(data.Rebirths)))
		data.Rebirths = 0
	end
	data.Rebirths = math.floor(data.Rebirths)

	-- Nests must be a dense array of exactly MaxNests entries.
	if typeof(data.Nests) ~= "table" then
		fix("Nests was not a table, rebuilt empty")
		data.Nests = buildEmptyNests()
	end
	for i = 1, Config.Plot.MaxNests do
		local slot = data.Nests[i]
		if slot == nil then
			data.Nests[i] = false
		elseif slot ~= false then
			if typeof(slot) ~= "table" or (slot.Kind ~= "Egg" and slot.Kind ~= "Creature") then
				fix(string.format("Nest %d held garbage, cleared", i))
				data.Nests[i] = false
			elseif slot.Kind == "Egg" and not Config.Eggs[slot.EggId or ""] then
				fix(string.format("Nest %d held unknown egg '%s', cleared", i, tostring(slot.EggId)))
				data.Nests[i] = false
			elseif slot.Kind == "Creature" and not Config.CreaturesById[slot.CreatureId or ""] then
				fix(string.format("Nest %d held unknown creature '%s', cleared", i, tostring(slot.CreatureId)))
				data.Nests[i] = false
			else
				slot.Heat = math.clamp(tonumber(slot.Heat) or 0, 0, Config.Heat.Max)
				slot.Vault = math.max(0, math.floor(tonumber(slot.Vault) or 0))
				-- A slot still marked Away means the last session ended while a
				-- thief was carrying it and before they claimed it (claiming
				-- clears the slot; an owner leaving forfeits it). The steal never
				-- completed, so the item is home.
				if slot.Away then
					fix(string.format("Nest %d was mid-steal when the last session ended; returned home", i))
					slot.Away = nil
					slot.AwayThief = nil
				end
			end
		end
	end
	-- Drop anything past MaxNests (can happen if MaxNests is lowered).
	for i = #data.Nests, Config.Plot.MaxNests + 1, -1 do
		if data.Nests[i] ~= nil then
			fix(string.format("Dropped nest %d beyond MaxNests", i))
			data.Nests[i] = nil
		end
	end

	-- Upgrade levels must exist and be within their table.
	if typeof(data.Upgrades) ~= "table" then
		fix("Upgrades was not a table, reset to defaults")
		data.Upgrades = buildDefaultUpgrades()
	end
	for _, upgradeId in ipairs(Config.UpgradeOrder) do
		local levels = Config.Upgrades[upgradeId].Levels
		local level = tonumber(data.Upgrades[upgradeId]) or 1
		local clamped = math.clamp(math.floor(level), 1, #levels)
		if clamped ~= data.Upgrades[upgradeId] then
			if data.Upgrades[upgradeId] ~= nil and clamped ~= level then
				fix(string.format("Upgrade %s level %s clamped to %d", upgradeId, tostring(data.Upgrades[upgradeId]), clamped))
			end
			data.Upgrades[upgradeId] = clamped
		end
	end
	-- Remove upgrades that no longer exist in Config.
	for upgradeId in pairs(data.Upgrades) do
		if not Config.Upgrades[upgradeId] then
			fix(string.format("Removed unknown upgrade '%s'", upgradeId))
			data.Upgrades[upgradeId] = nil
		end
	end

	-- Codex entries must name real creatures.
	if typeof(data.Codex) ~= "table" then
		data.Codex = {}
	end
	for creatureId in pairs(data.Codex) do
		if not Config.CreaturesById[creatureId] then
			fix(string.format("Removed unknown codex entry '%s'", creatureId))
			data.Codex[creatureId] = nil
		end
	end

	-- Expired buffs are dropped on load rather than carried.
	if typeof(data.Buffs) ~= "table" then
		data.Buffs = {}
	end
	local now = os.time()
	for buffName, expiry in pairs(data.Buffs) do
		if typeof(expiry) ~= "number" or expiry <= now then
			data.Buffs[buffName] = nil
		end
	end

	-- Trim the purchase log so it cannot grow without bound.
	if typeof(data.Purchases) ~= "table" then
		data.Purchases = {}
	end
	local purchaseList: { { id: string, at: number } } = {}
	for purchaseId, at in pairs(data.Purchases) do
		table.insert(purchaseList, { id = purchaseId, at = tonumber(at) or 0 })
	end
	if #purchaseList > ProfileTemplate.MaxRememberedPurchases then
		table.sort(purchaseList, function(a, b)
			return a.at > b.at -- newest first
		end)
		for i = ProfileTemplate.MaxRememberedPurchases + 1, #purchaseList do
			data.Purchases[purchaseList[i].id] = nil
		end
		fix(string.format("Trimmed purchase log from %d to %d entries", #purchaseList, ProfileTemplate.MaxRememberedPurchases))
	end

	if typeof(data.SpawnLockUntil) ~= "number" then
		data.SpawnLockUntil = 0
	end

	-- Paid-for rewards waiting to be applied must stay valid.
	if typeof(data.PendingEggs) ~= "table" then
		data.PendingEggs = {}
	end
	for i = #data.PendingEggs, 1, -1 do
		if not Config.Eggs[data.PendingEggs[i]] then
			fix(string.format("Removed unknown pending egg '%s'", tostring(data.PendingEggs[i])))
			table.remove(data.PendingEggs, i)
		end
	end
	if typeof(data.PendingMaxHeat) ~= "number" or data.PendingMaxHeat < 0 then
		data.PendingMaxHeat = 0
	end
	data.PendingMaxHeat = math.floor(data.PendingMaxHeat)

	-- Retention (Step 7.5): every field a whole, finite, non-negative number.
	if typeof(data.Retention) ~= "table" then
		fix("Retention was not a table, reset")
		data.Retention = ProfileTemplate.new().Retention
	end
	local retention = data.Retention :: any
	for key, default in pairs(ProfileTemplate.new().Retention :: any) do
		local value = retention[key]
		if typeof(value) ~= "number" or value ~= value or value == math.huge or value < 0 then
			if value ~= nil then
				fix(string.format("Retention.%s was %s, reset", key, tostring(value)))
			end
			retention[key] = default
		else
			retention[key] = math.floor(value)
		end
	end
	local retentionConfig = Config.Retention
	retention.DailyStreak = math.clamp(retention.DailyStreak, 0, #retentionConfig.Daily.Rewards)
	-- Times in the future can only come from a bad clock or bad data.
	if retention.LastSeenAt > now then
		retention.LastSeenAt = now
	end
	if retention.DailyLastDay > now // retentionConfig.Daily.DayLength then
		fix("Retention.DailyLastDay was in the future, reset")
		retention.DailyLastDay = 0
		retention.DailyStreak = 0
	end
	if retention.SpinNextFreeAt > now + retentionConfig.Spin.FreeEvery then
		retention.SpinNextFreeAt = now + retentionConfig.Spin.FreeEvery
	end
	-- Waiting offline cash may be paid twice over by the Double product, so
	-- it must stay under half of what one AddCash accepts.
	local maxPending = math.min(retentionConfig.MaxCashReward, Config.Income.AbsoluteMaxSingleCollect // 2)
	retention.PendingOffline = math.min(retention.PendingOffline, maxPending)
	retention.LastOfflineAmount = math.min(retention.LastOfflineAmount, maxPending)

	if #fixes > 0 then
		warn(string.format("[SAC/Profile] Repaired %s: %s", context, table.concat(fixes, "; ")))
	end

	return fixes
end

--------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------

--- Brings raw saved data up to the current schema, in place.
--- Safe to call on a brand new profile.
function ProfileTemplate.Normalize(data: ProfileData, context: string): ProfileData
	local fromVersion = tonumber(data.SchemaVersion) or 1

	-- Walk the migration chain.
	while fromVersion < ProfileTemplate.SchemaVersion do
		local migrate = Migrations[fromVersion]
		if not migrate then
			warn(string.format(
				"[SAC/Profile] %s is at schema v%d but no migration to v%d exists. Reconciling only.",
				context, fromVersion, fromVersion + 1))
			break
		end
		migrate(data)
		fromVersion += 1
		data.SchemaVersion = fromVersion
	end

	-- A profile saved by a NEWER server than this one. Do not touch it —
	-- reconciling could destroy fields this build does not know about.
	if fromVersion > ProfileTemplate.SchemaVersion then
		warn(string.format(
			"[SAC/Profile] %s is at schema v%d but this server only knows v%d. Loading read-only-ish; do not downgrade.",
			context, fromVersion, ProfileTemplate.SchemaVersion))
	end

	data.SchemaVersion = math.max(fromVersion, ProfileTemplate.SchemaVersion)
	reconcileInto(data, ProfileTemplate.new())
	repair(data, context)

	return data
end

--- Deep copy, used when handing data across a boundary.
function ProfileTemplate.DeepCopy<T>(value: T): T
	if typeof(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in pairs(value :: any) do
		copy[k] = ProfileTemplate.DeepCopy(v)
	end
	return (copy :: any) :: T
end

return ProfileTemplate
