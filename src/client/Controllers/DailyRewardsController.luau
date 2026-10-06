--!strict
--[[
	DailyRewardsController
	StarterPlayerScripts/Client/Controllers/DailyRewardsController

	The Daily Rewards window ("campfire field kit" Window "DailyRewards"),
	opened from the HUD's Daily tile:

	  header      "Day n of 7": where you are in the streak.
	  7 cards     Day 1..7: the reward (icon + short text). Days already
	              claimed this week are dimmed with a tick; today's card (the
	              one you can claim now) is lit ember, says "TODAY" and gently
	              pulses; day 7 is the big wide card. Tapping today's card
	              claims it; tapping a later day says when it comes.
	  status line what today's reward is in full, or a countdown to
	              tomorrow's.
	  CLAIM       claims today's reward (greyed out once it's claimed).

	The HUD tile shows a red "!" while there's something to claim, and the
	window pops up once on joining when there is: after the Offline Earnings
	popup, never on top of it or any other window, and never over the
	first-join tutorial (the TutorialActive player attribute).

	ALSO the shared client side of retention (it starts first of the four
	retention controllers, which all require it):
	  GetState / StateChanged   latest RetentionState push from the server
	  ServerNow()               the server's clock, for countdowns
	  FormatClock, Play, Invoke, PriceText, OtherPopupOpen, Open — small helpers

	Display only: RetentionService decides everything. The client sends
	"claim", nothing else.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Signal = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Util"):WaitForChild("Signal"))

local Components = script.Parent.Parent:WaitForChild("Components")
local Theme = require(Components:WaitForChild("Theme"))
local UI = require(Components:WaitForChild("UI"))
local Icon = require(Components:WaitForChild("Icon"))
local Window = require(Components:WaitForChild("Window"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))
local HudController = require(script.Parent:WaitForChild("HudController"))

local DailyRewardsController = {}

--- Fired as (state) whenever the server sends new retention state.
DailyRewardsController.StateChanged = Signal.new()

local C = Theme.Colors
local TUNING = Config.UI.Retention.Daily

local state: { [string]: any }? = nil
local serverOffset = 0 -- server os.time() minus our GetServerTimeNow()
local soundController: any = nil
local prices: { [string]: number } = {}
local priceRequested: { [string]: boolean } = {}
local priceWarned: { [string]: boolean } = {} -- log a failed price lookup once, not every retry

--------------------------------------------------------------------------
-- Shared helpers (used by all four retention controllers)
--------------------------------------------------------------------------

function DailyRewardsController.GetState(): { [string]: any }?
	return state
end

--- The server's os.time() right now (fractional).
function DailyRewardsController.ServerNow(): number
	return Workspace:GetServerTimeNow() + serverOffset
end

--- 75 -> "1:15", 3725 -> "1:02:05".
function DailyRewardsController.FormatClock(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	local hours = seconds // 3600
	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, (seconds % 3600) // 60, seconds % 60)
	end
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

--- Plays a Config.Sounds sound through SoundController (if it exists).
function DailyRewardsController.Play(name: string)
	if soundController == nil then
		local module = script.Parent:FindFirstChild("SoundController")
		local ok, loaded = false, nil
		if module then
			ok, loaded = pcall(require, module)
		end
		soundController = if ok and typeof(loaded) == "table" then loaded else false
	end
	if soundController and typeof(soundController.Play) == "function" then
		pcall(soundController.Play, name)
	end
end

--- Calls a retention RemoteFunction. Shows the server's message (and an
--- error sound) when it says no. Returns the result, or nil if the server
--- couldn't be reached.
function DailyRewardsController.Invoke(remoteName: string, ...: any): { [string]: any }?
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild(remoteName) :: RemoteFunction
	local args = table.pack(...)
	local ok, result = pcall(function()
		return remote:InvokeServer(table.unpack(args, 1, args.n))
	end)
	if not ok or typeof(result) ~= "table" then
		NotificationController.Show("Couldn't reach the server. Try again.", "Error")
		DailyRewardsController.Play("Error")
		return nil
	end
	if not result.Ok then
		NotificationController.Show(tostring(result.Message or "That didn't work."), "Error")
		DailyRewardsController.Play("Error")
	end
	return result
end

