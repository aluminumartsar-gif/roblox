--!strict
--[[
	DailyRewardsController
	StarterPlayerScripts/Client/Controllers/DailyRewardsController

	The Daily Rewards screen, on the STUD kit's DailyRewards popup, opened
	from the HUD's Daily button (bottom right):

	  7 cards     Day 1..7: the reward (icon + short text), a tick on days
	              already claimed this week, "TODAY" (gently pulsing) on the
	              one you can claim now. Tap today's card to claim it.
	  bottom line what today's reward is in full, or a countdown to
	              tomorrow's.

	The HUD button shows a red "!" while there's something to claim, and the
	screen pops up once on joining when there is (after the Offline Earnings
	popup, never on top of it).

	ALSO the shared client side of retention (it starts first of the four
	retention controllers, which all require it):
	  GetState / StateChanged   latest RetentionState push from the server
	  ServerNow()               the server's clock, for countdowns
	  FormatClock, Play, Invoke, PriceText, OtherPopupOpen  — small helpers

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
local Kit = require(Components:WaitForChild("Kit"))
local Icon = require(Components:WaitForChild("Icon"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))
local HudController = require(script.Parent:WaitForChild("HudController"))

local DailyRewardsController = {}

--- Fired as (state) whenever the server sends new retention state.
DailyRewardsController.StateChanged = Signal.new()

local localPlayer = Players.LocalPlayer

local CLAIMED_TINT = Color3.fromRGB(130, 130, 130)
local LOCKED_TINT = Color3.fromRGB(205, 205, 215)
local PULSE_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)

local state: { [string]: any }? = nil
local serverOffset = 0 -- server os.time() minus our GetServerTimeNow()
local soundController: any = nil
local prices: { [string]: number } = {}
local priceRequested: { [string]: boolean } = {}

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
				priceRequested[productKey] = nil -- try again later
			end
		end)
	end
	return "..."
end

--- True if a kit screen other than `except` is open right now.
function DailyRewardsController.OtherPopupOpen(except: ScreenGui?): boolean
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	if not playerGui then
		return false
	end
	for _, gui in ipairs(playerGui:GetChildren()) do
		if gui:IsA("ScreenGui") and gui ~= except and gui.Enabled and gui.Name ~= "HUD"
			and gui:FindFirstChild("Container") then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------
-- The screen
--------------------------------------------------------------------------

type Card = {
	frame: GuiObject,
	button: GuiButton?,
	icon: ImageLabel?,
	dayLabel: TextLabel?,
	rewardLabel: TextLabel?,
	check: ImageLabel,
	pulse: Tween,
	scale: UIScale,
}

local popup: Kit.Popup
local cards: { Card } = {}
local statusLabel: TextLabel? = nil
local busy = false

local function daily(): { [string]: any }?
	local s = state
	return s and s.Daily
end

local function claim()
	local d = daily()
	if busy or not d or not d.CanClaim then
		return
	end
	busy = true
	local result = DailyRewardsController.Invoke("ClaimDaily")
	busy = false
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
		card.frame.Visible = reward ~= nil
		if not reward then
			continue
		end
		local claimed = i <= (tonumber(d.ClaimedCount) or 0)
		local isToday = d.CanClaim == true and i == d.Day
		Kit.SetText(card.rewardLabel, tostring(reward.Short or ""))
		Kit.SetText(card.dayLabel, if isToday then "TODAY" else ("Day " .. i))
		if card.icon then
			card.icon.Image = Config.Icons[reward.Icon] or ""
			card.icon.ImageTransparency = if claimed then 0.5 else 0
		end
		if card.button and card.button:IsA("ImageButton") then
			card.button.ImageColor3 = if claimed then CLAIMED_TINT elseif isToday then Color3.new(1, 1, 1) else LOCKED_TINT
		end
		card.check.Visible = claimed
		if isToday then
			card.pulse:Play()
		else
			card.pulse:Cancel()
			card.scale.Scale = 1
		end
	end
end

--- The bottom line (ticks every second for the countdown).
local function renderStatus()
	local d = daily()
	if not statusLabel then
		return
	end
	if not d then
		statusLabel.Text = "Loading..."
	elseif not d.Enabled then
		statusLabel.Text = "Daily rewards are resting for now."
	elseif d.CanClaim then
		local reward = (d.Rewards or {})[d.Day]
		statusLabel.Text = string.format("Tap today's card to claim: %s", tostring(reward and reward.Detail or ""))
	else
		local remaining = (tonumber(d.NextClaimAt) or 0) - DailyRewardsController.ServerNow()
		statusLabel.Text = "Come back tomorrow! Next reward in " .. DailyRewardsController.FormatClock(remaining)
	end
end

