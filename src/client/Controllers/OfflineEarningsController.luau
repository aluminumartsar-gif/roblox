--!strict
--[[
	OfflineEarningsController
	StarterPlayerScripts/Client/Controllers/OfflineEarningsController

	The "while you were away" popup, on the STUD kit's OfflineRewardsPopup.
	It appears whenever the server says there's offline cash waiting
	(RetentionState Offline.Pending > 0):

	  "Your cryptids earned  $X"
	  [CLAIM 2x  R$..]  buys Double Offline Cash (the server prompts; the
	                    receipt pays it twice over)
	  [CLAIM!]          takes it

	It closes by itself once the cash is claimed. The waiting cash is saved
	on the server, so if the popup gets closed by another screen it comes
	back a few seconds later, and after a rejoin.

	Display only: RetentionService works out the amount.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Components = script.Parent.Parent:WaitForChild("Components")
local Kit = require(Components:WaitForChild("Kit"))
local Retention = require(script.Parent:WaitForChild("DailyRewardsController"))

local OfflineEarningsController = {}

local localPlayer = Players.LocalPlayer

-- If Roblox never reports how a purchase prompt ended, stop waiting after this.
local PURCHASE_WAIT_LIMIT = 60
-- How often a closed popup with cash still waiting tries to come back.
local REOPEN_CHECK_INTERVAL = 3

local popup: Kit.Popup
local amountLabel: TextLabel? = nil
local headerLabel: TextLabel? = nil
local claimButton: GuiButton? = nil
local doubleButton: GuiButton? = nil
local doubleLabel: TextLabel? = nil
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
	Kit.SetText(amountLabel, "$" .. Config.FormatNumber(amount))
	Kit.SetText(headerLabel, awayText())
	local purchasing = os.clock() < purchasingUntil
	Kit.SetButtonEnabled(claimButton, not purchasing and not busy)
	Kit.SetText(doubleLabel, "CLAIM 2x  " .. Retention.PriceText("OfflineDouble"))
	Kit.SetButtonEnabled(doubleButton, not purchasing and not busy)
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
		popup:Close()
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
	local gui = Kit.Mount("OfflineRewardsPopup")
	popup = Kit.Popup(gui)
	popup.OnOpen = render

	local navBar = Kit.Deep(gui, "NavBar")
	Kit.SetText(navBar and navBar:FindFirstChild("Title"), "WHILE YOU WERE AWAY")

	local content = Kit.Deep(gui, "Content")
	if not content then
		warn("[SAC/Offline] the kit's OfflineRewardsPopup has no Content frame")
		return
	end
	local header = content:FindFirstChild("HeaderText")
	if header and header:IsA("TextLabel") then
		headerLabel = header
		-- Our line is longer than the kit's "Total Earnings:".
		header.Size = UDim2.fromScale(0.9, header.Size.Y.Scale)
		header.Position = UDim2.fromScale(0.05, header.Position.Y.Scale)
	end
	local body = content:FindFirstChild("BodyText")
	if body and body:IsA("TextLabel") then
		amountLabel = body
		body.Size = UDim2.fromScale(0.6, body.Size.Y.Scale)
		body.Position = UDim2.fromScale(0.2, body.Position.Y.Scale)
	end

	local claimBtn = content:FindFirstChild("ClaimBtn")
	if claimBtn and claimBtn:IsA("GuiButton") then
		claimButton = claimBtn
		Kit.SetButtonText(claimBtn, "CLAIM!")
		claimBtn.Activated:Connect(function()
			task.spawn(claim)
		end)
	end

	local doubleBtn = content:FindFirstChild("DoubleBtn")
	if doubleBtn and doubleBtn:IsA("GuiButton") then
		doubleButton = doubleBtn
		-- The kit's Double button has two stacked labels; use the first.
		local labels = {}
		for _, child in ipairs(doubleBtn:GetChildren()) do
			if child:IsA("TextLabel") then
				table.insert(labels, child)
			end
		end
		for i, label in ipairs(labels) do
			if i == 1 then
				doubleLabel = label
			else
				label.Visible = false
			end
		end
		doubleBtn.Activated:Connect(function()
			task.spawn(buyDouble)
		end)
	end
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
			popup:Close()
		elseif lastPending <= 0 or popup:IsOpen() then
			render()
			if not popup:IsOpen() then
				popup:Open()
			end
		end
		lastPending = amount
	end)

	-- Cash is still waiting but the popup got closed (another screen opened
	-- over it): bring it back once nothing else is open.
	task.spawn(function()
		while true do
			task.wait(REOPEN_CHECK_INTERVAL)
			if pending() > 0 and not popup:IsOpen() and not Retention.OtherPopupOpen(popup.Gui) then
				popup:Open()
			elseif popup:IsOpen() then
				render()
			end
		end
	end)
end

return OfflineEarningsController