--- Price text for a developer product: "R$49", "SOON" (no id yet) or "...".
function DailyRewardsController.PriceText(productKey: string): string
	local product = Config.DevProducts[productKey]
	if not product or product.Id == 0 then
		return "SOON"
	end
	if prices[productKey] then
		return "R$" .. prices[productKey]
	end
	if not priceRequested[productKey] then
		priceRequested[productKey] = true
		task.spawn(function()
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(product.Id, Enum.InfoType.Product)
			end)
			if ok and typeof(info) == "table" and info.PriceInRobux then
				prices[productKey] = info.PriceInRobux
			else
				if not priceWarned[productKey] then
					priceWarned[productKey] = true
					warn(string.format("[SAC/Daily] GetProductInfo failed for %s (%d): %s",
						productKey, product.Id, tostring(info)))
				end
				priceRequested[productKey] = nil -- try again later
			end
		end)
	end
	return "..."
end

--- True if a window other than `except` is open right now. `except` is the
--- caller's own Window (its ScreenGui works too).
function DailyRewardsController.OtherPopupOpen(except: any?): boolean
	local skip = except
	if typeof(except) == "Instance" and except:IsA("ScreenGui") then
		skip = Window.Get(except.Name)
	end
	return Window.AnyOpen(skip)
end

--------------------------------------------------------------------------
-- The screen
--------------------------------------------------------------------------

type Card = {
	card: Frame,
	accent: Frame?,
	edge: UIStroke?,
	dayLabel: TextLabel,
	icon: ImageLabel,
	rewardLabel: TextLabel,
	check: ImageLabel,
	pulse: Tween,
	scale: UIScale,
}

local window: Window.Window? = nil
local cards: { Card } = {}
local statusLabel: TextLabel? = nil
local claimButton: TextButton? = nil
local busy = false

local function daily(): { [string]: any }?
	local s = state
	return s and s.Daily
end

local function iconName(name: any): string
	return if typeof(name) == "string" and Config.Icons[name] then name else "GiftBox"
end