local function build()
	local gui = Kit.Mount("DailyRewards")
	popup = Kit.Popup(gui)
	popup.OnOpen = function()
		render()
		renderStatus()
	end

	local background = gui:WaitForChild("Container"):FindFirstChild("Background")
	local content = background and background:FindFirstChild("Content")
	-- The line under the cards (kit text: "Gifts Refresh every 12 hours").
	local title = background and background:FindFirstChild("Title")
	if title and title:IsA("TextLabel") then
		title.TextWrapped = true
		-- Wider, so a long day-7 reward still reads on a phone.
		title.AnchorPoint = Vector2.new(0.5, title.AnchorPoint.Y)
		title.Position = UDim2.new(0.5, 0, title.Position.Y.Scale, title.Position.Y.Offset)
		title.Size = UDim2.new(0.92, 0, title.Size.Y.Scale, title.Size.Y.Offset)
		statusLabel = title
	end
	if not content then
		warn("[SAC/Daily] the kit's DailyRewards screen has no Content frame")
		return
	end

	-- The kit ships three styles of the same card (claim / claimed / timer).
	-- Use the "claim" one for all seven, so every card has a reward line.
	local kitCard = content:FindFirstChild("ClaimGift")
	if not kitCard or not kitCard:IsA("GuiObject") then
		warn("[SAC/Daily] the kit's DailyRewards screen has no ClaimGift card")
		return
	end
	local template = kitCard:Clone()
	for _, child in ipairs(content:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local layout = content:FindFirstChildOfClass("UIListLayout")
	if layout then
		layout.SortOrder = Enum.SortOrder.LayoutOrder
	end

	local length = #Config.Retention.Daily.Rewards
	for i = 1, length do
		local frame = template:Clone()
		frame.Name = "Day" .. i
		frame.LayoutOrder = i
		frame.Parent = content
		local button = frame:FindFirstChild("ItemButton")
		local dayLabel, rewardLabel = nil, nil
		if button then
			for _, child in ipairs(button:GetChildren()) do
				if child:IsA("TextLabel") then
					-- The day label sits above the card; the "CLAIM!" line below.
					if child.Position.Y.Scale < 0.3 then
						dayLabel = child
					else
						rewardLabel = child
					end
				end
			end
		end
		local check = Icon.new("CheckMark", 0, button or frame, {
			Name = "Claimed",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.45),
			Size = UDim2.fromScale(0.55, 0.55),
			ZIndex = (if button and button:IsA("GuiObject") then button.ZIndex else frame.ZIndex) + 5,
			Visible = false,
		})
		local scale = Instance.new("UIScale")
		scale.Parent = frame
		local card: Card = {
			frame = frame,
			button = if button and button:IsA("GuiButton") then button else nil,
			icon = if button then button:FindFirstChild("Icon") :: ImageLabel? else nil,
			dayLabel = dayLabel,
			rewardLabel = rewardLabel,
			check = check,
			pulse = TweenService:Create(scale, PULSE_INFO, { Scale = 1.08 }),
			scale = scale,
		}
		table.insert(cards, card)
		if card.button then
			card.button.Activated:Connect(function()
				local d = daily()
				if d and d.CanClaim and i == d.Day then
					claim()
				elseif d and i > (tonumber(d.ClaimedCount) or 0) then
					NotificationController.Show("Come back on Day " .. i .. " for this one!", "Info")
				end
			end)
		end
	end
	template:Destroy()
end

function DailyRewardsController.Open()
	if popup then
		popup:Open()
	end
end

--- Pops the screen up once after joining, if there's a reward waiting —
--- but only after the Offline Earnings popup is dealt with.
local function autoOpenOnce()
	task.wait(Config.Retention.Daily.AutoOpenDelay)
	-- A brand-new player is in the tutorial: don't cover it. The HUD Daily
	-- button's "!" still says there's a reward waiting.
	if Players.LocalPlayer:GetAttribute("TutorialActive") == true then
		return
	end
	local deadline = os.clock() + 120
	while os.clock() < deadline do
		local s = state
		local offline = s and s.Offline
		-- The server works out this visit's offline cash a few seconds after
		-- joining (Offline.Computed). Until then we can't know whether the
		-- offline popup is about to appear, so wait for it.
		local offlineUnknown = offline ~= nil and offline.Enabled == true and offline.Computed == false
		local offlinePending = offline ~= nil and offline.Enabled == true and (tonumber(offline.Pending) or 0) > 0
		if s and not offlineUnknown and not offlinePending and not DailyRewardsController.OtherPopupOpen(popup and popup.Gui) then
			local d = s.Daily
			if d and d.Enabled and d.CanClaim then
				DailyRewardsController.Open()
			end
			return
		end
		task.wait(1)
	end
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

	HudController.Bind("DailyBtn", DailyRewardsController.Open, "Daily")
	HudController.SetAlert("DailyBtn", false)

	DailyRewardsController.StateChanged:Connect(function()
		local d = daily()
		HudController.SetAlert("DailyBtn", d ~= nil and d.Enabled == true and d.CanClaim == true)
		render()
		renderStatus()
	end)

	task.spawn(function()
		while true do
			task.wait(1)
			if popup and popup:IsOpen() then
				renderStatus()
			end
		end
	end)

	task.spawn(autoOpenOnce)
end

return DailyRewardsController
