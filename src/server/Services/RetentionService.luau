--!strict
--[[
	RetentionService
	ServerScriptService/Server/Services/RetentionService

	Reasons to come back (Step 7.5). Every rule is decided here; the four
	client screens only show what this service sends them and ask for
	things by name.

	  Daily Rewards   One claim per UTC day (day = os.time() // DayLength).
	                  Claiming the day after your last claim continues the
	                  7-day streak; missing a day starts again at day 1;
	                  after day 7 it goes round again.
	  Spin Wheel      One free spin every Spin.FreeEvery seconds of real time
	                  (a new player has one ready), plus bought spins
	                  (Extra Spins product, granted by MonetizationService).
	                  The SERVER rolls the prize, grants it at once and
	                  returns the slot number; the client spins the wheel to
	                  land on it.
	  Playtime Gifts  Unlock at set minutes after your profile loaded on
	                  this server; each claimable once per visit. Kept in
	                  server memory only (a new visit starts a new set).
	  Offline Cash    "Last seen" is written every minute and on leaving. On
	                  joining after at least MinAwaySeconds away, a share of
	                  your creature income for the time away (capped at
	                  MaxHours) is saved as PendingOffline until you claim it
	                  — saved first, so a crash can't lose it. Double
	                  Offline Cash (Robux) is granted by MonetizationService.

	Rewards (Config.Retention) are lists of items: income-scaled cash, eggs
	(best unlocked egg if the named one is locked; saved for a free nest if
	there's no room), potion-style buffs, and Instant Hatch — granted through
	MonetizationService's helpers so they behave exactly like the products.

	The client gets everything it shows through RetentionState: on join,
	whenever something changes, and every StatePushInterval seconds (cash
	amounts follow your income). Times are server os.time() values with the
	server's "now" attached, so the client can count down correctly.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Server = ServerScriptService:WaitForChild("Server")
local Modules = Server:WaitForChild("Modules")
local Services = Server:WaitForChild("Services")
local RemoteGuard = require(Modules:WaitForChild("RemoteGuard"))
local Notifier = require(Modules:WaitForChild("Notifier"))
local ProfileTemplate = require(Modules:WaitForChild("ProfileTemplate"))
local DataService = require(Services:WaitForChild("DataService"))
local NestService = require(Services:WaitForChild("NestService"))
local MonetizationService = require(Services:WaitForChild("MonetizationService"))

type Reward = Config.RetentionReward
type Item = Config.RetentionItem
type ProfileData = ProfileTemplate.ProfileData

-- Per-player memory for this server visit.
type Session = {
	StartedAt: number,          -- os.time() the profile loaded here (playtime gifts count from this)
	GiftsClaimed: { [number]: boolean },
	AwaySeconds: number,        -- how long they were gone before this visit
	OfflineComputed: boolean,   -- offline cash has been worked out for this visit
	PushPending: boolean,
	SavePending: boolean,
	LastSaveAt: number,         -- os.clock()
}

local RetentionService = {}

local R = Config.Retention
local sessions: { [Player]: Session } = {}
local stateRemote: RemoteEvent? = nil
local rng = Random.new()

local function log(fmt: string, ...: any)
	if Config.Debug.Verbose then
		print(string.format("[SAC/Retention] " .. fmt, ...))
	end
end

local function warnf(fmt: string, ...: any)
	warn(string.format("[SAC/Retention] " .. fmt, ...))
end

local function formatClock(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	local hours = seconds // 3600
	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, (seconds % 3600) // 60, seconds % 60)
	end
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function today(): number
	return os.time() // R.Daily.DayLength
end

--- Biggest cash amount one reward may pay (AddCash refuses more).
local function maxCash(): number
	return math.min(R.MaxCashReward, Config.Income.AbsoluteMaxSingleCollect)
end

--- Biggest PendingOffline may get: Double pays it twice in one AddCash.
local function maxPendingOffline(): number
	return math.min(R.MaxCashReward, Config.Income.AbsoluteMaxSingleCollect // 2)
end

--------------------------------------------------------------------------
-- Rewards: resolving, describing, granting
--------------------------------------------------------------------------

--- The egg this player actually gets for `eggId`: that egg if they've
--- unlocked it, else the most expensive egg they have unlocked.
local function unlockedEgg(player: Player, eggId: string): string
	local data = DataService.Get(player)
	local rebirths = if data then data.Rebirths else 0
	local wanted = Config.Eggs[eggId]
	if wanted and wanted.RequiredRebirths <= rebirths then
		return eggId
	end
	local best, bestPrice = Config.Economy.RescueEggId, -1
	for _, id in ipairs(Config.EggOrder) do
		local egg = Config.Eggs[id]
		if egg.RequiredRebirths <= rebirths and egg.Price > bestPrice then
			best, bestPrice = id, egg.Price
		end
	end
	return best
end

local function cashAmount(player: Player, item: Item): number
	local scaled = math.floor((item.Minutes or 0) * 60 * MonetizationService.GetTotalCreatureIncome(player))
	return math.min(maxCash(), math.max(item.Base or 0, scaled))
end

local function itemText(player: Player, item: Item): string
	if item.Kind == "Cash" then
		return "$" .. Config.FormatNumber(cashAmount(player, item))
	elseif item.Kind == "Egg" then
		local egg = Config.Eggs[unlockedEgg(player, item.EggId or "")]
		local count = item.Count or 1
		return if count > 1 then string.format("%dx %s", count, egg.Name) else egg.Name
	elseif item.Kind == "Buff" then
		local name = R.BuffNames[item.Buff or ""] or tostring(item.Buff)
		return string.format("%s %dm", name, (item.Duration or 0) // 60)
	elseif item.Kind == "InstantHatch" then
		local count = item.Count or 1
		return if count > 1 then string.format("%dx Instant Hatch", count) else "Instant Hatch"
	end
	return "?"
end

local function itemIcon(item: Item): string
	if item.Kind == "Buff" then
		return R.Icons[item.Buff or ""] or R.Icons.Cash
	end
	return R.Icons[item.Kind] or R.Icons.Cash
end

--- What the client shows for a reward: text, icon, and a short line (the
--- first item) for small cards.
local function describe(player: Player, reward: Reward): { [string]: any }
	local parts = {}
	for _, item in ipairs(reward.Items) do
		table.insert(parts, itemText(player, item))
	end
	local first = reward.Items[1]
	return {
		Text = reward.Label or table.concat(parts, " + "),
		Detail = table.concat(parts, " + "),
		Short = reward.Label or parts[1] or "?",
		Icon = if first then itemIcon(first) else R.Icons.Cash,
	}
end

--- Gives one item. Never yields. Returns what was given, as text.
local function grantItem(player: Player, item: Item, reason: string): string
	if item.Kind == "Cash" then
		local amount = cashAmount(player, item)
		if not DataService.AddCash(player, amount, reason) then
			warnf("AddCash refused %d for %s (%s)", amount, player.Name, reason)
		end
		return "$" .. Config.FormatNumber(amount)

	elseif item.Kind == "Egg" then
		local eggId = unlockedEgg(player, item.EggId or "")
		local count = item.Count or 1
		local _, saved = MonetizationService.GrantEggs(player, eggId, count)
		local text = itemText(player, item)
		if saved > 0 then
			text ..= " (saved for your next free nest)"
		end
		return text

	elseif item.Kind == "Buff" then
		local buff = item.Buff or ""
		if R.BuffNames[buff] and (item.Duration or 0) > 0 then
			MonetizationService.ExtendBuff(player, buff, item.Duration :: number)
		else
			warnf("Reward has an unknown buff '%s'", tostring(buff))
		end
		return itemText(player, item)

	elseif item.Kind == "InstantHatch" then
		local hatchedNow = false
		for _ = 1, item.Count or 1 do
			if MonetizationService.GrantInstantHatch(player) then
				hatchedNow = true
			end
		end
		return itemText(player, item) .. (if hatchedNow then "" else " (saved for your next egg)")
	end

	warnf("Reward has an unknown kind '%s'", tostring(item.Kind))
	return "?"
end

local function grantReward(player: Player, reward: Reward, reason: string): string
	local parts = {}
	for _, item in ipairs(reward.Items) do
		table.insert(parts, grantItem(player, item, reason))
	end
	return table.concat(parts, " + ")
end

--------------------------------------------------------------------------
-- Status (what's claimable right now)
--------------------------------------------------------------------------

type DailyStatus = { CanClaim: boolean, Day: number, ClaimedCount: number, NextClaimAt: number }

local function dailyStatus(data: ProfileData): DailyStatus
	local r = data.Retention
	local t = today()
	local length = #R.Daily.Rewards
	local nextClaimAt = (t + 1) * R.Daily.DayLength
	if r.DailyLastDay < t then
		-- Claimed yesterday: carry on. Otherwise (missed a day, or never):
		-- back to day 1.
		local day = 1
		if r.DailyLastDay == t - 1 and r.DailyStreak >= 1 then
			day = (r.DailyStreak % length) + 1
		end
		return { CanClaim = true, Day = day, ClaimedCount = day - 1, NextClaimAt = 0 }
	end
	return { CanClaim = false, Day = r.DailyStreak, ClaimedCount = r.DailyStreak, NextClaimAt = nextClaimAt }
end

local function freeSpinReady(data: ProfileData): boolean
	return data.Retention.SpinNextFreeAt <= os.time()
end

local function spinsAvailable(data: ProfileData): number
	return (if freeSpinReady(data) then 1 else 0) + data.Retention.SpinExtra
end

local function giftUnlockAt(session: Session, index: number): number
	return session.StartedAt + (R.Playtime.Gifts[index].Minutes or 0) * 60
end

--------------------------------------------------------------------------
-- Pushing state to the client
--------------------------------------------------------------------------

local function buildState(player: Player): { [string]: any }?
	local data = DataService.Get(player)
	local session = sessions[player]
	if not data or not session then
		return nil
	end
	local r = data.Retention
	local now = os.time()

	local daily = dailyStatus(data)
	local dailyRewards = {}
	for i, reward in ipairs(R.Daily.Rewards) do
		dailyRewards[i] = describe(player, reward)
	end

	local prizes = {}
	for i, prize in ipairs(R.Spin.Prizes) do
		prizes[i] = describe(player, prize)
	end

	local gifts = {}
	for i, gift in ipairs(R.Playtime.Gifts) do
		local entry = describe(player, gift)
		entry.UnlockAt = giftUnlockAt(session, i)
		entry.Claimed = session.GiftsClaimed[i] == true
		gifts[i] = entry
	end

	return {
		ServerNow = now,
		Daily = {
			Enabled = R.Daily.Enabled,
			CanClaim = daily.CanClaim,
			Day = daily.Day,
			ClaimedCount = daily.ClaimedCount,
			NextClaimAt = daily.NextClaimAt,
			Rewards = dailyRewards,
		},
		Spin = {
			Enabled = R.Spin.Enabled,
			FreeReady = freeSpinReady(data),
			NextFreeAt = r.SpinNextFreeAt,
			Extra = r.SpinExtra,
			Spins = spinsAvailable(data),
			Prizes = prizes,
		},
		Gifts = {
			Enabled = R.Playtime.Enabled,
			List = gifts,
		},
		Offline = {
			Enabled = R.Offline.Enabled,
			Pending = r.PendingOffline,
			AwaySeconds = session.AwaySeconds,
			-- False for the first ComputeDelay seconds of a visit: this
			-- visit's offline cash isn't known yet (the Daily screen waits
			-- for it so it never pops up under the offline popup).
			Computed = session.OfflineComputed,
		},
	}
end

local function pushNow(player: Player)
	local session = sessions[player]
	if session then
		session.PushPending = false
	end
	local state = buildState(player)
	if state and stateRemote and player.Parent then
		stateRemote:FireClient(player, state)
	end
end

--- Queues a push; several changes in one frame send one push.
local function push(player: Player)
	local session = sessions[player]
	if not session or session.PushPending then
		return
	end
	session.PushPending = true
	task.defer(function()
		if sessions[player] == session and session.PushPending then
			pushNow(player)
		end
	end)
end

--------------------------------------------------------------------------
-- Saving (coalesced: claims save quickly, but never hammer the DataStore)
--------------------------------------------------------------------------

local function requestSave(player: Player)
	local session = sessions[player]
	if not session or session.SavePending then
		return
	end
	session.SavePending = true
	local delay = math.max(0, session.LastSaveAt + R.SaveDebounce - os.clock())
	task.delay(delay, function()
		session.SavePending = false
		session.LastSaveAt = os.clock()
		if player.Parent and DataService.IsLoaded(player) then
			DataService.SaveNow(player)
		end
	end)
end

--------------------------------------------------------------------------
-- Offline earnings
--------------------------------------------------------------------------

--- Offline cash for `awaySeconds` away, at the player's current income.
local function offlineAmountFor(player: Player, awaySeconds: number): number
	local offline = R.Offline
	local seconds = math.min(awaySeconds, offline.MaxHours * 3600)
	local perSecond = MonetizationService.GetTotalCreatureIncome(player)
	return math.max(0, math.floor(seconds * perSecond * offline.Fraction))
end

--- Works out this visit's offline cash (once) and starts "last seen".
--- Writes the profile table directly so it also works from OnBeforeRelease
--- (where Mutate is refused). Never yields.
local function computeOffline(player: Player, data: ProfileData)
	local session = sessions[player]
	if session and session.OfflineComputed then
		return
	end
	if session then
		session.OfflineComputed = true
	end
	local r = data.Retention
	local away = if session then session.AwaySeconds else 0
	if R.Offline.Enabled and away >= R.Offline.MinAwaySeconds then
		local amount = offlineAmountFor(player, away)
		if amount > 0 then
			r.PendingOffline = math.min(maxPendingOffline(), r.PendingOffline + amount)
			log("%s was away %s: +$%d offline cash pending (now $%d)", player.Name, formatClock(away), amount, r.PendingOffline)
		end
	end
	r.LastSeenAt = os.time()
	DataService.MarkChanged(player)
end

--------------------------------------------------------------------------
-- Remote handlers
--------------------------------------------------------------------------

local NOT_LOADED: RemoteGuard.Result = { Ok = false, Message = "Your save is still loading. Try again in a moment." }

local function claimDaily(player: Player): RemoteGuard.Result
	local data = DataService.Get(player)
	if not data or not sessions[player] then
		return NOT_LOADED
	end
	if not R.Daily.Enabled then
		return { Ok = false, Message = "Daily rewards are resting for now." }
	end
	if not RemoteGuard.Cooldowns.Ready(player, "ClaimDaily") then
		return { Ok = false, Message = "One moment..." }
	end
	local status = dailyStatus(data)
	if not status.CanClaim then
		return { Ok = false, Message = "Already claimed today. Next reward in " .. formatClock(status.NextClaimAt - os.time()) .. "." }
	end
	local reward = R.Daily.Rewards[status.Day]
	if not reward then
		return { Ok = false, Message = "That reward isn't set up yet." }
	end
	RemoteGuard.Cooldowns.Start(player, "ClaimDaily", R.Daily.ClaimCooldown)

	-- Mark it claimed first, in the same synchronous step as the grant (no
	-- yield between), so a double-fire can't claim twice.
	local t = today()
	DataService.Mutate(player, function(d)
		d.Retention.DailyLastDay = t
		d.Retention.DailyStreak = status.Day
	end)
	local text = grantReward(player, reward, "daily")
	log("%s claimed daily day %d: %s", player.Name, status.Day, text)
	Notifier.Send(player, string.format("Day %d reward: %s!", status.Day, text), "Success")
	requestSave(player)
	push(player)
	return { Ok = true, Day = status.Day, Text = text }
end

local function spinWheel(player: Player): RemoteGuard.Result
	local data = DataService.Get(player)
	if not data or not sessions[player] then
		return NOT_LOADED
	end
	if not R.Spin.Enabled then
		return { Ok = false, Message = "The wheel is resting for now." }
	end
	if not RemoteGuard.Cooldowns.Ready(player, "SpinWheel") then
		return { Ok = false, Message = "The wheel is still spinning!" }
	end
	if spinsAvailable(data) <= 0 then
		return { Ok = false, Message = "No spins left. Your next free spin is in "
			.. formatClock(data.Retention.SpinNextFreeAt - os.time()) .. "." }
	end
	local prizes = R.Spin.Prizes
	if #prizes == 0 then
		return { Ok = false, Message = "The wheel isn't set up yet." }
	end
	RemoteGuard.Cooldowns.Start(player, "SpinWheel", R.Spin.Cooldown)

	-- Use the free spin first, then a bought one. Spend before granting.
	local usedFree = freeSpinReady(data)
	DataService.Mutate(player, function(d)
		if usedFree then
			d.Retention.SpinNextFreeAt = os.time() + R.Spin.FreeEvery
		else
			d.Retention.SpinExtra -= 1
		end
	end)

	-- Weighted roll.
	local total = 0
	for _, prize in ipairs(prizes) do
		total += math.max(0, prize.Weight or 0)
	end
	local index = #prizes
	local roll = rng:NextNumber() * total
	for i, prize in ipairs(prizes) do
		roll -= math.max(0, prize.Weight or 0)
		if roll < 0 then
			index = i
			break
		end
	end

	local prize = prizes[index]
	local text = grantReward(player, prize, "spin")
	local shown = if prize.Label then string.format("%s (%s)", prize.Label, text) else text
	log("%s spun the wheel (%s): slot %d, %s", player.Name, usedFree and "free" or "bought", index, text)

	-- Tell them when the wheel stops, not before (it would spoil it).
	task.delay(R.Spin.SpinTime, function()
		if player.Parent then
			Notifier.Send(player, "The wheel gave you " .. shown .. "!", "Success")
		end
		if prize.Announce then
			RemoteGuard.GetClientEvent("GlobalAnnounce"):FireAllClients(
				string.format("%s hit the jackpot on the prize wheel: %s!", player.DisplayName, text), "Legendary")
		end
	end)
	requestSave(player)
	push(player)
	return { Ok = true, Index = index, Text = shown }
end

local function claimGift(player: Player, index: any): RemoteGuard.Result
	local data = DataService.Get(player)
	local session = sessions[player]
	if not data or not session then
		return NOT_LOADED
	end
	if not R.Playtime.Enabled then
		return { Ok = false, Message = "Gifts are resting for now." }
	end
	local gifts = R.Playtime.Gifts
	if typeof(index) ~= "number" or index ~= math.floor(index) or index < 1 or index > #gifts then
		return { Ok = false, Message = "That gift doesn't exist." }
	end
	if not RemoteGuard.Cooldowns.Ready(player, "ClaimPlaytimeGift") then
		return { Ok = false, Message = "One moment..." }
	end
	if session.GiftsClaimed[index] then
		return { Ok = false, Message = "You already opened that gift." }
	end
	local unlockAt = giftUnlockAt(session, index)
	if os.time() < unlockAt then
		return { Ok = false, Message = "That gift opens in " .. formatClock(unlockAt - os.time()) .. "." }
	end
	RemoteGuard.Cooldowns.Start(player, "ClaimPlaytimeGift", R.Playtime.ClaimCooldown)

	session.GiftsClaimed[index] = true
	local text = grantReward(player, gifts[index], "gift")
	log("%s opened playtime gift %d: %s", player.Name, index, text)
	Notifier.Send(player, string.format("Gift %d: %s!", index, text), "Success")
	requestSave(player)
	push(player)
	return { Ok = true, Index = index, Text = text }
end

local function claimOffline(player: Player): RemoteGuard.Result
	local data = DataService.Get(player)
	if not data or not sessions[player] then
		return NOT_LOADED
	end
	if not RemoteGuard.Cooldowns.Ready(player, "ClaimOffline") then
		return { Ok = false, Message = "One moment..." }
	end
	local amount = data.Retention.PendingOffline
	if amount <= 0 then
		return { Ok = false, Message = "There's no offline cash to claim." }
	end
	RemoteGuard.Cooldowns.Start(player, "ClaimOffline", R.Offline.ClaimCooldown)

	if not DataService.AddCash(player, amount, "offline") then
		warnf("AddCash refused offline cash %d for %s", amount, player.Name)
		return { Ok = false, Message = "Something went wrong. Try again." }
	end
	DataService.Mutate(player, function(d)
		d.Retention.PendingOffline = 0
		d.Retention.LastOfflineAmount = amount
	end)
	log("%s claimed $%d offline cash", player.Name, amount)
	Notifier.Send(player, string.format("+$%s from while you were away!", Config.FormatNumber(amount)), "Success")
	requestSave(player)
	push(player)
	return { Ok = true, Amount = amount }
end

--------------------------------------------------------------------------
-- Players
--------------------------------------------------------------------------

local function onProfileLoaded(player: Player, data: ProfileData)
	if sessions[player] then
		return
	end
	local now = os.time()
	local lastSeen = data.Retention.LastSeenAt
	sessions[player] = {
		StartedAt = now,
		GiftsClaimed = {},
		AwaySeconds = if lastSeen > 0 then math.max(0, now - lastSeen) else 0,
		OfflineComputed = false,
		PushPending = false,
		SavePending = false,
		LastSaveAt = 0,
	}
	push(player)

	-- Give the game-pass check (2x Cash) a moment before working out
	-- offline cash. Leaving before then is handled in OnBeforeRelease.
	task.delay(R.Offline.ComputeDelay, function()
		local current = DataService.Get(player)
		if current and DataService.IsLoaded(player) then
			computeOffline(player, current)
			push(player)
			requestSave(player)
		end
	end)
end

--- Sanity-checks Config.Retention once at boot (warnings, never errors).
local function validateConfig()
	local function checkReward(where: string, reward: Reward)
		if typeof(reward.Items) ~= "table" or #reward.Items == 0 then
			warnf("%s has no Items", where)
			return
		end
		for i, item in ipairs(reward.Items) do
			local at = string.format("%s item %d", where, i)
			if item.Kind == "Egg" and not Config.Eggs[item.EggId or ""] then
				warnf("%s names unknown egg '%s'", at, tostring(item.EggId))
			elseif item.Kind == "Buff" and not R.BuffNames[item.Buff or ""] then
				warnf("%s names unknown buff '%s'", at, tostring(item.Buff))
			elseif item.Kind ~= "Cash" and item.Kind ~= "Egg" and item.Kind ~= "Buff" and item.Kind ~= "InstantHatch" then
				warnf("%s has unknown Kind '%s'", at, tostring(item.Kind))
			end
		end
	end
	if #R.Daily.Rewards ~= 7 then
		warnf("Daily.Rewards has %d entries; the screen has 7 cards", #R.Daily.Rewards)
	end
	for i, reward in ipairs(R.Daily.Rewards) do
		checkReward("Daily day " .. i, reward)
	end
	for i, prize in ipairs(R.Spin.Prizes) do
		checkReward("Spin prize " .. i, prize)
		if (prize.Weight or 0) <= 0 then
			warnf("Spin prize %d has no Weight, so it can never be won", i)
		end
	end
	for i, gift in ipairs(R.Playtime.Gifts) do
		checkReward("Playtime gift " .. i, gift)
		if typeof(gift.Minutes) ~= "number" then
			warnf("Playtime gift %d has no Minutes", i)
		end
	end
	for name, icon in pairs(R.Icons) do
		if not Config.Icons[icon] then
			warnf("Retention.Icons.%s uses unknown icon '%s'", name, icon)
		end
	end
end

--------------------------------------------------------------------------
-- Studio debug helpers (DebugCommands)
--------------------------------------------------------------------------

function RetentionService.DebugState(player: Player): string
	local data = DataService.Get(player)
	local session = sessions[player]
	if not data or not session then
		return "not loaded"
	end
	local state = buildState(player)
	-- GiftsClaimed is a sparse table ({ [3] = true }); JSONEncode wants a
	-- plain list, so send the opened gift numbers instead.
	local opened = {}
	for index in pairs(session.GiftsClaimed) do
		table.insert(opened, index)
	end
	table.sort(opened)
	return HttpService:JSONEncode({
		Saved = data.Retention,
		Today = today(),
		SessionMinutes = math.floor((os.time() - session.StartedAt) / 6) / 10,
		GiftsClaimed = opened,
		OfflineComputed = session.OfflineComputed,
		AwaySeconds = session.AwaySeconds,
		State = state,
	})
end

--- Pretends the last daily claim was `daysAgo` days ago (1 = streak goes
--- on, 2+ = streak resets). Keeps the streak count.
function RetentionService.DebugDailyShift(player: Player, daysAgo: number): string
	local ok = DataService.Mutate(player, function(d)
		if d.Retention.DailyStreak == 0 then
			d.Retention.DailyStreak = 1
		end
		d.Retention.DailyLastDay = today() - daysAgo
	end)
	push(player)
	local data = DataService.Get(player)
	if not ok or not data then
		return "not loaded"
	end
	local status = dailyStatus(data)
	return string.format("last claim set to %d day(s) ago; next claim is day %d (canClaim=%s)",
		daysAgo, status.Day, tostring(status.CanClaim))
end

function RetentionService.DebugSpinReady(player: Player): string
	local ok = DataService.Mutate(player, function(d)
		d.Retention.SpinNextFreeAt = 0
	end)
	RemoteGuard.Cooldowns.Start(player, "SpinWheel", 0)
	push(player)
	return if ok then "free spin ready" else "not loaded"
end

--- Moves this visit's playtime clock forward by `minutes`.
function RetentionService.DebugGiftTime(player: Player, minutes: number): string
	local session = sessions[player]
	if not session then
		return "not loaded"
	end
	session.StartedAt -= math.floor(minutes * 60)
	push(player)
	return string.format("session is now %.1f minutes old", (os.time() - session.StartedAt) / 60)
end

--- Adds the offline cash they'd get for being away `seconds` (ignores
--- MinAwaySeconds) and shows the popup.
function RetentionService.DebugOffline(player: Player, seconds: number): string
	local data = DataService.Get(player)
	local session = sessions[player]
	if not data or not session then
		return "not loaded"
	end
	local amount = offlineAmountFor(player, seconds)
	DataService.Mutate(player, function(d)
		d.Retention.PendingOffline = math.min(maxPendingOffline(), d.Retention.PendingOffline + amount)
	end)
	session.AwaySeconds = seconds
	push(player)
	return string.format("+$%d pending for %s away (income $%.1f/s); pending now $%d",
		amount, formatClock(seconds), MonetizationService.GetTotalCreatureIncome(player), data.Retention.PendingOffline)
end

--------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------

function RetentionService.Start()
	validateConfig()
	stateRemote = RemoteGuard.GetClientEvent("RetentionState")

	RemoteGuard.BindFunction("ClaimDaily", claimDaily)
	RemoteGuard.BindFunction("SpinWheel", spinWheel)
	RemoteGuard.BindFunction("ClaimPlaytimeGift", claimGift)
	RemoteGuard.BindFunction("ClaimOffline", claimOffline)

	DataService.ProfileLoaded:Connect(onProfileLoaded)
	for _, player in ipairs(Players:GetPlayers()) do
		local data = DataService.Get(player)
		if data and DataService.IsLoaded(player) then
			task.spawn(onProfileLoaded, player, data)
		end
	end

	-- Last chance before the final save: work out offline cash if they left
	-- within ComputeDelay, and record when they were last here.
	DataService.OnBeforeRelease(function(player: Player, data: ProfileData)
		computeOffline(player, data)
		data.Retention.LastSeenAt = os.time()
	end)

	Players.PlayerRemoving:Connect(function(player)
		-- After DataService's release hooks have run (they're synchronous
		-- and run first thing on leave), forget the visit.
		task.delay(1, function()
			sessions[player] = nil
		end)
	end)

	-- Screens refresh when products are bought or income changes.
	MonetizationService.ProductGranted:Connect(function(player: Player, _key: string)
		push(player)
	end)
	NestService.Hatched:Connect(function(player: Player)
		push(player)
	end)

	-- Heartbeat: "last seen" (for offline cash after a crash) and a regular
	-- state refresh (income-scaled amounts, free spin becoming ready).
	task.spawn(function()
		local interval = math.min(R.StatePushInterval, R.Offline.HeartbeatInterval)
		local lastSeenWrite, lastPush = os.clock(), os.clock()
		while true do
			task.wait(interval)
			local now = os.clock()
			local writeSeen = now - lastSeenWrite >= R.Offline.HeartbeatInterval - 0.5
			local doPush = now - lastPush >= R.StatePushInterval - 0.5
			if writeSeen then
				lastSeenWrite = now
			end
			if doPush then
				lastPush = now
			end
			for player, session in pairs(sessions) do
				local ok, err = pcall(function()
					-- Only once offline cash is worked out: before that, the
					-- old "last seen" is what tells us how long they were away.
					if writeSeen and session.OfflineComputed and DataService.IsLoaded(player) then
						DataService.Mutate(player, function(d)
							d.Retention.LastSeenAt = os.time()
						end)
					end
					if doPush then
						push(player)
					end
				end)
				if not ok then
					warnf("heartbeat errored for %s: %s", player.Name, tostring(err))
				end
			end
		end
	end)

	log("Ready — daily %s, spin %s, gifts %s, offline %s",
		tostring(R.Daily.Enabled), tostring(R.Spin.Enabled), tostring(R.Playtime.Enabled), tostring(R.Offline.Enabled))
end

return RetentionService
