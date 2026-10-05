--!strict
--[[
	IncomeService
	ServerScriptService/Server/Services/IncomeService

	Creatures earn cash into their own vault; the owner collects by touching
	the creature.

	  * Every Config.Income.TickInterval, each creature slot gains
	    BoostService.GetCreatureIncome(owner, slot) * dt, capped at the owner's
	    vault cap (VaultSize upgrade, per creature). A full vault stops
	    filling — uncollected cash past the cap is lost, which is what keeps
	    owners moving around their base.
	  * Collect: touching the creature's body. Owner only, with a distance
	    check (touches can be faked remotely by exploit tools) and a short
	    per-nest cooldown. The amount paid is the server's own vault value,
	    so it can never exceed what the creature actually earned.
	  * Auto Collect pass (Step 6): collects every AutoCollectInterval.
	  * Every collect fires CashCollected (amount, position) to the owner;
	    the "+$X" popup and coin sound are FeedbackController's (Step 8).

	Vault values are written straight into the profile each tick without a
	client push; the creature model's Vault attribute carries the display.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Server = ServerScriptService:WaitForChild("Server")
local Services = Server:WaitForChild("Services")
local Modules = Server:WaitForChild("Modules")
local RemoteGuard = require(Modules:WaitForChild("RemoteGuard"))
local DataService = require(Services:WaitForChild("DataService"))
local BoostService = require(Services:WaitForChild("BoostService"))
local PlotService = require(Services:WaitForChild("PlotService"))
local NestService = require(Services:WaitForChild("NestService"))

type PlotRecord = PlotService.PlotRecord

local IncomeService = {}

-- How far (beyond the creature's own size) a touch may come from.
local COLLECT_REACH = 8

-- player -> nestIndex -> os.clock() of last collect
local lastCollect: { [Player]: { [number]: number } } = {}

--- Tells the collector's client to show "+$X" at the creature (the popup,
--- coin sound and HUD bounce are FeedbackController's job).
local function popup(player: Player, model: Model, amount: number)
	if player.Parent ~= Players then
		return
	end
	local cf, size = model:GetBoundingBox()
	local top = cf.Position + Vector3.new(0, size.Y / 2, 0)
	RemoteGuard.GetClientEvent("CashCollected"):FireClient(player, amount, top)
end

--- Pays out one creature's vault to its owner. Returns the amount paid.
function IncomeService.Collect(player: Player, nestIndex: number): number
	local slot = NestService.GetSlot(player, nestIndex)
	if not slot or slot.Kind ~= "Creature" or slot.Away then
		return 0
	end
	local amount = math.floor(slot.Vault)
	if amount < 1 then
		return 0
	end
	slot.Vault -= amount
	if not DataService.AddCash(player, amount, "collect") then
		slot.Vault += amount -- refused (shouldn't happen); give it back
		return 0
	end

	local plot = PlotService.GetPlot(player)
	local model = plot and NestService.GetVisual(plot.Index, nestIndex)
	if model then
		model:SetAttribute("Vault", math.floor(slot.Vault))
		popup(player, model, amount)
	end
	return amount
end

local function onTouched(plot: PlotRecord, nestIndex: number, model: Model, hit: BasePart)
	local character = hit:FindFirstAncestorOfClass("Model")
	local player = character and Players:GetPlayerFromCharacter(character)
	if not player or player ~= plot.Owner then
		return
	end

	local now = os.clock()
	local byNest = lastCollect[player]
	if not byNest then
		byNest = {}
		lastCollect[player] = byNest
	end
	if (byNest[nestIndex] or 0) + Config.Income.CollectTouchCooldown > now then
		return
	end

	local body = model.PrimaryPart
	if not body then
		return
	end
	local reach = body.Size.Magnitude / 2 + COLLECT_REACH
	if not RemoteGuard.IsWithinReach(player, body.Position, reach) then
		return
	end

	byNest[nestIndex] = now
	IncomeService.Collect(player, nestIndex)
end

local function tickIncome(dt: number)
	for _, plot in ipairs(PlotService.GetPlots()) do
		local owner = plot.Owner
		local data = owner and DataService.Get(owner)
		if owner and data then
			for nestIndex, slot in ipairs(data.Nests) do
				if slot ~= false and slot.Kind == "Creature" and not slot.Away then
					local cap = BoostService.GetVaultCap(owner, slot)
					local income = BoostService.GetCreatureIncome(owner, slot)
					slot.Vault = math.min(cap, slot.Vault + income * dt)
					local model = NestService.GetVisual(plot.Index, nestIndex)
					if model then
						local shown = math.floor(slot.Vault)
						if model:GetAttribute("Vault") ~= shown then
							model:SetAttribute("Vault", shown)
						end
						if model:GetAttribute("VaultCap") ~= cap then
							model:SetAttribute("VaultCap", cap)
						end
						if model:GetAttribute("IncomePerSecond") ~= income then
							model:SetAttribute("IncomePerSecond", income)
						end
					end
				end
			end
		end
	end
end

local function autoCollect()
	for _, plot in ipairs(PlotService.GetPlots()) do
		local owner = plot.Owner
		if owner and BoostService.HasPass(owner, "AutoCollect") then
			for nestIndex = 1, Config.Plot.MaxNests do
				IncomeService.Collect(owner, nestIndex)
			end
		end
	end
end

function IncomeService.Start()
	NestService.ItemRendered:Connect(function(_owner: Player, plot: PlotRecord, nestIndex: number, model: Model, slot: any)
		if slot.Kind ~= "Creature" then
			return
		end
		local body = model.PrimaryPart :: BasePart
		body.CanTouch = true
		body.Touched:Connect(function(hit)
			onTouched(plot, nestIndex, model, hit)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastCollect[player] = nil
	end)

	task.spawn(function()
		local last = os.clock()
		local sinceAuto = 0
		while true do
			task.wait(Config.Income.TickInterval)
			local now = os.clock()
			local dt = now - last
			last = now
			local ok, err = pcall(tickIncome, dt)
			if not ok then
				warn("[SAC/Income] tick errored: " .. tostring(err))
			end
			sinceAuto += dt
			if sinceAuto >= Config.Income.AutoCollectInterval then
				sinceAuto = 0
				pcall(autoCollect)
			end
		end
	end)
end

return IncomeService
