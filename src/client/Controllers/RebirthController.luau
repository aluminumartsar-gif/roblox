--!strict
--[[
	RebirthController
	StarterPlayerScripts/Client/Controllers/RebirthController

	The rebirth screen: a "campfire field kit" window (Components/Window)
	opened from the HUD's Rebirth tile. Its title reads "Rebirth N" (the
	rebirth you'd be doing).
	  * cash bar: your cash toward the rebirth cost ("$cash / $cost")
	  * requirement line: whether a Rare+ cryptid is at home (YES / NO)
	  * three columns: what you LOSE (Config.Rebirth.Resets), what you KEEP,
	    and what you GAIN — total luck, total income, a new nest glow, and
	    the egg the next rebirth unlocks (if any)
	  * REBIRTH button: greyed out (with the reason under it) until you
	    could rebirth; tapping it then still tells you why not. When you
	    can, it opens a confirm box over the screen: "REBIRTH" calls
	    DoRebirth and closes the screen, "Cancel" goes back.

	A preview only; RebirthService re-checks everything on the server.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Components = script.Parent.Parent:WaitForChild("Components")
local Theme = require(Components:WaitForChild("Theme"))
local UI = require(Components:WaitForChild("UI"))
local Window = require(Components:WaitForChild("Window"))
local ProfileController = require(script.Parent:WaitForChild("ProfileController"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))

local RebirthController = {}

local C = Theme.Colors
local tuning = Config.UI.Shops.Rebirth

type Line = { frame: Frame, icon: ImageLabel, label: TextLabel }

local window: Window.Window
local costBar: Frame
local costLabel: TextLabel
local requirementIcon: ImageLabel
local requirementLabel: TextLabel
local rebirthButton: TextButton
local reasonLabel: TextLabel
local gainLines: { Line } = {}
local confirm: TextButton
local confirmScale: UIScale
local confirmText: TextLabel
local confirmYes: TextButton
local busy = false

type Status = { ready: boolean, reason: string?, cost: number, cash: number, hasRare: boolean, nextRebirth: number }

local function status(): Status?
	local snapshot = ProfileController.Get()
	if not snapshot then
		return nil
	end
	local rebirths = tonumber(snapshot.Rebirths) or 0
	local cash = tonumber(snapshot.Cash) or 0
	local cost = Config.GetRebirthCost(rebirths)
	local hasRare = false
	for _, slot in ipairs(snapshot.Nests or {}) do
		if typeof(slot) == "table" and slot.Kind == "Creature" and not slot.Away
			and Config.GetRarityIndex(slot.Rarity) >= Config.RebirthMinRarityIndex then
			hasRare = true
		end
	end
	local minRarity = Config.RarityOrder[Config.RebirthMinRarityIndex]
	local reason = nil
	if not hasRare then
		reason = string.format("You need a %s or better cryptid at home.", minRarity)
	elseif cash < cost then
		reason = string.format("You need $%s.", Config.FormatNumber(cost))
	end
	return { ready = reason == nil, reason = reason, cost = cost, cash = cash, hasRare = hasRare, nextRebirth = rebirths + 1 }
end

local function setLine(line: Line?, text: string?, color: Color3?)
	if not line then
		return
	end
	line.frame.Visible = text ~= nil
	if text then
		line.label.Text = text
	end
	if color then
		line.icon.ImageColor3 = color
	end
end

local function refresh()
	local s = status()
	if not s then
		return
	end
	window:SetTitle("Rebirth " .. s.nextRebirth)

	local fraction = if s.cost > 0 then math.clamp(s.cash / s.cost, 0, 1) else 1
	UI.SetProgress(costBar, fraction, tuning.BarTime)
	costLabel.Text = string.format("$%s / $%s", Config.FormatNumber(s.cash), Config.FormatNumber(s.cost))

	local minRarity = Config.RarityOrder[Config.RebirthMinRarityIndex]
	local good = if s.hasRare then C.Moss else C.BloodBright
	requirementLabel.Text = string.format("Needs a %s+ cryptid: %s", minRarity, if s.hasRare then "YES" else "NO")
	requirementLabel.TextColor3 = good
	requirementIcon.Image = Config.Icons[if s.hasRare then "CheckMark" else "Close"]
	requirementIcon.ImageColor3 = good

	setLine(gainLines[1], string.format("+%d%% Luck", s.nextRebirth * Config.Luck.PerRebirthPercent))
	setLine(gainLines[2], string.format("+%d%% Cash", math.floor(s.nextRebirth * Config.Rebirth.IncomeBonusPerRebirth * 100 + 0.5)))
	-- The glow PlotService gives your nests after this rebirth.
	local glowColors = Config.Rebirth.NestGlowColors
	setLine(gainLines[3], "New Glow", glowColors[(s.nextRebirth % #glowColors) + 1])
	local unlock: string? = nil
	local unlockColor: Color3? = nil
	for _, eggId in ipairs(Config.EggOrder) do
		local egg = Config.Eggs[eggId]
		if egg.RequiredRebirths == s.nextRebirth then
			unlock = string.format(tuning.UnlockText, egg.Name)
			unlockColor = egg.Color
		end
	end
	setLine(gainLines[4], unlock, unlockColor)

	UI.SetButtonEnabled(rebirthButton, s.ready)
	reasonLabel.Visible = not s.ready
	reasonLabel.Text = s.reason or ""
end

local function hideConfirm()
	confirm.Visible = false
end

local function showConfirm(s: Status)
	confirmText.Text = string.format("Rebirth for $%s? You lose your cash, eggs, cryptids and upgrades.",
		Config.FormatNumber(s.cost))
	UI.SetButtonEnabled(confirmYes, true)
	confirm.Visible = true
	confirmScale.Scale = Theme.Tuning.Window.OpenFromScale
	UI.Tween(confirmScale, tuning.ConfirmPopTime, { Scale = 1 }, Enum.EasingStyle.Back)
end

local function doRebirth()
	if busy then
		return
	end
	busy = true
	UI.SetButtonEnabled(confirmYes, false)
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("DoRebirth") :: RemoteFunction
	local ok, result = pcall(function()
		return remote:InvokeServer()
	end)
	busy = false
	-- Nothing stays open after the confirm, whatever the answer.
	hideConfirm()
	window:Close()
	if ok and typeof(result) == "table" then
		NotificationController.Show(tostring(result.Message or ""), if result.Ok then "Success" else "Error")
	else
		NotificationController.Show("Couldn't reach the server.", "Error")
	end
end

function RebirthController.Open()
	window:Open()
end

--- True when the player could rebirth right now (the HUD shows an alert).
function RebirthController.CanRebirth(): boolean
	local s = status()
	return s ~= nil and s.ready
end

--------------------------------------------------------------------------
-- Building the screen
--------------------------------------------------------------------------

--- One of the lose / keep / gain columns. Returns the frame its lines go in.
local function column(title: string, accent: Color3, order: number, parent: Instance): Frame
	local card = UI.Card({
		Name = title,
		Accent = accent,
		Size = UDim2.new(1 / 3, -8, 1, 0),
		LayoutOrder = order,
		Parent = parent,
	})
	UI.Text({
		Name = "Title",
		Role = "Heading",
		Text = string.upper(title),
		TextSize = 19,
		TextColor3 = accent,
		Position = UDim2.fromOffset(0, 10),
		Size = UDim2.new(1, 0, 0, 24),
		Parent = card,
	})
	UI.Divider({ Position = UDim2.fromOffset(0, 40), Parent = card })
	return UI.new("Frame", {
		Name = "Lines",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 46),
		Size = UDim2.new(1, 0, 1, -46),
		Parent = card,
	}, {
		UI.Padding({ Top = 4, Left = 12, Right = 10 }),
		UI.List({ Padding = 6 }),
	})
end

local function line(parent: Instance, iconName: string, text: string, color: Color3, order: number): Line
	local frame = UI.new("Frame", {
		Name = "Line",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 28),
		LayoutOrder = order,
		Parent = parent,
	}) :: Frame
	local icon = UI.Icon(iconName, 22, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		ImageColor3 = color,
		Parent = frame,
	})
	local label = UI.Text({
		Name = "Label",
		Role = "Body",
		Weight = "Medium",
		Text = text,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(30, 0),
		Size = UDim2.new(1, -30, 1, 0),
		Parent = frame,
	})
	return { frame = frame, icon = icon, label = label }
end

local function buildConfirm()
	-- Covers the screen's body; the dimmed backdrop swallows taps so the
	-- buttons underneath can't be pressed while the box is up.
	confirm = UI.new("TextButton", {
		Name = "Confirm",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.Backdrop,
		BackgroundTransparency = tuning.ConfirmDim,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 10,
		Visible = false,
		Parent = window.Body,
	}, { UI.Corner() })
	confirm:SetAttribute("SAC_NoClick", true) -- no click sound for the backdrop

	local box = UI.Panel({
		Name = "Box",
		Rivets = true,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(tuning.ConfirmSize.X, tuning.ConfirmSize.Y),
		Parent = confirm,
	})
	confirmScale = UI.new("UIScale", { Name = "Pop", Parent = box }) :: UIScale
	UI.Title(tuning.ConfirmTitle, 34, {
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 14),
		Size = UDim2.new(1, 0, 0, 40),
		Parent = box,
	})
	confirmText = UI.Text({
		Name = "Message",
		Role = "Body",
		Text = "",
		TextSize = 18,
		TextWrapped = true,
		Position = UDim2.fromOffset(24, 62),
		Size = UDim2.new(1, -48, 0, 72),
		Parent = box,
	})
	local buttons = UI.new("Frame", {
		Name = "Buttons",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -18),
		Size = UDim2.new(1, -48, 0, 46),
		Parent = box,
	}, {
		UI.List({
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = 16,
		}),
	})
	confirmYes = UI.Button({
		Name = "Yes",
		Variant = "Danger",
		Text = "REBIRTH",
		Icon = "Rebirth",
		TextSize = 20,
		Size = UDim2.fromOffset(180, 46),
		LayoutOrder = 1,
		OnClick = doRebirth,
		Parent = buttons,
	})
	UI.Button({
		Name = "Cancel",
		Variant = "Secondary",
		Text = "Cancel",
		TextSize = 20,
		Size = UDim2.fromOffset(150, 46),
		LayoutOrder = 2,
		OnClick = hideConfirm,
		Parent = buttons,
	})