--- CLAIM button and the header's streak line.
local function renderButton()
	local d = daily()
	local w = window
	if w then
		local day = d and tonumber(d.Day) or 0
		w:SetInfo(if d and d.Enabled and day >= 1 then string.format("Day %d of %d", day, #cards) else "")
	end
	local button = claimButton
	if not button then
		return
	end
	local claimable = d ~= nil and d.Enabled == true and d.CanClaim == true
	if busy then
		UI.SetButtonText(button, "...")
	elseif d and d.Enabled and not d.CanClaim then
		UI.SetButtonText(button, "Claimed")
	else
		UI.SetButtonText(button, "Claim")
	end
	UI.SetButtonEnabled(button, claimable and not busy)
end

local function claim()
	local d = daily()
	if busy or not d or not d.CanClaim then
		return
	end
	busy = true
	renderButton()
	local result = DailyRewardsController.Invoke("ClaimDaily")
	busy = false
	renderButton()
	if result and result.Ok then
		DailyRewardsController.Play("DailyClaim")
	end
end

local function render()
	local d = daily()
	if not d then
		return
	end
	local rewards = d.Rewards or {}
	for i, card in ipairs(cards) do
		local reward = rewards[i]
		local slot = card.card.Parent
		if slot and slot:IsA("GuiObject") then
			slot.Visible = reward ~= nil
		end
		if not reward then
			continue
		end
		local claimed = i <= (tonumber(d.ClaimedCount) or 0)
		local isToday = d.CanClaim == true and i == d.Day
		local isBig = i == #cards
		card.rewardLabel.Text = tostring((if isBig then reward.Text else reward.Short) or reward.Short or "")
		card.dayLabel.Text = if isToday then "TODAY" else ("DAY " .. i)
		Icon.set(card.icon, iconName(reward.Icon))
		card.icon.ImageTransparency = if claimed then 0.55 else 0
		card.check.Visible = claimed
		card.dayLabel.TextColor3 = if isToday then C.EmberBright elseif claimed then C.TextFaint else C.TextDim
		card.rewardLabel.TextColor3 = if claimed then C.TextFaint else C.Text
		if card.accent then
			card.accent.BackgroundColor3 = if isToday then C.Ember elseif claimed then C.Moss else C.Edge
		end
		if card.edge then
			card.edge.Color = if isToday then C.Ember else C.Edge
			card.edge.Thickness = if isToday then 2 else 1
		end
		if isToday then
			card.pulse:Play()
		else
			card.pulse:Cancel()
			card.scale.Scale = 1
		end
	end
	renderButton()
end

--- The bottom line (ticks every second for the countdown).
local function renderStatus()
	local d = daily()
	local label = statusLabel
	if not label then
		return
	end
	if not d then
		label.Text = "Loading..."
	elseif not d.Enabled then
		label.Text = "Daily rewards are resting for now."
	elseif d.CanClaim then
		local reward = (d.Rewards or {})[d.Day]
		label.Text = string.format("Today's reward: %s", tostring(reward and reward.Detail or ""))
	else
		local remaining = (tonumber(d.NextClaimAt) or 0) - DailyRewardsController.ServerNow()
		label.Text = "Come back tomorrow! Next reward in " .. DailyRewardsController.FormatClock(remaining)
	end
end

local function buildCard(parent: Instance, day: number, length: number): Card
	local big = day == length
	local slot = UI.new("Frame", {
		Name = "Day" .. day,
		BackgroundTransparency = 1,
		LayoutOrder = day,
		Size = UDim2.fromOffset(if big then TUNING.BigCardWidth else TUNING.CardWidth, TUNING.CardHeight),
		Parent = parent,
	})
	-- The card sits centred in its slot so the pulse grows from the middle.
	local card = UI.Card({
		Name = "Card",
		Accent = C.Edge,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		Parent = slot,
	})
	local scale = UI.new("UIScale", { Name = "Pulse", Parent = card }) :: UIScale

	local dayLabel = UI.Text({
		Name = "Day",
		Role = "Heading",
		Weight = "Bold",
		Text = "DAY " .. day,
		TextSize = 16,
		TextColor3 = C.TextDim,
		Position = UDim2.fromOffset(0, 10),
		Size = UDim2.new(1, 0, 0, 20),
		Parent = card,
	})
	if big then
		UI.Text({
			Name = "BigOne",
			Role = "Notes",
			Text = "the big one",
			TextSize = 13,
			TextColor3 = C.EmberBright,
			Position = UDim2.fromOffset(0, 30),
			Size = UDim2.new(1, 0, 0, 16),
			Parent = card,
		})
	end
	local iconSize = if big then 48 else 40
	local icon = UI.Icon("GiftBox", iconSize, {
		Name = "Reward",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, if big then 74 else 64),
		Parent = card,
	})
	local rewardLabel = UI.Text({
		Name = "Reward",
		Role = "Heading",
		Weight = "SemiBold",
		Text = "",
		RichText = false,
		TextSize = if big then 15 else 16,
		TextScaled = true,
		TextWrapped = true,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.new(1, -10, 0, if big then 62 else 56),
		Parent = card,
	})
	UI.new("UITextSizeConstraint", { MaxTextSize = if big then 15 else 16, MinTextSize = 9, Parent = rewardLabel })
	local check = UI.Icon("CheckMark", 44, {
		Name = "Claimed",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, if big then 74 else 64),
		ImageColor3 = C.Moss,
		ZIndex = 3,
		Visible = false,
		Parent = card,
	})
	-- The whole card is a button.
	local hit = UI.new("TextButton", {
		Name = "Hit",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 5,
		Parent = card,
	}) :: TextButton
	hit.Activated:Connect(function()
		local d = daily()
		if d and d.CanClaim and day == d.Day then
			claim()
		elseif d and day > (tonumber(d.ClaimedCount) or 0) then
			NotificationController.Show("Come back on Day " .. day .. " for this one!", "Info")
		end
	end)

	return {
		card = card,
		accent = card:FindFirstChild("Accent") :: Frame?,
		edge = card:FindFirstChildOfClass("UIStroke"),
		dayLabel = dayLabel,
		icon = icon,
		rewardLabel = rewardLabel,
		check = check,
		pulse = TweenService:Create(scale,
			TweenInfo.new(TUNING.PulseTime, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Scale = TUNING.PulseScale }),
		scale = scale,
	}
end

