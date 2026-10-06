--!strict
--[[
	OfflineEarningsController
	StarterPlayerScripts/Client/Controllers/OfflineEarningsController

	The "while you were away" popup ("campfire field kit" Window "Offline").
	It appears whenever the server says there's offline cash waiting
	(RetentionState Offline.Pending > 0):

	  "Away 3h 12m, your cryptids earned"
	  $X                 (moss green, the cash icon beside it)
	  [CLAIM]            takes it (Cash button)
	  [CLAIM 2x  R$..]   buys Double Offline Cash (Robux, Moon button; the
	                     server prompts; the receipt pays it twice over)

	Both buttons grey out while a claim is in flight or the Double purchase
	prompt is open. It closes by itself once the cash is claimed. The waiting
	cash is saved on the server, so if the popup gets closed by another
	screen it comes back a few seconds later (once nothing else is open),
	and after a rejoin. It never opens over the first-join tutorial.

	Display only: RetentionService works out the amount.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Components = script.Parent.Parent:WaitForChild("Components")
local Theme = require(Components:WaitForChild("Theme"))
local UI = require(Components:WaitForChild("UI"))
local Window = require(Components:WaitForChild("Window"))
local Retention = require(script.Parent:WaitForChild("DailyRewardsController"))

local OfflineEarningsController = {}

local localPlayer = Players.LocalPlayer
local C = Theme.Colors
local TUNING = Config.UI.Retention.Offline

-- If Roblox never reports how a purchase prompt ended, stop waiting after this.
local PURCHASE_WAIT_LIMIT = 60
-- How often a closed popup with cash still waiting tries to come back.
local REOPEN_CHECK_INTERVAL = 3

local window: Window.Window
local amountLabel: TextLabel? = nil
local headerLabel: TextLabel? = nil
local claimButton: TextButton? = nil
local doubleButton: TextButton? = nil
local busy = false
local purchasingUntil = 0 -- os.clock(); Claim waits while a Double prompt is open

local function pending(): number
	local s = Retention.GetState()
	local offline = s and s.Offline
	if not offline or not offline.Enabled then
		return 0
	end
	return tonumber(offline.Pending) or 0
end

local function awayText(): string
	local s = Retention.GetState()
	local seconds = s and s.Offline and tonumber(s.Offline.AwaySeconds) or 0
	-- A short absence earns nothing, so cash waiting now is from an earlier
	-- visit: don't pair it with this visit's few minutes away.
	if seconds < Config.Retention.Offline.MinAwaySeconds then
		return "Your cryptids earned"
	end
	local hours = seconds // 3600
	local minutes = (seconds % 3600) // 60
	local away = if hours > 0 then string.format("%dh %dm", hours, minutes) else string.format("%dm", math.max(1, minutes))
	return "Away " .. away .. ", your cryptids earned"
end

local function render()
	local amount = pending()
	if amountLabel then
		amountLabel.Text = "$" .. Config.FormatNumber(amount)
	end
	if headerLabel then
		headerLabel.Text = awayText()
	end
	local purchasing = os.clock() < purchasingUntil
	UI.SetButtonEnabled(claimButton, not purchasing and not busy)
	UI.SetButtonText(doubleButton, "Claim 2x  " .. Retention.PriceText("OfflineDouble"))
	UI.SetButtonEnabled(doubleButton, not purchasing and not busy)
end

local function claim()
	if busy or pending() <= 0 or os.clock() < purchasingUntil then
		return
	end
	busy = true
	render()
	local result = Retention.Invoke("ClaimOffline")
	busy = false
	if result and result.Ok then
		Retention.Play("CashCollect")
		window:Close()
	end
	render()
end

local function buyDouble()
	if busy or pending() <= 0 or os.clock() < purchasingUntil then
		return
	end
	busy = true
	local result = Retention.Invoke("PromptPurchase", "Product", "OfflineDouble")
	busy = false
	if result and result.Ok then
		-- The Roblox prompt is open; don't let Claim race the purchase.
		purchasingUntil = os.clock() + PURCHASE_WAIT_LIMIT
	end
	render()
end

local function build()
	window = Window.new({
		Name = "Offline",
		Title = "While You Were Away",
		Icon = "Moon",
		Size = TUNING.WindowSize,
	})
	window.OnOpen = render
	local body = window.Body

	headerLabel = UI.Text({
		Name = "Away",
		Role = "Notes",
		Text = "Your cryptids earned",
		RichText = false,
		TextSize = 19,
		TextColor3 = C.TextDim,
		Size = UDim2.new(1, 0, 0, 26),
		Parent = body,
	})

	-- The amount, with the cash icon, centred.
	local amountRow = UI.new("Frame", {
		Name = "Amount",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 34),
		Size = UDim2.new(1, 0, 0, 66),
		Parent = body,
	}, {
		UI.List({
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = 10,
		}),
	})
	UI.Icon("Cash", 46, { Name = "CashIcon", ImageColor3 = C.Moss, LayoutOrder = 1, Parent = amountRow })
	amountLabel = UI.Text({
		Name = "Value",
		Role = "Heading",
		Weight = "Bold",
		Text = "$0",
		RichText = false,
		TextSize = 54,
		TextColor3 = C.MossBright,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		LayoutOrder = 2,
		Parent = amountRow,
	})

	UI.Text({
		Name = "Note",
		Role = "Notes",
		Text = "Your cash waits here at camp until you claim it.",
		TextSize = 15,
		TextColor3 = C.TextFaint,
		Position = UDim2.fromOffset(0, 108),
		Size = UDim2.new(1, 0, 0, 20),
		Parent = body,
	})

	local buttons = UI.new("Frame", {
		Name = "Buttons",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 56),
		Parent = body,
	}, {
		UI.List({
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = 16,
		}),
	})
	claimButton = UI.Button({
		Name = "ClaimBtn",
		Text = "Claim!",
		Variant = "Cash",
		Icon = "Cash",
		TextSize = 22,
		Size = UDim2.fromOffset(210, 54),
		LayoutOrder = 1,
		Parent = buttons,
		OnClick = function()
			task.spawn(claim)
		end,
	})
	doubleButton = UI.Button({
		Name = "DoubleBtn",
		Text = "Claim 2x",
		Variant = "Moon",
		Icon = "Robux",
		TextSize = 22,
		Size = UDim2.fromOffset(250, 54),
		LayoutOrder = 2,
		Parent = buttons,
		OnClick = function()
			task.spawn(buyDouble)
		end,
	})
end

function OfflineEarningsController.Start()
	build()

	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId: number, productId: number, _purchased: boolean)
		if userId == localPlayer.UserId and productId == Config.DevProducts.OfflineDouble.Id then
			purchasingUntil = 0
			render()
		end
	end)

	local lastPending = 0
	Retention.StateChanged:Connect(function()
		local amount = pending()
		if amount <= 0 then
			window:Close()
		elseif lastPending <= 0 or window:IsOpen() then
			render()
			-- Not over the first-join tutorial; the loop below opens it after.
			if not window:IsOpen() and localPlayer:GetAttribute("TutorialActive") ~= true then
				window:Open()
			end
		end
		lastPending = amount
	end)

	-- Cash is still waiting but the popup got closed (another screen opened
	-- over it): bring it back once nothing else is open.
	task.spawn(function()
		while true do
			task.wait(REOPEN_CHECK_INTERVAL)
			if pending() > 0 and not window:IsOpen() and not Retention.OtherPopupOpen(window)
				and localPlayer:GetAttribute("TutorialActive") ~= true then
				window:Open()
			elseif window:IsOpen() then
				render()
			end
		end
	end)
end

return OfflineEarningsController
