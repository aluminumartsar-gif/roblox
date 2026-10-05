--!strict
--[[
	PlotService
	ServerScriptService/Server/Services/PlotService

	Owns who has which plot, and everything about the plot as a place:

	  * Claim on profile load, release on leave. No free plot -> the player
	    is turned away with a message (set Server Size = Config.Plot.Count).
	  * Spawning. Players.CharacterAutoLoads is off (see Bootstrap); this
	    service loads each character once their plot is ready and spawns it
	    at home, and respawns it there after death.
	  * Lock. Lasts the LockDuration upgrade value; cooldown from activation.
	    Triggered by the plot's lock button prompt or the LockPlot remote.
	  * Enforcement, on a timer (Config.Plot.EnforceInterval):
	      - non-owners standing inside a locked plot are moved outside the
	        door. This — not the door part — is what makes a lock real; a
	        client that deletes its door still gets ejected.
	      - the owner gets the walk speed bonus while on their own plot.

	Time values on attributes use workspace:GetServerTimeNow(), which
	clients share, so client countdowns line up with the server.

	Replicated state:
	  Plot model attrs:  PlotIndex, OwnerUserId, OwnerName, LockedUntil, LockCooldownUntil
	  Player attrs:      PlotIndex, PlotLockedUntil, PlotLockCooldownUntil
	  (Player attrs exist because with streaming, a plot far away may not be
	  on the client; the HUD panel must still work.)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Signal = require(Shared:WaitForChild("Util"):WaitForChild("Signal"))

local Server = ServerScriptService:WaitForChild("Server")
local Modules = Server:WaitForChild("Modules")
local Services = Server:WaitForChild("Services")
local MapBuilder = require(Modules:WaitForChild("MapBuilder"))
local RemoteGuard = require(Modules:WaitForChild("RemoteGuard"))
local Notifier = require(Modules:WaitForChild("Notifier"))
local DataService = require(Services:WaitForChild("DataService"))
local WorldService = require(Services:WaitForChild("WorldService"))
local MovementService = require(Services:WaitForChild("MovementService"))
local BoostService = require(Services:WaitForChild("BoostService"))

export type PlotRecord = {
	Index: number,
	Model: Model,
	CFrame: CFrame,
	Owner: Player?,
	LockedUntil: number,
	LockCooldownUntil: number,
	ProtectedUntil: number,   -- spawn protection: no stealing from this plot
	SpawnCFrame: CFrame,
	EjectCFrame: CFrame,
	Nests: { Model },
}

local PlotService = {}

--- Fired as (player, plot) after a plot is claimed.
PlotService.PlotClaimed = Signal.new()
--- Fired as (player, plot) after a plot is released.
PlotService.PlotReleased = Signal.new()

local plots: { PlotRecord } = {}
local plotByPlayer: { [Player]: PlotRecord } = {}
-- Extra conditions that can block a lock, e.g. "carrying a stolen item"
-- (Step 4). Each returns (allowed, reasonIfNot).
local lockChecks: { (Player) -> (boolean, string?) } = {}
-- Throttle for "this camp is locked" messages.
local lastEjectNotice: { [Player]: number } = {}

-- Defined further down (state -> attributes); declared here so functions
-- above its definition can call it.
local publish: (PlotRecord) -> ()

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function log(fmt: string, ...: any)
	if Config.Debug.Verbose then
		print(string.format("[SAC/Plot] " .. fmt, ...))
	end
end

local function formatClock(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

--------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------

function PlotService.GetPlot(player: Player): PlotRecord?
	return plotByPlayer[player]
end

function PlotService.GetPlotByIndex(index: number): PlotRecord?
	return plots[index]
end

function PlotService.GetPlots(): { PlotRecord }
	return plots
end

function PlotService.IsLocked(plot: PlotRecord): boolean
	return plot.LockedUntil > now()
end

--- True while the owner's spawn protection is running.
function PlotService.IsProtected(plot: PlotRecord): boolean
	return plot.ProtectedUntil > now()
end

function PlotService.ProtectionRemaining(plot: PlotRecord): number
	return math.max(0, plot.ProtectedUntil - now())
end

--- Ends a player's spawn protection early (they started stealing).
function PlotService.EndProtection(player: Player)
	local plot = plotByPlayer[player]
	if plot and plot.ProtectedUntil > now() then
		plot.ProtectedUntil = 0
		publish(plot)
	end
end

--- True if `position` is inside the plot's walls.
function PlotService.IsInside(plot: PlotRecord, position: Vector3): boolean
	local p = Config.Plot
	local localPos = plot.CFrame:PointToObjectSpace(position)
	return math.abs(localPos.X) <= p.Size.X / 2
		and math.abs(localPos.Z) <= p.Size.Z / 2
		and localPos.Y >= -2
		and localPos.Y <= p.WallHeight + 12
end

--- The plot containing `position`, if any.
function PlotService.GetPlotAt(position: Vector3): PlotRecord?
	for _, plot in ipairs(plots) do
		if PlotService.IsInside(plot, position) then
			return plot
		end
	end
	return nil
end

--- Registers an extra condition that can block locking (see lockChecks).
function PlotService.AddLockCheck(check: (Player) -> (boolean, string?))
	table.insert(lockChecks, check)
end

--------------------------------------------------------------------------
-- State -> replicated attributes and visuals
--------------------------------------------------------------------------

function publish(plot: PlotRecord)
	local m = plot.Model
	local owner = plot.Owner
	m:SetAttribute("OwnerUserId", if owner then owner.UserId else 0)
	m:SetAttribute("OwnerName", if owner then owner.DisplayName else "")
	m:SetAttribute("LockedUntil", plot.LockedUntil)
	m:SetAttribute("LockCooldownUntil", plot.LockCooldownUntil)
	m:SetAttribute("ProtectedUntil", plot.ProtectedUntil)
	if owner then
		owner:SetAttribute("PlotIndex", plot.Index)
		owner:SetAttribute("PlotLockedUntil", plot.LockedUntil)
		owner:SetAttribute("PlotLockCooldownUntil", plot.LockCooldownUntil)
		owner:SetAttribute("ProtectedUntil", plot.ProtectedUntil)
	end
end

--- Lights up as many nests as the owner can use; dims the rest.
function PlotService.RefreshNests(player: Player)
	local plot = plotByPlayer[player]
	local data = DataService.Get(player)
	if not plot or not data then
		return
	end
	local activeCount = BoostService.GetNestCapacity(player)
	player:SetAttribute("NestCapacity", activeCount)
	local glowColors = Config.Rebirth.NestGlowColors
	local glow = glowColors[(data.Rebirths % #glowColors) + 1]
	for i, nest in ipairs(plot.Nests) do
		MapBuilder.SetNestActive(nest, i <= activeCount, glow)
	end
end

local function resetNests(plot: PlotRecord)
	for _, nest in ipairs(plot.Nests) do
		MapBuilder.SetNestActive(nest, false, Config.Rebirth.NestGlowColors[1])
	end
end

--------------------------------------------------------------------------
-- Spawning
--------------------------------------------------------------------------

local function moveCharacterHome(player: Player)
	local plot = plotByPlayer[player]
	local character = player.Character
	if not plot or not character then
		return
	end
	local root = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if root and character.Parent then
		character:PivotTo(plot.SpawnCFrame * CFrame.new(0, 3, 0))
	end
end

local function loadCharacterAtHome(player: Player)
	local plot = plotByPlayer[player]
	if not plot or player.Parent ~= Players then
		return
	end
	-- Ask the client to stream the plot in first, so the character doesn't
	-- appear above an empty void and fall.
	pcall(function()
		player:RequestStreamAroundAsync(plot.SpawnCFrame.Position, 5)
	end)
	if player.Parent == Players and plotByPlayer[player] == plot then
		player:LoadCharacter()
	end
end

local function onCharacterAdded(player: Player, character: Model)
	task.defer(moveCharacterHome, player)

	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if humanoid then
		humanoid.Died:Connect(function()
			task.delay(Players.RespawnTime, function()
				-- Only respawn if this is still their current (dead) character.
				if player.Character == character then
					loadCharacterAtHome(player)
				end
			end)
		end)
	end
end

--------------------------------------------------------------------------
-- Claim / release
--------------------------------------------------------------------------

local function claim(player: Player)
	if plotByPlayer[player] or player.Parent ~= Players then
		return
	end

	local free: PlotRecord? = nil
	for _, plot in ipairs(plots) do
		if plot.Owner == nil then
			free = plot
			break
		end
	end

	if not free then
		warn(string.format("[SAC/Plot] No free plot for %s (%d plots, %d players)",
			player.Name, #plots, #Players:GetPlayers()))
		player:Kick("Every campsite on this server is taken. Please try another server.")
		return
	end

	local plot = free :: PlotRecord
	plot.Owner = player
	plot.LockedUntil = 0
	plot.LockCooldownUntil = 0
	-- Spawn protection: longer on a player's very first join.
	local data = DataService.Get(player)
	local firstJoin = data ~= nil and (data.Stats.JoinCount or 0) <= 1
	plot.ProtectedUntil = now() + (if firstJoin
		then Config.Steal.NewPlayerSpawnLock
		else Config.Steal.ReturningPlayerSpawnLock)
	plotByPlayer[player] = plot

	MapBuilder.SetPlotSign(plot.Model, player.DisplayName)
	publish(plot)
	PlotService.RefreshNests(player)
	log("%s claimed plot %d", player.Name, plot.Index)

	PlotService.PlotClaimed:Fire(player, plot)

	-- Spawn at home. If a character already exists (e.g. it loaded before
	-- CharacterAutoLoads was turned off), move it instead.
	if player.Character then
		task.spawn(moveCharacterHome, player)
	else
		task.spawn(loadCharacterAtHome, player)
	end
end

local function release(player: Player)
	local plot = plotByPlayer[player]
	if not plot then
		return
	end
	plotByPlayer[player] = nil
	plot.Owner = nil
	plot.LockedUntil = 0
	plot.LockCooldownUntil = 0
	plot.ProtectedUntil = 0

	MapBuilder.SetPlotSign(plot.Model, nil)
	resetNests(plot)
	publish(plot)
	log("%s released plot %d", player.Name, plot.Index)

	PlotService.PlotReleased:Fire(player, plot)
end

--------------------------------------------------------------------------
-- Lock
--------------------------------------------------------------------------

export type Result = RemoteGuard.Result

function PlotService.TryLock(player: Player): Result
	local plot = plotByPlayer[player]
	if not plot then
		return { Ok = false, Message = "You don't have a camp yet." }
	end

	local t = now()
	if plot.LockedUntil > t then
		return { Ok = false, Message = "Already locked (" .. formatClock(plot.LockedUntil - t) .. " left)." }
	end
	if plot.LockCooldownUntil > t then
		return { Ok = false, Message = "Lock recharging: " .. formatClock(plot.LockCooldownUntil - t) }
	end

	if Config.Plot.LockRequiresPresence then
		local root = RemoteGuard.GetRoot(player)
		if not root or not PlotService.IsInside(plot, root.Position) then
			return { Ok = false, Message = "Stand in your camp to lock it." }
		end
	end

	for _, check in ipairs(lockChecks) do
		local allowed, reason = check(player)
		if not allowed then
			return { Ok = false, Message = reason or "You can't lock right now." }
		end
	end

	local data = DataService.Get(player)
	local duration = Config.GetUpgradeValue("LockDuration", if data then data.Upgrades.LockDuration else 1)

	plot.LockedUntil = t + duration
	plot.LockCooldownUntil = t + Config.Plot.LockCooldown
	publish(plot)
	log("%s locked plot %d for %ds", player.Name, plot.Index, duration)

	-- Clear anyone already inside right away, not on the next tick.
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			local root = RemoteGuard.GetRoot(other)
			if root and PlotService.IsInside(plot, root.Position) then
				(other.Character :: Model):PivotTo(plot.EjectCFrame)
				Notifier.Send(other, "That camp just locked. You were moved outside.", "Warning")
			end
		end
	end

	return {
		Ok = true,
		Message = "Camp locked for " .. duration .. "s.",
		LockedUntil = plot.LockedUntil,
		LockCooldownUntil = plot.LockCooldownUntil,
	}
end

--------------------------------------------------------------------------
-- Enforcement loop
--------------------------------------------------------------------------

local function enforce()
	local bonus = 1 + Config.Plot.OwnerWalkSpeedBonus
	for _, player in ipairs(Players:GetPlayers()) do
		local root = RemoteGuard.GetRoot(player)
		if root then
			local inside = PlotService.GetPlotAt(root.Position)

			-- Home speed bonus
			MovementService.SetModifier(player, "OwnPlot",
				if inside and inside.Owner == player then bonus else nil)

			-- Locked plots belong to their owner only
			if inside and inside.Owner ~= nil and inside.Owner ~= player and PlotService.IsLocked(inside) then
				(player.Character :: Model):PivotTo(inside.EjectCFrame)
				local t = os.clock()
				if (lastEjectNotice[player] or 0) + 3 < t then
					lastEjectNotice[player] = t
					Notifier.Send(player, "That camp is locked.", "Warning")
				end
			end
		end
	end
end

--------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------

function PlotService.Start()
	local p = Config.Plot

	for index, model in ipairs(WorldService.GetPlots()) do
		local cf = MapBuilder.GetPlotCFrame(index)
		local spawnPart = model:FindFirstChild("Spawn") :: BasePart
		local nestsFolder = model:FindFirstChild("Nests")
		local nests: { Model } = {}
		for k = 1, p.MaxNests do
			nests[k] = (nestsFolder :: Instance):FindFirstChild("Nest_" .. k) :: Model
		end

		local record: PlotRecord = {
			Index = index,
			Model = model,
			CFrame = cf,
			Owner = nil,
			LockedUntil = 0,
			LockCooldownUntil = 0,
			ProtectedUntil = 0,
			SpawnCFrame = spawnPart.CFrame,
			-- Outside the door, facing the hub.
			EjectCFrame = cf * CFrame.new(0, 3, -p.Size.Z / 2 - 8),
			Nests = nests,
		}
		plots[index] = record

		-- Physical lock button. Prompts can be fired from anywhere by
		-- exploit tools, so check owner and distance here too.
		local button = model:FindFirstChild("LockButton") :: BasePart
		local prompt = button:FindFirstChild("LockPrompt") :: ProximityPrompt
		prompt.Triggered:Connect(function(player: Player)
			if record.Owner ~= player then
				Notifier.Send(player, "This isn't your camp.", "Error")
				return
			end
			if not RemoteGuard.IsWithinReach(player, button.Position) then
				return
			end
			local result = PlotService.TryLock(player)
			Notifier.Send(player, result.Message or "", if result.Ok then "Success" else "Error")
		end)
	end

	RemoteGuard.BindFunction("LockPlot", function(player: Player): Result
		return PlotService.TryLock(player)
	end)

	DataService.ProfileLoaded:Connect(function(player: Player)
		claim(player)
	end)

	local function hookPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			onCharacterAdded(player, character)
		end)
	end
	Players.PlayerAdded:Connect(hookPlayer)
	for _, player in ipairs(Players:GetPlayers()) do
		hookPlayer(player)
		if player.Character then
			task.spawn(onCharacterAdded, player, player.Character)
		end
		-- Profiles that finished loading before this service started.
		if DataService.IsLoaded(player) then
			task.spawn(claim, player)
		end
	end

	Players.PlayerRemoving:Connect(function(player)
		release(player)
		lastEjectNotice[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(p.EnforceInterval)
			local ok, err = pcall(enforce)
			if not ok then
				warn("[SAC/Plot] enforce errored: " .. tostring(err))
			end
		end
	end)
end

return PlotService
