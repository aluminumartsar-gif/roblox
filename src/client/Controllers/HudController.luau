--!strict
--[[
	HudController
	StarterPlayerScripts/Client/Controllers/HudController

	The main HUD, our own ScreenGui "HUD" in the campfire field kit look
	(Components/UI), drawn at Config.UI.Layers.Hud. Where everything sits
	comes from Config.UI.Layout, in px at the reference screen height: the
	whole HUD is laid out on one canvas that scales with the screen, so it
	fits a phone in landscape.

	  top centre    Base -> fast travel home; Eggs -> fast travel to the egg
	                belt (in Roblox's top-bar row). A refusal from the server
	                ("not while carrying", cooldown...) shows as a toast.
	  left middle   side tiles, a 2-column grid under the camp panel: Store,
	                Codex, Gifts, Spin, Rebirth (red "!" when you can
	                rebirth), Invite (Roblox invite prompt), Settings
	  right middle  Daily, then quick-buy Luck Potion and 3-Egg Bundle with
	                their Robux prices
	  bottom centre active buff chips with countdowns and a "PROGRESS NOT
	                SAVING" warning, then the cash (gains count up and the
	                number punches; spending snaps), the rebirth count and
	                cash bonus, and "+" (opens the Store). The tool hotbar
	                sits under it (HotbarController).

	The camp panel (top left) is PlotController's.

	Codex, Gifts, Spin and Daily belong to other controllers: they stay
	hidden until claimed with HudController.Bind, and those controllers
	drive their "!" (SetAlert) and caption (SetCaption).

	Contract: the ScreenGui is named "HUD" and has no direct child called
	"Container" (that marks a Components/Window popup: SoundController plays
	the open sound when such a gui is enabled). The cash label is
	HudController.CashLabel() (also "CashText" under the HUD) for effects
	that fly cash into it.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Components = script.Parent.Parent:WaitForChild("Components")
local Theme = require(Components:WaitForChild("Theme"))
local UI = require(Components:WaitForChild("UI"))
local Icon = require(Components:WaitForChild("Icon"))
local ProfileController = require(script.Parent:WaitForChild("ProfileController"))
local NotificationController = require(script.Parent:WaitForChild("NotificationController"))
local RobuxShopController = require(script.Parent:WaitForChild("RobuxShopController"))
local RebirthController = require(script.Parent:WaitForChild("RebirthController"))
local SettingsController = require(script.Parent:WaitForChild("SettingsController"))

local HudController = {}

local localPlayer = Players.LocalPlayer

local C = Theme.Colors
local layout = Config.UI.Layout
local tuning = Config.UI.Hud

-- Gap between a chip's left edge and its icon (px).
local CHIP_ICON_INSET = 6

-- Every HUD tile by name (side tiles and Daily), for Bind / SetAlert /
-- SetCaption.
local tiles: { [string]: TextButton } = {}
-- The handler each Bind attached; binding the same tile again replaces it.
local bound: { [string]: RBXScriptConnection } = {}
local cashLabel: TextLabel? = nil

local BUFFS: { { key: string, icon: string } } = {
	{ key = "Luck", icon = "Potion" },
	{ key = "HatchSpeed", icon = "Bonfire" },
}

local function formatClock(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function travel(destination: string)
	local remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Travel") :: RemoteFunction
	local ok, result = pcall(function()
		return remote:InvokeServer(destination)
	end)
	if ok and typeof(result) == "table" and not result.Ok then
		NotificationController.Show(tostring(result.Message or ""), "Error")
	end
end

local function invite()
	local ok, canInvite = pcall(function()
		return SocialService:CanSendGameInviteAsync(localPlayer)
	end)
	if ok and canInvite then
		pcall(function()
			SocialService:PromptGameInvite(localPlayer)
		end)
	else
		NotificationController.Show("Invites aren't available right now.", "Info")
	end
end

-- Left-middle tiles in grid order (left to right, then down). `claimed`
-- tiles belong to other controllers and stay hidden until they Bind.
type TileSpec = { name: string, label: string, icon: string, claimed: boolean? }
local SIDE_TILES: { TileSpec } = {
	{ name = "ShopBtn", label = "Store", icon = "Shop" },
	{ name = "IndexBtn", label = "Codex", icon = "Book", claimed = true },
	{ name = "GiftBtn", label = "Gifts", icon = "GiftBox", claimed = true },
	{ name = "SpinBtn", label = "Spin", icon = "Spinner", claimed = true },
	{ name = "RebirthBtn", label = "Rebirth", icon = "Rebirth" },
	{ name = "InviteBtn", label = "Invite", icon = "AddFriend" },
	{ name = "SettingsBtn", label = "Settings", icon = "Settings" },
}

local SIDE_ACTIONS: { [string]: () -> () } = {
	ShopBtn = RobuxShopController.Open,
	RebirthBtn = RebirthController.Open,
	InviteBtn = invite,
	SettingsBtn = SettingsController.Open,
}

--------------------------------------------------------------------------
-- Building blocks
--------------------------------------------------------------------------

local function setCaption(tile: Instance, text: string)
	local caption = tile:FindFirstChild("Caption")
	if caption and caption:IsA("TextLabel") then
		caption.Text = string.upper(text)
	end
end

--- An icon-only UI.Button: drop its empty label so the icon sits centred.
local function dropLabel(button: Instance)
	local content = button:FindFirstChild("Content")
	local label = content and content:FindFirstChild("Label")
	if label then
		label:Destroy()
	end
end

--- A full-screen frame laid out in reference px (Config.UI.Layout's
--- units). UI.Scale shrinks or grows it with the screen, and its size is
--- the screen divided by that scale, so once scaled it covers the screen
--- exactly and every size and offset inside it scales along.
local function buildCanvas(gui: ScreenGui): (Frame, UIScale)
	local canvas = UI.new("Frame", {
		Name = "Canvas",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	}) :: Frame
	local scale = UI.Scale(canvas)
	local function fit()
		canvas.Size = UDim2.fromScale(1 / scale.Scale, 1 / scale.Scale)
	end
	scale:GetPropertyChangedSignal("Scale"):Connect(fit)
	fit()
	return canvas, scale
end

--- A buff chip or the saving warning: a pill with an icon on the left.
local function chip(parent: Instance, name: string, order: number, iconName: string, color: Color3, filled: boolean): Frame
	local pill = UI.Pill({
		Name = name,
		Text = "",
		Color = color,
		Filled = filled,
		Height = tuning.ChipHeight,
		TextSize = tuning.ChipTextSize,
		LayoutOrder = order,
		Visible = false,
		Parent = parent,
	})
	local icon = Icon.addLeft(pill, iconName, tuning.ChipIconSize, CHIP_ICON_INSET)
	icon.ImageColor3 = if filled then C.Text else color
	if filled then
		-- Bone text reads better than the dark accent text on blood red.
		local label = pill:FindFirstChild("Label")
		if label and label:IsA("TextLabel") then
			label.TextColor3 = C.Text
		end
	end
	return pill
end

--- A quick-buy offer: a HUD tile with the item's icon and name, and a
--- moonlight (Robux) price strip along the bottom. Returns the price label.
local function offer(parent: Instance, name: string, label: string, iconName: string, order: number, key: string): TextLabel
	local priceHeight = tuning.OfferPriceHeight
	local tile = UI.IconButton({
		Name = name,
		Icon = iconName,
		Label = label,
		Size = tuning.OfferSize,
		LayoutOrder = order,
		OnClick = function()
			RobuxShopController.Buy("Product", key)
		end,
		Parent = parent,
	})
	tile.Size = UDim2.fromOffset(tuning.OfferSize, tuning.OfferSize + priceHeight)
	-- The tile's caption moves up to sit on the price strip.
	local caption = tile:FindFirstChild("Caption")
	if caption and caption:IsA("TextLabel") then
		caption.Position = UDim2.new(0.5, 0, 1, -(priceHeight + 2))
	end
	local moon = UI.Variants.Moon
	local strip = UI.new("Frame", {
		Name = "Price",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -3),
		Size = UDim2.new(1, -6, 0, priceHeight - 3),
		BackgroundColor3 = Color3.new(1, 1, 1), -- white base: the gradient carries the colour
		BorderSizePixel = 0,
		ZIndex = tile.ZIndex + 1,
		Parent = tile,
	}, {
		UI.Corner(Theme.Tuning.CornerSmall),
		UI.Gradient(Theme.Sequence(moon.Top, moon.Bottom, moon.Mid), 90),
		UI.Stroke({ Color = moon.Edge }),
		UI.List({
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = 3,
		}),
	})
	UI.Icon("Robux", tuning.OfferPriceTextSize, {
		LayoutOrder = 1,
		ImageColor3 = moon.Text,
		ZIndex = tile.ZIndex + 2,
		Parent = strip,
	})
	return UI.Text({
		Name = "PriceText",
		Role = "Heading",
		Weight = "Bold",
		Text = "...",
		TextSize = tuning.OfferPriceTextSize,
		TextColor3 = moon.Text,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromScale(0, 1),
		LayoutOrder = 2,
		ZIndex = tile.ZIndex + 2,
		Parent = strip,
	})
end

--------------------------------------------------------------------------
-- Buttons other controllers own (Codex, Daily, Gifts, Spin)
--------------------------------------------------------------------------

--- Shows a HUD tile and runs `fn` when it's pressed. Names: "IndexBtn"
--- (Codex), "GiftBtn" (Playtime Gifts), "SpinBtn" (Spin Wheel), "DailyBtn"
--- (Daily Rewards, right side). Optional caption and icon (a Config.Icons
--- name) restyle it. Returns the tile. Call from a controller's Start();
--- HudController always starts first.
function HudController.Bind(name: string, fn: () -> (), caption: string?, iconName: string?): Instance?
	local tile = tiles[name]
	if not tile then
		warn("[SAC/HUD] no HUD button called " .. name)
		return nil
	end
	tile.Visible = true
	if caption then
		setCaption(tile, caption)
	end
	local icon = tile:FindFirstChild("Icon")
	if iconName and icon and icon:IsA("ImageLabel") and Config.Icons[iconName] then
		Icon.set(icon, iconName)
	end
	local previous = bound[name]
	if previous then
		previous:Disconnect()
	end
	bound[name] = tile.Activated:Connect(function()
		fn()
	end)
	return tile
end

--- Shows or hides the red "!" badge on a HUD tile.
function HudController.SetAlert(name: string, visible: boolean)
	local tile = tiles[name]
	if tile then
		UI.SetBadge(tile, visible)
	end
end

--- Changes a HUD tile's caption (e.g. to show a countdown).
function HudController.SetCaption(name: string, text: string)
	local tile = tiles[name]
	if tile then
		setCaption(tile, text)
	end
end

--- The HUD's cash label (a target for cash-fly effects), once the HUD is built.
function HudController.CashLabel(): TextLabel?
	return cashLabel
end

--------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------

function HudController.Start()
	local gui = UI.new("ScreenGui", {
		Name = "HUD",
		ResetOnSpawn = false,
		IgnoreGuiInset = true, -- the travel buttons sit in Roblox's top-bar row
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = Config.UI.Layers.Hud,
	}) :: ScreenGui
	local canvas, canvasScale = buildCanvas(gui)

	-- Top centre: Base / Eggs fast travel.
	local top = UI.new("Frame", {
		Name = "TopButtons",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, layout.TravelTop),
		Size = UDim2.fromOffset(0, layout.TravelHeight),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		Parent = canvas,
	}, {
		UI.List({
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = tuning.TravelGap,
		}),
	})
	for i, destination in ipairs({
		{ name = "BaseBtn", text = "Base", icon = "Home", to = "Home" },
		{ name = "EggsBtn", text = "Eggs", icon = "Egg", to = "EggBelt" },
	}) do
		UI.Button({
			Name = destination.name,
			Variant = tuning.TravelVariant,
			Icon = destination.icon,
			Text = destination.text,
			TextSize = tuning.TravelTextSize,
			Size = UDim2.fromOffset(tuning.TravelWidth, layout.TravelHeight),
			LayoutOrder = i,
			OnClick = function()
				travel(destination.to)
			end,
			Parent = top,
		})
	end

	-- Left middle: side tiles in a grid. Codex, Gifts and Spin are hidden
	-- until bound; the grid skips hidden tiles.
	local size, gap, columns = layout.SideButtonSize, layout.SideButtonGap, tuning.SideColumns
	local rows = math.ceil(#SIDE_TILES / columns)
	local side = UI.new("Frame", {
		Name = "SideButtons",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(columns * size + (columns - 1) * gap, rows * size + (rows - 1) * gap),
		Parent = canvas,
	}, {
		UI.Grid({
			CellSize = UDim2.fromOffset(size, size),
			CellPadding = UDim2.fromOffset(gap, gap),
			FillDirection = Enum.FillDirection.Horizontal,
			FillDirectionMaxCells = columns,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			VerticalAlignment = Enum.VerticalAlignment.Top,
		}),
	}) :: Frame
	for i, spec in ipairs(SIDE_TILES) do
		tiles[spec.name] = UI.IconButton({
			Name = spec.name,
			Icon = spec.icon,
			Label = spec.label,
			Size = size,
			LayoutOrder = i,
			Visible = not spec.claimed,
			OnClick = SIDE_ACTIONS[spec.name],
			Parent = side,
		})
	end
	local rebirthTile = tiles.RebirthBtn

	-- Vertically centred, but never above the camp panel (PlotController
	-- puts it TopGap under Roblox's top bar, CampHeight tall).
	local function placeSide()
		local s = canvasScale.Scale
		local insetTop = GuiService:GetGuiInset().Y / s
		local canvasHeight = gui.AbsoluteSize.Y / s
		local clearTop = insetTop + layout.TopGap + layout.CampHeight + gap
		local centredTop = (canvasHeight - side.Size.Y.Offset) / 2
		side.Position = UDim2.fromOffset(layout.EdgeMargin, math.max(clearTop, centredTop))
	end
	canvasScale:GetPropertyChangedSignal("Scale"):Connect(placeSide)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(placeSide)
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(placeSide)

	-- Right middle: Daily (hidden until bound), then the quick-buy offers.
	local right = UI.new("Frame", {
		Name = "RightButtons",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -layout.EdgeMargin, 0.5, 0),
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundTransparency = 1,
		Parent = canvas,
	}, {
		UI.List({ HorizontalAlignment = Enum.HorizontalAlignment.Right, Padding = gap }),
	})
	tiles.DailyBtn = UI.IconButton({
		Name = "DailyBtn",
		Icon = "DailyRewards",
		Label = "Daily",
		Size = size,
		LayoutOrder = 1,
		Visible = false,
		Parent = right,
	})
	local offers = UI.new("Frame", {
		Name = "Offers",
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Parent = right,
	}, {
		UI.List({ FillDirection = Enum.FillDirection.Horizontal, Padding = gap }),
	})
	local potionPrice = offer(offers, "LuckOffer", "Luck", "Potion", 1, "LuckPotion")
	local bundlePrice = offer(offers, "BundleOffer", "3 Eggs!", "Egg", 2, "EggBundle")

	-- Bottom centre: buff chips and the saving warning, then the cash block.
	-- Anchored at its bottom edge, so the chips grow it upwards.
	local bottom = UI.new("Frame", {
		Name = "BottomCentre",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -layout.CashBottom),
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundTransparency = 1,
		Parent = canvas,
	}, {
		UI.List({ HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = tuning.ChipGap }),
	})
	local extras = UI.new("Frame", {
		Name = "Extras",
		Size = UDim2.fromOffset(0, tuning.ChipHeight),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		Visible = false,
		Parent = bottom,
	}, {
		UI.List({
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = tuning.ChipGap,
		}),
	}) :: Frame
	local chips: { [string]: Frame } = {}
	for i, buff in ipairs(BUFFS) do
		chips[buff.key] = chip(extras, "Buff_" .. buff.key, i, buff.icon, C.MoonBright, false)
	end
	local warning = chip(extras, "NotSaving", #BUFFS + 1, "Warning", C.Blood, true)
	UI.SetPill(warning, "PROGRESS NOT SAVING")

	local function refreshExtras()
		local any = warning.Visible
		for _, c in pairs(chips) do
			any = any or c.Visible
		end
		extras.Visible = any
	end

	local block = UI.Panel({
		Name = "CashBlock",
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		LayoutOrder = 2,
		Parent = bottom,
	})
	UI.Padding({ Top = 2, Bottom = 6, Left = 12, Right = 8 }).Parent = block
	UI.List({ HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = 0 }).Parent = block
	local cashRow = UI.new("Frame", {
		Name = "CashRow",
		Size = UDim2.fromOffset(0, tuning.CashRowHeight),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		Parent = block,
	}, {
		UI.List({
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = 6,
		}),
	})
	UI.Icon("Cash", tuning.CashIconSize, { Name = "CashIcon", LayoutOrder = 1, ImageColor3 = C.Moss, Parent = cashRow })
	local cashText = UI.Text({
		Name = "CashText",
		Role = "Heading",
		Weight = "Bold",
		Text = "...",
		TextSize = tuning.CashTextSize,
		TextColor3 = C.MossBright,
		Size = UDim2.fromOffset(0, tuning.CashRowHeight),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Parent = cashRow,
	})
	cashLabel = cashText
	local addButton = UI.Button({
		Name = "AddBtn",
		Variant = tuning.AddButtonVariant,
		Icon = "Plus",
		IconSize = tuning.AddIconSize,
		Text = "",
		Size = UDim2.fromOffset(tuning.AddButtonSize, tuning.AddButtonSize),
		LayoutOrder = 3,
		OnClick = RobuxShopController.Open,
		Parent = cashRow,
	})
	dropLabel(addButton)
	local statusText = UI.Text({
		Name = "StatusText",
		Role = "Heading",
		Weight = "SemiBold",
		Text = "",
		TextSize = tuning.StatusTextSize,
		TextColor3 = C.TextDim,
		Size = UDim2.fromOffset(0, tuning.StatusTextSize + 4),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		Parent = block,
	})

	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	placeSide()

	-- Server clock at the moment the latest snapshot arrived (buff expiry
	-- times are server os.time values).
	local snapshotServerTime = os.time()
	local snapshotClock = os.clock()

	-- Cash change animation: gains count up and the number punches;
	-- spending snaps straight to the new value.
	local shownCash: number? = nil
	local cashCounter = Instance.new("NumberValue")
	local cashTween: Tween? = nil
	local cashPunch = UI.new("UIScale", { Name = "CashPunch", Parent = cashText }) :: UIScale
	cashCounter.Changed:Connect(function(value)
		cashText.Text = "$" .. Config.FormatNumber(math.floor(value + 0.5))
	end)
	local function animateCash(cash: number)
		local previous = shownCash
		if previous == cash then
			return -- another field changed; let a running count-up finish
		end
		shownCash = cash
		if cashTween then
			cashTween:Cancel()
			cashTween = nil
		end
		if previous == nil or cash <= previous then
			cashCounter.Value = cash
			cashText.Text = "$" .. Config.FormatNumber(cash)
			return
		end
		cashCounter.Value = math.max(cashCounter.Value, previous)
		local countUp = TweenService:Create(cashCounter,
			TweenInfo.new(Config.Feedback.CashCountUpTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Value = cash })
		countUp:Play()
		cashTween = countUp
		cashPunch.Scale = Config.Feedback.CashPunchScale
		UI.Tween(cashPunch, tuning.CashPunchTime, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	end

	local function render(snapshot: { [string]: any })
		local cash = tonumber(snapshot.Cash) or 0
		local rebirths = tonumber(snapshot.Rebirths) or 0
		animateCash(cash)
		if rebirths > 0 then
			statusText.Text = string.format("Rebirth %d  ·  +%d%% cash", rebirths,
				math.floor(rebirths * Config.Rebirth.IncomeBonusPerRebirth * 100 + 0.5))
		else
			statusText.Text = "Rebirth 0"
		end
		warning.Visible = snapshot.IsPersistent == false
		refreshExtras()
	end

	local function tick()
		local snapshot = ProfileController.Get()
		local buffs = snapshot and snapshot.Buffs or {}
		local serverNow = snapshotServerTime + (os.clock() - snapshotClock)
		for key, buffChip in pairs(chips) do
			local expiry = tonumber(buffs[key])
			local remaining = if expiry then expiry - serverNow else 0
			buffChip.Visible = remaining > 0
			if remaining > 0 then
				UI.SetPill(buffChip, formatClock(remaining))
			end
		end
		refreshExtras()
		UI.SetBadge(rebirthTile, RebirthController.CanRebirth())
		potionPrice.Text = RobuxShopController.PriceText("Product", "LuckPotion")
		bundlePrice.Text = RobuxShopController.PriceText("Product", "EggBundle")
	end

	ProfileController.Changed:Connect(function(snapshot)
		snapshotServerTime = tonumber(snapshot.ServerTime) or os.time()
		snapshotClock = os.clock()
		render(snapshot)
		tick()
	end)
	local existing = ProfileController.Get()
	if existing then
		snapshotServerTime = tonumber(existing.ServerTime) or os.time()
		render(existing)
	end
	tick()

	task.spawn(function()
		while true do
			task.wait(tuning.TickInterval)
			tick()
		end
	end)
end

return HudController