local function build()
	local w = Window.new({
		Name = "DailyRewards",
		Title = "Daily Rewards",
		Icon = "DailyRewards",
		Size = TUNING.WindowSize,
	})
	window = w
	w.OnOpen = function()
		render()
		renderStatus()
	end
	local body = w.Body

	UI.Text({
		Name = "Note",
		Role = "Notes",
		Text = "Check in once a day. Miss a day and the trail starts over at Day 1.",
		TextSize = 15,
		TextColor3 = C.TextDim,
		Size = UDim2.new(1, 0, 0, 20),
		Parent = body,
	})

	local row = UI.new("Frame", {
		Name = "Days",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 26),
		Size = UDim2.new(1, 0, 0, TUNING.CardHeight + 8),
		Parent = body,
	}, {
		UI.List({
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = TUNING.CardGap,
		}),
	})
	local length = #Config.Retention.Daily.Rewards
	for day = 1, length do
		table.insert(cards, buildCard(row, day, length))
	end

	statusLabel = UI.Text({
		Name = "Status",
		Role = "Heading",
		Weight = "Medium",
		Text = "Loading...",
		RichText = false,
		TextSize = 18,
		TextWrapped = true,
		TextColor3 = C.Text,
		Position = UDim2.fromOffset(0, TUNING.CardHeight + 38),
		Size = UDim2.new(1, 0, 0, 44),
		Parent = body,
	})

	claimButton = UI.Button({
		Name = "ClaimBtn",
		Text = "Claim",
		Variant = "Primary",
		TextSize = 22,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromOffset(220, 50),
		Parent = body,
		OnClick = function()
			task.spawn(claim)
		end,
	})
end

function DailyRewardsController.Open()
	local w = window
	if w then
		w:Open()
	end
end

--- Pops the screen up once after joining, if there's a reward waiting —
--- but only after the Offline Earnings popup is dealt with.
local function autoOpenOnce()
	task.wait(Config.Retention.Daily.AutoOpenDelay)
	-- A brand-new player is in the tutorial: don't cover it. The HUD Daily
	-- tile's "!" still says there's a reward waiting.
	if Players.LocalPlayer:GetAttribute("TutorialActive") == true then
		return
	end
	local deadline = os.clock() + TUNING.AutoOpenGiveUp
	while os.clock() < deadline do
		if Players.LocalPlayer:GetAttribute("TutorialActive") == true then
			return -- the tutorial started meanwhile: leave it be
		end
		local s = state
		local offline = s and s.Offline
		-- The server works out this visit's offline cash a few seconds after
		-- joining (Offline.Computed). Until then we can't know whether the
		-- offline popup is about to appear, so wait for it.
		local offlineUnknown = offline ~= nil and offline.Enabled == true and offline.Computed == false
		local offlinePending = offline ~= nil and offline.Enabled == true and (tonumber(offline.Pending) or 0) > 0
		if s and not offlineUnknown and not offlinePending and not DailyRewardsController.OtherPopupOpen(window) then
			local d = s.Daily
			if d and d.Enabled and d.CanClaim then
				DailyRewardsController.Open()
			end
			return
		end
		task.wait(1)
	end
end

local function onState()
	local d = daily()
	HudController.SetAlert("DailyBtn", d ~= nil and d.Enabled == true and d.CanClaim == true)
	render()
	renderStatus()
end

function DailyRewardsController.Start()
	-- State store first: the other retention controllers read it.
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("RetentionState") :: RemoteEvent
	remote.OnClientEvent:Connect(function(newState)
		if typeof(newState) ~= "table" then
			return
		end
		serverOffset = (tonumber(newState.ServerNow) or Workspace:GetServerTimeNow()) - Workspace:GetServerTimeNow()
		state = newState
		DailyRewardsController.StateChanged:Fire(newState)
	end)

	build()

	HudController.Bind("DailyBtn", DailyRewardsController.Open, "Daily", "DailyRewards")
	HudController.SetAlert("DailyBtn", false)

	DailyRewardsController.StateChanged:Connect(onState)
	if state then
		onState()
	end

	task.spawn(function()
		while true do
			task.wait(1)
			local w = window
			if w and w:IsOpen() then
				renderStatus()
			end
		end
	end)

	task.spawn(autoOpenOnce)
end

return DailyRewardsController
