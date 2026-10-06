--!strict
--[[
	PlaytimeGiftsController
	StarterPlayerScripts/Client/Controllers/PlaytimeGiftsController

	Playtime Gifts ("campfire field kit" Window "Gifts"), opened from the
	HUD's Gifts tile. Gifts unlock the longer this visit lasts
	(Config.Retention.Playtime.Gifts); each opens once per visit.

	  left card    the next gift to open: its reward and icon
	  right card   the one after it ("?"), with an arrow between
	  line + bar   "Gift n of m" and minutes played this visit toward that
	               gift ("3:00 / 5:00", or "Ready to open!")
	  CLAIM        opens it once it's ready; WAIT (greyed) until then; DONE
	               (greyed) once every gift is open

	HUD: the Gifts tile counts down to the next gift, says "Claim!" with a
	red "!" when one is ready, and a chime plays the moment one becomes
	ready.

	Display only: RetentionService keeps the clock and decides what's open.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Components = script.Parent.Parent:WaitForChild("Components")
local Theme = require(Components:WaitForChild("Theme"))
local UI = require(Components:WaitForChild("UI"))
local Icon = require(Components:WaitForChild("Icon"))
local Window = require(Components:WaitForChild("Window"))
local HudController = require(script.Parent:WaitForChild("HudController"))
local Retention = require(script.Parent:WaitForChild("DailyRewardsController"))

local PlaytimeGiftsController = {}

local C = Theme.Colors
local GIFTS = Config.Retention.Playtime.Gifts
local TUNING = Config.UI.Retention.Gifts

local window: Window.Window? = nil
local currentIcon: ImageLabel? = nil
local currentTitle: TextLabel? = nil
local nextTile: GuiObject? = nil
local nextTitle: TextLabel? = nil
local arrow: GuiObject? = nil
local bar: Frame? = nil
local progressLabel: TextLabel? = nil
local timeLabel: TextLabel? = nil
local claimButton: TextButton? = nil
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

local function setText(label: TextLabel?, text: string)
	if label then
		label.Text = text
	end
end

local function setIcon(label: ImageLabel?, name: any)
	if label then
		Icon.set(label, if typeof(name) == "string" and Config.Icons[name] then name else "GiftBox")
	end
end

local function render()
	local list = giftList()
	local index, gift = currentGift()
	if not index or not gift then
		-- Everything opened (or gifts are off).
		local last = list[#list]
		setIcon(currentIcon, last and last.Icon)
		setText(currentTitle, if #list > 0 then "All open!" else "")
		if nextTile then
			nextTile.Visible = false
		end
		if arrow then
			arrow.Visible = false
		end
		UI.SetProgress(bar, 1)
		setText(progressLabel, if #list > 0 then "All gifts opened" else "No gifts right now")
		setText(timeLabel, "More next time you join!")
		UI.SetButtonText(claimButton, "Done")
		UI.SetButtonEnabled(claimButton, false)
		return
	end

	setIcon(currentIcon, gift.Icon)
	setText(currentTitle, tostring(gift.Short or ("Gift " .. index)))
	local hasNext = list[index + 1] ~= nil
	if nextTile then
		nextTile.Visible = hasNext
	end
	if arrow then
		arrow.Visible = hasNext
	end
	setText(nextTitle, "Gift " .. (index + 1))
	setText(progressLabel, string.format("Gift %d of %d", index, #list))

	-- Minutes played this visit toward this gift.
	local config = GIFTS[index]
	local total = (if config then config.Minutes or 0 else 0) * 60
	local unlockAt = tonumber(gift.UnlockAt) or 0
	local startedAt = unlockAt - total
	local elapsed = math.clamp(Retention.ServerNow() - startedAt, 0, total)
	local ready = isReady(gift)
	local fraction = if ready or total <= 0 then 1 else elapsed / total
	UI.SetProgress(bar, math.max(fraction, TUNING.BarMinFill))
	if ready then
		setText(timeLabel, "Ready to open!")
	else
		setText(timeLabel, Retention.FormatClock(elapsed) .. " / " .. Retention.FormatClock(total))
	end
	UI.SetButtonText(claimButton, if ready then "Claim" else "Wait")
	UI.SetButtonEnabled(claimButton, ready)
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
	local w = Window.new({
		Name = "Gifts",
		Title = "Gifts",
		Icon = "GiftBox",
		Size = TUNING.WindowSize,
	})
	window = w
	w.OnOpen = render
	local body = w.Body

	UI.Text({
		Name = "Note",
		Role = "Notes",
		Text = "Gifts unlock the longer you stay this visit.",
		TextSize = 15,
		TextColor3 = C.TextDim,
		Size = UDim2.new(1, 0, 0, 20),
		Parent = body,
	})

	-- The two cards with an arrow between them.
	local row = UI.new("Frame", {
		Name = "Cards",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 28),
		Size = UDim2.new(1, 0, 0, 140),
		Parent = body,
	}, {
		UI.List({
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = 16,
		}),
	})

	local current = UI.Card({
		Name = "Current",
		Accent = C.Ember,
		Size = UDim2.fromOffset(220, 140),
		LayoutOrder = 1,
		Parent = row,
	})
	currentIcon = UI.Icon("GiftBox", 64, {
		Name = "Reward",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 16),
		Parent = current,
	})
	currentTitle = UI.Text({
		Name = "Title",
		Role = "Heading",
		Weight = "Bold",
		Text = "",
		RichText = false,
		TextSize = 20,
		TextWrapped = true,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.new(1, -16, 0, 46),
		Parent = current,
	})

	arrow = UI.Icon("ChevronRight", 32, {
		Name = "Arrow",
		ImageColor3 = C.TextDim,
		LayoutOrder = 2,
		Parent = row,
	})

	local nextCard = UI.Card({
		Name = "Next",
		Size = UDim2.fromOffset(140, 140),
		LayoutOrder = 3,
		Parent = row,
	})
	UI.Icon("QuestionMark", 48, {
		Name = "Mystery",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 22),
		ImageColor3 = C.TextFaint,
		Parent = nextCard,
	})
	nextTitle = UI.Text({
		Name = "Title",
		Role = "Heading",
		Weight = "SemiBold",
		Text = "",
		TextSize = 18,
		TextColor3 = C.TextDim,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.new(1, -12, 0, 24),
		Parent = nextCard,
	})
	nextTile = nextCard

	-- "Gift n of m" on the left, the clock on the right, the bar under them.
	progressLabel = UI.Text({
		Name = "Progress",
		Role = "Heading",
		Weight = "Bold",
		Text = "",
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(0, 180),
		Size = UDim2.new(0.5, 0, 0, 22),
		Parent = body,
	})
	timeLabel = UI.Text({
		Name = "Time",
		Role = "Heading",
		Weight = "SemiBold",
		Text = "",
		TextSize = 18,
		TextColor3 = C.TextDim,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 180),
		Size = UDim2.new(0.5, 0, 0, 22),
		Parent = body,
	})
	bar = UI.ProgressBar({
		Name = "Bar",
		Color = C.Ember,
		Position = UDim2.fromOffset(0, 206),
		Size = UDim2.new(1, 0, 0, 18),
		Parent = body,
	})

	claimButton = UI.Button({
		Name = "ClaimBtn",
		Text = "Wait",
		Variant = "Primary",
		Icon = "GiftBox",
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

function PlaytimeGiftsController.Open()
	local w = window
	if w then
		w:Open()
	end
end

function PlaytimeGiftsController.Start()
	build()
	HudController.Bind("GiftBtn", PlaytimeGiftsController.Open, "Gifts", "GiftBox")
	HudController.SetAlert("GiftBtn", false)

	Retention.StateChanged:Connect(function()
		renderHud()
		local w = window
		if w and w:IsOpen() then
			render()
		end
	end)

	local wasReady = false
	task.spawn(function()
		while true do
			task.wait(1)
			renderHud()
			local w = window
			if w and w:IsOpen() then
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