end

local function build()
	window = Window.new({
		Name = "Rebirth",
		Title = "Rebirth",
		Icon = "Rebirth",
		Size = tuning.Size,
	})
	window.OnOpen = refresh
	window.OnClose = hideConfirm

	local main = UI.new("Frame", {
		Name = "Main",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = window.Body,
	}, {
		UI.List({ HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = 10 }),
	})

	-- Cash toward the cost.
	local costRow = UI.new("Frame", {
		Name = "Cost",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 30),
		LayoutOrder = 1,
		Parent = main,
	})
	UI.Icon("Cash", 26, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		ImageColor3 = C.Moss,
		Parent = costRow,
	})
	costBar = UI.ProgressBar({
		Name = "CostBar",
		Color = C.Moss,
		Text = "",
		TextSize = 17,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 36, 0.5, 0),
		Size = UDim2.new(1, -36, 0, 26),
		Parent = costRow,
	})
	costLabel = costBar:WaitForChild("Label") :: TextLabel

	-- Rare+ requirement.
	local requirement = UI.new("Frame", {
		Name = "Requirement",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 24),
		LayoutOrder = 2,
		Parent = main,
	}, {
		UI.List({
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = 6,
		}),
	})
	requirementIcon = UI.Icon("Close", 20, { LayoutOrder = 1, ImageColor3 = C.BloodBright, Parent = requirement })
	requirementLabel = UI.Text({
		Name = "Label",
		Role = "Heading",
		Weight = "SemiBold",
		Text = "",
		TextSize = 18,
		TextColor3 = C.BloodBright,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		LayoutOrder = 2,
		Parent = requirement,
	})

	-- Lose / keep / gain.
	local columns = UI.new("Frame", {
		Name = "Columns",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, tuning.ColumnHeight),
		LayoutOrder = 3,
		Parent = main,
	}, {
		UI.List({ FillDirection = Enum.FillDirection.Horizontal, Padding = 12 }),
	})
	local lose = column(tuning.ColumnTitles.Lose, C.BloodBright, 1, columns)
	local startingCash = Config.FormatNumber(Config.Rebirth.StartingCash)
	for i, key in ipairs(Config.Rebirth.Resets) do
		local entry = (tuning.Lose :: any)[key]
		if entry then
			local text = if string.find(entry.Text, "%s", 1, true) then string.format(entry.Text, startingCash) else entry.Text
			line(lose, entry.Icon, text, C.BloodBright, i)
		end
	end
	local keep = column(tuning.ColumnTitles.Keep, C.Moon, 2, columns)
	for i, entry in ipairs(tuning.Keep) do
		line(keep, entry.Icon, entry.Text, C.Moon, i)
	end
	local gain = column(tuning.ColumnTitles.Gain, C.Moss, 3, columns)
	gainLines = {
		line(gain, "Luck", "", C.Moss, 1),
		line(gain, "Cash", "", C.Moss, 2),
		line(gain, "Star", "New Glow", C.Moss, 3),
		line(gain, "Egg", "", C.Moss, 4),
	}

	-- The button, and why you can't yet.
	rebirthButton = UI.Button({
		Name = "RebirthBtn",
		Variant = "Primary",
		Text = "REBIRTH",
		Icon = "Rebirth",
		TextSize = 24,
		Size = UDim2.fromOffset(tuning.ButtonSize.X, tuning.ButtonSize.Y),
		LayoutOrder = 4,
		OnClick = function()
			local s = status()
			if not s then
				return
			end
			if not s.ready then
				NotificationController.Show(s.reason or "Not yet.", "Error")
				return
			end
			showConfirm(s)
		end,
		Parent = main,
	})
	reasonLabel = UI.Text({
		Name = "Reason",
		Role = "Body",
		Weight = "Medium",
		Text = "",
		TextSize = 16,
		TextColor3 = C.BloodBright,
		Size = UDim2.new(1, 0, 0, 20),
		Visible = false,
		LayoutOrder = 5,
		Parent = main,
	})

	buildConfirm()
end

function RebirthController.Start()
	build()

	ProfileController.Changed:Connect(function()
		if window:IsOpen() then
			refresh()
		end
	end)
end

return RebirthController
