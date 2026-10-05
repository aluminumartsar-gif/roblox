--!strict
--[[
	PlaytimeGiftsController
	StarterPlayerScripts/Client/Controllers/PlaytimeGiftsController

	Playtime Gifts, on the STUD kit's Rewards popup, opened from the HUD's
	Gift button. Gifts unlock the longer this visit lasts
	(Config.Retention.Playtime.Gifts); each opens once per visit.

	  left tile    the next gift to open: its reward and icon
	  right tile   the one after it ("?")
	  bar + time   minutes played this visit toward that gift ("3:00 / 5:00")
	  CLAIM        opens it once it's ready (the kit's SKIP button is hidden)

	HUD: the Gift button counts down to the next gift, says "Claim!" with a
	red "!" when one is ready.

	Display only: RetentionService keeps the clock and decides what's open.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Components = script.Parent.Parent:WaitForChild("Components")
local Kit = require(Components:WaitForChild("Kit"))
local HudController = require(script.Parent:WaitForChild("HudController"))
local Retention = require(script.Parent:WaitForChild("DailyRewardsController"))

local PlaytimeGiftsController = {}

local GIFTS = Config.Retention.Playtime.Gifts

local popup: Kit.Popup
local currentIcon: ImageLabel? = nil
local currentTitle: TextLabel? = nil
local nextTile: GuiObject? = nil
local nextTitle: TextLabel? = nil
local arrow: GuiObject? = nil
local barFill: GuiObject? = nil
local progressLabel: TextLabel? = nil
local timeLabel: TextLabel? = nil
local claimButton: GuiButton? = nil
local busy = false

local function giftList(): { any }
	local s = Retention.GetState()
	local gifts = s and s.Gifts
	return if gifts and gifts.Enabled and typeof(gifts.List) == "table" then gifts.List else {}
end

--- The first gift not opened yet (index, entry), or nil when all are open.
local function currentGift(): (number?, any)
	for i, gift in ipairs(giftList()) do
		if not gift.Claimed then
			return i, gift
		end
	end
	return nil, nil
end

local function isReady(gift: any): boolean
	return gift ~= nil and not gift.Claimed and (tonumber(gift.UnlockAt) or math.huge) <= Retention.ServerNow()
end

local function anyReady(): boolean
	for _, gift in ipairs(giftList()) do
		if isReady(gift) then
			return true
		end
	end
	return false
end

local function render()
	local list = giftList()
	local index, gift = currentGift()
	if not index or not gift then
		-- Everything opened (or gifts are off).
		local last = list[#list]
		if currentIcon and last then
			currentIcon.Image = Config.Icons[last.Icon] or ""
		end
		Kit.SetText(currentTitle, if #list > 0 then "All open!" else "")
		Kit.Hide(nextTile)
		Kit.Hide(arrow)
		if barFill then
			barFill.Size = UDim2.fromScale(1, 1)
		end
		Kit.SetText(progressLabel, if #list > 0 then "All gifts opened" else "No gifts right now")
		Kit.SetText(timeLabel, "More next time you join!")
		Kit.SetButtonText(claimButton, "DONE")
		Kit.SetButtonEnabled(claimButton, false)
		return
	end

	if currentIcon then
		currentIcon.Image = Config.Icons[gift.Icon] or ""
	end
	Kit.SetText(currentTitle, tostring(gift.Short or ("Gift " .. index)))
	local hasNext = list[index + 1] ~= nil
	if nextTile then
		nextTile.Visible = hasNext
	end
	if arrow then
		arrow.Visible = hasNext
	end
	Kit.SetText(nextTitle, "Gift " .. (index + 1))
	Kit.SetText(progressLabel, string.format("Gift %d of %d", index, #list))

	-- Minutes played this visit toward this gift.
	local config = GIFTS[index]
	local total = (if config then config.Minutes or 0 else 0) * 60
	local unlockAt = tonumber(gift.UnlockAt) or 0
	local startedAt = unlockAt - total
	local elapsed = math.clamp(Retention.ServerNow() - startedAt, 0, total)
	local ready = isReady(gift)
	if barFill then
		local fraction = if ready or total <= 0 then 1 else elapsed / total
		barFill.Size = UDim2.fromScale(math.max(fraction, 0.03), 1)
	end
	if ready then
		Kit.SetText(timeLabel, "Ready to open!")
	else
		Kit.SetText(timeLabel, Retention.FormatClock(elapsed) .. " / " .. Retention.FormatClock(total))
	end
	Kit.SetButtonText(claimButton, if ready then "CLAIM" else "WAIT")
	Kit.SetButtonEnabled(claimButton, ready)
end

local function renderHud()
	local list = giftList()
	if #list == 0 then
		HudController.SetAlert("GiftBtn", false)
		HudController.SetCaption("GiftBtn", "Gifts")
		return
	end
	if anyReady() then
		HudController.SetAlert("GiftBtn", true)
		HudController.SetCaption("GiftBtn", "Claim!")
		return
	end
	HudController.SetAlert("GiftBtn", false)
	local soonest = math.huge
	for _, gift in ipairs(list) do
		if not gift.Claimed then
			soonest = math.min(soonest, tonumber(gift.UnlockAt) or math.huge)
		end
	end
	if soonest == math.huge then
		HudController.SetCaption("GiftBtn", "Gifts")
	else
		HudController.SetCaption("GiftBtn", Retention.FormatClock(soonest - Retention.ServerNow()))
	end
end

local function claim()
	local index, gift = currentGift()
	if busy or not index or not isReady(gift) then
		return
	end
	busy = true
	local result = Retention.Invoke("ClaimPlaytimeGift", index)
	busy = false
	if result and result.Ok then
		Retention.Play("GiftClaim")
	end
end

local function build()
	local gui = Kit.Mount("Rewards")
	popup = Kit.Popup(gui)
	popup.OnOpen = render

	local navBar = Kit.Deep(gui, "NavBar")
	Kit.SetText(navBar and navBar:FindFirstChild("Title"), "Gifts")

	local content = Kit.Deep(gui, "Content")
	if not content then
		warn("[SAC/Gifts] the kit's Rewards screen has no Content frame")
		return
	end

	-- Left tile: the gift you're working toward.
	local clipping = content:FindFirstChild("ClippingItems")
	local icon = clipping and clipping:FindFirstChild("Icon")
	if icon and icon:IsA("ImageLabel") then
		currentIcon = icon
		currentTitle = icon:FindFirstChildWhichIsA("TextLabel")
	end

	-- Right tile: the one after ("?" stays).
	local gift = content:FindFirstChild("Gift")
	if gift and gift:IsA("GuiObject") then
		nextTile = gift
		for _, label in ipairs(gift:GetChildren()) do
			if label:IsA("TextLabel") and label.Text ~= "?" then
				nextTitle = label
			end
		end
	end
	local arrowImage = content:FindFirstChild("Arrow")
	arrow = if arrowImage and arrowImage:IsA("GuiObject") then arrowImage else nil

	-- Progress bar. Its fill keeps a fixed shape (aspect constraint) in the
	-- kit; drop that so the fill can stretch with progress.
	local bar = content:FindFirstChild("Bar")
	local fill = bar and bar:FindFirstChild("InsideBar")
	if fill and fill:IsA("GuiObject") then
		local aspect = fill:FindFirstChildOfClass("UIAspectRatioConstraint")
		if aspect then
			aspect:Destroy()
		end
		barFill = fill
	end

	-- The two text lines under the tiles, told apart by their sample text.
	for _, child in ipairs(content:GetChildren()) do
		if child:IsA("TextLabel") and child.Name == "Title" then
			if child.Text == "Progress" then
				progressLabel = child
			else
				timeLabel = child
			end
		end
	end

	local buy = content:FindFirstChild("Buy")
	if buy and buy:IsA("GuiButton") then
		claimButton = buy
		buy.Activated:Connect(function()
			task.spawn(claim)
		end)
	end
	Kit.Hide(content:FindFirstChild("SkipBtn"))
end

function PlaytimeGiftsController.Open()
	if popup then
		popup:Open()
	end
end

function PlaytimeGiftsController.Start()
	build()
	HudController.Bind("GiftBtn", PlaytimeGiftsController.Open, "Gifts", "GiftBox")
	HudController.SetAlert("GiftBtn", false)

	Retention.StateChanged:Connect(function()
		renderHud()
		if popup and popup:IsOpen() then
			render()
		end
	end)

	local wasReady = false
	task.spawn(function()
		while true do
			task.wait(1)
			renderHud()
			if popup and popup:IsOpen() then
				render()
			end
			-- A little chime the moment a gift becomes ready.
			local ready = anyReady()
			if ready and not wasReady then
				Retention.Play("Notify")
			end
			wasReady = ready
		end
	end)
end

return PlaytimeGiftsController
