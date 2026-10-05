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
		Cash = Config.Debug.GrantTestCash and Config.Debug.TestCashAmount or 0,
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
